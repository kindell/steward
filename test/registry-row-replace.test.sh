#!/bin/bash
# test/registry-row-replace.test.sh - the in-place twin of the one writer core.
# A row's STATE changes (an invitation is revoked, a team gains a member) and
# registry_row_write refuses a destination that exists, by design. This is the
# other half: same lock, same validation, same readback - and a readback that
# fails puts the PREVIOUS bytes back, because a half-replaced row is worse
# than a refused one.
set -u
here="$(CDPATH= cd -- "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
pass=0; fail=0
ok()  { pass=$((pass+1)); printf '  ok   %s\n' "$1"; }
bad() { fail=$((fail+1)); printf '  FAIL %s\n     %s\n' "$1" "${2:-}"; }
is()  { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "wanted '$3', got '$2'"; fi; }
has() { case "$2" in *"$3"*) ok "$1" ;; *) bad "$1" "missing '$3' in: $2" ;; esac; }
# no_leftovers <label> <dir> - an unquoted glob at the CALL SITE expands (or
# stays literal) before the check ever runs, so the walk happens in here.
# Both the stage and the backup are temporary: a refusal that leaves either
# behind leaves the register's own directory dirty for the next glob.
no_leftovers() {
  local label="$1" dir="$2" f found=""
  for f in "$dir"/.stage.* "$dir"/.backup.*; do [ -e "$f" ] && found="$f"; done
  if [ -z "$found" ]; then ok "$label"; else bad "$label" "unexpectedly exists: $found"; fi
}
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
ROOT="$T/estate"; mkdir -p "$ROOT/entities.d" "$ROOT/estate"
printf 'ESTATE_NAME="fixture"\nDESK_ORIGIN="https://desk.example.test"\n' > "$ROOT/estate/steward.conf"
export STEWARD_ESTATE_ROOT="$ROOT" STEWARD_CONFIG_FILE="$T/no-such-config"
. "$here/lib/registry.sh"
echo "registry-row-replace"

printf 'NAME="Acme"\nMEMBERS="alice"\n' > "$ROOT/entities.d/acme.conf"
always_ok() { return 0; }
always_bad() { return 70; }

registry_entity_replace acme 'NAME="Acme"
MEMBERS="alice bo"
' always_ok; rc=$?
is  "a replace succeeds" "$rc" "0"
has "and the new bytes are on disk" "$(cat "$ROOT/entities.d/acme.conf")" 'MEMBERS="alice bo"'
registry_entity_load acme
is  "and the loader sees them" "$ENTITY_MEMBERS" "alice bo"
is  "the mode is 600" \
    "$(stat -c %a "$ROOT/entities.d/acme.conf" 2>/dev/null || stat -f %Lp "$ROOT/entities.d/acme.conf")" "600"
no_leftovers "a successful replace leaves no stage or backup behind" "$ROOT/entities.d"

registry_entity_replace nosuch 'NAME="X"
MEMBERS="alice"
' always_ok 2>"$T/err"; rc=$?
is  "replacing a row that does not exist is rc 65" "$rc" "65"
has "and says so" "$(cat "$T/err")" "no such"

registry_entity_replace acme 'NAME="Acme"
MEMBERS="alice bo cy"
' always_bad 2>/dev/null; rc=$?
is  "a refusing validator is rc 70" "$rc" "70"
has "and the previous bytes survive" "$(cat "$ROOT/entities.d/acme.conf")" 'MEMBERS="alice bo"'
no_leftovers "a refused validation leaves no stage or backup behind" "$ROOT/entities.d"

