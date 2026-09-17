#!/bin/bash
# desk/apply.sh - the privileged half of the order spool.
#
# THE SERVER WRITES ORDERS AND NEVER ACTS ON THEM. It is a read-only view on a
# socket; it cannot create a unix account, mint a key or write another home's
# authorized_keys. This runs in the steward account, reads what the server wrote, and
# is the only thing that acts.
#
# ─────────────────────────────────────────────────────────────────────────────
# FOUR THINGS IN A TRANSACTION THAT IS NOT A TRANSACTION, and the order is the whole
# design. There is no way to pick an order, run a verb, write a receipt and refresh a
# snapshot atomically, so every step is placed where a crash between it and the next
# one leaves a state somebody can read correctly.
#
#   1. RECEIPT state=running IS WRITTEN BEFORE THE VERB RUNS. A crash during the verb
#      then leaves `running` on disk, which is distinguishable from `never started`.
#      Written after, a crash would be indistinguishable from an order nobody picked
#      up - and the page would say queued forever while the work had already half
#      happened.
#
#   2. THE ORDER FILE IS MOVED OUT LAST, after the receipt is final. Removed first, a
#      crash loses the order and nobody knows what was asked for. Moved last, a crash
#      means the order is picked up again.
#
#   3. SO RE-RUNNING MUST BE SAFE, and that is a REQUIREMENT ON ACTIONS rather than a
#      hope about crashes. `invite redeem` satisfies it by design - the services spec:
#      "a step that fails leaves the earlier receipts in place and exits non-zero;
#      re-running continues from the first step that has not left its mark." An action
#      that cannot say that about itself does not belong in the table below.
#
#   4. THE SNAPSHOT IS TRIGGERED AFTER THE RECEIPT IS FINAL, because the snapshot is
#      how the page learns what happened. Triggered before, the page would show the
#      order still running and not refresh again until something else moved.
#
# OLDEST FIRST, BY FILENAME. Order ids are ULID-shaped, so a plain sort is time order
# and this reads the queue off the directory without parsing anything.
set -u

HERE="$(CDPATH= cd -- "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# THE SECRET GUARD IS THE BUS'S, EXTRACTED AND NOT REIMPLEMENTED. A verb's output can
# carry a provider link, and a provider link is a one-time credential; a second
# implementation of "what looks like a secret" is a second answer that ages
# separately. Extraction is the same technique test/bus-secret-guard.test.sh uses.
_apply_load_guard() {
  local src="$HERE/linux/bus-send"
  [ -r "$src" ] || return 1
  eval "$(sed -n '/^_BUS_SECRET_NOUNS=/p; /^bus_secret_guard() {/,/^}/p' "$src")" 2>/dev/null
  command -v bus_secret_guard >/dev/null 2>&1
}

# THE ACTION TABLE IS DATA. Adding an action is one row; the loop below knows nothing
# about any of them. STEWARD_DESK_APPLY_VERB overrides the command for a suite - it is
# not a test-only knob in the sense the constraints forbid, it is the same door an
# operator has when the product tree is not on PATH.
_apply_command_for() { # <action> -> the argv to run, or rc 1
  case "$1" in
    invite-redeem) printf '%s\n' "${STEWARD_DESK_APPLY_VERB:-$HERE/bin/steward}" invite redeem ;;
    *) return 1 ;;
  esac
}

_apply_args_for() { # <action> <order file> -> extra argv from the order's args
  case "$1" in
    invite-redeem)
      # THE ORDER CARRIES A DIGEST AND NEVER A TOKEN. The register stores only the
      # digest so a readable register does not leak an open door; an order carrying
      # the token would undo that decision in a second place, and the file would be a
      # working invitation on disk for as long as the queue is not drained.
      printf '%s\n' --digest "$(jq -r '.args.digest // empty' "$2")" \
                    --identity "$(jq -r '.args.identity // empty' "$2")" ;;
  esac
}

usage() { echo "usage: steward desk apply [--once]" >&2; exit 64; }

