#!/bin/bash
# test/operator-config.test.sh — the operator config parser, `~/.config/steward/config`.
#
# THE FILE IS NEVER SOURCED. This is the whole reason the parser exists: a
# strict key=value reader that refuses anything shaped like shell (quotes,
# `$(`, escapes, `~`) rather than one that would silently execute it. Every
# refusal branch below exists because a plain `source` would have accepted
# that same line and run it.
#
# A BROKEN FILE REFUSES THE WHOLE INVOCATION, never "skip the line" — proven
# here through `steward sessions`, the one real subcommand this suite reaches
# for, precisely because it is downstream of the dispatcher's own call to the
# loader. If the loader ran late, or only on some paths, a broken file would
# sometimes look like no file at all; the tests below are what would catch it.
#
# STEWARD_CFG_DEBUG is a test-only seam: it prints the three allowlisted
# values and their provenance, then exits, without reaching any subcommand.
# Nothing user-facing reads it — it exists so this suite can observe
# `_CFG_SOURCE_<KEY>` from outside the process without inventing a `steward
# config get` verb that belongs to a later task.
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

debug() { # <config-file> [env assignment ...]
  local cfg="$1"; shift
  env -i PATH="$PATH" HOME="$FX/home" STEWARD_CONFIG_FILE="$cfg" STEWARD_CFG_DEBUG=1 \
    "$@" bash "$STEWARD" ls 2>&1
}

# A minimal registry, reused by the whole-invocation refusal tests (test
# group 5): valid enough that a run reaching the subcommand would succeed,
# so a refusal proves the config loader intercepted first, not that the
# registry itself was the problem.
mkdir -p "$FX/estate" "$FX/sessions.d"
printf 'LABEL_PREFIX="com.fixture.claude"\nHUB_HOST="h1"\nOP_TOKEN_FILE_NAME="fixture-token"\n' \
  > "$FX/estate/steward.conf"
printf 'HOST="h1"\nOWNER="a"\nDOMAIN="acme"\nRC_LABEL="L"\nREPO_PATH="/tmp/x"\nID="alpha"\n' \
  > "$FX/sessions.d/alpha.conf"

echo "== 1. no file: rc 0, every value unset, every source 'unset' =="
out="$(debug "$FX/does-not-exist")"; rc=$?
is "no file: rc 0" "$rc" "0"
has "no file: estate root source unset" "$out" "STEWARD_ESTATE_ROOT= source=unset"
has "no file: tmux socket source unset" "$out" "STEWARD_TMUX_SOCKET= source=unset"
has "no file: liveness cmd source unset" "$out" "STEWARD_LIVENESS_CMD= source=unset"

echo "== 2. valid file, unset env: value from file, source config-file =="
cat > "$FX/valid" <<'EOF'
FORMAT=1
STEWARD_ESTATE_ROOT=/abs/estate/root
EOF
out="$(debug "$FX/valid")"; rc=$?
is "valid file: rc 0" "$rc" "0"
has "valid file: estate root taken from file" "$out" "STEWARD_ESTATE_ROOT=/abs/estate/root source=config-file"
has "valid file: tmux socket still unset" "$out" "STEWARD_TMUX_SOCKET= source=unset"

echo "== 3. same file, variable already set in the environment: env wins =="
out="$(debug "$FX/valid" env STEWARD_ESTATE_ROOT=/from/env)"; rc=$?
is "precedence: rc 0" "$rc" "0"
has "precedence: environment value untouched" "$out" "STEWARD_ESTATE_ROOT=/from/env source=process-environment"

echo "== 4. refusal branches: each one rc 78 =="

check_refuse() { # <description> <config-content> [grep-for]
  local desc="$1" content="$2" want="${3:-}"
  printf '%s' "$content" > "$FX/broken"
  out="$(debug "$FX/broken")"; rc=$?
  is "$desc: rc 78" "$rc" "78"
  if [ -n "$want" ]; then has "$desc: stderr mentions $want" "$out" "$want"; fi
}

check_refuse "missing FORMAT=1 (file starts with a key)" \
  "STEWARD_ESTATE_ROOT=/abs/path
"

check_refuse "missing FORMAT=1 (empty file)" ""

check_refuse "unknown FORMAT value" \
  "FORMAT=2
STEWARD_ESTATE_ROOT=/abs/path
"

check_refuse "unknown key — file-borne injection of a non-allowlisted STEWARD_* var" \
  "FORMAT=1
