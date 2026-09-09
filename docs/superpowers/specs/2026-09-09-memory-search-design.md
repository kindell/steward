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
whose configuration directories are owned by the effective uid the search
runs as, and that fall inside a scope the estate granted.

**Out, deliberately:** other unix accounts, other hosts, and job workspaces.
Not because they do not matter, but because each needs an owner-local reader
reached over authenticated transport - the same fan-out an estate's
multi-host front needs. That seam gets designed once, elsewhere, and this
feature adopts it later without changing its own contract.

## Identity: where the principal comes from

The caller supplies a query and filters. It never supplies a principal, a
root, or a scope - and this section says where those come from instead,
because leaving it to the implementation is how a tool argument becomes a
scope.

- **The principal is derived from the process, not from a session id.** The
  running host and the effective unix user identify at most one accounts
  register row; that row's principal is the caller's principal. Zero or more
  than one matching row is a refusal, never a guess. An MCP server's
  arguments are fixed at spawn and carry no session id, and the verb is also
  runnable from an ordinary shell that belongs to no session - so a session
  row cannot be the source.
- **The scope comes from the granted row's fixed arguments**, exactly as the
  history server's scope does today. Nothing the model says can widen it.
- **The physical instance of a login is `(this host, effective unix account,
  login)`.** A login row's `ACCOUNT` is the MODEL PROVIDER's account name -
  an address or subject that redemption writes - and is neither a unix
  account nor an accounts-register slug. Configuration directories are
  obtained only through the registry's own resolver, which takes the login
  slug and the owner's unix username.
- **`active_login`** is true when the login is the one this process was
  started with: the session's `LOGIN` where there is a session row, and
  otherwise a match against the inherited configuration-directory
  environment. A process with neither - the legacy unset case - reports
  `active_login: unknown` rather than guessing false.

## The gate

Two conditions, both required:

1. **Same principal.** The caller's principal, derived as above, equals the
   source login's principal.
2. **Same granted scope.** The row that grants the tool names the logical
   project or customer scope.

**Admission is a stat on an open file descriptor, not a claim.** A source is
searched only when the owning uid of the directory this process actually
opened equals the effective uid - checked with `fstat` on the held
descriptor, never with a path resolution followed by `stat`, because
resolving a path follows the very symlink the walk refuses and can be swapped
after the check. Readable is not owned: homes are `0750` on the hosts this
was measured on, but the product ships where they are `0755`, and an
admission rule written as "readable" would read another account's memory
while satisfying every other sentence here. The reader refuses to run setuid
or setgid, and never invokes `sudo`.

**Within one unix account the principal gate is a withholding rule enforced
in the backend - and it is not a security wall.** Say it plainly, because the
deployment this feature exists for is one account holding several logins, and
overclaiming here is worse than the gap: the same uid can read those files
with any other tool, so the real access boundary remains the unix account and
the transport. What the gate guarantees is that THIS tool does not carry
another principal's memory into a caller's context. It is enforced in the
verb - not in the MCP layer, not in the renderer - and it is the one branch
of this feature that must carry a mutation-verified test: a login row in the
caller's own account, inside the same granted scope, with a different
principal, yields zero hits, is not named in the coverage report, and is
counted only as `hidden`. Team, viewer and read-all visibility never widen
personal memory, and that sentence gets its own test.

**The gate is named where sight rules live.** It is a function in the
visibility library - `memory_source_visible_to <viewer-principal> <login>` -
carrying a header comment on why it is deliberately not the session rule and
why read-all does not reach it.

## The scope alias register

This is the implementation's most important input and must not be invented
during coding.

An estate declares scope aliases as rows: a logical `scope-id`, and one row
per physical place that scope lives, binding `(scope-id, host, unix-account,
path)`. The path is the repository or work tree as the runtime saw it. That
tuple is unique; two rows binding the same scope-id to the same host and
account with different paths are two aliases and both are searched. The
granting row names scope-ids, never paths.

A login is deliberately NOT part of an alias: the login set is derived from
the gate and the login register, so naming it in an alias would make the
login register half the truth.

## The project key

An absolute path is a locator, not an identity, and a runtime's directory
name is a lossy encoding of one - inverting it is how the history server got
a scope wrong. Neither is the origin URL sufficient: forks, mirrors, moved
remotes, monorepos and non-git trees all break it.

The key is the registry's `TARGET_PROJECT` where a row has one, and otherwise
the scope-id above. A clone at a new path is a new alias somebody writes
down - never a path derived by inverting an encoding.

