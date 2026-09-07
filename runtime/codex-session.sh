#!/bin/bash
# runtime/codex-session.sh - deliver a registered session's mail into its own
# Codex thread and send the answer back on the bus.
#
# WHY THIS RUNTIME HAS NO PROCESS. A claude-code session is a pane; an opencode
# session is a port. A Codex session is neither: it is a THREAD, and a thread
# needs a process only while a turn runs. So there is nothing to keep alive and
# nothing to supervise - this command is run when mail arrives (or on a timer),
# it answers what is waiting, and it exits. The thread is the durable thing, and
# it lives in the operator's Codex app where a human can read and join it.
#
# ORDER OF OPERATIONS, and why. Mail is taken out of the inbox before the turn
# runs, so a slow model cannot hold the 15-minute alarm hostage - but the text
# is written to a durable request file FIRST, so an acknowledged letter is never
# lost if the turn or the machine dies. On the next run a leftover request file
# is answered before any new mail is read. That is the whole crash contract:
# persist, then acknowledge, then answer, then reply, then forget.
#
#   codex-session.sh <registered-session-name>
#
# Exit 0 when there was nothing to do.
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

refuse() { local code="$1"; shift; echo "codex-session: REFUSING - $*" >&2; exit "$code"; }
note()   { echo "codex-session: $*" >&2; }

_registry_default() {
  local candidate
  for candidate in "$HOME/scripts/lib/registry.sh" "$_runtime_dir/../lib/registry.sh"; do
    [ -f "$candidate" ] && { printf '%s' "$candidate"; return 0; }
  done
  printf '%s' "$HOME/scripts/lib/registry.sh"
}

NAME="${1:-}"
[ -n "$NAME" ] || refuse 64 "usage: codex-session.sh <registered-session-name>"

REGISTRY_LIB="${STEWARD_REGISTRY_LIB:-$(_registry_default)}"
[ -f "$REGISTRY_LIB" ] || refuse 78 "registry library missing: $REGISTRY_LIB"
# shellcheck source=/dev/null
. "$REGISTRY_LIB" || refuse 78 "registry library could not be read: $REGISTRY_LIB"
registry_load "$NAME" >/dev/null || refuse 78 "registered session could not be loaded: $NAME"
[ "${RUNTIME:-}" = "codex" ] || refuse 78 "$NAME is not a Codex session"

[ -d "$REPO_PATH" ] || refuse 65 "repository is unavailable: $REPO_PATH"

CLIENT="${STEWARD_CODEX_CLIENT:-$_runtime_dir/codex-thread.js}"
[ -f "$CLIENT" ] || refuse 78 "thread client missing: $CLIENT"
# NODE, WHEREVER THIS HOST KEEPS IT. A non-interactive ssh session on macOS has
# no Homebrew on PATH, so `node` is not found even though node 22 is installed -
# measured on the estate's other host 2026-09-07. The row's host may name it;
# otherwise look where the two platforms put it before refusing.
NODE_BIN="${STEWARD_NODE_BIN:-}"
if [ -z "$NODE_BIN" ]; then
  for _n in node /opt/homebrew/opt/node@22/bin/node /opt/homebrew/bin/node /usr/local/bin/node /usr/bin/node; do
    command -v "$_n" >/dev/null 2>&1 && { NODE_BIN="$_n"; break; }
    [ -x "$_n" ] && { NODE_BIN="$_n"; break; }
  done
