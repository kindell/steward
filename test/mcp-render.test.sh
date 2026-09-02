#!/bin/bash
# test/mcp-render.test.sh — `steward mcp render <session-id>`, the one verb
# that turns the inherited MCP set (test/mcp-registry.test.sh) into a
# claude-compatible mcp-config document.
#
# THE PATTERN THIS SUITE EXISTS TO DEFEND: paths on command lines, values only
# in files. A rendered config is read by a process tree, quoted into logs, and
# printed by an operator debugging a session — so a token that reaches it is a
# token in every one of those places. When an asset declares MCP_ENV_FILE the
# command becomes a wrapper that is HANDED THE PATH and reads the file itself;
# the value never appears in the document, and section 4 below proves it by
# writing a real secret into a real env file and grepping the output for it.
#
# THE SECOND RULE IS ALL-OR-NOTHING. An asset whose definition is missing is
# OMITTED and NAMED, never rendered half-formed: a server entry with no command
# is a session that fails at start-up with no clue why, which is strictly worse
# than a server that was never offered.
#
# HERMETIC: a fresh mktemp estate per run, STEWARD_CONFIG_FILE pinned to a path
# that cannot exist.
set -u

here="$(CDPATH= cd -- "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
STEWARD="$here/bin/steward"
pass=0; fail=0
ok()  { pass=$((pass+1)); printf '  ok   %s\n' "$1"; }
bad() { fail=$((fail+1)); printf '  FAIL %s\n     %s\n' "$1" "${2:-}"; }
is()  { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "wanted '$3', got '$2'"; fi; }
has() { case "$2" in *"$3"*) ok "$1" ;; *) bad "$1" "missing '$3' in: $2" ;; esac; }
hasnt(){ case "$2" in *"$3"*) bad "$1" "unexpectedly present '$3' in: $2" ;; *) ok "$1" ;; esac; }

FX="$(mktemp -d)"; trap 'rm -rf "$FX"' EXIT
mkdir -p "$FX/estate" "$FX/entities.d" "$FX/projects.d" "$FX/sessions.d" "$FX/mcp.d" "$FX/env/beta" "$FX/accounts.d"

cat > "$FX/estate/steward.conf" <<'EOF'
ESTATE_NAME="fixture"
LABEL_PREFIX="com.fixture.claude"
HUB_HOST="h1"
OP_TOKEN_FILE_NAME="fixture-token"
EOF

ENT="$FX/entities.d"; PROJ="$FX/projects.d"; MCPD="$FX/mcp.d"; SESS="$FX/sessions.d"
ACC="$FX/accounts.d"

printf 'NAME="Acme"\nMEMBERS="a"\nMCP_ASSETS="chat-tool"\n'                 > "$ENT/acme.conf"
printf 'NAME="Beta"\nMANAGED_BY="acme"\nMCP_ASSETS="mail-tool"\n'           > "$ENT/beta.conf"
printf 'NAME="Gamma"\nPARENT="beta"\nMCP_ASSETS="notes-tool"\n'             > "$PROJ/gamma.conf"
printf 'NAME="Quiet"\nMEMBERS="a"\n'                                        > "$ENT/quiet.conf"
printf 'NAME="Lonely"\nMEMBERS="a"\nMCP_ASSETS="ghost-tool absent-tool"\n'  > "$ENT/lonely.conf"
printf 'NAME="Starry"\nMEMBERS="a"\nMCP_ASSETS="star-tool"\n'               > "$ENT/starry.conf"

# THE ACCOUNTS — personal capability, bound to the human and not to a node.
printf 'PRINCIPAL="ann"\nHOST="h1"\nMCP_ASSETS="crm-tool"\n'              > "$ACC/ann-h1.conf"
printf 'PRINCIPAL="bo"\nHOST="h1"\nMCP_ASSETS="video-tool"\n'             > "$ACC/bo-h1.conf"

