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
# The positive field allowlist is exported by lib/visibility.sh; desk/filter.jq
# projects it without duplicating either the field table or session visibility.
# This script builds a RAW document that deliberately carries more than any
# viewer may see, and every viewer file is that raw document run through the
# one filter. Nothing in this script writes a viewer file
# any other way.
#
# THE RAW DOCUMENT NEVER LEAVES THIS PROCESS. It is built in a temp directory
# that this script removes on every exit path, and the estate values that must
# never travel (a repository PATH, an MCP command line, a browser port) are
# either never read or reduced here - REPO_PATH becomes its basename before it
# is ever put into JSON.
#
# THE MODE BITS ARE THE LAST GATE, so this process sets them rather than
# inheriting them. Every file here was filtered when it was written precisely
# so that nothing has to decide at read time who may see it - which puts the
# whole weight on the filesystem, and a home that happens to be group- or
# world-readable would then hand every principal's file to anyone with a login
# on the machine. umask 077 makes each generation directory 0700 and each file
# 0600 whatever the timer, the shell or the deploy was running with.
#
# Exit codes: 0 ok - 69 jq is missing - 73 the desk directory cannot be
# written - 78 the estate or the registry would not load.
set -u
umask 077
here="$(CDPATH= cd -- "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# THE LIBRARY SITS ONE HOP UP IN BOTH LAYOUTS: desk/ beside lib/ at the repo
# root, and scripts/desk/ beside scripts/lib/ in a deployed home.
# STEWARD_REGISTRY_LIB overrides; found nowhere is a refusal.
lib_dir=""
if [ -n "${STEWARD_REGISTRY_LIB:-}" ]; then
  # shellcheck source=/dev/null
  . "$STEWARD_REGISTRY_LIB" || exit 78
  lib_dir="$(dirname "$STEWARD_REGISTRY_LIB")"
elif [ -f "$here/../lib/registry.sh" ]; then
  # shellcheck source=/dev/null
  . "$here/../lib/registry.sh" || exit 78
  lib_dir="$here/../lib"
else
  echo "desk snapshot: the registry library was found in neither layout (from $here)" >&2
  exit 78
fi
# THE LIVENESS LIBRARY IS TAKEN FROM THE SAME DIRECTORY THE REGISTRY CAME FROM,
# never guessed separately: an override that aims the registry at one tree and
# the liveness seam at another would measure one estate and describe a second.
if [ -f "$lib_dir/liveness.sh" ]; then
  # shellcheck source=/dev/null
  . "$lib_dir/liveness.sh" || exit 78
else
  echo "desk snapshot: the liveness library is not beside the registry library in $lib_dir" >&2
  exit 78
fi
# THE VISIBILITY LIBRARY IS TAKEN FROM THE SAME DIRECTORY THE REGISTRY CAME
# FROM, for the same reason liveness.sh is: an override that aimed the
# registry at one tree and the visibility rule at another would decide with
# one estate's rows and describe a second.
if [ -f "$lib_dir/visibility.sh" ]; then
  # shellcheck source=/dev/null
  . "$lib_dir/visibility.sh" || exit 78
else
  echo "desk snapshot: the visibility library is not beside the registry library in $lib_dir" >&2
  exit 78
fi
command -v jq >/dev/null 2>&1 || { echo "desk snapshot: jq is required" >&2; exit 69; }
. "$lib_dir/visibility.sh" || exit 78
owner_fields="$(visibility_field_list owner | jq -Rn '[inputs]')" || exit 78
member_fields="$(visibility_field_list member | jq -Rn '[inputs]')" || exit 78
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
# NOT `steward sessions --json`. That verb is VISIBILITY-FILTERED by the unix
# user that calls it, and the snapshot runs as one account while writing files
# for every principal in the estate - so the producer would measure only its own
# rows and every colleague's session would land as `unknown` in a file that
# otherwise describes it fully. Measured before this was changed: the producing
# account saw 2 sessions of 24. The seam underneath is what this reads instead.
#
# ONE CALL FOR THE WHOLE FLEET - liveness_rows takes no arguments and answers
# about everything the estate's shim can measure, by design.
#
# THE COMMAND IS RESOLVED THE WAY `sessions` RESOLVES IT: the environment wins,
# and only when it has no opinion does the estate's own LIVENESS_CMD get a turn.
# An estate that names none is the ordinary unconfigured state, not a refusal;
# an estate that names a malformed one is a refusal, and rc 78 carries it out,
# because a column of silent `unknown` is exactly what would hide that mistake.
if [ -z "${STEWARD_LIVENESS_CMD:-}" ]; then
  lv_err="$(mktemp)" || { echo "desk snapshot: could not create a temporary file" >&2; exit 73; }
  lv_out="$(registry_liveness_cmd 2>"$lv_err")"; lv_rc=$?
  if [ "$lv_rc" -ne 0 ]; then
    cat "$lv_err" >&2; rm -f "$lv_err"; exit 78
  fi
  rm -f "$lv_err"
  [ -z "$lv_out" ] || { STEWARD_LIVENESS_CMD="$lv_out"; export STEWARD_LIVENESS_CMD; }
