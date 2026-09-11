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
mkdir -p "$FX/estate" "$FX/reg" "$FX/bus/bin" "$FX/bin" \
  "$FX/accounts.d" "$FX/entities.d" "$FX/projects.d"

# THE WHOLE REQUIRED KEY SET, because enrolment now READS the register back.
# This fixture used to carry the five keys enroll itself touched: it wrote rows
# and never loaded one. Computing the new session's project mates makes enroll a
# registry_load reader for the first time, and that loader reads several estate
# values unconditionally and refuses (rc 78) on a half-built estate — which is
# not a thing a real estate can be, since every one of these keys is required
# there too. Without them the mates line would report "the register could not be
# read back" and the fixture, not the product, would be what was measured.
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

# THE REQUESTER MUST EXIST AND LIVE ON THE HOST IT NAMES. enroll checks both;
# without the conf the run refuses on identity and measures nothing about ID.
cat > "$FX/reg/asker.conf" <<'CONF'
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
        STEWARD_REGISTRY_DIR="$FX/reg" \
        STEWARD_RELAY_ROOT="$FX" \
        STEWARD_AUTHORIZED_KEYS="$FX/authorized_keys" \
        STEWARD_BUS_SEND="$FX/bin/send" \
        STEWARD_REGISTRY_LIB="$here/lib/registry.sh" STEWARD_ENROLL_FROM=asker \
        bash "$ENROLL" --send < "$req" 2>&1 )"
rc=$?

echo "nav-enroll — the conf it writes"

# THE FILENAME IS THE MINTED ID (identity-and-registry-birth-chain, I3,
# 2026-09-01), not the constructed name — measured out of enroll's own
# success line ("... registered as s-<hex> ...").
id="$(printf '%s' "$out" | sed -n 's/.*registered as \(s-[0-9a-f]\{16\}\).*/\1/p' | head -1)"
conf="$FX/reg/$id.conf"
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

# THE KEY LINE MUST CARRY THE ESTATE ROOT THE HUB ITSELF RAN WITH. A hub whose
# HOME is not the estate checkout (its own rows are the only ones under its own
# sessions.d) resolves the recipient through registry_dir(), which honours
# STEWARD_ESTATE_ROOT - unset in an sshd forced command. Without the assignment
# living in the line itself, the relay only ever knows the hub's own rows.
keyline="$(cat "$FX/authorized_keys")"
prefix="restrict,command=\"STEWARD_ESTATE_ROOT=$FX /bin/bash $FX/bus/bin/bus-relay-in $id\" "
case "$keyline" in
  "$prefix"*) ok "the key line carries the estate root the hub ran with" ;;
  *) bad "the key line carries the estate root the hub ran with" "$keyline" ;;
esac

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
  STEWARD_REGISTRY_DIR="$FX/reg" \
  STEWARD_RELAY_ROOT="$FX" \
  STEWARD_ESTATE_CHECKOUT="${CHECKOUT_OVERRIDE:-}" \
  STEWARD_AUTHORIZED_KEYS="$FX/authorized_keys" \
  STEWARD_BUS_SEND="$FX/bin/send" \
  STEWARD_REGISTRY_LIB="$here/lib/registry.sh" STEWARD_ENROLL_FROM=asker \
  bash "$ENROLL" --send < "$1" 2>&1
}
# A FRESH KEY PER CASE — one key, one identity, so a reused key would refuse
# for the wrong reason and the guard under test would never be reached.
mk_req() { # <file> <keytag> <sed expression>
  sed "s/FAKEKEYFORTESTONLYxxxxxxxxxxxxxxxxxxxxxxx/FAKEKEY$2xxxxxxxxxxxxxxxxxxxxxxx/; $3" "$req" > "$FX/mut.txt"
}
before_n="$(ls "$FX/reg"/s-*.conf 2>/dev/null | wc -l | tr -d ' ')"
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

after_n="$(ls "$FX/reg"/s-*.conf 2>/dev/null | wc -l | tr -d ' ')"
if [ "$before_n" -eq "$after_n" ]; then ok "no refused request left a row behind"
else bad "no refused request left a row behind" "$before_n -> $after_n"; fi

# ── THE ROW MUST REACH THE ESTATE'S CHECKOUT ────────────────────────────────
# The deploy reconciles the hub's runtime register against the checkout and
# deletes the remainder, and hosts install FROM the checkout. A row written only
# to the runtime register therefore disappeared at the next install and never
# reached the host that was supposed to run it.
mkdir -p "$FX/checkout/sessions.d"
CHECKOUT_OVERRIDE="$FX/checkout"
# -- EVERY CASE BELOW NAMES ITS OWN rc_label=, AND THAT IS THE FIXTURE BEING
# HONEST, NOT A CLAIM BEING SOFTENED ----------------------------------------
# Since 2026-09-09 enroll refuses a second row carrying an RC_LABEL another row
# in the SAME HOME already carries: the label is what supervision's orphan reap
# pgreps for and what --remote-control pairs on, so two rows sharing one cannot
# be told apart (that collision cross-killed 13 conversations on a live host).
#
# THIS FIXTURE'S projects.d IS EMPTY, so registry_display_for falls back to the
# domain's ENTITY for every request - one label, "Hub: Acme", for the whole
# home. Every case from here on registers a further session as person=someone
# on farhost, i.e. into that one home, and each is about something else
# entirely (the checkout copy, the activation line, RUNTIME, the mates
# read-back). Naming a distinct label per case is what a real estate does
# through its projects; here it is spelled out so the case under test is the
# one that decides the outcome.
mk_req x D 's|^namn=.*|namn=acme-gadget-someone|; s|^projekt=.*|projekt=gadget|; s|^pubkey=|rc_label=Case Gadget\
pubkey=|'
out2="$(run_req "$FX/mut.txt")"; rc2=$?
id2="$(printf '%s' "$out2" | sed -n 's/.*registered as \(s-[0-9a-f]\{16\}\).*/\1/p' | head -1)"
if [ "$rc2" -eq 0 ] && [ -n "$id2" ] && [ -f "$FX/checkout/sessions.d/$id2.conf" ]; then
  ok "the row is written to the estate checkout too"
else bad "the row is written to the estate checkout too" "rc=$rc2 id=$id2 out=$out2"; fi
if cmp -s "$FX/checkout/sessions.d/$id2.conf" "$FX/reg/$id2.conf"; then
  ok "the checkout row is byte-identical to the runtime row"
else bad "the checkout row is byte-identical to the runtime row"; fi
has "the operator is told to commit it" "$out2" "COMMIT AND PUSH IT"

# NO CHECKOUT: still registered, but LOUD — the conf and its destination are
# printed, because the alternative is a row that quietly disappears.
CHECKOUT_OVERRIDE=""
mk_req x E 's|^namn=.*|namn=acme-sprocket-someone|; s|^projekt=.*|projekt=sprocket|; s|^pubkey=|rc_label=Case Sprocket\
pubkey=|'
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
mk_req x F 's|^namn=.*|namn=acme-cog-someone|; s|^projekt=.*|projekt=cog|; s|^pubkey=|rc_label=Case Cog\
pubkey=|'
out2="$( STEWARD_ESTATE_ROOT="$FX" STEWARD_REGISTRY_DIR="$FX/reg" \
         STEWARD_RELAY_ROOT="$FX" STEWARD_AUTHORIZED_KEYS="$FX/authorized_keys" \
         STEWARD_REGISTRY_LIB="$here/lib/registry.sh" STEWARD_ENROLL_FROM=asker \
         bash "$ENROLL" --no-send < "$FX/mut.txt" 2>&1 )"
