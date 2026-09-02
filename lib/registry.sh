#!/bin/bash
# Sourced library. Single source of truth for the session registry layout.
# No side effects on source. Honors STEWARD_REGISTRY_DIR for testing.

# ---------------------------------------------------------------------------
# THE LABEL PREFIX: WHERE it lives, not WHAT it is.
#
# Every launchd label this layer operates shares the prefix. Changing its NAME
# forces the installer to boot out and bootstrap every live daemon — do that only
# at a moment when losing the live conversations is acceptable. The VALUE has not
# changed since it was introduced; what moved is where it comes from. A library
# meant to be published must not carry its owner's namespace hardcoded.
#
# NO DEFAULT, NO SILENT FALLBACK. Two ways of FAILING the lookup do exactly the
# same damage as a rename, without anybody having renamed anything:
#
#   1. An EMPTY prefix. The pruning glob in the installer is
#      "$LD/$PREFIX".*.plist and then degenerates to "$LD/".*.plist.
#      MEASURED, not assumed: it does NOT match the whole directory the way one
#      first reads it — the dot becomes literal, so it matches every HIDDEN plist
#      in the daemon directory. The installer would have booted out and deleted
#      units that never belonged to our namespace, and the prefix-stripping
#      expression would have derived the wrong project name for them. Less damage
#      than it first appears, and still somebody else's.
#   2. A DIFFERENT value. The live daemons become invisible to the tool: they run
#      on unsupervised while the installer bootstraps duplicates under the new
#      name.
#
# So the lookup refuses with rc 78 (EX_CONFIG) and says what is missing and where
# it belongs, instead of guessing. An empty prefix must never leave this
# function.

