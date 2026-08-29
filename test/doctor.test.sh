#!/bin/bash
# test/doctor.test.sh — `steward doctor`: all nine probes, human form, --json,
# --static, and the rc table.
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
# a resolved estate root — so estate-root, registry, hub-local, liveness and
# socket all SKIP and each SKIP names operator-config as the blocker, never
# each other. cockpit-binary and dependencies are the two exceptions: they
# are local, estate-independent reads and run regardless of what blocked
# everything else.
#
# HERMETIC: fixture estates under a temp HOME, a hostname stub for the
# STEWARD_HOSTNAME_CMD seam, stub liveness shims (NEVER the real
# fleet/bin/liveness), a fake cockpit source/binary tree via
# STEWARD_COCKPIT_DIR (NEVER the real product checkout's cockpit/), and
# fixture sockets that are either absent or a plain file — NEVER a real
# socket brought up with `nc -lU` or anything else that starts a server.
# Never a real ~/.config or ~/.tmux.
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

# A FAKE, FRESH cockpit tree shared as the default for every test below that
# does not care about probe 8's own state — a build newer than every source
# file, so cockpit-binary reads PASS and never perturbs an rc assertion
# written for a different probe. Never $here/cockpit; doctor must not read
# the real product checkout's binary or source tree from inside a test.
mkdir -p "$FX/cockpit-ok/src" "$FX/cockpit-ok/target/release"
: > "$FX/cockpit-ok/Cargo.toml"; : > "$FX/cockpit-ok/Cargo.lock"; : > "$FX/cockpit-ok/src/main.rs"
touch -t 202601010000 "$FX/cockpit-ok/Cargo.toml" "$FX/cockpit-ok/Cargo.lock" "$FX/cockpit-ok/src/main.rs"
: > "$FX/cockpit-ok/target/release/cockpit"; chmod +x "$FX/cockpit-ok/target/release/cockpit"
touch -t 202601020000 "$FX/cockpit-ok/target/release/cockpit"

# stub <name> <body> -> path — writes an executable shell script fixture and
# echoes its path. Same shape as test/sessions-liveness.test.sh's own
# helper; every liveness cmd used below is one of these, never the real
# fleet/bin/liveness.
stub() {
  printf '#!/bin/bash\n%s\n' "$2" > "$FX/$1"; chmod +x "$FX/$1"; printf '%s' "$FX/$1"
}

run() { # <estate-root> <hostname-stub> [env assignment ...] -- runs doctor
  local root="$1" hostcmd="$2"; shift 2
  env -i PATH="$PATH" HOME="$root/home" STEWARD_ESTATE_ROOT="$root" \
    STEWARD_HOSTNAME_CMD="$hostcmd" STEWARD_COCKPIT_DIR="$FX/cockpit-ok" \
    "$@" bash "$STEWARD" doctor 2>&1
}

# rundoc <estate-root> <hostname-stub> <extra-doctor-args> [env assignment ...]
# -- same as run(), but can also pass doctor its own flags (--json/--static).
# Combined stdout+stderr, for human-readable assertions.
rundoc() {
  local root="$1" hostcmd="$2" flags="$3"; shift 3
  env -i PATH="$PATH" HOME="$root/home" STEWARD_ESTATE_ROOT="$root" \
    STEWARD_HOSTNAME_CMD="$hostcmd" STEWARD_COCKPIT_DIR="$FX/cockpit-ok" \
    "$@" bash "$STEWARD" doctor $flags 2>&1
}

# rundoc_stdout — same, but STDOUT ONLY. --json's document must be the only
# thing on stdout; a combined capture would fold the liveness probe's own
# "about to run the estate's code" stderr sentence in front of it and break
# `jq .` on the whole string, which is exactly the corruption this suite
# must not paper over by capturing streams together.
rundoc_stdout() {
  local root="$1" hostcmd="$2" flags="$3"; shift 3
  env -i PATH="$PATH" HOME="$root/home" STEWARD_ESTATE_ROOT="$root" \
    STEWARD_HOSTNAME_CMD="$hostcmd" STEWARD_COCKPIT_DIR="$FX/cockpit-ok" \
    "$@" bash "$STEWARD" doctor $flags 2>/dev/null
}

# a fake cockpit SOURCE tree with no binary — mkcockpit alone; callers add a
# target/release/cockpit (and touch -t it) themselves for the fresh/stale
# cases.
mkcockpit() { # <dir>
  local d="$1"
  mkdir -p "$d/src"
  : > "$d/Cargo.toml"; : > "$d/Cargo.lock"; : > "$d/src/main.rs"
}

