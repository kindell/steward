#!/bin/bash
# test/hub-delivery.test.sh — group 4 of the hub-library merge: the send path,
# the read path and the remote delivery, as the UNION of the two libraries.
#
# WHAT THE SEND PATH GUARANTEES (each proven in the estate before it came here):
#   * The queue is keyed on the recipient's ID, whichever name was typed, and the
#     record's .to carries the ID - so the local write and the remote delivery
#     can never disagree about who the recipient is.
#   * A message carries its envelope fields (class, subject, headline).
#   * The sender's archive is written ONLY after a successful delivery.
#   * SAME MACHINE, OTHER HOME. A hub on a shared host has neighbours in the
#     house: sessions live in their owners' homes, homes are 0750, and a queue
#     written in the hub's own home is read by nobody. Delivery then goes AS THE
#     OWNER over ssh to our own host - the same protocol and the same bound key
#     as between machines, because it is the same boundary: another person's home.
#   * The ping goes to the tmux session named by the ID (bus_wake_target).
#
# WHAT THE READ PATH GUARANTEES:
#   * The name guard runs in BOTH directions: an unknown recipient is a loud error
#     (rc 1) - an empty print from a MISSPELLED name cannot be told from "no mail".
#   * The sweep runs BEFORE the loop and even when the inbox is missing: a silent
#     session is exactly the one whose archive is oldest.
#   * The envelope line precedes the record; the text is fenced.
#
# WHAT THE REMOTE DELIVERY GUARANTEES:
#   * Four header lines then JSON to EOF; the remote script is static.
#   * Read timeouts on everything from outside: a half-open connection used to
#     leave the remote side in pipe_read forever.
#   * The remote wake goes over the home's socket, named by that home's estate.
set -u
here="$(CDPATH= cd -- "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
pass=0; fail=0
ok()  { pass=$((pass+1)); printf '  ok   %s\n' "$1"; }
bad() { fail=$((fail+1)); printf '  FAIL %s\n     %s\n' "$1" "${2:-}"; }
is()  { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "wanted '$3', got '$2'"; fi; }
has() { case "$2" in *"$3"*) ok "$1" ;; *) bad "$1" "missing '$3' in: $2" ;; esac; }
count_json() { find "$1" -maxdepth 1 -name '*.json' 2>/dev/null | wc -l | tr -d ' '; }
old_days() { date -v-"$1"d '+%Y%m%d%H%M' 2>/dev/null || date -d "$1 days ago" '+%Y%m%d%H%M'; }

FX="$(mktemp -d)"; trap 'rm -rf "$FX"' EXIT
mkdir -p "$FX/reg" "$FX/hh/.tmux" "$FX/hh/scripts/estate" "$FX/bin"
export STEWARD_REGISTRY_DIR="$FX/reg"
export STEWARD_BUS_HOME="$FX/bus-home"
export HOME="$FX/hh"
export STEWARD_BUS_LOCAL_HOST=host-one
export STEWARD_BUS_SELF_USER=operator-a
cat > "$FX/estate.conf" <<'EOF'
HUB_SESSION="hub-one"
HUB_HOST="host-one"
TMUX_SOCKET="hub-one.sock"
PING_MSG="[bus] you have mail"
EOF
export STEWARD_ESTATE="$FX/estate.conf"
# The "remote" home's estate - read by the remote-side script for its socket name.
printf 'TMUX_SOCKET="hub-one.sock"\n' > "$FX/hh/scripts/estate/steward.conf"