id3="$(printf '%s' "$out2" | sed -n 's/.*registered as \(s-[0-9a-f]\{16\}\).*/\1/p' | head -1)"
has "the activate command carries id and slug" "$out2" "--activate $id3 acme-cog-someone"
has "CONFIRM still carries the id" "$out2" "id=$id3"

# ── THE SAME-HOST CASE: CONFIRM/PROOF MUST NAME THE OWNER'S OWN ~/scripts ──
# A requester whose vard= names the HUB'S OWN host takes the "same host"
# branch. The owner still runs the printed commands in THEIR OWN home, which
# is unreadable to the hub account on a host where the two are separate unix
# accounts — so this branch must print exactly the same tilde form as every
# other host, never the hub's own absolute path.
lacks() { case "$2" in *"$3"*) bad "$1" "found unwanted '$3' in: $2" ;; *) ok "$1" ;; esac; }
cat > "$FX/reg/asker-hub.conf" <<'CONF'
HOST="hubhost"
OWNER="someone"
DOMAIN="d"
RC_LABEL="Asker"
REPO_PATH="/tmp/x"
ID="asker-hub"
CONF
cat > "$FX/accounts.d/someone-hubhost.conf" <<'CONF'
PRINCIPAL="someone"
HOST="hubhost"
CONF
cat > "$FX/samehost-req.txt" <<'REQ'
DRIFT enroll: acme-samehost-someone requests registration
ENROLL-REQUEST v1
namn=acme-samehost-someone
doman=acme
projekt=samehost
person=someone
vard=hubhost
repo=/srv/homes/someone/Projects/samehost
pubkey=ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIFAKEKEYSAMEHOSTxxxxxxxxxxxxxxxxxxxx test-only
REQ
# STDOUT AND STDERR ARE KEPT APART ON PURPOSE: the "no estate checkout" NOTE
# on stderr legitimately prints the fixture's own conf path (it is telling the
# operator where the row lives), so mixing it into $out_sh would make the
# "never the fixture HOME" check below fail for a reason that has nothing to
# do with CONFIRM/PROOF. Only stdout carries the --no-send printf block
# (CONFIRM, PROOF) and the final "registered as" line.
out_sh="$( STEWARD_ESTATE_ROOT="$FX" STEWARD_REGISTRY_DIR="$FX/reg" \
           STEWARD_RELAY_ROOT="$FX" STEWARD_AUTHORIZED_KEYS="$FX/authorized_keys" \
           STEWARD_REGISTRY_LIB="$here/lib/registry.sh" STEWARD_ENROLL_FROM=asker-hub \
           bash "$ENROLL" --no-send < "$FX/samehost-req.txt" 2>/dev/null )"
id_sh="$(printf '%s' "$out_sh" | sed -n 's/.*registered as \(s-[0-9a-f]\{16\}\).*/\1/p' | head -1)"
has "same host: the activate command uses the owner's own ~/scripts" \
    "$out_sh" "activate=bash ~/scripts/session-new.sh --activate $id_sh acme-samehost-someone"
has "same host: the approval gate uses the owner's own ~/scripts" \
    "$out_sh" "gate=the approval runs FROM the new session: bash ~/scripts/session-approve.sh"
has "same host: PROOF's task uses the owner's own ~/scripts" \
    "$out_sh" "task=run: bash ~/scripts/session-approve.sh"
has "same host: PROOF's fleet-questions uses the owner's own ~/scripts" \
    "$out_sh" "fleet-questions=answer from the estate's own data: bash ~/scripts/estate-status.sh"
lacks "same host: CONFIRM/PROOF never name the hub's own absolute path" "$out_sh" "$here"
lacks "same host: CONFIRM/PROOF never name the fixture HOME" "$out_sh" "$FX"

# ── THE DEFAULT RC LABEL IS THE DERIVED DISPLAY NAME, NOT THE SLUG ──────────
# Measured on a live estate: a request with no rc_label= got
# "<prefix><slug>" (e.g. "Hub: acme-widget-someone") while every other row in
# the estate shows the "Parent->Project" form registry_display_for derives.
# The label a session RUNS under becomes a pairing name a human keeps, so the
# construction default should match what the rest of the estate shows.
echo
echo "nav-enroll — the default RC label"

# A second-level org tree (a project under an entity, not just the domain's
# own entity row) so the project-display branch has something real to derive.
cat > "$FX/entities.d/team.conf" <<'CONF'
NAME="Team"
MEMBERS="someone"
CONF
cat > "$FX/projects.d/work.conf" <<'CONF'
NAME="Work"
PARENT="team"
CONF

# (a) NO rc_label=, and the project resolves — the default is the prefix plus
# the derived "Entity->Project" display, not the constructed slug.
mk_req x G 's|^namn=.*|namn=team-work-someone|; s|^doman=.*|doman=team|; s|^projekt=.*|projekt=work|'
out2="$(run_req "$FX/mut.txt")"; rc2=$?
idg="$(printf '%s' "$out2" | sed -n 's/.*registered as \(s-[0-9a-f]\{16\}\).*/\1/p' | head -1)"
if [ "$rc2" -eq 0 ] && [ -n "$idg" ]; then ok "(a) a request naming a resolving project registers"
else bad "(a) a request naming a resolving project registers" "rc=$rc2 out=$out2"; fi
bodyg="$(cat "$FX/reg/$idg.conf" 2>/dev/null)"
has "(a) no rc_label defaults to the prefix plus the derived display name" \
    "$bodyg" "$(printf 'RC_LABEL="Hub: Team%sWork"' '→')"

# (a2) A SECOND REQUEST ON THE SAME RESOLVING PROJECT IN THE SAME HOME is refused. The naming convention
# (doman-projekt-person) makes it the same slug in the same account, so the (account, slug) gate speaks
# first; the work rule of spec §3 (one claude-code conversation per (login, project)) stands behind it in
# enroll as defence in depth and is proven as a predicate in test/registry-session-display.test.sh.
mk_req x G2 's|^namn=.*|namn=team-work-someone|; s|^doman=.*|doman=team|; s|^projekt=.*|projekt=work|; s|^pubkey=|rc_label=Work Again\
pubkey=|'
before_g2="$(ls "$FX/reg"/s-*.conf 2>/dev/null | wc -l | tr -d ' ')"
out2="$(run_req "$FX/mut.txt")"; rc2=$?
if [ "$rc2" -ne 0 ]; then ok "(a2) a second row on the same (home, project) is refused by the work rule"
else bad "(a2) a second row on the same (home, project) is refused by the work rule" "rc=$rc2 out=$out2"; fi
has "(a2) the refusal names the slug and the account" "$out2" "slug 'team-work-someone' is already taken in account 'someone-farhost'"
is "(a2) nothing was written" "$(ls "$FX/reg"/s-*.conf 2>/dev/null | wc -l | tr -d ' ')" "$before_g2"