fi

# NOT IN A COMMAND SUBSTITUTION - the LIVENESS_SEAM_REASON contract. `$( )` is a
# subshell, and the variable liveness_rows sets to say WHY it measured nothing
# would not come back from one; liveness_for reads it to fill the reason field
# of every session it has no row for. bin/steward redirects for the same reason.
#
# A MISSING OR UNPARSEABLE ANSWER IS `unknown`, NEVER A FAILED SNAPSHOT. The
# desk's other half - who owns what, and who may see it - is fully readable
# without any liveness at all, and a desk that refused to render because a
# multiplexer was down would be dark exactly when it is wanted.
live_rows=""
live_out="$tmp/liveness.tsv"
liveness_rows > "$live_out"
live_rows="$(cat "$live_out")"

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
    # THE OWNER IS THE PERSON, NEVER THE UNIX ACCOUNT. `owner` is compared with
    # the viewer in desk/filter.jq, and the viewer is a PRINCIPAL id - the
    # account register's namespace, not the operating system's. Writing the
    # row's raw OWNER here made the two namespaces meet: a unix account whose
    # name happens to equal some other person's principal id would hand that
    # person the session as `mine`, its account-axis assets (their colleague's
    # own credentials) and the project it works on. The account register is
    # what knows which human is behind a unix account, and this is the
    # product's one function for asking it - ACCOUNT through
    # registry_account_load to ACCOUNT_PRINCIPAL, OWNER only when the row
    # carries no resolvable ACCOUNT, with a line on stderr saying so.
    owner="$(_registry_row_principal "$n")"
    sid="${ID:-$n}"
    # KEYED BY THE REGISTRY NAME, NOT THE ID. liveness_rows prints one row per
    # session the shim ANSWERED ABOUT, under the name the estate administers it
    # by - the same word registry_list yields - and liveness_for is what turns
    # an absent name into a full row of `unknown` rather than into silence.
    live_row="$(liveness_for "$n" "$live_rows")"
    IFS=$'\t' read -r _lname _ldaemon _ltmux lagent _lruntime _lmodel lactivity _lreason \
      <<< "$live_row"
    # One shared decision per principal/session. Only the filtered projection
    # leaves this temporary directory; the sight map itself never travels.
    sight_f="$tmp/sight-$n.jsonl"
    : > "$sight_f"
    while IFS= read -r viewer; do
      [ -n "$viewer" ] || continue
      sight="$(visibility_fields "$viewer" "$n")" || exit 78
      jq -cn --arg key "$viewer" --arg value "$sight" '{key:$key,value:$value}' >> "$sight_f" || exit 78
    done < <(jq -r '.id' "$principals_f")
    sights="$(jq -sc 'from_entries' "$sight_f")" || exit 78
    jq -cn --arg id "$sid" --arg slug "${SLUG:-$n}" --arg label "$label" \
           --arg owner "$owner" \
           --arg domain "$domain" --arg project "${TARGET_PROJECT:-}" \
           --arg runtime "${RUNTIME:-claude-code}" --arg host "${HOST:-}" --arg repo "$repo" \
           --arg measuredAt "$generated_at" \
           --arg agent "${lagent:-unknown}" --arg lastActivity "${lactivity:-unknown}" \
           --argjson mcp "$mcp" --arg mcpReason "$mcp_reason" --argjson sight "$sights" '
      def blank($v): if $v == "" then null else $v end;
        {id:$id, slug:$slug, label:$label, owner:$owner, sight:$sight,
       domain: blank($domain), project: blank($project),
       runtime: $runtime, host: $host, repo: $repo,
       # THE AGE IS DERIVED HERE, NOT LEFT TO EVERY READER. `lastActivity` is
       # whatever the seam printed; a reader that parsed it itself would have
       # to decide what an unparseable value means, and three readers would
       # decide three ways. Unparseable or absent is null - an age nobody
       # could measure, said out loud. The two placeholders the seam prints say
       # the same thing in its own vocabulary: `-` is measured-and-empty,
       # `unknown` is never-measured, and neither one is a timestamp. The seam
       # has also been seen to print fractional seconds, e.g. a trailing
       # `.000Z` carried over from how a multiplexer formats its own
       # timestamps; `fromdateiso8601` rejects a fraction outright, so it is
       # stripped before parsing - the fraction is finer than the
       # second-level precision ageSeconds reports anyway, so dropping it
       # loses nothing this field promises.
       liveness: {state: $agent,
                  measuredAt: $measuredAt,
                  ageSeconds: (if ($lastActivity == "" or $lastActivity == "-"
                                   or $lastActivity == "unknown") then null
                               else (try ((now - ($lastActivity
                                                   | sub("\\.[0-9]+Z$"; "Z")
                                                   | fromdateiso8601)) | floor)
                                     catch null)
                               end)},
       mcp: $mcp, mcpReason: blank($mcpReason)}'
  ) >> "$sessions_f" || exit 78
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
  # A FAILED FILTER NEVER LEAVES ITS .tmp BEHIND. The `>` redirect below
  # creates the file the instant the shell sets it up, before jq runs at
  # all - so a jq failure still leaves an empty (or partial) .tmp sitting in
  # the generation unless this removes it on the way out.
  jq --arg viewer "$2" --argjson readAll "$3" --argjson memberOf "$4" \
     --argjson ownerFields "$owner_fields" --argjson memberFields "$member_fields" \
     -f "$here/filter.jq" "$raw" > "$dir/$gen/$1.json.tmp" || {
    rm -f "$dir/$gen/$1.json.tmp"
    return 1
  }
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
# serve by mistake. readAll selects owner fields, never raw rows.
write_view "_operator" "_operator" true '[]' || rc=1

