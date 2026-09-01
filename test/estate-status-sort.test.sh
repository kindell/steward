#!/bin/bash
# test/estate-status-sort.test.sh — the estate-listing table's own --sort,
# reordering the rows on the underlying field, never the rendered text.
#
# WHY THIS EXISTS. `steward sessions --sort` (1503e29) never reached the
# ESTATE listing form (`steward <estate> ls`): measured live, `steward
# <estate> ls --sort slug` neither sorted nor refused — the flag was silently
# swallowed on the way from bin/steward's dispatcher into cmd_ls. Silent
# flag-swallowing is worse than the flag not existing at all. This suite
# covers the RENDERER's half of the fix: linux/estate-status.sh, the script
# that actually owns this table's raw '|'-delimited rows before the final
# `column -t` render. bin/steward's own plumbing (the dispatcher forwarding
# the flag, and cmd_ls validating it before ever touching ssh) has no test
# harness for the ssh-based estate routes to extend — there is none in this
# suite today — so that half is covered by direct manual verification of the
# generated remote command string; this file only exercises the script both
# sides of that ssh hop actually run.
#
# THE FIXTURE DISAGREES ON PURPOSE, same shape as test/sessions-command.test.sh's
# --sort fixture: three sessions whose NAME order disagrees with SLUG order,
# OWNER order, HOST order and RC_LABEL (display) order. A fixture that agreed
# under every key could not tell "the flag reordered the rows" from "the rows
# were already in that order".
set -u
here="$(CDPATH= cd -- "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
pass=0; fail=0
ok()  { pass=$((pass+1)); printf '  ok   %s\n' "$1"; }
bad() { fail=$((fail+1)); printf '  FAIL %s\n     %s\n' "$1" "${2:-}"; }
is()  { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "wanted '$3', got '$2'"; fi; }
has() { case "$2" in *"$3"*) ok "$1" ;; *) bad "$1" "missing '$3' in: $2" ;; esac; }

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
mkdir -p "$T/sessions.d" "$T/entities.d" "$T/estate" "$T/bin" "$T/home/.tmux"

cat > "$T/estate/steward.conf" <<'EOF'
LABEL_PREFIX="com.example.claude"
RC_LABEL_PREFIX="Example: "
HUB_SESSION="examplehub"
HUB_HOST="examplehost"
STATE_DIR_NAME="example-supervisor"
PAUSED_DIR_NAME="example-paused"
JOB_LOG_DIR="example-jobs"
TMUX_SOCKET="example.sock"
EOF

# name=asess: OWNER first alphabetically, HOST last, SLUG last, display first.
printf 'HOST="hzz"\nOWNER="aowner"\nDOMAIN="example"\nRC_LABEL="rlA"\nSLUG="zzz-slug"\n' \
  > "$T/sessions.d/asess.conf"
# name=msess: OWNER middle, HOST middle, NO SLUG (the dash case), display middle.
printf 'HOST="hmm"\nOWNER="mowner"\nDOMAIN="example"\nRC_LABEL="rlM"\n' \
  > "$T/sessions.d/msess.conf"
# name=zsess: OWNER last, HOST first, SLUG first, display last.
printf 'HOST="haa"\nOWNER="zowner"\nDOMAIN="example"\nRC_LABEL="rlZ"\nSLUG="aaa-slug"\n' \
  > "$T/sessions.d/zsess.conf"

# ── THE ORG TREE THE LINEAGE COLUMN READS ──────────────────────────────────
#
# Three levels: beta is a client of acme, and acme is itself a client of
# team-one. A lineage that walked the whole chain would render three names for
# beta; this column stops after ONE hop, the same limit lib/visibility.sh and
# lib/sessions.sh both draw.
printf 'NAME="Team One"\n'                    > "$T/entities.d/team-one.conf"
printf 'NAME="Acme"\nMANAGED_BY="team-one"\n' > "$T/entities.d/acme.conf"
printf 'NAME="Beta"\nMANAGED_BY="acme"\n'     > "$T/entities.d/beta.conf"
# TARGET_ENTITY, APPENDED — never a rewritten RC_LABEL or DOMAIN. Both of those
# drive assertions written above, and the whole value of this fixture is that
# each key's order disagrees with the others'.
printf 'TARGET_ENTITY="beta"\n'     >> "$T/sessions.d/asess.conf"
printf 'TARGET_ENTITY="acme"\n'     >> "$T/sessions.d/msess.conf"
printf 'TARGET_ENTITY="team-one"\n' >> "$T/sessions.d/zsess.conf"
# THE DASH ROW, and the ONLY row `order` below deliberately does not match — so
# every assertion written before this one still measures exactly what it did
# before nsess existed. Its DOMAIN names no entity, so its ORG cell is "-".
printf 'HOST="hmm"\nOWNER="nowner"\nDOMAIN="nosuch-entity"\nRC_LABEL="rlN"\n' \
  > "$T/sessions.d/nsess.conf"

