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
# THE STUBS ARE FUNCTIONS, NOT FILES IN A DIRECTORY ON PATH, and the reason is
# the whole safety of this suite. The script's first line is
# `export PATH="/usr/bin:/bin:$PATH"`, which puts the REAL binaries ahead of
# any stub directory. On a machine without them that is harmless and the stub
# wins by accident; on a Linux session host /usr/bin/Xvfb EXISTS, so the suite
# reached the real one and tried to start X servers on the fixture's displays
# :5 :6 :8 :12 - which on a live host are somebody's rigs. It failed only
# because those displays were already locked. On a host with those displays
# free it would have started a real Xvfb and then a real browser on somebody's
# screen. Measured 2026-09-10.
#
# A bash function beats PATH no matter what the script does to PATH afterwards,
# which is why stat and pgrep were already functions - the file header explains
# that, and the same argument applies to every one of these.
_bs_log() { echo "$1 ${*:2} [TZ=${TZ:-<unset>}]" >> "$CALL_LOG"; return 0; }
Xvfb()             { _bs_log Xvfb "$@"; }
x11vnc()           { _bs_log x11vnc "$@"; }
setxkbmap()        { _bs_log setxkbmap "$@"; }
xmodmap()          { _bs_log xmodmap "$@"; }
autocutsel()       { _bs_log autocutsel "$@"; }
export -f _bs_log Xvfb x11vnc setxkbmap xmodmap autocutsel
mk_logger chromium-browser
BS_STUB_BIN="$bin"; export BS_STUB_BIN

# sg, same reasoning - and NOT `exec`, which inside a function would replace
# the suite's own shell instead of the stub process it used to be.
# CHROMIUM CANNOT BE A FUNCTION, and sg is why it does not have to be. The
# script runs it as `sg video -c "sg render -c \"exec chromium-browser ...\""`,
# and `exec` resolves through PATH ONLY - it never sees a shell function. So
# the one stub that must stay a file on disk is chromium-browser, and the gate
# it always passes through is this one: sg puts the stub directory FIRST in the
# PATH of the shell it runs, which is the shell that will exec. Measured: with
# the function form alone, Xvfb was intercepted and chromium was not, and six
# assertions failed with the browser missing from the call log.
sg() {
  shift
  if [ "${1:-}" = "-c" ]; then
    shift
    PATH="$BS_STUB_BIN:$PATH" /bin/bash -c "$1"
  else
    PATH="$BS_STUB_BIN:$PATH" "$@"
  fi
}
export -f sg

# ---------------------------------------------------------------------------
# stat/pgrep as bash FUNCTIONS, exported to the child process — they beat PATH
# regardless of the script's own PATH rewrite (see the file header).
# GNU FIRST, BSD AS FALLBACK, AND THE SHAPE IS CHECKED. `stat -f` is not a
# spelling difference: on GNU it means FILESYSTEM status and SUCCEEDS, printing
# `File: ... ID: ... Type: ext2/ext3 ...`, which the script then read as a file
# mode and refused with "the requirement is 700". A wrong answer that exits 0
# cannot be caught by rc alone, so the mode is accepted only when it looks like
# one. Same class as the operator-config fix, which had it the other way round.
stat() {
  if [ "${1:-}" = "-c" ] && [ "${2:-}" = "%a" ]; then
    local _m
    _m="$(/usr/bin/stat -c '%a' "$3" 2>/dev/null)"
    case "$_m" in
      [0-7][0-7][0-7]|[0-7][0-7][0-7][0-7]) printf '%s\n' "$_m"; return 0 ;;
    esac
    _m="$(/usr/bin/stat -f '%Lp' "$3" 2>/dev/null)"
    case "$_m" in
      [0-7][0-7][0-7]|[0-7][0-7][0-7][0-7]) printf '%s\n' "$_m"; return 0 ;;
    esac
    echo "stat stub: neither GNU nor BSD stat produced a mode for $3" >&2
    return 1
  else
    echo "stat stub: unexpected arguments: $*" >&2
    return 1
  fi
}
pgrep() {
  echo "pgrep $*" >> "$CALL_LOG"
  return 1   # "nothing is running" — deterministic: the script must always TRY to start
}
hostname() {
  printf '%s\n' testhost
}
export -f stat pgrep hostname

