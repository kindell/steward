#!/bin/bash
# test/mandates-registry.test.sh - the mandate register: a STRICT parser that is
# never sourced, and the one question the adapter asks before a turn.
#
# THE FILE IS NEVER SOURCED. A mandate row says who may spend whose quota on
# what, and a row that can execute is a row that can rewrite that. Every refusal
# below is a line a plain `source` would have accepted and run.
#
# ACCEPT_SOURCE IS THE FIELD THIS REGISTER EXISTS TO GET RIGHT. The authority
# norm: the bus authenticates a channel, not an author, and is coordination,
# not an audit trail. A yes over the bus is refused by NAME, with the norm in
# the refusal, so the person who wrote the row learns why rather than what.
set -u
here="$(CDPATH= cd -- "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
. "$here/lib/registry.sh"
pass=0; fail=0
ok()  { pass=$((pass+1)); printf '  ok   %s\n' "$1"; }
bad() { fail=$((fail+1)); printf '  FAIL %s\n     %s\n' "$1" "${2:-}"; }
is()  { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "wanted '$3', got '$2'"; fi; }
has() { case "$2" in *"$3"*) ok "$1" ;; *) bad "$1" "missing '$3' in: $2" ;; esac; }
FX="$(mktemp -d)"; trap 'rm -rf "$FX"' EXIT
mkdir -p "$FX/mandates.d" "$FX/bad.d"; chmod 700 "$FX/mandates.d" "$FX/bad.d"   # pinned, not the runner's umask
export STEWARD_MANDATES_DIR="$FX/mandates.d"
# A FIXTURE THAT WRITES EMPTY FAILS THE SUITE BY NAME. Found in review: the
# `revoked` and `paused` rows were built with a GNU-only sed append, which BSD
# sed refuses - writing ZERO BYTES - so on a mac both fixtures were empty files,
# the loader refused them as malformed, and every assertion "passed" for a
# reason that had nothing to do with revocation or pause: deleting the
# revocation check left that suite at exactly the same count. A suite about
# consent whose revocation test measures nothing is the one failure it cannot
# afford. So the helpers refuse to hand back an empty fixture, appends are done
# with printf (the two seds do not agree on appending), and a row built to carry
# one specific key checks that the key really reached the file.
row()    { cat > "$FX/mandates.d/$1.conf"; chmod 600 "$FX/mandates.d/$1.conf"; [ -s "$FX/mandates.d/$1.conf" ] || bad "FIXTURE '$1' WRITTEN EMPTY" "the builder produced zero bytes"; }
badrow() { cat > "$FX/bad.d/$1.conf";      chmod 600 "$FX/bad.d/$1.conf";      [ -s "$FX/bad.d/$1.conf" ]      || bad "FIXTURE '$1' WRITTEN EMPTY" "the builder produced zero bytes"; }
with_line()   { printf '%s\n%s\n' "$GOOD" "$1"; }                       # GOOD plus one appended line
fixture_has() { grep -q "^$3=" "$1/$2.conf" || bad "FIXTURE '$2' LACKS $3" "the line the case is about never reached the file"; }
GOOD='PRINCIPAL="simon"
LOGINS="simon-varvet"
LEGAL_OWNER_APPROVED="Varvet"
SCOPE="beneficiary:varvet project:steward repo:kindell/steward job:build"
RESERVE="open-below:25 hard-cap:50 min-days-left:2 idle-hours:48"
VALID_FROM="2026-09-10T00:00:00Z"
VALID_UNTIL="2026-12-31T00:00:00Z"
TERMS_VERSION="1.0"
ACCEPTED_AT="2026-09-09T21:00:00Z"
ACCEPT_SOURCE="unix-account:simon-basement"'
# refuse <name> <desc> <fragment> <sed-edit> - GOOD with one line REPLACED or DELETED (portable sed: s and d only)
refuse() { local n="$1" desc="$2" want="$3" edit="$4" err rc
  printf '%s\n' "$GOOD" | sed -E "$edit" > "$FX/bad.d/$n.conf"; chmod 600 "$FX/bad.d/$n.conf"
  [ -s "$FX/bad.d/$n.conf" ] || bad "FIXTURE '$n' WRITTEN EMPTY" "sed -E '$edit' produced zero bytes"
  err="$( STEWARD_MANDATES_DIR="$FX/bad.d" registry_mandate_load "$n" 2>&1 >/dev/null )"; rc=$?
  if [ "$rc" -eq 0 ]; then bad "$desc" "accepted, should have refused"; else has "$desc" "$err" "$want"; fi; }
