#!/bin/bash
# Runtime registry contract. Estate-independent: it builds its own.
#
# THIS FILE USED TO SAY "run with the <that estate>'s root" — and meant it. It
# set STEWARD_REGISTRY_DIR but never STEWARD_ESTATE_ROOT, so registry_load fell
# back to <product>/estate/steward.conf, which does not exist in a product
# checkout. Three assertions failed for anyone without that one estate on disk;
# they passed here only because the runner was always handed its root.
#
# A PRODUCT SUITE THAT NEEDS ONE PARTICULAR INSTALLATION IS NOT A PRODUCT SUITE.
# The sibling identity-schema suite already builds its own estate; this one now
# does the same, and the two together are the pattern for every suite after.
#
# THE FIX IS NOT TO SHIP AN estate/steward.conf WITH THE PRODUCT. That path is
# the FALLBACK, so a file there would turn "the estate file is missing" — a
# correct, loud refusal — into a silent success against an example. A real
# installation with a lost estate would then run against the sample instead of
# stopping. The refusal is the feature; the fixture belongs in the test.
set -u

here="$(CDPATH= cd -- "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fixtures="$(mktemp -d)"
set_fixtures="$(mktemp -d)"
estate_root="$(mktemp -d)"
trap 'rm -rf "$fixtures" "$set_fixtures" "$estate_root"' EXIT

# The estate the registry resolves against. Values are deliberately unlike any
# real installation: a fixture that borrows a live estate's names is a fixture
# that stops failing when the live estate changes.
mkdir -p "$estate_root/estate"
# ALL FIFTEEN FIELDS, not the four this suite happens to reach. Each one is a
# refusal waiting to happen: the registry validates the estate as a whole before
# it loads anything, so a fixture missing a field the suite never reads still
# fails every load. Writing them out makes this file double as the contract —
# what an estate must supply before the product will run at all.
cat > "$estate_root/estate/steward.conf" <<'ESTATE'
ESTATE_NAME="fixture"
LABEL_PREFIX="com.fixture.claude"
SCHEMA_VERSION="3"
HUB_HOST="fixturehost"
HUB_SESSION="fixturehub"
HUB_SSH="fixtureuser@fixturehost"
RC_LABEL_PREFIX="Fixture: "
JOB_LABEL_PREFIX="com.fixture.job"
SERVICE_LABEL_PREFIX="com.fixture.service"
BROWSER_LABEL_PREFIX="com.fixture.browser"
OP_TOKEN_FILE_NAME="fixture-token"
STATE_DIR_NAME="fixture-state"
PAUSED_DIR_NAME="fixture-paused"
JOB_LOG_DIR="fixture-logs"
TMUX_SOCKET="fixture-socket"
PING_MSG="fixture ping"
ESTATE
export STEWARD_ESTATE_ROOT="$estate_root"

pass=0; fail=0
ok() { pass=$((pass+1)); }
bad() { echo "FAIL: $1"; fail=$((fail+1)); }
check() { local desc="$1"; shift; if "$@"; then ok; else bad "$desc"; fi; }

write_opencode_conf() { # <path> <port>
  local path="$1" port="$2"
  cat > "$path" <<EOF
REPO_PATH="/Users/alice/Projects/steward-opencode"
RC_LABEL=""
OWNER="alice"
DOMAIN="steward"
RUNTIME="opencode"
MODEL="openai/gpt-5.3-codex"
OPENCODE_VERSION="1.18.14"
OPENCODE_PORT="$port"
AUTO_APPROVE="true"
CLAUDE_MEMORY_ROOT="/Users/alice/.claude/projects/-Users-alice-Projects-steward/memory"
EOF
}

cat > "$fixtures/claude-old.conf" <<'EOF'
REPO_PATH="/Users/alice/Projects/steward"
RC_LABEL="Butler: steward"
OWNER="alice"
DOMAIN="steward"
EOF
write_opencode_conf "$fixtures/opencode-good.conf" 4097

