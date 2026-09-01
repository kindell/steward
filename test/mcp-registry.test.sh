#!/bin/bash
# test/mcp-registry.test.sh — the mcp.d register, the MCP_ASSETS field on the
# two row types that may carry it, and the session resolver that unions them.
#
# WHAT THIS SUITE IS ABOUT. An MCP server is a capability a session is given,
# and the estate already has a place that says who a session belongs to: the
# team that manages the client, the client itself, the project the work sits
# in. Declaring the same server on every session that needs it is the shape
# this register exists to replace — one row per capability, referenced from
# whichever level of the org actually owns it.
#
# THE LOAD-BEARING SECTION is the resolver. Inheritance is the one thing here
# that cannot be read off a single file: a wrong ORDER hands a project a
# server its client never granted, a missing DEDUP renders the same server
# twice, and a level that fails to load SILENTLY is a capability that vanishes
# with no trace of why. Every one of those three is pinned below.
#
# HERMETIC: a fresh mktemp estate per run, STEWARD_CONFIG_FILE pinned to a
# path that cannot exist.
set -u

here="$(CDPATH= cd -- "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
pass=0; fail=0
ok()  { pass=$((pass+1)); printf '  ok   %s\n' "$1"; }
bad() { fail=$((fail+1)); printf '  FAIL %s\n     %s\n' "$1" "${2:-}"; }
is()  { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "wanted '$3', got '$2'"; fi; }
has() { case "$2" in *"$3"*) ok "$1" ;; *) bad "$1" "missing '$3' in: $2" ;; esac; }
hasnt(){ case "$2" in *"$3"*) bad "$1" "unexpectedly present '$3' in: $2" ;; *) ok "$1" ;; esac; }

FX="$(mktemp -d)"; trap 'rm -rf "$FX"' EXIT
mkdir -p "$FX/estate" "$FX/entities.d" "$FX/projects.d" "$FX/sessions.d" "$FX/mcp.d"

# registry_load REFUSES without an estate file — LABEL_PREFIX, HUB_HOST and
# OP_TOKEN_FILE_NAME are read unconditionally. A fixture that skips this file
# is not "no estate configured", it is every session failing to load.
cat > "$FX/estate/steward.conf" <<'EOF'
ESTATE_NAME="fixture"
LABEL_PREFIX="com.fixture.claude"
HUB_HOST="h1"
OP_TOKEN_FILE_NAME="fixture-token"
EOF

ENT="$FX/entities.d"; PROJ="$FX/projects.d"; MCPD="$FX/mcp.d"; SESS="$FX/sessions.d"

# ── THE ORG: a team that manages a client that owns a project ──────────────
printf 'NAME="Acme"\nMEMBERS="a"\nMCP_ASSETS="chat-tool"\n'                    > "$ENT/acme.conf"
printf 'NAME="Beta"\nMANAGED_BY="acme"\nMCP_ASSETS="mail-tool chat-tool"\n'    > "$ENT/beta.conf"
printf 'NAME="Gamma"\nPARENT="beta"\nMCP_ASSETS="notes-tool mail-tool"\n'      > "$PROJ/gamma.conf"
# A team that grants nothing: its levels contribute nothing AND say nothing.
printf 'NAME="Quiet"\nMEMBERS="a"\n'                                           > "$ENT/quiet.conf"
# A project whose PARENT names an entity that does not exist: the row will
# not load, and that must be said out loud rather than read as "no assets".
printf 'NAME="Delta"\nPARENT="ghost"\nMCP_ASSETS="mail-tool"\n'                > "$PROJ/delta.conf"

# ── THE REGISTER ───────────────────────────────────────────────────────────
printf 'MCP_COMMAND="/opt/chat/server"\n'                                      > "$MCPD/chat-tool.conf"
cat > "$MCPD/mail-tool.conf" <<'EOF'
MCP_COMMAND="/opt/mail/server"
MCP_ARGS="--port 7 --quiet"
MCP_ENV_FILE="/etc/steward/env/<domain>/mail-tool.env"
EOF
# notes-tool is DELIBERATELY ABSENT — the omission case lives in the render
# suite, and the resolver must still carry the slug through to it.
printf 'MCP_ARGS="--nothing"\n'                                                > "$MCPD/no-command.conf"

# ── THE SESSIONS ───────────────────────────────────────────────────────────
sess() { printf 'OWNER="a"\nHOST="h1"\nREPO_PATH="/tmp/x"\nID="%s"\n%s\n' "$1" "$2" > "$SESS/$1.conf"; }
sess s-project 'TARGET_PROJECT="gamma"'
sess s-entity  'TARGET_ENTITY="beta"'
sess s-legacy  'DOMAIN="acme"
RC_LABEL="L"'
sess s-orphan  'DOMAIN="nowhere"
RC_LABEL="L"'
sess s-quiet   'DOMAIN="quiet"
RC_LABEL="L"'
sess s-broken  'TARGET_PROJECT="delta"'

