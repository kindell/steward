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
mkdir -p "$FX/estate" "$FX/entities.d" "$FX/projects.d" "$FX/sessions.d" "$FX/mcp.d" "$FX/env/beta"

cat > "$FX/estate/steward.conf" <<'EOF'
ESTATE_NAME="fixture"
LABEL_PREFIX="com.fixture.claude"
HUB_HOST="h1"
OP_TOKEN_FILE_NAME="fixture-token"
EOF

ENT="$FX/entities.d"; PROJ="$FX/projects.d"; MCPD="$FX/mcp.d"; SESS="$FX/sessions.d"

printf 'NAME="Acme"\nMEMBERS="a"\nMCP_ASSETS="chat-tool"\n'                 > "$ENT/acme.conf"
printf 'NAME="Beta"\nMANAGED_BY="acme"\nMCP_ASSETS="mail-tool"\n'           > "$ENT/beta.conf"
printf 'NAME="Gamma"\nPARENT="beta"\nMCP_ASSETS="notes-tool"\n'             > "$PROJ/gamma.conf"
printf 'NAME="Quiet"\nMEMBERS="a"\n'                                        > "$ENT/quiet.conf"
printf 'NAME="Lonely"\nMEMBERS="a"\nMCP_ASSETS="ghost-tool absent-tool"\n'  > "$ENT/lonely.conf"
printf 'NAME="Starry"\nMEMBERS="a"\nMCP_ASSETS="star-tool"\n'               > "$ENT/starry.conf"

printf 'MCP_COMMAND="/opt/chat/server"\n'                                   > "$MCPD/chat-tool.conf"
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

echo "pass=$pass fail=$fail"
[ "$fail" -eq 0 ]
