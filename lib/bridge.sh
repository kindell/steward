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
#   ok US path US pid US procStart US tmux US name US nameSince US sessionId US startedAt US mtime_ms US inode
# THE INODE IS THE FRESHNESS RECORD (D10): the supervisor snapshots the inodes in sessions/ before
# it spawns, and a candidate whose inode was in that set existed before the launch it claims.
#   !unclassifiable US path US reason
# A complete, typed file whose tmux names ANOTHER id is silent (foreign). rc 0 always:
# absence is a measurement, and a non-zero exit would make a caller drop every other row.
bridge_candidates() {
  local id="${1:-}" dir="${2:-}" f sz row base mtime inode
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
      # procStart NORMALISES TO DIGITS OR IT IS POISON. Three vendor shapes are known: a number
      # (P1), a digit string (basement 2026-09-11), and - on darwin - the lstart words of ps(1),
      # "Sat Sep 12 08:40:24 2026" (butler 2026-09-12). The third read as !types, so EVERY bridge
      # file on a Mac was poison and the adapter answered unknown for a session plainly running.
      #
      # pidDomain IS THE DISCRIMINATOR, NOT THE SHAPE. Reading the date because it resembles one
      # is how a gate loosens into "any string will do" - the digit string taught us that
      # once. Without pidDomain=="darwin" a date is still poison, so no other build can smuggle
      # words through here.
      #
      # mktime IS UTC, AND THAT IS THE POINT. The vendor writes procStart in UTC; ps(1) prints
      # lstart in LOCAL time - measured exactly 7200s apart on three live pids in one second on a
      # CEST host. Each parsed in its own zone names the same instant. Parsed in one zone they
      # never compare equal, and the failure would read as "wrong process", not "wrong timezone".
      def psnorm:
        if (.procStart|type) == "number" then
          (if (.procStart|floor) == .procStart and .procStart >= 0 then (.procStart|tostring) else null end)
        elif (.procStart|type) == "string" then
          (if (.procStart|test("^[0-9]+$")) then .procStart
           elif .pidDomain == "darwin" then (try (.procStart|strptime("%a %b %d %H:%M:%S %Y")|mktime|tostring) catch null)
           else null end)
        else null end;
      # procStart IS A STRING ON THIS VENDOR BUILD and a number on another (measured on basement
      # 2026-09-11: "procStart":"54058753"; P1 saw a number). It is an opaque token we only ever compare,
      # so both shapes are read and both become the same digit string - while anything that is not
      # digits is still poison. Nothing else about the strictness moves.
      if type != "object" then "!notobject"
      elif ((.pid|type) != "number") or ((.tmux|type) != "string")
        or ((.name|type) != "string") or ((.nameSince|type) != "number") or ((.sessionId|type) != "string")
        or ((.startedAt|type) != "number") then "!types"
      elif (psnorm == null) then "!types"
      elif (.tmux|ctl) or (.name|ctl) or (.sessionId|ctl) then "!control-char"
      elif ((.pid|tostring) != $base) then "!filename-pid"
      elif (.tmux | test("^" + ($id|esc) + ":@[0-9]+[.]%[0-9]+$")) | not then "!foreign"
      else [(.pid|tostring), psnorm, .tmux,   # every accepted shape leaves here as the same digits
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
    inode="$(stat -c %i "$f" 2>/dev/null || stat -f %i "$f" 2>/dev/null)"; case "$inode" in ''|*[!0-9]*) _bridge_poison "$f" stat; continue ;; esac
    printf 'ok%s%s%s%s%s%s%s%s\n' "$US" "$f" "$US" "$row" "$US" "$mtime" "$US" "$inode"
  done
  return 0
}

# ---- OS facts: two backends, one vocabulary --------------------------------------------------
# MEASURED ON MININ 2026-09-12 (macOS arm64): there is no /proc and no pidfd. Every process fact the
# identity rests on - boot token, birth, state, process group, tty, foreground group, environment -
# is read here and nowhere else, from /proc on Linux and from ps(1)+sysctl(8) on darwin. Callers see
# the same words on both. BRIDGE_OS overrides uname for fixtures; BRIDGE_PROC_ROOT replaces /proc.
bridge_os() { case "${BRIDGE_OS:-$(uname -s 2>/dev/null)}" in Darwin|darwin) printf darwin ;; *) printf linux ;; esac; }

