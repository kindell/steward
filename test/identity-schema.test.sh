#!/bin/bash
# test/identity-schema.test.sh — the five additive fields the identity model
# rests on: ESTATE_NAME, SCHEMA_VERSION, ID, KIND, LIFECYCLE.
#
# WHY THEY ARE ADDITIVE. Five live conversations run on the hub while this
# lands. A field that changes what gets rendered would end them; a field that is
# only read by validation cannot. The rendered-plist gate is the proof, and it
# is a step in every task, not a hope.
set -u

here="$(CDPATH= cd -- "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
pass=0; fail=0
ok()  { pass=$((pass+1)); printf '  ok   %s\n' "$1"; }
bad() { fail=$((fail+1)); printf '  FAIL %s\n     %s\n' "$1" "${2:-}"; }

FX="$(mktemp -d)"; trap 'rm -rf "$FX"' EXIT
mkdir -p "$FX/estate" "$FX/sessions.d"

estate() { printf '%s\n' "$@" > "$FX/estate/steward.conf"; }
lade() { # run a registry function against the fixture estate
  ( export STEWARD_ESTATE_ROOT="$FX"
    # shellcheck source=/dev/null
    . "$here/lib/registry.sh"
    "$@" )
}

echo "ESTATE_NAME — the estate is named, never guessed"

# THE NAME IS REQUIRED. A missing name must refuse, not fall back on the hub
# session or the label prefix: those coincide in one estate and diverge in the
# next, and a default that is right once teaches nobody it can be wrong.
estate 'LABEL_PREFIX="com.example.claude"'
out="$(lade registry_estate_name 2>&1)"; rc=$?
[ "$rc" -eq 78 ] && ok "a missing ESTATE_NAME refuses with rc 78" \
                 || bad "a missing ESTATE_NAME refuses with rc 78" "rc=$rc: $out"
case "$out" in *ESTATE_NAME*) ok "the refusal names the key" ;;
  *) bad "the refusal names the key" "$out" ;; esac

# CONTROL GROUP: a valid name is returned verbatim.
estate 'LABEL_PREFIX="com.example.claude"' 'ESTATE_NAME="acme"'
out="$(lade registry_estate_name 2>&1)"; rc=$?
[ "$rc" -eq 0 ] && [ "$out" = "acme" ] && ok "a valid name is printed" \
                || bad "a valid name is printed" "rc=$rc, got '$out'"

# THE FORM IS THE GUARD. The name becomes part of derived session names, so a
# slash, a space or a glob character would let a typo name something outside its
# own namespace — the same failure LABEL_PREFIX is guarded against.
for bad_name in 'a b' 'a/b' 'a*' '' 'Ab'; do
  estate 'LABEL_PREFIX="com.example.claude"' "ESTATE_NAME=\"$bad_name\""
  lade registry_estate_name >/dev/null 2>&1
  [ "$?" -ne 0 ] && ok "refuses the malformed name '$bad_name'" \
                 || bad "refuses the malformed name '$bad_name'" "it was accepted"
done

echo "SCHEMA_VERSION — an old checkout refuses a newer estate"

# A CHECKOUT THAT IS BEHIND MUST SAY SO. Without the check it reads a register
# carrying fields it does not know, treats them as absent, and acts on a
# half-understood truth. That is the same confusion between "empty" and
# "unreadable" the whole library is built against, one level up.
estate 'LABEL_PREFIX="com.example.claude"' 'ESTATE_NAME="acme"' 'SCHEMA_VERSION="999"'
out="$(lade registry_schema_check 2>&1)"; rc=$?
[ "$rc" -eq 78 ] && ok "a newer schema refuses with rc 78" \
                 || bad "a newer schema refuses with rc 78" "rc=$rc: $out"
case "$out" in *999*) ok "the refusal names both versions" ;;
  *) bad "the refusal names both versions" "$out" ;; esac

# THE BOUNDARY THE LIVE FLEET STANDS ON. Read REGISTRY_SCHEMA_MAX out of the
# library itself rather than hardcoding a number here — a hardcoded "2" once
# stood for "the version this checkout was written for", stayed true only
# until the max was next raised to 3, and from then on covered NOTHING: the
# live fleet's actual boundary (estate schema == REGISTRY_SCHEMA_MAX) went
# untested while every assertion still read green. Mutating registry_schema_check's
# `-gt` to `-ge` proved it: pass=53 fail=0 here, rc=78 for every session on
# the real estate.
max="$( ( . "$here/lib/registry.sh"; printf '%s' "$REGISTRY_SCHEMA_MAX" ) )"

