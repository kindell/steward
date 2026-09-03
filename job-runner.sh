#!/bin/bash
# job-runner.sh: executes ONE registered job (claude or command kind) with the
# mechanics a domain's own nightly-job script had already earned the hard way
# (2026-07):
#   - env: source $REPO_PATH/.env ONLY (op hangs in launchd spawn contexts on
#     this box — NEVER call op here). Perms/owner checked, staleness warned.
#   - watchdog: own process group, TERM then KILL after TIMEOUT_MIN (macOS has
#     no timeout(1) and coreutils is not installed). PRE_CMD and POST_CMD run
#     INSIDE this same watched window so a hung hook can never wedge the job.
#   - pid-lock per job: a still-running instance means skip (guards manual runs;
#     launchd already serializes per label).
# Usage: job-runner.sh <domain> <job>
# Confs are the installer's snapshots in ~/scripts/jobs.d/<domain>-<job>.conf
# (STEWARD_JOBS_SNAPSHOT_DIR overrides, for tests).
set -uo pipefail
here="$(CDPATH= cd -- "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# THE REGISTRY IS RESOLVED, NOT ASSUMED TO BE A SIBLING. In the deployed image
# both files land in ~/scripts/, so "$here/lib/registry.sh" held for as long as
# they shared a checkout. They no longer do: this file lives in the product and
# the registry does not (yet). STEWARD_REGISTRY_LIB is the same override every
# other file in this set uses.
REG_LIB="${STEWARD_REGISTRY_LIB:-$here/lib/registry.sh}"
# shellcheck source=/dev/null
source "$REG_LIB" || { echo "FATAL: cannot load the registry library: $REG_LIB" >&2; exit 1; }

domain="${1:?usage: job-runner.sh <domain> <job>}"
job="${2:?usage: job-runner.sh <domain> <job>}"
# ONE NAME. An earlier revision also read a predecessor variable that carried an
# estate's name, so existing callers would not silently read the WRONG directory
# and report "conf missing" — a refusal pointing at the wrong cause. That
# compatibility belongs in the ESTATE, not here: a published product cannot carry
# somebody's old namespace, and the estate that needs the bridge can export the
# supported name from its own units.
SNAP="${STEWARD_JOBS_SNAPSHOT_DIR:-$here/jobs.d}"
conf="$SNAP/$domain-$job.conf"
registry_job_load "$conf" || { echo "FATAL: cannot load job conf $conf" >&2; exit 64; }

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"; }
EXIT_SUFFIX=""

# LOCK: pid-file per job (named from argv $domain/$job — the registry-derived
# JOB_NAME/DOMAIN are the doubled "<domain>-<job>" basename of the snapshot conf
# and are wrong for naming here). The single EXIT trap below fires on EVERY exit
# path from here on (lock-skip, cd-failure, pre-abort, success) so the
# fleet-parseable "=== domain/job exit N ===" marker is always written; it also
# removes OUR lock, guarded by pid match so a lock-skip exit never deletes the
# still-running instance's lock file. (bash has exactly one EXIT trap, so
# lock-cleanup and marker-logging must live in the same trap.)
LOCK="${TMPDIR:-/tmp}/agent-job-$domain-$job.pid"
trap 'rc_final=$?; [ "$(cat "$LOCK" 2>/dev/null)" = "$$" ] && rm -f "$LOCK"; log "=== $domain/$job exit $rc_final ===${EXIT_SUFFIX}"' EXIT
if [ -f "$LOCK" ] && kill -0 "$(cat "$LOCK" 2>/dev/null)" 2>/dev/null; then
  log "previous instance still running (pid $(cat "$LOCK")) — skipping"
  EXIT_SUFFIX=" (lock-skip)"
  exit 0
fi
echo $$ > "$LOCK"

cd "$REPO_PATH" || { log "FATAL: cannot cd $REPO_PATH"; exit 66; }

