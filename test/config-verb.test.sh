#!/bin/bash
# test/config-verb.test.sh — `steward config init`/`set`, the only writing
# verb anywhere in the operator's path in. Task 6 of "operator's way in".
#
# THE ALLOWLIST IS ONE LIST, NOT TWO. The parser
# (test/operator-config.test.sh, `_operator_config_load`) and this writer
# share the same predicate and the same allowed-key text — proved below by
# grepping BOTH refusal messages and checking they name the identical list,
# rather than trusting that two independently written lists happen to agree
# today.
#
# ATOMICITY IS PROVED BY ABSENCE, NOT BY INTERRUPTION. Killing `mv`
# mid-rename cannot be staged portably, so this suite instead checks the two
# things a broken rename would leave behind: a stray temp file sitting next
# to the real one, and content that is neither the old value nor the new one
# — a blend. Both come back clean or the test fails.
#
# THE ROUND TRIP IS THE CONTRACT (item 7 of the task brief): whatever `config
# init`/`set` writes, the real `_operator_config_load` (via a real `steward
# sessions --json`) must read back without refusal. Proved with a real
# fixture estate, not by re-implementing the parser's rules a second time.
#
# HERMETIC: every path below sits under a mktemp fixture; STEWARD_CONFIG_FILE
# always aims at one of those. Never the real ~/.config or ~/.tmux.
set -u

here="$(CDPATH= cd -- "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
STEWARD="$here/bin/steward"
pass=0; fail=0
ok()  { pass=$((pass+1)); printf '  ok   %s\n' "$1"; }
bad() { fail=$((fail+1)); printf '  FAIL %s\n     %s\n' "$1" "${2:-}"; }
is()   { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "wanted '$3', got '$2'"; fi; }
has()  { case "$2" in *"$3"*) ok "$1" ;; *) bad "$1" "missing '$3' in: $2" ;; esac; }
hasnt(){ case "$2" in *"$3"*) bad "$1" "unwanted '$3' found in: $2" ;; *) ok "$1" ;; esac; }
nonzero(){ if [ "$2" -ne 0 ]; then ok "$1"; else bad "$1" "got rc 0"; fi; }

FX="$(mktemp -d)"; trap 'rm -rf "$FX"' EXIT

# run <config-file> <config subcommand...> — a hermetic `steward config ...`
# invocation, environment scrubbed so nothing real leaks in.
run() {
  local cfg="$1"; shift
  env -i PATH="$PATH" HOME="$FX/home" STEWARD_CONFIG_FILE="$cfg" \
    bash "$STEWARD" config "$@" 2>&1
}

mode_of() { stat -f '%Lp' "$1" 2>/dev/null || stat -c '%a' "$1" 2>/dev/null; }

echo "== 1. init: creates the file 0600, FORMAT=1 first, directory 0700 =="
mkdir -p "$FX/init/home"
out="$(run "$FX/init/cfgdir/config" init --estate-root "$FX/init/estate")"; rc=$?
is "init: rc 0" "$rc" "0"
is "init: file mode 0600" "$(mode_of "$FX/init/cfgdir/config")" "600"
is "init: directory mode 0700" "$(mode_of "$FX/init/cfgdir")" "700"
content="$(cat "$FX/init/cfgdir/config")"
is "init: first line is FORMAT=1" "$(printf '%s\n' "$content" | head -n1)" "FORMAT=1"
has "init: estate root line present" "$content" "STEWARD_ESTATE_ROOT=$FX/init/estate"

echo "== 2. init when the file already exists: refuses, names 'config set', file untouched =="
before="$(cat "$FX/init/cfgdir/config")"
out="$(run "$FX/init/cfgdir/config" init --estate-root "$FX/init/other")"; rc=$?
nonzero "init on existing file: non-zero rc" "$rc"
has "init on existing file: names config set" "$out" "config set"
after="$(cat "$FX/init/cfgdir/config")"
is "init on existing file: content untouched" "$after" "$before"

