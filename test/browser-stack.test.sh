#!/bin/bash
# test/browser-stack.test.sh — the rig registry ($HOME/.config/browser-stack/screens)
# and start_screen in linux/browser-stack.sh.
#
# BACKGROUND: the script used to carry four hardcoded start_screen calls (one
# operator's own four rigs) as a SILENT FALLBACK when the registry was missing.
# That was thrown out 2026-08-18: the mechanism already existed (the registry was
# already data-driven), and a hardcoded default table is exactly the scar this
# codebase carries elsewhere — a silent fallback of the form "${DOMAIN:-$NAME}"
# gave one session another session's directory without anyone noticing. The
# script now REFUSES instead of guessing.
#
# NO REAL PATHS. The script starts genuine Xvfb/Chromium/x11vnc and runs under
# sg with real OS groups — none of that may happen in a test. Every external
# binary the script touches is replaced:
#
#   - Xvfb, chromium-browser, x11vnc, setxkbmap, xmodmap, autocutsel, sg: real
#     executable stub files in a directory placed FIRST in PATH. None of them
#     exists for real on the development machine (macOS), so the stub is found
#     even if the script rewrites PATH afterwards.
#   - stat, pgrep: the script's FIRST line does `export PATH="/usr/bin:/bin:$PATH"`,
#     so a directory stub for those two would lose against the REAL /usr/bin/stat
#     and /usr/bin/pgrep (which do exist there, unlike the ones above). A bash
#     FUNCTION, however, always beats PATH, no matter where in PATH a stub
#     directory sat — so they are exported as functions (`export -f`) to the
#     child process instead. macOS stat also lacks the GNU flag the script uses
#     (`stat -c %a`) and would crash outright ("illegal option -- c"); the
#     function stub translates to the real BSD call (`stat -f %Lp`) so the
#     permission check (the 700 requirement in start_screen) is measured FOR
#     REAL instead of being faked.
#
# The sg stub ignores the group name and runs the -c string with bash -c. The
# script's lines nest sg TWICE ("sg video -c \"sg render -c ...\""), and the stub
# finds itself again through PATH for the inner level.
#
# THE PROFILE NAMES IN THE FIXTURE ARE DELIBERATELY GENERIC. They used to be the
# estate's real client names, which made this file impossible to move into the
# product — and a fixture does not need a true name to exercise a code path. The
# only thing the assertions care about is that the name reaches chromium's
# --user-data-dir unchanged.
#
# This suite may run on a machine with LIVE sessions on it — no command here may
# ever reach PATH's real binaries for these tools. A test in this codebase once
# sent four real messages to live sessions; it was a different suite, but the
# lesson applies just as much here.
set -u
export CDPATH=".:/tmp"
here="$(CDPATH= cd -- "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
pass=0; fail=0
ok()   { pass=$((pass+1)); }
bad()  { echo "FAIL: $1"; [ -n "${2:-}" ] && echo "  $2"; fail=$((fail+1)); }

SCRIPT="$here/linux/browser-stack.sh"

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

# ---------------------------------------------------------------------------
# The stub directory (real executables — none of these commands exists for real
# on the test machine).
bin="$work/bin"
mkdir -p "$bin"

mk_logger() { # <name> — a stub that logs "$name $*" to $CALL_LOG and succeeds
  cat > "$bin/$1" <<EOF
#!/bin/bash
echo "$1 \$* [TZ=\${TZ:-<unset>}]" >> "\$CALL_LOG"
exit 0
EOF
  chmod +x "$bin/$1"
}
mk_logger Xvfb
mk_logger chromium-browser
mk_logger x11vnc
mk_logger setxkbmap
mk_logger xmodmap
mk_logger autocutsel

cat > "$bin/sg" <<'EOF'
#!/bin/bash
# stub: ignores the group name ($1), runs the -c string with bash -c.
shift
if [ "$1" = "-c" ]; then
  shift
  exec /bin/bash -c "$1"
else
  exec "$@"
fi
EOF
chmod +x "$bin/sg"

# ---------------------------------------------------------------------------
# stat/pgrep as bash FUNCTIONS, exported to the child process — they beat PATH
# regardless of the script's own PATH rewrite (see the file header).
stat() {
  if [ "${1:-}" = "-c" ] && [ "${2:-}" = "%a" ]; then
    /usr/bin/stat -f '%Lp' "$3" 2>/dev/null
  else
    echo "stat stub: unexpected arguments: $*" >&2
    return 1
  fi
}
pgrep() {
  echo "pgrep $*" >> "$CALL_LOG"
  return 1   # "nothing is running" — deterministic: the script must always TRY to start
}
export -f stat pgrep