# The directory the library itself sits in, symlink-safe.
#
# ${BASH_SOURCE[0]} is the SYMLINK's path, not the target's, when this file is
# reached through a link. No `readlink -f` — it does not exist on the older bash
# and coreutils this must run on — so the link is resolved by hand, one step at a
# time. Not a new invention: the same loop in two places is cheaper to trust than
# two different ones.
_registry_self_dir() {
  local self link
  self="${BASH_SOURCE[0]}"
  while [ -L "$self" ]; do
    link="$(readlink "$self")"
    case "$link" in
      /*) self="$link" ;;
      *)  self="$(dirname "$self")/$link" ;;
    esac
  done
  CDPATH= cd -- "$(dirname "$self")" && pwd
}

# _registry_estate_root — WHERE THE ESTATE'S DATA LIVES.
#
# ONE ROOT, NOT ONE OVERRIDE PER DIRECTORY. Everything the estate owns — the
# conf, the session registry, the host registry — sat resolved relative to THE
# LIBRARY. That held for as long as the library and the data shared a root, which
# is true in the deployed image and false the moment the library lives in the
# product's checkout and the data in the estate's.
#
# Patching one directory at a time is how a resolution becomes four resolutions
# that disagree. Measured 2026-08-20: the estate path was fixed first, and the
# session registry then pointed into the product's tree and reported every
# session as unrenderable — a gate that could not be measured, which is worse
# than a red gate because it reads as a broken machine rather than a broken path.
#
# STEWARD_ESTATE_ROOT names the root. The narrower overrides (STEWARD_ESTATE,
# STEWARD_REGISTRY_DIR) still win where they are set, because a test that wants
# one fixture directory should not have to build a whole estate around it.
_registry_estate_root() {
  if [ -n "${STEWARD_ESTATE_ROOT:-}" ]; then printf '%s' "$STEWARD_ESTATE_ROOT"; return 0; fi
  printf '%s' "$(_registry_self_dir)/.."
}

# registry_estate_file: the path to the estate file.
#
# THIS FUNCTION IS THE INTENDED REPLACEMENT SITE. A general estate resolution is
# a later step; when it exists, this body is what changes, and no other line needs
# to know where the estate lives. The path is computed relative to THE LIBRARY's
# own location — not cwd, not $HOME — so it holds both from a checkout and from
# the deployed image (~/scripts/lib/registry.sh -> ~/scripts/estate/steward.conf).
registry_estate_file() {
  # STEWARD_ESTATE IS THAT REPLACEMENT, AND IT IS NOW NEEDED. Resolving relative
  # to the library holds in the deployed image, where the library and the estate
  # land side by side under the same root. It does NOT hold once the library
  # lives in the product's checkout and the estate in its own: the library would
  # look for an estate directory next to itself and find nothing.
  #
  # A full PATH, not a directory: the file is the unit an estate hands over, and
  # a directory would leave the file name as one more thing to agree on.
  if [ -n "${STEWARD_ESTATE:-}" ]; then
    printf '%s\n' "$STEWARD_ESTATE"
    return 0
  fi
  printf '%s\n' "$(_registry_estate_root)/estate/steward.conf"
}

# registry_label_prefix: print the prefix, or REFUSE with rc 78.
registry_label_prefix() {
  local estate; estate="$(registry_estate_file)"
  if [ ! -f "$estate" ]; then
    echo "registry: REFUSING — the estate file is missing: $estate" >&2
    echo "registry: it must contain the line LABEL_PREFIX=\"com.<org>.claude\"." >&2
    echo "registry: the prefix names every installed daemon and is never guessed." >&2
    return 78
  fi
  # local BEFORE source: the estate file must not leak LABEL_PREFIX to the
  # caller, and a previously set global must not survive an empty line in it.
  local LABEL_PREFIX=""
  # shellcheck source=/dev/null
  if ! source "$estate"; then
    echo "registry: REFUSING — the estate file could not be read: $estate" >&2
    return 78
  fi
  # The form requirement closes both failure modes in a single line: empty does
  # not match, and a value carrying a slash, whitespace or a glob character can
  # never become a glob that wanders outside its own namespace.
  if ! [[ "$LABEL_PREFIX" =~ ^[A-Za-z0-9][A-Za-z0-9.-]*$ ]]; then
    echo "registry: REFUSING — LABEL_PREFIX missing or invalid in $estate" >&2
    echo "registry: got '${LABEL_PREFIX}', expected the form com.<org>.claude" >&2
    echo "registry: an empty prefix would turn the pruning glob into '<daemondir>/.*.plist'" >&2
    echo "registry: — which matches hidden plists that never belonged to the namespace." >&2
    return 78
  fi
  printf '%s\n' "$LABEL_PREFIX"
}

# registry_estate_name: print the estate's own name, or REFUSE with rc 78.
#
# THE ESTATE HAD NO NAME. Its identity was spread across four keys with two
# values — the daemon prefix said one thing, the hub session and host said
# another, and the job prefix a third. Nothing could be derived from it, which
# is why the advisory session had no name the product could construct.
#
# NEVER GUESSED FROM A NEIGHBOUR. The hub session and the hub host happen to
# carry the same string in the estate this was written for; a product that
# assumes they always do breaks the first time someone names their machine
# after the room it stands in and their session after what it does.
registry_estate_name() {
  local estate; estate="$(registry_estate_file)"
  if [ ! -f "$estate" ]; then
    echo "registry: REFUSING — the estate file is missing: $estate" >&2
    echo "registry: it must contain the line ESTATE_NAME=\"<name>\"." >&2
    return 78
  fi
  local ESTATE_NAME=""
  # shellcheck source=/dev/null
  if ! source "$estate"; then
    echo "registry: REFUSING — the estate file could not be read: $estate" >&2
    return 78
  fi
  # Lower-case, digits and hyphen. The name is rendered into derived session
  # names, so anything that could act as a path separator or a glob is refused
  # at the source rather than escaped at every use.
  if ! [[ "$ESTATE_NAME" =~ ^[a-z][a-z0-9-]*$ ]]; then
    echo "registry: REFUSING — ESTATE_NAME missing or invalid in $estate" >&2
    echo "registry: got '${ESTATE_NAME}', expected lower-case a-z 0-9 and hyphen" >&2
    return 78
  fi
  printf '%s\n' "$ESTATE_NAME"
}

# REGISTRY_SCHEMA_MAX — the newest register schema this checkout understands.
# Bump it in the same commit that teaches the library a new field, never before:
# the number is a promise about what the code can read, not a label on what the
# estate happens to contain.
# 4 (2026-08-30): the identity fields — ACCOUNT, SLUG, TARGET_ENTITY,
# TARGET_PROJECT — became readable in registry_load, and a session conf may
# carry a target reference in place of an RC_LABEL line.
# 5 (2026-09-01): the mcp register (mcp.d, one row per capability) and the
# MCP_ASSETS field on an entities.d, a projects.d and an accounts.d row — the
# last of these being the ACCOUNT axis, a grant bound to a human rather than
# to a node in the org.
#
# NO ESTATE BUMP CAME WITH 5, AND THAT IS THE DECISION, NOT AN OVERSIGHT.
# The number above is a promise about what this CODE can read; the estate's own
# SCHEMA_VERSION is a demand about what a reader must understand before it may
# read at all. Raising the estate's number would make every host still running
# an older checkout refuse the whole register — every session on it — the day
# one MCP_ASSETS line was written. That is an outage bought to protect against
# a degradation that is already safe:
#
#   AN OLDER READER FINDS MCP_ASSETS ABSENT, AND ABSENT IS AN ANSWER — "no
#   assets declared", read explicitly (registry_entity_load and
#   registry_project_load both clear the field before sourcing and copy it out
#   by name, so absent can never come back as the previous row's grant). The
#   session is handed ZERO capabilities. A capability field may only ever
#   degrade in that direction: fewer tools than granted is a session that says
#   a server is missing, MORE tools than granted is somebody else's
#   credentials. Fail closed, never open.
#
# So the estate stays at its current number and old readers grant nothing. The
# day a field lands that an old reader would MISREAD rather than miss — one
# that changes what an existing key means — the estate's number moves with it
# and the refusal above is the right answer.
REGISTRY_SCHEMA_MAX=5

# registry_schema_check: rc 0 if this checkout understands the estate's schema,
# rc 78 if the estate is NEWER than the code reading it.
#
# WHY IT REFUSES RATHER THAN DEGRADES. A checkout that is behind reads a
# register carrying fields it does not know and treats them as absent — and
# absent means something specific here: no rig wanted, no lifecycle, no kind. It
# would act confidently on a half-understood truth, which is worse than stopping.
#
# AN ABSENT VERSION IS 1. Every estate that exists when this lands predates the
# key. Refusing them would make the guard's first act an outage — but a
# MALFORMED version is not 1: a typo must not be quietly read as the oldest
# schema by the very gate that exists to stop half-understood estates.
registry_schema_check() {
  local estate; estate="$(registry_estate_file)"
  [ -f "$estate" ] || return 0
  # Every OTHER key the estate file may define is cleared locally too, for the
  # same reason _registry_estate_value below clears its thirteen: this is the
  # FIRST line of registry_load, so a leak here reaches every caller's shell —
  # every session on the machine — not just this function's own callers.
  local SCHEMA_VERSION="" LABEL_PREFIX="" ESTATE_NAME="" AGENT_INSTRUCTIONS="" \
        RC_LABEL_PREFIX="" HUB_SESSION="" HUB_HOST="" JOB_LOG_DIR="" HUB_SSH="" \
        TMUX_SOCKET="" PING_MSG="" JOB_LABEL_PREFIX="" SERVICE_LABEL_PREFIX="" \
        BROWSER_LABEL_PREFIX="" OP_TOKEN_FILE_NAME="" STATE_DIR_NAME="" PAUSED_DIR_NAME=""
  # shellcheck source=/dev/null
  source "$estate" 2>/dev/null || return 0
  [ -n "$SCHEMA_VERSION" ] || return 0
  if ! [[ "$SCHEMA_VERSION" =~ ^[0-9]+$ ]]; then
    echo "registry: REFUSING — SCHEMA_VERSION in $estate is not a number: '$SCHEMA_VERSION'" >&2
    return 78
  fi
  if [ "$SCHEMA_VERSION" -gt "$REGISTRY_SCHEMA_MAX" ]; then
    echo "registry: REFUSING — the estate is schema $SCHEMA_VERSION, this checkout reads up to $REGISTRY_SCHEMA_MAX." >&2
    echo "registry: pull the product before reading this register; do not guess at fields you cannot see." >&2
    return 78
  fi
  return 0
}

# ── ENTITIES: ONE NODE TYPE, TWO RELATIONS ─────────────────────────────────
#
# A team and a client are NOT two types. The register that came before this
# proved it three independent times: projects hang under both, sessions sit
# under both, and hosts are owned by both. Two types would have forced every
# edge to be written twice.
#
# So there is one node — an entity — and the difference is the RELATION:
#   MEMBERS     the people who belong to it   -> it functions as a team
#   MANAGED_BY  the team that manages it      -> it functions as a client
#
# BOTH AT ONCE IS LEGAL, AND DELIBERATELY SO. The day a client has its own people
# with their own sessions, it gets members. No new type, no migration.
registry_entity_dir() {
  if [ -n "${STEWARD_ENTITY_DIR:-}" ]; then printf '%s\n' "$STEWARD_ENTITY_DIR"; return 0; fi
  printf '%s\n' "$(_registry_estate_root)/entities.d"
}

# registry_entity_list: one id per line, or REFUSE with 78.
# A register that cannot be READ must never look like a register that is EMPTY:
# empty means "no entities exist", which is a claim, and an unreadable directory
# supports no claim at all.
registry_entity_list() {
  local d; d="$(registry_entity_dir)" || return 78
  if [ ! -d "$d" ]; then
    echo "registry: REFUSING — the entity register is not readable: $d" >&2
    return 78
  fi
  local f
  for f in "$d"/*.conf; do
    [ -e "$f" ] || continue
    basename "$f" .conf
  done
}

# registry_entity_load <id>: set ENTITY_ID, ENTITY_NAME, ENTITY_MEMBERS,
# ENTITY_MANAGED_BY, ENTITY_MCP_ASSETS. rc 1 on an invalid row.
registry_entity_load() {
  # Reset before sourcing so a prior load never leaks into this one — a caller
  # that gets rc 1 for a missing or invalid entity must not still see the last
  # entity that loaded successfully.
  ENTITY_ID=""; ENTITY_NAME=""; ENTITY_MEMBERS=""; ENTITY_MANAGED_BY=""; ENTITY_MCP_ASSETS=""
  local id="${1:-}" d f
  [ -n "$id" ] || return 1
  d="$(registry_entity_dir)" || return 78
  f="$d/$id.conf"
  [ -f "$f" ] || { echo "registry: no such entity: $id" >&2; return 1; }
  local NAME="" MEMBERS="" MANAGED_BY="" MCP_ASSETS=""
  # shellcheck source=/dev/null
  source "$f" || return 1
  if [ -z "$NAME" ]; then
    echo "registry: $id.conf missing NAME (the display name a human reads)" >&2
    return 1
  fi
  # A RELATION POINTING AT NOTHING IS WORSE THAN NO RELATION: it reads as
  # structure and carries none. THE MANAGER IS RESOLVED THROUGH THE ENTITY
  # LOADER, not by looking for a file — the same distinction
  # registry_project_load makes for PARENT below: the check is "does this
  # resolve", not "is there something with that name". A file test alone
  # accepted a MANAGED_BY pointing at a row with no NAME, which is not a row
  # that resolves.
  if [ -n "$MANAGED_BY" ]; then
    # A CHAIN, NOT JUST A SELF-CHECK. MANAGED_BY="$id" is the one-step case of
    # a cycle, but a two-step cycle (a managed by b, b managed by a) recurses
    # through this same function forever without a general guard — the
    # subshell below hides ENTITY_* from this caller but does not, on its
    # own, make the recursion bottom out. The chain of ids visited on the way
    # here is carried through the environment because each hop is a fresh
    # subshell invocation of this function, not a nested call in one shell.
    local _chain="${_REGISTRY_MANAGED_BY_CHAIN:- }$id "
    case "$_chain" in
      *" $MANAGED_BY "*)
        echo "registry: $id.conf MANAGED_BY forms a cycle at: $MANAGED_BY" >&2
        return 1
        ;;
    esac
    # SUBSHELL: registry_project_load already does this for PARENT, for the
    # same reason — a recursive load must not overwrite the caller's own
    # ENTITY_* globals with the manager's.
    if ! ( export _REGISTRY_MANAGED_BY_CHAIN="$_chain"
           registry_entity_load "$MANAGED_BY" >/dev/null 2>&1 ); then
      echo "registry: $id.conf MANAGED_BY does not resolve to a valid entity: $MANAGED_BY" >&2
      return 1
    fi
  fi
  ENTITY_ID="$id"; ENTITY_NAME="$NAME"
  ENTITY_MEMBERS="$MEMBERS"; ENTITY_MANAGED_BY="$MANAGED_BY"
  # MCP_ASSETS: which MCP capabilities this entity grants to the sessions under
  # it. EXPOSED, NOT RESOLVED — the slugs index the mcp register, and whether
  # each one has a definition is registry_mcp_asset_load's question, asked at
  # the moment of use. Resolving here would make one unwritten asset row refuse
  # the whole entity, and with it every session that hangs off it.
  ENTITY_MCP_ASSETS="$MCP_ASSETS"
}

# ── PROJECTS: THE WORK, UNDER WHICHEVER PARENT IT BELONGS TO ───────────────
#
# ENTITY answers WHO the work is for. PROJECT answers WHICH BOUNDED WORK. A
# client can have several projects with different repos, participants,
# credentials, deploy targets and lifecycles — aim a session at the client and
# the overbroad grouping this model replaces comes straight back.
#
# OWN WORK VERSUS CLIENT WORK IS THE EDGE, NOT A LABEL. A project hanging
# directly under a team is the team's own; one hanging under a client is client
# work. A field repeating that distinction could only ever contradict the edge.
registry_project_dir() {
  if [ -n "${STEWARD_PROJECT_DIR:-}" ]; then printf '%s\n' "$STEWARD_PROJECT_DIR"; return 0; fi
  printf '%s\n' "$(_registry_estate_root)/projects.d"
}

# registry_project_list: one id per line, or REFUSE with 78.
registry_project_list() {
  local d; d="$(registry_project_dir)" || return 78
  if [ ! -d "$d" ]; then
    echo "registry: REFUSING — the project register is not readable: $d" >&2
    return 78
  fi
  local f
  for f in "$d"/*.conf; do
    [ -e "$f" ] || continue
    basename "$f" .conf
  done
}

# registry_project_load <id>: set PROJECT_ID, PROJECT_NAME, PROJECT_PARENT,
# PROJECT_MCP_ASSETS. rc 1 on an invalid row.
registry_project_load() {
  # Reset before the file lookup — not just before sourcing — so a caller
  # that gets rc 1 never still sees the previous project's data.
  PROJECT_ID=""; PROJECT_NAME=""; PROJECT_PARENT=""; PROJECT_MCP_ASSETS=""
  local id="${1:-}" d f
  [ -n "$id" ] || return 1
  d="$(registry_project_dir)" || return 78
  f="$d/$id.conf"
  [ -f "$f" ] || { echo "registry: no such project: $id" >&2; return 1; }
  local NAME="" PARENT="" MCP_ASSETS=""
  # shellcheck source=/dev/null
  source "$f" || return 1
  [ -n "$NAME" ]   || { echo "registry: $id.conf missing NAME" >&2; return 1; }
  [ -n "$PARENT" ] || { echo "registry: $id.conf missing PARENT (a project always hangs under an entity)" >&2; return 1; }
  # THE PARENT IS RESOLVED THROUGH THE ENTITY LOADER, not by looking for a file.
  # A parent whose own row is invalid must not silently count as present — the
  # check is "does this resolve", not "is there something with that name".
  if ! ( registry_entity_load "$PARENT" >/dev/null 2>&1 ); then
    echo "registry: $id.conf PARENT does not resolve to a valid entity: $PARENT" >&2
    return 1
  fi
  PROJECT_ID="$id"; PROJECT_NAME="$NAME"; PROJECT_PARENT="$PARENT"
  # MCP_ASSETS — the same field an entity may carry, on the narrowest level of
  # the org. Exposed and never resolved here, for the reason spelled out in
  # registry_entity_load above.
  PROJECT_MCP_ASSETS="$MCP_ASSETS"
}

# ── THE MCP REGISTER: A CAPABILITY IS A ROW, NOT A COPY ────────────────────
#
# An MCP server is something a session is GIVEN, and the estate already
# records who a session belongs to: the team that manages the client, the
# client itself, the project the work sits in. Before this register the
# server's command line was repeated into every session that wanted it, and
# a repeated command line is a command line that drifts — the estate had the
# same server declared three ways, and nobody could say which was current.
#
# ONE ROW PER CAPABILITY, REFERENCED FROM THE LEVEL THAT OWNS IT. mcp.d holds
# the definition; entities.d and projects.d rows carry MCP_ASSETS naming it.
# A session's effective set is then DERIVED (registry_session_mcp_assets
# below) rather than stored, which is the same choice the identity model made
# for the display name and for the same reason: a stored copy of a derivable
# fact is a second truth waiting to disagree with the first.
#
# THE ENV FILE IS A PATH, NEVER A VALUE. MCP_ENV_FILE names a file the
# wrapper reads; the secrets inside it never reach a command line, a rendered
# config, a process listing or a log. It is a TEMPLATE — it may contain
# `<domain>`, substituted at render time — so ONE row serves every client
# that has its own copy of the same credential.
#
# ESTATE-GLOBAL, next to entities.d, the same placement accounts.d has.
registry_mcp_dir() {
  if [ -n "${STEWARD_MCP_DIR:-}" ]; then printf '%s\n' "$STEWARD_MCP_DIR"; return 0; fi
  printf '%s\n' "$(_registry_estate_root)/mcp.d"
}

# registry_mcp_list: one asset slug per line, or REFUSE with 78 — the same
# distinction registry_entity_list draws, for the same reason: a register that
# cannot be READ must never look like a register that is EMPTY.
registry_mcp_list() {
  local d; d="$(registry_mcp_dir)" || return 78
  if [ ! -d "$d" ]; then
    echo "registry: REFUSING — the mcp register is not readable: $d" >&2
    return 78
  fi
  local f
  for f in "$d"/*.conf; do
    [ -e "$f" ] || continue
    basename "$f" .conf
  done
}

# registry_mcp_asset_load <slug>: set MCP_ASSET_ID, MCP_COMMAND, MCP_ARGS,
# MCP_ENV_FILE. rc 1 on a missing or invalid row.
#
# THE FIELD NAMES AND THE GLOBAL NAMES ARE THE SAME HERE, which every other
# loader in this file avoids by shadowing the conf's names with locals. They
# cannot be shadowed when they are identical, so the ATOMICITY that shadowing
# buys is bought a different way: the sourced values are copied into locals,
# the globals are cleared AGAIN, and only a row that passes every check gets
# to set them. A refusal therefore leaves nothing behind — the property that
# matters, since this loader is asked once per asset in a loop and a leak
# would render one asset's command under the next asset's name.
#
# THE SLUG IS VALIDATED BEFORE IT IS USED AS A PATH, not after: it is
# concatenated into a filename, so `../something` reaches outside the register
# the moment the grammar is trusted. Same shape every other register here
# uses (^[a-z0-9-]+$, registry_valid_name's own).
registry_mcp_asset_load() {
  MCP_ASSET_ID=""; MCP_COMMAND=""; MCP_ARGS=""; MCP_ENV_FILE=""
  local slug="${1:-}" d f
  [ -n "$slug" ] || return 1
  if ! registry_valid_name "$slug"; then
    # NAMED THROUGH registry_printable: this is the one diagnostic that prints
    # a value the grammar has already rejected, so it is the one that can be
    # handed a carriage return — and a raw CR here returns the cursor and lets
    # the rest of the sentence overwrite the slug it was naming.
    echo "registry: invalid mcp asset name '$(registry_printable "$slug")' (allowed: a-z 0-9 -)" >&2
    return 1
  fi
  d="$(registry_mcp_dir)" || return 78
  f="$d/$slug.conf"
  [ -f "$f" ] || { echo "registry: no such mcp asset: $slug" >&2; return 1; }
  # shellcheck source=/dev/null
  source "$f" || return 1
  local _cmd="${MCP_COMMAND:-}" _args="${MCP_ARGS:-}" _envf="${MCP_ENV_FILE:-}"
  MCP_ASSET_ID=""; MCP_COMMAND=""; MCP_ARGS=""; MCP_ENV_FILE=""
  if [ -z "$_cmd" ]; then
    echo "registry: $slug.conf missing MCP_COMMAND (the program that speaks MCP)" >&2
    return 1
  fi
  MCP_ASSET_ID="$slug"; MCP_COMMAND="$_cmd"; MCP_ARGS="$_args"; MCP_ENV_FILE="$_envf"
}

# _registry_words <string> — sets the array REGISTRY_WORDS to the string's
# space-separated words.
#
# THE SPLIT IS WANTED; THE GLOB IS NOT. This is lib/visibility.sh's grant-list
# lesson, moved into a function so the two fields that need it (MCP_ASSETS and
# MCP_ARGS) share one implementation rather than two that drift. An unquoted
# expansion is word splitting AND pathname expansion, so the same conf answers
# differently from different working directories — measured there with
# VISIBLE_TO="*", where an asterisk became a real group name and let a
# non-member in. An MCP_ARGS="*" would do the same to a server's argv.
#
# THE FLAG IS RESTORED ONLY IF THE CALLER DID NOT ALREADY SET IT, and the
# capture is ONE line under it — a loop that returned from inside itself would
# skip the restore and leave globbing off in the caller's shell.
_registry_words() {
  local _had_f; case "$-" in *f*) _had_f=1 ;; *) _had_f="" ;; esac
  set -f
  # shellcheck disable=SC2206  # splitting is intended here; globbing is off
  REGISTRY_WORDS=( ${1:-} )
  [ -n "$_had_f" ] || set +f
}

# registry_printable <string> — the string with every control byte replaced by
# `?`, for NAMING a rejected value in a diagnostic and never for using one.
#
# A REFUSAL MUST NOT BE STEERED BY WHAT IT REFUSES. The values named below come
# from a conf, and a conf saved with CRLF line endings carries a carriage
# return inside a slug: printed raw, it returns the cursor and the rest of the
# sentence overwrites the part that named the culprit, so the operator reads a
# message that no longer says what went wrong. A newline is worse — one value
# becomes two apparent lines of output. Pure parameter expansion, so it costs
# no process and behaves the same under every locale (a multibyte character is
# not a control byte and survives untouched).
registry_printable() {
  local _s="${1:-}"
  printf '%s' "${_s//[[:cntrl:]]/?}"
}

# registry_session_owning_entity <session-id> — prints the entity slug that
# OWNS the session's work, or rc 1 and nothing.
#
# THE JOIN IS lib/sessions.sh's, AND IT IS ONE JOIN. That file's entity-join
# and lib/visibility.sh's rule 4 already answer this question in the same
# order — the declared target first, the project's PARENT second, the legacy
# DOMAIN last — because a migrated row's DOMAIN can name an entity that never
# existed (measured 2026-08-31: a machine session hidden from the very team
# that owned it). A fourth copy of that order would be a fourth chance to
# drift, so this one is written to be called, and the resolver below calls it.
#
# THE ANSWER IS VALIDATED HERE, BECAUSE HERE IS WHERE THE THREE SOURCES MEET.
# Every consumer splices this slug into a path — `steward mcp render` into a
# credential file, lib/sessions.sh and lib/visibility.sh into a register
# lookup — and only two of the three sources are grammar-checked upstream:
# registry_load checks DOMAIN and TARGET_ENTITY, and NOBODY checks a projects.d
# row's PARENT. registry_project_load asks only "does this resolve through
# registry_entity_load", and that loader concatenates the id into a filename
# without a grammar check of its own. A projects.d row carries a NAME, so it
# loads AS AN ENTITY — which made PARENT="../projects.d/<other>" resolve, and
# a session under it inherited another row's capabilities and rendered against
# another client's credential file (measured 2026-09-01, both).
#
# So the check is here rather than at each caller: one join, one grammar, and a
# fourth consumer added later cannot forget it.
#
# THREE EXIT CODES, because "there is no owning entity" and "the owning entity
# is not a name" are different facts and a caller must be able to tell them
# apart — the first is a session shape, the second is a fault that has to be
# named:
#   rc 0  — the slug is on stdout.
#   rc 1  — no owning entity could be derived at all; nothing on stdout.
#   rc 65 — one was derived and it is NOT a legal slug; nothing on stdout,
#           the value named on stderr.
#
# SUBSHELLED WHOLE: registry_load and registry_project_load both write into
# the shell they run in, and this function's caller is mid-render holding its
# own row.
registry_session_owning_entity() {
  local sid="${1:-}"
  [ -n "$sid" ] || return 1
  (
    registry_load "$sid" >/dev/null 2>&1 || exit 1
    local owning="${DOMAIN:-}"
    if [ -n "${TARGET_ENTITY:-}" ]; then
      owning="$TARGET_ENTITY"
    elif [ -n "${TARGET_PROJECT:-}" ]; then
      local pp
      pp="$( registry_project_load "$TARGET_PROJECT" >/dev/null 2>&1 && printf '%s' "${PROJECT_PARENT:-}" )"
      [ -n "$pp" ] && owning="$pp"
    fi
    [ -n "$owning" ] || exit 1
    # BEFORE IT IS PRINTED, NOT AFTER IT IS USED. The caller has no way to know
    # which of the three sources answered, so it cannot know whether the value
    # was checked; the only place that can is this one.
    if ! registry_valid_name "$owning"; then
      echo "registry: session '$sid' — the owning entity resolves to '$(registry_printable "$owning")', which is not a legal slug (allowed: a-z 0-9 -); refusing to hand it to anything that builds a path" >&2
      exit 65
    fi
    printf '%s\n' "$owning"
  )
}

# registry_session_mcp_assets <session-id> — the session's EFFECTIVE set, one
# asset slug per line on stdout.
#
# THE EXIT CODE SAYS WHICH OF THREE THINGS HAPPENED, and the middle one is the
# reason this is not simply "return the union it managed to build":
#   rc 0  — resolved. The set on stdout is the WHOLE grant; empty means nobody
#           granted anything, which is a configuration and an honest answer.
#   rc 65 — at least one level would not LOAD — the ACCOUNT included. The set
#           on stdout is PARTIAL and must never be read as the whole grant;
#           every failure is named on stderr.
#   rc 1  — the session's own row would not load. Nothing was resolved.
#
# WITHOUT THE MIDDLE ONE A FAULT READS AS A CONFIGURATION. The stderr sentence
# is for a person; the exit code is the part a machine reads, and the machine
# here is whatever spawns the session. One typo in a team name would otherwise
# come back as rc 0 and an empty set — "nobody granted anything" — and every
# session under that client would start with no tools and no signal. That is
# the exact nightmare this register exists to prevent, arriving through the one
# layer the rc contract did not cover.
#
# FOUR LEVELS, IN THIS ORDER: the session's OWNING ACCOUNT, the managing
# team, the owning entity, the target project's own row. The three org levels
# run broadest grant first, narrowest last — a reader of the list, and the
# JSON the render verb keys from it, both see the org from the outside in.
#
# THE ACCOUNT IS AN AXIS, NOT A FOURTH RUNG OF THE SAME LADDER, AND IT LEADS.
# The org levels all answer "where does this work sit"; the account answers
# "who is sitting here". A personal capability — a mail account, a calendar,
# a note store — is bound to a HUMAN and cannot be expressed on an org node
# at all: put it on the client and every colleague on that client inherits
# it, which is not a wider grant, it is somebody else's credentials. Two
# sessions on the SAME entity under DIFFERENT accounts must therefore differ,
# and that difference is the whole reason this level exists.
#
# IT LEADS BECAUSE IT IS THE GRANT THAT BELONGS TO WHOEVER IS ACTUALLY AT THE
# SESSION, and the org then widens around it. The order is fixed and
# documented rather than incidental: dedup keeps FIRST-SEEN, so the order
# decides which level a shared asset is attributed to, and the render verb
# keys its JSON object straight off this list.
#
# THE ACCOUNT SLUG IS ASSERTED AS A NAME BEFORE IT IS SPLICED. registry_load
# already refuses a malformed ACCOUNT on the way in, so this is a second gate
# and not the only one — deliberately, because accounts.d sits next to
# entities.d and the slug is concatenated into a filename. That is exactly
# the shape a projects.d PARENT used to reach another register through the
# entity join (measured 2026-09-01), and the lesson taken from it was that
# the check belongs where the splice happens, not only where the value was
# read.
#
# ONE MANAGED_BY HOP, AND ONLY ONE. The same deliberate limit lib/visibility.sh
# draws at its rule 5 and lib/sessions.sh at its lineage: a customer of a
# customer is not the same work, and a rule that walked the whole chain would
# hand out an ever-widening set of capabilities nobody declared. Capabilities
# make that argument sharper than visibility did — the thing being inherited
# here is the right to run a program with somebody's credentials.
#
# DEDUP PRESERVES FIRST-SEEN ORDER. The same asset granted by a team and again
# by its client is ONE server, named at the level that granted it first; the
# alternative is a duplicate key in the rendered document, where the last
# writer silently wins.
#
# AN ACCOUNT THAT WILL NOT LOAD IS THE SAME FAULT AS A TEAM THAT WILL NOT, and
# it is the fault this level is most likely to hit: an ACCOUNT naming a row
# that is missing from accounts.d would otherwise contribute an empty string,
# and the person's entire personal set would disappear into an rc 0 that reads
# "nobody granted you anything". A machine reads the rc, and rc 0 tells a
# spawner to start the session as if that were the whole grant.
#
# A LEVEL THAT FAILS TO LOAD CONTRIBUTES NOTHING, IS NAMED, AND MOVES THE RC.
# The levels that DID load still grant — the partial set is on stdout, because
# a caller that wants it should have it — but the answer is flagged as partial
# rather than handed over as if it were whole.
#
# THE FAILING LOADER'S OWN STDERR IS LET THROUGH, NOT SWALLOWED. Suppressing it
# left the sentence below naming the level that would not load — and the level
# is usually not the culprit. An entity whose MANAGED_BY names a row that does
# not exist reports as "the owning entity would not load", sending the operator
# to a file that is sitting right there and is fine; the loader had already
# written the true cause and it was being thrown away. Only stdout is
# redirected here, and only because a sourced conf must not be able to write
# into the set being built.
#
# SUBSHELLED WHOLE, for the reason registry_session_owning_entity is: the
# loads below write into the shell that runs them.
registry_session_mcp_assets() {
  local sid="${1:-}"
  if [ -z "$sid" ]; then
    echo "registry: registry_session_mcp_assets needs a session id" >&2
    return 1
  fi
  (
    # ONE LOAD, THREE ANSWERS. `out` carries TARGET_PROJECT on line one,
    # ACCOUNT on line two and a constant on line three — the possibly-empty
    # fields FIRST, because command substitution strips every trailing newline
    # and would otherwise collapse them into one field. The same idiom, and
    # the same reasoning, as registry_display_for's entity-chain walk above.
    #
    # THE ACCOUNT COMES OFF THE SAME READ AS THE TARGET, for the reason the
    # entity's MANAGED_BY and MCP_ASSETS do below: both fields are on the row
    # already in hand, and asking the register twice would buy a second read
    # for an answer it has just given.
    local out rc
    out="$( registry_load "$sid" >/dev/null 2>&1 && printf '%s\n%s\n%s\n' "${TARGET_PROJECT:-}" "${ACCOUNT:-}" "ok" )"
    rc=$?
    if [ "$rc" -ne 0 ]; then
      echo "registry: mcp assets for '$sid' — the session's own row would not load; no assets resolved" >&2
      exit 1
    fi
    local target_project="${out%%$'\n'*}" _after_project account
    _after_project="${out#*$'\n'}"
    account="${_after_project%%$'\n'*}"

    # A LEVEL FAILED is carried in a flag rather than returned from where it
    # happened: all four levels may fail independently, every one of them has
    # to be named, and an early return would silence the three after the
    # first.
    _MCP_SEEN=""; _MCP_OUT=""; _MCP_LEVEL_FAILED=""

    # LEVEL 0 — THE OWNING ACCOUNT, the person rather than the org node, and
    # collected FIRST so a shared asset is attributed to the level that is
    # closest to whoever is at the session.
    #
    # A ROW WITH NO ACCOUNT AT ALL IS AN ABSENCE, NOT A FAULT — every conf
    # that predates the naming model omits the field, and it must read exactly
    # as it did before this level existed: nothing collected, nothing said.
    # That is the same distinction LEVEL 3 draws for a session aimed at an
    # entity rather than a project.
    if [ -n "$account" ]; then
      # ASSERTED BEFORE THE SPLICE. registry_load's own grammar for ACCOUNT is
      # strictly narrower than this one, so nothing reaching here through that
      # loader can fail it — which is the argument for keeping the check, not
      # against it: the slug is about to be concatenated into a filename in a
      # directory that sits beside entities.d, and the last register that
      # trusted an upstream check for exactly that reason let a row reach
      # another register's file.
      if ! registry_valid_name "$account"; then
        echo "registry: mcp assets for '$sid' — the owning account resolves to '$(registry_printable "$account")', which is not a legal slug (allowed: a-z 0-9 -); refusing to hand it to anything that builds a path" >&2
        _MCP_LEVEL_FAILED=1
      else
        local acct_out acct_rc
        acct_out="$( registry_account_load "$account" >/dev/null \
                     && printf '%s\n%s\n' "${ACCOUNT_MCP_ASSETS:-}" "ok" )"
        acct_rc=$?
        if [ "$acct_rc" -ne 0 ]; then
          # THE LOADER'S OWN STDERR IS LET THROUGH here too, for the reason it
          # is at every other level: it has already said WHICH fault this was
          # — no such row, an unreadable one, a row missing PRINCIPAL — and
          # this sentence adds the session whose grant it cost.
          echo "registry: mcp assets for '$sid' — the owning account '$account' would not load; it grants nothing here" >&2
          _MCP_LEVEL_FAILED=1
        else
          _registry_mcp_collect "${acct_out%%$'\n'*}"
        fi
      fi
    fi

    local owning own_rc
    owning="$( registry_session_owning_entity "$sid" )"; own_rc=$?
    if [ "$own_rc" -eq 65 ]; then
      # NAMED BY registry_session_owning_entity ITSELF, which knows the value;
      # this line adds the session, so the two sentences together say what was
      # refused and whose work it cost.
      echo "registry: mcp assets for '$sid' — the owning entity is not a legal slug (named above); no level of the org could be read from it" >&2
      _MCP_LEVEL_FAILED=1
      owning=""
    elif [ "$own_rc" -ne 0 ]; then
      owning=""
    fi

    # LEVEL 1 AND LEVEL 2 COME OFF ONE READ OF THE OWNING ENTITY. Its
    # MANAGED_BY (the team) and its own MCP_ASSETS are both on that row;
    # asking the register twice would cost a second read for an answer it
    # already gave. Ordering again puts the possibly-empty fields first and a
    # constant last.
    if [ -n "$owning" ]; then
      local ent_out ent_rc mgr ent_assets rest
      ent_out="$( registry_entity_load "$owning" >/dev/null \
                  && printf '%s\n%s\n%s\n' "${ENTITY_MANAGED_BY:-}" "${ENTITY_MCP_ASSETS:-}" "ok" )"
      ent_rc=$?
      if [ "$ent_rc" -ne 0 ]; then
        echo "registry: mcp assets for '$sid' — the owning entity '$owning' would not load; it grants nothing here" >&2
        _MCP_LEVEL_FAILED=1
      else
        mgr="${ent_out%%$'\n'*}"
        rest="${ent_out#*$'\n'}"
        ent_assets="${rest%%$'\n'*}"
        # LEVEL 1 — the managing team, one hop.
        if [ -n "$mgr" ]; then
          local mgr_out mgr_rc
          mgr_out="$( registry_entity_load "$mgr" >/dev/null \
                      && printf '%s\n%s\n' "${ENTITY_MCP_ASSETS:-}" "ok" )"
          mgr_rc=$?
          if [ "$mgr_rc" -ne 0 ]; then
            echo "registry: mcp assets for '$sid' — the managing team '$mgr' would not load; it grants nothing here" >&2
            _MCP_LEVEL_FAILED=1
          else
            _registry_mcp_collect "${mgr_out%%$'\n'*}"
          fi
        fi
        # LEVEL 2 — the owning entity itself.
        _registry_mcp_collect "$ent_assets"
      fi
    fi

    # LEVEL 3 — the project's OWN row, the narrowest grant. A session aimed at
    # an entity has no third level at all; that is an absence, not a failure,
    # and says nothing.
    if [ -n "$target_project" ]; then
      local proj_out proj_rc
      proj_out="$( registry_project_load "$target_project" >/dev/null \
                   && printf '%s\n%s\n' "${PROJECT_MCP_ASSETS:-}" "ok" )"
      proj_rc=$?
      if [ "$proj_rc" -ne 0 ]; then
        echo "registry: mcp assets for '$sid' — the project '$target_project' would not load; it grants nothing here" >&2
        _MCP_LEVEL_FAILED=1
      else
        _registry_mcp_collect "${proj_out%%$'\n'*}"
      fi
    fi

    # THE PARTIAL SET IS STILL PRINTED, and then flagged. Printing first means
    # a caller that reads stdout and ignores the rc is no worse off than
    # before; the rc is what stops it being read as the whole grant.
    printf '%s' "$_MCP_OUT"
    [ -z "$_MCP_LEVEL_FAILED" ] || exit 65
  )
}

# _registry_mcp_collect <assets-string> — appends the string's words to the
# accumulator (_MCP_OUT), skipping any slug already collected. Called only
# from inside registry_session_mcp_assets' subshell, which owns both globals.
#
# THE MEMBERSHIP TEST IS SPACE-DELIMITED CONTAINMENT, the same idiom
# lib/visibility.sh's MEMBERS check uses — the surrounding spaces are what
# stop `chat` from matching inside `chat-tool`.
_registry_mcp_collect() {
  _registry_words "${1:-}"
  local w
  for w in "${REGISTRY_WORDS[@]+"${REGISTRY_WORDS[@]}"}"; do
    case " $_MCP_SEEN " in *" $w "*) continue ;; esac
    _MCP_SEEN="$_MCP_SEEN $w"
    _MCP_OUT="$_MCP_OUT$w"$'\n'
  done
}

# ── DISPLAY DERIVATION — PRESENTATION, NEVER IDENTITY ───────────────────────
#
# registry_display_for <entity|project> <slug> — prints the root-to-leaf
# ancestry NAMEs joined with the U+2192 arrow (→), the ONE separator this
# function itself generates. An ENTITY's display walks its MANAGED_BY chain
# to the root (a team with no MANAGED_BY is just its own NAME). A PROJECT's
# display is its own NAME as the leaf, prepended by its PARENT entity's own
# derived display — a project two hops under a team still reads
# root→…→leaf.
#
# PURE. Reads through registry_entity_dir/registry_project_dir (honoring
# STEWARD_ENTITY_DIR/STEWARD_PROJECT_DIR), writes nothing.
#
# COMPONENT VALIDATION BEFORE THE JOIN — THE HARD RULE. A NAME is never
# pushed through the join until it is checked for the one byte sequence
# this function itself generates (the arrow) and for control bytes/
# newlines. A NAME allowed to carry the arrow could forge a fake ancestor
# or split the string a caller might parse back apart; a control byte
# could make one row's display bleed into the next line of output. THE
# SEPARATOR IS NEVER MATCHED BACK OUT OF AN OLD ASCII REGEX — each
# component is validated OUT of the arrow BEFORE this function ever joins
# it in, not filtered afterward.
#
# SUBSHELLED LOADS, THE SAME LESSON registry_account_slug_available above
# and cmd_registry_client_add's --managed-by lookup (bin/steward) both
# already carry: registry_entity_load/registry_project_load SOURCE an
# untrusted conf. Called directly in THIS function's own shell, a hostile
# row assigning the walk's own lowercase locals (name, parent, managed_by,
# slug) would clobber them via bash's dynamic scoping the moment the row
# sourced — not a defence against the ENTITY_*/PROJECT_* globals the
# loaders themselves already guard by declaring their own uppercase
# locals, but against a second, independent path to the exact same class
# of corruption, through THIS function's own local variable names. Every
# extraction below therefore happens inside a command-substitution
# subshell — a separate process, so anything a hostile conf assigns dies
# with it and never reaches this function's own locals.
#
# CYCLE/DEPTH GUARD. registry_entity_load already refuses (rc 1) to load
# ANY entity sitting in a MANAGED_BY cycle — its own chain-walk guard
# (_REGISTRY_MANAGED_BY_CHAIN) fires before the loop below can iterate
# more than once over a cycle. The chain-set and depth cap in the loop
# below are defensive belt-and-braces on top of that, not the only thing
# standing between a cycle and an infinite loop.

# _registry_display_component <name> — 0 if the component is safe to join,
# or prints a refusal and returns 1. Internal to registry_display_for.
_registry_display_component() {
  local v="$1"
  case "$v" in
    *[[:cntrl:]]*)
      echo "registry: registry_display_for: refusing — a NAME contains a control character or newline" >&2
      return 1 ;;
  esac
  case "$v" in
    *"→"*)
      echo "registry: registry_display_for: refusing — a NAME contains the display separator itself" >&2
      return 1 ;;
  esac
  # UNICODE BIDIRECTIONAL CONTROLS ARE A VISUAL-REORDER SPOOF. RLO/LRO/RLE/LRE
  # (U+202A-202E) and the isolates (U+2066-2069) are format characters
  # (category Cf) — not [[:cntrl:]] and not the arrow, so the gates above miss
  # them — that can visually reorder a rendered string in any terminal or UI
  # honoring bidi. A NAME carrying one could make the derived display READ as a
  # different ancestry than the tree is. Refused by their UTF-8 byte sequences
  # (E2 80 AA-AE and E2 81 A6-A9), which match regardless of locale.
  case "$v" in
    *$'\xe2\x80\xaa'*|*$'\xe2\x80\xab'*|*$'\xe2\x80\xac'*|*$'\xe2\x80\xad'*|*$'\xe2\x80\xae'*|\
    *$'\xe2\x81\xa6'*|*$'\xe2\x81\xa7'*|*$'\xe2\x81\xa8'*|*$'\xe2\x81\xa9'*)
      echo "registry: registry_display_for: refusing — a NAME contains a Unicode bidirectional control character" >&2
      return 1 ;;
  esac
  return 0
}

