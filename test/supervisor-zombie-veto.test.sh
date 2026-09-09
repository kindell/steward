#!/bin/bash
# test/supervisor-zombie-veto.test.sh - the zombie repair's veto must measure a
# HUMAN, not the existence of a tmux client.
#
# THE GAP, measured on a live Linux host 2026-09-09. The veto read
# `tmux list-clients` and deferred the repair while ANY client answered. An
# estate's hub session then sat dead for TWO HOURS while the supervisor saw the
# zombie every round and refused to repair it:
#
#   ZOMBIE-shaped, but a tmux client is ATTACHED - deferring the kill.
#
# The client was not a human. It was an orphaned
# `script -qfc env -u TMUX tmux ... attach` whose parent chain ended at
# `systemd --user`, and which systemd had ALREADY logged as debris: "Found
# left-over process 4166896 (tmux: client) in control group while starting
# unit." Its client_activity was 1788959854 = 13:17:34, the exact second the
# session's runtime died - debris from an earlier fault, holding the veto over
# the wreckage it came from. The message named nothing, so nobody reading the
# journal could see that the "human" was a two-hour-old ghost.
#
# SEVEN CLAIMS:
#   1. A client whose activity PREDATES the death is not a human: the repair
#      proceeds, and the line names the client and says why.
#   2. A client whose activity is NEWER than the death still defers the kill.
#      THIS IS THE DIRECTION THAT MUST NOT REGRESS - the veto exists because an
#      older repair typed into somebody's editor.
#   3. An orphan of `systemd --user` with stale activity: the repair proceeds
#      and the line says the system itself already called it a left-over.
#   4. RULED (see the comment in the supervisor): an orphan with FRESH activity
#      DEFERS. Freshness is evidence about NOW, ancestry only about provenance -
#      and on any host with a console or desktop session a human's own terminal
#      descends from the user manager too.
#   5. Activity that cannot be read at all: an orphan is debris, a non-orphan
#      keeps the veto. Ancestry decides only what activity cannot.
#   6. No clients at all: unchanged, the repair proceeds.
#   7. The supervisor ASKS tmux for the activity and the pid - it counts nothing.
#   8. A server that will not answer the formatted listing at all is NOT read as
#      "no clients attached": the veto is kept, which is the one way this change
#      could have killed something the old existence check protected.
#
# NOTHING HERE TOUCHES THE MACHINE: tmux, pgrep and ps are shims over a fixture
# process table, and no tmux, ssh or sudo binary is ever reached.
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

NAME="s-0000000000000001"
cat > "$ROOT/sessions.d/$NAME.conf" <<EOF
OWNER="a"
HOST="h1"
DOMAIN="alpha"
REPO_PATH="$HOMEDIR/Projects/repo"
ID="$NAME"
RC_LABEL="Fixture Hub"
CLAUDE_MEMORY_ROOT="$T/memory"
EOF

# -- THE FIXTURE MACHINE ----------------------------------------------------
# One process table, two readers (pgrep by argv, ps by ppid). Columns: pid ppid argv
#
#   900     the user manager. A left-over client is reparented to it, and
#           systemd logs exactly that.
#   4242    the zombie pane: a bare shell wearing the session's name.
#   416689  the GHOST client - the incident's shape, parent chain to 900.
#   5099    sshd, a child of the SYSTEM manager (pid 1) - not the user manager.
#   5100    a REAL human's attach, under that sshd.
PROCTAB="$T/proctab"
CLIENTS="$T/clients"
export PROCTAB CLIENTS
GHOST_PID=416689
HUMAN_PID=5100
GHOST_TTY=/dev/pts/2
HUMAN_TTY=/dev/pts/3
cat > "$PROCTAB" <<EOF
1 0 /sbin/init
900 1 /usr/lib/systemd/systemd --user
4242 900 -bash
$GHOST_PID 900 script -qfc env -u TMUX tmux -S /run/user/1000/fixture.sock attach
5099 1 sshd: a@pts/3
$HUMAN_PID 5099 tmux -S /run/user/1000/fixture.sock attach
EOF

# tmux: -S <sock> stripped, then the verb. list-clients renders the fixture
# client table THROUGH the format the supervisor asked for - so an unknown
# field expands to empty here exactly as a real server expands it, and the
# supervisor's own format string is what gets exercised. With NO -F it prints
# tmux's own default shape (the tty and the session), which is what the old
# existence check was reading.
cat > "$BIN/tmux" <<'EOF'
#!/bin/bash
printf '%s\n' "$*" >> "$TMUX_LOG"
argv=("$@")
[ "${argv[0]:-}" = "-S" ] && argv=("${argv[@]:2}")
fmt=""; prev=""
for a in "${argv[@]}"; do [ "$prev" = "-F" ] && fmt="$a"; prev="$a"; done
case "${argv[0]:-}" in
  has-session)  [ -f "$T_HAS_SESSION" ] && exit 0; exit 1 ;;
  list-panes)   [ -f "$T_HAS_SESSION" ] && echo 4242; exit 0 ;;
  list-clients)
    # T_NO_FORMAT: a server that will not take -F at all (or will not expand
    # the fields) - it answers a plain listing and nothing else.
    [ -n "${T_NO_FORMAT:-}" ] && [ -n "$fmt" ] && exit 1
    [ -f "$CLIENTS" ] || exit 0
    while IFS='|' read -r tty act cpid; do
      [ -n "$tty$act$cpid" ] || continue
      if [ -z "$fmt" ]; then printf '%s: fixture [80x24 xterm] (utf8)\n' "$tty"; continue; fi
      line="$fmt"
      line="${line//'#{client_tty}'/$tty}"
      line="${line//'#{client_activity}'/$act}"
      line="${line//'#{client_pid}'/$cpid}"
      printf '%s\n' "$line"
    done < "$CLIENTS"
    exit 0 ;;
  capture-pane) exit 0 ;;
  *)            exit 0 ;;
