#!/bin/bash
# linux/liveness-host.sh — the HOST-SIDE liveness answerer for one Linux home.
#
# WHAT IT IS FOR. The liveness seam joins a measurement map into the session
# list, and the only producer of that map used to be a shim that read the
# machine it ran on: local daemons, the local tmux server. On a fleet whose
# sessions mostly live somewhere else that is honest and nearly useless —
# measured on one estate, six of twenty-one rows carried a real measurement and
# fifteen read `unknown` / `not-in-answer`. Those fifteen were not
# unmeasurable. Nobody had asked the machine they live on.
#
# This is that machine's answer. Run in a home, it reports every registry row
# that lives on THIS host and belongs to THE INVOKING UNIX ACCOUNT, in the same
# contract shape the seam already parses:
#
#   {"sessions":{"<id>":{daemon,tmux,agent,runtime,model,lastActivity}},
#    "omitted":{"<id>":"<reason>"}}
#
# WHY BASH AND NOT NODE. Every other thing that measures a Linux session host is
# bash — the supervisor whose ancestry walk this file reuses, and the status
# table beside it — and the two would drift the moment they were written in
# different languages against the same process tree. Bash and coreutils are also
# the only interpreter a session host is guaranteed to have by virtue of running
# the supervisor at all; a Node dependency would be a second thing that must be
# true before liveness can be measured, on the exact path whose failure mode is
# "the fleet looks dead".
#
# THE KEY IS THE ID, NEVER THE SLUG. A row's key is its conf basename. The slug
# is a human handle: mutable, account-scoped and permitted to collide between
# people. A flat measurement map keyed on a slug can pin a stale status onto the
# WRONG session — which is exactly how a whole fleet once reported unknown after
# a naming cutover, the shim answering on display names while the registry keyed
# on ids. Slugs belong in interactive command resolution, where one resolves to
# an id BEFORE anything happens.
#
# IT ANSWERS ONLY FOR ITS OWN ACCOUNT, and that is not caution. Homes are 750:
# this account cannot read the neighbour's tmux server, their user units, or
# their process tree. Their rows therefore leave the answer ENTIRELY — not in
# `sessions`, not in `omitted`. An omission says "I tried and could not"; this
# account never had standing to try, and putting their rows in a measurement map
# would invite a reader to believe something is broken rather than that it
# belongs to somebody else. The other machine's rows leave for the same reason:
# another host answers for them.
#
# A PROBE THAT CANNOT BE MADE IS NAMED, NEVER GUESSED. If a tool this file needs
# is absent, its rows go to `omitted` with a sentence saying so. Nothing is ever
# written into `sessions` on a guess: a guess and a measurement look identical
# downstream, and keeping "cannot measure" apart from "is down" is the whole
# reason the model this file feeds was built.
#
# READ-ONLY, ALWAYS. It probes, prints, and touches nothing.
set -uo pipefail

# NO ARGUMENTS. The contract is the whole home in ONE call — the asset layer
# already costs an ssh round trip per session and the liveness layer must not
# inherit that mistake. A refusal writes to stderr and leaves stdout EMPTY, so
# a caller can tell it apart from a home with no sessions.
if [ "$#" -gt 0 ]; then
  printf 'liveness-host: takes no arguments — the contract is the whole home in one call\n' >&2
  exit 64
fi

_reg_lib_default() {
  local d c
  d="$(CDPATH= cd -- "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  for c in "$HOME/scripts/lib/registry.sh" "$d/lib/registry.sh" "$d/../lib/registry.sh"; do
    [ -f "$c" ] && { printf '%s' "$c"; return 0; }
  done
  printf '%s' "$HOME/scripts/lib/registry.sh"
}
REG_LIB="${STEWARD_REGISTRY_LIB:-$(_reg_lib_default)}"
[ -f "$REG_LIB" ] || { echo "liveness-host: REFUSING — registry library missing: $REG_LIB" >&2; exit 78; }
# shellcheck source=/dev/null
. "$REG_LIB" || { echo "liveness-host: REFUSING — registry library could not be read: $REG_LIB" >&2; exit 78; }

