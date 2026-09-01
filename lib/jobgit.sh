#!/bin/bash
# lib/jobgit.sh — the job-owned checkout and the pinned delivery.
#
# THE JOB NEVER BORROWS THE SUBMITTER'S CHECKOUT [A1]. It clones from the
# submitter's ORIGIN, works on a branch keyed on the full immutable job id,
# and its delivery survives the submitter switching branches, moving the
# clone, or leaving it dirty. Retries reuse the same workdir; they never
# mint new branches.
#
# DELIVERY IS COMPARE-AND-SWAP. The push states which remote SHA it expects
# (--force-with-lease with an EXPLICIT expectation — the bare flag trusts a
# possibly stale local remote-ref and would overwrite an unseen move). An
# unexpected movement is a provenance conflict, rc 75, and both commits
# survive for a human to look at. Plain --force appears nowhere in this file.

jobgit_branch() {
  local id="${1:-}"
  case "$id" in j-????????????????) ;; *) echo "jobgit: bad id '$id'" >&2; return 64 ;; esac
  printf 'steward/jobs/%s/delivery\n' "$id"
}

jobgit_checkout() {
  local id="$1" src="$2" work="$3" branch origin base
  branch="$(jobgit_branch "$id")" || return $?
  origin="$(git -C "$src" remote get-url origin 2>/dev/null)" || {
    echo "jobgit: $src has no origin remote — a delivery needs somewhere to land" >&2; return 65; }
  git clone -q "$origin" "$work" || return 65
  base="$(git -C "$work" rev-parse HEAD)" || return 65
  git -C "$work" checkout -qb "$branch" "$base" || return 65
  printf 'BASE_SHA=%s\n' "$base"
}

jobgit_deliver() {
  local id="$1" work="$2" expected="${3:-}" branch sha
  branch="$(jobgit_branch "$id")" || return $?
  jobgit_push_guard "$id" "refs/heads/$branch" || return $?
  sha="$(git -C "$work" rev-parse "refs/heads/$branch")" || return 65
  if ! git -C "$work" push -q --force-with-lease="refs/heads/$branch:$expected" \
        origin "refs/heads/$branch:refs/heads/$branch" 2>/dev/null; then
    echo "jobgit: remote $branch is not at '${expected:-<absent>}' — provenance conflict, not forcing" >&2
    return 75
  fi
  printf 'DELIVERY_SHA=%s\n' "$sha"
}

# The receipt verifies the EXACT remote tip. "The branch exists" would accept
# yesterday's delivery as today's.
jobgit_receipt() {
  local id="$1" work="$2" want="$3" branch have
  branch="$(jobgit_branch "$id")" || return $?
  have="$(git -C "$work" ls-remote origin "refs/heads/$branch" | cut -f1)"
  [ -n "$have" ] || { echo "jobgit: no remote ref for $branch" >&2; return 65; }
  [ "$have" = "$want" ] || { echo "jobgit: remote tip $have != delivered $want" >&2; return 65; }
}

# The job pushes ONLY its own namespace: never main, never tags, never another
# job's refs. The guard is called by deliver and by anything else that pushes.
jobgit_push_guard() {
  local id="$1"; shift
  local ref
  for ref in "$@"; do
    case "$ref" in
      refs/heads/steward/jobs/$id/*) ;;
      *) echo "jobgit: REFUSES push of $ref — outside steward/jobs/$id/" >&2; return 65 ;;
    esac
  done
}
