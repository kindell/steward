#!/bin/bash
# test/jobstate.test.sh — the job state store: minted ids, strict reads.
#
# A ROW IS WRITABLE INPUT, NEVER CODE. The session registry sources its confs
# and pays for it with an entire hardening class; job rows are written at
# runtime by machinery under an inherited environment, so the FIRST reader is
# a parser. The proof below plants a command substitution in a value and
# asserts it never runs.
set -u
pass=0; fail=0
ok()  { pass=$((pass+1)); printf '  ok   %s\n' "$1"; }
bad() { fail=$((fail+1)); printf '  FAIL %s\n     %s\n' "$1" "${2:-}"; }

here="$(CDPATH= cd -- "$(dirname "$0")" && pwd)"
. "$here/../lib/jobstate.sh"

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
export STEWARD_JOB_STATE_HOME="$T/jobs"

id="$(jobstate_mint_id)"
case "$id" in j-[0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f]) ok "mint: j-<16hex>" ;; *) bad "mint shape" "$id" ;; esac
id2="$(jobstate_mint_id)"
[ "$id" != "$id2" ] && ok "mint: two mints differ" || bad "mint collision" "$id"

jobstate_create "$id" GOAL="ship the widget" OWNER=alice DESIRED=run \
  && ok "create: rc 0" || bad "create failed"
[ -f "$T/jobs/$id/row" ] && ok "create: row file exists" || bad "no row file"
jobstate_create "$id" GOAL=x 2>/dev/null && bad "create: duplicate id accepted" || ok "create: duplicate id refused"
jobstate_create "$id2" 'bad key=x' 2>/dev/null && bad "create: invalid field name accepted" || ok "create: invalid field name refused"
id4="$(jobstate_mint_id)"
jobstate_create "$id4" '0ABC=x' 2>/dev/null && bad "create: leading digit refused" || ok "create: leading digit refused"

# THE NO-SOURCE PROOF: a value carrying a command substitution is data.
id3="$(jobstate_mint_id)"
jobstate_create "$id3" GOAL='harmless $(touch '"$T"'/pwned) text' OWNER=alice
( jobstate_read "$id3" ) >/dev/null 2>&1
[ ! -e "$T/pwned" ] && ok "read: a planted \$() never executes" || bad "READ EXECUTED DATA" "pwned exists"
jobstate_read "$id3"
[ "$JOB_GOAL" = 'harmless $(touch '"$T"'/pwned) text' ] && ok "read: value verbatim" || bad "value mangled" "$JOB_GOAL"
[ "$JOB_OWNER" = "alice" ] && ok "read: second field" || bad "OWNER" "${JOB_OWNER:-}"

jobstate_read j-0000000000000000 2>/dev/null && bad "read: missing row rc 0" || { [ $? -eq 66 ] && ok "read: missing row rc 66" || ok "read: missing row nonzero"; }
printf 'NOFIELDHERE\n' >> "$T/jobs/$id3/row"
jobstate_read "$id3" 2>/dev/null && bad "read: corrupt row accepted" || ok "read: corrupt row refused"

printf 'pass=%d fail=%d\n' "$pass" "$fail"
[ "$fail" -eq 0 ] || exit 1
