#!/bin/bash
# linux/estate-status.sh — the estate's sessions, one row each, joined from the
# machinery itself: registry ⋈ tmux ⋈ supervision timers. READ-ONLY, always.
#
# WHY IT EXISTS. "Which sessions can you see?" was asked inside a session whose
# discovery tools had been deliberately turned off (the account-wide messaging
# layer crosses estate boundaries, so estates close it). The honest answer must
# then come from the estate's OWN data — and it already sits readable on disk;
# what was missing was one command that joins it. The same command serves the
# human over ssh, the laptop client, and the session itself.
#
# The output is a MEASUREMENT, not a promise: tmux and timers are read at this
# instant, on THIS machine. Sessions registered for other hosts are shown with
# their host name and a dash — visible, but not answered for from here.
set -uo pipefail

_reg_lib_default() {
  local d c
  d="$(CDPATH= cd -- "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  for c in "$HOME/scripts/lib/registry.sh" "$d/lib/registry.sh" "$d/../lib/registry.sh"; do
    [ -f "$c" ] && { printf '%s' "$c"; return 0; }
  done
  printf '%s' "$HOME/scripts/lib/registry.sh"
}
REG_LIB="${STEWARD_REGISTRY_LIB:-$(_reg_lib_default)}"
[ -f "$REG_LIB" ] || { echo "estate-status: REFUSING — registry library missing: $REG_LIB" >&2; exit 78; }
# shellcheck source=/dev/null
. "$REG_LIB" || { echo "estate-status: REFUSING — registry library could not be read: $REG_LIB" >&2; exit 78; }

RDIR="$(registry_dir)" || exit 78
HUB_HOST="$(registry_hub_host)" || exit 78
SELF_HOST="${STEWARD_SELF_HOST:-$(hostname -s)}"
# VEM ÄR "JAG" I EN LISTA ÖVER FLERA MÄNNISKORS SESSIONER. Det unix-konto som
# kör kommandot — inte en gissning ur sessionsnamnet, och inte $USER som en
# systemd-timer kan lämna osatt. En felaktig självbild här är tyst: den gör bara
# att fel rader saknar sin markör, vilket ser ut som att man inte äger något.
SELF_USER="${STEWARD_SELF_USER:-$(id -un)}"

# TMUX IS RESOLVED, NOT ASSUMED. Over ssh the PATH is bare (a package-manager
# prefix is a login-shell luxury), and an estate may run its server on a NAMED
# socket under ~/.tmux — measured on a live hub where the plain command found
# neither binary nor server and every session read as down. The named socket is
# used only when it actually EXISTS: an estate file may name a socket its
# machinery never created, and asking a nonexistent server about sessions would
# report a healthy fleet as dead.
TMUX_BIN="tmux"
if ! command -v tmux >/dev/null 2>&1; then
  for _c in /opt/homebrew/bin/tmux /usr/local/bin/tmux /usr/bin/tmux; do
    [ -x "$_c" ] && { TMUX_BIN="$_c"; break; }
  done
fi
SOCK="$(registry_tmux_socket 2>/dev/null || true)"
_tmux() {
  if [ -n "$SOCK" ] && [ -S "$HOME/.tmux/$SOCK" ]; then
    "$TMUX_BIN" -S "$HOME/.tmux/$SOCK" "$@"
  else
    "$TMUX_BIN" "$@"
  fi
}

# peek <session> — the session's screen, right now. Read-only like everything
# here; the exact target form for the same prefix-trap reason as below.
if [ "${1:-}" = "peek" ]; then
  _n="${2:?usage: estate-status.sh peek <session>}"
  # Exact guard first (=is session-target notation), THEN the plain name for
  # capture-pane, which parses its target as a PANE and rejects the =form —
  # measured on tmux 3.4/3.6b. With exact existence established, tmux resolves
  # the exact name before any prefix match.
  _tmux has-session -t "=$_n" 2>/dev/null \
    || { echo "estate-status: no live tmux session '$_n' here" >&2; exit 65; }
  _tmux capture-pane -p -t "$_n" 2>/dev/null \
    || { echo "estate-status: the pane could not be read for '$_n'" >&2; exit 70; }
  exit 0