# THE SANDBOX REFUSES TO RUN IF IT IS NOT IN EFFECT. Pure introspection - no
# binary is invoked to find out, because invoking the thing you are unsure
# about is how this defect would be discovered rather than prevented. If any
# name below is not a function, PATH would decide, and on a session host PATH
# means the real X server.
#
# typeset -f AND NOT type -t, measured 2026-09-11. The old form was the repo's
# only `type -t`, and under zsh it is not a test either: `type -t` is a bad
# option there, stdout is empty, and the comparison "" != "function" holds - so
# the gate REFUSES. It failed CLOSED, which for a gate whose failure would
# otherwise start a real X server on somebody's display is the direction one
# would pick on purpose.
#
# It was not picked on purpose, and that is the whole reason to change it. The
# other instrument in this repo failed OPEN in the same shell for the same
# reason, and the difference between the two was luck. A property this suite
# relies on should not rest on which way an accident happened to fall.
#
# typeset -f also answers the question this gate actually asks - "is this name
# specifically a FUNCTION, not something PATH can supply" - which is the
# distinction the gate exists for, and it is right in both shells.
# THE GATE ASKS A CHILD, because the child is what the property is about.
#
# Both earlier versions asked whether the name was a function IN THIS SHELL -
# first `type -t`, then `typeset -f` - and that is a proxy for the thing this
# suite depends on, not the thing itself. What it depends on is that a CHILD
# process sees the stub: the script under test is run as `bash "$SCRIPT"`, and
# if the stub does not reach it, PATH does, and on a session host PATH means a
# real X server on the fixture's displays.
#
# The two are not the same question, and measured 2026-09-11 they give
# different answers in the shell where it matters. zsh has no `export -f` in
# bash's sense - there it PRINTS the function instead of exporting it:
#   bash parent: f(){...}; export -f f; bash -c f   -> the stub runs
#   zsh  parent: same two lines;        bash -c f   -> command not found
# So under zsh the whole stub mechanism is inert. `type -t` refused everything
# there by accident (it is a bad option in zsh) and the suite never ran, which
# is why nobody had met this; `typeset -f` answers correctly that the function
# exists HERE, the gate passes, and every child then falls through to PATH -
# the exact hazard the gate exists to prevent, re-opened by making the gate
# more correct about a narrower question.
#
# Asking a child settles it in any shell, and needs no knowledge of which one
# is running.
for _n in Xvfb x11vnc setxkbmap xmodmap autocutsel sg stat pgrep hostname; do
  if ! bash -c 'typeset -f "$1" >/dev/null 2>&1' _ "$_n"; then
    echo "browser-stack.test: REFUSING TO RUN - a child process does not see '$_n' as a stub," >&2
    echo "  so PATH would decide, and on a host with a real X server this suite" >&2
    echo "  would start one on the fixture's displays. Fix the stub, do not run." >&2
    exit 1
  fi
done
unset _n
if [ ! -x "$bin/chromium-browser" ]; then
  echo "browser-stack.test: REFUSING TO RUN - the chromium stub file is missing," >&2
  echo "  and it is the one stub PATH decides, because the script execs it." >&2
  exit 1
fi

# The registry's HOST field is an ssh-alias-shaped, lowercase machine name. The
# test owns that value: using the developer machine's real hostname made the
# fixture invalid on hosts like "MacBookPro" before the browser logic was
# reached.

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
HUB_HOST="testhub"
HUB_SSH="test@testhub"
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
  "$(id -un)" "$(hostname -s)" > "$sdC/no-rig.conf"

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

# =============================================================================
echo "E. A RIG THAT REFUSED TO START MUST NOT BE COUNTED AS ENSURED"
# THE HOLE: the loop calls start_screen and throws its return code away, then
# increments the counter unconditionally, then exits 0. start_screen refuses on
# a profile directory whose mode is not 700 — a real guard, added because an
# unstarted profile can sit world-readable for hours and then be handed real
# logins. The refusal is loud on stderr and completely invisible in the verdict.
#
# The line above the counter argues, at length and correctly, that "ensured" is
# the honest word because it claims only that "this many rigs are meant to exist,
# AND AFTER THE RUN THEY DO". Nothing in the code measures the second half. A
# comment that reasons that carefully about not overstating, sitting on top of
# code that overstates, is the worst version of this fault: it reads as though
# somebody already checked.
#
# Measured on a live host 2026-08-25: one account had a rig declared and no rig
# running, and every signal available said the run was fine.

homeE="$work/homeE"; mkdir -p "$homeE"
sdE="$(mk_registry "$homeE")"
mk_rig "$sdE" ok1     5 ok1     9222 5900
mk_rig "$sdE" broken  6 broken  9223 5901

# The refusal needs a profile directory that already exists with the wrong mode:
# `mkdir -m 700 -p` leaves an existing directory's mode alone, which is exactly
# the case the guard was written for — a directory SOMEBODY ELSE created.
mkdir -p "$homeE/chrome-profiles/broken"
chmod 755 "$homeE/chrome-profiles/broken"

outE="$(run_stack "$homeE" "$sdE" 2>&1)"; rcE=$?

# The guard must have fired at all — if it did not, everything below measures
# nothing, and this control assertion is what tells us so.
case "$outE" in
  *"REFUSING to start broken"*) ok "the 700 guard refused the bad profile" ;;
  *) bad "the 700 guard refused the bad profile" "output: $outE" ;;
esac

# THE FINDING, first half: the count must not include a rig that never started.
case "$outE" in
  *"2 rig(s) ensured"*) bad "the count excludes the refused rig" "claimed 2 ensured; one refused" ;;
  *"1 rig(s) ensured"*) ok "the count excludes the refused rig" ;;
  *) bad "the count excludes the refused rig" "output: $outE" ;;
esac

# THE FINDING, second half: a run in which a declared rig did not start is not a
# successful run. Zero must mean "everything that was meant to exist does".
[ "$rcE" -ne 0 ] && ok "a refused rig makes the run fail" \
                 || bad "a refused rig makes the run fail" "rc=0 with a refusal in the output"

# AND THE GOOD RIG MUST STILL HAVE STARTED. A failure that aborts the loop would
# turn one broken profile into a whole home with no browsers — worse than the
# bug. The refusal is per rig; the verdict is for the run.
if grep -q 'user-data-dir=.*chrome-profiles/ok1' "$homeE/calls.log" 2>/dev/null; then
  ok "the healthy rig started anyway"
else
  bad "the healthy rig started anyway" "calls.log: $(cat "$homeE/calls.log" 2>/dev/null)"
fi
rm -rf "$homeE"

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