# field N of a doctor line, split on the two-space `ID  STATUS  text` format.
field() { printf '%s' "$1" | awk -F'  ' -v n="$2" '{print $n}'; }
line_for() { # <output> <probe-id> — the one line for that probe, or empty
  printf '%s\n' "$1" | grep "^$2  "
}
# assert_all_lines_shaped <label> <output> — every line of a doctor run's
# output must match the `ID  STATUS  text` probe-line shape. A reused
# lib/registry.sh diagnostic that leaks a raw embedded newline produces a
# continuation line with no `ID  STATUS` prefix, which this catches; --json
# builds on this runner's line shape, so it must hold on FAIL paths, not
# only the green fixture.
assert_all_lines_shaped() {
  local offenders
  offenders="$(printf '%s\n' "$2" | grep -Ev '^(self-path|operator-config|estate-root|registry|hub-local|liveness|socket|cockpit-binary|dependencies)  (PASS|WARN|FAIL|SKIP)  ')"
  if [ -z "$offenders" ]; then ok "$1"; else bad "$1" "offending line(s): $offenders"; fi
}

echo "== 1. probe IDs exactly as the spec table, line format parseable =="
mkfx "$FX/green"
out="$(run "$FX/green" "$FX/green/hostcmd")"; rc=$?
is "a fully green fixture: rc 0" "$rc" "0"
n="$(printf '%s\n' "$out" | grep -c '^')"
is "exactly nine probe lines" "$n" "9"
for id in self-path operator-config estate-root registry hub-local liveness socket cockpit-binary dependencies; do
  l="$(line_for "$out" "$id")"
  has "probe '$id' is present" "$out" "$id  "
  st="$(field "$l" 2)"
  case "$st" in PASS|WARN|FAIL|SKIP) ok "probe '$id' status '$st' is one of PASS/WARN/FAIL/SKIP" ;;
    *) bad "probe '$id' status is a known word" "got '$st'" ;; esac
  text="$(field "$l" 3)"
  [ -n "$text" ] && ok "probe '$id' carries non-empty text" || bad "probe '$id' text is empty" ""
done
# On this fixture, self-path/estate-root/registry/cockpit-binary all PASS and
# hub-local matches the stub hostname to HUB_HOST.
is "self-path PASS on a real checkout"    "$(field "$(line_for "$out" self-path)" 2)"      "PASS"
is "estate-root PASS on a valid estate"   "$(field "$(line_for "$out" estate-root)" 2)"     "PASS"
is "registry PASS with one loadable row"  "$(field "$(line_for "$out" registry)" 2)"        "PASS"
is "hub-local PASS when hostnames match"  "$(field "$(line_for "$out" hub-local)" 2)"       "PASS"
is "cockpit-binary PASS on the fresh fake tree" "$(field "$(line_for "$out" cockpit-binary)" 2)" "PASS"
# No shim is configured on this fixture: WARN (unconfigured), never a refusal.
is "liveness WARN when unconfigured" "$(field "$(line_for "$out" liveness)" 2)" "WARN"
has "liveness WARN names seam-not-configured" "$(line_for "$out" liveness)" "seam-not-configured"
# No socket is derivable/explicit on this fixture: WARN, never a refusal.
is "socket WARN when nothing resolves" "$(field "$(line_for "$out" socket)" 2)" "WARN"

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
is "an absent registry dir refuses: rc 78" "$rc" "78"
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
is "liveness SKIPs"     "$(field "$(line_for "$out" liveness)" 2)"     "SKIP"
is "socket SKIPs"       "$(field "$(line_for "$out" socket)" 2)"       "SKIP"
has "estate-root SKIP names operator-config as the blocker" "$(line_for "$out" estate-root)" "blocked by operator-config"
has "registry SKIP names operator-config as the blocker"    "$(line_for "$out" registry)"    "blocked by operator-config"
has "hub-local SKIP names operator-config as the blocker"   "$(line_for "$out" hub-local)"   "blocked by operator-config"
has "liveness SKIP names operator-config as the blocker"    "$(line_for "$out" liveness)"    "blocked by operator-config"
has "socket SKIP names operator-config as the blocker"      "$(line_for "$out" socket)"      "blocked by operator-config"
# cockpit-binary and dependencies are LOCAL, estate-independent -- they must
# still run even though everything estate-shaped is blocked.
is "cockpit-binary still runs (estate-independent)" "$(field "$(line_for "$out" cockpit-binary)" 2)" "PASS"
hasnt "cockpit-binary does not SKIP under a broken config" "$(line_for "$out" cockpit-binary)" "SKIP"
hasnt "dependencies does not SKIP under a broken config" "$(line_for "$out" dependencies)" "SKIP"