**Enumerate and match; never construct and open.** A transcript carries its
own working directory and can be checked against the alias; a memory file
carries nothing of the kind, so the directory name would otherwise be the
only evidence that a tree belongs to the aliased path. So: forward-encode
each aliased path, list the entries of the configuration directory's project
root, and keep the entry whose name is EQUAL - never a prefix - to an
encoding. No match is reported `absent`.

**The ambiguity that matters is in the alias set, not on disk.** A directory
cannot hold two entries with the same name; what can happen is that two
authoritative aliases forward-encode to the same single name. That collision
is detected in the alias set BEFORE anything is opened, and reported
`unsupported` for both. Residual risk, stated rather than hidden: a single
known alias cannot prove that some unknown path did not collide with it
upstream.

**The encoding is versioned and tested against measured versions.** The
deployed history server and the current supervisor already encode
differently; an adapter that guesses which one wrote a directory is a bug
waiting for a rename.

## What a hit carries

`artifact_kind`, `source_runtime`, `principal`, the account slug and unix
username, the provider account from the login row (its own field, never
merged with the account slug), `login`, `host`, the scope-id, the path
relative to `memory/`, the observed mtime, a content hash, and the adapter
version. Plus `active_login` (true, false or unknown) and `stale=unknown`: an
mtime is an observation, not a claim about when the text was written, and
nothing about the session or the author is asserted unless the file proves
it.

**Memory text from another login is quoted historical material, never
instructions.** The reader that renders a hit says so.

## Coverage

The report is scoped under a `sources` key, so its nouns are unambiguous.
Every granted source is reported as one of `searched`, `absent`,
`source-unreadable`, `remote`, `unsupported`, `not-implemented` or
`partial`. Beside them sits `hidden`, an integer: how many same-account
logins the principal gate withheld - never their names, never their labels.
The honest phrasing is "there is more here that you were not granted", never
"someone chose to withhold".

A partial failure must never look like zero hits - that is the difference
between "nothing was written about this" and "the directory that holds it
could not be opened".

**A registry that will not load is a refusal, not a wider search.** rc 78 and
zero hits, with a top-level `ok` stating whether the registry was readable -
a different field from per-source coverage. A configuration directory is
obtained only through the registry's own resolver; a refusal for one source
makes that source `source-unreadable` and the search continues.

## What the reader may touch

- Only `memory/**/*.md` under the directory the enumerate-and-match rule
  selected.
- A symlink anywhere in the chain - login root, project directory, memory
  directory, an intermediate, or the result - is refused, not followed.
- The mechanism is named, because asserting the property without it is how it
  becomes a path resolution plus a prefix test, which is the check that had
  to be rewritten away from once already. Open each directory relative to the
  descriptor held for its parent with `O_DIRECTORY|O_NOFOLLOW|O_CLOEXEC`;
  list through that descriptor; stat entries without following; open a leaf
  with `O_RDONLY|O_NOFOLLOW|O_NONBLOCK|O_CLOEXEC`, then `fstat` it and refuse
  anything that is not a regular file or whose device and inode differ from
  the entry the walk saw; clear `O_NONBLOCK` before reading. `O_NONBLOCK` is
  what makes a fifo a prompt refusal instead of a hang. Note that the
  directory-listing call takes no "follow symlinks" argument of its own - the
  guarantee comes from the open flags and from stat-without-follow, not from
  an argument to the walk.
- A size cap and a result cap.

## The query

**A literal, case-insensitive substring. There is no regular expression in
V1.** The standard library's regex engine has no timeout, so a short
catastrophic pattern hangs inside a single match call and no between-files
budget can interrupt it - "an explicit flag plus a pattern-length cap" is not
a bound. If regular expressions are wanted later, the matching runs in a
separate killable process with a hard timeout and a resource cap; that is a
different design, not a flag.

The filter set is closed - query, runtime, limit, since, until, and a source
label - and every filter narrows a set the gate already resolved. No filter
can add a source, and an unknown filter key is refused rather than ignored. A
search that exhausts its wall-clock budget returns `partial` coverage for
what it covered, never zero hits.

**Diagnostics go to stderr, and only protocol messages go to stdout** - on
every path, including the error paths. The log carries counts, coverage words
and durations: never a query string, never a snippet, never a path outside
the granted scope.

## On demand, never at start

