# The desk snapshot file

`steward desk snapshot` writes one JSON file per principal, plus `_operator.json`,
into a fresh generation directory and then points `current` at it:

    <STEWARD_DESK_DIR>/gen-<epoch>[-NN]/<principal>.json
    <STEWARD_DESK_DIR>/gen-<epoch>[-NN]/_operator.json
    <STEWARD_DESK_DIR>/current -> gen-<epoch>[-NN]

`STEWARD_DESK_DIR` defaults to the `dir=` line printed by `desk/bin/desk-paths`
(`$HOME/.local/state/<STATE_DIR_NAME>/desk`). The two newest generations are
kept; older ones are removed at the end of a run.

**The rule and the field table live in `lib/visibility.sh`; `desk/filter.jq`
only projects them.** `session_visible_to` decides who may see a session and
`visibility_field_list` enumerates what each of the two sights receives, both
in shell, once, for every renderer the product has. The filter is still a
positive projection - a key neither list names does not exist in the output,
whatever the raw snapshot carried - but it no longer holds a rule of its own.
What follows is those two functions read back in prose, and if the prose and
the code ever disagree the code is right.

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

Everywhere an **entity** decides what a viewer sees, the question is the same
one: **an entity is visible when the viewer is a member of it, or a member of
the entity that manages it** - one hop, no chain. Its projects follow it.

**A SESSION is not decided that way.** Whether a session travels is
`lib/visibility.sh`'s `session_visible_to` and nothing else - owner, group
grant, `private`, the entity hop and the one `MANAGED_BY` hop, all of it in one
function - and the snapshot asks it once per principal per session and carries
the answer here as `sight`. A renderer that re-derived any part of it in `jq`
would be a second copy of the rule, which is how the desk once let a `private`
row reach a viewer the one rule had already said no to. `readAll`
short-circuits both questions, and an unknown MCP axis is still dropped.

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

A project is present when the entity it hangs under is visible, when the
VIEWER'S OWN session works on it, or when the viewer reads everything. The
session clause is what keeps a `project` link from being a 404: a person's own
session page names a project, so the name that row points at has to be
resolvable. It follows the session decision rather than repeating it.

