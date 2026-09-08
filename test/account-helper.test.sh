#!/bin/bash
# test/account-helper.test.sh - the privileged helper, measured on what it
# CALLS. Nothing here runs as root and nothing here creates an account: id,
# getent, useradd, usermod, passwd, loginctl, install, systemd-tmpfiles, chmod,
# mkdir and mv are all shims that record their argv. What must be shown is the
# argument guard, the receipt lines and the exact commands - the account
# creation itself is the operating system's job and is not ours to test.
#
# HOW THE SHIMS GET IN FRONT. The helper pins its own PATH as its first
# statement, so prepending to PATH from here would be overridden - which is
# exactly what that line is for. Behaviour is therefore measured against a COPY
# of the helper, derived with one sed that rewrites that single production PATH
# line to put the fixture bin directory first; the REAL file is grepped for the
# exact production lines instead. A second copy, used by the last two cases
# only, additionally relocates the helper's fixed /home root into the fixture,
# because whether an archive destination exists and whether a home is a symlink
# are questions about real directories no test may create under /home. Both
# derivations are asserted: a copy identical to what it was derived from would
# mean the sed matched nothing and the cases using it would measure nothing.
#
# NOT EVERYTHING IS SHIMMED. date, grep, head, cat and printf run for real
# inside the fixture's own PATH; all of them are read-only or write only under
# $FX. Nothing outside $FX is written by this suite.
set -u
here="$(CDPATH= cd -- "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
H="$here/linux/steward-account-helper"
pass=0; fail=0
ok()  { pass=$((pass+1)); printf '  ok   %s\n' "$1"; }
bad() { fail=$((fail+1)); printf '  FAIL %s\n     %s\n' "$1" "${2:-}"; }
is()  { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "wanted '$3', got '$2'"; fi; }
has() { case "$2" in *"$3"*) ok "$1" ;; *) bad "$1" "missing '$3' in: $2" ;; esac; }
no()  { case "$2" in *"$3"*) bad "$1" "found '$3' in: $2" ;; *) ok "$1" ;; esac; }
FX="$(mktemp -d)"; trap 'rm -rf "$FX"' EXIT
mkdir -p "$FX/bin"
echo "account-helper"

# $FX/passwd is the fixture's whole account database, one <name>:<uid>:<home>
# per line. Everything the helper learns about an account comes from here, so a
# case can put it in front of root, a system account, or an account whose home
# is somewhere other than /home and measure what it refuses.
db() { printf '%s\n' "$@" > "$FX/passwd"; }
db_empty() { : > "$FX/passwd"; }

mkshim() { # <name> <body>
  cat > "$FX/bin/$1" <<EOF
#!/bin/bash
echo "$1 \$*" >> "$FX/calls"
$2
EOF
  chmod 755 "$FX/bin/$1"
}
: > "$FX/calls"
db_empty
mkshim id 'echo "${FAKE_UID:-0}"'
# getent answers passwd out of $FX/passwd and group for video only - that is
# how the "already there" branch and every floor case are exercised without a
# real account database.
mkshim getent 'case "$1" in
  passwd)
    row=""
    while IFS= read -r l; do
      case "$l" in "$2:"*) row="$l"; break ;; esac
    done < "'"$FX"'/passwd"
    [ -n "$row" ] || exit 2
    rest="${row#*:}"
    printf "%s:x:%s:%s::%s:/bin/bash\n" "$2" "${rest%%:*}" "${rest%%:*}" "${rest#*:}"
    exit 0 ;;
  group)  case "$2" in video) exit 0 ;; *) exit 2 ;; esac ;;
esac
exit 2'
mkshim useradd 'for a in "$@"; do u="$a"; done
printf "%s:1001:/home/%s\n" "$u" "$u" >> "'"$FX"'/passwd"
exit 0'
mkshim usermod 'exit 0'
mkshim passwd 'exit 0'
mkshim loginctl 'exit 0'
mkshim install 'cat > "'"$FX"'/fragment"; exit 0'
mkshim systemd-tmpfiles 'exit 0'
mkshim chmod 'exit 0'
mkshim mkdir 'exit 0'
mkshim mv 'exit 0'

