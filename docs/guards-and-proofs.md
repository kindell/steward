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

A third answer turned up later the same day: **dormant**. A guard that refuses
when a library is missing costs nothing while the library is loaded - its
value shows only in the combination where something ELSE is removed. Measured
in three combinations rather than one: without the source line and without the
guard, the probe reported PASS while measuring nothing; without the source but
with the guard, it failed honestly; with both, it measured the row. A zero in
the third row of that table is not the same claim as a zero in the first.

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

And a mutation can apply cleanly and still be a no-op. One replaced `measured`
at end-of-line in a verb whose rows carry a trailing tab: the edit was in the
file, the receipt said so, and it changed nothing the code did. **Applied is
not the same as effective.** The receipt to require is a behaviour that
changed, not a file that did - which usually means running the mutated code
once by hand and looking at its output before trusting any number.

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

## 8b. A retrospective audit can measure its author instead of its subject.

A message lost a whole sentence in transmission: it was written in backticks
inside a double-quoted shell string, so the shell expanded it away before the
sending tool ever saw the argument. The sender saw an rc error that reads as
noise; the receiver got a text with a hole and no way to know anything was
missing.

The instructive part is the audit that followed. 712 sent messages were swept
for the same damage with a heuristic - lines that stop abruptly after a colon -
and it returned 462 hits. A sample showed every one of them was an ordinary
heading. The heuristic had measured the author's writing style, not lost
content.

Two rules fall out of that, and the second is the sharper one:

- **A sweep that cannot distinguish its target from the author's own habits
  should not report a number at all.** 462 looked like a finding and was a
  self-portrait.
- **Some damage cannot be audited afterwards at any effort**, because the
  evidence is destroyed before the artefact exists - here, the expansion
  happens before the message is composed. When that is true, the check has to
  live at the moment of creation, and no amount of later diligence substitutes
  for it.

What the same sweep COULD measure honestly: 78 of those 712 messages carry
backticks that survived, so the hazard is not uniform and the mechanism was
not understood. That was reported as an open question rather than as safety.

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

## 11. A fixture that overrides one variable must override everything that outranks it.

A suite stood at `82/101` on one machine and `96/87` on another with no
difference in the code. The fixture builds a fake home and exports
`HOME="$T/home"` into the round - and every path in it was derived instead
from `STEWARD_ESTATE_ROOT`, which the resolver reads BEFORE `$HOME` and which
happened to be set in one author's shell profile. Fourteen assertions were
measuring a shell.

The shape is not "an environment variable leaked". It is narrower and worth
naming: **the fixture overrode the variable it knew about, and the code it
tests consults a variable that WINS over that one.** Overriding `HOME` looks
like total control of where the code will look, and it is total control only
until somebody adds a higher-priority resolver - which is exactly what an
estate resolver is for.

Both halves of the remedy are needed and the second is the one that is easy
to skip:

- Clear or pin every variable in the resolver's precedence chain, not just
  the one at the bottom of it. **DERIVE that list from the resolver; do not
  type it.** Measured the same day, twice. This rule's author wrote four
  names by hand and shipped them to five suites. Another estate ran the same
  two-way measurement on their own three suites and found one infected - by a
  FIFTH variable, `STEWARD_ACCOUNT_DIR` alone, `26/0` against `17/9`, while
  the three that had bitten here changed nothing there. Counting what the
  library actually reads gave FIFTEEN overrides that bypass `$HOME`. The
  person who writes the list from memory writes the variables they personally
  ran into; a fixture that clears four of fifteen is fixed against today's
  symptom, not against the class. A helper that greps the list out of the
  library carries the sixteenth for free - and it must REFUSE when the grep
  finds fewer names than it expects, because a rewritten expression would
  otherwise silence the whole protection without turning a single test red.
  Silently clearing nothing looks exactly like having cleared everything.
- **The same rule holds for `PATH`, and closing it has a platform trap.** A
  fixture that runs its probe with `"$FX/bin:$PATH"` has overridden the front
  of the path and left the back to the host: on a host that has the real tool
  behind the stub, the section meant to exercise the fallback measures the
  host instead. Measured 2026-09-12 - green on darwin, which has no `ss` and
  so could never reach the failure branch, `14/5` on Linux, which could. The
  fix is a PATH of one directory. But the tools the probe needs must be
  **symlinked** into it, not copied: an Apple-signed binary copied out of
  `/usr/bin` is killed by the signature check, so every pipeline's count came
  back empty and the same suite went `11/8` on darwin - the probe's own
  defect class, an empty result read as a number, reproduced by its fixture.
  A symlink runs the original at its original path. And resolve the tools
  with `type -P`, not `command -v`: in a shell where `grep` is an alias,
  `command -v grep` prints `grep`.
- A suite whose result depends on the author's profile should say so out
  loud. The receipt to require is the same suite passing under `env -i` plus
  an explicit environment - otherwise a green run on the machine that wrote
  the fixture proves nothing about any other machine, and a red run there
  gets blamed on the code.

Related to rule 8: an ambient value and a fixture value become the same value
here, and the code cannot tell which one it was handed.

## 12. A bisection must prove that each step checked out what it claims.

A four-row bisection blamed a commit, and every row of it had measured an
empty directory. `rm -rf` had removed a worktree's files but left git's
registration behind, so each `git worktree add ... 2>/dev/null` refused
silently, the checkout never happened, and the suite ran against nothing.
The refusal and the answer were the same value - rule 8 again, wearing the
clothes of a method that FEELS rigorous because it is systematic.

The correct answer turned out to be the opposite of the reported one: every
commit the bisection blamed was green, `183/0`.

So a bisection step owes a receipt that is not its own exit code:

- Assert the tree is what the row says - `git -C <dir> rev-parse HEAD` equals
  the commit under test, checked, not assumed.
- Never silence the checkout's errors. `2>/dev/null` on the line that
  establishes the measurement is the line that hides the measurement's
  absence.
- Assert the suite was actually there to run: a file count, or the suite's
  own total against a known one. A bisection over an empty tree produces a
  perfectly clean, perfectly monotonic table.

Systematic method does not confer correctness. It confers a shape that is
harder to doubt, which is worse.

**And a verified checkout isolates the TREE, not the HOST.** Measured the
same day this rule was written, by the person who wrote it: a full gate on a
worktree whose HEAD was checked before the run reported twelve red suites and
was reported onward as "origin is red in twelve". Ten of them were one line
in `~/.config/steward/config` on the host - a key the CLI's loader refuses,
so every `steward` call on the machine returned 78 for an hour, whichever
tree it ran from. A colleague's Linux run of the same commit was green in all
ten; a colleague's direct invocation on the same darwin host was green in all
ten; only the runs that crossed that hour on that host were red. The worktree
was clean. The measurement was correct. The conclusion was about the code,
and the cause was the machine.

So a bisection's receipt has a fourth line: **what the host contributed**.
`git rev-parse HEAD` says which tree ran; it says nothing about the user-level
config, the profile's environment, the state directories and the sockets the
code reads regardless of tree. When two runs of the same commit disagree,
suspect the host before the commit - and when a red must be attributed to a
change, reproduce it on a second machine, or in an environment whose host
inputs are enumerated, before saying whose it is. This is rule 11 one level
up: the fixture that overrides `HOME` and forgets the variable that outranks
it, and the bisection that verifies the tree and forgets the config that
outranks the tree, are the same mistake.

## 13. The field you can read and the surface a person looks at may be two objects.

