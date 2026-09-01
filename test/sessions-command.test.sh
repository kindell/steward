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
# THE ORG LINEAGE IS ITS OWN TOP-LEVEL FIELD, ADDITIVE beside `entity` rather
# than nested inside it: it is DERIVED from the tree above the entity, not a
# property of the entity row, and a consumer that wants the managing team must
# not have to walk the registry a second time to get it.
is "lineage joined"   "$(printf '%s' "$j" | jq -r '.sessions[]|select(.name=="alpha")|.lineage')" "Team One→Acme"
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
# AND SO IS ITS LINEAGE — null, never the "-" the TSV layer uses. A consumer
# reading json has a type for absence and should not have to know this
# product's placeholder byte, exactly as `slug` and `display` already do.
is "lineage is null too" \
   "$(printf '%s' "$j3" | jq -r '.sessions[]|select(.name=="orphan")|.lineage')" "null"

echo "== the human form =="
t="$(run)"
has "the table names a session" "$t" "alpha"
has "and shows its liveness"    "$t" "up"
has "and marks the unmeasured"  "$t" "unknown"
# THE ORG COLUMN, IN THE TABLE AND NOT ONLY IN THE DOCUMENT. The operator
# reading a shared fleet at a terminal is the one who needs to know WHOSE work
# a row is; sending them to --json for it makes the human form the lesser
# answer.
has "the header carries ORG"    "$t" "ORG"
has "and the row carries the lineage" "$t" "Team One→Acme"
# AN UNRESOLVABLE ENTITY IS A DASH HERE TOO, and a dash is a column, not a gap:
# a blank cell in a column-aligned table reads as a rendering fault rather than
# as "the registry does not describe this one".
#
# MATCHED BY POSITION, NOT BY "a dash appears somewhere on the line" — the
# MODEL column of an unmeasured session is a dash too, so a substring test
# would pass whether or not ORG was ever rendered. The ORG cell is the one
# directly after OWNER. A regex rather than an awk field number because a
# lineage legitimately contains spaces ("Team One→Acme"), which whitespace
# field-splitting would read as two columns.
orphan_row="$(printf '%s\n' "$t" | grep -E '^orphan +')"
if printf '%s\n' "$orphan_row" | grep -Eq '^orphan +a +- +'; then
  ok  "an unresolvable entity renders a dash in ORG"
else
  bad "an unresolvable entity renders a dash in ORG" "row: '$orphan_row'"
fi

# THE COLUMN IS PADDED IN COLUMNS, NOT IN BYTES. The arrow is U+2192 — three
# bytes drawn as one column — and bash's printf counts a `%-22s` field width in
# BYTES, so a plain format string pads a two-name lineage two columns short and
# shifts everything to its right on that row alone.
#
# MEASURED IN BYTES ON PURPOSE, so this assertion says the same thing in every
# locale. Up to the TMUX column both lines occupy the same COLUMNS; the row
# carrying one arrow must therefore be longer by exactly the arrow's two extra
# BYTES. Byte-padding would make the two prefixes equal in bytes instead, which
# is the defect.
bytes() { printf '%s' "$1" | LC_ALL=C wc -c | tr -d ' '; }
hdr_line="$(printf '%s\n' "$t" | grep -E '^SESSION ')"
alpha_line="$(printf '%s\n' "$t" | grep -E '^alpha ')"
hdr_pre="${hdr_line%%TMUX*}"
alpha_pre="${alpha_line%%up*}"
is "the ORG cell is padded by columns, not by bytes" \
   "$(( $(bytes "$alpha_pre") - $(bytes "$hdr_pre") ))" "2"

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

# ── THE ESTATE FALLBACK RESOLUTION ──────────────────────────────────────────
#
# A SEPARATE, MINIMAL FIXTURE TREE — not a mutation of $FX above. Adding a
# LIVENESS_CMD line to $FX/estate/steward.conf would silently change what
# "== with no liveness command ==" measures (it would stop being the
# unconfigured case), and the earlier assertions in this file would then be
# testing an accident of insertion order rather than the contract they claim.
FX2="$(mktemp -d)"
FX3="$(mktemp -d)"
trap 'rm -rf "$FX" "$FX2" "$FX3"' EXIT
mkdir -p "$FX2/sessions.d" "$FX2/entities.d" "$FX2/estate"
printf 'LABEL_PREFIX="com.fixture.claude"\nHUB_HOST="h1"\nOP_TOKEN_FILE_NAME="fixture-token"\nLIVENESS_CMD="%s"\n' \
  "$FX2/estate-shim" > "$FX2/estate/steward.conf"
