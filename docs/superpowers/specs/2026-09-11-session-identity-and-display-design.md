# Session identity and display

**Date:** 2026-09-11
**Status:** revised after the advisor's review of a30cca7; awaiting Jon
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

Consumers that break it (census 2026-09-11):

| consumer | how |
|---|---|
| `linux/session-supervisor-linux.sh` `matching_claude_pids` (:951-968) | pgrep on `--remote-control <label>`; decides "healthy" |
| same, `reap_orphan_claude` (:1075-1134) | uses `matching_claude_pids` to find the old runtime once tmux is gone |
| `watch/lib.mjs` `findProcess` (:82-96) | matches `--remote-control <label>` in ps text |
| `watch/session-watch.mjs` (:143-154) | label path for every non-RC-free row → central false-dead on rename |
| `watch/restart-session.mjs` (:25-40) | same lookup before a real restart |

`linux/liveness-host.sh` is already pane+descendant bound and is the model.

Consequences, measured: a hand-typed label rots (`Point→WordPress` against
`NAME="WWW"`); a renamed project makes the supervisor see an unidentified
process every round — it does not kill (`runtime_alive_in_session` vetoes) but
never reaches a safe state; the company form leaked into a label
(`Varvet AB→steward`) because the label is free text.

## Facts the design rests on

- **Remote Control shows `--remote-control [name]`, not `--name`.** Probed
  2026-09-11 on a FRESH session: claude.ai read `probe-adress`, the prompt box
  `probe-namn`. Display and the RC name are one vendor field.
- **The tile's name is FROZEN at registration.** Measured 2026-08-31 and
  written at `session-supervisor-linux.sh:140-147`: `--name`/`--remote-control`
  at start never renames an existing entity; a restart of the same thread
  reattaches under the stale name; the only rename is `/rename` typed into the
  live session, verified by the pane receipt `Session renamed to: <name>`. The
  supervisor already runs this cycle (`RENAME_PENDING`, `:1369-1403`,
  `type_line "/rename $RC_LABEL"`, receipt check at `:1266`). **Restart is not
  rename.** The fresh-session probe above does not contradict this: it never
  resumed a thread.
- **The vendor writes a local bridge file per interactive process:**
  `<CLAUDE_CONFIG_DIR>/sessions/<pid>.json`. Measured on this session
  (values of `bridgeSessionId` and `messagingSocketPath` never read or
  logged): it carries `pid`, `procStart`, `tmux` (= `<register ID>:@win.%pane`),
  `sessionId` (the thread), `name`, `nameSource`, `nameSince`, `status`,
  `statusUpdatedAt`, `startedAt`, `kind`. On this machine every file's pid is
  alive; the file of the process killed at 09:5x today is gone. Its lifecycle
  on SIGKILL is **not yet measured**; the design tolerates a stale file.
- The renderer exists: `registry_display_for` walks `parent→name`
  root-to-leaf (up to 64 levels) and **refuses** when the chain does not
  resolve. `registry_session_display` applies the precedence: non-empty
  `RC_LABEL` → project → entity → `prefix+slug`.
- The pause marker does not stop a process: the supervisor reads it and
  exits (`:160-163`). A paused row can still hold a live process and a tile.
- `runtime_alive_in_session` is deliberately loose (`:998-1012`): it vetoes
  destruction only. It is not a proof of identity and must not become one.
- The macOS twin lives in the butler estate. `ps eww` shows no environment
  on macOS; an env-var identity channel is unavailable there.
- Bus addressing is slug-addressed, ID-keyed (`bus_resolve_recipient` maps
  the handle to the ID-keyed queue). Display is uninvolved.

## Decisions (Jon, 2026-09-11)

- Display is the root-to-leaf ancestry `MANAGED_BY→…→ENTITY.NAME→PROJECT.NAME`
  ("Team→Kund→Projekt" in the common case), arrow as the only separator,
  **no account and no machine in the name**.
- A root entity (no `MANAGED_BY`) is the team. No collapse rule, never
  collapse on `NAME` equality, no `IS_TEAM`.
- The company is `Varvet`, never `Varvet AB`, in any register value or label.
- Work rule: at most one active `claude-code` session per **(login, project)**.
- Identity binds to ID, never to the string. Approach 1, amended below.

