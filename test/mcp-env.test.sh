#!/bin/bash
# test/mcp-env.test.sh -- linux/mcp-env, the wrapper a rendered mcp-config names
# when an asset declares MCP_ENV_FILE.
#
# WHY THE WRAPPER EXISTS. The document is read by a process tree, quoted into
# logs, pasted into bug reports and printed by whoever is debugging a session at
# 2am. So the render puts the credential file's PATH on the command line and
# never its contents (test/mcp-render.test.sh, section 4), and this program is
# what turns that path back into an environment -- on the session host, inside
# the process that needs it, and nowhere else.
#
# THE TWO PROPERTIES THIS SUITE DEFENDS:
#
#   IT DOES NOT SOURCE. A credential file that a shell reads as SHELL is a file
#   that can run code, with whatever the session has. Sourcing is the obvious
#   implementation and the wrong one; section 5 writes a file that would execute
#   if it were sourced and measures that it did not.
#
#   IT DOES NOT PRINT. Every refusal names a PATH or a LINE NUMBER. A wrapper
#   that echoed the offending line to explain itself would put the credential in
#   the journal, which is the one place the whole pattern exists to keep it out
#   of.
set -u

here="$(CDPATH= cd -- "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
W="$here/linux/mcp-env"
pass=0; fail=0
ok()  { pass=$((pass+1)); printf '  ok   %s\n' "$1"; }
bad() { fail=$((fail+1)); printf '  FAIL %s\n     %s\n' "$1" "${2:-}"; }
is()  { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "wanted '$3', got '$2'"; fi; }
has() { case "$2" in *"$3"*) ok "$1" ;; *) bad "$1" "missing '$3' in: $2" ;; esac; }
hasnt(){ case "$2" in *"$3"*) bad "$1" "unexpectedly present '$3' in: $2" ;; *) ok "$1" ;; esac; }

FX="$(mktemp -d)"; trap 'rm -rf "$FX"' EXIT
SHOW="$FX/show"
cat > "$SHOW" <<'EOF'
#!/bin/bash
for v in "$@"; do printf '%s=%s\n' "$v" "${!v-<unset>}"; done
EOF
chmod 755 "$SHOW"

echo "== 1. the file becomes an environment, and the command is exec'd =="
cat > "$FX/plain.env" <<'EOF'
# a comment, skipped

ALPHA=one
BETA=two
EOF
out="$(bash "$W" "$FX/plain.env" "$SHOW" ALPHA BETA 2>"$FX/e1")"; rc=$?
is "1a rc 0"                              "$rc" "0"
is "1b the first variable reached the command" "$(printf '%s' "$out" | sed -n '1p')" "ALPHA=one"
is "1c and the second"                         "$(printf '%s' "$out" | sed -n '2p')" "BETA=two"
is "1d nothing on stderr"                 "$(cat "$FX/e1")" ""

echo "== 2. a value with spaces, equals signs and quotes survives whole =="
# The split is on the FIRST equals sign only. A token is not a shell word, and
# a wrapper that split on every equals sign would hand the server a truncated
# credential -- which fails as an authentication error, three layers away from
# the cause.
printf 'TOKEN=a b=c "d" $e `f`\n' > "$FX/odd.env"
out2="$(bash "$W" "$FX/odd.env" "$SHOW" TOKEN 2>/dev/null)"
is "2 the value arrived byte for byte, unexpanded" "$out2" 'TOKEN=a b=c "d" $e `f`'

echo "== 3. a missing or unreadable file REFUSES, loudly, by path =="
out3="$(bash "$W" "$FX/no-such.env" "$SHOW" ALPHA 2>"$FX/e3")"; rc3=$?
err3="$(cat "$FX/e3")"
is  "3a rc 66"                       "$rc3" "66"
is  "3b the command never ran"       "$out3" ""
has "3c the path is named"           "$err3" "$FX/no-such.env"
: > "$FX/locked.env"; chmod 000 "$FX/locked.env"
if [ -r "$FX/locked.env" ]; then
  ok "3d an unreadable file refuses (skipped: this filesystem or user reads mode 000 anyway)"
else
  bash "$W" "$FX/locked.env" "$SHOW" ALPHA >/dev/null 2>&1
  is "3d an unreadable file refuses the same way" "$?" "66"
