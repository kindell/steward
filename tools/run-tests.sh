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
#
# WRITING OR BELIEVING A GUARD: docs/guards-and-proofs.md. A green run is a
# claim about the tests until you know why it is green - that file carries the
# measurements behind that sentence.

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
# WHETHER A LIMIT CAN BE APPLIED IS DECIDED ONCE, HERE, AND NOT INSIDE
# run_with_timeout. The runner calls it as `out="$(run_with_timeout ...)"`, a
# COMMAND SUBSTITUTION - a subshell - so a variable the function sets there
# never reaches the caller that has to read rc 124. Measured: the first cut set
# it in the function and the caller saw the old value every time.
#
# SET ONCE, READ TWICE. That makes "this host has no timeout(1)" a fact the
# RUNNER holds, not a question asked again in every branch that needs it -
# the same shape as _rt_cfg in the config isolation: a path the runner owns,
# not a value it asks about. (the other estate's product session, 2026-09-15)
if command -v timeout >/dev/null 2>&1; then _RT_LIMITED=1; else _RT_LIMITED=0; fi

# WHERE A RED SUITE'S OUTPUT IS KEPT. Outside the repo under test, because the
# checkout must stay clean: rule 14 binds a run to a commit and verifies HEAD
# and `git status` around it, and a runner that dropped files into the tree
# would fail the very check it exists to serve.
RED_DIR="${RUN_TESTS_RED_DIR:-${TMPDIR:-/tmp}/run-tests-red.$$}"

# The operator config (~/.config/steward/config) is the one file OUTSIDE the tree that every
# steward invocation reads. One operator line there (ESTATE=, 2026-09-12) turned ten suites red on
# a verified HEAD, on both platforms, with the tree itself green. A gate that claims to isolate the
# host points the loader at a path that does not exist - MEASURED: a missing file is "no config"
# (rc 0), while an empty file and /dev/null are both refused with rc 78 - so no host line can reach
# a suite. Suites that test the loader set their own STEWARD_CONFIG_FILE and override this.
# REMEMBERED BEFORE IT IS ISOLATED AWAY. The estate-guard block below may need the
# operator config to find out WHICH guard to run, and by then this variable points at
# the isolation. Captured here, once, so the two uses never contend: the suites get a
# path that does not exist, and the runner keeps the operator's real one for its own
# configuration. (Written after the first cut read it after the export and silently
# derived nothing.)
_rt_operator_cfg="${STEWARD_CONFIG_FILE:-$HOME/.config/steward/config}"
_rt_iso="$(mktemp -d 2>/dev/null || mktemp -d -t run-tests)" || exit 70
_rt_cfg="$_rt_iso/no-operator-config"     # the path WE own; nothing else may be removed
export STEWARD_CONFIG_FILE="$_rt_cfg"
trap 'rm -rf "$_rt_iso"' EXIT
ONLY="${2:-}"           # optional: run only suites whose name matches

red=0
silent=0
ran=0
found=0