# CONTROL GROUP: exactly at the maximum this checkout understands, the load
# succeeds — this IS the boundary the live fleet stands on today.
estate 'LABEL_PREFIX="com.example.claude"' 'ESTATE_NAME="acme"' "SCHEMA_VERSION=\"$max\""
lade registry_schema_check >/dev/null 2>&1
[ "$?" -eq 0 ] && ok "a schema exactly at REGISTRY_SCHEMA_MAX passes" \
               || bad "a schema exactly at REGISTRY_SCHEMA_MAX passes" "it refused"

# ONE STEP OVER THE BOUNDARY: refuses with 78. Together with the assertion
# above, this pins the exact edge instead of a value that will drift the next
# time REGISTRY_SCHEMA_MAX is raised.
estate 'LABEL_PREFIX="com.example.claude"' 'ESTATE_NAME="acme"' "SCHEMA_VERSION=\"$((max + 1))\""
out="$(lade registry_schema_check 2>&1)"; rc=$?
[ "$rc" -eq 78 ] && ok "one step over REGISTRY_SCHEMA_MAX refuses with 78" \
                 || bad "one step over REGISTRY_SCHEMA_MAX refuses with 78" "rc=$rc: $out"

# AN ABSENT VERSION IS VERSION 1, not an error. Every estate that exists today
# predates the key; refusing them would make the guard's first act an outage.
estate 'LABEL_PREFIX="com.example.claude"' 'ESTATE_NAME="acme"'
lade registry_schema_check >/dev/null 2>&1
[ "$?" -eq 0 ] && ok "an absent SCHEMA_VERSION reads as 1 and passes" \
               || bad "an absent SCHEMA_VERSION reads as 1 and passes" "it refused"

# A NON-NUMERIC VERSION IS NOT VERSION 1. Silently treating a typo as the
# oldest schema would let a malformed estate through the exact gate that exists
# to stop half-understood ones.
estate 'LABEL_PREFIX="com.example.claude"' 'ESTATE_NAME="acme"' 'SCHEMA_VERSION="two"'
lade registry_schema_check >/dev/null 2>&1
[ "$?" -ne 0 ] && ok "a malformed SCHEMA_VERSION refuses" \
               || bad "a malformed SCHEMA_VERSION refuses" "it was accepted as 1"

echo
echo "ID — the immutable key, separate from the display name"

konf() { printf '%s\n' "$@" > "$FX/sessions.d/$1.conf"; }
ladda() { # <session> -> load it against the fixture registry, print a field
  ( export STEWARD_ESTATE_ROOT="$FX" STEWARD_REGISTRY_DIR="$FX/sessions.d"
    # shellcheck source=/dev/null
    . "$here/lib/registry.sh"
    registry_load "$1" >/dev/null 2>&1 || exit 1
    printf '%s' "${!2}" )
}
estate 'LABEL_PREFIX="com.example.claude"' 'ESTATE_NAME="acme"' 'SCHEMA_VERSION="2"' \
  'RC_LABEL_PREFIX="Steward: "' 'HUB_SESSION="hub"' 'HUB_HOST="hub"' 'JOB_LOG_DIR="jobs"' \
  'HUB_SSH="owner@hub"' 'TMUX_SOCKET="steward.sock"' 'PING_MSG="ping"' \
  'JOB_LABEL_PREFIX="com.example.job"' 'SERVICE_LABEL_PREFIX="com.example.service"' \
  'BROWSER_LABEL_PREFIX="com.example.browser"' 'OP_TOKEN_FILE_NAME="token"' \
  'STATE_DIR_NAME="adapter-state"' 'PAUSED_DIR_NAME="paused"'