echo "== 3. set: rewrites only the target key, keeps the rest, FORMAT=1 first, mode 0600 =="
mkdir -p "$FX/setverb/home" "$FX/setverb/cfgdir"
cat > "$FX/setverb/cfgdir/config" <<EOF
FORMAT=1
# a hand-written comment, kept as-is
STEWARD_ESTATE_ROOT=$FX/setverb/old-root
STEWARD_TMUX_SOCKET=$FX/setverb/socket.sock
EOF
chmod 0600 "$FX/setverb/cfgdir/config"
out="$(run "$FX/setverb/cfgdir/config" set STEWARD_ESTATE_ROOT "$FX/setverb/new-root")"; rc=$?
is "set: rc 0" "$rc" "0"
content="$(cat "$FX/setverb/cfgdir/config")"
is "set: first line still FORMAT=1" "$(printf '%s\n' "$content" | head -n1)" "FORMAT=1"
has "set: new root value present" "$content" "STEWARD_ESTATE_ROOT=$FX/setverb/new-root"
hasnt "set: old root value gone" "$content" "$FX/setverb/old-root"
has "set: unrelated key (tmux socket) preserved" "$content" "STEWARD_TMUX_SOCKET=$FX/setverb/socket.sock"
has "set: hand-written comment preserved" "$content" "hand-written comment, kept as-is"
is "set: file mode still 0600" "$(mode_of "$FX/setverb/cfgdir/config")" "600"

echo "== 4. set with an unknown key: refuses via THE SHARED allowlist =="
out="$(run "$FX/setverb/cfgdir/config" set NOT_A_REAL_KEY "$FX/setverb/x")"; rc=$?
nonzero "set unknown key: non-zero rc" "$rc"
has "set unknown key: names the offending key" "$out" "NOT_A_REAL_KEY"

# THE SHARED ALLOWLIST, PROVED, NOT ASSUMED: the parser's own unknown-key
# refusal and this writer's unknown-key refusal must name the IDENTICAL list
# of allowed keys, character for character.
parser_out="$(env -i PATH="$PATH" HOME="$FX/home" STEWARD_CONFIG_FILE="$FX/setverb/parser-broken" \
  bash -c 'printf "FORMAT=1\nNOT_A_REAL_KEY=/x\n" > "$1"; exec bash "$2" ls' _ \
  "$FX/setverb/parser-broken" "$STEWARD" 2>&1)"
allowed_from_parser="$(printf '%s' "$parser_out" | grep -o 'allowed: [^)]*' | head -n1)"
allowed_from_writer="$(printf '%s' "$out" | grep -o 'allowed: [^)]*' | head -n1)"
if [ -n "$allowed_from_parser" ] && [ -n "$allowed_from_writer" ]; then
  ok "shared allowlist: both refusals name an allowed-key list"
else
  bad "shared allowlist: both refusals name an allowed-key list" \
    "parser='$allowed_from_parser' writer='$allowed_from_writer'"
fi
is "shared allowlist: parser and writer name the SAME keys" "$allowed_from_writer" "$allowed_from_parser"

echo "== 5. relative path and symlink refusals =="
out="$(run "$FX/setverb/cfgdir/config" set STEWARD_ESTATE_ROOT "relative/path")"; rc=$?
nonzero "set relative path: non-zero rc" "$rc"

mkdir -p "$FX/relative/home"
out="$(run "$FX/relative/cfgdir/config" init --estate-root "relative/path")"; rc=$?
nonzero "init relative path: non-zero rc" "$rc"
[ ! -e "$FX/relative/cfgdir/config" ] && ok "init relative path: no file left behind" \
  || bad "init relative path: no file left behind" "file exists"

mkdir -p "$FX/symlinked/home"
printf 'FORMAT=1\nSTEWARD_ESTATE_ROOT=%s\n' "$FX/symlinked/real" > "$FX/symlinked/real-target"
ln -sf "$FX/symlinked/real-target" "$FX/symlinked/config"
before_sym="$(cat "$FX/symlinked/real-target")"
out="$(run "$FX/symlinked/config" init --estate-root "$FX/symlinked/whatever")"; rc=$?
nonzero "init onto a symlink path: non-zero rc" "$rc"
is "init onto a symlink path: target untouched" "$(cat "$FX/symlinked/real-target")" "$before_sym"

out="$(run "$FX/symlinked/config" set STEWARD_ESTATE_ROOT "$FX/symlinked/whatever")"; rc=$?
nonzero "set onto a symlink path: non-zero rc" "$rc"
is "set onto a symlink path: target untouched" "$(cat "$FX/symlinked/real-target")" "$before_sym"
rm -f "$FX/symlinked/config" "$FX/symlinked/real-target"

