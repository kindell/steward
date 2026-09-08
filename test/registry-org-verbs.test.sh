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
neq()   { if [ "$2" != "$3" ]; then ok "$1"; else bad "$1" "wanted anything but '$3'"; fi; }
# no_stage_leftover <label> <dir> — an UNQUOTED "$dir/.stage."* glob check
# expands (or is silently left literal) at the CALL SITE before the function
# ever runs; quoting it there would prove nothing. This walks the glob
# itself, inside the function, so a real leftover stage file is actually
# detected.
no_stage_leftover() {
  local label="$1" dir="$2" f found=""
  for f in "$dir"/.stage.*; do [ -e "$f" ] && found="$f"; done
  if [ -z "$found" ]; then ok "$label"; else bad "$label" "unexpectedly exists: $found"; fi
}

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
is "1: file mode 600"        "$(stat -c '%a' "$CONF/acme.conf" 2>/dev/null || stat -f '%Lp' "$CONF/acme.conf")" "600"
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
  if [ -n "$marker" ]; then
    absent "$label: no side-effect file AFTER the explicit load either — nothing executed at read time" "$marker"
  fi
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
# C4: the lock lives UNDER THE ENTITY DIR now (registry_entity_dir), not at
# the estate root — see section C4 below for why that distinction matters.
mkdir -p "$CONF/.write.lock"
out="$(run team add lockvictim --name "x" --json)"; rc=$?
is "11: rc 75" "$rc" "75"
has "11: reason names the lock" "$(printf '%s' "$out" | jq -r '.reason')" ".write.lock"
absent "11: nothing written" "$CONF/lockvictim.conf"
rmdir "$CONF/.write.lock"

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
no_stage_leftover "12: no leftover stage file either" "$CONF"

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
no_stage_leftover "13: no leftover stage file either" "$CONF"

echo "== C1: a hostile managed-by conf must not clobber the caller's slug/name via bash's dynamic scope =="
# cmd_registry_client_add calls registry_entity_load "$managed_by" to check
# the manager resolves and has members. registry_entity_load SOURCES that
# conf. If that source ever runs un-subshelled in the caller's own shell,
# an assignment in the conf using the SAME NAME as one of the caller's own
# `local` variables (slug, name — lowercase, not the uppercase ENTITY_*
# ones registry_entity_load itself declares local) overwrites that local
# via bash's dynamic scoping. The PoC slug "../pwned" resolves relative to
# entities.d and lands in the estate root, which already exists (unlike
# "../victim/pwned", which needs an intermediate dir mv can't create) —
# arbitrary file write, one directory up, outside entities.d entirely.
cat > "$CONF/evil.conf" <<'EOF'
NAME="Evil Team"
MEMBERS="a"
slug="../pwned"
name="CLOBBERED"
EOF
out="$(run client add goodslug --managed-by evil --name Innocent --json)"; rc=$?
is "C1: rc 0 — the legitimate write still succeeds" "$rc" "0"
is "C1: the response names the CALLER's slug, not the injected one" \
  "$(printf '%s' "$out" | jq -r '.slug')" "goodslug"
(
  NAME=""; MANAGED_BY=""
  . "$CONF/goodslug.conf"
  [ "$NAME" = "Innocent" ] && [ "$MANAGED_BY" = "evil" ]
)
is "C1: goodslug.conf carries the CALLER's NAME/MANAGED_BY, not the injected ones" "$?" "0"
absent "C1: nothing written outside entities.d via the injected slug (../pwned)" "$FX/pwned.conf"
is "C1: no file OTHER than the attack fixture itself carries the injected name" \
  "$(grep -rl 'CLOBBERED' "$FX" 2>/dev/null | grep -v '/evil\.conf$' || true)" ""

echo "== C1b: registry_entity_write is a shared primitive — it validates its OWN slug, never trusting the caller =="
# A primitive whose safety rests entirely on "the caller already checked"
# is not a boundary. Call it directly with a path-traversal slug the way a
# future session/project writer might, bypassing the command layer's own
# regex check entirely.
_c1b_always_ok() { return 0; }
(
  . "$here/lib/registry.sh"
  STEWARD_ESTATE_ROOT="$FX"
  STEWARD_ENTITY_DIR="$CONF"
  registry_entity_write "../c1b-pwned" 'NAME="x"' _c1b_always_ok
)
rc=$?
is "C1b: registry_entity_write itself refuses a non-entity-id slug (rc 64)" "$rc" "64"
absent "C1b: nothing written via the primitive's own path-traversal slug" "$FX/c1b-pwned.conf"

