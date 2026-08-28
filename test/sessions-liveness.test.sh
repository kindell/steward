#!/bin/bash
# test/sessions-liveness.test.sh — the liveness seam: is this session alive?
#
# THE MEASUREMENT IS INJECTED, AND HERE THAT IS A SAFETY RULE, NOT A
# CONVENIENCE. The real liveness command reads a live multiplexer socket and can
# send keystrokes into running conversations. A suite that called it for real
# would type into someone's session. Every case below is a stub; nothing in this
# file may ever name a real socket.
#
# UNMEASURABLE IS `unknown`, NEVER ABSENT. A missing command, a command that
# fails, output that does not parse: all of them yield a full row of `unknown`.
# A row with fields missing would let a consumer read absence as health.
set -u

here="$(CDPATH= cd -- "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
pass=0; fail=0
ok()  { pass=$((pass+1)); printf '  ok   %s\n' "$1"; }
bad() { fail=$((fail+1)); printf '  FAIL %s\n     %s\n' "$1" "${2:-}"; }
is()  { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "wanted '$3', got '$2'"; fi; }

FX="$(mktemp -d)"; trap 'rm -rf "$FX"' EXIT
# shellcheck source=/dev/null
. "$here/lib/liveness.sh"

field() { printf '%s\n' "$1" | awk -F'\t' -v r="$2" -v c="$3" '$1==r{print $c}'; }

stub() { # <name> <body>
  printf '#!/bin/bash\n%s\n' "$2" > "$FX/$1"; chmod +x "$FX/$1"; printf '%s' "$FX/$1"
}

echo "== a measured session carries every field =="
good="$(stub good 'cat <<'"'"'J'"'"'
{"sessions":{"alpha":{"daemon":"loaded","tmux":"up","agent":"running",
 "runtime":"claude-code","model":"opus","lastActivity":"2026-08-28T09:00:00.000Z"}}}
J')"
out="$(STEWARD_LIVENESS_CMD="$good" liveness_rows)"; rc=$?
is "rc 0" "$rc" "0"
is "daemon"   "$(field "$out" alpha 2)" "loaded"
is "tmux"     "$(field "$out" alpha 3)" "up"
is "agent"    "$(field "$out" alpha 4)" "running"
is "runtime"  "$(field "$out" alpha 5)" "claude-code"
is "model"    "$(field "$out" alpha 6)" "opus"
is "activity" "$(field "$out" alpha 7)" "2026-08-28T09:00:00.000Z"

# `null` AND MISSING ARE DIFFERENT FACTS, and this is the distinction the whole
# layer exists to keep. An explicit null means the command looked and found no
# value; a missing key means it never looked. Collapsing them would turn "we did
# not measure the model" into "this session has no model".
echo "== an explicit null is measured-and-empty; a missing key is unmeasured =="
mixed="$(stub mixed 'cat <<'"'"'J'"'"'
{"sessions":{"beta":{"daemon":"missing","tmux":"down","agent":"not-running",
 "runtime":"claude-code","model":null}}}
J')"
out2="$(STEWARD_LIVENESS_CMD="$mixed" liveness_rows)"
is "an explicit null model is a dash"    "$(field "$out2" beta 6)" "-"
is "a missing lastActivity is unknown"   "$(field "$out2" beta 7)" "unknown"

echo "== what cannot be measured =="

# NO COMMAND AT ALL. The common case before an estate has wired its own shim.
# `env -u` cannot be used here: liveness_rows is a sourced shell function, not
# an executable on PATH, so env would only report "command not found" instead
# of exercising the no-command path. Unset in a subshell instead, so the
# absence is scoped to this one call and never leaks into the rest of the file.
out3="$(unset STEWARD_LIVENESS_CMD; liveness_rows)"; rc3=$?
is "no command still returns rc 0" "$rc3" "0"
is "and prints nothing"            "$out3" ""

# A COMMAND THAT FAILS is not a command that measured nothing.
bad_rc="$(stub badrc 'exit 3')"
out4="$(STEWARD_LIVENESS_CMD="$bad_rc" liveness_rows)"
is "a failing command prints nothing" "$out4" ""

# OUTPUT THAT DOES NOT PARSE must not be read as an empty fleet.
garbage="$(stub garbage 'echo "this is not json"')"
out5="$(STEWARD_LIVENESS_CMD="$garbage" liveness_rows 2>/dev/null)"
is "unparseable output prints nothing" "$out5" ""

