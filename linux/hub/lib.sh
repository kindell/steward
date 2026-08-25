#!/bin/bash
# Sourced library. Durable file queue for agent-to-agent messages between the
# fleet's tmux sessions. Message content NEVER travels as tmux keystrokes —
# it's written atomically to ~/.config/agent-bus/<to>/inbox/*.json and the
# recipient is woken with a fixed, contentless ping string
# (send-keys -l, same "literal text + separate Enter" shape as
# imessage-router's daemon uses for its own pane interactions). Plain bash +
# jq, no side effects on source — pure function definitions, same contract
# as imessage-router/lib.sh and lib/registry.sh.
#
# Honors STEWARD_BUS_HOME (queue root, default ~/.config/agent-bus) and
# STEWARD_REGISTRY_DIR (sessions.d location, via lib/registry.sh) for testing.

BUS_LIB_DIR="$(CDPATH= cd -- "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# THE REGISTRY LIVES ONE STEP UP IN A DEPLOYED HOME (scripts/bus/ beside
# scripts/lib/) but TWO steps up in the checkout (linux/hub/ beside lib/ at the
# repo root). One fixed hop would make this library loadable in exactly one of
# the two layouts and silently unloadable in the other — and a lib.sh that does
# not load turns every caller into the self-refusing client's shape without its
# explanation. STEWARD_REGISTRY_LIB overrides fully; found nowhere is a refusal,
# because an unreadable registry must not look like an empty one.
if [ -n "${STEWARD_REGISTRY_LIB:-}" ]; then
  # shellcheck source=/dev/null
  source "$STEWARD_REGISTRY_LIB"
elif [ -f "$BUS_LIB_DIR/../lib/registry.sh" ]; then
  # shellcheck source=../lib/registry.sh
  source "$BUS_LIB_DIR/../lib/registry.sh"
elif [ -f "$BUS_LIB_DIR/../../lib/registry.sh" ]; then
  # shellcheck source=/dev/null
  source "$BUS_LIB_DIR/../../lib/registry.sh"
else
  echo "bus/lib.sh: the registry library was found in neither layout (from $BUS_LIB_DIR)" >&2
  return 78
fi

# THE PING IS A FIXED, CONTENTLESS PROMPT — the ONLY thing ever typed into a
# recipient's pane. No message text, no sender name: a busy or idle mailbox
# reveals nothing about what is in it.
#
# THE NOTICE NAMES NO PATH. An earlier version pointed at a checkout that existed
# on the hub but not on the session hosts, so every session there was given an
# instruction it could not follow (reported 2026-08-06 — the fault was in the
# notice, not in any instruction file). It therefore refers to the machine's own
# instructions, which know whether the command is on PATH or carries a path.
#
# IT COMES FROM THE ESTATE, and that is not decoration. The text is a CONSTANT
# compared exactly — that is how the guard tells a ping from real user input —
# AND it is instruction text every running session has been told to react to.
# Changing it mid-flight shows live sessions a signal they do not recognise. The
# key exists to break the coupling in the CODE, not to change the text.
# RESOLVED LAZILY, NOT AT SOURCE TIME. The first version assigned it while the
# library loaded, which made the WHOLE library refuse to load whenever the estate
# was absent — including for callers that only wanted to parse an envelope and
# never ping anybody. A dependency that reaches further than the feature needs it
# is how a library becomes unusable in the environments where it is tested.
# Caught by the envelope suite, which parses without an estate on purpose.
bus_ping_msg() {
  local m
  if ! m="$(registry_ping_msg)"; then
    echo "bus: REFUSING to ping — the estate does not define PING_MSG. A guessed" >&2
    echo "     ping is a ping no session recognises, and the guard could not tell" >&2
    echo "     it from real user input." >&2
    return 78
  fi
  printf '%s' "$m"
}

