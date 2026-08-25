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
mkdir -p "$FX/sessions.d"

conf() { # <name> <owner> <domain> <host> <rc-label-line>
  { printf 'OWNER="%s"\nDOMAIN="%s"\nHOST="%s"\n' "$2" "$3" "$4"
    [ -n "${5:-}" ] && printf '%s\n' "$5"
  } > "$FX/sessions.d/$1.conf"
}

#            name        owner       domain    host     RC_LABEL
conf work-a   operator-a  entity-one  host-one  'RC_LABEL="A"'
conf other-a  operator-a  entity-two  host-one  'RC_LABEL="B"'
conf work-b   operator-b  entity-one  host-one  'RC_LABEL="C"'
conf far-b    operator-b  entity-two  host-two  'RC_LABEL="D"'
# The machine session is RC-free: the EMPTY line, never a missing one.
conf machine  operator-c  entity-mac  host-one  'RC_LABEL=""'
conf machine2 operator-c  entity-mac  host-two  'RC_LABEL=""'

export STEWARD_REGISTRY_DIR="$FX/sessions.d"
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

echo
printf '%s passed, %s failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