ONCE=""
while [ $# -gt 0 ]; do
  case "$1" in
    --once) ONCE=1; shift ;;
    -h|--help) usage ;;
    *) echo "steward desk apply: unknown argument '$1'" >&2; exit 64 ;;
  esac
done

DIR="$(bash "$HERE/desk/bin/desk-paths" 2>/dev/null | sed -n 's/^dir=//p' | head -1)"
[ -n "$DIR" ] || { echo "steward desk apply: desk-paths named no directory" >&2; exit 78; }
ORDERS="$DIR/orders"
DONE_DIR="$DIR/orders-done"

# NO ORDERS IS NOT AN ERROR AND IT SAYS SO. A path unit fires on a directory that may
# already have been drained by a previous run; silence would be indistinguishable
# from a run that could not read the spool.
if [ ! -d "$ORDERS" ]; then
  echo "steward desk apply: no spool at $ORDERS - nothing to do" >&2
  exit 0
fi

_apply_load_guard || { echo "steward desk apply: the secret guard could not be loaded from linux/bus-send - refusing rather than writing unscrubbed output" >&2; exit 78; }

mkdir -p "$DONE_DIR" 2>/dev/null || { echo "steward desk apply: cannot create $DONE_DIR" >&2; exit 73; }
chmod 700 "$DIR" "$ORDERS" "$DONE_DIR" 2>/dev/null || true

