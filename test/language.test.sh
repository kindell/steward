#!/bin/bash
# test/language.test.sh — the product is written in English, and this is how we
# know rather than believe it.
#
# WHY IT EXISTS. This code was extracted from a private estate whose prose is
# Swedish. The extraction left the product bilingual in the worst possible way:
# an English README over a Swedish interior. 366 of 504 comment lines were
# Swedish while the front page promised an international tool.
#
# That is not cosmetic, for two reasons the estate learned the hard way:
#
#   Error messages are interface. "REFUSED: the checkout is AHEAD of
#   origin/main" is the first thing a stranger sees when something goes wrong,
#   and refusing is the core of this design. A tool that refuses in a language
#   the reader does not have has not refused; it has crashed.
#
#   The comments are the largest asset here. They carry measurements, dates and
#   the reasoning behind each gate. An asset nobody can read is not an asset.
#
# WHY WORD BOUNDARIES, MEASURED. The first counter written for this job matched
# `each`, `and` and `denied` as Swedish, by matching short substrings inside
# them rather than whole words —
# and reported 241 remaining lines when the truth was 211. A measurement that
# cannot tell two languages apart cannot report progress in either. Every
# pattern below is anchored with \b, and the control groups at the end prove
# both directions: that Swedish is caught, and that ordinary English prose is
# not.
#
# WHAT IT DOES NOT COVER, deliberately. File names that carry the estate's own
# vocabulary (a session unit named after the estate, a directory and two scripts
# named in Swedish) are listed in the manifest's header as a separate migration:
# renaming them touches systemd unit names on running hosts. A guard that
# failed on them today would be a guard nobody can satisfy, and a guard nobody
# can satisfy gets disabled.
#
# Exit code: 0 = English throughout · 1 = at least one file carries Swedish

set -u
HERE="$(CDPATH= cd -- "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$HERE" || exit 70
pass=0; fail=0
ok()  { pass=$((pass+1)); }
bad() { echo "FAIL: $1"; fail=$((fail+1)); }

# ── THE MARKERS ────────────────────────────────────────────────────────────
# Swedish function words and the domain vocabulary this codebase actually used.
# Function words carry the load: prose in a language is unavoidably full of
# them, while a single borrowed noun is not evidence of anything.
#
# Anchored with \b at both ends. Without that anchoring this guard reports
# English as Swedish, which is worse than reporting nothing: it teaches the
# reader to ignore it.
# MEASURED EXCLUSION: the Swedish word "proven" (definite plural of "test") is
# also the English word "proven", and no amount of anchoring separates them —
# it is a whole-word collision, not a substring one. It flagged a purely
# English line reading "what must be proven here". Removed as a marker: the
# other test-related words carry that load without the false positive.
#
# A second collision is worth recording even though it does not apply here: a
# customer name that is also a common Swedish noun cannot be distinguished from
# prose by pattern at all, because compounds attach with a hyphen and word
# boundaries still match.
SWEDISH='\b(och|inte|som|för|att|är|den|det|kan|ska|när|från|över|måste|vara|blir|finns|görs|hela|varje|ingen|inget|alltså|eftersom|därför|vägra|vägran|vägrar|boet|källa|källan|källor|värd|värden|filen|raden|rader|hemmet|hemmen|siffran|mätt|mäter|mätning|klarade|föll|provet|sviten|utan|efter|innan|redan|bara|både)\b'

