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
REGISTRY_SCHEMA_MAX=2

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
  local SCHEMA_VERSION=""
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
  ID=""; KIND=""; LIFECYCLE=""
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
  # OWNER: the macOS user the session runs as. Required and validated because the
  # installer runs as root and renders it into UserName and every path — never guess.
  if ! [[ "$OWNER" =~ ^[a-z][a-z0-9-]*$ ]]; then
    echo "registry: $project.conf missing/invalid OWNER (macOS username, a-z 0-9 -)" >&2
    return 1
  fi
  # DOMAIN: which business the session belongs to. The
  # machine layer only carries it; fleet and reporting group by it.
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
