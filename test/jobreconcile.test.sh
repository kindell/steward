#!/bin/bash
# test/jobreconcile.test.sh — the reconciler SEARCHES FOR A RECEIPT BEFORE IT
# RETRIES [A2]. Every block below is one crash window from the spec: the
# machinery died at a specific point, and the reconciler must finish the job's
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

mkjob() { # <id> — fresh origin+work with one delivered-locally commit staged per caller
  local id="$1"
  git init -q --bare "$T/$id-origin.git"
  git clone -q "$T/$id-origin.git" "$T/$id-src" 2>/dev/null
  ( cd "$T/$id-src" && echo base > f && git add f && git commit -qm base && git push -q origin HEAD )
  jobgit_checkout "$id" "$T/$id-src" "$T/$id-work" > "$T/$id-base"
  jobstate_create "$id" GOAL=g OWNER=alice DESIRED=run PROCESS=exited EXIT_CODE=0 \
    WORKDIR="$T/$id-work" RUNTIME=claude-code BRIEF_OBJECTIVE=o BRIEF_DELIVERY=d BRIEF_TOOLS=t BRIEF_BOUNDS=b
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
jobstate_read "$id"; jobstate_transition "$id" "$JOB_VERSION" DEADLINE_ABSOLUT=500
jobreconcile "$id"
jobstate_read "$id"
[ "$JOB_OUTCOME" = "timed_out" ] && ok "deadline: timed_out" || bad "OUTCOME" "$JOB_OUTCOME"

# TERMINAL IS TERMINAL: reconciling a finished job changes nothing.
v="$JOB_VERSION"
jobreconcile "$id"; jobstate_read "$id"
[ "$JOB_VERSION" = "$v" ] && ok "terminal rows are left alone" || bad "terminal row mutated"

printf 'pass=%d fail=%d\n' "$pass" "$fail"
[ "$fail" -eq 0 ] || exit 1
