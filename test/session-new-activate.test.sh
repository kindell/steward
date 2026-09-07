#!/bin/bash
# test/session-new-activate.test.sh — what `session-new.sh --activate` enables,
# chosen on the row's RUNTIME.
#
# THE GAP, 2026-09-07. A codex row owns a thread, not a process: it is driven
# by agent-codex@ (a path unit watching the inbox, a timer retrying staged
# letters) and never by agent-session@ (tmux + supervisor, which refuses a
# codex row on sight). Activation enabled agent-session@ for every row, so a
# codex row born through the enrolment ended up with a timer that refused
# every period and no path unit at all — the units, the key and the daemon
# were all hand-made. This suite pins the choice and its preconditions.
#
# NOTHING HERE TOUCHES SYSTEMD OR CODEX FOR REAL: both are stubs on PATH that
# log their argv, and HOME is the fixture — the suite must never read this
# machine's own configuration.
set -u

here="$(CDPATH= cd -- "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SN="$here/linux/session-new.sh"
pass=0; fail=0
ok()  { pass=$((pass+1)); printf '  ok   %s\n' "$1"; }
bad() { fail=$((fail+1)); printf '  FAIL %s\n     %s\n' "$1" "${2:-}"; }
has()    { case "$2" in *"$3"*) ok "$1" ;; *) bad "$1" "missing '$3' in: $2" ;; esac; }
hasnt()  { case "$2" in *"$3"*) bad "$1" "found '$3' in: $2" ;; *) ok "$1" ;; esac; }
is()     { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "wanted '$3', got '$2'"; fi; }

FX="$(mktemp -d)"; trap 'rm -rf "$FX"' EXIT
mkdir -p "$FX/estate" "$FX/sessions.d" "$FX/ssh" "$FX/state" "$FX/bin" "$FX/home" "$FX/config"
# The drop-in canonicalizes `..`, not symlinks (the resolver's default form
# carries a trailing /..) — compare against the same form.
FXR="$(cd "$FX" && pwd)"

cat > "$FX/estate/steward.conf" <<'CONF'
RC_LABEL_PREFIX="Hub: "
HUB_SESSION="hub"
HUB_HOST="hubhost"
CONF

# THE STUBS. systemctl logs every call; `cat` of a template answers from the
# environment so a missing template can be staged. codex logs its argv and
# exits as told. tmux logs and is expected to stay silent.
cat > "$FX/bin/systemctl" <<EOF
#!/bin/bash
printf '%s\n' "\$*" >> "$FX/systemctl.log"
printf 'systemctl %s\n' "\$*" >> "$FX/trace.log"
if [ "\$2" = "cat" ]; then
  case "\$3" in
    agent-codex@.path)  [ -z "\${FAKE_NO_CODEX_TEMPLATE:-}" ]; exit \$? ;;
    agent-session@.timer) exit 0 ;;
  esac
fi
exit 0
EOF
cat > "$FX/bin/codex" <<EOF
#!/bin/bash
printf '%s\n' "\$*" >> "$FX/codex.log"
printf 'codex %s\n' "\$*" >> "$FX/trace.log"
exit "\${FAKE_CODEX_RC:-0}"
EOF
cat > "$FX/bin/tmux" <<EOF
#!/bin/bash
printf '%s\n' "\$*" >> "$FX/tmux.log"
EOF
chmod +x "$FX/bin/systemctl" "$FX/bin/codex" "$FX/bin/tmux"

# TWO ROWS, ONE SLUG SHAPE: a default row and a codex row, each with the
# private key filed under its slug as the request path leaves it.
row() { # <id> <slug> [extra-lines]
  cat > "$FX/sessions.d/$1.conf" <<CONF
ID="$1"
SLUG="$2"
ACCOUNT="someone-farhost"
HOST="farhost"
REPO_PATH="/srv/homes/someone/Projects/$2"
RC_LABEL="Hub: $2"
PERMISSION_MODE="bypassPermissions"
OWNER="someone"
DOMAIN="acme"
${3:-}
CONF
  : > "$FX/ssh/id_busrelay_$2"; : > "$FX/ssh/id_busrelay_$2.pub"
}
ID_DEF="s-00000000000000aa"; SLUG_DEF="acme-widget-someone"
ID_CDX="s-00000000000000bb"; SLUG_CDX="acme-gadget-someone"
row "$ID_DEF" "$SLUG_DEF"
row "$ID_CDX" "$SLUG_CDX" 'RUNTIME="codex"'

