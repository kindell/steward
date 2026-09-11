#!/bin/bash
# test/listeners.test.sh - the loopback listener probe, on its own.
#
# WHY IT IS ITS OWN FILE NOW. The probe lived inside linux/session-approve.sh,
# which runs top to bottom against a live tmux pane and a live bus; nothing
# could exercise it without a session. So the one thing it most needed to be
# asked - what do you do when you cannot measure? - was never asked, and the
# answer turned out to be "report a PASS".
#
# MEASURED 2026-09-11 on macOS by the session being approved: the probe is
# built on ss(8), which does not exist on darwin. Every pipeline yielded the
# empty string, so N=0, account=0, session=0, and the criterion "no listeners
# started by THIS SESSION" was true because nothing had been counted. lsof on
# the same host at the same moment showed NINE loopback listeners. The verdict
# happened to be right - that session had started nothing - but by luck.
#
# The file's own comment block argues at length that the unknown must become a
# number rather than a void. On that host the whole surface became a void and
# the script called it an approval.
set -u
here="$(CDPATH= cd -- "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
pass=0; fail=0
ok()  { pass=$((pass+1)); printf '  ok   %s\n' "$1"; }
bad() { fail=$((fail+1)); printf '  FAIL %s\n     %s\n' "$1" "${2:-}"; }
is()  { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "wanted '$3', got '$2'"; fi; }
has() { case "$2" in *"$3"*) ok "$1" ;; *) bad "$1" "missing '$3' in: $2" ;; esac; }

FX="$(mktemp -d)"; trap 'rm -rf "$FX"' EXIT
mkdir -p "$FX/bin"
# shellcheck source=/dev/null
. "$here/lib/listeners.sh"

# A STUB PER TOOL, in a directory we put FIRST on PATH. The probe must be asked
# what it does with each tool present and with neither, and a test that used the
# host's real ss or lsof would measure the host.
mk() { printf '#!/bin/bash\n%s\n' "$2" > "$FX/bin/$1"; chmod +x "$FX/bin/$1"; }

echo "== 1. neither tool present: a criterion that cannot be measured is not a pass =="
# NOT IN A COMMAND SUBSTITUTION. listeners_probe sets its results in the
# CALLER's shell, and a substitution is a subshell - captured that way every
# variable below would read as whatever it was before the call. The credential
# seam documents this trap at length; the first version of this suite walked
# into it anyway.
run_probe() { PATH="$1" listeners_probe 2>"$FX/err"; rc=$?; out="$(cat "$FX/err")"; }
run_probe "$FX/bin"
is  "1a rc is 70, not 0"                    "$rc" "70"
is  "1b LISTENERS_TOOL says so"             "$LISTENERS_TOOL" "none"
has "1c and it names both tools it wanted"  "$out" "ss"
has "1d ...both of them"                    "$out" "lsof"
# THE NUMBERS MUST NOT BE ZERO. Zero is an answer, and answering zero here is
# exactly the defect: it is indistinguishable from a clean machine.
is  "1e the count is not a number at all"   "$LISTENERS_N" ""
is  "1f nor is the account's"               "$LISTENERS_ACCOUNT" ""

echo "== 2. ss present (the Linux path), three listeners, one of them ours =="
mk ss 'case "$*" in
  *-ltnp*) printf "LISTEN 0 4096 127.0.0.1:8787 0.0.0.0:* users:((\\"python\\",pid=111,fd=3))\n"
           printf "LISTEN 0 4096 [::1]:8791 [::]:* users:((\\"node\\",pid=222,fd=7))\n" ;;
  *-ltn*)  printf "LISTEN 0 4096 127.0.0.1:8787 0.0.0.0:*\n"
           printf "LISTEN 0 4096 [::1]:8791 [::]:*\n"
           printf "LISTEN 0 4096 127.0.0.1:9222 0.0.0.0:*\n" ;;
esac'
run_probe "$FX/bin:$PATH"
is "2a rc 0"                         "$rc" "0"
is "2b the tool is named"            "$LISTENERS_TOOL" "ss"
is "2c N counts the whole surface"   "$LISTENERS_N" "3"
is "2d and the account's are fewer"  "$LISTENERS_ACCOUNT" "2"
has "2e the rows carry their pids"   "$LISTENERS_ROWS" "pid=111"

echo "== 3. lsof present and ss absent (the darwin path) =="
rm -f "$FX/bin/ss"
mk lsof 'case "$*" in
  *-u*) printf "python  111 someone  3u  IPv4 0x1  0t0  TCP 127.0.0.1:8787 (LISTEN)\n"
        printf "node    222 someone  7u  IPv6 0x2  0t0  TCP [::1]:8791 (LISTEN)\n" ;;
  *)    printf "python  111 someone  3u  IPv4 0x1  0t0  TCP 127.0.0.1:8787 (LISTEN)\n"
        printf "node    222 someone  7u  IPv6 0x2  0t0  TCP [::1]:8791 (LISTEN)\n"
        printf "Chrome  333 other    9u  IPv4 0x3  0t0  TCP 127.0.0.1:9222 (LISTEN)\n" ;;
esac'
run_probe "$FX/bin:$PATH"
is "3a rc 0"                        "$rc" "0"
is "3b the tool is named"           "$LISTENERS_TOOL" "lsof"
is "3c N counts the whole surface"  "$LISTENERS_N" "3"
is "3d the account's are fewer"     "$LISTENERS_ACCOUNT" "2"
has "3e the rows carry their pids"  "$LISTENERS_ROWS" "pid=111"
# NON-LOOPBACK IS NOT THIS PROBE'S QUESTION and must not inflate the count: a
# listener bound outward is a different conversation with a different remedy.
mk lsof 'printf "srv  444 someone  3u  IPv4 0x9  0t0  TCP 192.0.2.7:443 (LISTEN)\n"'
run_probe "$FX/bin:$PATH"
is "3f an outward-bound listener is not counted" "$LISTENERS_N" "0"

echo "== 4. ss wins when both are present, so a Linux host measures as before =="
mk ss 'printf "LISTEN 0 4096 127.0.0.1:8787 0.0.0.0:*\n"'
mk lsof 'printf "x 1 y 3u IPv4 0x1 0t0 TCP 127.0.0.1:9999 (LISTEN)\n"'
run_probe "$FX/bin:$PATH"
is "4a the tool is ss" "$LISTENERS_TOOL" "ss"
is "4b and the count is ss's" "$LISTENERS_N" "1"

printf '\n  %d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
