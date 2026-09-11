#!/bin/bash
# test/supervisor-zombie-veto.test.sh - the zombie repair's veto must measure a
# HUMAN, not the existence of a tmux client - and it must measure IDLENESS
# AGAINST NOW, not the ordering of a client against a frozen marker.
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
# THE FIRST FIX WAS THE WRONG COMPARISON, and this suite is the round that
# corrects it. Asking "is the client's activity NEWER than the suspect marker?"
# looks right and is not: client_activity is set AT ATTACH (measured on tmux
# 3.6b, isolated socket - pane output does not move it, a keypress does), and
# the marker is never re-touched while the veto defers. So a client that
# attaches AFTER the marker sorts fresh FOREVER and holds the veto with no
# human anywhere and no keystroke ever - the incident's own debris, three
# minutes later. Claim 10 below is that exact shape and it must REPAIR.
#
# CLAIMS:
#   1. A client idle past the grace is not a human: the repair proceeds, and
#      the line names the client, its pid, and how long it has been silent.
#   2. A client that touched a key seconds ago defers the kill. THIS IS THE
#      DIRECTION THAT MUST NOT REGRESS - the veto exists because an older
#      repair typed into somebody's editor.
#   3. An orphan of `systemd --user`, idle past the grace: the repair proceeds
#      and the line says the system itself already called it a left-over.
#   4. RULED: an orphan with FRESH activity DEFERS. Freshness is evidence about
#      NOW, ancestry only about provenance - and on any host with a console or
#      desktop session a human's own terminal descends from the user manager.
#   5. Activity that cannot be read at all KEEPS THE VETO, orphan or not
#      (including tmux < 2.9, where client_activity is a formatted date and
#      this whole measurement degrades to the old existence check).
#   6. Two clients, one ghost and one human: the human wins.
#   7. No clients at all: unchanged, the repair proceeds.
#   8. The supervisor ASKS tmux for the activity and the pid - it counts nothing.
#   9. A server that will not answer the formatted listing at all is NOT read as
#      "no clients attached": the veto is kept.
#  10. THE INCIDENT'S SHAPE: a client that attached AFTER the death and then sat
#      idle for hours is REPAIRED. The ordering rule deferred this forever.
#  11. A server that ACCEPTS -F and expands every field to nothing is not read
#      as "no clients" either: rows came back and none described a client, so
#      the veto is kept.
#  12. The clock is not evidence. A suspect marker with an mtime in the FUTURE
#      must not turn a live human into debris, and neither must a client whose
#      activity is ahead of this host's clock.
#  13. The grace's cost is bounded and STATED: a human idle longer than the
#      window loses the pane, and the log says how long they were silent and
#      what the window was.
#  14. AN ACTIVITY VALUE THIS SUPERVISOR CANNOT DO ARITHMETIC ON MUST NOT
#      DISCARD A LIVE HUMAN'S VETO. A fatal arithmetic error aborts the whole
#      client loop and everything after it, including the deferral - so the
#      veto fails OPEN on a value it merely failed to read.
#  15. A deferral says how long the session has been ZOMBIE-shaped. The veto
#      cannot tell a re-attaching wrapper from a human who has just attached,
#      so it must not try - but an indefinite deferral has to be legible on one
#      line, which is exactly what the two-hour incident lacked.
#  16. On a host with no `systemd --user` ancestry is not measured at all, and
#      the journal must say that rather than assert the negative "no orphan".
#  17. EVERY DEFERRAL SAYS THE CLIENT IS ATTACHED, IN THAT WORD. The concrete
#      naming this round added is an addition to the old message, not a
#      replacement for it: "attached" is what an operator greps the journal for
#      when a session will not repair itself, and an estate's own supervision
#      suite asserts it on the deferral. The word is pinned HERE so the next
#      rewording goes red in this repository instead of in one two hops away.
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
cp "$here/lib/registry.sh" "$here/lib/bridge.sh" "$here/lib/mcprender.sh" "$here/lib/mcpspawn.sh" "$LIBS/"
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
    # T_NO_FORMAT: a server that will not take -F at all - it answers a plain
    # listing and nothing else.
    [ -n "${T_NO_FORMAT:-}" ] && [ -n "$fmt" ] && exit 1
    [ -f "$CLIENTS" ] || exit 0
    while IFS='|' read -r tty act cpid; do
      [ -n "$tty$act$cpid" ] || continue
      if [ -z "$fmt" ]; then printf '%s: fixture [80x24 xterm] (utf8)\n' "$tty"; continue; fi
      # T_EMPTY_FORMAT: a server that ACCEPTS -F and expands every field to the
      # empty string. One row per client comes back, describing nobody.
      if [ -n "${T_EMPTY_FORMAT:-}" ]; then tty=""; act=""; cpid=""; fi
      line="$fmt"
      line="${line//'#{client_tty}'/$tty}"
      line="${line//'#{client_activity}'/$act}"
      line="${line//'#{client_pid}'/$cpid}"
      printf '%s\n' "$line"
    done < "$CLIENTS"
    exit 0 ;;
  capture-pane) exit 0 ;;
  display-message) case "${argv[${#argv[@]}-1]}" in *session_id*) [ -f "$T_HAS_SESSION" ] && echo '$7:1789000000' ;; esac; exit 0 ;;
  kill-session) rm -f "$T_HAS_SESSION"; exit 0 ;;
  new-session)  for a in "${argv[@]}"; do [ "$a" = "-P" ] && echo 4242; done; touch "$T_HAS_SESSION"; exit 0 ;;
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
T_EMPTY_FORMAT=""; export T_EMPTY_FORMAT

