#!/bin/bash
# test/bridge-generation.test.sh - the generation is history and bootstrap, never a
# second truth; a DEAD file is matched on pid:procStart; a birth with a colon in it
# round-trips (B2); an EMPTY birth never matches anything (third pass 3); and a suspect
# remembers WHAT it suspected (B6).
#
# WHY pid:procStart FOR THE DEAD. A bridge file left behind by KILL -9 names a process
# that no longer exists, so /proc cannot yield its birth token. The vendor's procStart
# is the only stable thing the file carries, and the generation keeps it beside the
# birth for exactly this comparison.
#
# WHY A COLON IS DANGEROUS. A birth token is boot_id:ticks - it contains a colon. A
# history entry is pid:procStart:birth. Splitting on the LAST colon returned only the
# ticks and the live match failed its own claim (B2). The matchers strip two fields
# from the front and keep the rest whole.
#
# WHY EMPTY NEVER MATCHES. "$(bridge_os_birth $gone)" is empty, and so is the birth of
# a generation that recorded none. Two empties compare equal, and a dead process reads
# as alive (third pass 3). Every matcher refuses an empty key.
set -u
here="$(CDPATH= cd -- "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
pass=0; fail=0
ok()  { pass=$((pass+1)); printf '  ok   %s\n' "$1"; }
bad() { fail=$((fail+1)); printf '  FAIL %s\n     %s\n' "$1" "${2:-}"; }
is()  { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "wanted '$3', got '$2'"; fi; }
. "$here/lib/bridge.sh" || { echo "cannot source lib/bridge.sh"; exit 1; }
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT; ID="s-0000000000000001"

echo "== 1. absent, write, read, merge =="
bridge_gen_get "$T" "$ID" pid >/dev/null 2>&1; is "1a absent rc 1" "$?" "1"
bridge_gen_write "$T" "$ID" pid=100 birth=boot-x:1 procStart=500 uid=1001 launch_ms=1789000000000
is "1b pid" "$(bridge_gen_get "$T" "$ID" pid)" "100"
is "1c launch_ms" "$(bridge_gen_get "$T" "$ID" launch_ms)" "1789000000000"
bridge_gen_write "$T" "$ID" applied="Alpha→Beta"
is "1d merge keeps pid" "$(bridge_gen_get "$T" "$ID" pid)" "100"; is "1e applied" "$(bridge_gen_get "$T" "$ID" applied)" "Alpha→Beta"
bridge_gen_write "$T" "$ID" applied="Point→Chalmers→HR Pilot"; is "1f spaces and arrows survive" "$(bridge_gen_get "$T" "$ID" applied)" "Point→Chalmers→HR Pilot"
bridge_gen_write "$T" "$ID" "bad key=1" >/dev/null 2>&1; is "1g bad key rc 64" "$?" "64"
is "1h bad key wrote nothing" "$(bridge_gen_get "$T" "$ID" applied)" "Point→Chalmers→HR Pilot"
# A WELL-FORMED TYPO IS THE DANGEROUS ONE: it passes the grammar and would become a fact.
bridge_gen_write "$T" "$ID" brith=boot-z:9 >/dev/null 2>&1; is "1i typo key (brith=) rc 64" "$?" "64"
is "1j typo key not persisted (read from the file, not via get: get is rc 1 only when the FILE is absent)" "$(grep -c '^brith=' "$T/$ID.generation")" "0"
bridge_gen_write "$T" "$ID" pid=100 brith=1 >/dev/null 2>&1; is "1k one bad key refuses the WHOLE write" "$?" "64"
is "1l pid unchanged after the refused write" "$(bridge_gen_get "$T" "$ID" pid)" "100"
for k in launch_uptime_ms launch_boot_id launch_inodes spawn_state stop_intent; do bridge_gen_write "$T" "$ID" "$k=x" >/dev/null 2>&1; is "1m v4 key $k accepted" "$?" "0"; done
bridge_gen_write "$T" "$ID" history=hacked >/dev/null 2>&1; is "1n history is not a caller key" "$?" "64"

