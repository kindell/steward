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
# 0700, PINNED. The login and invite readers refuse a group- or other-writable
# register, so under the Debian default umask of 002 a fixture that lets `mkdir`
# pick the mode measures the HOST, not the product. See test/register-modes.test.sh.
chmod 700 "$FX/logins.d"
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

mode_of() { # BSD or GNU, and ONLY AN OCTAL ANSWER COUNTS: on GNU
            # `stat -f` reports the FILESYSTEM and exits 0, so an empty-check
            # accepts an ext4 report as a mode (measured on the Linux host
            # 2026-09-04: 23 of 59 suites went red on this one shape).
  local m 2>/dev/null || true
  for m in "$(stat -f '%Lp' "$1" 2>/dev/null)" "$(stat -c '%a' "$1" 2>/dev/null)"; do
    case "$m" in [0-7]|[0-7][0-7]|[0-7][0-7][0-7]|[0-7][0-7][0-7][0-7]) printf '%s' "$m"; return 0 ;; esac
  done
  return 1
}
dir_listing() { ls "$LOGINS" 2>/dev/null | sort | tr '\n' ' '; }
stage_count() { ls -A "$LOGINS" 2>/dev/null | grep -c '^\.stage' || true; }

echo "== 1. login add: a valid row round trips with all five fields, mode 600, --json shape =="
out="$(run add acme --principal alice --account acct-acme-team --provider claude-team \
  --config-dir '~/.claude-logins/acme' --legal-owner 'Acme Corp' --json)"; rc=$?
is "1: rc 0"            "$rc" "0"
is "1: ok true"         "$(printf '%s' "$out" | jq -r '.ok')" "true"
# --json's SHAPE MATCHES `account add --json` — kind, slug, the row's own
# fields, then file — through the shared _json/jq helper, never a hand-built
# printf. See MINOR-1 of the task-9 review.
is "1: kind is login"   "$(printf '%s' "$out" | jq -r '.kind')" "login"
is "1: slug echoed"     "$(printf '%s' "$out" | jq -r '.slug')" "acme"
is "1: principal echoed" "$(printf '%s' "$out" | jq -r '.principal')" "alice"
is "1: account echoed"  "$(printf '%s' "$out" | jq -r '.account')" "acct-acme-team"
is "1: provider echoed" "$(printf '%s' "$out" | jq -r '.provider')" "claude-team"
is "1: config_dir echoed" "$(printf '%s' "$out" | jq -r '.config_dir')" "~/.claude-logins/acme"
is "1: legal_owner echoed" "$(printf '%s' "$out" | jq -r '.legal_owner')" "Acme Corp"
is "1: file echoed"     "$(printf '%s' "$out" | jq -r '.file')" "$LOGINS/acme.conf"
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

echo "== 3b. --provider SPANNING TWO entries is refused, and says which field =="
# A COMMAND-LINE ARGUMENT IS FREE TEXT, and the closed-vocabulary check used
# the substring form, which accepts a value that spans two entries. No bad row
# reached disk even then - the staging re-read refuses it - so the real defect
# was the DIAGNOSTIC: the person who mistyped a provider was told that a
# temporary file would not parse. This case pins the message, not just the
# refusal, because the comment above the gate says a verb that can only be
# caught by the reader is a verb that writes rubbish and reports success.
before="$(dir_listing)"
out="$(run add spanprovider --principal alice --account acct-acme-team \
  --provider 'claude-max claude-team' \
  --config-dir '~/.claude-logins/spanprovider' --legal-owner 'Acme Corp' --json)"; rc=$?
is  "3b: rc 64" "$rc" "64"
has "3b: the refusal names --provider, not a staging file" "$out" "invalid --provider"
absent "3b: nothing written" "$LOGINS/spanprovider.conf"
is  "3b: logins.d unchanged" "$(dir_listing)" "$before"

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

