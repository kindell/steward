#!/bin/bash
# test/credential-seam.test.sh - the credential seam: WHEN does a login run out?
#
# THE MEASUREMENT IS INJECTED, AND HERE THAT IS A SECRECY RULE BEFORE IT IS A
# COST ONE. A real credential shim reads a real credential. Every case below is
# a stub written by this file; nothing here may ever name a real account, a
# real credential directory, or hold a real token.
#
# THE ONE PROPERTY THIS SUITE EXISTS FOR is at the bottom, and it is not a
# parser test: a shim that puts a SECRET where a timestamp belongs must not be
# able to get that secret out of the seam - not in a row, not in a note, not on
# stderr. The contract says these columns are times; the guard has to hold when
# the shim is wrong, because a shim that is right needs no guard.
#
# A DEADLINE IS NOT A STATE. No case here asserts the word `expired`, because
# the seam never writes it. It reports WHEN; the comparison against a clock
# belongs to whoever raises an alarm.
set -u

here="$(CDPATH= cd -- "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
pass=0; fail=0
ok()  { pass=$((pass+1)); printf '  ok   %s\n' "$1"; }
bad() { fail=$((fail+1)); printf '  FAIL %s\n     %s\n' "$1" "${2:-}"; }
is()  { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "wanted '$3', got '$2'"; fi; }
has() { case "$2" in *"$3"*) ok "$1" ;; *) bad "$1" "missing '$3' in: $2" ;; esac; }
hasnt() { case "$2" in *"$3"*) bad "$1" "found '$3' in: $2" ;; *) ok "$1" ;; esac; }

FX="$(mktemp -d)"; trap 'rm -rf "$FX"' EXIT
mkdir -p "$FX/home" "$FX/estate" "$FX/logins.d"
# 0700, PINNED - the login reader refuses a group- or other-writable register,
# so a fixture that lets `mkdir` pick the mode measures the HOST, not the
# product. See test/register-modes.test.sh.
chmod 700 "$FX/logins.d"
HOME="$FX/home"; export HOME
STEWARD_ESTATE_ROOT="$FX"; export STEWARD_ESTATE_ROOT

# TWO LOGINS, so a lookup that answers "yes" to everything and one that answers
# "yes" to nothing are both visible; a single-row register cannot tell them apart.
for slug in alpha beta; do
  { printf 'PRINCIPAL="a"\nACCOUNT="%s@fixture.invalid"\n' "$slug"
    printf 'PROVIDER="claude-max"\nCONFIG_DIR="cfg-%s"\nLEGAL_OWNER="a"\n' "$slug"
  } > "$FX/logins.d/$slug.conf"
done
printf 'LABEL_PREFIX="com.fixture.claude"\nHUB_HOST="h1"\nOP_TOKEN_FILE_NAME="fixture-token"\n' \
  > "$FX/estate/steward.conf"

# shellcheck source=/dev/null
. "$here/lib/registry.sh"
# shellcheck source=/dev/null
. "$here/lib/credential.sh"

TAB="$(printf '\t')"

stub() { printf '#!/bin/bash\n%s\n' "$2" > "$FX/$1"; chmod +x "$FX/$1"; printf '%s' "$FX/$1"; }

# THE ROWS ARE READ BACK FROM A FILE, NEVER FROM `$(credential_rows)`, because
# it sets CREDENTIAL_SEAM_REASON and CREDENTIAL_DROPPED in the CALLER's shell
# and a command substitution is a subshell: captured that way both would come
# back as whatever they were before the call.
run_rows() {
  STEWARD_CREDENTIAL_CMD="$1" credential_rows >"$FX/rows" 2>"$FX/err"
  ROWS="$(cat "$FX/rows")"; ERR="$(cat "$FX/err")"
}
field() { printf '%s' "$1" | awk -F'\t' -v n="$2" 'NR==1{print $n}'; }

echo "== 1. the four path gates, and an unconfigured seam that says so quietly =="
STEWARD_CREDENTIAL_CMD="" credential_rows >"$FX/rows" 2>"$FX/err"
is "1a an unset seam is a normal state" "$CREDENTIAL_SEAM_REASON" "seam-not-configured"
is "1b and it prints nothing at all"    "$(cat "$FX/err")" ""
run_rows "credshim"
is "1c a bare name is refused, not resolved through PATH" "$CREDENTIAL_SEAM_REASON" "seam-not-a-path"
run_rows "./credshim"
is "1d a relative path is refused"      "$CREDENTIAL_SEAM_REASON" "seam-not-absolute"
run_rows "$FX/no-such-shim"
is "1e a missing shim is named"         "$CREDENTIAL_SEAM_REASON" "seam-not-found"
printf '#!/bin/bash\ntrue\n' > "$FX/notx"; chmod 644 "$FX/notx"
run_rows "$FX/notx"
is "1f a shim that cannot be run is named" "$CREDENTIAL_SEAM_REASON" "seam-not-executable"

