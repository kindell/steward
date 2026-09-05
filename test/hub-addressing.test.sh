#!/bin/bash
# test/hub-addressing.test.sh — group 3 of the hub-library merge: who is a valid
# recipient, where it lives, who owns it, and what is pending for it.
#
# THE HUB IS A SESSION WITH A ROW, like every other. The hub's name used to be
# a special case admitted without a row - from the time the hub had none. Now
# it has one, so the special case died: without a row the hub's word is an
# unknown recipient, and a word the estate does not use gets no privilege at
# all. Measured in the estate on 2026-09-05: with the special case, a hub whose
# row had migrated had TWO queues, one read by nobody.
#
# WHERE A RECIPIENT LIVES IS ANSWERED BY THE REGISTRY, NEVER GUESSED. A row
# without HOST lives on the estate's HUB_HOST; a row without HOST in an estate
# without HUB_HOST REFUSES (rc 65) - it used to fall back on a literal hub
# name, which after a split of the estate is a machine that is not even
# reachable, and a letter sent there looks delivered to the sender.
#
# WHO OWNS A RECIPIENT IS NEVER GUESSED EITHER. The estate's copy defaulted to
# a person's name when the row was missing or malformed - a name in the code,
# and a guess that produces exactly the misdelivery the function exists to
# prevent. The refusal semantics stay; the resolution goes through the resolver
# so a slug-addressed recipient's owner is read from the row that was resolved.
set -u
here="$(CDPATH= cd -- "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
pass=0; fail=0
ok()  { pass=$((pass+1)); printf '  ok   %s\n' "$1"; }
bad() { fail=$((fail+1)); printf '  FAIL %s\n     %s\n' "$1" "${2:-}"; }
is()  { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "wanted '$3', got '$2'"; fi; }
has() { case "$2" in *"$3"*) ok "$1" ;; *) bad "$1" "missing '$3' in: $2" ;; esac; }

FX="$(mktemp -d)"; trap 'rm -rf "$FX"' EXIT
mkdir -p "$FX/sessions.d" "$FX/empty.d" "$FX/hh"
export STEWARD_REGISTRY_DIR="$FX/sessions.d"
export STEWARD_BUS_HOME="$FX/bus-home"
export HOME="$FX/hh"
cat > "$FX/estate.conf" <<'EOF'
HUB_SESSION="hub-one"
HUB_HOST="host-one"
TMUX_SOCKET="hub-one.sock"
PING_MSG="[bus] you have mail"
EOF
cat > "$FX/estate-no-hub-host.conf" <<'EOF'
HUB_SESSION="hub-one"
TMUX_SOCKET="hub-one.sock"
PING_MSG="[bus] you have mail"
EOF
export STEWARD_ESTATE="$FX/estate.conf"
printf 'OWNER="operator-a"\nDOMAIN="entity-one"\nHOST="host-one"\nRC_LABEL="L"\nREPO_PATH="/tmp/x"\n' > "$FX/sessions.d/legacy.conf"
printf 'OWNER="operator-a"\nDOMAIN="entity-one"\nHOST="host-two"\nRC_LABEL="L"\nREPO_PATH="/tmp/x"\n' > "$FX/sessions.d/remote.conf"
printf 'OWNER="operator-b"\nDOMAIN="entity-one"\nRC_LABEL="L"\nREPO_PATH="/tmp/x"\n' > "$FX/sessions.d/homeless.conf"
printf 'DOMAIN="entity-one"\nHOST="host-one"\nRC_LABEL="L"\nREPO_PATH="/tmp/x"\n' > "$FX/sessions.d/ownerless.conf"
printf 'OWNER="Not Valid"\nDOMAIN="entity-one"\nHOST="host-one"\nRC_LABEL="L"\nREPO_PATH="/tmp/x"\n' > "$FX/sessions.d/badowner.conf"
printf 'ID="s-00000000000000aa"\nSLUG="alpha"\nACCOUNT="operator-a-hub"\nOWNER="operator-a"\nDOMAIN="entity-one"\nHOST="host-two"\nRC_LABEL="L"\nREPO_PATH="/tmp/x"\n' > "$FX/sessions.d/s-00000000000000aa.conf"
printf 'ID="s-00000000000000ff"\nSLUG="hub-one"\nACCOUNT="operator-a-hub"\nOWNER="operator-a"\nDOMAIN="machine"\nHOST="host-one"\nRC_LABEL="Hub"\nREPO_PATH="/tmp/x"\n' > "$FX/sessions.d/s-00000000000000ff.conf"

# shellcheck source=/dev/null
. "$here/linux/hub/lib.sh"
noop_ping() { :; }