fi
[ -n "$NODE_BIN" ] || refuse 78 "node is required for a Codex session and was not found on PATH or in the usual places"
command -v "$NODE_BIN" >/dev/null 2>&1 || [ -x "$NODE_BIN" ] || refuse 78 "node is required for a Codex session: $NODE_BIN is not executable"
# THE SHELL TOOL HAS ITS OWN BINARY ON macOS, AND GATEKEEPER CAN HOLD IT.
# Codex runs its shell tool through codex-code-mode-host; a copy that still
# carries com.apple.quarantine hangs in the dynamic loader, every command times
# out, and the model answers from guesswork - it looks exactly like a bad model.
# Measured on the estate's other host 2026-09-07: five tool calls timed out, and
# the same binary ran instantly from an unquarantined path. A brew upgrade
# recreates it, so this is a check and not a one-time fix.
codex_preflight() {
  local host; host="$(dirname "${STEWARD_CODEX_BIN:-$HOME/.local/bin/codex}")/codex-code-mode-host"
  [ -x "$host" ] || return 0
  timeout 5 "$host" --help >/dev/null 2>&1 && return 0
  case $? in
    124) refuse 78 "codex-code-mode-host does not answer (it hangs). On macOS this is Gatekeeper: run 'xattr -d com.apple.quarantine $host'. Every shell tool call would time out and the model would answer from guesswork." ;;
  esac
  return 0
}

BUS_SEND="${STEWARD_BUS_SEND:-$HOME/bin/bus-send}"
BUS_READ="${STEWARD_BUS_READ:-$HOME/bin/bus-read}"
BUS_ROOT="${STEWARD_BUS_ROOT:-$HOME/.config/agent-bus}"
INBOX="$BUS_ROOT/$ID/inbox"

STATE_DIR="${STEWARD_CODEX_STATE_DIR:-$HOME/.local/state/$(registry_state_dir_name)}"
umask 077
mkdir -p "$STATE_DIR" || refuse 70 "could not create state directory: $STATE_DIR"
THREAD_FILE="$STATE_DIR/$SESSION_NAME.codex-thread"
INSTRUCTIONS_FILE="$STATE_DIR/$SESSION_NAME.codex-instructions.md"
PENDING_DIR="$STATE_DIR/$SESSION_NAME.codex-pending"
# Answers live beside the pending directory, never inside it: what is in
# PENDING_DIR is exactly the mail still owed an answer, and a stray file there
# would be read as a letter on the next run.
ANSWER_DIR="$STATE_DIR/$SESSION_NAME.codex-answers"
# The ledger of letters already answered. It is the idempotency key of this
# runtime: a letter that was answered must never be answered twice, and the
# inbox alone cannot promise that - if the acknowledgement fails, or the machine
# dies between the answer and the acknowledgement, the same file is still lying
# there next run. Measured 2026-09-07: with a broken bus-read the first letter
# was answered a second time.
LEDGER="$STATE_DIR/$SESSION_NAME.codex-answered"
mkdir -p "$PENDING_DIR" "$ANSWER_DIR" || refuse 70 "could not create the working directories under $STATE_DIR"
[ -f "$LEDGER" ] || : > "$LEDGER"

# WHICH LETTERS DESERVE A TURN. A runtime that answers everything answers
# DRIFT alarms and FYND reports that never asked for anything - and two Codex
# rows pointed at each other answer each other's answers forever. The ledger
# stops a letter being answered twice; it does not stop a chain of new letters.
# So: a closed list, and never an answer to something that is itself a reply.
# The list is a FIELD, not a rule in this script: which classes a session should
# take is an estate decision, and the estate is the place decisions live.
# Read from the session's row when it carries the field (registry_load sources
# the conf, and the register tolerates the key), otherwise the safe default.
ANSWER_CLASSES="${CODEX_ANSWER_CLASSES:-FRAGA SAMORDNING}"
ANSWER_CLASS="${CODEX_REPLY_CLASS:-SAMORDNING}"
REPLY_MARK="reply to "

command -v timeout >/dev/null 2>&1 && codex_preflight

LABEL="$(registry_session_display "$NAME" 2>/dev/null)"
[ -n "$LABEL" ] || LABEL="$SESSION_NAME"

