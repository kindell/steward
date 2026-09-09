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
# 0700, PINNED. The login and invite readers refuse a group- or other-writable
# register, so under the Debian default umask of 002 a fixture that lets `mkdir`
# pick the mode measures the HOST, not the product. See test/register-modes.test.sh.
chmod 700 "$ROOT/invites.d"
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

# THE ID SHAPE AND THE ABSENT ROW ARE TWO DIFFERENT REFUSALS. 'inv-nosuch'
# above never reaches the file test at all - it dies on the shape - so the
# "no such invite" branch needs an id the shape check accepts.
registry_invite_load inv-00000099 2>"$T/err"; rc=$?
is  "a well-shaped id with no row is rc 1" "$rc" "1"
has "and says which invite is missing" "$(cat "$T/err")" "no such invite"

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

# AN EPOCH FIELD LONGER THAN AN INTEGER IS A REFUSAL, NOT A WARNING. A digit
# string of 23 characters passes a bare "all digits" test and then breaks the
# arithmetic comparison that measures expiry - which would print to stderr
# while the loader returned 0 and the row read as open.
write_row inv-00000011 open "99999999999999999999999" "$D1"
registry_invite_load inv-00000011 2>"$T/err"; rc=$?
is  "an EXPIRES_AT wider than an integer is rc 1" "$rc" "1"
has "and names the field" "$(cat "$T/err")" "EXPIRES_AT must be epoch seconds"
case "$(cat "$T/err")" in
  *"integer expression"*) bad "and the shell's own arithmetic error never leaks" "$(cat "$T/err")" ;;
  *) ok "and the shell's own arithmetic error never leaks" ;;
esac
rm -f "$ROOT/invites.d/inv-00000011.conf"

# REDEEMED_LOGIN NAMES A ROW IN THE LOGIN REGISTER, so it carries that
# register's own slug shape. Empty stays legal - an invitation nobody has
# redeemed yet has nothing to name.
write_row inv-00000012 open "$FUTURE" "$D1"
printf 'REDEEMED_LOGIN="../../etc/passwd oops"\n' >> "$ROOT/invites.d/inv-00000012.conf"
registry_invite_load inv-00000012 2>"$T/err"; rc=$?
is  "a REDEEMED_LOGIN that is not a login slug is rc 1" "$rc" "1"
has "and names the key" "$(cat "$T/err")" "REDEEMED_LOGIN"
write_row inv-00000012 open "$FUTURE" "$D1"
printf 'REDEEMED_LOGIN="login-a"\n' >> "$ROOT/invites.d/inv-00000012.conf"
registry_invite_load inv-00000012 2>"$T/err"; rc=$?
is  "a well-shaped REDEEMED_LOGIN loads" "$rc" "0"
is  "and is exposed" "$INVITE_REDEEMED_LOGIN" "login-a"
rm -f "$ROOT/invites.d/inv-00000012.conf"

# THE REGISTER DIRECTORY'S OWN STATE COMES BEFORE THE ROW'S. A mode-600 row
# inside a directory anybody can write to is not protected by its mode: the row
# can be renamed away and replaced, and the new file's mode check passes.
dir_mode="$(_registry_mode_of "$ROOT/invites.d")"
chmod 777 "$ROOT/invites.d"
registry_invite_load inv-0000000a 2>"$T/err"; rc=$?
is  "a world-writable register is rc 78" "$rc" "78"
has "and names the directory" "$(cat "$T/err")" "$ROOT/invites.d"
is  "and leaves nothing behind" "$INVITE_PRINCIPAL" ""
chmod "$dir_mode" "$ROOT/invites.d"
registry_invite_load inv-0000000a; rc=$?
is  "and the restored register loads again" "$rc" "0"

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

# THE WRITERS GUARD THE INVITE ID THEMSELVES. The row primitive underneath
# accepts any register slug, so an id like 'bad' would publish a file and only
# then fail the readback - a refusal after the write is not a refusal.
registry_invite_write bad "$content
" _invite_ok 2>"$T/err"; rc=$?
is  "the writer refuses an id that is not an invite id" "$rc" "64"
if [ -e "$ROOT/invites.d/bad.conf" ]; then bad "and writes no file" "found $ROOT/invites.d/bad.conf"; else ok "and writes no file"; fi
registry_invite_replace bad "$content
" _invite_ok 2>"$T/err"; rc=$?
is  "the replace refuses it too" "$rc" "64"

printf '\n  %d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
