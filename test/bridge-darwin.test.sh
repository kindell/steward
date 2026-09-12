#!/bin/bash
# The OS facts layer's DARWIN backend, run on any host through ps/sysctl/uname shims. MEASURED on minin
# 2026-09-12 (macOS arm64): no /proc, no pidfd - so every process fact there comes from ps(1) and
# sysctl(8). These claims pin the words the backend produces and the kill helper's darwin branch.
set -u
here="$(CDPATH= cd -- "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
BIN="$T/bin"; mkdir -p "$BIN"; export PSTAB="$T/pstab" ENVTAB="$T/envtab" REC="$T/rec"
pass=0; fail=0
ok() { pass=$((pass+1)); echo "  ok   $1"; }
bad() { fail=$((fail+1)); echo "  FAIL $1"; echo "     wanted '$3', got '$2'"; }
is() { [ "$2" = "$3" ] && ok "$1" || bad "$1" "$2" "$3"; }
has() { case "$2" in *"$3"*) ok "$1" ;; *) bad "$1" "$2" "contains $3" ;; esac; }

# ---- shims: darwin's ps, sysctl and uname, table-driven ----
cat > "$BIN/uname" <<'SH'
#!/bin/bash
echo Darwin
SH
cat > "$BIN/sysctl" <<'SH'
#!/bin/bash
[ "$1" = "-n" ] && [ "$2" = "kern.boottime" ] && { echo "{ sec = 1789000000, usec = 424242 } Fri Sep 11 12:26:40 2026"; exit 0; }
exit 1
SH
# PSTAB lines: pid|state|pgid|tty|tpgid|lstart ; ENVTAB lines: pid|word word word (ps -Eww appends env words)
cat > "$BIN/ps" <<'SH'
#!/bin/bash
fmt=""; pid=""; env=""
while [ $# -gt 0 ]; do case "$1" in -o) fmt="$2"; shift 2 ;; -p) pid="$2"; shift 2 ;; -Eww) env=1; shift ;; *) shift ;; esac; done
line="$(grep "^$pid|" "$PSTAB" 2>/dev/null | head -1)"; [ -n "$line" ] || exit 1
IFS='|' read -r p st pg tty tp lstart <<<"$line"
case "$fmt" in
  'stat=,pgid=,tty=,tpgid=,lstart=') printf '%s %s %s %s %s\n' "$st" "$pg" "$tty" "$tp" "$lstart" ;;
  'stat=,lstart=') printf '%s %s\n' "$st" "$lstart" ;;
  'command=') printf 'claude --resume x %s\n' "$(grep "^$pid|" "$ENVTAB" 2>/dev/null | cut -d'|' -f2-)" ;;
  'ppid=') echo 1 ;;
  *) exit 1 ;;
