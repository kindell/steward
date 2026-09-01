#!/bin/bash
# test/job-verbs.test.sh — steward's job verbs: the submission gate wired to
# the engine, the detached spawn, and the identity-first JSON answer.
set -u
pass=0; fail=0
ok()  { pass=$((pass+1)); printf '  ok   %s\n' "$1"; }
bad() { fail=$((fail+1)); printf '  FAIL %s\n     %s\n' "$1" "${2:-}"; }
here="$(CDPATH= cd -- "$(dirname "$0")" && pwd)"
STEWARD_BIN="$here/../bin/steward"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t

# start: a complete submission gives an id, one row, one checkout, and ONE spawn call.
git init -q --bare "$T/origin.git"; git clone -q "$T/origin.git" "$T/src" 2>/dev/null
( cd "$T/src" && echo a > f && git add f && git commit -qm one && echo b >> f && git commit -qam two && git push -q origin HEAD )
printf '#!/bin/bash\nprintf "%%s\\n" "$*" >> "%s/spawnlog"\n' "$T" > "$T/spawn"; chmod +x "$T/spawn"
id="$(SUBMIT_GOAL=g SUBMIT_CHECK_CMD=true SUBMIT_CHECK_EXPECT=0 \
  SUBMIT_BRIEF_OBJECTIVE=o SUBMIT_BRIEF_DELIVERY=d SUBMIT_BRIEF_TOOLS=t SUBMIT_BRIEF_BOUNDS=b \
  SUBMIT_REPO="$T/src" JOBSTART_SPAWN="$T/spawn" STEWARD_JOB_STATE_HOME="$T/jobs" \
  bash "$STEWARD_BIN" job start)"
case "$id" in j-????????????????) ok "start: returns an id" ;; *) bad "start output" "$id" ;; esac
grep -q "$id" "$T/spawnlog" && ok "start: runner spawned detached" || bad "no spawn"
# BASE_SHA is the SOURCE'S HEAD, not the root commit — this fells Task 7's simplification.
. "$here/../lib/jobstate.sh"; STEWARD_JOB_STATE_HOME="$T/jobs" jobstate_read "$id"
[ "$JOB_BASE_SHA" = "$(git -C "$T/src" rev-parse HEAD)" ] && ok "start: BASE_SHA is source HEAD" || bad "BASE_SHA" "${JOB_BASE_SHA:-}"

# start: an incomplete submission propagates the schema refusal, mints NOTHING.
SUBMIT_GOAL= bash "$STEWARD_BIN" job start 2>/dev/null && bad "incomplete start accepted" || ok "incomplete start refused"
[ "$(ls "$T/jobs" | wc -l | tr -d ' ')" = "1" ] && ok "refusal minted no row" || bad "row minted on refusal"

# jobs --json: identity first, honest unknowns, full coverage.
mkdir -p "$T/jobs/j-00000000000000aa"; printf 'CORRUPT\n' > "$T/jobs/j-00000000000000aa/row"
out="$(STEWARD_JOB_STATE_HOME="$T/jobs" bash "$STEWARD_BIN" jobs --json)"
echo "$out" | jq -e '.schema == 1 and .measuredAt' >/dev/null && ok "json: schema + measuredAt" || bad "json head" "$out"
echo "$out" | jq -e --arg i "$id" '.jobs[] | select(.id==$i) | .process' >/dev/null && ok "json: real row listed" || bad "row missing"
echo "$out" | jq -e '.jobs[] | select(.id=="j-00000000000000aa") | .reason == "unparsable row"' >/dev/null \
  && ok "json: corrupt row present WITH reason" || bad "corrupt row vanished"
echo "$out" | jq -e '.coverage.listed == 2 and .coverage.unmeasurable == 1' >/dev/null && ok "json: coverage adds up" || bad "coverage" "$(echo "$out" | jq .coverage)"

# cancel: durable and immediate.
STEWARD_JOB_STATE_HOME="$T/jobs" JOBOUTBOX_SEND=/bin/true bash "$STEWARD_BIN" job cancel "$id" && ok "cancel: rc 0" || bad "cancel failed"
STEWARD_JOB_STATE_HOME="$T/jobs" jobstate_read "$id"
[ "$JOB_OUTCOME" = "cancelled" ] && ok "cancel: outcome cancelled" || bad "OUTCOME" "$JOB_OUTCOME"

