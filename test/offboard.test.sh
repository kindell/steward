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
FX="$(mktemp -d)"
# A CASE THAT MAKES A DIRECTORY UNREADABLE PUTS IT BACK EVEN WHEN IT DIES. The
# fixture is removed from this trap, and `rm -rf` cannot descend into a mode-000
# directory - so an assertion that exits mid-case would leave the whole
# temporary tree on the machine for good.
GUARD_DIR=""
trap 'if [ -n "$GUARD_DIR" ]; then chmod 700 "$GUARD_DIR" 2>/dev/null; fi; rm -rf "$FX"' EXIT
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
    # FX_REFUSE_ARCHIVE models the helper's BELT: the receipts above already
    # went out, the account is locked, and only the move refuses. It is the
    # one shape of failure that lands AFTER every register row is gone.
    if [ -n "\${FX_REFUSE_ARCHIVE:-}" ]; then
      echo "helper: REFUSING - the home and /home/.offboarded are on different filesystems" >&2
      exit 70
    fi
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

FX_SUDO_MODE=""; FX_FAIL_USER=""; FX_SNAPSHOT_RC=""; FX_REFUSE_ARCHIVE=""
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
    export FX_SUDO_MODE FX_FAIL_USER FX_SNAPSHOT_RC FX_REFUSE_ARCHIVE
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
# BOTH MACHINES, NOT ONE. "run offboard on host-b" is only actionable if the
# reader can tell it apart from the machine they are already standing on.
has "and the host this run is standing on" "$out" "this host is host-a"
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
# AND THE ROW SAYS WHICH VERB REWROTE IT. The composition is shared with
# `invite redeem` and the verb's name is an argument to it, so nothing else
# would notice the two callers handing it the same label.
has "and the row names the verb that rewrote it" "$(cat "$ROOT/entities.d/acme.conf")" "updated by steward offboard"
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
# THE ARGV, NOT THE FLATTENED LINE. The calls log joins the words with spaces,
# so it cannot tell one argument carrying a space from two arguments; this
# record keeps the boundaries, and a username that ever reached the helper as
# part of a string instead of as its own word would show up here first.
has "and the helper was called with separate words, not one string" \
    "$(cat "$FX/argv")" "sudo|-n|/usr/local/sbin/steward-account-helper|lock|alice|--archive-home"

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

echo "== and removed[] holds ONLY what was removed =="
# A FIELD CALLED removed IS A PROMISE. A line saying the invitation was KEPT,
# or that a home was left in place, is the opposite of a removal, and a reader
# counting removed[] to see what this run did was being told the wrong number.
is  "the receipt is at schema 2" "$(jq -r .schemaVersion "$R")" "2"
no  "nothing in removed[] says it was kept" "$(jq -r '.removed|join(" ")' "$R")" "KEPT"
has "the invitation is in kept[] instead" "$(jq -r '.kept|join(" ")' "$R")" "KEPT as history"
is  "and a clean run warns about nothing" "$(jq -r '.warnings|length' "$R")" "0"

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
BOR="$HUBHOME/.local/state/fixture-state/offboards/bo.receipt.json"
has "and the receipt says the home was kept" "$(jq -r '.kept|join(" ")' "$BOR")" "kept in place"
# THE KEY IS STILL IN THAT HOME. Both keys live in the person's home and were
# meant to travel with it into the archive; --keep-home is the one path where
# the home does not travel, so the hub's delivery key stays installed in a
# directory the register no longer describes. The account is locked, so nothing
# can use it - but the receipt is the record, and it has to say so.
has "and that the delivery key is still installed there" \
    "$(jq -r '.kept|join(" ")' "$BOR")" "delivery key is still installed"
has "and the operator is told on stderr, not only in the file" "$out" "delivery key is still installed"
no  "the kept home is not counted as a removal" "$(jq -r '.removed|join(" ")' "$BOR")" "kept in place"

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
# COUNTED AS VALUES, NOT AS LINES. `jq -e .ok` is happy with a STREAM: two
# objects printed back to back are one line and every one of them has .ok, so
# the line count and a bare .ok together would still pass a verb that printed
# its answer twice. Slurping counts what a caller would actually have to parse.
is  "and stdout is exactly one JSON value, not a stream" \
    "$(printf '%s' "$out" | jq -s 'length' 2>/dev/null)" "1"
if printf '%s' "$out" | jq -s -e '.[0].ok' >/dev/null 2>&1; then ok "and it parses, ok true"; else bad "and it parses, ok true" "$out"; fi
is  "and it names the verb" "$(printf '%s' "$out" | jq -r .kind 2>/dev/null)" "offboard"
has "and carries the list of what went" "$(printf '%s' "$out" | jq -r '.removed|join(" ")' 2>/dev/null)" "$CSID"
is  "and the same three lists the receipt carries" \
    "$(printf '%s' "$out" | jq -r '[has("removed"),has("kept"),has("warnings")]|join(",")' 2>/dev/null)" "true,true,true"
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
# WHERE THE RUN STOPPED IS PART OF THE RECORD. A receipt carrying only the
# steps that worked leaves the reader with "state: failed" and no way to tell
# what said no - and it is a warning, not a removal.
is  "the refusal is one entry in warnings[]" \
    "$(jq -r '[.warnings[]|select(startswith("stopped here:"))]|length' "$ER")" "1"
