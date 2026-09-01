#!/bin/bash
# linux/session-new.sh — the REQUESTER's half of the session command. Runs as a
# human's own account on a session host, from inside a REGISTERED tmux session:
# the identity is DERIVED from the pane and never typed.
#
#   bash ~/scripts/session-new.sh <project> <repo-path>       create conf + key, send the request
#   bash ~/scripts/session-new.sh --activate <id> <slug>      the command ENROLL-CONFIRM prints
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
# ── WHERE A PENDING ENROLMENT IS REMEMBERED ─────────────────────────────────
# NOT IN sessions.d. The reservation used to be nothing but the local conf this
# script wrote at request time, and that directory is RECONCILED BY THE DEPLOY:
# the install builds a keep-list from the estate checkout and deletes every
# runtime conf the checkout does not carry — which is exactly what a local
# reservation is. So the ordinary "sync, then activate" order removed the one
# file activation depended on, and the discovery that replaced it then picked
# another session's key. A state directory the deploy never touches is the
# right home for a fact this account owns about its own request.
STATE_D="${STEWARD_ENROLL_STATE_DIR:-${XDG_STATE_HOME:-$HOME/.local/state}/steward-enroll}"

# THE SENDER MUST BE NAMEABLE — CHECKED HERE, BEFORE ANYTHING IS CREATED.
#
# bus-send refuses a sender it cannot name, because the nameless fallback picks
# another session's relay key and the hub stamps the mail with THAT name. This
# script would hit that refusal at its LAST step, after a conf and a key already
# exist — recoverable (the send failure withdraws them) but wasteful, and the
# diagnosis arrives attached to the wrong action.
#
# The check is deliberately WEAKER than bus-send's own: a set TMUX_PANE may
# still be stale. That is the right direction to be wrong in — this gate only
# rejects the case where a name is CERTAINLY underivable, and bus-send remains
# the authority on the rest. Duplicating the real derivation here would be two
# copies to keep in step, which is how a guard drifts away from what it guards.
#
# AND IT GUARDS THE REQUEST PATH ONLY. --activate sends nothing: it links a key
# and enables a timer, entirely locally. Gating it on a nameable SENDER made the
# command ENROLL-CONFIRM prints refuse with rc 78 in any terminal that is not a
# registered tmux pane — which is where an operator reads their mail and pastes
# it. The fixture that was supposed to catch that ran INSIDE tmux and inherited
# TMUX_PANE from the runner, so it measured the runner's terminal rather than
# the code (found 2026-09-01, while making the end-to-end fixture run the
# printed command verbatim).
if [ "${1:-}" != "--activate" ] && [ -z "${BUS_FROM:-}" ] && [ -z "${TMUX_PANE:-}" ]; then
  echo "$(basename "$0"): REFUSES — the sender cannot be named." >&2
  echo "  Not running in tmux and BUS_FROM is unset, so the request to the hub" >&2
  echo "  would be sent under another session's key and stamped with its name." >&2
  echo "  Set BUS_FROM=<your-session-name> and re-run." >&2
  exit 78
fi


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

# _ar_myntat_id <candidate>: rc 0 iff s- followed by exactly 16 hex digits.
# HEX, NOT "SIXTEEN OF ANYTHING" — the old test was the glob
# s-????????????????, which matches sixteen arbitrary characters. Harmless
# while no slug can take that shape, and free to assert properly.
_ar_myntat_id() {
  case "$1" in s-*) : ;; *) return 1 ;; esac
  case "${1#s-}" in *[!0123456789abcdef]*|"") return 1 ;; esac
  [ "${#1}" -eq 18 ]
}