cat > "$T/bin/tmux" <<'EOF'
#!/bin/bash
exit 0
EOF
chmod +x "$T/bin/tmux"

run() { STEWARD_ESTATE_ROOT="$T" STEWARD_REGISTRY_DIR="$T/sessions.d" \
        STEWARD_SELF_HOST="examplehost" STEWARD_SELF_USER="exampleuser" \
        HOME="$T/home" PATH="$T/bin:$PATH" \
        bash "$here/linux/estate-status.sh" "$@"; }
# THE ORDER OF THE THREE SESSION NAMES, READ OFF THE TABLE'S OWN SESSION
# COLUMN — not a substring search, which cannot tell order from mere
# presence. `column -t`'s leading ownership-marker column is '*' for a row the
# viewer owns and a single space otherwise; awk's default whitespace-FS
# collapses the space marker into nothing (SESSION lands in $1) but keeps the
# '*' as its own field (SESSION lands in $2) — so this scans every field on
# the line for the one that IS a session name, rather than trusting a fixed
# column number either way.
order() {
  printf '%s\n' "$1" | awk '{ for (i = 1; i <= NF; i++) if ($i ~ /^(asess|msess|zsess)$/) { print $i; next } }' | tr '\n' ','
}

echo "== estate-status --sort: default order is unchanged =="
is "default order is name order" "$(order "$(run)")" "asess,msess,zsess,"

echo "== estate-status --sort name: same as today's order, named explicitly =="
is "name order" "$(order "$(run --sort name)")" "asess,msess,zsess,"

echo "== estate-status --sort owner: alphabetical by OWNER =="
is "owner order" "$(order "$(run --sort owner)")" "asess,msess,zsess,"

echo "== estate-status --sort host: alphabetical by HOST, disagrees with name order =="
is "host order" "$(order "$(run --sort host)")" "zsess,msess,asess,"

echo "== estate-status --sort display: alphabetical by RC_LABEL =="
is "display order" "$(order "$(run --sort display)")" "asess,msess,zsess,"

echo "== estate-status --sort slug: alphabetical by SLUG, dash (no slug) last =="
is "slug order, dash last" "$(order "$(run --sort slug)")" "zsess,asess,msess,"

# ── THE ORG COLUMN ─────────────────────────────────────────────────────────
#
# THE SAME QUESTION, THE SAME ANSWER, IN BOTH LISTINGS. `steward sessions`
# renders this lineage from lib/sessions.sh's row; this table derives it here,
# from the same tree, with the same one-hop limit. A column that agreed in one
# listing and not the other would be worse than no column.
echo "== the estate table carries an ORG column =="
org_out="$(run)"
has "the header carries ORG" "$org_out" "ORG"
row_m="$(printf '%s\n' "$org_out" | grep -E '(^| )msess ')"
has "a client under a team reads Team→Client" "$row_m" "Team One→Acme"

echo "== a session directly under a team reads just the team =="
row_z="$(printf '%s\n' "$org_out" | grep -E '(^| )zsess ')"
has "the team names itself" "$row_z" "Team One"
case "$row_z" in
  *"→"*) bad "and nothing is prepended to it" "row: '$row_z'" ;;
  *)     ok  "and nothing is prepended to it" ;;
esac

echo "== the lineage stops after one MANAGED_BY hop =="
row_a="$(printf '%s\n' "$org_out" | grep -E '(^| )asess ')"
has "the managing entity and the entity" "$row_a" "Acme→Beta"
case "$row_a" in
  *"Team One"*) bad "and nothing above them" "row: '$row_a'" ;;
  *)            ok  "and nothing above them" ;;
esac

