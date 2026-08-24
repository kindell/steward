# The OpenCode runtime

Steward supervises agent sessions. Until 2026-08-24 every session was a Claude
Code session and the runtime was implicit — correct by accident, because there
was only one. This document describes the second one, and the contract any
further runtime has to meet.

Nothing here is estate-specific. An estate registers its own sessions and keeps
its own runbook; the mechanism below is the product's half.

## The invariant this was built under

**A Claude session's rendered configuration does not change.** The dispatch is a
`case` around the existing branch, not a rewrite of it. The estate's golden-master
gate compares rendered launchd configuration byte for byte, and it stays green
through this work. If a change here would move a Claude byte, the change is
wrong.

## The runtime set

Five conf fields, validated as a **group** by `registry_validate_runtime_set`. A
half-filled runtime is worse than none: it starts, and then does the wrong thing.

| Field | Meaning | Absent |
|---|---|---|
| `RUNTIME` | `claude-code` or `opencode` | defaults to `claude-code` |
| `MODEL` | provider-qualified model id | required for `opencode` |
| `OPENCODE_VERSION` | pinned build | required for `opencode` |
| `OPENCODE_PORT` | loopback port for the local server | required for `opencode` |
| `AUTO_APPROVE` | `true` maps to OpenCode `--auto` | optional |
| `CLAUDE_MEMORY_ROOT` | source of the memory snapshot | required to snapshot |

**Defaults are the contract, not a convenience.** Every conf that exists in a
running estate predates these fields. A missing `RUNTIME` therefore means Claude,
and status tooling renders it as `claude-code` rather than as unknown — otherwise
a healthy estate reads as unmeasured on the day the field is introduced.

**The model lives in the conf.** Changing model is a registry change plus a
restart, never a code change — the same rule that keeps the remote-control label
in the conf.

## Stable V1, not the beta

The pinned build is OpenCode **V1** (`1.18.14` at the time of writing). Do not
install or invoke the `opencode2` beta for a supervised session: it is a
different CLI surface, and a supervisor that dispatches into it produces a
session that looks supervised and is not.

`OPENCODE_VERSION` is compared **exactly** by the health probe. A health answer
from a different build is not a healthy session; it is a machine that has drifted
from the contract, and the difference matters precisely when nobody is looking.

## State files

The adapter owns one directory — the estate's supervisor state directory — and
writes one file per concern, named after the session:

```
<state>/<session>.opencode-session          the exact OpenCode session id
<state>/<session>.opencode-password         Basic auth password, mode 600
<state>/<session>.opencode.json             generated OpenCode configuration
<state>/<session>.opencode-instructions.md  generated session instructions
<state>/<session>.memory/                   read-only snapshot of Claude memory
<state>/<session>.memory-proposals/         where the session writes proposals
```

None of these belong in a repository. The session id, the password and the
generated configuration are machine state, not source.

## Exact resume, or a new thread

The session id is **persisted and reused**. On start the adapter reads
`<session>.opencode-session`; if it exists, that exact id is resumed in the TUI.
If it does not, a new session is created and its id is written back atomically —
written to a temporary file in the same directory and `mv`-ed into place, so a
crash between the two leaves either the old id or the new one, never half of one.

This is what makes a supervised restart continue a conversation instead of
starting a stranger. A supervisor that restarts a session into a fresh thread has
not restarted it; it has replaced it.

## The memory snapshot, and why it is read-only

An agent that can write into another agent's memory can change what the other one
believes is true. So the source is never handed over as working data:

1. The source tree is hashed.
2. It is copied to `<session>.memory/` with `rsync -a --delete`.
3. The source is hashed **again** and the two hashes must match — a source that
   changed mid-copy yields a snapshot that never existed as a whole, and the
   adapter refuses rather than proceed with it.
4. The snapshot is made read-only (`chmod -R a-w`), and the generated
   configuration additionally denies edits under it.

Durable-memory suggestions go to `<session>.memory-proposals/` as separate
Markdown files, for a human to read and act on. The proposal directory is the
session's only writable memory surface.

## Loopback only, and authenticated anyway

The OpenCode server binds `127.0.0.1` and carries HTTP Basic auth **even there**.
Two layers, because one of them is a configuration line and configuration lines
go wrong. The port must not answer from any other host on the network; an estate
runbook should carry that as an executable check rather than an assurance.

The password is read from its file and sent as an `Authorization` header. It must
never appear in an argument vector, a log line, or a returned object: process
command lines are world-readable on a shared machine, which is the whole reason
credentials moved out of argument lists in the first place.

A probe that cannot be made — missing password file, timeout, malformed body — is
**unknown**, never healthy and never unhealthy. A broken measuring instrument and
a broken session must not look the same.

## Refusals

The adapter refuses loudly rather than starting something half-configured:

- missing adapter, before any tmux session is created
- unknown runtime, refused by the registry
- an incomplete runtime set
- a memory source that changed while it was being copied
- a server that does not report healthy on its pinned version

A session that starts without its configuration answers willingly and returns
nothing useful, which reads as "no results" rather than "broken". That failure
mode is the one every refusal above exists to prevent.

## Operating a session

Generic commands; substitute your estate and session names:

```bash
steward <estate> attach <session>     # take over the TUI
steward <estate> peek <session>       # snapshot the screen without attaching
steward <estate> status               # runtime and model per session
```

`attach`, `peek`, `send` and `restart` remain tmux operations and are identical
across runtimes. Only the launch differs.

## Adding a third runtime

Add a branch to the supervisor's `case`, a validation group to the registry, and
a status column value. Do not add a second dispatch path: the reason this one is
a `case` and not a parallel script is that two launch paths drift, and the drift
is invisible until a session starts wrong.
