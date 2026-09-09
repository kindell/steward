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
no()  { case "$2" in *"$3"*) bad "$1" "found '$3' in: $2" ;; *) ok "$1" ;; esac; }
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
# The two registers whose loaders refuse a loose directory are 0700; every
# other register the scaffold makes must at least not be group- or
# other-writable. Both are ASSERTED under a umask that would otherwise produce
# something else, in both directions.
#
# THE SET IS THE SCAFFOLD'S OWN LIST, NOT A COPY OF IT. This used to be a
# hand-written line naming ten directories, and it was blind in the direction a
# hand list is always blind: a register ADDED to the scaffold that no loader
# reads was checked by nothing at all. Measured - `widgets.d` added to the
# scaffold's loop at mode 0777, no resolver anywhere, and this suite stayed
# green under both umasks. A world-writable register, silent. So the wanted set
# is now read off the loop that creates it, which is the only place a register
# can be added.
#
# Section 5 derives the OTHER direction - the registers the loaders READ - from
# lib/registry.sh. Two derivations facing opposite ways, and no list.
_scaffold_registers() { # <path to lib/scaffold.sh>
  awk '
    !/^[[:space:]]*#/ && /for _sc_reg in/ { f=1; sub(/^.*for _sc_reg in/, "") }
    f {
      cont = ($0 ~ /\\[[:space:]]*$/)     # the list is written over three lines
      sub(/\\[[:space:]]*$/, "")
      sub(/;[[:space:]]*do.*$/, "")
      print
      if (!cont) exit
    }
  ' "$1" | tr ' \t' '\n\n' | grep '\.d$' | sort -u
}

# scaffold_loose <estate> - one line per register the scaffold's list names
# that the estate gets wrong. SILENCE IS THE PASS, and the lines are the
# failure message, so a broken estate names the register rather than a count.
scaffold_loose() {
  local est="$1" r m
  for r in $scaffolded; do
    if [ ! -d "$est/$r" ]; then printf '%s missing\n' "$r"; continue; fi
    m="$(mode_of "$est/$r")"
    # THREE OCTAL DIGITS OR THE MEASUREMENT IS NOT ONE - the rule section 5
    # states, for the same reason: stat answers "2755" for a setgid directory
    # and nothing at all when it cannot look, and both would slip past the
    # digit test below as "not group-writable".
    case "$m" in
      [0-7][0-7][0-7]) ;;
      *) printf '%s mode "%s" is not three octal digits\n' "$r" "$m"; continue ;;
    esac
    case "$m" in ?[2367]?|??[2367]) printf '%s mode %s is group- or other-writable\n' "$r" "$m" ;; esac
  done
}

echo "== the scaffold pins every register's mode =="
scaffolded="$(_scaffold_registers "$here/lib/scaffold.sh" | tr '\n' ' ')"
sn=0; for r in $scaffolded; do sn=$((sn+1)); done
# A DERIVATION THAT FINDS NOTHING PASSES EVERY ASSERTION BUILT ON IT. That is
# the one way this class of guard dies without a sound, so it is measured.
if [ "$sn" -ge 1 ]; then ok "the scaffold's own list names $sn registers"
else bad "the scaffold's own list names at least one register" \
         "it named none, so every assertion built on it is vacuous"; fi
for u in 002 077; do
  ( umask "$u"; build_estate "$FX/e-$u" ) || bad "scaffold succeeds under umask $u" "rc $?"
  for d in logins.d invites.d; do
    is "umask $u: $d is 700" "$(mode_of "$FX/e-$u/$d")" "700"
  done
  is "umask $u: no register the scaffold makes is group- or other-writable" \
     "$(scaffold_loose "$FX/e-$u")" ""
done

# AND THE CHECK HAS TEETH, proved rather than assumed: one register of the
# scaffold's own list is widened by hand and the check must name THAT register,
# with its mode, and no other.
( umask 022; build_estate "$FX/widened" ) || bad "estate built for the widening" "rc $?"
chmod 0777 "$FX/widened/projects.d"
is "a register somebody widens is named, and only it" \
   "$(scaffold_loose "$FX/widened")" "projects.d mode 777 is group- or other-writable"

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
has "and names the remedy"                "$err" "chmod g-w,o-w \"$FX/loose/invites.d\""
err="$( STEWARD_ESTATE_ROOT="$FX/loose" bash -c \
        '. "$1/lib/registry.sh"; registry_login_load nobody' _ "$here" 2>&1 >/dev/null )"
has "the login refusal names the mode"    "$err" "group- or other-writable (mode 775)"
has "and names the directory"             "$err" "$FX/loose/logins.d"
has "and names the remedy"                "$err" "chmod g-w,o-w \"$FX/loose/logins.d\""