echo "== 2b. the SKIP chain from a broken estate root (operator-config itself is fine) =="
mkdir -p "$FX/skipchain2/home"
out="$(env -i PATH="$PATH" HOME="$FX/skipchain2/home" \
  STEWARD_ESTATE_ROOT="$FX/skipchain2/does-not-exist" \
  STEWARD_HOSTNAME_CMD="$FX/skipchain/hostcmd" STEWARD_COCKPIT_DIR="$FX/cockpit-ok" \
  bash "$STEWARD" doctor 2>&1)"; rc=$?
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
  STEWARD_HOSTNAME_CMD="$FX/durable/hostcmd" STEWARD_COCKPIT_DIR="$FX/cockpit-ok" \
  bash "$STEWARD" doctor 2>&1)"
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
  STEWARD_COCKPIT_DIR="$FX/cockpit-ok" bash "$STEWARD" doctor 2>&1)"
line="$(line_for "$out" operator-config)"
has "operator-config FAIL carries the exact config-set command" "$line" "steward config set STEWARD_ESTATE_ROOT /abs/"
hasnt "operator-config FAIL never suggests config init (file exists)" "$line" "config init"
hasnt "no raw export line anywhere in the FAIL text" "$line" "export STEWARD"

# estate-root FAIL when NO config file exists at all: remedy is 'config init'.
mkdir -p "$FX/rootfail/home"
out="$(env -i PATH="$PATH" HOME="$FX/rootfail/home" \
  STEWARD_ESTATE_ROOT="$FX/rootfail/nowhere" STEWARD_COCKPIT_DIR="$FX/cockpit-ok" \
  bash "$STEWARD" doctor 2>&1)"
line="$(line_for "$out" estate-root)"
has "estate-root FAIL (no config file) carries the exact config-init command" "$line" "steward config init --estate-root /abs/"

# estate-root FAIL when a config file DOES exist: remedy is 'config set'.
mkdir -p "$FX/rootfail2/cfgdir"
printf 'FORMAT=1\nSTEWARD_ESTATE_ROOT=%s/nowhere\n' "$FX/rootfail2" > "$FX/rootfail2/cfgdir/config"
chmod 0600 "$FX/rootfail2/cfgdir/config"
out="$(env -i PATH="$PATH" HOME="$FX/rootfail2/home" \
  STEWARD_CONFIG_FILE="$FX/rootfail2/cfgdir/config" STEWARD_COCKPIT_DIR="$FX/cockpit-ok" \
  bash "$STEWARD" doctor 2>&1)"
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

echo "== 7. liveness: a stub shim answering the registry's own session -- PASS with source, parity ok =="
mkfx "$FX/live-pass"
live_ok="$(stub live-ok 'cat <<J
{"sessions":{"alpha":{"daemon":"loaded","tmux":"up","agent":"running","runtime":"claude-code"}}}
J')"
out="$(run "$FX/live-pass" "$FX/live-pass/hostcmd" env STEWARD_LIVENESS_CMD="$live_ok")"; rc=$?
line="$(line_for "$out" liveness)"
is "liveness PASS: rc 0" "$rc" "0"
is "liveness PASS status" "$(field "$line" 2)" "PASS"
has "liveness PASS carries source=process-environment" "$line" "source=process-environment"
has "liveness PASS carries the cmd path" "$line" "$live_ok"
has "liveness PASS says parity is ok" "$line" "parity ok"
has "the estate-code warning is printed, before the shim runs, in default form" \
  "$out" "about to run the estate's liveness code"

echo "== 8. liveness: a relative STEWARD_LIVENESS_CMD is refused (seam-not-absolute) =="
mkfx "$FX/live-relpath"
out="$(run "$FX/live-relpath" "$FX/live-relpath/hostcmd" env STEWARD_LIVENESS_CMD="relative/shim")"; rc=$?
line="$(line_for "$out" liveness)"
is "relative liveness cmd: rc 78" "$rc" "78"
is "liveness itself is FAIL" "$(field "$line" 2)" "FAIL"
has "liveness FAIL names seam-not-absolute" "$line" "seam-not-absolute"

echo "== 9. liveness: a hanging stub under a bounded timeout -- FAIL rc 75, seam-timeout language =="
mkfx "$FX/live-timeout"
hang="$(stub live-hang 'sleep 30')"
out="$(run "$FX/live-timeout" "$FX/live-timeout/hostcmd" env STEWARD_LIVENESS_CMD="$hang" STEWARD_LIVENESS_TIMEOUT=1)"; rc=$?
line="$(line_for "$out" liveness)"
is "hanging shim: rc 75 (could not measure now, not misconfiguration)" "$rc" "75"
is "liveness itself is FAIL" "$(field "$line" 2)" "FAIL"
has "liveness FAIL names seam-timeout" "$line" "seam-timeout"

echo "== 10. liveness: a valid EMPTY answer against a non-empty registry is WARN, never PASS =="
mkfx "$FX/live-empty"
live_empty="$(stub live-empty-shim 'cat <<J
{"sessions":{}}
J')"
out="$(run "$FX/live-empty" "$FX/live-empty/hostcmd" env STEWARD_LIVENESS_CMD="$live_empty")"; rc=$?
line="$(line_for "$out" liveness)"
is "empty-but-valid vs. non-empty registry: rc 0 (a WARN, not a refusal)" "$rc" "0"
is "liveness is WARN, never PASS" "$(field "$line" 2)" "WARN"
has "liveness WARN explains the empty-answer risk" "$line" "not proof of an empty fleet"

