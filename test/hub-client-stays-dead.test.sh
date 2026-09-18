#!/bin/bash
# test/hub-client-stays-dead.test.sh — the hub client must NOT load when its
# library sits where the deploy puts it.
#
# WHY THIS SUITE EXISTS. linux/hub/bus-send resolves its library through the
# PARENT directory while the manifest installs that library as a SIBLING, so in
# the deployed layout the source line fails and none of the guards below it ever
# run. Its header says that is deliberate, and says why: on a session host this
# client writes mail into the SENDER's own home, a queue nobody reads (measured
# 2026-08-11 on a live account). The self-refusal above the source line covers
# every home that already holds a relay key — but the deploy runs BEFORE key
# creation, and an override exists, so in that window the only thing standing
# between a fresh home and a silent misdelivery is that this file cannot load.
#
# The header also claims "The envelope suite PINS the non-delivery ... It caught
# this very repair on 2026-08-20". MEASURED 2026-09-18, and it did not: the
# repair was applied to a throwaway clone of origin/main and the product's whole
# suite came back found=134 ran=134 red=0. Two estates checked their own suites
# as well — one DESCRIBES the deliberate death in a comment while asserting
# something about a different file, the other does not mention it. Three places,
# no pin.
#
# A search answers "I cannot find it". A mutation answers "it is not there, or it
# does not bite" — and to somebody repairing the line in good faith those are the
# same thing. Somebody did exactly that on 2026-08-20; whatever stopped them, it
# was not a red number. This suite makes it one.
#
# WHAT IS PINNED IS THE BEHAVIOUR, NOT THE TEXT. Asserting that line 32 reads
# `dirname .../..` would be a transcript: it breaks on every rewording and it
# proves nothing about what the file DOES. What is asserted here is that the
# client does not load in the layout the manifest actually produces.
set -u
here="$(CDPATH= cd -- "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
pass=0; fail=0
ok()  { pass=$((pass+1)); }
bad() { echo "FAIL: $1"; fail=$((fail+1)); }
check() { d="$1"; shift; if "$@"; then ok; else bad "$d"; fi; }

# A home with NO relay key, on purpose: the self-refusal above the source line
# fires when one exists, and would then be the thing under test instead of the
# path. This suite is about the window BEFORE any key exists — the one the
# header says the source failure covers alone.
rig() {
  D="$(mktemp -d)"
  mkdir -p "$D/home/.ssh" "$D/scripts/bus"
  cp "$here/linux/hub/bus-send" "$D/scripts/bus/bus-send"
  chmod +x "$D/scripts/bus/bus-send"
}
run_client() { ( cd "$D" && HOME="$D/home" bash "$D/scripts/bus/bus-send" somebody "DRIFT t: r" 2>&1 ); }

# ── 1. THE DEPLOYED LAYOUT: library as a SIBLING => the client must not load ──
rig
cp "$here/linux/hub/lib.sh" "$D/scripts/bus/lib.sh"       # exactly what manifest row 125 does
out="$(run_client)"; rc=$?
check "sibling layout: the client fails"        [ "$rc" -ne 0 ]
# NOT MERELY "it fails". Measured while writing this suite: with the path
# repaired, the client loads, gets further, and STILL exits non-zero for want of
# a registry - so "rc != 0" keeps passing on the very day the pin is supposed to
# break, and the only assertion that noticed was the control, which said the
# SUITE was wrong rather than the file. The failure has to be the LIBRARY READ,
# named as such.
case "$out" in
  *lib.sh*"No such file"*|*lib.sh*"Ingen s"*)
      ok ;;
  *)  bad "the client did not fail on reading its library - it loaded, which is what this suite exists to catch: $out" ;;
esac
# THE POINT IS NOT THE ERROR, IT IS THAT NOTHING WAS DELIVERED. A file that fails
# loudly and still queues the message would satisfy every assertion above.
check "sibling layout: no queue was written in the sender's home" \
      [ ! -d "$D/home/.config/agent-bus" ]
rm -rf "$D"

# ── 2. THE CONTROL: library where the client LOOKS => it must get past the source ──
# Without this, the suite passes for any reason the script exits non-zero - a
# missing tmux, a changed argument check - and would keep passing on the day the
# path is repaired and the file starts loading from somewhere else. Consistent
# numbers are not a check; the control assertion is what makes the first one mean
# what it says.
rig
cp "$here/linux/hub/lib.sh" "$D/scripts/lib.sh"           # the PARENT, where $here points
out="$(run_client)"; rc=$?
case "$out" in
  *"lib.sh: No such file"*|*"lib.sh: Ingen"*)
      bad "control: the client could not read its library where it looks - either this rig is wrong, or the client's lookup moved (see the failure above, if there is one)" ;;
  *) ok ;;
esac
# It may well fail further down (no registry, no tmux) - that is fine and is not
# what is being measured. What must be true is that it got PAST the source line.
check "control: the rig can produce a loading client" [ -f "$D/scripts/lib.sh" ]
rm -rf "$D"

echo "pass=$pass fail=$fail"
[ "$fail" -eq 0 ]
