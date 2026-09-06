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
# A target that reads as an ssh OPTION rather than as a user: the whole value
# must begin with an alphanumeric, or the first word of the command line stops
# being a destination and starts being a flag.
printf 'HUB_SSH="-F@north.example"\nOWNER="alice"\n'       > "$FX/peers.d/flagged.conf"

# A directory with nothing broken in it, for the candidate set: a malformed row
# is not skipped there any more, it refuses the whole set (part 4).
mkdir -p "$FX/peers-ok.d"
printf 'HUB_SSH="operator@north.example"\nOWNER="alice"\n' > "$FX/peers-ok.d/north.conf"
printf 'HUB_SSH="operator@east.example"\nOWNER="alice"\n'  > "$FX/peers-ok.d/east.conf"
printf 'HUB_SSH="operator@west.example"\nOWNER="bob"\n'    > "$FX/peers-ok.d/west.conf"

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
# A TARGET THAT IS AN OPTION IS NOT A TARGET. ssh reads its destination as a
# word on the command line, so a value starting with '-' is parsed as a flag and
# the letter goes wherever that flag points instead.
err="$(bus_peer_load flagged 2>&1)"; rc=$?
is  "a target that starts as an ssh flag: rc 78" "$rc" "78"
has "...naming the key" "$err" "HUB_SSH"
# THE NAME BECOMES A PATH. A peer name outside [a-z0-9-] can never name a row,
# and must not reach the file system: '*' would otherwise glob the directory.
bus_peer_load "../../etc/passwd" >/dev/null 2>&1; rc=$?
is "a peer name that is not [a-z0-9-]+: rc 1, no file is opened" "$rc" "1"

echo "4. candidates: the links one person owns, sorted, never another person's"
export STEWARD_BUS_PEERS_DIR="$FX/peers-ok.d"
is "alice owns two"          "$(bus_peer_candidates alice | tr '\n' ' ')" "east north "
is "bob owns one"            "$(bus_peer_candidates bob | tr '\n' ' ')"   "west "
is "carol owns none"         "$(bus_peer_candidates carol)" ""
bus_peer_candidates carol >/dev/null 2>&1; rc=$?
is "...and an empty list is rc 0, not an error" "$rc" "0"
is "a missing directory is an empty list" \
   "$(STEWARD_BUS_PEERS_DIR="$FX/nothing" bus_peer_candidates alice)" ""
# A BROKEN ROW IS NOT SKIPPED. Skipping it answers the question "which links
# does this person have" from an incomplete set: the one link that failed to
# parse is silently not a candidate, so a set of two reads as a set of one and
# the letter is forwarded without the ambiguity that should have stopped it.
export STEWARD_BUS_PEERS_DIR="$FX/peers.d"
out="$(bus_peer_candidates alice 2>/dev/null)"; rc=$?
is "one malformed row refuses the whole set: rc 78" "$rc" "78"
is "...and it names no candidates at all"           "$out" ""

echo "5. the key: one per link, in the hub's own home, never guessed"
: > "$FX/hh/.ssh/id_buspeer_north"
is "the key path" "$(bus_peer_key north)" "$FX/hh/.ssh/id_buspeer_north"
err="$(bus_peer_key east 2>&1)"; rc=$?
is  "a link without a key: rc 65" "$rc" "65"
has "...naming the path we looked for" "$err" "id_buspeer_east"

# ------------------------------------------------------------------ part 2
#
# THE BRANCH IN bus_send. A name we do not have is not automatically somebody
# else's: it is forwarded only over a link the SENDER'S OWNER owns, and only
# when exactly one such link exists. Everything else refuses and says why.
#
# The ssh stub records argv and stdin and answers STUB_RC, so "what left the
# machine" is an assertion about bytes; and every refusal below also asserts
# that the stub was NEVER called, because a gate that refuses after the letter
# has gone is not a gate.

mkdir -p "$FX/peers2.d" "$FX/reg" "$FX/bus-home"
export STEWARD_BUS_PEERS_DIR="$FX/peers2.d"
export STEWARD_REGISTRY_DIR="$FX/reg"
export STEWARD_BUS_HOME="$FX/bus-home"
export STEWARD_BUS_LOCAL_HOST=host-one
export STEWARD_BUS_SELF_USER=alice
cat > "$FX/estate2.conf" <<'EOF'
HUB_SESSION="hub-one"
HUB_HOST="host-one"
TMUX_SOCKET="hub-one.sock"
PING_MSG="[bus] you have mail"
EOF
export STEWARD_ESTATE="$FX/estate2.conf"

# One link for alice, one for bob. NOTHING BROKEN HERE: a malformed row refuses
# the whole candidate set now, so the broken row is written later, by the two
# tests that are about it.
printf 'HUB_SSH="operator@north.example"\nOWNER="alice"\n' > "$FX/peers2.d/north.conf"
printf 'HUB_SSH="operator@west.example"\nOWNER="bob"\n'    > "$FX/peers2.d/west.conf"
: > "$FX/hh/.ssh/id_buspeer_west"   # so a refusal below is the OWNER gate, not a missing key

