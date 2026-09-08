#!/bin/bash
# test/account-helper.test.sh - the privileged helper, measured on what it
# CALLS. Nothing here runs as root and nothing here creates an account: id,
# getent, useradd, usermod, passwd, loginctl, install, systemd-tmpfiles, chmod,
# mkdir, mv, stat, date, rm, rmdir, userdel and deluser are all shims that
# record their argv. What must be shown is the argument guard, the receipt lines
# and the exact commands - the account creation itself is the operating system's
# job and is not ours to test.
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
# NOT EVERYTHING IS SHIMMED. grep, head, cat and printf run for real inside the
# fixture's own PATH; all of them are read-only or write only under $FX. Nothing
# outside $FX is written by this suite. rm, rmdir, userdel and deluser ARE
# shimmed even though the helper is meant never to call three of them: a shim
# records an accidental call, an absent shim would run it.
#
# EVERY SHIM CAN BE MADE TO FAIL. FX_FAIL is the fixture's own knob, read by the
# shims and by nothing in the product; it names either a shim or a shim and its
# first argument, so one of the three usermod calls or one of the two chmod
# calls can be failed on its own. Before it, turning any of the helper's guards
# into `|| true` left this suite green while success receipts were printed for
# actions that had not happened.
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
echo "$1 \$*" >> "$FX/calls.all"
case " \${FX_FAIL:-} " in
  *" $1 "*|*" $1:\${1:-} "*) echo "$1: forced failure from the fixture" >&2; exit 9 ;;
esac
$2
EOF
  chmod 755 "$FX/bin/$1"
}
: > "$FX/calls"
db_empty
# id answers two questions: the caller's uid, and the group list of an account.
# FAKE_GROUPS is how an account that can become root - the one thing the floor
# has to refuse and cannot see in a passwd row - is put in front of the helper.
mkshim id 'case "${1:-}" in
  -nG) printf "%s\n" "${FAKE_GROUPS:-}"; exit 0 ;;
esac
echo "${FAKE_UID:-0}"'
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
    printf "%s:x:%s:%s::%s:/bin/bash\n" "${FAKE_ROW_NAME:-$2}" "${rest%%:*}" "${rest%%:*}" "${rest#*:}"
    exit 0 ;;
  group)  case "$2" in video) exit 0 ;; *) exit 2 ;; esac ;;
esac
exit 2'
# useradd answers two different questions and the shim answers both: -D reports
# the host's default HOME (the helper reads it before creating anything), and a
# real invocation registers the account. FAKE_NEW_UID and FAKE_NEW_HOME are how
# a host whose useradd lands somewhere other than /home/<name> is arranged -
# which is the one case where a privileged command has already run when the
# floor speaks.
mkshim useradd 'case "${1:-}" in
  -D) printf "%s\n" "${FAKE_USERADD_DEFAULT_HOME:-HOME=/home}"; exit 0 ;;
esac
for a in "$@"; do u="$a"; done
printf "%s:%s:%s\n" "$u" "${FAKE_NEW_UID:-1001}" "${FAKE_NEW_HOME:-/home/$u}" >> "'"$FX"'/passwd"
exit 0'
mkshim usermod 'exit 0'
mkshim passwd 'exit 0'
# loginctl answers the session list too: disable-linger releases logind's
# reference, but the user manager stays up while a session is open, so FAKE_SESSIONS
# is how a member who is logged in at the moment of offboarding is arranged.
mkshim loginctl 'case "${1:-}" in
  --no-legend)
    if [ -n "${FAKE_SESSIONS:-}" ]; then printf "%s\n" "${FAKE_SESSIONS}"; fi
    exit 0 ;;
esac
exit 0'
mkshim install 'cat > "'"$FX"'/fragment"; exit 0'
mkshim systemd-tmpfiles 'exit 0'
mkshim chmod 'exit 0'
mkshim mkdir 'exit 0'
mkshim mv 'exit 0'
# stat answers the device number, keyed on the path, so a home on one filesystem
# and an archive root on another can be put in front of the helper. Same number
# by default: on a stock host both are on the root filesystem.
mkshim stat 'case "${3:-}" in
  *.offboarded*) echo "${FAKE_DEV_ARCHIVE:-1}" ;;
  *)             echo "${FAKE_DEV_HOME:-1}" ;;
