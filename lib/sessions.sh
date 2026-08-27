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

# session_identity_rows — one TSV row per session on stdout:
#   name<TAB>id<TAB>owner<TAB>domain<TAB>host<TAB>entity_name<TAB>entity_relation<TAB>assets
# rc 0 ok (including zero sessions) · rc 1 the registry could not be read.
session_identity_rows() {
  if ! command -v registry_load >/dev/null 2>&1; then
    local _here; _here="$(CDPATH= cd -- "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    # shellcheck source=registry.sh
    . "$_here/registry.sh" || { echo "sessions: could not load the registry" >&2; return 1; }
  fi
  local names
  names="$(registry_list)" || return 1

  local n entity_dir; entity_dir="$(registry_entity_dir)"
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
    if ! registry_load "$n" >/dev/null 2>&1; then
      # A SESSION THAT EXISTS BUT WON'T LOAD IS DIAGNOSIS, NOT SILENCE. This
      # layer's contract is data on stdout, diagnosis on stderr, meaning in the
      # return code — dropping the name here would make one bad conf vanish
      # from the output with no trace of why the row count came up short.
      echo "sessions: skipping '$n' — the registry would not load it" >&2
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
    local ent_name="-" ent_rel="-" ent_conf="$entity_dir/$domain.conf"
    if [ -f "$ent_conf" ]; then
      ent_name="$(sed -n 's/^NAME="\(.*\)"/\1/p' "$ent_conf" | head -1)"
      [ -n "$ent_name" ] || ent_name="-"
      # TWO RELATIONS, READ AS THEMSELVES. MEMBERS names the people who work FOR
      # this entity; MANAGED_BY names the entity this one is a client of. They
      # answer different questions and must not collapse into one word. A
      # non-empty VALUE is required, not just the key's presence — a stale or
      # template MANAGED_BY="" must fall through to MEMBERS, not read as
      # "client" because the line happens to exist.
      local ent_managed_by ent_members
      ent_managed_by="$(sed -n 's/^MANAGED_BY="\(.*\)"/\1/p' "$ent_conf" | head -1)"
      ent_members="$(sed -n 's/^MEMBERS="\(.*\)"/\1/p' "$ent_conf" | head -1)"
      if [ -n "$ent_managed_by" ]; then ent_rel="client"
      elif [ -n "$ent_members" ]; then ent_rel="team"
      fi
    fi
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
      "$n" "$id" "$owner" "$domain" "$host" "$ent_name" "$ent_rel" "$assets"
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
  if [ "$total" -gt 0 ] && [ "$loaded" -eq 0 ]; then
    echo "sessions: REFUSING — $total session(s) listed and none could be loaded;" \
         "the estate file is likely missing or missing a required field" \
         "(LABEL_PREFIX, HUB_HOST, OP_TOKEN_FILE_NAME) — see the lines above" >&2
    return 1
  fi
  return 0
}
