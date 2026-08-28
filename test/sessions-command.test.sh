#!/bin/bash
# test/sessions-command.test.sh — the command that joins the two layers.
#
# THIS IS THE CONTRACT A VIEW READS. Everything below is about the shape a
# consumer sees, not about how either layer measured. The two layers have their
# own suites; this one asserts the join and the rendering.
#
# HERMETIC: fixture registry, stub liveness command. Never a real socket.
set -u

here="$(CDPATH= cd -- "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
STEWARD="$here/bin/steward"
pass=0; fail=0
ok()  { pass=$((pass+1)); printf '  ok   %s\n' "$1"; }
bad() { fail=$((fail+1)); printf '  FAIL %s\n     %s\n' "$1" "${2:-}"; }
is()  { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "wanted '$3', got '$2'"; fi; }
has() { case "$2" in *"$3"*) ok "$1" ;; *) bad "$1" "missing '$3' in: $2" ;; esac; }

FX="$(mktemp -d)"; trap 'rm -rf "$FX"' EXIT
mkdir -p "$FX/sessions.d" "$FX/entities.d" "$FX/estate"
# THE ESTATE FILE IS A PRECONDITION, NOT DECORATION. registry_load refuses with
# rc 78 when it cannot read the estate's label prefix and hub — so a fixture
# without this file makes EVERY session fail to load, and the suite then measures
# a missing fixture rather than the code it was written for.
printf 'LABEL_PREFIX="com.fixture.claude"\nHUB_HOST="h1"\nOP_TOKEN_FILE_NAME="fixture-token"\n' \
  > "$FX/estate/steward.conf"
printf 'HOST="h1"\nOWNER="a"\nDOMAIN="acme"\nRC_LABEL="L"\nREPO_PATH="/tmp/x"\nID="alpha"\nASSETS="widget"\n' \
  > "$FX/sessions.d/alpha.conf"
printf 'HOST="h1"\nOWNER="a"\nDOMAIN="acme"\nRC_LABEL="L"\nREPO_PATH="/tmp/x"\nID="beta"\n' \
  > "$FX/sessions.d/beta.conf"
printf 'NAME="Acme"\nMANAGED_BY="team-one"\n' > "$FX/entities.d/acme.conf"

cat > "$FX/live" <<'EOF'
#!/bin/bash
cat <<'J'
{"sessions":{"alpha":{"daemon":"loaded","tmux":"up","agent":"running",
 "runtime":"claude-code","model":"opus","lastActivity":"2026-08-28T09:00:00.000Z"}}}
J
EOF
chmod +x "$FX/live"

run() { STEWARD_REGISTRY_DIR="$FX/sessions.d" STEWARD_ESTATE_ROOT="$FX" \
        STEWARD_LIVENESS_CMD="$FX/live" bash "$STEWARD" sessions "$@" 2>&1; }

echo "== the json contract =="
j="$(run --json)"; rc=$?
is "rc 0" "$rc" "0"
is "ok is true"       "$(printf '%s' "$j" | jq -r '.ok')" "true"
is "two sessions"     "$(printf '%s' "$j" | jq -r '.sessions | length')" "2"
is "identity joined"  "$(printf '%s' "$j" | jq -r '.sessions[]|select(.name=="alpha")|.owner')" "a"
is "entity joined"    "$(printf '%s' "$j" | jq -r '.sessions[]|select(.name=="alpha")|.entity.name')" "Acme"
is "relation joined"  "$(printf '%s' "$j" | jq -r '.sessions[]|select(.name=="alpha")|.entity.relation')" "client"
is "liveness joined"  "$(printf '%s' "$j" | jq -r '.sessions[]|select(.name=="alpha")|.liveness.tmux')" "up"
is "model joined"     "$(printf '%s' "$j" | jq -r '.sessions[]|select(.name=="alpha")|.liveness.model')" "opus"