COCKPIT_ENGINE_CMD=/bin/rm
" "COCKPIT_ENGINE_CMD"

check_refuse "duplicate key" \
  "FORMAT=1
STEWARD_ESTATE_ROOT=/abs/one
STEWARD_ESTATE_ROOT=/abs/two
"

check_refuse "relative path value" \
  "FORMAT=1
STEWARD_ESTATE_ROOT=relative/path
"

check_refuse "quoted value" \
  'FORMAT=1
STEWARD_ESTATE_ROOT="/abs/path"
'

check_refuse "value with command substitution" \
  'FORMAT=1
STEWARD_ESTATE_ROOT=/abs/$(whoami)
'

check_refuse "value with leading whitespace" \
  "FORMAT=1
STEWARD_ESTATE_ROOT= /abs/path
"

# Line-number evidence, once, for the class of refusal the brief asks for by
# name — proves radnummer really lands on stderr, not just a bare 'no'.
printf 'FORMAT=1\nSTEWARD_ESTATE_ROOT=relative/path\n' > "$FX/broken"
out="$(debug "$FX/broken")"
has "relative path refusal names the line number" "$out" ":2:"

# Symlinked file — cheap to fixture without root, unlike foreign ownership.
printf 'FORMAT=1\nSTEWARD_ESTATE_ROOT=/abs/path\n' > "$FX/real-target"
ln -sf "$FX/real-target" "$FX/symlinked"
out="$(debug "$FX/symlinked")"; rc=$?
is "symlinked config file: rc 78" "$rc" "78"
has "symlinked config file: stderr mentions symlink" "$out" "symlink"
rm -f "$FX/symlinked" "$FX/real-target"

# Group-writable file — the MODE branch the brief asks be tested in place of
# foreign ownership, which cannot be fixtured without root.
printf 'FORMAT=1\nSTEWARD_ESTATE_ROOT=/abs/path\n' > "$FX/group-writable"
chmod 0664 "$FX/group-writable"
out="$(debug "$FX/group-writable")"; rc=$?
is "group-writable config file: rc 78" "$rc" "78"
has "group-writable config file: stderr mentions the mode problem" "$out" "writable"
chmod 0600 "$FX/group-writable"; rm -f "$FX/group-writable"

# Bonus, cheap: the containing directory is group/other-writable — the
# design doc names this alongside the file's own mode: a config file can be
# locked down to 0600 and still sit inside a directory anyone can write
# into, replace, or relink.
mkdir -p "$FX/open-dir"
printf 'FORMAT=1\nSTEWARD_ESTATE_ROOT=/abs/path\n' > "$FX/open-dir/config"
chmod 0600 "$FX/open-dir/config"
chmod 0777 "$FX/open-dir"
out="$(debug "$FX/open-dir/config")"; rc=$?
is "config inside a world-writable directory: rc 78" "$rc" "78"
chmod 0700 "$FX/open-dir"

echo "== 5. a broken file refuses the WHOLE invocation, not just the line =="
printf 'FORMAT=1\nCOCKPIT_ENGINE_CMD=/bin/rm\n' > "$FX/broken-for-sessions"

human="$(env -i PATH="$PATH" HOME="$FX/home" STEWARD_CONFIG_FILE="$FX/broken-for-sessions" \
  STEWARD_REGISTRY_DIR="$FX/sessions.d" STEWARD_ESTATE_ROOT="$FX" STEWARD_VIEWER="a" \
  bash "$STEWARD" sessions 2>&1)"; hrc=$?
is "broken config, human form: rc 78" "$hrc" "78"
has "broken config, human form: names the offending key" "$human" "COCKPIT_ENGINE_CMD"

json="$(env -i PATH="$PATH" HOME="$FX/home" STEWARD_CONFIG_FILE="$FX/broken-for-sessions" \
  STEWARD_REGISTRY_DIR="$FX/sessions.d" STEWARD_ESTATE_ROOT="$FX" STEWARD_VIEWER="a" \
  bash "$STEWARD" sessions --json 2>&1)"; jrc=$?
is "broken config, json form: rc 78" "$jrc" "78"
is "broken config, json form: ok is false" "$(printf '%s' "$json" | jq -r '.ok' 2>/dev/null)" "false"
has "broken config, json form: reason names the offending key" \
  "$(printf '%s' "$json" | jq -r '.reason' 2>/dev/null)" "COCKPIT_ENGINE_CMD"

rm -rf "$FX"
echo "pass=$pass fail=$fail"
[ "$fail" -eq 0 ]
