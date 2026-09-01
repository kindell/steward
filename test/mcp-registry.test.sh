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
mkdir -p "$FX/estate" "$FX/entities.d" "$FX/projects.d" "$FX/sessions.d" "$FX/mcp.d" "$FX/accounts.d"

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
ACC="$FX/accounts.d"

# ── THE ORG: a team that manages a client that owns a project ──────────────
printf 'NAME="Acme"\nMEMBERS="a"\nMCP_ASSETS="chat-tool"\n'                    > "$ENT/acme.conf"
printf 'NAME="Beta"\nMANAGED_BY="acme"\nMCP_ASSETS="mail-tool chat-tool"\n'    > "$ENT/beta.conf"
printf 'NAME="Gamma"\nPARENT="beta"\nMCP_ASSETS="notes-tool mail-tool"\n'      > "$PROJ/gamma.conf"
# A team that grants nothing: its levels contribute nothing AND say nothing.
printf 'NAME="Quiet"\nMEMBERS="a"\n'                                           > "$ENT/quiet.conf"
# A project whose PARENT names an entity that does not exist: the row will
# not load, and that must be said out loud rather than read as "no assets".
printf 'NAME="Delta"\nPARENT="ghost"\nMCP_ASSETS="mail-tool"\n'                > "$PROJ/delta.conf"

# ── THE ACCOUNTS: personal capability, bound to a HUMAN and not to a node ──
# THE WHOLE ARGUMENT FOR THIS AXIS. Every level above is a place in the org
# chart, and a personal capability has no place there — a mail account, a
# calendar, a note store belong to the person, and two people sitting on the
# SAME client must not inherit each other's. The entity tree cannot express
# that difference: it hands both of them the same set by construction.
printf 'PRINCIPAL="ann"\nHOST="h1"\nMCP_ASSETS="crm-tool"\n'            > "$ACC/ann-h1.conf"
printf 'PRINCIPAL="bo"\nHOST="h1"\nMCP_ASSETS="video-tool"\n'           > "$ACC/bo-h1.conf"
# An account that grants nothing: no field at all, which must read as "none
# declared" and never as the previously loaded account's grant.
printf 'PRINCIPAL="cy"\nHOST="h1"\n'                                     > "$ACC/cy-h1.conf"
# An account that grants what its team already grants — the dedup case.
printf 'PRINCIPAL="di"\nHOST="h1"\nMCP_ASSETS="chat-tool video-tool"\n' > "$ACC/di-h1.conf"

# ── THE REGISTER ───────────────────────────────────────────────────────────
printf 'MCP_COMMAND="/opt/chat/server"\n'                                      > "$MCPD/chat-tool.conf"
cat > "$MCPD/mail-tool.conf" <<'EOF'
MCP_COMMAND="/opt/mail/server"
MCP_ARGS="--port 7 --quiet"
MCP_ENV_FILE="/etc/steward/env/<domain>/mail-tool.env"
EOF
# notes-tool is DELIBERATELY ABSENT — the omission case lives in the render
# suite, and the resolver must still carry the slug through to it.
printf 'MCP_COMMAND="/opt/crm/server"\n'                                       > "$MCPD/crm-tool.conf"
printf 'MCP_COMMAND="/opt/video/server"\n'                                    > "$MCPD/video-tool.conf"
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
# ── THE SESSIONS THAT CARRY AN ACCOUNT ─────────────────────────────────────
# s-ann and s-bo are the whole argument in fixture form: SAME target entity,
# DIFFERENT accounts. Anything that reads them as equal has lost the axis.
sess s-account 'ACCOUNT="ann-h1"
TARGET_PROJECT="gamma"'
sess s-ann     'ACCOUNT="ann-h1"
TARGET_ENTITY="beta"'
sess s-bo      'ACCOUNT="bo-h1"
TARGET_ENTITY="beta"'
sess s-cy      'ACCOUNT="cy-h1"
TARGET_ENTITY="beta"'
sess s-di      'ACCOUNT="di-h1"
TARGET_ENTITY="beta"'
sess s-noaccount 'ACCOUNT="ghost-h1"
TARGET_ENTITY="beta"'
sess s-noaccount-quiet 'ACCOUNT="ghost-h1"
DOMAIN="quiet"
RC_LABEL="L"'

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
is  "11a rc 65 — a level that would not load is a fault a caller can READ, not an empty set" "$rc" "65"
is  "11b it contributes nothing"      "$out" ""
has "11c the entity is NAMED"         "$err" "nowhere"
has "11d and so is the session"       "$err" "s-orphan"

