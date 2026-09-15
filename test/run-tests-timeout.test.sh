#!/bin/bash
# test/run-tests-timeout.test.sh - a suite the runner KILLS says so, and says the
# limit. It used to report `?/?`, the same string a suite gets when its output
# cannot be parsed at all - so a reader of a timed-out suite went looking for a
# syntax error. Measured 2026-09-15: a suite that normally takes 328s was killed
# at 200 and reported `?/?`; two readers in two estates began by hunting for a
# broken edit. The outcome was true (it did not finish) and pointed the wrong
# way (the cause was the clock, not the code).
#
# THE SECOND HALF IS THE ONE THAT CARRIES THE CLAIM: on a host with no
# `timeout`, rc 124 can ONLY be the suite's own exit code, and calling it a
# timeout would be a claim about a mechanism that was not there.
set -u
here="$(CDPATH= cd -- "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
pass=0; fail=0
ok()  { pass=$((pass+1)); printf '  ok   %s\n' "$1"; }
bad() { fail=$((fail+1)); printf '  FAIL %s\n     %s\n' "$1" "${2:-}"; }
has() { case "$2" in *"$3"*) ok "$1";; *) bad "$1" "missing '$3' in: $(printf '%s' "$2" | head -c 300)";; esac; }
no()  { case "$2" in *"$3"*) bad "$1" "found '$3'";; *) ok "$1";; esac; }

command -v timeout >/dev/null 2>&1 || { echo "  SKIP no timeout(1) on this host"; echo; printf '  %d passed, %d failed\n' 0 0; exit 0; }

FX="$(mktemp -d)"; trap 'rm -rf "$FX"' EXIT
mkdir -p "$FX/tree/test" "$FX/tree/tools"; cp "$here/tools/run-tests.sh" "$FX/tree/tools/"
printf '#!/bin/bash\nsleep 30\necho "pass=1 fail=0"\n' > "$FX/tree/test/slow.test.sh"
printf '#!/bin/bash\necho "pass=2 fail=0"\n'          > "$FX/tree/test/quick.test.sh"
# A suite that CHOOSES 124 as its own exit code, printing no counts.
printf '#!/bin/bash\nexit 124\n'                      > "$FX/tree/test/own124.test.sh"
chmod +x "$FX/tree/test"/*.test.sh

only() { ( cd "$FX/tree" && unset STEWARD_ESTATE_ROOT; RUN_TESTS_TIMEOUT=2 RUN_TESTS_RED_DIR="$FX/red" bash tools/run-tests.sh . "$1" 2>&1 ); }

echo "== 1. a killed suite names the mechanism and the limit =="
out="$(only slow)"
has "1a the verdict says TIMEOUT, not ?/?"        "$out" "TIMEOUT after 2s"
no  "1b ...and not the unparsable marker"          "$out" "?/?"
has "1c the line says it did not FINISH"           "$out" "it did not fail, it did not finish"
has "1d ...and names the variable that sets it"    "$out" "RUN_TESTS_TIMEOUT"
has "1e it is still counted red"                   "$out" "red=1"

echo "== 2. a suite that finishes is untouched =="
out="$(only quick)"
has "2a a fast suite is ok"                        "$out" "ok     quick"
no  "2b ...and says nothing about timeouts"        "$out" "TIMEOUT"

echo "== 3. WITHOUT timeout(1), rc 124 is NOT called a timeout =="
# The runner falls back to a plain run when `timeout` is absent. Then 124 is the
# suite's own exit code and nothing was killed: claiming otherwise would name a
# mechanism that never ran. A PATH without timeout is the only honest fixture.
mkdir -p "$FX/bin"
for c in bash sed awk grep cat mktemp rm mkdir printf head cut tr sort wc dirname basename find node git; do
  p="$(command -v "$c" 2>/dev/null)" && ln -sf "$p" "$FX/bin/$c"
done
out="$( cd "$FX/tree" && unset STEWARD_ESTATE_ROOT; PATH="$FX/bin" RUN_TESTS_TIMEOUT=2 RUN_TESTS_RED_DIR="$FX/red" bash tools/run-tests.sh . own124 2>&1 )"
no  "3a no timeout(1): rc 124 is not called a TIMEOUT" "$out" "TIMEOUT after"
has "3b ...it is reported as the suite's own exit"     "$out" "the suite exited 124"

printf '\n  %d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