applied=0; failed=0
for f in "$ORDERS"/*.json; do
  [ -e "$f" ] || continue
  id="$(basename "$f" .json)"
  action="$(jq -r '.action // empty' "$f" 2>/dev/null)"
  principal="$(jq -r '.principal // empty' "$f" 2>/dev/null)"
  receipt="$DIR/$id.receipt.json"

  if [ -z "$action" ] || [ -z "$principal" ]; then
    # A MALFORMED ORDER IS MOVED ASIDE WITH A RECEIPT, not left to be retried forever.
    # The server is the only writer of this directory, so a file it cannot parse is a
    # defect worth seeing rather than a queue that never drains.
    jq -n --arg at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
      '{state:"failed",at:$at,lines:["the order could not be read: no action or no principal"]}' > "$receipt" 2>/dev/null
    mv -f "$f" "$DONE_DIR/" 2>/dev/null || true
    failed=$((failed+1))
    continue
  fi

  # NO mapfile, AND NO BARE EXPANSION OF A POSSIBLY-EMPTY ARRAY. macOS ships bash
  # 3.2.57 and always will - Apple stopped following bash at the licence change - and
  # that shell has neither. This file was written with both and went red on the
  # neighbour's darwin half: 5 passed, 20 failed, all twenty downstream of the first.
  #
  # THE HOUSE ALREADY KNEW. linux/hub/lib.sh carries the same note for the same two
  # reasons, and test/deploy-policy.test.sh forbids mapfile outright - on two named
  # files, which is why it did not catch this one. The rule was written; the
  # enforcement was a hand-kept list that does not grow with the tree.
  #
  # A COUNTER RATHER THAN ${#cmd[@]}, AND THE FIRST VERSION OF THIS COMMENT GAVE THE
  # WRONG REASON FOR IT. It said a counter "cannot be an unbound expansion", which
  # reads as though ${#cmd[@]} would be one on 3.2. Measured on bash 3.2.57:
  #
  #   set -u; c=();  echo "${#c[@]}"   ->  0                       declared, empty
  #   set -u;        echo "${#b[@]}"   ->  b: unbound variable      never assigned
  #   set -u; c=();  printf '%s' "${c[@]}"  ->  c[@]: unbound variable
  #
  # SO THE LINE IS DECLARED vs UNDECLARED, not empty vs non-empty, and counting is
  # safe as long as the array is ASSIGNED - the assignment is what makes it a
  # variable and the emptiness is irrelevant. Only "${arr[@]}" is unsafe on a
  # declared-empty array. Both forms here always assign, so the counter is more
  # conservative than required rather than necessary.
  #
  # IT STAYS ANYWAY, and the reason is not inertia: the two cases coincide in every
  # branch except the one where the assignment is skipped, and THAT is the branch a
  # reader consults a comment about. A counter cannot acquire that branch. The
  # comment is what needed narrowing - a wrong reason beside right code is the thing
  # the next reader builds on.
  cmd=(); cmd_n=0
  while IFS= read -r _line; do cmd[$cmd_n]="$_line"; cmd_n=$((cmd_n+1)); done < <(_apply_command_for "$action")
  if [ "$cmd_n" -eq 0 ]; then
    jq -n --arg at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" --arg a "$action" \
      '{state:"failed",at:$at,lines:[("no recipe for action " + $a)]}' > "$receipt"
    mv -f "$f" "$DONE_DIR/" 2>/dev/null || true
    failed=$((failed+1))
    continue
  fi
  extra=(); extra_n=0
  while IFS= read -r _line; do extra[$extra_n]="$_line"; extra_n=$((extra_n+1)); done < <(_apply_args_for "$action" "$f")

  # (1) RUNNING BEFORE THE VERB.
  jq -n --arg at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" '{state:"running",at:$at,lines:[]}' > "$receipt"

  # THE EMPTY CASE IS BRANCHED, NOT EXPANDED. `_apply_args_for` names one action, so
  # FIVE OF THE SIX carry no extra argv at all - and on bash 3.2 under `set -u`,
  # "${extra[@]}" on an empty array is an unbound-variable error, not an empty word
  # list. Fixing only the mapfile above would have moved the darwin failure from one
  # action to five without changing the number of red lines much.
  if [ "$extra_n" -eq 0 ]; then
    out="$("${cmd[@]}" 2>&1)"; rc=$?
  else
    out="$("${cmd[@]}" "${extra[@]}" 2>&1)"; rc=$?
  fi

  # THE GUARD REFUSES, IT DOES NOT REDACT, and the receipt is built around that.
  #
  # I first wrote this as `clean=$(bus_secret_guard "$out")` on the assumption that it
  # returns scrubbed text. It does not: it prints nothing, exits 0 when the text is
  # clean, and exits 65 with a reason on stderr when a line carries a known secret
  # shape. The assumption produced a receipt with EMPTY lines and a test that passed
  # for the wrong reason - "the secret is not in the receipt" was true because
  # everything was gone, not because anything was withheld.
  #
  # WITHHOLDING IS ALSO THE RIGHT ANSWER, not merely the available one. The services
  # spec says no token, secret or credential ever enters a receipt; a redactor that
  # gets it wrong writes the secret, while a refusal that gets it wrong writes too
  # little. The two failure directions are not comparable.
  guard_err="$(bus_secret_guard "$out" 2>&1 >/dev/null)"; guard_rc=$?
  if [ "$guard_rc" -ne 0 ]; then
    # THE GUARD'S OWN WORDS, not a summary of them: it names which line and which
    # family, and an operator who cannot see the output needs that to know what to
    # look at in the verb's own log.
    lines="the verb's output is withheld: it carries something the secret guard refuses
$guard_err"
  else
    lines="$out"
  fi

  state=done; [ "$rc" -eq 0 ] || { state=failed; failed=$((failed+1)); }
  [ "$rc" -eq 0 ] && applied=$((applied+1))

  # (2) FINAL RECEIPT, THEN (3) THE ORDER MOVES, THEN (4) THE SNAPSHOT.
  jq -n --arg at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" --arg s "$state" --argjson rc "$rc" \
        --arg lines "$lines" \
    '{state:$s,at:$at,rc:$rc,lines:($lines|split("\n"))}' > "$receipt"
  mv -f "$f" "$DONE_DIR/" 2>/dev/null || true
  bash "$HERE/bin/steward" desk snapshot >/dev/null 2>&1 || true

  [ -n "$ONCE" ] && break
done

echo "steward desk apply: applied=$applied failed=$failed"
[ "$failed" -eq 0 ]
