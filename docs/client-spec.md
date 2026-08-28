# The steward client — spec

*Status: specification, 2026-08-21. Nothing below is built unless a command
says so explicitly.*

A person who operates one or more estates does so from their own machine.
This document specifies the laptop-side client: one binary-shaped script,
`steward`, that installs estates, reads their state, and administers their
people — without ever becoming a channel between the estates themselves.

## The one rule everything else follows from

**Estates do not know about each other. Only the operator's own machine
does.** The client keeps a local list of estates; that list is personal
configuration, never synced anywhere, never visible to any estate. Two
estates operated by the same person share exactly two things: that person's
agent-account login and that person's SSH identity. Everything else —
registries, buses, supervision, credentials on disk — is measurably
separate, and the client must never quietly bridge them.

### The account layer is honestly wider than ours

Measured 2026-08-21: sessions logged in under the SAME agent account can
discover and message each other through the vendor's own remote-control
layer, across estates, regardless of anything this product does. That
channel belongs to the account, not to the estate machinery; it is only
visible within one person's account, but it bypasses the bus and every
guard on it. The client cannot close it and must not pretend otherwise —
the boundary it CAN enforce is the estate layer, and the documentation says
exactly that. If the vendor grows a way to scope discovery, adopt it;
until then this is a documented property, not a defect ticket that will
close itself.

## The estate list

```
~/.config/steward/estates.d/<estate>.conf
```

One file per estate, shell-sourceable, same format discipline as the
estate's own `steward.conf`:

```
SSH="user@host"            # how THIS operator reaches the estate
ESTATE_ROOT="~/estate"     # STEWARD_ESTATE_ROOT on that machine
PRODUCT_DIR="~/steward"    # the product checkout or deploy root there
```

The file name is the operator's own word for the estate. Two operators of
the same estate each have their own file, their own SSH identity, and
possibly different words for it.

## Commands

### `steward init <ssh-host>`

Runs the bootstrap (the same `install.sh` the one-liner runs) over ssh on a
prepared host, then writes the local estate file. Stops where it always
stops: the agent login inside the hub session is the person's own
interactive act, stated in the closing text, never automated. `init` on a
host that already has an estate refuses; adopting an existing estate is
`steward add`, which only writes the local file after reading the remote
conf back.

### `steward ls [<estate>]`

Sessions per estate, over plain ssh: the registry's confs joined with
`tmux ls` and the supervision timers. No daemon, no agent involvement.
With no argument: every estate in the list, one block each, failures
reported per estate rather than aborting the sweep — one unreachable
machine must not blind the operator to the others.

### `steward sessions [--json]`

Every session's IDENTITY joined with its LIVENESS, in one local read plus one
subprocess call. Identity comes from the registry and is free. Liveness comes
from a command the estate supplies. REACH — whether a session's declared assets
actually answer — is deliberately NOT here: it costs a remote round trip per
session and is `steward assets`' job, asked for separately and asynchronously.

The declared consumer is a view reading `--json` from a subprocess, so the
contract below is part of the product, not an implementation detail.

#### The liveness seam

The product does not measure liveness itself and cannot: it means reading a
launch manager, a multiplexer socket and a log file, all named by one estate's
conventions on one estate's operating system.

```
STEWARD_LIVENESS_CMD=<absolute path to the estate's shim>
```

**It must be a PATH, not a command name** — a bare name is refused rather than
resolved through `PATH`, because what this seam runs reads a socket carrying
live conversations. With the variable unset, every session reports `unknown`
with the reason `seam-not-configured`; that is a normal state for an estate that
has not wired a shim yet, and it is the ONLY seam condition that is not also
announced on stderr.

The shim takes no arguments and answers for the whole fleet in one call — the
asset layer already pays a remote round trip per session and liveness must not
inherit that cost. It writes one JSON document on stdout:

```json
{
  "sessions": { "<name>": { "daemon": "loaded", "tmux": "up", "agent": "running",
                            "runtime": "<name>", "model": "<name>|null",
                            "lastActivity": "<timestamp>|null" } },
  "omitted":  { "<name>": "<why this session could not be measured>" }
}
```

