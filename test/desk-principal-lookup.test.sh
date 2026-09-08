#!/bin/bash
# test/desk-principal-lookup.test.sh - the desk's bridge answers for BOTH
# entrances. The one-argument form is what the server calls today and must not
# move; the two-argument form is what the front will call.
set -u
here="$(CDPATH= cd -- "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
pass=0; fail=0
ok()  { pass=$((pass+1)); printf '  ok   %s\n' "$1"; }
bad() { fail=$((fail+1)); printf '  FAIL %s\n     %s\n' "$1" "${2:-}"; }
is()  { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "wanted '$3', got '$2'"; fi; }
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
ROOT="$T/estate"; mkdir -p "$ROOT/principals.d" "$ROOT/estate"
printf 'ESTATE_NAME="fixture"\n' > "$ROOT/estate/steward.conf"
export STEWARD_ESTATE_ROOT="$ROOT" STEWARD_CONFIG_FILE="$T/no-such-config"
B="$here/desk/bin/principal-for-login"
printf 'NAME="Alice"\nTAILSCALE_LOGIN="login-a@example.test"\nOIDC_LOGIN="issuer-a:SUB-1"\n' \
  > "$ROOT/principals.d/alice.conf"
echo "desk-principal-lookup"

out="$(bash "$B" login-a@example.test)"; rc=$?
is  "one argument still means the tailnet source" "$out" "alice"
is  "and exits 0" "$rc" "0"

out="$(bash "$B" tailscale login-a@example.test)"; rc=$?
is  "two arguments, tailscale" "$out" "alice"

out="$(bash "$B" oidc issuer-a:SUB-1)"; rc=$?
is  "two arguments, oidc" "$out" "alice"

bash "$B" oidc issuer-a:SUB-9 >/dev/null 2>&1; rc=$?
is  "an unknown identity is rc 1" "$rc" "1"
bash "$B" elsewhere x >/dev/null 2>&1; rc=$?
is  "an unknown source is rc 64" "$rc" "64"
bash "$B" >/dev/null 2>&1; rc=$?
is  "no argument is rc 64" "$rc" "64"
bash "$B" a b c >/dev/null 2>&1; rc=$?
is  "three arguments is rc 64" "$rc" "64"

printf 'NAME="Twin"\nOIDC_LOGIN="issuer-a:SUB-1"\n' > "$ROOT/principals.d/twin.conf"
bash "$B" oidc issuer-a:SUB-1 >/dev/null 2>&1; rc=$?
is  "an ambiguous identity is rc 65" "$rc" "65"

printf '\n  %d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
