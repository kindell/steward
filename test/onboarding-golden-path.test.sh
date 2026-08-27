#!/bin/bash
# test/onboarding-golden-path.test.sh — empty -> a verifiable first session,
# driven hermetically through the scaffold engine. This is the deliverable's
# proof: it runs on every suite pass, in a temp dir, touching no real machine.
set -u

here="$(CDPATH= cd -- "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
pass=0; fail=0
ok()  { pass=$((pass+1)); }
bad() { echo "FAIL: $1"; fail=$((fail+1)); }
check(){ local d="$1"; shift; if "$@"; then ok; else bad "$d"; fi; }

# shellcheck source=/dev/null
. "$here/lib/scaffold.sh"

FX="$(mktemp -d)"; trap 'rm -rf "$FX"' EXIT

echo "== the scaffold writes a readable estate =="
estate_scaffold "$FX/e" org=acme team=kindell owner=alice session=home-alice \
  assets="mail:kindell chromium-rig"
rc=$?
check "scaffold rc 0" [ "$rc" -eq 0 ]
check "estate file written" [ -f "$FX/e/estate/steward.conf" ]
check "estate file is mode 600" \
  [ "$(stat -c %a "$FX/e/estate/steward.conf" 2>/dev/null || stat -f %Lp "$FX/e/estate/steward.conf")" = "600" ]

# THE ESTATE MUST BE READABLE BY THE PRODUCT'S OWN READERS — "written" is not
# "loadable". Every key is resolved through registry.sh, so a missing field
# surfaces here, not at first supervision.
( export STEWARD_ESTATE_ROOT="$FX/e"
  # shellcheck source=/dev/null
  . "$here/lib/registry.sh"
  registry_schema_check
) ; check "schema check passes" [ "$?" -eq 0 ]

nm="$( export STEWARD_ESTATE_ROOT="$FX/e"; . "$here/lib/registry.sh"; registry_estate_name 2>/dev/null )"
check "ESTATE_NAME resolves to org" [ "$nm" = "acme" ]

# ALL 16 FIELDS RESOLVE. A refusal from any reader means a missing field.
allok=1
for fn in registry_hub_session registry_hub_host registry_hub_ssh \
          registry_rc_label_prefix registry_job_log_dir registry_tmux_socket \
          registry_ping_msg registry_state_dir_name; do
  ( export STEWARD_ESTATE_ROOT="$FX/e"; . "$here/lib/registry.sh"; "$fn" >/dev/null 2>&1 ) || allok=0
done
check "all estate readers resolve" [ "$allok" -eq 1 ]

# THE REGISTRY DIRECTORIES EXIST — a register that is missing refuses; one that
# is empty is valid. The identity model needs entities.d and projects.d, which
# today's install.sh does not create.
for d in sessions.d entities.d projects.d jobs.d services.d browsers.d hosts.d; do
  check "dir $d created" [ -d "$FX/e/$d" ]
done

echo "== validation rejects invalid names =="
estate_scaffold "$FX/bad-leading-digit" org=9acme team=kindell owner=alice session=home-alice >/dev/null 2>&1
check "org with leading digit rejected" [ "$?" -eq 64 ]

estate_scaffold "$FX/bad-leading-dash" org=-acme team=kindell owner=alice session=home-alice >/dev/null 2>&1
check "org with leading dash rejected" [ "$?" -eq 64 ]

echo "== assets is validated, not sourced blind =="

# THE INJECTION THE REVIEWER DEMONSTRATED. assets is written into a conf that
# registry_load later SOURCES; an unescaped '"' closes the string early and
# anything after it runs as shell when the conf is loaded. Prove the field is
# rejected BEFORE it ever reaches disk, and that the payload never ran.
rm -f /tmp/SHOULD_NOT_EXIST
estate_scaffold "$FX/inject" org=acme team=kindell owner=alice session=home-alice \
  assets='x" ; touch /tmp/SHOULD_NOT_EXIST ; y="z' >/dev/null 2>&1
inj_rc=$?
check "malicious assets refused (rc 64)" [ "$inj_rc" -eq 64 ]
check "malicious assets did not write a session conf" [ ! -e "$FX/inject/sessions.d/home-alice.conf" ]
check "the injected command never ran" [ ! -e /tmp/SHOULD_NOT_EXIST ]
rm -f /tmp/SHOULD_NOT_EXIST

# A HANDFUL OF OTHER INJECTION SHAPES, so the fix is a character allowlist and
# not a single-pattern patch over the one example the review happened to try.
estate_scaffold "$FX/inject-semicolon" org=acme team=kindell owner=alice session=s \
  assets='a;touch /tmp/SHOULD_NOT_EXIST_2' >/dev/null 2>&1
check "semicolon-only assets refused" [ "$?" -eq 64 ]
check "semicolon payload never ran" [ ! -e /tmp/SHOULD_NOT_EXIST_2 ]
rm -f /tmp/SHOULD_NOT_EXIST_2

estate_scaffold "$FX/inject-backtick" org=acme team=kindell owner=alice session=s \
  assets='a`touch /tmp/SHOULD_NOT_EXIST_3`' >/dev/null 2>&1