echo "== C2: publish must not silently report success when \$final appears in the publish window =="
# mv -n exits 0 when it DECLINES to overwrite an existing destination — the
# writer would return 0 ("wrote ...") while a foreign row sits under the
# final name untouched. The seam here is the validate_fn, called just
# before publish, standing in for a foreign writer that raced into the
# window between the recheck (step 2) and the publish (step 6).
_c2_race_final="$CONF/c2race.conf"
_c2_create_final_race() { printf 'NAME="Foreign Row"\n' > "$_c2_race_final"; return 0; }
(
  . "$here/lib/registry.sh"
  STEWARD_ESTATE_ROOT="$FX"
  STEWARD_ENTITY_DIR="$CONF"
  registry_entity_write "c2race" 'NAME="Legit"' _c2_create_final_race
)
rc=$?
neq "C2: registry_entity_write does NOT report success when \$final raced in" "$rc" "0"
(
  NAME=""
  . "$_c2_race_final"
  [ "$NAME" = "Foreign Row" ]
)
is "C2: the foreign row is untouched" "$?" "0"
no_stage_leftover "C2: no leftover stage file either" "$CONF"


echo "== C2-dir: a DIRECTORY racing into the publish window must not be linked into, littered, or squatted =="
# `ln SRC DIR` does NOT fail EEXIST — it links INTO the directory. A later
# `rm -f` cannot remove a directory, so the slug would be squatted forever
# with the staged bytes leaked nested inside. The validate_fn seam creates
# $final as a directory in the window between recheck and publish.
_c2d_final="$CONF/c2dir.conf"
_c2d_make_dir_race() { mkdir -p "$_c2d_final"; return 0; }
(
  . "$here/lib/registry.sh"
  STEWARD_ESTATE_ROOT="$FX"; STEWARD_ENTITY_DIR="$CONF"
  registry_entity_write "c2dir" 'NAME="Legit"' _c2d_make_dir_race
)
rc=$?
neq "C2-dir: writer refuses (non-zero) when a directory raced the publish" "$rc" "0"
[ -d "$_c2d_final" ]; is "C2-dir: the raced directory is left alone (not ours to delete)" "$?" "0"
# THE REAL PROOF: no staged bytes leaked nested inside the squatted directory.
_c2d_nested="$(find "$_c2d_final" -type f 2>/dev/null | head -1)"
is "C2-dir: no staged file leaked inside the directory" "$_c2d_nested" ""
# And the slug is NOT permanently squatted for a real writer: remove the
# raced dir (as an operator would) and a legit add now succeeds.
rmdir "$_c2d_final" 2>/dev/null
out="$(run team add c2dir --name "Recovered")"; rc=$?
is "C2-dir: after the raced dir is cleared, the slug is writable (rc 0)" "$rc" "0"

echo "== C4-fast: an unwritable register fails FAST (rc 78), never a multi-second stall =="
# The lock-acquire loop must distinguish EEXIST (held) from ENOENT/EACCES
# (unwritable) on the FIRST failed mkdir, not after the whole retry budget —
# correcting only the message left the stall the defect was blamed for.
RO_C4="$FX/readonly-entdir"; mkdir -p "$RO_C4"; chmod 555 "$RO_C4"
_t0="$(date +%s)"
(
  . "$here/lib/registry.sh"
  STEWARD_ESTATE_ROOT="$FX"; STEWARD_ENTITY_DIR="$RO_C4"
  registry_entity_write "cantwrite" 'NAME="x"' _permissive_validate_c3
) 2>/dev/null
rc=$?
_t1="$(date +%s)"
chmod 755 "$RO_C4"
is "C4-fast: unwritable register refuses rc 78" "$rc" "78"
[ "$((_t1 - _t0))" -le 1 ]; is "C4-fast: it fails within a second, no retry-budget stall" "$?" "0"

echo "== C3: rollback must not fail OPEN when stat is unavailable =="
# Step 7's rollback only removed the bad row if _registry_stat_id returned a
# NON-EMPTY value that matched — an empty stat (host without BSD/GNU stat,
# restricted PATH) left the bad row PUBLISHED while the message said
# "refusing". Stub `stat` on PATH to always fail, pair it with a permissive
# validate_fn and a hand-built row whose MANAGED_BY does not resolve (the
# same isolation section 13 uses for the readback check itself), and assert
# the row does NOT survive just because identity couldn't be confirmed.
STUBDIR_C3="$FX/stubbin-c3"; mkdir -p "$STUBDIR_C3"
cat > "$STUBDIR_C3/stat" <<'SH'
#!/bin/bash
exit 1
SH
chmod +x "$STUBDIR_C3/stat"
_permissive_validate_c3() { return 0; }
(
  . "$here/lib/registry.sh"
  export PATH="$STUBDIR_C3:$PATH"
  STEWARD_ESTATE_ROOT="$FX"
  STEWARD_ENTITY_DIR="$CONF"
  content='NAME="Bad Row"
MANAGED_BY="does-not-exist-anywhere"'
  registry_entity_write "c3-stat-victim" "$content" _permissive_validate_c3
)
rc=$?
is "C3: registry_entity_write refuses (rc 70) even when stat is unavailable" "$rc" "70"
absent "C3: no .conf left under the final name when stat can't confirm identity" "$CONF/c3-stat-victim.conf"
no_stage_leftover "C3: no leftover stage file either" "$CONF"

