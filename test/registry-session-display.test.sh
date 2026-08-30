#!/bin/bash
# test/registry-session-display.test.sh — the compat reader for the identity
# model (ACCOUNT, SLUG, TARGET_ENTITY, TARGET_PROJECT in registry_load) and
# registry_session_display, the ONE place a session's display string is
# computed.
#
# THE LOAD-BEARING CLAIM IS BYTE-IDENTITY FOR THE LEGACY SHAPE. The registry
# reads LIVE session confs, and every conf that exists when this lands carries
# the old shape (OWNER/DOMAIN/RC_LABEL, none of the identity fields). The
# reader ADDS optional fields; it must change NOTHING about how an old-shape
# row is read, validated or displayed — the first case block below pins the
# two legacy displays (RC_LABEL verbatim; prefix+name when the conf has no
# RC_LABEL row at all, exactly the string the supervisor builds today).
#
# READING IS LENIENT — the registry doctrine that a gap is not a failure. The
# identity fields are validated for SHAPE only, and only when non-empty; they
# are never RESOLVED here (an account or target that does not exist is a gap
# for the reader — strictness belongs to the writer that will set the fields).
# The one semantic gate is the typed union: TARGET_ENTITY and TARGET_PROJECT
# both set is two claims about what the session works on, and refuses.
#
# THE PROJECTION LOADS THROUGH A SUBSHELL. registry_load sources an untrusted
# conf; a row assigning the projection's own lowercase locals would clobber
# them via dynamic scoping the moment the row sourced. The clobber cases below
# prove the printed display survives a conf that declares exactly those names.
#
# HERMETIC: a fresh mktemp estate per run, STEWARD_CONFIG_FILE aimed at a
# path that cannot exist. Owner name in fixtures is "a", the letter
# convention sessions-command.test.sh already carries; nothing real.
set -u

here="$(CDPATH= cd -- "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
pass=0; fail=0
ok()  { pass=$((pass+1)); printf '  ok   %s\n' "$1"; }
bad() { fail=$((fail+1)); printf '  FAIL %s\n     %s\n' "$1" "${2:-}"; }
is()  { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "wanted '$3', got '$2'"; fi; }

FX="$(mktemp -d)"; trap 'rm -rf "$FX"' EXIT
mkdir -p "$FX/estate" "$FX/sessions.d" "$FX/entities.d" "$FX/projects.d"
SESS="$FX/sessions.d"; ENT="$FX/entities.d"; PROJ="$FX/projects.d"

# The full required-key set — registry_load reads several estate values
# unconditionally, and a half-built estate would turn every case below into a
# fixture bug (rc 78) instead of a measurement of the reader.
cat > "$FX/estate/steward.conf" <<'EOF'
ESTATE_NAME="fixture"
SCHEMA_VERSION="3"
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

printf 'NAME="Alpha"\nMEMBERS="a"\n' > "$ENT/alpha.conf"
printf 'NAME="Site"\nPARENT="alpha"\n' > "$PROJ/site.conf"

# in_fixture <fn> [args...] — run one library call hermetically inside the
# fixture estate. OUT carries stdout, RC the exit code; stderr is dropped
# (the refusal cases below assert on RC and on OUT staying empty, not on
# wording).
in_fixture() {
  OUT="$(
    export STEWARD_REGISTRY_DIR="$SESS" STEWARD_ESTATE_ROOT="$FX" \
           STEWARD_ENTITY_DIR="$ENT" STEWARD_PROJECT_DIR="$PROJ" \
           STEWARD_CONFIG_FILE="$FX/no-such-config"
    . "$here/lib/registry.sh"
    "$@" 2>/dev/null
  )"
  RC=$?
}

# fields <session> — registry_load in the same hermetic subshell, then print
# the four identity fields the load populated, pipe-joined. Proves the
# FIELD-READ half without asserting anything about display.
fields() {
  OUT="$(
    export STEWARD_REGISTRY_DIR="$SESS" STEWARD_ESTATE_ROOT="$FX" \
           STEWARD_ENTITY_DIR="$ENT" STEWARD_PROJECT_DIR="$PROJ" \
           STEWARD_CONFIG_FILE="$FX/no-such-config"
    . "$here/lib/registry.sh"
    registry_load "$1" >/dev/null 2>&1 || exit $?
    printf '%s|%s|%s|%s' "$ACCOUNT" "$SLUG" "$TARGET_ENTITY" "$TARGET_PROJECT"
  )"
  RC=$?
}

echo "== 1. LEGACY BYTE-IDENTITY — the old shape displays exactly as today =="

echo "-- 1a: RC_LABEL set -> printed verbatim --"
printf 'OWNER="a"\nDOMAIN="acme"\nRC_LABEL="Legacy: thing"\nREPO_PATH="/tmp/x"\n' \
  > "$SESS/legacy-label.conf"
in_fixture registry_session_display legacy-label
is "1a: rc 0"      "$RC"  "0"
is "1a: verbatim"  "$OUT" "Legacy: thing"

