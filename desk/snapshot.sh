#!/bin/bash
# desk/snapshot.sh - the desk's producer: one filtered JSON per principal,
# written into a fresh generation and swapped in with a single symlink.
#
# WHY A FILE PER VIEWER AND NOT ONE DOCUMENT PLUS A SERVER-SIDE FILTER. The
# server that hands these out (Task 4) is the part exposed to the network, and
# a filter that lives inside it is a filter that a request can be aimed at. A
# file that was never written cannot be served by a bug: `c.json` does not
# contain a colleague's session because the bytes are not on the disk, not
# because a code path declined to print them. The gate is the filesystem.
#
# THE FILTER IS A POSITIVE ALLOWLIST AND IT LIVES IN ONE FILE - desk/filter.jq.
# This script builds a RAW document that deliberately carries more than any
# viewer may see, and every viewer file is that raw document run through the
# one filter with three arguments. Nothing in this script writes a viewer file
# any other way.
#
# THE RAW DOCUMENT NEVER LEAVES THIS PROCESS. It is built in a temp directory
# that this script removes on every exit path, and the estate values that must
# never travel (a repository PATH, an MCP command line, a browser port) are
# either never read or reduced here - REPO_PATH becomes its basename before it
# is ever put into JSON.
#
# Exit codes: 0 ok - 69 jq is missing - 73 the desk directory cannot be
# written - 78 the estate or the registry would not load.
set -u
here="$(CDPATH= cd -- "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# THE LIBRARY SITS ONE HOP UP IN BOTH LAYOUTS: desk/ beside lib/ at the repo
# root, and scripts/desk/ beside scripts/lib/ in a deployed home.
# STEWARD_REGISTRY_LIB overrides; found nowhere is a refusal.
if [ -n "${STEWARD_REGISTRY_LIB:-}" ]; then
  # shellcheck source=/dev/null
  . "$STEWARD_REGISTRY_LIB" || exit 78
elif [ -f "$here/../lib/registry.sh" ]; then
  # shellcheck source=/dev/null
  . "$here/../lib/registry.sh" || exit 78
else
  echo "desk snapshot: the registry library was found in neither layout (from $here)" >&2
  exit 78
fi
command -v jq >/dev/null 2>&1 || { echo "desk snapshot: jq is required" >&2; exit 69; }
steward="$here/../bin/steward"

# --- WHERE THE SNAPSHOT LANDS ---------------------------------------------
# STEWARD_DESK_DIR is the operator's override; without it the location comes
# from the same bridge the server reads, so the two never disagree.
dir="${STEWARD_DESK_DIR:-}"
if [ -z "$dir" ]; then
  paths="$("$here/bin/desk-paths")" || exit 78
  dir="$(printf '%s\n' "$paths" | sed -n 's/^dir=//p')"
  [ -n "$dir" ] || { echo "desk snapshot: desk-paths named no directory" >&2; exit 78; }
fi

tmp="$(mktemp -d)" || { echo "desk snapshot: could not create a temporary directory" >&2; exit 73; }
trap 'rm -rf "$tmp"' EXIT

generated_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
host_name="$(hostname 2>/dev/null || uname -n 2>/dev/null || printf 'unknown')"
estate_dir="$(dirname "$(registry_estate_file 2>/dev/null || printf '%s' '.')")"
revision="$(git -C "$estate_dir" rev-parse --short HEAD 2>/dev/null)"
[ -n "$revision" ] || revision="unknown"

