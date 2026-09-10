#!/bin/bash
# desk-paths grows three optional lines for the front: the origin, the
# providers directory and the session key file the front cannot start without.
set -u
here="$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)"
pass=0; fail=0
ok()  { pass=$((pass+1)); printf '  ok   %s\n' "$1"; }
bad() { fail=$((fail+1)); printf '  FAIL %s\n     %s\n' "$1" "${2:-}"; }
is()  { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "wanted '$3', got '$2'"; fi; }
has() { case "$2" in *"$3"*) ok "$1" ;; *) bad "$1" "missing '$3' in: $2" ;; esac; }
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
ROOT="$T/estate"; mkdir -p "$ROOT/estate" "$ROOT/principals.d"
cat > "$ROOT/estate/steward.conf" <<'EOF'
ESTATE_NAME="fixture"
SCHEMA_VERSION="3"
HUB_SESSION="hub"
HUB_HOST="host-a"
HUB_SSH="hub@host-a"
LABEL_PREFIX="x."
RC_LABEL_PREFIX=""
TMUX_SOCKET="fx"
STATE_DIR_NAME="fixture-state"
PAUSED_DIR_NAME="fixture-paused"
PING_MSG="ping"
OP_TOKEN_NAME="op"
BUS_DIR_NAME="fixture-bus"
EOF
export STEWARD_ESTATE_ROOT="$ROOT" STEWARD_CONFIG_FILE="$T/no-such-config" HOME="$T/home"
mkdir -p "$HOME"
echo "desk-paths"

echo "== without front keys, exactly the two classic lines =="
out="$(bash "$here/desk/bin/desk-paths")"; rc=$?
is  "rc 0" "$rc" "0"
is  "two lines" "$(printf '%s\n' "$out" | wc -l | tr -d ' ')" "2"
has "dir line"  "$out" "dir=$HOME/.local/state/fixture-state/desk"
has "sock line" "$out" "sock=$HOME/.local/state/fixture-state/desk.sock"

echo "== with the front keys and a providers directory =="
printf 'DESK_ORIGIN="https://desk.example.test"\nDESK_SESSION_KEY_FILE="/var/fixture/key"\n' >> "$ROOT/estate/steward.conf"
mkdir -p "$ROOT/desk/providers.d"
out="$(bash "$here/desk/bin/desk-paths")"; rc=$?
is  "rc 0" "$rc" "0"
has "origin line"      "$out" "origin=https://desk.example.test"
has "providers line"   "$out" "providers=$ROOT/desk/providers.d"
has "session_key line" "$out" "session_key=/var/fixture/key"

echo "== a malformed origin is a refusal, not a guess =="
sed -i.bak 's|^DESK_ORIGIN=.*|DESK_ORIGIN="desk.example.test/desk"|' "$ROOT/estate/steward.conf"
bash "$here/desk/bin/desk-paths" >/dev/null 2>"$T/err"; rc=$?
is  "rc 78" "$rc" "78"
has "names the key" "$(cat "$T/err")" "DESK_ORIGIN"

echo "== a plaintext origin is refused, not quietly served =="
sed -i.bak 's|^DESK_ORIGIN=.*|DESK_ORIGIN="http://desk.example.test"|' "$ROOT/estate/steward.conf"
bash "$here/desk/bin/desk-paths" >/dev/null 2>"$T/err"; rc=$?
is  "http is rc 78" "$rc" "78"
has "http names the key" "$(cat "$T/err")" "DESK_ORIGIN"


