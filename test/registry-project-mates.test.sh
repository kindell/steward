#!/bin/bash
# test/registry-project-mates.test.sh — registry_project_mates and its one-line
# rendering: the OTHER sessions that work on the same thing this one does.
#
# WHY IT EXISTS. Two sessions aimed at the same project can already reach each
# other on the bus, and nothing ever tells either of them that the other is
# there. `desk` shows a human the project's sessions; this is the session's side
# of the same truth, and it has to come from the register rather than from a
# list somebody maintains by hand.
#
# THE ENTITY FALLBACK IS NARROW ON PURPOSE. A session with no TARGET_PROJECT
# works on the entity itself, and its mates are the rows that ALSO name that
# entity directly. A project row is NOT pulled in through its project's PARENT:
# every project in an estate hangs under some entity, so walking the join would
# make "mates" mean "everyone in the org" — which is the one thing the answer
# must not mean, because a session acts on what it is told is near it.
#
# THE CALLER'S OWN ROW MUST SURVIVE THE CALL. registry_load SOURCES a conf into
# the caller's variables, and every consumer of this helper (the hub's enrol
# path, both runtime adapters) calls it while holding its own loaded row. The
# last section proves the helper is subshelled whole, the same convention
# registry_session_owning_entity and registry_display_for carry.
#
# HERMETIC: a fresh mktemp estate per run, STEWARD_CONFIG_FILE aimed at a path
# that cannot exist. Owners are the letter convention the other registry suites
# already use; nothing real.
set -u

here="$(CDPATH= cd -- "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
pass=0; fail=0
ok()  { pass=$((pass+1)); printf '  ok   %s\n' "$1"; }
bad() { fail=$((fail+1)); printf '  FAIL %s\n     %s\n' "$1" "${2:-}"; }
is()  { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "wanted '$3', got '$2'"; fi; }
hasnt(){ case "$2" in *"$3"*) bad "$1" "unexpectedly present '$3' in: $2" ;; *) ok "$1" ;; esac; }

FX="$(mktemp -d)"; trap 'rm -rf "$FX"' EXIT
mkdir -p "$FX/estate" "$FX/sessions.d" "$FX/entities.d" "$FX/projects.d"
SESS="$FX/sessions.d"; ENT="$FX/entities.d"; PROJ="$FX/projects.d"

# The full required-key set: registry_load reads several estate values
# unconditionally, and a half-built estate would turn every case below into a
# fixture bug (rc 78) instead of a measurement of the helper.
cat > "$FX/estate/steward.conf" <<'EOF'
ESTATE_NAME="fixture"
SCHEMA_VERSION="3"
LABEL_PREFIX="com.fixture.claude"
RC_LABEL_PREFIX="fixture: "
HUB_SESSION="fixture-hub"
HUB_HOST="h1"
HUB_SSH="a@h1"
JOB_LOG_DIR="fixture-jobs"
TMUX_SOCKET="fixture.sock"
PING_MSG="you have mail"
STATE_DIR_NAME="fixture-supervisor"
PAUSED_DIR_NAME="fixture-paused"
JOB_LABEL_PREFIX="com.fixture.job"
SERVICE_LABEL_PREFIX="com.fixture.service"
BROWSER_LABEL_PREFIX="com.fixture.browser"
OP_TOKEN_FILE_NAME="fixture-token"
EOF

printf 'NAME="Team"\nMEMBERS="a b c"\n' > "$ENT/team.conf"
# BOTH PROJECTS HANG UNDER THE SAME ENTITY. That is what makes the entity
# fallback worth measuring: a rule that walked the PARENT join would report the
# project rows as mates of the entity rows, and the case below would pass by
# accident under a fixture where the parents differed.
printf 'NAME="Work"\nPARENT="team"\n'  > "$PROJ/work.conf"
printf 'NAME="Other"\nPARENT="team"\n' > "$PROJ/other.conf"

