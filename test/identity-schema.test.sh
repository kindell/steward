#!/bin/bash
# test/identity-schema.test.sh — the five additive fields the identity model
# rests on: ESTATE_NAME, SCHEMA_VERSION, ID, KIND, LIFECYCLE.
#
# WHY THEY ARE ADDITIVE. Five live conversations run on the hub while this
# lands. A field that changes what gets rendered would end them; a field that is
# only read by validation cannot. The rendered-plist gate is the proof, and it
# is a step in every task, not a hope.
set -u

here="$(CDPATH= cd -- "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
pass=0; fail=0
ok()  { pass=$((pass+1)); printf '  ok   %s\n' "$1"; }
bad() { fail=$((fail+1)); printf '  FAIL %s\n     %s\n' "$1" "${2:-}"; }

FX="$(mktemp -d)"; trap 'rm -rf "$FX"' EXIT
mkdir -p "$FX/estate" "$FX/sessions.d"

estate() { printf '%s\n' "$@" > "$FX/estate/steward.conf"; }
lade() { # run a registry function against the fixture estate
  ( export STEWARD_ESTATE_ROOT="$FX"
    # shellcheck source=/dev/null
    . "$here/lib/registry.sh"
    "$@" )
}

echo "ESTATE_NAME — the estate is named, never guessed"

# THE NAME IS REQUIRED. A missing name must refuse, not fall back on the hub
# session or the label prefix: those coincide in one estate and diverge in the
# next, and a default that is right once teaches nobody it can be wrong.
estate 'LABEL_PREFIX="com.example.claude"'
out="$(lade registry_estate_name 2>&1)"; rc=$?
[ "$rc" -eq 78 ] && ok "a missing ESTATE_NAME refuses with rc 78" \
                 || bad "a missing ESTATE_NAME refuses with rc 78" "rc=$rc: $out"
case "$out" in *ESTATE_NAME*) ok "the refusal names the key" ;;
  *) bad "the refusal names the key" "$out" ;; esac

# CONTROL GROUP: a valid name is returned verbatim.
estate 'LABEL_PREFIX="com.example.claude"' 'ESTATE_NAME="acme"'
out="$(lade registry_estate_name 2>&1)"; rc=$?
[ "$rc" -eq 0 ] && [ "$out" = "acme" ] && ok "a valid name is printed" \
                || bad "a valid name is printed" "rc=$rc, got '$out'"

# THE FORM IS THE GUARD. The name becomes part of derived session names, so a
# slash, a space or a glob character would let a typo name something outside its
# own namespace — the same failure LABEL_PREFIX is guarded against.
for bad_name in 'a b' 'a/b' 'a*' '' 'Ab'; do
  estate 'LABEL_PREFIX="com.example.claude"' "ESTATE_NAME=\"$bad_name\""
  lade registry_estate_name >/dev/null 2>&1
  [ "$?" -ne 0 ] && ok "refuses the malformed name '$bad_name'" \
                 || bad "refuses the malformed name '$bad_name'" "it was accepted"
done

echo "SCHEMA_VERSION — an old checkout refuses a newer estate"

# A CHECKOUT THAT IS BEHIND MUST SAY SO. Without the check it reads a register
# carrying fields it does not know, treats them as absent, and acts on a
# half-understood truth. That is the same confusion between "empty" and
# "unreadable" the whole library is built against, one level up.
estate 'LABEL_PREFIX="com.example.claude"' 'ESTATE_NAME="acme"' 'SCHEMA_VERSION="999"'
out="$(lade registry_schema_check 2>&1)"; rc=$?
[ "$rc" -eq 78 ] && ok "a newer schema refuses with rc 78" \
                 || bad "a newer schema refuses with rc 78" "rc=$rc: $out"
case "$out" in *999*) ok "the refusal names both versions" ;;
  *) bad "the refusal names both versions" "$out" ;; esac

# CONTROL GROUP: the version this checkout was written for passes.
estate 'LABEL_PREFIX="com.example.claude"' 'ESTATE_NAME="acme"' 'SCHEMA_VERSION="2"'
lade registry_schema_check >/dev/null 2>&1
[ "$?" -eq 0 ] && ok "the current schema passes" || bad "the current schema passes" "it refused"