A session's tile in the vendor's list showed `Du har post` for seven and a
half hours while its name was `Team→Session`. Two sessions measured it
independently and both reported the right name, because both read the same
place: the vendor's session record, which said `name=Team→Session,
nameSource=user` the whole time - verified in a third tree afterwards. The
rename had worked. What the human was reading was an AUTOTITLE the runtime
had written over the tile when the first `[bus] du har post` ping arrived, on
a surface neither measurement touched.

Nothing here was a wrong measurement. Both were correct about the field they
read, and the field was not the thing anyone cared about.

So when a person reports that a display is wrong and the measurement says it
is right, the disagreement is the finding, and it is resolved by asking WHICH
SURFACE each side is looking at - not by re-running the measurement, which
will keep agreeing with itself. Two questions settle it:

- Is the thing I am reading the thing they are seeing, or a record the
  surface is *supposed* to follow? A record and a rendering diverge whenever
  anything else can write the rendering.
- Can anything write that surface other than the code under test? Here it was
  the runtime's own autotitle, triggered by an unrelated feature - a message
  ping - which is exactly the kind of writer no fixture would think to stub.

The remedy that holds is to measure the surface, not the record: read the
tile, the rendered page, the list the operator opens. Where that is not
reachable from a test, the honest report names the field it read and says the
rendering was not checked, rather than answering "the name is correct" to a
question that was about the tile.

Measured 2026-09-12 by the session that owns the product's supervisor, which
also withdrew an earlier explanation of its own - that the rename cycle never
runs for derived sessions - when this one turned out to fit the evidence.

**And there is a third remedy, when the surface cannot be read at all: act at
the moment you know it changes.** The same session shipped it the same
evening. Nothing on the machine can see the tile - not the record, which is
correct, and not the pane, which renders something else - so no receipt can
ever prove the tile is right. But the corruption has a known TIME: the
runtime autotitles a fresh registration from its first prompt. So the fix
does not measure; it re-applies the name once more after the session's first
turn, detected as a pane seen busy and then idle again. Two steps, never one:
an idle pane alone is also how a session looks that has never had a prompt,
and then there is no autotitle to correct.

The shape generalises. An unmeasurable surface is not the end of the
analysis - ask whether its corruption is *predictable in time* even though it
is invisible in state. Where it is, the honest design is idempotent
re-application at that moment, and the cost is stated rather than hidden: one
rename too many costs a line in the pane, one too few costs a name nobody can
see is wrong. That trade is written into the code beside it. A guard that
cannot observe its subject can still be correct about when to act.

## 14. A guard that was NOT RUN is not a guard that passed - and somebody must be obliged to read the line that says so.

The runner says, on its summary line, which guards it could not run:

```
suites found=125 ran=125 red=0 silent=0 rust=not-run estate-guard=not-run
```

Both words are honest. `rust=not-run` means no cargo on this host;
`estate-guard=not-run` means the designated estate has no name list to run.
Neither is a failure, and neither is a pass. The line is loud on purpose:
the first draft of both hooks counted a missing measurement as RED, and a
summary that can never read `red=0` stops being read at all.

But a signal nobody is obliged to read is a signal, not a mechanism.
Measured 2026-09-12, the day the estate hook landed: the name guard lives in
the estate, so it only runs where the gate runs with that estate designated.
Our Linux steward's gate reported `estate-guard=not-run` - correct, that
estate carries no list - and the same run was, by our own practice, enough to
merge. So a change gated only there passes no name guard at all: the hook
closed a hole on one host and left one exactly its size on the other. The
peer who spotted it did so by taking our own receipt literally instead of
taking our summary of it, and asked which of three workflows was real rather
than asserting one. Both halves of that are the point.

There is no CI in this repo - `.github/workflows/` does not exist. Every gate
is a practice between the people who merge, which means the obligation has to
be written down where they read it:

> **A merge to `main` requires a gate run with `estate-guard=ok`.**
> `not-run` is not `ok`; it is "the name guard did not run". A gate run on a
> host whose estate carries no list satisfies the suites and not this rule.

And the corollary that keeps the rule from being resented: when the estate's
list makes a product PR red, the product's line is what changes - a comment
that says `(a darwin host, 2026-09-12)` instead of naming the machine - not
the estate's list. The list is the estate's to grow; a name added there can
turn a product PR red without a line of product changing, and that is the
design working, not a collision.

And the second corollary, which is about what `ok` is allowed to mean.
`estate-guard=ok` says one estate's list ran clean. It does not say the
product carries no names. The lists are disjoint by construction - each
estate holds the people and machines it actually knows, and an estate may not
write another estate's people into its own register - so a run is blind to
every other estate's names exactly the way it is meant to be.

Measured 2026-09-13, by the two estates comparing counts of the same tree:
two people appear in the product and in no list on this host, and this host's
list was the only one any gate had ever run. The asymmetry runs both ways.
The peer estate counted 137 lines to rewrite where this one counted 63, and
the entire difference was two machine names that do not exist on this host.
Each side had searched for what it could see, and neither could have
discovered that by looking harder at its own surface.

So the summary names the estate whose list ran - `estate-guard=ok(<estate>)`,
never a bare `ok`. `not-run` stays bare, because there is no list to name. A
PR gated on two estates has been measured against two registers and no
others, and the word is now precise enough to say which. That is the most a
partial guard can honestly claim, and more than a complete-looking one ever
could.

**A gate number names a COMMIT, and a rewritten commit voids it.** Rebase,
amend and squash all produce a hash nobody has gated, however small the
change - and the smaller it is, the stronger the pull to carry the old number
over. Measured the evening this rule was written, twice within an hour: a
docs-only rebase (another session appended to this very file while the PR was
open) moved the branch, and the honest move was to discard the number and
re-run - first mine, then, an hour later, a colleague's Linux number on the
same superseded hash. The second one was the real test: the rule held because
the author remembered the precedent he had just set for himself, not because
the text said so. It says so now.

And the exception that will be reached for first - **"no suite reads this
file"** - is not an exception at all. It is a CLAIM, and the person making it
is the person who wants to skip the run. Measured on this very file the same
evening, by the colleague who had no incentive to: `test/language.test.sh`
sweeps `git ls-files '*.md'`, so a Swedish letter appended to
`docs/guards-and-proofs.md` turns the suite red and names the file
(`pass=16 fail=1`, restored `17/0`). The author's own search had been
`grep -rln guards-and-proofs test/` - which finds a suite that names the file
and misses every suite that globs it. A docs-only change to a `.md` in this
repo can fail a suite, so the re-run that was demanded on precedent turned
out to be necessary on the merits too. Right conclusion, wrong reason, and
the next `.md` would have had the same reason and no such luck.

There is a second reason, and it is the load-bearing one: a number that names
a commit nobody can fetch **cannot be checked afterwards**. That is the same
reason we send each other hashes instead of "the branch is green" - a receipt
whose subject has been rewritten is a claim about a thing that no longer
exists. It holds even when the diff looks like it touches only files no suite
reads, which, per rule 15, is usually an unverified claim as well.

The cost of the strict reading is one gate run on a machine that was idle
anyway. The cost of the lenient reading is that "gated" stops meaning
anything, one defensible exception at a time.

Rule 10 says a double must be able to say both things. This is rule 10 for
the gate itself: a summary that can only say "everything ran" is a summary
that cannot warn you.

**And the rule has a practical floor: a number bound to a commit is only
worth something if the commit outlives the gate.** Measured the evening this
rule was written, by its author, on this file. Every suggestion taken in gave
a new hash, and a new hash means a new run - four gates in a row were thrown
away by their own author before they finished, each invalidated by the next
improvement to the text they were measuring. Nothing was wrong with any of
them. The rule was applied correctly four times and produced no usable number
at all.

That is a measurement of one's own cadence, and the response is not to relax
the rule - it is to stop editing. A file under active revision gets closed
for the session at a named commit, and further suggestions go into the NEXT
change rather than into the one being gated. Otherwise the gate becomes
ceremony: it runs, it is honest, and it never finishes in time to mean
anything.

The generalisation is worth stating plainly, because it is the one thing on
this page that is about pace rather than about proof: **a verification that
cannot complete before its subject changes is not a slow verification, it is
an absent one.** Any process that re-verifies on every edit has a rate above
which it measures nothing - and that rate is discoverable, by counting the
runs you discarded.

## 15. Searching for references does not answer whether anything reads the file.

"Does any suite read this file?" was answered with `grep -rln <filename>
test/`. That finds every suite which NAMES the file and misses every suite
which GLOBS it - and the one that globbed was the one that mattered:
`git ls-files '*.md'` at `test/language.test.sh:254`, under a line 102 that
skips `*.md` in the code sweep precisely because prose files are swept
separately below. The query could not match half the answer, so its empty
result was read as "none", and a rebase was reported to a colleague as
"docs-only, nothing reads it".

**The reliable way to answer "does X affect anything" is to change X and
measure.** Plant, run, restore, confirm the tree is clean: one Swedish letter (U+00E5, spelled here as a code point for the
reason this very suite exists) appended to `docs/guards-and-proofs.md` gave `pass=16 fail=1` with the file named, and
the restore gave `17/0`. Thirty seconds, and it answers the question asked
instead of a question about how somebody else happened to write their suite.
Measured 2026-09-12 on both platforms, the Linux half in a worktree with the
deployed tree untouched.

The shape is rule 5's relative one level up: an expression that cannot match
what you are looking for returns zero, and **zero looks like an answer**.
Rule 5 is about a test that says yes when it should say no; this is about a
search that says no when it cannot say yes. Both are read as measurements.

The finding was the searcher's own - the flaw was in the question, not in the
tree - and it was measured by the colleague who ran the suite out of habit
after editing the same file, which is also how most of this document was
found.

## 16. The least load-bearing claim in a group is where a wall-clock limit hides.

Four claims about one hung shim, in the order the suite makes them:

```
87  stderr names the deadline                      the guard fired
88  its own child was reaped by the group kill     it killed the whole group
89  seam-timeout at a different injected limit     the limit drives the reason, at two values
90  returned in under twice the injected limit     and it was quick enough
```

The first three prove the thing the seam exists for: the guard **killed** the
shim instead of waiting it out, and the limit - not chance - decided the reason,
shown at two different values so a shim that merely happened to return cannot
fake it. The fourth adds an upper bound on how long that was allowed to take.

Measured 2026-09-15, on a host running 128 suites: the fourth failed and the
other three passed. It compares `date +%s` before and after an injected 3-second
limit and requires a return inside 6 - a **wall clock** on a shared machine.
Under load the kill and the return took longer, with nothing wrong in the code
the suite was pointed at. Run alone, three times: green, green, green.

**The claim that fails under load is also the one that adds least.** That is not
a coincidence, and it generalises: a wall-clock bound tends to arrive as an extra
safety on top of a proof that already stands, written by someone who has just
made the hard part work. It is the cheapest line in the group to write and the
only one whose truth depends on who else is using the machine.

So, when a timing claim goes red, read what its NEIGHBOURS already prove before
repairing the timing:

- If the neighbours carry the proof, the bound is decoration under load. But
  removing it is not free either - it is the only thing standing between "kills
  correctly" and "kills correctly in sixty seconds", and a regression there
  would pass every remaining claim.
- The repair that keeps the protection is to compare against a reference that
  suffers the SAME load - a sleep started at the same moment - so the bound
  scales WITH the host instead of against it.
- The repair to refuse is a bigger constant, or one lifted into a variable the
  gate can raise. A loaded enough host passes that too, and then the suite is
  green because it was made slacker, not because the product got better.

Rule 1 asks whether a guard is unproven or redundant. This is the same question
asked of one claim inside a group that is otherwise sound - and the answer is
usually "redundant under load, load-bearing under regression", which is why the
repair is neither keeping it as it is nor deleting it.

## 17. A test's assertions are about its return values. Nothing asserts what it leaves behind.

A suite says `pass=17 fail=0` about the things it checked. It says nothing
whatsoever about what it wrote outside its own fixture tree - and a defect that
lives only in the traces passes every run, in both worlds, forever.

**The measured case.** Two suites start a *second* runner against a fixture
tree, at five call sites between them. **One** of those runs a probe that is
MEANT to fail: it is the control group, the thing that shows the isolation bites
when the protection is removed. The nested runner inherited `RUN_TESTS_RED_DIR`
from the environment, and since a red suite now saves its whole output there,
**that deliberate failure was written into the OUTER run's evidence
directory.**

**One call site was enough.** The reader of an evidence directory cannot know
which of the files in it is the control - so a single planted red makes the
whole directory unreadable, not one file in it. This is a narrower claim than
"nested runners tend to carry deliberate reds", and a stronger one: the defect
does not need a pattern to be total.

The result is a directory in which a control group and a real regression are
indistinguishable. Somebody opening it after a gate run reads

    FAIL: saw an existing config: /var/folders/.../poison
    pass=0 fail=1

and has no way to tell that this is the guard doing its job.

**Why no test caught it, and no test could.** The suites pass identically with
the leak and without it - `17/0` and `12/0` either way. Every assertion in them
is about a return value or a captured string. Not one of them makes a claim
about shared state outside the fixture, because nothing in the ordinary grammar
of a test invites that claim. *A test sees its assertions; it does not see its
traces.*

**How it was found, which is the part worth copying.** By opening the evidence
directory after a GREEN full run - a moment when it should have been empty - and
noticing a file in it. Not a search, not a hypothesis: somebody looked at a
thing that ought to be empty, *because they wanted to see how it worked*, and it
was not empty. **An emptiness that is not empty is one of the few defects
visible without knowing what you are looking for** - and only to someone who
looks at the emptiness at all.

**And the third measurement is the one that proves anything.** Two are obvious
and insufficient: with the fix the outer directory is empty; with the fix removed
`probe.out` returns. Both run inside the suite's own fixture, which is the world
the fix was written for. Only the **full gate** - green, and the evidence
directory empty, where before a green gate left a file there - shows it bites
where the fault actually occurred.

**How to apply.** When a change gives a run somewhere new to WRITE, ask the
question the assertions cannot: *what does this leave behind, and who would
notice if it left the wrong thing?* Then answer it by looking at the place
itself after a run that should have left it untouched. The cost is one `ls`.

This is rule 8's relative in the other direction: there, an error not
distinguished from an answer becomes an answer. Here, a control group not
distinguished from a regression becomes a regression - to the next person who
reads the directory, who will be reading it precisely because something went
wrong.

Found by a colleague who was looking at the mechanism rather than for a bug,
after the defect was introduced by the change that created the directory - a
change whose own two full gate runs could not have seen it.

## 18. A claim about two platforms, measured on one, is not "measured".

Three of these in one night, all by the same author, all in the same shape:

| the claim | measured on | asserted about |
|---|---|---|
| "the `^` anchor is zero-cost" | darwin, with that `PAT` | every `PAT` a later reader might write |
| "no suite reads this file" | a grep for the filename | every suite, including those that glob |
| "the shape check is zero-cost on both hosts we have" | darwin | GNU, where it turned out to do the work |

Each time the word used was **measured**. Each time the measurement was real and
the conclusion was wider than it. The mechanism is not laziness: it is that the
reachable half is the half that gets measured, and a conclusion written in the
same sentence inherits the confidence of the number beside it.

The repair is a habit of phrasing, and it costs one clause:

> **Name the ground the measurement stands on, in the sentence that makes the
> claim.** "Zero-cost here; unmeasured on GNU" is honest and just as short as
> "zero-cost on both". A reader on the other platform then knows whether they
> are reading a result or an expectation - and, more usefully, knows they can
> settle it in a minute.

That is what happened to the third one: a colleague on the other platform ran
the exact call, and the answer was not what the comment said. The code was
right; the sentence about it was not. Code is tried by the gate on both
platforms - **prose is tried only by a reader who cares**, which is why a
cross-estate review cannot be replaced by more tests.

**And the corollary, which cost a second correction the same hour: a measurement
refutes everything it touches, not only the claim that prompted it.** The GNU
run was made to check one sentence; it also falsified the sentence below it,
and the person who ran it did not see that - they checked the line they were
already looking at. So when someone else's measurement lands on your text, read
the whole passage against it, not the clause they quoted. The one who runs a
measurement is not automatically the one who sees everything it settles.

Rule 15 is this rule's neighbour and not the same: there, a TOOL could not see
half the answer and returned zero. Here the tool worked, the number was true,
and the SENTENCE reached further than the ground under it.

## 19. A gate number applies to a TREE. The tree that lands is the merge result.

A receipt binds to a commit — that is rule 14's whole point, and it is why a
receipt never lies about *what* it measured. But a branch's tip is not the tree
that will exist after the merge. **When a branch does not contain the target's
tip, merging produces a third tree that neither parent was**, and both halves'
numbers describe something that will not exist.

**Measured, not reasoned.** On one day, all five open pull requests stood on
branches that did not contain `main`'s tip:

```
git merge-base --is-ancestor origin/main origin/<branch>   →  false, five times
```

Two of them carried a *both-green* label at the time. The label was a true
statement about a tree, and the tree was not the one anybody would get.

**What follows is a claim and is marked as one.** That a clean merge of two green
halves can go red is not demonstrated here. It is credible rather than certain,
and the reason it is credible is rule 15's: this product has a suite that reads
prose files, so "nothing reads that file" is a claim somebody has to check, not a
safe default. Anyone who wants it measured can build it — a branch that tightens
a text check, plus a line on the target that the tightened check refuses; both
halves green, the merge red.

**The working order this produces:**

- **Rebase before asking for the pair, never after.** A rebase after a receipt
  discards both halves, including the one that measured nothing new.
- **Merge one at a time, and promptly.** Every merge invalidates every other open
  pair. Five open branches and one merge is five pairs to redo.
- **A label may not outlive the tree it describes.** When a branch falls behind,
  take the label down to *needs* rather than leave a green one standing for a
  tree that will not land — the label is what the queue shows, and it is read by
  people who never open the thread.

The shape underneath is one this document keeps meeting: **a statement that was
true when it was made, and stopped being true without anything in it changing.**
Rules 14 and 18 bind a claim to what it measured; this one binds it to how long
that stays the relevant thing to have measured.

## 20. When more than one branch is open, no per-branch base check can be satisfied for all of them. Measure the integrated tree and bind the number to a tree hash.

Rule 19's working order says *merge one at a time, and promptly*. Followed
literally with more than two open branches, it does not converge: the first merge
moves the target, so every other open pair is void again. Five open branches cost
5+4+3+2+1 = **fifteen pairs** — and the last four of those are re-runs of code
nobody changed.

**The instrument that replaces it.** Build the tree that will actually land —
the target plus every branch that is going in — and give *that* a pair. Then,
after the merges, compare hashes:

```
git rev-parse origin/main^{tree}        →  must equal the gated tree
```

That comparison is the whole point. It turns "we assume the merge produced what
we measured" into a measurement: equal hashes mean `main` is *literally* the tree
both halves ran. Different hashes mean something else changed while we worked,
and that is the moment to stop rather than to reason.

**Measured on the night it was first used**, five branches, two hosts:

- Five per-branch pairs, each on its own rebased commit, both halves readable in
  its own thread; **one** integration pair on the merged tree. Six pairs where
  the one-at-a-time order would have cost fifteen.
- The merge order and the merge style do not move the result, and this was
  measured rather than assumed: `51,47,53,68,52` as merge commits and
  `52,68,53,47,51` with fast-forward allowed both produced tree `11dda0d`. The
  real run then landed mixed — one branch fast-forwarded, four as merge commits —
  and `main^{tree}` came out `11dda0d` all the same.
- The branches were disjoint by file, checked pairwise. That is not a
  precondition for the method; it is why the order-independence held here.

**And when the hashes differ — which is the question a reader will have at the
worst possible moment.** "Stop rather than reason" is the right posture and it is
not an instruction; somebody standing in front of two unequal hashes at two in
the morning will improvise unless the next step is written down. It is:

- **Merge nothing further.** The difference means something changed that was not
  in the plan — a branch moved, someone landed a sixth thing, a rebase happened
  under one of the five. That is a fact to find, not a risk to weigh.
- **The per-branch pairs still stand.** They proved their own branches, and those
  branches did not change; a differing integration hash says nothing about them.
- **Rebuild the integration object and redo the INTEGRATION pair only.** One
  pair. That the remedy is this cheap is a property of the method rather than
  good luck: the integration object is the only thing the difference implicates.

This paragraph exists because the peer running the other half asked for it before
the pair was spent rather than after — the rule's own lesson applied to the rule:
adding it now costs two runs, adding it after the merge costs the same two runs
plus a second thread to read.

**The failure this method brings with it, and the guard against it.** The
integration object is a commit, and it must be named as one. Its *branch name*
moved under a peer mid-run — the author of this page rebuilt it to take in a
fifth branch, force-pushed the same name, and the peer who had already started
was measuring a ref rather than the commit they were asked to measure. Their own
diagnosis is the rule:

> `HEAD == $(git rev-parse origin/<branch>)` cannot fail. It compares a value
> with itself.

The assertion has to pin the SHA **from the order**, never from a remote ref;
and whoever names an integration commit owes the other half a promise that it
will not be rebuilt. Two people caught that window independently, from opposite
ends, and one of them had run the right tree by luck rather than by method — the
distinction they insisted on drawing, and the reason it is written here.

**A label may not outlive the tree it describes** (rule 19) has a second half
that this night supplied: *a label changes state when the THREAD changes state,
never when the person does*. Four labels were taken down at the moment a run
finished rather than the moment its receipt was readable by somebody else, which
left four queue entries carrying no label at all — and an absent label reads as
"nothing needed", not as "a half is missing". Absence is not emptiness; this
document has now paid for that equivalence four times.

## 21. Measure the quantity that separates the states, not one detector per cause. An observer is obliged to say that something is wrong before it can say why.

Rule 14 says a guard that was NOT RUN is not a guard that passed. That is a
statement about one line in one runner. The same sentence holds a level up, about
what to build in the first place, and a colleague's backlog item made it concrete
enough to write down.

**Their case, measured on their host and not here.** A scheduled job's failures
are watched through the queue: a send that is attempted and refused lands in
`failed/`, and somebody is obliged to read it. Then a sibling job died on a
provider quota *before writing anything*. Nothing was delivered, nothing was
sent, nothing was refused — `failed/` stayed empty, and stayed honest. Nine days
against a weekly schedule. The job's delivery path has no queue in it at all:
there was no channel to fail.

**The move that fixes it is a choice of quantity.** Not another detector — a
quota detector, a crash detector, a dead-key detector, a never-fired-schedule
detector — but the one measurable fact those causes have in common: *the age of
the newest delivered artefact*. Quota, crash, dead key, missing hook, a schedule
that never fired: all present as the same fact, and the observer does not need to
know which to be obliged to report it.

**And the assumption that carries it has to be written down, because the first
draft of this rule left it out.** Delivery age separates late from not-late *for
a job where every run delivers*. A job that delivers CONDITIONALLY — writing a
report only when there is something to report — breaks it: its newest artefact
ages while the job is running perfectly, and the observer calls a healthy run
late. That is an error in the other direction, which is precisely what a
separating quantity is supposed not to have. The author of the backlog item this
rule generalises raised it against their own item before the pair was spent, and
the hole was inherited from that item rather than introduced here.

**When delivery is conditional, the separating quantity is the RUN.** Which moves
the weight onto the run marker being trustworthy — and that is not free either.
Measured the same week: a tool's run column had been frozen for ten days because
it read a log directory that stopped being written when an estate was split,
while its delivery column was current the whole time. Every row rendered "never
ran", and an alarm on every row is an alarm on none. So the choice is not
delivery *or* run as a matter of taste: it is delivery when every run delivers,
run when delivery is conditional, and in both cases the reading has to come from
somewhere that still exists after the last reorganisation.

**Why a detector per cause loses on principle and not just on effort.** Each
detector covers the case its author thought of, which means the set of undetected
failures is exactly the set nobody enumerated — and that set is invisible by
construction, because an undetected failure produces no evidence that it went
undetected. A separating quantity inverts that: *with its assumption
satisfied* it is wrong in one direction only, it says *late* without claiming a
reason, and a reason can always be added later to an alarm that already fired.
The assumption is the part to state out loud — an unstated one turns the
one-directional guarantee into a false alarm on a healthy job, and a watcher that
cries wolf is decommissioned by the people it was built for.

**The test to apply when choosing what to watch:** name the states you must tell
apart, then ask what single reading differs between them. If the answer is a list
of causes, the design is a catalogue and it will be incomplete. If the answer is
one number, that is the thing to measure — and the causes become a diagnosis
after the fact instead of a precondition for noticing.

**The test to apply is also how the gap above was found.** Name the states, ask
what single reading differs. For a conditionally-delivering job the states are
*ran and had nothing to say* and *did not run at all* — and the delivery age is
**identical in both**. So the answer is not the delivery age; the rule
contradicted itself four paragraphs down, and the person who caught it did so by
taking the test seriously rather than by taking the claim on trust.

**The two quantities are not alternatives on equal footing.** Each has a
precondition, and the preconditions differ:

| quantity | works when | fails silently when |
|---|---|---|
| delivery age | every run delivers | delivery is conditional |
| run age | the run marker is written where the reader looks | the marker's source moves |

**And the chain does not terminate on its own.** Delivery age leans on the run
marker; the run marker leans on its source still being the source. In the case
above that chain had one silent link and it stayed silent for ten days. What
makes it terminate is a property the observer can check about *itself*: the input
I am reading has not changed at all in longer than it plausibly could. A log
directory nothing has written to in ten days is a finding about the READER, not
about the jobs — and that reading is free, being the same `mtime` comparison one
level up, the same shape as the check already being performed.

> **A separating quantity must also be able to report that its own input went
> quiet.** Otherwise the blind spot is not removed, only moved one level down,
> where it is harder to see and no longer anybody's item.

That rule of thumb, the table above, and the two-states formulation are the
objector's words rather than a summary of them, at their suggestion: take the
wording where it is sharper, not a paraphrase of it.

The form of this item was raised by the session that owns the affected jobs; the
measurements were taken by the session that wrote it up; the generalisation is
the reader's, and the correction to it came back from the first of them before it
could be merged. It belongs to none of them alone. Nobody who is obliged to say
"this is wrong" should be required to say why first.

## 22. Rule 20 integrates branches that merge TOGETHER. Two authors merging separately have no shared tree to bind to, and the only instrument left is telling each other.

Rule 20 builds the tree that will land and gives it one pair. That works because
one person decides what goes in. **When two estates each hold a branch and each
merges on their own judgement, there is no such tree**: the first merge moves the
target and the other author's gate — possibly already running — is measuring a
tree that will never land.

**There is no local measurement that can detect the invalidation, and that is
what makes this a rule about numbers rather than about manners.** The branch bears
the target's tip when the gate starts and does not when it finishes. The gate
measures a real tree and reports a true number; what the number describes is a
tree that will never exist. Neither side can see it happen: the author who merged
has no view of the reviewer's run, and the reviewer's own checks all pass, because
everything they measure is locally consistent.

That is the same subject as the twenty-one rules above — what a number means, and
when it means nothing — and it is the only one of them where the answer is that no
instrument helps. When there is no instrument, what remains is telling each other,
and the rules below are what that cost to work out.

**1. Start on a handover, not on the existence of a branch.** A pushed branch is
not an invitation to gate it. The author says *handed over* when they have
finished moving it, and the reviewer starts then. A gate begun on a branch the
author is still rebasing measures a commit nobody will merge.

**2. The party whose wait is free is the party that holds.** Not the one who is
senior, or asked first, or has the smaller change. Count what is already running:
a merge that throws away a gate in flight is expensive, and one that throws away
nothing is not.

**3. Count what the changes ARE, not only what is running.** A correction to
something already deployed goes ahead of a comment fix, because one is running
wrong code and the other is not.

**These two are separate rules because they can disagree, and a night in which
they happened to agree is what made them look like one.** They ask different
questions — rule 2 asks the cost of *waiting*, rule 3 the cost of *not landing*.
Invert them and they part:

| | in flight | the change |
|---|---|---|
| A | a gate is running | comments only |
| B | nothing running | a correction to deployed code |

Rule 2 says B holds. Rule 3 says B goes first. Same case, opposite answers.

**Untested.** In the night that produced these, the two pointed the same way every
time, so which wins when they part has never been measured. The reviewing estate's
judgement, marked as judgement: rule 3 wins, because a gate in flight is a sunk
cost of minutes and code running wrong is live damage. That is a position, not a
result, and this paragraph exists so the next reader knows the difference.

**4. Say on the bus before a merge and again after it.** Before, so the other
author can say "hold, mine is mid-flight". After, so they know to rebase without
having to poll. The line costs one message and replaces a rule nobody can enforce.

**5. A check that informs does not govern.** One estate's staleness check printed
NO and let the run start anyway; the operator saw the line after the gate was
already going. It now exits non-zero, with an explicit override for the
deliberate case. A measurement that exists and may not act is the failure mode
this document names in five other places.

**6. An agreement a third party will need later belongs in the artefact.** "Not
to be merged before #89" written in the pull request body is a condition; the
same sentence on the bus is a memory two people share. The reader in three weeks
has the first and not the second — the same reason a label follows what the
thread can be read to say rather than what the two participants know.

**Measured over one night, three estates, four rounds. The runs are named so
the table can be checked rather than believed:**

| round | main moved | thrown-away gate runs |
|---|---|---|
| before | `ecfc429` → `8967330` (#87) | **1** — a reviewer had just started a gate on `185782a`, handed over against `ecfc429`; they killed it when the merge landed |
| 1 | `8967330` → `25fc91f` (#90) | 0 — the merging author said so on the bus first |
| 2 | `25fc91f` → `6af32bd` (#89) | 0 — the other author held a ready branch rather than merge into a run |
| 3 | `6af32bd` → `ae63003` (#92) | 0 — the merger announced, the held branch rebased, the reviewer then started |

The fourth round was the first where no party's wait cost anything, and it was
not luck: one author held, the second waited for the first author's number rather
than handing over early, and the reviewer did not start until the handover came.
**Three parties each declined to do something that would have looked like
progress.**


## 23. Consistent numbers are not a check. Put the control assertion beside it.

When a probe answers the same in both states, you have not measured the
difference — you have measured something insensitive to it. The consistency
reads as rigour, and that is what makes it dangerous: a number that never moves
looks like a number that was checked.

**The cure is a CONTROL ASSERTION next to the one you care about:** something
that MUST change if the probe measures what you think it does.

Four instances in one week, none of them a miscount:

1. **A receipt asserted not to carry a secret.** It did not — because the guard
   had been used as a scrubber when it is a detector, so every receipt came out
   EMPTY. The assertion was satisfied by an empty set. Missing control: prove
   that ORDINARY output IS carried.
2. **A register lookup probed at two directory modes answered rc 1 in both.** Six
   fixture defects in a row produced the same rc 1, so "cannot reproduce" would
   have looked like a measurement. Missing control: drop the `2>/dev/null` so
   the loader's own refusal is visible, separating "this row does not match" from
   "no row could load".
3. **A sweep that finds nothing and a sweep that CANNOT find anything print the
   same zero.** That is the shape that let two `mapfile` calls through a guard
   that forbids `mapfile`. The control now in `test/deploy-policy.test.sh` asserts
   that the pattern still matches a known violation.
4. **"Red without this change" listed five assertions; two were.** The other
   three passed against the old tree, because the route they exercise did not
   exist there and every path 404s — which is exactly what those three assert.
   Green for a different reason than the one claimed, in the commit message whose
   whole subject was that failure mode.

**Being red is not the same as measuring the right thing, either.** The cure at
that level is MUTATION: change the production code in the specific way the test
claims to guard against, and require it to fall FOR THAT REASON. Two here, one at
a time: moving the route after the principal check fell exactly the test about
ordering; silencing the journal fell exactly the test about the journal — and
fell it ON THE JOURNAL ASSERTION while the 404 assertion before it stayed green,
which is how you learn a test measures its two halves independently. **One test
per mutation is the second reading and it is not given:** a test that falls on
several unrelated mutations measures something broader than it says.

**What cannot be mutation-tested, and say so rather than implying otherwise:** an
assertion that guards against a FUTURE change has no mutation to provoke yet.
Those three green-on-both-sides assertions pin that the route's refusal stays
byte-for-byte identical to an unknown path's. That is not evidence for the commit
that introduced them. **It is a commitment about the next one.**

**And THE COUNT IS NOT THE READING.** Overlaying new tests on the old tree tells you
that N assertions fall. It tells you nothing about why the others STAND, and a
colleague who had used this technique on four branches had named two reasons a test
can be green on both sides - it is a GUARD, or it is a TAUTOLOGY - with the note
that the difference is read and not measured. This week produced a third:

> **green on both sides because THE SUBJECT DID NOT EXIST on the old side.**

Three of five assertions about an invitation route passed against the old tree
because the route was not there, so every path 404s - which is exactly what those
three assert. Not a guard and not a tautology: a claim about an object that did not
exist when the measurement was taken, and **it looks exactly like a guard**.

There is a time axis inside it. What is coincidental today is load-bearing tomorrow,
and the only moment the difference can be seen is BEFORE the subject exists - after
it does, the two are indistinguishable. So the technique's output needs a sentence
the technique cannot produce: which of the three each green-on-both-sides assertion
is, marked as read and not measured.

**Where this does NOT apply:** it is not a demand that every assertion acquire a
partner. It applies where a probe has two states you believe it distinguishes. If
you cannot name the state in which your assertion would FAIL, you do not yet know
what it measures.

## 24. A check whose subject set is ENUMERATED stops covering the tree. Rule 7 is about the question; this is about the subjects.

Rule 7 says broadening a sweep does not change the question it asks, and that the
answer is often a second guard asking the inverse. **This is the complementary
case, and the tell is different:** when the question is already right and only the
list of things it is asked ABOUT is frozen, widening IS the fix.

`test/deploy-policy.test.sh` has forbidden `mapfile`, `declare -A`, `find
-printf` and `grep -P` since long before `desk/apply.sh` was written, with the
reasoning in its own comment: *"a construct that works only on the developer's
machine is a latent failure on every other one."* It checked TWO FILES, both
named literals. The rule was universal; the enforcement was a hand-kept list.

**So every file added after the check was written was exempt in silence.**
`desk/apply.sh` landed months later with two `mapfile` calls, the whole suite was
green on Linux, and the defect was found by a NEIGHBOUR'S MACHINE after a full
darwin run — 5 passed, 20 failed, nineteen of them downstream of the first.

**A guard whose subject is a hand-kept list does not grow with the tree, and its
coverage shrinks every time the tree grows.** Widening cost nothing: 194 shell
files (union of `*.sh` and a shell shebang, `07c28d9`), two real hits, four
comments naming the constructs in order to forbid them, two self-references in
the guard's own pattern. The rule had been followed everywhere someone happened
to remember it — which is precisely why nobody noticed the enforcement had
stopped growing.

**The same file carried three assumptions about its own environment**, and they
were found one at a time by making it bigger:

- the subject was a hand-kept list of two files;
- `strip()` used `\s`, a GNU extension — in the guard whose entire purpose is to
  catch constructs that only work on the developer's platform. Invisible while
  the sweep covered two files that happened to have no comment naming a forbidden
  construct; the moment it reached `bin/steward`, whose line 5 says "no mapfile",
  a working `\s` was the only thing between it and a FALSE FAILURE ON DARWIN ONLY;
- the file loop word-splits its listing, so a tracked path containing a space is
  split into pieces that each fail `[ -f ]` and are skipped without a word.
  Measured: 0 of 194 tracked paths contain whitespace — latent, not active.

**All three are assumptions about the environment baked into a check whose job is
to measure that environment.** A guard is the last place an assumption should
live, because nothing downstream of it will look again. And note what found them:
not a failure and not a review. WIDENING did. An assumption is only visible where
its exception lives, and a check that touches two files never meets its own
exception.

**A safeguard can hide its own subject.** `tools/run-tests.sh` loops over
`fleet watchdog watch`; two of those directories do not exist. The next line is
`[ -d "$d" ] || continue`, which makes the dead entries harmless AND THEREFORE
SILENT. **A dead entry never alarms.** The list is simultaneously too broad and
too narrow, and the too-broad half is invisible precisely because somebody
guarded against it.

**The form that survives is a set, not a list — and it must carry its reason.**
`test/desk-serve.test.sh` faced the same choice, chose a glob, and wrote down why
it did NOT add `desk` to the runner's list (it would run the suites twice under
two names). That reason is what stops the next person "tidying up" by adding it.
**A choice that carries its reason can be re-examined. A choice without one
becomes a habit.**

## 25. A number without its lens and its tree cannot be re-taken.

`bin/steward:4130` was corrected to `:4088`. **Both were right.** The line had
MOVED — `96c30b2` added 42 lines above it — and the two readers were looking at
different trees: one at `main`, one at a deployed copy. Neither number carried
its tree, so the correction inherited the defect it was correcting.

The same week produced five answers to "how many shell files are there", from
three machines, all correct under their own lens:

| lens | count |
|---|---|
| `file --mime-type` | 194 |
| `*.sh` only | 177 |
| shell shebang only | 194 |
| `*.sh` OR shebang (what the guard walks) | 195 (194 swept; the guard file is exempt) |

**The form: a number that claims something is written `<number> (<lens>, <tree>)`.**
`171 (*.sh, 07c28d9)`. `193 (file --mime-type, before my own two commits)`.
`4088 (bin/steward, 3dd90d3)`.

**Three slots, because an empty slot is visible.** This is the same mechanic that
makes the gate line in a merge commit a check rather than a claim: the line cannot
be filled in without holding the facts, so whoever cannot say which tree they
measured discovers it AT THE MOMENT OF WRITING. A rule that says "state your lens"
does not work — there are four measured instances in a single day, three of them
inside sentences ABOUT numbers needing their lens. A slot that stands empty does.

**Its limit, stated first when it was proposed:** the form prevents an UNSTATED
lens and nothing else. Not a miscounted number, not a badly chosen lens. All four
instances were of exactly that kind and none was a miscount.

**Scope:** it applies to the number in the sentence that CLAIMS something, not to
every digit in a letter. A line length or a PR number does not need the slots. It
is retelling that loses the lens, so the numbers that need it are the ones someone
may repeat.

**What it buys beyond re-takeability:** two numbers that both carry their slots can
be COMPARED. `desk-serve 246 (07c28d9)` and `desk-serve 251 (9fbd3d3)` differ by
five, and the commit claims exactly five added assertions, named. Two estates, two
trees, and the receipt's own claim checked from outside by someone who did not
have the branch. Without the slots those are just two numbers that disagree.

**And writing a rule down is necessary, not sufficient.** The two-file list above
survived for months — not because nobody had written the rule, but because the
rule was in that guard's OWN COMMENT and nothing put it in front of anyone at the
moment it was being broken. `test/desk-serve.test.sh` has carried *"NO NODE IS NOT
A PASS. A suite that could not run is reported as one failure, not as silence: the
alternative is a green line that measured nothing"* since long before the week that
produced rules 23–25 — the same sentence as `not-run` vs `pass`, as `list=absent`
vs `list=<digest>`, as an empty receipt satisfying "the secret is not in it". It
was on the page before anyone here argued it out, and three people rediscovered it
the expensive way. **This is why the slots and the gate line are worth more than
this document: they stand in the way. A document stands beside.**

**Which gives an ordering worth choosing in.** Everything in rules 23-25 is one of
three kinds, and they are not equally strong. One question separates them — WHAT
HAPPENS AT THE MOMENT OF WRITING:

| kind | example | at the moment of writing |
|---|---|---|
| **a slot** | the lens, the tree, the letter an endorsement names, the gate line's two rows | an empty field is in front of you |
| **a removed shortcut** | a send that refuses an identical body to a second recipient | you must do the thing twice |
| **a resolution** | "I will split the letters from now on" | nothing |

A slot is strongest because it cannot be skipped without the skipping being visible:
whoever cannot say which tree they measured finds out WHILE WRITING, not afterwards.
A removed shortcut does not make the error impossible — the sender can paste the same
text twice and change one word — but it abolishes the one route that produces the
error without the text being read twice. A resolution does nothing at all, and that
is measured rather than asserted: the author of the sentence about splitting letters
wrote it, named the mechanism it prevents, promised it, and broke it twice within the
hour, in a single letter.

**So when something must be prevented: ask first whether it can be made a slot. If
not, ask whether the shortcut can be removed. If neither, write the resolution and
know that it will not bite.** Three points from one week, and certainly not a complete
taxonomy — but the three are separable by that one question, and it is the question
that has divided what bit from what did not, every time.

**A SLOT CARRIES THE QUESTION AND NOT THE ANSWER**, and this is the limit to state
before anyone builds one expecting more. An empty slot is visible; a WRONGLY FILLED
one is not. Five numbers from the same week, every one of them written by someone
being careful, and every one of them would have passed a slot:

| the number | what was wrong with it |
|---|---|
| `90 of 104` | two different lenses in one fraction — the numerator counted lines, the denominator counted insertions |
| `193 shell files` | a third lens, at a fourth moment, taken before the change's own commits added files |
| `72 of 104` | the RIGHT lens and a wrong subtraction |
| `171 shell files` | a correct number with its lens unstated |
| `two of four threads` | the right method applied to the wrong set — comments counted, bodies missed |

The third is the sharp one: its lens and its tree were both correct and the arithmetic
was not. No slot can reach that, even in principle. What the slot buys is that the
number can be RE-TAKEN, which is how the other four were caught — and how the third
was caught too, by someone re-doing the subtraction.

The same limit appears in a completely different construction, which is how you know
it is the limit and not a property of numbers. A send that refuses an identical body
to a second recipient can be overridden; `--anyway` is a switch you press, while
`--also <address>,<address>` is a statement you must compose. The second is a slot, and
it forces the writer to confront that there ARE two recipients — but someone who
writes both addresses correctly can still have "yours" pointing at one of them.
**It compels the realisation; it does not validate the text.**

**And a CHOICE tests an ordering in a way a description never can.** Everything above
was written by describing forms already in use, and a description can always be made
to fit afterwards. The `--anyway` → `--also` change was different: somebody stood in
front of two constructions, used the table to pick one, and moved their own proposal up
a rank. If the ordering is wrong, that is where it will show — not here.

## 26. The better a red receipt points, the more narrowly the person who receives it reads.

The darwin receipt on `#97` named `desk/apply.sh:123` and the builtin that was
missing. It was correct, it was useful, and it set three readers onto one file.

