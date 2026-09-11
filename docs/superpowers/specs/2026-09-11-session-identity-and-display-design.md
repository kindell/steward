# Session identity and display

**Date:** 2026-09-11
**Status:** approved in dialogue (Jon), spec awaiting review
**Scope:** spec A of two. The entity/project graph (Nav/Steward as real
projects under estate entities, MANAGED_BY hygiene, infra semantics) is
spec B and is deliberately not here.

## The problem

One field, `RC_LABEL`, does two jobs today: it is what a human reads in
Remote Control, and it is how the Linux supervisor finds the process
(`CLAUDE_PAT` is built from it, `linux/session-supervisor-linux.sh:951-968`).
The library already forbids this:

> DISPLAY IS PRESENTATION, NEVER IDENTITY. Nothing may match a process, a
> pane or a bus address against this string — supervision keys on ID +
> ACCOUNT (+ tmux/pid). (`lib/registry.sh:3917`)

The supervisor breaks a law the registry already wrote. Consequences,
measured 2026-09-11:

- A hand-typed label rots: `RC_LABEL="Point→WordPress"` against a project
  whose `NAME` is `WWW`.
- A renamed project changes the label, the label misses pgrep, and the
  supervisor sees an unidentified process every round. It does not kill it
  (`runtime_alive_in_session` refuses) but it can never reach a safe state.
  A safe wedge, not a working rename.
- Two identical labels in one login are undetectable across registers, and
  the estate's own rule says pairing is addressed by label.
- The company form leaked into a label (`Varvet AB→steward`) because the
  label is free text.

## Facts the design rests on

- **Remote Control shows `--remote-control [name]`, not `--name`.** Probed
  2026-09-11 with a throwaway session (`--remote-control probe-adress
  --name probe-namn`); the claude.ai list read `probe-adress`, the prompt box
  read `probe-namn`. Display and the RC name are the same vendor field. The
  separation therefore happens on our side, or not at all.
- The renderer exists: `registry_display_for` walks `parent→name`
  recursively and **refuses** when the chain does not resolve — a display is
  never invented. `registry_session_display` applies the precedence: non-empty
  `RC_LABEL` → derived from project → derived from entity → `prefix+slug`.
- The tmux session is already named by the session ID. `session_pane_pids`
  already reads its panes. The ID-bound path exists beside the label-bound one.
- `identity-schema.test.sh` already asserts "ID is the immutable key, separate
  from the display name" and "a display name is required and free-form".
- The macOS twin (`session-supervisor.sh`) lives in the butler estate, not
  in this repo.
- `ps eww` shows no environment on macOS, so an env-var identity channel is
  unavailable on one of two platforms.

## Decisions (Jon, 2026-09-11)

- Display is `Team→Kund→Projekt`: `MANAGED_BY→ENTITY.NAME→PROJECT.NAME`,
  arrow as the only separator, **no account and no machine in the name**. The
  account is the login the row appears in; the machine is invisible to
  colleagues.
- A root entity (no `MANAGED_BY`) is the team. `Point→Nudge` falls out of the
  walk; no collapse rule, never collapse on `NAME` equality, no `IS_TEAM`.
- The company is `Varvet`, never `Varvet AB`, in any register value or label.
- At most one **active** `claude-code` session per **(login, project)**. A
  habit becomes a rule.
- Identity binds to tmux name (= ID) and pane pids. Approach 1 below.

## Approaches considered

1. **The supervisor obeys the registry.** Liveness = tmux session `=$ID`
   exists, its panes have pids, `runtime_alive_in_session` finds the runtime
   beneath them. The label pgrep is removed as a decision input. Nothing new
   is added. — **Chosen.** It is what `registry.sh:3917` prescribes and it
   removes code.
2. A machine-readable marker in argv/env. Rejected: the vendor has no such
   flag, an env var is invisible to `ps` on macOS, and it is a second
   identity field — the thing being removed.
3. A pid file per ID. Deferred: pid reuse after a crash, and state that must
   be kept in step. May return as a secondary check if pane pids are measured
   to be unreliable. Not before.

## Design

### 1. Identity and display

In `linux/session-supervisor-linux.sh`:

- `matching_claude_pids` / `CLAUDE_PAT` (`:951-968`) is no longer a decision
  input. A session is alive when the tmux session named `$ID` exists, its
  panes have pids, and `runtime_alive_in_session` finds the runtime beneath
  them — a claude descendant for claude rows, the port for OpenCode. Every
  action that WRITES — kill, restart, keystroke — targets those pids and no
  others. The two-consecutive-rounds suspect marker stays.
- At spawn, `--remote-control` and `--name` both receive
  `registry_session_display "$ID"`. The supervisor stops reading `RC_LABEL`
  directly and asks the registry.
- An RC-free row (`RC_LABEL=""`) stays RC-free: no `--remote-control`, but
  `--name` still carries the display so it has a name in `/resume`.

Unchanged: tmux naming, bus addressing (already ID), `registry_session_display`
and its precedence.

**macOS.** The butler estate's `session-supervisor.sh` must satisfy the same
contract: identity on tmux name and pids, never on the string. This spec
states the requirement and ships the acceptance tests in portable form; the
butler estate implements. We do not measure its veto for it.

