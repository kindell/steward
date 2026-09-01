#!/bin/bash
# test/job-run.test.sh — the attempt slot: lease, heartbeat, exact-thread resume.
#
# THE RETRY REUSES THE THREAD, NEVER THE GOAL. Attempt 1 records the runtime's
# thread id; attempt 2 must pass --resume with EXACTLY that id — a fresh
# thread would redo finished work and contradict the branch-as-checkpoint
# rule [A2]. The runtime is a stub that records its argv; the assertions read
# what the runtime SAW, not what the wrapper claims.
set -u
pass=0; fail=0
ok()  { pass=$((pass+1)); printf '  ok   %s\n' "$1"; }
bad() { fail=$((fail+1)); printf '  FAIL %s\n     %s\n' "$1" "${2:-}"; }
here="$(CDPATH= cd -- "$(dirname "$0")" && pwd)"
. "$here/../lib/jobstate.sh"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
export STEWARD_JOB_STATE_HOME="$T/jobs"
export JOBRUN_HEARTBEAT_SEC=1 JOBRUN_LEASE_TTL=60 JOBRUN_MAX_ATTEMPTS=2

# Stub runtime: records argv, emits a claude-shaped JSON answer, exits per fixture.
cat > "$T/rt" <<'EOF'
#!/bin/bash
printf '%s\n' "$*" >> "${RTLOG:?}"
rc="$(cat "${RTRC:?}")"
printf '{"session_id":"thread-abc","result":"done"}\n'
exit "$rc"
EOF
chmod +x "$T/rt"
export JOBRUN_RUNTIME_CMD="$T/rt" RTLOG="$T/rtlog" RTRC="$T/rtrc"

id="j-00000000000000ef"; mkdir -p "$T/work"
jobstate_create "$id" GOAL="do the thing" OWNER=alice DESIRED=run PROCESS=queued \
  WORKDIR="$T/work" BRIEF_OBJECTIVE=o BRIEF_DELIVERY=d BRIEF_TOOLS=t BRIEF_BOUNDS=b RUNTIME=claude-code

echo 0 > "$T/rtrc"
bash "$here/../job-run.sh" "$id" && ok "attempt 1: rc 0" || bad "attempt 1 failed"
jobstate_read "$id"
[ "$JOB_PROCESS" = "exited" ] && ok "attempt 1: PROCESS=exited" || bad "PROCESS" "$JOB_PROCESS"
[ "$JOB_EXIT_CODE" = "0" ] && ok "attempt 1: EXIT_CODE recorded" || bad "EXIT_CODE" "${JOB_EXIT_CODE:-}"
[ "$JOB_ATTEMPT_ID" = "1" ] && ok "attempt 1: ATTEMPT_ID=1" || bad "ATTEMPT_ID" "${JOB_ATTEMPT_ID:-}"
[ "$JOB_RUNTIME_THREAD" = "thread-abc" ] && ok "attempt 1: thread id recorded" || bad "RUNTIME_THREAD" "${JOB_RUNTIME_THREAD:-}"
grep -q -- "-p" "$T/rtlog" && ok "attempt 1: headless flag" || bad "no -p"
grep -q -- "--resume" "$T/rtlog" && bad "attempt 1 resumed a thread that does not exist" || ok "attempt 1: no --resume"
[ -f "$T/jobs/$id/heartbeat" ] && ok "heartbeat file touched" || bad "no heartbeat"

# Attempt 2 must resume EXACTLY thread-abc.
echo 1 > "$T/rtrc"
bash "$here/../job-run.sh" "$id" ; rc=$?
jobstate_read "$id"
[ "$JOB_ATTEMPT_ID" = "2" ] && ok "attempt 2: ATTEMPT_ID=2" || bad "ATTEMPT_ID" "$JOB_ATTEMPT_ID"
grep -q -- "--resume thread-abc" "$T/rtlog" && ok "attempt 2: resumes the exact thread" || bad "no exact resume" "$(tail -1 "$T/rtlog")"
[ "$JOB_EXIT_CODE" = "1" ] && ok "attempt 2: nonzero exit recorded" || bad "EXIT_CODE" "$JOB_EXIT_CODE"