# registry_schema_check IS THE FIRST LINE OF registry_load: any key it does not
# clear with `local` before its `source "$estate"` reaches every registry_load
# CALLER'S shell — every session on a live machine — not merely its own return
# value. AGENT_INSTRUCTIONS is used nowhere else in this library, so it can
# only appear in the caller's shell by leaking through this one `source`.
estate 'LABEL_PREFIX="com.example.claude"' 'ESTATE_NAME="acme"' 'SCHEMA_VERSION="2"' \
  'RC_LABEL_PREFIX="Steward: "' 'HUB_SESSION="hub"' 'HUB_HOST="hub"' 'JOB_LOG_DIR="jobs"' \
  'HUB_SSH="owner@hub"' 'TMUX_SOCKET="steward.sock"' 'PING_MSG="ping"' \
  'JOB_LABEL_PREFIX="com.example.job"' 'SERVICE_LABEL_PREFIX="com.example.service"' \
  'BROWSER_LABEL_PREFIX="com.example.browser"' 'OP_TOKEN_FILE_NAME="token"' \
  'STATE_DIR_NAME="adapter-state"' 'PAUSED_DIR_NAME="paused"' \
  'AGENT_INSTRUCTIONS="leaked-instructions"'
konf leaky 'REPO_PATH="/x"' 'RC_LABEL="Leaky"' 'OWNER="ada"' 'DOMAIN="d"'
out="$(
  export STEWARD_ESTATE_ROOT="$FX" STEWARD_REGISTRY_DIR="$FX/sessions.d"
  unset AGENT_INSTRUCTIONS
  # shellcheck source=/dev/null
  . "$here/lib/registry.sh"
  registry_load leaky >/dev/null 2>&1
  if [ -z "${AGENT_INSTRUCTIONS+x}" ]; then printf 'unset'; else printf 'set=%s' "$AGENT_INSTRUCTIONS"; fi
)"
[ "$out" = "unset" ] && ok "registry_load does not leak AGENT_INSTRUCTIONS into the caller's shell" \
  || bad "registry_load does not leak AGENT_INSTRUCTIONS into the caller's shell" "$out"

# CONTROL GROUP RESTORED: the estate that the rest of this section's ID/KIND/
# LIFECYCLE assertions rely on, without the leak probe's extra key.
estate 'LABEL_PREFIX="com.example.claude"' 'ESTATE_NAME="acme"' 'SCHEMA_VERSION="2"' \
  'RC_LABEL_PREFIX="Steward: "' 'HUB_SESSION="hub"' 'HUB_HOST="hub"' 'JOB_LOG_DIR="jobs"' \
  'HUB_SSH="owner@hub"' 'TMUX_SOCKET="steward.sock"' 'PING_MSG="ping"' \
  'JOB_LABEL_PREFIX="com.example.job"' 'SERVICE_LABEL_PREFIX="com.example.service"' \
  'BROWSER_LABEL_PREFIX="com.example.browser"' 'OP_TOKEN_FILE_NAME="token"' \
  'STATE_DIR_NAME="adapter-state"' 'PAUSED_DIR_NAME="paused"'

# AN EXPLICIT ID IS USED VERBATIM.
konf one 'REPO_PATH="/x"' 'RC_LABEL="One"' 'OWNER="ada"' 'DOMAIN="d"' 'ID="frozen-one"'
[ "$(ladda one ID)" = "frozen-one" ] && ok "an explicit ID is loaded" \
  || bad "an explicit ID is loaded" "got '$(ladda one ID)'"

# AN ABSENT ID FALLS BACK TO THE FILE NAME — and that is a MIGRATION, not a
# default to keep. Today's session name is already unique and already what
# everything keys on, so freezing it changes nothing and makes an existing
# truth explicit.
konf two 'REPO_PATH="/x"' 'RC_LABEL="Two"' 'OWNER="ada"' 'DOMAIN="d"'
[ "$(ladda two ID)" = "two" ] && ok "an absent ID falls back to the file name" \
  || bad "an absent ID falls back to the file name" "got '$(ladda two ID)'"

# THE ID IS NOT THE DISPLAY NAME. A conf may carry both, and they may differ —
# that is the entire point of the split, so a test that never sees them differ
# proves nothing.
konf three 'REPO_PATH="/x"' 'RC_LABEL="Renamed Yesterday"' 'OWNER="ada"' 'DOMAIN="d"' 'ID="three"'
[ "$(ladda three ID)" = "three" ] && [ "$(ladda three RC_LABEL)" = "Renamed Yesterday" ] \
  && ok "ID and display name are independent" \
  || bad "ID and display name are independent" "ID='$(ladda three ID)' label='$(ladda three RC_LABEL)'"