export STEWARD_ESTATE_ROOT="$FX"
export STEWARD_CONFIG_FILE="$FX/no-such-config"
# shellcheck source=/dev/null
. "$here/lib/registry.sh"

echo "== 1. the register's directory =="
is "1a default sits next to entities.d" "$(registry_mcp_dir)" "$FX/mcp.d"
is "1b STEWARD_MCP_DIR overrides it" \
   "$(STEWARD_MCP_DIR=/tmp/elsewhere registry_mcp_dir)" "/tmp/elsewhere"

echo "== 2. registry_mcp_asset_load: the fields a row carries =="
registry_mcp_asset_load chat-tool >/dev/null 2>&1; rc=$?
is "2a rc 0"                "$rc" "0"
is "2b MCP_ASSET_ID"        "${MCP_ASSET_ID:-}" "chat-tool"
is "2c MCP_COMMAND"         "${MCP_COMMAND:-}" "/opt/chat/server"
is "2d MCP_ARGS is empty"   "${MCP_ARGS:-}" ""
is "2e MCP_ENV_FILE empty"  "${MCP_ENV_FILE:-}" ""

registry_mcp_asset_load mail-tool >/dev/null 2>&1; rc=$?
is "2f rc 0"                "$rc" "0"
is "2g MCP_COMMAND"         "${MCP_COMMAND:-}" "/opt/mail/server"
is "2h MCP_ARGS raw"        "${MCP_ARGS:-}" "--port 7 --quiet"
is "2i MCP_ENV_FILE is the TEMPLATE, unsubstituted here" \
   "${MCP_ENV_FILE:-}" "/etc/steward/env/<domain>/mail-tool.env"

echo "== 3. a refusal leaves NOTHING behind =="
# mail-tool is loaded right now. A failing load must not leave a caller
# reading the previous asset's command as this one's — the same leak-guard
# every loader in lib/registry.sh carries.
# THE LOAD RUNS IN THIS SHELL, stderr to a file — a command substitution
# would run it in a subshell, where the reset it is being tested for could
# not possibly be observed.
registry_mcp_asset_load no-such-tool 2>"$FX/e3" >/dev/null; rc=$?
err="$(cat "$FX/e3")"
is  "3a rc 1"                     "$rc" "1"
has "3b names the missing slug"   "$err" "no-such-tool"
is  "3c MCP_COMMAND was reset"    "${MCP_COMMAND:-}" ""
is  "3d MCP_ARGS was reset"       "${MCP_ARGS:-}" ""
is  "3e MCP_ENV_FILE was reset"   "${MCP_ENV_FILE:-}" ""
is  "3f MCP_ASSET_ID was reset"   "${MCP_ASSET_ID:-}" ""

echo "== 4. MCP_COMMAND is required =="
registry_mcp_asset_load no-command 2>"$FX/e4" >/dev/null; rc=$?
err="$(cat "$FX/e4")"
is  "4a rc 1"                       "$rc" "1"
has "4b names the row"              "$err" "no-command"
has "4c names the missing field"    "$err" "MCP_COMMAND"
is  "4d MCP_ARGS did not survive"   "${MCP_ARGS:-}" ""

echo "== 5. the slug grammar is ^[a-z0-9-]+\$ =="
for badslug in "Chat-Tool" "chat_tool" "chat.tool" "../escape" "chat/tool" ""; do
  ( registry_mcp_asset_load "$badslug" ) >/dev/null 2>&1
  is "5: refuses '$badslug'" "$?" "1"
done

echo "== 6. MCP_ASSETS is legal on an entity and on a project row =="
registry_entity_load acme >/dev/null 2>&1
is "6a ENTITY_MCP_ASSETS"            "${ENTITY_MCP_ASSETS:-}" "chat-tool"
registry_entity_load beta >/dev/null 2>&1
is "6b ENTITY_MCP_ASSETS, two slugs" "${ENTITY_MCP_ASSETS:-}" "mail-tool chat-tool"
registry_entity_load quiet >/dev/null 2>&1
is "6c an entity without the field reads empty, not stale" "${ENTITY_MCP_ASSETS:-}" ""
registry_project_load gamma >/dev/null 2>&1
is "6d PROJECT_MCP_ASSETS"           "${PROJECT_MCP_ASSETS:-}" "notes-tool mail-tool"

