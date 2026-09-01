#!/bin/bash
# test/jobreconcile.test.sh — the reconciler SEARCHES FOR A RECEIPT BEFORE IT
# RETRIES [A2]. Every block below is one crash window from the spec: the
# machinery died at a specific stage, and the reconciler must finish the job's
# bookkeeping from the evidence — never rerun a model whose work already
# landed, never force, never guess.
set -u
pass=0; fail=0
ok()  { pass=$((pass+1)); printf '  ok   %s\n' "$1"; }
bad() { fail=$((fail+1)); printf '  FAIL %s\n     %s\n' "$1" "${2:-}"; }
here="$(CDPATH= cd -- "$(dirname "$0")" && pwd)"
. "$here/../lib/jobstate.sh"; . "$here/../lib/jobgit.sh"; . "$here/../lib/joboutbox.sh"; . "$here/../lib/jobreconcile.sh"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
export STEWARD_JOB_STATE_HOME="$T/jobs"
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
printf '#!/bin/bash\nprintf "%%s\\n" "$1" >> "%s/runnerlog"\n' "$T" > "$T/runner"; chmod +x "$T/runner"
export JOBRECONCILE_RUNNER="$T/runner"
printf '#!/bin/bash\nprintf "%%s\\n---\\n" "$2" >> "%s/sendlog"\n' "$T" > "$T/sender"; chmod +x "$T/sender"
export JOBOUTBOX_SEND="$T/sender"
export JOBSTATE_NOW=1000

mkjob() { # <id> — fresh origin+work with two pre-checkout commits to expose BASE_SHA vs root-commit differences
  local id="$1" base_sha
  git init -q --bare "$T/$id-origin.git"
  git clone -q "$T/$id-origin.git" "$T/$id-src" 2>/dev/null
  ( cd "$T/$id-src" && \
    echo one > f && git add f && git commit -qm one && \
    echo two >> f && git commit -qam two && \
    git push -q origin HEAD )
  jobgit_checkout "$id" "$T/$id-src" "$T/$id-work" > "$T/$id-base"
  base_sha="$(cat "$T/$id-base")"
  jobstate_create "$id" GOAL=g OWNER=alice DESIRED=run PROCESS=exited EXIT_CODE=0 \
    WORKDIR="$T/$id-work" RUNTIME=claude-code BRIEF_OBJECTIVE=o BRIEF_DELIVERY=d BRIEF_TOOLS=t BRIEF_BOUNDS=b \
    MESSAGE_RECEIPT=not-sent \
    "$base_sha"
}

# WINDOW: push happened, state did not. Reconciler verifies and finalizes —
# the model is NOT rerun.
id=j-0000000000000101; mkjob "$id"
( cd "$T/$id-work" && echo done > f && git add f && git commit -qm work )
del="$(jobgit_deliver "$id" "$T/$id-work" "")"; del="${del#DELIVERY_SHA=}"
jobstate_read "$id"; jobstate_transition "$id" "$JOB_VERSION" DELIVERY_SHA="$del"
jobreconcile "$id" && ok "push-no-state: rc 0" || bad "reconcile failed"
jobstate_read "$id"
[ "$JOB_OUTCOME" = "succeeded" ] && ok "push-no-state: succeeded" || bad "OUTCOME" "${JOB_OUTCOME:-}"
[ "$JOB_DELIVERY_RECEIPT" = "verified" ] && ok "push-no-state: receipt verified" || bad "RECEIPT" "${JOB_DELIVERY_RECEIPT:-}"
[ ! -e "$T/runnerlog" ] && ok "push-no-state: model NOT rerun" || bad "model rerun on delivered work"
grep -q "event: job-$id-terminal" "$T/sendlog" && ok "push-no-state: notice sent" || bad "no notice"
grep -qE "^DRIFT $id: job succeeded" "$T/sendlog" && ok "push-no-state: notice carries the bus envelope [C1]" || bad "envelope missing" "$(grep "$id" "$T/sendlog")"
[ "$JOB_MESSAGE_RECEIPT" = "sent" ] && ok "push-no-state: MESSAGE_RECEIPT=sent after successful drain [I2]" || bad "MESSAGE_RECEIPT" "${JOB_MESSAGE_RECEIPT:-unset}"

# WINDOW: local commit exists, push missing, process dead. Push the exact SHA.
id=j-0000000000000102; mkjob "$id"
( cd "$T/$id-work" && echo done > f && git add f && git commit -qm work )
want="$(git -C "$T/$id-work" rev-parse HEAD)"
jobreconcile "$id" && ok "commit-no-push: rc 0" || bad "reconcile failed"
jobstate_read "$id"
[ "$JOB_DELIVERY_SHA" = "$want" ] && ok "commit-no-push: exact sha delivered" || bad "sha" "${JOB_DELIVERY_SHA:-}"
[ "$JOB_OUTCOME" = "succeeded" ] && ok "commit-no-push: succeeded" || bad "OUTCOME" "$JOB_OUTCOME"

