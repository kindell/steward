# Session identity and display

**Date:** 2026-09-11
**Status:** fourth revision. Probe P1 has run (2026-09-11, results folded in
below); awaiting Jon and a closing advisor pass before the plan.
**Scope:** spec A of two. The entity/project graph (Nav/Steward as real
projects under estate entities, MANAGED_BY hygiene, infra semantics) is
spec B and is deliberately not here.

## The problem

One field, `RC_LABEL`, does two jobs today: it is what a human reads in
Remote Control, and it is how supervision finds the process. The library
already forbids the second:

> DISPLAY IS PRESENTATION, NEVER IDENTITY. Nothing may match a process, a
> pane or a bus address against this string — supervision keys on ID +
> ACCOUNT (+ tmux/pid). (`lib/registry.sh:3917`)

Deciding consumers that break it (census 2026-09-11):

| consumer | how |
|---|---|
| `linux/session-supervisor-linux.sh` `matching_claude_pids` (:951-968) | pgrep on `--remote-control <label>`; decides "healthy" |
| same, `reap_orphan_claude` (:1075-1134) | uses `matching_claude_pids` once tmux is gone |
| same, `type_line` | `send-keys -t "$NAME"` — the session's **current** pane, not Claude's |
| `watch/lib.mjs` `findProcess` (:82-96) | matches `--remote-control <label>` in ps text |
| `watch/session-watch.mjs` (:143-154), `watch/restart-session.mjs` (:25-40) | same lookup |

`linux/liveness-host.sh` is pane+descendant bound — the right shape, but it
is corroboration, not proof, until it reads the adapter in §1.

Consequences, measured: a hand-typed label rots (`Point→WordPress` against
`NAME="WWW"`); a renamed project makes the supervisor see an unidentified
process every round and never reach a safe state; the company form leaked
into a label (`Varvet AB→steward`) because the label is free text; and a
`/rename` typed at the wrong moment lands in a shell, where the supervisor's
own comment records that a conf string **executes** (`:1392`, canary-proven).

## Facts the design rests on

- **Remote Control shows `--remote-control [name]`, not `--name`.** Probed
  2026-09-11 on a fresh session.
- **The tile's name is frozen at registration** (`:140-147`, measured
  2026-08-31 at the vendor-visible level). **P1 did not reproduce it at the
  bridge level:** after a clean `/exit`, resuming the same thread with a new
  `--remote-control` gave a bridge file whose `name` was the new argv value.
  Either the vendor changed, or the 08-31 case had a still-registered tile,
  or the two levels differ — the claude.ai tile was not observed in P1. The
  spec keeps the 08-31 claim scoped to level 3 and relies on level 2 only
  where P1 measured it. Otherwise: a restart of the same thread reattaches under the stale name;
  the only rename is `/rename` typed into the live session, confirmed by the
  pane receipt `Session renamed to: <name>`. The supervisor runs this cycle
  (`RENAME_PENDING`, `:1369-1403`). Restart is not rename.
- **The vendor writes a local bridge file per interactive process:**
  `<CLAUDE_CONFIG_DIR>/sessions/<pid>.json` with `pid`, `procStart`, `tmux`
  (= `<register ID>:@win.%pane`, resolvable as a tmux `-t` target — measured),
  `sessionId`, `name`, `nameSource`, `nameSince`, `status`, `startedAt`,
  `kind`. Measured on one live process. **It is an undocumented vendor
  format**: the design treats it as *local bridge attestation*, never as
  authority (§1). **P1 measured its lifecycle** (throwaway sessions, this login): the file
  appears within 1 s of spawn; `/rename` sent to the exact pane updates
  `name` and advances `nameSince` within 1 s, with the pane receipt; clean
  exit and TERM remove it within 2 s; **KILL -9 leaves it behind** (stale
  file confirmed; it was gone by the time a later process started — vendor
  GC on start is a hypothesis, not measured); a tmux `rename-session` does
  **not** update `tmux` — the field records the name at registration; an
  RC-free row (only `--name`) also gets a file, with `name` from `--name`;
  two processes in one tmux session get distinct `@win.%pane`;
  `nameSource` reads `user` whether the name came from argv or `/rename` —
  it does not distinguish them, `nameSince` does.