echo "== 6. atomicity: no temp litter, final content is old or new, never blended =="
mkdir -p "$FX/atomic/home" "$FX/atomic/cfgdir"
printf 'FORMAT=1\nSTEWARD_ESTATE_ROOT=%s\n' "$FX/atomic/old" > "$FX/atomic/cfgdir/config"
chmod 0600 "$FX/atomic/cfgdir/config"
run "$FX/atomic/cfgdir/config" set STEWARD_ESTATE_ROOT "$FX/atomic/new" >/dev/null
entries="$(ls -a "$FX/atomic/cfgdir" | grep -v '^\.\{1,2\}$')"
is "atomicity: exactly one entry left in the config directory" "$entries" "config"
content="$(cat "$FX/atomic/cfgdir/config")"
case "$content" in
  *"$FX/atomic/new"*)
    hasnt "atomicity: no trace of the old value alongside the new" "$content" "$FX/atomic/old" ;;
  *) bad "atomicity: final content is the new value, not a blend" "got: $content" ;;
esac

echo "== 7. set on a missing file: refuses, names 'config init' =="
out="$(run "$FX/does-not-exist/config" set STEWARD_ESTATE_ROOT "$FX/whatever")"; rc=$?
nonzero "set on missing file: non-zero rc" "$rc"
has "set on missing file: names config init" "$out" "config init"

echo "== 8. init's optional flags: --tmux-socket and --liveness-cmd =="
mkdir -p "$FX/optflags/home"
run "$FX/optflags/cfgdir/config" init --estate-root "$FX/optflags/estate" \
  --tmux-socket "$FX/optflags/socket.sock" --liveness-cmd "$FX/optflags/liveness" >/dev/null
content="$(cat "$FX/optflags/cfgdir/config")"
has "init: tmux socket line present" "$content" "STEWARD_TMUX_SOCKET=$FX/optflags/socket.sock"
has "init: liveness cmd line present" "$content" "STEWARD_LIVENESS_CMD=$FX/optflags/liveness"

echo "== 9. round trip: what config writes, the real parser reads back without refusal =="
mkdir -p "$FX/roundtrip/home" "$FX/roundtrip/estate" "$FX/roundtrip/registry"
printf 'LABEL_PREFIX="com.fixture.claude"\nHUB_HOST="h1"\nOP_TOKEN_FILE_NAME="fixture-token"\n' \
  > "$FX/roundtrip/estate/steward.conf"
printf 'HOST="h1"\nOWNER="a"\nDOMAIN="acme"\nRC_LABEL="L"\nREPO_PATH="/tmp/x"\nID="alpha"\n' \
  > "$FX/roundtrip/registry/alpha.conf"
env -i PATH="$PATH" HOME="$FX/roundtrip/home" STEWARD_CONFIG_FILE="$FX/roundtrip/cfgdir/config" \
  bash "$STEWARD" config init --estate-root "$FX/roundtrip" >/dev/null 2>&1
env -i PATH="$PATH" HOME="$FX/roundtrip/home" STEWARD_CONFIG_FILE="$FX/roundtrip/cfgdir/config" \
  bash "$STEWARD" config set STEWARD_TMUX_SOCKET "$FX/roundtrip/socket.sock" >/dev/null 2>&1
json="$(env -i PATH="$PATH" HOME="$FX/roundtrip/home" STEWARD_CONFIG_FILE="$FX/roundtrip/cfgdir/config" \
  STEWARD_REGISTRY_DIR="$FX/roundtrip/registry" STEWARD_VIEWER="a" \
  bash "$STEWARD" sessions --json 2>&1)"; jrc=$?
is "round trip: sessions --json rc 0 (no parser refusal)" "$jrc" "0"
is "round trip: ok is true" "$(printf '%s' "$json" | jq -r '.ok' 2>/dev/null)" "true"

# Same proof again through STEWARD_CFG_DEBUG, the test-only seam
# operator-config.test.sh already uses — it names the SOURCE of each value,
# so this also proves the values genuinely came from the file `config`
# wrote, not from something already present in the environment.
debug="$(env -i PATH="$PATH" HOME="$FX/roundtrip/home" STEWARD_CONFIG_FILE="$FX/roundtrip/cfgdir/config" \
  STEWARD_CFG_DEBUG=1 bash "$STEWARD" ls 2>&1)"
has "round trip: estate root came from the config file" "$debug" "STEWARD_ESTATE_ROOT=$FX/roundtrip source=config-file"
has "round trip: tmux socket came from the config file" "$debug" "STEWARD_TMUX_SOCKET=$FX/roundtrip/socket.sock source=config-file"