check "backtick assets refused" [ "$?" -eq 64 ]
check "backtick payload never ran" [ ! -e /tmp/SHOULD_NOT_EXIST_3 ]
rm -f /tmp/SHOULD_NOT_EXIST_3

estate_scaffold "$FX/inject-cmdsub" org=acme team=kindell owner=alice session=s \
  assets='a$(touch /tmp/SHOULD_NOT_EXIST_4)' >/dev/null 2>&1
check "command-substitution assets refused" [ "$?" -eq 64 ]
check "command-substitution payload never ran" [ ! -e /tmp/SHOULD_NOT_EXIST_4 ]
rm -f /tmp/SHOULD_NOT_EXIST_4

estate_scaffold "$FX/inject-and" org=acme team=kindell owner=alice session=s \
  assets='a && touch /tmp/SHOULD_NOT_EXIST_5' >/dev/null 2>&1
check "&&-joined assets refused" [ "$?" -eq 64 ]
check "&&-joined payload never ran" [ ! -e /tmp/SHOULD_NOT_EXIST_5 ]
rm -f /tmp/SHOULD_NOT_EXIST_5

estate_scaffold "$FX/inject-newline" org=acme team=kindell owner=alice session=s \
  assets="$(printf 'a\ntouch /tmp/SHOULD_NOT_EXIST_6')" >/dev/null 2>&1
check "newline-embedded assets refused" [ "$?" -eq 64 ]
check "newline payload never ran" [ ! -e /tmp/SHOULD_NOT_EXIST_6 ]
rm -f /tmp/SHOULD_NOT_EXIST_6

# A→B MUST STILL WORK: valid assets are not collateral damage from the fix.
estate_scaffold "$FX/valid-assets" org=acme team=kindell owner=alice session=home-alice \
  assets="mail:acme chromium-rig" >/dev/null 2>&1
check "valid assets scaffold rc 0" [ "$?" -eq 0 ]
check "valid assets written verbatim" \
  grep -q 'ASSETS="mail:acme chromium-rig"' "$FX/valid-assets/sessions.d/home-alice.conf"

echo "== the first team is registered =="
tm="$( export STEWARD_ESTATE_ROOT="$FX/e" STEWARD_REGISTRY_DIR="$FX/e/sessions.d"
       . "$here/lib/registry.sh"; registry_entity_load kindell >/dev/null 2>&1 && printf '%s' "$ENTITY_MEMBERS" )"
check "team kindell has member alice" bash -c 'case " $1 " in *" alice "*) exit 0;; *) exit 1;; esac' _ "$tm"

echo "== the first session loads and belongs to the team =="
( export STEWARD_ESTATE_ROOT="$FX/e" STEWARD_REGISTRY_DIR="$FX/e/sessions.d"
  . "$here/lib/registry.sh"; registry_load home-alice >/dev/null 2>&1 )
check "session home-alice loads (rc 0)" [ "$?" -eq 0 ]
owner="$( export STEWARD_ESTATE_ROOT="$FX/e" STEWARD_REGISTRY_DIR="$FX/e/sessions.d"
          . "$here/lib/registry.sh"; registry_load home-alice >/dev/null 2>&1; printf '%s' "$OWNER" )"
check "session owner is alice" [ "$owner" = "alice" ]

# ASSETS is written but not read by registry_load here (that reader is subsystem
# B) — the declaration lives in the conf, so assert on the file.
check "session declares its assets" \
  grep -q 'ASSETS="mail:kindell chromium-rig"' "$FX/e/sessions.d/home-alice.conf"

echo "== the steward command exposes scaffold as --json =="
out="$( "$here/bin/steward" scaffold "$FX/j" org=acme team=kindell owner=alice \
        session=home-alice assets="mail:kindell" --json 2>/dev/null )"
rc=$?
check "steward scaffold rc 0" [ "$rc" -eq 0 ]
check "output is valid json" bash -c 'printf "%s" "$1" | jq -e . >/dev/null 2>&1' _ "$out"
check "json names the estate" bash -c 'printf "%s" "$1" | jq -e ".estate == \"acme\"" >/dev/null 2>&1' _ "$out"
check "json names the session" bash -c 'printf "%s" "$1" | jq -e ".session == \"home-alice\"" >/dev/null 2>&1' _ "$out"
check "json reports loadable true" bash -c 'printf "%s" "$1" | jq -e ".loadable == true" >/dev/null 2>&1' _ "$out"
check "json reports ok true" bash -c 'printf "%s" "$1" | jq -e ".ok == true" >/dev/null 2>&1' _ "$out"

# A REFUSAL IS STRUCTURED TOO, never a bare non-zero. A bad org must produce
# json with ok=false and a reason, so the TUI can render it.
bad_out="$( "$here/bin/steward" scaffold "$FX/bad" org=ACME team=kindell owner=alice session=s --json 2>/dev/null )"
check "a refusal is json with ok=false" bash -c 'printf "%s" "$1" | jq -e ".ok == false" >/dev/null 2>&1' _ "$bad_out"

echo
printf 'pass=%s fail=%s\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
