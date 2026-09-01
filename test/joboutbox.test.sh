#!/bin/bash
# test/joboutbox.test.sh — the idempotent terminal notice.
#
# ARTIFACT, RECEIPT-STATE AND NOTICE ARE THREE CRASH POINTS [A2]. A crash
# after delivery but before the notice must not lose the notice, and a crash
# after the notice but before the sent-marker must not DUPLICATE it silently:
# the event id is deterministic (job + version), enqueue is create-if-absent,
# and the message carries its own event id so the receiver can dedupe.
# Delivery is at-least-once BY DESIGN — the honest guarantee, stated, beats a
# fake exactly-once.
set -u
pass=0; fail=0
ok()  { pass=$((pass+1)); printf '  ok   %s\n' "$1"; }
bad() { fail=$((fail+1)); printf '  FAIL %s\n     %s\n' "$1" "${2:-}"; }
here="$(CDPATH= cd -- "$(dirname "$0")" && pwd)"
. "$here/../lib/joboutbox.sh"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
export STEWARD_JOB_STATE_HOME="$T/jobs"
id="j-00000000000000cd"; mkdir -p "$T/jobs/$id/outbox"

# The injected sender APPENDS to a log so a duplicate send is visible.
cat > "$T/sender" <<'EOF'
#!/bin/bash
printf '%s\n---\n' "$2" >> "${SENDLOG:?}"
EOF
chmod +x "$T/sender"
export JOBOUTBOX_SEND="$T/sender" SENDLOG="$T/sendlog"

joboutbox_enqueue "$id" 3 "job done, delivery abc123" && ok "enqueue: rc 0" || bad "enqueue failed"
[ -f "$T/jobs/$id/outbox/job-$id-terminal-v3.pending" ] && ok "enqueue: pending file at deterministic id" || bad "no pending file"
joboutbox_enqueue "$id" 3 "job done, DIFFERENT text" && ok "enqueue: same event id is a no-op (rc 0)" || bad "re-enqueue errored"
[ "$(ls "$T/jobs/$id/outbox" | wc -l | tr -d ' ')" = "1" ] && ok "enqueue: no second file" || bad "duplicate event file"

joboutbox_drain "$id" && ok "drain: rc 0" || bad "drain failed"
[ -f "$T/jobs/$id/outbox/job-$id-terminal-v3.sent" ] && ok "drain: pending became sent" || bad "no sent marker"
grep -q "event: job-$id-terminal-v3" "$T/sendlog" && ok "message carries its event id" || bad "no event id in message"
n1="$(grep -c '^---$' "$T/sendlog")"
joboutbox_drain "$id"
[ "$(grep -c '^---$' "$T/sendlog")" = "$n1" ] && ok "drain: second drain sends nothing" || bad "duplicate send"

# A failing sender leaves the pending file for the next drain.
joboutbox_enqueue "$id" 4 "second terminal (retry path)"
JOBOUTBOX_SEND=/bin/false joboutbox_drain "$id" 2>/dev/null
[ -f "$T/jobs/$id/outbox/job-$id-terminal-v4.pending" ] && ok "failed send keeps pending" || bad "pending lost on failure"
joboutbox_drain "$id"
[ -f "$T/jobs/$id/outbox/job-$id-terminal-v4.sent" ] && ok "redrain delivers it" || bad "redrain failed"

# Re-enqueue an already-sent event (v3 was drained earlier, now has .sent marker).
joboutbox_enqueue "$id" 3 "attempting to re-enqueue already-sent event" && ok "re-enqueue sent: rc 0" || bad "re-enqueue sent failed"
[ ! -f "$T/jobs/$id/outbox/job-$id-terminal-v3.pending" ] && ok "re-enqueue sent: no pending file created" || bad "pending file reappeared"
[ -f "$T/jobs/$id/outbox/job-$id-terminal-v3.sent" ] && ok "re-enqueue sent: marker preserved" || bad ".sent file lost"

printf 'pass=%d fail=%d\n' "$pass" "$fail"
[ "$fail" -eq 0 ] || exit 1
