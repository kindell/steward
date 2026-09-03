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
# The whole purpose of I3: mcprender.sh/mcpspawn.sh are only needed to SPAWN.
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

echo "== 7. the degraded-MCP alarm is signalled ONCE, not once per respawn =="
# The alarm sits on the spawn path because a degraded set is a property of the
# session that was just started. But a crash-looping session is respawned by
# this same supervisor every few rounds, and each respawn re-sent the identical
# sentence about the identical missing asset -- the "four times an hour" harm
# the alarm's own comment names, and the reason the unacked-mail escalation
# next door carries a dedup marker. So: the same degradation is signalled once,
# a DIFFERENT one is signalled anew, and a healthy spawn forgets.
MCP_MARK="$STATE/$NAME.mcp-signalled"
mkdir -p "$HOMEDIR/bin"
cat > "$HOMEDIR/bin/bus-send" <<'EOF'
#!/bin/bash
# One CALL line per send, so alarms can be COUNTED rather than assumed, then
# the message itself. The rc comes from a control file: a bus that refuses is
# a state this section measures too.
{ printf 'CALL\n'; printf '%s\n' "$2"; } >> "$HOME/bus.log"
exit "$(cat "$HOME/bus-rc" 2>/dev/null || echo 0)"
EOF
chmod 755 "$HOMEDIR/bin/bus-send"
printf '0\n' > "$HOMEDIR/bus-rc"
# A deployed spawn library whose outcome the fixture drives: the rc and the
# render's own words are read from control files, so one library serves the
# degraded, the changed and the healthy spawn.
cat > "$LIBS/mcpspawn.sh" <<'EOF'
mcp_spawn_prepare() {
  cat "$HOME/mcp-err" >&2
  local rc; rc="$(cat "$HOME/mcp-rc")"
  [ "$rc" = "3" ] && return 3
  printf ' --strict-mcp-config --mcp-config "%s"' "$2"
  return "$rc"
}
mcp_claude_cmd_fragment() {
  printf 'claude %s --permission-mode bypassPermissions%s%s --remote-control "%s"' "$1" "$2" "$3" "$4"
}
EOF
alarms() { grep -c '^CALL$' "$HOMEDIR/bus.log" 2>/dev/null | tr -d ' '; }
: > "$HOMEDIR/bus.log"; rm -f "$MCP_MARK"
printf '1\n' > "$HOMEDIR/mcp-rc"
printf "mcp render: OMITTED 'tool-one' -- its definition is missing\n" > "$HOMEDIR/mcp-err"
rm -f "$T_HAS_SESSION" "$T_CLAUDE_ALIVE"
run; rc7=$?
is  "7a rc 0 -- a degraded set never withholds the start" "$rc7" "0"
has "7b the session was spawned"        "$(cat "$TMUX_LOG")" "new-session"
is  "7c and the hub was told, once"     "$(alarms)" "1"
has "7d in the degraded-set thread"     "$(cat "$HOMEDIR/bus.log")" "DRIFT mcp-set"
[ -f "$MCP_MARK" ] && ok "7e the delivery left a marker" \
                   || bad "7e the delivery left a marker" "no $MCP_MARK"

# THE RESPAWN. Same missing asset, same rc: the human has already been told.
run; rc7b=$?
is  "7f the respawn still starts the session" "$rc7b" "0"
has "7g -- the spawn is not what is being suppressed" "$(cat "$TMUX_LOG")" "new-session"
is  "7h and the hub is NOT told a second time" "$(alarms)" "1"

# A DIFFERENT DEGRADATION IS NEWS. A second asset going missing, or rc 1
# becoming rc 2, is a fact the first alarm did not carry.
printf "mcp render: OMITTED 'tool-one' -- its definition is missing\nmcp render: OMITTED 'tool-two' -- its definition is missing\n" > "$HOMEDIR/mcp-err"
run
is "7i a degradation that CHANGED alarms anew" "$(alarms)" "2"

# A HEALTHY SPAWN FORGETS (the bug 7 lesson the unacked marker carries: a
# marker that outlives its condition silences the next real alarm).
printf '3\n' > "$HOMEDIR/mcp-rc"; : > "$HOMEDIR/mcp-err"
run
is "7j a healthy spawn sends nothing" "$(alarms)" "2"
[ -f "$MCP_MARK" ] && bad "7k and clears the marker" "$MCP_MARK is still there" \
                   || ok "7k and clears the marker"
