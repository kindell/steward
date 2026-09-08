#!/bin/bash
# test/bus-secret-guard.test.sh - bus_secret_guard, the line-by-line refusal
# gate in linux/bus-send, has never had a product test of its own before this
# file.
#
# EXTRACTION, NOT SOURCING. linux/bus-send is a script with `set -euo pipefail`
# and side effects at the top, not a library, so this suite does not source it.
# It pulls the two pieces it needs - the noun list and the function body - out
# of the file with sed and evals just that slice. bus-send gains no
# source-mode knob for this; the extraction is entirely the test's technique.
#
# WHY THIS SUITE EXISTS NOW. The prefix alternation for the OpenAI family was
# `sk-[A-Za-z0-9]`: any word ending in "sk" followed by a hyphen and one
# alphanumeric character. Three legitimate messages were refused on a single
# day because they named a file or used a common adjective ending in "-sk"
# before a hyphen. The fix adds a left boundary (start of line or a
# non-alphanumeric character before "sk-") and a length floor of sixteen
# characters after the prefix, so a real key is still caught while an
# ordinary word on "-sk" passes. The refusal also now names the FAMILY that
# matched, never the string that matched it.
set -u
here="$(CDPATH= cd -- "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
pass=0; fail=0
ok()  { pass=$((pass+1)); printf '  ok   %s\n' "$1"; }
bad() { fail=$((fail+1)); printf '  FAIL %s\n     %s\n' "$1" "${2:-}"; }
is()  { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "wanted '$3', got '$2'"; fi; }
has() { case "$2" in *"$3"*) ok "$1" ;; *) bad "$1" "missing '$3' in: $2" ;; esac; }
hasnt() { case "$2" in *"$3"*) bad "$1" "found '$3' in: $2" ;; *) ok "$1" ;; esac; }

eval "$(sed -n '/^_BUS_SECRET_NOUNS=/p; /^bus_secret_guard() {/,/^}/p' "$here/linux/bus-send")"

ERRFILE="$(mktemp)"; trap 'rm -f "$ERRFILE"' EXIT

# guard_rc <text> - runs the guard on one line of text, returns its rc and
# leaves stderr in $ERRFILE for the caller to inspect with `has`.
guard_rc() {
  local _rc
  bus_secret_guard "$1" >/dev/null 2>"$ERRFILE"
  _rc=$?
  printf '%s' "$_rc"
}

err() { cat "$ERRFILE"; }

echo "a. the sk- rule gets a left boundary: ordinary words on -sk pass"
is "desk-spec: passes"                    "$(guard_rc 'desk-spec')"                    "0"
is "falsk-signal: passes"                 "$(guard_rc 'falsk-signal')"                 "0"
is "teknisk-skuld: passes"                "$(guard_rc 'teknisk-skuld')"                "0"
is "svensk-text: passes"                  "$(guard_rc 'svensk-text')"                  "0"
is "see steward-desk-design.md: passes"   "$(guard_rc 'see steward-desk-design.md')"   "0"
is "the desk-snapshot job: passes"        "$(guard_rc 'the desk-snapshot job')"        "0"
is "letter before sk-, any length: passes" "$(guard_rc 'desk-abcdefghijklmnopqrstuvwxyz')" "0"

echo "b. the sk- rule gets a length floor of sixteen characters"
is "sk-short (below the floor): passes"          "$(guard_rc 'sk-short')"                       "0"
is "15 chars after the prefix: passes"           "$(guard_rc 'x sk-abcdefghijklmno')"            "0"
is "16 chars after the prefix: refused"          "$(guard_rc 'x sk-abcdefghijklmnopqrst')"       "65"

