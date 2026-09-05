#!/bin/bash
# test/hub-relay.test.sh — the hub's receiving side: bus-relay-in and
# bus-relay-deliver, and whether the forced-command path behaves EXACTLY like
# the inline script in lib.sh:bus_remote_deliver.
#
# bus-relay-deliver exists so the hub can deliver bus messages into ANOTHER
# PERSON'S account without getting a shell there. It is deliberately a copy of the
# inline script - and two copies drift apart. So BOTH are run against the same
# input and the outcomes compared. The inline path runs through the real client
# with STEWARD_BUS_SSH_BIN stubbed to a script that executes the command locally:
# not an imitation of the inline script, the script itself.
#
# bus-relay-in is the other forced command: the sender's identity comes from the
# authorized_keys line, never from the message.
set -uo pipefail
here="$(CDPATH= cd -- "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
pass=0; fail=0
ok()  { pass=$((pass+1)); printf '  ok   %s\n' "$1"; }
bad() { fail=$((fail+1)); printf '  FAIL %s\n     %s\n' "$1" "${2:-}"; }
is()  { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "wanted '$3', got '$2'"; fi; }
has() { case "$2" in *"$3"*) ok "$1" ;; *) bad "$1" "missing '$3' in: $2" ;; esac; }
DELIVER="$here/linux/hub/bin/bus-relay-deliver"
RELAY_IN="$here/linux/hub/bin/bus-relay-in"

setup() {
  T="$(mktemp -d)"
  mkdir -p "$T/hh/scripts/estate" "$T/bin" "$T/reg"
  # The home's socket name comes from the home's deployed estate, as in a real home.
  printf 'TMUX_SOCKET="hub-one.sock"\n' > "$T/hh/scripts/estate/steward.conf"
  printf 'HOST="far-host"\nOWNER="somebody"\nREPO_PATH="/tmp/x"\nRC_LABEL="L"\nDOMAIN="entity-one"\n' > "$T/reg/recipient.conf"
  cat > "$T/estate.conf" <<'EOF'
HUB_SESSION="hub-one"
HUB_HOST="host-one"
TMUX_SOCKET="hub-one.sock"
PING_MSG="[bus] you have mail"
EOF
  # tmux stub: logs every call (including a leading -S), answers has-session with
  # TMUX_ALIVE and capture-pane with PANE_TEXT.
  cat > "$T/bin/tmux" <<'STUB'
#!/bin/bash
printf '%s\n' "$*" >> "${TMUX_CALLS:?}"
if [ "$1" = "-S" ]; then shift 2; fi
case "$1" in
  has-session)  [ -n "${TMUX_ALIVE:-}" ] && exit 0 || exit 1 ;;
  capture-pane) printf '%s\n' "${PANE_TEXT:-normal prompt}"; exit 0 ;;
  send-keys)    shift; printf '%s\n' "$*" >> "${SENDKEYS:?}"; exit 0 ;;
  *) exit 0 ;;
esac
STUB
  # ssh stub: the last argument is the command - run it locally with the same stdin.
  cat > "$T/bin/ssh" <<'STUB'
#!/bin/bash
cmd=""; for a in "$@"; do cmd="$a"; done
exec bash -c "$cmd"
STUB
  chmod +x "$T/bin/tmux" "$T/bin/ssh"
  export TMUX_CALLS="$T/tmux-calls" SENDKEYS="$T/sendkeys"; : > "$TMUX_CALLS"; : > "$SENDKEYS"
}
teardown() { rm -rf "$T"; }
feed() { # <recipient> - four header lines then JSON, exactly what bus_remote_deliver pipes
  printf '%s\n%s\n%s\n%s\n' "$1" "1700000000" "hub-one" "[bus] you have mail"
  printf '{"from":"hub-one","to":"%s","ts":1700000000,"text":"DRIFT topic: hello"}' "$1"
}
run_forced() { ( export HOME="$T/hh" PATH="$T/bin:$PATH"; feed "$1" | bash "$DELIVER" >/dev/null 2>&1 ); }
run_inline() {
  ( export HOME="$T/hh" PATH="$T/bin:$PATH" STEWARD_BUS_SSH_BIN="$T/bin/ssh" \
           STEWARD_REGISTRY_DIR="$T/reg" STEWARD_ESTATE="$T/estate.conf" BUS_KLASS=
    . "$here/linux/hub/lib.sh" >/dev/null 2>&1
    bus_remote_deliver far-host "$1" hub-one "DRIFT topic: hello" somebody >/dev/null 2>&1 )
}
queue_count() { find "$T/hh/.config/agent-bus/$1/inbox" -name '*.json' 2>/dev/null | wc -l | tr -d ' '; }

echo "1. both paths deliver, to the same place"
setup; run_forced recipient; is "forced: the record landed" "$(queue_count recipient)" "1"; teardown
setup; run_inline recipient; is "inline: the record landed" "$(queue_count recipient)" "1"; teardown

echo "2. SAME CONTENT - two copies must not drift apart"
# Compared as PARSED json, not bytes: in production both paths get identical stdin,
# but the test feeds the forced path by hand. ts is normalised: the inline path
# stamps date +%s while the fixture carries a fixed value.
setup; run_forced recipient; a="$(jq -S -c '.ts="X"' "$T/hh/.config/agent-bus/recipient/inbox/"*.json 2>/dev/null)"; teardown
setup; run_inline recipient; b="$(jq -S -c '.ts="X"' "$T/hh/.config/agent-bus/recipient/inbox/"*.json 2>/dev/null)"; teardown
[ -n "$a" ] && is "forced and inline wrote the same record" "$a" "$b" || bad "forced wrote nothing to compare"