printf 'MCP_COMMAND="/opt/chat/server"\n'                                   > "$MCPD/chat-tool.conf"
printf 'MCP_COMMAND="/opt/crm/server"\n'                                    > "$MCPD/crm-tool.conf"
printf 'MCP_COMMAND="/opt/video/server"\n'                                  > "$MCPD/video-tool.conf"
cat > "$MCPD/mail-tool.conf" <<'EOF'
MCP_COMMAND="/opt/mail/server"
MCP_ARGS="--port 7 --quiet"
MCP_ENV_FILE="/etc/steward/env/<domain>/mail-tool.env"
EOF
cat > "$MCPD/star-tool.conf" <<'EOF'
MCP_COMMAND="/opt/star/server"
MCP_ARGS="* --flag"
EOF
# notes-tool, ghost-tool and absent-tool are DELIBERATELY ABSENT.

sess() { printf 'OWNER="a"\nHOST="h1"\nREPO_PATH="/tmp/x"\nID="%s"\n%s\n' "$1" "$2" > "$SESS/$1.conf"; }
sess s-project 'TARGET_PROJECT="gamma"'
sess s-quiet   'DOMAIN="quiet"
RC_LABEL="L"'
sess s-lonely  'DOMAIN="lonely"
RC_LABEL="L"'
sess s-star    'DOMAIN="starry"
RC_LABEL="L"'
# SAME entity, DIFFERENT accounts — the pair the account axis exists for.
sess s-ann     'ACCOUNT="ann-h1"
TARGET_PROJECT="gamma"'
sess s-bo      'ACCOUNT="bo-h1"
TARGET_PROJECT="gamma"'
sess s-noacct  'ACCOUNT="ghost-h1"
TARGET_ENTITY="beta"'

run() {
  STEWARD_ESTATE_ROOT="$FX" STEWARD_CONFIG_FILE="$FX/no-such-config" \
  STEWARD_VIEWER=a bash "$STEWARD" "$@"
}

echo "== 1. the inherited set, rendered in inheritance order =="
out="$(run mcp render s-project 2>"$FX/e1")"; rc=$?
err="$(cat "$FX/e1")"
is "1a rc 0 — one omitted asset does not sink the render" "$rc" "0"
is "1b it is valid JSON" "$(printf '%s' "$out" | jq -e 'type' 2>/dev/null)" '"object"'
is "1c the keys are the team's grant then the client's, in that order" \
   "$(printf '%s' "$out" | jq -r '.mcpServers | keys_unsorted | join(",")')" \
   "chat-tool,mail-tool"

echo "== 2. a plain asset: the command as declared, no args =="
is "2a command" "$(printf '%s' "$out" | jq -r '.mcpServers["chat-tool"].command')" "/opt/chat/server"
is "2b args is an empty LIST, never absent — a consumer reading .args must not get null" \
   "$(printf '%s' "$out" | jq -c '.mcpServers["chat-tool"].args')" "[]"

echo "== 3. an asset with MCP_ENV_FILE: the wrapper form =="
is "3a command is the wrapper" \
   "$(printf '%s' "$out" | jq -r '.mcpServers["mail-tool"].command')" "~/bin/mcp-env"
# THE ENV PATH FIRST, THEN THE REAL COMMAND, THEN ITS OWN ARGS — and <domain>
# resolved to the OWNING ENTITY (beta), not to the row's derived DOMAIN
# (gamma, the project slug). The env file belongs to the client whose secrets
# they are; a project-shaped path would look for it where it is not.
is "3b args are [env-path, command, ...MCP_ARGS] with <domain> substituted" \
   "$(printf '%s' "$out" | jq -c '.mcpServers["mail-tool"].args')" \
   '["/etc/steward/env/beta/mail-tool.env","/opt/mail/server","--port","7","--quiet"]'

echo "== 4. values NEVER inline; the PATH may appear =="
# A REAL SECRET IN A REAL FILE. The whole design claim is that a rendered
# config can be pasted into a bug report — this is the assertion that makes
# that claim measurable rather than stated.
printf 'MAIL_TOKEN=this-must-never-be-rendered\n' > "$FX/env/beta/mail-tool.env"
chmod 600 "$FX/env/beta/mail-tool.env"
out4="$(run mcp render s-project 2>/dev/null)"
hasnt "4a the value is nowhere in the document" "$out4" "this-must-never-be-rendered"
hasnt "4b nor is the variable's name"           "$out4" "MAIL_TOKEN"
has   "4c the path itself is there — that is the pattern" "$out4" "/mail-tool.env"