# ------------------------------------------- the envelope and parked subjects
#
# THIS FILE IS A DELIBERATE, SELF-CONTAINED COPY of the hub's own bus library —
# that is the entire reason it exists: it lives in a home that does NOT have the
# estate's checkout and must not depend on it. It does not source the other
# library, and every GUARD introduced there must be introduced here too.
#
# That did not happen by itself when the envelope was introduced (2026-08-17):
# this copy had zero occurrences of the envelope parser, the parking guard and
# the class list — a complete bypass of both guards. The divergence was triaged
# as cosmetic, but that measurement concerned reachability of the READ path; the
# ENTRY is the send path, and this file is deployed 755 as the bus client.
# Self-refusal in the client saves every home that already has a relay key, but
# the deploy runs BEFORE key creation, and an override exists.
#
# The envelope suite keeps the two libraries in step: this copy's send path is
# exercised for real against a fixture in the DEPLOYED layout, and the class list
# and slug pattern are compared between the files. If they diverge, the test
# fails.
BUS_KLASSER='BESLUT FYND SAMORDNING DRIFT FRAGA'

bus_envelope_parse() {
  local text="$1" rad1 klass rest amne rubrik
  rad1="$(printf '%s\n' "$text" | sed -n 1p)"
  klass="${rad1%% *}"
  case " $BUS_KLASSER " in
    *" $klass "*) : ;;
    *) echo "bus: the envelope has no valid class — the first line must be 'CLASS subject: headline' where CLASS is one of $BUS_KLASSER" >&2; return 65 ;;
  esac
  rest="${rad1#* }"
  case "$rest" in
    *": "*) : ;;
    *) echo "bus: the envelope has no 'subject: headline' after the class — the first line must be 'CLASS subject: headline'" >&2; return 65 ;;
  esac
  amne="${rest%%: *}"
  rubrik="${rest#*: }"
  # The characters are enumerated, never a range: a glob range follows the
  # collation, and in a UTF-8 collation the uppercase letters sit inside a-z. The
  # same fault and the same fix live in the hub's own copy — two files that must
  # behave identically.
  case "$amne" in
    ''|*[!abcdefghijklmnopqrstuvwxyz0123456789-]*)
      echo "bus: the envelope's subject '$amne' is not [a-z0-9-]+ (lowercase, digits, hyphens)" >&2; return 65 ;;
  esac
  # Whitespace alone is not a headline. The two copies must behave identically.
  [ -n "${rubrik//[[:space:]]/}" ] || { echo "bus: the envelope has no headline after the subject (whitespace does not count)" >&2; return 65; }
  printf '%s\n%s\n%s\n' "$klass" "$amne" "$rubrik"
}

