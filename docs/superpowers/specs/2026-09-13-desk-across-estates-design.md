# Desk across estates — one view, three producers (design, 2026-09-13)

**Status:** presented to the estate owner 2026-09-13; awaiting approval of this
written form. Companion specs: `2026-09-08-desk-services-design.md` (the Desk
itself) and `2026-09-08-desk-front-design.md` (the public door). Neither
designs a second estate; this spec adds that and changes nothing else.

**This version writes nothing.** Desk as an authority over estates is a separate
decision, deliberately deferred. Everything below is read-only, and the
approved Desk spec's rule that the first version writes nothing stands
unchanged.

## The measurement that starts it

Three estates run the product: basement (Linux), butler (macOS), skeppsbron
(Linux). Each produces a correct per-principal snapshot. One of them serves a
Desk, and that Desk can see exactly one estate — its own. A person with
sessions on two machines has no page that shows them both, and the operator has
no page that shows the fleet at all.

Measured 2026-09-13: skeppsbron's producer runs and answers
`host: skeppsbron`, two sessions, rc 0. The bytes exist. Nothing carries them.

## Shape

**One Desk. Three producers. The consumer pulls.**

An estate is named after its machine — `basement`, `skeppsbron`, `butler` —
and this spec spells them that way throughout. The third was called `minin` in
conversation for a year, after the hardware it runs on, and that nickname does
not appear in any estate's own `ESTATE_NAME`. A composed view is exactly where
such a habit becomes a defect: two estates would answer with the name their
register holds and one with the name people happened to use, and nothing in the
document would say they were the same kind of word.

```
  skeppsbron ──┐
               │  (pull, ssh + forced command)
  butler ──────┼─────────────▶  basement: desk/remote/<estate>/
               │                          desk/current/          (its own)
  basement ────┘                              │
                                              ▼
                                        one Desk, one page per viewer
```

Three properties follow from the arrow's direction, and each is the reason for
it:

1. **A producer never holds a key into the consumer.** The estate being read
   gains nothing by being read. An estate that is compromised cannot write into
   the Desk host; it can only stop answering.
2. **A dead estate is a stale snapshot, not a broken Desk.** The Desk reads
   files. If a fetch fails, the previous generation is still on disk and the
   estate is marked — the page renders.
3. **Only one machine needs the server.** butler and skeppsbron need `bash` and
   `jq`, which they have. `node` stays on basement alone. Measured: skeppsbron
   has no node installed, and under this design it never needs one.

### Why not one Desk per estate

It was the alternative considered. It means three network-facing servers to
harden, three fronts, three sets of credentials — and it still would not
produce a fleet view, because each Desk would see only its own estate. The
multi-estate problem is not solved by more Desks; it is solved by one consumer.

## Transport

A key per estate on the Desk host, bound on the producer's side to a **fully
fixed** forced command:

```
command="STEWARD_ESTATE_ROOT=<root> /bin/bash <scripts>/desk/bin/desk-snapshot-serve",restrict
```

This is the shape already in production for the bus relay, unchanged:

```
command="STEWARD_ESTATE_ROOT=/home/steward/Projects/basement /bin/bash \
         /home/steward/scripts/bus/bin/bus-relay-peer butler jon"
```

**The client names nothing.** The command takes no argument and reads no
`SSH_ORIGINAL_COMMAND`. The producer decides what it sends; the consumer cannot
ask for a path, a principal, or a directory. A forced command that parses a
client-supplied word is a parser on the far side of a trust boundary, and this
one has nothing to parse.

`desk-snapshot-serve` writes the current generation to stdout as a tar stream
and exits. It reads only the directory the local snapshot run published, never
the raw document — **the bytes that travel were already filtered when they were
written.** The raw document still never leaves the producing process; that
property is `snapshot.sh`'s and this spec does not touch it.

### What the consumer therefore holds

Every viewer file of every estate it consumes. This must be said plainly:
consuming an estate is a **trust relationship between estate owners**, not a
public read. The filter that decides what a *person* may see already ran on the
producer; the filter that decides what an *estate* may consume is the key, and
the key is granted once, by hand, by the producing estate's owner.

## What lands where

```
<desk-dir>/current/            the local estate      (unchanged)
<desk-dir>/remote/<estate>/
        current -> gen-<epoch>/    <principal>.json, _operator.json, meta.json
```

Mode 0700 on every directory, 0600 on every file, set by the fetching process
and not inherited — the same reasoning `snapshot.sh` already documents, for the
same reason: the mode bits are the last gate, so the process that writes them
sets them.

**A fetch never writes into the directory a reader is reading.** Each run builds
a whole `gen-<epoch>` and moves one symlink, exactly as the local producer does.
A reader sees the previous generation complete or the new one complete.

`meta.json` per estate carries what the consumer knows and the producer cannot:

| field | meaning |
|---|---|
| `estate` | the estate's name, as the consumer's register spells it |
| `fetchedAt` | UTC, when this fetch started |
| `status` | `ok`, `unavailable` |
| `reason` | absent when `ok`; otherwise one sentence naming the cause |

