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
HIST="$HOME/.claude/projects/$(printf '%s' "$REPO" | sed 's|[^a-zA-Z0-9]|-|g')"
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
if grep -q '^RC_LABEL=' "$CONF" 2>/dev/null; then
  RC_LABEL="$(sed -n 's/^RC_LABEL="\(.*\)"/\1/p' "$CONF" | head -1)"
else
  RC_LABEL="$(registry_session_display "$NAME" 2>/dev/null)" || RC_LABEL=""
  [ -n "$RC_LABEL" ] || RC_LABEL="$RC_PREFIX$NAME"
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
if [ -n "$_mcp_lib_missing" ]; then
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
if [ -z "$MCP_REFUSAL" ]; then
  CLAUDE_CMD="$(mcp_claude_cmd_fragment "$CONT" "$MCP_ARG" "$NAME_ARG" "$RC_LABEL")"
fi

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
if [ -n "$RC_LABEL" ]; then
  RC_LBL_PAT="$(printf '%s' "$RC_LABEL" | sed 's/[][\\.^$*+?(){}|]/\\&/g')"
  CLAUDE_PAT="^[^ ]*claude .*[-]-remote-control .?$RC_LBL_PAT\"?\$"
else
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
is_descendant() {
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
# Reap orphans BEFORE starting anew — otherwise the old claude keeps running
# beside the new one, two processes with the same RC label and a
# remote-control conflict. Only meaningful when no tmux session exists; with a
# live session the process belongs to it and is left alone (that is the
# suspect flow's responsibility).
# DEPLOY-DAY RUNBOOK: do a ONE-TIME per-host read-only sweep for
# --remote-control-labeled claudes running OUTSIDE the declared socket before
# turning this supervisor on. This reap matches on the label alone (there is
# no pane to bind to when no tmux session exists), so a same-label claude
# living in an abandoned default-socket homonym session would be shot as an
# orphan here. The sweep finds those before the first round can.
reap_orphan_claude() {
  tmuxc has-session -t "=$NAME" 2>/dev/null && return 0
  local pid
  # STEWARD_KILL overrides only in the test — kill is a bash builtin and
  # cannot be stubbed via PATH, so the test aims it at a script of its own.
  # The default is empty; then the builtin kill runs for real.
  for pid in $(matching_claude_pids); do
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
CLAUDE_JSON="$HOME/.claude.json"
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

if claude_alive_in_session; then
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
  # AUTO-RENAME AFTER A SPAWN THIS SUPERVISOR PERFORMED (see RENAME_PENDING at
  # the top for why the tile name goes stale). spawn_session wrote the pending
  # file; this branch drives the rename one step per timer round, on a session
  # the alive check just confirmed. The label is the round's already-resolved
  # RC_LABEL — the single source, no re-derivation. Attempts are bounded:
  # exhaustion is LOUD every round and leaves the pending file as the trace —
  # a stale tile name must never be silent, and must never block the session.
  # An RC-free session (empty label) has no name to drive in and is skipped.
  if [ -n "$RC_LABEL" ] && [ -f "$RENAME_PENDING" ]; then
    _rn_tries=""
    IFS=' ' read -r _rn_tries _ < "$RENAME_PENDING" 2>/dev/null || true
    case "${_rn_tries:-}" in ''|*[!0-9]*) _rn_tries=0 ;; esac
    # Pane-level commands take the PLAIN name behind the exact-alive guard —
    # the same measured rule as the re-ping below (capture-pane and send-keys
    # refuse the =form on tmux 3.4 and 3.6b).
    _rn_pane="$(tmuxc capture-pane -p -t "$NAME" 2>/dev/null)"
    case "$_rn_pane" in
      *"Session renamed to: $RC_LABEL"*)
        # The receipt — the ONLY thing that clears the pending file. Exact
        # string match on the whole label (spaces and arrows verbatim), never
        # a regex: a truncated or prefix receipt must not count.
        rm -f "$RENAME_PENDING"
        echo "session-supervisor: $NAME — rename receipt verified: the tile now carries '$RC_LABEL'" >&2
        ;;
      *)
        if rename_pane_busy "$_rn_pane"; then
          : # busy pane: never type — the round burns no attempt, retry next round
        elif [ "$_rn_tries" -ge 5 ]; then
          echo "session-supervisor: $NAME — RENAME NOT CONFIRMED after $_rn_tries attempts: no receipt 'Session renamed to: $RC_LABEL' in the pane." >&2
          echo "session-supervisor: $NAME — the tile may carry a stale name. $RENAME_PENDING remains as the trace; later rounds keep watching for the receipt." >&2
        elif ! claude_alive_in_session; then
          # RE-ASSERT CLAUDE-IN-PANE IMMEDIATELY BEFORE TYPING. The alive-check
          # far above ran before warn_if_untrusted_while_running spawned jq
          # (tens of ms); the launch string ends "; exec bash", so if claude
          # exited in that window the pane is now a SHELL, and RC_LABEL is free
          # conf text. A hostile label typed into bash EXECUTES (proven with a
          # canary in review). The busy predicate cannot tell a bash prompt
          # from an idle claude, so this re-check is the only thing standing
          # between a conf line and a shell. No claude descendant now -> skip;
          # a later round retries once the session is genuinely up.
          : # zombie/bash pane: never type a conf-derived label into a shell
        else
          tmuxc send-keys -t "$NAME" -l "/rename $RC_LABEL" 2>/dev/null
          tmuxc send-keys -t "$NAME" Enter 2>/dev/null
          printf '%s %s\n' "$(( _rn_tries + 1 ))" "$RC_LABEL" > "$RENAME_PENDING"
        fi
        ;;
    esac
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
      if ! tmuxc capture-pane -p -t "$NAME" 2>/dev/null | grep -q "esc to interrupt"; then
        tmuxc send-keys -t "$NAME" -l "$PING_MSG" 2>/dev/null
        tmuxc send-keys -t "$NAME" Enter 2>/dev/null
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
if [ -z "$CLAUDE_CMD" ]; then
  echo "session-supervisor: $NAME — REFUSING to spawn: the claude command line came out empty." >&2
  echo "session-supervisor: $NAME — a spawn on an empty command starts a bare shell wearing this session's" >&2
  echo "session-supervisor: $NAME — name, which is the zombie pane this supervisor exists to repair." >&2
  exit 78
