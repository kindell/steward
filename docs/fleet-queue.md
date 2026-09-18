# The fleet's queue

WHY THIS FILE EXISTS. On 2026-09-18 two estates built the same one-line fix
twice, ninety minutes apart, and the second time it was work one estate had said
out loud was another's. Neither was careless. The queue lived in letters, and a
letter is a copy each, not shared state: the holder cannot see that somebody else
already started, and the starter cannot see that it was held.

The remedy after the first collision was a letter saying "ask me before building
something I said was queued as mine". That remedy was itself a letter, and both
of the items it covered were built by somebody else within the hour.

So: A CLAIM THAT CANNOT BE READ IS NOT A CLAIM. Taking an item means committing
a change to this file. The commit is the claim - it is readable by every estate,
it has an order, and `git log -- docs/fleet-queue.md` answers "who took what,
when" without anyone having to remember.

## This branch is never merged

The product names no estate. Measured on main 2026-09-18: ONE file in the whole
tree carries the word `basement` or `skeppsbron`, and it is the guard that
enforces the rule, carrying its own fixture data. `docs/` has none. A stranger
who clones the repo gets the mechanism and nobody's names.

This file names three estates in every row, because that is what it is for: a
claim that cannot say whose it is cannot be read. So the file and the tree are
incompatible by construction, and both are right. It stays on the `fleet-queue`
branch and never lands on main.

That costs nothing it needed. The property that makes the file work is not that
it is on main - it is that GIT REFUSES A CONFLICTING PUSH, which a branch does
exactly as well. It has already done so once, between two sessions of one estate,
ninety seconds apart.

ROLE WORDS WERE THE OTHER CANDIDATE AND THEY ARE CLOSED BY A MEASUREMENT.
Writing `the-darwin-estate` instead of a name passes the guard - that much was
tested and it is true. But a role word has to be resolvable by whoever reads it,
and the registries do not carry what it would need. Measured in two estates,
fields enumerated:

    hosts.d      OWNER LEGAL_OWNER OPERATOR SSH_ALIAS HOST_ADDR, warning
                 thresholds, port ranges
    peers.d      HUB_SSH, PRINCIPAL
    platform, os, kernel, darwin, linux:   NO MATCHES IN EITHER

So `the-darwin-estate` cannot be looked up anywhere, and `the-linux-estate` is
ambiguous because two of the three are Linux. The mapping is not merely absent
from the product - it is absent everywhere. Building it means a new field in
three registries for the sake of a docs file, and that change should be made for
its own reasons or not at all.

Both estates changed position on this, in opposite directions, and converged -
and neither had measured the premise they converged on. Agreement between two
who have both REASONED is not a check, which is the same sentence this fleet
wrote about two numbers earlier the same day.

Fetch it before taking anything: `git fetch origin fleet-queue`.

## How to use it

- To take an item: add your estate to its `held:` line and push. If two estates
  push the same claim, git says so, which is the whole point.
- To release one: remove yourself. An item nobody holds is open.
- An item is DONE when it is merged, not when it is built.
- This file is not a plan. It does not say what ought to exist; it says who is
  holding what right now, so two people do not hold the same thing.

STATE LIVES IN GIT, NOT HERE. Do not write branch tips, suite numbers or gate
results into this file - those rot, and a rotted number used as a reason is a
mistake this fleet has already made more than once today. Name the branch and let
`git` answer for it.

## A run in flight lives in git

A gate run exists only as a process on one host, and no enumeration can see it.
On 2026-09-18 a merge that was correct by every rule invalidated a fourteen-minute
run on another machine: the tree it measured stopped being the tree that lands.
The fact WAS in a letter - the runner had said so twenty minutes earlier - and it
did not reach the moment of decision, which is the second half of why letters are
not state.

    at start    git push origin <sha>:refs/gating/<short>-<host>-<timestamp>
    at end      git push origin --delete refs/gating/<short>-<host>-<timestamp>
    before a merge   git ls-remote origin 'refs/gating/*' - and do not merge over
                     somebody else's run

The first spelling adopted was `refs/gating/<sha>`, and three estates measured it
broken within minutes. A PAIR gates the same sha by definition, so that spelling
cannot represent two halves: the second push is a silent no-op with rc 0, and the
first half to finish makes the other invisible while it still runs. It broke in
the case it exists for.