# (b) rc_label= IN THE REQUEST STILL WINS, UNCHANGED — today's rule takes the
# field verbatim, with no prefix added (RC_ETIKETT="${RC_ONSKAD:-...}"), and
# that has to stay true after this fix.
mk_req x H 's|^namn=.*|namn=acme-widgetzz-someone|; s|^doman=.*|doman=acme|; s|^projekt=.*|projekt=widgetzz|; s|^pubkey=|rc_label=Custom\
pubkey=|'
out2="$(run_req "$FX/mut.txt")"; rc2=$?
idh="$(printf '%s' "$out2" | sed -n 's/.*registered as \(s-[0-9a-f]\{16\}\).*/\1/p' | head -1)"
bodyh="$(cat "$FX/reg/$idh.conf" 2>/dev/null)"
has "(b) rc_label= in the request still wins, unprefixed, exactly as today" \
    "$bodyh" 'RC_LABEL="Custom"'

# (c) THE FALLBACK NEVER HARD-FAILS. An entity whose NAME carries the display
# separator itself makes registry_display_for refuse (it is the guard that
# stops a NAME from spoofing the "->" join), even though the entity row loads
# fine for the earlier org-tree precondition. Neither the project (does not
# exist) nor the entity display resolves, so the row must fall back to
# exactly today's construction: prefix plus the constructed slug.
printf 'NAME="Bad%sName"\n' '→' > "$FX/entities.d/c.conf"
mk_req x I 's|^namn=.*|namn=c-nope-someone|; s|^doman=.*|doman=c|; s|^projekt=.*|projekt=nope|'
out2="$(run_req "$FX/mut.txt")"; rc2=$?
idi="$(printf '%s' "$out2" | sed -n 's/.*registered as \(s-[0-9a-f]\{16\}\).*/\1/p' | head -1)"
if [ "$rc2" -eq 0 ] && [ -n "$idi" ]; then ok "(c) a request whose display cannot be derived still registers"
else bad "(c) a request whose display cannot be derived still registers" "rc=$rc2 out=$out2"; fi
bodyi="$(cat "$FX/reg/$idi.conf" 2>/dev/null)"
has "(c) an undeliverable display falls back to the slug form, exactly as today" \
    "$bodyi" 'RC_LABEL="Hub: c-nope-someone"'

# ── THE PROOF NAMES WHO ELSE WORKS HERE ─────────────────────────────────────
# A session's very first turn used to begin with no idea that anybody else was
# working on the same project. The bus could already carry a message between
# them; nothing told either side there was somebody to write to. ENROLL-PROOF
# is the one document the newborn reads before it does anything, so the answer
# belongs there — computed from the register at that moment, never from a list
# a human keeps.
#
# THE ROW IS WRITTEN BEFORE THE PROOF IS BUILT, so the new session is in the
# register while its own mates are computed. It must never appear in its own
# list, and a session on ANOTHER project must never appear at all — the whole
# value of the line is that it is narrow enough to act on.
echo
echo "nav-enroll — the project mates in ENROLL-PROOF"

cat > "$FX/projects.d/other.conf" <<'CONF'
NAME="Other"
PARENT="team"
CONF
cat > "$FX/projects.d/solo.conf" <<'CONF'
NAME="Solo"
PARENT="team"
CONF
# The row already at work on the project the request below enrols into. The
# decoy is case (a)'s row, registered on project "work" under the same entity:
# a rule that resolved each project to its PARENT would report it as a mate.
cat > "$FX/reg/mate-other.conf" <<'CONF'
HOST="farhost"
OWNER="ann"
DOMAIN="team"
REPO_PATH="/tmp/x"
ID="mate-other"
TARGET_PROJECT="other"
CONF

# --no-send is the mode that prints CONFIRM and PROOF themselves. stderr is
# dropped for the reason the same-host case above drops it: the "no estate
# checkout" NOTE legitimately prints fixture paths, and only stdout carries
# the proof block.
mk_req x J 's|^namn=.*|namn=team-other-someone|; s|^doman=.*|doman=team|; s|^projekt=.*|projekt=other|'
out2="$( STEWARD_ESTATE_ROOT="$FX" STEWARD_REGISTRY_DIR="$FX/reg" \
         STEWARD_RELAY_ROOT="$FX" STEWARD_AUTHORIZED_KEYS="$FX/authorized_keys" \
         STEWARD_REGISTRY_LIB="$here/lib/registry.sh" STEWARD_ENROLL_FROM=asker \
         bash "$ENROLL" --no-send < "$FX/mut.txt" 2>/dev/null )"
idj="$(printf '%s' "$out2" | sed -n 's/.*registered as \(s-[0-9a-f]\{16\}\).*/\1/p' | head -1)"
if [ -n "$idj" ]; then ok "a request into a project somebody is already on registers"
else bad "a request into a project somebody is already on registers" "out=$out2"; fi
# THE WHOLE LINE IS ASSERTED, not merely that the mate is somewhere in it: an
# equality is the only form that also proves the OTHER project's row and the
# newborn itself are absent.
mates_j="$(printf '%s' "$out2" | sed -n 's/^project-mates=//p' | head -1)"
is    "PROOF names the session already on this project, with its owner and display" \
      "$mates_j" "mate-other (ann) Team→Other"
lacks "and never the row on the sibling project" "$mates_j" "$idg"
lacks "and never the newborn itself"             "$mates_j" "$idj"

# NOBODY ELSE IS AN ANSWER, AND IT IS SPELLED OUT. An empty value after the
# `=` would read as a line that broke, and a session that cannot tell "nobody
# is here" from "this did not work" learns to ignore the line.
mk_req x K 's|^namn=.*|namn=team-solo-someone|; s|^doman=.*|doman=team|; s|^projekt=.*|projekt=solo|'
out2="$( STEWARD_ESTATE_ROOT="$FX" STEWARD_REGISTRY_DIR="$FX/reg" \
         STEWARD_RELAY_ROOT="$FX" STEWARD_AUTHORIZED_KEYS="$FX/authorized_keys" \
         STEWARD_REGISTRY_LIB="$here/lib/registry.sh" STEWARD_ENROLL_FROM=asker \
         bash "$ENROLL" --no-send < "$FX/mut.txt" 2>/dev/null )"
has "a project nobody is on gets the spelled-out empty answer" "$out2" "project-mates=none"

# ── THE LOGIN FIELD (writer census, task 9B) ────────────────────────────────
# A SEPARATE, SCHEMA-6 FIXTURE — the estate above is schema 3 deliberately
# (the transition case, proved above), so the LOGIN-required gate needs its
# own estate to exercise. Two accounts, two principals, one login, so both
# the "no login" refusal and the shared registry_login_principal_gate
# mismatch have something real to fail against.
echo
echo "nav-enroll — the LOGIN field, schema 6"
GFX=""
LFX="$(mktemp -d)"; trap 'rm -rf "$LFX" "$GFX" "$FX"' EXIT
mkdir -p "$LFX/estate" "$LFX/sessions.d" "$LFX/bus/bin" "$LFX/bin" \
  "$LFX/accounts.d" "$LFX/entities.d" "$LFX/projects.d" "$LFX/logins.d"