- The renderer exists (`registry_display_for`, root-to-leaf, refuses on an
  unresolved chain); `registry_session_display` applies the precedence.
- The pause marker does not stop a process (`:160-163`).
- `runtime_alive_in_session` is deliberately loose (`:998-1012`): a kill veto
  only.
- The macOS twin lives in the butler estate; `ps eww` shows no environment
  there.
- Bus addressing is slug-addressed, ID-keyed. Display is uninvolved.
- Central watch runs in the hub account and **cannot read other owners'
  0750 config dirs**.

## Decisions (Jon, 2026-09-11)

- Display is the root-to-leaf ancestry (`Team→Kund→Projekt` in the common
  case), arrow only, no account and no machine in the name.
- A root entity (no `MANAGED_BY`) is the team. No collapse rule, no `IS_TEAM`.
- `Varvet`, never `Varvet AB`, in any register value or label.
- Work rule: one `claude-code` row per (login, project) among non-retired rows.
- Identity binds to ID, never to the string.

## Design

### 1. Identity — one adapter, tri-state

**One strict adapter** answers "what is row `$ID`'s managed process" for every
consumer (supervisor, watch, liveness-host, doctor). Four direct JSON readers
would drift the day the schema moves; one reader fails in one place.

The adapter resolves the config dir through the row's **LOGIN + ACCOUNT +
OWNER**, never login alone — the two-account fault of 2026-09-11 must not
return inside identity itself. It reads `sessions/*.json` in that dir and
accepts a file only if it is a regular file (no symlink), bounded in size,
well-formed, typed as expected, with `tmux` exactly `<ID>:@<n>.%<m>`, and
with `pid`+`procStart` naming a live process whose OS start time matches.
`bridgeSessionId` and `messagingSocketPath` are never read or logged.

**Its answer is tri-state:**

- **alive** — exactly one accepted file for `$ID`.
- **dead** — no file, and the persisted launch generation (below) says the
  last known `pid`+`procStart` is gone with a receipted stop, or there is no
  generation at all.
- **identity-unknown** — everything else (P1 step G showed why a first-match
  reader is not acceptable: it attributed a KILLed process's stale file to a
  fresh RC-free session — the glob-order fault, reproduced by the probe itself): a file that is missing, late,
  half-written or of unknown schema while tmux or a runtime exists; a
  `procStart` mismatch; **more than one** accepted file for `$ID`
  (split-brain). Unknown is never rendered as dead.

**No writes on unknown.** Kill, restart, `/rename`, reap and spawn all
require *alive* or *dead*. Central watch must not report dead on unknown.

**Bounded grace at spawn.** After a spawn the adapter allows N rounds for the
bridge file to appear; during grace the process and pane may live but nothing
is written and watch stays quiet; after grace the row is degraded, alarms
once, and still nothing is written.

**Fail closed on schema.** If the vendor stops writing the file or changes
it so the adapter cannot parse, the identity capability reports *unsupported
bridge schema*, stops all writes, and **never** falls back to an argv or
label match. The doctor feature-probes the format; a green probe does not
turn a later parse failure into dead.

**Persisted launch generation.** After each confirmed bridge registration
the supervisor stores, per `$ID`: `pid`, `procStart`, `sessionId`, the last
observed bridge file name and time. This is history and bootstrap, not a
second truth: when a valid live bridge file exists, **its** fields win; a
contradiction between the two is *identity-unknown*, never latest-wins.

**Bootstrap and orphan, by generation:**