The commit that repaired the fault carried **two**: 32 lines in the broken file, and
90 in the guard that should have caught it. Its subject line said so —
*"no mapfile, no empty-array expansion, **and the guard that should have caught
both**"*. All three of us read the subject. None of us read the second file.

What followed is the measurement: three estates spent an hour discussing a missing
guard, opened an issue for it, and began building it — while the guard sat on `main`,
inside the very commit under review. It was found only because the person building
the replacement opened the file they were about to change and saw it already done.

**Three readers narrowed the same way, independently, within the same hour.** When
you know which file fell, diffing that file is the natural thing to do, and the path argument makes the narrowing
**invisible afterwards**:

> A review that runs `git diff <a> <b> -- <file>` leaves no trace of what it did not
> see.

That is what makes the remedy mechanical rather than moral. A narrowing that is
*written down* can be questioned by the next reader; one that is not can only be
discovered by somebody happening to redo the work.

**A branch is not only its defect. Review the commit, not the fault.**

- diff without a path argument when the tip is new;
- if you do narrow, say in the receipt **that** you narrowed and to what, so the
  narrowing is readable instead of invisible;
- and read the subject line as a **list of what the commit does**, not as a label on
  the thing it fixes.

**The mirror case arrived the same night**, and it is the same failure from the other
side: an issue whose body was written against **the tip that was `main` when its author
started**, and whose load-bearing claim — "the guard is aimed at three files" — stopped
being true one merge later, while the issue was still being written. `main` is a moving
name, and it was the movement that made the claim false; "written against `main`" reads
like a choice of reference, when the reference changed underneath.

