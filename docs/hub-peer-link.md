# Hub peer link — letters between two estates

Status: shipped 2026-09-06, gates corrected the same day after two reviews
(`linux/hub/lib.sh`, `linux/hub/bin/bus-relay-peer`,
`test/hub-peer-out.test.sh`, `test/hub-peer-in.test.sh`). Rollout below is per
estate and still by hand; nothing is deployed yet. Implements the "owned hub link" the estates asked
for: *another person in a neighbouring estate must never reach my sessions
in my private estate, but my own sessions must be able to find each other
across several estates.*

## The one rule

**A link between two hubs has an owner.** Two gates, one per hub, each
against its own registry, and they answer different questions:

- **The sending gate decides who may USE the link.** Only a session owned by
  the link's owner, measured in the sender's own registry.
- **The receiving gate decides whom the link may REACH.** The link owner's
  own sessions in that estate, and nobody else's — for **every** class, not
  only for FRAGA. The recipient's `OWNER` is read from the receiving
  registry and compared with the owner the *key* names; a mismatch refuses
  (rc 65) before anything is delivered.

Neither hub can run the other's gate, and neither trusts the other's claim
about who wrote what. The wire carries a sender's name; the key carries the
owner.

**A FRAGA does not cross a link.** Refused on the sending side (rc 65,
nothing leaves) and again on arrival (rc 65, nothing queued), whoever it is
addressed to — the link owner's own session included. A FRAGA is answered by
machinery out of a catalogue, and the answer goes back to the asker as a
DRIFT letter; across a link there is no return route, because the answering
hub would have to address `<asker>@<peer>`, a shape no hub sends and no gate
accepts. A question queued for an answer nobody can deliver is worse than a
refusal. A lookup-and-answer protocol across a link is a later addition.

## Vocabulary

