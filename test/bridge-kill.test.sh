#!/bin/bash
# test/bridge-kill.test.sh - the process is PINNED before its birth is read, and the signal goes
# to the pin (D6). A bare `kill <pid>` races: between our check and our signal the pid can be
# reused, and the signal lands on a stranger. pidfd_open pins one process incarnation; the
# birth token read afterwards is then that incarnation's; and pidfd_send_signal cannot hit
# anything else.
#
# THE PROCESS IS REAL, THE STAT IS A FIXTURE. pidfd_open needs a living pid, so the claims pin
# a sleep of their own; /proc is BRIDGE_PROC_ROOT so the birth token is chosen by the claim.
# The signal itself goes to STEWARD_KILL, a recorder, so nothing here is ever signalled.
set -u
here="$(CDPATH= cd -- "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
K="$here/linux/bridge-kill.py"
pass=0; fail=0
ok()  { pass=$((pass+1)); printf '  ok   %s\n' "$1"; }
bad() { fail=$((fail+1)); printf '  FAIL %s\n     %s\n' "$1" "${2:-}"; }
is()  { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "wanted '$3', got '$2'"; fi; }
has() { case "$2" in *"$3"*) ok "$1" ;; *) bad "$1" "missing '$3' in: $2" ;; esac; }
T="$(mktemp -d)"; trap 'rm -rf "$T"; kill "$SLEEPER" 2>/dev/null' EXIT
PROC="$T/proc"; mkdir -p "$PROC/sys/kernel/random"; printf 'boot-k\n' > "$PROC/sys/kernel/random/boot_id"
REC="$T/rec.log"; printf '#!/bin/sh\nprintf "%%s\\n" "$*" >> "%s"\n' "$REC" > "$T/recorder"; chmod 755 "$T/recorder"
sleep 300 & SLEEPER=$!
stat_for() { mkdir -p "$PROC/$1"; printf '%s (sleep) %s 1 1 1 0 -1 0 0 0 0 0 0 0 0 0 20 0 1 0 %s 0 0 0\n' "$1" "${3:-S}" "$2" > "$PROC/$1/stat"; }
run() { : > "$REC"; OUT="$(BRIDGE_PROC_ROOT="$PROC" STEWARD_KILL="$T/recorder" python3 "$K" "$@" 2>"$T/err")"; RC=$?; ERR="$(cat "$T/err")"; }

echo "== 1. match: pinned, birth equal, recorder receives pid and signal =="
stat_for "$SLEEPER" 4242
run "$SLEEPER" boot-k:4242; is "1a rc 0" "$RC" "0"; is "1b recorder got <pid> TERM" "$(cat "$REC")" "$SLEEPER TERM"
is "1c receipt line" "$OUT" "killed $SLEEPER boot-k:4242 TERM"
run "$SLEEPER" boot-k:4242 KILL; is "1d explicit signal name" "$(cat "$REC")" "$SLEEPER KILL"
run "$SLEEPER" boot-k:4242 SIGTERM; is "1e SIG-prefixed name is the same signal" "$(cat "$REC")" "$SLEEPER TERM"
run "$SLEEPER" boot-k:4242 15; is "1f a number names the signal" "$(cat "$REC")" "$SLEEPER TERM"

echo "== 2. refusals: rc 65, recorder never called =="
run "$SLEEPER" boot-k:9999; is "2a ticks differ -> 65" "$RC" "65"; is "2b not signalled" "$(cat "$REC")" ""; has "2c says mismatch" "$ERR" "birth"
run "$SLEEPER" boot-OTHER:4242; is "2d boot id differs -> 65" "$RC" "65"; is "2e not signalled" "$(cat "$REC")" ""
run "$SLEEPER" ""; is "2f empty birth -> 65" "$RC" "65"; is "2g not signalled" "$(cat "$REC")" ""
stat_for "$SLEEPER" 4242 Z; run "$SLEEPER" boot-k:4242; is "2h a zombie is refused -> 65" "$RC" "65"; is "2i not signalled" "$(cat "$REC")" ""; has "2j says zombie" "$ERR" "zombie"
stat_for "$SLEEPER" 4242
sleep 0.01 & GONE=$!; wait "$GONE"; stat_for "$GONE" 4242
run "$GONE" boot-k:4242; is "2k gone pid (stat fixture present, no process) -> 65" "$RC" "65"; is "2l not signalled" "$(cat "$REC")" ""; has "2m says gone" "$ERR" "gone"
rm -rf "$PROC/$SLEEPER"; run "$SLEEPER" boot-k:4242; is "2n pinned but no stat -> 65" "$RC" "65"; is "2o not signalled" "$(cat "$REC")" ""
stat_for "$SLEEPER" 4242

echo "== 3. usage: rc 64 =="
run "$SLEEPER" boot-k:4242 BOGUS; is "3a bad signal name -> 64" "$RC" "64"; is "3b not signalled" "$(cat "$REC")" ""
run abc boot-k:4242; is "3c bad pid -> 64" "$RC" "64"
run 0 boot-k:4242; is "3d pid 0 -> 64" "$RC" "64"
run -1 boot-k:4242; is "3e negative pid -> 64" "$RC" "64"
run; is "3f no args -> 64" "$RC" "64"

echo "== 4. no pidfd -> rc 69, NO fallback to kill =="
OUT="$(BRIDGE_PROC_ROOT="$PROC" STEWARD_KILL="$T/recorder" STEWARD_FORCE_NO_PIDFD=1 python3 "$K" "$SLEEPER" boot-k:4242 2>"$T/err")"; RC=$?
is "4a rc 69" "$RC" "69"; has "4b says pidfd unavailable" "$(cat "$T/err")" "pidfd unavailable"; is "4c not signalled" "$(cat "$REC")" ""
is "4d the sleeper is still alive (nothing was ever really signalled)" "$(kill -0 "$SLEEPER" 2>/dev/null && echo alive)" "alive"

printf '\n%d passed, %d failed\n' "$pass" "$fail"; [ "$fail" -eq 0 ]
