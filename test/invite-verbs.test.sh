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

# ---------------------------------------------------------------------------
# The fixture above ends with one open invitation, so everything below builds
# its OWN estate: a register whose contents are a side effect of an earlier
# check is a register the next reader has to reason about.
mkroot() { # <dir> - a complete fixture estate, two hosts, one account
  local r="$1"
  mkdir -p "$r/invites.d" "$r/entities.d" "$r/hosts.d" "$r/principals.d" \
           "$r/accounts.d" "$r/estate"
  printf 'ESTATE_NAME="fixture"\nDESK_ORIGIN="https://desk.example.test"\n' > "$r/estate/steward.conf"
  printf 'NAME="Acme"\nMEMBERS="operator"\n' > "$r/entities.d/acme.conf"
  printf 'OWNER="operator"\nLEGAL_OWNER="Acme Ltd"\nOPERATOR="operator"\n' > "$r/hosts.d/host-a.conf"
  printf 'OWNER="operator"\nLEGAL_OWNER="Acme Ltd"\nOPERATOR="operator"\n' > "$r/hosts.d/host-b.conf"
  printf 'NAME="Operator"\nTAILSCALE_LOGIN="login-op@example.test"\n' > "$r/principals.d/operator.conf"
  printf 'PRINCIPAL="operator"\nHOST="host-a"\nUSERNAME="%s"\n' "$(id -un)" > "$r/accounts.d/operator-host-a.conf"
}

echo "the token never reaches a child process's argv"
# jq is the only child process an --json issue hands the link to, and argv is
# world-readable on the hosts this register exists for (/proc/<pid>/cmdline).
# The shim records what jq was actually called with.
R2="$T/estate2"; mkroot "$R2"
SHIM="$T/shim"; mkdir -p "$SHIM"
JQ_REAL="$(command -v jq)"
printf '#!/bin/bash\nprintf "%%s\\n" "$*" >> "%s/jq-argv.log"\nexec "%s" "$@"\n' "$T" "$JQ_REAL" > "$SHIM/jq"
chmod +x "$SHIM/jq"
: > "$T/jq-argv.log"
jout="$(STEWARD_ESTATE_ROOT="$R2" PATH="$SHIM:$PATH" bash "$S" \
        invite issue --name "Dee Example" --principal dee --entity acme --host host-a --json 2>"$T/dee.err")"; rc=$?
is  "issue --json succeeds" "$rc" "0"
is  "and reports ok" "$(printf '%s' "$jout" | jq -r '.ok' 2>/dev/null)" "true"
is  "and kind invite" "$(printf '%s' "$jout" | jq -r '.kind' 2>/dev/null)" "invite"
is  "and the principal" "$(printf '%s' "$jout" | jq -r '.principal' 2>/dev/null)" "dee"
is  "and an inv- id" "$(printf '%s' "$jout" | jq -r '.id' 2>/dev/null | cut -c1-4)" "inv-"
jlink="$(printf '%s' "$jout" | jq -r '.link' 2>/dev/null)"
jtoken="${jlink##*/}"
if [ "${#jtoken}" -ge 43 ]; then ok "and a link carrying a full token"; else bad "and a link carrying a full token" "got '$jtoken'"; fi
no  "the token is absent from every jq argv" "$(cat "$T/jq-argv.log")" "$jtoken"
is  "the token appears exactly once across stdout and stderr" \
    "$(printf '%s\n' "$jout" "$(cat "$T/dee.err")" | grep -cF -- "$jtoken")" "1"
is  "and nowhere under invites.d" \
    "$(grep -rlF -- "$jtoken" "$R2/invites.d" 2>/dev/null | wc -l | tr -d ' ')" "0"

echo "the issuer is measured, or the verb refuses"
out="$(STEWARD_ESTATE_ROOT="$R2" bash "$S" invite issue --name "Eve Example" --principal eve \
       --entity acme --host host-a --issued-by deputy 2>&1)"; rc=$?
is  "--issued-by is honoured" "$rc" "0"
erow="$(grep -l 'PRINCIPAL="eve"' "$R2"/invites.d/*.conf | head -1)"
has "and is the row's ISSUED_BY" "$(cat "$erow")" 'ISSUED_BY="deputy"'