# TRAILING COMMENTS ARE COMMENTS TOO. The first version of this helper swept
# only WHOLE-LINE comments (`^\s*#`), and reported a clean tree while seven
# trailing comments carried Swedish — including one inside this very file. A
# guard that cannot see half the comments in a shell script reports the half it
# looked at and calls it the whole.
#
# QUOTED SPANS ARE REMOVED FIRST, and this is the load-bearing part. A `#`
# inside a string literal is data, not a comment: control group 1 below writes a
# deliberately foreign-language sample through printf, and the deploy-core suite
# writes a fixture whose name says it holds nothing but comments. Sweeping those
# would make the guard fail on the very samples it needs in order to prove it
# works — the guard would forbid its own control group. (This paragraph was
# itself flagged on the first run, for quoting the sample verbatim. Rewritten,
# never exempted: an exemption list measures the list instead of the language.)
#
# ONLY THE TEXT AFTER THE `#` IS SWEPT, never the code before it. Whether an
# identifier is named in Swedish is a naming question; this guard is about the
# language of documentation, and mixing the two makes it unsatisfiable while the
# rename migration is still open (control group 4 pins that down).
swedish_lines() { # <file> -> count of comment lines carrying Swedish markers
  {
    grep '^[[:space:]]*#' "$1"
    grep -v '^[[:space:]]*#' "$1" \
      | sed "s/'[^']*'//g; s/\"[^\"]*\"//g" \
      | sed -n 's/[^#]*#/#/p'
  } 2>/dev/null | grep -ciE "$SWEDISH" || true
}

# ── THE SWEEP ──────────────────────────────────────────────────────────────
# Every TRACKED file, not a hand-picked list. A guard that measures a subset
# chosen by whoever last edited the code measures what they already believe —
# the estate has a scar named exactly that: seven suites of thirty-two called
# "the golden master" while two were red.
echo "== the sweep =="
files=0; dirty=0; total=0
while IFS= read -r f; do
  case "$f" in
    LICENSE|*.md) continue ;;   # LICENSE is boilerplate; prose files are swept below
  esac
  [ -f "$f" ] || continue
  files=$((files+1))
  n="$(swedish_lines "$f")"
  if [ "$n" -gt 0 ]; then
    dirty=$((dirty+1)); total=$((total+n))
    printf '  SWEDISH %-32s %s line(s)\n' "$f" "$n"
  fi
done <<EOF
$(git ls-files 2>/dev/null)
EOF

echo "  swept $files file(s); $dirty still carry Swedish ($total lines)"
# THE COUNT IS PRINTED WHETHER OR NOT IT IS ZERO. A guard that only speaks when
# it fails cannot be distinguished from a guard that never ran — the estate's
# catalogue calls that "zero observations are not zero problems".
if [ "$dirty" -eq 0 ]; then ok; else bad "$dirty file(s) carry Swedish ($total lines)"; fi

# ── SWEEP TWO: DIACRITICS, ANYWHERE IN THE FILE ────────────────────────────
# A SECOND, INDEPENDENT INSTRUMENT. The marker sweep above reads comments and
# matches a word list; both of those are choices, and both can be wrong. This
# one reads EVERY line — code, string literals, assertion messages — and asks a
# question with no judgement in it: does this file contain a letter English does
# not have?
#
# It exists because the marker sweep reported a clean tree twice while it was
# not. It missed trailing comments (structure), and it missed short Swedish
# lines whose particular words were not on the list (vocabulary). Two blind
# spots of two different kinds is the signature of an instrument being trusted
# past what it measures — so the answer is a second instrument that fails
# differently, not a longer word list.
#
# ITS BLIND SPOT, STATED: transliterated Swedish (a for å, o for ö) carries no
# diacritic and passes this sweep untouched. The marker sweep catches those. The
# two are complementary BY CONSTRUCTION, and neither is sufficient alone —
# which is the point of having both.
#
# ZERO FALSE POSITIVES BY CONSTRUCTION: no English word contains å, ä or ö. A
# guard with this property can be trusted at a glance, which is exactly what the
# marker sweep cannot be.
#
# ── THE TWO EXEMPTIONS, AND WHY THEY ARE NOT THE BEGINNING OF A LIST ───────
#
# This goal's own abandon-criterion reads: give up on the guard if it cannot
# separate the languages without an exemption list that grows with every file.
# Two files cannot be swept, for reasons that are structural rather than matters
# of taste, and the difference is worth being precise about:
#
#   test/language.test.sh — THIS FILE. It cannot hunt a character without
#   naming it, and it cannot show that it catches Swedish without holding a
#   sample of Swedish. A dictionary is not a violation of the language it
#   defines. This exemption can never generalise to a second file, because
#   there is only one guard.
#
#   tools/run-tests.sh — it PARSES the estate's test output, and that output's
#   format is a Swedish sentence reporting how many cases passed and how many
#   fell. The estate stays Swedish deliberately: it is the language its people
#   work in. Rewriting the pattern would not translate anything; it would stop
#   the product from reading the estate's suites at all. This is a foreign
#   format being consumed, the same as parsing any external tool's output.
#
# THE LIST'S LENGTH IS ITSELF ASSERTED, immediately below. That is what keeps
# this from being the failure mode the goal warns about: a third entry cannot be
# added quietly to make a red run green — it fails the count and has to be
# argued for in a diff. An exemption list nobody measures becomes the thing
# being measured; this one measures back.
DIA_EXEMPT="test/language.test.sh tools/run-tests.sh"
n_exempt=0; for _e in $DIA_EXEMPT; do n_exempt=$((n_exempt+1)); done
[ "$n_exempt" -eq 2 ] && ok || bad "the diacritic exemption list has grown to $n_exempt — each entry needs a structural reason, not a convenience"

