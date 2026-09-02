#!/bin/bash
# job-run.sh <job-id> — one attempt slot: lease, run headless, record honestly.
#
# THE WRAPPER DECIDES NOTHING TERMINAL. It records what happened (PROCESS,
# EXIT_CODE, ATTEMPT_ID, RUNTIME_THREAD) and leaves outcome, delivery and
# notices to the reconciler — exit 0 proves neither outcome nor delivery
# [A3]. Retry semantics live here though: a later attempt resumes the EXACT
# runtime thread of an earlier one whenever that thread is still there to
# resume. A fresh thread would redo finished work; the branch is the
# checkpoint, the thread is the memory.
#
# THE THREAD IS MINTED BEFORE THE RUN, NOT PARSED AFTER IT. A thread id first
# written when the wrapper exits only ever exists for an attempt that ended
# cleanly — the one case that does not need a resume. So when the runtime
# accepts a caller-chosen id, this wrapper mints one and records it in the
# SAME transition that sets PROCESS=running, before the runtime is called.
#
# BUT THE ROW NAMES A THREAD; IT DOES NOT PROVE ONE. An attempt killed in its
# first moments leaves a name the runtime never made into a session, and
# `--resume` on that id fails outright. So the wrapper asks the runtime's own
# store whether the thread exists before it resumes, and starts the same name
# with --session-id when it does not. RESUME_KIND records the kind of start
# THIS attempt got — first, exact-thread, fresh-after-crash, or
# thread-at-exit for a runtime that takes no caller-chosen id at all (that
# path is not faked; the id is parsed from the final JSON as before). The
# wrapper is the field's only writer, so nothing downstream can claim an
# exact resume that never happened.
set -u
here="$(CDPATH= cd -- "$(dirname "$0")" && pwd)"
. "$here/lib/jobstate.sh"

