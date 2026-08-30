#!/bin/bash
# test/registry-org-verbs.test.sh — the two create-only org verbs,
# `steward registry team add` and `steward registry client add`.
#
# THE LOAD-BEARING SECTION IS THE INJECTION SUITE. entities.d/<slug>.conf is
# SOURCED by registry_entity_load — a NAME written with only quote/control
# validation would let `$(cmd)`, a backtick, `$VAR` or a bare backslash
# execute or expand the moment a reader loads the row back. Both verbs route
# every field through the ONE serializer in lib/registry.sh
# (_registry_emit_kv); this suite proves that serializer closes the hole
# rather than trusting the escaping logic by inspection.
#
# HERMETIC: a fresh mktemp estate per run, STEWARD_CONFIG_FILE pinned to a
# path that cannot exist, STEWARD_VIEWER set explicitly wherever the default-
# member path is not itself under test.
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
mkdir -p "$FX/estate" "$FX/entities.d" "$FX/sessions.d"

# THE ESTATE FILE, THE SAME SHAPE test/sessions-command.test.sh USES, filled
# out to the full required set _registry_estate_value's callers need — the
# org verbs source lib/registry.sh, and a half-built estate would make every
# refusal below a fixture bug instead of a measurement of the verb.
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

CONF="$FX/entities.d"

# run <args...> — a hermetic invocation. STEWARD_CONFIG_FILE is aimed at a
# path that cannot exist, so the operator config never contributes a value
# the fixture did not set.
run() {
  STEWARD_ESTATE_ROOT="$FX" STEWARD_CONFIG_FILE="$FX/no-such-config" \
  STEWARD_VIEWER="${STEWARD_VIEWER:-a}" bash "$STEWARD" registry "$@" 2>&1
}
runj() { run "$@"; }

echo "== 1. team add: NAME, default MEMBERS, mode, round trip =="
out="$(run team add acme --name "Acme Corp" --json)"; rc=$?
is "1: rc 0"                "$rc" "0"
is "1: ok true"              "$(printf '%s' "$out" | jq -r '.ok')" "true"
is "1: kind team"            "$(printf '%s' "$out" | jq -r '.kind')" "team"
is "1: slug echoed"          "$(printf '%s' "$out" | jq -r '.slug')" "acme"
is "1: membersSource default" "$(printf '%s' "$out" | jq -r '.membersSource')" "default"
is "1: file mode 600"        "$(stat -f '%Lp' "$CONF/acme.conf" 2>/dev/null || stat -c '%a' "$CONF/acme.conf")" "600"
(
  NAME=""; MEMBERS=""
  # shellcheck source=/dev/null
  . "$CONF/acme.conf"
  [ "$NAME" = "Acme Corp" ] && [ "$MEMBERS" = "a" ]
)
is "1: loads back — NAME=--name, MEMBERS defaults to the viewer" "$?" "0"

echo "== 2. team add: --member repeated (not CSV), overrides the default =="
out="$(run team add beta --name "Beta Team" --member a --member b --json)"; rc=$?
is "2: rc 0" "$rc" "0"
is "2: membersSource flags" "$(printf '%s' "$out" | jq -r '.membersSource')" "flags"
(
  MEMBERS=""
  . "$CONF/beta.conf"
  [ "$MEMBERS" = "a b" ]
)
is "2: MEMBERS is space-joined 'a b'" "$?" "0"

echo "== 3. team add: missing --name refuses rc 64, nothing written =="
out="$(run team add gamma --json)"; rc=$?
is "3: rc 64" "$rc" "64"
is "3: ok false" "$(printf '%s' "$out" | jq -r '.ok')" "false"
absent "3: nothing written" "$CONF/gamma.conf"

echo "== 4. team add: duplicate slug refuses rc 65, names the file, leaves it untouched =="
before="$(cat "$CONF/acme.conf")"
out="$(run team add acme --name "Acme Again" --json)"; rc=$?
is "4: rc 65" "$rc" "65"
has "4: reason names the file" "$(printf '%s' "$out" | jq -r '.reason')" "acme.conf"
is "4: the original file is byte-identical afterward" "$(cat "$CONF/acme.conf")" "$before"