printf '1\n' > "$HOMEDIR/mcp-rc"
printf "mcp render: OMITTED 'tool-one' -- its definition is missing\n" > "$HOMEDIR/mcp-err"
run
is "7l so the degradation coming back is signalled again" "$(alarms)" "3"

# A SEND THAT FAILED IS NOT A SEND. The marker is written on the receipt, like
# the unacked one, so a refusing bus is retried on the next spawn.
printf '65\n' > "$HOMEDIR/bus-rc"
: > "$HOMEDIR/bus.log"; rm -f "$MCP_MARK"
run
is "7m a refused send is still an attempt" "$(alarms)" "1"
[ -f "$MCP_MARK" ] && bad "7n but leaves no marker" "$MCP_MARK was written on a refusal" \
                   || ok "7n but leaves no marker"
printf '0\n' > "$HOMEDIR/bus-rc"
run
is "7o so the next spawn tries again" "$(alarms)" "2"

echo "== 8. LOGIN: the Linux twin's exec-prefix splice, in the fixture that actually runs it =="
# Review finding 1 (task 6, round 1): no suite in either repo ever set LOGIN
# for the Linux twin, so its splice (spawn_session's launch line) could be
# deleted outright and nothing here would turn red. This is that suite's own
# fixture and tmux shim -- not a new file -- because this is the only product
# suite that actually executes linux/session-supervisor-linux.sh end to end.
mkdir -p "$ROOT/logins.d"
printf 'PRINCIPAL="alice"\nACCOUNT="acct-acme-team"\nPROVIDER="claude-max"\nCONFIG_DIR="~/.claude-logins/acme"\nLEGAL_OWNER="alice"\n' \
  > "$ROOT/logins.d/acme-team.conf"
chmod 600 "$ROOT/logins.d/acme-team.conf"
# THE OWNER ARGUMENT ON THIS TWIN IS $(id -un), NOT the conf's OWNER (this
# file's own comment: the Linux twin already runs AS the owner, so the home
# it may resolve must be the one it is actually running in). The stub
# therefore answers for whoever the test process is, not for a fixed name.
cat > "$BIN/login-home" <<EOF
#!/bin/bash
printf '%s\n' "$HOMEDIR"
EOF
chmod 755 "$BIN/login-home"
# REAL MCP LIBRARIES, freshly copied: section 7 above left FAKE
# mcpprepare/mcpspawn functions in \$LIBS, and this section's assertions
# must not depend on that leftover fixture state.
cp "$here/lib/mcprender.sh" "$here/lib/mcpspawn.sh" "$LIBS/"

write_login_conf() { # [login-slug]
  {
    printf 'OWNER="a"\nHOST="h1"\nDOMAIN="alpha"\nREPO_PATH="%s"\nID="%s"\nRC_LABEL="L"\n' \
      "$HOMEDIR/Projects/repo" "$NAME"
    [ -n "${1:-}" ] && printf 'LOGIN="%s"\n' "$1"
  } > "$ROOT/sessions.d/$NAME.conf"
}

run_login() { # <extra env...> -> rc; stdout+stderr in $T/out, tmux calls in $TMUX_LOG
  rm -f "$STATE/$NAME".*
  : > "$TMUX_LOG"
  HOME="$HOMEDIR" \
  STEWARD_ESTATE_ROOT="$ROOT" \
  STEWARD_CONFIG_FILE="$T/no-such-config" \
  STEWARD_REGISTRY_LIB="$LIBS/registry.sh" \
  STEWARD_TMUX_SOCKET="$T/fixture.sock" \
  STEWARD_HOME_LOOKUP_CMD="$BIN/login-home" \
  PATH="$BIN:$PATH" \
    env "$@" bash "$SUP" "$NAME" >"$T/out" 2>&1
}

write_login_conf
rm -f "$T_HAS_SESSION" "$T_CLAUDE_ALIVE"
run_login; rc8_nologin=$?
log_nologin="$(cat "$TMUX_LOG")"
is  "8a a dead session with no LOGIN still spawns, rc 0"    "$rc8_nologin" "0"
has "8b and tmux was asked to create it"                    "$log_nologin" "new-session"

