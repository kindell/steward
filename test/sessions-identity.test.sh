#!/bin/bash
# test/sessions-identity.test.sh — the identity layer: who is this session?
#
# IDENTITY IS THE FREE LAYER. It is a local file read: no network, no host, no
# subprocess that can hang. That is why it is separated from liveness, which is
# none of those things — mixing a safe read with an unsafe one in the same
# function makes the safe one inherit the unsafe one's failure modes.
#
# HERMETIC. A fixture registry, never the real one. The claims here are about
# the shape of a row, not about any particular estate's sessions.
set -u

here="$(CDPATH= cd -- "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
pass=0; fail=0
ok()  { pass=$((pass+1)); printf '  ok   %s\n' "$1"; }
bad() { fail=$((fail+1)); printf '  FAIL %s\n     %s\n' "$1" "${2:-}"; }
is()  { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "wanted '$3', got '$2'"; fi; }

FX="$(mktemp -d)"; trap 'rm -rf "$FX"' EXIT
mkdir -p "$FX/sessions.d" "$FX/entities.d" "$FX/estate"

# registry_load REFUSES without an estate file — LABEL_PREFIX, HUB_HOST and
# OP_TOKEN_FILE_NAME are read unconditionally, not just when a conf omits the
# field they default. A fixture that skips this file is not "no estate
# configured", it is every session in it failing to load with rc 78 — a
# different bug than the one this suite exists to test.
printf 'LABEL_PREFIX="com.fixture.claude"\nHUB_HOST="h1"\nOP_TOKEN_FILE_NAME="fixture-token"\n' \
  > "$FX/estate/steward.conf"

printf 'HOST="h1"\nOWNER="alice"\nDOMAIN="acme"\nRC_LABEL="L"\nREPO_PATH="/tmp/x"\nID="full"\nASSETS="widget other:thing"\n' \
  > "$FX/sessions.d/full.conf"
printf 'HOST="h1"\nOWNER="bob"\nDOMAIN="team-one"\nRC_LABEL="L"\nREPO_PATH="/tmp/x"\nID="bare"\n' \
  > "$FX/sessions.d/bare.conf"

# TWO ENTITY RELATIONS, NOT ONE. MEMBERS names the people who work FOR an
# entity; MANAGED_BY names the entity this one is a client of. They are
# different facts and a row that flattened them would lose the distinction the
# registry deliberately makes.
printf 'NAME="Acme"\nMANAGED_BY="team-one"\n' > "$FX/entities.d/acme.conf"
printf 'NAME="Team One"\nMEMBERS="alice bob"\n' > "$FX/entities.d/team-one.conf"

export STEWARD_REGISTRY_DIR="$FX/sessions.d"
export STEWARD_ESTATE_ROOT="$FX"
# STEWARD_VIEWER: session_identity_rows filters by who is asking (M8's
# visibility rule) — a suite that never says who it is testing as is a suite
# testing whichever account happens to run it, not the code. "alice" owns
# `full` and, through team-one's MEMBERS, is also a legitimate viewer of
# `bare` (owned by bob) — one default covers most of this file's fixtures.
# A handful of later fixtures are owned by carol or dave instead; those calls
# override STEWARD_VIEWER inline rather than widening this default.
export STEWARD_VIEWER="alice"
# shellcheck source=/dev/null
. "$here/lib/sessions.sh"

field() { printf '%s\n' "$1" | awk -F'\t' -v r="$2" -v c="$3" '$1==r{print $c}'; }

echo "== a row carries every identity field =="
out="$(session_identity_rows)"; rc=$?
is "rc 0" "$rc" "0"
is "two sessions, two rows" "$(printf '%s\n' "$out" | grep -c .)" "2"
is "name"            "$(field "$out" full 1)" "full"
is "id"              "$(field "$out" full 2)" "full"
is "owner"           "$(field "$out" full 3)" "alice"
is "domain"          "$(field "$out" full 4)" "acme"
is "host"            "$(field "$out" full 5)" "h1"
is "entity name"     "$(field "$out" full 6)" "Acme"
is "entity relation" "$(field "$out" full 7)" "client"
is "assets"          "$(field "$out" full 8)" "widget other:thing"
# THE ORG LINEAGE: THE MANAGING TEAM, THEN THE ENTITY. `full` sits under acme,
# and acme is managed by team-one — so the column reads the chain root-first,
# joined with the arrow this product already uses for a derived display.
is "lineage"         "$(field "$out" full 11)" "Team One→Acme"