echo "== 5. bad slug / bad member: rc 64, nothing written =="
out="$(run team add Bad_Slug --name "x" --json)"; rc=$?
is "5: bad slug rc 64" "$rc" "64"
absent "5: bad slug — nothing written" "$CONF/Bad_Slug.conf"
out="$(run team add deltateam --name "x" --member Not_Ok --json)"; rc=$?
is "5: bad member rc 64" "$rc" "64"
absent "5: bad member — nothing written" "$CONF/deltateam.conf"

echo "== 6. client add: MANAGED_BY set, round trip =="
out="$(run client add acme-client --managed-by acme --name "Acme Client" --json)"; rc=$?
is "6: rc 0" "$rc" "0"
is "6: kind client" "$(printf '%s' "$out" | jq -r '.kind')" "client"
is "6: managedBy echoed" "$(printf '%s' "$out" | jq -r '.managedBy')" "acme"
(
  NAME=""; MANAGED_BY=""
  . "$CONF/acme-client.conf"
  [ "$NAME" = "Acme Client" ] && [ "$MANAGED_BY" = "acme" ]
)
is "6: loads back with MANAGED_BY" "$?" "0"

echo "== 7. client add: manager missing refuses rc 78, names it =="
out="$(run client add orphan --managed-by ghost-team --name "X" --json)"; rc=$?
is "7: rc 78" "$rc" "78"
has "7: reason names the manager" "$(printf '%s' "$out" | jq -r '.reason')" "ghost-team"
absent "7: nothing written" "$CONF/orphan.conf"

echo "== 8. client add: manager exists but has NO members — not a team, rc 78 =="
printf 'NAME="Solo"\n' > "$CONF/solo.conf"
out="$(run client add cli-solo --managed-by solo --name "X" --json)"; rc=$?
is "8: rc 78" "$rc" "78"
has "8: reason says not a team" "$(printf '%s' "$out" | jq -r '.reason')" "not a team"
absent "8: nothing written" "$CONF/cli-solo.conf"

echo "== 9. end to end: a session's DOMAIN resolves to the client via a real 'steward sessions --json' =="
printf 'HOST="h1"\nOWNER="a"\nDOMAIN="acme-client"\nRC_LABEL="L"\nREPO_PATH="/tmp/x"\nID="s1"\n' \
  > "$FX/sessions.d/s1.conf"
sj="$(STEWARD_ESTATE_ROOT="$FX" STEWARD_REGISTRY_DIR="$FX/sessions.d" \
      STEWARD_CONFIG_FILE="$FX/no-such-config" STEWARD_VIEWER="a" \
      bash "$STEWARD" sessions --json 2>&1)"
is "9: relation is client" \
  "$(printf '%s' "$sj" | jq -r '.sessions[]|select(.name=="s1")|.entity.relation')" "client"
is "9: entity name is the client's NAME" \
  "$(printf '%s' "$sj" | jq -r '.sessions[]|select(.name=="s1")|.entity.name')" "Acme Client"

echo "== 10. THE INJECTION SUITE — the load-bearing section =="
# Each case: a --name carrying a shell-metacharacter form. Assert (a) the verb
# SUCCEEDS, (b) a real registry_entity_load of the written file reports
# ENTITY_NAME equal to the literal input byte-for-byte, (c) no side-effect
# marker file was created — proving nothing executed at write time OR at
# read-back time.
inj_case() { # <label> <slug> <name-literal> <marker-or-empty>
  local label="$1" slug="$2" namelit="$3" marker="$4"
  out="$(run team add "$slug" --name "$namelit" --json)"; rc=$?
  is "$label: rc 0"      "$rc" "0"
  is "$label: ok true"   "$(printf '%s' "$out" | jq -r '.ok')" "true"
  if [ -n "$marker" ]; then
    absent "$label: no side-effect file — nothing executed" "$marker"
  fi
  local loaded
  loaded="$(
    . "$here/lib/registry.sh"
    STEWARD_ENTITY_DIR="$CONF" registry_entity_load "$slug" >/dev/null 2>&1
    printf '%s' "$ENTITY_NAME"
  )"
  is "$label: ENTITY_NAME equals the literal input byte-for-byte" "$loaded" "$namelit"
}

MARK1="$FX/PWNED-cmdsub-$$"
inj_case "10a command-sub \$(...)" "inj-cmdsub" "\$(touch $MARK1)" "$MARK1"

MARK2="$FX/PWNED-backtick-$$"
inj_case "10b backtick" "inj-backtick" "\`touch $MARK2\`" "$MARK2"

