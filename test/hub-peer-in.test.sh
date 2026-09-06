#!/bin/bash
# test/hub-peer-in.test.sh — the RECEIVING side of a hub peer link: the forced
# command bus-relay-peer, and what bus_send does with a letter that arrived over
# a link.
#
# THE OWNER COMES FROM THE KEY, NEVER FROM THE LETTER. The sending hub says who
# wrote the letter; this hub does not believe it. The authorized_keys row names
# the peer AND the link's owner, the forced command passes both from its argv,
# and every gate on this side measures that owner against OUR registry. A
# neighbouring hub can therefore reach exactly the sessions its link's owner
# owns here, and nothing else — whatever it writes on the wire.
#
# ONE HOP, NEVER A CHAIN. A recipient carrying an '@' asks this hub to forward
# on to a third hub; two hubs pointing at each other would then pass the same
# letter back and forth until a disk fills. The form check on the recipient is
# that refusal, and it runs before anything is written.
#
# THE '@' IN A SENDER IS THE FORGERY GUARD, and it is structural: a local
# session's name can never contain one (the registry's form check), so a stored
# `from` with an '@' can only have come through this path — and bus_send accepts
# that shape ONLY when the forced command has named a link owner.
#
# NOTHING HERE SSHes OR TALKS TO tmux. STEWARD_BUS_SSH_BIN and
# STEWARD_BUS_TMUX_BIN point at stubs; the relay itself is driven as a
# subprocess, the way sshd runs it.
set -u
here="$(CDPATH= cd -- "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
pass=0; fail=0
ok()  { pass=$((pass+1)); printf '  ok   %s\n' "$1"; }
bad() { fail=$((fail+1)); printf '  FAIL %s\n     %s\n' "$1" "${2:-}"; }
is()  { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "wanted '$3', got '$2'"; fi; }
has() { case "$2" in *"$3"*) ok "$1" ;; *) bad "$1" "missing '$3' in: $2" ;; esac; }
RELAY="$here/linux/hub/bin/bus-relay-peer"

FX="$(mktemp -d)"; trap 'rm -rf "$FX"' EXIT
mkdir -p "$FX/hh" "$FX/bin" "$FX/reg" "$FX/bus-home"
export HOME="$FX/hh"
export STEWARD_REGISTRY_DIR="$FX/reg"

# No links: this suite never routes over the machine's real peers.d.
mkdir -p "$FX/peers.d"; export STEWARD_BUS_PEERS_DIR="$FX/peers.d"
export STEWARD_BUS_HOME="$FX/bus-home"
export STEWARD_BUS_LOCAL_HOST=host-one
# The receiving hub runs as alice's account, so alice's sessions are delivered
# into this home and bob's would go over ssh to his — the ordinary two paths.
export STEWARD_BUS_SELF_USER=alice
cat > "$FX/estate.conf" <<'EOF'
HUB_SESSION="hub-one"
HUB_HOST="host-one"
TMUX_SOCKET="hub-one.sock"
PING_MSG="[bus] you have mail"
EOF
export STEWARD_ESTATE="$FX/estate.conf"

# Two recipients in OUR registry: one owned by the link's owner, one by somebody
# else. Both live on this machine.
printf 'OWNER="alice"\nDOMAIN="entity-one"\nHOST="host-one"\nRC_LABEL="L"\nREPO_PATH="/tmp/x"\n' > "$FX/reg/svc.conf"
printf 'OWNER="bob"\nDOMAIN="entity-two"\nHOST="host-one"\nRC_LABEL="L"\nREPO_PATH="/tmp/x"\n'   > "$FX/reg/other.conf"