STATE="$HOMEDIR/.local/state/fixture-supervisor"
SUSPECT="$STATE/$NAME.suspect"
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

# THE GRACE THIS SUITE MEASURES AGAINST. It is a constant in the supervisor on
# purpose - there is no environment knob to turn, so the suite states the same
# number and would go red if the two ever disagreed (claims 2, 13).
GRACE=900

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
# set_mtime <file> <epoch> - GNU form first, BSD form second. Both are tried
# because this suite runs on the laptop (BSD) and on the hosts (GNU), and the
# marker's age is what claims 10 and 12 are about.
set_mtime() {
  touch -d "@$2" "$1" 2>/dev/null && return 0
  touch -t "$(date -r "$2" +%Y%m%d%H%M.%S 2>/dev/null)" "$1" 2>/dev/null && return 0
  return 1
}

# arm [marker-age-seconds] - a live session, no runtime in its pane, and a
# suspect marker from a previous round: the exact state the veto guards.
# $NOW is what the supervisor's own `date +%s` will read; $DEATH is the moment
# the session was first suspected dead. THEY ARE NOT THE SAME NUMBER any more,
# and every claim below says which one it is timing against.
DEATH=0; NOW=0
arm() {
  mkdir -p "$STATE"
  touch "$T_HAS_SESSION"
  : > "$CLIENTS"
  # THE MARKER CARRIES THE KEY since the bridge adapter (plan v6 Task 5): round one recorded
  # `close <session_id>:<created>`, so this round is the confirming one. Its mtime is still the
  # gate's "first suspected dead" log text - a confirmed key does not rewrite the file.
  printf 'close $7:1789000000\n' > "$SUSPECT"
  NOW="$(date +%s)"
  if [ -n "${1:-}" ]; then
    set_mtime "$SUSPECT" "$(( NOW - $1 ))" || { bad "fixture: cannot backdate the suspect marker" "set_mtime failed"; return 1; }
  fi
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
  env "${BRIDGE_ENV[@]}" bash "$SUP" "$NAME" >"$T/out" 2>&1
}
repaired() { grep -q 'kill-session' "$TMUX_LOG" && grep -q 'new-session' "$TMUX_LOG"; }
untouched() { ! grep -q 'kill-session' "$TMUX_LOG" && ! grep -q 'new-session' "$TMUX_LOG"; }