echo "== the other relation is read as itself =="
is "a team entity says team" "$(field "$out" bare 7)" "team"
is "and names itself"        "$(field "$out" bare 6)" "Team One"
# A SESSION DIRECTLY UNDER A TEAM HAS A ONE-NAME LINEAGE. Nothing manages
# team-one, so there is no chain to render — and an invented "-→Team One"
# would read as a managing team that does not exist.
is "and its lineage is just itself" "$(field "$out" bare 11)" "Team One"

# AN EMPTY FIELD IS A DASH, NOT AN EMPTY COLUMN. A row whose columns shift
# because one was blank is a row every consumer parses wrong, and the consumer
# here is a cockpit that would render the shift as data.
echo "== nothing declared is a dash, never a blank column =="
is "no assets is a dash" "$(field "$out" bare 8)" "-"
is "the row still has eleven fields" \
   "$(printf '%s\n' "$out" | awk -F'\t' '$1=="bare"{print NF}')" "11"
# ...AND SO DOES A ROW WHOSE LAST FIELD CARRIES A REAL VALUE. Counting the
# columns only on the row whose eighth field is the literal dash (the row is
# eleven fields wide: slug and display were added additively, and lineage after
# them) verifies the dash substitution, not the row shape: a value that itself
# contained a tab would still split into extra columns and this assertion would
# never see it.
is "a row whose last field is a real value has eleven fields too" \
   "$(printf '%s\n' "$out" | awk -F'\t' '$1=="full"{print NF}')" "11"

# AN UNKNOWN ENTITY IS NOT AN ERROR. A session may name a domain no entity file
# describes yet; that is a gap in the registry, not a failure of this read.
echo "== a domain with no entity file still yields a row =="
printf 'HOST="h1"\nOWNER="carol"\nDOMAIN="nosuch"\nRC_LABEL="L"\nREPO_PATH="/tmp/x"\nID="orphan"\n' \
  > "$FX/sessions.d/orphan.conf"
# orphan's owner is carol, not the suite default alice, and its domain has no
# entity to grant a team view either — so only carol can see it.
out2="$(STEWARD_VIEWER=carol session_identity_rows)"
is "the orphan is listed"        "$(field "$out2" orphan 1)" "orphan"
is "its entity name is a dash"   "$(field "$out2" orphan 6)" "-"
is "its relation is a dash"      "$(field "$out2" orphan 7)" "-"
# AN UNRESOLVABLE ENTITY HAS NO LINEAGE TO REPORT, and the dash says exactly
# that. Falling back to the raw DOMAIN slug here would render a registry gap as
# an org chart — a guess wearing the clothes of a measurement.
is "and its lineage is a dash"   "$(field "$out2" orphan 11)" "-"

# AN UNREADABLE REGISTRY MUST REFUSE. Empty output from a missing directory is
# indistinguishable from an estate with no sessions.
echo "== an unreadable registry refuses, never prints empty =="
out3="$(STEWARD_REGISTRY_DIR="$FX/does-not-exist" session_identity_rows 2>/dev/null)"; rc3=$?
is "rc is non-zero" "$( [ "$rc3" -ne 0 ] && echo yes || echo no )" "yes"
is "and nothing was printed" "$out3" ""

# A SYSTEMIC FAILURE MUST NOT LOOK LIKE ZERO SESSIONS. registry_load refuses
# EVERY session identically when the estate file is missing or missing a
# required field (LABEL_PREFIX/HUB_HOST/OP_TOKEN_FILE_NAME) — registry_list
# still succeeds, so a loop that just `continue`s past each failure reports
# rc 0 with no rows, indistinguishable from an estate that genuinely has no
# sessions. That is the exact failure this whole layer exists to prevent.
echo "== a broken estate file refuses, not an empty read =="
SYS="$FX/systemic"; mkdir -p "$SYS/sessions.d" "$SYS/entities.d"
# Deliberately no estate/steward.conf: sessions.d holds a real, otherwise-valid
# conf, so registry_list sees one name — but nothing can load.
printf 'HOST="h1"\nOWNER="alice"\nDOMAIN="acme"\nRC_LABEL="L"\nREPO_PATH="/tmp/x"\nID="full"\n' \
  > "$SYS/sessions.d/full.conf"
