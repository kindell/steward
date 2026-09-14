# Switching a session's login, with a witness

**Status:** in flight 2026-09-14. One of six rows done. Written so the three
stewards can read the same thing instead of reconstructing it from letters, and
so the estate owner does not have to choose at each step.

A session cannot verify its own restart. That is the whole reason this document
exists, and every rule below follows from it.

---

## The failure this guards against

A session that switches login without its transcript present in the **new**
login's tree does not error. `linux/session-supervisor-linux.sh` says it
plainly:

> *"A session that changes model account while keeping the path looks in the
> WRONG account's history — and this selector falls OPEN to a fresh start, so it
> forks a new thread SILENTLY. The session lives, answers, and has lost its
> conversation."*

**From inside, the worst outcome looks like nothing at all.** The session
answers the bus, reports healthy, and does not know what it lost. It is the only
fault in the operation that cannot be measured by the party it happens to — so
it must be measured by somebody else.

A second failure, found the same evening: a **fresh login tree has never run the
first-time dialog**. A switched session came back with the right root, the right
conversation and the right `--resume`, and stood waiting in the theme picker.
Live process, zero progress, forever. It had not lost anything; it had never
started, and it could not report that because it was not running.

---

## Preparation, per estate

Nothing below may begin until all five hold. Verify them; do not assume them.

