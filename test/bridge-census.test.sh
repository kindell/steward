#!/bin/bash
# test/bridge-census.test.sh - the one-time bootstrap census (spec §1 "Bootstrap", gate P0; plan Task 10):
# every claude-code row of this uid on this host is asked in bootstrap mode, and its generation is
# seeded from the answer - a verified record for a managed row, a stop receipt for an empty one, and a
# `blocked:` mark for everything the operator must resolve first. The observer is a shim (its bootstrap
# mode is proven in test/bridge-observe.test.sh); the registry is a fixture; nothing here touches the machine.
set -u
here="$(CDPATH= cd -- "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CENSUS="$here/linux/bridge-census.sh"
pass=0; fail=0
ok()  { pass=$((pass+1)); printf '  ok   %s\n' "$1"; }
bad() { fail=$((fail+1)); printf '  FAIL %s\n     %s\n' "$1" "${2:-}"; }
is()  { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "wanted '$3', got '$2'"; fi; }
has() { case "$2" in *"$3"*) ok "$1" ;; *) bad "$1" "missing '$3' in: $2" ;; esac; }
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
US="$(printf '\037')"
ROOT="$T/estate"; LIBS="$T/libs"; SD="$T/state"; OBS="$T/obs"; BIN="$T/bin"
mkdir -p "$ROOT/estate" "$ROOT/sessions.d" "$ROOT/entities.d" "$ROOT/accounts.d" "$ROOT/projects.d" "$ROOT/mcp.d" "$LIBS" "$SD" "$OBS" "$BIN" "$T/memory"
cat > "$ROOT/estate/steward.conf" <<'EOF2'
ESTATE_NAME="fixture"
LABEL_PREFIX="com.fixture.claude"
JOB_LABEL_PREFIX="com.fixture.job"
SERVICE_LABEL_PREFIX="com.fixture.svc"
RC_LABEL_PREFIX="Fixture: "
HUB_SESSION="hub"
HUB_HOST="h1"
STATE_DIR_NAME="fixture-supervisor"
PAUSED_DIR_NAME="fixture-paused"
TMUX_SOCKET="fixture.sock"
OP_TOKEN_FILE_NAME="fixture-token"
PING_MSG="you have unread mail"
EOF2
printf 'NAME="Alpha"\nMEMBERS="a"\n' > "$ROOT/entities.d/alpha.conf"
ME="$(id -un)"
# THE CENSUS RUNS AS THE OWNER, and a row's unix user is its ACCOUNT's username - so the fixture's
# account names the account this test actually runs as. OWNER stays the principal, as a real row's does.
printf 'PRINCIPAL="a"\nHOST="h1"\nUSERNAME="%s"\n' "$ME" > "$ROOT/accounts.d/a-h1.conf"
cp "$here/lib/registry.sh" "$here/lib/bridge.sh" "$LIBS/"
row() { # <id> [KEY="v" ...]
  { printf 'OWNER="a"\nHOST="h1"\nDOMAIN="alpha"\nREPO_PATH="/tmp/r"\nID="%s"\nACCOUNT="a-h1"\nRC_LABEL="Fixture: x"\n' "$1"; shift; for l in "$@"; do printf '%s\n' "$l"; done; } > "$ROOT/sessions.d/$1.conf"
}
row s-0000000000000001; row s-0000000000000002; row s-0000000000000003; row s-0000000000000004
row s-0000000000000005 'RUNTIME="opencode"' 'MODEL="openai/m"' 'OPENCODE_VERSION="1.0.0"' 'OPENCODE_PORT="4097"' 'AUTO_APPROVE="true"' "CLAUDE_MEMORY_ROOT=\"$T/memory\""
row s-0000000000000006 'HOST="h2"'
{ printf 'OWNER="%s"\nHOST="h1"\nDOMAIN="alpha"\nREPO_PATH="/tmp/r"\nID="s-0000000000000007"\nRC_LABEL="Fixture: x"\n' "$ME"; } > "$ROOT/sessions.d/s-0000000000000007.conf"   # no ACCOUNT: its unix user is OWNER
# the observer shim: one line per id in $OBS/<id>, or unknown; every call logged with its mode
cat > "$BIN/observe" <<'EOF2'
#!/bin/bash
printf '%s\n' "$*" >> "$OBS_LOG"; id="$1"; [ "$id" = --bootstrap ] && id="$2"
if [ -f "$OBS_DIR/$id" ]; then cat "$OBS_DIR/$id"; else printf '%s\037unknown\037\037\037\037\037\037none\037unclassifiable\037\037\037\037\037\037\n' "$id"; fi
EOF2
chmod 755 "$BIN/observe"; export OBS_LOG="$T/obs.log" OBS_DIR="$OBS"
line() { local id="$1"; shift; local out="$id"; for a in "$@"; do out="$out$US$a"; done; printf '%s\n' "$out" > "$OBS/$id"; }
line s-0000000000000001 identified:managed 4243 boot-c:111 "s-0000000000000001:@0.%0" "Alpha→Thing" 1789000000000 bootstrap live:managed "" 4243 thread-1 1789000000000 '$7:1' 777
line s-0000000000000002 no-process "" "" "" "" "" bootstrap "" "" "" "" "" "" ""
line s-0000000000000003 identified:orphan 4300 boot-c:300 "s-0000000000000003:@0.%0" "X" 1 bootstrap live:orphan "" 4300 t 1 "" 778
line s-0000000000000004 unknown "" "" "" "" "" bootstrap "live:managed live:managed" "" "" "" "" '$8:1' ""
line s-0000000000000005 not-applicable "" "" "" "" "" none "" "" "" "" "" "" ""
line s-0000000000000007 unknown "" "" "" "" "" none account-missing "" "" "" "" "" ""
run() { : > "$OBS_LOG"; OUT="$(HOME="$T/home" STEWARD_ESTATE_ROOT="$ROOT" STEWARD_REGISTRY_LIB="$LIBS/registry.sh" STEWARD_BRIDGE_LIB="$LIBS/bridge.sh" STEWARD_BRIDGE_OBSERVE="$BIN/observe" STEWARD_STATE_DIR="$SD" STEWARD_TMUX_SOCKET="$T/fixture.sock" STEWARD_SELF_HOST=h1 bash "$CENSUS" "$@" 2>"$T/err")"; RC=$?; ERR="$(cat "$T/err")"; }
gget() { sed -n "s/^$2=//p" "$SD/$1.generation" 2>/dev/null | head -1; }

