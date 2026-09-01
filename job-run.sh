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

id="${1:?usage: job-run.sh <job-id>}"
jobstate_read "$id" || exit $?

max="${JOBRUN_MAX_ATTEMPTS:-3}"
attempt=$(( ${JOB_ATTEMPT_ID:-0} + 1 ))
if [ "$attempt" -gt "$max" ]; then
  jobstate_transition "$id" "$JOB_VERSION" SLOTS_EXHAUSTED=1 || true
  echo "job-run: $id has spent its $max attempt slots — reconciler decides now" >&2
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
( while :; do touch "$home/$id/heartbeat"; sleep "${JOBRUN_HEARTBEAT_SEC:-30}"; done ) &
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
[ -n "$thread" ] || thread="$(printf '%s' "$out" | jq -r '.session_id // empty' 2>/dev/null)"

jobstate_read "$id"
jobstate_transition "$id" "$JOB_VERSION" PROCESS=exited EXIT_CODE="$rc" RUNTIME_THREAD="${thread:-}"
exit 0
