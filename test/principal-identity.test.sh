#!/bin/bash
# test/principal-identity.test.sh - principals.d carries TWO identity sources.
# A tailnet login is an address and is matched case-insensitively; an OIDC
# identity is <issuer-slug>:<subject>, and the SUBJECT is case-sensitive - a
# provider that mints a base64url subject mints "aB" and "Ab" as two people.
set -u
here="$(CDPATH= cd -- "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
pass=0; fail=0
ok()  { pass=$((pass+1)); printf '  ok   %s\n' "$1"; }
bad() { fail=$((fail+1)); printf '  FAIL %s\n     %s\n' "$1" "${2:-}"; }
is()  { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "wanted '$3', got '$2'"; fi; }
has() { case "$2" in *"$3"*) ok "$1" ;; *) bad "$1" "missing '$3' in: $2" ;; esac; }
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
ROOT="$T/estate"; mkdir -p "$ROOT/principals.d" "$ROOT/estate"
printf 'ESTATE_NAME="fixture"\n' > "$ROOT/estate/steward.conf"
export STEWARD_ESTATE_ROOT="$ROOT" STEWARD_CONFIG_FILE="$T/no-such-config"
. "$here/lib/registry.sh"
echo "principal-identity"

printf 'NAME="Alice"\nTAILSCALE_LOGIN="login-a@example.test"\nOIDC_LOGIN="issuer-a:SUB-1"\nOIDC_EMAIL="alice@example.test"\n' \
  > "$ROOT/principals.d/alice.conf"
printf 'NAME="Bo"\nOIDC_LOGIN="issuer-a:SUB-2 issuer-b:SUB-3"\n' > "$ROOT/principals.d/bo.conf"

registry_principal_load alice; rc=$?
is  "a row with both sources loads" "$rc" "0"
is  "the tailnet login is exposed" "$PRINCIPAL_TAILSCALE_LOGIN" "login-a@example.test"
is  "the oidc identity is exposed" "$PRINCIPAL_OIDC_LOGIN" "issuer-a:SUB-1"
is  "the display email is exposed" "$PRINCIPAL_OIDC_EMAIL" "alice@example.test"

registry_principal_load bo; rc=$?
is  "a row with ONLY an oidc identity loads" "$rc" "0"
is  "and carries no tailnet login" "$PRINCIPAL_TAILSCALE_LOGIN" ""
is  "and exposes both oidc words" "$PRINCIPAL_OIDC_LOGIN" "issuer-a:SUB-2 issuer-b:SUB-3"

printf 'NAME="Nobody"\n' > "$ROOT/principals.d/nobody.conf"
registry_principal_load nobody 2>"$T/err"; rc=$?
is  "a row with neither source is refused" "$rc" "1"
has "and still names TAILSCALE_LOGIN" "$(cat "$T/err")" "TAILSCALE_LOGIN"
is  "a refused load leaves nothing behind" "$PRINCIPAL_OIDC_LOGIN" ""

printf 'NAME="Bad"\nOIDC_LOGIN="no-colon-here"\n' > "$ROOT/principals.d/bad.conf"
registry_principal_load bad 2>"$T/err"; rc=$?
is  "an oidc word without a subject is refused" "$rc" "1"
has "and names the field" "$(cat "$T/err")" "OIDC_LOGIN"
rm -f "$ROOT/principals.d/bad.conf"

is  "the oidc lookup finds the row" "$(registry_principal_for_identity oidc issuer-a:SUB-1)" "alice"
is  "the second word of a list resolves" "$(registry_principal_for_identity oidc issuer-b:SUB-3)" "bo"
registry_principal_for_identity oidc issuer-a:sub-1 >/dev/null 2>&1; rc=$?
is  "the SUBJECT is case-sensitive" "$rc" "1"
registry_principal_for_identity oidc issuer-a:SUB-9 >/dev/null 2>&1; rc=$?
is  "an unknown oidc identity is rc 1" "$rc" "1"
registry_principal_for_identity elsewhere x >/dev/null 2>&1; rc=$?
is  "an unknown source is rc 64" "$rc" "64"

is  "the tailscale source resolves" "$(registry_principal_for_identity tailscale login-a@example.test)" "alice"
is  "and is case-insensitive" "$(registry_principal_for_identity tailscale LOGIN-A@EXAMPLE.TEST)" "alice"
is  "the old wrapper is unchanged" "$(registry_principal_for_login login-a@example.test)" "alice"

printf 'NAME="Twin"\nOIDC_LOGIN="issuer-a:SUB-1"\n' > "$ROOT/principals.d/twin.conf"
registry_principal_for_identity oidc issuer-a:SUB-1 >"$T/out" 2>"$T/err"; rc=$?
is  "an oidc identity on two rows is rc 65" "$rc" "65"
is  "and prints no slug" "$(cat "$T/out")" ""
has "and names both rows" "$(cat "$T/err")" "twin"
rm -f "$ROOT/principals.d/twin.conf"

printf '\n  %d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
