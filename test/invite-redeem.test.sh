#!/bin/bash
# test/invite-redeem.test.sh - redemption, end to end, with every host-touching
# command replaced by a shim that records its argv. Nothing here creates an
# account, generates a real key, reaches a network or runs systemd.
#
# THE FIXTURE CARRIES ITS OWN PRODUCT TREE, the same technique
# test/deploy-self.test.sh uses: bin/steward resolves its own root, so the copy
# under the fixture is what runs and its linux/deploy-self.sh and
# desk/snapshot.sh are stubs that record instead of act.
set -u
here="$(CDPATH= cd -- "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
pass=0; fail=0
ok()  { pass=$((pass+1)); printf '  ok   %s\n' "$1"; }
bad() { fail=$((fail+1)); printf '  FAIL %s\n     %s\n' "$1" "${2:-}"; }
is()  { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "wanted '$3', got '$2'"; fi; }
has() { case "$2" in *"$3"*) ok "$1" ;; *) bad "$1" "missing '$3' in: $2" ;; esac; }
no()  { case "$2" in *"$3"*) bad "$1" "found '$3' in: $2" ;; *) ok "$1" ;; esac; }
FX="$(mktemp -d)"; trap 'rm -rf "$FX"' EXIT
echo "invite-redeem"

# -- the product tree -------------------------------------------------------
mkdir -p "$FX/product/bin" "$FX/product/lib" "$FX/product/linux" "$FX/product/desk/bin"
cp "$here/bin/steward"      "$FX/product/bin/steward"
cp "$here/lib/registry.sh"  "$FX/product/lib/registry.sh"
chmod 755 "$FX/product/bin/steward"
cat > "$FX/product/linux/deploy-self.sh" <<EOF
#!/bin/bash
echo "deploy-self \$*" >> "$FX/calls"
mkdir -p "$FX/home/alice/scripts/lib"
: > "$FX/home/alice/scripts/lib/registry.sh"
exit 0
EOF
cat > "$FX/product/desk/snapshot.sh" <<EOF
#!/bin/bash
echo "snapshot \$*" >> "$FX/calls"
exit 0
EOF
chmod 755 "$FX/product/linux/deploy-self.sh" "$FX/product/desk/snapshot.sh"
S="$FX/product/bin/steward"

# -- the estate -------------------------------------------------------------
ROOT="$FX/estate"
mkdir -p "$ROOT/invites.d" "$ROOT/entities.d" "$ROOT/hosts.d" "$ROOT/principals.d" \
         "$ROOT/accounts.d" "$ROOT/logins.d" "$ROOT/sessions.d" "$ROOT/estate"
# THE WHOLE ESTATE FILE, not only the keys this verb reads: step 7 writes a
# session row and the writer READS IT BACK through registry_load, which resolves
# the estate's label prefixes, socket and token name. A fixture that named only
# DESK_ORIGIN and the hub failed there with "wrote it but it does not load back"
# - a refusal about the fixture, wearing the shape of a refusal about the code.
cat > "$ROOT/estate/steward.conf" <<'EOF'
ESTATE_NAME="acme"
SCHEMA_VERSION="4"
DESK_ORIGIN="https://desk.example.test"
LABEL_PREFIX="com.fixture.claude"
RC_LABEL_PREFIX="fixture: "
STATE_DIR_NAME="fixture-state"
PAUSED_DIR_NAME="fixture-paused"
JOB_LOG_DIR="fixture-jobs"
TMUX_SOCKET="fixture.sock"
PING_MSG="you have mail"
JOB_LABEL_PREFIX="com.fixture.job"
SERVICE_LABEL_PREFIX="com.fixture.service"
BROWSER_LABEL_PREFIX="com.fixture.browser"
OP_TOKEN_FILE_NAME="fixture-token"
HUB_SESSION="host-a"
HUB_HOST="host-a"
HUB_SSH="steward@host-a"
EOF
printf 'NAME="Acme"\nMEMBERS="operator"\n' > "$ROOT/entities.d/acme.conf"
printf 'OWNER="operator"\nLEGAL_OWNER="Acme Ltd"\nOPERATOR="operator"\n' > "$ROOT/hosts.d/host-a.conf"
printf 'NAME="Operator"\nTAILSCALE_LOGIN="login-op@example.test"\n' > "$ROOT/principals.d/operator.conf"
printf 'PRINCIPAL="operator"\nHOST="host-a"\nUSERNAME="%s"\n' "$(id -un)" > "$ROOT/accounts.d/operator-host-a.conf"

# -- the hub's own home -----------------------------------------------------
HUBHOME="$FX/hubhome"
mkdir -p "$HUBHOME/.ssh" "$HUBHOME/scripts/bus/bin"
: > "$HUBHOME/.ssh/authorized_keys"
printf 'ssh-ed25519 AAAAHUBKEY hub\n' > "$HUBHOME/.ssh/id_ed25519.pub"
: > "$HUBHOME/scripts/bus/bin/bus-relay-in"