# -- 3b. THE REMEDY IS A COMMAND, SO IT IS MEASURED BY RUNNING IT -------------
#
# A remedy that reports success and repairs nothing is worse than no remedy:
# the operator pastes it, sees no error, and believes the register is fixed.
# Measured on an estate whose path contains a space, before this was quoted:
# the message printed `chmod g-w,o-w /var/.../my estate/invites.d`, pasting it
# gave `chmod: /var/.../my: No such file or directory` plus a second complaint
# about `estate/invites.d`, and the register was STILL 775 afterwards.
#
# So the assertion is not that the text looks right. The command is lifted out
# of the message the loader printed and RUN, in a shell, exactly as an operator
# would paste it, and the register is measured again afterwards.
echo "== the remedy the refusal prints actually repairs the register =="
SP="$FX/my estate"
( umask 022; build_estate "$SP" ) || bad "an estate builds at a path with a space" "rc $?"
chmod 775 "$SP/invites.d" "$SP/logins.d"
loader_err() { # <estate> <shell snippet>
  ( STEWARD_ESTATE_ROOT="$1" bash -c \
      ". \"\$1/lib/registry.sh\"; $2" _ "$here" 2>&1 >/dev/null )
}
for reg in invites logins; do
  case "$reg" in
    invites) call='registry_invite_load inv-00000000' ;;
    logins)  call='registry_login_load nobody' ;;
  esac
  err="$(loader_err "$SP" "$call")"
  remedy="$(printf '%s\n' "$err" | sed -n 's/.* - run: //p' | head -1)"
  has "the $reg refusal on a path with a space offers a remedy" "$remedy" "chmod g-w,o-w"
  crc=0; cout="$( eval "$remedy" 2>&1 )" || crc=$?
  is "and pasting the $reg remedy exits 0" "$crc" "0"
  is "and it complains about nothing"      "$cout" ""
  is "and $reg.d is no longer group- or other-writable" "$(mode_of "$SP/$reg.d")" "755"
  no "and the loader no longer refuses the register" \
     "$(loader_err "$SP" "$call")" "group- or other-writable"