out_sys="$(STEWARD_REGISTRY_DIR="$SYS/sessions.d" STEWARD_ESTATE_ROOT="$SYS" session_identity_rows 2>"$FX/sys.err")"; rc_sys=$?
is "systemic: rc is non-zero" "$( [ "$rc_sys" -ne 0 ] && echo yes || echo no )" "yes"
is "systemic: stdout is empty" "$out_sys" ""
is "systemic: stderr says something" "$( [ -s "$FX/sys.err" ] && echo yes || echo no )" "yes"

# ZERO SESSIONS MUST STAY A DIFFERENT ANSWER FROM "CANNOT READ". The fix above
# must not overcorrect into refusing an estate that genuinely has none.
echo "== a valid estate with zero sessions is still rc 0 =="
ZERO="$FX/zero"; mkdir -p "$ZERO/sessions.d" "$ZERO/entities.d" "$ZERO/estate"
printf 'LABEL_PREFIX="com.fixture.claude"\nHUB_HOST="h1"\nOP_TOKEN_FILE_NAME="fixture-token"\n' \
  > "$ZERO/estate/steward.conf"
out_zero="$(STEWARD_REGISTRY_DIR="$ZERO/sessions.d" STEWARD_ESTATE_ROOT="$ZERO" session_identity_rows 2>"$FX/zero.err")"; rc_zero=$?
is "zero sessions: rc 0" "$rc_zero" "0"
is "zero sessions: stdout is empty" "$out_zero" ""

# A PARTIAL FAILURE MUST STILL LIST THE GOOD ONES, AND NAME THE BAD ONE. The
# contract is "data on stdout, diagnosis on stderr" — a session that exists in
# the registry but could not be read is diagnosis, and dropping it silently is
# the same failure as the systemic case, just for one row instead of all.
echo "== a partial failure lists the good session and names the bad one on stderr =="
PART="$FX/partial"; mkdir -p "$PART/sessions.d" "$PART/entities.d" "$PART/estate"
printf 'LABEL_PREFIX="com.fixture.claude"\nHUB_HOST="h1"\nOP_TOKEN_FILE_NAME="fixture-token"\n' \
  > "$PART/estate/steward.conf"
printf 'HOST="h1"\nOWNER="dave"\nDOMAIN="acme"\nRC_LABEL="L"\nREPO_PATH="/tmp/x"\nID="good"\n' \
  > "$PART/sessions.d/good.conf"
# No OWNER: registry_load's own OWNER validation rejects this one (rc 1).
printf 'HOST="h1"\nDOMAIN="acme"\nRC_LABEL="L"\nREPO_PATH="/tmp/x"\nID="bad"\n' \
  > "$PART/sessions.d/bad.conf"
# the readable session here is owned by dave, not the suite default alice.
out_part="$(STEWARD_REGISTRY_DIR="$PART/sessions.d" STEWARD_ESTATE_ROOT="$PART" STEWARD_VIEWER=dave session_identity_rows 2>"$FX/part.err")"; rc_part=$?
is "partial: rc 0" "$rc_part" "0"
is "partial: the good session is listed" "$(field "$out_part" good 1)" "good"
is "partial: the bad session is absent from stdout" "$(field "$out_part" bad 1)" ""
is "partial: the bad session is named on stderr" \
   "$(grep -q 'bad' "$FX/part.err" && echo yes || echo no)" "yes"

# AN EMPTY MANAGED_BY VALUE IS NOT A RELATION. Matching the key's presence
# rather than a non-empty value would classify a stale/template
# MANAGED_BY="" as "client" instead of falling through to MEMBERS.
echo "== an empty MANAGED_BY value falls through to MEMBERS =="
printf 'NAME="Odd"\nMANAGED_BY=""\nMEMBERS="carol"\n' > "$FX/entities.d/odd.conf"
printf 'HOST="h1"\nOWNER="carol"\nDOMAIN="odd"\nRC_LABEL="L"\nREPO_PATH="/tmp/x"\nID="oddsession"\n' \
  > "$FX/sessions.d/oddsession.conf"
# oddsession's owner is carol, not the suite default alice.
out4="$(STEWARD_VIEWER=carol session_identity_rows)"
is "empty MANAGED_BY reads as team, not client" "$(field "$out4" oddsession 7)" "team"