echo "== 10. doctor prescribes exactly the command config accepts =="
mkdir -p "$FX/prescription/estate" "$FX/prescription/registry" "$FX/prescription/home"
printf 'LABEL_PREFIX="com.fixture.claude"\nHUB_HOST="h1"\nOP_TOKEN_FILE_NAME="fixture-token"\n' \
  > "$FX/prescription/estate/steward.conf"
printf 'HOST="h1"\nOWNER="a"\nDOMAIN="acme"\nRC_LABEL="L"\nREPO_PATH="/tmp/x"\nID="alpha"\n' \
  > "$FX/prescription/registry/alpha.conf"
cat > "$FX/prescription/hostcmd" <<'HOSTEOF'
#!/bin/bash
echo h1
HOSTEOF
chmod +x "$FX/prescription/hostcmd"
# No STEWARD_CONFIG_FILE at all here — the root reaches doctor purely
# through the process environment, the exact "ambient-only" founding case
# the WARN's remedy is written for.
doctor_out="$(env -i PATH="$PATH" HOME="$FX/prescription/home" STEWARD_ESTATE_ROOT="$FX/prescription" \
  STEWARD_HOSTNAME_CMD="$FX/prescription/hostcmd" bash "$STEWARD" doctor 2>&1)"
remedy_line="$(printf '%s\n' "$doctor_out" | grep 'operator-config' | head -n1)"
remedy_cmd="$(printf '%s' "$remedy_line" | sed -n 's/.*-- run: \(steward config init[^;]*\).*/\1/p')"
if [ -n "$remedy_cmd" ]; then
  ok "doctor's remedy line names a 'steward config init' command"
else
  bad "doctor's remedy line names a 'steward config init' command" "line: $remedy_line"
fi
# Run THAT EXACT shape (swap only the binary name for our checkout's path)
# against a fresh HOME, and it must succeed.
runnable="$(printf '%s' "$remedy_cmd" | sed "s|^steward |bash \"$STEWARD\" |")"
mkdir -p "$FX/prescription/fresh-home"
out="$(env -i PATH="$PATH" HOME="$FX/prescription/fresh-home" STEWARD_CONFIG_FILE="$FX/prescription/fresh-cfgdir/config" \
  bash -c "$runnable" 2>&1)"; rc=$?
is "doctor's exact prescribed command succeeds against a fresh fixture HOME" "$rc" "0"
has "the prescribed command wrote the estate root doctor named" \
  "$(cat "$FX/prescription/fresh-cfgdir/config" 2>/dev/null)" "STEWARD_ESTATE_ROOT=$FX/prescription"

echo "== 11. set REPAIRS a parser-refused file for real, and drops loudly =="
# THE THREE LIVE REPRODUCTIONS. Before the fix, `set` carried a foreign
# unreadable line through unchanged: rc 0, "updated", and the very next
# real parse of the file still refused. Each case below proves all four
# parts of the contract: (1) set itself still returns rc 0, (2) stderr
# names the exact dropped line, (3) the real dispatcher gate — the same
# `_operator_config_load` call every subcommand goes through — accepts the
# rewritten file (proved with a hermetic `steward -h`, which exercises that
# gate without needing an estate list or a network reach), (4) comments,
# blank lines and an untouched valid key all survive.

echo "-- 11a. an unknown-key line --"
mkdir -p "$FX/repairunknown/home" "$FX/repairunknown/cfgdir"
cat > "$FX/repairunknown/cfgdir/config" <<EOF
FORMAT=1
# a hand-written comment that must survive
STEWARD_TMUX_SOCKET=$FX/repairunknown/sock

UNKNOWN_LEGACY_KEY=whatever
EOF
chmod 0600 "$FX/repairunknown/cfgdir/config"
out="$(run "$FX/repairunknown/cfgdir/config" set STEWARD_ESTATE_ROOT "$FX/repairunknown/root")"; rc=$?
is "11a: set rc 0" "$rc" "0"
has "11a: stderr names the dropped line verbatim" "$out" "UNKNOWN_LEGACY_KEY=whatever"
content="$(cat "$FX/repairunknown/cfgdir/config")"
has "11a: new estate root written" "$content" "STEWARD_ESTATE_ROOT=$FX/repairunknown/root"
has "11a: untouched valid key survives" "$content" "STEWARD_TMUX_SOCKET=$FX/repairunknown/sock"
has "11a: comment survives" "$content" "a hand-written comment that must survive"
hasnt "11a: the unreadable line is gone from the file" "$content" "UNKNOWN_LEGACY_KEY"
env -i PATH="$PATH" HOME="$FX/repairunknown/home" STEWARD_CONFIG_FILE="$FX/repairunknown/cfgdir/config" \
  bash "$STEWARD" -h >/dev/null 2>&1
