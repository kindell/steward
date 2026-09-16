# Moving a session between estates — the transfer verb

**Status:** design, nothing built. Step 3 of the agreed order; steps 1 (the
lifecycle gate) and 2 (Desk across estates) are merged.

**Input:** `docs/transfer-and-manifest-backlog.md`, twelve reviewed items, of
which item 1 is decided and the rest are design-only. This document is what gets
built; that one is what it is built on.

---

## 1. What the verb is for, and what it is not

A session's value is its transcript, its memory and its identity on the bus. A
move must carry all three to another estate and leave nothing behind that can
still act as that session.

**It is not a login switch.** A login switch changes which account a row uses on
**one machine**; the row keeps its home, its keys, its rig numbers and its bus
identity because none of those moved. A move between estates keeps **none** of
them by default. Every rule below that looks like ceremony is there because one
of those was silently kept or silently lost.

**It is not a recovery.** A source that cannot be reached is a different verb
with a different safety story (backlog item 6). This verb assumes both estates
answer.

---

## 2. The safety property

Decided by the estate owner 2026-09-15:

> At most one estate may hold the **active claim** on a session at any moment.
> The active claim is three rights held together, never separately:
>
> 1. a registry row whose `LIFECYCLE` permits it to run,
> 2. a supervisor entitled to spawn or adopt its process,
> 3. the right to write its transcript under its vendor session id.
>
> **Copies of data are not claims.** A source copy retained after a completed
> move is an archive, and keeping one is the expected outcome — not a breach.

**The fence must measure all three.** A move that retires the row on the source
while its supervisor could still adopt a process has not fenced anything; it has
renamed the problem. The third right is in the list because the transcript is
where the value lives: two writers under one vendor session id corrupt it
silently, and neither estate's register would record that it happened.

---

## 3. Preconditions, and the three classes they fall into

Every precondition the verb checks belongs to exactly one class, and **the verb
states which**. This is not bookkeeping: the classes have different failure
modes and different remedies.

| class | who can measure it | what a failure means |
|---|---|---|
| **A** | the operator | the thing is absent |
| **B** | only the owning account | unknown — the operator cannot see it |
| **C** | the operator, but several objects answer | possibly the right answer about the wrong object |

**Class B exists because homes are `750`.** Credentials live in a home and are
per home *and* per machine; a login on one account is nothing to another. An
operator who reports "no credential" for a home they cannot read has reported
their own blindness as the estate's state. The verb must measure class B **as the
owning account**, or report it as unmeasured — never as absent.

**Class C is the dangerous one, because it succeeds.** A and B fail visibly; C
returns a true answer about something nobody asked about. Measured instances: a
home's own copy of the register read as the estate's, giving a count four times
too low; a deployed tree read as a checkout. **A class-C check must name the
object it read** — *"29 rows in the nav's register"*, never *"29 rows"*.

### The preconditions themselves

**On the destination:**

- a unix account and home for **every** owner whose rows are moving — class A
- a `principals.d` row for that person, and an `accounts.d` row binding account
  to principal — class A
- credentials present in **that** home — class B, measured as that account
- a free rig block if any moving row declares a rig, and the destination's
  retired-number list — class A. *A display number is never reused; an empty
  retired list is a fact, not an absence, and must be reported as empty rather
  than unknown*
- space for the transcripts — class A. *Size them from the largest measured row,
  not the average: one row has been measured at 150 MB*
- the bus: whether new rows can be enrolled, and whether the estate answers
  machine questions — class A

**On the source:**

- the row exists and its `LIFECYCLE` permits it to run — class A
- the operator can act as the owning account — class A
- nothing in the destination's target directory that exists only there — class A,
  see §6

**Account creation is a precondition the verb CHECKS, never one it satisfies.**
An account is a person's foothold on a machine. A verb that creates accounts as a
side effect of moving a row can create one by accident. It is a separate,
deliberate step that somebody decides once.

---

## 4. The order, and why each step is where it is

The order is the mechanism. Three rules fix it completely:

1. **The hand that writes must survive the writing.** A hub cannot kill itself,
   wait out its own death, copy and respawn. Within an estate, its hub goes last.
2. **The coordinating estate goes last overall.** By then its only available
   witness is the estate owner; spend it earlier and you have used the
   coordinator on a row that had cheaper witnesses.
3. **No estate's hub writes another estate's rows.** Domain-bound authority,
   and it holds even when a relay says go.

### Per row

```
0.  measure the preconditions (§3) and refuse on any class-A failure
1.  take the before-image (§5) — it cannot be reconstructed afterwards
2.  KILL the process, on its pid, never by pattern
3.  wait for the PROCESS, not the clock
3b. list what exists ONLY in the destination, and stop if the list is non-empty
4.  copy — transcript and memory, direction decided per directory kind (§6)
5.  WRITE THE ROW — on the destination, and retire it on the source
6.  let the supervisor take it up
7.  the witness measures (§7)
```

**Step 5 is last among the writes, and that is measured.** The supervisor does
not wait: the moment a row's `LOGIN` is rolled out it starts the session against
a tree the copy has not filled. Measured on a login switch: eight minutes of
flapping across seven spawns, both transcripts frozen, recovering the second the
copy landed. **The window grows with the transcript** — the same mistake on a
150 MB row flaps longer, not shorter.

**Steps 2, 4 and 5 must be TIGHT.** "Copy and kill in one command" is not enough
if one of the steps is slow: a sync tool between the kill and the row wrote 1 225
decision lines, and the supervisor respawned during it. The repair is a division
of labour, not a faster tool:

> **The tool decides WHAT to copy. A plain `cp` owns the WINDOW.**

Run the tool first, for the decision; then copy with the cheapest thing that can
do it. Measured: run tight, the gap between the frozen source and the copy was
**zero bytes**.

