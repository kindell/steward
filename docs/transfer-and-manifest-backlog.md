# Moving between estates, and what a session owns — the reviewed backlog

**Status:** item 1 DECIDED 2026-09-15; the spec is unblocked and not yet
written. Eleven items still design-only, nothing built. Twelve items, ordered. Written
2026-09-14 after an independent review of five proposals by the advisor on
another estate, which found three of them wrong in their first form and saved
them in a better one.

The transfer verb is step 3 of the agreed order (1. lifecycle gate — merged.
2. Desk across estates — **merged, on main**. 3. the transfer verb — **next**.
4. Desk as authority — deferred). This document is not the spec. It is what the
spec has to be built on, and item 1 below was why the spec could not be written.
It now can be.

**What the first use of it will be, measured 2026-09-15 rather than assumed:**
fifteen rows in the Point domain on one estate, owned by **two different
people**, to be moved to another machine. That is a materially different
operation from the six-row login switch completed the same night: those rows
changed which login they used *on the same machine*, and kept their home, their
keys, their rig numbers and their bus identity. A move between estates keeps
none of those by default, and half the rows are not the estate owner's to move.

---

## 1. Define "in two places at once" — DECIDED 2026-09-15

The estate owner's condition for a move is *never in two places at the same
time*. That sentence has four possible meanings and they are not the same rule:

| candidate | is it a violation? |
|---|---|
| two registry rows the lifecycle permits to run | **yes** — safety |
| two supervisors entitled to spawn or adopt the process | **yes** — safety |
| two writers to the same transcript under one vendor session id | **yes** — safety, and the one that destroys the value |
| two copies of the data | **no** — an archive is expected |

**Without this distinction no fence can be tested**, because a recovery can
satisfy row uniqueness while an isolated old runtime keeps writing locally, and
that reads as success.

### The definition, decided by the estate owner 2026-09-15

This is no longer a proposal. It was put to the estate owner as the one thing
blocking the transfer verb's spec, with the four candidates above and the
consequence of each, and accepted as written. The wording below is the rule.

> **At most one estate may hold the ACTIVE CLAIM on a session at any moment.**
>
> The active claim is three rights held together, never separately:
>   1. a registry row whose `LIFECYCLE` permits it to run,
>   2. a supervisor entitled to spawn or adopt its process,
>   3. the right to write its transcript under its vendor session id.
>
> **Copies of data are not claims.** A source copy retained after a completed
> move is an archive, and keeping one is the expected outcome — not a breach.

The fence therefore has to measure all three rights, not only the row. A move
that ends with the row retired on the source while its supervisor could still
adopt a process has not fenced anything; it has renamed the problem.

**Why the third right is in the list.** The transcript is where a session's
value actually lives. Two writers under one vendor session id corrupt the thing
being moved, silently, and neither estate's register would record that it
happened.

---

## 2. The offer and the receipt get cryptographic identity

**Drop the rule "the receipt never travels as a file."** That was the wrong
axis, and it was load-bearing in the original design. A channel message can be
copied, replayed and delivered twice exactly as a file can. A *signed* file is
safe; an *unsigned* channel packet can be a second move.

At-most-once comes from the content, not the pipe:

- a unique `MOVE_ID`
- binding to the source estate, session and **owner epoch**
- binding to the exact target estate, account and host
- a hash of the manifest and the payload
- a permanent consumed ledger with atomic check-and-record

A **bearer offer** that any estate can redeem is movable by the wrong party.
The offer names its destination or it is not an offer.

---

## 3. Finalizers are phase-local, never one global list

A Kubernetes finalizer works because several controllers mutate **the same
authoritative object** under compare-and-swap. Three independent estates have no
such object. If the source holds the list, the target must still send
authenticated durable proof before an entry can be removed; if both hold copies,
there are two lists that can disagree.

A global list plus the stop-at-uncertainty rule **locks permanently** the moment
any party dies after having its effect but before acknowledging. That is the
dead end.

Each phase therefore runs only the steps its own estate can verify:

- **`move-out`** — source-local, while the source is reachable: close the
  lifecycle and future-spawn gate, stop and fence the process, freeze the
  mailbox and worktree, revoke the source actors' right to write. Only when all
  of those are verified is a destination-bound offer written.
- **`move-in`** — target-local: claim in the consumed ledger, create the row
  suspended, mint new keys, copy and verify artefacts. **No target process
  starts before the commit point.** When the local journal shows complete, the
  same receipt can be re-derived and re-sent.
- **`move-finish`** — source-local cleanup after the receipt. If the source dies
  here the tombstone stays unfinished, but the target is already the sole active
  claim: that is operational debt, not split-brain.

Remote proof passes at exactly two points: the offer and the receipt.

---

## 4. The tombstone is a fencing receipt, not a row edit

`LIFECYCLE="suspended"` is a write to a file. A process that is already running
does not necessarily re-read its row, so the source can keep writing after the
target activates.

A valid offer requires measured facts:

- the supervisor is off for that row,
- the runtime, its tmux session and its bridge registration are **observed
  gone**,
- the source cannot restart it under the old owner epoch.

**The offer is the commit of the source relinquishing ownership**, not an
announcement that it intends to.

---

## 5. One at-most-once point; everything else idempotent

At-most-once versus reconciliation was a false dichotomy in the original
proposal. Exactly one transition may be at-most-once:

> the target's claim of `(session id, source epoch, MOVE_ID)` in the consumed
> ledger.

Everything before and after is at-least-once and idempotent: copying with hash
verification, key creation, staging the row, delivering the receipt, source
cleanup.

