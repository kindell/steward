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
  local body rrc
  body="$(mcp_render_document "$sid" 2>"$errf")"; rrc=$?

  # rc 69 travels unchanged: the render could not build a document SAFELY, and
  # neither a legacy spawn nor an empty document is an honest answer to that.
  if [ "$rrc" -eq 69 ]; then
    cat "$errf" >&2; rm -f "$errf"
    return 69
  fi

  if [ "$rrc" -eq 0 ]; then
    # THE EMPTY DOCUMENT IS THE CONFIGURATION, and it is the one outcome that
    # must leave the command line alone. Read the LENGTH rather than compare
    # text: the render is free to format its output, and a string comparison
    # against one spelling of an empty object would turn a whitespace change
    # into a spawn policy change.
    local n
    n="$(printf '%s' "$body" | jq -r '.mcpServers | length' 2>/dev/null)"
    if [ "${n:-0}" = "0" ]; then
      rm -f "$doc"
      rm -f "$errf"
      return 3
    fi
    if ! _mcp_write_document "$doc" "$body"; then
      echo "mcp spawn: session '$sid' -- the document could not be written to $doc; REFUSING to prepare a spawn" >&2
      rm -f "$errf"
      return 69
    fi
    printf ' --strict-mcp-config --mcp-config %s' "$doc"
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
  printf ' --strict-mcp-config --mcp-config %s' "$doc"
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
