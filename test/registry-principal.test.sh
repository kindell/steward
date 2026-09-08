#!/bin/bash
# test/registry-principal.test.sh - principals.d: one row per human, one
# tailnet login per row, and the login lookup that the desk gate depends on.
set -u
here="$(CDPATH= cd -- "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
pass=0; fail=0
ok()  { pass=$((pass+1)); printf '  ok   %s\n' "$1"; }
bad() { fail=$((fail+1)); printf '  FAIL %s\n     %s\n' "$1" "${2:-}"; }
is()  { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "wanted '$3', got '$2'"; fi; }
has() { case "$2" in *"$3"*) ok "$1" ;; *) bad "$1" "missing '$3' in: $2" ;; esac; }
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
ROOT="$T/estate"; mkdir -p "$ROOT/principals.d" "$ROOT/estate"
printf 'ESTATE_NAME="fixture"\n' > "$ROOT/estate/steward.conf"
export STEWARD_ESTATE_ROOT="$ROOT" STEWARD_CONFIG_FILE="$T/no-such-config"
. "$here/lib/registry.sh"
echo "registry-principal"

printf 'NAME="Ann"\nTAILSCALE_LOGIN="a@example.com"\nDESK_READ_ALL="yes"\n' > "$ROOT/principals.d/a.conf"
printf 'NAME="Ben"\nTAILSCALE_LOGIN="b@example.com"\n' > "$ROOT/principals.d/b.conf"
printf 'NAME="Broken"\n' > "$ROOT/principals.d/broken.conf"

registry_principal_load a; rc=$?
is  "a valid row loads" "$rc" "0"
is  "and exposes the login" "$PRINCIPAL_TAILSCALE_LOGIN" "a@example.com"
is  "and read-all" "$PRINCIPAL_DESK_READ_ALL" "yes"
registry_principal_load b
is  "read-all defaults to empty" "$PRINCIPAL_DESK_READ_ALL" ""
registry_principal_load broken 2>"$T/err"; rc=$?
is  "a row without a login is refused" "$rc" "1"
has "and says which field" "$(cat "$T/err")" "TAILSCALE_LOGIN"
is  "a refused load leaves nothing behind" "$PRINCIPAL_NAME" ""

is  "the login lookup finds the row" "$(registry_principal_for_login a@example.com)" "a"
registry_principal_for_login nobody@example.com >/dev/null 2>&1; rc=$?
is  "an unknown login is rc 1" "$rc" "1"
is  "and the lookup is case-insensitive on the login" "$(registry_principal_for_login A@EXAMPLE.COM)" "a"
printf 'NAME="Ann2"\nTAILSCALE_LOGIN="a@example.com"\n' > "$ROOT/principals.d/a2.conf"
registry_principal_for_login a@example.com >"$T/out" 2>"$T/err"; rc=$?
is  "a login on two rows is rc 65" "$rc" "65"
is  "and prints no slug" "$(cat "$T/out")" ""
has "and names both rows" "$(cat "$T/err")" "a2"
rm -f "$ROOT/principals.d/a2.conf"

echo "== TAILSCALE_LOGIN is a LIST: one human can carry several tailnet logins =="
printf 'NAME="Dee"\nTAILSCALE_LOGIN="d1@example.com d2@example.com"\n' > "$ROOT/principals.d/d.conf"
registry_principal_load d; rc=$?
is  "a row with two logins loads" "$rc" "0"
is  "and exposes both words" "$PRINCIPAL_TAILSCALE_LOGIN" "d1@example.com d2@example.com"
is  "the first word resolves via for_login" "$(registry_principal_for_login d1@example.com)" "d"
is  "the second word resolves via for_login" "$(registry_principal_for_login d2@example.com)" "d"

printf 'NAME="Empty"\nTAILSCALE_LOGIN=""\n' > "$ROOT/principals.d/empty.conf"
registry_principal_load empty 2>"$T/err"; rc=$?
is  "an empty login list is refused" "$rc" "1"

printf 'NAME="Kay"\nTAILSCALE_LOGIN="K1@Example.com k2@EXAMPLE.com"\n' > "$ROOT/principals.d/k.conf"
registry_principal_load k
is  "each word is lower-cased on load" "$PRINCIPAL_TAILSCALE_LOGIN" "k1@example.com k2@example.com"
is  "the lookup is case-insensitive per word" "$(registry_principal_for_login K2@EXAMPLE.COM)" "k"

