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
# The register check's refusal on this row is asserted once registry_login_check exists.
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

echo "pass=$pass fail=$fail"
[ "$fail" -eq 0 ]
