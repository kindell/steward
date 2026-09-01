# The job engine — operator guide

A job is a headless agent run with its own clone, its own branch and a row of
machine-owned state, born mid-conversation and never declared in the registry.
This is what an operator needs to start one, watch it and stop it. Sources:
`lib/job{schema,state,git,outbox,reconcile}.sh`, `job-run.sh`, `bin/steward`.

State lives under `$STEWARD_JOB_STATE_HOME`, else
`$HOME/.local/state/<registry-state-dir>/jobs`. Per job id: `row` (the canonical
`KEY=value` state, parsed — never sourced), `journal` (one line per version),
`lease`, `heartbeat`, `outbox/`, `work/` (the job's own clone). The id is
`j-<16 hex>`, opaque and stable across attempts; branches, paths and JSON all
key on it.

## Starting a job

`steward job start` reads the whole submission from the environment and prints
the new id on stdout:

| Variable | Notes |
|---|---|
| `SUBMIT_GOAL` | required — the task |
| `SUBMIT_CHECK_CMD` / `SUBMIT_CHECK_EXPECT` | required — the verifier (run, never judged) and what it must produce |
| `SUBMIT_BRIEF_OBJECTIVE` / `_DELIVERY` / `_TOOLS` / `_BOUNDS` | required — the four brief fields |
| `SUBMIT_REPO` | a git checkout with an `origin` remote; required in practice |
| `SUBMIT_DELIVERY_GLOB` | satisfies the schema instead of `REPO`, but see below |
| `SUBMIT_OWNER` | optional, defaults to `id -un` |
| `SUBMIT_RUNTIME` | optional, defaults to `claude-code` |
| `SUBMIT_PERMISSION_MODE` | optional, closed set: `default`, `acceptEdits`, `bypassPermissions`, `plan`; empty means unset |

The gate refuses (rc 65) and mints nothing when any of the seven named fields is
empty, when neither `SUBMIT_REPO` nor `SUBMIT_DELIVERY_GLOB` is set, or when
`SUBMIT_REPO` is not a git checkout. **Every defect is named in one refusal** —
fix the whole submission and resubmit once. Three more refusals follow the
schema, also rc 65: a `DELIVERY_GLOB`-only submission passes the schema but the
engine refuses it (file delivery is stage-2 work), a `SUBMIT_REPO` with no
`origin` remote is refused by the checkout — a delivery needs somewhere to land
— and a `SUBMIT_PERMISSION_MODE` outside the closed set is refused before
anything is minted, with the whole set named. The run is detached: a mode the
runtime does not know would otherwise fail an id, a clone and a branch that
were already spent.

On acceptance the job gets its **own** clone of the submitter's origin at
`<state>/jobs/<id>/work`, on branch `steward/jobs/<id>/delivery` cut from the
source's HEAD (recorded as `BASE_SHA`); the row is created `DESIRED=run
PROCESS=queued OUTCOME=pending DELIVERY_RECEIPT=pending MESSAGE_RECEIPT=not-sent`;
the runner is launched detached in a tmux session named after the id. If the
spawn fails, `steward job reconcile <id>` picks the job back up.

## The lifecycle

**One attempt slot per `job-run.sh` invocation.** `JOBRUN_MAX_ATTEMPTS`
(default 3): past it the runner sets `SLOTS_EXHAUSTED=1` and exits 65, leaving
the decision to the reconciler.

**Lease + heartbeat.** The runner takes the lease as `job-run:<pid>` with
`JOBRUN_LEASE_TTL` (default 300s); another live holder means exit 75. A tick
every `JOBRUN_HEARTBEAT_SEC` (default 30) touches `heartbeat` *and renews the
same lease*, so an attempt of any length stays "alive"; the lease is released
only if this process still holds it.

**The run.** `claude -p --output-format json` (`JOBRUN_RUNTIME_CMD`) inside the
workdir, prompted with GOAL / OBJECTIVE / DELIVERY / TOOLS / BOUNDS from the row.
A row carrying `PERMISSION_MODE` adds `--permission-mode <value>`; a row without
it adds nothing — the runner never supplies a default of its own, on the first
attempt or on a resume. `RUNTIME=opencode` is refused (exit 65): headless thread
resume is not a measured capability there.

**Exact-thread retry.** Attempt 1 records the runtime's `session_id` as
`RUNTIME_THREAD`; attempt 2+ resumes *that exact thread* (`--resume`) — the
branch is the checkpoint, the thread is the memory. If attempt 1 could not parse
a thread id (`THREAD_PARSE_FAILED=1`, empty `RUNTIME_THREAD`, e.g. no `jq`), the
next attempt refuses to start silently fresh (exit 65).

**The wrapper decides nothing terminal.** It records `PROCESS=exited`,
`EXIT_CODE`, `RUNTIME_THREAD`, `THREAD_PARSE_FAILED` through a compare-and-swap
on `VERSION` (one retry on contention; a second failure exits 70 and *preserves
the lease* rather than lying), then drops its lease and drives the reconciler
once. Exit 0 proves neither outcome nor delivery.

**Reconciler order** (one decision per invocation, every write via CAS): terminal
is terminal → `DESIRED=cancel` beats everything → `DEADLINE_ABSOLUTE` passed
(`OUTCOME=timed_out`) → a registered `DELIVERY_SHA` gets its receipt verified →
`SLOTS_EXHAUSTED` (`OUTCOME=abandoned`, worktree preserved) → only then, if the
lease shows no live process, the push/retry path. **Receipt before retry:
delivered work is never redone.** A missing workdir fails as `workdir-missing`
rather than staying silent.

## Delivery

The engine pushes only `refs/heads/steward/jobs/<id>/*` — never `main`, never
tags, never another job's refs — and the push is compare-and-swap:
`--force-with-lease=<ref>:<expected-sha>` with an explicit expectation. Plain
`--force` appears nowhere.

- Refused **and origin unreachable** → rc 69, an outage: the row goes to
  `PROCESS=retry-wait FAIL_REASON=remote-unreachable` and stays non-terminal, so
  a later reconcile delivers the finished work.
- Refused **and origin reachable** → rc 75, a provenance conflict: `OUTCOME=failed
  FAIL_REASON=remote-moved`. Both commits survive for a human.
- Crash between push and registration: the reconciler sees the remote tip equal to
  the local one, registers it as `DELIVERY_SHA` and verifies.

The receipt checks the **exact** remote tip, not merely that the branch exists:
match → `DELIVERY_RECEIPT=verified OUTCOME=succeeded`; ref absent →
`FAIL_REASON=remote-ref-absent`; ref moved → `FAIL_REASON=remote-moved`.

**Merging is always human.** The engine's whole delivery is that branch on the
remote; nothing in it opens, approves or merges anything.

Terminal notices go through a transactional outbox: event id
`job-<id>-terminal-v<version>`, create-if-absent enqueue, drain via
`$HOME/bin/bus-send` (`JOBOUTBOX_SEND` / `STEWARD_BUS_SEND`) to `hub`
(`JOBOUTBOX_TO`). At-least-once, stated honestly — the receiver dedupes on the
event id — and `MESSAGE_RECEIPT=sent` is written only after a drain delivered it.

## Monitoring

`steward jobs --json` — identity first: every directory under the state home is
listed. Top level: `ok`, `schema`, `measuredAt`, `jobs[]`,
`coverage{listed,measured,unmeasurable}` (a clean sweep vs. one that lost rows).
Each job: `id`, `goal`, `owner`, `desired`, `process`, `outcome`,
`delivery{receipt,sha}`, `attempt`, `heartbeatAgeSec`, `reason`. An unparsable
row still appears, as `{id, reason:"unparsable row"}` — never dropped, never
guessed at. A stale `heartbeatAgeSec` against `process:"running"` is the signal
to reconcile; `steward job reconcile <id>` is safe to run at any time.

## Cancelling

`steward job cancel <id>` writes `DESIRED=cancel` (CAS) and reconciles at once,
setting `OUTCOME=cancelled` and enqueueing the notice. It does not kill the
in-flight process; to stop the attempt now, also kill its tmux session (named
after the job id). If a cancelled job's worktree turns out to hold work past
`BASE_SHA`, the next reconcile records `LATE_DELIVERY=1` rather than pretending
nothing happened.