---

## 5. The before-image

Some facts stop existing the moment the switch happens and nobody can
reconstruct them. Take them while the old process still runs, and write them
where both the operator and the witness can read them — not into a letter:

- whether it runs **with or without `--resume`**, and if with, **which
  conversation id**
- its pid, its birth, its uptime
- the transcript file it is actually writing to, with size **and line count**
- which tree holds its session record

---

## 6. What to copy, and in which direction

**The whole project directory, not an enumeration.** An enumeration forgets; a
whole cannot. One estate survived a two-item list only because somebody copied
their memory files by hand, out of habit — and a plan that survives on an
unwritten habit is not a plan.

**But the target may not be empty, and then the direction is per directory kind,
not per file.** Measured on one estate:

```
transcripts   the same uuid in BOTH trees; the live one newer in the SOURCE
memory        38 files in the TARGET, and ZERO in the source
```

A whole-directory copy in the obvious direction overwrites thirty-eight live
memory files with nothing — the only step in this operation that destroys
something existing nowhere else. So:

> **Decide per directory kind, against measurement — and copy a file when the
> source is newer OR when the target does not have it at all.**

- **"newer OR missing", not merely "newer."** A file absent on one side has no
  timestamp to lose a comparison with.
- **Leave identical files alone.** Copying them anyway hides which files moved,
  and that list is the only receipt of what the step did.
- **The source is the directory the session runs against NOW** — never the one
  that happens to hold the file. A tree can hold a bigger, older, more convincing
  copy of the same uuid; **size is not provenance**.
- **On a collision the target's file is moved aside with a timestamp**, never
  quietly overwritten. The one step that destroys something is the one step that
  must leave a receipt.
- **Compare directories by their entries, never by their size.** `stat` on a
  directory returns its entry table: an empty one and one holding thirty-eight
  files differ by 64 against 1280, and it reads like content.

**Where a row's memory lives is a per-row fact.** A claude-code row keeps memory
under the login's `projects/`; another runtime may pin it to an absolute path
outside every login tree, in which case the copy neither carries it nor needs to.
Check the row.

---

## 7. What the witness measures

**A session cannot verify its own restart.** That is why this section exists, and
every rule in it follows from it. From inside, the worst outcome looks like
nothing at all: a session that starts without its transcript in the new tree does
not error — it forks a new thread silently, lives, answers, and has lost its
conversation.

1. **A process exists for the row** — found by the row's own identity in `argv`,
   never by a pattern that could match the checking command itself, and never by
   `pane_current_command`, which reads `bash` for a healthy session too.
2. **The generation carries a real pid and birth.** An empty pid with
   `spawn_state=started` is the silent state.
3. **Which tree holds `sessions/<pid>.json`** — a written artefact, not an
   environment variable. `CLAUDE_CONFIG_DIR` is legitimately absent when the
   target login is the default directory, and absent is indistinguishable from
   failed. Two rows on one machine can be told apart by a file each of them wrote.
4. **The pair of files.** After the move the source's copy is frozen and the new
   one grows. Two files of the same name, one moving and one still, is not
   compatible with the session writing anywhere else.
   - a **new uuid appearing beside it proves nothing** — the usage meter writes
     one every time it runs
   - a file that is **not growing means idle, not dead**. Send the session a
     letter and measure after it answers; *"let it work first"* without a way to
     make it work is a delay dressed as a method
5. **The new tree's transcript is not SHORTER than the frozen source's** —
   counted in **lines**, not bytes. A byte count can fall for a legitimate
   reason; a live `.jsonl`'s line count only grows.
   - **valid only once the source is DEAD.** Against a live source the target is
     normally shorter and that means nothing
   - **compare the last USER or ASSISTANT line, not the last line.** A `.jsonl`
     ends in bookkeeping written during shutdown, so a killed source almost
     always ends in records that are not conversation. Measured: two trees agreed
     through line 6982 and diverged at 6983, and all fourteen extra source lines
     were state. By the count fourteen lines were missing and it read as lost
     conversation; by the content nothing was lost

**A witness that quotes the measured party is not a witness.** It is the same
claim twice with a different sender, and it is more dangerous than no witness
because it sounds like confirmation. **And a failed lookup is not an absence:**
`ssh <host>` without `-i` failing answers *"did the keys I happened to offer
work?"*, not *"is there a way?"*

---

## 8. What the verb does not do

- **it does not create accounts** (§3)
- **it does not recover from an unreachable source** — that is item 6's verb
- **it does not grant machine answers.** `FRAGA` does not cross an estate link at
  all; it is refused at the sender's gate and again at the receiver's. A moved row
  gains machine answers from its new estate only once its row lives there, and
  only if that estate has a catalogue. Until then a `FRAGA` is *left for the
  model*: slower, never silent. The spec must not assume otherwise
- **it does not decide what a row is named.** Naming is an open question
  elsewhere

---

## 9. Open, and deliberately not decided here

- **the offer and the receipt** (backlog items 2, 4) — cryptographic identity for
  the hand-off, and the tombstone as a fencing receipt rather than a row edit
- **phase-local finalizers** (item 3) and **the single at-most-once point**
  (item 5)
- **conflict in the Desk** (item 7) — surfacing a contested claim to a person
- **the session manifest** (items 8–10)
- **where `desk-remotes.conf` lives**, and whether estates get a register
  category of their own

---

## 10. What this is built on

Every rule above has a measurement behind it, and most of them cost something to
learn. The method document for the single-machine case is
`docs/login-switch-plan.md`; the rules about believing a green test are
`docs/guards-and-proofs.md`. Where this spec and either of those disagree, they
were measured on different things and the disagreement is the finding.
