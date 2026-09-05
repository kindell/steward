#!/bin/bash
# test/hub-resolve.test.sh — the hub library's resolution layer, carried over
# from the estate's bus library where it was written and proven (2026-09-05).
#
# WHY IT EXISTS. The queue is keyed on a session's ID, never on the name the
# sender typed. For every legacy row (file name == ID) that is byte-identical
# to before; a MIGRATED row (file name = opaque ID, SLUG= + ACCOUNT=) is
# addressed by its slug and lands in <bus home>/<ID>/inbox. One resolver, one
# place: the gate, the delivery and the reader must never read different rows
# for the same name.
#
# THE REFUSALS ARE THE POINT. An ambiguous slug is never chosen silently (two
# people's sessions may share it) — rc 65 naming the rows AND the accounts. A
# row carrying SLUG without ID is broken and an ID is never guessed for it. An
# invalid name never reaches the file system: '*' would be a glob over the
# whole registry.
#
# Also here: the message builder (one builder, every caller), the sender's
# archive, the hub's own name and the wake target — all pure additions to
# this library, each specified before it was wired into a caller.
set -u
here="$(CDPATH= cd -- "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
pass=0; fail=0
ok()  { pass=$((pass+1)); printf '  ok   %s\n' "$1"; }
bad() { fail=$((fail+1)); printf '  FAIL %s\n     %s\n' "$1" "${2:-}"; }
is()  { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "wanted '$3', got '$2'"; fi; }
has() { case "$2" in *"$3"*) ok "$1" ;; *) bad "$1" "missing '$3' in: $2" ;; esac; }

FX="$(mktemp -d)"; trap 'rm -rf "$FX"' EXIT
mkdir -p "$FX/sessions.d" "$FX/hh/.tmux" "$FX/bin"
export STEWARD_REGISTRY_DIR="$FX/sessions.d"
export STEWARD_BUS_HOME="$FX/bus-home"
export HOME="$FX/hh"

cat > "$FX/estate.conf" <<'EOF'
RC_LABEL_PREFIX="Fixture: "
HUB_SESSION="hub-one"
HUB_HOST="host-one"
TMUX_SOCKET="hub-one.sock"
PING_MSG="[bus] you have mail"
EOF
export STEWARD_ESTATE="$FX/estate.conf"

row() { printf '%s\n' "$@" > "$FX/sessions.d/$1.conf"; }
# Legacy row without an ID line: the file name IS the id (same fallback as
# registry_load's `: "${ID:=$project}"`).
printf 'OWNER="operator-a"\nDOMAIN="entity-one"\nHOST="host-one"\nRC_LABEL="L"\nREPO_PATH="/tmp/x"\n' \
  > "$FX/sessions.d/legacy.conf"
# Legacy row WITH an ID line (ID == file name).
printf 'ID="with-id"\nOWNER="operator-a"\nDOMAIN="entity-one"\nHOST="host-one"\nRC_LABEL="L"\nREPO_PATH="/tmp/x"\n' \
  > "$FX/sessions.d/with-id.conf"
# Migrated row: file name = opaque ID, SLUG + ACCOUNT.
printf 'ID="s-00000000000000aa"\nSLUG="alpha"\nACCOUNT="operator-a-hub"\nOWNER="operator-a"\nDOMAIN="entity-one"\nHOST="host-one"\nRC_LABEL="L"\nREPO_PATH="/tmp/x"\n' \
  > "$FX/sessions.d/s-00000000000000aa.conf"
# Two rows sharing a slug on different accounts — the ambiguity that must never
# be chosen silently.
printf 'ID="s-00000000000000bb"\nSLUG="beta"\nACCOUNT="operator-a-hub"\nOWNER="operator-a"\nDOMAIN="entity-two"\nHOST="host-one"\nRC_LABEL="L"\nREPO_PATH="/tmp/x"\n' \
  > "$FX/sessions.d/s-00000000000000bb.conf"
printf 'ID="s-00000000000000cc"\nSLUG="beta"\nACCOUNT="operator-b-hub"\nOWNER="operator-b"\nDOMAIN="entity-two"\nHOST="host-one"\nRC_LABEL="L"\nREPO_PATH="/tmp/x"\n' \
  > "$FX/sessions.d/s-00000000000000cc.conf"
# New-form row MISSING its ID — broken; an id is never guessed for it.
printf 'SLUG="gamma"\nACCOUNT="operator-a-hub"\nOWNER="operator-a"\nDOMAIN="entity-one"\nHOST="host-one"\nRC_LABEL="L"\nREPO_PATH="/tmp/x"\n' \
  > "$FX/sessions.d/s-00000000000000dd.conf"
# The hub's own row: opaque ID, SLUG = the estate's HUB_SESSION.
printf 'ID="s-00000000000000ff"\nSLUG="hub-one"\nACCOUNT="operator-a-hub"\nOWNER="operator-a"\nDOMAIN="machine"\nHOST="host-one"\nRC_LABEL="Hub"\nREPO_PATH="/tmp/x"\n' \
  > "$FX/sessions.d/s-00000000000000ff.conf"