# A MISSING LIST MEANS NOTHING IS PARKED, never that everything is. Read
# tolerantly: a final line without a newline is a real line, and CR and
# surrounding whitespace are trimmed.
#
# THREE OUTCOMES: 0 = parked · 1 = not parked · 70 = cannot tell. Absence is
# fail-open; PRESENT-BUT-UNREADABLE is not — a directory, or a mode of 000, used
# to produce silent delivery.
#
# THE OPERATIONS CLASS CANNOT BE PARKED, and the class arrives as an ARGUMENT
# rather than from the exported variable. That class never reaches a human, so
# parking it dampens no noise — it only silences monitoring. The branch sits
# BEFORE the list is read, so that not even an UNREADABLE list can silence an
# alarm.
bus_parked() {
  local amne="$1" klass="${2:-}" fil
  [ "$klass" = DRIFT ] && return 1
  fil="$(bus_home)/parkerade"
  [ -e "$fil" ] || return 1
  if [ ! -f "$fil" ]; then
    echo "bus: the parking list $fil EXISTS but is not a regular file (a directory? a device?) — the guard cannot tell whether the subject is parked" >&2
    return 70
  fi
  if ! ( : < "$fil" ) 2>/dev/null; then
    echo "bus: the parking list $fil EXISTS but cannot be read (permissions? the mount?) — the guard cannot tell whether the subject is parked" >&2
    return 70
  fi
  local rad
  while rad=""; IFS= read -r rad || [ -n "$rad" ]; do
    rad="${rad%$'\r'}"
    rad="${rad#"${rad%%[![:space:]]*}"}"
    rad="${rad%"${rad##*[![:space:]]}"}"
    [ "$rad" = "$amne" ] && return 0
  done < "$fil"
  return 1
}

# bus_home — prints the queue root, honoring STEWARD_BUS_HOME.
bus_home() {
  printf '%s\n' "${STEWARD_BUS_HOME:-$HOME/.config/agent-bus}"
}

# bus_valid_recipient <to> — 0 iff <to> is THE HUB SESSION (always valid, even
# without a conf of its own) or matches a sessions.d/*.conf basename (via the
# registry's registry_list, so STEWARD_REGISTRY_DIR overrides both together for
# tests). No silent-drop path: an unknown recipient is always an error from the
# caller.
#
# The hub's name comes from the estate. It was a literal here, which is exactly
# what kept this file out of the product.
# bus_fraga_tillatet <from> <to> — may <from> put a FRAGA to <to>?
#
# THE RULE: one person's own sessions may ask each other, and sessions working on
# the same ENTITY may ask each other even across people.
#
#   same OWNER   -> yes  (one person's own sessions are a team)
#   same DOMAIN  -> yes  (the entity: two people's sessions in it share the work)
#   otherwise    -> no
#
# WHY A GATE AT ALL. FRAGA was built with no authorisation model, and so gave
# every session the right to ask the hub about the WHOLE registry — an inventory
# of another person's fleet, which the homes' 750 otherwise prevents. Nobody had
# decided that; it was a sharing implemented as the absence of a gate, the same
# shape the CDP port carried before it got its guard.
#
# THE DOMAIN OPENING ACROSS PEOPLE IS THE INTENT, not a hole: two sessions working
# on the same entity need each other's state, and that is exactly the case the
# rule exists for.
#
# REFUSAL IS THE DEFAULT. If owner or domain cannot be read for either party, the
# function answers NO. An unreadable registry must never become a permit. The
# controller name is a valid RECIPIENT even without a conf (bus_valid_recipient),
# but that does not make it a valid FRAGA recipient: with no conf there is no
# owner to compare against.
bus_fraga_falt() { # <session> <FALT> -> vardet, eller tomt
  local s="${1:-}" f="${2:-}" c
  c="$(registry_dir)/$s.conf"
  [ -f "$c" ] || return 1
  sed -n "s/^$f=\"\(.*\)\"/\\1/p" "$c" | head -1
}

# bus_ar_maskinsession <session> — RC-free, i.e. the machine's own session.
# Told apart by WHETHER THE LINE IS THERE, never by the value after source: empty
# and omitted are identical in a shell, and they mean different things here.
bus_ar_maskinsession() {
  local s="${1:-}" c
  c="$(registry_dir)/$s.conf"
  [ -f "$c" ] || return 1
  grep -q '^RC_LABEL=""[[:space:]]*$' "$c"
}

bus_fraga_tillatet() {
  local from_="${1:-}" to_="${2:-}"
  [ -n "$from_" ] && [ -n "$to_" ] || return 1
  local fo ft do_ dt
  fo="$(bus_fraga_falt "$from_" OWNER)"  || return 1
  ft="$(bus_fraga_falt "$to_" OWNER)"  || return 1
  do_="$(bus_fraga_falt "$from_" DOMAIN)" || return 1
  dt="$(bus_fraga_falt "$to_" DOMAIN)" || return 1
  [ -n "$fo" ] && [ -n "$ft" ] && [ -n "$do_" ] && [ -n "$dt" ] || return 1
  [ "$fo" = "$ft" ] && return 0
  [ "$do_" = "$dt" ] && return 0
  # THE MACHINE SESSION BELONGS TO EVERYONE WHO LIVES ON THE MACHINE. It does not
  # carry an entity — it carries a MACHINE — so the owner/domain rule would close
  # it to everyone but its own account, and it would then be useless for its only
  # purpose. The spec's case: another person's session sends to the machine
  # session, which does the sudo-scoped work WITHIN the machine.
  #
  # THE LIMIT IS LIVING THERE. Having a session on the machine is already having a
  # foothold on it; being allowed to ask its machine session grants no new surface.
  # Someone WITHOUT a session there may not ask — otherwise the machine layer would
  # be a shortcut past both the owner and the entity boundary.
  if bus_ar_maskinsession "$to_"; then
    local mh fh
    mh="$(bus_fraga_falt "$to_" HOST)"; fh="$(bus_fraga_falt "$from_" HOST)"
    [ -n "$mh" ] && [ -n "$fh" ] && [ "$mh" = "$fh" ] && return 0
  fi
  return 1
}

bus_valid_recipient() {
  local to="${1:-}"
  [ -z "$to" ] && return 1
  local hub; hub="$(registry_hub_session)" || return 1
  [ "$to" = "$hub" ] && return 0
  registry_list | grep -qxF "$to"
}

# ------------------------------------------------------------- tmux ping

# bus_tmux_sock — the hub's tmux socket path.
#
# THE SOCKET'S FILE NAME BELONGS TO THE ESTATE. It was a literal here, and it is a
# LIVE runtime path: the server holding every session created it, and renaming it
# would leave every client unable to find a server that is still running. The key
# exists to break the coupling in the code, not to rename the socket.
#
# STEWARD_BUS_TMUX_SOCK still overrides it whole, for tests.
bus_tmux_sock() {
  if [ -n "${STEWARD_BUS_TMUX_SOCK:-}" ]; then printf '%s' "$STEWARD_BUS_TMUX_SOCK"; return 0; fi
  local s; s="$(registry_tmux_socket)" || return 78
  printf '%s' "$HOME/.tmux/$s"
}
# Thin, individually-overridable wrappers around the real tmux calls — tests
# redefine these three functions (same pattern imessage-router-lib.test.sh
# uses for router_boot_epoch) so bus_tmux_ping's busy-gate logic runs for
# real without ever touching a real tmux server.

bus_tmux_has_session() {
  local to="${1:-}"
  "${STEWARD_BUS_TMUX_BIN:-/opt/homebrew/bin/tmux}" -S "$(bus_tmux_sock)" \
    has-session -t "$to" 2>/dev/null
}

bus_tmux_capture_pane() {
  local to="${1:-}"
  "${STEWARD_BUS_TMUX_BIN:-/opt/homebrew/bin/tmux}" -S "$(bus_tmux_sock)" \
    capture-pane -t "$to" -p 2>/dev/null
}

# bus_tmux_send_keys <to> <text> — literal text (-l, never interpreted) then
# a separately-sent Enter — a fixed string followed by a separate Enter, never
# one interpreted keystroke sequence.
bus_tmux_send_keys() {
  local to="${1:-}" text="${2:-}"
  local bin="${STEWARD_BUS_TMUX_BIN:-/opt/homebrew/bin/tmux}" sock; sock="$(bus_tmux_sock)"
  "$bin" -S "$sock" send-keys -t "$to" -l "$text" 2>/dev/null
  "$bin" -S "$sock" send-keys -t "$to" Enter 2>/dev/null
}

# bus_recipient_busy <to> — is the recipient working right now?
#
# A PING AT A BUSY SESSION IS LOST. send-keys returns without error even when the
# recipient is mid-tool-call — the keystrokes land in the input queue and never
# appear as a ping. The sender therefore believes the mail was delivered.
#
# One session missed two messages in a row this way on 2026-08-11: both arrived
# while it was running parallel work, and both lay unread until somebody pinged
# again once it was idle. It was found by a human asking "are you sending a tmux
# ping too?" — not by any alarm, because the unacknowledged-mail alarm requires
# somebody to SEE it.
#
# The classic shape: delivery looks done from the sender's side.
bus_recipient_busy() {
  local to="${1:-}"
  local bin="${STEWARD_BUS_TMUX_BIN:-/opt/homebrew/bin/tmux}" sock; sock="$(bus_tmux_sock)"
  "$bin" -S "$sock" capture-pane -p -t "$to" 2>/dev/null | grep -q "esc to interrupt"
}

# bus_pane_busy <pane-text> — pure predicate: 0 iff <pane-text> shows the
# session mid-turn ("esc to interrupt" or the "… (" spinner prefix) — same
# signal watchdog/lib.mjs's paneState() uses.
bus_pane_busy() {
  local text="${1:-}"
  case "$text" in
    *'esc to interrupt'*) return 0 ;;
  esac
  case "$text" in
    *'… ('*) return 0 ;;
  esac
  return 1
}