The host says who to ask. The timestamp is not decoration: ls-remote returns names
and no dates, so without it a fourteen-minute run and a three-day-old corpse look
alike, and people learn to scroll past the list. Each estate publishes how long a
full round takes there, so a stale ref can be judged without asking anyone.

A FULL ROUND IS FIFTEEN MINUTES, measured on two estates and not estimated: one
reported 15m 01s, 15m 15s and 15m 14s over three runs alone on the machine, the
other 15m 07s. Fourteen seconds of spread across two platforms. A ref older than
half an hour is therefore a rest. The third estate measured 17m 27s over a single
run, start read from the ref's own stamp and end from the log file's mtime - so
its bound is thirty-five minutes. The thresholds differ and neither can be derived
from the other, which is why each estate publishes its own. A number that carries
its method can be weighed; one without can only be believed.

TAKE THE REF DOWN BEFORE THE NEXT LETTER, not merely "when the number is
published". The looser wording was written here first and it says WHEN without
saying WITHIN WHAT: a run finished, its number sat ready in a log, and its owner
spent twenty minutes writing about something else while the ref stood. A ref that
stays up while its owner is writing about something else is no longer a state -
it is the memory of one.

It was caught because the estate that was blocked DECLINED LOUDLY: its script
printed that it was standing down after twenty minutes, with the ref named. A
silent wait would have cost that estate a round, cost the owner nothing, and left
the rest undiscovered.

The first figure offered was 27 minutes, given in good faith and never measured -
read off a wall clock between starting a run and publishing its receipt, which is
the run PLUS the reporter's own letters and checks. It made one estate look twice
as slow as the other and the staleness bound twice as loose as it should be. The
estate that gave it measured it and withdrew it, with the reason: A NUMBER OTHERS
BUILD A THRESHOLD ON IS NEVER TOO SMALL TO MEASURE.

A crashed run leaves its ref standing - visible and dateable rather than silent.

THE NAME DISTINGUISHES ESTATES, NOT HANDS. One estate runs several sessions from
one unix home under one git identity, so two of its runs are spelled alike. On the
day the form was adopted this cost four misdirected attributions between three
estates - a branch credited to the wrong estate twice, a run credited to the wrong
session twice - and the cost each time was a paragraph in a letter.

A fifth instance followed, of a different and dearer kind: a DECISION sent to one
hand of a two-hand estate, which the other hand could not see and asked for again.
The first four were misattributions - corrected afterwards, nobody standing still.
This one cost a WAIT in real time, and neither party could discover it: the sender
did not know the word was missing, the waiter did not know it existed.

Three fixes, all on the side that can actually close it. The sender's, which needs
no form: A DECISION GOES TO EVERY HAND IN AN ESTATE, never to whichever hand wrote
last. Its other half, which costs one line: A DECISION THAT PERMITS AN ACTION NAMES
THE HAND THAT IS TO PERFORM IT - then a relay can be routed by whoever receives it,
instead of depending on somebody NOTICING that it concerns a neighbour. Both times
it was caught by chance, and a form that rests on somebody noticing is not a form. And the estate's own, chosen by the estate that pays for it: the ref name is
derived from REPO_PATH, so sessions in one home spell themselves apart without
anyone agreeing on a list, and a third session names itself. Register, slug and bus
name are untouched - a fleet-wide rename would charge three estates for a problem
that lives in one home.

A NINTH INSTANCE IS OF A DIFFERENT KIND: CREDIT ERASED BY A GUARD DOING ITS WORK.
A finding written into the product cannot name the estate that made it, because an
estate name fails the leak guard - an installation's topology is not the product's
to carry, and that trade is already settled with a number. So a finding quoted into
an issue arrives without its origin, and a reader attributes it to whoever filed it.
That happened here and nobody did anything wrong: the letter attributed correctly,
the issue could not, the reader read reasonably. The eight before were misdirected
credit; this one is erased credit, and there is no line anyone could have written
differently.

The two stores differ, and the difference should be KNOWN rather than discovered:

    letters   can attribute, cannot be kept
    issues    are kept, cannot attribute

