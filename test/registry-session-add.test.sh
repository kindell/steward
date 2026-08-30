#!/bin/bash
# test/registry-session-add.test.sh — `steward registry session add`, the
# capstone of the identity model: account + target + minted opaque id +
# derived display + composite (ACCOUNT, SLUG) uniqueness, all meeting in one
# writing verb.
#
# WHAT IS SPECIFIC TO THIS VERB, AND THEREFORE PROVED HERE. The writer
# transaction itself (lock, stage, chmod-hard-refuse, no-clobber publish,
# canonical readback, fail-closed rollback) is the SAME registry_row_write
# core test/registry-org-verbs.test.sh already proves adversarially — this
# suite does not repeat that matrix. What this verb adds on top:
#
#   - the account gate: --account must RESOLVE through registry_account_load
#     (subshelled — a hostile account row must not clobber the verb's own
#     locals), and the row's OWNER is the account's PRINCIPAL, snapshotted
#     out of that subshell. That is the bridge that keeps a new-shape row
#     visible and enterable exactly like an old-shape one: visibility and
#     the cockpit's enter gate key on OWNER.
#   - the typed-union target: exactly one of --project/--entity, and it must
#     resolve through its own loader (subshelled, same lesson).
#   - THE COMPOSITE GATE, WIRED AT LAST: registry_account_slug_available was
#     built and tested ahead of this verb, and this is the step that calls
#     it — a second row claiming the same (ACCOUNT, SLUG) pair refuses.
#   - THE MINTED OPAQUE ID: the filename is an id minted from urandom, never
#     derived from account or slug — a future account move is a field
#     change, not a rename. Flat storage is the explicit choice: the
#     account-scoped slug lives as a FIELD, the filename carries only the id.
#   - NO LEGACY FIELDS: the row stores a target REFERENCE, never an RC_LABEL,
#     and no DOMAIN — the display derives from the target at read time.
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

FX="$(mktemp -d)"; trap 'rm -rf "$FX"' EXIT
mkdir -p "$FX/estate" "$FX/accounts.d" "$FX/hosts.d" "$FX/sessions.d" \
         "$FX/entities.d" "$FX/projects.d"
SESS="$FX/sessions.d"

# The full required-key set — the verb's readback goes through registry_load,
# which reads several estate values unconditionally; a half-built estate
# would turn every case below into a fixture bug instead of a measurement.
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

# One valid host — the minimal field set registry_host_load requires, the
# same shape a real hosts.d row carries.
cat > "$FX/hosts.d/h1.conf" <<'EOF'
OWNER="a"
LEGAL_OWNER="Fixture Co"
OPERATOR="a"
EOF

# Two accounts on the same host — the composite gate is scoped PER ACCOUNT,
# and proving that needs a second one.
printf 'PRINCIPAL="a"\nHOST="h1"\n' > "$FX/accounts.d/a-h1.conf"
printf 'PRINCIPAL="b"\nHOST="h1"\n' > "$FX/accounts.d/b-h1.conf"

# One team, one project under it — the display derivation's inputs.
printf 'NAME="Alpha"\nMEMBERS="a"\n'  > "$FX/entities.d/alpha.conf"
printf 'NAME="Site"\nPARENT="alpha"\n' > "$FX/projects.d/site.conf"

# run <args...> — a hermetic invocation of the verb under test.
run() {
  STEWARD_ESTATE_ROOT="$FX" STEWARD_CONFIG_FILE="$FX/no-such-config" \
  bash "$STEWARD" registry session "$@" 2>&1
}

# in_lib <fn> [args...] — one library call inside the fixture estate, in a
# subshell so nothing a load sets ever leaks between checks.
in_lib() {
  (
    export STEWARD_ESTATE_ROOT="$FX" STEWARD_CONFIG_FILE="$FX/no-such-config"
    # shellcheck source=/dev/null
    . "$here/lib/registry.sh"
    "$@"
  )
}

