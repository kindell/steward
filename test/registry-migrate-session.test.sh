#!/bin/bash
# test/registry-migrate-session.test.sh — `steward registry migrate-session`,
# the naming-model cutover's one-way converter: an OLD-SHAPE session conf
# (legacy DOMAIN/OWNER/RC_LABEL, no identity fields) becomes a NEW-SHAPE
# identity row IN PLACE, preserving every operational field, and the old row
# is removed ONLY after the new one reads back green.
#
# WHAT THIS VERB ADDS ON TOP OF `session add`, and is therefore proved here:
#
#   - IT READS AN EXISTING ROW and snapshots ALL its fields through a
#     SUBSHELLED source (a hostile conf must not clobber the verb's locals,
#     nor execute at snapshot time), then carries every operational field
#     forward UNCHANGED — RUNTIME, MODEL, OPENCODE_*, AUTO_APPROVE,
#     CLAUDE_MEMORY_ROOT, ASSETS, REPO_PATH, HOST and the rest. Dropping any
#     one of them would break a working session.
#   - IT ADDS the identity fields (minted opaque ID, ACCOUNT, SLUG, the typed
#     union TARGET_*) and rewrites OWNER to the account's PRINCIPAL — the
#     visibility/enter bridge.
#   - IT REMOVES the legacy RC_LABEL — the display now DERIVES from the target,
#     and a stale RC_LABEL would override that derivation.
#   - IT DERIVES DOMAIN to the target slug and writes it as a LITERAL line. The
#     Linux supervisor SOURCES the conf raw (not through registry_load) and
#     REFUSES a session with no DOMAIN — it derives the per-domain credential
#     directory from it. `session add` writes the same derived DOMAIN, so the
#     two verbs agree and a migrated session can actually start.
#   - IT IS ABORTABLE WITH NO LOSS: every gate (already-migrated, missing
#     row, unresolvable account/target, taken slug) refuses BEFORE the old
#     conf is touched. The old row is unlinked only after the new one is
#     readable through registry_load.
#
# The writer transaction (lock, stage, chmod-hard-refuse, no-clobber publish,
# canonical readback, fail-closed rollback) and the atomic composite gate are
# the SAME registry_row_write core test/registry-org-verbs.test.sh proves
# adversarially — this suite does not repeat that matrix.
#
# HERMETIC: a fresh mktemp estate per run, STEWARD_CONFIG_FILE pinned to a
# path that cannot exist. Owner names in fixtures are "a" and "b", the letter
# convention the neighbouring suites already carry; nothing real.
set -u

here="$(CDPATH= cd -- "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
STEWARD="$here/bin/steward"
pass=0; fail=0
ok()  { pass=$((pass+1)); printf '  ok   %s\n' "$1"; }
bad() { fail=$((fail+1)); printf '  FAIL %s\n     %s\n' "$1" "${2:-}"; }
is()    { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "wanted '$3', got '$2'"; fi; }
has()   { case "$2" in *"$3"*) ok "$1" ;; *) bad "$1" "missing '$3' in: $2" ;; esac; }
absent(){ if [ ! -e "$2" ]; then ok "$1"; else bad "$1" "unexpectedly exists: $2"; fi; }
present(){ if [ -e "$2" ]; then ok "$1"; else bad "$1" "expected to exist: $2"; fi; }

FX="$(mktemp -d)"; trap 'rm -rf "$FX"' EXIT
mkdir -p "$FX/estate" "$FX/accounts.d" "$FX/hosts.d" "$FX/sessions.d" \
         "$FX/entities.d" "$FX/projects.d"
SESS="$FX/sessions.d"

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
EOF

cat > "$FX/hosts.d/h1.conf" <<'EOF'
OWNER="a"
LEGAL_OWNER="Fixture Co"
OPERATOR="a"
EOF

printf 'PRINCIPAL="a"\nHOST="h1"\n' > "$FX/accounts.d/a-h1.conf"
printf 'PRINCIPAL="b"\nHOST="h1"\n' > "$FX/accounts.d/b-h1.conf"

printf 'NAME="Alpha"\nMEMBERS="a"\n'  > "$FX/entities.d/alpha.conf"
printf 'NAME="Site"\nPARENT="alpha"\n' > "$FX/projects.d/site.conf"

run() {
  STEWARD_ESTATE_ROOT="$FX" STEWARD_CONFIG_FILE="$FX/no-such-config" \
  bash "$STEWARD" registry migrate-session "$@" 2>&1
}

