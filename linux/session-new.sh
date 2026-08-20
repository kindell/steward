#!/bin/bash
# linux/session-new.sh — the REQUESTER's half of the session command. Runs as a
# human's own account on a session host, from inside a REGISTERED tmux session:
# the identity is DERIVED from the pane and never typed.
#
#   bash ~/scripts/session-new.sh <project> <repo-path>   create conf + key, send the request
#   bash ~/scripts/session-new.sh --activate <name>       after ENROLL-CONFIRM: start supervision
#
# Always invoked with a full path — ~/scripts is not on PATH, and a tool shell
# does not inherit the login shell's PATH.
#
# The name is CONSTRUCTED: <domain>-<project>-<person>, where domain and host
# come from the caller's own conf and person from the account. The trigger is a
# domain acquiring a project.
#
# THE FILE NAME AND THE --activate FLAG ARE STILL IN THE ESTATE'S LANGUAGE.
# Not because they are load-bearing — this script is invoked by humans through a
# full path, never by a systemd unit — but because renaming touches the manifest
# rows in two repositories, the deployed image in every home, the docs and the
# suites. Doing that once, after every source has moved, costs that churn once
# instead of once per file.
set -uo pipefail
# SESS_D is resolved AFTER the registry loads — see below. The estate owns the
# session registry, and only the registry knows where the estate is.
SESS_D=""
SSH_DIR="${STEWARD_SSH_DIR:-$HOME/.ssh}"
BUS_SEND="${STEWARD_BUS_SEND:-$HOME/bin/bus-send}"

fel() { echo "session-new: $1" >&2; exit "${2:-65}"; }

# ── THE ESTATE'S NAMES COME FROM THE ESTATE ────────────────────────────────
# Until 2026-08-20 two of the estate's values sat here as literals: the RC label
# prefix and the hub session's name. That alone kept this file out of the
# product — a product must not carry its owner's namespace burned in.
#
# THE VALUES DID NOT CHANGE when they moved. The registry suite compares against
# exactly the strings that stood here, trailing space in the prefix included.
#
# REFUSAL, NOT A DEFAULT. A guessed prefix would give the session an identity
# the supervisor does not recognise, and a guessed hub name would address the
# request to a recipient that does not exist. Both failures are silent until
# somebody wonders why a session never started.
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
[ -f "$REG_LIB" ] || fel "registry library missing: $REG_LIB" 78
# shellcheck source=/dev/null
. "$REG_LIB" || fel "registry library could not be read: $REG_LIB" 78
# THE SESSION REGISTRY COMES FROM THE ESTATE'S ROOT. It was a fixed path, so a
# second estate on the same account was invisible: its confs existed and the
# tooling looked past them, refusing with "no conf" — a refusal naming the wrong
# cause. Deployed, the root resolves to the same directory as before.
SESS_D="${STEWARD_SESSIONS_D:-$(registry_dir)}"
RC_PREFIX="$(registry_rc_label_prefix)" || exit 78
NAV="$(registry_hub_session)" || exit 78

if [ "${1:-}" = "--activate" ]; then
  NAMN="${2:?bash ~/scripts/session-new.sh --activate <name>}"
  [ -f "$SESS_D/$NAMN.conf" ] || fel "no conf for '$NAMN' in $SESS_D — send the request first"
  systemctl --user cat agent-session@.timer >/dev/null 2>&1 \
    || fel "supervision template agent-session@.timer missing — per-user supervision is a precondition" 65
  systemctl --user enable --now "agent-session@$NAMN.timer" \
    || fel "could not enable the timer" 70
  echo "session-new: timer active for '$NAMN' — supervision will start the session within one period."
  echo "  next: once the session is live it runs 'bash ~/scripts/session-approve.sh' (stated in its ENROLL-PROOF)."
  exit 0
fi

PROJEKT="${1:?bash ~/scripts/session-new.sh <project> <repo-path>}"
REPO="${2:?bash ~/scripts/session-new.sh <project> <repo-path>}"

# AN UNKNOWN FLAG MUST REFUSE AS A FLAG, NOT PASS AS A NAME. The project
# charset allows dashes, so '--anything' sailed through as a project name and
# the refusal blamed the SECOND argument ("not a git working copy") — a refusal
# naming the wrong cause, measured live 2026-08-21 when the flag's old
# pre-rename spelling was used against the renamed script.
case "$PROJEKT" in
  -*) fel "unknown flag '$PROJEKT' — the only flag is --activate <name>" 64 ;;
esac
case "$PROJEKT" in
  *[!abcdefghijklmnopqrstuvwxyz0123456789-]*|"") echo "session-new: project may contain only [a-z0-9-]" >&2; exit 64 ;;
esac

[ -n "${TMUX_PANE:-}" ] || fel "run from inside a registered tmux session — the identity is derived from the pane"
SJALV="$(tmux display-message -p -t "$TMUX_PANE" '#S' 2>/dev/null || true)"
[ -n "$SJALV" ] || fel "could not derive own session name from the pane"
PERSON="$(id -un)"