# 0700, PINNED. The login reader refuses a group- or other-writable register, so
# under the Debian default umask of 002 a fixture that lets `mkdir` pick the mode
# measures the HOST, not the product. See test/register-modes.test.sh.
chmod 700 "$LFX/logins.d"
# THE FULL ESTATE KEY SET, for the reason the FX fixture at the top of this
# file carries it and the GFX fixture below says out loud: enrolment READS the
# register back, and registry_load refuses (rc 78) on a half-built estate.
# This fixture kept the trimmed five keys, so L1/L2/R1/R2 were measuring a
# missing OP_TOKEN_FILE_NAME rather than the LOGIN and RUNTIME fields they
# were written for.
cat > "$LFX/estate/steward.conf" <<'CONF'
ESTATE_NAME="prov"
SCHEMA_VERSION="6"
LABEL_PREFIX="com.prov.claude"
RC_LABEL_PREFIX="Hub: "
HUB_SESSION="hub"
HUB_HOST="hubhost"
HUB_SSH="alice@hubhost"
JOB_LOG_DIR="prov-jobs"
TMUX_SOCKET="prov.sock"
PING_MSG="you have mail"
STATE_DIR_NAME="prov-supervisor"
PAUSED_DIR_NAME="prov-paused"
JOB_LABEL_PREFIX="com.prov.job"
SERVICE_LABEL_PREFIX="com.prov.service"
BROWSER_LABEL_PREFIX="com.prov.browser"
OP_TOKEN_FILE_NAME="prov-token"
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
  STEWARD_BUS_SEND="$LFX/bin/send" STEWARD_REGISTRY_LIB="$here/lib/registry.sh" STEWARD_ENROLL_FROM=asker \
  bash "$ENROLL" --send < "$1" 2>&1
}
# ONE LABEL PER CASE, for the reason spelled out at case D above: these all
# enrol into the one home (someone on farhost) of an estate whose projects do
# not resolve, so without an explicit label every one of them would derive
# "Hub: Acme" and the second would be refused as a duplicate. None of L1-L4,
# R1-R3 or G1-G2 is about the label.
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
rc_label=Case $2
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

# ── THE RUNTIME FIELD ───────────────────────────────────────────────────────
# A row's RUNTIME decides which units activation enables: agent-session@ for
# the default, agent-codex@ (path + timer, no tmux, no supervisor) for a codex
# row. The requester says which it wants with `--runtime codex`; enroll is the
# sole conf writer, so the word has to reach the row through the request. The
# same append-only rule as LOGIN: absent runtime= writes no RUNTIME line at
# all — a request from an un-updated caller produces byte-identical output.
echo "nav-enroll — the RUNTIME field"

# R1. runtime=codex LANDS AS RUNTIME="codex", after LOGIN.
lreq "$LFX/r1.txt" widgetr "login=acme-team
runtime=codex
"
out="$(run_lreq "$LFX/r1.txt")"; rc=$?
is "R1: runtime=codex registers, rc 0" "$rc" "0"
idr="$(printf '%s' "$out" | sed -n 's/.*registered as \(s-[0-9a-f]\{16\}\).*/\1/p' | head -1)"
bodyr="$(cat "$LFX/sessions.d/$idr.conf" 2>/dev/null)"
has "R1: the row carries RUNTIME=\"codex\"" "$bodyr" 'RUNTIME="codex"'
is "R1: RUNTIME is the last line, after LOGIN (append-only, like LOGIN)" \
   "$(printf '%s\n' "$bodyr" | tail -2 | tr '\n' ' ')" 'LOGIN="acme-team" RUNTIME="codex" '

# R2. NO runtime= WRITES NO RUNTIME LINE — byte for byte the row of an
# un-updated caller (L1 is that row; count the line, do not trust memory).
is "R2: no runtime= leaves no RUNTIME line (transition, byte for byte)" \
   "$(grep -c '^RUNTIME=' "$LFX/sessions.d/$id1.conf")" "0"

# R3. A RUNTIME THE ACTIVATION CANNOT SERVE IS REFUSED BEFORE ANY WRITE.
# opencode rows need MODEL/PORT/VERSION the request does not carry, and an
# unknown word would fail the registry's own gate on the first read — refusing
# here names the cause at the sender instead of at every later reader.
before="$(ls "$LFX/sessions.d" | sort)"
lreq "$LFX/r3.txt" widgets "login=acme-team
runtime=opencode
"
out="$(run_lreq "$LFX/r3.txt")"; rc=$?
is "R3: runtime=opencode refuses, rc 65" "$rc" "65"
has "R3: the refusal names the field and the accepted value" "$out" "runtime"
has "R3: the refusal names codex as the accepted value" "$out" "codex"
is "R3: nothing was written" "$(ls "$LFX/sessions.d" | sort)" "$before"

# ── LOGIN_REQUIRED_FOR SCOPES THE WRITE-TIME REFUSAL TOO (task 9B, fix round
# 1, MAJOR-1) ────────────────────────────────────────────────────────────
# The read gate (lib/registry.sh, registry_load) refuses a row without LOGIN
# at schema 6 only when the row's principal is in LOGIN_REQUIRED_FOR (or the
# key is absent, which means every principal). Before this fix enroll's
# write-time refusal ignored the list and refused every principal — stricter
# than the reader, and on a scoped estate it blocked a registration the
# reader would have accepted. A SEPARATE fixture, schema 6, scoped to a
# single principal ("bob"): alice is outside the list and must register
# without login=; bob is inside it and must still be refused.
GFX="$(mktemp -d)"
mkdir -p "$GFX/estate" "$GFX/sessions.d" "$GFX/bus/bin" "$GFX/bin" \
  "$GFX/accounts.d" "$GFX/entities.d" "$GFX/projects.d" "$GFX/logins.d"
chmod 700 "$GFX/logins.d"
# THE FULL ESTATE KEY SET (not the trimmed one the other fixtures in this
# file use) — G1 below loads its produced row back through registry_load,
# which refuses on any of these being missing, unlike enroll itself.
cat > "$GFX/estate/steward.conf" <<'CONF'
ESTATE_NAME="prov"
SCHEMA_VERSION="6"
LABEL_PREFIX="com.prov.claude"
RC_LABEL_PREFIX="Hub: "
HUB_SESSION="hub"
HUB_HOST="hubhost"
HUB_SSH="alice@hubhost"
JOB_LOG_DIR="prov-jobs"
TMUX_SOCKET="prov.sock"
PING_MSG="you have mail"
STATE_DIR_NAME="prov-supervisor"
PAUSED_DIR_NAME="prov-paused"
JOB_LABEL_PREFIX="com.prov.job"
SERVICE_LABEL_PREFIX="com.prov.service"
BROWSER_LABEL_PREFIX="com.prov.browser"
OP_TOKEN_FILE_NAME="prov-token"
LOGIN_REQUIRED_FOR="bob"
CONF
cat > "$GFX/sessions.d/asker-alice.conf" <<'CONF'
HOST="farhost"
OWNER="alice"
DOMAIN="d"
RC_LABEL="Asker"
REPO_PATH="/tmp/x"
ID="asker-alice"
CONF
cat > "$GFX/sessions.d/asker-bob.conf" <<'CONF'
HOST="farhost"
OWNER="bob"
DOMAIN="d"
RC_LABEL="Asker"
REPO_PATH="/tmp/x"
ID="asker-bob"
CONF
cat > "$GFX/entities.d/acme.conf" <<'CONF'
NAME="Acme"
CONF
cat > "$GFX/accounts.d/alice-farhost.conf" <<'CONF'
PRINCIPAL="alice"
HOST="farhost"
CONF
cat > "$GFX/accounts.d/bob-farhost.conf" <<'CONF'
PRINCIPAL="bob"
HOST="farhost"
CONF
printf '#!/bin/bash\n' > "$GFX/bus/bin/bus-relay-in"; chmod +x "$GFX/bus/bin/bus-relay-in"
printf '#!/bin/bash\nexit 0\n' > "$GFX/bin/send"; chmod +x "$GFX/bin/send"
: > "$GFX/authorized_keys"