# THE REGISTRY MOVED, AND THIS SUITE DID NOT FOLLOW. Until 2026-08-21 the script
# read one line per rig from $HOME/.config/browser-stack/screens, and every
# fixture below wrote that file. The rigs now live in sessions.d, declared by the
# session that owns them — so the old fixture set up a file nothing reads, the
# script refused for want of a registry library, and eighteen checks failed
# against a design that no longer exists.
#
# THAT IS NOT THE SAME THING AS A BUG, and the difference is worth naming: a red
# suite whose subject was removed reports a defect in code that is behaving
# exactly as designed. It stayed red from the migration until 2026-08-22, and
# during that time it could not have caught a real fault either.
#
# WHAT THIS SUITE STILL OWNS, and why it was rewritten rather than deleted: the
# registry's own validation is covered elsewhere (the estate's riggregister
# suite). What lives only here is the SHAPE OF THE CALLS — that Xvfb, the browser
# and x11vnc are invoked with the display, profile, ports and timezone the conf
# asked for. No other suite runs the script against stubs and reads back what it
# actually executed.
mk_registry() { # <home> — an estate file plus an empty sessions.d, returns the dir
  mkdir -p "$1/estate" "$1/sessions.d"
  cat > "$1/estate/steward.conf" <<'CONF'
HUB_HOST="navet"
HUB_SSH="prov@navet"
LABEL_PREFIX="com.prov"
OP_TOKEN_FILE_NAME="prov-token"
CONF
  printf '%s' "$1/sessions.d"
}
mk_rig() { # <sessions.d> <name> <display> <profile> <cdp> <vnc>
  # HOST and OWNER are the MACHINE'S OWN, deliberately. The script starts only
  # rigs belonging to the account and host it runs on, so a fixture with invented
  # values would be filtered out and the suite would pass having started nothing.
  printf 'REPO_PATH="/x"\nRC_LABEL="P"\nDOMAIN="d"\nOWNER="%s"\nHOST="%s"\nBROWSER_RIG="yes"\nBROWSER_DISPLAY="%s"\nBROWSER_PROFILE="%s"\nBROWSER_CDP="%s"\nBROWSER_VNC="%s"\n' \
    "$(id -un)" "$(hostname -s)" "$3" "$4" "$5" "$6" > "$1/$2.conf"
}

run_stack() { # <homedir> [registry-dir] — the script in its own sandbox
  local homedir="$1" regdir="${2:-}"
  CALL_LOG="$homedir/calls.log"; touch "$CALL_LOG"
  export CALL_LOG
  ( export HOME="$homedir" PATH="$bin:/usr/bin:/bin"
    export STEWARD_REGISTRY_LIB="$here/lib/registry.sh"
    export STEWARD_ESTATE="$homedir/estate/steward.conf"
    [ -n "$regdir" ] && export STEWARD_REGISTRY_DIR="$regdir"
    bash "$SCRIPT" )
}

# =============================================================================
echo "A. PROVOKE — the rig registry directory does not exist"
# The guard this exercises was added 2026-08-22 after a host whose registry lived
# where the resolver did not look reported "0 rig(s) ensured" with rc 0 — every
# rig declared, none started, and a confident sentence saying so. A directory
# that is not there must refuse, not read as an empty one.

homeA="$work/homeA"; mkdir -p "$homeA"
mk_registry "$homeA" >/dev/null
regA="$homeA/sessions.d-does-not-exist"   # deliberately never created

out="$(run_stack "$homeA" "$regA" 2>&1)"; rc=$?
[ "$rc" -eq 78 ] && ok || bad "a missing registry => rc 78" "got rc=$rc, output: $out"
case "$out" in
  *"$regA"*) ok ;;
  *) bad "the error names the path" "output: $out" ;;
esac
case "$out" in
  *"BROWSER_RIG"*) ok ;;
  *) bad "the error says what the directory must contain" "output: $out" ;;
esac
if grep -qE '^Xvfb|^chromium-browser|^x11vnc' "$homeA/calls.log" 2>/dev/null; then
  bad "no rig was allowed to start" "calls.log: $(cat "$homeA/calls.log" 2>/dev/null)"
else
  ok
fi

# =============================================================================
echo "B/C. CONTROL GROUP — four declared rigs start four rigs; a conf without a rig is skipped"

