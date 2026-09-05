#!/bin/bash
# test/hub-answerer.test.sh — bus-fraga-svar: FRAGA is answered by machinery,
# never by silence, and only with what the estate's catalogue allows.
#
# THE ALLOWLIST IS DATA. Which scripts may answer is written in the catalogue's
# header (#!allow ...); the product enforces only the form - the command starts
# with the allowed program and one listed script, and carries no chaining. A
# catalogue without the line, or a line that is not read-only, refuses the WHOLE
# run: a partial answer from a broken catalogue is a silent subset.
#
# THE GATE IS AUTHORITATIVE HERE. The send path refuses a forbidden FRAGA in the
# sender's client; the answerer refuses it where the answer is produced - and a
# refusal ANSWERS, so the asker learns the rule instead of seeing "idle".
#
# AN UNKNOWN QUESTION IS LEFT for the model. Acknowledging it would delete it.
set -u
here="$(CDPATH= cd -- "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
pass=0; fail=0
ok()  { pass=$((pass+1)); printf '  ok   %s\n' "$1"; }
bad() { fail=$((fail+1)); printf '  FAIL %s\n     %s\n' "$1" "${2:-}"; }
is()  { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "wanted '$3', got '$2'"; fi; }
has() { case "$2" in *"$3"*) ok "$1" ;; *) bad "$1" "missing '$3' in: $2" ;; esac; }
ANSWERER="$here/linux/hub/bin/bus-fraga-svar"