write_login_conf acme-team
rm -f "$T_HAS_SESSION" "$T_CLAUDE_ALIVE"
run_login; rc8_login=$?
log_login="$(cat "$TMUX_LOG")"
is  "8c a resolvable LOGIN still spawns, rc 0"               "$rc8_login" "0"
has "8d the exec prefix sits immediately before the claude binary, directory resolved" \
    "$log_login" \
    "/usr/bin/env -u ANTHROPIC_API_KEY -u ANTHROPIC_AUTH_TOKEN -u CLAUDE_CONFIG_DIR CLAUDE_CONFIG_DIR=$HOMEDIR/.claude-logins/acme $HOMEDIR/.local/bin/claude"

write_login_conf
rm -f "$T_HAS_SESSION" "$T_CLAUDE_ALIVE"
run_login; rc8_nologin2=$?
log_nologin2="$(cat "$TMUX_LOG")"
is "8e without LOGIN the command line is byte-identical to the no-LOGIN form" \
   "$log_nologin2" "$log_nologin"

echo "== 8f. a set but unresolvable LOGIN refuses BEFORE any tmux write =="
write_login_conf does-not-exist
rm -f "$T_HAS_SESSION" "$T_CLAUDE_ALIVE"
run_login; rc8_ghost=$?
log_ghost="$(cat "$TMUX_LOG")"
out8_ghost="$(cat "$T/out")"
is    "8f rc 78 -- LOGIN does not resolve"    "$rc8_ghost" "78"
hasnt "8g and no tmux write happened"          "$log_ghost" "new-session"
has   "8h the refusal names the slug"          "$out8_ghost" "does-not-exist"

echo "== 8i. an AMBIENT exported LOGIN cannot become the session's login (finding 2) =="
# The macOS twin reads LOGIN through registry_load, whose reset line clears
# LOGIN="" before sourcing the conf. This twin sources the conf straight into
# its own shell -- a LOGIN exported into the supervisor's own environment
# must not leak into a session whose conf is silent about it.
write_login_conf
rm -f "$T_HAS_SESSION" "$T_CLAUDE_ALIVE"
run_login LOGIN=acme-team; rc8_ambient=$?
log_ambient="$(cat "$TMUX_LOG")"
is    "8i an ambient LOGIN with a LOGIN-less conf still spawns, rc 0" "$rc8_ambient" "0"
# 8j WAS `hasnt ... "/usr/bin/env -u ANTHROPIC_API_KEY"` UNTIL THE SCRUB BECAME
# UNCONDITIONAL. It is FLIPPED, not deleted, for the same reason the estate
# twin's golden master is moved rather than silenced: the assertion that used
# to prove "no prefix at all" now proves the exact thing that changed -- the
# scrub is there, the DIRECTORY is not. A deleted assertion would have left the
# ambient-LOGIN case measuring nothing about the directory.
has   "8j and the command line carries the scrub but no directory" "$log_ambient" \
      "-u ANTHROPIC_AUTH_TOKEN $HOMEDIR/.local/bin/claude"
hasnt "8j the ambient LOGIN still cannot set a config directory" "$log_ambient" "CLAUDE_CONFIG_DIR="
is    "8k the command line is byte-identical to the no-LOGIN form"    "$log_ambient" "$log_nologin"

echo "== 8l. WITHOUT a LOGIN the branch STILL scrubs both auth overrides =="
# THE CASE THAT WAS MISSING. The library could make the scrub unconditional
# while this twin called it only inside `if [ -n "$LOGIN" ]` -- a rule closed
# in the code and open in production. These three measure the BRANCH, not the
# function: both keys unset, and NO directory, because the ambient directory
# must survive a LOGIN-less session (unsetting it would move every such
# session to another account silently).
has   "8l the branch emits -u ANTHROPIC_API_KEY with no LOGIN"    "$log_nologin" "-u ANTHROPIC_API_KEY"
has   "8m the branch emits -u ANTHROPIC_AUTH_TOKEN with no LOGIN" "$log_nologin" "-u ANTHROPIC_AUTH_TOKEN"
hasnt "8n and it sets no config directory"                        "$log_nologin" "CLAUDE_CONFIG_DIR="

# Restore the shared conf to its LOGIN-less base shape for cleanliness.
write_login_conf