# THE FORM IS THE GUARD: an ID is keyed on, so it must never carry a path
# separator, whitespace or a glob character.
for bad_id in 'a b' 'a/b' 'a*' 'A'; do
  konf four 'REPO_PATH="/x"' 'RC_LABEL="Four"' 'OWNER="ada"' 'DOMAIN="d"' "ID=\"$bad_id\""
  ladda four ID >/dev/null 2>&1
  [ "$?" -ne 0 ] && ok "refuses the malformed ID '$bad_id'" \
                 || bad "refuses the malformed ID '$bad_id'" "it was accepted"
done

echo "KIND — work, infra or advisor, stated once"

# THE DEFAULT IS work BECAUSE THAT IS WHAT ALMOST EVERY SESSION IS. A default
# that covers the common case is not a guess; a default that covers the rare one
# would be.
konf plain 'REPO_PATH="/x"' 'RC_LABEL="Plain"' 'OWNER="ada"' 'DOMAIN="d"'
[ "$(ladda plain KIND)" = "work" ] && ok "an absent KIND reads as work" \
  || bad "an absent KIND reads as work" "got '$(ladda plain KIND)'"

for k in work infra advisor; do
  konf kk 'REPO_PATH="/x"' 'RC_LABEL="K"' 'OWNER="ada"' 'DOMAIN="d"' "KIND=\"$k\""
  [ "$(ladda kk KIND)" = "$k" ] && ok "KIND=$k is accepted" || bad "KIND=$k is accepted" "it was not"
done

# AN UNKNOWN KIND REFUSES. The set is closed on purpose: a typo that reads as a
# fourth kind would be treated as "not any of the three" by everything that
# branches on it, which is the silent half-behaviour this library refuses.
konf kk 'REPO_PATH="/x"' 'RC_LABEL="K"' 'OWNER="ada"' 'DOMAIN="d"' 'KIND="machine"'
ladda kk KIND >/dev/null 2>&1
[ "$?" -ne 0 ] && ok "an unknown KIND refuses" || bad "an unknown KIND refuses" "it was accepted"

# KIND IS INDEPENDENT OF RC-FREENESS. Being RC-free is how the bus tells a
# machine session apart TODAY — one fact in three encodings. KIND states it
# once, and the test proves the two are not the same axis by combining them
# against the grain.
konf rcfree 'REPO_PATH="/x"' 'RC_LABEL=""' 'OWNER="ada"' 'DOMAIN="d"' 'KIND="work"'
[ "$(ladda rcfree KIND)" = "work" ] && ok "an RC-free session may still be work" \
  || bad "an RC-free session may still be work" "got '$(ladda rcfree KIND)'"

echo "LIFECYCLE — retirement can be written down"

konf live 'REPO_PATH="/x"' 'RC_LABEL="Live"' 'OWNER="ada"' 'DOMAIN="d"'
[ "$(ladda live LIFECYCLE)" = "active" ] && ok "an absent LIFECYCLE reads as active" \
  || bad "an absent LIFECYCLE reads as active" "got '$(ladda live LIFECYCLE)'"

for l in active suspended retired; do
  konf ll 'REPO_PATH="/x"' 'RC_LABEL="L"' 'OWNER="ada"' 'DOMAIN="d"' "LIFECYCLE=\"$l\""
  [ "$(ladda ll LIFECYCLE)" = "$l" ] && ok "LIFECYCLE=$l is accepted" \
    || bad "LIFECYCLE=$l is accepted" "it was not"
done

konf ll 'REPO_PATH="/x"' 'RC_LABEL="L"' 'OWNER="ada"' 'DOMAIN="d"' 'LIFECYCLE="dead"'
ladda ll LIFECYCLE >/dev/null 2>&1
[ "$?" -ne 0 ] && ok "an unknown LIFECYCLE refuses" || bad "an unknown LIFECYCLE refuses" "accepted"

# A RETIRED SESSION STILL LOADS. This task records the fact and acts on nothing:
# refusing to load a retired conf would BE the behaviour change, and it would
# arrive without anyone choosing it. The test pins that boundary so a later plan
# has to move it deliberately.
konf gone 'REPO_PATH="/x"' 'RC_LABEL="Gone"' 'OWNER="ada"' 'DOMAIN="d"' 'LIFECYCLE="retired"'
[ "$(ladda gone LIFECYCLE)" = "retired" ] && ok "a retired session still loads (recorded, not enforced)" \
  || bad "a retired session still loads" "loading it failed"

