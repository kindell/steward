#!/bin/bash
# lib/jobreconcile.sh — the reconciler: search for a receipt BEFORE any retry.
#
# ARTIFACT, RECEIPT-STATE AND NOTICE ARE THREE SEPARATE CRASH POINTS [A2].
# The reconciler reads all three surfaces (row, worktree, remote) and finishes
# the bookkeeping from evidence. The ORDER of the checks is the doctrine:
# terminal first (a finished job is finished), then desired-state (cancel
# beats everything), then deadline, then receipts (delivered work must never
# be redone), then — only when no receipt exists anywhere — the retry.
# One decision per invocation, every write through CAS.
#
# RECURSION: The push path (branch 5) and receipt verification (branch 3)
# deliberately recurse one level (two decisions in one external call).
# The push succeeds, then the next level verifies the receipt and sets outcome.
# This is the intentional exception to "one decision per invocation"; it catches
# the crash window between push and registration in a single reconcile call.

jobreconcile() {
  local id="$1"
  jobstate_read "$id" || return $?
  local v="$JOB_VERSION" branch have local_sha
  branch="$(jobgit_branch "$id")" || return $?

  # 0. Terminal is terminal — but a late delivery after cancel is RECORDED.
  case "${JOB_OUTCOME:-pending}" in
    cancelled)
      if [ -z "${JOB_LATE_DELIVERY:-}" ] && [ -d "${JOB_WORKDIR:-/nonexistent}" ]; then
        local_sha="$(git -C "$JOB_WORKDIR" rev-parse "refs/heads/$branch" 2>/dev/null)"
        if [ -n "$local_sha" ] && [ "$local_sha" != "${JOB_BASE_SHA:?}" ]; then
          jobstate_transition "$id" "$v" LATE_DELIVERY=1; return 0
        fi
      fi
      return 0 ;;
    succeeded|failed|abandoned|timed_out) return 0 ;;
  esac

  # 1. Cancel beats everything else.
  if [ "${JOB_DESIRED:-run}" = "cancel" ]; then
    jobstate_transition "$id" "$v" OUTCOME=cancelled || return 0
    joboutbox_enqueue "$id" "$((v+1))" "job $id cancelled"
    joboutbox_drain "$id" || true
    return 0
  fi

  # 2. Absolute deadline.
  if [ -n "${JOB_DEADLINE_ABSOLUT:-}" ] && [ "$(_jobstate_now)" -ge "$JOB_DEADLINE_ABSOLUT" ]; then
    jobstate_transition "$id" "$v" OUTCOME=timed_out FAIL_REASON=absolute-deadline || return 0
    joboutbox_enqueue "$id" "$((v+1))" "job $id timed out"
    joboutbox_drain "$id" || true
    return 0
  fi

  # 3. A registered delivery: verify the remote tip. Moved => failed, never done.
  if [ -n "${JOB_DELIVERY_SHA:-}" ]; then
    if jobgit_receipt "$id" "$JOB_WORKDIR" "$JOB_DELIVERY_SHA" 2>/dev/null; then
      jobstate_transition "$id" "$v" DELIVERY_RECEIPT=verified OUTCOME=succeeded || return 0
      joboutbox_enqueue "$id" "$((v+1))" "job $id succeeded, delivery $JOB_DELIVERY_SHA on $branch"
      joboutbox_drain "$id" || true
    else
      jobstate_transition "$id" "$v" DELIVERY_RECEIPT=failed OUTCOME=failed FAIL_REASON=remote-moved || return 0
      joboutbox_enqueue "$id" "$((v+1))" "job $id failed: remote ref moved unexpectedly"
      joboutbox_drain "$id" || true
    fi
    return 0
  fi

  # 4. Slots exhausted with nothing delivered: abandoned, artifacts preserved.
  if [ "${JOB_SLOTS_EXHAUSTED:-}" = "1" ]; then
    jobstate_transition "$id" "$v" OUTCOME=abandoned FAIL_REASON=slots-exhausted || return 0
    joboutbox_enqueue "$id" "$((v+1))" "job $id abandoned: attempt slots exhausted; worktree preserved"
    joboutbox_drain "$id" || true
    return 0
  fi

  # 5. A local commit the remote lacks, process dead: push the EXACT sha.
  if [ -d "${JOB_WORKDIR:-/nonexistent}" ] && ! _jobreconcile_alive "$id"; then
    local_sha="$(git -C "$JOB_WORKDIR" rev-parse "refs/heads/$branch" 2>/dev/null)"
    have="$(git -C "$JOB_WORKDIR" ls-remote origin "refs/heads/$branch" 2>/dev/null | cut -f1)"
    # Crash window: push succeeded but DELIVERY_SHA not registered yet.
    # The remote tip IS a receipt; register it and verify.
    if [ -n "$local_sha" ] && [ -z "${JOB_DELIVERY_SHA:-}" ] && [ "$local_sha" = "$have" ] && [ "$local_sha" != "${JOB_BASE_SHA:?}" ]; then
      jobstate_transition "$id" "$v" DELIVERY_SHA="$local_sha" || return 0
      jobreconcile "$id"
      return 0
    fi
    if [ -n "$local_sha" ] && [ "$local_sha" != "${JOB_BASE_SHA:?}" ] && [ "$local_sha" != "$have" ]; then
      local out
      if out="$(jobgit_deliver "$id" "$JOB_WORKDIR" "${have:-}")"; then
        jobstate_transition "$id" "$v" DELIVERY_SHA="${out#DELIVERY_SHA=}"
        # Finalize in the same breath: the next branch up (a registered
        # delivery) verifies the receipt and sets the outcome. One level of
        # recursion, and it terminates — DELIVERY_SHA is now set.
        jobreconcile "$id"
      else
        jobstate_transition "$id" "$v" OUTCOME=failed FAIL_REASON=remote-moved || return 0
        joboutbox_enqueue "$id" "$((v+1))" "job $id failed: remote ref moved unexpectedly"
        joboutbox_drain "$id" || true
      fi
      return 0
    fi
    # 6. Dirty or unfinished worktree, process dead, slots left: resume.
    "${JOBRECONCILE_RUNNER:-$(dirname "${BASH_SOURCE[0]}")/../job-run.sh}" "$id"
    return 0
  fi
  return 0
}

_jobreconcile_alive() { jobstate_lease_holder "$1" >/dev/null 2>&1; }