# ASSETS IS ALWAYS A LIST. A consumer that had to handle both a string and a
# list would get it wrong once; an empty list says "declares nothing" in the
# same shape as "declares two".
echo "== assets is a list, and empty means undeclared =="
is "one asset"                "$(printf '%s' "$j" | jq -r '.sessions[]|select(.name=="alpha")|.assets|length')" "1"
is "the asset itself"         "$(printf '%s' "$j" | jq -r '.sessions[]|select(.name=="alpha")|.assets[0]')" "widget"
is "undeclared is an EMPTY list, not null" \
   "$(printf '%s' "$j" | jq -r '.sessions[]|select(.name=="beta")|.assets|length')" "0"
is "and it is a list, not null" \
   "$(printf '%s' "$j" | jq -r '.sessions[]|select(.name=="beta")|.assets|type')" "array"

# THE SESSION THE LIVENESS COMMAND NEVER MENTIONED. This is the case the whole
# design exists for: `beta` was not measured, and it must not read as healthy
# and must not read as absent.
echo "== an unmeasured session is unknown on every liveness field =="
is "daemon"  "$(printf '%s' "$j" | jq -r '.sessions[]|select(.name=="beta")|.liveness.daemon')" "unknown"
is "tmux"    "$(printf '%s' "$j" | jq -r '.sessions[]|select(.name=="beta")|.liveness.tmux')" "unknown"
is "agent"   "$(printf '%s' "$j" | jq -r '.sessions[]|select(.name=="beta")|.liveness.agent')" "unknown"
is "model is null, not the string unknown" \
   "$(printf '%s' "$j" | jq -r '.sessions[]|select(.name=="beta")|.liveness.model')" "null"
# THE TIMESTAMP TOO. `model` and `lastActivity` are DATA fields, not status
# fields: a dash means "no value" and becomes null here, while `unknown` is the
# word the STATUS fields use. Putting a status word in a data field would make
# this one key render as a string where every other nullable key renders null.
is "lastActivity is null too, not the string unknown" \
   "$(printf '%s' "$j" | jq -r '.sessions[]|select(.name=="beta")|.liveness.lastActivity')" "null"

# NO LIVENESS COMMAND AT ALL is the state of a fresh estate. Every session must
# then be unknown — never healthy, never missing from the list.
echo "== with no liveness command, every session is still listed and unknown =="
j2="$(STEWARD_REGISTRY_DIR="$FX/sessions.d" STEWARD_ESTATE_ROOT="$FX" \
      env -u STEWARD_LIVENESS_CMD bash "$STEWARD" sessions --json 2>&1)"
is "both sessions still listed" "$(printf '%s' "$j2" | jq -r '.sessions | length')" "2"
is "alpha is unknown too"       "$(printf '%s' "$j2" | jq -r '.sessions[]|select(.name=="alpha")|.liveness.tmux')" "unknown"

# A DOMAIN WITH NO ENTITY FILE. null, not an empty object that a view would
# render as an entity with a blank name.
echo "== a missing entity is null =="
printf 'HOST="h1"\nOWNER="a"\nDOMAIN="nosuch"\nRC_LABEL="L"\nREPO_PATH="/tmp/x"\nID="orphan"\n' \
  > "$FX/sessions.d/orphan.conf"
j3="$(run --json)"
is "entity is null" "$(printf '%s' "$j3" | jq -r '.sessions[]|select(.name=="orphan")|.entity')" "null"

echo "== the human form =="
t="$(run)"
has "the table names a session" "$t" "alpha"
has "and shows its liveness"    "$t" "up"
has "and marks the unmeasured"  "$t" "unknown"

# A SESSION THAT EXISTS BUT WON'T LOAD, ALONGSIDE ONES THAT DO. rc stays 0 (a
# partial failure is not a systemic one) and lib/sessions.sh puts a diagnostic
# sentence on STDERR. The bug this reproduces: capturing that diagnostic into
# the same variable as the TSV data corrupts stdout — `--json` fed the merged
# text into jq's split() and produced NO valid JSON at all, while still
# exiting 0. This is the RED case: it must fail before the capture is split.
echo "== a partial identity failure does not corrupt stdout (json) =="
printf 'HOST="h1"\nOWNER="a"\nDOMAIN="acme"\nRC_LABEL="L"\nID="broken"\n' \
  > "$FX/sessions.d/broken.conf"

