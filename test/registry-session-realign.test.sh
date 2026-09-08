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
has "the receipt names the old host"  "$out" "'h1' -> 'h2'"
is  "OWNER is now the account's username" \
    "$(grep -c '^OWNER="svc-ann"$' "$ROOT/sessions.d/$OLD.conf")" "1"
is  "HOST is now the account's host" \
    "$(grep -c '^HOST="h2"$' "$ROOT/sessions.d/$OLD.conf")" "1"
is  "and neither old value survives anywhere in the row" \
    "$(grep -cE '^OWNER="ann"$|^HOST="h1"$' "$ROOT/sessions.d/$OLD.conf")" "0"
is  "every other field is carried through byte for byte" \
    "$(grep -cE '^ACCOUNT="ann-h2"$|^SLUG="old-one"$|^TARGET_ENTITY="alpha"$|^DOMAIN="alpha"$|^REPO_PATH="/tmp/repo"$|^ASSETS="widget"$|^ID="'"$OLD"'"$' "$ROOT/sessions.d/$OLD.conf")" "7"
has "the conf carries the receipt as a comment for the next reader" \
    "$(cat "$ROOT/sessions.d/$OLD.conf")" "# realigned to account 'ann-h2'"

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

echo "== the refusals =="
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
