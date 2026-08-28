#!/bin/bash
# lib/sessions.sh — the identity layer: who is a session, out of the registry.
#
# WHY THIS IS ITS OWN FILE. A session's identity is a local file read: no
# network, no remote host, no subprocess that can hang. Liveness is none of
# those things — it shells out and can fail. Putting them in one function would
# make the cheap, always-available answer inherit the expensive one's failure
# modes, and a caller could then no longer tell which half went wrong.
#
# TSV, NOT JSON. This layer's consumer is another shell function that joins it
# with liveness before anything is rendered. Emitting JSON here would mean
# parsing it back out one line later; the rendering belongs to the command.
#
# EVERY ROW HAS EVERY FIELD. An empty value is a dash, never an empty column: a
# row whose columns shift because one value was blank is a row the consumer
# parses wrong, and the consumer is a view that would draw the shift as data.
#
# ...AND THE SEPARATOR NEVER SURVIVES INSIDE A VALUE. The guarantee above is
# about field PRESENCE; it is worth nothing unless field CONTENT is escaped
# too. ASSETS is, in bin/probe-dispatch's own words, "the one registry field
# registry_load resets without validating" — lib/scaffold.sh guards the write
# path, but session-new.sh and a hand-edited conf both bypass it — and the
# entity display name is validated for presence, never for charset. Measured
# 2026-08-28 against a raw printf: an ASSETS value carrying a tab and a newline
# put ONE conf in and got TWO sessions out, rc 0, silence on both streams — a
# session that does not exist, in the document a view is being built to read.
# Every row therefore leaves through `jq -r @tsv`, which escapes tab, newline,
# CR and backslash — the same mechanism lib/liveness.sh already uses, and
# exactly why that half of the chain was never injectable. ESCAPE RATHER THAN
# REFUSE, because this layer's job is to report the registry as it is: a
# refusal would let one odd asset string hide every other session, which is the
# systemic-failure shape the rest of this file exists to avoid.

# _sessions_tsv_row <field...> — the fields as one escaped TSV row on stdout.
# Positional arguments, never a format string: a value that happened to contain
# a percent sign must not be able to reach printf's parser either.
_sessions_tsv_row() {
  jq -rn --args '$ARGS.positional | @tsv' "$@"
}