# BUS_FROM: a headless job has no tmux pane, so bus-send fell back on "unknown".
# On the night of 2026-08-05 a review arrived on the bus with from=unknown asking
# for changes to an approval path. The sender was a legitimate nightly build, but
# there was no way to know that from the message.
#
# Set HERE rather than per skill: an instruction every job must remember will
# sooner or later not be remembered.
#
# The name is the JOB's, not the domain's ("<domain>-<job>"), because that is the
# honest answer to "who wrote this". A reply goes to the domain's session, which
# is the first element — bus_send validates only the RECIPIENT, so a sender name
# need not itself be a valid recipient.
export BUS_FROM="$domain-$job"

log "=== $domain/$job start (kind=$KIND, timeout=${TIMEOUT_MIN}m) ==="

# Env: .env is materialized at boot by the session supervisor's op inject.
# JOB_ENV_FILE: the secret source may live OUTSIDE the job's cwd. Reading Bash
# commands inside the working directory are auto-approved (root cause verified
# 2026-08-02: cat inside the repo leaked 5/5 and 3/3, touch inside was blocked
# 3/3 with identical flags, cat outside was blocked 3/3). No permissions list
# therefore protects a file under cwd — the target has to move. Unset =>
# REPO_PATH/.env as before.
ENV_FILE="${JOB_ENV_FILE:-$REPO_PATH/.env}"
if [ -f "$ENV_FILE" ]; then
  # PORTABLE STAT: BSD (macOS) and GNU (Linux) have incompatible flags, and this
  # runner now runs on both. Without this the .env check fails on Linux —
  # silently, because the error is hidden by the test that follows.
  if stat -f '%Lp' "$ENV_FILE" >/dev/null 2>&1; then
    ENV_STAT=$(stat -f '%Lp %u %m' "$ENV_FILE")          # BSD/macOS
  else
    ENV_STAT=$(stat -c '%a %u %Y' "$ENV_FILE")           # GNU/Linux
  fi
  ENV_PERMS=$(echo "$ENV_STAT" | awk '{print $1}')
  ENV_OWNER=$(echo "$ENV_STAT" | awk '{print $2}')
  ENV_AGE_DAYS=$(( ($(date +%s) - $(echo "$ENV_STAT" | awk '{print $3}')) / 86400 ))
  if [ "$ENV_OWNER" = "$(id -u)" ] && echo "$ENV_PERMS" | grep -qE '^0?[0-7]00$'; then
    [ "$ENV_AGE_DAYS" -gt 14 ] && log "WARNING: .env is $ENV_AGE_DAYS days old — restart the session/machine if secrets rotated"
    if [ -n "${JOB_ENV_KEYS:-}" ]; then
      # LEAST PRIVILEGE (objection raised 2026-08-02): a pattern-based allow list
      # prevents `cat .env`, but NOT an allowed command from reading keys it has
      # INHERITED. With JOB_ENV_KEYS set only the named keys are exported — the
      # rest of the vault never reaches the job's environment. Unset => the whole
      # .env as before (backwards compatible).
      while IFS='=' read -r _k _v; do
        case "$_k" in ''|\#*) continue ;; esac
        [[ "$_k" =~ ^[A-Z_][A-Z0-9_]*$ ]] || continue
        # THE SEPARATOR IS FORGIVING: comma OR whitespace. TOOLS accepts both
        # (measured 2026-08-02), so a conf author reasonably generalises to here —
        # and a key list that silently matches ZERO keys yields a job without
        # secrets that exits 0. Exactly the silent functional death this design
        # exists to prevent. The first conf written by hand used whitespace.
        case " ${JOB_ENV_KEYS//,/ } " in
          *" $_k "*) _v="${_v%\"}"; _v="${_v#\"}"; export "$_k=$_v" ;;
        esac
      done < "$ENV_FILE"
      log "env: JOB_ENV_KEYS set — only [$JOB_ENV_KEYS] exported from .env"
    else
      set -a
      # shellcheck disable=SC1091
      source "$ENV_FILE"
      set +a
    fi
  else
    log "WARNING: .env has unsafe owner/perms ($ENV_PERMS) — ignoring it"
  fi
else
  log "WARNING: $ENV_FILE missing — running without repo secrets"
fi