# bus_tmux_ping <to> — default pingfn for bus_send. Pings ONLY if <to> has a
# live tmux session AND that session's pane is not busy; otherwise a silent
# no-op (post already durably queued — the watchdog/next ping is the
# fallback: losing a ping is harmless, because the message is already queued).
bus_tmux_ping() {
  local to="${1:-}"
  bus_tmux_has_session "$to" || return 0
  local pane; pane="$(bus_tmux_capture_pane "$to")"
  bus_pane_busy "$pane" && return 0
  local ping; ping="$(bus_ping_msg)" || return 78
  bus_tmux_send_keys "$to" "$ping"
  # TELL THE TRUTH ABOUT DELIVERY. A silent "sent" is a false receipt while the
  # recipient is working; the queue wakes it only once it is idle (or when
  # supervision pings again).
  if bus_recipient_busy "$to"; then
    echo "bus: $to IS BUSY — the ping may have been lost. The mail is queued and supervision will ping again once the session is idle." >&2
  fi
}

# ------------------------------------------------------------- queue ops

# bus_send <to> <from> <text> [pingfn] — validates <to>, writes the message
# atomically (tmp in the same inbox dir + mv, never a partial file visible to
# a concurrent reader), then calls [pingfn] (default: bus_tmux_ping) with
# <to>. Prints the written filename on stdout and returns 0 on success;
# returns 1 (message to stderr, nothing written) if <to> is unknown. A ping
# failure never fails the send — the message is already durably queued.
# bus_recipient_host <to> — which machine does the recipient live on? Reads HOST
# from the sessions.d conf, defaulting to the hub's host. The hub session lives on
# the hub by definition. An unknown name yields an empty string — the caller has
# already validated.
#
# BOTH the hub's SESSION name and the hub's HOST name come from the estate, and
# they are two keys even though they hold the same string here. A product that
# assumes they are always equal breaks the first time somebody names a machine
# after the room it stands in and a session after what it does.
bus_recipient_host() {
  local to="${1:-}"
  local hub_s hub_h
  hub_s="$(registry_hub_session)" || return 1
  hub_h="$(registry_hub_host)"    || return 1
  [ "$to" = "$hub_s" ] && { printf '%s' "$hub_h"; return 0; }
  local conf; conf="$(registry_dir)/$to.conf"
  [ -f "$conf" ] || return 1
  local h; h="$(grep -m1 '^HOST=' "$conf" | tr -d '"' | cut -d= -f2)"
  case "$h" in *[!abcdefghijklmnopqrstuvwxyz0123456789-]*) h='' ;; esac
  printf '%s' "${h:-$hub_h}"
}

