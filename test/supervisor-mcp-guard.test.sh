#!/bin/bash
# test/supervisor-mcp-guard.test.sh -- what a HALF-DEPLOYED host does.
#
# linux/session-supervisor-linux.sh gained two libraries (lib/mcprender.sh,
# lib/mcpspawn.sh) and the deploy manifest lists the supervisor BEFORE them, so
# "the supervisor is deployed and its spawn libraries are not" is a state the
# fleet passes through on every rollout and can be stranded in by one
# interrupted deploy-apply.
#
# THE REFUSAL IS RIGHT AND ITS PLACE WAS NOT. Starting a session on the legacy
# path because a library is missing hands it whatever the checkout's own
# .mcp.json declares while the registry's grant goes unread -- that must stay a
# refusal. But the refusal used to sit at the TOP of the file, so it also
# refused the round: on such a host every session's timer exited 78 four times
# an hour and the supervisor's other guarantees stopped with it -- the
# last-sid/launch-mark bookkeeping, the rename cycle, and the unacked-mail and
# malformed-mail escalations, none of which need a spawn library at all.
#
# So: the round runs, the SPAWN refuses, and it refuses BEFORE any tmux write.
# A supervisor that killed a zombie pane and then refused to respawn it would
# have turned a repair into a demolition.
#
# HERMETIC: a fixture home, a fixture estate, and shims for tmux and pgrep on
# PATH. `tmuxc` calls `command tmux`, so the shim is reached; every tmux call
# the supervisor makes is logged, which is how "no tmux write" is measured
# rather than asserted.
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
mkdir -p "$HOMEDIR/.local/bin" "$HOMEDIR/Projects/repo" "$LIBS" "$BIN" \
         "$ROOT/estate" "$ROOT/sessions.d" "$ROOT/entities.d" "$ROOT/accounts.d" \
         "$ROOT/projects.d" "$ROOT/mcp.d"

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
NAME="s-0000000000000001"
cat > "$ROOT/sessions.d/$NAME.conf" <<EOF
OWNER="a"
HOST="h1"
DOMAIN="alpha"
REPO_PATH="$HOMEDIR/Projects/repo"
ID="$NAME"
RC_LABEL="L"
EOF

# THE CLAUDE BINARY EXISTS. Its absence is a different refusal (supervisor's
# CLAUDE_BIN guard) and a fixture that left it out could not tell the two apart.
printf '#!/bin/sh\nexit 0\n' > "$HOMEDIR/.local/bin/claude"; chmod 755 "$HOMEDIR/.local/bin/claude"

cp "$here/lib/registry.sh" "$LIBS/registry.sh"

# -- THE SHIMS -------------------------------------------------------------
# tmux: every call is appended to $T/tmux.log, so a WRITE (new-session,
# send-keys, kill-session) is a measurement and not an assumption. Whether the
# session exists, and whether a claude lives in its pane, are driven by two
# control files so one fixture serves both branches.
cat > "$BIN/tmux" <<'EOF'
#!/bin/bash
printf '%s\n' "$*" >> "$TMUX_LOG"
argv=("$@")
# -S <socket> comes first, from tmuxc; drop it before dispatching.
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
# pgrep: answers the pane pid itself when a claude is meant to be alive, so
# is_descendant matches on its first comparison without needing a process tree.
cat > "$BIN/pgrep" <<'EOF'
#!/bin/bash
[ -f "$T_CLAUDE_ALIVE" ] && echo 4242
exit 0
EOF
chmod 755 "$BIN/pgrep"

export TMUX_LOG="$T/tmux.log"
export T_HAS_SESSION="$T/has-session"
export T_CLAUDE_ALIVE="$T/claude-alive"
export T_PANE="$T/pane.txt"
: > "$T_PANE"

STATE="$HOMEDIR/.local/state/fixture-supervisor"