is "11a: the real dispatcher gate now accepts the file" "$?" "0"

echo "-- 11b. a duplicate line of a DIFFERENT allowed key --"
mkdir -p "$FX/repairdup/home" "$FX/repairdup/cfgdir"
cat > "$FX/repairdup/cfgdir/config" <<EOF
FORMAT=1
# another comment that must survive
STEWARD_TMUX_SOCKET=$FX/repairdup/first-sock
STEWARD_TMUX_SOCKET=$FX/repairdup/second-sock
EOF
chmod 0600 "$FX/repairdup/cfgdir/config"
out="$(run "$FX/repairdup/cfgdir/config" set STEWARD_ESTATE_ROOT "$FX/repairdup/root")"; rc=$?
is "11b: set rc 0" "$rc" "0"
has "11b: stderr names the dropped duplicate line verbatim" "$out" "STEWARD_TMUX_SOCKET=$FX/repairdup/second-sock"
content="$(cat "$FX/repairdup/cfgdir/config")"
has "11b: new estate root written" "$content" "STEWARD_ESTATE_ROOT=$FX/repairdup/root"
has "11b: first occurrence of the duplicated key survives" "$content" "STEWARD_TMUX_SOCKET=$FX/repairdup/first-sock"
has "11b: comment survives" "$content" "another comment that must survive"
hasnt "11b: the second occurrence is gone from the file" "$content" "second-sock"
env -i PATH="$PATH" HOME="$FX/repairdup/home" STEWARD_CONFIG_FILE="$FX/repairdup/cfgdir/config" \
  bash "$STEWARD" -h >/dev/null 2>&1
is "11b: the real dispatcher gate now accepts the file" "$?" "0"

echo "-- 11c. a quoted value on a different key --"
mkdir -p "$FX/repairquoted/home" "$FX/repairquoted/cfgdir"
cat > "$FX/repairquoted/cfgdir/config" <<EOF
FORMAT=1
# a third comment that must survive
STEWARD_LIVENESS_CMD="$FX/repairquoted/quoted-cmd"
EOF
chmod 0600 "$FX/repairquoted/cfgdir/config"
out="$(run "$FX/repairquoted/cfgdir/config" set STEWARD_ESTATE_ROOT "$FX/repairquoted/root")"; rc=$?
is "11c: set rc 0" "$rc" "0"
has "11c: stderr names the dropped quoted line verbatim" "$out" "STEWARD_LIVENESS_CMD=\"$FX/repairquoted/quoted-cmd\""
content="$(cat "$FX/repairquoted/cfgdir/config")"
has "11c: new estate root written" "$content" "STEWARD_ESTATE_ROOT=$FX/repairquoted/root"
has "11c: comment survives" "$content" "a third comment that must survive"
hasnt "11c: the quoted line is gone from the file" "$content" "quoted-cmd"
env -i PATH="$PATH" HOME="$FX/repairquoted/home" STEWARD_CONFIG_FILE="$FX/repairquoted/cfgdir/config" \
  bash "$STEWARD" -h >/dev/null 2>&1
is "11c: the real dispatcher gate now accepts the file" "$?" "0"

echo "== 12. the lock: mkdir-based, bounded, never stolen, never left behind =="
mkdir -p "$FX/lockset/home" "$FX/lockset/cfgdir"
printf 'FORMAT=1\nSTEWARD_ESTATE_ROOT=%s\n' "$FX/lockset/old" > "$FX/lockset/cfgdir/config"
chmod 0600 "$FX/lockset/cfgdir/config"
mkdir "$FX/lockset/cfgdir/.steward-config.lock"
out="$(run "$FX/lockset/cfgdir/config" set STEWARD_ESTATE_ROOT "$FX/lockset/new")"; rc=$?
nonzero "12: set refuses while the lock directory is held" "$rc"
has "12: the refusal names the lock path" "$out" ".steward-config.lock"
is "12: the file is untouched while the lock is held" \
  "$(cat "$FX/lockset/cfgdir/config")" "FORMAT=1
