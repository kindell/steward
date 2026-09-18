#!/usr/bin/env bash
# test/desk-serve-failure-report.test.sh — that a failing run's own words survive the
# wrapper's filter.
#
# WHY THIS SUITE EXISTS, measured and not imagined. On 2026-09-18 `desk-serve` was red
# three times with `251/1`, and the fleet spent a working day varying the INPUT to that
# number — bisecting the suite list, swapping node major versions, twelve runs across
# two estates — because nobody could read the failure's own message. It had been
# thrown away every time, by one line in the wrapper:
#
#     grep -vE '^(ok [0-9]+ - |# Subtest: )' | tail -40
#
# node writes a test's diagnostic block DIRECTLY AFTER that test's `not ok` line.
# `not ok 198` stood on line 199 of 272; the window kept 233-272 and the block sat 34
# lines outside it. What RED_DIR archived was what the wrapper had already discarded,
# so the archive looked complete and was not.
#
# The assertion that failed appends the server's own stderr to its message. That string
# was the only thing in the entire run produced by the process that went wrong.
#
# THE CONTROL IS THE POINT OF THIS FILE. A fixture the OLD filter would also have
# carried proves nothing, so the suite asserts, in line, that `tail -40` of the very
# same input does NOT contain the message. If someone restores the old filter, or
# writes a fixture where the failure happens to fall near the end, that assertion is
# what refuses.
set -u
here="$(CDPATH= cd -- "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
pass=0; fail=0
ok()  { pass=$((pass+1)); printf '  ok   %s\n' "$1"; }
bad() { fail=$((fail+1)); printf '  FAIL %s\n     %s\n' "$1" "${2:-}"; }
is()  { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "wanted '$3', got '$2'"; fi; }
has() { case "$2" in *"$3"*) ok "$1" ;; *) bad "$1" "'$3' not in: $2" ;; esac; }
hasnt() { case "$2" in *"$3"*) bad "$1" "'$3' WAS in the output" ;; *) ok "$1" ;; esac; }
echo "desk-serve-failure-report"

eval "$(sed -n '/^desk_serve_failure_report() {/,/^}/p' "$here/test/desk-serve.test.sh")"

# THE EARLY EXIT SPEAKS THE RUNNER'S FORMAT. A bail-out written in prose turns "the
# function is gone" into "this suite said nothing", and unmeasured is the one outcome
# the runner exists to prevent.
type desk_serve_failure_report >/dev/null 2>&1 || {
  printf '  FAIL the function could not be extracted from test/desk-serve.test.sh\n'
  printf '\n  0 passed, 1 failed\n'
  exit 1
}

MSG="the bridge s socket was never created; stderr: EADDRINUSE fixture"

# --- the fixture reproduces the geometry that defeated the old filter -------------
# THE SHAPE IS MEASURED, AND TWO WRONG FIXTURES CAME FIRST. Both were caught by the
# control below, which is the whole reason it is written as an assertion and not as a
# comment.
#   first cut:  bare `ok` lines, nothing else. The old filter carried the message
#               fine, because after the grep almost nothing was left to push it out.
#   second cut: passing tests WITH their YAML blocks, but all of them before the
#               failure. `tail -40` then lands ON the failure, because the failure
#               was last.
# Measured against a real run of desk/test/serve.test.mjs: 558 lines in, 428 still
# standing after `grep -vE '^(ok [0-9]+ - |# Subtest: )'`. The grep removes a
# passing test's header and its `ok` line and LEAVES its four-line YAML block.
#
# So the geometry needs both halves, and the real run had both: the failure was the
# 198th of 252, which puts 197 passing tests in front of it and 54 BEHIND it. The 54
# behind are what push it out of the window - roughly 216 lines of other tests'
# success, between the failure and the end of the stream.
fixture() {
  echo "TAP version 13"
  i=1
  while [ "$i" -le 197 ]; do
    _fixture_pass "$i"
    i=$((i+1))
  done
  echo "not ok 198 - the default paths come from the bridge, not from a literal"
  echo "  ---"
  echo "  duration_ms: 20001.5"
  echo "  location: 'desk/test/serve.test.mjs:782:1'"
  echo "  failureType: 'testCodeFailure'"
  echo "  error: |-"
  echo "    $MSG"
  echo "  code: 'ERR_ASSERTION'"
  echo "  ..."
  # AND THE 54 THAT PASSED AFTER IT. Without these the failure is the last thing in
  # the stream and any tail carries it - which is the fixture that fooled the second
  # cut of this file.
  i=199
  while [ "$i" -le 252 ]; do
    _fixture_pass "$i"
    i=$((i+1))
  done
  echo "1..252"
  echo "# tests 252"
  echo "# pass 251"
  echo "# fail 1"
}
_fixture_pass() {
  printf '# Subtest: passing test %s\n' "$1"
  printf 'ok %s - passing test %s\n' "$1" "$1"
  printf '  ---\n  duration_ms: 1.5\n  type: %s\n  ...\n' "'test'"
}

out="$(fixture | desk_serve_failure_report)"

has "the failing test's name survives"        "$out" "not ok 198 - the default paths"
has "and its diagnostic block with it"        "$out" "failureType: 'testCodeFailure'"
has "and the message the assertion built"     "$out" "$MSG"
has "the file and line are still readable"    "$out" "serve.test.mjs:782"
has "the summary still reaches the reader"    "$out" "# fail 1"

# THE CONTROL. Without this the suite would pass on a fixture the old filter also
# carried, and would then be asserting nothing about the repair.
old="$(fixture | grep -vE '^(ok [0-9]+ - |# Subtest: )' | tail -40)"
hasnt "the OLD filter loses the message on this same input" "$old" "$MSG"
hasnt "and loses the failing test's name too"               "$old" "not ok 198"

# --- what must NOT come back ------------------------------------------------------
hasnt "passing lines are not echoed back"  "$out" "ok 42 - passing test 42"
hasnt "nor the Subtest headers"            "$out" "# Subtest: passing test 42"

# --- a broken run is bounded, and says what it left out ---------------------------
many() {
  i=1
  while [ "$i" -le 25 ]; do
    printf 'not ok %d - failure number %d\n' "$i" "$i"
    printf '  ---\n  error: |-\n    detail %d\n  ...\n' "$i"
    i=$((i+1))
  done
  echo "# fail 25"
}
m="$(many | desk_serve_failure_report)"
has  "the first failure is kept"               "$m" "not ok 1 - failure number 1"
has  "and the tenth"                           "$m" "not ok 10 - failure number 10"
hasnt "the eleventh is not"                    "$m" "not ok 11 - failure number 11"
has  "and the count left out is stated"        "$m" "and 15 more failing tests"

printf '\n  %d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