has "and it says where the run stopped" "$(jq -r '.warnings|join(" ")' "$ER")" "stopped here:"
has "quoting the helper's own words" "$(jq -r '.warnings|join(" ")' "$ER")" "helper: REFUSING"
no  "and the refusal is not counted as a removal" "$(jq -r '.removed|join(" ")' "$ER")" "stopped here:"
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
has "and carries the snapshot note as a warning" "$(jq -r '.warnings|join(" ")' "$GR")" "desk snapshot failed"
no  "which is not a thing that was removed" "$(jq -r '.removed|join(" ")' "$GR")" "desk snapshot failed"

echo "== the person a host row names is refused, not offboarded =="
# A HOST ROW NAMES ITS OWNER AND ITS OPERATOR, and this verb removes the
# principal row those two fields name. Offboarding the person a host row names leaves
# that row naming a principal that has no row anywhere - the machine's own
# record of who answers for it, broken by a verb that was only asked to clean up
# after a rehearsal. Nothing in the fleet would report the dangling name either:
# the loaders check the FORM of the slug, not that a principal by that name
# exists. The register has to be changed first, by a hand that knows who takes
# over.
newperson ivo "Ivo"
printf 'OWNER="operator"\nLEGAL_OWNER="Acme Ltd"\nOPERATOR="ivo"\n' > "$ROOT/hosts.d/host-c.conf"
: > "$FX/calls"
out="$(run offboard ivo 2>&1)"; rc=$?
is  "the machine's operator refuses, rc 65" "$rc" "65"
has "and names the host row that names them" "$out" "hosts.d/host-c.conf"
has "and which field does it" "$out" "OPERATOR"
is  "and nothing was called at all" "$(wc -c < "$FX/calls" | tr -d ' ')" "0"
# BOTH FIELDS, not only the one the estate happens to use. OWNER and OPERATOR
# are deliberately separate on a host row - a machine can be owned by a company
# and operated by a person - and a scan that read one of them would offboard
# the other in silence.
printf 'OWNER="ivo"\nLEGAL_OWNER="Acme Ltd"\nOPERATOR="operator"\n' > "$ROOT/hosts.d/host-c.conf"
out="$(run offboard ivo 2>&1)"; rc=$?
is  "the machine's owner refuses too, rc 65" "$rc" "65"
has "and says it is the OWNER field" "$out" "OWNER"
have "the principal row is untouched" "$ROOT/principals.d/ivo.conf"
have "the account row is untouched" "$ROOT/accounts.d/ivo-host-a.conf"
have "and the host row still names them" "$ROOT/hosts.d/host-c.conf"
havenot "no receipt was written" "$HUBHOME/.local/state/fixture-state/offboards/ivo.receipt.json"
# EVERY ROW THAT NAMES THEM, NOT THE FIRST ONE. A refusal that names one row at
# a time sends the operator to repair it, re-run, and be refused again by the
# next - and the second refusal reads as a verb that changed its mind.
rm -f "$ROOT/hosts.d/host-c.conf"
printf 'OWNER="operator"\nLEGAL_OWNER="Acme Ltd"\nOPERATOR="ivo"\n' > "$ROOT/hosts.d/host-d.conf"
printf 'OWNER="ivo"\nLEGAL_OWNER="Acme Ltd"\nOPERATOR="operator"\n' > "$ROOT/hosts.d/host-e.conf"
out="$(run offboard ivo 2>&1)"; rc=$?
is  "two host rows that name them still refuse, rc 65" "$rc" "65"
has "and the first row is named" "$out" "hosts.d/host-d.conf"
has "and so is the second" "$out" "hosts.d/host-e.conf"
rm -f "$ROOT/hosts.d/host-d.conf" "$ROOT/hosts.d/host-e.conf" \
      "$ROOT/principals.d/ivo.conf" "$ROOT/accounts.d/ivo-host-a.conf"

echo "== a row that cannot be matched or read is left in place, and SAID =="
# THE RECEIPT IS PRESENTED AS THE RECORD OF A FINISHED CLEANUP. A live session
# row, an unreadable login row or an account row the loader will not vouch for
# is exactly what this verb exists to prevent, and passing over one in silence
# is the one way the receipt can be true line by line and wrong as a whole.
newperson ivy "Ivy"
IVYSID="s-00000000000000ii"
# An OLD-SHAPE session row: it names the person in OWNER and carries no
# ACCOUNT at all, so no scan by account slug will ever find it.
cat > "$ROOT/sessions.d/$IVYSID.conf" <<EOF
ID="$IVYSID"
SLUG="acme-ivy"
DOMAIN="acme"
HOST="host-a"
REPO_PATH="$FX/home/ivy"
OWNER="ivy"
PERMISSION_MODE="bypassPermissions"
EOF
# A login row of hers the loader refuses: the required key ACCOUNT is missing.
printf 'PRINCIPAL="ivy"\nPROVIDER="claude-max"\nCONFIG_DIR="~/.claude-logins/claude-max"\nLEGAL_OWNER="ivy"\n' \
  > "$ROOT/logins.d/ivy-broken.conf"