echo "== 2. a shim that fails, says nothing, or hangs =="
run_rows "$(stub failing 'echo "provider refused" >&2; exit 3')"
is  "2a a failing shim leaves a reason" "$CREDENTIAL_SEAM_REASON" "seam-failed"
has "2b and its stderr is kept as evidence" "$ERR" "provider refused"
run_rows "$(stub quiet 'exit 0')"
is  "2c an empty answer is not an estate without credentials" "$CREDENTIAL_SEAM_REASON" "seam-no-output"
STEWARD_CREDENTIAL_TIMEOUT=1 run_rows "$(stub hung 'echo "waiting on the keychain" >&2; sleep 30')"
is  "2d a hung shim is killed and named" "$CREDENTIAL_SEAM_REASON" "seam-timeout"
has "2e and what it managed to say survives the kill" "$ERR" "waiting on the keychain"

echo "== 3. a well-formed answer passes through unchanged =="
run_rows "$(stub good "printf 'alpha\tclaude-max\t2026-09-10T13:30:08Z\t2026-10-09T20:54:20Z\t2026-09-10T06:32:25Z\tmeasured\n'")"
is "3a the row survives"        "$(field "$ROWS" 6)" "measured"
is "3b access time is verbatim" "$(field "$ROWS" 3)" "2026-09-10T13:30:08Z"
is "3c refresh time is verbatim" "$(field "$ROWS" 4)" "2026-10-09T20:54:20Z"
is "3d nothing is dropped"      "$CREDENTIAL_DROPPED" "0"
is "3e and nothing is said"     "$ERR" ""

echo "== 4. the two words that are not failures =="
run_rows "$(stub nocred "printf 'beta\tclaude-max\t\t\t2026-09-10T06:32:25Z\tno-credential\n'")"
is "4a a login with nothing to expire keeps its word" "$(field "$ROWS" 6)" "no-credential"
run_rows "$(stub unread "printf 'beta\tclaude-max\t\t\t2026-09-10T06:32:25Z\tunreadable\n'")"
is "4b a credential that could not be read keeps its word" "$(field "$ROWS" 6)" "unreadable"

echo "== 5. an empty column keeps its place - the hand-rolled splitter =="
# `IFS=<tab> read` collapses a run of tabs, which would slide the state word
# into a time field and publish a vocabulary word AS A TIMESTAMP.
run_rows "$(stub gap "printf 'alpha\tclaude-max\t\t2026-10-09T20:54:20Z\t\tmeasured\n'")"
is "5a an empty access column stays empty" "$(field "$ROWS" 3)" ""
is "5b and refresh does not slide left"    "$(field "$ROWS" 4)" "2026-10-09T20:54:20Z"
is "5c and the state is still the state"   "$(field "$ROWS" 6)" "measured"

echo "== 6. rows the register cannot vouch for are dropped, loudly =="
run_rows "$(stub unknownlogin "printf 'gamma\tclaude-max\t2026-09-10T13:30:08Z\t\t\tmeasured\n'")"
is  "6a a login the register does not know is dropped" "$ROWS" ""
is  "6b and counted"                                   "$CREDENTIAL_DROPPED" "1"
has "6c and never silent"                              "$ERR" "unknown login (1)"
run_rows "$(stub unknownprov "printf 'alpha\tacme-cloud\t2026-09-10T13:30:08Z\t\t\tmeasured\n'")"
is  "6d an unknown provider is dropped"  "$CREDENTIAL_DROPPED" "1"
has "6e and named as its own reason"     "$ERR" "unknown provider (1)"
run_rows "$(stub short "printf 'alpha\tclaude-max\t2026-09-10T13:30:08Z\n'")"
is  "6f a short row is dropped, not padded into a measurement" "$CREDENTIAL_DROPPED" "1"
has "6g and named as malformed"          "$ERR" "malformed (1)"
run_rows "$(stub wide "printf 'alpha\tclaude-max\ta\tb\tc\tmeasured\tnote\textra\n'")"
is  "6h a row with more columns than the contract is dropped" "$CREDENTIAL_DROPPED" "1"

