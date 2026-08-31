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
  # APPENDED, NOT INSERTED. The reachability pass below rewrites fields by
  # index ($3 name, $4 owner, $5 host, $6 tmux, $7 timer); a column added in the
  # middle would silently shift what those assignments touch.
  rows="$rows$sortkey|$mine|$name|$slug|${owner:-?}|$host|$tm|$ti|${rc}|$runtime|$model
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
  printf ' |SESSION|SLUG|OWNER|HOST|TMUX|TIMER|RC_LABEL|RUNTIME|MODEL\n'
  cat
} | column -t -s '|'

if [ -z "$only_mine" ]; then
  _n_mine="$(printf '%s' "$rows" | awk -F'|' '$1=="0"' | grep -c .)"
  _n_all="$(printf '%s' "$rows" | grep -c .)"
  printf '\n  * = yours (%s of %s). Other people'"'"'s sessions are shown because the machine is shared.\n' "$_n_mine" "$_n_all"
fi
