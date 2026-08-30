#!/bin/bash
# test/registry-display.test.sh — registry_display_for, the display
# derivation (lib/registry.sh): the root-to-leaf ancestry NAMEs joined with
# the U+2192 arrow, for an ENTITY (walk MANAGED_BY to the root) or a PROJECT
# (its own NAME as the leaf, prepended by its PARENT entity's own derived
# display).
#
# THE LOAD-BEARING SECTION IS THE FORGE SUITE (case 5). Display is presentation,
# never identity — but a NAME that is allowed to CONTAIN the separator this
# function itself generates could forge or split the derived path it returns,
# and a caller that treats the returned string as structured (splitting on the
# arrow) would then be fooled by a single hostile row. Each component is
# validated BEFORE the join, never after — this suite proves that a NAME
# carrying the arrow, or a control byte, refuses rather than silently joining.
#
# Case 6 proves the walk cannot be corrupted by a row that assigns the SAME
# lowercase local names the walk itself uses (name, parent, slug) — the exact
# class of danger every other loader in this file closes by loading through a
# command-substitution SUBSHELL rather than sourcing directly in the caller's
# own scope.
#
# PURE: registry_display_for only reads STEWARD_ENTITY_DIR/STEWARD_PROJECT_DIR
# fixture directories set below — no estate.conf is needed, and no steward CLI
# binary is invoked; this suite calls the library function directly.
set -u

here="$(CDPATH= cd -- "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
pass=0; fail=0
ok()  { pass=$((pass+1)); printf '  ok   %s\n' "$1"; }
bad() { fail=$((fail+1)); printf '  FAIL %s\n     %s\n' "$1" "${2:-}"; }
is()  { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "wanted '$3', got '$2'"; fi; }

FX="$(mktemp -d)"; trap 'rm -rf "$FX"' EXIT
ENT="$FX/entities.d"
PROJ="$FX/projects.d"
mkdir -p "$ENT" "$PROJ"

# disp <kind> <slug> — sets OUT (stdout) and RC (exit code) of a single
# registry_display_for call, hermetically pointed at this fixture's dirs.
disp() {
  OUT="$(
    . "$here/lib/registry.sh"
    STEWARD_ENTITY_DIR="$ENT" STEWARD_PROJECT_DIR="$PROJ" registry_display_for "$1" "$2"
  )"
  RC=$?
}

echo "== 1. entity, no MANAGED_BY: display is just its own NAME =="
cat > "$ENT/alpha.conf" <<'EOF'
NAME="Alpha"
MEMBERS="a"
EOF
disp entity alpha
is "1: rc 0"     "$RC"  "0"
is "1: display"  "$OUT" "Alpha"

echo "== 2. entity, one MANAGED_BY hop: root->leaf =="
cat > "$ENT/acme.conf" <<'EOF'
NAME="Acme"
MANAGED_BY="alpha"
EOF
disp entity acme
is "2: rc 0"     "$RC"  "0"
is "2: display"  "$OUT" "Alpha→Acme"

echo "== 3. project directly under a team: PARENT's display + own NAME =="
cat > "$PROJ/site.conf" <<'EOF'
NAME="Site"
PARENT="alpha"
EOF
disp project site
is "3: rc 0"     "$RC"  "0"
is "3: display"  "$OUT" "Alpha→Site"

echo "== 4. project under a client: root->client->project =="
cat > "$PROJ/site-under-acme.conf" <<'EOF'
NAME="Site"
PARENT="acme"
EOF
disp project site-under-acme
is "4: rc 0"     "$RC"  "0"
is "4: display"  "$OUT" "Alpha→Acme→Site"

echo "== 5. THE FORGE SUITE — a NAME cannot carry the separator or a control byte =="

echo "-- 5a: entity NAME literally containing the arrow refuses rc 1, nothing printed --"
printf 'NAME="Evil%sFake"\n' '→' > "$ENT/forged.conf"
disp entity forged
is "5a: rc 1"       "$RC"  "1"
is "5a: no output"  "$OUT" ""

echo "-- 5b: project NAME containing the arrow refuses rc 1 --"
printf 'NAME="Evil%sFake"\nPARENT="alpha"\n' '→' > "$PROJ/forged-project.conf"
disp project forged-project
is "5b: rc 1"       "$RC"  "1"
is "5b: no output"  "$OUT" ""

echo "-- 5c: PARENT entity's NAME containing the arrow also refuses (not just the leaf) --"
printf 'NAME="Evil%sFake"\n' '→' > "$ENT/forged-parent.conf"
cat > "$PROJ/clean-leaf.conf" <<'EOF'
NAME="Clean"
PARENT="forged-parent"
EOF
disp project clean-leaf
is "5c: rc 1"       "$RC"  "1"
is "5c: no output"  "$OUT" ""

echo "-- 5d: entity NAME with an embedded control byte (newline) refuses rc 1 --"
printf 'NAME="line1\nline2"\n' > "$ENT/ctrl-entity.conf"
disp entity ctrl-entity
is "5d: rc 1"       "$RC"  "1"
is "5d: no output"  "$OUT" ""

echo "-- 5e: entity NAME with an embedded control byte (tab) refuses rc 1 --"
printf 'NAME="a\tb"\n' > "$ENT/tab-entity.conf"
disp entity tab-entity
is "5e: rc 1"       "$RC"  "1"
is "5e: no output"  "$OUT" ""

echo "== 6. SUBSHELLED-LOAD PROOF — a row's own lowercase name/parent/slug cannot clobber the walk =="
cat > "$ENT/clobber.conf" <<'EOF'
NAME="Clobber"
MANAGED_BY="alpha"
slug="pwned"
parent="pwned"
name="pwned"
EOF
disp entity clobber
is "6a: rc 0"    "$RC"  "0"
is "6a: display not corrupted" "$OUT" "Alpha→Clobber"

cat > "$PROJ/clobber-project.conf" <<'EOF'
NAME="ClobberProject"
PARENT="alpha"
slug="pwned"
parent="pwned"
name="pwned"
EOF
disp project clobber-project
is "6b: rc 0"    "$RC"  "0"
is "6b: display not corrupted" "$OUT" "Alpha→ClobberProject"

echo "== 7. MANAGED_BY cycle terminates with rc 1, not an infinite loop =="
cat > "$ENT/cyc-a.conf" <<'EOF'
NAME="CycA"
MANAGED_BY="cyc-b"
EOF
cat > "$ENT/cyc-b.conf" <<'EOF'
NAME="CycB"
MANAGED_BY="cyc-a"
EOF
timeout 10 bash -c '
  . "'"$here"'/lib/registry.sh"
  STEWARD_ENTITY_DIR="'"$ENT"'" STEWARD_PROJECT_DIR="'"$PROJ"'" registry_display_for entity cyc-a
'
rc=$?
if [ "$rc" -eq 124 ]; then
  bad "7: MANAGED_BY cycle" "timed out — infinite loop, not a refusal"
else
  is "7: MANAGED_BY cycle refuses rc 1 (bounded)" "$rc" "1"
fi

echo "== 8. unknown target-kind refuses (usage error), not silently entity =="
disp bogus-kind alpha
if [ "$RC" -eq 0 ]; then
  bad "8: unknown kind rc" "wanted non-zero, got 0"
else
  ok "8: unknown kind refuses (rc $RC)"
fi
is "8: no output" "$OUT" ""

echo "pass=$pass fail=$fail"
[ "$fail" -eq 0 ]