echo "== the helper pins its own PATH and locale, before anything else =="
FIXED_PATH='export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin'
FIXED_LOCALE='export LC_ALL=C'
is "the real helper pins a fixed PATH" \
   "$(grep -Fxc -- "$FIXED_PATH" "$H" | tr -d ' ')" "1"
is "the real helper pins LC_ALL=C" \
   "$(grep -Fxc -- "$FIXED_LOCALE" "$H" | tr -d ' ')" "1"
is "and both are its first two statements" \
   "$(grep -vE '^[[:space:]]*(#|$)' "$H" | head -2)" \
   "$(printf '%s\n%s' "$FIXED_PATH" "$FIXED_LOCALE")"

# The one derivation: the production PATH line, with the fixture's bin first.
sed "s|^export PATH=|export PATH=$FX/bin:|" "$H" > "$FX/helper"
if cmp -s "$H" "$FX/helper"; then
  bad "the derived copy differs from the original" "sed matched nothing - every behavioural case below would be meaningless"
else
  ok "the derived copy differs from the original"
fi
has "and the copy searches the fixture bin first" \
    "$(grep -F -- 'export PATH=' "$FX/helper")" \
    "export PATH=$FX/bin:/usr/local/sbin:"

# useradd on a host with USERGROUPS_ENAB gives the account its own group, so a
# 750 home's group bits reach nobody; on a host with a shared default group
# they reach every member of it. Either way "the steward account's group
# reaches it" was never true, and a wrong rationale in THIS file gets cited as
# an authority by whatever is written next.
no  "the file does not claim a 750 home is reachable by the steward group" \
    "$(cat "$H")" "the steward account's group reaches it"

run() { ( bash "$FX/helper" "$@" ); }

# A SECOND COPY, FOR THE TWO CASES THAT NEED A REAL DIRECTORY. Whether the
# archive destination already exists, and whether the home is a symlink, are
# questions the helper asks the filesystem about paths under the fixed /home -
# which no test may create. This copy relocates that one fixed root into the
# fixture, so those two answers can be arranged and the refusals measured
# instead of read. The /home literals are asserted against the REAL file below.
# The home rewrite runs first so the bin directory spliced into PATH is never
# itself rewritten.
FXHOME="$FX/estate/home"
sed -e "s|/home|$FXHOME|g" -e "s|^export PATH=|export PATH=$FX/bin:|" "$H" > "$FX/helper-fs"
if cmp -s "$FX/helper" "$FX/helper-fs"; then
  bad "the relocated copy differs from the first copy" "the /home rewrite matched nothing"
else
  ok "the relocated copy differs from the first copy"
fi
runfs() { ( bash "$FX/helper-fs" "$@" ); }

echo "== the argument guard =="
out="$(run 2>&1)"; rc=$?
is  "no arguments is rc 64" "$rc" "64"
has "and the usage names the sudoers line" "$out" "NOPASSWD: /usr/local/sbin/steward-account-helper"
out="$(run add 2>&1)"; rc=$?
is  "add without a name is rc 64" "$rc" "64"
out="$(run add 'Alice' 2>&1)"; rc=$?
is  "an upper-case name is rc 64" "$rc" "64"
out="$(run add 'a' 2>&1)"; rc=$?
is  "a one-character name is rc 64" "$rc" "64"
out="$(run add 'alice; rm -rf /' 2>&1)"; rc=$?
is  "a name with a metacharacter is rc 64" "$rc" "64"
out="$(run add "$(printf 'a%.0s' $(seq 1 40))" 2>&1)"; rc=$?
is  "a name over 32 characters is rc 64" "$rc" "64"
out="$(run frobnicate alice 2>&1)"; rc=$?
is  "an unknown sub-command is rc 64" "$rc" "64"
# A typo'd offboard must not become a silent onboard.
out="$(run add alice --archive-home 2>&1)"; rc=$?
is  "--archive-home on add is rc 64" "$rc" "64"
# The guard is a bracket RANGE, and range membership follows the collation
# order of the locale. sudo keeps LC_* by default, so without the helper's own
# LC_ALL=C a caller can pick a locale in which 'Alice' collates inside [a-z] -
# and the one guarantee this whole boundary rests on stops being true.
out="$( ( export LC_ALL=en_US.ISO8859-1 LANG=en_US.ISO8859-1 LC_COLLATE=en_US.ISO8859-1
          bash "$FX/helper" add 'Alice' ) 2>&1 )"; rc=$?
