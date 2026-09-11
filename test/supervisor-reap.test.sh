#!/bin/bash
# test/supervisor-reap.test.sh - the orphan reap kills what belongs to NO pane.
#
# THE GAP, measured on a live Linux host 2026-09-09. reap_orphan_claude ran on
# every spawn with the guard "MY tmux session is gone" and the kill set "every
# pid in this home whose argv matches this row's CLAUDE_PAT". Nothing bound a
# candidate to a pane. Two sessions in the same home, under the same uid,
# carried the same RC_LABEL - so each session's zombie repair (which runs
# kill-session first, making the guard always false) SIGTERMed the OTHER
# session's LIVE claude, which two rounds later became the other's zombie
# verdict. An alternating mutual kill: 13 events in 55 minutes, each one a
# destroyed conversation.
#
# THE LATENT CASE IS WIDER. An RC-FREE row (RC_LABEL="") sets
# CLAUDE_PAT='^[^ ]*claude( |$)' - ANY claude in the home. One respawn of such
# a row would have killed every claude that home was running.
#
# FOUR CLAIMS:
#   1. A sibling session's LIVE claude, sharing this row's RC_LABEL, survives
#      the reap - it descends from a pane on the socket.
#   2. A GENUINE orphan - matching the pattern, descending from no pane at all -
#      is still reaped. This is the direction that must not regress: without it
#      "never kill anything" would pass claim 1.
#   3. Same, for an RC-FREE row's much broader pattern.
#   4. The veto is the PANE SET OF THE WHOLE SOCKET (list-panes -a), not this
#      session's own panes - by the time the zombie path calls the reap, this
#      session's panes are exactly what it just killed.
#
# NOTHING HERE TOUCHES THE MACHINE: tmux, pgrep and ps are shims over a
# fixture process table, and the kill goes through STEWARD_KILL.
set -u
here="$(CDPATH= cd -- "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SUP="${SUP_OVERRIDE:-$here/linux/session-supervisor-linux.sh}"   # SUP_OVERRIDE: a mutated copy, for the mutation runs
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
cp "$here/lib/registry.sh" "$here/lib/bridge.sh" "$here/lib/mcprender.sh" "$here/lib/mcpspawn.sh" "$LIBS/"
mkdir -p "$HOMEDIR/scripts/runtime"; printf '#!/bin/sh\nexit 0\n' > "$HOMEDIR/scripts/runtime/opencode-session.sh"; chmod 755 "$HOMEDIR/scripts/runtime/opencode-session.sh"
printf '#!/bin/sh\nexit 0\n' > "$HOMEDIR/.local/bin/claude"; chmod 755 "$HOMEDIR/.local/bin/claude"

# THE SHARED LABEL: the exact shape of the live collision - two rows, one home,
# one uid, one label. MINE is the row being supervised; SIB is its sibling.
LABEL='Steward -> Host-A'
MINE="s-0000000000000001"
SIB="s-0000000000000002"
FREE="s-0000000000000003"
row() { # <id> <rc-label>
  cat > "$ROOT/sessions.d/$1.conf" <<EOF
OWNER="a"
HOST="h1"
DOMAIN="alpha"
REPO_PATH="$HOMEDIR/Projects/repo"
ID="$1"
RC_LABEL="$2"
CLAUDE_MEMORY_ROOT="$T/memory"
EOF
}
row "$MINE" "$LABEL"
row "$SIB"  "$LABEL"
row "$FREE" ""

# -- THE FIXTURE MACHINE ----------------------------------------------------
# One table, three readers. Columns: pid ppid argv...
PROCTAB="$T/proctab"
PANES="$T/panes-all"
export PROCTAB PANES
# tmux: -S <sock> is stripped, then the verb. has-session answers NO for every
# session (the reap's own guard), list-panes -a serves the socket-wide pane set.
cat > "$BIN/tmux" <<'EOF'
#!/bin/bash
printf '%s\n' "$*" >> "$TMUX_LOG"
argv=("$@")
[ "${argv[0]:-}" = "-S" ] && argv=("${argv[@]:2}")
case "${argv[0]:-}" in
  has-session)  exit 1 ;;
  list-panes)
    # -a is the socket-wide set; -s -t "=NAME" is this session's own, and this
    # session has none (it is the one that is gone).
    for a in "${argv[@]}"; do [ "$a" = "-a" ] && { cat "$PANES"; exit 0; }; done
    exit 0 ;;
  list-clients) exit 0 ;;
  new-session)  for a in "${argv[@]}"; do [ "$a" = "-P" ] && echo 4242; done; exit 0 ;;
  *)            exit 0 ;;
