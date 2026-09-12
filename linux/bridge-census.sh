#!/bin/bash
# linux/bridge-census.sh [--dry-run] [--force] [<id>] - THE ONE-TIME BOOTSTRAP CENSUS (spec §1
# "Bootstrap", gate P0; plan Task 10). Before the adapter decides anything about an existing row, this
# script snapshots what is there and seeds the row's generation, so that "no generation" afterwards
# means first-ever and not "an old process nobody registered".
#
# It runs AS THE OWNER, in the owner's home, over every claude-code row of this uid on this host (or the
# one <id> given), and asks the adapter in bootstrap mode - `bridge-observe.sh --bootstrap <id>`, which
# classifies live candidates without a generation to lean on. Per answer:
#   identified:*        -> the verified record is seeded (pid birth procStart sessionId bridge_*), census=1 -
#                          managed, ORPHAN and MOVED alike (N1): the census's job is to write down what is
#                          there, and a seeded orphan is exactly what lets the supervisor's own policy
#                          reap it on the next round. Blocking it instead would leave a live process the
#                          adapter can never match again.
#   no-process          -> stop_receipt=census-<epoch> census=1 (nothing runs; the first spawn is planned)
#   anything else       -> census=blocked:<answer> - the supervisor keeps the row unknown until an
#                          operator resolves it and re-runs the census for that row with --force
#   not-applicable      -> listed, nothing written (OpenCode and Codex have no generation)
#   account-missing     -> listed as a PREREQUISITE, nothing written: the ACCOUNT migration comes first
#   uninspectable       -> listed, nothing written: the owner's own census seeds it
# A row that already carries census=1 is skipped unless --force. --dry-run prints the verdicts and
# writes nothing. Exit 0 when every row this uid can seed is seeded; 1 when any row is blocked or a
# prerequisite is missing (the report says which); 64 usage; 78 environment.
#
# THIS IS THE ONLY WRITER OF `census`. The observer never writes; the supervisor reads census and
# writes everything else. bash 3.2 (the macOS twin): no arrays, no `local -n`.
set -u
DRY=""; FORCE=""; ONLY=""
while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run) DRY=1 ;;
    --force) FORCE=1 ;;
    -h|--help) echo "usage: bridge-census.sh [--dry-run] [--force] [<id>]" >&2; exit 64 ;;
    -*) echo "bridge-census: unknown flag '$1'" >&2; exit 64 ;;
    *) [ -z "$ONLY" ] || { echo "bridge-census: one id at most" >&2; exit 64; }; ONLY="$1" ;;
  esac; shift
done
REG_LIB="${STEWARD_REGISTRY_LIB:-$HOME/scripts/lib/registry.sh}"; . "$REG_LIB" || { echo "bridge-census: registry library missing: $REG_LIB" >&2; exit 78; }
BRIDGE_LIB="${STEWARD_BRIDGE_LIB:-$(dirname "$REG_LIB")/bridge.sh}"; . "$BRIDGE_LIB" || { echo "bridge-census: bridge library missing: $BRIDGE_LIB" >&2; exit 78; }
HERE="$(CDPATH= cd -- "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OBSERVE="${STEWARD_BRIDGE_OBSERVE:-$HERE/bridge-observe.sh}"; [ -f "$OBSERVE" ] || { echo "bridge-census: the bridge observer is missing: $OBSERVE" >&2; exit 78; }
if [ -n "${STEWARD_STATE_DIR:-}" ]; then SD="$STEWARD_STATE_DIR"; else
  _sn="$(registry_state_dir_name 2>/dev/null)" || { echo "bridge-census: the estate names no state directory" >&2; exit 78; }
  SD="$HOME/.local/state/$_sn"
fi
if [ -n "${STEWARD_TMUX_SOCKET:-}" ]; then SOCK="$STEWARD_TMUX_SOCKET"; else
  _sk="$(registry_tmux_socket 2>/dev/null)" || { echo "bridge-census: the estate names no tmux socket" >&2; exit 78; }
  SOCK="$HOME/.tmux/$_sk"
fi
SELF_HOST="${STEWARD_SELF_HOST:-$(hostname -s 2>/dev/null || hostname)}"
NOW="$(date +%s)"; case "$NOW" in ''|*[!0-9]*) echo "bridge-census: the clock could not be read" >&2; exit 78 ;; esac
[ -n "$DRY" ] || mkdir -p "$SD" 2>/dev/null || { echo "bridge-census: the state directory cannot be created: $SD" >&2; exit 78; }

# census_clear <id> - a census is a COMPLETE statement about a row, not a merge into whatever was there
# (advisor N3). Re-censusing a row that once ran and is now gone must not leave its old pid, birth,
# launch claim or pending name behind, dressed up as "seeded". Everything the census does not itself
# write is cleared first; the history the generation keeps of earlier (pid, procStart, birth) triples is
# not touched, because that is what makes a KILL -9 file recognisable later.
census_clear() {
  bridge_gen_write "$SD" "$1" pid= birth= procStart= sessionId= uid= \
    bridge_name= bridge_nameSince= bridge_mtime= bridge_inode= \
    launch_ms= launch_uptime_ms= launch_boot_id= launch_nonce= launch_pane_pid= launch_pane_birth= launch_inodes= \
    spawn_state= grace_rounds= applied= applied_at= applied_nameSince= pending_for= pending_since= pending_name= rename_tries= \
    stop_intent= stop_receipt= census= >/dev/null 2>&1
}

