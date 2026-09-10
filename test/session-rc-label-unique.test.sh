#!/bin/bash
# test/session-rc-label-unique.test.sh - one RC_LABEL, one row, per home.
#
# THE GAP, measured on a live Linux host 2026-09-09. Nothing anywhere refused a
# second session row carrying an RC_LABEL another row in the same home already
# carried. Two did, and the consequences were not cosmetic:
#   * supervision's orphan reap found its candidates BY THAT LABEL, so each
#     session's repair killed the other's live claude - 13 destroyed
#     conversations in 55 minutes (the reap is bound to panes now, so that one
#     cannot recur; this is the other half);
#   * both processes answered to one --remote-control name, which is why the
#     hub logged "RENAME NOT CONFIRMED after 5 attempts" all morning.
#
# WRITE TIME, NOT LOAD TIME. A load-time refusal would break every estate that
# already carries duplicates - including the one this happened on, whose two
# rows are still on disk. Loading is how an operator SEES the problem; refusing
# to load is how they lose the machine that shows it to them. So: the existing
# pair still loads, and the NEXT one cannot be created.
#
# SCOPE IS THE HOME - (OWNER, HOST) - NOT THE ESTATE. The harm is bounded by
# the home twice over: the reap's finder is `pgrep -u "$(id -u)"`, and a tmux
# socket lives in one home on one host. The affected estate carries six
# cross-home duplicate labels TODAY by design (two people with an "Acme"
# session each), and refusing those would be a refusal with no measurement
# behind it.
#
# FIVE CLAIMS:
#   1. The predicate finds the holder of a colliding label in the same home,
#      and names it.
#   2. It does NOT fire across homes, on an empty label, or against the row's
#      own id.
#   3. nav-enroll - the sole writer of new session rows - refuses a colliding
#      row, names BOTH rows, and says what to do.
#   4. The refusal is TOTAL: no conf, no authorized_keys line, nothing to undo.
#   5. An estate that already carries a duplicate pair still LOADS both rows.
set -u
here="$(CDPATH= cd -- "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENROLL="$here/linux/hub/enroll"
pass=0; fail=0
ok()  { pass=$((pass+1)); printf '  ok   %s\n' "$1"; }
bad() { fail=$((fail+1)); printf '  FAIL %s\n     %s\n' "$1" "${2:-}"; }
is()  { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "wanted '$3', got '$2'"; fi; }
has() { case "$2" in *"$3"*) ok "$1" ;; *) bad "$1" "missing '$3' in: $2" ;; esac; }
hasnt(){ case "$2" in *"$3"*) bad "$1" "unexpectedly present '$3' in: $2" ;; *) ok "$1" ;; esac; }

FX="$(mktemp -d)"; trap 'rm -rf "$FX"' EXIT
mkdir -p "$FX/estate" "$FX/reg" "$FX/bus/bin" "$FX/bin" \
  "$FX/accounts.d" "$FX/entities.d" "$FX/projects.d"
cat > "$FX/estate/steward.conf" <<'CONF'
ESTATE_NAME="prov"
SCHEMA_VERSION="3"
RC_LABEL_PREFIX="Hub: "
HUB_SESSION="hub"
HUB_HOST="hubhost"
HUB_SSH="someone@hubhost"
LABEL_PREFIX="com.fixture.claude"
JOB_LABEL_PREFIX="com.fixture.job"
SERVICE_LABEL_PREFIX="com.fixture.service"
BROWSER_LABEL_PREFIX="com.fixture.browser"
JOB_LOG_DIR="fixture-jobs"
TMUX_SOCKET="fixture.sock"
PING_MSG="you have mail"
STATE_DIR_NAME="fixture-supervisor"
PAUSED_DIR_NAME="fixture-paused"
OP_TOKEN_FILE_NAME="fixture-token"
CONF
printf 'NAME="Acme"\n' > "$FX/entities.d/acme.conf"
printf 'PRINCIPAL="someone"\nHOST="farhost"\n' > "$FX/accounts.d/someone-farhost.conf"
printf 'PRINCIPAL="other"\nHOST="farhost"\n'   > "$FX/accounts.d/other-farhost.conf"
printf 'PRINCIPAL="someone"\nHOST="nearhost"\n' > "$FX/accounts.d/someone-nearhost.conf"
printf '#!/bin/bash\n' > "$FX/bus/bin/bus-relay-in"; chmod +x "$FX/bus/bin/bus-relay-in"
printf '#!/bin/bash\nexit 0\n' > "$FX/bin/send"; chmod +x "$FX/bin/send"
: > "$FX/authorized_keys"