# _registry_display_entity_chain <entity-id> -> the root-to-leaf display for
# that entity, walking MANAGED_BY upward one subshelled load at a time.
# Internal to registry_display_for; also the PARENT half of a project's
# display below.
_registry_display_entity_chain() {
  local id="${1:-}" depth=0 chain=" " out load_rc name managed_by result=""
  [ -n "$id" ] || return 1
  while [ -n "$id" ]; do
    case "$chain" in
      *" $id "*)
        echo "registry: registry_display_for: MANAGED_BY forms a cycle at: $id" >&2
        return 1 ;;
    esac
    chain="$chain$id "
    depth=$((depth + 1))
    if [ "$depth" -gt 64 ]; then
      echo "registry: registry_display_for: MANAGED_BY chain exceeds the depth cap at: $id" >&2
      return 1
    fi
    # SUBSHELLED — see the header above. `out` carries MANAGED_BY on line
    # one, NAME on line two — MANAGED_BY FIRST BECAUSE IT CAN BE EMPTY (the
    # root of the chain) AND NAME NEVER IS (registry_entity_load already
    # refuses a row with no NAME). Command substitution strips ALL
    # trailing newlines from its output, not just one — printing the
    # possibly-empty field last would collapse "Alpha\n\n" to a bare
    # "Alpha" with the separating newline gone too, and the split below
    # would then read the whole two-field payload back as a single NAME.
    # Printing the guaranteed-non-empty NAME last means the captured
    # string always ends in real content, so exactly one newline always
    # survives to split on.
    out="$( registry_entity_load "$id" >/dev/null 2>&1 && printf '%s\n%s\n' "$ENTITY_MANAGED_BY" "$ENTITY_NAME" )"
    load_rc=$?
    if [ "$load_rc" -ne 0 ]; then
      echo "registry: registry_display_for: entity does not resolve: $id" >&2
      return 1
    fi
    managed_by="${out%%$'\n'*}"
    name="${out#*$'\n'}"; name="${name%$'\n'}"
    _registry_display_component "$name" || return 1
    if [ -z "$result" ]; then result="$name"; else result="${name}→${result}"; fi
    id="$managed_by"
  done
  printf '%s' "$result"
}

# registry_display_for <entity|project> <slug> — see the header above.
registry_display_for() {
  local kind="${1:-}" slug="${2:-}"
  case "$kind" in
    entity)
      [ -n "$slug" ] || return 1
      _registry_display_entity_chain "$slug"
      ;;
    project)
      [ -n "$slug" ] || return 1
      local out load_rc name parent parent_display
      # SUBSHELLED — see the header above. Same PARENT-then-NAME ordering
      # as the entity chain walk above, for the same reason: NAME is the
      # field registry_project_load guarantees non-empty, so it is safe to
      # put last where command substitution's trailing-newline stripping
      # cannot collapse it into the field ahead of it.
      out="$( registry_project_load "$slug" >/dev/null 2>&1 && printf '%s\n%s\n' "$PROJECT_PARENT" "$PROJECT_NAME" )"
      load_rc=$?
      if [ "$load_rc" -ne 0 ]; then
        echo "registry: registry_display_for: project does not resolve: $slug" >&2
        return 1
      fi
      parent="${out%%$'\n'*}"
      name="${out#*$'\n'}"; name="${name%$'\n'}"
      _registry_display_component "$name" || return 1
      parent_display="$(_registry_display_entity_chain "$parent")" || return 1
      printf '%s→%s' "$parent_display" "$name"
      ;;
    *)
      echo "registry: registry_display_for: unknown target-kind '$kind' (allowed: entity, project)" >&2
      return 64
      ;;
  esac
}

# ── THE ENTITY SERIALIZER — ONE FUNCTION, BECAUSE THESE CONFS ARE SOURCED ──
#
# registry_entity_load ABOVE calls `source` on entities.d/<id>.conf. That is
# the same class of danger as any other shell-sourced config: a value written
# into a double-quoted assignment without escaping lets `$(cmd)`, a backtick,
# `$VAR` or a bare backslash EXECUTE OR EXPAND the moment a reader loads the
# row back — not a rendering bug, an injection.
#
# _registry_emit_kv KEY VALUE prints `KEY="<escaped-value>"` on stdout and
# returns 0, or prints nothing and returns 64 if VALUE carries a control byte
# or a newline. Both writer verbs (team add, client add) route every field
# they write through this one function — never two independently maintained
# escapers that could drift apart, the same reasoning the estate-value reader
# above already follows for READING.
#
# THE ESCAPE ORDER MATTERS: backslash FIRST. Escaping `"`, `$` or `` ` `` before
# backslash would have this function's OWN inserted backslashes re-escaped on
# the next substitution; escaping backslash first means every later
# substitution's find-pattern (`"`, `$`, `` ` ``) can never match a byte this
# function itself just inserted.
#
# AN APOSTROPHE NEEDS NONE OF THIS. Inside a double-quoted bash string a `'`
# has no meaning at all — a validator that rejected it would be both too
# strict (refusing an ordinary display name like "O'Brien") and pointless (it
# closes no hole this serializer actually has).
_registry_emit_kv() {
  local key="$1" value="$2"
  case "$value" in
    *[[:cntrl:]]*)
      echo "registry: refusing to write $key — value contains a control character or newline" >&2
      return 64 ;;
  esac
  local esc="$value"
  esc="${esc//\\/\\\\}"
  esc="${esc//\"/\\\"}"
  esc="${esc//\$/\\\$}"
  esc="${esc//\`/\\\`}"
  printf '%s="%s"\n' "$key" "$esc"
}

# _registry_restore_exit_trap <saved-trap-string> — restores whatever EXIT
# trap `trap -p EXIT` captured before this file's own lock trap replaced it,
# or clears the trap entirely if there was none. A caller's own
# `trap ... EXIT` (a test fixture's cleanup, say) must survive a call into
# registry_entity_write in the same shell — this is what makes that true.
_registry_restore_exit_trap() {
  if [ -n "$1" ]; then eval "$1"; else trap - EXIT; fi
}

# _registry_stat_id <path> — "<inode>:<size>", BSD or GNU stat, or empty on
# failure. Used only to tell "the file I just staged" from "a file some other
# process wrote under the same name a moment later" — a name match is not an
# identity match.
_registry_stat_id() {
  local p="$1" out
  out="$(stat -f '%i:%z' "$p" 2>/dev/null)" && [ -n "$out" ] && { printf '%s' "$out"; return 0; }
  out="$(stat -c '%i:%s' "$p" 2>/dev/null)" && [ -n "$out" ] && { printf '%s' "$out"; return 0; }
  return 1
}

