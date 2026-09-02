#!/bin/bash
# test/mcpspawn.test.sh -- lib/mcpspawn.sh, the policy that turns one session's
# rendered MCP set into the arguments a supervisor splices into its claude
# command.
#
# THE POINT OF THE SUITE IS THE MIDDLE ROW. A render can end three ways that a
# naive spawner collapses into one: a document, an empty document, and a
# refusal. Collapsing them means a session whose whole grant failed to resolve
# starts with the repo's own .mcp.json -- everything the repo happens to
# declare -- while the registry was trying to say "this set could not be
# honored". That is the opposite of fail-closed, and it is silent.
#
# So the outcomes are separated here, one case per exit code, and two of them
# are asserted to produce the SAME argument fragment for OPPOSITE reasons:
# rc 0/1 hands claude a document that has servers in it, rc 2 hands it a
# document that has none, and both are strict. Only rc 3 -- the registry never
# spoke -- leaves the command line alone.
#
# HERMETIC: a fresh mktemp estate per run, STEWARD_CONFIG_FILE pinned to a path
# that cannot exist. The fixture is the shape test/mcp-render.test.sh uses.
set -u
# THE WRAPPER KNOB IS UNSET TOO. STEWARD_MCP_WRAPPER changes what the document
# names; an operator shell that exports it would turn assertions about the
# default wrapper into assertions about that shell. Same lesson as the estate
# root: a suite is hermetic against every knob, not just the ones it noticed.
unset STEWARD_MCP_WRAPPER

here="$(CDPATH= cd -- "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
pass=0; fail=0
ok()  { pass=$((pass+1)); printf '  ok   %s\n' "$1"; }
bad() { fail=$((fail+1)); printf '  FAIL %s\n     %s\n' "$1" "${2:-}"; }
is()  { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "wanted '$3', got '$2'"; fi; }
has() { case "$2" in *"$3"*) ok "$1" ;; *) bad "$1" "missing '$3' in: $2" ;; esac; }
hasnt(){ case "$2" in *"$3"*) bad "$1" "unexpectedly present '$3' in: $2" ;; *) ok "$1" ;; esac; }

# The mode digits, on either stat. A document that is world-readable is the
# whole pattern lost: it names credential FILES, and a reader who can list them
# knows where to go next.
mode_of() { stat -f '%OLp' "$1" 2>/dev/null || stat -c '%a' "$1" 2>/dev/null; }

FX="$(mktemp -d)"; trap 'rm -rf "$FX"' EXIT
mkdir -p "$FX/estate" "$FX/entities.d" "$FX/projects.d" "$FX/sessions.d" "$FX/mcp.d" \
         "$FX/accounts.d" "$FX/docs"

cat > "$FX/estate/steward.conf" <<'EOF'
ESTATE_NAME="fixture"
LABEL_PREFIX="com.fixture.claude"
HUB_HOST="h1"
OP_TOKEN_FILE_NAME="fixture-token"
EOF

ENT="$FX/entities.d"; MCPD="$FX/mcp.d"; SESS="$FX/sessions.d"

printf 'NAME="Alpha"\nMEMBERS="a"\nMCP_ASSETS="chat-tool"\n'                > "$ENT/alpha.conf"
printf 'NAME="Beta"\nMEMBERS="a"\nMCP_ASSETS="chat-tool notes-tool"\n'      > "$ENT/beta.conf"
printf 'NAME="Gamma"\nMEMBERS="a"\nMCP_ASSETS="ghost-tool absent-tool"\n'   > "$ENT/gamma.conf"
printf 'NAME="Delta"\nMEMBERS="a"\n'                                        > "$ENT/delta.conf"
printf 'NAME="Epsilon"\nMEMBERS="a"\nMCP_ASSETS="mail-tool"\n'              > "$ENT/epsilon.conf"