A session the shim could not measure is **omitted from `sessions`, never
guessed** — a guess would look exactly like a measurement, which is the one
failure this whole model exists to prevent. `omitted` is optional and carries
the shim's own reason for that omission; every status field of an omitted
session is forced to `unknown` on the way in, because the estate is supplying a
REASON there, not a measurement.

Inside `sessions`, a missing key and an explicit `null` are different facts and
stay different: `null` means the shim looked and found no value, an absent key
means it never looked.

#### The JSON document

```json
{
  "ok": true,
  "unreadable": ["<session name>"],
  "sessions": [
    {
      "name": "<name>", "id": "<name>", "owner": "<name>",
      "domain": "<name>", "host": "<name>",
      "entity": { "name": "<display name>", "relation": "team" },
      "assets": ["<declared asset>"],
      "liveness": {
        "daemon": "loaded", "tmux": "up", "agent": "running",
        "runtime": "<name>", "model": "<name>", "lastActivity": "<timestamp>",
        "reason": null
      }
    }
  ]
}
```

**Closed vocabularies.** A word outside its set is rewritten to `unknown` before
it reaches this document — a command that answers something else is a broken
command, and a broken command must never be able to invent a word a view would
render as healthy.

| field | set |
|---|---|
| `liveness.daemon` | `loaded` · `missing` · `unknown` |
| `liveness.tmux` | `up` · `down` · `unknown` |
| `liveness.agent` | `running` · `not-running` · `unknown` |
| `entity.relation` | `team` · `client` · `-` (an entity that declares neither members nor a manager) |

`liveness.runtime` is deliberately NOT a closed set: a runtime is a NAME, not a
state, and a third one appears the day one is added. Rewriting an unrecognised
name to `unknown` would report "we could not measure the runtime" about a
runtime that was measured perfectly well.

**Nulls, and what each one claims.**

| field | `null` means |
|---|---|
| `entity` | no entity file describes this session's domain, or the one that does would not load |
| `liveness.model` | measured, and there is no value |
| `liveness.lastActivity` | measured, and there is no value |
| `liveness.reason` | the session WAS measured; there is nothing to explain |

`assets` is **always a list** — empty means the session declares none. A
consumer that had to handle both a string and a list gets it wrong once.

**`reason` is a detail field, not a fifth status word.** A view renders the
status words; `reason` is what it shows beside an `unknown` so that the reader
is not left with six causes collapsed into one word. The values the product
itself produces:

| value | what happened |
|---|---|
| `seam-not-configured` | `STEWARD_LIVENESS_CMD` is unset |
| `seam-not-a-path` | it is set to a bare command name |
| `seam-not-found` | it names a path that does not exist |
| `seam-not-executable` | it names a file without its exec bit |
| `seam-failed` | the shim ran and exited non-zero |
| `seam-no-output` | the shim succeeded and said nothing |
| `seam-unparseable` | the shim's output is not valid JSON |
| `seam-no-sessions-object` | valid JSON, no `sessions` object |
| `not-in-answer` | the shim ran and did not mention this session |

Anything else is a sentence the estate's shim supplied in its `omitted` map.

**`unreadable` is always present, and empty means nothing failed.** It names
every session that is in the registry and could not be loaded. Those sessions
are absent from `sessions` — a half-read row would be worse than none — and
`ok` stays `true`, because `ok` answers "was the registry readable", not "is
every row here". A consumer that ignores `unreadable` reads a shorter list as a
complete one, which is the failure this command was built against.

**Refusals stay in the requested format.** When the registry cannot be read at
all, `--json` answers `{"ok": false, "reason": "<the refusal text>"}` on stdout
with a non-zero exit code. A consumer that asked for JSON and got a bare
sentence reports a broken tool instead of an unreadable registry.

**Diagnosis is on stderr, always, in addition.** Everything above is
belt-and-braces: the per-session causes are also written to stderr as sentences
for a human at a terminal. Neither channel is the only one.

### `steward <estate> attach <session>`