run_greq() { # <request-file> <from>
  STEWARD_ESTATE_ROOT="$GFX" STEWARD_REGISTRY_DIR="$GFX/sessions.d" \
  STEWARD_RELAY_ROOT="$GFX" STEWARD_AUTHORIZED_KEYS="$GFX/authorized_keys" \
  STEWARD_BUS_SEND="$GFX/bin/send" STEWARD_REGISTRY_LIB="$here/lib/registry.sh" STEWARD_ENROLL_FROM="$2" \
  bash "$ENROLL" --send < "$1" 2>&1
}

# G1. alice is NOT in LOGIN_REQUIRED_FOR — a request with no login= must
# register, rc 0, WITHOUT a LOGIN line, and the row must LOAD.
cat > "$GFX/g1.txt" <<'REQ'
DRIFT enroll: acme-widgetg-alice requests registration
ENROLL-REQUEST v1
namn=acme-widgetg-alice
doman=acme
projekt=widgetg
person=alice
vard=farhost
repo=/srv/homes/alice/Projects/widgetg
pubkey=ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIFAKEKEYGFXAAAAAAAAAAAAAAAAAAAAAAAA test-only
REQ
out="$(run_greq "$GFX/g1.txt" asker-alice)"; rc=$?
is "G1: LOGIN_REQUIRED_FOR scopes the refusal — a principal outside the list registers without login=, rc 0" "$rc" "0"
id_g1="$(printf '%s' "$out" | sed -n 's/.*registered as \(s-[0-9a-f]\{16\}\).*/\1/p' | head -1)"
conf_g1="$GFX/sessions.d/$id_g1.conf"
is "G1: no LOGIN line was written" "$(printf '%s' "$(cat "$conf_g1" 2>/dev/null)" | grep -c '^LOGIN=')" "0"
( STEWARD_CONFIG_FILE="$GFX/no-such-config"
  # shellcheck source=/dev/null
  . "$here/lib/registry.sh"
  STEWARD_ESTATE_ROOT="$GFX" registry_load "$id_g1" >/dev/null 2>&1 ) \
  && ok "G1: the row loads (registry_load rc 0)" \
  || bad "G1: the row loads (registry_load rc 0)"

# G2. bob IS in LOGIN_REQUIRED_FOR — the same estate, no login= — must
# refuse exactly as the read gate would, rc 65, nothing written.
before="$(ls "$GFX/sessions.d" | sort)"
cat > "$GFX/g2.txt" <<'REQ'
DRIFT enroll: acme-widgeth-bob requests registration
ENROLL-REQUEST v1
namn=acme-widgeth-bob
doman=acme
projekt=widgeth
person=bob
vard=farhost
repo=/srv/homes/bob/Projects/widgeth
pubkey=ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIFAKEKEYGFXBBBBBBBBBBBBBBBBBBBBBBBB test-only
REQ
out="$(run_greq "$GFX/g2.txt" asker-bob)"; rc=$?
is "G2: LOGIN_REQUIRED_FOR scopes the refusal — a listed principal still refuses, rc 65" "$rc" "65"
after="$(ls "$GFX/sessions.d" | sort)"
is "G2: nothing was written" "$after" "$before"

# ── OWNER IS A LOGIN, AND THE HUB IS A WRITER ───────────────────────────────
# THE FINDING. enroll resolved the account by (PRINCIPAL, HOST) and then wrote
# OWNER=<principal>. On every estate that spells USERNAME and PRINCIPAL the
# same that is the same string, which is why it went unseen; on the estates the
# account model exists for, the hub minted by hand exactly the row shape its
# own strict writer refuses.
#
# WRITER AND READER MEET IN ONE TEST. Asserting the text of the line enroll
# emits would only re-state the writer to itself; the row is read BACK through
# registry_load, and the strict rule (OWNER is the account's USERNAME) is
# checked against the account register rather than against a literal.
echo
echo "nav-enroll — OWNER is the unix login, not the principal"
UFX="$(mktemp -d)"
mkdir -p "$UFX/estate" "$UFX/sessions.d" "$UFX/bus/bin" "$UFX/bin" \
  "$UFX/accounts.d" "$UFX/entities.d" "$UFX/projects.d"
cat > "$UFX/estate/steward.conf" <<'CONF'
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
cat > "$UFX/entities.d/acme.conf" <<'CONF'
NAME="Acme"
CONF
# THE ONE ACCOUNT SHAPE THAT SEPARATES THE TWO NAMES: a human called 'ann'
# whose work runs under a service login.
cat > "$UFX/accounts.d/ann-farhost.conf" <<'CONF'
PRINCIPAL="ann"
USERNAME="svc-ann"
HOST="farhost"
CONF
# THE REQUESTER IS ITSELF IN THE NEW SHAPE - OWNER is the login, and the row
# names the account. The owner check reads person= as a principal, so a
# requester that states its login must still be able to enrol.
cat > "$UFX/sessions.d/asker.conf" <<'CONF'
HOST="farhost"
OWNER="svc-ann"
ACCOUNT="ann-farhost"
DOMAIN="acme"
RC_LABEL="Asker"
REPO_PATH="/tmp/x"
ID="asker"
CONF
printf '#!/bin/bash\n' > "$UFX/bus/bin/bus-relay-in"; chmod +x "$UFX/bus/bin/bus-relay-in"
# THE STUB RECORDS THE CONFIRM. The other fixtures' send stubs only exit 0,
# which is enough to prove a send happened and nothing about what it said - and
# the mate list travels in the confirm, not on stdout.
cat > "$UFX/bin/send" <<'SEND'
#!/bin/bash
# The text arrives on STDIN, the recipient as $1 - the shape enroll pipes into.
cat >> "$UFX_SEND_LOG"
exit 0
SEND
chmod +x "$UFX/bin/send"
: > "$UFX/authorized_keys"
cat > "$UFX/u1.txt" <<'REQ'
DRIFT enroll: acme-widgetu-ann requests registration
ENROLL-REQUEST v1
namn=acme-widgetu-ann
doman=acme
projekt=widgetu
person=ann
vard=farhost
repo=/srv/homes/ann/Projects/widgetu
rc_label=Case widgetu
pubkey=ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIFAKEKEYUFXAAAAAAAAAAAAAAAAAAAAAAAA test-only
REQ
uout="$( STEWARD_ESTATE_ROOT="$UFX" STEWARD_REGISTRY_DIR="$UFX/sessions.d" \
         STEWARD_RELAY_ROOT="$UFX" STEWARD_AUTHORIZED_KEYS="$UFX/authorized_keys" \
         STEWARD_BUS_SEND="$UFX/bin/send" UFX_SEND_LOG="$UFX/sent.log" STEWARD_REGISTRY_LIB="$here/lib/registry.sh" STEWARD_ENROLL_FROM=asker \
         bash "$ENROLL" --send < "$UFX/u1.txt" 2>&1 )"; urc=$?
