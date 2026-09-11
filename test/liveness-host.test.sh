#!/bin/bash
# test/liveness-host.test.sh — the HOST-SIDE liveness answerer.
#
# WHY IT EXISTS. The liveness seam joins one measurement map into the session
# list, and until now the only thing that could produce that map was a shim
# reading the LOCAL machine: local daemons, the local tmux server. On a fleet
# whose sessions mostly live on other machines that is honest and nearly
# useless — measured on one estate, six of twenty-one rows carried a real
# measurement and fifteen read `unknown` / `not-in-answer`. The fifteen were
# not unmeasurable; nobody had asked the machine they live on.
#
# This is that machine's answer: run in a home, it reports the rows of the
# registry that live on THIS host and belong to THE INVOKING UNIX ACCOUNT, in
# the same contract shape the seam already parses.
#
# THE KEY IS THE ID, NEVER THE SLUG. A row's key is its conf basename. The slug
# is a human handle: mutable, account-scoped, and allowed to collide between
# people. A flat measurement map keyed on a slug can pin a stale status onto the
# WRONG session, and the fixture below therefore gives every row a slug that
# differs from its id — a fixture where they are equal cannot tell a correct
# lookup from a broken one.
#
# IT ANSWERS ONLY FOR ITS OWN ACCOUNT, and not because of caution. Homes are
# 750: this account cannot read the neighbour's tmux server, their timers, or
# their process tree. A row about them would be a guess wearing the clothes of a
# measurement, so their rows leave the answer entirely — neither measured nor
# excused.
#
# A PROBE THAT CANNOT BE MADE IS NAMED, NEVER GUESSED. `omitted[id] = reason`
# carries the sentence; the row never appears in `sessions` with an invented
# state. "Cannot reach" and "is down" are different facts and the whole model
# exists to keep them apart.
set -u
here="$(CDPATH= cd -- "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CMD="$here/linux/liveness-host.sh"
pass=0; fail=0
ok()  { pass=$((pass+1)); printf '  ok   %s\n' "$1"; }
bad() { fail=$((fail+1)); printf '  FAIL %s\n     %s\n' "$1" "${2:-}"; }
eq()  { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "wanted '$3', got '$2'"; fi; }

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
mkdir -p "$T/sessions.d" "$T/estate" "$T/bin" "$T/home/.tmux"

cat > "$T/estate/steward.conf" <<'EOF'
LABEL_PREFIX="com.acme.agent"
RC_LABEL_PREFIX="Acme: "
HUB_SESSION="acmehub"
HUB_HOST="h0"
STATE_DIR_NAME="acme-supervisor"
PAUSED_DIR_NAME="acme-paused"
JOB_LOG_DIR="acme-jobs"
TMUX_SOCKET="acme.sock"
EOF

# A SECOND ESTATE THAT NAMES NO STATE DIRECTORY. Everything else is identical,
# so exactly one fact differs between the two runs. A codex row's thread and
# ledger live under that directory, so an estate that does not name it makes the
# row UNMEASURABLE - and the answerer must say so rather than probe a path with
# a hole where the name should be.
mkdir -p "$T/nameless/estate"
grep -v '^STATE_DIR_NAME=' "$T/estate/steward.conf" > "$T/nameless/estate/steward.conf"
# A REAL UNIX SOCKET, not an empty file. Every socket probe in the answerer
# tests for a socket (-S), and a fixture that put a regular file there would
# prove only that a path exists - the exact confusion those checks exist to
# prevent.
#
# BOUND FROM INSIDE ITS OWN DIRECTORY, BY THE RELATIVE NAME. The kernel caps a
# unix socket path near a hundred characters, and the temporary root plus the
# runtime's default control path below is already past that cap on this host.
# Binding by basename keeps the fixture working wherever mktemp puts it.
mk_sock() { # mk_sock <path>
  local d b
  d="$(dirname "$1")"; b="$(basename "$1")"
  mkdir -p "$d"
  if ! ( cd "$d" && python3 - "$b" <<'PY' 2>/dev/null
import socket, sys
s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM); s.bind(sys.argv[1])
PY
  ); then
    echo "  FAIL could not create a unix socket for the fixture: $1 (python3?)" >&2
    exit 1
  fi
}

# THE DECLARED SOCKET MUST EXIST for it to be used - an estate file may name a
# socket its machinery never created, and asking a server that is not there
# would report a healthy home as dead.
mk_sock "$T/home/.tmux/acme.sock"

# Four rows for alice on h1, each exercising a different combination, plus two
# rows that must not be answered for at all.
mk() { # mk <id> <owner> <host> <slug> [extra lines...]
  local id="$1" owner="$2" host="$3" slug="$4"; shift 4
  { printf 'ID="%s"\nOWNER="%s"\nHOST="%s"\nSLUG="%s"\nDOMAIN="acme"\nRC_LABEL="Acme %s"\n' \
      "$id" "$owner" "$host" "$slug" "$slug"
    for l in "$@"; do printf '%s\n' "$l"; done
  } > "$T/sessions.d/$id.conf"
}
# timer active, tmux up, a runtime descending from the pane
mk s-a1 alice h1 handle-one
# NO TIMER: supervision is not armed for this row. That is a MEASUREMENT
# (missing), not an unmeasurable row.
mk s-b2 alice h1 handle-two
# timer active, but no tmux session on the declared socket
mk s-c3 alice h1 handle-three
# tmux up, but nothing that looks like a runtime descends from its pane
mk s-d4 alice h1 handle-four 'RUNTIME="opencode"' 'MODEL="acme/model-x"'
# NOT THIS ACCOUNT'S. Homes are 750; this row is unreadable from here and is
# not ours to report.
mk s-e5 bob   h1 handle-five
# NOT THIS HOST. Another machine answers for it.
mk s-f6 alice h2 handle-six

# FIVE CODEX ROWS. A codex row is a thread, not a pane: it is supervised by
# its own timer, it has no tmux session by design, and whether it can work is
# decided by the owner's daemon socket and by having a thread to speak into.
# The three probes written for a pane row answer three different wrong
# questions about it, so each of these rows pins one of the answers.
# timer armed, a thread on disk, a ledger of answered letters, daemon socket up
mk s-g7 alice h1 handle-seven 'RUNTIME="codex"'
# NOTHING: no timer, no thread, no ledger. Every field must still be measured.
mk s-h8 alice h1 handle-eight 'RUNTIME="codex"'
# timer armed and a thread on disk, but the owner's daemon is not listening.
mk s-i9 alice h1 handle-nine  'RUNTIME="codex"'
# THE PRODUCTION DEFAULTS, with no override set anywhere. Run with neither
# the socket knob nor the runtime home set, this row is measured at the two
# paths the adapter itself writes to. Nothing else pins those literals, so a
# rename on either side would otherwise pass every test and report a whole
# fleet of healthy rows as not-running.
mk s-j0 alice h1 handle-ten   'RUNTIME="codex"'
# A ZERO-BYTE THREAD FILE: the file was created and nothing was ever written to
# it, which is not a thread to speak into. This is the row that distinguishes
# "exists" from "has content".
mk s-k1 alice h1 handle-eleven 'RUNTIME="codex"'

