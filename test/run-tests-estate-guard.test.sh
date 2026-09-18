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
# THE OPERATOR CONFIG IS ISOLATED FOR EVERY CASE THAT DOES NOT SUPPLY ONE. Since the
# estate root can be DERIVED from it, a case meaning "no estate designated" would
# otherwise depend on whether the host running the suite happens to name one - green
# here, red on a colleague's machine, and neither would be about the code.
run() { ( cd "$here" && RUN_TESTS_RED_DIR="$FX/red" STEWARD_CONFIG_FILE="$FX/no-such-operator-config" bash tools/run-tests.sh . zzzz-no-suite-matches 2>&1 ); }

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
# THE SUMMARY LINE MUST NOT NAME THE ESTATE, and the suite line must. The summary
# is what gets pasted into a public pull request as proof; the name in it was
# published four times before anyone noticed (2026-09-15). The suite line above is
# where a person debugging a red guard reads, and nobody pastes that.
case "$out" in *"estate-guard=ok(designated,"*) ok "3b1 the summary says the ROLE" ;; *) bad "3b1 the summary says the ROLE" "no estate-guard=ok(designated, in: $(printf '%s' "$out" | tr '\n' ' ' | cut -c1-200)" ;; esac
case "$out" in *"estate-guard=ok($(basename "$FX/estate")"*) bad "3b2 the summary does NOT name the estate" "the estate's directory name is on the summary line" ;; *) ok "3b2 the summary does NOT name the estate" ;; esac
case "$out" in *"estate leak-guard ($(basename "$FX/estate"))"*) ok "3b3 the suite line still names it, for the person debugging" ;; *) bad "3b3 the suite line still names it" "$(printf '%s' "$out" | tr '\n' ' ' | cut -c1-200)" ;; esac
# THE WORD MUST SAY MORE THAN 'ok', AND LESS THAN THE NAME. The claim this was
# written against still stands: a bare 'ok' reads as "no names found anywhere", which
# no single run can make - each estate's guard sees only its OWN list, the lists are
# disjoint by design (measured 2026-09-13: two people appear in the product and in no
# list on this host), and a run against one estate leaves the others' people unguarded.
# The first form met that by naming the estate. 'designated' meets it too: it says the
# run used the estate it was POINTED AT, which is the only one it could have used, and
# it is the DESIGNATION that scopes the claim - not which estate happened to be there.
#
# What the name cost: the summary line is what people paste into a public pull request
# as proof, so the tool proving this surface carries no host names was writing one into
# the proof, and the habit published it (measured 2026-09-15). The name stays one line
# up, where somebody debugging a red guard reads and nobody pastes.
has "3b2 and says the run used the DESIGNATED estate" "$out" "estate-guard=ok(designated,"
out="$(STUB_RC=1 STEWARD_ESTATE_ROOT="$FX/estate" run)"
has "3c a red guard is RED in the summary"     "$out" "estate-guard=RED"
has "3c2 the red word is scoped the same way"  "$out" "estate-guard=RED(designated,"
# A RED ESTATE GUARD KEEPS ITS OUTPUT. It is the one red the other platform cannot
# reproduce - the name list lives in the estate, so a steward without one gets
# not-run and can only ask. Measured 2026-09-15: a colleague asked for the line off
# a red on their own branch and there was no file to send.
case "$out" in *"full output: "*"estate-leak-guard.out"*) ok "3c3 a red guard names a saved file" ;; *) bad "3c3 a red guard names a saved file" "$(printf '%s' "$out" | tr '\n' ' ' | cut -c1-200)" ;; esac
_egf="$(printf '%s' "$out" | sed -n 's/.*full output: \(.*estate-leak-guard.out\).*/\1/p' | head -1)"
if [ -n "$_egf" ] && [ -s "$_egf" ]; then ok "3c4 the file exists and is not empty"; else bad "3c4 the file exists and is not empty" "path='$_egf'"; fi
case "$(cat "$_egf" 2>/dev/null)" in *"produktytan"*|*"pass="*|*"FAIL"*) ok "3c5 it holds the guard's own output, not a summary" ;; *) bad "3c5 it holds the guard's own output" "$(head -c 120 "$_egf" 2>/dev/null)" ;; esac
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
out="$(cd "$FX/tree" && RUN_TESTS_RED_DIR="$FX/red" STEWARD_CONFIG_FILE="$FX/poison" bash tools/run-tests.sh . probe 2>&1)"
has "4a a poisoned host config in the environment never reaches a suite" "$out" "ok     probe"
# the probe bites: strip the isolation lines from the copy and the poison walks straight in
# STRIP THE ISOLATION, NOT THE BOOKKEEPING. Deleting the _rt_iso/_rt_cfg lines too would leave
# the later ownership check referring to an unset variable, and under set -u the runner dies
# before it can be wrong - a crashed runner is not the control we want. Removing only the export
# leaves the poisoned path in STEWARD_CONFIG_FILE, which is exactly the world this guards against.
sed -i.bak '/^export STEWARD_CONFIG_FILE=/d' "$FX/tree/tools/run-tests.sh"
out="$(cd "$FX/tree" && RUN_TESTS_RED_DIR="$FX/red" STEWARD_CONFIG_FILE="$FX/poison" bash tools/run-tests.sh . probe 2>&1)"
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
out="$( cd "$FX/tree5" && unset STEWARD_ESTATE_ROOT; RUN_TESTS_RED_DIR="$FX/red" bash tools/run-tests.sh . probe 2>&1 )"
has "5a the writer runs"                          "$out" "ok     probe-a-writer"
has "5b the next suite does not inherit the file" "$out" "ok     probe-b-reader"
has "5c and the runner says it removed it"        "$out" "a previous suite wrote"

