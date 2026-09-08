#!/bin/bash
# test/desk-snapshot.test.sh - the desk snapshot: one filtered file per
# principal, written into a fresh generation and swapped in atomically, with
# sentinel values in the registry that prove what never leaves.
set -u
here="$(CDPATH= cd -- "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
pass=0; fail=0
ok()  { pass=$((pass+1)); printf '  ok   %s\n' "$1"; }
bad() { fail=$((fail+1)); printf '  FAIL %s\n     %s\n' "$1" "${2:-}"; }
is()  { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "wanted '$3', got '$2'"; fi; }
has() { case "$2" in *"$3"*) ok "$1" ;; *) bad "$1" "missing '$3' in: $2" ;; esac; }
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT

# THE FIXTURE ESTATE - the same shape test/mcp-surface.test.sh builds, plus the
# principal rows the desk filters by. Three principals: `a` reads everything,
# `b` is a member of `team`, `c` is a member of nothing. Two sessions, both
# owned by rows that carry SENTINEL values the snapshot must never copy out.
ROOT="$T/estate"
mkdir -p "$ROOT"/{estate,sessions.d,entities.d,projects.d,accounts.d,mcp.d,hosts.d,principals.d}
cat > "$ROOT/estate/steward.conf" <<'EOF'
ESTATE_NAME="fixture"
LABEL_PREFIX="com.fixture.claude"
JOB_LABEL_PREFIX="com.fixture.job"
SERVICE_LABEL_PREFIX="com.fixture.svc"
RC_LABEL_PREFIX=""
HUB_SESSION="hub"
HUB_HOST="h1"
STATE_DIR_NAME="fixture-supervisor"
PAUSED_DIR_NAME="fixture-paused"
TMUX_SOCKET="fixture.sock"
OP_TOKEN_FILE_NAME="fixture-token"
PING_MSG="mail"
EOF
printf 'OWNER="a"\nOPERATOR="hub"\n' > "$ROOT/hosts.d/h1.conf"
printf 'NAME="Team"\nMEMBERS="a b"\nMCP_ASSETS="shared"\n' > "$ROOT/entities.d/team.conf"
printf 'NAME="Work"\nPARENT="team"\nMCP_ASSETS="tool"\n' > "$ROOT/projects.d/work.conf"
printf 'PRINCIPAL="a"\nHOST="h1"\nMCP_ASSETS="mail"\n' > "$ROOT/accounts.d/a-h1.conf"
printf 'PRINCIPAL="b"\nHOST="h1"\n' > "$ROOT/accounts.d/b-h1.conf"
for m in shared tool mail; do
  printf 'MCP_COMMAND="/usr/bin/%s"\nMCP_ARGS="--token SENTINEL_ARG"\nMCP_ENV_FILE="~/SENTINEL_ENV"\n' "$m" > "$ROOT/mcp.d/$m.conf"
done
printf 'NAME="Ann"\nTAILSCALE_LOGIN="a@example.com"\nDESK_READ_ALL="yes"\n' > "$ROOT/principals.d/a.conf"
printf 'NAME="Ben"\nTAILSCALE_LOGIN="b@example.com"\n'                      > "$ROOT/principals.d/b.conf"
printf 'NAME="Cy"\nTAILSCALE_LOGIN="c@example.com"\n'                       > "$ROOT/principals.d/c.conf"

SID_A="s-0000000000000021"
SID_B="s-0000000000000022"
cat > "$ROOT/sessions.d/$SID_A.conf" <<EOF
OWNER="a"
HOST="h1"
DOMAIN="work"
REPO_PATH="$T/SENTINEL_PATH/repo"
ID="$SID_A"
SLUG="work-a"
ACCOUNT="a-h1"
TARGET_PROJECT="work"
KIND="work"
BROWSER_RIG="yes"
BROWSER_DISPLAY="11"
BROWSER_CDP="9999"
BROWSER_VNC="22"
EOF
cat > "$ROOT/sessions.d/$SID_B.conf" <<EOF
OWNER="b"
HOST="h1"
DOMAIN="team"
REPO_PATH="$T/SENTINEL_PATH/repo"
ID="$SID_B"
SLUG="team-b"
ACCOUNT="b-h1"
TARGET_ENTITY="team"
KIND="work"
EOF

# THE LIVENESS ANSWER IS INJECTED THROUGH THE PRODUCT'S OWN SEAM, NEVER
# MEASURED HERE. The producer reads liveness_rows, whose command is named by
# STEWARD_LIVENESS_CMD; the real one reads a live multiplexer socket and a
# suite that let it run could type into a real conversation. The shim below is
# that seam's contract shape - an object keyed by session NAME, which is what
# registry_list yields.
#
# ONE SESSION IS MEASURED AND ONE IS NOT, ON PURPOSE. A shim that answered
# about every session could not tell a caller that reads absence as health
# apart from one that reads it as `unknown`.
cat > "$T/shim" <<EOF
#!/bin/bash
printf '{"sessions":{"%s":{"daemon":"loaded","tmux":"up","agent":"running","runtime":"claude-code","model":null,"lastActivity":"%s"}}}\n' \\
  "$SID_A" "\$(date -u +%Y-%m-%dT%H:%M:%SZ)"
EOF
chmod +x "$T/shim"

export STEWARD_ESTATE_ROOT="$ROOT" STEWARD_CONFIG_FILE="$T/no-such-config"
export HOME="$T/home"; mkdir -p "$HOME"
echo "desk-snapshot"