esac
exit 0'
mkshim date '/bin/date "$@"'
# THE DELETION SHIMS. rm is the helper's own tmpfiles fragment and nothing else;
# rmdir removes an EMPTY rig socket directory; userdel and deluser must never be
# reached at all. All four are shimmed so that a call is recorded rather than
# performed, and the assertions at the end of this file forbid every one of them
# the helper has no business making.
mkshim rm 'exit 0'
mkshim rmdir 'if [ -n "${FAKE_RIGDIR_BUSY:-}" ]; then exit 1; fi; exit 0'
mkshim userdel 'exit 0'
mkshim deluser 'exit 0'

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
# Two more rationales in the same class, and the same guard. bash reads BASH_ENV
# before the first statement of a script, so the two exports cannot be what
# keeps the environment out - env_reset in the sudoers line is. And the flag
# comment must describe what the code below it does, not its opposite.
no  "the file does not claim its two exports are what keeps the environment out" \
    "$(cat "$H")" "and only because of them"
has "it names env_reset as what keeps BASH_ENV out" "$(cat "$H")" "env_reset"
no  "the file does not say add accepts and ignores --archive-home" \
    "$(cat "$H")" "Accepted and ignored on add"

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
# --user-group IS WHAT MAKES THE 750 MEAN ANYTHING. Without it the account's
# group is whatever /etc/login.defs says, and on a host with USERGROUPS_ENAB no
# that is a group every member is in - so a 750 home is r-x to every other
# member, and the per-account model credentials under it are readable by all of
# them. The flag forces a group of one regardless of that host setting.
has "it creates the account with a group of its own" "$calls" \
    "useradd --create-home --user-group --shell /bin/bash alice"
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
# AN ACCOUNT THIS HELPER DID NOT CREATE IS NOT ITS ACCOUNT TO CONFIGURE, and
# every one of these is destructive on a human's existing account: a password
# lock takes that person's sudo away, a group add hands them a device they were
# not given, and lingering starts a user manager nobody asked for. All three
# used to run here under the receipt "already exists" and rc 0, which says the
# helper looked and did nothing.
no  "and it does not lock an existing account's password" "$calls" "passwd -l"
no  "and it does not add it to groups" "$calls" "usermod"
no  "and it does not turn lingering on" "$calls" "loginctl"
has "and the receipt names what it left alone" "$out" \
    "helper: groups, password and lingering left as is"

echo "== lock =="
: > "$FX/calls"; db 'alice:1001:/home/alice'
out="$(run lock alice 2>&1)"; rc=$?
is  "lock succeeds" "$rc" "0"
calls="$(cat "$FX/calls")"
has "it stops lingering (and with it the session units)" "$calls" "loginctl disable-linger alice"
has "it locks the password" "$calls" "usermod --lock alice"
has "it expires the account" "$calls" "usermod --expiredate 1 alice"
no  "and it does not touch the home" "$calls" "mv "
# THE FRAGMENT IS THE HELPER'S OWN FILE. add writes it, so lock takes it away -
# otherwise systemd recreates /run/steward/rig/<name> at every boot for an
# account that was offboarded. Removing it is not deleting the member's data,
# and the receipt has to say which of the two just happened.
has "it removes its own tmpfiles fragment" "$calls" \
    "rm -f /etc/tmpfiles.d/steward-rig-alice.conf"
has "and the receipt says whose file that was" "$out" "not the member's data"
has "it clears the rig socket directory when it is empty" "$calls" \
    "rmdir /run/steward/rig/alice"
: > "$FX/calls"
out="$( ( export FAKE_RIGDIR_BUSY=1; run lock alice ) 2>&1 )"; rc=$?
is  "a rig socket directory that is not empty is not a failure" "$rc" "0"
has "and the receipt says it was left in place" "$out" "left in place"