**And it was not re-reading that corrected it.** Its author began building the fix,
opened the file they were about to change, and found it already done. Had they not
built, the issue would still be open — which is the same shape as this rule's own
remedy, on the issue side rather than the review side: **an issue is corrected by
somebody touching the code it is about, not by somebody reading it again.**

One reader took too narrow a slice of the right tree; the other took the right slice of
a tree that had moved. **Both times what was missing lay inside what the reviewer
already had.**

---

## 27. A rule nothing asserts on purpose is held by whatever asserts it by accident.

`DESK_ORIGIN` had two readers with two patterns, and they disagreed about one
character:

```
lib/registry.sh:2685    '^https?://[A-Za-z0-9.-]+(:[0-9]+)?$'   the issuer ACCEPTS http
desk/bin/desk-paths:108 '^https://[A-Za-z0-9.-]+(:[0-9]+)?$'    the bridge REFUSES it
```

An estate configured with `http` therefore got an invitation **issued** and then
found it opened no door. Neither reader lied by itself.

The question this rule is about is not which pattern was right. It is **why the
loose one survived**, since it had been read many times by people who would have
tightened it on sight.

It survived because the only assertion pinning the scheme was about something
else:

```sh
printf 'DESK_ORIGIN="http://host-a.example.test:8443"\n' > "$ROOT/estate/steward.conf"
is  "a port is part of the origin" "$(registry_desk_origin)" "http://host-a.example.test:8443"
```

