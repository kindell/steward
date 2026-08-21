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
  rc="$(sed -n 's/^RC_LABEL="\(.*\)"/\1/p' "$conf" | head -1)"
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
  rows="$rows$name|${owner:-?}|$host|$tm|$ti|${rc:-?}
"
done

if [ -z "$have_confs" ]; then
  echo "estate-status: the registry at $RDIR holds no sessions."
  echo "  An empty registry is a real answer — but if you expected sessions, the"
  echo "  estate root may be wrong: STEWARD_ESTATE_ROOT=$(_registry_estate_root)"
  exit 0
fi

printf '%s' "$rows" | {
  printf 'SESSION|OWNER|HOST|TMUX|TIMER|RC_LABEL\n'
  cat
} | column -t -s '|'
