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
REG_LIB="${STEWARD_REGISTRY_LIB:-$HOME/scripts/lib/registry.sh}"
_reg_ok=""
if [ -f "$REG_LIB" ]; then
  # shellcheck source=/dev/null
  . "$REG_LIB" 2>/dev/null && _reg_ok=1
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
CONF="$HOME/scripts/sessions.d/$NAME.conf"
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
HIST="$HOME/.claude/projects/$(printf '%s' "$REPO" | sed 's|/|-|g')"
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
_latest="$(python3 - "$HIST" <<'PY' 2>/dev/null
import glob, json, os, sys
best = (None, None)   # (timestamp, path)
for f in glob.glob(os.path.join(sys.argv[1], "*.jsonl")):
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
    if newest and (best[0] is None or newest > best[0]):
        best = (newest, f)
if best[1]:
    print(best[1])
PY
)"
# Last resort if python3 is missing or no line carried a timestamp: the
# filesystem. Worse, but better than starting clean and forking.
if [ -z "$_latest" ]; then
  _latest="$(ls -t "$HIST"/*.jsonl 2>/dev/null | head -1)"
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

CLAUDE_CMD="claude $CONT --permission-mode bypassPermissions --remote-control \"$RC_PREFIX$NAME\""

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
# The same environment as a prefix on the command line, for the send-keys
# path: there is no new pane to set environment on — the shell is already
# alive and carries the server's environment. A VAR=value prefix applies only
# to the started process, which is exactly what we want.
CRED_ENV_PREFIX="$(printf 'CRED_HOME=%q AZURE_CONFIG_DIR=%q GH_CONFIG_DIR=%q CLOUDSDK_CONFIG=%q ' \
  "$CRED_HOME" "$AZURE_CONFIG_DIR" "$GH_CONFIG_DIR" "$CLOUDSDK_CONFIG")"

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
RC_PAT="$(printf '%s' "$RC_PREFIX" | sed 's/[][\\.^$*+?(){}|]/\\&/g')"
CLAUDE_PAT="^[^ ]*claude .*[-]-remote-control .?$RC_PAT$NAME"

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
session_pane_pid()     { tmux list-panes -t "$NAME" -F '#{pane_pid}' 2>/dev/null | head -1; }
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
  local pane; pane="$(session_pane_pid)"
  [ -n "$pane" ] || return 1   # no tmux session -> no live session, period
  local pid
  for pid in $(matching_claude_pids); do
    is_descendant "$pid" "$pane" && return 0
  done
  return 1
}
# Reap orphans BEFORE starting anew — otherwise the old claude keeps running
# beside the new one, two processes with the same RC label and a
# remote-control conflict. Only meaningful when no tmux session exists; with a
# live session the process belongs to it and is left alone (that is the
# suspect flow's responsibility).
reap_orphan_claude() {
  tmux has-session -t "$NAME" 2>/dev/null && return 0
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
  # ...but "alive" is not "able to work". See the comment at
  # ensure_workspace_trusted: a session waiting at the trust prompt is a live
  # process accomplishing zero, and without this line it looks like any
  # healthy session.
  warn_if_untrusted_while_running
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
    if [ "$OLDEST_FILE" != "$(cat "$PING_MARK" 2>/dev/null)" ]; then
      if ! tmux capture-pane -p -t "$NAME" 2>/dev/null | grep -q "esc to interrupt"; then
        tmux send-keys -t "$NAME" -l "$PING_MSG" 2>/dev/null
        tmux send-keys -t "$NAME" Enter 2>/dev/null
        printf '%s' "$OLDEST_FILE" > "$PING_MARK"
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
CLAUDE_BIN="$HOME/.local/bin/${CLAUDE_CMD%% *}"
if [ ! -x "$CLAUDE_BIN" ]; then
  echo "session-supervisor: $NAME not started — $CLAUDE_BIN is missing (the owner has not installed/logged in to Claude Code yet)" >&2
  exit 78
fi

# From here on we start something. Count the attempt so the loop protection
# above can trigger.
[ -n "$SID" ] && printf '%s %s\n' "$SID" "$(( ${_tries:-0} + 1 ))" > "$RESUME_TRY"

# No tmux at all (e.g. after boot): creating anew is risk-free — there is no
# live session to write into. No two-round rule here.
if ! tmux has-session -t "$NAME" 2>/dev/null; then
  ensure_workspace_trusted
  reap_orphan_claude   # a killed tmux session may have left an orphaned claude
  rm -f "$SUSPECT"
  tmux new-session -d -s "$NAME" -c "$REPO" "${CRED_ENV_ARGS[@]}" \
    "$HOME/.local/bin/$CLAUDE_CMD; exec bash"
  exit 0
fi

# tmux exists but no claude process: suspect — but write NOTHING until the
# next round says the same. Three extra minutes of downtime are cheaper than a
# command line injected into a live conversation.
if [ ! -f "$SUSPECT" ]; then
  touch "$SUSPECT"
  exit 0
fi
rm -f "$SUSPECT"
tmux send-keys -t "$NAME" -l "$CRED_ENV_PREFIX$CLAUDE_CMD" 2>/dev/null
tmux send-keys -t "$NAME" Enter 2>/dev/null
exit 0