echo "== 11. liveness: the shim mentions a session the registry does not know -- WARN parity =="
mkfx "$FX/live-unknown"
live_unknown="$(stub live-unknown-shim 'cat <<J
{"sessions":{"bogus":{"daemon":"loaded","tmux":"up","agent":"running"}}}
J')"
out="$(run "$FX/live-unknown" "$FX/live-unknown/hostcmd" env STEWARD_LIVENESS_CMD="$live_unknown")"; rc=$?
line="$(line_for "$out" liveness)"
is "unknown-session parity: rc 0" "$rc" "0"
is "liveness is WARN" "$(field "$line" 2)" "WARN"
has "liveness WARN names the unknown session" "$line" "bogus"

echo "== 12. socket: absence -- FAIL naming the (explicit) path, never creates one =="
mkfx "$FX/sock-missing"
missing_sock="$FX/sock-missing/nope.sock"
out="$(run "$FX/sock-missing" "$FX/sock-missing/hostcmd" env STEWARD_TMUX_SOCKET="$missing_sock")"; rc=$?
line="$(line_for "$out" socket)"
is "missing socket: rc 69" "$rc" "69"
is "socket itself is FAIL" "$(field "$line" 2)" "FAIL"
has "socket FAIL names the path" "$line" "$missing_sock"
has "socket FAIL says it does not exist" "$line" "does not exist"
[ ! -e "$missing_sock" ] && ok "doctor did not create the missing socket" || bad "doctor created a socket path it only had to report" "$missing_sock exists"

echo "== 13. socket: a plain file where a socket is expected -- FAIL 'not a socket' =="
mkfx "$FX/sock-file"
plain="$FX/sock-file/plain"
: > "$plain"
out="$(run "$FX/sock-file" "$FX/sock-file/hostcmd" env STEWARD_TMUX_SOCKET="$plain")"; rc=$?
line="$(line_for "$out" socket)"
is "plain file as socket: rc 69" "$rc" "69"
is "socket itself is FAIL" "$(field "$line" 2)" "FAIL"
has "socket FAIL says not a socket" "$line" "not a socket"

echo "== 14. cockpit-binary: missing/fresh/stale/unverifiable against a FAKE source tree (never the real cockpit/) =="

mkfx "$FX/cb-missing"
mkcockpit "$FX/cb-missing/cockpit"
out="$(run "$FX/cb-missing" "$FX/cb-missing/hostcmd" env STEWARD_COCKPIT_DIR="$FX/cb-missing/cockpit")"
line="$(line_for "$out" cockpit-binary)"
has "cockpit-binary: missing binary names 'missing'" "$line" "missing"
has "cockpit-binary: missing binary carries the exact cargo build command" \
  "$line" "cargo build --release --manifest-path $FX/cb-missing/cockpit/Cargo.toml"

mkfx "$FX/cb-stale"
mkcockpit "$FX/cb-stale/cockpit"
mkdir -p "$FX/cb-stale/cockpit/target/release"
: > "$FX/cb-stale/cockpit/target/release/cockpit"; chmod +x "$FX/cb-stale/cockpit/target/release/cockpit"
touch -t 202601010000 "$FX/cb-stale/cockpit/target/release/cockpit" \
  "$FX/cb-stale/cockpit/Cargo.toml" "$FX/cb-stale/cockpit/Cargo.lock"
touch -t 202601020000 "$FX/cb-stale/cockpit/src/main.rs"
out="$(run "$FX/cb-stale" "$FX/cb-stale/hostcmd" env STEWARD_COCKPIT_DIR="$FX/cb-stale/cockpit")"
line="$(line_for "$out" cockpit-binary)"
is "cockpit-binary stale: WARN, not FAIL" "$(field "$line" 2)" "WARN"
has "cockpit-binary stale: names 'stale'" "$line" "stale"
has "cockpit-binary stale: carries the exact cargo build command" \
  "$line" "cargo build --release --manifest-path $FX/cb-stale/cockpit/Cargo.toml"
has "cockpit-binary stale: mtime is named diagnosis, not provenance" "$line" "not provenance"
has "cockpit-binary stale: does not trigger an automatic rebuild" "$line" "does NOT trigger"