# load_field <id> <FIELD> — the value the REAL reader assigns FIELD after
# loading the new row. Prints nothing (and exits 1) if the row does not load.
load_field() {
  (
    export STEWARD_ESTATE_ROOT="$FX" STEWARD_CONFIG_FILE="$FX/no-such-config"
    # shellcheck source=/dev/null
    . "$here/lib/registry.sh"
    registry_load "$1" >/dev/null 2>&1 || exit 1
    eval "printf '%s' \"\${$2}\""
  )
}
display_of() {
  (
    export STEWARD_ESTATE_ROOT="$FX" STEWARD_CONFIG_FILE="$FX/no-such-config"
    # shellcheck source=/dev/null
    . "$here/lib/registry.sh"
    registry_session_display "$1" 2>/dev/null
  )
}
row_count() { ls "$SESS" 2>/dev/null | grep -c '\.conf$'; }

echo "== 1. old-shape -> new-shape: every operational field preserved =="
cat > "$SESS/oldsess.conf" <<'EOF'
OWNER="a"
DOMAIN="alpha"
RC_LABEL="Old: x"
HOST="h1"
REPO_PATH="/r"
RUNTIME="opencode"
MODEL="openai/x"
OPENCODE_VERSION="1.2.3"
OPENCODE_PORT="3099"
AUTO_APPROVE="true"
CLAUDE_MEMORY_ROOT="/m"
ASSETS="a b"
EOF
out="$(run oldsess --account a-h1 --entity alpha --slug hub --json)"; rc=$?
is  "1: rc 0"          "$rc" "0"
is  "1: ok true"       "$(printf '%s' "$out" | jq -r '.ok')" "true"
is  "1: kind"          "$(printf '%s' "$out" | jq -r '.kind')" "migrate-session"
is  "1: from names the old slug" "$(printf '%s' "$out" | jq -r '.from')" "oldsess"
ID1="$(printf '%s' "$out" | jq -r '.id')"
if [[ "$ID1" =~ ^s-[0-9a-f]{16}$ ]]; then ok "1: id minted opaque (s-<16 hex>)"; else bad "1: id minted opaque (s-<16 hex>)" "got '$ID1'"; fi
present "1: the new row exists on disk" "$SESS/$ID1.conf"
absent  "1: the OLD row was removed"    "$SESS/oldsess.conf"
# EVERY OPERATIONAL FIELD, read back through the real loader.
is "1: REPO_PATH preserved"          "$(load_field "$ID1" REPO_PATH)" "/r"
is "1: HOST preserved"               "$(load_field "$ID1" HOST)" "h1"
is "1: RUNTIME preserved"            "$(load_field "$ID1" RUNTIME)" "opencode"
is "1: MODEL preserved"              "$(load_field "$ID1" MODEL)" "openai/x"
is "1: OPENCODE_VERSION preserved"   "$(load_field "$ID1" OPENCODE_VERSION)" "1.2.3"
is "1: OPENCODE_PORT preserved"      "$(load_field "$ID1" OPENCODE_PORT)" "3099"
is "1: AUTO_APPROVE preserved"       "$(load_field "$ID1" AUTO_APPROVE)" "true"
is "1: CLAUDE_MEMORY_ROOT preserved" "$(load_field "$ID1" CLAUDE_MEMORY_ROOT)" "/m"
is "1: ASSETS preserved"             "$(load_field "$ID1" ASSETS)" "a b"
# THE IDENTITY FIELDS, added.
is "1: OWNER rewritten to the account principal" "$(load_field "$ID1" OWNER)" "a"
is "1: ACCOUNT added"      "$(load_field "$ID1" ACCOUNT)" "a-h1"
is "1: SLUG added"         "$(load_field "$ID1" SLUG)" "hub"
is "1: TARGET_ENTITY added" "$(load_field "$ID1" TARGET_ENTITY)" "alpha"
# RC_LABEL removed; DOMAIN DERIVED to the target slug and stored as a literal
# line (the raw-sourcing supervisor reads it, and registry_load agrees).
is "1: no RC_LABEL line stored" "$(grep -c '^RC_LABEL=' "$SESS/$ID1.conf")" "0"
is "1: DOMAIN derived to the target slug, stored literally" "$(grep -c '^DOMAIN="alpha"$' "$SESS/$ID1.conf")" "1"
is "1: registry_load reads DOMAIN=<target slug>" "$(load_field "$ID1" DOMAIN)" "alpha"
# THE DISPLAY now derives from the target.
is "1: display derives from the entity" "$(display_of "$ID1")" "Alpha"

