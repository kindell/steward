#!/bin/bash
# install.sh — bring up a steward estate on a fresh machine.
#
#   /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/<owner>/steward/main/install.sh)"
#
# WHAT IT DOES: fetches the product, writes an ESTATE skeleton, and then MEASURES
# that the product can read it. What it does NOT do is start anything, touch a
# running session, or invent a name.
#
# THE INSTALLER NEVER GUESSES THE ESTATE'S NAMES. Every value below identifies
# the owner's fleet — the label prefix that names their launchd units, the hub's
# name on the bus, the socket their tmux server holds. A default here would be a
# stranger's namespace burned into a fresh machine, and the whole reason this
# code could be published is that those values live in a file rather than in the
# code. So: one answer, or refuse.
#
# EXIT CODES: 0 ok · 64 usage · 65 refusal · 70 execution failure · 78 config.
set -uo pipefail

STEWARD_REPO_URL="${STEWARD_REPO_URL:-https://github.com/kindell/steward.git}"
PRODUCT_DIR="${STEWARD_PRODUCT_DIR:-$HOME/Projects/steward}"
ESTATE_DIR="${STEWARD_ESTATE_ROOT:-$HOME/estate}"

say()  { printf '%s\n' "$*"; }
die()  { printf 'install: %s\n' "$1" >&2; exit "${2:-70}"; }

# ── 1. THE NAME ────────────────────────────────────────────────────────────
# ORG is the only thing asked for. Everything else is derived from it, so a
# fresh estate is internally consistent by construction rather than by the
# installer's memory.
#
# Read from a variable when set (so this is scriptable), otherwise from the
# terminal. NOT from stdin: when this file is itself piped from curl, stdin is
# the SCRIPT, and reading it would consume the installer's own remaining lines —
# a failure that looks like a truncated download.
ORG="${STEWARD_ORG:-}"
if [ -z "$ORG" ]; then
  [ -t 0 ] || [ -r /dev/tty ] || die "no terminal to ask on. Set STEWARD_ORG=<name> and re-run." 64
  printf 'Name for this estate (lowercase, a-z0-9-): ' > /dev/tty
  IFS= read -r ORG < /dev/tty || true
fi
case "$ORG" in
  ''|*[!abcdefghijklmnopqrstuvwxyz0123456789-]*)
    die "estate name must be [a-z0-9-] and not empty (got '${ORG}')" 64 ;;
esac

# ── 2. PREREQUISITES ───────────────────────────────────────────────────────
# Everything supervision and the bus lean on, checked BEFORE anything is
# written: a bootstrap that discovers a missing tool halfway through leaves a
# machine that is half an estate, and a half state that looks whole is the
# recurring failure shape this code is written against.
#
# Installed via apt when possible; otherwise the refusal NAMES the missing
# tools, because "install failed" without names sends the reader to a log
# instead of to a package manager.
say ""
say "prerequisites:"
_missing=""
for _t in git curl tmux jq python3; do
  if command -v "$_t" >/dev/null 2>&1; then say "  ok   $_t"
  else _missing="$_missing $_t"; fi
done
if [ -n "$_missing" ]; then
  if command -v apt-get >/dev/null 2>&1 && { [ "$(id -u)" = 0 ] || sudo -n true 2>/dev/null; }; then
    say "  installing:$_missing"
    _sudo=""; [ "$(id -u)" = 0 ] || _sudo="sudo -n"
    $_sudo apt-get update -qq && $_sudo apt-get install -y -qq $_missing >/dev/null       || die "could not install:$_missing" 70
  else
    die "missing tools:$_missing — install them and re-run. (No apt or no sudo here.)" 69
  fi
fi
# claude: the session runtime. Installed with the official installer when
# absent — into ~/.local/bin, no root needed. LOGIN is not done here: it is a
# credential, it is interactive, and it is the owner's own act. The first
# supervision round starts claude anyway; an unauthenticated claude shows its
# login flow in the tmux pane, and attaching to answer it is the last step
# printed below.
if command -v claude >/dev/null 2>&1 || [ -x "$HOME/.local/bin/claude" ]; then
  say "  ok   claude ($("$HOME/.local/bin/claude" --version 2>/dev/null || claude --version 2>/dev/null | head -1))"