jerr="$(mktemp)"
jout="$(STEWARD_REGISTRY_DIR="$FX/sessions.d" STEWARD_ESTATE_ROOT="$FX" \
        STEWARD_LIVENESS_CMD="$FX/live" bash "$STEWARD" sessions --json 2>"$jerr")"
jrc=$?
jerrtext="$(cat "$jerr")"; rm -f "$jerr"
is "rc is still 0"           "$jrc" "0"
is "stdout is valid json"    "$(printf '%s' "$jout" | jq -e . >/dev/null 2>&1 && echo yes || echo no)" "yes"
is "ok is true"               "$(printf '%s' "$jout" | jq -r '.ok' 2>/dev/null)" "true"
is "the good session is present" \
   "$(printf '%s' "$jout" | jq -r '[.sessions[].name] | index("alpha") != null' 2>/dev/null)" "true"
case "$jout" in
  *broken*) bad "the broken session's name is not inside the JSON" "found 'broken' in: $jout" ;;
  *)        ok  "the broken session's name is not inside the JSON" ;;
esac
has "the diagnostic reached this command's own stderr instead" "$jerrtext" "broken"

echo "== the same partial failure, human form =="
herr="$(mktemp)"
hout="$(STEWARD_REGISTRY_DIR="$FX/sessions.d" STEWARD_ESTATE_ROOT="$FX" \
        STEWARD_LIVENESS_CMD="$FX/live" bash "$STEWARD" sessions 2>"$herr")"
hrc=$?
herrtext="$(cat "$herr")"; rm -f "$herr"
is "rc is still 0" "$hrc" "0"
has "the good session's row is present" "$hout" "alpha"
case "$hout" in
  *"skipping"*) bad "the diagnostic sentence is not spliced into stdout" "found 'skipping' in: $hout" ;;
  *)            ok  "the diagnostic sentence is not spliced into stdout" ;;
esac
has "but the diagnosis survives — on stderr" "$herrtext" "skipping 'broken'"

# AN UNREADABLE REGISTRY REFUSES, in both forms, and the json form must still be
# json — a consumer that gets a bare error string on stdout cannot parse it.
echo "== an unreadable registry refuses in both forms =="
e="$(STEWARD_REGISTRY_DIR="$FX/nope" STEWARD_ESTATE_ROOT="$FX" \
     bash "$STEWARD" sessions --json 2>/dev/null)"; erc=$?
is "json refusal is non-zero" "$( [ "$erc" -ne 0 ] && echo yes || echo no )" "yes"
is "and is still json"        "$(printf '%s' "$e" | jq -r '.ok')" "false"
has "and the reason is the actual refusal text, not empty" \
   "$(printf '%s' "$e" | jq -r '.reason')" "registry"

# THE PLAIN-TEXT REFUSAL WAS PREVIOUSLY UNASSERTED — only the --json refusal's
# content was checked. A fix that routed stderr to a file and then forgot to
# read it back would silently produce an empty reason, and only an assertion
# on the actual text (not just "non-zero rc") would catch that.
eo="$(STEWARD_REGISTRY_DIR="$FX/nope" STEWARD_ESTATE_ROOT="$FX" \
      bash "$STEWARD" sessions 2>/dev/null)"; eorc=$?
et="$(STEWARD_REGISTRY_DIR="$FX/nope" STEWARD_ESTATE_ROOT="$FX" \
      bash "$STEWARD" sessions 2>&1 1>/dev/null)"
is "plain refusal is non-zero too" "$( [ "$eorc" -ne 0 ] && echo yes || echo no )" "yes"
is "plain refusal's stdout is empty" "$eo" ""
has "plain refusal's reason lands on stderr" "$et" "registry"

echo
printf 'pass=%s fail=%s\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