echo "== 2. project target: the display walks root->leaf =="
cat > "$SESS/oldproj.conf" <<'EOF'
OWNER="a"
DOMAIN="alpha"
RC_LABEL="whatever"
REPO_PATH="/p"
EOF
out="$(run oldproj --account a-h1 --project site --slug web --json)"; rc=$?
is "2: rc 0" "$rc" "0"
ID2="$(printf '%s' "$out" | jq -r '.id')"
is "2: target kind project" "$(printf '%s' "$out" | jq -r '.target.kind')" "project"
is "2: TARGET_PROJECT set" "$(load_field "$ID2" TARGET_PROJECT)" "site"
is "2: no TARGET_ENTITY line stored" "$(grep -c '^TARGET_ENTITY=' "$SESS/$ID2.conf")" "0"
# THE CREDENTIAL-DRIFT RULE (adversarial review of 5b3b165): the old conf's
# DOMAIN is an OPERATIONAL field — the Linux supervisor builds the per-domain
# credential directory from it, with no inheritance chain. Deriving the LEAF
# target slug here silently orphaned the shared credential dir for every
# session migrated to a sub-project (the tool then reads "not logged in" — the
# exact symptom class the identity spec's findings warn mints second identities
# against customer tenants) and narrowed the bus same-DOMAIN gate. So migrate
# CARRIES the old DOMAIN; only a conf with none at all falls back to the
# target slug (so the supervisor's DOMAIN-required start never refuses).
is "2: DOMAIN CARRIED from the old conf (credential continuity), not the leaf slug" "$(load_field "$ID2" DOMAIN)" "alpha"
is "2: carried DOMAIN stored as a literal line" "$(grep -c '^DOMAIN="alpha"$' "$SESS/$ID2.conf")" "1"
is "2: display walks Alpha->Site" "$(display_of "$ID2")" "Alpha→Site"
is "2: display echoed in JSON" "$(printf '%s' "$out" | jq -r '.display')" "Alpha→Site"
absent "2: old row removed" "$SESS/oldproj.conf"

echo "== 2b. the plain (non-JSON) mapping line =="
cat > "$SESS/oldplain.conf" <<'EOF'
OWNER="a"
DOMAIN="alpha"
RC_LABEL="x"
REPO_PATH="/pp"
EOF
plain="$(run oldplain --account a-h1 --entity alpha --slug plainslug)"; rc=$?
is  "2b: rc 0" "$rc" "0"
has "2b: mapping names the old slug and the arrow" "$plain" "migrated oldplain ->"
has "2b: mapping carries the derived display" "$plain" "display: Alpha"

echo "== 2c. an old conf with NO DOMAIN at all: fall back to the target slug =="
cat > "$SESS/olddomless.conf" <<'EOF'
OWNER="a"
REPO_PATH="/p"
EOF
out="$(run olddomless --account a-h1 --project site --slug domless --json)"; rc=$?
is "2c: rc 0" "$rc" "0"
IDB="$(printf '%s' "$out" | jq -r '.id')"
is "2c: DOMAIN falls back to the target slug (the supervisor requires a line)" "$(load_field "$IDB" DOMAIN)" "site"

echo "== 2d. FAIL-CLOSED on an unmodeled field: refuse and name it; dead knowns are ignored =="
# The carry-loop is a hand-maintained allowlist. A field OUTSIDE the model
# must never be dropped silently at rc 0 — a future optional operational
# field forgotten in the loop would vanish across the cut. Refusal names the
# field so a human decides: extend the model, or clean the conf. SESSION_NAME
# is the known-dead exception: three live confs carry it, and registry_load
# overwrites it unconditionally, so dropping it is correct, not a loss.
cat > "$SESS/oldunknown.conf" <<'EOF'
OWNER="a"
DOMAIN="alpha"
REPO_PATH="/p"
FUTURE_FIELD="x"
EOF
out="$(run oldunknown --account a-h1 --entity alpha --slug unk 2>&1)"; rc=$?
is "2d: unmodeled field refused rc 65" "$rc" "65"
case "$out" in *FUTURE_FIELD*) ok "2d: the refusal names the field" ;; *) bad "2d: the refusal names the field" "got: $out" ;; esac
is "2d: old conf untouched by the refusal" "$(grep -c '^FUTURE_FIELD="x"$' "$SESS/oldunknown.conf")" "1"
rm -f "$SESS/oldunknown.conf"
cat > "$SESS/olddead.conf" <<'EOF'
OWNER="a"
DOMAIN="alpha"
REPO_PATH="/p"
SESSION_NAME="olddead"
EOF
out="$(run olddead --account a-h1 --entity alpha --slug deadok --json)"; rc=$?
is "2d: known-dead SESSION_NAME still migrates rc 0" "$rc" "0"
IDD="$(printf '%s' "$out" | jq -r '.id')"
is "2d: the dead line is not carried" "$(grep -c '^SESSION_NAME=' "$SESS/$IDD.conf")" "0"