is "U1: a new-shape requester enrols, rc 0" "$urc" "0"
uid="$(printf '%s' "$uout" | sed -n 's/.*registered as \(s-[0-9a-f]\{16\}\).*/\1/p' | head -1)"
ubody="$(cat "$UFX/sessions.d/$uid.conf" 2>/dev/null)"
has "U1: OWNER is the account's USERNAME"       "$ubody" 'OWNER="svc-ann"'
is  "U1: and never the principal" \
    "$(printf '%s' "$ubody" | grep -c '^OWNER="ann"$')" "0"
has "U1: ACCOUNT names the row that was matched" "$ubody" 'ACCOUNT="ann-farhost"'

# READ BACK THROUGH THE LOADER, AND MEASURED AGAINST THE ACCOUNT REGISTER.
uread="$( export STEWARD_ESTATE_ROOT="$UFX" STEWARD_REGISTRY_DIR="$UFX/sessions.d"
  . "$here/lib/registry.sh"
  registry_load "$uid" >/dev/null 2>&1 || exit $?
  _o="$OWNER"; _h="$HOST"; _a="$ACCOUNT"; _p="${ROW_PRINCIPAL:-}"
  registry_account_load "$_a" >/dev/null 2>&1 || exit 78
  # THE STRICT RULE, spelled out: a row in the shape the writers emit today
  # names the USERNAME of the account and the HOST of the account.
  #
  # NO APOSTROPHES IN THIS COMMENT. It sits inside a command substitution, and
  # bash 3.2 scans one for its closing parenthesis without understanding the
  # shell inside it - so an apostrophe here opens a quote that never closes,
  # the rest of the file is swallowed, and the suite exits rc 2 with no
  # pass/fail line at all. The same rule, measured the same way, is written
  # down in lib/registry.sh:723-731 and :779-780.
  [ "$ACCOUNT_USERNAME" = "$_o" ] || exit 65
  [ "$ACCOUNT_HOST" = "$_h" ] || exit 65
  printf '%s' "$_p" )"; urrc=$?
is "U1: the written row loads and satisfies the STRICT writer rule" "$urrc" "0"
is "U1: and it resolves to the human the account names" "$uread" "ann"

# U2. THE MATES READ-BACK: THE STATUS AND THE SENTENCE ARE BOTH KEPT.
# The call used to be `2>/dev/null || PROJECT_MATES=unknown`, which threw away
# the registry's own cause AND flattened every failure into one word. A row on
# the same entity whose ACCOUNT does not load stops the mates enumeration with
# rc 78 - somebody ELSE's fault, in another home. The new row this run wrote
# reads, so the enrolment stands and the confirm says the list is incomplete;
# refusing here would punish a requester for a conf it cannot see.
cat > "$UFX/sessions.d/mate-broken.conf" <<'CONF'
HOST="farhost"
OWNER="ben"
ACCOUNT="missing-account"
DOMAIN="acme"
TARGET_ENTITY="acme"
RC_LABEL="Broken"
REPO_PATH="/tmp/x"
ID="mate-broken"
CONF
sed 's/widgetu/widgetv/g; s/UFXAAAAAAAAAAAAAAAAAAAAAAAA/UFXBBBBBBBBBBBBBBBBBBBBBBBB/' \
  "$UFX/u1.txt" > "$UFX/u2.txt"
u2out="$( STEWARD_ESTATE_ROOT="$UFX" STEWARD_REGISTRY_DIR="$UFX/sessions.d" \
          STEWARD_RELAY_ROOT="$UFX" STEWARD_AUTHORIZED_KEYS="$UFX/authorized_keys" \
          STEWARD_BUS_SEND="$UFX/bin/send" UFX_SEND_LOG="$UFX/sent.log" STEWARD_REGISTRY_LIB="$here/lib/registry.sh" STEWARD_ENROLL_FROM=asker \
          bash "$ENROLL" --send < "$UFX/u2.txt" 2>&1 )"; u2rc=$?
is  "U2: a colleague's refused identity does not refuse the enrolment" "$u2rc" "0"
has "U2: the code is named"                    "$u2out" "rc 78"
has "U2: as a degradation, not a refusal"      "$u2out" "nav-enroll: DEGRADED"
has "U2: and the registry's own cause survives the read-back" "$u2out" "missing-account"
has "U2: the confirm says the mate list is incomplete" \
    "$(cat "$UFX/sent.log" 2>/dev/null)" "project-mates=unknown"

# U3-U5. THE OWNER CHECK AND THE REGISTER MUST AGREE ON WHAT THE ROW SAYS, AND
# ON WHOSE ROW IT IS. Three shapes, one gate.
# THE OUTPUT AND THE STATUS BOTH LAND IN GLOBALS. A helper whose result is read
# through a command substitution runs in a subshell, and the status it recorded
# there never reaches the caller - which is how the first draft of these three
# cases reported rc 0 for a refusal it had just printed.
urun() { # <from-key> <request-file> -> UOUT, URC
  UOUT="$( STEWARD_ESTATE_ROOT="$UFX" STEWARD_REGISTRY_DIR="$UFX/sessions.d" \
           STEWARD_RELAY_ROOT="$UFX" STEWARD_AUTHORIZED_KEYS="$UFX/authorized_keys" \
           STEWARD_BUS_SEND="$UFX/bin/send" UFX_SEND_LOG="$UFX/sent.log" \
           STEWARD_REGISTRY_LIB="$here/lib/registry.sh" STEWARD_ENROLL_FROM="$1" \
           bash "$ENROLL" --send < "$2" 2>&1 )"; URC=$?
}
# THE LABEL IS REWRITTEN WITH THE REST. Two of these cases enrol a SECOND row
# into svc-ann's home (U1 already took one), and since 2026-09-09 a home holds
# one row per label - see case D. The label follows the case, so what decides
# each outcome is the gate the case is about.
ureq() { # <name-suffix> <person> <key-suffix> -> a request file, path in UREQ
  UREQ="$UFX/req-$1.txt"
  sed "s/^namn=.*/namn=acme-widget$1-$2/; s/^projekt=.*/projekt=widget$1/; \
       s/^person=.*/person=$2/; s/^rc_label=.*/rc_label=Case widget$1 $2/; \
       s/UFXAAAAAAAAAAAAAAAAAAAAAAAA/UFX$3/" \
      "$UFX/u1.txt" > "$UREQ"
}

# U3. TWO OWNER LINES. A sourced conf is owned by the LAST one; the sed grammar
# this gate used took the FIRST. The row below belongs to svc-ann everywhere a
# reader looks, and a request from ben used to walk straight through.
cat > "$UFX/sessions.d/twoline.conf" <<'CONF'
HOST="farhost"
OWNER="ben"
OWNER="svc-ann"
ACCOUNT="ann-farhost"
DOMAIN="acme"
RC_LABEL="Two"
REPO_PATH="/tmp/x"
ID="twoline"
CONF
ureq w3 ben CCCCCCCCCCCCCCCCCCCCCCCCCC
urun twoline "$UREQ"
is  "U3: the first of two OWNER lines does not own the row" "$URC" "65"
has "U3: and the refusal quotes the owner the loader would read" "$UOUT" "owned by 'svc-ann'"

