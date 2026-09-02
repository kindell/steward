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
# The runtime's transcript store, measured: a thread lives at
# <store>/<munged-cwd>/<uuid>.jsonl. Every fixture below points the wrapper at
# a store of its own, so what these tests measure is the fixture and never
# whatever sessions this machine happens to hold.
export JOBRUN_THREAD_STORE="$T/store"
mkdir -p "$T/store/-a-munged-workdir"
mkthread() { : > "$T/store/-a-munged-workdir/$1.jsonl"; }

# Stub runtime: records argv, emits a claude-shaped JSON answer, exits per fixture.
cat > "$T/rt" <<'EOF'
#!/bin/bash
case " $* " in *" --help "*) exit 0 ;; esac
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
# The capability probe is a MEASUREMENT, and a measurement that leaves a line
# in the log the assertions read is a fixture that documents its own side
# effect instead of bounding it. The probe's `--help` belongs nowhere in here.
grep -qx -- '--help' "$T/rtlog" && bad "the probe left its own line in the argv log" "$(cat "$T/rtlog")" || ok "attempt 1: the argv log holds the run, not the probe"

# Attempt 2 must resume EXACTLY thread-abc — the thread attempt 1 created is
# in the store, so it is there to be resumed.
mkthread thread-abc
echo 1 > "$T/rtrc"
bash "$here/../job-run.sh" "$id" ; rc=$?
jobstate_read "$id"
[ "$JOB_ATTEMPT_ID" = "2" ] && ok "attempt 2: ATTEMPT_ID=2" || bad "ATTEMPT_ID" "$JOB_ATTEMPT_ID"
grep -q -- "--resume thread-abc" "$T/rtlog" && ok "attempt 2: resumes the exact thread" || bad "no exact resume" "$(tail -1 "$T/rtlog")"
[ "${JOB_RESUME_KIND:-}" = "exact-thread" ] && ok "attempt 2: the row names the start this attempt got" || bad "RESUME_KIND" "${JOB_RESUME_KIND:-unset}"
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
case " $* " in *" --help "*) exit 0 ;; esac
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

# C2: the heartbeat tick RENEWS THE LEASE (jobstate_lease_renew), not just a
# touched file. A lease whose TTL is shorter than the runtime call must
# survive to the end anyway — real wall-clock time, no JOBSTATE_NOW override.
id7="j-00000000000000f5"
jobstate_create "$id7" GOAL=g OWNER=alice DESIRED=run PROCESS=queued WORKDIR="$T/work" \
  BRIEF_OBJECTIVE=o BRIEF_DELIVERY=d BRIEF_TOOLS=t BRIEF_BOUNDS=b RUNTIME=claude-code
cat > "$T/rt-slow" <<'EOFSLOW'
#!/bin/bash
case " $* " in *" --help "*) exit 0 ;; esac
sleep 4
printf '{"session_id":"thread-slow","result":"done"}\n'
exit 0
EOFSLOW
chmod +x "$T/rt-slow"
JOBRUN_RUNTIME_CMD="$T/rt-slow" JOBRUN_HEARTBEAT_SEC=1 JOBRUN_LEASE_TTL=2 \
  bash "$here/../job-run.sh" "$id7" &
wpid7=$!
sleep 3
# At t=3s the ORIGINAL 2s TTL would already have expired without renewal.
still_held="$(jobstate_lease_holder "$id7" 2>/dev/null)"
[ -n "$still_held" ] && ok "C2: lease survives past its original TTL via heartbeat renewal" || bad "lease expired despite heartbeats"
wait "$wpid7" 2>/dev/null

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


# ── THE ROW CARRIES THE PERMISSION MODE, THE RUNNER OBEYS IT ───────────────
# A run's permission policy belongs to the submission, not to the wrapper. So
# the assertions read the runtime's OWN argv: a row that carries
# PERMISSION_MODE must reach the runtime as `--permission-mode <value>`, and a
# row without the field must send NOTHING. A hardcoded default here would
# quietly overrule every submission and run the whole fleet under a policy
# nobody chose.
export JOBRUN_RUNTIME_CMD="$T/rt"
echo 0 > "$T/rtrc"

