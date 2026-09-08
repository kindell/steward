#!/bin/bash
# test/codex-session.test.sh - the Codex adapter turns waiting mail into turns
# in one durable thread, and never loses an acknowledged letter.
#
# WHY. A Codex session has no process to supervise: the thread is the durable
# thing and a turn runs only while a letter is being answered. That makes the
# crash window the whole design. Mail must be written down BEFORE it is
# acknowledged, and a letter whose turn failed must still be there afterwards.
#
# SIX CLAIMS:
#   1. A row that is not RUNTIME="codex" is refused (78), by name.
#   2. Waiting mail is staged to disk BEFORE bus-read acknowledges it.
#   3. The answer goes back to the SENDER, in the letter's own subject.
#   4. A failed turn sends nothing and leaves the letter staged.
#   5. A letter staged by an earlier run is answered with no new mail at all.
#   6. The thread id is remembered, so the second letter resumes and never
#      starts a second thread.
#   7. A letter that was answered is never answered again, even when the
#      acknowledgement failed and the file is still sitting in the inbox.
#   8. Every send names the sender: without BUS_FROM the bus refuses a headless
#      send rather than stamp it as another session.
#   9. A class this session does not answer is read, never answered.
#  10. A letter that is itself a reply is never answered - two sessions
#      answering each other's answers is a loop no ledger can stop.
#  11. A failing turn says WHY in the log, and an environment refusal (rc 78)
#      is named as such - an expired login must never read as a silent model.
#  12. A round where turns failed and nothing was answered exits 75, so a
#      timer's log does not show a clean run over unanswered mail.
#  13. A held shell-tool binary stops the round before a single letter is
#      staged - the model must never be blamed for a tool that cannot run.
#  14. The turn is given the letter's own id (--client-id), and the message
#      the thread sees opens with where the letter came from - in the app a
#      queued letter is drawn like the owner's own words.
#  15. A missing daemon (rc 69) is named as DEGRADED, once, and the round
#      stops trying instead of failing every letter the same way.
set -u
here="$(CDPATH= cd -- "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ADAPTER="$here/runtime/codex-session.sh"
pass=0; fail=0
ok()  { pass=$((pass+1)); printf '  ok   %s\n' "$1"; }
bad() { fail=$((fail+1)); printf '  FAIL %s\n     %s\n' "$1" "${2:-}"; }
is()  { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "wanted '$3', got '$2'"; fi; }
has() { case "$2" in *"$3"*) ok "$1" ;; *) bad "$1" "missing '$3' in: $2" ;; esac; }
hasnt(){ case "$2" in *"$3"*) bad "$1" "unexpectedly present '$3' in: $2" ;; *) ok "$1" ;; esac; }

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
HOMEDIR="$T/home"; ROOT="$T/estate"; BIN="$T/bin"; LIBS="$T/libs"
mkdir -p "$HOMEDIR/Projects/repo" "$BIN" "$LIBS" "$T/state" \
         "$ROOT/estate" "$ROOT/sessions.d" "$ROOT/entities.d" "$ROOT/accounts.d" \
         "$ROOT/projects.d" "$ROOT/mcp.d"
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
PING_MSG="you have unread mail"
EOF
printf 'NAME="Alpha"\nMEMBERS="a"\n' > "$ROOT/entities.d/alpha.conf"
CODEX_ID="s-0000000000000011"
cat > "$ROOT/sessions.d/$CODEX_ID.conf" <<EOF
OWNER="a"
HOST="h1"
DOMAIN="alpha"
REPO_PATH="$HOMEDIR/Projects/repo"
ID="$CODEX_ID"
RC_LABEL="Alpha"
KIND="work"
RUNTIME="codex"
EOF
CLAUDE_ID="s-0000000000000012"
sed 's/RUNTIME="codex"/RUNTIME="claude-code"/; s/'"$CODEX_ID"'/'"$CLAUDE_ID"'/' \
  "$ROOT/sessions.d/$CODEX_ID.conf" > "$ROOT/sessions.d/$CLAUDE_ID.conf"

INBOX="$T/bus/$CODEX_ID/inbox"; mkdir -p "$INBOX"
letter() { # <name> <from> <subject> <headline> <body> [class]
  cat > "$INBOX/$1.json" <<EOF
{"from":"$2","to":"$CODEX_ID","ts":"1700000000","klass":"${6:-SAMORDNING}","amne":"$3","rubrik":"$4","text":"$5"}
EOF
}

