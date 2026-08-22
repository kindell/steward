#!/bin/bash
# linux/install-user-jobs.sh [--enable] — generate the job SNAPSHOT from the
# domain repos, and say what does NOT match the timers.
#
# WHY IT EXISTS. agent-job@ reads its confs from a SNAPSHOT
# ($HOME/scripts/jobs.d), not from the domain repos — deliberately: a job must be
# able to start without reading somebody else's checkout. On the hub, its own
# installer generates that directory. On Linux there was no equivalent at all.
#
# The consequence was not theoretical. A domain corrected its job conf IN THE
# SOURCE, correctly and verified — and the change had no effect, because what runs
# is the snapshot. The job ran blind for seventy hours, and the last of those
# hours were down to nobody knowing a manual step existed. The snapshot was four
# weeks old by then and differed from the source in TWO fields, not one.
#
# A FILE NOBODY GENERATES BUT EVERYTHING READS is a recurring shape in this tree.
# When both registries can carry the truth, the fix is to REMOVE one of them; here
# that is not possible, because the snapshot has a purpose of its own. Then the
# fix is a generator — that is, this file.
#
# READS AND WRITES ONLY IN THE RUNNING USER'S OWN HOME. No sudo, nobody else's
# directory: each person operates their own jobs, just as they do their own
# sessions.
set -uo pipefail

ENABLE=""; ACCEPT_DRIFT=""
for a in "$@"; do
  case "$a" in
    --enable)        ENABLE=1 ;;
    --accept-drift)  ACCEPT_DRIFT=1 ;;
    *) echo "anvandning: install-user-jobs.sh [--enable] [--accept-drift]" >&2; exit 64 ;;
  esac
done

HOME_SCRIPTS="${STEWARD_HOME_SCRIPTS:-$HOME/scripts}"
SOURCES="$HOME_SCRIPTS/jobs-sources.conf"
SNAPDIR="$HOME_SCRIPTS/jobs.d"

_reg_lib() {
  local c
  for c in "$HOME_SCRIPTS/lib/registry.sh" "$(dirname "${BASH_SOURCE[0]}")/../lib/registry.sh"; do
    [ -f "$c" ] && { printf '%s' "$c"; return 0; }
  done
  return 1
}
REG="${STEWARD_REGISTRY_LIB:-$(_reg_lib)}" || REG=""
# A REGISTRY THAT CANNOT BE READ MUST NEVER LOOK LIKE AN EMPTY ONE. Without the
# library no conf can be VALIDATED, and copying unvalidated confs would move the
# fault closer to the run instead of catching it.
[ -n "$REG" ] && [ -f "$REG" ] || { echo "install-user-jobs: VAGRAR — registerbiblioteket saknas" >&2; exit 78; }
# shellcheck source=/dev/null
. "$REG" || { echo "install-user-jobs: VAGRAR — registerbiblioteket gick inte att lasa" >&2; exit 78; }

if [ ! -f "$SOURCES" ]; then
  # THE DIFFERENCE BETWEEN "NO SOURCES" AND "NO SOURCE LIST" is the whole point of
  # this file: the first is an answer, the second is a broken installation.
  echo "install-user-jobs: VAGRAR — kallistan saknas: $SOURCES" >&2
  echo "  En rad per domanrepo. Utan den vet ingen VILKA jobb som ska finnas." >&2
  exit 78
fi
mkdir -p "$SNAPDIR" || exit 78