echo "== 12. a project row that will not load is named too =="
out="$(registry_session_mcp_assets s-broken 2>"$FX/e12")"; rc=$?
err="$(cat "$FX/e12")"
is  "12a rc 65 — the project level failed to load"  "$rc" "65"
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
ACCOUNT_MCP_ASSETS="sentinel"; ACCOUNT_PRINCIPAL="sentinel"
registry_session_mcp_assets s-account >/dev/null 2>&1
is "15a MCP_COMMAND untouched"        "$MCP_COMMAND" "sentinel"
is "15b ENTITY_MCP_ASSETS untouched"  "$ENTITY_MCP_ASSETS" "sentinel"
is "15c PROJECT_MCP_ASSETS untouched" "$PROJECT_MCP_ASSETS" "sentinel"
# THE ACCOUNT AXIS RUNS A FOURTH LOADER INSIDE THE SAME SUBSHELL, so it gets
# the same guard: a session resolved mid-render must not leave the next
# question answering out of this session's account row.
is "15d ACCOUNT_MCP_ASSETS untouched" "$ACCOUNT_MCP_ASSETS" "sentinel"
is "15e ACCOUNT_PRINCIPAL untouched"  "$ACCOUNT_PRINCIPAL" "sentinel"

echo "== 16. the owning entity is VALIDATED before anyone splices it into a path =="
# THE HOLE THIS PINS. DOMAIN and TARGET_ENTITY are grammar-checked by
# registry_load, but PROJECT_PARENT is checked by nobody: registry_project_load
# only asks "does this resolve through registry_entity_load", and that loader
# concatenates the id into a filename without a grammar check of its own. So a
# projects.d row carrying PARENT="../projects.d/<other>" resolves — a project
# row has a NAME, so it loads AS AN ENTITY — and the session inherits another
# row's grants. The join is the one place every consumer goes through
# (lib/sessions.sh and lib/visibility.sh run it too), so the check belongs
# INSIDE it rather than at each caller.
printf 'NAME="Other Work"\nPARENT="beta"\nMCP_ASSETS="secret-tool"\n' > "$PROJ/otherwork.conf"
printf 'NAME="Own Work"\nPARENT="../projects.d/otherwork"\nMCP_ASSETS="chat-tool"\n' > "$PROJ/ownwork.conf"
sess s-traverse 'TARGET_PROJECT="ownwork"'
out="$( registry_session_owning_entity s-traverse 2>"$FX/e16" )"; rc=$?
err="$(cat "$FX/e16")"
is  "16a a slug that is a path refuses"  "$( [ "$rc" -ne 0 ] && echo yes || echo no )" "yes"
is  "16b and prints NOTHING on stdout — a caller reading it must get no path" \
    "$out" ""
has "16c the refused value is named"     "$err" "projects.d/otherwork"
has "16d and so is the session"          "$err" "s-traverse"

out="$(registry_session_mcp_assets s-traverse 2>"$FX/e16b")"
hasnt "16e the other row's grant was NOT inherited" "$out" "secret-tool"
is    "16f the project's own grant still stands"    "$out" "chat-tool"
has   "16g and the failure is named, never silent"  "$(cat "$FX/e16b")" "s-traverse"

is "16h a LEGAL owning entity still resolves — the check refuses paths, not work" \
   "$(registry_session_owning_entity s-project 2>/dev/null)" "beta"
is "16i and so does a legacy DOMAIN row" \
   "$(registry_session_owning_entity s-legacy 2>/dev/null)" "acme"

echo "== 17. ONE MANAGED_BY hop, and only one — the grandparent grants nothing =="
# A CUSTOMER OF A CUSTOMER IS NOT THE SAME WORK. Without a three-deep fixture a
# resolver that walked the whole chain would stay green forever, and what it
# would be handing out is the right to run a program with somebody's
# credentials.
printf 'NAME="Top"\nMEMBERS="a"\nMCP_ASSETS="secret-tool"\n'                  > "$ENT/topteam.conf"
printf 'NAME="Middle"\nMANAGED_BY="topteam"\nMCP_ASSETS="chat-tool"\n'        > "$ENT/midteam.conf"
printf 'NAME="Leaf"\nMANAGED_BY="midteam"\nMCP_ASSETS="mail-tool"\n'          > "$ENT/leafclient.conf"
printf 'NAME="Deep"\nPARENT="leafclient"\nMCP_ASSETS="notes-tool"\n'          > "$PROJ/deepwork.conf"
sess s-deep 'TARGET_PROJECT="deepwork"'
out="$(registry_session_mcp_assets s-deep 2>"$FX/e17")"; rc=$?
is    "17a rc 0 — every level loaded"  "$rc" "0"
is    "17b the manager, the client, then the project" \
      "$out" "$(printf 'chat-tool\nmail-tool\nnotes-tool')"