Anything that needs both carries its origin in a form the guard passes - a ROLE, a
PLATFORM, a DATE - or the credit stays in the letters and the finding travels
without it. That is the transposition rule again, applied to credit instead of to
evidence: what crosses into a file with its own rules is transposed, not pasted.

EIGHT PAYMENTS, NO FLEET FORM, AND THAT IS A DECISION RATHER THAN AN OVERSIGHT.
The limit lives in three forms at once and they are not equally open:

    ref names        CLOSED, cheaply, by the estate that pays for it: the name is
                     derived from REPO_PATH, so a third session in one home names
                     itself with nobody agreeing on a list
    letter address   NOT closed by discipline - that failed three times in one day,
                     the third time inside the text declaring it closed. Closed
                     instead by mechanism: ONE LETTER, ONE MAILBOX. No broadcast
                     carries a second person. Two hands are thanked in
                     two letters, or in one that names them in the third person.
                     The rule was written the same morning it was broken again
    deploy receipts  OPEN. "DEPLOY sha=... homes=N rc=0" carries the estate and a
                     timestamp and no hand at all, and that line is the product's,
                     parsed by three estates

Only the third needs a product change, and its two payments so far - two receipts
each reading as "host two of three", and two hands running the same rollout - cost
nothing, because a rollout is idempotent and writes atomically. That is the tool's
property, not anyone's care.

THE TRIGGER IS NOT A HIGHER COUNT. It is the next payment that costs something
other than a paragraph. Eight paragraphs are worth less than one product change to
a line three estates read; one lost hour is worth more.

Why the count is written down at all: elimination that HITS costs nothing, feels
like knowledge, and teaches that the method suffices, while elimination that MISSES
costs a correction somebody has to write. A method whose hits are free cleans
itself out of memory every time it works - the same shape as a guard that is green
because it cannot fall. The count is the only thing that survives the hits.

No field is being added for it. A form that changed spelling once already should
not grow on a single day's irritation, and the estate that pays most for the
ambiguity is the one that declined to propose the change. The number is written
here so the next decision is made against a count rather than a guess about how
often it happens.

What this does NOT solve, so nobody reads it as more than it is: the race between
the push and the merge is narrower but not zero, a host with no network to origin
still runs blind, and rollouts and provenance checks have no ref at all.

## Open

