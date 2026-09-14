#!/bin/bash
# test/produktytan-form.test.sh - a measurement attribution in a comment names a PLATFORM and a
# DATE, never a host. The product cannot carry the estate's name list, so it cannot know that
# "butler" is a machine - but it can know the SHAPE that carried machine names into the product
# twice on 2026-09-12: "(<one bare word> <ISO date>)" where the word is not a measurement verb.
# "(butler 2026-09-12)" and "(basement 2026-09-11)" match; "(a darwin host, 2026-09-12)",
# "(measured 2026-09-07)" and "(PR #6, 2026-09-11)" do not. The allowlist is small and explicit.
set -u
here="$(CDPATH= cd -- "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
pass=0; fail=0
ok()  { pass=$((pass+1)); printf '  ok   %s\n' "$1"; }
bad() { fail=$((fail+1)); printf '  FAIL %s\n     %s\n' "$1" "${2:-}"; }
is()  { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "wanted '$3', got '$2'"; fi; }
# THE SHAPE: an opening paren, ONE bare word (letters, digits, hyphen), a space, an ISO date, a
# closing paren - and NO comma, because a comma makes the left half a phrase, not a host.
PAT='\(([A-Za-z][A-Za-z0-9-]*) (20[0-9]{2}-[0-9]{2}-[0-9]{2})\)'
ALLOW='measured|verified|since|rev|until|before|after|from|by'
# ONE MATCH AT A TIME, NOT ONE LINE AT A TIME. The first cut filtered the WHOLE LINE through the
# allowlist, so a line carrying an allowed parenthesis AND a host one passed - "(measured
# 2026-09-07) and (butler 2026-09-12)" was silent. That is rule 5 in the suite that cites rule 5:
# an allowed substring somewhere on the line is not membership for the match beside it, and the
# text is free prose written by an author. Reproduced on main 2026-09-14 with this file's own PAT
# and ALLOW before the rewrite.
#
# THE FORM IS THE MACHINE STEWARD'S, from their independent fix of the same advisor finding
# (session_01XKcqbwVu6NHzG48xGSN7TX, 691fd47). Two of us built this in parallel because the review
# went out without an owner; theirs is the better half and is kept. `grep -noE` extracts every
# match WITH its line number in one pipe - no shell loop - and it reports one line PER MATCH: two
# host words on one line are two hits, which is what a person reading the report wants; the first
# cut collapsed them to one.
#
# THE ANCHORS ARE ZERO-COST TODAY, BOTH OF THEM, and this is measured rather than assumed: removing
# the trailing $, and then removing ^ as well, leaves the suite at 11/0. `grep -o` emits exactly
# one whole match per line, and PAT's halves are a single bare word and a fixed-width date, so an
# allowed word can only sit at the start and nothing can follow the closing paren. They are kept
# for the day PAT admits a wider left or right half - rule 1's second branch, said out loud. I had
# written in a commit message that mine was zero-cost while this form's anchoring was load-bearing;
# that was a comparison I had not measured, and it was wrong. What is actually better here is the
# single pipe and the per-match report.
shape_hits() { LC_ALL=C grep -noE "$PAT" "$1" 2>/dev/null | grep -vE "^[0-9]+:\(($ALLOW) 20[0-9]{2}-[0-9]{2}-[0-9]{2}\)$" ; }

echo "== 1. the detector, measured before it measures =="
FX="$(mktemp -d)"; trap 'rm -rf "$FX"' EXIT
printf '# seen (butler 2026-09-12) here\n'            > "$FX/a"; is "1a a bare host word before a date is flagged"        "$(shape_hits "$FX/a" | wc -l | tr -d ' ')" "1"
printf '# seen (a darwin host, 2026-09-12) here\n'    > "$FX/b"; is "1b a platform phrase with a comma is not"           "$(shape_hits "$FX/b" | wc -l | tr -d ' ')" "0"
printf '# (measured 2026-09-07) and (verified 2026-08-02)\n' > "$FX/c"; is "1c measurement verbs are allowed"           "$(shape_hits "$FX/c" | wc -l | tr -d ' ')" "0"
printf '# (PR #6, 2026-09-11) and (rev 5, 2026-08-19)\n' > "$FX/d"; is "1d a number before the date, with a comma, is not" "$(shape_hits "$FX/d" | wc -l | tr -d ' ')" "0"
printf '# (basement 2026-09-11)\n'                    > "$FX/e"; is "1e another host word is flagged"                   "$(shape_hits "$FX/e" | wc -l | tr -d ' ')" "1"
# THE CONTROL THE FIRST CUT LACKED: allowed and forbidden on the SAME LINE. Without it the
# whole-line filter looked correct - 1a-1e each carry one kind only, and every one of them passed
# while the mixed line went through untouched.
printf '# (measured 2026-09-07) and (butler 2026-09-12)\n' > "$FX/f"; is "1f an allowed paren does not vouch for a host paren beside it" "$(shape_hits "$FX/f" | wc -l | tr -d ' ')" "1"
printf '# (by 2026-09-12) plus (basement 2026-09-11)\n'    > "$FX/g"; is "1g ... in either order, anywhere on the line"                 "$(shape_hits "$FX/g" | wc -l | tr -d ' ')" "1"
printf '# (butler 2026-09-12) and (measured 2026-09-07)\n' > "$FX/h"; is "1h ... host first, allowed second"                            "$(shape_hits "$FX/h" | wc -l | tr -d ' ')" "1"
printf '# (measured 2026-09-07) and (verified 2026-08-02) and (since 2026-01-01)\n' > "$FX/i"; is "1i three allowed on one line stay silent" "$(shape_hits "$FX/i" | wc -l | tr -d ' ')" "0"
printf '# (butler 2026-09-12) and (basement 2026-09-11)\n' > "$FX/j"; is "1j two host words on one line are TWO hits, one per match"    "$(shape_hits "$FX/j" | wc -l | tr -d ' ')" "2"

echo "== 2. the product surface carries no such shape =="
hits=0; list=""
for f in $(cd "$here" && git ls-files bin lib linux runtime watch tools test 2>/dev/null); do
  [ -f "$here/$f" ] || continue
  case "$f" in test/produktytan-form.test.sh) continue ;; esac
  h="$(shape_hits "$here/$f")"; [ -z "$h" ] && continue
  n="$(printf '%s\n' "$h" | wc -l | tr -d ' ')"; hits=$((hits+n)); list="$list
    $f: $(printf '%s\n' "$h" | head -2 | cut -c1-90 | tr '\n' ' ')"
done
if [ "$hits" -eq 0 ]; then ok "2a no '(<host> <date>)' attribution in the product"; else bad "2a $hits attribution(s) name a host instead of a platform:$list" ; fi

printf '\n  %d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