# Attempt 3 is beyond MAX_ATTEMPTS=2: refused, SLOTS_EXHAUSTED set, runtime NOT called.
n="$(wc -l < "$T/rtlog")"
bash "$here/../job-run.sh" "$id" 2>/dev/null && bad "attempt beyond budget ran" || ok "attempt beyond budget refused"
[ "$(wc -l < "$T/rtlog")" = "$n" ] && ok "runtime not called past budget" || bad "runtime ran past budget"
jobstate_read "$id"
[ "${JOB_SLOTS_EXHAUSTED:-}" = "1" ] && ok "SLOTS_EXHAUSTED recorded" || bad "no SLOTS_EXHAUSTED"

# A held lease refuses a second runner (fresh job, lease taken by someone else).
id2="j-00000000000000f0"
jobstate_create "$id2" GOAL=g OWNER=alice DESIRED=run PROCESS=queued WORKDIR="$T/work" \
  BRIEF_OBJECTIVE=o BRIEF_DELIVERY=d BRIEF_TOOLS=t BRIEF_BOUNDS=b RUNTIME=claude-code
jobstate_lease_acquire "$id2" other-runner 300
bash "$here/../job-run.sh" "$id2" 2>/dev/null && bad "second runner ran under a held lease" || ok "held lease refuses a second runner"

# opencode without measured resume support is refused with the reason.
id3="j-00000000000000f1"
jobstate_create "$id3" GOAL=g OWNER=alice DESIRED=run PROCESS=queued WORKDIR="$T/work" \
  BRIEF_OBJECTIVE=o BRIEF_DELIVERY=d BRIEF_TOOLS=t BRIEF_BOUNDS=b RUNTIME=opencode
out="$(bash "$here/../job-run.sh" "$id3" 2>&1)"; rc=$?
[ "$rc" -ne 0 ] && ok "opencode refused until resume is measured" || bad "opencode accepted unmeasured"
case "$out" in *resume*) ok "refusal states the reason" ;; *) bad "reason missing" "$out" ;; esac

# Heartbeat self-termination: wrapper killed, heartbeat must stop.
id4="j-00000000000000f2"
jobstate_create "$id4" GOAL=g OWNER=alice DESIRED=run PROCESS=queued WORKDIR="$T/work" \
  BRIEF_OBJECTIVE=o BRIEF_DELIVERY=d BRIEF_TOOLS=t BRIEF_BOUNDS=b RUNTIME=claude-code
echo 0 > "$T/rtrc"
cat > "$T/rt-sleep" <<'EOFSL'
#!/bin/bash
printf '%s\n' "$*" >> "${RTLOG:?}"
sleep 10
printf '{"session_id":"thread-xyz","result":"done"}\n'
exit 0
EOFSL
chmod +x "$T/rt-sleep"
export JOBRUN_RUNTIME_CMD="$T/rt-sleep"
bash "$here/../job-run.sh" "$id4" &
wpid=$!
sleep 2
kill -9 "$wpid" 2>/dev/null
wait "$wpid" 2>/dev/null || true
mtime1="$(stat -f%m "$T/jobs/$id4/heartbeat" 2>/dev/null || echo 0)"
sleep 2
mtime2="$(stat -f%m "$T/jobs/$id4/heartbeat" 2>/dev/null || echo 0)"
[ "$mtime1" = "$mtime2" ] && ok "heartbeat stopped after wrapper SIGKILL" || bad "heartbeat kept advancing after SIGKILL" "mtime1=$mtime1 mtime2=$mtime2"

# THREAD_PARSE_FAILED: rc 0 with invalid JSON → THREAD_PARSE_FAILED=1.
id5="j-00000000000000f3"
jobstate_create "$id5" GOAL=g OWNER=alice DESIRED=run PROCESS=queued WORKDIR="$T/work" \
  BRIEF_OBJECTIVE=o BRIEF_DELIVERY=d BRIEF_TOOLS=t BRIEF_BOUNDS=b RUNTIME=claude-code
