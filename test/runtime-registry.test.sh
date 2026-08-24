#!/bin/bash
# Runtime registry contract. Run with the Butler estate root.
set -u

here="$(CDPATH= cd -- "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fixtures="$(mktemp -d)"
set_fixtures="$(mktemp -d)"
trap 'rm -rf "$fixtures" "$set_fixtures"' EXIT

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
