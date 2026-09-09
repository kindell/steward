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
# an EXACT argv line in the recorded log, field by field - a substring test
# would pass on an invocation that carried extra words
argv_has() { if grep -Fxq -- "$3" "$2" 2>/dev/null; then ok "$1"; else bad "$1" "no line exactly '$3'"; fi; }
FX="$(mktemp -d)"; trap 'rm -rf "$FX"' EXIT
echo "invite-redeem"

# -- the product tree -------------------------------------------------------
mkdir -p "$FX/product/bin" "$FX/product/lib" "$FX/product/linux" "$FX/product/desk/bin"
cp "$here/bin/steward"      "$FX/product/bin/steward"
cp "$here/lib/registry.sh"  "$FX/product/lib/registry.sh"
chmod 755 "$FX/product/bin/steward"
# deploy-self: the stub deploys a skeleton into EVERY home that has none, the
# way the real per-host verb does. It is also THE HOOK the two concurrency
# tests hang off: a file dropped by the test makes something else change the
# invitation WHILE this redemption is between step 1 and step 12, which is the
# only window a shim can reach from outside the process.
cat > "$FX/product/linux/deploy-self.sh" <<EOF
#!/bin/bash
echo "deploy-self \$*" >> "$FX/calls"
for h in "$FX"/home/*; do
  [ -d "\$h" ] || continue
  mkdir -p "\$h/scripts/lib"
  : > "\$h/scripts/lib/registry.sh"
done
if [ -f "$FX/hook-revoke" ]; then
  hid="\$(cat "$FX/hook-revoke")"; rm -f "$FX/hook-revoke"
  bash "$FX/product/bin/steward" invite revoke "\$hid" >/dev/null 2>&1
fi
if [ -f "$FX/hook-close" ]; then
  set -- \$(cat "$FX/hook-close"); rm -f "$FX/hook-close"
  hconf="\$STEWARD_ESTATE_ROOT/invites.d/\$1.conf"
  hbody="\$(grep -v '^STATE=' "\$hconf" | grep -v '^REDEEMED_')"
  { printf '%s\n' "\$hbody"
    printf 'STATE="redeemed"\nREDEEMED_LOGIN="%s"\nREDEEMED_AT="%s"\n' "\$2" "\$(date -u +%s)"
  } > "\$hconf"
fi
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

# sudo: records argv (once as a line for eyeballing, once pipe-separated so a
# test can assert one invocation EXACTLY), then EITHER models the helper OR
# runs the rest of the command locally. Modelling the helper is what makes the
# account appear, so a second run can find the mark and skip the step.
#
# FIX_SUDO_MODE is the fixture's own knob - nothing in the product reads it.
# It models the five ways this call can go wrong on a real host: sudo cannot
# execute the helper, sudo wants a password, the helper itself refuses, the
# helper answers with its usage banner, and sudo declines the -u runas the five
# in-home writes need.
#
# THE HELPER'S RECEIPTS GO TO STDERR, and this shim writes them where the real
# one does. That is not decoration: step 3 captures the call with 2>&1 and step
# 10 reads the fragment path back out of what it captured, so a capture that
# took stdout alone would find neither the receipts nor the refusals. Writing
# them on stdout here would let that regression through unseen.
cat > "$FX/bin/sudo" <<EOF
#!/bin/bash
echo "sudo \$*" >> "$FX/calls"
line="sudo"; for a in "\$@"; do line="\$line|\$a"; done
printf '%s\n' "\$line" >> "$FX/argv"
args=()
user=""
while [ \$# -gt 0 ]; do
  case "\$1" in
    -n) shift ;;
    -u) user="\$2"; shift 2 ;;
    *) args+=("\$1"); shift ;;
  esac
done
mode="\${FIX_SUDO_MODE:-normal}"
case "\${args[0]:-}" in
  */steward-account-helper)
    case "\$mode" in
      nohelper) echo "sudo: unable to execute \${args[0]}: No such file or directory" >&2; exit 1 ;;
      password) echo "sudo: a password is required" >&2; exit 1 ;;
      refuse)   echo "helper: REFUSING - '\${args[2]}' is a reserved account name" >&2; exit 64 ;;
      usage)    printf 'usage: steward-account-helper add <username>\n       steward-account-helper lock <username> [--archive-home]\n' >&2; exit 64 ;;
      # The helper's OTHER success, receipt for receipt: the account was already
      # in the database, so it configured nothing - no home, no mode, no groups,
      # no password lock, no lingering. Only the tmpfiles fragment is written in
      # both branches, because it is the helper's own file. \`existing\` leaves
      # the home as it found it (nothing there); \`existhome\` models the same
      # answer about an account whose home IS there.
      existing|existhome)
        [ "\$mode" = "existhome" ] && mkdir -p "$FX/home/\${args[2]}/.ssh"
        echo "helper: account \${args[2]} already exists" >&2
        echo "helper: home $FX/home/\${args[2]} left as it is (the mode is set only on a home this helper creates)" >&2
        echo "helper: groups, password and lingering left as is (this helper configures only an account it created)" >&2
        echo "helper: tmpfiles /etc/tmpfiles.d/steward-rig-\${args[2]}.conf" >&2
        exit 0 ;;
    esac
    mkdir -p "$FX/home/\${args[2]}/.ssh"
    echo "helper: account \${args[2]} created" >&2
    echo "helper: tmpfiles /etc/tmpfiles.d/steward-rig-\${args[2]}.conf" >&2
    exit 0 ;;
