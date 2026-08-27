#!/bin/bash
# test/asset-chain.test.sh — the four links, driven as one chain.
#
# WHY A FOURTH SUITE. Each link already has its own: probe-dispatch is tested
# with stub probers, chromium-rig is invoked directly, assets.sh is tested with a
# stub probe command. Every one of them replaces its neighbour with a fixture, so
# together they prove that four halves work — not that the chain does. The seams
# between them (who exports STEWARD_PROBE_SESSION, which command the dispatcher
# is pointed at, how a multi-word detail survives the JSON split-and-rejoin) were
# covered by nothing at all, and the only end-to-end evidence in existence was one
# manual run against a live host that happened to be healthy.
#
# WHAT IS REAL HERE AND WHAT IS A FIXTURE. Real: bin/steward, lib/assets.sh,
# bin/probe-dispatch, probes/chromium-rig — the whole path, unstubbed. Fixture:
# the registry (STEWARD_REGISTRY_DIR), the estate root (an empty directory, so
# the dispatcher's estate-first lookup misses and falls through to the product's
# own prober), and the measurement (STEWARD_RIG_MEASURE_CMD).
#
# NO SSH. The one seam that must stay injected is the measurement: a suite that
# reached a real machine would be a suite that only runs where that machine does.
# The fixture measurement leaves a marker behind, and this suite asserts the
# marker — otherwise a chain that quietly stopped calling the prober would look
# exactly like a chain that called it and got the same answer.
set -u

here="$(CDPATH= cd -- "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
STEWARD="$here/bin/steward"
pass=0; fail=0
ok()  { pass=$((pass+1)); printf '  ok   %s\n' "$1"; }
bad() { fail=$((fail+1)); printf '  FAIL %s\n     %s\n' "$1" "${2:-}"; }
is()  { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "wanted '$3', got '$2'"; fi; }

FX="$(mktemp -d)"; trap 'rm -rf "$FX"' EXIT
mkdir -p "$FX/sessions.d" "$FX/bin" "$FX/estate/estate"

# THE FIXTURE ESTATE, in full. The registry validates the estate as a whole
# before it loads any session, so a fixture missing a field this suite never
# reads still fails every load. Note what is NOT here: an estate/probes
# directory. Its absence is load-bearing — the dispatcher searches the estate
# first, misses, and falls through to the product's own prober, which is the
# link this suite exists to exercise.
cat > "$FX/estate/estate/steward.conf" <<'ESTATE'
ESTATE_NAME="fixture"
LABEL_PREFIX="com.fixture.claude"
SCHEMA_VERSION="3"
HUB_HOST="fixturehost"
HUB_SESSION="fixturehub"
HUB_SSH="fixtureuser@fixturehost"
RC_LABEL_PREFIX="Fixture: "
JOB_LABEL_PREFIX="com.fixture.job"
SERVICE_LABEL_PREFIX="com.fixture.service"
BROWSER_LABEL_PREFIX="com.fixture.browser"
OP_TOKEN_FILE_NAME="fixture-token"
STATE_DIR_NAME="fixture-state"
PAUSED_DIR_NAME="fixture-paused"
JOB_LOG_DIR="fixture-logs"
TMUX_SOCKET="fixture-socket"
PING_MSG="fixture ping"
ESTATE

rig() { # <name> <cdp> <vnc>
  printf 'HOST="h1"\nOWNER="a"\nDOMAIN="d"\nRC_LABEL="L"\nREPO_PATH="/tmp/x"\nID="%s"\nASSETS="chromium-rig"\nBROWSER_RIG="yes"\nBROWSER_DISPLAY="9"\nBROWSER_CDP="%s"\nBROWSER_VNC="%s"\nBROWSER_PROFILE="%s"\n' \
    "$1" "$2" "$3" "$1" > "$FX/sessions.d/$1.conf"
}

# THE PORT NUMBERS ARE DELIBERATELY OUTSIDE EVERY RANGE A HOST DECLARES, and the
# addresses are RFC 5737 documentation addresses. A fixture that reuses a live
# port teaches a reader a real number, and this file is destined to be public.
rig healthy 9720 5810
rig loopvnc 9721 5811
rig deadvnc 9722 5812
printf 'HOST="h1"\nOWNER="a"\nDOMAIN="d"\nRC_LABEL="L"\nREPO_PATH="/tmp/x"\nID="odd"\nASSETS="no-such-type"\n' \
  > "$FX/sessions.d/odd.conf"

cat > "$FX/bin/measure" <<EOF
#!/bin/bash
: > "$FX/measured"
[ -n "\${MEASURE_SILENT:-}" ] && exit 255
echo "BIND 192.0.2.10:5810 127.0.0.1:5811 127.0.0.1:9720"
echo "GATED 9720"
echo "PROFILE 9720=healthy"
EOF
chmod +x "$FX/bin/measure"

# STEWARD_ASSET_PROBE_CMD IS DELIBERATELY UNSET. cmd_assets pointing it at the
# real dispatcher is one of the seams under test; setting it here would replace
# the very wiring this suite exists to prove.
run() {
  rm -f "$FX/measured"
  env -u STEWARD_ASSET_PROBE_CMD \
      STEWARD_ESTATE_ROOT="$FX/estate" \
      STEWARD_REGISTRY_DIR="$FX/sessions.d" \
      STEWARD_RIG_MEASURE_CMD="$FX/bin/measure" \
      bash "$STEWARD" assets "$@" 2>/dev/null
}