printf 'MCP_COMMAND="/opt/chat/server"\n'                                   > "$MCPD/chat-tool.conf"
cat > "$MCPD/mail-tool.conf" <<'EOF'
MCP_COMMAND="/opt/mail/server"
MCP_ENV_FILE="/etc/steward/env/<domain>/mail-tool.env"
EOF
# notes-tool, ghost-tool and absent-tool are DELIBERATELY ABSENT.

sess() { printf 'OWNER="a"\nHOST="h1"\nREPO_PATH="/tmp/x"\nID="%s"\nRC_LABEL="L"\n%s\n' "$1" "$2" > "$SESS/$1.conf"; }
sess s-full     'DOMAIN="alpha"'
sess s-degraded 'DOMAIN="beta"'
sess s-refused  'DOMAIN="gamma"'
sess s-empty    'DOMAIN="delta"'
sess s-envfile  'DOMAIN="epsilon"'

# THE SUPERVISOR'S OWN LOAD ORDER, reproduced: registry, render, spawn, all
# three from one directory, none of them reaching for bin/steward. A library
# that only works when bin/steward loaded it first is a library the session
# host cannot use, and the session host is the whole point.
prep() { # <session-id> <document-path> -> rc, fragment on stdout, render stderr on stderr
  STEWARD_ESTATE_ROOT="$FX" STEWARD_CONFIG_FILE="$FX/no-such-config" STEWARD_VIEWER=a \
  bash -c '. "$1/lib/registry.sh"; . "$1/lib/mcprender.sh"; . "$1/lib/mcpspawn.sh"
           mcp_spawn_prepare "$2" "$3"' _ "$here" "$1" "$2"
}
frag() { # the splice, called the way the supervisor calls it
  bash -c '. "$1/lib/mcpspawn.sh"; mcp_claude_cmd_fragment "$2" "$3" "$4" "$5"' \
    _ "$here" "$1" "$2" "$3" "$4"
}

DOC="$FX/state/s.mcp.json"

echo "== 1. rc 0 -- a set that rendered whole =="
out="$(prep s-full "$DOC" 2>"$FX/e1")"; rc=$?
is "1a rc 0"                        "$rc" "0"
is "1b the fragment carries its own leading space, like NAME_ARG does" \
   "$out" " --strict-mcp-config --mcp-config \"$DOC\""
is "1c the document exists and holds the granted server" \
   "$(jq -r '.mcpServers | keys_unsorted | join(",")' "$DOC" 2>/dev/null)" "chat-tool"
is "1d 0600 -- it names credential files, so nobody else may read it" \
   "$(mode_of "$DOC")" "600"
is "1e nothing on stderr for a clean render" "$(cat "$FX/e1")" ""

echo "== 2. rc 1 -- rendered, DEGRADED: a granted asset was omitted =="
# The distinction rc 1 exists for: the session still starts, with tools, and
# somebody must be told that part of what was granted is not there. Folding
# this into rc 0 makes a half grant indistinguishable from a whole one.
out2="$(prep s-degraded "$DOC" 2>"$FX/e2")"; rc2=$?
err2="$(cat "$FX/e2")"
is  "2a rc 1"                       "$rc2" "1"
is  "2b the fragment is the same one -- the session starts"  \
    "$out2" " --strict-mcp-config --mcp-config \"$DOC\""
is  "2c the document holds what DID render" \
    "$(jq -r '.mcpServers | keys_unsorted | join(",")' "$DOC" 2>/dev/null)" "chat-tool"
has "2d the omitted asset is named on stderr, for the caller to alarm with" "$err2" "notes-tool"
has "2e and the render's own word for it is carried through"                "$err2" "OMITTED"

echo "== 3. rc 2 -- the render REFUSED: strict and empty, never legacy =="
# THE FAIL-CLOSED ROW. Every granted asset failed to resolve. Handing the
# session the repo's own .mcp.json here would answer a refusal with MORE tools
# than the registry ever granted, and nothing in the running session would
# show that the grant had been lost.
out3="$(prep s-refused "$DOC" 2>"$FX/e3")"; rc3=$?
err3="$(cat "$FX/e3")"
is  "3a rc 2"                        "$rc3" "2"
is  "3b the fragment is STILL strict -- an empty document, deliberately" \
    "$out3" " --strict-mcp-config --mcp-config \"$DOC\""
