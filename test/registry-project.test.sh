#!/bin/bash
# test/registry-project.test.sh — `steward registry project add`, the third
# create-only registry verb, alongside team/client add
# (test/registry-org-verbs.test.sh) and account add (test/registry-account.test.sh).
#
# Writes projects.d/<slug>.conf through the SAME shared serializer and writer
# transaction those two suites already prove (_registry_emit_kv,
# registry_row_write) via registry_project_write — a thin wrapper, not a
# second writer. THE LOAD-BEARING SECTION is the injection suite, the same
# reason registry-org-verbs.test.sh calls its own injection suite
# load-bearing: projects.d/<slug>.conf is SOURCED by registry_project_load,
# so a --name written with only quote/control validation would let a shell
# metacharacter execute or expand the moment a reader loads the row back.
#
# HERMETIC: a fresh mktemp estate per run, STEWARD_CONFIG_FILE pinned to a
# path that cannot exist.
set -u

here="$(CDPATH= cd -- "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
STEWARD="$here/bin/steward"
pass=0; fail=0
ok()  { pass=$((pass+1)); printf '  ok   %s\n' "$1"; }
bad() { fail=$((fail+1)); printf '  FAIL %s\n     %s\n' "$1" "${2:-}"; }
is()    { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "wanted '$3', got '$2'"; fi; }
has()   { case "$2" in *"$3"*) ok "$1" ;; *) bad "$1" "missing '$3' in: $2" ;; esac; }
absent(){ if [ ! -e "$2" ]; then ok "$1"; else bad "$1" "unexpectedly exists: $2"; fi; }

FX="$(mktemp -d)"; trap 'rm -rf "$FX"' EXIT
mkdir -p "$FX/estate" "$FX/entities.d" "$FX/projects.d" "$FX/sessions.d"

cat > "$FX/estate/steward.conf" <<'EOF'
ESTATE_NAME="fixture"
SCHEMA_VERSION="3"
LABEL_PREFIX="com.fixture.claude"
RC_LABEL_PREFIX="fixture: "
HUB_SESSION="fixture-hub"
HUB_HOST="h1"
HUB_SSH="a@h1"
JOB_LOG_DIR="fixture-jobs"
TMUX_SOCKET="fixture.sock"
PING_MSG="you have mail"
STATE_DIR_NAME="fixture-supervisor"
PAUSED_DIR_NAME="fixture-paused"
JOB_LABEL_PREFIX="com.fixture.job"
SERVICE_LABEL_PREFIX="com.fixture.service"
BROWSER_LABEL_PREFIX="com.fixture.browser"
OP_TOKEN_FILE_NAME="fixture-token"
EOF

ENT="$FX/entities.d"
PROJ="$FX/projects.d"

cat > "$ENT/alpha.conf" <<'EOF'
NAME="Alpha"
MEMBERS="a"
EOF

cat > "$ENT/acme.conf" <<'EOF'
NAME="Acme"
MANAGED_BY="alpha"
EOF

run() {
  STEWARD_ESTATE_ROOT="$FX" STEWARD_CONFIG_FILE="$FX/no-such-config" \
  STEWARD_VIEWER="${STEWARD_VIEWER:-a}" bash "$STEWARD" registry "$@" 2>&1
}

load_project() {
  # <slug> -> "NAME<newline>PARENT", via the register's own loader.
  (
    . "$here/lib/registry.sh"
    STEWARD_ESTATE_ROOT="$FX" registry_project_load "$1" >/dev/null 2>&1
    printf '%s\n%s' "$PROJECT_NAME" "$PROJECT_PARENT"
  )
}

echo "== 1. project add: NAME, PARENT, mode 600, loads via registry_project_load =="
out="$(run project add site --parent alpha --name "Site" --json)"; rc=$?
is "1: rc 0"        "$rc" "0"
is "1: ok true"     "$(printf '%s' "$out" | jq -r '.ok')" "true"
is "1: kind project" "$(printf '%s' "$out" | jq -r '.kind')" "project"
is "1: slug echoed" "$(printf '%s' "$out" | jq -r '.slug')" "site"
is "1: name echoed" "$(printf '%s' "$out" | jq -r '.name')" "Site"
is "1: parent echoed" "$(printf '%s' "$out" | jq -r '.parent')" "alpha"
is "1: file mode 600" "$(stat -c '%a' "$PROJ/site.conf" 2>/dev/null || stat -f '%Lp' "$PROJ/site.conf")" "600"
loaded="$(load_project site)"
is "1: loaded NAME"   "${loaded%%$'\n'*}" "Site"
is "1: loaded PARENT" "${loaded#*$'\n'}"  "alpha"