if [ "${1:-}" = "--activate" ]; then
  ARG="${2:?bash ~/scripts/session-new.sh --activate <id> <slug>}"
  # ── THE PAIRING IS CARRIED, NEVER DISCOVERED ──────────────────────────────
  #
  # THE TWO NAMES A NEWBORN SESSION HAS. The hub files the row under a minted
  # opaque id and binds the relay key to that id. The host has the PRIVATE key
  # filed under the SLUG, because the slug is all this script knew when it
  # generated the key. Activation is the moment the two are joined.
  #
  # IT USED TO GUESS, AND THE GUESS WAS BOTH AMBIGUOUS AND SILENTLY WRONG.
  # ENROLL-CONFIRM printed `--activate <id>` alone, so this branch scanned
  # sessions.d for a conf with no ID line, owned by this account, with a
  # matching key on disk. Every old-shape row on the host satisfies all three —
  # including the requester's own, which always exists (this script refuses to
  # run except from a registered session). So the printed command refused on
  # any host that already had a session. And when exactly one candidate
  # survived — the reservation pruned by a deploy, the hub's own row disqualified
  # because it carries ID= — nothing related that candidate to the id: ANOTHER
  # SESSION'S KEY was linked under the new id, rc 0, no warning. The newborn's
  # outbound mail was then stamped with the other session's name. That is the
  # fleet's identity-swap incident, rebuilt from new parts, and the ordinary
  # recovery from the ambiguity refusal (sync, then activate) walked into it
  # every time.
  #
  # SO THE PAIRING TRAVELS WITH THE CONFIRM. The hub knows both names when it
  # answers and prints both: `--activate <id> <slug>`. Two tokens are as
  # copy-pastable as one and unambiguous with any number of enrolments in
  # flight. Nothing here reads another session's conf, ever.
  if _ar_myntat_id "$ARG"; then
    ID="$ARG"
    NAMN="${3:-}"
    if [ -n "$NAMN" ]; then
      case "$NAMN" in
        *[!abcdefghijklmnopqrstuvwxyz0123456789-]*|"")
          fel "the slug '$NAMN' is outside the namespace [a-z0-9-]" 64 ;;
      esac
    elif [ -e "$SSH_DIR/id_busrelay_$ID" ]; then
      # ALREADY LINKED, so there is nothing to pair. The hub-local request
      # path (below) registers and links in a single invocation — there is no
      # bus hop in between for a later --activate to bridge — so its printed
      # command is runnable with or without the slug.
      NAMN=""
    else
      # NO SLUG, NO KEY, NO GUESS. Listing what this account has in flight is
      # help, not discovery: nothing is chosen from it.
      _vantande=""
      if [ -d "$STATE_D" ]; then
        for _r in "$STATE_D"/enroll-*.pending; do
          [ -f "$_r" ] || continue
          _rn="$(basename "$_r" .pending)"; _rn="${_rn#enroll-}"
          _vantande="$_vantande $_rn"
        done
      fi
      echo "session-new: REFUSING — '$ID' alone does not say which local key it belongs to." >&2
      echo "  Run the command ENROLL-CONFIRM printed, which carries both halves:" >&2
      echo "    bash ${BASH_SOURCE[0]} --activate $ID <slug>" >&2
      echo "  The pairing is never guessed from the register: every old-shape row on this" >&2
      echo "  host looks like a pending request, and picking one links the wrong key under" >&2
      echo "  this id — the new session would then send mail as that other session." >&2
      if [ -n "$_vantande" ]; then
        echo "  requests in flight from this account:$_vantande" >&2
      else
        echo "  this account has no request in flight (see $STATE_D)." >&2
      fi
      exit 65
    fi
    # THE REGISTRY ROW MUST BE HERE BEFORE SUPERVISION IS TOLD ABOUT IT.
    # The old-shape branch has always checked its conf; this one checked only
    # the reservation, so activation printed "timer active" for an instance
    # the host could not see. The supervisor then refuses loudly every period
    # ("a session without a registry entry must not be started") — a failing
    # timer forever, announced at the wrong end. The hub writes the row into
    # the estate checkout; it reaches this host through the install.
    [ -f "$SESS_D/$ID.conf" ] || fel "no registry row '$ID.conf' in $SESS_D — the hub registered this session, but its row has not reached this host yet. Sync the estate (the install that copies the checkout's sessions.d) and re-run; supervision refuses to start a session it cannot find in the register, so activating now would only produce a timer that fails every period." 65
    if [ -n "$NAMN" ]; then
      # VERIFY THE SLUG MATCHES THE ROW'S OWN SLUG= FIELD. The row was registered
      # with a specific slug; a wrong second token would silently link the wrong
      # key (the identity-swap incident, now with the trigger moved to a typo).
      # Extract SLUG= from the conf and refuse rc 65 if they don't match, naming
      # both values and the correct command.
      _regslug="$(sed -n 's/^SLUG="\(.*\)"/\1/p' "$SESS_D/$ID.conf" | head -1)"
      if [ "$_regslug" != "$NAMN" ]; then
        fel "slug mismatch: row '$ID' declares SLUG=\"$_regslug\", but you provided '$NAMN'. Activate with the correct form: bash ${BASH_SOURCE[0]} --activate $ID $_regslug" 65
      fi
      # THE RESERVATION IS THIS ACCOUNT'S OWN NOTE ABOUT ITS OWN REQUEST — it
      # confirms the slug was requested from here and names the key. Absent
      # (an older request, a cleaned state dir) the key on disk is still the
      # authority: the slug came from the CONFIRM, not from a scan.
      _res="$STATE_D/enroll-$NAMN.pending"
      _nyckel="$SSH_DIR/id_busrelay_$NAMN"
      if [ -f "$_res" ]; then
        _rk="$(sed -n 's/^KEY="\(.*\)"/\1/p' "$_res" | head -1)"
        [ -n "$_rk" ] && _nyckel="$_rk"
      fi
      [ -f "$_nyckel" ] || fel "no key '$_nyckel' for '$NAMN' — this host never sent that request, or the key was removed. Nothing was linked." 65
      # THE KEY LINKS TO THE ID, NEVER RENAMES. The original file stays
      # addressable by the name it was generated under; the symlink is
      # what the relay's forced command (bound to the id in
      # authorized_keys, hub/enroll) and the launchd/systemd unit under
      # the id both need to find.
      ln -sf "$(basename "$_nyckel")" "$SSH_DIR/id_busrelay_$ID" || fel "could not link the key under the id" 70
      ln -sf "$(basename "$_nyckel").pub" "$SSH_DIR/id_busrelay_$ID.pub" || fel "could not link the public key under the id" 70
      rm -f "$_res"
    fi
    INSTANCE="$ID"
  else
    case "$ARG" in
      s-*) [ -f "$SESS_D/$ARG.conf" ] || \
             fel "'$ARG' looks like a minted id but is not one (the shape is s- followed by 16 hex digits)" 64 ;;
    esac
    # OLD-SHAPE: the name IS the identity, exactly as before the new-shape rows
    # existed. Kept for every session that has not been through the migration.
    NAMN="$ARG"
    [ -f "$SESS_D/$NAMN.conf" ] || fel "no conf for '$NAMN' in $SESS_D — send the request first"
    # AND THE ROW MUST ACTUALLY BE OLD-SHAPE. This branch never checked, so a
    # new-shape row could be activated under its slug: a name-keyed timer
    # beside the hub's id-keyed row, with the id-bound key never engaged.
    _cid="$(sed -n 's/^ID="\(.*\)"/\1/p' "$SESS_D/$NAMN.conf" | head -1)"
    [ -z "$_cid" ] || [ "$_cid" = "$NAMN" ] || \
      fel "'$NAMN' is a new-shape row filed under the id '$_cid' — supervision keys off the id, so activate it that way: bash ${BASH_SOURCE[0]} --activate $_cid $NAMN" 65
    # AND THE REGISTER MUST NOT ALREADY CARRY THIS NAME AS A SLUG. Between the
    # request and the next install a host holds BOTH the local reservation
    # (filed under the slug) and the hub's row (filed under the id). Activating
    # the reservation by name then succeeds and supervises a name-keyed
    # instance against a row the register does not have, permanently divergent,
    # with the id-bound key never engaged. THIS IS A REFUSAL SCAN, NOT A
    # SELECTION: it never picks a row to act on, so it cannot pick a wrong one.
    for _c in "$SESS_D"/*.conf; do
      [ -f "$_c" ] || continue
      [ "$(sed -n 's/^SLUG="\(.*\)"/\1/p' "$_c" | head -1)" = "$NAMN" ] || continue
      fel "'$NAMN' is the SLUG of '$(basename "$_c" .conf)' in $SESS_D — the hub has already filed this session under its minted id, and supervision keys off that id. Activate it as the ENROLL-CONFIRM says: bash ${BASH_SOURCE[0]} --activate $(basename "$_c" .conf) $NAMN" 65
    done
    INSTANCE="$NAMN"
  fi
  systemctl --user cat agent-session@.timer >/dev/null 2>&1 \
    || fel "supervision template agent-session@.timer missing — per-user supervision is a precondition" 65
  # THE ESTATE IS BOUND PER SESSION, NOT PER ACCOUNT. The template's environment
  # names ONE estate root for every instance on the account, which made a second
  # estate on the same account invisible to supervision — its sessions would
  # start against the wrong registry, or refuse. Activation is the one moment
  # that knows which estate a session belongs to (it just resolved it), so it
  # writes a per-instance drop-in and reloads BEFORE the first start. On a
  # single-estate account the drop-in states what the template already implied —
  # harmless, and every session becomes self-describing.
  #
  # THE INSTANCE IS THE ID FOR A NEW-SHAPE ROW, NEVER THE NAME — the timer,
  # the drop-in directory and (via authorized_keys, hub/enroll) the tmux
  # session all key off the same opaque id so a later account move or slug
  # rename never has to touch supervision.
  _dropdir="${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user/agent-session@$INSTANCE.service.d"
  mkdir -p "$_dropdir" || fel "could not create $_dropdir" 70
  # Canonicalized: the resolver's default form carries a trailing /.. — correct
  # to cd through, wrong to burn into a unit file that outlives this call.
  _eroot="$(CDPATH= cd -- "$(_registry_estate_root)" && pwd)" \
    || fel "could not resolve the estate root to a real directory" 70
  printf '[Service]\nEnvironment=STEWARD_ESTATE_ROOT=%s\n' "$_eroot" \
    > "$_dropdir/50-estate.conf" || fel "could not write the estate drop-in" 70
  systemctl --user daemon-reload
  systemctl --user enable --now "agent-session@$INSTANCE.timer" \
    || fel "could not enable the timer" 70
  echo "session-new: timer active for '$INSTANCE' — supervision will start the session within one period."
  echo "  estate bound per instance: $_dropdir/50-estate.conf"
  echo "  next: once the session is live it runs the approval command stated in its ENROLL-PROOF."
  exit 0
fi

# --domain <d>: BOOTSTRAP OF A DOMAIN'S FIRST SESSION ON THIS HOST.
#
# The gap it closes, measured 2026-08-24: the domain is derived from the
# CALLER's conf, so a domain that does not yet live on the host cannot get its
# first session there. Requesting from a session of some OTHER domain does not
# fail — it silently names the new session after that other domain, which is
# also the wrong credential space. The comment above says "the trigger is a
# domain acquiring a project", which quietly assumes the domain is already
# there. The first one has to arrive somehow, and this is how.
#
# PARSED BEFORE THE POSITIONALS so the flag never reaches the project-charset
# guard, and so an unknown flag still refuses AS a flag (2026-08-21).
# The gate that keeps it narrow lives further down, where the host is known.
# --label <text>: THE NAME THE SESSION SHOULD CARRY, sent with the request.
#
# The requester knows it; the protocol dropped it, and the hub then filled the
# hole with prefix+name. Measured 2026-08-24: a session ran for a minute under
# an invented label, and an RC label a session has RUN under becomes a pairing
# on the server that stays in a human's list afterwards — a name nobody asked
# for, which cannot be removed from the machines. Absent flag keeps the hub's
# construction, so an un-updated caller behaves exactly as before.
RC_ONSKAD=""
if [ "${1:-}" = "--label" ]; then
  RC_ONSKAD="${2:-}"
  [ -n "$RC_ONSKAD" ] || fel "--label requires a label" 64
  shift 2
fi

DOMAIN_FLAG=""
if [ "${1:-}" = "--domain" ]; then
  DOMAIN_FLAG="${2:-}"
  [ -n "$DOMAIN_FLAG" ] || fel "--domain requires a domain name" 64
  case "$DOMAIN_FLAG" in
    *[!abcdefghijklmnopqrstuvwxyz0123456789-]*) fel "domain may contain only [a-z0-9-]" 64 ;;
  esac
  shift 2
fi

PROJEKT="${1:?bash ~/scripts/session-new.sh [--domain <d>] <project> <repo-path>}"
REPO="${2:?bash ~/scripts/session-new.sh [--domain <d>] <project> <repo-path>}"

# AN UNKNOWN FLAG MUST REFUSE AS A FLAG, NOT PASS AS A NAME. The project
# charset allows dashes, so '--anything' sailed through as a project name and
# the refusal blamed the SECOND argument ("not a git working copy") — a refusal
# naming the wrong cause, measured live 2026-08-21 when the flag's old
# pre-rename spelling was used against the renamed script.
case "$PROJEKT" in
  -*) fel "unknown flag '$PROJEKT' — the flags are --activate <id> <slug>, --label <text> and --domain <d>" 64 ;;
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

# THE GATE THAT KEEPS --domain NARROW. It is accepted ONLY while the host has no
# session in that domain. Once one exists, the derivation above is already the
# right answer, and a flag would let someone quietly file a session under the
# wrong domain — which is the wrong CREDENTIAL SPACE, not just a wrong name.
# That is the same damage measured 2026-08-14, when DOMAIN fell back to the
# session name and one session silently got a private credential store instead
# of the domain's shared one.
#
# THE HOST IS NEVER TAKEN FROM A FLAG. A domain can only be opened on the host
# you already stand on; otherwise the flag would be a way to register sessions
# on machines you hold no account on.
if [ -n "$DOMAIN_FLAG" ]; then
  _existing=""
  for _c in "$SESS_D"/*.conf; do
    [ -e "$_c" ] || continue
    [ "$(sed -n 's/^DOMAIN="\(.*\)"/\1/p' "$_c" | head -1)" = "$DOMAIN_FLAG" ] || continue
    [ "$(sed -n 's/^HOST="\(.*\)"/\1/p' "$_c" | head -1)" = "$VARD" ] || continue
    _existing="$(basename "$_c" .conf)"; break
  done
  # NAME THE EXISTING ONE. A refusal that only says "the domain is already
  # here" leaves the reader to go looking; the name says straight away which
  # session to request from without the flag.
  [ -z "$_existing" ] || fel "--domain is only for a domain's FIRST session on $VARD; '$DOMAIN_FLAG' already has '$_existing' there — drop the flag and request from it" 64
  DOMAN="$DOMAIN_FLAG"
fi

NAMN="${DOMAN}-${PROJEKT}-${PERSON}"
[ -d "$REPO/.git" ] || fel "'$REPO' is not a git working copy — clone the project first"
[ -O "$REPO" ]      || fel "'$REPO' is not owned by $PERSON — a session works in its human's clones"
# AND THE ADVICE HERE HAS A SECOND HALF NOW. "Delete it and re-run" is right
# when the hub never registered anything. When the hub DID register and only
# the CONFIRM was lost, re-running meets the hub's own refusal — which now
# names the existing id and the activation command rather than blaming the
# reused key. Say both, so the operator does not walk the wrong one first.
[ ! -f "$SESS_D/$NAMN.conf" ] || fel "'$NAMN' already has a local conf — if the hub never answered, delete it deliberately and re-run. If the hub DID register and only the ENROLL-CONFIRM was lost, do not re-request: re-run the request and read the hub's refusal, which names the existing id and the '--activate <id> $NAMN' that finishes the birth."

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

# THE WIRE FORMAT IS THE SAME ON BOTH PATHS BELOW — one builder, so the two
# can never drift apart. Field-name notes further down.
bygg_begaran() {
  printf 'DRIFT enroll: %s requests registration\nENROLL-REQUEST v1\nnamn=%s\ndoman=%s\nprojekt=%s\nperson=%s\nvard=%s\nrepo=%s\n' \
    "$NAMN" "$NAMN" "$DOMAN" "$PROJEKT" "$PERSON" "$VARD" "$REPO"
  # BEFORE pubkey: the key must stay the LAST line. A stored payload without
  # a trailing newline once lost its final line, and that line is the one
  # registration hangs on (suite case 8b2).
  [ -n "$RC_ONSKAD" ] && printf 'rc_label=%s\n' "$RC_ONSKAD"
  printf 'pubkey=%s\n' "$PUB"
}

# ── THE HUB ENROLS LOCALLY, WITHOUT THE BUS ─────────────────────────────────
# When the requesting session IS the hub, the bus path defeats itself twice —
# measured live 2026-08-21 on a single-machine estate: (1) this script wrote
# the conf BEFORE sending, and the hub's enroll — reading the SAME registry —
# refused its own request as a name collision; (2) the hub's bus client
# refuses outright in a home that carries relay keys, which a single-machine
# hub's home always does. Both are artifacts of assuming the requester and the
# hub read different registries. So on the hub the request goes straight into
# enroll's stdin, and enroll is the SOLE writer — no pre-written conf, no
# collision, nothing to withdraw on failure.
#
# THE IDENTITY CLAIM IS AS STRONG AS THE BUS PATH'S: STEWARD_ENROLL_FROM is
# normally set by the controller from the relay-key-bound envelope; here the
# name comes from this script's OWN pane — the hub asserting itself to itself,
# on the same machine, under the same account.
if [ "$SJALV" = "$NAV" ]; then
  ENROLL="${STEWARD_ENROLL:-}"
  if [ -z "$ENROLL" ]; then
    _d="$(CDPATH= cd -- "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    for _c in "$_d/bus/enroll" "$_d/hub/enroll"; do
      [ -f "$_c" ] && { ENROLL="$_c"; break; }
    done
  fi
  [ -n "$ENROLL" ] && [ -f "$ENROLL" ] || fel "the hub's enroll was not found beside this script — deployed as bus/enroll, in a checkout as hub/enroll" 78
  # THE ESTATE ROOT TRAVELS WITH THE CALL. Enroll run bare defaults its estate
  # to its own tree — for a checkout that is the PRODUCT, which either refuses
  # (no estate file) or, worse, reads a stranger's. This script has already
  # resolved the estate through the registry; the child must see the same one,
  # not re-derive a different answer from somewhere else entirely.
  # CAPTURED, NOT STREAMED — enroll's own stdout still reaches the operator
  # (printed back below), but capturing it first lets this branch pull the
  # minted id out of enroll's success line ("... registered as s-<hex> ...").
  # There is no separate bus hop here for a later --activate to bridge, so
  # this is the ONLY moment that ever holds both the local name and the id
  # together — the key is linked right here, or never conveniently again.
  _out="$(bygg_begaran | STEWARD_ESTATE_ROOT="$(_registry_estate_root)" \
    STEWARD_ENROLL_FROM="$SJALV" bash "$ENROLL" --send 2>&1)"
  rc=$?
  printf '%s\n' "$_out"
  [ "$rc" -eq 0 ] || fel "enrolment refused — enroll wrote nothing (the key remains), the reason is above" "$rc"
  _id="$(printf '%s' "$_out" | sed -n 's/.*registered as \(s-[0-9a-f]\{16\}\).*/\1/p' | head -1)"
  echo "session-new: '$NAMN' registered hub-locally — no bus hop, enroll was the sole writer."
  if [ -n "$_id" ]; then
    ln -sf "id_busrelay_$NAMN" "$SSH_DIR/id_busrelay_$_id" || fel "could not link the key under the id" 70
    ln -sf "id_busrelay_$NAMN.pub" "$SSH_DIR/id_busrelay_$_id.pub" || fel "could not link the public key under the id" 70
    echo "  next: bash ${BASH_SOURCE[0]} --activate $_id $NAMN"
  else
    # enroll answered form=new but this build's output shape changed under us,
    # or an older enroll is on PATH. THE OLD FALLBACK PRINTED THE NAME-KEYED
    # ACTIVATION, which does not fall back — it succeeds, and supervises the
    # session under a name the register does not file it under, with the
    # id-bound key never engaged. A next step that cannot be constructed is
    # said plainly instead.
    echo "  NOTE: enroll's success line carried no minted id, so the activation command cannot be constructed here." >&2
    echo "  Read the id off the hub's ENROLL-CONFIRM and run: bash ${BASH_SOURCE[0]} --activate <id> $NAMN" >&2
  fi
  exit 0