# ── THE ORG LINEAGE COLUMN: ONE HOP, AND NEVER A GUESS ─────────────────────
#
# A DEDICATED FIXTURE ESTATE. The lineage claims below need an entity tree
# three levels deep and a project, and the checks on a hostile display NAME
# have to REWRITE an entity conf — doing either inside the suite's shared $FX
# would change what every earlier assertion in this file measured.
ORG="$FX/org"; mkdir -p "$ORG/sessions.d" "$ORG/entities.d" "$ORG/projects.d" "$ORG/estate"
printf 'LABEL_PREFIX="com.fixture.claude"\nHUB_HOST="h1"\nOP_TOKEN_FILE_NAME="fixture-token"\n' \
  > "$ORG/estate/steward.conf"
printf 'NAME="Team One"\nMEMBERS="alice"\n'   > "$ORG/entities.d/team-one.conf"
printf 'NAME="Acme"\nMANAGED_BY="team-one"\n' > "$ORG/entities.d/acme.conf"
# THREE LEVELS: beta is a client of acme, which is itself a client of team-one.
# The lineage of a session under beta must stop after ONE hop.
printf 'NAME="Beta"\nMANAGED_BY="acme"\n'     > "$ORG/entities.d/beta.conf"
printf 'NAME="H1 Rollout"\nPARENT="acme"\n'   > "$ORG/projects.d/h1.conf"
org() { STEWARD_REGISTRY_DIR="$ORG/sessions.d" STEWARD_ESTATE_ROOT="$ORG" \
        STEWARD_VIEWER=alice session_identity_rows 2>/dev/null; }

# ONE HOP, THE SAME DELIBERATE LIMIT THE VISIBILITY RULE DRAWS. A client of a
# client is not the same work: a column that walked the whole chain would grow
# an ever-widening ancestry nobody declared, and it would grow WIDER over time
# as the tree deepens, in a fixed-width table.
echo "== the lineage stops after one MANAGED_BY hop =="
printf 'HOST="h1"\nOWNER="alice"\nDOMAIN="beta"\nRC_LABEL="L"\nREPO_PATH="/tmp/x"\nID="deep"\n' \
  > "$ORG/sessions.d/deep.conf"
org_out="$(org)"
is "the managing team and the entity, and nothing above them" \
   "$(field "$org_out" deep 11)" "Acme→Beta"

# THE TARGET IS THE ANSWER, DOMAIN ONLY THE LEGACY FALLBACK — the same
# precedence the entity join beside it already uses. A migrated row's DOMAIN can
# name an entity that never existed, and a lineage derived from it would
# contradict the entity columns on its own row.
echo "== the lineage follows TARGET_ENTITY, not a stale DOMAIN =="
printf 'HOST="h1"\nOWNER="alice"\nDOMAIN="gone"\nTARGET_ENTITY="acme"\nRC_LABEL="L"\nREPO_PATH="/tmp/x"\nID="aimed"\n' \
  > "$ORG/sessions.d/aimed.conf"
org_out="$(org)"
is "the declared target decides"  "$(field "$org_out" aimed 11)" "Team One→Acme"
is "and the entity column agrees" "$(field "$org_out" aimed 6)"  "Acme"

echo "== a session aimed at a project reaches the entity through PARENT =="
printf 'HOST="h1"\nOWNER="alice"\nDOMAIN="h1"\nTARGET_PROJECT="h1"\nRC_LABEL="L"\nREPO_PATH="/tmp/x"\nID="onproj"\n' \
  > "$ORG/sessions.d/onproj.conf"
org_out="$(org)"
is "the project's PARENT entity is the one rendered" \
   "$(field "$org_out" onproj 11)" "Team One→Acme"

# A DISPLAY NAME CARRYING THE SEPARATOR COULD FORGE AN ANCESTOR. The arrow is
# generated by this join and by nothing else; a NAME allowed to carry one would
# let a single entity conf render an org chart the registry does not contain.
# The honest answer is the dash — the same one an unresolvable entity gets.
echo "== a display name carrying the arrow cannot forge an ancestor =="
printf 'NAME="Beta→Fake Parent"\nMANAGED_BY="acme"\n' > "$ORG/entities.d/beta.conf"
org_out="$(org)"
is "the row is still there"        "$(field "$org_out" deep 1)"  "deep"
is "and its lineage is a dash"     "$(field "$org_out" deep 11)" "-"
is "the sessions above are unaffected" "$(field "$org_out" aimed 11)" "Team One→Acme"
printf 'NAME="Beta"\nMANAGED_BY="acme"\n' > "$ORG/entities.d/beta.conf"