# --- stubs -------------------------------------------------------------------
# bus-read only records that it ran, and empties the inbox the way the real one
# does. The ORDER between staging and this call is claim 2.
cat > "$BIN/bus-read" <<'EOF'
#!/bin/sh
printf 'read %s\n' "$1" >> "$BUS_READ_LOG"
ls "$STAGE_DIR" > "$STAGED_WHEN_READ" 2>/dev/null
rm -f "$INBOX_DIR"/*.json
exit 0
EOF
cat > "$BIN/bus-send" <<'EOF'
#!/bin/sh
printf 'BUS_FROM=%s\n%s\n---\n%s\n===\n' "${BUS_FROM:-<unset>}" "$1" "$2" >> "$BUS_SEND_LOG"
[ -f "$SEND_FAILS" ] && exit 65
exit 0
EOF
# The thread client: prints an answer, and records the arguments it was given so
# the test can see which thread the second letter used.
cat > "$BIN/thread-client" <<'EOF'
#!/bin/sh
# The preflight is a separate verb and is not part of the turn log: a claim that
# reads the log is asking what the TURN was given.
if [ "$1" = "preflight" ]; then
  [ -f "$PREFLIGHT_FAILS" ] && { echo "codex-code-mode-host hangs"; exit 78; }
  echo "code-mode host ok"; exit 0
fi
printf '%s\n' "$*" >> "$CLIENT_LOG"
prev=""; for a in "$@"; do [ "$prev" = "--message-file" ] && cp "$a" "$MESSAGE_COPY"; prev="$a"; done
[ -f "$DAEMON_DOWN" ] && { echo "codex-thread: REFUSING - the owner's Codex daemon is not running (no socket at /nowhere)" >&2; exit 69; }
[ -f "$ENV_FAILS" ] && { echo "codex-thread: REFUSING - the turn did not complete: unauthorized" >&2; exit 78; }
[ -f "$TURN_FAILS" ] && { echo "codex-thread: REFUSING - the turn did not complete" >&2; exit 75; }
tf=""; prev=""
for a in "$@"; do [ "$prev" = "--thread-file" ] && tf="$a"; prev="$a"; done
[ -n "$tf" ] && [ ! -s "$tf" ] && printf 'thread-aaa\n' > "$tf"
echo "the answer"
exit 0
EOF
chmod 755 "$BIN"/bus-read "$BIN"/bus-send "$BIN"/thread-client
cp "$here/lib/registry.sh" "$LIBS/registry.sh"

run() { # run the adapter against a session name
  HOME="$HOMEDIR" \
  STEWARD_ESTATE_ROOT="$ROOT" \
  STEWARD_REGISTRY_LIB="$LIBS/registry.sh" \
  STEWARD_CODEX_STATE_DIR="$T/state" \
  STEWARD_CODEX_CLIENT="$BIN/thread-client" \
  STEWARD_NODE_BIN="/bin/sh" \
  STEWARD_BUS_SEND="$BIN/bus-send" \
  STEWARD_BUS_READ="$BIN/bus-read" \
  STEWARD_BUS_ROOT="$T/bus" \
  BUS_READ_LOG="$T/bus-read.log" BUS_SEND_LOG="$T/bus-send.log" CLIENT_LOG="$T/client.log" \
  STAGE_DIR="$T/state/$1.codex-pending" STAGED_WHEN_READ="$T/staged-when-read" \
  INBOX_DIR="$INBOX" SEND_FAILS="$T/send-fails" TURN_FAILS="$T/turn-fails" ENV_FAILS="$T/env-fails" \
  PREFLIGHT_FAILS="$T/preflight-fails" MESSAGE_COPY="$T/message-copy" DAEMON_DOWN="$T/daemon-down" \
  bash "$ADAPTER" "$1" 2>"$T/err"; echo "$?"
}

echo "codex-session"

# 1. wrong runtime
rc="$(run "$CLAUDE_ID")"
is  "a claude-code row is refused" "$rc" "78"
has "the refusal names the session" "$(cat "$T/err")" "$CLAUDE_ID is not a Codex session"

# 2 + 3 + 6. one letter, answered
letter 1700000000-a "s-sender-one" "harbour" "the pier is loose" "Please look at the pier."
rc="$(run "$CODEX_ID")"
is  "a letter is answered without error" "$rc" "0"
has "mail was staged BEFORE bus-read ran" "$(cat "$T/staged-when-read" 2>/dev/null)" "1700000000-a.json"
has "the reply goes to the sender" "$(cat "$T/bus-send.log")" "s-sender-one"
has "the reply keeps the subject" "$(cat "$T/bus-send.log")" "SAMORDNING harbour:"
has "the reply carries the answer" "$(cat "$T/bus-send.log")" "the answer"
has "the thread is named from the label" "$(cat "$T/client.log")" "--name Alpha"
has "the turn carries the letter's id" "$(cat "$T/client.log")" "--client-id 1700000000-a.json"
is  "the message opens with the letter's provenance" "$(head -1 "$T/message-copy")" "[bus SAMORDNING harbour from s-sender-one]"
has "and carries the headline and body" "$(cat "$T/message-copy")" "the pier is loose"
has "and carries the body" "$(cat "$T/message-copy")" "Please look at the pier."
hasnt "the thread does not see the raw header" "$(cat "$T/message-copy")" "from	s-sender-one"
is  "the thread id was remembered" "$(cat "$T/state/$CODEX_ID.codex-thread" 2>/dev/null)" "thread-aaa"
is  "nothing is left staged" "$(ls "$T/state/$CODEX_ID.codex-pending" | wc -l | tr -d ' ')" "0"

: > "$T/client.log"
letter 1700000001-b "s-sender-two" "harbour" "and the rope" "The rope too."
rc="$(run "$CODEX_ID")"
has "the second letter reuses the thread file" "$(cat "$T/client.log")" "--thread-file"
is  "no second thread was born" "$(cat "$T/state/$CODEX_ID.codex-thread")" "thread-aaa"

# 4. a failing turn keeps the letter
: > "$T/bus-send.log"; touch "$T/turn-fails"
letter 1700000002-c "s-sender-three" "storm" "the light is out" "The light is out."
rc="$(run "$CODEX_ID")"
# THE ROUND'S OUTCOME IS IN THE EXIT CODE. A run where every turn failed used
# to exit 0, so a timer's log showed a clean round while the mail sat
# unanswered. rc 75 says "temporary, try again", which is what a staged letter
# is. Asked for by the product's integrator after a real round on macOS.
is    "a round where the only turn failed exits 75" "$rc" "75"
is    "a failed turn sends nothing" "$(cat "$T/bus-send.log" | wc -c | tr -d ' ')" "0"
is    "the letter stays staged" "$(ls "$T/state/$CODEX_ID.codex-pending" | wc -l | tr -d ' ')" "1"

# 5. the staged letter is answered on a later run, with an empty inbox
rm -f "$T/turn-fails"; : > "$T/bus-read.log"
rc="$(run "$CODEX_ID")"
has "the staged letter is answered later" "$(cat "$T/bus-send.log")" "s-sender-three"
is  "an empty inbox needs no bus-read" "$(cat "$T/bus-read.log" | wc -c | tr -d ' ')" "0"
is  "and then nothing is staged" "$(ls "$T/state/$CODEX_ID.codex-pending" | wc -l | tr -d ' ')" "0"

# 7. an answered letter is never answered twice, even if bus-read did nothing
: > "$T/bus-send.log"
cat > "$BIN/bus-read" <<'EOF'
#!/bin/sh
printf 'read %s\n' "$1" >> "$BUS_READ_LOG"
exit 0
EOF
chmod 755 "$BIN/bus-read"
letter 1700000003-d "s-sender-four" "quay" "the bollard" "The bollard is loose."
rc="$(run "$CODEX_ID")"
has "the new letter is answered once" "$(cat "$T/bus-send.log")" "s-sender-four"
: > "$T/bus-send.log"
rc="$(run "$CODEX_ID")"
is  "the same letter is not answered again" "$(cat "$T/bus-send.log" | wc -c | tr -d ' ')" "0"
has "the ledger remembers it" "$(cat "$T/state/$CODEX_ID.codex-answered")" "1700000003-d.json"

# 8. the sender is named on every send
: > "$T/bus-send.log"
letter 1700000006-g "s-sender-seven" "pier" "one more" "One more, please."
rc="$(run "$CODEX_ID")"
has "the send names the sender" "$(cat "$T/bus-send.log")" "BUS_FROM=$CODEX_ID"

# 9. a class this session does not answer
: > "$T/bus-send.log"
letter 1700000004-e "s-sender-five" "weather" "the wind picked up" "Just so you know." DRIFT
rc="$(run "$CODEX_ID")"
is  "a DRIFT letter is not answered" "$(cat "$T/bus-send.log" | wc -c | tr -d ' ')" "0"
is  "and it is not left staged either" "$(ls "$T/state/$CODEX_ID.codex-pending" | wc -l | tr -d ' ')" "0"

# 10. a reply is never answered
: > "$T/bus-send.log"
letter 1700000005-f "s-sender-six" "quay" "reply to the bollard" "Thanks, noted."
rc="$(run "$CODEX_ID")"
is  "a reply is not answered" "$(cat "$T/bus-send.log" | wc -c | tr -d ' ')" "0"

# 11. an environment refusal is named as one
touch "$T/env-fails"; : > "$T/bus-send.log"
letter 1700000007-h "s-sender-eight" "dock" "the gate is stuck" "Please look."
rc="$(run "$CODEX_ID")"; err="$(cat "$T/err")"
is  "an environment refusal exits 75 as well" "$rc" "75"
has "the log carries the client's reason" "$err" "unauthorized"
has "and names rc 78 as the environment" "$err" "rc 78"
is  "the letter stays staged for a retry" "$(ls "$T/state/$CODEX_ID.codex-pending" | wc -l | tr -d ' ')" "1"
rm -f "$T/env-fails"

# 13. a failing preflight refuses the whole round, loudly
touch "$T/preflight-fails"; : > "$T/bus-send.log"
letter 1700000008-i "s-sender-nine" "yard" "the crane" "Please look."
rc="$(run "$CODEX_ID")"; err="$(cat "$T/err")"
is  "a held tool binary refuses the round" "$rc" "78"
has "and the refusal carries the reason" "$err" "code-mode-host"
is  "nothing was sent" "$(cat "$T/bus-send.log" | wc -c | tr -d ' ')" "0"
rm -f "$T/preflight-fails"

# 15. a missing daemon is degraded, once, and the round stops
touch "$T/daemon-down"; : > "$T/bus-send.log"; : > "$T/client.log"
letter 1700000009-j "s-sender-ten" "slip" "first of two" "Please look."
letter 1700000010-k "s-sender-eleven" "slip" "second of two" "Please look again."
rc="$(run "$CODEX_ID")"; err="$(cat "$T/err")"
is  "a round without a daemon exits 75" "$rc" "75"
has "and names the state DEGRADED" "$err" "DEGRADED"
has "and says what to start" "$err" "codex app-server daemon start"
is  "only one turn was attempted" "$(grep -c -- '--client-id' "$T/client.log")" "1"
is  "both letters stay staged" "$(ls "$T/state/$CODEX_ID.codex-pending" | grep -c -e 1700000009-j -e 1700000010-k)" "2"
is  "nothing was sent" "$(cat "$T/bus-send.log" | wc -c | tr -d ' ')" "0"
rm -f "$T/daemon-down"

# 16. the standing instructions name the other sessions on this project.
# The thread is durable and the instructions are rewritten before every round,
# so this is the one line that can carry a changed register into a session that
# already exists. It has to be a reading, not a cache: the second run below
# removes the mate and the file must say so.
printf 'TARGET_PROJECT="work"\n' >> "$ROOT/sessions.d/$CODEX_ID.conf"
cat > "$ROOT/sessions.d/mate-work.conf" <<EOF
OWNER="ben"
HOST="h1"
DOMAIN="alpha"
REPO_PATH="$HOMEDIR/Projects/repo"
ID="mate-work"
TARGET_PROJECT="work"
EOF
INSTR="$T/state/$CODEX_ID.codex-instructions.md"
rc="$(run "$CODEX_ID")"
has "the instructions name the session on the same project" \
    "$(cat "$INSTR" 2>/dev/null)" "Sessions on the same project: mate-work (ben)"
has "and say how to reach it" "$(cat "$INSTR" 2>/dev/null)" 'bash ~/bin/bus-send'
has "and that the first line of a message is the envelope" \
    "$(cat "$INSTR" 2>/dev/null)" "CLASS subject: heading"
rm -f "$ROOT/sessions.d/mate-work.conf"
rc="$(run "$CODEX_ID")"
has "rewritten every round: with the mate gone the line says none" \
    "$(cat "$INSTR" 2>/dev/null)" "Sessions on the same project: none"
hasnt "and the departed mate is not left behind in the file" \
    "$(cat "$INSTR" 2>/dev/null)" "mate-work"

printf '\n  %d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