# -- the home lookup and the shims ------------------------------------------
mkdir -p "$FX/bin" "$FX/home"
cat > "$FX/bin/homelookup" <<EOF
#!/bin/bash
echo "$FX/home/\$1"
EOF
chmod 755 "$FX/bin/homelookup"

# sudo: records argv, then EITHER models the helper OR runs the rest of the
# command locally. Modelling the helper is what makes the account appear, so a
# second run can find the mark and skip the step.
cat > "$FX/bin/sudo" <<EOF
#!/bin/bash
echo "sudo \$*" >> "$FX/calls"
args=()
user=""
while [ \$# -gt 0 ]; do
  case "\$1" in
    -n) shift ;;
    -u) user="\$2"; shift 2 ;;
    *) args+=("\$1"); shift ;;
  esac
done
case "\${args[0]:-}" in
  */steward-account-helper)
    mkdir -p "$FX/home/\${args[2]}/.ssh"
    echo "helper: account \${args[2]} created"
    echo "helper: tmpfiles /etc/tmpfiles.d/steward-rig-\${args[2]}.conf"
    exit 0 ;;
esac
exec "\${args[@]}"
EOF
chmod 755 "$FX/bin/sudo"
cat > "$FX/bin/ssh-keygen" <<EOF
#!/bin/bash
echo "ssh-keygen \$*" >> "$FX/calls"
f=""; prev=""
for a in "\$@"; do [ "\$prev" = "-f" ] && f="\$a"; prev="\$a"; done
[ -n "\$f" ] && { mkdir -p "\$(dirname "\$f")"; printf 'PRIVATE\n' > "\$f"; printf 'ssh-ed25519 AAAANEWKEY new\n' > "\$f.pub"; }
exit 0
EOF
chmod 755 "$FX/bin/ssh-keygen"
cat > "$FX/bin/ssh-keyscan" <<EOF
#!/bin/bash
echo "ssh-keyscan \$*" >> "$FX/calls"
echo "|1|hashed|hashed ssh-ed25519 AAAAHOSTKEY"
exit 0
EOF
chmod 755 "$FX/bin/ssh-keyscan"
: > "$FX/calls"

run() {
  ( export PATH="$FX/bin:$PATH"
    export HOME="$HUBHOME"
    export STEWARD_ESTATE_ROOT="$ROOT"
    export STEWARD_CONFIG_FILE="$FX/no-such-config"
    export STEWARD_HOME_LOOKUP_CMD="$FX/bin/homelookup"
    export STEWARD_AUTHORIZED_KEYS="$HUBHOME/.ssh/authorized_keys"
    bash "$S" "$@" )
}

# -- issue, then redeem -----------------------------------------------------
out="$(run invite issue --name "Alice Example" --principal alice --entity acme --host host-a 2>&1)"
is  "the fixture can issue" "$?" "0"
link="$(printf '%s\n' "$out" | grep -o 'https://desk.example.test/desk/invite/[A-Za-z0-9_-]*' | head -1)"
TOKEN="${link##*/}"
INV="$(ls "$ROOT/invites.d" | sed 's/\.conf$//' | head -1)"

out="$(run invite redeem "$TOKEN" --identity oidc:issuer-a:SUB-1 --email alice@example.test 2>&1)"; rc=$?
is  "redeem succeeds" "$rc" "0"
has "step 1 names the invitation" "$out" "1/12"
has "step 12 closes the row" "$out" "12/12"

echo "== the rows redemption wrote =="
has "a principal row, bound to the identity" "$(cat "$ROOT/principals.d/alice.conf")" 'OIDC_LOGIN="issuer-a:SUB-1"'
has "and the display email" "$(cat "$ROOT/principals.d/alice.conf")" 'OIDC_EMAIL="alice@example.test"'
has "an account row" "$(cat "$ROOT/accounts.d/alice-host-a.conf")" 'PRINCIPAL="alice"'
has "the entity gained the member" "$(cat "$ROOT/entities.d/acme.conf")" 'MEMBERS="operator alice"'
has "a login row" "$(cat "$ROOT/logins.d/alice-claude-max.conf")" 'PROVIDER="claude-max"'
has "the login names the directory by the tilde form" "$(cat "$ROOT/logins.d/alice-claude-max.conf")" 'CONFIG_DIR="~/.claude-logins/claude-max"'
sess="$(grep -l 'SLUG="acme-alice"' "$ROOT"/sessions.d/*.conf | head -1)"
if [ -n "$sess" ]; then ok "a session row for the first session"; else bad "a session row for the first session" "none found"; fi
sid="$(basename "$sess" .conf)"
has "the session rides the login" "$(cat "$sess")" "LOGIN=\"alice-claude-max\""

