#!/bin/bash
# test/doctor.test.sh — `steward doctor`, the core (probes 1-5, human form).
#
# EVERY PROBE IS A PURE READ. The one thing this suite proves harder than any
# individual probe's correctness is that doctor never writes anything: a
# recursive checksum of the whole fixture tree (find -type f | shasum),
# taken before and after a run, must come back identical. That method proves
# content and file-set identity — a changed byte, a new file, or a removed
# file all move the checksum. It does NOT prove an mtime-only change, a mode
# change, or a new empty directory left no trace; the checksum cannot see any
# of those. A diagnostic tool that mutates what it diagnoses has stopped
# being a diagnostic tool.
#
# THE SKIP CHAIN IS THE OTHER LOAD-BEARING SHAPE. A FAIL in operator-config
# means nothing downstream can be measured honestly — every later probe needs
# a resolved estate root — so estate-root, registry and hub-local all SKIP
# and each SKIP names operator-config as the blocker, not each other.
#
# HERMETIC: fixture estates under a temp HOME, a hostname stub for the
# STEWARD_HOSTNAME_CMD seam, never a real ~/.config or ~/.tmux.
set -u

here="$(CDPATH= cd -- "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
STEWARD="$here/bin/steward"
pass=0; fail=0
ok()  { pass=$((pass+1)); printf '  ok   %s\n' "$1"; }
bad() { fail=$((fail+1)); printf '  FAIL %s\n     %s\n' "$1" "${2:-}"; }
is()   { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "wanted '$3', got '$2'"; fi; }
has()  { case "$2" in *"$3"*) ok "$1" ;; *) bad "$1" "missing '$3' in: $2" ;; esac; }
hasnt(){ case "$2" in *"$3"*) bad "$1" "unwanted '$3' found in: $2" ;; *) ok "$1" ;; esac; }

FX="$(mktemp -d)"; trap 'rm -rf "$FX"' EXIT

# A minimal, LOADABLE estate: root, estate file, one session that loads
# cleanly, and a hostname stub so probe 5 (hub-local) can be driven without
# touching the real machine's name.
mkfx() { # <dir>
  local d="$1"
  mkdir -p "$d/estate" "$d/sessions.d" "$d/home"
  printf 'LABEL_PREFIX="com.fixture.claude"\nHUB_HOST="h1"\nOP_TOKEN_FILE_NAME="fixture-token"\n' \
    > "$d/estate/steward.conf"
  printf 'HOST="h1"\nOWNER="a"\nDOMAIN="acme"\nRC_LABEL="L"\nREPO_PATH="/tmp/x"\nID="alpha"\n' \
    > "$d/sessions.d/alpha.conf"
  cat > "$d/hostcmd" <<'EOF'
#!/bin/bash
echo h1
EOF
  chmod +x "$d/hostcmd"
}

run() { # <estate-root> <hostname-stub> [env assignment ...] -- runs doctor
  local root="$1" hostcmd="$2"; shift 2
  env -i PATH="$PATH" HOME="$root/home" STEWARD_ESTATE_ROOT="$root" \
    STEWARD_HOSTNAME_CMD="$hostcmd" "$@" bash "$STEWARD" doctor 2>&1
}

# field N of a doctor line, split on the two-space `ID  STATUS  text` format.
field() { printf '%s' "$1" | awk -F'  ' -v n="$2" '{print $n}'; }
line_for() { # <output> <probe-id> — the one line for that probe, or empty
  printf '%s\n' "$1" | grep "^$2  "
}
# assert_all_lines_shaped <label> <output> — every line of a doctor run's
# output must match the `ID  STATUS  text` probe-line shape. A reused
# lib/registry.sh diagnostic that leaks a raw embedded newline produces a
# continuation line with no `ID  STATUS` prefix, which this catches; Task 5's
# --json builds on this runner's line shape, so it must hold on FAIL paths,
# not only the green fixture.
assert_all_lines_shaped() {
  local offenders
  offenders="$(printf '%s\n' "$2" | grep -Ev '^(self-path|operator-config|estate-root|registry|hub-local)  (PASS|WARN|FAIL|SKIP)  ')"
  if [ -z "$offenders" ]; then ok "$1"; else bad "$1" "offending line(s): $offenders"; fi
}