# I4: A DRIVER EXISTS. `start` with a spawn that actually RUNS job-run.sh
# (synchronously, standing in for the detached tmux session) must end with
# the job fully reconciled — no human ever types `steward job reconcile`.
git init -q --bare "$T/e2e-origin.git"; git clone -q "$T/e2e-origin.git" "$T/e2e-src" 2>/dev/null
( cd "$T/e2e-src" && echo one > f && git add f && git commit -qm one && git push -q origin HEAD )
cat > "$T/e2e-runtime" <<'EOFRT'
#!/bin/bash
echo delivered >> f
git add f
git commit -qm "job work" >/dev/null
printf '{"session_id":"thread-e2e","result":"done"}\n'
exit 0
EOFRT
chmod +x "$T/e2e-runtime"
cat > "$T/e2e-spawn" <<EOFSPAWN
#!/bin/bash
JOBRUN_RUNTIME_CMD="$T/e2e-runtime" bash "$here/../job-run.sh" "\$1"
EOFSPAWN
chmod +x "$T/e2e-spawn"
e2e_id="$(SUBMIT_GOAL=g SUBMIT_CHECK_CMD=true SUBMIT_CHECK_EXPECT=0 \
  SUBMIT_BRIEF_OBJECTIVE=o SUBMIT_BRIEF_DELIVERY=d SUBMIT_BRIEF_TOOLS=t SUBMIT_BRIEF_BOUNDS=b \
  SUBMIT_REPO="$T/e2e-src" JOBSTART_SPAWN="$T/e2e-spawn" STEWARD_JOB_STATE_HOME="$T/jobs" \
  JOBOUTBOX_SEND=/bin/true \
  bash "$STEWARD_BIN" job start)"
case "$e2e_id" in j-????????????????) ok "e2e: start returns an id" ;; *) bad "e2e start output" "$e2e_id" ;; esac
STEWARD_JOB_STATE_HOME="$T/jobs" jobstate_read "$e2e_id"
[ "$JOB_OUTCOME" = "succeeded" ] && ok "e2e: I4 driver reconciles automatically, OUTCOME=succeeded" || bad "e2e OUTCOME" "${JOB_OUTCOME:-}"
[ -n "${JOB_DELIVERY_SHA:-}" ] && ok "e2e: DELIVERY_SHA recorded" || bad "e2e no DELIVERY_SHA"
[ "$(git -C "$T/e2e-origin.git" rev-parse "refs/heads/steward/jobs/$e2e_id/delivery" 2>/dev/null)" = "${JOB_DELIVERY_SHA:-}" ] \
  && ok "e2e: delivery actually landed on origin" || bad "e2e: origin ref does not match DELIVERY_SHA"


# ── THE OPERATOR'S TABLE ───────────────────────────────────────────────────
# `steward jobs` with NO flag renders the same identity-first data the --json
# form builds, for a human to read. The three states that must survive the
# rendering are a job still running, a job that reached a terminal outcome,
# and a row that cannot be parsed at all — the last one is the whole test:
# a table that quietly drops what it cannot measure is a table that lies.
tbl="$T/tjobs"; mkdir -p "$tbl"
long_goal="render the jobs a human can read at a glance without ever reaching for jq"
STEWARD_JOB_STATE_HOME="$tbl" jobstate_create j-00000000000000b1 \
  GOAL="$long_goal" OWNER=t DESIRED=run PROCESS=running OUTCOME=pending ATTEMPT_ID=1
STEWARD_JOB_STATE_HOME="$tbl" jobstate_create j-00000000000000b2 \
  GOAL="ship the receipt" OWNER=t DESIRED=run PROCESS=done OUTCOME=succeeded ATTEMPT_ID=2
mkdir -p "$tbl/j-00000000000000b3"; printf 'CORRUPT\n' > "$tbl/j-00000000000000b3/row"
: > "$tbl/j-00000000000000b1/heartbeat"

tbl_out="$(STEWARD_JOB_STATE_HOME="$tbl" bash "$STEWARD_BIN" jobs)"; tbl_rc=$?
[ "$tbl_rc" -eq 0 ] && ok "table: rc 0" || bad "table rc" "$tbl_rc"
printf '%s\n' "$tbl_out" | head -1 | grep -qE '^ID +PROCESS +OUTCOME +ATT +HB-AGE +GOAL$' \
  && ok "table: header names the six columns" || bad "table header" "$(printf '%s\n' "$tbl_out" | head -1)"

b1="$(printf '%s\n' "$tbl_out" | grep '^j-00000000000000b1')"
case "$b1" in *running*pending*) ok "table: a running job shows process and outcome" ;;
  *) bad "running row" "$b1" ;; esac
[ "$(printf '%s\n' "$b1" | awk '{print $4}')" = "1" ] && ok "table: ATT is the attempt" || bad "ATT" "$b1"
case "$(printf '%s\n' "$b1" | awk '{print $5}')" in
  ''|*[!0-9]*) bad "HB-AGE of a job with a heartbeat" "$b1" ;;
  *) ok "table: HB-AGE is an age in seconds when a heartbeat exists" ;;