echo "== 10. login ls: text and --json, an empty register, one row, two rows, an unreadable row =="
# A SEPARATE ESTATE, so ls's cases are not entangled with the collisions and
# refusals proved above (FX/logins.d already carries 'acme' and 'oldschool'
# by this stage of the suite). This section owns its own logins.d and its own
# STEWARD_HOME_LOOKUP_CMD stub — the same pattern test/logins-registry.test.sh
# uses to resolve a login's directory without touching the real system's
# account database.
FX2="$(mktemp -d)"
mkdir -p "$FX2/estate" "$FX2/logins.d" "$FX2/accounts.d"
chmod 700 "$FX2/logins.d"
cp "$FX/estate/steward.conf" "$FX2/estate/steward.conf"
LOGINS2="$FX2/logins.d"
# THE ACCOUNT ROW IS SPELLED OUT. MINOR-1's fix resolves the listing against
# the account's own USERNAME rather than the login's PRINCIPAL, so an
# accounts.d row must exist for 'acct-acme-team' or every row below would
# print "(account does not resolve)" instead of a path. USERNAME left unset
# on purpose: it defaults to PRINCIPAL ("alice"), the ordinary case where the
# two coincide — section 10e below is the case where they do not.
cat > "$FX2/accounts.d/acct-acme-team.conf" <<'EOF'
PRINCIPAL="alice"
HOST="h1"
EOF
chmod 600 "$FX2/accounts.d/acct-acme-team.conf"
cat > "$FX2/homelookup" <<'STUB'
#!/bin/bash
case "$1" in
  alice) printf '/srv/homes/alice\n' ;;
  *) exit 1 ;;
esac
STUB
chmod +x "$FX2/homelookup"

# STEWARD_SELF_HOST IS PART OF THE FIXTURE NOW, because the listing resolves a
# login to a unix account through accounts.d BY PRINCIPAL - and an account row
# is per HOST. Without a self-image the fixture's `HOST="h1"` rows belong to a
# machine this run is not, and every row lists as unresolvable. That is the
# resolver being right: a person may have accounts on several machines and only
# the one on this host has the home the credentials sit in.
run2() {
  STEWARD_ESTATE_ROOT="$FX2" STEWARD_CONFIG_FILE="$FX2/no-such-config" \
  STEWARD_SELF_HOST=h1 STEWARD_HOME_LOOKUP_CMD="$FX2/homelookup" \
  bash "$STEWARD" registry login "$@" 2>&1
}

echo "-- 10a. an empty register --"
out="$(run2 ls --json)"; rc=$?
is "10a: rc 0 --json"                 "$rc" "0"
is "10a: an empty logins array"       "$out" '{"logins":[]}'
out="$(run2 ls)"; rc=$?
is "10a: rc 0 text"                   "$rc" "0"
is "10a: text mode prints nothing"    "$out" ""

echo "-- 10b. one row, both modes --"
run2 add row1 --principal alice --account acct-acme-team --provider claude-team \
  --config-dir '~/.claude-logins/row1' --legal-owner 'Acme Corp' --json >/dev/null
out="$(run2 ls)"; rc=$?
is "10b: rc 0 text"                       "$rc" "0"
has "10b: text row names the slug"        "$out" "row1"
has "10b: text row names the account"     "$out" "acct-acme-team"
has "10b: text row shows the resolved dir" "$out" "/srv/homes/alice/.claude-logins/row1"
has "10b: text row shows the legal owner"  "$out" "Acme Corp"

out="$(run2 ls --json)"; rc=$?
is "10b: rc 0 --json"                     "$rc" "0"
is "10b: exactly one row"                 "$(printf '%s' "$out" | jq '.logins | length')" "1"
is "10b: row's login field"               "$(printf '%s' "$out" | jq -r '.logins[0].login')" "row1"
is "10b: row's account field"             "$(printf '%s' "$out" | jq -r '.logins[0].account')" "acct-acme-team"
is "10b: row's provider field"            "$(printf '%s' "$out" | jq -r '.logins[0].provider')" "claude-team"
is "10b: row's config_dir field is resolved, not raw" \
  "$(printf '%s' "$out" | jq -r '.logins[0].config_dir')" "/srv/homes/alice/.claude-logins/row1"
is "10b: row's legal_owner field"         "$(printf '%s' "$out" | jq -r '.logins[0].legal_owner')" "Acme Corp"

echo "-- 10c. two rows: the JSON comma --"
run2 add row2 --principal alice --account acct-acme-team --provider claude-team \
  --config-dir '~/.claude-logins/row2' --legal-owner 'Acme Corp' --json >/dev/null