| item | held | note |
|---|---|---|
| the drift refusal names a cause it cannot measure | - | it prints "the signature of an interrupted run" and omits the one fact that steers the reader. CORRECTED by the estate that hit it: the diagnosis is right in class - the drift check compares DISK against last-good, so for a home to fail, somebody had installed the FILE without yet writing the BASELINE, which is literally an interrupted run. What the guard cannot say is WHOSE. A reader gets "interrupted run" and fills in "my own earlier one"; there it was a neighbour finishing one second before. `--accept-drift` is harmless against the traces of a finished run and is a RACE against one still writing. Not a fault in the guard - the boundary between what a file comparison can know and what the reader needs. The remedy is NOT to enumerate more causes: the cause was rightly picked. It is to print the limit, in words like "a run left the file without its baseline; which run, and whether it is still writing, this comparison cannot see". The first asks the guard for more hypotheses; only the second would have stopped `--accept-drift` against a live run |
| `STEWARD_ESTATE` vs `STEWARD_ESTATE_ROOT` | - | deploy-self refuses with "set STEWARD_ESTATE" while one operator config carries only STEWARD_ESTATE_ROOT. Issue #71, and it bit in live operation 2026-09-18. NARROWED by a counter-measurement the same hour: one estate carries BOTH names and does not hit it, so the fault is not "the deploy reads the wrong name" but "there are two names and only one estate has both". A fix that renames inside the deploy would BREAK the estate that works. SHARPENED 2026-09-18 by running the onboarding chain on a host: the two names do not hold the same KIND of value. `STEWARD_ESTATE_ROOT` is the registry root (a directory); `STEWARD_ESTATE` is the path to `estate/steward.conf` itself (a file) - pointing it at the root answers "the estate file is missing". So this is not one value under two spellings, and a fix that treats it as an alias is wrong in a second way. It is what `invite redeem` step 11 fails on |
| deploy gate names a command that cannot work there | - | it refuses a detached worktree, then names `git pull --ff-only`, which answers "You are not currently on a branch" |
| liveness seam: "points at nothing" about a file that exists | skeppsbron | `lib/liveness.sh:96` cannot tell missing from unreachable; a fourth branch is needed |
| ~~the fifth short list~~ | closed | `lib/registry.sh:269` is hand-kept and has been short five times, but `test/identity-schema.test.sh:200` unsets EVERY derived key, sources the library and asserts the key is still unset - naming it. Guarded maintenance, not an open hole. The row was written from the comment's first sentence and not from the check |
| guards doc: a rule nothing asserts on purpose | basement | it belongs in `docs/guards-and-proofs.md` |
| desk-serve: the three wait loops | - | 793, 1075, 1150 - only 1150 asks whether the child is alive, and throws the answer away in its message |
| step 8 names a hub key nothing creates, and it is an INCONSISTENCY not a hole | - | `bin/steward:4443` hardcodes `$HOME/.ssh/id_ed25519.pub` as the hub's delivery key. Measured by running the chain on skeppsbron: absent, so step 8 refuses. CORRECTED the same hour by another estate, which HAS the file - a leftover probe key from August, its comment field naming a machine name no longer in use. The identifying details stay in that estate's own hands; what belongs here is the shape. So the same line SUCCEEDS on one estate and FAILS on another, and nothing in either outcome says which you got; on that estate it would succeed with a key nobody designated. The third host is the number still missing. The letter that reported this said "no host in the fleet has one" from a SINGLE host's measurement - a false fleet-wide negative, written in the letter arguing that a green suite says nothing about a machine. The fix is NOT to create the key: a hardcoded default path finds whatever happens to lie there, never what somebody DESIGNATED. The delivery key must be NAMED BY THE ESTATE, like `HUB_SSH` and `DESK_ORIGIN` - which is also the only form compatible with `bus-send`'s own header, since that forbids one key standing for a machine. `id_ed25519.pub` appears in five places in the tree: that one product line, TWO test fixtures that `printf` the file into existence, and the plan that specified it. Zero creators |
| step 8 can never report "already done" on a real host, and the consequence is a HANG | - | two of its three idempotence marks (`have_key` at `bin/steward:4445`, `have_deliver` at 4447) stat INSIDE the new account's home. `steward-account-helper` creates that home 750 owned by the account, so the hub cannot enter it. Measured in both directions on a real redemption: as the hub `[ -f ]` FALSE, as the owner TRUE. Both marks read false-absent while the truth is present, so `if have_key && have_row && have_deliver` can never fire; the step then runs `ssh-keygen`, which finds the file and PROMPTS. A non-interactive verb hangs on re-run - and re-run is exactly what the "already done" branches exist for. The helper's documented 750 and step 8's marks are incompatible BY CONSTRUCTION, so it is not a fault in either half alone. Same shape as the seam-unreachable work (fourth site), but the consequence is a hang rather than a wrong report. No test can see it: fixture homes are owned by the test user |
| the order spool has no trigger - nothing runs `steward desk apply` | - | the manifest installs ELEVEN systemd units and none of them runs it. The server writes an order, `desk/apply.sh` knows how to dispatch it, and nothing fires apply.sh - so a person who clicks an invitation queues an order nobody collects. `desk/apply.sh:91` says "A path unit fires on a directory that may already have been drained by a previous run" - a present-tense sentence about a unit that is not in the tree. `linux/agent-codex@.path` exists, so path units ARE a form the house uses; the absence is a gap and not a choice against the form. Fourth comment today describing machinery nobody built. Confirmed on a second host across five homes: zero units in any of them. WHICH unit should fire apply is an estate question |
| redeem step 11 runs a file no manifest row lands | - | `bin/steward:4622` runs `$HERE/linux/deploy-self.sh`. Manifest rows landing anything under `scripts/linux/`: ZERO. On a deployed host `$HERE` is `~/scripts` (bin/steward lands at `scripts/bin/steward`), and `~/scripts/linux/deploy-self.sh` is not there - measured with `ls`, on two hosts, five homes on the second. So step 11 works from a CHECKOUT and cannot work from an INSTALLATION, while the designed flow is deployed server -> spool -> deployed apply.sh -> deployed steward -> step 11. Identical in shape to `steward-account-helper`: a program bin/steward EXECUTES, installed by zero rows, invisible to every suite because suites run from the checkout. `cockpit` is also absent from the manifest and is NOT the same: it REFUSES with a sentence naming the requirement ("run bin/steward from a product checkout"). Step 11 says nothing and would fail with "No such file or directory" wrapped in "step 11 (skeleton) failed". Same absence, two very different costs to whoever debugs it. Whether a deployed home should be able to run a deploy AT ALL is a security question and belongs to the estate, not to a hand |
| the invitation link hardcodes the desk's mount | basement-product | `bin/steward:3573` built the link as `$origin/desk/invite/$token` with the mount HARDCODED while the desk serves wherever `DESK_PREFIX` says. Measured both ways in loopback, same binary, only the mount changed: with MOUNT `/desk`, `/desk/invite/x` -> 404 (route reached, token unknown) and `/invite/x` -> 403 (identity gate, route never reached); with MOUNT `""` the two answers swap. So on an estate that sets `DESK_PREFIX=""` the link never reaches the route at all. An INCONSISTENCY, not a hole: counted on three hosts, two set nothing (default mount, link correct) and one sets empty (broken), from one line of code with nothing in the outcome saying which you got. Being fixed in #123, which also had to add `--front` to desk-paths - asking it for the mount otherwise makes the INVITATION depend on the desk's STATE DIRECTORY, which two estates discovered independently as ~200 red tests |
| `guard-enumeration` | skeppsbron | committed, base has rotted, needs a rebase before it can be measured |