# session_identity_rows — one TSV row per session on stdout:
#   name<TAB>id<TAB>owner<TAB>domain<TAB>host<TAB>entity_name<TAB>entity_relation<TAB>assets
# rc 0 ok (including zero sessions) · rc 1 the registry could not be read.
#
# ALSO SETS SESSIONS_UNREADABLE: one name per line for every session that is in
# the registry but could not be loaded. The stderr sentence is for a human at a
# terminal; the declared consumer of this layer is a view reading a subprocess'
# stdout, and telling it to capture and correlate a second stream is exactly
# the kind of instruction that does not survive contact with a client. The
# variable is reset on every call, so a previous run's failures never leak into
# this one's answer.
session_identity_rows() {
  SESSIONS_UNREADABLE=""
  if ! command -v registry_load >/dev/null 2>&1; then
    local _here; _here="$(CDPATH= cd -- "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    # shellcheck source=registry.sh
    . "$_here/registry.sh" || { echo "sessions: could not load the registry" >&2; return 1; }
  fi
  # THE ESCAPER IS A DEPENDENCY, AND A MISSING ONE MUST REFUSE. Falling back to
  # a raw printf when jq is absent would restore the injection this layer was
  # fixed for, on the one machine least likely to notice.
  if ! command -v jq >/dev/null 2>&1; then
    echo "sessions: REFUSING — jq is required to emit a row safely and is not on PATH" >&2
    return 1
  fi
  local names
  names="$(registry_list)" || return 1

  local n entity_dir; entity_dir="$(registry_entity_dir)"
  # ONE SCRATCH FILE FOR THE WHOLE SWEEP, reused per session and removed on
  # every return path below.
  local _diagfile; _diagfile="$(mktemp)" || {
    echo "sessions: REFUSING — could not create a temporary file" >&2; return 1; }
  # COUNT LISTED VS LOADED. registry_load refuses every session identically
  # when the estate file is missing or missing a required field — registry_list
  # still succeeds in that state, so a loop that only ever `continue`s past a
  # load failure returns rc 0 with zero rows, indistinguishable from an estate
  # that genuinely has no sessions. Counting both lets the caller tell "the
  # registry is empty" from "the registry could not be read" apart below.
  local total=0 loaded=0
  # READ LINE BY LINE, do not word-split. Session names are validated to a safe
  # charset upstream, but an unquoted expansion here would still glob against
  # the caller's cwd — the exact hazard lib/assets.sh needed `set -f` for.
  while IFS= read -r n; do
    [ -n "$n" ] || continue
    total=$((total + 1))
    # THE CAUSE IS THE ONLY USEFUL HALF OF THIS DIAGNOSTIC. registry_load
    # already says WHICH field is wrong ("missing REPO_PATH", "invalid HOST
    # 'x'"); discarding that to >/dev/null and replacing it with a generic
    # sentence leaves an operator knowing a conf is bad and not what to edit.
    # Collapsed to one line so one bad conf stays one line of output.
    local _cause _lrc
    # A FILE, NOT A COMMAND SUBSTITUTION. registry_load writes the session's
    # fields into THIS shell as globals; `$(registry_load ...)` would run it in
    # a subshell and every field below would read as a dash. And not a pipeline
    # either — `cmd | tr` makes the captured status tr's, which is always 0, so
    # every session would read as loaded.
    : > "$_diagfile"
    registry_load "$n" >/dev/null 2>"$_diagfile"; _lrc=$?
    _cause="$(tr '\n' ' ' < "$_diagfile")"
    if [ "$_lrc" -ne 0 ]; then
      # A SESSION THAT EXISTS BUT WON'T LOAD IS DIAGNOSIS, NOT SILENCE. This
      # layer's contract is data on stdout, diagnosis on stderr, meaning in the
      # return code — dropping the name here would make one bad conf vanish
      # from the output with no trace of why the row count came up short.
      # Some of registry_load's refusals are silent returns (the runtime
      # validations), so an empty cause is itself reported rather than
      # rendered as a sentence that trails off.
      [ -n "$_cause" ] || _cause="no reason given (rc $_lrc)"
      echo "sessions: skipping '$n' — the registry would not load it: $_cause" >&2
      SESSIONS_UNREADABLE="${SESSIONS_UNREADABLE}$n"$'\n'
      continue
    fi
    loaded=$((loaded + 1))
    # SNAPSHOT BEFORE USING. registry_load writes into this shell, and the next
    # iteration overwrites every one of these — read them out first.
    local id owner domain host assets
    id="${ID:-$n}"; owner="${OWNER:--}"; domain="${DOMAIN:--}"
    host="${HOST:--}"; assets="${ASSETS:-}"
    [ -n "$assets" ] || assets="-"

    # THE ENTITY IS A JOIN, AND A MISSING ONE IS NOT AN ERROR. A session may
    # name a domain no entity file describes yet — that is a gap in the
    # registry, not a failure of this read, and refusing here would make one
    # unfinished entity hide every other session.
    #
    # THE JOIN GOES THROUGH THE REGISTRY'S OWN LOADER, not a second parse.
    # registry_entity_load handles single-quoted values, requires a NAME, and
    # resolves MANAGED_BY through itself so a relation pointing at nothing is
    # refused rather than reported as `client`. The sed this replaced matched
    # only double-quoted values and greedily to the last quote on the line:
    # measured 2026-08-28, NAME='Acme Ltd' read as no entity at all — a false
    # `null` indistinguishable from the honest "no entity file describes this
    # domain" the dash below is for.
    local ent_name="-" ent_rel="-" ent_conf="$entity_dir/$domain.conf"
    if [ -f "$ent_conf" ]; then
      local _ecause
      # Same reason as the load above: the ENTITY_* globals must land in this
      # shell, so the stderr goes to a file rather than through a subshell.
      : > "$_diagfile"
      registry_entity_load "$domain" >/dev/null 2>"$_diagfile"
      _ecause="$(tr '\n' ' ' < "$_diagfile")"
      if [ -n "$ENTITY_NAME" ]; then
        ent_name="$ENTITY_NAME"
        # TWO RELATIONS, READ AS THEMSELVES. MEMBERS names the people who work
        # FOR this entity; MANAGED_BY names the entity this one is a client of.
        # They answer different questions and must not collapse into one word.
        # A non-empty VALUE is required, not just the key's presence — a stale
        # or template MANAGED_BY="" must fall through to MEMBERS, not read as
        # "client" because the line happens to exist.
        if   [ -n "$ENTITY_MANAGED_BY" ]; then ent_rel="client"
        elif [ -n "$ENTITY_MEMBERS" ];    then ent_rel="team"
        fi
      else
        # AN ENTITY FILE THAT EXISTS AND WILL NOT LOAD IS NOT THE SAME FACT AS
        # NO ENTITY FILE. The row still carries dashes — the session itself is
        # readable and must not vanish over its domain — but the cause is said
        # out loud rather than rendered as an absence.
        [ -n "$_ecause" ] || _ecause="no reason given"
        echo "sessions: '$n' — the entity '$domain' exists but would not load: $_ecause" >&2
      fi
    fi
    _sessions_tsv_row "$n" "$id" "$owner" "$domain" "$host" "$ent_name" "$ent_rel" "$assets"
  done <<EOF
$names
EOF

  # AN ALL-FAIL IS A DIFFERENT ANSWER FROM "NO SESSIONS", NOT A WORSE CASE OF
  # IT. registry_list listing one or more names and every one of them failing
  # to load is not an estate with no sessions — it is a registry that could
  # not be read (a missing estate file, or one missing LABEL_PREFIX / HUB_HOST
  # / OP_TOKEN_FILE_NAME). Nothing was printed above in this branch, since the
  # loop only prints a row for a session that loaded — so stdout is already
  # empty here, matching the refusal this returns.
  rm -f "$_diagfile"

  if [ "$total" -gt 0 ] && [ "$loaded" -eq 0 ]; then
    echo "sessions: REFUSING — $total session(s) listed and none could be loaded;" \
         "the estate file is likely missing or missing a required field" \
         "(LABEL_PREFIX, HUB_HOST, OP_TOKEN_FILE_NAME) — see the lines above" >&2
    return 1
  fi
  return 0
}