row() { # <name> <owner> <target-line> [rc-label] [slug]
  { printf 'OWNER="%s"\nDOMAIN="team"\nREPO_PATH="/tmp/x"\n' "$2"
    # A ROW THAT NAMES NO TARGET MUST NAME ITS LABEL. registry_load derives the
    # display from the target and refuses a row that can do neither — so the
    # empty-label form is what a target-less row looks like in a real register,
    # and writing it here keeps case 4 a measurement of the helper rather than
    # of a conf the loader would have rejected anyway.
    if [ -n "${3:-}" ]; then printf '%s\n' "$3"; else printf 'RC_LABEL=""\n'; fi
    # THE OPTIONAL FOURTH ARGUMENT gives a row its own RC_LABEL alongside a
    # target — precedence 1 over the derived form, so a mate carrying one
    # proves the line shows what registry_session_display actually returns,
    # not a re-derivation of the target done a second way here.
    [ -n "${4:-}" ] && printf 'RC_LABEL="%s"\n' "$4"
    # THE OPTIONAL FIFTH ARGUMENT gives a row a SLUG (registry_load requires
    # none of ACCOUNT/TARGET_* alongside it - the identity fields are read
    # leniently, shape only, with no cross-field requirement at load time).
    [ -n "${5:-}" ] && printf 'SLUG="%s"\n' "$5"
  } > "$SESS/$1.conf"
}

row p1   a 'TARGET_PROJECT="work"'
row p2   b 'TARGET_PROJECT="work"' Ben
row p3   c 'TARGET_PROJECT="other"'
row e1   a 'TARGET_ENTITY="team"'
row e2   b 'TARGET_ENTITY="team"' Ann
row lone c ''

# mates <session> — the helper in a hermetic subshell. OUT carries stdout, RC
# the exit code; stderr is dropped (the refusal case asserts on RC and on OUT
# staying empty, not on wording).
mates() {
  OUT="$(
    export STEWARD_REGISTRY_DIR="$SESS" STEWARD_ESTATE_ROOT="$FX" \
           STEWARD_ENTITY_DIR="$ENT" STEWARD_PROJECT_DIR="$PROJ" \
           STEWARD_CONFIG_FILE="$FX/no-such-config"
    . "$here/lib/registry.sh"
    registry_project_mates "$1" "${2:-mates_project}" 2>/dev/null
  )"
  RC=$?
}

mates_line() { # the same, through the one-line rendering the consumers share
  OUT="$(
    export STEWARD_REGISTRY_DIR="$SESS" STEWARD_ESTATE_ROOT="$FX" \
           STEWARD_ENTITY_DIR="$ENT" STEWARD_PROJECT_DIR="$PROJ" \
           STEWARD_CONFIG_FILE="$FX/no-such-config"
    . "$here/lib/registry.sh"
    registry_project_mates_line "$1" 2>/dev/null
  )"
  RC=$?
}

echo "== 1. THE PROJECT CASE — the other rows on this row's TARGET_PROJECT =="
mates p1
is "1: rc 0"                       "$RC"  "0"
is "1: p1's mate is p2, with its owner and display" "$OUT" "p2 (b) Ben"
hasnt "1: the row never lists itself"   "$OUT" "p1"
hasnt "1: a row on another project is not a mate" "$OUT" "p3"

echo "== 2. ALONE ON A PROJECT IS AN ANSWER, NOT A FAULT =="
# Nothing on stdout and rc 0. A refusal here would make "nobody else works on
# this" indistinguishable from "the register could not be read", and the
# consumers would have to guess which one they got.
mates p3
is "2: rc 0"          "$RC"  "0"
is "2: nothing printed" "$OUT" ""

echo "== 3. NO PROJECT — the entity, and ONLY rows that name it directly =="
mates e1
is "3: rc 0"                        "$RC"  "0"
is "3: e1's mate is e2, with its owner and display" "$OUT" "e2 (b) Ann"
hasnt "3: a project row is not pulled in through the project's PARENT" "$OUT" "p1"
hasnt "3: nor the second project row"                                  "$OUT" "p2"

