#!/bin/bash
# test/desk-serve.test.sh - the desk's Node suites, reported in the shell
# runner's own language.
#
# THE AGGREGATE RUNNER GLOBS test/*.test.sh AND READS A COUNT LINE OFF STDOUT.
# desk/test/*.mjs are Node suites, so without this wrapper they would be
# invisible to `tools/run-tests.sh` - and an invisible suite is the failure mode
# that file's own comments were written against: red for a whole work day
# because nobody's canonical command ran it. This wrapper runs them and
# translates node's TAP summary (`# pass N` / `# fail M`) into the third
# phrasing that runner already parses, `N passed, M failed`, as the LAST line.
#
# NOT ADDED TO run-tests.sh's node list. That loop runs `node --test` in fleet,
# watchdog and watch; adding desk there as well would run these suites twice and
# report them under two names.
#
# NO NODE IS NOT A PASS. A suite that could not run is reported as one failure,
# not as silence: the alternative is a green line that measured nothing.
set -u
here="$(CDPATH= cd -- "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

echo "desk-serve"

if ! command -v node >/dev/null 2>&1; then
  echo "  FAIL node is not on PATH; the desk's Node suites could not run"
  echo "0 passed, 1 failed"
  exit 1
fi

out="$(cd "$here/desk" && node --test test/*.mjs 2>&1)"
rc=$?

printf '%s\n' "$out" | grep -E '^(ok|not ok) [0-9]+ - ' | sed 's/^/  /'

pass="$(printf '%s\n' "$out" | grep -E '^# pass [0-9]+$' | tail -1 | tr -dc '0-9')"
fail="$(printf '%s\n' "$out" | grep -E '^# fail [0-9]+$' | tail -1 | tr -dc '0-9')"

if [ -z "$pass" ] || [ -z "$fail" ]; then
  # No summary at all: node died before it could count. Print what it did say -
  # a stack trace here is the measurement - and report one failure.
  printf '%s\n' "$out" | tail -30
  echo "  FAIL node printed no TAP summary; the suites did not finish"
  echo "0 passed, 1 failed"
  [ "$rc" -eq 0 ] && rc=1
  exit "$rc"
fi

if [ "$rc" -ne 0 ]; then
  printf '%s\n' "$out" | grep -vE '^(ok [0-9]+ - |# Subtest: )' | tail -40
fi

echo "$pass passed, $fail failed"
exit "$rc"
