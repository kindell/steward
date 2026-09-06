#!/bin/bash
# test/install-user-jobs.test.sh - the installer renders the timer it enables.
#
# WHY. install-user-jobs.sh snapshotted the conf and enabled
# agent-job@<entity>-<job>.timer - and nothing wrote that unit. There was no
# template (a template cannot carry a calendar that differs per job) and no
# renderer, so every timer on a Linux host was written by hand from the conf's
# SCHEDULE_* keys, and "the job is deployed" and "the job runs" stayed two states
# that look identical on disk. The hub renders launchd's StartCalendarInterval
# from the same keys; the timer rendered here must mean the same thing.
#
# systemctl is a stub: it records every call and answers is-enabled from a
# directory of flags that enable --now fills. The assertions read what the stub
# SAW and what is on disk, never what the installer says it did.
set -u
pass=0; fail=0
ok()  { pass=$((pass+1)); printf '  ok   %s\n' "$1"; }
bad() { fail=$((fail+1)); printf '  FAIL %s\n     %s\n' "$1" "${2:-}"; }
here="$(CDPATH= cd -- "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
INSTALLER="$here/linux/install-user-jobs.sh"
REG="$here/lib/registry.sh"

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
export HOME="$T/home"
hs="$HOME/scripts"; units="$HOME/.config/systemd/user"
mkdir -p "$hs/estate" "$T/src/jobs.d" "$T/bin" "$T/enabled"
cat > "$hs/estate/steward.conf" <<'CONF'
HUB_HOST="hub-one"
HUB_SSH="p@hub-one"
HUB_SESSION="hub-one"
LABEL_PREFIX="io.example"
RC_LABEL_PREFIX="Hub: "
JOB_LABEL_PREFIX="io.example.job"
SERVICE_LABEL_PREFIX="io.example.service"
BROWSER_LABEL_PREFIX="io.example.browser"
JOB_LOG_DIR="hub-jobs"
TMUX_SOCKET="hub-one.sock"
PING_MSG='[bus] you have mail'
OP_TOKEN_FILE_NAME="op-token"
STATE_DIR_NAME="hub-supervisor"
PAUSED_DIR_NAME="hub-paused"
CONF
cat > "$T/bin/systemctl" <<'EOF'
#!/bin/bash
printf '%s\n' "$*" >> "${SYSTEMCTL_LOG:?}"
last=""; for a in "$@"; do last="$a"; done
case " $* " in
  *" is-enabled "*)  [ -e "${ENABLED_DIR:?}/$last" ] ;;
  *" enable --now "*) : > "${ENABLED_DIR:?}/$last" ;;
  *) exit 0 ;;
esac
EOF
chmod +x "$T/bin/systemctl"
export SYSTEMCTL_LOG="$T/systemctl.log" ENABLED_DIR="$T/enabled"
export PATH="$T/bin:$PATH"

mkjob() { # <name> <minute> <hour> <weekday>
  printf 'KIND="command"\nREPO_PATH="%s"\nOWNER="%s"\nDOMAIN="entity-one"\nSCHEDULE_MINUTE="%s"\nSCHEDULE_HOUR="%s"\nSCHEDULE_WEEKDAY="%s"\nTIMEOUT_MIN="5"\nCOMMAND="bin/x.sh"\n' \
    "$T/src" "$(id -un)" "$2" "$3" "$4" > "$T/src/jobs.d/$1.conf"
}
# The source is a git tree, as a real one is: the provenance gate wants a sha.
git -C "$T/src" init -q; git -C "$T/src" config user.email p@example.invalid; git -C "$T/src" config user.name P
mkjob alpha "15,45" "2,14" "1,3"
mkjob beta  "5" "" ""
mkjob gamma "5" "" "0,7"
mkjob delta "0" "7" ""
mkjob zeta  "08,09" "" ""
git -C "$T/src" add -A; git -C "$T/src" commit -qm x
printf '%s\n' "$T/src" > "$hs/jobs-sources.conf"

run() { STEWARD_HOME_SCRIPTS="$hs" STEWARD_REGISTRY_LIB="$REG" STEWARD_ESTATE="$hs/estate/steward.conf" bash "$INSTALLER" "$@" 2>&1; }
unit() { printf '%s/agent-job@entity-one-%s.timer' "$units" "$1"; }
cal()  { sed -n 's/^OnCalendar=//p' "$(unit "$1")"; }
reloads() { grep -cx -- '--user daemon-reload' "$SYSTEMCTL_LOG" 2>/dev/null || true; }