FX="$(mktemp -d)"; trap 'rm -rf "$FX"' EXIT
mkdir -p "$FX/reg" "$FX/bin" "$FX/hh"
export STEWARD_REGISTRY_DIR="$FX/reg" STEWARD_BUS_HOME="$FX/bus-home" HOME="$FX/hh"
export STEWARD_BUS_LOCAL_HOST=host-one STEWARD_BUS_SELF_USER=operator-a
cat > "$FX/estate.conf" <<'EOF'
HUB_SESSION="hub-one"
HUB_HOST="host-one"
TMUX_SOCKET="hub-one.sock"
PING_MSG="[bus] you have mail"
EOF
export STEWARD_ESTATE="$FX/estate.conf"
# tmux stub: no session anywhere, so pings are silent no-ops.
printf '#!/bin/bash\nexit 1\n' > "$FX/bin/tmux"; chmod 755 "$FX/bin/tmux"; export STEWARD_BUS_TMUX_BIN="$FX/bin/tmux"
# ssh stub: a reply to somebody in ANOTHER home goes as that owner over ssh - the
# stub runs the remote script locally, so it lands under $HOME/.config/agent-bus.
printf '#!/bin/bash\ncmd=""; for a in "$@"; do cmd="$a"; done\nexec bash -c "$cmd"\n' > "$FX/bin/ssh"; chmod 755 "$FX/bin/ssh"
export STEWARD_BUS_SSH_BIN="$FX/bin/ssh"; export PATH="$FX/bin:$PATH"
# The hub: a migrated row (opaque ID, SLUG = the estate's HUB_SESSION).
printf 'ID="s-00000000000000ff"\nSLUG="hub-one"\nACCOUNT="operator-a-hub"\nOWNER="operator-a"\nDOMAIN="machine"\nHOST="host-one"\nRC_LABEL="Hub"\nREPO_PATH="/tmp/x"\n' > "$FX/reg/s-00000000000000ff.conf"
# An asker with the same owner (allowed), and a stranger (other owner, other entity).
printf 'OWNER="operator-a"\nDOMAIN="entity-one"\nHOST="host-one"\nRC_LABEL="L"\nREPO_PATH="/tmp/x"\n' > "$FX/reg/asker.conf"
printf 'OWNER="operator-z"\nDOMAIN="entity-nine"\nHOST="host-one"\nRC_LABEL="L"\nREPO_PATH="/tmp/x"\n' > "$FX/reg/stranger.conf"
# Tools the catalogue may name.
printf '#!/bin/bash\necho "probe says: all is well"\n' > "$FX/probe.sh"
printf '#!/bin/bash\necho "one port is open"\nexit 3\n' > "$FX/finding.sh"
printf '#!/bin/bash\necho "should never run"\n' > "$FX/other.sh"
chmod 755 "$FX"/*.sh
HUB_Q="$FX/bus-home/s-00000000000000ff/inbox"; HUB_D="$FX/bus-home/s-00000000000000ff/done"
ask() { # <from> <headline-word> [subject]  - put a FRAGA in the hub's ID queue
  mkdir -p "$HUB_Q"
  . "$here/linux/hub/lib.sh"
  bus_message_json "$1" s-00000000000000ff "$(date +%s)" "FRAGA ${3:-status}: $2 please" > "$HUB_Q/$(date +%s)-$1-$$-$RANDOM.json"
}
answers() { find "$FX/bus-home/$1/inbox" -name '*.json' 2>/dev/null | wc -l | tr -d ' '; }
reply_text() { jq -r .text "$(find "$FX/bus-home/$1/inbox" -name '*.json' | sort | tail -1)"; }
run() { STEWARD_FRAGA_KATALOG="${CAT:-$FX/catalogue}" bash "$ANSWERER" "$@" 2>"$FX/err"; }

cat > "$FX/catalogue" <<EOF
# a test catalogue
#!allow probe.sh finding.sh
status|/usr/bin/env bash $FX/probe.sh
finding|/usr/bin/env bash $FX/finding.sh
unlisted|/usr/bin/env bash $FX/other.sh
chained|/usr/bin/env bash $FX/probe.sh; rm -rf /
EOF

echo "1. an allowed question is answered mechanically, in the same subject, and acknowledged"
rm -rf "$FX/bus-home"; ask asker status topic
out="$(run hub-one)"; rc=$?
is  "rc 0" "$rc" "0"
has "the run reports one answer" "$out" "1 answered"
is  "the asker got a reply" "$(answers asker)" "1"
has "the reply carries the same subject and names the question" "$(reply_text asker)" "DRIFT topic: answer to FRAGA status"
has "the reply carries the tool's output" "$(reply_text asker)" "probe says: all is well"
has "the reply says no model was involved" "$(reply_text asker)" "no model involved"
is  "the question was acknowledged (moved to done/)" "$(find "$HUB_D" -name '*.json' | wc -l | tr -d ' ')" "1"
is  "the hub's queue is empty" "$(find "$HUB_Q" -name '*.json' 2>/dev/null | wc -l | tr -d ' ')" "0"

echo "2. the recipient may be the hub's ID, its slug, or nothing at all (= the hub)"
rm -rf "$FX/bus-home"; ask asker status; run s-00000000000000ff >/dev/null; is "by ID: answered" "$(answers asker)" "1"
rm -rf "$FX/bus-home"; ask asker status; run >/dev/null;                    is "no argument: the hub's word from the registry, answered" "$(answers asker)" "1"

echo "3. a non-zero exit is reported as a possible finding, never swallowed as an error"
rm -rf "$FX/bus-home"; ask asker finding
run hub-one >/dev/null
has "the reply carries the exit code"  "$(reply_text asker)" "exited with rc 3"
has "...and names both readings"       "$(reply_text asker)" "FINDING as well as an error"
has "...and the output itself"         "$(reply_text asker)" "one port is open"

echo "4. an unknown question is LEFT for the model, and the run says so"
rm -rf "$FX/bus-home"; ask asker weather
out="$(run hub-one)"
has "the run reports it left" "$out" "1 left for the model"
is  "the question stays in the queue" "$(find "$HUB_Q" -name '*.json' | wc -l | tr -d ' ')" "1"
is  "no reply was sent" "$(answers asker)" "0"

echo "5. the gate: a stranger's question is REFUSED - with an answer that names the rule"
rm -rf "$FX/bus-home"; ask stranger status
out="$(run hub-one)"
has "the run reports one refusal" "$out" "1 refused"
# The stranger lives in another account, so the reply travelled as that owner.
remote="$FX/hh/.config/agent-bus/stranger/inbox"
is  "the stranger got a reply - in ITS home, delivered as its owner" "$(find "$remote" -name '*.json' 2>/dev/null | wc -l | tr -d ' ')" "1"
has "the reply names the rule" "$(jq -r .text "$(find "$remote" -name '*.json' | head -1)")" "same OWNER, or same DOMAIN"
is  "the question was acknowledged - it was answered" "$(find "$HUB_D" -name '*.json' | wc -l | tr -d ' ')" "1"

echo "6. the allowlist is the catalogue's data, and the form is enforced"
rm -rf "$FX/bus-home"; ask asker unlisted
run hub-one >/dev/null; rc=$?
is  "a script not on the allow line: the whole run refuses, rc 78" "$rc" "78"
has "...saying which line"       "$(cat "$FX/err")" "not a read-only command"
is  "...and nothing was answered" "$(answers asker)" "0"
rm -rf "$FX/bus-home"; ask asker chained
run hub-one >/dev/null; rc=$?
is  "a chained command: rc 78 even though the script is allowed" "$rc" "78"
sed 's/^#!allow.*$/# (no allow line)/' "$FX/catalogue" > "$FX/catalogue-noallow"
rm -rf "$FX/bus-home"; ask asker status
CAT="$FX/catalogue-noallow" run hub-one >/dev/null; rc=$?
is  "no #!allow line: rc 78, nothing guessed" "$rc" "78"
has "...and it says what is missing" "$(cat "$FX/err")" "#!allow"
is  "...and nothing was answered" "$(answers asker)" "0"
CAT="$FX/does-not-exist" run hub-one >/dev/null; rc=$?
is  "a missing catalogue: rc 78" "$rc" "78"

echo "7. where the catalogue is found: the variable first, then beside the library"
rm -rf "$FX/bus-home"; ask asker status
mkdir -p "$FX/deployed/bin"; cp "$here/linux/hub/lib.sh" "$FX/deployed/lib.sh"; cp "$ANSWERER" "$FX/deployed/bin/bus-fraga-svar"
mkdir -p "$FX/deployed/lib"; ln -sf "$here/lib/registry.sh" "$FX/deployed/lib/registry.sh"
cp "$FX/catalogue" "$FX/deployed/fraga-katalog"
( unset STEWARD_FRAGA_KATALOG; STEWARD_REGISTRY_LIB="$here/lib/registry.sh" bash "$FX/deployed/bin/bus-fraga-svar" hub-one >/dev/null 2>&1 ); rc=$?
is  "beside the library in the deployed layout: rc 0" "$rc" "0"
is  "...and answered from it" "$(answers asker)" "1"

echo
printf '%s: %d passed, %d failed\n' "$(basename "$0")" "$pass" "$fail"
[ "$fail" -eq 0 ]
