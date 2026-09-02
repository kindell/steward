#!/bin/bash
# test/logins-registry.test.sh — the login register: a STRICT parser that is
# never sourced, and the resolver that turns CONFIG_DIR into an absolute path.
#
# THE FILE IS NEVER SOURCED, and that is the whole reason the parser exists.
# Every refusal branch below is a line a plain `source` would have ACCEPTED and
# RUN. A login row names the directory that holds a subscription's credentials;
# a row that can execute is a row that can move them.
set -u
here="$(CDPATH= cd -- "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
. "$here/lib/registry.sh"
pass=0; fail=0
ok()  { pass=$((pass+1)); printf '  ok   %s\n' "$1"; }
bad() { fail=$((fail+1)); printf '  FAIL %s\n     %s\n' "$1" "${2:-}"; }
is()  { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "wanted '$3', got '$2'"; fi; }
has() { case "$2" in *"$3"*) ok "$1" ;; *) bad "$1" "missing '$3' in: $2" ;; esac; }

FX="$(mktemp -d)"; trap 'rm -rf "$FX"' EXIT
# TWO DIRECTORIES, FROM THE FIRST ROW. The SOUND one (logins.d) holds only rows
# that are meant to load; every REFUSAL row lives in bad.d. The reason is the
# register check: it reads the WHOLE directory it is pointed at, so a refusal
# fixture in the sound directory would make "a clean register passes rc 0"
# impossible to measure -- and that test is the only control group that gate has.
mkdir -p "$FX/logins.d" "$FX/bad.d"
export STEWARD_LOGINS_DIR="$FX/logins.d"

row()    { cat > "$FX/logins.d/$1.conf"; chmod 600 "$FX/logins.d/$1.conf"; }
badrow() { cat > "$FX/bad.d/$1.conf";    chmod 600 "$FX/bad.d/$1.conf"; }

echo "== 1. a valid row loads with every field set =="
row good <<'EOF'
# a comment is allowed
PRINCIPAL="alice"
ACCOUNT="acct-acme-team"
PROVIDER="claude-team"
CONFIG_DIR="~/.claude-logins/acme"
LEGAL_OWNER="Acme"
EOF
out="$( registry_login_load good >/dev/null 2>&1; printf '%s|%s|%s|%s|%s|%s' \
  "$LOGIN_SLUG" "$LOGIN_PRINCIPAL" "$LOGIN_ACCOUNT" "$LOGIN_PROVIDER" \
  "$LOGIN_CONFIG_DIR_RAW" "$LOGIN_LEGAL_OWNER" )"
is "every field lands" "$out" "good|alice|acct-acme-team|claude-team|~/.claude-logins/acme|Acme"

echo "== 2. the parser refuses what a source would have run =="
refuse() { # <name> <description> <expected text fragment> — reads bad.d
  local n="$1" desc="$2" want="$3" err rc
  err="$( STEWARD_LOGINS_DIR="$FX/bad.d" registry_login_load "$n" 2>&1 >/dev/null )"; rc=$?
  if [ "$rc" -eq 0 ]; then bad "$desc" "accepted, should have refused"
  else has "$desc" "$err" "$want"; fi
}

badrow cmdsub <<'EOF'
PRINCIPAL="alice"
ACCOUNT="acct-acme-team"
PROVIDER="claude-team"
CONFIG_DIR="~/.claude-logins/$(id -un)"
LEGAL_OWNER="Acme"
EOF
refuse cmdsub "a command substitution refuses" "substitution"

badrow backtick <<'EOF'
PRINCIPAL="alice"
ACCOUNT="acct-acme-team"
PROVIDER="claude-team"
CONFIG_DIR="~/.claude-logins/`id -un`"
LEGAL_OWNER="Acme"
EOF
refuse backtick "a backtick refuses" "substitution"

badrow varexp <<'EOF'
PRINCIPAL="alice"
ACCOUNT="acct-acme-team"
PROVIDER="claude-team"
CONFIG_DIR="${HOME}/.claude-logins/acme"
LEGAL_OWNER="Acme"
EOF
refuse varexp "a variable expansion refuses" "substitution"