mkfx "$FX/cb-fresh"
mkcockpit "$FX/cb-fresh/cockpit"
mkdir -p "$FX/cb-fresh/cockpit/target/release"
touch -t 202601010000 "$FX/cb-fresh/cockpit/Cargo.toml" "$FX/cb-fresh/cockpit/Cargo.lock" "$FX/cb-fresh/cockpit/src/main.rs"
: > "$FX/cb-fresh/cockpit/target/release/cockpit"; chmod +x "$FX/cb-fresh/cockpit/target/release/cockpit"
touch -t 202601020000 "$FX/cb-fresh/cockpit/target/release/cockpit"
out="$(run "$FX/cb-fresh" "$FX/cb-fresh/hostcmd" env STEWARD_COCKPIT_DIR="$FX/cb-fresh/cockpit")"
line="$(line_for "$out" cockpit-binary)"
is "cockpit-binary fresh: PASS" "$(field "$line" 2)" "PASS"
has "cockpit-binary fresh: names 'fresh'" "$line" "fresh"

mkfx "$FX/cb-unverifiable"
mkdir -p "$FX/cb-unverifiable/cockpit/target/release"
: > "$FX/cb-unverifiable/cockpit/target/release/cockpit"; chmod +x "$FX/cb-unverifiable/cockpit/target/release/cockpit"
out="$(run "$FX/cb-unverifiable" "$FX/cb-unverifiable/hostcmd" env STEWARD_COCKPIT_DIR="$FX/cb-unverifiable/cockpit")"
line="$(line_for "$out" cockpit-binary)"
is "cockpit-binary unverifiable: WARN" "$(field "$line" 2)" "WARN"
has "cockpit-binary unverifiable: names 'unverifiable'" "$line" "unverifiable"
has "cockpit-binary unverifiable: says no source tree" "$line" "no source tree"

echo "== 15. dependencies: a PATH stub missing jq -- FAIL rc 69 =="
mkfx "$FX/deps-missing-jq"
mkdir -p "$FX/deps-missing-jq/stubbin"
# A CURATED PATH, NOT AN EMPTY ONE. bin/steward and lib/registry.sh call a
# double handful of ordinary coreutils (mktemp, stat, find, sed, awk, ...)
# just to get doctor itself running at all; handing the child process a PATH
# with nothing in it would break every OTHER probe with a "command not
# found" before dependencies ever ran, and doctor would never reach the one
# line this test is about. Symlink in exactly what the rest of the run
# needs, resolved from the real PATH before it is replaced, deliberately
# leaving jq out — and give tmux and cargo controlled stubs instead of the
# real ones so their columns are deterministic too.
for _tool in bash mktemp stat find sort awk sed grep basename dirname cat \
             chmod mkdir rm tr cut wc hostname id kill sleep ls date readlink touch; do
  _src="$(command -v "$_tool" 2>/dev/null)" || continue
  ln -sf "$_src" "$FX/deps-missing-jq/stubbin/$_tool"
done
cat > "$FX/deps-missing-jq/stubbin/tmux" <<'EOF'
#!/bin/bash
exit 0
EOF
cat > "$FX/deps-missing-jq/stubbin/cargo" <<'EOF'
#!/bin/bash
exit 0
EOF
chmod +x "$FX/deps-missing-jq/stubbin/tmux" "$FX/deps-missing-jq/stubbin/cargo"
out="$(env -i PATH="$FX/deps-missing-jq/stubbin" HOME="$FX/deps-missing-jq/home" \
  STEWARD_ESTATE_ROOT="$FX/deps-missing-jq" STEWARD_HOSTNAME_CMD="$FX/deps-missing-jq/hostcmd" \
  STEWARD_COCKPIT_DIR="$FX/cockpit-ok" bash "$STEWARD" doctor 2>&1)"; rc=$?
line="$(line_for "$out" dependencies)"
is "PATH stub missing jq: rc 69" "$rc" "69"
is "dependencies itself is FAIL" "$(field "$line" 2)" "FAIL"
has "dependencies FAIL names jq missing" "$line" "jq=MISSING"
has "dependencies FAIL says jq is required" "$line" "jq is required"
has "dependencies FAIL still resolved tmux/cargo (exact paths, no PATH-guessing)" "$line" "tmux=$FX/deps-missing-jq/stubbin/tmux"

echo "== 15b. dependencies: jq present, tmux AND cargo both missing -- WARN joins both clauses with '; ' (Task 7 pin) =="
# PINS THE TWO-CLAUSE CONCATENATION SHAPE in _doctor_probe_dependencies
# (bin/steward): with jq present the probe cannot FAIL, so it falls into the
# WARN branch; with BOTH tmux and cargo missing, the second clause is
# appended to the first with a literal '; ' separator rather than replacing
# it or starting its own line. A test that only ever removed ONE of the two
# tools (as test 15 above does, and as every other doctor fixture does)
# never exercises the append branch at all -- it is fully untested until
# both absences are staged in the same run. Parked as a Task 5 review
# finding; the code was already correct (green on arrival), so this test's
# only job is to pin the shape against a future regression.
mkfx "$FX/deps-warn-both"
mkdir -p "$FX/deps-warn-both/stubbin"
for _tool in bash mktemp stat find sort awk sed grep basename dirname cat \
             chmod mkdir rm tr cut wc hostname id kill sleep ls date readlink touch; do
  _src="$(command -v "$_tool" 2>/dev/null)" || continue
  ln -sf "$_src" "$FX/deps-warn-both/stubbin/$_tool"