esac
EOF
# pgrep -u <uid> -f <pattern>: the pattern is applied as an ERE to the argv
# column, so the supervisor's REAL patterns are what get exercised.
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
cat > "$BIN/killrec" <<'EOF'
#!/bin/bash
printf '%s\n' "$1" >> "$KILL_LOG"
EOF
chmod 755 "$BIN/tmux" "$BIN/pgrep" "$BIN/ps" "$BIN/killrec"
export TMUX_LOG="$T/tmux.log" PGREP_LOG="$T/pgrep.log" KILL_LOG="$T/kill.log"
export T_HAS_SESSION="$T/has-session"
T_NO_FORMAT=""; export T_NO_FORMAT

STATE="$HOMEDIR/.local/state/fixture-supervisor"
SUSPECT="$STATE/$NAME.suspect"

# THE TEST'S OWN mtime READER, with the same shape filter the product needs:
# `stat -f` is FILESYSTEM status on GNU, exits 0 and prints a report that a
# non-empty check would swallow. Only an all-digit answer counts.
mtime_of() {
  local t
  for t in "$(stat -f '%m' "$1" 2>/dev/null)" "$(stat -c '%Y' "$1" 2>/dev/null)"; do
    case "$t" in ''|*[!0-9]*) continue ;; *) printf '%s' "$t"; return 0 ;; esac
  done
  return 1
}

# arm - a live session, no runtime in its pane, and a suspect marker from the
# previous round: the exact state the veto guards. $DEATH is the moment this
# session was first suspected dead, which is what the clients are timed against.
DEATH=0
arm() {
  mkdir -p "$STATE"
  touch "$T_HAS_SESSION"
  : > "$CLIENTS"
  touch "$SUSPECT"
  DEATH="$(mtime_of "$SUSPECT")"
}
# client <tty> <activity-epoch|""> <pid>
client() { printf '%s|%s|%s\n' "$1" "$2" "$3" >> "$CLIENTS"; }
run() {
  : > "$TMUX_LOG"; : > "$PGREP_LOG"; : > "$KILL_LOG"
  HOME="$HOMEDIR" \
  STEWARD_ESTATE_ROOT="$ROOT" \
  STEWARD_CONFIG_FILE="$T/no-such-config" \
  STEWARD_REGISTRY_LIB="$LIBS/registry.sh" \
  STEWARD_TMUX_SOCKET="$T/fixture.sock" \
  STEWARD_KILL="$BIN/killrec" \
  STEWARD_KEY_SETTLE_SEC=0 \
  PATH="$BIN:$PATH" \
  bash "$SUP" "$NAME" >"$T/out" 2>&1
}
repaired() { grep -q 'kill-session' "$TMUX_LOG" && grep -q 'new-session' "$TMUX_LOG"; }
untouched() { ! grep -q 'kill-session' "$TMUX_LOG" && ! grep -q 'new-session' "$TMUX_LOG"; }

echo "== 1. a client whose activity predates the death is not a human =="
arm
client "$HUMAN_TTY" "$(( DEATH - 3600 ))" "$HUMAN_PID"
run
out1="$(cat "$T/out")"
if repaired; then ok "1a the repair proceeds"; else bad "1a the repair proceeds" "tmux log: $(cat "$TMUX_LOG")"; fi
has "1b the line names the client's tty" "$out1" "$HUMAN_TTY"
has "1c and its pid"                     "$out1" "$HUMAN_PID"
has "1d and says why it is not a human"  "$out1" "BEFORE this session was first suspected dead"
[ -f "$SUSPECT" ] && bad "1e the suspect marker is cleared by the repair" "still there" \
                  || ok  "1e the suspect marker is cleared by the repair"

echo "== 2. a client active AFTER the death still defers the kill =="
# THE REGRESSION GUARD. A real human, attached over ssh, who touched a key
# since the session was first suspected dead.
arm
client "$HUMAN_TTY" "$(( DEATH + 42 ))" "$HUMAN_PID"
run
out2="$(cat "$T/out")"
if untouched; then ok "2a nothing is killed and nothing is spawned"; else bad "2a nothing is killed and nothing is spawned" "tmux log: $(cat "$TMUX_LOG")"; fi
has "2b the deferral is loud"            "$out2" "deferring the kill"
has "2c and names the client"            "$out2" "$HUMAN_TTY"
has "2d and says what it measured"       "$out2" "AFTER this session was first suspected dead"
[ -f "$SUSPECT" ] && ok  "2e the suspect cadence is kept (marker stays)" \
                  || bad "2e the suspect cadence is kept (marker stays)" "marker gone"

