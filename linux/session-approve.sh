#!/bin/bash
# linux/session-approve.sh — the ACCEPTANCE CRITERION for a new session, run
# FROM that new session:
#   (d) the first log line shows the DERIVED name
#   (a) the name has a local conf with DOMAIN set
#   (b) a PROVOKED refusal: bus-read with a wrong name gives rc 65 AND says REFUSES
#   (c) one message in each direction — proof received+acknowledged, report sent
#       with a delivery receipt in sent/
#   (e) the session's own loopback listeners inventoried, without root — expected: none
#
# "Done" is the OUTCOME of this script, never an assurance.
#
# The file name stays in the estate's language for now; renaming is one sweep at
# the end of the extraction, not one per file.
set -uo pipefail
BUS_READ="${STEWARD_BUS_READ:-$HOME/bin/bus-read}"
BUS_SEND="${STEWARD_BUS_SEND:-$HOME/bin/bus-send}"

# THE SENDER MUST BE NAMEABLE — CHECKED HERE, BEFORE ANYTHING IS CREATED.
#
# bus-send refuses a sender it cannot name, because the nameless fallback picks
# another session's relay key and the hub stamps the mail with THAT name. This
# script would hit that refusal at its LAST step, after a conf and a key already
# exist — recoverable (the send failure withdraws them) but wasteful, and the
# diagnosis arrives attached to the wrong action.
#
# The check is deliberately WEAKER than bus-send's own: a set TMUX_PANE may
# still be stale. That is the right direction to be wrong in — this gate only
# rejects the case where a name is CERTAINLY underivable, and bus-send remains
# the authority on the rest. Duplicating the real derivation here would be two
# copies to keep in step, which is how a guard drifts away from what it guards.
if [ -z "${BUS_FROM:-}" ] && [ -z "${TMUX_PANE:-}" ]; then
  echo "$(basename "$0"): REFUSES — the sender cannot be named." >&2
  echo "  Not running in tmux and BUS_FROM is unset, so the request to the hub" >&2
  echo "  would be sent under another session's key and stamped with its name." >&2
  echo "  Set BUS_FROM=<your-session-name> and re-run." >&2
  exit 78
fi

# Resolved after the registry loads — the estate owns the session registry.
SESS_D=""

# THE HUB'S NAME COMES FROM THE ESTATE, not from a literal. See session-new.sh for
# the same change and the reason: a product must not carry its owner's namespace
# burned in, and a guessed hub name sends the report to a recipient that does not
# exist — silently, until somebody wonders why the approval never arrived.
# THE LIBRARY IS FOUND IN THE DEPLOYED LAYOUT FIRST, then relative to this
# file. The order is the whole idea: an existing installation must behave exactly as
# before, so the deployed path wins whenever it exists. Only on a machine with
# no deployment — a checkout, a fresh estate — do the siblings apply. The first
# ordering tried was the reverse, and it made a supervisor in a product checkout
# read the PRODUCT tree as its estate: sixty-nine green tests went thirty-six
# red at once, which is exactly what the fixtures are for.
_reg_lib_default() {
  local d c
  d="$(CDPATH= cd -- "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  for c in "$HOME/scripts/lib/registry.sh" "$d/lib/registry.sh" "$d/../lib/registry.sh"; do
    [ -f "$c" ] && { printf '%s' "$c"; return 0; }
  done
  printf '%s' "$HOME/scripts/lib/registry.sh"
}
REG_LIB="${STEWARD_REGISTRY_LIB:-$(_reg_lib_default)}"
if [ -f "$REG_LIB" ]; then
  # shellcheck source=/dev/null
  . "$REG_LIB" 2>/dev/null || { echo "session-approve: REFUSING — registry library could not be read: $REG_LIB" >&2; exit 78; }
else
  echo "session-approve: REFUSING — registry library missing: $REG_LIB" >&2; exit 78
fi
# From the estate's root, not a fixed path — see session-new.sh.
SESS_D="${STEWARD_SESSIONS_D:-$(registry_dir)}"
NAV="$(registry_hub_session)" || exit 78

