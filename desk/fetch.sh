#!/bin/bash
# desk/fetch.sh [<estate>...] - the consumer's half of a cross-estate read: pull
# each remote estate's current desk generation into this desk's remote/ tree.
# (spec: docs/superpowers/specs/2026-09-13-desk-across-estates-design.md)
#
# THE CONSUMER PULLS. Nothing here is ever pushed to, and no producer holds a key
# into this machine. An estate that is compromised can stop answering; it cannot
# write. That is the whole reason the arrow points this way, and it is why this
# file exists rather than a receiver.
#
# THE ONE RULE EVERYTHING ELSE SERVES: a bad answer never replaces a good one.
# A stream that stops mid-file, a stream that was never a tar, a command that
# exits non-zero, and a command that says nothing at all are four different ways
# to fail, and a fetcher that checked only the exit status would swap in the
# first two. So the answer is unpacked to the side, inspected, and only then
# does one symlink move. Everything before that moment is reversible by deleting
# a directory nobody is reading.
#
# AND ABSENCE IS NAMED. A failed fetch leaves the previous generation exactly
# where it was and writes `status: unavailable` with the transport's own words
# into meta.json. It never deletes rows. A fleet page that quietly loses a host
# is indistinguishable from a host with nothing on it - the equivalence this
# product has paid to learn twice, in the liveness seam and again in
# `uncensused`.
#
# EVERY ESTATE IS ATTEMPTED. A run that stopped at the first unreachable machine
# would let one dead host make the others invisible.
#
# THE LIST lives at STEWARD_DESK_REMOTES (default
# <estate-root>/estate/desk-remotes.conf - BESIDE steward.conf, not above it: the
# path is derived from the estate FILE, and a reader who trusts this line to say
# otherwise puts the list one level too high. That happened, on a real host, on
# 2026-09-16: the line read <estate-root>/desk-remotes.conf and the operator
# believed it),
# one estate per line:
#
#     <estate>  <ssh-target>  <identity-slug>
#
#   for example:  far-estate  worker@192.0.2.10  id_desk_fetch    (RFC 5737)
#
# The identity is a SLUG under ~/.ssh, not a path: a free-form path field would
# let a line aim this machine's keys anywhere, and the line would look correct
# doing it. Same grammar discipline as the login register's CONFIG_DIR.
#
# Exit: 0 every named estate answered - 65 the list itself is malformed (and
# then NOTHING is fetched: acting on half a list is worse than refusing it) -
# 69 at least one estate did not answer - 73 the desk directory cannot be
# written - 78 the estate or the registry would not load.
set -u
umask 077

# THE CALLER'S ARGUMENTS ARE CAPTURED ON THE FIRST LINE THAT CAN, because the
# list parser below used to reach for `set -- $line` to split a line into
# fields - and `set --` replaces the SCRIPT'S positional parameters, not a
# local copy. `$*` then held the last parsed line instead of what the operator
# typed, so the "only these estates" filter silently matched one estate by
# coincidence and skipped every other. Found by the suite, which asked for two
# estates and got one.
WANT=" $* "

here="$(CDPATH= cd -- "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

paths="$("$here/bin/desk-paths" 2>/dev/null)" || exit 78
DESK="$(printf '%s\n' "$paths" | sed -n 's/^dir=//p' | head -1)"
[ -n "$DESK" ] || { echo "desk-fetch: desk-paths named no directory" >&2; exit 78; }

REMOTES="${STEWARD_DESK_REMOTES:-}"
if [ -z "$REMOTES" ]; then
  est_file="$( STEWARD_REGISTRY_LIB="${STEWARD_REGISTRY_LIB:-}" bash -c '
    . "${STEWARD_REGISTRY_LIB:-'"$here"'/../lib/registry.sh}" 2>/dev/null || exit 1
    registry_estate_file 2>/dev/null' )" || est_file=""
  [ -n "$est_file" ] && REMOTES="$(dirname "$est_file")/desk-remotes.conf"
fi

now_iso="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
now_epoch="$(date +%s)"