# THE CODEX RUNTIME'S OWN STATE DIRECTORY, named by the adapter's existing
# production knob. No test-only door is opened in the answerer for this.
CX="$T/codex-state"
mkdir -p "$CX"
# A KNOWN MTIME, because lastActivity is asserted literally below. `touch -d @N`
# is GNU; the BSD form takes a local wall clock, which `date -r N` prints for
# the same instant, so both hosts stamp the same file.
touch_at() { # touch_at <epoch> <file>
  touch -d "@$1" "$2" 2>/dev/null && return 0
  touch -t "$(date -r "$1" +%Y%m%d%H%M.%S)" "$2"
}
printf 'thread-g7\n' > "$CX/s-g7.codex-thread"
printf 'letter-one\n' > "$CX/s-g7.codex-answered"
# The thread file is OLDER than the ledger on purpose: the newest of the two is
# the answer, and a fixture where both are equal cannot tell a max from a pick.
touch_at 1756540800 "$CX/s-g7.codex-thread"
touch_at 1756542000 "$CX/s-g7.codex-answered"
printf 'thread-i9\n' > "$CX/s-i9.codex-thread"
# CREATED AND EMPTY. A file that exists is not a thread; only content is.
: > "$CX/s-k1.codex-thread"

# THE OWNER'S DAEMON CONTROL SOCKET, at the knob the adapter reads.
mk_sock "$T/codex-daemon.sock"

# THE TWO PRODUCTION DEFAULTS, for the one run that sets no knob at all: the
# control socket under the runtime home, and the state directory named by the
# estate under the home's state tree. Both are written here EXACTLY as the
# adapter spells them, because that is the whole value of the run below.
mkdir -p "$T/home/.local/state/acme-supervisor"
printf 'thread-j0\n' > "$T/home/.local/state/acme-supervisor/s-j0.codex-thread"
mk_sock "$T/home/.codex/app-server-control/app-server-control.sock"

# ── stubs ────────────────────────────────────────────────────────────────────
# systemd: only s-a1, s-c3 and s-d4 have an armed timer.
#
# THE INSTANCE IS SPLIT OFF THE UNIT NAME rather than matched whole. A literal
# `agent-session@<id>.timer` in this file reads to a text sweep exactly like an
# address — local part, at sign, dotted domain — and a guard that must not be
# taught exceptions is worth more than a shorter case arm.
cat > "$T/bin/systemctl" <<'EOF'
#!/bin/bash
for a in "$@"; do
  case "$a" in
    agent-session@*)
      inst="${a#*@}"; inst="${inst%.timer}"
      case "$inst" in s-a1|s-c3|s-d4) exit 0 ;; esac ;;
    agent-codex@*)
      inst="${a#*@}"; inst="${inst%.timer}"
      case "$inst" in s-g7|s-i9|s-j0|s-k1) exit 0 ;; esac ;;
  esac
done
exit 3
EOF

# tmux on the declared socket: s-a1, s-b2 and s-d4 are live. s-c3 is not.
# `session_activity` is epoch seconds, which is where lastActivity comes from.
#
# s-g7 IS LISTED TOO, AND IT IS A CODEX ROW. A stub that never named a codex
# session could not tell a branch that skips the pane walk from a branch that
# reached it and found nothing - the proof further down would pass against the
# code that had the fault. Listing it, and giving it a pane, makes the two
# claims real: no list-panes call may target it, and its lastActivity must be
# its own ledger's stamp rather than the one tmux is offering here.
cat > "$T/bin/tmux" <<'EOF'
#!/bin/bash
echo "$@" >> "${TMUX_LOG:?}"
mode=""; target=""
for a in "$@"; do
  case "$a" in
    list-sessions|list-panes) mode="$a" ;;
    =*) target="${a#=}" ;;
  esac
done
case "$mode" in
  list-sessions)
    printf 's-a1 1756540800\ns-b2 1756540900\ns-d4 1756541000\ns-g7 1756541100\n' ;;
  list-panes)
    case "$target" in
      s-a1) echo 100 ;;
      s-b2) echo 200 ;;
      s-d4) echo 400 ;;
      s-g7) echo 700 ;;
      *) exit 1 ;;
    esac ;;
  *) exit 0 ;;
esac
EOF

# pgrep: three processes look like a runtime. 999 belongs to no pane of ours.
cat > "$T/bin/pgrep" <<'EOF'
#!/bin/bash
printf '101\n201\n999\n'
EOF

# ps -o ppid= -p <pid>: the parent map the ancestry walk climbs.
cat > "$T/bin/ps" <<'EOF'
#!/bin/bash
pid=""; want=""
for a in "$@"; do
  if [ "$want" = 1 ]; then pid="$a"; want=0; continue; fi
  case "$a" in -p) want=1 ;; esac
done
case "$pid" in
  101) echo 100 ;;  201) echo 200 ;;  999) echo 1 ;;
  100|200|400|700) echo 50 ;;
  50) echo 1 ;;
  *) exit 1 ;;
esac
EOF
# THE BRIDGE OBSERVER STUB (plan Task 8): a claude row's agent is the adapter's answer. Per id a line
# in $T/obs/<id>; absent -> unknown. Every call and its environment are logged.
mkdir -p "$T/obs"
cat > "$T/bin/bridge-observe" <<'EOF'
printf '%s|%s|%s\n' "$1" "${STEWARD_STATE_DIR:-}" "${STEWARD_TMUX_SOCKET:-}" >> "${OBS_LOG:?}"
if [ -f "$OBS_DIR/$1" ]; then cat "$OBS_DIR/$1"; else printf '%s\037unknown\037\037\037\037\037\037none\037unclassifiable\037\037\037\037\037\037\n' "$1"; fi
EOF
obs() { # obs <id> <answer> [gen] [classes] - writes the fifteen-field line for <id>
  local pid="" birth="" pane="" ps="" since="" sid="" mt="" ino=""
  case "$2" in identified:*) pid=101; birth=boot-l:1; pane="$1:@0.%0"; ps=101; since=1; sid=t; mt=1; ino=777 ;; esac
  printf '%s\037%s\037%s\037%s\037%s\037%s\037%s\037%s\037%s\037\037%s\037%s\037%s\037\037%s\n' "$1" "$2" "$pid" "$birth" "$pane" "n" "$since" "${3:-none}" "${4:-}" "$ps" "$sid" "$mt" "$ino" > "$T/obs/$1"
}
obs s-a1 identified:managed alive live:managed
obs s-b2 identified:managed alive live:managed
obs s-c3 no-process gone-noreceipt
chmod +x "$T/bin/systemctl" "$T/bin/tmux" "$T/bin/pgrep" "$T/bin/ps" "$T/bin/bridge-observe"