else
  say "  installing claude (official installer, into ~/.local/bin)"
  curl -fsSL https://claude.ai/install.sh | bash >/dev/null 2>&1     || die "the claude installer failed — run it yourself and re-run this script:
     curl -fsSL https://claude.ai/install.sh | bash" 70
  [ -x "$HOME/.local/bin/claude" ] || die "claude did not land in ~/.local/bin" 70
  say "  ok   claude ($("$HOME/.local/bin/claude" --version 2>/dev/null | head -1))"
fi

# ── 3. THE PRODUCT ─────────────────────────────────────────────────────────
if [ -d "$PRODUCT_DIR/.git" ]; then
  say "product: already at $PRODUCT_DIR — fetching"
  git -C "$PRODUCT_DIR" fetch --quiet origin || die "could not fetch $STEWARD_REPO_URL" 70
  git -C "$PRODUCT_DIR" merge --quiet --ff-only origin/HEAD 2>/dev/null || true
else
  say "product: cloning into $PRODUCT_DIR"
  mkdir -p "$(dirname "$PRODUCT_DIR")" || die "could not create $(dirname "$PRODUCT_DIR")" 70
  git clone --quiet "$STEWARD_REPO_URL" "$PRODUCT_DIR" \
    || die "could not clone $STEWARD_REPO_URL — is the repository readable from here?" 70
fi
say "product: $(git -C "$PRODUCT_DIR" log --oneline -1)"

# ── 4. THE ESTATE ──────────────────────────────────────────────────────────
# REFUSES TO OVERWRITE. An existing conf holds values that name live units and a
# live tmux socket; rewriting it is how a machine loses track of what it is
# already running. Removing it is the owner's deliberate act, never ours.
if [ -e "$ESTATE_DIR/estate/steward.conf" ]; then
  die "an estate already exists at $ESTATE_DIR/estate/steward.conf — refusing to overwrite it.
     Its values name live units and a live tmux socket. Move it aside yourself if
     you mean to start over." 65
fi

mkdir -p "$ESTATE_DIR"/{estate,sessions.d,jobs.d,services.d,browsers.d,hosts.d} \
  || die "could not create $ESTATE_DIR" 70

cat > "$ESTATE_DIR/estate/steward.conf" <<CONF
# estate/steward.conf — THIS ESTATE'S OWN NAMES.
#
# Written by install.sh. Every value here identifies THIS fleet; the product
# carries the mechanism and nothing else. Changing a value renames something
# live — read the note beside each key before you do.

# Names every launchd/systemd unit this machine operates. Changing it makes the
# installer stop recognising the units it already installed: it would boot out
# every live one and bootstrap duplicates under the new name.
LABEL_PREFIX="com.${ORG}.claude"

# The session's identity in the process table:
#     claude --remote-control "<RC_LABEL_PREFIX><session name>"
# Supervision uses this string twice — to BUILD the command and to MEASURE
# whether claude is alive. Change it without restarting every process and the
# pattern matches nothing, supervision concludes every session is dead, and it
# enters its repair path. The trailing space belongs to the label.
RC_LABEL_PREFIX="${ORG}: "

# The hub's name on the bus, and its machine name. Two keys on purpose: they
# hold the same string in a small estate and diverge the first time somebody
# names a machine after the room it stands in.
HUB_SESSION="${ORG}-hub"
HUB_HOST="$(hostname -s)"

# The bus relay's ssh target, <user>@<host>. Both parts required: a bare host
# name makes ssh use the CALLING account's name, which on a multi-tenant machine
# is the wrong account.
HUB_SSH="$(id -un)@$(hostname -s)"

# A directory NAME, never a path — a slash would let a typo write logs anywhere.
JOB_LOG_DIR="${ORG}-jobs"

# The tmux socket file under ~/.tmux/. LIVE: the server holding every session
# creates it, and renaming it leaves every client unable to find a server that
# is still running.
TMUX_SOCKET="${ORG}.sock"