echo "== 7. a time that is not a time is emptied and the FIELD is named =="
run_rows "$(stub badstamp "printf 'alpha\tclaude-max\tyesterday\t2026-10-09T20:54:20Z\t\tmeasured\n'")"
is  "7a the unreadable time is emptied"  "$(field "$ROWS" 3)" ""
is  "7b the readable one is untouched"   "$(field "$ROWS" 4)" "2026-10-09T20:54:20Z"
has "7c and the note says WHICH field"   "$(field "$ROWS" 7)" "access:not-a-stamp"
is  "7d the row is kept - it is still evidence the login was looked at" \
    "$(printf '%s\n' "$ROWS" | grep -c .)" "1"

echo "== 8. a state outside the vocabulary becomes unknown, never a fifth colour =="
run_rows "$(stub badstate "printf 'alpha\tclaude-max\t2026-09-10T13:30:08Z\t\t\texpired\n'")"
is  "8a a word the vocabulary does not have becomes unknown" "$(field "$ROWS" 6)" "unknown"
has "8b and the note says it was the state"  "$(field "$ROWS" 7)" "state:not-in-vocabulary"
is  "8c the measured time is still reported" "$(field "$ROWS" 3)" "2026-09-10T13:30:08Z"

echo "== 9. a row must contain what its own word promises =="
run_rows "$(stub emptymeasured "printf 'alpha\tclaude-max\t\t\t2026-09-10T06:32:25Z\tmeasured\n'")"
is  "9a 'measured' with no time at all is not a measurement" "$(field "$ROWS" 6)" "unknown"
has "9b and says so"  "$(field "$ROWS" 7)" "measured-without-a-time"
run_rows "$(stub contradiction "printf 'beta\tclaude-max\t2026-09-10T13:30:08Z\t\t\tno-credential\n'")"
is  "9c 'no-credential' carrying a time contradicts itself" "$(field "$ROWS" 6)" "unknown"
has "9d and says so"  "$(field "$ROWS" 7)" "no-credential-with-a-time"

echo "== 10. absence becomes a word, and the word is unknown =="
run_rows "$(stub onlyalpha "printf 'alpha\tclaude-max\t2026-09-10T13:30:08Z\t\t\tmeasured\n'")"
hit="$(credential_for alpha "$ROWS")"
is "10a a login that was answered about comes back as itself" "$(field "$hit" 3)" "2026-09-10T13:30:08Z"
miss="$(credential_for beta "$ROWS")"
is "10b a login nobody mentioned is unknown, NOT no-credential" "$(field "$miss" 6)" "unknown"
is "10c and it carries the login it is about"  "$(field "$miss" 1)" "beta"
# A HEALTHY SEAM THAT SIMPLY DID NOT MENTION THE LOGIN still owes the reader a
# word. `not-reported` is that word: the seam worked, and this login was not in
# the answer - which is a different thing to fix than a seam that never ran.
is "10d a working seam that skipped a login says exactly that" "$(field "$miss" 7)" "not-reported"
STEWARD_CREDENTIAL_CMD="" credential_rows >/dev/null 2>&1
miss2="$(credential_for beta "")"
is "10e an unconfigured seam says so in the absent row" "$(field "$miss2" 7)" "seam-not-configured"

echo "== 11. THE RULE: a value cannot leave this seam, even when the shim is wrong =="
# The contract says columns 3-5 are timestamps. This shim has a field-order bug
# and puts the credential itself in one - the case the guard exists for.
SECRET='sk-ant-oat01-FIXTURE-NOT-A-REAL-TOKEN-0123456789abcdef'
run_rows "$(stub leaky "printf 'alpha\tclaude-max\t$SECRET\t\t\tmeasured\n'")"
hasnt "11a the secret is not in the row"      "$ROWS" "$SECRET"
hasnt "11b nor in the note"                   "$(field "$ROWS" 7)" "$SECRET"
hasnt "11c nor on stderr"                     "$ERR" "$SECRET"
hasnt "11d not even a prefix of it - a prefix of a secret is a secret" \
      "$ROWS$ERR" "sk-ant-oat01"