hasnt "17c the GRANDPARENT team's grant is absent — the hop limit holds" \
      "$out" "secret-tool"
is    "17d and a hop limit is not a fault: stderr is silent" "$(cat "$FX/e17")" ""

echo "== 18. an entity whose MANAGED_BY names a missing row =="
# The owning entity itself will not load, so it contributes nothing — and the
# CULPRIT is the manager, not the entity. Naming only the entity sends the
# operator to a file that is sitting right there and is fine.
printf 'NAME="Stray"\nMANAGED_BY="nosuchteam"\nMCP_ASSETS="chat-tool"\n' > "$ENT/stray.conf"
sess s-stray 'DOMAIN="stray"
RC_LABEL="L"'
out="$(registry_session_mcp_assets s-stray 2>"$FX/e18")"; rc=$?
err="$(cat "$FX/e18")"
is  "18a rc 65 — a level that FAILED to load is not an empty set" "$rc" "65"
is  "18b it contributed nothing"                 "$out" ""
has "18c the owning entity is named"             "$err" "stray"
has "18d the ACTUAL culprit is named too"        "$err" "nosuchteam"
has "18e and the session"                        "$err" "s-stray"

echo "== 19. the resolver's rc says WHICH of three things happened =="
# rc 0 — resolved, the set on stdout is the whole grant (empty is a grant of
#        nothing, and an honest answer).
# rc 65 — at least one level would not load: the set on stdout is PARTIAL and
#        must never be read as the whole grant.
# rc 1 — the session's own row would not load: nothing was resolved at all.
# Without the middle one a caller cannot tell a fault from a configuration,
# and one mistyped team name silently strips every capability under it.
printf 'PARENT="beta"\nMCP_ASSETS="secret-tool"\n' > "$PROJ/nameless.conf"
sess s-partial 'DOMAIN="beta"
TARGET_PROJECT="nameless"
RC_LABEL="L"'
out="$(registry_session_mcp_assets s-partial 2>"$FX/e19")"; rc=$?
err="$(cat "$FX/e19")"
is    "19a rc 65 — the project level failed"  "$rc" "65"
is    "19b the levels that DID load are still on stdout" \
      "$out" "$(printf 'chat-tool\nmail-tool')"
hasnt "19c the failed level granted nothing"  "$out" "secret-tool"
has   "19d and it is named"                   "$err" "nameless"
out="$(registry_session_mcp_assets s-quiet 2>/dev/null)"; rc=$?
is    "19e a clean resolution is still rc 0, even when it resolves to nothing" "$rc" "0"

echo "== 20. the schema max covers the mcp register and MCP_ASSETS =="
# The number is a promise about what the CODE can read. mcp.d and the
# MCP_ASSETS field are new readable surface, so the promise moved.
is "20a REGISTRY_SCHEMA_MAX is at least 5" \
   "$( [ "${REGISTRY_SCHEMA_MAX:-0}" -ge 5 ] && echo yes || echo no )" "yes"
mkdir -p "$FX/s5/estate" "$FX/s6/estate"
for v in 5 6; do
  { cat "$FX/estate/steward.conf"; printf 'SCHEMA_VERSION="%s"\n' "$v"; } > "$FX/s$v/estate/steward.conf"
done
( STEWARD_ESTATE_ROOT="$FX/s5" registry_schema_check ) >/dev/null 2>&1
is "20b an estate declaring schema 5 is READ, not refused" "$?" "0"
( STEWARD_ESTATE_ROOT="$FX/s6" registry_schema_check ) >/dev/null 2>&1
is "20c an estate NEWER than the code still refuses with 78" "$?" "78"
# AN ABSENT MCP_ASSETS IS "NO ASSETS DECLARED", read explicitly and not as a
# leftover. This is the compatibility decision the schema comment records: the
# field is additive, an older checkout reads it as absent, and absent grants
# ZERO — fail closed, never open.
ENTITY_MCP_ASSETS="leftover"
registry_entity_load quiet >/dev/null 2>&1
is "20d a row without the field reads empty, never the previous row's grant" \
   "${ENTITY_MCP_ASSETS:-}" ""