echo "== 7. the resolver: team, then entity, then project — deduped =="
# THE ORDER IS THE INHERITANCE. The managing team grants first, the owning
# entity second, the project last: a reader of the effective set sees the
# broadest grant before the narrowest, and the render below keys its JSON
# object in exactly this order.
out="$(registry_session_mcp_assets s-project 2>/dev/null)"; rc=$?
is "7a rc 0" "$rc" "0"
is "7b acme's, then beta's new one, then gamma's new one — each once" \
   "$out" "$(printf 'chat-tool\nmail-tool\nnotes-tool')"

echo "== 8. a session aimed at an entity has no project level =="
out="$(registry_session_mcp_assets s-entity 2>/dev/null)"
is "8 the team's grant, then the client's own" \
   "$out" "$(printf 'chat-tool\nmail-tool')"

echo "== 9. a legacy row resolves through DOMAIN, and a root team has no manager =="
out="$(registry_session_mcp_assets s-legacy 2>/dev/null)"
is "9 acme's own grant only" "$out" "chat-tool"

echo "== 10. a level that grants nothing says nothing =="
out="$(registry_session_mcp_assets s-quiet 2>"$FX/e10")"; rc=$?
is "10a rc 0"                    "$rc" "0"
is "10b the set is empty"        "$out" ""
is "10c and stderr is SILENT — an entity with no grants is not a fault" \
   "$(cat "$FX/e10")" ""

echo "== 11. a level that FAILS to load is named, never silent =="
out="$(registry_session_mcp_assets s-orphan 2>"$FX/e11")"; rc=$?
err="$(cat "$FX/e11")"
is  "11a rc 0 — one broken level is not a broken resolution" "$rc" "0"
is  "11b it contributes nothing"      "$out" ""
has "11c the entity is NAMED"         "$err" "nowhere"
has "11d and so is the session"       "$err" "s-orphan"

echo "== 12. a project row that will not load is named too =="
out="$(registry_session_mcp_assets s-broken 2>"$FX/e12")"; rc=$?
err="$(cat "$FX/e12")"
is  "12a rc 0"                          "$rc" "0"
is  "12b nothing was inherited from it" "$out" ""
has "12c the project is NAMED"          "$err" "delta"
hasnt "12d and its assets never leaked into the set" "$out" "mail-tool"

echo "== 13. a session that will not load is a refusal, not an empty set =="
out="$(registry_session_mcp_assets no-such-session 2>"$FX/e13")"; rc=$?
is  "13a rc is non-zero" "$( [ "$rc" -ne 0 ] && echo yes || echo no )" "yes"
is  "13b nothing on stdout" "$out" ""
has "13c and the session is named" "$(cat "$FX/e13")" "no-such-session"
out="$(registry_session_mcp_assets 2>/dev/null)"; rc=$?
is  "13d no argument at all refuses" "$( [ "$rc" -ne 0 ] && echo yes || echo no )" "yes"

echo "== 14. the split never globs =="
# THE SPLIT IS WANTED; THE GLOB IS NOT — lib/visibility.sh's grant-list
# lesson, in a second field. An MCP_ASSETS carrying an asterisk read from a
# directory holding matching files would inherit whatever happens to be on
# disk next to the caller.
printf 'NAME="Starry"\nMEMBERS="a"\nMCP_ASSETS="* chat-tool"\n' > "$ENT/starry.conf"
sess s-star 'DOMAIN="starry"
RC_LABEL="L"'
mkdir -p "$FX/cwd" && : > "$FX/cwd/chat-tool" && : > "$FX/cwd/mail-tool"
out="$(cd "$FX/cwd" && registry_session_mcp_assets s-star 2>/dev/null)"
is "14 the asterisk stayed an asterisk" "$out" "$(printf '*\nchat-tool')"

echo "== 15. the resolver leaks no globals into its caller =="
# It is asked once per session while a caller is mid-render; a load leaking
# out of it would answer the next question with the previous session's row.
MCP_COMMAND="sentinel"; ENTITY_MCP_ASSETS="sentinel"; PROJECT_MCP_ASSETS="sentinel"
registry_session_mcp_assets s-project >/dev/null 2>&1
is "15a MCP_COMMAND untouched"        "$MCP_COMMAND" "sentinel"
is "15b ENTITY_MCP_ASSETS untouched"  "$ENTITY_MCP_ASSETS" "sentinel"
is "15c PROJECT_MCP_ASSETS untouched" "$PROJECT_MCP_ASSETS" "sentinel"

echo "pass=$pass fail=$fail"
[ "$fail" -eq 0 ]