id8="j-00000000000000f6"
jobstate_create "$id8" GOAL=g OWNER=alice DESIRED=run PROCESS=queued WORKDIR="$T/work" \
  BRIEF_OBJECTIVE=o BRIEF_DELIVERY=d BRIEF_TOOLS=t BRIEF_BOUNDS=b RUNTIME=claude-code \
  PERMISSION_MODE=bypassPermissions
: > "$T/rtlog"
bash "$here/../job-run.sh" "$id8" >/dev/null 2>&1
grep -q -- "--permission-mode bypassPermissions" "$T/rtlog" \
  && ok "row with PERMISSION_MODE: the runtime saw the flag and the value" \
  || bad "permission mode never reached the runtime" "$(cat "$T/rtlog")"

id9="j-00000000000000f7"
jobstate_create "$id9" GOAL=g OWNER=alice DESIRED=run PROCESS=queued WORKDIR="$T/work" \
  BRIEF_OBJECTIVE=o BRIEF_DELIVERY=d BRIEF_TOOLS=t BRIEF_BOUNDS=b RUNTIME=claude-code
: > "$T/rtlog"
bash "$here/../job-run.sh" "$id9" >/dev/null 2>&1
grep -q -- "--permission-mode" "$T/rtlog" \
  && bad "runner invented a permission mode for a row that carries none" "$(cat "$T/rtlog")" \
  || ok "row without PERMISSION_MODE: no --permission-mode in the argv at all"

# The same rule on the resume path: attempt 2 keeps the row's mode.
: > "$T/rtlog"
echo 1 > "$T/rtrc"
bash "$here/../job-run.sh" "$id8" >/dev/null 2>&1
grep -q -- "--permission-mode bypassPermissions" "$T/rtlog" \
  && ok "attempt 2: the resumed run keeps the row's permission mode" \
  || bad "resume dropped the permission mode" "$(cat "$T/rtlog")"

# ── THE THREAD IS MINTED BEFORE THE RUN, NOT PARSED AFTER IT ───────────────
# A thread id first written when the wrapper exits is only ever there for an
# attempt that ended cleanly — the one case that does not need it. A killed
# attempt left the row with no thread, and attempt 2 then started FRESH on the
# same branch, redoing finished work. So when the runtime accepts a
# caller-chosen id, the wrapper mints one and records it in the SAME
# transition that sets PROCESS=running. The stub reads the row while the run
# is still in flight and exits 3 if the thread is not there yet — that exit
# code lands in EXIT_CODE, so the row itself is the evidence.
cat > "$T/rt-session" <<'EOFSESS'
#!/bin/bash
case " $* " in
  *" --help "*) printf -- '  --session-id <uuid>   Use a specific session ID for the\n'; exit 0 ;;
esac
printf '%s\n' "$*" >> "${RTLOG:?}"
row="${STEWARD_JOB_STATE_HOME:?}/${RTJOB:?}/row"
grep -q '^RUNTIME_THREAD=.' "$row" || {
  echo "stub: no RUNTIME_THREAD on the row while the run is in flight" >&2; exit 3; }
# Like the real runtime: the id it was handed is the id it reports back.
sid=""; prev=""
for a in "$@"; do
  case "$prev" in --session-id|--resume) sid="$a"; break ;; esac
  prev="$a"
done
printf '{"session_id":"%s","result":"done"}\n' "$sid"
exit 0
EOFSESS
chmod +x "$T/rt-session"

id10="j-00000000000000f8"
jobstate_create "$id10" GOAL=g OWNER=alice DESIRED=run PROCESS=queued WORKDIR="$T/work" \
  BRIEF_OBJECTIVE=o BRIEF_DELIVERY=d BRIEF_TOOLS=t BRIEF_BOUNDS=b RUNTIME=claude-code
: > "$T/rtlog"
RTJOB="$id10" JOBRUN_RUNTIME_CMD="$T/rt-session" bash "$here/../job-run.sh" "$id10" >/dev/null 2>&1
jobstate_read "$id10"
uuid="${JOB_RUNTIME_THREAD:-}"
[ "${JOB_EXIT_CODE:-}" = "0" ] \
  && ok "minted thread: the row carried RUNTIME_THREAD while the run was still in flight" \
  || bad "the run saw a row with no thread id" "EXIT_CODE=${JOB_EXIT_CODE:-unset}"
case "$uuid" in
  ????????-????-????-????-????????????) ok "minted thread: RUNTIME_THREAD is a uuid the runtime will accept" ;;
  *) bad "RUNTIME_THREAD is not a uuid" "${uuid:-unset}" ;;