echo "== 9. THE STOPPTEST: schema over this checkout's max refuses, rc 78, ZERO spawn =="
# Task 6B: this twin now asks registry_load for its VERDICT on every row (a
# subshell call, additive to the raw source above it), so the schema gate that
# lives in that loader -- inert on this platform until now -- finally bites
# here. Measured before this task: registry_load zero calls, registry_schema_check
# zero calls. Both directions are measured, because a gate proven only in the
# direction that stops is indistinguishable from a gate that stops everything.
stopptest() { # <description> <rc> <spawn-evidence file> <forbidden string>
  local d="$1" rc="$2" f="$3" pat="$4"
  [ "$rc" -eq 78 ] && ok "$d: rc 78" || bad "$d: rc 78" "got rc=$rc"
  if [ -s "$f" ] && grep -q "$pat" "$f"; then
    bad "$d: ZERO spawn" "it started anyway: $(cat "$f")"
  else ok "$d: ZERO spawn"; fi
}

write_login_conf   # the LOGIN-less row from section 8's own helper

echo "== 9a. SCHEMA_VERSION over REGISTRY_SCHEMA_MAX: rc 78, no tmux write =="
# THE BOUNDARY IS READ FROM THE LIBRARY, not hardcoded -- a fixture that
# hardcodes "one past REGISTRY_SCHEMA_MAX" as a literal number is only true
# on the day it was written. The number this checkout reads up to moves as
# the library's own schema history grows; this case must stay "one past
# whatever that is today", the same pattern test/identity-schema.test.sh
# already uses for its own over-the-ceiling case.
max9a="$( ( . "$here/lib/registry.sh"; printf '%s' "$REGISTRY_SCHEMA_MAX" ) )"
over9a=$((max9a + 1))
printf 'SCHEMA_VERSION="%s"\n' "$over9a" >> "$ROOT/estate/steward.conf"
rm -f "$T_HAS_SESSION" "$T_CLAUDE_ALIVE"
run_login; rc9a=$?
out9a="$(cat "$T/out")"
stopptest "9a Linux supervisor, schema over the ceiling" "$rc9a" "$TMUX_LOG" "new-session"
has "9a the refusal names the library, not a guess" "$out9a" "registry library will not load this row"
# The whole reason for the second registry_load call is to relay the
# LIBRARY's own reason, not just the supervisor's generic sentence above --
# without this assertion, deleting the relay line leaves the suite green.
has "9a the library's own reason is relayed" "$out9a" "this checkout reads up to"

echo "== 9b. SCHEMA_VERSION below the ceiling: starts, byte-identical to the no-LOGIN control =="
sed -i.bak '/^SCHEMA_VERSION=/d' "$ROOT/estate/steward.conf"
printf 'SCHEMA_VERSION="5"\n' >> "$ROOT/estate/steward.conf"
rm -f "$ROOT/estate/steward.conf.bak"
rm -f "$T_HAS_SESSION" "$T_CLAUDE_ALIVE"
run_login; rc9b=$?
log9b="$(cat "$TMUX_LOG")"
is  "9b rc 0 -- schema 5 is below the ceiling"                       "$rc9b" "0"
has "9b the session was spawned"                                    "$log9b" "new-session"
is  "9b the launch line is byte-identical to the no-LOGIN control" "$log9b" "$log_nologin"

# Restore: no SCHEMA_VERSION line, matching the estate fixture every section
# above and below this one relies on.
sed -i.bak '/^SCHEMA_VERSION=/d' "$ROOT/estate/steward.conf"
rm -f "$ROOT/estate/steward.conf.bak"

echo "== 10. LOGIN: the resume path and the trust file follow the login, not \$HOME/.claude =="
# Task 7's own two Linux edits -- HIST (~:364) and CLAUDE_JSON (~:1011) -- had
# no coverage anywhere in this repo. Reverting either line in isolation left
# this whole suite (sections 0-9) green, because no case here ever planted a
# thread or a trust file on BOTH sides of the CFG_ROOT split. These cases do.
CFG="$HOMEDIR/.claude-logins/acme"
MUNGE="$(printf '%s' "$HOMEDIR/Projects/repo" | sed 's|[^a-zA-Z0-9]|-|g')"
reset_projects() { rm -rf "$HOMEDIR/.claude-logins" "$HOMEDIR/.claude"; }

