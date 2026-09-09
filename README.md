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
  recipient's own queue rather than typed into a terminal. Two estates can be
  linked, one owned link at a time, so that one person's sessions reach each
  other across machines and nobody else's do:
  [docs/hub-peer-link.md](docs/hub-peer-link.md).
- **Selectable runtimes** — a session declares which agent runtime it runs on.
  The default is Claude Code, and a conf that says nothing about runtime keeps
  behaving exactly as before: every conf written before runtimes existed is a
  Claude conf, and rendering it as anything else would make a healthy estate
  look unmeasured. The second runtime is OpenCode; the contract for adding
  another is in [docs/opencode-runtime.md](docs/opencode-runtime.md).
- **Desk** — a read-only estate view, and a public front (OpenID Connect
  login, the box is only a proxy) - desk/SCHEMA.md, "Reaching it from the
  public front".

## Register modes on an estate that already exists

The scaffold pins the mode of every register directory it creates - `invites.d`
and `logins.d` at `0700`, the rest at `0755` - instead of leaving it to the
host's umask. On a Debian or Ubuntu host, whose default umask is 002, the
registers used to come out group-writable, and the invite and login loaders
refuse a group- or other-writable register on purpose: a row at mode 600 inside
a directory anybody can write to is not protected by its mode.

**The modes are applied only when the scaffold creates the directory.** An
estate scaffolded before this change keeps exactly the modes it had, and
nothing repairs it - not a re-scaffold, not an upgrade. The two guarded
registers will refuse and name the remedy the first time something reads them;
the others stay group-writable silently. Check and repair such an estate by
hand, once:

```sh
ESTATE=/path/to/estate
ls -ld "$ESTATE"/*.d                                # what the modes are now
chmod g-w,o-w "$ESTATE"/*.d                         # no register stays writable by others
chmod 0700 "$ESTATE"/invites.d "$ESTATE"/logins.d   # the two the loaders guard
```

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