# ── THE ROW WRITER TRANSACTION — ONE SHARED PRIMITIVE ──────────────────────
#
# registry_row_write <dir> <slug> <content> <validate_fn> <readback_fn> <label>
#
#   dir         the register directory the CALLER already resolved (e.g.
#               registry_entity_dir, registry_account_dir). This function
#               never resolves a directory on its own — a caller that honors
#               an override (STEWARD_ENTITY_DIR, STEWARD_ACCOUNT_DIR) keeps
#               doing so, and the lock below is keyed on whatever dir it is
#               handed, exactly as before the extraction.
#   slug        SHOULD already be validated by the CALLER against the
#               entity-id form (^[a-z0-9][a-z0-9-]*$) for a better error
#               message earlier — but this function re-checks it too, and
#               refuses on its own if it isn't. A primitive whose safety
#               rests on "the caller checked" is not a boundary.
#   content     the full file body, already built entirely out of
#               _registry_emit_kv lines — so every value inside it has
#               already been escaped or the caller never got this far.
#   validate_fn the name of a function the CALLER defines, called as
#               `validate_fn <staged-file-path>`. It must re-read the staged
#               file and confirm the row it is about to publish is the row
#               that was meant — this function does not know the schema of
#               what it is writing (team vs. client vs. account have
#               different keys).
#   readback_fn the name of the register's OWN loader (registry_entity_load,
#               registry_account_load, …), called as `readback_fn <slug>`
#               under the SAME lock right after publish — "written ok" means
#               exactly what a reader will see, never a second definition of
#               "valid" invented here.
#   label       a short noun ("entity", "account", …) spliced into the
#               refusal prose below ("the $label register is not readable",
#               "the staged $label file") — the ONLY thing that varies
#               between register types; every rc and every sequencing
#               decision is shared.
#
# THE SEQUENCE, each step named for the failure it closes:
#   0. SLUG      — validated against the entity-id form by THIS function,
#                  not just the caller (see above). rc 64 on a bad slug,
#                  before any path is built from it.
#   1. LOCK      — keyed on the DIRECTORY THE CALLER PASSED, not the estate
#                  root: a caller's own dir-resolver honors its own
#                  override independently of the estate root, so a lock
#                  keyed on the estate root let two writers pointed at the
#                  same register (via different estate roots) take
#                  different locks and race. mkdir is atomic on every
#                  filesystem this runs on; bounded retries, never stolen,
#                  rc 75 names the lock when it is genuinely held (EEXIST),
#                  rc 78 when mkdir cannot succeed for any other reason
#                  (ENOENT/EACCES) — that is an unwritable register, not
#                  contention, and must never be reported as one.
#   2. RECHECK   — under the lock, not before it: the destination must not
#                  exist and must not be a symlink. A caller's own pre-check
#                  (if any) happened before the lock was held and cannot be
#                  trusted against a concurrent writer.
#   3. STAGE     — write to a NON-.conf temp name in the same directory
#                  (umask 077 around the mktemp+write), so a reader globbing
#                  *.conf never observes a half-written row.
#   4. VALIDATE  — the caller's validate_fn re-reads the STAGED file and
#                  confirms it matches, before the row is ever visible under
#                  its final name. A bad row must never be readable as
#                  <slug>.conf even for the instant between mv and the next
#                  check.
#   5. chmod     — 0600, and a chmod FAILURE IS A HARD REFUSE. Publishing a
#                  file whose mode could not be verified narrow would be
#                  worse than not publishing at all.
#   6. PUBLISH   — `ln` (hardlink) onto the final name, then remove the
#                  stage. `ln` FAILS (EEXIST, non-zero) when the destination
#                  already exists — unlike `mv -n`, which exits 0 when it
#                  DECLINES to overwrite, which let this step report
#                  "wrote" while a foreign row sat under the final name
#                  untouched. The lock plus the recheck in step 2 already
#                  closed the ordinary race; this closes the case where
#                  something appeared in the window anyway.
#   7. READBACK  — under the SAME lock, through the register's OWN loader
#                  (readback_fn) — the same function every reader uses, so
#                  "written ok" means exactly what a reader will see. On
#                  failure the row is removed. The removal is UNCONDITIONAL
#                  unless stat POSITIVELY proves the file on disk is no
#                  longer the one just staged (inode+size differ, both
#                  readable) — an empty/unavailable stat (no BSD or GNU stat
#                  on PATH, a restricted PATH) must never be read as
#                  permission to leave a bad row published while the
#                  message claims "refusing". Refusing to publish is safe;
#                  refusing to clean up is not.
#   8. RELEASE   — trap-guarded, so an interrupt mid-transaction still frees
#                  the lock; every explicit return path also clears it so a
#                  caller in the same shell can retry.
#
# rc 64 invalid slug · 65 destination exists (names the file) · 75 lock held
# · 78 the register directory could not be resolved, or is unwritable · 70
# any other write/validate/chmod/publish/readback failure.
#
# EXTRACTED 2026-08-30 out of what was registry_entity_write, the day the
# account register needed the exact same transaction over a different
# directory and a different loader. registry_entity_write below is now a
# THIN WRAPPER over this function — same directory resolution
# (registry_entity_dir), same loader (registry_entity_load), same label
# ("entity") it always used, so its behavior is unchanged byte for byte;
# test/registry-org-verbs.test.sh pins that unchanged.
registry_row_write() {
  local dir="$1" slug="$2" content="$3" validate_fn="$4" readback_fn="$5" label="$6"
  # THIS PRIMITIVE VALIDATES ITS OWN SLUG. Documented above as "already
  # validated by the CALLER" is not a boundary — a caller whose validation
  # is bypassed, buggy, or simply doesn't exist yet would otherwise inherit
  # an unchecked path straight into $dir/$slug.conf. Refuse before that
  # path is ever built.
  if ! [[ "$slug" =~ ^[a-z0-9][a-z0-9-]*$ ]]; then
    echo "registry: refusing — invalid slug '$slug' (allowed: a-z0-9-, must start a-z0-9)" >&2
    return 64
  fi
  if [ ! -d "$dir" ]; then
    echo "registry: REFUSING — the $label register is not readable: $dir" >&2
    return 78
  fi
  local final="$dir/$slug.conf"
  # 1. LOCK. Derived from the DIRECTORY THE CALLER PASSED, not the estate
  # root — see the header above.
  local lock="$dir/.write.lock"
  local tries=0
  while ! mkdir "$lock" 2>/dev/null; do
    # A failed mkdir that left NO lock dir on disk AND an unwritable register
    # dir is a genuine ENOENT/EACCES that no retry resolves — fail fast (the
    # original defect was blamed for a multi-second stall). But a WRITABLE dir
    # with no lock present means a holder rmdir'd it in the window between our
    # failed mkdir and this check: pure contention, not unwritability.
    # Concluding 78 there (measured under a 60-way session-add race) reports a
    # merely-busy register as broken; require BOTH conditions, then loop and
    # let the next mkdir take the freed lock.
    if [ ! -d "$lock" ] && [ ! -w "$dir" ]; then
      echo "registry: could not create the write lock — the $label register is not writable: $lock" >&2
      return 78
    fi
    tries=$((tries+1))
    if [ "$tries" -ge 20 ]; then
      echo "registry: another write holds the registry lock, refusing: $lock" >&2
      echo "registry: if no write is in progress, remove it with: rmdir $lock" >&2
      return 75
    fi
    sleep 0.1
  done
  # Save whatever EXIT trap the caller already had, so this function's own
  # cleanup can restore it rather than wipe it out — a caller's own
  # `trap ... EXIT` (a test fixture's cleanup, say) must survive a call into
  # this function in the same shell.
  local _prev_trap; _prev_trap="$(trap -p EXIT)"
  trap 'rmdir "'"$lock"'" 2>/dev/null' EXIT

  # 2. RECHECK, under the lock.
  if [ -e "$final" ] || [ -L "$final" ]; then
    echo "registry: refusing — already exists: $final" >&2
    rmdir "$lock" 2>/dev/null; _registry_restore_exit_trap "$_prev_trap"
    return 65
  fi

  # 3. STAGE (umask 077 for the create, saved/restored immediately — this
  # function runs in the CALLER's shell, so leaving the umask changed would
  # leak into every command the caller runs afterward).
  local _prev_umask; _prev_umask="$(umask)"
  umask 077
  local stage
  stage="$(mktemp "$dir/.stage.XXXXXX" 2>/dev/null)"
  umask "$_prev_umask"
  if [ -z "$stage" ]; then
    echo "registry: could not create a staging file in $dir" >&2
    rmdir "$lock" 2>/dev/null; _registry_restore_exit_trap "$_prev_trap"
    return 70
  fi
  if ! printf '%s' "$content" > "$stage"; then
    echo "registry: could not write the staged $label file: $stage" >&2
    rm -f "$stage"; rmdir "$lock" 2>/dev/null; _registry_restore_exit_trap "$_prev_trap"
    return 70
  fi

  # 4. VALIDATE THE STAGED BYTES — before the row is visible under its final
  # name.
  if ! "$validate_fn" "$stage"; then
    rm -f "$stage"; rmdir "$lock" 2>/dev/null; _registry_restore_exit_trap "$_prev_trap"
    return 70
  fi

  # 5. chmod, hard refuse on failure.
  if ! chmod 0600 "$stage"; then
    echo "registry: could not set the mode of the staged $label file: $stage" >&2
    rm -f "$stage"; rmdir "$lock" 2>/dev/null; _registry_restore_exit_trap "$_prev_trap"
    return 70
  fi

  # 6. PUBLISH via hardlink, no-clobber. `ln` FAILS (EEXIST, non-zero) when
  # $final already exists — unlike `mv -n`, which exits 0 when it DECLINES
  # to overwrite, which let this step report "wrote" while a foreign row
  # sat under the final name untouched and a reader's next load would see
  # THAT row, not this one.
  # A directory (or any non-regular file) appearing under $final between the
  # recheck above and this publish is the one shape `ln` does NOT refuse:
  # `ln SRC DIR` links INTO the directory instead of failing EEXIST, and a
  # later `rm -f` cannot remove a directory — the slug would be squatted for
  # good with the staged bytes leaked inside it. Re-guard immediately before
  # the link, then confirm what actually landed is our own regular file.
  if [ -e "$final" ] || [ -L "$final" ]; then
    echo "registry: refusing — already exists: $final" >&2
    rm -f "$stage"; rmdir "$lock" 2>/dev/null; _registry_restore_exit_trap "$_prev_trap"
    return 65
  fi
  if ! ln "$stage" "$final" 2>/dev/null; then
    echo "registry: refusing — already exists: $final" >&2
    rm -f "$stage"; rmdir "$lock" 2>/dev/null; _registry_restore_exit_trap "$_prev_trap"
    return 65
  fi
  if [ ! -f "$final" ]; then
    # `ln` linked into a directory that raced in during the link syscall
    # itself: the staged bytes now sit at $final/<stage-basename>. Remove
    # that nested link, leave the raced directory (not ours to delete), and
    # refuse — never report a write that did not land where it claims.
    rm -f "$final/$(basename "$stage")" 2>/dev/null
    echo "registry: refusing — $final is not a regular file (a directory raced the publish)" >&2
    rm -f "$stage"; rmdir "$lock" 2>/dev/null; _registry_restore_exit_trap "$_prev_trap"
    return 70
  fi
  rm -f "$stage"

  # 7. CANONICAL READBACK, same lock, the register's own loader.
  local staged_id; staged_id="$(_registry_stat_id "$final")"
  if ! ( "$readback_fn" "$slug" >/dev/null 2>&1 ); then
    local now_id; now_id="$(_registry_stat_id "$final" 2>/dev/null)"
    # Remove UNCONDITIONALLY unless stat POSITIVELY proves $final is no
    # longer the file just staged (both ids present AND different). An
    # empty/unavailable stat on either side — no BSD or GNU stat on PATH, a
    # restricted PATH — must never be read as permission to leave a bad row
    # published while this message says "refusing". Refusing to publish is
    # safe; refusing to clean up is not.
    if [ -z "$staged_id" ] || [ -z "$now_id" ] || [ "$staged_id" = "$now_id" ]; then
      rm -f "$final"
    fi
    echo "registry: wrote $final but it does not load back through the registry — refusing" >&2
    rmdir "$lock" 2>/dev/null; _registry_restore_exit_trap "$_prev_trap"
    return 70
  fi

  # 8. RELEASE.
  rmdir "$lock" 2>/dev/null
  _registry_restore_exit_trap "$_prev_trap"
  return 0
}

# registry_entity_write <slug> <content> <validate_fn> — THIN WRAPPER over
# registry_row_write: resolves the entity directory (honoring
# STEWARD_ENTITY_DIR), reads back through registry_entity_load, and labels
# refusals "entity" — the exact directory, loader and wording this function
# used before the 2026-08-30 extraction. NOT THE ONLY ENTITY/SESSION WRITER
# IN THE PRODUCT. session-new.sh (on the estate host) and hub/enroll hold
# their own serializer for their own conf shape, and unifying all three is a
# later scope — this function covers the org verbs and the account verb
# asking for it now.
registry_entity_write() {
  local slug="$1" content="$2" validate_fn="$3"
  local dir; dir="$(registry_entity_dir)" || return 78
  registry_row_write "$dir" "$slug" "$content" "$validate_fn" registry_entity_load "entity"
}

# registry_project_write <slug> <content> <validate_fn> — THIN WRAPPER over
# registry_row_write, the project-register twin of registry_entity_write
# above: resolves the project directory (honoring STEWARD_PROJECT_DIR),
# reads back through registry_project_load, and labels refusals "project".
# Same writer transaction, same lock discipline, same eight-step sequence —
# `steward registry project add` (bin/steward) is the only caller.
registry_project_write() {
  local slug="$1" content="$2" validate_fn="$3"
  local dir; dir="$(registry_project_dir)" || return 78
  registry_row_write "$dir" "$slug" "$content" "$validate_fn" registry_project_load "project"
}

# ── ACCOUNTS: (PRINCIPAL, HOST, USERNAME) — THE THING SLUG AND DISPLAY
# BOTH SIT UNDER ─────────────────────────────────────────────────────────
#
# WHY THIS REGISTER EXISTS AT ALL. A bare username is not an identity — the
# same human already runs sessions under more than one host, and a username
# is neither unique across hosts nor stable enough to carry a bus address,
# history, or process ownership. An ACCOUNT names the (principal, host)
# pair a session's SLUG is scoped inside — ID stays global and immutable,
# ACCOUNT can change on a move, SLUG is unique only within its own account,
# and DISPLAY is derived and never used for identity.
#
# ESTATE-GLOBAL, next to entities.d — the slug convention is
# "<principal>-<host>" (readable, stable, never guessed from username
# alone), but that composition is GUIDANCE, not something this layer
# parses out of the slug: the slug is validated for SHAPE only
# (^[a-z0-9][a-z0-9-]*$), the same entity-id form every other register
# here uses.
registry_account_dir() {
  if [ -n "${STEWARD_ACCOUNT_DIR:-}" ]; then printf '%s\n' "$STEWARD_ACCOUNT_DIR"; return 0; fi
  printf '%s\n' "$(_registry_estate_root)/accounts.d"
}

# registry_account_load <slug>: sets ACCOUNT_PRINCIPAL, ACCOUNT_HOST,
# ACCOUNT_USERNAME, ACCOUNT_MCP_ASSETS. rc 1 on any missing/invalid field,
# matching registry_entity_load's own contract.
#
# MCP_ASSETS IS A LEGAL FIELD HERE FOR A REASON THE ORG TREE CANNOT COVER.
# entities.d and projects.d rows carry the same field, and every level they
# describe is a place in the ORG — a team, a client, a piece of work. A
# personal capability has no place there: a mail account, a calendar, a note
# store belong to the HUMAN, and two people working on the same client must
# not inherit each other's. An account is the one row in this estate that
# names a (principal, host) rather than an org node, so it is the one row
# that can carry a grant bound to a person. registry_session_mcp_assets
# unions it in as its FIRST level.
#
# NOT VALIDATED, ONLY EXPOSED — the same choice registry_entity_load records:
# resolving the slugs here would make every account load hit the mcp register,
# and the grammar each slug must satisfy is enforced where it is used as a
# path (registry_mcp_asset_load), not where it is read.
#
# RESET BEFORE SOURCING — the same leak-guard pattern every loader in this
# file follows: a caller that gets rc 1 for a missing or invalid account
# must not still see the last account that loaded successfully. The
# uppercase locals (PRINCIPAL, HOST, USERNAME, MCP_ASSETS) are read via
# `local` BEFORE the source too, so nothing the conf assigns ever reaches
# this function's caller except through the ACCOUNT_* globals set at the
# very end.
registry_account_load() {
  ACCOUNT_PRINCIPAL=""; ACCOUNT_HOST=""; ACCOUNT_USERNAME=""; ACCOUNT_MCP_ASSETS=""
  local slug="${1:-}" d f
  [ -n "$slug" ] || return 1
  d="$(registry_account_dir)" || return 78
  f="$d/$slug.conf"
  [ -f "$f" ] || { echo "registry: no such account: $slug" >&2; return 1; }
  local PRINCIPAL="" HOST="" USERNAME="" MCP_ASSETS=""
  # shellcheck source=/dev/null
  source "$f" || return 1
  # PRINCIPAL is the human this account belongs to — the OWNER/member form
  # (^[a-z][a-z0-9-]*$), matching entities' own MEMBERS entries.
  if ! [[ "$PRINCIPAL" =~ ^[a-z][a-z0-9-]*$ ]]; then
    echo "registry: $slug.conf missing/invalid PRINCIPAL" >&2
    return 1
  fi
  if [ -z "$HOST" ]; then
    echo "registry: $slug.conf missing HOST" >&2
    return 1
  fi
  # USERNAME defaults to PRINCIPAL — most accounts run under a unix account
  # that shares the human's own name, and forcing every row to repeat it
  # would be a field that is nearly always a copy of another.
  : "${USERNAME:=$PRINCIPAL}"
  ACCOUNT_PRINCIPAL="$PRINCIPAL"; ACCOUNT_HOST="$HOST"; ACCOUNT_USERNAME="$USERNAME"
  # SET LAST, WITH THE REST — an absent field reads as "no assets declared"
  # and can never come back as the previous account's grant. Fail closed:
  # fewer tools than granted is a session that says a server is missing;
  # more tools than granted is somebody else's credentials.
  ACCOUNT_MCP_ASSETS="$MCP_ASSETS"
}

# registry_account_write <slug> <content> <validate_fn> — THIN WRAPPER over
# registry_row_write, the account-register twin of registry_entity_write
# above: resolves the account directory (honoring STEWARD_ACCOUNT_DIR),
# reads back through registry_account_load, and labels refusals "account".
registry_account_write() {
  local slug="$1" content="$2" validate_fn="$3"
  local dir; dir="$(registry_account_dir)" || return 78
  registry_row_write "$dir" "$slug" "$content" "$validate_fn" registry_account_load "account"
}

