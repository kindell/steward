# steward

steward keeps coding-agent sessions alive on hardware you own.

An agent session in a terminal ends when the terminal does. steward makes it a
supervised, named service instead: it survives reboots, comes back on its own,
and can be reached by name from anywhere in your fleet.

## What it is

A control plane, not an agent. steward does not replace the agent runtime you
already use — it starts it, watches it, addresses it, and updates it.

- **Registry** — sessions and hosts as declared configuration. One file per
  session; the registry is the single source of truth about who exists and
  where they live.
- **Supervision** — `systemd --user` on Linux, launchd on macOS. One timer per
  session, in the owning user's own instance. Nobody supervises anyone else's
  sessions.
- **Deploy path** — a manifest, a provenance gate, and a drift gate. A host
  rolls out to itself from its own checkout; the hub is not required to be
  reachable for a machine to update.
- **Bus** — durable, acknowledged messages between sessions, delivered to the
  recipient's own queue rather than typed into a terminal.

## Design rules

These are load-bearing, not preferences. Each exists because its absence caused
a real incident.

**Refuse rather than guess.** Every gate fails closed. A tool that cannot tell
whether it is safe to act does not act.

**Measure the effect, not the step.** A deploy that reports success proves that
files were written — not that the machine can run anything. Acceptance is
stated as a command that exits 0, never as a judgement.

**A skipped check must never look like a passed one.** Absence of observation
is not absence of problem. Counts are printed, and what was skipped is named.

**One person, one account, one login.** Credentials belong to a human and stay
on the machine that human authenticated. steward never reads, copies, stores or
forwards them.

## Status

Early. The registry, supervision and deploy path are in production use; the
public surface is being extracted from a private estate one file at a time,
with tests, and is not yet complete.

## License

MIT — see [LICENSE](LICENSE).
