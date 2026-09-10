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

**Both outcomes occurred in the SAME PAIR of guards**, and that is what
makes the pair worth reading: identical symptom, identical cause - they were
**masking each other**, each cleaning up the evidence before the other could
see it - and opposite correct actions.

- Unproven: the vocabulary guard. A case that ISOLATES it - a row that does
  not trigger its neighbour - moved it from `113 -> 113/0` to
  `115 -> 113/2`. It had a test waiting to be written.
- Genuinely redundant: the guard that would quote a raw value. It stays,
  with both reasons written out beside it, and **no test was written for it
  on purpose**.

A second genuine redundancy, measured the same day: a length bound on a
percentage field. The bound is redundant because THE EXPRESSION already
refuses every long value except a run of leading zeros, and those
canonicalise to the right number - not because the canonicalisation catches
long values, which it does not. Measured: 1000 zeros followed by `100`
matches the expression and yields 100; 30 nines does not match at all. It
stays because it bounds WORK rather than meaning: 200 003 characters cost
90 ms in the expression and 4 ms in the canonicalisation, against about 1 ms
at the bound - so the expression IS the work - and the seam runs on a timer.

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

A mutation can also fail to apply by CRASHING IN ITS OWN SHELL - a quoting
error in the command that was supposed to edit the file. Measured the same
day, by the person who had written this rule that morning: the suite ran, the
numbers came back unchanged, and the number was reported as a cost of zero.
On disk nothing had been edited at all. **A mutation that crashed looks
exactly like a guard that is redundant**, and the difference is visible only
if you require a receipt that the file changed - not that the command
returned.

**That check is necessary and not sufficient.** A mutation that DID apply
and still cost zero is, so far, only a question: one such mutation was
neutralised by a third resolution twenty lines further down, which refused
with the same rc - rule 8's class, occurring in the middle of a mutation
round, where rule 3 sounds reassuring. Reading WHY the green is green
belongs to rule 1 and rule 8 together.

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
multi-line `case` was invisible to it - including the two live holes in one
seam, which are written across two lines each.

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

## 8. An error that is not distinguished from an answer becomes an answer.

A test that passes because a DIFFERENT guard refused the fixture first has
measured that other guard, not the one it names.

The wider form cost more than a wasted measurement. A verb called a function
that does not exist; bash returned 127; the `|| continue` beside the call read
that as "not a row I own"; so EVERY row already present in the home was
classified as no longer owned. Run in plan mode against a real estate, it
offered to delete all thirteen of one person's sessions and all seven of
another's. Without the plan mode it would have emptied two people's registers
in one line. The regression test for it costs 15 of that suite's 32
assertions.

Three shapes of the same defect turned up in a single day: a missing command
returning 127, a directory that could not be read, and a stub that wrote
nothing. All three were read as answers by the code beside them. An `|| true`,
a `2>/dev/null`, a `|| continue` - each is a place where an error and an
answer become the same value, and each needs the question asked out loud:
what does this branch mean when the thing before it did not run at all? Four attempts at one measurement in a
single day were refused by an earlier gate - a bad id form, a wrong key set,
an invalid enum value, a field count one short - and each refusal looked
like an answer. When a probe reports what you expected, check that it
reached the code you meant to measure.

## 9. Compare classes, not counts.

A suite at `162/2` and the same suite at `163/1` can hide a new failure
behind a fixed one. Read WHICH assertion fails, and compare it against the
same suite on the base branch, before calling a red known. Six name leaks
reached the main branch behind an unchanged-looking count.

## 10. A double must be able to say both things.

A test double that cannot produce the evidence its assertion looks for makes
that assertion true no matter what the code does.

Measured, in a suite written the same day: `tmux` was stubbed as `#!/bin/sh`
+ `exit 1` and nothing else. The assertion "and the session never started"
counted occurrences of the string `new-session` in the round's output - a
string a stub that writes nothing can never produce. With the entire creation
guard removed (`if mkdir ...` -> `if false`), that assertion stayed green:
`17/0` both with and without the guard.

The fix has two halves and the second is the one that is easy to miss.
Making the stub log its argv and reading the log is not enough: **a log
nothing ever writes to is as silent as no log at all**, and asserting merely
that the log FILE EXISTS repeats the mistake one layer up. The suite now
pins that the log DISCRIMINATES - a separate assertion requires the happy
path to reach `new-session` in that same log. Only then is its absence in
the failure case a measurement.

> A double must be able to say BOTH things. That it can say one is proven by
> a case in which it says the other - otherwise a silent stub has been traded
> for a silent log.

The suite totals were `17/0` before and after this fix. Nothing in the sum
changed; what changed is that the mutation can now fail. Which is rule 1
from the other side: a fix that moves no number can still be the one that
makes the suite true.
