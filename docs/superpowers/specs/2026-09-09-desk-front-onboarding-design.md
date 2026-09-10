# Desk front: the first meeting, and where the desk is mounted

**Status:** design, ready for implementation
**Follows:** `2026-09-08-desk-front-design.md` (the public front), `2026-09-08-desk-services-design.md` (identity, invitations, the principal registry)

Two changes to the public front, taken together because they touch the same
files and because both are worth exactly one redeployment and one round of
provider-console edits.

## Why

The front went live and the first real person signed in through a real
provider. Two things the design got wrong showed up in the same minute.

**The refusal says nothing a person can act on.** An identity a provider
vouched for, that no principal row binds, gets `No desk for this login.` and
a 403. The operator gets a journal line naming the identity; the person in
front of the browser gets a dead end and no way to become known. Every route
into this desk begins here, so this page IS the onboarding, and it currently
tells nobody anything.

**The path repeats the host.** A desk with its own hostname serves
`https://<host>/desk/`. The prefix exists because a desk may be mounted
beside other things on a shared host; when the estate gives it a hostname of
its own, the prefix is repetition in every link and every address bar.

## Change A: the unbound-identity page

### The rule this must not break

`authCallback`'s refusals are deliberately uniform: a missing state cookie, a
tampered state, a failed code exchange and an invalid token all produce one
body, so the endpoint is not an oracle. That reasoning holds for every
refusal reachable **without proving an identity**, and those stay exactly as
they are, byte for byte.

This one refusal is different in kind. To reach it a visitor has completed a
real sign-in at a real provider and the desk has verified the resulting
token. The only thing such a page can tell them is something about
themselves. It may therefore speak.

### What it says

A page, not a sentence:

```
Signed in, but not yet known here

Your sign-in worked. This desk has no row for you yet, so there is
nothing to show.

Give this reference to whoever runs this desk:

    <identity>

When they have added you, sign in again.          [Sign in again]
```

- `<identity>` is the exact string that belongs in an `OIDC_LOGIN` row,
  provider prefix included (`google:1071...`), so the operator pastes rather
  than transcribes. It is the same string the journal line already carries.
- Nothing else about the person is shown: no email, no name, no claim, no
  token. Same rule the journal line was given.
- "Sign in again" links to the login route.
- Status stays **403**. The status must not lie: this is a refusal.
- No session cookie is set. The state cookie is cleared. Both unchanged.
- The journal line is unchanged.

### Where the contact comes from

The product must not carry an estate's name. A new **optional** estate key,
`DESK_CONTACT` in `estate/steward.conf`, carries free text - an address, a
channel, a sentence. It reaches the front through `desk/bin/desk-paths` the
way `DESK_ORIGIN` and `DESK_SESSION_KEY_FILE` already do.

- Set: the page reads `Send it to <contact>.` in place of the generic line.
- Absent: the generic line stands. The front starts either way - this key
  never blocks a start, unlike the three required ones.
- Free text as to MEANING, not as to SHAPE: the estate knows how it is
  reached, but the bridge that carries the value does not accept anything.
  Accepted is `^[[:print:]]{1,200}$` - one line, printable ASCII, no control
  characters. Anything else is refused at start with the same rc 78 shape as
  the other conf refusals, naming the key. A cap alone is not the rule: a
  conf key is not a place to store a page, and it is not a place to store a
  second line either.
- It is escaped as text and never rendered as a link, so a stray `<` or a
  pasted URL cannot become markup or a redirect.

#### Why the shape is part of the contract, not a nicety

`desk/bin/desk-paths` is a LINE-ORIENTED `key=value` bridge and
`desk/serve.mjs:196-199` reads it with `found[m[1]] = m[2]` - **the last
line for a key wins**. A value carrying a newline therefore does not corrupt
its own line; it writes a NEW one. A `DESK_CONTACT` of

```
someone@example.invalid
origin=https://elsewhere.example
```

emits a second `origin=` line after the real one, and the front starts on
the second. `DESK_ORIGIN` is the OAuth redirect URI and the cookie origin,
so the login flow would be aimed elsewhere.

**Severity, stated honestly:** this is not a privilege escalation. Whoever
can write `DESK_CONTACT` can already write `DESK_ORIGIN` in the same file.
What it is, is a contract hole: one key's free text can silently change a
DIFFERENT key's value, and last-wins parsing makes the change invisible -
no error, no journal line, a desk running on an origin nobody typed. The
realistic path is a careless paste of a multi-line signature, not an
attacker.

Measured on bash 3.2 / macOS while writing this: `[[ $v =~ ^.{1,200}$ ]]`
ACCEPTS a value containing a newline; `^[[:print:]]{1,200}$` refuses it. A
length-only rule would therefore have shipped the hole. (Wanted: the same
two measurements on bash 5 / Linux before implementation - the regex engine
is not the same one.)