echo "== 1. a dry run asks every row on this host in bootstrap mode and writes nothing =="
run --dry-run
is "1a rc 1 (a blocked row and a prerequisite are in the report)" "$RC" "1"
is "1b every h1 claude row was asked, in --bootstrap mode" "$(grep -c '^--bootstrap s-' "$OBS_LOG")" "6"; is "1c the h2 row was not" "$(grep -c 's-0000000000000006' "$OBS_LOG")" "0"
is "1d nothing written" "$(ls "$SD" | wc -l | tr -d ' ')" "0"; has "1e says dry run" "$ERR" "DRY RUN"

echo "== 2. the real run seeds, receipts, blocks and lists =="
run
is "2a rc 1: something is blocked" "$RC" "1"
is "2b managed: pid seeded" "$(gget s-0000000000000001 pid)" "4243"; is "2c birth" "$(gget s-0000000000000001 birth)" "boot-c:111"; is "2d procStart" "$(gget s-0000000000000001 procStart)" "4243"
is "2e sessionId" "$(gget s-0000000000000001 sessionId)" "thread-1"; is "2f bridge_name" "$(gget s-0000000000000001 bridge_name)" "Alpha→Thing"; is "2g bridge_inode" "$(gget s-0000000000000001 bridge_inode)" "777"
is "2h census=1" "$(gget s-0000000000000001 census)" "1"; is "2i no stop receipt on a live row" "$(gget s-0000000000000001 stop_receipt)" ""
is "2j no-process: census=1" "$(gget s-0000000000000002 census)" "1"; case "$(gget s-0000000000000002 stop_receipt)" in census-[0-9]*) ok "2k and a census stop receipt";; *) bad "2k and a census stop receipt" "$(gget s-0000000000000002 stop_receipt)";; esac
# N1: AN ORPHAN IS SEEDED, NOT BLOCKED. The census writes down what is there; the supervisor's own policy
# then reaps it on the next round. A blocked orphan would leave a live process the adapter can never match.
is "2l orphan: seeded, with its verified record" "$(gget s-0000000000000003 census)" "1"; is "2m and its pid" "$(gget s-0000000000000003 pid)" "4300"
is "2m2 and its birth" "$(gget s-0000000000000003 birth)" "boot-c:300"
is "2n split-brain: blocked:unknown" "$(gget s-0000000000000004 census)" "blocked:unknown"
[ -f "$SD/s-0000000000000005.generation" ] && bad "2o not-applicable: no generation" "" || ok "2o not-applicable: no generation"
[ -f "$SD/s-0000000000000007.generation" ] && bad "2p account-missing: no generation (prerequisite)" "" || ok "2p account-missing: no generation (prerequisite)"
has "2q the report names the prerequisite" "$OUT" "prerequisite"; has "2r and names the ACCOUNT migration" "$OUT" "migrate the row first"
has "2s the summary counts" "$ERR" "3 seeded, 1 blocked, 1 prerequisite, 1 listed"
# (s-...6 lives on h2 and is not this host's to census - the MOVED case uses a row of this host.)
line s-0000000000000004 identified:moved 4400 boot-c:400 "s-0000000000000004:@0.%0" "Moved" 1 bootstrap live:moved "" 4400 tm 1 "" 779
run --force s-0000000000000004; is "2t a MOVED row is seeded too (N1)" "$RC" "0"; is "2u with its record" "$(gget s-0000000000000004 pid)" "4400"