# bus_recipient_owner <to> — which ACCOUNT on the host owns the recipient?
#
# Without this the relay ssh'd as the host alias's default user and wrote the
# inbox into the WRONG HOME: a session's queue and tmux live under its owner's
# account, not under whichever account the alias happens to name. A message
# delivered where nobody reads it is worse than one that bounces.
#
# REFUSAL, NOT A GUESSED ACCOUNT. This function used to fall back on a person's
# name — an estate value in a product file, and worse, a guess that produces
# exactly the misdelivery the function exists to prevent. There is nothing
# sensible to guess: the caller has already validated the recipient, so a missing
# or malformed OWNER means the registry is broken, and a broken registry must say
# so rather than pick a home.
bus_recipient_owner() {
  local to="${1:-}"
  local conf; conf="$(registry_dir)/$to.conf"
  if [ ! -f "$conf" ]; then
    echo "bus: no conf for '$to' — cannot tell which account owns the recipient" >&2
    return 1
  fi
  local o; o="$(grep -m1 '^OWNER=' "$conf" | tr -d '"' | cut -d= -f2)"
  case "$o" in
    ''|*[!abcdefghijklmnopqrstuvwxyz0123456789-]*)
      echo "bus: OWNER missing or malformed in $conf — refusing to guess an account" >&2
      echo "     to deliver into; a queue in the wrong home is never read." >&2
      return 1 ;;
  esac
  printf '%s' "$o"
}