echo "== 3. an orphan of the user manager, stale, is named as debris =="
arm
client "$GHOST_TTY" "$(( DEATH - 1 ))" "$GHOST_PID"
run
out3="$(cat "$T/out")"
if repaired; then ok "3a the repair proceeds"; else bad "3a the repair proceeds" "tmux log: $(cat "$TMUX_LOG")"; fi
has "3b the line names the ghost"        "$out3" "$GHOST_TTY"
has "3c and its pid"                     "$out3" "$GHOST_PID"
has "3d and says the system called it debris" "$out3" "left-over process"
has "3e the ancestry was measured against the user manager" "$(cat "$PGREP_LOG")" "systemd --user"

echo "== 4. RULED: an orphan with FRESH activity defers =="
# Freshness is evidence about NOW; ancestry only about provenance. On a host
# with a console or desktop session a human's own terminal descends from the
# user manager too, so ancestry must never override a live keystroke.
arm
client "$GHOST_TTY" "$(( DEATH + 5 ))" "$GHOST_PID"
run
out4="$(cat "$T/out")"
if untouched; then ok "4a an orphan that was just active is not killed"; else bad "4a an orphan that was just active is not killed" "tmux log: $(cat "$TMUX_LOG")"; fi
has "4b the deferral says so"            "$out4" "deferring the kill"
has "4c and names the orphan"            "$out4" "$GHOST_TTY"
has "4d and records that activity outranks ancestry" "$out4" "activity outranks ancestry"

echo "== 5. unreadable activity: ancestry decides what activity cannot =="
arm
client "$GHOST_TTY" "" "$GHOST_PID"
run
out5="$(cat "$T/out")"
if repaired; then ok "5a an orphan with no readable activity is debris"; else bad "5a an orphan with no readable activity is debris" "tmux log: $(cat "$TMUX_LOG")"; fi
has "5b and the line says the activity could not be read" "$out5" "could not be read"
arm
client "$HUMAN_TTY" "" "$HUMAN_PID"
run
out5b="$(cat "$T/out")"
if untouched; then ok "5c a non-orphan with no readable activity keeps the veto"; else bad "5c a non-orphan with no readable activity keeps the veto" "tmux log: $(cat "$TMUX_LOG")"; fi
has "5d and says it could not measure" "$out5b" "could not be read"

echo "== 6. two clients, one ghost and one human: the human wins =="
arm
client "$GHOST_TTY" "$(( DEATH - 7200 ))" "$GHOST_PID"
client "$HUMAN_TTY" "$(( DEATH + 9 ))" "$HUMAN_PID"
run
out6="$(cat "$T/out")"
if untouched; then ok "6a one live human vetoes the repair"; else bad "6a one live human vetoes the repair" "tmux log: $(cat "$TMUX_LOG")"; fi
has "6b the ghost beside them is still named" "$out6" "$GHOST_TTY"
has "6c and the human is the reason"          "$out6" "$HUMAN_TTY"

echo "== 7. no clients at all: unchanged =="
arm
run
out7="$(cat "$T/out")"
if repaired; then ok "7a the repair proceeds with no client attached"; else bad "7a the repair proceeds with no client attached" "tmux log: $(cat "$TMUX_LOG")"; fi
has   "7b the zombie verdict is unchanged" "$out7" "ZOMBIE PANE"
hasnt "7c and nothing is said about clients" "$out7" "attached tmux client"

echo "== 8. the supervisor asks tmux for what it measures =="
arm
client "$HUMAN_TTY" "$(( DEATH + 1 ))" "$HUMAN_PID"
run
log8="$(cat "$TMUX_LOG")"
has "8a it asks for the client's activity" "$log8" "client_activity"
has "8b and for the client's pid"          "$log8" "client_pid"
has "8c and for the client's tty"          "$log8" "client_tty"

echo "== 9. a server that will not describe its clients keeps the veto =="
# The trap this change could have set: `list-clients -F` failing outright looks
# exactly like "nobody is attached", and the repair would kill a session the old
# existence check protected. The plain listing is the cross-check.
arm
client "$HUMAN_TTY" "$(( DEATH - 3600 ))" "$HUMAN_PID"
T_NO_FORMAT=1 run
out9="$(cat "$T/out")"
if untouched; then ok "9a an unreadable client is treated as a human"; else bad "9a an unreadable client is treated as a human" "tmux log: $(cat "$TMUX_LOG")"; fi
has "9b and the reason is named"   "$out9" "will not describe"
has "9c the plain listing was the cross-check" "$out9" "while a plain listing did"

echo "pass=$pass fail=$fail"
[ "$fail" -eq 0 ]