echo "asset-chain — a healthy rig, all four links"

out="$(run healthy)"; rc=$?
is "the chain answers one line for one asset" "$out" "chromium-rig up vnc:5810 cdp:9720"
is "rc 0 — the chain reports, it does not judge" "$rc" "0"
if [ -f "$FX/measured" ]; then ok "the real prober ran (the measurement was called)"
else bad "the real prober ran (the measurement was called)" "no marker left behind"; fi

# BOTH PORTS INTACT. The detail is the only place the reader learns where to
# connect, and it is the field every layer between here and the cockpit is most
# likely to truncate: asset_probe takes it with awk, cmd_assets splits it on
# spaces for JSON. A single-word detail would have passed both by accident.
case "$out" in *"vnc:5810"*) ok "the VNC port survived to the caller" ;;
  *) bad "the VNC port survived to the caller" "$out" ;; esac
case "$out" in *"cdp:9720"*) ok "the CDP port survived to the caller" ;;
  *) bad "the CDP port survived to the caller" "$out" ;; esac

echo "asset-chain — the other three status words, end to end"

# Before this suite, `up` was the only status ever observed surviving the whole
# chain — from one manual run against a host that happened to be healthy.
out="$(run loopvnc)"
is "a loopback-only rig is local-only through the chain" "$out" "chromium-rig local-only vnc-loopback-only"

out="$(run deadvnc)"
is "a dead rig is down through the chain" "$out" "chromium-rig down not-listening"

out="$(MEASURE_SILENT=1 run healthy)"
is "an unreachable host is unknown through the chain" "$out" "chromium-rig unknown host-unreachable"

# AND THE DISPATCHER IS REALLY IN THE PATH. A type with no prober behind it must
# come back as the dispatcher's own answer, not as silence — silence at this
# layer is indistinguishable from health.
out="$(run odd)"
is "an unknown asset type is unknown through the chain" "$out" "no-such-type unknown unknown-asset-type"

echo "asset-chain — the JSON path carries the same answer"

# THE JSON BRANCH REBUILDS THE DETAIL. cmd_assets does `split(" ")` and rejoins
# `.[2:]`, so a multi-word detail is exactly what would come back mangled — and
# the multi-word detail is the healthy one, the row a cockpit renders most.
j="$(run healthy --json)"
is "json reports the same status" \
   "$(printf '%s' "$j" | jq -r '.assets[0].status')" "up"
is "json rebuilds the multi-word detail unmangled" \
   "$(printf '%s' "$j" | jq -r '.assets[0].detail')" "vnc:5810 cdp:9720"
is "json names the asset" \
   "$(printf '%s' "$j" | jq -r '.assets[0].asset')" "chromium-rig"
is "json names the session" \
   "$(printf '%s' "$j" | jq -r '.session')" "healthy"
is "json carries exactly one asset" \
   "$(printf '%s' "$j" | jq -r '.assets | length')" "1"

j="$(run deadvnc --json)"
is "json agrees with the plain path on a dead rig" \
   "$(printf '%s' "$j" | jq -r '.assets[0].status + " " + .assets[0].detail')" "down not-listening"

echo "asset-chain — the two deadlines are ordered"

# THE PROBER'S OWN DEADLINE MUST FIT INSIDE asset_probe's, or the prober never
# gets to answer: against a blackholed host the outer clock kills it first and
# `unknown probe-timeout` replaces the one diagnosis that names the machine.
# The two numbers live in two files and were tuned independently once already
# (8s inside 5s), so the relationship is asserted here rather than trusted to
# the comments that now carry it.
ct="$(sed -n 's/.*ConnectTimeout=\([0-9][0-9]*\).*/\1/p' "$here/probes/chromium-rig" | head -1)"
lib="$(sed -n 's/.*STEWARD_ASSET_PROBE_TIMEOUT:-\([0-9][0-9]*\).*/\1/p' "$here/lib/assets.sh" | head -1)"
cli="$(sed -n 's/.*STEWARD_ASSET_PROBE_TIMEOUT:=\([0-9][0-9]*\).*/\1/p' "$here/bin/steward" | head -1)"
if [ -n "$ct" ] && [ -n "$lib" ] && [ -n "$cli" ]; then
  ok "all three deadlines were found where the comments say they are"
else
  bad "all three deadlines were found where the comments say they are" \
      "connect='$ct' library='$lib' cli='$cli'"
fi
if [ -n "$ct" ] && [ -n "$lib" ] && [ "$ct" -lt "$lib" ]; then
  ok "the prober's connect bound is under the library backstop ($ct < $lib)"
else
  bad "the prober's connect bound is under the library backstop" "connect=$ct library=$lib"
fi
if [ -n "$lib" ] && [ -n "$cli" ] && [ "$cli" -ge "$lib" ]; then
  ok "the command's deadline is not tighter than the backstop ($cli >= $lib)"
else
  bad "the command's deadline is not tighter than the backstop" "cli=$cli library=$lib"
fi

echo
# THE HOUSE'S COUNT LINE. tools/run-tests.sh reads `pass=N fail=M` and shows
# `?/?` for a suite whose numbers it cannot read — a green suite that cannot say
# what it measured is the silent measurement all of this exists to prevent.
printf 'pass=%s fail=%s\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