# WINDOW: dirty worktree, process dead, slots left. Resume — same worktree,
# runner invoked, nothing reset.
id=j-0000000000000103; mkjob "$id"
echo half-done > "$T/$id-work/f"
jobreconcile "$id" && ok "dirty-dead: rc 0" || bad "reconcile failed"
grep -q "$id" "$T/runnerlog" && ok "dirty-dead: runner re-invoked" || bad "no retry"
[ "$(cat "$T/$id-work/f")" = "half-done" ] && ok "dirty-dead: edits preserved" || bad "worktree reset"

# WINDOW: remote moved from the registered delivery. failed, never done, never force.
id=j-0000000000000104; mkjob "$id"
( cd "$T/$id-work" && echo done > f && git add f && git commit -qm work )
del="$(jobgit_deliver "$id" "$T/$id-work" "")"; del="${del#DELIVERY_SHA=}"
jobstate_read "$id"; jobstate_transition "$id" "$JOB_VERSION" DELIVERY_SHA="$del" DELIVERY_RECEIPT=verified OUTCOME=pending
git clone -q "$T/$id-origin.git" "$T/$id-intruder" 2>/dev/null
( cd "$T/$id-intruder" && git checkout -q "steward/jobs/$id/delivery" && echo moved > f && git add f && git commit -qm moved && git push -q origin HEAD )
jobreconcile "$id"
jobstate_read "$id"
[ "$JOB_OUTCOME" = "failed" ] && ok "remote-moved: failed" || bad "OUTCOME" "$JOB_OUTCOME"
[ "${JOB_FAIL_REASON:-}" = "remote-moved" ] && ok "remote-moved: reason named" || bad "FAIL_REASON" "${JOB_FAIL_REASON:-}"

# WINDOW: slots exhausted. abandoned with the artifacts still in place.
id=j-0000000000000105; mkjob "$id"
jobstate_read "$id"; jobstate_transition "$id" "$JOB_VERSION" SLOTS_EXHAUSTED=1
jobreconcile "$id"
jobstate_read "$id"
[ "$JOB_OUTCOME" = "abandoned" ] && ok "slots: abandoned" || bad "OUTCOME" "$JOB_OUTCOME"
[ -d "$T/$id-work" ] && ok "slots: worktree preserved" || bad "worktree gone"

# WINDOW: cancel beats a late completion. late_delivery recorded, never done.
id=j-0000000000000106; mkjob "$id"
jobstate_read "$id"; jobstate_transition "$id" "$JOB_VERSION" DESIRED=cancel
jobreconcile "$id"
jobstate_read "$id"
[ "$JOB_OUTCOME" = "cancelled" ] && ok "cancel: cancelled" || bad "OUTCOME" "$JOB_OUTCOME"
v="$JOB_VERSION"
( cd "$T/$id-work" && echo late > f && git add f && git commit -qm late )
jobreconcile "$id"
jobstate_read "$id"
[ "$JOB_OUTCOME" = "cancelled" ] && ok "cancel: late delivery does not flip outcome" || bad "OUTCOME flipped" "$JOB_OUTCOME"
[ "${JOB_LATE_DELIVERY:-}" = "1" ] && ok "cancel: late_delivery recorded" || bad "no LATE_DELIVERY"

# WINDOW: absolute deadline passed. timed_out.
id=j-0000000000000107; mkjob "$id"
jobstate_read "$id"; jobstate_transition "$id" "$JOB_VERSION" DEADLINE_ABSOLUTE=500
jobreconcile "$id"
jobstate_read "$id"
[ "$JOB_OUTCOME" = "timed_out" ] && ok "deadline: timed_out" || bad "OUTCOME" "$JOB_OUTCOME"

# TERMINAL IS TERMINAL: reconciling a finished job changes nothing.
v="$JOB_VERSION"
jobreconcile "$id"; jobstate_read "$id"
[ "$JOB_VERSION" = "$v" ] && ok "terminal rows are left alone" || bad "terminal row mutated"

