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
cp "$here/lib/registry.sh" "$here/lib/mcprender.sh" "$here/lib/mcpspawn.sh" "$LIBS/"
printf '#!/bin/sh\nexit 0\n' > "$HOMEDIR/.local/bin/claude"; chmod 755 "$HOMEDIR/.local/bin/claude"

# THE SHARED LABEL: the exact shape of the live collision - two rows, one home,
# one uid, one label. MINE is the row being supervised; SIB is its sibling.
LABEL='Steward -> Basement'
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

# ── THE FIXTURE MACHINE ────────────────────────────────────────────────────
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
run() { # <session-id>
  : > "$TMUX_LOG"; : > "$PGREP_LOG"; : > "$KILL_LOG"
  HOME="$HOMEDIR" \
  STEWARD_ESTATE_ROOT="$ROOT" \
  STEWARD_CONFIG_FILE="$T/no-such-config" \
  STEWARD_REGISTRY_LIB="$LIBS/registry.sh" \
  STEWARD_TMUX_SOCKET="$T/fixture.sock" \
  STEWARD_KILL="$BIN/killrec" \
  PATH="$BIN:$PATH" \
  bash "$SUP" "$1" >"$T/out" 2>&1
}
killed() { grep -qx "$1" "$KILL_LOG"; }

echo "== 1. a sibling's live claude, same label, same home - survives =="
# 4242 is the SIBLING's pane, alive on the socket. 4243 is its claude, wearing
# the very label this row is about to hunt for. 5000 is a genuine orphan:
# same label, reparented to init, no pane anywhere.
cat > "$PROCTAB" <<EOF
4242 1 -bash
4243 4242 $CLAUDE --permission-mode bypassPermissions --remote-control "$LABEL"
5000 1 $CLAUDE --permission-mode bypassPermissions --remote-control "$LABEL"
EOF
printf '4242\n' > "$PANES"
run "$MINE"
klog="$(cat "$KILL_LOG")"; out="$(cat "$T/out")"
if killed 4243; then bad "1a the sibling's LIVE claude is not killed" "kill log: $klog"
else ok "1a the sibling's LIVE claude is not killed"; fi
if killed 5000; then ok "1b the genuine orphan IS still reaped"
else bad "1b the genuine orphan IS still reaped" "kill log: $klog"; fi
has   "1c the reap says which pid it took" "$out" "killed orphan claude 5000"
hasnt "1d and never claims the sibling's pid" "$out" "killed orphan claude 4243"
has   "1e the veto asked for EVERY pane on the socket" "$(cat "$TMUX_LOG")" "list-panes -a"

echo "== 2. no pane on the socket at all - the orphan is still reaped =="
# The "never kill anything" control: with an empty pane set the fix must not
# turn into a no-op. Both matching pids are orphans here.
: > "$PANES"
run "$MINE"
klog2="$(cat "$KILL_LOG")"
if killed 5000; then ok "2a an orphan is reaped when no pane exists anywhere"
else bad "2a an orphan is reaped when no pane exists anywhere" "kill log: $klog2"; fi
if killed 4243; then ok "2b and so is the now-paneless 4243"
else bad "2b and so is the now-paneless 4243" "kill log: $klog2"; fi

echo "== 3. an RC-FREE row's broad pattern kills only what has no pane =="
# RC_LABEL="" widens CLAUDE_PAT to "any claude in this home". The pane binding
# is then the ONLY thing standing between one respawn and every conversation
# in the home. 4243 here carries a DIFFERENT label - the pattern still matches it.
cat > "$PROCTAB" <<EOF
4242 1 -bash
4243 4242 $CLAUDE --permission-mode bypassPermissions --remote-control "Someone Else"
5000 1 $CLAUDE --permission-mode bypassPermissions --remote-control "Third Party"
EOF
printf '4242\n' > "$PANES"
run "$FREE"
klog3="$(cat "$KILL_LOG")"
has "3a the RC-free pattern really is the broad one" "$(cat "$PGREP_LOG")" '^[^ ]*claude( |$)'
if killed 4243; then bad "3b another session's live claude survives the broad pattern" "kill log: $klog3"
else ok "3b another session's live claude survives the broad pattern"; fi
if killed 5000; then ok "3c while the paneless one is reaped"
else bad "3c while the paneless one is reaped" "kill log: $klog3"; fi

echo "== 4. a deep descendant of a live pane is not an orphan =="
# The runtime is usually one hop from the pane, but not always: a login prefix
# or a wrapper puts a shell in between. The veto climbs, it does not compare.
cat > "$PROCTAB" <<EOF
4242 1 -bash
4300 4242 sh -c wrapper
4243 4300 $CLAUDE --permission-mode bypassPermissions --remote-control "$LABEL"
5000 1 $CLAUDE --permission-mode bypassPermissions --remote-control "$LABEL"
EOF
printf '4242\n' > "$PANES"
run "$MINE"
klog4="$(cat "$KILL_LOG")"
if killed 4243; then bad "4a a grandchild of a live pane survives" "kill log: $klog4"
else ok "4a a grandchild of a live pane survives"; fi
if killed 5000; then ok "4b the orphan beside it is still reaped"
else bad "4b the orphan beside it is still reaped" "kill log: $klog4"; fi

echo "pass=$pass fail=$fail"
[ "$fail" -eq 0 ]
