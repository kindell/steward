#!/bin/bash
# test/invite-verbs.test.sh - the operator's three verbs. The token is printed
# ONCE and stored never; the listing cannot leak what the register does not
# hold; and every refusal happens before a row exists.
set -u
here="$(CDPATH= cd -- "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
pass=0; fail=0
ok()  { pass=$((pass+1)); printf '  ok   %s\n' "$1"; }
bad() { fail=$((fail+1)); printf '  FAIL %s\n     %s\n' "$1" "${2:-}"; }
is()  { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "wanted '$3', got '$2'"; fi; }
has() { case "$2" in *"$3"*) ok "$1" ;; *) bad "$1" "missing '$3' in: $2" ;; esac; }
no()  { case "$2" in *"$3"*) bad "$1" "found '$3' in: $2" ;; *) ok "$1" ;; esac; }
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
ROOT="$T/estate"
mkdir -p "$ROOT/invites.d" "$ROOT/entities.d" "$ROOT/hosts.d" "$ROOT/principals.d" \
         "$ROOT/accounts.d" "$ROOT/estate"
printf 'ESTATE_NAME="fixture"\nDESK_ORIGIN="https://desk.example.test"\n' > "$ROOT/estate/steward.conf"
printf 'NAME="Acme"\nMEMBERS="operator"\n' > "$ROOT/entities.d/acme.conf"
printf 'OWNER="operator"\nLEGAL_OWNER="Acme Ltd"\nOPERATOR="operator"\n' > "$ROOT/hosts.d/host-a.conf"
printf 'NAME="Operator"\nTAILSCALE_LOGIN="login-op@example.test"\n' > "$ROOT/principals.d/operator.conf"
printf 'PRINCIPAL="operator"\nHOST="host-a"\nUSERNAME="%s"\n' "$(id -un)" > "$ROOT/accounts.d/operator-host-a.conf"
export STEWARD_ESTATE_ROOT="$ROOT" STEWARD_CONFIG_FILE="$T/no-such-config"
S="$here/bin/steward"
echo "invite-verbs"

out="$(bash "$S" invite issue --name "Alice Example" --principal alice --entity acme --host host-a 2>&1)"; rc=$?
is  "issue succeeds" "$rc" "0"
has "and prints a link on the estate's origin" "$out" "https://desk.example.test/desk/invite/"
link="$(printf '%s\n' "$out" | grep -o 'https://desk.example.test/desk/invite/[A-Za-z0-9_-]*' | head -1)"
token="${link##*/}"
if [ "${#token}" -ge 43 ]; then ok "the link carries a full token"; else bad "the link carries a full token" "got '${token}'"; fi

id="$(ls "$ROOT/invites.d" | sed 's/\.conf$//' | head -1)"
row="$(cat "$ROOT/invites.d/$id.conf")"
no  "the row does not hold the token" "$row" "$token"
has "the row holds the digest" "$row" "TOKEN_SHA256=\"$(printf '%s' "$token" | { if command -v sha256sum >/dev/null 2>&1; then sha256sum; else shasum -a 256; fi; } | cut -d' ' -f1)\""
has "the row names the principal" "$row" 'PRINCIPAL="alice"'
has "the row defaults the runtime" "$row" 'RUNTIME="claude-code"'
has "the row defaults the provider" "$row" 'PROVIDER="claude-max"'
has "the row names the issuer" "$row" 'ISSUED_BY="operator"'
has "the row is open" "$row" 'STATE="open"'
is  "the row is mode 600" \
    "$(stat -c %a "$ROOT/invites.d/$id.conf" 2>/dev/null || stat -f %Lp "$ROOT/invites.d/$id.conf")" "600"

lsout="$(bash "$S" invite ls 2>&1)"; rc=$?
is  "ls succeeds" "$rc" "0"
has "and names the invitation" "$lsout" "$id"
has "and its state" "$lsout" "open"
no  "and never a token" "$lsout" "$token"

jsonout="$(bash "$S" invite ls --json 2>&1)"
is  "ls --json is valid json" "$(printf '%s' "$jsonout" | jq -e 'type=="array"' >/dev/null 2>&1 && echo yes)" "yes"
is  "and carries the row" "$(printf '%s' "$jsonout" | jq -r '.[0].principal')" "alice"
no  "and no token field" "$jsonout" "$token"

out="$(bash "$S" invite issue --name "Alice Again" --principal alice --entity acme --host host-a 2>&1)"; rc=$?
is  "a second open invite for the same principal is rc 65" "$rc" "65"
has "and names the existing invitation" "$out" "$id"

printf 'NAME="Bo"\nTAILSCALE_LOGIN="login-b@example.test"\n' > "$ROOT/principals.d/bo.conf"
out="$(bash "$S" invite issue --name "Bo" --principal bo --entity acme --host host-a 2>&1)"; rc=$?
is  "inviting an existing principal is rc 65" "$rc" "65"
has "and says why" "$out" "already"

out="$(bash "$S" invite issue --name "Cy" --principal cy --entity nosuch --host host-a 2>&1)"; rc=$?
is  "an unknown entity is rc 65" "$rc" "65"
out="$(bash "$S" invite issue --name "Cy" --principal cy --entity acme --host nosuch 2>&1)"; rc=$?
is  "an unknown host is rc 65" "$rc" "65"
out="$(bash "$S" invite issue --name "Cy" --principal cy --entity acme --host host-a --runtime nonsense 2>&1)"; rc=$?
is  "an unknown runtime is rc 64" "$rc" "64"
out="$(bash "$S" invite issue --name "Cy" --principal cy --entity acme --host host-a --provider nonsense 2>&1)"; rc=$?
is  "an unknown provider is rc 64" "$rc" "64"
out="$(bash "$S" invite issue --name "Cy" --principal cy --entity acme --host host-a --days 0 2>&1)"; rc=$?
is  "zero days is rc 64" "$rc" "64"
is  "and none of those wrote a row" "$(ls "$ROOT/invites.d" | wc -l | tr -d ' ')" "1"

out="$(bash "$S" invite revoke "$id" 2>&1)"; rc=$?
is  "revoke succeeds" "$rc" "0"
has "and the row moved" "$(cat "$ROOT/invites.d/$id.conf")" 'STATE="revoked"'
out="$(bash "$S" invite revoke "$id" 2>&1)"; rc=$?
is  "revoking twice is a no-op, rc 0" "$rc" "0"
out="$(bash "$S" invite revoke inv-00000099 2>&1)"; rc=$?
is  "revoking a row that does not exist is rc 78" "$rc" "78"
out="$(bash "$S" invite revoke nonsense 2>&1)"; rc=$?
is  "a malformed id is rc 64" "$rc" "64"

# A revoked invitation frees the principal for a new one.
out="$(bash "$S" invite issue --name "Alice Example" --principal alice --entity acme --host host-a 2>&1)"; rc=$?
is  "a fresh invitation after a revoke succeeds" "$rc" "0"

printf '\n  %d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