run() {
  STEWARD_DESK_DIR="$T/desk" STEWARD_LIVENESS_CMD="$T/shim" \
    bash "$here/bin/steward" desk snapshot "$@"
}
rc="$(run >/dev/null 2>"$T/err"; echo $?)"
is  "the snapshot runs" "$rc" "0"
[ "$rc" = "0" ] || printf '     stderr: %s\n' "$(cat "$T/err")"
D="$T/desk/current"
is  "one file per principal plus the operator file" "$(ls "$D" 2>/dev/null | LC_ALL=C sort | tr '\n' ' ')" "_operator.json a.json b.json c.json "
is  "schemaVersion is 1" "$(jq .schemaVersion "$D/b.json")" "1"
is  "b sees the team session and a's session in the same domain" "$(jq -r '.sessions|map(.slug)|sort|join(" ")' "$D/b.json")" "team-b work-a"
is  "b never sees a's MCP surface" "$(jq -r '.sessions[]|select(.slug=="work-a")|has("mcp")' "$D/b.json")" "false"
is  "member gets liveness including activity age" "$(jq -r '.sessions[]|select(.slug=="work-a")|.liveness|keys|join(" ")' "$D/b.json")" "ageSeconds measuredAt state"
is  "member sight is explicit" "$(jq -r '.sessions[]|select(.slug=="work-a")|.sight' "$D/b.json")" "member"
is  "owner sight is explicit" "$(jq -r '.sessions[]|select(.slug=="team-b")|.sight' "$D/b.json")" "owner"
is  "a sees the own account axis" "$(jq -r '.sessions[]|select(.slug=="work-a")|.mcp|map(.axis)|join(" ")' "$D/a.json")" "account entity project"
is  "c sees nothing" "$(jq '.sessions|length' "$D/c.json")" "0"
is  "the operator file carries every session" "$(jq '.sessions|length' "$D/_operator.json")" "2"

before_current="$(readlink "$T/desk/current")"
printf 'OWNER="a"\nHOST="h1"\nACCOUNT="missing-account"\nDOMAIN="team"\nRC_LABEL="Bad"\nREPO_PATH="/tmp/x"\n' \
  > "$ROOT/sessions.d/account-broken.conf"
bad_rc="$(run >/dev/null 2>"$T/account-broken.err"; echo $?)"
is "invalid account identity refuses the snapshot with rc 78" "$bad_rc" "78"
is "a refused snapshot leaves current on the prior generation" "$(readlink "$T/desk/current")" "$before_current"
has "the snapshot names the invalid account" "$(cat "$T/account-broken.err")" "missing-account"
rm -f "$ROOT/sessions.d/account-broken.conf"

# THE SENTINELS ARE THE POINT. Each one is a real registry value the snapshot
# reads past on its way to something else; a filter that ever grew a passthrough
# would carry one of them into a viewer's file, and this loop is what notices.
for s in SENTINEL_ARG SENTINEL_PATH SENTINEL_ENV "9999" MCP_ARGS mcpReason; do
  is "sentinel $s reaches no file" "$(grep -l "$s" "$D"/*.json 2>/dev/null | wc -l | tr -d ' ')" "0"
done

is  "repo is a name, not a path" "$(jq -r '.sessions[0].repo' "$D/_operator.json")" "repo"
is  "liveness carries an age" "$(jq -r '.sessions[0].liveness|has("ageSeconds")' "$D/_operator.json")" "true"
is  "the age of a just-measured session is a number" "$(jq -r '.sessions[0].liveness.ageSeconds|type' "$D/_operator.json")" "number"
is  "liveness state is the agent word" "$(jq -r '.sessions[0].liveness.state' "$D/_operator.json")" "running"
# THE AGE IS SECONDS SINCE THE SEAM'S TIMESTAMP, not a constant the producer
# invented: the shim stamps the moment it runs, so anything outside a couple of
# minutes means the derivation read the wrong field or the wrong clock.
is  "and it is a small number of seconds" \
    "$(jq -r '.sessions[0].liveness.ageSeconds | (. >= 0 and . <= 120)' "$D/_operator.json")" "true"
is  "the measuredAt is the run's own stamp" \
    "$(jq -r '(.sessions[0].liveness.measuredAt == .generatedAt)' "$D/_operator.json")" "true"

echo "== the seam may print fractional seconds =="
# A REAL LIVENESS COMMAND HAS BEEN SEEN TO STAMP MILLISECONDS, e.g.
# `2026-09-07T13:10:22.000Z` rather than the plain-seconds form the first
# shim uses. Both must derive an age - a parser that only accepted one form
# would leave every session null the day the seam started printing the other.
cat > "$T/shim-ms" <<EOF
#!/bin/bash
printf '{"sessions":{"%s":{"daemon":"loaded","tmux":"up","agent":"running","runtime":"claude-code","model":null,"lastActivity":"%s"}}}\n' \\
  "$SID_A" "\$(date -u +%Y-%m-%dT%H:%M:%S).000Z"
EOF
chmod +x "$T/shim-ms"
rc="$(STEWARD_DESK_DIR="$T/desk-ms" STEWARD_LIVENESS_CMD="$T/shim-ms" \
      bash "$here/bin/steward" desk snapshot >/dev/null 2>"$T/err-ms"; echo $?)"
is  "the snapshot runs with a fractional lastActivity" "$rc" "0"
is  "the age of a fractional-seconds timestamp is a number" \
    "$(jq -r '.sessions[]|select(.slug=="work-a")|.liveness.ageSeconds|type' "$T/desk-ms/current/_operator.json")" "number"
is  "and it is a small number of seconds" \
    "$(jq -r '.sessions[]|select(.slug=="work-a")|.liveness.ageSeconds | (. >= 0 and . < 120)' "$T/desk-ms/current/_operator.json")" "true"

# ABSENCE FROM THE SEAM'S ANSWER IS A WORD, NOT A GUESS. The shim never
# mentions the second session; it must read as `unknown` with no age at all,
# and never inherit the measured session's row.
is  "a session the seam never mentioned is unknown" \
    "$(jq -r '.sessions[]|select(.slug=="team-b")|.liveness.state' "$D/_operator.json")" "unknown"
is  "and carries no age" \
    "$(jq -r '.sessions[]|select(.slug=="team-b")|.liveness.ageSeconds|type' "$D/_operator.json")" "null"
