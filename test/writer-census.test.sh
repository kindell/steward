#!/bin/bash
# test/writer-census.test.sh — a CENSUS, not a list. `steward registry
# session add` is not the only path that produces a sessions.d row, and
# under schema 6 every row must either carry a valid LOGIN or the path that
# minted it must have refused. A hand-picked list of "the writers I remember"
# goes stale the moment a new one is added; this suite instead greps the
# tree for the same signal the register's own writer uses (`sessions.d`,
# `registry_session_write`, `registry_row_write`) and checks the hit list
# against a COVERED table — path, role, reason. A path the grep finds that
# is not in the table fails the suite; a path in the table the grep no
# longer finds fails it too, because a stale table is exactly the failure
# this suite exists to catch (test/registry-library.test.sh proves the same
# shape for the library's own exports, for the same reason).
#
# THE ASSERTION IS THE OUTCOME, NOT THE SOURCE. A suite that only grepped
# for the string "LOGIN" would pass a writer that writes the field empty.
# Every WRITER row is instead EXECUTED against a fixture, and the row it
# produces is loaded through the real reader (registry_load) against a
# SCHEMA_VERSION="6" estate — rc 0, or the path refused with nothing
# written. A path that cannot know a login (a bus request with none) must
# refuse rather than mint an unloadable row.
set -u

here="$(CDPATH= cd -- "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
STEWARD="$here/bin/steward"
ENROLL="$here/linux/hub/enroll"
pass=0; fail=0
ok()  { pass=$((pass+1)); printf '  ok   %s\n' "$1"; }
bad() { fail=$((fail+1)); printf '  FAIL %s\n     %s\n' "$1" "${2:-}"; }
is()  { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "wanted '$3', got '$2'"; fi; }
has() { case "$2" in *"$3"*) ok "$1" ;; *) bad "$1" "missing '$3' in: $2" ;; esac; }

cd "$here" || { echo "cannot cd to $here" >&2; exit 70; }

# ONE TRAP FOR ALL THREE FIXTURE ROOTS — each is assigned later, in sequence,
# but the trap is registered once, up front, so a later assignment does not
# silently discard the cleanup of an earlier one (bash keeps only the LAST
# `trap ... EXIT`).
FX=""; SCFX=""; SNX=""
trap 'rm -rf "$FX" "$SCFX" "$SNX"' EXIT

# ─────────────────────────────────────────────────────────────────────────
# THE CENSUS ITSELF — grep the tree, compare against the COVERED table.
# ─────────────────────────────────────────────────────────────────────────
echo "== the census: every hit is covered, every covered entry still hits =="

FOUND_F="$(mktemp)"
grep -rln 'sessions\.d\|registry_session_write\|registry_row_write' \
  bin/steward lib/ linux/ install.sh 2>/dev/null | sort -u > "$FOUND_F"

# path::role::reason — one line per file the grep is expected to name.
# WRITER means it can mint or rewrite a sessions.d row. READER/NEIGHBOUR
# means it only reads sessions.d, or touches a different register entirely.
#
# A DOUBLE-QUOTED STRING, NOT SINGLE-QUOTED (task 9B, fix round 1, MINOR-5)
# — this table is what a future maintainer reads to decide whether a new
# grep hit is a writer, and a single-quoted string cannot carry an
# apostrophe at all: every possessive below silently lost its ' ("task 9s",
# "the hubs", "a sessions rig", "the registrys path"). Double quotes keep the
# apostrophe literal; the brief's own suggestion of `<<'EOF'` was tried
# first and DROPPED — under this repo's target shell (bash 3.2, the same
# one nav-enroll is written to run on) a `'`-quoted heredoc nested inside a
# `$(...)` command substitution mis-parses the moment its body contains an
# apostrophe ("unexpected EOF while looking for matching `''`"), a bash 3.2
# parser bug independent of this file. Measured directly: `X=$(cat <<'EOF'
# ... it's ... EOF)` fails that way on this machine's bash 3.2.57; the same
# text as a plain double-quoted assignment does not, since nothing here is
# `$`, a backtick or a `"` that double quotes would need escaping.
COVERED_TABLE="bin/steward::writer::cmd_registry_session_add (task 9's --login gate) and cmd_registry_migrate_session (LOGIN carried below)
lib/registry.sh::core::registry_row_write/registry_session_write and registry_login_principal_gate live here; not itself a session-row writer
lib/scaffold.sh::writer::estate_scaffold mints a NEW estate's sessions.d/accounts.d/logins.d, not a session row
linux/session-new.sh::requester::composes the ENROLL-REQUEST the hub's enroll writes; never touches sessions.d itself
linux/hub/enroll::writer::the hub's registration path, writes a session row from a bus request
linux/hub/bus-send::reader::validates a recipient against sessions.d, writes nothing
linux/hub/lib.sh::reader::resolves hub/session paths against sessions.d, writes nothing
linux/browser-stack.sh::reader::reads sessions.d to find a session's rig, writes browsers.d not sessions.d
linux/session-supervisor-linux.sh::reader::reads sessions.d to supervise, writes nothing to it
linux/deploy-self.sh::reader::reconciles the runtime sessions.d against the checkout, does not mint a row
install.sh::messenger::prints the registry's path as an install hint (one line), writes no row"

