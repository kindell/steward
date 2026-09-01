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
# THE DECLARED SOCKET MUST EXIST for it to be used — an estate file may name a
# socket its machinery never created, and asking a server that is not there
# would report a healthy home as dead.
#
# A REAL UNIX SOCKET, not an empty file. The probe tests for a socket (-S), and
# a fixture that put a regular file there would prove only that the path exists
# — which is the exact confusion the existence check was added to prevent.
if ! python3 - "$T/home/.tmux/acme.sock" <<'PY' 2>/dev/null
import socket, sys
s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM); s.bind(sys.argv[1])
PY
then
  echo "  FAIL could not create a unix socket for the fixture (python3?)" >&2
  exit 1
fi

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
  esac
done
exit 3
EOF

# tmux on the declared socket: s-a1, s-b2 and s-d4 are live. s-c3 is not.
# `session_activity` is epoch seconds, which is where lastActivity comes from.
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
    printf 's-a1 1756540800\ns-b2 1756540900\ns-d4 1756541000\n' ;;
  list-panes)
    case "$target" in
      s-a1) echo 100 ;;
      s-b2) echo 200 ;;
      s-d4) echo 400 ;;
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
  100|200|400) echo 50 ;;
  50) echo 1 ;;
  *) exit 1 ;;
esac
EOF
chmod +x "$T/bin/systemctl" "$T/bin/tmux" "$T/bin/pgrep" "$T/bin/ps"

run() { # run [extra PATH dir first] -> stdout of the answerer
  env -i HOME="$T/home" PATH="$T/bin:/usr/bin:/bin" \
    STEWARD_ESTATE_ROOT="$T" STEWARD_REGISTRY_DIR="$T/sessions.d" \
    STEWARD_SELF_HOST="h1" STEWARD_SELF_USER="alice" \
    TMUX_LOG="$T/tmuxlog" \
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

echo "== another account's row leaves the answer entirely =="
eq "it is not measured" "$(printf '%s' "$out" | jq -r '.sessions | has("s-e5")')" "false"
# NOT EVEN AS AN OMISSION. An omitted entry says "I tried and could not"; this
# account never had standing to try, and saying so in a measurement map would
# invite a reader to believe the row is broken rather than somebody else's.
eq "and not excused either" "$(printf '%s' "$out" | jq -r '.omitted | has("s-e5")')" "false"

echo "== another host's row leaves the answer entirely =="
eq "it is not measured" "$(printf '%s' "$out" | jq -r '.sessions | has("s-f6")')" "false"
eq "and not excused either" "$(printf '%s' "$out" | jq -r '.omitted | has("s-f6")')" "false"

echo "== exactly four rows are answered for =="
eq "four measured rows" "$(printf '%s' "$out" | jq -r '.sessions | length')" "4"

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
mkdir -p "$T/bin2"
for f in tmux pgrep ps; do cp "$T/bin/$f" "$T/bin2/$f"; done
out2="$( env -i HOME="$T/home" PATH="$T/bin2:/usr/bin:/bin" \
          STEWARD_ESTATE_ROOT="$T" STEWARD_REGISTRY_DIR="$T/sessions.d" \
          STEWARD_SELF_HOST="h1" STEWARD_SELF_USER="alice" \
          TMUX_LOG="$T/tmuxlog2" bash "$CMD" 2>/dev/null )"
eq "the answer is still valid JSON" \
   "$(printf '%s' "$out2" | jq -r '.sessions | type')" "object"
eq "nothing is measured" \
   "$(printf '%s' "$out2" | jq -r '.sessions | length')" "0"
eq "all four own rows are omitted" \
   "$(printf '%s' "$out2" | jq -r '.omitted | length')" "4"
eq "and the reason names the missing tool" \
   "$(printf '%s' "$out2" | jq -r '.omitted["s-a1"] | test("systemctl")')" "true"
eq "the neighbour is still not in the answer" \
   "$(printf '%s' "$out2" | jq -r '.omitted | has("s-e5")')" "false"

echo "== no argument is taken: the contract is the whole home in one call =="
env -i HOME="$T/home" PATH="$T/bin:/usr/bin:/bin" \
  STEWARD_ESTATE_ROOT="$T" STEWARD_REGISTRY_DIR="$T/sessions.d" \
  STEWARD_SELF_HOST="h1" STEWARD_SELF_USER="alice" TMUX_LOG="$T/tmuxlog3" \
  bash "$CMD" s-a1 >"$T/argout" 2>/dev/null; rc3=$?
if [ "$rc3" -ne 0 ]; then ok "an argument is refused"; else bad "an argument is refused" "rc=0"; fi
# A REFUSAL MUST NOT LEAK ONTO STDOUT, or the caller cannot tell it from an
# empty home.
eq "and stdout stays empty" "$(cat "$T/argout")" ""

echo
printf '%s passed, %s failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