done

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
has "and the remedy travels with it"      "$out" "chmod g-w,o-w \"$FX/loose/invites.d\""
n=0; for f in "$FX/loose"/invites.d/*.conf; do [ -e "$f" ] && n=$((n+1)); done
is "and the refused row was removed" "$n" "0"

# -- 5. EVERY REGISTER THE LOADERS READ IS A REGISTER THE SCAFFOLD MAKES ------
#
# THIS IS THE GUARD, and it exists because a hand-written list is how the last
# two defects happened. invites.d was absent from the scaffold's list for as
# long as the invite loader had existed, and principals.d was absent for as
# long as `invite redeem` had written a principal row - both found by a person
# reading two lists side by side, not by anything that measured.
#
# SO THE WANTED SET IS NOT WRITTEN DOWN HERE. It is DERIVED from the code that
# resolves the paths: every function in lib/registry.sh named registry_*dir
# whose body roots a path at _registry_estate_root NAMES the register it reads,
# as a literal, on one line. That literal is the derivation's only input. A
# register added to the loaders therefore joins this test's expectation the
# moment its resolver is written, and turns the test red until the scaffold
# creates it. A SECOND HAND-MAINTAINED LIST WOULD GUARD NOTHING - it would
# simply be the third place to forget.
#
# AND THE DERIVATION CHECKS ITSELF. A resolver that computed its directory
# instead of naming it would contribute nothing and the set would silently
# shrink, so every estate-rooted resolver is required to name EXACTLY ONE
# register and is named in the failure if it does not. The set is also required
# to be non-empty: a grep that matches nothing passes every assertion built on
# it, which is the one way a guard like this dies without a sound.
echo "== the registers the loaders read are the registers the scaffold makes =="
REG_SRC="$here/lib/registry.sh"

# _resolver_table - one line per registry_*dir function in lib/registry.sh, as
# "<function><TAB><body with comments stripped>". A comment is not code, and a
# register named only in prose must not enter the derivation.
_resolver_table() {
  awk '
    /^registry_[a-z_]*dir\(\)/ {
      fn=$0; sub(/\(\).*/,"",fn)
      line=$0; sub(/#.*/,"",line)
      if ($0 ~ /}[[:space:]]*$/) { print fn "\t" line; next }   # a one-line body
      inb=1; body=""; next
    }
    inb==1 && /^}/ { print fn "\t" body; inb=0; next }
    inb==1 { line=$0; sub(/#.*/,"",line); body=body " " line; next }
  ' "$1"
}

# THE LITERAL, AS THE CODE WRITES IT. Matching the whole composition rather
# than a bare "<name>.d" keeps a register name that appears in a body for some
# other reason out of the set.
_registers_in() { printf '%s\n' "$1" \
  | grep -oE '_registry_estate_root\)/[a-z][a-z0-9_-]*\.d' | sed 's|.*/||' | sort -u; }

# THE TABLE'S OWN PATTERN IS MEASURED, because the pattern is the guard. A
# resolver the pattern cannot see contributes nothing and is reported as
# nothing: it is not a named gap, it is an absence, and the derived set simply
# comes back one register shorter than the code. Two spellings were invisible -
# `registry_x_dir ()` with a space before the parens, which is valid bash and a
# common style, and a private `_registry_x_dir`. Both are fed to the table here
# from a fixture, so that widening the pattern later cannot narrow it again by
# accident. The fixture is a file of resolvers, not lib/registry.sh: a guard
# that can only be tested by editing the code it guards is not tested.
SPELL="$FX/spellings.sh"
cat > "$SPELL" <<'EOF'
registry_plain_dir() {
  printf '%s\n' "$(_registry_estate_root)/plain.d"
}
registry_spaced_dir ()  {
  printf '%s\n' "$(_registry_estate_root)/spaced.d"
}
_registry_private_dir() {
  printf '%s\n' "$(_registry_estate_root)/private.d"
}
registry_oneline_dir() { printf '%s\n' "$(_registry_estate_root)/oneline.d"; }
EOF
while read -r sp_fn sp_reg; do
  [ -n "$sp_fn" ] || continue
  sp_body="$(_resolver_table "$SPELL" | awk -F'\t' -v f="$sp_fn" '$1==f{print $2}')"
  is "the table sees a resolver spelled $sp_fn" \
     "$(printf '%s' "$sp_body" | grep -c . | tr -d ' ')" "1"
  is "and derives $sp_reg from it" "$(_registers_in "$sp_body")" "$sp_reg"
done <<'EOF'
registry_plain_dir plain.d
registry_spaced_dir spaced.d
_registry_private_dir private.d
registry_oneline_dir oneline.d
EOF

derived=""
while IFS=$'\t' read -r fn body; do
  [ -n "$fn" ] || continue
  case "$body" in *_registry_estate_root*) ;; *) continue ;; esac
  names="$(_registers_in "$body")"
  n="$(printf '%s\n' "$names" | grep -c '[a-z]')"
  if [ "$n" -ne 1 ]; then
    bad "resolver $fn names exactly one register" "it names $n - the derivation cannot see what it reads"
    continue
  fi
  ok "resolver $fn names $names"
  derived="$derived $names"
done <<EOF
$(_resolver_table "$REG_SRC")
EOF
dn=0; for r in $derived; do dn=$((dn+1)); done
if [ "$dn" -ge 1 ]; then ok "the derivation found $dn registers"
else bad "the derivation found at least one register" "it found none, so every assertion below is vacuous"; fi

# THE TWO DERIVATIONS ARE CHECKED AGAINST EACH OTHER, at the SOURCE rather than
# through a built estate. Every register a loader reads must appear in the
# scaffold's own list; a register that does not is one the product reads and
# never creates. The estate check below would also catch it, but only after a
# scaffold ran - here the two lists are compared as the code writes them, so a
# break in either awk shows up as a named register rather than as a shrunken
# set nobody counted.
unscaffolded=""
for r in $derived; do
  case " $scaffolded " in *" $r "*) ;; *) unscaffolded="$unscaffolded $r" ;; esac
done
is "every register the loaders read is named by the scaffold's own list" "$unscaffolded" ""

# WHICH REGISTERS ARE THE TIGHT ONES IS DERIVED TOO. A loader that refuses a
# group- or other-writable register says so in a sentence naming that register:
# "the <noun> register is group- or other-writable". Those nouns are the
# product's own statement about which registers carry something worth
# protecting, and each maps to its resolver by name - registry_<noun>_dir. A
# guarded register the scaffold leaves readable by others is not protected by
# the check its loader makes, because anyone who can read the directory can
# read every row in it.
guarded=""
for noun in $(grep -v '^[[:space:]]*#' "$REG_SRC" \
              | grep -oE 'the [a-z]+ register is group- or other-writable' \
              | awk '{print $2}' | sort -u); do
  g="$(_registers_in "$(_resolver_table "$REG_SRC" | awk -F'\t' -v f="registry_${noun}_dir" '$1==f{print $2}')")"
  if [ -z "$g" ]; then
    bad "the guarded register '$noun' has a resolver" "no registry_${noun}_dir names a register"
    continue
  fi
  ok "the '$noun' register the loaders guard is $g"
  guarded="$guarded $g"