# Build the main command.
# The STABLE claude path before the versioned symlink: on macOS, TCC keys App
# Data Protection / Full Disk Access on the RESOLVED path, so
# ~/.local/bin/claude -> versions/<ver> loses the grant on every upgrade.
# Falls back to the symlink when no pinned path exists (never worse than before).
CLAUDE_BIN="${STEWARD_CLAUDE_BIN:-}"
if [ -z "$CLAUDE_BIN" ]; then
  if [ -x "$HOME/.local/share/claude/stable/claude" ]; then
    CLAUDE_BIN="$HOME/.local/share/claude/stable/claude"
  else
    CLAUDE_BIN="$HOME/.local/bin/claude"
  fi
fi
# WAKE THE DOMAIN'S BROWSER IF THE JOB NEEDS IT.
#
# Sleeping browsers (a guard suspends profiles nobody has connected to for an
# hour) free several GB — but a job that loads chrome-devtools and meets a
# sleeping profile gets an MCP server that cannot connect. There is no crash,
# just a tool that is silently absent: exactly the kind of degradation the whole
# delivery measurement exists to prevent.
#
# THE WAKE HAPPENS HERE, SYNCHRONOUSLY, BEFORE THE JOB — not through a signal the
# job sends once it is already trying to connect. Measured 2026-08-06: a scanner
# calls markActivity and connects in the same tick, without retry, so a
# signal-driven wake never arrives in time.
#
# Living in the RUNNER rather than in each job's conf is deliberate: it then
# applies to every domain without anyone having to remember it, and no domain
# file needs changing. browser-power.sh verifies that CDP actually answers before
# returning, so "woken" is a measurement and not an assumption.
wake_browser_if_needed() {
  local bp="$(dirname "$0")/tools/browser-power.sh"
  [ -x "$bp" ] || return 0                      # no browser-power on this platform — skip
  [ -n "${DOMAIN:-}" ] || return 0
  [ -f "$(dirname "$0")/browsers.d/$DOMAIN.conf" ] || return 0
  local mcp_src
  if [ -n "${MCP_CONFIG:-}" ]; then mcp_src="$REPO_PATH/$MCP_CONFIG"; else mcp_src="$REPO_PATH/.mcp.json"; fi
  [ -f "$mcp_src" ] || return 0
  grep -q "chrome-devtools" "$mcp_src" 2>/dev/null || return 0
  log "the job loads chrome-devtools — waking $DOMAIN's browser"
  if bash "$bp" wake "$DOMAIN" >/dev/null 2>&1; then
    log "browser $DOMAIN is up"
  else
    # FAIL LOUD. A job that runs on without its tool produces an answer that
    # looks complete and is missing half its evidence.
    log "FATAL: could not wake $DOMAIN's browser — the job does NOT run"
    exit 69
  fi
}
wake_browser_if_needed

# THE ONE RULE, APPLIED BEFORE THE KIND BRANCH — for BOTH kinds.
#
# WHY BOTH. A claude-kind job's model calls are billed to whichever account it
# runs on, so it obviously needs the rule. A command-kind job needs it too, and
# for a reason that is easy to miss: the commands in this estate INCLUDE tools
# that read credentials (the auth probe) and tools that shell out to claude. A
# rule that stopped at the claude branch would have left the one job that
# MEASURES credentials measuring whichever account the process inherited.
#
# registry_login_apply IS THE RULE — not a hand-written copy of it. This runner
# execs CMD from its own process, so it needs real environment rather than a
# command prefix; that is the only difference, and both forms read the same
# $_REGISTRY_LOGIN_SCRUB and the same resolver. A fifth branch spelling out
# `unset ANTHROPIC_API_KEY ANTHROPIC_AUTH_TOKEN` by hand would be a copy that
# stops following the list the day the list grows.
if ! registry_login_apply "${LOGIN:-}" "$OWNER"; then
  log "FATAL: LOGIN=\"${LOGIN:-}\" does not resolve — the job does NOT run. A job that"
  log "runs on the ambient account bills whoever happens to own this process."
  exit 78
