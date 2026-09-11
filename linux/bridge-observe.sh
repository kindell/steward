#!/bin/bash
# linux/bridge-observe.sh <id> | --all | --bootstrap <id> - THE adapter. Read-only: it measures,
# asks lib/bridge.sh, prints one fifteen-field line, and WRITES NOTHING. The supervisor owns
# every byte of state; this script has no path that creates, renames or removes a file.
#
# THE LINE (fields separated by US, byte 31; empty when absent):
#   1 id  2 answer  3 pid  4 birth  5 pane  6 name  7 nameSince  8 gen_state  9 classes
#   10 launch_child  11 procStart  12 sessionId  13 bridge_mtime  14 tmux_tuple  15 inode
# Fields 3-7 and 11-15 describe the ONE verified-live candidate and are blank for every other
# answer (D9): an unknown must not leak the metadata of a candidate that was not chosen.
#
# THREE THINGS PROVE A FRESH PROCESS IS OURS, TOGETHER (D4, D8, D10): the launch is open and
# inside its window on a monotonic clock; the process carries this launch's nonce in its
# environment; and it descends from the launch pane's recorded INCARNATION (the pane pid is
# alive with the birth we wrote). A file that existed before the launch (its inode was in the
# snapshot AND its mtime is older than the launch) is not this launch's file - an inode alone
# proves nothing, ext4 reuses a freed number at once.
#
# A ROW THAT IS NOT claude-code IS not-applicable (D1): no /proc, no bridge, no pgrep.
# bash 3.2 (the macOS twin): no arrays, no `local -n`, no ${var,,}.
set -u
REG_LIB="${STEWARD_REGISTRY_LIB:-$HOME/scripts/lib/registry.sh}"; . "$REG_LIB" || exit 78
BRIDGE_LIB="${STEWARD_BRIDGE_LIB:-$(dirname "$REG_LIB")/bridge.sh}"; . "$BRIDGE_LIB" || exit 78
SD="${STEWARD_STATE_DIR:?}"; SOCK="${STEWARD_TMUX_SOCKET:?}"; GRACE_MS="${STEWARD_BRIDGE_GRACE_MS:-600000}"
PROC="${BRIDGE_PROC_ROOT:-/proc}"
NOW_MS="${STEWARD_NOW_MS:-$(( $(date +%s) * 1000 ))}"
NOW_UP="${STEWARD_NOW_UPTIME_MS:-$(awk '{printf "%d", $1*1000}' "$PROC/uptime" 2>/dev/null || printf 0)}"
BOOT_ID="$(cat "$PROC/sys/kernel/random/boot_id" 2>/dev/null)"
RUNTIME_VETO_PAT='(^|[ /])(claude|opencode)'
tmuxc() { command tmux -S "$SOCK" "$@"; }
line() { local first=1 a; for a in "$@"; do [ "$first" = 1 ] && first=0 || printf '%s' "$US"; printf '%s' "$a"; done; printf '\n'; }
env_has_nonce() { [ -n "${2:-}" ] && LC_ALL=C tr '\0' '\n' < "$PROC/$1/environ" 2>/dev/null | grep -qx "STEWARD_LAUNCH_NONCE=$2"; }
same_nonempty() { [ -n "${1:-}" ] && [ "$1" = "${2:-}" ]; }
word_in() { case " $2 " in *" $1 "*) return 0 ;; *) return 1 ;; esac; }
refuse() { line "$1" "$2" "" "" "" "" "" "$3" "$4" "" "" "" "" "" ""; }   # <id> <answer> <gen_state> <reason>
observe() { # <id> <bootstrap 0|1>
  local id="$1" boot="${2:-0}" owner cfg uid classes="" tmux_present veto gen_state gp launch lup lboot nonce census lpid lbirth linodes child="" tuple=""
  local tag path pid pstart tmuxf name since sid started mtime inode alive uid_ok known claim stored any dead birth sp p q c open_launch ans
  local L_PID="" L_BIRTH="" L_PANE="" L_NAME="" L_SINCE="" L_PS="" L_SID="" L_MTIME="" L_INODE="" all_panes sess_panes
  registry_load "$id" >/dev/null 2>&1 || { refuse "$id" unknown none row-does-not-load; return; }
  [ "${RUNTIME:-claude-code}" = claude-code ] || { refuse "$id" not-applicable none ""; return; }       # D1
  [ -n "${ACCOUNT:-}" ] || { refuse "$id" unknown none account-missing; return; }
  owner="$( registry_account_load "$ACCOUNT" >/dev/null 2>&1 && printf '%s' "$ACCOUNT_USERNAME" )"
  [ -n "$owner" ] || { refuse "$id" unknown none account-does-not-resolve; return; }
  uid="$(id -u "$owner" 2>/dev/null)" || { refuse "$id" unknown none owner-uid-unknown; return; }
  [ -n "$uid" ] || { refuse "$id" unknown none owner-uid-unknown; return; }
  [ "$uid" = "$(id -u)" ] || { refuse "$id" uninspectable none other-owner; return; }
  if [ -n "${LOGIN:-}" ]; then
    registry_login_principal_gate "$LOGIN" "$ACCOUNT" >/dev/null 2>&1 || { refuse "$id" unknown none login-account-mismatch; return; }
    cfg="$(registry_login_config_dir "$LOGIN" "$owner" 2>/dev/null)" || cfg=""
  else cfg="$HOME/.claude"; fi   # the owner IS this user (checked above), and without a LOGIN the runtime's directory is the unnamed default
  [ -n "$cfg" ] && [ -r "$cfg" ] && [ -x "$cfg" ] || { refuse "$id" unknown none config-dir-unreadable; return; }
  if [ -d "$cfg/sessions" ] && ! { [ -r "$cfg/sessions" ] && [ -x "$cfg/sessions" ]; }; then refuse "$id" unknown none sessions-dir-unreadable; return; fi
  all_panes="$(tmuxc list-panes -a -F '#{pane_pid}' 2>/dev/null)"; sess_panes="$(tmuxc list-panes -s -t "=$id" -F '#{pane_pid}' 2>/dev/null)"
  if tmuxc has-session -t "=$id" 2>/dev/null; then
    tmux_present=1; tuple="$(tmuxc display-message -p -t "=$id" '#{session_id}:#{session_created}' 2>/dev/null)"
    case "$tuple" in *:*) [ -n "${tuple%%:*}" ] && [ -n "${tuple#*:}" ] || tuple="" ;; *) tuple="" ;; esac     # D5: both halves, or nothing
    [ -n "$tuple" ] || { refuse "$id" unknown none tmux-tuple-incomplete; return; }
  else tmux_present=0; fi
  launch="$(bridge_gen_get "$SD" "$id" launch_ms 2>/dev/null)"; launch="${launch:-0}"
  lup="$(bridge_gen_get "$SD" "$id" launch_uptime_ms 2>/dev/null)"; lup="${lup:-0}"
  lboot="$(bridge_gen_get "$SD" "$id" launch_boot_id 2>/dev/null)"
  nonce="$(bridge_gen_get "$SD" "$id" launch_nonce 2>/dev/null)"; gp="$(bridge_gen_get "$SD" "$id" pid 2>/dev/null)"
  census="$(bridge_gen_get "$SD" "$id" census 2>/dev/null)"; lpid="$(bridge_gen_get "$SD" "$id" launch_pane_pid 2>/dev/null)"
  lbirth="$(bridge_gen_get "$SD" "$id" launch_pane_birth 2>/dev/null)"; linodes="$(bridge_gen_get "$SD" "$id" launch_inodes 2>/dev/null)"
  if [ "$launch" != 0 ]; then                                                                            # D8: clocks
    if [ "$NOW_MS" -lt "$launch" ] || [ "$NOW_UP" -lt "$lup" ] || { [ -n "$lboot" ] && [ "$lboot" != "$BOOT_ID" ]; }; then
      refuse "$id" unknown none launch-clock-discontinuity; return; fi
  fi
  open_launch=0; [ "$launch" != 0 ] && [ -z "$gp" ] && [ $((NOW_UP - lup)) -lt "$GRACE_MS" ] && open_launch=1
  # THE LAUNCH CHILD is a nonce-bearing runtime descending from the launch pane - the pane's own
  # pid is the `; exec bash` shell, which outlives Claude and proves tmux, not the child.
  if [ -n "$lpid" ] && [ -n "$nonce" ]; then
    child=0; for p in $(pgrep -u "$uid" -f "$RUNTIME_VETO_PAT" 2>/dev/null); do bridge_is_descendant "$p" "$lpid" && env_has_nonce "$p" "$nonce" && { child=1; break; }; done
  fi
  while IFS="$US" read -r tag path pid pstart tmuxf name since sid started mtime inode; do
    [ -n "$tag" ] || continue
    [ "$tag" = '!unclassifiable' ] && { classes="$classes unclassifiable"; continue; }
    alive=0; uid_ok=0; known=0; claim=0; stored=0; any=0; dead=0; birth=""
    if birth="$(bridge_os_birth "$pid")"; then
      alive=1
      [ "$(ps -o uid= -p "$pid" 2>/dev/null | tr -d ' ')" = "$uid" ] && uid_ok=1
      if [ "$boot" = 1 ]; then known=1
      else
        bridge_gen_matches_live "$SD" "$id" "$pid" "$birth" && known=1
        if [ "$open_launch" = 1 ] && [ "${started:-0}" -ge "$launch" ] 2>/dev/null && [ "${mtime:-0}" -ge $((launch - 1000)) ] 2>/dev/null \
           && ! { word_in "$inode" "$linodes" && [ "${mtime:-0}" -lt "$launch" ] 2>/dev/null; } \
           && env_has_nonce "$pid" "$nonce" && [ -n "$lpid" ] && bridge_is_descendant "$pid" "$lpid" \
           && same_nonempty "$(bridge_os_birth "$lpid" 2>/dev/null)" "$lbirth"; then claim=1; fi
      fi
      sp="$(tmuxc display-message -p -t "$tmuxf" '#{pane_pid}' 2>/dev/null)"; [ -n "$sp" ] && bridge_is_descendant "$pid" "$sp" && stored=1
      for p in $all_panes; do bridge_is_descendant "$pid" "$p" && { any=1; break; }; done
    else
      [ "$boot" = 1 ] || { bridge_gen_matches_dead "$SD" "$id" "$pid" "$pstart" && dead=1; }
    fi
    c="$(bridge_classify_candidate "$alive" "$uid_ok" "$known" "$claim" "$stored" "$any" "$dead")"; classes="$classes $c"
    case "$c" in live:*) L_PID="$pid"; L_BIRTH="$birth"; L_PANE="$tmuxf"; L_NAME="$name"; L_SINCE="$since"; L_PS="$pstart"; L_SID="$sid"; L_MTIME="$mtime"; L_INODE="$inode" ;; esac
  done <<CANDIDATES
