#!/bin/bash
# linux/deploy-apply.sh — the host's executor for a deploy. Runs as root on the
# host, invoked by whichever entry point built the stage; the fixture suite runs
# it unprivileged with STEWARD_DEPLOY_INSTALL_OWNER=off.
#
#   deploy-apply.sh <stage> <sha> [--accept-drift <home> --file <target> [--file <target>]...] <home>...
#   ONE --accept-drift per run: the valve holds a single home. See the parser.
#
# Order per home: drift gate -> loneliness sweep -> install -> post-check ->
# daemon-reload (only if a systemd unit changed) -> new last-good.
#
# THE SWEEP COMES BEFORE INSTALL. Measured during a domain's cutover: a decoy is
# a precondition, not something install creates — and sweeping after install gave
# a bootstrap loop that never converges.
#
# TARGET PATHS ARE ALWAYS BUILT AS <home>/<target> — never '~', never the HOME
# variable. It was exactly that kind of expansion that sent a document into the
# wrong person's home. The prohibition is asserted by a grep test, not by
# discipline.
#
# No code path may touch services: the only permitted systemctl verb is
# daemon-reload. That is asserted by a grep test too — policy as code.
set -uo pipefail

STAGE="${1:?deploy-apply.sh <stage> <sha> [flags] <home>...}"
SHA="${2:?deploy-apply.sh <stage> <sha> [flags] <home>...}"
shift 2
STATE="${STEWARD_DEPLOY_STATE:-/var/lib/steward-deploy}"
SYSTEMCTL="${STEWARD_DEPLOY_SYSTEMCTL:-systemctl}"
MANIFEST="$STAGE/deploy-manifest"
[ -d "$STAGE" ] && [ -f "$MANIFEST" ] || {
  echo "deploy-apply: stage or manifest missing: $STAGE" >&2; exit 78; }
mkdir -p "$STATE" 2>/dev/null || { echo "deploy-apply: cannot write $STATE" >&2; exit 78; }

# The manifest is read into a row list. Defined here, early, because the valve
# validation below needs it.
manifest_rows() { grep -v '^#' "$MANIFEST" | awk 'NF>=4'; }

