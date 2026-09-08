#!/bin/bash
# test/hub-envelope.test.sh — the envelope and the parking guard, ported from the
# estate's suite before the estate's copy of the library dies.
#
# THE ENVELOPE IS THE FIRST LINE: `CLASS subject: headline`. A human should see
# what a message IS before reading it, and the subject is the thread key. The
# parser refuses (rc 65) anything else, and bus_send refuses without it and writes
# nothing.
#
# THE SLUG GUARD IS LOCALE-INDEPENDENT. A glob range `[!a-z0-9-]` follows
# collation, and in a UTF-8 collation the upper case sits INSIDE a-z: the same
# code accepted "BESLUT Pii: r" in en_US.UTF-8 and refused it in C. The whole
# suite was green with the fault in place. So the guard is an enumeration, and
# this suite checks the SOURCE for a range as well as the behaviour in a
# collation-sensitive locale when the machine has one.
#
# THE PARKING GUARD: a subject on the list refuses (65); a MISSING list parks
# nothing; an UNREADABLE list is no answer at all (70) - guessing "not parked"
# when one cannot know is delivering in exactly the state where one cannot know
# that one may. Every spelling of the list counts (no final newline, CRLF,
# surrounding whitespace). And DRIFT cannot be parked: it never reaches a human,
# so parking it silences a watch, never noise.
set -u
here="$(CDPATH= cd -- "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
pass=0; fail=0
ok()  { pass=$((pass+1)); printf '  ok   %s\n' "$1"; }
bad() { fail=$((fail+1)); printf '  FAIL %s\n     %s\n' "$1" "${2:-}"; }
is()  { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "wanted '$3', got '$2'"; fi; }
has() { case "$2" in *"$3"*) ok "$1" ;; *) bad "$1" "missing '$3' in: $2" ;; esac; }

FX="$(mktemp -d)"; trap 'chmod -R u+rwX "$FX" 2>/dev/null; rm -rf "$FX"' EXIT
mkdir -p "$FX/reg" "$FX/hh"
export STEWARD_REGISTRY_DIR="$FX/reg" HOME="$FX/hh"

# No links: this suite never routes over the machine's real peers.d.
mkdir -p "$FX/peers.d"; export STEWARD_BUS_PEERS_DIR="$FX/peers.d"
export STEWARD_BUS_LOCAL_HOST=host-one STEWARD_BUS_SELF_USER=operator-a
cat > "$FX/estate.conf" <<'EOF'
HUB_SESSION="hub-one"
HUB_HOST="host-one"
TMUX_SOCKET="hub-one.sock"
PING_MSG="[bus] you have mail"
EOF
export STEWARD_ESTATE="$FX/estate.conf"
printf 'HOST="host-one"\nOWNER="operator-a"\nDOMAIN="entity-one"\nRC_LABEL="L"\nREPO_PATH="/tmp/x"\n' > "$FX/reg/rcpt.conf"
# NO REAL SSH FROM A TEST - refused and counted; the suite ends by asserting none.
printf '#!/bin/bash\necho "$*" >> "${SSH_REFUSED:?}"; exit 255\n' > "$FX/ssh-refuse"; chmod 755 "$FX/ssh-refuse"
export STEWARD_BUS_SSH_BIN="$FX/ssh-refuse" SSH_REFUSED="$FX/ssh-refused"; : > "$SSH_REFUSED"
noop_ping() { :; }

# shellcheck source=/dev/null
. "$here/linux/hub/lib.sh"

echo "1. parsing"
u="$(bus_envelope_parse "BESLUT some-topic: a headline here")"; rc=$?
is "a valid envelope: rc 0" "$rc" "0"
is "class"    "$(printf '%s\n' "$u" | sed -n 1p)" "BESLUT"
is "subject"  "$(printf '%s\n' "$u" | sed -n 2p)" "some-topic"
is "headline" "$(printf '%s\n' "$u" | sed -n 3p)" "a headline here"
u="$(bus_envelope_parse "FYND deploy: the gate does not gate itself
line two
line three")"
is "multi-line: only the first line is the envelope" "$(printf '%s\n' "$u" | sed -n 3p)" "the gate does not gate itself"
for k in BESLUT FYND SAMORDNING DRIFT FRAGA; do
  bus_envelope_parse "$k topic: headline" >/dev/null 2>&1 && ok "class $k is accepted" || bad "class $k is accepted"
done

echo "2. the refusal paths"
for case_ in "no class at all" "MADEUP topic: headline" "BESLUT Under_score: headline" "BESLUT Upper: headline" "BESLUT UPPER: headline" "BESLUT topic headline without colon" "DRIFT topic:" "DRIFT topic:    " "DRIFT topic: 	"; do
  u="$(bus_envelope_parse "$case_" 2>&1)"; rc=$?
  is  "refused rc 65: '$case_'" "$rc" "65"
  has "...and the refusal mentions the envelope" "$u" "envelope"
done

