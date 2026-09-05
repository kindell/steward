#!/bin/bash
# test/hub-plumbing.test.sh — group 2 of the hub-library merge: the small bodies.
#
# Three things, each measured in the estate before it was carried here:
#
#   * THE TMUX WRAPPERS USE THE TMUX ON PATH. A Homebrew path was hard-coded as
#     the fallback in four places; on a Linux host every ping then failed
#     SILENTLY, because a ping failure never fails the send - the recipient got
#     mail without being told. bus_tmux_bin is the one place that decides.
#   * THE SWEEPER KEEPS 90 DAYS AND SWEEPS THREE DIRECTORIES. Seven days was not
#     enough to answer "what was decided and by whom", and sent/ and failed/ grew
#     unswept once they existed. The archive is the review material; a sweeper
#     that deletes it is loss, not hygiene.
#   * THE FRAGA FIELDS GO THROUGH THE RESOLVER. A FRAGA at a slug must read
#     exactly the row the send path resolved - never a second interpretation
#     built from the raw name, which for a migrated row is a file that does not
#     exist. Refusal (unknown, ambiguous, broken) becomes rc 1, and the gate on
#     top answers NO - refusal is the default, as before.
set -u
here="$(CDPATH= cd -- "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
pass=0; fail=0
ok()  { pass=$((pass+1)); printf '  ok   %s\n' "$1"; }
bad() { fail=$((fail+1)); printf '  FAIL %s\n     %s\n' "$1" "${2:-}"; }
is()  { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "wanted '$3', got '$2'"; fi; }
has() { case "$2" in *"$3"*) ok "$1" ;; *) bad "$1" "missing '$3' in: $2" ;; esac; }

FX="$(mktemp -d)"; trap 'rm -rf "$FX"' EXIT
mkdir -p "$FX/reg" "$FX/hh/.tmux" "$FX/bin"
export STEWARD_REGISTRY_DIR="$FX/reg"
export STEWARD_BUS_HOME="$FX/bus-home"
export HOME="$FX/hh"
cat > "$FX/estate.conf" <<'EOF'
HUB_SESSION="hub-one"
HUB_HOST="host-one"
TMUX_SOCKET="hub-one.sock"
PING_MSG="[bus] you have mail"
EOF
export STEWARD_ESTATE="$FX/estate.conf"
printf 'OWNER="operator-a"\nDOMAIN="entity-one"\nHOST="host-one"\nRC_LABEL="L"\nREPO_PATH="/tmp/x"\n' > "$FX/reg/legacy.conf"
printf 'ID="s-00000000000000aa"\nSLUG="alpha"\nACCOUNT="operator-a-hub"\nOWNER="operator-a"\nDOMAIN="entity-one"\nHOST="host-one"\nRC_LABEL="L"\nREPO_PATH="/tmp/x"\n' > "$FX/reg/s-00000000000000aa.conf"
printf 'ID="s-00000000000000mm"\nSLUG="machine"\nACCOUNT="operator-c-hub"\nOWNER="operator-c"\nDOMAIN="machine"\nHOST="host-one"\nRC_LABEL=""\nREPO_PATH="/tmp/x"\n' > "$FX/reg/s-00000000000000mm.conf"

# A tmux stub that logs every call. It answers has-session with TMUX_ALIVE and
# capture-pane with PANE_TEXT, like the estate's relay-deliver fixture.
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
chmod 755 "$FX/bin/tmux"
export TMUX_CALLS="$FX/tmux-calls"

# NO REAL SSH FROM A TEST. The estate's suite once delivered a fixture's record into
# a colleague's real home: a row with another OWNER on the same host is an ssh
# boundary to the merged library. Every ssh attempt here is refused and counted;
# the suite ends by asserting there were none.
printf '#!/bin/bash\necho "$*" >> "${SSH_REFUSED:?}"; exit 255\n' > "$FX/ssh-refuse"; chmod 755 "$FX/ssh-refuse"
export STEWARD_BUS_SSH_BIN="$FX/ssh-refuse" SSH_REFUSED="$FX/ssh-refused"; : > "$SSH_REFUSED"
# shellcheck source=/dev/null
. "$here/linux/hub/lib.sh"

echo "1. the tmux wrappers use bus_tmux_bin - the one on PATH, never a literal path"
: > "$TMUX_CALLS"
( export PATH="$FX/bin:$PATH" STEWARD_BUS_TMUX_BIN= TMUX_ALIVE=1
  bus_tmux_has_session s-00000000000000aa; bus_tmux_capture_pane s-00000000000000aa >/dev/null
  bus_tmux_send_keys s-00000000000000aa "[bus] you have mail"; bus_recipient_busy s-00000000000000aa )