echo "== the bus enrolment =="
if [ -f "$FX/home/alice/.ssh/id_busrelay_$sid" ]; then ok "a relay key under the session id"; else bad "a relay key under the session id" "missing"; fi
has "the hub carries the relay row" "$(cat "$HUBHOME/.ssh/authorized_keys")" "bus-relay-in $sid\""
has "and the row carries the estate root" "$(cat "$HUBHOME/.ssh/authorized_keys")" "STEWARD_ESTATE_ROOT=$ROOT"
has "the account carries the delivery key" "$(cat "$FX/home/alice/.ssh/authorized_keys")" "bus-relay-deliver"
has "and it is the hub's key" "$(cat "$FX/home/alice/.ssh/authorized_keys")" "AAAAHUBKEY"
has "restrict on both" "$(cat "$FX/home/alice/.ssh/authorized_keys")" "restrict,command="

echo "== the seeds the first ssh needs =="
has "the hub's host key is in known_hosts" "$(cat "$FX/home/alice/.ssh/known_hosts")" "AAAAHOSTKEY"
has "onboarding.env names the estate root" "$(cat "$FX/home/alice/onboarding.env")" "STEWARD_ESTATE_ROOT=$ROOT"
has "and the hub" "$(cat "$FX/home/alice/onboarding.env")" "STEWARD_HUB_SSH=steward@host-a"

echo "== the host-touching commands were all shims =="
calls="$(cat "$FX/calls")"
has "the helper was called through sudo -n" "$calls" "steward-account-helper add alice"
has "the skeleton was deployed" "$calls" "deploy-self host-a"
has "the desk was snapshotted" "$calls" "snapshot"

echo "== the receipt =="
R="$HUBHOME/.local/state/fixture-state/invites/$INV.receipt.json"
if [ -f "$R" ]; then ok "a receipt file was written"; else bad "a receipt file was written" "no $R"; fi
is  "the receipt is mode 600" "$(stat -c %a "$R" 2>/dev/null || stat -f %Lp "$R")" "600"
is  "the receipt is done" "$(jq -r .state "$R")" "done"
is  "the receipt carries twelve lines" "$(jq -r '.lines | length' "$R")" "12"
no  "and never the token" "$(cat "$R")" "$TOKEN"

echo "== the invitation is closed =="
has "the row is redeemed" "$(cat "$ROOT/invites.d/$INV.conf")" 'STATE="redeemed"'
has "and names the bound identity" "$(cat "$ROOT/invites.d/$INV.conf")" 'REDEEMED_LOGIN="oidc:issuer-a:SUB-1"'
no  "and still holds no token" "$(cat "$ROOT/invites.d/$INV.conf")" "$TOKEN"

echo "== the same token cannot be used twice =="
out="$(run invite redeem "$TOKEN" --identity oidc:issuer-a:SUB-2 2>&1)"; rc=$?
is  "a redeemed invitation refuses, rc 65" "$rc" "65"
has "and says which state it is in" "$out" "redeemed"
out="$(run invite redeem not-a-real-token --identity oidc:issuer-a:SUB-2 2>&1)"; rc=$?
is  "an unknown token refuses, rc 65" "$rc" "65"
out="$(run invite redeem "$TOKEN" --identity nonsense:x 2>&1)"; rc=$?
is  "an unknown identity source refuses, rc 64" "$rc" "64"

echo "== resumable: a redemption interrupted after step 4 continues, not restarts =="
out="$(run invite issue --name "Bo Example" --principal bo --entity acme --host host-a 2>&1)"
link2="$(printf '%s\n' "$out" | grep -o 'https://desk.example.test/desk/invite/[A-Za-z0-9_-]*' | head -1)"
TOKEN2="${link2##*/}"
INV2="$(grep -l 'PRINCIPAL="bo"' "$ROOT"/invites.d/*.conf | head -1)"
INV2="$(basename "$INV2" .conf)"
# Simulate an interrupted run: the first four marks are placed by hand.
mkdir -p "$FX/home/bo/.ssh"
printf 'NAME="Bo Example"\nOIDC_LOGIN="issuer-b:SUB-9"\n' > "$ROOT/principals.d/bo.conf"
printf 'PRINCIPAL="bo"\nHOST="host-a"\nUSERNAME="bo"\n' > "$ROOT/accounts.d/bo-host-a.conf"
: > "$FX/calls"
out="$(run invite redeem "$TOKEN2" --identity oidc:issuer-b:SUB-9 2>&1)"; rc=$?
is  "the resumed redemption succeeds" "$rc" "0"
has "step 2 was already done" "$out" "2/12 principal: already done"
has "step 4 was already done" "$out" "4/12 account: already done"
has "step 5 still ran" "$out" "5/12 membership:"
has "the entity gained the second member" "$(cat "$ROOT/entities.d/acme.conf")" "bo"
calls="$(cat "$FX/calls")"
no  "and nothing re-created the account" "$calls" "steward-account-helper add bo"

printf '\n  %d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
