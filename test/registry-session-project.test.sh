#!/bin/bash
# test/registry-session-project.test.sh - `steward registry session project`:
# put an owner's session rows into their home, and say what changed.
#
# WHY THE VERB EXISTS. Six registers reach every home through the estate's
# manifest as whole directories. sessions.d cannot travel that way - a home may
# see only its OWNER's rows, and a manifest row copies a directory whole - so
# session rows have always arrived as a SIDE EFFECT of enrolment: written once,
# and never reconciled again. Measured before the verb was written: five homes
# on the estate it was written for, all five already correct. The verb is not
# a repair; it is the ability to KNOW, on demand, rather than by hand.
#
# SECTION 1 IS A REGRESSION TEST FOR THE VERB'S FIRST DRAFT, and it is the
# reason --plan is the mode this verb is used in first. That draft called
# `registry_session_load`, which does not exist. Bash returned 127, the
# `|| continue` beside it read that as "not a row I own", every estate row was
# skipped, and every row ALREADY IN THE HOME was therefore classed as no
# longer owned. The plan offered to delete thirteen of one person's sessions
# and seven of another's. A missing command read as an answer.
set -u
here="$(CDPATH= cd -- "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
S="$here/bin/steward"
pass=0; fail=0
ok()  { pass=$((pass+1)); printf '  ok   %s\n' "$1"; }
bad() { fail=$((fail+1)); printf '  FAIL %s\n     %s\n' "$1" "${2:-}"; }
is()  { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "wanted '$3', got '$2'"; fi; }
has() { case "$2" in *"$3"*) ok "$1" ;; *) bad "$1" "missing '$3' in: $2" ;; esac; }
hasnt() { case "$2" in *"$3"*) bad "$1" "found '$3'" ;; *) ok "$1" ;; esac; }

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
ROOT="$T/estate"; HOMEDIR="$T/home"
mkdir -p "$ROOT/estate" "$ROOT/sessions.d" "$ROOT/accounts.d" "$ROOT/entities.d" "$HOMEDIR/scripts/sessions.d"
chmod 700 "$ROOT/accounts.d"
printf 'ESTATE_NAME="fixture"\nLABEL_PREFIX="com.fixture.claude"\nHUB_HOST="host-a"\nOP_TOKEN_FILE_NAME="fixture-token"\n' > "$ROOT/estate/steward.conf"
printf 'NAME="Acme"\nMEMBERS="ann"\n' > "$ROOT/entities.d/acme.conf"
printf 'PRINCIPAL="ann"\nHOST="host-a"\nUSERNAME="%s"\n' "$(id -un)" > "$ROOT/accounts.d/ann-host-a.conf"
chmod 600 "$ROOT/accounts.d/ann-host-a.conf"
# The home is resolved through the product's own hook, so the suite never
# writes into the running user's real home.
printf '#!/bin/sh\nprintf "%%s" "%s"\n' "$HOMEDIR" > "$T/homelookup"; chmod 755 "$T/homelookup"
export STEWARD_ESTATE_ROOT="$ROOT" STEWARD_SELF_HOST="host-a" \
       STEWARD_HOME_LOOKUP_CMD="$T/homelookup" STEWARD_CONFIG_FILE="$T/no-such-config"

