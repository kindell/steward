#!/bin/bash
# test/hub-peer-out.test.sh — the SENDING side of a hub peer link: the peers.d
# reader and its refusals, and the branch in bus_send that hands a letter to a
# neighbouring hub.
#
# WHAT THE LINK IS. A link between two hubs has an OWNER. Nothing crosses it
# unless the sending session is owned by the link's owner, measured in the
# sender's own registry. The receiving hub runs the mirrored gate against its
# own registry. Neither hub trusts the other's claim about who wrote what, so
# the sending side is tested here on its own terms: what leaves the machine,
# over which key, to which target, and what is refused before anything leaves.
#
# WHY THE REFUSALS ARE THE POINT. A malformed peer row must never fall back on
# a guess: a link is a person's own name in ANOTHER estate, and the wrong one
# hands another person's hub a letter it will store as ours. So a row missing a
# key, or carrying a target that is not user@host, refuses (rc 78) and names the
# file and the key — it never degrades into "no peers".
#
# NO TEST HERE EVER SSHes. STEWARD_BUS_SSH_BIN points at a stub that records its
# argv and its stdin and answers STUB_RC; the wire bytes are then an assertion
# rather than a description.
set -u
here="$(CDPATH= cd -- "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
pass=0; fail=0
ok()  { pass=$((pass+1)); printf '  ok   %s\n' "$1"; }
bad() { fail=$((fail+1)); printf '  FAIL %s\n     %s\n' "$1" "${2:-}"; }
is()  { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "wanted '$3', got '$2'"; fi; }
has() { case "$2" in *"$3"*) ok "$1" ;; *) bad "$1" "missing '$3' in: $2" ;; esac; }

FX="$(mktemp -d)"; trap 'rm -rf "$FX"' EXIT
mkdir -p "$FX/peers.d" "$FX/hh/.ssh" "$FX/bin"
export HOME="$FX/hh"
export STEWARD_BUS_PEERS_DIR="$FX/peers.d"

# Two links owned by one person, one owned by another. The names are LOCAL to
# this side: what we call north may call us south.
printf 'HUB_SSH="operator@north.example"\nOWNER="alice"\n' > "$FX/peers.d/north.conf"
printf 'HUB_SSH="operator@east.example"\nOWNER="alice"\n'  > "$FX/peers.d/east.conf"
printf 'HUB_SSH="operator@west.example"\nOWNER="bob"\n'    > "$FX/peers.d/west.conf"
# Two broken rows: one without an owner, one whose target is not user@host.
printf 'HUB_SSH="operator@south.example"\n'                > "$FX/peers.d/south.conf"
printf 'HUB_SSH="northexample"\nOWNER="alice"\n'           > "$FX/peers.d/inner.conf"

# shellcheck source=/dev/null
. "$here/linux/hub/lib.sh"

echo "1. the peers directory: the estate's, overridable for a fixture"
is "STEWARD_BUS_PEERS_DIR wins" "$(bus_peers_dir)" "$FX/peers.d"
is "otherwise it sits in the estate root" \
   "$(STEWARD_BUS_PEERS_DIR= STEWARD_ESTATE_ROOT="$FX/root" bus_peers_dir)" "$FX/root/peers.d"

echo "2. a good row: the ssh target and the owner, read with sed, never sourced"
BUS_PEER_SSH=""; BUS_PEER_OWNER=""
bus_peer_load north; rc=$?
is "rc 0" "$rc" "0"
is "HUB_SSH"  "$BUS_PEER_SSH"   "operator@north.example"
is "OWNER"    "$BUS_PEER_OWNER" "alice"
bus_peer_load west >/dev/null 2>&1
is "a second row overwrites both fields" "$BUS_PEER_OWNER" "bob"

echo "3. refusals: a row we cannot trust never degrades into a guess"
bus_peer_load nowhere >/dev/null 2>&1; rc=$?
is "an unknown peer: rc 1" "$rc" "1"
err="$(bus_peer_load south 2>&1)"; rc=$?
is  "a row without OWNER: rc 78" "$rc" "78"
has "...naming the file" "$err" "south.conf"
has "...naming the key"  "$err" "OWNER"
err="$(bus_peer_load inner 2>&1)"; rc=$?
is  "a target that is not user@host: rc 78" "$rc" "78"
has "...naming the key" "$err" "HUB_SSH"
# THE NAME BECOMES A PATH. A peer name outside [a-z0-9-] can never name a row,
# and must not reach the file system: '*' would otherwise glob the directory.
bus_peer_load "../../etc/passwd" >/dev/null 2>&1; rc=$?
is "a peer name that is not [a-z0-9-]+: rc 1, no file is opened" "$rc" "1"

echo "4. candidates: the links one person owns, sorted, never another person's"
is "alice owns two"          "$(bus_peer_candidates alice | tr '\n' ' ')" "east north "
is "bob owns one"            "$(bus_peer_candidates bob | tr '\n' ' ')"   "west "
is "carol owns none"         "$(bus_peer_candidates carol)" ""
bus_peer_candidates carol >/dev/null 2>&1; rc=$?
is "...and an empty list is rc 0, not an error" "$rc" "0"
is "a broken row is nobody's candidate" "$(bus_peer_candidates alice | grep -c inner)" "0"
is "a missing directory is an empty list" \
   "$(STEWARD_BUS_PEERS_DIR="$FX/nothing" bus_peer_candidates alice)" ""

echo "5. the key: one per link, in the hub's own home, never guessed"
: > "$FX/hh/.ssh/id_buspeer_north"
is "the key path" "$(bus_peer_key north)" "$FX/hh/.ssh/id_buspeer_north"
err="$(bus_peer_key east 2>&1)"; rc=$?
is  "a link without a key: rc 65" "$rc" "65"
has "...naming the path we looked for" "$err" "id_buspeer_east"

echo
printf '%s: %d passed, %d failed\n' "$(basename "$0")" "$pass" "$fail"
[ "$fail" -eq 0 ]
