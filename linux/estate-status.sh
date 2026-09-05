#!/bin/bash
# linux/estate-status.sh — the estate's sessions, one row each, joined from the
# machinery itself: registry ⋈ tmux ⋈ supervision timers. READ-ONLY, always.
#
# WHY IT EXISTS. "Which sessions can you see?" was asked inside a session whose
# discovery tools had been deliberately turned off (the account-wide messaging
# layer crosses estate boundaries, so estates close it). The honest answer must
# then come from the estate's OWN data — and it already sits readable on disk;
# what was missing was one command that joins it. The same command serves the
# human over ssh, the laptop client, and the session itself.
#
# The output is a MEASUREMENT, not a promise: tmux and timers are read at this
# instant, on THIS machine. Sessions registered for other hosts are shown with
# their host name and a dash — visible, but not answered for from here.
set -uo pipefail

_reg_lib_default() {
  local d c
  d="$(CDPATH= cd -- "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  for c in "$HOME/scripts/lib/registry.sh" "$d/lib/registry.sh" "$d/../lib/registry.sh"; do
    [ -f "$c" ] && { printf '%s' "$c"; return 0; }
  done
  printf '%s' "$HOME/scripts/lib/registry.sh"
}
REG_LIB="${STEWARD_REGISTRY_LIB:-$(_reg_lib_default)}"
[ -f "$REG_LIB" ] || { echo "estate-status: REFUSING — registry library missing: $REG_LIB" >&2; exit 78; }
# shellcheck source=/dev/null
. "$REG_LIB" || { echo "estate-status: REFUSING — registry library could not be read: $REG_LIB" >&2; exit 78; }

# SAME SEARCH, SAME THREE CANDIDATES, for lib/sort.sh — the --sort flag's
# shared reorder (lib/sort.sh's _field_sort_rows, also used by `steward
# sessions --sort`). Only RESOLVED lazily, further down, when --sort is
# actually given: unlike REG_LIB this is not required by every invocation, and
# an estate whose deploy has not yet picked up the new file must keep working
# for every use of this script that is not --sort.
_sort_lib_default() {
  local d c
  d="$(CDPATH= cd -- "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  for c in "$HOME/scripts/lib/sort.sh" "$d/lib/sort.sh" "$d/../lib/sort.sh"; do
    [ -f "$c" ] && { printf '%s' "$c"; return 0; }
  done
  printf '%s' "$HOME/scripts/lib/sort.sh"
}

RDIR="$(registry_dir)" || exit 78
HUB_HOST="$(registry_hub_host)" || exit 78
SELF_HOST="${STEWARD_SELF_HOST:-$(hostname -s)}"
# WHO IS "ME" IN A LIST OF SEVERAL PEOPLE'S SESSIONS. The unix account running
# the command — not a guess from the session name, and not $USER, which a systemd
# timer may leave unset. A wrong self-image here is silent: it only makes the
# wrong rows lack their marker, which looks like owning nothing.
SELF_USER="${STEWARD_SELF_USER:-$(id -un)}"

# TMUX IS RESOLVED, NOT ASSUMED. Over ssh the PATH is bare (a package-manager
# prefix is a login-shell luxury), and an estate may run its server on a NAMED
# socket under ~/.tmux — measured on a live hub where the plain command found
# neither binary nor server and every session read as down. The named socket is
# used only when it actually EXISTS: an estate file may name a socket its
# machinery never created, and asking a nonexistent server about sessions would
# report a healthy fleet as dead.
TMUX_BIN="tmux"
if ! command -v tmux >/dev/null 2>&1; then
  for _c in /opt/homebrew/bin/tmux /usr/local/bin/tmux /usr/bin/tmux; do
    [ -x "$_c" ] && { TMUX_BIN="$_c"; break; }
  done
fi
SOCK="$(registry_tmux_socket 2>/dev/null || true)"
_tmux() {
  if [ -n "$SOCK" ] && [ -S "$HOME/.tmux/$SOCK" ]; then
    "$TMUX_BIN" -S "$HOME/.tmux/$SOCK" "$@"
  else
    "$TMUX_BIN" "$@"
  fi
}