| | check |
|---|---|
| the login row | exists **in that estate's own register** — authority is domain-bound |
| the credential | `claude auth status` in the target directory answers the right account. A credential is per home **and** per machine; signing in on one estate does nothing for another |
| the onboarding fields | `hasCompletedOnboarding`, `lastOnboardingVersion` (the installed CLI's version), and `settings.json` — without them the session stops in the theme picker |
| the product | new enough to carry the login machinery the switch needs |
| `steward` on PATH | a symlink in `~/bin` to the deployed binary; a login shell finds it there |

Transcripts are **not** prepared in advance. See the next section for why.

---

## The five steps, in order, per row

The order is the whole mechanism. Steps 2 and 3 exist because of a death gap
that an earlier draft of this plan left open.

1. **Write the row** — `LOGIN=` in the estate's register **and** in the deployed
   tree. The supervisor unit sets no `STEWARD_ESTATE_ROOT`, so it reads
   `~/scripts/sessions.d`: a commit alone looks like a switch without being one.
   Compare the two with `cmp`.
2. **Stop the session.**
3. **Wait until the process is actually gone.** Not the row, not the unit — the
   process, checked in a loop. Not "wait a few seconds": measured on the last
   row of this operation, the transcript's final mtime was the exact second the
   signal was sent — **a session writes its last bytes while it dies**, and a
   copy taken one second early would have left them nowhere at all.
3b. **List what exists ONLY in the target, and stop if the list is not empty.**
   Step 4 begins by deleting the target, and the case where that destroys
   something is FALL C below — but the check belongs here, as a step, not there
   as an explanation. On the last row of this operation the check was made
   because the operator had happened to read another estate's figures an hour
   earlier, not because anything told them to; a plan that survives on that is
   the unwritten habit this document already warns about, one level up.

4. **Copy the whole project directory now**, in this minute, and read the size
   and mtime **of the fresh copy** of the transcript. That pair is the *before*
   value. Copying earlier gives a file that ages while the work continues; using
   the pre-copy number as the reference measures the copy instead of the session.

   **The whole directory, not the transcript.** Beside the `.jsonl` and its uuid
   directory sits `memory/`, and a step that names two things is silent about
   the third. One estate survived that only because somebody copied their memory
   files by hand, out of habit — and a plan that survives on an unwritten habit
   is not a plan. An enumeration forgets; a whole cannot.

   And the ageing is not only the transcript's: measured on this estate, a
   memory note was 2 899 B live and 2 041 B in a copy fourteen minutes old,
   while the **file count matched exactly**. Counting is not comparing.
5. **Respawn**, and let the witness measure.

### 4b. The copy's own size is the before-value — and only the copy's

This is worth its own heading because it has now been got wrong three times in
one evening — and the third was by the person who wrote the rule, citing it in
the same message.

That third case is the instructive one: the conclusion came out right anyway, so
nothing looked wrong. The comparison used a copy from an hour earlier, and the
copying alone had added 1.1 MB — so **the file would have read as grown even if
the session had forked into an empty tree.** A test that cannot fail is not a
test, and it takes an outside reader with the real before-value to notice that
it never could have.

Taking the size of a copy made *earlier* and calling it *before* means the file
grows by however much the fresh copy added — and **"the same file grew" is then
satisfied even when the session forked into an empty tree.** The test passes on
the failure it was built to catch.

Read the size and mtime after step 4 completes, of the file that now exists.
Nothing measured before that moment is a before-value.

### 4b'. Where a row's memory lives is a per-row fact, not a general one

Step 4's whole-directory copy covers memory **only when the memory sits in the
login tree**, and whether it does depends on the row:

- a **claude-code** row keeps its memory under the login's `projects/` — it
  follows the login, and the whole-directory copy carries it;
- an **opencode** row may pin `CLAUDE_MEMORY_ROOT` to an absolute path outside
  every login tree, in which case the copy neither carries it nor needs to.

Measured on one estate: twenty-one memory files sat outside all login trees for
exactly that reason, while the same estate's login trees held none. Both facts
were true and they describe different rows. **Check the row before deciding
which case you are in** — an answer that is right for one row is not a general
answer, and treating it as one turns a correct measurement into a wrong
conclusion about somebody else.

### 4b''. FALL C — the target is not empty

Step 4's whole-directory copy assumes the target is a place the session has
never lived. Measured on one estate, that assumption is false in the most
expensive way available:

    transcripts   five uuids exist in BOTH trees; the live one is 163 MB in the
                  SOURCE and 150 MB, two days older, in the TARGET
    memory        38 files in the TARGET, and ZERO in the source

**The transcript is freshest in the source; the memory exists only in the
target.** A whole-directory copy in that direction overwrites thirty-eight live
memory files with nothing — and it is the only step in this operation that
destroys something which exists nowhere else.

The rule was right for the case it was written for and destructive for this one,
which is worse than merely insufficient. So, before step 4:

> **Decide per directory type, against measurement — and copy a file when the
> source is newer OR when the target does not have it at all.**

Measured on the estate in question, the direction is constant *within* each
directory and opposite *between* them: the transcripts wanted source→target
(one file 13 MB newer there, two present only there, four identical), while
memory had thirty-eight files in the target, none in the source, and **zero
filenames in common**. What varies is the directory's kind, not the individual
file — so this needs no file-by-file machine, only a decision per kind.

**"Newer OR missing" and not merely "newer."** Two transcripts existed only in
the source; a plain newer-wins rule drops them silently, because a file that is
absent on one side has no timestamp to lose a comparison with.

**Leave identical files alone.** Copying them anyway is harmless and hides which
files actually moved — and that list is the only receipt of what the step did.

This is not the opencode exception above: nothing here is pinned outside a tree.
It is a *merge*, and the plan knew only about moves.

**A caution earned twice while writing this section.** Both readers who measured
it first got it wrong in opposite directions, from the same data. One of the
errors is worth naming: `stat` on a *directory* returns the size of the
directory's own entry table, so an empty directory and one holding thirty-eight
files differ by exactly that — 64 against 1280 — and it reads like content. The
number was true and answered a question nobody had asked. **Compare directories
by their entries, never by their size.**

**And the onboarding fields can be missing from an old, heavily used target
too.** One `~/.claude` lacked `hasCompletedOnboarding` after two years of use.
Check them because they may be absent, not because the tree looks new.

### 4c. A before-image can only be taken before

Some criteria stop existing the moment the switch happens, and nobody can
reconstruct them afterwards. Take them while the old session still runs:

- does it run **with or without `--resume`**, and if with, **which conversation
  id**? After the switch it must carry one, and it must be that one.
- its pid, its birth, its uptime.
- the transcript file it is actually writing to.

Write them somewhere both the witness and the operator can read — not into a
letter that scrolls away.

---

## What the witness measures

Four things, in this order. The fourth is the one that matters.

1. **A process exists for that row.** Not `pane_current_command` — that reads
   `bash` for a healthy session too, because the launcher runs
   `bash -c '... claude ...; exec bash'` and claude is the pane's child.
2. **The generation carries a real pid and birth.** An empty pid with
   `spawn_state=started` is the silent state: inside the grace window a dead
   session looks like a healthy supervisor for ten minutes, quiet and rc 0.
3. **The process runs on the new `CLAUDE_CONFIG_DIR`** — read it from
   `/proc/<pid>/environ`, not from the row.
4. **The transcript file that already existed keeps growing.** Size and mtime
   against the *before* value from step 4.
   - A **new uuid appearing beside it proves nothing**: the usage meter writes
     one every time it runs — three in ten minutes, measured.
   - A file that is **not growing means idle, not dead**. A session writes only
     while it works — so this check needs a *how*, not just a *when*: **send the
     session a letter and measure after it answers.** "Let it work first" without
     a way to make it work is a delay dressed as a method, and turns into another
     guess.
   - The proof of a fork is the **combination**: it answers the bus **and** the
     file stands still. Either alone means nothing.
   - **The strongest evidence is the pair of files.** After the switch the old
     login's copy is frozen at the second the session died, while the new one
     grows. Two files of the same name, one moving and one still, is not
     compatible with the session writing anywhere else — and unlike every check
     above it cannot be satisfied by accident.

---

## Who may witness whom

A witness must **see** and **speak**. Both, or it is not a witness.

| row | witness | why |
|---|---|---|
| skeppsbron's steward | basement's steward or hub | both have shell there and can report |
| skeppsbron's hub | basement's steward or hub | same |
| basement's steward | basement's hub | same machine, same home |
| basement's hub | the estate owner | it is the last row, and by then nobody else is left to report |
| butler's two | butler's own steward, plus basement reading their snapshot | basement has a read-only key there and no shell |

**A witness that quotes the measured party is not a witness.** It is the same
claim a second time with a different sender, and it is more dangerous than no
witness because it sounds like confirmation.

**And a failed lookup is not an absence.** `ssh <host>` without `-i` failing
answers *"did the keys I happened to offer work?"*, not *"is there a way?"* —
measured the hard way this evening, in both directions.

---

## Order of the six rows

The hand that writes must survive the writing, so each estate's hub goes last
within its own estate, and the estate that coordinates goes last overall.

1. **butler**, both rows, by **butler's own hub** — their register, their
   authority. Blocked until they say which login their rows carry.
2. **skeppsbron's steward** — done 2026-09-14, verified from outside.
3. **skeppsbron's hub**, by itself, witnessed from basement.
4. **basement's steward**, by basement's hub.
5. **basement's hub**, by itself, witnessed by the estate owner.

No estate's hub writes another estate's rows. That is not caution; it is the
same domain-bound rule the register enforces everywhere else, and it holds even
when a relay says go.

---

## What this cost, and what it bought

Four faults were found in preparation, none of which would have been visible
afterwards: transcripts ageing into a silent fork; an after-test that measured a
quantity the usage meter also changes; a before-value that the copy overwrites;
and a fresh login tree that stops in the theme picker.

The pattern under all four, and under the two witness errors as well, was named
by basement's hub after walking into it:

> *"It is a quantity with two causes, and I chose the one I already believed."*