echo "== 2. live and dead matching, colon-safe =="
bridge_gen_matches_live "$T" "$ID" 100 boot-x:1; is "2a current live, colon in birth" "$?" "0"
bridge_gen_write "$T" "$ID" pid=101 birth=boot-x:2 procStart=501
bridge_gen_matches_live "$T" "$ID" 100 boot-x:1;  is "2b old live pair in history (B2)" "$?" "0"
bridge_gen_matches_live "$T" "$ID" 100 boot-y:1;  is "2c wrong boot id no" "$?" "1"
bridge_gen_matches_live "$T" "$ID" 100 boot-x:2;  is "2d wrong ticks no" "$?" "1"
bridge_gen_matches_dead "$T" "$ID" 100 500;       is "2e old DEAD pair by procStart" "$?" "0"
bridge_gen_matches_dead "$T" "$ID" 100 999;       is "2f wrong procStart no" "$?" "1"
bridge_gen_matches_dead "$T" "$ID" 101 501;       is "2g current dead pair" "$?" "0"

echo "== 3. an empty key never matches (third pass 3) =="
bridge_gen_write "$T" "$ID" pid=200 birth= procStart=
bridge_gen_matches_live "$T" "$ID" 200 "";        is "3a empty birth vs empty recorded birth = NO match" "$?" "1"
bridge_gen_matches_dead "$T" "$ID" 200 "";        is "3b empty procStart vs empty recorded = NO match" "$?" "1"
bridge_gen_matches_live "$T" "$ID" "" boot-x:2;   is "3c empty pid = NO match" "$?" "1"

echo "== 4. clearing the pid opens a launch claim and keeps history =="
bridge_gen_write "$T" "$ID" pid= birth= procStart=
is "4a pid empty" "$(bridge_gen_get "$T" "$ID" pid)" ""
bridge_gen_matches_dead "$T" "$ID" 101 501;       is "4b 101 still in history after two pid changes" "$?" "0"

echo "== 5. history is bounded to eight =="
i=3; while [ $i -le 12 ]; do bridge_gen_write "$T" "$ID" pid=$((100+i)) birth=boot-x:$i procStart=$((500+i)); i=$((i+1)); done
bridge_gen_matches_dead "$T" "$ID" 100 500;       is "5a oldest fell off" "$?" "1"
bridge_gen_matches_dead "$T" "$ID" 105 505;       is "5b recent kept" "$?" "0"
is "5c history holds 8 entries" "$(sed -n 's/^history=//p' "$T/$ID.generation" | wc -w | tr -d ' ')" "8"

echo "== 6. the file is one truth: no duplicate keys, atomic tmp gone =="
is "6a exactly one pid= line" "$(grep -c '^pid=' "$T/$ID.generation")" "1"
is "6b no tmp left behind" "$(ls "$T" | grep -c '\.tmp\.')" "0"

echo "== 7. suspect: the SAME key twice in a row, reset by any other =="
S="$T/suspect"; K1="$(bridge_suspect_key identified:orphan 4500 boot-x:9)"; K2="$(bridge_suspect_key identified:moved 4500 boot-x:9)"
bridge_suspect_confirmed "$S" "$K1"; is "7a first sighting not confirmed" "$?" "1"
bridge_suspect_confirmed "$S" "$K1"; is "7b second identical sighting confirmed" "$?" "0"
bridge_suspect_confirmed "$S" "$K1"; bridge_suspect_confirmed "$S" "$K2"; is "7c a different answer is not confirmed" "$?" "1"
bridge_suspect_confirmed "$S" "$K1"; is "7d and it reset the original" "$?" "1"
K3="$(bridge_suspect_key identified:orphan 4501 boot-x:9)"
bridge_suspect_confirmed "$S" "$K1"; bridge_suspect_confirmed "$S" "$K3"; is "7e same answer, different pid, not confirmed" "$?" "1"
K4="$(bridge_suspect_key close - - session_created=1789000000)"; K5="$(bridge_suspect_key close - - session_created=1789000005)"
bridge_suspect_confirmed "$S" "$K4"; bridge_suspect_confirmed "$S" "$K5"; is "7f same action, different tmux identity, not confirmed" "$?" "1"
is "7g key carries every argument" "$K4" "close - - session_created=1789000000"

printf '\n%d passed, %d failed\n' "$pass" "$fail"; [ "$fail" -eq 0 ]