echo "== lock stops the work, and says so only when it is true =="
# disable-linger releases logind's reference; it stops the user manager only
# when the reference count reaches zero, which it does not while the member has
# a session open. So the receipt "the units are down" was false for exactly the
# member who is logged in when they are offboarded - and their agent kept
# running, through open fds, into a home that was being archived under it.
: > "$FX/calls"; db 'alice:1001:/home/alice'
out="$(run lock alice 2>&1)"; rc=$?
calls="$(cat "$FX/calls")"
has "it terminates the account's sessions" "$calls" "loginctl terminate-user -- alice"
has "and asks logind what is left" "$calls" "loginctl --no-legend list-sessions"
: > "$FX/calls"
out="$( ( export FAKE_SESSIONS='c3 1001 alice seat0 pts/1'; run lock alice ) 2>&1 )"; rc=$?
is  "a member who still has a session open is rc 70" "$rc" "70"
has "and the refusal says why" "$out" "still has an open session"
no  "and nothing was locked or expired" "$(cat "$FX/calls")" "usermod"
: > "$FX/calls"
out="$( ( export FAKE_SESSIONS='c3 1002 bob seat0 pts/1'; run lock alice ) 2>&1 )"; rc=$?
is  "another account's session is not this account's" "$rc" "0"
has "and the receipt is printed" "$out" "helper: lingering disabled"

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

# THE FLOOR HAS TO JUDGE PRIVILEGE, NOT ONLY ORDINARINESS. On the hosts this
# product targets, the account an operator reaches for when everything else is
# broken is not root - root ships with a locked password and no remote login. It
# is an ordinary account: uid 1000 or above, home /home/<name>, and a member of
# a sudo-capable group. Every one of those passed the floor above, so an account
# holding nothing but the one sudoers line could expire and archive every human
# on the machine, one call at a time, and keep its own way in. Locking every
# person out of a host is not reversible from the host.
#
# SUDO_USER is one of the few variables sudo SETS rather than passes through, so
# it survives env_reset and names the account the hub is running as. That
# account holds the sudoers line; locking it is the self-destruct variant of the
# same attack, and it also archives the hub's own home out from under it.
db 'alice:1001:/home/alice'
out="$( ( export FAKE_GROUPS='alice users sudo'; run lock alice --archive-home ) 2>&1 )"; rc=$?
is  "locking an account in the sudo group is rc 64" "$rc" "64"
has "and the refusal says why" "$out" "sudo-capable group"
out="$( ( export FAKE_GROUPS='alice users sudo'; run add alice ) 2>&1 )"; rc=$?
is  "and add refuses it on the same ground" "$rc" "64"
out="$( ( export FAKE_GROUPS='alice wheel'; run lock alice ) 2>&1 )"; rc=$?
is  "wheel counts too" "$rc" "64"
out="$( ( export FAKE_GROUPS='alice adm'; run lock alice ) 2>&1 )"; rc=$?
is  "and adm" "$rc" "64"
out="$( ( export FAKE_GROUPS='alice admin'; run lock alice ) 2>&1 )"; rc=$?
is  "and admin" "$rc" "64"
out="$( ( export SUDO_USER=alice; run lock alice --archive-home ) 2>&1 )"; rc=$?
is  "locking the calling account is rc 64" "$rc" "64"
has "and the refusal says which account that is" "$out" "the calling account"
out="$( ( export SUDO_USER=alice; run add alice ) 2>&1 )"; rc=$?
is  "and add refuses the calling account too" "$rc" "64"

is  "and not one of those refusals ran a privileged command" \
    "$(grep -cvE '^(id|getent) ' "$FX/calls" | tr -d ' ')" "0"

# The other direction, so the two new refusals are not simply "the floor now
# refuses everything": an ordinary group list passes, and on the paths where
# there is no sudo at all - a root shell, a root crontab - SUDO_USER is unset
# and that test is vacuous, which is the right answer there.
out="$( ( export FAKE_GROUPS='alice users video'; run lock alice ) 2>&1 )"; rc=$?
is  "an ordinary group list is not a refusal" "$rc" "0"
out="$(run lock alice 2>&1)"; rc=$?
is  "with no SUDO_USER in the environment that test is vacuous" "$rc" "0"