reset_logs() { rm -f "$FX/systemctl.log" "$FX/codex.log" "$FX/tmux.log" "$FX/trace.log"; }
activate() { # <id> <slug>  (extra env via the caller)
  PATH="$FX/bin:$PATH" HOME="$FX/home" XDG_CONFIG_HOME="$FX/config" \
  STEWARD_ESTATE_ROOT="$FX" STEWARD_SESSIONS_D="$FX/sessions.d" \
  STEWARD_REGISTRY_LIB="$here/lib/registry.sh" \
  STEWARD_SSH_DIR="$FX/ssh" STEWARD_ENROLL_STATE_DIR="$FX/state" \
  bash "$SN" --activate "$1" "$2" 2>&1
}
UNITS="$FX/config/systemd/user"

# ── A1. THE DEFAULT ROW: agent-session@, exactly as before ──────────────────
echo "session-new --activate — the default row"
reset_logs
out="$(activate "$ID_DEF" "$SLUG_DEF")"; rc=$?
is  "A1: rc 0" "$rc" "0"
log="$(cat "$FX/systemctl.log" 2>/dev/null)"
has "A1: enables agent-session@<id>.timer" "$log" "--user enable --now agent-session@$ID_DEF.timer"
hasnt "A1: never mentions agent-codex@" "$log" "agent-codex@"
[ -f "$UNITS/agent-session@$ID_DEF.service.d/50-estate.conf" ] \
  && ok "A1: the estate drop-in sits under agent-session@<id>.service.d" \
  || bad "A1: the estate drop-in sits under agent-session@<id>.service.d"
[ ! -f "$FX/codex.log" ] && ok "A1: codex is never called for a default row" \
  || bad "A1: codex is never called for a default row" "$(cat "$FX/codex.log")"
[ -L "$FX/ssh/id_busrelay_$ID_DEF" ] && ok "A1: the key is linked under the id" \
  || bad "A1: the key is linked under the id"

# ── A2. THE CODEX ROW: agent-codex@ path + timer, the daemon, no tmux ───────
echo "session-new --activate — the codex row"
reset_logs
out="$(activate "$ID_CDX" "$SLUG_CDX")"; rc=$?
is  "A2: rc 0" "$rc" "0"
log="$(cat "$FX/systemctl.log" 2>/dev/null)"
has "A2: checks the agent-codex@.path template, not agent-session@.timer" "$log" "--user cat agent-codex@.path"
hasnt "A2: never checks agent-session@.timer" "$log" "agent-session@.timer"
has "A2: enables agent-codex@<id>.path and .timer in one call" "$log" \
    "--user enable --now agent-codex@$ID_CDX.path agent-codex@$ID_CDX.timer"
hasnt "A2: never enables agent-session@ for a codex row" "$log" "agent-session@$ID_CDX"
has "A2: reloads before enabling" "$log" "--user daemon-reload"
dropin="$UNITS/agent-codex@$ID_CDX.service.d/50-estate.conf"
[ -f "$dropin" ] && ok "A2: the estate drop-in sits under agent-codex@<id>.service.d" \
  || bad "A2: the estate drop-in sits under agent-codex@<id>.service.d"
is  "A2: the drop-in binds the estate root" "$(cat "$dropin" 2>/dev/null)" \
    "$(printf '[Service]\nEnvironment=STEWARD_ESTATE_ROOT=%s' "$FXR")"
[ ! -f "$UNITS/agent-session@$ID_CDX.service.d/50-estate.conf" ] \
  && ok "A2: no agent-session@ drop-in for a codex row" \
  || bad "A2: no agent-session@ drop-in for a codex row"
has "A2: bootstraps the owner's app-server daemon" "$(cat "$FX/codex.log" 2>/dev/null)" "app-server daemon bootstrap"
[ ! -f "$FX/tmux.log" ] && ok "A2: tmux is never called" || bad "A2: tmux is never called" "$(cat "$FX/tmux.log")"
[ -L "$FX/ssh/id_busrelay_$ID_CDX" ] && ok "A2: the key is linked under the id" \
  || bad "A2: the key is linked under the id"
has "A2: the receipt names the path unit and the timer" "$out" "agent-codex@$ID_CDX.path"
has "A2: the receipt says what wakes the row" "$out" "inbox"
hasnt "A2: the receipt does not promise a supervisor period" "$out" "supervision will start the session"