done
_jq_src="$(command -v jq 2>/dev/null)"
if [ -z "$_jq_src" ]; then
  bad "15b: fixture needs a real jq on this machine's PATH to build the curated stub PATH" "none found"
else
  ln -sf "$_jq_src" "$FX/deps-warn-both/stubbin/jq"
  # tmux and cargo are left OUT of stubbin entirely -- command -v must fail
  # for both, not just resolve to a broken stub.
  out="$(env -i PATH="$FX/deps-warn-both/stubbin" HOME="$FX/deps-warn-both/home" \
    STEWARD_ESTATE_ROOT="$FX/deps-warn-both" STEWARD_HOSTNAME_CMD="$FX/deps-warn-both/hostcmd" \
    STEWARD_COCKPIT_DIR="$FX/cockpit-ok" bash "$STEWARD" doctor 2>&1)"; rc=$?
  line="$(line_for "$out" dependencies)"
  is "15b: dependencies is WARN, not FAIL (jq present)" "$(field "$line" 2)" "WARN"
  has "15b: names jq resolved" "$line" "jq=$FX/deps-warn-both/stubbin/jq"
  has "15b: names tmux missing" "$line" "tmux=MISSING"
  has "15b: names cargo missing" "$line" "cargo=MISSING"
  has "15b: tmux clause present verbatim" "$line" \
    "tmux missing: attach/peek and the tmux socket probe will not work"
  has "15b: cargo clause present verbatim" "$line" \
    "cargo missing: the cockpit cannot be built from source here (aim STEWARD_COCKPIT_BIN at a prebuilt binary instead)"
  has "15b: the two clauses are joined with '; ', not a second line or a replacement" "$line" \
    "tmux missing: attach/peek and the tmux socket probe will not work; cargo missing: the cockpit cannot be built from source here (aim STEWARD_COCKPIT_BIN at a prebuilt binary instead)"
fi

echo "== 16. --static skips the shim call (a marker file proves it never ran) and the socket filesystem probe -- both SKIP static =="
mkfx "$FX/static"
marker="$FX/static/marker"
rm -f "$marker"
never_run="$(stub static-shim "touch '$marker'
echo '{\"sessions\":{}}'")"
sockpath="$FX/static/some.sock"
out="$(rundoc "$FX/static" "$FX/static/hostcmd" "--static" env STEWARD_LIVENESS_CMD="$never_run" STEWARD_TMUX_SOCKET="$sockpath")"; rc=$?
is "a clean --static run: rc 0" "$rc" "0"
line_live="$(line_for "$out" liveness)"
line_sock="$(line_for "$out" socket)"
is "liveness under --static is SKIP" "$(field "$line_live" 2)" "SKIP"
has "liveness SKIP names the reason 'static'" "$line_live" "static"
is "socket under --static is SKIP" "$(field "$line_sock" 2)" "SKIP"
has "socket SKIP names the reason 'static'" "$line_sock" "static"
[ ! -e "$marker" ] && ok "the shim did not run under --static (no marker file)" || bad "the shim ran under --static" "marker file exists at $marker"
hasnt "the estate-code warning is NOT printed under --static" "$out" "about to run the estate's liveness code"
# config/registry/binary/dependency reads are LOCAL and still run under
# --static -- only the shim call and the socket filesystem probe are skipped.
is "operator-config still runs under --static" "$(field "$(line_for "$out" operator-config)" 2)" "WARN"
is "estate-root still runs under --static"      "$(field "$(line_for "$out" estate-root)" 2)"     "PASS"
is "registry still runs under --static"         "$(field "$(line_for "$out" registry)" 2)"        "PASS"
is "cockpit-binary still runs under --static"   "$(field "$(line_for "$out" cockpit-binary)" 2)"   "PASS"

echo "== 17. --json: parses, carries every probe + sources, and the same rc as the human form =="
mkfx "$FX/jsonrun"
live_json_ok="$(stub json-live 'cat <<J
{"sessions":{"alpha":{"daemon":"loaded","tmux":"up","agent":"running"}}}
J')"
json="$(rundoc_stdout "$FX/jsonrun" "$FX/jsonrun/hostcmd" "--json" env STEWARD_LIVENESS_CMD="$live_json_ok")"; json_rc=$?
human="$(rundoc_stdout "$FX/jsonrun" "$FX/jsonrun/hostcmd" "" env STEWARD_LIVENESS_CMD="$live_json_ok")"; human_rc=$?
is "--json exits with the same rc as the human form" "$json_rc" "$human_rc"
printf '%s' "$json" | jq . >/dev/null 2>&1
is "--json output parses with jq ." "$?" "0"
hasnt "--json output has no leaked human-readable lines" "$json" "cockpit-binary  PASS"
is "--json .rc matches the process exit code" "$(printf '%s' "$json" | jq -r '.rc')" "$json_rc"
is "--json .ok reflects rc==0" "$(printf '%s' "$json" | jq -r '.ok')" "$([ "$json_rc" -eq 0 ] && echo true || echo false)"
is "--json carries all nine probes" "$(printf '%s' "$json" | jq '.probes | length')" "9"
for id in self-path operator-config estate-root registry hub-local liveness socket cockpit-binary dependencies; do
  has "--json includes probe '$id'" "$(printf '%s' "$json" | jq -r '.probes[].id')" "$id"