echo "== 1. a client silent for longer than the grace is not a human =="
arm
client "$HUMAN_TTY" "$(( NOW - 3600 ))" "$HUMAN_PID"
run
out1="$(cat "$T/out")"
if repaired; then ok "1a the repair proceeds"; else bad "1a the repair proceeds" "tmux log: $(cat "$TMUX_LOG")"; fi
has "1b the line names the client's tty" "$out1" "$HUMAN_TTY"
has "1c and its pid"                     "$out1" "$HUMAN_PID"
has "1d and says why it is not a human"  "$out1" "past the ${GRACE}s grace"
# NOT ASSERTED: that the repair removes the suspect marker. Measured 2026-09-09:
# commenting out the `rm -f "$SUSPECT"` on the repair path leaves this suite
# fully green, because spawn_session clears the marker itself on every start.
# An assertion that cannot fail for the line it names is worse than no
# assertion - it reads as a guard and is not one. Claim 2e below IS one: the
# marker must SURVIVE a deferral, and nothing else on that path removes it.

echo "== 2. a client that touched a key seconds ago defers the kill =="
# THE REGRESSION GUARD. A real human, attached over ssh, who has been reading
# for a minute - well inside the grace.
arm
client "$HUMAN_TTY" "$(( NOW - 60 ))" "$HUMAN_PID"
run
out2="$(cat "$T/out")"
if untouched; then ok "2a nothing is killed and nothing is spawned"; else bad "2a nothing is killed and nothing is spawned" "tmux log: $(cat "$TMUX_LOG")"; fi
has "2b the deferral is loud"            "$out2" "deferring the kill"
has "2c and names the client"            "$out2" "$HUMAN_TTY"
has "2d and states the window it measured against" "$out2" "of ${GRACE}s"
[ -f "$SUSPECT" ] && ok  "2e the suspect cadence is kept (marker stays)" \
                  || bad "2e the suspect cadence is kept (marker stays)" "marker gone"
has "2f and says what would resume the repair" "$out2" "silent for ${GRACE}s"
# AND THE CLIENT THAT DEFERS IS NOT SIMULTANEOUSLY CALLED DEBRIS. This is the
# positive the old assertion 7c looked like it was making and could not: 7c
# lives in the no-clients case, where the debris line is unreachable by
# construction, so nothing there can fail. Here there IS a client, and a
# journal that both defers to it and names it as debris is incoherent.
hasnt "2g the human who holds the veto is not also named as debris" "$out2" "is not a working human"

echo "== 3. an orphan of the user manager, long silent, is named as debris =="
arm
client "$GHOST_TTY" "$(( NOW - 7200 ))" "$GHOST_PID"
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
client "$GHOST_TTY" "$(( NOW - 5 ))" "$GHOST_PID"
run
out4="$(cat "$T/out")"
if untouched; then ok "4a an orphan that was just active is not killed"; else bad "4a an orphan that was just active is not killed" "tmux log: $(cat "$TMUX_LOG")"; fi
has "4b the deferral says so"            "$out4" "deferring the kill"
has "4c and names the orphan"            "$out4" "$GHOST_TTY"
has "4d and records that activity outranks ancestry" "$out4" "activity outranks ancestry"