is  "the write is atomic: no tmp files remain" "$(ls "$D" | grep -c tmp)" "0"
is  "unknown keys are dropped by the filter" "$(jq -r '.sessions[0]|keys|join(",")' "$D/a.json")" "domain,host,id,label,liveness,mcp,mine,owner,project,repo,runtime,sight,slug"
is  "an asset carries the four allowed keys only" "$(jq -r '.sessions[]|select(.slug=="work-a")|.mcp[0]|keys|join(",")' "$D/a.json")" "axis,id,name,source"
is  "the viewer is named in the file" "$(jq -r .viewer "$D/b.json")" "b"
is  "read-all is a boolean" "$(jq -r '.readAll|tostring' "$D/b.json")" "false"
is  "and true for the read-all principal" "$(jq -r '.readAll|tostring' "$D/a.json")" "true"
is  "mine marks the viewer's own session" "$(jq -r '.sessions[]|select(.slug=="team-b")|.mine|tostring' "$D/b.json")" "true"
is  "and is false for a colleague's" "$(jq -r '.sessions[]|select(.slug=="work-a")|.mine|tostring' "$D/b.json")" "false"
is  "b sees the team it belongs to, marked as membership" "$(jq -r '.entities|map(.id+":"+(.member|tostring))|join(" ")' "$D/b.json")" "team:true"
is  "c sees no entity" "$(jq '.entities|length' "$D/c.json")" "0"

echo "== the generation is private to the account that produced it =="
# THE FILES ARE THE WHOLE ACCESS CONTROL. Each one was filtered when it was
# written precisely so that no code path decides who may read it - which means
# the mode bits are the last gate, and a home that happens to be group- or
# world-readable would hand every principal's file to anyone with a login on
# the machine. The producer therefore sets its own umask rather than inheriting
# whatever the timer, the shell or the deploy happened to have.
# ASSERTED PORTABLY: `stat` has no common spelling across BSD and GNU, and the
# first ten characters of `ls -ld` do.
gen_dir="$T/desk/$(readlink "$T/desk/current")"
is  "the generation directory is 0700" "$(ls -ld "$gen_dir" | cut -c1-10)" "drwx------"
is  "and every file in it is 0600" \
    "$(ls -l "$gen_dir" | grep -c '^-rw-------' | tr -d ' ')" "4"

echo "== generations: every run is a new directory, current is a symlink =="
is  "current is a symlink" "$([ -L "$T/desk/current" ] && echo yes || echo no)" "yes"
is  "one generation after one run" "$(ls -d "$T/desk"/gen-* | wc -l | tr -d ' ')" "1"
run >/dev/null 2>&1
run >/dev/null 2>&1
is  "exactly two generations after three runs" "$(ls -d "$T/desk"/gen-* | wc -l | tr -d ' ')" "2"
is  "current still points into a live generation" "$(jq -r .schemaVersion "$T/desk/current/a.json")" "1"
is  "and no tmp file survived any run" "$(find "$T/desk" -name '*.tmp' | wc -l | tr -d ' ')" "0"

echo "== desk-paths: the two default locations, derived from the estate =="
out="$(HOME="$T/home" bash "$here/desk/bin/desk-paths" 2>"$T/err")"; rc=$?
is  "the bridge answers" "$rc" "0"
is  "the directory hangs under the estate's state dir" "$(printf '%s\n' "$out" | sed -n 's/^dir=//p')" "$T/home/.local/state/fixture-supervisor/desk"
is  "and names the socket beside it" "$(printf '%s\n' "$out" | sed -n 's/^sock=//p')" "$T/home/.local/state/fixture-supervisor/desk.sock"

echo "== an unresolvable surface is an empty list, never a reason a viewer reads =="
# `mcp surface` refuses (rc 65) when a level of the org will not load. The raw
# document records that as mcp:null plus mcpReason - and the allowlist names
# neither, so the viewer gets an empty list and the snapshot still renders.
printf 'NAME="Work"\nPARENT="missing"\nMCP_ASSETS="tool"\n' > "$ROOT/projects.d/work.conf"
rc="$(STEWARD_DESK_DIR="$T/desk2" STEWARD_LIVENESS_CMD="$T/shim" \
      bash "$here/bin/steward" desk snapshot >/dev/null 2>"$T/err"; echo $?)"
is  "the snapshot still runs" "$rc" "0"
is  "the session is still there for the operator" "$(jq -r '.sessions[]|select(.slug=="work-a")|.slug' "$T/desk2/current/_operator.json")" "work-a"
is  "with an empty asset list" "$(jq -r '.sessions[]|select(.slug=="work-a")|.mcp|length' "$T/desk2/current/_operator.json")" "0"
is  "and no reason field anywhere" "$(grep -l mcpReason "$T/desk2/current"/*.json 2>/dev/null | wc -l | tr -d ' ')" "0"
printf 'NAME="Work"\nPARENT="team"\nMCP_ASSETS="tool"\n' > "$ROOT/projects.d/work.conf"

echo "== an estate with no liveness command still renders a desk =="
# THE COMMON, UNCONFIGURED STATE. The fixture estate names no LIVENESS_CMD and
# nothing is in the environment, so the seam measures nothing at all - and the
# desk's other half (who owns what, and who may see it) is fully readable
# without it. A snapshot that refused here would be dark exactly when it is
# wanted. `env -u` because an ambient value would silently make this pass.
rc="$(env -u STEWARD_LIVENESS_CMD STEWARD_DESK_DIR="$T/desk3" \
      bash "$here/bin/steward" desk snapshot >/dev/null 2>"$T/err"; echo $?)"
is  "the snapshot runs without any seam" "$rc" "0"
[ "$rc" = "0" ] || printf '     stderr: %s\n' "$(cat "$T/err")"
is  "every state is unknown" \
    "$(jq -r '[.sessions[].liveness.state]|unique|join(" ")' "$T/desk3/current/_operator.json")" "unknown"
is  "and every age is null" \
    "$(jq -r '[.sessions[].liveness.ageSeconds]|unique|map(tostring)|join(" ")' "$T/desk3/current/_operator.json")" "null"

