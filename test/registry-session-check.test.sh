#!/bin/bash
# test/registry-session-check.test.sh - the check MEASURES a row's ability to
# speak, and says plainly what it could not measure.
#
# WHY. `registry session add` writes a row and mints nothing: no relay key in
# the owner's home, no line in the hub's authorized_keys. Such a row receives
# mail perfectly and cannot answer, which reads as a silent session rather than
# as a missing key - measured twice in one day on this estate, on two hosts,
# and both times found only after somebody waited for a reply.
#
# THE SECOND CLAIM IS THE POINT. Homes are 0750, so run as the hub this verb
# CANNOT see another person's ~/.ssh. An unreadable directory is not an absent
# key, and a check that said "missing" for a key it merely could not see would
# send its reader to mint a second key over a working one.
set -u
here="$(CDPATH= cd -- "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
pass=0; fail=0
ok()  { pass=$((pass+1)); printf '  ok   %s\n' "$1"; }
bad() { fail=$((fail+1)); printf '  FAIL %s\n     %s\n' "$1" "${2:-}"; }
is()  { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "wanted '$3', got '$2'"; fi; }
has() { case "$2" in *"$3"*) ok "$1" ;; *) bad "$1" "missing '$3' in: $2" ;; esac; }

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
ROOT="$T/estate"; HOMEDIR="$T/home"
mkdir -p "$ROOT/estate" "$ROOT/sessions.d" "$ROOT/entities.d" "$ROOT/accounts.d" \
         "$ROOT/projects.d" "$ROOT/mcp.d" "$HOMEDIR/.ssh"
cat > "$ROOT/estate/steward.conf" <<'EOF'
ESTATE_NAME="fixture"
LABEL_PREFIX="com.fixture.claude"
JOB_LABEL_PREFIX="com.fixture.job"
SERVICE_LABEL_PREFIX="com.fixture.svc"
RC_LABEL_PREFIX=""
HUB_SESSION="hub"
HUB_HOST="h1"
STATE_DIR_NAME="fixture-supervisor"
PAUSED_DIR_NAME="fixture-paused"
TMUX_SOCKET="fixture.sock"
OP_TOKEN_FILE_NAME="fixture-token"
PING_MSG="you have unread mail"
EOF
printf 'NAME="Alpha"\nMEMBERS="a"\n' > "$ROOT/entities.d/alpha.conf"
ID="s-00000000000000a1"
cat > "$ROOT/sessions.d/$ID.conf" <<EOF
ID="$ID"
ACCOUNT="a-h1"
SLUG="mute-row"
TARGET_ENTITY="alpha"
DOMAIN="alpha"
HOST="h1"
REPO_PATH="$HOMEDIR"
OWNER="$(id -un)"
RC_LABEL="A"
EOF

run() { HOME="$HOMEDIR" STEWARD_ESTATE_ROOT="$ROOT" bash "$here/bin/steward" registry session check "$@" 2>&1; }

echo "registry session check"

out="$(run "$ID")"
has "the row is read and named" "$out" "mute-row"
has "no hub line is reported as no" "$out" "hub relay line   no"
has "and the row is called mute" "$out" "can send         NO"
has "with the way to make a sending session" "$out" "session-new.sh"

# the key IS measurable here: the fixture's owner is this process
has "the key is measured when the home is readable" "$out" "relay key        no"

printf 'restrict,command="bus-relay-in %s" ssh-ed25519 AAAA busrelay %s\n' "$ID" "$ID" > "$HOMEDIR/.ssh/authorized_keys"
: > "$HOMEDIR/.ssh/id_busrelay_$ID"
out="$(run "$ID")"
has "a row with both is reported as able to send" "$out" "can send         yes"

out="$(run "$ID" --json)"
has "json carries the hub line" "$out" '"hub_row":"yes"'
has "json carries the key" "$out" '"relay_key":"yes"'
has "json says whether it can send" "$out" '"can_send":"yes"'

out="$(run s-0000000000000bad)"
has "an unknown id is reported, not invented" "$out" "row              missing"

out="$(run 2>&1)"; rc=$?
has "no id is a refusal that says so" "$out" "needs a session id"

printf '\n  %d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
