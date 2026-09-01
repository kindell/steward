#!/bin/bash
# lib/jobschema.sh — the submission gate: no judge, no boundaries, no job.
#
# THE CHECK IS RUN, NEVER JUDGED. Without a near-perfect verifier the workers
# solve the wrong problem [R 3.6]; without the four brief fields they
# duplicate work and wander [R 2.1]. Both failure classes happen BEFORE the
# run, which is why this gate sits at submission and not at delivery.
#
# EVERY defect is named in ONE refusal: a submitter who is told about one
# missing field per attempt stops attempting.

jobschema_validate() {
  local missing=""
  [ -n "${SUBMIT_GOAL:-}" ]            || missing="$missing GOAL"
  [ -n "${SUBMIT_CHECK_CMD:-}" ]       || missing="$missing CHECK_CMD"
  [ -n "${SUBMIT_CHECK_EXPECT:-}" ]    || missing="$missing CHECK_EXPECT"
  [ -n "${SUBMIT_BRIEF_OBJECTIVE:-}" ] || missing="$missing BRIEF_OBJECTIVE"
  [ -n "${SUBMIT_BRIEF_DELIVERY:-}" ]  || missing="$missing BRIEF_DELIVERY"
  [ -n "${SUBMIT_BRIEF_TOOLS:-}" ]     || missing="$missing BRIEF_TOOLS"
  [ -n "${SUBMIT_BRIEF_BOUNDS:-}" ]    || missing="$missing BRIEF_BOUNDS"
  if [ -z "${SUBMIT_REPO:-}" ] && [ -z "${SUBMIT_DELIVERY_GLOB:-}" ]; then
    missing="$missing REPO-or-DELIVERY_GLOB"
  fi
  if [ -n "${SUBMIT_REPO:-}" ] && ! git -C "$SUBMIT_REPO" rev-parse --git-dir >/dev/null 2>&1; then
    missing="$missing REPO(not-a-git-checkout)"
  fi
  if [ -n "$missing" ]; then
    echo "jobschema: REFUSES — submission incomplete. Missing or broken:$missing" >&2
    echo "  A job without an executable check solves the wrong problem; a brief" >&2
    echo "  without boundaries duplicates work. Fill every named field and resubmit." >&2
    return 65
  fi
  return 0
}