esac
grep -q -- "--session-id $uuid" "$T/rtlog" \
  && ok "attempt 1: the runtime saw --session-id with exactly the recorded id" \
  || bad "the minted id never reached the runtime" "$(cat "$T/rtlog")"
[ -z "${JOB_THREAD_MISMATCH:-}" ] && ok "minted thread: the runtime used the id it was given, so nothing is flagged" || bad "THREAD_MISMATCH on an agreeing run" "${JOB_THREAD_MISMATCH:-}"
[ "${JOB_RESUME_KIND:-}" = "first" ] && ok "minted thread: the row names the start this attempt got" || bad "RESUME_KIND" "${JOB_RESUME_KIND:-unset}"
grep -q -- "--resume" "$T/rtlog" && bad "attempt 1 resumed a thread that did not exist yet" || ok "attempt 1: no --resume"

# Attempt 2 resumes EXACTLY the id minted before attempt 1 ran — the run
# created that thread, so the store holds it.
mkthread "$uuid"
: > "$T/rtlog"
RTJOB="$id10" JOBRUN_RUNTIME_CMD="$T/rt-session" bash "$here/../job-run.sh" "$id10" >/dev/null 2>&1
jobstate_read "$id10"
[ "${JOB_ATTEMPT_ID:-}" = "2" ] && ok "minted thread: ATTEMPT_ID=2" || bad "ATTEMPT_ID" "${JOB_ATTEMPT_ID:-}"
grep -q -- "--resume $uuid" "$T/rtlog" \
  && ok "attempt 2: resumes the exact id minted before attempt 1" \
  || bad "no exact resume" "$(cat "$T/rtlog")"
[ "${JOB_RUNTIME_THREAD:-}" = "$uuid" ] && ok "attempt 2: the thread id is unchanged" || bad "thread id moved" "${JOB_RUNTIME_THREAD:-}"
[ "${JOB_RESUME_KIND:-}" = "exact-thread" ] && ok "attempt 2: the row names the start this attempt got" || bad "RESUME_KIND" "${JOB_RESUME_KIND:-unset}"

# A runtime that does NOT take a caller-chosen id is not faked: the wrapper
# keeps the parse-at-exit path, invents no flag, and the row says so.
id11="j-00000000000000f9"
jobstate_create "$id11" GOAL=g OWNER=alice DESIRED=run PROCESS=queued WORKDIR="$T/work" \
  BRIEF_OBJECTIVE=o BRIEF_DELIVERY=d BRIEF_TOOLS=t BRIEF_BOUNDS=b RUNTIME=claude-code
: > "$T/rtlog"; echo 0 > "$T/rtrc"
JOBRUN_RUNTIME_CMD="$T/rt" bash "$here/../job-run.sh" "$id11" >/dev/null 2>&1
jobstate_read "$id11"
grep -q -- "--session-id" "$T/rtlog" \
  && bad "the wrapper passed a flag this runtime does not take" "$(cat "$T/rtlog")" \
  || ok "no pre-minted id: the runtime saw no --session-id at all"
[ "${JOB_RUNTIME_THREAD:-}" = "thread-abc" ] && ok "no pre-minted id: the runtime's own id is still recorded at exit" || bad "RUNTIME_THREAD" "${JOB_RUNTIME_THREAD:-unset}"
[ "${JOB_RESUME_KIND:-}" = "thread-at-exit" ] && ok "no pre-minted id: the row says the thread only arrives at exit" || bad "RESUME_KIND" "${JOB_RESUME_KIND:-unset}"

# ── A THREAD ID IS A NAME; ONLY THE STORE SAYS WHETHER IT EXISTS ───────────
# The row names the thread before the run, so a kill in the first moments
# leaves a row pointing at a session the runtime never created. `--resume` on
# that id fails outright — measured against the real runtime: "No conversation
# found with session ID". So the wrapper asks the store, not the row: the
# thread is there → resume it exactly; it is not → start it now under the SAME
# name with --session-id, and say on the row which of the two happened. The
# condition is "the row has a thread", never the attempt counter.
seed_thread=22222222-3333-4444-a555-666666666666

