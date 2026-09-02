#!/bin/bash
# test/registry-login-verb.test.sh — `steward registry login add/ls`, the
# writer for the login register.
#
# THE WRITER IS NOT REIMPLEMENTED HERE. registry_login_write is a thin
# wrapper over the SAME transaction test/registry-org-verbs.test.sh already
# proves adversarially (lock, stage, chmod-hard-refuse, no-clobber publish,
# canonical readback, fail-closed rollback) — this suite does not repeat that
# matrix. What IS specific to this verb, and therefore IS proved here:
#
#   - _registry_validate_login_stage is the ONE stage validator in bin/steward
#     that does NOT source what it validates — its four neighbours source a
#     row they just serialised themselves, which is safe because this
#     register's own readers do not source. A validator that sourced would be
#     the single place in the chain where a login row gets EXECUTED.
#   - --config-dir is checked against the grammar BEFORE the write, and
#     --provider against the closed vocabulary BEFORE the write — a verb
#     whose only defence is the reader's later refusal would publish rubbish
#     that looks like data.
#   - the resolved-directory collision is caught by registry_login_check
#     inside the stage validator, UNDER THE REGISTER'S WRITE LOCK — the one
#     moment a refusal costs nothing because the stage was never published.
#
# HERMETIC: a fresh mktemp estate per run, STEWARD_CONFIG_FILE pinned to a
# path that cannot exist. Fixtures: principal "alice", account
# "acct-acme-team" — deliberately not an e-mail address, since the account
# field is the account's name on whatever provider it belongs to, not
# necessarily an address.
set -u

here="$(CDPATH= cd -- "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
STEWARD="$here/bin/steward"
pass=0; fail=0
ok()  { pass=$((pass+1)); printf '  ok   %s\n' "$1"; }
bad() { fail=$((fail+1)); printf '  FAIL %s\n     %s\n' "$1" "${2:-}"; }
is()    { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "wanted '$3', got '$2'"; fi; }
has()   { case "$2" in *"$3"*) ok "$1" ;; *) bad "$1" "missing '$3' in: $2" ;; esac; }
absent(){ if [ ! -e "$2" ]; then ok "$1"; else bad "$1" "unexpectedly exists: $2"; fi; }

FX="$(mktemp -d)"; trap 'rm -rf "$FX"' EXIT
mkdir -p "$FX/estate" "$FX/logins.d"
LOGINS="$FX/logins.d"

# THE ESTATE FILE — the same required-key set the neighbouring registry-verb
# suites fill out, plus LEGACY_LOGIN: the one estate value this verb's own
# grammar check reads before a write. A half-built estate would turn every
# refusal below into a fixture bug instead of a measurement of the verb.
cat > "$FX/estate/steward.conf" <<'EOF'
ESTATE_NAME="fixture"
SCHEMA_VERSION="4"
LABEL_PREFIX="com.fixture.claude"
RC_LABEL_PREFIX="fixture: "
HUB_SESSION="fixture-hub"
HUB_HOST="h1"
HUB_SSH="a@h1"
JOB_LOG_DIR="fixture-jobs"
TMUX_SOCKET="fixture.sock"
PING_MSG="you have mail"
STATE_DIR_NAME="fixture-supervisor"
PAUSED_DIR_NAME="fixture-paused"
JOB_LABEL_PREFIX="com.fixture.job"
SERVICE_LABEL_PREFIX="com.fixture.service"
BROWSER_LABEL_PREFIX="com.fixture.browser"
OP_TOKEN_FILE_NAME="fixture-token"
LEGACY_LOGIN="oldschool"
EOF

# run <args...> — a hermetic invocation. STEWARD_CONFIG_FILE is aimed at a
# path that cannot exist, so the operator config never contributes a value
# the fixture did not set.
run() {
  STEWARD_ESTATE_ROOT="$FX" STEWARD_CONFIG_FILE="$FX/no-such-config" \
  bash "$STEWARD" registry login "$@" 2>&1
}

# load_login <slug> — round trip through the REAL loader, in a subshell so
# LOGIN_* never leaks between checks. Prints
# "PRINCIPAL|ACCOUNT|PROVIDER|CONFIG_DIR_RAW|LEGAL_OWNER" on success, nothing
# on failure.
load_login() {
  (
    STEWARD_ESTATE_ROOT="$FX"
    # shellcheck source=/dev/null
    . "$here/lib/registry.sh"
    registry_login_load "$1" >/dev/null 2>&1 || exit 1
    printf '%s|%s|%s|%s|%s' \
      "$LOGIN_PRINCIPAL" "$LOGIN_ACCOUNT" "$LOGIN_PROVIDER" \
      "$LOGIN_CONFIG_DIR_RAW" "$LOGIN_LEGAL_OWNER"
  )
}

