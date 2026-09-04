#!/bin/bash
# tools/run-tests.sh — run the WHOLE suite and say what happened.
#
# WHY IT EXISTS. An environment-variable prefix was renamed in the tests but not
# in the scripts that read them. Two suites went from green to red — 343/0 to
# 330/13, and 12/0 to 10/2 — on the main branch. It went unnoticed for a whole
# working session, because whoever merged ran seven hand-picked suites and called
# them the golden master. The suite has thirty-two. A subset chosen by hand by
# the person who just changed the code measures what they already believe.
#
# The regression was eventually found by an outside review, not by us. This
# script exists so that route is not the only one.
#
# THREE THINGS IT DOES THAT A FOR-LOOP DOES NOT:
#
# 1. Reads BOTH output formats. The suites speak two, a legacy one and a
#    current one. A sweep that understands only one silently reports zero for
#    half the fleet.
# 2. Fails on SILENT SYNTAX ERRORS. Two expressions once blew up under bash 3.2
#    and wrote "syntax error near unexpected token" to stderr WITHOUT counting
#    as a test failure: the measurement never ran, the suite said nothing, and
#    the exit code was 0. A test that could not run is not a test that passed.
#    Stderr noise of that class is therefore an error here.
# 3. Counts suites, not just outcomes. The number of suites run is printed and
#    compared against the number found — a sweep that skips half must not be
#    able to look like a clean sweep.
#
# NOTE: at least one suite may reach out to live sessions when run on a host
# that has them. Until that is fixed, a full run on such a machine is not free
# of side effects.
#
# Exit code: 0 = all green · 1 = at least one suite red or carrying a silent
# syntax error

set -u

# THE UMASK IS PART OF THE FIXTURE, so the runner fixes it. A suite that builds
# a directory tree inherits the operator's umask, and the guards under test then
# judge a fixture the test never described: on Ubuntu (umask 002) a fixture
# directory is created 0775, several guards correctly refuse a group-writable
# trust root, and the suite reports a product fault that exists nowhere outside
# the fixture. Measured 2026-09-04, the first time these suites ran on Linux:
# 19 of 59 red, all of them this. macOS (umask 022) never showed it.
#
# 0077 is the strict end, so a suite that WANTS a lax mode still sets it
# explicitly with chmod -- and then the mode is written down in the test, which
# is where a mode a guard will judge belongs.
umask 077

# The repo under test is the CURRENT DIRECTORY by default, not this script's own
# tree. The runner lives in the product but is used by any checkout that has a
# test/ directory — an estate runs its own suites through this exact file.
# Passing a path overrides it.
#
# A runner that could only test its own tree would have to be copied into every
# repo, and a copied file is precisely what the double-life guard forbids: the
# same path in two trees, drifting apart silently.
HERE="${1:-$PWD}"
HERE="$(CDPATH= cd -- "$HERE" && pwd)" || exit 70
[ -d "$HERE/test" ] || { echo "REFUSED: no test/ directory in $HERE" >&2; exit 78; }
cd "$HERE" || exit 70

TIMEOUT_S="${RUN_TESTS_TIMEOUT:-200}"
ONLY="${2:-}"           # optional: run only suites whose name matches

red=0
silent=0
ran=0
found=0

run_with_timeout() {
  # `timeout` is not present everywhere; fall back to a plain run rather than
  # skipping the suite. Being unable to set a time limit is a worse day, but
  # silently omitting a suite is a silent failure.
  if command -v timeout >/dev/null 2>&1; then timeout "$TIMEOUT_S" "$@"
  else "$@"; fi
}