is  "an upper-case name is still rc 64 under a collating locale" "$rc" "64"
is  "and none of those called anything" "$(wc -l < "$FX/calls" | tr -d ' ')" "0"

echo "== it refuses when it is not root =="
out="$( ( export FAKE_UID=1000; bash "$FX/helper" add alice ) 2>&1 )"; rc=$?
is  "a non-root run is rc 77" "$rc" "77"
has "and says so" "$out" "root"

echo "== add, on a host where the account does not exist =="
: > "$FX/calls"; db_empty
out="$(run add alice 2>&1)"; rc=$?
is  "add succeeds" "$rc" "0"
calls="$(cat "$FX/calls")"
has "it creates the account" "$calls" "useradd --create-home --shell /bin/bash alice"
has "it tightens the home" "$calls" "chmod 750 /home/alice"
has "it adds the group that exists" "$calls" "usermod -aG video alice"
no  "and not the group that does not" "$calls" "usermod -aG render alice"
has "it locks the password" "$calls" "passwd -l alice"
has "it enables lingering" "$calls" "loginctl enable-linger alice"
has "it installs the rig fragment" "$calls" "install -m 0644 /dev/stdin /etc/tmpfiles.d/steward-rig-alice.conf"
# The bytes matter more than the argv: systemd applies this file as root at
# every boot, and a mode, an owner or a leading letter other than 'd' would
# change what it does to /run without changing a single argv assertion.
is  "the fragment's bytes are exact" "$(cat "$FX/fragment" 2>&1)" \
    "d /run/steward/rig/alice 0710 alice steward -"
is  "and the install argv carries mode 0644 and no other flag" \
    "$(grep '^install ' "$FX/calls")" \
    "install -m 0644 /dev/stdin /etc/tmpfiles.d/steward-rig-alice.conf"
has "it applies the fragment" "$calls" "systemd-tmpfiles --create /etc/tmpfiles.d/steward-rig-alice.conf"
has "the receipt names the fragment" "$out" "helper: tmpfiles /etc/tmpfiles.d/steward-rig-alice.conf"
has "the receipt names the account" "$out" "helper: account alice"

echo "== add, on a host where the account already exists =="
: > "$FX/calls"; db 'alice:1001:/home/alice'
out="$(run add alice 2>&1)"; rc=$?
is  "a second add succeeds" "$rc" "0"
calls="$(cat "$FX/calls")"
no  "and does not create the account again" "$calls" "useradd"
has "but still reports the fragment" "$out" "helper: tmpfiles /etc/tmpfiles.d/steward-rig-alice.conf"
# A home this helper did not create may have been tightened to 0700 on purpose,
# and 750 would be a loosening. Everything else here is an idempotent re-apply;
# the mode is not.
no  "and it leaves an existing home's mode alone" "$calls" "chmod"
has "and says so in the receipt" "$out" "helper: home /home/alice left as it is"

echo "== lock =="
: > "$FX/calls"; db 'alice:1001:/home/alice'
out="$(run lock alice 2>&1)"; rc=$?
is  "lock succeeds" "$rc" "0"
calls="$(cat "$FX/calls")"
has "it stops lingering (and with it the session units)" "$calls" "loginctl disable-linger alice"
has "it locks the password" "$calls" "usermod --lock alice"
has "it expires the account" "$calls" "usermod --expiredate 1 alice"
no  "and it does not touch the home" "$calls" "mv "

: > "$FX/calls"
out="$(run lock alice --archive-home 2>&1)"; rc=$?
is  "lock --archive-home succeeds" "$rc" "0"
calls="$(cat "$FX/calls")"
has "it makes the archive root" "$calls" "mkdir -p /home/.offboarded"
has "it moves the home under a dated name" "$calls" "mv /home/alice /home/.offboarded/alice-"
has "and the receipt names the destination" "$out" "helper: archived /home/.offboarded/alice-"

: > "$FX/calls"; db_empty
out="$(run lock alice 2>&1)"; rc=$?
is  "locking an account that does not exist is rc 70" "$rc" "70"
has "and says which one" "$out" "alice"

