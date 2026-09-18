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

## Open

| item | held | note |
|---|---|---|
| liveness seam: "points at nothing" about a file that exists | - | `lib/liveness.sh:96` cannot tell missing from unreachable; a fourth branch is needed |
| the fifth short list | - | `lib/registry.sh:269` - a hand-kept derived set that has been short five times |
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
| the hub client pin | butler | `#104` - queued behind the manifest rows, which have landed |

## Done today

The manifest rows for what deployed code executes; three rollouts; the estate
leak-guard's collision rule; the desk invitation route.