out="$(run2 ls --json)"; rc=$?
is "10c: rc 0"                       "$rc" "0"
is "10c: two rows, valid JSON"       "$(printf '%s' "$out" | jq '.logins | length')" "2"
is "10c: row order is row1 then row2" \
  "$(printf '%s' "$out" | jq -r '.logins[].login' | tr '\n' ' ')" "row1 row2 "

echo "-- 10d. a deliberately unreadable row: text prints UNREADABLE, --json carries it explicitly (MINOR-3) --"
# A hand-corrupted conf: registry_login_list still names the slug (it only
# globs *.conf), but registry_login_load refuses it (missing PROVIDER) — the
# exact asymmetry this register's readers are built to survive, and the one
# a machine consumer of --json must be able to see too.
printf 'PRINCIPAL="alice"\nACCOUNT="acct-acme-team"\nCONFIG_DIR="~/.claude-logins/broken"\nLEGAL_OWNER="Acme Corp"\n' \
  > "$LOGINS2/broken.conf"
chmod 600 "$LOGINS2/broken.conf"

out="$(run2 ls)"; rc=$?
is "10d: rc 0 text"                        "$rc" "0"
has "10d: text mode names the unreadable row" "$out" "broken: UNREADABLE"

out="$(run2 ls --json)"; rc=$?
is "10d: rc 0 --json"                      "$rc" "0"
is "10d: three rows total, the broken one included" \
  "$(printf '%s' "$out" | jq '.logins | length')" "3"
is "10d: the broken row's unreadable marker is explicit, not a drop" \
  "$(printf '%s' "$out" | jq -r '.logins[] | select(.login=="broken") | .unreadable')" "true"
is "10d: the two readable rows are unaffected" \
  "$(printf '%s' "$out" | jq -r '[.logins[] | select(.unreadable != true) | .login] | sort | join(" ")')" \
  "row1 row2"

echo "-- 10e. MINOR-1: the resolved directory follows the ACCOUNT's username, not the login's PRINCIPAL --"
# A SEPARATE ESTATE again, and this one's STEWARD_HOME_LOOKUP_CMD maps ONLY
# 'a-user' — 'alice' resolves to nothing. If the verb still asks the lookup
# about the login's PRINCIPAL (alice) instead of the account's USERNAME
# (a-user), the row prints "(does not resolve)" instead of a path — that is
# the red this section is built to see.
FX3="$(mktemp -d)"
mkdir -p "$FX3/estate" "$FX3/logins.d" "$FX3/accounts.d"
chmod 700 "$FX3/logins.d"
cp "$FX/estate/steward.conf" "$FX3/estate/steward.conf"
LOGINS3="$FX3/logins.d"
cat > "$FX3/accounts.d/acct-acme-team.conf" <<'EOF'
PRINCIPAL="alice"
HOST="h1"
USERNAME="a-user"
EOF
chmod 600 "$FX3/accounts.d/acct-acme-team.conf"
cat > "$FX3/homelookup3" <<'STUB'
#!/bin/bash
case "$1" in
  a-user) printf '/srv/homes/a-user\n' ;;
  *) exit 1 ;;
esac
STUB
chmod +x "$FX3/homelookup3"

run3() {
  STEWARD_ESTATE_ROOT="$FX3" STEWARD_CONFIG_FILE="$FX3/no-such-config" \
  STEWARD_SELF_HOST=h1 STEWARD_HOME_LOOKUP_CMD="$FX3/homelookup3" \
  bash "$STEWARD" registry login "$@" 2>&1
}

run3 add r1 --principal alice --account acct-acme-team --provider claude-team \
  --config-dir '~/.claude-logins/r1' --legal-owner 'Acme Corp' --json >/dev/null

out="$(run3 ls)"; rc=$?
is "10e: rc 0" "$rc" "0"
has "10e: the listed directory is resolved against the account's username (a-user), not the principal (alice)" \
  "$out" "/srv/homes/a-user/.claude-logins/r1"

