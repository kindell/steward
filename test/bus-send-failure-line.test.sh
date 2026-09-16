#!/bin/bash
# test/bus-send-failure-line.test.sh - the line an operator sees when a send fails.
#
# EXTRACTION, NOT SOURCING, the same technique test/bus-secret-guard.test.sh uses
# and for the same reason: linux/bus-send runs `set -euo pipefail` and exits on its
# own arguments, so sourcing it would run the script. This file cuts the one
# function out with sed and evals that slice. bus-send gains no test-only hook.
#
# WHY THE LINE IS WORTH A SUITE. It reported the rc and the archive directory but
# not the RECIPIENT. That was a complete report while a home had one peer - there
# was only one place mail could be going. It stopped being one the moment a second
# peer was added, without a character of it changing.
set -u
here="$(CDPATH= cd -- "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
pass=0; fail=0
ok()  { pass=$((pass+1)); printf '  ok   %s\n' "$1"; }
bad() { fail=$((fail+1)); printf '  FAIL %s\n     %s\n' "$1" "${2:-}"; }
has() { case "$2" in *"$3"*) ok "$1" ;; *) bad "$1" "missing '$3' in: $2" ;; esac; }
is()  { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "wanted '$3', got '$2'"; fi; }
echo "bus-send-failure-line"

eval "$(sed -n '/^bus_send_failed_line() {/,/^}/p' "$here/linux/bus-send")"
# THE EARLY EXIT SPEAKS THE RUNNER'S FORMAT. tools/run-tests.sh parses
# "pass=N fail=M" or "N passed, M failed" and reports a suite it cannot parse as
# unmeasured - so a bail-out written in prose would turn "the function is gone"
# into "this suite said nothing", which is the one outcome that runner exists to
# prevent. Measured against HEAD before this change: the extraction fails and this
# is the line that has to carry it.
type bus_send_failed_line >/dev/null 2>&1 || {
  printf '  FAIL the function could not be extracted from linux/bus-send\n'
  printf '\n  0 passed, 1 failed\n'
  exit 1
}

echo "== the recipient is named =="
out="$(bus_send_failed_line 'peer-session@butler' 255 '/h/.config/agent-bus/me/failed/')"
has "the recipient appears"        "$out" "peer-session@butler"
has "the rc appears"               "$out" "ssh rc 255"
has "the archive path appears"     "$out" "/h/.config/agent-bus/me/failed/"
has "it still says the send failed" "$out" "THE SEND FAILED"

# QUOTED, BECAUSE A RECIPIENT CAN BE EMPTY OR CARRY SPACING FROM A MISTYPED
# COMMAND LINE. Unquoted, `THE SEND FAILED to  (ssh rc 255)` reads as a line with a
# typo in it rather than as a recipient nobody supplied.
echo "== the recipient is delimited, so an empty one is visible =="
out="$(bus_send_failed_line '' 255 '/d/')"
has "an empty recipient shows as empty quotes" "$out" "to ''"

echo "== a local session name survives unchanged =="
out="$(bus_send_failed_line 's-738707c917c0a070' 65 '/d/')"
has "the bare session name is intact" "$out" "to 's-738707c917c0a070'"
has "and its rc"                      "$out" "ssh rc 65"

# THE LINE IS ONE LINE. It is written to stderr beside ssh's own message, and a
# second line here would push ssh's explanation off the top of a small pane -
# which is the message that actually says WHY, since rc 255 covers a refused
# connection, a rejected key and an unknown host key alike.
echo "== exactly one line =="
is "one line, not two" "$(bus_send_failed_line 'a@b' 1 '/d/' | wc -l | tr -d ' ')" "1"

printf '\n  %d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