badrow unknownkey <<'EOF'
PRINCIPAL="alice"
ACCOUNT="acct-acme-team"
PROVIDER="claude-team"
CONFIG_DIR="~/.claude-logins/acme"
LEGAL_OWNER="Acme"
PATH="/tmp/evil"
EOF
refuse unknownkey "an unknown key refuses" "unknown key"

badrow dupkey <<'EOF'
PRINCIPAL="alice"
PRINCIPAL="bob"
ACCOUNT="acct-acme-team"
PROVIDER="claude-team"
CONFIG_DIR="~/.claude-logins/acme"
LEGAL_OWNER="Acme"
EOF
refuse dupkey "a duplicate key refuses" "duplicate key"

badrow unquoted <<'EOF'
PRINCIPAL=alice
ACCOUNT="acct-acme-team"
PROVIDER="claude-team"
CONFIG_DIR="~/.claude-logins/acme"
LEGAL_OWNER="Acme"
EOF
refuse unquoted "an unquoted value refuses" "must be written"

badrow trailing <<'EOF'
PRINCIPAL="alice" ; rm -rf /
ACCOUNT="acct-acme-team"
PROVIDER="claude-team"
CONFIG_DIR="~/.claude-logins/acme"
LEGAL_OWNER="Acme"
EOF
refuse trailing "text after the closing quote refuses" "must be written"

badrow missing <<'EOF'
PRINCIPAL="alice"
PROVIDER="claude-team"
CONFIG_DIR="~/.claude-logins/acme"
LEGAL_OWNER="Acme"
EOF
refuse missing "a missing required key refuses" "ACCOUNT"

badrow emptylegal <<'EOF'
PRINCIPAL="alice"
ACCOUNT="acct-acme-team"
PROVIDER="claude-team"
CONFIG_DIR="~/.claude-logins/acme"
LEGAL_OWNER=""
EOF
refuse emptylegal "an empty LEGAL_OWNER refuses" "who pays"

badrow badprovider <<'EOF'
PRINCIPAL="alice"
ACCOUNT="acct-acme-team"
PROVIDER="claude-enterprise"
CONFIG_DIR="~/.claude-logins/acme"
LEGAL_OWNER="Acme"
EOF
refuse badprovider "an unknown PROVIDER refuses" "PROVIDER"

badrow badprincipal <<'EOF'
PRINCIPAL="Alice Example"
ACCOUNT="acct-acme-team"
PROVIDER="claude-team"
CONFIG_DIR="~/.claude-logins/acme"
LEGAL_OWNER="Acme"
EOF
refuse badprincipal "a PRINCIPAL that is not a member form refuses" "PRINCIPAL"

echo "== 3. a CR byte refuses (a file edited on another platform) =="
printf 'PRINCIPAL="alice"\r\nACCOUNT="acct-acme-team"\r\nPROVIDER="claude-team"\r\nCONFIG_DIR="~/.claude-logins/acme"\r\nLEGAL_OWNER="Acme"\r\n' \
  > "$FX/bad.d/crlf.conf"; chmod 600 "$FX/bad.d/crlf.conf"
refuse crlf "a CR byte refuses" "control character"

echo "== 4. the file's own state is asked about before its content =="
ln -s "$FX/logins.d/good.conf" "$FX/bad.d/linked.conf"
refuse linked "a symlinked row refuses" "symlink"
cp "$FX/logins.d/good.conf" "$FX/bad.d/loose.conf"
chmod 666 "$FX/bad.d/loose.conf"
refuse loose "a world-writable row refuses" "writable"

echo "== 4b. the REGISTER DIRECTORY's own state is asked about too =="
# A row can be 600 inside a directory anybody can write to, and then anybody can
# REPLACE it. Grind 2 names the parent; this is the register's own parent.
mkdir -p "$FX/loose.d"
cp "$FX/logins.d/good.conf" "$FX/loose.d/good.conf"; chmod 600 "$FX/loose.d/good.conf"
chmod 777 "$FX/loose.d"
( STEWARD_LOGINS_DIR="$FX/loose.d" registry_login_load good >/dev/null 2>&1 )
is "a world-writable register directory is rc 78" "$?" "78"
chmod 700 "$FX/loose.d"