echo "== C4: the lock is keyed on the entity dir, not the estate root =="
# registry_entity_dir honors STEWARD_ENTITY_DIR INDEPENDENTLY of the estate
# root. Two writers pointed at the SAME entities.d but different estate
# roots used to take DIFFERENT locks (one per estate root) and could run
# concurrently — a bypass, not just a false negative. Simulate "another
# writer, using estate root FX, already holds the lock" the OLD way
# (mkdir at $FX/.registry-write.lock) and confirm a SECOND writer using a
# DIFFERENT estate root (FX2) but the SAME entities.d is still blocked,
# because the lock now lives under the entities.d both of them share.
FX2="$(mktemp -d)"; mkdir -p "$FX2/estate"
cp "$FX/estate/steward.conf" "$FX2/estate/steward.conf"
mkdir -p "$CONF/.write.lock"
out="$(STEWARD_ESTATE_ROOT="$FX2" STEWARD_ENTITY_DIR="$CONF" \
       STEWARD_CONFIG_FILE="$FX/no-such-config" STEWARD_VIEWER="a" \
       bash "$STEWARD" registry team add lockshare --name "x" --json 2>&1)"
rc=$?
is "C4: rc 75 — a different estate root sharing the same entities.d still contends" "$rc" "75"
has "C4: reason names the entity-dir lock" "$(printf '%s' "$out" | jq -r '.reason')" ".write.lock"
absent "C4: nothing written" "$CONF/lockshare.conf"
rmdir "$CONF/.write.lock"
rm -rf "$FX2"

echo "== C4b: mkdir failing for a reason OTHER than contention is rc 78, never misdiagnosed as 'lock held' =="
# An unwritable (but present and listable) entities.d makes every mkdir of
# the lock fail with EACCES, never EEXIST — that must read as "the register
# is unwritable" (78), not "another write holds the lock" (75).
chmod 500 "$CONF"
out="$(run team add unwritable --name "x" --json)"; rc=$?
chmod 700 "$CONF"
is "C4b: rc 78, not 75 — mkdir failing structurally is not the same as EEXIST" "$rc" "78"
absent "C4b: nothing written" "$CONF/unwritable.conf"

echo "== L1: --json purity — the serializer's own refusal must not leak a bare prose line onto stdout+stderr =="
# _registry_emit_kv's own refusal used to go straight to the process's real
# stderr, uncaptured — fine when a caller separates the streams, but a
# combined capture (2>&1 — exactly what this suite's own run() does, and
# exactly what a caller piping both streams into a log would do) got a bare
# prose line landing BEFORE the JSON object, breaking any parser expecting
# one JSON value on that stream.
out="$(run team add ctrlchar --name "$(printf 'a\nb')" --json)"; rc=$?
is "L1: rc 64" "$rc" "64"
printf '%s' "$out" | jq . >/dev/null 2>&1
is "L1: combined stdout+stderr parses as ONE pure JSON value" "$?" "0"
is "L1: ok is false" "$(printf '%s' "$out" | jq -r '.ok')" "false"
absent "L1: nothing written" "$CONF/ctrlchar.conf"

echo "== L1b: same purity guarantee on client add's NAME field =="
out="$(run client add ctrlchar2 --managed-by acme --name "$(printf 'a\nb')" --json)"; rc=$?
is "L1b: rc 64" "$rc" "64"
printf '%s' "$out" | jq . >/dev/null 2>&1
is "L1b: combined stdout+stderr parses as ONE pure JSON value" "$?" "0"
absent "L1b: nothing written" "$CONF/ctrlchar2.conf"

echo "== L2: register rows match scaffold's shape — header comment, trailing newline =="
out="$(run team add shapecheck --name "Shape Team" --json)"; rc=$?
is "L2: rc 0" "$rc" "0"
first_line="$(head -n1 "$CONF/shapecheck.conf")"
has "L2: first line is a '# <slug> — ...' header comment, like scaffold's rows" "$first_line" "# shapecheck —"
last_byte="$(tail -c1 "$CONF/shapecheck.conf" | od -An -c | tr -d ' \n')"
is "L2: file ends with a trailing newline" "$last_byte" '\n'
(
  NAME=""; MEMBERS=""
  . "$CONF/shapecheck.conf"
  [ "$NAME" = "Shape Team" ]
)
is "L2: still loads correctly with the header line present" "$?" "0"

echo "== L2b: client rows carry the same header shape =="
out="$(run client add shapecheck-client --managed-by acme --name "Shape Client" --json)"; rc=$?
is "L2b: rc 0" "$rc" "0"
first_line="$(head -n1 "$CONF/shapecheck-client.conf")"
has "L2b: first line is a '# <slug> — ...' header comment" "$first_line" "# shapecheck-client —"

echo "pass=$pass fail=$fail"
[ "$fail" -eq 0 ]