cat > "$FX/bin/ssh" <<'STUB'
#!/bin/bash
printf '%s\n' "$*" >> "${SSH_ARGV:?}"
cat > /dev/null
exit "${STUB_RC:-0}"
STUB
# has-session answers no, so the ping is a no-op and no pane is ever typed into.
cat > "$FX/bin/tmux" <<'STUB'
#!/bin/bash
printf '%s\n' "$*" >> "${TMUX_CALLS:?}"
exit 1
STUB
chmod 755 "$FX/bin/ssh" "$FX/bin/tmux"
export STEWARD_BUS_SSH_BIN="$FX/bin/ssh" SSH_ARGV="$FX/ssh-argv"
export STEWARD_BUS_TMUX_BIN="$FX/bin/tmux" TMUX_CALLS="$FX/tmux-calls"
: > "$SSH_ARGV"; : > "$TMUX_CALLS"

# The wire, exactly as the sending hub writes it: recipient, sender, text to EOF.
wire() { printf '%s\n%s\n%s' "$1" "$2" "$3"; }
relay() { # <to> <from> <text> — the forced command, as sshd runs it
  wire "$1" "$2" "$3" | bash "$RELAY" north alice
}
inbox_count() { find "$FX/bus-home/$1/inbox" -name '*.json' 2>/dev/null | wc -l | tr -d ' '; }
sent_any() { find "$FX/bus-home" -type d -name sent 2>/dev/null | wc -l | tr -d ' '; }

echo "1. the protocol: three parts, or nothing is written"
printf '' | bash "$RELAY" north alice >/dev/null 2>&1; rc=$?
is "empty stdin: rc 64" "$rc" "64"
printf 'svc\n' | bash "$RELAY" north alice >/dev/null 2>&1; rc=$?
is "a recipient but no sender: rc 64" "$rc" "64"
printf 'svc\nsender\n' | bash "$RELAY" north alice >/dev/null 2>&1; rc=$?
is "a sender but no text: rc 64" "$rc" "64"
bash "$RELAY" north </dev/null >/dev/null 2>&1; rc=$?
[ "$rc" -ne 0 ] && ok "without both arguments the forced command refuses" \
                || bad "without both arguments the forced command refuses"
printf 'svc\nsender\nDRIFT topic: x' | bash "$RELAY" North alice >/dev/null 2>&1; rc=$?
is "a peer name of the wrong form in the key's row: rc 78" "$rc" "78"
printf 'svc\nsender\nDRIFT topic: x' | bash "$RELAY" north Alice >/dev/null 2>&1; rc=$?
is "an owner of the wrong form in the key's row: rc 78" "$rc" "78"

echo "2. one hop, never a chain: an '@' in either name is refused"
out="$(relay "svc@east" sender "DRIFT topic: onwards" 2>&1)"; rc=$?
is  "a recipient at a third hub: rc 64" "$rc" "64"
is  "...and nothing was written" "$(inbox_count svc)" "0"
printf 'svc\nsender@east\nDRIFT topic: x' | bash "$RELAY" north alice >/dev/null 2>&1; rc=$?
is  "a sender that already carries a peer: rc 64" "$rc" "64"
relay "Svc" sender "DRIFT topic: x" >/dev/null 2>&1; rc=$?
is  "a recipient that is not [a-z0-9-]+: rc 64" "$rc" "64"
relay "../../etc" sender "DRIFT topic: x" >/dev/null 2>&1; rc=$?
is  "the recipient becomes a path: traversal is refused, rc 64" "$rc" "64"
[ -e "$FX/bus-home/../../etc" ] && bad "path traversal got through" || ok "...and nothing was created outside the queue"

echo "3. a letter over the link lands, stamped with the peer we know"
relay svc sender "DRIFT topic: hello from afar" >/dev/null 2>&1; rc=$?
is "rc 0" "$rc" "0"
is "the record landed in the recipient's inbox" "$(inbox_count svc)" "1"
f="$(find "$FX/bus-home/svc/inbox" -name '*.json' 2>/dev/null | head -1)"
is "the sender is <name>@<peer> — our name for the link, not theirs for themselves" \
   "$(jq -r .from "$f" 2>/dev/null)" "sender@north"