echo "RESET — a polluted shell must never leak into a fresh load"

# THIS TEST GUARDS ONE LINE: the "Reset before sourcing" statement in
# registry_load that clears ID, KIND and LIFECYCLE before the conf is read.
# Every assertion above this one runs registry_load in ladda's own subshell,
# so that line's absence is invisible to them — there is nothing stray in the
# parent shell for it to leak from. Delete the reset line and every test above
# stays green; only a load that starts from an ALREADY-POLLUTED shell can
# catch it. Without this assertion, the next hand to touch registry.sh could
# drop that one line and nothing here would say so — a real session would
# then be able to inherit a stray ID, KIND or LIFECYCLE from whatever
# environment launched it.
konf clean 'REPO_PATH="/x"' 'RC_LABEL="Clean"' 'OWNER="ada"' 'DOMAIN="d"'
out="$(
  export STEWARD_ESTATE_ROOT="$FX" STEWARD_REGISTRY_DIR="$FX/sessions.d"
  # Pollute the shell registry_load is about to run in with values that would
  # each be REFUSED if they survived: ID="hijack" is well-formed but wrong,
  # KIND="claude" and LIFECYCLE="dead" both fall outside their closed sets.
  export ID="hijack" KIND="claude" LIFECYCLE="dead"
  # shellcheck source=/dev/null
  . "$here/lib/registry.sh"
  registry_load clean >/dev/null 2>&1
  printf 'rc=%s ID=%s KIND=%s LIFECYCLE=%s' "$?" "$ID" "$KIND" "$LIFECYCLE"
)"
[ "$out" = "rc=0 ID=clean KIND=work LIFECYCLE=active" ] \
  && ok "a polluted ID/KIND/LIFECYCLE never survives a fresh load" \
  || bad "a polluted ID/KIND/LIFECYCLE never survives a fresh load" "$out"

echo "the schema gate is WIRED — a checkout that is behind refuses to load"

# THE GATE THAT GUARDS NOTHING. Until this task registry_schema_check had exactly
# one caller: this test file. The estate declared a version, the library knew how
# to compare it, and nothing ever asked. A gate with no caller is not a gate that
# passes — it is a gate that is not there, and it looks identical from outside.
#
# The next task raises the estate to schema 3. Wiring must come FIRST: the moment
# a version is raised past an unwired gate, every older checkout reads the new
# number without objection and the key becomes decoration permanently.
#
# THE FULL FIELD SET STANDS HERE TOO, WITH ONLY SCHEMA_VERSION RAISED. A
# minimal estate (three keys) would ALSO make registry_load return 78 later,
# from the unrelated HUB_HOST lookup — indistinguishable from the schema gate
# firing. Only a fully valid estate isolates the gate: everything else this
# load would need is present, so 78 can only come from the version check.
estate 'LABEL_PREFIX="com.example.claude"' 'ESTATE_NAME="acme"' 'SCHEMA_VERSION="999"' \
  'RC_LABEL_PREFIX="Steward: "' 'HUB_SESSION="hub"' 'HUB_HOST="hub"' 'JOB_LOG_DIR="jobs"' \
  'HUB_SSH="owner@hub"' 'TMUX_SOCKET="steward.sock"' 'PING_MSG="ping"' \
  'JOB_LABEL_PREFIX="com.example.job"' 'SERVICE_LABEL_PREFIX="com.example.service"' \
  'BROWSER_LABEL_PREFIX="com.example.browser"' 'OP_TOKEN_FILE_NAME="token"' \
  'STATE_DIR_NAME="adapter-state"' 'PAUSED_DIR_NAME="paused"'
konf gated 'REPO_PATH="/x"' 'RC_LABEL="G"' 'OWNER="ada"' 'DOMAIN="d"'
( export STEWARD_ESTATE_ROOT="$FX" STEWARD_REGISTRY_DIR="$FX/sessions.d"
  # shellcheck source=/dev/null
  . "$here/lib/registry.sh"
  registry_load gated >/dev/null 2>&1 )