run() { # -> rc; stdout+stderr in $T/out
  : > "$TMUX_LOG"
  HOME="$HOMEDIR" \
  STEWARD_ESTATE_ROOT="$ROOT" \
  STEWARD_CONFIG_FILE="$T/no-such-config" \
  STEWARD_REGISTRY_LIB="$LIBS/registry.sh" \
  STEWARD_TMUX_SOCKET="$T/fixture.sock" \
  PATH="$BIN:$PATH" \
  bash "$SUP" "$NAME" >"$T/out" 2>&1
}

# THE CONTROL GROUP FIRST. Without it every assertion below could be passing
# for the wrong reason -- a fixture the supervisor refuses for some unrelated
# missing estate value would also produce "no tmux write".
echo "== 0. control: with both libraries deployed, a dead session IS spawned =="
cp "$here/lib/mcprender.sh" "$here/lib/mcpspawn.sh" "$LIBS/"
rm -f "$T_HAS_SESSION" "$T_CLAUDE_ALIVE"
run; rc0=$?
is  "0a rc 0"                             "$rc0" "0"
has "0b tmux was asked to create the session" "$(cat "$TMUX_LOG")" "new-session"

echo "== 1. control: with both libraries deployed, a live session is left alone =="
touch "$T_HAS_SESSION" "$T_CLAUDE_ALIVE"
printf '%s\n' "$NAME" > "$STATE/$NAME.launched"
run; rc1=$?
is    "1a rc 0"                                 "$rc1" "0"
is    "1b the alive round did its last-sid bookkeeping" \
      "$(cat "$STATE/$NAME.last-sid" 2>/dev/null)" "$NAME"
hasnt "1c and nothing was spawned"              "$(cat "$TMUX_LOG")" "new-session"

echo "== 2. a half-deployed host still supervises a LIVE session =="
# The whole point of I3: mcprender.sh/mcpspawn.sh are only needed to SPAWN.
# A host that has the supervisor but not yet its spawn libraries must keep
# doing everything that does not spawn.
rm -f "$LIBS/mcprender.sh" "$LIBS/mcpspawn.sh"
touch "$T_HAS_SESSION" "$T_CLAUDE_ALIVE"
rm -f "$STATE/$NAME.last-sid"
printf '%s\n' "$NAME" > "$STATE/$NAME.launched"
run; rc2=$?
out2="$(cat "$T/out")"
is "2a the round is NOT refused"                "$rc2" "0"
is "2b the launch mark became last-sid -- the bookkeeping ran" \
   "$(cat "$STATE/$NAME.last-sid" 2>/dev/null)" "$NAME"
[ -f "$STATE/$NAME.launched" ] && bad "2c the launch mark was consumed" "it is still there" \
                              || ok "2c the launch mark was consumed"
has "2d the rename cycle still drove the label into the pane" \
    "$(cat "$TMUX_LOG")" "send-keys"

echo "== 3. ...and REFUSES to spawn a dead one, before touching tmux =="
rm -f "$T_HAS_SESSION" "$T_CLAUDE_ALIVE"
run; rc3=$?
out3="$(cat "$T/out")"
log3="$(cat "$TMUX_LOG")"
is    "3a rc 78 -- a config refusal, so the unit shows as failed" "$rc3" "78"
has   "3b the refusal names the library"        "$out3" "mcpspawn.sh"
has   "3c and says why legacy is not an option" "$out3" "legacy"
hasnt "3d NOT ONE tmux write: no session was created" "$log3" "new-session"
hasnt "3e nor any keystroke sent"                     "$log3" "send-keys"
hasnt "3f nor any session killed"                     "$log3" "kill-session"

