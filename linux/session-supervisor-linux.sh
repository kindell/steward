#!/bin/bash
# linux/session-supervisor-linux.sh <name> <repo> — supervision for a session
# host: makes sure a tmux session with claude is running, and resumes the latest
# conversation after a restart. Run by agent-session@.timer.
#
# THE SIGN OF LIFE IS THE PROCESS, NOT THE PANE'S COMMAND NAME. The first
# version checked pane_current_command against claude|node — and in a brief
# window it reports something else, whereupon the "repair" wrote the command line
# AS USER INPUT into a live session. One session proved it from its own
# conversation log on 2026-08-06: the string appeared twice as a user message,
# once in the middle of a tool call. Writing into a live session is worse than
# waiting one more round.
#
# Hence: (1) pgrep against the RC label — the claude process exists continuously
# while the session lives, unlike the pane's command name; (2) any repair that
# WRITES something requires two consecutive rounds reaching the same conclusion
# (the suspect marker), so a single false negative never touches the
# conversation.
set -uo pipefail
NAME="${1:?session-supervisor-linux <name> [repo]}"
export PATH="$HOME/.local/bin:$PATH"

# ── THE PAUSE MARKER IS READ BEFORE ANYTHING ELSE ──────────────────────────
# This check used to sit two hundred lines further down, AFTER the conf refusal. A paused
# session whose conf was absent from the DEPLOYED registry therefore failed early
# and never reached it.
#
# MEASURED 2026-08-20 on one host: 1262 failed runs since 6 August, zero
# successful, and the journal's oldest line was the first attempt. Nothing was
# down — the session was paused deliberately — but the timer burned four times an
# hour for fourteen days.
#
# AND CENTRAL SUPERVISION DID NOT SEE IT: it logs "paused — skipped" and moves
# on, which is right. The combination is what is dangerous: A PAUSE SILENCES THE
# EVIDENCE, not just the work. A paused session can fail for as long as it likes
# without anyone noticing, and 1262 journal lines make a REAL failure chain
# harder to find. An alarm drowns in an alarm nobody cares about.
#
# THE ORDER IS THE WHOLE IDEA. A deliberate shutdown answers the question "should
# this session run", and that question comes before every question about HOW it
# should run. Reading the configuration first is asking how to start something
# you have already decided not to start.
#
# THE REFUSAL ON A MISSING CONF IS UNCHANGED for sessions that are NOT paused —
# rc 78, loudly, for the reasons stated at that check. The suite has control
# groups in both directions precisely so that property is not lost while this
# line moves.
#
# The paths are derived from $HOME and $NAME, never from the conf, so they can be
# computed up here. That is what made the move possible without duplicating a
# check.
# THE STATE DIRECTORIES' NAMES COME FROM THE ESTATE. They were literals until
# 2026-08-20 and carried its name; the directories themselves are UNCHANGED.
#
# THE REGISTRY IS LOADED BEFORE THE PAUSE GUARD, but the refusal is NOT. The
# order is the whole idea of #112: a paused session must exit 0 without asking
# anything about HOW it would have been started. So the library is loaded here,
# but a failed lookup falls back to an EMPTY string and the refusal happens
# only after the pause guard — otherwise a broken estate would have burned a
# timer every three minutes for every paused session, which is exactly the
# damage #112 measured.
# THE LIBRARY IS FOUND IN THE DEPLOYED LAYOUT FIRST, then relative to this
# file. The order is the whole idea: an existing installation must behave exactly as
# before, so the deployed path wins whenever it exists. Only on a machine with
# no deployment — a checkout, a fresh estate — do the siblings apply. The first
# ordering tried was the reverse, and it made a supervisor in a product checkout
# read the PRODUCT tree as its estate: sixty-nine green tests went thirty-six
# red at once, which is exactly what the fixtures are for.
_reg_lib_default() {
  local d c
  d="$(CDPATH= cd -- "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  for c in "$HOME/scripts/lib/registry.sh" "$d/lib/registry.sh" "$d/../lib/registry.sh"; do
    [ -f "$c" ] && { printf '%s' "$c"; return 0; }
  done
  printf '%s' "$HOME/scripts/lib/registry.sh"
}
REG_LIB="${STEWARD_REGISTRY_LIB:-$(_reg_lib_default)}"
_reg_ok=""
if [ -f "$REG_LIB" ]; then
  # shellcheck source=/dev/null
  . "$REG_LIB" 2>/dev/null && _reg_ok=1
fi
# THE BRIDGE LIBRARY SITS BESIDE THE REGISTRY LIBRARY, found the same way - but it is loaded only
# once the runtime is known (after the conf, at IS_CLAUDE), and only for a claude row: an OpenCode
# round must be byte-identical to what it was, and a syntactically broken bridge.sh must not be able
# to end it (advisor H5). The path is resolved here, the source happens below.
BRIDGE_LIB="${STEWARD_BRIDGE_LIB:-$(dirname "$REG_LIB")/bridge.sh}"
_bridge_ok=""
# THE SPAWN LIBRARIES SIT NEXT TO THE REGISTRY LIBRARY, and are found the same
# way: whatever directory REG_LIB actually resolved to, deployed or in a
# checkout. Deriving them separately would let a host load its registry from
# ~/scripts/lib and its spawn policy from a checkout that happens to be lying
# around, which is two different opinions about the same session.
#
# LOADED HERE, REFUSED LATER, exactly like the registry above: a paused session
# must reach its guard without being asked anything about HOW it would have
# been started (#112). A missing library is remembered by name and answered
# below.
_MCP_LIB_DIR="$(dirname "$REG_LIB")"
_mcp_lib_missing=""
for _c in mcprender.sh mcpspawn.sh; do
  if [ -f "$_MCP_LIB_DIR/$_c" ]; then
    # shellcheck source=/dev/null
    . "$_MCP_LIB_DIR/$_c" 2>/dev/null || _mcp_lib_missing="$_MCP_LIB_DIR/$_c"
  else
    _mcp_lib_missing="$_MCP_LIB_DIR/$_c"
  fi
done
# PRESENCE IS NOT CONTENTS, and the difference is a rollout state. A deployed
# lib that is there and sources cleanly but PREDATES the function this file
# calls -- exactly what a future edit to these libraries produces halfway
# through a deploy -- passed a file check and then made
# mcp_claude_cmd_fragment a command-not-found, which makes CLAUDE_CMD the EMPTY
# STRING. The CLAUDE_BIN guard does not catch that either: the first word of an
# empty string is empty, so the guard tests -x on "$HOME/.local/bin/", a
# DIRECTORY, and passes. The spawn then ran "$HOME/.local/bin/; exec bash" -- a
# shell error and a bare bash pane wearing a live session's name, i.e. the
# zombie pane this file has a whole repair path for.
#
# So the library is measured by what it DEFINES. The three names are the entire
# contract this file has with lib/mcprender.sh and lib/mcpspawn.sh.
if [ -z "$_mcp_lib_missing" ]; then
  for _c in mcp_spawn_prepare mcp_claude_cmd_fragment mcp_render_document; do
    declare -F "$_c" >/dev/null 2>&1 || \
      _mcp_lib_missing="$_MCP_LIB_DIR -- what is deployed there does not define $_c"
  done
fi
_STATE_NAME=""; _PAUSED_NAME=""
if [ -n "$_reg_ok" ]; then
  _STATE_NAME="$(registry_state_dir_name 2>/dev/null || true)"
  _PAUSED_NAME="$(registry_paused_dir_name 2>/dev/null || true)"
fi
STATE_DIR="$HOME/.local/state/${_STATE_NAME:-.}"
[ -n "$_STATE_NAME" ] && mkdir -p "$STATE_DIR"
SUSPECT="$STATE_DIR/$NAME.suspect"
RESUME_TRY="$STATE_DIR/$NAME.resume-try"
# THE LAST CONFIRMED-ALIVE SID AND THE LAUNCH MARK (ported from the macOS twin
# 2026-08-31). The macOS supervisor holds in the foreground and notes the held
# sid in-process once the session has provably survived; this supervisor is a
# one-shot timer, so the start round writes WHAT IT LAUNCHED to the launch
# mark, and the next round that finds the session alive turns that into
# last-sid (or clears last-sid after a fresh start). Same state directory,
# same file shapes as the twin.
LAST_SID_FILE="$STATE_DIR/$NAME.last-sid"
LAUNCH_MARK="$STATE_DIR/$NAME.launched"
# THE AUTO-RENAME CYCLE'S TRACE FILE (measured 2026-08-31): the app tile's
# name is FROZEN at registration — --name at start never renames an existing
# entity, and a restart reattaches under the stale name. The only rename
# mechanism is /rename typed into the live session, verified by the receipt
# line "Session renamed to: <name>" in the pane; no receipt means not renamed.
# spawn_session writes this file (<attempts> <label>); ONLY a verified receipt
# clears it. While it exists, later rounds keep driving the rename — and a
# file that stays behind is the trace that the tile may carry a stale name.
RENAME_PENDING="$STATE_DIR/$NAME.rename-pending"
# THE DEGRADED-MCP ALARM'S DEDUP MARKER, the same shape as the unacked-mail one
# below: it holds the KEY of the degradation last delivered to the hub, and is
# written only on a receipt. A crash-looping session is respawned by this
# supervisor every few rounds, and the alarm sits on the spawn path -- so
# without this file the identical sentence about the identical missing asset
# went out on every respawn, which is the "four times an hour" harm the alarm's
# own comment names. The key is the rc plus the render's own words, so a set
# that degrades FURTHER (a second asset gone, or rc 1 becoming rc 2) is news
# and alarms anew, while a spawn whose set is healthy clears the marker -- a
# marker that outlives its condition silences the next real alarm.
MCP_MARK="$STATE_DIR/$NAME.mcp-signalled"
if [ -n "$_PAUSED_NAME" ] && [ -f "$HOME/.local/state/$_PAUSED_NAME/$NAME" ]; then
  rm -f "$SUSPECT"
  exit 0
fi

# ── THE ESTATE'S RC PREFIX, NOT A LITERAL ──────────────────────────────────
# The label was a literal in the code until 2026-08-20. It carried the estate's
# name, and the product cannot own a file that does. The value now comes from
# estate/steward.conf via registry.sh — UNCHANGED value, measured against
# eleven live processes on the session host before the switch.
#
# REFUSAL, NOT GUESSING, and the reason is harder here than in the other two
# files: the label is used in TWO places — to build the claude command AND to
# decide whether the session is alive. A guessed prefix that does not match the
# live command makes supervision judge every session dead and enter its repair
# path, which WRITES into ongoing conversations. Better a failed timer.
#
# AFTER the pause guard on purpose: a paused session must exit 0 without asking
# anything about HOW it would have been started (#112). The suite has a control
# group for exactly that order.
#
# THE REFUSALS FOR THE ESTATE VALUES ARE GATHERED HERE, after the pause guard.
# The library was loaded higher up so the pause guard could look up its
# directory; what must NOT happen there was the refusal.
if [ -z "$_reg_ok" ]; then
  echo "session-supervisor: $NAME — REFUSING: the registry library is missing or could not be read ($REG_LIB)." >&2
  exit 78
fi
if [ -z "$_STATE_NAME" ] || [ -z "$_PAUSED_NAME" ]; then
  echo "session-supervisor: $NAME — REFUSING: the estate lacks STATE_DIR_NAME or PAUSED_DIR_NAME." >&2
  echo "session-supervisor: $NAME — without them the supervisor's state would be guessed, and a paused" >&2
  echo "session-supervisor: $NAME — session would have been restarted although someone shut it down." >&2
  exit 78
fi
RC_PREFIX="$(registry_rc_label_prefix)" || exit 78
# THE HUB'S NAME COMES FROM THE ESTATE, as in session-new and session-approve.
# A literal here would have sent every auto-alert to a recipient that may not
# exist.
NAV="$(registry_hub_session)" || exit 78
# THE PING TEXT COMES FROM THE ESTATE TOO. It is a constant that is COMPARED
# EXACTLY elsewhere on the bus, and it is instruction text every live session
# has been told to act on — a literal here (in any language) would drift from
# the value the fleet recognizes. Same refusal as the other estate values;
# a guessed ping is a keystroke into a live pane.
PING_MSG="$(registry_ping_msg)" || exit 78

# ── THE SOCKET IS THE ESTATE'S, NEVER A BARE DEFAULT ───────────────────────
# MEASURED ON wise-lynx 2026-08-30: this file's tmux calls carried no -S at
# all, so every one of them talked to the bare default socket
# (/tmp/tmux-1001/default) while the rest of the product — install's own
# verification, doctor's derivation, the cockpit's attach — agrees the
# estate's sessions live on ~/.tmux/<TMUX_SOCKET from estate/steward.conf>.
# driftwood-hub started on the wrong socket while doctor and the cockpit both
# aimed at ~/.tmux/driftwood.sock: the product's own layers disagreed about
# where the session lives, and nothing here ever saw the pane it thought it
# was supervising.
#
# STEWARD_TMUX_SOCKET — a full path, the same variable and precedence the
# cockpit's _resolve_socket and the hub's bus_tmux_sock already use — wins
# untouched when set. Otherwise the estate's own declared TMUX_SOCKET,
# resolved under ~/.tmux/, and NEVER a guessed or bare default: a supervisor
# that guesses a socket writes keystrokes toward the wrong universe, which is
# the exact sin the cockpit refuses to commit.
if [ -n "${STEWARD_TMUX_SOCKET:-}" ]; then
  SOCK="$STEWARD_TMUX_SOCKET"
else
  _sock_name="$(registry_tmux_socket)" || {
    echo "session-supervisor: $NAME — REFUSING: TMUX_SOCKET is missing or invalid in the estate ($(registry_estate_file 2>/dev/null))." >&2
    exit 78
  }
  SOCK="$HOME/.tmux/$_sock_name"
fi
mkdir -p "$HOME/.tmux"
# ONE WRAPPER, EVERY CALL THROUGH IT. No bare `tmux` may remain in this file
# outside this function — everything below talks to the socket resolved
# above, never to whatever server happens to be listening on the default path.
tmuxc() { command tmux -S "$SOCK" "$@"; }

# THE REPO IS READ FROM THE REGISTRY, not from an assumed path. The unit
# hardcoded %h/Projects/%i, which held as long as every session had a repo named
# after the session. One session broke it: its workspace is
# ~/Projects/<x>/<x>-claude while ~/Projects/<x> is a container of sibling
# repos. A session rooted at the container finds neither CLAUDE.md nor
# .mcp.json (2026-08-06).
#
# The second argument still wins, so old calls work unchanged.
# THE CONF IS ALWAYS SOURCED, not only when REPO is missing. The sourcing used
# to sit INSIDE `if [ -z "$REPO" ]`, so a call with two arguments skipped it —
# and then DOMAIN is unset all the way down to CRED_HOME below, which THEN fell
# back to the session name. The consequence: the session SILENTLY got a private
# credential directory under its session name instead of the domain's shared
# one, and the first symptom is that tools ask for login again in a single
# session while everything else looks healthy. (One session found the variant
# 2026-08-14 while narrowing its own proposal — it saw that the damage it
# nearly caused by accident was already the normal outcome for an incomplete
# conf.)
# THE CONF COMES FROM THE ESTATE'S ROOT, not a fixed path. This was
# "$HOME/scripts/sessions.d/$NAME.conf", so supervision could only ever see ONE
# estate: a session registered in a second estate on the same account was
# invisible, and the refusal below named "no conf" while the conf existed one
# directory away. A refusal pointing at the wrong cause is the failure shape this
# whole file is built against. Deployed, the root resolves to the same directory
# as before, so nothing about an existing installation changes.
CONF="$(registry_dir)/$NAME.conf"
# REFUSAL, NOT A WARNING. Until 2026-08-15 both cases below warned to stderr
# and continued with rc 0 — a session without a conf silently got a private
# credential directory and looked healthy all the way. One session dry-ran
# exactly that during an enrollment incident and showed that
# `systemctl enable --now` on an unknown name had spawned a misconfigured
# session with a green outcome. Supervision is the last link in the activation
# path; a green outcome from here must mean something.
# rc 78 (EX_CONFIG) makes the systemd unit show as failed instead of the error
# hiding inside a live but broken session.
# LOGIN IS RESET BEFORE THE SOURCE, unlike every other field this file reads
# from the conf. Review finding 2 (task 6, round 1): this file sources the
# conf straight into its own shell, with no reset comparable to the macOS
# twin's registry_load (whose reset line clears LOGIN="" before it sources
# anything). Without this line an exported ambient LOGIN in the supervisor's
# own environment is read exactly as if the conf had declared it -- a session
# silently launched against another login's credential directory, with no
# line in the conf a reader could have caught.
LOGIN=""
if [ -f "$CONF" ]; then
  # shellcheck source=/dev/null
  . "$CONF"
else
  echo "session-supervisor: $NAME — REFUSING: no conf at $CONF." >&2
  echo "session-supervisor: $NAME — a session without a registry entry must not be started: the credential" >&2
  echo "session-supervisor: $NAME — directory would have become private instead of the domain's shared one." >&2
  echo "session-supervisor: $NAME — register the session first (bash ~/scripts/session-new.sh)." >&2
  exit 78
fi
# THE ONE DISPATCH WORD (E1). A claude-code row is supervised through the bridge adapter's
# answer; every other runtime keeps today's path, verbatim. Set here, right after the conf,
# so no branch below can read RUNTIME two different ways.
case "${RUNTIME:-claude-code}" in claude-code) IS_CLAUDE=1 ;; *) IS_CLAUDE="" ;; esac
NO_PROCESS_CONFIRMED=""; NP_TUPLE=""
# THE BRIDGE LIBRARY, FOR CLAUDE ROWS ONLY, PROBED IN A SUBSHELL FIRST: a syntax error in a sourced
# file is fatal to a non-interactive shell, so the probe takes the hit and this shell sources only a
# file that has already been shown to load. The refusal itself is below (after the pause guard and
# CFG_ROOT), so a paused row is never asked anything.
if [ "$IS_CLAUDE" = 1 ] && [ -f "$BRIDGE_LIB" ] && ( . "$BRIDGE_LIB" ) >/dev/null 2>&1; then
  # shellcheck source=/dev/null
  . "$BRIDGE_LIB" 2>/dev/null && declare -F bridge_answer >/dev/null 2>&1 && _bridge_ok=1
fi

# THE LIBRARY VALIDATES WHAT THE RAW SOURCE ABOVE ONLY READS.
#
# MEASURED 2026-08-31: this file called registry_load zero times, so every gate
# that lives in that loader — the schema gate, the LOGIN requirement, the field
# validation — was inert on this platform. The estate's most populated host was
# the one host where none of them applied.
#
# ADDITIVE, NOT A REPLACEMENT. The raw source and the sed-based RC_LABEL read
# stay exactly as they are: they distinguish an EMPTY RC_LABEL line from a
# MISSING one, which is the difference between a deliberate RC-free session and
# a forgotten label, and `source` destroys it. registry_load is asked for its
# VERDICT, not for its values.
#
# SUBSHELLED, so the loader's own globals never overwrite what the raw source
# just put in this shell — this file reads REPO/DOMAIN/LOGIN from the conf
# itself, and registry_load sets the same names.
if ! ( registry_load "$NAME" >/dev/null 2>&1 ); then
  echo "session-supervisor: $NAME — REFUSING: the registry library will not load this row." >&2
  # Captured into a variable rather than piped straight to sed: $NAME is not
  # shape-validated anywhere in this file, and interpolating it into a sed
  # replacement would let a conf name containing & \ or / corrupt or break the
  # relayed text. A plain read loop has no such hazard.
  _reg_relay="$( registry_load "$NAME" 2>&1 >/dev/null )"
  if [ -n "$_reg_relay" ]; then
    printf '%s\n' "$_reg_relay" | while IFS= read -r _reg_relay_line; do
      printf 'session-supervisor: %s — %s\n' "$NAME" "$_reg_relay_line" >&2
    done
  else
    echo "session-supervisor: $NAME — the library gave no reason; run \`registry_load $NAME\` by hand to see it." >&2
  fi
  echo "session-supervisor: $NAME — nothing is started. A row the library refuses is a row" >&2
  echo "session-supervisor: $NAME — whose meaning this supervisor cannot be sure of." >&2
  exit 78
