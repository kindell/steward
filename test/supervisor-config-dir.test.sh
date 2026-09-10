#!/bin/bash
# test/supervisor-config-dir.test.sh - who makes a login's credential
# directory, and with what mode.
#
# THE TRAP THIS FILE EXISTS TO KEEP SHUT. registry_login_config_dir refuses a
# group- or other-writable credential directory, and it deliberately ALLOWS one
# that does not exist yet - a missing directory is the normal state before a
# cutover, and refusing it would make the gate something an operator turns off
# in order to migrate. Those two rules are each right and together they were a
# time bomb:
#
#   round 1  the directory is missing, the gate allows it, the session starts,
#            and the CLI creates the directory itself THROUGH THE UMASK. Under
#            the Debian default of 002 that is 0775.
#   round 2  the gate measures a group-writable credential directory and
#            refuses, correctly. The session dies and stays dead.
#
# So a session works exactly once, and the refusal names a mode nobody chose.
# MEASURED 2026-09-09 on a live estate: six sessions on a freshly made login
# directory, all dead by the next round, the only trace in the unit's journal.
#
# THE SUITE RUNS UNDER 002 ON PURPOSE. Every other fixture in this repo pins
# its modes so the host's umask cannot change the answer; this one does the
# opposite for the directory under test, because the umask IS the mechanism.
set -u
here="$(CDPATH= cd -- "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SUP="$here/linux/session-supervisor-linux.sh"
pass=0; fail=0
ok()  { pass=$((pass+1)); printf '  ok   %s\n' "$1"; }
bad() { fail=$((fail+1)); printf '  FAIL %s\n     %s\n' "$1" "${2:-}"; }
is()  { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "wanted '$3', got '$2'"; fi; }
has() { case "$2" in *"$3"*) ok "$1" ;; *) bad "$1" "missing '$3' in: $2" ;; esac; }

T="$(mktemp -d)"; trap 'chmod -R u+rwX "$T" 2>/dev/null; rm -rf "$T"' EXIT
HOMEDIR="$T/home"; ROOT="$T/estate"; LIBS="$T/libs"; BIN="$T/bin"
mkdir -p "$HOMEDIR/.local/bin" "$HOMEDIR/Projects/repo" "$LIBS" "$BIN" \
         "$ROOT/estate" "$ROOT/sessions.d" "$ROOT/entities.d" "$ROOT/accounts.d" \
         "$ROOT/projects.d" "$ROOT/mcp.d" "$ROOT/logins.d" "$T/memory"
chmod 700 "$ROOT/logins.d"
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
# THE TMUX DOUBLE RECORDS WHAT IT WAS ASKED, and that is not tidiness - the
# first version of it was `exit 1` and nothing else, and it made assertion 5c
# VACUOUS: "the session never started" grepped the round's output for
# `new-session`, a string a silent stub can never produce, so the assertion
# passed whether the round refused or not. MEASURED: with the whole creation
# guard removed, 5c still passed.
#
# That is the double carrying away the very thing the assertion was about. A
# stub that only returns a code can answer "did it fail?" and nothing else;
# one that logs its argv can answer "what did it try?", which is what an
# assertion about behaviour needs.
TMUX_LOG="$T/tmux.log"
printf '#!/bin/sh\nprintf "%%s\\n" "$*" >> %s\nexit 1\n' "$TMUX_LOG" > "$BIN/tmux"
chmod 755 "$BIN/tmux"; : > "$TMUX_LOG"

# The login's home is resolved through the product's own hook, so the suite
# never writes into the running user's real home.
printf '#!/bin/sh\nprintf "%%s" "%s"\n' "$HOMEDIR" > "$T/homelookup"; chmod 755 "$T/homelookup"
printf 'PRINCIPAL="a"\nACCOUNT="a@fixture.invalid"\nPROVIDER="claude-max"\nCONFIG_DIR="~/.claude-logins/alpha"\nLEGAL_OWNER="a"\n' > "$ROOT/logins.d/alpha.conf"
chmod 600 "$ROOT/logins.d/alpha.conf"

NAME="s-0000000000000001"
cat > "$ROOT/sessions.d/$NAME.conf" <<EOF
OWNER="a"
HOST="h1"
DOMAIN="alpha"
REPO_PATH="$HOMEDIR/Projects/repo"
ID="$NAME"
RC_LABEL="Fixture Hub"
LOGIN="alpha"
CLAUDE_MEMORY_ROOT="$T/memory"
EOF

CFG="$HOMEDIR/.claude-logins/alpha"
run() {
  : > "$TMUX_LOG"
  ( umask 002
    HOME="$HOMEDIR" \
    STEWARD_ESTATE_ROOT="$ROOT" \
    STEWARD_CONFIG_FILE="$T/no-such-config" \
    STEWARD_REGISTRY_LIB="$LIBS/registry.sh" \
    STEWARD_TMUX_SOCKET="$T/fixture.sock" \
    STEWARD_SELF_HOST="h1" \
    STEWARD_HOME_LOOKUP_CMD="$T/homelookup" \
    STEWARD_KEY_SETTLE_SEC=0 \
    PATH="$BIN:$PATH" \
    bash "$SUP" "$NAME" >"$T/out" 2>&1 )
  RC=$?; OUT="$(cat "$T/out")"; TMUXED="$(cat "$TMUX_LOG" 2>/dev/null)"
}
mode_of() { stat -c '%a' "$1" 2>/dev/null || stat -f '%Lp' "$1" 2>/dev/null; }