echo "== 5. a missing definition is OMITTED and NAMED =="
hasnt "5a notes-tool is not in the document" "$out" "notes-tool"
has   "5b it is named on stderr"             "$err" "notes-tool"
has   "5c together with the session id"      "$err" "s-project"
# NEVER A HALF DEFINITION: no key may exist without a command.
is "5d every rendered server has a command" \
   "$(printf '%s' "$out" | jq -r '[.mcpServers[] | select((.command | type) != "string" or .command == "")] | length')" "0"

echo "== 6. an empty set is an empty document, not a refusal =="
out6="$(run mcp render s-quiet 2>/dev/null)"; rc6=$?
is "6a rc 0"                       "$rc6" "0"
is "6b mcpServers is present and empty" "$(printf '%s' "$out6" | jq -c '.mcpServers')" "{}"

echo "== 7. a non-empty set that renders NOTHING refuses =="
# The difference between "no servers were granted" and "every granted server
# is missing from the register" is the whole reason this branch exists: the
# first is a configuration, the second is a fault, and an empty document
# would report the fault as the configuration.
out7="$(run mcp render s-lonely 2>"$FX/e7")"; rc7=$?
err7="$(cat "$FX/e7")"
is  "7a rc 65"                        "$rc7" "65"
is  "7b and NOTHING on stdout"        "$out7" ""
has "7c both assets are named: ghost-tool" "$err7" "ghost-tool"
has "7d and absent-tool"                   "$err7" "absent-tool"

echo "== 8. MCP_ARGS splits on spaces and never globs =="
mkdir -p "$FX/cwd" && : > "$FX/cwd/chat-tool" && : > "$FX/cwd/mail-tool"
out8="$(cd "$FX/cwd" && run mcp render s-star 2>/dev/null)"
is "8 the asterisk reached the args as itself" \
   "$(printf '%s' "$out8" | jq -c '.mcpServers["star-tool"].args')" '["*","--flag"]'

echo "== 9. the verb's own refusals =="
out9="$(run mcp render no-such-session 2>"$FX/e9")"; rc9=$?
is  "9a an unknown session refuses"  "$rc9" "65"
is  "9b with nothing on stdout"      "$out9" ""
has "9c naming it"                   "$(cat "$FX/e9")" "no-such-session"
run mcp render >/dev/null 2>&1
is  "9d render with no session id is a usage error" "$?" "64"
run mcp >/dev/null 2>&1
is  "9e a bare 'mcp' is a usage error"              "$?" "64"
run mcp sing >/dev/null 2>&1
is  "9f an unknown mcp verb is a usage error"       "$?" "64"

echo "== 10. a level that FAILED to load never renders as an empty document =="
# THE FAULT MUST NOT READ AS THE CONFIGURATION. Section 6 above is the honest
# empty set — nobody granted anything. This is the other thing entirely: a
# level of the org would not load, so the resolver could not say what was
# granted. Rendering {} with rc 0 for both tells a spawner "start this session
# with no tools" when the truth is "one typo hid every capability under this
# client", and a machine reads the rc, not the sentence.
printf 'NAME="Broke"\nMANAGED_BY="nosuchteam"\nMCP_ASSETS="chat-tool"\n' > "$ENT/broke.conf"
sess s-broke 'DOMAIN="broke"
RC_LABEL="L"'
out10="$(run mcp render s-broke 2>"$FX/e10")"; rc10=$?
err10="$(cat "$FX/e10")"
is  "10a rc 65, not 0"                    "$rc10" "65"
is  "10b and NOTHING on stdout"           "$out10" ""
has "10c the session is named"            "$err10" "s-broke"
has "10d the level that failed is named"  "$err10" "broke"
has "10e and the actual culprit with it"  "$err10" "nosuchteam"