# registry_account_slug_available <account-slug> <session-slug> — PURE: 0 if
# no session declares that (ACCOUNT, SLUG) pair, 1 if one does.
#
# WIRED INTO `steward registry session add` (bin/steward, 2026-08-30) —
# the composite gate that verb refuses on (rc 65) before minting an id.
# Built and tested AHEAD of that writer, which is exactly why wiring it in
# was one call and not an invention under time pressure. On a register
# whose rows predate the identity model the scan honestly finds no pair
# and reports available — old-shape rows carry no ACCOUNT/SLUG, and the
# gate begins to bite precisely as new-shape rows land.
#
# SUBSHELLED SOURCE, same reasoning as the host/managed-by loads elsewhere
# in this file: a hostile sessions.d row is exactly as untrusted as a
# hostile hosts.d or entities.d row, and this function's own ACCOUNT/SLUG
# locals must never be overwritten by bash's dynamic scoping when a
# candidate conf happens to assign the same names.
registry_account_slug_available() {
  local account="${1:-}" slug="${2:-}" d f
  [ -n "$account" ] && [ -n "$slug" ] || return 1
  d="$(registry_dir)"
  [ -d "$d" ] || return 0
  for f in "$d"/*.conf; do
    [ -e "$f" ] || continue
    # SOURCE IN A COMMAND SUBSTITUTION, COMPARE IN THE PARENT. `source` can
    # set ANY variable, so no operand name in the same scope is safe — a conf
    # declaring the comparison's own `account`/`slug` would overwrite the
    # query and make the scan report its own taken pair as available (a false
    # negative on its one job). Extracting only ACCOUNT/SLUG through `$( )`
    # (the visibility.sh pattern) keeps the sourced file from ever touching
    # the operands `$account`/`$slug`, which live only in this parent shell.
    local f_account f_slug
    f_account="$( ACCOUNT=""; source "$f" 2>/dev/null; printf '%s' "$ACCOUNT" )"
    f_slug="$( SLUG=""; source "$f" 2>/dev/null; printf '%s' "$SLUG" )"
    [ "$f_account" = "$account" ] && [ "$f_slug" = "$slug" ] && return 1
  done
  return 0
}

# registry_session_write <id> <content> <validate_fn> — THIN WRAPPER over
# registry_row_write, the session-register sibling of the entity/project/
# account wrappers above: resolves the session directory (registry_dir,
# honoring STEWARD_REGISTRY_DIR), reads back through registry_load — the
# SAME reader every consumer of this register uses, so "written ok" means
# exactly what a reader will see — and labels refusals "session".
#
# FLAT STORAGE IS THE EXPLICIT CHOICE HERE, not an omission. The design
# spec deliberately deferred the physical layout and named the safe
# option: a flat sessions.d/<opaque-id>.conf where the FILENAME carries
# only the minted, immutable id and the account-scoped slug lives as a
# FIELD inside the row. An account move is then a field change, never a
# rename, and everything that globs the register's *.conf survives. A
# nested projection can be layered on later, on measured grounds, without
# this writer changing.
registry_session_write() {
  local id="$1" content="$2" validate_fn="$3"
  local dir; dir="$(registry_dir)" || return 78
  registry_row_write "$dir" "$id" "$content" "$validate_fn" registry_load "session"
}

# ── THE ESTATE'S OTHER VALUES ──────────────────────────────────────────────
# The same shape as the prefix lookup above, and for the same reasons: `local`
# before `source` so the estate file never leaks a global to the caller, form
# validation that closes the failure modes in one line, and REFUSAL 78 instead of
# a guess.
#
# These values stood as LITERALS in code destined for the product, and that alone
# is what held several sources back. Moving them here is not a rename — THE
# VALUES ARE UNCHANGED. It makes replaceable what was burned in.
#
# ONE SHARED READER, NOT ONE PER KEY. Sourcing the same file once per key would
# be one chance per key for the file to leak something, and one place per key to
# forget `local`.
_registry_estate_value() { # <key> <regex> -> the value, or rc 78
  local _nyckel="$1" _form="$2" _estate
  _estate="$(registry_estate_file)"
  if [ ! -f "$_estate" ]; then
    echo "registry: REFUSING — the estate file is missing: $_estate" >&2
    echo "registry: it must contain the line $_nyckel=\"...\"." >&2
    echo "registry: an estate's names are never guessed — the product knows the mechanism, the estate its own names." >&2
    return 78
  fi
  # Every key is cleared locally BEFORE the source: a previously set global in
  # the caller's environment must not survive an empty or missing line in the
  # file and look like an answer.
  local RC_LABEL_PREFIX="" HUB_SESSION="" JOB_LOG_DIR="" HUB_SSH="" TMUX_SOCKET="" PING_MSG="" HUB_HOST="" \
        JOB_LABEL_PREFIX="" SERVICE_LABEL_PREFIX="" BROWSER_LABEL_PREFIX="" OP_TOKEN_FILE_NAME="" \
        STATE_DIR_NAME="" PAUSED_DIR_NAME=""
  # shellcheck source=/dev/null
  if ! source "$_estate"; then
    echo "registry: REFUSING — the estate file could not be read: $_estate" >&2
    return 78
  fi
  local _varde=""
  case "$_nyckel" in
    RC_LABEL_PREFIX) _varde="$RC_LABEL_PREFIX" ;;
    HUB_SESSION)     _varde="$HUB_SESSION" ;;
    HUB_HOST)        _varde="$HUB_HOST" ;;
    JOB_LOG_DIR)     _varde="$JOB_LOG_DIR" ;;
    HUB_SSH)         _varde="$HUB_SSH" ;;
    TMUX_SOCKET)     _varde="$TMUX_SOCKET" ;;
    PING_MSG)        _varde="$PING_MSG" ;;
    JOB_LABEL_PREFIX)     _varde="$JOB_LABEL_PREFIX" ;;
    SERVICE_LABEL_PREFIX) _varde="$SERVICE_LABEL_PREFIX" ;;
    BROWSER_LABEL_PREFIX) _varde="$BROWSER_LABEL_PREFIX" ;;
    OP_TOKEN_FILE_NAME)   _varde="$OP_TOKEN_FILE_NAME" ;;
    STATE_DIR_NAME)       _varde="$STATE_DIR_NAME" ;;
    PAUSED_DIR_NAME)      _varde="$PAUSED_DIR_NAME" ;;
    *) echo "registry: unknown estate key '$_nyckel'" >&2; return 70 ;;
  esac
  if ! [[ "$_varde" =~ $_form ]]; then
    echo "registry: REFUSING — $_nyckel is missing or invalid in $_estate" >&2
    echo "registry: got '${_varde}', expected the form $_form" >&2
    return 78
  fi
  printf '%s\n' "$_varde"
}

# RC_LABEL_PREFIX forms the session's identity in the process table. THE FORM ALLOWS
# A TRAILING SPACE IS ALLOWED deliberately: the space belongs to the label. A
# form that trimmed it would silently change the pattern supervision matches
# against, which is exactly the damage this key exists to prevent.
registry_rc_label_prefix() { _registry_estate_value RC_LABEL_PREFIX '^[A-Za-z0-9][A-Za-z0-9 :._-]*$'; }

# HUB_SESSION is the hub's name on the bus — a session name, so the same form the
# name validator requires.
registry_hub_session()    { _registry_estate_value HUB_SESSION '^[a-z0-9][a-z0-9-]*$'; }

# HUB_HOST is the hub's MACHINE name — the same form as a host name in the
# registry, and deliberately a SEPARATE key even though it holds the same string
# as HUB_SESSION in this estate. See the estate file for why.
registry_hub_host()       { _registry_estate_value HUB_HOST '^[a-z0-9][a-z0-9-]*$'; }

# The three label prefixes and the token file's name. A prefix has the form of a
# reversed domain: dot-separated segments, no trailing dot — a typo with a
# trailing dot would produce labels with a doubled dot, which launchd accepts and
# no later glob finds.
registry_job_label_prefix()     { _registry_estate_value JOB_LABEL_PREFIX     '^[A-Za-z0-9][A-Za-z0-9_-]*(\.[A-Za-z0-9][A-Za-z0-9_-]*)+$'; }
registry_service_label_prefix() { _registry_estate_value SERVICE_LABEL_PREFIX '^[A-Za-z0-9][A-Za-z0-9_-]*(\.[A-Za-z0-9][A-Za-z0-9_-]*)+$'; }
registry_browser_label_prefix() { _registry_estate_value BROWSER_LABEL_PREFIX '^[A-Za-z0-9][A-Za-z0-9_-]*(\.[A-Za-z0-9][A-Za-z0-9_-]*)+$'; }
# A FILE NAME, NEVER A PATH — the same reason as JOB_LOG_DIR and TMUX_SOCKET.
registry_op_token_name()        { _registry_estate_value OP_TOKEN_FILE_NAME   '^[A-Za-z0-9][A-Za-z0-9._-]*$'; }

# Supervision's two state directory NAMES, never paths — the same reason as
# JOB_LOG_DIR: a slash would let a typo wander out of the state tree.
registry_state_dir_name()       { _registry_estate_value STATE_DIR_NAME       '^[A-Za-z0-9][A-Za-z0-9._-]*$'; }
registry_paused_dir_name()      { _registry_estate_value PAUSED_DIR_NAME      '^[A-Za-z0-9][A-Za-z0-9._-]*$'; }

# registry_label_prefixes — sets the three globals, or REFUSES with rc 78.
#
# A FUNCTION OF ITS OWN, NOT A LOOKUP AT SOURCE TIME. The prefixes were literals
# at top level, and the installer reads them as GLOBALS to glob out installed
# units: `for p in "$dir/$SERVICE_LABEL_PREFIX".*.plist`. An empty prefix makes
# that glob WIDE OPEN — it would match every plist in the directory, including
# other people's, in a routine that BOOTS OUT what it finds. So they are never
# quietly left empty: either all three stand, or the function refuses and the
# caller aborts.
#
# And not at source time either: a lookup there would make the WHOLE library
# refuse to load whenever the estate is absent, even for callers that only want
# to list sessions. The same mistake was made the same day in the hub's bus
# library and was caught by its test.
registry_label_prefixes() {
  JOB_LABEL_PREFIX="$(registry_job_label_prefix)"         || return 78
  SERVICE_LABEL_PREFIX="$(registry_service_label_prefix)" || return 78
  BROWSER_LABEL_PREFIX="$(registry_browser_label_prefix)" || return 78
  return 0
}

# JOB_LOG_DIR is ONE directory name, never a path: a slash would let a typo
# wander out of the log tree and write logs anywhere.
registry_job_log_dir()    { _registry_estate_value JOB_LOG_DIR '^[A-Za-z0-9][A-Za-z0-9._-]*$'; }

# HUB_SSH is the bus relay's ssh target, <user>@<host>. The form requires BOTH
# parts: a bare host name would make ssh use the CALLING account's name, which on
# a multi-tenant machine is the wrong account rather than the intended one — and
# the fault first appears as a rejected key exchange, far from its cause.
registry_hub_ssh()        { _registry_estate_value HUB_SSH '^[A-Za-z0-9._-]+@[A-Za-z0-9._-]+$'; }

# TMUX_SOCKET is ONE FILE NAME under ~/.tmux, never a path — the same reason as
# JOB_LOG_DIR: a slash would name another server's socket.
registry_tmux_socket()    { _registry_estate_value TMUX_SOCKET '^[A-Za-z0-9][A-Za-z0-9._-]*$'; }

# PING_MSG is free text and therefore has the widest form in this file. A
# narrower one would reject the estate's own string (it carries an em dash and
# parentheses), and a guard that rejects the value it exists to protect gets
# switched off. The only requirements are that it is not EMPTY and not
# multi-line — an empty ping would be invisible, and a multi-line one would be
# typed as several keystrokes into a live pane.
#
# THE FORM WAS FIRST '^[^\n]+$', AND IT REFUSED THE ESTATE'S OWN VALUE. In a
# regular expression, \n inside a bracket class is not a newline but the
# characters \ and n — so the class excluded the letter n, which appears in
# almost every sentence.
#
# AND THE FIRST CORRECTION CARRIED A FALSE CLAIM: that the anchors alone reject a
# multi-line value. They do not. grep matches LINE BY LINE, so '^.+$' matches the
# first line and lets the rest through — measured, not assumed. The newline check
# below makes the claim true instead of softening it.
registry_ping_msg() {
  local _v
  _v="$(_registry_estate_value PING_MSG '^.+$')" || return 78
  case "$_v" in
    *"
"*) echo "registry: REFUSING — PING_MSG is multi-line." >&2
        echo "registry: knuffen skrivs i en LEVANDE panel; flera rader blir flera" >&2
        echo "registry: keystrokes, and the second can land as user input." >&2
        return 78 ;;
  esac
  printf '%s\n' "$_v"
}

# registry_liveness_cmd — the estate's own liveness shim, or the empty string.
#
# THE ONE OPTIONAL FIELD IN THIS FILE, AND THAT IS WHY IT IS NOT A CASE IN
# _registry_estate_value. Every key that function serves is REQUIRED: a
# missing RC_LABEL_PREFIX or HUB_HOST is a broken estate and rc 78 says so.
# LIVENESS_CMD is different — it started life outside the estate file
# entirely, as the operator's own STEWARD_LIVENESS_CMD, and an estate that
# has not declared one yet is not broken, it simply has not opted in. Folding
# a fourth outcome ("absent is fine, just for THIS key") into the shared
# reader would give every other caller of that reader a branch to get wrong.
#
# THE THREE OUTCOMES, KEPT DISTINCT ON PURPOSE:
#   - no estate file, or the file lacks the line  -> prints nothing, rc 0
#   - the line is present and well-formed          -> prints the value, rc 0
#   - the line is present and INVALID               -> rc 78
# An operator who wrote a relative path deserves a refusal, not a silent
# fallback to `seam-not-configured` that reads exactly like never having
# written the line at all — that collapse is the whole reason this is its
# own function instead of one more line in _registry_estate_value.
#
# SAME FILE, SAME "local BEFORE source" DISCIPLINE as every reader above: a
# stale global from the caller's own shell must not survive an estate file
# that never mentions LIVENESS_CMD, and a value the estate file sets must
# never leak past this function's return.
registry_liveness_cmd() {
  local _estate; _estate="$(registry_estate_file)"
  # NO ESTATE FILE AT ALL is not this function's refusal to make — plenty of
  # other readers already refuse for that, the moment they are asked for a
  # REQUIRED field. This field is optional, so absence of the whole file
  # reads the same as absence of the one line: nothing to report, rc 0.
  [ -f "$_estate" ] || { printf ''; return 0; }
  local LIVENESS_CMD=""
  # shellcheck source=/dev/null
  if ! source "$_estate"; then
    echo "registry: REFUSING — the estate file could not be read: $_estate" >&2
    return 78
  fi
  [ -n "$LIVENESS_CMD" ] || { printf ''; return 0; }
  # Absolute path only — the same regex the binding spec names. A relative
  # one would resolve against whatever directory happened to be current when
  # the seam ran, which is not a thing a liveness command may depend on.
  if ! [[ "$LIVENESS_CMD" =~ ^/[A-Za-z0-9/._-]+$ ]]; then
    echo "registry: REFUSING — LIVENESS_CMD in $_estate is not an absolute path: '$LIVENESS_CMD'" >&2
    echo "registry: expected the form ^/[A-Za-z0-9/._-]+\$ — got '$LIVENESS_CMD'" >&2
    return 78
  fi
  printf '%s\n' "$LIVENESS_CMD"
}

# registry_estate_checkout — where the estate's own git working copy lives, or
# the empty string.
#
# THE DISTINCTION THIS KEY EXISTS FOR: the estate has TWO roots on the hub, and
# until now only one of them had a name. STEWARD_ESTATE_ROOT names the
# RUNTIME image (~/scripts on a deployed hub) — what the machine reads. The
# CHECKOUT is what the machine is deployed FROM, and what git remembers.
#
# A writer that only knows the runtime root writes rows that the next deploy
# deletes: the deploy builds a keep-list from the checkout and prunes the
# runtime directory against it, and every host installs from the checkout. That
# is a real cost already paid — a session enrolled through the bus lost its
# registry row on the next install while its key line and timer survived.
#
# OPTIONAL, AND OPTIONAL THE SAME WAY registry_liveness_cmd IS — same three
# outcomes, same reasons, same "local before source" discipline:
#   - no estate file, or no ESTATE_CHECKOUT line -> prints nothing, rc 0
#   - present and well-formed                    -> prints the value, rc 0
#   - present and INVALID                        -> rc 78
# An estate that has not declared a checkout is not broken; a caller that gets
# the empty string is expected to say so loudly rather than guess a path. And
# an operator who wrote a relative path deserves a refusal, not a directory
# resolved against whatever happened to be the current one.
#
# STEWARD_ESTATE_CHECKOUT overrides, as every other resolution here allows.
registry_estate_checkout() {
  if [ -n "${STEWARD_ESTATE_CHECKOUT:-}" ]; then
    printf '%s\n' "$STEWARD_ESTATE_CHECKOUT"
    return 0
  fi
  local _estate; _estate="$(registry_estate_file)"
  [ -f "$_estate" ] || { printf ''; return 0; }
  local ESTATE_CHECKOUT=""
  # shellcheck source=/dev/null
  if ! source "$_estate"; then
    echo "registry: REFUSING — the estate file could not be read: $_estate" >&2
    return 78
  fi
  [ -n "$ESTATE_CHECKOUT" ] || { printf ''; return 0; }
  if ! [[ "$ESTATE_CHECKOUT" =~ ^/[A-Za-z0-9/._-]+$ ]]; then
    echo "registry: REFUSING — ESTATE_CHECKOUT in $_estate is not an absolute path: '$ESTATE_CHECKOUT'" >&2
    echo "registry: expected the form ^/[A-Za-z0-9/._-]+\$ — got '$ESTATE_CHECKOUT'" >&2
    return 78
  fi
  printf '%s\n' "$ESTATE_CHECKOUT"
}

registry_dir() {
  if [ -n "${STEWARD_REGISTRY_DIR:-}" ]; then
    printf '%s\n' "$STEWARD_REGISTRY_DIR"
  else
    printf '%s\n' "$(_registry_estate_root)/sessions.d"
  fi
}

# A MISSING DIRECTORY IS NOT AN EMPTY ONE, and the difference is the whole
# reason this line changed. `sessions.d` absent means the estate is broken or
# the resolver is pointed somewhere wrong; `sessions.d` present and empty means
# nobody has declared a session yet. Both used to print nothing and return 0.
#
# MEASURED 2026-08-23. The same shape, one level up, made browser-stack report
# "0 rig(s) ensured" with rc 0 on a host where every rig was declared — it cost
# hours, because "0 rigs" reads as "none declared". And the estate's
# verify-rendered-plists.sh iterates this list: with nothing returned its loop
# ran zero times, `fail` stayed 0, and the gate that protects live sessions from
# a bad deploy certified safety WITHOUT COMPARING ANYTHING.
#
# stdout stays empty either way — callers that pipe cannot see a status. The
# signal is the exit code plus a line on stderr, so a caller that checks gets
# the truth and a caller that does not is at least visibly told.
registry_list() {
  local dir; dir="$(registry_dir)"
  if [ ! -d "$dir" ]; then
    echo "registry: REFUSING to list — the registry directory does not exist: $dir" >&2
    echo "  An empty sessions.d means zero sessions; a missing one means the estate" >&2
    echo "  is broken, or STEWARD_REGISTRY_DIR is aimed at the wrong place." >&2
    return 78
  fi
  local f name
  for f in "$dir"/*.conf; do
    [ -e "$f" ] || continue
    name="$(basename "$f" .conf)"
    printf '%s\n' "$name"
  done | sort
}

registry_valid_name() {
  [[ "${1:-}" =~ ^[a-z0-9-]+$ ]]
}

registry_validate_runtime_set() {
  local project port projects seen_ports="" seen_port seen_project
  projects="$(registry_list)" || return 1
  while IFS= read -r project; do
    [ -n "$project" ] || continue
    port="$(
      registry_load "$project" || exit $?
      if [ "$RUNTIME" = "opencode" ]; then printf '%s' "$OPENCODE_PORT"; fi
    )" || return 1
    [ -n "$port" ] || continue
    while IFS=: read -r seen_port seen_project; do
      [ -n "$seen_port" ] || continue
      if [ "$seen_port" = "$port" ]; then
        echo "registry: OpenCode port $port conflicts between $seen_project and $project" >&2
        return 1
      fi
    done <<< "$seen_ports"
    seen_ports="${seen_ports}${port}:${project}
"
  done <<< "$projects"
}

registry_load() {
  # THE SCHEMA GATE, WIRED. Until 2026-08-25 registry_schema_check existed and
  # nothing called it: the estate declared a version, the library knew how to
  # compare it, and no path ever asked. A gate with no caller is indistinguishable
  # from no gate at all, and the difference only shows up as damage.
  #
  # IT COMES FIRST, before the conf is even located. A checkout that cannot
  # understand this register must not begin interpreting it — refusing on a field
  # it half-knows would report the wrong cause and send the reader after the
  # wrong bug.
  registry_schema_check || return 78
  local project="${1:-}"
  if ! registry_valid_name "$project"; then
    echo "registry: invalid project name '$project' (allowed: a-z 0-9 -)" >&2
    return 1
  fi
  local conf; conf="$(registry_dir)/$project.conf"
  if [ ! -f "$conf" ]; then
    echo "registry: unknown project '$project' (no $conf)" >&2
    return 1
  fi
  # Reset before sourcing so a prior load never leaks into this one.
  REPO_PATH=""; RC_LABEL=""; ENV_REFRESH=""; PERMISSION_MODE=""; OP_RUN=""; ENV_FILE=""; RC_FRI=""
  ID=""; KIND=""; LIFECYCLE=""; ASSETS=""
  ACCOUNT=""; SLUG=""; TARGET_ENTITY=""; TARGET_PROJECT=""
  VISIBILITY=""; VISIBLE_TO=""
  OP_TOKEN_FILE=""; OWNER=""; DOMAIN=""; ENV_SOURCE=""; HOST=""
  BROWSER_RIG=""; BROWSER_DISPLAY=""; BROWSER_CDP=""; BROWSER_VNC=""; BROWSER_PROFILE=""
  RUNTIME=""; MODEL=""; OPENCODE_VERSION=""; OPENCODE_PORT=""; AUTO_APPROVE=""; CLAUDE_MEMORY_ROOT=""
  # shellcheck source=/dev/null
  source "$conf"
  : "${PERMISSION_MODE:=bypassPermissions}"
  : "${RUNTIME:=claude-code}"
  case "$RUNTIME" in claude-code|opencode) ;; *) return 1 ;; esac
  case "$RUNTIME" in
    opencode)
      [[ "$MODEL" =~ ^[A-Za-z0-9._-]+/[A-Za-z0-9._:-]+$ ]] || return 1
      [[ "$OPENCODE_VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || return 1
      [[ "$OPENCODE_PORT" =~ ^[0-9]+$ ]] && [ "$OPENCODE_PORT" -ge 1024 ] && [ "$OPENCODE_PORT" -le 65535 ] || return 1
      case "$AUTO_APPROVE" in true|false) ;; *) return 1 ;; esac
      [[ "$CLAUDE_MEMORY_ROOT" = /* ]] && [[ "$CLAUDE_MEMORY_ROOT" != *".."* ]] || return 1
      ;;
    claude-code)
      [ -z "$OPENCODE_VERSION$OPENCODE_PORT" ] || return 1
      ;;
  esac
  # HOST: which machine the session LIVES on (2026-08-06). Defaults to the hub
  # from the estate — every existing conf is unchanged. A session with a
  # different HOST is owned by the registry but NEVER rendered to launchd here:
  # the installer and the gates skip it, and the bus reads the field to know where
  # a message should go. The name must match an ssh alias in ~/.ssh/config.
  local _hubhost; _hubhost="$(registry_hub_host)" || return 78
  : "${HOST:=$_hubhost}"
  if ! [[ "$HOST" =~ ^[a-z][a-z0-9-]*$ ]]; then
    echo "registry: $project.conf invalid HOST '$HOST'" >&2; return 1
  fi
  # ENV_FILE: WHERE the materialised .env lands. Default = the repository root,
  # exactly as before. Set to a path OUTSIDE the repository, cwd stops carrying
  # secrets — reading Bash commands inside the working directory are auto-approved
  # (verified 2026-08-02), so a .env in cwd is readable regardless of tool and
  # permission blocks. Affects NO rendered plist: a session plist carries only
  # HOME/PATH and the project name.
  : "${ENV_FILE:=$REPO_PATH/.env}"
  : "${OP_RUN:=}"
  # ENV_SOURCE=1: source $REPO_PATH/.env into the session env before exec claude
  # (so .mcp.json ${VAR} secrets resolve) WITHOUT op — for domains whose .env is
  # materialized by ENV_REFRESH (e.g. via sops). OP_RUN already sources .env.
  : "${ENV_SOURCE:=}"
  if [ -z "$REPO_PATH" ]; then echo "registry: $project.conf missing REPO_PATH" >&2; return 1; fi
  # ── THE IDENTITY FIELDS (naming-model design, 2026-08-30) ────────────────
  # ACCOUNT      which (principal, host) account the session belongs to —
  #              references an accounts.d slug.
  # SLUG         the session's short name, unique within its ACCOUNT.
  # TARGET_*     what the session works ON — a reference the display is
  #              DERIVED from, never a stored label.
  #
  # READ LENIENTLY: a gap is not a failure. Every conf that predates the
  # model omits all four, and omission must read EXACTLY as before — the
  # fields are validated for SHAPE only, and only when non-empty. They are
  # never RESOLVED here: an account or target that does not exist in its
  # register is a gap for the reader, and strictness belongs to the writer
  # that sets the fields. (The composite (ACCOUNT, SLUG) uniqueness gate,
  # registry_account_slug_available above, stays unwired for the same
  # reason — it is the writer's gate, not the reader's.)
  #
  # The shape refused here is refused for the same reason OWNER's is: these
  # values index other registers, so a path escape or a control byte would
  # reach outside the register the moment a consumer built a path from one.
  local _idf
  for _idf in ACCOUNT SLUG TARGET_ENTITY TARGET_PROJECT; do
    if [ -n "${!_idf}" ] && ! [[ "${!_idf}" =~ ^[a-z0-9][a-z0-9-]*$ ]]; then
      echo "registry: $project.conf invalid $_idf (allowed: a-z 0-9 and hyphen, starting with a letter or digit)" >&2
      return 1
    fi
  done
  # THE TARGET IS A TYPED UNION. A session works on a project OR directly on
  # an entity (a team session with no project is legitimate) — a row claiming
  # both is two contradictory claims about the same session, and picking one
  # silently would make the display disagree with whichever claim lost.
  if [ -n "$TARGET_ENTITY" ] && [ -n "$TARGET_PROJECT" ]; then
    echo "registry: $project.conf sets both TARGET_ENTITY and TARGET_PROJECT — the target is a typed union, declare exactly one" >&2
    return 1
  fi
  # RC-FREE SESSION: THE MACHINE SESSION. One standing session per machine under
  # the machine steward's account, started WITHOUT --remote-control. It is reached
  # over the bus and through the client's peek/attach.
  #
  # RC-FREE MEANS UNSTEERABLE, NOT INVISIBLE — and this comment claimed the
  # opposite until 2026-08-23. MEASURED that day on a machine session: no process
  # in the tree carries --remote-control, and the session is registered with the
  # vendor's bridge anyway. ~/.claude/sessions/<pid>.json holds a bridgeSessionId,
  # written live, over a separate connection from the API host.
  #
  # The bridge registers every interactive CLI session regardless of the flag. So
  # an empty label buys exactly one thing: nobody can drive the session remotely.
  # It does not hide it. Anyone choosing RC-free for discretion rather than for
  # control is getting half of what they asked for, and should know which half.
  #
  # EMPTY IS NOT MISSING, AND THE DIFFERENCE IS WHETHER THE LINE IS THERE. After
  # `source`, an empty variable and an omitted one are indistinguishable — which
  # is why the conf is re-read here. Three cases, and they are the SAME ones
  # linux/session-supervisor-linux.sh already implements; a second mechanism for
  # the same thing would have become two truths about it, and the stale one
  # answers rather than refuses.
  #
  #   RC_LABEL="Something" -> ordinary session (unchanged)
  #   RC_LABEL=""          -> RC-FREE machine session, a CHOICE
  #   no RC_LABEL line     -> REFUSAL here (a FORGOTTEN label must never quietly
  #                           become an invisible session; the Linux supervisor
  #                           instead builds a prefixed name for older estates)
  if grep -q '^RC_LABEL=' "$conf" 2>/dev/null; then
    RC_FRI=""
    [ -z "$RC_LABEL" ] && RC_FRI="yes"
  elif [ -n "$TARGET_ENTITY$TARGET_PROJECT" ]; then
    # A NEW-SHAPE row: the display is a REFERENCE (the target above), not a
    # stored label, so there is no label line to forget — the refusal below
    # exists to catch a FORGOTTEN label, and nothing is forgotten here.
    # registry_session_display derives the string. An old-shape row (no
    # target fields) never reaches this branch and refuses exactly as before.
    RC_FRI=""
  else
    echo "registry: $project.conf missing RC_LABEL (write RC_LABEL=\"\" for an RC-free machine session)" >&2
    return 1
  fi
  # ID: the name that is KEYED ON, as opposed to RC_LABEL which is DISPLAYED.
  #
  # WHY THEY ARE TWO. A displayed name must be free to change — a project gets
  # renamed, a client rebrands. A keyed name must never change, because history,
  # credentials, mailboxes and installed daemons hang off it. Until 2026-08-25
  # they were one string, and the day the two needs pulled apart neither could
  # move without breaking the other.
  #
  # THE FALLBACK IS A MIGRATION, NOT A DEFAULT. Today's file name is already
  # unique, already stable and already what everything keys on, so adopting it
  # changes nothing and makes an existing truth explicit. It stays only until
  # every conf carries the line.
  : "${ID:=$project}"
  if ! [[ "$ID" =~ ^[a-z][a-z0-9-]*$ ]]; then
    echo "registry: $project.conf invalid ID (lower-case a-z 0-9 and hyphen)" >&2
    return 1
  fi
  # KIND: what sort of session this is, stated ONCE.
  #
  #   work     — the ordinary case: a session doing a project's work.
  #   infra    — its subject is the MACHINE. No entity, no project.
  #   advisor  — it reviews on request. One or two in a whole fleet.
  #
  # ONE FACT, THREE ENCODINGS was the state before this line. A machine session
  # was recognisable by an owner that was a service account, by a domain that
  # said "machine", and by being RC-free — and the bus read the third. None of
  # them was authoritative, and the two machine sessions in the estate this was
  # written for encoded it in two different ways.
  #
  # THE SET IS CLOSED. A typo that read as a fourth kind would be treated as
  # "none of the three" by everything that branches on it — a silent half
  # behaviour rather than a refusal.
  # NAMESPACE WARNING: KIND IS OWNED TWICE IN THIS FILE. registry_job_load below
  # uses the same global for a DIFFERENT closed set (claude|command). Nothing
  # breaks today because both loaders reset their globals before sourcing — the
  # safety comes from that reset, not from design. Anything that starts BRANCHING
  # on KIND across both loaders must rename one of them first.
  #
  # ID has the same shape of problem: it is the name /etc/os-release sets, and
  # this library is sourced into scripts that read it that way.
  : "${KIND:=work}"
  case "$KIND" in
    work|infra|advisor) ;;
    *) echo "registry: $project.conf invalid KIND '$KIND' (work, infra or advisor)" >&2; return 1 ;;
  esac
  # LIFECYCLE: whether this session is meant to be running.
  #
  #   active     — the ordinary case.
  #   suspended  — deliberately off. Status must say so, never "healthy".
  #   retired    — gone for good; the row is a tombstone.
  #
  # WHY A TOMBSTONE AND NOT A DELETION. Removing a row from git stops no timer,
  # revokes no bus key, frees no port and cleans no disk — and it can come back
  # from an old clone. A retirement that is only an absence cannot be told from
  # a row nobody has written yet.
  #
  # RECORDED HERE, ACTED ON NOWHERE. Refusing to load a retired conf would be a
  # behaviour change arriving without anyone choosing it, with live
  # conversations in the room. A later plan moves that boundary deliberately.
  : "${LIFECYCLE:=active}"
  case "$LIFECYCLE" in
    active|suspended|retired) ;;
    *) echo "registry: $project.conf invalid LIFECYCLE '$LIFECYCLE' (active, suspended or retired)" >&2; return 1 ;;
  esac
  # OWNER: the macOS user the session runs as. Required and validated because the
  # installer runs as root and renders it into UserName and every path — never guess.
  if ! [[ "$OWNER" =~ ^[a-z][a-z0-9-]*$ ]]; then
    echo "registry: $project.conf missing/invalid OWNER (macOS username, a-z 0-9 -)" >&2
    return 1
  fi
  # DOMAIN: which business the session belongs to. The
  # machine layer only carries it; fleet and reporting group by it.
  #
  # LEGACY ON A NEW-SHAPE ROW (2026-08-30). A row that carries a target
  # reference stores no DOMAIN line — the target IS the grouping — so the
  # legacy value is DERIVED for old consumers: the target's own slug,
  # already shape-validated above. A derivation, never a guess, and never a
  # RESOLUTION — the reader does not walk the target's parent chain here
  # (that belongs to the display derivation); a consumer that needs the
  # owning ENTITY of a project-targeted row resolves the reference itself.
  # An old-shape row without DOMAIN refuses exactly as before.
  if [ -z "$DOMAIN" ] && [ -n "$TARGET_ENTITY$TARGET_PROJECT" ]; then
    DOMAIN="${TARGET_PROJECT:-$TARGET_ENTITY}"
  fi
  if ! [[ "$DOMAIN" =~ ^[a-z0-9-]+$ ]]; then
    echo "registry: $project.conf missing/invalid DOMAIN (a-z 0-9 -)" >&2
    return 1
  fi
  case "$RC_LABEL" in
    *\'*) echo "registry: $project.conf RC_LABEL must not contain a single quote" >&2; return 1 ;;
  esac
  # BROWSER_RIG=yes: this session wants a browser rig — an Xvfb screen, a
  # Chromium with DevTools, and a VNC view of it. OPT-IN, never a default: a rig
  # costs about 30 MB of screen plus a browser, and most sessions never need one.
  #
  # THE UNIT IS THE SESSION. One session = one rig = one profile, and the profile
  # name IS the session name. The alternative — a rig per client or per profile —
  # needs a second name to exist and a second place to keep it in step.
  #
  # THE THREE NUMBERS ARE ASSIGNED, NOT DERIVED. Deriving them from the session
  # name has no way out of a collision (nobody renames a session because a port
  # is taken) and, worse, FREES the number when a session is removed — while this
  # tool's own rule is that a display number must never be reused, because a
  # number that changes meaning makes old notes misleading. They are therefore
  # written into the conf once and stay there.
  #
  # WHY THE ALLOCATOR MUST SEE EVERY HOME. Homes are 750: no account can list
  # another's rigs, so an account that hands out its own numbers is guessing —
  # which is how one host ended up with three rigs in one account's range and a
  # fourth wedged inside it. The block scheme lives with whoever holds the
  # registry; see the rig documentation for the ranges.
  if [ -n "$BROWSER_RIG" ] && [ "$BROWSER_RIG" != "yes" ]; then
    echo "registry: $project.conf BROWSER_RIG must be 'yes' or unset (got '$BROWSER_RIG')" >&2
    return 1
  fi
  if [ -n "$BROWSER_RIG" ]; then
    # ALL THREE OR REFUSE. A rig with two numbers starts on a screen nobody can
    # see, or answers on a port nobody grants — and both look like a working rig
    # from the outside.
    local _f
    for _f in BROWSER_DISPLAY BROWSER_CDP BROWSER_VNC; do
      if ! [[ "${!_f}" =~ ^[0-9]+$ ]]; then
        echo "registry: $project.conf BROWSER_RIG=yes needs a numeric $_f (got '${!_f}')" >&2
        return 1
      fi
    done
    # BROWSER_PROFILE: which Chromium profile directory the rig opens. Defaults
    # to the session name — that IS the rule — but a default is not the same
    # thing as a rule, and this field exists because a fleet predates it.
    #
    # A PROFILE IS LOGGED-IN STATE AND THE MISMATCH IS SILENT. Aim a rig at a
    # profile name that does not exist and the browser creates an empty one: the
    # rig starts, the window opens, the VNC view shows it, everything reports
    # success — and gigabytes of sessions and cookies sit untouched in the
    # directory beside it with nobody looking for them. That is worse than
    # losing the state; it is A SUCCESSFUL OUTCOME THAT HIDES THAT THE STATE DID
    # NOT COME ALONG.
    #
    # Measured on one host 2026-08-21: five profile directories, only two named
    # after a session. One held 1.6 GB of logins, last written the day its rig
    # died — its session had been renamed since.
    : "${BROWSER_PROFILE:=$project}"
    if ! registry_valid_name "$BROWSER_PROFILE"; then
      echo "registry: $project.conf invalid BROWSER_PROFILE '$BROWSER_PROFILE' (allowed: a-z 0-9 -)" >&2
      return 1
    fi
  elif [ -n "$BROWSER_DISPLAY$BROWSER_CDP$BROWSER_VNC$BROWSER_PROFILE" ]; then
    # Numbers without the opt-in are the silent case: they look like a declared
    # rig and start nothing. Say so rather than ignoring them.
    echo "registry: $project.conf has BROWSER_* settings but no BROWSER_RIG=yes — the rig will NOT start" >&2
    return 1
  fi
  # VISIBILITY AND VISIBLE_TO — who, besides the owner, may see this session.
  #
  # THIS IS A RENDERING RULE, NOT ACCESS CONTROL. The registry is readable and
  # a caller can set STEWARD_REGISTRY_DIR to any directory; what these fields
  # buy is that the tools do not show, and do not offer, what the viewer is
  # not meant to work on. The real boundary is file permissions on the hosts.
  #
  # THE VOCABULARY IS CLOSED at one word. `private` withdraws a session from the
  # derived team view; absence means the ordinary derivation applies. A third
  # word would be a declaration whose meaning no consumer knows.
  case "${VISIBILITY:-}" in
    ""|private) ;;
    *) echo "registry: $project.conf invalid VISIBILITY '$VISIBILITY' (allowed: private, or omit)" >&2
       return 1 ;;
  esac
  # EVERY NAME IN THE LIST IS CHECKED, not just the first: a list validated by
  # its head is a list something appends to. The names index entity confs, so a
  # value containing a slash or a leading dot would reach outside the entity
  # directory the moment a consumer built a path from it.
  #
  # THE SPLIT IS WANTED; THE GLOB IS NOT. An unquoted `$VISIBLE_TO` is word
  # splitting AND pathname expansion, and the expansion happens DURING the
  # split — so the per-entry check above would validate whatever the CALLER'S
  # WORKING DIRECTORY happened to contain instead of what the conf says.
  # Measured 2026-08-28 with VISIBLE_TO="*", the same conf and the same loader,
  # only the directory differing: a cwd holding a file named after a real group
  # loaded rc 0 with the asterisk silently replaced; a cwd holding a plain
  # notes file refused rc 1; a cwd holding the entity directory refused too.
  # A field whose meaning is decided by the reader's cwd is not validated.
  #
  # THE SPLIT IS CAPTURED INTO AN ARRAY rather than looped under `set -f`,
  # because this loop RETURNS from inside itself — a restore placed after the
  # loop would be skipped on the refusal path and leave globbing disabled in
  # the caller's shell. One line under the flag, then the flag goes back.
  if [ -n "${VISIBLE_TO:-}" ]; then
    local _had_f; case "$-" in *f*) _had_f=1 ;; *) _had_f="" ;; esac
    set -f
    # shellcheck disable=SC2206  # splitting is intended here; globbing is off
    local _vt_entries=( $VISIBLE_TO )
    [ -n "$_had_f" ] || set +f
    local _g
    for _g in "${_vt_entries[@]+"${_vt_entries[@]}"}"; do
      if ! registry_valid_name "$_g"; then
        echo "registry: $project.conf invalid VISIBLE_TO entry '$_g' (allowed: a-z 0-9 -)" >&2
        return 1
      fi
    done
  fi
  OWNER_HOME="/Users/$OWNER"
  # Per-project secrets service account (a domain may have its own vault and account).
  local _optok; _optok="$(registry_op_token_name)" || return 78
  : "${OP_TOKEN_FILE:=$OWNER_HOME/.config/op/$_optok}"
  SESSION_NAME="$project"
  # The prefix is resolved HERE and the load fails with the same rc 78 if it
  # cannot be. The alternative — letting the label become empty or unset and be
  # discovered later — is exactly the silent failure the rest of this file is
  # built against.
  local _prefix
  if ! _prefix="$(registry_label_prefix)"; then
    echo "registry: $project.conf could not be given a launchd label (see the lines above)" >&2
    return 78
  fi
  LAUNCHD_LABEL="$_prefix.$project"
  # Owner-home-based (not $HOME) so paths stay correct when the installer runs as
  # root (where $HOME is /var/root).
  if [ "$RUNTIME" = "opencode" ]; then
    LOG_PATH="$OWNER_HOME/.local/state/$(registry_state_dir_name)/$project.log"
  else
    LOG_PATH="$OWNER_HOME/.claude/claude-$project.log"
  fi
}

# registry_session_display <session> — prints the session's display string.
# THE ONE PLACE a session's display is computed: a consumer that shows a
# session (supervisor, cockpit, status) calls this instead of reading
# RC_LABEL raw, so the derivation has a single owner when it changes.
#
# PRECEDENCE, in order:
#   1. RC_LABEL non-empty        -> printed VERBATIM. The legacy override: a
#                                   row that carries a label has chosen its
#                                   display, byte-identical to what the
#                                   supervisor shows today.
#   2. TARGET_PROJECT            -> registry_display_for project (root→leaf).
#   3. TARGET_ENTITY             -> registry_display_for entity.
#   4. neither                   -> prefix+name, the EXACT construction the
#                                   Linux supervisor builds when a conf has
#                                   no RC_LABEL line — the old-shape path,
#                                   and it must not change what old sessions
#                                   display.
#
# A target that fails to derive (renamed away, a forged NAME) PROPAGATES
# registry_display_for's refusal — a display is never invented, because an
# invented one would look exactly like a working derivation.
#
# DISPLAY IS PRESENTATION, NEVER IDENTITY. Nothing may match a process, a
# pane or a bus address against this string — supervision keys on ID +
# ACCOUNT (+ tmux/pid). Duplicates between sessions are deliberate.
#
# THE LOAD IS SUBSHELLED and the fields are SNAPSHOTTED out. registry_load
# sources an untrusted conf; run in this function's own shell, a row
# assigning this function's lowercase locals would clobber them via dynamic
# scoping the moment the row sourced. Everything the conf can influence
# crosses the boundary as printed field values only; the name used by the
# fallback is this function's own argument, captured before any load runs.
registry_session_display() {
  local slug="${1:-}"
  if ! registry_valid_name "$slug"; then
    echo "registry: registry_session_display: invalid session name '$slug' (allowed: a-z 0-9 -)" >&2
    return 1
  fi
  local conf; conf="$(registry_dir)/$slug.conf"
  if [ ! -f "$conf" ]; then
    echo "registry: registry_session_display: unknown session '$slug' (no $conf)" >&2
    return 1
  fi
  # THE OLDER-ESTATE SHAPE: no RC_LABEL line and no target reference.
  # registry_load REFUSES that conf (a forgotten label must never quietly
  # become an invisible session) — but the supervisor serves those estates
  # by BUILDING the label as prefix+name, and this projection must match it
  # byte-for-byte. Detected the same way both registry_load and the
  # supervisor detect the label line: the LINE's presence, not the value.
  if ! grep -q -e '^RC_LABEL=' -e '^TARGET_ENTITY=' -e '^TARGET_PROJECT=' "$conf" 2>/dev/null; then
    local _prefix
    _prefix="$(registry_rc_label_prefix)" || return 78
    printf '%s\n' "$_prefix$slug"
    return 0
  fi
  # SUBSHELLED — see the header. The snapshot prints the two targets first
  # (guaranteed newline-free: registry_load validated their shape, or they
  # are empty) and RC_LABEL last, behind a sentinel byte so an empty label
  # cannot be collapsed by command substitution's trailing-newline
  # stripping into the field ahead of it. stderr flows through, so a
  # refusing load explains itself in registry_load's own words.
  local snap rc
  snap="$(
    registry_load "$slug" >/dev/null || exit $?
    printf '%s\n%s\n%s' "$TARGET_PROJECT" "$TARGET_ENTITY" "x$RC_LABEL"
  )"
  rc=$?
  [ "$rc" -eq 0 ] || return "$rc"
  local tproj tent label rest
  tproj="${snap%%$'\n'*}"
  rest="${snap#*$'\n'}"
  tent="${rest%%$'\n'*}"
  label="${rest#*$'\n'}"
  label="${label#x}"
  if [ -n "$label" ]; then
    printf '%s\n' "$label"
    return 0
  fi
  local disp
  if [ -n "$tproj" ]; then
    disp="$(registry_display_for project "$tproj")" || return $?
    printf '%s\n' "$disp"
    return 0
  fi
  if [ -n "$tent" ]; then
    disp="$(registry_display_for entity "$tent")" || return $?
    printf '%s\n' "$disp"
    return 0
  fi
  # RC_LABEL line present but empty (the RC-FREE choice) and no target: the
  # session still needs a name a human can read in a list, and prefix+name
  # is the one construction that already means "this session, unlabeled".
  local _prefix
  _prefix="$(registry_rc_label_prefix)" || return 78
  printf '%s\n' "$_prefix$slug"
}

registry_render_plist() {
  local project="${1:-}"
  registry_load "$project" || return 1
  cat <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>$LAUNCHD_LABEL</string>
  <key>ProgramArguments</key>
  <array>
    <string>/bin/bash</string>
    <string>$OWNER_HOME/scripts/session-supervisor.sh</string>
    <string>$project</string>
  </array>
  <key>WorkingDirectory</key><string>$REPO_PATH</string>
  <key>EnvironmentVariables</key>
  <dict>
    <key>HOME</key><string>$OWNER_HOME</string>
    <key>PATH</key><string>$OWNER_HOME/.local/bin:/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin</string>
  </dict>
  <key>UserName</key><string>$OWNER</string>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
  <key>ThrottleInterval</key><integer>10</integer>
  <key>StandardOutPath</key><string>$LOG_PATH</string>
  <key>StandardErrorPath</key><string>$LOG_PATH</string>
</dict>
</plist>
PLIST
}

# ---------------------------------------------------------------------------
# Jobs & services (unified-jobs spec, 2026-07-14). Jobs render as LaunchAgents
# in the OWNER's gui domain — the same domain as the legacy per-domain jobs — to
# preserve TCC/notification behavior. Services render as system LaunchDaemons.
# The prefixes come from the estate — see registry_label_prefixes above for why
# they are not resolved here.

_registry_valid_num_list() { [[ "${1:-}" =~ ^[0-9]+(,[0-9]+)*$ ]]; }

# Range-check every comma-separated element of $1 against [$2, $3]. Caller must
# already know $1 is a valid num list (_registry_valid_num_list) — this only
# checks bounds, e.g. SCHEDULE_HOUR="0,24" is a valid list but an invalid hour.
_registry_list_in_range() {
  local list="${1:-}" min="$2" max="$3" IFS=',' n
  for n in $list; do
    [ "$n" -ge "$min" ] && [ "$n" -le "$max" ] || return 1
  done
  return 0
}

registry_job_load() {
  local conf="${1:-}"
  if [ ! -f "$conf" ]; then echo "registry: no such job conf '$conf'" >&2; return 1; fi
  JOB_NAME="$(basename "$conf" .conf)"
  if ! registry_valid_name "$JOB_NAME"; then
    echo "registry: invalid job name '$JOB_NAME' (allowed: a-z 0-9 -)" >&2; return 1
  fi
  # Reset before sourcing so a prior load never leaks into this one.
  KIND=""; REPO_PATH=""; OWNER=""; DOMAIN=""; TIMEOUT_MIN=""
  SCHEDULE_MINUTE=""; SCHEDULE_HOUR=""; SCHEDULE_WEEKDAY=""
  PROMPT=""; MAX_TURNS=""; PERMISSION_MODE=""; SETTINGS_FILE=""; ALLOWED_TOOLS=""; TOOLS=""; JOB_ENV_KEYS=""; JOB_ENV_FILE=""; DELIVERY_GLOB=""; MCP_CONFIG=""
  PRE_CMD=""; POST_CMD=""; COMMAND=""
  # shellcheck source=/dev/null
  source "$conf"
  # NAMESPACE WARNING: see the note at the session loader's KIND validation. The
  # same global name carries a different closed set there (work|infra|advisor).
  case "$KIND" in claude|command) ;; *)
    echo "registry: $JOB_NAME: KIND must be claude|command (got '$KIND')" >&2; return 1 ;;
  esac
  if [ -z "$REPO_PATH" ]; then echo "registry: $JOB_NAME missing REPO_PATH" >&2; return 1; fi
  if ! [[ "$OWNER" =~ ^[a-z][a-z0-9-]*$ ]]; then
    echo "registry: $JOB_NAME missing/invalid OWNER" >&2; return 1
  fi
  if ! [[ "$DOMAIN" =~ ^[a-z0-9-]+$ ]]; then
    echo "registry: $JOB_NAME missing/invalid DOMAIN" >&2; return 1
  fi
  if ! [[ "$TIMEOUT_MIN" =~ ^[0-9]+$ ]]; then
    echo "registry: $JOB_NAME missing/invalid TIMEOUT_MIN" >&2; return 1
  fi
  # UNKNOWN SCHEDULE FIELDS ARE REJECTED, not ignored. Somebody wrote
  # SCHEDULE_DAYS="*/3" believing the job would run every third day. The field
  # does not exist — not here, not in the schedule reader, not in any renderer —
  # so the job would have run EVERY DAY while the conf claimed otherwise, without
  # a single
  # felmeddelande (2026-08-10).
  #
  # This is the recurring failure class here: a setting that looks like it
  # applies and does not. A conf that lies is worse than one that refuses to
  # load, because whoever wrote it stops looking.
  #
  # We can only see fields that ACTUALLY stand in the file, so we grep it rather
  # than trust the environment — an empty variable cannot be told from an unset
  # one.
  # TWO TRAPS HERE, both mine, both caught by the test:
  #   1. `tr -d '[:space:]'` removes the LINE BREAKS too, so all three known
  #      fields were glued into one string which of course did not match the
  #      list — and EVERY valid conf was rejected. The suite went 20/0 -> 12/8.
  #   2. Without `|| true`, grep returns 1 when no unknown field exists, which
  #      under set -e aborts the function on its own SUCCESSFUL outcome.
  local _bad=""
  _bad="$(grep -oE '^[[:space:]]*SCHEDULE_[A-Z_]+' "$conf" 2>/dev/null | tr -d ' \t' \
          | grep -vxE 'SCHEDULE_MINUTE|SCHEDULE_HOUR|SCHEDULE_WEEKDAY' | sort -u | tr '\n' ' ' || true)"
  if [ -n "$_bad" ]; then
    echo "registry: $JOB_NAME has an unknown schedule field: ${_bad% }" >&2
    echo "registry: supported: SCHEDULE_MINUTE, SCHEDULE_HOUR, SCHEDULE_WEEKDAY" >&2
    return 1
  fi
  if ! _registry_valid_num_list "$SCHEDULE_MINUTE"; then
    echo "registry: $JOB_NAME missing/invalid SCHEDULE_MINUTE" >&2; return 1
  fi
  if [ -n "$SCHEDULE_HOUR" ] && ! _registry_valid_num_list "$SCHEDULE_HOUR"; then
    echo "registry: $JOB_NAME invalid SCHEDULE_HOUR" >&2; return 1
  fi
  if [ -n "$SCHEDULE_WEEKDAY" ] && ! _registry_valid_num_list "$SCHEDULE_WEEKDAY"; then
    echo "registry: $JOB_NAME invalid SCHEDULE_WEEKDAY" >&2; return 1
  fi
  if ! _registry_list_in_range "$SCHEDULE_MINUTE" 0 59; then
    echo "registry: $JOB_NAME SCHEDULE_MINUTE out of range (0-59)" >&2; return 1
  fi
  if [ -n "$SCHEDULE_HOUR" ] && ! _registry_list_in_range "$SCHEDULE_HOUR" 0 23; then
    echo "registry: $JOB_NAME SCHEDULE_HOUR out of range (0-23)" >&2; return 1
  fi
  if [ -n "$SCHEDULE_WEEKDAY" ] && ! _registry_list_in_range "$SCHEDULE_WEEKDAY" 0 7; then
    echo "registry: $JOB_NAME SCHEDULE_WEEKDAY out of range (0-7)" >&2; return 1
  fi
  if [ "$KIND" = "claude" ]; then
    if [ -z "$PROMPT" ] || ! [[ "$MAX_TURNS" =~ ^[0-9]+$ ]] || [ -z "$PERMISSION_MODE" ]; then
      echo "registry: $JOB_NAME (claude) needs PROMPT, numeric MAX_TURNS, PERMISSION_MODE" >&2; return 1
    fi
  else
    if [ -z "$COMMAND" ]; then echo "registry: $JOB_NAME (command) needs COMMAND" >&2; return 1; fi
  fi
  OWNER_HOME="/Users/$OWNER"
  registry_label_prefixes || return 78
  local _logdir; _logdir="$(registry_job_log_dir)" || return 78
  JOB_LABEL="$JOB_LABEL_PREFIX.$DOMAIN.$JOB_NAME"
  JOB_LOG="$OWNER_HOME/Library/Logs/$_logdir/$DOMAIN-$JOB_NAME.log"
}

