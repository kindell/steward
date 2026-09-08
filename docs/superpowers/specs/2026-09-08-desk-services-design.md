# Desk services - invitation, first session, add-ons (design, 2026-09-08)

**Status:** approved in conversation by the estate owner 2026-09-08 (closed
registration: the invitation is the door). Supersedes the estate
onboarding draft of the same day as far as the product is concerned.
Companion spec: `2026-09-08-desk-front-design.md` (the public door). This
spec does not depend on the front - everything here is measured over the
tailnet first and works unchanged behind the front later.

## The measurement that starts it

A new person's first hour on a host: six stumbles, all in the terminal
(ssh key on the wrong forge account, shared tailnet node with another
address, a browser link that cannot be opened on a server, the agent's
one-time bypass warning stopping the workplace, the wrong provider account
chosen in the browser, a missing unix group for the rig). None of them had
anything to do with the work. Afterwards the person used only the agent's
own app, the Desk and a VNC client - never a terminal.

## Minimal viable onboarding

A person needs exactly three things to have a first session:

1. an identity the Desk trusts, bound to a principal row;
2. their own model subscription logged in inside their own account on the
   host;
3. one session that runs.

Everything else - forge access, a browser rig, extra runtimes, more
sessions, more team memberships - is an **add-on** the person or the
operator adds later from the same Desk page. Onboarding is therefore not a
subsystem of its own: it is the first add-on, and it is mandatory.

What the person sees, in order:

1. They open the Desk through an invitation link, log in with an identity
   provider, and land on **their page**.
2. The page shows one thing: *Log in to Claude* (or the runtime the
   invitation names). One button, one provider link, one green check.
3. The hub starts the session. The page shows *Your session is running -
   say hello* with the link to the agent's app.
4. Below that, the add-on list.

Two clicks for the human. Target: under three minutes from link to hello.

## Registry

### `invites.d/<id>.conf` - new category

An invitation is the operator's word, recorded before the person exists.
`<id>` is a random slug (`inv-` + 8 hex). Keys:

| key | meaning |
|---|---|
| `NAME` | display name of the invited person |
| `PRINCIPAL` | the principal slug that redemption will create; must not exist yet |
| `ENTITY` | the entity the person becomes a `MEMBERS` of on redemption |
| `HOST` | the host the account and the first session live on |
| `RUNTIME` | runtime of the first session (`claude-code` in v1; the value is validated against the runtime list) |
| `PROVIDER` | login provider of the first session (`claude-max` or `claude-team` in v1) |
| `TOKEN_SHA256` | hex digest of the one-time link token; the token itself is printed once at issue and never stored |
| `ISSUED_BY` | principal of the operator who issued it |
| `ISSUED_AT`, `EXPIRES_AT` | epoch seconds; default validity 7 days |
| `STATE` | `open`, `redeemed`, `revoked`, `expired` |
| `REDEEMED_LOGIN`, `REDEEMED_AT` | set on redemption: the identity that was bound (`<source>:<value>`) and when |

The token is 32 bytes from `/dev/urandom`, base64url. The link is
`<desk-origin>/desk/invite/<token>`. The row stores only the digest, so a
readable registry does not leak an open door.

### `principals.d` - a second identity source

`TAILSCALE_LOGIN` stays. New key `OIDC_LOGIN`: a space-separated list of
`<issuer-slug>:<subject>` words (for example `google:1093...`,
`microsoft:0000-...`). The subject, not the email, is the key - an email
can change, a subject cannot. A display email may be kept as
`OIDC_EMAIL` (informational, never used for lookup). Uniqueness is the
same rule as for `TAILSCALE_LOGIN`: every word is unique across all rows,
enforced at write time and again at read time.

`registry_principal_for_login` becomes `registry_principal_for_identity
<source> <value>` with `<source>` in `tailscale|oidc`; the old name stays as
a wrapper for `tailscale`. Same return codes: 0 one row, 1 none, 65
ambiguous.

### Sessions, accounts, logins - unchanged shape

Redemption writes ordinary rows with the existing verbs (`registry
account add`, `registry principal add`, `registry login add`, `registry
session add`). No new session keys. The first session's slug defaults to
`<entity>-<principal>`.

## Verbs

All verbs are idempotent, print one receipt line per step, and are safe to
re-run. Each is a `case` arm in `bin/steward` next to the existing ones.

### `steward invite issue --name <n> --principal <slug> --entity <e> --host <h> [--runtime r] [--provider p] [--days 7] [--json]`

Writes the row, prints the link **once** on stdout. Refuses (rc 65) when
the principal exists, the entity or host does not, or an `open` invite for
the same principal already exists (print its id instead).

### `steward invite ls [--json]`, `steward invite revoke <id>`

