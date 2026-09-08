#!/bin/bash
# test/mcp-surface.test.sh - the MCP surface of a session, with the axis each
# asset was granted on, as a JSON contract that carries nothing else.
set -u
here="$(CDPATH= cd -- "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
pass=0; fail=0
ok()  { pass=$((pass+1)); printf '  ok   %s\n' "$1"; }
bad() { fail=$((fail+1)); printf '  FAIL %s\n     %s\n' "$1" "${2:-}"; }
is()  { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "wanted '$3', got '$2'"; fi; }
has() { case "$2" in *"$3"*) ok "$1" ;; *) bad "$1" "missing '$3' in: $2" ;; esac; }
hasnt(){ case "$2" in *"$3"*) bad "$1" "unexpectedly present '$3' in: $2" ;; *) ok "$1" ;; esac; }
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
ROOT="$T/estate"; mkdir -p "$ROOT"/{estate,sessions.d,entities.d,projects.d,accounts.d,mcp.d,hosts.d}
cat > "$ROOT/estate/steward.conf" <<'EOF'
ESTATE_NAME="fixture"
LABEL_PREFIX="com.fixture.claude"
JOB_LABEL_PREFIX="com.fixture.job"
SERVICE_LABEL_PREFIX="com.fixture.svc"
RC_LABEL_PREFIX=""
HUB_SESSION="hub"
HUB_HOST="h1"
STATE_DIR_NAME="fixture-supervisor"
PAUSED_DIR_NAME="fixture-paused"
TMUX_SOCKET="fixture.sock"
OP_TOKEN_FILE_NAME="fixture-token"
PING_MSG="mail"
EOF
printf 'OWNER="a"\nOPERATOR="hub"\n' > "$ROOT/hosts.d/h1.conf"
printf 'NAME="Team"\nMEMBERS="a b"\nMCP_ASSETS="shared"\n' > "$ROOT/entities.d/team.conf"
printf 'NAME="Work"\nPARENT="team"\nMCP_ASSETS="tool"\n' > "$ROOT/projects.d/work.conf"
printf 'PRINCIPAL="a"\nHOST="h1"\nMCP_ASSETS="mail"\n' > "$ROOT/accounts.d/a-h1.conf"
for m in shared tool mail; do
  printf 'MCP_COMMAND="/usr/bin/%s"\nMCP_ARGS="--token SECRETVALUE"\nMCP_ENV_FILE="~/.env"\n' "$m" > "$ROOT/mcp.d/$m.conf"
done
SID="s-0000000000000021"
cat > "$ROOT/sessions.d/$SID.conf" <<EOF
OWNER="a"
HOST="h1"
DOMAIN="work"
REPO_PATH="$T/repo"
ID="$SID"
SLUG="work-a"
ACCOUNT="a-h1"
TARGET_PROJECT="work"
KIND="work"
EOF
export STEWARD_ESTATE_ROOT="$ROOT" STEWARD_CONFIG_FILE="$T/no-such-config"
echo "mcp-surface"
out="$(bash "$here/bin/steward" mcp surface "$SID" --json 2>"$T/err")"; rc=$?
is  "the surface renders" "$rc" "0"
is  "ok is true" "$(printf '%s' "$out" | jq -r .ok)" "true"
is  "three assets, account first" "$(printf '%s' "$out" | jq -r '.assets|map(.id)|join(" ")')" "mail shared tool"
is  "the account axis is named" "$(printf '%s' "$out" | jq -r '.assets[0].axis+" "+.assets[0].source')" "account a-h1"
is  "the entity axis is named" "$(printf '%s' "$out" | jq -r '.assets[1].axis+" "+.assets[1].source')" "entity team"
is  "the project axis is named" "$(printf '%s' "$out" | jq -r '.assets[2].axis+" "+.assets[2].source')" "project work"
hasnt "no command leaks" "$out" "/usr/bin/"
hasnt "no argument leaks" "$out" "SECRETVALUE"
hasnt "no env file leaks" "$out" ".env"
is  "only the four allowed keys" "$(printf '%s' "$out" | jq -r '.assets[0]|keys|join(",")')" "axis,id,name,source"
printf 'NAME="Work"\nPARENT="missing"\n' > "$ROOT/projects.d/work.conf"
out="$(bash "$here/bin/steward" mcp surface "$SID" --json 2>/dev/null)"; rc=$?
is  "a level that will not load refuses" "$rc" "65"
is  "with ok false" "$(printf '%s' "$out" | jq -r .ok)" "false"
printf '\n  %d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
