#!/bin/bash
# test/principal-identity-verb.test.sh - the write side of the second identity
# source: one identity, one human, enforced before the lock and again under it.
set -u
here="$(CDPATH= cd -- "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
pass=0; fail=0
ok()  { pass=$((pass+1)); printf '  ok   %s\n' "$1"; }
bad() { fail=$((fail+1)); printf '  FAIL %s\n     %s\n' "$1" "${2:-}"; }
is()  { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "wanted '$3', got '$2'"; fi; }
has() { case "$2" in *"$3"*) ok "$1" ;; *) bad "$1" "missing '$3' in: $2" ;; esac; }
no()  { case "$2" in *"$3"*) bad "$1" "found '$3' in: $2" ;; *) ok "$1" ;; esac; }
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
ROOT="$T/estate"; mkdir -p "$ROOT/principals.d" "$ROOT/estate"
printf 'ESTATE_NAME="fixture"\n' > "$ROOT/estate/steward.conf"
export STEWARD_ESTATE_ROOT="$ROOT" STEWARD_CONFIG_FILE="$T/no-such-config"
S="$here/bin/steward"
echo "principal-identity-verb"

out="$(bash "$S" registry principal add alice --name Alice --oidc-login issuer-a:SUB-1 2>&1)"; rc=$?
is  "an oidc-only principal is written" "$rc" "0"
has "the row carries the identity" "$(cat "$ROOT/principals.d/alice.conf")" 'OIDC_LOGIN="issuer-a:SUB-1"'
no  "and no empty tailnet line" "$(cat "$ROOT/principals.d/alice.conf")" 'TAILSCALE_LOGIN=""'

out="$(bash "$S" registry principal add bo --name Bo --tailscale-login login-b@example.test 2>&1)"; rc=$?
is  "a tailnet-only principal still works" "$rc" "0"
no  "and carries no empty oidc line" "$(cat "$ROOT/principals.d/bo.conf")" 'OIDC_LOGIN=""'

out="$(bash "$S" registry principal add cy --name Cy --oidc-login 'issuer-a:SUB-9 issuer-b:SUB-9' \
        --oidc-email cy@example.test --tailscale-login login-c@example.test 2>&1)"; rc=$?
is  "both sources on one row" "$rc" "0"
has "both oidc words are written" "$(cat "$ROOT/principals.d/cy.conf")" 'OIDC_LOGIN="issuer-a:SUB-9 issuer-b:SUB-9"'
has "the display email is written" "$(cat "$ROOT/principals.d/cy.conf")" 'OIDC_EMAIL="cy@example.test"'

out="$(bash "$S" registry principal add dee --name Dee 2>&1)"; rc=$?
is  "no identity at all is rc 64" "$rc" "64"
has "and says what is missing" "$out" "identity"

out="$(bash "$S" registry principal add ell --name Ell --oidc-login 'no-colon' 2>&1)"; rc=$?
is  "a malformed oidc word is rc 64" "$rc" "64"
is  "and nothing was written" "$(ls "$ROOT/principals.d" | grep -c ell)" "0"

out="$(bash "$S" registry principal add twin --name Twin --oidc-login issuer-a:SUB-1 2>&1)"; rc=$?
is  "a duplicate oidc identity is refused before the write" "$rc" "65"
has "and names the other principal" "$out" "alice"
is  "and nothing was written" "$(ls "$ROOT/principals.d" | grep -c twin)" "0"

out="$(bash "$S" registry principal add dedupe --name Dedupe \
        --oidc-login issuer-a:SUB-7 --oidc-login issuer-a:SUB-7 2>&1)"; rc=$?
is  "a word repeated within the row is de-duplicated" "$rc" "0"
has "and written once" "$(cat "$ROOT/principals.d/dedupe.conf")" 'OIDC_LOGIN="issuer-a:SUB-7"'

echo "== the ATOMIC gate: uniqueness is re-asked UNDER the register's write lock =="
_DUP='NAME="Raced"
OIDC_LOGIN="issuer-b:SUB-9"'
_rc=0
( export STEWARD_ESTATE_ROOT="$ROOT" STEWARD_CONFIG_FILE="$T/no-such-config"
  . "$here/lib/registry.sh"
  eval "$(sed -n '/^_principal_validate_row()/,/^}/p' "$here/bin/steward")"
  export _REGW_EXPECT_NAME="Raced" _REGW_EXPECT_TAILSCALE_LOGIN="" \
         _REGW_EXPECT_OIDC_LOGIN="issuer-b:SUB-9" _REGW_EXPECT_OIDC_EMAIL="" \
         _REGW_EXPECT_DESK_READ_ALL=""
  registry_principal_write raced "$_DUP" _principal_validate_row ) >/dev/null 2>&1 || _rc=$?
is  "the under-lock validator refuses a colliding oidc word" \
    "$( [ "$_rc" -ne 0 ] && echo refused || echo passed )" "refused"
if [ -e "$ROOT/principals.d/raced.conf" ]; then
  bad "no colliding row must be published" "found $ROOT/principals.d/raced.conf"
else
  ok "no colliding row published"
fi

out="$(bash "$S" registry principal add jay --name Jay --oidc-login issuer-a:SUB-J \
        --oidc-email jay@example.test --json 2>&1)"; rc=$?
is  "the json receipt is written too" "$rc" "0"
has "and reports the oidc identity" "$out" '"oidcLogin":"issuer-a:SUB-J"'
has "and the display email" "$out" '"oidcEmail":"jay@example.test"'

# THE LEAK GUARD: the validator sources the staged row, so every field the row
# can carry must be `local` in it. A field left out is published into the
# CALLER's shell by the first row that carries it.
_leak="$( export STEWARD_ESTATE_ROOT="$ROOT" STEWARD_CONFIG_FILE="$T/no-such-config"
  . "$here/lib/registry.sh"
  eval "$(sed -n '/^_principal_validate_row()/,/^}/p' "$here/bin/steward")"
  printf 'NAME="Leak"\nOIDC_LOGIN="issuer-a:SUB-L"\nOIDC_EMAIL="leak@example.test"\n' > "$T/leak.conf"
  _REGW_EXPECT_NAME="Leak" _REGW_EXPECT_TAILSCALE_LOGIN="" \
    _REGW_EXPECT_OIDC_LOGIN="issuer-a:SUB-L" _REGW_EXPECT_OIDC_EMAIL="leak@example.test" \
    _REGW_EXPECT_DESK_READ_ALL="" _principal_validate_row "$T/leak.conf" >/dev/null 2>&1
  printf '%s|%s' "${OIDC_LOGIN:-unset}" "${OIDC_EMAIL:-unset}" )"
is  "the validator leaks neither oidc field into its caller" "$_leak" "unset|unset"

printf '\n  %d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
