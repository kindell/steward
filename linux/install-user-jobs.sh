#!/bin/bash
# linux/install-user-jobs.sh [--enable] — generera jobb-ogonblicksbilden ur
# domanrepona, och sag vad som INTE stammer med timrarna.
#
# VARFOR DEN FINNS. agent-job@ laser sina confar ur en OGONBLICKSBILD
# ($HOME/scripts/jobs.d), inte ur domanrepona — med flit: ett jobb ska kunna
# starta utan att lasa nagon annans utcheckning. Pa navet genererar dess egen
# installerare den katalogen. Pa Linux fanns ingen motsvarighet alls.
#
# Foljden var inte teoretisk. En doman rattade sin jobbconf i KALLAN, korrekt och
# verifierad — och andringen var verkningslos, for det som kors ar
# ogonblicksbilden. Jobbet gick blint i sjuttio timmar, och de sista timmarna
# berodde pa att ingen visste att ett manuellt steg fanns. Ogonblicksbilden var
# da fyra veckor gammal och saknade TVA falt mot kallan, inte ett.
#
# EN FIL SOM INGEN GENERERAR MEN SOM ALLT LASER ar en aterkommande form i det har
# tradet. Nar bada registren kan bara sanningen ar losningen att TA BORT det ena;
# har gar inte det, eftersom ogonblicksbilden har ett eget syfte. Da ar losningen
# en generator — alltsa den har filen.
#
# LASER OCH SKRIVER BARA I DEN EGNA ANVANDARENS HEM. Ingen sudo, ingen annans
# katalog: varje manniska driftar sina egna jobb, precis som sina egna sessioner.
set -uo pipefail

ENABLE=""
case "${1:-}" in
  --enable) ENABLE=1 ;;
  "") ;;
  *) echo "anvandning: install-user-jobs.sh [--enable]" >&2; exit 64 ;;
esac

HOME_SCRIPTS="${STEWARD_HOME_SCRIPTS:-$HOME/scripts}"
SOURCES="$HOME_SCRIPTS/jobs-sources.conf"
SNAPDIR="$HOME_SCRIPTS/jobs.d"

_reg_lib() {
  local c
  for c in "$HOME_SCRIPTS/lib/registry.sh" "$(dirname "${BASH_SOURCE[0]}")/../lib/registry.sh"; do
    [ -f "$c" ] && { printf '%s' "$c"; return 0; }
  done
  return 1
}
REG="${STEWARD_REGISTRY_LIB:-$(_reg_lib)}" || REG=""
# ETT REGISTER SOM INTE GAR ATT LASA FAR ALDRIG SE UT SOM ETT TOMT. Utan
# biblioteket kan ingen conf VALIDERAS, och att kopiera ovaliderade confar vore
# att flytta felet narmare korningen i stallet for att fanga det.
[ -n "$REG" ] && [ -f "$REG" ] || { echo "install-user-jobs: VAGRAR — registerbiblioteket saknas" >&2; exit 78; }
# shellcheck source=/dev/null
. "$REG" || { echo "install-user-jobs: VAGRAR — registerbiblioteket gick inte att lasa" >&2; exit 78; }

if [ ! -f "$SOURCES" ]; then
  # SKILLNADEN MELLAN "INGA KALLOR" OCH "INGEN KALLISTA" ar hela poangen med den
  # har filen: den forsta ar ett svar, den andra ar en trasig installation.
  echo "install-user-jobs: VAGRAR — kallistan saknas: $SOURCES" >&2
  echo "  En rad per domanrepo. Utan den vet ingen VILKA jobb som ska finnas." >&2
  exit 78
fi
mkdir -p "$SNAPDIR" || exit 78

fel=0; skrivna=0; oforandrade=0; seen=""
while IFS= read -r srcrepo; do
  case "$srcrepo" in ''|\#*) continue ;; esac
  if [ ! -d "$srcrepo/jobs.d" ]; then
    echo "install-user-jobs: kallan '$srcrepo' har ingen jobs.d — hoppar" >&2
    continue
  fi
  for conf in "$srcrepo"/jobs.d/*.conf; do
    [ -e "$conf" ] || continue
    # EN OGILTIG CONF FALLER KORNINGEN, men stoppar inte de ovriga. Att avbryta
    # helt hade latit ett trasigt jobb halla alla andra gisslan; att tiga hade
    # gett en gron korning som utelamnade ett jobb.
    if ! registry_job_load "$conf" >/dev/null 2>&1; then
      echo "install-user-jobs: OGILTIG conf, hoppas over: $conf" >&2
      registry_job_load "$conf" 2>&1 | sed 's/^/    /' >&2
      fel=1; continue
    fi
    snapname="$DOMAIN-$JOB_NAME.conf"
    case " $seen " in
      *" $snapname "*)
        echo "install-user-jobs: DUBBLETT $snapname fran flera kallor — behaller den forsta" >&2
        fel=1; continue ;;
    esac
    seen="$seen $snapname"
    if cmp -s "$conf" "$SNAPDIR/$snapname"; then
      oforandrade=$((oforandrade+1))
    else
      cp "$conf" "$SNAPDIR/$snapname" || { echo "install-user-jobs: kunde inte skriva $snapname" >&2; fel=1; continue; }
      echo "  uppdaterad: $snapname"
      skrivna=$((skrivna+1))
    fi
  done
done < "$SOURCES"

# --- foraldralosa ogonblicksbilder -------------------------------------------
# En conf vars kalla forsvunnit kors ANDA tills nagon tar bort den. Den rensas
# inte automatiskt: att radera ur en katalog som ocksa bar handkopior och
# backuper ar en oaterkallelig handling pa svagt underlag. Den NAMNGES.
foraldralosa=""
for f in "$SNAPDIR"/*.conf; do
  [ -e "$f" ] || continue
  b="$(basename "$f")"
  case " $seen " in *" $b "*) continue ;; esac
  foraldralosa="$foraldralosa $b"
done

# --- timrarna ----------------------------------------------------------------
# ATT EN CONF FINNS BETYDER INTE ATT NAGOT KOR DEN. Utan den har kontrollen ar
# "jobbet ar utrullat" och "jobbet kors" tva olika tillstand som ser identiska ut
# i varje matning man gor pa filen.
saknade=""
for snapname in $seen; do
  unit="agent-job@${snapname%.conf}.timer"
  if systemctl --user is-enabled "$unit" >/dev/null 2>&1; then continue; fi
  saknade="$saknade $unit"
done

echo "install-user-jobs: $skrivna uppdaterade, $oforandrade oforandrade, $(printf '%s' "$seen" | wc -w | tr -d ' ') jobb totalt."
[ -n "$foraldralosa" ] && { echo "  FORALDRALOSA (kalla borta, kors anda):$foraldralosa"; fel=1; }
if [ -n "$saknade" ]; then
  if [ -n "$ENABLE" ]; then
    for u in $saknade; do
      if systemctl --user enable --now "$u" >/dev/null 2>&1; then echo "  timer aktiverad: $u"
      else echo "  KUNDE INTE aktivera: $u" >&2; fel=1; fi
    done
  else
    echo "  TIMER SAKNAS (confen finns, ingenting kor den):$saknade"
    echo "  Kor med --enable for att aktivera dem."
    fel=1
  fi
fi
exit "$fel"
