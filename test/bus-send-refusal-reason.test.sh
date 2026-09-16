#!/bin/bash
# test/bus-send-refusal-reason.test.sh — what a refused send records about WHY.
#
# EXTRACTION, NOT SOURCING, the technique test/bus-send-failure-line.test.sh and
# test/bus-secret-guard.test.sh use, for the reason stated there: linux/bus-send runs
# `set -euo pipefail` and acts on its own arguments, so sourcing it would run the
# script. This file cuts the two functions out with sed and evals the slices.
#
# WHY THESE ARE WORTH A SUITE. Two writers put records in failed/. The secret guard
# writes `refused_by` and a `note`; the ssh path wrote `ssh_rc` and nothing else, so
# rc 65 stood for a malformed envelope, an invented class, a parked subject and a
# FRAGA across a link alike. Measured on one estate: 31 records over 22.6 days, 15
# from the second path, twelve of them an invented class the hub had NAMED in a line
# nobody kept. One was a correction of a factual error that the sender believed
# delivered for 48 hours.
set -u
here="$(CDPATH= cd -- "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
pass=0; fail=0
ok()  { pass=$((pass+1)); printf '  ok   %s\n' "$1"; }
bad() { fail=$((fail+1)); printf '  FAIL %s\n     %s\n' "$1" "${2:-}"; }
is()  { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "wanted '$3', got '$2'"; fi; }
echo "bus-send-refusal-reason"

eval "$(sed -n '/^bus_send_refused_by() {/,/^}/p' "$here/linux/bus-send")"
eval "$(sed -n '/^bus_send_reason_cap() {/,/^}/p' "$here/linux/bus-send")"

# THE EARLY EXIT SPEAKS THE RUNNER'S FORMAT, for the reason given in the sibling
# suite: a bail-out written in prose turns "the function is gone" into "this suite
# said nothing", and unmeasured is the one outcome the runner exists to prevent.
type bus_send_refused_by >/dev/null 2>&1 && type bus_send_reason_cap >/dev/null 2>&1 || {
  printf '  FAIL the functions could not be extracted from linux/bus-send\n'
  printf '\n  0 passed, 1 failed\n'
  exit 1
}

# --- who refused -----------------------------------------------------------------
# THE FOUR REFUSAL CLASSES AS THE HUB ACTUALLY WRITES THEM, transcribed from a live
# measurement on 2026-09-16 rather than invented. All four are rc 65, which is the
# whole point: the number cannot tell them apart and the first line can.
is "malformed envelope is the hub" \
  "$(bus_send_refused_by "bus: the envelope has no valid class — the first line must be 'CLASS subject: headline'" 65)" hub
is "unknown recipient is the hub" \
  "$(bus_send_refused_by "bus: 'nobody-here' is no name in this estate, and 'x' has SEVERAL links: a b" 65)" hub
is "parked subject is the hub" \
  "$(bus_send_refused_by "bus: the subject 'x' is parked — nothing is sent." 65)" hub
is "FRAGA across a link is the hub" \
  "$(bus_send_refused_by "bus: a FRAGA does not cross a link — nothing is sent to 'x@y'." 65)" hub

# TRANSPORT FAILURE IS NOT THE HUB. ssh rc 255 covers a refused connection, a
# rejected key and an unknown host key alike; none of them reached a hub to be
# refused by one, and recording "hub" would name a component that never saw the mail.
is "ssh transport failure is ssh" \
  "$(bus_send_refused_by "ssh: connect to host h port 22: Connection refused" 255)" ssh
is "an empty reason at 255 is still ssh" "$(bus_send_refused_by "" 255)" ssh

# UNKNOWN RATHER THAN A GUESS. An archive that guesses is worse than one that admits
# — this field exists because rc 65 already guessed for us.
is "an empty reason at 65 is unknown" "$(bus_send_refused_by "" 65)" unknown
is "an unrecognised reason is unknown" "$(bus_send_refused_by "something else entirely" 1)" unknown

# `bus:` MUST BE A PREFIX, NOT A SUBSTRING. A message body quoted inside some future
# refusal line could contain the word anywhere; only the start of the line is the
# hub speaking.
is "bus: in the middle is not the hub" "$(bus_send_refused_by "ssh: remote said bus: no" 255)" ssh