## Approaches considered

1. **The supervisor obeys the registry** — identity on ID via tmux and pids.
   **Chosen, amended:** the ID→process relation is the vendor's own bridge
   file, not the tmux pane list alone. The pane list stays as corroboration;
   `runtime_alive_in_session` stays as a kill veto. Reasons for the amendment:
   a second Claude opened by a human in another pane of the same tmux session
   would otherwise keep a dead managed runtime "healthy"; a renamed tmux
   session would otherwise drop the binding and allow a duplicate spawn;
   orphan reap would otherwise have no ID→pid relation once tmux is gone.
2. A marker in argv/env. Rejected: no vendor flag; env invisible to `ps` on
   macOS; a second identity field.
3. A pid file per ID written by us. **Superseded**: the vendor already writes
   one, with `procStart`, and it is the authority on what is bridged.

## Design

### 1. Identity

The managed process of row `$ID` is the one whose bridge file
`<login config dir>/sessions/<pid>.json` has `tmux` beginning `$ID:` **and**
whose `pid`+`procStart` name a live process. Everything that decides,
writes, or reports keys on that:

- **Liveness (supervisor and watch):** bridge file present for `$ID` with a
  live `pid`+`procStart`, and the tmux session `$ID` present. A missing file,
  a dead pid, a stale `procStart`, or a missing tmux session is *not alive*.
  Two consecutive rounds before any write, as today.
- **Kill veto:** `runtime_alive_in_session` stays exactly as it is — a broad
  veto that any interactive runtime under the panes postpones destruction.
  It never asserts health.
- **Orphan reap:** a bridge file whose `tmux` names `$ID` while the tmux
  session is gone identifies the orphan by `pid`+`procStart`. No label. If no
  such file exists, the orphan cannot be identified and **no reap happens**;
  the round warns and refuses a new spawn until an operator decides.
- **Duplicate guard at spawn:** a live bridge file for `$ID` refuses a
  second spawn, whatever tmux says.
- **`matching_claude_pids` and every argv/label match** are removed from
  decisions in the supervisor, `watch/lib.mjs`, `session-watch.mjs`,
  `restart-session.mjs`. `liveness-host.sh` corroborates with the bridge file.
- `pid` alone is never trusted; `pid`+`procStart` always.

### 2. Display

At spawn, `--remote-control` and `--name` both receive
`registry_session_display "$ID"`. The supervisor stops reading `RC_LABEL`
directly. An RC-free row (`RC_LABEL=""`) stays RC-free: no
`--remote-control`, but `--name` carries the display.

**Rename reuses the existing cycle.** Desired display =
`registry_session_display`. Applied display = bridge file `name`. When they
differ, the row is *rename pending*: the supervisor types `/rename <desired>`
through the existing `type_line`, and the rename is **confirmed** only when
the pane shows `Session renamed to: <desired>` **and** the bridge file's
`name` equals it with `nameSince` advanced. Both names are reserved while
pending (see 3). This is the mechanism the supervisor already runs after
every spawn (`:1677`); nothing new is typed into a session that is not
already typed today.

**Name-only rename is applied by the cycle.** It costs a slash command, not
a restart, and a stale name makes a human pick the wrong tile. *(This
changes the dialogue design, which assumed rename meant restart.)*

**Retarget is not rename.** A change to `TARGET_PROJECT`, `PARENT` or
`MANAGED_BY` on an active row changes capabilities, visibility and mates
while the old process runs with the old MCP/config. It is **refused on an
active row**; the row must be stopped, re-rendered and restarted as its own
migration.

**Three levels of receipt, named honestly:** *launched* (argv), *bridge-
registered* (bridge file `name`/`status`), *vendor-visible* (the claude.ai
tile — human eyes until there is an API). The spec promises the first two.

**Last-applied state** is seeded from the bridge file, never from the
register (a live process may carry a legacy name). No file → *unknown*,
degraded, operator decision. State loss is recoverable the same way.

### 3. Rules

**Work rule (write gate).** At most one active `claude-code` row per
(login, project), enforced in `registry session add` and the hub's enroll as
one shared gate. RUNTIME first: OpenCode and Codex are exempt (no tile), and
their vestigial `LOGIN` is removed in the same migration.