The heading says **port**. The fixture happens to be `http`. Every reader who
checked what held the scheme found an assertion that passed, and every reader who
read this assertion was thinking about ports. Change the pattern to `https` only
and this test goes red — so it was load-bearing — but nothing about it says so,
and nobody who broke it would have learned what they had broken.

**A test asserts everything its fixture contains, not only what its heading
claims.** The difference is invisible while the test is green, which is almost
always.

### What to do

- When a fixture carries a value the assertion does not name — a scheme, a port,
  a locale, a permission bit, an ordering — either that property has its own
  assertion, with its own heading, or it is not guarded.
- When you tighten a validator, do not simply move the old fixture. Ask what the
  old fixture was silently holding, and give that its own line. The repair here
  kept `a port is part of the origin` with an `https` fixture and added a second
  assertion beside it whose heading is the scheme and whose reason is written
  down.
- The reverse reading is the useful one when hunting: **if a rule is real but no
  test names it, find the test that would go red and read its heading.** That
  heading tells you what the next person will think they are changing.

### Why this is not rule 24

Rule 24 is about a check whose subject set is enumerated: it stops covering
subjects that are added later. This is the opposite direction — full coverage of
one subject, under a name that describes a different property, so the coverage is
real and unfindable. Rule 24's failure is discovered when something new is missed;
this one is discovered when somebody changes the thing and the wrong test goes
red.

