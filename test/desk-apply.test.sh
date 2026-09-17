#!/bin/bash
# test/desk-apply.test.sh - the privileged half of the order spool.
#
# FOUR THINGS IN A TRANSACTION THAT IS NOT A TRANSACTION, and the order is what this
# suite is about. There is no way to pick an order, run a verb, write a receipt and
# refresh a snapshot atomically, so each step is placed where a crash between it and
# the next leaves a state somebody can read correctly. A test that only checked the
# happy path would pass on every wrong ordering.
#
# THE VERB IS A SHIM. Nothing here creates an account, mints a key or reaches a
# network - STEWARD_DESK_APPLY_VERB points at a script that records its argv and
# returns what the case wants.
set -u
here="$(CDPATH= cd -- "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
pass=0; fail=0
ok()  { pass=$((pass+1)); printf '  ok   %s\n' "$1"; }
bad() { fail=$((fail+1)); printf '  FAIL %s\n     %s\n' "$1" "${2:-}"; }
is()  { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "wanted '$3', got '$2'"; fi; }
has() { case "$2" in *"$3"*) ok "$1" ;; *) bad "$1" "missing '$3' in: $2" ;; esac; }
no()  { case "$2" in *"$3"*) bad "$1" "unexpectedly present: '$3'" ;; *) ok "$1" ;; esac; }
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
echo "desk-apply"

DESK="$T/desk"; mkdir -p "$DESK/orders"
# desk-paths is asked for the directory, so a stub answers for it.
mkdir -p "$T/fake/desk/bin" "$T/fake/bin" "$T/fake/linux"
printf '#!/bin/bash\necho "dir=%s"\necho "sock=%s/desk.sock"\n' "$DESK" "$DESK" > "$T/fake/desk/bin/desk-paths"
cp "$here/desk/apply.sh" "$T/fake/desk/apply.sh"
cp "$here/linux/bus-send" "$T/fake/linux/bus-send"
printf '#!/bin/bash\n[ "$1" = desk ] && [ "$2" = snapshot ] && { echo "snapshot" >> "%s/calls"; exit 0; }\nexit 0\n' "$T" > "$T/fake/bin/steward"
chmod 755 "$T/fake/desk/bin/desk-paths" "$T/fake/bin/steward"

order() { # <id> <action> [digest] [identity]
  printf '{"id":"%s","principal":"alice","action":"%s","args":{"digest":"%s","identity":"%s"},"at":1,"origin":"tailnet"}\n' \
    "$1" "$2" "${3:-}" "${4:-}" > "$DESK/orders/$1.json"
}
verb() { printf '#!/bin/bash\necho "$@" >> "%s/argv"\n%s\n' "$T" "$1" > "$T/verb"; chmod 755 "$T/verb"; }
run() { OUT="$(STEWARD_DESK_APPLY_VERB="$T/verb" bash "$T/fake/desk/apply.sh" "$@" 2>&1)"; RC=$?; }

echo "== oldest first, by filename =="
# ORDER IDS ARE ULID-SHAPED so a plain sort is time order. This is what lets apply
# read the queue off the directory without parsing anything.
verb 'exit 0'
order 01AAAAAAAAAAAAAAAAAAAAAAAA invite-redeem d1 oidc:a
order 01BBBBBBBBBBBBBBBBBBBBBBBB invite-redeem d2 oidc:b
run
is  "both applied"            "$(grep -c . "$T/argv")" "2"
is  "the older one ran first" "$(head -1 "$T/argv" | grep -o 'd1')" "d1"

echo "== a receipt is final and names the state =="
is  "rc 0 when every order succeeded" "$RC" "0"
has "the summary counts them"         "$OUT" "applied=2 failed=0"
is  "state is done"  "$(jq -r .state "$DESK/01AAAAAAAAAAAAAAAAAAAAAAAA.receipt.json")" "done"
is  "and carries rc" "$(jq -r .rc    "$DESK/01AAAAAAAAAAAAAAAAAAAAAAAA.receipt.json")" "0"

echo "== the order is moved out, not deleted =="
# REMOVED, A CRASH LOSES WHAT WAS ASKED FOR. Moved, it can still be read.
is  "the spool is drained"        "$(ls "$DESK/orders" | wc -l | tr -d ' ')" "0"
is  "and the orders are kept"     "$(ls "$DESK/orders-done" | wc -l | tr -d ' ')" "2"