esac
case "$b1" in *...) ok "table: a long goal is truncated" ;; *) bad "goal not truncated" "$b1" ;; esac
case "$b1" in *"reaching for jq"*) bad "goal ran past its column" "$b1" ;;
  *) ok "table: the truncated goal stops well short of the full text" ;; esac

b2="$(printf '%s\n' "$tbl_out" | grep '^j-00000000000000b2')"
case "$b2" in *succeeded*) ok "table: a finished job shows its outcome" ;; *) bad "succeeded row" "$b2" ;; esac
[ "$(printf '%s\n' "$b2" | awk '{print $5}')" = "-" ] && ok "table: HB-AGE is - with no heartbeat" || bad "HB-AGE dash" "$b2"

b3="$(printf '%s\n' "$tbl_out" | grep '^j-00000000000000b3')"
case "$b3" in *"[unparsable row]"*) ok "table: an unmeasurable row is listed WITH its reason" ;;
  *) bad "unparsable row missing or unexplained" "${b3:-<absent>}" ;; esac

# `jobs --json` is untouched by any of the above.
STEWARD_JOB_STATE_HOME="$tbl" bash "$STEWARD_BIN" jobs --json | jq -e '.schema == 1' >/dev/null \
  && ok "table: --json still answers as before" || bad "--json changed"

# THE EMPTY HOME IS NOT AN ERROR, and it is not a blank screen either: the
# header proves the verb ran, the sentence proves there was nothing to show.
mkdir -p "$T/nojobs"
empty_out="$(STEWARD_JOB_STATE_HOME="$T/nojobs" bash "$STEWARD_BIN" jobs)"; empty_rc=$?
[ "$empty_rc" -eq 0 ] && ok "empty: rc 0" || bad "empty rc" "$empty_rc"
printf '%s\n' "$empty_out" | head -1 | grep -q '^ID ' && ok "empty: the header is still printed" || bad "empty header" "$empty_out"
printf '%s\n' "$empty_out" | grep -q '^no jobs$' && ok "empty: says so in a sentence" || bad "empty line" "$empty_out"

# ── `steward job show <id>` ────────────────────────────────────────────────
# One job, everything known about it: the row as the STRICT READER parsed it,
# the tail of its journal, the outbox with each entry's state, and whether the
# delivery it claims is still the remote tip.
STEWARD_JOB_STATE_HOME="$T/jobs" jobstate_read "$e2e_id"
e2e_sha="${JOB_DELIVERY_SHA:-}"
show_out="$(STEWARD_JOB_STATE_HOME="$T/jobs" bash "$STEWARD_BIN" job show "$e2e_id")"; show_rc=$?
[ "$show_rc" -eq 0 ] && ok "show: rc 0" || bad "show rc" "$show_rc"
for f in GOAL OWNER PROCESS OUTCOME WORKDIR VERSION; do
  printf '%s\n' "$show_out" | grep -q "^$f=" && ok "show: prints $f" || bad "show missing $f" "$show_out"
done
printf '%s\n' "$show_out" | grep -q '^journal:$' && ok "show: has a journal section" || bad "no journal section"
printf '%s\n' "$show_out" | grep -q 'v0 created' && ok "show: the journal carries its lines" || bad "no journal lines" "$show_out"
printf '%s\n' "$show_out" | grep -q '^outbox:$' && ok "show: has an outbox section" || bad "no outbox section"
printf '%s\n' "$show_out" | grep -qE "job-$e2e_id-terminal-v[0-9]+ +(sent|pending)" \
  && ok "show: each outbox entry carries its state" || bad "outbox entries" "$show_out"
printf '%s\n' "$show_out" | grep -q "^  branch: steward/jobs/$e2e_id/delivery$" \
  && ok "show: delivery names the branch" || bad "no branch line" "$show_out"
printf '%s\n' "$show_out" | grep -q "DELIVERY_SHA=$e2e_sha" && ok "show: delivery names the sha" || bad "no delivery sha"
printf '%s\n' "$show_out" | grep -q '^  remote: matches' \
  && ok "show: says the remote tip still matches" || bad "remote verdict" "$show_out"

# A MOVED REMOTE TIP IS SAID OUT LOUD, never rounded down to "delivered".
git -C "$T/e2e-src" fetch -q origin "steward/jobs/$e2e_id/delivery" 2>/dev/null
( cd "$T/e2e-src" && git checkout -q -B moved FETCH_HEAD && echo drift >> f && git commit -qam drift \
  && git push -q -f origin "moved:steward/jobs/$e2e_id/delivery" ) >/dev/null 2>&1
moved_out="$(STEWARD_JOB_STATE_HOME="$T/jobs" bash "$STEWARD_BIN" job show "$e2e_id")"
printf '%s\n' "$moved_out" | grep -q '^  remote: does NOT match' \
  && ok "show: a moved remote tip is named as such" || bad "moved verdict" "$moved_out"