fi

# A conf without HOST lives on the hub — the registry's own convention.
have_confs=""
rows=""
for conf in "$RDIR"/*.conf; do
  [ -f "$conf" ] || continue
  have_confs=1
  name="$(basename "$conf" .conf)"
  host="$(sed -n 's/^HOST="\(.*\)"/\1/p' "$conf" | head -1)"
  owner="$(sed -n 's/^OWNER="\(.*\)"/\1/p' "$conf" | head -1)"
  rc="$(sed -n 's/^RC_LABEL="\(.*\)"/\1/p' "$conf" | head -1)"
  host="${host:-$HUB_HOST}"
  if [ "$host" = "$SELF_HOST" ]; then
    # =name, the exact form — tmux -t prefix-matches, and a session whose name
    # prefixes a sibling's would otherwise borrow the sibling's answer
    # (measured live 2026-08-21, same fault family as the supervisor's).
    if _tmux has-session -t "=$name" 2>/dev/null; then tm="up"; else tm="down"; fi
    if command -v systemctl >/dev/null 2>&1 \
       && systemctl --user is-active "agent-session@$name.timer" >/dev/null 2>&1; then
      ti="active"
    else
      ti="-"
    fi
  else
    tm="?($host)"; ti="?($host)"
  fi
  # ÄGARSKAP SOM EGEN KOLUMN, INTE SOM NÅGOT LÄSAREN FÅR RÄKNA UT.
  #
  # Listan visade tidigare varje sessions OWNER och lät den som läste jämföra
  # med sig själv. Det låter likvärdigt och är det inte: frågan som ställs inne
  # i en session är nästan aldrig "vem äger den här raden" utan "vilka är MINA",
  # och en lista som kräver att läsaren håller sitt eget användarnamn i huvudet
  # besvarar den andra frågan medan den ser ut att besvara den första. I en
  # flotta där en maskin bär FLERA människors sessioner är det skillnaden
  # mellan att se sin grupp och att se ett register.
  #
  # Markören är '*' i en egen kolumn och sorteringen lägger dina först — samma
  # svar, men läsbart utan att räkna.
  if [ "${owner:-}" = "$SELF_USER" ]; then mine="*"; sortkey="0"; else mine=" "; sortkey="1"; fi
  rows="$rows$sortkey|$mine|$name|${owner:-?}|$host|$tm|$ti|${rc:-?}
"
done

if [ -z "$have_confs" ]; then
  echo "estate-status: the registry at $RDIR holds no sessions."
  echo "  An empty registry is a real answer — but if you expected sessions, the"
  echo "  estate root may be wrong: STEWARD_ESTATE_ROOT=$(_registry_estate_root)"
  exit 0
fi

# --mine: bara dina. För den som vet vad hen frågar efter och inte vill läsa
# förbi grannens rader. Utan flaggan visas allt, med dina först — att GRANNENS
# sessioner syns är inte en läcka utan poängen: en maskin med flera människors
# sessioner måste gå att förstå av var och en som bor där.
only_mine=""; want_remote=""
for _a in "$@"; do
  case "$_a" in
    --mine|-m)   only_mine=1 ;;
    --remote|-r) want_remote=1 ;;
    --help|-h)   echo "usage: estate-status.sh [--mine] [--remote]" >&2; exit 0 ;;
    *)           echo "estate-status: unknown option '$_a'" >&2; exit 64 ;;
  esac
done

# --remote: FYLL I DE FRÅGETECKEN SOM ÄR DINA ATT FYLLA I.
#
# Utan flaggan svarar listan bara för den här maskinen, och sessioner på andra
# värdar står som ?(värd). Det är ärligt men otillräckligt för den vanligaste
# frågan inifrån en session: lever mina syskon? På en flotta där de flesta av
# dina sessioner bor någon annanstans är en lista med tio frågetecken inget svar.
#
# DEN SVARAR BARA FÖR DINA. Uppslaget sker som DITT unix-konto över ssh, så det
# kan bara se din egen tmux-server på den andra maskinen. Grannens rader förblir
# ?(värd) — inte av försiktighet utan för att det är sant: hemmen är 750 och ditt
# konto ser inte deras server. En rad som påstod något om en annan människas
# session hade varit en gissning i en kolumn som ser ut att vara en mätning.
#
# EN OPÅLITLIG VÄRD GER ?(värd unreachable), ALDRIG "down". Skillnaden är hela
# poängen: "down" är ett larm någon agerar på, "kan inte nå" är en fråga om
# nätet. Att slå ihop dem är att göra ett tyst fel av ett synligt.
if [ -n "$want_remote" ]; then
  _hosts="$(printf '%s' "$rows" | awk -F'|' -v me="$SELF_USER" -v self="$SELF_HOST" '$4==me && $5!=self {print $5}' | sort -u)"
  for _h in $_hosts; do
    _live="$(ssh -o BatchMode=yes -o ConnectTimeout=8 -l "$SELF_USER" "$_h" \
              'tmux ls 2>/dev/null | cut -d: -f1' 2>/dev/null)" || _live="__UNREACHABLE__"
    if [ "$_live" = "__UNREACHABLE__" ]; then
      rows="$(printf '%s' "$rows" | awk -F'|' -v OFS='|' -v me="$SELF_USER" -v h="$_h" \
              '{ if ($4==me && $5==h) { $6="?(" h " unreachable)"; $7=$6 } ; print }')"
      continue
    fi
    # NYRADER FÅR INTE RESA I EN awk -v. En variabel med radbrytningar bryter
    # awk:s egen tolkning av programtexten — den föll på det här en gång och
    # felet såg ut som ett tomt register, alltså det enda utfall som absolut
    # inte får uppstå av ett formateringsfel. Listan plattas därför till en
    # mellanslagsseparerad rad före överlämningen.
    _live_flat="$(printf '%s' "$_live" | tr '\n' ' ')"
    rows="$(printf '%s' "$rows" | awk -F'|' -v OFS='|' -v me="$SELF_USER" -v h="$_h" -v live="$_live_flat" '
      BEGIN { n=split(live, a, " "); for (i=1;i<=n;i++) if (a[i]!="") up[a[i]]=1 }
      { if ($4==me && $5==h) { $6 = ($3 in up) ? "up" : "down"; $7="-" } ; print }')"
  done
fi

_body="$(printf '%s' "$rows" | sort -t'|' -k1,1 -k3,3)"
if [ -n "$only_mine" ]; then
  _body="$(printf '%s\n' "$_body" | awk -F'|' '$1=="0"')"
  if [ -z "$_body" ]; then
    # NOLL ÄR ETT SVAR, inte en tom utskrift. En tom lista och ett trasigt
    # uppslag ser annars likadana ut.
    echo "estate-status: inga sessioner ägs av '$SELF_USER' i registret på $SELF_HOST."
    echo "  (Kör utan --mine för att se hela registret: $(printf '%s' "$rows" | grep -c . ) rader.)"
    exit 0
  fi
fi

printf '%s\n' "$_body" | cut -d'|' -f2- | {
  printf ' |SESSION|OWNER|HOST|TMUX|TIMER|RC_LABEL\n'
  cat
} | column -t -s '|'

if [ -z "$only_mine" ]; then
  _n_mine="$(printf '%s' "$rows" | awk -F'|' '$1=="0"' | grep -c .)"
  _n_all="$(printf '%s' "$rows" | grep -c .)"
  printf '\n  * = dina (%s av %s). Andras sessioner visas för att maskinen delas.\n' "$_n_mine" "$_n_all"
fi
