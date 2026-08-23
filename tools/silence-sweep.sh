#!/bin/bash
# tools/silence-sweep.sh — find the shapes that turn a failure into a zero.
#
# WHY IT EXISTS. docs/tysta-fel.md in the estate describes this class of fault in
# two thousand lines, and describing it has not stopped it happening. On
# 2026-08-23 alone the fleet produced: a timer reporting `active` with nothing
# scheduled, a supervisor reporting `0 rigs ensured` for a directory it could not
# read, a checkout reporting `0 behind` against a stale ref, a ping marked
# delivered that was never received, and a test reporting `pass=14 fail=0` on an
# empty tree. Every one of them answered a question it had not measured.
#
# THIS TOOL DOES NOT JUDGE. It finds SHAPES, and a shape is not a bug: a great
# many of these sites are correct, because sometimes absence really is emptiness.
# What the shapes have in common is that they make the two indistinguishable at
# the point where the code decides. Which of the three a site is — legitimate,
# should refuse, or needs a third outcome — is a reading, and the reading is
# human.
#
# THE RANKING IS THE ONLY OPINION IT HAS. The same shape is more dangerous in a
# gate, an alarm or a supervisor than in a print routine, because that is where a
# swallowed error becomes a false statement of health rather than a missing line
# of output.
#
# Usage:
#   tools/silence-sweep.sh              ranked summary
#   tools/silence-sweep.sh --list       every site, file:line, with context
#   tools/silence-sweep.sh --count      just the totals, for a trend line
#
# Exit: always 0. This is an inventory, NOT a gate. A gate against an existing
# backlog gets switched off the same day; it becomes a gate when the backlog is
# clear, and not before.

set -uo pipefail
HERE="$(CDPATH= cd -- "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$HERE" || exit 78

MODE="${1:---summary}"

# ── THE SHAPES ─────────────────────────────────────────────────────────────
# Each is <key>::<description>::<regex>. THE SEPARATOR IS :: AND NOT |, because
# both the regexes AND the descriptions contain pipes — `|| true` is one of the
# shapes being described. With | as the separator the field split mid-pattern and
# two shapes reported zero sites while eleven existed: the sweep was silent about
# its own subject matter, which is the exact fault it exists to find.
#
# The estate's job-status.sh carries this lesson in a comment written weeks ago.
# Reading it did not prevent repeating it; the counter that said 0 did.
#
# AND THE PATTERNS DO NOT EXCLUDE PIPES EITHER. The first version used [^|]* to
# avoid running across a shell pipe, and thereby missed every site whose own
# pattern contained one — `grep -ciE 'syntax error|unexpected token'` was the
# only instance of one shape and it was invisible. Three separate bugs in this
# file, all the same root: a pipe inside the content, in a place that treated the
# pipe as structure.
#
# The regexes are otherwise deliberately narrow: a sweep that cries wolf gets
# ignored, which is the same failure one level up.
SHAPES='
absent-is-empty::a file test that succeeds when the thing is missing::\[ (! )?-[dferxs] [^]]*\] \|\| (return 0|continue|:)
swallowed-then-tested::stderr discarded, then the empty result used as the answer::2>/dev/null.*\|\| (echo|true|:)
measurement-forgiven::a measurement whose failure is forgiven::\|\| true[[:space:]]*$
unmatched-glob::a loop over a glob that may match nothing::for [a-zA-Z_]+ in [^;]*\*[^;]*; do
count-of-absent::a count taken on a path that may not exist::(grep -c|wc -l).*2>/dev/null
'

# ── WHERE IT MATTERS ───────────────────────────────────────────────────────
# A site's weight is its FILE's job, not its own cleverness. These are the files
# whose output is read as a statement about the world: gates, supervision,
# alarms, deploys. Everything else is presentation.
CRITICAL='hub/lib.sh session-supervisor-linux.sh deploy-apply.sh deploy-self.sh registry.sh job-runner.sh browser-stack.sh install-user-jobs.sh bus-send bus-read'

is_critical() { case " $CRITICAL " in *" $(basename "$1") "*) return 0 ;; esac; return 1; }

files() { git ls-files 2>/dev/null | grep -E '\.(sh)$|/(bus-send|bus-read|enroll)$' | grep -v '^test/' ; }

tot_crit=0; tot_rest=0
OUT="$(mktemp)"; trap 'rm -f "$OUT"' EXIT

printf '%s\n' "$SHAPES" | while IFS= read -r line; do
  key="${line%%::*}"; rest="${line#*::}"; desc="${rest%%::*}"; rx="${rest#*::}"
  [ -n "${key:-}" ] || continue
  files | while read -r f; do
    [ -f "$f" ] || continue
    grep -nE "$rx" "$f" 2>/dev/null | while IFS=: read -r ln rest; do
      w="rest"; is_critical "$f" && w="CRIT"
      printf '%s\t%s\t%s\t%s\t%s\n' "$w" "$key" "$f" "$ln" "$(printf '%s' "$rest" | sed 's/^[[:space:]]*//' | cut -c1-92)"
    done
  done
done > "$OUT"

C=$(grep -c '^CRIT' "$OUT" 2>/dev/null || echo 0)
R=$(grep -c '^rest' "$OUT" 2>/dev/null || echo 0)

case "$MODE" in
  --count)
    printf '%s\t%s\t%s\n' "$(date -u +%FT%TZ)" "$C" "$R"
    ;;
  --list)
    for w in CRIT rest; do
      grep "^$w" "$OUT" | sort -t"$(printf '\t')" -k3,3 -k4,4n | while IFS="$(printf '\t')" read -r _ key f ln txt; do
        printf '%-6s %-22s %s:%s\n        %s\n' "$w" "$key" "$f" "$ln" "$txt"
      done
    done
    ;;
  *)
    echo "== silence sweep =="
    printf '%s\n' "$SHAPES" | while IFS= read -r line; do
      key="${line%%::*}"; rest="${line#*::}"; desc="${rest%%::*}"
      [ -n "${key:-}" ] || continue
      c=$(awk -F"\t" -v k="$key" '$2==k && $1=="CRIT"' "$OUT" | wc -l | tr -d ' ')
      r=$(awk -F"\t" -v k="$key" '$2==k && $1=="rest"' "$OUT" | wc -l | tr -d ' ')
      printf '  %-22s %3s in gates/supervision  %3s elsewhere   %s\n' "$key" "$c" "$r" "$desc"
    done
    echo
    printf '  %s sites where the output is read as a statement about the world\n' "$C"
    printf '  %s sites elsewhere\n' "$R"
    echo
    echo "  A shape is not a bug. Each site is one of three:"
    echo "    LEGITIMATE     absence really is emptiness"
    echo "    SHOULD REFUSE  absence means broken, and the caller must be told"
    echo "    THIRD OUTCOME  absence is neither — it needs its own status, not a zero"
    echo
    echo "  --list for every site, --count for a trend line."
    ;;
esac
