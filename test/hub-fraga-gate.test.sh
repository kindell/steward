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
# A MACHINE session (RC-free) whose ACCOUNT does not load - the carve-out sits
# behind the principal of the target, so this row is closed to the machine too.
printf 'OWNER="steward"\nACCOUNT="ghost"\nDOMAIN="entity-mac"\nHOST="host-a"\nRC_LABEL=""\n'      > "$FX/reg/ghostmac.conf"
# Two people, two accounts that both load, ONE domain: the domain path must
# still open when both rows can be vouched for.
printf 'OWNER="alice"\nACCOUNT="acct-al"\nDOMAIN="entity-seven"\nHOST="host-a"\nRC_LABEL="P8"\n'  > "$FX/reg/domalice.conf"
printf 'OWNER="bob"\nACCOUNT="acct-bb"\nDOMAIN="entity-seven"\nHOST="host-a"\nRC_LABEL="P9"\n'    > "$FX/reg/dombob.conf"
# UNQUOTED OWNER, no ACCOUNT: valid to the registry loader, which sources the
# conf. The domains differ, so only the person path can open this pair.
printf 'OWNER=alice\nDOMAIN="entity-eight"\nHOST="host-a"\nRC_LABEL="Q1"\n'                       > "$FX/reg/unqa.conf"
printf 'OWNER=alice\nDOMAIN="entity-nine"\nHOST="host-a"\nRC_LABEL="Q2"\n'                        > "$FX/reg/unqb.conf"

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
# vouch for - refused, and the refusal is LOUD. A gate that closes silently on
# a broken row cannot be told from a gate that is working, so the account
# loader's own explanation - it names the conf and the cause - is left on
# stderr. The repair is on the ROW, and only that text says which row.
err="$(bus_fraga_tillatet ghostrow stewa 2>&1 >/dev/null)"; rc=$?
[ "$rc" -ne 0 ] && ok "a row naming an account that does not load: refused" \
  || bad "a row naming an account that does not load: refused" "allowed ghostrow -> stewa"
[ -n "$err" ] && ok "...and the reason reached stderr" \
  || bad "...and the reason reached stderr" "stderr was empty"
case "$err" in *cannot*) ok "...naming the cause" ;; *) bad "...naming the cause" "$err" ;; esac
case "$err" in *ghostrow.conf*) ok "...naming the conf" ;; *) bad "...naming the conf" "$err" ;; esac

# CASE 4: the group grant's MEMBERS names PRINCIPALS, never accounts.
printf 'NAME="Group"\nMEMBERS="alice"\n' > "$FX/entities.d/grp.conf"
allowed askerrow grptarget "group grant: asker's principal is a member: allowed"
printf 'NAME="Group"\nMEMBERS="steward"\n' > "$FX/entities.d/grp.conf"
refused askerrow grptarget "group grant: MEMBERS names principals, not accounts: refused"

echo "FRAGA gate - the target side"
# CASE 5: THE TARGET'S ROW IS JUDGED TOO, and before every grant below it. A
# target naming an account this hub cannot read is refused on the same-DOMAIN
# path and on the machine carve-out alike - both of which needed no account at
# all before. That is refusal-as-default, and the cost of it is an outage that
# looks exactly like a working gate, so both cases are pinned here and the
# first one asserts that the reason is audible.
err="$(bus_fraga_tillatet work-a ghostrow 2>&1 >/dev/null)"; rc=$?
[ "$rc" -ne 0 ] && ok "target's account does not load, same domain: refused" \
  || bad "target's account does not load, same domain: refused" "allowed work-a -> ghostrow"
[ -n "$err" ] && ok "...and the reason reached stderr" \
  || bad "...and the reason reached stderr" "stderr was empty"
case "$err" in *cannot*) ok "...naming the cause" ;; *) bad "...naming the cause" "$err" ;; esac
case "$err" in *ghostrow.conf*) ok "...naming the conf" ;; *) bad "...naming the conf" "$err" ;; esac
# The machine session belongs to everyone on the machine - but not when its own
# row cannot be vouched for.
refused askerrow ghostmac "machine session whose account does not load, same host: refused"
# And the domain path still opens when BOTH rows can be vouched for, even
# though the two principals differ. Refusal-as-default must not become refusal.
allowed domalice dombob "two vouched rows, different principals, same domain: allowed"

# THE OWNER READ CHANGED GRAMMAR with the principal: delivery's grep|tr|cut
# reads OWNER quoted or unquoted, where the gate's old sed read quoted only.
# An unquoted OWNER= row is legitimate - the registry loader sources the conf -
# and it is accepted here now where it was refused before.
allowed unqa unqb "unquoted OWNER, one person, different domains: allowed"

echo
printf 'pass=%s fail=%s\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