out="$(run3 ls --json)"; rc=$?
is "10e: rc 0 --json"                     "$rc" "0"
is "10e: config_dir field carries the same resolution" \
  "$(printf '%s' "$out" | jq -r '.logins[0].config_dir')" "/srv/homes/a-user/.claude-logins/r1"

echo "-- 10f. a login whose PRINCIPAL has no account on this host names the refusal, not a path --"
# THIS CASE USED TO ASSERT THE BUG. It added a row with `--account acct-ghost`
# and expected "(account does not resolve)" - which only made sense while the
# listing looked ACCOUNT up as an accounts.d slug. ACCOUNT is the account's REAL
# NAME (an address; see registry_login_load's own comment), so `acct-ghost` is
# not an unresolvable slug, it is just a name, and there is nothing there to
# resolve. The fixture hid the defect by giving every account row a slug that
# happened to equal the ACCOUNT field, so the wrong lookup succeeded here and
# failed on every real estate: measured 2026-09-09, all four correct rows on
# a live host printed "(account does not resolve)".
#
# The genuinely unresolvable case is a login whose PRINCIPAL has no account on
# THIS host - the person's credentials live on another machine - and that is
# what is asserted now.
run3 add r2 --principal nobody --account somebody@example.test --provider claude-team \
  --config-dir '~/.claude-logins/r2' --legal-owner 'Acme Corp' --json >/dev/null
out="$(run3 ls)"; rc=$?
is "10f: rc 0" "$rc" "0"
has "10f: the row names the refusal, not a path" "$out" "no account for this login's principal on this host"
has "10f: and the resolvable row beside it is unaffected" "$out" "/srv/homes/a-user/.claude-logins/r1"
is  "10f: --json carries the same refusal in config_dir" \
  "$(printf '%s' "$(run3 ls --json)" | jq -r '.logins[] | select(.login=="r2") | .config_dir' | grep -c "no account for")" "1"
is  "10f: and its credential column is a dash, never a no" \
  "$(printf '%s' "$(run3 ls --json)" | jq -r '.logins[] | select(.login=="r2") | .credential')" "-"

rm -rf "$FX3"

rm -rf "$FX2"

echo "== 11. local-variable discipline: k (validator) and K (login add) do not leak into their caller (MINOR-4) =="
# The mutation this proves: dropping 'k' from _registry_validate_login_stage's
# local line, or 'K' from cmd_registry_login_add's, makes the sentinel below
# get overwritten by the loop's last iteration value instead of surviving.
_extract_fn() { sed -n "/^$1()/,/^}/p" "$STEWARD"; }

out_k="$(
  export STEWARD_ESTATE_ROOT="$FX" STEWARD_CONFIG_FILE="$FX/no-such-config"
  # shellcheck source=/dev/null
  . "$here/lib/registry.sh"
  eval "$(_extract_fn _registry_validate_login_stage)"
  _REGW_EXPECT_SLUG="acme"
  _REGW_EXPECT_PRINCIPAL="alice"
  _REGW_EXPECT_ACCOUNT="acct-acme-team"
  _REGW_EXPECT_PROVIDER="claude-team"
  _REGW_EXPECT_CONFIG_DIR="~/.claude-logins/acme"
  _REGW_EXPECT_LEGAL_OWNER="Acme Corp"
  k="SENTINEL"
  _registry_validate_login_stage "$LOGINS/acme.conf" >/dev/null 2>&1
  printf '%s' "$k"
)"
is "11a: the validator leaves the caller's k untouched" "$out_k" "SENTINEL"

out_K="$(
  # THE INHERITED EXIT TRAP IS CLEARED FIRST. This subshell inherits the
  # fixtures rm-the-tempdir EXIT trap set near the top of this file, in
  # dormant form: present, but never fired unless something re-registers it
  # with the trap builtin. registry_row_writes own lock does exactly that
  # (save/restore, so a callers real EXIT trap survives a call into it in
  # the same shell) and restoring it here would re-arm the dormant trap and
  # delete the fixture out from under this very call. Clearing it first
  # makes that save/restore a no-op.
  trap - EXIT
  export STEWARD_ESTATE_ROOT="$FX" STEWARD_CONFIG_FILE="$FX/no-such-config"
  # shellcheck source=/dev/null
  . "$here/lib/registry.sh"
  eval "$(_extract_fn _reg_fail)"
  eval "$(_extract_fn _registry_validate_login_stage)"
  eval "$(_extract_fn cmd_registry_login_add)"
  HERE="$here"
  K="SENTINEL"
  cmd_registry_login_add kleaktest --principal alice --account acct-acme-team \
    --provider claude-team --config-dir '~/.claude-logins/kleaktest' \
    --legal-owner 'Acme Corp' >/dev/null 2>&1
  printf '%s' "$K"
)"
is "11b: cmd_registry_login_add leaves the caller's K untouched" "$out_K" "SENTINEL"
is "11b: the row was still written correctly under the harness" \
  "$(load_login kleaktest)" "alice|acct-acme-team|claude-team|~/.claude-logins/kleaktest|Acme Corp"