# refuse_add <name> <desc> <fragment> <line> - GOOD with one line APPENDED (printf), the key checked present
refuse_add() { local n="$1" desc="$2" want="$3" line="$4" err rc
  with_line "$line" > "$FX/bad.d/$n.conf"; chmod 600 "$FX/bad.d/$n.conf"
  fixture_has "$FX/bad.d" "$n" "${line%%=*}"
  err="$( STEWARD_MANDATES_DIR="$FX/bad.d" registry_mandate_load "$n" 2>&1 >/dev/null )"; rc=$?
  if [ "$rc" -eq 0 ]; then bad "$desc" "accepted, should have refused"; else has "$desc" "$err" "$want"; fi; }

echo "== 1. a valid row loads with every field set, optional ones included =="
printf '%s\n' "$GOOD" | row good
out="$( registry_mandate_load good >/dev/null 2>&1; printf '%s|%s|%s|%s|%s|%s|%s|%s|%s|%s' "$MANDATE_ID" "$MANDATE_PRINCIPAL" "$MANDATE_LOGINS" "$MANDATE_LEGAL_OWNER_APPROVED" "$MANDATE_RESERVE" "$MANDATE_VALID_FROM" "$MANDATE_VALID_UNTIL" "$MANDATE_TERMS_VERSION" "$MANDATE_ACCEPT_SOURCE" "$MANDATE_PAUSED" )"
is "every field lands" "$out" "good|simon|simon-varvet|Varvet|open-below:25 hard-cap:50 min-days-left:2 idle-hours:48|2026-09-10T00:00:00Z|2026-12-31T00:00:00Z|1.0|unix-account:simon-basement|"
printf '%s\n' "$GOOD" | grep -v VALID_UNTIL | row openended
( registry_mandate_load openended >/dev/null 2>&1 ) && ok "VALID_UNTIL is optional: open-ended validity loads" || bad "VALID_UNTIL is optional" "refused"

echo "== 2. the parser refuses what a source would have run =="
refuse cmdsub   "a command substitution refuses" "substitution"  's|^PRINCIPAL=.*|PRINCIPAL="$(id -un)"|'
refuse backtick "a backtick refuses"             "substitution"  's|^SCOPE=.*|SCOPE="beneficiary:`id`"|'
refuse varexp   "a variable expansion refuses"   "substitution"  's|^LOGINS=.*|LOGINS="${HOME}"|'
refuse_add unknown  "an unknown key refuses"         "unknown key"   'PATH="/tmp/evil"'
refuse_add dup      "a duplicate key refuses"        "duplicate key" 'PRINCIPAL="bob"'
refuse unquoted "an unquoted value refuses"      'exactly KEY="VALUE"' 's|^PRINCIPAL=.*|PRINCIPAL=simon|'
refuse trailing "trailing text after the quote refuses" 'exactly KEY="VALUE"' 's|^PRINCIPAL=.*|PRINCIPAL="simon" ; rm -rf /|'
printf 'PRINCIPAL="simon"\r\n' > "$FX/bad.d/cr.conf"; printf '%s\n' "$GOOD" | grep -v PRINCIPAL >> "$FX/bad.d/cr.conf"; chmod 600 "$FX/bad.d/cr.conf"
err="$( STEWARD_MANDATES_DIR="$FX/bad.d" registry_mandate_load cr 2>&1 >/dev/null )"; has "a CR byte refuses" "$err" "control character"

echo "== 3. every required key is required, once each =="
# THE FIXTURE NAME IS LOWERCASED: a mandate id is a slug, and the loader refuses
# the id's grammar BEFORE it opens the file - so `no-PRINCIPAL` was refused for
# its capitals and never reached the missing-key branch this block measures.
# Caught on the first run; the loader was right and the fixture was wrong.
for k in PRINCIPAL LOGINS LEGAL_OWNER_APPROVED SCOPE RESERVE VALID_FROM TERMS_VERSION ACCEPTED_AT ACCEPT_SOURCE; do
  refuse "no-$(printf '%s' "$k" | tr 'A-Z_' 'a-z-')" "missing $k refuses and names it" "missing required key '$k'" "/^$k=/d"
