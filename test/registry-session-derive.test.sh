#!/bin/bash
# test/registry-session-derive.test.sh - `steward registry session derive <session>`, the migration verb
# of spec §4: a row stops carrying a typed RC_LABEL and starts DERIVING its display from its target.
#
# THE LINE IS DELETED, NEVER EMPTIED. RC_LABEL="" is not "no label" - it is the RC-FREE choice, in both
# readers: the supervisor starts such a session with no --remote-control at all and the registry gate
# skips it. A migration that emptied the line instead of removing it would silently take every migrated
# session out of Remote Control, which is exactly the trap spec §4 names. That is the property this
# suite exists for, and the mutation that proves it.
#
# The verb refuses, byte-identically, when the target does not resolve (a row must not lose the only
# name it has) and when the rendered display is already taken under the same login key (spec §3).
set -u
here="$(CDPATH= cd -- "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
pass=0; fail=0
ok()  { pass=$((pass+1)); printf '  ok   %s\n' "$1"; }
bad() { fail=$((fail+1)); printf '  FAIL %s\n     %s\n' "$1" "${2:-}"; }
is()  { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "wanted '$3', got '$2'"; fi; }
has() { case "$2" in *"$3"*) ok "$1" ;; *) bad "$1" "missing '$3' in: $2" ;; esac; }
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
ROOT="$T/estate"; SESS="$ROOT/sessions.d"
mkdir -p "$ROOT/estate" "$SESS" "$ROOT/entities.d" "$ROOT/accounts.d" "$ROOT/projects.d" "$ROOT/mcp.d" "$ROOT/logins.d"
chmod 700 "$ROOT/logins.d"
cat > "$ROOT/estate/steward.conf" <<'EOF2'
ESTATE_NAME="fixture"
LABEL_PREFIX="com.fixture.claude"
RC_LABEL_PREFIX="Fixture: "
HUB_SESSION="hub"
HUB_HOST="h1"
HUB_SSH="hub@127.0.0.1"
STATE_DIR_NAME="fixture-supervisor"
PAUSED_DIR_NAME="fixture-paused"
TMUX_SOCKET="fixture.sock"
OP_TOKEN_FILE_NAME="fixture-token"
PING_MSG="you have unread mail"
EOF2
printf 'NAME="Alpha"\nMEMBERS="a"\n' > "$ROOT/entities.d/alpha.conf"
printf 'NAME="Site"\nPARENT="alpha"\n' > "$ROOT/projects.d/site.conf"
printf 'NAME="Other"\nPARENT="alpha"\n' > "$ROOT/projects.d/other.conf"
printf 'PRINCIPAL="a"\nHOST="h1"\nUSERNAME="a"\n' > "$ROOT/accounts.d/a-h1.conf"
printf 'PRINCIPAL="b"\nHOST="h1"\nUSERNAME="b"\n' > "$ROOT/accounts.d/b-h1.conf"
run() { STEWARD_ESTATE_ROOT="$ROOT" STEWARD_CONFIG_FILE="$T/no-such-config" bash "$here/bin/steward" registry session derive "$@" 2>&1; }
display_of() { ( export STEWARD_ESTATE_ROOT="$ROOT" STEWARD_CONFIG_FILE="$T/no-such-config"; . "$here/lib/registry.sh"; registry_session_display "$1" 2>/dev/null ); }
row() { # <id> <slug> <label-line-or-empty> <target-line> [extra]
  { printf 'ID="%s"\nACCOUNT="a-h1"\nSLUG="%s"\nOWNER="a"\nHOST="h1"\nDOMAIN="alpha"\nREPO_PATH="/tmp/repo"\n%s\n' "$1" "$2" "$4"
    [ -z "$3" ] || printf '%s\n' "$3"; shift 4; for l in "$@"; do printf '%s\n' "$l"; done; } > "$SESS/$1.conf"
}