done

# registers_wrong <estate> - one line per derived register the estate gets
# wrong. SILENCE IS THE PASS, and the lines are the failure message, so a
# broken estate names the register rather than reporting a count.
registers_wrong() {
  local est="$1" r m
  for r in $derived; do
    if [ ! -d "$est/$r" ]; then printf '%s missing\n' "$r"; continue; fi
    m="$(mode_of "$est/$r")"
    # THREE OCTAL DIGITS OR THE MEASUREMENT IS NOT ONE. stat answers "2755" for
    # a setgid directory and nothing at all when it cannot look, and both would
    # slip past the digit tests below as "not group-writable" - a guard that
    # passes on an unread mode is the failure this whole suite is about.
    case "$m" in
      [0-7][0-7][0-7]) ;;
      *) printf '%s mode "%s" is not three octal digits\n' "$r" "$m"; continue ;;
    esac
    case " $guarded " in
      # 0700: the group and other digits are both zero. The loader's own check
      # only refuses WRITE, but a register whose contents are worth that check
      # is a register others have no business reading either.
      *" $r "*) case "$m" in 700) ;; *) printf '%s mode %s wanted 700\n' "$r" "$m" ;; esac ;;
      # Everything else: not group- or other-writable, whatever the umask. This
      # is the exact predicate the product's own _registry_group_or_other_writable
      # applies, and the one the Debian default umask violated.
      *) case "$m" in ?[2367]?|??[2367]) printf '%s mode %s is group- or other-writable\n' "$r" "$m" ;; esac ;;
    esac
  done
}

for u in 002 077; do
  ( umask "$u"; build_estate "$FX/derived-$u" ) || bad "estate built under umask $u" "rc $?"
  is "umask $u: every register the loaders read is scaffolded, with its mode" \
     "$(registers_wrong "$FX/derived-$u")" ""
done

# THE GUARD IS PROVED BY MUTATION, not by having passed. A test that measures
# nothing passes exactly like a test that measures everything, so one register
# is removed from the scaffold's own list and the check is required to name
# THAT register and no other. The mutation is verified to have changed the file
# before it is trusted: a sed that matched nothing would prove the opposite of
# what this case claims.
mkdir -p "$FX/mut/lib"
sed '/^[[:space:]]*#/!s/ projects\.d//' "$here/lib/scaffold.sh" > "$FX/mut/lib/scaffold.sh"
if cmp -s "$here/lib/scaffold.sh" "$FX/mut/lib/scaffold.sh"; then
  bad "the mutation drops projects.d from the scaffold's list" "the file came back unchanged"
else
  ok "the mutation drops projects.d from the scaffold's list"
  ( umask 022
    # shellcheck source=/dev/null
    . "$FX/mut/lib/scaffold.sh"
    estate_scaffold "$FX/mut/e" org=acme team=kindell owner=alice session=home-alice ) >/dev/null 2>&1
  is "a register the scaffold drops is named, and only it" \
     "$(registers_wrong "$FX/mut/e")" "projects.d missing"
fi

# -- 6. THE FIRST ONBOARDING SEQUENCE, ON AN ESTATE THE PRODUCT JUST BUILT ----
#
# THE SHAPE BOTH DEFECTS HID BEHIND. Every suite that exercises invitations
# builds its estate by hand, with mkdir, so a register the SCAFFOLD does not
# create is present in every test and absent on every fresh machine. This case
# walks the sequence a new estate actually takes - scaffold, issue, redeem -
# against an estate nothing but lib/scaffold.sh has touched.
#
# HOST-TOUCHING COMMANDS ARE SHIMMED, the technique test/invite-redeem.test.sh
# uses: nothing here creates a unix account, generates a real key, reaches a
# network, or writes outside the fixture.
echo "== scaffold, invite issue, invite redeem - on an estate the product built =="
P="$FX/product"
mkdir -p "$P/bin" "$P/lib" "$P/linux" "$P/desk" "$FX/sbin" "$FX/home" \
         "$FX/hub/.ssh" "$FX/hub/scripts/bus/bin"