echo "== 5. a failed load leaks nothing from the previous one =="
# BOTH LOADS RUN IN THIS SHELL, un-subshelled — the property under test is that
# the globals are cleared in the CALLER, and a subshell would hide exactly that.
# The directory is switched with a plain assignment rather than a command
# prefix: `VAR=x some_function` leaks the assignment in some bash versions, and
# a fixture seam must not depend on which.
registry_login_load good >/dev/null 2>&1
STEWARD_LOGINS_DIR="$FX/bad.d"
registry_login_load dupkey >/dev/null 2>&1
STEWARD_LOGINS_DIR="$FX/logins.d"
is "PRINCIPAL is cleared after a refusal" "$LOGIN_PRINCIPAL" ""
is "CONFIG_DIR is cleared after a refusal" "$LOGIN_CONFIG_DIR_RAW" ""

echo "== 6. an absent register REFUSES the listing, never reads as empty =="
( STEWARD_LOGINS_DIR="$FX/nope" registry_login_list >/dev/null 2>&1 )
is "listing an absent register is rc 78" "$?" "78"

echo "== 6b. a DANGLING symlink row is LISTED, so the register check can see it =="
# `-e` follows the link and would skip it silently; the loader would then never
# be asked, and registry_login_check would certify a register containing a row
# it never looked at.
ln -s "$FX/does-not-exist.conf" "$FX/bad.d/dangling.conf"
out="$( STEWARD_LOGINS_DIR="$FX/bad.d" registry_login_list )"
case "$out" in *dangling*) ok "a dangling row is listed" ;;
  *) bad "a dangling row is listed" "the lister skipped it: $out" ;; esac
( STEWARD_LOGINS_DIR="$FX/bad.d" registry_login_check >/dev/null 2>&1 )
is "and the register check therefore refuses" "$?" "78"
rm -f "$FX/bad.d/dangling.conf"

echo "== 7. the owner's home is resolved, never guessed =="
cat > "$FX/homelookup" <<'STUB'
#!/bin/bash
case "$1" in
  alice) printf '/srv/homes/alice\n' ;;
  relative) printf 'srv/homes/relative\n' ;;
  dotted) printf '/srv/homes/../etc\n' ;;
  empty) : ;;
  *) exit 1 ;;
esac
STUB
chmod +x "$FX/homelookup"
export STEWARD_HOME_LOOKUP_CMD="$FX/homelookup"

is "a known account resolves" "$( _registry_owner_home alice )" "/srv/homes/alice"
( _registry_owner_home nosuch >/dev/null 2>&1 ); is "an unknown account is rc 78" "$?" "78"
( _registry_owner_home empty >/dev/null 2>&1 ); is "an empty answer is rc 78" "$?" "78"
( _registry_owner_home relative >/dev/null 2>&1 ); is "a relative home is rc 78" "$?" "78"
( _registry_owner_home dotted >/dev/null 2>&1 ); is "a home carrying .. is rc 78" "$?" "78"
err="$( _registry_owner_home nosuch 2>&1 >/dev/null )"
has "the refusal names the account" "$err" "nosuch"

echo "== 8. the legacy exception is named by the estate, never by the code =="
mkdir -p "$FX/estate/estate"
export STEWARD_ESTATE_ROOT="$FX/estate"
estate() { printf '%s\n' "$@" > "$FX/estate/estate/steward.conf"; }

estate 'LABEL_PREFIX="com.example.claude"'
is "an estate without the key answers empty, rc 0" "$( registry_legacy_login; echo "rc=$?" )" "rc=0"
estate 'LABEL_PREFIX="com.example.claude"' 'LEGACY_LOGIN="acme-old"'
is "the named slug is returned" "$( registry_legacy_login )" "acme-old"
estate 'LABEL_PREFIX="com.example.claude"' 'LEGACY_LOGIN="Not A Slug"'
( registry_legacy_login >/dev/null 2>&1 ); is "a malformed key is rc 78" "$?" "78"
echo "== 8b. a broken estate file REFUSES, never reads as absent =="
printf 'LEGACY_LOGIN="acme"\nthis is not shell (\n' > "$FX/estate/estate/steward.conf"
( registry_legacy_login >/dev/null 2>&1 ); is "a broken estate file is rc 78" "$?" "78"
err="$( registry_legacy_login 2>&1 >/dev/null )"
has "the refusal names the estate file" "$err" "could not be read"
estate 'LABEL_PREFIX="com.example.claude"'
unset STEWARD_ESTATE_ROOT