rc=$?
[ "$rc" -eq 78 ] && ok "a newer estate makes registry_load refuse with 78" \
                 || bad "a newer estate makes registry_load refuse with 78" "rc=$rc"

# THE REFUSAL COMES FIRST. A conf that is ALSO malformed must still fail on the
# schema, not on its own fields: the point of the gate is that a checkout which
# cannot understand the register must not start interpreting it. A test that only
# uses a valid conf cannot tell the two orders apart. Same fully valid estate as
# above (still schema 999) — the only thing wrong here is the conf's own KIND.
konf broken 'REPO_PATH="/x"' 'RC_LABEL="B"' 'OWNER="ada"' 'DOMAIN="d"' 'KIND="nonsense"'
( export STEWARD_ESTATE_ROOT="$FX" STEWARD_REGISTRY_DIR="$FX/sessions.d"
  # shellcheck source=/dev/null
  . "$here/lib/registry.sh"
  registry_load broken >/dev/null 2>&1 )
rc=$?
[ "$rc" -eq 78 ] && ok "the schema refusal precedes field validation" \
                 || bad "the schema refusal precedes field validation" "rc=$rc, expected 78 not 1"

# CONTROL GROUP: at the version this checkout understands, loading works exactly
# as before. Without this the two assertions above would also pass against a
# registry_load that refused everything.
#
# THE FULL FIELD SET IS RESTORED HERE, NOT JUST SCHEMA_VERSION. The two
# refusal assertions above ran against a deliberately minimal estate (three
# keys) because the schema gate is meant to fire before any other field is
# even looked at. registry_load, once past the gate, still resolves HUB_HOST,
# the label prefixes and the op token name — so a control group that wants to
# prove "the load is unaffected" must give it everything a real load needs,
# the same full set used earlier in this file.
estate 'LABEL_PREFIX="com.example.claude"' 'ESTATE_NAME="acme"' 'SCHEMA_VERSION="2"' \
  'RC_LABEL_PREFIX="Steward: "' 'HUB_SESSION="hub"' 'HUB_HOST="hub"' 'JOB_LOG_DIR="jobs"' \
  'HUB_SSH="owner@hub"' 'TMUX_SOCKET="steward.sock"' 'PING_MSG="ping"' \
  'JOB_LABEL_PREFIX="com.example.job"' 'SERVICE_LABEL_PREFIX="com.example.service"' \
  'BROWSER_LABEL_PREFIX="com.example.browser"' 'OP_TOKEN_FILE_NAME="token"' \
  'STATE_DIR_NAME="adapter-state"' 'PAUSED_DIR_NAME="paused"'
[ "$(ladda gated ID)" = "gated" ] && ok "at a known schema the load is unaffected" \
                                  || bad "at a known schema the load is unaffected" "got '$(ladda gated ID)'"

echo "entities — one node type, two relations"

mkdir -p "$FX/entities.d"
ent() { # <id> <line...>
  local id="$1"; shift
  printf '%s\n' "$@" > "$FX/entities.d/$id.conf"
}
lad_ent() { # <id> <field>
  ( export STEWARD_ESTATE_ROOT="$FX" STEWARD_ENTITY_DIR="$FX/entities.d"
    # shellcheck source=/dev/null
    . "$here/lib/registry.sh"
    registry_entity_load "$1" >/dev/null 2>&1 || exit 1
    printf '%s' "${!2}" )
}
estate 'LABEL_PREFIX="com.example.claude"' 'ESTATE_NAME="acme"' 'SCHEMA_VERSION="2"'

# A TEAM IS AN ENTITY WITH MEMBERS.
ent alfa 'NAME="Alfa"' 'MEMBERS="ada bo"'
[ "$(lad_ent alfa ENTITY_MEMBERS)" = "ada bo" ] && ok "a team carries its members" \
  || bad "a team carries its members" "got '$(lad_ent alfa ENTITY_MEMBERS)'"

# A CLIENT IS AN ENTITY MANAGED BY ONE. Same file shape, different relation —
# that is the whole claim the spec makes, so the test must load both from the
# same loader and see them differ.
ent beta 'NAME="Beta"' 'MANAGED_BY="alfa"'
[ "$(lad_ent beta ENTITY_MANAGED_BY)" = "alfa" ] && ok "a client carries its managing team" \
  || bad "a client carries its managing team" "got '$(lad_ent beta ENTITY_MANAGED_BY)'"
