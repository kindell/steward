#!/bin/bash
# test/estate-status-other-owner.test.sh — a session on THIS host that belongs
# to ANOTHER account must render as unknown, never as "down".
#
# THE SOCKET IS PER HOME. Homes on a shared host are closed to each other, and
# the tmux server lives in the owner's home. Asking OUR socket about THEIR
# session always answers "no such session" — and the table printed that as
# "down": an alarm in the one column a human acts on, produced by a question
# that could never have said anything else. The remote sweep already refuses to
# guess about other people's rows; the local branch has to make the same
# refusal. Measured on a hub that runs on a shared Linux host: every other
# account's session read "down" while its owner was typing in it.
#
# The form is the one the other unknowns already use — ?(who), naming what would
# have to answer — so a reader can tell "cannot see" from "is not running".
set -u
here="$(CDPATH= cd -- "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
pass=0; fail=0
ok()  { pass=$((pass+1)); printf '  ok   %s\n' "$1"; }
bad() { fail=$((fail+1)); printf '  FAIL %s\n     %s\n' "$1" "${2:-}"; }
has()     { case "$2" in *"$3"*) ok "$1" ;; *) bad "$1" "missing '$3' in:\n$2" ;; esac; }
lacks()   { case "$2" in *"$3"*) bad "$1" "found '$3' in:\n$2" ;; *) ok "$1" ;; esac; }

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

# Ours, on this host: measured against our socket.
cat > "$T/sessions.d/mine.conf" <<'EOF'
HOST="examplehost"
OWNER="exampleuser"
DOMAIN="example"
RC_LABEL="Mine"
EOF

# Someone else's, on this host: our socket cannot answer for it.
cat > "$T/sessions.d/theirs.conf" <<'EOF'
HOST="examplehost"
OWNER="otheruser"
DOMAIN="example"
RC_LABEL="Theirs"
EOF

# tmux stub: answers "no such session" for everything, so a row that is asked
# at all comes out "down". Ours is expected to; theirs must never be asked.
cat > "$T/bin/tmux" <<'EOF'
#!/bin/bash
echo "$@" >> "${TMUX_LOG:?}"
exit 1
EOF
chmod +x "$T/bin/tmux"

: > "$T/tmuxlog"
out="$( STEWARD_ESTATE_ROOT="$T" STEWARD_REGISTRY_DIR="$T/sessions.d" \
        STEWARD_SELF_HOST="examplehost" STEWARD_SELF_USER="exampleuser" \
        STEWARD_TMUX_BIN="$T/bin/tmux" TMUX_LOG="$T/tmuxlog" \
        HOME="$T/home" PATH="$T/bin:$PATH" \
        bash "$here/linux/estate-status.sh" 2>&1 )"; rc=$?

echo "estate-status: another account's session on this host"
[ "$rc" -eq 0 ] && ok "the command succeeds" || bad "the command succeeds" "rc=$rc:\n$out"

row_mine="$(printf '%s\n' "$out" | grep ' mine ' || true)"
row_theirs="$(printf '%s\n' "$out" | grep ' theirs ' || true)"

has   "our own row is measured and reads down" "$row_mine" "down"
lacks "their row does not read down"           "$row_theirs" "down"
has   "their row names who would have to answer" "$row_theirs" "?(otheruser)"
has   "their timer column is unknown too, not a dash that reads as measured" \
      "$(printf '%s' "$row_theirs" | sed 's/?(otheruser)//')" "?(otheruser)"

# THE QUESTION IS NOT EVEN ASKED. Asking our socket about their session and
# then discarding the answer would still be a query whose answer we know.
has   "tmux is asked about our own session"   "$(cat "$T/tmuxlog")" "has-session -t =mine"
lacks "tmux is never asked about their session" "$(cat "$T/tmuxlog")" "=theirs"

echo
echo "pass=$pass fail=$fail"
[ "$fail" -eq 0 ]