fi

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
if ! bygg_begaran | "$BUS_SEND" "$NAV"; then
  rm -f "$SESS_D/$NAMN.conf"
  fel "the request did not reach the hub — conf withdrawn (the key remains), re-run" 70
fi

# ── THE RESERVATION: THIS ACCOUNT'S OWN NOTE ABOUT ITS OWN REQUEST ──────────
# Written only after the send succeeded, for the same reason the conf is
# withdrawn on failure: a note about a request nobody received is a half state
# that looks whole. It lives in the account's state directory, NOT in
# sessions.d, because the deploy reconciles sessions.d against the estate
# checkout and deletes exactly this kind of host-local row — and it was that
# deletion, followed by a disk scan for "something that looks pending", that
# linked another session's key under a new id.
#
# Nothing chooses FROM this file. Activation is told the slug by the CONFIRM;
# the reservation only confirms the slug was requested here and names the key.
mkdir -p "$STATE_D" 2>/dev/null || true
if [ -d "$STATE_D" ]; then
  cat > "$STATE_D/enroll-$NAMN.pending" <<RESEOF
# pending enrolment — written by session-new $(date -u +%Y-%m-%dT%H:%M:%SZ).
# Removed by: bash ~/scripts/session-new.sh --activate <id> $NAMN
SLUG="$NAMN"
KEY="$NYCKEL"
HOST="$VARD"
RESEOF
fi

echo "session-new: request sent for '$NAMN'."
# NEVER THE NAME-KEYED FORM. This line lands in the operator's terminal FIRST,
# before the hub answers, and the name-keyed activation it used to print
# SUCCEEDS — it supervises the session under a name-keyed instance against the
# local reservation while the hub filed the row under a minted id and bound the
# key to that id. Two contradictory instructions in one birth, and the wrong one
# arrived first. The id does not exist yet here, so this line names the source
# of the command instead of inventing one.
echo "  next: wait for ENROLL-CONFIRM in your inbox. It prints the exact activation command,"
echo "        which carries both halves of the pairing: --activate <id> $NAMN"