# load_session <id> — round trip through the REAL reader. Prints
# "ACCOUNT|SLUG|TARGET_PROJECT|TARGET_ENTITY|OWNER|HOST|REPO_PATH" on
# success, nothing on failure.
load_session() {
  (
    export STEWARD_ESTATE_ROOT="$FX" STEWARD_CONFIG_FILE="$FX/no-such-config"
    # shellcheck source=/dev/null
    . "$here/lib/registry.sh"
    registry_load "$1" >/dev/null 2>&1 || exit 1
    printf '%s|%s|%s|%s|%s|%s|%s' \
      "$ACCOUNT" "$SLUG" "$TARGET_PROJECT" "$TARGET_ENTITY" "$OWNER" "$HOST" "$REPO_PATH"
  )
}

row_count() { ls "$SESS" 2>/dev/null | grep -c '\.conf$'; }
mode_of()   { stat -f '%Lp' "$1" 2>/dev/null || stat -c '%a' "$1"; }

echo "== 1. happy path: project target, minted id, derived display, owner bridge =="
out="$(run add --account a-h1 --project site --slug web --repo /tmp/fixture-repo --json)"; rc=$?
is  "1: rc 0"           "$rc" "0"
is  "1: ok true"        "$(printf '%s' "$out" | jq -r '.ok')" "true"
is  "1: kind session"   "$(printf '%s' "$out" | jq -r '.kind')" "session"
ID1="$(printf '%s' "$out" | jq -r '.id')"
if [[ "$ID1" =~ ^s-[0-9a-f]{12,}$ ]]; then ok "1: id is opaque hex (s-...)"; else bad "1: id is opaque hex (s-...)" "got '$ID1'"; fi
is  "1: account echoed" "$(printf '%s' "$out" | jq -r '.account')" "a-h1"
is  "1: slug echoed"    "$(printf '%s' "$out" | jq -r '.slug')" "web"
is  "1: target kind"    "$(printf '%s' "$out" | jq -r '.target.kind')" "project"
is  "1: target slug"    "$(printf '%s' "$out" | jq -r '.target.slug')" "site"
is  "1: host defaults to the hub host" "$(printf '%s' "$out" | jq -r '.host')" "h1"
is  "1: owner is the account's principal" "$(printf '%s' "$out" | jq -r '.owner')" "a"
is  "1: repo echoed"    "$(printf '%s' "$out" | jq -r '.repo')" "/tmp/fixture-repo"
is  "1: file named by the id" "$(printf '%s' "$out" | jq -r '.file')" "$SESS/$ID1.conf"
if [ -f "$SESS/$ID1.conf" ]; then ok "1: the row exists on disk"; else bad "1: the row exists on disk" "no $SESS/$ID1.conf"; fi
is  "1: mode 600"       "$(mode_of "$SESS/$ID1.conf")" "600"
is  "1: registry_load round trip (account, slug, target, owner, host, repo)" \
    "$(load_session "$ID1")" "a-h1|web|site||a|h1|/tmp/fixture-repo"
is  "1: display derives from the target" "$(in_lib registry_session_display "$ID1" 2>/dev/null)" "Alpha→Site"
is  "1: no RC_LABEL line stored"  "$(grep -c '^RC_LABEL='  "$SESS/$ID1.conf")" "0"
is  "1: no DOMAIN line stored"    "$(grep -c '^DOMAIN='    "$SESS/$ID1.conf")" "0"
is  "1: PERMISSION_MODE stored"   "$(grep -c '^PERMISSION_MODE="bypassPermissions"$' "$SESS/$ID1.conf")" "1"