**At-most-once *delivery* is dangerous**: a lost receipt locks the move. Send
the receipt at-least-once and deduplicate on `MOVE_ID`. Exactly-once *effect*
is built from durable idempotency, never from trying only once.

And the constraint that keeps reconciliation safe: **it may never create a new
claim, change ownership, or reactivate the source.** It may only complete
effects under an epoch already claimed.

---

## 6. `forced-recovery` is a separate verb, and it is not a move

A distributed check cannot tell a fire from a partition, so the automation must
stop — that rule stands. But a permanently dead source would otherwise make a
move impossible to finish, so an operator path is needed.

It is **not** a force-detach and must never be dressed as the ordinary move:

- it proceeds only on **positive fencing evidence** — the machine is destroyed,
  its storage is unreachable, the account, keys or overlay access are revoked,
  or some other mechanism makes the old incarnation *unable to write*;
- **a timeout is not evidence.** "Has not answered" is not evidence;
- the original incomplete transaction is kept, and a separate irreversible
  recovery receipt records the actor, the time, the reason, and **which fences
  were measured**.

If full fencing cannot be proven, the "never two" guarantee cannot be held. It
is then more honest to create a **new session with a new id and a handover**
than to claim the old one was moved.

---

## 7. Conflict is first-class in the Desk — BEFORE the fleet page

A read-only view needs no leader election: nothing is written, so two Desks
serving the same document are not a correctness problem. That part of the
earlier reasoning stands.

**But split-brain is not harmless, and that part was wrong.** It corrupts
nothing by itself. It misleads: a merged view that shows a session as one object
can hide that two estates make conflicting claims about it, and a person then
clicks attach, login or stop on the wrong copy. Tomorrow's acting Desk would
inherit the read model as its authority.

The rule, to be honoured before the overview page is built:

> The same session id active in two estates is **never deduplicated and never
> picked**. It renders as `CONFLICT`, naming both estates, and every route that
> later *acts* fails closed on it.

Provenance per source stays beside every row, and stale or unavailable coverage
stays visible next to it.

**Today's reader is safe by construction**, not by having solved this:
`desk/render.mjs` renders one block per estate and merges nothing. The rule
exists for the page that will merge.

---

## 8-10. The session manifest

### 8. A richer schema than "how it travels"

Each entry carries:

- **relation** — `owns` · `references` · `derived` · `shared`
- **weight** — `safety-critical` · `continuity-only`
- **operation** — `copy` · `create` · `revoke` · `regenerate` · `verify` ·
  `retain` · `archive` · `ignore`
- **verifier** — how the operation is proved to have happened
- **phase** — which of move-out / move-in / move-finish owns it

`shared` is the column that matters most: the credential directory belongs to a
**login**, which is a person's subscription, not a session's property. A session
move *verifies* that the target has the named login; it never copies one. A
person move is a different manifest.

### 9. One catalogue, two plans

The same inventory answers both questions, but **not with the same actions**. A
transcript is `copy`+`verify` on a move and `retain` on a retirement; a bus key
is `create-new`+`revoke-old` on a move and `revoke` on a retirement; a
materialised `.env` is `regenerate` on a move and `remove` on a retirement.

Separate policy columns per phase and for `retire`, or two plans generated from
one catalogue. Do not force the move vocabulary to mean retirement.

**This is worth building whether or not the transfer verb is:** today nothing
sweeps after a retired row. The mailbox, the bus key and the transcripts stay,
because nothing knows what belonged to the row.

### 10. The inventory is larger than the obvious six

Traced first: the registry row, `.generation`, `.last-sid` (the bridge to the
vendor's session id), the mailbox, the bus key, and the transcript that
`.last-sid` names. Five of those are already keyed by the session id.

The review added, and none of these were in that list: the working copy's
writable state (uncommitted, index, untracked, stash, branch); the live process
with its supervisor, tmux and remote-control registration; the browser rig's
profile, cookies and ports; materialised environment and secrets — **regenerate,
never copy**; MCP-rendered state; resume, fork and counter files and logs; the
OpenCode session id, password and memory snapshot with its proposals; jobs and
schedules that reference the session; pending, done and failed bus messages; and
**the hub's `authorized_keys` line**.

---

## 11. A row that cannot deliver should be able to say so

Measured 2026-09-14, three times in one morning: an advisor read a review order,
worked for eighty minutes including a subagent with 191 tool calls, reached a
usage limit **while sending**, and from outside was indistinguishable from a row
that had done nothing. The only way to learn otherwise was to read its tmux
pane, and the answer differed depending on how far up one scrolled.

This is the family the estate keeps removing: `uncensused` on a row,
`unavailable` on an estate, `(does not resolve)` on a login. A state that exists
and cannot be seen is found by someone wondering why it is quiet.

**A row that holds an answer it cannot send should be able to report exactly
that.** Not "running", not "idle" — *blocked on delivery*.

---

## 12. What does not change

The three-verb protocol stands. Stopping at uncertainty stands. No leader
election for a read-only view stands. The review's own recommendation was to
keep all three and fix the machinery under them, which is what items 2-6 do.

---

## Order

1. **Item 1**, the definition. Nothing below is testable without it and the spec
   cannot be written.
2. **Item 7**, the conflict rule, before the overview page exists rather than
   after.
3. **Items 8-10**, the manifest, which pays for itself on retirement alone.
4. **Items 2-6**, the transfer spec, once 1 is settled.
5. **Item 11**, independent of all of it.