echo "== a viewer write that fails never publishes the generation =="
# THE FAULT IS A REAL, BROKEN FILTER INPUT for exactly one viewer - jq itself
# fails for principal `c`'s call and only that call. A fake `jq` ahead of the
# real one on PATH refuses the one invocation whose `--arg viewer` is `c`
# (that triple appears nowhere else in the script) and delegates every other
# call to the real binary untouched, so `a` and `_operator` still write. The
# shell's own `>` redirection still creates `c.json.tmp` before the fake jq
# even runs, so this reproduces the leftover-tmp half of the bug too.
D4="$T/desk4"
rc="$(STEWARD_DESK_DIR="$D4" STEWARD_LIVENESS_CMD="$T/shim" \
      bash "$here/bin/steward" desk snapshot >/dev/null 2>"$T/err4"; echo $?)"
is  "finding1 setup: the baseline run succeeds" "$rc" "0"
before_current="$(readlink "$D4/current")"

mkdir -p "$T/fakebin"
cat > "$T/fakebin/jq" <<'EOF'
#!/bin/bash
args=("$@")
n=${#args[@]}
i=0
while [ "$i" -lt "$n" ]; do
  if [ "${args[$i]}" = "--arg" ] && [ "${args[$((i+1))]}" = "viewer" ] && [ "${args[$((i+2))]}" = "c" ]; then
    echo "fake jq: forced failure for viewer c" >&2
    exit 1
  fi
  i=$((i+1))
done
exec /usr/bin/jq "$@"
EOF
chmod +x "$T/fakebin/jq"

rc="$(PATH="$T/fakebin:$PATH" STEWARD_DESK_DIR="$D4" STEWARD_LIVENESS_CMD="$T/shim" \
      bash "$here/bin/steward" desk snapshot >/dev/null 2>"$T/err4b"; echo $?)"
is  "a failed viewer write makes the whole run fail" "$([ "$rc" -ne 0 ] && echo yes || echo no)" "yes"
is  "current still points at the previous generation" "$(readlink "$D4/current")" "$before_current"
is  "no tmp file survives anywhere under the desk dir" \
    "$(find "$D4" -name '*.tmp' 2>/dev/null | wc -l | tr -d ' ')" "0"

echo "== prune never deletes the generation just published =="
# A BACKWARDS CLOCK STEP MUST NOT ORPHAN `current`. Two siblings pre-dated far
# into the future (by name, not by mtime) sort AFTER the generation this run
# is about to publish; a pruner that trusts sort order alone would count the
# fresh generation among the "oldest" and delete the very directory `current`
# now points to.
D5="$T/desk5"
mkdir -p "$D5/gen-9999999999" "$D5/gen-9999999998"
rc="$(STEWARD_DESK_DIR="$D5" STEWARD_LIVENESS_CMD="$T/shim" \
      bash "$here/bin/steward" desk snapshot >/dev/null 2>"$T/err5"; echo $?)"
is  "the run still succeeds with future-named siblings present" "$rc" "0"
new_gen="$(readlink "$D5/current")"
is  "the freshly published generation still exists after prune" \
    "$([ -n "$new_gen" ] && [ -d "$D5/$new_gen" ] && echo yes || echo no)" "yes"
is  "current is not left dangling" "$([ -e "$D5/current" ] && echo yes || echo no)" "yes"

echo "== filter.jq: an axis this file does not know is dropped for every viewer =="
# TESTED DIRECTLY AGAINST filter.jq, not through the registry - there is no
# way to make `mcp surface` hand back an axis this file has never heard of;
# the axis names are the registry's own vocabulary. A hand-written raw
# document is the deterministic way to prove the rule the comment states:
# unknown is dropped, never inherited by "own" or "readAll".
cat > "$T/raw3.json" <<'EOF'
{"host":"h","generatedAt":"g","registryRevision":"r",
 "principals":[{"id":"a","name":"A","readAll":true}],
 "entities":[], "projects":[],
 "sessions":[{"id":"s1","slug":"s1","label":"S1","owner":"a","domain":null,"project":null,
              "runtime":"claude-code","host":"h","repo":"repo",
              "liveness":{"state":"unknown","measuredAt":"g","ageSeconds":null},
              "mcp":[{"id":"x","name":"X","axis":"other","source":"whatever"}]}]}
EOF
. "$here/lib/visibility.sh"
owner_fields="$(visibility_field_list owner | jq -Rn '[inputs]')"
member_fields="$(visibility_field_list member | jq -Rn '[inputs]')"
out3="$(jq --arg viewer a --argjson readAll true --argjson memberOf '[]' \
           --argjson ownerFields "$owner_fields" --argjson memberFields "$member_fields" \
           -f "$here/desk/filter.jq" "$T/raw3.json")"
is  "an unknown axis is dropped even for the owner/readAll viewer" \
    "$(printf '%s' "$out3" | jq '.sessions[0].mcp|length')" "0"

echo "== filter.jq: shared sight, not membership, selects session fields =="
# Raw input deliberately carries extra fields at every depth. No new field
# reaches a viewer merely because the producer starts measuring it.
cat > "$T/raw4.json" <<'EOF'
{"host":"h","generatedAt":"g","registryRevision":"r",
 "principals":[{"id":"a","name":"A","readAll":true},{"id":"b","name":"B","readAll":false}],
 "entities":[{"id":"team","name":"Team","managedBy":null,"members":["a","b"]}],
 "projects":[{"id":"work","name":"Work","parent":"team"},{"id":"other","name":"Other","parent":"e1"}],
 "sessions":[{"id":"s1","slug":"work-a","label":"Work A","owner":"a","domain":"team","project":"work",
               "runtime":"claude-code","host":"h","repo":"repo", "sight":{"b":"member"},
               "mail":"SENTINEL_MAIL", "activityAge":42,
               "liveness":{"state":"unknown","measuredAt":"g","ageSeconds":42,"secret":"SENTINEL_LIVE"},
               "mcp":[{"id":"shared","name":"shared","axis":"entity","source":"team","command":"SENTINEL_CMD"},
                     {"id":"tool","name":"tool","axis":"project","source":"work"},
                     {"id":"other-tool","name":"other-tool","axis":"project","source":"other"}]}]}
EOF
out4b="$(jq --arg viewer b --argjson readAll false --argjson memberOf '["team"]' \
            --argjson ownerFields "$owner_fields" --argjson memberFields "$member_fields" \
            -f "$here/desk/filter.jq" "$T/raw4.json")"
out4a="$(jq --arg viewer a --argjson readAll true  --argjson memberOf '[]' \
            --argjson ownerFields "$owner_fields" --argjson memberFields "$member_fields" \
            -f "$here/desk/filter.jq" "$T/raw4.json")"
is  "b gets no MCP fields" \
    "$(printf '%s' "$out4b" | jq -r '.sessions[]|select(.slug=="work-a")|has("mcp")')" false
is  "a (readAll) still sees the other-project asset" \
    "$(printf '%s' "$out4a" | jq -r '.sessions[]|select(.slug=="work-a")|.mcp|map(.source)|sort|join(" ")')" \
     "other team work"
for sentinel in SENTINEL_MAIL SENTINEL_LIVE SENTINEL_CMD; do
  is "extra field $sentinel is absent for both levels" \
    "$(printf '%s\n%s' "$out4a" "$out4b" | grep -Fc "$sentinel")" 0
done
out_none="$(jq '.sessions[].sight.b = "none"' "$T/raw4.json" |
  jq --arg viewer b --argjson readAll false --argjson memberOf '["team"]' \
     --argjson ownerFields "$owner_fields" --argjson memberFields "$member_fields" -f "$here/desk/filter.jq")"