echo "== 21. a scaffolded estate has a READABLE mcp register =="
# registry_mcp_list draws the register's own distinction — unreadable is not
# empty — so an estate scaffolded without mcp.d refuses with 78 the first time
# anything asks what capabilities exist.
( bash "$here/bin/steward" scaffold "$FX/fresh" org=fixture team=onlyteam \
    owner=someone session=first ) >/dev/null 2>&1
is "21a the scaffold made mcp.d next to entities.d" \
   "$( [ -d "$FX/fresh/mcp.d" ] && echo yes || echo no )" "yes"
( STEWARD_ESTATE_ROOT="$FX/fresh" registry_mcp_list ) >/dev/null 2>&1
is "21b so the register READS as empty rather than refusing with 78" "$?" "0"

echo "== 22. MCP_ASSETS is a legal field on an accounts.d row =="
# PERSONAL CAPABILITY IS NOT AN ORG NODE. The three levels above all name a
# place in the org chart; a mail account or a note store names a HUMAN, and
# the account register is the one row in this estate that does.
registry_account_load ann-h1 >/dev/null 2>&1; rc=$?
is "22a rc 0"                   "$rc" "0"
is "22b ACCOUNT_MCP_ASSETS"     "${ACCOUNT_MCP_ASSETS:-}" "crm-tool"
is "22c the existing fields still load" "${ACCOUNT_PRINCIPAL:-}" "ann"
registry_account_load di-h1 >/dev/null 2>&1
is "22d two slugs, raw"         "${ACCOUNT_MCP_ASSETS:-}" "chat-tool video-tool"
# ABSENT IS AN ANSWER, NEVER THE PREVIOUS ROW'S GRANT — the same fail-closed
# reading registry_entity_load gives the field, and the reason the schema note
# in lib/registry.sh can call this addition safe for an older checkout.
registry_account_load cy-h1 >/dev/null 2>&1
is "22e a row without the field reads empty, not stale" "${ACCOUNT_MCP_ASSETS:-}" ""
# A FAILING LOAD LEAVES NOTHING BEHIND. Run in THIS shell, not a substitution
# — a subshell could not show the reset the loader is being tested for.
registry_account_load ann-h1 >/dev/null 2>&1
registry_account_load no-such-account 2>"$FX/e22" >/dev/null; rc=$?
is "22f rc 1"                        "$rc" "1"
is "22g ACCOUNT_MCP_ASSETS was reset" "${ACCOUNT_MCP_ASSETS:-}" ""
is "22h and so was PRINCIPAL"         "${ACCOUNT_PRINCIPAL:-}" ""

echo "== 23. the account axis unions with the entity tree, ACCOUNT FIRST =="
# THE ORDER IS DOCUMENTED AND THEREFORE PINNED: account, managing team,
# owning entity, target project. The account leads because it is the grant
# that belongs to whoever is actually sitting at the session; the org tree
# then widens around it, broadest-to-narrowest as before.
out="$(registry_session_mcp_assets s-account 2>"$FX/e23")"; rc=$?
is "23a rc 0"                              "$rc" "0"
is "23b the person's own, then acme's, then beta's, then gamma's" \
   "$out" "$(printf 'crm-tool\nchat-tool\nmail-tool\nnotes-tool')"
is "23c a resolved account is not a fault: stderr is silent" "$(cat "$FX/e23")" ""
# AN ACCOUNT THAT GRANTS NOTHING IS A CONFIGURATION, exactly like a team that
# grants nothing — it contributes nothing AND says nothing.
out="$(registry_session_mcp_assets s-cy 2>"$FX/e23b")"; rc=$?
is "23d rc 0"                              "$rc" "0"
is "23e only the org tree's grant"          "$out" "$(printf 'chat-tool\nmail-tool')"
is "23f and stderr is silent"              "$(cat "$FX/e23b")" ""
# A SESSION WITH NO ACCOUNT FIELD AT ALL is the pre-model row, and an absent
# account is an absence, not a failure.
out="$(registry_session_mcp_assets s-entity 2>"$FX/e23c")"; rc=$?
is "23g rc 0"                              "$rc" "0"
is "23h the set is unchanged from before the axis existed" \
   "$out" "$(printf 'chat-tool\nmail-tool')"
is "23i and nothing is said about the account it does not have" \
   "$(cat "$FX/e23c")" ""