homeC="$work/homeC"; mkdir -p "$homeC"
sdC="$(mk_registry "$homeC")"
mk_rig "$sdC" alfa  5  alfa  9222 5900
mk_rig "$sdC" beta  6  beta  9223 5901
mk_rig "$sdC" gamma 8  gamma 9225 5902
mk_rig "$sdC" delta 12 delta 9226 5903
# A session with no rig at all — it must load cleanly and start nothing. This is
# the row the old fixture expressed as a comment line, and it is the commoner
# case in a real registry by a wide margin.
printf 'REPO_PATH="/x"\nRC_LABEL="P"\nDOMAIN="d"\nOWNER="%s"\nHOST="%s"\n' \
  "$(id -un)" "$(hostname -s)" > "$sdC/utan-rigg.conf"

out="$(run_stack "$homeC" "$sdC" 2>&1)"; rc=$?
[ "$rc" -eq 0 ] && ok || bad "four declared rigs => rc 0" "got rc=$rc, output: $out"

log="$homeC/calls.log"
check_rig() { # <name> <display> <cdp> <vnc>
  local name="$1" d="$2" cdp="$3" vnc="$4"
  grep -q "^Xvfb :$d " "$log" \
    && ok || bad "$name: Xvfb on display :$d" "log: $(cat "$log")"
  grep -q "user-data-dir=$homeC/chrome-profiles/$name.*--remote-debugging-port=$cdp" "$log" \
    && ok || bad "$name: chromium with the right profile+cdp port ($cdp)" "log: $(cat "$log")"
  grep -q -- "-display :$d -rfbport $vnc" "$log" \
    && ok || bad "$name: x11vnc on display :$d, port $vnc" "log: $(cat "$log")"
}
check_rig alfa  5  9222 5900
check_rig beta  6  9223 5901
check_rig gamma 8  9225 5902
check_rig delta 12 9226 5903

# exactly four — the rig-less conf must not have triggered a fifth
n_xvfb="$(grep -c '^Xvfb ' "$log")"
[ "$n_xvfb" -eq 4 ] && ok || bad "exactly four Xvfb calls (the rig-less conf skipped)" "got $n_xvfb, log: $(cat "$log")"

echo "== D. THE TIMEZONE — the rig shows human time, the host logs UTC =="
# Rigs exist so that a person can look at them over VNC, and that audience reads
# local time. Without TZ the browser reports the host's zone, and every clock
# reading in a screenshot from it is wrong against the viewer's clock.
homeD="$(mktemp -d)"
sdD="$(mk_registry "$homeD")"
mk_rig "$sdD" testprofile 5 testprofile 9222 5900
run_stack "$homeD" "$sdD" >/dev/null 2>&1
if grep -q 'TZ=Europe/Stockholm' "$homeD/calls.log" 2>/dev/null; then ok "the rig starts with Europe/Stockholm"
else bad "the rig starts with Europe/Stockholm" "$(grep -m1 chromium "$homeD/calls.log" 2>/dev/null || echo 'no rig started')"; fi
# ONLY THE BROWSER CALL needs the zone. Xvfb, x11vnc and the keyboard tools draw
# no clock. A test that demanded TZ of all of them measured a larger set than the
# claim covered — and failed on eight calls that never had anything to do with it.
case "$(grep -E '^sg |chromium' "$homeD/calls.log" 2>/dev/null | grep -c 'TZ=<unset>')" in
  0) ok "no browser call is missing the zone" ;;
  *) bad "no browser call is missing the zone" "$(grep -E '^sg |chromium' "$homeD/calls.log" | grep -c 'TZ=<unset>') calls" ;;
esac

# CONTROL GROUP: the value is not baked in — a host somewhere else can set its own.
( export RIG_TZ="Pacific/Auckland"; run_stack "$homeD" "$sdD" >/dev/null 2>&1 )
if grep -q 'TZ=Pacific/Auckland' "$homeD/calls.log" 2>/dev/null; then ok "CONTROL GROUP: RIG_TZ wins"
else bad "CONTROL GROUP: RIG_TZ wins" "$(grep -m1 chromium "$homeD/calls.log" 2>/dev/null)"; fi
rm -rf "$homeD"

echo "pass=$pass fail=$fail"
[ "$fail" -eq 0 ]

# =============================================================================
# MUTATION TEST (run by hand, not part of the suite — it mutates the source):
#
#   <mutation tool> "bash test/browser-stack.test.sh" \
#     linux/browser-stack.sh "s/exit 78/exit 0/"
#
# The mutation swapped the refusal (rc 78) for rc 0 in the missing-registry
# branch. The baseline was green (pass=18 fail=0) and the mutation was caught
# (pass=17 fail=1): test A's `[ "$rc" -eq 78 ]` went from ok to bad and the suite
# went red. The test measures what it claims.