mode_of() { stat -f '%Lp' "$1" 2>/dev/null || stat -c '%a' "$1"; }
dir_listing() { ls "$LOGINS" 2>/dev/null | sort | tr '\n' ' '; }
stage_count() { ls -A "$LOGINS" 2>/dev/null | grep -c '^\.stage' || true; }

echo "== 1. login add: a valid row round trips with all five fields, mode 600, --json shape =="
out="$(run add acme --principal alice --account acct-acme-team --provider claude-team \
  --config-dir '~/.claude-logins/acme' --legal-owner 'Acme Corp' --json)"; rc=$?
is "1: rc 0"            "$rc" "0"
is "1: ok true"         "$(printf '%s' "$out" | jq -r '.ok')" "true"
is "1: login echoed"    "$(printf '%s' "$out" | jq -r '.login')" "acme"
is "1: principal echoed" "$(printf '%s' "$out" | jq -r '.principal')" "alice"
is "1: account echoed"  "$(printf '%s' "$out" | jq -r '.account')" "acct-acme-team"
is "1: provider echoed" "$(printf '%s' "$out" | jq -r '.provider')" "claude-team"
is "1: config_dir echoed" "$(printf '%s' "$out" | jq -r '.config_dir')" "~/.claude-logins/acme"
is "1: legal_owner echoed" "$(printf '%s' "$out" | jq -r '.legal_owner')" "Acme Corp"
is "1: file mode 600"   "$(mode_of "$LOGINS/acme.conf")" "600"
is "1: loads back via registry_login_load" \
  "$(load_login acme)" "alice|acct-acme-team|claude-team|~/.claude-logins/acme|Acme Corp"

echo "== 2. --config-dir outside the grammar refuses rc 64, nothing written =="
before="$(dir_listing)"
out="$(run add badgrammar --principal alice --account acct-acme-team --provider claude-team \
  --config-dir '/etc/passwd' --legal-owner 'Acme Corp' --json)"; rc=$?
is "2: rc 64" "$rc" "64"
is "2: ok false" "$(printf '%s' "$out" | jq -r '.ok')" "false"
absent "2: nothing written" "$LOGINS/badgrammar.conf"
is "2: logins.d unchanged" "$(dir_listing)" "$before"

echo "== 3. --provider outside the closed vocabulary refuses rc 64 =="
before="$(dir_listing)"
out="$(run add badprovider --principal alice --account acct-acme-team --provider chatgpt-legacy \
  --config-dir '~/.claude-logins/badprovider' --legal-owner 'Acme Corp' --json)"; rc=$?
is "3: rc 64" "$rc" "64"
absent "3: nothing written" "$LOGINS/badprovider.conf"
is "3: logins.d unchanged" "$(dir_listing)" "$before"

echo "== 4. empty --legal-owner refuses rc 64 =="
before="$(dir_listing)"
out="$(run add badlegal --principal alice --account acct-acme-team --provider claude-team \
  --config-dir '~/.claude-logins/badlegal' --legal-owner '' --json)"; rc=$?
is "4: rc 64" "$rc" "64"
absent "4: nothing written" "$LOGINS/badlegal.conf"
is "4: logins.d unchanged" "$(dir_listing)" "$before"

echo "== 5. create-only: a second add on the same slug refuses rc 65, leaves the row untouched =="
before_content="$(cat "$LOGINS/acme.conf")"
before="$(dir_listing)"
out="$(run add acme --principal alice --account acct-acme-team --provider claude-team \
  --config-dir '~/.claude-logins/acme-again' --legal-owner 'Acme Corp' --json)"; rc=$?
is "5: rc 65" "$rc" "65"
is "5: the original row is byte-identical afterward" "$(cat "$LOGINS/acme.conf")" "$before_content"
is "5: logins.d unchanged" "$(dir_listing)" "$before"

echo "== 6. a row whose RESOLVED directory collides with an existing row refuses rc 65 — the window is CLOSED =="
# Same PRINCIPAL, same CONFIG_DIR leaf as 'acme' above, but a DIFFERENT verb
# slug — registry_row_write's own create-only recheck (case 5) never fires;
# only the stage validator's registry_login_check catches this, under the
# lock, before publish.
before="$(dir_listing)"
out="$(run add acme2 --principal alice --account acct-acme-team --provider claude-team \
  --config-dir '~/.claude-logins/acme' --legal-owner 'Acme Corp' --json)"; rc=$?
is "6: rc 65 or 70 (the collision is a stage-validator refusal)" "$rc" "70"
is "6: ok false" "$(printf '%s' "$out" | jq -r '.ok')" "false"
absent "6: nothing written under the new slug" "$LOGINS/acme2.conf"
is "6: logins.d is BYTE FOR BYTE unchanged — no published-then-removed intermediate state" \
  "$(dir_listing)" "$before"
