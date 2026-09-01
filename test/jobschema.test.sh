#!/bin/bash
# test/jobschema.test.sh — the submission gate. The two costliest failure
# classes happen BEFORE the run: underspecified briefs (41.8% in MAST) and
# missing verification (21.3%) [R 3.1, 3.6]. So a job without an executable
# check or without the four brief fields is refused at the door — and the
# refusal names EVERY missing field at once, because a submitter who fixes
# one field per round stops trying.
set -u
pass=0; fail=0
ok()  { pass=$((pass+1)); printf '  ok   %s\n' "$1"; }
bad() { fail=$((fail+1)); printf '  FAIL %s\n     %s\n' "$1" "${2:-}"; }
here="$(CDPATH= cd -- "$(dirname "$0")" && pwd)"
. "$here/../lib/jobschema.sh"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
git init "$T/repo" >/dev/null 2>&1

complete_env() {
  SUBMIT_GOAL="ship the widget" SUBMIT_CHECK_CMD="true" SUBMIT_CHECK_EXPECT="0" \
  SUBMIT_BRIEF_OBJECTIVE="build X" SUBMIT_BRIEF_DELIVERY="commits on the job branch" \
  SUBMIT_BRIEF_TOOLS="bash, jq" SUBMIT_BRIEF_BOUNDS="owns src/x only" \
  SUBMIT_REPO="$T/repo" SUBMIT_DELIVERY_GLOB="" "$@"
}

complete_env jobschema_validate && ok "a complete submission passes" || bad "complete refused"

out="$(SUBMIT_GOAL="" SUBMIT_CHECK_CMD="" SUBMIT_CHECK_EXPECT="" \
  SUBMIT_BRIEF_OBJECTIVE="" SUBMIT_BRIEF_DELIVERY="" SUBMIT_BRIEF_TOOLS="" \
  SUBMIT_BRIEF_BOUNDS="" SUBMIT_REPO="" SUBMIT_DELIVERY_GLOB="" jobschema_validate 2>&1)"
rc=$?
[ "$rc" -eq 65 ] && ok "empty submission: rc 65" || bad "rc" "$rc"
for f in GOAL CHECK_CMD BRIEF_OBJECTIVE BRIEF_DELIVERY BRIEF_TOOLS BRIEF_BOUNDS; do
  case "$out" in *"$f"*) ok "refusal names $f" ;; *) bad "refusal silent about $f" "$out" ;; esac
done

out="$(SUBMIT_GOAL="ship the widget" SUBMIT_CHECK_CMD="" SUBMIT_CHECK_EXPECT="0" \
  SUBMIT_BRIEF_OBJECTIVE="build X" SUBMIT_BRIEF_DELIVERY="commits on the job branch" \
  SUBMIT_BRIEF_TOOLS="bash, jq" SUBMIT_BRIEF_BOUNDS="owns src/x only" \
  SUBMIT_REPO="$T/repo" SUBMIT_DELIVERY_GLOB="" jobschema_validate 2>&1)"; rc=$?
[ "$rc" -eq 65 ] && ok "missing check refused even with full brief" || bad "judge optional" "rc=$rc"

out="$(SUBMIT_GOAL="ship the widget" SUBMIT_CHECK_CMD="true" SUBMIT_CHECK_EXPECT="0" \
  SUBMIT_BRIEF_OBJECTIVE="build X" SUBMIT_BRIEF_DELIVERY="commits on the job branch" \
  SUBMIT_BRIEF_TOOLS="bash, jq" SUBMIT_BRIEF_BOUNDS="owns src/x only" \
  SUBMIT_REPO="$T/norepo" SUBMIT_DELIVERY_GLOB="" jobschema_validate 2>&1)"; rc=$?
[ "$rc" -eq 65 ] && ok "SUBMIT_REPO that is no git checkout refused" || bad "bad repo accepted"

out="$(SUBMIT_GOAL="ship the widget" SUBMIT_CHECK_CMD="true" SUBMIT_CHECK_EXPECT="0" \
  SUBMIT_BRIEF_OBJECTIVE="build X" SUBMIT_BRIEF_DELIVERY="commits on the job branch" \
  SUBMIT_BRIEF_TOOLS="bash, jq" SUBMIT_BRIEF_BOUNDS="owns src/x only" \
  SUBMIT_REPO="" SUBMIT_DELIVERY_GLOB="" jobschema_validate 2>&1)"; rc=$?
[ "$rc" -eq 65 ] && ok "neither repo nor glob: refused" || bad "deliveryless job accepted"
SUBMIT_GOAL="ship the widget" SUBMIT_CHECK_CMD="true" SUBMIT_CHECK_EXPECT="0" \
  SUBMIT_BRIEF_OBJECTIVE="build X" SUBMIT_BRIEF_DELIVERY="commits on the job branch" \
  SUBMIT_BRIEF_TOOLS="bash, jq" SUBMIT_BRIEF_BOUNDS="owns src/x only" \
  SUBMIT_REPO="" SUBMIT_DELIVERY_GLOB="out/*.md" jobschema_validate \
  && ok "file delivery with glob passes" || bad "file delivery refused"

printf 'pass=%d fail=%d\n' "$pass" "$fail"
[ "$fail" -eq 0 ] || exit 1