inj_case "10c \$VAR expansion" "inj-var" '$HOME-is-not-expanded' ""

inj_case "10d backslash" "inj-backslash" 'back\slash\here' ""

echo "== 10e: control byte (embedded newline) refuses rc 64, nothing written =="
out="$(run team add inj-newline --name "$(printf 'line1\nline2')" --json)"; rc=$?
is "10e: rc 64" "$rc" "64"
absent "10e: nothing written" "$CONF/inj-newline.conf"

echo "== 10f: control byte (embedded tab) refuses rc 64, nothing written =="
out="$(run team add inj-tab --name "$(printf 'a\tb')" --json)"; rc=$?
is "10f: rc 64" "$rc" "64"
absent "10f: nothing written" "$CONF/inj-tab.conf"

echo "== 10g: apostrophe is SAFE inside double quotes — allowed, not rejected =="
out="$(run team add inj-apostrophe --name "O'Brien" --json)"; rc=$?
is "10g: rc 0" "$rc" "0"
(
  NAME=""
  . "$CONF/inj-apostrophe.conf"
  [ "$NAME" = "O'Brien" ]
)
is "10g: NAME loads back exactly" "$?" "0"

echo "== 10h: client add carries the same serializer — one injection case on it too =="
MARK3="$FX/PWNED-client-$$"
out="$(run client add inj-client --managed-by acme --name "\$(touch $MARK3)" --json)"; rc=$?
is "10h: rc 0" "$rc" "0"
absent "10h: no side-effect file" "$MARK3"
(
  NAME=""
  . "$CONF/inj-client.conf"
  [ "$NAME" = '$(touch '"$MARK3"')' ]
)
is "10h: client NAME loads back byte-for-byte" "$?" "0"

echo "== 11. writer: lock held refuses rc 75, names it, nothing written =="
mkdir -p "$FX/.registry-write.lock"
out="$(run team add lockvictim --name "x" --json)"; rc=$?
is "11: rc 75" "$rc" "75"
has "11: reason names the lock" "$(printf '%s' "$out" | jq -r '.reason')" ".registry-write.lock"
absent "11: nothing written" "$CONF/lockvictim.conf"
rmdir "$FX/.registry-write.lock"

echo "== 12. writer: a chmod failure is a hard refuse, nothing published =="
# A STUBBED chmod earlier on PATH, not a mode argument — the real call site
# is chmod 0600 on a fixed, valid mode, so the only reachable seam is the
# binary itself. The stub always fails; the production code must never
# publish when it does.
STUBDIR="$FX/stubbin"; mkdir -p "$STUBDIR"
cat > "$STUBDIR/chmod" <<'SH'
#!/bin/bash
exit 1
SH
chmod +x "$STUBDIR/chmod"
out="$(PATH="$STUBDIR:$PATH" run team add chmodvictim --name "x" --json)"; rc=$?
is "12: rc 70" "$rc" "70"
absent "12: nothing published" "$CONF/chmodvictim.conf"
absent "12: no leftover stage file either" "$CONF/.stage."*

echo "== 13. writer: a readback refusal leaves no .conf under the final name =="
# Calls registry_entity_write DIRECTLY (bypassing the command layer's own
# argument validation) with hand-built content the real registry_entity_load
# rejects — a MANAGED_BY that does not resolve — and a permissive
# validate_fn (always rc 0) so step 4's own staged-value check cannot be
# what stops it. This isolates step 7's rollback.
_permissive_validate() { return 0; }
(
  # shellcheck source=/dev/null
  . "$here/lib/registry.sh"
  # STEWARD_ESTATE_ROOT too, not just STEWARD_ENTITY_DIR: the lock path is
  # built from _registry_estate_root regardless of the entity-dir override,
  # and leaving it unset here would make this call lock the REAL product
  # checkout instead of the fixture.
  STEWARD_ESTATE_ROOT="$FX"
  STEWARD_ENTITY_DIR="$CONF"
  content='NAME="Bad Row"
MANAGED_BY="does-not-exist-anywhere"'
  registry_entity_write "readback-victim" "$content" _permissive_validate
)
rc=$?
is "13: registry_entity_write itself refuses (rc 70)" "$rc" "70"
absent "13: no .conf left under the final name" "$CONF/readback-victim.conf"
absent "13: no leftover stage file either" "$CONF/.stage."*

echo "pass=$pass fail=$fail"
[ "$fail" -eq 0 ]