echo "1. a valid recipient is a resolvable row - the hub included, and only with its row"
bus_valid_recipient legacy && ok "legacy row is valid" || bad "legacy row is valid"
bus_valid_recipient alpha  && ok "slug is valid" || bad "slug is valid"
bus_valid_recipient s-00000000000000aa && ok "ID is valid" || bad "ID is valid"
bus_valid_recipient hub-one && ok "the hub's word is valid WHEN its row exists" || bad "the hub's word is valid WHEN its row exists"
bus_valid_recipient nobody && bad "unknown name is not valid" || ok "unknown name is not valid"
bus_valid_recipient "" && bad "empty name is not valid" || ok "empty name is not valid"
( export STEWARD_REGISTRY_DIR="$FX/empty.d"; bus_valid_recipient hub-one ); rc=$?
is "without its row the hub's word is UNKNOWN (rc 1) - no special case" "$rc" "1"

echo "2. where a recipient lives: the row, then the estate, then a refusal"
is "row with HOST"                      "$(bus_recipient_host remote)" "host-two"
is "row without HOST lives on HUB_HOST" "$(bus_recipient_host homeless)" "host-one"
is "slug-addressed: HOST from the resolved row" "$(bus_recipient_host alpha)" "host-two"
is "the hub lives where ITS row says"   "$(bus_recipient_host hub-one)" "host-one"
bus_recipient_host nobody 2>/dev/null; rc=$?
is "unknown recipient: rc 1, empty" "$rc" "1"
err="$(STEWARD_ESTATE="$FX/estate-no-hub-host.conf" bus_recipient_host homeless 2>&1 >/dev/null)"; rc=$?
is  "no HOST and no HUB_HOST: REFUSES rc 65" "$rc" "65"
has "the refusal names the recipient" "$err" "homeless"
is  "and prints no guess on stdout" "$(STEWARD_ESTATE="$FX/estate-no-hub-host.conf" bus_recipient_host homeless 2>/dev/null)" ""
# THE SEND STOPS ON THAT REFUSAL. An empty host used to read as "local" one step
# later - the same fail-open, moved. The send must return the 65 and write nothing.
before="$(find "$FX/bus-home" -name '*.json' 2>/dev/null | wc -l | tr -d ' ')"
( export STEWARD_ESTATE="$FX/estate-no-hub-host.conf" STEWARD_BUS_LOCAL_HOST=host-one
  bus_send homeless legacy "DRIFT topic: nowhere to go" noop_ping >/dev/null 2>&1 ); rc=$?
is "bus_send returns the refusal (65), not a local write" "$rc" "65"
is "and nothing was written anywhere" "$(find "$FX/bus-home" -name '*.json' 2>/dev/null | wc -l | tr -d ' ')" "$before"

echo "3. who owns a recipient: read from the resolved row, never guessed"
is "owner via legacy name" "$(bus_recipient_owner legacy)" "operator-a"
is "owner via slug"        "$(bus_recipient_owner alpha)"  "operator-a"
is "owner via ID"          "$(bus_recipient_owner s-00000000000000aa)" "operator-a"
out="$(bus_recipient_owner nobody 2>/dev/null)"; rc=$?
is "unknown recipient: refuses rc 1"           "$rc" "1"
is "unknown recipient: no account on stdout"   "$out" ""
out="$(bus_recipient_owner ownerless 2>/dev/null)"; rc=$?
is "row without OWNER: refuses rc 1"           "$rc" "1"
is "row without OWNER: no guessed account"     "$out" ""
err="$(bus_recipient_owner badowner 2>&1 >/dev/null)"; rc=$?
is  "malformed OWNER: refuses rc 1"            "$rc" "1"
has "malformed OWNER: the refusal explains"    "$err" "refusing to guess"

echo "4. pending mail is listed from the ID-keyed queue, whichever name is used"
# The queue is seeded directly: keying the SEND on the ID is the last group of
# the merge, and this section must not depend on it.
q="$FX/bus-home/s-00000000000000aa/inbox"; mkdir -p "$q"
bus_message_json legacy s-00000000000000aa 1700000000 "DRIFT topic: first"  > "$q/1700000000-legacy-1.json"
bus_message_json legacy s-00000000000000aa 1700000001 "DRIFT topic: second" > "$q/1700000001-legacy-2.json"
is "listed via slug: two lines" "$(bus_list_unacked alpha | grep -c '.')" "2"
is "listed via ID: the same two" "$(bus_list_unacked s-00000000000000aa | grep -c '.')" "2"
has "format is <file>|<age>|<from>" "$(bus_list_unacked alpha | head -1)" "|legacy"
is "an unresolvable name lists nothing, rc 0" "$(bus_list_unacked nobody; echo "rc=$?")" "rc=0"

echo
printf '%s: %d passed, %d failed\n' "$(basename "$0")" "$pass" "$fail"
[ "$fail" -eq 0 ]