echo "== 1. the happy path: the label line is DELETED and the display derives =="
A="s-00000000000000a1"; row "$A" one 'RC_LABEL="Old Name"' 'TARGET_PROJECT="site"'
before="$(display_of "$A")"; is "1a before: the typed label wins" "$before" "Old Name"
out="$(run "$A")"; rc=$?
is "1b rc 0" "$rc" "0"; has "1c the receipt names the rendered display" "$out" "Alpha→Site"
is "1d NO RC_LABEL line remains - not even an empty one" "$(grep -c '^RC_LABEL=' "$SESS/$A.conf")" "0"
is "1e the display now derives" "$(display_of "$A")" "Alpha→Site"
is "1f every other field survives" "$(grep -c '^REPO_PATH="/tmp/repo"$' "$SESS/$A.conf")" "1"
is "1g the row still loads" "$( ( export STEWARD_ESTATE_ROOT="$ROOT" STEWARD_CONFIG_FILE="$T/no-such-config"; . "$here/lib/registry.sh"; registry_load "$A" >/dev/null 2>&1 && echo yes ) )" "yes"

echo "== 2. idempotence and the rows that have nothing to derive =="
out="$(run "$A")"; rc=$?; is "2a a derived row is already derived: rc 0, nothing written" "$rc" "0"; has "2b and says so" "$out" "already"
B="s-00000000000000b1"; row "$B" two 'RC_LABEL=""' 'TARGET_PROJECT="other"'
sum="$(cksum < "$SESS/$B.conf")"; out="$(run "$B")"; rc=$?
is "2c an RC-FREE row is a deliberate choice, not a migration: refused" "$rc" "65"; has "2d and says RC-free" "$out" "RC-free"
is "2e byte-identical" "$(cksum < "$SESS/$B.conf")" "$sum"
C="s-00000000000000c1"; row "$C" three 'RC_LABEL="Legacy"' 'DOMAIN="alpha"'
sum="$(cksum < "$SESS/$C.conf")"; out="$(run "$C")"; rc=$?
is "2f a row with no target has nothing to derive: refused" "$rc" "65"; has "2g and names the missing target" "$out" "target"
is "2h byte-identical" "$(cksum < "$SESS/$C.conf")" "$sum"

echo "== 3. the refusals leave the row byte-identical =="
D="s-00000000000000d1"; row "$D" four 'RC_LABEL="Keep Me"' 'TARGET_PROJECT="no-such-project"'
sum="$(cksum < "$SESS/$D.conf")"; out="$(run "$D")"; rc=$?
is "3a an unresolvable target is refused" "$rc" "65"; has "3b and names the project" "$out" "no-such-project"
is "3c byte-identical - a row never loses the only name it has" "$(cksum < "$SESS/$D.conf")" "$sum"
is "3d the label still wins" "$(display_of "$D")" "Keep Me"
E="s-00000000000000e1"; row "$E" five 'RC_LABEL="Mine"' 'TARGET_PROJECT="site"'
sum="$(cksum < "$SESS/$E.conf")"; out="$(run "$E")"; rc=$?
is "3e the rendered display is already held under this login key: refused" "$rc" "65"; has "3f and names the holder" "$out" "$A"
is "3g byte-identical" "$(cksum < "$SESS/$E.conf")" "$sum"
F="s-00000000000000f1"; { printf 'ID="%s"\nACCOUNT="b-h1"\nSLUG="six"\nOWNER="b"\nHOST="h1"\nDOMAIN="alpha"\nREPO_PATH="/tmp/repo"\nTARGET_PROJECT="site"\nRC_LABEL="Theirs"\n' "$F"; } > "$SESS/$F.conf"
out="$(run "$F")"; rc=$?
is "3h another login key may render the same display (Jon 2026-09-11): rc 0" "$rc" "0"
is "3i and its line is gone too" "$(grep -c '^RC_LABEL=' "$SESS/$F.conf")" "0"
out="$(run s-0000000000000099)"; rc=$?; is "3j an unknown session is refused" "$rc" "78"
printf 'garbage\n' > "$SESS/s-00000000000000a9.conf"
out="$(run s-00000000000000a9)"; rc=$?; case "$rc" in 0) bad "3k a row that does not load is refused" "rc 0" ;; *) ok "3k a row that does not load is refused" ;; esac
# AND THE GATE FAILS CLOSED ON IT (spec §3, advisor M5): a row that yields neither a login key nor a
# display cannot be shown NOT to carry the display being taken, so no other row may derive while it lies
# in the register. (A row that merely fails to LOAD is read without being executed and compared instead -
# see test/registry-session-display.test.sh section 9.)
I="s-00000000000000i1"; row "$I" nine 'RC_LABEL="Nine"' 'TARGET_ENTITY="alpha"'
sum="$(cksum < "$SESS/$I.conf")"; out="$(run "$I")"; rc=$?
is "3l a row that cannot be read blocks every derive (fails closed)" "$rc" "65"; has "3m and is named" "$out" "s-00000000000000a9"
is "3n byte-identical" "$(cksum < "$SESS/$I.conf")" "$sum"
rm -f "$SESS/s-00000000000000a9.conf" "$SESS/$I.conf"