is "6: no stage was left behind" "$(stage_count)" "0"

echo "== 7. '~/.claude' as --config-dir is reserved for the estate's LEGACY_LOGIN =="
before="$(dir_listing)"
out="$(run add notlegacy --principal alice --account acct-acme-team --provider claude-team \
  --config-dir '~/.claude' --legal-owner 'Acme Corp' --json)"; rc=$?
is "7a: a slug that is not LEGACY_LOGIN refuses rc 64" "$rc" "64"
has "7a: the refusal names LEGACY_LOGIN's current value" "$(printf '%s' "$out" | jq -r '.reason')" "oldschool"
absent "7a: nothing written" "$LOGINS/notlegacy.conf"
is "7a: logins.d unchanged" "$(dir_listing)" "$before"

out="$(run add oldschool --principal alice --account acct-acme-team --provider claude-team \
  --config-dir '~/.claude' --legal-owner 'Acme Corp' --json)"; rc=$?
is "7b: the estate's named LEGACY_LOGIN slug is accepted with '~/.claude' — rc 0" "$rc" "0"
is "7b: loads back with the legacy CONFIG_DIR" \
  "$(load_login oldschool)" "alice|acct-acme-team|claude-team|~/.claude|Acme Corp"

echo "== 8. a control character in a value refuses rc 64 (_registry_emit_kv) — no CLI-level whitespace check catches --legal-owner =="
before="$(dir_listing)"
out="$(run add ctrltest --principal alice --account acct-acme-team --provider claude-team \
  --config-dir '~/.claude-logins/ctrltest' --legal-owner "$(printf 'Acme\tCo')" --json)"; rc=$?
is "8: rc 64" "$rc" "64"
absent "8: nothing written" "$LOGINS/ctrltest.conf"
is "8: logins.d unchanged" "$(dir_listing)" "$before"

echo "== 9. the stage validator does NOT source what it validates =="
# _registry_validate_login_stage is extracted straight from bin/steward and
# called DIRECTLY on a HAND-WRITTEN file (never through the serializer, which
# would refuse the substitution characters itself at emit time) — the only
# way to construct bytes that a `source` would execute.
# _call_validator <file> <expect-slug> <expect-config-dir> — sets the
# _REGW_EXPECT_* globals INSIDE the subshell (never leaking to the parent)
# and calls the real validator, extracted straight from bin/steward.
_call_validator() {
  local _file="$1" _eslug="$2" _econfig="$3"
  (
    export STEWARD_ESTATE_ROOT="$FX" STEWARD_CONFIG_FILE="$FX/no-such-config"
    # shellcheck source=/dev/null
    . "$here/lib/registry.sh"
    eval "$(sed -n '/^_registry_validate_login_stage()/,/^}/p' "$STEWARD")"
    _REGW_EXPECT_SLUG="$_eslug"
    _REGW_EXPECT_PRINCIPAL="alice"
    _REGW_EXPECT_ACCOUNT="acct-acme-team"
    _REGW_EXPECT_PROVIDER="claude-team"
    _REGW_EXPECT_CONFIG_DIR="$_econfig"
    _REGW_EXPECT_LEGAL_OWNER="Acme Corp"
    _registry_validate_login_stage "$_file"
  )
}

MARK1="$FX/PWNED-cmdsub-$$"
HAND1="$(mktemp)"
cat > "$HAND1" <<EOF
PRINCIPAL="alice"
ACCOUNT="acct-acme-team"
PROVIDER="claude-team"
CONFIG_DIR="~/.claude-logins/\$(touch $MARK1)"
LEGAL_OWNER="Acme Corp"
EOF
_call_validator "$HAND1" inj1 "\$(touch $MARK1)"
rc=$?
is "9a: a hand-written stage with a command substitution refuses rc 70" "$rc" "70"
absent "9a: no side effect — the substitution never ran" "$MARK1"
rm -f "$HAND1"

MARK2="$FX/PWNED-backtick-$$"
HAND2="$(mktemp)"
cat > "$HAND2" <<EOF
PRINCIPAL="alice"
ACCOUNT="acct-acme-team"
PROVIDER="claude-team"
CONFIG_DIR="~/.claude-logins/\`touch $MARK2\`"
LEGAL_OWNER="Acme Corp"
EOF
_call_validator "$HAND2" inj2 "\`touch $MARK2\`"
rc=$?
is "9b: a hand-written stage with a backtick refuses rc 70" "$rc" "70"
absent "9b: no side effect — the backtick never ran" "$MARK2"
rm -f "$HAND2"

echo "pass=$pass fail=$fail"
[ "$fail" -eq 0 ]
