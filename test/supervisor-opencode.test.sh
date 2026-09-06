#!/bin/bash
# test/supervisor-opencode.test.sh - the Linux supervisor starts an OpenCode row
# through the runtime adapter, exactly as the macOS twin does.
#
# WHY. RUNTIME="opencode" has been a valid row since the adapter landed
# (runtime/opencode-session.sh), and the macOS supervisor dispatches on it. The
# Linux supervisor never did: it built a claude command line, demanded a claude
# binary, prepared an MCP document and drove /rename into the pane - none of
# which an OpenCode session has. The first advisor row on a Linux host was
# therefore a row supervision could validate and never start.
#
# FIVE CLAIMS:
#   1. A dead OpenCode row is spawned through the ADAPTER, with no claude anywhere.
#   2. It needs no spawn library: the adapter carries its own configuration.
#   3. A missing adapter is a refusal (rc 78) that names the path - never a
#      bare shell wearing the session's name.
#   4. A live OpenCode session is found by ITS PORT, and left alone: no spawn,
#      no keystrokes (OpenCode has no /rename).
#   5. No rename cycle is armed for it.
set -u
here="$(CDPATH= cd -- "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SUP="$here/linux/session-supervisor-linux.sh"
pass=0; fail=0
ok()  { pass=$((pass+1)); printf '  ok   %s\n' "$1"; }
bad() { fail=$((fail+1)); printf '  FAIL %s\n     %s\n' "$1" "${2:-}"; }
is()  { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "wanted '$3', got '$2'"; fi; }
has() { case "$2" in *"$3"*) ok "$1" ;; *) bad "$1" "missing '$3' in: $2" ;; esac; }
hasnt(){ case "$2" in *"$3"*) bad "$1" "unexpectedly present '$3' in: $2" ;; *) ok "$1" ;; esac; }

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
HOMEDIR="$T/home"; ROOT="$T/estate"; LIBS="$T/libs"; BIN="$T/bin"
mkdir -p "$HOMEDIR/.local/bin" "$HOMEDIR/Projects/repo" "$HOMEDIR/scripts/runtime" "$LIBS" "$BIN" \
         "$ROOT/estate" "$ROOT/sessions.d" "$ROOT/entities.d" "$ROOT/accounts.d" \
         "$ROOT/projects.d" "$ROOT/mcp.d" "$T/memory"
cat > "$ROOT/estate/steward.conf" <<'EOF'
ESTATE_NAME="fixture"
LABEL_PREFIX="com.fixture.claude"
JOB_LABEL_PREFIX="com.fixture.job"
SERVICE_LABEL_PREFIX="com.fixture.svc"
RC_LABEL_PREFIX="Fixture: "
HUB_SESSION="hub"
HUB_HOST="h1"
STATE_DIR_NAME="fixture-supervisor"
PAUSED_DIR_NAME="fixture-paused"
TMUX_SOCKET="fixture.sock"
OP_TOKEN_FILE_NAME="fixture-token"
PING_MSG="you have unread mail"
EOF
printf 'NAME="Alpha"\nMEMBERS="a"\n' > "$ROOT/entities.d/alpha.conf"
NAME="s-0000000000000002"
PORT=4097
cat > "$ROOT/sessions.d/$NAME.conf" <<EOF
OWNER="a"
HOST="h1"
DOMAIN="alpha"
REPO_PATH="$HOMEDIR/Projects/repo"
ID="$NAME"
RC_LABEL=""
KIND="advisor"
RUNTIME="opencode"
MODEL="openai/example-model"
OPENCODE_VERSION="1.18.14"
OPENCODE_PORT="$PORT"
AUTO_APPROVE="true"
CLAUDE_MEMORY_ROOT="$T/memory"
EOF
# NO claude binary in this home, on purpose: an OpenCode row must not need one.
cp "$here/lib/registry.sh" "$LIBS/registry.sh"
ADAPTER="$HOMEDIR/scripts/runtime/opencode-session.sh"
printf '#!/bin/sh\nexit 0\n' > "$ADAPTER"; chmod 755 "$ADAPTER"
cat > "$BIN/tmux" <<'EOF'
printf '%s\n' "$*" >> "$TMUX_LOG"
argv=("$@")
[ "${argv[0]:-}" = "-S" ] && argv=("${argv[@]:2}")
case "${argv[0]:-}" in
  has-session)  [ -f "$T_HAS_SESSION" ] && exit 0; exit 1 ;;
  list-panes)   [ -f "$T_HAS_SESSION" ] && echo 4242; exit 0 ;;
  list-clients) exit 0 ;;
  capture-pane) cat "$T_PANE" 2>/dev/null; exit 0 ;;
  *)            exit 0 ;;
