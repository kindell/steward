#!/bin/bash
# Format guard for linux/deploy-manifest. Run: bash test/deploy-manifest.test.sh
set -u
here="$(CDPATH= cd -- "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# THE MANIFEST IS THE UNION, NOT THE PRODUCT'S HALF. The estate's own rows live
# in its manifest and the mechanism's in this one; the deploy composes them and
# works against the sum. If this suite checks only one side, its most important
# guards go half-blind — the truncation guard (>=20 rows) and the core-target
# list both failed the moment the manifests were split, which is exactly what
# they exist for. A guard that measures a subset of what is deployed does not
# guard the deploy.
#
# ESTATE_ROOT points at an estate checkout when one is available; without it the
# estate's rows cannot be verified and are counted instead.
# NO ESTATE IS GUESSED BY DIRECTORY NAME. This resolved a sibling checkout by
# ITS NAME, which is a particular estate's name and means nothing on anybody
# else's machine: there the guess silently finds nothing, the estate's rows go
# unverified, and the suite reports green having measured half the manifest.
# The estate says where it is, or it is not there.
ESTATE_ROOT="${STEWARD_ESTATE_ROOT:-}"
[ -z "$ESTATE_ROOT" ] && [ -n "${STEWARD_ESTATE:-}" ] && ESTATE_ROOT="$(dirname "$(dirname "$STEWARD_ESTATE")")"
unverified=0
M="$(mktemp)"; trap 'rm -f "$M"' EXIT
cat "$here/linux/deploy-manifest" > "$M"
ESTATE_MANIFEST=""
if [ -n "$ESTATE_ROOT" ] && [ -f "$ESTATE_ROOT/estate/deploy-manifest" ]; then
  ESTATE_MANIFEST="$ESTATE_ROOT/estate/deploy-manifest"
elif [ -z "$ESTATE_ROOT" ] && [ -f "$here/estate/deploy-manifest" ]; then
  ESTATE_MANIFEST="$here/estate/deploy-manifest"
fi
[ -n "$ESTATE_MANIFEST" ] && { printf '\n' >> "$M"; cat "$ESTATE_MANIFEST" >> "$M"; }
pass=0; fail=0
ok()  { pass=$((pass+1)); }
bad() { echo "FAIL: $1"; fail=$((fail+1)); }

[ -f "$M" ] || { echo "FAIL: the manifest is missing"; echo "pass=0 fail=1"; exit 1; }

