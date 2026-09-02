#!/bin/bash
# lib/mcpspawn.sh -- the spawn policy for a session's inherited MCP set.
# Sourced library, no side effects on source.
#
#   mcp_spawn_prepare      <session-id> <document-path>
#   mcp_claude_cmd_fragment <cont> <mcp-arg> <name-arg> <rc-label>
#
# SOURCE lib/registry.sh AND lib/mcprender.sh FIRST, in that order. Same reason
# lib/mcprender.sh does not source the registry itself: the two consumers of
# this file -- the Linux session supervisor and the macOS twin -- find their
# libraries in two different places, and a library that reached for a second
# one on its own would load a different registry than its caller already had.
#
# ── WHY A POLICY LAYER AT ALL ──────────────────────────────────────────────
#
# The render answers three ways (lib/mcprender.sh): a document, an empty
# document, and a refusal. A spawner that reads only stdout collapses the last
# two, and the collapse is silent in the worst possible direction:
#
#   A session whose entire grant failed to resolve would start on the LEGACY
#   path -- the repo's own .mcp.json, i.e. whatever that checkout happens to
#   declare -- at the exact moment the registry was trying to say "this set
#   could not be honored". More tools than anybody granted, because something
#   broke. Nothing in the running session shows it.
#
# So the outcomes are separated into exit codes the caller branches on, and two
# of them produce the SAME argument fragment for OPPOSITE reasons:
#
#  rc 0  rendered, complete            -- document written, strict
#  rc 1  rendered, DEGRADED            -- document written, strict; at least one
#                                         granted asset was OMITTED, and the
#                                         render's stderr is carried through so
#                                         the caller can name which
#  rc 2  the render REFUSED            -- an EMPTY document written, strict.
#                                         FAIL-CLOSED: strict plus empty means
#                                         no MCP at all, and it is a KNOWN no
#                                         rather than the legacy everything.
#                                         The render's stderr is carried through
#  rc 3  nothing was granted           -- no document (a stale one is removed),
#                                         no fragment. THE REGISTRY NEVER SPOKE,
#                                         and the caller keeps the command line
#                                         it has today, byte for byte. Live
#                                         sessions with no grant must not change
#  rc 69 the document cannot be built  -- no fragment. jq is missing, or the
#                                         document could not be written. The
#                                         caller must REFUSE TO SPAWN: falling
#                                         back to legacy because a TOOL is
#                                         missing is the rc 2 mistake with a
#                                         different cause
#
# THE DOCUMENT ONLY EVER HOLDS PATHS. It names credential FILES, never their
# contents (the pattern lib/mcprender.sh enforces and test/mcp-render.test.sh
# measures), and it is written 0600 anyway: a reader who can list the paths
# knows where to go next.

# _mcp_write_document <path> <content> -- 0600, and atomic.
#
# TEMP PLUS RENAME, NOT A TRUNCATING REDIRECT. The supervisor rewrites this
# file on every round while claude may be reading it; a redirect empties the
# file first and leaves a window in which the document exists and is empty --
# which under --strict-mcp-config is a session with no tools and no reason
# given. The mode is set on the temp file, so the document is never readable by
# anyone else, not even for the instant between create and chmod.
_mcp_write_document() {
  local doc="$1" content="$2" dir tmp
  # A DIRECTORY AT THE DOCUMENT'S PATH IS A REFUSAL, CHECKED BEFORE ANYTHING IS
  # CREATED. `mv -f file dir` does not replace the directory -- it moves the
  # file INSIDE it and returns 0, so the write would report success, the
  # fragment would point --mcp-config at a directory, and a 0600
  # s.mcp.json.tmp.<pid> would be left in there for good. claude cannot read a
  # directory as a config, and under --strict-mcp-config that is a session with
  # no tools and nothing saying why; the honest answer is the refusal every
  # other unwritable document already gets. The test comes first so no temp
  # file is ever made inside a path we are about to refuse.
  if [ -d "$doc" ]; then return 1; fi
  dir="$(dirname "$doc")"
  mkdir -p "$dir" 2>/dev/null || return 1
  tmp="$doc.tmp.$$"
  ( umask 077; printf '%s\n' "$content" > "$tmp" ) 2>/dev/null || { rm -f "$tmp"; return 1; }
  chmod 600 "$tmp" 2>/dev/null || { rm -f "$tmp"; return 1; }
  mv -f "$tmp" "$doc" 2>/dev/null || { rm -f "$tmp"; return 1; }
  return 0
}