echo "== 4. A ROW WITH NEITHER FIELD IS NOBODY'S MATE, AND HAS NONE =="
mates lone
is "4: rc 0"            "$RC"  "0"
is "4: nothing printed" "$OUT" ""
mates e1
hasnt "4: and it is not somebody else's mate either" "$OUT" "lone"

echo "== 5. A NAME THE REGISTER DOES NOT CARRY IS A FAULT, NOT AN EMPTY SET =="
mates no-such-session
is "5: rc 1"            "$RC"  "1"
is "5: nothing printed" "$OUT" ""

echo "== 6. TWO MATES: one per line, sorted by name =="
# p0 sorts before p2 and is added LAST, so the order in the output cannot come
# from the order the fixture was written in. p0 carries no RC_LABEL, so its
# display comes from the TARGET_PROJECT fallback (registry_display_for) —
# proving the label is registry_session_display's own answer, not just an
# echo of an RC_LABEL that happens to be sitting on the row.
row p0 c 'TARGET_PROJECT="work"'
mates p1
is "6: rc 0"            "$RC"  "0"
is "6: both, sorted"    "$OUT" "$(printf 'p0 (c) Team→Work\np2 (b) Ben')"

echo "== 7. THE ONE-LINE RENDERING the three consumers share =="
# One spelling of the joined form and one spelling of the empty answer, in the
# library — the hub's proof line and both runtime adapters print the same
# string, and "none" cannot drift into "-" in one of them. The join is `; `,
# not `, `: a display is free text and can itself carry a comma.
mates_line p1
is "7: rc 0"                 "$RC"  "0"
is "7: semicolon-joined"     "$OUT" "p0 (c) Team→Work; p2 (b) Ben"
mates_line p3
is "7: the empty answer is spelled out" "$OUT" "none"
mates_line no-such-session
is "7: an unknown name still refuses"   "$RC"  "1"

echo "== 8. THE CALLER'S OWN ROW SURVIVES THE CALL =="
# registry_load SOURCES a conf into the caller's variables. Every consumer
# calls this helper while holding its own loaded row, so the helper must be
# subshelled whole — the same convention registry_session_owning_entity and
# registry_display_for carry. Without it the adapter that asked "who else is on
# my project" would find its own OWNER and TARGET_PROJECT replaced by the last
# row the loop happened to read.
OUT="$(
  export STEWARD_REGISTRY_DIR="$SESS" STEWARD_ESTATE_ROOT="$FX" \
         STEWARD_ENTITY_DIR="$ENT" STEWARD_PROJECT_DIR="$PROJ" \
         STEWARD_CONFIG_FILE="$FX/no-such-config"
  . "$here/lib/registry.sh"
  registry_load p1 >/dev/null 2>&1 || exit 9
  registry_project_mates p1 >/dev/null 2>&1
  printf '%s|%s|%s' "$SESSION_NAME" "$OWNER" "$TARGET_PROJECT"
)"
is "8: the caller's loaded row is untouched" "$OUT" "p1|a|work"

echo "== 9. A MATE WHOSE TARGET DOES NOT RESOLVE IS STILL A MATE =="
# g2 targets a project with no projects.d/ghostproj.conf at all (renamed away,
# or never created). registry_session_display cannot derive a display for it,
# and the fallback in the loop above must carry the row through anyway, bare.
row g1 c 'TARGET_PROJECT="ghostproj"'
row g2 d 'TARGET_PROJECT="ghostproj"'
mates g1
is "9: rc 0"                                 "$RC"  "0"
is "9: the mate survives with the bare form" "$OUT" "g2 (d)"

echo "== 10. A CANDIDATE WITH A SLUG IS NAMED BY ITS SLUG, NOT ITS ROW NAME =="
# Humans and the estate docs speak slug; the rendered instruction ("Reach one
# with: bus-send <slug> ...") must name a slug, not the opaque id every row
# born under the identity model carries as its name.
row slugsubj a 'TARGET_PROJECT="slugwork"'
row slugcand b 'TARGET_PROJECT="slugwork"' '' mate-one
mates slugsubj
is "10: rc 0"                                      "$RC"  "0"
is "10: the candidate is named by its SLUG"        "$OUT" "mate-one (b)"