rows=0
while read -r src target mode kind extra; do
  case "$src" in ''|'#'*) continue ;; esac
  rows=$((rows+1))
  # 1. Exactly four fields
  if [ -n "${extra:-}" ] || [ -z "${kind:-}" ]; then bad "row shape: '$src ...'"; continue; fi
  # 2. The source exists — in the product, or in the estate.
  #
  # TWO ROOTS. The manifest's source column is relative to a repo, and since the
  # split the sources live in two: the mechanism's files here, the estate's own
  # files in the estate. Asking only this tree turns every estate row into a
  # false failure — which is exactly what happened the first time this suite ran
  # after the move.
  #
  # The estate is OPTIONAL, and its absence is not silently forgiven: rows that
  # cannot be checked are counted and printed at the end. A test that quietly
  # skips what it cannot see reports a clean tree it never looked at.
  if [ "$kind" = "registry" ]; then
    # A REGISTRY ROW'S SOURCE IS REQUIRED TO BE A DIRECTORY, never a file —
    # the row type reconciles a whole directory of *.conf, and a file source
    # would be staged, then silently never matched by anything apply does.
    if [ -d "$here/$src" ]; then
      ok
    elif [ -n "${ESTATE_ROOT:-}" ] && [ -d "$ESTATE_ROOT/$src" ]; then
      ok
    elif [ -z "${ESTATE_ROOT:-}" ]; then
      unverified=$((unverified+1))
    else
      bad "registry source missing, or not a directory, in both product and estate: $src"
    fi
  elif [ -f "$here/$src" ]; then
    ok
  elif [ -n "${ESTATE_ROOT:-}" ] && [ -f "$ESTATE_ROOT/$src" ]; then
    ok
  elif [ -z "${ESTATE_ROOT:-}" ]; then
    unverified=$((unverified+1))
  else
    bad "source missing in both product and estate: $src"
  fi
  # 3. The target is relative and free of ~, $HOME and ..
  case "$target" in /*|'~'*|*'$HOME'*|*..*) bad "target shape: $target" ;; esac
  # 4. The mode is three octal digits
  case "$mode" in [0-7][0-7][0-7]) : ;; *) bad "mode: $mode ($src)" ;; esac
  # 5. The kind is one we know
  case "$kind" in scripts|bin|systemd|lib|docs|registry) : ;; *) bad "kind: $kind ($src)" ;; esac
  # 6. Forbidden targets: instance configuration is never deployed. The registry
  # is what the deploy READS to decide where to write; writing it back would let
  # a rollout rewrite its own instructions.
  case "$target" in sessions.d/*|*/sessions.d/*|*jobs.d/*|*jobs-sources*) bad "instance target in the manifest: $target" ;; esac
done < "$M"

# 5b. PROOF: for kind=registry, a FILE source is REJECTED, never silently
# accepted as if it were a directory. Built from this very suite file — a
# path guaranteed to exist and guaranteed to be a file, never a directory —
# so the demonstration cannot depend on anything else being present. Only
# meaningful with an estate root: without one, check 2's own "unverified"
# branch fires first for EITHER a file or a directory source, and there is
# nothing left to prove.
if [ -n "${ESTATE_ROOT:-}" ]; then
  proof_src="test/deploy-manifest.test.sh"
  if [ -d "$here/$proof_src" ] || [ -d "$ESTATE_ROOT/$proof_src" ]; then
    bad "PROOF FAILED: a registry row with a FILE source was accepted as a directory: $proof_src"
  else
    ok
  fi
else
  echo "NOTE: registry file-source-rejection proof skipped — no ESTATE_ROOT (check 2 falls to 'unverified' for either a file or a directory, so there is nothing to prove)"
fi

min_rows=17
[ -n "$ESTATE_MANIFEST" ] && min_rows=20
[ "$rows" -ge "$min_rows" ] && ok || bad "suspiciously short manifest: $rows rows"

# 7. No duplicate targets (two sources must not write the same target)
dupes="$(grep -v '^#' "$M" | awk 'NF>=4 {print $2}' | sort | uniq -d)"
[ -z "$dupes" ] && ok || bad "duplicate target: $dupes"

# 8. The core files the hand-rolled path used to deploy must still be targets.
# This is the truncation guard's companion: a manifest can be the right length
# and still have lost the one row that matters.
# THE UNIT'S NAME CHANGED 2026-08-20 and this list caught it, which is what the
# list is for: a manifest can be the right length and still have lost the row
# that matters. The rename swapped the estate's name for a function name
# (`agent-`), and until a host has been switched over by hand it still RUNS the
# old unit — the manifest describes what the deploy writes, not what runs.
# THE ADAPTER IS A PRODUCT ROW; tysta-fel.md is an ESTATE row. That difference
# decides which list they belong to: runtime/opencode-session.sh lives in
# linux/deploy-manifest and must therefore be required EVEN WHEN NO ESTATE IS
# PRESENT - which is the whole point of the suite running standalone. The
# estate's row is required only when the estate manifest was read.
# THE SPAWN LIBRARIES AND THE WRAPPER JOIN THE LIST for a reason the other
# entries share: losing one of them is not a missing feature, it is a session
# that starts with the wrong tools and says nothing. Without
# scripts/lib/mcpspawn.sh the supervisor refuses to spawn at all (by design,
# rc 78) -- so a manifest that quietly dropped the row would take a whole host
# down on the next deploy. Without bin/mcp-env every rendered document that
# names a credential file points at a program that is not there.
REQUIRED_TARGETS="bin/bus-send scripts/session-supervisor-linux.sh scripts/runtime/opencode-session.sh scripts/lib/registry.sh .config/systemd/user/agent-session@.timer"
REQUIRED_TARGETS="$REQUIRED_TARGETS scripts/lib/mcprender.sh scripts/lib/mcpspawn.sh bin/mcp-env"
# The job installer joins for the same reason: without scripts/install-user-jobs.sh
# a home has a job runner and no way to turn the estate's job rows into timers,
# so every scheduled job on that host is silently never scheduled.
REQUIRED_TARGETS="$REQUIRED_TARGETS scripts/install-user-jobs.sh"
# THE DESK IS FOUR FILES AND TWO UNITS, and every one of them fails QUIETLY.
# A home that lost scripts/desk/bin/desk-paths has a server that exits 78 the
# moment systemd starts it and says so only in the journal - the socket is
# simply never there, and the reader in front of it reports a connection
# refused that names nothing. The producer fails the same way: without
# scripts/desk/snapshot.sh the timer runs a unit whose ExecStart does not
# exist, and the desk keeps serving the generation it happened to have. The
# units are here because a deploy that writes the files and not the units
# leaves a host with a desk nobody starts.
REQUIRED_TARGETS="$REQUIRED_TARGETS scripts/desk/snapshot.sh scripts/desk/serve.mjs"
REQUIRED_TARGETS="$REQUIRED_TARGETS scripts/desk/bin/desk-paths scripts/desk/bin/principal-for-login"
REQUIRED_TARGETS="$REQUIRED_TARGETS .config/systemd/user/steward-desk.service .config/systemd/user/steward-desk-snapshot.timer"
# The rest of the desk fails the same quiet way. A timer whose service is gone
# fails every five minutes in the journal only; a server without render.mjs
# cannot import the pages it serves and dies on start; and filter.jq is the
# security boundary itself - a home running an older one, or none, writes files
# that carry more than the current rules allow, and nothing downstream notices.
REQUIRED_TARGETS="$REQUIRED_TARGETS .config/systemd/user/steward-desk-snapshot.service scripts/desk/render.mjs scripts/desk/filter.jq"
# The producer calls the client for the mcp surface; without scripts/bin/steward
# in the deployed home, that call fails and the desk's mcp section goes quietly
# null on every principal.
REQUIRED_TARGETS="$REQUIRED_TARGETS scripts/bin/steward"
[ -n "$ESTATE_MANIFEST" ] && REQUIRED_TARGETS="$REQUIRED_TARGETS scripts/docs/tysta-fel.md"
for required in $REQUIRED_TARGETS; do
  grep -v '^#' "$M" | awk '{print $2}' | grep -qx "$required" && ok || bad "core target missing: $required"
done

# 8b. THE HUB'S RECEIVING SIDE TRAVELS TOGETHER, and executable.
#
# Each of these is the forced command behind a key in somebody's
# authorized_keys: a row that goes missing, or lands 644, does not break a
# deploy — it breaks a key that is already installed on the other side, and the
# failure is an ssh error in a log nobody reads. bus-relay-peer joined them when
# the hub peer link shipped, so the list names all three rather than the two it
# was written for.
for relay in bus-relay-in bus-relay-deliver bus-relay-peer; do
  row="$(grep -v '^#' "$M" | awk -v t="scripts/bus/bin/$relay" '$2 == t {print $3}')"
  is_mode="$(printf '%s' "$row")"
  [ "$is_mode" = "755" ] && ok || bad "the hub's receiving side: scripts/bus/bin/$relay is not a 755 manifest row (got '${is_mode:-no row}')"
done

# 8c. THE TEST TREE IS NOT PART OF THE IMAGE.
#
# desk/ ships file by file, and the directory holds its own tests beside the
# files they measure. A row that swept them along would put a test fixture into
# somebody's home, where nothing runs it and nothing prunes it - and the desk's
# tests write sockets and generation directories. What belongs in a home is the
# part a unit starts.
# Matches desk/test itself (a registry-kind row, source is the directory with
# no trailing slash) as well as anything under it - two case patterns, not one
# regex, because bash 3.2's case is what the rest of this suite already uses.
leaked=""
while read -r src _target _mode _kind _extra; do
  case "$src" in
    ''|'#'*) continue ;;
    desk/test|desk/test/*) leaked="$leaked $src" ;;
  esac
done < "$M"
leaked="${leaked# }"
[ -z "$leaked" ] && ok || bad "a desk test file is a manifest source: $leaked"

# 8d. THE DESK'S UNITS FIND THEIR OWN PROGRAMS.
#
# A systemd user manager's PATH is a short system list; it does not carry
# ~/.local/bin or ~/bin, which is where a version manager puts a runtime and
# where this product's own bridges land. The server unit has always carried the
# PATH line for that reason, and the producer unit needs it just as much: the
# round shells out to jq, to git and to the estate's liveness command, and a
# producer that cannot find one of them writes a snapshot that says the whole
# fleet is unknown - on a timer, every five minutes, into the journal only.
# This is how a program is FOUND, not configuration: nothing here names a
# directory the desk owns.
for unit in steward-desk.service steward-desk-snapshot.service; do
  if grep -q '^Environment=PATH=%h/.local/bin:%h/bin:/usr/local/bin:/usr/bin:/bin$' "$here/linux/$unit"; then
    ok
  else
    bad "linux/$unit carries no Environment=PATH line - the round cannot find its own programs"
  fi
done

# 9. THE TOOLS ARE NEVER PART OF WHAT THEY WRITE.
#
# The hub's same-machine check protects the hub from becoming a victim of its own
# deploy. deploy-self.sh has no such check, because by definition it always
# deploys to its own machine. The protection therefore rests entirely on the
# tools that RUN the deploy, and the manifest that DRIVES it, never being
# something the deploy WRITES. Nothing measured that property before.
# The hub's entry point is ESTATE code and is named by the estate, not here.
# It joins the list when STEWARD_HUB_ENTRY points at it; the product's own four
# are always checked.
# bin/steward IS NOT IN THIS LIST, and the difference is the one the check is
# about: deploy-self.sh runs it from $PRODUCT after the apply has finished,
# while the manifest carries it to scripts/bin/steward - a different path, in a
# home, never the file the running deploy is reading - so no rollout can
# overwrite the copy its own run depends on, which is the class forbidden here.
TOOLS="lib/deploy-core.sh linux/deploy-self.sh linux/deploy-apply.sh linux/deploy-manifest"
[ -n "${STEWARD_HUB_ENTRY:-}" ] && TOOLS="$STEWARD_HUB_ENTRY $TOOLS"
for t in $TOOLS; do
  # 9a. Never a SOURCE: that would mean the tool running the deploy lives in the
  # image it writes — it would update itself in the middle of its own run.
  grep -v '^#' "$M" | awk '{print $1}' | grep -qx "$t" \
    && bad "tool as a manifest source — self-update mid-run: $t" || ok
  # 9b. Never a TARGET: that would mean a target points into the checkout. If
  # <home root> ever coincided with the checkout (a misconfigured session, or
  # deploy-self.sh running against its OWN machine) the deploy would overwrite
  # the running tool itself.
  grep -v '^#' "$M" | awk '{print $2}' | grep -qx "$t" \
    && bad "tool as a manifest target — points into the checkout: $t" || ok
done

# 10. EVERY LIBRARY A DEPLOYED FILE SOURCES TRAVELS WITH IT, not only the ones
# named in the required-target list above. desk/snapshot.sh sources three
# files from THE SAME DIRECTORY the registry library came from - registry.sh,
# liveness.sh, and now visibility.sh - and a home missing any one of them
# fails on the sourcing line, at rc 78, into a journal nobody reads. This
# check reads every file the manifest deploys under desk/, runtime/, and
# linux/hub/ (the three trees that source a library the SAME WAY, from a
# variable directory, ending in a literal repo-relative `lib/<name>.sh`) and
# proves the manifest carries a row for what it finds. TWO ROWS WERE MISSING
# BEFORE THIS CHECK EXISTED: bin/steward, on a different day, and
# lib/visibility.sh, measured 2026-09-08. Both failed the same way - quietly,
# on a deployed home, never on the checkout that wrote the manifest.
#
# A VARIABLE BASENAME IS SKIPPED, NEVER GUESSED. A line whose final path
# segment is itself a variable - `. "$STEWARD_REGISTRY_LIB"`,
# `. "$_MCP_LIB_DIR/$_c"` - names no literal file this check could look up, so
# it is left to the required-target list above, or to a human, rather than
# invented here.
#
# THE DIRECTORY HOP IS READ FROM ITS OWN LAST COMPONENT, not from a fixed
# string. `$lib_dir/visibility.sh` never contains the four characters `lib/`
# - the variable is named `lib_dir`, not `lib` - so a check that only grepped
# for a literal `lib/` segment would have missed the very row this check
# exists to guard. What decides a match is the path segment immediately
# before the literal basename: a directory called `lib` (as in
# `$here/../lib/registry.sh`) or a variable whose own name says so (as in
# `$lib_dir/visibility.sh`). The hub's own `$here/lib.sh` has neither - the
# name is a variable that says nothing about a library directory, and the
# library it names is not under `lib/` at all - so it is correctly left out.
# THE EXTRACTED PATH IS THE ONE RIGHT AFTER THE SOURCE KEYWORD, never the last
# quoted string on the line. `.*"\([^"]*\)".*` is greedy at its own leading
# `.*"` and, given more than one quoted span (a trailing comment that itself
# carries a quoted string, or a later statement on the same line), it lands on
# the LAST one, not the one being sourced. Anchoring the prefix to `[^"]*`
# instead of `.*` stops it from crossing the first quote at all, so the
# capture is forced onto the span right after the keyword - real lines this
# check reads carry no quote before it. Proven wrong on real code, not a
# hypothetical: `linux/hub/enroll` sources a config with `. "$conf"; : "$ID"
# "$ACCOUNT" ...` on one line, and the greedy form extracted `$DOMAIN` (the
# last quoted name) instead of `$conf`. The same PATH_SED backs the proof
# right after this loop.
# -- EVERY LIBRARY IN THE REPO HAS A ROW, SOURCED OR NOT ------------------
#
# THE CHECK BELOW PROVES THE WRONG HALF ON ITS OWN, and this is what taught
# us: lib/credential.sh was committed with no manifest row, the rollout
# answered rc 0, and the file landed in ZERO homes. The sweep further down did
# not fail, and it was RIGHT not to: it reads the files that SOURCE a library
# and proves a row exists for what they name. Nothing sourced credential.sh
# yet - it is a seam waiting for its caller - so there was nothing to find.
#
# "Everything that is sourced is deployed" and "everything in lib/ is
# deployed" are different claims, and only the first was ever checked. A
# library with no caller yet is exactly the file that slips through: it is
# newest, it is the one somebody is still wiring up, and its absence shows up
# later as a deployed host failing on a sourcing line at rc 78, in a journal
# nobody reads.
#
# THE EXCLUSION IS A LIST, NOT A RULE. lib/deploy-core.sh is deliberately not
# deployed - linux/deploy-self.sh sources it from the CHECKOUT, before any
# rollout exists to have deployed anything. Naming it here means adding a
# second such file is a deliberate edit to this list with a reason beside it,
# rather than a hole that widens quietly.
NOT_DEPLOYED="lib/deploy-core.sh"
# EXACT MEMBERSHIP, IN A SUITE THAT DELIBERATELY DOES NOT LOAD THE PRODUCT.
# `case " $NOT_DEPLOYED " in *" $rel "*` would be the substring form - the one
# this repo spent a day removing - and writing it HERE, in the check whose
# whole purpose is to catch a list widening quietly, would be the joke telling
# itself. It is not a hole today: the list has ONE entry and a two-word value
# needs two ADJACENT ones to span anything, and the needle is a basename from
# this repo rather than free text from outside.
#
# But the list EXISTS IN ORDER TO GROW - the comment above says a second file
# must be a deliberate edit with a reason beside it - and on the day it has
# two entries the substring form is one filename-with-a-space away from
# excluding something nobody excluded. So it is exact from the start.
#
# FOUR LINES RATHER THAN `_registry_word_in_list`, on purpose: this suite
# reads the manifest as a text file and loads nothing from lib/, so that a
# broken library cannot make the manifest check pass. A test that depends on
# the thing it is checking is a coupling worth four lines to avoid.
_excluded() {
  local want="$1" e
  for e in $NOT_DEPLOYED; do [ "$e" = "$want" ] && return 0; done
  return 1
}
for libfile in "$here"/lib/*.sh; do
  [ -f "$libfile" ] || continue
  rel="lib/$(basename "$libfile")"
  _excluded "$rel" && continue
  if grep -qE "^${rel//./\\.}[[:space:]]" "$M"; then
    ok "manifest row for $rel"
  else
    bad "manifest row for $rel" "the file is in the repo and in no home: a rollout will answer rc 0 and deploy nothing"
  fi
done

PATH_SED='s/^[^"]*(\. |source )"([^"]*)".*/\2/'
LIB_SOURCERS="$(grep -v '^#' "$M" | awk '{print $1}' | grep -E '^(desk/|runtime/|linux/hub/)')"
for srcfile in $LIB_SOURCERS; do
  [ -f "$here/$srcfile" ] || continue
  hits="$(grep -nE '(\. "\$|source "\$)' "$here/$srcfile" 2>/dev/null)"
  [ -z "$hits" ] && continue
  while IFS=: read -r lineno linetext; do
    [ -z "${lineno:-}" ] && continue
    first="$(printf '%s' "$linetext" | sed -n 's/^[[:space:]]*\(.\).*/\1/p')"
    [ "$first" = '#' ] && continue
    path="$(printf '%s' "$linetext" | sed -E -n "$PATH_SED"'p')"
    [ -z "$path" ] && continue
    case "$path" in
      */*) basename="${path##*/}" ;;
      *) basename="$path" ;;
    esac
    case "$basename" in
      *'$'*) continue ;;
    esac
    case "$basename" in
      *.sh) : ;;
      *) continue ;;
    esac
    prefix="${path%/*}"
    case "$prefix" in
      */*) lpc="${prefix##*/}" ;;
      *) lpc="$prefix" ;;
    esac
    case "$lpc" in
      *lib*) : ;;
      *) continue ;;
    esac
    libname="${basename%.sh}"
    want="lib/${libname}.sh"
    if grep -v '^#' "$M" | awk '{print $1}' | grep -qx "$want"; then
      ok
    else
      bad "$srcfile sources lib/${libname}.sh (line $lineno) but the manifest has no row for $want"
    fi
  done <<EOF