# ── THE LIST IS VALIDATED WHOLE, BEFORE ANYTHING IS FETCHED ─────────────────
# A malformed list is a configuration fault, not a per-estate one. Fetching the
# good lines and refusing the bad would leave the operator with a fleet that is
# right about some estates and silent about others, for a reason that is not in
# any meta.json - the list is not a thing the Desk renders.
NAMES=""; TARGETS=""; IDENTS=""
if [ -n "$REMOTES" ] && [ -f "$REMOTES" ]; then
  lineno=0
  while IFS= read -r line || [ -n "$line" ]; do
    lineno=$((lineno+1))
    case "$line" in ''|\#*) continue ;; esac
    # A FUNCTION HAS ITS OWN POSITIONAL PARAMETERS. Splitting here rather than in
    # the script's frame is what keeps `set --` from reaching the caller's
    # arguments - see WANT above for the bug that taught this.
    _fields() { NFIELDS=$#; _e="${1-}"; _t="${2-}"; _i="${3-}"; }
    # shellcheck disable=SC2086
    _fields $line
    if [ "$NFIELDS" -ne 3 ]; then
      echo "desk-fetch: REFUSING $REMOTES line $lineno: expected '<estate> <ssh-target> <identity-slug>', got $NFIELDS field(s): $line" >&2
      exit 65
    fi
    case "$_e" in *[!a-z0-9-]*|'') echo "desk-fetch: REFUSING $REMOTES line $lineno: '$_e' is not an estate slug" >&2; exit 65 ;; esac
    case "$_t" in *[!A-Za-z0-9@.:_-]*|'') echo "desk-fetch: REFUSING $REMOTES line $lineno: '$_t' is not an ssh target" >&2; exit 65 ;; esac
    case "$_i" in *[!A-Za-z0-9._-]*|''|*/*) echo "desk-fetch: REFUSING $REMOTES line $lineno: '$_i' must be a key name under ~/.ssh, not a path" >&2; exit 65 ;; esac
    NAMES="$NAMES $_e"; TARGETS="$TARGETS $_t"; IDENTS="$IDENTS $_i"
  done < "$REMOTES"
fi

# AN ESTATE THAT CONSUMES NOTHING IS THE ORDINARY STATE for most machines in a
# fleet. Refusing an absent or empty list would make this something one must
# remember not to install.
# ...BUT IT MUST SAY SO. Rule 21: an observer is obliged to report that its own
# input went quiet before it can say why. A bare `exit 0` here is indistinguishable
# from a successful fetch of every named estate - the header's own promise, "Exit: 0
# every named estate answered", is satisfied VACUOUSLY by naming none. Measured
# 2026-09-16 on a real host: a list written one directory too high produced rc 0,
# no data and not one line, and the same rc 0 as the run that worked. The operator
# had no way to tell the two apart. Naming the path searched is what separates them.
if [ -z "${NAMES# }" ]; then
  if [ -n "$REMOTES" ]; then
    echo "desk-fetch: no estate is named in $REMOTES - nothing was fetched" >&2
  else
    echo "desk-fetch: no remotes list was found and none was named - nothing was fetched" >&2
  fi
  exit 0
fi

mkdir -p "$DESK/remote" 2>/dev/null || { echo "desk-fetch: cannot write $DESK/remote" >&2; exit 73; }
chmod 700 "$DESK/remote" 2>/dev/null

# write_meta <estate> <status> [reason]
# THE REASON IS JSON-ESCAPED BY A PARSER, not by a substitution. It carries the
# transport's own stderr, which is arbitrary text from another machine; a
# hand-rolled escape is where that becomes a broken document the Desk cannot
# read, and an unreadable meta.json is an estate that vanishes for a reason
# nobody can see.
write_meta() {
  python3 - "$DESK/remote/$1/meta.json" "$1" "$now_iso" "$2" "${3-}" <<'PYMETA'
import json, os, sys
path, estate, fetched, status, reason = sys.argv[1:6]
doc = {"estate": estate, "fetchedAt": fetched, "status": status}
if status != "ok":
    doc["reason"] = reason or "the fetch failed without a message"
tmp = path + ".tmp"
with open(tmp, "w") as f:
    # COMPACT, because this file is read by a machine and diffed by a person:
    # the default separators put a space after every colon, which is noise in
    # both uses and a surprise to anything grepping for a field.
    json.dump(doc, f, separators=(",", ":"))
os.chmod(tmp, 0o600)
os.replace(tmp, path)
PYMETA
}

worst=0
i=0
for est in $NAMES; do
  i=$((i+1))
  target="$(printf '%s' "$TARGETS" | cut -d' ' -f$((i+1)))"
  ident="$(printf '%s' "$IDENTS"  | cut -d' ' -f$((i+1)))"
  case "$WANT" in "  ") : ;; *" $est "*) : ;; *) continue ;; esac

  rdir="$DESK/remote/$est"
  mkdir -p "$rdir" 2>/dev/null || { echo "desk-fetch: cannot write $rdir" >&2; exit 73; }
  chmod 700 "$rdir" 2>/dev/null

  stage="$rdir/.fetch-$now_epoch.$$"
  rm -rf "$stage"; mkdir -p "$stage/unpack" || { echo "desk-fetch: cannot stage in $rdir" >&2; exit 73; }

  # ── the transport ────────────────────────────────────────────────────────
  if [ -n "${STEWARD_DESK_FETCH_CMD:-}" ]; then
    "$STEWARD_DESK_FETCH_CMD" "$est" >"$stage/answer.tar" 2>"$stage/why"; trc=$?
  else
    # -T: NO PTY. Without it ssh prints "Pseudo-terminal will not be allocated
    # because stdin is not a terminal" onto stderr, and stderr is where the
    # REASON comes from - so every unreachable estate led its explanation with a
    # sentence about terminals instead of with the connection error. Measured
    # against a real host. -n keeps stdin off the socket for the same reason.
    ssh -T -n -o BatchMode=yes -o ConnectTimeout=10 -o ServerAliveInterval=10 \
        -o ServerAliveCountMax=3 -i "$HOME/.ssh/$ident" "$target" \
        >"$stage/answer.tar" 2>"$stage/why"; trc=$?
  fi
  # CARRIAGE RETURNS ARE STRIPPED WITH THE NEWLINES. ssh over a pty emits CRLF,
  # and a lone \r left in the reason breaks the line where a person reads it -
  # in a terminal it overwrites what came before, in a web page it is invisible
  # and the sentence looks truncated. Both make a correct explanation look wrong.
  why="$(tr '\n\r' '  ' < "$stage/why" 2>/dev/null | sed -e 's/  */ /g' -e 's/^ //' -e 's/ $//' | cut -c1-400)"

  fault=""
  if [ "$trc" -ne 0 ]; then
    fault="${why:-the transport exited $trc with no message}"
  elif [ ! -s "$stage/answer.tar" ]; then
    # AN EMPTY ANSWER WITH rc 0 is the shape a misconfigured forced command
    # produces, and it is the one that would otherwise install an empty estate.
    fault="the estate answered with nothing (0 bytes, exit 0)"
  elif ! tar -C "$stage/unpack" -xf "$stage/answer.tar" 2>"$stage/why2"; then
    fault="the answer did not unpack: $(tr '\n' ' ' < "$stage/why2" | cut -c1-200)"
  else
    # IS IT A GENERATION? A directory that unpacked is not yet a snapshot. The
    # cheapest true test is that it holds at least one viewer file, which is
    # what every generation has and what a stray tarball does not.
    n=0; for f in "$stage/unpack"/*.json; do [ -f "$f" ] && n=$((n+1)); done
    [ "$n" -gt 0 ] || fault="the answer unpacked to no viewer file, so it is not a generation"
  fi

  if [ -n "$fault" ]; then
    # THE PREVIOUS GENERATION IS UNTOUCHED. Nothing above this line moved the
    # symlink, so there is nothing to undo - only a staging directory to drop.
    rm -rf "$stage"
    write_meta "$est" unavailable "$fault"
    echo "desk-fetch: $est unavailable - $fault" >&2
    worst=69
    continue
  fi

  gen="$rdir/gen-$now_epoch"
  rm -rf "$gen"
  mv "$stage/unpack" "$gen" || { rm -rf "$stage"; echo "desk-fetch: cannot place the generation for $est" >&2; exit 73; }
  rm -rf "$stage"
  # THE MODES ARE SET HERE, NOT INHERITED. This directory holds other people's
  # viewer files, and the mode bits are the last gate on them; a run under a
  # loose umask would otherwise hand every principal's file to any account on
  # this machine. umask 077 above covers what this process creates, and tar
  # restores the producer's modes onto what it extracted - so both are pinned.
  chmod 700 "$gen" 2>/dev/null
  for f in "$gen"/*; do [ -f "$f" ] && chmod 600 "$f" 2>/dev/null; done
  # ONE SYMLINK, MOVED LAST. A reader sees the previous generation complete or
  # this one complete, never a directory being filled.
  ln -sfn "gen-$now_epoch" "$rdir/current.new" && mv -Tf "$rdir/current.new" "$rdir/current" 2>/dev/null \
    || { rm -f "$rdir/current.new"; ln -sfn "gen-$now_epoch" "$rdir/current"; }
  write_meta "$est" ok
done

exit "$worst"
