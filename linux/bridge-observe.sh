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
# A MEASUREMENT THAT FAILS IS NOT A MEASUREMENT OF NOTHING (advisor G2). tmux's pane census and
# pgrep's process census are the sets every classification stands on; when either cannot be
# read the answer is `unknown` with the reason - never an empty set, which would have turned a
# known live process into an orphan (-> reap) or a held veto into no-process (-> close).
# tmux's own "no server running" IS an absence and reads as an empty set.
#
# THE GENERATION IS STATE TEXT AND IS VALIDATED BEFORE IT REACHES ARITHMETIC (G3, G4): a launch
# is recorded only whole - numeric wall and uptime, a boot id equal to this boot - or the row is
# `unknown` with `generation-invalid` / `launch-clock-discontinuity`; and a launch CHILD must
# descend from the launch pane's recorded incarnation, exactly like a candidate's claim.
#
# A ROW THAT IS NOT claude-code IS not-applicable (D1): no /proc, no clock, no bridge, no pgrep -
# the refusal comes before any of them is read (G1).
# bash 3.2 (the macOS twin): no arrays, no `local -n`, no ${var,,}.
set -u
REG_LIB="${STEWARD_REGISTRY_LIB:-$HOME/scripts/lib/registry.sh}"; . "$REG_LIB" || exit 78
BRIDGE_LIB="${STEWARD_BRIDGE_LIB:-$(dirname "$REG_LIB")/bridge.sh}"; . "$BRIDGE_LIB" || exit 78
SD="${STEWARD_STATE_DIR:?}"; SOCK="${STEWARD_TMUX_SOCKET:?}"; GRACE_MS="${STEWARD_BRIDGE_GRACE_MS:-600000}"
PROC="${BRIDGE_PROC_ROOT:-/proc}"
RUNTIME_VETO_PAT='(^|[ /])(claude|opencode)'
tmuxc() { command tmux -S "$SOCK" "$@"; }
line() { local first=1 a; for a in "$@"; do [ "$first" = 1 ] && first=0 || printf '%s' "$US"; printf '%s' "$a"; done; printf '\n'; }
env_has_nonce() { [ -n "${2:-}" ] && LC_ALL=C tr '\0' '\n' < "$PROC/$1/environ" 2>/dev/null | grep -qxF "STEWARD_LAUNCH_NONCE=$2"; }   # -F: state text is never a pattern
is_nonce() { [ "${#1}" -eq 32 ] && case "$1" in *[!0-9a-f]*) return 1 ;; esac; }
# is_birth: "<boot id>:<ticks>", the boot id one token without spaces, the ticks digits (H6).
is_birth() { case "${1:-}" in *:*) : ;; *) return 1 ;; esac; [ -n "${1%%:*}" ] && case "${1%%:*}" in *[[:space:]]*) return 1 ;; esac && is_digits "${1##*:}"; }
same_nonempty() { [ -n "${1:-}" ] && [ "$1" = "${2:-}" ]; }
is_digits() { case "${1:-}" in ''|*[!0-9]*) return 1 ;; esac; return 0; }
word_in() { case " $2 " in *" $1 "*) return 0 ;; *) return 1 ;; esac; }
refuse() { line "$1" "$2" "" "" "" "" "" "$3" "$4" "" "" "" "" "" ""; }   # <id> <answer> <gen_state> <reason>
# tmux_panes <list-panes args...> -> pane pids on stdout; rc 0 measured (possibly empty), rc 1 tmux says
# there is no server (an absence), rc 2 the census could not be read (a measurement failure).
# stdout and stderr are captured together: a success is digits per line, a failure is tmux's words.
tmux_panes() {
  local res rc; res="$(tmuxc list-panes "$@" -F '#{pane_pid}' 2>&1)"; rc=$?
  if [ "$rc" -eq 0 ]; then case "$res" in *[!0-9$'\n']*) return 2 ;; esac; printf '%s\n' "$res"; return 0; fi
  case "$res" in *"no server running"*|*"error connecting to"*|*"No such file or directory"*) return 1 ;; *) return 2 ;; esac
}
# runtime_pids <uid> -> pids on stdout; rc 0 measured (rc 1 from pgrep is "no match" and reads as empty), rc 2 pgrep failed.
runtime_pids() { local out rc; out="$(pgrep -u "$1" -f "$RUNTIME_VETO_PAT" 2>/dev/null)"; rc=$?; [ "$rc" -le 1 ] || return 2; printf '%s\n' "$out"; return 0; }
observe() { # <id> <bootstrap 0|1>
  local id="$1" boot="${2:-0}" owner cfg uid classes="" tmux_present veto gen_state gp gbirth launch lup lboot nonce census lpid lbirth linodes child="" tuple=""
  local tag path pid pstart tmuxf name since sid started mtime inode alive uid_ok known claim stored any dead birth sp p q c open_launch ans
  local L_PID="" L_BIRTH="" L_PANE="" L_NAME="" L_SINCE="" L_PS="" L_SID="" L_MTIME="" L_INODE="" all_panes sess_panes="" rpids rc now_ms now_up boot_id lpid_birth=""
  registry_load "$id" >/dev/null 2>&1 || { refuse "$id" unknown none row-does-not-load; return; }
  [ "${RUNTIME:-claude-code}" = claude-code ] || { refuse "$id" not-applicable none ""; return; }       # D1, before any clock or /proc read (G1)
  [ -n "${ACCOUNT:-}" ] || { refuse "$id" unknown none account-missing; return; }
  owner="$( registry_account_load "$ACCOUNT" >/dev/null 2>&1 && printf '%s' "$ACCOUNT_USERNAME" )"
  [ -n "$owner" ] || { refuse "$id" unknown none account-does-not-resolve; return; }
  uid="$(id -u "$owner" 2>/dev/null)" || { refuse "$id" unknown none owner-uid-unknown; return; }
  is_digits "$uid" || { refuse "$id" unknown none owner-uid-unknown; return; }
  [ "$uid" = "$(id -u)" ] || { refuse "$id" uninspectable none other-owner; return; }
  if [ -n "${LOGIN:-}" ]; then
    registry_login_principal_gate "$LOGIN" "$ACCOUNT" >/dev/null 2>&1 || { refuse "$id" unknown none login-account-mismatch; return; }
    cfg="$(registry_login_config_dir "$LOGIN" "$owner" 2>/dev/null)" || cfg=""
  else cfg="$HOME/.claude"; fi   # the owner IS this user (checked above), and without a LOGIN the runtime's directory is the unnamed default
  [ -n "$cfg" ] && [ -r "$cfg" ] && [ -x "$cfg" ] || { refuse "$id" unknown none config-dir-unreadable; return; }
  if [ -d "$cfg/sessions" ] && ! { [ -r "$cfg/sessions" ] && [ -x "$cfg/sessions" ]; }; then refuse "$id" unknown none sessions-dir-unreadable; return; fi
  # ---- clocks and /proc, read only now, and validated before any arithmetic (G1, G4) ----
  now_ms="${STEWARD_NOW_MS:-$(( $(date +%s) * 1000 ))}"
  now_up="${STEWARD_NOW_UPTIME_MS:-$(awk '{printf "%d", $1*1000}' "$PROC/uptime" 2>/dev/null)}"
  boot_id="$(cat "$PROC/sys/kernel/random/boot_id" 2>/dev/null)"
  is_digits "$now_ms" && is_digits "$now_up" && is_digits "$GRACE_MS" && [ -n "$boot_id" ] || { refuse "$id" unknown none clock-invalid; return; }
  # ---- the tmux census (G2): presence, tuple, this session's panes, every pane on the socket ----
  if tmuxc has-session -t "=$id" 2>/dev/null; then
    tmux_present=1; tuple="$(tmuxc display-message -p -t "=$id" '#{session_id}:#{session_created}' 2>/dev/null)"
    case "$tuple" in *:*) [ -n "${tuple%%:*}" ] && [ -n "${tuple#*:}" ] || tuple="" ;; *) tuple="" ;; esac     # D5: both halves, or nothing
    [ -n "$tuple" ] || { refuse "$id" unknown none tmux-tuple-incomplete; return; }
    sess_panes="$(tmux_panes -s -t "=$id")" || { refuse "$id" unknown none tmux-session-panes-unreadable; return; }
  else tmux_present=0; fi
  all_panes="$(tmux_panes -a)"; rc=$?
  if [ "$rc" -eq 2 ] || { [ "$rc" -eq 1 ] && [ "$tmux_present" = 1 ]; }; then refuse "$id" unknown none tmux-panes-unreadable; return; fi
  # ---- the process census (G2): one pgrep, used by the launch child and the veto ----
  rpids="$(runtime_pids "$uid")" || { refuse "$id" unknown none pgrep-failed; return; }
  # ---- the generation, validated as text before it is used as numbers (G3, G4) ----
  gp="$(bridge_gen_get "$SD" "$id" pid 2>/dev/null)"; gbirth="$(bridge_gen_get "$SD" "$id" birth 2>/dev/null)"
  launch="$(bridge_gen_get "$SD" "$id" launch_ms 2>/dev/null)"; lup="$(bridge_gen_get "$SD" "$id" launch_uptime_ms 2>/dev/null)"
  lboot="$(bridge_gen_get "$SD" "$id" launch_boot_id 2>/dev/null)"; nonce="$(bridge_gen_get "$SD" "$id" launch_nonce 2>/dev/null)"
  census="$(bridge_gen_get "$SD" "$id" census 2>/dev/null)"; lpid="$(bridge_gen_get "$SD" "$id" launch_pane_pid 2>/dev/null)"
  lbirth="$(bridge_gen_get "$SD" "$id" launch_pane_birth 2>/dev/null)"; linodes="$(bridge_gen_get "$SD" "$id" launch_inodes 2>/dev/null)"
  # PAIRS ARE WHOLE (H6): a pid without a birth can never be proven alive OR dead, so with a live process
  # and no bridge file it would have read as gone -> no-process -> a spawn beside a process whose absence
  # was never shown. The same for the launch pane; and a stored nonce is exactly 32 lowercase hex.
  { [ -z "$gp" ] || { is_digits "$gp" && is_birth "$gbirth"; }; } && { [ -z "$gbirth" ] || [ -n "$gp" ]; } \
    && { [ -z "$lpid$lbirth" ] || { is_digits "$lpid" && is_birth "$lbirth"; }; } \
    && { [ -z "$nonce" ] || is_nonce "$nonce"; } || { refuse "$id" unknown none generation-invalid; return; }
  if [ -n "$launch$lup$lboot$nonce" ]; then                                    # a launch is recorded: it must be WHOLE (G3, G4)
    is_digits "$launch" && is_digits "$lup" || { refuse "$id" unknown none generation-invalid; return; }
    same_nonempty "$lboot" "$boot_id" || { refuse "$id" unknown none launch-clock-discontinuity; return; }   # empty boot id is a discontinuity too (D8)
    if [ "$now_ms" -lt "$launch" ] || [ "$now_up" -lt "$lup" ]; then refuse "$id" unknown none launch-clock-discontinuity; return; fi
  else launch=0; lup=0; fi
  open_launch=0; [ "$launch" != 0 ] && [ -z "$gp" ] && [ $((now_up - lup)) -lt "$GRACE_MS" ] && open_launch=1
  # THE LAUNCH PANE INCARNATION: the recorded pane pid alive with the recorded birth. Both the launch
  # child and a candidate's claim require it (D4, G3); a reused pane pid proves nothing.
  if [ -n "$lpid" ] && same_nonempty "$(bridge_os_birth "$lpid" 2>/dev/null)" "$lbirth"; then lpid_birth=1; else lpid_birth=""; fi
  # THE LAUNCH CHILD is a nonce-bearing runtime descending from the launch pane incarnation - the
  # pane's own pid is the `; exec bash` shell, which outlives Claude and proves tmux, not the child.
  if [ -n "$lpid" ] && [ -n "$nonce" ]; then
    child=0
    if [ -n "$lpid_birth" ]; then for p in $rpids; do bridge_is_descendant "$p" "$lpid" && env_has_nonce "$p" "$nonce" && { child=1; break; }; done; fi
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
        bridge_gen_matches_live "$SD" "$id" "$pid" "$birth" "$pstart" && known=1   # K4: a procStart that contradicts the generation is not known
        if [ "$open_launch" = 1 ] && [ -n "$lpid_birth" ] && is_digits "${started:-}" && is_digits "${mtime:-}" \
           && [ "$started" -ge "$launch" ] && [ "$mtime" -ge $((launch - 1000)) ] \
           && ! { word_in "$inode" "$linodes" && [ "$mtime" -lt "$launch" ]; } \
           && env_has_nonce "$pid" "$nonce" && bridge_is_descendant "$pid" "$lpid"; then claim=1; fi
      fi
      sp="$(tmuxc display-message -p -t "$tmuxf" '#{pane_pid}' 2>/dev/null)"; is_digits "$sp" && bridge_is_descendant "$pid" "$sp" && stored=1
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
    if same_nonempty "$(bridge_os_birth "$gp" 2>/dev/null)" "$gbirth"; then gen_state=alive
    elif [ -n "$(bridge_gen_get "$SD" "$id" stop_receipt 2>/dev/null)" ]; then gen_state=gone-receipt; else gen_state=gone-noreceipt; fi
  elif [ "$open_launch" = 1 ]; then gen_state=grace
  elif [ "$launch" != 0 ]; then if [ "$child" = 1 ]; then gen_state=alive; else gen_state=gone-noreceipt; fi
  fi
  # THE VETO IS THIS SESSION'S PANES: a runtime under a pane of "=$id" blocks close and spawn.
  veto=0; for p in $rpids; do for q in $sess_panes; do bridge_is_descendant "$p" "$q" && { veto=1; break 2; }; done; done
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