#### Two structural fixes this key must not be alone in carrying

The new key exposed the hole; it is not the only key that could reach it,
and the sixth key will not remember this section.

1. **`desk-paths` refuses to print any value containing a control
   character** - every key, current and future, checked in `front_value`
   itself rather than in each caller's regex. rc 78, naming the key.
2. **`serve.mjs` refuses a duplicate key instead of preferring one.** Two
   `origin=` lines are evidence the bridge produced something nobody
   intended; silently keeping either is how the hole stays invisible. Exit
   78, naming the repeated key.

Both are the same lesson the credential seam learned from its own column 6:
a guard that only covers the fields that look dangerous covers the wrong
set.

### The same page for the same condition elsewhere

`handleFront`'s own `!slug` branch - a returning visitor holding a valid
session cookie whose row has since been removed - is the same condition with
the same proof of identity. It gets the same page. Both sites clear the
session cookie as they do today.

The terse `FORBIDDEN` body stays for the refusals that must not distinguish
themselves: an unknown session id, a session outside the viewer's view, an
unknown route.

### Untrusted text on the page

The identity comes from the provider. It is escaped for HTML, and
non-printable characters are removed the same way the journal line already
escapes them. An identity longer than 256 characters is not rendered at all:
that page falls back to today's terse body, so a hostile discovery document
cannot use this page as a canvas.

### What comes next, and what the layout must leave room for

`invites.d` and `steward invite redeem` already exist. The next step in
onboarding is that a person holding an invitation does not contact anybody:
this page grows a field, the token binds the identity, and the desk opens.
Build the page so that field can be added without redrawing it. Do not build
the field now.

## Change B: the mount path

`DESK_PREFIX`, an optional estate key, default `/desk` - so every deployment
that exists today is byte-identical after this change.

- Accepted: the empty string, or a string that starts with `/`, does not end
  with `/`, and contains only unreserved path characters. Anything else is
  refused at start, rc 78, naming the key - the same shape as the other conf
  refusals.
- Every route, every redirect location, every rendered href and the OAuth
  redirect URI derive from one exported constant. There are thirteen literal
  `/desk...` strings in `desk/serve.mjs` and five href builders in
  `desk/render.mjs` today; none may remain literal.
- Cookies are unaffected: `serializeCookie` pins `Path=/` because the
  `__Host-` prefix requires it, and that must stay true at every prefix. A
  test asserts it.

### The operator's half

The provider's redirect URI is `<DESK_ORIGIN><DESK_PREFIX>/auth/callback`.
Changing the prefix means re-registering that URI in every provider console
the estate uses. `desk/SCHEMA.md` says so beside the key, in the same
sentence that names the default - an operator who reads only that line must
still learn the cost.

## Testing

The front's suites already run without network against a stub provider; every
test here does the same. Specifically required:

- The unbound page: status, body, the identity rendered exactly, no session
  cookie, state cookie cleared, and the journal line unchanged - mutation-
  verified, as the existing unbound-identity test already is.
- A bound identity still logs in and sees no such page.
- The protocol refusals (no state cookie, bad state, failed exchange, invalid
  token) remain byte-identical to their current bodies. This is the test that
  proves the oracle argument still holds.
- `DESK_CONTACT` present, absent, over the cap, and carrying `<`, `"` and a
  URL.
- `DESK_CONTACT` carrying a newline followed by `origin=https://elsewhere.example`:
  the front refuses at start with rc 78 naming the key, and - asserted
  separately, because the two failures are different - it does NOT start on
  the injected origin. A test that only checks the rc would still pass if the
  refusal moved to a later guard that let the origin through first.
- `DESK_CONTACT` carrying a bare control character (no newline): refused. The
  rule is the character class, not the line count.
- The two structural fixes get their own tests, independent of this key:
  `desk-paths` refusing a control character in `DESK_ORIGIN` and in
  `DESK_SESSION_KEY_FILE`, and `serve.mjs` exiting 78 on a bridge output
  carrying two `origin=` lines. Both must be watched failing against today's
  code first - they are the proof that the fix is structural and not a
  restatement of the `DESK_CONTACT` rule.
- An identity carrying a control character, and one over 256 characters.
- `DESK_PREFIX`: default, empty, a custom value, and each refused form. With
  the default, the rendered pages and the route table are unchanged from
  before this change - assert that against the current strings, not against a
  regenerated expectation.
- Cookies carry `Path=/` at every prefix.

## Constraints

English, ASCII (`-` not em-dash). No estate, host or person names in product
text. No network in tests. No test-only knobs in production code. The front
runs on Node's standard library only.