echo "== the floor: it manages ordinary accounts and nothing else =="
# The name guard says what a name may LOOK like; it says nothing about WHICH
# account the caller named. Every system account on a stock host matches
# it, and their home fields are real system directories - so without a floor,
# an account holding nothing but the sudoers line can expire root or move /dev
# out of the filesystem through the one boundary meant to prevent exactly that.
: > "$FX/calls"
db 'root:0:/root'
out="$(run add root 2>&1)"; rc=$?
is  "add root is rc 64" "$rc" "64"
out="$(run lock root --archive-home 2>&1)"; rc=$?
is  "lock root --archive-home is rc 64" "$rc" "64"
has "and it says which account it refused" "$out" "root"
db 'sys:3:/dev'
out="$(run lock sys --archive-home 2>&1)"; rc=$?
is  "lock sys --archive-home is rc 64" "$rc" "64"
has "and it names the uid it refused on" "$out" "uid 3"
db 'www-data:33:/var/www'
out="$(run add www-data 2>&1)"; rc=$?
is  "add www-data is rc 64" "$rc" "64"
has "and it names that uid too" "$out" "uid 33"
db 'alice:1001:/srv/x'
out="$(run lock alice --archive-home 2>&1)"; rc=$?
is  "an ordinary uid whose home is outside /home is rc 64" "$rc" "64"
has "and it names the home it refused" "$out" "/srv/x"
db 'alice:1001:/home/alice/nested'
out="$(run add alice 2>&1)"; rc=$?
is  "a home that is not a direct child of /home is rc 64" "$rc" "64"
db 'alice:1001:/home/bob'
out="$(run add alice 2>&1)"; rc=$?
is  "a home under another name is rc 64" "$rc" "64"
is  "and not one of those refusals ran a privileged command" \
    "$(grep -cvE '^(id|getent) ' "$FX/calls" | tr -d ' ')" "0"

echo "== the archive refuses anything that would make its receipt false =="
# The real file's fixed paths, asserted here because the cases below run
# against the copy that relocates them.
is  "the real helper archives under /home/.offboarded" \
    "$(grep -Fc -- 'DEST="/home/.offboarded/$USERNAME-$(date -u +%Y-%m-%d)"' "$H" | tr -d ' ')" "1"
is  "and creates that root there" \
    "$(grep -Fc -- 'mkdir -p /home/.offboarded' "$H" | tr -d ' ')" "1"
is  "and the floor pins the home to /home/<name>" \
    "$(grep -Fc -- '[ "$HOME_DIR" = "/home/$USERNAME" ]' "$H" | tr -d ' ')" "1"

today="$(date -u +%Y-%m-%d)"
mkdir -p "$FXHOME" "$FX/elsewhere"
db "alice:1001:$FXHOME/alice"

: > "$FX/calls"; rm -rf "$FXHOME/alice" "$FXHOME/.offboarded"; mkdir -p "$FXHOME/alice"
out="$(runfs lock alice --archive-home 2>&1)"; rc=$?
is  "the relocated copy still archives an ordinary home" "$rc" "0"
has "and moves it" "$(cat "$FX/calls")" "mv $FXHOME/alice $FXHOME/.offboarded/alice-$today"

# mv into an EXISTING directory moves the source inside it. Offboard, re-add,
# offboard again on the same day and the receipt names a path one level above
# the home - an operator restoring from it restores the previous archive.
: > "$FX/calls"; mkdir -p "$FXHOME/.offboarded/alice-$today"
out="$(runfs lock alice --archive-home 2>&1)"; rc=$?
is  "an archive destination that already exists is rc 70" "$rc" "70"
has "and the refusal names it" "$out" "$FXHOME/.offboarded/alice-$today"
no  "and nothing was moved" "$(cat "$FX/calls")" "mv "

# mv does not follow a symlinked source: it relocates the LINK and leaves the
# data where it was, still readable, under a receipt that says archived.
: > "$FX/calls"; rm -rf "$FXHOME/alice" "$FXHOME/.offboarded"
ln -s "$FX/elsewhere" "$FXHOME/alice"
out="$(runfs lock alice --archive-home 2>&1)"; rc=$?
is  "a home that is a symlink is rc 70" "$rc" "70"
has "and the refusal says why" "$out" "symlink"
no  "and nothing was moved" "$(cat "$FX/calls")" "mv "
rm -f "$FXHOME/alice"

printf '\n  %d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
