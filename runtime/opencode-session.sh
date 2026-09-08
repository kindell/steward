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
# THE PIN IS THE ROW'S, NOT THIS FILE'S. The row already names the version
# (OPENCODE_VERSION selects the binary's directory above); a literal here made
# the field a lie - a row moved to a newer pin was refused by the runtime that
# had just picked the newer binary from that very field. Measured 2026-09-08.
[ "$installed_version" = "$OPENCODE_VERSION" ] || refuse 78 "OpenCode must be the row's OPENCODE_VERSION ($OPENCODE_VERSION); the binary at $OPENCODE_BIN reports '${installed_version:-missing}'"
[ -d "$CLAUDE_MEMORY_ROOT" ] || refuse 65 "Claude memory source is unavailable: $CLAUDE_MEMORY_ROOT"

umask 077
mkdir -p "$STATE_DIR" || refuse 70 "could not create state directory: $STATE_DIR"

SESSION_FILE="$STATE_DIR/$SESSION_NAME.opencode-session"
MODEL_FILE="$STATE_DIR/$SESSION_NAME.opencode-model"
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

# ── WHO ELSE WORKS ON THIS PROJECT ─────────────────────────────────────────
# A session could always write to another one on the bus and was never told
# there WAS another one, so the fact lived in whichever human remembered it.
#
# READ FROM THE REGISTER ON EVERY RUN, NEVER CACHED. This file is rewritten
# each time the adapter starts, so the list a session reads is the register as
# it stood at that moment. A stored copy would go stale in exactly the case
# that matters — a colleague joining the project after this session did.
#
# THE LIMIT IS HONEST RATHER THAN HIDDEN: a session that is already running
# sees a new mate at its NEXT start, because that is when this file is written.
# Nothing here refreshes a live session.
#
# THE HELPER IS SUBSHELLED, so the row this adapter has loaded — REPO_PATH,
# MODEL, the port it is about to bind — survives the call intact.
#
# THE STATUS IS READ, AND rc 78 IS NAMED AS ITSELF. It used to collapse into
# the same four words as every other failure, so an identity refusal and a
# missing register were indistinguishable in the log.
#
# AND IT DEGRADES RATHER THAN REFUSING, WHICH IS MEASURED, NOT PREFERRED. This
# session's OWN identity claim is already fail-closed at line 38:
# registry_load "$NAME" refuses 78 when the row does not read, which is exactly
# what a dangling or borrowed ACCOUNT on this row produces. So every rc 78 that
# can reach this line belongs to a DIFFERENT row - a colleague on the same
# project whose ACCOUNT will not load, which stops registry_project_mates'
# enumeration. Refusing here would let one broken conf in somebody else's home
# stop a healthy session from starting, which is the fleet-wide stop this
# product removed everywhere else. So the list degrades and the code is stated,
# rather than the session not coming up after a restart.
_mates_rc=0
PROJECT_MATES="$(registry_mates_summary "$NAME")" || _mates_rc=$?
if [ "$_mates_rc" -eq 78 ]; then
  echo "opencode-session: DEGRADED — the register refused another row's identity claim while reading the mates (rc 78, cause above); this session's own row reads, so it starts with an incomplete mate list" >&2
  PROJECT_MATES="unknown - the register refused a row's identity claim while reading the mates back (rc 78)"
elif [ "$_mates_rc" -ne 0 ]; then
  echo "opencode-session: DEGRADED — the mates could not be read back (rc $_mates_rc)" >&2
  PROJECT_MATES="unknown - the register could not be read back"
fi

cat > "$INSTRUCTIONS_FILE" <<EOF
You are the OpenCode Steward bootstrap session named $SESSION_NAME.
Read the memory snapshot supplied in OpenCode instructions before planning work.
The snapshot is derived from Claude memory and must never be edited.
Snapshot: $SNAPSHOT_DIR
Write durable-memory proposals as separate Markdown files in the configured memory-proposals directory.
Memory proposals: $PROPOSALS_DIR
Work only in the current git worktree; never switch another agent's checkout.
$PROJECT_MATES
Reach one with: bash ~/bin/bus-send <slug> "CLASS subject: heading" (first line is the envelope; body follows)
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

