#!/bin/bash
# Behavioral contract for runtime/opencode-session.sh. It runs the real adapter
# against deliberately narrow binaries, never a real OpenCode server or memory.
set -u

here="$(CDPATH= cd -- "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fx="$(mktemp -d)"
trap 'rm -rf "$fx"' EXIT

pass=0; fail=0
ok() { pass=$((pass + 1)); }
bad() { echo "FAIL: $1"; fail=$((fail + 1)); }
check() { local desc="$1"; shift; if "$@"; then ok; else bad "$desc"; fi; }
check_eq() { local desc="$1" got="$2" want="$3"; [ "$got" = "$want" ] && ok || bad "$desc (got '$got', want '$want')"; }
check_file_contains() { local desc="$1" file="$2" text="$3"; grep -F -- "$text" "$file" >/dev/null 2>&1 && ok || bad "$desc"; }
check_arg() { check_file_contains "$1" "$capture_tui" "$2"; }
mode() { stat -f '%Lp' "$1"; }

estate="$fx/estate"
home="$fx/home"
state="$fx/state"
memory="$fx/claude-memory"
repo="$fx/repo"
bin="$fx/bin"
capture_tui="$fx/tui.args"
capture_server="$fx/server.args"
capture_server_stop="$fx/server.stopped"
capture_curl="$fx/curl.args"
mkdir -p "$estate/sessions.d" "$estate/estate" "$home" "$state" "$memory/topics" "$repo" "$bin"
cat > "$estate/estate/steward.conf" <<'EOF'
LABEL_PREFIX="com.example.claude"
RC_LABEL_PREFIX="Steward: "
HUB_SESSION="hub"
HUB_HOST="hub"
JOB_LOG_DIR="jobs"
HUB_SSH="owner@hub"
TMUX_SOCKET="steward.sock"
PING_MSG="ping"
JOB_LABEL_PREFIX="com.example.job"
SERVICE_LABEL_PREFIX="com.example.service"
BROWSER_LABEL_PREFIX="com.example.browser"
OP_TOKEN_FILE_NAME="token"
STATE_DIR_NAME="adapter-state"
PAUSED_DIR_NAME="paused"
EOF

write_conf() { # <model> <memory root>
  cat > "$estate/sessions.d/steward-opencode.conf" <<EOF
REPO_PATH="$repo"
RC_LABEL=""
OWNER="tester"
DOMAIN="steward"
RUNTIME="opencode"
MODEL="$1"
OPENCODE_VERSION="1.18.14"
OPENCODE_PORT="4097"
AUTO_APPROVE="true"
CLAUDE_MEMORY_ROOT="$2"
EOF
}

printf 'durable memory\n' > "$memory/MEMORY.md"
printf 'topic memory\n' > "$memory/topics/topic.md"
write_conf "openai/gpt-5.3-codex" "$memory"

cat > "$bin/opencode" <<'EOF'
#!/bin/bash
set -u
if [ "${1:-}" = "--version" ]; then
  printf '%s\n' "${FAKE_OPENCODE_VERSION:-1.18.14}"
  exit 0
fi
if [ "${1:-}" = "serve" ]; then
  shift
  printf '%s\n' "$@" > "$FAKE_SERVER_ARGS"
  trap 'printf stopped > "$FAKE_SERVER_STOP"; exit 0' TERM INT
  while :; do sleep 1; done
fi
printf '%s\n' "$@" > "$FAKE_TUI_ARGS"
printf 'OPENCODE_CONFIG=%s\n' "${OPENCODE_CONFIG:-}" >> "$FAKE_TUI_ARGS"
printf 'OPENCODE_SERVER_PASSWORD=%s\n' "${OPENCODE_SERVER_PASSWORD:+set}" >> "$FAKE_TUI_ARGS"
EOF
chmod 755 "$bin/opencode"

cat > "$bin/curl" <<'EOF'
#!/bin/bash
set -u
printf '%s\n' "$@" >> "$FAKE_CURL_ARGS"
has_config=""
url=""
for arg in "$@"; do
  [ "$arg" = "--config" ] && has_config=1
  case "$arg" in http://127.0.0.1:4097/*) url="$arg" ;; esac
done
[ -n "$has_config" ] && IFS= read -r _credentials || true
case "$url" in
  */global/health)
    [ "${FAKE_CURL_HEALTH:-healthy}" = "healthy" ] || exit 22
    printf '%s\n' '{"healthy":true,"version":"1.18.14"}'
    ;;
  */session)
    printf '%s\n' "{\"id\":\"${FAKE_SESSION_ID:-ses_bootstrap123}\",\"title\":\"steward-opencode\"}"
    ;;
  *) exit 22 ;;
esac
EOF
chmod 755 "$bin/curl"

cat > "$bin/sleep" <<'EOF'
#!/bin/bash
exit 0
EOF
chmod 755 "$bin/sleep"

cat > "$bin/rsync-race" <<'EOF'
#!/bin/bash
"/usr/bin/rsync" "$@" || exit $?
printf 'changed during copy\n' >> "$FAKE_MEMORY_ROOT/topics/topic.md"
EOF
chmod 755 "$bin/rsync-race"