### 2. Rules

**Uniqueness.** At most one *active* `claude-code` session per (login, project) — active
meaning no pause marker in `PAUSED_DIR_NAME` for that ID. Enforced where rows are written — `registry session add`
and the hub's enroll — as one shared gate, the shape of
`registry_login_principal_gate`. The supervisor checks the same rule at
spawn so a row that slipped the write gate still does not start.

The rule reads `RUNTIME` first: only `claude-code` rows are subject.
OpenCode and Codex have no RC tile and are exempt by construction. Their
vestigial `LOGIN="jon-varvet"` is removed in the same migration so the rule
never sees a false collision.

**Known gap, stated:** the gate sees the whole estate register, every host.
Two estates do not see each other. `jon-point` with `Chalmers→Innovation` on
basement *and* on skeppsbron is not caught until a federated check exists.

**Refusal is asymmetric.**

- *New spawn:* if `registry_session_display` refuses — project without parent,
  renamed-away entity, forged name — the supervisor does not start. rc 78,
  message names the missing link. No slug fallback: an invented name looks
  healthy and hides the register fault. Exception: a row with a non-empty
  `RC_LABEL` starts with it — dual-read during migration.
- *Running session:* if derivation starts failing while the session lives,
  it is kept alive on ID, keeps its last applied name, is marked degraded,
  and alarms — journal and a `DRIFT` on the bus. A name fault never
  authorises a kill.

### 3. Rename and migration

**Rename is a state transition.** The supervisor records *last applied
display* per ID in its state directory (`STATE_DIR_NAME`, today
`steward-supervisor`). Each round compares it with
`registry_session_display`. A difference marks the session *rename pending*
— visible in journal and status — and **nothing happens on its own**: a
rename is a restart, and a restart mid-conversation is an intervention. It is
applied at the next natural restart or on an explicit operator verb (its name
is decided in the plan, not here). Application is
the ordinary restart path: stop the ID's pids, spawn with the new display,
resume the thread. **The receipt is local:** the new process alive under the
ID with the new argv, the old pids gone. On failure the old name stands, the
session is marked degraded, and a second session under the new name is never
started.

What the receipt cannot carry: the tile on claude.ai. The vendor's list is
not observable from the machine. Until there is an API, the old tile's
disappearance is a human's eyes; the spec states this as a limit.

**Migration, one row at a time.**

1. The row's target must resolve. Work rows already do — the renderer yields
   `Point→Nudge`, `Varvet→Intrum→Hero` unaided. **Hub rows wait for spec B**:
   they would render bare `Basement`, so they keep `RC_LABEL` until the `Nav`
   project exists.
2. The `RC_LABEL` line is **deleted**, not emptied.
3. Restart goes through the rename transition — it *is* a rename, from legacy
   to rendered.
4. Receipt. Then the next row.

**The empty-label trap is closed by aligning the readers**, not by a new
field. `RC_LABEL=""` means *RC-free*: the supervisor already reads it so
(`:677-681`); `registry_session_display` must read it the same way and feed
only `--name`. An absent line means *rendered*. Two states, two spellings,
one reading everywhere. Legacy precedence is removed only when no row carries
a non-empty `RC_LABEL`. Last step, not an early one.

### 4. Tests and platforms

TDD throughout: a failing test before each change, the suite green after,
and every guard proven by a mutation that makes it fire.

Suites that change:

- `test/identity-schema.test.sh` — the contract gains: supervision never
  matches on display; display may change while ID stands.
- `test/session-rc-label-unique.test.sh` — becomes the (login, project)
  uniqueness suite; RUNTIME-first; OpenCode/Codex exempt.
- `test/supervisor-*.test.sh` — liveness fixtures: a session whose display
  changed between rounds is still found; a stub pgrep that would have matched
  the old label proves the label is no longer consulted.

New tests:

- *Rename pending:* display drift is detected, nothing restarts, status says
  pending; explicit apply restarts once, receipt recorded; a failed apply
  leaves the old name and never spawns a second.
- *Refusal:* an unresolvable target refuses a new spawn (rc 78, names the
  link); the same fault on a running row keeps it alive and alarms.
- *Dual-read:* a row with non-empty `RC_LABEL` starts byte-identical to
  today; `RC_LABEL=""` is RC-free in both readers; an absent line renders.
- *Migration step:* deleting `RC_LABEL` on one row and applying yields the
  rendered name under the same ID; every other row untouched.
- *Portable acceptance for the macOS twin:* the fixtures above expressed
  without Linux-only tools, handed to the butler estate.

## Order of work

1. Identity: supervisor liveness on ID; label pgrep out of decisions.
2. Display: `--remote-control`/`--name` from the registry; RC-free alignment.
3. Rules: uniqueness gate (write + spawn); vestigial LOGIN off non-claude rows.
4. Rename transition + receipt.
5. Migration tooling; migrate one work row; measure; then the rest.
6. Legacy precedence removed when no non-empty `RC_LABEL` remains.

Hub rows and the graph: spec B.

## Out of scope

Spec B (graph, Nav/Steward projects, MANAGED_BY hygiene, infra semantics).
Seat rotation for hubs. Federated uniqueness across estates. A vendor API for
reconciling RC tiles.