echo "== the floor also judges the account useradd just made =="
# Every case above seeds the database first, so every one of them takes the
# EXISTING-account branch. The create path has its own floor call, and it is the
# only one that speaks after a privileged command has already run - so it is
# also the only one that must not answer 64, which this file documents as "you
# asked wrong, nothing happened".
#
# First, the cheap half: the host's useradd default is readable, so a host that
# would put the home somewhere else is refused BEFORE anything is created.
: > "$FX/calls"; db_empty
out="$( ( export FAKE_USERADD_DEFAULT_HOME='HOME=/srv'; run add alice ) 2>&1 )"; rc=$?
is  "a host whose useradd default HOME is not /home is rc 64" "$rc" "64"
has "and the refusal names the value it measured" "$out" "/srv"
has "and what it expected instead" "$out" "/home"
has "and says nothing was created" "$out" "nothing was created"
no  "and nothing was created" "$(cat "$FX/calls")" "useradd --create-home"

# Then the belt: the host answered /home to -D and put the account somewhere
# else anyway. The account EXISTS now, so the receipt has to say so and the code
# cannot be the usage code.
: > "$FX/calls"; db_empty
out="$( ( export FAKE_NEW_HOME=/srv/alice; run add alice ) 2>&1 )"; rc=$?
is  "an account useradd put outside /home is rc 70, not 64" "$rc" "70"
calls="$(cat "$FX/calls")"
has "because the account really was created" "$calls" "useradd --create-home --user-group --shell /bin/bash alice"
has "and the receipt says so" "$out" "created by useradd but fails the floor"
has "and names the account it left behind" "$out" "alice"
has "and the home the host gave it" "$out" "/srv/alice"
has "and that it was not configured" "$out" "not configured"
no  "and nothing was configured after the create: no mode" "$calls" "chmod"
no  "no groups" "$calls" "usermod"
no  "no lingering" "$calls" "loginctl"
no  "no password" "$calls" "passwd -l"
no  "no rig fragment" "$calls" "systemd-tmpfiles"

: > "$FX/calls"; db_empty
out="$( ( export FAKE_NEW_UID=999; run add alice ) 2>&1 )"; rc=$?
is  "an account useradd gave a system uid is rc 70 too" "$rc" "70"
has "and the receipt names the uid" "$out" "uid 999"
no  "and it was left unconfigured as well" "$(cat "$FX/calls")" "loginctl"

echo "== a row about another account is not an answer =="
# ONE lookup answers every question this helper asks, which is only worth
# anything if the answer is about the account that was asked for. $USERNAME, not
# the row's name, is what every privileged command receives - so a mismatch
# cannot steer the helper onto another account, but it does mean the uid and the
# home being judged belong to someone else.
: > "$FX/calls"; db 'alice:1001:/home/alice'
out="$( ( export FAKE_ROW_NAME=bob; run lock alice ) 2>&1 )"; rc=$?
is  "lock on a row that names another account is rc 64" "$rc" "64"
has "and the refusal names the account that was asked for" "$out" "alice"
no  "and nothing was locked" "$(cat "$FX/calls")" "usermod"
: > "$FX/calls"
out="$( ( export FAKE_ROW_NAME=bob; run add alice ) 2>&1 )"; rc=$?
no  "and add does not take such a row for an existing account" "$out" "already exists"
has "it goes to the create path instead" "$(cat "$FX/calls")" "useradd --create-home --user-group --shell /bin/bash alice"

echo "== the archive refuses anything that would make its receipt false =="
# The real file's fixed paths, asserted here because the cases below run
# against the copy that relocates them.
is  "the real helper archives under /home/.offboarded" \
    "$(grep -Fc -- 'DEST="/home/.offboarded/$USERNAME-$STAMP"' "$H" | tr -d ' ')" "1"
is  "and creates that root there" \
    "$(grep -Fc -- 'mkdir -p /home/.offboarded' "$H" | tr -d ' ')" "1"
is  "and the floor pins the home to /home/<name>" \
    "$(grep -Fc -- '[ "$HOME_DIR" != "/home/$USERNAME" ]' "$H" | tr -d ' ')" "1"
is  "and the create path pins the host's useradd default to /home" \
    "$(grep -Fc -- '[ "$UA_HOME" = "/home" ]' "$H" | tr -d ' ')" "1"

today="$(date -u +%Y-%m-%d)"
mkdir -p "$FXHOME" "$FX/elsewhere"
db "alice:1001:$FXHOME/alice"

