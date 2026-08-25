#!/bin/bash
# Start an OpenCode session from Steward's registry.  The server exists only
# long enough to create the one durable OpenCode session; every later launch
# resumes that exact ID directly in the TUI.
set -uo pipefail

_self="${BASH_SOURCE[0]}"
while [ -L "$_self" ]; do
  _link="$(readlink "$_self")"
  case "$_link" in
    /*) _self="$_link" ;;
    *) _self="$(dirname "$_self")/$_link" ;;
  esac
done
_runtime_dir="$(CDPATH= cd -- "$(dirname "$_self")" && pwd)"

_registry_default() {
  local candidate
  for candidate in "$HOME/scripts/lib/registry.sh" "$_runtime_dir/../lib/registry.sh"; do
    [ -f "$candidate" ] && { printf '%s' "$candidate"; return 0; }
  done
  printf '%s' "$HOME/scripts/lib/registry.sh"
}

refuse() {
  local code="$1"; shift
  echo "opencode-session: REFUSING — $*" >&2
  exit "$code"
}

NAME="${1:-}"
[ -n "$NAME" ] || refuse 64 "usage: opencode-session.sh <registered-session-name>"

REGISTRY_LIB="${STEWARD_REGISTRY_LIB:-$(_registry_default)}"
[ -f "$REGISTRY_LIB" ] || refuse 78 "registry library missing: $REGISTRY_LIB"
# shellcheck source=/dev/null
. "$REGISTRY_LIB" || refuse 78 "registry library could not be read: $REGISTRY_LIB"
registry_load "$NAME" >/dev/null || refuse 78 "registered session could not be loaded: $NAME"
[ "$RUNTIME" = "opencode" ] || refuse 78 "$NAME is not an OpenCode session"

cd "$REPO_PATH" 2>/dev/null || refuse 65 "repository is unavailable: $REPO_PATH"

OPENCODE_BIN="${STEWARD_OPENCODE_BIN:-$HOME/.local/share/opencode/$OPENCODE_VERSION/node_modules/.bin/opencode}"
CURL_BIN="${STEWARD_CURL_BIN:-/usr/bin/curl}"
STATE_DIR="${STEWARD_OPENCODE_STATE_DIR:-$HOME/.local/state/$(registry_state_dir_name)}"
RSYNC_BIN="${STEWARD_RSYNC_BIN:-rsync}"

[ -x "$OPENCODE_BIN" ] || refuse 78 "OpenCode binary missing or not executable: $OPENCODE_BIN"
installed_version="$("$OPENCODE_BIN" --version 2>/dev/null)"
[ "$installed_version" = "1.18.14" ] || refuse 78 "OpenCode must be exactly 1.18.14 (got '${installed_version:-missing}')"
[ -d "$CLAUDE_MEMORY_ROOT" ] || refuse 65 "Claude memory source is unavailable: $CLAUDE_MEMORY_ROOT"

umask 077
mkdir -p "$STATE_DIR" || refuse 70 "could not create state directory: $STATE_DIR"

SESSION_FILE="$STATE_DIR/$SESSION_NAME.opencode-session"
PASSWORD_FILE="$STATE_DIR/$SESSION_NAME.opencode-password"
CONFIG_FILE="$STATE_DIR/$SESSION_NAME.opencode.json"
INSTRUCTIONS_FILE="$STATE_DIR/$SESSION_NAME.opencode-instructions.md"
SNAPSHOT_DIR="$STATE_DIR/$SESSION_NAME.memory"
PROPOSALS_DIR="$STATE_DIR/$SESSION_NAME.memory-proposals"

source_hash() {
  find "$CLAUDE_MEMORY_ROOT" -type f -exec shasum -a 256 {} \; | sort
}

source_before="$(source_hash)" || refuse 65 "could not hash Claude memory source"
mkdir -p "$SNAPSHOT_DIR" "$PROPOSALS_DIR" || refuse 70 "could not create isolated memory state"
chmod u+rwx "$PROPOSALS_DIR" || refuse 70 "could not make memory proposals writable"
chmod -R u+w "$SNAPSHOT_DIR" || refuse 70 "could not prepare memory snapshot for refresh"
"$RSYNC_BIN" -a --delete "$CLAUDE_MEMORY_ROOT/" "$SNAPSHOT_DIR/" || refuse 70 "could not refresh memory snapshot"
source_after="$(source_hash)" || refuse 65 "could not re-hash Claude memory source"
[ "$source_before" = "$source_after" ] || refuse 65 "Claude memory changed while its snapshot was copied"
chmod -R a-w "$SNAPSHOT_DIR" || refuse 70 "could not lock memory snapshot read-only"

# THE ESTATE'S BASE INSTRUCTION — NAMED BY THE ESTATE, PASSED THROUGH BY US.
#
# Measured 2026-08-25 on the first live session: the generated text said "Use
# the Steward bus instructions already present in the user's global agent
# instructions" and NO SUCH FILE EXISTED anywhere. The session was pointed at a
# document that had never been written. It answered correctly anyway, but by
# luck — it found the authority rule in the read-only memory snapshot. A runtime
# that depends on luck for its ground rules has none.
#
# THE SPLIT: the product knows that a runtime HAS a base instruction and where
# it is read from. The estate owns what it SAYS — envelope format, authority,
# commit routine are an estate's rules, not a mechanism's. So we pass a path
# through and never invent content.
#
# NAMED BUT ABSENT IS A REFUSAL. An estate that names a file it did not ship has
# a broken estate; starting anyway would hide it behind a session that merely
# behaves oddly. Unset is silence — no promise of a file that is not there,
# because a reader who goes looking and finds nothing learns to distrust the rest.
ESTATE_CONF="$(registry_estate_file)" || refuse 78 "could not resolve the estate file"
ESTATE_ROOT_DIR="$(CDPATH= cd -- "$(dirname "$ESTATE_CONF")/.." && pwd)" \
  || refuse 70 "could not resolve the estate root"
BASE_INSTRUCTIONS="$(sed -n 's/^AGENT_INSTRUCTIONS="\(.*\)"/\1/p' "$ESTATE_CONF" 2>/dev/null | head -1)"
BASE_INSTRUCTIONS_PATH=""
if [ -n "$BASE_INSTRUCTIONS" ]; then
  case "$BASE_INSTRUCTIONS" in
    /*) BASE_INSTRUCTIONS_PATH="$BASE_INSTRUCTIONS" ;;
    *)  BASE_INSTRUCTIONS_PATH="$ESTATE_ROOT_DIR/$BASE_INSTRUCTIONS" ;;
  esac
  [ -f "$BASE_INSTRUCTIONS_PATH" ] || refuse 78 \
    "the estate names AGENT_INSTRUCTIONS=$BASE_INSTRUCTIONS but no such file exists at $BASE_INSTRUCTIONS_PATH"
fi

cat > "$INSTRUCTIONS_FILE" <<EOF
You are the OpenCode Steward bootstrap session named $SESSION_NAME.
Read the memory snapshot supplied in OpenCode instructions before planning work.
The snapshot is derived from Claude memory and must never be edited.
Snapshot: $SNAPSHOT_DIR
Write durable-memory proposals as separate Markdown files in the configured memory-proposals directory.
Memory proposals: $PROPOSALS_DIR
Work only in the current git worktree; never switch another agent's checkout.
EOF
chmod 600 "$INSTRUCTIONS_FILE" || refuse 70 "could not secure OpenCode instructions"

cat > "$CONFIG_FILE" <<EOF
{
  "model": "$MODEL",
  "instructions": [$( [ -n "$BASE_INSTRUCTIONS_PATH" ] && printf '"%s", ' "$BASE_INSTRUCTIONS_PATH" )"$INSTRUCTIONS_FILE"],
  "permission": {
    "*": "allow",
    "external_directory": {
      "$STATE_DIR": "allow"
    },
    "edit": {
      "$SNAPSHOT_DIR/**": "deny"
    }
  }
}
EOF
chmod 600 "$CONFIG_FILE" || refuse 70 "could not secure OpenCode configuration"
export OPENCODE_CONFIG="$CONFIG_FILE"

TEMP_SERVER_PID=""
cleanup_server() {
  if [ -n "${TEMP_SERVER_PID:-}" ]; then
    kill "$TEMP_SERVER_PID" 2>/dev/null || true
    wait "$TEMP_SERVER_PID" 2>/dev/null || true
    TEMP_SERVER_PID=""
  fi
}
trap 'cleanup_server' EXIT
trap 'cleanup_server; exit 130' INT
trap 'cleanup_server; exit 143' TERM

create_password() {
  local temporary password
  password="$(LC_ALL=C tr -dc 'A-Za-z0-9' < /dev/urandom | head -c 32)"
  [ "${#password}" -eq 32 ] || refuse 70 "could not generate a 32-character server password"
  temporary="$(mktemp "$PASSWORD_FILE.XXXXXX")" || refuse 70 "could not make password temporary file"
  printf '%s' "$password" > "$temporary" || refuse 70 "could not write server password"
  chmod 600 "$temporary" || refuse 70 "could not secure server password"
  mv -f "$temporary" "$PASSWORD_FILE" || refuse 70 "could not atomically persist server password"
}

curl_with_password() {
  printf 'user = "opencode:%s"\n' "$OPENCODE_SERVER_PASSWORD" |
    "$CURL_BIN" --config - -fsS "$@"
}

if [ -f "$SESSION_FILE" ]; then
  SESSION_ID="$(cat "$SESSION_FILE")"
  [[ "$SESSION_ID" =~ ^ses_[A-Za-z0-9_-]+$ ]] || refuse 65 "saved OpenCode session ID is malformed"
else
  if [ ! -f "$PASSWORD_FILE" ]; then create_password; fi
  chmod 600 "$PASSWORD_FILE" || refuse 70 "could not secure server password"
  OPENCODE_SERVER_PASSWORD="$(cat "$PASSWORD_FILE")"
  [ "${#OPENCODE_SERVER_PASSWORD}" -eq 32 ] || refuse 65 "saved server password is malformed"
  export OPENCODE_SERVER_PASSWORD

  "$OPENCODE_BIN" serve --hostname 127.0.0.1 --port "$OPENCODE_PORT" >/dev/null 2>&1 &
  TEMP_SERVER_PID=$!
  healthy=""
  attempt=0
  while [ "$attempt" -lt 10 ]; do
    health="$(curl_with_password "http://127.0.0.1:$OPENCODE_PORT/global/health" 2>/dev/null)"
    case "$health" in
      *'"healthy":true'*'"version":"1.18.14"'*) healthy=1; break ;;
    esac
    attempt=$((attempt + 1))
    [ "$attempt" -lt 10 ] && sleep 1
  done
  [ -n "$healthy" ] || refuse 65 "OpenCode server at 127.0.0.1:$OPENCODE_PORT is not healthy"

  response="$(curl_with_password -X POST -H 'Content-Type: application/json' \
    -d '{"title":"steward-opencode"}' "http://127.0.0.1:$OPENCODE_PORT/session")" || refuse 65 "could not create OpenCode session"
  SESSION_ID="$(printf '%s\n' "$response" | sed -n 's/.*"id"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p')"
  [[ "$SESSION_ID" =~ ^ses_[A-Za-z0-9_-]+$ ]] || refuse 65 "OpenCode returned a malformed session ID"
  session_temporary="$(mktemp "$SESSION_FILE.XXXXXX")" || refuse 70 "could not make session temporary file"
  printf '%s\n' "$SESSION_ID" > "$session_temporary" || refuse 70 "could not write session temporary file"
  chmod 600 "$session_temporary" || refuse 70 "could not secure session temporary file"
  mv -f "$session_temporary" "$SESSION_FILE" || refuse 70 "could not atomically persist OpenCode session"
  cleanup_server
fi

if [ "$AUTO_APPROVE" = "true" ]; then
  exec "$OPENCODE_BIN" "$REPO_PATH" --session "$SESSION_ID" --model "$MODEL" --hostname 127.0.0.1 --port "$OPENCODE_PORT" --auto
else
  exec "$OPENCODE_BIN" "$REPO_PATH" --session "$SESSION_ID" --model "$MODEL" --hostname 127.0.0.1 --port "$OPENCODE_PORT"
fi
