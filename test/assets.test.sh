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

echo
printf 'pass=%s fail=%s\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