# shellcheck source=/dev/null
. "$here/linux/hub/lib.sh"

echo "1. resolution: exact name"
bus_resolve_recipient legacy && ok "legacy row resolves" || bad "legacy row resolves"
is "legacy: ID is the file name"        "${BUS_RES_ID:-}"   "legacy"
is "legacy: conf is the exact file"     "${BUS_RES_CONF:-}" "$FX/sessions.d/legacy.conf"
bus_resolve_recipient with-id && ok "row with ID line resolves" || bad "row with ID line resolves"
is "ID line is read from the row"       "${BUS_RES_ID:-}"   "with-id"
bus_resolve_recipient s-00000000000000aa && ok "migrated row resolves on its exact ID" || bad "migrated row resolves on its exact ID"
is "exact ID: queue key is the ID"      "${BUS_RES_ID:-}"   "s-00000000000000aa"

echo "2. resolution: slug"
bus_resolve_recipient alpha && ok "unique slug resolves" || bad "unique slug resolves"
is "slug: ID comes from the matched row"   "${BUS_RES_ID:-}"   "s-00000000000000aa"
is "slug: conf is the matched row"         "${BUS_RES_CONF:-}" "$FX/sessions.d/s-00000000000000aa.conf"

echo "3. ambiguous slug: refusal that names rows and accounts"
err="$(bus_resolve_recipient beta 2>&1)"; rc=$?
is  "ambiguous slug: rc 65" "$rc" "65"
has "refusal names the first row"    "$err" "s-00000000000000bb"
has "refusal names the second row"   "$err" "s-00000000000000cc"
has "refusal names the first account"  "$err" "operator-a-hub"
has "refusal names the second account" "$err" "operator-b-hub"
bus_resolve_recipient beta 2>/dev/null
is "ambiguous slug: no conf chosen" "${BUS_RES_CONF:-}" ""

echo "4. a SLUG row without ID is refused, never guessed"
bus_resolve_recipient s-00000000000000dd 2>/dev/null; rc=$?
is "missing ID on a new-form row: rc 65" "$rc" "65"
bus_resolve_recipient gamma 2>/dev/null && bad "slug hit on a row without ID must not resolve" || ok "slug hit on a row without ID must not resolve"

echo "5. an invalid name never reaches the file system as a pattern"
bus_resolve_recipient '*' 2>/dev/null && bad "'*' must not resolve" || ok "'*' must not resolve"
is "'*' chose no conf (never reached the scan)" "${BUS_RES_CONF:-}" ""
bus_resolve_recipient '../legacy' 2>/dev/null && bad "'../' must not resolve" || ok "'../' must not resolve"
bus_resolve_recipient 'ALPHA' 2>/dev/null && bad "upper case is an invalid form" || ok "upper case is an invalid form"
bus_resolve_recipient '' 2>/dev/null && bad "empty name must not resolve" || ok "empty name must not resolve"
bus_resolve_recipient nobody 2>/dev/null; rc=$?
is "unknown name: rc 1 (unknown, not refused)" "$rc" "1"

echo "6. the form filter in the scan: a junk-named conf cannot poison a slug"
printf 'ID="s-00000000000000ee"\nSLUG="alpha"\nACCOUNT="mallory-hub"\nOWNER="mallory"\n' > "$FX/sessions.d/UPPER.Weird.conf"
bus_resolve_recipient alpha 2>/dev/null && ok "junk-named conf does not make 'alpha' ambiguous" || bad "junk-named conf does not make 'alpha' ambiguous"
is "form filter: the real row was still chosen" "${BUS_RES_ID:-}" "s-00000000000000aa"
rm -f "$FX/sessions.d/UPPER.Weird.conf"

echo "7. one message builder, every caller"
u="$(bus_message_json snd rcv 1700000000 "hello" '{}')"; rc=$?
is "builder: rc 0" "$rc" "0"
is "from" "$(printf '%s' "$u" | jq -r .from)" "snd"
is "to"   "$(printf '%s' "$u" | jq -r .to)"   "rcv"
is "ts is a number" "$(printf '%s' "$u" | jq -r '.ts|type')" "number"
is "text" "$(printf '%s' "$u" | jq -r .text)" "hello"
# THE DEFAULT WAS BROKEN ONCE: `${5:-\{\}}` yields the literal string `\{\}`
# and jq answers rc 70. The signature promises a default, so it is proven.
u="$(bus_message_json snd rcv 1700000000 "hello")"; rc=$?
is "builder without extra: rc 0" "$rc" "0"
is "builder without extra: no extra fields" "$(printf '%s' "$u" | jq -r 'keys|join(",")')" "from,text,to,ts"
u="$(bus_message_json snd rcv 1700000000 "hello" "")"; rc=$?
is "builder with empty extra: rc 0" "$rc" "0"
u="$(bus_message_json snd rcv 1700000000 "hello" '{"delivered":true}')"
is "extra: delivered" "$(printf '%s' "$u" | jq -r .delivered)" "true"
u="$(bus_message_json snd rcv 1700000000 "hello" '{}')"
is "without the flag the field is absent" "$(printf '%s' "$u" | jq -r 'has("not_a_secret")')" "false"