echo "c. a real key is still refused, whatever comes before it"
r="$(guard_rc 'sk-proj-ABCDEFGHIJKLMNOPQRSTUVWXYZabcdef012345')"
is "sk- alone on a line: refused"         "$r" "65"
has "...names the sk- family"             "$(err)" "(sk-)"
hasnt "...never echoes the matched key"   "$(err)" "sk-proj-ABCDEFGHIJKLMNOPQRSTUVWXYZabcdef012345"
has "...the second refusal line is still printed" "$(err)" "does the same job"
r="$(guard_rc 'key: sk-abcdefghijklmnopqrst')"
is "sk- preceded by a space: refused"     "$r" "65"
has "...names the sk- family"             "$(err)" "(sk-)"
r="$(guard_rc '(sk-abcdefghijklmnopqrst)')"
is "sk- preceded by a parenthesis: refused" "$r" "65"
has "...names the sk- family"             "$(err)" "(sk-)"

echo "d. the other prefix families are unaffected, and the refusal names each"
r="$(guard_rc 'ghp_abcdef')"
is "ghp_ token: refused"    "$r" "65"
has "...names the github family" "$(err)" "ghp_"
hasnt "...never echoes the matched token" "$(err)" "ghp_abcdef"
r="$(guard_rc 'xoxb-1')"
is "xoxb- token: refused"   "$r" "65"
has "...names the xox- family"   "$(err)" "xox-"
hasnt "...never echoes the matched token" "$(err)" "xoxb-1"
r="$(guard_rc 'AKIAABCDEFGHIJKL')"
is "AKIA token: refused"    "$r" "65"
has "...names the AKIA family"   "$(err)" "AKIA"
hasnt "...never echoes the matched token" "$(err)" "AKIAABCDEFGHIJKL"
r="$(guard_rc '-----BEGIN RSA PRIVATE KEY-----')"
is "PEM block: refused"     "$r" "65"
has "...names the PEM family"    "$(err)" "PEM private key"
hasnt "...never echoes the matched header line" "$(err)" "-----BEGIN RSA PRIVATE KEY-----"
r="$(guard_rc 'eyJabcdefghij')"
is "JWT token: refused"     "$r" "65"
has "...names the JWT family"    "$(err)" "JWT"
hasnt "...never echoes the matched token" "$(err)" "eyJabcdefghij"

echo "e. --not-a-secret still bypasses everything, including a real-looking key"
_NOT_A_SECRET=1
r="$(guard_rc 'sk-ABCDefgh12345678ABCDefgh12345678ABCD')"
unset _NOT_A_SECRET
is "40-char key with the flag set: passes" "$r" "0"

echo "f. the noun-plus-value rule is untouched by the prefix work"
r="$(guard_rc 'password: Abc12345')"
is "noun plus a value-shaped token: refused" "$r" "65"
has "...the second refusal line is still printed" "$(err)" "does the same job"

echo "g. a family whose pattern cannot compile fails CLOSED, not open"
# THE PROPERTY UNDER TEST: grep returns 0 on a match, 1 on no match, and 2 (or
# higher) when the pattern itself will not compile. A guard that folds every
# non-zero exit into "no match" would let a broken pattern pass every line in
# silence - the one failure mode this guard cannot afford. There is no
# production knob to provoke this from outside: the shipped pattern table is
# always valid ERE, so grep never fails to run on it. This case therefore
# builds a SECOND, renamed copy of the function from a text copy of the
# source, with one prefix pattern swapped for an invalid ERE - a single open
# parenthesis, which grep cannot compile - and calls that copy instead.
# Extraction only, the same technique as the top of this file; linux/bus-send
# itself is not touched and gains no test-only knob.
_broken_src="$(sed -n '/^bus_secret_guard() {/,/^}/p' "$here/linux/bus-send")"
_broken_src="$(printf '%s\n' "$_broken_src" | sed \
  -e 's/^bus_secret_guard() {/bus_secret_guard_broken() {/' \
  -e "s/'(ghp_|gho_|ghs_|github_pat_)'/'('/")"
eval "$_broken_src"
bus_secret_guard_broken 'irrelevant text' >/dev/null 2>"$ERRFILE"
r="$?"
is "broken pattern table: fails closed, rc 65" "$r" "65"
has "...names the failure, not a false pass" "$(err)" "could not run"

echo
printf '%s: %d passed, %d failed\n' "$(basename "$0")" "$pass" "$fail"
[ "$fail" -eq 0 ]