row() { # <id> <owner> <host> [label]
  printf 'OWNER="%s"\nHOST="%s"\nDOMAIN="acme"\nREPO_PATH="%s"\nID="%s"\nRC_LABEL="%s"\n' \
    "$2" "$3" "$HOMEDIR" "$1" "${4:-Fixture $1}" > "$ROOT/sessions.d/$1.conf"
}
inhome() { printf '%s' "$1" > /dev/null; }   # readability helper for intent
proj() { "$S" registry session project "$@" 2>&1; }
n_home() { ls "$HOMEDIR/scripts/sessions.d"/*.conf 2>/dev/null | wc -l | tr -d ' '; }

A=s-000000000000000a; B=s-000000000000000b; C=s-000000000000000c
row "$A" ann host-a; row "$B" ann host-a

echo "== 1. a home that already agrees is reported as agreeing, not as garbage =="
# THE REGRESSION. With the loader misnamed this said "would remove" for every
# row in the home and "unchanged 0".
cp "$ROOT/sessions.d/$A.conf" "$ROOT/sessions.d/$B.conf" "$HOMEDIR/scripts/sessions.d/"
out="$(proj ann --plan)"
is    "1a nothing would change"        "$(printf '%s' "$out" | grep -c 'would ')" "0"
has   "1b and it says how many agree"  "$out" "unchanged 2, changed 0"
hasnt "1c and offers to remove nothing" "$out" "would remove"
is    "1d the home is untouched"       "$(n_home)" "2"

echo "== 2. --plan writes nothing, and the run that follows does =="
row "$C" ann host-a
out="$(proj ann --plan)"
has "2a the plan names the row it would add" "$out" "would add    $C"
is  "2b but the home still has two"          "$(n_home)" "2"
out="$(proj ann)"
has "2c the run says it added it"            "$out" "added    $C"
is  "2d and the home has three"              "$(n_home)" "3"
is  "2e byte for byte what the register says" \
    "$(diff -q "$ROOT/sessions.d/$C.conf" "$HOMEDIR/scripts/sessions.d/$C.conf" >/dev/null && echo same || echo DIFFERS)" "same"

echo "== 3. idempotent: the second run changes nothing and says so =="
out="$(proj ann)"
is  "3a nothing changed"               "$(printf '%s' "$out" | grep -cE 'added|updated|removed')" "0"
has "3b and the receipt says so"       "$out" "unchanged 3, changed 0"

echo "== 4. a row that drifted is updated, not left =="
printf 'OWNER="ann"\nHOST="host-a"\nRC_LABEL="Stale"\n' > "$HOMEDIR/scripts/sessions.d/$A.conf"
out="$(proj ann --plan)"
has "4a the plan names it"      "$out" "would update $A"
out="$(proj ann)"
has "4b and the run updates it" "$out" "updated  $A"
is  "4c back to the register's bytes" \
    "$(diff -q "$ROOT/sessions.d/$A.conf" "$HOMEDIR/scripts/sessions.d/$A.conf" >/dev/null && echo same || echo DIFFERS)" "same"

echo "== 5. a row the register no longer owns is pruned =="
# A session moved to another person, or deleted, must not keep answering from
# the old home.
rm -f "$ROOT/sessions.d/$C.conf"
out="$(proj ann --plan)"
has "5a the plan names the prune"  "$out" "would remove $C"
is  "5b and the home still has it" "$(n_home)" "3"
out="$(proj ann)"
has "5c the run removes it"        "$out" "removed  $C"
is  "5d and the home has two"      "$(n_home)" "2"

echo "== 6. the prune touches ONLY files shaped like a session id =="
# Everything else in that directory belongs to somebody, and this verb does not
# know whom. Measured on a live estate: two homes held 26 `.bak-*` files from
# old renames, invisible to the register's own *.conf glob and none of the
# verb's business.
printf 'x\n' > "$HOMEDIR/scripts/sessions.d/notes.conf"
printf 'x\n' > "$HOMEDIR/scripts/sessions.d/$A.conf.bak-rename"
printf 'x\n' > "$HOMEDIR/scripts/sessions.d/s-nothex.conf"
out="$(proj ann)"
is "6a a plain name is not a session row"        "$( [ -f "$HOMEDIR/scripts/sessions.d/notes.conf" ] && echo kept || echo GONE )" "kept"
is "6b a rename backup is left alone"            "$( [ -f "$HOMEDIR/scripts/sessions.d/$A.conf.bak-rename" ] && echo kept || echo GONE )" "kept"
is "6c an id-shaped-but-not-hex name is left alone" "$( [ -f "$HOMEDIR/scripts/sessions.d/s-nothex.conf" ] && echo kept || echo GONE )" "kept"
hasnt "6d and none of them is mentioned"         "$out" "notes"

echo "== 7. another owner's rows, and another host's, are not this home's =="
row "$C" bob host-a
row s-000000000000000d ann other-host
out="$(proj ann --plan)"
hasnt "7a a row owned by somebody else is not projected" "$out" "$C"
hasnt "7b nor a row that lives on another host"          "$out" "s-000000000000000d"
has   "7c and the receipt still accounts for the rest"   "$out" "unchanged 2"

echo "== 8. an owner with no account on this host is refused, not guessed =="
out="$(proj nobody --plan)"; rc=$?
is  "8a rc 78"                       "$rc" "78"
# THE REFUSAL MUST NAME THE MISSING ROW. "no account on this host" is true and
# sends the reader into the verb's source looking for a forgotten case; what is
# missing is a REGISTER ROW, and an operator told that knows what to do. This
# case pins the wording, not just the refusal.
has "8b it names the register that lacks the row" "$out" "no accounts.d row on 'host-a'"
has "8c and the owner it looked for"              "$out" "names 'nobody'"
has "8d and says the fix is a row, not a flag"    "$out" "the fix is a register row, not a flag"
out="$(proj 'Bad Owner' --plan)"; rc=$?
is  "8e an invalid owner is rc 64"   "$rc" "64"

echo "== 9. the json receipt carries the same three lists =="
row "$C" ann host-a
out="$(proj ann --plan --json)"
has "9a plan is marked as a plan"    "$out" '"plan":true'
has "9b the added list carries the row" "$out" "\"added\":[\"$C\"]"
has "9c and the counts are there"    "$out" '"changed":1'
out="$(proj ann --json)"
has "9d a real run says so"          "$out" '"plan":false'

printf '\n  %d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