### The same shape, in the same file, five times over

`lib/registry.sh:269` records that the hand-kept key list has been short five
times. That is rule 24. This rule is its neighbour: the list was short, *and* the
property that would have caught it was being asserted by a test about ports. A
fleet that has both will find neither by reading, because both are green.

---

## 28. A check measures what its CODE says, never what its NAME says — and the name is the only part that travels.

An estate's leak-guard went red on one file, in a class called **"exact counts of
private artefacts"**. Three parties then guessed which line had matched. All
three guessed wrong, and all three guessed from the class's name.

| guess | line | reasoning |
|---|---|---|
| the guard's own estate | 86 | `Between 2 and 32 characters` — a number and a noun |
| the guard's own estate | 39-40 | `0 done - 64 usage - 70 an action failed` — numbers and nouns |
| a second estate | 344 | `a 750 home` — a number immediately before a *private artefact* |

The actual match, found by running the pattern:

```
linux/steward-account-helper:353
  # ran useradd two lines ago. 64 means the caller asked wrong and nothing
```

The word `lines`, followed within nineteen characters by `64` — **across a
sentence boundary**. Not a count, not an artefact, and not a number and a noun in
the same clause.

### Why every guess was wrong the same way

The class's word list is nine words: five English plural counting-nouns —
`commits`, `lines`, `files`, `sessions`, `incidents` — and the four Swedish
equivalents of the same nouns. Not one of the nine is `home`, `account`, `key`
or `host`. **The name is broader than the
implementation**, so a search built from the name cannot find what the code
finds, and can only find something else.