echo "== 5. unreadable activity keeps the veto, orphan or not =="
# ANCESTRY NEVER DECIDES AGAINST A HUMAN. Until 2026-09-09 an orphan whose
# activity could not be read was killed - which on tmux < 2.9 plus a desktop
# session is a live person at their own console.
arm
client "$GHOST_TTY" "" "$GHOST_PID"
run
out5="$(cat "$T/out")"
if untouched; then ok "5a an orphan with no readable activity keeps the veto"; else bad "5a an orphan with no readable activity keeps the veto" "tmux log: $(cat "$TMUX_LOG")"; fi
has "5b and the line says the activity could not be read" "$out5" "could not be read"
arm
client "$HUMAN_TTY" "" "$HUMAN_PID"
run
out5b="$(cat "$T/out")"
if untouched; then ok "5c a non-orphan with no readable activity keeps the veto"; else bad "5c a non-orphan with no readable activity keeps the veto" "tmux log: $(cat "$TMUX_LOG")"; fi
has "5d and says it could not measure" "$out5b" "could not be read"
# tmux < 2.9: client_activity is a formatted date, not an epoch. The whole
# measurement is unavailable there and the veto degrades to the old existence
# check - which is safe, and is what the supervisor's comment now says.
arm
client "$GHOST_TTY" "Tue Sep  9 13:17:34 2026" "$GHOST_PID"
run
out5c="$(cat "$T/out")"
if untouched; then ok "5e an old tmux's formatted activity keeps the veto (orphan included)"; else bad "5e an old tmux's formatted activity keeps the veto (orphan included)" "tmux log: $(cat "$TMUX_LOG")"; fi
has "5f and the reason is that it could not be read" "$out5c" "could not be read"

echo "== 6. two clients, one ghost and one human: the human wins =="
arm
client "$GHOST_TTY" "$(( NOW - 7200 ))" "$GHOST_PID"
client "$HUMAN_TTY" "$(( NOW - 9 ))" "$HUMAN_PID"
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
has   "7b the verdict is the bridge path's: no process, confirmed twice, closed by \$N" "$out7" "NO PROCESS confirmed twice"
# WAS: hasnt "nothing is said about clients" ... "attached tmux client". That
# string is only ever built per-client inside `if [ -n "$_clients" ]`, which by
# construction does not run when no client is attached - seven mutations failed
# to make it fail. What this case can really assert is that an empty listing is
# not read as an unreadable one: the deferral at the top of the veto fires when
# `-F` answers nothing while a PLAIN listing answers something, and with nobody
# attached both are empty, so nothing must defer. Dropping that cross-check
# turns this red.
hasnt "7c an empty listing is not read as an unreadable one" "$out7" "deferring the kill"

echo "== 8. the supervisor asks tmux for what it measures =="
arm
client "$HUMAN_TTY" "$(( NOW - 1 ))" "$HUMAN_PID"
run
log8="$(cat "$TMUX_LOG")"
has "8a it asks for the client's activity" "$log8" "client_activity"
has "8b and for the client's pid"          "$log8" "client_pid"
has "8c and for the client's tty"          "$log8" "client_tty"

echo "== 9. a server that will not describe its clients keeps the veto =="
# `list-clients -F` failing outright looks exactly like "nobody is attached",
# and the repair would kill a session the old existence check protected. The
# plain listing is the cross-check.
arm
client "$HUMAN_TTY" "$(( NOW - 3600 ))" "$HUMAN_PID"
T_NO_FORMAT=1 run
out9="$(cat "$T/out")"
if untouched; then ok "9a an unreadable client is treated as a human"; else bad "9a an unreadable client is treated as a human" "tmux log: $(cat "$TMUX_LOG")"; fi
has "9b and the reason is named"   "$out9" "will not describe"
has "9c the plain listing was the cross-check" "$out9" "while a plain listing did"