# THE REQUESTER. Present so the identity check passes and the run measures the
# label, not the envelope.
cat > "$FX/reg/asker.conf" <<'CONF'
HOST="farhost"
OWNER="someone"
DOMAIN="d"
RC_LABEL="Asker"
REPO_PATH="/tmp/x"
ID="asker"
CONF

LABEL='Steward-Host-A'

echo "== 1-2. the predicate: same home only, non-empty labels only =="
# Two rows in the SAME home carrying the SAME label - the live shape.
cat > "$FX/reg/s-1111111111111111.conf" <<CONF
ID="s-1111111111111111"
OWNER="someone"
HOST="farhost"
DOMAIN="acme"
REPO_PATH="/tmp/a"
RC_LABEL="$LABEL"
CONF
# Same label, ANOTHER home on the same host - legitimate, six of these exist.
cat > "$FX/reg/s-2222222222222222.conf" <<CONF
ID="s-2222222222222222"
OWNER="other"
HOST="farhost"
DOMAIN="acme"
REPO_PATH="/tmp/b"
RC_LABEL="$LABEL"
CONF
# Same owner, ANOTHER host - a different machine, a different tmux socket.
cat > "$FX/reg/s-3333333333333333.conf" <<CONF
ID="s-3333333333333333"
OWNER="someone"
HOST="nearhost"
DOMAIN="acme"
REPO_PATH="/tmp/c"
RC_LABEL="$LABEL"
CONF
# TWO RC-FREE ROWS in one home. RC_LABEL="" is a deliberate choice, not a
# label, and the supervisor disambiguates those by pane. They must not collide.
cat > "$FX/reg/s-4444444444444444.conf" <<CONF
ID="s-4444444444444444"
OWNER="someone"
HOST="farhost"
DOMAIN="acme"
REPO_PATH="/tmp/d"
RC_LABEL=""
CONF

probe() { # <id-to-exclude> <owner> <host> <label> -> holder id on stdout, rc
  ( STEWARD_ESTATE_ROOT="$FX" STEWARD_REGISTRY_DIR="$FX/reg"
    . "$here/lib/registry.sh"
    registry_session_rc_label_holder "$1" "$2" "$3" "$4" ) 2>/dev/null
}
h="$(probe "s-9999999999999999" someone farhost "$LABEL")"; rc=$?
is "1a a colliding label in the same home is a conflict" "$rc" "0"
is "1b and the holder is named" "$h" "s-1111111111111111"

# TWO homes on this host already carry the label (someone's and other's). A
# THIRD home is still free to use it: the harm cannot cross a unix account.
h="$(probe "s-9999999999999999" plex farhost "$LABEL")"; rc=$?
is "2a the SAME label in other homes is not a conflict here" "$rc" "1"
h="$(probe "s-9999999999999999" someone otherhost "$LABEL")"; rc=$?
is "2b nor is the same home's label on another host" "$rc" "1"
# And the answer is PER HOME: asked about other's home, the holder named is
# other's row, never someone's.
h="$(probe "s-9999999999999999" other farhost "$LABEL")"; rc=$?
is "2e the holder named is the one in the home asked about" "$h" "s-2222222222222222"
h="$(probe "s-9999999999999999" someone farhost "")"; rc=$?
is "2c an empty label is never a conflict (RC-free is a choice)" "$rc" "1"
h="$(probe "s-1111111111111111" someone farhost "$LABEL")"; rc=$?
is "2d and a row never conflicts with itself" "$rc" "1"