echo "== the calendar: the same product the hub renders for launchd =="
out="$(run)"
[ -f "$(unit alpha)" ] && ok "a timer unit is rendered beside the snapshot" || bad "no timer unit" "$out"
[ "$(cal alpha)" = "Mon,Wed *-*-* 02,14:15,45:00" ] && ok "weekday x hour x minute lists become one OnCalendar" || bad "alpha calendar" "$(cal alpha)"
[ "$(cal beta)" = "*-*-* *:05:00" ] && ok "no hour means every hour, no weekday means every day" || bad "beta calendar" "$(cal beta)"
[ "$(cal gamma)" = "Sun *-*-* *:05:00" ] && ok "weekday 0 and 7 are both Sunday, named once" || bad "gamma calendar" "$(cal gamma)"
[ "$(cal delta)" = "*-*-* 07:00:00" ] && ok "a single hour and minute are zero-padded" || bad "delta calendar" "$(cal delta)"
[ "$(cal zeta)" = "*-*-* *:08,09:00" ] && ok "a value written with a leading zero is read as decimal, not octal" || bad "zeta calendar" "$(cal zeta)"
grep -q '^# rendered by install-user-jobs.sh' "$(unit alpha)" && ok "the unit carries the rendered-by header" || bad "no rendered-by header"
grep -q 'alpha.conf' "$(unit alpha)" && ok "the header names the conf it came from" || bad "header does not name the source conf"
grep -q '^Persistent=true' "$(unit alpha)" && ok "Persistent=true, a missed run is caught up" || bad "no Persistent line"
grep -qi 'launchd' "$(unit alpha)" && ok "the unit says where it differs from launchd" || bad "the launchd difference is not written down"
grep -q '^WantedBy=timers.target' "$(unit alpha)" && ok "installable under timers.target" || bad "no WantedBy"
[ "$(reloads)" = "1" ] && ok "one daemon-reload after the units were written" || bad "daemon-reload count" "$(reloads)"
grep -q 'enable --now' "$SYSTEMCTL_LOG" && bad "enabled without --enable" || ok "without --enable nothing is enabled"
case "$out" in *"agent-job@entity-one-alpha.timer"*) ok "the missing timers are named" ;; *) bad "missing timers not named" "$out" ;; esac

echo "== idempotent: an unchanged run touches no file and no timer =="
touch "$T/mark"; sleep 1
: > "$SYSTEMCTL_LOG"
out="$(run)"
[ "$(unit alpha)" -nt "$T/mark" ] && bad "an unchanged unit was rewritten" || ok "an unchanged unit is left as it was"
[ "$(reloads)" = "0" ] && ok "no daemon-reload when nothing was written" || bad "daemon-reload on an unchanged run" "$(cat "$SYSTEMCTL_LOG")"

echo "== --enable: the timers the stub saw =="
out="$(run --enable)"
for j in alpha beta gamma delta zeta; do
  grep -qx -- "--user enable --now agent-job@entity-one-$j.timer" "$SYSTEMCTL_LOG" && ok "enable --now $j" || bad "not enabled: $j" "$out"
done
case "$out" in *"TIMER"*"MISSING"*|*"missing"*) bad "still reports missing timers after --enable" "$out" ;; *) ok "nothing missing after --enable" ;; esac

echo "== a hand-written timer is never touched =="
printf '[Timer]\nOnCalendar=*-*-* 03:00:00\n' > "$(unit beta)"
cp "$(unit beta)" "$T/beta.hand"
: > "$SYSTEMCTL_LOG"
out="$(run)"
cmp -s "$(unit beta)" "$T/beta.hand" && ok "a unit without the header is left byte for byte" || bad "hand-written unit rewritten"
case "$out" in *"hand-written"*"agent-job@entity-one-beta.timer"*) ok "the hand-written unit is named" ;; *) bad "hand-written unit not named" "$out" ;; esac
[ "$(reloads)" = "0" ] && ok "leaving a hand-written unit alone reloads nothing" || bad "reload for a hand-written unit"

echo "== the estate's time zone =="
echo 'JOB_TIMEZONE="Europe/Vienna"' >> "$hs/estate/steward.conf"
: > "$SYSTEMCTL_LOG"
out="$(run)"
[ "$(cal alpha)" = "Mon,Wed *-*-* 02,14:15,45:00 Europe/Vienna" ] && ok "JOB_TIMEZONE is the OnCalendar suffix" || bad "no zone suffix" "$(cal alpha)"
[ "$(reloads)" = "1" ] && ok "a changed unit is followed by one daemon-reload" || bad "reload after change" "$(reloads)"
grep -qx -- "--user restart agent-job@entity-one-alpha.timer" "$SYSTEMCTL_LOG" && ok "an enabled timer whose unit changed is restarted" || bad "changed enabled timer not restarted" "$(cat "$SYSTEMCTL_LOG")"
cmp -s "$(unit beta)" "$T/beta.hand" && ok "the hand-written unit stays hand-written through a zone change" || bad "hand-written unit rewritten on zone change"

echo "== the key is read through the registry, with a form =="
ask() { ( STEWARD_ESTATE="$1"; . "$REG"; registry_job_timezone ) 2>/dev/null; echo "rc=$?"; }
printf 'JOB_TIMEZONE="Europe/Vienna"\n' > "$T/tz.conf"
[ "$(ask "$T/tz.conf")" = "Europe/Vienna
rc=0" ] && ok "a zone name is read" || bad "zone not read" "$(ask "$T/tz.conf")"
: > "$T/none.conf"
[ "$(ask "$T/none.conf")" = "
rc=0" ] && ok "an absent zone is empty, not a refusal" || bad "absent zone" "$(ask "$T/none.conf")"
printf 'JOB_TIMEZONE="not a zone"\n' > "$T/bad.conf"
[ "$(ask "$T/bad.conf" | tail -1)" = "rc=78" ] && ok "a zone with spaces is refused, rc 78" || bad "bad zone accepted" "$(ask "$T/bad.conf")"

echo "pass=$pass fail=$fail"
[ "$fail" -eq 0 ]
