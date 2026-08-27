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
is "seven fields"  "$(printf '%s\n' "$row" | awk -F'\t' '{print NF}')" "7"
is "daemon"        "$(printf '%s\n' "$row" | cut -f2)" "unknown"
is "tmux"          "$(printf '%s\n' "$row" | cut -f3)" "unknown"
is "agent"         "$(printf '%s\n' "$row" | cut -f4)" "unknown"
is "runtime"       "$(printf '%s\n' "$row" | cut -f5)" "unknown"
is "model is a dash, not a guess" "$(printf '%s\n' "$row" | cut -f6)" "-"

echo "== and a session it did mention comes back intact =="
row2="$(liveness_for alpha "$out")"
is "tmux survives the lookup" "$(printf '%s\n' "$row2" | cut -f3)" "up"

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