# ── A REGISTRY ROW RECONCILES A DIRECTORY ──────────────────────────
# Install every delivered *.conf, then remove every *.conf in the target that
# was NOT delivered. The prune is the reason the row type exists: without it a
# conf removed in the hub keeps being loaded on the host, the supervisor keeps
# starting the session, and nothing says why.
#
# ONLY *.conf IS TOUCHED, in both directions. A live home carries backups
# beside its confs (measured: six .bak-omdop siblings in one home), and a
# deploy that eats them destroys the only copy of what a rename replaced.
#
# THE DIRECTORY ITSELF SURVIVES AN EMPTY DELIVERY. "Exists and is empty" and
# "is missing" are different states — the register's own list function refuses
# on the second and returns nothing on the first.
#
# A MISSING SOURCE DIRECTORY REFUSES, IT DOES NOT PRUNE. Without this check an
# unstaged directory looked exactly like an empty delivery: the glob below
# expanded to nothing, the delivered list stayed empty, and the prune loop
# removed every conf a host had — silently, at rc 0. A measurement that
# cannot be made must refuse, never report empty.
# A DELIVERED-NAME LIST WAS TRIED AND DROPPED. It joined basenames with a '|'
# delimiter and matched with `case ... *"|$base|"*`, but POSIX allows '|' in a
# filename: delivering "a|b.conf" made the delivered string "|a|b.conf|",
# which contains "|b.conf|" as a substring — so an unrelated, undelivered
# "b.conf" matched and survived the prune. Asking the source directory
# directly, per candidate, has no delimiter to break.
#
# A BROKEN SYMLINK IS STILL A *.conf. "[ -f ]" is false for one (it resolves
# the link), so a stale, undelivered *.conf that is a dangling symlink was
# skipped by BOTH loops below and never installed or pruned. "[ -e ] || [ -L ]"
# catches it either way.
apply_registry_row() { # <stage-dir> <target-dir> <mode>
  local SRCD="$1" DSTD="$2" MODE="$3" c base tmp
  [ -d "$SRCD" ] || { echo "deploy: registry source directory missing: $SRCD" >&2; return 70; }
  mkdir -p "$DSTD" || { echo "deploy: cannot create $DSTD" >&2; return 70; }
  for c in "$SRCD"/*.conf; do
    [ -e "$c" ] || [ -L "$c" ] || continue
    base="$(basename "$c")"
    # AN OVERWRITE OF A DIFFERING FILE IS ANNOUNCED. A registry row is the only
    # place in the deploy that changes files without passing the drift gate, so
    # without this line it would also be the only place that changes them
    # silently. A NEW file is not a reconciliation and says nothing.
    if [ -f "$DSTD/$base" ] && ! cmp -s "$c" "$DSTD/$base"; then
      echo "RECONCILED $DSTD/$base"
    fi
    # WRITE ATOMICALLY, LIKE EVERY OTHER ROW TYPE IN THIS FILE — see the
    # tmp_dst comment further down for the measured truncation bug this
    # avoids: install to a sibling name in the same directory, set its mode
    # before it is visible, then rename over the target.
    tmp="$DSTD/.deploy-tmp.$base.$$"
    cp "$c" "$tmp" || { rm -f "$tmp"; echo "deploy: cannot install $base into $DSTD" >&2; return 70; }
    chmod "$MODE" "$tmp" || { rm -f "$tmp"; echo "deploy: cannot set mode on $DSTD/$base" >&2; return 70; }
    mv -f "$tmp" "$DSTD/$base" || { rm -f "$tmp"; echo "deploy: cannot install $base into $DSTD" >&2; return 70; }
  done
  for c in "$DSTD"/*.conf; do
    [ -e "$c" ] || [ -L "$c" ] || continue
    base="$(basename "$c")"
    if [ -e "$SRCD/$base" ] || [ -L "$SRCD/$base" ]; then continue; fi
    rm -f "$c" || { echo "deploy: cannot prune $c" >&2; return 70; }
    echo "PRUNED $DSTD/$base"
  done
  return 0
}

# --accept-drift <home> --file <target> [--file <target>]... — the valve, with a
# name and a trace: the files are enumerated one by one, and the overwrite is
# recorded in last-good. Parsed here; its effect lives in the drift gate.
ACCEPT_HOME=""; ACCEPT_FILES=""
HOMES=""
while [ $# -gt 0 ]; do
  case "$1" in
    --accept-drift)
      [ $# -ge 2 ] || { echo "deploy-apply: --accept-drift requires a value (home root)" >&2; exit 64; }
      # ONE HOME PER RUN. ACCEPT_HOME is a scalar: before 2026-08-22 a second
      # --accept-drift overwrote the first WITHOUT A WORD, while --file went on
      # accumulating into a shared list. Measured on basement: two homes in one run
      # gave one OK and one refusal whose text was IDENTICAL to the run with no
      # valve at all — the valve that had been given vanished, and nothing in the
      # output told the two cases apart. The usage line promised repetition with a
      # trailing "...", which is what made that form reasonable to write.
      [ -z "$ACCEPT_HOME" ] || {
        echo "deploy-apply: --accept-drift given twice ($ACCEPT_HOME, then $2) — the valve holds ONE home and the second would have replaced the first silently. Run one home per invocation." >&2
        exit 64; }
      ACCEPT_HOME="$2"; shift 2 ;;
    --file)
      [ $# -ge 2 ] || { echo "deploy-apply: --file requires a value (target path)" >&2; exit 64; }
      ACCEPT_FILES="$ACCEPT_FILES $2"; shift 2 ;;
    -*)            echo "deploy-apply: unknown argument $1" >&2; exit 64 ;;
    *)             HOMES="$HOMES $1"; shift ;;
  esac
done
[ -n "${HOMES// /}" ] || { echo "deploy-apply: no homes given" >&2; exit 64; }
if [ -n "$ACCEPT_HOME" ] && [ -z "${ACCEPT_FILES// /}" ]; then
  echo "deploy-apply: --accept-drift requires --file per drifted file — the valve leaves a trace" >&2
  exit 64
fi
# THE VALVE MUST MATCH SOMETHING REAL. A home that is not part of this batch, or
# a --file that is not a manifest target, is a valve that silently misses its
# subject — and the next run produces an identical refusal without a word about
# the valve having been given and not matched. Measured: a trailing slash on the
# home, or the wrong case in --file, produced the same refusal verbatim.
if [ -n "$ACCEPT_HOME" ]; then
  case " $HOMES " in
    *" $ACCEPT_HOME "*) ;;
    *) echo "deploy-apply: the valve was given for $ACCEPT_HOME but that home is not in this batch ($HOMES)" >&2
       exit 64 ;;
  esac
  _target_set="$(manifest_rows | awk '{print $2}')"
  for _af in $ACCEPT_FILES; do
    printf '%s\n' "$_target_set" | grep -qxF "$_af" || {
      echo "deploy-apply: the valve was given for $_af but that file is not a manifest target" >&2
      exit 64
    }
  done
fi

# Portable wrappers — the fixture runs on macOS, production is Linux/GNU. The
# hub never computes a hash; these do, on the host, because whoever computes it
# can also lie about the result.
hash_of()  { if command -v md5sum >/dev/null 2>&1; then md5sum "$1" | cut -d' ' -f1
             else md5 -q "$1"; fi }
inode_of() { if stat -c %i "$1" >/dev/null 2>&1; then stat -c %i "$1"
             else stat -f %i "$1"; fi }
# The dereferencing variant (-L): measured in the fixture — neither GNU stat -c
# nor BSD stat -f reads through a symlink without -L (the same lstat semantics on
# both), contrary to what was assumed. Only the sweep needs "what does the link
# point at"; everywhere else compares real files, where lstat and stat agree.
inode_of_L() { if stat -L -c %i "$1" >/dev/null 2>&1; then stat -L -c %i "$1"
               else stat -L -f %i "$1"; fi }
now_iso()  { date -u +%Y-%m-%dT%H:%M:%SZ; }

# ensure_dir <home root> <full directory path> — creates missing components
# below the home root, ONE at a time, and sets owner and mode ONLY on the
# component it just created.
#
# It refuses (rc 65, naming $SYMLINK_COMPONENT) if ANY component below the home
# root is already a symlink: `install -d` FOLLOWS symlinked directories and
# forces mode and owner onto whatever the link points at. Measured: a directory
# in mode 700 became 755, and through a symlink the chown can land far outside
# the tree (~/bin -> /etc, run as root).
#
# An existing directory's own mode and owner are NEVER touched — only what we
# created ourselves, just now.
ensure_dir() {
  home="$1"; dir="$2"
  case "$dir" in
    "$home") return 0 ;;
    "$home"/*) : ;;
    *) echo "deploy-apply: internal: $dir is not below $home" >&2; return 70 ;;
  esac
  rel="${dir#$home/}"
  sofar="$home"
  IFS_SAVED="$IFS"; IFS=/
  set -- $rel
  IFS="$IFS_SAVED"
  for part in "$@"; do
    sofar="$sofar/$part"
    if [ -L "$sofar" ]; then
      SYMLINK_COMPONENT="$sofar"
      return 65
    fi
    if [ ! -e "$sofar" ]; then
      mkdir "$sofar" || return 70
      if [ "${STEWARD_DEPLOY_INSTALL_OWNER:-}" != "off" ]; then
        chown "$USERNAME:$USERNAME" "$sofar" || return 70
      fi
      chmod 755 "$sofar" || return 70
    elif [ ! -d "$sofar" ]; then
      SYMLINK_COMPONENT="$sofar (exists but is not a directory)"
      return 70
    fi
  done
  return 0
}

TOTAL_RC=0
UNTOUCHED=""

for HOME_ROOT in $HOMES; do
  USERNAME="$(basename "$HOME_ROOT")"
  LG="$STATE/$USERNAME.last-good"
  COMPARED=0; INSTALLED=0
  REFUSED=""

  # ── PHANTOM HOME. Measured: a home root that did not exist was silently
  # created by `install -d`, 29 files landed in the decoy directory, the report
  # said BOOTSTRAP and rc 0 — "the right file at the wrong path" in its purest
  # form. Checked BEFORE any writing.
  if [ ! -d "$HOME_ROOT" ]; then
    echo "HOME $HOME_ROOT RESULT=REFUSED COMPARED=0 INSTALLED=0"
    echo "REFUSAL $HOME_ROOT the home root does not exist as a directory — phantom home (wrong path in the registry?), not created silently"
    TOTAL_RC=78
    continue
  fi
  if command -v getent >/dev/null 2>&1; then
    PASSWD_HOME="$(getent passwd "$USERNAME" | cut -d: -f6)"
    if [ -n "$PASSWD_HOME" ] && [ "$PASSWD_HOME" != "$HOME_ROOT" ]; then
      echo "HOME $HOME_ROOT RESULT=REFUSED COMPARED=0 INSTALLED=0"
      echo "REFUSAL $HOME_ROOT the home root does not match account ${USERNAME}'s home according to passwd ($PASSWD_HOME)"
      TOTAL_RC=78
      continue
    fi
  fi

  # ── THE DRIFT GATE (against last-good, BEFORE any writing) ───────────────
  if [ -f "$LG" ]; then
    DRIFT_DETAIL=""
    while read -r src target mode kind; do
      lg_md5="$(awk -v m="$target" '$1==m && $3=="" {print $2} $1==m && $3!="" {print $2}' "$LG" | head -1)"
      [ -n "$lg_md5" ] || continue          # a new manifest row: no baseline yet
      COMPARED=$((COMPARED+1))
      deployed="$HOME_ROOT/$target"
      if [ ! -f "$deployed" ]; then
        # A DELETED FILE IS DRIFT — not a gap to silently reinstall into.
        DRIFT_DETAIL="$DRIFT_DETAIL|$target is missing — it was in last-good and is now deleted => a deleted file is drift, no silent reinstall — accept it deliberately with --accept-drift $HOME_ROOT --file $target"
      else
        dep_md5="$(hash_of "$deployed")"
        if [ "$dep_md5" = "$lg_md5" ]; then continue; fi
        # THREE-WAY DIAGNOSIS (a finding from a session owner's review): compare
        # against the INCOMING source as well, not just against last-good.
        src_md5="$(hash_of "$STAGE/src/$src" 2>/dev/null || echo missing)"
        if [ "$dep_md5" = "$src_md5" ]; then
          DRIFT_DETAIL="$DRIFT_DETAIL|$target differs = the incoming source's md5 => the signature of an interrupted run, not a hand edit — re-run with --accept-drift $HOME_ROOT --file $target"
        else
          DRIFT_DETAIL="$DRIFT_DETAIL|$target differs with a THIRD value (neither last-good nor the source) => a hand edit — investigate, or accept it deliberately with --accept-drift $HOME_ROOT --file $target"
        fi
      fi
      # The valve: an enumerated file is let through, with a trace.
      if [ "$ACCEPT_HOME" = "$HOME_ROOT" ]; then
        case " $ACCEPT_FILES " in *" $target "*) DRIFT_DETAIL="${DRIFT_DETAIL%|*}"; continue ;; esac
      fi
      REFUSED=1
    done <<ROWS
$(manifest_rows)
ROWS
    if [ -n "$REFUSED" ]; then
      echo "HOME $HOME_ROOT RESULT=REFUSED COMPARED=$COMPARED INSTALLED=0"
      printf '%s\n' "$DRIFT_DETAIL" | tr '|' '\n' | while IFS= read -r line; do
        [ -n "$line" ] && echo "REFUSAL $HOME_ROOT $line"
      done
      TOTAL_RC=65
      continue
    fi
    # An untouched home is a positive control group: an exact match before the
    # deploy, which is what proves the gate was actually able to compare.
    [ "$COMPARED" -gt 0 ] && [ -z "$DRIFT_DETAIL" ] && UNTOUCHED="$UNTOUCHED $HOME_ROOT"
    BOOTSTRAP=""
  else
    BOOTSTRAP=1
    echo "BOOTSTRAP $HOME_ROOT — no last-good: the current state is measured and becomes the baseline; drift refusal applies from the next run"
  fi

  # ── THE LONELINESS SWEEP (BEFORE install — a decoy is a precondition) ─────
  # A decoy is a file with the same basename as a manifest target, sitting
  # earlier on the user's PATH, quietly shadowing the deployed one.
  #
  # The candidate directories are derived from the MEASURED PATH (measured:
  # ~/scripts is on no PATH and cannot shadow anything; ~/bin only in a login
  # shell) plus the manifest's own target directories. The comparison is made on
  # inode/realpath, never on names: a symlink to the target is harmless, other
  # content is the decoy.
  if [ -n "${STEWARD_SWEEP_PATH_ALL:-}" ]; then
    SWEEP_PATH="$STEWARD_SWEEP_PATH_ALL"
  else
    override="$(eval "printf %s \"\${STEWARD_SWEEP_PATH_${USERNAME}:-}\"" 2>/dev/null || true)"
    if [ -n "$override" ]; then SWEEP_PATH="$override"
    else
      SWEEP_PATH="$(sudo -n -u "$USERNAME" bash -lc 'printf %s "$PATH"' 2>/dev/null):$(sudo -n -u "$USERNAME" bash -c 'printf %s "$PATH"' 2>/dev/null)"
    fi
  fi
  SWEEP_DIRS=""
  IFS_SAVED="$IFS"; IFS=:
  for d in $SWEEP_PATH; do
    case "$d" in "$HOME_ROOT"/*) SWEEP_DIRS="$SWEEP_DIRS $d" ;; esac   # this home's directories only
  done
  IFS="$IFS_SAVED"
  while read -r src target mode kind; do
    SWEEP_DIRS="$SWEEP_DIRS $HOME_ROOT/$(dirname "$target")"
  done <<ROWS
$(manifest_rows)
ROWS
  SWEEP_DIRS="$(printf '%s\n' $SWEEP_DIRS | sort -u)"
  # THE SET of all manifest targets: one basename may have SEVERAL legitimate
  # targets (a bus client can live both on the PATH and inside a guard's own
  # directory). A candidate that is itself a manifest target is never a decoy —
  # compare against the set, not against the row's own target, or two legitimate
  # files report each other.
  ALL_TARGETS="|"
  while read -r src target mode kind; do
    ALL_TARGETS="$ALL_TARGETS$HOME_ROOT/$target|"
  done <<ROWS
$(manifest_rows)
ROWS
  SWEEP_HITS=""
  while read -r src target mode kind; do
    base="$(basename "$target")"
    target_file="$HOME_ROOT/$target"
    for d in $SWEEP_DIRS; do
      cand="$d/$base"
      [ -e "$cand" ] || continue
      case "$ALL_TARGETS" in *"|$cand|"*) continue ;; esac   # a legitimate target of some row
      # git working copies are exempt: a clone is a source, not a deploy target
      gd="$d"; in_git=""
      while [ "$gd" != "$HOME_ROOT" ] && [ "$gd" != "/" ]; do
        [ -d "$gd/.git" ] && { in_git=1; break; }
        gd="$(dirname "$gd")"
      done
      [ -n "$in_git" ] && continue
      # the same inode as the target = the same file (symlink/hardlink) = harmless
      if [ -e "$target_file" ]; then
        ci="$(cd "$(dirname "$cand")" 2>/dev/null && inode_of "$(basename "$cand")" 2>/dev/null || echo x)"
        ti="$(inode_of "$target_file")"
        [ "$ci" = "$ti" ] && continue
        # a symlink whose target IS the target file — read through the link:
        # inode_of (lstat) NEVER reads through a link (measured, see above),
        # which is why inode_of_L is used here, the only place that needs it.
        li="$(inode_of_L "$cand" 2>/dev/null || echo y)"
        [ "$li" = "$ti" ] && continue
      fi
      SWEEP_HITS="$SWEEP_HITS|DECOY $cand (target: $target)"
    done
  done <<ROWS
$(manifest_rows)
ROWS
  if [ -n "$SWEEP_HITS" ]; then
    echo "HOME $HOME_ROOT RESULT=REFUSED COMPARED=$COMPARED INSTALLED=0"
    printf '%s\n' "$SWEEP_HITS" | tr '|' '\n' | while IFS= read -r line; do
      [ -n "$line" ] && echo "REFUSAL $HOME_ROOT $line"
    done
    TOTAL_RC=65
    continue
  fi

  # ── INSTALL + POST-CHECK ─────────────────────────────────────────────────
  BEFORE_ROWS=""
  NEW_LG_ROWS=""
  SYSTEMD_CHANGED=""
  INSTALL_ERROR=""
  COMPONENT_REFUSED=""
  while read -r src target mode kind; do
    if [ "$kind" = "registry" ]; then
      apply_registry_row "$STAGE/src/$src" "$HOME_ROOT/$target" "$mode" \
        || { INSTALL_ERROR="$target (registry row failed to reconcile $src)"; break; }
      continue
    fi
    srcfile="$STAGE/src/$src"
    dst="$HOME_ROOT/$target"
    [ -f "$srcfile" ] || { echo "REFUSAL $HOME_ROOT the source is missing from the stage: $src" ; REFUSED=1; break; }
    if [ -n "$BOOTSTRAP" ]; then
      if [ -f "$dst" ]; then BEFORE_ROWS="$BEFORE_ROWS
# BEFORE $target $(hash_of "$dst")"
      else BEFORE_ROWS="$BEFORE_ROWS
# BEFORE $target MISSING"; fi
    fi
    before_inode="$( [ -f "$dst" ] && inode_of "$dst" || echo new )"
    SYMLINK_COMPONENT=""
    ensure_dir "$HOME_ROOT" "$(dirname "$dst")"
    dirrc=$?
    if [ "$dirrc" -eq 65 ]; then
      COMPONENT_REFUSED="symlink in the target path: $SYMLINK_COMPONENT (target $target) — refusing to follow symlinked directory components"
      break
    elif [ "$dirrc" -ne 0 ]; then
      INSTALL_ERROR="directory $target ($SYMLINK_COMPONENT)"; break
    fi
    # INSTALL DOES NOT WRITE ATOMICALLY. Measured on a Linux host (GNU coreutils
    # 9.4): `install` over an existing file TRUNCATES it and writes into the same
    # inode. The post-check below required the inode to have changed — so the
    # deploy could NEVER succeed against a home that already had the file, and
    # the first live run failed on the manifest's first row in all three homes.
    #
    # The gate was right and the code was wrong. What the documentation claimed
    # — that a running script is safe because the process keeps its old inode —
    # was therefore untrue: a truncation underneath a bash that reads the file
    # line by line can feed it garbage mid-run.
    #
    # Hence: install to a sibling name in the SAME directory (same filesystem,
    # so the rename is atomic), set owner and mode on it before it is visible,
    # and move it over the target. Now the inode really does change, and the
    # post-check measures something that actually happens.
    tmp_dst="$(dirname "$dst")/.deploy-tmp.$(basename "$dst").$$"
    if [ "${STEWARD_DEPLOY_INSTALL_OWNER:-}" = "off" ]; then
      install -m "$mode" "$srcfile" "$tmp_dst" || { rm -f "$tmp_dst"; INSTALL_ERROR="$target"; break; }
    else
      install -o "$USERNAME" -g "$USERNAME" -m "$mode" "$srcfile" "$tmp_dst" \
        || { rm -f "$tmp_dst"; INSTALL_ERROR="$target"; break; }
    fi
    mv -f "$tmp_dst" "$dst" || { rm -f "$tmp_dst"; INSTALL_ERROR="$target (rename failed)"; break; }
    after_inode="$(inode_of "$dst")"
    after_md5="$(hash_of "$dst")"
    src_md5="$(hash_of "$srcfile")"
    if [ "$after_md5" != "$src_md5" ]; then INSTALL_ERROR="$target (md5 after != the source's)"; break; fi
    if [ "$before_inode" != "new" ] && [ "$before_inode" = "$after_inode" ]; then
      INSTALL_ERROR="$target (the inode did not change — install did not write atomically)"; break
    fi
    INSTALLED=$((INSTALLED+1))
    case "$kind" in systemd) SYSTEMD_CHANGED=1 ;; esac
    accept_mark=""
    if [ "$ACCEPT_HOME" = "$HOME_ROOT" ]; then
      case " $ACCEPT_FILES " in *" $target "*) accept_mark=" ACCEPT-DRIFT" ;; esac
    fi
    NEW_LG_ROWS="$NEW_LG_ROWS
$target $src_md5$accept_mark"
  done <<ROWS
$(manifest_rows)
ROWS
  if [ -n "$COMPONENT_REFUSED" ]; then
    echo "HOME $HOME_ROOT RESULT=REFUSED COMPARED=$COMPARED INSTALLED=$INSTALLED"
    echo "REFUSAL $HOME_ROOT $COMPONENT_REFUSED"
    TOTAL_RC=65
    continue
  fi
  if [ -n "$INSTALL_ERROR" ]; then
    echo "HOME $HOME_ROOT RESULT=REFUSED COMPARED=$COMPARED INSTALLED=$INSTALLED"
    echo "REFUSAL $HOME_ROOT execution failure at $INSTALL_ERROR — last-good UNTOUCHED, the next run will see drift and diagnose it"
    TOTAL_RC=70
    continue
  fi

  # ── DAEMON-RELOAD (the only permitted systemctl verb) ────────────────────
  if [ -n "$SYSTEMD_CHANGED" ]; then
    "$SYSTEMCTL" --user daemon-reload 2>/dev/null \
      || echo "HOME $HOME_ROOT note: daemon-reload did not work from here — it is run by the owner"
  fi

  # ── NEW LAST-GOOD (last — an abort before this point looks like drift, by
  # design: the baseline must never claim a state that was not reached) ─────
  count="$(printf '%s\n' "$NEW_LG_ROWS" | grep -c .)"
  tmp="$(mktemp)"
  {
    echo "# steward-deploy last-good user=$USERNAME sha=$SHA ts=$(now_iso) count=$count"
    printf '%s\n' "$NEW_LG_ROWS" | grep .
    # RETIRED rows are inherited from the previous image: a file that has left
    # the manifest keeps being measured and reported. Without this, an additive
    # manifest plus a manifest-driven sweep together make a permanently
    # unmeasured decoy.
    if [ -f "$LG" ]; then
      awk 'NR>1 && $1!~/^#/ {print $1}' "$LG" | while read -r old_target; do
        printf '%s\n' "$NEW_LG_ROWS" | awk '{print $1}' | grep -qx "$old_target" && continue
        old_md5="$(awk -v m="$old_target" '$1==m {print $2}' "$LG" | head -1)"
        echo "$old_target $old_md5 RETIRED"
      done
    fi
    [ -n "$BEFORE_ROWS" ] && { echo "# before-state (bootstrap only):"; printf '%s\n' "$BEFORE_ROWS" | grep .; }
  } > "$tmp"
  chmod 600 "$tmp"
  mv "$tmp" "$LG"
  result=OK; [ -n "$BOOTSTRAP" ] && result=BOOTSTRAP
  echo "HOME $HOME_ROOT RESULT=$result COMPARED=$COMPARED INSTALLED=$INSTALLED"
done

for u in $UNTOUCHED; do echo "UNTOUCHED-HOME $u"; done
[ -z "$UNTOUCHED" ] && echo "UNTOUCHED-HOME: none — every home either differed or was bootstrapped; read that as a state, not as a receipt"
home_count="$(printf '%s\n' $HOMES | grep -c .)"
echo "DEPLOY sha=$SHA ts=$(now_iso) homes=$home_count rc=$TOTAL_RC"
exit "$TOTAL_RC"
