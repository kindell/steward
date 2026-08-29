#!/bin/bash
# test/login-verb.test.sh — `steward login [session]`: hands the operator off
# to the runtime's own interactive login flow, carrying a fresh install the
# last step from "the agent is waiting for credentials" to "logged in"
# without a manual multiplexer dance to reach the prompt.
#
# HERMETIC: a fixture estate under a temp HOME, a hostname stub for the
# STEWARD_HOSTNAME_CMD seam, two login-binary stubs for the
# STEWARD_LOGIN_CMD_CLAUDE / STEWARD_LOGIN_CMD_OPENCODE seams, and
# STEWARD_CONFIG_FILE aimed at a path that never exists — the real operator
# config must never leak into this suite. Never a real claude or opencode
# binary, never a real terminal: every run below pipes stdin from /dev/null,
# and STEWARD_LOGIN_ASSUME_TTY is the only seam that lets a run past that.
set -u

here="$(CDPATH= cd -- "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
STEWARD="$here/bin/steward"
pass=0; fail=0
ok()   { pass=$((pass+1)); printf '  ok   %s\n' "$1"; }
bad()  { fail=$((fail+1)); printf '  FAIL %s\n     %s\n' "$1" "${2:-}"; }
is()   { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "wanted '$3', got '$2'"; fi; }
has()  { case "$2" in *"$3"*) ok "$1" ;; *) bad "$1" "missing '$3' in: $2" ;; esac; }
present() { if [ -e "$2" ]; then ok "$1"; else bad "$1" "expected to find: $2"; fi; }
absent()  { if [ -e "$2" ]; then bad "$1" "did not expect to find: $2"; else ok "$1"; fi; }

FX="$(mktemp -d)"; trap 'rm -rf "$FX"' EXIT
mkdir -p "$FX/estate" "$FX/sessions.d" "$FX/home" "$FX/bin"

printf 'LABEL_PREFIX="com.fixture.claude"\nHUB_HOST="h1"\nOP_TOKEN_FILE_NAME="fixture-token"\nHUB_SESSION="hub"\nSTATE_DIR_NAME="adapter-state"\n' \
  > "$FX/estate/steward.conf"

# The hub session itself — the target when no name is given.
printf 'HOST="h1"\nOWNER="a"\nDOMAIN="acme"\nRC_LABEL="L"\nREPO_PATH="/tmp/x"\nID="hub"\n' \
  > "$FX/sessions.d/hub.conf"

# An ordinary owned session, claude-code runtime (the default when unset).
printf 'HOST="h1"\nOWNER="a"\nDOMAIN="acme"\nRC_LABEL="L"\nREPO_PATH="/tmp/x"\nID="work"\n' \
  > "$FX/sessions.d/work.conf"

# Owned by a different operator entirely.
printf 'HOST="h1"\nOWNER="b"\nDOMAIN="acme"\nRC_LABEL="L"\nREPO_PATH="/tmp/x"\nID="theirs"\n' \
  > "$FX/sessions.d/theirs.conf"

# An OpenCode runtime session — the same shape test/opencode-session.test.sh's
# own fixture uses, so registry_load accepts it on the same terms as every
# other suite in this tree.
printf 'HOST="h1"\nOWNER="a"\nDOMAIN="acme"\nRC_LABEL="L"\nREPO_PATH="/tmp/x"\nID="oc"\nRUNTIME="opencode"\nMODEL="openai/gpt-5.3-codex"\nOPENCODE_VERSION="1.18.14"\nOPENCODE_PORT="4097"\nAUTO_APPROVE="true"\nCLAUDE_MEMORY_ROOT="/tmp/mem"\n' \
  > "$FX/sessions.d/oc.conf"

cat > "$FX/bin/hostcmd-hub" <<'EOF'
#!/bin/bash
echo h1
EOF
chmod +x "$FX/bin/hostcmd-hub"

cat > "$FX/bin/hostcmd-other" <<'EOF'
#!/bin/bash
echo h2
EOF
chmod +x "$FX/bin/hostcmd-other"

# The two runtime stubs. Each drops a marker (proof it ran at all) and
# records its own argv, then exits with a distinctive code of its own — a
# code an `exec`-based verb has no way to alter, so the test can prove the
# stub's own exit status became the whole invocation's exit status.
cat > "$FX/bin/claude-stub" <<EOF
#!/bin/bash
: > "$FX/claude.ran"
printf '%s\n' "\$@" > "$FX/claude.args"
exit 42
EOF
chmod +x "$FX/bin/claude-stub"

cat > "$FX/bin/opencode-stub" <<EOF
#!/bin/bash
: > "$FX/opencode.ran"
printf '%s\n' "\$@" > "$FX/opencode.args"
exit 43
EOF
chmod +x "$FX/bin/opencode-stub"

hub_host="$FX/bin/hostcmd-hub"
other_host="$FX/bin/hostcmd-other"
claude_stub="$FX/bin/claude-stub"
opencode_stub="$FX/bin/opencode-stub"
missing_bin="$FX/bin/does-not-exist"