printf 'NAME="Bad2"\nTAILSCALE_LOGIN="ok@example.com not-a-login"\n' > "$ROOT/principals.d/bad2.conf"
registry_principal_load bad2 2>"$T/err"; rc=$?
is  "a row with one malformed word among valid ones is refused" "$rc" "1"

# the verb
out="$(bash "$here/bin/steward" registry principal add c --name Cy --tailscale-login c@example.com 2>&1)"; rc=$?
is  "the verb writes a row" "$rc" "0"
has "the row carries the login" "$(cat "$ROOT/principals.d/c.conf")" 'TAILSCALE_LOGIN="c@example.com"'
out="$(bash "$here/bin/steward" registry principal add again --name Again --tailscale-login a@example.com 2>&1)"; rc=$?
is  "a duplicate login is refused before writing" "$rc" "65"
is  "and no row was written" "$(ls "$ROOT/principals.d" | grep -c again)" "0"
out="$(bash "$here/bin/steward" registry principal add bad --name Bad --tailscale-login 'not a login' 2>&1)"; rc=$?
is  "a malformed login is refused" "$rc" "64"

echo "== the verb: --tailscale-login is a repeatable, space-splittable LIST =="
out="$(bash "$here/bin/steward" registry principal add multi --name Multi \
  --tailscale-login m1@example.com --tailscale-login m2@example.com 2>&1)"; rc=$?
is  "the verb accepts a repeated --tailscale-login flag" "$rc" "0"
has "the row carries both logins" "$(cat "$ROOT/principals.d/multi.conf")" 'TAILSCALE_LOGIN="m1@example.com m2@example.com"'

out="$(bash "$here/bin/steward" registry principal add multi2 --name Multi2 \
  --tailscale-login 'm3@example.com m4@example.com' 2>&1)"; rc=$?
is  "the verb accepts one space-separated value" "$rc" "0"
has "producing the same row shape as the repeated flag" \
    "$(cat "$ROOT/principals.d/multi2.conf")" 'TAILSCALE_LOGIN="m3@example.com m4@example.com"'

out="$(bash "$here/bin/steward" registry principal add dedupe --name Dedupe \
  --tailscale-login dd@example.com --tailscale-login dd@example.com 2>&1)"; rc=$?
is  "a login repeated within the row is de-duplicated" "$rc" "0"
has "writing it once" "$(cat "$ROOT/principals.d/dedupe.conf")" 'TAILSCALE_LOGIN="dd@example.com"'

out="$(bash "$here/bin/steward" registry principal add nologins --name NoLogins 2>&1)"; rc=$?
is  "the verb requires at least one --tailscale-login" "$rc" "64"

out="$(bash "$here/bin/steward" registry principal add again2 --name Again2 --tailscale-login m1@example.com 2>&1)"; rc=$?
is  "a second row carrying a word from another row is refused before writing" "$rc" "65"
is  "and no row was written" "$(ls "$ROOT/principals.d" | grep -c again2)" "0"

out="$(bash "$here/bin/steward" registry principal add bad3 --name Bad3 \
  --tailscale-login 'ok2@example.com not-a-login' 2>&1)"; rc=$?
is  "a malformed word among valid ones is rc 64" "$rc" "64"
is  "and nothing was written" "$(ls "$ROOT/principals.d" | grep -c bad3)" "0"

# the under-lock validator also refuses a collision on a NON-FIRST word — same
# bypass-the-pre-check technique as the ATOMIC gate below.
_DUP3='NAME="Raced2"
TAILSCALE_LOGIN="other@example.com m1@example.com"'
_rc=0
( export STEWARD_ESTATE_ROOT="$ROOT" STEWARD_CONFIG_FILE="$T/no-such-config"
  . "$here/lib/registry.sh"
  eval "$(sed -n '/^_principal_validate_row()/,/^}/p' "$here/bin/steward")"
  export _REGW_EXPECT_NAME="Raced2" _REGW_EXPECT_TAILSCALE_LOGIN="other@example.com m1@example.com" _REGW_EXPECT_DESK_READ_ALL=""
  registry_principal_write raced2 "$_DUP3" _principal_validate_row ) >/dev/null 2>&1 || _rc=$?