# The fixed, contentless ping typed into a recipient's pane. A CONSTANT compared
# exactly — that is how the guard tells a ping from real user input — and also
# instruction text every running session is told to react to.
PING_MSG="[bus] you have mail — read your inbox"

# Supervision's two state directory names. A pause marker that cannot be found
# turns a deliberately stopped session into one supervision restarts.
STATE_DIR_NAME="${ORG}-supervisor"
PAUSED_DIR_NAME="${ORG}-paused"

# Label prefixes for jobs, services and browsers. Same warning as LABEL_PREFIX.
JOB_LABEL_PREFIX="com.${ORG}.job"
SERVICE_LABEL_PREFIX="com.${ORG}.service"
BROWSER_LABEL_PREFIX="com.${ORG}.browser"

# The name of this machine's secrets service-account file under ~/.config/op/.
OP_TOKEN_FILE_NAME="${ORG}-service-account"
CONF
chmod 600 "$ESTATE_DIR/estate/steward.conf"
say "estate: written to $ESTATE_DIR/estate/steward.conf"

# ── 5. THE MEASUREMENT ─────────────────────────────────────────────────────
# THE INSTALL ENDS WITH A MEASUREMENT, NOT A CLAIM. "Written" says a file
# exists; it does not say the product can READ it. Every key is resolved through
# the product's own readers here, so a typo surfaces now rather than at the first
# supervision round on a machine nobody is watching.
say ""
say "verifying — the product reading this estate:"
# shellcheck source=/dev/null
STEWARD_ESTATE_ROOT="$ESTATE_DIR" . "$PRODUCT_DIR/lib/registry.sh" \
  || die "could not load $PRODUCT_DIR/lib/registry.sh" 70

_bad=0
for _fn in registry_label_prefix registry_rc_label_prefix registry_hub_session \
           registry_hub_host registry_hub_ssh registry_job_log_dir \
           registry_tmux_socket registry_ping_msg registry_state_dir_name \
           registry_paused_dir_name registry_op_token_name; do
  if _v="$(STEWARD_ESTATE_ROOT="$ESTATE_DIR" "$_fn" 2>/dev/null)"; then
    printf '  ok   %-26s %s\n' "${_fn#registry_}" "$_v"
  else
    printf '  FAIL %-26s could not be resolved\n' "${_fn#registry_}"
    _bad=$((_bad + 1))
  fi
done
if STEWARD_ESTATE_ROOT="$ESTATE_DIR" registry_label_prefixes 2>/dev/null; then
  printf '  ok   %-26s %s / %s / %s\n' "label prefixes" \
    "$JOB_LABEL_PREFIX" "$SERVICE_LABEL_PREFIX" "$BROWSER_LABEL_PREFIX"
else
  printf '  FAIL %-26s could not be resolved\n' "label prefixes"; _bad=$((_bad + 1))
fi

[ "$_bad" -eq 0 ] || die "$_bad value(s) could not be read back. The estate file is at
     $ESTATE_DIR/estate/steward.conf — fix it and re-run this script." 78

# ── 6. THE FIRST SESSION ───────────────────────────────────────────────────
# THE FIRST SESSION CANNOT CREATE ITSELF. session-new.sh derives its identity
# from the tmux pane it runs in, which requires an already-registered session —
# right for every session after the first, impossible for the first. So the
# installer writes the hub's registry entry itself, and everything after the
# first goes through the enrolment chain like it should.
HUB="${ORG}-hub"
cat > "$ESTATE_DIR/sessions.d/$HUB.conf" <<CONF
# $HUB — this estate's hub, written by install.sh. The FIRST session cannot be
# created by session-new.sh (it derives identity from the pane it runs in), so
# this one entry is written at install time. Every later session goes through
# the enrolment chain.
HOST="$(hostname -s)"
REPO_PATH="$ESTATE_DIR"
RC_LABEL="${ORG}: $HUB"
PERMISSION_MODE="bypassPermissions"
OWNER="$(id -un)"
DOMAIN="$ORG"
CONF
say ""
say "hub session: $HUB registered"

