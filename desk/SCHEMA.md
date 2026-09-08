# The desk snapshot file

`steward desk snapshot` writes one JSON file per principal, plus `_operator.json`,
into a fresh generation directory and then points `current` at it:

    <STEWARD_DESK_DIR>/gen-<epoch>[-NN]/<principal>.json
    <STEWARD_DESK_DIR>/gen-<epoch>[-NN]/_operator.json
    <STEWARD_DESK_DIR>/current -> gen-<epoch>[-NN]

`STEWARD_DESK_DIR` defaults to the `dir=` line printed by `desk/bin/desk-paths`
(`$HOME/.local/state/<STATE_DIR_NAME>/desk`). The two newest generations are
kept; older ones are removed at the end of a run.

**`desk/filter.jq` is the source of truth for this document, not this file.**
The filter is a positive allowlist: a key it does not name does not exist in the
output, whatever the raw snapshot carried. What follows is that allowlist read
back in prose, and if the two ever disagree the filter is right.

## Top level

| key | type | meaning |
|-----|------|---------|
| `schemaVersion` | number | `1`. Bumped when a key changes meaning or leaves. |
| `host` | string | the machine that produced the snapshot. |
| `generatedAt` | string | UTC, `YYYY-MM-DDTHH:MM:SSZ`, when the run started. |
| `registryRevision` | string | short git revision of the estate checkout, or `"unknown"`. |
| `viewer` | string | the principal id this file belongs to; `"_operator"` for the operator file. |
| `readAll` | boolean | true when this viewer's row carries `DESK_READ_ALL`. |
| `entities` | array | see below. |
| `projects` | array | see below. |
| `sessions` | array | see below. |

## One visibility rule

Everywhere an entity decides what a viewer sees, the question is the same one:
**an entity is visible when the viewer is a member of it, or a member of the
entity that manages it** - one hop, no chain. What hangs under a visible entity
follows it: its projects, the sessions working in it, and the grants those two
levels made. `readAll` short-circuits all of it, and an unknown axis is still
dropped.

## `entities[]`

An entity is present when it is visible to the viewer, or the viewer reads
everything.

| key | type | meaning |
|-----|------|---------|
| `id` | string | the row's slug. |
| `name` | string | display name. |
| `managedBy` | string or null | the entity that manages this one. |
| `members` | array of strings | principal ids on the row. |
| `member` | boolean | whether the viewer is one of them (as opposed to reaching the row through the manager, or through `readAll`). |

## `projects[]`

A project is present when the entity it hangs under is visible, when the viewer
owns a session whose target is this project, or when the viewer reads
everything. The own-session clause is what keeps a session page's `project` link
from being a 404 for the person sitting in that session.

| key | type | meaning |
|-----|------|---------|
| `id` | string | the row's slug. |
| `name` | string | display name. |
| `parent` | string or null | the entity the project hangs under. |

## `sessions[]`

A session is present when `lib/visibility.sh`'s `session_visible_to` says so for
this viewer, or when the viewer reads everything - that function is the
product's one rule for who may see a session, and this document only projects
the fields of the sessions it already returned yes for.