- **peer** — a neighbouring hub, named by the estate that talks to it. The
  name is `[a-z0-9-]+` and is local to each side: what one estate calls
  `north` the other may call `south`.
  **One estate, one name per neighbour, in both files.** The name in
  `peers.d/<peer>.conf` MUST be the name written in the `authorized_keys` row
  for that peer's key on the same hub (`bus-relay-peer <peer> <owner>`). A
  letter arriving over that row is stamped `<name>@<peer>`, and a reply to
  `<name>@<peer>` is routed through `peers.d/<peer>.conf` — so two spellings
  of one neighbour means every reply meets "unknown peer". The two ESTATES
  may still call each other whatever they like.
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
`^[A-Za-z0-9][A-Za-z0-9._-]*@[A-Za-z0-9._-]+$` — the whole value begins with
an alphanumeric, because ssh reads its destination as a word on a command
line and `-F@host` is a flag, not a target. `OWNER` matches `^[a-z][a-z0-9-]*$`.
A malformed row refuses (rc 78); it never falls back, and it is never
skipped: bare-name discovery reads `peers.d` as a whole set and refuses
(rc 78) while any row in it is broken, rather than routing on the rows that
happened to parse. That is estate-wide, not per owner: one owner's broken
row also stops another owner's bare-name sending until it is fixed, and the
refusal names the file, so the fix is a minute's work. An explicitly
addressed peer names its own row and gets that row's own answer.

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
-o ServerAliveInterval=5 -o ServerAliveCountMax=3 -o IdentitiesOnly=yes
-o IdentityAgent=none -o ClearAllForwardings=yes <HUB_SSH> false`, stdin:

```
<to>          line 1: recipient name as the peer knows it, [a-z0-9-]+
<from>        line 2: sender name as WE know it, [a-z0-9-]+ (slug, else id)
<text…>       rest to EOF, at most 65536 bytes, envelope on its first line
```

Same shape as `bus-relay-in` plus one line; the same read timeouts
(`BUS_RELAY_READ_TIMEOUT`, default 15 s) and the same byte cap.

`IdentitiesOnly=yes` and `IdentityAgent=none` are what make `-i` mean *only*
this key: with an agent running, ssh offers the agent's keys first and the
letter can arrive under a different `authorized_keys` row — another forced
command, another owner stamped on it. `ClearAllForwardings=yes` drops
anything a config file would tunnel along beside the letter. The trailing
`false` is a fixed remote command: the intended key's forced command
overrides it, so it never runs on the happy path; if any *other* key ever
authenticated, the remote runs `false`, our text is discarded with its
stdin, and nothing has opened a shell on a machine in another estate.

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
   "ambiguous across peers, address as <name>@<peer>". A malformed row
   anywhere in `peers.d` → rc 78, nothing sent.
3. **Owner gate**: the sender's `OWNER` must equal the chosen peer's
   `OWNER`, else rc 65 with both names on stderr. A session of another
   owner never leaves the estate over a link it does not own.
4. **Forward**: pipe `to`, `from` (sender's SLUG, else ID), `text` over the
   link. ssh rc propagates. On rc 0 the sender's `sent/` copy is archived
   as for any delivery; on failure nothing is archived by the hub (the
   client already archives to `failed/`).
5. **FRAGA**: refused, rc 65, nothing leaves — both for an explicit peer
   address and for a bare name that would be forwarded. See "The one rule".
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
- a **FRAGA is refused on arrival**, rc 65, nothing queued — whoever it is
  addressed to. The refusal runs before the recipient is resolved.
- **every other class is owner-gated**: the recipient's `OWNER`, read from
  the receiving registry, must equal `STEWARD_BUS_PEER_OWNER`, else rc 65
  naming both owners and nothing is delivered. The gate runs before the
  local inbox and before `bus_remote_deliver`, so it covers all three
  delivery paths (this home, another home on this machine, another machine
  in this estate). Only the owner rule applies across a link — no domain,
  group, or same-machine carve-out. A domain shared across estates is a new
  link with its own owner, additively, later.
- no `sent/` archive is written on the receiving hub (the sending hub
  already has it).
- delivery is otherwise unchanged: local inbox, or `bus_remote_deliver`
  to the recipient's own host inside the receiving estate. That hop is
  estate-internal and is not a chain.

### What the account is trusted with

The gates are enforced by the hub account and its home permissions, not by
anything structural. `STEWARD_BUS_PEER_OWNER` is an environment variable set
by the forced command; `peers.d` and `~/.ssh/id_buspeer_<peer>` are files in
the hub's home. Anyone who can run code as the hub account, or write those
files, can set the variable themselves, point a link elsewhere, or use the
key directly. The link adds no privilege the hub account did not already
have — it lets a neighbouring hub reach exactly the sessions its link's
owner owns here, through one forced command, and nothing more.

What *is* structural: the `@` in a stored sender (a local session's name can
never contain one), and where each fact comes from. The `from` on the wire is
a **display claim** by the sending hub — a label a reader sees, never a
credential. The `@<peer>` suffix and the owner are what the key
authenticates, and every gate measures those.

## Known, and shared with `bus-relay-in`

Both relays read the body the same way, so both carry the same two flaws.
Listed here rather than fixed, because fixing either one belongs in both
relays at once:

- **A body over 65536 bytes is truncated, not refused.** `head -c 65536`
  stops reading and the letter is delivered as its first 64 kB, with
  nothing on the record to say it was cut. The recipient reads half a
  sentence and cannot tell that from a sender who wrote half a sentence.
- **Without `timeout` or `gtimeout` on `PATH`, a withheld EOF hangs the
  reader.** The two `read -t` calls cover the first two lines; the body has
  no timeout of its own when neither binary exists, and the only remaining
  guard is the sending side's `ServerAlive`. On a hub where that PATH is
  short, a peer that opens a connection and stops writing holds a forced
  command open.

## What this deliberately does not do

- No lookup protocol. A bare name is forwarded on the strength of the
  owner match; the peer answers rc 1 if it has no such session. Cheap,
  and it keeps "who exists on the other side" inside the other side.
  **The cost: a mistyped recipient's full text reaches the peer hub.** A
  name this estate does not have is not a refusal, it is a forward — the
  letter crosses, the peer bounces it, and the body has been on the other
  machine by then. The peer hub is owned by the same person (that is the
  owner match), so this stays inside one person's own machines; it is a
  real leak of a slip of the finger, not of another person's mail.
- No peer enrol verb, no key rotation verb. Two `authorized_keys` rows and
  two `peers.d` files, by hand, with backups.
- No transitive routing, no broadcast, no shared domains across estates.
- No change to `bus-send` (the session client) or to the session keys.

## Tests (TDD, each red before green)

- `test/hub-peer-out.test.sh`: `peers.d` parsing and refusals (including a
  `HUB_SSH` that starts as an ssh flag, and a malformed row refusing the
  whole candidate set); explicit address; bare-name forwarding with 0/1/many
  candidates; owner gate; FRAGA refused both ways with the stub untouched;
  wire bytes and argv seen by the ssh stub (`to`, `from`, text, key path,
  target, the three pinning options, the trailing `false`); sent archive on
  rc 0 only; parking applies; local resolution still wins over peers when the
  name exists locally.
- `test/hub-peer-in.test.sh`: drives `bus-relay-peer` as a subprocess
  with a fixture estate: protocol timeouts/caps, `@` in `to` refused,
  from stored as `<name>@<peer>` and rendered by `bus_read`, FRAGA refused
  both to the link owner's session and to another owner's, every class
  owner-gated on arrival (an ordinary letter to another owner: rc 65, no
  inbox file, no ssh), no `sent/` on the receiver, `bus_send` refuses
  `<name>@<peer>` without `STEWARD_BUS_PEER_OWNER`.
- `test/deploy-manifest.test.sh` (existing): the new script is in the
  manifest, executable, beside `bus-relay-in`.

## What shipped differently from the design above

Decided while building, or in the fix round after two reviews, and measured
by the suites.

**Reversed after review (2026-09-06).** The first shipped version got the
boundary wrong in both directions, and both are now the opposite:

- **It delivered every non-FRAGA class to ANY owner's session.** The
  reasoning was that only a FRAGA hands the asker something the 750 homes
  hide. But an ordinary letter to another owner's session is written into
  that person's home — over ssh as them — on the word of a hub in another
  estate whose registry we cannot read. The class was never the boundary;
  the owner is. Every class is owner-gated on arrival now.
- **It let a FRAGA cross the link** and gated it by owner on the receiving
  side. There is no return route for the answer, so a FRAGA that crossed was
  a question queued for an answer nobody could deliver. It is now refused on
  both sides, for every recipient.

**Also in that round:** `HUB_SSH` must begin with an alphanumeric (`-F@host`
is an ssh flag, not a target); a malformed `peers.d` row refuses bare-name
discovery (rc 78) instead of being skipped, which had let a set of two links
read as a set of one and forward without the ambiguity that should have
stopped it; and the link's ssh is pinned to the link key
(`IdentitiesOnly=yes`, `IdentityAgent=none`, `ClearAllForwardings=yes`) with
a fixed remote command `false`.

**Decided while building:**

- **Every link refusal is rc 65, not the local FRAGA gate's rc 1.** The local
  gate answers 1 because it is one of several reasons a send can fail
  ordinarily; a link refusal is a refusal WITH an explanation, and the link's
  other refusals already carry 65. The arrival owner gate's message names
  both owners.
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

Two findings worth keeping, both about bash rather than about links:

- An apostrophe inside `${1:?word}` is parsed as a quote even within double
  quotes. `"the peer's name"` in the first argument guard swallowed the
  entire `OWNER=` assignment on the following line, and the script ran with
  an unset owner until the suite caught it.
- bash 3.2 cannot parse a `case` statement inside `$( )`: it reads the `)`
  that closes a case pattern as the end of the substitution, and the whole
  file stops parsing. `bus_peer_candidates` was first written that way (a
  subshell, to keep the `BUS_PEER_*` globals from leaking) and now runs its
  loop in the caller's shell, saving and restoring those two variables
  itself. That is also what lets its rc 78 propagate at all.

## Rollout (per estate, after the product ships)

0. Pick the name each estate will use for the other. **That one name goes in
   both of that estate's files** — `peers.d/<peer>.conf` and the
   `authorized_keys` row for that peer's key — or replies meet "unknown
   peer". The two estates need not agree with each other.
1. Each hub: `ssh-keygen -t ed25519 -f ~/.ssh/id_buspeer_<peer> -N ''`.
2. Each hub: the other's public key as the `bus-relay-peer <peer> <owner>`
   row, backup first.
3. Each estate: `peers.d/<peer>.conf`, install.
4. **Each hub: learn the other's host key first.** `BatchMode=yes` never
   accepts a new one, so an unknown host is a refusal, not a prompt — every
   measurement below fails until this is done. Either connect by hand once
   as the hub account and confirm the fingerprint, or
   `ssh-keyscan -t ed25519 <host> >> ~/.ssh/known_hosts` and check the
   fingerprint against the other machine.
5. Measure both directions: a letter each way lands rc 0, `bus-read`
   shows `from=<name>@<peer>`; a letter from a session of another owner
   is refused rc 65 on the sending side; a letter of ANY class to another
   owner's session is refused rc 65 on the receiving side and leaves no
   inbox file; a FRAGA is refused rc 65 on the sending side, and nothing
   leaves the machine.