seeded=0; blocked=0; prereq=0; listed=0
report() { printf '%-20s %-22s %s\n' "$1" "$2" "$3"; }
census_row() { # <id>
  local id="$1" line ans reason existing why
  if ! why="$(census_eligible "$id")"; then
    report "$id" refused "$why"; blocked=$((blocked+1)); return 0
  fi
  existing="$(bridge_gen_get "$SD" "$id" census 2>/dev/null)"
  if [ "$existing" = 1 ] && [ -z "$FORCE" ]; then report "$id" already-censused "generation carries census=1; --force to redo"; return 0; fi
  line="$(STEWARD_STATE_DIR="$SD" STEWARD_TMUX_SOCKET="$SOCK" STEWARD_REGISTRY_LIB="$REG_LIB" STEWARD_BRIDGE_LIB="$BRIDGE_LIB" bash "$OBSERVE" --bootstrap "$id" 2>/dev/null)" || line=""
  if ! bridge_line_valid "$line" "$id"; then
    report "$id" blocked:unreadable "the observer's answer is not the fifteen-field contract"
    [ -n "$DRY" ] || bridge_gen_write "$SD" "$id" census="blocked:unreadable" >/dev/null 2>&1 || true
    blocked=$((blocked+1)); return 0
  fi
  ans="$BL_ANS"; reason="$BL_CLASSES"
  case "$ans" in
    identified:managed|identified:orphan|identified:moved)
      report "$id" seeded "${ans#identified:}: pid $BL_PID birth $BL_BIRTH procStart $BL_PS name '$BL_NAME'"
      [ -n "$DRY" ] || { census_clear "$id"; bridge_gen_write "$SD" "$id" pid="$BL_PID" birth="$BL_BIRTH" procStart="$BL_PS" sessionId="$BL_SID" uid="$(id -u)" \
          bridge_name="$BL_NAME" bridge_nameSince="$BL_SINCE" bridge_mtime="$BL_MTIME" bridge_inode="$BL_INODE" stop_receipt= census=1; } \
        || { report "$id" blocked:write-failed "the generation could not be written to $SD"; blocked=$((blocked+1)); return 0; }
      seeded=$((seeded+1)) ;;
    no-process)
      report "$id" seeded "no process; stop receipt census-$NOW, the first spawn is planned"
      [ -n "$DRY" ] || { census_clear "$id"; bridge_gen_write "$SD" "$id" stop_receipt="census-$NOW" census=1; } \
        || { report "$id" blocked:write-failed "the generation could not be written to $SD"; blocked=$((blocked+1)); return 0; }
      seeded=$((seeded+1)) ;;
    not-applicable)
      report "$id" not-applicable "not a claude-code row; no generation"; listed=$((listed+1)) ;;
    uninspectable)
      report "$id" uninspectable "another owner's row (${reason:-other-owner}); its owner's census seeds it"; listed=$((listed+1)) ;;
    unknown)
      case "$reason" in
        *account-missing*) report "$id" prerequisite "no ACCOUNT on the row - migrate the row first (P0 prerequisite)"; prereq=$((prereq+1)); return 0 ;;
      esac
      report "$id" "blocked:unknown" "${reason:-unknown}; resolve, then: bridge-census.sh --force $id"
      [ -n "$DRY" ] || bridge_gen_write "$SD" "$id" census="blocked:unknown" >/dev/null 2>&1 || true
      blocked=$((blocked+1)) ;;
    *)
      report "$id" "blocked:$ans" "${reason:-$ans}; resolve, then: bridge-census.sh --force $id"
      [ -n "$DRY" ] || bridge_gen_write "$SD" "$id" census="blocked:$ans" >/dev/null 2>&1 || true
      blocked=$((blocked+1)) ;;
  esac
}
# ONE GATE FOR ONE ROW AND FOR ALL OF THEM (advisor N2): an explicit <id> used to skip the load, the
# owner and the host check, so `bridge-census.sh <a row on another host>` would ask THIS host's socket
# about a foreign row and write this host's state under its name. A row is censused here only if it
# loads, belongs to this unix account, and lives on this host.
census_eligible() { # <id> -> rc 0 eligible; otherwise a reason on stdout
  local id="$1" snap owner
  registry_valid_name "$id" || { printf '%s' "not a session id"; return 1; }
  snap="$( registry_load "$id" >/dev/null 2>&1 || exit 1
           _u="$OWNER"; [ -z "${ACCOUNT:-}" ] || { registry_account_load "$ACCOUNT" >/dev/null 2>&1 && _u="$ACCOUNT_USERNAME"; }
           printf '%s\n%s' "${HOST:-}" "$_u" )" || { printf '%s' "the row does not load"; return 1; }
  local h="${snap%%$'\n'*}" u="${snap#*$'\n'}"
  [ "$h" = "$SELF_HOST" ] || { printf '%s' "it lives on '$h', not on $SELF_HOST"; return 1; }
  [ "${u:-}" = "$(id -un)" ] || { printf '%s' "it belongs to '${u:-nobody}', not to $(id -un) - its own owner censuses it"; return 1; }
  return 0
}
rows() {
  if [ -n "$ONLY" ]; then printf '%s\n' "$ONLY"; return 0; fi
  local n
  for n in $(registry_list 2>/dev/null); do
    census_eligible "$n" >/dev/null 2>&1 && printf '%s\n' "$n"
  done
}
[ -n "$DRY" ] && echo "bridge-census: DRY RUN - nothing is written" >&2
for id in $(rows); do census_row "$id"; done
printf 'bridge-census: %d seeded, %d blocked, %d prerequisite, %d listed%s\n' "$seeded" "$blocked" "$prereq" "$listed" "${DRY:+ (dry run)}" >&2
[ "$blocked" -eq 0 ] && [ "$prereq" -eq 0 ] && exit 0
exit 1