# A migrated row (ID + SLUG) for alice, legacy rows for the others.
printf 'ID="s-000000000000a001"\nSLUG="scout"\nACCOUNT="alice-hub"\nOWNER="alice"\nDOMAIN="entity-one"\nHOST="host-one"\nRC_LABEL="L"\nREPO_PATH="/tmp/x"\n' > "$FX/reg/s-000000000000a001.conf"
printf 'OWNER="bob"\nDOMAIN="entity-one"\nHOST="host-one"\nRC_LABEL="L"\nREPO_PATH="/tmp/x"\n'   > "$FX/reg/bobsession.conf"
printf 'OWNER="carol"\nDOMAIN="entity-two"\nHOST="host-one"\nRC_LABEL="L"\nREPO_PATH="/tmp/x"\n' > "$FX/reg/carolsession.conf"
printf 'OWNER="alice"\nDOMAIN="entity-one"\nHOST="host-one"\nRC_LABEL="L"\nREPO_PATH="/tmp/x"\n' > "$FX/reg/local-friend.conf"

cat > "$FX/bin/ssh" <<'STUB'
#!/bin/bash
printf '%s\n' "$*" >> "${SSH_ARGV:?}"
cat >> "${SSH_STDIN:?}"
exit "${STUB_RC:-0}"
STUB
chmod 755 "$FX/bin/ssh"
export STEWARD_BUS_SSH_BIN="$FX/bin/ssh" SSH_ARGV="$FX/ssh-argv" SSH_STDIN="$FX/ssh-stdin"
arm() { : > "$SSH_ARGV"; : > "$SSH_STDIN"; }
untouched() { is "$1" "$(wc -c < "$SSH_ARGV" | tr -d ' ')" "0"; }
noop_ping() { :; }
sent_count() { find "$FX/bus-home/s-000000000000a001/sent" -name '*.json' 2>/dev/null | wc -l | tr -d ' '; }

echo "6. an explicit peer address goes over that link, and nowhere else"
arm
bus_send far@north s-000000000000a001 "DRIFT topic: hello" noop_ping >/dev/null 2>&1; rc=$?
is  "rc 0 (the stub's)" "$rc" "0"
has "the link's key"    "$(cat "$SSH_ARGV")" "-i $FX/hh/.ssh/id_buspeer_north"
has "the peer's target" "$(cat "$SSH_ARGV")" "operator@north.example"
has "batch mode"        "$(cat "$SSH_ARGV")" "-o BatchMode=yes"
has "a connect timeout" "$(cat "$SSH_ARGV")" "-o ConnectTimeout=8"
has "a server-alive interval" "$(cat "$SSH_ARGV")" "-o ServerAliveInterval=5"
# THE LINK KEY, AND NO OTHER. Without IdentitiesOnly a running agent offers its
# own keys first and the letter can arrive under a DIFFERENT authorized_keys row
# — another forced command, another owner. IdentityAgent=none takes the agent
# out of the question entirely, and ClearAllForwardings drops anything a config
# file would otherwise tunnel along.
has "only the key we named"   "$(cat "$SSH_ARGV")" "-o IdentitiesOnly=yes"
has "no agent"                "$(cat "$SSH_ARGV")" "-o IdentityAgent=none"
has "no forwardings"          "$(cat "$SSH_ARGV")" "-o ClearAllForwardings=yes"
# A FIXED REMOTE COMMAND AFTER THE TARGET. The intended key carries a forced
# command, which overrides it; if any other key ever authenticated, the remote
# runs 'false' and the text is discarded — never an interactive shell.
has "a fixed remote command, last" "$(cat "$SSH_ARGV")" "operator@north.example false"
# THE WIRE: recipient, sender, text — and the sender is OUR name for it. The
# letter was addressed by ID; what crosses is the SLUG, because that is the
# name a human on the other side can answer.
exp="$(printf '%s\n%s\n%s' far scout "DRIFT topic: hello")"
is "the three parts, in order, the sender as its slug" "$(cat "$SSH_STDIN")" "$exp"
is "...and not a byte more" "$(wc -c < "$SSH_STDIN" | tr -d ' ')" "${#exp}"
is "a forwarded letter is archived as sent" "$(sent_count)" "1"

echo "7. a bare name we do not have: forwarded over the sender's ONE link"
arm
bus_send nowhere scout "DRIFT topic: bare" noop_ping >/dev/null 2>&1; rc=$?
is  "rc 0" "$rc" "0"
has "over alice's link" "$(cat "$SSH_ARGV")" "operator@north.example"
is  "the name travels as typed" "$(printf '%s' "$(cat "$SSH_STDIN")" | sed -n 1p)" "nowhere"

echo "8. two links, one owner: ambiguous, and NOTHING is sent"
printf 'HUB_SSH="operator@east.example"\nOWNER="alice"\n' > "$FX/peers2.d/east.conf"
arm
err="$(bus_send nowhere scout "DRIFT topic: bare" noop_ping 2>&1 >/dev/null)"; rc=$?
is  "rc 65" "$rc" "65"
has "...naming one link"  "$err" "north"
has "...and the other"    "$err" "east"
has "...and how to choose" "$err" "nowhere@"
untouched "the letter never left the machine"
rm -f "$FX/peers2.d/east.conf"

