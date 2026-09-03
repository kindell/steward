#!/bin/bash
# lib/mcprender.sh -- the inherited MCP set, rendered as a claude mcp-config
# document. Sourced library, no side effects on source.
#
#   mcp_render_document <session-id>
#
# SOURCE lib/registry.sh FIRST. This library calls the registry's own resolver
# and loaders (registry_session_mcp_assets, registry_session_owning_entity,
# registry_mcp_asset_load, _registry_words, registry_printable) and deliberately
# does not source it itself: the two consumers -- bin/steward and the Linux
# session supervisor -- find that library in two different ways (a checkout
# root, a deployed ~/scripts/lib), and a library that reached for a second one
# on its own would load a different registry than its caller already had.
#
# THIS IS AN EXTRACTION, NOT A REWRITE. The body below was bin/steward's
# cmd_mcp_render verbatim; test/mcp-render.test.sh is unchanged and is the
# measurement that says the move changed nothing -- it drives `steward mcp
# render`, the verb, which is now this library's thin caller, so the same
# assertions that held before the extraction hold after it.
#
# Prints a claude-compatible mcp-config document for ONE session's effective
# MCP set -- the union lib/registry.sh's registry_session_mcp_assets derives
# from the managing team, the owning entity and the target project.
#
# THE PATTERN IS: PATHS ON COMMAND LINES, VALUES ONLY IN FILES. When an asset
# declares MCP_ENV_FILE the entry does not gain an `env` object holding the
# credential; it gains a WRAPPER that is handed the file's PATH and reads it
# itself. The difference is where the secret ends up: a rendered config is
# read by a process tree, quoted into logs, pasted into bug reports and
# printed by whoever is debugging the session at 2am. A path in all of those
# places is a path. A token in all of those places is a token in all of those
# places. The env file is a 0600 file on the host and stays one.
#
# AN ASSET IS RENDERED WHOLE OR NOT AT ALL. A granted asset whose definition
# is missing from the register is OMITTED and NAMED on stderr with the session
# id. The alternative — an entry with a key and no command — is a session that
# fails at start-up with no clue which server broke it, which is strictly
# worse than a server that was never offered.
#
# THE THREE EXIT CODES SAY THREE DIFFERENT THINGS, and the middle one is why
# this is not simply "print what worked":
#
#  rc 0 with servers — at least one asset rendered.
#  rc 0 with {}      — the set was EMPTY. Nobody granted anything: a
#                      configuration, and an honest empty document.
#  rc 65, no stdout  — either the set was NON-EMPTY and nothing in it
#                      rendered, or a LEVEL OF THE ORG would not load so the
#                      set could not be known. Both are faults. Printing {}
#                      for either would report a fault as the configuration
#                      above, and the reader could not tell them apart.
#
# A LEADING ~/ IN A ROW IS ONE HOME AT A TIME — THE RENDERING PROCESS'S OWN.
# The register is written once and read on every machine that runs a session
# for it; a row is not allowed to say whose home that is, only that it is
# relative to one. So `steward mcp render` run by hand from a checkout prints
# the OPERATOR's own home in any row that asked for it — that is what the verb
# means when it is run that way, not a bug. lib/mcpspawn.sh already resolves
# its wrapper's `~/bin/mcp-env` the same way, against $HOME, at spawn time;
# this file's rows now follow the same rule.