# THE VALIDATOR RUNS UNDER THE LOCK, ON THE STAGED BYTES, AND BEFORE THE ROW
# IS VISIBLE. All three are measured from inside the validator itself: any
# one of them broken would let a reader observe a row nobody approved.
saw_lock=""; saw_staged=""; saw_final=""; saw_name=""
watching_ok() {
  [ -d "$ROOT/entities.d/.write.lock" ] && saw_lock="yes"
  saw_name="$(basename "$1")"
  saw_staged="$(cat "$1" 2>/dev/null)"
  saw_final="$(cat "$ROOT/entities.d/acme.conf" 2>/dev/null)"
  return 0
}
registry_entity_replace acme 'NAME="Acme"
MEMBERS="alice bo dee"
' watching_ok; rc=$?
is  "the watched replace succeeds" "$rc" "0"
is  "the lock is held while the validator runs" "$saw_lock" "yes"
has "the validator is handed the STAGED bytes" "$saw_staged" 'MEMBERS="alice bo dee"'
has "under a non-.conf name" "$saw_name" ".stage."
has "and the row on disk is still the previous one" "$saw_final" 'MEMBERS="alice bo"'

# A row the register's OWN loader cannot read must not be published: the
# readback runs under the lock, and the previous content comes back.
registry_entity_replace acme 'MEMBERS="alice bo cy"
' always_ok 2>/dev/null; rc=$?
is  "a row that does not load back is refused" "$rc" "70"
has "and the previous bytes are restored" "$(cat "$ROOT/entities.d/acme.conf")" 'NAME="Acme"'
has "with the previous members" "$(cat "$ROOT/entities.d/acme.conf")" 'MEMBERS="alice bo dee"'
is  "the restored row keeps mode 600" \
    "$(stat -c %a "$ROOT/entities.d/acme.conf" 2>/dev/null || stat -f %Lp "$ROOT/entities.d/acme.conf")" "600"
no_leftovers "a restored row leaves no stage or backup behind" "$ROOT/entities.d"

ln -s "$ROOT/entities.d/acme.conf" "$ROOT/entities.d/link.conf"
registry_entity_replace link 'NAME="X"
MEMBERS="alice"
' always_ok 2>"$T/err"; rc=$?
is  "a symlink destination is refused" "$rc" "65"
has "and names the reason" "$(cat "$T/err")" "symlink"
rm -f "$ROOT/entities.d/link.conf"

registry_entity_replace 'BAD/SLUG' 'NAME="X"
' always_ok 2>/dev/null; rc=$?
is  "an invalid slug is rc 64" "$rc" "64"

# AN UNREADABLE REGISTER IS 78, NEVER A CREATE. The entity dir resolver
# honours STEWARD_ENTITY_DIR, so aiming it at nothing is the shortest way
# to ask this question.
( STEWARD_ENTITY_DIR="$T/no-such-register" \
  registry_entity_replace acme 'NAME="X"
' always_ok ) 2>"$T/err"; rc=$?
is  "an unreadable register is rc 78" "$rc" "78"
has "and names the directory" "$(cat "$T/err")" "no-such-register"

# A LOCK SOMEBODY ELSE HOLDS IS 75, NOT A WAIT FOREVER AND NOT A STEAL.
mkdir "$ROOT/entities.d/.write.lock"
registry_entity_replace acme 'NAME="Acme"
MEMBERS="alice"
' always_ok 2>"$T/err"; rc=$?
is  "a held lock is rc 75" "$rc" "75"
has "and names the lock" "$(cat "$T/err")" ".write.lock"
has "and the row is untouched" "$(cat "$ROOT/entities.d/acme.conf")" 'MEMBERS="alice bo dee"'
rmdir "$ROOT/entities.d/.write.lock"

# The lock is released on every path - a second replace in the same shell must
# not meet a stale lock.
registry_entity_replace acme 'NAME="Acme"
MEMBERS="alice"
' always_ok; rc=$?
is  "a later replace still gets the lock" "$rc" "0"
[ -d "$ROOT/entities.d/.write.lock" ] \
  && bad "the lock is gone after a successful replace" "still there" \
  || ok "the lock is gone after a successful replace"

# A NON-REGULAR FILE UNDER THE ROW'S NAME AT PUBLISH TIME. `mv` is the one
# publish that does NOT refuse a directory: it moves the stage INSIDE it and
# exits 0. The validator runs under the lock and before the publish, so a
# validator that swaps the destination reproduces that race exactly - and
# without a guard the restore moves the backup in there too, chmods the
# DIRECTORY to 0600, and reports "the previous row was restored" over a
# squatted slug with both copies locked inside it.
racing_dir_ok() {
  rm -f "$ROOT/entities.d/acme.conf"
  mkdir -p "$ROOT/entities.d/acme.conf"
  return 0
}
registry_entity_replace acme 'NAME="Acme"
MEMBERS="alice bo"
' racing_dir_ok 2>"$T/err"; rc=$?
is  "a raced non-regular destination is rc 70" "$rc" "70"
case "$(cat "$T/err")" in
  *"was restored"*) bad "and never claims a restore that did not happen" "claimed a restore: $(cat "$T/err")" ;;
  *) ok "and never claims a restore that did not happen" ;;