fi
CLAUDE_BIN="$HOME/.local/bin/${CLAUDE_CMD%% *}"
if [ ! -x "$CLAUDE_BIN" ]; then
  echo "session-supervisor: $NAME not started — $CLAUDE_BIN is missing (the owner has not installed/logged in to Claude Code yet)" >&2
  exit 78
fi

# From here on we start something. ONE start path for both branches below:
# the boot start and the zombie respawn must count attempts, leave the launch
# mark and set the environment identically, or the next divergence hides in
# whichever branch a test did not exercise.
spawn_session() {
  ensure_workspace_trusted
  reap_orphan_claude   # a killed tmux session may have left an orphaned claude
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
  if [ -n "$RC_LABEL" ]; then
    printf '%s %s\n' 0 "$RC_LABEL" > "$RENAME_PENDING"
  fi
  tmuxc new-session -d -s "$NAME" -c "$REPO" "${CRED_ENV_ARGS[@]}" \
    "$HOME/.local/bin/$CLAUDE_CMD; exec bash"
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
# AN ATTACHED CLIENT DEFERS THE KILL. A human working in vi or bash in the
# pane where claude crashed must never lose their editor to a repair — the
# old send-keys repair would have typed into their vim buffer; this makes the
# missing guard explicit instead. While any client is attached we warn loudly
# and keep the suspect cadence (the marker stays, so the round after the
# client detaches kills without a fresh grace round). The cost is accepted: a
# stale forgotten attachment blocks repair with loud warnings — the
# false-ALIVE direction this design already accepts everywhere else.
if [ -n "$(tmuxc list-clients -t "=$NAME" 2>/dev/null)" ]; then
  echo "session-supervisor: $NAME — ZOMBIE-shaped, but a tmux client is ATTACHED to session '$NAME' — deferring the kill." >&2
  echo "session-supervisor: $NAME — a human may be working in that window; repair resumes the round after the client detaches." >&2
  exit 0
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
echo "session-supervisor: $NAME — ZOMBIE PANE: tmux session '$NAME' exists but no claude/opencode process descends from its pane, two rounds in a row." >&2
echo "session-supervisor: $NAME — killing the zombie session and respawning." >&2
tmuxc kill-session -t "=$NAME" 2>/dev/null
spawn_session
exit 0