is    "11e and the length is not published either" \
      "$(printf '%s%s' "$ROWS" "$ERR" | grep -oE '[0-9]{2,}' | grep -c "${#SECRET}" || true)" "0"
has   "11f what IS published is the shape that was wrong" "$(field "$ROWS" 7)" "access:not-a-stamp"
# AND THE SEVENTH COLUMN: a shim's own free text is not forwarded, because a
# column the product passes through verbatim is a column a shim can put a
# credential in.
# AND THE STATE COLUMN, which is the one this section did not pin. Columns 3-5
# are timestamps and column 7 is the note; column 6 is a word from a closed
# list - and the gate that refuses a foreign word WRITES THE NOTE ABOUT THE
# VALUE IT JUST REFUSED. Today it writes only the shape. Change it to include
# the value it saw and the secret walks out in the note, and until this case
# existed that change cost ZERO of 69 assertions: the code was right and the
# proof was missing. A shim with a field-order bug can put a credential in any
# column, so every column needs the same case, not just the ones that look
# like they hold data.
run_rows "$(stub leakystate "printf 'alpha\tclaude-max\t2026-09-10T13:30:08Z\t\t\t$SECRET\n'")"
hasnt "11j a secret in the STATE column does not reach the row" "$ROWS" "$SECRET"
hasnt "11k nor stderr"                                          "$ERR"  "$SECRET"
is    "11l the state is the word for a foreign one"  "$(field "$ROWS" 6)" "unknown"
is    "11m and the note names the shape, not the value" "$(field "$ROWS" 7)" "state:not-in-vocabulary"

run_rows "$(stub leakynote "printf 'alpha\tclaude-max\t2026-09-10T13:30:08Z\t\t\tmeasured\t$SECRET\n'")"
hasnt "11g a note written by the shim is not forwarded" "$ROWS" "$SECRET"
is    "11h the note that survives is the seam's own" "$(field "$ROWS" 7)" ""
is    "11i and the measurement is still reported"    "$(field "$ROWS" 3)" "2026-09-10T13:30:08Z"

echo "== 12. the row carries no path, and no-credential is not not-applicable =="
# A PATH INSIDE SOMEBODY'S HOME is not needed to answer this row's question and
# is read by more people than that home's owner. The shim may name one on
# stderr, to the operator repairing it; the row may not carry one.
run_rows "$(stub pathy "printf 'alpha\tclaude-max\t\t\t2026-09-10T06:32:25Z\tunreadable\t/home/someone/.claude/.credentials.json\n'")"
hasnt "12a a path written by the shim does not reach the row" "$ROWS" "/home/someone"
is    "12b the state still says what happened"  "$(field "$ROWS" 6)" "unreadable"
# TWO WORDS THAT MEAN DIFFERENT THINGS DO NOT SHARE A SPELLING. usage's
# `not-applicable` is permanent by construction; a missing credential is
# temporary - somebody signs in and it exists. A view greying out the first is
# right and greying out the second hides the row about to be acted on.
run_rows "$(stub nocred2 "printf 'beta\tclaude-max\t\t\t2026-09-10T06:32:25Z\tno-credential\n'")"
is    "12c a missing credential is not spelled not-applicable" "$(field "$ROWS" 6)" "no-credential"
run_rows "$(stub napp "printf 'beta\tclaude-max\t\t\t2026-09-10T06:32:25Z\tnot-applicable\n'")"
is    "12d and the twin's word is not in this vocabulary"      "$(field "$ROWS" 6)" "unknown"
has   "12e it is refused like any other foreign word"          "$(field "$ROWS" 7)" "state:not-in-vocabulary"

echo "== 13. a value that SPANS two vocabulary entries is not one of them =="
# THESE FIELDS ARE TAB SEPARATED, so a value may legally contain spaces, and
# the substring form `case " $list " in *" $v "*` asks only whether the value
# sits between two spaces somewhere in the list. A value spanning two
# NEIGHBOURS satisfies that. Every case here passed before the gates were
# changed to exact membership - the seam published all three.
run_rows "$(stub twologin "printf 'alpha beta\tclaude-max\t2026-09-10T13:30:08Z\t\t\tmeasured\n'")"
is  "13a a login spanning two register entries is not a login" "$ROWS" ""
has "13b it is dropped as an unknown login"  "$ERR" "unknown login (1)"
run_rows "$(stub twoprov "printf 'alpha\tclaude-max claude-team\t2026-09-10T13:30:08Z\t\t\tmeasured\n'")"
is  "13c a provider spanning two entries is not a provider" "$ROWS" ""
has "13d and named as its own reason"        "$ERR" "unknown provider (1)"
run_rows "$(stub twostate "printf 'alpha\tclaude-max\t2026-09-10T13:30:08Z\t\t\tmeasured no-credential\n'")"
is  "13e a state spanning two entries is not a fifth word"  "$(field "$ROWS" 6)" "unknown"
has "13f and it is named as foreign"         "$(field "$ROWS" 7)" "state:not-in-vocabulary"
# AND THE EMPTY VALUE, which the substring form also accepts: " " appears in
# any list of two or more words.
run_rows "$(stub emptystate "printf 'alpha\tclaude-max\t2026-09-10T13:30:08Z\t\t\t\n'")"
is  "13g an empty state is not a member either" "$(field "$ROWS" 6)" "unknown"

echo "== 14. the vocabulary is a fact, not a habit =="
# WHY THIS EXISTS: removing the state gate costs four assertions, but ADDING a
# word to _CREDENTIAL_STATES costs none - no test enumerates the list, so a
# fifth colour could be introduced silently. This pins the list itself, and
# pins the two words most likely to be added by someone who has not read the
# file: `expired`, which is the derived status this seam refuses to store, and
# `not-applicable`, the twin's word for a permanent absence.
is "14a the state vocabulary is exactly these four" \
   "$_CREDENTIAL_STATES" "measured no-credential unreadable unknown"
is "14b and the word expired is not one of them" \
   "$(_registry_word_in_list expired "$_CREDENTIAL_STATES" && echo IN || echo out)" "out"
is "14c nor the twins word for a permanent absence" \
   "$(_registry_word_in_list not-applicable "$_CREDENTIAL_STATES" && echo IN || echo out)" "out"

echo "== 15. registry_credential_cmd: absent, present, not absolute =="
# THE THIRD KEY OF ONE CLASS, tested with the same three cases as its twins
# rather than assumed to inherit them. No new grammar: if this form is wrong
# on some point it is wrong for LIVENESS_CMD and USAGE_CMD too, and the fix
# belongs to all three in one commit.
#
# TWO CASES BEYOND THE TWINS' OWN, and both earn their place. The program this
# key names READS A CREDENTIAL, so a value resolving against whatever
# directory happened to be current - or against whatever PATH a login shell
# searched - is refused before anything runs it. And the reader sources the
# estate file, so it is proven not to overwrite a caller's own CREDENTIAL_CMD:
# the dynamic-scope rule every loader in registry.sh lives under.
_cbase='LABEL_PREFIX="com.fixture.claude"
HUB_HOST="h1"
OP_TOKEN_FILE_NAME="fixture-token"'
printf '%s\n' "$_cbase" > "$FX/estate/steward.conf"
v="$(registry_credential_cmd)"; rc=$?
is "15a no CREDENTIAL_CMD line: rc 0"          "$rc" "0"
is "15b no CREDENTIAL_CMD line: prints nothing" "$v" ""
printf '%s\nCREDENTIAL_CMD="/abs/cred-shim"\n' "$_cbase" > "$FX/estate/steward.conf"
v="$(registry_credential_cmd)"; rc=$?
is "15c a well-formed value: rc 0"        "$rc" "0"
is "15d a well-formed value: prints it"   "$v" "/abs/cred-shim"
printf '%s\nCREDENTIAL_CMD="relative/cred-shim"\n' "$_cbase" > "$FX/estate/steward.conf"
registry_credential_cmd >/dev/null 2>"$FX/reg.err"; rc=$?
is  "15e a relative value: rc 78"              "$rc" "78"
has "15f the refusal names the field"          "$(cat "$FX/reg.err")" "CREDENTIAL_CMD"
# A BARE NAME IS NOT A PATH, and it is the mistake an operator actually makes:
# `CREDENTIAL_CMD="cred-shim"` reads as if PATH would be searched, and a seam
# that searched PATH would run whatever a login shell happened to find first.
printf '%s\nCREDENTIAL_CMD="cred-shim"\n' "$_cbase" > "$FX/estate/steward.conf"
registry_credential_cmd >/dev/null 2>"$FX/reg.err"; rc=$?
is  "15g a bare name: rc 78"                   "$rc" "78"
has "15h the bare-name refusal names the field" "$(cat "$FX/reg.err")" "CREDENTIAL_CMD"
# AND IT DOES NOT LEAK INTO THE CALLER. The reader sources the estate file, so
# a caller holding its own CREDENTIAL_CMD must not have it overwritten - the
# same dynamic-scope rule the registry loaders live under.
CREDENTIAL_CMD="untouched-by-the-reader"
printf '%s\nCREDENTIAL_CMD="/abs/other"\n' "$_cbase" > "$FX/estate/steward.conf"
registry_credential_cmd >/dev/null 2>&1
is "15i the caller\'s own variable survives the read" "$CREDENTIAL_CMD" "untouched-by-the-reader"
unset CREDENTIAL_CMD
printf '%s\n' "$_cbase" > "$FX/estate/steward.conf"

printf '\n  %d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