esac
has "and says what it found" "$(cat "$T/err")" "not a regular file"
is  "and nothing of ours is left inside the raced directory" \
    "$(ls -A "$ROOT/entities.d/acme.conf" 2>/dev/null | wc -l | tr -d ' ')" "0"
is  "and the previous bytes are still readable where the refusal says" \
    "$(sed -n 's/.*previous entity row is at \(.*\), refusing.*/\1/p' "$T/err" | xargs cat | grep -c 'MEMBERS="alice"')" "1"
chmod 700 "$ROOT/entities.d/acme.conf" 2>/dev/null
rm -rf "$ROOT/entities.d/acme.conf"
rm -f "$ROOT"/entities.d/.backup.* "$ROOT"/entities.d/.stage.*
printf 'NAME="Acme"\nMEMBERS="alice"\n' > "$ROOT/entities.d/acme.conf"
chmod 600 "$ROOT/entities.d/acme.conf"

# THE CALLER'S OWN FIXTURE SURVIVES. This suite's own `trap ... EXIT` is what
# cleans up $T; a writer that armed or fired somebody else's EXIT handler
# would have deleted the fixture out from under the run by now.
[ -d "$ROOT/entities.d" ] && ok "the fixture survived every replace" \
  || bad "the fixture survived every replace" "$ROOT/entities.d is gone"

echo "== the digest helper =="
is  "sha256 of the empty string" "$(printf '' | _registry_sha256)" \
    "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
is  "sha256 of a known string" "$(printf 'abc' | _registry_sha256)" \
    "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
mkdir -p "$T/emptybin"
( hash -r 2>/dev/null; PATH="$T/emptybin"; printf 'abc' | _registry_sha256 ) >"$T/out" 2>"$T/err"; rc=$?
is  "no digest tool on PATH is rc 78, never an empty digest" "$rc" "78"
is  "and nothing is printed on stdout" "$(cat "$T/out")" ""
has "and the refusal names what it looked for" "$(cat "$T/err")" "sha256sum"

echo "== the estate names the desk's origin =="
is  "DESK_ORIGIN resolves" "$(registry_desk_origin)" "https://desk.example.test"
printf 'DESK_ORIGIN="http://host-a.example.test:8443"\n' > "$ROOT/estate/steward.conf"
is  "a port is part of the origin" "$(registry_desk_origin)" "http://host-a.example.test:8443"
printf 'DESK_ORIGIN="https://desk.example.test/"\n' > "$ROOT/estate/steward.conf"
registry_desk_origin >/dev/null 2>"$T/err"; rc=$?
is  "a trailing slash is refused, not trimmed" "$rc" "78"
printf 'ESTATE_NAME="fixture"\n' > "$ROOT/estate/steward.conf"
registry_desk_origin >/dev/null 2>"$T/err"; rc=$?
is  "a missing DESK_ORIGIN refuses with 78" "$rc" "78"
has "and names the key" "$(cat "$T/err")" "DESK_ORIGIN"

printf '\n  %d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
