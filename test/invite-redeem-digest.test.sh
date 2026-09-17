#!/bin/bash
# test/invite-redeem-digest.test.sh - `invite redeem --digest`, the entry point for
# a caller that never held the token.
#
# WHY IT EXISTS. The Desk validates a request and appends ONE order to a spool for a
# privileged process to act on. That order has to identify the invitation and carry
# no more. The register already stores only the DIGEST, deliberately, so that a
# readable register does not leak an open door - and putting the token back into a
# spool file beside it would undo that decision in a second place: the file would be
# a working invitation, on disk, for as long as the queue is not drained.
#
# ARGUMENT HANDLING ONLY. The twelve privileged steps have their own suite
# (invite-redeem.test.sh) with every host-touching command shimmed; nothing here
# creates an account, mints a key or reaches a network. These are the refusals that
# happen before any of that, and they are reachable with no fixture at all.
set -u
here="$(CDPATH= cd -- "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
pass=0; fail=0
ok()  { pass=$((pass+1)); printf '  ok   %s\n' "$1"; }
bad() { fail=$((fail+1)); printf '  FAIL %s\n     %s\n' "$1" "${2:-}"; }
has() { case "$2" in *"$3"*) ok "$1" ;; *) bad "$1" "missing '$3' in: $2" ;; esac; }
no()  { case "$2" in *"$3"*) bad "$1" "unexpectedly present: '$3'" ;; *) ok "$1" ;; esac; }
S() { bash "$here/bin/steward" invite redeem "$@" 2>&1; }
D64="$(printf 'a%.0s' $(seq 1 64))"
echo "invite-redeem-digest"

echo "== the form is named, not merely refused =="
# A VALUE THAT IS NOT A DIGEST CANNOT MATCH ANY ROW, so without this check the
# lookup answers "no open invitation" - which sends the operator to reissue an
# invitation that was never wrong.
has "a non-hex digest names the shape"      "$(S --digest zz --identity oidc:x)" "64 lowercase hex characters"
has "a short digest names the shape"        "$(S --digest "${D64:0:63}" --identity oidc:x)" "64 lowercase hex"
has "...and says what it got"               "$(S --digest "${D64:0:63}" --identity oidc:x)" "got 63"
has "an uppercase digest is refused"        "$(S --digest "$(printf 'A%.0s' $(seq 1 64))" --identity oidc:x)" "64 lowercase hex"
has "an empty digest is refused"            "$(S --digest '' --identity oidc:x)" "64 lowercase hex"
has "--digest without a value is refused"   "$(S --digest)" "needs a value"

echo "== one token at a time, whichever two ways were combined =="
# EVERY ENTRY POINT MUST SEE EVERY OTHER. Widening one guard and not the rest is how
# a second value arrives past a check that only looked for the first - measured here
# before the fix: --digest followed by a positional token reached --identity.
has "digest then positional"                "$(S --digest "$D64" tok --identity oidc:x)" "one token at a time"
has "digest then --token-file"              "$(S --digest "$D64" --token-file /etc/hostname --identity oidc:x)" "one token at a time"
has "positional then digest"                "$(S tok --digest "$D64" --identity oidc:x)" "one token at a time"
has "digest twice"                          "$(S --digest "$D64" --digest "$D64" --identity oidc:x)" "one token at a time"

echo "== the refusal for nothing at all names every way in =="
# A REFUSAL THAT NAMES A SMALLER SET THAN IT ACCEPTS sends the reader looking for
# something they do not have.
out="$(S --identity oidc:x)"
has "it still says a token is required"     "$out" "a token is required"
has "and names --token-file"                "$out" "--token-file"
has "and stdin"                             "$out" "'-'"
has "and --digest"                          "$out" "--digest"

echo "== a digest gets past argument handling =="
# THE PROOF THAT IT IS AN ENTRY POINT AND NOT ONLY A VALIDATOR: with a well-formed
# digest the command stops complaining about the token and starts complaining about
# what comes next. Without --identity that is the identity; the twelve steps are
# another suite's business.
out="$(S --digest "$D64")"
has "a well-formed digest reaches the next requirement" "$out" "--identity"
no  "and is not itself refused"                         "$out" "a token is required"

# THE CONTROL. A digest must not become a way to skip the identity - the whole point
# of redemption is binding an identity to a row.
out="$(S --digest "$D64" --identity '')"
has "an empty identity is still refused" "$out" "--identity"

printf '\n  %d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
