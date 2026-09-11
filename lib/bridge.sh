#!/bin/bash
# lib/bridge.sh - the vendor's local bridge attestation, read strictly and by name.
#
# THE FILE IS AN UNDOCUMENTED VENDOR FORMAT (<CLAUDE_CONFIG_DIR>/sessions/<pid>.json).
# Measured 2026-09-11 (P1): appears within 1 s of spawn, follows /rename within 1 s, is
# removed on clean exit and TERM, is LEFT BEHIND on KILL -9, and its `tmux` field records
# the session name AT REGISTRATION and does not follow a rename. Nothing here trusts it
# as authority: every candidate is classified, never picked. The design decision is in
# docs/superpowers/specs/2026-09-11-session-identity-and-display-design.md.
#
# POISON TRAVELS IN BAND. A broken file is a `!unclassifiable` LINE on stdout, so a
# caller that captured the output in $(...) still sees it. The first draft set a shell
# variable, which dies at the subshell boundary; every caller read zero (A2).
#
# FIELDS TRAVEL WITH THE UNIT SEPARATOR (byte 31). Tab is IFS whitespace, and `read`
# collapses a run of whitespace, so a row with an EMPTY name shifted every later field
# one to the left. US is not whitespace, so an empty value travels EMPTY and a name that
# really is "-" stays distinguishable from one that is missing (B8, third pass 10).
#
# SCHEMA FIRST, MEMBERSHIP SECOND. A record is validated COMPLETELY before its tmux is
# compared with the id. A file missing `tmux` is unsupported schema and is poison -
# never "foreign", which would let a vendor rename of that field turn every row into
# no-process and authorise a spawn (A3).
#
# TWO FIELDS ARE NEVER READ: bridgeSessionId and messagingSocketPath. jq is given the
# fields by name, so a future secret added beside them cannot ride out.
#
# NO BACKSLASH-U IN THE jq PROGRAM. A control-character class written with backslash-u
# escapes (NUL through US, and DEL) was decoded into three raw bytes by a tool that carries
# text as JSON, and the file it lived in turned into "data" (B1). Control detection uses
# explode; the separator uses implode. Both are plain jq and survive every writing tool.
#
# bash 3.2 (the macOS twin): no arrays, no `local -n`, no ${var,,}.
set -u

BRIDGE_MAX_BYTES="${BRIDGE_MAX_BYTES:-65536}"
US="$(printf '\037')"

_bridge_size() { wc -c < "$1" 2>/dev/null | tr -d ' '; }
# seconds * 1000: GNU stat first, BSD stat second. Millisecond precision is not claimed;
# the value is compared against launch_ms, which the supervisor also writes in seconds*1000.
_bridge_mtime_ms() { local s; s="$(stat -c %Y "$1" 2>/dev/null || stat -f %m "$1" 2>/dev/null)" || return 1; printf '%s000' "$s"; }
_bridge_poison() { printf '!unclassifiable%s%s%s%s\n' "$US" "$1" "$US" "$2"; }
# any byte below 32 or equal to 127 anywhere in the string. The `tr -d` keeps only those
# bytes; grep -q . then asks whether anything is left.
_bridge_has_ctl() { LC_ALL=C printf '%s' "$1" | LC_ALL=C tr -d '\040-\176\200-\377' | LC_ALL=C grep -q .; }