echo "== diacritics =="
dia_dirty=0; dia_total=0
for f in $(git ls-files 2>/dev/null | grep -v '^LICENSE$'); do
  [ -f "$f" ] || continue
  case " $DIA_EXEMPT " in *" $f "*) continue ;; esac
  n="$(grep -c '[åäöÅÄÖ]' "$f" 2>/dev/null || true)"
  [ "${n:-0}" -gt 0 ] && {
    printf '  DIACRITIC %-30s %s line(s)\n' "$f" "$n"
    dia_dirty=$((dia_dirty+1)); dia_total=$((dia_total+n))
  }
done
echo "  files carrying å/ä/ö: $dia_dirty ($dia_total lines), $n_exempt exempt"
if [ "$dia_dirty" -eq 0 ]; then ok; else bad "$dia_dirty file(s) carry Swedish letters ($dia_total lines)"; fi

# THE EXEMPTIONS ARE NOT A FREE PASS FOR THE MARKER SWEEP. Both files are still
# swept for Swedish COMMENTS above — only the diacritic sweep spares them, and
# only because their Swedish sits in patterns and samples rather than in prose.
# An exemption that silenced every instrument at once would let the guard's own
# documentation rot in the one file nobody may edit carelessly.

# ── SWEEP THREE: TRANSLITERATED SWEDISH, ANYWHERE IN THE FILE ──────────────
# THE THIRD BLIND SPOT, and the one that made this guard say a clean tree while
# a whole suite was Swedish. The two instruments above miss the same case from
# opposite sides:
#
#   the marker sweep reads COMMENTS, and skips string literals
#   the diacritic sweep reads EVERY line, but only catches å/ä/ö
#
# Swedish written without diacritics, inside an assertion string, is invisible
# to both. MEASURED 2026-08-19: test/deploy-core.test.sh carried 26 such lines —
# its section headings and most of its assertion messages — while this guard
# reported the whole product as English. Those strings are not decoration: they
# are what a stranger reads when the suite goes red. (The samples are not quoted
# here; the marker sweep above reads this file, and a dictionary that spells out
# its own entries fails itself. Fourth time in one day that a guard caught its
# own documentation — the answer each time was to rewrite the line.)
#
# THE TOKENS BELOW ARE ONLY THE UNAMBIGUOUS ONES. The first list written for
# this sweep counted `for`, `matt` and `hem`, and reported 139 lines when the
# truth was 31 — the exact mistake this file's header already records about
# `each` and `denied`, made a second time by the same hand. Every token here was
# checked to be a word English does not have. That is why the most obvious
# Swedish function words are absent from it: the shortest and commonest ones
# collide with English words, and a guard that cries wolf gets turned off. They
# are not written out here either, for the same reason the samples above are
# not — this file is swept by the marker instrument above.
#
# The two files exempted from the diacritic sweep are exempt here for the same
# reasons — one is this dictionary, the other parses the estate's Swedish output.
TRANSLIT='\b(vagran|vagrar|vagra|harkomst|harkomsten|kallor|kallan|smutsig|smutsigt|tradet|karnan|navet|ovidkommande|paverkar|foll|klarade|provet|sviten|maste|fran|utan|inte|nagot|nagon|aldrig|varje|hemmet|raden|filen|skulle|tva|korning|korningen|sokvag|sokvagen|namnger|anvands|forbi|tyst|saknad|saknat|okand)\b'
echo "== transliterated =="
tr_dirty=0; tr_total=0
for f in $(git ls-files 2>/dev/null | grep -v '^LICENSE$'); do
  [ -f "$f" ] || continue
  case " $DIA_EXEMPT " in *" $f "*) continue ;; esac
  n="$(grep -ciE "$TRANSLIT" "$f" 2>/dev/null || true)"
  [ "${n:-0}" -gt 0 ] && {
    printf '  TRANSLIT %-31s %s line(s)\n' "$f" "$n"
    tr_dirty=$((tr_dirty+1)); tr_total=$((tr_total+n))
  }