# AN ABSENT WORKDIR IS A FACT, NOT AN ERROR. Nothing to ask git with, so the
# line says so and the verb still succeeds.
STEWARD_JOB_STATE_HOME="$tbl" jobstate_create j-00000000000000b4 \
  GOAL=gone OWNER=t DESIRED=run PROCESS=done OUTCOME=failed \
  WORKDIR="$T/vanished" DELIVERY_SHA=0123456789abcdef0123456789abcdef01234567
gone_out="$(STEWARD_JOB_STATE_HOME="$tbl" bash "$STEWARD_BIN" job show j-00000000000000b4)"; gone_rc=$?
[ "$gone_rc" -eq 0 ] && ok "show: an absent workdir is rc 0" || bad "gone rc" "$gone_rc"
printf '%s\n' "$gone_out" | grep -q '^  workdir: gone$' && ok "show: says the workdir is gone" || bad "gone line" "$gone_out"

# ── THE PERMISSION MODE IS PART OF THE SUBMISSION ──────────────────────────
# `start` writes SUBMIT_PERMISSION_MODE into the row so the runner can honour
# it without a wrapper of its own. The set is CLOSED: a value outside it is a
# submission the runtime would reject halfway through a detached run, so the
# gate names the whole set and mints nothing.
perm_id="$(SUBMIT_GOAL=g SUBMIT_CHECK_CMD=true SUBMIT_CHECK_EXPECT=0 \
  SUBMIT_BRIEF_OBJECTIVE=o SUBMIT_BRIEF_DELIVERY=d SUBMIT_BRIEF_TOOLS=t SUBMIT_BRIEF_BOUNDS=b \
  SUBMIT_REPO="$T/src" JOBSTART_SPAWN="$T/spawn" STEWARD_JOB_STATE_HOME="$T/jobs" \
  SUBMIT_PERMISSION_MODE=bypassPermissions \
  bash "$STEWARD_BIN" job start)"
case "$perm_id" in j-????????????????) ok "permission mode: an accepted value still returns an id" ;;
  *) bad "start with a permission mode" "$perm_id" ;; esac
STEWARD_JOB_STATE_HOME="$T/jobs" jobstate_read "$perm_id"
[ "${JOB_PERMISSION_MODE:-}" = "bypassPermissions" ] \
  && ok "permission mode: the row carries the submitted value" || bad "PERMISSION_MODE" "${JOB_PERMISSION_MODE:-unset}"

# A submission without the field leaves it OFF the row — never a default nobody chose.
STEWARD_JOB_STATE_HOME="$T/jobs" jobstate_read "$id"
[ -z "${JOB_PERMISSION_MODE:-}" ] \
  && ok "permission mode: unset stays unset on the row" || bad "row invented a mode" "${JOB_PERMISSION_MODE:-}"

before="$(ls "$T/jobs" | wc -l | tr -d ' ')"
perm_err="$T/perm-err"
SUBMIT_GOAL=g SUBMIT_CHECK_CMD=true SUBMIT_CHECK_EXPECT=0 \
  SUBMIT_BRIEF_OBJECTIVE=o SUBMIT_BRIEF_DELIVERY=d SUBMIT_BRIEF_TOOLS=t SUBMIT_BRIEF_BOUNDS=b \
  SUBMIT_REPO="$T/src" JOBSTART_SPAWN="$T/spawn" STEWARD_JOB_STATE_HOME="$T/jobs" \
  SUBMIT_PERMISSION_MODE=nonsense \
  bash "$STEWARD_BIN" job start >/dev/null 2>"$perm_err"; perm_rc=$?
[ "$perm_rc" -eq 65 ] && ok "permission mode: a value outside the set is rc 65" || bad "nonsense rc" "$perm_rc"
for word in default acceptEdits bypassPermissions plan; do
  grep -q -- "$word" "$perm_err" && ok "permission mode: the refusal names $word" \
    || bad "refusal omits $word" "$(cat "$perm_err")"
done
[ "$(ls "$T/jobs" | wc -l | tr -d ' ')" = "$before" ] \
  && ok "permission mode: the refusal minted nothing" || bad "row minted on a refused mode"

# A NAME NOBODY HAS: rc 66, and the message says WHICH id was not found.
show_err="$T/show-err"
STEWARD_JOB_STATE_HOME="$tbl" bash "$STEWARD_BIN" job show j-0000000000000fff 2>"$show_err"; miss_rc=$?
[ "$miss_rc" -eq 66 ] && ok "show: a missing id is rc 66" || bad "missing id rc" "$miss_rc"
grep -q 'j-0000000000000fff' "$show_err" && ok "show: the refusal names the id" || bad "refusal text" "$(cat "$show_err")"

printf 'pass=%d fail=%d\n' "$pass" "$fail"
[ "$fail" -eq 0 ] || exit 1