echo "9. no link at all: the unknown recipient it was before links existed"
arm
err="$(bus_send nowhere carolsession "DRIFT topic: bare" noop_ping 2>&1 >/dev/null)"; rc=$?
is  "rc 1" "$rc" "1"
has "...and it says unknown recipient" "$err" "unknown recipient"
untouched "nothing left the machine"

echo "10. the owner gate: a session never leaves over a link it does not own"
arm
err="$(bus_send far@north bobsession "DRIFT topic: not yours" noop_ping 2>&1 >/dev/null)"; rc=$?
is  "rc 65" "$rc" "65"
has "...naming the sender's owner" "$err" "bob"
has "...and the link's owner"      "$err" "alice"
untouched "nothing left the machine"
arm
bus_send far@north nosuchsender "DRIFT topic: who" noop_ping >/dev/null 2>&1; rc=$?
is "a sender with no row of its own cannot prove ownership: rc 65" "$rc" "65"
untouched "...and nothing left the machine"

echo "11. a name we DO have is local, links or no links"
arm
bus_send local-friend scout "DRIFT topic: at home" noop_ping >/dev/null 2>&1; rc=$?
is  "rc 0" "$rc" "0"
is  "the letter is in the local queue" \
    "$(find "$FX/bus-home/local-friend/inbox" -name '*.json' 2>/dev/null | wc -l | tr -d ' ')" "1"
untouched "...and no link was used"

echo "12. a failed link is a failed send, and archives nothing"
before="$(sent_count)"
arm
STUB_RC=255 bus_send far@north s-000000000000a001 "DRIFT topic: lost" noop_ping >/dev/null 2>&1; rc=$?
is "the ssh return code is the send's"      "$rc" "255"
is "...and nothing is archived for it"      "$(sent_count)" "$before"

echo "13. a FRAGA does not cross a link, addressed either way"
# A FRAGA is answered by MACHINERY out of a catalogue, and the answer travels
# back as a DRIFT letter to the asker. Across a link there is no return route:
# the answering side would have to address <asker>@<us>, which is a shape no
# sending hub writes and no gate here would accept. So the question is refused
# where it is asked, rather than crossing and dying silently over there.
arm
err="$(bus_send far@north scout "FRAGA topic: sessioner" noop_ping 2>&1 >/dev/null)"; rc=$?
is  "an explicit peer address: rc 65" "$rc" "65"
has "...and it says a FRAGA is answered from a catalogue" "$err" "catalogue"
has "...and that the return route is what is missing"     "$err" "return route"
untouched "...and nothing left the machine"
arm
err="$(bus_send nowhere scout "FRAGA topic: sessioner" noop_ping 2>&1 >/dev/null)"; rc=$?
is  "a bare name that would be forwarded: rc 65" "$rc" "65"
has "...same explanation" "$err" "return route"
untouched "...and nothing left the machine"

echo "14. a malformed row refuses discovery: never a route from an incomplete set"
printf 'HUB_SSH="operator@bent.example"\n' > "$FX/peers2.d/bent.conf"
arm
err="$(bus_send nowhere scout "DRIFT topic: bare" noop_ping 2>&1 >/dev/null)"; rc=$?
is  "rc 78, the reader's code" "$rc" "78"
has "...naming the broken row" "$err" "bent"
untouched "...and nothing left the machine"

echo "15. the refusals that come BEFORE the link"
mkdir -p "$FX/bus-home"; printf 'hush\n' > "$FX/bus-home/parkerade"
arm
bus_send far@north scout "FYND hush: parked" noop_ping >/dev/null 2>&1; rc=$?
is "a parked subject: rc 65 — the parking list is the SENDING estate's" "$rc" "65"
untouched "...and nothing left the machine"
rm -f "$FX/bus-home/parkerade"
arm
err="$(bus_send far@south scout "DRIFT topic: x" noop_ping 2>&1 >/dev/null)"; rc=$?
is  "an unknown peer: rc 65" "$rc" "65"
has "...and it says so"      "$err" "unknown peer"
untouched "...and nothing left the machine"
arm
bus_send far@bent scout "DRIFT topic: x" noop_ping >/dev/null 2>&1; rc=$?
is "a broken peer row: rc 78, the reader's code" "$rc" "78"
untouched "...and nothing left the machine"
arm
bus_send far@north@east scout "DRIFT topic: x" noop_ping >/dev/null 2>&1; rc=$?
is "an address with two hops: rc 65 — one hop, never a chain" "$rc" "65"
untouched "...and nothing left the machine"
arm
bus_send "Far@north" scout "DRIFT topic: x" noop_ping >/dev/null 2>&1; rc=$?
is "a recipient name of the wrong form: rc 65" "$rc" "65"
untouched "...and nothing left the machine"

echo
printf '%s: %d passed, %d failed\n' "$(basename "$0")" "$pass" "$fail"
[ "$fail" -eq 0 ]
