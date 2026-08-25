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
printf 'pass=%s fail=%s\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