# ── 7. SUPERVISION ─────────────────────────────────────────────────────────
# EVERY SESSION IS BORN KNOWING ITS ESTATE. The first live estate answered
# "which sessions can you see?" from an account-wide discovery layer that
# crosses estate boundaries — because nothing had ever told it where its own
# registry lived. The context block below loads into every session on this
# account (user-level memory); the markers make the write idempotent, and an
# existing file is appended to, never replaced.
_CMD="$HOME/.claude/CLAUDE.md"
if ! grep -q "steward:estate-context" "$_CMD" 2>/dev/null; then
  mkdir -p "$HOME/.claude"
  cat >> "$_CMD" <<CTX

<!-- steward:estate-context begin -->
# This machine's estate
- Estate root: $ESTATE_DIR (registry: $ESTATE_DIR/sessions.d/)
- Fleet questions ("which sessions exist / are alive?") are answered from the
  estate's own data — run:
      STEWARD_ESTATE_ROOT=$ESTATE_DIR bash $PRODUCT_DIR/linux/estate-status.sh
  and read the table. Never guess, never use account-wide discovery.
- Messages between sessions travel on the estate bus only.
<!-- steward:estate-context end -->
CTX
  say "context: estate block appended to ~/.claude/CLAUDE.md"
fi

# The unit templates ship pointing at the deployed image (~/scripts). This
# install runs from a CHECKOUT, so a drop-in override points ExecStart at the
# checkout and carries the estate root — the same mechanism systemd offers for
# exactly this, and the shipped unit stays byte-identical for image installs.
if command -v systemctl >/dev/null 2>&1 && systemctl --user show-environment >/dev/null 2>&1; then
  _UD="$HOME/.config/systemd/user"
  mkdir -p "$_UD/agent-session@.service.d"
  cp "$PRODUCT_DIR/linux/agent-session@.service" "$_UD/"
  cp "$PRODUCT_DIR/linux/agent-session@.timer"   "$_UD/"
  cat > "$_UD/agent-session@.service.d/override.conf" <<UNIT
# Written by install.sh: this estate runs from a checkout, not a deployed image.
[Service]
Environment=STEWARD_ESTATE_ROOT=$ESTATE_DIR
Environment=STEWARD_REGISTRY_LIB=$PRODUCT_DIR/lib/registry.sh
ExecStart=
ExecStart=/bin/bash $PRODUCT_DIR/linux/session-supervisor-linux.sh %i
UNIT
  systemctl --user daemon-reload
  # Linger, so the user manager — and with it every session — survives logout.
  # Needs no root on modern systemd.
  loginctl enable-linger "$(id -un)" 2>/dev/null || true
  systemctl --user enable --now "agent-session@$HUB.timer" >/dev/null 2>&1     || die "could not enable agent-session@$HUB.timer" 70
  say "supervision: agent-session@$HUB.timer enabled — first round within a minute"
else
  say "supervision: NO systemd user manager here — the timer was not installed."
  say "  Start the hub by hand when you want it:"
  say "    STEWARD_ESTATE_ROOT=$ESTATE_DIR bash $PRODUCT_DIR/linux/session-supervisor-linux.sh $HUB"
fi

say ""
say "Estate '$ORG' is up. One step remains, and it is yours:"
say ""
say "  the hub is starting under supervision. claude in it is NOT logged in —"
say "  that is a credential, so the installer never touches it. Attach and log in:"
say ""
say "      tmux attach -t $HUB"
say ""
say "  if ssh greets you with 'missing or unsuitable terminal', your terminal's"
say "  terminfo is not on this machine — export it once from your OWN machine:"
say "      infocmp -x | ssh <this-host> 'tic -x -o ~/.terminfo /dev/stdin'"
say ""
say "  after that: add projects from inside the hub with"
say "      STEWARD_ESTATE_ROOT=$ESTATE_DIR bash $PRODUCT_DIR/linux/session-new.sh <project> <repo path>"
say ""
say "  the estate's values live in $ESTATE_DIR/estate/steward.conf and are yours;"
say "  the product carries the mechanism and none of the names."