echo "== 4. --json is data, and --dry-run writes nothing =="
H="s-00000000000000h1"; row "$H" seven 'RC_LABEL="Old Seven"' 'TARGET_ENTITY="alpha"'
sum="$(cksum < "$SESS/$H.conf")"
out="$(run "$H" --dry-run --json)"; rc=$?
is "4a dry run rc 0" "$rc" "0"; is "4b it reports what would be written" "$(printf '%s' "$out" | jq -r '.display')" "Alpha"
is "4c and writes nothing" "$(cksum < "$SESS/$H.conf")" "$sum"
out="$(run "$H" --json)"; rc=$?
is "4d rc 0" "$rc" "0"; is "4e ok true" "$(printf '%s' "$out" | jq -r '.ok')" "true"
is "4f kind" "$(printf '%s' "$out" | jq -r '.kind')" "session-derive"
is "4g the old label is reported" "$(printf '%s' "$out" | jq -r '.was')" "Old Seven"
is "4h and the new display" "$(printf '%s' "$out" | jq -r '.display')" "Alpha"
is "4i the line is gone" "$(grep -c '^RC_LABEL=' "$SESS/$H.conf")" "0"

echo "== 5. the write is the registry's own transaction (advisor P1, P2, P5) =="
printf 'NAME="Tenth"\nMEMBERS="a"\n' > "$ROOT/entities.d/tenth.conf"
J="s-00000000000000j1"; row "$J" ten 'RC_LABEL="Ten"' 'TARGET_ENTITY="tenth"'
chmod 0600 "$SESS/$J.conf"; umask 022
out="$(run "$J")"; rc=$?
is "5a rc 0" "$rc" "0"
is "5b the published row keeps mode 0600 even under a loose umask (P2)" "$(stat -c %a "$SESS/$J.conf")" "600"
is "5c no staging or backup file is left behind" "$(ls "$SESS" | grep -c 'stage\|backup\|derive')" "0"
# THE GATE RUNS INSIDE THE LOCK (P1): a competitor that takes the same display between the pre-check and
# the publish is caught by the staged-row validator, and the row keeps its label.
printf 'NAME="Eleventh"\nPARENT="alpha"\n' > "$ROOT/projects.d/eleventh.conf"
K="s-00000000000000k1"; row "$K" eleven 'RC_LABEL="Eleven"' 'TARGET_PROJECT="eleventh"'
out="$(run "$K")"; rc=$?
is "5d a row whose rendered display is free is published" "$rc" "0"
is "5d2 and it renders it" "$(display_of "$K")" "Alpha→Eleventh"
L="s-00000000000000l1"; row "$L" twelve 'RC_LABEL="Twelve"' 'TARGET_PROJECT="site"'
# 'site' renders Alpha→Site, which $A already carries: the pre-check refuses it - the same refusal the
# staged-row validator would give inside the lock, and the one an operator sees.
sum="$(cksum < "$SESS/$L.conf")"; out="$(run "$L")"; rc=$?
is "5e a taken display is refused" "$rc" "65"; is "5f and the row is byte-identical" "$(cksum < "$SESS/$L.conf")" "$sum"
# P3: a row of another runtime is not this verb's business, and its bytes are untouched.
M="s-00000000000000m1"
printf 'ID="%s"\nACCOUNT="a-h1"\nSLUG="thirteen"\nOWNER="a"\nHOST="h1"\nDOMAIN="alpha"\nREPO_PATH="/tmp/repo"\nTARGET_ENTITY="alpha"\nRC_LABEL="Thirteen"\nRUNTIME="opencode"\nMODEL="openai/m"\nOPENCODE_VERSION="1.0.0"\nOPENCODE_PORT="4097"\nAUTO_APPROVE="true"\nCLAUDE_MEMORY_ROOT="/tmp/m"\n' "$M" > "$SESS/$M.conf"
sum="$(cksum < "$SESS/$M.conf")"; out="$(run "$M")"; rc=$?
is "5g an OpenCode row is refused (RUNTIME first)" "$rc" "65"; has "5h and says why" "$out" "vestigial"
is "5i byte-identical" "$(cksum < "$SESS/$M.conf")" "$sum"
# P4: a row already without the line, whose target renders nothing, is not a successful idempotent migration.
N="s-00000000000000n1"
printf 'ID="%s"\nACCOUNT="a-h1"\nSLUG="fourteen"\nOWNER="a"\nHOST="h1"\nDOMAIN="alpha"\nREPO_PATH="/tmp/repo"\nTARGET_PROJECT="no-such-project"\n' "$N" > "$SESS/$N.conf"
sum="$(cksum < "$SESS/$N.conf")"; out="$(run "$N")"; rc=$?
is "5j no label and a broken target: refused, not 'already derived'" "$rc" "65"; has "5k and says it has no display at all" "$out" "no display at all"
is "5l byte-identical" "$(cksum < "$SESS/$N.conf")" "$sum"