# AN ABSENT VERSION IS VERSION 1, not an error. Every estate that exists today
# predates the key; refusing them would make the guard's first act an outage.
estate 'LABEL_PREFIX="com.example.claude"' 'ESTATE_NAME="acme"'
lade registry_schema_check >/dev/null 2>&1
[ "$?" -eq 0 ] && ok "an absent SCHEMA_VERSION reads as 1 and passes" \
               || bad "an absent SCHEMA_VERSION reads as 1 and passes" "it refused"

# A NON-NUMERIC VERSION IS NOT VERSION 1. Silently treating a typo as the
# oldest schema would let a malformed estate through the exact gate that exists
# to stop half-understood ones.
estate 'LABEL_PREFIX="com.example.claude"' 'ESTATE_NAME="acme"' 'SCHEMA_VERSION="two"'
lade registry_schema_check >/dev/null 2>&1
[ "$?" -ne 0 ] && ok "a malformed SCHEMA_VERSION refuses" \
               || bad "a malformed SCHEMA_VERSION refuses" "it was accepted as 1"

echo
echo "ID — the immutable key, separate from the display name"

konf() { printf '%s\n' "$@" > "$FX/sessions.d/$1.conf"; }
ladda() { # <session> -> load it against the fixture registry, print a field
  ( export STEWARD_ESTATE_ROOT="$FX" STEWARD_REGISTRY_DIR="$FX/sessions.d"
    # shellcheck source=/dev/null
    . "$here/lib/registry.sh"
    registry_load "$1" >/dev/null 2>&1 || exit 1
    printf '%s' "${!2}" )
}
estate 'LABEL_PREFIX="com.example.claude"' 'ESTATE_NAME="acme"' 'SCHEMA_VERSION="2"' \
  'RC_LABEL_PREFIX="Steward: "' 'HUB_SESSION="hub"' 'HUB_HOST="hub"' 'JOB_LOG_DIR="jobs"' \
  'HUB_SSH="owner@hub"' 'TMUX_SOCKET="steward.sock"' 'PING_MSG="ping"' \
  'JOB_LABEL_PREFIX="com.example.job"' 'SERVICE_LABEL_PREFIX="com.example.service"' \
  'BROWSER_LABEL_PREFIX="com.example.browser"' 'OP_TOKEN_FILE_NAME="token"' \
  'STATE_DIR_NAME="adapter-state"' 'PAUSED_DIR_NAME="paused"'

# AN EXPLICIT ID IS USED VERBATIM.
konf one 'REPO_PATH="/x"' 'RC_LABEL="One"' 'OWNER="ada"' 'DOMAIN="d"' 'ID="frozen-one"'
[ "$(ladda one ID)" = "frozen-one" ] && ok "an explicit ID is loaded" \
  || bad "an explicit ID is loaded" "got '$(ladda one ID)'"

# AN ABSENT ID FALLS BACK TO THE FILE NAME — and that is a MIGRATION, not a
# default to keep. Today's session name is already unique and already what
# everything keys on, so freezing it changes nothing and makes an existing
# truth explicit.
konf two 'REPO_PATH="/x"' 'RC_LABEL="Two"' 'OWNER="ada"' 'DOMAIN="d"'
[ "$(ladda two ID)" = "two" ] && ok "an absent ID falls back to the file name" \
  || bad "an absent ID falls back to the file name" "got '$(ladda two ID)'"

# THE ID IS NOT THE DISPLAY NAME. A conf may carry both, and they may differ —
# that is the entire point of the split, so a test that never sees them differ
# proves nothing.
konf three 'REPO_PATH="/x"' 'RC_LABEL="Renamed Yesterday"' 'OWNER="ada"' 'DOMAIN="d"' 'ID="three"'
[ "$(ladda three ID)" = "three" ] && [ "$(ladda three RC_LABEL)" = "Renamed Yesterday" ] \
  && ok "ID and display name are independent" \
  || bad "ID and display name are independent" "ID='$(ladda three ID)' label='$(ladda three RC_LABEL)'"

