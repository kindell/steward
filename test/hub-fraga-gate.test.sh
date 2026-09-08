#!/bin/bash
# test/hub-fraga-gate.test.sh — bus_fraga_tillatet in linux/hub/lib.sh.
#
# THE HOLE THAT GAVE THE TEST: the gate is the only thing standing between a
# FRAGA and a mechanical answer read out of the WHOLE session registry — an
# inventory of another person's fleet that the homes' 750 otherwise prevents.
# It had no test at all. When the file was translated into the product, the
# locals were renamed to from_/to_ but two of the four reads kept the old name,
# so the recipient's owner and domain were looked up under an empty session
# name. That file never exists, so both reads returned 1 and the gate refused.
#
# IT FAILED CLOSED, which is the safe direction and exactly why it went unseen:
# nothing leaked and nothing crashed. What broke was the PERMIT — every FRAGA
# was refused, including the ones the rule exists to allow. A gate that says no
# to everything is not a gate; it is an outage wearing a gate's clothes, and it
# cannot be told from a working gate by watching refusals.
#
# So the load-bearing cases here are the ALLOWED ones. The refusals below are a
# control group: they passed even while the gate was broken, and on their own
# they certify nothing.
set -u

here="$(CDPATH= cd -- "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
pass=0; fail=0
ok()  { pass=$((pass+1)); printf '  ok   %s\n' "$1"; }
bad() { fail=$((fail+1)); printf '  FAIL %s\n     %s\n' "$1" "${2:-}"; }

FX="$(mktemp -d)"; trap 'rm -rf "$FX"' EXIT
mkdir -p "$FX/reg"

conf() { # <name> <owner> <domain> <host> <rc-label-line>
  { printf 'OWNER="%s"\nDOMAIN="%s"\nHOST="%s"\n' "$2" "$3" "$4"
    [ -n "${5:-}" ] && printf '%s\n' "$5"
  } > "$FX/reg/$1.conf"
}

#            name        owner       domain    host     RC_LABEL
conf work-a   operator-a  entity-one  host-one  'RC_LABEL="A"'
conf other-a  operator-a  entity-two  host-one  'RC_LABEL="B"'
conf work-b   operator-b  entity-one  host-one  'RC_LABEL="C"'
conf far-b    operator-b  entity-two  host-two  'RC_LABEL="D"'
# The machine session is RC-free: the EMPTY line, never a missing one.
conf machine  operator-c  entity-mac  host-one  'RC_LABEL=""'
conf machine2 operator-c  entity-mac  host-two  'RC_LABEL=""'

# PRINCIPAL FIXTURES: accounts.d rows and the session rows that name them, for
# the cases below where the gate must compare the PERSON, not the account.
mkdir -p "$FX/accounts.d" "$FX/entities.d"
export STEWARD_ACCOUNT_DIR="$FX/accounts.d"
export STEWARD_ENTITY_DIR="$FX/entities.d"

acct() { # <slug> <principal> <username> <host>
  printf 'PRINCIPAL="%s"\nUSERNAME="%s"\nHOST="%s"\n' "$2" "$3" "$4" > "$FX/accounts.d/$1.conf"
}

# One person, two accounts: alice runs one session under her own name and one
# under the steward account, both on host-a.
acct acct-sa alice  steward host-a
acct acct-al alice  alice   host-a
# The same unix account, bob, naming two DIFFERENT principals - not a real
# shape, but the gate must not open on OWNER alone any more.
acct acct-ba alice  bob     host-a
acct acct-bb bob    bob     host-a