# Factored finalization: check final transition, retry on contention, preserve lease on failure.
_jobrun_finalize() {
  local jid="$1" exit_code="$2" thread_id="$3" parse_failed="$4" mismatch="${5:-}"
  local rc retry_count=0
  local mism=()
  [ -n "$mismatch" ] && mism=(THREAD_MISMATCH=1)

  while [ "$retry_count" -lt 2 ]; do
    jobstate_transition "$jid" "$JOB_VERSION" \
      PROCESS=exited EXIT_CODE="$exit_code" RUNTIME_THREAD="${thread_id:-}" \
      THREAD_PARSE_FAILED="$parse_failed" ${mism+"${mism[@]}"}
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

# A caller-chosen id is only honest if the runtime says it takes one, so the
# runtime is MEASURED, never assumed: its own --help is the evidence. Two
# rules keep the measurement from becoming a side effect of its own. It runs
# BEFORE the lease is taken, so a runtime that answers slowly holds nothing;
# and it runs INSIDE the job's own clone, the one directory this wrapper ever
# lets the runtime touch — measuring it in whatever directory the caller
# happened to be standing in is how a probe writes somewhere it was never
# invited. A runtime that cannot be measured is treated as taking no id.
_jobrun_takes_session_id() {
  local cmd="$1" dir="$2"
  ( cd "$dir" 2>/dev/null || exit 1; "$cmd" --help 2>/dev/null ) | grep -q -- '--session-id'
}

# DOES THE THREAD THE ROW NAMES ACTUALLY EXIST? The id on the row is a NAME
# this wrapper chose before the run; it becomes a session only once the runtime
# has written a transcript for it. Measured against the shipped runtime, the
# transcript lands at
#   $HOME/.claude/projects/<munged-cwd>/<uuid>.jsonl
# and `--resume <uuid>` for an id that has none fails outright ("No conversation
# found with session ID"). Matching the file ANYWHERE under the store is
# deliberate: the munged directory is derived from the cwd, and a job that moved
# clones would otherwise look like a job that lost its thread.
# JOBRUN_THREAD_STORE exists so the suite can point this at a store of its own.
_jobrun_thread_exists() {
  local uuid="$1" store="${JOBRUN_THREAD_STORE:-$HOME/.claude/projects}"
  [ -n "$uuid" ] || return 1
  [ -d "$store" ] || return 1
  [ -n "$(find "$store" -type f -name "$uuid.jsonl" 2>/dev/null | head -n 1)" ]
}

# Version-4 shape, lowercase — the runtime documents --session-id <uuid> and
# refuses anything that is not a valid one.
_jobrun_mint_thread() {
  if command -v uuidgen >/dev/null 2>&1; then
    uuidgen | tr 'A-Z' 'a-z'
    return 0
  fi
  if [ -r /proc/sys/kernel/random/uuid ]; then
    cat /proc/sys/kernel/random/uuid
    return 0
  fi
  local h; h="$(od -An -N16 -tx1 /dev/urandom | tr -d ' \n')"
  printf '%s-%s-4%s-a%s-%s\n' "${h:0:8}" "${h:8:4}" "${h:13:3}" "${h:17:3}" "${h:20:12}"
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

cmd="${JOBRUN_RUNTIME_CMD:-claude}"

# HOW THIS ATTEMPT STARTS IS DECIDED HERE, ONCE. The row NAMES a thread; the
# store says whether that name is a session yet. Three starts follow, and
# RESUME_KIND records which one this attempt got — the wrapper is the only
# writer of that field, in the same transition as PROCESS=running:
#   the row names a thread that exists  -> --resume <id>     exact-thread
#   the row names one that does not     -> --session-id <id> fresh-after-crash
#   no thread, runtime takes an id      -> mint it           first
#   no thread, runtime takes none       -> no flag at all    thread-at-exit
# The second line is the killed-in-the-first-moments case: the name stands, the
# session is created now, and nothing claims a resume that could not happen.
# Which of these it is has nothing to do with the attempt counter.
minted=""
thread_flag=()
resume_kind="thread-at-exit"
if [ -n "${JOB_RUNTIME_THREAD:-}" ]; then
  if _jobrun_thread_exists "$JOB_RUNTIME_THREAD"; then
    thread_flag=(--resume "$JOB_RUNTIME_THREAD"); resume_kind="exact-thread"
  else
    thread_flag=(--session-id "$JOB_RUNTIME_THREAD"); resume_kind="fresh-after-crash"
  fi
elif _jobrun_takes_session_id "$cmd" "${JOB_WORKDIR:-.}"; then
  minted="$(_jobrun_mint_thread)"
  thread_flag=(--session-id "$minted"); resume_kind="first"
fi

home="$(jobstate_home)"
wrapper=$$
owner="job-run:$wrapper"

# Release the lease only if THIS process still holds it — an unconditional
# rm here is how a slow attempt-1 deletes attempt-2's lease on its way out
# [C2].
_jobrun_release_lease() {
  local f="$home/$id/lease" holder until
  [ -f "$f" ] || return 0
  read -r holder until < "$f" 2>/dev/null || return 0
  [ "$holder" = "$owner" ] && rm -f "$f"
  return 0
}

jobstate_lease_acquire "$id" "$owner" "${JOBRUN_LEASE_TTL:-300}" || {
  echo "job-run: another runner holds the lease on $id" >&2; exit 75; }

jobstate_read "$id"
mint=()
[ -n "$minted" ] && mint=(RUNTIME_THREAD="$minted")
jobstate_transition "$id" "$JOB_VERSION" PROCESS=running ATTEMPT_ID="$attempt" \
  RESUME_KIND="$resume_kind" ${mint+"${mint[@]}"} || exit $?

# The heartbeat tick RENEWS THE ACTUAL LEASE, not just a touched file [C2] —
# jobstate_lease_renew is the only thing that keeps _jobreconcile_alive
# meaning something for an attempt that outlives the lease's own TTL.
( while :; do
    kill -0 "$wrapper" 2>/dev/null || exit 0
    touch "$home/$id/heartbeat"
    jobstate_lease_renew "$id" "$owner" >/dev/null 2>&1
    sleep "${JOBRUN_HEARTBEAT_SEC:-30}"
  done ) &
hb=$!
trap 'kill "$hb" 2>/dev/null; wait "$hb" 2>/dev/null; _jobrun_release_lease' EXIT

prompt="GOAL: ${JOB_GOAL}
OBJECTIVE: ${JOB_BRIEF_OBJECTIVE:-}
DELIVERY: ${JOB_BRIEF_DELIVERY:-}
TOOLS: ${JOB_BRIEF_TOOLS:-}
BOUNDS: ${JOB_BRIEF_BOUNDS:-}"

# THE ROW DECIDES THE PERMISSION MODE, AND ONLY THE ROW. A row that carries
# PERMISSION_MODE gets the flag with exactly that value; a row without it gets
# NO flag at all — not a default chosen here. A hardcoded fallback in the
# wrapper would silently overrule every submission and run the whole fleet
# under one policy nobody asked for, which is the same class of lie as
# deciding an outcome [A3].
perm=()
[ -n "${JOB_PERMISSION_MODE:-}" ] && perm=(--permission-mode "$JOB_PERMISSION_MODE")

out="" ; rc=0
out="$(cd "${JOB_WORKDIR:?}" && "$cmd" -p ${thread_flag+"${thread_flag[@]}"} ${perm+"${perm[@]}"} --output-format json "$prompt")" || rc=$?

# THE RUNTIME'S OWN ID SETTLES IT. The final JSON says which session the run
# actually used, and that answer is already in hand — free to read, free to
# compare. A runtime that accepted --session-id and then ran under an id of
# its own would otherwise leave the row pointing at a session holding none of
# the work, and the next attempt would resume that. So when the two disagree
# the row learns the runtime's id, records THREAD_MISMATCH, and says both out
# loud; when they agree, nothing changes.
thread="${JOB_RUNTIME_THREAD:-}"
thread_parse_failed="0"
thread_mismatch=""
actual=""
if command -v jq >/dev/null 2>&1; then
  actual="$(printf '%s' "$out" | jq -r '.session_id // empty' 2>/dev/null)"
fi
if [ -n "$thread" ]; then
  if [ -n "$actual" ] && [ "$actual" != "$thread" ]; then
    echo "job-run: $id ran under thread $actual, but the row named $thread" >&2
    echo "  The row learns the runtime's id; a resume of $thread would find none of the work." >&2
    thread="$actual"
    thread_mismatch="1"
  fi
elif [ -n "$actual" ]; then
  thread="$actual"
elif [ "$rc" -eq 0 ]; then
  thread_parse_failed="1"
fi

jobstate_read "$id"
_jobrun_finalize "$id" "$rc" "$thread" "$thread_parse_failed" "$thread_mismatch"
# _jobrun_finalize only returns on SUCCESS — its own second-failure path
# exits 70 directly, preserving the lease. From here the attempt's bookkeeping
# landed, so release this attempt's lease/heartbeat BEFORE driving the
# reconciler, or _jobreconcile_alive would see this same process as the
# still-live owner and skip straight past the delivery [C2].
kill "$hb" 2>/dev/null; wait "$hb" 2>/dev/null
_jobrun_release_lease
trap - EXIT

# A DRIVER EXISTS [I4]: nothing else calls the reconciler in production, so
# without this a job halts forever at PROCESS=exited / OUTCOME=pending. One
# job then runs start -> run -> reconciled without a human typing
# `steward job reconcile`. A refusal here (e.g. a row this reconcile cannot
# make sense of) is reported and left for a later reconcile — the wrapper
# still decides nothing terminal.
. "$here/lib/jobgit.sh"
. "$here/lib/joboutbox.sh"
. "$here/lib/jobreconcile.sh"
jobreconcile "$id" || echo "job-run: reconcile after finalize reported rc $? for $id — a later reconcile will retry" >&2

exit 0