counts() {
  # Either format -> "N/M" (passed/failed), or empty if neither was found.
  local out="$1" p f g
  p="$(printf '%s' "$out" | grep -oE 'pass=[0-9]+ fail=[0-9]+' | tail -1)"
  if [ -n "$p" ]; then
    printf '%s' "$p" | sed -E 's/pass=([0-9]+) fail=([0-9]+)/\1\/\2/'
    return
  fi
  f="$(printf '%s' "$out" | grep -oE '[0-9]+ klarade, [0-9]+ föll' | tail -1)"
  if [ -n "$f" ]; then
    printf '%s' "$f" | sed -E 's/([0-9]+) klarade, ([0-9]+) föll/\1\/\2/'
    return
  fi
  # A THIRD PHRASING EXISTS, and it was invisible until Linux. test/liveness-host
  # ends with "36 passed, 3 failed"; the parser knew two forms, reported ?/? for
  # this one and counted it red -- correct as a refusal, useless as a
  # measurement, since a suite that RAN and failed three assertions looked
  # exactly like a suite that could not run at all.
  g="$(printf '%s' "$out" | grep -oE '[0-9]+ passed, [0-9]+ failed' | tail -1)"
  [ -n "$g" ] && printf '%s' "$g" | sed -E 's/([0-9]+) passed, ([0-9]+) failed/\1\/\2/'
}

echo "== shell suites =="
for t in test/*.test.sh; do
  [ -e "$t" ] || continue
  name="$(basename "$t" .test.sh)"
  found=$((found+1))
  case "$name" in *"$ONLY"*) ;; *) continue ;; esac
  ran=$((ran+1))

  errfile="$(mktemp)"
  out="$(run_with_timeout bash "$t" 2>"$errfile")"
  rc=$?
  n="$(counts "$out")"
  [ -n "$n" ] || n="?/?"

  # Silent syntax errors: written to stderr without counting as test failures.
  # NO `|| echo 0` here: `grep -c` already PRINTS "0" and returns 1 when it
  # finds nothing, so the fallback appended a second "0" and made the value
  # "0\n0" — which then failed the next test with "integer expression
  # expected". The error handling destroyed the value it was meant to protect.
  n_syntax="$(grep -ciE 'syntax error|unexpected token' "$errfile" 2>/dev/null)"
  [ -n "$n_syntax" ] || n_syntax=0
  rm -f "$errfile"

  if [ "$rc" -ne 0 ]; then
    printf '  RED    %-34s %s\n' "$name" "$n"
    red=$((red+1))
  elif [ "$n_syntax" -gt 0 ]; then
    printf '  SILENT %-34s %s — %s syntax error(s) on stderr WITHOUT a test failure: the measurement did not run\n' \
      "$name" "$n" "$n_syntax"
    silent=$((silent+1))
  else
    printf '  ok     %-34s %s\n' "$name" "$n"
  fi
done

echo
echo "== node suites =="
for d in fleet watchdog; do
  [ -d "$d" ] || continue
  if run_with_timeout bash -c "cd '$d' && node --test" >/dev/null 2>&1; then
    printf '  ok     %-34s\n' "$d"
  else
    printf '  RED    %-34s (node --test)\n' "$d"
    red=$((red+1))
  fi
done

echo
echo "== rust suites =="
# CARGO IS NOT ON PATH. rustup keeps it in ~/.cargo/bin, and this machine
# does not have that on its path — a bare `cargo` would have given "command
# not found" and a silent green line, exactly the absence of measurement
# this file exists against.
CARGO="${CARGO:-$HOME/.cargo/bin/cargo}"
for d in cockpit; do
  [ -d "$d" ] || continue
  found=$((found+1))
  case "$d" in *"$ONLY"*) ;; *) continue ;; esac
  ran=$((ran+1))
  if [ ! -x "$CARGO" ]; then
    # A MISSING TOOL IS NOT A GREEN TEST. It is a measurement that could not
    # be made, and it must show as red — not skipped over with a reassuring
    # line.
    printf '  RED    %-34s (cargo missing: %s)\n' "$d" "$CARGO"
    red=$((red+1)); continue
  fi
  if run_with_timeout bash -c "cd '$d' && '$CARGO' test --quiet" >/dev/null 2>&1; then
    printf '  ok     %-34s\n' "$d"
  else
    printf '  RED    %-34s (cargo test)\n' "$d"
    red=$((red+1))
  fi
done

echo
echo "suites found=$found ran=$ran red=$red silent=$silent"
[ -n "$ONLY" ] && echo "NOTE: filter '$ONLY' is active — this is NOT a full run."
if [ "$ran" -ne "$found" ] && [ -z "$ONLY" ]; then
  echo "REFUSED: $ran of $found suites ran with no filter — the sweep skipped something." >&2
  exit 1
fi
[ "$red" -eq 0 ] && [ "$silent" -eq 0 ]