# U4. LEADING WHITESPACE. A sourced conf accepts it; the anchored sed did not,
# so the legitimate owner of this row could not enrol at all.
printf 'HOST="farhost"\n  OWNER="svc-ann"\nACCOUNT="ann-farhost"\nDOMAIN="acme"\nRC_LABEL="Sp"\nREPO_PATH="/tmp/x"\nID="spaced"\n' \
  > "$UFX/sessions.d/spaced.conf"
ureq w4 ann DDDDDDDDDDDDDDDDDDDDDDDDDD
urun spaced "$UREQ"
is "U4: an indented OWNER line still owns the row" "$URC" "0"

# U5. THE LENIENT SHAPE, REFUSED. This row carries the account's PRINCIPAL as
# its OWNER - legible to the loader, and the shape mcp assets already withhold
# the account axis for, because a principal id and a unix login are two
# namespaces nothing keeps disjoint. Enrolment STAMPS a row under the account
# it resolves, so a row it cannot measure through its own account does not
# enrol at all; the refusal names the verb that ends the ambiguity.
cat > "$UFX/sessions.d/legacyowner.conf" <<'CONF'
HOST="farhost"
OWNER="ann"
ACCOUNT="ann-farhost"
DOMAIN="acme"
RC_LABEL="Legacy"
REPO_PATH="/tmp/x"
ID="legacyowner"
CONF
ureq w5 zoe EEEEEEEEEEEEEEEEEEEEEEEEEE
urun legacyowner "$UREQ"
is  "U5: a row its own account names only by PRINCIPAL is refused" "$URC" "65"
has "U5: and the refusal quotes the OWNER the loader reads"  "$UOUT" "OWNER='ann'"
has "U5: and the USERNAME the account actually names"        "$UOUT" "svc-ann"
has "U5: and points at the verb that ends the ambiguity"     "$UOUT" "registry session realign"
has "U5: and says which of the two names the OWNER actually is" "$UOUT" "names as its PRINCIPAL and not as its USERNAME"

# U5b. THE SAME GATE, THE OTHER SHAPE. OWNER here is neither the account's
# PRINCIPAL nor its USERNAME - a row pointed at an account that is not its own
# - and the sentence used to tell this reader that their OWNER was the
# account's principal. It was not, so the stated cause was wrong and the verb
# it recommends cannot fix the row. The branch names both fields instead.
cat > "$UFX/sessions.d/neitherowner.conf" <<'CONF'
HOST="farhost"
OWNER="zed"
ACCOUNT="ann-farhost"
DOMAIN="acme"
RC_LABEL="Neither"
REPO_PATH="/tmp/x"
ID="neitherowner"
CONF
ureq w5b zed FFFFFFFFFFFFFFFFFFFFFFFFFF
urun neitherowner "$UREQ"
is  "U5b: a row whose OWNER is neither field is refused" "$URC" "65"
has "U5b: and the refusal names the account's PRINCIPAL" "$UOUT" "neither as its PRINCIPAL='ann'"
has "U5b: and the account's USERNAME"                    "$UOUT" "nor as its USERNAME='svc-ann'"
case "$UOUT" in
  *"names as its PRINCIPAL and not"*)
    bad "U5b: and never claims the OWNER is the account's principal" "$UOUT" ;;
  *) ok "U5b: and never claims the OWNER is the account's principal" ;;
esac

# U6. THE COLLISION, WHOLE. Account A is PRINCIPAL="ann" USERNAME="svc-ann";
# account B is PRINCIPAL="bob" USERNAME="ann". The row above is A's row - it
# names A as its ACCOUNT - while OWNER="ann" is B's unix login, so it runs as
# bob and claims ann. A request naming person=ann satisfied the raw
# OWNER-equals-person arm and stamped a new session for ann out of bob's
# session. The two namespaces are not required to be disjoint and nothing in
# the string tells them apart, so the account decides or nothing does.
cat > "$UFX/accounts.d/bob-farhost.conf" <<'CONF'
PRINCIPAL="bob"
USERNAME="ann"
HOST="farhost"
CONF
ureq w6 ann FFFFFFFFFFFFFFFFFFFFFFFFFF
urun legacyowner "$UREQ"
is  "U6: the raw OWNER string no longer admits a row that carries an ACCOUNT" "$URC" "65"
has "U6: and the refusal is the account one, not a person mismatch" \
    "$UOUT" "registry session realign"

# U7. THE LEGACY ROW THAT STILL ENROLS. No ACCOUNT line at all, so there is
# nothing to resolve through and OWNER is the only human this row can name.
# Refusing these would take down every conf written before the identity model,
# which is the fault the loader's lenient read exists to avoid.
printf 'HOST="farhost"\nOWNER="ann"\nDOMAIN="acme"\nRC_LABEL="NoAcct"\nREPO_PATH="/tmp/x"\nID="noacct"\n' \
  > "$UFX/sessions.d/noacct.conf"
ureq w7 ann GGGGGGGGGGGGGGGGGGGGGGGGGG
urun noacct "$UREQ"
is "U7: an account-less legacy row still enrols on its raw OWNER" "$URC" "0"

# U8-U9. THE ACCOUNT LINK IS (USERNAME, HOST), NOT USERNAME ALONE. An
# accounts.d row is a (principal, host) pair - that is what the resolution loop
# further down matches on - so linking a session row to one on USERNAME alone
# asks half the question. A unix login is unique within a machine and nothing
# more: two hosts may both have an 'ann', and they need not be the same person.
#
# Both accounts below name principal 'carl' with USERNAME 'ann'; one lives on
# the host the requesting row runs on and one does not. The row names the one
# that does not.
cat > "$UFX/accounts.d/carl-farhost.conf" <<'CONF'
PRINCIPAL="carl"
USERNAME="svc-carl"
HOST="farhost"
CONF
cat > "$UFX/accounts.d/carl-otherhost.conf" <<'CONF'
PRINCIPAL="carl"
USERNAME="ann"
HOST="otherhost"
CONF
cat > "$UFX/sessions.d/crosshost.conf" <<'CONF'
HOST="farhost"
OWNER="ann"
ACCOUNT="carl-otherhost"
DOMAIN="acme"
RC_LABEL="Cross"
REPO_PATH="/tmp/x"
ID="crosshost"
CONF
ureq w8 carl HHHHHHHHHHHHHHHHHHHHHHHHHH
urun crosshost "$UREQ"
is  "U8: an account on another host no longer admits a row on this one" "$URC" "65"
has "U8: and the refusal names the host the row runs on"  "$UOUT" "runs on host 'farhost'"
has "U8: and the host the account lives on"               "$UOUT" "lives on 'otherhost'"

# U9. THE SAME ACCOUNT ON THE RIGHT HOST STILL ENROLS. Without this the gate
# above is indistinguishable from one that refuses every row carrying an
# ACCOUNT, and a refusal that never lets anything through is not a gate.
cat > "$UFX/accounts.d/carl-otherhost.conf" <<'CONF'
PRINCIPAL="carl"
USERNAME="ann"
HOST="farhost"
CONF
rm -f "$UFX/accounts.d/carl-farhost.conf"
ureq w9 carl IIIIIIIIIIIIIIIIIIIIIIIIII
urun crosshost "$UREQ"
is "U9: the same account on the row's own host enrols" "$URC" "0"