is "membership cannot override shell sight none" "$(printf '%s' "$out_none" | jq '.sessions|length')" 0

echo "== client membership never grants the rest of the managing team =="
printf 'NAME="Client"\nMEMBERS="c"\nMANAGED_BY="team"\n' > "$ROOT/entities.d/client.conf"
printf 'NAME="Client work"\nPARENT="client"\n' > "$ROOT/projects.d/client-work.conf"
for name in peer hidden granted; do
  printf 'OWNER="b"\nHOST="h1"\nDOMAIN="client-work"\nTARGET_PROJECT="client-work"\nREPO_PATH="/tmp/repo"\n' \
    > "$ROOT/sessions.d/$name.conf"
done
printf 'VISIBILITY="private"\n' >> "$ROOT/sessions.d/hidden.conf"
printf 'VISIBILITY="private"\nVISIBLE_TO="client"\n' >> "$ROOT/sessions.d/granted.conf"
rc="$(STEWARD_DESK_DIR="$T/desk-client" STEWARD_LIVENESS_CMD="$T/shim" \
      bash "$here/bin/steward" desk snapshot >/dev/null 2>"$T/client.err"; echo $?)"
is "client snapshot runs" "$rc" 0
C="$T/desk-client/current/c.json"
is "client member sees peers and explicit grants, not private or team rows" \
   "$(jq -r '.sessions|map(.slug)|sort|join(" ")' "$C")" "granted peer"
is "every client peer has member sight" "$(jq -r '[.sessions[].sight]|unique|join(" ")' "$C")" member
is "client peer fields exclude account MCP and mail but retain activity age" \
   "$(jq -r 'all(.sessions[]; (has("mcp")|not) and (has("mail")|not) and (.liveness|has("ageSeconds")))' "$C")" true
is "client member sees the project's descriptor" \
   "$(jq -r '.projects|map(.id)|join(" ")' "$C")" client-work

echo "== filter.jq: a project-axis asset with no source is dropped, never raises =="
# A NULL SOURCE ON A PROJECT-AXIS ASSET must be dropped like any other asset
# the viewer cannot see, not raise a jq error that fails the whole snapshot.
# THE REAL PRODUCER NEVER WRITES ONE (registry_session_mcp_surface always
# names the granting project's own slug), so this is fed to filter.jq
# directly, the same way raw3/raw4 above are.
# THE VIEWER MUST NOT OWN THE SESSION AND MUST NOT READ ALL, so keepAsset's
# short-circuiting `or` cannot skip the buggy indexing before it is ever
# reached - b is a plain member of team, not the session's owner.
cat > "$T/raw5.json" <<'EOF'
{"host":"h","generatedAt":"g","registryRevision":"r",
 "principals":[{"id":"a","name":"A","readAll":true},{"id":"b","name":"B","readAll":false}],
 "entities":[{"id":"team","name":"Team","managedBy":null,"members":["a","b"]}],
 "projects":[{"id":"work","name":"Work","parent":"team"}],
 "sessions":[{"id":"s1","slug":"work-a","label":"Work A","owner":"a","domain":"team","project":"work",
              "runtime":"claude-code","host":"h","repo":"repo",
              "liveness":{"state":"unknown","measuredAt":"g","ageSeconds":null},
               "sight":{"b":"member"},
               "mcp":[{"id":"orphan","name":"orphan","axis":"project","source":null}]}]}
EOF
rc5="$(jq --arg viewer b --argjson readAll false --argjson memberOf '["team"]' \
           --argjson ownerFields "$owner_fields" --argjson memberFields "$member_fields" \
          -f "$here/desk/filter.jq" "$T/raw5.json" >"$T/out5.json" 2>"$T/err5b"; echo $?)"
is  "the snapshot succeeds with a null-source project asset" "$rc5" "0"
[ "$rc5" = "0" ] || printf '     stderr: %s\n' "$(cat "$T/err5b")"
is  "and the null-source asset is absent" \
    "$(jq -r '.sessions[0]|has("mcp")' "$T/out5.json" 2>/dev/null)" "false"