echo "-- 1b: no RC_LABEL row -> prefix+name, the supervisor's own construction --"
# The expected value is DERIVED from the same estate value the supervisor
# reads (registry_rc_label_prefix), never hardcoded — if the fixture prefix
# changes, the assertion follows it the way the supervisor would.
in_fixture registry_rc_label_prefix
is "1b precondition: the fixture prefix resolves" "$RC" "0"
expected_fallback="${OUT}legacy-noline"
printf 'OWNER="a"\nDOMAIN="acme"\nREPO_PATH="/tmp/x"\n' > "$SESS/legacy-noline.conf"
in_fixture registry_session_display legacy-noline
is "1b: rc 0"          "$RC"  "0"
is "1b: prefix+name"   "$OUT" "$expected_fallback"

echo "== 2. NEW SHAPE — the display is DERIVED from the target reference =="

printf 'OWNER="a"\nDOMAIN="acme"\nREPO_PATH="/tmp/x"\nTARGET_PROJECT="site"\n' \
  > "$SESS/on-project.conf"
in_fixture registry_session_display on-project
is "2a: rc 0"             "$RC"  "0"
is "2a: project display"  "$OUT" "Alpha→Site"

printf 'OWNER="a"\nDOMAIN="acme"\nREPO_PATH="/tmp/x"\nTARGET_ENTITY="alpha"\n' \
  > "$SESS/on-entity.conf"
in_fixture registry_session_display on-entity
is "2b: rc 0"            "$RC"  "0"
is "2b: entity display"  "$OUT" "Alpha"

echo "== 3. PRECEDENCE — an explicit RC_LABEL wins over the target =="
# RC_LABEL is the legacy override: a row that carries one has chosen its
# display, and the derivation must not second-guess it.
printf 'OWNER="a"\nDOMAIN="acme"\nRC_LABEL="Explicit"\nREPO_PATH="/tmp/x"\nTARGET_PROJECT="site"\n' \
  > "$SESS/both-label.conf"
in_fixture registry_session_display both-label
is "3a: rc 0"          "$RC"  "0"
is "3a: label wins"    "$OUT" "Explicit"

echo "-- 3b: an RC-FREE row (RC_LABEL empty by choice) still derives from its target --"
printf 'OWNER="a"\nDOMAIN="acme"\nRC_LABEL=""\nREPO_PATH="/tmp/x"\nTARGET_ENTITY="alpha"\n' \
  > "$SESS/rcfree-target.conf"
in_fixture registry_session_display rcfree-target
is "3b: rc 0"              "$RC"  "0"
is "3b: derived display"   "$OUT" "Alpha"

echo "== 4. TYPED UNION — both targets set is two claims, and refuses =="
printf 'OWNER="a"\nDOMAIN="acme"\nRC_LABEL="L"\nREPO_PATH="/tmp/x"\nTARGET_ENTITY="alpha"\nTARGET_PROJECT="site"\n' \
  > "$SESS/both-targets.conf"
in_fixture registry_load both-targets
is "4a: registry_load rc 1" "$RC" "1"
in_fixture registry_session_display both-targets
is "4b: display refuses too" "$RC" "1"
is "4b: no output"           "$OUT" ""

echo "== 5. FORGE AND CLOBBER — the step-5 hardening is inherited, not bypassed =="

echo "-- 5a: a target whose NAME carries the separator refuses; nothing is invented --"
printf 'NAME="Evil%sFake"\n' '→' > "$ENT/forged.conf"
printf 'OWNER="a"\nDOMAIN="acme"\nREPO_PATH="/tmp/x"\nTARGET_ENTITY="forged"\n' \
  > "$SESS/on-forged.conf"
in_fixture registry_session_display on-forged
is "5a: rc 1"       "$RC"  "1"
is "5a: no output"  "$OUT" ""

echo "-- 5b: a target whose NAME carries a bidi control refuses --"
printf 'NAME="Bidi\xe2\x80\xaeName"\n' > "$ENT/bidi.conf"
printf 'OWNER="a"\nDOMAIN="acme"\nREPO_PATH="/tmp/x"\nTARGET_ENTITY="bidi"\n' \
  > "$SESS/on-bidi.conf"
in_fixture registry_session_display on-bidi
is "5b: rc 1"       "$RC"  "1"
is "5b: no output"  "$OUT" ""

echo "-- 5c: a target that does not resolve refuses; no display is invented --"
printf 'OWNER="a"\nDOMAIN="acme"\nREPO_PATH="/tmp/x"\nTARGET_PROJECT="renamed-away"\n' \
  > "$SESS/on-gone.conf"
in_fixture registry_session_display on-gone
is "5c: rc 1"       "$RC"  "1"
is "5c: no output"  "$OUT" ""

