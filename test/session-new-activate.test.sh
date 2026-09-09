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
# `app-server daemon version` is the liveness question (rc 0 iff a daemon
# answers on the socket); it is answered from the environment so both states
# can be staged. Everything else exits as told.
cat > "$FX/bin/codex" <<EOF
#!/bin/bash
printf '%s\n' "\$*" >> "$FX/codex.log"
printf 'codex %s\n' "\$*" >> "$FX/trace.log"
if [ "\$*" = "app-server daemon version" ]; then [ -n "\${FAKE_DAEMON_UP:-}" ]; exit \$?; fi
exit "\${FAKE_CODEX_RC:-0}"
EOF
# tmux answers ONE question — `display-message -p '#S'`, the pane's own session
# name, which is where the request path derives the caller's identity from. It
# still logs every call, because the activation cases below assert it is never
# reached at all.
cat > "$FX/bin/tmux" <<EOF
#!/bin/bash
printf '%s\n' "\$*" >> "$FX/tmux.log"
if [ "\$1" = "display-message" ]; then printf '%s\n' "\${FAKE_TMUX_SESSION:-}"; fi
exit 0
EOF
# ssh-keygen: the request path generates a relay key, and no real key material
# is needed to measure who a request names. The stub writes both halves where
# -f points and nothing else.
cat > "$FX/bin/ssh-keygen" <<'EOF'
#!/bin/bash
f=""
while [ $# -gt 0 ]; do
  case "$1" in -f) f="${2:-}"; shift 2 ;; *) shift ;; esac
done
[ -n "$f" ] || exit 1
: > "$f"
printf 'ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIFIXTUREKEYSESSIONNEWREQUESTPATHxxxxxx fixture\n' > "$f.pub"
EOF
chmod +x "$FX/bin/systemctl" "$FX/bin/codex" "$FX/bin/tmux" "$FX/bin/ssh-keygen"

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
# THE DAEMON IS ABSENT IN A2 (the stub's default), so it is bootstrapped —
# WITH remote control: that flag is how the owner reaches the thread from the
# app, and a bootstrap without it restarts the daemon with RC off (measured
# 2026-09-07: the owner's app lost the host until RC was re-enabled by hand).
is  "A2: an absent daemon is bootstrapped, with --remote-control" \
    "$(grep -c '^app-server daemon bootstrap --remote-control$' "$FX/codex.log" 2>/dev/null)" "1"
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

# ── A2b. THE DAEMON ALREADY RUNS: LEFT ALONE ────────────────────────────────
# bootstrap on a running daemon is NOT idempotent — it restarts it (throwing
# the human out mid-turn) and, without the flag, with remote control off.
# A running daemon is the precondition already met; the activation asks and
# then does not touch it.
ID_UP="s-00000000000000dd"; SLUG_UP="acme-gizmo-someone"
row "$ID_UP" "$SLUG_UP" 'RUNTIME="codex"'
reset_logs
out="$(FAKE_DAEMON_UP=1 activate "$ID_UP" "$SLUG_UP")"; rc=$?
is  "A2b: rc 0 with a running daemon" "$rc" "0"
has "A2b: the daemon is asked" "$(cat "$FX/codex.log" 2>/dev/null)" "app-server daemon version"
hasnt "A2b: a running daemon is never bootstrapped" "$(cat "$FX/codex.log" 2>/dev/null)" "bootstrap"
has "A2b: the units are still enabled" "$(cat "$FX/systemctl.log" 2>/dev/null)" \
    "--user enable --now agent-codex@$ID_UP.path agent-codex@$ID_UP.timer"
has "A2b: the receipt says the daemon was already running" "$out" "already running"

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

