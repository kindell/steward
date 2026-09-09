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
# THE REPORTER IS PINNED, NOT INHERITED. `# pass N` is TAP, and TAP stopped
# being node's default reporter: on 2026-09-09 the same tree, in the same
# minute, measured 179 passed / 0 failed under node v22.23.1 and 0 passed /
# 1 failed ("node printed no TAP summary") under node v25.9.0, whose default
# reporter writes the count as "<info glyph> pass 179" - not `# pass 179`,
# so neither grep below matched anything. A green suite turned silently red
# the day a host upgraded node, and three agents who reported it were
# disbelieved because every checker had node 22 pinned in PATH. So the
# invocation below names `--test-reporter=tap`: this file parses TAP, and it
# must ASK for TAP rather than hope the interpreter still defaults to it.
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

out="$(cd "$here/desk" && node --test --test-reporter=tap test/*.mjs 2>&1)"
rc=$?

printf '%s\n' "$out" | grep -E '^(ok|not ok) [0-9]+ - ' | sed 's/^/  /'

pass="$(printf '%s\n' "$out" | grep -E '^# pass [0-9]+$' | tail -1 | tr -dc '0-9')"
fail="$(printf '%s\n' "$out" | grep -E '^# fail [0-9]+$' | tail -1 | tr -dc '0-9')"

if [ -z "$pass" ] || [ -z "$fail" ]; then
  # No summary at all: node died before it could count. Print what it did say -
  # a stack trace here is the measurement - and report one failure.
  printf '%s\n' "$out" | tail -30
  # NAME THE OTHER SUSPECT. A crash and an unhonoured --test-reporter=tap look
  # identical from here: both leave `pass` empty. They are told apart by
  # whether node counted at all - if some line ends in "pass <n>" without the
  # leading "# ", node RAN the suites and reported them in a format this file
  # does not parse, which is a harness fault and not a red suite. Say so, with
  # the interpreter's version, so the next reader does not spend a work day
  # disbelieving a true red.
  if printf '%s\n' "$out" | grep -qE '[[:space:]]pass [0-9]+$'; then
    echo "  FAIL node ignored --test-reporter=tap and counted in another format"
    echo "  FAIL node is $(node --version 2>/dev/null); this parser needs TAP (\`# pass N\`)"
  else
    echo "  FAIL node printed no TAP summary; the suites did not finish"
  fi
  echo "0 passed, 1 failed"
  [ "$rc" -eq 0 ] && rc=1
  exit "$rc"
fi

if [ "$rc" -ne 0 ]; then
  printf '%s\n' "$out" | grep -vE '^(ok [0-9]+ - |# Subtest: )' | tail -40
fi

echo "$pass passed, $fail failed"
exit "$rc"