# ORDER: the daemon is a precondition of the units doing anything, so it is
# bootstrapped BEFORE they are enabled — an enabled path unit against a
# missing daemon would fire the runtime into rc 69 on the first letter.
bl="$(grep -n '^codex app-server daemon bootstrap' "$FX/trace.log" | head -1 | cut -d: -f1)"
el="$(grep -n '^systemctl --user enable --now agent-codex@' "$FX/trace.log" | head -1 | cut -d: -f1)"
if [ -n "$bl" ] && [ -n "$el" ] && [ "$bl" -lt "$el" ]; then ok "A2: the daemon is bootstrapped BEFORE the units are enabled"
else bad "A2: the daemon is bootstrapped BEFORE the units are enabled" "bootstrap at line '$bl', enable at line '$el'"; fi

# ── A3. CODEX ROW, TEMPLATE MISSING: refuse, enable nothing ─────────────────
echo "session-new --activate — preconditions of a codex row"
row "$ID_CDX" "$SLUG_CDX" 'RUNTIME="codex"'; rm -f "$FX/ssh/id_busrelay_$ID_CDX" "$FX/ssh/id_busrelay_$ID_CDX.pub"
rm -rf "$UNITS/agent-codex@$ID_CDX.service.d"
reset_logs
out="$(FAKE_NO_CODEX_TEMPLATE=1 activate "$ID_CDX" "$SLUG_CDX")"; rc=$?
is  "A3: a missing agent-codex@.path template refuses, rc 65" "$rc" "65"
has "A3: the refusal names the template" "$out" "agent-codex@.path"
hasnt "A3: nothing is enabled" "$(cat "$FX/systemctl.log" 2>/dev/null)" "enable"
[ ! -f "$FX/codex.log" ] && ok "A3: the daemon is not bootstrapped" || bad "A3: the daemon is not bootstrapped"

# ── A4. CODEX ROW, NO codex BINARY: rc 78 before anything is enabled ────────
reset_logs
out="$(PATH_SANS="$FX/bin-nocodex"; mkdir -p "$PATH_SANS"; cp "$FX/bin/systemctl" "$FX/bin/tmux" "$PATH_SANS/"; \
       PATH="$PATH_SANS:/usr/bin:/bin" HOME="$FX/home" XDG_CONFIG_HOME="$FX/config" \
       STEWARD_ESTATE_ROOT="$FX" STEWARD_SESSIONS_D="$FX/sessions.d" \
       STEWARD_REGISTRY_LIB="$here/lib/registry.sh" \
       STEWARD_SSH_DIR="$FX/ssh" STEWARD_ENROLL_STATE_DIR="$FX/state" \
       bash "$SN" --activate "$ID_CDX" "$SLUG_CDX" 2>&1)"; rc=$?
is  "A4: no codex binary refuses, rc 78" "$rc" "78"
has "A4: the refusal names codex" "$out" "codex"
hasnt "A4: nothing is enabled" "$(cat "$FX/systemctl.log" 2>/dev/null)" "enable"
[ ! -f "$UNITS/agent-codex@$ID_CDX.service.d/50-estate.conf" ] \
  && ok "A4: no drop-in is written" || bad "A4: no drop-in is written"

# ── A5. CODEX ROW, BOOTSTRAP FAILS: rc 70, units stay disabled ──────────────
reset_logs
out="$(FAKE_CODEX_RC=1 activate "$ID_CDX" "$SLUG_CDX")"; rc=$?
is  "A5: a failed daemon bootstrap refuses, rc 70" "$rc" "70"
has "A5: the refusal names the daemon" "$out" "daemon"
hasnt "A5: nothing is enabled after a failed bootstrap" "$(cat "$FX/systemctl.log" 2>/dev/null)" "enable"

# ── A6. AN UNKNOWN RUNTIME ON THE ROW: refuse, never guess agent-session@ ───
ID_ODD="s-00000000000000cc"; SLUG_ODD="acme-thing-someone"
row "$ID_ODD" "$SLUG_ODD" 'RUNTIME="opencode"'
reset_logs
out="$(activate "$ID_ODD" "$SLUG_ODD")"; rc=$?
is  "A6: a runtime this activation does not serve refuses, rc 65" "$rc" "65"
has "A6: the refusal names the runtime" "$out" "opencode"
hasnt "A6: nothing is enabled" "$(cat "$FX/systemctl.log" 2>/dev/null)" "enable"

echo
printf 'pass=%s fail=%s\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