echo "3. the slug guard is an enumeration, not a collation range"
slug_line="$(awk '/^bus_envelope_parse\(\)/,/^}/' "$here/linux/hub/lib.sh" | grep -E '\|\*\[!' || true)"
[ -n "$slug_line" ] && ok "the slug guard has a negated character class" || bad "the slug guard has a negated character class"
case "$slug_line" in
  *a-z*|*A-Z*|*0-9*) bad "the slug guard uses a collation range" "$slug_line" ;;
  *) ok "the slug guard enumerates its characters" ;;
esac
coll_loc=""
for L in en_US.UTF-8 en_US.utf8 sv_SE.UTF-8 sv_SE.utf8 de_DE.UTF-8; do
  if LC_ALL="$L" bash -c 'case A in [a-z]) exit 0 ;; esac; exit 1' 2>/dev/null; then coll_loc="$L"; break; fi
done
if [ -n "$coll_loc" ]; then
  ( export LC_ALL="$coll_loc"; . "$here/linux/hub/lib.sh"; bus_envelope_parse "BESLUT Upper: r" >/dev/null 2>&1 ); rc=$?
  is "in a collation-sensitive locale ($coll_loc) upper case is still refused" "$rc" "65"
else
  ok "(no collation-sensitive locale on this machine - the static check above carries the weight)"
fi

echo "4. bus_send refuses without an envelope, and writes nothing"
export STEWARD_BUS_HOME="$FX/bus-home"
bus_send rcpt sender "no envelope here" noop_ping >/dev/null 2>&1; rc=$?
is "without envelope: rc 65" "$rc" "65"
is "nothing written" "$(find "$FX/bus-home" -name '*.json' 2>/dev/null | wc -l | tr -d ' ')" "0"
f="$(bus_send rcpt sender "DRIFT topic: a headline" noop_ping 2>/dev/null)"; rc=$?
is "with envelope: rc 0" "$rc" "0"
is "class in the record"    "$(jq -r .klass  "$FX/bus-home/rcpt/inbox/$f")" "DRIFT"
is "subject in the record"  "$(jq -r .amne   "$FX/bus-home/rcpt/inbox/$f")" "topic"
is "headline in the record" "$(jq -r .rubrik "$FX/bus-home/rcpt/inbox/$f")" "a headline"

echo "5. the parking guard"
park() { # <list-printf-format> <text> -> rc, in a fresh bus home
  rm -rf "$FX/bh"; mkdir -p "$FX/bh"
  [ -n "$1" ] && printf "$1" > "$FX/bh/parkerade"
  ( export STEWARD_BUS_HOME="$FX/bh"; bus_send rcpt sender "$2" noop_ping >"$FX/out" 2>"$FX/err" ); echo $?
}
written() { find "$FX/bh/rcpt/inbox" -name '*.json' 2>/dev/null | wc -l | tr -d ' '; }
is  "a parked subject: rc 65"            "$(park '# parked\nsome-topic\n\nother\n' "FYND some-topic: news")" "65"
has "...the refusal names the subject"   "$(cat "$FX/err")" "some-topic"
has "...and says it is parked"           "$(cat "$FX/err")" "parked"
is  "...and nothing was written"         "$(written)" "0"
is  "an unparked subject passes: rc 0"   "$(park 'some-topic\n' "FYND another: news")" "0"
is  "a missing list parks nothing: rc 0" "$(park '' "FYND some-topic: news")" "0"

echo "6. every spelling of the list counts"
for spec in 'trailing newline|topic-x\n|65' 'NO trailing newline|topic-x|65' 'CRLF|topic-x\r\n|65' 'CRLF without newline|topic-x\r|65' 'leading blanks|  topic-x\n|65' 'trailing blanks|topic-x   \n|65' 'tabs around|\ttopic-x\t\n|65' 'last of several, no newline|other\npii\ntopic-x|65' 'a substring is no match|topic-x-b\n|0' 'a prefix is no match|topic\n|0' 'a comment line is no subject|# topic-x\n|0' 'an empty list parks nothing|\n\n|0'; do
  label="${spec%%|*}"; rest="${spec#*|}"; fmt="${rest%|*}"; want="${rest##*|}"
  is "$label: rc $want" "$(park "$fmt" "FYND topic-x: headline")" "$want"
done

echo "7. an unreadable list is NO answer - rc 70, nothing sent, and the error says what to fix"
rm -rf "$FX/bh"; mkdir -p "$FX/bh/parkerade"
( export STEWARD_BUS_HOME="$FX/bh"; bus_send rcpt sender "FYND topic-y: headline" noop_ping >/dev/null 2>"$FX/err" ); rc=$?
is  "the list is a DIRECTORY: rc 70" "$rc" "70"
is  "...nothing written" "$(written)" "0"
has "...the error names the file"          "$(cat "$FX/err")" "$FX/bh/parkerade"
has "...and says nothing is sent"          "$(cat "$FX/err")" "NOTHING IS SENT"
if [ "$(id -u)" -ne 0 ]; then
  rm -rf "$FX/bh"; mkdir -p "$FX/bh"; printf 'x\n' > "$FX/bh/parkerade"; chmod 000 "$FX/bh/parkerade"
  ( export STEWARD_BUS_HOME="$FX/bh"; bus_send rcpt sender "FYND topic-y: headline" noop_ping >/dev/null 2>&1 ); rc=$?
  is "the list is mode 000: rc 70" "$rc" "70"
  chmod 644 "$FX/bh/parkerade"
