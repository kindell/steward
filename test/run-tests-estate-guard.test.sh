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
# (control) the not-run word stays bare: naming an estate there would claim a list that is absent
case "$out" in *"estate-guard=not-run("*) bad "2c not-run names no estate" "it did: $(printf '%s' "$out" | grep -o 'estate-guard=[^ ]*')" ;; *) ok "2c not-run names no estate" ;; esac
echo "== 3. designated with a guard: it runs against THIS tree =="
out="$(STEWARD_ESTATE_ROOT="$FX/estate" run)"
has "3a the guard ran"                          "$out" "estate leak-guard"
has "3b summary carries estate-guard=ok"       "$out" "estate-guard=ok"
# WHICH estate's list ran is part of the word. 'ok' alone reads as "no names found anywhere",
# and that is a claim no single run can make: each estate's guard sees only its OWN list, and the
# lists are disjoint by design (measured 2026-09-13: two people appear in the product and in no
# list on this host). A gate run on two estates leaves the third's people unguarded, so the
# summary names the estate whose list actually ran.
has "3b2 and names the estate whose list ran"  "$out" "estate-guard=ok(estate)"
out="$(STUB_RC=1 STEWARD_ESTATE_ROOT="$FX/estate" run)"
has "3c a red guard is RED in the summary"     "$out" "estate-guard=RED"
has "3c2 the red word names the estate too"    "$out" "estate-guard=RED(estate)"
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
# STRIP THE ISOLATION, NOT THE BOOKKEEPING. Deleting the _rt_iso/_rt_cfg lines too would leave
# the later ownership check referring to an unset variable, and under set -u the runner dies
# before it can be wrong - a crashed runner is not the control we want. Removing only the export
# leaves the poisoned path in STEWARD_CONFIG_FILE, which is exactly the world this guards against.
sed -i.bak '/^export STEWARD_CONFIG_FILE=/d' "$FX/tree/tools/run-tests.sh"
out="$(cd "$FX/tree" && STEWARD_CONFIG_FILE="$FX/poison" bash tools/run-tests.sh . probe 2>&1)"
has "4b (control) without the isolation the probe is RED" "$out" "RED    probe"

echo "== 5. a suite that writes the isolated config does not hand it to the next one =="
# The isolated path is writable (a 0700 mktemp dir), so one suite can create the very file the
# isolation exists to prevent - and every suite after it would read an operator config the host
# never had. The runner removes it before each suite and says so. Probe A writes it; probe B is
# red if it can see it.
mkdir -p "$FX/tree5/test" "$FX/tree5/tools"; cp "$here/tools/run-tests.sh" "$FX/tree5/tools/"
cat > "$FX/tree5/test/probe-a-writer.test.sh" <<'PROBE'
#!/bin/bash
printf 'FORMAT=1\nBOGUS=1\n' > "$STEWARD_CONFIG_FILE"
echo "pass=1 fail=0"
PROBE
cat > "$FX/tree5/test/probe-b-reader.test.sh" <<'PROBE'
#!/bin/bash
if [ -e "${STEWARD_CONFIG_FILE:-/nonexistent}" ]; then echo "FAIL: inherited a config from an earlier suite"; echo "pass=0 fail=1"; exit 1; fi
echo "pass=1 fail=0"
PROBE
chmod +x "$FX/tree5/test/probe-a-writer.test.sh" "$FX/tree5/test/probe-b-reader.test.sh"
out="$( cd "$FX/tree5" && unset STEWARD_ESTATE_ROOT; bash tools/run-tests.sh . probe 2>&1 )"
has "5a the writer runs"                          "$out" "ok     probe-a-writer"
has "5b the next suite does not inherit the file" "$out" "ok     probe-b-reader"
has "5c and the runner says it removed it"        "$out" "a previous suite wrote"

printf '\n  %d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
