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


printf '\n  %d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
