#!/bin/bash
# test/registry-session-realign.test.sh - the migration path from the old row
# shape to the one today's writers emit.
#
# WHY IT EXISTS. `registry session add` and `registry migrate-session` wrote
# OWNER as the account's PRINCIPAL and HOST as the estate's HUB_HOST until the
# identity model landed; they write the account's USERNAME and its own HOST
# today. lib/registry.sh reads BOTH shapes on purpose - a reader that refused
# yesterday's rows would take down every session the product wrote itself, and
# only on the estates where USERNAME and PRINCIPAL differ, which are exactly
# the estates the account model exists for. This verb is the other half: how a
# row stops being yesterday's without anybody editing a conf by hand.
#
# WHAT IT MUST NOT DO. It never chooses the ACCOUNT, so it can never move a
# session to another human; it carries every other field through byte for byte;
# and a rewrite that would not load is put back.
set -u
here="$(CDPATH= cd -- "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
pass=0; fail=0
ok()  { pass=$((pass+1)); printf '  ok   %s\n' "$1"; }
bad() { fail=$((fail+1)); printf '  FAIL %s\n     %s\n' "$1" "${2:-}"; }
is()  { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "wanted '$3', got '$2'"; fi; }
has() { case "$2" in *"$3"*) ok "$1" ;; *) bad "$1" "missing '$3' in: $2" ;; esac; }

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
ROOT="$T/estate"
mkdir -p "$ROOT/estate" "$ROOT/sessions.d" "$ROOT/entities.d" "$ROOT/accounts.d" \
         "$ROOT/projects.d" "$ROOT/mcp.d"
cat > "$ROOT/estate/steward.conf" <<'EOF'
ESTATE_NAME="fixture"
LABEL_PREFIX="com.fixture.claude"
RC_LABEL_PREFIX=""
HUB_SESSION="hub"
HUB_HOST="h1"
HUB_SSH="hub@127.0.0.1"
STATE_DIR_NAME="fixture-supervisor"
PAUSED_DIR_NAME="fixture-paused"
TMUX_SOCKET="fixture.sock"
OP_TOKEN_FILE_NAME="fixture-token"
PING_MSG="you have unread mail"
EOF
printf 'NAME="Alpha"\nMEMBERS="ann"\n' > "$ROOT/entities.d/alpha.conf"
# The account whose USERNAME and PRINCIPAL differ, on a host that is not the
# hub - the only shape where the old writers and the new ones disagree at all.
printf 'PRINCIPAL="ann"\nUSERNAME="svc-ann"\nHOST="h2"\n' > "$ROOT/accounts.d/ann-h2.conf"

run() { STEWARD_ESTATE_ROOT="$ROOT" bash "$here/bin/steward" registry session realign "$@"; }

write_old() {
  cat > "$ROOT/sessions.d/$1.conf" <<EOF
# $1 - session
ID="$1"
ACCOUNT="ann-h2"
SLUG="$2"
TARGET_ENTITY="alpha"
DOMAIN="alpha"
HOST="h1"
REPO_PATH="/tmp/repo"
OWNER="ann"
ASSETS="widget"
EOF
}

echo "== the old shape is rewritten, and the receipt says what moved =="
OLD="s-00000000000000b1"
write_old "$OLD" old-one
out="$(run "$OLD" 2>"$T/err")"; rc=$?
is  "rc 0" "$rc" "0"
has "the receipt names the old owner" "$out" "'ann' -> 'svc-ann'"
is  "OWNER is now the account's username" \
    "$(grep -c '^OWNER="svc-ann"$' "$ROOT/sessions.d/$OLD.conf")" "1"
# WHERE THE SESSION LIVES IS NOT PART OF THE SHAPE. lib/registry.sh states that
# a session may run on a host the hub only deploys to, so a HOST that differs
# from the account's is a legitimate row rather than yesterday's shape - and a
# verb that rewrote it would silently relocate a correct session. HOST moves
# only when --host says so.
is  "HOST is left exactly as the row had it" \
    "$(grep -c '^HOST="h1"$' "$ROOT/sessions.d/$OLD.conf")" "1"
case "$out" in
  *HOST*) bad "the receipt does not mention a field that did not move" "got: $out" ;;
  *)      ok  "the receipt does not mention a field that did not move" ;;
esac
is  "the old owner survives nowhere in the row" \
    "$(grep -c '^OWNER="ann"$' "$ROOT/sessions.d/$OLD.conf")" "0"
is  "every other field is carried through byte for byte" \
    "$(grep -cE '^ACCOUNT="ann-h2"$|^SLUG="old-one"$|^TARGET_ENTITY="alpha"$|^DOMAIN="alpha"$|^REPO_PATH="/tmp/repo"$|^ASSETS="widget"$|^ID="'"$OLD"'"$' "$ROOT/sessions.d/$OLD.conf")" "7"
