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
whose configuration directories are OWNED by the effective uid the search runs
as, and that fall inside a scope the estate granted.

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

**Admission is a stat, not a claim.** A source is searched only when
`os.stat(realpath(x)).st_uid == os.geteuid()` holds for the login root, the
project directory AND the memory directory. Readable is not owned: homes are
`0750` on the hosts this was measured on, but the product ships where they are
`0755`, and an admission rule written as "readable" would read another
account's memory while satisfying every other sentence here. The product
already owns the correct test - `registry_login_config_dir` refuses a parent
the running user does not own - and this reader applies the same one. Every
other same-principal source is reported and never opened. The reader refuses
to run setuid or setgid, and never invokes `sudo`.

**Within one unix account, the principal gate IS the boundary - so it is a
hard refusal, not a rendering rule.** This feature exists for the deployment
where one account holds several logins, and the registry already carries
`(PRINCIPAL, CONFIG_DIR)` pairs that share an account. Once the uid rule
above admits a source, nothing else stands between a caller and another
person's memory in that same account. The refusal therefore lives in the
backend verb - not in the MCP layer, not in the renderer - and it is the one
branch of this feature that must carry a mutation-verified test: a login row
in the caller's own account, inside the same granted scope, with a different
`LOGIN_PRINCIPAL`, yields zero hits, is not named in the coverage report, and
is counted only as `hidden`. Team, viewer and read-all visibility never widen
personal memory, and that sentence gets its own test.

**The gate is named where sight rules live.** It is a function in the
visibility library - `memory_source_visible_to <viewer-principal> <login>` -
carrying a header comment on why it is deliberately not the session rule and
why read-all does not reach it. Two rules in one file drift visibly; two
rules in two files do not.

## The project key

An absolute path is a locator, not an identity, and a runtime's directory
name is a lossy encoding of one - inverting it is how the history server got
a scope wrong. Neither is the origin URL sufficient: forks, mirrors, moved
remotes, monorepos and non-git trees all break it.

The key is the registry's `TARGET_PROJECT` where a row has one, and otherwise
an explicit logical scope id. The estate's configuration maps that id to
exact `(host, account, login, path)` aliases, and an alias may name the
encoded directory outright. A clone at a new path is a new alias somebody
writes down - never a path derived by inverting an encoding.

**Enumerate and match; never construct and open.** A transcript carries its
own `cwd` and can be checked against the alias; a memory file carries nothing
of the kind, so the directory name would otherwise be the only evidence that
a tree belongs to the aliased path - the same lossy encoding that produced a
scope leak once already, travelled forwards this time but still
uncorroborated. So: list the entries of `realpath(<config dir>)/projects`,
keep those whose name is EQUAL - never a prefix - to the forward encoding of
the aliased path, and refuse on any count but one. Zero is reported `absent`;
more than one is reported `unsupported`.

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

The report is scoped under a `sources` key, so its nouns are unambiguous.
Every granted source is reported as one of `searched`, `absent`,
`source-unreadable`, `remote`, `unsupported` or `partial`. Beside them sits
`hidden`, an integer: how many same-account logins the principal gate
withheld - never their names, never their labels. The honest phrasing is
"there is more here that you were not granted", never "someone chose to
withhold".

A partial failure must never look like zero hits - that is the difference
between "nothing was written about this" and "the directory that holds it
could not be opened". A search that exhausts its budget is `partial` for what
it covered, by the same reasoning.

**A registry that will not load is a refusal, not a wider search.** rc 78 and
zero hits, with a top-level `ok` stating whether the registry was readable -
a different field from per-source coverage. A configuration directory is
obtained only through the registry's own resolver; rc 78 for one source makes
that source `source-unreadable` and the search continues.

## What the reader may touch

- Only `memory/**/*.md` under the directory the enumerate-and-match rule
  above selected.
- A symlink anywhere in the chain - login root, project directory, memory
  directory, an intermediate, or the result - is refused, not followed.
- The mechanism is named, because asserting the property without it is how it
  becomes `realpath` plus `startswith`, which is the check that had to be
  rewritten away from once already: walk with `os.scandir(follow_symlinks=False)`,
  hold a directory fd per level opened `O_DIRECTORY|O_NOFOLLOW`, open leaves
  relative to that fd with `O_RDONLY|O_NOFOLLOW|O_NONBLOCK`, then `fstat` and
  refuse anything that is not `S_ISREG` or whose `st_dev`/`st_ino` differ from
  the entry the walk saw, then clear `O_NONBLOCK` before reading. `O_NONBLOCK`
  is what makes a fifo a prompt refusal instead of a hang.
- A size cap and a result cap.
- Sibling state is never read: credentials, trust, history, plugins, policy.
- Content is opaque text. Nothing is sourced, executed, parsed as
  configuration, or trusted for its front matter.
- A file that changes or disappears mid-search is reported as omitted, not
  silently dropped.

## On demand, never at start

**The query is a literal, case-insensitive substring.** A regular expression
is available only behind an explicit boolean filter, with a cap on compiled
pattern length, a per-file wall-clock budget and a total budget; exhausting a
budget returns `partial` coverage, never zero hits. The filter set is closed -
query, runtime, limit, since, until, and a source label - and every filter
narrows a set the gate already resolved. No filter can add a source, and an
unknown filter key is refused rather than ignored.

**Diagnostics go to stderr, and only framed JSON-RPC goes to stdout** - on
every path, including the error paths, because on a stdio server stdout is
the protocol. The log carries counts, coverage words and durations: never a
query string, never a snippet, never a path outside the granted scope.

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
- The product's server supersedes any estate-local one. The estate's row
  switches to it in the same rollout, and the estate copy is removed in that
  rollout rather than left running beside it.

## Testing

No network, no real home, no ssh, nothing under `/home`. Fixture trees only.

- The uid rule: a fixture directory owned by another uid at mode `0755` is
  reported and never opened - the case an admission rule written as
  "readable" would have let through.
- The principal gate, mutation-verified: a login in the caller's OWN account,
  in the same granted scope, with a different principal, yields zero hits, is
  absent from the source list, and appears only in `hidden`. Removing the
  refusal must turn this test red.
- Visibility: team, viewer and read-all do not widen personal memory.
- The key: zero matching directories is `absent`, two is `unsupported`, and
  neither is a merge.
- The filesystem rules: a symlink at each of the five positions, a fifo
  (refused promptly, with a timeout on the test itself), a file that grows
  past the cap, a file removed mid-read.
- Provenance: every field present, `active_login` correct for both cases.
- Coverage: one granted source made unreadable produces `source-unreadable`
  beside the hits from the others - never an empty result. A registry that
  will not load produces rc 78 and `ok: false`.
- Budgets: an exhausted budget returns `partial`, never zero hits.
- Filters: an unknown filter key is refused.
- The channel: nothing but framed JSON-RPC reaches stdout, on the error paths
  too.
- Adapter: an unknown layout answers `unsupported`.
- No write path: the fixture memory tree is mode `0500` and the search still
  succeeds, so an attempted write would fail the run rather than pass
  unnoticed.

## Constraints

English, ASCII (`-` not em-dash). No estate, host or person names in product
text. Python: standard library only, and the same version floor the estate's
other python already requires. Bash side stays bash 3.2 compatible.