mcp_spawn_prepare() { # <session-id> <document-path>
  local sid="${1:-}" doc="${2:-}"
  if [ -z "$sid" ] || [ -z "$doc" ]; then
    echo "mcp spawn: needs a session id and a document path" >&2
    return 64
  fi

  # THE RENDER'S STDERR IS KEPT, NOT DISCARDED. It is the only place the names
  # of the omitted or unrenderable assets exist; rc 1 and rc 2 are alarms whose
  # whole value is naming what is missing, and an alarm that says "something"
  # sends a human to read four files.
  local errf
  errf="$(mktemp "${TMPDIR:-/tmp}/mcpspawn.XXXXXX" 2>/dev/null)" || {
    echo "mcp spawn: session '$sid' -- no temp file could be made to hold the render's diagnostics; REFUSING to prepare a spawn" >&2
    return 69
  }
  # THE WRAPPER IS RESOLVED TO AN ABSOLUTE PATH FOR *THIS* RENDER, and only
  # here. lib/mcprender.sh names the wrapper `~/bin/mcp-env` by default because
  # `steward mcp render` runs on the machine that HOLDS the register and prints
  # for a human -- the tilde is the honest thing to write when the reader's home
  # is not the writer's. This caller is the opposite case: it renders ON the
  # session host, at spawn time, and hands the document straight to claude --
  # and an MCP client spawns a server's `command` DIRECTLY, with no shell to
  # expand anything. A literal tilde there is a directory named "~", the server
  # dies with ENOENT, and under --strict-mcp-config that is a granted asset that
  # silently never starts.
  #
  # A `local` RATHER THAN AN EXPORT: bash's dynamic scoping makes it visible to
  # mcp_render_document for the length of the call and to nothing afterwards, so
  # no other renderer in the process inherits this host's home. An override
  # already in the environment wins -- an operator who installed the wrapper
  # elsewhere has said so.
  #
  # AN EMPTY $HOME LEAVES THE DEFAULT ALONE. "/bin/mcp-env" is a confident,
  # wrong path; the literal is at least visibly a template.
  local _wrapper="${STEWARD_MCP_WRAPPER:-}"
  if [ -z "$_wrapper" ] && [ -n "${HOME:-}" ]; then
    _wrapper="$HOME/bin/mcp-env"
  fi
  local body rrc STEWARD_MCP_WRAPPER="$_wrapper"
  body="$(mcp_render_document "$sid" 2>"$errf")"; rrc=$?

  # rc 69 travels unchanged: the render could not build a document SAFELY, and
  # neither a legacy spawn nor an empty document is an honest answer to that.
  if [ "$rrc" -eq 69 ]; then
    cat "$errf" >&2; rm -f "$errf"
    return 69
  fi

  # A FAILED PROBE IS NOT A PROBE THAT SAID ZERO. The emptiness probe below is
  # the ONLY gate in front of rc 3, and rc 3 is the one outcome that leaves the
  # command line alone -- i.e. hands the session the legacy .mcp.json, whatever
  # the checkout declares. Reading a non-zero jq (fork failure under memory
  # pressure, jq replaced mid-deploy) or a non-numeric answer as "length 0"
  # resolves an UNKNOWN in the single direction this whole library exists to
  # forbid, and does it silently. So the probe's own rc is captured and a bad
  # answer falls through to the refusal below, like every other unknown here.
  local probe_bad=""
  if [ "$rrc" -eq 0 ]; then
    # THE EMPTY DOCUMENT IS THE CONFIGURATION, and it is the one outcome that
    # must leave the command line alone. Read the LENGTH rather than compare
    # text: the render is free to format its output, and a string comparison
    # against one spelling of an empty object would turn a whitespace change
    # into a spawn policy change.
    local n probe_rc=0
    n="$(printf '%s' "$body" | jq -r '.mcpServers | length' 2>/dev/null)" || probe_rc=$?
    if [ "$probe_rc" -ne 0 ]; then
      probe_bad="the emptiness probe could not be run (jq answered rc $probe_rc)"
    else
      # THE ANSWER IS NOT QUOTED BACK. A probe that printed a warning, or a
      # shim standing in for jq, would put its output into the journal on the
      # one path that also handles a document naming credential files.
      case "$n" in
        ''|*[!0-9]*) probe_bad="the emptiness probe answered something that is not a count" ;;
      esac
    fi
  fi
  if [ "$rrc" -eq 0 ] && [ -z "$probe_bad" ]; then
    if [ "$n" = "0" ]; then
      rm -f "$doc"
      rm -f "$errf"
      return 3
    fi
    if ! _mcp_write_document "$doc" "$body"; then
      echo "mcp spawn: session '$sid' -- the document could not be written to $doc; REFUSING to prepare a spawn" >&2
      rm -f "$errf"
      return 69
    fi
    # THE PATH IS QUOTED, the same way NAME_ARG quotes its value. This fragment
    # is spliced into CLAUDE_CMD and then into a string a shell runs, so an
    # unquoted path with a space in it reaches claude as a TRUNCATED --mcp-config
    # plus a stray positional argument -- and under --strict-mcp-config that is a
    # session with no tools and nothing anywhere saying why. STATE_DIR_NAME is
    # validated and the session id is s-<hex>, so the injectable component today
    # is $HOME -- and the macOS twin sources this same library on homes named
    # /Users/First Last.
    printf ' --strict-mcp-config --mcp-config "%s"' "$doc"
    # DEGRADED IS DETECTED FROM THE RENDER'S OWN WORD. The render already
    # decided what "omitted" means and already named each one; re-deriving it
    # here would be a second opinion that can disagree with the first.
    if grep -q 'OMITTED' "$errf" 2>/dev/null; then
      cat "$errf" >&2; rm -f "$errf"
      return 1
    fi
    rm -f "$errf"
    return 0
  fi

  if [ -n "$probe_bad" ]; then
    echo "mcp spawn: session '$sid' -- $probe_bad, so whether anything was granted is NOT KNOWN; treating it as a REFUSAL (strict, empty) rather than as 'nothing was granted', which would hand the session the legacy set" >&2
  fi

  # EVERY OTHER RENDER OUTCOME IS A REFUSAL, and refusals fail closed. rc 65 is
  # the render's own (a level of the org would not load, or the set was
  # non-empty and nothing in it rendered); anything else that is not 0 or 69 is
  # unknown, and an unknown answer about a grant is not a reason to hand out
  # the legacy set.
  if ! _mcp_write_document "$doc" '{"mcpServers":{}}'; then
    echo "mcp spawn: session '$sid' -- the render refused (rc $rrc) and the empty document could not be written to $doc; REFUSING to prepare a spawn" >&2
    cat "$errf" >&2; rm -f "$errf"
    return 69
  fi
  printf ' --strict-mcp-config --mcp-config "%s"' "$doc"
  cat "$errf" >&2; rm -f "$errf"
  return 2
}