pass=0; fail=0; RAPPORT=""
rad() { RAPPORT="${RAPPORT}
$1"; }
ja()  { pass=$((pass+1)); rad "PASS  $1"; echo "  PASS  $1"; }
nej() { fail=$((fail+1)); rad "FAIL  $1"; echo "  FAIL  $1"; }

# (d) — the first line, before anything else
NAMN="$(tmux display-message -p -t "${TMUX_PANE:-}" '#S' 2>/dev/null || true)"
echo "session-approve: I am '${NAMN:-<no pane identity>}' (derived from the pane, never from the environment)"
[ -n "$NAMN" ] || { echo "session-approve: FAIL — no pane identity, cannot continue"; exit 1; }

# (a)
if [ -f "$SESS_D/$NAMN.conf" ] && grep -q '^DOMAIN="..*"' "$SESS_D/$NAMN.conf"; then
  ja "conf exists locally and DOMAIN is set"
else
  nej "conf missing or DOMAIN empty for '$NAMN' in $SESS_D"
fi

# (b) — assert BOTH: the code and the text. "REFUSES" IS A TOKEN, not prose:
# bus-read prints it and this line greps for it. Asserting only rc would pass a
# script that refuses for some entirely different reason. The token was in the
# estate's own language until 2026-08-20; renaming it is a coordinated change
# across both files, and the coupling is stated in both.
utd="$("$BUS_READ" prov-fel-namn 2>&1)"; rc=$?
if [ "$rc" -eq 65 ] && printf '%s' "$utd" | grep -q "REFUSES"; then
  ja "a wrong name is refused (rc 65, the text says REFUSES)"
else
  nej "the wrong-name probe gave rc=$rc — the name guard is missing or answers wrongly"
fi

# (c) inbound — read+acknowledge, require ENROLL-PROOF in the archive
ark="$HOME/.config/agent-bus/$NAMN"
"$BUS_READ" "$NAMN" >/dev/null 2>&1 || true
if grep -l "ENROLL-PROOF" "$ark/done/"*.json >/dev/null 2>&1; then
  ja "inbound proven — the hub's ENROLL-PROOF received and acknowledged"
else
  nej "no ENROLL-PROOF in the archive — the hub may not know this name"
fi

# (e) — without root, `ss` shows users: only for one's OWN processes; that is the
# whole idea.
#
# TWO CLASSES, BOTH REPORTED. A bare /users:/ condition counted only listeners
# owned by this uid — and thereby made the most interesting port INVISIBLE.
# Measured 2026-08-17: a debug port with no authentication of its own carried no
# users: field and was silenced, while an ordinary VNC port produced a FAIL.
# Exactly the wrong way round. The criterion is "the session's own loopback
# listeners inventoried" and was READ as "the loopback surface is inventoried" —
# and the latter requires that what cannot be attributed becomes an OPEN
# QUESTION rather than silence.
#
# TWO STEPS AND A DIFFERENCE, not a filter. Two accounts measured the same
# machine at the same instant, 2026-08-17T13:16Z: N=23 loopback listeners in
# BOTH cases, but M=14 attributable for one and M=2 for the other. The SURFACE
# is a property of the MACHINE and countable by anyone without root; it is the
# ATTRIBUTION that is uid-dependent, and it varied by a factor of seven between
# two accounts on the same box. The old /users:/ filter passed a session on 2 of
# 23 and called that an approval — 8.7% of a surface the probe itself could have
# counted.
#
# So: count the whole surface (step 1), count what is attributable (step 2), and
# REPORT THE DIFFERENCE as a number. Then the unknown becomes a measurement
# instead of a void. No port-class narrowing: the whole loopback surface.
#
# THREE LEVELS, NOT TWO. Measured 2026-08-17: the users: field belongs to the
# whole UNIX ACCOUNT, not to the session. On an account running several
# concurrent sessions plus a remote desktop, a fresh session inherits its
# predecessors' ports, so (e) could NEVER pass — the criterion demanded zero of
# something the session does not control.
#   N  the machine's loopback surface   (ss -ltn, no attribution)
#   M  the account's attributable ones  (ss -ltnp, users:)
#   S  the SESSION's own                (M filtered through the pane's process tree)
# The criterion rests on S. N and M are reported as context: numbers the session
# should know but does not answer for.
loop_n="$(ss -ltn 2>/dev/null | awk '/127\.0\.0\.1/ || /\[::1\]/' | grep -c .)"
lyss_konto="$(ss -ltnp 2>/dev/null | awk '(/127\.0\.0\.1/ || /\[::1\]/) && /users:/ {print "    " $4 "  " $NF}')"
loop_m="$(printf '%s' "$lyss_konto" | grep -c . )"
loop_okand=$(( loop_n - loop_m ))

# Does the pid descend from the pane's tree? Walk the parent chain; depth-limited
# so a broken chain cannot hang the probe.
PANE_PID="$(tmux display-message -p -t "${TMUX_PANE:-}" '#{pane_pid}' 2>/dev/null || true)"
min_attling() {
  p="$1"; d=0
  while [ -n "$p" ] && [ "$p" != "1" ] && [ "$d" -lt 24 ]; do
    [ "$p" = "$PANE_PID" ] && return 0
    p="$(ps -o ppid= -p "$p" 2>/dev/null | tr -d ' ')"
    d=$((d+1))
  done
  return 1
}
lyss_egna=""
if [ -n "$PANE_PID" ]; then
  while IFS= read -r rad; do
    [ -n "$rad" ] || continue
    pid="$(printf '%s' "$rad" | sed -n 's/.*pid=\([0-9]*\).*/\1/p')"
    [ -n "$pid" ] || continue
    if min_attling "$pid"; then lyss_egna="$lyss_egna
$rad"; fi
  done <<KONTORADER
$lyss_konto
KONTORADER
fi
loop_s="$(printf '%s' "$lyss_egna" | grep -c . )"
# The numbers carry their timestamp: the surface moves while you measure it (one
# port listened in one measurement and not in the next), so a present-tense
# result cannot be compared against a later one.
echo "  MEASURED $(date -u +%Y-%m-%dT%H:%MZ): loopback N=$loop_n account=$loop_m session=$loop_s (unattributable for this account=$loop_okand)"
if [ "$loop_m" -gt "$loop_s" ]; then
  echo "  THE ACCOUNT'S, NOT THE SESSION'S ($(( loop_m - loop_s ))) — predates this session, reported but not answered for:"
  printf '%s\n' "$lyss_konto" | grep . | while IFS= read -r r; do
    case "$lyss_egna" in *"$r"*) : ;; *) echo "$r" ;; esac
  done