printf 'HOST="h1"\nOWNER="a"\nDOMAIN="acme"\nRC_LABEL="L"\nREPO_PATH="/tmp/x"\nID="alpha"\n' \
  > "$FX2/sessions.d/alpha.conf"
printf 'NAME="Acme"\n' > "$FX2/entities.d/acme.conf"

cat > "$FX2/estate-shim" <<'EOF'
#!/bin/bash
echo ran > "$(dirname "$0")/estate-shim.ran"
cat <<'J'
{"sessions":{"alpha":{"daemon":"loaded","tmux":"up","agent":"running","runtime":"claude-code"}}}
J
EOF
chmod +x "$FX2/estate-shim"

cat > "$FX2/env-shim" <<'EOF'
#!/bin/bash
echo ran > "$(dirname "$0")/env-shim.ran"
cat <<'J'
{"sessions":{"alpha":{"daemon":"loaded","tmux":"up","agent":"running","runtime":"claude-code"}}}
J
EOF
chmod +x "$FX2/env-shim"

# THE PROCESS ENVIRONMENT WINS, EVEN THOUGH THE ESTATE ALSO NAMES A SHIM.
# Which stub actually ran is proved by its OWN marker file, not just by the
# json coming back healthy — a resolution bug that ran the wrong stub could
# still answer correctly if both stubs happen to agree on alpha's liveness.
echo "== resolution: an explicit STEWARD_LIVENESS_CMD wins over the estate field =="
rm -f "$FX2/env-shim.ran" "$FX2/estate-shim.ran"
j4="$(STEWARD_REGISTRY_DIR="$FX2/sessions.d" STEWARD_ESTATE_ROOT="$FX2" STEWARD_VIEWER="a" \
      STEWARD_LIVENESS_CMD="$FX2/env-shim" bash "$STEWARD" sessions --json 2>&1)"
is "the env stub ran"          "$( [ -e "$FX2/env-shim.ran" ]    && echo yes || echo no )" "yes"
is "the estate stub did not run" "$( [ -e "$FX2/estate-shim.ran" ] && echo yes || echo no )" "no"
is "liveness measured via the env stub" \
   "$(printf '%s' "$j4" | jq -r '.sessions[]|select(.name=="alpha")|.liveness.tmux')" "up"

# WITH THE ENVIRONMENT SILENT, THE ESTATE'S OWN FIELD GETS A TURN.
echo "== resolution: with STEWARD_LIVENESS_CMD unset, the estate's own shim runs =="
rm -f "$FX2/env-shim.ran" "$FX2/estate-shim.ran"
j5="$(STEWARD_REGISTRY_DIR="$FX2/sessions.d" STEWARD_ESTATE_ROOT="$FX2" STEWARD_VIEWER="a" \
      env -u STEWARD_LIVENESS_CMD bash "$STEWARD" sessions --json 2>&1)"
is "the estate stub ran"     "$( [ -e "$FX2/estate-shim.ran" ] && echo yes || echo no )" "yes"
is "the env stub did not run" "$( [ -e "$FX2/env-shim.ran" ]    && echo yes || echo no )" "no"
is "liveness measured via the estate stub" \
   "$(printf '%s' "$j5" | jq -r '.sessions[]|select(.name=="alpha")|.liveness.tmux')" "up"

# NEITHER SET: the fixture at $FX (used throughout the rest of this file)
# names no LIVENESS_CMD in its estate file, and "== with no liveness command,
# every session is still listed and unknown ==" above already asserts the
# seam-not-configured reason for exactly that case — this comment records the
# coverage rather than duplicating the fixture.

# AN ESTATE FIELD THAT FAILS registry_liveness_cmd'S FORM CHECK REFUSES THE
# WHOLE INVOCATION — not a `sessions` table that quietly renders every
# liveness column `unknown` with no clue why the estate's own line did not
# take effect.
mkdir -p "$FX3/sessions.d" "$FX3/entities.d" "$FX3/estate"
printf 'LABEL_PREFIX="com.fixture.claude"\nHUB_HOST="h1"\nOP_TOKEN_FILE_NAME="fixture-token"\nLIVENESS_CMD="relative/shim"\n' \
  > "$FX3/estate/steward.conf"
printf 'HOST="h1"\nOWNER="a"\nDOMAIN="acme"\nRC_LABEL="L"\nREPO_PATH="/tmp/x"\nID="alpha"\n' \
  > "$FX3/sessions.d/alpha.conf"
printf 'NAME="Acme"\n' > "$FX3/entities.d/acme.conf"