run_with_timeout() {
  # `timeout` is not present everywhere; fall back to a plain run rather than
  # skipping the suite. Being unable to set a time limit is a worse day, but
  # silently omitting a suite is a silent failure.
  #
  # _RT_LIMITED RECORDS WHETHER A LIMIT WAS ACTUALLY APPLIED, and the caller
  # needs it to read rc 124. GNU timeout exits 124 when it kills, but 124 is
  # also an exit code a suite may choose for itself - and on a host without
  # `timeout` it can ONLY mean the latter. Saying "timed out" on a host that
  # never set a deadline would be a claim about a mechanism that was not there.
  if [ "$_RT_LIMITED" -eq 1 ]; then timeout "$TIMEOUT_S" "$@"
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
  # THE ISOLATED PATH MUST STILL BE ABSENT WHEN THIS SUITE STARTS. It is a writable path in a
  # 0700 directory, so a suite that creates it hands the NEXT suite an operator config the host
  # never had - the same class as the host config this isolation exists against, only from
  # inside the run. Absence is what "no config" means (measured: a missing file is rc 0, an
  # empty one rc 78), so the check is one test and the remedy is to remove it and say so.
  # ONLY THE PATH THIS RUNNER CREATED. The first cut removed whatever STEWARD_CONFIG_FILE
  # pointed at - so a run whose isolation had been edited away would DELETE THE OPERATOR'S REAL
  # CONFIG. Caught by this suite's own control (4b), which runs the runner with the isolation
  # stripped and a poisoned config in the environment: the check ate the fixture's file and the
  # control went silent instead of red. A cleanup that can touch a path it did not create is not
  # a cleanup.
  if [ "${STEWARD_CONFIG_FILE:-}" = "$_rt_cfg" ] && [ -e "$_rt_cfg" ]; then
    printf '  NOTE   %-34s a previous suite wrote %s - removed before this suite\n' "$name" "$_rt_cfg"
    rm -f "$_rt_cfg"
  fi
  out="$(run_with_timeout bash "$t" 2>"$errfile")"
  rc=$?
  n="$(counts "$out")"
  # A SUITE THAT WAS KILLED SAYS SO, AND SAYS THE LIMIT. It used to report
  # `?/?` - the same string a suite gets when its output cannot be parsed at
  # all - so a reader of a timed-out suite went looking for a syntax error.
  # Measured 2026-09-15 on a loaded host: a suite that normally takes 328s was
  # killed at 200 and reported `?/?`; two readers in two estates began by
  # hunting for a broken edit. The outcome was true (it did not finish) and
  # pointed the wrong way (the cause was the clock, not the code).
  if [ "${_RT_LIMITED:-0}" -eq 1 ] && [ "$rc" -eq 124 ]; then
    n="TIMEOUT after ${TIMEOUT_S}s"
  fi
  [ -n "$n" ] || n="?/?"

  # Silent syntax errors: written to stderr without counting as test failures.
  # NO `|| echo 0` here: `grep -c` already PRINTS "0" and returns 1 when it
  # finds nothing, so the fallback appended a second "0" and made the value
  # "0\n0" — which then failed the next test with "integer expression
  # expected". The error handling destroyed the value it was meant to protect.
  n_syntax="$(grep -ciE 'syntax error|unexpected token' "$errfile" 2>/dev/null)"
  [ -n "$n_syntax" ] || n_syntax=0

  if [ "$rc" -ne 0 ]; then
    printf '  RED    %-34s %s\n' "$name" "$n"
    red=$((red+1))
    # A RED SUITE'S OUTPUT IS KEPT AND SHOWN. It used to be thrown away: the
    # suite's stdout went into `out`, which nothing printed, and `errfile` was
    # deleted one line above this branch -- so a red suite reported a COUNT and
    # destroyed the evidence behind it. The one moment the output is needed is
    # the one moment it was discarded, in a runner whose whole purpose is to
    # "say what happened".
    #
    # Measured: a suite came back 54/45 in a full run and green on every run
    # after, and the question that would have settled it -- WHICH 45 claims fell,
    # clustered (leaked state) or scattered (something global) -- could not be
    # asked at all, because nothing had kept them.
    #
    # The failing lines go to the terminal, capped, so a sweep of 128 suites
    # stays readable; the whole thing goes to a file that OUTLIVES the run,
    # outside the repo under test so the checkout stays clean for rule 14.
    mkdir -p "$RED_DIR" 2>/dev/null
    { printf '%s\n' "$out"; printf '\n--- stderr ---\n'; cat "$errfile" 2>/dev/null; } > "$RED_DIR/$name.out" 2>/dev/null
    _rt_lines="$(printf '%s\n' "$out" | grep -nE '^[[:space:]]*(FAIL|not ok|✗|x )' | head -20)"
    if [ -n "$_rt_lines" ]; then
      printf '%s\n' "$_rt_lines" | sed 's/^/         /'
      _rt_tot="$(printf '%s\n' "$out" | grep -cE '^[[:space:]]*(FAIL|not ok|✗|x )')"
      [ "$_rt_tot" -gt 20 ] && printf '         ... and %s more\n' "$((_rt_tot-20))"
    else
      # NO RECOGNISED FAILURE MARKER is itself worth saying. A suite can exit
      # non-zero without printing a claim at all, and silence here would read
      # as "no failures" -- the same equivalence between absence and emptiness
      # this product keeps paying for.
      if [ "${_RT_LIMITED:-0}" -eq 1 ] && [ "$rc" -eq 124 ]; then
        printf '         (killed at the %ss limit - RUN_TESTS_TIMEOUT; it did not fail, it did not finish)\n' "$TIMEOUT_S"
      else
        printf '         (no recognised failure line; the suite exited %s)\n' "$rc"
      fi
    fi
    printf '         full output: %s\n' "$RED_DIR/$name.out"
    rm -f "$errfile"
  elif [ "$n_syntax" -gt 0 ]; then
    printf '  SILENT %-34s %s — %s syntax error(s) on stderr WITHOUT a test failure: the measurement did not run\n' \
      "$name" "$n" "$n_syntax"
    silent=$((silent+1))
    # THE SAME RULE AS THE RED BRANCH, AND THIS ONE NEEDS IT MORE. The line says
    # a measurement did NOT run, and then deleted the only text that said WHICH:
    # the syntax error, and the line it was on, went out with errfile. A reader
    # of that line is left knowing something broke and unable to find out what -
    # which is the state this whole branch exists to prevent.
    #
    # Only stderr is kept here. stdout is the suite's ordinary chatter and the
    # counter already summarises it; the evidence for a SILENT verdict is what
    # was written to stderr WITHOUT being counted.
    mkdir -p "$RED_DIR" 2>/dev/null
    cp "$errfile" "$RED_DIR/$name.stderr" 2>/dev/null
    grep -nE 'syntax error|unexpected token' "$errfile" 2>/dev/null | head -10 | sed 's/^/         /'
    printf '         full stderr: %s\n' "$RED_DIR/$name.stderr"
    rm -f "$errfile"
  else
    printf '  ok     %-34s %s\n' "$name" "$n"
    rm -f "$errfile"
  fi
done

echo
echo "== node suites =="
for d in fleet watchdog watch; do
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
rust="none"              # none: no rust suite in this tree; ok|RED|not-run otherwise
for d in cockpit; do
  [ -d "$d" ] || continue
  found=$((found+1))
  case "$d" in *"$ONLY"*) ;; *) continue ;; esac
  ran=$((ran+1))
  if [ ! -x "$CARGO" ]; then
    # A MISSING TOOL IS NOT A GREEN TEST - but it is not a red product either. It is a measurement
    # that could not be made, and it is SAID so: a NOT RUN line with the path that was looked at,
    # and rust=not-run in the summary, the same form as the estate guard. It used to count as RED;
    # on the two steward homes that have no Rust (2026-09-12, both platforms) every full gate then
    # carried one red that meant "no cargo here", and a summary that never reads red=0 stops
    # meaning anything. The count of suites that RAN is not touched: this suite did not run.
    ran=$((ran-1)); rust="not-run"
    printf '  NOT RUN %-33s cargo missing at %s\n' "$d" "$CARGO"; continue
  fi
  if run_with_timeout bash -c "cd '$d' && '$CARGO' test --quiet" >/dev/null 2>&1; then
    printf '  ok     %-34s\n' "$d"; [ "$rust" = "not-run" ] || rust="ok"
  else
    printf '  RED    %-34s (cargo test)\n' "$d"
    red=$((red+1)); rust="RED"
  fi
