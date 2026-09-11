# Session identity and display

**Date:** 2026-09-11
**Status:** sixth revision, plan-ready per the advisor's sixth pass once
these were folded in: *moved* is not *orphan*; applied display is the last
receipted `/rename`, not the bridge's reported name; OS birth token and
bounded history in the generation; the pre-spawn-tmux row. Jon has delegated
execution.
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

### 1. Identity — one adapter, identity apart from health

**One strict adapter** answers "what is row `$ID`'s managed process" for every
consumer (supervisor, watch, liveness-host, doctor). Four direct JSON readers
would drift the day the schema moves; one reader fails in one place.

The adapter resolves the config dir through the row's **LOGIN + ACCOUNT +
OWNER**, never login alone. It reads `sessions/*.json` there. A file is a
*candidate* for `$ID` only if it is a regular file (no symlink), bounded,
well-formed, typed as expected, and its `tmux` is exactly `<ID>:@<n>.%<m>`.
`bridgeSessionId` and `messagingSocketPath` are never read or logged.

**Each candidate is classified**, never picked by order (P1 step G showed a
first-match reader attributing a KILLed process's stale file to a fresh
session — the glob-order fault, reproduced by the probe itself):

- **verified-live** — `pid`+`procStart` name a live process whose OS start
  matches (Linux: `/proc/<pid>/stat` starttime plus boot id; macOS: P2), whose
  uid is the row's account, and whose file is not older than the current
  spawn generation's launch (during grace a file that predates the launch is
  never the new registration). *Attachment* is then one of three: **managed-pane** when the pid is a
  descendant of the file's exact tmux pane; **orphan** when the pid is a
  descendant of **no pane on the whole intended tmux socket**; **moved** when
  the stored pane is gone or does not contain the pid, but the pid is found
  under some other pane or session on the socket (P1: `tmux rename-session`
  leaves the `tmux` field at the old name — the conversation is alive under a
  new name, not abandoned). A live pid whose stored pane exists but does not
  contain it is never managed: it is *moved* or a pid reuse, and either way
  unknown for writes.
- **stale** — well-formed, matches a known generation's `pid`+`procStart`,
  and that exact OS process is provably gone. Stale is evidence of a past
  process, not an unknown. It is ignored after two stable observations and
  recorded in the generation; the vendor's file is not deleted by us.
- **unclassifiable** — anything else: malformed, unknown schema, a live pid
  whose `procStart` or uid does not match, a file predating the launch during
  grace.

**The adapter's answer:**

| answer | when | writes allowed |
|---|---|---|
| **identified / managed-pane** | exactly one verified-live, attached | health, rename cycle to that exact pane, receipt |
| **identified / orphan** | exactly one verified-live, under no pane on the socket | reap that process by its OS birth token (existing two-round rule; human veto is an action gate) — then → no-process |
| **identified / moved** | exactly one verified-live, under a pane that is not the stored one | **nothing** written: no reap, no spawn, no rename; alarm; the operator restores the ID name or stops it deliberately |
| **no-process** (after two rounds) | zero verified-live; every candidate stale or absent; no broad-veto runtime under the managed pane/session | close zombie tmux per existing veto; **exactly one respawn**; receipt classifies the exit *planned* (stop receipt) or *unplanned* (none) |
| **identity-unknown** | ≥2 verified-live (split-brain); any unclassifiable candidate; the generation's process alive but no candidate names it | **nothing** written; degraded; alarm once (pid/procStart only) |

**Crash recovery is the normal path, not the exception.** A crash or a
human `/exit` removes the bridge file and leaves the generation without a
stop receipt. That is *no-process* once the generation's exact process is
gone and nothing else answers — and no-process respawns. The stop receipt
classifies the cause; it is **never a condition for resurrection**. Fail-closed
is for unknown, not for dead.

**No writes on unknown.** Kill, restart, `/rename`, reap and spawn all
require an identified or no-process answer. Central watch must not report
dead on unknown.

**Bounded grace at spawn.** After a spawn the adapter allows N rounds for a
fresh registration; during grace the process and pane may live but nothing
is written and watch stays quiet; after grace: degraded, alarm once, still
nothing written.

**Fail closed on schema.** If the vendor stops writing the file or changes
it so no candidate classifies, the capability reports *unsupported bridge
schema*, stops all writes, and **never** falls back to an argv or label
match. The doctor feature-probes the format; a green probe does not turn a
later parse failure into dead.

**Persisted launch generation**, per `$ID`: `pid`, the **exact OS birth
token** (Linux: boot id + `/proc/<pid>/stat` start ticks; macOS: what P2
finds), the vendor's `procStart` as an observation beside it, uid,
`sessionId`, our launch time, last observed bridge (`name`, `nameSince`,
mtime, inode), the **last confirmed applied display** with its receipt time,
stop receipt if any, and a **bounded history of earlier (pid, birth token)**
pairs so a second or third KILL-stale file is still classifiable. During
grace a file whose mtime, inode or `startedAt` predates the launch is never
the new registration, even with a reused pid. History and bootstrap, not a
second truth: a verified-live file's fields win; a contradiction is
identity-unknown, never latest-wins.