echo "== 10. THE INCIDENT'S SHAPE: attached AFTER the death, then idle =="
# THE CASE THE ORDERING RULE GOT WRONG, AND THE REASON THIS ROUND EXISTS.
# client_activity is set AT ATTACH (measured, tmux 3.6b). The suspect marker is
# never re-touched while the veto defers. So a ghost that attached three
# minutes after the death has activity NEWER than the marker forever, and the
# ordering rule `activity > marker` defers it FOREVER - with no human anywhere
# and not one keystroke: the two-hour incident, unbounded. Idleness against NOW
# has no such fixed point: two hours of silence is two hours of silence.
arm 7200
client "$GHOST_TTY" "$(( DEATH + 180 ))" "$GHOST_PID"
run
out10="$(cat "$T/out")"
if repaired; then ok "10a a ghost that attached after the death and went quiet IS repaired"; else bad "10a a ghost that attached after the death and went quiet IS repaired" "tmux log: $(cat "$TMUX_LOG")"; fi
has "10b the line names how long it has been silent" "$out10" "past the ${GRACE}s grace"
has "10c and that its activity postdates the death"  "$out10" "after this session was first suspected dead"
has "10d and names the ghost"                        "$out10" "$GHOST_TTY"
# The same client, still attached, but silent for less than the grace: the
# window is a window, not a licence. This is what bounds the cost at 900s.
arm 7200
client "$GHOST_TTY" "$(( NOW - 30 ))" "$GHOST_PID"
run
if untouched; then ok "10e a client active 30s ago still defers, however old the marker"; else bad "10e a client active 30s ago still defers, however old the marker" "tmux log: $(cat "$TMUX_LOG")"; fi

echo "== 11. rows that describe nobody are not a measurement of nothing =="
# A server that ACCEPTS -F and expands every field to empty: one row per
# client, none of them readable. Counting that as "no clients attached" prints
# "every attached client is debris" while naming nobody, and kills.
arm
client "$HUMAN_TTY" "$(( NOW - 30 ))" "$HUMAN_PID"
T_EMPTY_FORMAT=1 run
out11="$(cat "$T/out")"
if untouched; then ok "11a empty rows keep the veto"; else bad "11a empty rows keep the veto" "tmux log: $(cat "$TMUX_LOG")"; fi
has   "11b and the reason is named" "$out11" "could not be read as clients"
hasnt "11c nobody is called debris without being named" "$out11" "every attached client is debris"

echo "== 12. the clock is not evidence =="
# A marker whose mtime is in the FUTURE (NTP correction, VM resume, an
# RTC-less host correcting at boot). Under the ordering rule every client
# sorted older than the marker and every client was debris - including a human
# whose last keypress was one second ago.
arm
set_mtime "$SUSPECT" "$(( NOW + 9999999 ))" || bad "fixture: cannot set a future marker" "set_mtime failed"
client "$HUMAN_TTY" "$(( NOW - 1 ))" "$HUMAN_PID"
run
out12="$(cat "$T/out")"
if untouched; then ok "12a a marker mtime in the future does not kill a live human"; else bad "12a a marker mtime in the future does not kill a live human" "tmux log: $(cat "$TMUX_LOG")"; fi
has "12b and the deferral still names the human" "$out12" "$HUMAN_TTY"
# And a client whose activity is ahead of this host's clock is idle for a
# negative number of seconds. That is not staleness.
arm
client "$HUMAN_TTY" "$(( NOW + 4000 ))" "$HUMAN_PID"
run
if untouched; then ok "12c activity ahead of the clock is not staleness"; else bad "12c activity ahead of the clock is not staleness" "tmux log: $(cat "$TMUX_LOG")"; fi

echo "== 13. the grace's cost, bounded and stated =="
# A human idle LONGER than the window loses the pane. That is the price of the
# window and it is not new - the ordering rule killed them sooner. What IS
# required is that the journal says how long they were silent and against what,
# so the next operator can read the cost instead of inferring it.
arm
client "$HUMAN_TTY" "$(( NOW - 1000 ))" "$HUMAN_PID"
run
out13="$(cat "$T/out")"
if repaired; then ok "13a a human idle past the window loses the pane"; else bad "13a a human idle past the window loses the pane" "tmux log: $(cat "$TMUX_LOG")"; fi
has "13b the log states the window that was applied" "$out13" "past the ${GRACE}s grace"
has "13c and the veto says it measures idleness"     "$out13" "the veto measures IDLENESS"