## Held

| item | held | branch |
|---|---|---|
| desk-serve diagnosis | butler | in flight - the only estate where the fault reproduces |
| root targets / the account helper | skeppsbron | `root-targets` |
| DESK_ORIGIN https only | skeppsbron | `desk-origin-https-only` - awaiting a darwin half |
| the wrapper's failure window | basement | `#107` |
| the bridge failure's cause | skeppsbron | `bridge-failure-names` - basement's `#108` was withdrawn for it |
| the hub client pin | butler | `#104` - nothing is queued in front of it now |

## Is this row a test? One question, asked at the moment it runs

Settled 2026-09-18 across three estates, after six one-off counts came out correctly computed
and answering the wrong question. **Four carried no control row, and NONE was caught by the
person who ran it** - two were saved by the answer being absurd on its face, the rest by another
hand holding the counter-example.

This is not a new rule. It is rule 23 - *consistent numbers are not a check; put the control
assertion beside it* - applied to a COUNT instead of a suite. It gets missed because a count
LOOKS like an observation, and nobody asks an observation whether it could have been right for
the wrong reason.

**The criterion, in the form it collapsed to:**

> CAN THIS ROW BECOME FALSE FROM THE ERROR I AM LOOKING FOR, AT THE TIME IT RUNS?

Three conditions were proposed separately during the evening and all three turn out to be
CONSEQUENCES of it rather than additions - a partition cannot become false from any error at
all; a number frozen in a comment is already false; two dependent measurements cannot diverge.
So is a fourth: an empty predicate ("is the key mentioned in some test" came out 19 of 19 with
the known defect sitting inside that hundred per cent) fails on *from the error I am looking
for*. The time index is the one clause that does NOT fall out, and it is what makes the question
askable more than once: without it the criterion is true of any row that was ever sharp.

