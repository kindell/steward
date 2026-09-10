# Guards and proofs

Rules for writing a guard and for believing a test. Every one below was
measured, most of them more than once, and each names the measurement so a
reader can re-run it instead of taking this document's word.

The one sentence the rest of the file elaborates:

> **A green test is a claim about the test, not about the code, until you
> know WHY it is green.**

## 1. A zero-cost mutation means one of two things. Find out which.

Remove a guard, run the suite. If nothing fails, the guard is either
**unproven** or **genuinely redundant**, and those need opposite responses.

Measured, both kinds in one day:

- Unproven: two guards in a seam's row parser each cost nothing when
  removed. They were not weak; they were **masking each other**. One guard
  cleaned up the evidence before the other could see it, in both directions.
  Adding one case that isolates the second guard - a row that does not
  trigger the first - moved it from `113 -> 113/0` to `115 -> 113/2`.
- Genuinely redundant: a length bound on a percentage field cost nothing,
  because the canonicalisation behind it produces the right number anyway.
  It stays, because it bounds WORK rather than meaning: 200 003 characters
  cost 90 ms in the expression and 1 ms at the bound, and the seam runs on a
  timer.

Write BOTH numbers next to the guard when you settle one, so the next sweep
does not have to rediscover it. Do **not** write a test to make a zero look
better: a guard that bounds work cannot be proven by a suite that measures
meaning, and an invented assertion makes the suite lie about what it checks.

## 2. Mutate one guard at a time.

Co-located guards mask each other (see above), and a mutation that changes
two things at once cannot tell you which one the suite noticed. A sweep of
21 guards in one seam, one at a time, found 20 that cost between 1 and 22
assertions and exactly one zero - a resolution that a batch mutation would
have averaged away.

## 3. Verify that the mutation applied.

A mutation that silently failed to apply produces a green run that proves
nothing, and it looks exactly like a guard that is genuinely redundant. Two
zeros in one sweep turned out to be edits that never landed. Diff the file,
or assert the replacement happened, before you believe any number.

## 4. A guard is proven only against inputs someone thought of.

The membership guards in one seam each cost three assertions when removed -
so "is this guard tested?" answered yes. What nobody fed them was a value
with a space in it, and that is exactly where they failed. Being tested and
being correct are different properties, and a suite can only report the
first.

## 5. Substring membership is not membership.

`case " $list " in *" $needle "*)` is a substring test over a space-run, not
a membership test. A needle that spans two ADJACENT entries in list order
passes it.

The rule for when this is a hole rather than a deviation - both halves
measured:

> It is a hole exactly when the needle is **free text from outside**, or
> when the list spans **more rows than the needle's origin**.

A sweep of the product found 38 sites. Most are safe by construction - the
needle comes from a `for` over the list itself, or it is a validated slug,
or the list is loaded per row so a two-word match can only reach words that
row already owns. Four were holes, and each satisfied the rule: a field a
foreign helper writes freely, or a command-line argument, checked against a
list spanning the whole register or the whole vocabulary.

`_registry_word_in_list` (lib/registry.sh) is exact membership and refuses
whitespace. Use it.

**Where a regular expression anchored at both ends does the job, this hole
cannot open**: two values joined by a space cannot satisfy `^...$`.
Membership is where it CAN open, so membership is where the exactness has to
be spelled out. One registry loader validates five fields by SHAPE and
exactly one by membership - and the membership one is the field that leaked.

**When sweeping for this pattern, do not require `case` and the pattern on
the same line.** A line-bound grep found 17 of the 38 sites; every
multi-line `case` was invisible to it, including all four holes' siblings.

## 6. Every column can hold a secret, not just the ones that look like data.

A seam that refuses to let a value escape had that rule proven for its three
TIMESTAMP columns, because those look like fields that carry something. The
column holding a word from a closed vocabulary had no such test - and the
guard that refuses a foreign word is the same line that WRITES THE NOTE
ABOUT that word, so the only route out for the value ran through the line
that exists to stop it. Changing the note's complaint to include the raw
value cost 0 of 69 assertions; a helper with a field-order bug can put a
credential in any column, so every column needs the case.

## 7. Broadening a check's sweep does not change the question it asks.

A guard that asks "does every library a SHIPPED FILE SOURCES travel with
it?" cannot answer "is every library in the repo shipped by somebody?" The
two differ precisely for a file with no caller yet - which is every new seam
on the day it lands, so each one is invisible to that guard exactly once.

When a guard misses something, ask which question it answers before widening
its sweep. Often the answer is a second guard asking the inverse question,
not a bigger version of the first.

The shape of what slips through is worth naming: **the library with no
caller yet**. It is the newest file, the one somebody is still wiring in,
and nothing sources it - so a guard that starts from callers has nothing to
find. Its absence surfaces later as a deployed host dying on a source line,
rc 78, in a journal nobody reads.

## 8. A test double carries the bug it simulates, or it proves nothing.

Related: a test that passes because a DIFFERENT guard refused the fixture
first has measured that other guard. Four attempts at one measurement in a
single day were refused by an earlier gate - a bad id form, a wrong key set,
an invalid enum value, a field count one short - and each refusal looked
like an answer. When a probe reports what you expected, check that it
reached the code you meant to measure.

## 9. Compare classes, not counts.

A suite at `162/2` and the same suite at `163/1` can hide a new failure
behind a fixed one. Read WHICH assertion fails, and compare it against the
same suite on the base branch, before calling a red known. Six name leaks
reached the main branch behind an unchanged-looking count.
