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
# THE MANAGER MUST EXIST. The entity join goes through registry_entity_load,
# which refuses a MANAGED_BY that does not resolve — a relation pointing at
# nothing reads as structure and carries none. A fixture that omitted this file
# would be measuring a broken registry rather than the join.
printf 'NAME="Team One"\nMEMBERS="a"\n' > "$FX/entities.d/team-one.conf"

cat > "$FX/live" <<'EOF'
#!/bin/bash
cat <<'J'
{"sessions":{"alpha":{"daemon":"loaded","tmux":"up","agent":"running",
 "runtime":"claude-code","model":"opus","lastActivity":"2026-08-28T09:00:00.000Z"}}}
J
EOF
chmod +x "$FX/live"

# STEWARD_VIEWER: the command's answer depends on who is asking — a session
# invisible to the viewer is hidden, not listed — so a suite that never says
# who it is testing as is testing an accident of whichever account happens to
# run it. Every fixture session below is OWNER="a", so "a" is the viewer that
# legitimately sees all of them; the owner check in lib/visibility.sh always
# wins regardless of entity membership, which is why one viewer covers alpha,
# beta, orphan and broken alike.
run() { STEWARD_REGISTRY_DIR="$FX/sessions.d" STEWARD_ESTATE_ROOT="$FX" \
        STEWARD_LIVENESS_CMD="$FX/live" STEWARD_VIEWER="a" bash "$STEWARD" sessions "$@" 2>&1; }

echo "== the json contract =="
j="$(run --json)"; rc=$?
is "rc 0" "$rc" "0"
is "ok is true"       "$(printf '%s' "$j" | jq -r '.ok')" "true"
# The document declares WHICH HOST IS HOME. A consumer deciding whether a
# session can be attached locally needs the hub's name next to each session's
# host — without it, the cockpit attached a remote-host session to the local
# tmux and got "can't find session", measured on the real hub.
is "hub declared"     "$(printf '%s' "$j" | jq -r '.hub')" "h1"
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

# AND THE UNKNOWN SAYS WHY. Six distinct causes render as this one word; a view
# cannot invent a reason it was never given, so the reason travels with it.
# `reason` is a DETAIL beside the status words, never a fifth status word.
echo "== an unknown carries its reason; a measurement carries none =="
is "the reason key is always there" \
   "$(printf '%s' "$j" | jq -r '.sessions[]|select(.name=="alpha")|.liveness|has("reason")')" "true"
is "a measured session has no reason to give" \
   "$(printf '%s' "$j" | jq -r '.sessions[]|select(.name=="alpha")|.liveness.reason')" "null"
is "an unmeasured session says the seam did not mention it" \
   "$(printf '%s' "$j" | jq -r '.sessions[]|select(.name=="beta")|.liveness.reason')" "not-in-answer"

# NO LIVENESS COMMAND AT ALL is the state of a fresh estate. Every session must
# then be unknown — never healthy, never missing from the list.
echo "== with no liveness command, every session is still listed and unknown =="
j2="$(STEWARD_REGISTRY_DIR="$FX/sessions.d" STEWARD_ESTATE_ROOT="$FX" STEWARD_VIEWER="a" \
      env -u STEWARD_LIVENESS_CMD bash "$STEWARD" sessions --json 2>&1)"
is "both sessions still listed" "$(printf '%s' "$j2" | jq -r '.sessions | length')" "2"
is "alpha is unknown too"       "$(printf '%s' "$j2" | jq -r '.sessions[]|select(.name=="alpha")|.liveness.tmux')" "unknown"
is "and every one of them says WHY it is unknown" \
   "$(printf '%s' "$j2" | jq -r '[.sessions[]|select(.liveness.reason=="seam-not-configured")]|length')" "2"

# THE HUMAN FORM SAYS IT TOO — on stderr, so the table stays pure data.
h2err="$(mktemp)"
STEWARD_REGISTRY_DIR="$FX/sessions.d" STEWARD_ESTATE_ROOT="$FX" STEWARD_VIEWER="a" \
  env -u STEWARD_LIVENESS_CMD bash "$STEWARD" sessions >/dev/null 2>"$h2err"
has "the human form names the missing variable" "$(cat "$h2err")" "STEWARD_LIVENESS_CMD"
rm -f "$h2err"

# A SEAM THAT WAS CONFIGURED AND COULD NOT BE RUN IS A DIFFERENT FACT FROM ONE
# THAT WAS NEVER CONFIGURED — and neither may render as the other.
echo "== a seam that could not be run says so, on stderr and in the document =="
serr="$(mktemp)"
j2b="$(STEWARD_REGISTRY_DIR="$FX/sessions.d" STEWARD_ESTATE_ROOT="$FX" STEWARD_VIEWER="a" \
       STEWARD_LIVENESS_CMD="$FX/no-such-shim" bash "$STEWARD" sessions --json 2>"$serr")"
serrtext="$(cat "$serr")"; rm -f "$serr"
is "the sessions are still listed" "$(printf '%s' "$j2b" | jq -r '.sessions | length')" "2"
is "with a reason that is not the unconfigured one" \
   "$(printf '%s' "$j2b" | jq -r '.sessions[0].liveness.reason')" "seam-not-found"
is "and stdout is still valid json" \
   "$(printf '%s' "$j2b" | jq -e . >/dev/null 2>&1 && echo yes || echo no)" "yes"
has "and the diagnosis is on stderr, not in the table" "$serrtext" "no-such-shim"

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
jout="$(STEWARD_REGISTRY_DIR="$FX/sessions.d" STEWARD_ESTATE_ROOT="$FX" STEWARD_VIEWER="a" \
        STEWARD_LIVENESS_CMD="$FX/live" bash "$STEWARD" sessions --json 2>"$jerr")"
jrc=$?
jerrtext="$(cat "$jerr")"; rm -f "$jerr"
is "rc is still 0"           "$jrc" "0"
is "stdout is valid json"    "$(printf '%s' "$jout" | jq -e . >/dev/null 2>&1 && echo yes || echo no)" "yes"
is "ok is true"               "$(printf '%s' "$jout" | jq -r '.ok' 2>/dev/null)" "true"
is "the good session is present" \
   "$(printf '%s' "$jout" | jq -r '[.sessions[].name] | index("alpha") != null' 2>/dev/null)" "true"
is "the broken session is absent from the session list" \
   "$(printf '%s' "$jout" | jq -r '[.sessions[].name] | index("broken") // "absent"' 2>/dev/null)" "absent"
# A SESSION THAT VANISHES IS THE SPEC'S FOUNDING COMPLAINT WITH FEWER ROWS.
# `ok:true` beside a shorter list asserts the answer is complete. The diagnosis
# exists on stderr and stays there — but the declared consumer is a view reading
# --json from a subprocess, and nothing in the contract tells it to capture and
# correlate a second stream. So the document carries it too.
is "but it is named in unreadable" \
   "$(printf '%s' "$jout" | jq -r '.unreadable | index("broken") != null' 2>/dev/null)" "true"
is "and unreadable is a list, always present" \
   "$(printf '%s' "$jout" | jq -r '.unreadable | type' 2>/dev/null)" "array"
has "the diagnostic reached this command's own stderr as well" "$jerrtext" "broken"

echo "== the same partial failure, human form =="
herr="$(mktemp)"
hout="$(STEWARD_REGISTRY_DIR="$FX/sessions.d" STEWARD_ESTATE_ROOT="$FX" STEWARD_VIEWER="a" \
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