echo "== 9. CONFIG_DIR is grammar, resolved against the OWNER's home =="
export STEWARD_HOME_LOOKUP_CMD="$FX/homelookup"
mkdir -p "$FX/estate/estate"; export STEWARD_ESTATE_ROOT="$FX/estate"
printf 'LABEL_PREFIX="com.example.claude"\nLEGACY_LOGIN="acme-old"\n' \
  > "$FX/estate/estate/steward.conf"

# ITS OWN LEAF, AND THAT MATTERS. `good` (test 1) already claims
# ~/.claude-logins/acme; a second sound row on the same directory is exactly the
# collision registry_login_check refuses, and test 11's control group ("a
# register of only sound rows passes rc 0") would then be impossible to satisfy.
# Two rows sharing a leaf here would have made that assertion permanently red
# and looked like a bug in the check.
row named <<'EOF'
PRINCIPAL="alice"
ACCOUNT="acct-acme-team"
PROVIDER="claude-team"
CONFIG_DIR="~/.claude-logins/acme-team"
LEGAL_OWNER="Acme"
EOF
is "the named form resolves against the owner's home" \
   "$( registry_login_config_dir named alice )" "/srv/homes/alice/.claude-logins/acme-team"

is "the CALLER's HOME is never used" \
   "$( HOME=/wrong registry_login_config_dir named alice )" "/srv/homes/alice/.claude-logins/acme-team"

# THE ESTATE-NAMED LEGACY ROW IS SOUND, so it lives in the sound directory.
row acme-old <<'EOF'
PRINCIPAL="alice"
ACCOUNT="acct-acme-legacy"
PROVIDER="claude-max"
CONFIG_DIR="~/.claude"
LEGAL_OWNER="Acme"
EOF
is "the estate-named legacy row may use the unnamed default" \
   "$( registry_login_config_dir acme-old alice )" "/srv/homes/alice/.claude"

# A SECOND ROW ON THE UNNAMED DEFAULT IS A REFUSAL, so it lives in bad.d.
badrow other-old <<'EOF'
PRINCIPAL="alice"
ACCOUNT="acct-acme-other"
PROVIDER="claude-max"
CONFIG_DIR="~/.claude"
LEGAL_OWNER="Acme"
EOF
( STEWARD_LOGINS_DIR="$FX/bad.d" registry_login_config_dir other-old alice >/dev/null 2>&1 )
is "a row NOT named by the estate may not" "$?" "78"
err="$( STEWARD_LOGINS_DIR="$FX/bad.d" registry_login_config_dir other-old alice 2>&1 >/dev/null )"
has "the refusal names the estate key" "$err" "LEGACY_LOGIN"

badgrammar() { # <name> <CONFIG_DIR value> <description> — always in bad.d
  badrow "$1" <<EOF
PRINCIPAL="alice"
ACCOUNT="acct-acme-team"
PROVIDER="claude-team"
CONFIG_DIR="$2"
LEGAL_OWNER="Acme"
EOF
  ( STEWARD_LOGINS_DIR="$FX/bad.d" registry_login_config_dir "$1" alice >/dev/null 2>&1 )
  is "$3" "$?" "78"
}
badgrammar absolute  "/srv/homes/alice/.claude-logins/acme" "an absolute path refuses"
badgrammar dotdot    "~/.claude-logins/../.ssh"             "a .. component refuses"
badgrammar dot       "~/.claude-logins/."                   "a . component refuses"
badgrammar emptyleaf "~/.claude-logins/"                    "an empty last component refuses"
badgrammar deep      "~/.claude-logins/a/b"                 "a nested path refuses"
badgrammar wrongroot "~/.config/claude"                     "another root refuses"
badgrammar upper     "~/.claude-logins/Acme"                "a non-slug directory name refuses"
badgrammar space     "~/.claude-logins/ac me"               "a space refuses"
badgrammar tildeonly "~"                                    "the bare home refuses"