The second estate's guess is the instructive one: it was *more* careful than the
first two — it rejected them for being exit codes and string lengths rather than
counts, reasoned explicitly about what "a private artefact" means, searched for
exactly that, found exactly one hit, and noted that one hit matching one hit was
"corroborating, not proof". Every step of that was sound. It was still a wrong
answer, because the whole chain hung from a description.

> A note on the line above, which is itself an instance. The first draft quoted
> all nine words verbatim, and four of them are not English. The estate language
> guard failed this file on it — correctly: quoted data is still data in the
> file that carries it. The remedy was to keep the argument and drop the tokens,
> because the exact spelling of those four was never load-bearing; the point is
> only that none of the nine names a private artefact. Narrowing the guard, or
> exempting this file, was the other option and was not taken.
>
> The second draft then miscounted, in the one sentence whose subject is a
> count: it listed four English words and implied four more, which is eight. The
> list's owner supplied the wording above — five English, four Swedish — and had
> already run it. Quoting somebody else's data by describing it is the right
> instinct in the wrong file format; describing it *wrongly* is a different
> mistake, and it took the person who owned the code to see it.

### The asymmetry, which is the part to act on

This is not a symmetric failure. One party could run the pattern; the others
could not. **A letter can carry a check's name, its heading and its prose
description. It cannot carry its code.** So a remote reader reasons from the name
*by necessity*, not by laziness — which means the duty sits with whoever holds
the code.