# THE SWAP AND THE PRUNE ONLY HAPPEN WHEN EVERY VIEWER WROTE. A generation
# with even one missing file is not a generation a reader may be pointed at -
# `current` stays on the last good one, this run's half-built directory is
# left behind (a later successful run's prune sweeps it up as just another
# old generation), and the run exits non-zero so the fault is not silent.
if [ "$rc" -eq 0 ]; then
  # ONE SYMLINK, REPLACED IN PLACE. `mv -f` onto an existing symlink-to-directory
  # does NOT replace it on BSD - it moves the new link INSIDE the old target
  # (measured on macOS: the link landed as current/current.tmp and `current` never
  # moved). `ln -sfn` replaces the link itself on both BSD and GNU, and is the
  # only portable spelling of this swap.
  ln -sfn "$gen" "$dir/current" || { echo "desk snapshot: could not point $dir/current at $gen" >&2; exit 73; }

  # KEEP TWO GENERATIONS: the one being served and the one a reader may still
  # have open. Older ones are the previous week's answers and nobody asks them.
  #
  # THE GENERATION JUST PUBLISHED IS NEVER A PRUNE CANDIDATE, whatever its name
  # sorts as. Names are epoch stamps, and a clock that steps backward between
  # runs can make the fresh one sort earlier than a sibling minted before it -
  # sorting alone would then count $gen among the "oldest" and delete the very
  # directory `current` was just pointed at. It is kept unconditionally, plus
  # whichever OTHER generation sorts latest; everything else goes.
  gens="$(cd "$dir" && ls -1d gen-* 2>/dev/null | sort)"
  keep_other="$(printf '%s\n' "$gens" | grep -v -x "$gen" | tail -1)"
  printf '%s\n' "$gens" | while IFS= read -r g; do
    case "$g" in
      gen-*) [ "$g" = "$gen" ] || [ "$g" = "$keep_other" ] || rm -rf "${dir:?}/$g" ;;
    esac
  done
else
  echo "desk snapshot: generation $gen was not fully written - current still points at the previous generation" >&2
fi
exit "$rc"
