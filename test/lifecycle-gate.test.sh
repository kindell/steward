#!/bin/bash
# test/lifecycle-gate.test.sh — LIFECYCLE is one closed set, read the same way by
# every reader, and only one of its values runs.
#
# WHY IT EXISTS. The register recorded a lifecycle and acted on it nowhere: its
# own comment said "RECORDED HERE, ACTED ON NOWHERE", and no start path asked.
# A retired row was started by the supervisor exactly like a live one, and the
# only thing a retirement did was change a word in a file.
#
# AND THE TWO READERS HAD DRIFTED. registry_load accepted active|suspended|
# retired; the strict non-executing reader added for the host gate accepted
# active|retired|stopped. So "suspended" loaded but was uninspectable to the
# gate, and "stopped" passed the gate but could never load — two vocabularies
# for one field, each the authority somewhere. Measured 2026-09-13.
#
# THE CLAIM THAT ACTUALLY BITES is section 3: not that each reader knows its own
# list, but that the two lists are the SAME list. A test per reader would have
# stayed green through the whole drift.
set -u
here="$(CDPATH= cd -- "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
pass=0; fail=0
ok()  { pass=$((pass+1)); echo "  ok   $1"; }
bad() { fail=$((fail+1)); echo "  FAIL $1"; echo "     wanted '$3', got '$2'"; }
is()  { [ "$2" = "$3" ] && ok "$1" || bad "$1" "$2" "$3"; }

FX="$(mktemp -d)"; trap 'rm -rf "$FX"' EXIT
mkdir -p "$FX/estate" "$FX/sessions.d" "$FX/entities.d" "$FX/projects.d" "$FX/accounts.d"
SESS="$FX/sessions.d"
cat > "$FX/estate/steward.conf" <<'EOF'
ESTATE_NAME="fixture"
SCHEMA_VERSION="3"
LABEL_PREFIX="com.fixture.claude"
RC_LABEL_PREFIX="fixture: "
HUB_SESSION="fixture-hub"
HUB_HOST="h1"
HUB_SSH="a@h1"
JOB_LOG_DIR="fixture-jobs"
TMUX_SOCKET="fixture.sock"
PING_MSG="you have mail"
STATE_DIR_NAME="fixture-supervisor"
PAUSED_DIR_NAME="fixture-paused"
JOB_LABEL_PREFIX="com.fixture.job"
SERVICE_LABEL_PREFIX="com.fixture.service"
BROWSER_LABEL_PREFIX="com.fixture.browser"
OP_TOKEN_FILE_NAME="fixture-token"
EOF
printf 'NAME="Alpha"\nMEMBERS="a"\n' > "$FX/entities.d/alpha.conf"
printf 'PRINCIPAL="a"\nHOST="h1"\n' > "$FX/accounts.d/a-h1.conf"

# one row, rewritten per case; everything but LIFECYCLE stays loadable
row() { # [lifecycle-line]
  { printf 'OWNER="a"\nHOST="h1"\nDOMAIN="alpha"\nREPO_PATH="/tmp/repo"\nRC_LABEL="L"\n'
    [ -n "${1:-}" ] && printf '%s\n' "$1"
  } > "$SESS/one.conf"
}
in_fixture() { # <fn> [args...]
  OUT="$(
    export STEWARD_REGISTRY_DIR="$SESS" STEWARD_ESTATE_ROOT="$FX" \
           STEWARD_ENTITY_DIR="$FX/entities.d" STEWARD_PROJECT_DIR="$FX/projects.d" \
           STEWARD_ACCOUNT_DIR="$FX/accounts.d" STEWARD_CONFIG_FILE="$FX/no-such-config"
    . "$here/lib/registry.sh"
    "$@" 2>/dev/null
  )"; RC=$?
}

echo "== 1. one closed set =="
for v in active suspended retired; do
  in_fixture registry_lifecycle_valid "$v"; is "1a '$v' is in the set" "$RC" "0"
done
for v in stopped moving moved Active ACTIVE "act ive" "" "-" "active retired"; do
  in_fixture registry_lifecycle_valid "$v"; is "1b '$v' is not" "$RC" "1"
done

echo "== 2. one rule: only active runs =="
in_fixture registry_lifecycle_runs active;    is "2a active runs" "$RC" "0"
in_fixture registry_lifecycle_runs suspended; is "2b suspended does not" "$RC" "1"
in_fixture registry_lifecycle_runs retired;   is "2c retired does not" "$RC" "1"
# THE DEFAULT IS DELIBERATE, NOT AN OVERSIGHT: a row with no LIFECYCLE line is
# every row written before the field existed, and those rows run. An EMPTY value
# is the same case in the loader (: "${LIFECYCLE:=active}"), so it is here too.
in_fixture registry_lifecycle_runs "";        is "2d an absent/empty value is the active default" "$RC" "0"
in_fixture registry_lifecycle_runs;           is "2e no argument at all is the same default" "$RC" "0"
in_fixture registry_lifecycle_runs stopped;   is "2f a value outside the set never runs" "$RC" "1"

echo "== 3. the two readers are the SAME reader =="
# For every value, the loader's verdict and the strict non-executing reader's
# verdict must agree. This is the claim the drift walked through.
for v in active suspended retired stopped moving Active "act ive"; do
  row "LIFECYCLE=\"$v\""
  in_fixture registry_load one >/dev/null; loader=$RC
  in_fixture _registry_gate_raw "$SESS/one.conf" LIFECYCLE; raw=$RC
  # loader: 0 accept, 1 refuse. raw: 0 accept, 2 refuse.
  l=refuse; [ "$loader" = 0 ] && l=accept
  r=refuse; [ "$raw" = 0 ] && r=accept
  is "3a '$v': loader and raw agree ($l)" "$r" "$l"
done
row ""
in_fixture registry_load one >/dev/null; is "3b a row with no LIFECYCLE line loads" "$RC" "0"
in_fixture _registry_gate_raw "$SESS/one.conf" LIFECYCLE; is "3c and the raw reader answers empty, not a refusal" "$RC:$OUT" "0:"

echo "== 4. the drift itself, pinned =="
row 'LIFECYCLE="stopped"'
in_fixture registry_load one >/dev/null; is "4a 'stopped' does not load" "$RC" "1"
in_fixture _registry_gate_raw "$SESS/one.conf" LIFECYCLE; is "4b and the strict reader refuses it too (it did not)" "$RC" "2"
row 'LIFECYCLE="suspended"'
in_fixture registry_load one >/dev/null; is "4c 'suspended' loads" "$RC" "0"
in_fixture _registry_gate_raw "$SESS/one.conf" LIFECYCLE; is "4d and the strict reader accepts it (it did not)" "$RC:$OUT" "0:suspended"

printf '\n%d passed, %d failed\n' "$pass" "$fail"; [ "$fail" -eq 0 ]