# (a) the thread exists in the store → an exact resume.
id12="j-00000000000000fa"
jobstate_create "$id12" GOAL=g OWNER=alice DESIRED=run PROCESS=queued WORKDIR="$T/work" \
  BRIEF_OBJECTIVE=o BRIEF_DELIVERY=d BRIEF_TOOLS=t BRIEF_BOUNDS=b RUNTIME=claude-code \
  RUNTIME_THREAD="$seed_thread"
mkthread "$seed_thread"
: > "$T/rtlog"
RTJOB="$id12" JOBRUN_RUNTIME_CMD="$T/rt-session" bash "$here/../job-run.sh" "$id12" >/dev/null 2>&1
jobstate_read "$id12"
grep -q -- "--resume $seed_thread" "$T/rtlog" \
  && ok "thread in the store: the runtime saw --resume with exactly that id" \
  || bad "no exact resume for a thread that exists" "$(cat "$T/rtlog")"
[ "${JOB_RESUME_KIND:-}" = "exact-thread" ] && ok "thread in the store: the row says exact-thread" || bad "RESUME_KIND" "${JOB_RESUME_KIND:-unset}"

# (b) the same row, and the store does not hold that thread: the name stands,
# but the session has to be CREATED now — a resume here would only fail.
id13="j-00000000000000fb"
jobstate_create "$id13" GOAL=g OWNER=alice DESIRED=run PROCESS=queued WORKDIR="$T/work" \
  BRIEF_OBJECTIVE=o BRIEF_DELIVERY=d BRIEF_TOOLS=t BRIEF_BOUNDS=b RUNTIME=claude-code \
  RUNTIME_THREAD=33333333-4444-4555-a666-777777777777
: > "$T/rtlog"
RTJOB="$id13" JOBRUN_RUNTIME_CMD="$T/rt-session" bash "$here/../job-run.sh" "$id13" >/dev/null 2>&1
jobstate_read "$id13"
grep -q -- "--session-id 33333333-4444-4555-a666-777777777777" "$T/rtlog" \
  && ok "thread not in the store: the run starts that same id instead of resuming it" \
  || bad "no --session-id for a thread that does not exist" "$(cat "$T/rtlog")"
grep -q -- "--resume" "$T/rtlog" \
  && bad "resumed a thread the store does not hold" "$(cat "$T/rtlog")" \
  || ok "thread not in the store: no --resume at all"
[ "${JOB_RESUME_KIND:-}" = "fresh-after-crash" ] && ok "thread not in the store: the row says fresh-after-crash" || bad "RESUME_KIND" "${JOB_RESUME_KIND:-unset}"
[ "${JOB_RUNTIME_THREAD:-}" = "33333333-4444-4555-a666-777777777777" ] && ok "thread not in the store: the row keeps the name it gave" || bad "RUNTIME_THREAD" "${JOB_RUNTIME_THREAD:-unset}"

# ── THE RUNTIME'S OWN ID BEATS THE ONE THE ROW GUESSED ────────────────────
# A runtime may accept --session-id and still run under an id of its own. The
# final JSON says which one it used, and that answer is free — it is already
# in hand at exit. If the row kept its guess, the next attempt would resume a
# session holding none of the work. So the row learns the runtime's id, says
# they disagreed, and names both on stderr.
cat > "$T/rt-liar" <<'EOFLIAR'
#!/bin/bash
case " $* " in
  *" --help "*) printf -- '  --session-id <uuid>   Use a specific session ID for the\n'; exit 0 ;;
esac
printf '%s\n' "$*" >> "${RTLOG:?}"
printf '{"session_id":"99999999-8888-4777-a666-555555555555","result":"done"}\n'
exit 0
EOFLIAR
chmod +x "$T/rt-liar"

id14="j-00000000000000fc"
jobstate_create "$id14" GOAL=g OWNER=alice DESIRED=run PROCESS=queued WORKDIR="$T/work" \
  BRIEF_OBJECTIVE=o BRIEF_DELIVERY=d BRIEF_TOOLS=t BRIEF_BOUNDS=b RUNTIME=claude-code
: > "$T/rtlog"
JOBRUN_RUNTIME_CMD="$T/rt-liar" bash "$here/../job-run.sh" "$id14" >/dev/null 2>"$T/liar-err"
minted_id="$(grep -o -- '--session-id [0-9a-f-]*' "$T/rtlog" | head -1 | awk '{print $2}')"
jobstate_read "$id14"
[ "${JOB_RUNTIME_THREAD:-}" = "99999999-8888-4777-a666-555555555555" ] \
  && ok "id mismatch: the row learns the id the runtime actually used" \
  || bad "RUNTIME_THREAD" "${JOB_RUNTIME_THREAD:-unset}"