echo "== 6. an unset root is derived from the operator config, and the line says so =="
# A GUARD THAT MUST BE REMEMBERED IS A GUARD THAT WILL BE FORGOTTEN. Measured on the
# other estate 2026-09-15/16: every gate run there said not-run for a night, because the
# root was only ever set in the operator config and the gate environment does not read
# it. Two receipts reported on a surface they could not see.
# A PASSING STUB AGAIN: section 3e replaced it with one that exits 1 to prove a red
# guard is reported. This section is about WHERE THE ROOT CAME FROM, not about red.
printf '#!/bin/bash\necho "pass=1 fail=0"\n' > "$FX/estate/test/leak-guard.test.sh"; chmod +x "$FX/estate/test/leak-guard.test.sh"
printf 'FORMAT=1\nSTEWARD_ESTATE_ROOT=%s\n' "$FX/estate" > "$FX/operator-config"
out="$( cd "$here" && env -u STEWARD_ESTATE_ROOT STEWARD_CONFIG_FILE="$FX/operator-config" bash tools/run-tests.sh . zzzz-no-suite 2>&1 )"
has "6a the guard runs on a root that only the config named" "$out" "estate leak-guard"
has "6b and the summary says where the root came from"       "$out" "estate-guard=ok(designated:config,"
# UNSET IS NOT EMPTY. `STEWARD_ESTATE_ROOT=` means "no estate, deliberately"; deriving
# over it would make editing the operator config the only way to run without the guard -
# a durable change for a temporary need.
out="$( cd "$here" && STEWARD_ESTATE_ROOT= STEWARD_CONFIG_FILE="$FX/operator-config" bash tools/run-tests.sh . zzzz-no-suite 2>&1 )"
has "6c an empty-but-set root is left alone"                 "$out" "estate-guard=not-run"
has "6d and the reason names both places looked"             "$out" "unset in env and operator config"
# THE TWO FAILURES MUST NOT READ ALIKE: "you pointed at a tree without a guard" and "we
# found a root in your config and it has no guard" send a reader to different places.
printf 'FORMAT=1\nSTEWARD_ESTATE_ROOT=%s\n' "$FX/nothing" > "$FX/operator-config-bad"
out="$( cd "$here" && env -u STEWARD_ESTATE_ROOT STEWARD_CONFIG_FILE="$FX/operator-config-bad" bash tools/run-tests.sh . zzzz-no-suite 2>&1 )"
has "6e a derived root without a guard says it was derived"  "$out" "root derived from operator config"
# AND THE NAME COMES FROM THE ESTATE, NOT THE DIRECTORY. A derived root is ~/scripts in
# every home on every host; basename of it is "scripts", which is not an estate.
mkdir -p "$FX/estate/estate"; printf 'ESTATE_NAME="fixture-estate"\n' > "$FX/estate/estate/steward.conf"
out="$( cd "$here" && STEWARD_ESTATE_ROOT="$FX/estate" bash tools/run-tests.sh . zzzz-no-suite 2>&1 )"
has "6f the suite line names the estate, not the directory"  "$out" "estate leak-guard (fixture-estate)"