# The rows below name accounts, and a row that names an account the registry
# cannot read is refused (rc 78) wherever the row's PERSON is asked for — the
# peer link's bare-name route asks. So the accounts exist, and agree with the
# rows: same unix name, same host.
mkdir -p "$FX/accounts.d"; export STEWARD_ACCOUNT_DIR="$FX/accounts.d"
printf 'PRINCIPAL="operator-a"\nHOST="host-one"\n' > "$FX/accounts.d/operator-a-hub.conf"
printf 'PRINCIPAL="operator-b"\nHOST="host-one"\n' > "$FX/accounts.d/operator-b-hub.conf"
# NO LINKS: an unknown name must bounce here, not be routed over whatever
# peers.d the machine running this test happens to have. Measured: without the
# pin the suite read the real estate's peers.d and failed on ITS rows.
mkdir -p "$FX/peers.d"; export STEWARD_BUS_PEERS_DIR="$FX/peers.d"
printf 'OWNER="operator-a"\nDOMAIN="entity-one"\nHOST="host-one"\nRC_LABEL="L"\nREPO_PATH="/tmp/x"\n' > "$FX/reg/legacy.conf"
printf 'ID="s-00000000000000aa"\nSLUG="alpha"\nACCOUNT="operator-a-hub"\nOWNER="operator-a"\nDOMAIN="entity-one"\nHOST="host-one"\nRC_LABEL="L"\nREPO_PATH="/tmp/x"\n' > "$FX/reg/s-00000000000000aa.conf"
printf 'ID="s-00000000000000bb"\nSLUG="beta"\nACCOUNT="operator-a-hub"\nOWNER="operator-a"\nDOMAIN="entity-two"\nHOST="host-one"\nRC_LABEL="L"\nREPO_PATH="/tmp/x"\n' > "$FX/reg/s-00000000000000bb.conf"
printf 'ID="s-00000000000000cc"\nSLUG="beta"\nACCOUNT="operator-b-hub"\nOWNER="operator-b"\nDOMAIN="entity-two"\nHOST="host-one"\nRC_LABEL="L"\nREPO_PATH="/tmp/x"\n' > "$FX/reg/s-00000000000000cc.conf"
printf 'ID="s-00000000000000ff"\nSLUG="hub-one"\nACCOUNT="operator-a-hub"\nOWNER="operator-a"\nDOMAIN="machine"\nHOST="host-one"\nRC_LABEL="Hub"\nREPO_PATH="/tmp/x"\n' > "$FX/reg/s-00000000000000ff.conf"
# A neighbour: same host, ANOTHER person's home.
printf 'ID="s-00000000000000ee"\nSLUG="neighbour"\nACCOUNT="operator-b-hub"\nOWNER="operator-b"\nDOMAIN="entity-one"\nHOST="host-one"\nRC_LABEL="L"\nREPO_PATH="/tmp/x"\n' > "$FX/reg/s-00000000000000ee.conf"
# A session on another machine.
printf 'OWNER="operator-b"\nDOMAIN="entity-one"\nHOST="host-two"\nRC_LABEL="L"\nREPO_PATH="/tmp/x"\n' > "$FX/reg/faraway.conf"
# Somebody with a different owner but the same entity - the FRAGA gate's permit.
printf 'OWNER="operator-b"\nDOMAIN="entity-one"\nHOST="host-one"\nRC_LABEL="L"\nREPO_PATH="/tmp/x"\n' > "$FX/reg/colleague.conf"
printf 'OWNER="operator-c"\nDOMAIN="entity-nine"\nHOST="host-one"\nRC_LABEL="L"\nREPO_PATH="/tmp/x"\n' > "$FX/reg/stranger.conf"

# ssh stub: logs its arguments, then runs the LAST argument (the remote script)
# locally with the same stdin - so the remote side really executes, in $HOME.
cat > "$FX/bin/ssh" <<'STUB'
#!/bin/bash
printf '%s\n' "$*" >> "${SSH_CALLS:?}"
cmd=""; for a in "$@"; do cmd="$a"; done
exec bash -c "$cmd"
STUB
# tmux stub for the remote side: logs calls, answers has-session/capture-pane.
cat > "$FX/bin/tmux" <<'STUB'
#!/bin/bash
printf '%s\n' "$*" >> "${TMUX_CALLS:?}"
if [ "$1" = "-S" ]; then shift 2; fi
case "$1" in
  has-session)  [ -n "${TMUX_ALIVE:-}" ] && exit 0 || exit 1 ;;
  capture-pane) printf '%s\n' "${PANE_TEXT:-normal prompt}"; exit 0 ;;
  *) exit 0 ;;