Listing never shows tokens (there are none to show). Revoke sets
`STATE=revoked`; an expired invite is reported as `expired` at read time
without a write.

### `steward invite redeem <token> --identity <source>:<value> [--email e] [--json]`

Called by the Desk apply step (below), never by the person. Steps, each a
receipt, in this order:

1. digest the token, find the row; refuse (rc 65) unless `STATE=open` and
   not expired; refuse if `<identity>` already maps to a principal;
2. `registry principal add --name --oidc-login <source:value>` (or
   `--tailscale-login` for a tailnet redemption);
3. unix account on `HOST` via the privileged helper (below);
4. `registry account add --principal --host`;
5. `MEMBERS` of `ENTITY` gets the principal;
6. `registry login add --principal --account --provider --config-dir
   <home>/.claude-logins/<provider> --legal-owner <principal>`;
7. `registry session add --account --login --entity --slug` with
   `RUNTIME` from the row;
8. relay key + relay row + delivery key (the same steps the bus enrolment
   already performs);
9. deploy of the skeleton to the new home; desk snapshot;
10. row `STATE=redeemed`, `REDEEMED_LOGIN`, `REDEEMED_AT`.

A step that fails leaves the earlier receipts in place and exits non-zero;
re-running continues from the first step that has not left its mark. The
session is **not** started here - it cannot run before the model login
exists.

### `steward offboard <principal> [--keep-home]`