echo "== 10a. a thread filed under the login's OWN directory is the one resumed =="
reset_projects
write_login_conf acme-team
mkdir -p "$CFG/projects/$MUNGE"
printf '{"type":"last-prompt","timestamp":"2026-08-31T10:00:00Z"}\n' \
  > "$CFG/projects/$MUNGE/aaaaaaaa-1111-2222-3333-444444444444.jsonl"
rm -f "$T_HAS_SESSION" "$T_CLAUDE_ALIVE"
run_login; rc10a=$?
log10a="$(cat "$TMUX_LOG")"
is  "10a rc 0"                                          "$rc10a" "0"
has "10a the launch line resumes the login's own thread" \
    "$log10a" "--resume aaaaaaaa-1111-2222-3333-444444444444"

echo "== 10b. the SAME thread sitting under legacy ~/.claude is invisible -- the login's own store is empty, so the start is FRESH, not the legacy thread =="
reset_projects
write_login_conf acme-team
mkdir -p "$HOMEDIR/.claude/projects/$MUNGE"
printf '{"type":"last-prompt","timestamp":"2026-08-31T10:00:00Z"}\n' \
  > "$HOMEDIR/.claude/projects/$MUNGE/bbbbbbbb-1111-2222-3333-444444444444.jsonl"
rm -f "$T_HAS_SESSION" "$T_CLAUDE_ALIVE"
run_login; rc10b=$?
log10b="$(cat "$TMUX_LOG")"
is    "10b rc 0"                                        "$rc10b" "0"
hasnt "10b the launch line does not carry --resume at all -- this is the case the task exists for" \
      "$log10b" "--resume"

echo "== 10c. no-LOGIN control: the legacy directory is still read exactly as before =="
reset_projects
write_login_conf
mkdir -p "$HOMEDIR/.claude/projects/$MUNGE"
printf '{"type":"last-prompt","timestamp":"2026-08-31T10:00:00Z"}\n' \
  > "$HOMEDIR/.claude/projects/$MUNGE/cccccccc-1111-2222-3333-444444444444.jsonl"
rm -f "$T_HAS_SESSION" "$T_CLAUDE_ALIVE"
run_login; rc10c=$?
log10c="$(cat "$TMUX_LOG")"
is  "10c rc 0"                                                     "$rc10c" "0"
has "10c without LOGIN the launch line resumes ~/.claude's thread, unchanged" \
    "$log10c" "--resume cccccccc-1111-2222-3333-444444444444"

echo "== 10d. the trust file follows the login too, and leaves \$HOME/.claude.json alone =="
# ensure_workspace_trusted only WRITES an existing file ([ -f "$CLAUDE_JSON" ]
# || return 0) -- so the fixture pre-creates the file it expects the function
# to update, on each side, and leaves the other side absent.
reset_projects
write_login_conf acme-team
mkdir -p "$CFG"
printf '{"projects":{}}\n' > "$CFG/.claude.json"
rm -f "$T_HAS_SESSION" "$T_CLAUDE_ALIVE"
run_login; rc10d=$?
is "10d rc 0" "$rc10d" "0"
trust10d="$(jq -r --arg p "$HOMEDIR/Projects/repo" '.projects[$p].hasTrustDialogAccepted // false' "$CFG/.claude.json" 2>/dev/null)"
is "10d the login's own trust file was written"     "$trust10d" "true"
[ -e "$HOMEDIR/.claude.json" ] && bad "10d and \$HOME/.claude.json was left alone" "it exists" \
                               || ok "10d and \$HOME/.claude.json was left alone"

echo "== 10d-ctrl. no-LOGIN control: the legacy trust file is still the one written =="
reset_projects
write_login_conf
printf '{"projects":{}}\n' > "$HOMEDIR/.claude.json"
rm -f "$T_HAS_SESSION" "$T_CLAUDE_ALIVE"
run_login; rc10dctrl=$?
is "10d-ctrl rc 0" "$rc10dctrl" "0"
trust10dctrl="$(jq -r --arg p "$HOMEDIR/Projects/repo" '.projects[$p].hasTrustDialogAccepted // false' "$HOMEDIR/.claude.json" 2>/dev/null)"
is "10d-ctrl without LOGIN the legacy trust file is still the one written, unchanged" \
   "$trust10dctrl" "true"

# Restore the shared conf to its LOGIN-less base shape, and drop the login
# directories this section created, for cleanliness.
write_login_conf
reset_projects

echo "pass=$pass fail=$fail"
[ "$fail" -eq 0 ]
