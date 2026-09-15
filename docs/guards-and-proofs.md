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

**The measured case.** Four suites start a *second* runner against a fixture
tree. Three of those fixtures hold a probe that is MEANT to fail: it is the
control group, the thing that shows the isolation bites when the protection is
removed. The nested runner inherited `RUN_TESTS_RED_DIR` from the environment,
and since a red suite now saves its whole output there, **the control group's
deliberate failures were written into the OUTER run's evidence directory.**

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