echo "== 6. the gate that runs INSIDE the writer's lock, proven on its own (advisor P1) =="
# registry_row_replace calls this on the STAGED row while it holds the sessions lock. A competitor that
# takes the display between the pre-check and the publish is caught here, not by the pre-check.
in_lib() { OUT="$( export STEWARD_ESTATE_ROOT="$ROOT" STEWARD_CONFIG_FILE="$T/no-such-config"; . "$here/lib/registry.sh"; REGISTRY_DERIVE_ID="$1"; REGISTRY_DERIVE_EXPECT="${3:-}"; "$2" "$4" 2>&1 )"; RC=$?; }
# Section 5 left a row with no display at all (P4's case) - the gate below fails closed on it, which is
# section 9's property in test/registry-session-display.test.sh, not this one. Repair it away first.
rm -f "$SESS/s-00000000000000n1.conf"
printf 'NAME="Contest"\nPARENT="alpha"\n' > "$ROOT/projects.d/contest.conf"
STAGED="$T/staged.conf"
printf 'ID="s-00000000000000p1"\nACCOUNT="a-h1"\nSLUG="fifteen"\nOWNER="a"\nHOST="h1"\nDOMAIN="alpha"\nREPO_PATH="/tmp/repo"\nTARGET_PROJECT="contest"\n' > "$STAGED"
in_lib s-00000000000000p1 registry_derive_validate_stage "" "$STAGED"; is "6a a staged row whose display is free passes the in-lock gate" "$RC" "0"
# the competitor lands between the pre-check and the publish
printf 'ID="s-00000000000000q1"\nACCOUNT="a-h1"\nSLUG="sixteen"\nOWNER="a"\nHOST="h1"\nDOMAIN="alpha"\nREPO_PATH="/tmp/repo"\nTARGET_PROJECT="contest"\n' > "$SESS/s-00000000000000q1.conf"
in_lib s-00000000000000p1 registry_derive_validate_stage "" "$STAGED"; is "6b the same staged row is REFUSED once a competitor holds the display" "$RC" "70"
has "6c and the refusal names the competitor" "$OUT" "s-00000000000000q1"
# and the readback is the promise, checked after the publish
in_lib s-00000000000000q1 registry_derive_readback "Alpha→Contest" s-00000000000000q1; is "6d the readback accepts the promised display" "$RC" "0"
in_lib s-00000000000000q1 registry_derive_readback "Something Else" s-00000000000000q1; is "6e and refuses any other" "$RC" "1"
has "6f naming what it found" "$OUT" "Alpha→Contest"
rm -f "$SESS/s-00000000000000q1.conf" "$ROOT/projects.d/contest.conf"