# resolve <name> — the SESSION KEY for a human handle. Prints the conf basename
# (the tmux/launchd/queue name) and nothing else.
#
# WHY IT EXISTS. After the naming model a row's filename is an opaque id and the
# human handle is SLUG. Every consumer that takes a name from a person needs the
# same mapping, and each one that grew its own has been a separate defect: the
# bus (fixed), fleet (fixed), and — measured 2026-08-31 by the owner —
# `steward <estate> attach <slug>` answering "can't find session". This is the
# one resolver they can all call, so the next consumer borrows instead of
# reinventing. Exact filename first (old-shape rows and migrated ids alike),
# then a SLUG scan; ambiguity refuses rather than guesses.
#
# NON-EXECUTING like every read here: sed over the file, never source.
_resolve_session_key() { # <name> -> key on stdout, rc 65 if unknown/ambiguous
  local _q="${1:-}" _d _hit _n
  case "$_q" in ''|*[!abcdefghijklmnopqrstuvwxyz0123456789-]*) return 65 ;; esac
  _d="$RDIR"
  [ -f "$_d/$_q.conf" ] && { printf '%s' "$_q"; return 0; }
  _hit=""
  for _f in "$_d"/*.conf; do
    [ -f "$_f" ] || continue
    _n="$(basename "$_f" .conf)"
    case "$_n" in *[!abcdefghijklmnopqrstuvwxyz0123456789-]*) continue ;; esac
    if [ "$(sed -n 's/^SLUG="\([a-z0-9-]*\)"$/\1/p' "$_f" | head -1)" = "$_q" ]; then
      [ -n "$_hit" ] && { echo "estate-status: '$_q' is ambiguous: $_hit and $_n" >&2; return 65; }
      _hit="$_n"
    fi
  done
  [ -n "$_hit" ] || return 65
  printf '%s' "$_hit"
}
if [ "${1:-}" = "resolve" ]; then
  _k="$(_resolve_session_key "${2:-}")" \
    || { echo "estate-status: no session '${2:-}' in the registry (tried the filename and every SLUG)" >&2; exit 65; }
  printf '%s\n' "$_k"
  exit 0
fi

# peek <session> — the session's screen, right now. Read-only like everything
# here; the exact target form for the same prefix-trap reason as below.
if [ "${1:-}" = "peek" ]; then
  _n="${2:?usage: estate-status.sh peek <session>}"
  # A HUMAN HANDLE IS ACCEPTED HERE TOO — peek by slug resolves to the key.
  _n="$(_resolve_session_key "$_n" || printf '%s' "$_n")"
  # Exact guard first (=is session-target notation), THEN the plain name for
  # capture-pane, which parses its target as a PANE and rejects the =form —
  # measured on tmux 3.4/3.6b. With exact existence established, tmux resolves
  # the exact name before any prefix match.
  _tmux has-session -t "=$_n" 2>/dev/null \
    || { echo "estate-status: no live tmux session '$_n' here" >&2; exit 65; }
  _tmux capture-pane -p -t "$_n" 2>/dev/null \
    || { echo "estate-status: the pane could not be read for '$_n'" >&2; exit 70; }
  exit 0
fi

# ── THE ORG LINEAGE COLUMN ─────────────────────────────────────────────────
#
# WHAT IT SAYS: the managing team, then the entity whose work the session is —
# `Team→Client` — or just the team's own name when nothing manages it. ONE
# MANAGED_BY hop and no more, the same deliberate limit lib/visibility.sh's
# rule 5 and lib/sessions.sh's own lineage draw: a client of a client is not
# the same work, and a column that walked the whole chain would widen on its
# own as the tree deepens.
#
# THE SAME OWNING ENTITY THE REST OF THE PRODUCT RESOLVES: TARGET_ENTITY, else
# TARGET_PROJECT's PARENT, else the legacy DOMAIN. A migrated row's DOMAIN can
# name an entity that never existed, so the declared target has to win — and
# the two listings an operator compares would otherwise disagree about the same
# session.
#
# NON-EXECUTING, LIKE EVERY OTHER READ HERE: sed over NAME/PARENT/MANAGED_BY,
# never `source`. These are other people's confs on a shared machine. That also
# makes this a status column's best safe effort rather than a second authority
# — lib/sessions.sh's lineage, reached through `steward sessions`, is the one
# that goes through the registry's own loader and its full validation.
#
# AN ANOMALY IS A DASH, NEVER A GUESS. No entity file, an empty NAME, a
# MANAGED_BY naming a row that is not there: all render "-". Falling back to
# the raw slug would print a registry gap as an org chart.
EROOT="$(_registry_estate_root 2>/dev/null)" || EROOT=""

# _org_component_ok <name> — rc 1 if a NAME must not be joined into a lineage.
#
# THREE BYTES THIS COLUMN ITSELF GENERATES OR DEPENDS ON. The arrow is produced
# by the join and by nothing else, so a NAME carrying one could forge an
# ancestor the registry does not contain. '|' is THIS table's own field
# separator, and a NAME carrying one would open a column of its own and shift
# every cell after it. A control character would break the row across lines.
_org_component_ok() {
  case "$1" in
    ""|*"→"*|*"|"*|*[[:cntrl:]]*) return 1 ;;
  esac
  return 0
}

# A conf without HOST lives on the hub — the registry's own convention.
have_confs=""
rows=""
for conf in "$RDIR"/*.conf; do
  [ -f "$conf" ] || continue
  have_confs=1
  name="$(basename "$conf" .conf)"
  # THE HUMAN HANDLE BESIDE THE OPAQUE ID. A new-shape row's filename is an
  # opaque id; SLUG is what people address and recognize. Old-shape rows have
  # no SLUG line — the filename IS the handle, so the column shows "-" there
  # rather than repeating it. Same non-executing read as everything else.
  slug="$(sed -n 's/^SLUG="\([a-z0-9-]*\)"$/\1/p' "$conf" | head -1)"
  slug="${slug:--}"
  host="$(sed -n 's/^HOST="\(.*\)"/\1/p' "$conf" | head -1)"
  owner="$(sed -n 's/^OWNER="\(.*\)"/\1/p' "$conf" | head -1)"
  # A DELIBERATE EMPTY IS NOT AN UNREADABLE ONE. RC_LABEL="" is a CHOICE — the
  # machine session runs without --remote-control so nobody can steer it
  # remotely. A conf with no RC_LABEL line at all is a forgotten label, which the
  # registry refuses to load. Rendering both as "?" made the two indistinguishable
  # in the one place a reader looks to tell them apart.
  #
  # Reported 2026-08-23 by the session it concerned. The distinction is the line's
  # PRESENCE, never the value after it — the same rule the registry and the Linux
  # supervisor already use, because after `source` an empty variable and an
  # omitted one are identical in a shell.
  if grep -q '^RC_LABEL=' "$conf" 2>/dev/null; then
    rc="$(sed -n 's/^RC_LABEL="\(.*\)"/\1/p' "$conf" | head -1)"
    rc="${rc:-(RC-free)}"
  else
    # NO LABEL LINE IS NOT A FORGOTTEN LABEL ANY MORE. A new-shape row (the
    # naming model) stores a REFERENCE — TARGET_ENTITY or TARGET_PROJECT —
    # and the display derives from the org tree. Printing "(no label line)"
    # here told the truth about the FILE and a lie about the SESSION.
    #
    # THE WALK IS NON-EXECUTING, like every other read in this tool: sed over
    # NAME/PARENT/MANAGED_BY, never source — these are other people's confs
    # on shared machines. It is a bounded, display-only sibling of the real
    # projection (registry_session_display): max four hops, and ANY anomaly —
    # missing conf, empty NAME, a loop — falls back to "(derived)", which is
    # true and invites the reader to ask the registry properly. The projection
    # stays the single owner of authoritative derivation; this is a status
    # column's best safe effort, not a second authority.
    rc="(derived)"
    _t="$(sed -n 's/^TARGET_PROJECT="\([a-z0-9-]*\)"$/\1/p' "$conf" | head -1)"; _kind="project"
    [ -n "$_t" ] || { _t="$(sed -n 's/^TARGET_ENTITY="\([a-z0-9-]*\)"$/\1/p' "$conf" | head -1)"; _kind="entity"; }
    if [ -n "$_t" ]; then
      _root="$(_registry_estate_root 2>/dev/null)" || _root=""
      _chain=""; _hop=0; _cur="$_t"; _curkind="$_kind"; _ok=1
      while [ -n "$_cur" ] && [ "$_hop" -lt 4 ]; do
        _hop=$((_hop+1))
        if [ "$_curkind" = "project" ]; then _cf="$_root/projects.d/$_cur.conf"; else _cf="$_root/entities.d/$_cur.conf"; fi
        [ -f "$_cf" ] || { _ok=""; break; }
        _nm="$(sed -n 's/^NAME="\(.*\)"$/\1/p' "$_cf" | head -1)"
        [ -n "$_nm" ] || { _ok=""; break; }
        _chain="$_nm${_chain:+→$_chain}"
        if [ "$_curkind" = "project" ]; then _cur="$(sed -n 's/^PARENT="\([a-z0-9-]*\)"$/\1/p' "$_cf" | head -1)"
        else _cur="$(sed -n 's/^MANAGED_BY="\([a-z0-9-]*\)"$/\1/p' "$_cf" | head -1)"; fi
        _curkind="entity"
      done
      [ -n "$_ok" ] && [ -n "$_chain" ] && [ -z "$_cur" ] && rc="$_chain"
    fi
  fi
  # WHICH RUNTIME, AND ON WHICH MODEL. Until a second runtime existed the answer
  # was implicit and right by accident; with two, a reader cannot tell a Claude
  # session that died from an OpenCode session that was never dispatched, and
  # those need different repairs.
  #
  # SAME NON-EXECUTING READ as host and owner above. A read-only status command
  # must not source estate session files — they may contain anything, on a
  # machine that carries several people's sessions.
  #
  # THE DEFAULTS ARE THE CONTRACT. A conf with no RUNTIME line is a Claude
  # session: every conf that exists today predates the field, and rendering
  # them unknown would make a healthy estate look unmeasured. A missing MODEL
  # renders "-" rather than empty, because a blank cell in a column-aligned
  # table reads as a rendering fault instead of "this runtime has no model".
  runtime="$(sed -n 's/^RUNTIME="\(.*\)"/\1/p' "$conf" | head -1)"
  model="$(sed -n 's/^MODEL="\(.*\)"/\1/p' "$conf" | head -1)"
  runtime="${runtime:-claude-code}"
  model="${model:--}"
  host="${host:-$HUB_HOST}"
  if [ "$host" = "$SELF_HOST" ] && [ "$owner" != "$SELF_USER" ]; then
    # THE SOCKET IS PER HOME. Another account's tmux server lives in a home
    # that is closed to us, so asking OUR socket about THEIR session can only
    # ever say "no such session" — and that used to print as "down": an alarm
    # in the one column a human acts on, produced by a question whose answer
    # was known before it was asked. Same refusal the remote sweep already
    # makes for other people's rows (below), same ?(who) form as an
    # unreachable host. Measured on a hub on a shared Linux host: every other
    # account's session read "down" while its owner was typing in it.
    tm="?($owner)"; ti="?($owner)"
  elif [ "$host" = "$SELF_HOST" ]; then
    # =name, the exact form — tmux -t prefix-matches, and a session whose name
    # prefixes a sibling's would otherwise borrow the sibling's answer
    # (measured live 2026-08-21, same fault family as the supervisor's).
    if _tmux has-session -t "=$name" 2>/dev/null; then tm="up"; else tm="down"; fi
    if command -v systemctl >/dev/null 2>&1 \
       && systemctl --user is-active "agent-session@$name.timer" >/dev/null 2>&1; then
      ti="active"
    else
      ti="-"
    fi
  else
    tm="?($host)"; ti="?($host)"
  fi
  # THE OWNING ENTITY, THEN ONE HOP ABOVE IT — see the header block above.
  org="-"
  _oe="$(sed -n 's/^TARGET_ENTITY="\([a-z0-9-]*\)"$/\1/p' "$conf" | head -1)"
  if [ -z "$_oe" ]; then
    _op="$(sed -n 's/^TARGET_PROJECT="\([a-z0-9-]*\)"$/\1/p' "$conf" | head -1)"
    if [ -n "$_op" ] && [ -n "$EROOT" ] && [ -f "$EROOT/projects.d/$_op.conf" ]; then
      _oe="$(sed -n 's/^PARENT="\([a-z0-9-]*\)"$/\1/p' "$EROOT/projects.d/$_op.conf" | head -1)"
    fi
  fi
  # THE LEGACY FALLBACK IS READ WITH A GREEDY sed AND IS THEREFORE NOT A
  # FILENAME YET. DOMAIN carries whatever the conf put there — the targets
  # above are matched against [a-z0-9-] by their own patterns, this one is not
  # — so it is checked against the registry's own id charset BEFORE it is ever
  # pasted into a path. A value carrying a slash or a dot-dot would otherwise
  # read a conf outside the entity register.
  if [ -z "$_oe" ]; then
    _oe="$(sed -n 's/^DOMAIN="\(.*\)"/\1/p' "$conf" | head -1)"
    case "$_oe" in ""|*[!a-z0-9-]*) _oe="" ;; esac
  fi
  if [ -n "$_oe" ] && [ -n "$EROOT" ] && [ -f "$EROOT/entities.d/$_oe.conf" ]; then
    _en="$(sed -n 's/^NAME="\(.*\)"$/\1/p' "$EROOT/entities.d/$_oe.conf" | head -1)"
    _emb="$(sed -n 's/^MANAGED_BY="\([a-z0-9-]*\)"$/\1/p' "$EROOT/entities.d/$_oe.conf" | head -1)"
    if _org_component_ok "$_en"; then
      if [ -z "$_emb" ]; then
        org="$_en"
      elif [ -f "$EROOT/entities.d/$_emb.conf" ]; then
        _mn="$(sed -n 's/^NAME="\(.*\)"$/\1/p' "$EROOT/entities.d/$_emb.conf" | head -1)"
        _org_component_ok "$_mn" && org="${_mn}→${_en}"
      fi
      # A MANAGED_BY NAMING A ROW THAT IS NOT THERE LEAVES THE DASH. It reads
      # as structure and carries none, and the entity register's own loader
      # refuses such a row outright — so reporting the entity alone here would
      # be a friendlier answer than the registry's, which is another way of
      # saying a less true one.
    fi
  fi
  # OWNERSHIP AS ITS OWN COLUMN, NOT AS SOMETHING THE READER MUST WORK OUT.
  #
  # The list used to print each session's OWNER and let whoever read it compare
  # against themselves. That sounds equivalent and is not: the question asked
  # from inside a session is almost never "who owns this row" but "which ones
  # are MINE", and a list that requires the reader to hold their own username
  # in their head answers the second question while looking like it answers the
  # first. In a fleet where one machine carries SEVERAL people's sessions, that
  # is the difference between seeing your group and seeing a registry.
  #
  # The marker is '*' in a column of its own and the sort puts yours first —
  # the same answer, but readable without counting.
  if [ "${owner:-}" = "$SELF_USER" ]; then mine="*"; sortkey="0"; else mine=" "; sortkey="1"; fi
  # APPENDED, NOT INSERTED. The reachability pass below rewrites fields by
  # index ($3 name, $4 owner, $5 host, $6 tmux, $7 timer); a column added in the
  # middle would silently shift what those assignments touch.
  rows="$rows$sortkey|$mine|$name|$slug|${owner:-?}|$host|$tm|$ti|${rc}|$runtime|$model|$org
"
done

if [ -z "$have_confs" ]; then
  echo "estate-status: the registry at $RDIR holds no sessions."
  echo "  An empty registry is a real answer — but if you expected sessions, the"
  echo "  estate root may be wrong: STEWARD_ESTATE_ROOT=$(_registry_estate_root)"
  exit 0
fi

# _status_sort_field <key> -> 1-indexed field number into the pipe-delimited
# `rows` built above ($sortkey|$mine|$name|$slug|$owner|$host|$tm|$ti|$rc|
# $runtime|$model|$org), or rc 1 if unknown. THE SAME KEY SET `steward sessions
# --sort` uses (name, slug, display, owner, host, lineage) — display maps to
# $rc, this table's human-readable RC_LABEL/derived column, the analogue of
# that command's resolved display name, and lineage to the ORG column. One
# place, so validation, the usage text and the refusal message can never name a
# different set of keys than this actually understands.
_status_sort_field() {
  case "$1" in
    name)    echo 3 ;;
    slug)    echo 4 ;;
    owner)   echo 5 ;;
    host)    echo 6 ;;
    display) echo 9 ;;
    lineage) echo 12 ;;
    *)       return 1 ;;
  esac
}

# THE VALID KEYS, SAID ONCE — the usage line and the refusal below both read
# this, so a key added to the map above can never be missing from one of them.
_STATUS_SORT_KEYS="name, slug, display, owner, host, lineage"

# --mine: yours only. For the reader who knows what they are after and does not
# want to read past the neighbour's rows. Without the flag everything is shown,
# yours first — the NEIGHBOUR's sessions being visible is not a leak but the
# point: a machine holding several people's sessions has to be understandable
# by each of the people living on it.
#
# --sort <key>: the SAME contract `steward sessions --sort` (1503e29) gives the
# fleet-wide list, over THIS table instead — same key names (name, slug,
# display, owner, host), same rc-64 refusal naming the valid ones, same
# stable/LC_ALL=C/dash-last reorder (lib/sort.sh's _field_sort_rows, shared
# rather than re-copied — see there). Without it the order is unchanged: yours
# first, then by name, exactly as before this flag existed.
#
# --sort TAKES A VALUE, so this loop walks an index rather than a plain
# `for _a in "$@"` — that shape sees --sort's OWN key token arrive as the NEXT
# iteration's argument and refuses it as "unknown option 'slug'". Same
# bash-3.2-safe indexed-array shape bin/steward's cmd_sessions already uses for
# the identical reason.
only_mine=""; want_remote=""; sort_key=""; sort_field=""
_st_argv=( "$@" )
_st_i=0; _st_n=${#_st_argv[@]}
while [ "$_st_i" -lt "$_st_n" ]; do
  _a="${_st_argv[$_st_i]}"
  case "$_a" in
    --mine|-m)   only_mine=1 ;;
    --remote|-r) want_remote=1 ;;
    --help|-h)   echo "usage: estate-status.sh [--mine] [--remote] [--sort <key>] — keys: $_STATUS_SORT_KEYS" >&2; exit 0 ;;
    --sort)
      _st_i=$((_st_i + 1))
      sort_key="${_st_argv[$_st_i]:-}"
      sort_field="$(_status_sort_field "$sort_key")" || {
        echo "estate-status: unknown --sort key '$sort_key' — valid keys: $_STATUS_SORT_KEYS" >&2
        exit 64
      }
      ;;
    *)           echo "estate-status: unknown option '$_a'" >&2; exit 64 ;;
  esac
  _st_i=$((_st_i + 1))
done

# --remote: FILL IN THE QUESTION MARKS THAT ARE YOURS TO FILL IN.
#
# Without the flag the list answers only for this machine, and sessions on other
# hosts read as ?(host). That is honest but insufficient for the commonest
# question from inside a session: are my siblings alive? In a fleet where most of
# your sessions live elsewhere, a list of ten question marks is no answer.
#
# IT ANSWERS ONLY FOR YOURS. The lookup runs as YOUR unix account over ssh, so it
# can only see your own tmux server on the other machine. The neighbour's rows
# stay ?(host) — not out of caution but because it is true: homes are 750 and your
# account cannot see their server. A row that claimed something about another
# person's session would be a guess in a column that looks like a measurement.
#
# AN UNREACHABLE HOST GIVES ?(host unreachable), NEVER "down". The difference is
# the whole point: "down" is an alarm somebody acts on, "cannot reach" is a
# question about the network. Merging them turns a visible failure into a silent
# one.
if [ -n "$want_remote" ]; then
  _hosts="$(printf '%s' "$rows" | awk -F'|' -v me="$SELF_USER" -v self="$SELF_HOST" '$5==me && $6!=self {print $6}' | sort -u)"
  for _h in $_hosts; do
    # THE PROBE MUST ASK THE DECLARED SOCKET. Measured 2026-08-31: a bare
    # `tmux ls` asks the DEFAULT socket while every supervised session lives on
    # the estate's declared one, so seven demonstrably live sessions were
    # reported "down" — a false alarm in the one column a human acts on, which
    # is worse than "?": a silent failure wearing the clothes of a measurement.
    # Same socket-contract class as the stranger-journey finding #9 and the
    # zombie-pane hunt. The socket name is the estate's own value; the remote
    # HOME is the remote account's, so the path is expanded THERE (single
    # quotes), never here.
    _sock_name="$(registry_tmux_socket 2>/dev/null)" || _sock_name=""
    if [ -n "$_sock_name" ]; then
      _live="$(ssh -o BatchMode=yes -o ConnectTimeout=8 -l "$SELF_USER" "$_h" \
                "tmux -S \"\$HOME/.tmux/$_sock_name\" ls 2>/dev/null | cut -d: -f1" 2>/dev/null)" || _live="__UNREACHABLE__"
    else
      _live="$(ssh -o BatchMode=yes -o ConnectTimeout=8 -l "$SELF_USER" "$_h" \
                'tmux ls 2>/dev/null | cut -d: -f1' 2>/dev/null)" || _live="__UNREACHABLE__"
    fi
    if [ "$_live" = "__UNREACHABLE__" ]; then
      rows="$(printf '%s' "$rows" | awk -F'|' -v OFS='|' -v me="$SELF_USER" -v h="$_h" \
              '{ if ($5==me && $6==h) { $7="?(" h " unreachable)"; $8=$7 } ; print }')"
      continue
    fi
    # NEWLINES MUST NOT TRAVEL IN AN awk -v. A variable containing line breaks
    # breaks awk's own parsing of the program text — this failed on it once, and
    # the failure looked like an empty registry, which is precisely the outcome
    # that must never arise from a formatting mistake. The list is therefore
    # flattened to one space-separated line before being handed over.
    _live_flat="$(printf '%s' "$_live" | tr '\n' ' ')"
    rows="$(printf '%s' "$rows" | awk -F'|' -v OFS='|' -v me="$SELF_USER" -v h="$_h" -v live="$_live_flat" '
      BEGIN { n=split(live, a, " "); for (i=1;i<=n;i++) if (a[i]!="") up[a[i]]=1 }
      { if ($5==me && $6==h) { $7 = ($3 in up) ? "up" : "down"; $8="-" } ; print }')"
  done
fi

# --sort REPLACES THE DEFAULT ORDER ENTIRELY, rather than sorting within it —
# the same choice `steward sessions --sort` already made: an operator who
# asked to see the table by HOST does not also want "yours first" quietly
# still in charge of ties. lib/sort.sh is sourced LAZILY, only when --sort was
# actually given: every other estate-status.sh invocation (the overwhelming
# majority — --sort is new) must keep working unchanged even on an estate
# whose deploy has not yet picked up lib/sort.sh, exactly like REG_LIB is
# required only because every invocation needs it and this file does not.
if [ -n "$sort_field" ]; then
  SORT_LIB="${STEWARD_SORT_LIB:-$(_sort_lib_default)}"
  [ -f "$SORT_LIB" ] || { echo "estate-status: REFUSING — sort library missing: $SORT_LIB" >&2; exit 78; }
  # shellcheck source=/dev/null
  . "$SORT_LIB" || { echo "estate-status: REFUSING — sort library could not be read: $SORT_LIB" >&2; exit 78; }
  _body="$(printf '%s' "$rows" | _field_sort_rows "$sort_field" '|')"
else
  _body="$(printf '%s' "$rows" | sort -t'|' -k1,1 -k3,3)"
fi
if [ -n "$only_mine" ]; then
  _body="$(printf '%s\n' "$_body" | awk -F'|' '$1=="0"')"
  if [ -z "$_body" ]; then
    # ZERO IS AN ANSWER, not an empty printout. Otherwise an empty list and a
    # broken lookup look exactly alike.
    echo "estate-status: no sessions are owned by '$SELF_USER' in the registry on $SELF_HOST."
    echo "  (Run without --mine to see the whole registry: $(printf '%s' "$rows" | grep -c . ) rows.)"
    exit 0
  fi
fi

printf '%s\n' "$_body" | cut -d'|' -f2- | {
  printf ' |SESSION|SLUG|OWNER|HOST|TMUX|TIMER|RC_LABEL|RUNTIME|MODEL|ORG\n'
  cat
} | column -t -s '|'

if [ -z "$only_mine" ]; then
  _n_mine="$(printf '%s' "$rows" | awk -F'|' '$1=="0"' | grep -c .)"
  _n_all="$(printf '%s' "$rows" | grep -c .)"
  printf '\n  * = yours (%s of %s). Other people'"'"'s sessions are shown because the machine is shared.\n' "$_n_mine" "$_n_all"
fi