| bridge file | generation | tmux `$ID` | meaning | allowed |
|---|---|---|---|---|
| none | none | absent | never launched, or cleanly offboarded | **spawn** (exactly one) |
| none | present, old pid+procStart gone, stop receipted | absent | cleanly stopped | spawn |
| none | present, old pid+procStart gone, **no** stop receipt | absent | unaccounted | refuse spawn, alarm |
| none | present, old pid+procStart **alive** | absent | orphan | reap that pid+procStart |
| none | any | present | late or missing registration | grace → unknown |
| one | — | **absent** | runtime alive under a *renamed* tmux session (P1: the `tmux` field does not follow a rename) | identity-unknown: no spawn, no reap, alarm |
| one | — | present | managed | alive |
| >1 | — | — | split-brain | refuse everything, alarm (pid/procStart only) |

`runtime_alive_in_session` stays exactly as it is: a broad veto that
postpones destruction. It never asserts identity or health.

### 2. Display and rename — gated on P1

At spawn, `--remote-control` and `--name` both receive
`registry_session_display "$ID"`. An RC-free row (`RC_LABEL=""`) stays
RC-free — no `--remote-control` — but `--name` carries the display.

**Rename reuses the existing cycle, bound to the managed pane.** Desired =
`registry_session_display`. Applied = bridge file `name`. When they differ
the row is *rename pending*, both names are reserved (§3), and the cycle
runs — with **every step addressed to the bridge file's exact `tmux` pane**,
never to `$NAME`: the immediate pid+procStart recheck, `capture-pane`,
`send-keys`, and the receipt read. A pane whose foreground is not the
managed runtime gets nothing typed into it. The TOCTOU between the last
check and `send-keys` remains; the exact pane makes its blast radius one
known process instead of whatever window a human left current.

**This is a new trigger.** Today the cycle runs after a supervisor spawn;
here it also runs when an entity or project `NAME` drifts under an old live
conversation. That is more writes. It is accepted for name-only changes
because a stale name makes a human pick the wrong tile, and because P1 and
the canary fixture (§5) must first show the typing lands only in the managed
pane.

**Receipt, two levels promised, one named as beyond us:**
1. *launched* — argv carries the desired string;
2. *bridge-registered* — the bridge file's `name` equals desired **and**
   `nameSince` advanced past the previous observation **and** `procStart`
   matches the OS process; the pane shows `Session renamed to: <desired>`;
3. *vendor-visible* — the claude.ai tile: human eyes until there is an API.

Level 2 is **measured** (P1): `/rename` to the exact pane updated the bridge
file within 1 s, `nameSince` advanced, the pane receipt appeared. Level 3
remains eyes-only.