run() { # run [extra PATH dir first] -> stdout of the answerer
  env -i HOME="$T/home" PATH="$T/bin:/usr/bin:/bin" \
    STEWARD_ESTATE_ROOT="$T" STEWARD_REGISTRY_DIR="$T/sessions.d" \
    STEWARD_SELF_HOST="h1" STEWARD_SELF_USER="alice" \
    STEWARD_CODEX_STATE_DIR="$CX" \
    STEWARD_CODEX_DAEMON_SOCK="$T/codex-daemon.sock" \
    TMUX_LOG="$T/tmuxlog" OBS_LOG="$T/obslog" OBS_DIR="$T/obs" STEWARD_BRIDGE_OBSERVE="$T/bin/bridge-observe" \
    bash "$CMD" 2>"$T/err"
}

: > "$T/tmuxlog"
out="$(run)"; rc=$?

echo "== the contract shape =="
eq "the answerer succeeds" "$rc" "0"
eq "the answer is JSON with a sessions object" \
   "$(printf '%s' "$out" | jq -r '.sessions | type')" "object"
eq "and an omitted object" \
   "$(printf '%s' "$out" | jq -r '.omitted | type')" "object"

echo "== the keys are IDs, never slugs =="
eq "the id is a key" \
   "$(printf '%s' "$out" | jq -r '.sessions | has("s-a1")')" "true"
eq "the slug is NOT a key" \
   "$(printf '%s' "$out" | jq -r '[.sessions,.omitted] | map(keys[]) | flatten
                                  | map(select(startswith("handle-"))) | length')" "0"

echo "== timer armed, tmux up, a runtime under the pane =="
eq "daemon is loaded"   "$(printf '%s' "$out" | jq -r '.sessions["s-a1"].daemon')"  "loaded"
eq "tmux is up"         "$(printf '%s' "$out" | jq -r '.sessions["s-a1"].tmux')"    "up"
eq "agent is running"   "$(printf '%s' "$out" | jq -r '.sessions["s-a1"].agent')"   "running"
# A ROW WITH NO RUNTIME LINE IS A CLAUDE ROW — every conf that predates the
# field is one, and calling them unknown would make a healthy home look unmeasured.
eq "runtime defaults"   "$(printf '%s' "$out" | jq -r '.sessions["s-a1"].runtime')" "claude-code"
# NULL IS A MEASUREMENT ("no value"), an absent key is an unmeasured field. The
# seam keeps them apart, so the answerer must too.
eq "model has a key"    "$(printf '%s' "$out" | jq -r '.sessions["s-a1"] | has("model")')" "true"
eq "and its value is null, not a guess" \
   "$(printf '%s' "$out" | jq -r '.sessions["s-a1"].model')" "null"
eq "lastActivity has a key" \
   "$(printf '%s' "$out" | jq -r '.sessions["s-a1"] | has("lastActivity")')" "true"
eq "and it reads as a timestamp" \
   "$(printf '%s' "$out" | jq -r '.sessions["s-a1"].lastActivity
                                  | test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T")')" "true"

echo "== a claude row's agent is the bridge adapter's answer, asked with the estate's state dir and socket =="
eq "s-a1 was asked about" "$(grep -c '^s-a1|' "$T/obslog")" "1"
eq "with STEWARD_STATE_DIR under the estate's state directory name" "$(grep '^s-a1|' "$T/obslog" | cut -d'|' -f2)" "$T/home/.local/state/acme-supervisor"
eq "and the declared socket" "$(grep '^s-a1|' "$T/obslog" | cut -d'|' -f3)" "$T/home/.tmux/acme.sock"
eq "the OpenCode row is never asked (the pane walk is its measure)" "$(grep -c '^s-d4|' "$T/obslog")" "0"
eq "nor the codex rows" "$(grep -c '^s-g7|' "$T/obslog")" "0"
eq "a managed row has no reason key" "$(printf '%s' "$out" | jq -r '.sessions["s-a1"] | has("reason")')" "false"

echo "== a session with no timer: missing, and still measured otherwise =="
eq "daemon is missing"  "$(printf '%s' "$out" | jq -r '.sessions["s-b2"].daemon')" "missing"
eq "tmux is still up"   "$(printf '%s' "$out" | jq -r '.sessions["s-b2"].tmux')"   "up"
eq "agent is still running" "$(printf '%s' "$out" | jq -r '.sessions["s-b2"].agent')" "running"
eq "it is not omitted"  "$(printf '%s' "$out" | jq -r '.omitted | has("s-b2")')"   "false"

echo "== a timer with no tmux: down, and no runtime can descend from nothing =="
eq "daemon is loaded"   "$(printf '%s' "$out" | jq -r '.sessions["s-c3"].daemon')" "loaded"
eq "tmux is down"       "$(printf '%s' "$out" | jq -r '.sessions["s-c3"].tmux')"   "down"
eq "agent is not-running" "$(printf '%s' "$out" | jq -r '.sessions["s-c3"].agent')" "not-running"
# A SESSION THAT IS NOT UP HAS NO ACTIVITY TO REPORT — null, not a stale stamp.
eq "lastActivity is null" "$(printf '%s' "$out" | jq -r '.sessions["s-c3"].lastActivity')" "null"

echo "== a tmux with no runtime process under its pane =="
eq "tmux is up"         "$(printf '%s' "$out" | jq -r '.sessions["s-d4"].tmux')"   "up"
# 999 matches the runtime pattern but descends from no pane of this session.
# Counting it would be the oldest mistake in this family: measuring something
# ADJACENT (does a matching process exist?) instead of the question asked (is
# MY runtime running, tied to MY tmux?).
eq "agent is not-running" "$(printf '%s' "$out" | jq -r '.sessions["s-d4"].agent')" "not-running"
eq "the declared runtime is reported" \
   "$(printf '%s' "$out" | jq -r '.sessions["s-d4"].runtime')" "opencode"
eq "and its model"      "$(printf '%s' "$out" | jq -r '.sessions["s-d4"].model')"  "acme/model-x"