# The thread's standing instructions. Rewritten every run so a changed row
# reaches the thread on its next turn; the thread itself is never recreated.
{
  printf 'You are a Steward session.\n\n'
  printf -- '- Your name on the bus is %s. Your label is %s.\n' "$ID" "$LABEL"
  printf -- '- Your working copy is %s. You are on host %s.\n' "$REPO_PATH" "$HOST"
  printf -- '- Every message you receive is a letter from another session or a person.\n'
  printf -- '  Answer it directly. Your answer is sent back to the sender as a letter,\n'
  printf -- '  so write it as a message, not as a report about a message.\n'
  printf -- '- Secrets never travel on the bus. A pointer to where a key lives is fine;\n'
  printf -- '  the value never is.\n'
} > "$INSTRUCTIONS_FILE" || refuse 70 "could not write the instructions file"

json_field() { # <file> <field>  -> raw string on stdout
  "${STEWARD_JQ:-jq}" -r --arg f "$2" '.[$f] // ""' "$1" 2>/dev/null
}

# --- 1. persist what is waiting, before anything is acknowledged -------------
staged=0
for letter in "$INBOX"/*.json; do
  [ -e "$letter" ] || break
  base="$(basename "$letter")"
  request="$PENDING_DIR/$base"
  [ -e "$request" ] && continue
  grep -Fxq "$base" "$LEDGER" 2>/dev/null && continue
  from="$(json_field "$letter" from)"
  klass="$(json_field "$letter" klass)"
  amne="$(json_field "$letter" amne)"
  rubrik="$(json_field "$letter" rubrik)"
  text="$(json_field "$letter" text)"
  [ -n "$from" ] || { note "skipping a letter without a sender: $base"; continue; }
  case " $ANSWER_CLASSES " in
    *" ${klass:-} "*) ;;
    *) note "not answering $klass in $base (this session answers: $ANSWER_CLASSES)"; continue ;;
  esac
  # A letter whose headline is already an answer gets read, never answered:
  # otherwise two sessions reply to each other's replies without end.
  case "$rubrik" in
    "$REPLY_MARK"*|*"$REPLY_MARK"*) note "not answering a reply: $base"; continue ;;
  esac
  tmp="$request.partial"
  {
    printf 'from\t%s\n' "$from"
    printf 'class\t%s\n' "$klass"
    printf 'subject\t%s\n' "$amne"
    printf 'headline\t%s\n' "$rubrik"
    printf 'body\n'
    printf '%s\n' "$text"
  } > "$tmp" && mv -f "$tmp" "$request" || { rm -f "$tmp"; refuse 70 "could not stage $base"; }
  staged=$((staged + 1))
done

# --- 2. acknowledge, through the product's own read path ---------------------
# bus-read is what stamps and moves the mail; duplicating that here would mean
# two implementations of the alarm's definition of "read".
if [ "$staged" -gt 0 ]; then
  if [ -x "$BUS_READ" ]; then
    STEWARD_BUS_SELF="$ID" "$BUS_READ" "$ID" >/dev/null 2>&1 || note "bus-read exited non-zero; the mail may still be in the inbox"
  else
    note "bus-read is missing at $BUS_READ; mail stays in the inbox"
  fi
fi

# --- 3. answer everything staged, oldest first, one turn at a time -----------
answered=0
failed=0
for request in "$PENDING_DIR"/*.json; do
  [ -e "$request" ] || break
  # awk, not sed: BSD sed reads \t as the letter t, so a tab-separated header
  # parses on Linux and silently returns nothing on macOS.
  from="$(awk -F'\t' 'NR==1 && $1=="from" {print $2; exit}' "$request")"
  subject="$(awk -F'\t' 'NR==3 && $1=="subject" {print $2; exit}' "$request")"
  headline="$(awk -F'\t' 'NR==4 && $1=="headline" {print $2; exit}' "$request")"
  [ -n "$from" ] || { note "a staged letter has no sender, leaving it: $(basename "$request")"; continue; }
  [ -n "$subject" ] || subject="reply"

  answer_file="$ANSWER_DIR/$(basename "$request").answer"
  if [ ! -s "$answer_file" ]; then
    # THE EXIT CODE IS CAPTURED ON ITS OWN LINE. Inside `if ! cmd; then`, $? is
    # the IF's own result, not the command's - the log then said "rc 0" about a
    # turn that had just refused with 78. Measured by this suite 2026-09-07.
    "$NODE_BIN" "$CLIENT" turn \
        --cwd "$REPO_PATH" \
        --message-file "$request" \
        --thread-file "$THREAD_FILE" \
        --instructions "$INSTRUCTIONS_FILE" \
        --name "$LABEL" \
        ${MODEL:+--model "$MODEL"} \
        > "$answer_file.partial" 2>"$answer_file.err"
    _rc=$?
    if [ "$_rc" -ne 0 ]; then
      # THE REASON, NOT JUST THE FACT. A letter that stays staged with no cause
      # in the log reads as a silent model; the client's stderr carries the
      # real one - an expired login, a refused account, a turn that failed.
      failed=$((failed + 1))
      note "the turn failed (rc $_rc) for $(basename "$request"); the letter stays staged"
      sed 's/\x1b\[[0-9;]*m//g' "$answer_file.err" | tail -3 >&2
      [ "$_rc" = 78 ] && note "rc 78 is an ENVIRONMENT refusal - the login or the binary, not the model"
      rm -f "$answer_file.partial"
      continue
    fi
    mv -f "$answer_file.partial" "$answer_file"
  fi

  reply="$(cat "$answer_file")"
  [ -n "$reply" ] || { note "empty answer for $(basename "$request"); leaving it staged"; continue; }
  if [ -x "$BUS_SEND" ]; then
    # BUS_FROM IS NOT OPTIONAL HERE. Outside tmux the bus cannot derive who is
    # sending, and it refuses rather than fall back on a generic key that would
    # be stamped as ANOTHER session. This runtime has no pane, so every send it
    # makes is headless. Measured by the product's integrator 2026-09-07: the
    # first version answered every letter into a refusal, and the unit test
    # could not see it because bus-send was a stub.
    if BUS_FROM="$ID" "$BUS_SEND" "$from" "$ANSWER_CLASS $subject: reply to ${headline:-your letter}
$reply" >/dev/null 2>&1; then
      # The ledger is written BEFORE the request is removed: a crash between the
      # two costs a stale line, never a second answer.
      printf '%s\n' "$(basename "$request")" >> "$LEDGER"
      # Keep it bounded. A thousand lines is far more than any inbox backlog and
      # still a file a human can read.
      if [ "$(wc -l < "$LEDGER" | tr -d ' ')" -gt 1000 ]; then
        tail -n 500 "$LEDGER" > "$LEDGER.trimmed" && mv -f "$LEDGER.trimmed" "$LEDGER"
      fi
      rm -f "$request" "$answer_file" "$answer_file.err"
      answered=$((answered + 1))
    else
      # NAME THE LIKELIEST CAUSE. A row minted with `registry session add` gets
      # no relay key and no row at the hub - only session-new/enroll do that -
      # and the send then refuses for a reason the reader has to go looking for.
      if [ ! -e "$HOME/.ssh/id_busrelay_$ID" ]; then
        note "no relay key for $ID (~/.ssh/id_busrelay_$ID): this row was minted without one, and the hub has no row for it either"
      fi
      note "could not send the reply to $from; the answer is kept at $answer_file"
    fi
  else
    note "bus-send is missing at $BUS_SEND; the answer is kept at $answer_file"
  fi
done

[ "$answered" -gt 0 ] && note "answered $answered letter(s) in thread $(cat "$THREAD_FILE" 2>/dev/null)"

# THE EXIT CODE HAS TO CARRY THE ROUND'S OUTCOME. A run where every turn failed
# exited 0, so a timer's log showed a clean run while the mail sat unanswered -
# measured on the estate's other host 2026-09-07. A letter still waiting is not
# an error (it is answered next round); a round where turns FAILED and nothing
# was answered is, and rc 75 says "temporary, try again" rather than "broken".
if [ "$failed" -gt 0 ] && [ "$answered" -eq 0 ]; then
  note "$failed turn(s) failed and nothing was answered"
  exit 75
fi
exit 0