# bus_remote_deliver <host> <to> <from> <text> — the same guarantee as locally,
# but over ssh: a durable queue AT THE RECIPIENT, an atomic name via ln, and a
# contentless ping gated on the recipient not being busy. The message is built as
# JSON locally (jq) and piped — no value passes through an argument list.
# Overridable in tests, exactly like the bus_tmux_* trio.
bus_remote_deliver() {
  local host="$1" to="$2" from="$3" text="$4" owner="${5:-}"
  local now; now="$(date +%s)"
  local safe_from; safe_from="$(printf '%s' "$from" | tr -c 'A-Za-z0-9._-' '_')"
  # EVERYTHING goes through stdin — four header lines and then JSON to EOF. The
  # remote script is ENTIRELY static (single-quoted, zero interpolation): no
  # quoting bug, and no value can become shell code on the other side. The first
  # attempt built the script with embedded variables and died on nested quotes.
  local ping; ping="$(bus_ping_msg)" || return 78
  { printf '%s\n%s\n%s\n%s\n' "$to" "$now" "$safe_from" "$ping"
    jq -n --arg from "$from" --arg to "$to" --argjson ts "$now" --arg text "$text" \
      '{from: $from, to: $to, ts: $ts, text: $text}'
  } | "${STEWARD_BUS_SSH_BIN:-ssh}" -o BatchMode=yes -o ConnectTimeout=8 ${owner:+-l "$owner"} "$host" '
    set -u
    IFS= read -r to; IFS= read -r now; IFS= read -r sf; IFS= read -r ping
    case "$to" in *[!abcdefghijklmnopqrstuvwxyz0123456789-]*|"") echo "relay: bad recipient" >&2; exit 1;; esac
    inbox="$HOME/.config/agent-bus/$to/inbox"
    mkdir -p "$inbox" || exit 1
    tmp="$(mktemp "$inbox/.tmp.XXXXXX")" || exit 1
    cat > "$tmp" || { rm -f "$tmp"; exit 1; }
    f="$now-$sf-$$.json"; n=1
    until ln "$tmp" "$inbox/$f" 2>/dev/null; do
      n=$((n+1)); [ "$n" -gt 10000 ] && { rm -f "$tmp"; exit 1; }
      f="$now-$sf-$$-$n.json"
    done
    rm -f "$tmp"
    if tmux has-session -t "$to" 2>/dev/null; then
      pane="$(tmux capture-pane -t "$to" -p 2>/dev/null)"
      case "$pane" in
        *"esc to interrupt"*|*"… ("*) : ;;
        *) tmux send-keys -t "$to" -l "$ping" 2>/dev/null
           tmux send-keys -t "$to" Enter 2>/dev/null ;;
      esac
    fi
    printf "%s\n" "$f"'
}