is  "3c and the document is empty, not absent" \
    "$(jq -c '.mcpServers' "$DOC" 2>/dev/null)" "{}"
is  "3d 0600 here too"               "$(mode_of "$DOC")" "600"
has "3e the refused assets are named on stderr: ghost-tool" "$err3" "ghost-tool"
has "3f and absent-tool"                                    "$err3" "absent-tool"

echo "== 4. rc 3 -- nothing was granted: the legacy path, untouched =="
# THE REGISTRY NEVER SPOKE. Live sessions with no grant at all must keep the
# command line they have today, down to the byte -- so the fragment is EMPTY
# and claude falls back to the repo's own .mcp.json exactly as before.
out4="$(prep s-empty "$DOC" 2>"$FX/e4")"; rc4=$?
is "4a rc 3"                    "$rc4" "3"
is "4b and NOTHING on stdout -- no flags are spliced" "$out4" ""

echo "== 5. rc 3 removes a stale document =="
# A document left behind by a grant that has since been revoked is worse than
# no document: the next round splices nothing, but anything else that reads
# the state directory still finds a set nobody grants any more.
printf '{"mcpServers":{"chat-tool":{"command":"/opt/chat/server","args":[]}}}\n' > "$DOC"
prep s-empty "$DOC" >/dev/null 2>&1
[ -f "$DOC" ] && bad "5 the stale document survived a revoked grant" || ok "5 the stale document is gone"

