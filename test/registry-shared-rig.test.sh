#!/bin/bash
# test/registry-shared-rig.test.sh - BROWSER_RIG="shared": one row owns a rig,
# others name it and start nothing.
#
# WHY. Two rows each declared "I have a rig on screen 24" - the same display,
# CDP and VNC - in an attempt to make two runtimes on one client share a
# browser. That is not one shared rig, it is two claims on one number:
# browser-stack refused the whole account, and after a VNC password change two
# rigs failed to come back while the tunnel went on listening on the port with
# nothing behind it. The outage looked like a network fault to the person.
# Measured 2026-09-07, found by the session whose rig it was.
#
# FOUR CLAIMS:
#   1. A borrower names the owner and carries no numbers.
#   2. A borrower that repeats the numbers is refused - that is the collision.
#   3. An owner name without the shared mode is refused: a row either owns a rig
#      or names the row that does.
#   4. The mode is a closed set, so a typo cannot become a third meaning.
set -u
here="$(CDPATH= cd -- "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
pass=0; fail=0
ok()  { pass=$((pass+1)); printf '  ok   %s\n' "$1"; }
bad() { fail=$((fail+1)); printf '  FAIL %s\n     %s\n' "$1" "${2:-}"; }
is()  { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "wanted '$3', got '$2'"; fi; }
has() { case "$2" in *"$3"*) ok "$1" ;; *) bad "$1" "missing '$3' in: $2" ;; esac; }

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
ROOT="$T/estate"
mkdir -p "$ROOT/estate" "$ROOT/sessions.d" "$ROOT/entities.d" "$ROOT/accounts.d" "$ROOT/projects.d" "$ROOT/mcp.d"
cat > "$ROOT/estate/steward.conf" <<'EOF'
ESTATE_NAME="fixture"
LABEL_PREFIX="com.fixture.claude"
JOB_LABEL_PREFIX="com.fixture.job"
SERVICE_LABEL_PREFIX="com.fixture.svc"
RC_LABEL_PREFIX=""
HUB_SESSION="hub"
HUB_HOST="h1"
STATE_DIR_NAME="fixture-supervisor"
PAUSED_DIR_NAME="fixture-paused"
TMUX_SOCKET="fixture.sock"
OP_TOKEN_FILE_NAME="fixture-token"
PING_MSG="you have unread mail"
EOF
printf 'NAME="Alpha"\nMEMBERS="a"\n' > "$ROOT/entities.d/alpha.conf"
printf 'PRINCIPAL="a"\nHOST="h1"\n' > "$ROOT/accounts.d/a-h1.conf"

row() { # <id> <extra lines>
  cat > "$ROOT/sessions.d/$1.conf" <<EOF
ID="$1"
ACCOUNT="a-h1"
SLUG="$1-slug"
TARGET_ENTITY="alpha"
DOMAIN="alpha"
HOST="h1"
REPO_PATH="$T"
OWNER="a"
RC_LABEL="A"
$2
EOF
}
load() { ( STEWARD_ESTATE_ROOT="$ROOT" bash -c ". '$here/lib/registry.sh'; registry_load '$1' >/dev/null" ) 2>&1; }
rc_of() { ( STEWARD_ESTATE_ROOT="$ROOT" bash -c ". '$here/lib/registry.sh'; registry_load '$1' >/dev/null 2>&1" ); echo $?; }

echo "registry shared rig"

row s-owner 'BROWSER_RIG="yes"
BROWSER_DISPLAY="24"
BROWSER_CDP="9327"
BROWSER_VNC="5924"
BROWSER_PROFILE="acme"'
is "an owner still loads" "$(rc_of s-owner)" "0"

row s-borrow 'BROWSER_RIG="shared"
BROWSER_RIG_OWNER="s-owner-slug"'
is "a borrower that names the owner loads" "$(rc_of s-borrow)" "0"

row s-copycat 'BROWSER_RIG="shared"
BROWSER_RIG_OWNER="s-owner-slug"
BROWSER_DISPLAY="24"
BROWSER_CDP="9327"
BROWSER_VNC="5924"'
is  "a borrower that repeats the numbers is refused" "$(rc_of s-copycat)" "1"
has "and the refusal says the numbers belong to the owner" "$(load s-copycat)" "belong to 's-owner-slug'"

row s-nameless 'BROWSER_RIG="shared"'
is  "shared without an owner is refused" "$(rc_of s-nameless)" "1"
has "and the refusal names the missing field" "$(load s-nameless)" "BROWSER_RIG_OWNER"

row s-stray 'BROWSER_RIG_OWNER="s-owner-slug"'
is  "an owner name without the mode is refused" "$(rc_of s-stray)" "1"
has "and says a row either owns or names" "$(load s-stray)" "either owns a rig or names"

row s-typo 'BROWSER_RIG="share"
BROWSER_RIG_OWNER="s-owner-slug"'
is  "a typo in the mode is refused" "$(rc_of s-typo)" "1"
has "and the allowed values are named" "$(load s-typo)" "'yes', 'shared' or unset"

printf '\n  %d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