is  "the under-lock validator refuses when ANY word collides, not only the first" \
    "$( [ "$_rc" -ne 0 ] && echo refused || echo passed )" "refused"
if [ -e "$ROOT/principals.d/raced2.conf" ]; then
  bad "no row with a colliding word must be published" "found $ROOT/principals.d/raced2.conf"
else
  ok "no row with a colliding word published"
fi
rm -f "$ROOT/principals.d/raced2.conf"

echo "== ATOMIC gate: the login-uniqueness check runs INSIDE the write lock =="
# A parallel race is non-reproducible on demand; the deterministic proof is
# that the validate_fn (which registry_row_write calls UNDER its lock, before
# publish) itself refuses a STAGED row whose login is already on another
# row — with the verb's own pre-check bypassed entirely by calling
# registry_principal_write directly. Same technique as the ATOMIC-gate check
# in test/registry-session-add.test.sh: eval the function's own source out of
# bin/steward (it is a script, not a library, so it cannot be sourced) into a
# subshell, then drive it exactly as registry_row_write would.
printf 'NAME="Existing"\nTAILSCALE_LOGIN="race@example.com"\n' > "$ROOT/principals.d/existing.conf"
_DUP='NAME="Raced"
TAILSCALE_LOGIN="race@example.com"'
_rc=0
( export STEWARD_ESTATE_ROOT="$ROOT" STEWARD_CONFIG_FILE="$T/no-such-config"
  . "$here/lib/registry.sh"
  eval "$(sed -n '/^_principal_validate_row()/,/^}/p' "$here/bin/steward")"
  export _REGW_EXPECT_NAME="Raced" _REGW_EXPECT_TAILSCALE_LOGIN="race@example.com" _REGW_EXPECT_DESK_READ_ALL=""
  registry_principal_write raced "$_DUP" _principal_validate_row ) >/dev/null 2>&1 || _rc=$?
is  "the validator refuses a login already on another row, under the lock" \
    "$( [ "$_rc" -ne 0 ] && echo refused || echo passed )" "refused"
if [ -e "$ROOT/principals.d/raced.conf" ]; then
  bad "no duplicate-login row must be published" "found $ROOT/principals.d/raced.conf"
else
  ok "no duplicate-login row published"
fi
rm -f "$ROOT/principals.d/existing.conf" "$ROOT/principals.d/raced.conf"

echo "== PARALLEL sanity — a real race never yields more than one winner =="
# The pre-check alone (before any lock) lets two concurrent verb calls for
# the SAME NEW login both pass it before either has staged anything. Fire a
# 20-way race at one login across 20 distinct slugs: at most one row for that
# login may land, exactly one call may succeed, and every loser must be
# refused as a duplicate — rc 65 if the pre-check caught it, rc 70 if only
# the under-lock recheck did (no remapping between the two, per the
# controller ruling on the earlier fix round: registry_row_write hardcodes
# 70 for every validate_fn failure, the same as every other validator in
# this file).
for i in $(seq 1 20); do
  ( r=0; bash "$here/bin/steward" registry principal add "raced$i" --name Raced \
      --tailscale-login raced-shared@example.com >/dev/null 2>&1 || r=$?
    printf '%s' "$r" > "$T/rc_$i" ) &
done
wait
_won="$(grep -l 'TAILSCALE_LOGIN="raced-shared@example.com"' "$ROOT"/principals.d/*.conf 2>/dev/null | wc -l | tr -d ' ')"
is  "at most one winner under a 20-way race (got $_won)" \
    "$( [ "${_won:-0}" -le 1 ] && echo ok || echo TOOMANY )" "ok"
_zeros=0; _bad=0
for i in $(seq 1 20); do
  v="$(cat "$T/rc_$i" 2>/dev/null)"
  case "$v" in
    0)     _zeros=$((_zeros+1)) ;;
    65|70) : ;;
    *)     _bad=$((_bad+1)) ;;
  esac
done
is "exactly one concurrent add succeeds" "$_zeros" "1"
is "every loser is refused as a duplicate (rc 65 or 70)" "$_bad" "0"
grep -l 'TAILSCALE_LOGIN="raced-shared@example.com"' "$ROOT"/principals.d/*.conf 2>/dev/null | xargs rm -f 2>/dev/null || true

printf '\n  %d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
