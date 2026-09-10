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
# refused with a rc this file documents.
#
# THERE ARE THREE SUCH RCS, NOT TWO. 65 if the pre-check caught the duplicate,
# 70 if only the under-lock recheck did (no remapping between the two, per the
# controller ruling on the earlier fix round: registry_row_write hardcodes 70
# for every validate_fn failure, the same as every other validator in this
# file) — and 75 for a loser that never got the lock at all, which
# _registry_lock_take returns after 20 bounded tries and which lib/registry.sh
# documents in four places.
#
# THE THIRD ONE WAS MISSING HERE, and its absence was invisible: on an idle
# machine all twenty callers take the lock in turn and 75 never happens. Under
# load it does, and the suite went red for a product doing exactly what it
# says. Measured: idle 1x0 19x70 -> green; under CPU load 1x0 18x70 1x75 ->
# red, four runs in six; after a full 104-suite run, three 75s at once.
#
# So the vocabulary lives in ONE place below, the race and the deterministic
# lock case both read it, and the histogram is printed either way - a red run
# on a loaded machine should say what it saw, not just that it counted wrong.
_loser_rc_is_legal() { case "$1" in 65|70|75) return 0 ;; *) return 1 ;; esac; }
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
  if [ "$v" = "0" ]; then _zeros=$((_zeros+1))
  elif _loser_rc_is_legal "$v"; then :
  else _bad=$((_bad+1)); fi
done
printf '  rc histogram: %s\n' \
  "$(for i in $(seq 1 20); do cat "$T/rc_$i" 2>/dev/null; echo; done | sort | uniq -c \
     | awk '{printf "%sx%s ", $1, $2}')"
is "exactly one concurrent add succeeds" "$_zeros" "1"
is "every loser is refused with a documented rc (65, 70 or 75)" "$_bad" "0"
grep -l 'TAILSCALE_LOGIN="raced-shared@example.com"' "$ROOT"/principals.d/*.conf 2>/dev/null | xargs rm -f 2>/dev/null || true

echo "== THE THIRD LOSER — one who never gets the lock, made to happen on purpose =="
# The race above can only OBSERVE a 75; it cannot GUARANTEE one, so on an idle
# machine dropping 75 from the vocabulary costs nothing and the widening would
# be free. Hold the lock the way the product holds it and the refusal is
# deterministic: _registry_lock_take gives up after 20 tries at 0.1s.
_lock="$ROOT/principals.d/.write.lock"
mkdir "$_lock"
_r=0; _out="$(bash "$here/bin/steward" registry principal add lockedout --name Lockedout \
     --tailscale-login lockedout@example.com 2>&1)" || _r=$?
rmdir "$_lock" 2>/dev/null || true
is  "a caller that never gets the lock is refused, not served" "$_r" "75"
has "and the refusal names the lock it waited for" "$_out" ".write.lock"
has "and says how to clear it if nothing is writing" "$_out" "rmdir"
# THIS is the assertion that makes the widening cost something: take 75 out of
# _loser_rc_is_legal and it falls here, on any machine, in two seconds.
is  "the race's vocabulary accepts the refusal the product actually gives" \
    "$(_loser_rc_is_legal "$_r" && echo accepted || echo REJECTED)" "accepted"
is  "no row was published for a caller that never got the lock" \
    "$(ls "$ROOT/principals.d"/lockedout.conf 2>/dev/null | wc -l | tr -d ' ')" "0"

printf '\n  %d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