echo "== 14. an activity value that will not do arithmetic cannot discard a human =="
# THE VETO MUST FAIL CLOSED, AND ARITHMETIC FAILS OPEN. _is_epoch accepts any
# run of digits, and bash reads a leading-zero run as OCTAL: 0888, 08 and 09 are
# invalid octal, and an arithmetic EXPANSION error is fatal to the whole
# `if [ -n "$_clients" ]` compound - the debris print, the deferral AND the
# empty-rows guard are all skipped, and execution resumes at the kill. Measured
# 2026-09-09: a human idle 5s listed FIRST, plus one client whose activity is
# 0888, gave REPAIRED with the human's veto silently discarded and only a bash
# error in the journal. The property is that a value this supervisor cannot
# measure never outranks a human it can - not that the arithmetic is right.
arm
client "$HUMAN_TTY" "$(( NOW - 5 ))" "$HUMAN_PID"
client "$GHOST_TTY" "0888" "$GHOST_PID"
run
out14="$(cat "$T/out")"
if untouched; then ok "14a a live human's veto survives an unarithmetic sibling"; else bad "14a a live human's veto survives an unarithmetic sibling" "tmux log: $(cat "$TMUX_LOG")"; fi
has   "14b the deferral still names the human" "$out14" "$HUMAN_TTY"
hasnt "14c and no arithmetic error escaped to the journal" "$out14" "value too great for base"

echo "== 15. a deferral says how long this has been going on =="
# THE RESIDUAL THE VETO CANNOT GUARD, ANSWERED BY ANNOUNCING IT. A wrapper that
# re-attaches every round produces a genuinely NEW client each time - new pid,
# created == activity == now - which is indistinguishable from a human who just
# attached and has not typed yet, the exact human this veto protects. So the
# veto cannot tell them apart, and a round cap that overrode it would be the
# failure this whole thing exists to prevent. What it CAN do is say how long it
# has been deferring, so an indefinite hang is legible on ONE line instead of
# having to be diffed out of consecutive journal entries. That is what the
# original incident cost: two hours in which nobody knew.
arm 7200
client "$GHOST_TTY" "$(( NOW - 30 ))" "$GHOST_PID"
run
out15="$(cat "$T/out")"
if untouched; then ok "15a the deferral still stands"; else bad "15a the deferral still stands" "tmux log: $(cat "$TMUX_LOG")"; fi
has "15b it says how long this session has been zombie-shaped" "$out15" "ZOMBIE-shaped for "
# THE NUMBER MUST BE THE SESSION'S AGE, NOT THE CLIENT'S IDLENESS. Both are in
# scope on this path and only one of them answers "how long has this been
# hanging". The window is loose because `arm` reads `date +%s` a fraction of a
# second before the supervisor does.
zage="$(printf '%s\n' "$out15" | sed -n 's/.*ZOMBIE-shaped for \([0-9][0-9]*\)s.*/\1/p' | head -1)"
if [ -n "$zage" ] && [ "$zage" -ge 7200 ] && [ "$zage" -le 7260 ]; then
  ok "15c and the number is the session's age, not the client's idleness"
else
  bad "15c and the number is the session's age, not the client's idleness" "wanted 7200..7260, got '${zage:-none}'"
fi

echo "== 16. a host with no systemd --user does not assert a negative it never measured =="
# A container or a non-systemd distro: user_manager_pids answers nothing, every
# ancestry question is unanswerable, and the debris verdict rests on activity
# alone - which is safe in direction. What must not happen is the journal
# saying "it is no orphan of systemd --user", which is a measurement nobody
# took. Until now nothing guarded that: deleting the fallback arm left the
# suite fully green, and so did restoring the false claim verbatim.
PROCTAB_NO_UM="$T/proctab-no-um"
grep -v 'systemd --user' "$PROCTAB" > "$PROCTAB_NO_UM"
arm
client "$HUMAN_TTY" "$(( NOW - 3600 ))" "$HUMAN_PID"
PROCTAB="$PROCTAB_NO_UM" run
out16="$(cat "$T/out")"
if repaired; then ok "16a the repair still proceeds on activity alone"; else bad "16a the repair still proceeds on activity alone" "tmux log: $(cat "$TMUX_LOG")"; fi
has   "16b the line says ancestry was not measured" "$out16" "ancestry was not measured"
hasnt "16c and claims no negative it never measured" "$out16" "no orphan"
hasnt "16d nor that the system called it a left-over" "$out16" "left-over process"