echo "== 1. a missing credential directory is made by us, at 0700 =="
rm -rf "$HOMEDIR/.claude-logins"
run
is "1a the directory now exists"                "$( [ -d "$CFG" ] && echo yes || echo no )" "yes"
is "1b at 0700, not at whatever the umask said" "$(mode_of "$CFG")" "700"
is "1c and so is the parent it was made under"  "$(mode_of "$HOMEDIR/.claude-logins")" "700"
has "1d and the round says it did it"           "$OUT" "created the credential directory 0700"
# THE DOUBLE MUST BE ABLE TO SAY BOTH THINGS, or an assertion that reads it
# proves nothing. This is the happy path: the directory was made, the gate
# passed, and the round went on to ask tmux for a session. If this line ever
# goes quiet, assertion 5c below stops being an assertion and nobody notices.
has "1e and the round got as far as asking tmux for a session" "$TMUXED" "new-session"

echo "== 2. and that is the whole point: a second round still passes the gate =="
# THE REGRESSION, stated as the incident: leave the creation to the umask and
# this is the round that refuses. `-e` on the refusal, not on the exit code,
# because a later stage of the round fails in this fixture for its own reasons.
run
is "2a no refusal on the second round" \
   "$(printf '%s' "$OUT" | grep -c 'REFUSING.*group- or other-writable')" "0"
is "2b and the mode has not drifted" "$(mode_of "$CFG")" "700"

echo "== 3. the trap, reproduced: a 0775 directory IS refused =="
# Exactly what the CLI leaves behind under a 002 umask. The gate must still
# refuse it - the creation above is a fix for who makes the directory, never a
# loosening of what is acceptable once it exists.
rm -rf "$HOMEDIR/.claude-logins"
mkdir -p "$CFG"; chmod 755 "$HOMEDIR/.claude-logins"; chmod 775 "$CFG"
run
is  "3a the round refuses"                    "$RC" "78"
has "3b naming the mode nobody chose"         "$OUT" "group- or other-writable (mode 775)"
has "3c and naming the directory"             "$OUT" ".claude-logins/alpha"

echo "== 4. a group-writable PARENT is refused too - the trap one level up =="
# `mkdir -m 700 -p` would not have caught this: -m applies to the directory
# mkdir creates, never to the parents it makes on the way.
rm -rf "$HOMEDIR/.claude-logins"
mkdir -p "$HOMEDIR/.claude-logins"; chmod 775 "$HOMEDIR/.claude-logins"
run
is  "4a a 0775 parent is refused"      "$RC" "78"
has "4b and the PARENT is named as the thing at fault" "$OUT" "the PARENT"

echo "== 5. a chmod that does not take is refused NOW, not one round later =="
# A chmod that silently fails leaves a 0775 credential directory behind, and
# the round must not start a session on it - otherwise the fix for the
# incident reintroduces the incident. The check that catches this is
# registry_login_exec_prefix further down, which re-resolves the login and
# refuses to start before any pane is touched; this case is what proves it.
# (A second explicit gate call was written here first, and deleted when it
# turned out to cost nothing: this check already did the work.)
#
# The failure is made reproducible rather than argued about: chmod is stubbed
# to fail without changing anything, which is what an immutable attribute or a
# hostile filesystem does, and mkdir under 002 then leaves exactly 0775.
rm -rf "$HOMEDIR/.claude-logins"
printf '#!/bin/sh\nexit 1\n' > "$BIN/chmod"; chmod 755 "$BIN/chmod"
run
rm -f "$BIN/chmod"
is  "5a the round refuses immediately"        "$RC" "78"
has "5b naming the mode the chmod failed to remove" "$OUT" "group- or other-writable"
is  "5c and the session never started"        "$(printf '%s' "$TMUXED" | grep -c 'new-session')" "0"
# AND THE DOUBLE IS PROVED TO BE ABLE TO SAY OTHERWISE. An assertion that
# reads a log nothing ever writes to is not an assertion; this pins that the
# stub does record, so 5c can fail.
# (1e above is what proves 5c can fail: the same log carries `new-session` on
# the happy path, so its absence here is a measurement and not a silent stub.)

echo "== 6. a session with no login is untouched by any of it =="
# The estate that has not moved to named logins must not acquire a new failure
# mode from a change made for the ones that have.
sed -i.bak '/^LOGIN=/d' "$ROOT/sessions.d/$NAME.conf" 2>/dev/null || \
  sed -i '' '/^LOGIN=/d' "$ROOT/sessions.d/$NAME.conf"
rm -rf "$HOMEDIR/.claude-logins"
run
is "6a nothing is created for a session without a login" \
   "$( [ -e "$HOMEDIR/.claude-logins" ] && echo made || echo none )" "none"
is "6b and no credential directory is refused" \
   "$(printf '%s' "$OUT" | grep -c 'REFUSING')" "0"

printf '\n  %d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