cat > "$T/rt-badparse" <<'EOFBAD'
#!/bin/bash
printf '%s\n' "$*" >> "${RTLOG:?}"
printf 'not valid json\n'
exit 0
EOFBAD
chmod +x "$T/rt-badparse"
export JOBRUN_RUNTIME_CMD="$T/rt-badparse"
bash "$here/../job-run.sh" "$id5" >/dev/null 2>&1
jobstate_read "$id5"
[ "${JOB_THREAD_PARSE_FAILED:-}" = "1" ] && ok "THREAD_PARSE_FAILED=1 on bad JSON + rc 0" || bad "THREAD_PARSE_FAILED not set" "${JOB_THREAD_PARSE_FAILED:-empty}"
[ -z "${JOB_RUNTIME_THREAD:-}" ] && ok "RUNTIME_THREAD empty on parse failure" || bad "RUNTIME_THREAD not empty" "${JOB_RUNTIME_THREAD:-}"

# Second attempt refuses if THREAD_PARSE_FAILED=1 and RUNTIME_THREAD empty.
# Reset runtime to the good stub for future tests
export JOBRUN_RUNTIME_CMD="$T/rt"
out="$(bash "$here/../job-run.sh" "$id5" 2>&1)"; rc=$?
[ "$rc" -eq 65 ] && ok "attempt 2 refuses after parse failure" || bad "attempt 2 rc" "$rc"
case "$out" in *THREAD_PARSE_FAILED*) ok "refusal mentions parse failure" ;; *) bad "reason missing" "$out" ;; esac

# FINALIZE_LEASE_PRESERVED: _jobrun_finalize exits 70 on write-lock contention, preserves lease.
id6="j-00000000000000f4"
jobstate_create "$id6" GOAL=g OWNER=alice DESIRED=run PROCESS=running WORKDIR="$T/work" \
  BRIEF_OBJECTIVE=o BRIEF_DELIVERY=d BRIEF_TOOLS=t BRIEF_BOUNDS=b RUNTIME=claude-code \
  ATTEMPT_ID=1 EXIT_CODE=0
jobstate_lease_acquire "$id6" test-owner 300

# Pre-create write-lock to force jobstate_transition rc 75 on every call.
mkdir "$T/jobs/$id6/write-lock"

# Create a test script that sources the finalize function and calls it.
cat > "$T/test-finalize-fail.sh" <<'FINTEST'
#!/bin/bash
set -u
here="$1"; T="$2"; jobid="$3"
. "$here/../lib/jobstate.sh"
export STEWARD_JOB_STATE_HOME="$T/jobs"
jobstate_read "$jobid"
# Extract and source the _jobrun_finalize function
eval "$(sed -n '/_jobrun_finalize()/,/^}/p' "$here/../job-run.sh")"
_jobrun_finalize "$jobid" 0 "thread-test" 0
FINTEST
chmod +x "$T/test-finalize-fail.sh"

out="$("$T/test-finalize-fail.sh" "$here" "$T" "$id6" 2>&1)"; finalize_rc=$?

[ "$finalize_rc" -eq 70 ] && ok "finalize exits 70 on write-lock contention" || bad "finalize_rc" "$finalize_rc (expected 70)"
[ -f "$T/jobs/$id6/lease" ] && ok "lease file preserved after finalize failure" || bad "lease file deleted"
echo "$out" | grep -q "$id6" && ok "finalize stderr names the job" || bad "job name missing in stderr"
echo "$out" | grep -q "FINAL BOOKKEEPING FAILED" && ok "finalize explains the failure" || bad "failure reason missing"

# Retry after removing the lock: finalize should succeed and return rc 0.
# (Lease removal is the wrapper's job via its EXIT trap, not finalize's responsibility.)
rmdir "$T/jobs/$id6/write-lock"

cat > "$T/test-finalize-ok.sh" <<'FINTEST2'
#!/bin/bash
set -u
here="$1"; T="$2"; jobid="$3"
. "$here/../lib/jobstate.sh"
export STEWARD_JOB_STATE_HOME="$T/jobs"
jobstate_read "$jobid"
eval "$(sed -n '/_jobrun_finalize()/,/^}/p' "$here/../job-run.sh")"
_jobrun_finalize "$jobid" 0 "thread-test" 0
FINTEST2
chmod +x "$T/test-finalize-ok.sh"

"$T/test-finalize-ok.sh" "$here" "$T" "$id6" >/dev/null 2>&1; finalize_rc=$?
[ "$finalize_rc" -eq 0 ] && ok "finalize succeeds after lock removed" || bad "finalize_rc after unlock" "$finalize_rc"

printf 'pass=%d fail=%d\n' "$pass" "$fail"
[ "$fail" -eq 0 ] || exit 1