`ssh -t` into the host and `tmux attach`. The client never types INTO a
pane (keystroke injection loses content — the estates' own rule) — attach
hands the terminal to the human and gets out of the way.

### `steward <estate> users`

The registry distilled per OWNER, measured against the host in the same
sweep:

```
<owner>   3 sessions   account: present   linger: on   timers: 3/3   relay keys: 3
```

Both sources are read so the DIFFERENCES surface: a conf whose owner
account is missing, an account with timers the registry does not know —
orphans in either direction are the finding, not decoration.

### `steward <estate> adduser <name>`

The recipe that exists as documentation becomes a command: create the OS
account, install per-user supervision under it, prepare the bus key path.
Stops at the same line `init` stops at: the new person logs in to their own
agent account themselves, in their own session. One person, one OS account,
one login — the client enforces the shape and never touches the credential.

### `steward <estate> rmuser <name>` — and the retirement form

Retirement is the form this fleet has never built, and its absence is now a
four-time finding: hosts can be welcomed but not retired, deploys can
install paths but not withdraw them, users can be added but not removed,
and a session cannot leave one estate for another without it. So the form
gets specified once, here, and every retiring verb uses it:

1. **Show first.** A dry pass prints exactly what will be disabled,
   archived or revoked — timers, key lines, confs — before anything runs.
2. **Archive, never delete.** Confs move to an `archive/` sibling with a
   timestamp; key lines are removed from `authorized_keys` (the backup
   convention already exists); timers are disabled, not uninstalled.
3. **The irreplaceable is named out loud.** Conversation history and
   working copies belong to the person; the command states where they
   remain and touches neither.
4. **A receipt.** What was done, where the archive is, how to reverse it.

### `steward move <session> --to <estate>`

Two cases, deliberately asymmetric in cost:

**Same machine** (the common case once several estates share a host): the
move is a RE-REGISTRATION. History and memory are keyed to the working
copy's path and do not travel; the working copy stays put; the login is
the same person's. What changes hands: the conf (from one registry to the
other), the relay key (reissued — identity is bound per estate), and the
RC label (rewritten — which requires one planned restart of the session,
the move's only real cost). Precondition: supervision must bind the estate
per SESSION, not per account — the per-instance drop-in work. Until that
lands, two estates on one account cannot coexist and `move` refuses with
that exact reason.

**Cross-machine**: the same re-registration on top of a host move — here
history and working copy DO travel, and the export/import deserves its own
care and its own receipt. Built second, on top of the first.

Both directions end with the retirement form running in the source estate.
A move that only welcomes is half a move.

### `steward update <estate>`

`git pull` of the product on the host, followed by the host's own rollout
path. Never touches estate values.

## Security posture

The client's transport is SSH, full stop — the same boundary the bus and
enrolment already ride. Recommendations the client FACILITATES but never
enforces:

- **Private overlay networks** (mesh VPN of the operator's choice): `init`
  detects one if present and prefers its addresses; the docs carry a recipe
  for closing public SSH once the overlay is verified. A team with its own
  network arrangement keeps it — mechanism, not policy.
- The client never stores or forwards agent credentials, tokens or estate
  secrets. Its estate list contains addresses and paths only.

## Distribution

The same channel as the server side: the repository, and `install.sh`
grows a `--client` mode that links `steward` into `~/.local/bin`. A
package-manager tap is the day someone who is not already running an
estate asks for one — not before.

## Relationship to existing estates

Nothing here is new-installations-only. An existing estate converges by
the same migration discipline as every source before it: deployed
artifacts stay byte-identical until their own migration step, values move
without changing, and the estate's own word for itself keeps working as
the operator's name for it in the estate list.

## Build order

1. **Per-session estate binding** (the drop-in per instance) — blocks
   `move` and multi-estate hosts, and is independently wanted.
2. **`ls` + `users`** — cheap reads, immediate value, no state.
3. **`init` / `add`** — wraps what already works by hand.
4. **`adduser`** — the documented recipe as a command.
5. **The retirement form + `rmuser`** — specified above, built once.
6. **`move`, same-machine** — re-registration on top of 1 and 5.
7. **`move`, cross-machine** — last, on top of everything.