fi

if [ -z "${DOMAIN:-}" ]; then
  echo "session-supervisor: $NAME — REFUSING: DOMAIN is missing from the conf ($CONF)." >&2
  echo "session-supervisor: $NAME — without DOMAIN the credential directory falls back to" >&2
  echo "session-supervisor: $NAME — the session name, and that must never be reached. Set DOMAIN." >&2
  exit 78
fi
REPO="${2:-${REPO_PATH:-$HOME/Projects/$NAME}}"
[ -d "$REPO" ] || { echo "session-supervisor: $NAME is missing repo $REPO" >&2; exit 78; }

# --continue ONLY IF THERE IS SOMETHING TO RESUME. A brand-new session has no
# history, and `claude --continue` then answers "No conversation found to
# continue" and EXITS immediately. Supervision restarted it every third minute
# for all eternity, and every attempt died within a second.
#
# That is how one session failed at its first setup 2026-08-06 — and worse: I
# measured the process in the gap between start and death, saw it alive, and
# reported the session as running. A measurement that happens to land in a
# momentary window proves nothing.
#
# Claude Code stores conversations per project path with / replaced by -.
# The munge is EVERY non-alphanumeric character, not just the slash. Measured
# on a real checkout: a repo path with a dot maps to a directory where the dot
# is also a dash. With slash-only munging the lookup globs an empty directory
# for any dotted repo path and silently forks a fresh thread on every respawn.
# THE HISTORY ROOT FOLLOWS THE LOGIN. It was $HOME/.claude/projects/... until
# 2026-08-31. A session that changes model account while keeping the path looks
# in the WRONG account's history -- and this selector falls OPEN to a fresh
# start, so it forks a new thread SILENTLY. The session lives, answers, and has
# lost its conversation.
#
# WITHOUT A LOGIN IT IS ~/.claude, unchanged. A branch that moved the directory
# for everyone would have dropped every existing session's history at once.
CFG_ROOT="$HOME/.claude"
if [ -n "${LOGIN:-}" ]; then
  CFG_ROOT="$(registry_login_config_dir "$LOGIN" "$(id -un)")" || exit 78
fi
# ---- the bridge path: one adapter that measures, one pin that signals, one claim per spawn ----
# THE ADAPTER IS READ-ONLY AND THIS FILE OWNS EVERY WRITE (spec §1). linux/bridge-observe.sh
# prints one fifteen-field line; observe_row reads it by position into B_*. bridge-kill.py pins
# the process before it signals. Both sit beside this script, deployed or in a checkout.
OBSERVE="${STEWARD_BRIDGE_OBSERVE:-$(dirname "$0")/bridge-observe.sh}"
BKILL="${STEWARD_BRIDGE_KILL:-$(dirname "$0")/bridge-kill.py}"
PROCR="${BRIDGE_PROC_ROOT:-/proc}"
if [ "$IS_CLAUDE" = 1 ]; then
  if [ "$_bridge_ok" != 1 ]; then
    echo "session-supervisor: $NAME — REFUSING: $BRIDGE_LIB does not define bridge_answer; a claude row cannot be identified without it." >&2
    echo "session-supervisor: $NAME — deploy the product's lib/ to $(dirname "$REG_LIB"). Nothing is started, nothing is closed." >&2
    exit 78
  fi
  if [ ! -f "$OBSERVE" ]; then
    echo "session-supervisor: $NAME — REFUSING: the bridge observer is missing: $OBSERVE" >&2
    exit 78
  fi
fi
B_ANS=""; B_PID=""; B_BIRTH=""; B_PANE=""; B_NAME=""; B_SINCE=""; B_GEN=""; B_CLASSES=""; B_CHILD=""; B_PS=""; B_SID=""; B_MTIME=""; B_TUPLE=""; B_INODE=""
observe_row() {
  local _l _id=""
  _l="$(STEWARD_STATE_DIR="$STATE_DIR" STEWARD_TMUX_SOCKET="$SOCK" STEWARD_REGISTRY_LIB="$REG_LIB" STEWARD_BRIDGE_LIB="$BRIDGE_LIB" bash "$OBSERVE" "$NAME")" || _l=""
  IFS="$US" read -r _id B_ANS B_PID B_BIRTH B_PANE B_NAME B_SINCE B_GEN B_CLASSES B_CHILD B_PS B_SID B_MTIME B_TUPLE B_INODE <<EOF
$_l
EOF
  observe_line_valid "$_l" "$_id" || {
    # AN UNREADABLE ANSWER IS unknown, NEVER no-process: nothing below may act on it (H4).
    B_ANS="unknown"; B_GEN="none"; B_CLASSES="observer-unreadable"; B_PID=""; B_BIRTH=""; B_PANE=""; B_NAME=""; B_SINCE=""; B_CHILD=""; B_PS=""; B_SID=""; B_MTIME=""; B_TUPLE=""; B_INODE=""
  }
}
# observe_line_valid <line> <id> - THE shared validator (lib/bridge.sh bridge_line_valid, K3-K6): one line,
# fifteen fields, this row's id, closed vocabularies and the pairs the adapter can emit, typed identified
# fields and the EXACT pane. The B_* the round reads are the validated BL_*.
observe_line_valid() {
  bridge_line_valid "$1" "$NAME" || return 1
  B_ANS="$BL_ANS"; B_PID="$BL_PID"; B_BIRTH="$BL_BIRTH"; B_PANE="$BL_PANE"; B_NAME="$BL_NAME"; B_SINCE="$BL_SINCE"; B_GEN="$BL_GEN"; B_CLASSES="$BL_CLASSES"; B_CHILD="$BL_CHILD"; B_PS="$BL_PS"; B_SID="$BL_SID"; B_MTIME="$BL_MTIME"; B_TUPLE="$BL_TUPLE"; B_INODE="$BL_INODE"
  return 0
}
# runtime_identified: the alive question, asked the runtime's own way (E2).
runtime_identified() {
  if [ "$IS_CLAUDE" = 1 ]; then observe_row; [ "$B_ANS" = identified:managed ]; else claude_alive_in_session; fi
}
# bind_generation: a verified-live bridge record becomes the generation's current fact, so a
# file left behind by KILL -9 is later recognised by pid:procStart. Written only on change.
bind_generation() { # rc 1 when the record could not be written - the caller must not go on writing; rc 2 on a contradiction
  local g_uid g_pid g_birth g_ps; g_uid="$(id -u)"
  g_pid="$(bridge_gen_get "$STATE_DIR" "$NAME" pid 2>/dev/null)"; g_birth="$(bridge_gen_get "$STATE_DIR" "$NAME" birth 2>/dev/null)"; g_ps="$(bridge_gen_get "$STATE_DIR" "$NAME" procStart 2>/dev/null)"
  # A CONTRADICTION IS NEVER REBOUND (spec §1, K4): the same pid and OS birth with another vendor
  # procStart is two stories about one process; the generation keeps the first, the row is degraded.
  if [ "$g_pid" = "$B_PID" ] && [ "$g_birth" = "$B_BIRTH" ] && [ -n "$g_ps" ] && [ -n "$B_PS" ] && [ "$g_ps" != "$B_PS" ]; then
    [ -f "$STATE_DIR/$NAME.identity-degraded" ] || { touch "$STATE_DIR/$NAME.identity-degraded"; echo "session-supervisor: $NAME — DEGRADED: pid $B_PID (birth $B_BIRTH) now reports procStart $B_PS, the generation recorded $g_ps. A contradiction is not rebound." >&2; }
    return 2
  fi
  rm -f "$STATE_DIR/$NAME.identity-degraded"
  if [ "$(bridge_gen_get "$STATE_DIR" "$NAME" pid 2>/dev/null)" != "$B_PID" ] || [ "$(bridge_gen_get "$STATE_DIR" "$NAME" birth 2>/dev/null)" != "$B_BIRTH" ] \
     || [ "$(bridge_gen_get "$STATE_DIR" "$NAME" procStart 2>/dev/null)" != "$B_PS" ] || [ "$(bridge_gen_get "$STATE_DIR" "$NAME" sessionId 2>/dev/null)" != "$B_SID" ] \
     || [ "$(bridge_gen_get "$STATE_DIR" "$NAME" uid 2>/dev/null)" != "$g_uid" ] || [ "$(bridge_gen_get "$STATE_DIR" "$NAME" bridge_nameSince 2>/dev/null)" != "$B_SINCE" ] \
     || [ "$(bridge_gen_get "$STATE_DIR" "$NAME" bridge_inode 2>/dev/null)" != "$B_INODE" ] \
     || [ "$(bridge_gen_get "$STATE_DIR" "$NAME" bridge_name 2>/dev/null)" != "$B_NAME" ] || [ "$(bridge_gen_get "$STATE_DIR" "$NAME" bridge_mtime 2>/dev/null)" != "$B_MTIME" ] \
     || [ -n "$(bridge_gen_get "$STATE_DIR" "$NAME" spawn_state 2>/dev/null)" ]; then
    bridge_gen_write "$STATE_DIR" "$NAME" pid="$B_PID" birth="$B_BIRTH" procStart="$B_PS" sessionId="$B_SID" bridge_mtime="$B_MTIME" bridge_inode="$B_INODE" \
      bridge_name="$B_NAME" bridge_nameSince="$B_SINCE" uid="$g_uid" spawn_state= || return 1
  fi
  return 0
}
# reobserve_same <answer> <key> - the action-boundary re-observation (H1): the adapter is asked again
# immediately before an action and must give the SAME answer and the SAME action key; anything else
# resets the suspect and ends the round. Prints the reason on stderr and returns 1 on any difference.
reobserve_same() {
  local want_ans="$1" want_key="$2" got_key
  observe_row
  case "$want_key" in
    "reap "*)  got_key="$(bridge_suspect_key reap "$B_PID" "$B_BIRTH")" ;;
    "close "*) got_key="$(bridge_suspect_key close "$B_TUPLE")" ;;
    *)         got_key="$(bridge_suspect_key spawn absent)"; [ -z "$B_TUPLE" ] || got_key="(tuple present)" ;;
  esac
  if [ "$B_ANS" = "$want_ans" ] && [ "$got_key" = "$want_key" ]; then return 0; fi
  rm -f "$SUSPECT"
  echo "session-supervisor: $NAME — the re-observation before the action differs ($B_ANS, $got_key; wanted $want_ans, $want_key); resetting, nothing done." >&2
  return 1
}
_steward_nonce() { od -An -N16 -tx1 /dev/urandom 2>/dev/null | tr -d ' \n'; }
# ---- THE HOST GATE OF SPEC §3 (plan Task 9b) ----------------------------------------------------
# host_display_reserved <desired> - prints the id of another row on THIS host, under the SAME login key,
# that holds <desired>; rc 0 reserved, rc 1 free.
#
# WHAT HOLDS A DISPLAY IS A LIVE BRIDGE FILE (spec §3; advisor M3), not a generation's pid: a process we
# launched but that never registered holds no tile, and a row whose generation is stale holds nothing at
# all. So each candidate is ASKED - the adapter's `identified:*` is the proof that a bridge file exists -
# and only then are its reported name and its generation's applied/pending compared.
#
# THE KEY IS THE SAME ONE THE REGISTRY GATE USES (M1): two logins have two tile lists, and a pair the
# registry allows must not be blocked here. A row of another OWNER on this host cannot be asked at all
# (its home is 0750): under STEWARD_RESERVATION_STRICT=1 a colliding rendered display is refused - manual
# census - otherwise it is named once and the write proceeds.
MY_LOGIN_KEY="$(registry_session_login_key "${LOGIN:-}" "${OWNER:-}" "${HOST:-}" 2>/dev/null)"
host_display_reserved() {
  local desired="$1" n f_owner f_host f_rt f_fri f_lc f_key line applied pending
  [ -n "$desired" ] || return 1
  [ -n "$MY_LOGIN_KEY" ] || return 1
  for n in $(registry_list 2>/dev/null); do
    [ "$n" = "$NAME" ] && continue
    # The row's own words first, in a subshell: a conf cannot reach this shell's names.
    # THE UNIX USER OF A ROW IS ITS ACCOUNT'S USERNAME, not its OWNER field - OWNER may be the principal,
    # which is a person, not a login on this machine. The adapter resolves it the same way.
    local snap; snap="$( registry_load "$n" >/dev/null 2>&1 || exit 1
                         _u="$OWNER"; [ -z "${ACCOUNT:-}" ] || { registry_account_load "$ACCOUNT" >/dev/null 2>&1 && _u="$ACCOUNT_USERNAME"; }
                         printf '%s\n%s\n%s\n%s\n%s\n%s\n%s' "${RUNTIME:-claude-code}" "${LIFECYCLE:-active}" "${RC_FRI:-}" "${LOGIN:-}" "${OWNER:-}" "${HOST:-}" "$_u" )" || continue
    f_rt="${snap%%$'\n'*}"; snap="${snap#*$'\n'}"; f_lc="${snap%%$'\n'*}"; snap="${snap#*$'\n'}"
    f_fri="${snap%%$'\n'*}"; snap="${snap#*$'\n'}"; local f_login="${snap%%$'\n'*}"; snap="${snap#*$'\n'}"
    f_owner="${snap%%$'\n'*}"; snap="${snap#*$'\n'}"; f_host="${snap%%$'\n'*}"; snap="${snap#*$'\n'}"; local f_user="${snap}"
    [ "$f_rt" = claude-code ] || continue
    [ "$f_lc" != retired ] || continue
    [ "$f_fri" != yes ] || continue
    [ "${f_host:-}" = "${STEWARD_SELF_HOST:-$(hostname -s)}" ] || continue     # the host gate is local
    f_key="$(registry_session_login_key "$f_login" "$f_owner" "$f_host")"
    [ "$f_key" = "$MY_LOGIN_KEY" ] || continue
    if [ "${f_user:-$f_owner}" != "$(id -un)" ]; then
      # UNINSPECTABLE: another owner's home cannot be read from here, so the only thing we can compare is
      # what the register says that row RENDERS - a static fact, not a live one.
      local disp; disp="$(registry_session_display "$n" 2>/dev/null)" || continue
      [ "$disp" = "$desired" ] || continue
      if [ "${STEWARD_RESERVATION_STRICT:-}" = 1 ]; then
        echo "session-supervisor: $NAME — the display '$desired' is also rendered by '$n' (owner $f_owner) on this host; that home is uninspectable from here - MANUAL CENSUS REQUIRED (STEWARD_RESERVATION_STRICT=1)." >&2
        printf '%s\n' "$n"; return 0
      fi
      [ -n "${_host_gate_foreign_said:-}" ] || echo "session-supervisor: $NAME — note: '$desired' is also rendered by '$n' (owner $f_owner) on this host; uninspectable from here, not refused (set STEWARD_RESERVATION_STRICT=1 to refuse)." >&2
      _host_gate_foreign_said=1
      continue
    fi
    # OURS TO ASK. identified:* proves a live bridge file; anything else holds no tile.
    line="$(STEWARD_STATE_DIR="$STATE_DIR" STEWARD_TMUX_SOCKET="$SOCK" STEWARD_REGISTRY_LIB="$REG_LIB" STEWARD_BRIDGE_LIB="$BRIDGE_LIB" bash "$OBSERVE" "$n" 2>/dev/null)" || continue
    bridge_line_valid "$line" "$n" || continue
    case "$BL_ANS" in identified:*) : ;; *) continue ;; esac
    applied="$(bridge_gen_get "$STATE_DIR" "$n" applied 2>/dev/null)"; pending="$(bridge_gen_get "$STATE_DIR" "$n" pending_for 2>/dev/null)"
    if [ "$BL_NAME" = "$desired" ] || [ "$applied" = "$desired" ] || [ "$pending" = "$desired" ]; then
      printf '%s\n' "$n"; return 0
    fi
  done
  return 1
}

# ---- the critical section (advisor M4) -----------------------------------------------------------
# A gate that checks and then writes in two steps is not a reservation: two supervisors can both see a
# display free and both take it. The check and the write it authorises run under one host-wide lock -
# a directory, because mkdir is atomic on every filesystem this runs on - and the lock is RE-ENTRANT so
# a path that gates and then calls spawn_session (which gates again) cannot deadlock against itself.
HOST_GATE_LOCK="$STATE_DIR/.display-reservation.lock"
HOST_GATE_DEPTH=0
HOST_GATE_STALE_SEC="${STEWARD_RESERVATION_STALE_SEC:-120}"
host_gate_lock() { # rc 0 held (by us), rc 1 ANOTHER supervisor holds it, rc 2 no lock is possible here
  [ "$HOST_GATE_DEPTH" -gt 0 ] && { HOST_GATE_DEPTH=$((HOST_GATE_DEPTH+1)); return 0; }
  local age now
  if ! mkdir "$HOST_GATE_LOCK" 2>/dev/null; then
    # A LOCK THAT DOES NOT EXIST AND CANNOT BE CREATED IS NOT CONTENTION - it is a state directory this
    # process cannot write. Saying "another supervisor holds it" there would be a confident false
    # diagnosis; and nothing can be reserved anyway, because every write below fails on the same
    # directory. Proceed unlocked and let those writes refuse with their own reason.
    if [ ! -d "$HOST_GATE_LOCK" ]; then
      echo "session-supervisor: $NAME — the display reservation lock cannot be created in $STATE_DIR; proceeding unlocked (every write below fails on the same directory)." >&2
      return 2
    fi
    now="$(date +%s)"; age="$(_mtime_of "$HOST_GATE_LOCK")"
    if _is_epoch "$age" && _is_epoch "$now" && [ $((now - age)) -ge "$HOST_GATE_STALE_SEC" ]; then
      echo "session-supervisor: $NAME — the display reservation lock is $((now - age))s old (limit ${HOST_GATE_STALE_SEC}s); breaking it." >&2
      rmdir "$HOST_GATE_LOCK" 2>/dev/null
      mkdir "$HOST_GATE_LOCK" 2>/dev/null || return 1
    else
      return 1
    fi
  fi
  HOST_GATE_DEPTH=1
  return 0
}
host_gate_unlock() {
  [ "$HOST_GATE_DEPTH" -gt 0 ] || return 0
  HOST_GATE_DEPTH=$((HOST_GATE_DEPTH-1))
  [ "$HOST_GATE_DEPTH" -eq 0 ] && rmdir "$HOST_GATE_LOCK" 2>/dev/null
  return 0
}