echo "== 1. probe IDs exactly as the spec table, line format parseable =="
mkfx "$FX/green"
out="$(run "$FX/green" "$FX/green/hostcmd")"; rc=$?
is "a fully green fixture: rc 0" "$rc" "0"
n="$(printf '%s\n' "$out" | grep -c '^')"
is "exactly five probe lines" "$n" "5"
for id in self-path operator-config estate-root registry hub-local; do
  l="$(line_for "$out" "$id")"
  has "probe '$id' is present" "$out" "$id  "
  st="$(field "$l" 2)"
  case "$st" in PASS|WARN|FAIL|SKIP) ok "probe '$id' status '$st' is one of PASS/WARN/FAIL/SKIP" ;;
    *) bad "probe '$id' status is a known word" "got '$st'" ;; esac
  text="$(field "$l" 3)"
  [ -n "$text" ] && ok "probe '$id' carries non-empty text" || bad "probe '$id' text is empty" ""
done
# On this fixture, self-path/estate-root/registry all PASS and hub-local
# matches the stub hostname to HUB_HOST — every probe should be clean.
is "self-path PASS on a real checkout"    "$(field "$(line_for "$out" self-path)" 2)"      "PASS"
is "estate-root PASS on a valid estate"   "$(field "$(line_for "$out" estate-root)" 2)"     "PASS"
is "registry PASS with one loadable row"  "$(field "$(line_for "$out" registry)" 2)"        "PASS"
is "hub-local PASS when hostnames match"  "$(field "$(line_for "$out" hub-local)" 2)"       "PASS"

echo "== 1b. multi-line diagnostics stay one line per probe: schema-too-new (estate-root) =="
mkfx "$FX/schema"
printf 'SCHEMA_VERSION=99999\n' >> "$FX/schema/estate/steward.conf"
out="$(run "$FX/schema" "$FX/schema/hostcmd")"; rc=$?
is "schema-too-new: rc 78" "$rc" "78"
is "estate-root itself is FAIL" "$(field "$(line_for "$out" estate-root)" 2)" "FAIL"
assert_all_lines_shaped "schema-too-new: every output line matches the probe-line shape" "$out"

echo "== 1c. multi-line diagnostics stay one line per probe: missing sessions.d (registry) =="
mkdir -p "$FX/nosessions/estate" "$FX/nosessions/home"
printf 'LABEL_PREFIX="com.fixture.claude"\nHUB_HOST="h1"\nOP_TOKEN_FILE_NAME="fixture-token"\n' \
  > "$FX/nosessions/estate/steward.conf"
cat > "$FX/nosessions/hostcmd" <<'EOF'
#!/bin/bash
echo h1
EOF
chmod +x "$FX/nosessions/hostcmd"
out="$(run "$FX/nosessions" "$FX/nosessions/hostcmd")"; rc=$?
is "missing sessions.d: rc 78" "$rc" "78"
is "estate-root PASS (sessions.d is registry's own concern)" "$(field "$(line_for "$out" estate-root)" 2)" "PASS"
is "registry itself is FAIL" "$(field "$(line_for "$out" registry)" 2)" "FAIL"
assert_all_lines_shaped "missing-sessions.d: every output line matches the probe-line shape" "$out"