echo "== 10. the directory's own state refuses when it EXISTS =="
mkdir -p "$FX/realhome/.claude-logins/acme-team"
cat > "$FX/homelookup2" <<STUB
#!/bin/bash
[ "\$1" = "alice" ] && printf '%s\n' "$FX/realhome"
STUB
chmod +x "$FX/homelookup2"
real() { STEWARD_HOME_LOOKUP_CMD="$FX/homelookup2" registry_login_config_dir named alice; }

is "an existing, tight directory resolves" "$( real )" "$FX/realhome/.claude-logins/acme-team"
chmod 777 "$FX/realhome/.claude-logins/acme-team"
( real >/dev/null 2>&1 ); is "a world-writable existing directory refuses" "$?" "78"
chmod 700 "$FX/realhome/.claude-logins/acme-team"
rm -rf "$FX/realhome/.claude-logins/acme-team"
ln -s /tmp "$FX/realhome/.claude-logins/acme-team"
( real >/dev/null 2>&1 ); is "a symlinked target refuses" "$?" "78"
rm -f "$FX/realhome/.claude-logins/acme-team"
( real >/dev/null 2>&1 ); is "a directory that does not exist YET is allowed" "$?" "0"

echo "== 10b. the PARENT is asked about too (grind 2 names parent AND target) =="
# A tight target under a world-writable parent is not tight: anybody can rename
# the target away and put their own directory there. Grind 2 says "symlinked
# parent/target" and the first version of this resolver only checked the target.
chmod 777 "$FX/realhome/.claude-logins"
( real >/dev/null 2>&1 ); is "a world-writable parent refuses" "$?" "78"
chmod 700 "$FX/realhome/.claude-logins"
rm -rf "$FX/realhome/.claude-logins"
ln -s /tmp "$FX/realhome/.claude-logins"
( real >/dev/null 2>&1 ); is "a symlinked parent refuses" "$?" "78"
err="$( real 2>&1 >/dev/null )"
has "the parent refusal says PARENT" "$err" "parent"
rm -f "$FX/realhome/.claude-logins"
( real >/dev/null 2>&1 ); is "a parent that does not exist YET is allowed" "$?" "0"

echo "== 10c. PRINCIPAL is the human, USERNAME is the unix account =="
# THE FIXTURE THAT WOULD HAVE CAUGHT THE FIRST registry_login_check.
# PRINCIPAL=alice, the unix account is a-user, and the resolved directory must
# land under that account's home. The same pair is proven again through the
# projection (uppgift 15) and through a launch branch (uppgift 6) — one
# measurement per layer, because each layer resolves a home for itself.
#
# THE HOME ROOT IS /srv/homes/, NEVER /home/. This suite is on PRODUCT FILES
# from task 1 onward, and the leak guard's class 5 counts every
# `/home/<name>` on that surface with an assertion of `-eq 0`. The pair under
# test is PRINCIPAL != USERNAME, which any root proves equally well — and the
# stub in test 7 above already uses /srv/homes/alice, so this keeps one root
# for the whole suite.
cat > "$FX/homelookup3" <<'STUB'
#!/bin/bash
case "$1" in
  a-user) printf '/srv/homes/a-user\n' ;;
  alice)  exit 1 ;;   # the HUMAN is not a unix account — resolving it MUST fail
  *) exit 1 ;;
esac
STUB
chmod +x "$FX/homelookup3"
is "the resolver takes a UNIX ACCOUNT and lands in its home" \
   "$( STEWARD_HOME_LOOKUP_CMD="$FX/homelookup3" registry_login_config_dir named a-user )" \
   "/srv/homes/a-user/.claude-logins/acme-team"
( STEWARD_HOME_LOOKUP_CMD="$FX/homelookup3" registry_login_config_dir named alice >/dev/null 2>&1 )
is "resolving the PRINCIPAL as a unix account refuses (it is not one)" "$?" "78"