done
echo "  files carrying transliterated Swedish: $tr_dirty ($tr_total lines)"
if [ "$tr_dirty" -eq 0 ]; then ok; else bad "$tr_dirty file(s) carry transliterated Swedish ($tr_total lines)"; fi

# Markdown prose is swept separately: the README is the front page, and a
# stranger reads it before anything else.
echo "== prose =="
md_dirty=0
for f in $(git ls-files '*.md' 2>/dev/null); do
  [ -f "$f" ] || continue
  n="$(grep -ciE "$SWEDISH" "$f" || true)"
  [ "$n" -gt 0 ] && { printf '  SWEDISH %-32s %s line(s)\n' "$f" "$n"; md_dirty=$((md_dirty+1)); }
done
echo "  markdown files carrying Swedish: $md_dirty"
if [ "$md_dirty" -eq 0 ]; then ok; else bad "$md_dirty markdown file(s) carry Swedish"; fi

# ── CONTROL GROUPS — BOTH DIRECTIONS ───────────────────────────────────────
# A guard that has never fired has not shown that it can, and a guard that
# fires on everything is worse than none.
echo "== control groups =="
FX="$(mktemp -d)"; trap 'rm -rf "$FX"' EXIT

# 1. Swedish IS caught.
printf '# Den här raden är svensk och ska fällas av vakten.\n' > "$FX/sv.sh"
n="$(swedish_lines "$FX/sv.sh")"
[ "$n" -gt 0 ] && ok || bad "control group: Swedish was NOT caught"

# 2. English is NOT caught — including the exact words that fooled the first
#    counter. This is the case that matters: without \b anchoring, all three of
#    these match.
cat > "$FX/en.sh" <<'ENGLISH'
# The caller maps 127 to "sudo denied or missing" and each row is measured.
# A gate that measures a subset of what is deployed does not guard the deploy.
# Refuse rather than guess: every gate fails closed, and the count is printed.
ENGLISH
n="$(swedish_lines "$FX/en.sh")"
[ "$n" -eq 0 ] && ok || bad "control group: English prose was flagged as Swedish ($n lines) — the anchoring is broken"

# 3. A Swedish word inside an English word must NOT trigger. "denied" contains
#    a Swedish article as a substring; "each" and "banned" likewise. If any of these
#    fire, the guard is matching substrings and will cry wolf until disabled.
printf '# denied, each, banned, format, informed, understand, standard\n' > "$FX/sub.sh"
n="$(swedish_lines "$FX/sub.sh")"
[ "$n" -eq 0 ] && ok || bad "control group: substring match inside English words ($n) — \\b anchoring failed"

# 4. Code lines are not prose. A shell variable named in Swedish is a naming
#    question, not a language-of-documentation question, and this guard is about
#    the latter. Mixing them would make the guard unsatisfiable while the
#    rename migration is still open.
printf 'BOET="/tmp/x"\necho "$BOET"\n' > "$FX/code.sh"
n="$(swedish_lines "$FX/code.sh")"
[ "$n" -eq 0 ] && ok || bad "control group: a non-comment line was swept ($n)"