# mcp_claude_cmd_fragment <cont> <mcp-arg> <name-arg> <rc-label>
#
# THE COMMAND LINE, ASSEMBLED IN ONE PLACE SO IT CAN BE MEASURED. The
# supervisor has no suite of its own; keeping the exact order here is what lets
# test/mcpspawn.test.sh assert it.
#
# --remote-control "<label>" IS LAST, AND THAT IS LOAD-BEARING. The supervisor's
# pid-finding pattern anchors on the label, so a flag appended after it does not
# fail loudly -- it makes aliveness measurement quietly wrong, and a supervisor
# that misjudges aliveness enters a repair path that WRITES into live
# conversations. Every new argument goes BEFORE it.
#
# MCP-ARG AND NAME-ARG CARRY THEIR OWN LEADING SPACE when non-empty, and are
# empty strings otherwise. That is what makes the no-grant case produce the
# command line the fleet already runs, down to the byte.
mcp_claude_cmd_fragment() {
  local cont="${1:-}" mcp_arg="${2:-}" name_arg="${3:-}" label="${4:-}"
  if [ -n "$label" ]; then
    printf 'claude %s --permission-mode bypassPermissions%s%s --remote-control "%s"' \
      "$cont" "$mcp_arg" "$name_arg" "$label"
  else
    printf 'claude %s --permission-mode bypassPermissions%s%s' \
      "$cont" "$mcp_arg" "$name_arg"
  fi
}