**Bootstrap.** *No generation* means first-ever **only after a one-time
census**: at first deploy on existing rows, every row's processes, bridge
files and tmux sessions are snapshotted, a generation seeded, and a bootstrap
receipt written. Before that census, no-generation on an existing row is
identity-unknown — it may be an old unregistered orphan. After it, the table
holds:

| bridge | generation | tmux `$ID` | reading | action |
|---|---|---|---|---|
| none | none (post-census) | absent | first-ever | spawn exactly one |
| none | none (post-census) | **present** | manual or zombie tmux before first spawn | no-process only if the pane/runtime veto is empty; otherwise identity-unknown |
| none | process gone, stop receipt | absent | planned stop | respawn if the row is active |
| none | process gone, no receipt | absent | **unplanned exit** | two rounds → no-process → respawn |
| none | process gone | present | zombie tmux | existing veto → close → respawn |
| none | process **alive** | any | live process, no attestation | identity-unknown (grace after our own spawn) |
| one live, attached | — | present | managed | identified / managed-pane |
| one live, under no pane | — | any | orphan | identified / orphan → reap |
| one live, under another pane | — | absent or renamed | **moved** | identified / moved → nothing, alarm |
| one live, stored pane exists but lacks it | — | present | pid reuse or moved | identity-unknown |
| stale only | matches | any | past process | as "none" for that row |
| ≥2 live | — | — | split-brain | identity-unknown |

`runtime_alive_in_session` stays exactly as it is: a broad veto that
postpones destruction. It never asserts identity or health — **it is an
action gate on close and respawn, not a fifth adapter answer**: the adapter
may say *no-process* while the veto still holds; close and respawn simply
wait until it clears.

### 2. Display and rename — gated on P1

At spawn, `--remote-control` and `--name` both receive
`registry_session_display "$ID"`. An RC-free row (`RC_LABEL=""`) stays
RC-free — no `--remote-control` — but `--name` carries the display.

**Rename reuses the existing cycle, bound to the managed pane.** Desired =
`registry_session_display`. **Applied = the last display confirmed by a
`/rename` receipt**, persisted in the generation — *not* the bridge file's
`name`. P1 showed the bridge `name` follows argv on a resume while the
2026-08-31 measurement says the vendor tile can keep the old one; the bridge
field is therefore the **locally reported name**, and equality between it and
desired proves nothing about the tile. When desired ≠ applied the row is
*rename pending* — persistent across restarts — both names are reserved
(§3), and the cycle runs **even when the new bridge file already reports
desired** — with **every step addressed to the bridge file's exact `tmux` pane**,
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
2. *receipted* — the pane shows `Session renamed to: <desired>` **and** the
   bridge file's reported `name` equals desired with `nameSince` advanced past
   the previous observation, on the process with the matching birth token;
   this, not the bridge field alone, becomes *applied*;
3. *vendor-visible* — the claude.ai tile: human eyes until there is an API.

Level 2 is **measured** (P1): `/rename` to the exact pane updated the bridge
file within 1 s, `nameSince` advanced, the pane receipt appeared. Level 3
remains eyes-only.

