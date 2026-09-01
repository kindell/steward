#!/bin/bash
# test/jobgit.test.sh — the job-owned checkout and the pinned delivery.
#
# NEVER THE SUBMITTER'S CHECKOUT [A1]: the session model already forbids a
# shared working copy, and scheduled jobs measured the dirty-tree collisions.
# The job clones, works on its own branch keyed on the FULL immutable id, and
# delivers by CAS push — an unexpected remote movement is a provenance
# conflict (rc 75), never a force. The receipt verifies the EXACT tip: "the
# branch exists" would accept a stale delivery.
set -u
pass=0; fail=0
ok()  { pass=$((pass+1)); printf '  ok   %s\n' "$1"; }
bad() { fail=$((fail+1)); printf '  FAIL %s\n     %s\n' "$1" "${2:-}"; }
here="$(CDPATH= cd -- "$(dirname "$0")" && pwd)"
. "$here/../lib/jobgit.sh"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t

# Fixture origin: a bare repo with one commit, cloned to a "submitter" checkout.
git init -q --bare "$T/origin.git"
git clone -q "$T/origin.git" "$T/src" 2>/dev/null
( cd "$T/src" && echo base > f.txt && git add f.txt && git commit -qm base && git push -q origin HEAD )

id="j-00000000000000ab"
[ "$(jobgit_branch "$id")" = "steward/jobs/$id/delivery" ] && ok "branch keyed on full id" || bad "branch" "$(jobgit_branch "$id")"
jobgit_branch "not-an-id" 2>/dev/null && bad "bad id accepted" || ok "bad id refused"
jobgit_branch "j-/etc/passwd/xxxx" 2>/dev/null && bad "slash in id accepted" || ok "slash in id refused"
jobgit_branch "j-ABCDEF0123456789" 2>/dev/null && bad "uppercase id accepted" || ok "uppercase id refused"
jobgit_branch "j-0123456789abcdef" >/dev/null && ok "lowercase hex id accepted" || bad "lowercase hex id refused"

base_out="$(jobgit_checkout "$id" "$T/src" "$T/work")"
[ -d "$T/work/.git" ] && ok "checkout: job owns a clone" || bad "no clone"
case "$base_out" in BASE_SHA=*) ok "checkout: BASE_SHA reported" ;; *) bad "no BASE_SHA" "$base_out" ;; esac
base_sha="${base_out#BASE_SHA=}"
[ "$(git -C "$T/work" rev-parse HEAD)" = "$base_sha" ] && ok "checkout: work at BASE_SHA" || bad "work not at base"
[ "$(git -C "$T/work" branch --show-current)" = "steward/jobs/$id/delivery" ] && ok "checkout: on delivery branch" || bad "wrong branch"
# The clone's origin is the SOURCE'S origin, not the submitter's checkout:
# delivery must survive the submitter moving or dirtying their clone.
[ "$(git -C "$T/work" remote get-url origin)" = "$T/origin.git" ] && ok "checkout: origin is the real origin" || bad "origin" "$(git -C "$T/work" remote get-url origin)"

( cd "$T/work" && echo delivered > f.txt && git add f.txt && git commit -qm "job work" )
del_out="$(jobgit_deliver "$id" "$T/work" "")"
case "$del_out" in DELIVERY_SHA=*) ok "deliver: DELIVERY_SHA reported" ;; *) bad "no DELIVERY_SHA" "$del_out" ;; esac
del_sha="${del_out#DELIVERY_SHA=}"
jobgit_receipt "$id" "$T/work" "$del_sha" && ok "receipt: exact tip verified" || bad "receipt failed on honest delivery"
jobgit_receipt "$id" "$T/work" "$base_sha" 2>/dev/null && bad "receipt: wrong sha accepted" || ok "receipt: wrong sha refused"

# Deliver again with empty expectation (branch already exists on remote).
( cd "$T/work" && echo again2 > f.txt && git add f.txt && git commit -qm again2 )
jobgit_deliver "$id" "$T/work" "" >/dev/null 2>&1
[ $? -eq 75 ] && ok "deliver: already-exists with empty expectation refused rc 75" || bad "already-exists not refused"

# UNEXPECTED REMOTE MOVEMENT IS rc 75, NEVER A FORCE. Simulate a foreign push.
git clone -q "$T/origin.git" "$T/intruder" 2>/dev/null
( cd "$T/intruder" && git checkout -qb "steward/jobs/$id/delivery" "$del_sha" && echo moved > f.txt && git add f.txt && git commit -qm moved && git push -q origin HEAD )
moved_sha="$(git -C "$T/intruder" rev-parse HEAD)"
( cd "$T/work" && echo again > f.txt && git add f.txt && git commit -qm again )
jobgit_deliver "$id" "$T/work" "$del_sha" >/dev/null 2>&1
[ $? -eq 75 ] && ok "deliver: moved remote refused with rc 75" || bad "moved remote not refused"
[ "$(git -C "$T/origin.git" rev-parse "refs/heads/steward/jobs/$id/delivery")" = "$moved_sha" ] && ok "deliver: foreign commit NOT overwritten" || bad "force happened"

jobgit_push_guard "$id" "refs/heads/steward/jobs/$id/delivery" && ok "guard: own namespace allowed" || bad "own namespace refused"
jobgit_push_guard "$id" "refs/heads/main" 2>/dev/null && bad "guard: main allowed" || ok "guard: main refused"
jobgit_push_guard "$id" "refs/tags/v1" 2>/dev/null && bad "guard: tag allowed" || ok "guard: tag refused"
jobgit_push_guard "$id" "refs/heads/steward/jobs/j-00000000000000ff/delivery" 2>/dev/null && bad "guard: another job's ref allowed" || ok "guard: another job's ref refused"
jobgit_push_guard "*" "refs/heads/steward/jobs/*/delivery" 2>/dev/null && bad "guard: wildcard id accepted" || ok "guard: wildcard id refused"

printf 'pass=%d fail=%d\n' "$pass" "$fail"
[ "$fail" -eq 0 ] || exit 1