echo "== 7. the list digest is carried, and its absence is printed =="
# A PAIR PROPERTY. Two receipts that both say ok(designated) are consistent with two
# estates AND with one estate measured twice; a digest of the list each guard ran
# settles it. Measured 2026-09-16: five open PRs carried "green on both halves" while
# one half had never run a name list at all, and the receipts did not say so.
mkdir -p "$FX/dg/test" "$FX/dg/estate"
printf 'ESTATE_NAME="digest-fixture"\n' > "$FX/dg/estate/steward.conf"
printf '#!/bin/bash\necho "LIST-DIGEST=1233ed66"\necho "pass=1 fail=0"\n' > "$FX/dg/test/leak-guard.test.sh"
chmod +x "$FX/dg/test/leak-guard.test.sh"
out="$( cd "$here" && STEWARD_ESTATE_ROOT="$FX/dg" bash tools/run-tests.sh . zzzz-no-suite 2>&1 )"
has "7a a digest the guard printed is carried verbatim" "$out" "list=1233ed66"
# AND A GUARD THAT PRINTS NONE SAYS SO. A missing field reads as a field that was not
# needed - the same equivalence between absence and emptiness this runner has paid for
# twice. A digest and a blank prove exactly as little as two blanks.
printf '#!/bin/bash\necho "pass=1 fail=0"\n' > "$FX/dg/test/leak-guard.test.sh"
out="$( cd "$here" && STEWARD_ESTATE_ROOT="$FX/dg" bash tools/run-tests.sh . zzzz-no-suite 2>&1 )"
has "7b a guard without one prints the absence"        "$out" "list=absent"
case "$out" in *"list=absent"*) ok "7c the field is never simply omitted" ;; *) bad "7c the field is never simply omitted" "no list= field at all" ;; esac
# THE GUARD OWNS THE DEFINITION: a malformed line is not half-read into a digest.
printf '#!/bin/bash\necho "LIST-DIGEST="\necho "pass=1 fail=0"\n' > "$FX/dg/test/leak-guard.test.sh"
out="$( cd "$here" && STEWARD_ESTATE_ROOT="$FX/dg" bash tools/run-tests.sh . zzzz-no-suite 2>&1 )"
has "7d an empty digest line reads as absent, not as empty" "$out" "list=absent"

echo "== 8. which TREE the guard ran in, without saying where it is =="
# THE SECOND HALF OF THE PAIR PROPERTY. Since the estate names itself out of its own
# conf (section 6f), a checkout and a deployed copy of the same estate print the SAME
# word - two different trees, one name. The list digest separates them only when the
# lists differ. A digest of the resolved root says which tree, and says nothing about
# where it lives: the path cannot go on this line, because this line is what gets
# pasted into a public pull request and that is why the name came off it (2026-09-15).
mkdir -p "$FX/t8a/test" "$FX/t8b/test"
printf '#!/bin/bash\necho "pass=1 fail=0"\n' | tee "$FX/t8a/test/leak-guard.test.sh" > "$FX/t8b/test/leak-guard.test.sh"
chmod +x "$FX/t8a/test/leak-guard.test.sh" "$FX/t8b/test/leak-guard.test.sh"
_root_of() { printf '%s' "$1" | sed -n 's/.*estate-guard=[a-zA-Z]*(\([^)]*\)).*/\1/p' | sed -n 's/.*root=\([0-9a-z]*\).*/\1/p' | head -1; }
out="$( cd "$here" && STEWARD_ESTATE_ROOT="$FX/t8a" bash tools/run-tests.sh . zzzz-no-suite 2>&1 )"; r_a="$(_root_of "$out")"
case "$r_a" in [0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f]) ok "8a the line carries a root digest, eight hex" ;; *) bad "8a the line carries a root digest" "got root='$r_a' from: $(printf '%s' "$out" | grep -o 'estate-guard=[^ ]*')" ;; esac
out="$( cd "$here" && STEWARD_ESTATE_ROOT="$FX/t8b" bash tools/run-tests.sh . zzzz-no-suite 2>&1 )"; r_b="$(_root_of "$out")"
if [ -n "$r_a" ] && [ "$r_a" != "$r_b" ]; then ok "8b two trees give two digests - the receipts cannot look alike"; else bad "8b two trees give two digests" "both said '$r_a'"; fi
# THE SAME TREE, REACHED TWO WAYS, IS THE SAME TREE. The source word (env vs config)
# says how the runner found the root; the digest says what it found. They are different
# questions and a run must not blur them.
printf 'FORMAT=1\nSTEWARD_ESTATE_ROOT=%s\n' "$FX/t8a" > "$FX/operator-config-8"
out="$( cd "$here" && env -u STEWARD_ESTATE_ROOT STEWARD_CONFIG_FILE="$FX/operator-config-8" bash tools/run-tests.sh . zzzz-no-suite 2>&1 )"; r_cfg="$(_root_of "$out")"
if [ "$r_cfg" = "$r_a" ]; then ok "8c env and config naming one tree give one digest"; else bad "8c env and config naming one tree give one digest" "env='$r_a' config='$r_cfg'"; fi
has "8c2 and the source word still separates them" "$out" "designated:config, root=$r_cfg"
# PHYSICAL, NOT SPELLED. A symlinked checkout and its target are one tree; a digest of
# the literal string would call them two and invent a difference that is not there.
ln -s "$FX/t8a" "$FX/t8a-link"
out="$( cd "$here" && STEWARD_ESTATE_ROOT="$FX/t8a-link" bash tools/run-tests.sh . zzzz-no-suite 2>&1 )"; r_link="$(_root_of "$out")"
if [ "$r_link" = "$r_a" ]; then ok "8d a symlink to the tree is the same tree"; else bad "8d a symlink to the tree is the same tree" "direct='$r_a' via symlink='$r_link'"; fi
# (control) THE PATH ITSELF STAYS OFF THE LINE. This is the whole reason it is a digest.
_sum="$(printf '%s\n' "$out" | grep '^suites found=')"
case "$_sum" in *"$FX"*) bad "8e the summary line carries no path" "the fixture path is on it: $_sum" ;; *) ok "8e the summary line carries no path" ;; esac