RDIR="$(registry_dir)" || exit 78
HUB_HOST="$(registry_hub_host)" || exit 78
SELF_HOST="${STEWARD_SELF_HOST:-$(hostname -s 2>/dev/null || hostname)}"
# WHO IS "ME" ON A MACHINE CARRYING SEVERAL PEOPLE'S SESSIONS: the unix account
# running the command. Not $USER, which a systemd unit may leave unset, and not
# a guess from a session name. A wrong self-image here is silent — it simply
# answers for the wrong set.
SELF_USER="${STEWARD_SELF_USER:-$(id -un)}"

# systemd --user OVER SSH HAS NO SESSION BUS UNLESS TOLD WHERE IT IS. A
# non-login ssh command inherits no XDG_RUNTIME_DIR, and `systemctl --user`
# then fails for a reason that has nothing to do with the timer — every row
# would read as unsupervised. The value is derivable and stable, so derive it
# rather than reporting a fleet-wide failure caused by the transport.
export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"

# ── the tools this file needs, resolved rather than assumed ──────────────────
# Over ssh the PATH is bare; a package-manager prefix is a login-shell luxury.
have() { command -v "$1" >/dev/null 2>&1; }
TMUX_BIN=""
if have tmux; then TMUX_BIN="tmux"; else
  for _c in /usr/bin/tmux /usr/local/bin/tmux /opt/homebrew/bin/tmux; do
    [ -x "$_c" ] && { TMUX_BIN="$_c"; break; }
  done
fi
MISSING=""
[ -n "$TMUX_BIN" ] || MISSING="${MISSING:+$MISSING, }tmux"
have systemctl || MISSING="${MISSING:+$MISSING, }systemctl"
have pgrep     || MISSING="${MISSING:+$MISSING, }pgrep"
have ps        || MISSING="${MISSING:+$MISSING, }ps"
# `stat` IS ONE OF THEM. A codex row's lastActivity IS an mtime, and an mtime
# comes from stat. Without it that field could only be reported as null, which
# reads as "this row never ran" - a sentence about the row, invented on a host
# that never managed to look. Named, like every other tool that is not there.
have stat      || MISSING="${MISSING:+$MISSING, }stat"

# THE DECLARED SOCKET, WHEN IT EXISTS. Measured on a live fleet: a bare
# `tmux ls` asks the DEFAULT socket while every supervised session lives on the
# estate's declared one, so seven demonstrably live sessions were reported
# "down" — a false alarm in the one column a human acts on, which is worse than
# a question mark. The named socket is used only when it actually EXISTS: an
# estate file may name a socket its machinery never created, and asking a server
# that is not there would report a healthy home as dead.
SOCK="$(registry_tmux_socket 2>/dev/null || true)"
_tmux() {
  if [ -n "$SOCK" ] && [ -S "$HOME/.tmux/$SOCK" ]; then
    "$TMUX_BIN" -S "$HOME/.tmux/$SOCK" "$@"
  else
    "$TMUX_BIN" "$@"
  fi
}