printf 'OWNER="steward"\nACCOUNT="acct-sa"\nDOMAIN="entity-one"\nHOST="host-a"\nRC_LABEL="P1"\n'   > "$FX/reg/stewa.conf"
printf 'OWNER="alice"\nACCOUNT="acct-al"\nDOMAIN="entity-two"\nHOST="host-a"\nRC_LABEL="P2"\n'     > "$FX/reg/alicer.conf"
printf 'OWNER="bob"\nACCOUNT="acct-ba"\nDOMAIN="entity-three"\nHOST="host-a"\nRC_LABEL="P3"\n'     > "$FX/reg/samea.conf"
printf 'OWNER="bob"\nACCOUNT="acct-bb"\nDOMAIN="entity-four"\nHOST="host-a"\nRC_LABEL="P4"\n'      > "$FX/reg/sameb.conf"
printf 'OWNER="steward"\nACCOUNT="ghost"\nDOMAIN="entity-one"\nHOST="host-a"\nRC_LABEL="P5"\n'     > "$FX/reg/ghostrow.conf"
printf 'OWNER="bob"\nDOMAIN="entity-five"\nHOST="host-a"\nVISIBLE_TO="grp"\nRC_LABEL="P6"\n'       > "$FX/reg/grptarget.conf"
printf 'OWNER="steward"\nACCOUNT="acct-sa"\nDOMAIN="entity-six"\nHOST="host-a"\nRC_LABEL="P7"\n'   > "$FX/reg/askerrow.conf"

export STEWARD_REGISTRY_DIR="$FX/reg"
# shellcheck source=/dev/null
source "$here/linux/hub/lib.sh"

allowed() { bus_fraga_tillatet "$1" "$2" && ok "$3" || bad "$3" "refused $1 -> $2"; }
refused() { bus_fraga_tillatet "$1" "$2" && bad "$3" "allowed $1 -> $2" || ok "$3"; }

echo "FRAGA gate — the permit"
# SAME OWNER. One person's own sessions are a team; the entity differs on
# purpose, so this can only pass by reading the recipient's OWNER.
allowed work-a other-a "same owner, different entity: allowed"
# SAME ENTITY ACROSS PEOPLE. This is the intent, not a hole — two people's
# sessions working the same entity need each other's state.
allowed work-a work-b  "same entity, different people: allowed"
# THE MACHINE SESSION belongs to everyone with a foothold on the machine.
allowed work-a machine "machine session, same host: allowed"

echo "FRAGA gate — the refusal (control group)"
refused work-a far-b     "different owner and entity: refused"
refused work-a machine2  "machine session on another host: refused"
refused work-a nosuch    "recipient with no conf: refused"
refused ""     work-b    "empty sender: refused"

echo "FRAGA gate - the principal, not the account"
# CASE 1: different unix accounts, one PRINCIPAL - allowed. Before this change
# the gate compared OWNER directly (steward != alice) and refused this pair.
allowed stewa alicer "same principal across different accounts: allowed"

# CASE 2: the SAME unix account naming two DIFFERENT principals, with
# different domains too - refused. The gate must not open on OWNER alone.
refused samea sameb "same owner, different principals, different domains: refused"

# CASE 3: a row naming an ACCOUNT that does not load is a row this hub cannot
# vouch for - refused, and nothing on the gate's own stderr. The account
# loader's own explanation is written for the ones who can see it (the peer
# link, where the sender reads it); here the asker gets only the gate's
# refusal, and a row this hub cannot vouch for opens nothing.
err="$(bus_fraga_tillatet ghostrow stewa 2>&1 >/dev/null)"; rc=$?
[ "$rc" -ne 0 ] && ok "a row naming an account that does not load: refused" \
  || bad "a row naming an account that does not load: refused" "allowed ghostrow -> stewa"
[ -z "$err" ] && ok "...and the gate itself wrote nothing to stderr" \
  || bad "...and the gate itself wrote nothing to stderr" "$err"

# CASE 4: the group grant's MEMBERS names PRINCIPALS, never accounts.
printf 'NAME="Group"\nMEMBERS="alice"\n' > "$FX/entities.d/grp.conf"
allowed askerrow grptarget "group grant: asker's principal is a member: allowed"
printf 'NAME="Group"\nMEMBERS="steward"\n' > "$FX/entities.d/grp.conf"
refused askerrow grptarget "group grant: MEMBERS names principals, not accounts: refused"

echo
printf 'pass=%s fail=%s\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
