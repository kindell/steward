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
half an hour is therefore a rest.

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
| deploy gate names a command that cannot work there | - | it refuses a detached worktree, then names `git pull --ff-only`, which answers "You are not currently on a branch" |
| liveness seam: "points at nothing" about a file that exists | skeppsbron | `lib/liveness.sh:96` cannot tell missing from unreachable; a fourth branch is needed |
| ~~the fifth short list~~ | closed | `lib/registry.sh:269` is hand-kept and has been short five times, but `test/identity-schema.test.sh:200` unsets EVERY derived key, sources the library and asserts the key is still unset - naming it. Guarded maintenance, not an open hole. The row was written from the comment's first sentence and not from the check |
| guards doc: a rule nothing asserts on purpose | basement | it belongs in `docs/guards-and-proofs.md` |
| desk-serve: the three wait loops | - | 793, 1075, 1150 - only 1150 asks whether the child is alive, and throws the answer away in its message |
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

## Done today

The manifest rows for what deployed code executes; five rollouts; the estate
leak-guard's collision rule; the desk invitation route.