# ── the two probes that are made ONCE for the whole home ─────────────────────
# One tmux call gives both which sessions are live and when each was last
# active; one pgrep call gives every candidate runtime process. Doing either per
# session would put the fleet's size into the cost of asking about it.
LIVE_NAMES=""; LIVE_ACT=""
# WHY THE RETURN CODE IS KEPT, AND WHY IT IS NOT ENOUGH ON ITS OWN. This probe
# used to end in `|| true`, which made a tmux call that FAILED indistinguishable
# from a tmux server with nothing on it: every pane row in the home was then
# written into `sessions` as `down` / `not-running`. Measured 2026-09-09 - three
# live sessions, one of them the process doing the measuring, reported dead with
# an empty stderr and an empty `omitted`. A guess wearing a measurement's
# clothes, which is the thing this file exists not to produce.
#
# BUT A NON-ZERO rc IS NOT BY ITSELF A FAILURE TO MEASURE, and reading it as one
# would break the opposite case just as badly. `tmux list-sessions` exits 1 when
# there is simply NO SERVER - the ordinary state of a home with nothing running
# - and that is a real measurement: no server, therefore no pane, therefore
# nothing can descend from one. Treating it as unmeasurable would turn every
# quiet home into a column of question marks.
#
# So the two are told apart by what tmux SAYS, measured against tmux 3.4:
#   no server running on <path>                     -> nothing is up  (a measurement)
#   error connecting to <path> (Permission denied)  -> could not ask  (unmeasurable)
#   error connecting to <path> (No such file ...)   -> could not ask  (unmeasurable)
#   killed by the caller's deadline, rc 124         -> could not ask  (unmeasurable)
#
# THE UNRECOGNISED CASE FALLS TO `unmeasurable`, DELIBERATELY. If a future tmux
# rewords its own message, this branch degrades into naming a probe it could not
# make - a question mark with a sentence attached - and never into inventing a
# dead fleet. The safe direction is the one that cannot fabricate a negative.
TMUX_REASON=""
if [ -z "$MISSING" ]; then
  # The command's own stderr is the evidence that decides the branch, so it is
  # captured rather than discarded. A home that cannot even hold a temporary
  # file cannot be probed either, and says so rather than guessing.
  _lserr="$(mktemp 2>/dev/null)" || _lserr=""
  if [ -z "$_lserr" ]; then
    TMUX_REASON="could not create a temporary file to capture tmux's own error"
  else
    _ls="$(_tmux list-sessions -F '#{session_name} #{session_activity}' 2>"$_lserr")"; _lsrc=$?
    _lsmsg="$(tr '\n' ' ' < "$_lserr")"; rm -f "$_lserr"
    if [ "$_lsrc" -ne 0 ]; then
      case "$_lsmsg" in
        *"no server running"*)
          # A MEASUREMENT: there is no server, so there are no live sessions.
          # The empty list below is the honest answer, not a missing one.
          _ls="" ;;
        *)
          TMUX_REASON="tmux could not be asked (rc $_lsrc)${_lsmsg:+: $_lsmsg}" ;;
      esac
    fi
    if [ -z "$TMUX_REASON" ]; then
      LIVE_NAMES=" $(printf '%s' "$_ls" | awk '{print $1}' | tr '\n' ' ')"
      LIVE_ACT="$_ls"
    fi
  fi
  # SAID ONCE, FOR THE HOME, not once per row. The omission below carries the
  # sentence to the reader of the answer; this carries it to whoever is reading
  # the log of the run that produced it.
  [ -z "$TMUX_REASON" ] || echo "liveness-host: $TMUX_REASON - no pane row on $SELF_HOST could be measured" >&2
fi

# THE PATTERN IS DELIBERATELY THE BROAD ONE. The supervisor anchors its pattern
# on the session's remote-control label because it decides RESTARTS, and a wide
# match there would let one session's process keep a sibling alive on paper.
# This file decides nothing; it reports whether a runtime lives under this
# session's panes, and the pane-descendant check below is what carries identity
# — it has done so since the day an orphaned runtime, reparented to init and
# matching every pattern, convinced supervision that a dead session was alive.
RUNTIME_PAT='(^|[ /])(claude|opencode)'
RUNTIME_PIDS=""
# THE SAME DISTINCTION, THE SECOND DOOR. `pgrep` exits 1 when nothing matched -
# a measurement, and the common one on a quiet home - and something greater than
# 1 when it could not look at all. `|| true` collapsed both into an empty list,
# and an empty list makes every live pane row read `not-running`: the identical
# fabrication the tmux branch above was just fixed for, reached by a different
# command. Only rc > 1 is a failure to measure.
PGREP_REASON=""
if [ -z "$MISSING" ] && [ -z "$TMUX_REASON" ]; then
  RUNTIME_PIDS="$(pgrep -u "$(id -u)" -f "$RUNTIME_PAT" 2>/dev/null)"; _pgrc=$?
  if [ "$_pgrc" -gt 1 ]; then
    RUNTIME_PIDS=""
    PGREP_REASON="pgrep could not be asked (rc $_pgrc)"
    echo "liveness-host: $PGREP_REASON - no pane row on $SELF_HOST could be measured" >&2
  fi
fi