# 5. A TRAILING comment IS caught. Seven of these hid from the first version of
#    this guard, and the tree was reported clean while they sat there.
printf 'X=1   # den här kommentaren sitter efter kod och ska fällas\n' > "$FX/trail.sh"
n="$(swedish_lines "$FX/trail.sh")"
[ "$n" -gt 0 ] && ok || bad "control group: a TRAILING comment was not swept — the guard sees only whole-line comments"

# 6. A `#` inside a STRING LITERAL is data, not a comment. Both of this repo's
#    suites write Swedish fixture lines that way, and one of them is this file's
#    own control group 1 — a guard that swept string literals would fail on the
#    sample that proves it works.
printf 'printf %s > "$out"\n' "'# Den här raden är svensk och ska fällas av vakten.\\n'" > "$FX/lit.sh"
n="$(swedish_lines "$FX/lit.sh")"
[ "$n" -eq 0 ] && ok || bad "control group: Swedish inside a string literal was swept as a comment ($n)"

# 7. Code BEFORE a trailing comment is not swept. The comment is prose and is
#    measured; the identifiers are a naming question and are not.
printf 'kor_provet_utan_bo "$X"   # this trailing comment is entirely English\n' > "$FX/mixed.sh"
n="$(swedish_lines "$FX/mixed.sh")"
[ "$n" -eq 0 ] && ok || bad "control group: Swedish identifiers before an English trailing comment were swept ($n)"

# 8. TRANSLITERATED Swedish in a STRING LITERAL is caught. This is the case that
#    passed both other instruments: no diacritic, and not a comment.
printf 'check "%s" [ "$rc" -eq 0 ]\n' 'kallan foll utan att provet klarade' > "$FX/tr.sh"
n="$(grep -ciE "$TRANSLIT" "$FX/tr.sh")"
[ "$n" -gt 0 ] && ok || bad "control group: transliterated Swedish in a string was NOT caught"

# 9. AND THE DIRECTION THAT DECIDES WHETHER THE SWEEP SURVIVES: ordinary English
#    must not trip it. The first token list written for this sweep counted `for`,
#    `matt` and `hem` and reported 139 lines against a true 31 — if this case
#    ever fails, the list has grown greedy and the sweep is measuring the list.
cat > "$FX/tr_en.sh" <<'ENGLISH'
check "the stage is not in a temp directory" [ -d "$s" ]
# A gate that fails closed for a missing manifest, a dirty source, or a home
# that does not exist. The matter is settled by measurement, not by memory.
echo "REFUSED: the checkout is AHEAD of origin/main"
ENGLISH
n="$(grep -ciE "$TRANSLIT" "$FX/tr_en.sh")"
[ "$n" -eq 0 ] && ok || bad "control group: English prose flagged as transliterated Swedish ($n lines) — the token list is greedy"

echo

# --- A VARIABLE NAME MUST NOT TOUCH A MULTIBYTE CHARACTER (2026-09-01) -------
# An unbraced expansion glued to the arrow parsed fine under UTF-8 locales and died with "unbound
# variable _mn<garbage>" under a single-byte locale, where the arrow's first
# byte (0xE2, a-circumflex in Latin-1) counts as a LETTER and bash 3.2 reads
# it into the variable name. Locale-dependent parsing is the worst kind of
# latent: it passes every suite on the machine that wrote it. Braces make the
# boundary explicit under every locale — so an unbraced expansion directly
# followed by a high byte is refused here, wholesale.
_mb_hits="$(perl -ne 'print "$ARGV:$.: $_" if /\$[A-Za-z_][A-Za-z0-9_]*[\x80-\xFF]/' $(git -C "$HERE" ls-files '*.sh' 'bin/steward' 'job-run.sh' 2>/dev/null | sed "s|^|$HERE/|") 2>/dev/null)"
if [ -n "$_mb_hits" ]; then
  bad "an unbraced \$var touches a multibyte character (use \${var}):" "$_mb_hits"
else
  ok "no unbraced expansion touches a multibyte character"
fi

printf 'pass=%s fail=%s\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