echo "== one visibility rule: what hangs under a visible entity is visible =="
# THE DEFECT THIS SECTION WAS WRITTEN AGAINST, measured on a real estate. A
# viewer who belongs to `team` reached `client` - the entity `team` manages -
# and then reached NOTHING under it: the project their own team is delivering
# was absent from the file and a 404 on the desk. Two rules had grown where
# there is one question: an entity was visible through its manager, and
# everything below it was visible only through direct membership.
#
# A SECOND ESTATE, NOT AN EDIT TO THE FIRST. The rule under test is about the
# manager hop, and the fixture above deliberately has none; growing one into it
# would change what every assertion up to here is measuring.
ROOT2="$T/estate2"
mkdir -p "$ROOT2"/{estate,sessions.d,entities.d,projects.d,accounts.d,mcp.d,hosts.d,principals.d}
sed 's/"fixture"/"fixture2"/' "$ROOT/estate/steward.conf" > "$ROOT2/estate/steward.conf"
printf 'OWNER="a"\nOPERATOR="hub"\n' > "$ROOT2/hosts.d/h1.conf"
printf 'NAME="Team"\nMEMBERS="b"\nMCP_ASSETS="shared"\n'   > "$ROOT2/entities.d/team.conf"
printf 'NAME="Client"\nMANAGED_BY="team"\n'                > "$ROOT2/entities.d/client.conf"
printf 'NAME="E1"\n'                                       > "$ROOT2/entities.d/e1.conf"
printf 'NAME="Work"\nPARENT="client"\nMCP_ASSETS="tool"\n' > "$ROOT2/projects.d/work.conf"
printf 'NAME="Other"\nPARENT="e1"\n'                       > "$ROOT2/projects.d/other.conf"
printf 'PRINCIPAL="a"\nHOST="h1"\n' > "$ROOT2/accounts.d/a-h1.conf"
for m in shared tool; do
  printf 'MCP_COMMAND="/usr/bin/%s"\n' "$m" > "$ROOT2/mcp.d/$m.conf"
done
printf 'NAME="Ann"\nTAILSCALE_LOGIN="a@example.com"\n' > "$ROOT2/principals.d/a.conf"
printf 'NAME="Ben"\nTAILSCALE_LOGIN="b@example.com"\n' > "$ROOT2/principals.d/b.conf"
printf 'NAME="Cy"\nTAILSCALE_LOGIN="c@example.com"\n'  > "$ROOT2/principals.d/c.conf"
SID_W="s-0000000000000031"
cat > "$ROOT2/sessions.d/$SID_W.conf" <<EOF
OWNER="a"
HOST="h1"
DOMAIN="client"
REPO_PATH="$T/repo"
ID="$SID_W"
SLUG="work-a"
ACCOUNT="a-h1"
TARGET_PROJECT="work"
KIND="work"
EOF
D6="$T/desk6"
rc="$(env -u STEWARD_LIVENESS_CMD STEWARD_ESTATE_ROOT="$ROOT2" STEWARD_DESK_DIR="$D6" \
      bash "$here/bin/steward" desk snapshot >/dev/null 2>"$T/err6"; echo $?)"
is  "the second estate snapshots" "$rc" "0"
[ "$rc" = "0" ] || printf '     stderr: %s\n' "$(cat "$T/err6")"
is  "Ben reaches the client his team manages, and it is not his membership" \
    "$(jq -r '.entities|map(.id+":"+(.member|tostring))|sort|join(" ")' "$D6/current/b.json")" \
    "client:false team:true"
is  "and the project that hangs under that client" \
    "$(jq -r '.projects|map(.id)|sort|join(" ")' "$D6/current/b.json")" "work"
is  "and the session working on it" \
    "$(jq -r '.sessions|map(.slug)|join(" ")' "$D6/current/b.json")" "work-a"
is  "member session visibility does not expose the MCP surface" \
    "$(jq -r '.sessions[]|has("mcp")' "$D6/current/b.json")" "false"
# THE RULE WIDENS ONE HOP, NOT ALL OF THEM. `e1` is managed by nobody Ben
# belongs to, so neither it nor what hangs under it may follow the client in.
is  "a project under an unrelated entity stays absent for Ben" \
    "$(jq -r '[.projects[]|select(.id=="other")]|length' "$D6/current/b.json")" "0"
is  "and so does that entity" \
    "$(jq -r '[.entities[]|select(.id=="e1")]|length' "$D6/current/b.json")" "0"
# THE OWN-SESSION CLAUSE. Ann belongs to no entity at all; the project her own
# session works on is still hers to see, or her own session's page names a
# project that is a 404 for her.
is  "Ann is a member of nothing and still sees the project her own session works on" \
    "$(jq -r '.projects|map(.id)|join(" ")' "$D6/current/a.json")" "work"
is  "a viewer who is a member of nothing and owns nothing still sees nothing" \
    "$(jq -r '[(.entities|length),(.projects|length),(.sessions|length)]|join(" ")' "$D6/current/c.json")" \
    "0 0 0"

echo "== the owner is the PERSON, resolved through the account register =="
# THE DEFECT THIS SECTION WAS WRITTEN AGAINST. `owner` used to be the session
# row's raw unix OWNER, and the filter compares `owner` with the viewer, which
# is a PRINCIPAL id. The two namespaces are different registers: a unix account
# named after one person's principal id would hand that person somebody else's
# session as `mine: true`, its account-axis assets, and the project it works on.
# The row below is exactly that shape - it runs as the unix account `c`, and
# the account register says the human behind it is `b`.
#
# A THIRD ESTATE, NOT AN EDIT TO THE FIRST. Every assertion above counts the
# sessions and the slugs of the first fixture; growing a row into it would
# change what those are measuring.
ROOT3="$T/estate3"
mkdir -p "$ROOT3"/{estate,sessions.d,entities.d,projects.d,accounts.d,mcp.d,hosts.d,principals.d}
sed 's/"fixture"/"fixture3"/' "$ROOT/estate/steward.conf" > "$ROOT3/estate/steward.conf"
printf 'OWNER="b"\nOPERATOR="hub"\n' > "$ROOT3/hosts.d/h1.conf"
printf 'NAME="Team"\nMEMBERS="b"\nMCP_ASSETS="shared"\n'  > "$ROOT3/entities.d/team.conf"
printf 'NAME="Work"\nPARENT="team"\nMCP_ASSETS="tool"\n'  > "$ROOT3/projects.d/work.conf"
# THE ACCOUNT IS THE HOP UNDER TEST: the unix account is `c`, the human is `b`.
printf 'PRINCIPAL="b"\nHOST="h1"\nUSERNAME="c"\nMCP_ASSETS="mail"\n' > "$ROOT3/accounts.d/c-h1.conf"
for m in shared tool mail; do
  printf 'MCP_COMMAND="/usr/bin/%s"\n' "$m" > "$ROOT3/mcp.d/$m.conf"