is "the text is intact" "$(jq -r .text "$f" 2>/dev/null)" "DRIFT topic: hello from afar"
is "the envelope was parsed here too" "$(jq -r .klass "$f" 2>/dev/null)" "DRIFT"

echo "4. THE RECEIVING HUB ARCHIVES NOTHING. The sending hub holds the sent copy;"
echo "   a second one here would be a letter this hub never sent."
is "no sent/ anywhere under the queue root" "$(sent_any)" "0"

echo "5. bus_read renders the peer sender unchanged"
# shellcheck source=/dev/null
. "$here/linux/hub/lib.sh"
out="$(bus_read svc 2>&1)"
has "from=sender@north" "$out" "from=sender@north"
has "...with the text inside the fence" "$out" "hello from afar"

echo "6. a FRAGA does not cross a link — not even to the link owner's own session"
# A FRAGA is answered by MACHINERY out of a catalogue, and the answer goes back
# to the asker as a DRIFT letter. Across a link there is no return route: the
# answering side would have to address <asker>@<us>, a shape no sending hub
# writes and no gate here accepts. The question is therefore refused on arrival
# rather than queued for an answer nobody can deliver. A lookup-and-answer
# protocol across a link is a later addition, deliberately.
err="$(relay svc sender "FRAGA topic: sessioner" 2>&1 >/dev/null)"; rc=$?
is  "to the link owner's own session: rc 65" "$rc" "65"
has "...and it says a FRAGA is answered from a catalogue" "$err" "catalogue"
has "...and that the return route is what is missing"     "$err" "return route"
is  "...and nothing was queued" "$(inbox_count svc)" "0"
err="$(relay other sender "FRAGA topic: sessioner" 2>&1 >/dev/null)"; rc=$?
is  "to another owner's session: rc 65 too" "$rc" "65"
is  "...and nothing was queued"        "$(inbox_count other)" "0"
is  "...and nothing left this machine" "$(wc -c < "$SSH_ARGV" | tr -d ' ')" "0"

echo "6b. EVERY class is owner-gated on arrival: the link reaches its owner's"
echo "    own sessions here and nobody else's"
# The sending gate decides who may USE the link; this one decides whom it may
# REACH. Without it a link owned by alice carried a BESLUT into bob's queue —
# over ssh as bob, into a home this hub cannot otherwise write in — on the word
# of a hub in another estate. The class was never the boundary; the owner is.
err="$(relay other sender "BESLUT topic: an ordinary letter" 2>&1 >/dev/null)"; rc=$?
is  "an ordinary message to another owner's session: rc 65" "$rc" "65"
has "...naming the link's principal"   "$err" "alice"
has "...and the recipient's principal" "$err" "bob"
is  "...and nothing was queued"        "$(inbox_count other)" "0"
is  "...and nothing left this machine" "$(wc -c < "$SSH_ARGV" | tr -d ' ')" "0"
# A row with no OWNER is a row this hub cannot vouch for: broken
# configuration (rc 78, naming the file), not the wrong person (65). Refuse,
# never pass, and never deliver by a guessed home.
printf 'DOMAIN="entity-one"\nHOST="host-one"\nRC_LABEL="L"\nREPO_PATH="/tmp/x"\n' > "$FX/reg/noowner.conf"
err="$(relay noowner sender "BESLUT topic: to a row without an owner" 2>&1 >/dev/null)"; rc=$?
is  "a recipient row without OWNER: rc 78, the broken-row code" "$rc" "78"
has "...and it names the row" "$err" "noowner.conf"
is  "...and nothing was queued" "$(inbox_count noowner)" "0"
rm -f "$FX/reg/noowner.conf"
relay svc sender "BESLUT topic: for the owner" >/dev/null 2>&1; rc=$?
is  "...while the link owner's own session still receives: rc 0" "$rc" "0"
is  "...and it was queued" "$(inbox_count svc)" "1"
is  "...and STILL no sent/ archive on this side" "$(sent_any)" "0"