echo "== the adapter decides for a claude row: the pane walk no longer does =="
: > "$T/tmuxlog"; : > "$T/obslog"
obs s-a1 unknown alive "live:managed live:managed"          # a runtime under s-a1's pane (pid 101) - and the adapter says split-brain
obs s-b2 identified:moved alive live:moved
obs s-c3 identified:managed alive live:managed              # tmux DOWN for s-c3, yet the adapter says managed (it measured; we report it)
out2="$(run)"
eq "s-a1: a runtime under the pane, adapter unknown -> agent unknown, not running" "$(printf '%s' "$out2" | jq -r '.sessions["s-a1"].agent')" "unknown"
eq "s-a1: the reason is the adapter's answer with its classes" "$(printf '%s' "$out2" | jq -r '.sessions["s-a1"].reason')" "bridge: unknown (live:managed live:managed), generation alive"
eq "s-a1: tmux is still measured independently (up)" "$(printf '%s' "$out2" | jq -r '.sessions["s-a1"].tmux')" "up"
eq "s-b2: moved is unknown with its reason" "$(printf '%s' "$out2" | jq -r '.sessions["s-b2"].reason')" "bridge: identified:moved (live:moved), generation alive"
eq "s-c3: the adapter's managed is running even with tmux down (two measurements, both reported)" "$(printf '%s' "$out2" | jq -r '.sessions["s-c3"].agent')" "running"
eq "s-d4 (OpenCode) is unchanged: not-running by the pane walk" "$(printf '%s' "$out2" | jq -r '.sessions["s-d4"].agent')" "not-running"
rm -f "$T/obs/s-a1"; out3="$(run)"
eq "no line for a claude row -> the stub's unknown -> agent unknown" "$(printf '%s' "$out3" | jq -r '.sessions["s-a1"].agent')" "unknown"
printf 's-a1\037no-process\037\037\037\037\037\037none\037\037\037\037\037\037\n' > "$T/obs/s-a1"; out4="$(run)"
eq "a fourteen-field line is not the contract -> unknown" "$(printf '%s' "$out4" | jq -r '.sessions["s-a1"].agent')" "unknown"
eq "and says so" "$(printf '%s' "$out4" | jq -r '.sessions["s-a1"].reason')" "cannot observe: the observer's line has 14 fields, not fifteen"
printf 's-zz\037no-process\037\037\037\037\037\037none\037\037\037\037\037\037\037\n' > "$T/obs/s-a1"; out5="$(run)"
eq "a line about another id -> unknown" "$(printf '%s' "$out5" | jq -r '.sessions["s-a1"].reason')" "cannot observe: the observer answered about 's-zz'"
# L1: the same contract the supervisor holds the line to - a malformed answer is unknown, never a verdict
printf 's-a1\037no-process\037\037\037\037\037\037alive\037\037\037\037\037\037\037\n' > "$T/obs/s-a1"; outL1="$(run)"
eq "L1: no-process beside gen_state=alive is unknown, not not-running" "$(printf '%s' "$outL1" | jq -r '.sessions["s-a1"].agent')" "unknown"
eq "L1: with the contract named" "$(printf '%s' "$outL1" | jq -r '.sessions["s-a1"].reason | test("breaks the contract")')" "true"
printf 's-a1\037identified:managed\037101\037boot-l:1\037s-zz:@0.%%0\037n\0371\037alive\037live:managed\037\037101\037t\0371\037$7:1\037777\n' > "$T/obs/s-a1"; outL1b="$(run)"
eq "L1: identified with a FOREIGN pane is unknown, not running" "$(printf '%s' "$outL1b" | jq -r '.sessions["s-a1"].agent')" "unknown"
printf 's-a1\037identified:managed\037101\037boot-l:1\037s-a1:@0.%%0\037n\0371\037alive\037live:managed\037\037\037t\0371\037$7:1\037777\n' > "$T/obs/s-a1"; outL1c="$(run)"
eq "L1: identified with an EMPTY procStart is unknown, not running" "$(printf '%s' "$outL1c" | jq -r '.sessions["s-a1"].agent')" "unknown"
obs s-a1 identified:managed alive live:managed; obs s-b2 identified:managed alive live:managed; obs s-c3 no-process gone-noreceipt
out6="$(env -i HOME="$T/home" PATH="$T/bin:/usr/bin:/bin" STEWARD_ESTATE_ROOT="$T" STEWARD_REGISTRY_DIR="$T/sessions.d" STEWARD_SELF_HOST="h1" STEWARD_SELF_USER="alice" STEWARD_CODEX_STATE_DIR="$CX" STEWARD_CODEX_DAEMON_SOCK="$T/codex-daemon.sock" TMUX_LOG="$T/tmuxlog" OBS_LOG="$T/obslog" OBS_DIR="$T/obs" STEWARD_BRIDGE_OBSERVE="$T/no-such-observer" bash "$CMD" 2>/dev/null)"
eq "a missing observer is unknown with its reason, never running" "$(printf '%s' "$out6" | jq -r '.sessions["s-a1"].agent')" "unknown"
eq "and names the path" "$(printf '%s' "$out6" | jq -r '.sessions["s-a1"].reason | test("bridge observer is missing")')" "true"
eq "while the OpenCode row is untouched by that" "$(printf '%s' "$out6" | jq -r '.sessions["s-d4"].agent')" "not-running"
: > "$T/tmuxlog"; out="$(run)"

echo "== a codex row is measured by its own machinery =="
# Measured on a session host: a healthy codex row - timer active, the owner's
# daemon up, a thread id on disk, the last letter answered hours before - was
# rendered not-running with no activity at all. The page was right; all three
# probes had answered a question this row was never asked.
eq "the timer that actually supervises it is the one asked" \
   "$(printf '%s' "$out" | jq -r '.sessions["s-g7"].daemon')" "loaded"
# NOT `down`. `down` is the sentence "we looked for a pane and there was none".
# A codex row owns no tmux session by design, so nobody looked.
eq "tmux does not apply to this row" \
   "$(printf '%s' "$out" | jq -r '.sessions["s-g7"].tmux')" "n/a"
eq "agent is running: daemon socket up and a thread to speak into" \
   "$(printf '%s' "$out" | jq -r '.sessions["s-g7"].agent')" "running"
eq "the declared runtime is reported" \
   "$(printf '%s' "$out" | jq -r '.sessions["s-g7"].runtime')" "codex"
# THE NEWEST OF THE TWO FILES THIS RUNTIME WRITES. The ledger of answered
# letters is younger than the thread file in the fixture, so a reader that
# picked one instead of the maximum would read the older stamp.
eq "lastActivity is the newest of ledger and thread" \
   "$(printf '%s' "$out" | jq -r '.sessions["s-g7"].lastActivity')" \
   "2025-08-30T08:20:00.000Z"

echo "== a codex row with no timer, no thread and no ledger =="
eq "daemon is missing"  "$(printf '%s' "$out" | jq -r '.sessions["s-h8"].daemon')" "missing"
eq "tmux still does not apply" \
   "$(printf '%s' "$out" | jq -r '.sessions["s-h8"].tmux')" "n/a"
eq "agent is not-running" "$(printf '%s' "$out" | jq -r '.sessions["s-h8"].agent')" "not-running"
# NEVER RAN IS NOT A TIMESTAMP. null is a measurement; a stale stamp would be a
# guess wearing a measurement's clothes.
eq "lastActivity is null" \
   "$(printf '%s' "$out" | jq -r '.sessions["s-h8"].lastActivity')" "null"

echo "== a codex row cannot work while the owner's daemon is not listening =="
# Supervision is armed and the thread exists; only the socket is gone. The two
# facts are separate and the answer must keep them separate.
out4="$( env -i HOME="$T/home" PATH="$T/bin:/usr/bin:/bin" \
          STEWARD_ESTATE_ROOT="$T" STEWARD_REGISTRY_DIR="$T/sessions.d" \
          STEWARD_SELF_HOST="h1" STEWARD_SELF_USER="alice" \
          STEWARD_CODEX_STATE_DIR="$CX" \
          STEWARD_CODEX_DAEMON_SOCK="$T/no-such-daemon.sock" \
          TMUX_LOG="$T/tmuxlog4" OBS_LOG="$T/obslog" OBS_DIR="$T/obs" STEWARD_BRIDGE_OBSERVE="$T/bin/bridge-observe" bash "$CMD" 2>/dev/null )"