done
printf 'NAME="Ben"\nTAILSCALE_LOGIN="b@example.com"\n' > "$ROOT3/principals.d/b.conf"
printf 'NAME="Cy"\nTAILSCALE_LOGIN="c@example.com"\n'  > "$ROOT3/principals.d/c.conf"
SID_P="s-0000000000000041"
cat > "$ROOT3/sessions.d/$SID_P.conf" <<EOF
OWNER="c"
HOST="h1"
DOMAIN="team"
REPO_PATH="$T/repo"
ID="$SID_P"
SLUG="work-c"
ACCOUNT="c-h1"
TARGET_PROJECT="work"
KIND="work"
EOF
# THE FALLBACK ROW: no ACCOUNT at all, so there is nothing to resolve and OWNER
# is the only answer the estate has. It must still be named, not blanked.
# ITS OWNER IS A UNIX ACCOUNT NO PRINCIPAL ROW CLAIMS, so the fallback cannot
# accidentally satisfy the namesake assertions below with a second session.
SID_N="s-0000000000000042"
cat > "$ROOT3/sessions.d/$SID_N.conf" <<EOF
OWNER="d"
HOST="h1"
DOMAIN="team"
REPO_PATH="$T/repo"
ID="$SID_N"
SLUG="plain-c"
TARGET_PROJECT="work"
KIND="work"
EOF
D7="$T/desk7"
rc="$(env -u STEWARD_LIVENESS_CMD STEWARD_ESTATE_ROOT="$ROOT3" STEWARD_DESK_DIR="$D7" \
      bash "$here/bin/steward" desk snapshot >/dev/null 2>"$T/err7"; echo $?)"
is  "the third estate snapshots" "$rc" "0"
[ "$rc" = "0" ] || printf '     stderr: %s\n' "$(cat "$T/err7")"
is  "the owner of a row whose unix account resolves to another person is the PERSON" \
    "$(jq -r '.sessions[]|select(.slug=="work-c")|.owner' "$D7/current/b.json")" "b"
is  "and the session is that person's own" \
    "$(jq -r '.sessions[]|select(.slug=="work-c")|.mine|tostring' "$D7/current/b.json")" "true"
is  "and the account-axis asset travels to that person" \
    "$(jq -r '.sessions[]|select(.slug=="work-c")|.mcp|map(select(.axis=="account")|.id)|join(" ")' "$D7/current/b.json")" \
    "mail"
# THE UNIX ACCOUNT'S NAMESAKE PRINCIPAL GETS NOTHING. `c` is a person who is a
# member of no entity and owns no session; the only thing that ever connected
# them to this row was a string equal to a unix account name.
is  "the namesake principal sees no session" "$(jq '.sessions|length' "$D7/current/c.json")" "0"
is  "and no project" "$(jq '.projects|length' "$D7/current/c.json")" "0"
is  "and no asset anywhere in the file" \
    "$(jq '[.sessions[]?.mcp[]?]|length' "$D7/current/c.json")" "0"
is  "a row with no ACCOUNT falls back to OWNER" \
    "$(jq -r '.sessions[]|select(.slug=="plain-c")|.owner' "$D7/current/_operator.json")" "d"

echo "== private with a grant: the desk asks the one visibility rule =="
# THE DEFECT THIS SECTION WAS WRITTEN AGAINST, measured on a real estate: a
# session with VISIBILITY=private and VISIBLE_TO=<a group entity> reached a
# viewer who belonged to the OWNING entity but not the GRANTED one, because
# desk/filter.jq re-implemented the session rule as
# ".owner == $viewer or isVisibleEntity(.domain; $managerOf) or $readAll" and
# that copy never learned `private` or `VISIBLE_TO` at all. lib/visibility.sh
# session_visible_to answers rc 1 for that same viewer; this section proves
# the desk now asks it instead of its own copy.
#
# A FOURTH ESTATE, NOT AN EDIT TO ONE ABOVE - the same reason every prior
# section built its own: an edit here would change what earlier assertions
# are counting.
ROOT4="$T/estate4"
mkdir -p "$ROOT4"/{estate,sessions.d,entities.d,projects.d,accounts.d,mcp.d,hosts.d,principals.d}
sed 's/"fixture"/"fixture4"/' "$ROOT/estate/steward.conf" > "$ROOT4/estate/steward.conf"
printf 'OWNER="alice"\nOPERATOR="hub"\n' > "$ROOT4/hosts.d/h1.conf"
printf 'NAME="Client"\nMEMBERS="alice bob carol"\n' > "$ROOT4/entities.d/client.conf"
printf 'NAME="Board"\nMEMBERS="alice"\n'             > "$ROOT4/entities.d/board.conf"
printf 'NAME="Alice"\nTAILSCALE_LOGIN="alice@example.com"\n' > "$ROOT4/principals.d/alice.conf"
printf 'NAME="Bob"\nTAILSCALE_LOGIN="bob@example.com"\n'     > "$ROOT4/principals.d/bob.conf"
printf 'NAME="Carol"\nTAILSCALE_LOGIN="carol@example.com"\n' > "$ROOT4/principals.d/carol.conf"
printf 'NAME="Dave"\nTAILSCALE_LOGIN="dave@example.com"\nDESK_READ_ALL="yes"\n' > "$ROOT4/principals.d/dave.conf"
SID_BOARD="s-0000000000000051"
cat > "$ROOT4/sessions.d/$SID_BOARD.conf" <<EOF
OWNER="carol"
HOST="h1"
DOMAIN="client"
REPO_PATH="$T/repo"
ID="$SID_BOARD"
SLUG="board-session"
RC_LABEL=""
VISIBILITY="private"
VISIBLE_TO="board"
KIND="work"
EOF
# THE REGRESSION CHECK: a NON-private session in the same entity, so the fix
# must not have also broken the ordinary team-visibility path.
SID_OPEN="s-0000000000000052"
cat > "$ROOT4/sessions.d/$SID_OPEN.conf" <<EOF
OWNER="carol"
HOST="h1"
DOMAIN="client"
REPO_PATH="$T/repo"
ID="$SID_OPEN"
SLUG="open-session"
RC_LABEL=""
KIND="work"
EOF
D8="$T/desk8"
rc="$(env -u STEWARD_LIVENESS_CMD STEWARD_ESTATE_ROOT="$ROOT4" STEWARD_DESK_DIR="$D8" \
      bash "$here/bin/steward" desk snapshot >/dev/null 2>"$T/err8"; echo $?)"