echo "6c. THE LINK'S OWNER IS A PERSON, MEASURED AS THE PRINCIPAL — the unix account stays where it is"
# OWNER on a session row is the UNIX account: it builds the home the queue is
# written in and the -l the other-home hop logs in as. A link is owned by a
# PERSON, and a person can run under an account that is not their own name (a
# machine's steward account, say). Comparing the link's owner with OWNER made
# "reach the hub over the link" require OWNER=<person> — which moves the hub's
# queue into a home nobody reads. So the gate resolves the row's ACCOUNT to its
# PRINCIPAL, and only after checking that the account really is the row's
# account: USERNAME must be the row's OWNER and HOST the row's HOST, or a row
# could point at somebody else's account and borrow their link.
mkdir -p "$FX/accounts.d"; export STEWARD_ACCOUNT_DIR="$FX/accounts.d"
printf 'PRINCIPAL="ann"\nHOST="host-one"\nUSERNAME="alice"\n' > "$FX/accounts.d/alice-machine.conf"
printf 'PRINCIPAL="ann"\nHOST="host-one"\nUSERNAME="bob"\n'   > "$FX/accounts.d/bob-for-ann.conf"
printf 'PRINCIPAL="ann"\nHOST="host-two"\nUSERNAME="alice"\n' > "$FX/accounts.d/alice-elsewhere.conf"
# the hub's own row: runs as alice (this hub's account), belongs to ann
printf 'OWNER="alice"\nACCOUNT="alice-machine"\nDOMAIN="entity-one"\nHOST="host-one"\nRC_LABEL="L"\nREPO_PATH="/tmp/x"\n' > "$FX/reg/hubrow.conf"
printf 'OWNER="bob"\nACCOUNT="bob-for-ann"\nDOMAIN="entity-one"\nHOST="host-one"\nRC_LABEL="L"\nREPO_PATH="/tmp/x"\n'     > "$FX/reg/annsbob.conf"
printf 'OWNER="bob"\nACCOUNT="alice-machine"\nDOMAIN="entity-one"\nHOST="host-one"\nRC_LABEL="L"\nREPO_PATH="/tmp/x"\n'  > "$FX/reg/borrowed.conf"
printf 'OWNER="alice"\nACCOUNT="alice-elsewhere"\nDOMAIN="entity-one"\nHOST="host-one"\nRC_LABEL="L"\nREPO_PATH="/tmp/x"\n' > "$FX/reg/elsewhere.conf"
printf 'OWNER="alice"\nACCOUNT="ghost"\nDOMAIN="entity-one"\nHOST="host-one"\nRC_LABEL="L"\nREPO_PATH="/tmp/x"\n'          > "$FX/reg/ghostacct.conf"
relay_as() { # <principal> <to> <from> <text>
  local who="$1"; shift; wire "$1" "$2" "$3" | bash "$RELAY" north "$who"
}
: > "$SSH_ARGV"
relay_as ann hubrow sender "BESLUT topic: to the hub over ann's link" >/dev/null 2>&1; rc=$?
is  "ann's link reaches the hub that runs as alice: rc 0" "$rc" "0"
is  "...queued LOCALLY, under the unix account, where it is read" "$(inbox_count hubrow)" "1"
is  "...and nothing left this machine" "$(wc -c < "$SSH_ARGV" | tr -d ' ')" "0"
relay_as ann annsbob sender "BESLUT topic: to ann's session in bob's home" >/dev/null 2>&1; rc=$?
is  "ann's session that runs as bob: rc 0" "$rc" "0"
has "...delivered into bob's home, as bob" "$(cat "$SSH_ARGV")" "-l bob"
: > "$SSH_ARGV"
err="$(relay_as ann borrowed sender "BESLUT topic: borrowed" 2>&1 >/dev/null)"; rc=$?
is  "a row whose ACCOUNT runs as somebody else (USERNAME != OWNER): rc 78" "$rc" "78"
has "...naming the account" "$err" "alice-machine"
is  "...nothing queued" "$(inbox_count borrowed)" "0"
is  "...nothing sent" "$(wc -c < "$SSH_ARGV" | tr -d ' ')" "0"
err="$(relay_as ann elsewhere sender "BESLUT topic: elsewhere" 2>&1 >/dev/null)"; rc=$?
is  "a row whose ACCOUNT lives on another host: rc 78" "$rc" "78"
is  "...nothing queued" "$(inbox_count elsewhere)" "0"
err="$(relay_as ann ghostacct sender "BESLUT topic: ghost" 2>&1 >/dev/null)"; rc=$?
is  "a row whose ACCOUNT does not exist: rc 78, never a fallback to OWNER" "$rc" "78"
has "...naming the account" "$err" "ghost"
is  "...nothing queued" "$(inbox_count ghostacct)" "0"
err="$(relay_as alice hubrow sender "DRIFT topic: alice is the unix name, not the person" 2>&1 >/dev/null)"; rc=$?
is  "the unix account's name is NOT the person: alice's link does not reach ann's hub: rc 65" "$rc" "65"
has "...naming the link's principal" "$err" "alice"
has "...and the recipient's"         "$err" "ann"
is  "...nothing queued" "$(inbox_count hubrow)" "1"
relay_as ann svc sender "DRIFT topic: legacy" >/dev/null 2>&1; rc=$?
is  "a legacy row without ACCOUNT keeps OWNER as its principal: ann's link does not reach alice's: rc 65" "$rc" "65"
rm -f "$FX/reg/hubrow.conf" "$FX/reg/annsbob.conf" "$FX/reg/borrowed.conf" "$FX/reg/elsewhere.conf" "$FX/reg/ghostacct.conf"

