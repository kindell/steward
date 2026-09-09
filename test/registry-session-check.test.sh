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
hasnt() { case "$2" in *"$3"*) bad "$1" "found '$3' in: $2" ;; *) ok "$1" ;; esac; }

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
HUB_HOST="__HUBHOST__"
HUB_SSH="__HUBUSER__@127.0.0.1"
STATE_DIR_NAME="fixture-supervisor"
PAUSED_DIR_NAME="fixture-paused"
TMUX_SOCKET="fixture.sock"
OP_TOKEN_FILE_NAME="fixture-token"
PING_MSG="you have unread mail"
EOF
# THE FIXTURE PRETENDS TO BE THE HUB, because that is where this verb normally
# runs and where the hub's own authorized_keys is readable. The machine's real
# name goes in: a hard-coded one would make the check answer "not measured" for
# every claim below - correctly, and uselessly.
sed -i.bak "s/__HUBHOST__/$(hostname -s)/; s/__HUBUSER__/$(id -un)/" "$ROOT/estate/steward.conf" && rm -f "$ROOT/estate/steward.conf.bak"
printf 'NAME="Alpha"\nMEMBERS="a"\n' > "$ROOT/entities.d/alpha.conf"
printf 'PRINCIPAL="a"\nUSERNAME="%s"\nHOST="%s"\n' "$(id -un)" "$(hostname -s)" > "$ROOT/accounts.d/a-hub.conf"
ID="s-00000000000000a1"
cat > "$ROOT/sessions.d/$ID.conf" <<EOF
ID="$ID"
ACCOUNT="a-hub"
SLUG="mute-row"
TARGET_ENTITY="alpha"
DOMAIN="alpha"
HOST="$(hostname -s)"
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

cp "$ROOT/sessions.d/$ID.conf" "$ROOT/sessions.d/$ID.conf.good"
printf 'ACCOUNT="missing-account"\n' >> "$ROOT/sessions.d/$ID.conf"
bad_account="$(run "$ID" --json)"; bad_account_rc=$?
is "invalid account identity preserves rc 78" "$bad_account_rc" "78"
has "the check names the invalid account" "$bad_account" "missing-account"
mv "$ROOT/sessions.d/$ID.conf.good" "$ROOT/sessions.d/$ID.conf"

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
# THE REASON MUST MATCH THE QUESTION. Without a row there is no owner, and
# blaming an unreadable home for a key nobody declared sends the reader to the
# wrong place. Raised in review by the product's integrator.
has "and the missing row is the reason, not the home" "$out" "there is no row"

# A PREFIX IS NOT A MATCH. The hub line is matched with its closing quote, so a
# longer id that starts with a shorter one can never answer for it.
printf 'restrict,command="bus-relay-in %s-extra" ssh-ed25519 AAAA busrelay x\n' "$ID" > "$HOMEDIR/.ssh/authorized_keys"
out="$(run "$ID")"
has "a longer id does not answer for a shorter one" "$out" "hub relay line   no"

out="$(run 2>&1)"; rc=$?
has "no id is a refusal that says so" "$out" "needs a session id"

# A ROW CANNOT NAME ANOTHER ROW, NOR CHOOSE THE FORMAT. The loader's wall stops
# a conf at the LOADER's frame; it does not stop one at THIS verb's, because
# bash scope is dynamic and both `id` and `want_json` are declared above
# registry_load and read below it. `id` names the session in every line and
# builds the relay-key path; `want_json` decides the format. Measured on the
# real CLI: a row carrying both reported ANOTHER session's id and relay key in
# JSON nobody asked for. The row is sourced in a child process now.
OTHER="s-00000000000000b2"
cat > "$ROOT/sessions.d/$OTHER.conf" <<EOF
ID="$OTHER"
ACCOUNT="a-hub"
SLUG="other-row"
TARGET_ENTITY="alpha"
DOMAIN="alpha"
HOST="$(hostname -s)"
REPO_PATH="$HOMEDIR"
OWNER="$(id -un)"
RC_LABEL="B"
EOF
cp "$ROOT/sessions.d/$ID.conf" "$ROOT/sessions.d/$ID.conf.good"
printf 'id="%s"\nwant_json=1\n' "$OTHER" >> "$ROOT/sessions.d/$ID.conf"
out="$(run "$ID")"
has "a lying row is still reported under its own id" "$out" "session $ID"
hasnt "a lying row does not take the other row's id" "$out" "$OTHER"
has "a lying row does not build the other row's relay key path" "$out" ".ssh/id_busrelay_$ID"
has "a lying row is still read and named by its own slug" "$out" "mute-row"
hasnt "a lying row cannot switch the format to json" "$out" '{"ok":true'
mv "$ROOT/sessions.d/$ID.conf.good" "$ROOT/sessions.d/$ID.conf"
rm -f "$ROOT/sessions.d/$OTHER.conf"

# THE HUB'S FILE IS NOT THE CALLER'S. Run in a person's own account the check
# used to read THEIR authorized_keys and report the hub's line as absent - the
# exact fault this verb exists to avoid, in the verb itself. Measured by running
# the check as its own subject 2026-09-07.
cat > "$ROOT/estate/steward.conf.hub" <<'EOF'
EOF
sed 's/^HUB_HOST=.*/HUB_HOST="somewhere-else"/' "$ROOT/estate/steward.conf" > "$ROOT/estate/steward.conf.tmp" \
  && mv "$ROOT/estate/steward.conf.tmp" "$ROOT/estate/steward.conf"
out="$(run "$ID")"
has "a hub on another machine is not measured here" "$out" "hub relay line   not measured"
has "and the reason names the hub" "$out" "somewhere-else"
has "the row is then unknown, never a false no" "$out" "can send         unknown"
rm -f "$ROOT/estate/steward.conf.hub"

printf '\n  %d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