# bridge_boot_id -> one token that names this boot; compared for equality only. Linux: the kernel's
# boot_id. darwin: kern.boottime's seconds - stable for the life of the boot, different after one.
bridge_boot_id() {
  local root="${BRIDGE_PROC_ROOT:-/proc}" b
  case "$(bridge_os)" in
    darwin) b="$(sysctl -n kern.boottime 2>/dev/null | sed -n 's/.*{[[:space:]]*sec = \([0-9][0-9]*\).*/\1/p' | head -1)" ;;   # anchored on "{ sec": "usec" contains "sec" too
    *)      b="$(cat "$root/sys/kernel/random/boot_id" 2>/dev/null)" ;;
  esac
  case "$b" in ''|*[!0-9A-Za-z-]*) return 1 ;; esac
  printf '%s' "$b"
}

# bridge_uptime_ms -> milliseconds since boot (digits), rc 1 when unreadable.
bridge_uptime_ms() {
  local root="${BRIDGE_PROC_ROOT:-/proc}" u b
  case "$(bridge_os)" in
    darwin) b="$(bridge_boot_id)" || return 1; u="$(( ($(date +%s) - b) * 1000 ))" ;;
    *)      u="$(awk '{printf "%d", $1*1000}' "$root/uptime" 2>/dev/null)" ;;
  esac
  case "$u" in ''|*[!0-9]*) return 1 ;; esac
  printf '%s' "$u"
}

# _bridge_darwin_ps <pid> -> "state pgid tty tpgid start_epoch" from ps(1); rc 1 when the pid is gone.
# lstart is local time in ps's own words; python3 (required on darwin for the kill helper anyway) turns
# it into seconds. Seconds are the birth's resolution there: a pid reused within the same second as
# its predecessor's start is the one thing this cannot tell apart, and pids do not wrap that fast.
_bridge_darwin_ps() {
  local line st pg tty tp rest epoch
  line="$(ps -o stat=,pgid=,tty=,tpgid=,lstart= -p "$1" 2>/dev/null | head -1)"
  [ -n "$line" ] || return 1
  set -- $line; st="${1:-}"; pg="${2:-}"; tty="${3:-}"; tp="${4:-}"; shift 4 2>/dev/null || return 1; rest="$*"
  epoch="$(python3 -c 'import sys,time; print(int(time.mktime(time.strptime(sys.argv[1], "%a %b %d %H:%M:%S %Y"))))' "$rest" 2>/dev/null)" || return 1
  case "$epoch" in ''|*[!0-9]*) return 1 ;; esac
  printf '%s %s %s %s %s' "${st%%[!A-Za-z]*}" "$pg" "$tty" "$tp" "$epoch"
}

# bridge_proc_facts <pid> -> "state pgrp tty tpgid" ; rc 1 when the pid is gone. Linux: /proc stat
# fields 3, 5, 7, 8 (split AFTER the last ")" - comm may hold spaces). darwin: ps. tty is a name on
# darwin ("ttys003", "??" for none) and a number on Linux ("0" for none): compared for equality only.
bridge_proc_facts() {
  local pid="${1:-}" root="${BRIDGE_PROC_ROOT:-/proc}" stat rest f
  case "$pid" in ''|*[!0-9]*) return 1 ;; esac
  case "$(bridge_os)" in
    darwin) f="$(_bridge_darwin_ps "$pid")" || return 1; set -- $f; printf '%s %s %s %s' "$1" "$2" "$3" "$4" ;;
    *)
      stat="$(cat "$root/$pid/stat" 2>/dev/null)" || return 1
      rest="${stat##*) }"; set -- $rest; [ "$#" -ge 6 ] || return 1
      printf '%s %s %s %s' "$1" "$3" "$5" "$6" ;;
  esac
}