# --- THE LIVENESS ANSWER --------------------------------------------------
# ONE CALL FOR THE WHOLE FLEET, and it is a subprocess rather than a library
# call because the measurement lives behind `steward sessions --json` and the
# seam it dispatches to is the estate's own.
#
# STEWARD_DESK_SESSIONS_JSON IS AN OPERATOR OVERRIDE, not a test hook: an
# estate that already collects this document on a schedule (or on another
# machine) points the snapshot at the file instead of paying for a second
# measurement on every run.
#
# A MISSING OR UNPARSEABLE ANSWER IS `unknown`, NEVER A FAILED SNAPSHOT. The
# desk's other half - who owns what, and who may see it - is fully readable
# without any liveness at all, and a desk that refused to render because a
# multiplexer was down would be dark exactly when it is wanted.
live_raw=""
if [ -n "${STEWARD_DESK_SESSIONS_JSON:-}" ]; then
  live_raw="$(cat "$STEWARD_DESK_SESSIONS_JSON" 2>/dev/null)" || live_raw=""
elif [ -x "$steward" ]; then
  live_raw="$("$steward" sessions --json 2>/dev/null)" || live_raw=""
fi
live_map="$(printf '%s' "$live_raw" | jq -c '
  [ (.sessions // [])[] | { key: (.id // .name // ""), value: (.liveness // {}) } ] | from_entries' 2>/dev/null)" \
  || live_map=""
[ -n "$live_map" ] || live_map='{}'

# --- THE RAW DOCUMENT, ONE REGISTER AT A TIME -----------------------------
# EACH ROW IS LOADED IN ITS OWN SUBSHELL - the registry-dump pattern. The
# loaders set globals, and a row that fails to load must never leave the
# previous row's values behind for the next one to print as its own.
principals_f="$tmp/principals.jsonl"; : > "$principals_f"
entities_f="$tmp/entities.jsonl";     : > "$entities_f"
projects_f="$tmp/projects.jsonl";     : > "$projects_f"
sessions_f="$tmp/sessions.jsonl";     : > "$sessions_f"

# PRINCIPALS. The register has no list function of its own, so the directory is
# globbed the way registry-dump globs hosts.d.
pdir="$(registry_principal_dir)" || exit 78
if [ -d "$pdir" ]; then
  for f in "$pdir"/*.conf; do
    [ -e "$f" ] || continue
    p="$(basename "$f" .conf)"
    (
      registry_principal_load "$p" >/dev/null 2>&1 || {
        echo "desk snapshot: principal '$p': the registry refuses the row - skipped" >&2; exit 0; }
      read_all=false
      [ "$PRINCIPAL_DESK_READ_ALL" = "yes" ] && read_all=true
      jq -cn --arg id "$PRINCIPAL_ID" --arg name "$PRINCIPAL_NAME" --argjson readAll "$read_all" \
        '{id:$id,name:$name,readAll:$readAll}'
    ) >> "$principals_f"
  done
fi

# ENTITIES. MEMBERS is the estate's space-separated word list; it is split here
# so the filter can test membership without knowing the storage idiom.
ents="$(registry_entity_list)" || exit 78
while IFS= read -r e; do
  [ -n "$e" ] || continue
  (
    registry_entity_load "$e" >/dev/null 2>&1 || {
      echo "desk snapshot: entity '$e': the registry refuses the row - skipped" >&2; exit 0; }
    jq -cn --arg id "$ENTITY_ID" --arg name "$ENTITY_NAME" \
           --arg managedBy "$ENTITY_MANAGED_BY" --arg members "$ENTITY_MEMBERS" \
      '{id:$id, name:$name,
        managedBy: (if $managedBy == "" then null else $managedBy end),
        members: ($members | [splits("[ \t\n]+")] | map(select(length > 0)))}'
  ) >> "$entities_f"
done <<< "$ents"

# PROJECTS.
projs="$(registry_project_list)" || exit 78
while IFS= read -r pr; do
  [ -n "$pr" ] || continue
  (
    registry_project_load "$pr" >/dev/null 2>&1 || {
      echo "desk snapshot: project '$pr': the registry refuses the row - skipped" >&2; exit 0; }
    jq -cn --arg id "$PROJECT_ID" --arg name "$PROJECT_NAME" --arg parent "$PROJECT_PARENT" \
      '{id:$id, name:$name, parent:(if $parent == "" then null else $parent end)}'
  ) >> "$projects_f"
done <<< "$projs"

# SESSIONS. The one row that reaches into three other places: the display name,
# the owning entity, and the MCP surface.
names="$(registry_list)" || exit 78
while IFS= read -r n; do
  [ -n "$n" ] || continue
  (
    registry_load "$n" >/dev/null 2>&1 || {
      echo "desk snapshot: session '$n': the registry refuses the row - skipped" >&2; exit 0; }
    label="$(registry_session_display "$n" 2>/dev/null)" || label="$n"
    [ -n "$label" ] || label="$n"
    domain="$(registry_session_owning_entity "$n" 2>/dev/null)" || domain=""
    # A NAME, NEVER THE PATH. A repository path names a directory on a machine
    # a colleague has no account on; the name is what a desk shows, and the
    # path is what an allowlist exists to keep out of the answer.
    repo=""
    [ -n "${REPO_PATH:-}" ] && repo="$(basename "$REPO_PATH")"
    # THE MCP SURFACE COMES FROM THE VERB THAT ALREADY REFUSES TO PRINT A
    # COMMAND LINE, not from the mcp register. rc != 0 means the org would not
    # resolve, and an unresolved surface is `null` plus a reason in the RAW
    # document - never an empty list, which would read as "granted nothing".
    mcp="null"; mcp_reason="unknown"
    if surface="$("$steward" mcp surface "$n" --json 2>/dev/null)"; then
      if assets="$(printf '%s' "$surface" | jq -c '.assets // []' 2>/dev/null)"; then
        mcp="$assets"; mcp_reason=""
      fi
    fi
    sid="${ID:-$n}"
    live="$(printf '%s' "$live_map" | jq -c --arg k "$sid" '.[$k] // {}' 2>/dev/null)" || live="{}"
    [ -n "$live" ] || live="{}"
    jq -cn --arg id "$sid" --arg slug "${SLUG:-$n}" --arg label "$label" \
           --arg owner "${OWNER:-}" --arg domain "$domain" --arg project "${TARGET_PROJECT:-}" \
           --arg runtime "${RUNTIME:-claude-code}" --arg host "${HOST:-}" --arg repo "$repo" \
           --arg measuredAt "$generated_at" --argjson live "$live" \
           --argjson mcp "$mcp" --arg mcpReason "$mcp_reason" '
      def blank($v): if $v == "" then null else $v end;
      {id:$id, slug:$slug, label:$label, owner:$owner,
       domain: blank($domain), project: blank($project),
       runtime: $runtime, host: $host, repo: $repo,
       # THE AGE IS DERIVED HERE, NOT LEFT TO EVERY READER. `lastActivity` is
       # whatever the seam printed; a reader that parsed it itself would have
       # to decide what an unparseable value means, and three readers would
       # decide three ways. Unparseable or absent is null - an age nobody
       # could measure, said out loud.
       liveness: {state: ($live.agent // "unknown"),
                  measuredAt: $measuredAt,
                  ageSeconds: (($live.lastActivity // null) as $la
                               | if $la == null then null
                                 else (try ((now - ($la | fromdateiso8601)) | floor) catch null)
                                 end)},
       mcp: $mcp, mcpReason: blank($mcpReason)}'
  ) >> "$sessions_f"
done <<< "$names"

raw="$tmp/raw.json"
jq -n --arg host "$host_name" --arg generatedAt "$generated_at" --arg registryRevision "$revision" \
      --slurpfile principals "$principals_f" --slurpfile entities "$entities_f" \
      --slurpfile projects "$projects_f" --slurpfile sessions "$sessions_f" \
  '{host:$host, generatedAt:$generatedAt, registryRevision:$registryRevision,
    principals:$principals, entities:$entities, projects:$projects, sessions:$sessions}' \
  > "$raw" || { echo "desk snapshot: the raw document would not assemble" >&2; exit 78; }

# --- GENERATIONS ----------------------------------------------------------
# A RUN NEVER WRITES INTO THE DIRECTORY A READER IS READING. Every run builds a
# whole new `gen-<epoch>` and then moves one symlink; a reader either sees the
# previous generation complete or the new one complete, and never a directory
# with three of four files rewritten. The per-file `.tmp` + `mv` below is the
# second half of the same promise: no reader ever opens a half-written file.
mkdir -p "$dir" || { echo "desk snapshot: cannot create $dir" >&2; exit 73; }
epoch="$(date -u +%s)"
gen=""
if mkdir "$dir/gen-$epoch" 2>/dev/null; then
  gen="gen-$epoch"
else
  # THE SAME SECOND CAN REPEAT - two runs a second apart is a schedule, two in
  # the same second is a schedule plus a hand. The suffix is zero-padded so the
  # plain lexicographic sort the pruner uses stays the chronological one.
  i=1
  while [ "$i" -le 99 ]; do
    cand="$(printf 'gen-%s-%02d' "$epoch" "$i")"
    if mkdir "$dir/$cand" 2>/dev/null; then gen="$cand"; break; fi
    i=$((i + 1))
  done
fi
[ -n "$gen" ] || { echo "desk snapshot: could not create a generation directory in $dir" >&2; exit 73; }

write_view() { # <basename> <viewer> <readAll json> <memberOf json>
  jq --arg viewer "$2" --argjson readAll "$3" --argjson memberOf "$4" \
     -f "$here/filter.jq" "$raw" > "$dir/$gen/$1.json.tmp" || return 1
  mv -f "$dir/$gen/$1.json.tmp" "$dir/$gen/$1.json"
}

rc=0
while IFS= read -r p; do
  [ -n "$p" ] || continue
  read_all="$(jq -r --arg p "$p" '.principals[] | select(.id == $p) | .readAll' "$raw")"
  [ -n "$read_all" ] || read_all=false
  # MEMBERSHIP IS READ OFF THE ENTITY ROWS, NOT OFF THE PRINCIPAL ROW. A
  # principal row says who a person is; the entities say who they belong to,
  # and the desk must answer from the same rows the org is administered in.
  member_of="$(jq -c --arg p "$p" '[ .entities[] | select(.members | index($p)) | .id ]' "$raw")"
  [ -n "$member_of" ] || member_of='[]'
  write_view "$p" "$p" "$read_all" "$member_of" || rc=1
done < <(jq -r '.principals[].id' "$raw")

# THE OPERATOR FILE IS THE UNFILTERED VIEW, AND IT IS STILL WRITTEN THROUGH THE
# FILTER. Building it any other way would make it the one file whose shape the
# allowlist does not describe - and the one file a server is most likely to
# serve by mistake.
write_view "_operator" "_operator" true '[]' || rc=1

# ONE SYMLINK, REPLACED IN PLACE. `mv -f` onto an existing symlink-to-directory
# does NOT replace it on BSD - it moves the new link INSIDE the old target
# (measured on macOS: the link landed as current/current.tmp and `current` never
# moved). `ln -sfn` replaces the link itself on both BSD and GNU, and is the
# only portable spelling of this swap.
ln -sfn "$gen" "$dir/current" || { echo "desk snapshot: could not point $dir/current at $gen" >&2; exit 73; }

# KEEP TWO GENERATIONS: the one being served and the one a reader may still
# have open. Older ones are the previous week's answers and nobody asks them.
gens="$(cd "$dir" && ls -1d gen-* 2>/dev/null | sort)"
total="$(printf '%s\n' "$gens" | grep -c . || true)"
drop=$((total - 2))
if [ "$drop" -gt 0 ]; then
  printf '%s\n' "$gens" | sed -n "1,${drop}p" | while IFS= read -r g; do
    case "$g" in gen-*) rm -rf "${dir:?}/$g" ;; esac
  done
fi
exit "$rc"