echo "== 7. R1: the row the content was built from must still be the row under the lock =="
# Advisor R1: the content is built before registry_row_replace takes the lock; a concurrent writer that
# changes the SAME row in between would be overwritten with stale content. The in-lock validator now also
# compares the source row's fingerprint (size + cksum, captured when the content was built).
SRC="$SESS/s-00000000000000r1.conf"
printf 'NAME="Seventeen"\nPARENT="alpha"\n' > "$ROOT/projects.d/seventeen.conf"   # a target of its own: the display rule must pass on its own
printf 'ID="s-00000000000000r1"\nACCOUNT="a-h1"\nSLUG="seventeen"\nOWNER="a"\nHOST="h1"\nDOMAIN="alpha"\nREPO_PATH="/tmp/repo"\nTARGET_PROJECT="seventeen"\nRC_LABEL="Old"\n' > "$SRC"
printf 'ID="s-00000000000000r1"\nACCOUNT="a-h1"\nSLUG="seventeen"\nOWNER="a"\nHOST="h1"\nDOMAIN="alpha"\nREPO_PATH="/tmp/repo"\nTARGET_PROJECT="seventeen"\n' > "$STAGED"
fp_of() { ( export STEWARD_ESTATE_ROOT="$ROOT" STEWARD_CONFIG_FILE="$T/no-such-config"; . "$here/lib/registry.sh"; registry_row_fingerprint "$1" ); }
FP="$(fp_of "$SRC")"
in_fp() { OUT="$( export STEWARD_ESTATE_ROOT="$ROOT" STEWARD_CONFIG_FILE="$T/no-such-config"; . "$here/lib/registry.sh"; REGISTRY_DERIVE_ID="s-00000000000000r1"; REGISTRY_DERIVE_SOURCE_FP="$1"; registry_derive_validate_stage "$STAGED" 2>&1 )"; RC=$?; }
in_fp "$FP"; is "7a the same source passes" "$RC" "0"
printf 'REPO_PATH="/tmp/other"\n' >> "$SRC"
in_fp "$FP"; is "7b a source that changed between the build and the lock is REFUSED" "$RC" "70"; has "7c and the refusal says the row changed" "$OUT" "changed"
in_fp ""; is "7d no fingerprint given (another caller) - the gate does not invent one; rc 0 on the display rule alone" "$RC" "0"
in_fp "$(fp_of "$SRC")"; is "7e the fresh fingerprint passes again" "$RC" "0"
rm -f "$SRC"; in_fp "$FP"; is "7f a source that vanished is refused too" "$RC" "70"; rm -f "$ROOT/projects.d/seventeen.conf"

echo "== 8. R2: the content build fails closed - a read failure or an empty body never publishes a comment-only row =="
in_content() { OUT="$( export STEWARD_ESTATE_ROOT="$ROOT" STEWARD_CONFIG_FILE="$T/no-such-config"; . "$here/lib/registry.sh"; registry_derive_content "$1" "$2" 2>"$T/c.err" )"; RC=$?; CERR="$(cat "$T/c.err")"; }
printf 'ID="s-00000000000000r2"\nRC_LABEL="Old"\nOWNER="a"\n' > "$T/c1.conf"
in_content "$T/c1.conf" "Old"; is "8a body without the label line, plus the comment" "$OUT" "$(printf 'ID="s-00000000000000r2"\nOWNER="a"\n# display derived from the target (was RC_LABEL="Old")')"
is "8b rc 0" "$RC" "0"
in_content "$T/no-such.conf" "Old"; is "8c an unreadable source is rc 70" "$RC" "70"; is "8d and prints NOTHING (nothing to publish)" "$OUT" ""
has "8c2 and says it could not READ - the read failure is its own refusal, not the empty-body one" "$CERR" "could not read"
printf 'RC_LABEL="Only"\n' > "$T/c2.conf"
in_content "$T/c2.conf" "Only"; is "8e a row that would be left with only the comment is rc 70" "$RC" "70"; is "8f and prints nothing" "$OUT" ""
has "8g saying why" "$CERR" "nothing but"

printf '\n%d passed, %d failed\n' "$pass" "$fail"; [ "$fail" -eq 0 ]