is  "four wrappers, five tmux calls (send-keys is two)" "$(wc -l < "$TMUX_CALLS" | tr -d ' ')" "5"
has "has-session over the estate's socket"  "$(sed -n 1p "$TMUX_CALLS")" "-S $FX/hh/.tmux/hub-one.sock has-session -t s-00000000000000aa"
has "capture-pane over the socket"          "$(sed -n 2p "$TMUX_CALLS")" "-S $FX/hh/.tmux/hub-one.sock capture-pane"
has "send-keys: literal text, options closed with --" "$(sed -n 3p "$TMUX_CALLS")" "send-keys -t s-00000000000000aa -l -- [bus] you have mail"
has "send-keys: a separate Enter"           "$(sed -n 4p "$TMUX_CALLS")" "send-keys -t s-00000000000000aa Enter"
# A TEXT THAT BEGINS WITH A DASH is still text: without '--' tmux would read it as
# an option and the ping would fall silently.
: > "$TMUX_CALLS"
( export PATH="$FX/bin:$PATH" STEWARD_BUS_TMUX_BIN=; bus_tmux_send_keys legacy "-x looks like an option" )
has "send-keys ends its options with -- before the text" "$(sed -n 1p "$TMUX_CALLS")" "send-keys -t legacy -l -- -x looks like an option"
: > "$TMUX_CALLS"
( export PATH="$FX/empty" STEWARD_BUS_TMUX_BIN="$FX/bin/tmux" TMUX_ALIVE=1; bus_tmux_has_session legacy )
is "STEWARD_BUS_TMUX_BIN still overrides the PATH lookup" "$(wc -l < "$TMUX_CALLS" | tr -d ' ')" "1"
is "no Homebrew path left in the library's live code" \
   "$(sed 's/#.*//' "$here/linux/hub/lib.sh" | grep -c '/opt/homebrew/bin/tmux')" "1"
has "...and the one occurrence is bus_tmux_bin's last resort (after the PATH lookup)" \
   "$(sed 's/#.*//' "$here/linux/hub/lib.sh" | grep '/opt/homebrew/bin/tmux')" "command -v tmux"

echo "2. the sweeper: 90 days by default, three directories, never the inbox"
old_days() { date -v-"$1"d '+%Y%m%d%H%M' 2>/dev/null || date -d "$1 days ago" '+%Y%m%d%H%M'; }
q="$FX/bus-home/s-00000000000000aa"
mkdir -p "$q/done" "$q/sent" "$q/failed" "$q/inbox"
for d in done sent failed inbox; do
  printf '{}' > "$q/$d/old.json";  touch -t "$(old_days 100)" "$q/$d/old.json"
  printf '{}' > "$q/$d/mid.json";  touch -t "$(old_days 10)"  "$q/$d/mid.json"
  printf '{}' > "$q/$d/new.json"
done
bus_gc
is "default keeps a 10-day entry (the review window is 90 days)" "$(ls "$q/done" | sort | tr '\n' ' ')" "mid.json new.json "
is "default removes a 100-day entry from sent/"   "$(ls "$q/sent"   | sort | tr '\n' ' ')" "mid.json new.json "
is "default removes a 100-day entry from failed/" "$(ls "$q/failed" | sort | tr '\n' ' ')" "mid.json new.json "
is "the inbox is never swept - unread mail is not an archive" "$(ls "$q/inbox" | sort | tr '\n' ' ')" "mid.json new.json old.json "
bus_gc 7
is "an explicit window still works: 7 days removes the 10-day entry" "$(ls "$q/done" | tr '\n' ' ')" "new.json "
is "...in sent/ too" "$(ls "$q/sent" | tr '\n' ' ')" "new.json "

echo "3. the FRAGA fields and the machine-session question go through the resolver"
is "field via slug equals field via ID" "$(bus_fraga_falt alpha OWNER)" "$(bus_fraga_falt s-00000000000000aa OWNER)"
is "field via slug: the value"          "$(bus_fraga_falt alpha OWNER)" "operator-a"
is "field via legacy name"              "$(bus_fraga_falt legacy DOMAIN)" "entity-one"
bus_fraga_falt nobody OWNER >/dev/null 2>&1; rc=$?
is "unknown name: rc 1, the gate above answers no" "$rc" "1"
bus_ar_maskinsession machine && ok "machine session found via its slug (RC_LABEL empty line)" || bad "machine session found via its slug (RC_LABEL empty line)"
bus_ar_maskinsession s-00000000000000mm && ok "...and via its ID" || bad "...and via its ID"
bus_ar_maskinsession alpha && bad "a labelled session is not a machine session" || ok "a labelled session is not a machine session"
bus_ar_maskinsession nobody 2>/dev/null && bad "unknown name is not a machine session" || ok "unknown name is not a machine session"
# THE GATE ON TOP: same owner via slug is allowed, and an unresolvable party refuses.
bus_fraga_tillatet legacy alpha && ok "gate: same owner via slug allowed" || bad "gate: same owner via slug allowed"
bus_fraga_tillatet legacy nobody && bad "gate: unresolvable recipient refused" || ok "gate: unresolvable recipient refused"

echo "z. no test reached a real ssh"
is "ssh was never called" "$(wc -l < "$SSH_REFUSED" | tr -d ' ')" "0"

echo
printf '%s: %d passed, %d failed\n' "$(basename "$0")" "$pass" "$fail"
[ "$fail" -eq 0 ]