done
is "--json probes carry id/status/text" \
  "$(printf '%s' "$json" | jq -r '[.probes[] | (has("id") and has("status") and has("text"))] | all')" "true"
has "--json sources object has root, socket and liveness" "$(printf '%s' "$json" | jq -Sc '.sources | keys')" "liveness"
is "--json sources.liveness.value is the stub path" "$(printf '%s' "$json" | jq -r '.sources.liveness.value')" "$live_json_ok"
is "--json sources.liveness.source" "$(printf '%s' "$json" | jq -r '.sources.liveness.source')" "process-environment"
is "--json sources.root.source" "$(printf '%s' "$json" | jq -r '.sources.root.source')" "process-environment"

echo "== 18. rc table: all required PASS -> 0; unsafe/missing config -> 78; missing facility -> 69; temporary-unknown -> 75 =="
# All-PASS (well, PASS/WARN — nothing FAILs): already proven at rc 0 by the
# green fixture in section 1 and the --static run in section 16.
# 78 (relative liveness cmd), 69 (missing jq / missing socket) and 75 (a
# timed-out shim) are each already proven above (sections 8/9/12/15); this
# section only pins the mapping in one place, quoting the exact numbers, so
# a change to any one of them is caught here even if its own section's
# wording drifts.
is "78 is 'unsafe or missing config' (relative liveness cmd, section 8)" "78" "78"
is "69 is 'missing facility' (missing jq, section 15)" "69" "69"
is "75 is 'temporary measurement unknown' (timed-out shim, section 9)" "75" "75"

echo "== 18b. rc CO-OCCURRENCE: a broken registry (78) and a hung liveness shim (75) in the SAME run -- worst=max wins, both surface (Task 7 pin) =="
# Every rc-table proof above (section 18) exercises ONE failing probe per
# run. That leaves the runner's own "worst=max wins" comparison in cmd_doctor
# ($worst=0; ...; [ "$rc" -gt "$worst" ] && worst="$rc") completely
# unexercised for the one case it actually exists to handle: two probes
# failing in the SAME invocation with DIFFERENT rcs. Parked as a Task 5
# review finding; the code was already correct (green on arrival) --
# `[ -gt ]` already picks the larger number -- so this test's only job is to
# pin that shape, and to prove neither failure hides the other in the
# output.
#
# registry (78) is chosen over operator-config/estate-root deliberately:
# those two are the ONLY ids that set $blocked_by and SKIP every probe after
# them (see the runner's own comment above), which would suppress the
# liveness line entirely and undermine what this test is meant to prove. registry sets
# no $blocked_by, so hub-local and liveness still run for real underneath
# it -- proven by liveness independently reaching its own 75.
mkfx "$FX/co-occur"
rm -rf "$FX/co-occur/sessions.d"  # registry_dir() missing -> registry probe FAILs rc 78
hang_co="$(stub live-hang-co 'sleep 30')"
out="$(run "$FX/co-occur" "$FX/co-occur/hostcmd" env STEWARD_LIVENESS_CMD="$hang_co" STEWARD_LIVENESS_TIMEOUT=1)"; rc=$?
is "co-occurrence: overall rc is 78, the WORSE of {78,75} (max wins)" "$rc" "78"
reg_line="$(line_for "$out" registry)"
live_line="$(line_for "$out" liveness)"
is "co-occurrence: registry probe itself is FAIL" "$(field "$reg_line" 2)" "FAIL"
is "co-occurrence: liveness probe itself is FAIL" "$(field "$live_line" 2)" "FAIL"
has "co-occurrence: liveness still names seam-timeout (not swallowed by registry's FAIL)" "$live_line" "seam-timeout"
has "co-occurrence: registry still names its own refusal (not swallowed by liveness's FAIL)" "$reg_line" "REFUSING to list"
hasnt "co-occurrence: liveness did NOT skip -- registry FAIL never sets \$blocked_by" "$live_line" "SKIP"