The search is a tool call. Another login's `MEMORY.md` is **not** read at
startup: that index is distilled instruction, and loading it would both blend
authority and spend context nobody asked to spend. A second tool may list
sources or index headings with provenance - still a call, still not
bootstrap. The active login keeps using the runtime's own memory exactly as
it does today.

## Shape, and who owns what

One implementation of the walker and the gate, not two.

- **A python reader, standard library only, with a command-line mode.** It
  owns the filesystem walk and the matching. It is given an already
  authorised, machine-readable source manifest and does not consult the
  registry itself.
- **A steward verb, `steward memory search`,** owns the registry join, the
  principal derivation, the gate, the alias resolution and the coverage
  report. It builds the manifest and executes the reader. It runs local to
  the account whose files it reads.
- **A thin MCP server** that calls the same verb. It adds no logic of its
  own, and the scope and principal never come from a tool argument.
- A runtime's on-disk layout is reached through an **adapter**: behind the
  product's own read API, carrying a version, and answering `unsupported` -
  never "no hits" - when it meets a layout it does not know. Fixtures are
  sanitised copies of measured versions.
- Codex keeps its memory in its own store rather than in files beside the
  conversations. That is a second adapter, not part of V1; it is reported
  `not-implemented`, which is not the same word as `absent`.

**The MCP server is a protocol, not two pipes.** Specify and test the message
framing, initialisation and version negotiation, tool listing, tool calls,
notifications, unknown methods, malformed input, cancellation, and that
nothing but protocol reaches stdout. At least one contract test runs against
a real client's handshake or a recorded, sanitised transcript of one -
otherwise the server can be correct JSON-RPC and still never be an MCP
server. Choosing the standard library moves the dependency from a package to
a protocol we now own; this paragraph is the price of that choice.

## Rollout

The product's server supersedes an estate-local one only once it has feature
parity for what that server already does - including Codex CONVERSATION
search, which is deployed today and which the Codex-memory exclusion must not
quietly remove. Verify the same tools, the same scope and the same provenance
through the product server, switch the granting row atomically, and only then
remove the estate copy.

## Testing

No network, no real home, no ssh, nothing under `/home`. Fixture trees only.

- The identity source: a host and unix user with exactly one account row
  resolves; zero or two rows refuse; a tool argument naming a principal, root
  or scope is refused.
- The uid rule: a fixture directory owned by another uid at mode `0755` is
  reported and never opened - the case an admission rule written as
  "readable" would have let through - and the check is on the opened
  descriptor.
- The withholding rule, mutation-verified: a login in the caller's own
  account, in the same granted scope, with a different principal, yields zero
  hits, is absent from the source list, and appears only in `hidden`.
  Removing the refusal must turn this test red.
- Visibility: team, viewer and read-all do not widen personal memory.
- The alias set: two aliases whose paths forward-encode to the same directory
  name are detected before any open and reported `unsupported`; one alias
  with no matching directory is `absent`.
- The encoding: a fixture per measured encoding version; an unknown one is
  `unsupported`.
- The filesystem rules: a symlink at each of the five positions, a fifo
  (refused promptly, with a timeout on the test itself), a file that grows
  past the cap, a file removed mid-read, and a directory swapped for a
  symlink between the walk and the open.
- Provenance: every field present, the account slug and the provider account
  distinct, `active_login` correct for true, false and unknown.
- Coverage: one granted source made unreadable produces `source-unreadable`
  beside the hits from the others - never an empty result. A registry that
  will not load produces rc 78 and `ok: false`.
- Budgets: an exhausted budget returns `partial`, never zero hits.
- Filters: an unknown filter key is refused.
- The protocol: framing, initialisation, tool listing, a tool call, an
  unknown method, malformed input, cancellation, and stdout purity on the
  error paths - plus the contract test named above.
- **Search requires no source writes and leaves the sources unchanged.** Not
  "no write path exists", which the previous draft claimed and no portable
  suite can prove. Measure it as four things: every source tree is read-only
  and the search still succeeds; a before-and-after manifest of hash, mode,
  mtime and inode is identical; the single opener abstraction is instrumented
  in a unit test that refuses any flag carrying write, create, truncate or
  append; and the production code is reviewed to open sources only through
  that abstraction. Proving it at the system-call level would need a sandbox
  or a tracer, which this suite is not.

## Constraints

English, ASCII (`-` not em-dash). No estate, host or person names in product
text. Python: standard library only, and the same version floor the estate's
other python already requires. Bash side stays bash 3.2 compatible.