echo "== 3-4. nav-enroll refuses to write the second one =="
# ONE KEY, ONE IDENTITY - enroll refuses a second registration of the same
# pubkey, so each request below carries its own.
req() { # <namn> <rc_label> <key-suffix>
  cat <<REQ
DRIFT enroll: $1 requests registration
ENROLL-REQUEST v1
namn=$1
doman=acme
projekt=widget
person=someone
vard=farhost
repo=/srv/homes/someone/Projects/widget
rc_label=$2
pubkey=ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIFAKEKEYFORTESTONLYxxxxxxxxxxxxxxxxxxx$3 test-only
REQ
}
enroll() { # stdin = request
  STEWARD_ESTATE_ROOT="$FX" \
  STEWARD_REGISTRY_DIR="$FX/reg" \
  STEWARD_RELAY_ROOT="$FX" \
  STEWARD_AUTHORIZED_KEYS="$FX/authorized_keys" \
  STEWARD_BUS_SEND="$FX/bin/send" \
  STEWARD_REGISTRY_LIB="$here/lib/registry.sh" STEWARD_ENROLL_FROM=asker \
  bash "$ENROLL" --send 2>&1
}
before_rows="$(ls "$FX/reg" | wc -l | tr -d ' ')"
before_keys="$(wc -l < "$FX/authorized_keys" | tr -d ' ')"
out="$(req acme-widget-someone "$LABEL" aa | enroll)"; rc=$?
after_rows="$(ls "$FX/reg" | wc -l | tr -d ' ')"
after_keys="$(wc -l < "$FX/authorized_keys" | tr -d ' ')"
# THE REFUSAL LINE ITSELF, not the run's whole output: a successful run echoes
# the row it wrote, so asserting against everything enroll printed would let a
# SUCCESS satisfy claims about a refusal's wording.
refline="$(printf '%s\n' "$out" | grep 'REFUSING' | head -1)"

if [ "$rc" -ne 0 ]; then ok "3a the colliding registration is refused"
else bad "3a the colliding registration is refused" "rc=$rc out=$out"; fi
has "3b the message names the label"        "$refline" "$LABEL"
has "3c and the row that already holds it"  "$refline" "s-1111111111111111"
has "3d and the row being refused"          "$refline" "acme-widget-someone"
has "3e and the home the two would share"   "$refline" "someone"
has "3f and says what to do about it"       "$refline" "rc_label"
is  "4a nothing was written to the register" "$after_rows" "$before_rows"
is  "4b and no key line was appended"        "$after_keys" "$before_keys"

echo "== 5. a DIFFERENT label in the same home still registers =="
out5="$(req acme-widget-someone 'Steward-Host-A (Alice)' bb | enroll)"; rc5=$?
id5="$(printf '%s' "$out5" | sed -n 's/.*registered as \(s-[0-9a-f]\{16\}\).*/\1/p' | head -1)"
if [ "$rc5" -eq 0 ] && [ -n "$id5" ] && [ -f "$FX/reg/$id5.conf" ]; then
  ok "5a a distinct label in the same home is registered"
else
  bad "5a a distinct label in the same home is registered" "rc=$rc5 out=$out5"
fi
has "5b under the label that was asked for" "$(cat "$FX/reg/$id5.conf" 2>/dev/null)" 'RC_LABEL="Steward-Host-A (Alice)"'

echo "== 6. the duplicate that already exists still LOADS =="
# The estate this happened on still carries its pair. A load-time refusal
# would take the operator's own diagnosis tools away at the worst moment.
cat > "$FX/reg/s-5555555555555555.conf" <<CONF
ID="s-5555555555555555"
OWNER="someone"
HOST="farhost"
DOMAIN="acme"
REPO_PATH="/tmp/e"
RC_LABEL="$LABEL"
CONF
for dup in s-1111111111111111 s-5555555555555555; do
  if ( STEWARD_ESTATE_ROOT="$FX" STEWARD_REGISTRY_DIR="$FX/reg"
       . "$here/lib/registry.sh"; registry_load "$dup" ) >/dev/null 2>&1; then
    ok "6 the pre-existing duplicate $dup still loads"
  else
    bad "6 the pre-existing duplicate $dup still loads" "registry_load refused it"
  fi
done

echo "pass=$pass fail=$fail"
[ "$fail" -eq 0 ]