esac
STUB
chmod 755 "$FX/bin/ssh" "$FX/bin/tmux"
export SSH_CALLS="$FX/ssh-calls" TMUX_CALLS="$FX/tmux-calls"
export STEWARD_BUS_SSH_BIN="$FX/bin/ssh" STEWARD_BUS_TMUX_BIN="$FX/bin/tmux"
export PATH="$FX/bin:$PATH"

# shellcheck source=/dev/null
. "$here/linux/hub/lib.sh"
pings="$FX/pings"; recording_ping() { printf '%s\n' "$1" >> "$pings"; }

echo "1. a local send: ID-keyed queue, envelope fields, archive, ping to the wake target"
: > "$pings"
f="$(bus_send alpha legacy "DRIFT topic: a headline" recording_ping)"; rc=$?
is  "rc 0" "$rc" "0"
is  "the file lands in the ID queue, not under the slug" "$(count_json "$FX/bus-home/s-00000000000000aa/inbox")" "1"
is  "no queue under the slug" "$(ls -d "$FX/bus-home/alpha" 2>/dev/null)" ""
rec="$FX/bus-home/s-00000000000000aa/inbox/$f"
is  ".to carries the ID"          "$(jq -r .to "$rec")"    "s-00000000000000aa"
is  ".from is the sender as typed" "$(jq -r .from "$rec")" "legacy"
is  ".klass"  "$(jq -r .klass "$rec")"  "DRIFT"
is  ".amne"   "$(jq -r .amne "$rec")"   "topic"
is  ".rubrik" "$(jq -r .rubrik "$rec")" "a headline"
is  "the sender's archive holds one copy, marked delivered" "$(jq -r .delivered "$(find "$FX/bus-home/legacy/sent" -name '*.json' | head -1)")" "true"
is  "the ping went to the recipient's ID (its tmux name)" "$(cat "$pings")" "s-00000000000000aa"
f2="$(bus_send s-00000000000000aa legacy "DRIFT topic: by id" recording_ping)"
is  "addressing by ID: the same queue" "$(count_json "$FX/bus-home/s-00000000000000aa/inbox")" "2"
: > "$pings"
bus_send hub-one legacy "DRIFT topic: to the hub" recording_ping >/dev/null
is  "the hub's word lands in the hub's ID queue" "$(count_json "$FX/bus-home/s-00000000000000ff/inbox")" "1"
is  "and its ping goes to the hub's ID" "$(cat "$pings")" "s-00000000000000ff"
is  "a legacy recipient: queue under its name, byte-identical to before" \
    "$(bus_send legacy alpha "DRIFT topic: legacy" recording_ping >/dev/null; count_json "$FX/bus-home/legacy/inbox")" "1"

echo "2. refusals write nothing and archive nothing"
before="$(find "$FX/bus-home" -name '*.json' | wc -l | tr -d ' ')"
bus_send nobody legacy "DRIFT topic: x" recording_ping >/dev/null 2>&1; rc=$?
is "unknown recipient: rc 1" "$rc" "1"
err="$(bus_send beta legacy "DRIFT topic: x" recording_ping 2>&1 >/dev/null)"; rc=$?
is  "ambiguous slug: rc 65" "$rc" "65"
has "...naming both rows" "$err" "s-00000000000000cc"
bus_send alpha legacy "no envelope here" recording_ping >/dev/null 2>&1; rc=$?
is "missing envelope: rc 65" "$rc" "65"
is "nothing was written by any refusal" "$(find "$FX/bus-home" -name '*.json' | wc -l | tr -d ' ')" "$before"
# A FRAGA GOES TO THE HUB ONLY (2026-09-08): a session has no machinery to answer
# one, so the same-entity permit of the gate applies to asking the HUB, never to
# asking a colleague's session. Both of these are refused before anything is
# written; the gate itself is proved against the hub in hub-envelope.test.sh.
bus_send colleague legacy "FRAGA status: how" recording_ping >/dev/null 2>&1 && bad "FRAGA: same entity, other person - refused (a FRAGA goes to the hub only)" || ok "FRAGA: same entity, other person - refused (a FRAGA goes to the hub only)"
bus_send stranger legacy "FRAGA status: how" recording_ping >/dev/null 2>&1 && bad "FRAGA: other entity, other person - refused" || ok "FRAGA: other entity, other person - refused"

