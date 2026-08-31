#!/bin/bash
# test/estate-status-runtime.test.sh — the status table must say WHICH RUNTIME a
# session runs, and on which model.
#
# WHY THE COLUMNS EXIST. Until now every session in the table was a Claude
# session, so the runtime was implicit and correct by accident. Once a second
# runtime lives on the same machine, a reader cannot tell from the table whether
# a down session is a Claude session that died or an OpenCode session that was
# never dispatched — and those need different repairs. An implicit fact stops
# being true the moment there are two of something.
#
# READ, NEVER SOURCED. The conf is parsed with the same non-executing `sed` the
# host and owner columns already use. A read-only status command must not
# execute estate session files: sourcing them would run whatever they contain,
# on a machine that carries several people's sessions.
#
# THE DEFAULTS ARE PART OF THE CONTRACT. A conf without RUNTIME is a Claude
# session — every existing conf predates the field, and rendering them as "?"
# would make a healthy estate look unmeasured. A missing MODEL renders "-" and
# not empty, because a blank cell in a column-aligned table reads as a rendering
# fault rather than as "this runtime has no model".
set -u
here="$(CDPATH= cd -- "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
pass=0; fail=0
ok()  { pass=$((pass+1)); printf '  ok   %s\n' "$1"; }
bad() { fail=$((fail+1)); printf '  FAIL %s\n     %s\n' "$1" "${2:-}"; }
has()     { case "$2" in *"$3"*) ok "$1" ;; *) bad "$1" "missing '$3' in:\n$2" ;; esac; }

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
mkdir -p "$T/sessions.d" "$T/estate" "$T/bin" "$T/home/.tmux"

cat > "$T/estate/steward.conf" <<'EOF'
LABEL_PREFIX="com.example.claude"
RC_LABEL_PREFIX="Example: "
HUB_SESSION="examplehub"
HUB_HOST="examplehost"
STATE_DIR_NAME="example-supervisor"
PAUSED_DIR_NAME="example-paused"
JOB_LOG_DIR="example-jobs"
TMUX_SOCKET="example.sock"
EOF

# THE NAMES DO NOT CARRY THE ANSWER. The fixture first named these sessions
# after their runtimes, and "the row carries its runtime" then passed because the
# NAME contained the word — a test measuring its own fixture. Neutral names force
# the check to read the column.
#
# A DEFAULT CLAUDE CONF: no RUNTIME line at all, like every conf that exists.
cat > "$T/sessions.d/alfa.conf" <<'EOF'
HOST="examplehost"
OWNER="exampleuser"
DOMAIN="example"
RC_LABEL="Example Claude"
EOF

# An OpenCode conf with a model.
cat > "$T/sessions.d/beta.conf" <<'EOF'
HOST="examplehost"
OWNER="exampleuser"
DOMAIN="example"
RC_LABEL="Example OpenCode"
RUNTIME="opencode"
MODEL="openai/gpt-5.3-codex"
EOF

# tmux stub: both sessions are up. The exact form =name must be preserved.
cat > "$T/bin/tmux" <<'EOF'
#!/bin/bash
echo "$@" >> "${TMUX_LOG:?}"
case "$*" in *has-session*) exit 0 ;; esac
exit 0
EOF
chmod +x "$T/bin/tmux"

: > "$T/tmuxlog"
out="$( STEWARD_ESTATE_ROOT="$T" STEWARD_REGISTRY_DIR="$T/sessions.d" \
        STEWARD_SELF_HOST="examplehost" STEWARD_SELF_USER="exampleuser" \
        STEWARD_TMUX_BIN="$T/bin/tmux" TMUX_LOG="$T/tmuxlog" \
        HOME="$T/home" PATH="$T/bin:$PATH" \
        bash "$here/linux/estate-status.sh" 2>&1 )"; rc=$?

echo "estate-status: runtime and model"
[ "$rc" -eq 0 ] && ok "the command succeeds" || bad "the command succeeds" "rc=$rc:\n$out"

has "the header carries RUNTIME"     "$out" "RUNTIME"
has "the header carries MODEL"       "$out" "MODEL"
has "the OpenCode row carries model" "$out" "openai/gpt-5.3-codex"

# THE DEFAULT: a conf with no RUNTIME line is a Claude session, not an unknown.
row_claude="$(printf '%s\n' "$out" | grep alfa || true)"
case "$row_claude" in
  *claude-code*) ok "a conf without RUNTIME renders as claude-code" ;;
  *) bad "a conf without RUNTIME does not render as claude-code" "row: '$row_claude'" ;;
esac
case "$row_claude" in
  *"?"*) bad "a conf without RUNTIME renders as unknown — the default is the contract" "row: '$row_claude'" ;;
  *) ok "a conf without RUNTIME is not unknown" ;;
