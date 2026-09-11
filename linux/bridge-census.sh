#!/bin/bash
# linux/bridge-census.sh [--dry-run] [--force] [<id>] - THE ONE-TIME BOOTSTRAP CENSUS (spec §1
# "Bootstrap", gate P0; plan Task 10). Before the adapter decides anything about an existing row, this
# script snapshots what is there and seeds the row's generation, so that "no generation" afterwards
# means first-ever and not "an old process nobody registered".
#
# It runs AS THE OWNER, in the owner's home, over every claude-code row of this uid on this host (or the
# one <id> given), and asks the adapter in bootstrap mode - `bridge-observe.sh --bootstrap <id>`, which
# classifies live candidates without a generation to lean on. Per answer:
#   identified:managed  -> the verified record is seeded (pid birth procStart sessionId bridge_*), census=1
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

seeded=0; blocked=0; prereq=0; listed=0
report() { printf '%-20s %-22s %s\n' "$1" "$2" "$3"; }
census_row() { # <id>
  local id="$1" line ans reason existing
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
    identified:managed)
      report "$id" seeded "pid $BL_PID birth $BL_BIRTH procStart $BL_PS name '$BL_NAME'"
      [ -n "$DRY" ] || bridge_gen_write "$SD" "$id" pid="$BL_PID" birth="$BL_BIRTH" procStart="$BL_PS" sessionId="$BL_SID" uid="$(id -u)" \
          bridge_name="$BL_NAME" bridge_nameSince="$BL_SINCE" bridge_mtime="$BL_MTIME" bridge_inode="$BL_INODE" stop_receipt= census=1 \
        || { report "$id" blocked:write-failed "the generation could not be written to $SD"; blocked=$((blocked+1)); return 0; }
      seeded=$((seeded+1)) ;;
    no-process)
      report "$id" seeded "no process; stop receipt census-$NOW, the first spawn is planned"
      [ -n "$DRY" ] || bridge_gen_write "$SD" "$id" stop_receipt="census-$NOW" census=1 \
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
rows() {
  if [ -n "$ONLY" ]; then printf '%s\n' "$ONLY"; return 0; fi
  local n
  for n in $(registry_list 2>/dev/null); do
    ( registry_load "$n" >/dev/null 2>&1 || exit 1; [ "${HOST:-}" = "$SELF_HOST" ] || exit 1 ) && printf '%s\n' "$n"
  done
}
[ -n "$DRY" ] && echo "bridge-census: DRY RUN - nothing is written" >&2
for id in $(rows); do census_row "$id"; done
printf 'bridge-census: %d seeded, %d blocked, %d prerequisite, %d listed%s\n' "$seeded" "$blocked" "$prereq" "$listed" "${DRY:+ (dry run)}" >&2
[ "$blocked" -eq 0 ] && [ "$prereq" -eq 0 ] && exit 0
exit 1