echo "== 11. A SUBJECT'S OWN SLUG NEVER LEAKS ONTO A SLUG-LESS CANDIDATE =="
# registry_load resets SLUG="" on every load, so a row without SLUG cannot
# inherit the subject's - pinned here rather than trusted.
row slugsubj2 a 'TARGET_PROJECT="slugwork2"' '' subject-slug
row barecand  b 'TARGET_PROJECT="slugwork2"'
mates slugsubj2
is "11: rc 0"                                                       "$RC"  "0"
is "11: the slug-less candidate is named by its row name, never the subject's slug" \
   "$OUT" "barecand (b)"

echo "== visibility and all relationship levels =="
row hidden b 'TARGET_PROJECT="work"'
printf 'VISIBILITY="private"\n' >> "$SESS/hidden.conf"
mates p1
hasnt "private project mate is hidden" "$OUT" "hidden"
printf 'VISIBLE_TO="team"\n' >> "$SESS/hidden.conf"
mates p1
is "explicit grant restores private mate" "$(printf '%s\n' "$OUT" | grep -c '^hidden ')" 1
printf 'NAME="Client"\nMEMBERS="c"\nMANAGED_BY="team"\n' > "$ENT/client.conf"
printf 'NAME="Client work"\nPARENT="client"\n' > "$PROJ/client-work.conf"
printf 'NAME="Sibling"\nPARENT="client"\n' > "$PROJ/sibling.conf"
row cp c 'TARGET_PROJECT="client-work"'
row peer b 'TARGET_PROJECT="client-work"'
row sibling b 'TARGET_PROJECT="sibling"'
row parent b 'TARGET_ENTITY="client"'
row private-peer b 'TARGET_PROJECT="client-work"'
printf 'VISIBILITY="private"\n' >> "$SESS/private-peer.conf"
mates cp
is "client member sees project peer" "$(printf '%s\n' "$OUT" | grep -c '^peer ')" 1
hasnt "private peer is hidden" "$OUT" private-peer
mates cp mates_client
for name in peer sibling parent; do
  is "client level includes $name" "$(printf '%s\n' "$OUT" | grep -c "^$name ")" 1
done
hasnt "client level excludes unrelated team rows" "$OUT" 'p1 '
hasnt "client level filters private rows" "$OUT" private-peer
mates p1 mates_team
is "team includes entity own rows" "$(printf '%s\n' "$OUT" | grep -c '^e1 ')" 1
is "team includes other projects under membership" "$(printf '%s\n' "$OUT" | grep -c '^p3 ')" 1
hasnt "team excludes entities without direct membership" "$OUT" 'peer '
OUT="$(
  export STEWARD_ESTATE_ROOT="$FX" STEWARD_REGISTRY_DIR="$SESS" STEWARD_CONFIG_FILE="$FX/no-such-config"
  . "$here/lib/registry.sh"
  registry_mates_summary cp
)"
for heading in 'Same project:' 'Same client:' 'Same team:' 'People on this project: c'; do
  is "summary includes $heading" "$(printf '%s\n' "$OUT" | grep -Fc "$heading")" 1
done

mkdir -p "$FX/accounts.d"
printf 'PRINCIPAL="c"\nHOST="h1"\nUSERNAME="service"\n' > "$FX/accounts.d/service.conf"
printf 'OWNER="service"\nHOST="h1"\nACCOUNT="service"\nTARGET_PROJECT="client-work"\nREPO_PATH="/tmp/repo"\n' > "$SESS/service.conf"
mates service mates_team
is "team membership uses the account principal, not the Unix owner" "$(printf '%s\n' "$OUT" | grep -c '^peer ')" 1

echo "pass=$pass fail=$fail"
[ "$fail" -eq 0 ]
