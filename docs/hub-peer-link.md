# Hub peer link — letters between two estates

Status: shipped, 2026-09-06 (`linux/hub/lib.sh`, `linux/hub/bin/bus-relay-peer`,
`test/hub-peer-out.test.sh`, `test/hub-peer-in.test.sh`). Rollout below is per
estate and still by hand. Implements the "owned hub link" the estates asked
for: *another person in a neighbouring estate must never reach my sessions
in my private estate, but my own sessions must be able to find each other
across several estates.*

## The one rule

**A link between two hubs has an owner.** Nothing crosses the link unless
the sending session is owned by the link's owner (measured in the sender's
own registry), and the receiving hub treats everything that arrives over
the link as written by that owner (measured from the key, never from the
letter). Two gates, one per hub, each against its own registry. Neither hub
trusts the other's claim about who wrote what.

## Vocabulary

- **peer** — a neighbouring hub, named by the estate that talks to it. The
  name is `[a-z0-9-]+` and is local to each side: what one estate calls
  `north` the other may call `south`.
- **link** — one direction of traffic, one key pair, one owner. A two-way
  neighbourhood is two links.
- **peer address** — `<name>@<peer>`: a session name (slug) as the peer
  knows it, at a peer as we know it.

## Data

### Sending side: `peers.d/<peer>.conf` in the estate root

```
HUB_SSH="operator@hub.example"   # ssh target of the peer hub, user@host
OWNER="alice"                    # the link owner: a unix account name in OUR registry
```

Read with `sed`, never sourced. Both keys required; `HUB_SSH` matches
`^[A-Za-z0-9._-]+@[A-Za-z0-9._-]+$`, `OWNER` matches `^[a-z][a-z0-9-]*$`.
A malformed row refuses (rc 78); it never falls back.

The private key for the link is `$HOME/.ssh/id_buspeer_<peer>` in the hub's
own home. Missing key → rc 65, named on stderr.

The estate deploys `peers.d/` to `~/scripts/peers.d/` on the hub (estate
install; the product's manifest does not carry estate data).

### Receiving side: one row in the hub's `authorized_keys`

```
restrict,command="STEWARD_ESTATE_ROOT=<root> /bin/bash <root>/bus/bin/bus-relay-peer <peer> <owner>" ssh-ed25519 AAAA… buspeer-<peer>
```

`<peer>` is what the receiving estate calls the sender; `<owner>` is the
link owner as a unix account name **in the receiving registry**. The key
says both; the wire says neither. Written by hand today, like the first
session keys were; an enrol verb is a later addition.

## Wire protocol (sending hub → receiving hub)

Over `ssh -i $HOME/.ssh/id_buspeer_<peer> -o BatchMode=yes -o ConnectTimeout=8
-o ServerAliveInterval=5 -o ServerAliveCountMax=3 <HUB_SSH>`, stdin:

```
<to>          line 1: recipient name as the peer knows it, [a-z0-9-]+
<from>        line 2: sender name as WE know it, [a-z0-9-]+ (slug, else id)
<text…>       rest to EOF, at most 65536 bytes, envelope on its first line
```

Same shape as `bus-relay-in` plus one line; the same read timeouts
(`BUS_RELAY_READ_TIMEOUT`, default 15 s) and the same byte cap.

## Sending: what `bus_send` does with an unknown name

`bus_send <to> <from> <text>` keeps its order — envelope parse, parking
gate, resolve — and grows one branch where it today returns
`unknown recipient` (rc 1):

1. **Explicit peer address** `<name>@<peer>`: the peer must exist in
   `peers.d` (else rc 65, "unknown peer"). Never resolved locally.
2. **Bare name that does not resolve locally**: candidates are the peers
   whose `OWNER` equals the sender's `OWNER` (sender's own row, via
   `bus_recipient_owner`). Exactly one candidate → forward there. None →
   rc 1, `unknown recipient`, as today. Several → rc 65 naming them:
   "ambiguous across peers, address as <name>@<peer>".
3. **Owner gate**: the sender's `OWNER` must equal the chosen peer's
   `OWNER`, else rc 65 with both names on stderr. A session of another
   owner never leaves the estate over a link it does not own.