esac
EOF
chmod 755 "$BIN/tmux"
# pgrep records the pattern it was asked for: the port-bound identity is the claim.
cat > "$BIN/pgrep" <<'EOF'
printf '%s\n' "$*" >> "$PGREP_LOG"
[ -f "$T_ALIVE" ] && echo 4242
exit 0
EOF
chmod 755 "$BIN/pgrep"
export TMUX_LOG="$T/tmux.log" PGREP_LOG="$T/pgrep.log"
export T_HAS_SESSION="$T/has-session" T_ALIVE="$T/alive" T_PANE="$T/pane.txt"
: > "$T_PANE"
STATE="$HOMEDIR/.local/state/fixture-supervisor"
run() { # -> rc; stdout+stderr in $T/out
  : > "$TMUX_LOG"; : > "$PGREP_LOG"
  HOME="$HOMEDIR" \
  STEWARD_ESTATE_ROOT="$ROOT" \
  STEWARD_CONFIG_FILE="$T/no-such-config" \
  STEWARD_REGISTRY_LIB="$LIBS/registry.sh" \
  STEWARD_TMUX_SOCKET="$T/fixture.sock" \
  PATH="$BIN:$PATH" \
  bash "$SUP" "$NAME" >"$T/out" 2>&1
}

echo "== 1. a dead OpenCode row is spawned through the adapter =="
cp "$here/lib/mcprender.sh" "$here/lib/mcpspawn.sh" "$LIBS/"
rm -f "$T_HAS_SESSION" "$T_ALIVE"
run; rc1=$?
log1="$(cat "$TMUX_LOG")"
is    "1a rc 0" "$rc1" "0"
has   "1b tmux was asked to create the session" "$log1" "new-session"
has   "1c and the command is the adapter" "$log1" "$ADAPTER"
has   "1d called with the session name" "$log1" "$ADAPTER\" \"$NAME"
hasnt "1e no claude on the launch line" "$log1" "claude"
[ -f "$STATE/$NAME.rename-pending" ] && bad "1f no rename cycle armed for OpenCode" "rename-pending exists" \
                                     || ok  "1f no rename cycle armed for OpenCode"

echo "== 2. it needs no spawn library =="
rm -f "$LIBS/mcprender.sh" "$LIBS/mcpspawn.sh"
rm -f "$T_HAS_SESSION" "$T_ALIVE"
run; rc2=$?
is  "2a rc 0 without the MCP libraries" "$rc2" "0"
has "2b and the adapter was launched" "$(cat "$TMUX_LOG")" "$ADAPTER"
cp "$here/lib/mcprender.sh" "$here/lib/mcpspawn.sh" "$LIBS/"

echo "== 3. a missing adapter is a refusal that names the path =="
mv "$ADAPTER" "$ADAPTER.away"
rm -f "$T_HAS_SESSION" "$T_ALIVE"
run; rc3=$?
out3="$(cat "$T/out")"
is    "3a rc 78" "$rc3" "78"
has   "3b the refusal names the adapter" "$out3" "$ADAPTER"
hasnt "3c and nothing was spawned" "$(cat "$TMUX_LOG")" "new-session"
mv "$ADAPTER.away" "$ADAPTER"

echo "== 4. a live OpenCode session is found by its port and left alone =="
touch "$T_HAS_SESSION" "$T_ALIVE"
printf '%s\n' "$NAME" > "$STATE/$NAME.launched"
run; rc4=$?
log4="$(cat "$TMUX_LOG")"
is    "4a rc 0" "$rc4" "0"
hasnt "4b nothing was spawned" "$log4" "new-session"
hasnt "4c no keystrokes into the pane (OpenCode has no /rename)" "$log4" "send-keys"
hasnt "4d nothing was killed" "$log4" "kill-session"
has   "4e the identity pattern names the runtime" "$(cat "$PGREP_LOG")" "opencode"
has   "4f and the session's port" "$(cat "$PGREP_LOG")" "port $PORT"
hasnt "4g and never the claude label form" "$(cat "$PGREP_LOG")" "remote-control"

echo "== 5. a session gone from the pane is respawned through the adapter, not claude =="
rm -f "$T_HAS_SESSION" "$T_ALIVE"
run; rc5=$?
is    "5a rc 0" "$rc5" "0"
has   "5b the adapter again" "$(cat "$TMUX_LOG")" "$ADAPTER"
hasnt "5c never claude" "$(cat "$TMUX_LOG")" "claude"

echo "pass=$pass fail=$fail"
[ "$fail" -eq 0 ]