echo "== 11. the <domain> substitution refuses a slug that is a path =="
# The value spliced into a credential path comes from the owning-entity join,
# and one of that join's three sources — a project row's PARENT — is
# grammar-checked by nobody upstream. A projects.d row loads AS AN ENTITY (it
# has a NAME), so PARENT="../projects.d/<other>" made a session render against
# another row's credentials and inherit its grants.
printf 'NAME="Other Work"\nPARENT="beta"\nMCP_ASSETS="secret-tool"\n' > "$PROJ/otherwork.conf"
printf 'NAME="Own Work"\nPARENT="../projects.d/otherwork"\nMCP_ASSETS="mail-tool"\n' > "$PROJ/ownwork.conf"
printf 'MCP_COMMAND="/opt/secret/server"\n' > "$MCPD/secret-tool.conf"
sess s-traverse 'TARGET_PROJECT="ownwork"'
out11="$(run mcp render s-traverse 2>"$FX/e11")"; rc11=$?
err11="$(cat "$FX/e11")"
is    "11a rc 65 — the join refused, so there is no document"   "$rc11" "65"
is    "11b nothing on stdout"                                   "$out11" ""
hasnt "11c no traversal reached a rendered path"                "$out11" "projects.d"
hasnt "11d and the other row's capability was never inherited"  "$out11" "secret-tool"
has   "11e the refused value is named on stderr"                "$err11" "projects.d/otherwork"

echo "== 12. quotes and backslashes in a definition stay DATA =="
# The jq construction is what keeps them data; nothing pinned it, so a future
# hand-rolled printf would pass every other assertion in this file.
cat > "$MCPD/odd-tool.conf" <<'ODD'
MCP_COMMAND="/opt/o\"dd/ser\\ver"
MCP_ARGS="--json {\"a\":1} --win C:\\\\tmp --quote \" --end"
ODD
printf 'NAME="Odd"\nMEMBERS="a"\nMCP_ASSETS="odd-tool"\n' > "$ENT/odd.conf"
sess s-odd 'DOMAIN="odd"
RC_LABEL="L"'
out12="$(run mcp render s-odd 2>/dev/null)"; rc12=$?
is "12a rc 0"                     "$rc12" "0"
is "12b the document is valid JSON" \
   "$(printf '%s' "$out12" | jq -e 'type' 2>/dev/null)" '"object"'
is "12c the key list is exactly the one asset — nothing smuggled a second key" \
   "$(printf '%s' "$out12" | jq -r '.mcpServers | keys_unsorted | join(",")')" "odd-tool"
is "12d the quote and the backslash reached the command byte for byte" \
   "$(printf '%s' "$out12" | jq -r '.mcpServers["odd-tool"].command')" \
   '/opt/o"dd/ser\ver'
is "12e and the args split on spaces with every byte intact" \
   "$(printf '%s' "$out12" | jq -c '.mcpServers["odd-tool"].args')" \
   '["--json","{\"a\":1}","--win","C:\\\\tmp","--quote","\"","--end"]'

echo "== 13. the operator is told the REAL reason an asset was omitted =="
# One catch-all sentence for three different faults — no such file, an illegal
# slug, a row with no MCP_COMMAND — sends the operator to look for a file that
# is sitting right there. The loader's own diagnostic is already precise; it
# was being thrown away.
printf 'MCP_ARGS="--nothing"\n' > "$MCPD/no-command.conf"
printf 'NAME="Half"\nMEMBERS="a"\nMCP_ASSETS="no-command"\n' > "$ENT/half.conf"
sess s-half 'DOMAIN="half"
RC_LABEL="L"'
run mcp render s-half >/dev/null 2>"$FX/e13"
err13="$(cat "$FX/e13")"
has "13a the missing FIELD is named, not just the asset" "$err13" "MCP_COMMAND"
has "13b the asset too"                                  "$err13" "no-command"
# A slug carrying a carriage return: the real cause is the grammar, and the CR
# must never reach the terminal, where it overwrites the line being read.
printf 'NAME="Crlf"\nMEMBERS="a"\nMCP_ASSETS="chat-tool\r"\n' > "$ENT/crlf.conf"
sess s-crlf 'DOMAIN="crlf"
RC_LABEL="L"'
run mcp render s-crlf >/dev/null 2>"$FX/e13b"
err13b="$(cat "$FX/e13b")"
has   "13c the grammar is named as the cause"  "$err13b" "invalid mcp asset name"
hasnt "13d and no raw carriage return reached the operator's terminal" \
      "$err13b" "$(printf '\r')"