- **If you can run it, send the evidence, not the class.** The matched line, or
  the pattern itself. A red receipt naming only the class invites exactly the
  three guesses above, and each one costs a round trip.
- **If you cannot run it, say you cannot determine it.** Producing a candidate
  from the heading is worse than producing nothing: it reads as a contribution,
  it has to be disproved by the one person who could have spent that time
  running the check, and hedging it as "not proof" does not stop the reader from
  building on it.
- **A guard's heading is documentation, and documentation drifts from code.** The
  distance between them is invisible while the guard is green.

### Its neighbours

Rule 27 is about a rule held by an assertion whose heading names something else —
the heading lies about what it *guards*. This is the same gap from the other
side: the heading lies about what it *matches*. Both are only visible when
somebody changes something and the wrong thing goes red; this one is also visible
whenever the finding has to cross a machine boundary, which is every time two
estates share a fleet.

---

## 29. The lens has a version too. A receipt that names the instrument but not the instrument's COMMIT records a number nobody can re-take.

Rule 25 requires a number to carry its lens and its tree. This is the case where
it carried both and was still unreproducible.

Two gate runs on one host, hours apart:

```
3bb8057   estate-guard=RED   root=ddba5552  list=6e524e3f
0dd2f55   estate-guard=ok    root=ddba5552  list=6e524e3f
```

**The digests are identical.** `root=` is the estate root's path, `list=` is the
guard's own name list — both were written precisely so that a reader could tell
whether two runs measured the same thing, and both said yes.

The entire difference was **one character in the guard's own source**, and that
character lived on a branch that had not landed. The second receipt is green, is
fully attributed under rule 25, and cannot be reproduced from `main` by anybody —
including its author, tomorrow.

### Why the existing fields could not catch it

`root=` and `list=` describe the guard's **subject**: which estate, which names.
Nothing in the receipt described the guard's **code**. A guard is not a constant
that reads a changing world; it is itself a thing under version control, edited
on the same days as everything it measures — this one was edited three times in
one day.

This is rule 28 turned against the gate that enforces it. A check measures what
its code says, never what its name says, and `estate-guard=ok` is a name.

### What a receipt therefore has to carry

The instrument's own commit, and whether that commit is reachable from the branch
the rest of the fleet would run:

```
GUARD: <estate checkout> 9ca874f [main] uncommitted=2 on-main=yes
```

- **The instrument's commit is the file's, not the checkout's.** Both are worth
  having and they answer different questions. The estate checkout's `HEAD` says
  *what state the guard stood in*; the last commit that touched the guard's own
  file says *what code did the measuring*. Only the second survives the estate
  moving on: a receipt naming the guard file's commit can be re-taken ten commits
  later, as long as none of them touched the guard. A receipt naming only the
  checkout sends the next reader to a tree where the guard is byte-identical and
  the number still cannot be tied to it.

      root=  list=      what the guard measured
      guard=            which code measured it
      HEAD, uncommitted what state it stood in

  The first draft of this rule prescribed only the third, because that is what
  the estate that found the fault happened to print. A second estate built the
  receipt a day later and reached for the guard file's own commit instead — and
  that is the field rule 29 exists to require. The rule is corrected to say so.
- `on-main=no` means the number rests on unlanded code. It may still be a true
  number; it is not a **re-takeable** one, and the difference is the whole of what
  a receipt is for.
- Uncommitted changes in the instrument's checkout are the same defect without a
  commit to name, so the count is printed rather than hidden.
- The comparison must **fetch first**. An unfetched ref would make a branch that
  landed during the run read as unlanded — the same error one turn quieter.
- And it is proven in both directions before it is trusted: a checkout on main
  reads `yes`, a commit above main reads `no`, a commit *below* main (an
  ancestor) reads `yes`, and a directory that is not a checkout at all reads `?`
  and `no` — loudly, never silently.

> The example line above was first pasted verbatim from a real receipt, with a
> real home path and a real estate name in it. The estate leak-guard failed this
> file on it — correctly, and for a second reason than the language guard did:
> an estate's own topology has no business in a shipped product. The line is
> shown in the shape a reader needs and not in the shape it arrived in. That is
> the third time this one rule's own text has had to be repaired by the guards it
> is about.

### The general form

Every measuring apparatus in a fleet is also an artefact of that fleet, changing
on the same schedule. Wherever a receipt records *what was measured* and *what it
was measured against*, ask what is missing: **what was it measured WITH, and can
somebody else obtain that.**
