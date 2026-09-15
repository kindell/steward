# The watch, and the alarms nobody can act on — reviewed backlog

One item so far. It was proposed by a fleet session that had just been alarmed
about, measured itself first, and then argued that the alarm should not have
fired — which is the right order and the reason the item is written down.

---

## 1. "Unacknowledged mail" cannot tell a session that is STUCK from one that is WORKING

**The alarm today.** `watch/session-watch.mjs` alarms when mail has sat
unacknowledged in a row's inbox past a threshold. It counts minutes and nothing
else.

**Why that is not enough.** A session deep in a long piece of work and a session
that has hung look identical from outside if the only quantity is elapsed time.
Both have unread mail; both have been quiet. The alarm fires on both, so the
half of them that are working teach the reader to ignore it — and an alarm that
trains its audience to dismiss it is worse than no alarm, because it costs the
same attention and returns nothing.

Measured twice in one evening on the same row. The first firing was real: a
request for a **witness** to a login switch sat unread for 18 minutes and
expired while it lay there. The second was noise: the row was writing
continuously and the mail was two status letters with nothing time-critical in
them. **Same alarm, same threshold, same row — and the difference was not in
anything the guard measured.**

**The quantity that separates them — and it is a timestamp, not a growth
measurement.** The obvious form is *is the transcript growing?* It is the same
pair used as proof during the login switches the same evening — *the new tree
grows while the old one stands frozen* — turned around: there it said a session
had survived its restart, here it says an alarm is not needed.

**But growth needs a window, and the window is a second parameter that is easy
to forget to give.** Measured on a live alarm: the file was unchanged across a
25-second sample, which by the growth rule reads as *stuck* — while its mtime was
two minutes old and its last lines were a user turn at 04:45:53 and an assistant
turn at 04:45:57. The session was awake and had worked *after* the mail arrived.
Twenty-five seconds does not separate *thinking* from *hung*; a window shorter
than the longest normal silence answers a different question than the one asked,
and swaps one bad indicator for another.

**So use the age of the last USER or ASSISTANT line instead.** It is strictly
better on every axis that matters here:

- it is an **instantaneous** value — no window, no waiting, no second parameter
  to get wrong;
- it distinguishes *wrote bookkeeping* from *held a conversation*, because a
  `.jsonl` ends in state records written during shutdown — the same split that
  verified the estate switches the same night;
- and it degrades honestly: an old timestamp with unread mail is exactly the
  condition the alarm is for.

The growth form is not wrong, it is under-specified. Written down this way so
that nobody implements the version that needs a window without being told the
window is the hard part.

**What it would take, and why this is not a one-line change.** The guard does
not know where a row's transcript is. It measures processes, panes and the bus
queues, and has no notion of a login tree or a project directory. Reaching the
file means the chain

    row -> LOGIN -> CONFIG_DIR -> projects/<repo path> -> the row's .jsonl

and that chain lives in the bash registry while the guard is Node. It is a new
lookup across a language boundary, not a condition to add. The proposal was
first offered as "just a condition" by someone who had not opened the guard —
and naming that is part of the item, because the same misjudgement in the other
direction is how a finding gets oversold.

**A note on how both of the above were found.** Each was proposed by the same
session and then withdrawn by it after measurement — three times in one day, and
the shape was identical every time: *a measurement was proposed without saying
what it should be compared AGAINST.* The growth rule without a window is that
shape exactly. It is worth naming here because the repair is cheap and the error
is not visible from inside the proposal: a quantity always sounds sufficient
until someone asks for its reference.

**Shape when it is built.** Growing → silent, or a weaker line that says *busy
for N minutes* rather than an alarm. Standing still → alarm exactly as today.
Never the reverse default: a guard that cannot read the transcript must fall
back to alarming, because absence of a measurement is not evidence of health.

## 2. The alarm speaks in the row's voice, and the supervisor is the one speaking

Raised by the same session, measured in the supervisor rather than proposed from
memory, and confirmed here before being written down.

The text is built in `linux/session-supervisor-linux.sh` around line 2105:

    UNACK_MSG="DRIFT okvitterad-post: $NAME has $(( AGE/60 )) min of unacked mail
    AUTO-ALERT: unacked mail in my inbox for ... I get pinged but do not read ..."

**The first line is already right.** It names the row in the third person and
states what was measured. It is only the second line that borrows first person -
and the supervisor, not the row, is what writes both.

That costs two things, and the second is the serious one:

- it asserts something about the row's **experience** ("I get pinged") that
  neither the row nor the supervisor has measured. What the supervisor knows is
  that mail is still queued.
- if the row is **hung**, the alarm is still phrased in her voice - so the worst
  outcome reads exactly like the ordinary one. That is the equivalence the
  witness discipline exists to break, reappearing in the one line a person
  actually reads.

It is the same shape as *"I switched"*: a claim about oneself that only somebody
else can test.

**But the text was not careless - it was outgrown.** The comment at line 2030
records why it was written: a session measured **35 identical pings for one
message** on 2026-08-17 and could not read, because the wake-up looped. The line
says *"an alarm saying 'I get pinged but do not read' is true while the cause
lies in the PING"* - and for that case it was true and first person was honest.
Item 1 above is a later widening of the same alarm onto a case nobody rewrote it
for. **The defect is the unreviewed extension, not the original sentence.**

**Two constraints on the repair, both documented in place.** Consumers grep for
the occurrence of `AUTO-ALERT`, not its line position, so the token stays; and
the subject slug `okvitterad-post` is a live thread key on the hub, so renaming
it would sever the thread. The second line should simply take the first line's
voice: what was measured, and who measured it.

---

## 3. A send that never left the machine is invisible to everything we have

The guard watches `inbox/` and `malformed/`. It does not watch `failed/`, and
neither does the supervisor. Verified by counting, in the product tree:

```
linux/session-supervisor-linux.sh    0 hits for failed/
watch/session-watch.mjs              0
watch/lib.mjs                        0
```

What they *do* reference: `inbox/`, `malformed/`, `done/`. A refused send lands
in `failed/` with its reason, its rc and a timestamp — and nothing ever looks.

**Measured live while writing this item:** the author's own `failed/` held **ten
entries, the oldest 149 hours old**. Most were benign — deliberate address
probes, and refusals of a class that does not cross an estate link. That is not
the point. The point is that **nothing would have said so**; they were found
because somebody asked.

**The expensive version is already on record.** A session went quiet for eight
days. Its reports were being written. Its sends were failing on `publickey`, its
letters were piling into its own `failed/` — and the escalation that should have
raised it went down the same closed path. Every part of the machinery was
working, and the only observer that could have noticed was the one directory
nobody reads.

**Why this belongs beside item 1.** That item is about an alarm that fires when
it should not. This is an alarm that cannot fire at all. They share a file and a
sweep, and a fix that touches one should carry the other: the same loop that asks
*how old is the oldest unread letter* can ask *how old is the oldest unsent one*,
and the second question has no false-positive problem at all — an entry in
`failed/` is never ambiguous. Something tried to leave and did not.

**One caution on the coverage figure.** Measuring the central watch shows it
inspects only a few rows of many, because `inspectable` requires the row's owner
to match the account the watch runs as. Read alone that looks like a hole. It is
not: each account's own supervisor runs the same signalling on its own rows. The
coverage exists; it lives somewhere else. *A true number answering a different
question* — and the reason to state it here is that the next person to measure it
will reach for the same wrong conclusion.