fi
chmod 644 "$FX/locked.env"

echo "== 4. a line that is not KEY=value REFUSES, by LINE NUMBER =="
# THE LINE NUMBER, NEVER THE LINE. The whole reason this file is handled by a
# parser instead of a shell is that its contents must not leak; a refusal that
# quoted the line to be helpful would print a credential into the journal on
# the day somebody's editor mangled the file.
cat > "$FX/bad.env" <<'EOF'
GOOD=fine
export SECRET=hunter2-must-never-be-printed
EOF
out4="$(bash "$W" "$FX/bad.env" "$SHOW" GOOD 2>"$FX/e4")"; rc4=$?
err4="$(cat "$FX/e4")"
is    "4a rc 65"                     "$rc4" "65"
is    "4b the command never ran"     "$out4" ""
has   "4c the line NUMBER is named"  "$err4" "line 2"
hasnt "4d the value is not echoed"   "$err4" "hunter2-must-never-be-printed"
hasnt "4e nor is the key it tried to set" "$err4" "SECRET"
# A key that breaks the grammar in the other direction: it starts legally and
# then carries a character an environment variable name cannot hold.
printf 'A-B=x\n' > "$FX/bad2.env"
bash "$W" "$FX/bad2.env" "$SHOW" GOOD >/dev/null 2>"$FX/e4b"
is  "4f a key with an illegal character refuses too" "$?" "65"
has "4g naming its line"                             "$(cat "$FX/e4b")" "line 1"

echo "== 5. the file is DATA, never shell =="
# The obvious implementation is `set -a; . "$envfile"`. It is the wrong one: a
# credential file is written by deploy tooling, edited by hand and readable by
# whoever owns the home, and sourcing turns every one of those into code
# execution inside the session. Nothing else in this suite would notice.
cat > "$FX/exec.env" <<EOF
HARMLESS=yes
INJECTED=\$(touch "$FX/pwned")
EOF
out5="$(bash "$W" "$FX/exec.env" "$SHOW" HARMLESS INJECTED 2>/dev/null)"; rc5=$?
is "5a rc 0 -- the line is well formed, it is just not code" "$rc5" "0"
[ -e "$FX/pwned" ] && bad "5b the substitution RAN -- the wrapper sources its input" \
                     || ok "5b nothing was executed"
is "5c and the value arrived as the literal text it is" \
   "$(printf '%s' "$out5" | sed -n '2p')" 'INJECTED=$(touch "'"$FX"'/pwned")'

echo "== 6. the wrapper never prints the file =="
# The claim the whole pattern rests on, measured rather than stated: run it on
# a file holding a real-looking secret and grep everything it said.
printf 'API_KEY=zz-never-print-this-value\n' > "$FX/secret.env"
noise="$(bash "$W" "$FX/secret.env" /usr/bin/true 2>&1)"
hasnt "6a the value is nowhere in what the wrapper printed" "$noise" "zz-never-print-this-value"
is    "6b and it printed nothing at all"                    "$noise" ""

echo "== 7. the usage guard =="
bash "$W" >/dev/null 2>"$FX/e7a";                 is "7a no arguments at all"      "$?" "64"
bash "$W" "$FX/plain.env" >/dev/null 2>"$FX/e7b"; is "7b a file and no command"    "$?" "64"
has "7c the usage line names the shape"           "$(cat "$FX/e7b")" "<env-file>"

echo "== 8. the exec'd command's own exit code is the wrapper's =="
# It is an exec, not a call: a server that dies with a code must not have that
# code replaced by the wrapper's own idea of success.
bash "$W" "$FX/plain.env" bash -c 'exit 42' >/dev/null 2>&1
is "8a the code travels"    "$?" "42"
bash "$W" "$FX/plain.env" bash -c 'exit 0' >/dev/null 2>&1
is "8b and so does success" "$?" "0"

echo "== 9. a file with no trailing newline still yields its last variable =="
printf 'LAST=here' > "$FX/notrail.env"
is "9 the final line is read" \
   "$(bash "$W" "$FX/notrail.env" "$SHOW" LAST 2>/dev/null)" "LAST=here"

echo "pass=$pass fail=$fail"
[ "$fail" -eq 0 ]