# Emit the StartCalendarInterval body: cartesian product of the comma lists.
_registry_render_calendar() {
  local IFS=','
  local -a minutes hours weekdays
  read -ra minutes <<<"$SCHEDULE_MINUTE"
  read -ra hours <<<"${SCHEDULE_HOUR:-}"
  read -ra weekdays <<<"${SCHEDULE_WEEKDAY:-}"
  [ ${#hours[@]} -gt 0 ] || hours=("")
  [ ${#weekdays[@]} -gt 0 ] || weekdays=("")
  echo "  <key>StartCalendarInterval</key>"
  echo "  <array>"
  local w h m
  for w in "${weekdays[@]}"; do for h in "${hours[@]}"; do for m in "${minutes[@]}"; do
    echo "    <dict>"
    [ -n "$w" ] && echo "      <key>Weekday</key><integer>$w</integer>"
    [ -n "$h" ] && echo "      <key>Hour</key><integer>$h</integer>"
    echo "      <key>Minute</key><integer>$m</integer>"
    echo "    </dict>"
  done; done; done
  echo "  </array>"
}

registry_job_render_plist() {
  registry_job_load "${1:-}" || return 1
  cat <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>$JOB_LABEL</string>
  <key>ProgramArguments</key>
  <array>
    <string>/bin/bash</string>
    <string>$OWNER_HOME/scripts/job-runner.sh</string>
    <string>$DOMAIN</string>
    <string>$JOB_NAME</string>
  </array>
  <key>WorkingDirectory</key><string>$REPO_PATH</string>
  <key>EnvironmentVariables</key>
  <dict>
    <key>HOME</key><string>$OWNER_HOME</string>
    <key>PATH</key><string>$OWNER_HOME/.local/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin</string>
  </dict>
$(_registry_render_calendar)
  <key>StandardOutPath</key><string>$JOB_LOG</string>
  <key>StandardErrorPath</key><string>$JOB_LOG</string>
</dict>
</plist>
PLIST
}

registry_service_load() {
  local conf="${1:-}"
  if [ ! -f "$conf" ]; then echo "registry: no such service conf '$conf'" >&2; return 1; fi
  SERVICE_NAME="$(basename "$conf" .conf)"
  if ! registry_valid_name "$SERVICE_NAME"; then
    echo "registry: invalid service name '$SERVICE_NAME'" >&2; return 1
  fi
  OWNER=""; SERVICE_SCRIPT=""; SERVICE_APP=""; SERVICE_LOG=""; SERVICE_DOMAIN=""
  # shellcheck source=/dev/null
  source "$conf"
  # SERVICE_DOMAIN: where the service belongs in launchd (2026-08-11).
  #   system (default) — the system daemon directory, running as OWNER via
  #                      UserName. Right for network services with no GUI needs.
  #   gui             — the owner's LaunchAgents, gui/<uid>, like jobs
  #                      and browsers. MANDATORY for anything touching the
  #                      platform's privacy permissions or the user's GUI
  #                      session: a scripted helper that talks to a desktop app
  #                      cannot reach the GUI session from the system domain, and
  #                      permission dialogs nobody can answer are denied
  #                      automatically — the service looks supervised and quietly
  #                      stops delivering. That is exactly what would have
  #                      happened to one router had its conf been deployed as
  #                      written.
  : "${SERVICE_DOMAIN:=system}"
  case "$SERVICE_DOMAIN" in
    system|gui) : ;;
    *) echo "registry: $SERVICE_NAME invalid SERVICE_DOMAIN '$SERVICE_DOMAIN' (system|gui)" >&2; return 1 ;;
  esac
  # Trim leading/trailing whitespace so a whitespace-only SERVICE_APP (e.g.
  # a stray "SERVICE_APP=\" \"" typo) reduces to empty and falls through to
  # the "missing SERVICE_SCRIPT or SERVICE_APP" check below, rather than
  # being accepted as a truthy-but-garbage OWNER-relative path.
  SERVICE_APP="$(printf '%s' "$SERVICE_APP" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
  if ! [[ "$OWNER" =~ ^[a-z][a-z0-9-]*$ ]]; then
    echo "registry: $SERVICE_NAME missing/invalid OWNER" >&2; return 1
  fi
  # Exactly one of SERVICE_SCRIPT (bash wrapper under scripts/) / SERVICE_APP
  # (bundle binary, run directly — no bash wrapper, because for TCC-gated
  # services the app's own code-signed identity is what matters). SERVICE_APP is
  # OWNER-relative (joined as $OWNER_HOME/$SERVICE_APP), same pattern as the
  # browser registry's PROFILE_DIR — never hardcode /Users/<owner> in a conf.
  if [ -n "$SERVICE_SCRIPT" ] && [ -n "$SERVICE_APP" ]; then
    echo "registry: $SERVICE_NAME must set exactly one of SERVICE_SCRIPT/SERVICE_APP (both set)" >&2; return 1
  fi
  if [ -z "$SERVICE_SCRIPT" ] && [ -z "$SERVICE_APP" ]; then
    echo "registry: $SERVICE_NAME missing SERVICE_SCRIPT or SERVICE_APP" >&2; return 1
  fi
  if [ -n "$SERVICE_APP" ] && { [[ "$SERVICE_APP" = /* ]] || printf '%s' "$SERVICE_APP" | grep -q '\.\.'; }; then
    echo "registry: $SERVICE_NAME unsafe SERVICE_APP (relative to OWNER_HOME, no leading /, no ..)" >&2; return 1
  fi
  OWNER_HOME="/Users/$OWNER"
  registry_label_prefixes || return 78
  SERVICE_LABEL="$SERVICE_LABEL_PREFIX.$SERVICE_NAME"
  : "${SERVICE_LOG:=$OWNER_HOME/.claude/$SERVICE_NAME.log}"
}

registry_service_render_plist() {
  registry_service_load "${1:-}" || return 1
  local program_arguments
  if [ -n "$SERVICE_APP" ]; then
    program_arguments="<array><string>$OWNER_HOME/$SERVICE_APP</string></array>"
  else
    program_arguments="<array><string>/bin/bash</string><string>$OWNER_HOME/scripts/$SERVICE_SCRIPT</string></array>"
  fi
  # UserName is a DAEMON key. In a gui agent it is at best ignored — the agent
  # already runs as the logged-in user — and rendering it would be documenting
  # something that does not apply. The system rendering is unchanged down to the
  # byte: the golden test against the live baseline guards that.
  local user_name_row=""
  [ "$SERVICE_DOMAIN" = "system" ] && user_name_row="  <key>UserName</key><string>$OWNER</string>
"
  cat <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>$SERVICE_LABEL</string>
  <key>ProgramArguments</key>
  $program_arguments
  <key>EnvironmentVariables</key>
  <dict>
    <key>HOME</key><string>$OWNER_HOME</string>
  </dict>
${user_name_row}  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
  <key>ThrottleInterval</key><integer>10</integer>
  <key>StandardOutPath</key><string>$SERVICE_LOG</string>
  <key>StandardErrorPath</key><string>$SERVICE_LOG</string>
</dict>
</plist>
PLIST
}

# ---------------------------------------------------------------------------
# Browser registry (gui-domain LaunchAgent, 2026-07-16). Renders a KeepAlive
# LaunchAgent for a Chrome instance configured via conf file.
# The prefix comes from the estate — see registry_label_prefixes.

registry_browser_load() {
  local conf="${1:-}"
  if [ ! -f "$conf" ]; then echo "registry: no such browser conf '$conf'" >&2; return 1; fi
  BROWSER_DOMAIN_FILE="$(basename "$conf" .conf)"
  OWNER=""; DOMAIN=""; CHROME_PORT=""; PROFILE_DIR=""
  # shellcheck source=/dev/null
  source "$conf"
  if ! [[ "$OWNER" =~ ^[a-z][a-z0-9-]*$ ]]; then echo "registry: $BROWSER_DOMAIN_FILE missing/invalid OWNER" >&2; return 1; fi
  if ! [[ "$DOMAIN" =~ ^[a-z0-9-]+$ ]]; then echo "registry: $BROWSER_DOMAIN_FILE missing/invalid DOMAIN" >&2; return 1; fi
  # chrome-launch.sh loads confs BY FILENAME while the label derives from
  # DOMAIN — a mismatch would collide labels and launch the wrong conf.
  if [ "$DOMAIN" != "$BROWSER_DOMAIN_FILE" ]; then
    echo "registry: $BROWSER_DOMAIN_FILE DOMAIN '$DOMAIN' must match the conf filename" >&2; return 1; fi
  if ! [[ "$CHROME_PORT" =~ ^[0-9]{2,5}$ ]] || [ "$CHROME_PORT" -lt 1024 ] || [ "$CHROME_PORT" -gt 65535 ]; then
    echo "registry: $BROWSER_DOMAIN_FILE invalid CHROME_PORT (1024-65535)" >&2; return 1; fi
  # PROFILE_DIR is joined as $OWNER_HOME/$PROFILE_DIR — absolute paths would
  # silently nest under OWNER_HOME instead of being used as written.
  if [ -z "$PROFILE_DIR" ] || [[ "$PROFILE_DIR" = /* ]] || printf '%s' "$PROFILE_DIR" | grep -q '\.\.'; then
    echo "registry: $BROWSER_DOMAIN_FILE missing/unsafe PROFILE_DIR (relative to OWNER_HOME, no ..)" >&2; return 1; fi
  OWNER_HOME="/Users/$OWNER"
  registry_label_prefixes || return 78
  local _logdir; _logdir="$(registry_job_log_dir)" || return 78
  BROWSER_LABEL="$BROWSER_LABEL_PREFIX.$DOMAIN"
  BROWSER_LOG="$OWNER_HOME/Library/Logs/$_logdir/browser-$DOMAIN.log"
}

registry_browser_render_plist() {
  registry_browser_load "${1:-}" || return 1
  cat <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>$BROWSER_LABEL</string>
  <key>ProgramArguments</key>
  <array>
    <string>/bin/bash</string>
    <string>$OWNER_HOME/scripts/chrome-launch.sh</string>
    <string>$DOMAIN</string>
  </array>
  <key>EnvironmentVariables</key>
  <dict><key>HOME</key><string>$OWNER_HOME</string></dict>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
  <key>ThrottleInterval</key><integer>10</integer>
  <key>StandardOutPath</key><string>$BROWSER_LOG</string>
  <key>StandardErrorPath</key><string>$BROWSER_LOG</string>
</dict>
</plist>
PLIST
}

# ---------------------------------------------------------------------------
# Host registry (2026-08-04). An inventory of the machines this layer answers for
# driften av.
#
# THIS REGISTRY TYPE RENDERS NO PLIST. It describes machines standing somewhere
# else — nothing here can touch a live session, and it therefore does not pass
# through the golden-master gate.
#
# WHY TWO OWNER FIELDS: ownership is not one field. LEGAL_OWNER is who pays and
# carries legal responsibility; OPERATOR is who runs the machine. They diverge in
# practice — a machine can be operated by one person and owned by a company — and
# that boundary existed only in somebody's head until it was written down.

registry_host_dir() {
  if [ -n "${STEWARD_HOSTS_DIR:-}" ]; then
    printf '%s\n' "$STEWARD_HOSTS_DIR"
  else
    printf '%s\n' "$(_registry_estate_root)/hosts.d"
  fi
}

# Same distinction as registry_list above, same reason.
registry_host_list() {
  local dir; dir="$(registry_host_dir)"
  if [ ! -d "$dir" ]; then
    echo "registry: REFUSING to list hosts — the host registry does not exist: $dir" >&2
    return 78
  fi
  local f
  for f in "$dir"/*.conf; do
    [ -e "$f" ] || continue
    basename "$f" .conf
  done | sort
}

registry_host_load() {
  local conf="${1:-}"
  if [ ! -f "$conf" ]; then echo "registry: no such host conf '$conf'" >&2; return 1; fi
  HOST_NAME="$(basename "$conf" .conf)"
  if ! registry_valid_name "$HOST_NAME"; then
    echo "registry: invalid host name '$HOST_NAME'" >&2; return 1
  fi
  OWNER=""; LEGAL_OWNER=""; OPERATOR=""; SSH_ALIAS=""; HOST_ADDR=""; ENDPOINTS=""
  CERT_WARN_DAYS=""; DISK_WARN_PCT=""; MEM_WARN_PCT=""
  # shellcheck source=/dev/null
  source "$conf"
  if ! [[ "$OWNER" =~ ^[a-z][a-z0-9-]*$ ]]; then
    echo "registry: $HOST_NAME missing/invalid OWNER" >&2; return 1
  fi
  # LEGAL_OWNER is free text (a company name), but it MUST NOT be empty. A
  # machine with no named legal owner is precisely the state this registry exists
  # to make impossible.
  LEGAL_OWNER="$(printf '%s' "$LEGAL_OWNER" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
  if [ -z "$LEGAL_OWNER" ]; then
    echo "registry: $HOST_NAME missing LEGAL_OWNER (who pays, and who answers for it?)" >&2; return 1
  fi
  if ! [[ "$OPERATOR" =~ ^[a-z][a-z0-9-]*$ ]]; then
    echo "registry: $HOST_NAME missing/invalid OPERATOR" >&2; return 1
  fi
  # ENDPOINTS is optional (2026-08-06): a machine with no HTTPS addresses is
  # still worth watching — capacity and reachability over ssh ARE the measurement
  # there. Requiring it was the wrong shape: it forced invented
  # addresses, or kept real machines out of the registry entirely.
  local pair
  for pair in $ENDPOINTS; do
    # address[/path]=domain. The path exists because an API root may well answer
    # 404 on "/" and still be perfectly healthy — measured on a live endpoint that
    # does exactly that, where probing "/" would have alarmed on health. Only the
    # owner of an address knows what counts as a healthy answer, so it is declared
    # here.
    if ! [[ "$pair" =~ ^[a-z0-9][a-z0-9.-]*(/[A-Za-z0-9._~/-]*)?=[a-z0-9-]+$ ]]; then
      echo "registry: $HOST_NAME bad ENDPOINTS entry '$pair' (expected address[/path]=domain)" >&2; return 1
    fi
  done
  : "${CERT_WARN_DAYS:=21}"; : "${DISK_WARN_PCT:=85}"; : "${MEM_WARN_PCT:=90}"
  local n
  for n in CERT_WARN_DAYS DISK_WARN_PCT MEM_WARN_PCT; do
    if ! [[ "${!n}" =~ ^[0-9]+$ ]]; then
      echo "registry: $HOST_NAME invalid $n '${!n}' (expected an integer)" >&2; return 1
    fi
  done
}

# ── LOGINS: WHO PAYS FOR THE MODEL CALLS ───────────────────────────────────
#
# A LOGIN is to the model account what a host row is to the machine: the one
# place that answers "who pays, and who answers for it". One row per human x
# account, NEVER per session — sessions on the same account share a login the
# way they share one credential directory today.
#
# THIS REGISTER IS NEVER SOURCED, and it is the first one in this file that
# isn't. The reason is what the rows CARRY: a path to a directory holding a
# subscription's live credentials. `source` on such a row means any line in it
# can move those credentials, and a row is exactly the kind of file a hand
# edits under time pressure. The operator config took the same decision for the
# same reason; this is that reader, for this register.
_REGISTRY_LOGIN_REQUIRED="PRINCIPAL ACCOUNT PROVIDER CONFIG_DIR LEGAL_OWNER"

# THE PROVIDER VOCABULARY IS CLOSED, and a word in it is not a promise that a
# mechanism exists. Two of the four are measured; the other two are RESERVED
# NAMES whose isolation recipe has not been written. The export rule refuses on
# them rather than doing nothing quietly — a login that silently fails to scope
# is a login that bills the wrong account and looks fine.
_REGISTRY_LOGIN_PROVIDERS="claude-max claude-team opencode-chatgpt codex-openai"

# _registry_mode_of <path> — octal mode, BSD or GNU stat, empty on failure.
# Same two-shot idiom as _registry_stat_id above, and for the same reason: this
# library is sourced on both platforms and neither stat flag exists on both.
#
# KNOWINGLY DUPLICATED: bin/steward carries the same reader for the operator
# config, defined before it sources this file. Collapsing them is a separate
# change; doing it here would move a guard the config reader depends on.
_registry_mode_of() {
  local p="$1" m
  m="$(stat -f '%Lp' "$p" 2>/dev/null)" && [ -n "$m" ] && { printf '%s' "$m"; return 0; }
  m="$(stat -c '%a' "$p" 2>/dev/null)" && [ -n "$m" ] && { printf '%s' "$m"; return 0; }
  return 1
}

_registry_group_or_other_writable() { # <octal mode>
  local mode="$1"
  case "$mode" in ''|*[!0-7]*) return 0 ;; esac   # unreadable mode: treat as unsafe
  while [ "${#mode}" -lt 3 ]; do mode="0$mode"; done
  local grp="${mode: -2:1}" oth="${mode: -1}"
  [ $(( 8#$grp & 2 )) -ne 0 ] && return 0
  [ $(( 8#$oth & 2 )) -ne 0 ] && return 0
  return 1
}

registry_login_dir() {
  if [ -n "${STEWARD_LOGINS_DIR:-}" ]; then
    printf '%s\n' "$STEWARD_LOGINS_DIR"
  else
    printf '%s\n' "$(_registry_estate_root)/logins.d"
  fi
}

# Same distinction as registry_host_list: an absent register REFUSES. A login
# register that reads as empty is a fleet where nothing declares who pays, and
# the fallback for that is "the ambient account" — the one outcome this whole
# register exists to make impossible.
registry_login_list() {
  local dir; dir="$(registry_login_dir)"
  if [ ! -d "$dir" ]; then
    echo "registry: REFUSING to list logins — the login register does not exist: $dir" >&2
    return 78
  fi
  local f
  for f in "$dir"/*.conf; do
    # -e OR -L. `-e` FOLLOWS the link, so a DANGLING symlink named <slug>.conf
    # is invisible to it — and then the register-wide check never sees the row
    # at all, while registry_login_load would have refused it as a symlink. A
    # row the lister skips and the loader refuses is a row that exists for
    # everything except the guard built to notice it.
    [ -e "$f" ] || [ -L "$f" ] || continue
    basename "$f" .conf
  done | sort
}

# registry_login_load <slug> — parse ONE login row. rc 0 · 1 (no such row, or a
# row whose content is refused) · 78 (the register or the file's own state
# refuses: symlink, wrong owner, loose mode).
#
# RESET FIRST, same leak-guard posture as every other loader in this file: a
# caller that gets a refusal must never still see the last row that parsed.
registry_login_load() {
  LOGIN_SLUG=""; LOGIN_PRINCIPAL=""; LOGIN_ACCOUNT=""; LOGIN_PROVIDER=""
  LOGIN_CONFIG_DIR_RAW=""; LOGIN_LEGAL_OWNER=""
  local slug="${1:-}" dir f
  if ! [[ "$slug" =~ ^[a-z0-9][a-z0-9-]*$ ]]; then
    echo "registry: invalid login slug '$slug' (allowed: a-z 0-9 and hyphen)" >&2
    return 1
  fi
  dir="$(registry_login_dir)" || return 78
  # THE REGISTER DIRECTORY'S OWN STATE COMES BEFORE THE ROW'S. A row at mode 600
  # inside a directory anybody can write to is not protected by its mode: anybody
  # can rename it away and put their own file there under the same name, and the
  # mode check on the new file passes. Measured as a class in this estate's own
  # key-permission tool: the boundary is the whole chain, not the leaf.
  if [ -L "$dir" ]; then
    echo "registry: the login register is a symlink, refusing: $dir" >&2
    return 78
  fi
  if [ -d "$dir" ]; then
    local dmode; dmode="$(_registry_mode_of "$dir")" || {
      echo "registry: cannot read the mode of the login register: $dir" >&2; return 78; }
    if _registry_group_or_other_writable "$dmode"; then
      echo "registry: the login register is group- or other-writable (mode $dmode), refusing: $dir" >&2
      return 78
    fi
  fi
  f="$dir/$slug.conf"
  # THE SYMLINK IS ASKED ABOUT FIRST, ahead of `-f` — `-L` does not follow the
  # link, so this also catches a DANGLING one, which would otherwise read as
  # "no such login". A link's target can be swapped out from under an
  # owner/mode check that ran a moment earlier.
  if [ -L "$f" ]; then
    echo "registry: login '$slug' is a symlink, refusing: $f" >&2
    return 78
  fi
  if [ ! -f "$f" ]; then
    echo "registry: no such login: $slug" >&2
    return 1
  fi
  if [ ! -O "$f" ]; then
    echo "registry: login '$slug' is not owned by the current user, refusing: $f" >&2
    return 78
  fi
  local mode; mode="$(_registry_mode_of "$f")" || {
    echo "registry: cannot read the mode of login '$slug': $f" >&2; return 78; }
  if _registry_group_or_other_writable "$mode"; then
    echo "registry: login '$slug' is group- or other-writable (mode $mode), refusing: $f" >&2
    return 78
  fi

  local lineno=0 line key value seen="" k
  local v_PRINCIPAL="" v_ACCOUNT="" v_PROVIDER="" v_CONFIG_DIR="" v_LEGAL_OWNER=""
  while IFS= read -r line || [ -n "$line" ]; do
    lineno=$((lineno+1))
    # A CR byte is a control character wherever it stands, including at the end
    # of a line — a row edited on another platform must refuse rather than
    # carry an invisible byte into a directory path.
    case "$line" in
      *[[:cntrl:]]*)
        echo "registry: $f:$lineno: control character in the line, refusing" >&2
        return 1 ;;
    esac
    case "$line" in ''|'#'*) continue ;; esac
    # EXACTLY KEY="VALUE" AND NOTHING ELSE ON THE LINE. The anchored match is
    # what makes `PRINCIPAL="alice" ; rm -rf /` a refusal rather than a
    # command: there is no branch here that reads part of a line and ignores
    # the rest.
    if ! [[ "$line" =~ ^([A-Z_]+)=\"([^\"]*)\"$ ]]; then
      echo "registry: $f:$lineno: each setting must be written exactly KEY=\"VALUE\" on its own line" >&2
      return 1
    fi
    key="${BASH_REMATCH[1]}"; value="${BASH_REMATCH[2]}"
    case " $_REGISTRY_LOGIN_REQUIRED " in
      *" $key "*) ;;
      *) echo "registry: $f:$lineno: unknown key '$key' (allowed: $_REGISTRY_LOGIN_REQUIRED)" >&2
         return 1 ;;
    esac
    case " $seen " in
      *" $key "*) echo "registry: $f:$lineno: duplicate key '$key'" >&2; return 1 ;;
    esac
    seen="$seen $key"
    # NO SUBSTITUTION SURVIVES THE READER. The value never reaches a shell in
    # this function, but it DOES reach a path join and an exec string further
    # on — and a row is the wrong place to learn which of its readers is the
    # careless one. Refuse the shape at the source.
    case "$value" in
      *'$'*|*'`'*|*'\'*)
        echo "registry: $f:$lineno: '$key' contains a substitution or escape character, refusing" >&2
        return 1 ;;
    esac
    eval "v_$key=\$value"
  done < "$f"

  for k in $_REGISTRY_LOGIN_REQUIRED; do
    case " $seen " in
      *" $k "*) ;;
      *) echo "registry: $f: missing required key '$k'" >&2; return 1 ;;
    esac
  done

  # PRINCIPAL is the HUMAN — the same form as an entity's MEMBERS entries and a
  # session's OWNER, because the identity gate compares them directly.
  if ! [[ "$v_PRINCIPAL" =~ ^[a-z][a-z0-9-]*$ ]]; then
    echo "registry: $f: invalid PRINCIPAL '$v_PRINCIPAL' (a-z, then a-z 0-9 and hyphen)" >&2
    return 1
  fi
  # ACCOUNT is the account's REAL name and is deliberately free-ish text: it is
  # an address today and may be something else on another provider. It must not
  # be empty, and it must not carry whitespace — a name with a space in it is
  # almost always two fields that got glued.
  case "$v_ACCOUNT" in
    ''|*[[:space:]]*)
      echo "registry: $f: ACCOUNT must be the account's real name, non-empty and without whitespace" >&2
      return 1 ;;
  esac
  case " $_REGISTRY_LOGIN_PROVIDERS " in
    *" $v_PROVIDER "*) ;;
    *) echo "registry: $f: invalid PROVIDER '$v_PROVIDER' (one of: $_REGISTRY_LOGIN_PROVIDERS)" >&2
       return 1 ;;
  esac
  # LEGAL_OWNER is free text (a company name) and MUST NOT be empty — the same
  # requirement, for the same reason, as a host row's own LEGAL_OWNER: an
  # account with no named payer is precisely the state this register exists to
  # make impossible.
  v_LEGAL_OWNER="$(printf '%s' "$v_LEGAL_OWNER" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
  if [ -z "$v_LEGAL_OWNER" ]; then
    echo "registry: $f: missing LEGAL_OWNER (who pays for these model calls, and who answers for them?)" >&2
    return 1
  fi
  # CONFIG_DIR's GRAMMAR is checked by registry_login_config_dir, which also
  # resolves it. It is deliberately NOT validated here: the transition
  # exception depends on the estate, and a reader that half-validates would
  # report the wrong cause.
  LOGIN_SLUG="$slug"
  LOGIN_PRINCIPAL="$v_PRINCIPAL"
  LOGIN_ACCOUNT="$v_ACCOUNT"
  LOGIN_PROVIDER="$v_PROVIDER"
  LOGIN_CONFIG_DIR_RAW="$v_CONFIG_DIR"
  LOGIN_LEGAL_OWNER="$v_LEGAL_OWNER"
  return 0
}