# A CONTROL CHARACTER IN ANY VALUE IS A REFUSAL, and this is NOT hypothetical:
# measured 2026-09-10 against the shipped bridge. The conf is sourced as shell,
# so a quoted value may legally span lines - and this bridge is LINE-ORIENTED
# while its reader (desk/serve.mjs) keeps the LAST line for a key. A newline in
# DESK_SESSION_KEY_FILE therefore does not corrupt its own line; it writes a NEW
# one, and a second `origin=` after the real one is the origin the front starts
# on. Its regex `^/.+$` admits it because `.` matches a newline here.
#
# The guard lives in front_value, which every key goes through, rather than in
# each key's own expression: the sixth key will not remember this test.
echo "== a value with a newline cannot smuggle a second line =="
{ printf 'HUB_HOST="h1"\nLABEL_PREFIX="com.fixture"\nSTATE_DIR_NAME="fixture-state"\n'
  printf 'OP_TOKEN_NAME="op"\nBUS_DIR_NAME="fixture-bus"\n'
  printf 'DESK_ORIGIN="https://desk.example.test"\n'
  printf 'DESK_SESSION_KEY_FILE="/var/fixture/key\norigin=https://elsewhere.example"\n'
} > "$ROOT/estate/steward.conf"
out="$(bash "$here/desk/bin/desk-paths" 2>"$T/err")"; rc=$?
is  "a smuggled line is rc 78" "$rc" "78"
has "and names the key"        "$(cat "$T/err")" "DESK_SESSION_KEY_FILE"
# NOT ONLY THE RC. A refusal that arrived after the lines were printed would
# still have handed the front the injected origin, so the output is asserted
# separately from the exit code.
case "$out" in
  *elsewhere.example*) bad "the injected origin was printed anyway" "$out" ;;
  *)                   ok  "the injected origin was never printed" ;;
esac

echo "== a bare control character is refused too, and it is named =="
{ printf 'HUB_HOST="h1"\nLABEL_PREFIX="com.fixture"\nSTATE_DIR_NAME="fixture-state"\n'
  printf 'OP_TOKEN_NAME="op"\nBUS_DIR_NAME="fixture-bus"\n'
  printf 'DESK_ORIGIN="https://desk.example.test"\n'
  printf 'DESK_SESSION_KEY_FILE="/var/fixture/%bkey"\n' "\\t"
} > "$ROOT/estate/steward.conf"
bash "$here/desk/bin/desk-paths" >/dev/null 2>"$T/err"; rc=$?
is  "a tab is rc 78" "$rc" "78"
has "the tab refusal names the key" "$(cat "$T/err")" "DESK_SESSION_KEY_FILE"

# ISOLATING THE `emit` BACKSTOP. The case above is caught by front_value, so it
# says nothing about the three DERIVED lines - dir, sock and providers pass
# through no key expression at all. Measured: with only the case above, removing
# `emit`\'s check cost ZERO assertions, which is rule 1\'s "unproven or genuinely
# redundant, find out which". It is not redundant - it covers lines the other
# guard never sees - so here is the case that proves it.
#
# HOME is the reachable one: a newline is a legal character in a directory name,
# and `dir=` is built from HOME without ever being validated.
echo "== a derived line cannot smuggle one either =="
{ printf 'HUB_HOST="h1"\nLABEL_PREFIX="com.fixture"\nSTATE_DIR_NAME="fixture-state"\n'
  printf 'OP_TOKEN_NAME="op"\nBUS_DIR_NAME="fixture-bus"\n'
} > "$ROOT/estate/steward.conf"
# $'\n' AND NOT $(printf '\n'): command substitution strips trailing newlines,
# so the first version of this line produced a path with NO newline in it and
# the case passed the guard it was written to trip. Rule 8, in the fixture.
NLHOME="$T/home"$'\n'"origin=https://elsewhere.example"
mkdir -p "$NLHOME"
out="$(HOME="$NLHOME" bash "$here/desk/bin/desk-paths" 2>"$T/err")"; rc=$?
is  "a newline in a derived value is rc 78" "$rc" "78"
has "and the refusal names the output key"  "$(cat "$T/err")" "dir="
case "$out" in
  *elsewhere.example*) bad "the derived line was printed anyway" "$out" ;;
  *)                   ok  "the derived line was never printed" ;;
esac

printf '\n  %d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