echo "== 4. a document that cannot be built refuses the SPAWN, not the round =="
# rc 69 from mcp_spawn_prepare (no jq, an unwritable state directory) had the
# same shape as the missing library: it exited before the alive branch. Same
# split, same reason.
cp "$here/lib/mcprender.sh" "$here/lib/mcpspawn.sh" "$LIBS/"
mkdir -p "$T/nojq"
for b in /usr/bin/* /bin/*; do
  n="$(basename "$b")"; [ "$n" = "jq" ] && continue
  ln -sf "$b" "$T/nojq/$n" 2>/dev/null
done
ln -sf "$BIN/tmux" "$T/nojq/tmux"; ln -sf "$BIN/pgrep" "$T/nojq/pgrep"
run4() {
  : > "$TMUX_LOG"
  HOME="$HOMEDIR" STEWARD_ESTATE_ROOT="$ROOT" STEWARD_CONFIG_FILE="$T/no-such-config" \
  STEWARD_REGISTRY_LIB="$LIBS/registry.sh" STEWARD_TMUX_SOCKET="$T/fixture.sock" \
  PATH="$T/nojq" bash "$SUP" "$NAME" >"$T/out" 2>&1
}
touch "$T_HAS_SESSION" "$T_CLAUDE_ALIVE"
rm -f "$STATE/$NAME.last-sid"; printf '%s\n' "$NAME" > "$STATE/$NAME.launched"
run4; rc4=$?
is "4a a live session's round survives a document that cannot be built" "$rc4" "0"
is "4b and the bookkeeping ran"  "$(cat "$STATE/$NAME.last-sid" 2>/dev/null)" "$NAME"
rm -f "$T_HAS_SESSION" "$T_CLAUDE_ALIVE"
run4; rc4b=$?
out4b="$(cat "$T/out")"
is    "4c a dead session is REFUSED"    "$rc4b" "78"
has   "4d and the render's own reason is carried into the refusal" "$out4b" "jq"
hasnt "4e with no tmux write"           "$(cat "$TMUX_LOG")" "new-session"

echo "== 5. a library that is PRESENT but out of date is a missing library =="
# The state a future edit to these libraries creates during a rollout: the file
# is there and sources cleanly, but predates the function the supervisor calls.
# Checking presence let that through -- mcp_claude_cmd_fragment was then a
# command-not-found, CLAUDE_CMD became the EMPTY STRING, and the CLAUDE_BIN
# guard did not catch it either ("$HOME/.local/bin/" is a directory, and -x on
# a directory is true). The spawn ran "$HOME/.local/bin/; exec bash": a shell
# error and then a bare bash pane wearing a live session's name, which is the
# zombie-pane failure this file has a whole repair path for.
cp "$here/lib/mcprender.sh" "$LIBS/mcprender.sh"
cat > "$LIBS/mcpspawn.sh" <<'EOF'
# A stale deployed library: sources cleanly, predates mcp_claude_cmd_fragment.
mcp_spawn_prepare() { return 3; }
EOF
rm -f "$T_HAS_SESSION" "$T_CLAUDE_ALIVE"
run; rc5=$?
out5="$(cat "$T/out")"
is    "5a rc 78"                                     "$rc5" "78"
has   "5b the refusal itself names the missing function" \
      "$out5" "does not define mcp_claude_cmd_fragment"
hasnt "5c and nothing was spawned"                   "$(cat "$TMUX_LOG")" "new-session"

echo "== 6. an EMPTY claude command is refused in its own right =="
# The belt to section 5's braces. A library that defines every function the
# check asks for and still yields an empty command line must not reach tmux:
# the CLAUDE_BIN guard reads the FIRST WORD of the command, and the first word
# of an empty string is empty, so its -x test passes on a directory.
cat > "$LIBS/mcpspawn.sh" <<'EOF'
mcp_spawn_prepare()       { return 3; }
mcp_claude_cmd_fragment() { printf ''; }
EOF
rm -f "$T_HAS_SESSION" "$T_CLAUDE_ALIVE"
run; rc6=$?
out6="$(cat "$T/out")"
is    "6a rc 78"                                "$rc6" "78"
has   "6b the refusal says the command is empty" "$out6" "empty"
hasnt "6c and no bare shell was started"        "$(cat "$TMUX_LOG")" "new-session"

echo "pass=$pass fail=$fail"
[ "$fail" -eq 0 ]