chmod 600 "$ROOT/logins.d/ivy-broken.conf"
# A session row filed under an account slug with no row at all: no scan by
# account slug can find it either, and it is stranded the same way the
# old-shape row above is. (An account row the loader REFUSES is a different
# answer now - it refuses the whole run, in its own case below.)
STRANDED="s-00000000000000ij"
cat > "$ROOT/sessions.d/$STRANDED.conf" <<EOF
ID="$STRANDED"
ACCOUNT="ivy-gone"
SLUG="acme-ivy-two"
DOMAIN="acme"
HOST="host-a"
REPO_PATH="$FX/home/ivy"
OWNER="ivy"
PERMISSION_MODE="bypassPermissions"
EOF
out="$(run offboard ivy 2>&1)"; rc=$?
IR="$HUBHOME/.local/state/fixture-state/offboards/ivy.receipt.json"
is  "the offboarding still succeeds, rc 0" "$rc" "0"
has "the old-shape session row is named on stderr" "$out" "$IVYSID"
has "and the reader is told what to do with it" "$out" "left in place"
has "the row filed under the broken account is named too" "$out" "$STRANDED"
has "the login row that will not load is named too" "$out" "logins.d/ivy-broken.conf"
kept="$(jq -r '.kept|join(" ")' "$IR")"
has "the session row is in the receipt's kept list" "$kept" "$IVYSID"
has "so is the stranded one" "$kept" "$STRANDED"
has "so is the login row" "$kept" "logins.d/ivy-broken.conf"
no  "and none of them is counted as removed" "$(jq -r '.removed|join(" ")' "$IR")" "ivy-broken"
have "the session row really is still there" "$ROOT/sessions.d/$IVYSID.conf"
have "and the stranded one" "$ROOT/sessions.d/$STRANDED.conf"
have "and the login row" "$ROOT/logins.d/ivy-broken.conf"
havenot "while the principal row went" "$ROOT/principals.d/ivy.conf"
rm -f "$ROOT/sessions.d/$IVYSID.conf" "$ROOT/sessions.d/$STRANDED.conf" \
      "$ROOT/logins.d/ivy-broken.conf"

echo "== an account row that does not load refuses the whole run =="
# AN ACCOUNT ROW IS THE ONLY THING THAT NAMES A UNIX ACCOUNT. A row the loader
# will not vouch for is an account nothing here can lock and a home nothing here
# can move; warning and carrying on left the person's account open on the host
# behind a receipt that said done - the one answer an operator re-reads to be
# sure it is clean.
newperson jai "Jai"
printf 'PRINCIPAL="jai"\nUSERNAME="jaitwo"\n' > "$ROOT/accounts.d/jai-broken.conf"   # no HOST: refused
: > "$FX/calls"
out="$(run offboard jai 2>&1)"; rc=$?
is  "an account row that will not load refuses, rc 78" "$rc" "78"
has "and names the row" "$out" "accounts.d/jai-broken.conf"
has "and says nothing here can name the account" "$out" "does not load"
is  "and nothing was called at all" "$(wc -c < "$FX/calls" | tr -d ' ')" "0"
have "the principal row is untouched" "$ROOT/principals.d/jai.conf"
have "the good account row is untouched" "$ROOT/accounts.d/jai-host-a.conf"
have "and the broken row is left where it stood" "$ROOT/accounts.d/jai-broken.conf"
havenot "and no receipt was written" "$HUBHOME/.local/state/fixture-state/offboards/jai.receipt.json"
# AND IT CANNOT BE WALKED PAST BY LOSING THE PRINCIPAL ROW EITHER. A broken
# account row that outlives its principal is the shape a half-finished cleanup
# leaves behind.
rm -f "$ROOT/principals.d/jai.conf" "$ROOT/accounts.d/jai-host-a.conf"
out="$(run offboard jai 2>&1)"; rc=$?
is  "a broken row outliving the principal row still refuses, rc 78" "$rc" "78"
has "and still names the row" "$out" "accounts.d/jai-broken.conf"
no  "and never reports the person as cleanly gone" "$out" "nothing left to remove"
rm -f "$ROOT/accounts.d/jai-broken.conf"

echo "== a field the register's own writer would refuse is not acted on =="
# THE ACCOUNT ROWS ARE CARRIED IN A TAB- AND NEWLINE-DELIMITED LIST, and a
# hand-edited USERNAME carrying both forges a whole extra row inside it.
# Measured before this gate: one such row made the run lock a unix account NO
# register row names, archive its home, and file both under this person's
# offboarding at rc 0. `steward registry account add` refuses the same value on
# the way in; the reader has to refuse it on the way out.
newperson kev "Kev"
printf 'PRINCIPAL="kev"\nHOST="host-a"\nUSERNAME="kev\nkev-forged\thost-a\tzed"\n' \
  > "$ROOT/accounts.d/kev-host-a.conf"