# -- the codex runtime's two paths, derived ONCE for the whole home ----------
# A codex row is measured at a control socket and inside a state directory, and
# both are the same for every row in this home. Deriving them per row would fork
# a subshell and re-read the estate file once per session - the cost model the
# two probes above exist to avoid, in a file whose whole promise is that the
# fleet's size does not enter the price of asking about it.
#
# BOTH ARE THE ADAPTER'S OWN PRODUCTION KNOBS, spelled the way it spells them. A
# third name invented here would keep measuring a home that has moved either
# path at the place it no longer is.
CODEX_SOCK="${STEWARD_CODEX_DAEMON_SOCK:-${CODEX_HOME:-$HOME/.codex}/app-server-control/app-server-control.sock}"
CODEX_STATE_DIR=""
CODEX_STATE_REASON=""
if [ -n "${STEWARD_CODEX_STATE_DIR:-}" ]; then
  CODEX_STATE_DIR="$STEWARD_CODEX_STATE_DIR"
else
  # THE RETURN CODE IS KEPT, and that is the entire reason this is not one
  # expansion. Inside a `${x:-default}` the refusal of this call is invisible:
  # the estate names no state directory, the answer is empty, the path becomes a
  # state tree with a hole where the name should be, and every codex row is
  # probed there, found absent, and written into `sessions` as not-running. That
  # is a guess wearing a measurement's clothes - the one thing this file
  # promises never to produce. A row that cannot be probed is NAMED instead.
  _cx_name="$(registry_state_dir_name 2>/dev/null)"; _cx_rc=$?
  if [ "$_cx_rc" -eq 0 ] && [ -n "$_cx_name" ]; then
    CODEX_STATE_DIR="$HOME/.local/state/$_cx_name"
  else
    CODEX_STATE_REASON="the estate does not name a state directory"
  fi
fi

# Is $1 equal to or a descendant of $2? Climb ppid until the target, init (1) or
# a ceiling — the ceiling guards against a broken ps that cycles. Same walk as
# the supervisor's; the two must agree about what "belongs to this session"
# means, or a status table and the thing that repairs it would disagree.
is_descendant() {
  local pid="$1" target="$2" n=0
  while [ -n "$pid" ] && [ "$pid" -gt 1 ] 2>/dev/null && [ "$n" -lt 40 ]; do
    [ "$pid" = "$target" ] && return 0
    pid="$(ps -o ppid= -p "$pid" 2>/dev/null | tr -d ' ')"
    n=$((n+1))
  done
  return 1
}

# ── JSON, escaped by hand because jq is not a session host's guarantee ───────
# Only the value characters JSON forbids are touched: backslash, double quote,
# and control characters. A field that arrived from a conf is free data and must
# never be able to close a string and continue as structure.
_json_str() {
  printf '%s' "${1-}" \
    | LC_ALL=C sed -e 's/\\/\\\\/g' -e 's/"/\\"/g' \
                   -e 's/	/\\t/g' \
                   -e 's/[[:cntrl:]]//g' \
    | tr -d '\n'
}
_conf_val() { # <file> <KEY> — non-executing read, never source
  sed -n "s/^$2=\"\(.*\)\"\$/\1/p" "$1" | head -1
}

sess_json=""; omit_json=""
add_sess() { sess_json="${sess_json:+$sess_json,}$1"; }
add_omit() { omit_json="${omit_json:+$omit_json,}\"$(_json_str "$1")\":\"$(_json_str "$2")\""; }