echo "== 2. the SKIP chain from a broken operator config =="
mkfx "$FX/skipchain"
mkdir -p "$FX/skipchain/cfgdir"
printf 'FORMAT=1\nCOCKPIT_ENGINE_CMD=/bin/rm\n' > "$FX/skipchain/cfgdir/broken"
out="$(run "$FX/skipchain" "$FX/skipchain/hostcmd" env STEWARD_CONFIG_FILE="$FX/skipchain/cfgdir/broken")"; rc=$?
is "broken operator config: rc 78" "$rc" "78"
is "self-path still runs (blocks nothing)" "$(field "$(line_for "$out" self-path)" 2)" "PASS"
is "operator-config itself is FAIL" "$(field "$(line_for "$out" operator-config)" 2)" "FAIL"
is "estate-root SKIPs"  "$(field "$(line_for "$out" estate-root)" 2)"  "SKIP"
is "registry SKIPs"     "$(field "$(line_for "$out" registry)" 2)"     "SKIP"
is "hub-local SKIPs"    "$(field "$(line_for "$out" hub-local)" 2)"    "SKIP"
has "estate-root SKIP names operator-config as the blocker" "$(line_for "$out" estate-root)" "blocked by operator-config"
has "registry SKIP names operator-config as the blocker"    "$(line_for "$out" registry)"    "blocked by operator-config"
has "hub-local SKIP names operator-config as the blocker"   "$(line_for "$out" hub-local)"   "blocked by operator-config"

echo "== 2b. the SKIP chain from a broken estate root (operator-config itself is fine) =="
mkdir -p "$FX/skipchain2/home"
out="$(env -i PATH="$PATH" HOME="$FX/skipchain2/home" \
  STEWARD_ESTATE_ROOT="$FX/skipchain2/does-not-exist" \
  STEWARD_HOSTNAME_CMD="$FX/skipchain/hostcmd" bash "$STEWARD" doctor 2>&1)"; rc=$?
is "broken estate root: rc 78" "$rc" "78"
is "estate-root itself is FAIL" "$(field "$(line_for "$out" estate-root)" 2)" "FAIL"
is "registry SKIPs when estate-root fails"   "$(field "$(line_for "$out" registry)" 2)"   "SKIP"
is "hub-local SKIPs when estate-root fails"  "$(field "$(line_for "$out" hub-local)" 2)"  "SKIP"
has "registry SKIP names estate-root as the blocker"  "$(line_for "$out" registry)"  "blocked by estate-root"
has "hub-local SKIP names estate-root as the blocker" "$(line_for "$out" hub-local)" "blocked by estate-root"

echo "== 3. provenance: ambient-only vs. a durable config file =="
mkfx "$FX/ambient"
out="$(run "$FX/ambient" "$FX/ambient/hostcmd")"
line="$(line_for "$out" operator-config)"
has "env-sourced root with no config file: source=process-environment" "$line" "source=process-environment"
has "env-sourced root with no config file: WARN"                        "$line" "operator-config  WARN"
has "the founding case is named 'ambient-only'"                         "$line" "ambient-only"
has "the WARN carries a config-init remedy"                             "$line" "steward config init --estate-root"

mkfx "$FX/durable"
mkdir -p "$FX/durable/cfgdir"
printf 'FORMAT=1\nSTEWARD_ESTATE_ROOT=%s\n' "$FX/durable" > "$FX/durable/cfgdir/config"
chmod 0600 "$FX/durable/cfgdir/config"
out="$(env -i PATH="$PATH" HOME="$FX/durable/home" STEWARD_CONFIG_FILE="$FX/durable/cfgdir/config" \
  STEWARD_HOSTNAME_CMD="$FX/durable/hostcmd" bash "$STEWARD" doctor 2>&1)"
line="$(line_for "$out" operator-config)"
has "config-file-sourced root: source=config-file" "$line" "source=config-file"
has "config-file-sourced root: PASS"               "$line" "operator-config  PASS"
hasnt "a durable config file is never called ambient-only" "$line" "ambient-only"

echo "== 4. every FAIL carries the exact remedy command =="
# operator-config's own FAIL: the file exists (broken, not missing), so the
# remedy must be 'config set', never 'config init' — init refuses outright
# on a file that already exists.
mkdir -p "$FX/cfgfail/cfgdir"
printf 'FORMAT=1\nSTEWARD_ESTATE_ROOT=relative/not/absolute\n' > "$FX/cfgfail/cfgdir/broken"
out="$(env -i PATH="$PATH" HOME="$FX/cfgfail/home" STEWARD_CONFIG_FILE="$FX/cfgfail/cfgdir/broken" \
  bash "$STEWARD" doctor 2>&1)"
