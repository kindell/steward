#!/bin/bash
# job-run.sh <job-id> — one attempt slot: lease, run headless, record honestly.
#
# THE WRAPPER DECIDES NOTHING TERMINAL. It records what happened (PROCESS,
# EXIT_CODE, ATTEMPT_ID, RUNTIME_THREAD) and leaves outcome, delivery and
# notices to the reconciler — exit 0 proves neither outcome nor delivery
# [A3]. Retry semantics live here though: attempt N>1 resumes the EXACT
# runtime thread recorded by attempt 1. A fresh thread would redo finished
# work; the branch is the checkpoint, the thread is the memory.
set -u
here="$(CDPATH= cd -- "$(dirname "$0")" && pwd)"
. "$here/lib/jobstate.sh"

# Factored finalization: check final transition, retry on contention, preserve lease on failure.
_jobrun_finalize() {
  local jid="$1" exit_code="$2" thread_id="$3" parse_failed="$4"
  local rc retry_count=0

  while [ "$retry_count" -lt 2 ]; do
    jobstate_transition "$jid" "$JOB_VERSION" \
      PROCESS=exited EXIT_CODE="$exit_code" RUNTIME_THREAD="${thread_id:-}" \
      THREAD_PARSE_FAILED="$parse_failed"
    rc=$?

    if [ "$rc" -eq 0 ]; then
      # Success: remove lease on normal exit path
      return 0
    fi

    if [ "$rc" -eq 75 ]; then
      # CAS contention: re-read and retry once
      if [ "$retry_count" -eq 0 ]; then
        jobstate_read "$jid"
        retry_count=$((retry_count + 1))
        continue
      fi
    fi

    # Second failure or non-contention error: preserve lease, loud stderr, exit 70
    echo "job-run: FINAL BOOKKEEPING FAILED for $jid (rc $rc after retry)" >&2
    echo "  Preserving lease file to outlive this failure (honest state)." >&2
    trap - EXIT  # Clear the EXIT trap so we don't delete the lease
    exit 70
  done
}

id="${1:?usage: job-run.sh <job-id>}"
jobstate_read "$id" || exit $?

max="${JOBRUN_MAX_ATTEMPTS:-3}"
attempt=$(( ${JOB_ATTEMPT_ID:-0} + 1 ))
if [ "$attempt" -gt "$max" ]; then
  jobstate_transition "$id" "$JOB_VERSION" SLOTS_EXHAUSTED=1 || true
  echo "job-run: $id has spent its $max attempt slots — reconciler decides now" >&2
  exit 65
fi

# Refuse if THREAD_PARSE_FAILED from attempt 1: the thread id was unparseable.
# Attempt 2+ must not silently start a fresh thread.
if [ "${JOB_THREAD_PARSE_FAILED:-}" = "1" ] && [ -z "${JOB_RUNTIME_THREAD:-}" ]; then
  echo "job-run: $id failed to parse thread id in attempt 1 — refusing silent fresh-thread start" >&2
  echo "  (THREAD_PARSE_FAILED=1, RUNTIME_THREAD empty). Reconciler owns recovery." >&2
  exit 65
fi

runtime="${JOB_RUNTIME:-claude-code}"
if [ "$runtime" = "opencode" ]; then
  echo "job-run: REFUSES opencode — headless thread resume is not yet a measured" >&2
  echo "  capability (see docs/opencode-resume-measurement.md). Half support here" >&2
  echo "  would mean attempt 2 silently redoing attempt 1's work." >&2
  exit 65
fi

jobstate_lease_acquire "$id" "job-run:$$" "${JOBRUN_LEASE_TTL:-300}" || {
  echo "job-run: another runner holds the lease on $id" >&2; exit 75; }

jobstate_read "$id"
jobstate_transition "$id" "$JOB_VERSION" PROCESS=running ATTEMPT_ID="$attempt" || exit $?

home="$(jobstate_home)"
wrapper=$$
( while :; do kill -0 "$wrapper" 2>/dev/null || exit 0; touch "$home/$id/heartbeat"; sleep "${JOBRUN_HEARTBEAT_SEC:-30}"; done ) &
hb=$!
trap 'kill "$hb" 2>/dev/null; rm -f "$home/$id/lease"' EXIT

cmd="${JOBRUN_RUNTIME_CMD:-claude}"
prompt="GOAL: ${JOB_GOAL}
OBJECTIVE: ${JOB_BRIEF_OBJECTIVE:-}
DELIVERY: ${JOB_BRIEF_DELIVERY:-}
TOOLS: ${JOB_BRIEF_TOOLS:-}
BOUNDS: ${JOB_BRIEF_BOUNDS:-}"

out="" ; rc=0
if [ "$attempt" -eq 1 ] || [ -z "${JOB_RUNTIME_THREAD:-}" ]; then
  out="$(cd "${JOB_WORKDIR:?}" && "$cmd" -p --output-format json "$prompt")" || rc=$?
else
  out="$(cd "${JOB_WORKDIR:?}" && "$cmd" -p --resume "$JOB_RUNTIME_THREAD" --output-format json "$prompt")" || rc=$?
fi

thread="${JOB_RUNTIME_THREAD:-}"
thread_parse_failed="0"
if [ -n "$thread" ]; then
  : # thread already recorded, use it
elif command -v jq >/dev/null 2>&1; then
  thread="$(printf '%s' "$out" | jq -r '.session_id // empty' 2>/dev/null)"
  if [ -z "$thread" ] && [ "$rc" -eq 0 ]; then
    thread_parse_failed="1"
  fi
else
  if [ "$rc" -eq 0 ]; then
    thread_parse_failed="1"
  fi
fi

jobstate_read "$id"
_jobrun_finalize "$id" "$rc" "$thread" "$thread_parse_failed"
exit 0