echo "== 9. the lens has a version: guard=<commit> and how it stands to main (rule 29) =="
# WHY THIS SECTION EXISTS. root= and list= describe the guard's SUBJECT. Two receipts
# from one host, hours apart, carried identical values for both - one RED and one ok -
# and the whole difference was one character in the guard's own source on a branch that
# had not landed. A receipt that names the instrument but not the instrument's COMMIT
# records a number nobody can re-take, including its author tomorrow.
#
# THE ESTATE IS A REAL GIT REPO IN THIS FIXTURE, not a stub, because every claim below
# is about what git answers: which commit last touched one file, whether the working
# tree is dirty for that file, and whether a commit is reachable from a remote's main.
# A stubbed git would prove the fixture.
_guard_of() { printf '%s\n' "$1" | grep '^suites found=' | sed -n 's/.*guard=\([^)]*\)).*/\1/p'; }

mk_estate_repo() {  # <dir> - an estate checkout with a guard and an origin
  mkdir -p "$1/test" "$1.origin"
  git init -q --bare "$1.origin"
  git init -q "$1"; git -C "$1" config user.email e@x; git -C "$1" config user.name E
  printf '#!/bin/bash\necho "pass=1 fail=0"\n' > "$1/test/leak-guard.test.sh"
  chmod +x "$1/test/leak-guard.test.sh"
  git -C "$1" add -A >/dev/null; git -C "$1" commit -qm "guard"
  git -C "$1" branch -M main; git -C "$1" remote add origin "$1.origin"
  git -C "$1" push -q origin main
}

# 9a ON MAIN: the commit is reachable from origin/main, so the bare sha stands alone.
mk_estate_repo "$FX/e9"
out="$( cd "$here" && STEWARD_ESTATE_ROOT="$FX/e9" bash tools/run-tests.sh . zzzz-no-suite 2>&1 )"
g="$(_guard_of "$out")"
case "$g" in
  [0-9a-f]*+*) bad "9a a landed guard carries a bare commit" "got '$g'" ;;
  [0-9a-f]*)   ok  "9a a landed guard carries a bare commit" ;;
  *)           bad "9a a landed guard carries a bare commit" "got '$g'" ;;
esac

# 9b ABOVE MAIN: a new commit to the guard that has not been pushed. This is the exact
# case from the rule - a number taken with an instrument nobody else has.
printf '# edited\n' >> "$FX/e9/test/leak-guard.test.sh"
git -C "$FX/e9" commit -qam "guard, edited"
out="$( cd "$here" && STEWARD_ESTATE_ROOT="$FX/e9" bash tools/run-tests.sh . zzzz-no-suite 2>&1 )"
case "$(_guard_of "$out")" in *+unlanded) ok "9b a guard above main says +unlanded" ;;
  *) bad "9b a guard above main says +unlanded" "got '$(_guard_of "$out")'" ;; esac

# 9c AN ANCESTOR OF MAIN IS LANDED. The direction that would be wrong if the check
# asked "is it EQUAL to main" - a guard not touched for three merges is still landed,
# and calling that unlanded would put the word on nearly every honest run until it
# stopped being read.
git -C "$FX/e9" push -q origin main
printf 'x\n' > "$FX/e9/other-file"; git -C "$FX/e9" add -A >/dev/null
git -C "$FX/e9" commit -qm "something else entirely"; git -C "$FX/e9" push -q origin main
out="$( cd "$here" && STEWARD_ESTATE_ROOT="$FX/e9" bash tools/run-tests.sh . zzzz-no-suite 2>&1 )"
case "$(_guard_of "$out")" in *+unlanded) bad "9c an ancestor of main is landed" "said +unlanded" ;;
  *) ok "9c an ancestor of main is landed" ;; esac