cp "$fixtures/opencode-good.conf" "$fixtures/runtime-unknown.conf"
printf 'RUNTIME="unknown"\n' >> "$fixtures/runtime-unknown.conf"
cp "$fixtures/opencode-good.conf" "$fixtures/model-bad.conf"
printf 'MODEL="gpt-5.3-codex"\n' >> "$fixtures/model-bad.conf"
cp "$fixtures/opencode-good.conf" "$fixtures/version-whitespace.conf"
printf 'OPENCODE_VERSION="1.18. 14"\n' >> "$fixtures/version-whitespace.conf"
cp "$fixtures/opencode-good.conf" "$fixtures/port-low.conf"
printf 'OPENCODE_PORT="1023"\n' >> "$fixtures/port-low.conf"
cp "$fixtures/opencode-good.conf" "$fixtures/port-high.conf"
printf 'OPENCODE_PORT="65536"\n' >> "$fixtures/port-high.conf"
cp "$fixtures/opencode-good.conf" "$fixtures/auto-approve-bad.conf"
printf 'AUTO_APPROVE="yes"\n' >> "$fixtures/auto-approve-bad.conf"
cp "$fixtures/opencode-good.conf" "$fixtures/memory-relative.conf"
printf 'CLAUDE_MEMORY_ROOT="relative/memory"\n' >> "$fixtures/memory-relative.conf"

for required in MODEL OPENCODE_VERSION OPENCODE_PORT AUTO_APPROVE CLAUDE_MEMORY_ROOT; do
  grep -v "^$required=" "$fixtures/opencode-good.conf" > "$fixtures/opencode-missing-$required.conf"
done

cat > "$fixtures/claude-opencode-field.conf" <<'EOF'
REPO_PATH="/Users/alice/Projects/steward"
RC_LABEL="Butler: steward"
OWNER="alice"
DOMAIN="steward"
OPENCODE_PORT="4097"
EOF

export STEWARD_REGISTRY_DIR="$fixtures"
# shellcheck source=/dev/null
source "$here/lib/registry.sh"

registry_load claude-old >/dev/null 2>&1
check "old Claude conf defaults RUNTIME" [ "${RUNTIME:-}" = "claude-code" ]

registry_load opencode-good >/dev/null 2>&1
check "OpenCode runtime loads" [ "${RUNTIME:-}" = "opencode" ]
check "OpenCode model loads" [ "${MODEL:-}" = "openai/gpt-5.3-codex" ]
check "OpenCode version loads" [ "${OPENCODE_VERSION:-}" = "1.18.14" ]
check "OpenCode port loads" [ "${OPENCODE_PORT:-}" = "4097" ]
check "OpenCode auto approval loads" [ "${AUTO_APPROVE:-}" = "true" ]
check "OpenCode Claude memory root loads" \
  [ "${CLAUDE_MEMORY_ROOT:-}" = "/Users/alice/.claude/projects/-Users-alice-Projects-steward/memory" ]

for invalid in runtime-unknown model-bad version-whitespace port-low port-high auto-approve-bad memory-relative claude-opencode-field; do
  if registry_load "$invalid" >/dev/null 2>&1; then
    bad "invalid runtime fixture accepted: $invalid"
  else
    ok
  fi
done

for required in MODEL OPENCODE_VERSION OPENCODE_PORT AUTO_APPROVE CLAUDE_MEMORY_ROOT; do
  if registry_load "opencode-missing-$required" >/dev/null 2>&1; then
    bad "OpenCode fixture missing $required accepted"
  else
    ok
  fi
done

write_opencode_conf "$set_fixtures/first.conf" 4097
write_opencode_conf "$set_fixtures/second.conf" 4097
export STEWARD_REGISTRY_DIR="$set_fixtures"
duplicate_output="$(registry_validate_runtime_set 2>&1)"
duplicate_rc=$?
check "duplicate OpenCode ports are refused" [ "$duplicate_rc" -ne 0 ]
check "duplicate-port refusal names first session" \
  bash -c '[[ "$1" == *first* ]]' _ "$duplicate_output"
check "duplicate-port refusal names second session" \
  bash -c '[[ "$1" == *second* ]]' _ "$duplicate_output"

write_opencode_conf "$set_fixtures/second.conf" 4098
if registry_validate_runtime_set >/dev/null 2>&1; then
  ok
else
  bad "unique OpenCode ports were refused"
fi

echo "pass=$pass fail=$fail"
[ "$fail" -eq 0 ]
