#!/bin/bash
# lib/joboutbox.sh — the transactional outbox for terminal notices.
#
# THE BUS IS A NOTICE, NEVER A SOURCE OF TRUTH [A2]. The notice must survive
# a crash after delivery (the pending file IS the intent, durable on disk)
# and must not silently duplicate after a crash between send and marker. The
# event id is deterministic — job:<id>:terminal:<version> — so enqueue is
# create-if-absent and every resend carries the SAME id. The guarantee is
# at-least-once; the receiver dedupes on the id printed in the message. An
# honest at-least-once, stated, beats a pretended exactly-once.
#
# joboutbox_drain PRINTS THE EVENT ID OF EVERY SEND IT ACTUALLY COMPLETED,
# one per line, on stdout. Its rc is a summary (0 iff every pending event in
# this job's outbox sent); the printed ids are the precise answer to "did
# THIS event go out" — a caller with more than one pending file (a crash
# between two terminal versions) must not read a nonzero rc as "nothing
# sent" when its own event id is in fact on the list [I2].

_joboutbox_dir() {
  local home; home="$(jobstate_home 2>/dev/null)" || home="${STEWARD_JOB_STATE_HOME:?}"
  printf '%s/%s/outbox\n' "$home" "$1"
}

joboutbox_enqueue() {
  local id="$1" version="$2" text="$3" dir eid
  dir="$(_joboutbox_dir "$id")"; eid="job-$id-terminal-v$version"
  mkdir -p "$dir"
  # Create-if-absent across BOTH states: a sent event must never be re-minted.
  if [ -e "$dir/$eid.pending" ] || [ -e "$dir/$eid.sent" ]; then return 0; fi
  printf '%s\nevent: %s\n' "$text" "$eid" > "$dir/$eid.tmp.$$" && mv "$dir/$eid.tmp.$$" "$dir/$eid.pending"
}

joboutbox_drain() {
  local id="$1" dir f eid rc=0
  # Explicit path, not a bare name trusted to PATH — a headless job's shell
  # may not have the operator's PATH at all.
  local send="${JOBOUTBOX_SEND:-${STEWARD_BUS_SEND:-$HOME/bin/bus-send}}"
  dir="$(_joboutbox_dir "$id")"
  for f in "$dir"/*.pending; do
    [ -e "$f" ] || continue
    eid="$(basename "$f" .pending)"
    if "$send" "${JOBOUTBOX_TO:-hub}" "$(cat "$f")"; then
      mv "$f" "$dir/$eid.sent"
      printf '%s\n' "$eid"
    else
      echo "joboutbox: send failed for $eid — kept pending for the next drain" >&2
      rc=1
    fi
  done
  return "$rc"
}