fi
if [ -n "${LOGIN:-}" ]; then
  # THE SLUG TRAVELS WITH THE DIRECTORY. A command-kind job that MEASURES
  # credentials has to be able to NAME which account it measured, and the
  # directory alone does not carry the name. This is the seam the estate's
  # auth probe reads (see the plan's task 17) — the alternative, an argument
  # inside COMMAND, does not work: the runner execs `bash "$REPO_PATH/$COMMAND"`,
  # so a COMMAND with a space in it becomes one impossible filename.
  export STEWARD_LOGIN="$LOGIN"
  log "login: $LOGIN -> $CLAUDE_CONFIG_DIR"
else
  log "login: none declared — running on the ambient account (transition)"
fi

if [ "$KIND" = "claude" ]; then
  # (The scrub of ANTHROPIC_API_KEY/AUTH_TOKEN lived here until 2026-08-31 and
  # now lives in registry_login_apply above, for BOTH kinds. The reason and the
  # two measurements — exit 1, "Credit balance is too low", 2026-07-15 and
  # -16 — stay in that function's header comment, where the rule now lives.)
  CMD=("$CLAUDE_BIN" -p "$PROMPT" --permission-mode "$PERMISSION_MODE" --max-turns "$MAX_TURNS")
  [ -n "$SETTINGS_FILE" ] && CMD+=(--settings "$REPO_PATH/$SETTINGS_FILE")
  # MCP_CONFIG (optional, jobs.d): narrow the job's MCP surface to EXACTLY the
  # servers it needs. Without the field the job inherits the repository's
  # .mcp.json plus user scope — i.e. EVERY server, chrome-devtools included, on
  # EVERY run, and some jobs run many times a day. Each spawn costs processes and
  # can trigger a macOS App Data Protection prompt (2026-07-26: the root cause of
  # a flood of them). Headless jobs rarely need a browser MCP — SESSIONS do, and
  # a session's tool surface is never touched by this.
  # --strict-mcp-config also closes user-scope servers.
  if [ -n "$MCP_CONFIG" ]; then
    if [ -f "$REPO_PATH/$MCP_CONFIG" ]; then
      CMD+=(--strict-mcp-config --mcp-config "$REPO_PATH/$MCP_CONFIG")
    else
      # Fail LOUD, not silently: without the file claude would give a cryptic
      # error, and quietly running on with the FULL MCP surface would do the
      # exact opposite of the conf's stated intent. The job aborts with a clear
      # cause.
      log "FATAL: MCP_CONFIG names $REPO_PATH/$MCP_CONFIG which does not exist — the job does NOT run (a scope intent must not silently fall back to the full MCP surface)"
      exit 78
    fi
  fi
  # ALLOWED_TOOLS IS A PERMISSION LIST, NOT A TOOL BLOCK. From claude's own help:
  # --allowed-tools = "tool names to ALLOW", while --tools = "the list of
  # AVAILABLE tools from the built-in set". Proven 2026-08-02 with a side-effect
  # test: Bash RUNS despite --allowed-tools Read. To block structurally, set
  # TOOLS, not ALLOWED_TOOLS.
  [ -n "$ALLOWED_TOOLS" ] && CMD+=(--allowedTools "$ALLOWED_TOOLS")
  # TOOLS: the REAL block. TOOLS="none" => --tools "" (no built-in tools at all);
  # otherwise the list as given. An empty value means no flag, i.e. unchanged
  # behaviour for every existing conf.
  if [ -n "$TOOLS" ]; then
    if [ "$TOOLS" = "none" ]; then CMD+=(--tools ""); else CMD+=(--tools "$TOOLS"); fi
  fi
  # Model fallback chain: run on the account default first, and only when a run
  # is refused for a usage/spend-limit reason ("hit your monthly spend limit …
  # switch models to continue", seen 2026-07-25 07:00) retry on the next model.
  # "default" = no --model flag (whatever the account's plan defaults to). Other
  # failure classes never fall through, so a genuine bug can't burn every model.
  # Override with STEWARD_MODELS_FALLBACK (space-separated, "default" allowed).
  MODELS_FALLBACK="${STEWARD_MODELS_FALLBACK:-default opus sonnet}"
else
  CMD=(bash "$REPO_PATH/$COMMAND")
fi