echo "== 11. the register-wide check catches what a row cannot see =="
# TWO ROWS ON ONE DIRECTORY, in a one-shot register of their own — never in the
# sound directory, so the control group below stays meaningful.
mkdir -p "$FX/collide.d"
for n in dup-a dup-b; do
  printf 'PRINCIPAL="alice"\nACCOUNT="acct-acme-team"\nPROVIDER="claude-team"\nCONFIG_DIR="~/.claude-logins/same"\nLEGAL_OWNER="Acme"\n' \
    > "$FX/collide.d/$n.conf"
  chmod 600 "$FX/collide.d/$n.conf"
done
( STEWARD_LOGINS_DIR="$FX/collide.d" registry_login_check >/dev/null 2>&1 )
is "two rows on the SAME dir for the SAME principal refuse" "$?" "78"
err="$( STEWARD_LOGINS_DIR="$FX/collide.d" registry_login_check 2>&1 >/dev/null )"
has "the refusal names the shared directory" "$err" ".claude-logins/same"
has "the refusal names the second row" "$err" "dup-b"

# THE CONTROL GROUP THAT PROVES IT IS A PAIR AND NOT A PATH. Two DIFFERENT
# humans naming the same relative directory are two directories in two homes.
# A check that compared paths alone would refuse this — and that refusal is
# exactly what would have blocked a second human's own login row.
mkdir -p "$FX/twoprincipals.d"
printf 'PRINCIPAL="alice"\nACCOUNT="acct-a"\nPROVIDER="claude-team"\nCONFIG_DIR="~/.claude-logins/shared"\nLEGAL_OWNER="Acme"\n' \
  > "$FX/twoprincipals.d/a.conf"
printf 'PRINCIPAL="bob"\nACCOUNT="acct-b"\nPROVIDER="claude-team"\nCONFIG_DIR="~/.claude-logins/shared"\nLEGAL_OWNER="Acme"\n' \
  > "$FX/twoprincipals.d/b.conf"
chmod 600 "$FX/twoprincipals.d"/*.conf
( STEWARD_LOGINS_DIR="$FX/twoprincipals.d" registry_login_check >/dev/null 2>&1 )
is "two DIFFERENT principals on the same relative dir is NOT a collision" "$?" "0"

# AND THE CHECK NEVER RESOLVES A HOME — proven by making resolution IMPOSSIBLE.
# Neither `alice` nor `bob` is a unix account on the machine running this suite,
# and the lookup seam is aimed at a stub that refuses everything. A check that
# resolved homes would refuse here; one that compares declarations cannot tell
# the difference.
printf '#!/bin/bash\nexit 1\n' > "$FX/homelookup-never"; chmod +x "$FX/homelookup-never"
( STEWARD_LOGINS_DIR="$FX/twoprincipals.d" \
  STEWARD_HOME_LOOKUP_CMD="$FX/homelookup-never" registry_login_check >/dev/null 2>&1 )
is "the check passes even when NO home can be resolved" "$?" "0"

# TWO ROWS ON THE UNNAMED DEFAULT, same shape, its own register.
mkdir -p "$FX/twolegacy.d"
cp "$FX/logins.d/acme-old.conf" "$FX/twolegacy.d/acme-old.conf"
cp "$FX/bad.d/other-old.conf"   "$FX/twolegacy.d/other-old.conf"
chmod 600 "$FX/twolegacy.d"/*.conf
( STEWARD_LOGINS_DIR="$FX/twolegacy.d" registry_login_check >/dev/null 2>&1 )
is "two rows claiming the unnamed default refuse" "$?" "78"

# AN UNPARSABLE ROW IS A REGISTER FAULT, never a skipped row.
mkdir -p "$FX/onebad.d"
cp "$FX/logins.d/named.conf" "$FX/onebad.d/named.conf"
cp "$FX/bad.d/dupkey.conf"   "$FX/onebad.d/dupkey.conf"
chmod 600 "$FX/onebad.d"/*.conf
( STEWARD_LOGINS_DIR="$FX/onebad.d" registry_login_check >/dev/null 2>&1 )
is "one unparsable row fails the whole register" "$?" "78"

# THE CONTROL GROUP, and it is the whole reason the fixtures are split. Without
# it every assertion above is satisfied by a check that refuses EVERYTHING.
( registry_login_check >/dev/null 2>&1 )
is "a register of only sound rows passes rc 0" "$?" "0"

echo "pass=$pass fail=$fail"
[ "$fail" -eq 0 ]
