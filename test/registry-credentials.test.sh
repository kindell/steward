#!/bin/bash
# test/registry-credentials.test.sh - `steward registry credentials`, the one
# reader of the credential seam that both the doctor and the watch consume.
#
# WHY A VERB AND NOT TWO READERS. The seam is bash; the watch that must alarm
# on it is node. Letting the watch run the shim itself would put the seam's
# validation in a second language, and a second implementation of a contract
# is a second set of bugs. One verb, two consumers, and an operator who can
# see their own deadlines without reading a log.
#
# THE RULE THIS SUITE EXISTS TO PIN: the measurement carries the TIME, the
# alarm does the COMPARING. Nothing here may look at a clock. A verb that
# decided "expired" would be deciding it against the clock of whichever
# machine rendered the row, and a row rendered on a host with a wrong clock
# would then lie in a way no consumer could detect.
set -u
here="$(CDPATH= cd -- "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
S="$here/bin/steward"
pass=0; fail=0
ok()  { pass=$((pass+1)); printf '  ok   %s\n' "$1"; }
bad() { fail=$((fail+1)); printf '  FAIL %s\n     %s\n' "$1" "${2:-}"; }
is()  { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "wanted '$3', got '$2'"; fi; }
has() { case "$2" in *"$3"*) ok "$1" ;; *) bad "$1" "missing '$3' in: $2" ;; esac; }
hasnt() { case "$2" in *"$3"*) bad "$1" "found '$3' in: $2" ;; *) ok "$1" ;; esac; }

FX="$(mktemp -d)"; trap 'rm -rf "$FX"' EXIT
mkdir -p "$FX/home" "$FX/estate" "$FX/logins.d" "$FX/bin"
chmod 700 "$FX/logins.d"
HOME="$FX/home"; export HOME
export STEWARD_ESTATE_ROOT="$FX" STEWARD_CONFIG_FILE="$FX/no-such-config"

for slug in alpha beta; do
  { printf 'PRINCIPAL="a"\nACCOUNT="%s@fixture.invalid"\n' "$slug"
    printf 'PROVIDER="claude-max"\nCONFIG_DIR="cfg-%s"\nLEGAL_OWNER="a"\n' "$slug"
  } > "$FX/logins.d/$slug.conf"
done
BASE='LABEL_PREFIX="com.fixture.claude"
HUB_HOST="h1"
OP_TOKEN_FILE_NAME="fixture-token"'
printf '%s\n' "$BASE" > "$FX/estate/steward.conf"
TAB="$(printf '\t')"

shim() { # <name> <body> -> path
  { echo '#!/bin/bash'; printf '%s\n' "$2"; } > "$FX/bin/$1"
  chmod +x "$FX/bin/$1"; printf '%s' "$FX/bin/$1"
}
# Two logins, one measured with both stamps and one with nothing to expire.
# ONE OF THESE DEADLINES IS IN THE PAST AND ONE IS IN THE FUTURE, deliberately
# and with FIXED dates. A fixture whose stamps are all in the future gives a
# clock comparison nothing to trip on, so a verb that had one would look
# exactly like a verb that does not - which is what the first version of this
# suite measured, and it measured nothing.
GOOD="$(shim good "printf '%s\n' \
  \"alpha${TAB}claude-max${TAB}2026-10-01T00:00:00Z${TAB}2026-10-09T20:54:20Z${TAB}2026-09-10T07:00:00Z${TAB}measured\" \
  \"beta${TAB}claude-max${TAB}${TAB}${TAB}2026-09-10T07:00:00Z${TAB}no-credential\" \
  \"alpha${TAB}claude-max${TAB}2020-01-02T00:00:00Z${TAB}2020-01-09T00:00:00Z${TAB}2020-01-01T00:00:00Z${TAB}measured\"")"

echo "== the estate names the shim, and the verb finds it there =="
printf '%s\nCREDENTIAL_CMD="%s"\n' "$BASE" "$GOOD" > "$FX/estate/steward.conf"
out="$(timeout 60 bash "$S" registry credentials 2>"$FX/err")"; rc=$?
is  "rc 0"                       "$rc" "0"
is  "one line per row"           "$(printf '%s\n' "$out" | grep -c .)" "3"
has "the measured login is there"  "$out" "alpha"
has "and carries its refresh time" "$out" "2026-10-09T20:54:20Z"
has "the login with nothing to expire says so" "$out" "no-credential"
is  "nothing on stderr"          "$(cat "$FX/err")" ""