# ── FIELD CONTENT IS A HAZARD, NOT JUST FIELD PRESENCE ─────────────────────
#
# A TSV row is only a row while no VALUE contains the separator. ASSETS is the
# one registry field registry_load resets without validating (bin/probe-dispatch
# says so in as many words), and the entity display NAME is validated for
# presence, never for charset. A raw printf of either one lets a conf forge
# extra columns — or, with enough of them, a whole extra session that the
# registry does not contain. Reproduced 2026-08-28: one conf in, two sessions
# out, rc 0, nothing on either stream.
echo "== a value carrying a tab and a newline cannot forge a row =="
HOS="$FX/hostile"; mkdir -p "$HOS/sessions.d" "$HOS/entities.d" "$HOS/estate"
printf 'LABEL_PREFIX="com.fixture.claude"\nHUB_HOST="h1"\nOP_TOKEN_FILE_NAME="fixture-token"\n' \
  > "$HOS/estate/steward.conf"
printf 'NAME="Acme"\nMEMBERS="alice"\n' > "$HOS/entities.d/acme.conf"
# The injection is written with real control characters: a tab inside the value
# and a newline that opens what looks like a second eight-field row.
{
  printf 'HOST="h1"\nOWNER="alice"\nDOMAIN="acme"\nRC_LABEL="L"\nREPO_PATH="/tmp/x"\nID="alpha"\n'
  printf 'ASSETS="one\nzz-ghost\tzz-ghost\troot\tprod\thub9\tMegaCorp\tclient\tsecret"\n'
} > "$HOS/sessions.d/alpha.conf"
hos_out="$(STEWARD_REGISTRY_DIR="$HOS/sessions.d" STEWARD_ESTATE_ROOT="$HOS" session_identity_rows 2>/dev/null)"
is "one conf in the registry is one row out" \
   "$(printf '%s\n' "$hos_out" | grep -c .)" "1"
is "the row still has exactly eleven fields" \
   "$(printf '%s\n' "$hos_out" | awk -F'\t' 'NR==1{print NF}')" "11"
# THE PROPERTY IS "NO NEW COLUMN", NOT "NO TAB ANYWHERE AFTER IT". The older
# glob asked whether a real tab followed the ghost text anywhere on the line —
# true for any row that simply has more fields after the injected one, which is
# what happened the day slug and display were added. It would have gone red on a
# perfectly escaped row. The real question: does the fabricated name occupy a
# field of its own? Ask awk, which splits on real tabs only.
_ghost_field="$(printf '%s\n' "$hos_out" | awk -F'\t' '{for(i=1;i<=NF;i++) if ($i=="zz-ghost") print i}')"
if [ -n "$_ghost_field" ]; then
  bad "no fabricated session name reaches a column of its own" "zz-ghost owns field $_ghost_field in: $hos_out"
else
  ok  "no fabricated session name reaches a column of its own"
fi
is "the session that does exist is still named correctly" \
   "$(field "$hos_out" alpha 1)" "alpha"
is "and its owner is not overwritten by the injection" \
   "$(field "$hos_out" alpha 3)" "alice"

# THE ENTITY DISPLAY NAME IS THE SECOND VECTOR. Nothing validates its charset,
# and a tab in it shifts every column to its right — turning `relation` into
# whatever the second half of the name happened to be, outside its own closed
# set team|client|-.
echo "== a tab in the entity display name cannot shift the relation column =="
printf 'NAME="Ac\tme"\nMEMBERS="alice"\n' > "$HOS/entities.d/acme.conf"
hos2="$(STEWARD_REGISTRY_DIR="$HOS/sessions.d" STEWARD_ESTATE_ROOT="$HOS" session_identity_rows 2>/dev/null)"
is "the row still has exactly eleven fields" \
   "$(printf '%s\n' "$hos2" | awk -F'\t' 'NR==1{print NF}')" "11"
rel="$(field "$hos2" alpha 7)"
case "$rel" in
  team|client|-) ok "the relation stays inside its closed set" ;;
  *)             bad "the relation stays inside its closed set" "got '$rel'" ;;
esac