# 9d DIRTY IS COUNTED, NOT HIDDEN. A working-tree edit is the most unreproducible state
# of all - the commit exists and says nothing about what actually ran.
printf '# uncommitted\n' >> "$FX/e9/test/leak-guard.test.sh"
out="$( cd "$here" && STEWARD_ESTATE_ROOT="$FX/e9" bash tools/run-tests.sh . zzzz-no-suite 2>&1 )"
case "$(_guard_of "$out")" in *+dirty*) ok "9d an edited working tree says +dirty" ;;
  *) bad "9d an edited working tree says +dirty" "got '$(_guard_of "$out")'" ;; esac
git -C "$FX/e9" checkout -q -- test/leak-guard.test.sh

# 9e NOT A CHECKOUT AT ALL: a deployed home. '?' and never blank - a missing value that
# looks like an absent field is how a receipt claims more than it measured.
out="$( cd "$here" && STEWARD_ESTATE_ROOT="$FX/estate" bash tools/run-tests.sh . zzzz-no-suite 2>&1 )"
case "$(_guard_of "$out")" in ?) ok "9e a deployed home says guard=?" ;;
  *) bad "9e a deployed home says guard=?" "got '$(_guard_of "$out")'" ;; esac

# 9g THE COMPARISON LEAVES NO STATE IN THE ESTATE. The estate checkout is shared -
# this host runs two sessions out of one home against one estate root - so a fetch
# into FETCH_HEAD would be two runs writing one file and reading each other's answer.
# The ref is per-run and deleted; refs/tmp must be empty after a run, and a leftover
# would be this field breaking the very rule it reports.
out="$( cd "$here" && STEWARD_ESTATE_ROOT="$FX/e9" bash tools/run-tests.sh . zzzz-no-suite 2>&1 )"
_left="$(git -C "$FX/e9" for-each-ref 'refs/tmp/*' 2>/dev/null | grep -c . || true)"
[ "${_left:-1}" -eq 0 ] && ok "9g the landed-check leaves no ref behind" \
  || bad "9g the landed-check leaves no ref behind" "refs/tmp: $(git -C "$FX/e9" for-each-ref 'refs/tmp/*')"
# and it did not silently stop answering: the field is still filled in
case "$(_guard_of "$out")" in "") bad "9g2 and still answers" "empty guard field" ;; *) ok "9g2 and still answers" ;; esac

# 9h A GUARD, NOT A MEASUREMENT - and the difference is the point of the row.
#
# 9g proves the ref is DELETED. It does not prove the ref is UNIQUE PER RUN, and the
# two are different properties: a fixed name is also deleted afterwards, so 9g stays
# green on it. Measured 2026-09-18 by mutating the name from "guard-landed-$$" to
# "guard-landed-fast": the whole section stayed 47/0. A row that cannot fail on the
# axis it is named after is worth less than no row, because it is read as cover.
#
# WHY UNIQUENESS MATTERS: this host runs two sessions out of one home against one
# estate checkout, and both gate. With a fixed name, run B's delete can land between
# run A's fetch and A's merge-base, and A then reports +unlanded about a guard that is
# landed - the exact unreproducible number this whole field exists to prevent.
#
# WHY IT IS NOT MEASURED HERE: the honest measurement is two runners racing on one
# estate, and a race that passes by luck is a worse row than an admitted guard. So this
# READS the source for the pid in the name, and says so in its own label. A guard is a
# claim about a shape; a measurement is a claim about a behaviour. Writing one and
# calling it the other is how a suite comes to certify the wrong thing.
if grep -q 'refs/tmp/guard-landed-\$\$' "$here/tools/run-tests.sh"; then
  ok "9h (guard, read not measured) the landed-check ref carries the pid"
else
  bad "9h (guard, read not measured) the landed-check ref carries the pid" \
    "a fixed ref name races two runs sharing one estate checkout; 9g cannot see it"
fi

# 9f (control) THE FIELD NEVER CARRIES A PATH. Same reason root= is a digest: this line
# is pasted into public pull requests.
_sum="$(printf '%s\n' "$out" | grep '^suites found=')"
case "$_sum" in *"$FX"*) bad "9f the guard field carries no path" "$_sum" ;; *) ok "9f the guard field carries no path" ;; esac

printf '\n  %d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