has "the conf carries the receipt as a comment for the next reader" \
    "$(cat "$ROOT/sessions.d/$OLD.conf")" "# realigned to account 'ann-h2'"
# OWNER IS NOT A LABEL. lib/registry.sh derives the home from it, and the log
# path and the op token path from the home - so a login change moves four
# things, and a session already up keeps the ones it started with. The receipt
# is where the next reader of this file finds that out.
has "the receipt says the login change moves the derived paths" \
    "$out" "op-token"
has "and that a running session keeps the old ones until it restarts" \
    "$out" "until it is restarted"
has "and the conf carries that sentence too" \
    "$(cat "$ROOT/sessions.d/$OLD.conf")" "a session already running keeps the old ones"

echo "== the row still loads, and its principal is unchanged =="
OUT="$(export STEWARD_ESTATE_ROOT="$ROOT" STEWARD_REGISTRY_DIR="$ROOT/sessions.d"
  . "$here/lib/registry.sh"
  registry_load "$OLD" >/dev/null 2>&1 || exit $?
  printf '%s' "$(_registry_row_principal "$OLD" 2>/dev/null)")"; lrc=$?
is  "the realigned row loads" "$lrc" "0"
is  "and it still belongs to the same human" "$OUT" "ann"

echo "== a second run changes nothing =="
before="$(cat "$ROOT/sessions.d/$OLD.conf")"
out2="$(run "$OLD" 2>/dev/null)"; rc2=$?
is  "rc 0" "$rc2" "0"
has "and says so" "$out2" "already in the new shape"
is  "the file is byte-identical" "$(cat "$ROOT/sessions.d/$OLD.conf")" "$before"

echo "== the json form reports the change as data =="
NEW="s-00000000000000b2"
write_old "$NEW" old-two
j="$(run "$NEW" --json 2>/dev/null)"; jrc=$?
is  "rc 0"        "$jrc" "0"
is  "ok is true"  "$(printf '%s' "$j" | jq -r .ok)" "true"
is  "changed is true" "$(printf '%s' "$j" | jq -r .changed)" "true"
is  "the previous owner is named" "$(printf '%s' "$j" | jq -r .was.owner)" "ann"
is  "the new owner is named"      "$(printf '%s' "$j" | jq -r .owner)" "svc-ann"
is  "the account is never chosen here, only reported" \
    "$(printf '%s' "$j" | jq -r .account)" "ann-h2"
is  "changedFields names OWNER and nothing else" \
    "$(printf '%s' "$j" | jq -rc .changedFields)" '["OWNER"]'
is  "and HOST is reported unchanged on both sides" \
    "$(printf '%s' "$j" | jq -r '.was.host + "/" + .host')" "h1/h1"

# A CORRECT ROW WITH A DIFFERING HOST IS NOT A ROW TO FIX. This is the state
# the loader calls legitimate and warns about: OWNER already the account's
# username, HOST somewhere the hub only deploys to. Before this rule the
# product recommended realign for it and realign moved the session.
echo "== a correct row on another host is left byte-identical =="
REMOTE="s-00000000000000b4"
cat > "$ROOT/sessions.d/$REMOTE.conf" <<EOF
# $REMOTE - session
ID="$REMOTE"
ACCOUNT="ann-h2"
SLUG="remote-one"
TARGET_ENTITY="alpha"
DOMAIN="alpha"
HOST="h9"
REPO_PATH="/tmp/repo"
OWNER="svc-ann"
EOF
remote_before="$(cat "$ROOT/sessions.d/$REMOTE.conf")"
rout="$(run "$REMOTE" 2>/dev/null)"; rrc=$?
is  "rc 0" "$rrc" "0"
has "and it says there was nothing to write" "$rout" "already in the new shape"
is  "the conf is byte-identical afterwards" \
    "$(cat "$ROOT/sessions.d/$REMOTE.conf")" "$remote_before"

# THE VERIFY STEP READS THE FIELD BACK, NOT JUST THE RETURN CODE, so what the
# receipt claims and what the next loader will read are the same value. The awk
# rewrite drops any OWNER line after the first, so a conf cannot come out of it
# carrying two - which is what makes this an assertion rather than a fix, and
# why the case below is a row that is rewritten normally.
echo "== the value the receipt reports is the value the loader reads back =="
TWO="s-00000000000000b5"
cat > "$ROOT/sessions.d/$TWO.conf" <<EOF
# $TWO - session
ID="$TWO"
ACCOUNT="ann-h2"
SLUG="two-owner"
TARGET_ENTITY="alpha"
DOMAIN="alpha"
HOST="h1"
REPO_PATH="/tmp/repo"
OWNER="svc-ann"
OWNER="ann"
EOF
tj="$(run "$TWO" --json 2>/dev/null)"; trc=$?
is  "a row carrying two OWNER lines still realigns" "$trc" "0"
is  "the receipt reports the new login"             "$(printf '%s' "$tj" | jq -r .owner)" "svc-ann"
is  "exactly one OWNER line survives the rewrite" \
    "$(grep -c '^OWNER=' "$ROOT/sessions.d/$TWO.conf")" "1"