STEWARD_ESTATE_ROOT=$FX/lockset/old"
rmdir "$FX/lockset/cfgdir/.steward-config.lock"
out="$(run "$FX/lockset/cfgdir/config" set STEWARD_ESTATE_ROOT "$FX/lockset/new")"; rc=$?
is "12: set succeeds once the lock is free" "$rc" "0"
has "12: the new value landed" "$(cat "$FX/lockset/cfgdir/config")" "STEWARD_ESTATE_ROOT=$FX/lockset/new"
[ ! -e "$FX/lockset/cfgdir/.steward-config.lock" ] \
  && ok "12: no lock directory left behind after a normal set" \
  || bad "12: no lock directory left behind after a normal set" "lock directory still present"

mkdir -p "$FX/lockinit/home"
mkdir -p "$FX/lockinit/cfgdir"
mkdir "$FX/lockinit/cfgdir/.steward-config.lock"
out="$(run "$FX/lockinit/cfgdir/config" init --estate-root "$FX/lockinit/estate")"; rc=$?
nonzero "12: init refuses while the lock directory is held" "$rc"
has "12: init's refusal names the lock path" "$out" ".steward-config.lock"
[ ! -e "$FX/lockinit/cfgdir/config" ] \
  && ok "12: init wrote nothing while the lock is held" \
  || bad "12: init wrote nothing while the lock is held" "file exists"
rmdir "$FX/lockinit/cfgdir/.steward-config.lock"
out="$(run "$FX/lockinit/cfgdir/config" init --estate-root "$FX/lockinit/estate")"; rc=$?
is "12: init succeeds once the lock is free" "$rc" "0"
[ ! -e "$FX/lockinit/cfgdir/.steward-config.lock" ] \
  && ok "12: no lock directory left behind after a normal init" \
  || bad "12: no lock directory left behind after a normal init" "lock directory still present"

echo "== 13. steward -h names doctor and config init/set (Task 7) =="
h_out="$(env -i PATH="$PATH" HOME="$FX/home13" bash "$STEWARD" -h 2>&1)"
has "13: -h mentions 'steward doctor'" "$h_out" "steward doctor"
has "13: -h mentions 'steward config init'" "$h_out" "steward config init"
has "13: -h mentions 'steward config set'" "$h_out" "steward config set"

echo "== 14. embedded newline / control byte in a value: refused, no smuggled key (C1) =="
# THE LIVE REPRODUCTION FROM THE REVIEW: a value that carries a second
# line naming an unrelated allowlisted key. If the writer only refused
# edge whitespace, this would land both lines, and the parser would read
# STEWARD_TMUX_SOCKET back as a key the operator never named -- bypassing
# the hub gate (STEWARD_TMUX_SOCKET) or, worse, arranging for
# lib/liveness.sh to EXECUTE an operator-uncommanded STEWARD_LIVENESS_CMD.
smuggle="$(printf '/a\nSTEWARD_TMUX_SOCKET=/live/socket')"

mkdir -p "$FX/inject/home"
out="$(run "$FX/inject/cfgdir/config" init --estate-root "$smuggle")"; rc=$?
is "14: init with an embedded-newline value: rc 64" "$rc" "64"
[ ! -e "$FX/inject/cfgdir/config" ] && ok "14: init wrote nothing" \
  || bad "14: init wrote nothing" "file exists: $(cat "$FX/inject/cfgdir/config" 2>/dev/null)"

mkdir -p "$FX/injectset/home" "$FX/injectset/cfgdir"
printf 'FORMAT=1\nSTEWARD_ESTATE_ROOT=%s\n' "$FX/injectset/root" > "$FX/injectset/cfgdir/config"
chmod 0600 "$FX/injectset/cfgdir/config"
before="$(cat "$FX/injectset/cfgdir/config")"
out="$(run "$FX/injectset/cfgdir/config" set STEWARD_ESTATE_ROOT "$smuggle")"; rc=$?
is "14: set with an embedded-newline value: rc 64" "$rc" "64"
after="$(cat "$FX/injectset/cfgdir/config")"
is "14: set with an embedded-newline value: file unchanged" "$after" "$before"
hasnt "14: the smuggled second line never landed in the file" "$after" "STEWARD_TMUX_SOCKET=/live/socket"