esac
if [ -n "\$user" ] && [ "\$mode" = "norunas" ]; then
  echo "sudo: sorry, this account is not allowed to run that command as \$user" >&2
  exit 1
fi
exec "\${args[@]}"
EOF
chmod 755 "$FX/bin/sudo"
cat > "$FX/bin/ssh-keygen" <<EOF
#!/bin/bash
echo "ssh-keygen \$*" >> "$FX/calls"
f=""; prev=""
for a in "\$@"; do [ "\$prev" = "-f" ] && f="\$a"; prev="\$a"; done
if [ -n "\$f" ]; then
  mkdir -p "\$(dirname "\$f")"
  printf 'PRIVATE\n' > "\$f"
  if [ "\${FIX_PUB_MODE:-}" = "twoline" ]; then
    printf 'ssh-ed25519 AAAANEWKEY new\nssh-ed25519 AAAAINJECTED elsewhere\n' > "\$f.pub"
  else
    printf 'ssh-ed25519 AAAANEWKEY new\n' > "\$f.pub"
  fi
fi
exit 0
EOF
chmod 755 "$FX/bin/ssh-keygen"
cat > "$FX/bin/ssh-keyscan" <<EOF
#!/bin/bash
echo "ssh-keyscan \$*" >> "$FX/calls"
[ "\${FIX_KEYSCAN:-}" = "empty" ] && exit 0
echo "|1|hashed|hashed ssh-ed25519 AAAAHOSTKEY"
exit 0
EOF
chmod 755 "$FX/bin/ssh-keyscan"
# mktemp: a pass-through that carries ONE hook. A bare `mktemp` (no template)
# is what the membership step asks for immediately after it has read the
# entity and before it takes the register's write lock - the window an entity
# change has to land in for the under-lock recheck to be the thing that
# catches it. Every other mktemp in the run passes a template, so the hook
# cannot fire on the wrong one.
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
# id: THE FIXTURE'S ACCOUNT DATABASE, and only for `id -u <name>`. Step 3 asks
# the floor's own questions about an account it did not create, and the first of
# them is "does this name already exist here" - a question that must be
# answerable without creating an account on the machine running the suite.
# `$FX/uids` holds `<name>:<uid>` lines; a name that is not in it is a name that
# does not exist, which is the ordinary case. EVERY OTHER FORM IS THE REAL id:
# the product also asks who is RUNNING (`id -un`), and the fixture's own
# operator row was written from that answer, so a shim that guessed there would
# break the estate rather than the case under test.
ID_REAL="$(command -v id)"
cat > "$FX/bin/id" <<EOF
#!/bin/bash
if [ "\${1:-}" = "-u" ] && [ \$# -eq 2 ]; then
  while IFS=: read -r n v; do
    [ "\$n" = "\$2" ] || continue
    printf '%s\n' "\$v"; exit 0
  done < "$FX/uids"
  echo "id: '\$2': no such user" >&2
  exit 1
fi
exec "$ID_REAL" "\$@"
EOF
chmod 755 "$FX/bin/id"
: > "$FX/uids"
: > "$FX/calls"
: > "$FX/argv"

# The fixture's knobs, all read by the shims above and by nothing else.
FIX_SUDO_MODE=""; FIX_PUB_MODE=""; FIX_KEYSCAN=""; FIX_ENTITY_DIR=""
run() {
  ( export PATH="$FX/bin:$PATH"
    export HOME="$HUBHOME"
    export STEWARD_ESTATE_ROOT="$ROOT"
    export STEWARD_CONFIG_FILE="$FX/no-such-config"
    export STEWARD_HOME_LOOKUP_CMD="$FX/bin/homelookup"
    export STEWARD_AUTHORIZED_KEYS="$HUBHOME/.ssh/authorized_keys"
    # THIS MACHINE IS THE HOST THE INVITATIONS NAME. Redemption acts locally -
    # helper, keys, seeds - so it refuses an invitation for another host, and
    # without this the fixture's own host slug would never match.
    export STEWARD_SELF_HOST="host-a"
    export FIX_SUDO_MODE FIX_PUB_MODE FIX_KEYSCAN
    [ -n "$FIX_ENTITY_DIR" ] && export STEWARD_ENTITY_DIR="$FIX_ENTITY_DIR"
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
has "step 10 names the fragment the helper placed" "$out" "10/12 rig-socket-dir: /etc/tmpfiles.d/steward-rig-alice.conf"
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
# THE HUB'S OWN LINE, READ FROM THE HUB'S OWN FILE. The assertion above reads
# the account's file, and the line that authorizes something on the machine
# running this verb is the other one: without `restrict,` it is a shell.
has "the hub's line opens with restrict" "$(head -1 "$HUBHOME/.ssh/authorized_keys")" "restrict,command=\"STEWARD_ESTATE_ROOT="
is  "and the hub's file gained exactly one line" "$(wc -l < "$HUBHOME/.ssh/authorized_keys" | tr -d ' ')" "1"

echo "== the five in-home writes went through sudo -n -u, argv for argv =="
AH="$FX/home/alice"
argv_has "the helper, as root" "$FX/argv" "sudo|-n|/usr/local/sbin/steward-account-helper|add|alice"
argv_has "the relay keygen, as the account" "$FX/argv" \
  "sudo|-n|-u|alice|ssh-keygen|-q|-t|ed25519|-N||-f|$AH/.ssh/id_busrelay_$sid|-C|host-a-alice-acme-alice"
argv_has "reading the relay public key" "$FX/argv" "sudo|-n|-u|alice|cat|$AH/.ssh/id_busrelay_$sid.pub"
argv_has "installing the delivery key" "$FX/argv" "sudo|-n|-u|alice|tee|-a|$AH/.ssh/authorized_keys"
argv_has "seeding known_hosts" "$FX/argv" "sudo|-n|-u|alice|tee|-a|$AH/.ssh/known_hosts"
argv_has "writing onboarding.env" "$FX/argv" "sudo|-n|-u|alice|tee|$AH/onboarding.env"

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
has "step 10 is named in this run too" "$out" "10/12 rig-socket-dir: already done"
has "the entity gained the second member" "$(cat "$ROOT/entities.d/acme.conf")" "bo"
calls="$(cat "$FX/calls")"
no  "and nothing re-created the account" "$calls" "steward-account-helper add bo"

# issue <principal> [more issue flags] - one invitation, leaving its token in
# TOK and its id in INVID. Every scenario below needs its own invitation, and
# an invitation is consumed by the run that redeems it.
issue() {
  local p="$1"; shift
  local o l
  o="$(run invite issue --name "$p Example" --principal "$p" --entity acme --host host-a "$@" 2>&1)"
  l="$(printf '%s\n' "$o" | grep -o 'https://desk.example.test/desk/invite/[A-Za-z0-9_-]*' | head -1)"
  TOK="${l##*/}"
  INVID="$(grep -l "PRINCIPAL=\"$p\"" "$ROOT"/invites.d/*.conf | tail -1)"
  INVID="$(basename "$INVID" .conf)"
  [ -n "$TOK" ] || bad "the fixture can issue for $p" "no link in: $o"
}

echo "== a revoke that lands mid-redemption is refused, not overwritten =="
# THE ROW IS SNAPSHOTTED AT STEP 1 AND THE SNAPSHOT IS WHAT STEP 12 COMPARES
# AGAINST, under the register's own write lock. Without that, step 12 re-reads
# the row it is about to close, sees the revoked state, and publishes over it -
# the verb would report success on an invitation somebody had just withdrawn.
issue tam
printf '%s\n' "$INVID" > "$FX/hook-revoke"
out="$(run invite redeem "$TOK" --identity oidc:issuer-t:SUB-T 2>&1)"; rc=$?
is  "a revoke landing during the run refuses, rc 70" "$rc" "70"
has "and says the invitation changed under it" "$out" "changed while redeeming"
has "the row is still revoked" "$(cat "$ROOT/invites.d/$INVID.conf")" 'STATE="revoked"'
no  "and no redemption was recorded on it" "$(cat "$ROOT/invites.d/$INVID.conf")" "REDEEMED_"

echo "== a relay .pub that is not one key line never reaches the hub =="
# The .pub is read out of the NEW account's home - a file that account's owner
# can write. A second line in it would be a second authorized_keys line on the
# hub, without the forced command, i.e. a shell on the machine that runs the
# estate.
issue rex
hub_before="$(cat "$HUBHOME/.ssh/authorized_keys")"
FIX_PUB_MODE="twoline"
out="$(run invite redeem "$TOK" --identity oidc:issuer-r:SUB-R 2>&1)"; rc=$?
FIX_PUB_MODE=""
is  "a two-line public key refuses, rc 70" "$rc" "70"
has "and names the file it refused" "$out" "id_busrelay_"
is  "the hub's authorized_keys is byte for byte what it was" "$(cat "$HUBHOME/.ssh/authorized_keys")" "$hub_before"
no  "and the second key never landed" "$(cat "$HUBHOME/.ssh/authorized_keys")" "AAAAINJECTED"

echo "== rc 77 is 'sudo could not run it', rc 70 is 'it ran and said no' =="
# The discriminator cannot be the exit status - sudo passes the command's
# through - so it is the output, and it has to be anchored: the helper's own
# binary name ENDS in "-helper", so sudo's "unable to execute
# /usr/local/sbin/steward-account-helper: ..." carries the substring "helper: "
# without a single line of the helper's in it.
issue mia
MR="$HUBHOME/.local/state/fixture-state/invites/$INVID.receipt.json"
FIX_SUDO_MODE="nohelper"
out="$(run invite redeem "$TOK" --identity oidc:issuer-m:SUB-M 2>&1)"; rc=$?
is  "sudo that cannot execute the helper is rc 77" "$rc" "77"
has "and the message names the sudoers line" "$out" "NOPASSWD"
has "and quotes sudo's own words" "$out" "unable to execute"
FIX_SUDO_MODE="password"
out="$(run invite redeem "$TOK" --identity oidc:issuer-m:SUB-M 2>&1)"; rc=$?
is  "sudo that wants a password is rc 77" "$rc" "77"
has "and quotes sudo's own words" "$out" "a password is required"
FIX_SUDO_MODE="refuse"
out="$(run invite redeem "$TOK" --identity oidc:issuer-m:SUB-M 2>&1)"; rc=$?
is  "a helper that ran and refused is rc 70" "$rc" "70"
has "and quotes the helper's own line" "$out" "helper: REFUSING"
no  "and does not send the operator to sudoers" "$out" "NOPASSWD"
# A USAGE BANNER IS THE HELPER SPEAKING TOO. Every OTHER thing the helper prints
# is prefixed "helper: ", but its usage text is not - and the helper answers
# with it, on rc 64, for a name it will not take and for a sub-command it does
# not have. Those are the two cases a caller passing a bad argument produces, so
# they are the likeliest refusals of the lot; both were reported as rc 77 "the
# estate has not installed the sudoers line", with the helper's own words quoted
# underneath as what sudo said. The reader is sent to /etc/sudoers to fix a host
# where the sudoers line is already working perfectly.
FIX_SUDO_MODE="usage"
out="$(run invite redeem "$TOK" --identity oidc:issuer-m:SUB-M 2>&1)"; rc=$?
is  "a helper that answered with its usage banner is rc 70" "$rc" "70"
has "and quotes the banner it printed" "$out" "usage: steward-account-helper"
has "and reports it as the helper refusing" "$out" "ran and refused"
no  "and does not send the operator to sudoers" "$out" "NOPASSWD"
no  "and does not attribute the helper's words to sudo" "$out" "sudo said"

echo "== the five in-home writes name sudo when sudo is what refused =="
# The spec's single sudoers line covers the helper and nothing else, so on a
# host configured to exactly that line every `sudo -n -u <user>` in step 8 and
# step 9 fails - and the operator used to be told the key could not be
# generated, with no mention of sudo anywhere.
FIX_SUDO_MODE="norunas"
out="$(run invite redeem "$TOK" --identity oidc:issuer-m:SUB-M 2>&1)"; rc=$?
is  "sudo refusing the runas is rc 77" "$rc" "77"
has "and names the right this host is missing" "$out" "sudo -n -u mia"
has "and quotes sudo's own words" "$out" "not allowed to run"
is  "the receipt says the run failed" "$(jq -r .state "$MR")" "failed"
has "and the receipt names sudo" "$(jq -r '.lines|join(" ")' "$MR")" "sudo"

echo "== a seed step that produced nothing is a failure, not a receipt =="
FIX_SUDO_MODE=""; FIX_KEYSCAN="empty"
out="$(run invite redeem "$TOK" --identity oidc:issuer-m:SUB-M 2>&1)"; rc=$?
is  "an ssh-keyscan that answered nothing is rc 70" "$rc" "70"
has "and names known_hosts" "$out" "known_hosts"
is  "and known_hosts holds nothing" "$(cat "$FX/home/mia/.ssh/known_hosts" 2>/dev/null | wc -c | tr -d ' ')" "0"
FIX_KEYSCAN=""
out="$(run invite redeem "$TOK" --identity oidc:issuer-m:SUB-M 2>&1)"; rc=$?
is  "the run that follows all of them finishes" "$rc" "0"
has "step 8 was already done" "$out" "8/12 bus: already done"
has "step 9 ran this time" "$out" "9/12 seeds:"

echo "== a token is never mistaken for a flag =="
# base64url's alphabet contains '-', so one minted token in sixty-four used to
# open with a hyphen - and the verb refused that perfectly valid link with
# "unknown flag", rc 64. The minter no longer produces one, and `--` is there
# for the tokens minted before it stopped.
dashy=0
for i in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20 21 22 23 24 25 26 27 28 29 30 31 32 \
         33 34 35 36 37 38 39 40 41 42 43 44 45 46 47 48 49 50 51 52 53 54 55 56 57 58 59 60 61 62 63 64; do
  t="$( . "$here/lib/registry.sh"; registry_invite_mint_token )"
  case "$t" in -*) dashy=$((dashy+1)) ;; esac
done
is  "sixty-four minted tokens, none opening with a hyphen" "$dashy" "0"
issue tok
out="$(run invite redeem --identity oidc:issuer-k:SUB-K -- "$TOK" 2>&1)"; rc=$?
is  "and a token handed over after -- is redeemed" "$rc" "0"

echo "== the token does not have to go through argv =="
# ON LINUX /proc/<pid>/cmdline IS WORLD-READABLE, and this verb runs on the very
# host where every invited member has an account: a positional token is a live
# one-time invitation link sitting in the process table for as long as the
# redemption takes, and anybody who runs `ps` during it can open that link and
# bind THEIR identity to the invited principal. The row has only ever held the
# digest and the receipt only the identity; this closes the last channel. The
# positional form is unchanged - it is the one for a human at a terminal.
issue fil
printf '%s\n' "$TOK" > "$FX/token-file"
: > "$FX/argv"; : > "$FX/calls"
out="$(run invite redeem --token-file "$FX/token-file" --identity oidc:issuer-z:SUB-F 2>&1)"; rc=$?
is  "a token read from a file redeems, rc 0" "$rc" "0"
no  "and the token reached no child's argv" "$(cat "$FX/argv" "$FX/calls")" "$TOK"
no  "and nothing the run printed carries it" "$out" "$TOK"
no  "and the receipt does not" "$(cat "$HUBHOME/.local/state/fixture-state/invites/$INVID.receipt.json")" "$TOK"
issue sam
: > "$FX/argv"; : > "$FX/calls"
out="$(printf '%s\n' "$TOK" | run invite redeem - --identity oidc:issuer-z:SUB-S 2>&1)"; rc=$?
is  "a token read from stdin redeems, rc 0" "$rc" "0"
no  "and the token reached no child's argv" "$(cat "$FX/argv" "$FX/calls")" "$TOK"
no  "and nothing the run printed carries it" "$out" "$TOK"
# AND EVERY WAY OF ASKING FOR A TOKEN THAT ISN'T THERE IS rc 64, before the
# register is opened at all.
out="$(run invite redeem --token-file "$FX/no-such-file" --identity oidc:issuer-z:SUB-Q 2>&1)"; rc=$?
is  "a token file that cannot be read refuses, rc 64" "$rc" "64"
has "and names the file" "$out" "no-such-file"
: > "$FX/empty-token"
out="$(run invite redeem --token-file "$FX/empty-token" --identity oidc:issuer-z:SUB-Q 2>&1)"; rc=$?
is  "an empty token file refuses, rc 64" "$rc" "64"
has "and says the first line is where the token goes" "$out" "first line"
out="$(run invite redeem --token-file "$FX" --identity oidc:issuer-z:SUB-Q 2>&1)"; rc=$?
is  "a token file that is a directory refuses, rc 64" "$rc" "64"
out="$(run invite redeem - --identity oidc:issuer-z:SUB-Q < /dev/null 2>&1)"; rc=$?
is  "'-' with nothing on stdin refuses, rc 64" "$rc" "64"
has "and says where it looked" "$out" "stdin"
out="$(run invite redeem --token-file 2>&1)"; rc=$?
is  "--token-file with no value refuses, rc 64" "$rc" "64"
out="$(run invite redeem --token-file "$FX/token-file" ALSO --identity oidc:issuer-z:SUB-Q 2>&1)"; rc=$?
is  "a file AND a positional token refuses, rc 64" "$rc" "64"
has "and says one at a time" "$out" "one token at a time"

echo "== an invitation for another machine is refused before anything is made =="
# Steps 3, 8, 9 and 10 all act on the LOCAL machine - the helper through local
# sudo, the account database, files under the local home - so an invitation
# naming another host would build the account here and only fall over at the
# skeleton deploy, with the account, the keys and the seeds already made.
printf 'OWNER="operator"\nLEGAL_OWNER="Acme Ltd"\nOPERATOR="operator"\n' > "$ROOT/hosts.d/host-b.conf"
issue fay --host host-b
: > "$FX/argv"
out="$(run invite redeem "$TOK" --identity oidc:issuer-f:SUB-F 2>&1)"; rc=$?
is  "an invitation for another host refuses, rc 65" "$rc" "65"
has "and names the host it is for" "$out" "host-b"
is  "and no sudo ran at all" "$(wc -l < "$FX/argv" | tr -d ' ')" "0"
if [ -e "$ROOT/principals.d/fay.conf" ]; then bad "and no principal row was written" "fay.conf exists"
else ok "and no principal row was written"; fi

echo "== a principal that exists with ANOTHER identity stops the resumed run =="
# The identity gate at step 1 answers "does somebody else hold this identity";
# this is the other half - does the principal this run is finishing actually
# carry the identity it is about to record in the invitation.
issue eli
printf 'NAME="Eli Example"\nOIDC_LOGIN="issuer-e:OTHER"\n' > "$ROOT/principals.d/eli.conf"
out="$(run invite redeem "$TOK" --identity oidc:issuer-e:SUB-E 2>&1)"; rc=$?
is  "a principal row that does not carry the identity refuses, rc 65" "$rc" "65"
has "and says which principal and why" "$out" "another identity"
has "and names the principal" "$out" "eli"

echo "== a membership change that lands mid-step is refused, not lost =="
# Two redemptions into the same entity, or an operator's own membership edit
# landing during one, used to end with one of the two memberships silently
# gone: the staged row was compared only against what THIS run intended.
issue uli
mkdir -p "$FX/home/uli/.ssh"
printf 'NAME="Uli Example"\nOIDC_LOGIN="issuer-u:SUB-U"\n' > "$ROOT/principals.d/uli.conf"
printf 'PRINCIPAL="uli"\nHOST="host-a"\nUSERNAME="uli"\n' > "$ROOT/accounts.d/uli-host-a.conf"
members_before="$(sed -n 's/^MEMBERS="\(.*\)"$/\1/p' "$ROOT/entities.d/acme.conf")"
printf '%s zoe\n' "$members_before" > "$FX/hook-entity"
out="$(run invite redeem "$TOK" --identity oidc:issuer-u:SUB-U 2>&1)"; rc=$?
is  "an entity that moved under the run refuses, rc 70" "$rc" "70"
has "and says the entity changed" "$out" "changed while redeeming"
has "the concurrent member is still a member" "$(cat "$ROOT/entities.d/acme.conf")" "zoe"
no  "and this run's member never landed" "$(cat "$ROOT/entities.d/acme.conf")" "uli"

echo "== a run whose every earlier mark is on disk does only step 12 =="
# The resumption design is "ask the machine, step by step" - so every step
# needs its already-done branch exercised, and the only way to reach the ones
# past step 4 is a fixture that places their marks by hand.
issue cy
mkdir -p "$FX/home/cy/.ssh" "$FX/home/cy/scripts/lib"
printf 'NAME="Cy Example"\nOIDC_LOGIN="issuer-c:SUB-C"\n' > "$ROOT/principals.d/cy.conf"
printf 'PRINCIPAL="cy"\nHOST="host-a"\nUSERNAME="cy"\n' > "$ROOT/accounts.d/cy-host-a.conf"
cy_members="$(sed -n 's/^MEMBERS="\(.*\)"$/\1/p' "$ROOT/entities.d/acme.conf")"
printf 'NAME="Acme"\nMEMBERS="%s cy"\n' "$cy_members" > "$ROOT/entities.d/acme.conf"
run registry login add cy-claude-max --principal cy --account cy@example.test \
    --provider claude-max --config-dir '~/.claude-logins/claude-max' --legal-owner cy >/dev/null 2>&1
cy_sess="$(run registry session add --account cy-host-a --entity acme --slug acme-cy \
           --repo "$FX/home/cy" --host host-a --login cy-claude-max --json 2>/dev/null)"
csid="$(printf '%s' "$cy_sess" | jq -r '.id // empty' 2>/dev/null)"
: > "$FX/home/cy/.ssh/id_busrelay_$csid"
printf 'restrict,command="seeded bus-relay-in %s" ssh-ed25519 AAAACY cy\n' "$csid" >> "$HUBHOME/.ssh/authorized_keys"
printf 'restrict,command="seeded bus-relay-deliver" ssh-ed25519 AAAAHUBKEY hub\n' > "$FX/home/cy/.ssh/authorized_keys"
printf 'seeded\n' > "$FX/home/cy/.ssh/known_hosts"
printf 'STEWARD_ESTATE_ROOT=seeded\n' > "$FX/home/cy/onboarding.env"
: > "$FX/home/cy/scripts/lib/registry.sh"
: > "$FX/calls"
out="$(run invite redeem "$TOK" --identity oidc:issuer-c:SUB-C 2>&1)"; rc=$?
is  "the fully marked run succeeds" "$rc" "0"
has "step 2 already done" "$out" "2/12 principal: already done"
has "step 3 already done" "$out" "3/12 account-unix: already done"
has "step 4 already done" "$out" "4/12 account: already done"
has "step 5 already done" "$out" "5/12 membership: already done"
has "step 6 already done" "$out" "6/12 login: already done"
has "step 7 already done, by the id it minted last time" "$out" "7/12 session: already done ($csid)"
has "step 8 already done" "$out" "8/12 bus: already done"
has "step 9 already done" "$out" "9/12 seeds: already done"
has "step 10 already done" "$out" "10/12 rig-socket-dir: already done"
has "step 11 already done" "$out" "11/12 skeleton: already done"
has "and step 12 still closed the row" "$out" "12/12 invitation: $INVID redeemed"
no  "and nothing on the host was touched" "$(cat "$FX/calls")" "steward-account-helper add cy"

echo "== an invitation closed under the run BY THIS IDENTITY is already done =="
issue dee
printf '%s oidc:issuer-d:SUB-D\n' "$INVID" > "$FX/hook-close"
out="$(run invite redeem "$TOK" --identity oidc:issuer-d:SUB-D 2>&1)"; rc=$?
is  "a row that reached the wanted state on its own is rc 0" "$rc" "0"
has "and step 12 reports already done" "$out" "12/12 invitation: already done"

echo "== every rc 65 this verb can reach =="
issue gus
out="$(run invite redeem "$TOK" --identity oidc:issuer-a:SUB-1 2>&1)"; rc=$?
is  "an identity that belongs to somebody else refuses, rc 65" "$rc" "65"
has "and names who holds it" "$out" "alice"
printf 'NAME="One"\nOIDC_LOGIN="issuer-q:DUP"\n' > "$ROOT/principals.d/dup-one.conf"
printf 'NAME="Two"\nOIDC_LOGIN="issuer-q:DUP"\n' > "$ROOT/principals.d/dup-two.conf"
out="$(run invite redeem "$TOK" --identity oidc:issuer-q:DUP 2>&1)"; rc=$?
is  "an identity that maps to two principals refuses, rc 65" "$rc" "65"
has "and refuses to pick" "$out" "more than one"
rm -f "$ROOT/principals.d/dup-one.conf" "$ROOT/principals.d/dup-two.conf"
issue hal --runtime codex
out="$(run invite redeem "$TOK" --identity oidc:issuer-h:SUB-H 2>&1)"; rc=$?
is  "a runtime the session writer cannot finish refuses, rc 65" "$rc" "65"
has "and names the runtime" "$out" "codex"
issue jay
run invite revoke "$INVID" >/dev/null 2>&1
out="$(run invite redeem "$TOK" --identity oidc:issuer-j:SUB-J 2>&1)"; rc=$?
is  "a revoked invitation refuses, rc 65" "$rc" "65"
has "and says which state it is in" "$out" "revoked"
issue kip
kconf="$ROOT/invites.d/$INVID.conf"
kbody="$(grep -v '^EXPIRES_AT=' "$kconf")"
{ printf '%s\n' "$kbody"; printf 'EXPIRES_AT="1000000000"\n'; } > "$kconf"
out="$(run invite redeem "$TOK" --identity oidc:issuer-p:SUB-P 2>&1)"; rc=$?
is  "an expired invitation refuses, rc 65" "$rc" "65"
has "and says which state it is in" "$out" "expired"

echo "== an invitation may not take over an account this product did not create =="
# STEP 3'S MARK IS "A HOME EXISTS", so an account already on the host skips the
# helper - and with it the floor the helper applies to every account it makes:
# root, the calling account, a system uid, a home outside /home/<name>. The
# floor's own comment says why it exists ("an account holding nothing but the
# sudoers line can expire root"), and redemption is this product's OTHER
# privileged path into an account. Measured before this gate: an invitation
# naming `root` wrote a principal row and an account row for it, and went on to
# install the hub's delivery key in its home. The four questions are asked here
# or they are asked nowhere.
printf 'root:0\n' > "$FX/uids"
issue root
: > "$FX/calls"
out="$(run invite redeem "$TOK" --identity oidc:issuer-z:SUB-Z 2>&1)"; rc=$?
is  "an invitation naming root refuses, rc 65" "$rc" "65"
has "and names the floor" "$out" "not an account this product may take over"
is  "and nothing was called at all" "$(wc -c < "$FX/calls" | tr -d ' ')" "0"
if [ -e "$ROOT/accounts.d/root-host-a.conf" ]; then bad "and no account row was written" "root-host-a.conf exists"
else ok "and no account row was written"; fi
rm -f "$ROOT/principals.d/root.conf"
# A SYSTEM UID IS THE SAME ANSWER UNDER ANOTHER NAME - the helper refuses
# uid < 1000, and an account that skipped the helper must meet the same bar.
printf 'root:0\nsvc:71\n' > "$FX/uids"
issue svc
: > "$FX/calls"
out="$(run invite redeem "$TOK" --identity oidc:issuer-z:SUB-Y 2>&1)"; rc=$?
is  "an invitation naming a system uid refuses, rc 65" "$rc" "65"
has "and names the uid it read" "$out" "uid 71"
is  "and nothing was called at all" "$(wc -c < "$FX/calls" | tr -d ' ')" "0"
rm -f "$ROOT/principals.d/svc.conf"
# AND A HOME OUTSIDE /home/<name> IS THE FOURTH QUESTION. The helper will only
# ever have made an account at /home/<name>, so a home anywhere else is an
# account somebody else made.
printf 'root:0\nsvc:71\nmel:4242\n' > "$FX/uids"
issue mel
: > "$FX/calls"
out="$(run invite redeem "$TOK" --identity oidc:issuer-z:SUB-X 2>&1)"; rc=$?
is  "an account whose home is not /home/<name> refuses, rc 65" "$rc" "65"
has "and names the home it read" "$out" "$FX/home/mel"
is  "and nothing was called at all" "$(wc -c < "$FX/calls" | tr -d ' ')" "0"
rm -f "$ROOT/principals.d/mel.conf"
# AND THE ORDINARY CASE IS UNTOUCHED: a name that is not an account yet is the
# account this run is about to create, and the helper's own floor answers for
# it.
: > "$FX/uids"
issue nel
out="$(run invite redeem "$TOK" --identity oidc:issuer-z:SUB-N 2>&1)"; rc=$?
is  "an account this run creates is untouched by the floor, rc 0" "$rc" "0"
has "and step 3 says it created it" "$out" "3/12 account-unix: nel created"

echo "== a helper that changed nothing did not create anything =="
# OFFBOARD NEVER DELETES THE PASSWD ROW - it expires, locks and archives the
# home - so a later redemption for the same principal finds a home PATH with
# nothing at it, calls the helper, and the helper's already-exists branch by
# design does not unlock the password, re-enable lingering or recreate the home.
# The receipt used to say "<p> created, home /home/<p>" about an account nothing
# created, that is still locked, and whose home is not there; the run then died
# at step 8's ssh-keygen. (The fixture reaches this through a name the account
# database does not know, so the floor above stays out of the way; on a real
# host the offboarded account's passwd row still says /home/<p> and passes it.)
FIX_SUDO_MODE="existing"
issue rob
: > "$FX/calls"
out="$(run invite redeem "$TOK" --identity oidc:issuer-z:SUB-R 2>&1)"; rc=$?
FIX_SUDO_MODE=""
is  "a helper that configured nothing and left no home is rc 70" "$rc" "70"
no  "and nothing in it claims the account was created" "$out" "created, home"
has "and it says the home is not there" "$out" "is not there"
has "and names the likely cause" "$out" "offboarded account"
if [ -e "$ROOT/accounts.d/rob-host-a.conf" ]; then bad "and no account row was written" "rob-host-a.conf exists"
else ok "and no account row was written"; fi
rm -f "$ROOT/principals.d/rob.conf"
# AND WHEN THE HOME IS THERE, THE RECEIPT SAYS WHICH OF THE TWO ANSWERS THE
# HELPER GAVE. Only "helper: account <u> created" is a creation; everything else
# it can say on rc 0 is an account that was already there.
FIX_SUDO_MODE="existhome"
issue rio
out="$(run invite redeem "$TOK" --identity oidc:issuer-z:SUB-I 2>&1)"; rc=$?
FIX_SUDO_MODE=""
is  "a helper that found the account and its home finishes, rc 0" "$rc" "0"
has "and the receipt says it already existed" "$out" "3/12 account-unix: rio already existed, home"
no  "and never that it was created" "$out" "rio created"

echo "== a register that cannot be read is rc 78, never 'empty' =="
issue vic
mkdir -p "$FX/home/vic/.ssh"
printf 'NAME="Vic Example"\nOIDC_LOGIN="issuer-v:SUB-V"\n' > "$ROOT/principals.d/vic.conf"
printf 'PRINCIPAL="vic"\nHOST="host-a"\nUSERNAME="vic"\n' > "$ROOT/accounts.d/vic-host-a.conf"
FIX_ENTITY_DIR="$FX/no-such-entities"
out="$(run invite redeem "$TOK" --identity oidc:issuer-v:SUB-V 2>&1)"; rc=$?
FIX_ENTITY_DIR=""
is  "a missing entity register refuses, rc 78" "$rc" "78"
has "and names the entity it wanted" "$out" "acme"
cp "$ROOT/entities.d/acme.conf" "$FX/acme.bak"
printf 'NAME="Acme"\nMEMBERS="never closed\n' > "$ROOT/entities.d/acme.conf"
out="$(run invite redeem "$TOK" --identity oidc:issuer-v:SUB-V 2>&1)"; rc=$?
cp "$FX/acme.bak" "$ROOT/entities.d/acme.conf"
is  "an entity row that does not parse refuses, rc 78" "$rc" "78"
has "and the refusal is this verb's, prefixed" "$out" "steward invite redeem:"
cp "$ROOT/estate/steward.conf" "$FX/estate.bak"
printf 'STATE_DIR_NAME="not a name"\n' >> "$ROOT/estate/steward.conf"
out="$(run invite redeem "$TOK" --identity oidc:issuer-v:SUB-V 2>&1)"; rc=$?
cp "$FX/estate.bak" "$ROOT/estate/steward.conf"
is  "an estate value this verb needs and cannot read refuses, rc 78" "$rc" "78"
has "and that refusal is prefixed too" "$out" "steward invite redeem:"

echo "== --json is exactly one JSON value on stdout, refusal or not =="
issue eve
printf 'NAME="Eve Example"\nOIDC_LOGIN="issuer-w:OTHER"\n' > "$ROOT/principals.d/eve.conf"
out="$(run invite redeem "$TOK" --identity oidc:issuer-w:SUB-W --json 2>/dev/null)"; rc=$?
is  "a refusal after step 1 keeps its rc" "$rc" "65"
is  "and stdout is one line" "$(printf '%s\n' "$out" | wc -l | tr -d ' ')" "1"
is  "and it is the refusal shape" "$(printf '%s' "$out" | jq -r .ok 2>/dev/null)" "false"
has "carrying the reason" "$(printf '%s' "$out" | jq -r .reason 2>/dev/null)" "another identity"
issue ida
out="$(run invite redeem "$TOK" --identity oidc:issuer-x:SUB-X --json 2>/dev/null)"; rc=$?
is  "a --json redemption succeeds" "$rc" "0"
is  "and stdout is one line, not twelve receipt lines and a value" "$(printf '%s\n' "$out" | wc -l | tr -d ' ')" "1"
is  "and it names the verb" "$(printf '%s' "$out" | jq -r .kind 2>/dev/null)" "redeem"
is  "and the receipt still carries all twelve lines" \
    "$(jq -r '.lines | length' "$HUBHOME/.local/state/fixture-state/invites/$INVID.receipt.json")" "12"

printf '\n  %d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