# every grep hit must be named in the table
while IFS= read -r f; do
  [ -n "$f" ] || continue
  if printf '%s\n' "$COVERED_TABLE" | grep -qE "^${f}::"; then
    ok "grep hit is covered: $f"
  else
    bad "grep hit is covered: $f" "UNLISTED — a new sessions.d writer or reader with no census entry"
  fi
done < "$FOUND_F"

# every table entry must still be a live hit — a stale entry is the failure
# this suite exists to catch just as much as a missing one.
while IFS= read -r line; do
  [ -n "$line" ] || continue
  path="${line%%::*}"
  if grep -qxF "$path" "$FOUND_F"; then
    ok "COVERED entry still matches the grep: $path"
  else
    bad "COVERED entry still matches the grep: $path" "STALE — the grep no longer finds it"
  fi
done <<EOF
$COVERED_TABLE
EOF

n_found="$(wc -l < "$FOUND_F" | tr -d ' ')"
n_table="$(printf '%s\n' "$COVERED_TABLE" | grep -c '::')"
is "the grep and the table name the same number of files" "$n_found" "$n_table"
rm -f "$FOUND_F"

# ─────────────────────────────────────────────────────────────────────────
# SHARED FIXTURE — one schema-6 estate, reused by the writer proofs below.
# ─────────────────────────────────────────────────────────────────────────
FX="$(mktemp -d)"
mkdir -p "$FX/estate" "$FX/sessions.d" "$FX/entities.d" "$FX/projects.d" \
         "$FX/accounts.d" "$FX/logins.d" "$FX/hosts.d" "$FX/checkout/sessions.d" \
         "$FX/bus/bin" "$FX/bin"

cat > "$FX/estate/steward.conf" <<'EOF'
ESTATE_NAME="census"
SCHEMA_VERSION="6"
LABEL_PREFIX="com.census.claude"
RC_LABEL_PREFIX="census: "
HUB_SESSION="hub"
HUB_HOST="h1"
HUB_SSH="alice@h1"
JOB_LOG_DIR="census-jobs"
TMUX_SOCKET="census.sock"
PING_MSG="you have mail"
STATE_DIR_NAME="census-supervisor"
PAUSED_DIR_NAME="census-paused"
JOB_LABEL_PREFIX="com.census.job"
SERVICE_LABEL_PREFIX="com.census.service"
BROWSER_LABEL_PREFIX="com.census.browser"
OP_TOKEN_FILE_NAME="census-token"
EOF

cat > "$FX/hosts.d/h1.conf" <<'EOF'
OWNER="alice"
LEGAL_OWNER="Acme Corp"
OPERATOR="alice"
EOF

cat > "$FX/entities.d/acme.conf" <<'EOF'
NAME="Acme"
EOF

printf 'PRINCIPAL="alice"\nHOST="h1"\n' > "$FX/accounts.d/acct-acme-team.conf"

cat > "$FX/logins.d/acme-team.conf" <<'EOF'
PRINCIPAL="alice"
ACCOUNT="acme-team-seat"
PROVIDER="claude-team"
CONFIG_DIR="~/.claude-logins/acme-team"
LEGAL_OWNER="Acme Corp"
EOF
chmod 600 "$FX/logins.d/acme-team.conf"

printf '#!/bin/bash\n' > "$FX/bus/bin/bus-relay-in"; chmod +x "$FX/bus/bin/bus-relay-in"
printf '#!/bin/bash\nexit 0\n' > "$FX/bin/send"; chmod +x "$FX/bin/send"
: > "$FX/authorized_keys"

# load_session <id> — the real reader, the census's own proof that a
# produced row is not merely present but LOADABLE at schema 6.
load_session() {
  (
    export STEWARD_ESTATE_ROOT="$FX" STEWARD_CONFIG_FILE="$FX/no-such-config"
    # shellcheck source=/dev/null
    . "$here/lib/registry.sh"
    registry_load "$1" >/dev/null 2>&1 || exit 1
    printf '%s' "$LOGIN"
  )
}