# ── B. THE REQUEST PATH: WHO THE REQUEST NAMES ──────────────────────────────
#
# THE GAP, measured on a live host 2026-09-09. The request named `id -un` — the
# unix login — in its person= field, while the hub's enroll compares that field
# to the requesting row's PRINCIPAL (an account is a (principal, host) pair, and
# OWNER is the login that runs it). On an account whose login is a ROLE rather
# than a person's name — "steward", the normal shape for a steward account —
# the enrolment was refused two machines away with
#
#   owner check: 's-...' is owned by 'steward' (principal 'jon'), the request
#   names 'steward'
#
# a refusal naming a value the requester never typed. The hub side was right;
# the requester was never updated to match. So the person a request names is
# RESOLVED through the account register, and when it cannot be resolved the
# request is not built at all — a fallback to the login is exactly what
# produces the confusing refusal at the far end.
echo "session-new — the person a request names"

BFX="$FX/request"
mkdir -p "$BFX/sessions.d" "$BFX/ssh" "$BFX/state" "$BFX/repo/.git"

# The bus client records the request it was handed. It is the ONLY thing that
# leaves this fixture, so its absence is how "nothing was sent" is measured.
cat > "$BFX/bus-send" <<EOF
#!/bin/bash
printf '%s\n' "\$*" >> "$BFX/sent.to"
cat > "$BFX/sent.txt"
EOF
chmod +x "$BFX/bus-send"

# THE REQUESTING SESSION. A request must come from a registered session, and
# DOMAIN and HOST are read off this row — the identity is derived from the pane
# and never typed.
UU="$(id -un)"
PRIN="chief"; [ "$PRIN" = "$UU" ] && PRIN="chieftain"
cat > "$BFX/sessions.d/asker.conf" <<CONF
ID="asker"
HOST="farhost"
OWNER="$UU"
DOMAIN="acme"
RC_LABEL="Hub: asker"
REPO_PATH="/srv/homes/asker/Projects/asker"
CONF

# Every case runs the same request against a DIFFERENT account register, so the
# register is the only variable. The leftovers of a previous case are cleared
# first: a name collision or a reused key would refuse for the wrong reason.
request() { # <accounts.d>
  rm -f "$BFX/sent.txt" "$BFX/sent.to"
  rm -f "$BFX/sessions.d"/acme-widget-*.conf
  rm -f "$BFX/ssh"/id_busrelay_*
  rm -f "$BFX/state"/enroll-*.pending
  PATH="$FX/bin:$PATH" HOME="$FX/home" XDG_CONFIG_HOME="$FX/config" \
  TMUX_PANE="%0" FAKE_TMUX_SESSION="asker" \
  STEWARD_ESTATE_ROOT="$FX" STEWARD_SESSIONS_D="$BFX/sessions.d" \
  STEWARD_ACCOUNT_DIR="$1" \
  STEWARD_REGISTRY_LIB="$here/lib/registry.sh" \
  STEWARD_SSH_DIR="$BFX/ssh" STEWARD_ENROLL_STATE_DIR="$BFX/state" \
  STEWARD_BUS_SEND="$BFX/bus-send" \
  bash "$SN" widget "$BFX/repo" 2>&1
}
nothing_left() { # <case>  — no key, no reservation, no conf, nothing sent
  local c="$1" left=""
  [ -f "$BFX/sent.txt" ] && left="$left sent-request"
  ls "$BFX/ssh"/id_busrelay_* >/dev/null 2>&1 && left="$left relay-key"
  ls "$BFX/sessions.d"/acme-widget-*.conf >/dev/null 2>&1 && left="$left local-conf"
  ls "$BFX/state"/enroll-*.pending >/dev/null 2>&1 && left="$left reservation"
  if [ -z "$left" ]; then ok "$c: nothing was built and nothing was sent"
  else bad "$c: nothing was built and nothing was sent" "left behind:$left"; fi
}