eq "daemon is still loaded"  "$(printf '%s' "$out4" | jq -r '.sessions["s-i9"].daemon')" "loaded"
eq "but the agent is not-running" \
   "$(printf '%s' "$out4" | jq -r '.sessions["s-i9"].agent')" "not-running"

echo "== a thread file that exists but is empty is not a thread =="
# The file was created and nothing was ever written into it. Existence is not
# the question; content is - and the two are one character apart in the probe.
eq "daemon is loaded"   "$(printf '%s' "$out" | jq -r '.sessions["s-k1"].daemon')" "loaded"
eq "agent is not-running" "$(printf '%s' "$out" | jq -r '.sessions["s-k1"].agent')" "not-running"

echo "== no pane is ever walked for a codex row =="
# The pane walk is the third wrong question. A row with no tmux session must
# not be asked which runtime descends from panes it does not have - and the
# stub above OFFERS s-g7 a live tmux session with a pane, so this claim now
# fails against code that lets a codex row fall into the pane branch.
eq "list-panes never targets a codex id" \
   "$(grep -cE 'list-panes.*=s-(g7|h8|i9|j0|k1)' "$T/tmuxlog" | tr -d ' ')" "0"
# NOR IS TMUX'S ACTIVITY STAMP BORROWED. tmux is offering 1756541100 for s-g7;
# the row's own ledger says 1756542000, and the row is measured by its own
# machinery or it is not measured by machinery that fits it.
eq "lastActivity is the ledger's, never the tmux server's" \
   "$(printf '%s' "$out" | jq -r '.sessions["s-g7"].lastActivity')" \
   "2025-08-30T08:20:00.000Z"

echo "== the production default paths, with no knob set anywhere =="
# NEITHER OVERRIDE IS SET here: no daemon socket knob, no runtime home, no
# state directory knob. The socket is found at the runtime home's default
# control path and the thread under the state directory the estate names. These
# two literals live in the adapter; nothing else in this suite pins them, so a
# rename on either side would report a fleet of healthy rows as not-running and
# every other case here would stay green.
out5="$( env -i HOME="$T/home" PATH="$T/bin:/usr/bin:/bin" \
          STEWARD_ESTATE_ROOT="$T" STEWARD_REGISTRY_DIR="$T/sessions.d" \
          STEWARD_SELF_HOST="h1" STEWARD_SELF_USER="alice" \
          TMUX_LOG="$T/tmuxlog5" OBS_LOG="$T/obslog" OBS_DIR="$T/obs" STEWARD_BRIDGE_OBSERVE="$T/bin/bridge-observe" bash "$CMD" 2>/dev/null )"
eq "the daemon socket is found at the runtime home's default path" \
   "$(printf '%s' "$out5" | jq -r '.sessions["s-j0"].agent')" "running"

echo "== an estate that names no state directory makes a codex row unmeasurable =="
# The thread and the ledger live under a directory the ESTATE names. With no
# name there is no directory, and a path built around the hole would be probed,
# found absent, and written into `sessions` as not-running - a guess wearing a
# measurement's clothes, which is the one thing this file promises never to do.
# The row is omitted with the sentence instead.
out6="$( env -i HOME="$T/home" PATH="$T/bin:/usr/bin:/bin" \
          STEWARD_ESTATE_ROOT="$T/nameless" STEWARD_REGISTRY_DIR="$T/sessions.d" \
          STEWARD_SELF_HOST="h1" STEWARD_SELF_USER="alice" \
          TMUX_LOG="$T/tmuxlog6" OBS_LOG="$T/obslog" OBS_DIR="$T/obs" STEWARD_BRIDGE_OBSERVE="$T/bin/bridge-observe" bash "$CMD" 2>/dev/null )"
eq "the codex row is not measured" \
   "$(printf '%s' "$out6" | jq -r '.sessions | has("s-g7")')" "false"
eq "it is omitted with the reason, named" \
   "$(printf '%s' "$out6" | jq -r '.omitted["s-g7"]')" \
   "cannot probe on h1: the estate does not name a state directory"
eq "every codex row is omitted" \
   "$(printf '%s' "$out6" | jq -r '.omitted | length')" "5"
# THE PANE ROWS ARE UNTOUCHED. A missing state directory name says nothing
# about a row measured by tmux and a process tree, and an omission that spread
# past its own cause would hide four healthy rows.
eq "the pane rows are still measured" \
   "$(printf '%s' "$out6" | jq -r '.sessions | length')" "4"
eq "and measured as before" \
   "$(printf '%s' "$out6" | jq -r '.sessions["s-a1"].tmux')" "up"

echo "== another account's row leaves the answer entirely =="
eq "it is not measured" "$(printf '%s' "$out" | jq -r '.sessions | has("s-e5")')" "false"
# NOT EVEN AS AN OMISSION. An omitted entry says "I tried and could not"; this
# account never had standing to try, and saying so in a measurement map would
# invite a reader to believe the row is broken rather than somebody else's.
eq "and not excused either" "$(printf '%s' "$out" | jq -r '.omitted | has("s-e5")')" "false"

echo "== another host's row leaves the answer entirely =="
eq "it is not measured" "$(printf '%s' "$out" | jq -r '.sessions | has("s-f6")')" "false"
eq "and not excused either" "$(printf '%s' "$out" | jq -r '.omitted | has("s-f6")')" "false"

echo "== exactly nine rows are answered for =="
eq "nine measured rows" "$(printf '%s' "$out" | jq -r '.sessions | length')" "9"

echo "== the tmux probe asks the DECLARED socket, not the default one =="
# Measured on a live fleet: a bare `tmux ls` asks the default socket while every
# supervised session lives on the estate's declared one, so seven demonstrably
# live sessions read "down" — a false alarm in the one column a human acts on.
eq "the socket path is on the command line" \
   "$(grep -c -- "-S $T/home/.tmux/acme.sock" "$T/tmuxlog" | tr -d ' ' | { read -r n; [ "$n" -gt 0 ] && echo yes || echo no; })" "yes"
echo "== and it targets sessions exactly, never by prefix =="
# tmux -t prefix-matches; a session whose name prefixes a sibling's would
# otherwise borrow the sibling's answer.
eq "list-panes uses the =name form" \
   "$(grep -c 'list-panes.*=s-' "$T/tmuxlog" | tr -d ' ' | { read -r n; [ "$n" -gt 0 ] && echo yes || echo no; })" "yes"

