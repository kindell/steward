#!/bin/bash
# test/assets.test.sh — a session's assets, in two layers.
#
# DECLARED is the registry's truth: what the session SHOULD reach. It is
# hermetic and always testable. PROBED is health: whether each declared asset
# answers right now. The two are deliberately separate — declared is not
# working, and a view that conflates them lies in the direction of "fine".
set -u

here="$(CDPATH= cd -- "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
pass=0; fail=0
ok()  { pass=$((pass+1)); }
bad() { echo "FAIL: $1"; fail=$((fail+1)); }
check(){ local d="$1"; shift; if "$@"; then ok; else bad "$d"; fi; }

FX="$(mktemp -d)"; trap 'rm -rf "$FX"' EXIT
mkdir -p "$FX/sessions.d"
printf 'HOST="h"\nOWNER="alice"\nDOMAIN="kindell"\nRC_LABEL="L"\nREPO_PATH="/tmp/x"\nID="with-assets"\nASSETS="mail:kindell chromium-rig slack:acme"\n' \
  > "$FX/sessions.d/with-assets.conf"
printf 'HOST="h"\nOWNER="alice"\nDOMAIN="kindell"\nRC_LABEL="L"\nREPO_PATH="/tmp/x"\nID="no-assets"\n' \
  > "$FX/sessions.d/no-assets.conf"

export STEWARD_REGISTRY_DIR="$FX/sessions.d"
# shellcheck source=/dev/null
. "$here/lib/assets.sh"

echo "== declared assets come out of the registry =="
out="$(session_assets with-assets)"; rc=$?
check "session_assets rc 0" [ "$rc" -eq 0 ]
check "three assets, one per line" [ "$(printf '%s\n' "$out" | grep -c .)" -eq 3 ]
check "mail asset present"     bash -c 'printf "%s\n" "$1" | grep -qx "mail:kindell"' _ "$out"
check "rig asset present"      bash -c 'printf "%s\n" "$1" | grep -qx "chromium-rig"' _ "$out"
check "slack asset present"    bash -c 'printf "%s\n" "$1" | grep -qx "slack:acme"' _ "$out"

# NO ASSETS IS A VALID ANSWER, not an error. A session may legitimately reach
# nothing; refusing here would make "declares nothing" indistinguishable from
# "could not be read", which is the confusion this whole model exists to end.
echo "== a session with no assets answers empty, rc 0 =="
out2="$(session_assets no-assets)"; rc2=$?
check "no-assets rc 0" [ "$rc2" -eq 0 ]
check "no-assets prints nothing" [ -z "$out2" ]

# AN UNREADABLE SESSION MUST REFUSE. Empty output from a misspelled name is
# indistinguishable from "no assets" — the same silent-nothing this house has
# been hunting all week.
echo "== an unknown session refuses, never prints empty =="
out3="$(session_assets does-not-exist 2>/dev/null)"; rc3=$?
check "unknown session rc non-zero" [ "$rc3" -ne 0 ]

# THE RESET GUARANTEE. Loading a session WITHOUT assets after one WITH them must
# not inherit the previous value. The reset lines in registry_load are what make
# every field additive; a field added without a reset is a leak.
echo "== ASSETS does not leak between loads =="
leak="$( . "$here/lib/registry.sh"
         registry_load with-assets >/dev/null 2>&1
         registry_load no-assets   >/dev/null 2>&1
         printf '%s' "$ASSETS" )"
check "ASSETS is empty after loading a session without it" [ -z "$leak" ]


# GLOB EXPANSION MUST NOT LEAK INTO THE FIELD. The list is deliberately word-
# split (unquoted on purpose) but a literal '*' must come out as '*', not as
# whatever files happen to sit in the caller's cwd. Run from a directory that
# actually contains files, so a regression would manifest as extra lines.
echo "== a literal '*' in ASSETS survives, even with files in cwd =="
printf 'HOST="h"\nOWNER="alice"\nDOMAIN="kindell"\nRC_LABEL="L"\nREPO_PATH="/tmp/x"\nID="glob-assets"\nASSETS="mail:acme * chromium-rig"\n' \
  > "$FX/sessions.d/glob-assets.conf"
