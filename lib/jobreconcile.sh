#!/bin/bash
# lib/jobreconcile.sh — the reconciler: search for a receipt BEFORE any retry.
#
# ARTIFACT, RECEIPT-STATE AND NOTICE ARE THREE SEPARATE CRASH SURFACES [A2].
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
#
# A LOST CAS WRITE IS NEVER SILENT [I3]. Every jobstate_transition below is
# guarded with `|| return 75` — the same code jobstate_transition itself uses
# for contention — so a caller (bin/steward's `job cancel`, a supervisor loop)
# sees the stand-down instead of being told a decision landed when it did not.
#
# EVERY TERMINAL NOTICE CARRIES THE BUS ENVELOPE [C1]. The first line of the
# text handed to joboutbox_enqueue is always `DRIFT <job-id>: <summary>` — the
# job id is already a valid envelope subject, so this satisfies the bus's
# grammar for free. `_jobreconcile_notify` also advances MESSAGE_RECEIPT=sent
# once the drain actually delivers THIS terminal event, never on a bare
# enqueue [I2].

jobreconcile() {
  local id="$1"
  jobstate_read "$id" || return $?
  local v="$JOB_VERSION" branch have local_sha
  branch="$(jobgit_branch "$id")" || return $?

  # 0. Terminal is terminal — but a late delivery after cancel is RECORDED.
  case "${JOB_OUTCOME:-pending}" in
    cancelled)
      if [ -z "${JOB_LATE_DELIVERY:-}" ] && [ -d "${JOB_WORKDIR:-/nonexistent}" ]; then
        _jobreconcile_require_base_sha "$id" || return 65
        local_sha="$(git -C "$JOB_WORKDIR" rev-parse "refs/heads/$branch" 2>/dev/null)"
        if [ -n "$local_sha" ] && [ "$local_sha" != "$JOB_BASE_SHA" ]; then
          jobstate_transition "$id" "$v" LATE_DELIVERY=1; return 0
        fi
      fi
      return 0 ;;
    succeeded|failed|abandoned|timed_out) return 0 ;;
  esac

  # 1. Cancel beats everything else.
  if [ "${JOB_DESIRED:-run}" = "cancel" ]; then
    jobstate_transition "$id" "$v" OUTCOME=cancelled || return 75
    _jobreconcile_notify "$id" "$((v+1))" "DRIFT $id: job cancelled"
    return 0
  fi

  # 2. Absolute deadline.
  if [ -n "${JOB_DEADLINE_ABSOLUTE:-}" ] && [ "$(_jobstate_now)" -ge "$JOB_DEADLINE_ABSOLUTE" ]; then
    jobstate_transition "$id" "$v" OUTCOME=timed_out FAIL_REASON=absolute-deadline || return 75
    _jobreconcile_notify "$id" "$((v+1))" "DRIFT $id: job timed out"
    return 0
  fi

  # 3. A registered delivery: verify the remote tip. Moved => failed, never
  # done. Absent (ref deleted, e.g. branch cleanup) is a DIFFERENT truth than
  # moved, and gets its own reason [I7] — jobgit_receipt tells them apart by rc.
  if [ -n "${JOB_DELIVERY_SHA:-}" ]; then
    local receipt_rc=0
    jobgit_receipt "$id" "$JOB_WORKDIR" "$JOB_DELIVERY_SHA" 2>/dev/null || receipt_rc=$?
    if [ "$receipt_rc" -eq 0 ]; then
      jobstate_transition "$id" "$v" DELIVERY_RECEIPT=verified OUTCOME=succeeded || return 75
      _jobreconcile_notify "$id" "$((v+1))" "DRIFT $id: job succeeded, delivery $JOB_DELIVERY_SHA on $branch"
    elif [ "$receipt_rc" -eq 66 ]; then
      jobstate_transition "$id" "$v" DELIVERY_RECEIPT=failed OUTCOME=failed FAIL_REASON=remote-ref-absent || return 75
      _jobreconcile_notify "$id" "$((v+1))" "DRIFT $id: job failed: delivery ref no longer exists on remote"
    else
      jobstate_transition "$id" "$v" DELIVERY_RECEIPT=failed OUTCOME=failed FAIL_REASON=remote-moved || return 75
      _jobreconcile_notify "$id" "$((v+1))" "DRIFT $id: job failed: remote ref moved unexpectedly"
    fi
    return 0
  fi

  # 4. Slots exhausted with nothing delivered: abandoned, artifacts preserved.
  if [ "${JOB_SLOTS_EXHAUSTED:-}" = "1" ]; then
    jobstate_transition "$id" "$v" OUTCOME=abandoned FAIL_REASON=slots-exhausted || return 75
    _jobreconcile_notify "$id" "$((v+1))" "DRIFT $id: job abandoned: attempt slots exhausted; worktree preserved"
    return 0
  fi

  # 5. A local commit the remote lacks, process dead: push the EXACT sha.
  # "Dead" is lease-based [C2] — job-run.sh's heartbeat renews the SAME lease
  # every tick now, so a live attempt (any length) keeps it live; this check
  # means something again instead of racing a fixed TTL against real work.
  if ! _jobreconcile_alive "$id"; then
    # The workdir itself is gone (host lost the clone) — this cannot resolve
    # itself, and staying silent forever is the bug [I7]. Distinct from the
    # ordinary "still running" case, which correctly does nothing here.
    if [ ! -d "${JOB_WORKDIR:-/nonexistent}" ]; then
      jobstate_transition "$id" "$v" OUTCOME=failed FAIL_REASON=workdir-missing || return 75
      _jobreconcile_notify "$id" "$((v+1))" "DRIFT $id: job failed: workdir no longer exists"
      return 0
    fi
    _jobreconcile_require_base_sha "$id" || return 65
    local_sha="$(git -C "$JOB_WORKDIR" rev-parse "refs/heads/$branch" 2>/dev/null)"
    have="$(git -C "$JOB_WORKDIR" ls-remote origin "refs/heads/$branch" 2>/dev/null | cut -f1)"
    # Crash window: push succeeded but DELIVERY_SHA not registered yet.
    # The remote tip IS a receipt; register it and verify.
    if [ -n "$local_sha" ] && [ -z "${JOB_DELIVERY_SHA:-}" ] && [ "$local_sha" = "$have" ] && [ "$local_sha" != "$JOB_BASE_SHA" ]; then
      jobstate_transition "$id" "$v" DELIVERY_SHA="$local_sha" || return 75
      jobreconcile "$id"
      return 0
    fi
    # CRASHED IS NOT FINISHED. The wrapper writes PROCESS=exited for every
    # attempt it survives, so a dead lease over a row that still says
    # PROCESS=running means the attempt was killed mid-work. Its commits are
    # the CHECKPOINT, not a delivery — pushing them here would report a
    # half-finished attempt as a success, which is the same class of lie as
    # deciding an outcome the machinery never reached [A3]. So: no delivery,
    # fall through to the runner below and resume. Branch 4 (slots exhausted)
    # sits above this, so the resume cannot loop forever.
    local crashed=""
    [ "${JOB_PROCESS:-}" = "running" ] && crashed=1
    if [ -z "$crashed" ] && [ -n "$local_sha" ] && [ "$local_sha" != "$JOB_BASE_SHA" ] && [ "$local_sha" != "$have" ]; then
      local out deliver_rc=0
      if out="$(jobgit_deliver "$id" "$JOB_WORKDIR" "${have:-}")"; then
        jobstate_transition "$id" "$v" DELIVERY_SHA="${out#DELIVERY_SHA=}" || return 75
        # Finalize in the same breath: the next branch up (a registered
        # delivery) verifies the receipt and sets the outcome. One level of
        # recursion, and it terminates — DELIVERY_SHA is now set.
        jobreconcile "$id"
      else
        deliver_rc=$?
        if [ "$deliver_rc" -eq 69 ]; then
          # Outage, not a conflict [C3]: leave the row non-terminal so a
          # later reconcile — origin back — delivers the finished work
          # instead of a false "remote-moved" throwing it away.
          jobstate_transition "$id" "$v" PROCESS=retry-wait FAIL_REASON=remote-unreachable || return 75
        else
          jobstate_transition "$id" "$v" OUTCOME=failed FAIL_REASON=remote-moved || return 75
          _jobreconcile_notify "$id" "$((v+1))" "DRIFT $id: job failed: remote ref moved unexpectedly"
        fi
      fi
      return 0
    fi
    # THE ROW SAYS WHICH RESUME THIS IS. A thread id already on the row means
    # the next attempt resumes that exact thread; no thread id means the crash
    # took the memory with it and attempt N+1 starts fresh on the same branch.
    # Naming it is the point: the log must never claim an exact resume that
    # did not happen.
    if [ -n "$crashed" ]; then
      if [ -n "${JOB_RUNTIME_THREAD:-}" ]; then
        jobstate_transition "$id" "$v" RESUME_KIND=exact-thread || return 75
      else
        jobstate_transition "$id" "$v" RESUME_KIND=fresh-after-crash || return 75
      fi
    fi
    # 6. Dirty or unfinished worktree, process dead, slots left: resume.
    "${JOBRECONCILE_RUNNER:-$(dirname "${BASH_SOURCE[0]}")/../job-run.sh}" "$id"
    return 0
  fi
  return 0
}

_jobreconcile_alive() { jobstate_lease_holder "$1" >/dev/null 2>&1; }

# ${JOB_BASE_SHA:?} used to kill the CALLING shell on a row missing BASE_SHA —
# a library must never do that [I1]. This is the honest replacement: a named,
# loud refusal (rc 65) the caller can see and survive.
_jobreconcile_require_base_sha() {
  local id="$1"
  [ -n "${JOB_BASE_SHA:-}" ] && return 0
  echo "jobreconcile: $id has no BASE_SHA — refusing to guess, not comparing" >&2
  return 65
}

# Enqueue + drain a terminal notice, then advance MESSAGE_RECEIPT=sent iff the
# drain actually delivered THIS event [I2] — not on a bare enqueue, and never
# when the sender failed (the row is left at its prior not-sent/unset state,
# which the next drain retries against the still-pending outbox file).
_jobreconcile_notify() {
  local id="$1" version="$2" text="$3" eid sent
  eid="job-$id-terminal-v$version"
  joboutbox_enqueue "$id" "$version" "$text"
  sent="$(joboutbox_drain "$id")"
  if printf '%s\n' "$sent" | grep -qx "$eid"; then
    jobstate_transition "$id" "$version" MESSAGE_RECEIPT=sent || true
  fi
}
