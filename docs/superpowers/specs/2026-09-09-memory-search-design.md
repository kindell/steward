# Memory search: one person's logins can read each other's memory

**Status:** design, ready for implementation
**Builds on:** the deployed cross-runtime history server (an estate's read-only
MCP over Claude Code and Codex conversation files) and the identity and
register design that gives a login its principal, account and configuration
directory.

## Why

A runtime keeps its memory under the configuration directory it was started
with. One person with two model accounts therefore has two disjoint memories
of the same work in the same repository, and neither runtime asks the other.

Measured on a live host: a project directory under one login holds 36 memory
files; the same project under that person's second login holds an empty
`memory/`. Switching login is total amnesia for that project - for the same
human, in the same tree, on the same machine.

The estate's history server already proved the shape this wants: read only,
scope granted by a row rather than by code, and every hit says which runtime
it came from. This spec takes that shape into the product and adds one axis -
the same person's other logins - and one source - the memory directory beside
the conversations.

## Scope of V1

**In:** memory belonging to logins whose principal is the caller's principal,
whose configuration directories are readable by the unix account the search
runs as, and that fall inside a scope the estate granted.

**Out, deliberately:** other unix accounts, other hosts, and job workspaces.
Not because they do not matter, but because each needs an owner-local reader
reached over authenticated transport - the same fan-out the estate's
multi-host front needs. That seam gets designed once, elsewhere, and this
feature adopts it later without changing its own contract.

## The gate

Two conditions, both required:

1. **Same principal.** The caller's `ROW_PRINCIPAL` (derived by the registry
   from the session's `ACCOUNT`, not read from a conf) equals the source
   login's `LOGIN_PRINCIPAL`. A login's configuration directory is always
   resolved through its own `ACCOUNT` - never against the principal's name,
   and never against the calling process's `HOME`.
2. **Same granted scope.** The row that grants the tool names the logical
   project or customer scope, exactly as the history server's row does today.
   A session never states its own scope, so it cannot widen it.

The caller supplies a query and filters. It never supplies a principal, a
root, or a scope.

**Principal equality is a rendering rule, not access control.** The real
boundary is the unix account and the transport. A local reader must not read
another account's home, whatever the register says about principals; a
same-principal source it cannot read is reported, not read. Team, viewer or
read-all visibility rules must never widen personal memory.

## The project key

An absolute path is a locator, not an identity, and a runtime's directory
name is a lossy encoding of one - inverting it is how the history server got
a scope wrong. Neither is the origin URL sufficient: forks, mirrors, moved
remotes, monorepos and non-git trees all break it.

The key is the registry's `TARGET_PROJECT` where a row has one, and otherwise
an explicit logical scope id. The estate's configuration maps that id to
exact `(host, account, login, path)` aliases. A clone at a new path is a new
alias somebody writes down - never a path derived by inverting an encoding.

## What a hit carries

A login label alone is too thin - a memory written under one account may
assume things another must not. Every hit carries:

`artifact_kind`, `source_runtime`, `principal`, `login`, `host`, the logical
scope id, the path relative to `memory/`, the observed mtime, a content hash,
and the adapter version. Plus `active_login` (true or false) and
`stale=unknown`: an mtime is an observation, not a claim about when the text
was written, and nothing about the session or the author is asserted unless
the file proves it.

**Memory text from another login is quoted historical material, never
instructions.** The reader that renders a hit says so.

## Coverage

Every granted source is reported as one of `searched`, `absent`,
`unreadable`, `remote` or `unsupported`. A partial failure must never look
like zero hits - that is the difference between "nothing was written about
this" and "the directory that holds it could not be opened".

## What the reader may touch

- Pinned to `realpath(<config dir>)/projects/<exact authoritative encoding>/memory`,
  and only `memory/**/*.md`.
- A symlink anywhere in that chain - login root, project directory, memory
  directory, an intermediate, or the result - is refused, not followed.
- Only regular files are opened, with a size cap and a result cap, without
  following symlinks; after opening, the file is confirmed still regular and
  still under the root.
- Sibling state is never read: credentials, trust, history, plugins, policy.
- Content is opaque text. Nothing is sourced, executed, parsed as
  configuration, or trusted for its front matter.
- A file that changes or disappears mid-search is reported as omitted, not
  silently dropped.

## On demand, never at start

The search is a tool call. Another login's `MEMORY.md` is **not** read at
startup: that index is distilled instruction, and loading it would both blend
authority and spend context nobody asked to spend. A second tool may list
sources or index headings with provenance - still a call, still not
bootstrap. The active login keeps using the runtime's own memory exactly as
it does today.

## Shape

- A read-only backend verb, `steward memory search`, owning the registry
  join, the gate, the coverage report and the adapter contract. It runs local
  to the account whose files it reads.
- An MCP server in front of it, in **python, standard library only**. MCP
  over stdio is JSON-RPC on two pipes; hand-writing it removes a per-home
  `pip install` that lives outside the deploy path and would otherwise leave
  the server silently dead in any home where somebody skipped it.
- A runtime's on-disk layout is reached through an **adapter**: located
  behind the product's own read API, carrying a version, and answering
  `unsupported` - never "no hits" - when it meets a layout it does not know.
  Fixtures are sanitised copies of measured versions.
- Codex keeps its memory in its own store rather than in files beside the
  conversations. That is a second adapter, not part of V1, and it stays
  unmeasured until someone measures it.

## Testing

No network, no real home, no ssh, nothing under `/home`. Fixture trees only.

- The gate: a login with a different principal is not searched; a login whose
  configuration directory is unreadable is reported `unreadable`, not read; a
  caller cannot pass a principal, root or scope.
- The key: two trees that encode to the same directory name are reported
  ambiguous and refused rather than merged.
- The filesystem rules: a symlink at each of the five positions, a fifo, a
  file that grows past the cap, a file removed mid-read.
- Provenance: every field present, `active_login` correct for both cases.
- Coverage: one granted source made unreadable produces `unreadable` beside
  the hits from the others - never an empty result.
- Adapter: an unknown layout answers `unsupported`.
- No write path exists: the suite asserts the reader opens nothing for
  writing anywhere under a configuration directory.

## Constraints

English, ASCII (`-` not em-dash). No estate, host or person names in product
text. Python: standard library only, and the same version floor the estate's
other python already requires. Bash side stays bash 3.2 compatible.