# bridge_proc_has_tty <tty> - rc 0 when the value names a terminal on this OS.
bridge_proc_has_tty() { case "${1:-}" in ''|0|'??'|'-') return 1 ;; esac; return 0; }

# bridge_os_birth <pid> -> "<boot_token>:<start>" ; rc 1 and empty when the pid is gone or a zombie.
# Linux: field 22 of /proc/<pid>/stat is starttime in clock ticks since boot. darwin: lstart in
# seconds. With the boot token in front it names one process for the life of the machine, which a
# bare pid does not. A ZOMBIE IS NOT ALIVE: state Z keeps its token until reaped, so a dead but
# unreaped Claude would have read as live forever (fifth pass E6).
bridge_os_birth() {
  local pid="${1:-}" root="${BRIDGE_PROC_ROOT:-/proc}" boot stat rest f
  case "$pid" in ''|*[!0-9]*) return 1 ;; esac
  boot="$(bridge_boot_id)" || return 1
  case "$(bridge_os)" in
    darwin)
      f="$(_bridge_darwin_ps "$pid")" || return 1; set -- $f
      case "$1" in Z*|X*) return 1 ;; esac
      printf '%s:%s' "$boot" "$5" ;;
    *)
      [ -r "$root/$pid/stat" ] || return 1
      stat="$(cat "$root/$pid/stat" 2>/dev/null)" || return 1
      rest="${stat##*) }"; set -- $rest
      [ "$#" -ge 20 ] || return 1
      case "$1" in Z|X) return 1 ;; esac
      printf '%s:%s' "$boot" "${20}" ;;
  esac
}

# bridge_env_has <pid> <NAME=value> - rc 0 when the process environment carries exactly that entry.
# Linux: /proc/<pid>/environ. darwin: ps -Eww appends the environment to the command line, one word
# per entry, so an entry whose value carries spaces cannot be matched there - the nonce is hex.
bridge_env_has() {
  local pid="${1:-}" entry="${2:-}" root="${BRIDGE_PROC_ROOT:-/proc}"
  case "$pid" in ''|*[!0-9]*) return 1 ;; esac; [ -n "$entry" ] || return 1
  case "$(bridge_os)" in
    darwin) ps -Eww -o command= -p "$pid" 2>/dev/null | tr ' ' '\n' | grep -qxF -- "$entry" ;;
    *)      LC_ALL=C tr '\0' '\n' < "$root/$pid/environ" 2>/dev/null | grep -qxF -- "$entry" ;;   # -F: state text is never a pattern
  esac
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

# ---- the observer's line, validated as the contract it is ----------------------------------------
# bridge_line_valid <line> <id> - rc 0 and BL_* set when <line> is exactly the fifteen-field line
# linux/bridge-observe.sh prints for <id>; rc 1 (and BL_* emptied) for anything else. ONE validator for
# every consumer (the supervisor, liveness-host; the watch mirrors it in JS), so a malformed answer cannot
# become a decision in one reader and not another (advisor K3-K6, L1):
#   - exactly one line, exactly fifteen US fields, the id asked about (slug grammar)
#   - answer and gen_state from their closed vocabularies, and a pair the adapter can emit:
#     no-process/wait-veto only beside none|bootstrap|gone-*, grace only beside grace
#   - identified:* is TYPED: pid, procStart, nameSince, mtime, inode numeric and non-empty (inode > 0),
#     birth "<token>:<digits>", sessionId non-empty, and the pane EXACTLY "<id>:@<n>.%<m>" - rebuilt from
#     its parsed parts and compared whole, so "<id>:@0.%0.%1" and "<id>:@0.%0:@1.%1" are not panes (K6)
#   - every other answer carries NO candidate field
#   - launch_child in {"", 0, 1}
bridge_line_valid() {
  local l="${1:-}" id="${2:-}" n win pane rest
  BL_ID=""; BL_ANS=""; BL_PID=""; BL_BIRTH=""; BL_PANE=""; BL_NAME=""; BL_SINCE=""; BL_GEN=""; BL_CLASSES=""; BL_CHILD=""; BL_PS=""; BL_SID=""; BL_MTIME=""; BL_TUPLE=""; BL_INODE=""
  case "$l" in *"$US"*) : ;; *) return 1 ;; esac
  case "$l" in *$'\n'*) return 1 ;; esac
  n="$(printf '%s' "$l" | tr -cd "$US" | wc -c | tr -d ' ')"; [ "$n" -eq 14 ] || return 1
  IFS="$US" read -r BL_ID BL_ANS BL_PID BL_BIRTH BL_PANE BL_NAME BL_SINCE BL_GEN BL_CLASSES BL_CHILD BL_PS BL_SID BL_MTIME BL_TUPLE BL_INODE <<EOF