R3="$T/estate3"; mkroot "$R3"; rm -f "$R3"/accounts.d/*.conf
out="$(STEWARD_ESTATE_ROOT="$R3" bash "$S" invite issue --name "Fay Example" --principal fay \
       --entity acme --host host-a 2>&1)"; rc=$?
is  "an unresolvable issuer is rc 65" "$rc" "65"
has "and names --issued-by" "$out" "--issued-by"
is  "and wrote no row" "$(ls "$R3/invites.d" | wc -l | tr -d ' ')" "0"

# Two accounts for one unix username on two hosts: the alphabetically first
# row is NOT the answer - this machine's host row is.
R7="$T/estate7"; mkroot "$R7"
printf 'NAME="Aardvark"\nTAILSCALE_LOGIN="login-aa@example.test"\n' > "$R7/principals.d/aardvark.conf"
printf 'PRINCIPAL="aardvark"\nHOST="host-b"\nUSERNAME="%s"\n' "$(id -un)" > "$R7/accounts.d/aardvark-host-b.conf"
out="$(STEWARD_ESTATE_ROOT="$R7" STEWARD_SELF_HOST="host-a" bash "$S" invite issue \
       --name "Ivy Example" --principal ivy --entity acme --host host-a 2>&1)"; rc=$?
is  "two accounts, one unix user: issuing on host-a succeeds" "$rc" "0"
irow="$(grep -l 'PRINCIPAL="ivy"' "$R7"/invites.d/*.conf | head -1)"
has "and the issuer is this host's principal, not the first row's" "$(cat "$irow")" 'ISSUED_BY="operator"'
out="$(STEWARD_ESTATE_ROOT="$R7" STEWARD_SELF_HOST="host-z" bash "$S" invite issue \
       --name "Jay Example" --principal jay --entity acme --host host-a 2>&1)"; rc=$?
is  "and an issuer this machine cannot separate is rc 65" "$rc" "65"
has "naming the first candidate" "$out" "operator"
has "and the second" "$out" "aardvark"
has "and --issued-by" "$out" "--issued-by"
is  "and the register still holds only ivy's row" "$(ls "$R7/invites.d" | wc -l | tr -d ' ')" "1"

echo "a refusal keeps its shape when the caller asked for json"
R4="$T/estate4"; mkroot "$R4"
printf 'ESTATE_NAME="fixture"\n' > "$R4/estate/steward.conf"
out="$(STEWARD_ESTATE_ROOT="$R4" bash "$S" invite issue --name "Gus Example" --principal gus \
       --entity acme --host host-a --json 2>/dev/null)"; rc=$?
is  "a missing DESK_ORIGIN is rc 78" "$rc" "78"
is  "and --json still gets an object" "$(printf '%s' "$out" | jq -r '.ok' 2>/dev/null)" "false"
has "whose reason names DESK_ORIGIN" "$(printf '%s' "$out" | jq -r '.reason' 2>/dev/null)" "DESK_ORIGIN"
is  "and no row was written" "$(ls "$R4/invites.d" | wc -l | tr -d ' ')" "0"

R5="$T/estate5"; mkroot "$R5"; rmdir "$R5/invites.d"
out="$(STEWARD_ESTATE_ROOT="$R5" bash "$S" invite ls --json 2>/dev/null)"; rc=$?
is  "ls without a register is rc 78" "$rc" "78"
is  "and --json gets an object there too" "$(printf '%s' "$out" | jq -r '.ok' 2>/dev/null)" "false"

echo "a row the reader refuses is reported, never dropped"
R8="$T/estate8"; mkroot "$R8"
STEWARD_ESTATE_ROOT="$R8" bash "$S" invite issue --name "Kim Example" --principal kim \
  --entity acme --host host-a >/dev/null 2>&1
printf 'NAME="Broken"\n' > "$R8/invites.d/inv-deadbeef.conf"
chmod 600 "$R8/invites.d/inv-deadbeef.conf"
lo="$(STEWARD_ESTATE_ROOT="$R8" bash "$S" invite ls 2>"$T/ls8.err")"; rc=$?
is  "ls over a malformed row is rc 78" "$rc" "78"
has "and still lists the good row" "$lo" "kim"
has "and names the malformed one on stderr" "$(cat "$T/ls8.err")" "inv-deadbeef"
lj="$(STEWARD_ESTATE_ROOT="$R8" bash "$S" invite ls --json 2>"$T/ls8j.err")"; rc=$?
is  "ls --json over a malformed row is rc 78" "$rc" "78"
is  "and its array still carries the good row" "$(printf '%s' "$lj" | jq -r '.[0].principal' 2>/dev/null)" "kim"
has "and names the malformed one on stderr" "$(cat "$T/ls8j.err")" "inv-deadbeef"

echo "revoke refuses a redeemed row, and a row that moved under it"
R6="$T/estate6"; mkroot "$R6"
DIG="$(printf 'not-the-token' | { if command -v sha256sum >/dev/null 2>&1; then sha256sum; else shasum -a 256; fi; } | cut -d' ' -f1)"
redeemed_row() { # <path>
  printf 'NAME="Hal Example"\nPRINCIPAL="hal"\nENTITY="acme"\nHOST="host-a"\n' > "$1"
  printf 'RUNTIME="claude-code"\nPROVIDER="claude-max"\nTOKEN_SHA256="%s"\n' "$DIG" >> "$1"
  printf 'ISSUED_BY="operator"\nISSUED_AT="1700000000"\nEXPIRES_AT="4102444800"\n' >> "$1"
  printf 'STATE="redeemed"\nREDEEMED_LOGIN="hal-host-a"\nREDEEMED_AT="1700000100"\n' >> "$1"
  chmod 600 "$1"
}
redeemed_row "$R6/invites.d/inv-0000beef.conf"
out="$(STEWARD_ESTATE_ROOT="$R6" bash "$S" invite revoke inv-0000beef --json 2>/dev/null)"; rc=$?
is  "revoking a redeemed invitation is rc 65" "$rc" "65"
is  "and --json says so" "$(printf '%s' "$out" | jq -r '.ok' 2>/dev/null)" "false"
has "and the row is untouched" "$(cat "$R6/invites.d/inv-0000beef.conf")" 'STATE="redeemed"'

# THE READ HAPPENS OUTSIDE THE WRITE LOCK, so a redemption can land between it
# and the publish. The shim below is that redemption: `rm` is first called from
# _invite_compose, which is after revoke has read the row and before the lock
# is taken, so the row on disk moves to redeemed inside exactly that window.
R9="$T/estate9"; mkroot "$R9"
STEWARD_ESTATE_ROOT="$R9" bash "$S" invite issue --name "Lee Example" --principal lee \
  --entity acme --host host-a >/dev/null 2>&1
R9ID="$(ls "$R9/invites.d" | sed 's/\.conf$//' | head -1)"
RACE="$T/race"; mkdir -p "$RACE"
RM_REAL="$(command -v rm)"
cat > "$RACE/rm" <<RACESHIM
#!/bin/bash
if [ ! -e "$T/race.fired" ]; then
  : > "$T/race.fired"
  printf 'NAME="Lee Example"\nPRINCIPAL="lee"\nENTITY="acme"\nHOST="host-a"\n' > "$R9/invites.d/$R9ID.conf"
  printf 'RUNTIME="claude-code"\nPROVIDER="claude-max"\nTOKEN_SHA256="$DIG"\n' >> "$R9/invites.d/$R9ID.conf"
  printf 'ISSUED_BY="operator"\nISSUED_AT="1700000000"\nEXPIRES_AT="4102444800"\n' >> "$R9/invites.d/$R9ID.conf"
  printf 'STATE="redeemed"\nREDEEMED_LOGIN="lee-host-a"\nREDEEMED_AT="1700000100"\n' >> "$R9/invites.d/$R9ID.conf"
  chmod 600 "$R9/invites.d/$R9ID.conf"
fi
exec "$RM_REAL" "\$@"
RACESHIM
chmod +x "$RACE/rm"
out="$(STEWARD_ESTATE_ROOT="$R9" PATH="$RACE:$PATH" bash "$S" invite revoke "$R9ID" 2>&1)"; rc=$?
if [ -e "$T/race.fired" ]; then ok "the redemption landed inside the window"; else bad "the redemption landed inside the window" "the shim never fired"; fi
if [ "$rc" -ne 0 ]; then ok "a row that moved under the revoke is refused"; else bad "a row that moved under the revoke is refused" "wanted a non-zero rc, got 0"; fi
has "and the redemption survives" "$(cat "$R9/invites.d/$R9ID.conf")" 'STATE="redeemed"'
has "with its login intact" "$(cat "$R9/invites.d/$R9ID.conf")" 'REDEEMED_LOGIN="lee-host-a"'

printf '\n  %d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