# --- the cap ---------------------------------------------------------------------
# A SHORT REASON IS UNTOUCHED — the cap must not become a rewriter of ordinary
# refusals, which are the ones that will actually be read.
is "a short reason passes through" "$(bus_send_reason_cap "bus: nope")" "bus: nope"
is "an empty reason stays empty" "$(bus_send_reason_cap "")" ""

# EXACTLY AT THE BOUNDARY IS NOT TRUNCATED. An off-by-one here would silently mark
# well-formed reasons as truncated, and the note would then be the lie.
long2000="$(printf 'a%.0s' $(seq 1 2000))"
long2001="$(printf 'a%.0s' $(seq 1 2001))"
is "the 2000-character fixture is the length it claims" "${#long2000}" 2000
capped2000="$(bus_send_reason_cap "$long2000")"
is "at the boundary nothing is removed" "${#capped2000}" 2000

# THE PROPERTY THE CALLER RELIES ON: the cap shortens a reason exactly when it had
# something to remove. The record's `note` is derived from that difference rather
# than from a second comparison against 2000, so this assertion is what keeps the
# note honest. Written after breaking the cap from -gt to -ge and watching all
# nineteen assertions pass: cutting 2000 characters to 2000 is a no-op, invisible
# to any test of the output, and it was invisible because the decision lived in two
# places. Asserting the RELATION rather than the number is what closes that.
shortens() { # <input> -> "yes" if the cap removed anything, else "no"
  local _in="$1" _out
  _out="$(bus_send_reason_cap "$_in")"
  if [ "${#_out}" -ne "${#_in}" ]; then printf 'yes'; else printf 'no'; fi
}
is "the cap removes nothing at 1999"      "$(shortens "${long2000:0:1999}")" no
is "the cap removes nothing at 2000"      "$(shortens "$long2000")"          no
is "the cap removes something at 2001"    "$(shortens "$long2001")"          yes

capped2001="$(bus_send_reason_cap "$long2001")"
is "one over the boundary is cut to the cap" "${#capped2001}" 2000

huge="$(printf 'a%.0s' $(seq 1 9000))"
capped_huge="$(bus_send_reason_cap "$huge")"
is "a flood is cut to the cap" "${#capped_huge}" 2000

# THE CAP COUNTS CHARACTERS, NOT BYTES. A multibyte reason cut mid-character would
# be invalid UTF-8, and jq refuses a record over it — the reason must never be the
# thing that loses the record it explains.
# THE FIXTURE IS BUILT FROM AN ESCAPE, NOT TYPED. What is needed here is a
# two-byte character, and the obvious one to reach for is a Swedish letter — which
# the estate's language suite forbids in the product surface, and which turned this
# file red the first time it ran. The escape gives the same bytes and leaves the
# source ASCII, so the fixture cannot be the thing that fails the sweep it is
# unrelated to. U+00E9 is two bytes in UTF-8, which is the only property under test.
two_byte="$(printf '\303\251')"
multi="$(printf "%s" "$(for _ in $(seq 1 2500); do printf '%s' "$two_byte"; done)")"
capped_multi="$(bus_send_reason_cap "$multi")"
is "a multibyte reason is cut by character" "${#capped_multi}" 2000
if printf '%s' "$capped_multi" | iconv -f UTF-8 -t UTF-8 >/dev/null 2>&1; then
  ok "the cut multibyte reason is still valid UTF-8"
else
  bad "the cut multibyte reason is still valid UTF-8" "iconv rejected it"
fi

# A MULTI-LINE REASON KEEPS ITS LINES. The hub's longest refusal is four lines, and
# flattening it would drop the part that explains what to do instead.
multiline="$(printf 'bus: line one\nline two\nline three')"
is "a multi-line reason keeps its newlines" \
  "$(bus_send_reason_cap "$multiline" | wc -l | tr -d ' ')" 2
is "a multi-line reason is still attributed to the hub" \
  "$(bus_send_refused_by "$multiline" 65)" hub

printf '\n  %d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