echo "== 6. rc 69 -- no jq, no spawn =="
# The render cannot build a document safely without jq, and a spawner that
# treated that as "nothing granted" would start the session on the legacy path
# because a TOOL is missing. Refusing is the only honest answer.
rm -rf "$FX/shimbin"; mkdir -p "$FX/shimbin"
for b in /usr/bin/* /bin/*; do
  n="$(basename "$b")"; [ "$n" = "jq" ] && continue
  ln -sf "$b" "$FX/shimbin/$n" 2>/dev/null
done
rm -f "$DOC"
out6="$(PATH="$FX/shimbin" prep s-full "$DOC" 2>"$FX/e6")"; rc6=$?
is "6a rc 69"                     "$rc6" "69"
is "6b and NOTHING on stdout"     "$out6" ""
[ -f "$DOC" ] && bad "6c a document was written without jq" || ok "6c no document was written"
has "6d jq is named"              "$(cat "$FX/e6")" "jq"

echo "== 7. the document holds PATHS, never values =="
# The same claim test/mcp-render.test.sh makes about the render's stdout, made
# again about the FILE this library writes -- because that file is the one a
# human opens at 2am, and it lands in a state directory that outlives the run.
out7="$(prep s-envfile "$DOC" 2>/dev/null)"; rc7=$?
doc7="$(cat "$DOC" 2>/dev/null)"
is    "7a rc 0"                        "$rc7" "0"
is    "7b the command is the wrapper"  \
      "$(jq -r '.mcpServers["mail-tool"].command' "$DOC" 2>/dev/null)" "$HOME/bin/mcp-env"
has   "7c and the env file's PATH is an argument" "$doc7" "/mail-tool.env"
hasnt "7d nothing that looks like a value reached the file" "$doc7" "MAIL_TOKEN"
# A TILDE IS A PATH THAT NEVER RESOLVES HERE. `steward mcp render` writes the
# document on the machine that HOLDS the register and a human reads it, so the
# literal ~/bin/mcp-env is right there. This library renders on the machine that
# RUNS the session, at spawn time, and hands the result to claude -- and an MCP
# client spawns a server's `command` DIRECTLY, with no shell to expand anything.
# A tilde is then a directory named "~", the server dies with ENOENT, and under
# --strict-mcp-config that is a granted asset that silently never starts.
hasnt "7e no tilde survives into the document the supervisor hands to claude" \
      "$doc7" "~"
has   "7f and the wrapper is named absolutely"    "$doc7" "$HOME/bin/mcp-env"

echo "== 8. the splice: the label is the LAST argument =="
# The pid-finding pattern in the supervisor anchors on the label. A flag
# appended after it does not fail loudly -- it makes aliveness measurement
# quietly wrong, and a supervisor that misjudges aliveness writes into live
# conversations. This is the assertion that keeps the order.
cmd="$(frag "--continue" " --strict-mcp-config --mcp-config /s/d.json" " --name \"disp\"" "L")"
is "8a the whole command, in order" "$cmd" \
   'claude --continue --permission-mode bypassPermissions --strict-mcp-config --mcp-config /s/d.json --name "disp" --remote-control "L"'
case "$cmd" in
  *' --remote-control "L"') ok "8b the label ends the command line" ;;
  *) bad "8b the label ends the command line" "got: $cmd" ;;
esac
is "8c the binary is still the first word -- the CLAUDE_BIN guard reads it" \
   "${cmd%% *}" "claude"

echo "== 9. the splice with no grant is the command line as it is today =="
# rc 3 must change NOTHING. This is that promise, spelled out as a string.
is "9a no MCP fragment, no --continue" \
   "$(frag "" "" " --name \"disp\"" "L")" \
   'claude  --permission-mode bypassPermissions --name "disp" --remote-control "L"'
is "9b an RC-free session gets no --remote-control at all" \
   "$(frag "--continue" "" "" "")" \
   'claude --continue --permission-mode bypassPermissions'

echo "== 10. a probe that FAILED is not a probe that answered zero =="
# THE ONE DIRECTION THIS LIBRARY EXISTS TO FORBID. rc 3 means "the registry
# never spoke", and it is the only outcome that leaves the command line alone
# -- i.e. hands the session the repo's own .mcp.json, everything the checkout
# happens to declare. The emptiness probe answering an ERROR is not that: it is
# an UNKNOWN, and an unknown answer about a grant must fail closed like every
# other unknown in this file.
#
# The shim fails ONLY the probe's filter, so the render itself still succeeds
# and still produces a document with a granted server in it -- which is what
# makes the old behaviour (rc 3, legacy, silent) reachable at all.
rm -rf "$FX/probebin"; mkdir -p "$FX/probebin"
REALJQ="$(command -v jq)"
cat > "$FX/probebin/jq" <<EOF
#!/bin/bash
for a in "\$@"; do
  case "\$a" in *'.mcpServers | length'*) exit 1 ;; esac
done
exec "$REALJQ" "\$@"
EOF
chmod 755 "$FX/probebin/jq"
rm -f "$DOC"
out10="$(PATH="$FX/probebin:$PATH" prep s-full "$DOC" 2>"$FX/e10")"; rc10=$?
err10="$(cat "$FX/e10")"
is  "10a a failed probe resolves to rc 2, never rc 3" "$rc10" "2"
is  "10b and the fragment is the fail-closed one"     "$out10" \
    " --strict-mcp-config --mcp-config \"$DOC\""
is  "10c the document written is the EMPTY one"       \
    "$(jq -c '.mcpServers' "$DOC" 2>/dev/null)" "{}"
has "10d and the reason is on stderr, not swallowed"  "$err10" "probe"

echo "== 11. a probe that answers something that is not a count refuses too =="
# rc 0 with garbage on stdout is the same unknown wearing a success code -- a
# jq replaced mid-run by a deploy, a shim, a wrapper that prints a warning.
rm -rf "$FX/probebin2"; mkdir -p "$FX/probebin2"
cat > "$FX/probebin2/jq" <<EOF
#!/bin/bash
for a in "\$@"; do
  case "\$a" in *'.mcpServers | length'*) echo "not-a-number"; exit 0 ;; esac
done
exec "$REALJQ" "\$@"
EOF
chmod 755 "$FX/probebin2/jq"
rm -f "$DOC"
out11="$(PATH="$FX/probebin2:$PATH" prep s-full "$DOC" 2>"$FX/e11")"; rc11=$?
is    "11a rc 2, not rc 3"                          "$rc11" "2"
is    "11b the document is empty and present"       \
      "$(jq -c '.mcpServers' "$DOC" 2>/dev/null)" "{}"
hasnt "11c the probe's own output is not quoted back" "$(cat "$FX/e11")" "not-a-number"

echo "== 12. the document path survives a directory with a space in it =="
# THE FRAGMENT ENDS UP INSIDE A SHELL STRING. The supervisor splices it into
# CLAUDE_CMD and then into "$HOME/.local/bin/$CLAUDE_CMD; exec bash", which tmux
# hands to a shell -- so the assertion that matters is not the string this
# library prints, it is the ARGV that string becomes. Every other component of
# that command line quotes its value (NAME_ARG is --name \"$SESSION_NAME\",
# the label is --remote-control \"$RC_LABEL\"); this one must too.
#
# Today's exposure is $HOME: STATE_DIR_NAME is validated and $NAME is s-<hex>,
# but the macOS twin sources this same library on homes named /Users/First Last.
# Unquoted, claude gets a truncated config path plus a stray positional
# argument -- under --strict-mcp-config that is a session with no tools and no
# diagnosis anywhere.
SPACEDOC="$FX/state dir/s.mcp.json"
out12="$(prep s-full "$SPACEDOC" 2>/dev/null)"; rc12=$?
is "12a rc 0"                       "$rc12" "0"
argv12=(); eval "argv12=($out12)"
is "12b the flag is its own argument"                "${argv12[0]:-}" "--strict-mcp-config"
is "12c and the path arrives WHOLE, as one argument" "${argv12[2]:-}" "$SPACEDOC"
is "12d with nothing split off the end of it"        "${#argv12[@]}"  "3"

echo "== 13. a document path that is a DIRECTORY is refused, not moved into =="
# `mv -f "$tmp" "$doc"` with $doc an existing directory MOVES THE TEMP FILE INTO
# IT and returns 0. The write then reported success, the fragment pointed
# --mcp-config at a directory, and a 0600 s.mcp.json.tmp.<pid> was left inside it
# forever. claude cannot read a directory as a config, so the honest answer is
# the refusal this library already has for a document it cannot write.
DIRDOC="$FX/dirdoc/s.mcp.json"
rm -rf "$FX/dirdoc"; mkdir -p "$DIRDOC"
out13="$(prep s-full "$DIRDOC" 2>"$FX/e13")"; rc13=$?
is "13a rc 69 -- the document could not be written"  "$rc13" "69"
is "13b and NOTHING on stdout: no fragment names a directory" "$out13" ""
has "13c the path is named in the refusal"           "$(cat "$FX/e13")" "$DIRDOC"
is "13d and no temp file was orphaned inside it" \
   "$(find "$DIRDOC" -name '*.tmp.*' 2>/dev/null | wc -l | tr -d ' ')" "0"
# THE SAME ON THE REFUSAL PATH. rc 2 writes the empty document through the same
# helper, and a fail-closed answer that silently wrote nowhere is not one.
out13b="$(prep s-refused "$DIRDOC" 2>"$FX/e13b")"; rc13b=$?
is "13e the refusal path refuses too"                "$rc13b" "69"
is "13f with no fragment"                            "$out13b" ""
is "13g and still nothing orphaned" \
   "$(find "$DIRDOC" -name '*.tmp.*' 2>/dev/null | wc -l | tr -d ' ')" "0"

echo "pass=$pass fail=$fail"
[ "$fail" -eq 0 ]
