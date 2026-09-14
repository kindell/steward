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

**The quantity that separates them.** Is the session's transcript growing? A
session writes while it works. Growing means busy, and the alarm is noise;
standing still with mail unread is the real thing.

This is the same pair used as proof during the login switches the same evening —
*the new tree grows while the old one stands frozen* — turned around. There it
said a session had survived its restart; here it says an alarm is not needed.

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

**Shape when it is built.** Growing → silent, or a weaker line that says *busy
for N minutes* rather than an alarm. Standing still → alarm exactly as today.
Never the reverse default: a guard that cannot read the transcript must fall
back to alarming, because absence of a measurement is not evidence of health.

**One more thing to fix while in there.** The alarm text says *"I get pinged but
do not read"*. A session cannot observe that about itself — it does not know it
was pinged; it knows mail is still queued. It is the same shape as *"I
switched"*: a claim about oneself that only someone else can test. The line
should say what was measured, which is that mail is unacknowledged.