4. **Forward**: pipe `to`, `from` (sender's SLUG, else ID), `text` over the
   link. ssh rc propagates. On rc 0 the sender's `sent/` copy is archived
   as for any delivery; on failure nothing is archived by the hub (the
   client already archives to `failed/`).
5. **FRAGA**: the sending hub does not run the FRAGA gate for a forwarded
   letter — it cannot see the recipient's row. The receiving hub runs it.
6. The parking list is the **sending** estate's; a parked subject is
   parked for outgoing letters too. The receiving hub applies its own
   list on arrival, like for any letter.

`STEWARD_BUS_SSH_BIN` stubs the transport in tests, as for
`bus_remote_deliver`.

## Receiving: `linux/hub/bin/bus-relay-peer <peer> <owner>`

Lands beside `bus-relay-in` (`scripts/bus/bin/`), same manifest section.

1. Reads the three parts with the same timeouts and cap as `bus-relay-in`;
   empty or late input → rc 64.
2. Form-checks `to` and `from` as `[a-z0-9-]+`. An `@` in `to` is a
   request to forward to a third hub: refused by the form check. **One hop,
   never a chain** — two hubs pointing at each other would otherwise loop
   until a disk is full.
3. Calls `bus_send "$to" "$from@$peer" "$text"` with
   `STEWARD_BUS_PEER_OWNER=<owner>` exported.
4. Exit codes: 64 for malformed input, otherwise `bus_send`'s.

`bus_send` learns one thing: a `from` of the form `<name>@<peer>` is
accepted **only** when `STEWARD_BUS_PEER_OWNER` is set (else rc 65 — a
local sender can never write that shape), and then:

- the letter is stored with `from` exactly `<name>@<peer>`; `bus-read`
  shows it as such. A local session can never carry an `@`, so a peer
  letter can never be mistaken for a local one. That is the forgery
  guard, structural, and it needs no lookup.
- the FRAGA gate compares `STEWARD_BUS_PEER_OWNER` with the recipient's
  `OWNER`. Only the owner rule applies across a link — no domain, group,
  or same-machine carve-out. A domain shared across estates is a new link
  with its own owner, additively, later.
- no `sent/` archive is written on the receiving hub (the sending hub
  already has it).
- delivery is otherwise unchanged: local inbox, or `bus_remote_deliver`
  to the recipient's own host inside the receiving estate. That hop is
  estate-internal and is not a chain.

## What this deliberately does not do

- No lookup protocol. A bare name is forwarded on the strength of the
  owner match; the peer answers rc 1 if it has no such session. Cheap,
  and it keeps "who exists on the other side" inside the other side.
- No peer enrol verb, no key rotation verb. Two `authorized_keys` rows and
  two `peers.d` files, by hand, with backups.
- No transitive routing, no broadcast, no shared domains across estates.
- No change to `bus-send` (the session client) or to the session keys.

## Tests (TDD, each red before green)

- `test/hub-peer-out.test.sh`: `peers.d` parsing and refusals; explicit
  address; bare-name forwarding with 0/1/many candidates; owner gate;
  wire bytes seen by the ssh stub (`to`, `from`, text, key path, target);
  sent archive on rc 0 only; parking applies; local resolution still wins
  over peers when the name exists locally.
- `test/hub-peer-in.test.sh`: drives `bus-relay-peer` as a subprocess
  with a fixture estate: protocol timeouts/caps, `@` in `to` refused,
  from stored as `<name>@<peer>` and rendered by `bus_read`, FRAGA allowed
  for the link owner's recipient and refused for another owner's, no
  `sent/` on the receiver, `bus_send` refuses `<name>@<peer>` without
  `STEWARD_BUS_PEER_OWNER`.
- `test/deploy-manifest.test.sh` (existing): the new script is in the
  manifest, executable, beside `bus-relay-in`.

## What shipped differently from the design above

Four things the design left open, decided while building and measured by the
suites:

- **A FRAGA refused across a link is rc 65, not the local gate's rc 1.** The
  local gate answers 1 because it is one of several reasons a send can fail
  ordinarily; a link refusal is a refusal WITH an explanation, and the link's
  other refusals already carry 65. The message names both owners.
- **`bus-relay-peer` form-checks its own argv and answers rc 78.** A `<peer>`
  or `<owner>` outside `[a-z0-9-]+` is a broken `authorized_keys` row on THIS
  machine — configuration, not input — so it is not folded into the 64 that
  describes what arrived.
- **`bus_send` re-checks the sender's shape, not only the forced command.** The
  stored `from` is what a reader sees and what an archive is searched by, so
  `<name>@<peer>` is split and both halves checked there too (rc 65), together
  with the owner it was handed.
- **The manifest assertion covers all three forced commands.** Rather than a
  row named on its own, `test/deploy-manifest.test.sh` requires
  `bus-relay-in`, `bus-relay-deliver` and `bus-relay-peer` to be 755 manifest
  rows: each is the whole vocabulary of a key that is already installed
  somewhere else, and losing one breaks that key rather than the deploy.

One finding worth keeping: an apostrophe inside `${1:?word}` is parsed as a
quote even within double quotes. `"the peer's name"` in the first argument
guard swallowed the entire `OWNER=` assignment on the following line, and the
script ran with an unset owner until the suite caught it.

## Rollout (per estate, after the product ships)

1. Each hub: `ssh-keygen -t ed25519 -f ~/.ssh/id_buspeer_<peer> -N ''`.
2. Each hub: the other's public key as the `bus-relay-peer <peer> <owner>`
   row, backup first.
3. Each estate: `peers.d/<peer>.conf`, install.
4. Measure both directions: a letter each way lands rc 0, `bus-read`
   shows `from=<name>@<peer>`; a letter from a session of another owner
   is refused rc 65 on the sending side; a FRAGA to another owner's
   session is refused rc 65 on the receiving side.
