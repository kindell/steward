#!/bin/bash
# test/jobstate-transition.test.sh — CAS is the write path, the journal is the
# memory. TWO CONTROLLERS MUST NOT BOTH WIN: a transition carries the version
# it read, and a row that moved since then refuses with rc 75 — the loser
# re-reads instead of overwriting. An old generation can never finish a job it
# no longer owns; the lease tests pin the same rule to processes.
set -u
pass=0; fail=0
ok()  { pass=$((pass+1)); printf '  ok   %s\n' "$1"; }
bad() { fail=$((fail+1)); printf '  FAIL %s\n     %s\n' "$1" "${2:-}"; }
here="$(CDPATH= cd -- "$(dirname "$0")" && pwd)"
. "$here/../lib/jobstate.sh"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
export STEWARD_JOB_STATE_HOME="$T/jobs"

id="$(jobstate_mint_id)"; jobstate_create "$id" GOAL=g OWNER=alice DESIRED=run PROCESS=queued
jobstate_read "$id"
[ "${JOB_VERSION:-}" = "0" ] && ok "create seeds VERSION=0" || bad "VERSION after create" "${JOB_VERSION:-unset}"

jobstate_transition "$id" 0 PROCESS=running && ok "transition at right version: rc 0" || bad "transition refused wrongly"
jobstate_read "$id"
[ "$JOB_PROCESS" = "running" ] && ok "field updated" || bad "PROCESS" "$JOB_PROCESS"
[ "$JOB_VERSION" = "1" ] && ok "version bumped" || bad "VERSION" "$JOB_VERSION"
[ "$JOB_GOAL" = "g" ] && ok "untouched fields survive" || bad "GOAL lost" "${JOB_GOAL:-}"

jobstate_transition "$id" 0 PROCESS=exited 2>/dev/null
[ $? -eq 75 ] && ok "stale version refused with rc 75" || bad "stale version accepted"
jobstate_read "$id"
[ "$JOB_PROCESS" = "running" ] && ok "loser did not overwrite" || bad "overwrite happened" "$JOB_PROCESS"

grep -q "^v1 " "$T/jobs/$id/journal" && ok "journal holds the transition" || bad "no journal line"
j_before="$(wc -l < "$T/jobs/$id/journal")"
jobstate_transition "$id" 99 PROCESS=x 2>/dev/null
[ "$(wc -l < "$T/jobs/$id/journal")" = "$j_before" ] && ok "refused transition leaves no journal line" || bad "journal wrote on refusal"

# --- leases ---------------------------------------------------------------
export JOBSTATE_NOW=1000
jobstate_lease_acquire "$id" runner-a 60 && ok "lease: acquire on free row" || bad "acquire failed"
jobstate_lease_acquire "$id" runner-b 60 2>/dev/null
[ $? -eq 75 ] && ok "lease: second owner refused while valid" || bad "double lease"
[ "$(jobstate_lease_holder "$id")" = "runner-a" ] && ok "lease: holder named" || bad "holder" "$(jobstate_lease_holder "$id")"
jobstate_lease_renew "$id" runner-b 2>/dev/null
[ $? -eq 75 ] && ok "lease: renew by non-holder refused" || bad "renew stolen"
export JOBSTATE_NOW=2000
jobstate_lease_holder "$id" >/dev/null 2>&1 && bad "expired lease still held" || ok "lease: expiry frees it"
jobstate_lease_acquire "$id" runner-b 60 && ok "lease: acquire after expiry" || bad "acquire after expiry failed"

printf 'pass=%d fail=%d\n' "$pass" "$fail"
[ "$fail" -eq 0 ] || exit 1