$hits
EOF
done

# 10b. PROOF: PATH_SED captures the span right after the source keyword, not
# the last quoted span on the line. Run through the SAME sed script the loop
# above uses, on a line built for this proof - a trailing comment carrying its
# own quoted text ("other.sh") must never win the capture.
proof_line='. "$x/a.sh" # "other.sh"'
proof_path="$(printf '%s' "$proof_line" | sed -E -n "$PATH_SED"'p')"
if [ "$proof_path" = '$x/a.sh' ]; then
  ok
else
  bad "PROOF FAILED: PATH_SED extracted '$proof_path' instead of \$x/a.sh from a line with a trailing quoted comment"
fi

# 11. EVERY SHIPPED FILE'S lib/<name>.sh STRINGS HAVE A ROW - swept over EVERY
# manifest source OF A KIND THAT CAN SOURCE, not only the desk/runtime/hub
# trees check 10 restricts itself to. Check 10 parses a source STATEMENT
# (". \"\$dir/x.sh\"") in three named trees; this check is a plain
# `grep -o 'lib/[a-z_-]*\.sh'` over every file the manifest ships, wherever it
# lives. bin/steward is outside all three of check 10's trees and shipped
# with SIX missing lib rows - a deployed host's `steward sessions --json`
# died on `lib/sessions.sh: No such file or directory`, measured 2026-09-09.
# Check 10 could not have caught it; this check would have.
#
# THE KIND FILTER IS A POSITIVE LIST, not "every kind but docs". A `docs`
# row's file is never sourced by anything - it is prose - and prose that
# happens to NAME a library in passing is not a missing manifest row. With
# STEWARD_ESTATE_ROOT set (the canonical aggregate, both manifests read
# together) the estate ships docs/deployvagen.md, kind `docs`, which mentions
# lib/deploy-core.sh while explaining what it is - a real false failure this
# suite produced with an estate root, measured 2026-09-09, the day after this
# check was added. Restricting the sweep to the kinds that CAN source a
# library - scripts, lib, bin - rather than excluding docs by name keeps the
# next non-executing kind out too, without this check having to learn its
# name.
#
# A file that does not exist locally (an estate row with no estate checkout)
# is skipped, the same as check 2's own "unverified" branch - this check
# widens the sweep, it does not tighten what counting a source as present
# requires.
ALL_SOURCES="$(grep -v '^#' "$M" | awk 'NF>=4 && ($4=="scripts"||$4=="lib"||$4=="bin"){print $1}')"
for srcfile in $ALL_SOURCES; do
  libfile=""
  if [ -f "$here/$srcfile" ]; then
    libfile="$here/$srcfile"
  elif [ -n "${ESTATE_ROOT:-}" ] && [ -f "$ESTATE_ROOT/$srcfile" ]; then
    libfile="$ESTATE_ROOT/$srcfile"
  fi
  [ -n "$libfile" ] || continue
  wanted="$(grep -o 'lib/[a-z_-]*\.sh' "$libfile" 2>/dev/null | sort -u)"
  [ -z "$wanted" ] && continue
  for want in $wanted; do
    if grep -v '^#' "$M" | awk '{print $1}' | grep -qx "$want"; then
      ok
    else
      bad "$srcfile references $want but the manifest has no row for it"
    fi
  done