# THE LOOKUP IS WHERE ABSENCE BECOMES `unknown`. liveness_rows prints only what
# it measured; liveness_for is what guarantees a caller always gets a full row.
echo "== a session the command never mentioned is unknown, not absent =="
row="$(liveness_for gamma "$out")"
# EIGHT FIELDS, not seven: the eighth is the REASON. A non-answer that does not
# say why is the silence this whole model exists to make impossible.
is "eight fields"  "$(printf '%s\n' "$row" | awk -F'\t' '{print NF}')" "8"
is "daemon"        "$(printf '%s\n' "$row" | cut -f2)" "unknown"
is "tmux"          "$(printf '%s\n' "$row" | cut -f3)" "unknown"
is "agent"         "$(printf '%s\n' "$row" | cut -f4)" "unknown"
is "runtime"       "$(printf '%s\n' "$row" | cut -f5)" "unknown"
is "model is a dash, not a guess" "$(printf '%s\n' "$row" | cut -f6)" "-"
is "last_activity is a dash, not a guess" "$(printf '%s\n' "$row" | cut -f7)" "-"
is "and the reason is not empty" \
   "$( [ -n "$(printf '%s\n' "$row" | cut -f8)" ] && echo yes || echo no )" "yes"

echo "== and a session it did mention comes back intact =="
row2="$(liveness_for alpha "$out")"
is "tmux survives the lookup" "$(printf '%s\n' "$row2" | cut -f3)" "up"
is "last_activity survives the lookup" "$(printf '%s\n' "$row2" | cut -f7)" "2026-08-28T09:00:00.000Z"

# A PROBER THAT INVENTS A WORD MUST NOT REACH A CONSUMER. The vocabulary for
# each field is closed; anything else is a broken command, and a broken command
# must not be able to render as healthy.
echo "== a word outside the vocabulary is rewritten to unknown =="
liar="$(stub liar 'cat <<'"'"'J'"'"'
{"sessions":{"delta":{"daemon":"excellent","tmux":"fabulous","agent":"running"}}}
J')"
out6="$(STEWARD_LIVENESS_CMD="$liar" liveness_rows)"
is "an invented daemon word becomes unknown" "$(field "$out6" delta 2)" "unknown"
is "an invented tmux word becomes unknown"   "$(field "$out6" delta 3)" "unknown"
is "the legitimate field survives"           "$(field "$out6" delta 4)" "running"

# NO REAL SOCKET, EVER. A guard on the suite itself: if a future edit points the
# seam at anything that looks like a live multiplexer socket, fell the suite
# rather than discover it by typing into a conversation.
#
# The banned substrings are assembled from separate pieces at runtime, and
# never appear whole anywhere in this file, including in comments: written out
# in full, either one would make this check find itself on every run, no
# matter what the library does, and a guard that always fails is no guard.
# ── A MISCONFIGURED SEAM MUST NOT BE BYTE-IDENTICAL TO A WORKING ONE ───────
#
# The assertions above are right about stdout purity and were, for that reason,
# the exact place this hid: five distinct misconfigurations all returned rc 0
# with nothing on either stream, and the whole fleet then rendered as a column
# of `unknown` with no reason anywhere. rc IS ALWAYS 0 here and stays that way —
# this layer reports. rc is not the channel; stderr is.
echo "== a misconfigured seam says what was wrong, on stderr =="
# NOT EXECUTABLE. A real file, wrong mode — the commonest of them, because a
# checkout that lost its exec bit looks entirely healthy in a directory listing.
printf '#!/bin/bash\necho "{}"\n' > "$FX/noexec"; chmod -x "$FX/noexec"
o_ne="$(STEWARD_LIVENESS_CMD="$FX/noexec" liveness_rows 2>"$FX/ne.err")"
is "not executable: stdout stays empty" "$o_ne" ""
is "not executable: and stderr says so" \
   "$( [ -s "$FX/ne.err" ] && echo yes || echo no )" "yes"
is "not executable: naming the path"    \
   "$(grep -q "$FX/noexec" "$FX/ne.err" && echo yes || echo no)" "yes"

