#!/bin/bash
# test/offboard.test.sh - the exact reverse of a redemption, and the receipt
# that makes a rehearsal cleanable. Nothing here locks a real account: the
# helper is reached through a sudo shim that records its argv, and every home
# is a directory under the fixture.
set -u
here="$(CDPATH= cd -- "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
pass=0; fail=0
ok()  { pass=$((pass+1)); printf '  ok   %s\n' "$1"; }
bad() { fail=$((fail+1)); printf '  FAIL %s\n     %s\n' "$1" "${2:-}"; }
is()  { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "wanted '$3', got '$2'"; fi; }
has() { case "$2" in *"$3"*) ok "$1" ;; *) bad "$1" "missing '$3' in: $2" ;; esac; }
no()  { case "$2" in *"$3"*) bad "$1" "found '$3' in: $2" ;; *) ok "$1" ;; esac; }
have()    { if [ -e "$2" ]; then ok "$1"; else bad "$1" "missing $2"; fi; }
havenot() { if [ -e "$2" ]; then bad "$1" "still there: $2"; else ok "$1"; fi; }
modeof()  { stat -c %a "$1" 2>/dev/null || stat -f %Lp "$1"; }
FX="$(mktemp -d)"; trap 'rm -rf "$FX"' EXIT
echo "offboard"

# -- the product tree -------------------------------------------------------
# THE FIXTURE CARRIES ITS OWN PRODUCT TREE, the technique
# test/invite-redeem.test.sh uses: bin/steward resolves its own root, so the
# copy under the fixture is what runs and its desk/snapshot.sh is a stub that
# records instead of acting.
mkdir -p "$FX/product/bin" "$FX/product/lib" "$FX/product/desk"
cp "$here/bin/steward" "$FX/product/bin/steward"
cp "$here/lib/registry.sh" "$FX/product/lib/registry.sh"
chmod 755 "$FX/product/bin/steward"
cat > "$FX/product/desk/snapshot.sh" <<EOF
#!/bin/bash
echo "snapshot \$*" >> "$FX/calls"
# FX_SNAPSHOT_RC is the fixture's own knob - nothing in the product reads it.
exit "\${FX_SNAPSHOT_RC:-0}"
EOF
chmod 755 "$FX/product/desk/snapshot.sh"
S="$FX/product/bin/steward"

# -- the estate -------------------------------------------------------------
ROOT="$FX/estate"
mkdir -p "$ROOT/invites.d" "$ROOT/entities.d" "$ROOT/hosts.d" "$ROOT/principals.d" \
         "$ROOT/accounts.d" "$ROOT/logins.d" "$ROOT/sessions.d" "$ROOT/estate"
