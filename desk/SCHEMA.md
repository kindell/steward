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

## `entities[]`

An entity is present when the viewer is a member of it, is a member of the team
that manages it, or reads everything.

| key | type | meaning |
|-----|------|---------|
| `id` | string | the row's slug. |
| `name` | string | display name. |
| `managedBy` | string or null | the entity that manages this one. |
| `members` | array of strings | principal ids on the row. |
| `member` | boolean | whether the viewer is one of them (as opposed to reaching the row through the manager, or through `readAll`). |

## `projects[]`

A project is present when the viewer is a member of the entity it hangs under,
or reads everything.

| key | type | meaning |
|-----|------|---------|
| `id` | string | the row's slug. |
| `name` | string | display name. |
| `parent` | string or null | the entity the project hangs under. |

## `sessions[]`

A session is present when the viewer owns it, is a member of its owning entity,
or reads everything.

| key | type | meaning |
|-----|------|---------|
| `id` | string | the session's opaque id. |
| `slug` | string | the short handle a human types. |
| `label` | string | the display name the estate renders. |
| `owner` | string | the account that owns the session. |
| `mine` | boolean | whether `owner` is the viewer. |
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
| `state` | string | `running`, `not-running` or `unknown` - the agent word from `steward sessions --json`. A session that answer did not mention is `unknown`. |
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
- **entity** - visible to a member of the entity named in `source`.
- **project** - visible to a member of the entity the project in `source` hangs
  under.
- anything else - dropped. A new axis has to be granted deliberately in
  `filter.jq`; it is never inherited.

## What is deliberately absent

The raw document the producer builds carries more than any of this, and none of
it is named by the filter, so none of it can appear here: MCP command lines,
arguments and env files (`mcp surface` already refuses to print them),
repository paths, browser rig ports and profiles, and `mcpReason` - the raw
document's note that a session's surface could not be resolved. A viewer whose
session has an unresolved surface sees an empty `mcp` list.