echo "== 17. every deferral says the client is ATTACHED, in that word =="
# THE WORD IS PART OF THE INTERFACE. Naming the client concretely - tty, pid,
# how long it has been silent - is what the two-hour incident lacked, and this
# round added it. What it must not do is spend the word to buy the detail: an
# operator looking at a session that will not repair itself greps the journal
# for "attached", and an estate's supervision suite asserts exactly that on the
# deferral's stderr. Losing it cost one red suite in the estate on 2026-09-09,
# two repositories from where the wording changed. So both properties are
# pinned together below: the word AND the concrete naming, on every one of the
# three paths that can defer.
#
# WHY THE HEADLINE AND NOT THE WHOLE STDERR: the debris line ("attached tmux
# client X is not a working human") carries the word too, so a whole-output
# match would stay green for a deferral that never says it. The headline is the
# line that announces the deferral - "ZOMBIE-shaped, ..." with the comma. The
# repair path's "ZOMBIE PANE" verdict and the deferral's own age line ("it has
# been ZOMBIE-shaped for Ns") are not headlines and are not matched.
defer_headlines() { printf '%s\n' "$1" | grep -- 'ZOMBIE-shaped,'; }
# Either case satisfies a reader and satisfies the estate; the case is not the
# property, the word is.
says_attached() {
  if [ -z "$2" ]; then bad "$1" "no deferral headline at all"; return; fi
  case "$(printf '%s' "$2" | tr 'A-Z' 'a-z')" in
    *attached*) ok "$1" ;;
    *) bad "$1" "the deferral never says the client is attached: $2" ;;
  esac
}

# (a) THE ORDINARY DEFERRAL: a live human inside the grace.
arm
client "$HUMAN_TTY" "$(( NOW - 60 ))" "$HUMAN_PID"
run
out17="$(cat "$T/out")"
if untouched; then ok "17a a live human still defers"; else bad "17a a live human still defers" "tmux log: $(cat "$TMUX_LOG")"; fi
says_attached "17b and the deferral says the client is attached" "$(defer_headlines "$out17")"
has "17c and the concrete naming survives beside the word" "$(defer_headlines "$out17")" "$HUMAN_TTY"
has "17d including the pid"                                "$(defer_headlines "$out17")" "$HUMAN_PID"

# (b) THE SERVER THAT WILL NOT DESCRIBE ITS CLIENTS (claim 9's path).
arm
client "$HUMAN_TTY" "$(( NOW - 3600 ))" "$HUMAN_PID"
T_NO_FORMAT=1 run
out17b="$(cat "$T/out")"
if untouched; then ok "17e an undescribable client still defers"; else bad "17e an undescribable client still defers" "tmux log: $(cat "$TMUX_LOG")"; fi
says_attached "17f and that deferral says it too" "$(defer_headlines "$out17b")"

# (c) THE SERVER THAT ANSWERS ROWS DESCRIBING NOBODY (claim 11's path).
arm
client "$HUMAN_TTY" "$(( NOW - 30 ))" "$HUMAN_PID"
T_EMPTY_FORMAT=1 run
out17c="$(cat "$T/out")"
if untouched; then ok "17g unreadable rows still defer"; else bad "17g unreadable rows still defer" "tmux log: $(cat "$TMUX_LOG")"; fi
says_attached "17h and that deferral says it as well" "$(defer_headlines "$out17c")"

echo "pass=$pass fail=$fail"
[ "$fail" -eq 0 ]