: > "$FX/calls"
out="$(run offboard kev 2>&1)"; rc=$?
is  "a forged USERNAME refuses, rc 78" "$rc" "78"
has "and names the row it came out of" "$out" "accounts.d/kev-host-a.conf"
has "and the field that is wrong" "$out" "USERNAME"
is  "and nothing was called at all" "$(wc -c < "$FX/calls" | tr -d ' ')" "0"
no  "so no account nobody named was locked" "$(cat "$FX/calls")" "zed"
have "the account row is left where it stood" "$ROOT/accounts.d/kev-host-a.conf"
have "the principal row is untouched" "$ROOT/principals.d/kev.conf"
havenot "and no receipt was written" "$HUBHOME/.local/state/fixture-state/offboards/kev.receipt.json"
# HOST IS THE OTHER FIELD THE LOADER ONLY CHECKS FOR EMPTINESS. A value with a
# space in it reached the host gate and came back out as a message about a
# machine that does not exist; it is a row the writer would never have written.
printf 'PRINCIPAL="kev"\nHOST="host a"\nUSERNAME="kev"\n' > "$ROOT/accounts.d/kev-host-a.conf"
: > "$FX/calls"
out="$(run offboard kev 2>&1)"; rc=$?
is  "a HOST the writer would refuse refuses too, rc 78" "$rc" "78"
has "and names that field" "$out" "HOST"
is  "and still nothing was called" "$(wc -c < "$FX/calls" | tr -d ' ')" "0"
rm -f "$ROOT/accounts.d/kev-host-a.conf" "$ROOT/principals.d/kev.conf"

echo "== the reader and the writer share ONE grammar per field =="
# THE REFUSAL ABOVE IS "a value this register's own writer would have refused",
# and until now it said that from a COPY of the writer's regex. Change the
# writer's grammar and the reader keeps refusing what the writer now accepts -
# and the failure mode is a refusal to offboard a person whose row the product
# itself wrote. Both sides now ask the same predicate; these cases feed one
# accepted and one rejected value to each and assert the two agree.
#
# The reader probe always leaves a SECOND account row, on the other host, so the
# accepted values stop at the cross-host gate: nothing is ever locked or moved
# here, whichever way the grammar answers.
newperson mox "Mox"
writer_verdict() {   # <flag> <value> -> refused | accepted
  local wo
  case "$1" in
    host)     wo="$(run registry account add mox-probe --principal mox --host "$2" --username mox 2>&1)" ;;
    username) wo="$(run registry account add mox-probe --principal mox --host host-a --username "$2" 2>&1)" ;;
  esac
  rm -f "$ROOT/accounts.d/mox-probe.conf"
  case "$wo" in *"invalid --$1"*) printf 'refused' ;; *) printf 'accepted' ;; esac
}
reader_verdict() {   # <HOST> <USERNAME> -> refused | accepted
  local ro
  printf 'PRINCIPAL="mox"\nHOST="%s"\nUSERNAME="%s"\n' "$1" "$2" > "$ROOT/accounts.d/mox-host-b.conf"
  ro="$(run offboard mox 2>&1)"
  rm -f "$ROOT/accounts.d/mox-host-b.conf"
  case "$ro" in *"would have refused"*) printf 'refused' ;; *) printf 'accepted' ;; esac
}
w="$(writer_verdict host '-host-a')"
is  "the writer refuses a HOST that starts with a hyphen" "$w" "refused"
is  "and the reader gives the same answer" "$(reader_verdict '-host-a' mox)" "$w"
w="$(writer_verdict host 'host-b')"
is  "the writer accepts a well-formed HOST" "$w" "accepted"
is  "and the reader gives the same answer" "$(reader_verdict 'host-b' mox)" "$w"
w="$(writer_verdict username '1mox')"
is  "the writer refuses a USERNAME that starts with a digit" "$w" "refused"
is  "and the reader gives the same answer" "$(reader_verdict 'host-b' '1mox')" "$w"
w="$(writer_verdict username 'mox')"
is  "the writer accepts a well-formed USERNAME" "$w" "accepted"
is  "and the reader gives the same answer" "$(reader_verdict 'host-b' 'mox')" "$w"
rm -f "$ROOT/principals.d/mox.conf" "$ROOT/accounts.d/mox-host-a.conf"

echo "== a register that cannot be READ is not a register with nothing in it =="
# MEASURED, AND ALL OF IT SILENT: mode 000 on hosts.d walked straight past the
# operator gate above and offboarded the machine's own operator at rc 0; mode
# 000 on sessions.d left the session row AND the bus relay row in the hub's
# authorized_keys standing behind a receipt that said "done" with zero
# warnings. A directory that cannot be listed answers every question with
# "nothing", and every question this verb asks is "does anything here still
# name this person". An ABSENT directory is a different answer and stays fine.
newperson kip "Kip"
KIPR="$HUBHOME/.local/state/fixture-state/offboards/kip.receipt.json"
if [ "$(id -u)" = "0" ]; then
  echo "  SKIP the unreadable-register cases - this run is root, where mode 000 is still readable"