bus_send() {
  local to="${1:-}" from="${2:-}" text="${3:-}" pingfn="${4:-bus_tmux_ping}"
  # THE ENVELOPE GUARD COMES FIRST, the same order as in the hub's own copy: a
  # refusal must not leave half a delivery behind, and the envelope is cheaper to
  # check than the recipient.
  local _env; _env="$(bus_envelope_parse "$text")" || return 65
  BUS_KLASS="$(printf '%s\n' "$_env" | sed -n 1p)"
  BUS_AMNE="$(printf '%s\n' "$_env" | sed -n 2p)"
  BUS_RUBRIK="$(printf '%s\n' "$_env" | sed -n 3p)"
  export BUS_KLASS BUS_AMNE BUS_RUBRIK
  local _prc=0; bus_parked "$BUS_AMNE" "$BUS_KLASS" || _prc=$?
  case "$_prc" in
    0)  echo "bus: the subject '$BUS_AMNE' is parked — nothing is sent. Remove the line from $(bus_home)/parkerade when it is taken up again." >&2
        return 65 ;;
    70) echo "bus: NOTHING IS SENT — the parking guard could not read its list (the reason is above). Repair the list, or remove it if nothing should be parked." >&2
        return 70 ;;
  esac
  if ! bus_valid_recipient "$to"; then
    echo "bus: unknown recipient '$to'" >&2
    return 1
  fi
  # THE FRAGA GATE. Only this class is restricted — ordinary messages are
  # unchanged. The reason: a FRAGA is answered MECHANICALLY out of a registry, so
  # it hands the asker something they could not otherwise see (homes are 750). An
  # ordinary message conveys only what the sender writes themselves.
  #
  # THE REFUSAL IS LOUD AND EXPLAINS THE RULE. A gate that only says no teaches
  # nothing, and the next attempt is identical.
  if [ "${BUS_KLASS:-}" = "FRAGA" ] && ! bus_fraga_tillatet "$from" "$to"; then
    echo "bus: '$from' may not put a FRAGA to '$to'." >&2
    echo "     Regeln: samma AGARE, eller samma DOMAN (entiteten man jobbar pa)." >&2
    echo "     Vanliga meddelanden (BESLUT FYND SAMORDNING DRIFT) ar oberorda." >&2
    return 1
  fi
  # If the recipient lives on another machine, deliver over ssh — the queue lands
  # AT the recipient, never in an intermediary that can be forgotten.
  local rhost; rhost="$(bus_recipient_host "$to")"
  # WHICH MACHINE AM I? Defaults to the hub's host from the estate, because this
  # client belongs on the hub. STEWARD_BUS_LOCAL_HOST overrides it for tests.
  local localhost_name="${STEWARD_BUS_LOCAL_HOST:-}"
  [ -n "$localhost_name" ] || localhost_name="$(registry_hub_host)" || return 78
  if [ -n "$rhost" ] && [ "$rhost" != "$localhost_name" ]; then
    # THE OWNER IS RESOLVED BEFORE THE SEND, not inline in the argument list: it
    # can now REFUSE, and a refusal inside a command substitution would have been
    # swallowed and delivered as an empty account.
    local rowner
    if ! rowner="$(bus_recipient_owner "$to")"; then
      echo "bus: NOTHING IS SENT to '$to' — the owning account could not be resolved." >&2
      return 78
    fi
    bus_remote_deliver "$rhost" "$to" "$from" "$text" "$rowner"
    return $?
  fi
  local inbox; inbox="$(bus_home)/$to/inbox"
  mkdir -p "$inbox" || return 1

  local now; now="$(date +%s)"
  local safe_from; safe_from="$(printf '%s' "$from" | tr -c 'A-Za-z0-9._-' '_')"

  local tmp; tmp="$(mktemp "$inbox/.tmp.XXXXXX")" || return 1
  if ! jq -n --arg from "$from" --arg to "$to" --argjson ts "$now" --arg text "$text" \
      '{from: $from, to: $to, ts: $ts, text: $text}' > "$tmp" 2>/dev/null; then
    echo "bus: jq failed building message to '$to'" >&2
    rm -f "$tmp"
    return 1
  fi
  # Race-free name allocation (a review measured that check-then-mv silently lost
  # 27 of 30 concurrent sends from the same process). ln(1) is atomic — the link
  # FAILS if the target name already exists, so the loop tries the next suffix
  # until it wins. No window, no silent overwrite.
  local fname="${now}-${safe_from}-$$.json" n=1
  until ln "$tmp" "$inbox/$fname" 2>/dev/null; do
    n=$((n + 1))
    if [ "$n" -gt 10000 ]; then
      echo "bus: could not allocate filename for message to '$to'" >&2
      rm -f "$tmp"
      return 1
    fi
    fname="${now}-${safe_from}-$$-$n.json"
  done
  rm -f "$tmp"

  printf '%s\n' "$fname"
  "$pingfn" "$to" || true
  return 0
}