# THE FORM IS THE GUARD: an ID is keyed on, so it must never carry a path
# separator, whitespace or a glob character.
for bad_id in 'a b' 'a/b' 'a*' 'A'; do
  konf four 'REPO_PATH="/x"' 'RC_LABEL="Four"' 'OWNER="ada"' 'DOMAIN="d"' "ID=\"$bad_id\""
  ladda four ID >/dev/null 2>&1
  [ "$?" -ne 0 ] && ok "refuses the malformed ID '$bad_id'" \
                 || bad "refuses the malformed ID '$bad_id'" "it was accepted"
done

echo "KIND — work, infra or advisor, stated once"

# THE DEFAULT IS work BECAUSE THAT IS WHAT ALMOST EVERY SESSION IS. A default
# that covers the common case is not a guess; a default that covers the rare one
# would be.
konf plain 'REPO_PATH="/x"' 'RC_LABEL="Plain"' 'OWNER="ada"' 'DOMAIN="d"'
[ "$(ladda plain KIND)" = "work" ] && ok "an absent KIND reads as work" \
  || bad "an absent KIND reads as work" "got '$(ladda plain KIND)'"

for k in work infra advisor; do
  konf kk 'REPO_PATH="/x"' 'RC_LABEL="K"' 'OWNER="ada"' 'DOMAIN="d"' "KIND=\"$k\""
  [ "$(ladda kk KIND)" = "$k" ] && ok "KIND=$k is accepted" || bad "KIND=$k is accepted" "it was not"
done

# AN UNKNOWN KIND REFUSES. The set is closed on purpose: a typo that reads as a
# fourth kind would be treated as "not any of the three" by everything that
# branches on it, which is the silent half-behaviour this library refuses.
konf kk 'REPO_PATH="/x"' 'RC_LABEL="K"' 'OWNER="ada"' 'DOMAIN="d"' 'KIND="machine"'
ladda kk KIND >/dev/null 2>&1
[ "$?" -ne 0 ] && ok "an unknown KIND refuses" || bad "an unknown KIND refuses" "it was accepted"

# KIND IS INDEPENDENT OF RC-FREENESS. Being RC-free is how the bus tells a
# machine session apart TODAY — one fact in three encodings. KIND states it
# once, and the test proves the two are not the same axis by combining them
# against the grain.
konf rcfree 'REPO_PATH="/x"' 'RC_LABEL=""' 'OWNER="ada"' 'DOMAIN="d"' 'KIND="work"'
[ "$(ladda rcfree KIND)" = "work" ] && ok "an RC-free session may still be work" \
  || bad "an RC-free session may still be work" "got '$(ladda rcfree KIND)'"

echo "LIFECYCLE — retirement can be written down"

konf live 'REPO_PATH="/x"' 'RC_LABEL="Live"' 'OWNER="ada"' 'DOMAIN="d"'
[ "$(ladda live LIFECYCLE)" = "active" ] && ok "an absent LIFECYCLE reads as active" \
  || bad "an absent LIFECYCLE reads as active" "got '$(ladda live LIFECYCLE)'"

for l in active suspended retired; do
  konf ll 'REPO_PATH="/x"' 'RC_LABEL="L"' 'OWNER="ada"' 'DOMAIN="d"' "LIFECYCLE=\"$l\""
  [ "$(ladda ll LIFECYCLE)" = "$l" ] && ok "LIFECYCLE=$l is accepted" \
    || bad "LIFECYCLE=$l is accepted" "it was not"
done

konf ll 'REPO_PATH="/x"' 'RC_LABEL="L"' 'OWNER="ada"' 'DOMAIN="d"' 'LIFECYCLE="dead"'
ladda ll LIFECYCLE >/dev/null 2>&1
[ "$?" -ne 0 ] && ok "an unknown LIFECYCLE refuses" || bad "an unknown LIFECYCLE refuses" "accepted"

# A RETIRED SESSION STILL LOADS. This task records the fact and acts on nothing:
# refusing to load a retired conf would BE the behaviour change, and it would
# arrive without anyone choosing it. The test pins that boundary so a later plan
# has to move it deliberately.
konf gone 'REPO_PATH="/x"' 'RC_LABEL="Gone"' 'OWNER="ada"' 'DOMAIN="d"' 'LIFECYCLE="retired"'
[ "$(ladda gone LIFECYCLE)" = "retired" ] && ok "a retired session still loads (recorded, not enforced)" \
  || bad "a retired session still loads" "loading it failed"

printf 'pass=%s fail=%s\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