: > "$FX/calls"; rm -rf "$FXHOME/alice" "$FXHOME/.offboarded"
mkdir -p "$FXHOME/alice" "$FXHOME/.offboarded"
out="$(runfs lock alice --archive-home 2>&1)"; rc=$?
is  "the relocated copy still archives an ordinary home" "$rc" "0"
calls="$(cat "$FX/calls")"
has "it makes the archive root" "$calls" "mkdir -p $FXHOME/.offboarded"
# THE ROSTER OF WHO WAS OFFBOARDED IS NOT PUBLIC. Root's umask leaves a fresh
# mkdir at 0755, so every account on the machine could list the archive root and
# read the names and dates in it.
has "and takes the archive root down to 700" "$calls" "chmod 700 $FXHOME/.offboarded"
# -T makes the kernel refuse to nest the source inside an existing destination,
# rather than trusting the -e test taken two statements earlier.
has "and moves it with -T" "$calls" "mv -T $FXHOME/alice $FXHOME/.offboarded/alice-$today"
has "and the receipt names the destination" "$out" "helper: archived $FXHOME/.offboarded/alice-$today"

# mv across filesystems is a recursive copy followed by rm -rf of the source. It
# makes the receipt below a lie - the helper did delete, and what it deleted is
# the one thing an offboard preserves - and it makes the move non-atomic: a
# member who fills the archive volume leaves half a home and half an archive. A
# per-user dataset, a quota volume and a bind-mounted home all produce it.
: > "$FX/calls"; rm -rf "$FXHOME/alice" "$FXHOME/.offboarded"
mkdir -p "$FXHOME/alice" "$FXHOME/.offboarded"
out="$( ( export FAKE_DEV_ARCHIVE=2; runfs lock alice --archive-home ) 2>&1 )"; rc=$?
is  "a home on a different filesystem than the archive root is rc 70" "$rc" "70"
has "and the refusal names the home's device" "$out" "device 1"
has "and the archive root's" "$out" "device 2"
has "and says what a move between them would do" "$out" "copies and then deletes"
no  "and nothing was moved" "$(cat "$FX/calls")" "mv "

# A symlinked archive root is the one way the archive lands somewhere other than
# the path the receipt names: mkdir -p succeeds on a symlink to a directory.
: > "$FX/calls"; rm -rf "$FXHOME/alice" "$FXHOME/.offboarded"
mkdir -p "$FXHOME/alice"; ln -s "$FX/elsewhere" "$FXHOME/.offboarded"
out="$(runfs lock alice --archive-home 2>&1)"; rc=$?
is  "an archive root that is a symlink is rc 70" "$rc" "70"
has "and the refusal says why" "$out" "symlink"
no  "and nothing was moved" "$(cat "$FX/calls")" "mv "
rm -f "$FXHOME/.offboarded"

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

# The date the destination is stamped with is a command substitution, and a
# failed one is not caught by set -u: it yields an empty string, an unstamped
# destination, and a collision that turns every later archive into a refusal.
: > "$FX/calls"; rm -rf "$FXHOME/alice" "$FXHOME/.offboarded"
mkdir -p "$FXHOME/alice" "$FXHOME/.offboarded"
out="$( ( export FX_FAIL=date; runfs lock alice --archive-home ) 2>&1 )"; rc=$?
is  "a date the host would not give is rc 70" "$rc" "70"
has "and the refusal says what it could not read" "$out" "date"
no  "and nothing was moved" "$(cat "$FX/calls")" "mv "

echo "== chmod on the create path follows a symlink exactly as mv would =="
# useradd --create-home does not create a home that already exists and does not
# chown it, but it still writes the passwd row - so a pre-placed symlink at
# /home/<name> passes the floor, is recorded as CREATED, and turns the contract's
# chmod 750 into a root chmod on whatever the link points at. The archive path
# has guarded against exactly this since it was written; the create path did not.
: > "$FX/calls"; db_empty
rm -rf "$FXHOME/alice"; ln -s "$FX/elsewhere" "$FXHOME/alice"
out="$( ( export FAKE_USERADD_DEFAULT_HOME="HOME=$FXHOME" FAKE_NEW_HOME="$FXHOME/alice"
          runfs add alice ) 2>&1 )"; rc=$?
is  "a created home that is a symlink is rc 70, not a chmod" "$rc" "70"
has "and the refusal says why" "$out" "symlink"
calls="$(cat "$FX/calls")"
no  "and the mode was never set" "$calls" "chmod"
has "and the receipt names the account it left behind" "$out" "alice"
has "and says it was not configured" "$out" "not configured"
rm -f "$FXHOME/alice"

