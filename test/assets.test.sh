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

echo
printf 'pass=%s fail=%s\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