Tested against four cases whose answers were known before the question was put - it accepts the
one form that actually caught the hardcoded mount ("zero literal mount paths outside the desk
module", a plain absence claim) and rejects the three that could not have. A heuristic tried
first - *prefer a relationship to a presence* - was DISCARDED for rejecting the only form that
worked.

**Two checks, two different questions.** The row above validates the INSTRUMENT. A mutation test
needs a second one that validates the RUN: that the edit actually landed. A mutation that did not
apply and a row that cannot fall produce the SAME observation - no change in the number - and the
natural reading is the second. Diff the file; a mutation test that cannot show the file changed
has shown nothing.

**Where to put it.** A standing tool runs its own control row every call (`bus-behind` does). A
one-off sweep has no tool to build into, and the place that remains is the LETTER: the expected
answer written in the same text that will carry the number, before the run. That is auditable
discipline, not mechanism - somebody must still remember - but a reader can afterwards see
whether it was done, which moves the discovery off the author.

## Two ways to find a defect, and each is blind to the other's kind

Settled 2026-09-18 by four findings in one evening, two from each method.

    INCONSISTENCY   fails on one estate, succeeds on another, from the same line
    HOLE            fails identically everywhere

- **Comparing estates** finds inconsistencies and is blind to holes. A hole looks the same in
  every home, so the comparison shows nothing at all.
- **Running the chain on one machine** finds holes and is blind to inconsistencies. One machine
  is ONE configuration - a single point in the space.

From the comparison: the hub key `id_ed25519` (absent on two hosts, present-but-wrong on the
third) and the link's mount. From the run: step 11's missing file and the absent unit. Neither
pile was reachable by the other method: whoever ran the chain has only their own configuration,
and whoever compares estates sees an identical absence everywhere and reads it as normal.

The practical consequence: one estate alone finds only holes; a fleet that never runs the chain
on a machine finds only inconsistencies. **Three estates are not redundancy - they are a second
instrument**, and neither instrument is optional.

**A third kind and a third instrument**, both added the same evening:

    DRIFT   the machine differs from what the CODE says

Drift is neither a hole nor an inconsistency: the code is right, every estate is alike, and the
machine is still not what the code describes. Running the chain finds it only when it happens to
bite; comparing estates misses it when all have drifted the same way - which is the normal case,
since they drift for the same reason. The instrument is a third: **compare the TREE against the
DISK**, which the deploy already does against last-good but only during a rollout, never as a
question somebody asks. Run on all three hosts in ten minutes and costing no machine time: every
difference was a lagging rollout, and **zero hand edits anywhere** - a measured negative worth
more than the three ratios, because the whole drift category rests on the deploy being the only
way code reaches a machine.

A defect can CHANGE KIND when it is half-fixed. The account helper was a HOLE in the morning
(called from four places, installed by zero rows); the manifest row landed in the afternoon; what
remains is one host of three without the file, which is DRIFT. The hand that wrote the row went
on citing the hole as open for hours - **whoever fixes half of something is the likeliest to keep
describing the whole of it with the old word**, because what you remember is the problem you
solved, not the solution.

**And a fourth method, which finds siblings rather than firsts:** ask what a guard that SHOULD
have caught it actually matches. It needs no second estate and no host - it is a reading, available
to any hand at any time, and therefore the cheapest. But nobody asks it until a defect is already
found by one of the other two, so it does not find the first instance; it converts one instance
into a class sweep. Measured on `deploy-manifest` check 8, whose expression matches only
`$VAR/bin/…` and `$VAR/desk/bin/…`: of the four programs `bin/steward` executes it reached TWO. It
is worth asking backwards about every hole already on this list.

## Done today

The manifest rows for what deployed code executes; five rollouts; the estate
leak-guard's collision rule; the desk invitation route.

**The onboarding chain run on a host for the first time** (skeppsbron, a marked probe
principal issued against a throwaway COPY of the estate root so no link-bearing value was
written to the real one, redeemed for real, the account and its hub authorization row then
removed). Steps 1-10 pass; step 11 fails on `STEWARD_ESTATE`; step 12 is still unmeasured.
Step 3 created a real unix account through the deployed helper and `sudo -n` - uid, home
750, groups, lingering, measured with `id` and `getent` rather than read out of the receipt.
That is the measurement plan 1 wrote out of its own scope with "Out of scope: Measurement 4
belongs to the estate, not to this plan", and it had never been true on any host.

Both step-8 rows above were found by RUNNING it. Neither is visible to reading, and neither
is visible to a green `invite-redeem` (186/0), because that suite's fixture `printf`s the
key file into existence and its homes are owned by the test user. That is now three holes in
one chain with the same shape - the helper installed by zero code lines, the hub key created
by zero code lines, the marks that stat through a home the caller cannot enter - which makes
it a pattern rather than three accidents: **every plan here ends at "tests pass", and a test
whose code manufactures its own precondition says "the logic is right", never "the machine is
ready".** The cheap check is to grep the tree for the literal path; if the only writers are
under `test/`, the precondition is manufactured.