# ── THE ENTITY JOIN IS THE REGISTRY'S OWN READ, NOT A SECOND ONE ───────────
#
# A second implementation of a measurement drifts from the first, and the drift
# renders as a fact. registry_entity_load accepts single-quoted values, requires
# a NAME, and resolves MANAGED_BY through itself; a local sed for the same two
# fields matched only double quotes. Measured 2026-08-28: NAME='Acme Ltd' read
# as no entity at all — a false `null` indistinguishable from the honest "no
# entity file describes this domain".
echo "== a single-quoted entity name resolves, it does not read as no entity =="
SQ="$FX/singlequote"; mkdir -p "$SQ/sessions.d" "$SQ/entities.d" "$SQ/estate"
printf 'LABEL_PREFIX="com.fixture.claude"\nHUB_HOST="h1"\nOP_TOKEN_FILE_NAME="fixture-token"\n' \
  > "$SQ/estate/steward.conf"
printf "NAME='Acme Ltd'\nMEMBERS='alice'\n" > "$SQ/entities.d/acme.conf"
printf 'HOST="h1"\nOWNER="alice"\nDOMAIN="acme"\nRC_LABEL="L"\nREPO_PATH="/tmp/x"\nID="sq"\n' \
  > "$SQ/sessions.d/sq.conf"
sq_out="$(STEWARD_REGISTRY_DIR="$SQ/sessions.d" STEWARD_ESTATE_ROOT="$SQ" session_identity_rows 2>/dev/null)"
is "the single-quoted name is read"  "$(field "$sq_out" sq 6)" "Acme Ltd"
is "and its relation with it"        "$(field "$sq_out" sq 7)" "team"

# A RELATION POINTING AT NOTHING IS NOT A RELATION. The registry's loader
# refuses a MANAGED_BY that does not resolve; reporting `client` on the strength
# of the line existing invents structure out of a typo.
echo "== a MANAGED_BY pointing at nothing does not read as client =="
printf 'NAME="Orphan Co"\nMANAGED_BY="no-such-team"\n' > "$SQ/entities.d/acme.conf"
sq2="$(STEWARD_REGISTRY_DIR="$SQ/sessions.d" STEWARD_ESTATE_ROOT="$SQ" session_identity_rows 2>"$FX/sq.err")"
is "the session is still listed"     "$(field "$sq2" sq 1)" "sq"
is "but it is not called a client"   "$( [ "$(field "$sq2" sq 7)" = "client" ] && echo yes || echo no )" "no"
is "and the unreadable entity is named on stderr" \
   "$(grep -q 'no-such-team' "$FX/sq.err" && echo yes || echo no)" "yes"

# ── M7: THE CAUSE IS THE ONLY USEFUL HALF OF A SKIP LINE ───────────────────
echo "== a skipped session's diagnostic carries the registry's own cause =="
M7="$FX/cause"; mkdir -p "$M7/sessions.d" "$M7/entities.d" "$M7/estate"
printf 'LABEL_PREFIX="com.fixture.claude"\nHUB_HOST="h1"\nOP_TOKEN_FILE_NAME="fixture-token"\n' \
  > "$M7/estate/steward.conf"
printf 'HOST="h1"\nOWNER="alice"\nDOMAIN="acme"\nRC_LABEL="L"\nREPO_PATH="/tmp/x"\nID="ok"\n' \
  > "$M7/sessions.d/fine.conf"
# HOST is validated by registry_load and says so by name.
printf 'HOST="NOT A HOST"\nOWNER="alice"\nDOMAIN="acme"\nRC_LABEL="L"\nREPO_PATH="/tmp/x"\nID="b"\n' \
  > "$M7/sessions.d/badhost.conf"
STEWARD_REGISTRY_DIR="$M7/sessions.d" STEWARD_ESTATE_ROOT="$M7" \
  session_identity_rows >/dev/null 2>"$FX/cause.err"
is "the skip line names the session" \
   "$(grep -q "skipping 'badhost'" "$FX/cause.err" && echo yes || echo no)" "yes"
is "and carries the registry's own cause, not just a generic sentence" \
   "$(grep -q "invalid HOST" "$FX/cause.err" && echo yes || echo no)" "yes"