line="$(line_for "$out" operator-config)"
has "operator-config FAIL carries the exact config-set command" "$line" "steward config set STEWARD_ESTATE_ROOT /abs/"
hasnt "operator-config FAIL never suggests config init (file exists)" "$line" "config init"
hasnt "no raw export line anywhere in the FAIL text" "$line" "export STEWARD"

# estate-root FAIL when NO config file exists at all: remedy is 'config init'.
mkdir -p "$FX/rootfail/home"
out="$(env -i PATH="$PATH" HOME="$FX/rootfail/home" \
  STEWARD_ESTATE_ROOT="$FX/rootfail/nowhere" bash "$STEWARD" doctor 2>&1)"
line="$(line_for "$out" estate-root)"
has "estate-root FAIL (no config file) carries the exact config-init command" "$line" "steward config init --estate-root /abs/"

# estate-root FAIL when a config file DOES exist: remedy is 'config set'.
mkdir -p "$FX/rootfail2/cfgdir"
printf 'FORMAT=1\nSTEWARD_ESTATE_ROOT=%s/nowhere\n' "$FX/rootfail2" > "$FX/rootfail2/cfgdir/config"
chmod 0600 "$FX/rootfail2/cfgdir/config"
out="$(env -i PATH="$PATH" HOME="$FX/rootfail2/home" \
  STEWARD_CONFIG_FILE="$FX/rootfail2/cfgdir/config" bash "$STEWARD" doctor 2>&1)"
line="$(line_for "$out" estate-root)"
has "estate-root FAIL (config file exists) carries the exact config-set command" "$line" "steward config set STEWARD_ESTATE_ROOT /abs/"
hasnt "estate-root FAIL never suggests config init once a file exists" "$line" "config init"

echo "== 5. doctor never mutates the estate it reads =="
mkfx "$FX/pristine"
checksum() { find "$FX/pristine" -type f -print0 | sort -z | xargs -0 shasum | shasum; }
before="$(checksum)"
run "$FX/pristine" "$FX/pristine/hostcmd" >/dev/null
after="$(checksum)"
is "fixture tree checksum unchanged after a doctor run" "$after" "$before"

echo "== 6. rc 69: hub-local cannot determine this machine's hostname =="
mkfx "$FX/rc69"
out="$(run "$FX/rc69" "$FX/rc69/does-not-exist")"; rc=$?
is "unresolvable hostname command: rc 69" "$rc" "69"
is "hub-local itself is FAIL" "$(field "$(line_for "$out" hub-local)" 2)" "FAIL"
has "hub-local FAIL names the reason" "$(line_for "$out" hub-local)" "could not determine"

echo "== unknown flags refuse rc 64 (--json/--static are a later task) =="
mkfx "$FX/flags"
run_with_flag() { # <flag>
  env -i PATH="$PATH" HOME="$FX/flags/home" STEWARD_ESTATE_ROOT="$FX/flags" \
    STEWARD_HOSTNAME_CMD="$FX/flags/hostcmd" bash "$STEWARD" doctor "$1" 2>&1
}
out="$(run_with_flag --json)"; rc=$?
is "--json refuses: rc 64" "$rc" "64"
has "--json names the later-task disclaimer" "$out" "later task"
out="$(run_with_flag --static)"; rc=$?
is "--static refuses: rc 64" "$rc" "64"
has "--static names the later-task disclaimer" "$out" "later task"
out="$(run_with_flag --bogus)"; rc=$?
is "an unrelated unknown flag refuses: rc 64" "$rc" "64"
hasnt "an unrelated unknown flag gets a plain refusal, no later-task disclaimer" "$out" "later task"

rm -rf "$FX"
echo "pass=$pass fail=$fail"
[ "$fail" -eq 0 ]