**The session clause reaches the viewer's own rows and no further.** A project
carries `name` and `parent`, and `parent` can name an entity the entity rule
above deliberately withheld from this viewer. Following every VISIBLE session -
a colleague's included - would therefore make a withheld entity recoverable out
of `projects[].parent`, which is what `docs/client-spec.md` refuses one level
down when it says `hidden` is a count and never names. The rationale for the
clause only ever covered the viewer's own link, so that is how far it goes.
Pinned in `test/desk-snapshot.test.sh` ("a project travels with its entity or
with the viewer's OWN session").

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
| `owner` | string | the principal id of the person the session belongs to. A row with `ACCOUNT` must resolve to a registered account, and its `OWNER` must be that account's `USERNAME` **or** its `PRINCIPAL` - the two shapes this product's own writers have emitted; anything else is a borrowed identity and the row is refused. A `HOST` the account does not name is a gap, not a fault: a session may live on a host the hub only deploys to. That is the read rule; the WRITE rule is stricter, and `steward registry session realign` moves a row to the shape today's writers emit. A refused row is absent here and named in `unreadable` (docs/client-spec.md:208-213), never a blank fleet. Only a legacy row with no `ACCOUNT` uses `OWNER` as its principal. |
| `mine` | boolean | whether `owner` equals the viewer. |
| `domain` | string or null | the owning entity. |
| `project` | string or null | the target project. |
| `runtime` | string | `claude-code`, `opencode`, `codex`. |
| `host` | string | the machine the session lives on. |
| `repo` | string | the repository's **name** - never its path. |
| `liveness` | object | `state`, `measuredAt`, `ageSeconds` (below). |
| `sight` | string | `owner` or `member` - which of the two field sets this row was projected through, said out loud so a view never has to infer it from which keys arrived. A `readAll` viewer reads `owner` on every row. |
| `mcp` | array | the granted assets that reached this viewer - always present, possibly empty (below). |

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

**The array is always present; the AXIS decides what is in it.**
`lib/visibility.sh`'s `visibility_field_list` names `mcp.*` under both `owner`
and `member`, so every row a viewer receives carries the key - an empty array
means "nothing on this row reached you", never "this key is not for you", and a
consumer never has to tell an absent key from an empty one.

**The axes are not interchangeable, and `lib/visibility.sh`'s
`visibility_asset_axes` is the one place that says so.**

| axis | who receives it |
|------|-----------------|
| `account` | the owner, and a `readAll` viewer. Nobody else, ever. |
| `entity` | anyone the granting entity is visible to. |
| `project` | anyone the entity the source project hangs under is visible to. |

An `account`-axis asset is a person's own credential - a mail account, a note
store - granted to the human sitting in the session and not to the org node
above them. An `entity`- or `project`-axis asset was granted by an org node,
and it travels exactly as far as that node does: a member of the granting
entity sees what their own entity handed out, which is a fact about their own
team rather than about a colleague.

**Where each half of that decision lives.** The axis table is shell, in
`lib/visibility.sh`, and `desk/snapshot.sh` passes it into the filter - the
renderer states no policy of its own. The "is the granting node visible to this
viewer" half is `filter.jq`'s `isVisibleEntity`, the same function this
document already applies to `entities[]` and `projects[]`; it is the entity
rule applied to an asset's source, not a second copy of the axis policy, and it
can only ever narrow the table, never widen it.

**One entry per asset here, and `source` is a source the reader can see.** More
than one level may grant the same asset - a managing team and the client it
manages both declaring it is ordinary - so `steward mcp surface` carries one
row per GRANT, closest level first. The rule above is applied to each of those
rows and the survivors are deduplicated by `id` afterwards, so this array
carries each asset once, attributed to the nearest granting level that is
visible to this viewer. Deduplicating first is what made the promise above
false: the asset was named after the manager alone, and a member of the managed
client - not a member of its manager - lost what their own entity had granted
them. An asset every granting level withholds from this viewer is still absent,
which is the rule doing its job.

**Decided 2026-09-08, reversed 2026-09-08.** For one branch the whole array was
an owner field, on the argument that two rules for one question is how a
renderer drifts from the gate. That argument was for MOVING the axis rule out
of `jq`, which is what the table above does; deleting it instead removed a
capability no spec sentence asked to remove, and left the product answering one
question two ways - `steward sessions --json` handed a member the colleague's
declared `ASSETS` while the desk handed that same member no `mcp` key at all.

**`assets` in `steward sessions --json` is a different question.** That field is
the row's own declared `ASSETS` line - what the session says it wants - and it
carries no axis at all; `docs/client-spec.md` pins it as always a list of the
row's declarations. This document's `mcp[]` is the surface that RESOLVED for
this viewer. The two are only ever compared by mistake.

**The axis vocabulary is closed.** `account`, `entity` and `project` are the
complete known set, and an asset carrying anything else matches no line in the
table and is dropped even from an owner's document: an axis the policy cannot
interpret must never become an implicit grant the day the schema grows. A new
axis has to be admitted deliberately in `visibility_asset_axes`; it is never
inherited.

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
   `DESK_SESSION_KEY_FILE="<absolute path>"` in `estate/steward.conf`. The
   origin is `https://` plus the host, with an optional `:<port>`, and
   **nothing else**: no path, no trailing slash. `desk-paths` checks the form
   and exits 78 naming the key on anything else, so a desk never runs on a
   guessed origin. The key file is generated once, 0600, owned by the desk
   account, at least 32 bytes:
   `umask 077; head -c 32 /dev/urandom | base64 > <path>`.
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
   `<tailnet addr>:<port>` with the visitor's address as `X-Real-IP`. The box
   must **overwrite** any `X-Real-IP` the client sent rather than append to
   it - Caddy `header_up X-Real-IP {remote_host}`, nginx
   `proxy_set_header X-Real-IP $remote_addr;`. The desk believes the header
   only as a single well-formed IP literal (a comma, or anything that is not
   an address, falls back to the box's own address), so a client-set copy
   cannot mint a fresh rate-limit bucket per request.

What a visitor sees: `/desk/auth/login` lists the providers; after the
provider's login the desk verifies the `id_token` (signature against the
provider's JWKS, issuer, audience, expiry, nonce), maps
`oidc:<slug>:<subject>` to a principal row through `desk/bin/principal-for-login`
and sets `__Host-desk-session` for 12 hours. **The cookie carries that
identity, not the principal**, and every request resolves it through
`desk/bin/principal-for-login` again - so removing the person's `OIDC_LOGIN`
word, moving it to another row, or deleting the row all log them out within
five seconds rather than at the cookie's expiry. Five and not zero: the
bridge forks a subshell per principal row, so the answer for one identity -
a slug, or nobody - is remembered for five seconds and the desk asks once per
identity per five seconds instead of once per click. `POST /desk/auth/logout`
clears the cookie.

**The budgets are per ADDRESS, and the address is the one the proxy box
reported.** `/desk/auth/*` is rate limited to 10 requests per minute per
visitor address: that is the provider redirect, the callback and the logout,
the three that spawn a bridge or talk to a provider. `GET /desk/auth/login`
with no `provider` is the chooser page - it reads nothing, spawns nothing and
contacts nobody - so it costs no hit at all. Every other path on the front -
the ones that resolve a cookie, read a snapshot and render - gets 120 per
minute per visitor address. Every page carries
`<link rel="icon" href="data:,">`, so the browser asks for no favicon and a
page view is one hit rather than two: about 120 page views a minute per
address. A team behind one NAT shares one address and therefore shares one
budget - which is the cost of measuring the visitor rather than the cookie,
and is deliberate: a budget per cookie is a budget anybody can mint more of.

The front never reads the `tailscale-user-login` header; the tailnet socket
never reads a cookie.

**Known costs.** Two things a person setting this up should know before they
meet them:

- `desk-paths` resolves `origin=` and `session_key=` through
  `registry_estate_file`, which honours `STEWARD_ESTATE`, but resolves
  `providers=` through `_registry_estate_root`, which does not. Set
  `STEWARD_ESTATE_ROOT` for the desk, not `STEWARD_ESTATE`, or the desk finds
  an origin and a key and no providers - and refuses to start for the
  providers it cannot see. The deploy sets `STEWARD_ESTATE_ROOT`.
- The per-request `principal-for-login` lookup is a synchronous spawn with a
  five second timeout, and the desk is one process with both listeners in it.
  A slow registry bridge therefore stalls the tailnet listener as well as the
  front, for up to five seconds per request.

## What is deliberately absent

The raw document the producer builds carries more than any of this, and none of
it is named by the filter, so none of it can appear here: MCP command lines,
arguments and env files (`mcp surface` already refuses to print them),
repository paths, browser rig ports and profiles, and `mcpReason` - the raw
document's note that a session's surface could not be resolved. A viewer whose
session has an unresolved surface sees an empty `mcp` list.