done

echo "== 4. each field's own shape =="
refuse p-caps    "PRINCIPAL is a lowercase slug"            "invalid PRINCIPAL"        's|^PRINCIPAL=.*|PRINCIPAL="Simon"|'
refuse l-empty   "LOGINS must name a login"                 "at least one login"       's|^LOGINS=.*|LOGINS=""|'
# NOT "simon varvet" - that is two VALID slugs separated by a space, which is
# exactly the list grammar LOGINS has, and the loader accepted it correctly on
# the first run. The fixture was wrong, not the loader. Capitals are invalid.
refuse l-bad     "a login slug is a slug"                    "invalid login slug"       's|^LOGINS=.*|LOGINS="Simon-Varvet"|'
refuse lo-empty  "the payer must be named"                   "LEGAL_OWNER_APPROVED"     's|^LEGAL_OWNER_APPROVED=.*|LEGAL_OWNER_APPROVED="  "|'
refuse s-noben   "SCOPE without a beneficiary refuses"       "beneficiary"              's|^SCOPE=.*|SCOPE="project:steward"|'
refuse s-key     "SCOPE has a closed key set"                "unknown SCOPE key"        's|^SCOPE=.*|SCOPE="beneficiary:varvet budget:all"|'
refuse s-shape   "SCOPE tokens are key:value"                "not key:value"            's|^SCOPE=.*|SCOPE="beneficiary:varvet steward"|'
refuse r-key     "RESERVE has a closed key set"              "unknown RESERVE key"      's|^RESERVE=.*|RESERVE="open-below:25 hard-cap:50 min-days-left:2 idle-hours:48 max-jobs:3"|'
refuse r-missing "RESERVE needs all four numbers"            "must carry all of"        's|^RESERVE=.*|RESERVE="open-below:25 hard-cap:50"|'
refuse r-int     "RESERVE values are whole numbers"          "whole number"             's|^RESERVE=.*|RESERVE="open-below:25% hard-cap:50 min-days-left:2 idle-hours:48"|'
refuse r-order   "the cap must sit above the opening level"  "must be above open-below" 's|^RESERVE=.*|RESERVE="open-below:60 hard-cap:50 min-days-left:2 idle-hours:48"|'
refuse r-pct     "percentages are 0-100"                     "0-100"                    's|^RESERVE=.*|RESERVE="open-below:25 hard-cap:150 min-days-left:2 idle-hours:48"|'
refuse t-from    "VALID_FROM is ISO-8601 UTC"                "VALID_FROM must be ISO"   's|^VALID_FROM=.*|VALID_FROM="tomorrow"|'
refuse t-order   "VALID_UNTIL is after VALID_FROM"           "must be after VALID_FROM" 's|^VALID_UNTIL=.*|VALID_UNTIL="2026-01-01T00:00:00Z"|'
refuse t-acc     "ACCEPTED_AT is ISO-8601 UTC"               "ACCEPTED_AT must be ISO"  's|^ACCEPTED_AT=.*|ACCEPTED_AT="2026-09-09"|'
refuse_add t-rev     "REVOKED_AT, when set, is ISO-8601 UTC"     "REVOKED_AT must be ISO"   'REVOKED_AT="yesterday"'
refuse_add paused    "PAUSED is yes, no or absent"               "PAUSED must be"           'PAUSED="maybe"'
refuse terms     "TERMS_VERSION is a version slug"           "invalid TERMS_VERSION"    's|^TERMS_VERSION=.*|TERMS_VERSION="v 1"|'

refuse t-until   "VALID_UNTIL, when set, is ISO-8601 UTC"     "VALID_UNTIL must be ISO"  's|^VALID_UNTIL=.*|VALID_UNTIL="whenever"|'
refuse t-zero    "a stamp must be a real moment - 0000-00-00 is not" "must be ISO"      's|^VALID_FROM=.*|VALID_FROM="0000-00-00T00:00:00Z"|'
refuse s-chars   "SCOPE values have a closed character set"       "characters outside"  's|^SCOPE=.*|SCOPE="beneficiary:var\|vet"|'