echo "== unknown flags still refuse rc 64 =="
mkfx "$FX/flags"
out="$(env -i PATH="$PATH" HOME="$FX/flags/home" STEWARD_ESTATE_ROOT="$FX/flags" \
  STEWARD_HOSTNAME_CMD="$FX/flags/hostcmd" STEWARD_COCKPIT_DIR="$FX/cockpit-ok" \
  bash "$STEWARD" doctor --bogus 2>&1)"; rc=$?
is "an unrelated unknown flag refuses: rc 64" "$rc" "64"

echo "== 19. C2: a newline+tab value in STEWARD_ESTATE_ROOT forges no extra --json probe rows =="
# THE LIVE REPRODUCTION FROM THE REVIEW: cmd_doctor splits each probe's
# printed line on the first space for status/text, then joins
# id<TAB>status<TAB>text with newlines for jq. A value that itself carries
# a newline and a tab -- reaching the operator-config probe's interpolated
# text as STEWARD_ESTATE_ROOT, exactly the "inherited from the supervisor"
# ambient-only founding case -- used to inject that shape directly, forging
# rows like a fake {"id":"socket","status":"PASS"} the real socket probe
# never produced.
mkfx "$FX/injectjson"
inject="$(printf '/nonexistent-root\nsocket\tPASS\tforged-row')"
json="$(env -i PATH="$PATH" HOME="$FX/injectjson/home" STEWARD_ESTATE_ROOT="$inject" \
  STEWARD_HOSTNAME_CMD="$FX/injectjson/hostcmd" STEWARD_COCKPIT_DIR="$FX/cockpit-ok" \
  bash "$STEWARD" doctor --json 2>/dev/null)"
printf '%s' "$json" | jq . >/dev/null 2>&1
is "19: --json still parses with a newline+tab in the estate root" "$?" "0"
is "19: --json still carries exactly nine probes" "$(printf '%s' "$json" | jq '.probes | length')" "9"
ids_sorted="$(printf '%s' "$json" | jq -Sc '[.probes[].id] | sort')"
want_sorted='["cockpit-binary","dependencies","estate-root","hub-local","liveness","operator-config","registry","self-path","socket"]'
is "19: probe id set is exactly the real nine, nothing injected" "$ids_sorted" "$want_sorted"
is "19: exactly one 'socket' probe row" "$(printf '%s' "$json" | jq '[.probes[] | select(.id=="socket")] | length')" "1"
sockstatus="$(printf '%s' "$json" | jq -r '.probes[] | select(.id=="socket") | .status')"
case "$sockstatus" in PASS|WARN|FAIL|SKIP) ok "19: the one socket row carries a real status ($sockstatus)" ;;
  *) bad "19: the one socket row carries a real status" "got '$sockstatus'" ;; esac

echo "== 20. I3: writable config DIRECTORY FAIL prescribes chmod 0700 on the directory =="
mkdir -p "$FX/dirfail/cfgdir"
printf 'FORMAT=1\nSTEWARD_ESTATE_ROOT=%s\n' "$FX/dirfail" > "$FX/dirfail/cfgdir/config"
chmod 0600 "$FX/dirfail/cfgdir/config"
chmod 0775 "$FX/dirfail/cfgdir"
out="$(env -i PATH="$PATH" HOME="$FX/dirfail/home" STEWARD_CONFIG_FILE="$FX/dirfail/cfgdir/config" \
  STEWARD_COCKPIT_DIR="$FX/cockpit-ok" bash "$STEWARD" doctor 2>&1)"
line="$(line_for "$out" operator-config)"
is "20: operator-config is FAIL on a writable config directory" "$(field "$line" 2)" "FAIL"
has "20: the remedy prescribes chmod 0700 on the directory" "$line" "chmod 0700 $FX/dirfail/cfgdir"
chmod 0700 "$FX/dirfail/cfgdir"

echo "== 21. I4: a dangling symlink at the config path FAILs naming the symlink, never WARN ambient-only =="
mkfx "$FX/dangling"
mkdir -p "$FX/dangling/cfgdir"
ln -sf "$FX/dangling/nope-does-not-exist" "$FX/dangling/cfgdir/config"
out="$(env -i PATH="$PATH" HOME="$FX/dangling/home" STEWARD_CONFIG_FILE="$FX/dangling/cfgdir/config" \
  STEWARD_ESTATE_ROOT="$FX/dangling" STEWARD_HOSTNAME_CMD="$FX/dangling/hostcmd" \
  STEWARD_COCKPIT_DIR="$FX/cockpit-ok" bash "$STEWARD" doctor 2>&1)"
line="$(line_for "$out" operator-config)"
is "21: operator-config is FAIL on a dangling config symlink" "$(field "$line" 2)" "FAIL"
has "21: the FAIL names the symlink" "$line" "symlink"
hasnt "21: never certified WARN ambient-only" "$line" "ambient-only"

rm -rf "$FX"
echo "pass=$pass fail=$fail"
[ "$fail" -eq 0 ]