# OUTPUT THAT DOES NOT PARSE. The command ran and answered; the answer is not
# an answer. Reading that as an empty fleet is reading a broken tool as health.
garb2="$(stub garbage2 'echo "this is not json"')"
o_gb="$(STEWARD_LIVENESS_CMD="$garb2" liveness_rows 2>"$FX/gb.err")"
is "unparseable: stdout stays empty" "$o_gb" ""
is "unparseable: and stderr says so" \
   "$( [ -s "$FX/gb.err" ] && echo yes || echo no )" "yes"

# A PATH THAT DOES NOT EXIST — a typo in a deploy, indistinguishable from a
# working seam until someone asks why nothing is ever measured.
o_nf="$(STEWARD_LIVENESS_CMD="$FX/does-not-exist" liveness_rows 2>"$FX/nf.err")"
is "missing path: stdout stays empty" "$o_nf" ""
is "missing path: and stderr says so" \
   "$( [ -s "$FX/nf.err" ] && echo yes || echo no )" "yes"

# A BARE COMMAND NAME rather than a path. `[ -x ]` fails on anything unresolved,
# so this reads exactly like every other silence — and it is a plausible
# mistake, because most environment variables that name a command take one.
o_bn="$(STEWARD_LIVENESS_CMD="true" liveness_rows 2>"$FX/bn.err")"
is "bare name: stdout stays empty" "$o_bn" ""
is "bare name: and stderr says so" \
   "$( [ -s "$FX/bn.err" ] && echo yes || echo no )" "yes"

# A COMMAND THAT FAILS.
bad_rc2="$(stub badrc2 'echo "boom" >&2; exit 3')"
o_rc="$(STEWARD_LIVENESS_CMD="$bad_rc2" liveness_rows 2>"$FX/rc.err")"
is "failing command: stdout stays empty" "$o_rc" ""
is "failing command: and stderr says so" \
   "$( [ -s "$FX/rc.err" ] && echo yes || echo no )" "yes"
is "failing command: the command's own words survive" \
   "$(grep -q 'boom' "$FX/rc.err" && echo yes || echo no)" "yes"

# THE UNSET CASE IS NOT AN ERROR. An estate that has not wired a shim yet is a
# normal state; making it noisy would train the reader to ignore the line that
# matters.
echo "== an unconfigured seam stays quiet — that is a normal state =="
o_un="$(unset STEWARD_LIVENESS_CMD; liveness_rows 2>"$FX/un.err")"
is "unset: stdout stays empty" "$o_un" ""
is "unset: and stderr stays empty too" \
   "$( [ -s "$FX/un.err" ] && echo yes || echo no )" "no"

# ── A NON-ANSWER CARRIES ITS REASON ───────────────────────────────────────
#
# `unknown` with no reason is the silence this whole model exists to make
# impossible: six different causes render as one word, and a view cannot invent
# a reason it was never given. The reason is an eighth field — a DETAIL, next to
# the status words, never a fifth status word of its own.
#
# liveness_rows sets LIVENESS_SEAM_REASON in the CALLER's shell, so these calls
# redirect its stdout to a file rather than capturing it in `$(...)` — a command
# substitution is a subshell and the variable would never come back.
echo "== a session that was not measured says why =="
reason_of() { printf '%s\n' "$1" | cut -f8; }

STEWARD_LIVENESS_CMD="$good" liveness_rows >"$FX/rows.good" 2>/dev/null
rows_good="$(cat "$FX/rows.good")"
is "a measured session's reason is a dash — there is nothing to explain" \
   "$(reason_of "$(liveness_for alpha "$rows_good")")" "-"
is "eight fields now, not seven" \
   "$(printf '%s\n' "$(liveness_for alpha "$rows_good")" | awk -F'\t' '{print NF}')" "8"
is "a session the seam ran and did not mention says so" \
   "$(reason_of "$(liveness_for gamma "$rows_good")")" "not-in-answer"

( unset STEWARD_LIVENESS_CMD; liveness_rows >/dev/null 2>&1
  r="$(liveness_for gamma "")"
  printf '%s' "$r" | cut -f8 ) > "$FX/r.unconf"
is "an unconfigured seam says that, not 'not measured'" \
   "$(cat "$FX/r.unconf")" "seam-not-configured"

STEWARD_LIVENESS_CMD="$bad_rc2" liveness_rows >/dev/null 2>/dev/null
is "a seam that ran and failed says that" \
   "$(reason_of "$(liveness_for gamma "")")" "seam-failed"