echo "7. a name this estate does not have bounces — it is never forwarded onwards"
: > "$SSH_ARGV"
err="$(relay nosuchsession sender "DRIFT topic: x" 2>&1 >/dev/null)"; rc=$?
is  "rc 1, unknown recipient" "$rc" "1"
has "...and it says so" "$err" "unknown recipient"
is  "...and nothing left this machine" "$(wc -c < "$SSH_ARGV" | tr -d ' ')" "0"

echo "8. the envelope guard runs on this side too"
relay svc sender "no envelope here" >/dev/null 2>&1; rc=$?
is "a letter without an envelope: rc 65" "$rc" "65"

echo "9. bus_send refuses a peer sender that no key vouched for"
# Only the forced command can set STEWARD_BUS_PEER_PRINCIPAL, and it takes it from
# the authorized_keys row. Without it the '@' shape is unattributable, and an
# unattributable sender must never be stored as if a link had carried it.
err="$(bus_send svc "sender@north" "DRIFT topic: unvouched" : 2>&1 >/dev/null)"; rc=$?
is  "rc 65" "$rc" "65"
has "...and it says a peer sender needs a link principal" "$err" "link principal"
is  "...and nothing was queued" "$(inbox_count svc)" "1"

echo "10. a silent sender cannot hang the forced command"
fifo="$FX/fifo"; mkfifo "$fifo"
( printf 'svc\n'; sleep 30 ) > "$fifo" &
producer=$!
t0=$SECONDS
( export BUS_RELAY_READ_TIMEOUT=2; bash "$RELAY" north alice < "$fifo" >/dev/null 2>&1 ); rc=$?
dt=$(( SECONDS - t0 ))
kill "$producer" 2>/dev/null
[ "$dt" -lt 10 ] && ok "the relay gave up within the timeout (${dt}s, RT=2)" \
                 || bad "the relay hung on a withheld EOF" "${dt}s"
is "...and failed the call" "$rc" "64"

echo
printf '%s: %d passed, %d failed\n' "$(basename "$0")" "$pass" "$fail"
[ "$fail" -eq 0 ]