echo "== 4b. membership is EXACT - asserted on the HELPER, because no row can reach it =="
# Review, high: `case " $SET " in *" $w "*` tested a substring of a space-run, so
# `unix-account desk-oidc` matched two channels at once and loaded with rc 0.
#
# THE ROW-LEVEL CASES BELOW DO NOT PROVE THE FIX, AND THAT WAS MEASURED: with the
# helper reverted to the substring form this suite still read 74/0. Every path
# into the closed sets refuses a two-entry value EARLIER - SCOPE and RESERVE split
# their tokens on whitespace, ACCEPT_SOURCE refuses whitespace before the colon -
# so nothing a row can carry ever reaches the membership test with a space in it.
# The property therefore has to be asserted where it lives: on the helper. These
# four lines are what turn red when the substring form comes back.
is "the helper refuses a word naming two entries"      "$(_registry_word_in_list 'unix-account desk-oidc' 'unix-account desk-oidc' && echo yes || echo no)" "no"
is "...and the same for a provider pair"               "$(_registry_word_in_list 'claude-max claude-team' "$_REGISTRY_LOGIN_PROVIDERS" && echo yes || echo no)" "no"
is "...and an empty word is not a member of anything"  "$(_registry_word_in_list '' 'unix-account desk-oidc' && echo yes || echo no)" "no"
is "...while a real single entry still matches"        "$(_registry_word_in_list 'desk-oidc' 'unix-account desk-oidc' && echo yes || echo no)" "yes"

echo "== 4c. the row-level paths refuse a two-entry value too, earlier and for their own reason =="
# Review, high: `case " $SET " in *" $w "*` tested a substring of a space-run, so
# a value naming two channels at once passed. The shared helper is exact now;
# each closed set is asserted with a two-entry value.
refuse a-two     "ACCEPT_SOURCE naming two channels is refused"   "whitespace"           's|^ACCEPT_SOURCE=.*|ACCEPT_SOURCE="unix-account desk-oidc:jon"|'
refuse s-two     "a SCOPE key spanning two keys is refused"       "not key:value"        's|^SCOPE=.*|SCOPE="beneficiary domain:varvet"|'
# RESERVE's tokens are split on whitespace before the key is ever looked at, so
# `open-below hard-cap:50` is two tokens - and the FIRST is refused for having no
# value, not for an unknown key. The refusal that matters is that it is refused;
# the fixture now names the one the reader will actually see.
refuse r-two     "a RESERVE token spanning two keys is refused"   "must be a whole number" 's|^RESERVE=.*|RESERVE="open-below hard-cap:50 min-days-left:2 idle-hours:48"|'

echo "== 5. ACCEPT_SOURCE: only a channel this estate authenticates as the person =="
refuse a-bus   "a yes over the bus is refused by name"        "not one this estate authenticates"  's|^ACCEPT_SOURCE=.*|ACCEPT_SOURCE="bus:s-6dbf0fa397e613a1"|'
refuse a-norm  "...and the refusal names the norm"           "not an audit trail"                 's|^ACCEPT_SOURCE=.*|ACCEPT_SOURCE="slack:jon"|'
refuse a-shape "ACCEPT_SOURCE is channel:identifier"         "must be <channel>:<identifier>"      's|^ACCEPT_SOURCE=.*|ACCEPT_SOURCE="unix-account"|'
refuse a-id    "the identifier is a slug"                    "must be a slug"                     's|^ACCEPT_SOURCE=.*|ACCEPT_SOURCE="desk-oidc:jon@varvet.com"|'
printf '%s\n' "$GOOD" | sed 's|^ACCEPT_SOURCE=.*|ACCEPT_SOURCE="desk-oidc:jon"|' | row oidc
( registry_mandate_load oidc >/dev/null 2>&1 ) && ok "a Desk OIDC login is an accepted channel" || bad "desk-oidc accepted" "refused"

echo "== 6. the file's and the register's own state come before the content =="
printf '%s\n' "$GOOD" | row loose; chmod 660 "$FX/mandates.d/loose.conf"
err="$( registry_mandate_load loose 2>&1 >/dev/null )"; rc=$?; is "a group-writable row refuses with rc 78" "$rc" "78"; has "...and names the mode" "$err" "group- or other-writable"
ln -s "$FX/mandates.d/good.conf" "$FX/mandates.d/link.conf"
err="$( registry_mandate_load link 2>&1 >/dev/null )"; rc=$?; is "a symlink row refuses with rc 78" "$rc" "78"
mkdir -p "$FX/loosedir"; chmod 770 "$FX/loosedir"; printf '%s\n' "$GOOD" > "$FX/loosedir/x.conf"; chmod 600 "$FX/loosedir/x.conf"
err="$( STEWARD_MANDATES_DIR="$FX/loosedir" registry_mandate_load x 2>&1 >/dev/null )"; rc=$?; is "a loose register directory refuses before any row is read" "$rc" "78"; has "...with the remedy, quoted" "$err" 'chmod g-w,o-w "'