echo "== 2. parent missing (does not resolve) refuses rc 78, names it =="
out="$(run project add orphan --parent no-such-entity --name "Orphan" --json)"; rc=$?
is "2: rc 78" "$rc" "78"
is "2: ok false" "$(printf '%s' "$out" | jq -r '.ok')" "false"
has "2: reason names the parent" "$(printf '%s' "$out" | jq -r '.reason')" "no-such-entity"
absent "2: nothing written" "$PROJ/orphan.conf"

echo "== 3. parent is a valid entity (a client, not just a team) succeeds =="
out="$(run project add site2 --parent acme --name "Site Two" --json)"; rc=$?
is "3: rc 0" "$rc" "0"
is "3: ok true" "$(printf '%s' "$out" | jq -r '.ok')" "true"
loaded="$(load_project site2)"
is "3: loaded PARENT is the client" "${loaded#*$'\n'}" "acme"

echo "== 4. bad slug refuses rc 64, nothing written =="
out="$(run project add Bad_Slug --parent alpha --name "x" --json)"; rc=$?
is "4: rc 64" "$rc" "64"
absent "4: nothing written" "$PROJ/Bad_Slug.conf"

echo "== 5. --name is required =="
out="$(run project add noname --parent alpha --json)"; rc=$?
is "5: rc 64" "$rc" "64"
absent "5: nothing written" "$PROJ/noname.conf"

echo "== 6. --parent is required =="
out="$(run project add noparent --name "x" --json)"; rc=$?
is "6: rc 64" "$rc" "64"
absent "6: nothing written" "$PROJ/noparent.conf"

echo "== 7. control byte in --name refuses rc 64, nothing written =="
out="$(run project add ctrl --parent alpha --name "$(printf 'line1\nline2')" --json)"; rc=$?
is "7: rc 64" "$rc" "64"
absent "7: nothing written" "$PROJ/ctrl.conf"

echo "== 8. second add of the same slug refuses rc 65, original untouched =="
before="$(cat "$PROJ/site.conf")"
out="$(run project add site --parent alpha --name "Site Again" --json)"; rc=$?
is "8: rc 65" "$rc" "65"
has "8: reason names the file" "$(printf '%s' "$out" | jq -r '.reason')" "site.conf"
is "8: original file byte-identical afterward" "$(cat "$PROJ/site.conf")" "$before"

echo "== 9. THE INJECTION SUITE — --name carrying shell metacharacters =="
# Each case: assert (a) the verb succeeds, (b) a real registry_project_load
# of the written file reports PROJECT_NAME equal to the literal input
# byte-for-byte, (c) no side-effect marker file was created — proving
# nothing executed at write time OR at read-back time.
inj_case() { # <label> <slug> <name-literal> <marker-or-empty>
  local label="$1" slug="$2" namelit="$3" marker="$4"
  out="$(run project add "$slug" --parent alpha --name "$namelit" --json)"; rc=$?
  is "$label: rc 0"    "$rc" "0"
  is "$label: ok true" "$(printf '%s' "$out" | jq -r '.ok')" "true"
  if [ -n "$marker" ]; then
    absent "$label: no side-effect file — nothing executed" "$marker"
  fi
  local loaded_name
  loaded_name="$(
    . "$here/lib/registry.sh"
    STEWARD_ENTITY_DIR="$ENT" STEWARD_PROJECT_DIR="$PROJ" registry_project_load "$slug" >/dev/null 2>&1
    printf '%s' "$PROJECT_NAME"
  )"
  is "$label: PROJECT_NAME equals the literal input byte-for-byte" "$loaded_name" "$namelit"
  if [ -n "$marker" ]; then
    absent "$label: no side-effect file AFTER the explicit load either" "$marker"
  fi
}

MARK1="$FX/PWNED-cmdsub-$$"
inj_case "9a command-sub \$(...)" "inj-cmdsub" "\$(touch $MARK1)" "$MARK1"

MARK2="$FX/PWNED-backtick-$$"
inj_case "9b backtick" "inj-backtick" "\`touch $MARK2\`" "$MARK2"

inj_case "9c \$VAR expansion" "inj-var" '$HOME-is-not-expanded' ""

inj_case "9d backslash" "inj-backslash" 'back\slash\here' ""

echo "pass=$pass fail=$fail"
[ "$fail" -eq 0 ]