$l
EOF
  case "$id" in ''|*[!a-z0-9-]*) _bridge_line_reset; return 1 ;; esac
  [ "$BL_ID" = "$id" ] || { _bridge_line_reset; return 1; }
  case "$BL_ANS" in identified:managed|identified:orphan|identified:moved|no-process|unknown|wait-veto|grace|uninspectable|not-applicable) : ;; *) _bridge_line_reset; return 1 ;; esac
  case "$BL_GEN" in none|gone-receipt|gone-noreceipt|alive|grace|bootstrap) : ;; *) _bridge_line_reset; return 1 ;; esac
  case "$BL_ANS" in
    no-process|wait-veto) case "$BL_GEN" in none|bootstrap|gone-receipt|gone-noreceipt) : ;; *) _bridge_line_reset; return 1 ;; esac ;;
    grace) [ "$BL_GEN" = grace ] || { _bridge_line_reset; return 1; } ;;
  esac
  case "$BL_CHILD" in ''|0|1) : ;; *) _bridge_line_reset; return 1 ;; esac
  case "$BL_ANS" in
    identified:*)
      case "$BL_PID"   in ''|*[!0-9]*)   _bridge_line_reset; return 1 ;; esac
      case "$BL_PS"    in ''|*[!0-9]*)   _bridge_line_reset; return 1 ;; esac
      case "$BL_SINCE" in ''|*[!0-9]*)   _bridge_line_reset; return 1 ;; esac
      case "$BL_MTIME" in ''|*[!0-9]*)   _bridge_line_reset; return 1 ;; esac
      case "$BL_INODE" in ''|*[!0-9]*|0) _bridge_line_reset; return 1 ;; esac
      case "$BL_BIRTH" in *:*) : ;; *) _bridge_line_reset; return 1 ;; esac
      [ -n "${BL_BIRTH%%:*}" ] || { _bridge_line_reset; return 1; }
      case "${BL_BIRTH##*:}" in ''|*[!0-9]*) _bridge_line_reset; return 1 ;; esac
      [ -n "$BL_SID" ] || { _bridge_line_reset; return 1; }
      # THE PANE, EXACTLY: <id>:@<digits>.%<digits>, rebuilt and compared whole (K6)
      case "$BL_PANE" in "$id:@"*) : ;; *) _bridge_line_reset; return 1 ;; esac
      rest="${BL_PANE#"$id":@}"
      case "$rest" in *.%*) : ;; *) _bridge_line_reset; return 1 ;; esac
      win="${rest%%.%*}"; pane="${rest#*.%}"
      case "$win"  in ''|*[!0-9]*) _bridge_line_reset; return 1 ;; esac
      case "$pane" in ''|*[!0-9]*) _bridge_line_reset; return 1 ;; esac
      [ "$BL_PANE" = "$id:@$win.%$pane" ] || { _bridge_line_reset; return 1; } ;;
    *) [ -z "$BL_PID$BL_BIRTH$BL_PANE$BL_PS$BL_SID$BL_INODE" ] || { _bridge_line_reset; return 1; } ;;
  esac
  return 0
}
_bridge_line_reset() { BL_ID=""; BL_ANS=""; BL_PID=""; BL_BIRTH=""; BL_PANE=""; BL_NAME=""; BL_SINCE=""; BL_GEN=""; BL_CLASSES=""; BL_CHILD=""; BL_PS=""; BL_SID=""; BL_MTIME=""; BL_TUPLE=""; BL_INODE=""; }

