#!/bin/bash
# test/invite-registry.test.sh - invites.d: the operator's word, recorded
# before the person exists. The row holds a DIGEST, never a token, so a
# readable register is not an open door - and expiry is computed on every read
# rather than written, so a row nobody looked at is not silently still valid.
set -u
here="$(CDPATH= cd -- "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
pass=0; fail=0
ok()  { pass=$((pass+1)); printf '  ok   %s\n' "$1"; }
bad() { fail=$((fail+1)); printf '  FAIL %s\n     %s\n' "$1" "${2:-}"; }
is()  { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "wanted '$3', got '$2'"; fi; }
has() { case "$2" in *"$3"*) ok "$1" ;; *) bad "$1" "missing '$3' in: $2" ;; esac; }
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
ROOT="$T/estate"; mkdir -p "$ROOT/invites.d" "$ROOT/estate"
printf 'ESTATE_NAME="fixture"\n' > "$ROOT/estate/steward.conf"
export STEWARD_ESTATE_ROOT="$ROOT" STEWARD_CONFIG_FILE="$T/no-such-config"
. "$here/lib/registry.sh"
echo "invite-registry"

NOW="$(date -u +%s)"
FUTURE=$((NOW + 86400))
PAST=$((NOW - 86400))

write_row() { # <id> <state> <expires> <digest>
  local id="$1" state="$2" exp="$3" digest="$4"
  {
    printf 'NAME="Alice Example"\n'
    printf 'PRINCIPAL="alice"\n'
    printf 'ENTITY="acme"\n'
    printf 'HOST="host-a"\n'
    printf 'RUNTIME="claude-code"\n'
    printf 'PROVIDER="claude-max"\n'
    printf 'TOKEN_SHA256="%s"\n' "$digest"
    printf 'ISSUED_BY="operator"\n'
    printf 'ISSUED_AT="%s"\n' "$NOW"
    printf 'EXPIRES_AT="%s"\n' "$exp"
    printf 'STATE="%s"\n' "$state"
  } > "$ROOT/invites.d/$id.conf"
  chmod 600 "$ROOT/invites.d/$id.conf"
}
D1="$(printf 'token-one' | _registry_sha256)"
D2="$(printf 'token-two' | _registry_sha256)"
write_row inv-0000000a open "$FUTURE" "$D1"
write_row inv-0000000b open "$PAST"   "$D2"

registry_invite_load inv-0000000a; rc=$?
is  "a valid row loads" "$rc" "0"
is  "and exposes the principal" "$INVITE_PRINCIPAL" "alice"
is  "and the entity" "$INVITE_ENTITY" "acme"
is  "and the host" "$INVITE_HOST" "host-a"
is  "and the runtime" "$INVITE_RUNTIME" "claude-code"
is  "and the digest" "$INVITE_TOKEN_SHA256" "$D1"
is  "and the state" "$INVITE_STATE" "open"
is  "and the effective state" "$INVITE_EFFECTIVE_STATE" "open"
is  "and no redemption yet" "$INVITE_REDEEMED_LOGIN" ""

registry_invite_load inv-0000000b
is  "a past expiry reads as expired" "$INVITE_EFFECTIVE_STATE" "expired"
is  "without rewriting the stored state" "$INVITE_STATE" "open"
has "and the row on disk still says open" "$(cat "$ROOT/invites.d/inv-0000000b.conf")" 'STATE="open"'

registry_invite_load inv-nosuch 2>"$T/err"; rc=$?
is  "a missing row is rc 1" "$rc" "1"
is  "a refused load leaves nothing behind" "$INVITE_PRINCIPAL" ""

printf 'NAME="X"\nPRINCIPAL="alice"\n' > "$ROOT/invites.d/inv-0000000c.conf"
chmod 600 "$ROOT/invites.d/inv-0000000c.conf"
registry_invite_load inv-0000000c 2>"$T/err"; rc=$?
is  "a row missing required keys is rc 1" "$rc" "1"
has "and names a missing key" "$(cat "$T/err")" "missing required key"
rm -f "$ROOT/invites.d/inv-0000000c.conf"