esac
# THE MODEL COLUMN, NOT ANY DASH. The timer column already carries "-", so a bare
# search for a dash passed before the column existed.
case "$row_claude" in
  *"claude-code"*" - "*|*"claude-code"*" -") ok "a missing model renders as - AFTER the runtime" ;;
  *) bad "a missing model does not render as - after the runtime" "row: '$row_claude'" ;;
esac

row_oc="$(printf '%s\n' "$out" | grep beta || true)"
case "$row_oc" in
  *opencode*) ok "the OpenCode row carries its runtime" ;;
  *) bad "the OpenCode row does not carry its runtime" "row: '$row_oc'" ;;
esac

# THE EXISTING COLUMNS MUST NOT BE LOST. New fields that push old ones out are a
# silent regression: the table looks complete and lacks what one came for.
has "ownership is still marked" "$out" "*"
has "the tmux state remains"    "$out" "up"
has "RC_LABEL remains"          "$out" "Example Claude"

# THE EXACT FORM =name IS AN INVARIANT, not a detail: tmux prefix-matches, and a
# session whose name prefixes a sibling's would borrow the sibling's answer.
has "tmux is asked with the exact form" "$(cat "$T/tmuxlog")" "has-session -t =alfa"

# THE CONF MUST NOT BE EXECUTED. A command that only reads status must not run
# estate session files — they may contain anything, and the machine carries
# several people's sessions.
cat > "$T/sessions.d/dangerous.conf" <<'EOF'
HOST="examplehost"
OWNER="exampleuser"
DOMAIN="example"
RC_LABEL="Dangerous"
RUNTIME="claude-code"
EOF
printf 'touch "%s/WAS_EXECUTED"\n' "$T" >> "$T/sessions.d/dangerous.conf"
STEWARD_ESTATE_ROOT="$T" STEWARD_REGISTRY_DIR="$T/sessions.d" \
  STEWARD_SELF_HOST="examplehost" STEWARD_SELF_USER="exampleuser" \
  STEWARD_TMUX_BIN="$T/bin/tmux" TMUX_LOG="$T/tmuxlog" \
  HOME="$T/home" PATH="$T/bin:$PATH" \
  bash "$here/linux/estate-status.sh" >/dev/null 2>&1
[ -f "$T/WAS_EXECUTED" ] && bad "the conf WAS EXECUTED — status must only read" \
                         || ok "the conf was read without being executed"

echo "== a new-shape row derives its display without executing anything =="
# The naming model stores a REFERENCE, not a label line. "(no label line)"
# told the truth about the file and a lie about the session. The walk must be
# sed-only (the executed-canary guards it like every other read here), bounded,
# and fall back to "(derived)" on any anomaly rather than inventing a name.
mkdir -p "$T/entities.d" "$T/projects.d"
printf 'NAME="Alpha"\nMEMBERS="a"\n' > "$T/entities.d/alpha.conf"
printf 'NAME="Client"\nMANAGED_BY="alpha"\n' > "$T/entities.d/client.conf"
printf 'NAME="Site"\nPARENT="client"\n' > "$T/projects.d/site.conf"
cat > "$T/sessions.d/s-00000000000000aa.conf" <<'EOF'
ID="s-00000000000000aa"
ACCOUNT="a-h"
SLUG="hub"
TARGET_ENTITY="alpha"
OWNER="a"
REPO_PATH="/tmp/x"
EOF
cat > "$T/sessions.d/s-00000000000000bb.conf" <<'EOF'
ID="s-00000000000000bb"
ACCOUNT="a-h"
SLUG="web"
TARGET_PROJECT="site"
OWNER="a"
REPO_PATH="/tmp/x"
EOF
cat > "$T/sessions.d/s-00000000000000cc.conf" <<'EOF'
ID="s-00000000000000cc"
ACCOUNT="a-h"
SLUG="broken"
TARGET_ENTITY="no-such-ent"
OWNER="a"
REPO_PATH="/tmp/x"
EOF
out="$( STEWARD_ESTATE_ROOT="$T" STEWARD_REGISTRY_DIR="$T/sessions.d"         STEWARD_TMUX_BIN="$T/bin/tmux" PATH="$T/bin:$PATH"         bash "$here/linux/estate-status.sh" 2>&1 )"
case "$out" in *"Alpha"*) ok "entity target derives Alpha" ;; *) bad "entity target derives Alpha" "$out" ;; esac
case "$out" in *"Alpha→Client→Site"*) ok "project target walks the chain root→leaf" ;; *) bad "project target walks the chain root→leaf" "$out" ;; esac
case "$out" in *"(derived)"*) ok "unresolvable target says (derived), never invents" ;; *) bad "unresolvable target says (derived)" "$out" ;; esac
case "$out" in *"(no label line)"*) bad "the old file-truth label is gone" "$out" ;; *) ok "the old file-truth label is gone" ;; esac
rm -f "$T/sessions.d/s-000000000000"??".conf"

echo
printf 'pass=%s fail=%s\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