# SAME SHAPE AS THE EXISTING HUB_HOST REFUSAL FURTHER UP: the json form's
# reason field IS the diagnostic text; nothing is additionally duplicated onto
# stderr in this branch, matching every other early refusal in cmd_sessions
# (see "an unreadable registry refuses in both forms" above, whose --json case
# routes stderr to /dev/null and asserts on `.reason` alone). The plain form
# below is where stderr itself is asserted on.
echo "== resolution: an invalid estate field refuses the whole invocation (json) =="
j6="$(STEWARD_REGISTRY_DIR="$FX3/sessions.d" STEWARD_ESTATE_ROOT="$FX3" STEWARD_VIEWER="a" \
      env -u STEWARD_LIVENESS_CMD bash "$STEWARD" sessions --json 2>/dev/null)"; j6rc=$?
is "refusal rc is 78" "$j6rc" "78"
is "ok is false"      "$(printf '%s' "$j6" | jq -r '.ok')" "false"
has "the reason names the estate field" "$(printf '%s' "$j6" | jq -r '.reason')" "LIVENESS_CMD"

echo "== resolution: an invalid estate field refuses the whole invocation (plain) =="
p6err="$(mktemp)"
p6out="$(STEWARD_REGISTRY_DIR="$FX3/sessions.d" STEWARD_ESTATE_ROOT="$FX3" STEWARD_VIEWER="a" \
      env -u STEWARD_LIVENESS_CMD bash "$STEWARD" sessions 2>"$p6err")"; p6rc=$?
p6errtext="$(cat "$p6err")"; rm -f "$p6err"
is "refusal rc is 78 in the plain form too" "$p6rc" "78"
is "plain refusal's stdout is empty"        "$p6out" ""
has "plain refusal names the estate field on stderr" "$p6errtext" "LIVENESS_CMD"

# ── --sort ────────────────────────────────────────────────────────────────
#
# A DEDICATED FIXTURE, not a mutation of $FX above. The three session names
# are picked so their FILENAME order (registry_list's own order, alphabetical
# by name) disagrees with SLUG order, OWNER order, HOST order and RC_LABEL
# (display) order — a suite that reused $FX, whose two live sessions already
# happen to sort the same way under every key, could not tell "the flag
# reordered the rows" from "the rows were already in that order".
FX4="$(mktemp -d)"
trap 'rm -rf "$FX" "$FX2" "$FX3" "$FX4"' EXIT
mkdir -p "$FX4/sessions.d" "$FX4/entities.d" "$FX4/estate"
printf 'LABEL_PREFIX="com.fixture.claude"\nHUB_HOST="h1"\nOP_TOKEN_FILE_NAME="fixture-token"\n' \
  > "$FX4/estate/steward.conf"
# name=asess: OWNER first alphabetically, HOST last, SLUG last, display first.
printf 'HOST="hzz"\nOWNER="aowner"\nDOMAIN="acme"\nRC_LABEL="rlA"\nREPO_PATH="/tmp/x"\nID="asess"\nSLUG="zzz-slug"\n' \
  > "$FX4/sessions.d/asess.conf"
# name=msess: OWNER middle, HOST middle, NO SLUG (the dash case), display middle.
printf 'HOST="hmm"\nOWNER="mowner"\nDOMAIN="acme"\nRC_LABEL="rlM"\nREPO_PATH="/tmp/x"\nID="msess"\n' \
  > "$FX4/sessions.d/msess.conf"
# name=zsess: OWNER last, HOST first, SLUG first, display last.
printf 'HOST="haa"\nOWNER="zowner"\nDOMAIN="acme"\nRC_LABEL="rlZ"\nREPO_PATH="/tmp/x"\nID="zsess"\nSLUG="aaa-slug"\n' \
  > "$FX4/sessions.d/zsess.conf"
# MEMBERS, NOT A MATCHING OWNER — visibility grants a session to its OWNER or
# to a MEMBER of the entity that owns it. The three OWNER values above are
# deliberately none of them "a" (they exist to drive --sort owner), so "a"
# must reach every row through team membership instead.
#
# THREE ENTITIES, ONE PER SESSION, whose display NAMEs disagree with every
# other key's order — the same reason the three confs above disagree on OWNER,
# HOST and SLUG. A fixture where every session shared one entity could not tell
# "--sort lineage reordered the rows" from "the rows never moved".
printf 'NAME="Acme"\nMEMBERS="a"\n'        > "$FX4/entities.d/acme.conf"
printf 'NAME="Midway"\nMEMBERS="a"\n'      > "$FX4/entities.d/h1.conf"
printf 'NAME="Zeta Works"\nMEMBERS="a"\n'  > "$FX4/entities.d/beta.conf"
# asess -> "Zeta Works" (last), msess -> "Acme" (first), zsess -> "Midway".
# TARGET_ENTITY rather than a rewritten DOMAIN, so these rows also state their
# owning entity the way a migrated row does.
printf 'TARGET_ENTITY="beta"\n' >> "$FX4/sessions.d/asess.conf"
printf 'TARGET_ENTITY="acme"\n' >> "$FX4/sessions.d/msess.conf"
printf 'TARGET_ENTITY="h1"\n'   >> "$FX4/sessions.d/zsess.conf"
# THE DASH ROW. Its entity does not resolve, so its ORG column is "-" and the
# shared reorder must put it LAST, behind every row that carries a real value.
# OWNER="a" is what makes it visible at all — there is no entity to grant it.
printf 'HOST="hmm"\nOWNER="a"\nDOMAIN="nosuch-entity"\nRC_LABEL="rlN"\nREPO_PATH="/tmp/x"\nID="nsess"\n' \
  > "$FX4/sessions.d/nsess.conf"