is  "the fourth estate snapshots" "$rc" "0"
[ "$rc" = "0" ] || printf '     stderr: %s\n' "$(cat "$T/err8")"
is  "alice reaches the board session through her grant" \
    "$(jq -r '[.sessions[]|.slug]|sort|join(" ")' "$D8/current/alice.json")" "board-session open-session"
is  "bob is a member of the owning entity but not the grant - the leak stays closed" \
    "$(jq -r '[.sessions[]|.slug]|sort|join(" ")' "$D8/current/bob.json")" "open-session"
is  "carol sees her own private session as owner" \
    "$(jq -r '[.sessions[]|.slug]|sort|join(" ")' "$D8/current/carol.json")" "board-session open-session"
is  "a read-all principal still sees the private session - that semantic is unchanged" \
    "$(jq -r '[.sessions[]|.slug]|sort|join(" ")' "$D8/current/dave.json")" "board-session open-session"
is  "the operator file still carries every session, private included" \
    "$(jq '.sessions|length' "$D8/current/_operator.json")" "2"

echo "== a conf cannot assign the sweep's own key and be answered as another row =="
# THE PRODUCER SOURCES EVERY SESSION CONF, and the sweep holds the row's key in
# a lowercase variable. Everything that follows the load is looked up BY that
# key: the display, the owning entity, the MCP surface the verb renders, and
# the per-principal sight decision. A row that assigned it would be filled in
# with another session's answers and published under its own owner - which for
# the MCP surface means one person's account-axis assets appearing in another
# person's file. The load therefore happens one subshell deeper than the scope
# that holds the key, and only values cross back.
ROOT9="$T/estate9"
mkdir -p "$ROOT9/estate" "$ROOT9/sessions.d" "$ROOT9/entities.d" "$ROOT9/projects.d" \
         "$ROOT9/accounts.d" "$ROOT9/mcp.d" "$ROOT9/hosts.d" "$ROOT9/principals.d"
cp "$ROOT/estate/steward.conf" "$ROOT9/estate/steward.conf"
cp "$ROOT/hosts.d/h1.conf" "$ROOT9/hosts.d/h1.conf"
cp "$ROOT/entities.d/team.conf" "$ROOT9/entities.d/team.conf"
cp "$ROOT/projects.d/work.conf" "$ROOT9/projects.d/work.conf"
cp "$ROOT"/mcp.d/*.conf "$ROOT9/mcp.d/"
cp "$ROOT/accounts.d/a-h1.conf" "$ROOT9/accounts.d/a-h1.conf"
cp "$ROOT/principals.d/b.conf" "$ROOT9/principals.d/b.conf"
cp "$ROOT/sessions.d/$SID_A.conf" "$ROOT9/sessions.d/$SID_A.conf"
# `a` keeps its read-all row so the operator view still has one; the row that
# matters is `c`, a principal with one entity of their own and nothing else.
cp "$ROOT/principals.d/a.conf" "$ROOT9/principals.d/a.conf"
printf 'NAME="Cy"\nTAILSCALE_LOGIN="c@example.com"\n' > "$ROOT9/principals.d/c.conf"
printf 'NAME="Solo"\nMEMBERS="c"\n'                   > "$ROOT9/entities.d/solo.conf"
printf 'PRINCIPAL="c"\nHOST="h1"\n'                   > "$ROOT9/accounts.d/c-h1.conf"
SID_SNEAK="s-0000000000000029"
cat > "$ROOT9/sessions.d/$SID_SNEAK.conf" <<EOF
OWNER="c"
HOST="h1"
DOMAIN="solo"
REPO_PATH="$T/SENTINEL_PATH/repo"
ID="$SID_SNEAK"
SLUG="sneaky"
ACCOUNT="c-h1"
TARGET_ENTITY="solo"
KIND="work"
n="$SID_A"
label="FORGED"
owner="a"
EOF
D9="$T/desk9"
rc="$(env -u STEWARD_LIVENESS_CMD STEWARD_ESTATE_ROOT="$ROOT9" STEWARD_DESK_DIR="$D9" \
      bash "$here/bin/steward" desk snapshot >/dev/null 2>"$T/err9"; echo $?)"
is  "the estate with the assigning row still snapshots" "$rc" "0"
[ "$rc" = "0" ] || printf '     stderr: %s\n' "$(cat "$T/err9")"
sneak='.sessions[]|select(.slug=="sneaky")'
is  "the row is still owned by the principal its ACCOUNT names" \
    "$(jq -r "$sneak|.owner" "$D9/current/c.json")" "c"
is  "its owning entity is its own, not the one the assigned key points at" \
    "$(jq -r "$sneak|.domain" "$D9/current/c.json")" "solo"
is  "its label is derived from its own row" \
    "$(jq -r "$sneak|.label" "$D9/current/c.json")" "Solo"
is  "and it inherits no MCP asset from the session it named" \
    "$(jq -r "$sneak|[.mcp[].id]|join(\" \")" "$D9/current/c.json")" ""
is  "the session it tried to be answered as is untouched" \
    "$(jq -r '.sessions[]|select(.slug=="work-a")|.domain' "$D9/current/_operator.json")" "team"
is  "and c reaches nothing of a's" \
    "$(jq -r '[.sessions[]|.slug]|sort|join(" ")' "$D9/current/c.json")" "sneaky"

echo "== the verb's own refusals =="
out="$(bash "$here/bin/steward" desk 2>"$T/err")"; rc=$?
is  "desk without a verb is a usage error" "$rc" "64"
has "and names the verbs it has" "$(cat "$T/err")" "snapshot"
out="$(bash "$here/bin/steward" desk bogus 2>"$T/err")"; rc=$?
is  "an unknown desk verb is a usage error" "$rc" "64"

printf '\n  %d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