esac
SH
chmod 755 "$BIN"/*
export PATH="$BIN:$PATH" BRIDGE_OS=darwin
. "$here/lib/bridge.sh"
epoch_of() { python3 -c 'import sys,time; print(int(time.mktime(time.strptime(sys.argv[1], "%a %b %d %H:%M:%S %Y"))))' "$1"; }
printf '%s\n' '4243|S+|4242|ttys003|4242|Sat Sep 12 07:44:17 2026' '4300|Z|4300|??|4300|Sat Sep  2 01:02:03 2026' '4400|S|4400|??|4400|Sat Sep 12 07:00:00 2026' > "$PSTAB"
printf '%s\n' '4243|STEWARD_LAUNCH_NONCE=0123456789abcdef0123456789abcdef HOME=/x' > "$ENVTAB"

echo "== 1. the OS is measured, and overridable =="
is "1a BRIDGE_OS=darwin" "$(bridge_os)" "darwin"
is "1b uname says Darwin when the override is absent" "$(BRIDGE_OS= bridge_os)" "darwin"
is "1c anything else is linux" "$(BRIDGE_OS=FreeBSD bridge_os)" "linux"

echo "== 2. boot token and uptime from sysctl =="
is "2a boot token = kern.boottime seconds" "$(bridge_boot_id)" "1789000000"
up="$(bridge_uptime_ms)"; case "$up" in ''|*[!0-9]*) bad "2b uptime is digits" "$up" "digits" ;; *) ok "2b uptime is digits" ;; esac
[ "${up:-0}" -ge $(( ( $(date +%s) - 1789000000 - 5 ) * 1000 )) ] && ok "2c uptime = now - boot" || bad "2c uptime = now - boot" "$up" "about $(( ( $(date +%s) - 1789000000 ) * 1000 ))"

echo "== 3. birth: boot token + lstart seconds; a zombie is not alive; a missing pid is nothing =="
want="1789000000:$(epoch_of 'Sat Sep 12 07:44:17 2026')"
is "3a birth of a live process" "$(bridge_os_birth 4243)" "$want"
bridge_os_birth 4300 >/dev/null; is "3b a zombie (state Z) is rc 1" "$?" "1"
bridge_os_birth 9999 >/dev/null; is "3c a missing pid is rc 1" "$?" "1"
is "3d and prints nothing" "$(bridge_os_birth 9999)" ""
has "3e the token passes the line validator's birth shape" "$(printf '%s' "$want" | grep -cE '^[0-9A-Za-z-]+:[0-9]+$')" "1"
is "3f lstart with a two-space day parses" "$(printf '%s\n' '4400|S|4400|??|4400|Sat Sep  2 01:02:03 2026' > "$PSTAB.2"; PSTAB="$PSTAB.2" bridge_os_birth 4400)" "1789000000:$(epoch_of 'Sat Sep  2 01:02:03 2026')"

echo "== 4. process facts: state pgrp tty tpgid, and tty names =="
is "4a facts" "$(bridge_proc_facts 4243)" "S 4242 ttys003 4242"
is "4b state letter only (S+ -> S)" "$(bridge_proc_facts 4243 | cut -d' ' -f1)" "S"
bridge_proc_has_tty ttys003 && ok "4c ttys003 is a tty" || bad "4c ttys003 is a tty" "1" "0"
bridge_proc_has_tty '??' && bad "4d ?? is no tty" "0" "1" || ok "4d ?? is no tty"
bridge_proc_has_tty 0 && bad "4e 0 is no tty (linux word)" "0" "1" || ok "4e 0 is no tty (linux word)"
bridge_proc_facts 9999 >/dev/null; is "4f missing pid rc 1" "$?" "1"

echo "== 5. environment through ps -Eww =="
bridge_env_has 4243 STEWARD_LAUNCH_NONCE=0123456789abcdef0123456789abcdef && ok "5a the nonce is found" || bad "5a the nonce is found" "1" "0"
bridge_env_has 4243 STEWARD_LAUNCH_NONCE=ffff && bad "5b another value is not" "0" "1" || ok "5b another value is not"
bridge_env_has 4243 STEWARD_LAUNCH_NONCE=0123456789abcdef0123456789abcde && bad "5c a prefix is not (-x)" "0" "1" || ok "5c a prefix is not (-x)"
bridge_env_has 4400 STEWARD_LAUNCH_NONCE=0123456789abcdef0123456789abcdef && bad "5d a process without it" "0" "1" || ok "5d a process without it"

echo "== 6. the kill helper's darwin branch: birth re-read before the signal, no pin, recorder receives =="
K="$here/linux/bridge-kill.py"
cat > "$T/recorder" <<'SH'
#!/bin/bash
printf '%s %s\n' "$1" "$2" >> "$REC"; [ -f "$REC.fail" ] && exit 1; exit 0
SH
chmod 755 "$T/recorder"
run() { : > "$REC"; OUT="$(STEWARD_KILL="$T/recorder" BRIDGE_OS=darwin STEWARD_FORCE_NO_PIDFD=1 python3 "$K" "$@" 2>"$T/err")"; RC=$?; ERR="$(cat "$T/err")"; }
run 4243 "$want"; is "6a match: rc 0" "$RC" "0"; is "6b recorder got pid and TERM" "$(cat "$REC")" "4243 TERM"; has "6c the receipt says no pin" "$OUT" "no pin"
run 4243 "$want" KILL; is "6d explicit signal name reaches the recorder" "$(cat "$REC")" "4243 KILL"
run 4243 "1789000000:1"; is "6e birth mismatch: rc 65" "$RC" "65"; is "6f nothing recorded" "$(cat "$REC")" ""; has "6g says reused" "$ERR" "reused"
run 4300 "1789000000:$(epoch_of 'Sat Sep  2 01:02:03 2026')"; is "6h zombie: rc 65" "$RC" "65"; has "6i says zombie" "$ERR" "zombie"
run 9999 "$want"; is "6j gone: rc 65" "$RC" "65"; has "6k says gone" "$ERR" "gone"
run 4243 ""; is "6l empty birth: rc 65" "$RC" "65"
touch "$REC.fail"; run 4243 "$want"; is "6m a failing recorder is no delivery: rc 65" "$RC" "65"; rm -f "$REC.fail"
OUT="$(STEWARD_KILL="$T/recorder" BRIDGE_OS=linux STEWARD_FORCE_NO_PIDFD=1 python3 "$K" 4243 "$want" 2>"$T/err")"; is "6n linux without pidfd is still 69 - the darwin branch is darwin's only" "$?" "69"

echo; echo "$pass passed, $fail failed"; [ "$fail" -eq 0 ]