[ -z "$(lad_ent beta ENTITY_MEMBERS)" ] && ok "a client has no members by default" \
  || bad "a client has no members by default" "got '$(lad_ent beta ENTITY_MEMBERS)'"

# THE ID COMES FROM THE FILE NAME, like sessions. One name, keyed on.
[ "$(lad_ent alfa ENTITY_ID)" = "alfa" ] && ok "the entity id is its file name" \
  || bad "the entity id is its file name" "got '$(lad_ent alfa ENTITY_ID)'"

# A DISPLAY NAME IS REQUIRED and free-form: it is what a human reads, and an
# entity with no readable name is a row nobody can act on.
ent gamma 'MEMBERS="ada"'
lad_ent gamma ENTITY_NAME >/dev/null 2>&1
[ "$?" -ne 0 ] && ok "an entity without NAME refuses" || bad "an entity without NAME refuses" "accepted"

# BOTH RELATIONS AT ONCE IS LEGAL, and the spec says so explicitly: the day a
# client has its own people it gets members, with no new type and no migration.
ent delta 'NAME="Delta"' 'MEMBERS="ada"' 'MANAGED_BY="alfa"'
[ "$(lad_ent delta ENTITY_MEMBERS)" = "ada" ] && [ "$(lad_ent delta ENTITY_MANAGED_BY)" = "alfa" ] \
  && ok "an entity may have members AND a managing team" \
  || bad "an entity may have members AND a managing team" "one of them was lost"

# MANAGED_BY MUST RESOLVE. A relation pointing at nothing is worse than no
# relation: it reads as structure and carries none.
ent epsilon 'NAME="Epsilon"' 'MANAGED_BY="no-such-entity"'
lad_ent epsilon ENTITY_ID >/dev/null 2>&1
[ "$?" -ne 0 ] && ok "MANAGED_BY pointing at nothing refuses" \
               || bad "MANAGED_BY pointing at nothing refuses" "accepted"

# MANAGED_BY MUST RESOLVE, NOT MERELY EXIST AS A FILE. gamma's row (above) has
# no NAME, so it does not resolve through registry_entity_load even though
# gamma.conf is right there on disk. A file test alone would accept this; the
# loader must not.
ent zeta 'NAME="Zeta"' 'MANAGED_BY="gamma"'
lad_ent zeta ENTITY_ID >/dev/null 2>&1
[ "$?" -ne 0 ] && ok "MANAGED_BY pointing at a broken entity refuses" \
               || bad "MANAGED_BY pointing at a broken entity refuses" "accepted"

# SELF-MANAGEMENT REFUSES. An entity managing itself is a cycle of length one,
# and a file test alone would accept it (the file plainly exists).
ent eta 'NAME="Eta"' 'MANAGED_BY="eta"'
lad_ent eta ENTITY_ID >/dev/null 2>&1
[ "$?" -ne 0 ] && ok "self-management refuses" || bad "self-management refuses" "accepted"

# THE LIST REFUSES RATHER THAN LOOKING EMPTY — the house rule.
utE="$( ( export STEWARD_ESTATE_ROOT="$FX" STEWARD_ENTITY_DIR="$FX/no-such-dir"
          . "$here/lib/registry.sh"; registry_entity_list ) 2>&1 )"
rc=$?
[ "$rc" -eq 78 ] && ok "an unreadable entity register refuses with 78" \
                 || bad "an unreadable entity register refuses with 78" "rc=$rc: $utE"

# A FAILED LOAD MUST NOT LEAK THE PREVIOUS ENTITY'S DATA. lad_ent runs each
# load in its own throwaway subshell, which hides exactly this bug: the leak
# only shows up when a successful load and a failed load share ONE shell, so
# this assertion makes its own subshell that does both loads itself instead
# of calling lad_ent twice.
leaked="$( ( export STEWARD_ESTATE_ROOT="$FX" STEWARD_ENTITY_DIR="$FX/entities.d"
  # shellcheck source=/dev/null
  . "$here/lib/registry.sh"
  registry_entity_load alfa >/dev/null 2>&1
  registry_entity_load gamma >/dev/null 2>&1
  printf '%s' "$ENTITY_MEMBERS" ) )"