echo "== THE MEASUREMENT CARRIES THE TIME; IT NEVER COMPARES =="
# The stamps above are in the past relative to no clock in particular. Whatever
# today is when this suite runs, the verb must not have decided anything about
# it: no word here may be a verdict.
# BOTH OUTPUT SHAPES, because the first version of this check looked only at
# the TSV and a clock comparison planted in the --json branch cost it nothing.
jout="$(timeout 60 bash "$S" registry credentials --json 2>/dev/null)"
for verdict in expired expiring valid soon overdue urgent; do
  hasnt "no verdict word '$verdict' in the rows"  "$out"  "$verdict"
  hasnt "no verdict word '$verdict' in the JSON"  "$jout" "$verdict"
done
# AND THE POSITIVE HALF: the row whose deadline is years past is still exactly
# the word the shim wrote. Absence of a verdict word is not the same claim as
# the state surviving untouched.
is "a long-past deadline is still the shim's own word" \
   "$(printf '%s\n' "$out" | awk -F'\t' '$3=="2020-01-02T00:00:00Z"{print $6}')" "measured"

echo "== an unconfigured seam is a normal state, not a failure =="
printf '%s\n' "$BASE" > "$FX/estate/steward.conf"
out="$(timeout 60 bash "$S" registry credentials 2>"$FX/err")"; rc=$?
is  "rc 0 with no CREDENTIAL_CMD" "$rc" "0"
is  "and prints no rows"          "$out" ""
has "and says why, on stderr"     "$(cat "$FX/err")" "seam-not-configured"

echo "== a shim that fails is reported, and the rows are not invented =="
BAD="$(shim bad "echo 'the provider refused' >&2; exit 3")"
printf '%s\nCREDENTIAL_CMD="%s"\n' "$BASE" "$BAD" > "$FX/estate/steward.conf"
out="$(timeout 60 bash "$S" registry credentials 2>"$FX/err")"; rc=$?
is  "a failing shim is rc 78"     "$rc" "78"
is  "and no rows are printed"     "$out" ""
has "the reason is named"         "$(cat "$FX/err")" "seam-failed"
has "and the shim's own words survive as evidence" "$(cat "$FX/err")" "the provider refused"

echo "== the environment wins over the estate, as everywhere else =="
printf '%s\nCREDENTIAL_CMD="%s"\n' "$BASE" "$BAD" > "$FX/estate/steward.conf"
out="$(STEWARD_CREDENTIAL_CMD="$GOOD" timeout 60 bash "$S" registry credentials 2>/dev/null)"
has "the environment's shim was used" "$out" "alpha"

echo "== --json is the same measurement, shaped for the watch =="
printf '%s\nCREDENTIAL_CMD="%s"\n' "$BASE" "$GOOD" > "$FX/estate/steward.conf"
out="$(timeout 60 bash "$S" registry credentials --json 2>/dev/null)"
has "it is an object with a rows array" "$out" '"rows"'
has "the login is a field"              "$out" '"login"'
has "the refresh deadline is a field"   "$out" '"refresh_expires"'
has "the state is a field"              "$out" '"state"'
# THE JSON IS PARSED, NOT PATTERN-MATCHED. A test that only greps cannot tell
# valid JSON from a string that happens to contain the right words, and the
# consumer is a JSON parser.
if printf '%s' "$out" | "${STEWARD_NODE:-node}" -e \
     'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>{const o=JSON.parse(s);
      if(o.rows.length!==3) throw new Error("rows="+o.rows.length);
      if(o.rows[0].login!=="alpha") throw new Error("login="+o.rows[0].login);
      if(o.rows[1].state!=="no-credential") throw new Error("state="+o.rows[1].state);})' 2>"$FX/jerr"; then
  ok "the JSON parses and carries the two rows"
else
  bad "the JSON parses and carries the two rows" "$(cat "$FX/jerr")"
fi

echo "== an unknown flag is refused rather than ignored =="
timeout 60 bash "$S" registry credentials --nope >/dev/null 2>"$FX/err"; rc=$?
is  "rc 64"              "$rc" "64"
has "and names the flag" "$(cat "$FX/err")" "--nope"

printf '\n  %d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