else
  # MODE 000 REMOVES BOTH BITS AND THEREFORE PINS NEITHER. Both halves of the
  # check are load-bearing and both fail OPEN on their own: at mode 444 the
  # glob lists every name and `[ -e ]` then fails on all of them, at mode 111
  # the glob itself returns nothing - measured, each one left the session row
  # behind at rc 0. Two more turns of this loop, one per half.
  for regmode in accounts.d:000 principals.d:000 sessions.d:000 logins.d:000 \
                 hosts.d:000 entities.d:000 invites.d:000 \
                 sessions.d:444 sessions.d:111; do
    reg="${regmode%:*}"; regm="${regmode#*:}"
    GUARD_DIR="$ROOT/$reg"
    chmod "$regm" "$ROOT/$reg"
    : > "$FX/calls"
    out="$(run offboard kip 2>&1)"; rc=$?
    chmod 755 "$ROOT/$reg"; GUARD_DIR=""
    is  "an unreadable $reg (mode $regm) refuses, rc 78" "$rc" "78"
    has "and names the directory it could not read ($reg $regm)" "$out" "$reg"
    is  "and nothing was called at all ($reg $regm)" "$(wc -c < "$FX/calls" | tr -d ' ')" "0"
    have "the account row is untouched ($reg $regm)" "$ROOT/accounts.d/kip-host-a.conf"
    havenot "and no receipt was written ($reg $regm)" "$KIPR"
  done
  # AND ONE ROW INSIDE ONE OF THEM. The operator gate reads every host conf by
  # hand; a conf it cannot source reads as a row that names nobody, which is the
  # gate failing open on precisely the file that would have closed it.
  printf 'OWNER="operator"\nLEGAL_OWNER="Acme Ltd"\nOPERATOR="kip"\n' > "$ROOT/hosts.d/host-g.conf"
  printf 'OWNER="operator"\nLEGAL_OWNER="Acme Ltd"\nOPERATOR="kip"\n' > "$ROOT/hosts.d/host-i.conf"
  chmod 000 "$ROOT/hosts.d/host-g.conf"
  : > "$FX/calls"
  out="$(run offboard kip 2>&1)"; rc=$?
  chmod 644 "$ROOT/hosts.d/host-g.conf"
  is  "a host row that cannot be read refuses, rc 78" "$rc" "78"
  has "and names the file" "$out" "host-g.conf"
  is  "and nothing was called at all" "$(wc -c < "$FX/calls" | tr -d ' ')" "0"
  havenot "and no receipt was written" "$KIPR"
  # ONE REFUSAL AT A TIME, IN THE ORDER THAT MAKES THE NEXT ONE TRUE. The
  # unreadable file is answered first and alone, because it is the one that
  # makes every other answer uncertain; once the mode is fixed the SAME run
  # reports the rows that really do name the person, and both of them.
  : > "$FX/calls"
  out="$(run offboard kip 2>&1)"; rc=$?
  is  "and once the mode is fixed the row refusal is rc 65" "$rc" "65"
  has "naming the row that was readable all along" "$out" "host-i.conf"
  has "and the one whose mode was just fixed" "$out" "host-g.conf"
  is  "and still nothing was called" "$(wc -c < "$FX/calls" | tr -d ' ')" "0"
  rm -f "$ROOT/hosts.d/host-g.conf" "$ROOT/hosts.d/host-i.conf"

  # A REGISTER THAT IS A LINK TO NOTHING IS NOT AN ABSENT REGISTER. `[ -d ]` is
  # false for a dangling symlink, so it landed in the "absent is legitimate"
  # arm and the run finished at rc 0 - but an estate that points a register
  # somewhere has SAID something is there, and what it named is gone. That is
  # the same answer as a directory this run cannot list, not the same answer as
  # a directory nobody ever made.
  mv "$ROOT/logins.d" "$ROOT/logins.d-real"
  ln -s "$ROOT/no-such-register" "$ROOT/logins.d"
  : > "$FX/calls"
  out="$(run offboard kip 2>&1)"; rc=$?
  rm -f "$ROOT/logins.d"
  is  "a register that is a link to nothing refuses, rc 78" "$rc" "78"
  has "and says what is wrong with it" "$out" "points at nothing"
  is  "and nothing was called at all" "$(wc -c < "$FX/calls" | tr -d ' ')" "0"
  have "the account row is untouched" "$ROOT/accounts.d/kip-host-a.conf"
  havenot "and no receipt was written" "$KIPR"

  # A REGISTER THAT IS A FILE IS NOT AN ABSENT REGISTER EITHER. Measured before
  # this arm: hosts.d replaced by a one-line regular file offboarded the
  # machine's own OWNER and OPERATOR at rc 0, receipt state "done", warnings []
  # - the exact harm this gate was built for, through the one shape it did not
  # classify. The same register at mode 000, and as a dangling symlink, are both
  # rc 78; only "it is a file" walked through.
  mv "$ROOT/hosts.d" "$ROOT/hosts.d-real"
  printf 'this is a file, not a register\n' > "$ROOT/hosts.d"
  : > "$FX/calls"
  out="$(run offboard kip 2>&1)"; rc=$?
  rm -f "$ROOT/hosts.d"; mv "$ROOT/hosts.d-real" "$ROOT/hosts.d"
  is  "a register that is a regular file refuses, rc 78" "$rc" "78"
  has "and names it" "$out" "hosts.d"
  is  "and nothing was called at all" "$(wc -c < "$FX/calls" | tr -d ' ')" "0"
  have "the account row is untouched" "$ROOT/accounts.d/kip-host-a.conf"
  havenot "and no receipt was written" "$KIPR"
  # AND THE REQUIRED REGISTER SAYS THE RIGHT THING ABOUT IT: "not there" is
  # false when it is there and is a file.
  mv "$ROOT/entities.d" "$ROOT/entities.d-real"
  printf 'this is a file, not a register\n' > "$ROOT/entities.d"
  out="$(run offboard kip 2>&1)"; rc=$?
  rm -f "$ROOT/entities.d"; mv "$ROOT/entities.d-real" "$ROOT/entities.d"
  is  "a required register that is a file refuses, rc 78" "$rc" "78"
  no  "and does not claim it is not there" "$out" "is not there"

  # A ROW THAT IS A LINK TO NOTHING IS A ROW NOBODY CAN READ. `[ -e ]` is false
  # for a dangling symlink, so the row walk's own existence guard used to skip
  # it before the -r check ever ran. Measured: a dangling sessions.d row plus
  # its bus-relay-in row in the hub's authorized_keys came back rc 0, state
  # "done", warnings [] and kept [], with the relay row still standing
  # (before=1, after=1) and the row still in sessions.d. The same row as a
  # mode-000 regular file is rc 78.
  ln -s "$ROOT/no-such-target" "$ROOT/sessions.d/zz-dangle.conf"
  : > "$FX/calls"
  out="$(run offboard kip 2>&1)"; rc=$?
  rm -f "$ROOT/sessions.d/zz-dangle.conf"
  is  "a row that is a link to nothing refuses, rc 78" "$rc" "78"
  has "and names it" "$out" "zz-dangle.conf"
  is  "and nothing was called at all" "$(wc -c < "$FX/calls" | tr -d ' ')" "0"
  havenot "and no receipt was written" "$KIPR"

  # A ROW THAT IS NOT A FILE IS A ROW NOBODY CAN READ. `[ -r ]` is true for a
  # directory and for a fifo, so both used to walk past the check this loop
  # exists for. Measured before the `-f`: a directory named *.conf came back
  # rc 0 with state "done" and warnings []; a FIFO named *.conf blocked the run
  # forever, after the unix account was already locked and with no receipt
  # written at all. A directory is the safe half to assert on - a fifo case
  # would wedge this suite on a red.
  mkdir -p "$ROOT/sessions.d/zz-notafile.conf"
  : > "$FX/calls"
  out="$(run offboard kip 2>&1)"; rc=$?
  rmdir "$ROOT/sessions.d/zz-notafile.conf"
  is  "a row that is not a file refuses, rc 78" "$rc" "78"
  has "and names it" "$out" "zz-notafile.conf"
  is  "and nothing was called at all" "$(wc -c < "$FX/calls" | tr -d ' ')" "0"
  havenot "and no receipt was written" "$KIPR"

  # AND A LINK TO A READABLE DIRECTORY IS A REGISTER LIKE ANY OTHER: `-r` and
  # `-x` follow symlinks, so the refusal above must turn on the target being
  # gone and on nothing else.
  ln -s "$ROOT/logins.d-real" "$ROOT/logins.d"
  out="$(run offboard kip 2>&1)"; rc=$?
  rm -f "$ROOT/logins.d"; mv "$ROOT/logins.d-real" "$ROOT/logins.d"
  is  "a register that is a link to a readable directory is rc 0" "$rc" "0"
  rm -f "$KIPR"
