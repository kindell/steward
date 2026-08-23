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

# peek <session> — the session's screen, right now. Read-only like everything
# here; the exact target form for the same prefix-trap reason as below.
if [ "${1:-}" = "peek" ]; then
  _n="${2:?usage: estate-status.sh peek <session>}"
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

# A conf without HOST lives on the hub — the registry's own convention.
have_confs=""
rows=""
for conf in "$RDIR"/*.conf; do
  [ -f "$conf" ] || continue
  have_confs=1
  name="$(basename "$conf" .conf)"
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
    rc="(no label line)"
  fi
  host="${host:-$HUB_HOST}"
  if [ "$host" = "$SELF_HOST" ]; then
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
  rows="$rows$sortkey|$mine|$name|${owner:-?}|$host|$tm|$ti|${rc}
"
done

if [ -z "$have_confs" ]; then
  echo "estate-status: the registry at $RDIR holds no sessions."
  echo "  An empty registry is a real answer — but if you expected sessions, the"
  echo "  estate root may be wrong: STEWARD_ESTATE_ROOT=$(_registry_estate_root)"
  exit 0
fi

# --mine: yours only. For the reader who knows what they are after and does not
# want to read past the neighbour's rows. Without the flag everything is shown,
# yours first — the NEIGHBOUR's sessions being visible is not a leak but the
# point: a machine holding several people's sessions has to be understandable
# by each of the people living on it.
only_mine=""; want_remote=""
for _a in "$@"; do
  case "$_a" in
    --mine|-m)   only_mine=1 ;;
    --remote|-r) want_remote=1 ;;
    --help|-h)   echo "usage: estate-status.sh [--mine] [--remote]" >&2; exit 0 ;;
    *)           echo "estate-status: unknown option '$_a'" >&2; exit 64 ;;
  esac
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
  _hosts="$(printf '%s' "$rows" | awk -F'|' -v me="$SELF_USER" -v self="$SELF_HOST" '$4==me && $5!=self {print $5}' | sort -u)"
  for _h in $_hosts; do
    _live="$(ssh -o BatchMode=yes -o ConnectTimeout=8 -l "$SELF_USER" "$_h" \
              'tmux ls 2>/dev/null | cut -d: -f1' 2>/dev/null)" || _live="__UNREACHABLE__"
    if [ "$_live" = "__UNREACHABLE__" ]; then
      rows="$(printf '%s' "$rows" | awk -F'|' -v OFS='|' -v me="$SELF_USER" -v h="$_h" \
              '{ if ($4==me && $5==h) { $6="?(" h " unreachable)"; $7=$6 } ; print }')"
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
      { if ($4==me && $5==h) { $6 = ($3 in up) ? "up" : "down"; $7="-" } ; print }')"
  done
fi

_body="$(printf '%s' "$rows" | sort -t'|' -k1,1 -k3,3)"
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
  printf ' |SESSION|OWNER|HOST|TMUX|TIMER|RC_LABEL\n'
  cat
} | column -t -s '|'

if [ -z "$only_mine" ]; then
  _n_mine="$(printf '%s' "$rows" | awk -F'|' '$1=="0"' | grep -c .)"
  _n_all="$(printf '%s' "$rows" | grep -c .)"
  printf '\n  * = yours (%s of %s). Other people'"'"'s sessions are shown because the machine is shared.\n' "$_n_mine" "$_n_all"
fi