cp "$here/bin/steward" "$P/bin/steward"; chmod 755 "$P/bin/steward"
cp "$here/lib/registry.sh" "$P/lib/registry.sh"
cat > "$P/linux/deploy-self.sh" <<EOF
#!/bin/bash
mkdir -p "$FX/home/bo/scripts/lib" && : > "$FX/home/bo/scripts/lib/registry.sh"
exit 0
EOF
printf '#!/bin/bash\nexit 0\n' > "$P/desk/snapshot.sh"
chmod 755 "$P/linux/deploy-self.sh" "$P/desk/snapshot.sh"
printf '#!/bin/bash\necho "%s/home/$1"\n' "$FX" > "$FX/sbin/homelookup"
# THE HELPER'S RECEIPTS GO TO STDERR, where the real one writes them: step 10
# reads the tmpfiles line back out of what step 3 captured.
cat > "$FX/sbin/sudo" <<EOF
#!/bin/bash
args=(); while [ \$# -gt 0 ]; do
  case "\$1" in -n) shift ;; -u) shift 2 ;; *) args+=("\$1"); shift ;; esac
done
case "\${args[0]:-}" in
  */steward-account-helper)
    mkdir -p "$FX/home/\${args[2]}/.ssh"
    echo "helper: account \${args[2]} created" >&2
    echo "helper: tmpfiles /etc/tmpfiles.d/steward-rig-\${args[2]}.conf" >&2
    exit 0 ;;
esac
exec "\${args[@]}"
EOF
cat > "$FX/sbin/ssh-keygen" <<'EOF'
#!/bin/bash
f=""; prev=""
for a in "$@"; do [ "$prev" = "-f" ] && f="$a"; prev="$a"; done
[ -n "$f" ] && { mkdir -p "$(dirname "$f")"; printf 'PRIVATE\n' > "$f"
                 printf 'ssh-ed25519 AAAANEWKEY new\n' > "$f.pub"; }
exit 0
EOF
printf '#!/bin/bash\necho "|1|hashed|hashed ssh-ed25519 AAAAHOSTKEY"\nexit 0\n' > "$FX/sbin/ssh-keyscan"
# id: the fixture's account database, empty - `id -u <name>` answers "no such
# user" for everybody, which is the ordinary case for an invited person. Every
# other form is the real id, because the product also asks who is RUNNING.
ID_REAL="$(command -v id)"
cat > "$FX/sbin/id" <<EOF
#!/bin/bash
if [ "\${1:-}" = "-u" ] && [ \$# -eq 2 ]; then
  echo "id: '\$2': no such user" >&2; exit 1
fi
exec "$ID_REAL" "\$@"
EOF
chmod 755 "$FX/sbin/homelookup" "$FX/sbin/sudo" "$FX/sbin/ssh-keygen" \
          "$FX/sbin/ssh-keyscan" "$FX/sbin/id"
: > "$FX/hub/.ssh/authorized_keys"
printf 'ssh-ed25519 AAAAHUBKEY hub\n' > "$FX/hub/.ssh/id_ed25519.pub"
: > "$FX/hub/scripts/bus/bin/bus-relay-in"

E2E="$FX/onboard"
( umask 002; build_estate "$E2E" ) || bad "the estate scaffolds under umask 002" "rc $?"
e2e() {
  ( export PATH="$FX/sbin:$PATH" HOME="$FX/hub" \
           STEWARD_ESTATE_ROOT="$E2E" \
           STEWARD_CONFIG_FILE="$FX/no-such-config" \
           STEWARD_HOME_LOOKUP_CMD="$FX/sbin/homelookup" \
           STEWARD_AUTHORIZED_KEYS="$FX/hub/.ssh/authorized_keys" \
           STEWARD_SELF_HOST="host-a"
    umask 002
    bash "$P/bin/steward" "$@" )
}
out="$(e2e invite issue --name "Bo Example" --principal bo --entity acme \
        --host host-a --issued-by alice 2>&1)"; rc=$?
is "issue succeeds on a freshly scaffolded estate" "$rc" "0"
no "and no register refused the step"  "$out" "register is not readable"
tok="$(printf '%s\n' "$out" | grep -o 'https://desk.example.test/desk/invite/[A-Za-z0-9_-]*' | head -1)"
tok="${tok##*/}"
out="$(e2e invite redeem "$tok" --identity oidc:issuer-e2e:SUB-1 --email bo@example.test 2>&1)"; rc=$?
is "redeem succeeds on a freshly scaffolded estate" "$rc" "0"
no "and no register refused a step"    "$out" "register is not readable"
no "and no register was refused loose" "$out" "group- or other-writable"
is "the principal row is on disk" "$([ -f "$E2E/principals.d/bo.conf" ] && echo yes || echo no)" "yes"
is "the account row is on disk"   "$([ -f "$E2E/accounts.d/bo-host-a.conf" ] && echo yes || echo no)" "yes"
is "and every register is still right afterwards" "$(registers_wrong "$E2E")" ""

echo
printf '  %s passed, %s failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
