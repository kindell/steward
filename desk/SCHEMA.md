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

**Decided 2026-09-08: read-all wins over `private`.** A `readAll` viewer is the
operator's own eye on the estate, and it short-circuits a `private` row the
same way it short-circuits everything else - a row nobody but its owner and a
grantee should see is still shown to a viewer whose row carries
`DESK_READ_ALL`. This was weighed, not overlooked: a future reader finding a
`private` row inside a read-all response should read it as the decided shape,
not a leak to fix. For every other viewer, whether a row marked `private` is
visible is `lib/visibility.sh`'s `session_visible_to` and nothing else - the
one rule this document already names above.

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

**The desk must never be reached from its own node.** Measured on a
two-account host: a request the desk's own host sends toward its own socket
carries the node owner's login header, because the tailnet client
identifies the node rather than the local account that made the
request - so any local account on that host could otherwise read the node
owner's view. The desk refuses this: a request where ANY comma-separated
entry of the forwarded-address header is the host's own is answered with
403, whatever login header it carries. Every entry is checked, not only the
first, because this server is the terminus of the chain, never a hop: the
proxy in front of it appends a client-supplied forwarded-address entry to
the one it inserts for the inbound node, rather than replacing it, so the
host's own address can land anywhere in the list - and because this server
never forwards the request on, checking every entry never refuses a real
remote caller. The host's own uid-gated egress rule is the first line of
defense against this and the server's refusal is the second, so a host
without that rule is not left open. This check matters on the socket mode
above, where only the serve tool can reach the server at all; it adds
nothing on top of `serve.mjs`'s loopback-listen mode
(`STEWARD_DESK_LISTEN`), which already accepts, as its own documented cost,
that any local process there can set the same headers itself. The set of
addresses that count as the host's own is read once, at startup: a desk
started before its tailnet interface has an address never learns that
address later, so restart the desk after the address is up, or name it in
`STEWARD_DESK_SELF_ADDRS` ahead of time.

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

### Reaching it from the public front

A second door for people who are not on the tailnet: a public proxy box
terminates TLS for the estate's hostname and forwards to a second listener
on this host's tailnet address. The box holds no secret; the OpenID Connect
login runs here. Design: `docs/superpowers/specs/2026-09-08-desk-front-design.md`.

The estate provides, in this order:

1. `DESK_ORIGIN="https://<public hostname>"` and
   `DESK_SESSION_KEY_FILE="<absolute path>"` in `estate/steward.conf`. The key
   file is generated once, 0600, owned by the desk account, at least 32
   bytes: `umask 077; head -c 32 /dev/urandom | base64 > <path>`.
2. `desk/providers.d/<slug>.conf` beside the registry, one per provider:
   `ISSUER` (or `ISSUER_TEMPLATE` with a literal `<tid>` for a multi-tenant
   provider that discovers through a common endpoint), `DISCOVERY`,
   `CLIENT_ID`, `CLIENT_SECRET_FILE` (0600, the desk account's). The
   provider's redirect URI is `<DESK_ORIGIN>/desk/auth/callback`.
3. A drop-in `~/.config/systemd/user/steward-desk.service.d/50-estate.conf`:

       [Service]
       Environment=STEWARD_DESK_FRONT_LISTEN=<this host's tailnet addr>:<port>
       Environment=STEWARD_DESK_FRONT_PEER=<the box's tailnet addr>

   The bind must be a tailnet (100.64.0.0/10) or loopback address; the desk
   exits 64 on anything else. The peer is the only address whose requests
   are answered; every other peer gets a plain-text 403 before identity is
   read.
4. The tailnet ACL lets only the box's tag reach this host on that port.
5. The box: a reverse proxy with automatic certificates, forwarding to
   `<tailnet addr>:<port>` with the visitor's address as `X-Real-IP`.

What a visitor sees: `/desk/auth/login` lists the providers; after the
provider's login the desk verifies the `id_token` (signature against the
provider's JWKS, issuer, audience, expiry, nonce), maps
`oidc:<slug>:<subject>` to a principal row through `desk/bin/principal-for-login`
and sets `__Host-desk-session` for 12 hours. Every request re-checks that the
principal row still exists (`desk/bin/principal-exists`), so removing a row
logs the person out on their next click. `POST /desk/auth/logout` clears the
cookie. `/desk/auth/*` is rate limited to 10 requests per minute per visitor.

The front never reads the `tailscale-user-login` header; the tailnet socket
never reads a cookie.

## What is deliberately absent

The raw document the producer builds carries more than any of this, and none of
it is named by the filter, so none of it can appear here: MCP command lines,
arguments and env files (`mcp surface` already refuses to print them),
repository paths, browser rig ports and profiles, and `mcpReason` - the raw
document's note that a session's surface could not be resolved. A viewer whose
session has an unresolved surface sees an empty `mcp` list.