**Retarget is not rename.** A change to `TARGET_PROJECT`, `PARENT` or
`MANAGED_BY` on an active row changes capabilities, visibility and mates
while the old process runs with the old MCP/config. Two operator paths, both
explicit:
- *Scope change* (the session's real customer/project changes): do **not**
  resume the old thread under the new target. Create the new row and thread
  first **only if** both can coexist under the desired-name gate; otherwise
  stop and retire the old with a receipt first, accepting the downtime.
- *Same work, organisational move* (`PARENT`/`MANAGED_BY`): drain, stop with
  a receipt (no live bridge file), mutate the graph, re-render capabilities,
  restart, receipt.
`PARENT` and `MANAGED_BY` are shared edges: the graph writer computes the
**reverse dependency closure on register lifecycle across all hosts** — not
on bridge liveness, which a writer cannot measure — and refuses while any
affected row has not gone through the stop transaction. Under pressure, create new entity/project
rows and migrate sessions one at a time instead of mutating shared edges.

### 3. Rules — who enforces what

**The namespace of both gates is the LOGIN KEY** (amended 2026-09-11 — this
paragraph replaces the earlier "estate-wide"; Jon's decision of the same
day, point 4). A display is a tile in one Claude login's list, and two
logins have two lists that never meet: two project accounts under different
logins may render the same name, and `Chalmers→Innovation` needs no suffix
for that. Within ONE login, two identical names are two tiles a human cannot
tell apart, and that is what is refused. The key is the row's `LOGIN`; for a
legacy row that names none it is `owner:<OWNER>@<HOST>` — the HOME, which is
the closest thing to a login a row without one has, and exactly the scope
the older same-home label gate measured. **Both gates use this same key**; a
pair the registry gate allows must not be blocked by the host gate.

**Registry gate (write time), static.** Reserves every *desired* rendered
string across all non-retired RC-enabled `claude-code` rows **under the same
login key**, on every host; two such rows rendering identically are refused.
The work rule — one `claude-code` row per (login key, project) — is enforced
here too, on **register lifecycle** (non-retired; or active+suspended by
explicit choice), never on live process state, which a writer cannot
measure. RUNTIME first: OpenCode/Codex exempt; their vestigial `LOGIN`
removed. **Fail closed:** a candidate row that cannot be read, or whose
display will not render, makes the answer *uninspectable* and the write is
refused naming that row — uniqueness cannot be established by omitting the
rows one could not read.

**Host gate (spawn/rename time), local, measured.** Reserves the *applied*
and *pending* strings of rows **under the same login key** among live bridge
files in the homes this host can read. "Active" here means *a live bridge
file exists* — established by asking the adapter about that row and getting
`identified:*`, not by a generation's pid alone; pause releases nothing; a
row is retired only by a stop transaction ending with no bridge file. A row
of another owner on this host is *uninspectable*: under
`STEWARD_RESERVATION_STRICT=1` a colliding rendered display is refused
("manual census required"), otherwise it is named once and the write
proceeds. **The check and the write it authorises are one critical section**
on a host-wide lock: two supervisors must not both see a display free and
then both take it.

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
launched, no receipt, no bridge, process gone → **no-process after two
rounds → respawns** (the crash path; an earlier draft said "refuses" here
and was wrong — the bootstrap table is the law). 0/1/>1 bridge files →
dead-or-spawn / alive / split-brain refusal. Malformed, truncated,
schema-changed, symlinked bridge → identity-unknown, zero writes. Delayed
bridge over several rounds → grace → degraded, no duplicate spawn. Display
changes while the same managed pid+procStart lives → still alive; every
label pgrep stub a hard failure. Two tmux IDs, identical rendered names, A
dies → B untouched, no kill or keystroke reaches B. A second Claude in
another pane of `$ID` while the managed one dies → not alive; veto still
blocks destruction. tmux renamed while runtime lives → classified *moved*: **zero kill, zero
reap**, process continues, no duplicate, alarm. Live pid under a pane that is
not the stored one → unknown, never managed. Live pid under no pane on the
socket → orphan → reaped by birth token. Two
login slugs with the same `CONFIG_DIR` under two accounts → each resolved to
its own home (LOGIN+ACCOUNT+OWNER).

*Rename.* Claude in window 0, a shell canary current → `/rename` reaches
only the bridge file's pane; the canary never moves. Claude in the target
pane but a shell or subprocess **foreground** there → nothing typed
(descendant-of-pane is not foreground; the plan defines the foreground test). Same thread resumed
with changed flags → **per level**: bridge reported name = new argv (P1,
deterministic); tile behaviour is P1b case B, not a fixture; rename pending
stays set from the last confirmed apply and the cycle runs. Missing generation on a live legacy
process → seeded from the bridge file, never the register; bridge ≠
generation → unknown.

*State machine.* Crash (bridge gone, no receipt, tmux present) → two rounds
→ no-process → exactly one respawn. `/exit` with a shell left in the pane →
same. Stale file (pid gone, procStart matches generation) → classified
stale, ignored after two rounds, respawn allowed, file untouched. Stale +
one live → identified. Malformed + live → unknown, zero writes. Orphan
(one live, tmux gone) → reap that pid+procStart, then respawn. Pre-census
existing row, no generation → unknown; post-census → first-ever. File
predating our launch during grace → not accepted as the registration.

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

**P1b — human acceptance of level 3, two cases**, before the first live
NAME-drift rename. **A:** a live `/rename` through the *real* supervisor
cycle to the exact pane, a shell canary current in another window and a
subprocess foreground in the target pane at least once — a human sees the
old tile become the new one, no duplicate, no stale tile, nothing typed
anywhere else. **B:** clean exit, then the same thread resumed with a new
`--remote-control` — a human observes whether the old tile changes, stays,
or doubles. If B updates the tile, the bridge's reported name may be trusted
after registration; if B leaves a stale tile, *rename pending* stays
persistent from the last confirmed apply and the cycle runs regardless of
what the new bridge file reports (the default this spec assumes). Until P1b,
resume with new argv is not a rename proof.

**P0 — bootstrap census** before the adapter is activated on any existing
row: snapshot processes, bridge files and tmux per row; seed generations;
write the bootstrap receipt.

**Still unmeasured, carried by the plan:** `procStart` precision and
semantics per OS (is it a unique birth token, or second-rounded?); bridge
`tmux`/`pid`/`procStart` on macOS; partial-write atomicity of the bridge
file; stale-file lifecycle when the next process gets the same or another
pid; adapter answers for stale+live and malformed+live; `/exit` or crash
with a tmux shell left; the exact-pane canary through the production
`type_line`; central watch via the owner's host measurement.

**P2 — macOS twin**, as above, in the butler estate.

**P3 — manual census** for any login on more than one host or estate.

## Order of work

1. The adapter: candidate classification, four answers, grace, generation,
   bootstrap census (P0), fail-closed.
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