# U10. THE ACCOUNT ID IS A NAME, AND A NAME IS NOT A PATH. registry_account_load
# builds "<accounts.d>/<slug>.conf" and sources it, and this gate reads
# F_ACCOUNT straight out of the requester's conf without the loader's grammar.
# The conf below is placed one directory OUTSIDE accounts.d and named by a
# relative ACCOUNT: before the check it loaded, satisfied the owner gate, and
# the request enrolled. The rows this hub writes are shape-checked by the
# loader that reads them back, so no live session reaches this - it is one
# hand-edited conf away.
cat > "$UFX/outside.conf" <<'CONF'
PRINCIPAL="ann"
USERNAME="ann"
HOST="farhost"
CONF
cat > "$UFX/sessions.d/escaped.conf" <<'CONF'
HOST="farhost"
OWNER="ann"
ACCOUNT="../outside"
DOMAIN="acme"
RC_LABEL="Escaped"
REPO_PATH="/tmp/x"
ID="escaped"
CONF
ureq wa ann JJJJJJJJJJJJJJJJJJJJJJJJJJ
urun escaped "$UREQ"
is  "U10: a path-shaped ACCOUNT is refused before anything is sourced" "$URC" "65"
has "U10: and the refusal names the grammar, not a read failure" "$UOUT" "not an account id"
case "$UOUT" in
  *"this hub cannot read it"*) bad "U10: the shape is measured before the load" "$UOUT" ;;
  *)                           ok  "U10: the shape is measured before the load" ;;
esac
rm -rf "$UFX"

# ── THE TWO SIDES, PINNED TOGETHER ──────────────────────────────────────────
#
# THE GAP, measured on a live host 2026-09-09. Everything above measures what
# enroll accepts against a request this file writes by hand. The requester
# writes its own, and the two drifted: session-new put `id -un` in person=
# while this file's owner check reads that field as a PRINCIPAL. On an account
# whose login is a role ("steward") rather than a person's name the enrolment
# was refused two machines from where the mistake was made, naming a value the
# operator never typed.
#
# A comment on either side would not have caught it, because a comment is not
# run. So the request is not written here at all: session-new BUILDS it, and
# enroll is handed exactly what came off that wire. Whichever side moves next,
# this case is the one that goes red.
echo "session-new and enroll — one request, both sides"

XFX="$FX/crosspin"
mkdir -p "$XFX/sessions.d" "$XFX/ssh" "$XFX/state" "$XFX/repo/.git"

XUU="$(id -un)"
XPRIN="chief"; [ "$XPRIN" = "$XUU" ] && XPRIN="chieftain"

# THE ACCOUNT THE STORY IS ABOUT: a person named by PRINCIPAL, running under a
# unix login named for the ROLE. The estate's other account row (someone) is
# left in place — the resolution must pick this one, not merely the only one.
cat > "$FX/accounts.d/chief-farhost.conf" <<CONF
PRINCIPAL="$XPRIN"
HOST="farhost"
USERNAME="$XUU"
CONF

# THE REQUESTING SESSION, in BOTH registers: the requester reads DOMAIN and HOST
# off its own copy, the hub reads OWNER and ACCOUNT off its own. Two machines,
# two registers, one row.
xrow() { cat > "$1" <<CONF
ID="asker-chief"
HOST="farhost"
OWNER="$XUU"
ACCOUNT="chief-farhost"
DOMAIN="acme"
RC_LABEL="Hub: asker-chief"
REPO_PATH="/srv/homes/$XUU/Projects/asker"
CONF
}
xrow "$FX/reg/asker-chief.conf"
xrow "$XFX/sessions.d/asker-chief.conf"

# Stubs: tmux answers the pane's session name, ssh-keygen writes a key that is
# not real and not the one the hand-written request above already registered,
# and the bus client keeps the request instead of sending it.
cat > "$FX/bin/tmux" <<EOF
#!/bin/bash
if [ "\$1" = "display-message" ]; then printf '%s\n' "\${FAKE_TMUX_SESSION:-}"; fi
exit 0
EOF
cat > "$FX/bin/ssh-keygen" <<'EOF'
#!/bin/bash
f=""
while [ $# -gt 0 ]; do
  case "$1" in -f) f="${2:-}"; shift 2 ;; *) shift ;; esac
done
[ -n "$f" ] || exit 1
: > "$f"
printf 'ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAICROSSPINFIXTUREKEYNOTREALxxxxxxxxxx crosspin\n' > "$f.pub"
EOF
cat > "$XFX/bus-send" <<EOF
#!/bin/bash
cat > "$XFX/sent.txt"
EOF
chmod +x "$FX/bin/tmux" "$FX/bin/ssh-keygen" "$XFX/bus-send"

xout="$( PATH="$FX/bin:$PATH" HOME="$XFX" \
         TMUX_PANE="%0" FAKE_TMUX_SESSION="asker-chief" \
         STEWARD_ESTATE_ROOT="$FX" STEWARD_SESSIONS_D="$XFX/sessions.d" \
         STEWARD_REGISTRY_LIB="$here/lib/registry.sh" \
         STEWARD_SSH_DIR="$XFX/ssh" STEWARD_ENROLL_STATE_DIR="$XFX/state" \
         STEWARD_BUS_SEND="$XFX/bus-send" \
         bash "$here/linux/session-new.sh" widget "$XFX/repo" 2>&1 )"
xrc=$?
is "the requester builds a request, rc 0" "$xrc" "0"
xreq="$(cat "$XFX/sent.txt" 2>/dev/null)"
has "the request it built names the principal" "$xreq" "person=$XPRIN"

# AND NOW THE HUB, fed exactly those bytes.
xhub="$( STEWARD_ESTATE_ROOT="$FX" \
         STEWARD_REGISTRY_DIR="$FX/reg" \
         STEWARD_RELAY_ROOT="$FX" \
         STEWARD_AUTHORIZED_KEYS="$FX/authorized_keys" \
         STEWARD_BUS_SEND="$FX/bin/send" \
         STEWARD_REGISTRY_LIB="$here/lib/registry.sh" STEWARD_ENROLL_FROM=asker-chief \
         bash "$ENROLL" --send < "$XFX/sent.txt" 2>&1 )"
xhrc=$?
if [ "$xhrc" -eq 0 ]; then ok "enroll accepts the request the requester built"
else bad "enroll accepts the request the requester built" "rc=$xhrc out=$xhub"; fi
xid="$(printf '%s' "$xhub" | sed -n 's/.*registered as \(s-[0-9a-f]\{16\}\).*/\1/p' | head -1)"
xbody="$(cat "$FX/reg/$xid.conf" 2>/dev/null)"
has "the row is stamped under the account that resolved" "$xbody" 'ACCOUNT="chief-farhost"'
# OWNER IS THE LOGIN, on both sides of the wire: the requester's own reservation
# and the row the hub stamps say the same thing, and it is not the principal.
has "the row the hub stamps owns it by the unix login" "$xbody" "OWNER=\"$XUU\""
has "the requester's own reservation agrees" \
    "$(cat "$XFX/sessions.d/acme-widget-$XPRIN.conf" 2>/dev/null)" "OWNER=\"$XUU\""

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
