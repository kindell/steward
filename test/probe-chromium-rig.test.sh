#!/bin/bash
# test/probe-chromium-rig.test.sh — a browser rig's health, in four words.
#
# THE MEASUREMENT IS INJECTED. A prober that can only be tried against a live
# machine is a prober that is never tried: it would need a real host, a real
# firewall and a real browser to say anything at all, so it would be exercised
# once by hand and then quietly rot. STEWARD_RIG_MEASURE_CMD is the seam; every
# case below is a fixture.
#
# FIVE RIG OUTCOMES, FOUR STATUS WORDS. The mapping is the design decision this
# suite guards. Two of the five are deliberately `up` with a warning in the
# detail field: the status word answers "can the session use this asset", and in
# both cases the answer is yes. An ungated port and a drifted port are real
# problems — a security one and a bookkeeping one — but they are not that
# question, and inventing a fifth word would force every consumer to learn what
# it means.
set -u

here="$(CDPATH= cd -- "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROBE="$here/probes/chromium-rig"
pass=0; fail=0
ok()  { pass=$((pass+1)); printf '  ok   %s\n' "$1"; }
bad() { fail=$((fail+1)); printf '  FAIL %s\n     %s\n' "$1" "${2:-}"; }
is()  { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "wanted '$3', got '$2'"; fi; }
word(){ printf '%s' "$1" | awk '{print $1}'; }
det() { printf '%s' "$1" | awk '{$1=""; sub(/^ /,""); print}'; }
has() { case "$2" in *"$3"*) ok "$1" ;; *) bad "$1" "missing '$3' in: $2" ;; esac; }

FX="$(mktemp -d)"; trap 'rm -rf "$FX"' EXIT
mkdir -p "$FX/sessions.d" "$FX/bin"

rig() { # <name> <cdp> <vnc> [profile]
  printf 'HOST="h1"\nOWNER="a"\nDOMAIN="d"\nRC_LABEL="L"\nREPO_PATH="/tmp/x"\nID="%s"\nBROWSER_RIG="yes"\nBROWSER_DISPLAY="9"\nBROWSER_CDP="%s"\nBROWSER_VNC="%s"\nBROWSER_PROFILE="%s"\n' \
    "$1" "$2" "$3" "${4:-$1}" > "$FX/sessions.d/$1.conf"
}

rig healthy  9320 5910
rig ungated  9321 5911
rig drifted  9322 5912
rig deadcdp  9323 5913
rig loopvnc  9324 5914
rig deadvnc  9325 5915
printf 'HOST="h1"\nOWNER="a"\nDOMAIN="d"\nRC_LABEL="L"\nREPO_PATH="/tmp/x"\nID="norig"\n' \
  > "$FX/sessions.d/norig.conf"

# THE FIXTURE HOST, as one measurement. Every session above reads its own rows
# out of these three lines, exactly as the real prober reads them off a host.
#   healthy  VNC 5910 bound outward, CDP 9320 listening and gated
#   ungated  VNC 5911 bound outward, CDP 9321 listening, NO gate rule
#   drifted  VNC 5912 bound outward, CDP 9322 silent, profile running on 9399
#   deadcdp  VNC 5913 bound outward, CDP 9323 silent, no profile anywhere
#   loopvnc  VNC 5914 on loopback only
#   deadvnc  VNC 5915 absent entirely
cat > "$FX/bin/measure" <<'EOF'
#!/bin/bash
[ -n "${MEASURE_SILENT:-}" ] && exit 255
echo "BIND 10.0.0.1:5910 10.0.0.1:5911 10.0.0.1:5912 10.0.0.1:5913 127.0.0.1:5914 127.0.0.1:9320 127.0.0.1:9321 127.0.0.1:9399"
echo "GRINDAD 9320 9399"
echo "PROFIL 9320=healthy 9321=ungated 9399=drifted"
EOF
chmod +x "$FX/bin/measure"

run() { # <session>
  STEWARD_REGISTRY_DIR="$FX/sessions.d" \
  STEWARD_RIG_MEASURE_CMD="$FX/bin/measure" \
  STEWARD_PROBE_SESSION="$1" \
  bash "$PROBE" chromium-rig "" 2>&1
}

echo "chromium-rig — the healthy control group"
out="$(run healthy)"; rc=$?
is  "a healthy rig is up" "$(word "$out")" "up"
is  "rc 0 — probing reports, it does not judge" "$rc" "0"
has "the detail names the VNC port to connect to" "$out" "vnc:5910"
has "the detail names the CDP port" "$out" "cdp:9320"

echo "chromium-rig — the two warnings that stay 'up'"