cat > "$ROOT/estate/steward.conf" <<'EOF'
ESTATE_NAME="acme"
STATE_DIR_NAME="fixture-state"
HUB_SESSION="host-a"
HUB_HOST="host-a"
HUB_SSH="steward@host-a"
EOF
printf 'NAME="Acme"\nMEMBERS="operator alice"\n' > "$ROOT/entities.d/acme.conf"
printf 'OWNER="operator"\nLEGAL_OWNER="Acme Ltd"\nOPERATOR="operator"\n' > "$ROOT/hosts.d/host-a.conf"
printf 'OWNER="operator"\nLEGAL_OWNER="Acme Ltd"\nOPERATOR="operator"\n' > "$ROOT/hosts.d/host-b.conf"
printf 'NAME="Alice"\nOIDC_LOGIN="issuer-a:SUB-1"\n' > "$ROOT/principals.d/alice.conf"
printf 'NAME="Operator"\nTAILSCALE_LOGIN="login-op@example.test"\n' > "$ROOT/principals.d/operator.conf"
printf 'PRINCIPAL="alice"\nHOST="host-a"\nUSERNAME="alice"\n' > "$ROOT/accounts.d/alice-host-a.conf"
cat > "$ROOT/logins.d/alice-claude-max.conf" <<'EOF'
PRINCIPAL="alice"
ACCOUNT="alice@example.test"
PROVIDER="claude-max"
CONFIG_DIR="~/.claude-logins/claude-max"
LEGAL_OWNER="alice"
EOF
chmod 600 "$ROOT/logins.d/alice-claude-max.conf"
SID="s-00000000000000aa"
cat > "$ROOT/sessions.d/$SID.conf" <<EOF
ID="$SID"
ACCOUNT="alice-host-a"
SLUG="acme-alice"
TARGET_ENTITY="acme"
DOMAIN="acme"
HOST="host-a"
REPO_PATH="$FX/home/alice"
OWNER="alice"
PERMISSION_MODE="bypassPermissions"
LOGIN="alice-claude-max"
EOF
# The invitation that created her - it must survive as history.
NOW="$(date -u +%s)"
cat > "$ROOT/invites.d/inv-0000000a.conf" <<EOF
NAME="Alice"
PRINCIPAL="alice"
ENTITY="acme"
HOST="host-a"
RUNTIME="claude-code"
PROVIDER="claude-max"
TOKEN_SHA256="$(printf 'x' | { if command -v sha256sum >/dev/null 2>&1; then sha256sum; else shasum -a 256; fi; } | cut -d' ' -f1)"
ISSUED_BY="operator"
ISSUED_AT="$NOW"
EXPIRES_AT="$((NOW + 86400))"
STATE="redeemed"
REDEEMED_LOGIN="oidc:issuer-a:SUB-1"
REDEEMED_AT="$NOW"
EOF
chmod 600 "$ROOT/invites.d/inv-0000000a.conf"

HUBHOME="$FX/hubhome"; mkdir -p "$HUBHOME/.ssh"
printf 'restrict,command="STEWARD_ESTATE_ROOT=%s /bin/bash %s/scripts/bus/bin/bus-relay-in %s" ssh-ed25519 AAAAALICE alice\n' \
  "$ROOT" "$HUBHOME" "$SID" > "$HUBHOME/.ssh/authorized_keys"
printf 'restrict,command="keep me" ssh-ed25519 AAAAOTHER other\n' >> "$HUBHOME/.ssh/authorized_keys"
mkdir -p "$FX/home/alice/.ssh"

# -- the home lookup and the shims ------------------------------------------
mkdir -p "$FX/bin"
cat > "$FX/bin/homelookup" <<EOF
#!/bin/bash
echo "$FX/home/\$1"
EOF
chmod 755 "$FX/bin/homelookup"

# sudo: records argv, then MODELS THE HELPER. The helper's own words go to
# STDERR, where the real one puts them - offboard captures the call with 2>&1
# and reads the archive path back out of that capture, so a shim writing them
# on stdout would let a regression through unseen.
#
# FX_SUDO_MODE and FX_FAIL_USER are the fixture's own knobs; nothing in the
# product reads them. They model the three ways this call goes wrong on a real
# host: sudo wants a password (sudo speaking), the helper's floor refuses
# (the helper speaking), and a refusal that lands on the SECOND account of a
# person whose first one was already locked.
cat > "$FX/bin/sudo" <<EOF
#!/bin/bash
echo "sudo \$*" >> "$FX/calls"
line="sudo"; for a in "\$@"; do line="\$line|\$a"; done
printf '%s\n' "\$line" >> "$FX/argv"
all="\$*"
args=()
while [ \$# -gt 0 ]; do
  case "\$1" in
    -n) shift ;;
    *) args+=("\$1"); shift ;;
  esac
done
u="\${args[2]:-}"
case "\${FX_SUDO_MODE:-normal}" in
  password) echo "sudo: a password is required" >&2; exit 1 ;;
  refuse)   echo "helper: REFUSING - '\$u' is in a sudo-capable group" >&2; exit 64 ;;
esac
if [ -n "\${FX_FAIL_USER:-}" ] && [ "\$u" = "\${FX_FAIL_USER:-}" ]; then
  echo "helper: REFUSING - '\$u' is in a sudo-capable group" >&2
  exit 64
