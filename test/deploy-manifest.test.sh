#!/bin/bash
# Format guard for linux/deploy-manifest. Run: bash test/deploy-manifest.test.sh
set -u
here="$(CDPATH= cd -- "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# THE MANIFEST IS THE UNION, NOT THE PRODUCT'S HALF. The estate's own rows live
# in its manifest and the mechanism's in this one; the deploy composes them and
# works against the sum. If this suite checks only one side, its most important
# guards go half-blind — the truncation guard (>=20 rows) and the core-target
# list both failed the moment the manifests were split, which is exactly what
# they exist for. A guard that measures a subset of what is deployed does not
# guard the deploy.
#
# ESTATE_ROOT points at an estate checkout when one is available; without it the
# estate's rows cannot be verified and are counted instead.
# NO ESTATE IS GUESSED BY DIRECTORY NAME. This resolved a sibling checkout by
# ITS NAME, which is a particular estate's name and means nothing on anybody
# else's machine: there the guess silently finds nothing, the estate's rows go
# unverified, and the suite reports green having measured half the manifest.
# The estate says where it is, or it is not there.
ESTATE_ROOT="${STEWARD_ESTATE_ROOT:-}"
[ -z "$ESTATE_ROOT" ] && [ -n "${STEWARD_ESTATE:-}" ] && ESTATE_ROOT="$(dirname "$(dirname "$STEWARD_ESTATE")")"
unverified=0
M="$(mktemp)"; trap 'rm -f "$M"' EXIT
cat "$here/linux/deploy-manifest" > "$M"
[ -f "${ESTATE_ROOT:-$here}/estate/deploy-manifest" ] && { printf '\n' >> "$M"; cat "${ESTATE_ROOT:-$here}/estate/deploy-manifest" >> "$M"; }
pass=0; fail=0
ok()  { pass=$((pass+1)); }
bad() { echo "FAIL: $1"; fail=$((fail+1)); }

[ -f "$M" ] || { echo "FAIL: the manifest is missing"; echo "pass=0 fail=1"; exit 1; }

rows=0
while read -r src target mode kind extra; do
  case "$src" in ''|'#'*) continue ;; esac
  rows=$((rows+1))
  # 1. Exactly four fields
  if [ -n "${extra:-}" ] || [ -z "${kind:-}" ]; then bad "row shape: '$src ...'"; continue; fi
  # 2. The source exists — in the product, or in the estate.
  #
  # TWO ROOTS. The manifest's source column is relative to a repo, and since the
  # split the sources live in two: the mechanism's files here, the estate's own
  # files in the estate. Asking only this tree turns every estate row into a
  # false failure — which is exactly what happened the first time this suite ran
  # after the move.
  #
  # The estate is OPTIONAL, and its absence is not silently forgiven: rows that
  # cannot be checked are counted and printed at the end. A test that quietly
  # skips what it cannot see reports a clean tree it never looked at.
  if [ -f "$here/$src" ]; then
    ok
  elif [ -n "${ESTATE_ROOT:-}" ] && [ -f "$ESTATE_ROOT/$src" ]; then
    ok
  elif [ -z "${ESTATE_ROOT:-}" ]; then
    unverified=$((unverified+1))
  else
    bad "source missing in both product and estate: $src"
  fi
  # 3. The target is relative and free of ~, $HOME and ..
  case "$target" in /*|'~'*|*'$HOME'*|*..*) bad "target shape: $target" ;; esac
  # 4. The mode is three octal digits
  case "$mode" in [0-7][0-7][0-7]) : ;; *) bad "mode: $mode ($src)" ;; esac
  # 5. The kind is one we know
  case "$kind" in scripts|bin|systemd|lib|docs) : ;; *) bad "kind: $kind ($src)" ;; esac
  # 6. Forbidden targets: instance configuration is never deployed. The registry
  # is what the deploy READS to decide where to write; writing it back would let
  # a rollout rewrite its own instructions.
  case "$target" in sessions.d/*|*/sessions.d/*|*jobs.d/*|*jobs-sources*) bad "instance target in the manifest: $target" ;; esac
done < "$M"
[ "$rows" -ge 20 ] && ok || bad "suspiciously short manifest: $rows rows"

# 7. No duplicate targets (two sources must not write the same target)
dupes="$(grep -v '^#' "$M" | awk 'NF>=4 {print $2}' | sort | uniq -d)"
[ -z "$dupes" ] && ok || bad "duplicate target: $dupes"

# 8. The core files the hand-rolled path used to deploy must still be targets.
# This is the truncation guard's companion: a manifest can be the right length
# and still have lost the one row that matters.
# THE UNIT'S NAME CHANGED 2026-08-20 and this list caught it, which is what the
# list is for: a manifest can be the right length and still have lost the row
# that matters. The rename swapped the estate's name for a function name
# (`agent-`), and until a host has been switched over by hand it still RUNS the
# old unit — the manifest describes what the deploy writes, not what runs.
for required in bin/bus-send scripts/session-supervisor-linux.sh scripts/lib/registry.sh \
            .config/systemd/user/agent-session@.timer scripts/docs/tysta-fel.md; do
  grep -v '^#' "$M" | awk '{print $2}' | grep -qx "$required" && ok || bad "core target missing: $required"
done

# 9. THE TOOLS ARE NEVER PART OF WHAT THEY WRITE.
#
# The hub's same-machine check protects the hub from becoming a victim of its own
# deploy. deploy-self.sh has no such check, because by definition it always
# deploys to its own machine. The protection therefore rests entirely on the
# tools that RUN the deploy, and the manifest that DRIVES it, never being
# something the deploy WRITES. Nothing measured that property before.
# The hub's entry point is ESTATE code and is named by the estate, not here.
# It joins the list when STEWARD_HUB_ENTRY points at it; the product's own four
# are always checked.
TOOLS="lib/deploy-core.sh linux/deploy-self.sh linux/deploy-apply.sh linux/deploy-manifest"
[ -n "${STEWARD_HUB_ENTRY:-}" ] && TOOLS="$STEWARD_HUB_ENTRY $TOOLS"
for t in $TOOLS; do
  # 9a. Never a SOURCE: that would mean the tool running the deploy lives in the
  # image it writes — it would update itself in the middle of its own run.
  grep -v '^#' "$M" | awk '{print $1}' | grep -qx "$t" \
    && bad "tool as a manifest source — self-update mid-run: $t" || ok
  # 9b. Never a TARGET: that would mean a target points into the checkout. If
  # <home root> ever coincided with the checkout (a misconfigured session, or
  # deploy-self.sh running against its OWN machine) the deploy would overwrite
  # the running tool itself.
  grep -v '^#' "$M" | awk '{print $2}' | grep -qx "$t" \
    && bad "tool as a manifest target — points into the checkout: $t" || ok
done

[ "$unverified" -gt 0 ] && echo "NOTE: $unverified estate rows could not be verified (no estate checkout found)"
echo "pass=$pass fail=$fail"
[ "$fail" -eq 0 ]