fel=0; skrivna=0; oforandrade=0; seen=""
while IFS= read -r srcrepo; do
  case "$srcrepo" in ''|\#*) continue ;; esac
  if [ ! -d "$srcrepo/jobs.d" ]; then
    echo "install-user-jobs: kallan '$srcrepo' har ingen jobs.d — hoppar" >&2
    continue
  fi
  # THE PROVENANCE GATE. The deploy path requires source files to be CLEAN: "the
  # deploy deploys HEAD, and last-good carries the sha". The snapshot had no
  # equivalent — a conf could be copied out of an UNCOMMITTED working tree, and
  # then no sha binds what RUNS to anything in the history. It was found by the
  # domain whose conf I hand-copied that way myself: the hand-copy went around the
  # gate, and the generator inherited the hole until this line existed.
  #
  # WHY IT MATTERS: a job that goes wrong is diagnosed by reading its conf. If the
  # conf is uncommitted there is no way to know WHO changed it, WHEN, or what it
  # said before — and last-good cannot carry that. A snapshot without provenance is
  # a running configuration with no history.
  #
  # --accept-drift exists because a gate nobody can get past gets bypassed by
  # hand-copying instead, which is exactly what happened. The exemption is LOUD and
  # names the sha that is missing.
  _repo_sha=""; _repo_smutsig=""
  if git -C "$srcrepo" rev-parse --git-dir >/dev/null 2>&1; then
    _repo_sha="$(git -C "$srcrepo" rev-parse --short HEAD 2>/dev/null)"
    [ -n "$(git -C "$srcrepo" status --porcelain -- jobs.d 2>/dev/null)" ] && _repo_smutsig=1
  else
    _repo_smutsig=1; _repo_sha="(inget git-tra)"
  fi
  if [ -n "$_repo_smutsig" ]; then
    if [ -n "$ACCEPT_DRIFT" ]; then
      echo "install-user-jobs: DRIFT GODTAGEN for '$srcrepo' (jobs.d ar ocommitterad, harkomst=$_repo_sha+lokalt)" >&2
      fel=1
    else
      echo "install-user-jobs: VAGRAR '$srcrepo' — jobs.d har ocommitterade andringar" >&2
      echo "    Ogonblicksbilden skulle da kora utan en sha som binder den till historiken." >&2
      echo "    Committa forst, eller kor med --accept-drift om du VET vad du gor." >&2
      fel=1; continue
    fi
  fi

  for conf in "$srcrepo"/jobs.d/*.conf; do
    [ -e "$conf" ] || continue
    # AN INVALID CONF FAILS THE RUN, but does not stop the others. Aborting
    # outright would let one broken job hold all the rest hostage; staying silent
    # would give a green run that left a job out.
    if ! registry_job_load "$conf" >/dev/null 2>&1; then
      echo "install-user-jobs: OGILTIG conf, hoppas over: $conf" >&2
      registry_job_load "$conf" 2>&1 | sed 's/^/    /' >&2
      fel=1; continue
    fi
    snapname="$DOMAIN-$JOB_NAME.conf"
    case " $seen " in
      *" $snapname "*)
        echo "install-user-jobs: DUBBLETT $snapname fran flera kallor — behaller den forsta" >&2
        fel=1; continue ;;
    esac
    seen="$seen $snapname"
    if cmp -s "$conf" "$SNAPDIR/$snapname"; then
      oforandrade=$((oforandrade+1))
    else
      cp "$conf" "$SNAPDIR/$snapname" || { echo "install-user-jobs: kunde inte skriva $snapname" >&2; fel=1; continue; }
      echo "  uppdaterad: $snapname  (harkomst $_repo_sha)"
      # THE PROVENANCE IS WRITTEN DOWN, not just printed. A line in a terminal is
      # gone the next day; whoever debugs this in three weeks needs to know which
      # sha the conf came out of.
      printf '%s\t%s\t%s\t%s\n' "$snapname" "$srcrepo" "$_repo_sha${_repo_smutsig:++lokalt}" \
        "$(date -u +%FT%TZ)" >> "$SNAPDIR/.harkomst" 2>/dev/null || true
      skrivna=$((skrivna+1))
    fi
  done
done < "$SOURCES"

# --- orphaned snapshots -------------------------------------------------------
# A conf whose source has disappeared RUNS ANYWAY until somebody removes it. It is
# not cleaned up automatically: deleting from a directory that also holds hand
# copies and backups is an irreversible act on weak evidence. It is NAMED instead.
foraldralosa=""
for f in "$SNAPDIR"/*.conf; do
  [ -e "$f" ] || continue
  b="$(basename "$f")"
  case " $seen " in *" $b "*) continue ;; esac
  foraldralosa="$foraldralosa $b"
done

# --- the timers ---------------------------------------------------------------
# A CONF EXISTING DOES NOT MEAN ANYTHING RUNS IT. Without this check, "the job is
# deployed" and "the job runs" are two different states that look identical in
# every measurement made on the file.
saknade=""
for snapname in $seen; do
  unit="agent-job@${snapname%.conf}.timer"
  if systemctl --user is-enabled "$unit" >/dev/null 2>&1; then continue; fi
  saknade="$saknade $unit"
done

echo "install-user-jobs: $skrivna uppdaterade, $oforandrade oforandrade, $(printf '%s' "$seen" | wc -w | tr -d ' ') jobb totalt."
[ -n "$foraldralosa" ] && { echo "  FORALDRALOSA (kalla borta, kors anda):$foraldralosa"; fel=1; }
if [ -n "$saknade" ]; then
  if [ -n "$ENABLE" ]; then
    for u in $saknade; do
      if systemctl --user enable --now "$u" >/dev/null 2>&1; then echo "  timer aktiverad: $u"
      else echo "  KUNDE INTE aktivera: $u" >&2; fel=1; fi
    done
  else
    echo "  TIMER SAKNAS (confen finns, ingenting kor den):$saknade"
    echo "  Kor med --enable for att aktivera dem."
    fel=1
  fi
fi
exit "$fel"