fi
echo "helper: account \$u expired" >&2
echo "helper: password locked" >&2
echo "helper: lingering disabled, no session left (measured)" >&2
case "\$all" in
  *--archive-home*)
    rm -rf "$FX/home/\$u"
    echo "helper: archived /home/.offboarded/\$u-2026-09-09" >&2
    echo "helper: NOTHING BELONGING TO THE MEMBER WAS DELETED" >&2 ;;
esac
exit 0
EOF
chmod 755 "$FX/bin/sudo"

# mktemp: a pass-through carrying ONE hook, the same seam
# test/invite-redeem.test.sh uses. A bare \`mktemp\` (no template) is what the
# membership step asks for after it has read the entity and before the writer
# takes its lock - the window a concurrent MEMBERS change has to land in for
# the under-lock recheck to be the thing that catches it. Every other mktemp
# in the run passes a template, so the hook cannot fire on the wrong one.
MKTEMP_REAL="$(command -v mktemp)"
cat > "$FX/bin/mktemp" <<EOF
#!/bin/bash
if [ \$# -eq 0 ] && [ -f "$FX/hook-entity" ]; then
  hm="\$(cat "$FX/hook-entity")"; rm -f "$FX/hook-entity"
  printf 'NAME="Acme"\nMEMBERS="%s"\n' "\$hm" > "\$STEWARD_ESTATE_ROOT/entities.d/acme.conf"
fi
exec "$MKTEMP_REAL" "\$@"
EOF
chmod 755 "$FX/bin/mktemp"
: > "$FX/calls"
: > "$FX/argv"

FX_SUDO_MODE=""; FX_FAIL_USER=""; FX_SNAPSHOT_RC=""
run() {
  ( export PATH="$FX/bin:$PATH"
    export HOME="$HUBHOME"
    export STEWARD_ESTATE_ROOT="$ROOT"
    export STEWARD_CONFIG_FILE="$FX/no-such-config"
    export STEWARD_HOME_LOOKUP_CMD="$FX/bin/homelookup"
    export STEWARD_AUTHORIZED_KEYS="$HUBHOME/.ssh/authorized_keys"
    # THIS MACHINE IS THE HOST THE ACCOUNTS NAME. Offboarding acts locally -
    # the helper through local sudo, a home on this disk - so it refuses an
    # account that lives on another machine, and without this the fixture's
    # own host slug would never match.
    export STEWARD_SELF_HOST="host-a"
    export FX_SUDO_MODE FX_FAIL_USER FX_SNAPSHOT_RC
    bash "$S" "$@" )
}

# helper <principal> <name> - a person with a principal row and an account.
newperson() {
  printf 'NAME="%s"\nOIDC_LOGIN="issuer-x:SUB-%s"\n' "$2" "$1" > "$ROOT/principals.d/$1.conf"
  printf 'PRINCIPAL="%s"\nHOST="host-a"\nUSERNAME="%s"\n' "$1" "$1" > "$ROOT/accounts.d/$1-host-a.conf"
  mkdir -p "$FX/home/$1"
}

echo "== the arguments =="
out="$(run offboard nobody 2>&1)"; rc=$?
is  "an unknown principal is rc 78" "$rc" "78"
out="$(run offboard 'Not A Slug' 2>&1)"; rc=$?
is  "a malformed principal is rc 64" "$rc" "64"
out="$(run offboard 2>&1)"; rc=$?
is  "no principal at all is rc 64" "$rc" "64"

echo "== an account on another machine is refused before any side effect =="
# The helper is LOCAL: it locks an account in this machine's account database
# and moves a home on this machine's disk. A person whose account lives
# elsewhere would be half-offboarded here - rows gone, account still open
# there - so the refusal comes before the first call.
printf 'PRINCIPAL="alice"\nHOST="host-b"\nUSERNAME="alice"\n' > "$ROOT/accounts.d/alice-host-b.conf"
: > "$FX/calls"
out="$(run offboard alice 2>&1)"; rc=$?
is  "an account on another host refuses, rc 65" "$rc" "65"
has "and names the host it lives on" "$out" "host-b"
is  "and nothing was called at all" "$(wc -c < "$FX/calls" | tr -d ' ')" "0"
have "the session row is untouched" "$ROOT/sessions.d/$SID.conf"
have "the account row is untouched" "$ROOT/accounts.d/alice-host-a.conf"
have "the principal row is untouched" "$ROOT/principals.d/alice.conf"
havenot "and no receipt was written" "$HUBHOME/.local/state/fixture-state/offboards/alice.receipt.json"
rm -f "$ROOT/accounts.d/alice-host-b.conf"

echo "== the offboarding itself =="
: > "$FX/calls"
out="$(run offboard alice 2>&1)"; rc=$?
is  "offboard succeeds" "$rc" "0"

echo "== every row is gone =="
havenot "the session row is removed" "$ROOT/sessions.d/$SID.conf"
havenot "the login row is removed" "$ROOT/logins.d/alice-claude-max.conf"
havenot "the account row is removed" "$ROOT/accounts.d/alice-host-a.conf"
havenot "the principal row is removed" "$ROOT/principals.d/alice.conf"
is  "the membership is gone" "$(sed -n 's/^MEMBERS="\(.*\)"/\1/p' "$ROOT/entities.d/acme.conf")" "operator"
has "the invitation survives as history" "$(cat "$ROOT/invites.d/inv-0000000a.conf")" 'STATE="redeemed"'
has "and the run says so out loud" "$out" "KEPT as history"

echo "== the bus is unbound =="
ak="$(cat "$HUBHOME/.ssh/authorized_keys")"
no  "the relay row is gone" "$ak" "$SID"
has "and the other key line is untouched" "$ak" "AAAAOTHER"
is  "the hub's file is mode 600" "$(modeof "$HUBHOME/.ssh/authorized_keys")" "600"
have "one backup, under a fixed name" "$HUBHOME/.ssh/authorized_keys.bak-offboard"
is  "and the backup is mode 600" "$(modeof "$HUBHOME/.ssh/authorized_keys.bak-offboard")" "600"
is  "and there is exactly one of them" \
    "$(ls "$HUBHOME/.ssh" | grep -c 'bak' | tr -d ' ')" "1"

echo "== the host was touched only through the helper =="
calls="$(cat "$FX/calls")"
has "the account was locked" "$calls" "steward-account-helper lock alice"
has "and the home archived" "$calls" "steward-account-helper lock alice --archive-home"
has "the desk was snapshotted" "$calls" "snapshot"
if [ -d "$FX/home/alice" ]; then bad "and the home is out of the way" "still there"; else ok "and the home is out of the way"; fi

echo "== the receipt lists everything removed =="
R="$HUBHOME/.local/state/fixture-state/offboards/alice.receipt.json"
have "a receipt file was written" "$R"
is  "the receipt directory is mode 700" "$(modeof "$HUBHOME/.local/state/fixture-state/offboards")" "700"
is  "the receipt is mode 600" "$(modeof "$R")" "600"
is  "the receipt is done" "$(jq -r .state "$R")" "done"
is  "and names the person" "$(jq -r .principal "$R")" "alice"
has "it names the session" "$(cat "$R")" "$SID"
has "it names the login" "$(cat "$R")" "alice-claude-max"
has "it names the account" "$(cat "$R")" "alice-host-a"
has "it names the principal" "$(cat "$R")" "principals.d/alice.conf"
has "it says the home was archived, not deleted" "$(cat "$R")" "archived, not deleted"
has "and names where the helper put it" "$(cat "$R")" "/home/.offboarded/alice-"

echo "== a second run is a no-op =="
# AND IT DOES NOT REWRITE THE RECEIPT. The second run removes nothing, so a
# receipt written from it would be an empty list published over the record of
# what the first run actually did.
lines_before="$(jq -r '.removed|length' "$R")"
: > "$FX/calls"
out="$(run offboard alice 2>&1)"; rc=$?
is  "the second run is rc 0" "$rc" "0"
has "and says there was nothing left" "$out" "nothing left to remove"
is  "and calls nothing" "$(wc -c < "$FX/calls" | tr -d ' ')" "0"
is  "and the first run's receipt is left standing" "$(jq -r '.removed|length' "$R")" "$lines_before"
has "still naming the session it removed" "$(cat "$R")" "$SID"

echo "== --keep-home leaves the home alone =="
newperson bo "Bo"
: > "$FX/calls"
out="$(run offboard bo --keep-home 2>&1)"; rc=$?
is  "offboard --keep-home succeeds" "$rc" "0"
calls="$(cat "$FX/calls")"
has "the account is still locked" "$calls" "steward-account-helper lock bo"
no  "but the home is not archived" "$calls" "--archive-home"
if [ -d "$FX/home/bo" ]; then ok "and the home is still there"; else bad "and the home is still there" "gone"; fi
has "and the receipt says the home was kept" "$(cat "$HUBHOME/.local/state/fixture-state/offboards/bo.receipt.json")" "kept in place"

echo "== --json is exactly one JSON value on stdout =="
newperson cyd "Cyd"
CSID="s-00000000000000cc"
cat > "$ROOT/sessions.d/$CSID.conf" <<EOF
ID="$CSID"
ACCOUNT="cyd-host-a"
SLUG="acme-cyd"
TARGET_ENTITY="acme"
DOMAIN="acme"
HOST="host-a"
REPO_PATH="$FX/home/cyd"
OWNER="cyd"
PERMISSION_MODE="bypassPermissions"
EOF
out="$(run offboard cyd --json 2>/dev/null)"; rc=$?
is  "a --json offboarding succeeds" "$rc" "0"
is  "and stdout is one line, not a prose list and a value" "$(printf '%s\n' "$out" | wc -l | tr -d ' ')" "1"
if printf '%s' "$out" | jq -e .ok >/dev/null 2>&1; then ok "and it parses, ok true"; else bad "and it parses, ok true" "$out"; fi
is  "and it names the verb" "$(printf '%s' "$out" | jq -r .kind 2>/dev/null)" "offboard"
has "and carries the list of what went" "$(printf '%s' "$out" | jq -r '.removed|join(" ")' 2>/dev/null)" "$CSID"
has "and names the receipt" "$(printf '%s' "$out" | jq -r .receipt 2>/dev/null)" "cyd.receipt.json"
no  "and no prose leaked onto stdout" "$out" "offboard: "
err="$(run offboard cyd --json 2>&1 >/dev/null)"
has "the prose went to stderr" "$err" "nothing left to remove"

echo "== rc 77 is 'sudo could not run it', rc 70 is 'it ran and said no' =="
# The discriminator cannot be the exit status - sudo passes the command's
# through - so it is the output, exactly as the redemption reads it.
newperson dag "Dag"
DR="$HUBHOME/.local/state/fixture-state/offboards/dag.receipt.json"
FX_SUDO_MODE="password"
out="$(run offboard dag 2>&1)"; rc=$?
is  "sudo that wants a password is rc 77" "$rc" "77"
has "and the message names the sudoers line" "$out" "NOPASSWD"
has "and quotes sudo's own words" "$out" "a password is required"
is  "the receipt says the run failed" "$(jq -r .state "$DR")" "failed"
have "and no row was removed" "$ROOT/accounts.d/dag-host-a.conf"
FX_SUDO_MODE="refuse"
out="$(run offboard dag 2>&1)"; rc=$?
FX_SUDO_MODE=""
is  "a helper that ran and refused is rc 70" "$rc" "70"
has "and quotes the helper's own line" "$out" "helper: REFUSING"
no  "and does not send the operator to sudoers" "$out" "NOPASSWD"
have "and still no row was removed" "$ROOT/accounts.d/dag-host-a.conf"
have "the principal row too" "$ROOT/principals.d/dag.conf"

echo "== a refusal on the SECOND account is honest about the first =="
# The receipt is the reason this verb exists. A run that locked one account
# and then met a refusal on the next must say which one it did.
newperson elm "Elm"
printf 'PRINCIPAL="elm"\nHOST="host-a"\nUSERNAME="elmtwo"\n' > "$ROOT/accounts.d/elm-second.conf"
mkdir -p "$FX/home/elmtwo"
: > "$FX/calls"
FX_FAIL_USER="elmtwo"
out="$(run offboard elm 2>&1)"; rc=$?
FX_FAIL_USER=""
ER="$HUBHOME/.local/state/fixture-state/offboards/elm.receipt.json"
is  "the run fails, rc 70" "$rc" "70"
is  "the receipt says failed" "$(jq -r .state "$ER")" "failed"
has "and names the account it did lock" "$(jq -r '.removed|join(" ")' "$ER")" "elm locked"
no  "and never claims the one it did not" "$(jq -r '.removed|join(" ")' "$ER")" "elmtwo locked"
have "no row was removed" "$ROOT/accounts.d/elm-host-a.conf"
have "neither was the second" "$ROOT/accounts.d/elm-second.conf"
if [ -d "$FX/home/elm" ]; then ok "and no home was archived"; else bad "and no home was archived" "gone"; fi
rm -f "$ROOT/accounts.d/elm-second.conf" "$ROOT/accounts.d/elm-host-a.conf" "$ROOT/principals.d/elm.conf"

echo "== a membership change that lands mid-run is refused, not lost =="
# The rewrite goes through the same under-lock recheck a redemption uses: this
# run measured its decision against a MEMBERS it read a moment earlier, and a
# row that moved in between is refused rather than published over.
newperson fen "Fen"
members_before="$(sed -n 's/^MEMBERS="\(.*\)"$/\1/p' "$ROOT/entities.d/acme.conf")"
printf 'NAME="Acme"\nMEMBERS="%s fen"\n' "$members_before" > "$ROOT/entities.d/acme.conf"
printf '%s fen zoe\n' "$members_before" > "$FX/hook-entity"
out="$(run offboard fen 2>&1)"; rc=$?
is  "an entity that moved under the run refuses, rc 70" "$rc" "70"
has "and says the entity changed" "$out" "changed"
has "the concurrent member is still a member" "$(cat "$ROOT/entities.d/acme.conf")" "zoe"
have "and the principal row is still there, for the rerun" "$ROOT/principals.d/fen.conf"
is  "the receipt says failed" \
    "$(jq -r .state "$HUBHOME/.local/state/fixture-state/offboards/fen.receipt.json")" "failed"
printf 'NAME="Acme"\nMEMBERS="%s"\n' "$members_before" > "$ROOT/entities.d/acme.conf"
rm -f "$ROOT/principals.d/fen.conf"

echo "== a snapshot that fails is said out loud, never swallowed =="
# The snapshot is a projection of the register, and the register has already
# changed by the time it runs - so its failure cannot undo anything. It is
# still the operator's business: the desk keeps showing a person who is gone
# until somebody runs it by hand.
newperson gam "Gam"
: > "$FX/calls"
FX_SNAPSHOT_RC="1"
out="$(run offboard gam 2>&1)"; rc=$?
FX_SNAPSHOT_RC=""
is  "the offboarding still succeeds, rc 0" "$rc" "0"
has "and names the snapshot as the thing that failed" "$out" "desk snapshot failed"
has "and says what to run by hand" "$out" "steward desk snapshot"
GR="$HUBHOME/.local/state/fixture-state/offboards/gam.receipt.json"
is  "the receipt is still done" "$(jq -r .state "$GR")" "done"
has "and carries the snapshot note" "$(jq -r '.removed|join(" ")' "$GR")" "desk snapshot failed"

printf '\n  %d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