run_adapter() {
  HOME="$home" PATH="$bin:$PATH" \
  STEWARD_ESTATE_ROOT="$estate" STEWARD_REGISTRY_DIR="$estate/sessions.d" \
  STEWARD_OPENCODE_BIN="$bin/opencode" STEWARD_CURL_BIN="$bin/curl" \
  STEWARD_OPENCODE_STATE_DIR="$state" \
  FAKE_TUI_ARGS="$capture_tui" FAKE_SERVER_ARGS="$capture_server" \
  FAKE_SERVER_STOP="$capture_server_stop" FAKE_CURL_ARGS="$capture_curl" \
  FAKE_MEMORY_ROOT="$memory" \
  bash "$here/runtime/opencode-session.sh" steward-opencode
}

# The production change each assertion protects: accepting a different server,
# losing the exact session, altering Claude memory, exposing a credential, or
# silently accepting an invalid bootstrap condition.
run_adapter
first_rc=$?
check_eq "first adapter run succeeds" "$first_rc" 0
session_file="$state/steward-opencode.opencode-session"
password_file="$state/steward-opencode.opencode-password"
config_file="$state/steward-opencode.opencode.json"
instructions_file="$state/steward-opencode.opencode-instructions.md"
snapshot="$state/steward-opencode.memory"
proposals="$state/steward-opencode.memory-proposals"
check_eq "session ID is persisted exactly" "$(cat "$session_file" 2>/dev/null)" "ses_bootstrap123"
check_eq "password is 32 characters" "$(wc -c < "$password_file" 2>/dev/null | tr -d ' ')" 32
check_eq "password mode is 600" "$(mode "$password_file" 2>/dev/null)" 600
check_file_contains "temporary server binds loopback" "$capture_server" "127.0.0.1"
check_file_contains "temporary server uses registry port" "$capture_server" "4097"
check "temporary server is terminated" test -f "$capture_server_stop"
check "snapshot copies MEMORY.md" cmp "$memory/MEMORY.md" "$snapshot/MEMORY.md"
check "snapshot copies topic memory" cmp "$memory/topics/topic.md" "$snapshot/topics/topic.md"
check "proposal directory is writable" test -w "$proposals"
check_eq "snapshot file is read-only" "$(mode "$snapshot/MEMORY.md" 2>/dev/null)" 444
check_file_contains "config selects registry model" "$config_file" "openai/gpt-5.3-codex"
check_file_contains "config broadly allows normal work" "$config_file" '"*": "allow"'
check_file_contains "config allows this state directory" "$config_file" "$state"
check_file_contains "config denies snapshot edits" "$config_file" '"edit"'
check_file_contains "config denial wins beneath broad allowance" "$config_file" '"deny"'
check_file_contains "instructions name snapshot" "$instructions_file" "$snapshot"
check_file_contains "instructions name proposals" "$instructions_file" "$proposals"
check_arg "TUI receives exact session" "ses_bootstrap123"
check_arg "TUI receives auto approval" "--auto"
check_arg "TUI receives loopback hostname" "127.0.0.1"
check_arg "TUI receives registry port" "4097"
check_arg "TUI receives first model" "openai/gpt-5.3-codex"
check_file_contains "TUI receives generated config environment" "$capture_tui" "OPENCODE_CONFIG=$config_file"
check_file_contains "curl uses stdin config" "$capture_curl" "--config"
if grep -Ex -- '-u|--user' "$capture_curl" >/dev/null 2>&1; then
  bad "curl does not put Basic credentials in argv"
else
  ok
fi
if grep -F -- "$(cat "$password_file" 2>/dev/null)" "$capture_curl" "$capture_tui" >/dev/null 2>&1; then
  bad "password is absent from captures"
else
  ok
fi

chmod a-w "$proposals"
run_adapter
second_rc=$?
check_eq "second adapter run succeeds" "$second_rc" 0
check "existing proposal directory is restored writable" test -w "$proposals"
check_eq "second run does not create another API session" "$(grep -c '/session' "$capture_curl" 2>/dev/null)" 1
check_eq "second run reuses exact session" "$(cat "$session_file" 2>/dev/null)" "ses_bootstrap123"

write_conf "openai/gpt-5.5" "$memory"
run_adapter
model_rc=$?
check_eq "second valid model fixture succeeds" "$model_rc" 0
check_arg "model comes from current registry conf" "openai/gpt-5.5"

mv "$memory" "$fx/missing-memory"
run_adapter >/dev/null 2>&1
check_eq "missing memory source refuses with EX_DATAERR" "$?" 65
mv "$fx/missing-memory" "$memory"

FAKE_OPENCODE_VERSION="1.18.13" run_adapter >/dev/null 2>&1
check_eq "wrong installed OpenCode version refuses with EX_CONFIG" "$?" 78

rm -f "$session_file"
FAKE_SESSION_ID="not-a-session" run_adapter >/dev/null 2>&1
check_eq "malformed API session ID is refused" "$?" 65
check "malformed API session ID is not persisted" test ! -e "$session_file"

FAKE_CURL_HEALTH="unhealthy" run_adapter >/dev/null 2>&1
check_eq "unhealthy or occupied configured port is refused" "$?" 65
check "unhealthy temporary server is terminated" test -f "$capture_server_stop"

rm -f "$session_file"
STEWARD_RSYNC_BIN="$bin/rsync-race" run_adapter >/dev/null 2>&1
check_eq "source mutation during snapshot is refused" "$?" 65
check "source race does not create session state" test ! -e "$session_file"

echo "pass=$pass fail=$fail"
[ "$fail" -eq 0 ]