echo "3. same machine, other home: delivered AS THE OWNER over ssh, then archived"
: > "$SSH_CALLS"; : > "$TMUX_CALLS"
export TMUX_ALIVE=1 PANE_TEXT="normal prompt"
python3 -c 'import socket,sys; socket.socket(socket.AF_UNIX).bind(sys.argv[1])' "$FX/hh/.tmux/hub-one.sock" 2>/dev/null || :
f="$(bus_send neighbour legacy "DRIFT topic: over the fence" recording_ping)"; rc=$?
is  "rc 0" "$rc" "0"
has "ssh ran as the neighbour's owner"   "$(cat "$SSH_CALLS")" "-l operator-b"
has "...to our own host"                 "$(cat "$SSH_CALLS")" " host-one "
is  "nothing was written in the hub's own home for the neighbour" "$(ls -d "$FX/bus-home/s-00000000000000ee" 2>/dev/null)" ""
rem="$FX/hh/.config/agent-bus/s-00000000000000ee/inbox"
is  "the remote side wrote the record under the ID" "$(count_json "$rem")" "1"
is  ".to carries the ID on the remote copy too" "$(jq -r .to "$rem/$f")" "s-00000000000000ee"
is  ".klass survives the wire" "$(jq -r .klass "$rem/$f")" "DRIFT"
has "the remote wake went over the home's socket, named by its estate" "$(cat "$TMUX_CALLS")" "-S $FX/hh/.tmux/hub-one.sock has-session -t s-00000000000000ee"
has "...and typed the registry's ping text" "$(cat "$TMUX_CALLS")" "send-keys -t s-00000000000000ee -l -- [bus] you have mail"
is  "the sender's archive got the copy after success" "$(count_json "$FX/bus-home/legacy/sent")" "4"
unset TMUX_ALIVE

echo "4. another machine: ssh to that host as the owner; a failed delivery is not archived"
: > "$SSH_CALLS"
bus_send faraway legacy "DRIFT topic: far" recording_ping >/dev/null; rc=$?
is  "rc 0" "$rc" "0"
has "ssh went to the recipient's host" "$(cat "$SSH_CALLS")" " host-two "
has "...as its owner"                  "$(cat "$SSH_CALLS")" "-l operator-b"
printf '#!/bin/bash\nexit 1\n' > "$FX/bin/ssh-dead"; chmod 755 "$FX/bin/ssh-dead"
before="$(count_json "$FX/bus-home/legacy/sent")"
STEWARD_BUS_SSH_BIN="$FX/bin/ssh-dead" bus_send faraway legacy "DRIFT topic: lost" recording_ping >/dev/null 2>&1; rc=$?
is "a dead link fails the send"          "$([ "$rc" -ne 0 ] && echo nonzero)" "nonzero"
is "...and nothing is archived for it"   "$(count_json "$FX/bus-home/legacy/sent")" "$before"

echo "4b. a row without OWNER: written locally, refused where an owner is needed"
printf 'DOMAIN="entity-one"\nHOST="host-one"\nRC_LABEL="L"\nREPO_PATH="/tmp/x"\n' > "$FX/reg/ownerless-local.conf"
printf 'DOMAIN="entity-one"\nHOST="host-two"\nRC_LABEL="L"\nREPO_PATH="/tmp/x"\n' > "$FX/reg/ownerless-far.conf"
f="$(bus_send ownerless-local legacy "DRIFT topic: local" recording_ping 2>/dev/null)"; rc=$?
is  "local recipient without OWNER: rc 0" "$rc" "0"
is  "...written in our own bus home" "$(count_json "$FX/bus-home/ownerless-local/inbox")" "1"
bus_send ownerless-far legacy "DRIFT topic: far" recording_ping >/dev/null 2>&1; rc=$?
is  "remote recipient without OWNER: rc 78 - a queue in the wrong home is never read" "$rc" "78"