echo "== 12. login shell: the directory and the account are SAID before anything is typed =="
# WHY THIS VERB EXISTS, and it is one measured evening: a login is just a
# directory in CLAUDE_CONFIG_DIR, and nothing tells a person which one they are
# standing in until after they have typed /login. On 2026-09-09 a login meant
# for `~/.claude-logins/<login>` landed in `~/.claude` - a different
# subscription -
# and every session on that account was signed out mid-work.
FX4="$(mktemp -d)"
mkdir -p "$FX4/estate" "$FX4/logins.d" "$FX4/accounts.d" "$FX4/home/.claude-logins/mine"
chmod 700 "$FX4/logins.d"
# THE LOGIN DIRECTORY AND ITS PARENT ARE PINNED, NOT LEFT TO THE RUNNER'S UMASK.
# registry_login_config_dir refuses a group- or other-writable target OR parent,
# and under the Debian default of 002 `mkdir -p` makes both 775 - so the fixture
# would measure the host's umask instead of the product. This is not a
# hypothetical: the same 775 on a real home stopped seven sessions from starting
# on 2026-09-09, and the refusal reached only the supervisor's journal.
chmod 755 "$FX4/home/.claude-logins" "$FX4/home/.claude-logins/mine"
cp "$FX/estate/steward.conf" "$FX4/estate/steward.conf"
ME="$(id -un)"
printf 'PRINCIPAL="me"\nHOST="h1"\nUSERNAME="%s"\n' "$ME" > "$FX4/accounts.d/a-me.conf"
printf 'PRINCIPAL="them"\nHOST="h1"\nUSERNAME="someone-else"\n'  > "$FX4/accounts.d/a-them.conf"
chmod 600 "$FX4/accounts.d"/*.conf
cat > "$FX4/homelookup4" <<STUB
case "\$1" in
  $ME) printf '$FX4/home\n' ;;
  someone-else) printf '/srv/homes/someone-else\n' ;;
  *) exit 1 ;;
esac
STUB
chmod +x "$FX4/homelookup4"
run4() { STEWARD_ESTATE_ROOT="$FX4" STEWARD_CONFIG_FILE="$FX4/no-such-config" \
         STEWARD_SELF_HOST=h1 STEWARD_HOME_LOOKUP_CMD="$FX4/homelookup4" \
         bash "$STEWARD" registry login "$@"; }
run4 add mine  --principal me   --account me@example.test   --provider claude-team --config-dir '~/.claude-logins/mine'  --legal-owner 'Acme' --json >/dev/null 2>&1
run4 add yours --principal them --account them@example.test --provider claude-team --config-dir '~/.claude-logins/yours' --legal-owner 'Acme' --json >/dev/null 2>&1

# THE VARIABLE IS THE POINT: the shell runs a command with the login's own
# directory in CLAUDE_CONFIG_DIR, which is the whole mechanism a session uses.
out="$(run4 shell mine -- sh -c 'printf %s "$CLAUDE_CONFIG_DIR"' 2>/dev/null)"
is "12: the command runs with the login's directory in CLAUDE_CONFIG_DIR" "$out" "$FX4/home/.claude-logins/mine"
out="$(run4 shell mine -- sh -c 'printf %s "$STEWARD_LOGIN"' 2>/dev/null)"
is "12: and STEWARD_LOGIN names the login" "$out" "mine"

# THE THREE LINES GO TO STDERR, so a command in a pipeline still carries them to
# the terminal - the person must see them even when stdout is captured.
err="$(run4 shell mine -- true 2>&1 >/dev/null)"
has "12: the banner names the login and who pays"  "$err" "login    mine (me@example.test, paid by Acme)"
has "12: the banner names the resolved directory"  "$err" "dir      $FX4/home/.claude-logins/mine"
has "12: and says there is no credential yet"      "$err" "no credential yet"
out="$(run4 shell mine -- sh -c 'echo ON-STDOUT' 2>/dev/null)"
is  "12: nothing of the banner leaks onto stdout"  "$out" "ON-STDOUT"

# AN ALREADY-LOGGED-IN DIRECTORY SAYS SO, because /login there means something
# different: re-authenticate, or switch the account under running sessions.
printf '{}' > "$FX4/home/.claude-logins/mine/.credentials.json"
err="$(run4 shell mine -- true 2>&1 >/dev/null)"
has "12: an existing credential is reported as such" "$err" "already logged in"

# AN UNREADABLE DIRECTORY IS `unreadable`, NEVER `no`. Run from the hub account
# every other person's login directory is unreachable (homes are 0750), and a
# plain existence test answers "not logged in" for a directory that is perfectly
# well logged in - an unmeasurable rendered as a negative fact, which would send
# someone to run /login where none was needed. Simulated here by taking away our
# own read bit, which is the same question from the same side.
chmod 000 "$FX4/home/.claude-logins/mine"
out="$(run4 ls 2>/dev/null)"
has "12: an unreadable login directory reads 'unreadable'" "$out" "unreadable"
is  "12: ...and never 'no'" "$(printf '%s\n' "$out" | awk '$1=="mine"{print $0}' | grep -c ' no ')" "0"
is  "12: --json carries the same word" \
    "$(run4 ls --json 2>/dev/null | jq -r '.logins[] | select(.login=="mine") | .credential')" "unreadable"
chmod 755 "$FX4/home/.claude-logins/mine"

# ANOTHER PERSON'S LOGIN IS REFUSED, and the refusal names the human who must
# run it instead - their credentials are in their own 0750 home.
err="$(run4 shell yours -- true 2>&1)"; rc=$?
is  "12: another person's login refuses rc 77" "$rc" "77"
has "12: ...and names the person"              "$err" "belongs to them"
has "12: ...and names the directory"           "$err" "/srv/homes/someone-else/.claude-logins/yours"
err="$(run4 shell nosuch -- true 2>&1)"; rc=$?
is  "12: an unknown login refuses rc 78" "$rc" "78"
# THE COMMAND'S OWN EXIT STATUS IS THE CALLER'S: exec, not a subshell.
run4 shell mine -- sh -c 'exit 42' 2>/dev/null; is "12: the command's exit status is passed through" "$?" "42"
err="$(run4 shell 2>&1)"; rc=$?
is  "12: no login at all is a usage error (64)" "$rc" "64"
has "12: ...and prints the usage line"          "$err" "steward registry login shell <login>"
printf 'PRINCIPAL="me"\nACCOUNT="me@example.test"\nPROVIDER="claude-pro"\nCONFIG_DIR="~/.claude-logins/mine"\nLEGAL_OWNER="Acme"\n' > "$FX4/logins.d/badrow.conf"
chmod 600 "$FX4/logins.d/badrow.conf"
out="$(run4 ls 2>/dev/null)"
# THE ROW'S OWN REFUSAL REACHES THE LISTING. A login whose row does not LOAD is
# a different fact from a principal with no account here, and the second
# sentence used to be printed for both - sending a reader to accounts.d while
# the fault was a field in the login row. The message existed all along, behind
# a `2>&1` on the deciding line.
has "12: a row that does not load reports ITS OWN refusal" "$out" "UNREADABLE -- "
has "12: ...and the refusal names the field"               "$out" "invalid PROVIDER"
is  "12: ...and not the account sentence" "$(printf '%s\n' "$out" | grep -c "no account for this login")" "0"

echo "== 13. the listing does not depend on the CALLER's IFS =="
# The eighteen macOS failures were not in the join. `IFS=$'\t' read -r a b c
# <<<"$(registry_login_state ...)"` runs the substitution under that IFS on bash
# 3.2, so the whole state function ran with IFS=TAB and every space-separated
# list it touched stopped splitting. The verb captures first and reads second
# now, and the helper pins its own IFS - two independent guards, either of which
# would have prevented it.
out="$( IFS=$'\t'; run4 ls 2>/dev/null )"
has "13: with IFS=TAB the row still resolves" "$out" "$FX4/home/.claude-logins/mine"
is  "13: ...and no row claims a missing account" "$(printf '%s\n' "$out" | grep -c "no account for this login")" "0"
out="$( IFS=,; run4 shell mine -- sh -c 'printf %s "$CLAUDE_CONFIG_DIR"' 2>/dev/null )"
is  "13: shell sets the directory under a comma IFS too" "$out" "$FX4/home/.claude-logins/mine"
rm -f "$FX4/logins.d/badrow.conf"
rm -rf "$FX4"

echo "== 12. TWO ACCOUNTS, ONE PERSON, ONE HOST - the join has no single answer =="
# A LOGIN HAS NO HOME DIRECTORY. The PAIR (login, account) has one. Until now
# this function answered the question anyway, by taking the FIRST accounts.d row
# whose PRINCIPAL and HOST matched - which means the answer was decided by glob
# order, and glob order is alphabetical.
#
# Measured on a real host 2026-09-10: `alice-h1` (USERNAME=alice) and
# `zz-worker-h1` (USERNAME=worker) both carry the same PRINCIPAL, so the lookup
# answered the first while the session that USES that login runs as the second. The
# credential seam then read the wrong home and reported a refresh deadline
# TWENTY HOURS from the session's real one. On another host the wrong home had
# no file at all, so the row said `no-credential` - the words for "nothing to
# fix here" - about a hub running on a perfectly valid login.
#
# THE SUPERVISOR JOINS ON THE SESSION'S OWNER, which is unambiguous. This
# function joined on the person, which is not. A silent pick between two
# defensible answers is the same defect as reading an error as an answer: the
# caller cannot tell that a question was even asked.
FX5="$(mktemp -d)"
mkdir -p "$FX5/estate" "$FX5/logins.d" "$FX5/accounts.d"
chmod 700 "$FX5/logins.d"
cp "$FX/estate/steward.conf" "$FX5/estate/steward.conf"
cat > "$FX5/logins.d/two-homes.conf" <<'EOF'
PRINCIPAL="alice"
ACCOUNT="alice@example.invalid"
PROVIDER="claude-max"
CONFIG_DIR="~/.claude-logins/two-homes"
LEGAL_OWNER="Acme"
EOF
chmod 600 "$FX5/logins.d/two-homes.conf"
for pair in "alice-h1 alice" "zz-worker-h1 worker"; do
  set -- $pair
  printf 'PRINCIPAL="alice"
HOST="h1"
USERNAME="%s"
' "$2" > "$FX5/accounts.d/$1.conf"
  chmod 600 "$FX5/accounts.d/$1.conf"
done
out="$( STEWARD_ESTATE_ROOT="$FX5" STEWARD_SELF_HOST="h1" bash -c '
  . '"$here"'/lib/registry.sh
  registry_login_unix_account two-homes' 2>"$FX5/err" )"; rc=$?
is  "12a an ambiguous join REFUSES rather than picking"  "$rc" "1"
is  "12b and prints no account at all"                   "$out" ""
has "12c the refusal names both candidates"              "$(cat "$FX5/err")" "alice-h1"
has "12d ...both of them"                                "$(cat "$FX5/err")" "zz-worker-h1"
# AND THE ORDINARY CASE IS UNCHANGED: one account, one answer, no refusal.
rm -f "$FX5/accounts.d/zz-worker-h1.conf"
out="$( STEWARD_ESTATE_ROOT="$FX5" STEWARD_SELF_HOST="h1" bash -c '
  . '"$here"'/lib/registry.sh
  registry_login_unix_account two-homes' 2>/dev/null )"; rc=$?
is "12e one account still answers" "$out" "alice"
is "12f and it is rc 0"            "$rc" "0"
rm -rf "$FX5"

echo "pass=$pass fail=$fail"
[ "$fail" -eq 0 ]
