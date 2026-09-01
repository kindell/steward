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

printf 'pass=%d fail=%d\n' "$pass" "$fail"
[ "$fail" -eq 0 ] || exit 1