esac
EOF
# pgrep -u <uid> -f <pattern>: the pattern is applied, as an ERE, to the argv
# column of the table - so the row's REAL CLAUDE_PAT is what gets exercised.
cat > "$BIN/pgrep" <<'EOF'
#!/bin/bash
pat=""; prev=""
for a in "$@"; do [ "$prev" = "-f" ] && pat="$a"; prev="$a"; done
printf '%s\n' "$pat" >> "$PGREP_LOG"
[ -n "$pat" ] || exit 1
found=0
while read -r pid ppid argv; do
  case "$pid" in ""|\#*) continue ;; esac
  if printf '%s' "$argv" | grep -Eq -- "$pat"; then printf '%s\n' "$pid"; found=1; fi
done < "$PROCTAB"
[ "$found" = 1 ]
EOF
# ps -o ppid= -p <pid>: the table's second column, the one is_descendant climbs.
cat > "$BIN/ps" <<'EOF'
#!/bin/bash
pid=""; prev=""
for a in "$@"; do [ "$prev" = "-p" ] && pid="$a"; prev="$a"; done
[ -n "$pid" ] || exit 1
while read -r p pp rest; do
  case "$p" in ""|\#*) continue ;; esac
  [ "$p" = "$pid" ] && { printf ' %s\n' "$pp"; exit 0; }
done < "$PROCTAB"
exit 1
EOF
# STEWARD_KILL: the production seam that already exists because kill is a
# builtin. It RECORDS instead of signalling - nothing on this machine is aimed at.
cat > "$BIN/killrec" <<'EOF'
#!/bin/bash
printf '%s\n' "$1" >> "$KILL_LOG"
EOF
chmod 755 "$BIN/tmux" "$BIN/pgrep" "$BIN/ps" "$BIN/killrec"
export TMUX_LOG="$T/tmux.log" PGREP_LOG="$T/pgrep.log" KILL_LOG="$T/kill.log"

CLAUDE="$HOMEDIR/.local/bin/claude"
export T_HAS_SESSION="$T/never-has-session"
cat > "$BIN/observe" <<'EOF'
#!/bin/bash
# THE OBSERVER SHIM: its measuring is proven in test/bridge-observe.test.sh; here it answers from
# the fixture's two control files so this suite keeps testing what the supervisor DOES.
printf '%s\n' "$*" >> "${OBS_LOG:-/dev/null}"; id="${1:-}"; [ "$id" = --bootstrap ] && id="${2:-}"
if [ -f "${T_CLAUDE_ALIVE:-/nonexistent}" ] && [ -f "$T_HAS_SESSION" ]; then
  printf '%s\037identified:managed\0374243\037boot-m:111\037%s:@0.%%0\037L\0371\037alive\037live:managed\037\0374243\037t\0371\037$7:1789000000\037777\n' "$id" "$id"
elif [ -f "$T_HAS_SESSION" ]; then
  printf '%s\037no-process\037\037\037\037\037\037gone-noreceipt\037\037\037\037\037\037$7:1789000000\037\n' "$id"
else
  printf '%s\037no-process\037\037\037\037\037\037gone-noreceipt\037\037\037\037\037\037\037\n' "$id"
fi
EOF
cat > "$BIN/nonce" <<'EOF'
#!/bin/bash
echo 0123456789abcdef0123456789abcdef
EOF
chmod 755 "$BIN/observe" "$BIN/nonce"
PROC="$T/proc"; mkdir -p "$PROC/sys/kernel/random" "$PROC/4242"
printf 'boot-m\n' > "$PROC/sys/kernel/random/boot_id"; printf '500.00 400.00\n' > "$PROC/uptime"
printf '4242 (bash) S 1 4242 4242 0 -1 0 0 0 0 0 0 0 0 0 20 0 1 0 100 0 0 0\n' > "$PROC/4242/stat"
export OBS_LOG="$T/obs.log"
BRIDGE_ENV=( STEWARD_BRIDGE_OBSERVE="$BIN/observe" STEWARD_NONCE_CMD="$BIN/nonce" BRIDGE_PROC_ROOT="$PROC" STEWARD_BRIDGE_LIB="$LIBS/bridge.sh" )

OCROW="s-0000000000000004"; PORT=4097
cat > "$ROOT/sessions.d/$OCROW.conf" <<EOF
OWNER="a"
HOST="h1"
DOMAIN="alpha"
REPO_PATH="$HOMEDIR/Projects/repo"
ID="$OCROW"
RC_LABEL=""
KIND="advisor"
RUNTIME="opencode"
MODEL="openai/example-model"
OPENCODE_VERSION="1.18.14"
OPENCODE_PORT="$PORT"
AUTO_APPROVE="true"
CLAUDE_MEMORY_ROOT="$T/memory"
EOF
run() { # <session-id> - TWO rounds: a claude row's spawn is a keyed two-round suspect since the
        # bridge adapter (plan v6 Task 5), and the claim here is what the SPAWN does not do.
  : > "$TMUX_LOG"; : > "$PGREP_LOG"; : > "$KILL_LOG"
  local i; for i in 1 2; do
  HOME="$HOMEDIR" \
  STEWARD_ESTATE_ROOT="$ROOT" \
  STEWARD_CONFIG_FILE="$T/no-such-config" \
  STEWARD_REGISTRY_LIB="$LIBS/registry.sh" \
  STEWARD_TMUX_SOCKET="$T/fixture.sock" \
  STEWARD_KILL="$BIN/killrec" \
  PATH="$BIN:$PATH" \
  env "${BRIDGE_ENV[@]}" bash "$SUP" "$1" >"$T/out" 2>&1
  done
}
killed() { grep -qx "$1" "$KILL_LOG"; }