echo "== 3. idempotence and safety: abortable with no loss =="
# 3a. Already NEW-SHAPE (carries ACCOUNT) — refuse, touch nothing.
cat > "$SESS/already.conf" <<'EOF'
ID="s-00112233445566aa"
ACCOUNT="a-h1"
SLUG="already"
TARGET_ENTITY="alpha"
OWNER="a"
REPO_PATH="/a"
EOF
before="$(row_count)"
out="$(run already --account a-h1 --entity alpha --slug newname --json)"; rc=$?
is  "3a: already-migrated refuses rc 65" "$rc" "65"
present "3a: the already-new row is untouched" "$SESS/already.conf"
is  "3a: no row was added or removed" "$(row_count)" "$before"
# 3b. Missing old row.
out="$(run ghost --account a-h1 --entity alpha --slug g1 --json)"; rc=$?
is  "3b: missing old row refuses rc 78" "$rc" "78"
# 3c. Unresolvable account — old row UNTOUCHED (no loss).
cat > "$SESS/oldsafe.conf" <<'EOF'
OWNER="a"
DOMAIN="alpha"
RC_LABEL="x"
REPO_PATH="/s"
EOF
before="$(row_count)"
out="$(run oldsafe --account nobody-h9 --entity alpha --slug g2 --json)"; rc=$?
is  "3c: unresolvable account refuses rc 78" "$rc" "78"
present "3c: the old row is UNTOUCHED (abortable, no loss)" "$SESS/oldsafe.conf"
is  "3c: nothing was written" "$(row_count)" "$before"
# 3d. Unresolvable target — old row UNTOUCHED.
out="$(run oldsafe --account a-h1 --project no-such --slug g3 --json)"; rc=$?
is  "3d: unresolvable target refuses rc 78" "$rc" "78"
present "3d: the old row is still UNTOUCHED" "$SESS/oldsafe.conf"
# 3e. Composite (account, slug) already taken — old row UNTOUCHED.
#     'hub' in account a-h1 was claimed by case 1.
before="$(row_count)"
out="$(run oldsafe --account a-h1 --entity alpha --slug hub --json)"; rc=$?
is  "3e: taken (account, slug) refuses rc 65" "$rc" "65"
present "3e: the old row is UNTOUCHED after the taken-slug refusal" "$SESS/oldsafe.conf"
is  "3e: nothing was written" "$(row_count)" "$before"
# 3f. Typed union: both / neither target.
out="$(run oldsafe --account a-h1 --entity alpha --project site --slug g4 --json)"; rc=$?
is  "3f: both targets refuse rc 64" "$rc" "64"
out="$(run oldsafe --account a-h1 --slug g5 --json)"; rc=$?
is  "3f: no target refuses rc 64" "$rc" "64"
present "3f: old row survives the union refusals" "$SESS/oldsafe.conf"

echo "== 4. field preservation under injection: a hostile ASSETS is inert =="
# The stored value is ALREADY escaped, exactly as _registry_emit_kv would have
# written it — a conf that was itself written safely. Sourcing it (at snapshot
# time, and later at readback) must yield the LITERAL string, never run it.
CANARY="$FX/pwned"
printf 'OWNER="a"\nDOMAIN="alpha"\nRC_LABEL="x"\nREPO_PATH="/i"\nASSETS="\\$(touch %s) \\`touch %s\\`"\n' \
  "$CANARY" "$CANARY" > "$SESS/oldinj.conf"
out="$(run oldinj --account a-h1 --entity alpha --slug injslug --json)"; rc=$?
is  "4: rc 0" "$rc" "0"
ID4="$(printf '%s' "$out" | jq -r '.id')"
absent "4: the injection did NOT execute (no canary at snapshot/write time)" "$CANARY"
is "4: ASSETS round-trips to the literal string, inert" \
   "$(load_field "$ID4" ASSETS)" "\$(touch $CANARY) \`touch $CANARY\`"
absent "4: still no canary after the reader loaded it" "$CANARY"
absent "4: old injected row removed" "$SESS/oldinj.conf"

echo
echo "pass=$pass fail=$fail"
[ "$fail" -eq 0 ]
