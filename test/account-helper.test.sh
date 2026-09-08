#!/bin/bash
# test/account-helper.test.sh - the privileged helper, measured on what it
# CALLS. Nothing here runs as root and nothing here creates an account: id,
# getent, useradd, usermod, passwd, loginctl, install, systemd-tmpfiles, chmod,
# mkdir and mv are all shims on PATH that record their argv. What must be shown
# is the argument guard, the receipt lines and the exact commands - the account
# creation itself is the operating system's job and is not ours to test.
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
mkdir -p "$FX/bin" "$FX/home/alice"
echo "account-helper"

mkshim() { # <name> <body>
  cat > "$FX/bin/$1" <<EOF
#!/bin/bash
echo "$1 \$*" >> "$FX/calls"
$2
EOF
  chmod 755 "$FX/bin/$1"
}
: > "$FX/calls"
mkshim id 'echo "${FAKE_UID:-0}"'
# getent answers for the account only when $FX/exists says so - that is how the
# "already there" branch is exercised without a real account database.
mkshim getent 'case "$1" in
  passwd) if [ -f "'"$FX"'/exists" ]; then echo "$2:x:1001:1001::'"$FX"'/home/$2:/bin/bash"; exit 0; fi; exit 2 ;;
  group)  case "$2" in video) exit 0 ;; *) exit 2 ;; esac ;;
esac
exit 2'
mkshim useradd 'touch "'"$FX"'/exists"; exit 0'
mkshim usermod 'exit 0'
mkshim passwd 'exit 0'
mkshim loginctl 'exit 0'
mkshim install 'cat > /dev/null; exit 0'
mkshim systemd-tmpfiles 'exit 0'
mkshim chmod 'exit 0'
mkshim mkdir 'exit 0'
mkshim mv 'exit 0'

run() { ( export PATH="$FX/bin:$PATH"; bash "$H" "$@" ); }

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
is  "and none of those called anything" "$(wc -l < "$FX/calls" | tr -d ' ')" "0"

echo "== it refuses when it is not root =="
out="$( ( export PATH="$FX/bin:$PATH" FAKE_UID=1000; bash "$H" add alice ) 2>&1 )"; rc=$?
is  "a non-root run is rc 77" "$rc" "77"
has "and says so" "$out" "root"

echo "== add, on a host where the account does not exist =="
: > "$FX/calls"; rm -f "$FX/exists"
out="$(run add alice 2>&1)"; rc=$?
is  "add succeeds" "$rc" "0"
calls="$(cat "$FX/calls")"
has "it creates the account" "$calls" "useradd --create-home --shell /bin/bash alice"
has "it tightens the home" "$calls" "chmod 750 $FX/home/alice"
has "it adds the group that exists" "$calls" "usermod -aG video alice"
no  "and not the group that does not" "$calls" "usermod -aG render alice"
has "it locks the password" "$calls" "passwd -l alice"
has "it enables lingering" "$calls" "loginctl enable-linger alice"
has "it installs the rig fragment" "$calls" "install -m 0644 /dev/stdin /etc/tmpfiles.d/steward-rig-alice.conf"
has "it applies the fragment" "$calls" "systemd-tmpfiles --create /etc/tmpfiles.d/steward-rig-alice.conf"
has "the receipt names the fragment" "$out" "helper: tmpfiles /etc/tmpfiles.d/steward-rig-alice.conf"
has "the receipt names the account" "$out" "helper: account alice"

echo "== add, on a host where the account already exists =="
: > "$FX/calls"; touch "$FX/exists"
out="$(run add alice 2>&1)"; rc=$?
is  "a second add succeeds" "$rc" "0"
calls="$(cat "$FX/calls")"
no  "and does not create the account again" "$calls" "useradd"
has "but still reports the fragment" "$out" "helper: tmpfiles /etc/tmpfiles.d/steward-rig-alice.conf"

echo "== lock =="
: > "$FX/calls"; touch "$FX/exists"
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
has "it moves the home under a dated name" "$calls" "mv $FX/home/alice /home/.offboarded/alice-"
has "and the receipt names the destination" "$out" "helper: archived /home/.offboarded/alice-"

: > "$FX/calls"; rm -f "$FX/exists"
out="$(run lock alice 2>&1)"; rc=$?
is  "locking an account that does not exist is rc 70" "$rc" "70"
has "and says which one" "$out" "alice"

printf '\n  %d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