fi
rm -f "$ROOT/principals.d/kip.conf" "$ROOT/accounts.d/kip-host-a.conf"

echo "== a ROW nobody can read is not a row that names nobody =="
# THE DIRECTORY GATE ABOVE CLOSED THE REGISTER; THIS CLOSES THE ROW INSIDE IT.
# Every scanner here reaches a row through a loader or a subshelled `source`,
# and both fail QUIETLY on a file they cannot open - so a single mode-000 conf
# is not skipped-and-said, it is never attributed to anybody at all. MEASURED
# before this gate, every one of them rc 0 with state "done", kept [] and
# warnings []: a mode-000 accounts.d row left a second unix account of the
# person's unlocked and its home unarchived; a mode-000 sessions.d row left the
# session row AND its bus relay row standing in the hub's authorized_keys; a
# mode-000 entities.d row left the person a member of that entity. A row nobody
# can read may be anybody's, so it is refused before the first side effect, and
# named.
LUXR="$HUBHOME/.local/state/fixture-state/offboards/lux.receipt.json"
luxseed() {
  newperson lux "Lux"
  printf 'PRINCIPAL="lux"\nHOST="host-a"\nUSERNAME="luxtwo"\n' > "$ROOT/accounts.d/lux-host-a2.conf"
  cat > "$ROOT/logins.d/lux-claude-max.conf" <<'LEOF'
PRINCIPAL="lux"
ACCOUNT="lux@example.test"
PROVIDER="claude-max"
CONFIG_DIR="~/.claude-logins/claude-max"
LEGAL_OWNER="lux"
LEOF
  chmod 600 "$ROOT/logins.d/lux-claude-max.conf"
  cat > "$ROOT/sessions.d/s-00000000000000lx.conf" <<LEOF
ID="s-00000000000000lx"
ACCOUNT="lux-host-a"
SLUG="acme-lux"
DOMAIN="acme"
HOST="host-a"
REPO_PATH="$FX/home/lux"
OWNER="lux"
PERMISSION_MODE="bypassPermissions"
LEOF
  printf 'NAME="Beta"\nMEMBERS="operator lux"\n' > "$ROOT/entities.d/beta.conf"
  printf 'OWNER="operator"\nLEGAL_OWNER="Acme Ltd"\nOPERATOR="operator"\n' > "$ROOT/hosts.d/host-h.conf"
  LNOW="$(date -u +%s)"
  cat > "$ROOT/invites.d/inv-0000000l.conf" <<LEOF
NAME="Lux"
PRINCIPAL="lux"
ENTITY="acme"
HOST="host-a"
RUNTIME="claude-code"
PROVIDER="claude-max"
TOKEN_SHA256="$(printf 'y' | { if command -v sha256sum >/dev/null 2>&1; then sha256sum; else shasum -a 256; fi; } | cut -d' ' -f1)"
ISSUED_BY="operator"
ISSUED_AT="$LNOW"
EXPIRES_AT="$((LNOW + 86400))"
STATE="redeemed"
REDEEMED_LOGIN="oidc:issuer-l:SUB-9"
REDEEMED_AT="$LNOW"
LEOF
  chmod 600 "$ROOT/invites.d/inv-0000000l.conf"
}
luxclean() {
  rm -f "$ROOT/accounts.d/lux-host-a.conf" "$ROOT/accounts.d/lux-host-a2.conf" \
        "$ROOT/principals.d/lux.conf" "$ROOT/logins.d/lux-claude-max.conf" \
        "$ROOT/sessions.d/s-00000000000000lx.conf" "$ROOT/entities.d/beta.conf" \
        "$ROOT/hosts.d/host-h.conf" "$ROOT/invites.d/inv-0000000l.conf" "$LUXR"
}
if [ "$(id -u)" = "0" ]; then
  echo "  SKIP the unreadable-row cases - this run is root, where mode 000 is still readable"