# ---- generation: <state-dir>/<id>.generation, key=value, written atomically -----------------
# HISTORY AND BOOTSTRAP, NEVER A SECOND TRUTH. When a verified-live bridge file exists ITS
# fields win; the generation remembers what we launched and what we saw, so a file left
# behind by KILL -9 can be recognised (by pid:procStart - a dead process has no birth) and
# a fresh launch can be told apart from a stranger (by the nonce, in the adapter).
bridge_gen_path() { printf '%s/%s.generation' "$1" "$2"; }
bridge_gen_get()  { local f; f="$(bridge_gen_path "$1" "$2")"; [ -f "$f" ] || return 1; sed -n "s/^$3=//p" "$f" | head -1; }
_bridge_gen_hist() { sed -n 's/^history=//p' "$(bridge_gen_path "$1" "$2")" 2>/dev/null | head -1; }
# A HISTORY ENTRY IS pid:procStart:birth, AND birth IS boot_id:ticks - it contains a colon.
# Splitting on the LAST colon returned only the ticks (B2). Strip two fields from the
# front and keep the rest whole.
_bridge_hist_pid()   { printf '%s' "${1%%:*}"; }
_bridge_hist_ps()    { local r="${1#*:}"; printf '%s' "${r%%:*}"; }
_bridge_hist_birth() { local r="${1#*:}"; printf '%s' "${r#*:}"; }
# AN EMPTY KEY NEVER MATCHES. "$(bridge_os_birth $gone)" is empty and so is a birth that was
# never recorded; two empties compared equal and a dead process read as alive (third pass 3).
# bridge_gen_matches_live <sd> <id> <pid> <birth> [procStart] - the generation knows this LIVE process.
# THE VENDOR'S procStart IS IDENTITY EVIDENCE TOO (spec §1 "persisted launch generation"; advisor K4):
# when the generation recorded a procStart for this pid+birth and the caller supplies one, the two must
# agree - a contradiction is NOT a match, so the candidate reads unclassifiable and the row unknown,
# never latest-wins. A generation without a procStart (the first bind, a bootstrap) still matches.
bridge_gen_matches_live() { # sd id pid birth procStart - all five required (K5: no four-argument bypass)
  [ -n "${3:-}" ] && [ -n "${4:-}" ] && [ -n "${5:-}" ] || return 1
  local gps; gps="$(bridge_gen_get "$1" "$2" procStart 2>/dev/null)"
  if [ "$(bridge_gen_get "$1" "$2" pid 2>/dev/null)" = "$3" ] && [ "$(bridge_gen_get "$1" "$2" birth 2>/dev/null)" = "$4" ]; then
    [ -z "$gps" ] || [ "$gps" = "$5" ] || return 1     # a generation without a procStart (first bind) still matches
    return 0
  fi
  local h hps; for h in $(_bridge_gen_hist "$1" "$2"); do
    [ "$(_bridge_hist_pid "$h")" = "$3" ] && [ "$(_bridge_hist_birth "$h")" = "$4" ] || continue
    hps="$(_bridge_hist_ps "$h")"; [ "$hps" = - ] && hps=""
    [ -z "$hps" ] || [ "$hps" = "$5" ] || return 1
    return 0
  done
  return 1
}
bridge_gen_matches_dead() { # sd id pid procStart
  [ -n "${3:-}" ] && [ -n "${4:-}" ] || return 1
  [ "$(bridge_gen_get "$1" "$2" pid 2>/dev/null)" = "$3" ] && [ "$(bridge_gen_get "$1" "$2" procStart 2>/dev/null)" = "$4" ] && return 0
  local h; for h in $(_bridge_gen_hist "$1" "$2"); do [ "$(_bridge_hist_pid "$h")" = "$3" ] && [ "$(_bridge_hist_ps "$h")" = "$4" ] && return 0; done
  return 1
}
# THE GENERATION HAS A CLOSED VOCABULARY. A well-formed but unknown key (a typo such as
# brith=) is refused with the whole write, not persisted as a silent new fact - the first
# version checked only the grammar, so a typo would have looked like a field forever (fourth
# pass 11). `history` is written by this function itself and is not a caller's key.
BRIDGE_GEN_KEYS=" pid birth procStart uid sessionId launch_ms launch_uptime_ms launch_boot_id launch_nonce launch_pane_pid launch_pane_birth launch_inodes spawn_state grace_rounds bridge_name bridge_nameSince bridge_mtime bridge_inode applied applied_at applied_nameSince pending_for pending_since pending_name rename_tries stop_intent stop_receipt census "
_bridge_gen_key_ok() { case "$1" in *[!A-Za-z0-9_]*|'') return 1 ;; esac; case "$BRIDGE_GEN_KEYS" in *" $1 "*) return 0 ;; *) return 1 ;; esac; }

