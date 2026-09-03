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
is()     { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "wanted '$3', got '$2'"; fi; }

FX="$(mktemp -d)"; trap 'rm -rf "$FX"' EXIT
mkdir -p "$FX/estate" "$FX/sessions.d" "$FX/bus/bin" "$FX/bin" \
  "$FX/accounts.d" "$FX/entities.d" "$FX/projects.d"

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

# ORG-TREE FIXTURES. Since the identity model landed (2026-08-30), enroll also
# refuses unless the request's target resolves (a project row, or absent that
# the domain's own entity row) and unless (OWNER, HOST) resolves to a known
# account — see test/nav-enroll.test.sh (estate) for the exhaustive coverage;
# this fixture only needs enough for the ONE request below to pass through.
cat > "$FX/entities.d/acme.conf" <<'CONF'
NAME="Acme"
CONF
cat > "$FX/accounts.d/someone-farhost.conf" <<'CONF'
PRINCIPAL="someone"
HOST="farhost"
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
repo=/srv/homes/someone/Projects/widget
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

# THE FILENAME IS THE MINTED ID (identity-and-registry-birth-chain, I3,
# 2026-09-01), not the constructed name — measured out of enroll's own
# success line ("... registered as s-<hex> ...").
id="$(printf '%s' "$out" | sed -n 's/.*registered as \(s-[0-9a-f]\{16\}\).*/\1/p' | head -1)"
conf="$FX/sessions.d/$id.conf"
if [ "$rc" -eq 0 ] && [ -n "$id" ] && [ -f "$conf" ]; then ok "a valid request registers the name"
else bad "a valid request registers the name" "rc=$rc id=$id out=$out"; fi

body="$(cat "$conf" 2>/dev/null)"

# CONTROL GROUP FIRST: the fields that always worked must still be written, so a
# red ID assertion below means the ID line and not a broken fixture.
has "OWNER comes from the request"  "$body" 'OWNER="someone"'
has "DOMAIN comes from the request" "$body" 'DOMAIN="acme"'
has "HOST comes from the request"   "$body" 'HOST="farhost"'

# THE FINDING (as it stood before the identity-and-registry-birth-chain work):
# the conf must carry an explicit ID line.
has "the conf carries an explicit ID" "$body" "ID=\"$id\""

# AND THE ID IS OPAQUE — s-<16 hex>, minted, immutable — never the constructed
# name, the label or the domain. Those coincided under the old shape (ID
# defaulted to the file's basename, which WAS the name); the new shape keeps
# the human name in SLUG instead, so pinning ID's actual shape is what makes
# this assertion mean something again.
case "$id" in
  s-????????????????) ok "ID is an opaque minted id, not the constructed name" ;;
  *) bad "ID is an opaque minted id, not the constructed name" "$id" ;;
esac
has "SLUG carries the constructed name" "$body" 'SLUG="acme-widget-someone"'
has "ACCOUNT resolves (OWNER, HOST) to the accounts.d row" "$body" 'ACCOUNT="someone-farhost"'
has "TARGET_ENTITY names the domain's own entity row" "$body" 'TARGET_ENTITY="acme"'

# THIS ESTATE IS SCHEMA 3 (below the LOGIN-required schema) AND THE REQUEST
# CARRIES NO login= LINE — the transition, byte for byte: no LOGIN line
# appears on a row this estate's own reader does not require it on. Writer
# census, task 9B: the append-only-when-given form below (linux/hub/enroll)
# must never interpolate an empty LOGIN line into the heredoc, only append a
# real one — this is that guarantee, read back off disk.
is "no LOGIN line on a schema-3, no-login row (transition, byte for byte)" \
   "$(printf '%s' "$body" | grep -c '^LOGIN=')" "0"

# ── WHAT IS SENT IS NOT WHAT MAY BE WRITTEN ─────────────────────────────────
# Two request fields land in a conf that is then SOURCED — by this tool's own
# gate and by every later reader of the register. Unguarded, `repo=/x$(touch
# PWNED)y` registered with rc 0 and ran its payload as the hub's owner on every
# read. The sender is any registered session, so this is a remote execution
# primitive handed to the population the enrolment path exists to grow.
run_req() { # <file> [extra env assignments are the caller's business]
  STEWARD_ESTATE_ROOT="$FX" \
  STEWARD_REGISTRY_DIR="$FX/sessions.d" \
  STEWARD_RELAY_ROOT="$FX" \
  STEWARD_ESTATE_CHECKOUT="${CHECKOUT_OVERRIDE:-}" \
  STEWARD_AUTHORIZED_KEYS="$FX/authorized_keys" \
  STEWARD_BUS_SEND="$FX/bin/send" \
  STEWARD_ENROLL_FROM=asker \
  bash "$ENROLL" --send < "$1" 2>&1
}
# A FRESH KEY PER CASE — one key, one identity, so a reused key would refuse
# for the wrong reason and the guard under test would never be reached.
mk_req() { # <file> <keytag> <sed expression>
  sed "s/FAKEKEYFORTESTONLYxxxxxxxxxxxxxxxxxxxxxxx/FAKEKEY$2xxxxxxxxxxxxxxxxxxxxxxx/; $3" "$req" > "$FX/mut.txt"
}
before_n="$(ls "$FX/sessions.d"/s-*.conf 2>/dev/null | wc -l | tr -d ' ')"
rm -f "$FX/PWNED"