done

echo
echo "== estate guard =="
# THE NAME GUARD LIVES WHERE THE NAME LIST LIVES - in the estate - and the product's gate RUNS it
# when an estate is designated, so a PR carrying a customer's or a machine's name falls here, on
# the host it is merged from, and not in the estate's own gate afterwards (twice in one afternoon,
# 2026-09-12). STEWARD_ESTATE_ROOT is the estate CHECKOUT when the gate is run as CLAUDE.md
# prescribes; a deployed home has no test/ and the guard is not run there. A guard that was not
# run is SAID so, in the summary line, and never looks like one that passed.
estate_guard="not-run"
eg_reason=""
eg_src="env"

# AN UNSET ROOT IS DERIVED FROM THE OPERATOR CONFIG, BECAUSE A GUARD THAT MUST BE
# REMEMBERED IS A GUARD THAT WILL BE FORGOTTEN.
#
# Measured 2026-09-15/16, on the other estate: every gate run there reported
# estate-guard=not-run, for a whole night, because the variable was only ever set
# in ~/.config/steward/config and the gate environment does not read it. Two
# receipts reported on a surface they could not see, and the explanation given
# alongside them ("this estate has no guard") was false - the guard was there.
#
# The direction of the error decides this. Derive, and a guard may run when nobody
# asked: the gate is STRICTER than expected, and a red suite with a name in it says
# so immediately. Do not derive, and a guard silently does not run: the gate is
# LOOSER than expected, and that is not self-reporting - it went unnoticed for a
# night. One failure direction announces itself; the other does not.
#
# THE ISOLATION THIS DOES NOT BREAK: STEWARD_CONFIG_FILE is pointed at a path that
# does not exist for the SUITES, so the host's config cannot fail a test. That is
# about the INPUT to what is measured. The estate root is not something a suite
# reads - it is this runner's own configuration, WHICH guard to run. Reading the
# operator config for that is a different dependency, and the summary line says
# which one was used so the two are never confused.
if [ -z "${STEWARD_ESTATE_ROOT+set}" ]; then
  # UNSET, not empty. `STEWARD_ESTATE_ROOT=` means "no estate, deliberately" and is
  # left alone: otherwise the only way to run without the guard would be to edit the
  # operator config - a durable change for a temporary need.
  _rt_cfg_file="$_rt_operator_cfg"
  if [ -f "$_rt_cfg_file" ] && [ ! -L "$_rt_cfg_file" ]; then
    # ONE KEY, READ THE WAY THE LOADER SPELLS IT, and nothing else from the file.
    # The CLI's loader owns this format - symlinks refused, FORMAT=1, an allowlist -
    # and a second full reader of a format is the defect the lifecycle gate was
    # written against. This reads one line and does not pretend to validate the file.
    _rt_cfg_root="$(sed -n 's/^STEWARD_ESTATE_ROOT="\{0,1\}\([^"]*\)"\{0,1\}$/\1/p' "$_rt_cfg_file" 2>/dev/null | head -1)"
    if [ -n "$_rt_cfg_root" ]; then
      STEWARD_ESTATE_ROOT="$_rt_cfg_root"; eg_src="config"
    fi
  fi
fi

if [ -z "${STEWARD_ESTATE_ROOT:-}" ]; then
  eg_reason="no estate designated (STEWARD_ESTATE_ROOT unset in env and operator config)"
elif [ ! -f "$STEWARD_ESTATE_ROOT/test/leak-guard.test.sh" ]; then
  # TWO DIFFERENT FAILURES MUST NOT READ ALIKE. "You pointed at a tree without a
  # guard" and "we found a root in your config and it has no guard" send a reader
  # to different places, and the night this was written was spent on two people
  # reading one wording as the other.
  if [ "$eg_src" = config ]; then
    eg_reason="not run (root derived from operator config: $STEWARD_ESTATE_ROOT) - no guard at $STEWARD_ESTATE_ROOT/test"
  else
    eg_reason="no estate test dir at $STEWARD_ESTATE_ROOT/test, not run"
  fi
else
  # STEWARD_PRODUCT_REPO IS THIS TREE - the one being gated - never a sibling checkout: the guard
  # derives the product surface from it, and a PR must be measured against its own files.
  # WHOSE list ran is part of the answer. Each estate's guard knows only its OWN names, and the
  # lists are disjoint by construction - a name in one estate's register is absent from the others
  # (measured 2026-09-13: two people appear in the product and in no list on this host). A bare
  # 'ok' would read as "no names anywhere", which no single run can establish. The estate's name is
  # DERIVED from the designated root, never written down twice. Rule 14, second corollary.
  # THE ESTATE NAMES ITSELF; A DIRECTORY DOES NOT.
  #
  # basename of the root was the name until the root could be DERIVED. A derived root
  # is ~/scripts in every home on every host, so every derived receipt would have read
  # estate-guard=ok(scripts) - no estate named at all, on the exact runs where knowing
  # WHICH list ran matters most. Measured on both estates before this line was written:
  # one predicted ok(<estate>), the other got ok(scripts), same estate and same list.
  #
  # estate/steward.conf carries ESTATE_NAME, and it is deployed into every home, so the
  # name is readable from the deployed copy as well as from the checkout. Nothing else
  # is read from that file here.
  eg_who="$(sed -n 's/^ESTATE_NAME="\{0,1\}\([^"]*\)"\{0,1\}$/\1/p' "$STEWARD_ESTATE_ROOT/estate/steward.conf" 2>/dev/null | head -1)"
  [ -n "$eg_who" ] || eg_who="$(basename "$STEWARD_ESTATE_ROOT")"   # an estate without the key still says something
  eg_out="$(run_with_timeout env STEWARD_PRODUCT_REPO="$HERE" bash "$STEWARD_ESTATE_ROOT/test/leak-guard.test.sh" 2>&1)"; eg_rc=$?
  eg_n="$(counts "$eg_out")"; [ -n "$eg_n" ] || eg_n="?/?"
  # THE LIST DIGEST IS A PAIR PROPERTY, SO ITS ABSENCE IS PRINTED TOO.
  #
  # Two receipts that both say ok(designated) are consistent with "two estates, two
  # lists" AND with "one estate measured twice" - and the reader cannot tell. A digest
  # of the list each guard actually ran settles it: different digests prove different
  # lists, the same digest proves the same list, and neither leaks a name or even a
  # COUNT (a count says how many people and customers an estate has; a digest says
  # nothing).
  #
  # Measured 2026-09-16, and it is why the absence is printed rather than omitted: five
  # open PRs carried "green on both halves" while one half had never run a name list at
  # all. A field that is simply missing reads as a field that was not needed - the same
  # equivalence between absence and emptiness this runner has paid for twice. A digest
  # and a blank prove exactly as little as two blanks; saying WHICH half brought one is
  # what makes the gap visible while the estates converge.
  #
  # The guard owns the definition. This reads the line it prints and carries it verbatim;
  # computing one here would be a second reader of the list.
  eg_digest="$(printf '%s\n' "$eg_out" | sed -n 's/^LIST-DIGEST=\([0-9a-fA-F][0-9a-fA-F]*\).*$/\1/p' | head -1)"
  [ -n "$eg_digest" ] || eg_digest="absent"
  # THE SUMMARY LINE SAYS THE ROLE; THE SUITE LINE SAYS THE NAME.
  #
  # The summary is the line people paste into a pull request as proof. So the tool
  # that proves this surface carries no host or customer names was writing one INTO
  # the proof, and our own habit published it: four of one author's PR bodies and
  # several of another's carried an estate's directory name, every one of them from
  # a pasted receipt (measured 2026-09-15, in the public repo).
  #
  # What a reader of a receipt needs is that the DESIGNATED estate's list ran - not
  # which estate it was; the estates' lists are disjoint, so "designated" already
  # says the run could only have used the one it was pointed at. The name stays on
  # the suite line above, which is where somebody debugging a red guard looks and
  # which nobody pastes.
  #
  # A guard that reads files cannot see issues and pull-request prose; that surface
  # has no guard at all. This does not give it one - it stops handing it material.
  # THE SUMMARY SAYS THE ROLE, AND WHERE THE ROOT CAME FROM. Two receipts that both say
  # ok(designated) are consistent with "two estates, disjoint lists" AND with "one estate
  # measured twice" - and the reader cannot tell which. That linux+darwin means two
  # estates today is an UNWRITTEN INVARIANT, and unwritten invariants have cost this
  # fleet twice in a night. The source word says whether the guard ran because somebody
  # ASKED (env) or because the host said so (config), which is the same distinction the
  # role made reproducible in the first place.
  eg_tag="designated"; [ "$eg_src" = config ] && eg_tag="designated:config"
  eg_tag="$eg_tag, list=$eg_digest"
  if [ "$eg_rc" -eq 0 ]; then estate_guard="ok($eg_tag)"; printf '  ok     %-34s %s\n' "estate leak-guard ($eg_who)" "$eg_n"
  else estate_guard="RED($eg_tag)"; red=$((red+1)); printf '  RED    %-34s %s\n' "estate leak-guard ($eg_who)" "$eg_n"
       printf '%s\n' "$eg_out" | grep -E '^\s+/|^FAIL' | head -12 | sed 's/^/         /'
       # THE ONE RED WHOSE EVIDENCE NOBODY ELSE CAN REPRODUCE MUST BE KEPT.
       #
       # Every shell suite's output is saved when it goes red. This guard's was not -
       # it printed twelve matching lines and dropped the rest, in the one case where
       # the person who needs them CANNOT re-run it: the name list lives in the estate,
       # so a steward on a host without one gets estate-guard=not-run and has no way to
       # ask what fell. Measured 2026-09-15: a colleague asked for exactly that line off
       # a red on their own branch, and there was no file to send.
       mkdir -p "$RED_DIR" 2>/dev/null
       printf '%s\n' "$eg_out" > "$RED_DIR/estate-leak-guard.out" 2>/dev/null
       printf '         full output: %s\n' "$RED_DIR/estate-leak-guard.out"
  fi
fi
[ -n "$eg_reason" ] && printf '  NOT RUN estate leak-guard: %s\n' "$eg_reason"
echo
echo "suites found=$found ran=$ran red=$red silent=$silent rust=$rust estate-guard=$estate_guard"
[ -n "$ONLY" ] && echo "NOTE: filter '$ONLY' is active — this is NOT a full run."
expected_ran=$found; [ "$rust" = "not-run" ] && expected_ran=$((found-1))   # said in the summary, not swept under
if [ "$ran" -ne "$expected_ran" ] && [ -z "$ONLY" ]; then
  echo "REFUSED: $ran of $found suites ran with no filter — the sweep skipped something." >&2
  exit 1
fi
[ "$red" -eq 0 ] && [ "$silent" -eq 0 ]