# ─────────────────────────────────────────────────────────────────────────
# WRITER: steward registry session add
# ─────────────────────────────────────────────────────────────────────────
echo "== writer: steward registry session add =="
out="$( STEWARD_ESTATE_ROOT="$FX" STEWARD_CONFIG_FILE="$FX/no-such-config" \
        bash "$STEWARD" registry session add --account acct-acme-team \
        --login acme-team --entity acme --slug census-add --repo /tmp/fixture-repo-census --json )"
rc=$?
is "session add: rc 0" "$rc" "0"
id_add="$(printf '%s' "$out" | sed -n 's/.*"id":"\([^"]*\)".*/\1/p')"
is "session add: the loaded row carries LOGIN" "$(load_session "$id_add")" "acme-team"

# ─────────────────────────────────────────────────────────────────────────
# WRITER: steward registry migrate-session — an old-shape row that already
# carried a hand-set LOGIN must not lose it across the cut.
# ─────────────────────────────────────────────────────────────────────────
echo "== writer: steward registry migrate-session =="
cat > "$FX/sessions.d/census-old.conf" <<'EOF'
HOST="h1"
OWNER="someone"
DOMAIN="acme"
RC_LABEL="Old"
REPO_PATH="/tmp/fixture-repo-census-old"
LOGIN="acme-team"
EOF
out="$( STEWARD_ESTATE_ROOT="$FX" STEWARD_CONFIG_FILE="$FX/no-such-config" \
        bash "$STEWARD" registry migrate-session census-old \
        --account acct-acme-team --entity acme --slug census-mig --json )"
rc=$?
is "migrate-session: rc 0" "$rc" "0"
id_mig="$(printf '%s' "$out" | sed -n 's/.*"id":"\([^"]*\)".*/\1/p')"
is "migrate-session: LOGIN carried through, and the row loads at schema 6" \
   "$(load_session "$id_mig")" "acme-team"

# ─────────────────────────────────────────────────────────────────────────
# WRITER: linux/hub/enroll — a request that names a login it may carry
# loads; a request that names none, against a schema-6 estate, refuses with
# NOTHING written.
# ─────────────────────────────────────────────────────────────────────────
echo "== writer: linux/hub/enroll =="
cat > "$FX/sessions.d/asker.conf" <<'EOF'
HOST="h1"
OWNER="alice"
DOMAIN="acme"
RC_LABEL="Asker"
REPO_PATH="/tmp/fixture-repo-asker"
ID="asker"
EOF

run_enroll() { # <request-file>
  STEWARD_ESTATE_ROOT="$FX" STEWARD_REGISTRY_DIR="$FX/sessions.d" \
  STEWARD_RELAY_ROOT="$FX" STEWARD_AUTHORIZED_KEYS="$FX/authorized_keys" \
  STEWARD_BUS_SEND="$FX/bin/send" STEWARD_ENROLL_FROM=asker \
  bash "$ENROLL" --send < "$1" 2>&1
}
sess_snapshot() { ( cd "$FX/sessions.d" && find . -type f -name '*.conf' -exec shasum {} \; | sort ); }

req_ok="$FX/req-ok.txt"
cat > "$req_ok" <<'EOF'
DRIFT enroll: acme-gizmo-alice requests registration
ENROLL-REQUEST v1
namn=acme-gizmo-alice
doman=acme
projekt=gizmo
person=alice
vard=h1
repo=/srv/homes/alice/Projects/gizmo
login=acme-team
pubkey=ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIFAKEKEYCENSUSOKAAAAAAAAAAAAAAAAAAAAA census-ok
EOF
out="$(run_enroll "$req_ok")"; rc=$?
is "enroll: a request naming its login registers, rc 0" "$rc" "0"
id_enr="$(printf '%s' "$out" | sed -n 's/.*registered as \(s-[0-9a-f]\{16\}\).*/\1/p' | head -1)"
is "enroll: the loaded row carries LOGIN" "$(load_session "$id_enr")" "acme-team"

before="$(sess_snapshot)"
req_nologin="$FX/req-nologin.txt"
sed '/^login=/d' "$req_ok" \
  | sed 's/^namn=.*/namn=acme-widget-alice/; s/^projekt=.*/projekt=widget/' \
  | sed 's/CENSUSOKAAAA/CENSUSNOAAAA/' \
  > "$req_nologin"
out="$(run_enroll "$req_nologin")"; rc=$?
is "enroll: a request with no login refuses at schema 6" "$rc" "65"
has "enroll: the refusal names the missing field" "$out" "login"
after="$(sess_snapshot)"
is "enroll: the schema-6 refusal wrote nothing — sessions.d unchanged" "$after" "$before"

# ─────────────────────────────────────────────────────────────────────────
# WRITER (of an ESTATE, not a session row): lib/scaffold.sh — a fresh
# estate must carry accounts.d and logins.d from birth, or the very first
# session resolved against it cannot find its principal or its login.
# ─────────────────────────────────────────────────────────────────────────
echo "== writer: lib/scaffold.sh (estate_scaffold) =="
# shellcheck source=/dev/null
. "$here/lib/scaffold.sh"
SCFX="$(mktemp -d)"
estate_scaffold "$SCFX/e" org=acme team=acme-team owner=alice session=hub >/dev/null
rc=$?
is "scaffold: rc 0" "$rc" "0"
[ -d "$SCFX/e/accounts.d" ] && ok "scaffold: accounts.d exists from birth" \
  || bad "scaffold: accounts.d exists from birth" "missing"
[ -d "$SCFX/e/logins.d" ] && ok "scaffold: logins.d exists from birth" \
  || bad "scaffold: logins.d exists from birth" "missing"
( export STEWARD_ESTATE_ROOT="$SCFX/e"
  # shellcheck source=/dev/null
  . "$here/lib/registry.sh"
  registry_login_list >/dev/null 2>&1
)
is "scaffold: registry_login_list rc 0 on the fresh, empty register" "$?" "0"

# ─────────────────────────────────────────────────────────────────────────
# REQUESTER, NOT A WRITER: linux/session-new.sh composes the request the
# hub's enroll writes. --login <slug> wins when given; otherwise the
# requesting session's own LOGIN (in $EGEN) is carried forward.
#
# A REAL tmux pane is not available in a hermetic fixture, so `tmux` is
# stubbed on PATH — the script's only tmux call is
# `tmux display-message -p -t "$TMUX_PANE" '#S'` to learn its own session
# name, and a fixed answer there is exactly as good as a real pane for
# proving what session-new does with the name once it has it.
# ─────────────────────────────────────────────────────────────────────────
echo "== requester: linux/session-new.sh — login=<slug> on the wire =="
SNX="$(mktemp -d)"
mkdir -p "$SNX/bin" "$SNX/estate" "$SNX/sessions.d" "$SNX/ssh" "$SNX/state" "$SNX/repo" "$SNX/repo2"
cat > "$SNX/estate/steward.conf" <<'EOF'
RC_LABEL_PREFIX="census: "
HUB_SESSION="hub"
HUB_HOST="h1"
EOF
cat > "$SNX/sessions.d/requester.conf" <<'EOF'
HOST="h1"
OWNER="alice"
DOMAIN="acme"
LOGIN="acme-team"
EOF
( cd "$SNX/repo" && git init -q )
( cd "$SNX/repo2" && git init -q )

printf '#!/bin/bash\nif [ "$1" = "display-message" ]; then echo requester; fi\n' \
  > "$SNX/bin/tmux"
chmod +x "$SNX/bin/tmux"
printf '#!/bin/bash\ncat > "%s/captured.txt"\n' "$SNX" > "$SNX/bin/send"
chmod +x "$SNX/bin/send"

run_session_new() { # extra args...
  PATH="$SNX/bin:$PATH" \
  STEWARD_ESTATE_ROOT="$SNX" STEWARD_SESSIONS_D="$SNX/sessions.d" \
  STEWARD_REGISTRY_LIB="$here/lib/registry.sh" \
  STEWARD_SSH_DIR="$SNX/ssh" STEWARD_ENROLL_STATE_DIR="$SNX/state" \
  STEWARD_BUS_SEND="$SNX/bin/send" TMUX_PANE="fixture-pane" \
  bash "$here/linux/session-new.sh" "$@" >/dev/null 2>&1
}

rm -f "$SNX/captured.txt"
run_session_new gizmo "$SNX/repo"
has "session-new: falls back to the requesting session's own LOGIN" \
    "$(cat "$SNX/captured.txt" 2>/dev/null)" "login=acme-team"

rm -f "$SNX/captured.txt"
run_session_new --login other-team gizmo2 "$SNX/repo2"
has "session-new: --login wins over the requester's own LOGIN" \
    "$(cat "$SNX/captured.txt" 2>/dev/null)" "login=other-team"

echo
printf 'pass=%s fail=%s\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