# bridge_gen_write <sd> <id> key=value ... - atomic (tmp + mv); a DIFFERENT pid pushes the old
# triple into history, bounded to the last 8; a key outside the vocabulary refuses the WHOLE write.
bridge_gen_write() {
  local dir="$1" id="$2" f tmp kv k v old_pid old_ps old_b hist; shift 2
  f="$(bridge_gen_path "$dir" "$id")"; tmp="$f.tmp.$$"; mkdir -p "$dir"
  old_pid="$(bridge_gen_get "$dir" "$id" pid 2>/dev/null)"; old_ps="$(bridge_gen_get "$dir" "$id" procStart 2>/dev/null)"; old_b="$(bridge_gen_get "$dir" "$id" birth 2>/dev/null)"
  hist="$(_bridge_gen_hist "$dir" "$id")"
  : > "$tmp"; [ -f "$f" ] && grep -v '^history=' "$f" > "$tmp"
  for kv in "$@"; do
    k="${kv%%=*}"; v="${kv#*=}"
    _bridge_gen_key_ok "$k" || { echo "bridge: generation key '$k' is not in the vocabulary; nothing written" >&2; rm -f "$tmp"; return 64; }
    grep -v "^$k=" "$tmp" > "$tmp.2"; mv "$tmp.2" "$tmp"; printf '%s=%s\n' "$k" "$v" >> "$tmp"
    if [ "$k" = pid ] && [ -n "$old_pid" ] && [ "$v" != "$old_pid" ]; then hist="$hist $old_pid:${old_ps:--}:${old_b:--}"; fi
  done
  hist="$(printf '%s\n' $hist | grep . | tail -8 | tr '\n' ' ')"; hist="${hist% }"
  [ -n "$hist" ] && printf 'history=%s\n' "$hist" >> "$tmp"
  mv -f "$tmp" "$f"
}

# ---- keyed two-round suspect (B6) --------------------------------------------------------------
# THE SAME KEY MUST BE SEEN TWICE IN A ROW. A boolean marker let orphan A license the kill of
# orphan B; the key carries the intended action and its target - every argument, in order,
# "-" for an empty one - and any different key resets the count.
bridge_suspect_key() { local out="" a; for a in "$@"; do out="${out:+$out }${a:--}"; done; printf '%s' "$out"; }
# THE FILE IS WRITTEN ONLY WHEN THE KEY CHANGES, so its mtime is the FIRST sighting of the key
# that is now confirmed - the supervisor's debris gate reads that mtime as "when this session
# was first suspected dead" (log text, never a verdict). A rewrite on every sighting reset it
# to "now" each round and the age it reported was always zero.
bridge_suspect_confirmed() { # <file> <key> -> rc 0 when the file already held exactly this key
  local f="$1" key="$2" prev=""
  [ -f "$f" ] && prev="$(cat "$f")"
  [ "$prev" = "$key" ] && return 0
  printf '%s\n' "$key" > "$f"
  return 1
}