# Everything below runs inside ONE watchdogged process group: PRE, main and POST
# share the TIMEOUT_MIN budget, so a hung hook (the op-under-launchd failure
# class this design exists for) can never wedge the job forever.
TIMEOUT_SECS=$(( TIMEOUT_MIN * 60 ))
[ -n "${STEWARD_TEST_TIMEOUT_SECS:-}" ] && TIMEOUT_SECS="$STEWARD_TEST_TIMEOUT_SECS"
OUT_FILE=$(mktemp "${TMPDIR:-/tmp}/agent-job-$domain-$job.out.XXXXXX")
STATUS_FILE=$(mktemp "${TMPDIR:-/tmp}/agent-job-$domain-$job.status.XXXXXX")
rc=0
set -m
(
  # PRE_CMD: exit 100 = deliberate skip; other nonzero aborts the job.
  if [ -n "$PRE_CMD" ]; then
    pre_rc=0
    bash -c "$PRE_CMD" || pre_rc=$?
    if [ "$pre_rc" -eq 100 ]; then echo skipped > "$STATUS_FILE"; exit 0; fi
    if [ "$pre_rc" -ne 0 ]; then echo "pre_failed:$pre_rc" > "$STATUS_FILE"; exit "$pre_rc"; fi
  fi
  main_rc=0
  if [ "$KIND" = "claude" ]; then
    for _model in $MODELS_FALLBACK; do
      attempt=("${CMD[@]}")
      [ "$_model" != "default" ] && attempt+=(--model "$_model")
      _aout=$(mktemp "${TMPDIR:-/tmp}/agent-job-$domain-$job.attempt.XXXXXX")
      main_rc=0
      "${attempt[@]}" >"$_aout" 2>&1 || main_rc=$?
      cat "$_aout"
      # A usage/spend-limit refusal can arrive with EXIT 0 — claude "ran" and
      # produced a refusal message, so its exit code reads as success. Check
      # the output signature BEFORE trusting rc=0; otherwise a capped model
      # looks like a successful run and the fallback never fires. Observed
      # 2026-07-25: every claude job down on Fable's monthly limit, yet the
      # loop never iterated because the refusal exited 0 and broke here as
      # "success". Only a usage/spend-limit refusal warrants the next model.
      if grep -qiE 'spend limit|usage limit|switch model' "$_aout"; then
        echo "[job-runner] model '${_model}' hit a usage/spend limit — falling back to next model"
        rm -f "$_aout"
        main_rc=1   # a capped FINAL model must leave the job failed, not a false rc=0
        continue
      fi
      rm -f "$_aout"
      break   # real success (rc=0) or a non-limit error (never burn other models)
    done
  else
    "${CMD[@]}" || main_rc=$?
  fi
  # POST_CMD observes the run; its failure never changes the job's rc.
  if [ -n "$POST_CMD" ]; then
    JOB_OUTPUT_FILE="$OUT_FILE" JOB_RC="$main_rc" bash -c "$POST_CMD" \
      || echo "WARNING: POST_CMD failed (job rc unchanged)"
  fi
  exit "$main_rc"
) >"$OUT_FILE" 2>&1 &
JOB_PID=$!
(
  sleep "$TIMEOUT_SECS"
  echo "WATCHDOG: timeout after ${TIMEOUT_SECS}s — killing process group" >>"$OUT_FILE"
  kill -TERM -- -"$JOB_PID" 2>/dev/null
  sleep 10
  kill -KILL -- -"$JOB_PID" 2>/dev/null
) &
WATCHDOG_PID=$!
set +m
disown "$WATCHDOG_PID" 2>/dev/null || true   # F6: no zombie, no "Terminated: 15" noise in logs
wait "$JOB_PID" || rc=$?
kill -TERM -- -"$WATCHDOG_PID" 2>/dev/null || true
cat "$OUT_FILE"
STATUS="$(cat "$STATUS_FILE" 2>/dev/null || true)"
rm -f "$OUT_FILE" "$STATUS_FILE"
case "$STATUS" in
  skipped) log "PRE_CMD requested skip"; rc=0; EXIT_SUFFIX=" (skipped)" ;;
  pre_failed:*) log "PRE_CMD failed (rc=${STATUS#pre_failed:}) — job aborted" ;;
esac

exit "$rc"