# A follow-up parser read must never see the smuggled key -- proved through
# the real _operator_config_load seam (STEWARD_CFG_DEBUG), not a
# re-implementation of the parser.
debug_out="$(env -i PATH="$PATH" HOME="$FX/injectset/home" STEWARD_CONFIG_FILE="$FX/injectset/cfgdir/config" \
  STEWARD_CFG_DEBUG=1 bash "$STEWARD" ls 2>&1)"
hasnt "14: parser read-back shows no smuggled STEWARD_TMUX_SOCKET" "$debug_out" "STEWARD_TMUX_SOCKET=/live/socket source=config-file"

echo "== 15. group/other-writable config DIRECTORY: writer refuses before writing or locking (I3) =="
mkdir -p "$FX/writedir/home" "$FX/writedir/cfgdir"
printf 'FORMAT=1\nSTEWARD_ESTATE_ROOT=%s\n' "$FX/writedir/old" > "$FX/writedir/cfgdir/config"
chmod 0600 "$FX/writedir/cfgdir/config"
chmod 0775 "$FX/writedir/cfgdir"
before="$(cat "$FX/writedir/cfgdir/config")"
out="$(run "$FX/writedir/cfgdir/config" set STEWARD_ESTATE_ROOT "$FX/writedir/new")"; rc=$?
is "15: set into a 0775 dir: rc 78" "$rc" "78"
has "15: set refusal names the directory" "$out" "$FX/writedir/cfgdir"
is "15: file unchanged (the remedy did not silently 'succeed')" "$(cat "$FX/writedir/cfgdir/config")" "$before"
[ ! -e "$FX/writedir/cfgdir/.steward-config.lock" ] && ok "15: set left no stray lock directory behind" \
  || bad "15: set left no stray lock directory behind" "lock dir exists"
chmod 0700 "$FX/writedir/cfgdir"

mkdir -p "$FX/writedirinit/home" "$FX/writedirinit/cfgdir"
chmod 0775 "$FX/writedirinit/cfgdir"
out="$(run "$FX/writedirinit/cfgdir/config" init --estate-root "$FX/writedirinit/estate")"; rc=$?
is "15: init into a 0775 dir: rc 78" "$rc" "78"
has "15: init refusal names the directory" "$out" "$FX/writedirinit/cfgdir"
[ ! -e "$FX/writedirinit/cfgdir/config" ] && ok "15: init wrote nothing" \
  || bad "15: init wrote nothing" "file exists"
[ ! -e "$FX/writedirinit/cfgdir/.steward-config.lock" ] && ok "15: init left no stray lock directory behind" \
  || bad "15: init left no stray lock directory behind" "lock dir exists"
chmod 0700 "$FX/writedirinit/cfgdir"

echo "== 16. set on a valid file with a leading comment before FORMAT=1 (M1) =="
mkdir -p "$FX/leadcomment/home" "$FX/leadcomment/cfgdir"
cat > "$FX/leadcomment/cfgdir/config" <<EOF
# a leading comment before FORMAT=1
FORMAT=1
STEWARD_ESTATE_ROOT=$FX/leadcomment/old
EOF
chmod 0600 "$FX/leadcomment/cfgdir/config"
out="$(run "$FX/leadcomment/cfgdir/config" set STEWARD_ESTATE_ROOT "$FX/leadcomment/new")"; rc=$?
is "16: set rc 0" "$rc" "0"
hasnt "16: no 'dropping unreadable' line for the leading comment" "$out" "dropping unreadable line 1"
hasnt "16: FORMAT=1 itself was never reported dropped" "$out" "dropping unreadable line 2"
content="$(cat "$FX/leadcomment/cfgdir/config")"
is "16: first line is still FORMAT=1" "$(printf '%s\n' "$content" | head -n1)" "FORMAT=1"
has "16: the leading comment survives" "$content" "a leading comment before FORMAT=1"
has "16: new estate root written" "$content" "STEWARD_ESTATE_ROOT=$FX/leadcomment/new"
env -i PATH="$PATH" HOME="$FX/leadcomment/home" STEWARD_CONFIG_FILE="$FX/leadcomment/cfgdir/config" \
  bash "$STEWARD" -h >/dev/null 2>&1
is "16: the real dispatcher gate accepts the rewritten file" "$?" "0"

rm -rf "$FX"
echo "pass=$pass fail=$fail"
[ "$fail" -eq 0 ]