# SINCE THE BRIDGE ADAPTER (plan v6 Task 5) A CLAUDE ROW NEVER RUNS THE PATTERN REAP. Its orphans
# are the adapter's: identified:orphan, keyed over two rounds, signalled on a pidfd pin
# (test/supervisor-bridge.test.sh claim 6). The direction that must not regress is now the
# OPPOSITE of the one this file was written for: NOTHING in a claude row's home is killed by an
# argv pattern - not the sibling, not the stranger, not even a genuine orphan. The pattern reap
# survives for the OpenCode path, which finds its process by port (claim 5).

echo "== 1. a claude row: a sibling's live claude AND a genuine orphan both survive the spawn =="
cat > "$PROCTAB" <<EOF
4242 1 -bash
4243 4242 $CLAUDE --permission-mode bypassPermissions --remote-control "$LABEL"
5000 1 $CLAUDE --permission-mode bypassPermissions --remote-control "$LABEL"
EOF
printf '4242\n' > "$PANES"
run "$MINE"
klog="$(cat "$KILL_LOG")"; out="$(cat "$T/out")"
if killed 4243; then bad "1a the sibling's LIVE claude is not killed" "kill log: $klog"; else ok "1a the sibling's LIVE claude is not killed"; fi
if killed 5000; then bad "1b the orphan is NOT reaped by pattern (it is the adapter's, on the pin)" "kill log: $klog"; else ok "1b the orphan is NOT reaped by pattern (it is the adapter's, on the pin)"; fi
has   "1c the spawn itself happened (so the reap had its chance and did not take it)" "$(cat "$TMUX_LOG")" "new-session"
hasnt "1d no pattern reap message" "$out" "killed orphan claude"
is    "1e no claude argv pattern was ever asked of pgrep" "$(grep -c 'claude' "$PGREP_LOG")" "0"

echo "== 2. no pane on the socket at all - still nothing killed by pattern =="
: > "$PANES"
run "$MINE"
is "2a kill log empty" "$(cat "$KILL_LOG")" ""

echo "== 3. an RC-FREE claude row: the broad pattern is never consulted either =="
cat > "$PROCTAB" <<EOF
4242 1 -bash
4243 4242 $CLAUDE --permission-mode bypassPermissions --remote-control "Someone Else"
5000 1 $CLAUDE --permission-mode bypassPermissions --remote-control "Third Party"
EOF
printf '4242\n' > "$PANES"
run "$FREE"
is    "3a kill log empty" "$(cat "$KILL_LOG")" ""
hasnt "3b the broad pattern was not asked" "$(cat "$PGREP_LOG")" '^[^ ]*claude( |$)'

echo "== 4. a deep descendant of a live pane: same answer, nothing =="
cat > "$PROCTAB" <<EOF
4242 1 -bash
4300 4242 sh -c wrapper
4243 4300 $CLAUDE --permission-mode bypassPermissions --remote-control "$LABEL"
5000 1 $CLAUDE --permission-mode bypassPermissions --remote-control "$LABEL"
EOF
printf '4242\n' > "$PANES"
run "$MINE"
is "4a kill log empty" "$(cat "$KILL_LOG")" ""

echo "== 5. the OpenCode path keeps the pattern reap, by port, bound to the pane set =="
cat > "$PROCTAB" <<EOF
4242 1 -bash
4243 4242 /x/opencode $HOMEDIR/Projects/repo --session s --port $PORT
5000 1 /x/opencode $HOMEDIR/Projects/repo --session s --port $PORT
6000 1 /x/opencode $HOMEDIR/Projects/repo --session s --port 9999
EOF
printf '4242\n' > "$PANES"
run "$OCROW"
klog5="$(cat "$KILL_LOG")"
if killed 5000; then ok "5a the paneless adapter on THIS row's port is reaped"; else bad "5a the paneless adapter on THIS row's port is reaped" "kill log: $klog5"; fi
if killed 4243; then bad "5b the one under a live pane survives" "kill log: $klog5"; else ok "5b the one under a live pane survives"; fi
if killed 6000; then bad "5c another row's port is not this row's business" "kill log: $klog5"; else ok "5c another row's port is not this row's business"; fi
has "5d the veto asked for EVERY pane on the socket" "$(cat "$TMUX_LOG")" "list-panes -a"
has "5e the pattern names the port" "$(cat "$PGREP_LOG")" "port $PORT"

echo "pass=$pass fail=$fail"
[ "$fail" -eq 0 ]