is  "and the loader reads the value the receipt reported" \
    "$(export STEWARD_ESTATE_ROOT="$ROOT" STEWARD_REGISTRY_DIR="$ROOT/sessions.d"
       . "$here/lib/registry.sh"; registry_load "$TWO" >/dev/null 2>&1 && printf '%s' "$OWNER")" \
    "svc-ann"
is  "and no backup or staging file is left behind" "$(ls "$ROOT/sessions.d" | grep -c realign)" "0"
rm -f "$ROOT/sessions.d/$TWO.conf"

echo "== --host is the one way to restate where a session lives =="
hout="$(run "$REMOTE" --host h7 2>/dev/null)"; hrc=$?
is  "rc 0" "$hrc" "0"
has "the receipt names the host that moved" "$hout" "HOST 'h9' -> 'h7'"
case "$hout" in
  *OWNER*) bad "and does not claim OWNER moved" "got: $hout" ;;
  *)       ok  "and does not claim OWNER moved" ;;
esac
is  "the row now says the host that was asked for" \
    "$(grep -c '^HOST="h7"$' "$ROOT/sessions.d/$REMOTE.conf")" "1"
is  "the owner is untouched" \
    "$(grep -c '^OWNER="svc-ann"$' "$ROOT/sessions.d/$REMOTE.conf")" "1"
jh="$(run "$REMOTE" --host h5 --json 2>/dev/null)"
is  "changedFields names HOST alone" \
    "$(printf '%s' "$jh" | jq -rc .changedFields)" '["HOST"]'
is  "and the row still loads after a host restatement" \
    "$(STEWARD_ESTATE_ROOT="$ROOT" STEWARD_REGISTRY_DIR="$ROOT/sessions.d" bash -c '
        . "'"$here"'/lib/registry.sh"; registry_load "'"$REMOTE"'" >/dev/null 2>&1; echo $?')" "0"

echo "== the refusals =="
out="$(run "$REMOTE" --host 'Not A Host' 2>&1 >/dev/null)"; rc=$?
is  "an invalid --host is a usage error" "$rc" "64"
has "and names the value"                "$out" "Not A Host"
out="$(run "$REMOTE" --host 2>&1 >/dev/null)"; rc=$?
is  "a --host with no value is a usage error" "$rc" "64"
out="$(run "$REMOTE" --bogus 2>&1 >/dev/null)"; rc=$?
is  "an unknown flag is a usage error" "$rc" "64"

out="$(run 2>&1 >/dev/null)"; rc=$?
is  "no handle is a usage error" "$rc" "64"
has "and says what is missing"   "$out" "needs a session handle"

out="$(run nosuch 2>&1 >/dev/null)"; rc=$?
is  "an unknown session refuses"  "$rc" "78"
has "and names it"                "$out" "nosuch"

# A LEGACY ROW HAS NO ACCOUNT TO ALIGN TO. Realigning it would mean choosing a
# human for it, and that is `migrate-session`'s decision, made with a flag.
printf 'OWNER="ann"\nHOST="h1"\nDOMAIN="alpha"\nRC_LABEL="L"\nREPO_PATH="/tmp/repo"\n' \
  > "$ROOT/sessions.d/legacy.conf"
out="$(run legacy 2>&1 >/dev/null)"; rc=$?
is  "a row with no ACCOUNT refuses rather than guessing a person" "$rc" "65"
has "and points at the verb that does choose one" "$out" "migrate-session"

printf 'ID="s-00000000000000b3"\nACCOUNT="gone"\nSLUG="x"\nTARGET_ENTITY="alpha"\nDOMAIN="alpha"\nHOST="h1"\nREPO_PATH="/tmp/repo"\nOWNER="ann"\n' \
  > "$ROOT/sessions.d/s-00000000000000b3.conf"
out="$(run s-00000000000000b3 2>&1 >/dev/null)"; rc=$?
is  "a row whose account does not load refuses" "$rc" "78"

printf '\n%s: %s passed, %s failed\n' "$(basename "$0")" "$pass" "$fail"
[ "$fail" -eq 0 ]