# ── I4: THE UNREADABLE SESSIONS ARE A VALUE, NOT ONLY A SENTENCE ───────────
#
# The declared consumer of this layer is a view reading a subprocess' stdout.
# Telling it to also capture stderr and correlate the two is an instruction that
# does not survive contact with a client, so the names are readable as data too.
echo "== the skipped sessions are also carried in SESSIONS_UNREADABLE =="
SESSIONS_UNREADABLE="stale-value-from-a-previous-run"
STEWARD_REGISTRY_DIR="$M7/sessions.d" STEWARD_ESTATE_ROOT="$M7" \
  session_identity_rows >/dev/null 2>/dev/null
is "the bad session is named in it" \
   "$(printf '%s\n' "$SESSIONS_UNREADABLE" | grep -cx 'badhost')" "1"
is "the good one is not"  \
   "$(printf '%s\n' "$SESSIONS_UNREADABLE" | grep -cx 'fine')" "0"
STEWARD_REGISTRY_DIR="$ZERO/sessions.d" STEWARD_ESTATE_ROOT="$ZERO" \
  session_identity_rows >/dev/null 2>/dev/null
is "and a clean run resets it, it does not accumulate" \
   "$(printf '%s' "$SESSIONS_UNREADABLE")" ""

# ── THE ARGV CHANNEL: A FIELD VALUE THAT IS ALSO A jq OPTION ───────────────
#
# The tab-and-newline fixture above proves control characters are escaped
# INSIDE the filter. It cannot see this class: jq parses options anywhere on
# its command line, including after --args, so a field value that happens to
# spell an option token is consumed as an option rather than handed to @tsv as
# data — no control character involved. ASSETS is the one registry field
# registry_load resets without validating, so this is the field a hostile or
# merely unlucky conf reaches through.
#
# TWO TOKENS, TWO DIFFERENT FAILURE SHAPES. --tab is swallowed as a jq flag,
# short one field on the row; -h makes jq print its own usage text to stdout,
# in place of the row. A fix that only closed one of these would still leave
# the other indistinguishable from a healthy session.
echo "== an ASSETS value that is a jq option token does not eat a field =="
ARGV="$FX/argv-option"; mkdir -p "$ARGV/sessions.d" "$ARGV/entities.d" "$ARGV/estate"
printf 'LABEL_PREFIX="com.fixture.claude"\nHUB_HOST="h1"\nOP_TOKEN_FILE_NAME="fixture-token"\n' \
  > "$ARGV/estate/steward.conf"
printf 'HOST="h1"\nOWNER="alice"\nDOMAIN="acme"\nRC_LABEL="L"\nREPO_PATH="/tmp/x"\nID="argvtab"\nASSETS="--tab"\n' \
  > "$ARGV/sessions.d/argvtab.conf"
argv_tab_out="$(STEWARD_REGISTRY_DIR="$ARGV/sessions.d" STEWARD_ESTATE_ROOT="$ARGV" session_identity_rows 2>/dev/null)"
is "--tab: row count matches the registry (one session, one row)" \
   "$(printf '%s\n' "$argv_tab_out" | grep -c .)" "1"
is "--tab: the row still has all eleven fields" \
   "$(printf '%s\n' "$argv_tab_out" | awk -F'\t' 'NR==1{print NF}')" "11"
is "--tab: the session's own name is present" \
   "$(field "$argv_tab_out" argvtab 1)" "argvtab"

rm -f "$ARGV/sessions.d/argvtab.conf"
printf 'HOST="h1"\nOWNER="alice"\nDOMAIN="acme"\nRC_LABEL="L"\nREPO_PATH="/tmp/x"\nID="argvh"\nASSETS="-h"\n' \
  > "$ARGV/sessions.d/argvh.conf"
argv_h_out="$(STEWARD_REGISTRY_DIR="$ARGV/sessions.d" STEWARD_ESTATE_ROOT="$ARGV" session_identity_rows 2>/dev/null)"
is "-h: row count matches the registry (one session, one row)" \
   "$(printf '%s\n' "$argv_h_out" | grep -c .)" "1"
is "-h: the row still has all eleven fields" \
   "$(printf '%s\n' "$argv_h_out" | awk -F'\t' 'NR==1{print NF}')" "11"
is "-h: the session's own name is present" \
   "$(field "$argv_h_out" argvh 1)" "argvh"
case "$argv_h_out" in
  *"commandline JSON processor"*) bad "-h: jq's own usage text does not enter the row stream" "got: $argv_h_out" ;;
  *)                               ok  "-h: jq's own usage text does not enter the row stream" ;;
esac

echo
printf 'pass=%s fail=%s\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