# bus_list_unacked <to> — one line per pending inbox entry:
# "<file>|<age_s>|<from>", sorted oldest-first (filename = epoch prefix).
# Prints nothing (rc 0) if <to> has no inbox yet.
bus_list_unacked() {
  local to="${1:-}"
  local inbox; inbox="$(bus_home)/$to/inbox"
  [ -d "$inbox" ] || return 0
  local now; now="$(date +%s)"
  local f ts from age
  while IFS= read -r f; do
    [ -e "$f" ] || continue
    ts="$(jq -r '.ts // empty' "$f" 2>/dev/null)"
    from="$(jq -r '.from // empty' "$f" 2>/dev/null)"
    case "$ts" in (*[!0-9]*|"") ts=0 ;; esac
    age=$((now - ts))
    printf '%s|%s|%s\n' "$f" "$age" "$from"
  done < <(find "$inbox" -maxdepth 1 -type f -name '*.json' -print 2>/dev/null | sort)
}

# bus_read <to> — the recipient's only command: prints every inbox entry
# (from, ts, text — one per line) and acks EACH by moving it to done/ (never
# rm — done/ is cleaned up later by bus_gc). Prints nothing and is a safe
# no-op if <to> is unknown or has no inbox.
bus_read() {
  local to="${1:-}"
  bus_valid_recipient "$to" || return 0
  local base; base="$(bus_home)/$to"
  local inbox="$base/inbox" done_dir="$base/done"
  [ -d "$inbox" ] || return 0
  mkdir -p "$done_dir" || return 1
  local f from ts text
  while IFS= read -r f; do
    [ -e "$f" ] || continue
    from="$(jq -r '.from // empty' "$f" 2>/dev/null)"
    ts="$(jq -r '.ts // empty' "$f" 2>/dev/null)"
    text="$(jq -r '.text // empty' "$f" 2>/dev/null)"
    printf 'from=%s ts=%s text=%s\n' "$from" "$ts" "$text"
    mv -f "$f" "$done_dir/$(basename "$f")" 2>/dev/null
  done < <(find "$inbox" -maxdepth 1 -type f -name '*.json' -print 2>/dev/null | sort)
}

# bus_gc <days> — removes done/ entries (any recipient) older than <days>
# (mtime-based — done/ entries are acked receipts, not live content, so
# filesystem mtime at ack time is the right clock). Default 7 days, per plan.
bus_gc() {
  local days="${1:-7}"
  local home; home="$(bus_home)"
  [ -d "$home" ] || return 0
  local d
  while IFS= read -r d; do
    [ -d "$d" ] || continue
    find "$d" -maxdepth 1 -type f -name '*.json' -mtime "+$days" -delete 2>/dev/null
  done < <(find "$home" -mindepth 2 -maxdepth 2 -type d -name done -print 2>/dev/null)
}