[ "${JOB_THREAD_MISMATCH:-}" = "1" ] && ok "id mismatch: the row says the two ids disagreed" || bad "THREAD_MISMATCH" "${JOB_THREAD_MISMATCH:-unset}"
grep -q "99999999-8888-4777-a666-555555555555" "$T/liar-err" && ok "id mismatch: stderr names the id the runtime used" || bad "stderr missing the runtime's id" "$(cat "$T/liar-err")"
grep -q "$minted_id" "$T/liar-err" && ok "id mismatch: stderr names the id the row held" || bad "stderr missing the row's id" "$(cat "$T/liar-err")"

# ── THE PROBE MEASURES THE FLAG, NOT A SUBSTRING OF IT ────────────────────
# `--fork-session-id` and `--session-id-file` are different flags. A substring
# match reads either as "this runtime takes a caller-chosen session id", and
# the wrapper then passes a flag the runtime does not have — which fails the
# whole attempt. The flag has to be matched as a word.
cat > "$T/rt-otherflags" <<'EOFOTHER'
#!/bin/bash
case " $* " in
  *" --help "*)
    printf -- '  --fork-session-id <uuid>   Fork the session under a new id\n'
    printf -- '  --session-id-file <path>   Write the session id to this file\n'
    exit 0 ;;
esac
printf '%s\n' "$*" >> "${RTLOG:?}"
printf '{"session_id":"thread-other","result":"done"}\n'
exit 0
EOFOTHER
chmod +x "$T/rt-otherflags"

id15="j-00000000000000fd"
jobstate_create "$id15" GOAL=g OWNER=alice DESIRED=run PROCESS=queued WORKDIR="$T/work" \
  BRIEF_OBJECTIVE=o BRIEF_DELIVERY=d BRIEF_TOOLS=t BRIEF_BOUNDS=b RUNTIME=claude-code
: > "$T/rtlog"
JOBRUN_RUNTIME_CMD="$T/rt-otherflags" bash "$here/../job-run.sh" "$id15" >/dev/null 2>&1
jobstate_read "$id15"
grep -q -- "--session-id" "$T/rtlog" \
  && bad "a longer flag was read as --session-id" "$(cat "$T/rtlog")" \
  || ok "look-alike flags: the runtime saw no --session-id"
[ "${JOB_RESUME_KIND:-}" = "thread-at-exit" ] && ok "look-alike flags: the row says the thread only arrives at exit" || bad "RESUME_KIND" "${JOB_RESUME_KIND:-unset}"

# ── A ROW WITHOUT A WORKDIR IS NOT MEASURED IN WHATEVER DIRECTORY THIS IS ──
# The probe runs the runtime, and it runs it inside the job's own clone — the
# one directory this wrapper ever lets the runtime touch. Falling back to `.`
# would run it wherever the caller happened to be standing, which is how a
# probe writes somewhere it was never invited. So a row with no WORKDIR is
# refused, loudly, before anything is executed.
id16="j-00000000000000fe"
jobstate_create "$id16" GOAL=g OWNER=alice DESIRED=run PROCESS=queued \
  BRIEF_OBJECTIVE=o BRIEF_DELIVERY=d BRIEF_TOOLS=t BRIEF_BOUNDS=b RUNTIME=claude-code
: > "$T/rtlog"
out="$(JOBRUN_RUNTIME_CMD="$T/rt-session" bash "$here/../job-run.sh" "$id16" 2>&1)"; rc=$?
[ "$rc" -eq 65 ] && ok "no workdir: refused with rc 65" || bad "no-workdir rc" "$rc"
case "$out" in *WORKDIR*) ok "no workdir: the refusal names the missing field" ;; *) bad "refusal text" "$out" ;; esac
[ ! -s "$T/rtlog" ] && ok "no workdir: the runtime was never executed" || bad "the probe ran anyway" "$(cat "$T/rtlog")"

printf 'pass=%d fail=%d\n' "$pass" "$fail"
[ "$fail" -eq 0 ] || exit 1