The exact reverse: stop sessions, remove relay rows and delivery keys,
remove registry rows (session, login, account, MEMBERS entry, principal;
the invite row stays as history with `STATE=redeemed`), lock the unix
account, archive the home to `/home/.offboarded/<account>-<date>` (deleted
only on the operator's word, never by the verb), desk snapshot. Prints one
line per thing removed - this list is what makes a rehearsal cleanable.

### The privileged helper

Account creation needs root; the hub runs as the steward account. Product
ships `linux/steward-account-helper` (root-owned, 0755) with two
sub-commands: `add <username>` (useradd, home 750, groups `video render`,
locked password, `loginctl enable-linger`) and `lock <username>`. It
validates its argument shape itself (`^[a-z][a-z0-9-]{1,31}$`), takes no
other input, and is the only thing the sudoers line allows:
`steward ALL=(root) NOPASSWD: /usr/local/sbin/steward-account-helper`.
The estate installs the line; the product documents it and refuses with a
clear message when `sudo -n` cannot run the helper.

## Desk: from reading to ordering

Desk v1 is a pure renderer: no JavaScript, no cookie, nothing written. This
spec keeps that property for the page and adds **one** write path.

### The order spool

A button is a `<form method="post">`. The server validates the request and
appends one file to `~/.local/state/<name>/desk/orders/<ulid>.json`:

```json
{"id":"01J...","principal":"alice","action":"claude-login",
 "args":{"session":"s-..."},"at":1757340000,"origin":"tailnet"}
```

Nothing else is written by the server, ever. The spool directory is 0700
to the steward account.

Validation before the append, all of them, in this order:

- method POST, `Content-Type: application/x-www-form-urlencoded`, body
  under 4 KiB;
- `Sec-Fetch-Site: same-origin` (or `none` is refused; a browser that does
  not send the header is refused - Desk requires a current browser);
- a form nonce that matches the current snapshot generation for this
  principal (the nonce is `HMAC(generation-secret, principal, generation)`
  and is rendered into every form; a stale page cannot order);
- the action is in the allowlist and its args refer to objects the viewer
  is allowed to act on (owner only - membership and read-all give
  reading, never ordering);
- at most one open order per (principal, action); otherwise 409.

### `steward desk apply`

A systemd path unit on the spool directory runs `steward desk apply` in
the steward account. It processes orders oldest first, writes
`<id>.receipt.json` (`state`: `running|done|failed`, `at`, `lines`: the
verb's receipt lines, `link`: an optional provider link for the page),
and triggers a snapshot after each. The snapshot carries each principal's
own orders and receipts (filtered like everything else), so the page shows
*queued / running / done / failed* and the receipt lines without the
server reading the spool.

Provider links (the model login URL, the forge device code) are
**one-time links from the provider**; they are shown on the page and
expire on their own. No token, secret or credential ever enters a receipt.
The apply step scrubs the verb's output through the same secret guard the
bus uses before writing it.

### Actions in v1

| action | who | what apply runs |
|---|---|---|
| `claude-login` | owner | `steward login <session>` in the person's account, non-interactive: capture the login URL, put it in `link`. Green when the credential file exists in the login row's `CONFIG_DIR` **and** its account matches the row (see measurements). |
| `start-session` | apply itself | after `claude-login` turns green: enable the session's supervisor unit. Never a button. |
| `forge-login` | owner | `gh auth login --git-protocol ssh --device` in the person's account; `link` = the device URL and code. Then the forge's public keys are appended to the account's `authorized_keys` (the step that was manual today). |
| `request-rig` | owner requests, operator grants | a request order lands on the read-all principal's page as *pending*; the operator's click turns it into a grant order; apply assigns the next free display/CDP/VNC numbers from the host's range and writes the `BROWSER_*` keys. |
| `request-session` | owner requests, operator grants | same shape; args: entity or project, runtime. |

An action whose runtime has no login recipe (today: `codex`,
`opencode-chatgpt`) is **not rendered** - the add-on list is derived from
`_REGISTRY_LOGIN_PROVIDERS` filtered by "has a recipe in `steward
login`". Adding a runtime later means adding its recipe, nothing on the
page.

Self-service versus the operator's word, the rule: an action that touches
only the person's own accounts and own home (model login, forge login) is
self-service and reversible. An action that consumes a shared resource or
reaches another entity (a rig, another session, a membership) is a
request that the operator grants with their own authenticated click. What
reaches outside the estate (mail, money, deletion of the irreplaceable) is
never a button.

### The pages

- `/desk/` - unchanged, plus a banner while the first session is not yet
  running.
- `/desk/me` - the person's page: the mandatory step, the running session
  with its app link, the add-on list with state and buttons, their own
  orders and receipts.
- `/desk/invite/<token>` - the only page a stranger can reach. With a valid
  token and an identity in the request: bind and redirect to `/desk/me`.
  With a valid token and no identity: the front's login (companion spec)
  or, over the tailnet, a 403 - the tailnet always carries an identity.
  With an invalid, used or expired token: the same 404 as an unknown path.
- `/desk/admin/invites` - read-all only: open invitations (id, name,
  entity, expiry, never the token), pending requests with grant buttons,
  redeemed history.

Rendering rules from the Desk v1 spec apply unchanged (allowlist,
escaping, headers, no external resources). The only new markup is forms.

## Measurements before the code

1. **Where the agent persists the bypass acceptance.** The trust dialog is
   already seeded (`ensure_workspace_trusted`); the one-time
   bypass-permissions acceptance is not handled anywhere in the product.
   Find the key and file it lands in, cite it in the supervisor next to
   the trust seed, and seed it the same way. Never guess the key.
2. **Which account a credential file belongs to.** `claude-login` must
   turn green only for the intended account. Measure what the credential
   file and `claude auth status` (or equivalent) expose; the check
   compares against the login row, never against a name typed on a page.
3. **`steward login` non-interactive.** Today it `exec`s the interactive
   login in the session's home. The apply step needs the URL captured and
   the process left waiting for the browser step. Measure how the CLI
   behaves with stdin closed and stdout piped; if it needs a pty, run it
   in the session's tmux server and scrape the URL from the pane.
4. **`sudo -n` and the helper** on the target host.

## Tests

Every verb and every Desk path is covered by `test/*.test.sh` fixtures:
a temporary estate root, stub `sudo`, stub `gh`, stub `claude` printing a
fake login URL, no network, no systemd. In particular:

- invite: issue prints the link once; the row holds only the digest; a
  wrong, used, expired or revoked token gives the same 404 body as an
  unknown path; redeem is resumable after a failed step; redeem refuses an
  identity that already has a principal.
- principals: `OIDC_LOGIN` uniqueness across rows, at write and at read;
  the `tailscale` wrapper unchanged.
- order spool: every validation in the list above has a refusing test;
  a domain member or read-all viewer cannot order on another's session;
  a stale nonce is refused; the server writes exactly one file and nothing
  else (sentinel directory listing before and after).
- apply: receipts scrubbed through the secret guard (a stub verb prints a
  fake token; the receipt must not contain it); `start-session` only after
  a green login; a failed order does not block later ones.
- offboard: the receipt lists every row and key that redeem created, and
  a second run is a no-op.
- language and leak guards as for every product change.

## Non-goals

A web terminal (convenience, not a door - its own spec if ever), several
hosts per invitation, domain-wide automatic registration (invitation is
the only door in v1; a per-entity domain rule may come later as an add-on
to the entity row), self-service for shared resources, any action that
reaches outside the estate.

## Build order

1. Product: `OIDC_LOGIN` + `registry_principal_for_identity`; `invites.d`
   with issue/ls/revoke; tests.
2. Product: measurements 1-4; the privileged helper; `invite redeem` and
   `offboard`.
3. Product: the order spool and `steward desk apply` with `claude-login`,
   `start-session`, `forge-login`; `/desk/me`; `/desk/invite/<token>`.
4. Product: requests and grants (`request-rig`, `request-session`),
   `/desk/admin/invites`.
5. Estate: sudoers line, path unit, a rehearsal principal redeemed over the
   tailnet and offboarded; time from link to hello measured.
6. The first real person, through the front (companion spec).