echo "== 2. the gates: account, typed union, slug, repo, host =="
before="$(row_count)"
out="$(run add --project site --slug g1 --repo /tmp/x --json)"; rc=$?
is "2: missing --account refuses rc 64" "$rc" "64"
out="$(run add --account nobody-h9 --project site --slug g2 --repo /tmp/x --json)"; rc=$?
is  "2: unknown account refuses rc 78" "$rc" "78"
has "2: the refusal names the account" "$out" "nobody-h9"
out="$(run add --account a-h1 --project site --entity alpha --slug g3 --repo /tmp/x --json)"; rc=$?
is "2: both targets refuse rc 64 (typed union)" "$rc" "64"
out="$(run add --account a-h1 --slug g4 --repo /tmp/x --json)"; rc=$?
is "2: no target refuses rc 64 (typed union)" "$rc" "64"
out="$(run add --account a-h1 --project no-such --slug g5 --repo /tmp/x --json)"; rc=$?
is  "2: unknown project refuses rc 78" "$rc" "78"
has "2: the refusal names the project" "$out" "no-such"
out="$(run add --account a-h1 --entity no-such --slug g6 --repo /tmp/x --json)"; rc=$?
is "2: unknown entity refuses rc 78" "$rc" "78"
out="$(run add --account a-h1 --project site --repo /tmp/x --json)"; rc=$?
is "2: missing --slug refuses rc 64" "$rc" "64"
out="$(run add --account a-h1 --project site --slug 'Bad_Slug' --repo /tmp/x --json)"; rc=$?
is "2: bad slug form refuses rc 64" "$rc" "64"
out="$(run add --account a-h1 --project site --slug g7 --json)"; rc=$?
is "2: missing --repo refuses rc 64" "$rc" "64"
out="$(run add --account a-h1 --project site --slug g8 --repo relative/path --json)"; rc=$?
is "2: relative --repo refuses rc 64" "$rc" "64"
out="$(run add --account a-h1 --project site --slug g9 --repo /tmp/../etc --json)"; rc=$?
is "2: --repo with dot-dot refuses rc 64" "$rc" "64"
out="$(run add --account a-h1 --project site --slug g10 --repo /tmp/x --host 'H!' --json)"; rc=$?
is "2: bad --host form refuses rc 64" "$rc" "64"
out="$(run add --account a-h1 --project site --slug g11 --repo /tmp/x extra-arg --json)"; rc=$?
is "2: a positional argument refuses rc 64 (the id is minted, never given)" "$rc" "64"
is "2: none of the refusals wrote a row" "$(row_count)" "$before"

echo "== 2b. entity target: a team session without a project is legitimate =="
out="$(run add --account a-h1 --entity alpha --slug board --repo /tmp/fixture-repo --json)"; rc=$?
is "2b: rc 0" "$rc" "0"
ID2="$(printf '%s' "$out" | jq -r '.id')"
is "2b: target kind entity" "$(printf '%s' "$out" | jq -r '.target.kind')" "entity"
is "2b: registry_load round trip" "$(load_session "$ID2")" "a-h1|board||alpha|a|h1|/tmp/fixture-repo"
is "2b: display derives from the entity" "$(in_lib registry_session_display "$ID2" 2>/dev/null)" "Alpha"
is "2b: no TARGET_PROJECT line stored" "$(grep -c '^TARGET_PROJECT=' "$SESS/$ID2.conf")" "0"

echo "== 3. the composite gate, wired: (ACCOUNT, SLUG) is unique =="
before="$(row_count)"
out="$(run add --account a-h1 --entity alpha --slug web --repo /tmp/other --json)"; rc=$?
is  "3: same (account, slug) refuses rc 65 — even with a different target" "$rc" "65"
has "3: the refusal names the pair" "$(printf '%s' "$out" | jq -r '.reason')" "slug 'web' is already taken in account 'a-h1'"
is  "3: nothing was written" "$(row_count)" "$before"
out="$(run add --account b-h1 --entity alpha --slug web --repo /tmp/fixture-repo --json)"; rc=$?
is "3: the same slug under a DIFFERENT account is available — rc 0" "$rc" "0"
ID3="$(printf '%s' "$out" | jq -r '.id')"
if [ "$ID3" != "$ID1" ] && [ -n "$ID3" ]; then ok "3: the second row minted its own id"; else bad "3: the second row minted its own id" "got '$ID3'"; fi
# The scan must SEE the earlier rows: the first pair is found through the
# very ACCOUNT/SLUG fields this verb writes, not through anything legacy.
out="$(run add --account b-h1 --project site --slug web --repo /tmp/x --json)"; rc=$?
is "3: and now (b-h1, web) is taken too — the scan reads the row this verb wrote" "$rc" "65"