echo "== the receipts go where the contract says: stderr =="
# Every other run in this file merges the two streams with 2>&1, which is how
# fourteen receipts sat on stdout for a round without anything noticing. stdout
# is where a caller that parses this helper looks for data; the receipts are
# diagnostics and belong on stderr, and the only way to know which stream they
# are on is to keep them apart in at least one case per verb.
: > "$FX/calls"; db_empty
outv="$(run add alice 2>"$FX/err")"; rc=$?
is  "add still succeeds with the streams apart" "$rc" "0"
is  "and prints nothing at all on stdout" "$outv" ""
has "while the receipts are on stderr" "$(cat "$FX/err")" "helper: account alice created"
has "including the fragment line a caller reads back" "$(cat "$FX/err")" \
    "helper: tmpfiles /etc/tmpfiles.d/steward-rig-alice.conf"
: > "$FX/calls"; db 'alice:1001:/home/alice'
outv="$(run lock alice 2>"$FX/err")"; rc=$?
is  "lock still succeeds with the streams apart" "$rc" "0"
is  "and prints nothing at all on stdout" "$outv" ""
has "while its receipts are on stderr" "$(cat "$FX/err")" "helper: account expired"

echo "== every guard is a real guard: each failing command is measured =="
# NOT ONE OF THESE GUARDS WAS EVER EXERCISED. Changing any `|| fail` in the
# helper to `|| true` left this suite green - and printed the success receipt
# for an action that had not happened, which is the exact failure the receipts
# exist to prevent. Each case fails ONE command and asks two questions: what the
# exit code is, and which receipt stopped being printed.
add_guard() { # <label> <FX_FAIL> <receipt that must not appear after it>
  local o r
  : > "$FX/calls"; db_empty
  o="$( ( export FX_FAIL="$2"; run add alice ) 2>&1 )"; r=$?
  is  "$1 is rc 70" "$r" "70"
  no  "and then no receipt for what did not happen" "$o" "$3"
}
lock_guard() { # <label> <FX_FAIL> <receipt that must not appear after it>
  local o r
  : > "$FX/calls"; db 'alice:1001:/home/alice'
  o="$( ( export FX_FAIL="$2"; run lock alice ) 2>&1 )"; r=$?
  is  "$1 is rc 70" "$r" "70"
  no  "and then no receipt for what did not happen" "$o" "$3"
}
arch_guard() { # <label> <FX_FAIL> <receipt that must not appear after it>
  local o r
  : > "$FX/calls"; db "alice:1001:$FXHOME/alice"
  rm -rf "$FXHOME/alice" "$FXHOME/.offboarded"
  mkdir -p "$FXHOME/alice" "$FXHOME/.offboarded"
  o="$( ( export FX_FAIL="$2"; runfs lock alice --archive-home ) 2>&1 )"; r=$?
  is  "$1 is rc 70" "$r" "70"
  no  "and then no receipt for what did not happen" "$o" "$3"
}
add_guard "a host that will not report its useradd defaults" "useradd:-D" "helper: account alice created"
add_guard "a useradd that fails"        "useradd:--create-home" "helper: account alice created"
add_guard "an account database with no row after useradd" "getent:passwd" "helper: home"
add_guard "a chmod that fails"          "chmod:750"             "helper: home"
add_guard "a group add that fails"      "usermod:-aG"           "helper: group video"
add_guard "a password lock that fails"  "passwd:-l"             "helper: password locked"
add_guard "an enable-linger that fails" "loginctl:enable-linger" "helper: lingering enabled"
add_guard "a fragment that cannot be written" "install"         "helper: tmpfiles"
add_guard "a fragment that cannot be applied" "systemd-tmpfiles" "helper: tmpfiles"
lock_guard "a disable-linger that fails" "loginctl:disable-linger" "helper: lingering disabled"
lock_guard "a session list logind will not give" "loginctl:--no-legend" "helper: lingering disabled"
lock_guard "a usermod --lock that fails" "usermod:--lock"       "helper: password locked"
lock_guard "a usermod --expiredate that fails" "usermod:--expiredate" "helper: account expired"
lock_guard "a fragment that cannot be removed" "rm:-f"          "helper: rig socket directory"
arch_guard "an archive root that cannot be made" "mkdir"        "helper: archived"
arch_guard "an archive root that cannot be moded" "chmod:700"   "helper: archived"
arch_guard "a device number that cannot be read" "stat"         "helper: archived"
arch_guard "a move that fails"          "mv:-T"                 "helper: archived"