echo "-- 5d: a conf declaring the projection's own lowercase locals cannot corrupt it --"
# `source` can set ANY variable; via dynamic scoping a hostile row could
# reach the projection's own locals if the load ran in the projection's
# shell. Every name the projection uses is assigned here, and the display
# must come out clean anyway — the subshelled-load proof.
cat > "$SESS/clobber-target.conf" <<'EOF'
OWNER="a"
DOMAIN="acme"
REPO_PATH="/tmp/x"
TARGET_ENTITY="alpha"
slug="evil"
account="evil"
name="evil"
conf="evil"
snap="evil"
rest="evil"
label="evil"
disp="evil"
tproj="evil"
tent="evil"
_prefix="evil"
EOF
in_fixture registry_session_display clobber-target
is "5d: rc 0"            "$RC"  "0"
is "5d: display intact"  "$OUT" "Alpha"

echo "-- 5e: the same assignments under an explicit RC_LABEL leave it verbatim --"
cat > "$SESS/clobber-label.conf" <<'EOF'
OWNER="a"
DOMAIN="acme"
RC_LABEL="Mine"
REPO_PATH="/tmp/x"
slug="evil"
label="evil"
snap="evil"
_prefix="evil"
EOF
in_fixture registry_session_display clobber-label
is "5e: rc 0"            "$RC"  "0"
is "5e: label intact"    "$OUT" "Mine"

echo "== 6. FIELD READ — lenient population, shape-only validation =="

echo "-- 6a: a new-shape conf populates all four fields --"
printf 'OWNER="a"\nDOMAIN="acme"\nRC_LABEL="L"\nREPO_PATH="/tmp/x"\nACCOUNT="a-h1"\nSLUG="alpha"\nTARGET_PROJECT="site"\n' \
  > "$SESS/new-shape.conf"
fields new-shape
is "6a: rc 0"    "$RC"  "0"
is "6a: fields"  "$OUT" "a-h1|alpha||site"

echo "-- 6b: an old-shape conf reads with every identity field empty --"
fields legacy-label
is "6b: rc 0"          "$RC"  "0"
is "6b: all empty"     "$OUT" "|||"

echo "-- 6c: ACCOUNT carrying a path escape refuses --"
printf 'OWNER="a"\nDOMAIN="acme"\nRC_LABEL="L"\nREPO_PATH="/tmp/x"\nACCOUNT="../x"\n' \
  > "$SESS/bad-account.conf"
fields bad-account
is "6c: rc 1" "$RC" "1"

echo "-- 6d: ACCOUNT carrying a control byte refuses --"
printf 'OWNER="a"\nDOMAIN="acme"\nRC_LABEL="L"\nREPO_PATH="/tmp/x"\nACCOUNT="a\tb"\n' \
  > "$SESS/ctl-account.conf"
fields ctl-account
is "6d: rc 1" "$RC" "1"

echo "-- 6e: SLUG with an uppercase letter refuses (shape, not resolution) --"
printf 'OWNER="a"\nDOMAIN="acme"\nRC_LABEL="L"\nREPO_PATH="/tmp/x"\nSLUG="Alpha"\n' \
  > "$SESS/bad-slug.conf"
fields bad-slug
is "6e: rc 1" "$RC" "1"

echo "-- 6f: an account that does not EXIST still reads (a gap is not a failure) --"
# The reader never resolves ACCOUNT/TARGET_* against their registers —
# accounts.d does not even exist in this fixture, and the load succeeds.
printf 'OWNER="a"\nDOMAIN="acme"\nRC_LABEL="L"\nREPO_PATH="/tmp/x"\nACCOUNT="nobody-nowhere"\n' \
  > "$SESS/gap-account.conf"
fields gap-account
is "6f: rc 0"    "$RC"  "0"
is "6f: fields"  "$OUT" "nobody-nowhere|||"

echo "-- 6g: a later load never shows the previous load's identity fields --"
# The reset-block proof: the identity fields sit in the same reset block as
# every other field registry_load owns, so a second load — here an old-shape
# row that declares none of them — starts from empty instead of inheriting
# the first row's values.
OUT="$(
  export STEWARD_REGISTRY_DIR="$SESS" STEWARD_ESTATE_ROOT="$FX" \
         STEWARD_ENTITY_DIR="$ENT" STEWARD_PROJECT_DIR="$PROJ" \
         STEWARD_CONFIG_FILE="$FX/no-such-config"
  . "$here/lib/registry.sh"
  registry_load new-shape >/dev/null 2>&1 || exit 99
  registry_load legacy-label >/dev/null 2>&1 || exit 98
  printf '%s|%s|%s|%s' "$ACCOUNT" "$SLUG" "$TARGET_ENTITY" "$TARGET_PROJECT"
)"
is "6g: reset before source" "$OUT" "|||"

echo "== 7. THE PROJECTION'S OWN REFUSALS =="
in_fixture registry_session_display no-such-session
is "7a: unknown session rc 1" "$RC" "1"
in_fixture registry_session_display 'Bad Name'
is "7b: invalid name rc 1" "$RC" "1"

echo
echo "pass=$pass fail=$fail"
[ "$fail" -eq 0 ]