# FINDING 1 (Critical): push succeeded, DELIVERY_SHA unset. Reconciler handles
# the crash window where remote has the commit but the row does not.
id=j-0000000000000108; mkjob "$id"
( cd "$T/$id-work" && echo done > f && git add f && git commit -qm work )
del="$(jobgit_deliver "$id" "$T/$id-work" "")"; del="${del#DELIVERY_SHA=}"
# Do NOT set DELIVERY_SHA in the row — simulate the crash stage
jobstate_read "$id"
rm -f "$T/runnerlog"  # Clear any prior runner invocations
jobreconcile "$id" && ok "push-crash-window: rc 0" || bad "reconcile failed"
jobstate_read "$id"
[ "${JOB_DELIVERY_SHA:-}" = "$del" ] && ok "push-crash-window: DELIVERY_SHA set" || bad "sha" "${JOB_DELIVERY_SHA:-}"
[ "${JOB_OUTCOME:-}" = "succeeded" ] && ok "push-crash-window: succeeded" || bad "OUTCOME" "${JOB_OUTCOME:-}"
[ ! -e "$T/runnerlog" ] && ok "push-crash-window: model NOT rerun" || bad "model rerun on delivered work"

# FINDING 2 + I3: a lost CAS write must not report rc 0 — the caller (e.g.
# bin/steward's `job cancel`) has to be able to see the stand-down.
id=j-0000000000000109; mkjob "$id"
jobstate_read "$id"
jobstate_transition "$id" "$JOB_VERSION" DESIRED=cancel
# Pre-create write-lock directory to block the next CAS attempt
mkdir "$STEWARD_JOB_STATE_HOME/$id/write-lock" 2>/dev/null || true
rm -f "$T/sendlog"  # Clear sendlog
jobreconcile "$id" 2>/dev/null; rc=$?
[ "$rc" -ne 0 ] && ok "cas-refused: reconcile rc != 0, caller can see the loss [I3]" || bad "reconcile silently reported rc 0 on lost CAS"
# Check that no outbox entry was created (no line in sendlog with this job)
if [ -f "$T/sendlog" ] && grep -q "$id" "$T/sendlog" 2>/dev/null; then
  bad "cas-refused: notice sent despite CAS failure"
else
  ok "cas-refused: no notice on refused CAS"
fi
# Verify row is unchanged
jobstate_read "$id"
[ "${JOB_OUTCOME:-}" = "" ] && ok "cas-refused: row unchanged after CAS refusal" || bad "OUTCOME changed" "${JOB_OUTCOME:-}"
# Remove lock, reconcile again, should now succeed and send notice
rmdir "$STEWARD_JOB_STATE_HOME/$id/write-lock" 2>/dev/null || true
rm -f "$T/sendlog"
jobreconcile "$id" && ok "cas-refused: reconcile rc 0 once the lock clears" || bad "reconcile still refused after unlock"
jobstate_read "$id"
[ "$JOB_OUTCOME" = "cancelled" ] && ok "cas-refused: cancelled after CAS ok" || bad "OUTCOME" "${JOB_OUTCOME:-}"
if [ -f "$T/sendlog" ] && grep -qE "^DRIFT $id: job cancelled" "$T/sendlog" 2>/dev/null; then
  ok "cas-refused: notice sent on second attempt, envelope intact [C1]"
else
  bad "cas-refused: no notice on second attempt"
fi
[ "$JOB_MESSAGE_RECEIPT" = "sent" ] && ok "cas-refused: MESSAGE_RECEIPT=sent after the notice actually drained [I2]" || bad "MESSAGE_RECEIPT" "${JOB_MESSAGE_RECEIPT:-unset}"

# I2 (failure path): a sender that fails must NOT advance MESSAGE_RECEIPT —
# the row stays not-sent, so a later drain still retries.
id=j-000000000000010a; mkjob "$id"
jobstate_read "$id"; jobstate_transition "$id" "$JOB_VERSION" DESIRED=cancel
export JOBOUTBOX_SEND=/bin/false
jobreconcile "$id" 2>/dev/null
export JOBOUTBOX_SEND="$T/sender"
jobstate_read "$id"
[ "$JOB_OUTCOME" = "cancelled" ] && ok "message-receipt: outcome lands even when the sender fails" || bad "OUTCOME" "${JOB_OUTCOME:-}"
[ "$JOB_MESSAGE_RECEIPT" = "not-sent" ] && ok "message-receipt: stays not-sent when the sender fails [I2]" || bad "MESSAGE_RECEIPT" "${JOB_MESSAGE_RECEIPT:-unset}"

# I1: a row missing BASE_SHA reconciles to a loud, named refusal — never
# kills the calling shell the way ${JOB_BASE_SHA:?} used to.
id=j-000000000000010b; mkjob "$id"
grep -v '^BASE_SHA=' "$T/jobs/$id/row" > "$T/jobs/$id/row.tmp" && mv "$T/jobs/$id/row.tmp" "$T/jobs/$id/row"
out="$(jobreconcile "$id" 2>&1)"; rc=$?
[ "$rc" -eq 65 ] && ok "no-base-sha: refuses with rc 65 [I1]" || bad "rc" "$rc"
case "$out" in *"$id"*) ok "no-base-sha: refusal names the job" ;; *) bad "job id missing from refusal" "$out" ;; esac
case "$out" in *BASE_SHA*) ok "no-base-sha: refusal names the missing field" ;; *) bad "BASE_SHA missing from refusal" "$out" ;; esac
_i1_probe_survived=1