**Uniqueness proof (spawn/rename gate).** For all RC-enabled `claude-code`
rows under one login, the **applied rendered string** is unique among live
bridge files, and during pending both old and new are reserved. "Active"
means *a live bridge file exists*, not "unpaused": pause does not stop a
process. A row is retired only by a stop transaction that ends with no
bridge file. Two project slugs that render identically are a refusal at the
write gate. The work rule is a habit made rule; the string reservation is the
proof.

**Known gap, stated.** Both gates see one estate. Two estates do not see each
other, and `peers.d` transports signed letters for a principal — it exposes
no register and cannot be a write gate. Rule for A: **before the first
migration of any login used in more than one estate, a manual fleet census
must show its applied and desired displays unique across estates.** A
permanent invariant needs global project identity or a stable tiebreak; that
is out of scope.

**Refusal is asymmetric.** *New spawn:* `registry_session_display` refuses
→ no start, rc 78, message names the missing link; no slug fallback.
Exception: a non-empty `RC_LABEL` starts with it (dual-read). *Running row:*
derivation failing → kept alive on identity, keeps applied name, degraded,
alarms once per transition (journal + bus `DRIFT`). A name fault never
authorises a kill.

### 4. Migration

One row at a time.

1. Target resolves. Work rows already do. **Hub rows wait for spec B.**
2. `RC_LABEL` line is **deleted**, not emptied. `RC_LABEL=""` means RC-free
   in both readers (`registry_session_display` must read it so and feed only
   `--name`); an absent line means rendered.
3. The row's next round sees desired ≠ applied → the rename cycle runs →
   bridge-registered receipt.
4. Then the next row.

Legacy precedence is removed only when no row carries a non-empty
`RC_LABEL`. Last step.

### 5. Tests and platforms

TDD throughout; every guard proven by a mutation that makes it fire.
Required fixtures, all before the first live row:

- Display changes while the same managed `pid`+`procStart` lives → still
  found, still healthy; every label-based pgrep stub is a hard failure.
- Two tmux sessions with identical rendered names, A dies, B lives → B must
  not keep A healthy, must not receive A's kill or keystrokes.
- A second Claude in another pane of `$ID` while the managed runtime dies →
  row is *not alive*; the veto still blocks destruction.
- tmux session renamed while the runtime lives → no duplicate spawn.
- tmux gone, orphan with OLD display, register says NEW → orphan identified
  by bridge file, reaped by `pid`+`procStart`; with no bridge file → no reap,
  no spawn, warning.
- Paused but live row → uniqueness NOT released.
- Two project slugs rendering the same string → refused at write.
- Same thread resumed with changed flags → tile name unchanged (frozen);
  rename cycle then applies; receipt in pane and bridge file.
- `watch/session-watch.mjs` and `restart-session.mjs` with a display change
  → no decision changes.
- Missing last-applied state on a live legacy process → seeded from bridge
  file, never from the register.
- Retarget on an active row → refused.
- Dual-read: non-empty `RC_LABEL` starts byte-identical to today.

**Platforms.** Fixtures are portable for the contract. **Actual macOS
execution is acceptance before the first live row**: the twin's process
model, its `runtime_alive_in_session` veto, and the bridge file's lifecycle
on macOS are unmeasured. The butler estate implements and measures its own.

## Measurements still owed

- Bridge file lifecycle on SIGKILL and on clean exit (create/update/delete,
  `status` values). The design tolerates a stale file; the plan must confirm.
- The macOS twin, as above.
- Cross-estate duplicate behaviour (manual census procedure).

## Order of work

1. Identity on the bridge file: supervisor liveness, duplicate guard,
   orphan reap; `matching_claude_pids` out of decisions.
2. Watch: `findProcess` and its callers on the bridge file.
3. Display from the registry; RC-free alignment in both readers.
4. Rename cycle driven by desired ≠ applied; two-level receipt; last-applied
   seeded from the bridge file; retarget refused.
5. Gates: work rule at write; string reservation at spawn/rename; vestigial
   LOGIN off non-claude rows.
6. Migration of one work row; measure; then the rest.
7. Legacy precedence removed when no non-empty `RC_LABEL` remains.

## Out of scope

Spec B. Seat rotation. Federated uniqueness. A vendor API for tiles.