echo "== a probe that cannot be made is NAMED, never invented =="
# systemctl absent: supervision state is unknowable here. The rows must not
# appear in `sessions` wearing a guessed daemon word.
#
# THE DIRECTORY MUST BE THE WHOLE PATH, NOT A PREFIX OF IT. `PATH="$T/bin2:/usr/bin:/bin"`
# does not remove systemctl on a machine that HAS one - Linux keeps it in
# /usr/bin, the shim finds it there, and the three claims below then measure a
# host where nothing is missing. Green on a mac, red on every Linux host, for a
# reason that has nothing to do with the product: measured 2026-09-09, these
# three were the only red in the suite on the Linux host and they are red at the
# commit that introduced them. Built like the `stat` case below instead - every
# command on this machine EXCEPT the one under test - so the absence is real
# wherever the suite runs.
mkdir -p "$T/bin2"
ln -s /usr/bin/* "$T/bin2/" 2>/dev/null
ln -s /bin/*     "$T/bin2/" 2>/dev/null
rm -f "$T/bin2/systemctl"
for f in tmux pgrep ps; do rm -f "$T/bin2/$f"; cp "$T/bin/$f" "$T/bin2/$f"; done
out2="$( env -i HOME="$T/home" PATH="$T/bin2" \
          STEWARD_ESTATE_ROOT="$T" STEWARD_REGISTRY_DIR="$T/sessions.d" \
          STEWARD_SELF_HOST="h1" STEWARD_SELF_USER="alice" \
          TMUX_LOG="$T/tmuxlog2" OBS_LOG="$T/obslog" OBS_DIR="$T/obs" STEWARD_BRIDGE_OBSERVE="$T/bin/bridge-observe" bash "$CMD" 2>/dev/null )"
eq "the answer is still valid JSON" \
   "$(printf '%s' "$out2" | jq -r '.sessions | type')" "object"
eq "nothing is measured" \
   "$(printf '%s' "$out2" | jq -r '.sessions | length')" "0"
eq "all nine own rows are omitted" \
   "$(printf '%s' "$out2" | jq -r '.omitted | length')" "9"
eq "and the reason names the missing tool" \
   "$(printf '%s' "$out2" | jq -r '.omitted["s-a1"] | test("systemctl")')" "true"
eq "the neighbour is still not in the answer" \
   "$(printf '%s' "$out2" | jq -r '.omitted | has("s-e5")')" "false"

echo "== stat is one of those tools, and its absence is named too =="
# A codex row's lastActivity IS an mtime, and an mtime comes from stat. A host
# without it cannot look; writing null into `sessions` there would say "never
# ran" about a row nobody managed to ask. The directory below is every command
# on this machine EXCEPT that one, so the rest of the fixture still runs.
mkdir -p "$T/bin3"
ln -s /usr/bin/* "$T/bin3/" 2>/dev/null
ln -s /bin/*     "$T/bin3/" 2>/dev/null
rm -f "$T/bin3/stat"
for f in systemctl tmux pgrep ps; do rm -f "$T/bin3/$f"; cp "$T/bin/$f" "$T/bin3/$f"; done
out3="$( env -i HOME="$T/home" PATH="$T/bin3" \
          STEWARD_ESTATE_ROOT="$T" STEWARD_REGISTRY_DIR="$T/sessions.d" \
          STEWARD_SELF_HOST="h1" STEWARD_SELF_USER="alice" \
          STEWARD_CODEX_STATE_DIR="$CX" \
          STEWARD_CODEX_DAEMON_SOCK="$T/codex-daemon.sock" \
          TMUX_LOG="$T/tmuxlog7" OBS_LOG="$T/obslog" OBS_DIR="$T/obs" STEWARD_BRIDGE_OBSERVE="$T/bin/bridge-observe" bash "$CMD" 2>/dev/null )"
eq "nothing is measured" \
   "$(printf '%s' "$out3" | jq -r '.sessions | length')" "0"
eq "and the reason names the tool" \
   "$(printf '%s' "$out3" | jq -r '.omitted["s-a1"] | test("stat")')" "true"

echo "== no argument is taken: the contract is the whole home in one call =="
env -i HOME="$T/home" PATH="$T/bin:/usr/bin:/bin" \
  STEWARD_ESTATE_ROOT="$T" STEWARD_REGISTRY_DIR="$T/sessions.d" \
  STEWARD_SELF_HOST="h1" STEWARD_SELF_USER="alice" TMUX_LOG="$T/tmuxlog3" OBS_LOG="$T/obslog" OBS_DIR="$T/obs" STEWARD_BRIDGE_OBSERVE="$T/bin/bridge-observe" \
  bash "$CMD" s-a1 >"$T/argout" 2>/dev/null; rc3=$?
if [ "$rc3" -ne 0 ]; then ok "an argument is refused"; else bad "an argument is refused" "rc=0"; fi
# A REFUSAL MUST NOT LEAK ONTO STDOUT, or the caller cannot tell it from an
# empty home.
eq "and stdout stays empty" "$(cat "$T/argout")" ""

echo "== a tmux server that could not be ASKED is unknown, never a home full of 'down' =="
# MEASURED 2026-09-09 on a live host: a tmux call that FAILS is swallowed by the
# `|| true` on the one list-sessions probe, and every pane row in the home is
# then written into `sessions` as tmux `down`, agent `not-running`. Three
# demonstrably live sessions — one of them the session running the measurement —
# reported dead, with an EMPTY stderr and an EMPTY `omitted`. Nothing anywhere
# said a probe had failed.
#
# That is a guess wearing a measurement's clothes, which is the one thing this
# file promises never to produce. It is also not hypothetical: the whole desk
# generation fell out this way at 13:30, 0 of 81 rows carrying a life sign
# across five homes, and a person read his own working session as dead.
#
# TWO RETURN CODES, because they arrive by different doors and neither may be
# read as an answer: 124 is the aggregator's own `timeout` ceiling cutting a
# slow home off, 1 is a server that was not there to be asked. A third door —
# any other non-zero — is covered by the same branch.
#
# THE CODEX ROWS MUST SURVIVE IT. A codex row is a thread, not a pane, and never
# needed tmux at all; an outage in one runtime's probe may not erase the other
# runtime's measurement.
mkdir -p "$T/bin4"
for f in systemctl pgrep ps; do cp "$T/bin/$f" "$T/bin4/$f"; done
#
# THE STDERR IS HOSTILE ON PURPOSE. This diff is the first thing that carries an
# estate's FREE TEXT into a reason, and from there into the desk's HTML and into
# a TSV whose fields are positional. A fixture whose stub says nothing cannot
# fail the JSON claim below - gut both escapes in _json_str and the suite still
# reads green. So the stub says the four things that break the three layers: a
# double quote and a backslash (which close a JSON string), a TAB (which invents
# a ninth TSV field), and a script tag (which is markup on the page).
for trc in 1 124; do
  cat > "$T/bin4/tmux" <<EOF
#!/bin/bash
echo "\$@" >> "\${TMUX_LOG:?}"
printf 'no route: peer said "down\\\\here"\tafter-tab <script>alert(1)</script>\n' >&2
exit $trc
EOF
  chmod +x "$T/bin4/tmux"
  out4="$( env -i HOME="$T/home" PATH="$T/bin4:/usr/bin:/bin" \
            STEWARD_ESTATE_ROOT="$T" STEWARD_REGISTRY_DIR="$T/sessions.d" \
            STEWARD_SELF_HOST="h1" STEWARD_SELF_USER="alice" \
            STEWARD_CODEX_STATE_DIR="$CX" \
            STEWARD_CODEX_DAEMON_SOCK="$T/codex-daemon.sock" \
            TMUX_LOG="$T/tmuxlog-$trc" OBS_LOG="$T/obslog" OBS_DIR="$T/obs" STEWARD_BRIDGE_OBSERVE="$T/bin/bridge-observe" bash "$CMD" 2>"$T/err-$trc" )"

  eq "rc $trc: the answer is still valid JSON" \
     "$(printf '%s' "$out4" | jq -r '.sessions | type')" "object"
  # THE POINT OF THE WHOLE BLOCK: no pane row may carry a negative word.
  eq "rc $trc: no pane row is invented as not-running" \
     "$(printf '%s' "$out4" | jq -r '[.sessions[] | select(.tmux != "n/a") | .agent] | length')" "0"
  eq "rc $trc: the four pane rows are omitted instead" \
     "$(printf '%s' "$out4" | jq -r '[.omitted | keys[] | select(. == "s-a1" or . == "s-b2" or . == "s-c3" or . == "s-d4")] | length')" "4"
  eq "rc $trc: and the reason names tmux" \
     "$(printf '%s' "$out4" | jq -r '.omitted["s-a1"] | test("tmux")')" "true"
  # THE FOUR HOSTILE SHAPES, EACH ASSERTED WHERE IT WOULD DO ITS DAMAGE.
  eq "rc $trc: the quote and backslash survive as data, not as structure" \
     "$(printf '%s' "$out4" | jq -r '.omitted["s-a1"] | test("down\\\\here")')" "true"
  eq "rc $trc: the script tag is carried as text" \
     "$(printf '%s' "$out4" | jq -r '.omitted["s-a1"] | test("<script>")')" "true"
  # THE TAB IS CARRIED, NOT STRIPPED - and MEASURED rather than assumed, because
  # the first version of this block asserted the opposite and was wrong. What
  # matters is not that the character is absent; it is that it never becomes
  # STRUCTURE at any of the three layers it crosses.
  #
  # LAYER ONE, THIS FILE'S JSON: a RAW control character inside a JSON string is
  # invalid, and one raw tab would take the WHOLE home to `seam-unparseable` -
  # every row, not just this one. _json_str emits the two-character escape
  # instead, so the bytes on stdout carry no literal tab anywhere.
  eq "rc $trc: no literal tab is emitted - it is escaped, not raw" \
     "$(printf '%s' "$out4" | grep -c "$(printf '\t')")" "0"
  # LAYER TWO, THE SEAM'S TSV: measured end to end against lib/liveness.sh - the
  # decoded tab goes through `jq -r @tsv`, which re-escapes it, and the row stays
  # EIGHT fields. A ninth field would shift `reason` into a column a view reads
  # as something else.
  eq "rc $trc: the reason is one TSV field, not two" \
     "$(printf '%s' "$out4" | jq -r '[.omitted["s-a1"]] | @tsv' | awk -F'\t' '{print NF}')" "1"
  eq "rc $trc: and the answer still has exactly the four pane rows" \
     "$(printf '%s' "$out4" | jq -r '.omitted | length')" "4"
  # THE FAILURE IS SAID OUT LOUD. A silent omission is how six causes render as
  # one word with nowhere to look; this file's seam keeps stderr as the channel.
  if [ -s "$T/err-$trc" ]; then ok "rc $trc: the failure is said on stderr"
  else bad "rc $trc: the failure is said on stderr" "stderr was empty"; fi
  # THE OTHER RUNTIME IS UNTOUCHED.
  eq "rc $trc: the codex rows are still measured" \
     "$(printf '%s' "$out4" | jq -r '.sessions | length')" "5"
  eq "rc $trc: and a healthy codex row still reads running" \
     "$(printf '%s' "$out4" | jq -r '.sessions["s-g7"].agent')" "running"
  # A PROBE THAT FAILED IS NOT A PROBE THAT WAS SKIPPED: it was attempted.
  eq "rc $trc: tmux was actually asked" \
     "$(grep -c 'list-sessions' "$T/tmuxlog-$trc" | tr -d ' ')" "1"
done

echo "== the SECOND door: a session listed as up whose panes cannot be read =="
# THE FIX THAT SHIPPED FIRST LEFT THIS ONE OPEN, and a review caught it. It lands
# somewhere worse than the closed door: list-sessions has already said the
# session is UP, so a failed list-panes produced `tmux: up, agent: not-running`
# with an empty stderr. A confident, specific, false report that a live session
# has no runtime - which is the line an operator acts on, unlike a question mark.
#
# The stub answers list-sessions normally and fails ONLY list-panes, so exactly
# one fact differs from the healthy fixture.
mkdir -p "$T/bin7"
for f in systemctl pgrep ps; do cp "$T/bin/$f" "$T/bin7/$f"; done
cat > "$T/bin7/tmux" <<'EOF'
#!/bin/bash
echo "$@" >> "${TMUX_LOG:?}"
for a in "$@"; do
  case "$a" in
    list-sessions) printf 's-a1 1756540800\ns-b2 1756540900\ns-d4 1756541000\ns-g7 1756541100\n'; exit 0 ;;
    list-panes)    echo "error connecting to /x (Connection refused)" >&2; exit 1 ;;
  esac
done
exit 0
EOF
chmod +x "$T/bin7/tmux"
out7="$( env -i HOME="$T/home" PATH="$T/bin7:/usr/bin:/bin" \
          STEWARD_ESTATE_ROOT="$T" STEWARD_REGISTRY_DIR="$T/sessions.d" \
          STEWARD_SELF_HOST="h1" STEWARD_SELF_USER="alice" \
          STEWARD_CODEX_STATE_DIR="$CX" \
          STEWARD_CODEX_DAEMON_SOCK="$T/codex-daemon.sock" \
          TMUX_LOG="$T/tmuxlog-panes" OBS_LOG="$T/obslog" OBS_DIR="$T/obs" STEWARD_BRIDGE_OBSERVE="$T/bin/bridge-observe" bash "$CMD" 2>"$T/err-panes" )"
eq "no up row is answered as not-running" \
   "$(printf '%s' "$out7" | jq -r '[.sessions[] | select(.tmux == "up") | select(.agent == "not-running")] | length')" "0"
eq "the up OpenCode pane row is omitted instead (claude rows never walk their panes here - L2)" \
   "$(printf '%s' "$out7" | jq -r '[.omitted | keys[] | select(. == "s-a1" or . == "s-b2" or . == "s-d4")] | length')" "1"
eq "and the reason says the panes could not be read" \
   "$(printf '%s' "$out7" | jq -r '.omitted["s-d4"] | test("panes could not be read")')" "true"
# A DOWN ROW NEVER REACHED THE PANE WALK, so it keeps its measurement.
eq "the row that was never up is still measured" \
   "$(printf '%s' "$out7" | jq -r '.sessions["s-c3"].agent')" "not-running"
# L2 (plan Task 8): a claude row never walks its panes here, so a pane census that cannot be read omits
# only the OpenCode row; the claude rows stay measured - tmux up from list-sessions, agent from the adapter.
eq "L2: the up claude row is NOT omitted for an unreadable pane census" "$(printf '%s' "$out7" | jq -r '.omitted | has("s-a1")')" "false"
eq "L2: it reads tmux up" "$(printf '%s' "$out7" | jq -r '.sessions["s-a1"].tmux')" "up"
eq "L2: and agent running, from the adapter" "$(printf '%s' "$out7" | jq -r '.sessions["s-a1"].agent')" "running"
eq "L2: the OpenCode row IS omitted, with the pane read named" "$(printf '%s' "$out7" | jq -r '.omitted["s-d4"] | test("panes could not be read")')" "true"
eq "and the codex rows are untouched" \
   "$(printf '%s' "$out7" | jq -r '.sessions["s-g7"].agent')" "running"

echo "== pgrep: rc 1 is a measurement, anything above it is not =="
# THE BRANCH EXISTED AND NOTHING WOULD HAVE NOTICED IF IT STOPPED. pgrep exits 1
# when nothing matched - the ordinary quiet home - and greater than 1 when it
# could not look at all. Collapsing the two is the same fabrication as the tmux
# door: an empty list makes every live pane row read `not-running`.
mkdir -p "$T/bin8"
for f in systemctl tmux ps; do cp "$T/bin/$f" "$T/bin8/$f"; done
for prc in 1 2; do
  printf '#!/bin/bash\nexit %s\n' "$prc" > "$T/bin8/pgrep"; chmod +x "$T/bin8/pgrep"
  out8="$( env -i HOME="$T/home" PATH="$T/bin8:/usr/bin:/bin" \
            STEWARD_ESTATE_ROOT="$T" STEWARD_REGISTRY_DIR="$T/sessions.d" \
            STEWARD_SELF_HOST="h1" STEWARD_SELF_USER="alice" \
            STEWARD_CODEX_STATE_DIR="$CX" \
            STEWARD_CODEX_DAEMON_SOCK="$T/codex-daemon.sock" \
            TMUX_LOG="$T/tmuxlog-pg$prc" OBS_LOG="$T/obslog" OBS_DIR="$T/obs" STEWARD_BRIDGE_OBSERVE="$T/bin/bridge-observe" bash "$CMD" 2>"$T/err-pg$prc" )"
  if [ "$prc" = 1 ]; then
    eq "rc 1: nothing matched is a measurement, rows stay in sessions" \
       "$(printf '%s' "$out8" | jq -r '.sessions | length')" "9"
    eq "rc 1: and the OpenCode pane row honestly reads not-running" \
       "$(printf '%s' "$out8" | jq -r '.sessions["s-d4"].agent')" "not-running"
    eq "rc 1: a claude row carries the adapter's answer, not pgrep's" \
       "$(printf '%s' "$out8" | jq -r '.sessions["s-a1"].agent')" "running"
    eq "rc 1: nothing is excused" \
       "$(printf '%s' "$out8" | jq -r '.omitted | length')" "0"
  else
    # SINCE TASK 8 the host's pgrep measures only the OpenCode pane walk; a claude row's agent is the
    # bridge adapter's answer, whose own census failures come back as unknown with their reason.
    eq "rc 2: the OpenCode pane row is not invented as not-running" \
       "$(printf '%s' "$out8" | jq -r '[.sessions[] | select(.runtime == "opencode")] | length')" "0"
    eq "rc 2: it is omitted with pgrep named" \
       "$(printf '%s' "$out8" | jq -r '.omitted["s-d4"] | test("pgrep")')" "true"
    eq "rc 2: the claude rows are not omitted for the host's pgrep - the adapter measured them" \
       "$(printf '%s' "$out8" | jq -r '.omitted | has("s-a1")')" "false"
    eq "rc 2: the codex rows and the claude rows still answer" \
       "$(printf '%s' "$out8" | jq -r '.sessions | length')" "8"
  fi
done

echo "== but a home with NO SERVER is measured, not excused =="
# THE CASE THE BRANCH ABOVE MUST NOT SWALLOW. `tmux list-sessions` exits 1 when
# there is no server at all - the ordinary state of a quiet home - and that is a
# MEASUREMENT: no server, no pane, nothing that can descend from one. Reading
# every non-zero rc as "could not ask" would turn every quiet home into a column
# of question marks, which is the same silence from the other side.
#
# The message is tmux's own, measured against tmux 3.4 on a socket whose file
# exists with no server behind it.
cat > "$T/bin4/tmux" <<'EOF'
#!/bin/bash
echo "$@" >> "${TMUX_LOG:?}"
echo "no server running on $HOME/.tmux/acme.sock" >&2
exit 1
EOF
chmod +x "$T/bin4/tmux"
obs s-a1 no-process gone-noreceipt   # with no server the adapter finds nothing either; the stub says so
out5="$( env -i HOME="$T/home" PATH="$T/bin4:/usr/bin:/bin" \
          STEWARD_ESTATE_ROOT="$T" STEWARD_REGISTRY_DIR="$T/sessions.d" \
          STEWARD_SELF_HOST="h1" STEWARD_SELF_USER="alice" \
          STEWARD_CODEX_STATE_DIR="$CX" \
          STEWARD_CODEX_DAEMON_SOCK="$T/codex-daemon.sock" \
          TMUX_LOG="$T/tmuxlog-noserver" OBS_LOG="$T/obslog" OBS_DIR="$T/obs" STEWARD_BRIDGE_OBSERVE="$T/bin/bridge-observe" bash "$CMD" 2>"$T/err-noserver" )"
eq "all nine rows are measured, none excused" \
   "$(printf '%s' "$out5" | jq -r '.sessions | length')" "9"
eq "no pane row is omitted" \
   "$(printf '%s' "$out5" | jq -r '.omitted | length')" "0"
eq "a pane row reads down - we looked, and there was no server" \
   "$(printf '%s' "$out5" | jq -r '.sessions["s-a1"].tmux')" "down"
eq "and its agent reads not-running, which is measured (the adapter's no-process)" \
   "$(printf '%s' "$out5" | jq -r '.sessions["s-a1"].agent')" "not-running"
obs s-a1 identified:managed alive live:managed
# A MEASUREMENT IS NOT AN INCIDENT: nothing is written to stderr for the
# ordinary quiet home, or the log fills with a warning nobody reads.
eq "and nothing is reported as a failure" "$(cat "$T/err-noserver")" ""

echo "== and the other direction still holds: a session that is really down is down =="
# The pairing is what makes the claim mean anything. `s-c3` has an armed timer
# and no tmux session on a HEALTHY server: that is a measurement, and it must
# keep its negative word. Asserted here beside its opposite so the two read
# together; the fixture at the top of this file pins the same row's fields.
eq "a genuinely absent session is still not-running" \
   "$(printf '%s' "$out" | jq -r '.sessions["s-c3"].agent')" "not-running"
eq "and it is NOT omitted — it was measured" \
   "$(printf '%s' "$out" | jq -r '.omitted | has("s-c3")')" "false"

echo
printf '%s passed, %s failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