# host_gate_refuses <desired> <where> - the gate applied with its alarm-once marker; rc 0 when the write
# must NOT happen (reserved), rc 1 when it may. The marker (.display-reserved) is cleared when free.
host_gate_refuses() {
  local desired="$1" where="$2" holder
  if holder="$(host_display_reserved "$desired")"; then
    if [ ! -f "$STATE_DIR/$NAME.display-reserved" ] || [ "$(cat "$STATE_DIR/$NAME.display-reserved" 2>/dev/null)" != "$holder" ]; then
      printf '%s\n' "$holder" > "$STATE_DIR/$NAME.display-reserved"
      echo "session-supervisor: $NAME — REFUSING to $where: the display '$desired' is reserved on this host by the live row '$holder' (spec §3 host gate). Nothing written; retire or rename '$holder' first." >&2
    fi
    return 0
  fi
  rm -f "$STATE_DIR/$NAME.display-reserved"
  return 1
}
# spawn_claude_claimed (D7): the claim is written BEFORE new-session and closed AFTER, and every
# input is validated before a byte is written - a claim that cannot be written is a failed spawn,
# never a launch with a hole in its proof.
_claim_fail() { # <why> - close the claim as failed; the launch never happens
  bridge_gen_write "$STATE_DIR" "$NAME" spawn_state="failed:$(date +%s)" launch_nonce= launch_ms= launch_uptime_ms= launch_boot_id= launch_inodes= || true
  echo "session-supervisor: $NAME — REFUSING to spawn: $1. DEGRADED: nothing started." >&2
  return 1
}
# claude_claim_open (D7, H3, H7): every input is read as TEXT and validated, then the pending claim is
# written - and only a SUCCESSFUL write opens the claim. Nothing else about the spawn (attempt counters,
# marks, the launch) may happen before this returned 0.
CLAIM_NONCE=""
claude_claim_open() {
  local nonce wall up boot inodes f i
  nonce="$(${STEWARD_NONCE_CMD:-_steward_nonce} 2>/dev/null)"
  [ "${#nonce}" -eq 32 ] || nonce=""; case "$nonce" in *[!0-9a-f]*) nonce="" ;; esac
  wall="$(date +%s 2>/dev/null)"; case "$wall" in ''|*[!0-9]*) wall="" ;; *) wall="${wall}000" ;; esac
  up="$(awk '{printf "%d", $1*1000}' "$PROCR/uptime" 2>/dev/null)"; case "$up" in ''|*[!0-9]*) up="" ;; esac
  boot="$(cat "$PROCR/sys/kernel/random/boot_id" 2>/dev/null)"; case "$boot" in ''|*[!0-9A-Za-z-]*) boot="" ;; esac   # compared for equality only; one token, no spaces
  [ -n "$nonce" ] && [ -n "$wall" ] && [ -n "$up" ] && [ -n "$boot" ] \
    || { _claim_fail "the launch claim cannot be written (nonce ${nonce:-invalid}, wall ${wall:-unreadable}, uptime ${up:-unreadable}, boot id ${boot:-unreadable})"; return 1; }
  inodes=""
  for f in "$CFG_ROOT"/sessions/*.json; do
    [ -e "$f" ] || continue
    i="$(stat -c %i "$f" 2>/dev/null || stat -f %i "$f" 2>/dev/null)"; case "$i" in ''|*[!0-9]*) _claim_fail "the inode of $f cannot be read for the snapshot"; return 1 ;; esac
    inodes="$inodes $i"
  done
  inodes="${inodes# }"
  # THE CLAIM RESERVES THE DISPLAY (M4): between this write and the first observation of the new process
  # there is no bridge file to hold the name, so the claim holds it - pending_for is what the host gate
  # of another row reads. pending_since is left empty on purpose: the rename cycle seeds it from the
  # first observation of the process that is about to exist.
  bridge_gen_write "$STATE_DIR" "$NAME" launch_ms="$wall" launch_uptime_ms="$up" launch_boot_id="$boot" launch_nonce="$nonce" launch_inodes="$inodes" spawn_state=pending pid= birth= procStart= stop_receipt= pending_for="${RC_LABEL:-}" pending_since= \
    || { echo "session-supervisor: $NAME — REFUSING to spawn: the pending claim could not be written to $STATE_DIR. DEGRADED: nothing started." >&2; return 1; }
  CLAIM_NONCE="$nonce"
  return 0
}
# claude_claim_launch: new-session under the open claim, then the claim closed - started or failed.
claude_claim_launch() {
  local pane_pid pbirth="" rc
  # THE NONCE RIDES IN FRONT OF claude AS AN ENVIRONMENT ASSIGNMENT, never behind the ';' -
  # the fallback shell must not inherit it (measured P1: it does not).
  pane_pid="$(tmuxc new-session -d -P -F '#{pane_pid}' -s "$NAME" -c "$REPO" "${CRED_ENV_ARGS[@]}" \
      "STEWARD_LAUNCH_NONCE=$CLAIM_NONCE ${LOGIN_PREFIX}$HOME/.local/bin/$CLAUDE_CMD; exec bash")"; rc=$?
  case "$pane_pid" in ''|*[!0-9]*) pane_pid="" ;; esac
  if [ "$rc" -eq 0 ] && [ -n "$pane_pid" ] && pbirth="$(bridge_os_birth "$pane_pid")" && [ -n "$pbirth" ]; then
    if bridge_gen_write "$STATE_DIR" "$NAME" launch_pane_pid="$pane_pid" launch_pane_birth="$pbirth" spawn_state=started; then return 0; fi
    echo "session-supervisor: $NAME — the session started but the claim could not be recorded as started; the launch child will be judged by its nonce alone. DEGRADED." >&2
    return 0
  fi
  _claim_fail "new-session did not verifiably start (rc $rc, pane pid ${pane_pid:-none}); the claim is closed"
  return 1
}
HIST="$CFG_ROOT/projects/$(printf '%s' "$REPO" | sed 's|[^a-zA-Z0-9]|-|g')"
# STATE_DIR/SUSPECT/RESUME_TRY are set at the top, at the pause check — they
# derive from $HOME and $NAME and had to move there together with it.

# --resume <id>, NOT --continue. The difference is not cosmetic: --continue
# created a NEW conversation file during one session's migration 2026-08-06
# even though history existed, while an explicit session id resumed the right
# thread (measured: the file grew from 700 kB to 2.2 MB instead of an empty one
# being created beside it).
#
# That session's rationale for why this outranks the cosmetic: "A bug in your
# own tool that creates silent forks is worse than a broken MCP server. The
# server speaks up; the fork looks like a normal new session."
#
# The thread is chosen as the MOST RECENTLY TOUCHED .jsonl file in the project
# directory; the filename's stem IS the session id.
CONT=""
SID=""

# THE THREAD IS CHOSEN BY CONTENT, NOT BY THE FILESYSTEM. The first version
# took the most recently touched file — one session tore that heuristic apart
# immediately:
#
#   "An mtime that comes from another machine is not a claim about this
#    machine's history."
#
# The migrated file carries mtime 2026-08-06 10:26 because the COPY preserved
# the laptop's timestamp, not because anything happened on this host then. Had
# the migration been done an hour later than the session's last activity, the
# mtime choice would have pointed at the wrong thread with full confidence —
# and the result would have been a silent fork, i.e. precisely what this code
# exists to prevent.
#
# The lines' own timestamp fields are machine-independent. Files without a
# timestamp (e.g. a migrated file's "last-prompt" entry) sort last instead of
# being guessed.
#
# CLASS BEFORE TIME. Measured 2026-08-31 on three live sessions at once: the
# project directory holds BOTH the long-lived human conversation AND the short
# job/automation threads, and jobs run on a schedule — so the job thread is
# almost always the newest one. Newest-by-content therefore picked the WRONG
# thread reliably rather than occasionally, and the session went on answering
# in the job own format for its own errand. The chooser now prints TWO lines:
# the class ("human"/"job") and the path.
#
# THE LAST HELD SID IS PREFERRED over every heuristic below (ported from the
# macOS twin 2026-08-31, measured the same night on a machine-session restart
# here: the chooser silently landed on a different thread than the live one).
# The sid supervision itself last CONFIRMED ALIVE is the only thread known to
# be the session's own; class-then-newest is the fallback when no last-sid
# exists or its thread is gone. [ -f ] also covers the FIFO and the directory.
_latest=""
if [ -f "$LAST_SID_FILE" ]; then
  _last_sid=""
  IFS=' ' read -r _last_sid _ < "$LAST_SID_FILE" 2>/dev/null || true
  [ -n "${_last_sid:-}" ] && [ -f "$HIST/$_last_sid.jsonl" ] && _latest="$HIST/$_last_sid.jsonl"
fi
_kind=""
_pick=""
[ -n "$_latest" ] || _pick="$(python3 - "$HIST" <<'PY' 2>/dev/null
import glob, json, os, sys
# THE FIRST RECORD SEPARATES THE SESSION'S OWN THREAD FROM AN ERRAND THREAD.
# Measured over every thread file under the projects directory: exactly three
# first-record types exist. Every job/automation thread carried
# "queue-operation"; the long-lived conversations the session IS carried
# "last-prompt", and one carried "file-history-snapshot" ahead of its first
# user turn.
#
# THE CONVERSE IS FALSE, AND SAYING SO MATTERS. A "queue-operation" thread is
# not automatically robot-only: the review of 2026-08-31 found real human
# dialogue inside two of them — a message channel where a person asks the
# session things, and an errand a person kept talking in after a job opened
# it. What the type actually separates is OPENED BY A MACHINE from OPENED AS
# THIS SESSION'S OWN CONVERSATION, and that is the distinction supervision
# needs: resuming an errand makes the session answer as that errand, with its
# narrow role, which is exactly the incident this rule exists to prevent.
#
# THE COST IS REAL AND IS ACCEPTED. A conversation held inside an errand
# thread is deprioritised and not resumed. That is the lesser loss: it stays
# on disk and reachable, while the failure it prevents ran three sessions as
# the wrong assistant for fourteen hours before the owner noticed.
#
# THE RULE IS A DENYLIST, NOT AN ALLOWLIST. Only known job types demote a
# thread; unknown, missing and unparsable first records count as human. That
# is the safe direction: an unrecognised job type costs us no more than the
# old behavior, while an allowlist would demote a real human conversation the
# day a new header type appears.
JOB_FIRST_TYPES = ("queue-operation",)

def first_record_type(path):
    try:
        with open(path, errors="replace") as fh:
            head = fh.readline()
    except OSError:
        return None
    try:
        rec = json.loads(head)
    except Exception:
        return None
    return rec.get("type") if isinstance(rec, dict) else None

best = {}                # class -> (timestamp, path)
for f in glob.glob(os.path.join(sys.argv[1], "*.jsonl")):
    # Only regular files: a FIFO named .jsonl blocks open forever and a
    # directory is not a conversation. Measured in the adversarial round.
    if not os.path.isfile(f):
        continue
    newest = None
    try:
        with open(f, errors="replace") as fh:
            # Split across two statements — and NO APOSTROPHES in this
            # comment: the heredoc sits inside a $() substitution, and bash 3.2
            # (the hub runs it) misparses an apostrophe there into an unclosed
            # quote, swallowing lines until the next one. Measured 2026-08-20:
            # one possessive apostrophe here surfaced as "unbound variable"
            # eighty lines further down. The digit split itself exists because
            # the estate leak guard counts "<word><digits>" pairs without a
            # word boundary, so the digits must not share a line with
            # readlines().
            tail = fh.readlines()
            tail = tail[-200:]                # the last two hundred suffice; hits the live thread
    except OSError:
        continue
    for line in reversed(tail):
        try:
            ts = json.loads(line).get("timestamp")
        except Exception:
            continue
        if ts and (newest is None or ts > newest):
            newest = ts
    if not newest:
        continue
    kind = "job" if first_record_type(f) in JOB_FIRST_TYPES else "human"
    if kind not in best or newest > best[kind][0]:
        best[kind] = (newest, f)
# Human threads outrank job threads; WITHIN a class the newest content wins,
# exactly as before. A job thread is chosen only when no human thread exists.
for kind in ("human", "job"):
    if kind in best:
        print(kind)
        print(best[kind][1])
        break
PY
)"
if [ -n "$_pick" ]; then
  _kind="$(printf '%s\n' "$_pick" | sed -n '1p')"
  _latest="$(printf '%s\n' "$_pick" | sed -n '2p')"
  [ -n "$_latest" ] || _kind=""
fi

# Last resort if python3 is missing or no line carried a timestamp: the
# filesystem. Worse, but better than starting clean and forking.
#
# THE FALLBACK CARRIES THE SAME CLASS RULE. Without it the whole fix collapses
# back to plain mtime the moment python3 is absent — and mtime prefers the job
# thread just as reliably as content did. The class is read from the FIRST line
# of the thread with `read`: one line per file, no python3 needed. Measured:
# "type" is the first key in every thread file, so the pattern is anchored at
# the start of the line. The anchoring is also the safe direction — an
# unanchored substring match could demote a genuine human thread that happened
# to quote the string, whereas a missed job thread merely yields the old
# behavior.
#
# -d lists the glob matches THEMSELVES: without it ls lists a directory named
# .jsonl by its CONTENTS and the fallback picks an id that is not a
# conversation in this directory. [ -f ] for the same reason as in the chooser
# above, and it also shuts out the FIFO that would otherwise block in `read`.
_newest_of_class() { # <human|job> -> path, empty when the class is absent
  ls -td "$HIST"/*.jsonl 2>/dev/null | while IFS= read -r _f; do
    [ -f "$_f" ] || continue
    _head=""
    IFS= read -r _head < "$_f" 2>/dev/null
    case "$_head" in
      '{"type":"queue-operation"'*|'{"type": "queue-operation"'*) _k="job" ;;
      *) _k="human" ;;
    esac
    [ "$_k" = "$1" ] || continue
    printf '%s\n' "$_f"; break
  done
}
if [ -z "$_latest" ]; then
  _latest="$(_newest_of_class human)"
  if [ -n "$_latest" ]; then
    _kind="human"
  else
    _latest="$(_newest_of_class job)"
    [ -n "$_latest" ] && _kind="job"
  fi
  [ -n "$_latest" ] && echo "session-supervisor: $NAME — no timestamp in the threads, falling back to mtime" >&2
fi
if [ -n "$_latest" ]; then
  _sid="$(basename "$_latest" .jsonl)"
  # An id that does not look like a UUID is not a conversation but something
  # else that happened to land in the directory — then it is safer to start
  # clean than to feed claude garbage and get a restart loop.
  # The characters are enumerated, no range: a hex range follows the collation,
  # and in a UTF-8 locale it matches A and E but not F. Harmless right here —
  # Claude's session ids are lowercase hex — but a guard that means different
  # things in different envs is exactly the form test/locale-glob.test.sh
  # exists for.
  case "$_sid" in
    [0123456789abcdef][0123456789abcdef][0123456789abcdef][0123456789abcdef][0123456789abcdef][0123456789abcdef][0123456789abcdef][0123456789abcdef]-*-*-*-*) SID="$_sid" ;;
  esac
  # THIS FORK MUST NEVER BE SILENT. Resuming a job thread beats starting fresh,
  # but the session then answers in the JOB own format and for its errand — from
  # the outside that looks like the assistant got dumb, not like a thread
  # choice. The warning names the session AND the thread so the fork shows up
  # in the log instead of in the owner patience.
  if [ -n "$SID" ] && [ "$_kind" = "job" ]; then
    echo "session-supervisor: $NAME — WARNING: no thread of this session's own in $HIST; resuming the errand thread $SID." >&2
    echo "session-supervisor: $NAME — the session will answer as that errand, not as itself. The thread it skipped may hold conversation too — nothing is deleted." >&2
  fi
fi

# LOOP PROTECTION. A resume that fails dies as silently as --continue did, and
# supervision would retry every third minute forever. After three attempts on
# the SAME id we start clean instead — better a new thread than a session that
# is down all night. The counter resets as soon as the process is alive
# (further down).
if [ -n "$SID" ]; then
  _tries=0
  [ -f "$RESUME_TRY" ] && IFS=' ' read -r _prev_sid _tries < "$RESUME_TRY" 2>/dev/null
  [ "${_prev_sid:-}" = "$SID" ] || _tries=0
  # GARBAGE IN THE COUNTER = 0, NEVER A DEAD START (ported from the macOS
  # twin's fix round). A non-numeric tries field (torn write, hand edit)
  # crashed the arithmetic at the attempt count under set -u BEFORE anything
  # started — the session lay down on the guard's own state, precisely the
  # outcome the guard exists to prevent. Same fail-open as the empty file.
  case "${_tries:-}" in ''|*[!0-9]*) _tries=0 ;; esac
  if [ "${_tries:-0}" -ge 3 ]; then
    # STARTING CLEAN IS FORKING. One session's objection, and it is correct:
    # this is the right call when the alternative is a session that lies down
    # all night, but it is the very outcome all of this was built to avoid.
    # Then it must SCREAM, not silently fall back — and leave a trace someone
    # can find.
    echo "session-supervisor: $NAME — WARNING: resume of $SID failed $_tries times." >&2
    echo "session-supervisor: $NAME — starting a NEW thread. The old one remains in $HIST but does not continue." >&2
    printf '%s\tSID=%s\tforsok=%s\n' "$(date -u +%FT%TZ)" "$SID" "$_tries" >> "$STATE_DIR/$NAME.forked"
    SID=""
  else
    CONT="--resume $SID"
  fi
fi

# CUSTOMER CREDENTIALS MUST NOT BE SHARED BETWEEN SESSIONS. One session
# flagged it 2026-08-10, and it is the sharpest observation about this machine
# so far: all sessions run as the SAME unix user in the SAME home, and az by
# default puts its tokens in ~/.azure. If one session logs in with a customer
# identity, a customer token sits readable for another customer's session —
# precisely the commingling session-per-customer exists to prevent,
# reintroduced via a tool's default setting.
#
# We set it per domain instead of asking anyone to remember. Their own lesson
# from that same day: a documented rule does not protect if it is read after
# you have already chosen.
#
# OUTSIDE THE REPOS on purpose — a cache in ~/Projects/<x>/.azure risks being
# committed.
#
# HONEST ABOUT THE REACH: only AZURE_CONFIG_DIR is known for certain. Other
# tools that cache customer credentials (pac/PowerPlatform, m365,
# IdentityService/MSAL) have mechanisms of their own I have not verified.
# Whoever brings in SUCH a tool must check where it caches BEFORE the first
# login — then it is free, afterwards it is a leak to clean up.
# BARE $DOMAIN, NO FALLBACK. The form was `${DOMAIN:-$NAME}` until 2026-08-18.
# It was UNREACHABLE — the refusal on an empty DOMAIN sits much earlier in the
# file and exits with rc 78 — but unreachable dead code that expresses a
# fallback TEACHES the fallback. That very fallback is moreover the damage the
# refusal exists for: a private credential directory under the session name
# instead of the domain's shared one, with "the tool asks for login again in
# ONE session" as the only symptom. We would have published the line in the
# same release as the argument against it.
CRED_HOME="$HOME/.local/state/agent-creds/$DOMAIN"
mkdir -p "$CRED_HOME" 2>/dev/null
chmod 700 "$HOME/.local/state/agent-creds" "$CRED_HOME" 2>/dev/null
export AZURE_CONFIG_DIR="$CRED_HOME/azure"
# gh caches its auth in ~/.config/gh/hosts.yml — same shared home, same trap.
# The same session flagged it itself when it asked for gh (2026-08-11).
export GH_CONFIG_DIR="$CRED_HOME/gh"
# gcloud caches OAuth tokens in ~/.config/gcloud — the same shared home again.
# Set before the FIRST login (one session's Vertex setup 2026-08-11): the only
# time the convention is free.
export CLOUDSDK_CONFIG="$CRED_HOME/gcloud"

# THE LABEL IS THE CONF'S TO DECIDE (design 2026-08-21: the label is the
# nearest meaningful name — free data, never person, never construction).
# Three cases, told apart by the CONF LINE's presence, not the value:
#   RC_LABEL="Something"  -> that label, verbatim
#   RC_LABEL=""           -> an RC-FREE session: no --remote-control at all,
#                            never in anyone's app; aliveness is measured on
#                            the pane-descendant check alone (the label was
#                            only ever a FINDER of candidate pids — the pane
#                            binding has carried identity since 2026-08-12)
#   no RC_LABEL line      -> a NEW-SHAPE row: the display is DERIVED from the
#                            target, so ask registry_session_display (the one
#                            owner of that derivation) instead of building
#                            prefix+name. A migrated session (no RC_LABEL,
#                            ACCOUNT/SLUG/TARGET_*) would otherwise show the
#                            ugly fallback "<prefix><opaque-id>" rather than
#                            the target's derived display name. The projection
#                            short-circuits to prefix+name for a truly
#                            OLD-shape row (no target, no label), so those
#                            estates are byte-identical.
#
# THE RC_LABEL-PRESENT PATH IS UNTOUCHED — a session whose conf carries a label
# line reads it verbatim through the sed above, byte-for-byte as today. ONLY
# the no-label branch derives.
#
# NEVER EMPTY: if the projection refuses or returns empty (a target that does
# not resolve, a derivation refused), keep the old prefix+name construction.
# The label doubles as the pid-finder's anchor and the session's display name;
# an empty one widens the pattern to "any claude" and leaves the session
# nameless — the supervisor's own doctrine forbids it.
# THE DISPLAY IS A FACT, NOT A FALLBACK (spec §2, §3 "refusal is asymmetric"). registry_session_display
# is the one owner of the derivation; its refusal is KEPT in DISPLAY_ERR instead of being papered over
# with "<prefix><opaque-id>". A new spawn with an unresolvable display refuses (rc 78, naming the missing
# link - see the no-process branch); a RUNNING row is kept alive on identity, keeps its applied name, and
# is marked degraded once per transition (the alive branch). The legacy RC_LABEL line is still read
# verbatim, byte-for-byte; RC_LABEL="" is still the RC-free choice.
# ONE CALL, ONE SNAPSHOT (advisor J5): the register can change between two reads, and the stderr of the
# read whose stdout is used would be lost. stderr goes to a file beside the state, read back, removed.
DISPLAY=""; DISPLAY_ERR=""; _derr="$STATE_DIR/$NAME.display-stderr"
if DISPLAY="$(registry_session_display "$NAME" 2>"$_derr")"; then :; else DISPLAY=""; fi
DISPLAY_ERR="$(cat "$_derr" 2>/dev/null)"; rm -f "$_derr"
if [ -n "$DISPLAY" ]; then DISPLAY_ERR=""; elif [ -z "$DISPLAY_ERR" ]; then DISPLAY_ERR="registry_session_display returned an empty display without a reason"; fi
if grep -q '^RC_LABEL=' "$CONF" 2>/dev/null; then
  RC_LABEL="$(sed -n 's/^RC_LABEL="\(.*\)"/\1/p' "$CONF" | head -1)"
  [ -n "$RC_LABEL" ] && DISPLAY_ERR=""          # a verbatim label IS the display; a derivation failure beside it is not a fault
else
  RC_LABEL="$DISPLAY"
fi
# SESSION_NAME (optional) -> --name, the DISPLAY name in the app's session list.
#
# INDEPENDENT OF RC_LABEL, and the separation is deliberate: an RC-FREE session
# is still registered by the bridge and still appears in the list. Without
# --name the shown name is DERIVED from the working directory and carries a
# per-process suffix that changes on EVERY restart, so the same session appears
# under a new name each time. Nobody can recognise a session by that, and an
# RC-free one has no label to fall back on.
#
# ABSENT FIELD -> NO FLAG. Every existing session must keep the command line it
# already has; this adds a name where one is asked for and changes nothing
# where it is not.
# FALLS BACK TO THE LABEL, exactly as the macOS supervisor does. Measured
# 2026-08-24, right after this field was introduced: on the hub every session
# carried an explicit name, on the Linux host five of six carried MACHINE-DERIVED
# ones that change suffix on every restart — because that supervisor defaults
# --name to the label while this one demanded a field of its own. Two
# supervisors, two behaviours, and the difference showed up only in a human's
# session list. An RC-free session with no field has nothing to fall back on,
# and only there is a derived name the correct outcome.
SESSION_NAME="$(sed -n 's/^SESSION_NAME="\(.*\)"/\1/p' "$CONF" 2>/dev/null | head -1)"
# THE DISPLAY, THEN THE LAST APPLIED NAME, THEN THE LABEL (spec §2): an RC-free row (RC_LABEL="") has no
# label but still has a derived display, and --name is how it stays recognisable in the vendor's list.
[ -n "$SESSION_NAME" ] || SESSION_NAME="$DISPLAY"
[ -n "$SESSION_NAME" ] || { [ "${_bridge_ok:-}" = 1 ] && SESSION_NAME="$(bridge_gen_get "$STATE_DIR" "$NAME" applied 2>/dev/null)"; } || true
[ -n "$SESSION_NAME" ] || SESSION_NAME="$RC_LABEL"
NAME_ARG=""
[ -n "$SESSION_NAME" ] && NAME_ARG=" --name \"$SESSION_NAME\""
# ── THE SESSION'S GRANTED MCP SET, PREPARED ONCE ───────────────────────────
# The registry knows which MCP servers this session inherited (its account, its
# managing team, the owning entity, the project). Until now nothing on a host
# read that: every session started on the LEGACY path -- claude's own discovery
# of the repo's .mcp.json -- so the grant existed only in the register.
#
# ONE CALL, ONE FILE, ONE BRANCH. lib/mcpspawn.sh holds every rule about what
# each outcome means; this file only reads the exit code, because a supervisor
# that re-derived the policy would be a second opinion that can disagree with
# the first. The whole coupling is the six lines below plus one alarm inside
# spawn_session.
#
#   rc 0  a document was written; splice it, strict
#   rc 1  a document was written and part of the grant was OMITTED; splice it,
#         and ALARM after the spawn naming what is missing
#   rc 2  the render REFUSED; an EMPTY document was written and it is spliced
#         strict anyway -- fail-closed, and ALARM. Never the legacy path: the
#         registry spoke and could not be honored, and answering that with
#         whatever the checkout declares gives the session MORE tools than
#         anybody granted, silently
#   rc 3  nothing was granted; MCP_ARG is empty and the command line below is
#         byte for byte the one this fleet already runs
#   rc 69 the document could not be built; REFUSE, same as any other estate
#         value this file will not guess at
#
# THE STDERR IS KEPT because it is the only place the omitted or unrenderable
# assets are named, and an alarm that cannot name them sends a human to read
# four files. The temp file is read in spawn_session and removed on the way out.
#
# THE REFUSALS ARE REMEMBERED HERE AND TAKEN ON THE SPAWN PATH. Both of them --
# a missing spawn library, and a document that could not be built -- used to
# `exit 78` right here, which is ABOVE the alive branch. On a half-deployed host
# (the manifest lists this file BEFORE the two lib rows, so an interrupted
# deploy-apply lands exactly there) that refused the whole ROUND: every
# session's timer exited 78 four times an hour and took with it the
# last-sid/launch-mark bookkeeping, the rename cycle, the zombie-pane repair and
# the unacked-mail and malformed-mail escalations -- none of which need a spawn
# library at all. The libraries are required to START a session, so the refusal
# belongs where a session is started, and MCP_REFUSAL carries it there.
MCP_ARG=""
MCP_RC=3
MCP_REFUSAL=""
MCP_ERR="$(mktemp 2>/dev/null || printf '%s' "$STATE_DIR/$NAME.mcp-err")"
# EVERY EXIT PATH FREES IT. This file leaves through a dozen `exit 0`s -- the
# alive branch alone has several -- and a temp file per supervision round is
# four an hour per session, forever.
trap 'rm -f "$MCP_ERR"' EXIT
# THE ADAPTER CARRIES ITS OWN CONFIGURATION. An OpenCode row has no MCP
# document to prepare and no claude command line to build: neither library is
# needed to start it, so neither may refuse it.
# A CODEX ROW HAS NO PROCESS TO SUPERVISE, and this round must not invent one.
# Run against such a row, the supervision below builds a claude command line
# and starts a tmux session in the row's working copy - a claude-code session
# nobody registered, in the codex row's own directory, with the codex row's id.
# Measured 2026-09-07: "workspace pre-trusted" on a row whose runtime is codex.
# The codex row is driven by its mail (linux/agent-codex@.path) and by nothing
# else; supervision of it is a refusal that says so.
if [ "${RUNTIME:-claude-code}" = "codex" ]; then
  echo "session-supervisor: $NAME is a codex row - it has no pane or port to supervise. Its turns run from linux/agent-codex@.path when mail arrives; nothing to do here." >&2
  exit 0
fi

if [ "${RUNTIME:-claude-code}" = "opencode" ]; then
  :
elif [ -n "$_mcp_lib_missing" ]; then
  MCP_REFUSAL="lib"
else
  MCP_ARG="$(mcp_spawn_prepare "$NAME" "$STATE_DIR/$NAME.mcp.json" 2>"$MCP_ERR")"
  MCP_RC=$?
  [ "$MCP_RC" -eq 69 ] && MCP_REFUSAL="prepare"
fi

# PLACED BEFORE --remote-control ON PURPOSE. The label has to stay the command's
# LAST argument: the pid-finding pattern further down anchors on it, so a --name
# or an --mcp-config appended after it would break aliveness measurement without
# failing loudly. mcp_claude_cmd_fragment is where that order is written down,
# and test/mcpspawn.test.sh section 8 is where it is measured -- this file has
# no suite of its own, so the assembly lives where a suite can reach it.
# A REMEMBERED REFUSAL HAS NO COMMAND LINE. mcp_claude_cmd_fragment lives in the
# library that may be the very thing missing, so it is not called at all; the
# empty string that results is refused on the spawn path below, never spawned.
CLAUDE_CMD=""
if [ -z "$MCP_REFUSAL" ] && [ "${RUNTIME:-claude-code}" != "opencode" ]; then
  CLAUDE_CMD="$(mcp_claude_cmd_fragment "$CONT" "$MCP_ARG" "$NAME_ARG" "$RC_LABEL")"
fi

# THE LOGIN — WHICH MODEL ACCOUNT PAYS (logins.d). ONE rule, shared with the
# macOS twin, built once here and prepended to the command below.
#
# NOT A `new-session -e` ARGUMENT, and the reason is in this file's own
# environment comment: `-e` can SET a variable but cannot UNSET one, and half
# the rule is unsetting the two auth overrides that WIN over subscription auth.
# The prefix carries the whole rule as arguments no shell reinterprets, so it
# works identically here and inside the macOS branches' exec strings.
#
# EMPTY LOGIN -> THE SCRUB WITHOUT A DIRECTORY. It WAS an empty prefix and a
# byte-identical command line until 2026-09-03; a LOGIN-less line now carries
# `-u ANTHROPIC_API_KEY -u ANTHROPIC_AUTH_TOKEN` too. The DIRECTORY is what
# stays transitional: with no LOGIN no CLAUDE_CONFIG_DIR is set at all.
#
# THE REFUSAL FIRES AT LOAD TIME, EVERY ROUND -- not only on a spawn. A LOGIN
# that stops resolving (a row removed from logins.d, a home lookup that
# fails) exits 78 here on every subsequent round too, so it stops supervision
# of an already-live and healthy session, not just a new spawn. Loud (rc 78,
# a named slug) beats quiet: a session that silently kept running unsupervised
# because its login rotted underneath it is worse than one that gets no
# restarts until someone fixes the row.
# ALWAYS BUILT, EVEN WITHOUT A LOGIN -- see the macOS twin's note. The call used
# to sit inside `if [ -n "$LOGIN" ]`, so a LOGIN-less session never reached the
# rule and passed on whatever auth override it inherited. An API key WINS over
# subscription auth, so that session ran on API billing while every view showed
# the subscription.
#
# PRESENCE IS NOT CONTENTS -- the same guard the spawn libraries get above
# (:116-121), and now needed for the same rollout state. A registry library that
# sources cleanly but PREDATES registry_login_exec_prefix makes this call a
# command-not-found: rc 127, which `if !` below reads as a refusal. Until the
# call became unconditional that could only strike a row WITH a login; it now
# strikes every row, and the refusal below would name the ROW ("LOGIN=\"\" does
# not resolve") and send the person debugging it into logins.d looking for a
# line that was never there. So the library is measured by what it DEFINES, and
# the refusal names the library.
if ! declare -F registry_login_exec_prefix >/dev/null 2>&1; then
  echo "session-supervisor: $NAME — REFUSING to start: $REG_LIB does not define registry_login_exec_prefix — deploy the product first." >&2
  exit 78
fi
# AN OPENCODE ROW NEVER GOES THROUGH THE CLAUDE LOGIN RECIPE. The adapter
# (runtime/opencode-session.sh) owns its own login - OpenCode's auth store in
# this account - and reads none of this prefix. Resolving LOGIN here would
# refuse every OpenCode row whose provider has no claude isolation recipe,
# which is all of them. Ported from the macOS twin, which measured it.
if [ "${RUNTIME:-claude-code}" = "opencode" ]; then
  LOGIN_PREFIX=""
elif ! LOGIN_PREFIX="$(registry_login_exec_prefix "${LOGIN:-}" "$(id -un)")"; then
  echo "session-supervisor: $NAME — REFUSING to start: LOGIN=\"${LOGIN:-}\" does not resolve (see above)." >&2
  exit 78
fi
# LEADING SPACE, spliced with no separator. The prefix is never empty now; the
# form is kept so a future empty one cannot break the command line.
[ -n "$LOGIN_PREFIX" ] && LOGIN_PREFIX="$LOGIN_PREFIX "

# TMUX DOES NOT INHERIT THIS ENVIRONMENT. Measured 2026-08-14, and it is a
# trap that made the whole credential isolation ineffective for two days
# without anything speaking up:
#
#   The variables above are exported by THIS SCRIPT. But claude is not run by
#   this script — it is run by the TMUX SERVER, which started the first time
#   any session was created and which carries ITS environment until it dies. A
#   new session inside an old server inherits the server's environment, not
#   ours.
#
#   The consequence: one session was restarted, its tmux session was
#   recreated, the thread resumed correctly — and /proc/<pid>/environ still
#   lacked every single variable. Restarting the SESSION is not enough; it
#   would have required killing the SERVER, i.e. every session on the machine
#   at once.
#
# Therefore the environment is set EXPLICITLY in both start paths below. Then
# it does not matter what the server carries, and a single session can be
# restarted without touching the others. The requirement is tmux >= 3.2 for
# `new-session -e` (the session host runs 3.4).
#
# The rule behind it: a setting that depends on inheritance is a setting that
# depends on process history — and process history is exactly what nobody
# looks at when they read a conf and believe they know what applies.
CRED_ENV_ARGS=(
  -e "CRED_HOME=$CRED_HOME"
  -e "AZURE_CONFIG_DIR=$AZURE_CONFIG_DIR"
  -e "GH_CONFIG_DIR=$GH_CONFIG_DIR"
  -e "CLOUDSDK_CONFIG=$CLOUDSDK_CONFIG"
)
# THE RIG'S PORT TRAVELS WITH THE SESSION, for the same reason the directories
# above do. A rig is declared on the session row; the tools that drive it used
# to learn the port from their own default, and a default is ONE owner's port.
# Measured 2026-09-04 in a second home: two servers reached for 127.0.0.1:9225
# -- the first owner's rig, behind a guard -- and the error named the caller's
# own machine, which sends the reader to the wrong rig entirely. The PATHS in
# those same rows had already been made home-relative for this exact reason;
# the port is the same fault one level down.
#
# ONLY WHEN THERE IS A RIG. An empty value would read as "there is a rig, on
# port nothing", and a tool that trusts the variable then fails differently
# from one that falls back to its own default -- two failure modes for one
# missing declaration.
if [ -n "${BROWSER_CDP:-}" ]; then
  CRED_ENV_ARGS+=( -e "STEWARD_BROWSER_CDP=$BROWSER_CDP" )
fi
# THE WHOLE RIG TRAVELS, not half of it. The VNC port and the display follow
# the same rule as the CDP port: exported only when declared, so a session
# knows every number of its own rig from its environment and never opens its
# conf, or computes, to find the other two. Measured 2026-09-06: a session
# knew its CDP port this way and its VNC port only by reading its row.
if [ -n "${BROWSER_VNC:-}" ]; then
  CRED_ENV_ARGS+=( -e "STEWARD_BROWSER_VNC=$BROWSER_VNC" )
fi
if [ -n "${BROWSER_DISPLAY:-}" ]; then
  CRED_ENV_ARGS+=( -e "STEWARD_BROWSER_DISPLAY=$BROWSER_DISPLAY" )
fi
# (The send-keys variant of this environment is gone WITH the send-keys
# repair: every start path below creates a fresh pane via new-session -e, so
# the array above is the whole story.)

# THE PAUSE MARKER WINS OVER EVERYTHING — and is therefore read at the TOP of
# the file, not here. A session deliberately shut down must not be revived by
# supervision three minutes later, and the watchdog reads the same marker and
# does not alarm about the missing process. Without the marker, "switched off"
# cannot be told apart from "dead" (2026-08-06). The check sat here until
# 2026-08-20; see the file header for the measurement that moved it.

# Is the claude process for this session alive? The RC label is unique.
# ANCHORED ON THE CLAUDE BINARY: the tmux server carries the session's whole
# start command in its own process line (including the RC label) as long as
# the server lives — an unanchored pattern matches it and reports "alive"
# about a dead claude. Measured 2026-08-06: supervision stood watching the
# tmux server while the pane showed a bash prompt.
# THE PREFIX IS DATA IN A REGULAR EXPRESSION. As long as it was a literal this
# did not matter — the old literal had no metacharacters. Now it comes from
# the estate's conf, and registry_rc_label_prefix lets through among others
# "." and "-". An unescaped "." matches any character: the pattern becomes
# wider than the label and can match ANOTHER session's process. Wide matching
# is the dangerous direction here — supervision would believe the session is
# alive and never restart it.
# THE PATTERN MEASURES THE LABEL THAT WAS DECIDED, not a construction — the
# same RC_LABEL resolution as CLAUDE_CMD above, escaped whole (the label is
# free data since 2026-08-21 and may carry any metacharacter).
# ANCHORED AT BOTH ENDS. The front anchor (the claude binary) has its story
# above. The END anchor is younger and was paid for live 2026-08-21: without
# it, a session whose name is a strict PREFIX of a sibling's matched the
# sibling's process — supervision believed the shorter-named session was
# alive as long as the longer-named one ran, and it could never be restarted.
# The label is always the command's last argument (CLAUDE_CMD above), so end
# of line — with an optional closing quote — is exact. The same prefix trap
# lives in tmux's -t matching, which is why every target below says =$NAME.
#
# AN RC-FREE SESSION (empty RC_LABEL) HAS NO LABEL TO FIND PIDS BY: the
# pattern widens to "any claude", and the pane-descendant check below — which
# has carried identity since 2026-08-12 — does ALL the disambiguation. The
# label was only ever a finder of candidates.
# AN OPENCODE SESSION IS FOUND BY ITS PORT. It carries no --remote-control
# label; what its process line does carry is the loopback port the registry
# gave this row and no other, as measured on the first live advisor:
# "opencode <repo> --session ... --port N".
if [ "${RUNTIME:-claude-code}" = "opencode" ]; then
  CLAUDE_PAT="^[^ ]*opencode .*[-]-port $OPENCODE_PORT( |\$)"
else
  # NO LABEL BRANCH ANY MORE: a claude row is identified through the bridge adapter (IS_CLAUDE),
  # and this pattern is never consulted for it. The RC-free form is kept for the functions the
  # OpenCode path still calls.
  CLAUDE_PAT="^[^ ]*claude( |\$)"
fi

# ...BUT A PATTERN IS NOT ENOUGH: the process must belong to THIS session's
# tmux pane. A claude the timer started before the owner had logged in, and
# which then became orphaned when the tmux session was killed, still matches
# the pattern — it reparents to systemd and keeps running. Supervision saw it,
# believed the session was alive, and never restarted it. Observed during an
# onboarding on the session host 2026-08-12, verified in the code and the
# process tree (wchan, ppid chain) from here. The same process-group mistake
# as a job loop's 11/11 timeout and the empty session — the check measured
# something ADJACENT (does a matching process exist?) instead of what it
# wanted to know (is MY claude running, tied to MY tmux?).
matching_claude_pids() { pgrep -u "$(id -u)" -f "$CLAUDE_PAT" 2>/dev/null; }
# EVERY PANE IN EVERY WINDOW (-s), never just the current window. Fixture-proven
# on real tmux 3.6b: list-panes -t "=name" lists ONLY the session's CURRENT
# window. A human attaches, opens a second window (it becomes current),
# detaches → claude lives on in window 0, invisible to both the alive check
# and the kill veto → two rounds of "no runtime" → kill-session destroys the
# live conversation. The kill must never out-scope its own veto, so both
# checks below iterate descendants of every pane this returns.
session_pane_pids()    { tmuxc list-panes -s -t "=$NAME" -F '#{pane_pid}' 2>/dev/null; }
# Is $1 equal to or a descendant of $2? Follow ppid upwards until target, init
# (1) or a ceiling is reached — the ceiling protects against a broken ps that
# cycles.
is_descendant() {   # the OpenCode path's own walk, unchanged; the adapter has the same walk in lib/bridge.sh (E2, H5)
  local pid="$1" target="$2" n=0
  while [ -n "$pid" ] && [ "$pid" -gt 1 ] && [ "$n" -lt 40 ]; do
    [ "$pid" = "$target" ] && return 0
    pid="$(ps -o ppid= -p "$pid" 2>/dev/null | tr -d ' ')"
    n=$((n+1))
  done
  return 1
}
claude_alive_in_session() {
  local panes; panes="$(session_pane_pids)"
  [ -n "$panes" ] || return 1   # no tmux session -> no live session, period
  local pid pane
  for pid in $(matching_claude_pids); do
    for pane in $panes; do
      is_descendant "$pid" "$pane" && return 0
    done
  done
  return 1
}
# THE KILL DECISION IS BROADER THAN THE ALIVE DECISION. The zombie repair
# below kills a tmux session, and a kill must never reach a living runtime —
# so its veto does not trust the label-anchored pattern above (a drifted
# label, or a pattern bug, would otherwise turn into a killed conversation)
# and it counts EVERY interactive runtime: claude under any label, and the
# opencode adapter, whose process line carries "opencode" in a path word
# rather than as claude argv. The match is deliberately loose ((^|[ /]) word
# start, no end anchor): a false ALIVE here merely postpones a repair one
# round and warns, while a false DEAD kills — the asymmetry picks the
# direction. The label-anchored check keeps deciding "healthy"; this one only
# vetoes destruction.
# OUT OF SCOPE BY DECISION: a RENAMED runtime binary — no "claude" or
# "opencode" anywhere in any argv — is invisible to this veto and would be
# killed as a zombie. Whoever renames the binary steps outside the contract;
# widening the veto to "any process at all" would make every zombie pane
# (which always holds a live bash) unkillable forever.
RUNTIME_VETO_PAT='(^|[ /])(claude|opencode)'
matching_runtime_pids() { pgrep -u "$(id -u)" -f "$RUNTIME_VETO_PAT" 2>/dev/null; }
runtime_alive_in_session() {
  local panes; panes="$(session_pane_pids)"
  [ -n "$panes" ] || return 1
  local pid pane
  for pid in $(matching_runtime_pids); do
    for pane in $panes; do
      is_descendant "$pid" "$pane" && return 0
    done
  done
  return 1
}

# ---- THE ZOMBIE VETO'S EVIDENCE OF A HUMAN --------------------------------
# The kill veto further down asks "may a human be working in that window?".
# Until 2026-09-09 it answered with the EXISTENCE of a tmux client, and that is
# not the same question. What the three helpers below measure is stated at the
# veto itself; here is only the machinery.

# _is_epoch <s> - 0 iff the string is a bare, non-empty run of digits. Every
# comparison below is arithmetic, and an unset or unexpandable tmux format
# yields the EMPTY string, which `-gt` would read as 0 and call ancient.
_is_epoch() { case "${1:-}" in ''|*[!0-9]*) return 1 ;; esac; return 0; }

# _mtime_of <path> - the file's mtime in epoch seconds, empty when unreadable.
# TWO-SHOT WITH A SHAPE FILTER, the idiom lib/registry.sh:_registry_mode_of
# documents: `stat -f` means FILESYSTEM STATUS on GNU, exits 0, and prints a
# multi-line ext4 report that a non-empty check would happily accept as a
# timestamp - and this supervisor's whole point is that it runs on Linux. Only
# an all-digit answer counts; anything else falls through to the GNU form.
_mtime_of() {
  local p="$1" t
  for t in "$(stat -f '%m' "$p" 2>/dev/null)" "$(stat -c '%Y' "$p" 2>/dev/null)"; do
    _is_epoch "$t" && { printf '%s' "$t"; return 0; }
  done
  return 1
}

# THE USER MANAGER'S PIDS, read once per round by the veto (a pgrep per client
# would be the same answer four times). systemd --user is the reaper a
# session-scoped process falls to when the thing that started it dies, and it
# says so itself in the journal: "Found left-over process N (tmux: client) in
# control group while starting unit. Ignoring. This usually indicates unclean
# termination of a previous run."
UM_PIDS=""
user_manager_pids() { pgrep -u "$(id -u)" -f 'systemd --user' 2>/dev/null; }

# client_is_orphaned <pid> - 0 iff the client's parent chain reaches the user
# manager. THE SAME CLIMB THE KILL VETO ALREADY USES (is_descendant), not a
# second walk: one ps-climbing implementation, one ceiling, one ppid reader.
client_is_orphaned() {
  local pid="$1" um
  _is_epoch "$pid" || return 1
  for um in $UM_PIDS; do
    is_descendant "$pid" "$um" && return 0
  done
  return 1
}
# Reap orphans BEFORE starting anew — otherwise the old claude keeps running
# beside the new one, two processes with the same RC label and a
# remote-control conflict. Only meaningful when no tmux session exists; with a
# live session the process belongs to it and is left alone (that is the
# suspect flow's responsibility).
# DEPLOY-DAY RUNBOOK: do a ONE-TIME per-host read-only sweep for
# --remote-control-labeled claudes running OUTSIDE the declared socket before
# turning this supervisor on. A claude on ANOTHER socket descends from no pane
# this function can see, so it is an orphan by this test too. The sweep finds
# those before the first round can.
#
# THE VETO IS THE WHOLE SOCKET'S PANES, NOT THIS SESSION'S. The guard above
# says only that MY session is gone; it says nothing about anyone else's. The
# kill set used to be "every pid in this home whose argv matches CLAUDE_PAT",
# bound to no pane at all - and CLAUDE_PAT is a LABEL, which is not an
# identity: two rows in one home may carry the same one.
#
# MEASURED ON A LIVE LINUX HOST 2026-09-09: two sessions in one home, one uid,
# the same RC_LABEL. The zombie repair calls kill-session BEFORE spawn_session,
# so the has-session guard is always false on that path - and each repair
# SIGTERMed the OTHER session's live claude, which two rounds later became the
# other's zombie verdict. An alternating mutual kill, 13 destroyed
# conversations in 55 minutes. The label collision is fixed in its own place
# (the write-time uniqueness check on a session row), but this function must
# not depend on labels being unique to avoid killing a live conversation.
#
# THE LATENT CASE THIS ALSO CLOSES IS WIDER THAN THE ONE THAT FIRED. An
# RC-FREE row (RC_LABEL="") sets CLAUDE_PAT='^[^ ]*claude( |$)' - ANY claude in
# the home. One respawn of such a row would have killed every claude that home
# was running. No such row exists on the affected host today; the pane binding
# means none ever can.
#
# STRICTLY NARROWER, BY CONSTRUCTION: every candidate that used to be killed is
# still considered, and the only thing added is a reason to SKIP one. This can
# kill fewer processes than before, never more - which is the property that
# makes the change reviewable. The empty pane set (no tmux server, no session
# anywhere) skips nothing, so the deploy-day sweep case is unchanged.
#
# It also makes the function do what its own name already claims: kill a
# runtime that belongs to NO live pane.
reap_orphan_claude() {
  tmuxc has-session -t "=$NAME" 2>/dev/null && return 0
  # EVERY PANE IN EVERY WINDOW OF EVERY SESSION ON THE SOCKET (-a). Not
  # session_pane_pids: that asks about "=$NAME", which is precisely the
  # session the caller has just established does not exist.
  local all_panes; all_panes="$(tmuxc list-panes -a -F '#{pane_pid}' 2>/dev/null)"
  local pid pane bound
  # STEWARD_KILL overrides only in the test — kill is a bash builtin and
  # cannot be stubbed via PATH, so the test aims it at a script of its own.
  # The default is empty; then the builtin kill runs for real.
  for pid in $(matching_claude_pids); do
    # is_descendant CLIMBS, so a login prefix or a wrapper shell between the
    # pane and the runtime does not turn a live conversation into an orphan.
    bound=""
    for pane in $all_panes; do
      is_descendant "$pid" "$pane" && { bound=1; break; }
    done
    [ -n "$bound" ] && continue
    ${STEWARD_KILL:-kill} "$pid" 2>/dev/null && echo "session-supervisor: $NAME killed orphan claude $pid (no tmux session)" >&2
  done
}


# THE TRUST PROMPT IS A SILENT DEATH TRAP FOR AN UNATTENDED SESSION.
# Measured 2026-08-14: three out of three new sessions started in a repo
# Claude Code had not seen before and stopped at
#
#   "Quick safety check: Is this a project you created or one you trust?"
#
# waiting for a keypress. No timer presses Enter. And the worst part:
# SUPERVISION REPORTED HEALTHY the whole time — claude WAS a live descendant
# of the pane, which is precisely what the sign of life measures. Green while
# the session could accomplish nothing. The unacked alarm was silent too,
# because an inbox that is never read is not an inbox that grows.
#
# It is the catalogue's form in our own code: a check that measures THAT THE
# PROCESS EXISTS, not that it is ABLE TO WORK. One session found it and had to
# press Enter for three sessions by hand.
#
# WE DO NOT GREP THE PANE. The prompt text is a UI string that changes without
# notice, and answering with send-keys would be writing into a conversation —
# precisely what the two-round rule further down exists to prevent. Claude
# Code has a STATE for the same thing:
# .projects["<repo>"].hasTrustDialogAccepted in ~/.claude.json. We set the
# state instead of answering the question.
#
# Written only when missing, and only right before a NEW session is started —
# no claude is running in that workspace yet. Other sessions' claudes can
# rewrite the file and happen to zero the flag; the next supervision round
# sets it again. Self-healing beats a one-time fix when you share a file with
# processes you do not control.
# THE TRUST STATE LIVES IN THE ACTIVE ACCOUNT'S OWN FILE. Setting the flag in
# ~/.claude.json while the session reads a different config directory writes
# to a file nothing consults: the start then sticks at the trust prompt
# forever, and the journal says the workspace was pre-trusted.
#
# MEASURED 2026-09-02, read-only ls against a live session's config
# directory: under a set CLAUDE_CONFIG_DIR the CLI writes its trust/config
# file to <cfg>/.claude.json (present, 41587 bytes), not <cfg>.json.
#
# EXCEPT FOR THE LEGACY LOGIN, whose directory is the runtime's unnamed
# default: the exec prefix leaves CLAUDE_CONFIG_DIR UNSET for that row (see
# _registry_login_is_unnamed_default in lib/registry.sh, 2026-09-03), so the
# CLI keeps its file BESIDE the directory, at ~/.claude.json, exactly as with
# no LOGIN at all. Setting the flag in <cfg>/.claude.json there is the same
# mistake as the paragraph above, mirrored -- and once that stray file is
# gone, ensure_workspace_trusted returns 0 without writing, so the start
# sticks at the trust prompt while the journal says it was pre-trusted.
#
# THE CHOICE FOLLOWS THE LIBRARY THAT IS ACTUALLY DEPLOYED. A registry
# library without the helper is one whose prefix still ASSIGNS the legacy
# directory, and under that prefix the CLI does read <cfg>/.claude.json --
# so on such a host the old line is the right line. The two must move
# together, and this way they cannot disagree.
CLAUDE_JSON="$HOME/.claude.json"
if [ -n "${LOGIN:-}" ]; then
  if declare -F _registry_login_is_unnamed_default >/dev/null 2>&1 \
     && _registry_login_is_unnamed_default "$CFG_ROOT"; then
    :   # legacy row: the file beside the directory, as with no LOGIN
  else
    CLAUDE_JSON="$CFG_ROOT/.claude.json"
  fi
fi
ensure_workspace_trusted() {
  command -v jq >/dev/null 2>&1 || {
    echo "session-supervisor: $NAME — jq is missing, cannot pre-trust the workspace" >&2; return 0; }
  [ -f "$CLAUDE_JSON" ] || return 0
  local cur
  cur="$(jq -r --arg p "$REPO" '.projects[$p].hasTrustDialogAccepted // false' "$CLAUDE_JSON" 2>/dev/null)"
  [ "$cur" = "true" ] && return 0
  local tmp; tmp="$(mktemp "${CLAUDE_JSON}.XXXXXX")" || return 0
  if jq --arg p "$REPO" '.projects[$p].hasTrustDialogAccepted = true' "$CLAUDE_JSON" > "$tmp" 2>/dev/null \
     && [ -s "$tmp" ]; then
    chmod --reference="$CLAUDE_JSON" "$tmp" 2>/dev/null
    mv -f "$tmp" "$CLAUDE_JSON"
    echo "session-supervisor: $NAME — workspace $REPO pre-trusted (otherwise the start sticks at the trust prompt)" >&2
  else
    rm -f "$tmp"
    echo "session-supervisor: $NAME — could not write $CLAUDE_JSON, the start may stick at the trust prompt" >&2
  fi
}

# A SIGN OF LIFE IS NOT ABILITY TO WORK. Backstop for the case above: if
# claude runs while the workspace is UNTRUSTED it is almost certainly sitting
# at the prompt. That is a STATE we can read, not a guess about what the pane
# shows — and it alarms in the journal instead of looking healthy.
warn_if_untrusted_while_running() {
  command -v jq >/dev/null 2>&1 || return 0
  [ -f "$CLAUDE_JSON" ] || return 0
  local cur
  cur="$(jq -r --arg p "$REPO" '.projects[$p].hasTrustDialogAccepted // false' "$CLAUDE_JSON" 2>/dev/null)"
  [ "$cur" = "true" ] && return 0
  echo "session-supervisor: $NAME — WARNING: claude is alive but the workspace $REPO is not trusted." >&2
  echo "session-supervisor: $NAME — the session is probably waiting at the trust prompt and accomplishing nothing." >&2
}
# (Defined BEFORE the live branch below — on 2026-08-16 they sat after their
# own top-level call: command not found on every supervision round, 97 journal
# lines in two days, and the guard against silent waiting was itself silently
# gone.)

# rename_pane_busy <pane-text> — 0 iff the pane shows the session mid-turn.
# Mirrors the bus client's proven pane-busy predicate ("esc to interrupt", or
# the "… (" spinner prefix — the same signal the watchdog's paneState reads).
# Typing into a busy pane loses keystrokes or lands text inside a running
# turn, which is the exact failure the two-round rule exists to prevent — so a
# busy round is skipped and retried, never typed into and never counted.
rename_pane_busy() {
  case "${1:-}" in *'esc to interrupt'*) return 0 ;; esac
  case "${1:-}" in *'… ('*) return 0 ;; esac
  return 1
}

# rename_receipt_seen <pane-text> <label> — 0 iff some pane LINE is the receipt
# for EXACTLY this label. The receipt line the runtime prints is indented and
# carries a "⎿" marker ("  ⎿  Session renamed to: <name>"); leading indent and
# marker are stripped, trailing whitespace too, and what remains must EQUAL
# "Session renamed to: <label>" — never contain it.
#
# WHY LINE-EQUAL AND NOT SUBSTRING (measured 2026-09-03 19:06-19:09): the
# rename's Enter was lost, the re-ping of the same round landed on the same
# input line, and the session was renamed to "<label> <ping text>". The
# substring match found "Session renamed to: <label>" inside that receipt and
# logged "receipt verified" — a wrong tile, receipted as right. A receipt one
# character longer than the label is a receipt for a different name.
rename_receipt_seen() {
  local _line
  while IFS= read -r _line; do
    _line="${_line#"${_line%%[![:space:]]*}"}"
    _line="${_line#⎿}"
    _line="${_line#"${_line%%[![:space:]]*}"}"
    _line="${_line%"${_line##*[![:space:]]}"}"
    [ "$_line" = "Session renamed to: $2" ] && return 0
  done <<EOF
${1:-}
EOF
  return 1
}

# type_line <text> — type one line into the session's pane: the text
# literally, a settle pause, then Enter. THE PAUSE IS THE FIX. Text and
# Enter in the same breath is how the rename's Enter went missing on
# 2026-09-03 (the text stayed in the input box, unsubmitted, and the next
# keystrokes appended to it); the hand repair that worked the same evening
# was exactly this shape — text, two seconds, Enter. STEWARD_KEY_SETTLE_SEC
# overrides the pause (the suites set 0). Callers hold the busy/alive guards;
# this only types. TYPED_THIS_ROUND records that keys went to the pane, so
# the round's other typing site can stand down — see the re-ping.
TYPED_THIS_ROUND=""
type_line() { # <pane-target> <text> - EVERY keystroke names its pane. For a claude row the target is the
              # bridge file's exact pane (session:@window.%pane); a human's current window is never it.
              # rc 0 delivered; rc 1 nothing left this process (the literal failed); rc 2 PARTIAL - the literal
              # landed but Enter did not, which is an attempt (the text is in the pane) and must be loud, because
              # an immediate retry would double the input (advisor J7).
  tmuxc send-keys -t "$1" -l "$2" 2>/dev/null || return 1
  TYPED_THIS_ROUND=1
  sleep "${STEWARD_KEY_SETTLE_SEC:-2}"
  tmuxc send-keys -t "$1" Enter 2>/dev/null || return 2
  return 0
}
# pane_foreground_is_managed <pane-target> <managed-pid> - the pane's FOREGROUND is the managed claude.
# Descendant-of-pane is not foreground: a vim or a shell in front of claude would receive the keys. Three
# independent readings must agree (spec §2, plan B9): tmux says the current command is claude; the pane
# shell and the managed pid share the same nonzero tty (field 7 of /proc/<pid>/stat); and that tty's
# foreground process group (field 8, tpgid) - read on BOTH sides - is the managed pid's own group (field 5).
pane_foreground_is_managed() {
  local pane_pid root="${BRIDGE_PROC_ROOT:-/proc}" a b
  [ "$(tmuxc display-message -p -t "$1" '#{pane_current_command}' 2>/dev/null)" = claude ] || return 1
  pane_pid="$(tmuxc display-message -p -t "$1" '#{pane_pid}' 2>/dev/null)"; case "$pane_pid" in ''|*[!0-9]*) return 1 ;; esac
  a="$(sed 's/^.*) //' "$root/$pane_pid/stat" 2>/dev/null)"; b="$(sed 's/^.*) //' "$root/$2/stat" 2>/dev/null)"
  [ -n "$a" ] && [ -n "$b" ] || return 1
  set -- $a; local p_tty="${5:-}" p_tpgid="${6:-}"
  set -- $b; local m_pgrp="${3:-}" m_tty="${5:-}" m_tpgid="${6:-}"
  case "$p_tty" in ''|0|*[!0-9]*) return 1 ;; esac
  [ "$p_tty" = "$m_tty" ] && [ "$p_tpgid" = "$m_tpgid" ] && [ "$p_tpgid" = "$m_pgrp" ]
}
same_nonempty_sv() { [ -n "${1:-}" ] && [ "$1" = "${2:-}" ]; }
# PANE_TARGET: where this round's keystrokes go. The bridge's exact pane for an identified claude row;
# the session name (today's form) for everything else.
PANE_TARGET="$NAME"

# bus_signalera <what> <text> — send an AUTO-ALERT to the hub and REPORT THE
# TRUTH about why it failed. rc 0 on success, non-zero otherwise.
#
# THE LOG LINE BLAMED THE WRONG THING. The form was
#     if [ -x "$BUS_SEND" ] && "$BUS_SEND" "$NAV" "$MSG" 2>/dev/null; then …
#     else echo "COULD NOT signal … (bus-send missing/broken) — retrying"
# Three different errors were squeezed into one sentence that pointed at the
# least likely of them, and stderr — where the bus's own guard actually
# explains itself — was thrown away.
#
# Concretely: if someone parks a noisy subject, or the envelope is wrong, or
# the secret guard in ~/bin/bus-send trips, the send is refused rc 65. Then
# the journal says the BINARY IS MISSING. Whoever debugs looks for a file that
# exists, every round, forever — and the real cause lay in the stderr that was
# just discarded.
#
# Refusal (65) and config error (78) are OUR OWN GUARDS speaking up; they get
# a text of their own and their stderr passed through. The noise from a broken
# network may stay silent.
bus_signalera() { # <what> <text>
  local vad="$1" text="$2" bs="$HOME/bin/bus-send"
  if [ ! -x "$bs" ]; then
    echo "session-supervisor: $NAME COULD NOT signal $vad — $bs is missing or not executable" >&2
    return 1
  fi
  local err; err="$(mktemp 2>/dev/null)" || err=""
  local rc=0
  if [ -n "$err" ]; then
    BUS_FROM="$NAME" "$bs" "$NAV" "$text" >/dev/null 2>"$err" || rc=$?
  else
    BUS_FROM="$NAME" "$bs" "$NAV" "$text" >/dev/null 2>/dev/null || rc=$?
  fi
  case "$rc" in
    0) : ;;
    65|78)
      echo "session-supervisor: $NAME — the signal about $vad was REFUSED BY THE BUS'S OWN GUARD (rc $rc)." >&2
      echo "session-supervisor: $NAME — this is NOT an absent bus-send. Common causes: the subject is parked, the envelope is wrong, or the secret guard tripped. The guard says:" >&2
      [ -n "$err" ] && sed 's/^/  /' "$err" >&2
      ;;
    *)
      echo "session-supervisor: $NAME COULD NOT signal $vad (bus-send rc $rc) — retrying next round" >&2
      ;;
  esac
  [ -n "$err" ] && rm -f "$err"
  return "$rc"
}

if runtime_identified; then
  if [ "$IS_CLAUDE" = 1 ]; then
    bind_generation; _bind_rc=$?
    if [ "$_bind_rc" -eq 2 ]; then exit 0; fi   # the contradiction is logged once above; nothing else this round
    if [ "$_bind_rc" -ne 0 ]; then
      echo "session-supervisor: $NAME — the verified record could not be written to the generation; no other write this round." >&2
      exit 0
    fi
  fi
  rm -f "$SUSPECT" "$RESUME_TRY"   # live session = the resume took, reset the counter
  # SURVIVAL TURNS THE LAUNCH MARK INTO last-sid (the macOS twin's hold-loop
  # round two, translated to the one-shot model: a full timer interval alive
  # is a stronger survival proof than the twin's ten seconds). A start with a
  # sid records that sid as the last one known alive; a FRESH start clears
  # last-sid, so the next respawn finds the NEW thread via newest-by-content
  # instead of the old one via last-sid. A round that did not start anything
  # leaves no mark and touches nothing.
  if [ -f "$LAUNCH_MARK" ]; then
    _l_sid=""
    IFS=' ' read -r _l_sid _ < "$LAUNCH_MARK" 2>/dev/null || true
    if [ -n "${_l_sid:-}" ]; then
      printf '%s\n' "$_l_sid" > "$LAST_SID_FILE"
    else
      rm -f "$LAST_SID_FILE"
    fi
    rm -f "$LAUNCH_MARK"
  fi
  # ...but "alive" is not "able to work". See the comment at
  # ensure_workspace_trusted: a session waiting at the trust prompt is a live
  # process accomplishing zero, and without this line it looks like any
  # healthy session.
  warn_if_untrusted_while_running
  # THE RENAME CYCLE, BOUND TO THE BRIDGE'S PANE (spec §2; plan Task 6). Desired is the display this
  # round derived; APPLIED is the last display confirmed by a receipt, kept in the generation - never the
  # bridge file's reported name, which follows argv on a resume and proves nothing about the tile. When
  # desired != applied the row is RENAME PENDING (persistent across restarts; the trace file is log
  # text): every step is addressed to the bridge file's exact pane, the pane's foreground must be the
  # managed claude, and the /rename is a KEYED two-round suspect - typed only when two consecutive rounds
  # saw the same pid, birth, pane, desired and pending_since immediately before typing. The receipt has
  # to hold on three sides at once: the pane line, the bridge's reported name, and a nameSince that
  # ADVANCED past the observation the pending was recorded on. OpenCode has no /rename and no cycle.
  if [ "$IS_CLAUDE" = 1 ]; then
    [ -n "$B_PANE" ] && PANE_TARGET="$B_PANE"
    RENAME_SUSPECT="$STATE_DIR/$NAME.rename-suspect"
    if [ -n "$DISPLAY_ERR" ]; then
      if [ ! -f "$STATE_DIR/$NAME.display-degraded" ]; then
        touch "$STATE_DIR/$NAME.display-degraded"
        echo "session-supervisor: $NAME — DEGRADED: the display no longer derives ($DISPLAY_ERR); keeping the applied name, supervising on identity." >&2
      fi
    else
      rm -f "$STATE_DIR/$NAME.display-degraded"    # recovery: the next transition alarms once more
    fi
    DESIRED="$RC_LABEL"; APPLIED="$(bridge_gen_get "$STATE_DIR" "$NAME" applied 2>/dev/null)"
    _hg=0; if [ -n "$DESIRED" ] && [ "$DESIRED" != "$APPLIED" ]; then host_gate_lock; _hg=$?; fi
    if [ "$_hg" -eq 1 ]; then
      rm -f "$RENAME_SUSPECT"
      echo "session-supervisor: $NAME — another supervisor holds the display reservation lock; no rename step this round." >&2
    elif [ -n "$DESIRED" ] && [ "$DESIRED" != "$APPLIED" ] && host_gate_refuses "$DESIRED" "rename"; then
      host_gate_unlock; rm -f "$RENAME_SUSPECT"                                            # spec §3 host gate (Task 9b): no baseline, no keys
    elif [ -n "$DESIRED" ] && [ "$DESIRED" != "$APPLIED" ]; then
      # THE BASELINE IS A RECEIPT, NEVER A COERCION (J4): pending_since is the nameSince the pending was
      # recorded on, and only a nameSince ABOVE it receipts. An absent or unreadable baseline is re-seeded
      # from the current observation and the cycle starts over - "0" would have let old pane text and a
      # bridge name that already reads desired pass as a receipt.
      _pending_for="$(bridge_gen_get "$STATE_DIR" "$NAME" pending_for 2>/dev/null)"
      PENDING_SINCE="$(bridge_gen_get "$STATE_DIR" "$NAME" pending_since 2>/dev/null)"
      _reseed=""; [ "$_pending_for" = "$DESIRED" ] || _reseed=1; case "$PENDING_SINCE" in ''|*[!0-9]*) _reseed=1 ;; esac
      if [ -n "$_reseed" ]; then
        rm -f "$RENAME_SUSPECT"
        # THE BASELINE IS THE RESERVATION (M4): it is written inside the same lock the gate ran under.
        if bridge_gen_write "$STATE_DIR" "$NAME" pending_for="$DESIRED" pending_since="$B_SINCE" rename_tries=0; then
          echo "session-supervisor: $NAME — rename pending for '$DESIRED' (baseline nameSince $B_SINCE); the cycle starts." >&2
        else
          echo "session-supervisor: $NAME — the rename baseline could not be written; no rename step this round." >&2
        fi
        _rn_skip=1     # the round that (re)seeds the baseline takes no further step: a receipt needs a baseline to advance past
      else _rn_skip=""; fi
      host_gate_unlock                     # the reservation is written; the rest of the cycle needs no lock
      printf '%s\n' "$DESIRED" > "$RENAME_PENDING" 2>/dev/null || true
      _rn_tries="$(bridge_gen_get "$STATE_DIR" "$NAME" rename_tries 2>/dev/null)"; case "${_rn_tries:-}" in ''|*[!0-9]*) _rn_tries=0 ;; esac
      _rn_key="$(bridge_suspect_key rename "$B_PID" "$B_BIRTH" "$PANE_TARGET" "$DESIRED" "$PENDING_SINCE")"
      # THE ACTION BOUNDARY RE-OBSERVES (J3, as H1): the B_* the round opened with are stale by now. The
      # receipt is judged on a FRESH observation of the same process in the same pane, and so is the type.
      # THE IMMEDIATE RECHECK IS pid + OS birth + pane + the vendor's procStart (spec §2; K2): the same
      # pid and birth with another procStart is a contradiction, and a contradiction types nothing.
      rename_same_process() { observe_row; [ "$B_ANS" = identified:managed ] && [ "$B_PID" = "$1" ] && [ "$B_BIRTH" = "$2" ] && [ "$B_PANE" = "$3" ] && [ "$B_PS" = "$4" ]; }
      _rn_pid="$B_PID"; _rn_birth="$B_BIRTH"; _rn_pane_id="$B_PANE"; _rn_ps="$B_PS"
      if [ -n "$_rn_skip" ]; then
        :
      elif ! rename_same_process "$_rn_pid" "$_rn_birth" "$_rn_pane_id" "$_rn_ps"; then
        rm -f "$RENAME_SUSPECT"; echo "session-supervisor: $NAME — the managed process changed between the round's observation and the rename step ($B_ANS, pid ${B_PID:-none}, procStart ${B_PS:-none}); nothing typed, nothing receipted." >&2
      else
        _rn_pane="$(tmuxc capture-pane -p -t "$PANE_TARGET" 2>/dev/null)"
        if rename_receipt_seen "$_rn_pane" "$DESIRED" && [ "$B_NAME" = "$DESIRED" ] && case "$B_SINCE" in ''|*[!0-9]*) false ;; *) [ "$B_SINCE" -gt "$PENDING_SINCE" ] ;; esac; then
          _now_s="$(date +%s 2>/dev/null)"; case "$_now_s" in ''|*[!0-9]*) _now_s="" ;; esac
          if [ -n "$_now_s" ] && bridge_gen_write "$STATE_DIR" "$NAME" applied="$DESIRED" applied_at="${_now_s}000" applied_nameSince="$B_SINCE" rename_tries=0 pending_for= pending_since=; then
            rm -f "$RENAME_PENDING" "$RENAME_SUSPECT"
            echo "session-supervisor: $NAME — rename receipted: pane and bridge both report '$DESIRED', nameSince advanced ($PENDING_SINCE -> $B_SINCE)." >&2
          else
            echo "session-supervisor: $NAME — the receipt for '$DESIRED' holds but could not be WRITTEN as applied; nothing cleared, next round retries the write." >&2
          fi
        elif rename_pane_busy "$_rn_pane"; then
          rm -f "$RENAME_SUSPECT"    # busy pane: never type; the two-round count restarts
        elif [ "$_rn_tries" -ge 5 ]; then
          rm -f "$RENAME_SUSPECT"
          echo "session-supervisor: $NAME — RENAME NOT CONFIRMED after $_rn_tries attempts: no full receipt for '$DESIRED'. The tile may carry a stale name; $RENAME_PENDING remains as the trace." >&2
        elif ! pane_foreground_is_managed "$PANE_TARGET" "$B_PID"; then
          rm -f "$RENAME_SUSPECT"
          echo "session-supervisor: $NAME — rename pending, but the managed pane's foreground is not the managed claude (command, tty and process group must all agree); not typing." >&2
        elif ! bridge_suspect_confirmed "$RENAME_SUSPECT" "$_rn_key"; then
          :                          # first sighting of exactly this rename: the next identical round types
        # THE LAST THREE READINGS BEFORE THE KEYS, IN THIS ORDER (K1): the fresh observation FIRST - it takes
        # time, and a foreground read before it would be stale by the time the keys leave - then the
        # foreground, then the OS birth, then send. Nothing is read between the birth and the keys.
        elif ! rename_same_process "$_rn_pid" "$_rn_birth" "$_rn_pane_id" "$_rn_ps"; then
          rm -f "$RENAME_SUSPECT"; echo "session-supervisor: $NAME — the managed process changed immediately before typing ($B_ANS, pid ${B_PID:-none}, procStart ${B_PS:-none}); nothing typed." >&2
        elif ! pane_foreground_is_managed "$PANE_TARGET" "$B_PID"; then
          rm -f "$RENAME_SUSPECT"; echo "session-supervisor: $NAME — the foreground changed during the final observation; not typing." >&2
        elif ! same_nonempty_sv "$(bridge_os_birth "$B_PID" 2>/dev/null)" "$B_BIRTH"; then
          rm -f "$RENAME_SUSPECT"    # the process changed under us between the observation and now
        else
          type_line "$PANE_TARGET" "/rename $DESIRED"; _rn_rc=$?
          rm -f "$RENAME_SUSPECT"
          case "$_rn_rc" in
            0|2) bridge_gen_write "$STATE_DIR" "$NAME" rename_tries=$(( _rn_tries + 1 )) || echo "session-supervisor: $NAME — the rename attempt could not be counted in the generation." >&2
                 [ "$_rn_rc" -eq 2 ] && echo "session-supervisor: $NAME — PARTIAL delivery: the /rename text reached the pane but Enter did not; counted as an attempt, NOT retried this round (a retry would double the input)." >&2 ;;
            *)   echo "session-supervisor: $NAME — send-keys failed; nothing reached the pane, no attempt counted." >&2 ;;
          esac
        fi
      fi
    else
      rm -f "$RENAME_SUSPECT" "$RENAME_PENDING"
    fi
  fi
  # RE-PING: a ping that arrived while the session was working was lost.
  #
  # send-keys against a busy session returns without error but is never seen —
  # the message lands in the queue and the sender believes it was delivered.
  # One session missed two messages that way 2026-08-11, and it was discovered
  # because a human asked "do you run a tmux ping too?", not because anything
  # alarmed.
  #
  # Supervision runs every third minute anyway and sees both things: if unread
  # mail is waiting AND the session sits at the prompt, ping again. Then no
  # luck is needed — the queue drains as soon as the receiver is idle, no
  # matter when the message arrived.
  #
  # NEVER pings a working session: writing into an ongoing conversation is
  # precisely the mistake the two-round rule below exists to avoid.
  INBOX="$HOME/.config/agent-bus/$NAME/inbox"
  UNACK_MARK="$STATE_DIR/$NAME.unacked-signalled"
  PING_MARK="$STATE_DIR/$NAME.pinged"
  if compgen -G "$INBOX/*.json" >/dev/null 2>&1; then
    # OLDEST UNREAD FIRST — it is the dedup key for BOTH signals below.
    OLDEST_TS=""; OLDEST_FILE=""
    for f in "$INBOX"/*.json; do
      [ -e "$f" ] || continue
      b="$(basename "$f")"; ts="${b%%-*}"
      case "$ts" in ''|*[!0-9]*) continue;; esac
      if [ -z "$OLDEST_TS" ] || [ "$ts" -lt "$OLDEST_TS" ]; then OLDEST_TS="$ts"; OLDEST_FILE="$b"; fi
    done
    # IF THE AGE COULD NOT BE DERIVED from any filename (a file outside the
    # convention <ts>-<from>-<pid>.json) ⇒ fall back to the first filename as
    # dedup key. Never empty: an empty key compares equal to a missing marker
    # file and makes the ping SILENT, which would be fixing a loop with a
    # silence. The age escalation below still requires a genuine OLDEST_TS.
    if [ -z "$OLDEST_FILE" ]; then
      for f in "$INBOX"/*.json; do
        [ -e "$f" ] || continue
        OLDEST_FILE="$(basename "$f")"; break
      done
    fi

    # ONE PING PER MESSAGE, NOT ONE PER ROUND. Without dedup this branch
    # pinged every third minute forever: one session measured 35 IDENTICAL
    # pings for ONE message 2026-08-17 and could not read, because the wake-up
    # looped. An alarm saying "I get pinged but do not read" is true while the
    # cause lies in the PING.
    #
    # Dedup on the oldest filename — the same mechanism the escalation below
    # already used. The purpose stands: a ping that was lost against a WORKING
    # session is sent when the session becomes idle, and NEW mail pings anew.
    # The ping text itself is the estate's PING_MSG, resolved at the top — a
    # constant the whole fleet compares exactly, never a literal here.
    # THE MARKER AGES. It records that the ping was SENT, never that it ARRIVED —
    # and keystrokes get lost, which is the whole reason the bus exists instead
    # of send-keys. The idle test is a heuristic: `grep "esc to interrupt"`. A
    # session can be working without showing that string. The ping then goes, the
    # keystrokes fall away while the marker is written, and the dedup — which
    # exists to avoid a ping storm — becomes permanent silence.
    #
    # MEASURED 2026-08-23: a session carried unread mail for 1628 minutes. The
    # marker was set, the inbox was not empty, and supervision ran silently every
    # three minutes for twenty-seven hours. What finally reached a human was the
    # session's OWN outgoing signal below — a fallback that happened to exist.
    #
    # So the marker now carries a timestamp and holds for a while only. The same
    # message is pinged again while it is still queued after BUS_REPING_AFTER_SEC.
    # A marker file WITHOUT a timestamp, written by an older version, reads as
    # expired: that shape must produce one extra ping, never eternal silence.
    _pm_file=""; _pm_ts=0
    if [ -r "$PING_MARK" ]; then
      read -r _pm_file _pm_ts < "$PING_MARK" 2>/dev/null || true
      case "${_pm_ts:-}" in ''|*[!0-9]*) _pm_ts=0 ;; esac
    fi
    _pm_age=$(( $(date +%s) - _pm_ts ))
    if [ "$OLDEST_FILE" != "$_pm_file" ] || [ "$_pm_age" -ge "${BUS_REPING_AFTER_SEC:-600}" ]; then
      # PANE-LEVEL COMMANDS TAKE THE PLAIN NAME, BEHIND THE EXACT GUARD. The
      # =form is a SESSION-target notation: has-session and list-panes accept
      # it, but capture-pane and send-keys parse their target as a pane and
      # answer "can't find pane: =x" — measured on tmux 3.4 and 3.6b
      # 2026-08-21, an hour after =everything was deployed; the suite's tmux
      # stub cannot see the difference. Plain is safe HERE because this branch
      # only runs for a session whose exact existence the alive check just
      # established, and tmux resolves an existing exact name before any
      # prefix match (also measured, against the sibling pair that found the
      # original trap).
      # ONE KEY BURST PER ROUND. The rename above and this ping typed into the
      # same pane tens of milliseconds apart on 2026-09-03; the rename's Enter
      # was lost and the ping text landed on the SAME input line — the
      # session was renamed to "<label> <ping text>". A round that already
      # typed stands down here: the mark is NOT written, so the next round
      # (three minutes later, the rename receipted or not) pings as usual.
      if [ -n "$TYPED_THIS_ROUND" ]; then
        echo "session-supervisor: $NAME has unread mail but the rename typed this round — ping deferred to the next round" >&2
      elif ! tmuxc capture-pane -p -t "$PANE_TARGET" 2>/dev/null | grep -q "esc to interrupt"; then
        type_line "$PANE_TARGET" "$PING_MSG" || echo "session-supervisor: $NAME — the re-ping did not fully reach the pane (type_line rc $?)" >&2
        printf '%s %s' "$OLDEST_FILE" "$(date +%s)" > "$PING_MARK"
        echo "session-supervisor: $NAME had unread mail and stood idle — pinged again" >&2
      fi
    fi

    # ESCALATION ON LONG-UNACKED MAIL — signal OUT, because the central guard
    # does not escalate here. The re-ping above pings the session forever but
    # never reaches a human. The hub machine's 15-min alarm skips accounts not
    # owned by the hub's principal (bound key, deliberate isolation) — so the
    # CLAUDE.md line "unacked mail is alarmed after 15 min" was false for
    # those accounts without this signal. Same OUT pattern as malformed, same
    # category one level up. Found by one session 2026-08-12. Age from the
    # FILENAME (<ts>-<from>-<pid>.json), no jq dependency. Dedup on the oldest
    # file's name (like the hub's busAlert): the same oldest message does not
    # spam, a new oldest alarms anew.
    if [ -n "$OLDEST_TS" ]; then
      AGE=$(( $(date +%s) - OLDEST_TS ))
      if [ "$AGE" -ge "${BUS_UNACK_ESCALATE_SEC:-900}" ] && [ "$OLDEST_FILE" != "$(cat "$UNACK_MARK" 2>/dev/null)" ]; then
        # THE FIRST LINE IS THE ENVELOPE (bus/lib.sh:bus_envelope_parse,
        # envelope v2) — bus_send now refuses every SEND without it. The
        # AUTO-ALERT line stays unchanged as the second line: no consumer
        # greps for it at a specific line position, only for occurrence. The
        # subject slug "okvitterad-post" is a live thread key — renaming it
        # would sever the thread on the hub, so it stays.
        UNACK_MSG="DRIFT okvitterad-post: $NAME has $(( AGE/60 )) min of unacked mail
AUTO-ALERT: unacked mail in my inbox for $(( AGE/60 )) min ($NAME on $(hostname -s)). I get pinged but do not read — the central guard does not escalate here (bound key), hence this outgoing signal."
        if bus_signalera "unacked mail" "$UNACK_MSG"; then
          printf '%s' "$OLDEST_FILE" > "$UNACK_MARK"
          echo "session-supervisor: $NAME signaled unacked mail ($(( AGE/60 ))m) to the hub" >&2
        fi
      fi
    fi
  else
    # Inbox emptied → reset the dedup marker, otherwise the next unacked
    # message with the same oldest filename is silent (the bug 7 lesson, same
    # form as malformed).
    rm -f "$UNACK_MARK" "$PING_MARK"
  fi

  # UNREADABLE MAIL IN malformed/ — signal OUTWARD, because the central guard
  # cannot see here. The hub's key into this account is bound to delivery
  # (when the account is not the hub operator's own), so the hub machine's
  # guard never inspects malformed/ here. But WE run as the owner on the host
  # and see it. A malformed file should never occur (the relay writes
  # atomically), so a single one is worth an outgoing signal to the hub, which
  # reaches a human. Found by one session 2026-08-12: the hub cannot read
  # here, therefore here must signal out. Dedup via a marker file so the same
  # finding does not spam every round.
  MALFORMED="$HOME/.config/agent-bus/$NAME/malformed"
  MF_MARK="$STATE_DIR/$NAME.malformed-signalled"
  if compgen -G "$MALFORMED/*.json" >/dev/null 2>&1; then
    MF_COUNT="$(find "$MALFORMED" -maxdepth 1 -name '*.json' 2>/dev/null | wc -l | tr -d ' ')"
    if [ "$MF_COUNT" != "$(cat "$MF_MARK" 2>/dev/null)" ]; then
      # THE FIRST LINE IS THE ENVELOPE, same reason as above.
      MF_MSG="DRIFT malformed: $MF_COUNT unreadable messages at $NAME
AUTO-ALERT: $MF_COUNT unreadable messages in my malformed/ ($NAME on $(hostname -s)). Should never happen — the relay writes atomically. The central guard does not see here (bound key), hence this outgoing signal."
      # A persistent send failure (key revoked, bus-send gone) must NOT be
      # silent — the marker is not written, so the next round retries, but
      # without a journal line there is no traceability at all. Found by one
      # session 2026-08-12. The line is now written by bus_signalera, which
      # moreover DISTINGUISHES our own refusal (rc 65/78, stderr passed
      # through) from a real send failure.
      if bus_signalera "$MF_COUNT malformed" "$MF_MSG"; then
        printf '%s' "$MF_COUNT" > "$MF_MARK"
        echo "session-supervisor: $NAME signaled $MF_COUNT malformed to the hub" >&2
      fi
    fi
  else
    # A CLEANED malformed/ RESETS THE MARKER. Without this branch an empty
    # directory skipped the whole block, the marker stayed at its old count,
    # and the next unreadable message with the same count was deduped away —
    # silent forever. The mjs version resets via count→0; the shell version
    # must do it explicitly, because an empty glob gives no loop to count in.
    # Bug 7, found by one session 2026-08-12: the memory of the report rotted
    # and the silence could not be told apart from "nothing happened".
    rm -f "$MF_MARK"
  fi
  exit 0
fi

# ── FROM HERE ON, EVERY PATH ENDS IN A SPAWN ───────────────────────────────
# The alive branch above has exited. What remains is the boot start, the zombie
# repair (which kills a pane only because a respawn follows it) and the start
# path itself -- so this is where "we are about to spawn" begins, and it is the
# last stop before the first tmux WRITE. A refusal taken here refuses the
# spawn and nothing else; a refusal taken after the kill would have turned a
# repair into a demolition.
#
# A DEPLOYED SUPERVISOR WITHOUT ITS SPAWN LIBRARY MUST NOT SPAWN LEGACY. The
# tempting fallback -- carry on with the command line this file used before the
# libraries existed -- is the exact failure lib/mcpspawn.sh was written to
# prevent, one level up: a session started with whatever its checkout's own
# .mcp.json declares, while the registry's grant was never consulted, and
# nothing anywhere says so. A failed timer is loud; that is not.
if [ "$MCP_REFUSAL" = "lib" ]; then
  echo "session-supervisor: $NAME — REFUSING to spawn: the spawn library is missing, unreadable or out of date ($_mcp_lib_missing)." >&2
  echo "session-supervisor: $NAME — without it the session's granted MCP set cannot be honored, and starting" >&2
  echo "session-supervisor: $NAME — on the legacy path would silently hand it whatever the checkout declares." >&2
  echo "session-supervisor: $NAME — deploy the product's lib/ to $_MCP_LIB_DIR. Supervision of a LIVE session" >&2
  echo "session-supervisor: $NAME — continues meanwhile; only the start is refused." >&2
  exit 78
fi
if [ "$MCP_REFUSAL" = "prepare" ]; then
  echo "session-supervisor: $NAME — REFUSING to spawn: the session's MCP set could not be prepared." >&2
  sed 's/^/  /' "$MCP_ERR" >&2
  echo "session-supervisor: $NAME — starting on the legacy path would hand the session whatever the" >&2
  echo "session-supervisor: $NAME — checkout declares, while the registry's own grant went unread." >&2
  exit 78
fi

# DOES CLAUDE EXIST AT ALL? A session whose binary is missing starts an empty
# shell that looks exactly like a live session: `tmux has-session` answers 0,
# the window stands there, and everything that measures on tmux reports UP —
# with nothing inside. Our own supervision is not fooled (it counts claude
# processes with pgrep), but it does something almost as bad: it restarts the
# shell every round, for all eternity, without anyone learning why.
#
# Discovered 2026-08-11 when one session got its supervision before its owner
# had had time to install Claude Code. The right behavior is to refuse to
# start and say why — a session waiting for its human is not an error to be
# masked with a restart loop.
# $CLAUDE_CMD carries arguments (--resume, --permission-mode ...) — test the
# BINARY, i.e. the first word. The first version of the guard ran -x on the
# whole string and stopped every session that had a thread to resume; the test
# suite fell from 14/0 to 8/6 and showed it immediately.
# AN EMPTY COMMAND IS REFUSED IN ITS OWN RIGHT, before the binary guard below
# can be fooled by it. ${CLAUDE_CMD%% *} of an empty string is empty, so
# CLAUDE_BIN becomes "$HOME/.local/bin/" and -x on a DIRECTORY is true: the
# guard would wave through a spawn of "$HOME/.local/bin/; exec bash". The
# declare -F check above is what should make this unreachable; this is the
# assertion that it stays unreachable.
ADAPTER=""
if [ "${RUNTIME:-claude-code}" = "opencode" ]; then
  # THE ADAPTER IS THE COMMAND. A missing adapter is refused here, before tmux,
  # for the same reason an empty claude command is: a spawn on a missing
  # program is a bare shell wearing this session's name.
  ADAPTER="$HOME/scripts/runtime/opencode-session.sh"
  if [ ! -x "$ADAPTER" ]; then
    echo "session-supervisor: $NAME — REFUSING to spawn: the OpenCode adapter is missing: $ADAPTER" >&2
    echo "session-supervisor: $NAME — deploy the product's runtime/ to this home; nothing is started until then." >&2
    exit 78
  fi
elif [ -z "$CLAUDE_CMD" ]; then
  echo "session-supervisor: $NAME — REFUSING to spawn: the claude command line came out empty." >&2
  echo "session-supervisor: $NAME — a spawn on an empty command starts a bare shell wearing this session's" >&2
  echo "session-supervisor: $NAME — name, which is the zombie pane this supervisor exists to repair." >&2
  exit 78
else
  CLAUDE_BIN="$HOME/.local/bin/${CLAUDE_CMD%% *}"
  if [ ! -x "$CLAUDE_BIN" ]; then
    echo "session-supervisor: $NAME not started — $CLAUDE_BIN is missing (the owner has not installed/logged in to Claude Code yet)" >&2
    exit 78
  fi
fi

# From here on we start something. ONE start path for both branches below:
# the boot start and the zombie respawn must count attempts, leave the launch
# mark and set the environment identically, or the next divergence hides in
# whichever branch a test did not exercise.
spawn_session() {
  ensure_workspace_trusted
  # THE ADAPTER OWNS ORPHANS FOR CLAUDE ROWS (identified:orphan, keyed, killed on the pin);
  # the pattern reap is the OpenCode path's, which finds its process by port.
  [ "$IS_CLAUDE" = 1 ] || reap_orphan_claude   # a killed tmux session may have left an orphaned adapter
  # FOR A CLAUDE ROW THE CLAIM COMES FIRST (H7): a refused claim must not count as a resume attempt, must
  # not leave a launch mark, and must not arm the rename - three refused claims would otherwise read as
  # three failed resumes and fork a fresh thread.
  if [ "$IS_CLAUDE" = 1 ]; then
    # ONE CRITICAL SECTION (M4): the gate and the claim that reserves the display are not two steps that
    # another supervisor can slip between.
    host_gate_lock; _hg=$?
    if [ "$_hg" -eq 1 ]; then
      echo "session-supervisor: $NAME — another supervisor holds the display reservation lock; not spawning this round." >&2
      return 0
    fi
    if [ -n "$RC_LABEL" ] && host_gate_refuses "$RC_LABEL" "spawn"; then host_gate_unlock; return 0; fi
    claude_claim_open || { host_gate_unlock; return 0; }
    host_gate_unlock
  fi
  rm -f "$SUSPECT"
  # The attempt is counted BEFORE the launch, so a resume that is refused can
  # never count itself; the loop protection above reads this file.
  [ -n "$SID" ] && printf '%s %s\n' "$SID" "$(( ${_tries:-0} + 1 ))" > "$RESUME_TRY"
  # WHAT WE LAUNCHED, for the survival round: the sid, or an empty line for a
  # fresh start. The alive branch turns this into last-sid (or clears it).
  printf '%s\n' "$SID" > "$LAUNCH_MARK"
  # EVERY OWN SPAWN RESTARTS THE RENAME CYCLE (see RENAME_PENDING at the top):
  # the entity keeps its registered name across restarts, so every (re)start
  # must end with the tile carrying the resolved label — driven by the alive
  # rounds, verified on the receipt line. Only a labeled session: an RC-free
  # one (empty label) has, by definition, no name to drive in.
  # NO RENAME CYCLE FOR OPENCODE: it has no /rename, and a keystroke typed into
  # a runtime that does not expect it is free text into a conversation.
  # SINCE TASK 6 pending is DERIVED every alive round from desired != applied (the generation's
  # `applied`); a spawn only resets the attempt counter. The trace file is written by the cycle itself.
  if [ "$IS_CLAUDE" = 1 ]; then bridge_gen_write "$STATE_DIR" "$NAME" rename_tries=0; fi
  if [ -n "$ADAPTER" ]; then
    tmuxc new-session -d -s "$NAME" -c "$REPO" "${CRED_ENV_ARGS[@]}" \
      "exec \"$ADAPTER\" \"$NAME\""
  else
    claude_claim_launch || return 0    # a failed launch is a failed spawn: nothing started, nothing to alarm about below
  fi
  # THE ALARM IS ON THE SPAWN PATH, AND ONLY THERE. A degraded or refused set
  # is a property of the session that was just STARTED, so it is signalled once
  # per start. Putting it on the every-round path instead would send the same
  # sentence to the hub four times an hour for as long as the asset stays
  # missing -- and an alarm nobody can act on faster than it arrives is an
  # alarm everybody learns to skip, which is how the unacked-mail escalation
  # above was nearly lost.
  #
  # AFTER the launch: the session starts either way. rc 1 means it starts with
  # part of its tools, rc 2 means it starts with none and knows it. Neither is
  # a reason to withhold the start; both are a reason to tell a human.
  if [ "${MCP_RC:-3}" -eq 1 ] || [ "${MCP_RC:-3}" -eq 2 ]; then
    # THE KEY IS THE RC PLUS THE RENDER'S OWN WORDS (see MCP_MARK at the top).
    # The diagnostics name the omitted assets, so hashing them is what makes
    # "the same degradation" and "a worse one" two different alarms; the rc is
    # carried in cleartext so a human reading the marker can see which of the
    # two outcomes was signalled.
    _mcp_key="$MCP_RC $(cksum < "$MCP_ERR" 2>/dev/null)"
    if [ "$_mcp_key" != "$(cat "$MCP_MARK" 2>/dev/null)" ]; then
      # THE FIRST LINE IS THE ENVELOPE (bus/lib.sh:bus_envelope_parse, envelope
      # v2) -- bus_send refuses every SEND without it. Same form as the two
      # signals above; the subject slug is the thread key on the hub.
      _mcp_why="the granted set was refused and the session started with NO MCP servers (strict, empty)"
      [ "$MCP_RC" -eq 1 ] && _mcp_why="part of the granted set was omitted and the session started without it"
      MCP_MSG="DRIFT mcp-set: $NAME spawned degraded
AUTO-ALERT: $_mcp_why ($NAME on $(hostname -s)). What the render said:
$(sed 's/^/  /' "$MCP_ERR" 2>/dev/null)"
      # THE MARKER IS WRITTEN ON THE RECEIPT, not on the attempt -- exactly
      # like the unacked-mail marker. A bus that refused the send has told
      # nobody, and a marker written anyway would make the next spawn treat
      # that silence as a delivery.
      if bus_signalera "the MCP set" "$MCP_MSG"; then
        printf '%s' "$_mcp_key" > "$MCP_MARK"
        echo "session-supervisor: $NAME signaled a degraded MCP set (rc $MCP_RC) to the hub" >&2
      fi
    else
      echo "session-supervisor: $NAME spawned with a degraded MCP set (rc $MCP_RC), already signaled to the hub -- not repeating it" >&2
    fi
  else
    # A SPAWN WHOSE SET IS WHOLE FORGETS. Otherwise the marker outlives the
    # degradation and the next one -- possibly a different asset entirely --
    # is compared against a condition that no longer exists.
    rm -f "$MCP_MARK"
  fi
}

if [ "$IS_CLAUDE" = 1 ]; then
  # THE ADAPTER ANSWERED (observe_row ran in runtime_identified above). Every destructive step
  # is a KEYED two-round suspect: the key carries the action and its exact target, and any
  # other answer in between resets it (B6, D5).
  case "$B_ANS" in
    identified:managed) : ;;
    identified:moved) rm -f "$SUSPECT"; echo "session-supervisor: $NAME — identified but MOVED (pid $B_PID, not under $B_PANE). Nothing written." >&2; exit 0 ;;
    unknown)
      rm -f "$SUSPECT"
      if [ "$B_GEN" = alive ] && [ ! -f "$STATE_DIR/$NAME.identity-degraded" ]; then
        touch "$STATE_DIR/$NAME.identity-degraded"
        echo "session-supervisor: $NAME — DEGRADED: our process lives but nothing attests it." >&2
      fi
      echo "session-supervisor: $NAME — identity-unknown ($B_CLASSES). Nothing written." >&2; exit 0 ;;
    grace|wait-veto) rm -f "$SUSPECT"; exit 0 ;;
    identified:orphan)
      _key="$(bridge_suspect_key reap "$B_PID" "$B_BIRTH")"
      bridge_suspect_confirmed "$SUSPECT" "$_key" || exit 0
      [ -x "$BKILL" ] || { echo "session-supervisor: $NAME — ORPHAN confirmed, but the kill helper is missing or not executable: $BKILL. Nothing signalled." >&2; exit 0; }
      reobserve_same identified:orphan "$_key" || exit 0                      # H1: the same orphan, immediately before the signal
      echo "session-supervisor: $NAME — ORPHAN confirmed twice (pid $B_PID, birth $B_BIRTH): signalling TERM on the pin." >&2
      "$BKILL" "$B_PID" "$B_BIRTH" TERM >&2; rm -f "$SUSPECT"; exit 0 ;;
    no-process)
      [ -z "${DISPLAY_ERR:-}" ] || { echo "session-supervisor: $NAME — REFUSING to spawn: the display does not derive: $DISPLAY_ERR" >&2; exit 78; }
      if [ -n "$RC_LABEL" ]; then                                    # spec §3 host gate (Task 9b), before the suspect is even keyed
        host_gate_lock; _hg=$?
        if [ "$_hg" -eq 1 ]; then echo "session-supervisor: $NAME — another supervisor holds the display reservation lock; nothing decided this round." >&2; exit 0; fi
        if host_gate_refuses "$RC_LABEL" "spawn"; then host_gate_unlock; rm -f "$SUSPECT"; exit 78; fi
        host_gate_unlock
      fi
      if [ -n "$B_TUPLE" ]; then _np_key="$(bridge_suspect_key close "$B_TUPLE")"; else _np_key="$(bridge_suspect_key spawn absent)"; fi
      bridge_suspect_confirmed "$SUSPECT" "$_np_key" || exit 0
      # THE MARKER STAYS while the debris gate below runs: its mtime is the gate's "first suspected
      # dead" log text, and the gate removes it itself before the close. The spawn-absent path
      # needs no gate and clears it here.
      NO_PROCESS_CONFIRMED=1; NP_TUPLE="$B_TUPLE"; [ -n "$NP_TUPLE" ] || rm -f "$SUSPECT" ;;
    *) echo "session-supervisor: $NAME — adapter answered '$B_ANS', unknown here. Nothing written." >&2; exit 0 ;;
  esac
  if [ -n "$NO_PROCESS_CONFIRMED" ]; then
    if [ -z "$NP_TUPLE" ]; then
      tmuxc has-session -t "=$NAME" 2>/dev/null && { rm -f "$SUSPECT"; echo "session-supervisor: $NAME — a tmux session appeared after 'spawn absent' was confirmed; resetting." >&2; exit 0; }
      reobserve_same no-process "spawn absent" || exit 0                      # H1: still nothing, immediately before the spawn
      spawn_session; exit 0
    fi
    : # tmux present: fall into the EXISTING activity/debris gate below, then the close by $N
  else
    exit 0    # a managed row that reached here has nothing more to do this round
  fi
else
  # No tmux at all (e.g. after boot): creating anew is risk-free — there is no
  # live session to write into. No two-round rule here.
  if ! tmuxc has-session -t "=$NAME" 2>/dev/null; then
    spawn_session
    exit 0
  fi

  # tmux exists but no claude matching the label. Before anything destructive:
  # does ANY runtime live in the pane? A claude under a drifted label, or an
  # opencode adapter, is a living conversation this supervisor cannot identify —
  # it must be neither killed nor typed into. Warn every round (the same posture
  # as warn_if_untrusted_while_running: an anomaly a human should fix, never a
  # silent one), and clear the suspect mark so the zombie verdict below always
  # rests on two CONSECUTIVE runtime-free rounds.
  if runtime_alive_in_session; then
    rm -f "$SUSPECT"
    echo "session-supervisor: $NAME — WARNING: a claude/opencode process lives in the session's pane but does not match this session's pattern." >&2
    echo "session-supervisor: $NAME — leaving it alone (no kill, no keystrokes). If the label changed, fix the conf; supervision cannot repair what it cannot identify." >&2
    exit 0
  fi

  # No runtime at all in a session that exists: suspect — but do NOTHING until
  # the next round says the same. The launch string ends '; exec bash', so a
  # session mid-boot and a session whose claude just died look identical for one
  # measurement; three extra minutes of downtime are cheaper than killing a
  # session that was about to come up.
  if [ ! -f "$SUSPECT" ]; then
    touch "$SUSPECT"
    exit 0
  fi
fi
# A WORKING HUMAN DEFERS THE KILL - AND A CLIENT IS NOT A HUMAN. A human
# working in vi or bash in the pane where claude crashed must never lose their
# editor to a repair; the old send-keys repair would have typed into their vim
# buffer, and this veto is the guard that replaced it. That direction is
# unchanged. What changed on 2026-09-09 is WHAT IT MEASURES.
#
# MEASURED ON A LIVE LINUX HOST 2026-09-09: the veto was
# `[ -n "$(tmuxc list-clients ...)" ]`, and an estate's hub session sat DEAD FOR
# TWO HOURS while this supervisor saw the zombie every round and refused to
# repair it. The "human" was an orphaned `script -qfc env -u TMUX tmux ...
# attach` whose parent chain ended at systemd --user, and which systemd had
# ALREADY logged as debris ("Found left-over process 4166896 (tmux: client) in
# control group while starting unit"). Its client_activity was 1788959854 =
# 13:17:34 - THE EXACT SECOND the session's runtime died. Debris from an
# earlier fault, holding the veto over the wreckage it came from.
#
# SO THE QUESTION IS ASKED OF THE CLIENT'S IDLENESS, NOT OF ITS EXISTENCE -
# AND IT IS ASKED AGAINST NOW. A client that touched a key less than
# HUMAN_GRACE_SEC ago is evidence of a human in that pane; one that has been
# silent for longer is not. Any single keystroke during the deferral re-arms
# the veto and keeps it armed for another full window, so a human who reaches
# for the keyboard outranks every other measurement here for as long as they
# keep doing it.
#
# NOT "NEWER THAN THE SUSPECT MARKER", WHICH IS WHAT THIS FILE ASKED FOR ONE
# ROUND ON 2026-09-09 AND WHICH DOES NOT CLOSE THE DEADLOCK. MEASURED, tmux
# 3.6b on an isolated socket: client_activity is set AT ATTACH, is NOT moved by
# pane output, and moves only on real client input.
#
#   attach   act=1788970347 now=1788970350   <- set at attach, no keystroke
#   pane output (send-keys echo)             <- act unchanged
#   keypress act=1788970356 now=1788970359   <- input, and only input, moves it
#
# The marker is never re-touched while the veto defers, and client_activity
# only grows. So a client that attaches AFTER the marker sorts newer than it
# FOREVER and holds the veto with no human anywhere and not one keystroke.
# That is the incident's own debris three minutes later: the `script ... tmux
# attach` wrapper happened to attach at the death second, and had it attached
# after, the ordering rule would have reproduced the two-hour hang WITHOUT END
# while printing "repair resumes the round after that client goes quiet".
# Idleness against now has no such fixed point - two hours of silence is two
# hours of silence, whatever the marker says.
#
# THE WINDOW IS 900 SECONDS, and both of its costs are bounded and logged:
#  - a genuinely dead session with a client attached waits at most one window
#    longer for its repair. Every deferral prints "idle Ns of 900s", so the
#    wait is readable rather than mysterious;
#  - a human idle LONGER than the window loses the pane. That is not a new
#    cost: the ordering rule killed that human sooner, since after 900s of
#    silence their last keypress is older than a marker written within one
#    timer period of the death.
# The width must comfortably exceed an ordinary reading pause - a diff, a phone
# call - and stay far under the two hours the deadlock cost. One supervision
# round (3 min) is too tight to read a diff in; an hour makes the deadlock
# cheap again. DELIBERATELY NOT AN ENVIRONMENT KNOB: the veto that protects
# humans is not a thing a caller may widen or a test may shrink.
#
# THE SUSPECT MARKER IS LOG TEXT NOW, NOT EVIDENCE. It still stands in for the
# death moment - the runtime is gone, so nothing can report when it exited -
# and the debris lines still say how far a client's last activity fell before
# or after it, because "its activity postdates the death by 180s" is what tells
# the next reader they are looking at an attach and not a keystroke. But no
# decision rests on it, so a marker mtime in the FUTURE (NTP correction, VM
# resume, an RTC-less host correcting at boot) is now cosmetic instead of
# fatal. #{session_activity} was considered and rejected as the input signal:
# it moves with any pane OUTPUT, including output a client's own redraw causes,
# so it can drift newer than a live human's last keypress. The marker errs the
# other way, but it is not harmless either: it lands up to one timer period
# (agent-session@.timer, OnUnitActiveSec=3min) PLUS the length of the round
# that wrote it after the true death, and a slow round widens that. Bounded, in
# the safe direction - not "cannot mislead".
#
# ANCESTRY IS REPORTED, AND NEVER DECIDES AGAINST A HUMAN. An attach whose
# parent chain reaches systemd --user is one the system itself has already
# called a left-over. That is evidence about PROVENANCE, and it is printed on
# every debris line so the journal names the ghost - but it never turns a
# client into debris on its own. A client with FRESH activity defers the kill
# even when it is orphaned, AND SO DOES A CLIENT WHOSE ACTIVITY CANNOT BE READ
# AT ALL: on any host with a console or desktop session a person's own terminal
# descends from the user manager too, so "orphaned and unmeasurable" describes
# a live human at a graphical login exactly as well as it describes a ghost.
#
# ON tmux < 2.9 THIS MEASUREMENT DOES NOTHING. There client_activity is a
# formatted date ("Tue Sep  9 13:17:34 2026"), not an epoch; _is_epoch rejects
# it, and every client falls into the unreadable case above. The veto is then
# exactly the pre-2026-09-09 existence check - the deadlock is not fixed on
# those hosts, and no human is at risk on them either. That is the honest
# degradation, and upgrading tmux is the only thing that changes it.
#
# AND ON A HOST WITH NO systemd --user - a container, a non-systemd distro -
# user_manager_pids answers nothing and ancestry is not measured at all. The
# fallback is activity alone, which is safe in direction; what must not happen
# is the journal asserting a negative it never measured, so the debris line
# says ancestry was not measured rather than "no orphan".
#
# DELIBERATELY NOT A ROUND CAP. The tempting fix is "after N deferrals, kill
# anyway". A ceiling that overrides a live human is precisely the failure this
# veto was built to prevent - it would have repaired the ghost, and it would
# also eventually type over somebody's editor. The fix is to measure the human
# correctly, not to time them out.
#
# A MEASUREMENT THAT FAILS IS NOT A MEASUREMENT OF NOTHING, AND THERE ARE TWO
# WAYS IT CAN FAIL. If the formatted listing comes back empty while a PLAIN one
# does not, this server will not take the -F at all. If it ANSWERS the -F but
# expands every field to the empty string, rows come back and none of them
# describes a client - and the loop below would then find neither a human to
# keep nor debris to name, print "every attached client is debris" naming
# nobody, and kill. Both would mean "no clients attached" and authorize the
# kill, and both are ways this change could kill something the old existence
# check protected. Both are checked explicitly and the old behavior kept:
# defer, loudly, naming the reason.
#
# THE WINDOW A CLIENT'S LAST KEYSTROKE MUST FALL INSIDE FOR IT TO BE EVIDENCE
# OF A HUMAN. Rationale, cost and why it is not configurable: above.
HUMAN_GRACE_SEC=900
CLIENT_FMT='#{client_tty}|#{client_activity}|#{client_pid}'
_clients="$(tmuxc list-clients -t "=$NAME" -F "$CLIENT_FMT" 2>/dev/null)"
if [ -z "$_clients" ] && [ -n "$(tmuxc list-clients -t "=$NAME" 2>/dev/null)" ]; then
  echo "session-supervisor: $NAME - ZOMBIE-shaped, but a tmux client is ATTACHED that this server will not describe" >&2
  echo "session-supervisor: $NAME - (list-clients -F '$CLIENT_FMT' answered nothing while a plain listing did) - deferring the kill." >&2
  echo "session-supervisor: $NAME - a human may be working in that window; an unreadable client is treated as one." >&2
  exit 0
fi
if [ -n "$_clients" ]; then
  _now="$(date +%s)"
  _death="$(_mtime_of "$SUSPECT")"   # log text only - see above; no verdict rests on it
  UM_PIDS="$(user_manager_pids)"
  _keep=""; _keep_why=""; _debris=""; _NL=$'\n'
  # THE SEPARATOR IS '|', NOT A SPACE. An empty field between two spaces is
  # eaten by `read` with whitespace IFS, and the pid would then be read as the
  # activity - a bare number, which compares perfectly well as a timestamp and
  # is wrong. None of tty, epoch or pid can contain a pipe.
  while IFS='|' read -r _ctty _cact _cpid _crest; do
    [ -n "$_ctty$_cact$_cpid" ] || continue
    _who="${_ctty:-(no tty)} (pid ${_cpid:-unknown})"
    _orphan=""; client_is_orphaned "$_cpid" && _orphan=1
    _left_over="its parent chain reaches systemd --user, which already logged it as a left-over process"
    # UNREADABLE ACTIVITY KEEPS THE VETO, ORPHAN OR NOT. This is the whole of
    # the tmux < 2.9 path and of any format that did not expand.
    if ! _is_epoch "$_cact"; then
      _why="its last activity could not be read"
      [ -n "$_orphan" ] && _why="$_why, and $_left_over - but ancestry never decides against a human"
      [ -z "$_keep" ] && { _keep="$_who"; _keep_why="$_why - the veto stands on what it cannot measure"; }
      continue
    fi
    # IDLENESS AGAINST NOW. A negative answer means the client's activity is
    # ahead of this host's clock; that is not staleness, and -lt keeps it a
    # human. A `date` that answered nothing lands in the same place - an empty
    # $_now is 0 in arithmetic, every client looks aeons ahead, and the veto
    # holds. So does a clock stepped BACKWARDS: it can only make a client look
    # fresher.
    #
    # THE ONE TURN THAT FALLS AGAINST THE HUMAN IS A FORWARD CLOCK CORRECTION
    # LARGER THAN THE WINDOW. This measurement trusts the host clock in the
    # forward direction, and it cannot do otherwise: a VM resumed after eight
    # hours really was idle eight hours, and telling that apart from a step
    # needs state carried across rounds. Measured 2026-09-09 with a `date` shim
    # answering now+3600: a human whose last keypress was 60s earlier reads as
    # silent for 3660s and loses the pane. Reachable on RTC-less hosts
    # correcting at boot and on VMs restored from a stale snapshot. It is
    # strictly narrower than the marker-mtime hazard it replaced - that one
    # killed EVERY client on ANY backward step, persistently, off a stale mtime
    # sitting on disk - and it SELF-HEALS: one keypress after the step
    # re-stamps activity from the corrected clock and the next round defers.
    # That is the whole of the exposure, and it is not worth cross-round state.
    # 10# ON EVERY EPOCH, BECAUSE THE ALTERNATIVE IS A FAIL-OPEN. _is_epoch
    # accepts any run of digits, and bash reads a leading-zero run as OCTAL:
    # 0888, 08 and 09 are invalid octal and an arithmetic EXPANSION error is
    # FATAL to this whole compound - the debris print below, the _keep deferral
    # and the empty-rows guard are all skipped, and execution resumes at the
    # kill. A value we merely failed to READ would then outrank a human we
    # measured. _is_epoch already guarantees a non-empty digit run, so 10#
    # cannot itself error, and nothing changes for a %s tmux ever renders.
    _idle=$(( _now - 10#$_cact ))
    if [ "$_idle" -lt "$HUMAN_GRACE_SEC" ]; then
      _why="was active ${_idle}s ago (idle ${_idle}s of ${HUMAN_GRACE_SEC}s)"
      [ -n "$_orphan" ] && _why="$_why (it is an orphan of systemd --user, but activity outranks ancestry)"
      [ -z "$_keep" ] && { _keep="$_who"; _keep_why="$_why"; }
      continue
    fi
    _why="it has been silent for ${_idle}s, past the ${HUMAN_GRACE_SEC}s grace"
    if _is_epoch "$_death"; then
      if [ "$_cact" -gt "$_death" ]; then
        _why="$_why (its last activity was $(( 10#$_cact - 10#$_death ))s after this session was first suspected dead - an attach, then nothing)"
      else
        _why="$_why (its last activity was $(( 10#$_death - 10#$_cact ))s before this session was first suspected dead)"
      fi
    fi
    if [ -n "$_orphan" ]; then
      _why="$_why, and $_left_over"
    elif [ -z "$UM_PIDS" ]; then
      _why="$_why (no systemd --user on this host: ancestry was not measured)"
    fi
    _debris="${_debris:+$_debris$_NL}session-supervisor: $NAME - attached tmux client $_who is not a working human: $_why."
  done <<EOF
$_clients
EOF
  [ -n "$_debris" ] && printf '%s\n' "$_debris" >&2
  if [ -n "$_keep" ]; then
    # THE WORD "ATTACHED" IS LOAD-BEARING, NOT DECORATION. Every deferral line
    # this veto prints says a client is ATTACHED, in that word, because that is
    # what an operator greps the journal for when a session will not repair
    # itself - and an estate's own supervision suite asserts it on this line.
    # The concrete naming below (tty, pid, why) is what the 2026-09-09 incident
    # lacked; the word is what it had. Keep both. test/supervisor-zombie-veto
    # claim 17 pins it on all three deferral paths.
    echo "session-supervisor: $NAME - ZOMBIE-shaped, but an ATTACHED tmux client $_keep $_keep_why - deferring the kill." >&2
    # HOW LONG THIS HAS BEEN GOING ON, ON ONE LINE. The residual this veto
    # cannot close is a wrapper that re-attaches every round: each attach is a
    # genuinely new client with created == activity == now, which is exactly a
    # human who has just attached and not yet typed. Nothing distinguishes
    # them, and a round cap that overrode the veto is refused above. So do not
    # guard - ANNOUNCE. The marker's age is already measured for the debris
    # text and costs nothing here, and it turns a silent indefinite hang into a
    # line that says how long it has been hanging. That is precisely what the
    # incident cost: two hours in which nobody knew. If more is ever wanted,
    # ALARM on a long deferral; never kill on one.
    if _is_epoch "$_death"; then
      echo "session-supervisor: $NAME - it has been ZOMBIE-shaped for $(( _now - 10#$_death ))s and the veto has deferred throughout." >&2
    fi
    echo "session-supervisor: $NAME - a human may be working in that window; repair resumes the first round after that client has been silent for ${HUMAN_GRACE_SEC}s, or the round after it detaches." >&2
    exit 0
  fi
  if [ -z "$_debris" ]; then
    echo "session-supervisor: $NAME - ZOMBIE-shaped, with tmux clients ATTACHED whose rows could not be read as clients" >&2
    echo "session-supervisor: $NAME - (list-clients -F '$CLIENT_FMT' expanded every field to nothing) - deferring the kill." >&2
    echo "session-supervisor: $NAME - measuring nobody while rows came back is not a measurement of nobody; a human may be working in that window." >&2
    exit 0
  fi
  echo "session-supervisor: $NAME - every attached client is debris, not a working human - the veto measures IDLENESS against now, not existence." >&2
fi
rm -f "$SUSPECT"
# TWO ROUNDS WITHOUT A RUNTIME: the pane is a bare shell wearing a live
# session's name. Measured 2026-08-31: seven sessions sat like this for ~6
# hours — claude had exited, '; exec bash' kept the pane alive, has-session
# kept answering yes, and bus pings were typed into bash as syntax errors,
# with zero alarms. The old repair here was send-keys into that shell — the
# same lossy keystroke path. Kill the zombie LOUDLY, by name, and respawn
# through the one start path (which resumes the thread exactly like any other
# restart).
if [ "$IS_CLAUDE" = 1 ]; then
  [ -n "$NO_PROCESS_CONFIRMED" ] || { echo "session-supervisor: $NAME — reached the close without a confirmed no-process; not closing." >&2; exit 0; }
  # THE TARGET IS THE PARSED $N, NEVER THE NAME (E4): a session created under this name after
  # the tuple was confirmed is a stranger, and `-t "=$NAME"` would have killed it. The tuple is
  # re-read HERE, immediately before the close (D5); a receipt is written only after kill-session
  # returned 0 AND the id is gone (E3, D12) - and a spawn follows only a receipt.
  NP_N="${NP_TUPLE%%:*}"; case "$NP_N" in \$*) : ;; *) NP_N="" ;; esac
  case "${NP_N#\$}" in ''|*[!0-9]*) rm -f "$SUSPECT"; echo "session-supervisor: $NAME — tuple has no usable session id; not closing." >&2; exit 0 ;; esac
  _now="$(tmuxc display-message -p -t "=$NAME" '#{session_id}:#{session_created}' 2>/dev/null)"
  [ "$_now" = "$NP_TUPLE" ] || { rm -f "$SUSPECT"; echo "session-supervisor: $NAME — tmux tuple changed before close ($NP_TUPLE is now ${_now:-gone}); resetting." >&2; exit 0; }
  echo "session-supervisor: $NAME — NO PROCESS confirmed twice under $NP_TUPLE: closing $NP_N and respawning." >&2
  reobserve_same no-process "$(bridge_suspect_key close "$NP_TUPLE")" || exit 0   # H1: still no process, immediately before the close
  bridge_gen_write "$STATE_DIR" "$NAME" stop_intent="zombie-$(date +%s)" \
    || { echo "session-supervisor: $NAME — the stop intent could not be written; not closing (H3)." >&2; exit 0; }
  if tmuxc kill-session -t "$NP_N" 2>/dev/null && ! tmuxc has-session -t "$NP_N" 2>/dev/null; then
    if bridge_gen_write "$STATE_DIR" "$NAME" stop_receipt="zombie-$(date +%s)"; then spawn_session; exit 0; fi
    echo "session-supervisor: $NAME — $NP_N is closed but the receipt could not be written; NO spawn without a receipt (D12). The next round sees no-process and takes the two-round path again." >&2
    exit 0
  fi
  echo "session-supervisor: $NAME — close of $NP_N did not verifiably succeed; no receipt, no spawn." >&2; exit 0
fi
echo "session-supervisor: $NAME — ZOMBIE PANE: tmux session '$NAME' exists but no claude/opencode process descends from its pane, two rounds in a row." >&2
echo "session-supervisor: $NAME — killing the zombie session and respawning." >&2
tmuxc kill-session -t "=$NAME" 2>/dev/null
spawn_session
exit 0