The snapshot's own `host`, `generatedAt` and `registryRevision` stay inside each
viewer file, written by the producer. The consumer never rewrites them:
`fetchedAt` is the consumer's fact, `generatedAt` is the producer's, and a
design that collapsed them would make a fresh fetch of an old snapshot look
current.

### A bad answer does not replace a good one

If the stream fails to arrive, fails to unpack, or unpacks to something that is
not a generation, the new directory is discarded and **the symlink is not
moved**. The previous generation stays, and `meta.json` records
`status: unavailable` with the reason. The alternative — swapping in whatever
arrived — would turn one bad fetch into a fleet that silently lost an estate.

## Absence is named, never omitted

The Desk shows, per estate, one of exactly three states:

| state | when | shown as |
|---|---|---|
| `ok` | fetched within the freshness window | the estate's rows |
| `stale` | fetched, but `fetchedAt` is older than the window | the rows, **and** the age |
| `unavailable` | the last fetch failed | no rows, **and** the reason |

**An estate that is silent must look silent.** It must never be an absent
section. This is the same rule the liveness seam already follows and that this
product has paid to learn twice: an unmeasurable rendered as a negative fact
sends someone to fix a thing that is not broken. A fleet page that quietly drops
a host is worse than one that says it cannot see it, because the first is
indistinguishable from a host with nothing on it.

The freshness window is the producer's timer interval times three, so a single
missed run is not an alarm and two are.

## Identity across estates

**The open question, and the one that changes the producer.**

The viewer file today carries the principal's slug and nothing else:

```json
{"host":"basement","generatedAt":"2026-09-13T16:10:05Z",
 "registryRevision":"8671c71","viewer":"jon"}
```

Nothing ties basement's `jon` to skeppsbron's `jon` except the convention that
we spelled them alike. That holds today and is exactly the kind of assumption
that holds until it does not — and the failure is showing one person another
person's sessions.

**The rule: the name is a label, the identity is the key.**

The producer adds the principal's identity word — `TAILSCALE_LOGIN` or an
`OIDC_LOGIN` entry, which the register already requires to be unique across all
rows — to each viewer file. The consumer joins a remote file to a local
principal **on that word**, never on the slug. A remote file whose identity
matches no local principal is held and shown to nobody: it belongs to a person
this estate does not know, which is a fact, not an error.

A remote file whose identity word is *absent* is also shown to nobody, and the
estate is marked with the reason. An estate running a producer too old to emit
the field is a real state during a rollout, and it must fail toward showing
less, never toward guessing.

This is the same discipline as the credential directory's: the pair names the
thing, and a name that merely looks right is not a key.

## The fleet view

The overview page — every estate, every session, at a glance — is a page of this
Desk, fed by the same composed document. It is what makes three estates worth
composing, and it is the first page that cannot be built without this spec.

It is deliberately **not** specified here beyond that. Its layout is design
work with its own iteration, and holding this spec open for it would delay the
transport that every version of that page needs.

## What this does not do

- **It writes nothing.** No verb, no button, no request that changes an estate.
- **It does not move anything between estates.** The transfer verb is its own
  spec, and this one must not become a half of it: a read path that could also
  write is how a read path becomes a write path.
- **It does not make Desk an authority.** Step 4 of the agreed order, decided
  separately, with this visibility in hand.

## Failure modes and exit codes

`desk-snapshot-serve` (producer): `0` a generation was written to stdout · `69`
no current generation exists · `73` the desk directory cannot be read · `78` the
estate or the registry would not load.

`desk-fetch` (consumer), per estate: `0` fetched and swapped · `65` the answer
was refused (did not unpack, not a generation, identity field absent) and the
previous generation was kept · `69` the estate could not be reached · `73` the
remote directory cannot be written · `78` the estate register would not load.
The command's own exit status is the worst of the per-estate statuses, and
**every** estate is attempted regardless of an earlier failure: a fetch that
stopped at the first unreachable estate would let one dead machine hide two live
ones.

## Testing

Hermetic, and no ssh in the suite. The transport seam is a command the fetcher
runs (`STEWARD_DESK_FETCH_CMD`), so the tests supply a stub that answers with a
tar stream, a truncated stream, a valid stream with the identity field removed,
a non-zero exit, and a hang. The claims that must bite:

1. A failed fetch **keeps** the previous generation and marks the estate.
2. A truncated or non-generation answer never becomes `current`.
3. An estate that is silent renders as `unavailable` with a reason — asserted
   both ways: the reason is present **and** the estate's rows are absent.
4. The join is on the identity word: a remote file whose slug matches a local
   principal but whose identity does not is shown to **nobody**.
5. `fetchedAt` and `generatedAt` are separate: a fresh fetch of an old snapshot
   reads as fresh-fetch, old-snapshot.
6. One unreachable estate does not stop the others being fetched.
7. Modes are 0700/0600 whatever the runner's umask.