# I7: workdir deleted (host lost the clone) — a terminal failure with a
# reason, never a silent forever-pending row.
id=j-000000000000010c; mkjob "$id"
rm -rf "$T/$id-work"
jobreconcile "$id"
jobstate_read "$id"
[ "$JOB_OUTCOME" = "failed" ] && ok "workdir-missing: failed, not silent [I7]" || bad "OUTCOME" "${JOB_OUTCOME:-}"
[ "${JOB_FAIL_REASON:-}" = "workdir-missing" ] && ok "workdir-missing: reason named" || bad "FAIL_REASON" "${JOB_FAIL_REASON:-}"

# I7: delivery ref deleted from origin (branch cleanup) after being
# registered — a DIFFERENT truth than "moved", so a different reason.
id=j-000000000000010d; mkjob "$id"
( cd "$T/$id-work" && echo done > f && git add f && git commit -qm work )
del="$(jobgit_deliver "$id" "$T/$id-work" "")"; del="${del#DELIVERY_SHA=}"
jobstate_read "$id"; jobstate_transition "$id" "$JOB_VERSION" DELIVERY_SHA="$del" DELIVERY_RECEIPT=verified OUTCOME=pending
git -C "$T/$id-origin.git" update-ref -d "refs/heads/steward/jobs/$id/delivery"
jobreconcile "$id"
jobstate_read "$id"
[ "$JOB_OUTCOME" = "failed" ] && ok "remote-ref-absent: failed" || bad "OUTCOME" "${JOB_OUTCOME:-}"
[ "${JOB_FAIL_REASON:-}" = "remote-ref-absent" ] && ok "remote-ref-absent: reason distinct from remote-moved [I7]" || bad "FAIL_REASON" "${JOB_FAIL_REASON:-}"

# C3: a transient remote outage is retry-wait, never failed — and a later
# reconcile with origin back delivers the finished work honestly instead of
# throwing it away under a false "remote-moved".
id=j-000000000000010e; mkjob "$id"
( cd "$T/$id-work" && echo done > f && git add f && git commit -qm work )
real_origin="$(git -C "$T/$id-work" remote get-url origin)"
git -C "$T/$id-work" remote set-url origin "$T/does-not-exist-$id.git"
jobreconcile "$id"
jobstate_read "$id"
[ "${JOB_PROCESS:-}" = "retry-wait" ] && ok "outage: PROCESS=retry-wait, never failed [C3]" || bad "PROCESS" "${JOB_PROCESS:-}"
[ "${JOB_FAIL_REASON:-}" = "remote-unreachable" ] && ok "outage: reason names the outage" || bad "FAIL_REASON" "${JOB_FAIL_REASON:-}"
[ -z "${JOB_OUTCOME:-}" ] && ok "outage: row stays non-terminal" || bad "outage flipped OUTCOME" "${JOB_OUTCOME:-}"
git -C "$T/$id-work" remote set-url origin "$real_origin"
jobreconcile "$id"
jobstate_read "$id"
[ "$JOB_OUTCOME" = "succeeded" ] && ok "outage: reconcile delivers once origin is back [C3]" || bad "OUTCOME after recovery" "${JOB_OUTCOME:-}"

# C2: a lease renewed past its original TTL keeps looking alive — the
# reconciler must never spawn a second runner into the same worktree/branch.
id=j-000000000000010f; mkjob "$id"
echo half-done > "$T/$id-work/f"
jobstate_read "$id"; jobstate_transition "$id" "$JOB_VERSION" PROCESS=running
jobstate_lease_acquire "$id" "job-run:99999" 300 >/dev/null
t=1000
while [ "$t" -lt 1400 ]; do
  t=$((t+30)); export JOBSTATE_NOW=$t
  jobstate_lease_renew "$id" "job-run:99999" >/dev/null
done
rm -f "$T/runnerlog"
jobreconcile "$id"
[ ! -e "$T/runnerlog" ] && ok "C2: lease renewals (past the original 300s TTL) prevent a second runner" || bad "second runner spawned despite live renewals"
export JOBSTATE_NOW=1000

[ "${_i1_probe_survived:-}" = "1" ] && ok "no-base-sha: calling shell survived to run these later assertions [I1]" || bad "script did not survive the BASE_SHA refusal"

printf 'pass=%d fail=%d\n' "$pass" "$fail"
[ "$fail" -eq 0 ] || exit 1