**Retarget is not rename.** A change to `TARGET_PROJECT`, `PARENT` or
`MANAGED_BY` on an active row changes capabilities, visibility and mates
while the old process runs with the old MCP/config. Two operator paths, both
explicit:
- *Scope change* (the session's real customer/project changes): do **not**
  resume the old thread under the new target — create a new row and thread
  under the new target, verify, then stop and retire the old.
- *Same work, organisational move* (`PARENT`/`MANAGED_BY`): drain, stop with
  a receipt (no live bridge file), mutate the graph, re-render capabilities,
  restart, receipt.
`PARENT` and `MANAGED_BY` are shared edges: the graph writer computes the
**reverse dependency closure** and refuses while any affected row has not
gone through the stop transaction. Under pressure, create new entity/project
rows and migrate sessions one at a time instead of mutating shared edges.

### 3. Rules — who enforces what

**Registry gate (write time), estate-wide, static.** Reserves every
*desired* rendered string across all non-retired RC-enabled `claude-code`
rows in the estate; two slugs rendering identically are refused. The work
rule — one `claude-code` row per (login, project) — is enforced here too,
on **register lifecycle** (non-retired; or active+suspended by explicit
choice), never on live process state, which a writer cannot measure.
RUNTIME first: OpenCode/Codex exempt; their vestigial `LOGIN` removed.

**Host gate (spawn/rename time), local, measured.** Reserves the *applied*
and *pending* strings among live bridge files in the homes this host can
read. "Active" here means *a live bridge file exists*; pause releases
nothing; a row is retired only by a stop transaction ending with no bridge
file.

**Stated gaps.** Cross-host applied/pending and cross-estate anything are
**manual census** in A: before the first migration of any login used on more
than one host or estate, a census must show its applied and desired displays
unique. `peers.d` transports letters for a principal, exposes no register,
and cannot be a gate. Central watch marks other owners' rows *uninspectable*
or consumes the owner's own host measurement; it never infers from the hub
account.

**Refusal is asymmetric.** New spawn with an unresolvable display → no
start, rc 78, names the missing link, no slug fallback (non-empty `RC_LABEL`
starts as today: dual-read). Running row with failing derivation → kept
alive on identity, keeps applied name, degraded, alarms once per transition.
A name fault never authorises a kill.

### 4. Migration

One row at a time. Target resolves (hub rows wait for spec B). `RC_LABEL`
line **deleted**, not emptied — `""` is RC-free in both readers, absence is
rendered. Next round: desired ≠ applied → rename cycle → level-2 receipt.
Legacy precedence removed only when no row carries a non-empty `RC_LABEL`.

### 5. Tests and platforms

TDD; every guard proven by a mutation. Required before the first live row:

*Identity.* First-ever (no tmux, no bridge, no generation) spawns exactly
one. Cleanly stopped (generation + receipt, no bridge) respawns. Previously
launched, no receipt, no bridge → refuses, alarms. 0/1/>1 bridge files →
dead-or-spawn / alive / split-brain refusal. Malformed, truncated,
schema-changed, symlinked bridge → identity-unknown, zero writes. Delayed
bridge over several rounds → grace → degraded, no duplicate spawn. Display
changes while the same managed pid+procStart lives → still alive; every
label pgrep stub a hard failure. Two tmux IDs, identical rendered names, A
dies → B untouched, no kill or keystroke reaches B. A second Claude in
another pane of `$ID` while the managed one dies → not alive; veto still
blocks destruction. tmux renamed while runtime lives → no duplicate. Two
login slugs with the same `CONFIG_DIR` under two accounts → each resolved to
its own home (LOGIN+ACCOUNT+OWNER).

*Rename.* Claude in window 0, a shell canary current → `/rename` reaches
only the bridge file's pane; the canary never moves. Same thread resumed
with changed flags → name unchanged (frozen); cycle then applies; receipt at
level 2 (or level 1 + pane, per P1). Missing generation on a live legacy
process → seeded from the bridge file, never the register; bridge ≠
generation → unknown.

*Rules.* Two slugs rendering the same string → refused at write. Paused but
live → uniqueness not released. Retarget on an active row → refused;
shared-edge mutation refuses the whole reverse closure. Watch in another
owner's home → uninspectable, not dead. `session-watch`/`restart-session`
with a display change → no decision changes. Dual-read byte-identical.

**Platforms.** Fixtures portable for the contract. **Actual macOS execution
is acceptance before the first live row** — the twin's process model, veto
and bridge lifecycle are unmeasured. The butler estate implements and
measures its own.

## Gates before the plan

**P1 — done** (see Facts). Open from it: vendor GC of stale files (seen
once, not measured), and the level-3 tile on resume (needs eyes).

**P2 — macOS twin**, as above, in the butler estate.

**P3 — manual census** for any login on more than one host or estate.

## Order of work

1. The adapter: tri-state, grace, generation, bootstrap table, fail-closed.
   Supervisor liveness, duplicate guard and orphan reap on it;
   `matching_claude_pids` out of decisions.
2. Watch (`findProcess` and callers) and liveness-host on the adapter;
   uninspectable for other owners.
3. Display from the registry; RC-free alignment in both readers.
4. Rename cycle bound to the exact pane; desired ≠ applied trigger; receipt
   per P1; generation seeding; retarget refusal with closure.
5. Gates: registry (desired, work rule on lifecycle); host (applied+pending).
6. Migration of one work row after P3; measure; then the rest.
7. Legacy precedence removed when no non-empty `RC_LABEL` remains.

## Out of scope

Spec B. Seat rotation. Federated uniqueness. A vendor API for tiles.