echo "3. the recipient name becomes a path - traversal is refused"
setup; run_forced "../../etc"
[ -e "$T/hh/.config/agent-bus/../../etc" ] && bad "path traversal got through" || ok "path traversal refused"
run_forced "Recipient"; is "upper case is refused (enumeration, not a range)" "$(queue_count Recipient)" "0"
teardown

echo "4. the ping: only when the session is idle, and over the home's socket"
setup; python3 -c 'import socket,sys; socket.socket(socket.AF_UNIX).bind(sys.argv[1])' "$T/hh/.tmux/hub-one.sock" 2>/dev/null || { mkdir -p "$T/hh/.tmux"; python3 -c 'import socket,sys; socket.socket(socket.AF_UNIX).bind(sys.argv[1])' "$T/hh/.tmux/hub-one.sock"; }
( export TMUX_ALIVE=1 PANE_TEXT="normal prompt"; run_forced recipient )
has "idle session is pinged with the header's ping text" "$(cat "$SENDKEYS")" "[bus] you have mail"
has "forced: has-session over the home's socket" "$(cat "$TMUX_CALLS")" "-S $T/hh/.tmux/hub-one.sock has-session -t recipient"
has "forced: send-keys over the home's socket"   "$(cat "$TMUX_CALLS")" "-S $T/hh/.tmux/hub-one.sock send-keys"
: > "$TMUX_CALLS"; : > "$SENDKEYS"
( export TMUX_ALIVE=1 PANE_TEXT="normal prompt"; run_inline recipient )
has "inline: has-session over the home's socket" "$(cat "$TMUX_CALLS")" "-S $T/hh/.tmux/hub-one.sock has-session -t recipient"
: > "$SENDKEYS"
( export TMUX_ALIVE=1 PANE_TEXT="thinking... esc to interrupt"; run_forced recipient )
is "a WORKING session is never typed into" "$(cat "$SENDKEYS")" ""
teardown
setup
( export TMUX_ALIVE=1 PANE_TEXT="normal prompt"; run_forced recipient )
grep -q -- '-S' "$TMUX_CALLS" && bad "without the home's socket -S was still passed" "$(cat "$TMUX_CALLS")" || ok "without the home's socket: the default server, no -S"
has "...and the ping still went out" "$(cat "$SENDKEYS")" "you have mail"
teardown

echo "5. two deliveries, two files - atomic names, no overwrite"
setup; run_forced recipient; run_forced recipient; is "second delivery did not overwrite the first" "$(queue_count recipient)" "2"; teardown

echo "6. a half-open connection cannot hang the forced command"
# Four header lines, then SILENCE with no EOF - what a dropped link looks like.
setup
fifo="$T/fifo"; mkfifo "$fifo"
( printf 'recipient\n1700000000\nhub-one\n[bus] x\n'; sleep 30 ) > "$fifo" &
producer=$!
t0=$SECONDS
( export HOME="$T/hh" PATH="$T/bin:$PATH" BUS_RELAY_READ_TIMEOUT=2
  bash "$DELIVER" < "$fifo" >/dev/null 2>&1 )
dt=$(( SECONDS - t0 ))
kill "$producer" 2>/dev/null
[ "$dt" -lt 10 ] && ok "the relay gave up within the timeout (${dt}s, RT=2)" || bad "the relay hung on a withheld EOF" "${dt}s"
teardown

echo "7. bus-relay-in: the sender is the KEY's identity, never the message's"
setup
mkdir -p "$T/reg2"
printf 'OWNER="somebody"\nDOMAIN="entity-one"\nHOST="host-one"\nRC_LABEL="L"\nREPO_PATH="/tmp/x"\n' > "$T/reg2/inbound.conf"
out="$( printf 'inbound\nDRIFT topic: report from afar\n' | \
        STEWARD_REGISTRY_DIR="$T/reg2" STEWARD_ESTATE="$T/estate.conf" STEWARD_BUS_HOME="$T/bus-home" \
        STEWARD_BUS_LOCAL_HOST=host-one STEWARD_BUS_SELF_USER=somebody \
        bash "$RELAY_IN" far-machine 2>&1 )"; rc=$?
is  "relay-in: rc 0" "$rc" "0"
f="$(find "$T/bus-home/inbound/inbox" -name '*.json' 2>/dev/null | head -1)"
[ -n "$f" ] && ok "the record landed at the recipient" || bad "the record landed at the recipient" "$out"
is  "the sender is the key's identity"  "$(jq -r .from "$f" 2>/dev/null)" "far-machine"
is  "the text is intact"                "$(jq -r .text "$f" 2>/dev/null)" "DRIFT topic: report from afar"
printf '' | STEWARD_REGISTRY_DIR="$T/reg2" STEWARD_ESTATE="$T/estate.conf" STEWARD_BUS_HOME="$T/bus-home" bash "$RELAY_IN" far-machine >/dev/null 2>&1; rc=$?
is  "empty stdin: rc 64" "$rc" "64"
printf 'inbound\n' | STEWARD_REGISTRY_DIR="$T/reg2" STEWARD_ESTATE="$T/estate.conf" STEWARD_BUS_HOME="$T/bus-home" bash "$RELAY_IN" far-machine >/dev/null 2>&1; rc=$?
is  "recipient but no text: rc 64" "$rc" "64"
bash "$RELAY_IN" </dev/null >/dev/null 2>&1; rc=$?
[ "$rc" -ne 0 ] && ok "no identity argument: refused" || bad "no identity argument: refused"
teardown

echo
printf '%s: %d passed, %d failed\n' "$(basename "$0")" "$pass" "$fail"
[ "$fail" -eq 0 ]