else
  for row in accounts.d/lux-host-a2.conf principals.d/lux.conf \
             sessions.d/s-00000000000000lx.conf logins.d/lux-claude-max.conf \
             hosts.d/host-h.conf entities.d/beta.conf invites.d/inv-0000000l.conf; do
    luxclean; luxseed
    chmod 000 "$ROOT/$row"
    : > "$FX/calls"
    out="$(run offboard lux 2>&1)"; rc=$?
    chmod 644 "$ROOT/$row" 2>/dev/null
    is  "an unreadable $row refuses, rc 78" "$rc" "78"
    has "and names the row it could not read ($row)" "$out" "$row"
    # WITHOUT THIS LINE the principals.d iteration passes by accident: the run
    # that walks past it prints "principals.d/lux.conf removed", which carries
    # the name too.
    has "and says it could not READ it ($row)" "$out" "is not a regular file this run can read"
    is  "and nothing was called at all ($row)" "$(wc -c < "$FX/calls" | tr -d ' ')" "0"
    have "the good account row is untouched ($row)" "$ROOT/accounts.d/lux-host-a.conf"
    have "the principal row is untouched ($row)" "$ROOT/principals.d/lux.conf"
    havenot "and no receipt was written ($row)" "$LUXR"
  done
fi
luxclean

echo "== an ABSENT register is a different answer from an unreadable one =="
# THE GATE'S CENTRAL CLAIM, ASSERTED RATHER THAN COMMENTED. Nothing that is not
# there can name anybody, so six of the seven registers may be missing and the
# cleanup still finishes and still writes a receipt that says so.
NR="$HUBHOME/.local/state/fixture-state/offboards/nia.receipt.json"
niaclean() { rm -f "$NR" "$ROOT/principals.d/nia.conf" "$ROOT/accounts.d/nia-host-a.conf"; }
for reg in accounts.d principals.d sessions.d logins.d hosts.d invites.d; do
  niaclean; newperson nia "Nia"
  mv "$ROOT/$reg" "$ROOT/$reg-aside"
  out="$(run offboard nia 2>&1)"; rc=$?
  mv "$ROOT/$reg-aside" "$ROOT/$reg"
  is  "an absent $reg is legitimate, rc 0" "$rc" "0"
  is  "and the offboarding finished ($reg)" "$(jq -r '.state // ""' "$NR" 2>/dev/null)" "done"