[ -z "$leaked" ] && ok "a failed load does not leak the previous entity's data" \
  || bad "a failed load does not leak the previous entity's data" "got '$leaked'"

echo "projects — the work, under whichever parent it belongs to"

mkdir -p "$FX/projects.d"
proj() { local id="$1"; shift; printf '%s\n' "$@" > "$FX/projects.d/$id.conf"; }
load_proj() {
  ( export STEWARD_ESTATE_ROOT="$FX" STEWARD_ENTITY_DIR="$FX/entities.d" \
           STEWARD_PROJECT_DIR="$FX/projects.d"
    # shellcheck source=/dev/null
    . "$here/lib/registry.sh"
    registry_project_load "$1" >/dev/null 2>&1 || exit 1
    printf '%s' "${!2}" )
}

# A PROJECT UNDER A TEAM — own work.
proj egen 'NAME="Egen"' 'PARENT="alfa"'
[ "$(load_proj egen PROJECT_PARENT)" = "alfa" ] && ok "a project may hang under a team" \
  || bad "a project may hang under a team" "got '$(load_proj egen PROJECT_PARENT)'"

# A PROJECT UNDER A CLIENT — client work. SAME FIELD, different parent. That is
# the spec's claim: own-work versus client-work is the EDGE, not a label, so a
# test that only ever uses one kind of parent proves nothing about it.
proj kund 'NAME="Kund"' 'PARENT="beta"'
[ "$(load_proj kund PROJECT_PARENT)" = "beta" ] && ok "a project may hang under a client" \
  || bad "a project may hang under a client" "got '$(load_proj kund PROJECT_PARENT)'"

[ "$(load_proj egen PROJECT_ID)" = "egen" ] && ok "the project id is its file name" \
  || bad "the project id is its file name" "got '$(load_proj egen PROJECT_ID)'"

# THE PARENT MUST EXIST AND MUST BE AN ENTITY. A project whose parent is missing
# is an orphan that reads as placed.
proj stray 'NAME="Stray"' 'PARENT="no-such-id"'
load_proj stray PROJECT_ID >/dev/null 2>&1
[ "$?" -ne 0 ] && ok "a project with an unresolvable parent refuses" \
               || bad "a project with an unresolvable parent refuses" "accepted"

# A PARENT IS REQUIRED. A project under nothing is exactly the overbroad grouping
# the whole model exists to replace.
proj parentless 'NAME="Parentless"'
load_proj parentless PROJECT_ID >/dev/null 2>&1
[ "$?" -ne 0 ] && ok "a project without PARENT refuses" || bad "a project without PARENT refuses" "accepted"

proj nameless 'PARENT="alfa"'
load_proj nameless PROJECT_ID >/dev/null 2>&1
[ "$?" -ne 0 ] && ok "a project without NAME refuses" || bad "a project without NAME refuses" "accepted"

utP="$( ( export STEWARD_ESTATE_ROOT="$FX" STEWARD_PROJECT_DIR="$FX/no-such-id"
          . "$here/lib/registry.sh"; registry_project_list ) 2>&1 )"
rc=$?
[ "$rc" -eq 78 ] && ok "an unreadable project register refuses with 78" \
                 || bad "an unreadable project register refuses with 78" "rc=$rc: $utP"

# A FAILED LOAD MUST NOT LEAK THE PREVIOUS PROJECT'S DATA. load_proj runs each
# load in its own throwaway subshell, which hides exactly this bug: the leak
# only shows up when a successful load and a failed load share ONE shell, so
# this assertion makes its own subshell that does both loads itself instead
# of calling load_proj twice.
leakedP="$( ( export STEWARD_ESTATE_ROOT="$FX" STEWARD_ENTITY_DIR="$FX/entities.d" \
                     STEWARD_PROJECT_DIR="$FX/projects.d"
  # shellcheck source=/dev/null
  . "$here/lib/registry.sh"
  registry_project_load egen >/dev/null 2>&1
  registry_project_load nameless >/dev/null 2>&1
  printf '%s|%s|%s' "$PROJECT_ID" "$PROJECT_NAME" "$PROJECT_PARENT" ) )"
[ "$leakedP" = "||" ] && ok "a failed load does not leak the previous project's data" \
  || bad "a failed load does not leak the previous project's data" "got '$leakedP'"

printf 'pass=%s fail=%s\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