STEWARD_LIVENESS_CMD="$garb2" liveness_rows >/dev/null 2>/dev/null
is "a seam whose answer does not parse says that" \
   "$(reason_of "$(liveness_for gamma "")")" "seam-unparseable"

STEWARD_LIVENESS_CMD="$FX/noexec" liveness_rows >/dev/null 2>/dev/null
is "a seam that could not be run says that" \
   "$(reason_of "$(liveness_for gamma "")")" "seam-not-executable"

# THE ESTATE MAY NAME ITS OWN OMISSIONS. A session the shim could not measure
# is still OMITTED from `sessions` — it is never guessed — but the shim may say
# why in an `omitted` map, and that reason reaches the consumer instead of a
# bare "not in the answer".
echo "== an omission the seam explained keeps the seam's own words =="
omit="$(stub omit 'cat <<'"'"'J'"'"'
{"sessions":{"alpha":{"daemon":"loaded","tmux":"up","agent":"running","runtime":"claude-code"}},
 "omitted":{"delta":"the launch manager did not answer"}}
J')"
STEWARD_LIVENESS_CMD="$omit" liveness_rows >"$FX/rows.omit" 2>/dev/null
rows_omit="$(cat "$FX/rows.omit")"
drow="$(liveness_for delta "$rows_omit")"
is "the omitted session's reason is the seam's own" \
   "$(reason_of "$drow")" "the launch manager did not answer"
is "and it is still not claimed to be down" \
   "$(printf '%s\n' "$drow" | cut -f3)" "unknown"

# AN OMISSION LISTED WITHOUT A REASON IS ITS OWN WORD, NOT A BARE SILENCE. A
# shim may name a session in `omitted` and still supply an empty string (or the
# dash this file uses elsewhere for "nothing here") as its reason — that is
# different from `not-in-answer` (the shim never mentioned the session at all)
# and must not collapse into it.
echo "== an omission listed with an empty reason gets its own word =="
omit_empty="$(stub omitempty 'cat <<'"'"'J'"'"'
{"sessions":{},"omitted":{"epsilon":""}}
J')"
STEWARD_LIVENESS_CMD="$omit_empty" liveness_rows >"$FX/rows.omitempty" 2>/dev/null
rows_omitempty="$(cat "$FX/rows.omitempty")"
erow="$(liveness_for epsilon "$rows_omitempty")"
is "the reason is omitted-without-reason, not a blank" \
   "$(reason_of "$erow")" "omitted-without-reason"

# FIELD CONTENT IS A HAZARD ON THIS SIDE TOO. This half of the chain was never
# injectable — @tsv has escaped every value since the first version — but no
# fixture in this family ever carried whitespace in a field, so the property was
# believed rather than measured. The identity half was injectable for exactly
# that long, for exactly that reason.
echo "== a value carrying a tab cannot forge a column =="
nasty="$(stub nasty 'printf "%s" "{\"sessions\":{\"eps\":{\"daemon\":\"loaded\",\"tmux\":\"up\",\"agent\":\"running\",\"runtime\":\"rt\tzz-ghost\tup\tup\tup\",\"model\":\"m\"}}}"')"
STEWARD_LIVENESS_CMD="$nasty" liveness_rows >"$FX/rows.nasty" 2>/dev/null
rows_nasty="$(cat "$FX/rows.nasty")"
is "one session answered for is one row out" \
   "$(printf '%s\n' "$rows_nasty" | grep -c .)" "1"
is "and it still has exactly eight fields" \
   "$(printf '%s\n' "$rows_nasty" | awk -F'\t' 'NR==1{print NF}')" "8"
is "the model column is not overwritten by the injection" \
   "$(field "$rows_nasty" eps 6)" "m"

echo "== the suite never names a real socket =="
_no_sock_pat='\.s'"ock"
_no_tmux_s_pat='tmux'; _no_tmux_s_pat="${_no_tmux_s_pat} -S"
if grep -qE "$_no_sock_pat|$_no_tmux_s_pat" "$here/test/sessions-liveness.test.sh"; then
  bad "the suite must not name a socket or invoke tmux directly" "found a match"
else
  ok "the suite names no socket and invokes no multiplexer"
fi

echo
printf 'pass=%s fail=%s\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
