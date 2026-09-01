#!/bin/bash
# test/steward-estate-ls-sort.test.sh — bin/steward's own half of the --sort
# fix: the dispatcher must not swallow the flag on the way into cmd_ls, and
# cmd_ls must validate --sort and refuse anything else BEFORE ever running ssh.
#
# WHY THIS EXISTS. `steward sessions --sort` (1503e29) never reached the
# ESTATE listing form: measured live, `steward <estate> ls --sort slug`
# neither sorted nor refused. Root cause, found by reading the dispatcher: the
# estate-client fallback branch matched "ls" and called `cmd_ls "$est"` without
# shifting past "ls" or forwarding what came after it — `--sort slug` was
# never even handed to cmd_ls to accept or reject. linux/estate-status.sh
# (the actual table renderer, over ssh) is covered by
# test/estate-status-sort.test.sh; THIS suite is the layer above it — the
# plumbing that decides whether the flag ever reaches that renderer at all.
#
# HERMETIC: no real ssh. STEWARD_SSH points at a stub that logs the exact
# command line it was asked to run (so a test can assert --sort DID or did NOT
# cross the wire) and answers with a fixed, harmless line so `_ls_en` sees
# rc 0 and a normal table.
set -u

here="$(CDPATH= cd -- "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
STEWARD="$here/bin/steward"
pass=0; fail=0
ok()  { pass=$((pass+1)); printf '  ok   %s\n' "$1"; }
bad() { fail=$((fail+1)); printf '  FAIL %s\n     %s\n' "$1" "${2:-}"; }
is()  { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "wanted '$3', got '$2'"; fi; }
has() { case "$2" in *"$3"*) ok "$1" ;; *) bad "$1" "missing '$3' in: $2" ;; esac; }
hasnt() { case "$2" in *"$3"*) bad "$1" "unexpectedly found '$3' in: $2" ;; *) ok "$1" ;; esac; }

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
mkdir -p "$T/estates.d" "$T/bin"

cat > "$T/estates.d/myestate.conf" <<'EOF'
SSH="myhost"
ESTATE_ROOT="/home/op/estate"
PRODUCT_DIR="/home/op/steward"
EOF

# THE STUB LOGS ITS OWN ARGV — the single string bin/steward builds to run
# remotely — TO A FILE, THEN ANSWERS with one harmless table line. A test that
# only checked the human-readable table could not distinguish "--sort reached
# the remote command" from "it didn't, and the estate happened to render the
# same either way"; the logged argv is the one place that distinction is
# actually visible.
SSHLOG="$T/sshlog"
cat > "$T/bin/ssh" <<EOF
#!/bin/bash
printf '%s\n' "\$*" >> "$SSHLOG"
echo "fake-row"
exit 0
EOF
chmod +x "$T/bin/ssh"

run() { : > "$SSHLOG"
        STEWARD_ESTATES_D="$T/estates.d" STEWARD_SSH="$T/bin/ssh" \
        bash "$STEWARD" "$@" 2>&1; }

echo "== steward <estate> ls --sort <key>: the flag reaches the remote command =="
out="$(run myestate ls --sort slug)"; rc=$?
is "rc 0" "$rc" "0"
has "the remote command carries --sort slug" "$(cat "$SSHLOG")" "--sort slug"
has "the table still renders" "$out" "fake-row"

echo "== steward ls <estate> --sort <key>: the other call order, same wiring =="
out2="$(run ls myestate --sort host)"; rc2=$?
is "rc 0" "$rc2" "0"
has "the remote command carries --sort host" "$(cat "$SSHLOG")" "--sort host"

echo "== steward <estate> ls, no flag: unchanged — no --sort reaches the remote command =="
out3="$(run myestate ls)"; rc3=$?
is "rc 0" "$rc3" "0"
hasnt "no --sort in the remote command" "$(cat "$SSHLOG")" "--sort"

echo "== steward <estate> ls --sort bogus: refuses rc 64, BEFORE ssh ever runs =="
: > "$SSHLOG"
uerr="$(mktemp)"
uout="$(STEWARD_ESTATES_D="$T/estates.d" STEWARD_SSH="$T/bin/ssh" \
        bash "$STEWARD" myestate ls --sort bogus 2>"$uerr")"; urc=$?
uerrtext="$(cat "$uerr")"; rm -f "$uerr"
is "rc is 64" "$urc" "64"
is "stdout is empty" "$uout" ""
has "names the bad key" "$uerrtext" "bogus"
has "lists the valid keys" "$uerrtext" "name, slug, display, owner, host"
is "ssh was never invoked" "$(cat "$SSHLOG")" ""

echo "== steward <estate> ls --bogus: an unrelated unknown flag also refuses rc 64, before ssh =="
: > "$SSHLOG"
berr="$(mktemp)"
bout="$(STEWARD_ESTATES_D="$T/estates.d" STEWARD_SSH="$T/bin/ssh" \
        bash "$STEWARD" myestate ls --bogus 2>"$berr")"; brc=$?
berrtext="$(cat "$berr")"; rm -f "$berr"
is "rc is 64" "$brc" "64"
is "stdout is empty" "$bout" ""
has "names the bad option" "$berrtext" "bogus"
is "ssh was never invoked" "$(cat "$SSHLOG")" ""

echo "== steward ls (sweep-all) --sort <key>: forwarded to every estate's ssh call =="
: > "$SSHLOG"
sout="$(run ls --sort owner)"; src=$?
is "rc 0" "$src" "0"
has "the remote command carries --sort owner" "$(cat "$SSHLOG")" "--sort owner"

echo
printf 'pass=%s fail=%s\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
