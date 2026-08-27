#!/bin/bash
# test/probe-dispatch.test.sh — the dispatcher: which prober answers for a type?
#
# HERMETIC ON PURPOSE. Every prober here is a stub. The question this suite asks
# is about LOOKUP — which directory wins, what a non-executable file counts as,
# what an unknown type answers — and none of that needs a real measurement.
#
# THE ESTATE IS SEARCHED FIRST. That is the whole reason the dispatcher exists:
# an estate must be able to replace a generic prober with one that knows more
# about its own machines, without touching the product.
set -u

here="$(CDPATH= cd -- "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DISPATCH="$here/bin/probe-dispatch"
pass=0; fail=0
ok()  { pass=$((pass+1)); printf '  ok   %s\n' "$1"; }
bad() { fail=$((fail+1)); printf '  FAIL %s\n     %s\n' "$1" "${2:-}"; }
is()  { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "wanted '$3', got '$2'"; fi; }
has() { case "$2" in *"$3"*) ok "$1" ;; *) bad "$1" "missing '$3' in: $2" ;; esac; }

FX="$(mktemp -d)"; trap 'rm -rf "$FX"' EXIT
mkdir -p "$FX/estate/probes"

# The product's own probes directory is a real path inside the checkout, so the
# suite cannot write to it. Point the product half at a fixture too, through the
# same override the dispatcher offers for testing.
mkdir -p "$FX/product/probes"

stub() { # <dir> <type> <line>
  printf '#!/bin/bash\nprintf "%%s\\n" "%s"\n' "$3" > "$1/probes/$2"
  chmod +x "$1/probes/$2"
}

run() { STEWARD_ESTATE_ROOT="$FX/estate" \
        STEWARD_PRODUCT_PROBE_DIR="$FX/product/probes" \
        bash "$DISPATCH" "$@" 2>&1; }

echo "probe-dispatch — lookup"

# CONTROL GROUP FIRST: a product prober alone is found and its line comes back
# verbatim. If this breaks, the fixture is wrong, not the claims below.
stub "$FX/product" widget "up product-answered"
out="$(run widget "")"; rc=$?
is  "a product prober answers" "$out" "up product-answered"
is  "rc 0 when a prober answered" "$rc" "0"

# THE ESTATE WINS. Same type in both directories: the estate's answer is the one
# that comes back.
stub "$FX/estate" widget "up estate-answered"
is "the estate is searched first" "$(run widget "")" "up estate-answered"

# ARGUMENTS REACH THE PROBER, both of them, unaltered.
printf '#!/bin/bash\nprintf "up type=%%s arg=%%s\\n" "$1" "$2"\n' > "$FX/product/probes/echoer"
chmod +x "$FX/product/probes/echoer"
is "type and arg are passed through" "$(run echoer 'a:b c')" "up type=echoer arg=a:b c"

# THE ENVIRONMENT TRAVELS. The session name rides in STEWARD_PROBE_SESSION and
# the dispatcher must not eat it — Task 2's prober cannot measure without it.
printf '#!/bin/bash\nprintf "up session=%%s\\n" "${STEWARD_PROBE_SESSION:-none}"\n' \
  > "$FX/product/probes/envcheck"
chmod +x "$FX/product/probes/envcheck"
is "STEWARD_PROBE_SESSION reaches the prober" \
   "$(STEWARD_PROBE_SESSION=abc run envcheck "")" "up session=abc"

echo "probe-dispatch — what cannot be measured"

# AN UNKNOWN TYPE IS unknown, NOT SILENCE. Printing nothing would make an
# unrecognised type indistinguishable from a healthy one at the layer above.
out="$(run no-such-type "")"; rc=$?
has "an unknown type says unknown" "$out" "unknown"
has "the refusal names the reason" "$out" "unknown-asset-type"
is  "rc is still 0 — probing reports, it does not judge" "$rc" "0"

# A FILE THAT IS NOT EXECUTABLE IS NOT A HIT. Treating it as one would run
# nothing, print nothing, and read as a successful empty measurement.
printf '#!/bin/bash\nprintf "up should-not-run\\n"\n' > "$FX/estate/probes/dud"
chmod -x "$FX/estate/probes/dud"
out="$(run dud "")"
has "a non-executable file is not a hit" "$out" "unknown-asset-type"

# A NON-EXECUTABLE IN THE ESTATE MUST NOT SHADOW A WORKING PRODUCT PROBER.
# "Searched first" means first in ORDER, not first to veto.
stub "$FX/product" dud "up product-fallback"
is "a dud in the estate falls through to the product" \
   "$(run dud "")" "up product-fallback"

# A PROBER THAT FAILS IS THE CALLER'S PROBLEM, NOT THE DISPATCHER'S. The
# dispatcher forwards rc and output; asset_probe already downgrades a non-zero
# rc to `unknown probe-failed-rcN`, and duplicating that judgement here would
# give two layers a say in the same verdict.
printf '#!/bin/bash\nexit 3\n' > "$FX/product/probes/broken"
chmod +x "$FX/product/probes/broken"
run broken "" >/dev/null 2>&1; rc=$?
is "a failing prober's rc is forwarded" "$rc" "3"

echo "probe-dispatch — a missing estate is not a crash"

# NO ESTATE PROBES DIRECTORY AT ALL is the normal case for a fresh estate. It
# must fall through to the product, not fail.
rm -rf "$FX/estate/probes"
is "a missing estate probes directory falls through" \
   "$(run widget "")" "up product-answered"

# NO TYPE GIVEN AT ALL. Same rule: say so, do not guess.
out="$(run "" "")"
has "an empty type is unknown too" "$out" "unknown"

echo
printf 'pass=%s fail=%s\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