mk_req x A 's|^repo=.*|repo=/srv/homes/x$(touch '"$FX"'/PWNED)y|'
out2="$(run_req "$FX/mut.txt")"; rc2=$?
if [ "$rc2" -eq 65 ]; then ok "a command substitution in repo= is refused"
else bad "a command substitution in repo= is refused" "rc=$rc2 out=$out2"; fi
if [ ! -e "$FX/PWNED" ]; then ok "the repo= payload never ran"
else bad "the repo= payload never ran" "PWNED exists"; fi

mk_req x B 's|^pubkey=|rc_label=Widget$(touch '"$FX"'/PWNED)\
pubkey=|'
out2="$(run_req "$FX/mut.txt")"; rc2=$?
if [ "$rc2" -eq 65 ]; then ok "a command substitution in rc_label= is refused"
else bad "a command substitution in rc_label= is refused" "rc=$rc2 out=$out2"; fi
if [ ! -e "$FX/PWNED" ]; then ok "the rc_label= payload never ran"
else bad "the rc_label= payload never ran" "PWNED exists"; fi

mk_req x C 's|^repo=.*|repo=not/absolute|'
out2="$(run_req "$FX/mut.txt")"; rc2=$?
if [ "$rc2" -eq 65 ]; then ok "a relative repo path is refused"
else bad "a relative repo path is refused" "rc=$rc2 out=$out2"; fi

after_n="$(ls "$FX/sessions.d"/s-*.conf 2>/dev/null | wc -l | tr -d ' ')"
if [ "$before_n" -eq "$after_n" ]; then ok "no refused request left a row behind"
else bad "no refused request left a row behind" "$before_n -> $after_n"; fi

# ── THE ROW MUST REACH THE ESTATE'S CHECKOUT ────────────────────────────────
# The deploy reconciles the hub's runtime register against the checkout and
# deletes the remainder, and hosts install FROM the checkout. A row written only
# to the runtime register therefore disappeared at the next install and never
# reached the host that was supposed to run it.
mkdir -p "$FX/checkout/sessions.d"
CHECKOUT_OVERRIDE="$FX/checkout"
mk_req x D 's|^namn=.*|namn=acme-gadget-someone|; s|^projekt=.*|projekt=gadget|'
out2="$(run_req "$FX/mut.txt")"; rc2=$?
id2="$(printf '%s' "$out2" | sed -n 's/.*registered as \(s-[0-9a-f]\{16\}\).*/\1/p' | head -1)"
if [ "$rc2" -eq 0 ] && [ -n "$id2" ] && [ -f "$FX/checkout/sessions.d/$id2.conf" ]; then
  ok "the row is written to the estate checkout too"
else bad "the row is written to the estate checkout too" "rc=$rc2 id=$id2 out=$out2"; fi
if cmp -s "$FX/checkout/sessions.d/$id2.conf" "$FX/sessions.d/$id2.conf"; then
  ok "the checkout row is byte-identical to the runtime row"
else bad "the checkout row is byte-identical to the runtime row"; fi
has "the operator is told to commit it" "$out2" "COMMIT AND PUSH IT"

# NO CHECKOUT: still registered, but LOUD — the conf and its destination are
# printed, because the alternative is a row that quietly disappears.
CHECKOUT_OVERRIDE=""
mk_req x E 's|^namn=.*|namn=acme-sprocket-someone|; s|^projekt=.*|projekt=sprocket|'
out2="$(run_req "$FX/mut.txt")"; rc2=$?
if [ "$rc2" -eq 0 ]; then ok "no checkout still registers"
else bad "no checkout still registers" "rc=$rc2 out=$out2"; fi
has "no checkout names the key to set" "$out2" "ESTATE_CHECKOUT"
has "no checkout prints the conf itself" "$out2" 'SLUG="acme-sprocket-someone"'