$(bridge_candidates "$id" "$cfg/sessions")
CANDIDATES
  gen_state=none
  if [ "$boot" = 1 ]; then gen_state=bootstrap
  elif [ -n "$gp" ]; then
    if same_nonempty "$(bridge_os_birth "$gp" 2>/dev/null)" "$(bridge_gen_get "$SD" "$id" birth 2>/dev/null)"; then gen_state=alive
    elif [ -n "$(bridge_gen_get "$SD" "$id" stop_receipt 2>/dev/null)" ]; then gen_state=gone-receipt; else gen_state=gone-noreceipt; fi
  elif [ "$open_launch" = 1 ]; then gen_state=grace
  elif [ "$launch" != 0 ]; then if [ "$child" = 1 ]; then gen_state=alive; else gen_state=gone-noreceipt; fi
  fi
  # THE VETO IS THIS SESSION'S PANES: a runtime under a pane of "=$id" blocks close and spawn.
  veto=0; for p in $(pgrep -u "$uid" -f "$RUNTIME_VETO_PAT" 2>/dev/null); do for q in $sess_panes; do bridge_is_descendant "$p" "$q" && { veto=1; break 2; }; done; done
  if [ "$boot" = 1 ]; then ans="$(bridge_answer "$classes" none "$tmux_present" "$veto" 1)"        # D3: the census ignores the generation
  else ans="$(bridge_answer "$classes" "$gen_state" "$tmux_present" "$veto" "$census")"; fi
  case "$ans" in identified:*) : ;; *) L_PID=""; L_BIRTH=""; L_PANE=""; L_NAME=""; L_SINCE=""; L_PS=""; L_SID=""; L_MTIME=""; L_INODE="" ;; esac   # D9
  line "$id" "$ans" "$L_PID" "$L_BIRTH" "$L_PANE" "$L_NAME" "$L_SINCE" "$gen_state" "${classes# }" "$child" "$L_PS" "$L_SID" "$L_MTIME" "$tuple" "$L_INODE"
}
case "${1:-}" in
  # A ROW THAT DOES NOT LOAD IS REPORTED, NOT SKIPPED: a census that drops a row silently is a
  # gate with a hole in it. Its host cannot be read, so it is printed regardless of host.
  --all) for n in $(registry_list); do
           if ! registry_load "$n" >/dev/null 2>&1; then refuse "$n" unknown none row-does-not-load; continue; fi
           [ "${HOST:-}" = "${STEWARD_SELF_HOST:-$(hostname -s)}" ] || continue; observe "$n" 0; done ;;
  --bootstrap) [ -n "${2:-}" ] || { echo "usage: bridge-observe.sh --bootstrap <id>" >&2; exit 64; }; observe "$2" 1 ;;
  '') echo "usage: bridge-observe.sh <id> | --all | --bootstrap <id>" >&2; exit 64 ;;
  *) observe "$1" 0 ;;
esac
