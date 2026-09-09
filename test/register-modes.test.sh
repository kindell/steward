#!/bin/bash
# test/register-modes.test.sh - a register directory's mode is the PRODUCT's
# decision, never the ambient umask.
#
# WHY THIS SUITE EXISTS, MEASURED. On a Debian/Ubuntu host the default umask is
# 002 (user-private groups). Every register the product created there came out
# group-writable, and the invite and login loaders refuse a group- or
# other-writable register on purpose - a row at mode 600 inside a directory
# anybody can write to is not protected by its mode. So `steward invite issue`
# wrote its row, its own canonical readback refused the register it had just
# written into, and the writer deleted the row and returned 70. The first step
# of onboarding could not be taken at all on the platform this product is for,
# and the suites were green everywhere it was run because the aggregate ran on
# a host whose umask is 022.
#
# EVERY CASE HERE RUNS UNDER AN EXPLICIT UMASK, in both directions. A test that
# inherits the runner's umask measures the runner, not the product: under 022
# the bug is invisible, and under 077 a directory that is merely "not
# group-writable by accident" passes for one that was pinned. 002 proves the
# mode is tightened; 077 proves it is loosened; neither may be left to chance.
set -u
here="$(CDPATH= cd -- "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
pass=0; fail=0
ok()  { pass=$((pass+1)); printf '  ok   %s\n' "$1"; }
bad() { fail=$((fail+1)); printf '  FAIL %s\n     %s\n' "$1" "${2:-}"; }
is()  { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "wanted '$3', got '$2'"; fi; }
has() { case "$2" in *"$3"*) ok "$1" ;; *) bad "$1" "missing '$3' in: $2" ;; esac; }
FX="$(mktemp -d)"; trap 'rm -rf "$FX"' EXIT
echo "register-modes"

# The same two-shot stat idiom the library uses: neither flag exists on both
# platforms, and a wrong-platform `stat -f` on GNU answers about the FILESYSTEM
# with exit 0, so the BSD form must be probed first and shape-checked.
mode_of() { stat -f '%Lp' "$1" 2>/dev/null || stat -c '%a' "$1" 2>/dev/null; }

# -- an estate a real onboarding can be run against -------------------------
# Scaffolded by the product's own engine, then given the three rows `invite
# issue` reads before it writes: the entity, the host, and the account that
# says who is issuing. Nothing here creates a directory by hand - the point of
# the suite is what the PRODUCT creates.
build_estate() { # <dir>
  local d="$1"
  # shellcheck source=/dev/null
  ( . "$here/lib/scaffold.sh"
    estate_scaffold "$d" org=acme team=kindell owner=alice session=home-alice ) >/dev/null 2>&1 || return $?
  printf 'DESK_ORIGIN="https://desk.example.test"\n' >> "$d/estate/steward.conf" || return 70
  printf 'NAME="Acme"\nMEMBERS="alice"\n' > "$d/entities.d/acme.conf" || return 70
  printf 'OWNER="alice"\nLEGAL_OWNER="Acme Ltd"\nOPERATOR="alice"\n' > "$d/hosts.d/host-a.conf" || return 70
  return 0
}

# -- 1. THE SCAFFOLD PINS EVERY REGISTER'S MODE -----------------------------
# The two registers whose loaders refuse a loose directory are 0700; the rest
# are 0755. Both are ASSERTED under a umask that would otherwise produce
# something else, in both directions.
echo "== the scaffold pins every register's mode =="
for u in 002 077; do
  ( umask "$u"; build_estate "$FX/e-$u" ) || bad "scaffold succeeds under umask $u" "rc $?"
  for d in logins.d invites.d; do
    is "umask $u: $d is 700" "$(mode_of "$FX/e-$u/$d")" "700"
  done
  for d in sessions.d entities.d projects.d mcp.d jobs.d services.d browsers.d hosts.d accounts.d; do
    is "umask $u: $d is 755" "$(mode_of "$FX/e-$u/$d")" "755"
  done
done

# -- 2. ONBOARDING'S FIRST STEP WORKS UNDER 002 --------------------------------
# The whole bug in one case: issue an invitation on an estate built under the
# Debian default and read the register back afterwards.
echo "== invite issue succeeds under umask 002 =="
( umask 002; build_estate "$FX/issue" ) || bad "estate built" "rc $?"
out="$( umask 002; STEWARD_ESTATE_ROOT="$FX/issue" bash "$here/bin/steward" \
        invite issue --name "Bo" --principal bo --entity acme --host host-a \
        --issued-by alice 2>&1 )"; rc=$?
is "invite issue rc 0" "$rc" "0"
has "and it names the invitation" "$out" "steward: invitation inv-"
is "the invite register is still 700" "$(mode_of "$FX/issue/invites.d")" "700"
n=0; for f in "$FX/issue"/invites.d/*.conf; do [ -e "$f" ] && n=$((n+1)); done
is "exactly one row survived the write" "$n" "1"

# -- 3. A LOOSE REGISTER IS STILL REFUSED, AND THE REFUSAL NAMES THE REMEDY ----
# Pinning the mode does not retire the guard: a directory somebody widens by
# hand must still refuse. What changes is that the refusal now says which
# directory and what to run - the operator used to be told only that a readback
# failed, two layers above the cause.
echo "== a group-writable register refuses, and names the remedy =="
( umask 022; build_estate "$FX/loose" ) || bad "estate built" "rc $?"
chmod 775 "$FX/loose/invites.d" "$FX/loose/logins.d"
err="$( STEWARD_ESTATE_ROOT="$FX/loose" bash -c \
        '. "$1/lib/registry.sh"; registry_invite_load inv-00000000' _ "$here" 2>&1 >/dev/null )"
has "the invite refusal names the mode"   "$err" "group- or other-writable (mode 775)"
has "and names the directory"             "$err" "$FX/loose/invites.d"
has "and names the remedy"                "$err" "chmod g-w,o-w $FX/loose/invites.d"
err="$( STEWARD_ESTATE_ROOT="$FX/loose" bash -c \
        '. "$1/lib/registry.sh"; registry_login_load nobody' _ "$here" 2>&1 >/dev/null )"
has "the login refusal names the mode"    "$err" "group- or other-writable (mode 775)"
has "and names the directory"             "$err" "$FX/loose/logins.d"
has "and names the remedy"                "$err" "chmod g-w,o-w $FX/loose/logins.d"

# -- 4. THE WRITER'S READBACK REFUSAL CARRIES THE LOADER'S OWN SENTENCE --------
# The readback used to run with `>/dev/null 2>&1`, so the one message that said
# WHY the row would not load was thrown away and the operator got "wrote it but
# it does not load back" with nothing under it. That is why this cost a trace
# to find.
echo "== the readback refusal carries the loader's words =="
out="$( STEWARD_ESTATE_ROOT="$FX/loose" bash "$here/bin/steward" \
        invite issue --name "Cy" --principal cy --entity acme --host host-a \
        --issued-by alice 2>&1 )"; rc=$?
is "invite issue still refuses" "$rc" "70"
has "and still says the readback failed" "$out" "does not load back through the registry"
has "and now carries the loader's reason" "$out" "group- or other-writable"
has "and the remedy travels with it"      "$out" "chmod g-w,o-w $FX/loose/invites.d"
n=0; for f in "$FX/loose"/invites.d/*.conf; do [ -e "$f" ] && n=$((n+1)); done
is "and the refused row was removed" "$n" "0"

echo
printf '  %s passed, %s failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
