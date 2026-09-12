#!/bin/bash
# test/run-tests-estate-guard.test.sh - the product's gate runs the ESTATE's leak guard when an
# estate is designated, against THIS tree, and says out loud when it did not run.
#
# The guard that keeps the product domain-agnostic lives where the name list lives - the estate.
# A product PR ran only the product's suites, so names merged twice in one afternoon (2026-09-12)
# with nothing red anywhere. Now the runner calls $STEWARD_ESTATE_ROOT/test/leak-guard.test.sh
# with STEWARD_PRODUCT_REPO pointed at the tree being gated. Not designated, or no test dir (a
# deployed home): a NOT RUN line and estate-guard=not-run in the summary - never silence.
set -u
here="$(CDPATH= cd -- "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
pass=0; fail=0
ok()  { pass=$((pass+1)); printf '  ok   %s\n' "$1"; }
bad() { fail=$((fail+1)); printf '  FAIL %s\n     %s\n' "$1" "${2:-}"; }
has() { case "$2" in *"$3"*) ok "$1" ;; *) bad "$1" "missing '$3' in: $(printf '%s' "$2" | tr '\n' ' ' | cut -c1-160)" ;; esac; }
FX="$(mktemp -d)"; trap 'rm -rf "$FX"' EXIT
mkdir -p "$FX/estate/test"
printf '#!/bin/bash\necho "== produktytan =="\necho "repo=${STEWARD_PRODUCT_REPO:-unset}"\necho "pass=1 fail=0"\nexit ${STUB_RC:-0}\n' > "$FX/estate/test/leak-guard.test.sh"; chmod +x "$FX/estate/test/leak-guard.test.sh"
run() { ( cd "$here" && bash tools/run-tests.sh . zzzz-no-suite-matches 2>&1 ); }

echo "== 1. not designated: said, not silent =="
out="$( (unset STEWARD_ESTATE_ROOT; run) )"
has "1a NOT RUN line names the reason"        "$out" "NOT RUN estate leak-guard: no estate designated"
has "1b summary carries estate-guard=not-run"  "$out" "estate-guard=not-run"
echo "== 2. designated but no test dir (a deployed home): said, with the path =="
out="$(STEWARD_ESTATE_ROOT="$FX/nothing" run)"
has "2a NOT RUN line names the missing dir"    "$out" "no estate test dir at $FX/nothing/test"
has "2b summary carries estate-guard=not-run"  "$out" "estate-guard=not-run"
echo "== 3. designated with a guard: it runs against THIS tree =="
out="$(STEWARD_ESTATE_ROOT="$FX/estate" run)"
has "3a the guard ran"                          "$out" "estate leak-guard"
has "3b summary carries estate-guard=ok"       "$out" "estate-guard=ok"
out="$(STUB_RC=1 STEWARD_ESTATE_ROOT="$FX/estate" run)"
has "3c a red guard is RED in the summary"     "$out" "estate-guard=RED"
has "3d and counted among the red suites"      "$out" "red=1"
# STEWARD_PRODUCT_REPO must be the gated tree, not a sibling: the stub echoes what it got.
printf '#!/bin/bash\necho "FAIL: repo=${STEWARD_PRODUCT_REPO:-unset}"\necho "pass=1 fail=1"\nexit 1\n' > "$FX/estate/test/leak-guard.test.sh"
out="$(STEWARD_ESTATE_ROOT="$FX/estate" run)"
has "3e the guard is pointed at the tree under test, and its FAIL lines surface" "$out" "FAIL: repo=$here"

echo "== 4. the host's operator config cannot reach a suite =="
# A poisoned host config (an unknown key) turns every steward call into rc 78. Behind the runner it
# must not: the runner points STEWARD_CONFIG_FILE at a path that does not exist. The probe suite is
# red when it can see any existing config file (or none at all), green when the path points at nothing.
mkdir -p "$FX/tree/test" "$FX/tree/tools"; cp "$here/tools/run-tests.sh" "$FX/tree/tools/"
printf 'FORMAT=1\nBOGUS_KEY=1\n' > "$FX/poison"
cat > "$FX/tree/test/probe.test.sh" <<'PROBE'
#!/bin/bash
if [ -z "${STEWARD_CONFIG_FILE:-}" ]; then echo "FAIL: unset - the host default would be read"; echo "pass=0 fail=1"; exit 1; fi
if [ -e "$STEWARD_CONFIG_FILE" ]; then echo "FAIL: saw an existing config: $STEWARD_CONFIG_FILE"; echo "pass=0 fail=1"; exit 1; fi
echo "pass=1 fail=0"
PROBE
chmod +x "$FX/tree/test/probe.test.sh"
out="$(cd "$FX/tree" && STEWARD_CONFIG_FILE="$FX/poison" bash tools/run-tests.sh . probe 2>&1)"
has "4a a poisoned host config in the environment never reaches a suite" "$out" "ok     probe"
# the probe bites: strip the isolation lines from the copy and the poison walks straight in
sed -i.bak '/^_rt_iso=/d; /^export STEWARD_CONFIG_FILE=/d' "$FX/tree/tools/run-tests.sh"
out="$(cd "$FX/tree" && STEWARD_CONFIG_FILE="$FX/poison" bash tools/run-tests.sh . probe 2>&1)"
has "4b (control) without the isolation the probe is RED" "$out" "RED    probe"

printf '\n  %d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