fi
if [ "$loop_okand" -gt 0 ]; then
  echo "  OPEN QUESTION  $loop_okand loopback listener(s) cannot be attributed from this uid."
  echo "                 A listener that is not mine is not THEREBY harmless — it is therefore UNINVESTIGATED."
  echo "                 Requires root or the owner's word; reported, not decided here."
fi
if [ "$loop_s" -eq 0 ]; then
  ja "no listeners started by THIS SESSION (of $loop_n on the machine, $loop_m on the account)"
else
  nej "listeners started by this session — name them or close them:
$lyss_egna"
fi

# (c) outbound — send the report, assert the receipt in sent/
# THE FIRST LINE IS THE ENVELOPE (bus lib: bus_envelope_parse) — bus_send now
# refuses every SEND without one. The GODKANN-RAPPORT v1 line stays unchanged as
# the second line (the suites look for PRESENCE, not position).
#
# A REFUSAL AND A SEND FAILURE ARE NOT THE SAME THING. `2>&1 >/dev/null` is kept
# for the noise, but stderr is CAPTURED rather than discarded: rc 65/78 are THE
# BUS'S OWN GUARDS (a parked subject, a malformed envelope, the secret guard) and
# whoever reads the approval must see WHICH guard said no — not merely "did not
# reach the hub", which blames the network.
#
# THE WIRE FIELD NAMES BELOW ARE DELIBERATELY UNTRANSLATED — they are DATA, read
# verbatim by the receiving end. Renaming them is a protocol change on both sides
# of a live link.
_sanderr="$(mktemp 2>/dev/null)" || _sanderr=""
_sandrc=0
printf 'DRIFT godkannande: %s — %s pass, %s fail\nGODKANN-RAPPORT v1\nnamn=%s\nutfall=%s pass, %s fail%s\n' \
     "$NAMN" "$pass" "$fail" "$NAMN" "$pass" "$fail" "$RAPPORT" \
  | { if [ -n "$_sanderr" ]; then "$BUS_SEND" "$NAV" >/dev/null 2>"$_sanderr"
      else "$BUS_SEND" "$NAV" >/dev/null 2>&1; fi } || _sandrc=$?
if [ "$_sandrc" -eq 0 ]; then
  nyast=""
  for f in $(ls -t "$ark/sent/"*.json 2>/dev/null); do nyast="$f"; break; done
  if [ -n "$nyast" ] && grep -q '"delivered":[[:space:]]*true' "$nyast" 2>/dev/null; then
    echo "  PASS  outbound proven — sent/ carries delivered=true"
  else
    echo "  FAIL  the report has no delivery receipt in sent/"; fail=$((fail+1))
  fi
elif [ "$_sandrc" -eq 65 ] || [ "$_sandrc" -eq 78 ]; then
  echo "  FAIL  the report was REFUSED BY THE BUS'S OWN GUARD (rc $_sandrc) — not by the hub."
  echo "        A parked subject, a malformed envelope or the secret guard. The guard says:"
  [ -n "$_sanderr" ] && sed 's/^/        /' "$_sanderr"
  fail=$((fail+1))
else
  echo "  FAIL  the report did not reach the hub (rc $_sandrc)"; fail=$((fail+1))
fi
[ -n "$_sanderr" ] && rm -f "$_sanderr"

echo "session-approve: $pass pass, $fail fail"
[ "$fail" -eq 0 ]