echo "5. the read path: loud on unknown, ID-keyed, envelope line, fenced text, sweep first"
out="$(bus_read nobody 2>&1)"; rc=$?
is  "unknown recipient: rc 1" "$rc" "1"
has "...and it says so on stderr" "$out" "unknown recipient"
bus_read beta >/dev/null 2>&1; rc=$?
is  "ambiguous slug: rc 65, no inbox guessed" "$rc" "65"
out="$(bus_read alpha 2>/dev/null)"; rc=$?
is  "read via slug: rc 0" "$rc" "0"
has "the envelope line precedes the record" "$(printf '%s\n' "$out" | head -1)" "[DRIFT] topic"
has "the record line"                       "$out" "from=legacy ts="
has "the text is fenced"                    "$out" "  │ DRIFT topic: a headline"
is  "the ID queue is empty afterwards"      "$(count_json "$FX/bus-home/s-00000000000000aa/inbox")" "0"
is  "...and both records are in done/"      "$(count_json "$FX/bus-home/s-00000000000000aa/done")" "2"
# THE SWEEP RUNS BEFORE THE LOOP - proven on the archive, not on the print.
d="$FX/bus-home/s-00000000000000aa/done"; old="$d/ancient.json"; printf '{}' > "$old"; touch -t "$(old_days 200)" "$old"
i="$FX/bus-home/s-00000000000000aa/inbox"; oldmail="$i/1700000000-legacy-9.json"
bus_message_json legacy s-00000000000000aa 1700000000 "DRIFT topic: old but unread" > "$oldmail"; touch -t "$(old_days 200)" "$oldmail"
out="$(bus_read alpha 2>/dev/null)"
is  "a 200-day archive entry is swept by the read"  "$([ -f "$old" ] && echo kept || echo swept)" "swept"
has "an old UNREAD record is still read"            "$out" "old but unread"
is  "...and survives in done/ (sweep before, not after)" "$(ls "$d" | grep -c '1700000000-legacy-9.json')" "1"
old2="$d/ancient-2.json"; printf '{}' > "$old2"; touch -t "$(old_days 200)" "$old2"
STEWARD_BUS_GC_DAYS="" bus_read alpha >/dev/null 2>&1
is  "STEWARD_BUS_GC_DAYS='' turns the sweep off" "$([ -f "$old2" ] && echo kept || echo swept)" "kept"
# EVEN WHEN THE INBOX IS MISSING: the silent session's archive is the oldest one.
printf 'OWNER="operator-a"\nDOMAIN="entity-one"\nHOST="host-one"\nRC_LABEL="L"\nREPO_PATH="/tmp/x"\n' > "$FX/reg/silent.conf"
sd="$FX/bus-home/silent/done"; mkdir -p "$sd"; s_old="$sd/ancient.json"; printf '{}' > "$s_old"; touch -t "$(old_days 200)" "$s_old"
rm -rf "$FX/bus-home/silent/inbox"
bus_read silent >/dev/null 2>&1
is  "the sweep runs for a recipient without an inbox" "$([ -f "$s_old" ] && echo kept || echo swept)" "swept"

echo "6. the remote script reads with timeouts - a half-open connection cannot hang it"
# A producer that sends one header line and then stalls. With a 1 s read
# timeout the remote side must give up on its own within a few seconds.
# The consumer is what is timed, not the producer: with a plain pipe the stub
# would wait for the sleeping producer and measure the wrong process.
cat > "$FX/bin/ssh-stall" <<'STUB'
#!/bin/bash
cmd=""; for a in "$@"; do cmd="$a"; done
bash -c "$cmd" < <( printf 'legacy\n'; sleep 4 )
STUB
chmod 755 "$FX/bin/ssh-stall"
t0=$(date +%s)
BUS_RELAY_READ_TIMEOUT=1 STEWARD_BUS_SSH_BIN="$FX/bin/ssh-stall" bus_remote_deliver host-two legacy alpha "DRIFT topic: stall" operator-b >/dev/null 2>&1; rc=$?
t1=$(date +%s)
is "the stalled delivery fails" "$([ "$rc" -ne 0 ] && echo nonzero)" "nonzero"
is "...within the timeout, not after the producer" "$([ $((t1-t0)) -le 3 ] && echo quick || echo slow)" "quick"

echo
printf '%s: %d passed, %d failed\n' "$(basename "$0")" "$pass" "$fail"
[ "$fail" -eq 0 ]