echo "== 14. the verb is in the usage banner, and only the verb =="
# usage() seds every `#   ` line out of this file, so a comment block indented
# that way anywhere below turns prose into what reads as four more verbs.
help="$(run --help 2>&1)"
has   "14a the verb is listed"                        "$help" "steward mcp render <session-id>"
hasnt "14b and the rc-contract prose is not listed as a verb" "$help" "rc 0 with servers"

echo "== 15. the account's own personal grant is rendered, and it leads the document =="
# THE KEY ORDER IS THE INHERITANCE, and the document is keyed from the
# resolver's own order: account first, then the managing team, the owning
# entity, the project. A reader of the JSON sees whose grant each server came
# through without having to consult four files.
out15="$(run mcp render s-ann 2>"$FX/e15")"; rc15=$?
is "15a rc 0" "$rc15" "0"
is "15b the personal asset leads, then the team's, then the client's" \
   "$(printf '%s' "$out15" | jq -r '.mcpServers | keys_unsorted | join(",")')" \
   "crm-tool,chat-tool,mail-tool"
is "15c and it is rendered whole, command and all" \
   "$(printf '%s' "$out15" | jq -r '.mcpServers["crm-tool"].command')" "/opt/crm/server"
is "15d the org levels still render exactly as before the axis existed" \
   "$(printf '%s' "$out15" | jq -c '.mcpServers["mail-tool"].args')" \
   '["/etc/steward/env/beta/mail-tool.env","/opt/mail/server","--port","7","--quiet"]'

echo "== 16. two sessions, one entity, two people — two different documents =="
# A PERSONAL CREDENTIAL IS THE THING BEING HANDED OUT HERE. Both sessions sit
# on the same project under the same client, so every org level grants them an
# identical set; if the rendered documents were equal, one person would be
# starting a server against the other's account.
out16="$(run mcp render s-bo 2>/dev/null)"
is    "16a bo's document leads with HIS asset" \
      "$(printf '%s' "$out16" | jq -r '.mcpServers | keys_unsorted | join(",")')" \
      "video-tool,chat-tool,mail-tool"
hasnt "16b ann's personal server is nowhere in bo's document" "$out16" "crm-tool"
hasnt "16c and bo's is nowhere in ann's"                      "$out15" "video-tool"
is    "16d the shared org grant is identical in both — only the person differs" \
      "$(printf '%s' "$out16" | jq -c '.mcpServers["mail-tool"]')" \
      "$(printf '%s' "$out15" | jq -c '.mcpServers["mail-tool"]')"

echo "== 17. an ACCOUNT naming a missing row refuses the render, it does not thin it =="
# THE SAME CONTRACT SECTION 10 PINS FOR THE ORG LEVELS, on the axis that
# carries the personal credentials. Rendering the org half with rc 0 would
# tell a spawner "this is what somebody granted you" while the person's entire
# personal set had silently vanished.
out17="$(run mcp render s-noacct 2>"$FX/e17")"; rc17=$?
err17="$(cat "$FX/e17")"
is  "17a rc 65, not 0"                     "$rc17" "65"
is  "17b and NOTHING on stdout"            "$out17" ""
has "17c the account that failed is named" "$err17" "ghost-h1"
has "17d and the session with it"          "$err17" "s-noacct"

echo "== 18. the library's header states what this suite is to the extraction =="
# lib/mcprender.sh was lifted out of bin/steward's cmd_mcp_render verbatim, and
# the paragraph that says so lost its own ending in the move: "...is unchanged
# and is the" ran straight into the next paragraph's "Prints a ...". The claim
# this suite exists to back -- that the move changed no behaviour -- was left
# as half a sentence, which is a claim no reader can check.
HDR="$(awk '/^[^#]/{exit} {print}' "$here/lib/mcprender.sh")"
hasnt "18a the extraction sentence does not run into the next paragraph" \
      "$HDR" "and is the
# Prints"
has   "18b it names this suite as the measurement of the move" \
      "$HDR" "test/mcp-render.test.sh"
has   "18c and finishes the thought"  "$HDR" "measurement"

echo "pass=$pass fail=$fail"
[ "$fail" -eq 0 ]
