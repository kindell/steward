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
#   audit      a group whose only member is in no other group — so a case that
#              passes only if the loop reaches the SECOND name in a grant
printf 'NAME="Audit"\nMEMBERS="dave"\n'        > "$FX/entities.d/audit.conf"

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

# A GRANT IS A LIST, AND NOTHING EXERCISED THE SECOND ENTRY. Every case above
# names one group, so a loop that read only the head of the list would have been
# green through this whole suite. `dave` is in `audit` and in nothing else, which
# is the only shape that can tell "the loop ran" from "the first name matched".
echo "== a grant can name more than one group =="
sess pair bob team-a 'VISIBILITY="private"\nVISIBLE_TO="board audit"\n'
yes "a member of the FIRST named group sees it"  carol pair
yes "a member of the SECOND named group sees it" dave  pair
no  "and someone in neither still does not"      erin  pair

# WORD SPLITTING IS WANTED HERE; PATHNAME EXPANSION IS NOT. `for g in $grants`
# is both, so an unquoted split makes a field the registry has already validated
# mean different things in different directories. Measured 2026-08-28 with
# VISIBLE_TO="*" on one private session — same conf, same viewer, only the
# working directory differing:
#
#   cwd holding a file named notes.txt   registry_load REFUSED the conf (rc 1)
#   cwd holding a file named board       the grant fired and the glob let a
#                                        non-member in
#   cwd holding a directory entities.d   registry_load REFUSED the conf
#
# THE FIXTURE HAS TO RUN FROM A DIRECTORY THAT WOULD EXPAND, or it asserts
# nothing at all: in an empty directory an unquoted `*` stays literal by itself
# and the broken code passes. The trap directory below is seeded with names that
# match real groups on purpose.
echo "== a literal * in VISIBLE_TO is a name, not a wildcard =="
TRAP="$FX/trap"; mkdir -p "$TRAP"; : > "$TRAP/board"; : > "$TRAP/team-a"
sess star bob team-a 'VISIBILITY="private"\nVISIBLE_TO="*"\n'
_star="$( cd "$TRAP" && session_visible_to carol star >/dev/null 2>&1 && echo VISIBLE || echo hidden )"
if [ "$_star" = hidden ]; then ok "a glob does not hand a group grant to a non-member"
else bad "a glob does not hand a group grant to a non-member" "expected HIDDEN, got $_star"; fi
# AND NOT BECAUSE EVERYTHING BROKE IN THAT DIRECTORY. Without this control the
# case above is green for a rule that refuses everyone from any cwd, which is
# not the property wanted. A grant that IS valid must still be honoured from
# the same trap directory, whose listing names its group.
_ctrl="$( cd "$TRAP" && session_visible_to carol granted >/dev/null 2>&1 && echo VISIBLE || echo hidden )"
if [ "$_ctrl" = VISIBLE ]; then ok "a real grant is still honoured from that same directory"
else bad "a real grant is still honoured from that same directory" "expected VISIBLE, got $_ctrl"; fi
# The owner of `star` does not see it either, and that is the registry refusing
# the conf rather than the rule hiding it: with the glob off, `*` is a name, and
# registry_load rejects it as an invalid VISIBLE_TO entry. Refusal-as-default
# then applies to everyone, owner included. test/visibility-fields.test.sh
# measures that half; asserted here so the asymmetry is not read as a bug.
_star_own="$( cd "$TRAP" && session_visible_to bob star >/dev/null 2>&1 && echo VISIBLE || echo hidden )"
if [ "$_star_own" = hidden ]; then ok "and an invalid grant refuses the conf for its owner too"
else bad "and an invalid grant refuses the conf for its owner too" "expected HIDDEN, got $_star_own"; fi

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

# ── NEW-SHAPE PROJECT-TARGET SESSIONS (naming model step 7) ─────────────────
# projects.d: a project owned by team-a, and one owned by client-x (the one-hop
# case). A new-shape session aims at a project via TARGET_PROJECT and carries a
# legacy-derived DOMAIN equal to the project slug — NOT an entity. The team that
# owns the work must still see it.
mkdir -p "$FX/projects.d"
printf 'NAME="Site"\nPARENT="team-a"\n'   > "$FX/projects.d/site.conf"
printf 'NAME="Shop"\nPARENT="client-x"\n' > "$FX/projects.d/shop.conf"
# owner is carol (in no relevant team) so only the derived team view can grant.
printf 'HOST="h1"\nOWNER="carol"\nDOMAIN="site"\nTARGET_PROJECT="site"\nREPO_PATH="/tmp/x"\nID="s-proja"\n' > "$FX/sessions.d/s-proja.conf"
printf 'HOST="h1"\nOWNER="carol"\nDOMAIN="shop"\nTARGET_PROJECT="shop"\nREPO_PATH="/tmp/x"\nID="s-projb"\n' > "$FX/sessions.d/s-projb.conf"

yes "a team member sees their team's PROJECT session (rule 4b)"        alice s-proja
yes "another team member sees it too"                                  bob   s-proja
yes "the owner sees their own project session"                         carol s-proja
no  "a non-member does not see the team's project session"             dave  s-proja
# one hop: team-a manages client-x; team-a members see client-x's project work.
yes "the managing team sees a CLIENT project session (4b + rule 5 hop)" alice s-projb
no  "a stranger does not see the client project session"               dave  s-projb
# the deep hop the rule must NOT take still must not: a project under a client
# under a client is two hops — team-a must not reach it.
printf 'NAME="Far"\nPARENT="deep"\n' > "$FX/projects.d/far.conf"
printf 'HOST="h1"\nOWNER="carol"\nDOMAIN="far"\nTARGET_PROJECT="far"\nREPO_PATH="/tmp/x"\nID="s-far"\n' > "$FX/sessions.d/s-far.conf"
no  "the two-hop project is NOT reachable (rule 5 is one hop only)"     alice s-far

echo
printf 'pass=%s fail=%s\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