# THE ONE TOLERATED FAILURE, AND IT IS TOLERATED ON PURPOSE: an account with no
# session open has nothing to terminate, and logind says so with a non-zero
# status. The session list two lines later is what the receipt actually rests on.
: > "$FX/calls"; db 'alice:1001:/home/alice'
out="$( ( export FX_FAIL='loginctl:terminate-user'; run lock alice ) 2>&1 )"; rc=$?
is  "a terminate-user with nothing to terminate is not a failure" "$rc" "0"
has "and the receipt is still printed" "$out" "helper: lingering disabled"

# A LATE add FAILURE LEAVES A CONFIGURED ACCOUNT, and the refusal has to name
# it. By the time the fragment is written the account exists, its home is
# moded, its groups are set, its password is locked and its user manager is
# lingering - and "could not write the fragment" tells the operator none of that.
: > "$FX/calls"; db_empty
out="$( ( export FX_FAIL=install; run add alice ) 2>&1 )"; rc=$?
is  "a fragment that cannot be written is rc 70" "$rc" "70"
has "and the refusal names the account it left standing" "$out" "alice is left"
has "and that it was created" "$out" "created"
has "and moded" "$out" "home mode 750"
has "and grouped" "$out" "group video"
has "and locked" "$out" "password locked"
has "and lingering" "$out" "lingering enabled"

echo "== the helper never deletes, and never in the wrong order =="
# THE WHOLE CALL LOG OF THIS SUITE, judged at the end. rm, rmdir, userdel and
# deluser are all on the fixture's PATH, so a call to any of them is recorded
# rather than performed - and the only deletion this helper is allowed is its
# OWN tmpfiles fragment and an EMPTY rig socket directory. An account, a home
# and an archive are removed by an operator, never by this file.
allcalls="$(cat "$FX/calls.all")"
is  "no run ever called userdel" "$(printf '%s\n' "$allcalls" | grep -c '^userdel' | tr -d ' ')" "0"
is  "or deluser" "$(printf '%s\n' "$allcalls" | grep -c '^deluser' | tr -d ' ')" "0"
is  "or a recursive rm" "$(printf '%s\n' "$allcalls" | grep -cE '^rm( .*)? -[a-zA-Z]*[rR]' | tr -d ' ')" "0"
is  "and the only rm is the helper's own tmpfiles fragment" \
    "$(printf '%s\n' "$allcalls" | grep '^rm ' | sort -u | tr '\n' ';')" \
    "rm -f /etc/tmpfiles.d/steward-rig-alice.conf;"
is  "and the only rmdir is the rig socket directory" \
    "$(printf '%s\n' "$allcalls" | grep '^rmdir ' | sort -u | tr '\n' ';')" \
    "rmdir /run/steward/rig/alice;"

# ORDER, NOT PRESENCE. Every assertion above asks whether a call is in the log;
# none of them asks when. Archiving a home before the account's work is stopped
# moves the tree out from under a running agent, and a substring check cannot
# tell that arrangement from the right one.
: > "$FX/calls"; db "alice:1001:$FXHOME/alice"
rm -rf "$FXHOME/alice" "$FXHOME/.offboarded"; mkdir -p "$FXHOME/alice" "$FXHOME/.offboarded"
runfs lock alice --archive-home >/dev/null 2>&1
n_linger="$(grep -n 'loginctl disable-linger alice' "$FX/calls" | head -1 | cut -d: -f1)"
n_move="$(grep -n '^mv ' "$FX/calls" | head -1 | cut -d: -f1)"
if [ -n "$n_linger" ] && [ -n "$n_move" ] && [ "$n_linger" -lt "$n_move" ]; then
  ok "lingering is stopped before the home is moved"
else
  bad "lingering is stopped before the home is moved" \
      "disable-linger at line '$n_linger', mv at line '$n_move'"
fi

printf '\n  %d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