# ── THE ACTIVATION COMMAND CARRIES BOTH HALVES OF THE PAIRING ───────────────
# With the id alone, the receiving host had to guess which local key the id
# belonged to. The guess was ambiguous on any host that already had a session,
# and silently WRONG when exactly one candidate survived — it linked another
# session's key under the new id, so the newborn's mail went out stamped with
# that other session's name. The slug is what the requester filed its key
# under, so the hub, which knows both names here, prints both.
# --no-send, because that is the mode that prints the messages themselves.
mk_req x F 's|^namn=.*|namn=acme-cog-someone|; s|^projekt=.*|projekt=cog|'
out2="$( STEWARD_ESTATE_ROOT="$FX" STEWARD_REGISTRY_DIR="$FX/sessions.d" \
         STEWARD_RELAY_ROOT="$FX" STEWARD_AUTHORIZED_KEYS="$FX/authorized_keys" \
         STEWARD_ENROLL_FROM=asker \
         bash "$ENROLL" --no-send < "$FX/mut.txt" 2>&1 )"
id3="$(printf '%s' "$out2" | sed -n 's/.*registered as \(s-[0-9a-f]\{16\}\).*/\1/p' | head -1)"
has "the activate command carries id and slug" "$out2" "--activate $id3 acme-cog-someone"
has "CONFIRM still carries the id" "$out2" "id=$id3"

# ── THE LOGIN FIELD (writer census, task 9B) ────────────────────────────────
# A SEPARATE, SCHEMA-6 FIXTURE — the estate above is schema 3 deliberately
# (the transition case, proved above), so the LOGIN-required gate needs its
# own estate to exercise. Two accounts, two principals, one login, so both
# the "no login" refusal and the shared registry_login_principal_gate
# mismatch have something real to fail against.
echo
echo "nav-enroll — the LOGIN field, schema 6"
LFX="$(mktemp -d)"; trap 'rm -rf "$LFX" "$FX"' EXIT
mkdir -p "$LFX/estate" "$LFX/sessions.d" "$LFX/bus/bin" "$LFX/bin" \
  "$LFX/accounts.d" "$LFX/entities.d" "$LFX/projects.d" "$LFX/logins.d"
cat > "$LFX/estate/steward.conf" <<'CONF'
ESTATE_NAME="prov"
SCHEMA_VERSION="6"
RC_LABEL_PREFIX="Hub: "
HUB_SESSION="hub"
HUB_HOST="hubhost"
CONF
cat > "$LFX/sessions.d/asker.conf" <<'CONF'
HOST="farhost"
OWNER="someone"
DOMAIN="d"
RC_LABEL="Asker"
REPO_PATH="/tmp/x"
ID="asker"
CONF
cat > "$LFX/entities.d/acme.conf" <<'CONF'
NAME="Acme"
CONF
cat > "$LFX/accounts.d/someone-farhost.conf" <<'CONF'
PRINCIPAL="someone"
HOST="farhost"
CONF
cat > "$LFX/logins.d/acme-team.conf" <<'CONF'
PRINCIPAL="someone"
ACCOUNT="acme-team-seat"
PROVIDER="claude-team"
CONFIG_DIR="~/.claude-logins/acme-team"
LEGAL_OWNER="Acme Corp"
CONF
chmod 600 "$LFX/logins.d/acme-team.conf"
# A SECOND LOGIN, A DIFFERENT PRINCIPAL — the requester's identity (PERSON,
# via the owner check above) fixes WHICH account resolves, so a mismatch
# case cannot come from changing PERSON; it has to come from naming a login
# that belongs to somebody else entirely.
cat > "$LFX/logins.d/other-login.conf" <<'CONF'
PRINCIPAL="other"
ACCOUNT="other-seat"
PROVIDER="claude-team"
CONFIG_DIR="~/.claude-logins/other-login"
LEGAL_OWNER="Other Corp"
CONF
chmod 600 "$LFX/logins.d/other-login.conf"
printf '#!/bin/bash\n' > "$LFX/bus/bin/bus-relay-in"; chmod +x "$LFX/bus/bin/bus-relay-in"
printf '#!/bin/bash\nexit 0\n' > "$LFX/bin/send"; chmod +x "$LFX/bin/send"
: > "$LFX/authorized_keys"