GLOBDIR="$(mktemp -d)"; trap 'rm -rf "$FX" "$GLOBDIR"' EXIT
: > "$GLOBDIR/aaa"; : > "$GLOBDIR/bbb"
glob_out="$(cd "$GLOBDIR" && session_assets glob-assets)"
check "exactly three assets, not glob-expanded" [ "$(printf '%s\n' "$glob_out" | grep -c .)" -eq 3 ]
check "literal '*' present"    bash -c 'printf "%s\n" "$1" | grep -qx "\*"' _ "$glob_out"
check "mail asset present too" bash -c 'printf "%s\n" "$1" | grep -qx "mail:acme"' _ "$glob_out"
check "rig asset present too"  bash -c 'printf "%s\n" "$1" | grep -qx "chromium-rig"' _ "$glob_out"
check "aaa did not sneak in"   bash -c '! printf "%s\n" "$1" | grep -qx "aaa"' _ "$glob_out"
check "bbb did not sneak in"   bash -c '! printf "%s\n" "$1" | grep -qx "bbb"' _ "$glob_out"

# set -f MUST NOT LEAK INTO THE CALLER. The function runs in the caller's own
# shell (no subshell), so calling it here — in THIS script's shell, not inside
# $(...) or (...) which would isolate any leak — must leave $- exactly as it
# was found. Also prove globbing itself still works afterward: a leaked
# `set -f` would make the next glob a no-op rather than flip a flag we forgot
# to read.
echo "== set -f does not leak into the caller =="
case "$-" in *f*) before_f=1 ;; *) before_f="" ;; esac
_save_pwd="$PWD"
cd "$GLOBDIR"
session_assets glob-assets >/dev/null
cd "$_save_pwd"
case "$-" in *f*) after_f=1 ;; *) after_f="" ;; esac
check "caller's -f flag unchanged by session_assets" [ "$before_f" = "$after_f" ]
_glob_check="$GLOBDIR"/*
set -- $_glob_check
check "caller's shell still globs after session_assets" [ "$#" -eq 2 ]

echo "== probing reports health, and never guesses =="

# THE PROBES ARE INJECTABLE. A probe that shells out to a real mail client or a
# real socket cannot run in a suite, so each type's measurement goes through an
# overridable command. The test drives stubs; production drives the real thing.
# Without this the probe layer would be untestable and would therefore be untested.
export STEWARD_ASSET_PROBE_CMD="$FX/probe-stub"
cat > "$FX/probe-stub" <<'STUB'
#!/bin/bash
# stub: <type> <arg> -> prints a status word, exits 0; exit 3 = cannot measure
case "$1" in
  mail)          echo "up logged-in" ;;
  slack)         echo "down no-token" ;;
  chromium-rig)  echo "local-only 127.0.0.1-only" ;;
  *)             exit 3 ;;
esac
STUB
chmod +x "$FX/probe-stub"

line="$(asset_probe mail:kindell)"
check "mail probes up"        bash -c '[[ "$1" == "mail:kindell up "* ]]' _ "$line"
line="$(asset_probe slack:acme)"
check "slack probes down"     bash -c '[[ "$1" == "slack:acme down "* ]]' _ "$line"
line="$(asset_probe chromium-rig)"
check "rig probes local-only" bash -c '[[ "$1" == "chromium-rig local-only "* ]]' _ "$line"

# AN UNMEASURABLE ASSET IS 'unknown', NEVER 'up' AND NEVER SILENT. This is the
# rule the whole house runs on: a measurement that cannot be made must say so.
line="$(asset_probe teams:acme)"
check "unmeasurable type is unknown" bash -c '[[ "$1" == "teams:acme unknown "* ]]' _ "$line"
check "unmeasurable is never up"     bash -c '[[ "$1" != *" up "* ]]' _ "$line"

# A MISSING PROBE COMMAND IS ALSO 'unknown' — not a crash, not silence. The
# cockpit must be able to render a fleet where probing is unavailable.
unset STEWARD_ASSET_PROBE_CMD
line="$(STEWARD_ASSET_PROBE_CMD=/nonexistent-probe asset_probe mail:kindell)"
check "missing probe command is unknown" bash -c '[[ "$1" == "mail:kindell unknown "* ]]' _ "$line"
export STEWARD_ASSET_PROBE_CMD="$FX/probe-stub"

# THE STATUS VOCABULARY IS CLOSED. Four words, no others — the cockpit renders
# on them and an unexpected word would render as nothing.
for a in mail:kindell slack:acme chromium-rig teams:acme; do
  w="$(asset_probe "$a" | awk '{print $2}')"
  case "$w" in up|local-only|down|unknown) ok ;; *) bad "unexpected status word '$w' for $a" ;; esac
done

echo "== a prober's own 'unknown' reason survives; a broken prober's does not =="

# UNKNOWN IS A LEGITIMATE ANSWER IN THE FOUR-WORD VOCABULARY, not a broken
# prober's invention. A prober that measured and honestly could not tell must
# have its own reason survive intact — collapsing it to the generic
# bad-status-from-probe would erase exactly the detail a reader needs
# (host-unreachable vs. no-session-context vs. no-rig-declared read very
# differently at the cockpit).
cat > "$FX/probe-stub-unknown" <<'STUB'
#!/bin/bash
echo "unknown some-specific-reason"
STUB
chmod +x "$FX/probe-stub-unknown"
line="$(STEWARD_ASSET_PROBE_CMD="$FX/probe-stub-unknown" asset_probe widget:x)"
check "a prober's own unknown reason survives" \
  [ "$line" = "widget:x unknown some-specific-reason" ]

# THE GUARD STILL BITES ON A WORD OUTSIDE THE VOCABULARY. A broken prober must
# never be able to invent a status the cockpit would render as healthy — that
# is the guard's real job, and accepting 'unknown' above must not weaken it.
cat > "$FX/probe-stub-bogus" <<'STUB'
#!/bin/bash
echo "healthy all-good"
STUB
chmod +x "$FX/probe-stub-bogus"
line="$(STEWARD_ASSET_PROBE_CMD="$FX/probe-stub-bogus" asset_probe widget:x)"
check "a word outside the vocabulary is still rewritten" \
  [ "$line" = "widget:x unknown bad-status-from-probe" ]

echo "== a hung probe times out instead of blocking forever =="

# A STUB THAT SLEEPS LONGER THAN THE LIMIT is what a stuck socket looks like.
# Without a deadline this would hang asset_probe forever — worse than 'unknown',
# since it reports NOTHING and blocks a caller that polls a whole fleet
# serially. The sleep is kept well above the limit (STUB_SLEEP > timeout) so
# the assertion below — that asset_probe returns well inside STUB_SLEEP — only
# passes if the deadline was actually enforced, not just outlasted by luck.
STUB_SLEEP=3
cat > "$FX/probe-stub-slow" <<STUB
#!/bin/bash
sleep $STUB_SLEEP
echo "up should-not-be-seen"
STUB
chmod +x "$FX/probe-stub-slow"

before=$SECONDS
line="$(STEWARD_ASSET_PROBE_CMD="$FX/probe-stub-slow" STEWARD_ASSET_PROBE_TIMEOUT=1 asset_probe mail:kindell)"
elapsed=$((SECONDS - before))
check "timed-out probe reports unknown" bash -c '[[ "$1" == "mail:kindell unknown "* ]]' _ "$line"
check "timed-out probe names the timeout" bash -c '[[ "$1" == *"probe-timeout"* ]]' _ "$line"
check "timed-out probe returns well inside the stub's sleep" [ "$elapsed" -lt "$STUB_SLEEP" ]

echo "== the steward command joins both layers as json =="
out="$( STEWARD_REGISTRY_DIR="$FX/sessions.d" STEWARD_ASSET_PROBE_CMD="$FX/probe-stub" \
        "$here/bin/steward" assets with-assets --json 2>/dev/null )"
rc=$?
check "assets --json rc 0" [ "$rc" -eq 0 ]
check "output is valid json" bash -c 'printf "%s" "$1" | jq -e . >/dev/null 2>&1' _ "$out"
check "json names the session" bash -c 'printf "%s" "$1" | jq -e ".session == \"with-assets\"" >/dev/null 2>&1' _ "$out"
check "json reports ok true" bash -c 'printf "%s" "$1" | jq -e ".ok == true" >/dev/null 2>&1' _ "$out"
check "three assets in the array" bash -c 'printf "%s" "$1" | jq -e ".assets | length == 3" >/dev/null 2>&1' _ "$out"
check "each entry carries a status" \
  bash -c 'printf "%s" "$1" | jq -e "[.assets[].status] | all(. != null and . != \"\")" >/dev/null 2>&1' _ "$out"
check "the rig entry is local-only" \
  bash -c 'printf "%s" "$1" | jq -e "[.assets[] | select(.asset==\"chromium-rig\") | .status] == [\"local-only\"]" >/dev/null 2>&1' _ "$out"

# A REFUSAL IS STRUCTURED TOO — the cockpit renders it, so it cannot be a bare
# non-zero with a message on stderr only.
bad_out="$( STEWARD_REGISTRY_DIR="$FX/sessions.d" "$here/bin/steward" assets does-not-exist --json 2>/dev/null )"
bad_rc=$?
check "unknown session rc non-zero" [ "$bad_rc" -ne 0 ]
check "refusal is json with ok false" bash -c 'printf "%s" "$1" | jq -e ".ok == false" >/dev/null 2>&1' _ "$bad_out"

# WITHOUT --json THE DATA IS THE SAME, just line-oriented. No ANSI: the engine
# never renders.
plain="$( STEWARD_REGISTRY_DIR="$FX/sessions.d" STEWARD_ASSET_PROBE_CMD="$FX/probe-stub" \
          "$here/bin/steward" assets with-assets 2>/dev/null )"
check "plain output has three lines" [ "$(printf '%s\n' "$plain" | grep -c .)" -eq 3 ]
check "plain output carries no escape codes" bash -c '! printf "%s" "$1" | grep -q "$(printf "\033")"' _ "$plain"

echo "== usage errors with --json are structured on stdout =="

# NO SESSION NAME: --json BEFORE the error
no_sess="$( STEWARD_REGISTRY_DIR="$FX/sessions.d" "$here/bin/steward" assets --json 2>/dev/null )"
no_sess_rc=$?
check "no session with --json gives rc 64" [ "$no_sess_rc" -eq 64 ]
check "no session with --json gives valid json" bash -c 'printf "%s" "$1" | jq -e . >/dev/null 2>&1' _ "$no_sess"
check "no session json has ok false" bash -c 'printf "%s" "$1" | jq -e ".ok == false" >/dev/null 2>&1' _ "$no_sess"
check "no session json includes reason" bash -c 'printf "%s" "$1" | jq -e ".reason" >/dev/null 2>&1' _ "$no_sess"

# TWO SESSION NAMES: --json BEFORE the error
two_sess="$( STEWARD_REGISTRY_DIR="$FX/sessions.d" "$here/bin/steward" assets --json with-assets no-assets 2>/dev/null )"
two_sess_rc=$?
check "two sessions with --json gives rc 64" [ "$two_sess_rc" -eq 64 ]
check "two sessions with --json gives valid json" bash -c 'printf "%s" "$1" | jq -e . >/dev/null 2>&1' _ "$two_sess"
check "two sessions json has ok false" bash -c 'printf "%s" "$1" | jq -e ".ok == false" >/dev/null 2>&1' _ "$two_sess"

# UNKNOWN FLAG: --json BEFORE the error
unknown_flag="$( STEWARD_REGISTRY_DIR="$FX/sessions.d" "$here/bin/steward" assets --json --bogus 2>/dev/null )"
unknown_flag_rc=$?
check "unknown flag with --json gives rc 64" [ "$unknown_flag_rc" -eq 64 ]
check "unknown flag with --json gives valid json" bash -c 'printf "%s" "$1" | jq -e . >/dev/null 2>&1' _ "$unknown_flag"
check "unknown flag json has ok false" bash -c 'printf "%s" "$1" | jq -e ".ok == false" >/dev/null 2>&1' _ "$unknown_flag"

# UNKNOWN FLAG: --json AFTER the error (test argv ordering)
unknown_flag_after="$( STEWARD_REGISTRY_DIR="$FX/sessions.d" "$here/bin/steward" assets --bogus --json 2>/dev/null )"
unknown_flag_after_rc=$?
check "unknown flag after --json gives rc 64" [ "$unknown_flag_after_rc" -eq 64 ]
check "unknown flag after --json gives valid json" bash -c 'printf "%s" "$1" | jq -e . >/dev/null 2>&1' _ "$unknown_flag_after"
check "unknown flag after --json json has ok false" bash -c 'printf "%s" "$1" | jq -e ".ok == false" >/dev/null 2>&1' _ "$unknown_flag_after"

echo
printf 'pass=%s fail=%s\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