# THE SESSION ID IS THE WHOLE ARGUMENT LIST. Flag parsing stayed with the verb
# in bin/steward: a library that answers rc 64 for a flag would be describing a
# command line it does not own.
mcp_render_document() {
  local sid="${1:-}"
  [ -n "$sid" ] || {
    echo "steward: mcp render: needs a session id — steward mcp render <session-id>" >&2
    return 64
  }
  # THE BUILDER IS A DEPENDENCY, AND A MISSING ONE MUST REFUSE. A hand-rolled
  # printf would put an unescaped command path or argument straight into the
  # document — lib/sessions.sh refuses on the same grounds for the same tool.
  command -v jq >/dev/null 2>&1 || {
    echo "steward: mcp render: jq is required to build the document safely and is not on PATH" >&2
    return 69
  }

  # THE WRAPPER'S PATH IS A LITERAL BY DEFAULT, TILDE AND ALL. It is written
  # into the document as the string `~/bin/mcp-env` rather than resolved here,
  # because the document is rendered on the machine that HOLDS the register and
  # read on the machine that RUNS the session — and those are not always the
  # same home directory. Expanding it here would bake one operator's path into
  # every other operator's config.
  #
  # STEWARD_MCP_WRAPPER OVERRIDES IT, AND THE SUPERVISOR SETS IT. A caller that
  # renders ON the host at spawn time and hands the result straight to claude is
  # in the opposite situation: an MCP client spawns a server's `command`
  # DIRECTLY, with no shell between them, so a literal tilde is a directory
  # named "~" and the server dies with ENOENT — under --strict-mcp-config, a
  # granted asset that silently never starts. lib/mcpspawn.sh sets this to
  # $HOME/bin/mcp-env for its own render. The DEFAULT is unchanged so that
  # `steward mcp render` and test/mcp-render.test.sh stay byte for byte what
  # they were.
  local wrapper="${STEWARD_MCP_WRAPPER:-}"
  [ -n "$wrapper" ] || wrapper='~/bin/mcp-env'

  # THE RESOLVER'S RC IS READ, NOT JUST ITS OUTPUT. Its middle code says "at
  # least one level of the org would not load, so what follows is PARTIAL" —
  # and a partial set rendered as a document is the one thing the three exit
  # codes below exist to prevent. A spawner reading rc 0 and an empty (or
  # short) document cannot tell "nobody granted anything" from "one mistyped
  # team name hid every capability under this client", so the render refuses
  # rather than answer for a set it was told is not the whole grant.
  local set_lines set_rc
  set_lines="$(registry_session_mcp_assets "$sid")"; set_rc=$?
  if [ "$set_rc" -eq 65 ]; then
    echo "steward: mcp render: session '$sid' — a level of the org would not load (the cause is named above), so the granted set is not known; refusing rather than printing a document that would read as what somebody actually granted" >&2
    return 65
  fi
  [ "$set_rc" -eq 0 ] || return 65

  # THE `<domain>` THE TEMPLATE SUBSTITUTES IS THE OWNING ENTITY, not the
  # row's DOMAIN field. An env file holds a CLIENT's credentials and lives
  # under that client's own directory; a session aimed at a project derives a
  # DOMAIN equal to the PROJECT slug (lib/registry.sh, registry_load), so
  # substituting that would look for the file one level below where it is.
  # Same join the resolver used to build the set, from the same function.
  # AN ILLEGAL SLUG IS NOT A MISSING ONE. registry_session_owning_entity
  # answers rc 65 for a value that resolved but is not a name — the case that
  # let a projects.d PARENT="../projects.d/<other>" reach a credential path.
  # It cannot arrive here (the resolver above already refused the whole render
  # on the same signal) and is still handled rather than folded into the
  # empty case, so a future caller order cannot make it fall through.
  local domain domain_rc
  domain="$( registry_session_owning_entity "$sid" )"; domain_rc=$?
  [ "$domain_rc" -eq 0 ] || domain=""

  local objs=() slug total=0 rendered=0
  # A HERE-DOCUMENT, NOT A PIPELINE. `... | while read` runs the loop in a
  # subshell and every object it built would be discarded at the `done`.
  while IFS= read -r slug; do
    [ -n "$slug" ] || continue
    total=$((total + 1))
    # THE LOADER'S OWN STDERR IS LET THROUGH. One catch-all sentence stood for
    # three genuinely different faults — no such row, a slug that breaks the
    # grammar, a row with no MCP_COMMAND — and the loader had already written
    # the precise one before it was thrown away. Measured with a conf saved
    # CRLF (MCP_ASSETS="chat-tool<CR>"): the operator was told to go look for a
    # definition that is sitting right there and is fine. Only stdout is
    # dropped, and only because the row is SOURCED and must not be able to
    # write into the document being built.
    #
    # THE SLUG IS NAMED THROUGH registry_printable for the same measurement: a
    # raw carriage return in it returns the cursor and the rest of this
    # sentence overwrites the part that named it.
    if ! registry_mcp_asset_load "$slug" >/dev/null; then
      echo "steward: mcp render: session '$sid': the asset '$(registry_printable "$slug")' has no usable definition in the mcp register (the reason is named above) — OMITTED from the document" >&2
      continue
    fi
    local cmdpath="$MCP_COMMAND" envf="$MCP_ENV_FILE"
    # THE SPLIT GOES THROUGH THE REGISTRY'S OWN HELPER, under `set -f`: an
    # MCP_ARGS containing an asterisk must reach the server's argv as an
    # asterisk, not as whatever happens to sit in the operator's cwd.
    _registry_words "$MCP_ARGS"
    local argv=( "${REGISTRY_WORDS[@]+"${REGISTRY_WORDS[@]}"}" )

    # A LEADING ~/ IN A ROW IS THE RENDERING PROCESS'S OWN $HOME. The register
    # is written once, on the machine that HOLDS it, and read on every machine
    # that RUNS a session for it — and on a team of more than one person those
    # are different home directories. A row that hardcoded one member's
    # `/home/alice/...` handed alice's paths to bob's session too, which bob
    # cannot even read (a home is 750) and the server dies in the handshake.
    # `~/` fixes that the way lib/mcpspawn.sh already fixes it for the
    # wrapper's own path (~:121 there): write the row relative to the
    # OPERATOR's home and let the process that renders it supply the home.
    #
    # ONLY A LEADING `~/` COUNTS, and only that. `~` alone and `~user/...` are
    # a passwd lookup for a DIFFERENT user's home, not a string this function
    # owns — resolving it would need getent/dscl, a second kind of lookup this
    # loop has no business doing, and the row almost certainly did not mean
    # "some other named account's home" anyway. A `~/` that shows up in the
    # MIDDLE of a word (the `a~/b` case the fixture carries) is DATA, not a
    # path prefix, and rewriting it would corrupt an argument the row meant
    # literally. `case "$x" in "~/"*)` matches exactly the leading form and
    # nothing else, with no `eval` and no shell tilde-expansion (`set -f`
    # already governs this loop for the same reason).
    local home_needed=0
    case "$cmdpath" in "~/"*) home_needed=1 ;; esac
    case "$envf" in "~/"*) home_needed=1 ;; esac
    local _hw
    for _hw in "${argv[@]+"${argv[@]}"}"; do
      case "$_hw" in "~/"*) home_needed=1 ;; esac
    done
    if [ "$home_needed" -eq 1 ]; then
      if [ -z "${HOME:-}" ]; then
        # THE SAME HOLE THE <domain> BRANCH BELOW NAMES, IN THE SAME WORDS:
        # a template that needs a value this process does not have is OMITTED
        # and NAMED rather than rendered with the tilde left in — a literal
        # "~" reaching an MCP client that spawns `command` directly (no shell
        # between them) is a directory named "~", and the server dies with
        # ENOENT under --strict-mcp-config with no clue why.
        echo "steward: mcp render: session '$sid': the asset '$(registry_printable "$slug")' names a home-relative path (~/) and HOME is unset in this process — OMITTED rather than rendered against a hole" >&2
        continue
      fi
      case "$cmdpath" in "~/"*) cmdpath="$HOME/${cmdpath#"~/"}" ;; esac
      case "$envf" in "~/"*) envf="$HOME/${envf#"~/"}" ;; esac
      # NO `+` GUARD HERE, UNLIKE THE VALUE FORM ABOVE (and the detection loop
      # three lines up). Two independent reasons, not one: first, the INDEX
      # form `${!argv[@]}` does not trip `set -u` on an empty array even on
      # bash 3.2.57, unlike `${argv[@]}` — so no guard is needed for safety.
      # Second, the guard idiom used elsewhere in this file, applied literally
      # to the index form as `${!argv[@]+"${!argv[@]}"}`, is not equivalent to
      # it: bash's `!name[@]` "list of keys" grammar does not compose with a
      # trailing `+word` the way the plain `name[@]+word` form does, and
      # collapses to empty instead of the real indices — verified empirically,
      # not assumed. Adding it here would silently break this loop on every
      # non-empty argv. Left unguarded on purpose.
      local _hi
      for _hi in "${!argv[@]}"; do
        case "${argv[$_hi]}" in "~/"*) argv[$_hi]="$HOME/${argv[$_hi]#"~/"}" ;; esac
      done
    fi

    if [ -n "$envf" ]; then
      case "$envf" in
        *"<domain>"*)
          if [ -z "$domain" ]; then
            echo "steward: mcp render: session '$sid': the asset '$(registry_printable "$slug")' has an MCP_ENV_FILE template naming <domain> and this session resolves to no owning entity — OMITTED rather than rendered against a hole" >&2
            continue
          fi
          envf="${envf//<domain>/$domain}"
          ;;
      esac
      argv=( "$envf" "$cmdpath" "${argv[@]+"${argv[@]}"}" )
      cmdpath="$wrapper"
    fi
    # `--` IS LOAD-BEARING. jq parses options anywhere on its command line,
    # including after --args: an argument that happens to spell an option
    # token would be consumed as one instead of handed to the filter as data.
    # lib/sessions.sh measured exactly that and carries the same note.
    objs[${#objs[@]}]="$(jq -cn --arg name "$slug" --arg cmd "$cmdpath" --args \
      '{($name): {command: $cmd, args: $ARGS.positional}}' -- "${argv[@]+"${argv[@]}"}")" || {
      echo "steward: mcp render: session '$sid': the asset '$(registry_printable "$slug")' could not be encoded as JSON — OMITTED" >&2
      continue
    }
    rendered=$((rendered + 1))
  done <<EOF
$set_lines
EOF

  if [ "$total" -gt 0 ] && [ "$rendered" -eq 0 ]; then
    echo "steward: mcp render: session '$sid' — $total asset(s) are granted and NONE could be rendered; refusing rather than printing an empty document that would read as 'nothing was granted'" >&2
    return 65
  fi
  if [ "$rendered" -eq 0 ]; then
    # THE EMPTY SET, STATED. mcpServers is present and empty rather than
    # absent: a consumer reading `.mcpServers` gets an object either way and
    # never has to tell a missing key from an empty one.
    jq -n '{mcpServers: {}}'
    return 0
  fi
  # KEY ORDER IS THE INHERITANCE ORDER. jq preserves insertion order, and the
  # objects were built in the order the resolver emitted them — broadest grant
  # first — so the document reads the org from the outside in.
  printf '%s\n' "${objs[@]}" | jq -s '{mcpServers: (add // {})}'
}