printf 'PRINCIPAL="alice"\nSTATE="open"\nWHATEVER="x"\n' > "$ROOT/invites.d/inv-0000000d.conf"
chmod 600 "$ROOT/invites.d/inv-0000000d.conf"
registry_invite_load inv-0000000d 2>"$T/err"; rc=$?
is  "an unknown key is rc 1" "$rc" "1"
has "and names it" "$(cat "$T/err")" "WHATEVER"
rm -f "$ROOT/invites.d/inv-0000000d.conf"

write_row inv-0000000e nonsense "$FUTURE" "$D1"
registry_invite_load inv-0000000e 2>"$T/err"; rc=$?
is  "an unknown STATE is rc 1" "$rc" "1"
has "and names the vocabulary" "$(cat "$T/err")" "open"
rm -f "$ROOT/invites.d/inv-0000000e.conf"

# THE ROW IS NEVER SOURCED. A command substitution in a value must land in the
# value, not in a shell.
rm -f "$T/DETONATED"
printf 'NAME="X"\nPRINCIPAL="alice"\nENTITY="acme"\nHOST="host-a"\nRUNTIME="claude-code"\nPROVIDER="claude-max"\nTOKEN_SHA256="%s"\nISSUED_BY="operator"\nISSUED_AT="%s"\nEXPIRES_AT="%s"\nSTATE="open"\n' \
  '$(touch '"$T"'/DETONATED)' "$NOW" "$FUTURE" > "$ROOT/invites.d/inv-0000000f.conf"
chmod 600 "$ROOT/invites.d/inv-0000000f.conf"
registry_invite_load inv-0000000f >/dev/null 2>&1; rc=$?
is  "a substitution in a value is refused" "$rc" "1"
if [ -e "$T/DETONATED" ]; then bad "the payload must never run" "found $T/DETONATED"; else ok "the payload never ran"; fi
rm -f "$ROOT/invites.d/inv-0000000f.conf"

echo "== lookups =="
is  "the digest lookup finds the row" "$(registry_invite_for_digest "$D1")" "inv-0000000a"
registry_invite_for_digest "$(printf 'nothing' | _registry_sha256)" >/dev/null 2>&1; rc=$?
is  "an unknown digest is rc 1" "$rc" "1"
is  "the open-invite lookup finds the row" "$(registry_invite_open_for_principal alice)" "inv-0000000a"
registry_invite_open_for_principal nobody >/dev/null 2>&1; rc=$?
is  "no open invite is rc 1" "$rc" "1"
is  "the listing names both rows" "$(registry_invite_list | tr '\n' ' ')" "inv-0000000a inv-0000000b "

echo "== minting =="
tok="$(registry_invite_mint_token)"; rc=$?
is  "minting a token succeeds" "$rc" "0"
case "$tok" in
  *[!A-Za-z0-9_-]*) bad "a token is base64url only" "got '$tok'" ;;
  *) ok "a token is base64url only" ;;
esac
if [ "${#tok}" -ge 43 ]; then ok "a token is at least 43 characters (32 bytes)"; else bad "a token is at least 43 characters" "got ${#tok}"; fi
tok2="$(registry_invite_mint_token)"
if [ "$tok" != "$tok2" ]; then ok "two tokens differ"; else bad "two tokens differ" "both '$tok'"; fi
id="$(registry_invite_mint_id)"
case "$id" in
  inv-[0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f]) ok "a minted id is inv- plus 8 hex" ;;
  *) bad "a minted id is inv- plus 8 hex" "got '$id'" ;;
esac

echo "== the writer and the in-place replace =="
_invite_ok() { return 0; }
content="$(cat "$ROOT/invites.d/inv-0000000a.conf")"
registry_invite_write inv-00000010 "$content
" _invite_ok; rc=$?
is  "the writer publishes a row" "$rc" "0"
registry_invite_load inv-00000010
is  "and it loads back" "$INVITE_PRINCIPAL" "alice"
registry_invite_write inv-00000010 "$content
" _invite_ok 2>/dev/null; rc=$?
is  "writing over an existing row is rc 65" "$rc" "65"
registry_invite_replace inv-00000010 "$(printf '%s\n' "$content" | sed 's/^STATE=.*/STATE="revoked"/')
" _invite_ok; rc=$?
is  "the replace succeeds" "$rc" "0"
registry_invite_load inv-00000010
is  "and the state moved" "$INVITE_EFFECTIVE_STATE" "revoked"

printf '\n  %d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