echo "8. extra flags come from the envelope globals and two switches"
is "no envelope, no switches: empty object" "$(BUS_KLASS= STEWARD_BUS_NOT_A_SECRET= bus_extra_flags)" "{}"
f="$(BUS_KLASS=DRIFT BUS_AMNE=topic BUS_RUBRIK="a heading" bus_extra_flags)"
is "class field"   "$(printf '%s' "$f" | jq -r .klass)"  "DRIFT"
is "subject field" "$(printf '%s' "$f" | jq -r .amne)"   "topic"
is "heading field" "$(printf '%s' "$f" | jq -r .rubrik)" "a heading"
is "not_a_secret switch" "$(BUS_KLASS= STEWARD_BUS_NOT_A_SECRET=1 bus_extra_flags | jq -r .not_a_secret)" "true"
is "delivered switch"    "$(BUS_KLASS= STEWARD_BUS_NOT_A_SECRET= bus_extra_flags delivered | jq -r .delivered)" "true"

echo "9. the hub's own name is a registry value"
is "bus_hub_word reads HUB_SESSION" "$(bus_hub_word)" "hub-one"
( STEWARD_ESTATE="$FX/missing.conf" bus_hub_word >/dev/null 2>&1 ); rc=$?
is "without an estate bus_hub_word refuses, rc 78" "$rc" "78"

echo "10. the wake target translates the hub's WORD to its ID, nothing else"
is "hub word -> hub ID"        "$(bus_wake_target hub-one)" "s-00000000000000ff"
is "other targets pass through" "$(bus_wake_target legacy)" "legacy"
is "an ID passes through"       "$(bus_wake_target s-00000000000000aa)" "s-00000000000000aa"
is "without an estate the target falls open (mail is durable, the watch re-pings)" \
   "$(STEWARD_ESTATE="$FX/missing.conf" bus_wake_target hub-one)" "hub-one"

echo "11. the local host is measured, with an override for tests"
is "STEWARD_BUS_LOCAL_HOST wins" "$(STEWARD_BUS_LOCAL_HOST=host-x bus_local_host)" "host-x"
printf '#!/bin/sh\necho stub-host\n' > "$FX/bin/hostname"; chmod 755 "$FX/bin/hostname"
is "otherwise hostname -s" "$(PATH="$FX/bin:$PATH" STEWARD_BUS_LOCAL_HOST= bus_local_host)" "stub-host"

echo "12. tmux is the one on PATH"
printf '#!/bin/sh\n' > "$FX/bin/tmux"; chmod 755 "$FX/bin/tmux"
is "STEWARD_BUS_TMUX_BIN wins" "$(STEWARD_BUS_TMUX_BIN=/x/tmux bus_tmux_bin)" "/x/tmux"
is "otherwise the tmux on PATH" "$(PATH="$FX/bin" STEWARD_BUS_TMUX_BIN= bus_tmux_bin)" "$FX/bin/tmux"
is "last resort when PATH has none: the launchd-era path" "$(PATH="$FX/empty" STEWARD_BUS_TMUX_BIN= bus_tmux_bin)" "/opt/homebrew/bin/tmux"

echo "13. the sender's archive follows the sender's ID and never blocks"
bus_archive_sent alpha legacy "DRIFT topic: sent copy"; rc=$?
is "archive: rc 0" "$rc" "0"
is "archive lands under the sender's ID, not its slug" \
   "$(find "$FX/bus-home/s-00000000000000aa/sent" -name '*.json' 2>/dev/null | wc -l | tr -d ' ')" "1"
is "no archive under the slug" "$(ls -d "$FX/bus-home/alpha" 2>/dev/null)" ""
a="$(find "$FX/bus-home/s-00000000000000aa/sent" -name '*.json' | head -1)"
is "archived copy carries delivered=true" "$(jq -r .delivered "$a")" "true"
is "archived copy carries the recipient as typed" "$(jq -r .to "$a")" "legacy"
bus_archive_sent unknown-sender legacy "DRIFT topic: x"; rc=$?
is "an unregistered sender archives under its own name" \
   "$(find "$FX/bus-home/unknown-sender/sent" -name '*.json' 2>/dev/null | wc -l | tr -d ' ')" "1"
bus_archive_sent "" legacy "DRIFT topic: x"; rc=$?
is "empty sender: nothing written, rc 0" "$rc" "0"

echo
printf '%s: %d passed, %d failed\n' "$(basename "$0")" "$pass" "$fail"
[ "$fail" -eq 0 ]