# AN UNGATED CDP PORT is the most serious line in the table. CDP is full remote
# control of the browser with NO authentication, and loopback is not a user
# boundary — every account on the machine reaches it. The rig still works, so
# the status word is `up`; the warning rides in the detail.
out="$(run ungated)"
is  "an ungated rig is still usable, so still up" "$(word "$out")" "up"
is  "the detail spells the danger out" "$(det "$out")" "cdp-open-to-all-local-users"

# DRIFT IS NOT DOWN. The profile runs on a port the registry does not declare:
# the rig works, but declared and measured truth have come apart. The fix is to
# sync the registry, not to touch the rig — a different problem with a different
# action, so it must not share a word with a dead rig.
out="$(run drifted)"
is  "a drifted rig is still up" "$(word "$out")" "up"
has "the detail names the port actually running" "$out" "9399"
has "the detail names the declared port too" "$out" "9322"

echo "chromium-rig — the unusable states"

# VNC LISTENING ONLY ON LOOPBACK is neither up nor down. The port is alive, so
# restarting the rig fixes nothing — it must be rebound. Two different faults
# with two different actions must not share a word.
out="$(run loopvnc)"
is  "loopback-only VNC is local-only" "$(word "$out")" "local-only"
is  "the detail says it is bound loopback-only" "$(det "$out")" "vnc-loopback-only"

out="$(run deadvnc)"
is  "no VNC listener at all is down" "$(word "$out")" "down"
is  "the detail says not-listening" "$(det "$out")" "not-listening"

# CDP DEAD WHILE VNC IS UP: you can look at the rig but not drive it, and an
# agent cannot use a rig it cannot drive. Separate detail from the VNC row so
# the reader knows which port is missing.
out="$(run deadcdp)"
is  "a rig with no CDP is down" "$(word "$out")" "down"
is  "the detail names CDP, not VNC" "$(det "$out")" "cdp-not-listening"

echo "chromium-rig — what cannot be measured"

# A HOST THAT DID NOT ANSWER IS UNKNOWN, NOT DOWN. Not knowing whether a rig
# lives is not the same as knowing it is dead, and reporting the second for the
# first sends whoever reads it to restart a machine that was fine.
out="$(MEASURE_SILENT=1 run healthy)"
is  "an unreachable host is unknown" "$(word "$out")" "unknown"
is  "the detail says the host could not be asked" "$(det "$out")" "host-unreachable"

# NO SESSION CONTEXT. The prober is handed a type and an arg; the session rides
# in the environment. Without it there is nothing to measure — and nothing to
# measure is `unknown`, never a guess and never silence.
out="$(STEWARD_REGISTRY_DIR="$FX/sessions.d" STEWARD_RIG_MEASURE_CMD="$FX/bin/measure" \
       bash "$PROBE" chromium-rig "" 2>&1)"
is  "no session context is unknown" "$(word "$out")" "unknown"
is  "the detail says why" "$(det "$out")" "no-session-context"

# A SESSION THAT DECLARES NO RIG. Asking about an asset the session does not
# have is a question with no measurement behind it.
out="$(run norig)"
is  "a session with no rig is unknown" "$(word "$out")" "unknown"
is  "the detail says no rig is declared" "$(det "$out")" "no-rig-declared"

# AN UNKNOWN SESSION NAME. Same rule; a typo must not read as a dead rig.
out="$(run does-not-exist)"
is  "an unloadable session is unknown" "$(word "$out")" "unknown"

echo "chromium-rig — the output contract"

# EXACTLY ONE LINE. asset_probe splits the first word off as the status and the
# rest as the detail; a second line would be silently swallowed, taking whatever
# it said with it.
out="$(run healthy)"
is "exactly one line of output" "$(printf '%s\n' "$out" | grep -c .)" "1"

# THE VOCABULARY IS CLOSED. Every fixture above must answer with one of four
# words — a prober that invents a fifth is a broken prober, and asset_probe
# would rewrite it to `unknown bad-status-from-probe`, hiding the breakage.
for s in healthy ungated drifted deadcdp loopvnc deadvnc norig; do
  w="$(word "$(run "$s")")"
  case "$w" in
    up|local-only|down|unknown) ok "$s answers inside the vocabulary" ;;
    *) bad "$s answers inside the vocabulary" "got '$w'" ;;
  esac
done

echo
# THE HOUSE'S COUNT LINE, not one of our own. tools/run-tests.sh parses
# `pass=N fail=M` and shows `?/?` for a suite whose numbers it cannot read. A
# suite that counts as green while unable to report what it measured is exactly
# the silent measurement the rest of this work exists to prevent.
printf 'pass=%s fail=%s\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