# ── B1. USERNAME DIFFERS FROM PRINCIPAL — the case that fails today ─────────
acc="$BFX/acc-role"; mkdir -p "$acc"
cat > "$acc/chief-farhost.conf" <<CONF
PRINCIPAL="$PRIN"
HOST="farhost"
USERNAME="$UU"
CONF
out="$(request "$acc")"; rc=$?
is "B1: rc 0" "$rc" "0"
sent="$(cat "$BFX/sent.txt" 2>/dev/null)"
has   "B1: the request names the account's principal" "$sent" "person=$PRIN"
hasnt "B1: the request never names the unix login as the person" "$sent" "person=$UU"
has   "B1: the constructed name ends in the principal" "$sent" "namn=acme-widget-$PRIN"
conf="$BFX/sessions.d/acme-widget-$PRIN.conf"
[ -f "$conf" ] && ok "B1: the local reservation is filed under the principal's name" \
  || bad "B1: the local reservation is filed under the principal's name" "$(ls "$BFX/sessions.d")"
# OWNER IS STILL THE LOGIN. The principal answers "whose session is this"; OWNER
# answers "which unix account runs it", and the hub refuses a row that confuses
# the two. Resolving the principal must not quietly rewrite the other field.
has "B1: the reservation's OWNER stays the unix login" "$(cat "$conf" 2>/dev/null)" "OWNER=\"$UU\""

# ── B2. NO USERNAME ON THE ROW — the field defaults to PRINCIPAL ────────────
# registry_account_load defaults USERNAME to PRINCIPAL, so a row that omits it
# still joins the operating-system namespace to the principal namespace. A
# resolver that demanded the field literally would refuse most of the register.
acc="$BFX/acc-default"; mkdir -p "$acc"
cat > "$acc/plain-farhost.conf" <<CONF
PRINCIPAL="$UU"
HOST="farhost"
CONF
out="$(request "$acc")"; rc=$?
is  "B2: rc 0 when USERNAME is defaulted from PRINCIPAL" "$rc" "0"
has "B2: the request names the defaulted principal" "$(cat "$BFX/sent.txt" 2>/dev/null)" "person=$UU"

# ── B3. NO ROW AT ALL — refuse, never fall back to the login ────────────────
acc="$BFX/acc-empty"; mkdir -p "$acc"
out="$(request "$acc")"; rc=$?
is  "B3: an unresolvable login refuses, rc 78" "$rc" "78"
has "B3: the refusal names the unix login it searched for" "$out" "'$UU'"
has "B3: the refusal names the host" "$out" "farhost"
has "B3: the refusal names the register it searched" "$out" "$acc"
nothing_left "B3"

# ── B4. TWO ROWS MATCH — refuse rather than guess ───────────────────────────
acc="$BFX/acc-two"; mkdir -p "$acc"
cat > "$acc/first-farhost.conf" <<CONF
PRINCIPAL="$PRIN"
HOST="farhost"
USERNAME="$UU"
CONF
cat > "$acc/second-farhost.conf" <<CONF
PRINCIPAL="deputy"
HOST="farhost"
USERNAME="$UU"
CONF
out="$(request "$acc")"; rc=$?
is  "B4: an ambiguous login refuses, rc 78" "$rc" "78"
has "B4: the refusal names the first candidate" "$out" "first-farhost"
has "B4: the refusal names the second candidate" "$out" "second-farhost"
nothing_left "B4"

# ── B5. THE SAME LOGIN ON ANOTHER HOST IS NOT A MATCH ───────────────────────
# A login name is unique within a machine, never across a fleet. An account is
# a (principal, host) pair, and half of it is the host.
acc="$BFX/acc-elsewhere"; mkdir -p "$acc"
cat > "$acc/chief-otherhost.conf" <<CONF
PRINCIPAL="$PRIN"
HOST="otherhost"
USERNAME="$UU"
CONF
out="$(request "$acc")"; rc=$?
is  "B5: an account on another host does not resolve this one, rc 78" "$rc" "78"
has "B5: the refusal names the host that was searched" "$out" "farhost"
nothing_left "B5"

echo
printf 'pass=%s fail=%s\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
