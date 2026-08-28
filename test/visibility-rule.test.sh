#!/bin/bash
# test/visibility-rule.test.sh — who may see a session, and why.
#
# THE RULE LIVES IN ONE PLACE and this suite is its whole surface. Every branch
# of the precedence table gets a case, including the two that look alike and are
# not: an owner always sees their own session, and a group grant survives a
# `private` that would otherwise withdraw it.
#
# REFUSAL IS THE DEFAULT. An unreadable conf, a missing owner, an entity that
# will not load: all of them answer NO. A registry that cannot be read must
# never become a permit — that is bus/lib.sh's established rule and it holds
# here too.
#
# THIS IS A RENDERING RULE, NOT ACCESS CONTROL. Nothing here prevents anyone
# from reading a conf directly. What it decides is what the tools show and
# offer. No assertion below should be read as a security boundary.
set -u

here="$(CDPATH= cd -- "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
pass=0; fail=0
ok()  { pass=$((pass+1)); printf '  ok   %s\n' "$1"; }
bad() { fail=$((fail+1)); printf '  FAIL %s\n     %s\n' "$1" "${2:-}"; }
yes() { if session_visible_to "$2" "$3" 2>/dev/null; then ok "$1"; else bad "$1" "expected VISIBLE"; fi; }
no()  { if session_visible_to "$2" "$3" 2>/dev/null; then bad "$1" "expected HIDDEN"; else ok "$1"; fi; }

FX="$(mktemp -d)"; trap 'rm -rf "$FX"' EXIT
mkdir -p "$FX/sessions.d" "$FX/entities.d" "$FX/estate"
printf 'LABEL_PREFIX="com.fixture.claude"\nHUB_HOST="h1"\nOP_TOKEN_FILE_NAME="t"\n' \
  > "$FX/estate/steward.conf"

# The entity shapes this rule has to tell apart:
#   team-a     a team both alice and bob work for
#   team-solo  a team only alice works for
#   client-x   a customer of team-a — the one-hop case
#   deep       a customer of client-x — the hop the rule must NOT take
#   board      a group with no sessions of its own
printf 'NAME="Team A"\nMEMBERS="alice bob"\n'   > "$FX/entities.d/team-a.conf"
printf 'NAME="Team Solo"\nMEMBERS="alice"\n'    > "$FX/entities.d/team-solo.conf"
printf 'NAME="Client X"\nMANAGED_BY="team-a"\n' > "$FX/entities.d/client-x.conf"
printf 'NAME="Deep"\nMANAGED_BY="client-x"\n'   > "$FX/entities.d/deep.conf"
printf 'NAME="Board"\nMEMBERS="alice carol"\n'  > "$FX/entities.d/board.conf"

sess() { # <name> <owner> <domain> [extra]
  printf 'HOST="h1"\nOWNER="%s"\nDOMAIN="%s"\nRC_LABEL="L"\nREPO_PATH="/tmp/x"\nID="%s"\n%b' \
    "$2" "$3" "$1" "${4:-}" > "$FX/sessions.d/$1.conf"
}
sess own      alice team-a
sess shared   bob   team-a
sess solo     alice team-solo
sess client   bob   client-x
sess distant  bob   deep
sess hidden   bob   team-a  'VISIBILITY="private"\n'
sess granted  bob   team-a  'VISIBILITY="private"\nVISIBLE_TO="board"\n'
sess orphan   bob   nosuch-entity

export STEWARD_REGISTRY_DIR="$FX/sessions.d" STEWARD_ESTATE_ROOT="$FX"
# shellcheck source=/dev/null
. "$here/lib/visibility.sh"

echo "== the owner always sees their own =="
yes "alice sees her own session"                 alice own
yes "even when it is private"                    bob   hidden

echo "== the derived team view =="
yes "a teammate sees a shared session"           alice shared
no  "a stranger does not"                        carol shared
no  "a teammate of a DIFFERENT team does not"    bob   solo

echo "== one hop up MANAGED_BY, and only one =="
yes "a member of the managing team sees the customer's session" alice client
# THE SECOND HOP IS NOT TAKEN, deliberately. registry_entity_load follows the
# MANAGED_BY chain with cycle detection, but visibility does not: a customer of
# a customer is not the same work, and a rule that walked the chain would grant
# an ever-widening circle nobody declared.
no  "but not a customer of a customer"           alice distant

echo "== private withdraws the derived view =="
no  "a teammate no longer sees a private session" alice hidden

# THE ORDER MATTERS HERE. A board session sets BOTH fields: private to withdraw
# it from the team, and a grant to hand it to the group. If `private` were
# checked first the grant would never fire, and the field pair would be useless
# in exactly the case it exists for.
echo "== but a group grant survives private =="
yes "a board member sees a granted private session" carol granted
no  "someone outside the group still does not"      dave  granted

echo "== a grant does not widen beyond its members =="
sess narrow bob team-solo 'VISIBLE_TO="board"\n'
yes "a board member sees it through the grant" carol narrow
no  "a non-member with no other claim does not" dave  narrow

echo "== refusal is the default =="
no  "an unknown session is not visible"          alice does-not-exist
no  "a session whose entity does not exist"      alice orphan
printf 'HOST="h1"\nDOMAIN="team-a"\nRC_LABEL="L"\nREPO_PATH="/tmp/x"\nID="noowner"\n' \
  > "$FX/sessions.d/noowner.conf"
no  "a session with no readable owner"           alice noowner

# AN EMPTY VIEWER IS NOT A WILDCARD. A caller that failed to determine who is
# asking must get NO, not everything.
echo "== an empty viewer is refused, not treated as everyone =="
no  "empty viewer sees nothing"                  "" own

echo
printf 'pass=%s fail=%s\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