for conf in "$RDIR"/*.conf; do
  [ -f "$conf" ] || continue
  id="$(basename "$conf" .conf)"
  case "$id" in *[!abcdefghijklmnopqrstuvwxyz0123456789-]*) continue ;; esac
  owner="$(_conf_val "$conf" OWNER)"
  host="$(_conf_val "$conf" HOST)"
  # A conf without HOST lives on the hub — the registry's own convention.
  host="${host:-$HUB_HOST}"

  # NOT OURS TO REPORT — see the file header. Neither measured nor excused.
  [ "$owner" = "$SELF_USER" ] || continue
  [ "$host" = "$SELF_HOST" ] || continue

  if [ -n "$MISSING" ]; then
    add_omit "$id" "cannot probe on $SELF_HOST: missing $MISSING"
    continue
  fi

  # RUNTIME COMES FROM THE ROW, not from a probe - it is what the session was
  # DECLARED to run, and the seam renders a runtime name as itself. A conf with
  # no RUNTIME line is a Claude row: every conf that predates the field is one,
  # and calling them unknown would make a healthy home look unmeasured. It is
  # read HERE, before any probe, because it decides WHICH probes are the honest
  # ones for this row.
  runtime="$(_conf_val "$conf" RUNTIME)"; runtime="${runtime:-claude-code}"

  if [ "$runtime" = "codex" ]; then
    # A CODEX ROW IS A THREAD, NOT A PANE, and the three probes below the else
    # each answer a different question it was never asked. Measured on a session
    # host: a healthy codex row - its supervising timer active, its last round
    # finished a second after it started, the owner's app-server daemon up with
    # remote control, a thread id on disk and the last letter answered three
    # hours earlier - was rendered as not-running with no activity at all, and a
    # person asked why the page was broken. The page was fine. The measurement
    # lied, three times: the timer probe asks about a unit template this row is
    # not supervised by, the tmux probe asks for a session this runtime never
    # creates, and the pane walk asks which runtime process descends from panes
    # that do not exist. Three wrong answers about one healthy row.

    # A ROW WHOSE STATE DIRECTORY HAS NO NAME CANNOT BE PROBED AT ALL. The
    # thread and the ledger both live inside it, so without the name there is
    # nothing to look at and nothing true to say about this row except that. It
    # goes to `omitted` with the sentence, and never into `sessions`.
    if [ -z "$CODEX_STATE_DIR" ]; then
      add_omit "$id" "cannot probe on $SELF_HOST: $CODEX_STATE_REASON"
      continue
    fi

    # DAEMON. The unit template that actually supervises a codex row. Same word
    # pair as every other row: an armed timer is `loaded`, a stopped or absent
    # one is `missing`, and that is a MEASUREMENT.
    if systemctl --user is-active "agent-codex@$id.timer" >/dev/null 2>&1; then
      daemon="loaded"
    else
      daemon="missing"
    fi

    # TMUX. The literal `n/a`, and deliberately NOT `down`. `down` is the
    # sentence "we looked for a pane and there was none"; here nobody looked,
    # because this runtime owns no tmux session BY DESIGN. Saying `n/a` tells a
    # reader the column does not apply to this row, which is the true sentence
    # and the only one they can act on.
    tmux_state="n/a"

    # AGENT. Two facts stand in for the pane walk: the owner's daemon is
    # listening, and this row has a thread to speak into. Both paths are the
    # adapter's own production knobs - the same environment names it reads - so
    # a home that has moved either one is measured where it actually lives.
    #
    # THE SOCKET IS TESTED FOR EXISTENCE AND NEVER OPENED. This file is
    # read-only and answers for a whole home in one call; a probe that
    # negotiates a websocket is a probe that can hang the entire answer. The
    # existence test is also EXACTLY what the thread client itself uses to
    # decide whether the daemon is up, so the two agree by construction rather
    # than by anybody remembering to keep them in step.
    _cx_thread="$CODEX_STATE_DIR/$id.codex-thread"
    agent="not-running"
    if [ -S "$CODEX_SOCK" ] && [ -s "$_cx_thread" ]; then agent="running"; fi

    # LAST ACTIVITY. The newest mtime of the two files this runtime writes: the
    # ledger of answered letters, and the thread id. Neither present is a row
    # that has never run - null, which is a measurement, and never a stale stamp
    # dressed as one. `stat` is asked in the GNU form first and the BSD form
    # second; `ls` output is a rendering, not a field, and is never parsed.
    last="null"
    _cx_newest=""
    for _cx_f in "$CODEX_STATE_DIR/$id.codex-answered" "$_cx_thread"; do
      [ -e "$_cx_f" ] || continue
      _cx_m="$(stat -c %Y "$_cx_f" 2>/dev/null || stat -f %m "$_cx_f" 2>/dev/null || true)"
      case "$_cx_m" in ''|*[!0123456789]*) continue ;; esac
      if [ -z "$_cx_newest" ] || [ "$_cx_m" -gt "$_cx_newest" ]; then _cx_newest="$_cx_m"; fi
    done
    if [ -n "$_cx_newest" ]; then
      _iso="$(date -u -d "@$_cx_newest" +%Y-%m-%dT%H:%M:%S.000Z 2>/dev/null \
              || date -u -r "$_cx_newest" +%Y-%m-%dT%H:%M:%S.000Z 2>/dev/null || true)"
      [ -n "$_iso" ] && last="\"$(_json_str "$_iso")\""
    fi
  else
    # A PANE ROW WHOSE TMUX COULD NOT BE ASKED IS UNMEASURABLE, and is named
    # rather than answered. Every probe below this line reads the tmux answer,
    # directly or through the pane walk; without it the three of them would
    # agree on a confident `down` / `not-running` that nobody measured.
    #
    # THE CODEX BRANCH ABOVE IS DELIBERATELY UNTOUCHED BY THIS. A codex row is a
    # thread, not a pane: it is measured at a socket and a state directory and
    # never needed tmux at all. An outage in one runtime's probe may not erase
    # the other runtime's answer - the whole home going dark on a tmux failure
    # is the blast radius this branch exists to bound.
    if [ -n "$TMUX_REASON" ]; then
      add_omit "$id" "cannot probe on $SELF_HOST: $TMUX_REASON"
      continue
    fi
    if [ -n "$PGREP_REASON" ]; then
      add_omit "$id" "cannot probe on $SELF_HOST: $PGREP_REASON"
      continue
    fi

    # DAEMON. `is-active` on the session's user timer, the same unit name the
    # supervisor and the status table use. An armed timer is `loaded`; no timer,
    # or a stopped one, is `missing` - and that is a MEASUREMENT, not a failure to
    # measure: we looked, and supervision is not running for this row.
    if systemctl --user is-active "agent-session@$id.timer" >/dev/null 2>&1; then
      daemon="loaded"
    else
      daemon="missing"
    fi

    # TMUX. Membership in the one list-sessions answer above.
    case "$LIVE_NAMES" in
      *" $id "*) tmux_state="up" ;;
      *)         tmux_state="down" ;;
    esac

    # AGENT. A runtime process that descends from one of THIS session's panes.
    # With no tmux session there are no panes, so nothing can descend from it -
    # `not-running` is measured, not assumed.
    agent="not-running"
    last="null"
    if [ "$tmux_state" = "up" ]; then
      # The exact target form (=name): tmux -t prefix-matches, and a session whose
      # name prefixes a sibling's would otherwise borrow the sibling's panes.
      # EVERY window (-s), never just the current one: a human who opens a second
      # window makes the runtime in window 0 invisible to a current-window probe.
      panes="$(_tmux list-panes -s -t "=$id" -F '#{pane_pid}' 2>/dev/null || true)"
      if [ -n "$panes" ]; then
        for pid in $RUNTIME_PIDS; do
          for pane in $panes; do
            if is_descendant "$pid" "$pane"; then agent="running"; break 2; fi
          done
        done
      fi
      # LAST ACTIVITY, only where it is free: tmux already told us, in the same
      # call that told us the session is live. A row that is not up has no
      # activity to report - null, never a stale stamp dressed as a measurement.
      _e="$(printf '%s\n' "$LIVE_ACT" | awk -v n="$id" '$1==n {print $2; exit}')"
      if [ -n "$_e" ]; then
        _iso="$(date -u -d "@$_e" +%Y-%m-%dT%H:%M:%S.000Z 2>/dev/null \
                || date -u -r "$_e" +%Y-%m-%dT%H:%M:%S.000Z 2>/dev/null || true)"
        [ -n "$_iso" ] && last="\"$(_json_str "$_iso")\""
      fi
    fi
  fi

  # THE MODEL COMES FROM THE ROW TOO, and a missing MODEL is null - "we looked
  # and there is no value" - which the seam keeps distinct from an absent key.
  model="$(_conf_val "$conf" MODEL)"
  if [ -n "$model" ]; then model="\"$(_json_str "$model")\""; else model="null"; fi

  add_sess "\"$(_json_str "$id")\":{\"daemon\":\"$daemon\",\"tmux\":\"$tmux_state\",\"agent\":\"$agent\",\"runtime\":\"$(_json_str "$runtime")\",\"model\":$model,\"lastActivity\":$last}"
done

printf '{"sessions":{%s},"omitted":{%s}}\n' "$sess_json" "$omit_json"