echo "== 4. injection: hostile values and hostile neighbouring confs =="
before="$(row_count)"
out="$(run add --account a-h1 --project site --slug inj1 --repo "/tmp/\$(touch $FX/pwned-dollar)" --json)"; rc=$?
is     "4: command-substitution repo is accepted as inert bytes (rc 0)" "$rc" "0"
IDD="$(printf '%s' "$out" | jq -r '.id')"
absent "4: ...and sourcing the row runs nothing" "$FX/pwned-dollar"
is     "4: the repo round-trips byte-identical" \
       "$(load_session "$IDD" | cut -d'|' -f7)" "/tmp/\$(touch $FX/pwned-dollar)"
absent "4: ...even after the round trip" "$FX/pwned-dollar"
out="$(run add --account a-h1 --project site --slug inj2 --repo "/tmp/\`touch $FX/pwned-tick\`" --json)"; rc=$?
is     "4: backtick repo — same story (rc 0)" "$rc" "0"
IDT="$(printf '%s' "$out" | jq -r '.id')"
load_session "$IDT" >/dev/null
absent "4: no backtick side effect either" "$FX/pwned-tick"
ctrl="$(printf '/tmp/x\ty')"
out="$(run add --account a-h1 --project site --slug inj3 --repo "$ctrl" --json)"; rc=$?
is "4: a control byte in --repo refuses rc 64" "$rc" "64"
absent "4: control-byte case wrote nothing" "$SESS/inj3.conf"

# A hostile ACCOUNT row declaring the verb's own lowercase locals must not
# divert the write — the load is subshelled, so the assignments die with it.
printf 'PRINCIPAL="a"\nHOST="h1"\nslug="hijacked"\nrepo="/tmp/evil"\naccount="a-h1"\nid="s-ffffffffffff"\n' \
  > "$FX/accounts.d/evil.conf"
out="$(run add --account evil --entity alpha --slug safe --repo /tmp/fixture-repo --json)"; rc=$?
is "4: hostile account conf — the verb still writes what was ASKED (rc 0)" "$rc" "0"
IDE="$(printf '%s' "$out" | jq -r '.id')"
is "4: the slug written is the operator's, not the conf's" \
   "$(load_session "$IDE" | cut -d'|' -f2)" "safe"
is "4: the repo written is the operator's, not the conf's" \
   "$(load_session "$IDE" | cut -d'|' -f7)" "/tmp/fixture-repo"
absent "4: the hostile conf could not steer the filename" "$SESS/s-ffffffffffff.conf"

# Same for a hostile TARGET conf — the entity load is subshelled too.
printf 'NAME="Mal"\nslug="stolen"\nrepo="/tmp/stolen"\n' > "$FX/entities.d/mal.conf"
out="$(run add --account b-h1 --entity mal --slug tgt --repo /tmp/fixture-repo --json)"; rc=$?
is "4: hostile target conf — rc 0, write not diverted" "$rc" "0"
IDM="$(printf '%s' "$out" | jq -r '.id')"
is "4: slug and repo are the operator's own" \
   "$(load_session "$IDM" | cut -d'|' -f2,7)" "tgt|/tmp/fixture-repo"

echo "== 5. the id is opaque: never derived from account or slug =="
case "$ID1" in
  *a-h1*|*web*) bad "5: the id encodes nothing (no account, no slug)" "got '$ID1'" ;;
  *)            ok  "5: the id encodes nothing (no account, no slug)" ;;
esac
if [ "$ID1" != "$ID2" ] && [ "$ID1" != "$ID3" ] && [ "$ID2" != "$ID3" ]; then
  ok "5: every add minted a distinct id"
else
  bad "5: every add minted a distinct id" "$ID1 / $ID2 / $ID3"
fi
# The remint loop cannot be forced deterministically from out here (the next
# mint is random by design), so what IS pinned: distinctness above, the
# opaque form, and the writer's own create-only refusal underneath — a
# colliding mint that somehow survived the remint loop still cannot clobber.

echo
echo "== 6. ATOMIC gate: the composite (account,slug) check runs INSIDE the write lock =="
# A parallel race is non-reproducible; the deterministic proof is that the
# validate_fn (which registry_row_write calls UNDER its lock, before publish)
# itself refuses a staged row whose (account,slug) is already published — with
# cmd's advisory pre-check bypassed. Pre-fix, validate_fn only field-matched
# and this write SUCCEEDED (a TOCTOU winner); now it refuses under the lock.
cat > "$SESS/s-aaaaaaaaaaaaaaaa.conf" <<'EOF'
ID="s-aaaaaaaaaaaaaaaa"
ACCOUNT="a-h1"
SLUG="locked"
TARGET_PROJECT="tgt"
HOST="h1"
REPO_PATH="/tmp/fixture-repo"
OWNER="a"
PERMISSION_MODE="bypassPermissions"
EOF
_DUP='ID="s-bbbbbbbbbbbbbbbb"
ACCOUNT="a-h1"
SLUG="locked"
TARGET_PROJECT="tgt"
HOST="h1"
REPO_PATH="/tmp/fixture-repo"
OWNER="a"
PERMISSION_MODE="bypassPermissions"'
_rc=0
( export STEWARD_ESTATE_ROOT="$FX" STEWARD_CONFIG_FILE="$FX/no-such-config"
  . "$here/lib/registry.sh"
  eval "$(sed -n '/^_registry_validate_session_stage()/,/^}/p' "$STEWARD")"
  export _REGW_EXPECT_ID="s-bbbbbbbbbbbbbbbb" _REGW_EXPECT_ACCOUNT="a-h1" _REGW_EXPECT_SLUG="locked"          _REGW_EXPECT_TARGET_ENTITY="" _REGW_EXPECT_TARGET_PROJECT="tgt" _REGW_EXPECT_HOST="h1"          _REGW_EXPECT_REPO_PATH="/tmp/fixture-repo" _REGW_EXPECT_OWNER="a" _REGW_EXPECT_PERMISSION_MODE="bypassPermissions"
  registry_session_write "s-bbbbbbbbbbbbbbbb" "$_DUP" _registry_validate_session_stage ) >/dev/null 2>&1 || _rc=$?
is "6: a duplicate (account,slug) is refused INSIDE the locked write path" "$( [ "$_rc" -ne 0 ] && echo refused || echo passed )" "refused"
if [ -e "$SESS/s-bbbbbbbbbbbbbbbb.conf" ]; then bad "6: the duplicate row must NOT be published"; else ok "6: no duplicate row published"; fi
rm -f "$SESS/s-aaaaaaaaaaaaaaaa.conf" "$SESS/s-bbbbbbbbbbbbbbbb.conf"

echo "== 6b: PARALLEL sanity — a real race never yields more than one winner =="
for i in $(seq 1 40); do
  ( STEWARD_ESTATE_ROOT="$FX" STEWARD_CONFIG_FILE="$FX/no-such-config"     bash "$STEWARD" registry session add --account a-h1 --project tgt --slug raced --repo /tmp/fixture-repo >/dev/null 2>&1 ) &
done
wait
_won="$(grep -l 'SLUG="raced"' "$SESS"/*.conf 2>/dev/null | wc -l | tr -d ' ')"
is "6b: at most one winner under a 40-way race (got $_won)" "$( [ "${_won:-0}" -le 1 ] && echo ok || echo TOOMANY )" "ok"
grep -l 'SLUG="raced"' "$SESS"/*.conf 2>/dev/null | xargs rm -f 2>/dev/null || true

echo "pass=$pass fail=$fail"
[ "$fail" -eq 0 ]