echo "== an entity the registry does not describe reads a dash, never a guess =="
row_n="$(printf '%s\n' "$org_out" | grep -E '(^| )nsess ')"
has "the row is still listed" "$row_n" "nsess"
case "$row_n" in
  *nosuch-entity*) bad "and its ORG cell does not fall back to the raw slug" "row: '$row_n'" ;;
  *)               ok  "and its ORG cell does not fall back to the raw slug" ;;
esac

# THE FOURTH SESSION IS ONLY EVER READ HERE, for the same reason as in
# test/sessions-command.test.sh: `order` above must keep measuring three rows.
ordern() {
  printf '%s\n' "$1" | awk '{ for (i = 1; i <= NF; i++) if ($i ~ /^(asess|msess|nsess|zsess)$/) { print $i; next } }' | tr '\n' ','
}
echo "== estate-status --sort lineage: alphabetical by the ORG lineage, dash last =="
is "lineage order, dash last" "$(ordern "$(run --sort lineage)")" "asess,zsess,msess,nsess,"

# A DISPLAY NAME IS NEVER VALIDATED FOR CHARSET BY THE REGISTRY — only for
# presence — so the two bytes this column depends on have to be checked here,
# before the join, and both answer with the dash rather than with a half-true
# cell.
echo "== a display name carrying the arrow cannot forge an ancestor =="
printf 'NAME="Beta→Fake Parent"\nMANAGED_BY="acme"\n' > "$T/entities.d/beta.conf"
forge_out="$(run)"
row_f="$(printf '%s\n' "$forge_out" | grep -E '(^| )asess ')"
has "the row is still listed" "$row_f" "asess"
case "$row_f" in
  *"Fake Parent"*) bad "and the forged ancestor never renders" "row: '$row_f'" ;;
  *)               ok  "and the forged ancestor never renders" ;;
esac

# '|' IS THIS TABLE'S OWN FIELD SEPARATOR. A NAME carrying one would open a
# column of its own and shift every cell to its right — the same class of
# fault a tab in an entity name causes in the TSV layer.
echo "== a display name carrying the table's own separator cannot add a column =="
printf 'NAME="Beta|Ghost"\nMANAGED_BY="acme"\n' > "$T/entities.d/beta.conf"
sep_out="$(run)"
row_s="$(printf '%s\n' "$sep_out" | grep -E '(^| )asess ')"
has "the row is still listed" "$row_s" "asess"
case "$row_s" in
  *Ghost*) bad "and the injected text never reaches a cell" "row: '$row_s'" ;;
  *)       ok  "and the injected text never reaches a cell" ;;
esac
printf 'NAME="Beta"\nMANAGED_BY="acme"\n' > "$T/entities.d/beta.conf"

echo "== estate-status --sort with an unknown key refuses, listing the valid ones =="
uerr="$(mktemp)"
uout="$(run --sort bogus 2>"$uerr")"; urc=$?
uerrtext="$(cat "$uerr")"; rm -f "$uerr"
is "rc is 64" "$urc" "64"
is "stdout is empty" "$uout" ""
has "names the bad key" "$uerrtext" "bogus"
has "lists slug"    "$uerrtext" "slug"
has "lists display" "$uerrtext" "display"
has "lists owner"   "$uerrtext" "owner"
has "lists host"    "$uerrtext" "host"
has "lists name"    "$uerrtext" "name"
has "lists lineage" "$uerrtext" "lineage"

echo "== estate-status: an unrelated unknown flag still refuses rc 64 (unchanged) =="
berr="$(mktemp)"
bout="$(run --bogus 2>"$berr")"; brc=$?
berrtext="$(cat "$berr")"; rm -f "$berr"
is "rc is 64" "$brc" "64"
is "stdout is empty" "$bout" ""
has "names the bad option" "$berrtext" "bogus"

echo "== estate-status: --mine and --sort still combine =="
mout="$(STEWARD_ESTATE_ROOT="$T" STEWARD_REGISTRY_DIR="$T/sessions.d" \
        STEWARD_SELF_HOST="examplehost" STEWARD_SELF_USER="aowner" \
        HOME="$T/home" PATH="$T/bin:$PATH" \
        bash "$here/linux/estate-status.sh" --mine --sort host 2>&1)"
is "only the owned row" "$(order "$mout")" "asess,"

echo
printf 'pass=%s fail=%s\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