echo "== 3. idempotence: a censused row is skipped unless --force =="
run s-0000000000000001; is "3a rc 0 for the one seeded row" "$RC" "0"; has "3b already-censused" "$OUT" "already-censused"; is "3c the observer was not asked" "$(grep -c . "$OBS_LOG")" "0"
line s-0000000000000001 identified:managed 4250 boot-c:250 "s-0000000000000001:@0.%0" "Alpha→Thing" 1 bootstrap live:managed "" 4250 thread-2 1 '$7:1' 779
run --force s-0000000000000001; is "3d --force re-asks and re-seeds" "$(gget s-0000000000000001 pid)" "4250"; is "3e the old pid went to history" "$(grep -c '4243:4243:boot-c:111' "$SD/s-0000000000000001.generation")" "1"

echo "== 4. a blocked row is re-censused with --force once resolved =="
line s-0000000000000003 no-process "" "" "" "" "" bootstrap "" "" "" "" "" "" ""
run --force s-0000000000000003; is "4a rc 0" "$RC" "0"; is "4b census=1 now" "$(gget s-0000000000000003 census)" "1"

echo "== 5. an observer answer outside the contract blocks, never seeds =="
printf 's-0000000000000002\037identified:managed\n' > "$OBS/s-0000000000000002"; run --force s-0000000000000002
is "5a rc 1" "$RC" "1"; is "5b blocked:unreadable" "$(gget s-0000000000000002 census)" "blocked:unreadable"; is "5c the receipt from before is kept, no pid invented" "$(gget s-0000000000000002 pid)" ""

echo "== 5b. N2: one gate for one row and for all of them =="
row s-0000000000000008 'HOST="h2"'
run s-0000000000000008; is "5e an explicit id on ANOTHER host is refused" "$RC" "1"; has "5f and says where it lives" "$OUT" "it lives on 'h2'"
[ -f "$SD/s-0000000000000008.generation" ] && bad "5g and writes no generation for it" "" || ok "5g and writes no generation for it"
is "5h the observer was never asked about it" "$(grep -c 's-0000000000000008' "$OBS_LOG")" "0"
run s-0000000000000099; is "5i an id that is not a row is refused" "$RC" "1"; has "5j and says so" "$OUT" "does not load"
[ -f "$SD/s-0000000000000099.generation" ] && bad "5k no debris for an unknown id" "" || ok "5k no debris for an unknown id"
printf 'OWNER="nobody-else"\nHOST="h1"\nDOMAIN="alpha"\nREPO_PATH="/tmp/r"\nID="s-0000000000000009"\nRC_LABEL="x"\n' > "$ROOT/sessions.d/s-0000000000000009.conf"
run s-0000000000000009; is "5l another unix account's row is refused" "$RC" "1"; has "5m and names whose it is" "$OUT" "nobody-else"
rm -f "$ROOT/sessions.d/s-0000000000000008.conf" "$ROOT/sessions.d/s-0000000000000009.conf"

echo "== 5c. N3: --force is a complete census, not a merge onto stale identity =="
line s-0000000000000002 identified:managed 4500 boot-c:500 "s-0000000000000002:@0.%0" "Was Live" 1 bootstrap live:managed "" 4500 t2 1 '$5:1' 780
run --force s-0000000000000002; is "5n first: a live row is seeded" "$(gget s-0000000000000002 pid)" "4500"
bash -c ". '$LIBS/bridge.sh'; bridge_gen_write '$SD' 's-0000000000000002' launch_ms=1789 launch_nonce=0123456789abcdef0123456789abcdef pending_for='Old Name' applied='Older Name' spawn_state=pending"
line s-0000000000000002 no-process "" "" "" "" "" bootstrap "" "" "" "" "" "" ""
run --force s-0000000000000002; is "5o then: the row is gone and re-censused" "$RC" "0"
is "5p no stale pid survives" "$(gget s-0000000000000002 pid)" ""; is "5q no stale birth" "$(gget s-0000000000000002 birth)" ""
is "5r no stale launch claim" "$(gget s-0000000000000002 launch_nonce)$(gget s-0000000000000002 launch_ms)$(gget s-0000000000000002 spawn_state)" ""
is "5s no stale name reservation" "$(gget s-0000000000000002 pending_for)$(gget s-0000000000000002 applied)" ""
case "$(gget s-0000000000000002 stop_receipt)" in census-[0-9]*) ok "5t and the receipt it DOES state is the new one";; *) bad "5t and the receipt it DOES state is the new one" "$(gget s-0000000000000002 stop_receipt)";; esac
is "5u the history of earlier processes is kept - a KILL -9 file must stay recognisable" "$(grep -c '^history=' "$SD/s-0000000000000002.generation")" "1"

echo "== 6. usage and environment =="
run --bogus; is "6a unknown flag rc 64" "$RC" "64"
run a b; is "6b two ids rc 64" "$RC" "64"
OUT="$(HOME="$T/home" STEWARD_ESTATE_ROOT="$ROOT" STEWARD_REGISTRY_LIB="$LIBS/registry.sh" STEWARD_BRIDGE_LIB="$LIBS/bridge.sh" STEWARD_BRIDGE_OBSERVE="$T/none" STEWARD_STATE_DIR="$SD" STEWARD_TMUX_SOCKET="$T/s" bash "$CENSUS" 2>&1)"; is "6c a missing observer is rc 78" "$?" "78"

printf '\n%d passed, %d failed\n' "$pass" "$fail"; [ "$fail" -eq 0 ]