EGEN="$SESS_D/$SJALV.conf"
[ -f "$EGEN" ] || fel "no conf for '$SJALV' in $SESS_D — a request must come from a registered session"
DOMAN="$(sed -n 's/^DOMAIN="\(.*\)"/\1/p' "$EGEN" | head -1)"
VARD="$(sed -n 's/^HOST="\(.*\)"/\1/p' "$EGEN" | head -1)"
# A SILENT FALLBACK HERE WAS A REAL FAULT, measured 2026-08-14: with DOMAIN
# unset the credential directory fell back to the session name, so one session
# quietly got a PRIVATE credential store instead of the domain's shared one.
# The first symptom is tools asking for a login again in a single session while
# everything else looks healthy.
[ -n "$DOMAN" ] || fel "DOMAIN missing in $EGEN — set it"
[ -n "$VARD" ]  || fel "HOST missing in $EGEN"

NAMN="${DOMAN}-${PROJEKT}-${PERSON}"
[ -d "$REPO/.git" ] || fel "'$REPO' is not a git working copy — clone the project first"
[ -O "$REPO" ]      || fel "'$REPO' is not owned by $PERSON — a session works in its human's clones"
[ ! -f "$SESS_D/$NAMN.conf" ] || fel "'$NAMN' already has a local conf — after a hub failure, delete it deliberately and re-run"

# One repo, one session. The name collision above does not catch TWO NAMES
# pointing at the SAME working copy, which would give one repo two supervisors —
# a state a session refused to create by hand on 2026-08-15. Only the requester
# can see the path, so this is the only place the check can live. Realpath, not
# the string: a symlink and its target are the same repo and different strings.
REPO_REAL="$(cd "$REPO" && pwd -P)" || fel "could not resolve '$REPO' to a real path" 70
for _c in "$SESS_D"/*.conf; do
  [ -f "$_c" ] || continue
  _crp="$(sed -n 's/^REPO_PATH="\(.*\)"/\1/p' "$_c" | head -1)"
  [ -n "$_crp" ] || continue
  _crp_real="$(cd "$_crp" 2>/dev/null && pwd -P || printf '%s' "$_crp")"
  [ "$_crp_real" != "$REPO_REAL" ] || \
    fel "'$REPO' is already owned by session '$(basename "$_c" .conf)' — one repo, one session"
done

NYCKEL="$SSH_DIR/id_busrelay_$NAMN"
if [ -f "$NYCKEL" ]; then
  echo "session-new: key already exists — reusing it (idempotent after a failed send)" >&2
else
  ssh-keygen -q -t ed25519 -N "" -f "$NYCKEL" -C "${VARD}-${PERSON}-${NAMN}" \
    || fel "key generation failed" 70
fi
PUB="$(cat "$NYCKEL.pub")" || fel "could not read the public key" 70

tmpc="$(mktemp)" || fel mktemp 70
cat > "$tmpc" <<CONFEOF
# $NAMN — created by session-new $(date -u +%Y-%m-%dT%H:%M:%SZ) from $SJALV.
HOST="$VARD"
REPO_PATH="$REPO"
RC_LABEL="$RC_PREFIX$NAMN"
PERMISSION_MODE="bypassPermissions"
OWNER="$PERSON"
DOMAIN="$DOMAN"
CONFEOF
mv "$tmpc" "$SESS_D/$NAMN.conf" || fel "could not write the conf" 70

# The request: ONLY the public key travels. If the send fails the conf is
# withdrawn — a half state that looks whole is the recurring failure shape here.
#
# THE FIRST LINE IS THE ENVELOPE (bus lib: bus_envelope_parse) — bus_send now
# refuses every SEND without one. "ENROLL-REQUEST v1" stays unchanged as its own
# line: the hub's enroll handler requires it verbatim and explicitly skips a
# preceding envelope line.
#
# THE WIRE FIELD NAMES BELOW ARE DELIBERATELY UNTRANSLATED. They are DATA, read
# verbatim by the receiving end, and renaming them is a protocol change on both
# sides of a live link — its own migration, announced by refusal rather than
# discovered by breakage.
#
# THE ENVELOPE'S HEADLINE IS NOT IN THAT CLASS and was translated. Only the
# CLASS (DRIFT) and the SUBJECT SLUG (enroll) are structural — the subject is
# the thread key. The headline after the colon is free text; measured across
# both repositories, nothing matches on it.
if ! printf 'DRIFT enroll: %s requests registration\nENROLL-REQUEST v1\nnamn=%s\ndoman=%s\nprojekt=%s\nperson=%s\nvard=%s\nrepo=%s\npubkey=%s\n' \
      "$NAMN" "$NAMN" "$DOMAN" "$PROJEKT" "$PERSON" "$VARD" "$REPO" "$PUB" \
      | "$BUS_SEND" "$NAV"; then
  rm -f "$SESS_D/$NAMN.conf"
  fel "the request did not reach the hub — conf withdrawn (the key remains), re-run" 70
fi

echo "session-new: request sent for '$NAMN'."
echo "  next: wait for ENROLL-CONFIRM in your inbox, then run: bash ~/scripts/session-new.sh --activate $NAMN"