clear_markers() {
  rm -f "$FX/claude.ran" "$FX/claude.args" "$FX/opencode.ran" "$FX/opencode.args"
}

# run <hostcmd> <claude-cmd> <opencode-cmd> <assume-tty:0|1> [login-args...]
#
# STDIN IS ALWAYS /dev/null. A real terminal running this suite by hand must
# see the same non-tty behavior a CI runner does; STEWARD_LOGIN_ASSUME_TTY is
# the only thing that ever lets a call here reach the runtime dispatch.
run() {
  local hostcmd="$1" claudecmd="$2" opencodecmd="$3" assumetty="$4"; shift 4
  local -a extra=()
  [ "$assumetty" = "1" ] && extra=(STEWARD_LOGIN_ASSUME_TTY=1)
  env -i PATH="$PATH" HOME="$FX/home" STEWARD_ESTATE_ROOT="$FX" \
    STEWARD_CONFIG_FILE="$FX/no-such-operator-config" \
    STEWARD_HOSTNAME_CMD="$hostcmd" STEWARD_VIEWER="a" \
    STEWARD_LOGIN_CMD_CLAUDE="$claudecmd" STEWARD_LOGIN_CMD_OPENCODE="$opencodecmd" \
    "${extra[@]+"${extra[@]}"}" \
    bash "$STEWARD" login "$@" </dev/null 2>&1
}

echo "== owned, hub-local, claude-code: the claude stub runs =="
clear_markers
out="$(run "$hub_host" "$claude_stub" "$opencode_stub" 1 work)"; rc=$?
present "claude stub ran"                 "$FX/claude.ran"
is      "claude stub got /login as its argument" "$(cat "$FX/claude.args" 2>/dev/null)" "/login"
absent  "opencode stub did not run"       "$FX/opencode.ran"
has     "announce line names the session" "$out" "work"
has     "announce line names the runtime" "$out" "claude-code"
is      "exit code is the stub's own rc"  "$rc" "42"

echo "== owned, hub-local, opencode runtime: the opencode stub runs =="
clear_markers
out="$(run "$hub_host" "$claude_stub" "$opencode_stub" 1 oc)"; rc=$?
present "opencode stub ran"                "$FX/opencode.ran"
is      "opencode stub got auth login as its arguments" \
        "$(cat "$FX/opencode.args" 2>/dev/null)" "$(printf 'auth\nlogin')"
absent  "claude stub did not run"          "$FX/claude.ran"
has     "announce line names the runtime"  "$out" "opencode"
is      "exit code is the stub's own rc"   "$rc" "43"

echo "== a session owned by someone else is refused, never run =="
clear_markers
out="$(run "$hub_host" "$claude_stub" "$opencode_stub" 1 theirs)"; rc=$?
is      "rc 77"                       "$rc" "77"
has     "refusal names the owner"     "$out" "owned by b"
absent  "claude stub did not run"     "$FX/claude.ran"
absent  "opencode stub did not run"   "$FX/opencode.ran"

echo "== a non-hub machine is refused, never run =="
clear_markers
out="$(run "$other_host" "$claude_stub" "$opencode_stub" 1 work)"; rc=$?
is      "rc 69"                        "$rc" "69"
has     "refusal names the hub"        "$out" "h1"
has     "refusal explains this machine is not it" "$out" "not it"
absent  "claude stub did not run"      "$FX/claude.ran"

echo "== no session name defaults to the estate's hub session =="
clear_markers
out="$(run "$hub_host" "$claude_stub" "$opencode_stub" 1)"; rc=$?
has     "announce line names the hub session" "$out" "hub"
present "claude stub ran"                      "$FX/claude.ran"
is      "exit code is the stub's own rc"       "$rc" "42"

echo "== an unknown session name refuses with the registry's own words =="
clear_markers
out="$(run "$hub_host" "$claude_stub" "$opencode_stub" 1 ghost)"; rc=$?
is      "rc 78"                              "$rc" "78"
has     "the registry's own refusal passes through" "$out" "unknown project"
absent  "claude stub did not run"            "$FX/claude.ran"
absent  "opencode stub did not run"          "$FX/opencode.ran"

echo "== a missing login binary refuses honestly, names the path =="
clear_markers
out="$(run "$hub_host" "$missing_bin" "$opencode_stub" 1 work)"; rc=$?
is      "rc 69"                          "$rc" "69"
has     "refusal names the missing path" "$out" "$missing_bin"
absent  "opencode stub did not run"      "$FX/opencode.ran"

echo "== no tty refuses instead of hanging =="
clear_markers
out="$(run "$hub_host" "$claude_stub" "$opencode_stub" 0 work)"; rc=$?
is      "rc 64"                            "$rc" "64"
has     "refusal explains login is interactive" "$out" "interactive"
absent  "claude stub did not run"          "$FX/claude.ran"

echo
echo "pass=$pass fail=$fail"
[ "$fail" -eq 0 ]