run_lreq() { # <request-file>
  STEWARD_ESTATE_ROOT="$LFX" STEWARD_REGISTRY_DIR="$LFX/sessions.d" \
  STEWARD_RELAY_ROOT="$LFX" STEWARD_AUTHORIZED_KEYS="$LFX/authorized_keys" \
  STEWARD_BUS_SEND="$LFX/bin/send" STEWARD_ENROLL_FROM=asker \
  bash "$ENROLL" --send < "$1" 2>&1
}
lreq() { # <file> <namn/projekt-suffix> <login-line-or-empty>
  cat > "$1" <<EOF2
DRIFT enroll: acme-$2-someone requests registration
ENROLL-REQUEST v1
namn=acme-$2-someone
doman=acme
projekt=$2
person=someone
vard=farhost
repo=/srv/homes/someone/Projects/$2
${3}pubkey=ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIFAKEKEY$2xxxxxxxxxxxxxxxxxxxxxxx test-only
EOF2
}

# L1. login= NAMES A LOGIN WHOSE PRINCIPAL MATCHES THE RESOLVED ACCOUNT.
lreq "$LFX/l1.txt" widgetl "login=acme-team
"
out="$(run_lreq "$LFX/l1.txt")"; rc=$?
is "L1: a login whose principal matches the account registers, rc 0" "$rc" "0"
id1="$(printf '%s' "$out" | sed -n 's/.*registered as \(s-[0-9a-f]\{16\}\).*/\1/p' | head -1)"
has "L1: the row carries the LOGIN line" "$(cat "$LFX/sessions.d/$id1.conf" 2>/dev/null)" 'LOGIN="acme-team"'

# L2. login= NAMES A LOGIN THAT BELONGS TO A DIFFERENT PRINCIPAL THAN THE
# RESOLVED ACCOUNT — GATE 1, the shared registry_login_principal_gate.
before="$(ls "$LFX/sessions.d" | sort)"
lreq "$LFX/l2.txt" widgetm "login=other-login
"
out="$(run_lreq "$LFX/l2.txt")"; rc=$?
is "L2: a login whose principal does NOT match the account refuses, rc 65" "$rc" "65"
has "L2: the refusal names the login's own principal" "$out" "other"
is "L2: nothing was written" "$(ls "$LFX/sessions.d" | sort)" "$before"

# L3. login= NAMES A LOGIN THAT DOES NOT EXIST.
before="$(ls "$LFX/sessions.d" | sort)"
lreq "$LFX/l3.txt" widgetn "login=no-such-login
"
out="$(run_lreq "$LFX/l3.txt")"; rc=$?
is "L3: an unknown login refuses, rc 78" "$rc" "78"
is "L3: nothing was written" "$(ls "$LFX/sessions.d" | sort)" "$before"

# L4. NO login= AT ALL, AGAINST A SCHEMA-6 ESTATE.
before="$(ls "$LFX/sessions.d" | sort)"
lreq "$LFX/l4.txt" widgeto ""
out="$(run_lreq "$LFX/l4.txt")"; rc=$?
is "L4: no login at schema 6 refuses, rc 65" "$rc" "65"
has "L4: the refusal names the missing field" "$out" "login"
is "L4: nothing was written" "$(ls "$LFX/sessions.d" | sort)" "$before"

# ── registry_estate_checkout: THE THREE OUTCOMES ────────────────────────────
# Optional field, same contract as registry_liveness_cmd: absent is not broken,
# invalid is a refusal, and a relative path is invalid because it would resolve
# against whatever directory happened to be current.
# shellcheck source=/dev/null
( . "$here/lib/registry.sh"
  v="$(STEWARD_ESTATE_ROOT="$FX" registry_estate_checkout)" || exit 9
  [ -z "$v" ] || exit 8 ) \
  && ok "an estate with no ESTATE_CHECKOUT prints nothing, rc 0" \
  || bad "an estate with no ESTATE_CHECKOUT prints nothing, rc 0"
printf 'ESTATE_CHECKOUT="relative/path"\n' >> "$FX/estate/steward.conf"
( . "$here/lib/registry.sh"
  STEWARD_ESTATE_ROOT="$FX" registry_estate_checkout >/dev/null 2>&1; [ "$?" -eq 78 ] ) \
  && ok "a relative ESTATE_CHECKOUT refuses with rc 78" \
  || bad "a relative ESTATE_CHECKOUT refuses with rc 78"
( . "$here/lib/registry.sh"
  v="$(STEWARD_ESTATE_ROOT="$FX" STEWARD_ESTATE_CHECKOUT=/tmp/override registry_estate_checkout)" \
  && [ "$v" = "/tmp/override" ] ) \
  && ok "the environment override wins over the estate file" \
  || bad "the environment override wins over the estate file"

echo
printf 'pass=%s fail=%s\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