done

# 11b. PROOF: a `docs` row naming a library in prose produces no failure; a
# `scripts` row with the identical content produces one. One real fixture
# file, mentioning lib/nothing.sh (a name guaranteed to have no manifest
# row), run through the FULL check-11 pipeline twice on a synthetic one-row
# manifest - once as if its row were `docs`, once as if its row were
# `scripts` - not a restatement of the filter line alone: the kind filter,
# the content grep, and the row lookup all run, exactly as check 11 runs
# them, so this proves the behavior the ruling asked for, not just the
# expression it named.
PROOF_FIXTURE="$here/test/.deploy-manifest-guard-fixture-$$"
printf 'this is prose, not code, and it names lib/nothing.sh in passing\n' > "$PROOF_FIXTURE"
trap 'rm -f "$M" "$PROOF_FIXTURE"' EXIT
PROOF_REL="test/.deploy-manifest-guard-fixture-$$"
for proof_kind in docs scripts; do
  proof_row="$PROOF_REL	scripts/fixture	644	$proof_kind"
  proof_sources="$(printf '%s\n' "$proof_row" | awk 'NF>=4 && ($4=="scripts"||$4=="lib"||$4=="bin"){print $1}')"
  proof_failed=0
  for proof_srcfile in $proof_sources; do
    proof_libfile=""
    [ -f "$here/$proof_srcfile" ] && proof_libfile="$here/$proof_srcfile"
    [ -n "$proof_libfile" ] || continue
    proof_wanted="$(grep -o 'lib/[a-z_-]*\.sh' "$proof_libfile" 2>/dev/null | sort -u)"
    [ -z "$proof_wanted" ] && continue
    for proof_want in $proof_wanted; do
      if grep -v '^#' "$M" | awk '{print $1}' | grep -qx "$proof_want"; then
        :
      else
        proof_failed=1
      fi
    done
  done
  if [ "$proof_kind" = "docs" ]; then
    [ "$proof_failed" -eq 0 ] && ok || bad "PROOF FAILED: a docs row naming lib/nothing.sh in prose produced a failure — $PROOF_REL"
  else
    [ "$proof_failed" -eq 1 ] && ok || bad "PROOF FAILED: a scripts row naming lib/nothing.sh produced no failure — $PROOF_REL"
  fi
done
rm -f "$PROOF_FIXTURE"

[ "$unverified" -gt 0 ] && echo "NOTE: $unverified estate rows could not be verified (no estate checkout found)"
[ -z "$ESTATE_MANIFEST" ] && echo "NOTE: estate manifest not found; product rows only checked"
echo "pass=$pass fail=$fail"
[ "$fail" -eq 0 ]