| key | type | meaning |
|-----|------|---------|
| `id` | string | the session's opaque id. |
| `slug` | string | the short handle a human types. |
| `label` | string | the display name the estate renders. |
| `owner` | string | the principal id of the person the session belongs to (the account register's `PRINCIPAL`, `OWNER` only when the row carries no resolvable `ACCOUNT`). Never the unix account: `mine` and every axis rule compare it with the viewer, who is a principal. |
| `mine` | boolean | whether `owner` equals the viewer. |
| `domain` | string or null | the owning entity. |
| `project` | string or null | the target project. |
| `runtime` | string | `claude-code`, `opencode`, `codex`. |
| `host` | string | the machine the session lives on. |
| `repo` | string | the repository's **name** - never its path. |
| `liveness` | object | `state`, `measuredAt`, `ageSeconds` (below). |
| `mcp` | array | the granted assets the viewer may see (below). |

### `sessions[].liveness`

| key | type | meaning |
|-----|------|---------|
| `state` | string | `running`, `not-running` or `unknown` - the agent word from the estate's liveness seam (`liveness_rows`, one call per run, keyed by session name). A session the seam did not measure is `unknown`, and so is every session when no seam is configured. |
| `measuredAt` | string | the run's `generatedAt`. |
| `ageSeconds` | number or null | seconds since the session's last activity, or null when there was no timestamp or it did not parse. |

### `sessions[].mcp[]`

| key | type | meaning |
|-----|------|---------|
| `id` | string | the asset's slug. |
| `name` | string | its display name. |
| `axis` | string | `account`, `entity` or `project` - which level granted it. |
| `source` | string | the row on that level that did the granting. |

The axis decides who sees the asset at all:

- **account** - the person's own credential. Only the session's owner, or a
  `readAll` viewer, ever sees it.
- **entity** - travels when the entity named in `source` is visible, or to the
  session's owner (a principal).
- **project** - travels when the entity the project in `source` hangs under is
  visible, or to the session's owner (a principal).
- anything else - dropped. A new axis has to be granted deliberately in
  `filter.jq`; it is never inherited.

## Operating the desk on a session host

The deploy writes the files and the unit files, and daemon-reloads. It never
enables and never starts anything - that verb is refused by design
(`test/deploy-policy.test.sh`). The deploy writes the units and the desk files
into every home on the host; only the hub account enables the units, and the
other homes carry the files unused. So after the first rollout that carries the
desk, the hub account turns it on once, by hand:

    loginctl enable-linger <the hub account>     # once per account, if not already
    systemctl --user daemon-reload
    systemctl --user enable --now steward-desk.service steward-desk-snapshot.timer

`enable-linger` is what lets the units run with nobody logged in; without it
the desk stops the moment the last session ends. Later deploys need none of
this repeated - they overwrite the unit files and reload, and systemd keeps
what was enabled.

The first enabled round is also what brings `<STEWARD_DESK_DIR>` into being,
and that directory is how a host says it has a desk: `linux/deploy-self.sh`
takes a snapshot after an apply only when it is already there, and prints
`no desk on this host ... snapshot skipped` otherwise. So the sequence above
is the switch, and every deploy after it refreshes what the switch turned on.

### Reaching it from the tailnet

**The desk mounts at ROOT, and the serve tool must be given no path prefix.**
Its routes and every link it writes are absolute `/desk/...`, so the prefix is
inside the application already; adding a second one outside it is what breaks
the desk. Measured 2026-09-08: `--set-path /desk` strips the prefix before
proxying, the socket then receives `/`, `/team/...`, `/session/...`, and every
route answers 404.

Aim the serve tool at the socket - the `sock=` line `desk/bin/desk-paths`
prints - with no path prefix. The invocation has the shape:

    tailscale serve --bg --https=443 unix:<the sock= path>

`--set-path` is the flag to leave out. Everything else about the exposure is
the operator's business; the desk only requires that what arrives at the socket
is the path the reader typed.

**How quickly a change reaches a desk.** Different answers for different
changes, and confusing them is the trap:

- **A withdrawal has two latencies, and which one you get depends on where the
  withdrawal was made.** Every file was filtered when it was written, so a
  person keeps seeing what the last generation gave them until a new one
  exists.
  - Withdrawn by a deploy that lands on the desk's own host: **seconds.**
    `linux/deploy-self.sh` runs `steward desk snapshot` itself after an apply
    that succeeded, and a failed snapshot makes the deploy exit 70 - the
    rollout happened, the view of it did not.
  - Withdrawn in the estate registry and pulled into the checkout some other
    way - a `git pull` on the desk host, an edit made straight in the estate,
    a deploy that ran on a different host: **up to five minutes.** Nothing
    told the desk, so the next timer round is what notices.
- **Liveness is the timer's - up to five minutes.** That is what
  `steward-desk-snapshot.timer` is for. It is the floor under a withdrawal, not
  the path a withdrawal is meant to take: a rollout that knows a withdrawal
  happened says so in seconds, and reading the timer as the revocation path is
  what would make five minutes look like the design rather than the fallback.

The server needs no restart when a generation changes; it reads
`<STEWARD_DESK_DIR>/current` per request. Restart it only when `serve.mjs`,
`render.mjs` or the unit itself changed.

## What is deliberately absent

The raw document the producer builds carries more than any of this, and none of
it is named by the filter, so none of it can appear here: MCP command lines,
arguments and env files (`mcp surface` already refuses to print them),
repository paths, browser rig ports and profiles, and `mcpReason` - the raw
document's note that a session's surface could not be resolved. A viewer whose
session has an unresolved surface sees an empty `mcp` list.
