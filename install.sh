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

# ── 2. THE PRODUCT ─────────────────────────────────────────────────────────
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

# ── 3. THE ESTATE ──────────────────────────────────────────────────────────
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

# ── 4. THE MEASUREMENT ─────────────────────────────────────────────────────
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

say ""
say "Estate '$ORG' is ready. Nothing has been started."
say ""
say "  next: create the hub session, then add projects to it:"
say "    STEWARD_ESTATE_ROOT=$ESTATE_DIR bash $PRODUCT_DIR/linux/session-new.sh <project> <repo path>"
say ""
say "  the estate's values live in $ESTATE_DIR/estate/steward.conf and are yours;"
say "  the product carries the mechanism and none of the names."
