#!/bin/bash
# test/hub-enroll-conf.test.sh — the conf nav-enroll writes for a new session.
#
# THE GAP, measured 2026-08-26. The identity model made ID a required field:
# an immutable key that survives both the display name and the file name. Every
# hand-written conf got one. But nav-enroll — the SOLE writer of new session
# confs, by its own design comment — did not emit the line.
#
# The first session enrolled after the model landed therefore failed the
# estate's registry suite with "saknar ID". The tool did not produce what the
# model requires, and nothing in the product noticed: enroll had no test at all.
#
# It would still have WORKED. registry_load defaults ID to the file's basename,
# so the session loads and runs. That is exactly why it went unseen — and
# exactly why it matters: with the line absent the immutable key is bound to a
# file name, and renaming the file moves the identity silently. A default that
# is right until someone renames a file teaches nobody it can be wrong.
set -u

here="$(CDPATH= cd -- "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENROLL="$here/linux/hub/enroll"
pass=0; fail=0
ok()  { pass=$((pass+1)); printf '  ok   %s\n' "$1"; }
bad() { fail=$((fail+1)); printf '  FAIL %s\n     %s\n' "$1" "${2:-}"; }
has()    { case "$2" in *"$3"*) ok "$1" ;; *) bad "$1" "missing '$3' in: $2" ;; esac; }

FX="$(mktemp -d)"; trap 'rm -rf "$FX"' EXIT
mkdir -p "$FX/estate" "$FX/sessions.d" "$FX/bus/bin" "$FX/bin"

cat > "$FX/estate/steward.conf" <<'CONF'
ESTATE_NAME="prov"
SCHEMA_VERSION="3"
RC_LABEL_PREFIX="Hub: "
HUB_SESSION="hub"
HUB_HOST="hubhost"
CONF

# THE REQUESTER MUST EXIST AND LIVE ON THE HOST IT NAMES. enroll checks both;
# without the conf the run refuses on identity and measures nothing about ID.
cat > "$FX/sessions.d/asker.conf" <<'CONF'
HOST="farhost"
OWNER="someone"
DOMAIN="d"
RC_LABEL="Asker"
REPO_PATH="/tmp/x"
ID="asker"
CONF

# The relay only has to EXIST — enroll refuses to write a key line naming a
# path that does not resolve, and that refusal has its own reason to live.
printf '#!/bin/bash\n' > "$FX/bus/bin/bus-relay-in"; chmod +x "$FX/bus/bin/bus-relay-in"
printf '#!/bin/bash\nexit 0\n' > "$FX/bin/send"; chmod +x "$FX/bin/send"
: > "$FX/authorized_keys"

req="$FX/req.txt"
cat > "$req" <<'REQ'
DRIFT enroll: acme-widget-someone requests registration
ENROLL-REQUEST v1
namn=acme-widget-someone
doman=acme
projekt=widget
person=someone
vard=farhost
repo=/home/someone/Projects/widget
pubkey=ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIFAKEKEYFORTESTONLYxxxxxxxxxxxxxxxxxxxxxxx test-only
REQ

out="$( STEWARD_ESTATE_ROOT="$FX" \
        STEWARD_REGISTRY_DIR="$FX/sessions.d" \
        STEWARD_RELAY_ROOT="$FX" \
        STEWARD_AUTHORIZED_KEYS="$FX/authorized_keys" \
        STEWARD_BUS_SEND="$FX/bin/send" \
        STEWARD_ENROLL_FROM=asker \
        bash "$ENROLL" --send < "$req" 2>&1 )"
rc=$?

echo "nav-enroll — the conf it writes"

conf="$FX/sessions.d/acme-widget-someone.conf"
if [ "$rc" -eq 0 ] && [ -f "$conf" ]; then ok "a valid request registers the name"
else bad "a valid request registers the name" "rc=$rc out=$out"; fi

body="$(cat "$conf" 2>/dev/null)"

# CONTROL GROUP FIRST: the fields that always worked must still be written, so a
# red ID assertion below means the ID line and not a broken fixture.
has "OWNER comes from the request"  "$body" 'OWNER="someone"'
has "DOMAIN comes from the request" "$body" 'DOMAIN="acme"'
has "HOST comes from the request"   "$body" 'HOST="farhost"'

# THE FINDING.
has "the conf carries an explicit ID" "$body" 'ID="acme-widget-someone"'

# AND THE ID IS THE NAME, not the label and not the domain. Those three coincide
# in a one-word estate and diverge everywhere else; pinning the value is what
# makes the assertion mean something.
case "$body" in
  *'ID="Hub: acme-widget-someone"'*|*'ID="acme"'*) bad "ID is the session name, not label or domain" "$body" ;;
  *) ok "ID is the session name, not label or domain" ;;
esac

echo
printf 'pass=%s fail=%s\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