# bridge_candidates <id> <sessions-dir>
#   ok US path US pid US procStart US tmux US name US nameSince US sessionId US startedAt US mtime_ms
#   !unclassifiable US path US reason
# A complete, typed file whose tmux names ANOTHER id is silent (foreign). rc 0 always:
# absence is a measurement, and a non-zero exit would make a caller drop every other row.
bridge_candidates() {
  local id="${1:-}" dir="${2:-}" f sz row base mtime
  [ -n "$id" ] && [ -d "$dir" ] || return 0
  for f in "$dir"/*.json; do
    # A PATH WITH A CONTROL BYTE cannot be framed, so it is named with the bytes replaced.
    if _bridge_has_ctl "$f"; then _bridge_poison "$(printf '%s' "$f" | LC_ALL=C tr -c '\040-\176' '?')" path-control; continue; fi
    # -L BEFORE -e: a dangling symlink fails -e and would otherwise be skipped silently.
    if [ -L "$f" ]; then _bridge_poison "$f" symlink; continue; fi
    [ -e "$f" ] || continue
    if [ ! -f "$f" ]; then _bridge_poison "$f" not-regular; continue; fi
    sz="$(_bridge_size "$f")"
    if [ -z "$sz" ] || [ "$sz" -gt "$BRIDGE_MAX_BYTES" ]; then _bridge_poison "$f" size; continue; fi
    base="$(basename "$f" .json)"
    row="$(jq -r --arg id "$id" --arg base "$base" '
      def ctl: (explode | any(. < 32 or . == 127));
      def esc: gsub("(?<c>[.^$*+?()\\[\\]{}|\\\\-])"; "\\" + .c);   # jq: the replacement sees NAMED CAPTURES only
      def us: ([31] | implode);
      if type != "object" then "!notobject"
      elif ((.pid|type) != "number") or ((.procStart|type) != "number") or ((.tmux|type) != "string")
        or ((.name|type) != "string") or ((.nameSince|type) != "number") or ((.sessionId|type) != "string")
        or ((.startedAt|type) != "number") then "!types"
      elif (.tmux|ctl) or (.name|ctl) or (.sessionId|ctl) then "!control-char"
      elif ((.pid|tostring) != $base) then "!filename-pid"
      elif (.tmux | test("^" + ($id|esc) + ":@[0-9]+[.]%[0-9]+$")) | not then "!foreign"
      else [(.pid|tostring), (.procStart|tostring), .tmux,
            .name,
            (.nameSince|tostring),
            .sessionId,
            (.startedAt|tostring)] | join(us) end
    ' "$f" 2>/dev/null)" || row="!json"
    case "$row" in
      "!foreign") continue ;;
      "!"*|"") _bridge_poison "$f" "${row#!}"; continue ;;
    esac
    mtime="$(_bridge_mtime_ms "$f")" || { _bridge_poison "$f" stat; continue; }
    printf 'ok%s%s%s%s%s%s\n' "$US" "$f" "$US" "$row" "$US" "$mtime"
  done
  return 0
}

# bridge_os_birth <pid> -> "<boot_id>:<start_ticks>" ; rc 1 and empty when the pid is gone.
# Field 22 of /proc/<pid>/stat is starttime in clock ticks since boot; with the boot id in
# front it names one process for the life of the machine, which a bare pid does not.
# The comm field (2) may contain spaces and parentheses, so the line is split AFTER the
# last ")" - never on whitespace from the start. Honors BRIDGE_PROC_ROOT for fixtures.
bridge_os_birth() {
  local pid="${1:-}" root="${BRIDGE_PROC_ROOT:-/proc}" boot stat rest
  case "$pid" in ''|*[!0-9]*) return 1 ;; esac
  [ -r "$root/$pid/stat" ] || return 1
  boot="$(cat "$root/sys/kernel/random/boot_id" 2>/dev/null)" || return 1
  stat="$(cat "$root/$pid/stat" 2>/dev/null)" || return 1
  rest="${stat##*) }"        # $1 of rest = field 3 (state) ... starttime = field 22 = ${20}
  set -- $rest
  [ "$#" -ge 20 ] || return 1
  printf '%s:%s' "$boot" "${20}"
}

# bridge_is_descendant <pid> <ancestor> - rc 0 when <ancestor> is on <pid>'s parent chain.
# Moved here from linux/session-supervisor-linux.sh so the adapter can use the same walk.
bridge_is_descendant() {
  local pid="${1:-}" target="${2:-}" n=0
  while [ -n "$pid" ] && [ "$pid" -gt 1 ] 2>/dev/null && [ "$n" -lt 40 ]; do
    [ "$pid" = "$target" ] && return 0
    pid="$(ps -o ppid= -p "$pid" 2>/dev/null | tr -d ' ')"
    n=$((n+1))
  done
  return 1
}

# ---- classification: all inputs measured by the caller; this only decides ------------------
# bridge_classify_candidate <alive> <uid_ok> <birth_known> <launch_claim> <stored_pane_has_pid> <any_pane_has_pid> <dead_match>
#   live:managed    alive, the owner's uid, ours (known birth or proven launch claim), in the stored pane
#   live:moved      ... under a pane that is not the stored one (tmux renamed, or dragged) - never touched
#   live:orphan     ... under NO pane on the socket
#   stale           dead, and (pid, procStart) is in the generation's history - KILL -9 leaves this behind
#   unclassifiable  everything else; it is never chosen, and it poisons the answer (see bridge_answer)
bridge_classify_candidate() {
  local alive="${1:-0}" uid_ok="${2:-0}" known="${3:-0}" claim="${4:-0}" stored="${5:-0}" any="${6:-0}" dead="${7:-0}"
  if [ "$alive" = 1 ]; then
    [ "$uid_ok" = 1 ] || { printf 'unclassifiable'; return 0; }
    # OURS IN EXACTLY TWO WAYS: the generation knows this birth, or the adapter proved the
    # launch claim - open launch, inside the window, started after it, AND carrying this
    # launch's nonce in its environment. Time and place alone do not prove that our spawn
    # created the process; a replacement someone typed into the pane has the same time and
    # place and not the nonce (B4).
    [ "$known" = 1 ] || [ "$claim" = 1 ] || { printf 'unclassifiable'; return 0; }
    if [ "$stored" = 1 ]; then printf 'live:managed'; elif [ "$any" = 1 ]; then printf 'live:moved'; else printf 'live:orphan'; fi
    return 0
  fi
  if [ "$dead" = 1 ]; then printf 'stale'; else printf 'unclassifiable'; fi
}

# ---- the answer -------------------------------------------------------------------------------
# bridge_answer <classes> <gen_state> <tmux_present> <veto> <census>
#   classes     space-separated words from bridge_classify_candidate (may be empty)
#   gen_state   none | gone-receipt | gone-noreceipt | alive | grace
#   census      the generation's census value; ONLY the exact string "1" means done (B11)
# Prints one of: identified:managed identified:orphan identified:moved no-process unknown wait-veto grace
#
# ANY unclassifiable candidate, or more than one live one, is unknown - the answer is never
# the first thing that looked plausible. THE VETO IS AN ACTION GATE, NOT A FIFTH IDENTITY:
# no-process with the runtime veto held is wait-veto, so the caller neither closes nor spawns,
# without pretending it does not know what it saw.
bridge_answer() {
  local classes="${1:-}" gen="${2:-none}" tmux="${3:-0}" veto="${4:-0}" census="${5:-}" w live=0 unclass=0 kind=""
  for w in $classes; do
    case "$w" in live:*) live=$((live+1)); kind="${w#live:}" ;; stale) : ;; *) unclass=$((unclass+1)) ;; esac
  done
  [ "$unclass" -eq 0 ] || { printf 'unknown'; return 0; }
  [ "$live" -le 1 ]    || { printf 'unknown'; return 0; }
  [ "$live" -eq 1 ]    && { printf 'identified:%s' "$kind"; return 0; }
  case "$gen" in
    grace) printf 'grace'; return 0 ;;
    alive) printf 'unknown'; return 0 ;;          # our process lives but nothing attests it
    none)  [ "$census" = 1 ] || { printf 'unknown'; return 0; } ;;
    gone-receipt|gone-noreceipt) : ;;
    *) printf 'unknown'; return 0 ;;
  esac
  if [ "$veto" = 1 ]; then printf 'wait-veto'; else printf 'no-process'; fi
}