echo "== 24. SAME entity, DIFFERENT accounts — different sets. The whole reason. =="
# WITHOUT THIS ASSERTION THE AXIS IS DECORATION. Both sessions target beta, so
# every org level hands them an identical grant; the ONLY thing that may differ is
# what their own account declares. A resolver that ignored ACCOUNT would keep
# every other test in this file green and still be wrong here.
out_ann="$(registry_session_mcp_assets s-ann 2>/dev/null)"
out_bo="$(registry_session_mcp_assets s-bo 2>/dev/null)"
is    "24a ann gets her own crm-tool on top of the shared org grant" \
      "$out_ann" "$(printf 'crm-tool\nchat-tool\nmail-tool')"
is    "24b bo gets his own video-tool on top of the SAME org grant" \
      "$out_bo" "$(printf 'video-tool\nchat-tool\nmail-tool')"
hasnt "24c and ann never sees bo's"   "$out_ann" "video-tool"
hasnt "24d nor bo ann's"              "$out_bo" "crm-tool"

echo "== 25. dedup spans the account axis too, first-seen wins =="
# The same asset granted by a person's account and again by the team above
# them is ONE server. Rendered twice it is a duplicate key in the document,
# where the last writer silently wins and nobody can say which entry ran.
out="$(registry_session_mcp_assets s-di 2>/dev/null)"; rc=$?
is "25a rc 0" "$rc" "0"
is "25b chat-tool appears ONCE, at the account level that named it first" \
   "$out" "$(printf 'chat-tool\nvideo-tool\nmail-tool')"
is "25c counted rather than eyeballed" \
   "$(printf '%s\n' "$out" | grep -c '^chat-tool$')" "1"

echo "== 26. an ACCOUNT naming a missing row is rc 65, NAMED, never a silent drop =="
# THE FAULT THIS SECTION EXISTS FOR. An account row that is missing or
# unreadable would otherwise contribute an empty string, and the person's
# entire personal set would vanish into an rc 0 that reads "nobody granted you
# anything" — the identical trap the org levels already close. A machine reads
# the rc, and rc 0 tells a spawner to start the session as if that were the
# whole grant.
out="$(registry_session_mcp_assets s-noaccount 2>"$FX/e26")"; rc=$?
err="$(cat "$FX/e26")"
is  "26a rc 65 — a fault, not a configuration" "$rc" "65"
has "26b the account is NAMED"                 "$err" "ghost-h1"
has "26c and so is the session"                "$err" "s-noaccount"
is  "26d the levels that DID load are still on stdout, flagged as partial" \
    "$out" "$(printf 'chat-tool\nmail-tool')"
# And when the org tree grants nothing either, the empty set must STILL not
# read as rc 0 — that is exactly the silent drop being refused.
out="$(registry_session_mcp_assets s-noaccount-quiet 2>"$FX/e26b")"; rc=$?
is  "26e rc 65 even though the set is empty" "$rc" "65"
is  "26f nothing was inherited"              "$out" ""
has "26g the account is still named"         "$(cat "$FX/e26b")" "ghost-h1"

echo "== 27. the ACCOUNT slug is a NAME before it is ever spliced into a path =="
# accounts.d sits next to entities.d, so an ACCOUNT that is a path reaches
# another register the moment it is concatenated into a filename — the exact
# escape a projects.d PARENT achieved through the entity join. Two gates stand
# in front of it and BOTH are pinned: registry_load refuses the shape on the
# way in, and the resolver asserts registry_valid_name before the splice.
printf 'PRINCIPAL="ee"\nHOST="h1"\nMCP_ASSETS="video-tool"\n' > "$ACC/elsewhere.conf"
sess s-acct-traverse 'ACCOUNT="../accounts.d/elsewhere"
TARGET_ENTITY="beta"'
out="$(registry_session_mcp_assets s-acct-traverse 2>"$FX/e27")"; rc=$?
err="$(cat "$FX/e27")"
is    "27a a path-shaped ACCOUNT never resolves" \
      "$( [ "$rc" -ne 0 ] && echo yes || echo no )" "yes"
hasnt "27b and the row that path named granted nothing" "$out" "video-tool"
is    "27c the refusal is said out loud" \
      "$( [ -s "$FX/e27" ] && echo yes || echo no )" "yes"
# A LEGAL ACCOUNT STILL RESOLVES — the gate refuses paths, not people.
is "27d" "$(registry_session_mcp_assets s-ann 2>/dev/null | head -1)" "crm-tool"

echo "pass=$pass fail=$fail"
[ "$fail" -eq 0 ]