echo "== 7. a failed load leaks nothing from the previous one =="
registry_mandate_load good >/dev/null 2>&1; registry_mandate_load nosuch >/dev/null 2>&1
is "MANDATE_PRINCIPAL is reset on refusal" "$MANDATE_PRINCIPAL" ""; is "MANDATE_ID is reset on refusal" "$MANDATE_ID" ""

echo "== 8. the register list refuses when absent and lists a dangling link =="
err="$( STEWARD_MANDATES_DIR="$FX/nowhere" registry_mandate_list 2>&1 >/dev/null )"; rc=$?; is "an absent register REFUSES the listing (rc 78)" "$rc" "78"
ln -s "$FX/mandates.d/gone.conf" "$FX/mandates.d/dangling.conf"
has "a dangling symlink is LISTED, so the check can see it" "$(registry_mandate_list 2>/dev/null | tr '\n' ' ')" "dangling"
rm -f "$FX/mandates.d/dangling.conf" "$FX/mandates.d/link.conf" "$FX/mandates.d/loose.conf"

echo "== 9. registry_mandate_active - the question asked before every turn =="
active() { registry_mandate_active "$1" "$2" >/dev/null 2>&1 && echo yes || echo no; }
reason() { registry_mandate_active "$1" "$2" 2>&1 >/dev/null; }
is "within validity, not revoked, not paused: active"   "$(active good 2026-10-01T12:00:00Z)" "yes"
is "AT VALID_FROM exactly: active (inclusive)"              "$(active good 2026-09-10T00:00:00Z)" "yes"
is "a date without a time is a malformed now: not active"   "$(active good 2026-10-01)" "no"
is "before VALID_FROM: not active"                        "$(active good 2026-09-09T23:59:59Z)" "no"; has "...and says so" "$(reason good 2026-09-09T23:59:59Z)" "not valid yet"
is "at VALID_UNTIL: not active (exclusive)"               "$(active good 2026-12-31T00:00:00Z)" "no"; has "...and says so" "$(reason good 2026-12-31T00:00:00Z)" "expired"
is "open-ended: active far in the future"                  "$(active openended 2030-01-01T00:00:00Z)" "yes"
with_line 'REVOKED_AT="2026-09-20T10:00:00Z"' | row revoked; fixture_has "$FX/mandates.d" revoked REVOKED_AT
is "revoked: not active, whatever the dates"               "$(active revoked 2026-10-01T12:00:00Z)" "no"; has "...and names the revocation" "$(reason revoked 2026-10-01T12:00:00Z)" "revoked (since 2026-09-20T10:00:00Z)"
with_line 'PAUSED="yes"' | row paused; fixture_has "$FX/mandates.d" paused PAUSED
is "paused: not active"                                    "$(active paused 2026-10-01T12:00:00Z)" "no"
is "a row that will not load is not active (fail closed)" "$(active nosuch 2026-10-01T12:00:00Z)" "no"
is "a malformed now is not active (fail closed)"           "$(active good 'now')" "no"

echo "== 10. the writer reads back through the strict parser =="
( registry_mandate_write written "$GOOD" true >/dev/null 2>&1 ) && ok "a valid row writes and reads back" || bad "write round trip" "refused"
is "and it loads"      "$( registry_mandate_load written >/dev/null 2>&1 && echo "$MANDATE_LOGINS" )" "simon-varvet"
( registry_mandate_write badw "$(printf '%s\n' "$GOOD" | sed 's|^ACCEPT_SOURCE=.*|ACCEPT_SOURCE="bus:x"|')" true >/dev/null 2>&1 ) && bad "a refused row must not be written" "written" || ok "a row the reader refuses is not written"
[ -e "$FX/mandates.d/badw.conf" ] && bad "...and leaves no file behind" "file exists" || ok "...and leaves no file behind"

echo; printf '%s passed, %s failed\n' "$pass" "$fail"; [ "$fail" -eq 0 ]