echo "== running is written BEFORE the verb, which is how a crash is readable =="
# THE POINT OF THE WHOLE ORDERING. A verb that never returns must leave `running` on
# disk - written after, a crash would be indistinguishable from an order nobody
# picked up, and the page would say queued forever while the work had half happened.
rm -f "$DESK"/*.receipt.json "$DESK/orders-done"/*.json "$T/argv"
order 01CCCCCCCCCCCCCCCCCCCCCCCC invite-redeem d3 oidc:c
printf '#!/bin/bash\ncat "%s/01CCCCCCCCCCCCCCCCCCCCCCCC.receipt.json" > "%s/seen"\nexit 0\n' "$DESK" "$T" > "$T/verb"; chmod 755 "$T/verb"
run
is  "the verb saw a receipt already on disk" "$(jq -r .state "$T/seen" 2>/dev/null)" "running"

echo "== a failing verb is failed, not silently done =="
rm -f "$DESK"/*.receipt.json
order 01DDDDDDDDDDDDDDDDDDDDDDDD invite-redeem d4 oidc:d
verb 'echo "it went wrong"; exit 65'
run
is  "state is failed"            "$(jq -r .state "$DESK/01DDDDDDDDDDDDDDDDDDDDDDDD.receipt.json")" "failed"
is  "the verb rc is kept"        "$(jq -r .rc    "$DESK/01DDDDDDDDDDDDDDDDDDDDDDDD.receipt.json")" "65"
has "the output is in the lines" "$(jq -r '.lines|join(" ")' "$DESK/01DDDDDDDDDDDDDDDDDDDDDDDD.receipt.json")" "it went wrong"
is  "and apply says so"          "$RC" "1"

echo "== a refused output is WITHHELD, and the refusal is named =="
# THE GUARD REFUSES, IT DOES NOT REDACT. The first draft of this suite asserted "the
# secret is not in the receipt" against a version that treated the guard as a
# scrubber - and it PASSED, because the assumption emptied every receipt. A green
# assertion that is green because everything disappeared is the same family as a
# green suite that measured the wrong control. The control below is what makes this
# one mean something.
rm -f "$DESK"/*.receipt.json
order 01EEEEEEEEEEEEEEEEEEEEEEEE invite-redeem d5 oidc:e
verb 'echo "ghp_aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"; exit 0'
run
R="$(cat "$DESK/01EEEEEEEEEEEEEEEEEEEEEEEE.receipt.json")"
no  "the secret is not in the receipt"   "$R" "ghp_aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
has "and the receipt says it was withheld" "$R" "withheld"
has "with the guard's own reason"          "$R" "secret prefix"

# THE CONTROL, AND IT IS THE POINT. Without it, a version that wrote nothing at all
# would satisfy every assertion above - which is exactly what the first draft did.
rm -f "$DESK"/*.receipt.json
order 01HHHHHHHHHHHHHHHHHHHHHHHH invite-redeem d6 oidc:f
verb 'echo "ordinary output"; exit 0'
run
has "clean output IS carried into the receipt" "$(jq -r '.lines|join(" ")' "$DESK/01HHHHHHHHHHHHHHHHHHHHHHHH.receipt.json")" "ordinary output"
no  "and it is not marked withheld"            "$(cat "$DESK/01HHHHHHHHHHHHHHHHHHHHHHHH.receipt.json")" "withheld"

echo "== an unknown action fails with a named reason and does not block the queue =="
# A QUEUE THAT NEVER DRAINS IS WORSE THAN A FAILED ORDER: the next order never runs,
# and the page shows both as queued.
rm -f "$DESK"/*.receipt.json
order 01FFFFFFFFFFFFFFFFFFFFFFFF rm-rf
verb 'exit 0'
run
is  "state is failed"        "$(jq -r .state "$DESK/01FFFFFFFFFFFFFFFFFFFFFFFF.receipt.json")" "failed"
has "and names the action"   "$(jq -r '.lines|join(" ")' "$DESK/01FFFFFFFFFFFFFFFFFFFFFFFF.receipt.json")" "rm-rf"
is  "the spool still drained" "$(ls "$DESK/orders" | wc -l | tr -d ' ')" "0"

echo "== a malformed order is moved aside with a receipt =="
rm -f "$DESK"/*.receipt.json
printf 'not json at all\n' > "$DESK/orders/01GGGGGGGGGGGGGGGGGGGGGGGG.json"
run
is  "state is failed"         "$(jq -r .state "$DESK/01GGGGGGGGGGGGGGGGGGGGGGGG.receipt.json")" "failed"
is  "and it left the spool"   "$(ls "$DESK/orders" | wc -l | tr -d ' ')" "0"

echo "== an empty spool is not an error, and says so =="
# A PATH UNIT FIRES ON A DIRECTORY A PREVIOUS RUN MAY HAVE DRAINED. Silence would be
# indistinguishable from a run that could not read the spool at all.
run
is  "rc 0"                  "$RC" "0"
has "and it reports zero"   "$OUT" "applied=0 failed=0"

printf '\n  %d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
