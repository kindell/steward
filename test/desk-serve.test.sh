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

# THE FAILURE'S OWN WORDS COME FIRST, AND THE TAIL SECOND. node writes a test's
# diagnostic block DIRECTLY AFTER that test's `not ok` line - never at the end - so
# a window taken from the end of the stream carries the summary and not the failure.
# Measured 2026-09-18: `not ok 198` stood on line 199 of 272, the old `tail -40` kept
# 233-272, and the block sat 34 lines outside it. The one string in the whole run that
# came from the process that failed - the assertion message, which for this suite
# appends the server's stderr - was discarded by this filter FOUR TIMES, each time
# before RED_DIR archived what the wrapper had already thrown away. Two estates then
# spent a day varying the input to a measurement whose output could not be read.
#
# The bound stays, because an unbounded dump of a broken run is its own kind of
# silence: at most FAIL_CAP failing blocks, then a line saying how many were left out.
FAIL_CAP=10
desk_serve_failure_report() {   # TAP on stdin -> each failure with its diagnostics, then a tail
  # awk and not bash: the block below walks state over lines, which `while read` in
  # bash 3.2 does more slowly and no more clearly. No mapfile, no arrays of the kind
  # test/deploy-policy.test.sh forbids.
  awk -v cap="${FAIL_CAP:-10}" -v tailn=40 '
    # A PASSING TEST CARRIES A BLOCK TOO, and dropping it is half the repair. The old
    # filter removed a passing `ok` line and left its four-line YAML behind, so 252
    # green tests contributed roughly a thousand lines for the window to land in. The
    # failure was not buried by the failure; it was buried by the successes.
    /^[[:space:]]*not ok [0-9]+ - / {
      nf++
      if (nf <= cap) { keep = 1; print } else { keep = 0 }
      skip = 0
      next
    }
    /^[[:space:]]*ok [0-9]+ - /     { keep = 0; skip = 1; next }
    /^[[:space:]]*---[[:space:]]*$/ {
      if (keep)      { inblk  = 1; print }
      else if (skip) { inskip = 1 }
      next
    }
    inblk {
      print
      if ($0 ~ /^[[:space:]]*\.\.\.[[:space:]]*$/) { inblk = 0; keep = 0 }
      next
    }
    inskip {
      if ($0 ~ /^[[:space:]]*\.\.\.[[:space:]]*$/) { inskip = 0; skip = 0 }
      next
    }
    /^[[:space:]]*# Subtest: / { next }
    { rest[++nr] = $0 }
    END {
      if (nf > cap) printf("  ... and %d more failing tests, not shown\n", nf - cap)
      start = nr - tailn + 1
      if (start < 1) start = 1
      for (i = start; i <= nr; i++) print rest[i]
    }
  '
}

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
  printf '%s\n' "$out" | desk_serve_failure_report
fi

echo "$pass passed, $fail failed"
exit "$rc"