write_model_record() {
  local temporary
  temporary="$(mktemp "$MODEL_FILE.XXXXXX")" || refuse 70 "could not make model record temporary file"
  printf '%s\n' "$MODEL" > "$temporary" || refuse 70 "could not write model record temporary file"
  chmod 600 "$temporary" || refuse 70 "could not secure model record temporary file"
  mv -f "$temporary" "$MODEL_FILE" || refuse 70 "could not atomically persist model record"
}

# Everything a fresh thread needs: password, temporary server, health loop,
# session creation, and the durable records - the session id AND the model it
# was born with (see the resume branch below for why the model is recorded
# here). Called from the first-start path and from the resume path when the
# row's model no longer matches the thread's.
create_thread() {
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
      *'"healthy":true'*"\"version\":\"$OPENCODE_VERSION\""*) healthy=1; break ;;
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
  write_model_record
  cleanup_server
}

if [ -f "$SESSION_FILE" ]; then
  SESSION_ID="$(cat "$SESSION_FILE")"
  [[ "$SESSION_ID" =~ ^ses_[A-Za-z0-9_-]+$ ]] || refuse 65 "saved OpenCode session ID is malformed"

  # A SAVED THREAD KEEPS THE MODEL IT WAS BORN WITH. Measured on two hosts,
  # twice, 2026-09-08: OpenCode resumes a thread with `--session <id> --model
  # $MODEL`, but a resumed thread ignores --model - it goes on answering on
  # whatever model created it. A row's MODEL field was changed and restarted,
  # and the thread kept answering on the old model with no error; the fix was
  # moving the session file aside by hand.
  #
  # A RECORD, NOT A QUERY: there is no server to ask a resumed thread what
  # model it holds. The temporary server exists only long enough to create a
  # session, then it is gone (see create_thread's cleanup_server). So the
  # model the thread was born with has to be written down at creation time,
  # beside the session id, and compared to the row on every resume.
  #
  # A THREAD FROM BEFORE THIS RECORD EXISTED IS RECORDED, NOT ROTATED. Rotating
  # every legacy thread once would silently start a fresh thread - and lose
  # the history - for every session already running, on the one occasion
  # operators already know how to handle by hand: move the session file aside.
  if [ -f "$MODEL_FILE" ]; then
    RECORDED_MODEL="$(cat "$MODEL_FILE")"
    if [ "$RECORDED_MODEL" != "$MODEL" ]; then
      ARCHIVED_SESSION_FILE="$SESSION_FILE.$(date +%s)"
      mv -f "$SESSION_FILE" "$ARCHIVED_SESSION_FILE" || refuse 70 "could not archive the previous OpenCode session"
      echo "opencode-session: MODEL changed from $RECORDED_MODEL to $MODEL - a saved thread keeps the model it was born with, so a new thread is started; the old id is kept at $ARCHIVED_SESSION_FILE" >&2
      create_thread
    fi
  else
    write_model_record
    echo "opencode-session: no model record for the saved thread; recorded $MODEL as its model - if the thread was born on another model, move the session file aside once" >&2
  fi
else
  create_thread
fi

if [ "$AUTO_APPROVE" = "true" ]; then
  exec "$OPENCODE_BIN" "$REPO_PATH" --session "$SESSION_ID" --model "$MODEL" --hostname 127.0.0.1 --port "$OPENCODE_PORT" --auto
else
  exec "$OPENCODE_BIN" "$REPO_PATH" --session "$SESSION_ID" --model "$MODEL" --hostname 127.0.0.1 --port "$OPENCODE_PORT"
fi