else
  ok "(running as root - the mode-000 case is skipped; the directory case covers the branch)"
fi

echo "8. DRIFT cannot be parked - a list must never silence a watch"
is  "DRIFT on a parked subject goes through: rc 0" "$(park 'unacked-mail\nmalformed\n' "DRIFT unacked-mail: AUTO-ALERT")" "0"
is  "FYND on the same subject is still parked: rc 65" "$(park 'unacked-mail\n' "FYND unacked-mail: same subject, other class")" "65"
rm -rf "$FX/bh"; mkdir -p "$FX/bh/parkerade"
( export STEWARD_BUS_HOME="$FX/bh"; bus_send rcpt sender "DRIFT unacked-mail: the alert goes through" noop_ping >/dev/null 2>&1 ); rc=$?
is  "DRIFT goes through even when the list is unreadable" "$rc" "0"
( export STEWARD_BUS_HOME="$FX/bh"; bus_send rcpt sender "FYND anything: stopped by an unreadable list" noop_ping >/dev/null 2>&1 ); rc=$?
is  "FYND is stopped by the unreadable list: rc 70" "$rc" "70"
call="$(awk '/^bus_send\(\)/,/^}/' "$here/linux/hub/lib.sh" | grep -F 'bus_parked ')"
has "the class is passed to bus_parked as an ARGUMENT, not read from an inherited export" "$call" '"$BUS_KLASS"'

echo "9. a FRAGA goes to the hub only"
# The fixture's estate names hub-one as the hub; give it a row so it resolves.
printf 'HOST="host-one"\nOWNER="operator-a"\nDOMAIN="entity-one"\nRC_LABEL="H"\nREPO_PATH="/tmp/h"\nID="hub-one"\nSLUG="hub-one"\n' > "$FX/reg/hub-one.conf"
# The sender needs a row too: the hub's own FRAGA gate (same person or domain) runs after this guard.
printf 'HOST="host-one"\nOWNER="operator-a"\nDOMAIN="entity-one"\nRC_LABEL="S"\nREPO_PATH="/tmp/s"\nID="sender"\nSLUG="sender"\n' > "$FX/reg/sender.conf"
fraga() { ( export STEWARD_BUS_HOME="$FX/bh9"; bus_send "$1" sender "$2" noop_ping >"$FX/out" 2>"$FX/err" ); echo $?; }
written9() { find "$FX/bh9" -name '*.json' 2>/dev/null | wc -l | tr -d ' '; }
is  "a FRAGA to a session: rc 65"                "$(fraga rcpt 'FRAGA topic: status')" "65"
has "...and the refusal says where a FRAGA goes" "$(cat "$FX/err")" "hub only"
has "...and names the recipient it refused"      "$(cat "$FX/err")" "rcpt"
is  "...and nothing was written"                 "$(written9)" "0"
is  "a FRAGA to the hub by its word: rc 0"       "$(fraga hub-one 'FRAGA topic: status')" "0"
is  "a SAMORDNING to a session still passes"     "$(fraga rcpt 'SAMORDNING topic: a question for a person')" "0"
is  "a DRIFT to a session still passes"          "$(fraga rcpt 'DRIFT topic: news')" "0"
# A FRAGA TO THE HUB FROM A DIFFERENT PERSON, DIFFERENT ENTITY: the hub's own
# FRAGA gate (bus_fraga_tillatet) refuses it on the send path, and the refusal
# states the rule in the same words as the answerer's own (bus-fraga-svar).
printf 'HOST="host-one"\nOWNER="operator-z"\nDOMAIN="entity-nine"\nRC_LABEL="O"\nREPO_PATH="/tmp/o"\nID="outsider"\nSLUG="outsider"\n' > "$FX/reg/outsider.conf"
( export STEWARD_BUS_HOME="$FX/bh9"; bus_send hub-one outsider 'FRAGA topic: status' noop_ping >/dev/null 2>"$FX/err9" ); rc9=$?
is  "a FRAGA to the hub from a different person and entity: refused" "$rc9" "1"
has "...and the refusal states the PERSON rule" "$(cat "$FX/err9")" "same PERSON (the account's principal"
rm -f "$FX/reg/outsider.conf"
rm -f "$FX/reg/hub-one.conf"
is  "a FRAGA when the hub has no row: rc 65 (no guess)" "$(fraga rcpt 'FRAGA topic: status')" "65"
rm -f "$FX/reg/sender.conf"

echo "z. no test reached a real ssh"
is "ssh was never called" "$(wc -l < "$SSH_REFUSED" | tr -d ' ')" "0"

echo
printf '%s: %d passed, %d failed\n' "$(basename "$0")" "$pass" "$fail"
[ "$fail" -eq 0 ]