done
niaclean
# ENTITIES.D IS THE ONE EXCEPTION, and it is not a matter of taste:
# registry_entity_list REFUSES a directory that is not there, and it does so
# long after this gate - measured, it killed the run at rc 78 with a receipt in
# state "failed" AFTER the unix account was locked and its account row removed,
# and the second-run guard then answered rc 70 for that principal until
# somebody finished the cleanup by hand. A register this verb cannot do without
# is required AT THE GATE, where refusing still costs nothing.
newperson nia "Nia"
: > "$FX/calls"
mv "$ROOT/entities.d" "$ROOT/entities.d-aside"
out="$(run offboard nia 2>&1)"; rc=$?
mv "$ROOT/entities.d-aside" "$ROOT/entities.d"
is  "an absent entities.d refuses, rc 78" "$rc" "78"
has "and names the register it cannot do without" "$out" "entities.d"
is  "and nothing was called at all" "$(wc -c < "$FX/calls" | tr -d ' ')" "0"
have "the account row is untouched" "$ROOT/accounts.d/nia-host-a.conf"
have "the principal row is untouched" "$ROOT/principals.d/nia.conf"
havenot "and no receipt was written" "$NR"
niaclean

echo "== a run that stopped AFTER the rows is not a finished run =="
# THE SECOND RUN USED TO READ THE RECEIPT'S EXISTENCE AND NOTHING ELSE. A
# failure late in the order - here the helper's belt refusing to move a home
# across filesystems - leaves the register empty and the home in place, and the
# next run found no rows, found a receipt, and reported the person as cleanly
# gone. A cleanup that says "done" over an unarchived home is worse than one
# that refuses: it is the answer an operator re-runs precisely to be sure.
newperson hal "Hal"
: > "$FX/calls"
FX_REFUSE_ARCHIVE="1"
out="$(run offboard hal 2>&1)"; rc=$?
HR="$HUBHOME/.local/state/fixture-state/offboards/hal.receipt.json"
is  "a home the helper will not move fails the run, rc 70" "$rc" "70"
is  "the receipt says failed" "$(jq -r .state "$HR")" "failed"
havenot "and the rows are gone all the same" "$ROOT/principals.d/hal.conf"
if [ -d "$FX/home/hal" ]; then ok "while the home is still sitting there"; else bad "while the home is still sitting there" "gone"; fi
# THE HELPER SPEAKS IN MANY LINES - three receipts and then the refusal - and
# the receipt is built by splitting one accumulated string on newlines. Recorded
# verbatim, one refusal arrived as FOUR entries, three of them in a field named
# removed, telling the reader that "helper: password locked" was a thing this
# run had removed.
is  "the helper's four lines are one entry, not four" \
    "$(jq -r '[.warnings[]|select(startswith("stopped here:"))]|length' "$HR")" "1"
is  "and none of them became a removal" \
    "$(jq -r '[.removed[]|select(startswith("helper:"))]|length' "$HR")" "0"
is  "nor a warning of its own" \
    "$(jq -r '[.warnings[]|select(startswith("helper:"))]|length' "$HR")" "0"
has "the one entry still carries the helper's words" \
    "$(jq -r '.warnings|join(" ")' "$HR")" "different filesystems"
: > "$FX/calls"
out="$(run offboard hal 2>&1)"; rc=$?
FX_REFUSE_ARCHIVE=""
is  "the next run refuses rather than reporting it done, rc 70" "$rc" "70"
no  "and never says the person is cleanly gone" "$out" "nothing left to remove"
has "it names the receipt to read" "$out" "hal.receipt.json"
has "and the state that receipt is in" "$out" "failed"
has "and repeats where the first run stopped" "$out" "stopped here:"
is  "and it touched nothing" "$(wc -c < "$FX/calls" | tr -d ' ')" "0"
if [ -d "$FX/home/hal" ]; then ok "the home is still where the first run left it"; else bad "the home is still where the first run left it" "gone"; fi
rm -f "$HR"

echo "== a receipt that cannot be written fails the run =="
# THE RECEIPT IS THE SECOND-RUN GUARD. Swallowing a write failure leaves the
# register empty with nothing on disk that says so, and the next run reads that
# as a person who was never offboarded at all.
newperson hex "Hex"
printf 'ESTATE_NAME="acme"\nSTATE_DIR_NAME="fixture-blocked"\nHUB_SESSION="host-a"\nHUB_HOST="host-a"\nHUB_SSH="steward@host-a"\n' \
  > "$ROOT/estate/steward.conf"
: > "$HUBHOME/.local/state/fixture-blocked"   # a FILE where the state directory must be
out="$(run offboard hex 2>&1)"; rc=$?
is  "a receipt that cannot be written is rc 70" "$rc" "70"
has "and says which path it could not write" "$out" "receipt could not be written"
has "and that the rows went anyway" "$out" "fixture-blocked"
havenot "the principal row is gone all the same" "$ROOT/principals.d/hex.conf"
rm -f "$HUBHOME/.local/state/fixture-blocked"
printf 'ESTATE_NAME="acme"\nSTATE_DIR_NAME="fixture-state"\nHUB_SESSION="host-a"\nHUB_HOST="host-a"\nHUB_SSH="steward@host-a"\n' \
  > "$ROOT/estate/steward.conf"

printf '\n  %d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