run4() { STEWARD_REGISTRY_DIR="$FX4/sessions.d" STEWARD_ESTATE_ROOT="$FX4" STEWARD_VIEWER="a" \
         env -u STEWARD_LIVENESS_CMD bash "$STEWARD" sessions "$@" 2>&1; }
# THE ORDER OF THE THREE SESSION NAMES, READ OFF THE TABLE'S OWN FIRST
# COLUMN — not a substring search, which cannot tell order from mere presence.
order4() { printf '%s\n' "$1" | awk '{print $1}' | grep -E '^(asess|msess|zsess)$' | tr '\n' ',' ; }

echo "== --sort: with no flag, the order is unchanged (filename/id) =="
is "default order is filename order" "$(order4 "$(run4)")" "asess,msess,zsess,"

echo "== --sort name: same as today's order, named explicitly =="
is "name order" "$(order4 "$(run4 --sort name)")" "asess,msess,zsess,"

echo "== --sort owner: alphabetical by OWNER =="
is "owner order" "$(order4 "$(run4 --sort owner)")" "asess,msess,zsess,"

echo "== --sort host: alphabetical by HOST, disagrees with filename order =="
is "host order" "$(order4 "$(run4 --sort host)")" "zsess,msess,asess,"

echo "== --sort display: alphabetical by the resolved display (RC_LABEL here) =="
is "display order" "$(order4 "$(run4 --sort display)")" "asess,msess,zsess,"

echo "== --sort slug: alphabetical by SLUG, dash (no slug) rows last =="
is "slug order, dash last" "$(order4 "$(run4 --sort slug)")" "zsess,asess,msess,"

# THE FOURTH SESSION IS ONLY EVER READ HERE. `order4` above deliberately does
# not match it, so every assertion written before this one measures exactly
# what it measured before nsess existed.
order4n() { printf '%s\n' "$1" | awk '{print $1}' | grep -E '^(asess|msess|nsess|zsess)$' | tr '\n' ',' ; }

echo "== --sort lineage: alphabetical by the ORG lineage, dash rows last =="
is "lineage order, dash last" "$(order4n "$(run4 --sort lineage)")" "msess,zsess,asess,nsess,"

echo "== --sort with an unknown key refuses, listing the valid ones =="
uerr="$(mktemp)"
uout="$(STEWARD_REGISTRY_DIR="$FX4/sessions.d" STEWARD_ESTATE_ROOT="$FX4" STEWARD_VIEWER="a" \
        env -u STEWARD_LIVENESS_CMD bash "$STEWARD" sessions --sort bogus 2>"$uerr")"; urc=$?
uerrtext="$(cat "$uerr")"; rm -f "$uerr"
is "rc is 64" "$urc" "64"
is "stdout is empty" "$uout" ""
has "names the bad key" "$uerrtext" "bogus"
has "lists slug"    "$uerrtext" "slug"
has "lists display"  "$uerrtext" "display"
has "lists owner"    "$uerrtext" "owner"
has "lists host"     "$uerrtext" "host"
has "lists name"     "$uerrtext" "name"
has "lists lineage"  "$uerrtext" "lineage"

echo "== --sort with an unknown key, --json form =="
ujerr="$(mktemp)"
ujout="$(STEWARD_REGISTRY_DIR="$FX4/sessions.d" STEWARD_ESTATE_ROOT="$FX4" STEWARD_VIEWER="a" \
         env -u STEWARD_LIVENESS_CMD bash "$STEWARD" sessions --sort bogus --json 2>"$ujerr")"; ujrc=$?
is "rc is 64 in json form too" "$ujrc" "64"
is "ok is false"    "$(printf '%s' "$ujout" | jq -r '.ok')" "false"
has "reason names the bad key" "$(printf '%s' "$ujout" | jq -r '.reason')" "bogus"

echo
printf 'pass=%s fail=%s\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
