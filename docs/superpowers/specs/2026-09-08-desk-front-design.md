# Desk front - a public door without the tailnet (design, 2026-09-08)

**Status:** approved in conversation by the estate owner 2026-09-08. The
owner's framing: "the whole idea of a VPS was a front on the open net so
we can skip the tailnet - log in with Google or Microsoft, then reach the
Desk." Companion spec: `2026-09-08-desk-services-design.md` (invitation,
first session, add-ons). This spec is about **who you are** when you are
not on the tailnet; that one is about **what you can do** once the Desk
knows.

## What it is

A public hostname (the estate names it) in front of the Desk. A visitor
logs in with an identity provider the estate does not run (OpenID
Connect: Google, Microsoft), and the Desk maps that identity to a
principal exactly as it maps a tailnet login today. The tailnet stays -
for the operator, for the hubs, and as the private wire between the
public box and the host - but a person who is invited never sees it.

The Desk behind the front is the same Desk: same snapshot, same pages,
same order spool. Only the entrance differs.

## Two entrances, one identity function

| entrance | carries identity as | trusted because |
|---|---|---|
| tailnet (today) | `tailscale-user-login` header set by the node | Tailscale Serve strips the client's copy and sets its own |
| front (this spec) | a session cookie issued by the Desk after an OIDC login | the Desk verified the provider's `id_token` itself |

Both resolve through `registry_principal_for_identity <source> <value>`
(`tailscale:<login>` or `oidc:<issuer-slug>:<subject>`). Unknown or
ambiguous identity: 403, no page, no hint - unchanged.

The two entrances are **separate listeners**. The tailnet listener is the
existing unix socket behind Tailscale Serve. The front listener is a TCP
port on the host's tailnet address, reachable only by the public box (see
the next section). A request on the front listener ignores
`tailscale-user-login` entirely; a request on the tailnet socket ignores
cookies entirely. A header cannot walk through the wrong door.

## The public box is a proxy, nothing more

Design decision, changing the estate draft: **the OIDC flow runs in the
Desk, on the host. The public box terminates TLS and forwards bytes.**

Why: a box that signs identity assertions is a box whose compromise mints
any identity. A box that holds the provider client secret can log in as
the application. A box that only forwards TLS to a tailnet address holds
nothing - its compromise gives an attacker a place to stand, not a key.
The client secret lives on the host in a 0600 file under the steward
account; the provider's public keys (JWKS) are fetched by the host
directly over the tailnet's exit or the host's own egress.

What the public box runs: one reverse proxy with automatic certificates
(Caddy or equivalent), `reverse_proxy` to the host's tailnet address on
the front port, and the tailnet client. The proxy forwards
`X-Forwarded-Proto` and the visitor's address as `X-Real-IP`; the Desk
trusts them **only** on the front listener and only when the TCP peer is
the public box's tailnet address. The proxy adds nothing about identity -
the Desk would refuse it anyway.

**The front listener is plain TCP on the host's tailnet address** (a new
knob, `STEWARD_DESK_FRONT_LISTEN=<tailnet-addr>:<port>`, next to the
existing `STEWARD_DESK_LISTEN`), not a `tailscale serve` mount. Measured
on a host 2026-09-08 (tailscale 1.102.3): `serve` has no per-service
hostname, it overwrites `X-Forwarded-For` with the client's tailnet
address, and it sets `tailscale-user-login` to the box's *owner* - three
things the front would have to undo. A TCP listener inside the WireGuard
tunnel needs none of it: the traffic is already encrypted and
peer-authenticated by the tailnet, the Desk reads the peer address
straight from the socket and refuses any peer but the configured box
(`STEWARD_DESK_FRONT_PEER=<box tailnet addr>`), and the Tailscale ACL
lets only the box's tag reach that port. `X-Real-IP` is trusted because
the box is the only thing that can reach the port; per-address rate
limiting keys on it. The listener binds the tailnet address only - never
`0.0.0.0` - and refuses to start when the address is not a CGNAT
(`100.64.0.0/10`) address. Own origin for cookies comes for free: a
different host:port from the tailnet Desk.

mTLS between box and host is not needed in v1 for the same reason. The
box terminates TLS, so it sees the request in cleartext, cookie included
- accepted in v1 and stated in "What a compromised box can do", with the
passthrough alternative there.

## The OIDC login, in the Desk

Node 22 standard library only, like the rest of the Desk.

1. `GET /desk/auth/login?provider=google|microsoft` - only reachable
   through an invitation link or an expired session; sets a short-lived
   state cookie (`__Host-desk-oauth`, HttpOnly, Secure, SameSite=Lax,
   10 min) holding `state` and PKCE verifier, redirects to the provider's
   authorization endpoint with `scope=openid email`.
2. `GET /desk/auth/callback?code&state` - checks the state cookie, redeems
   the code at the token endpoint with the client secret, receives the
   `id_token`.
3. Verifies the `id_token` locally: signature against the provider's JWKS
   (cached, refreshed on unknown `kid`, never trusted from the token
   itself), `iss`, `aud` = our client id, `exp`, `iat` skew under 5 min,
   `nonce` equal to the one sent. Microsoft: `tid` recorded with the
   subject so a personal and a work account with the same email stay
   distinct.
4. Identity = `oidc:<issuer-slug>:<sub>`. Resolves to a principal, or,
   when the request carries an open invitation token, binds to it
   (companion spec). Otherwise 403.
5. Issues the session cookie `__Host-desk-session`: HttpOnly, Secure,
   SameSite=Lax, Path=/, 12 hours, value = `<principal>.<issued>.<hmac>`
   with the HMAC key from a 0600 file the estate generates once. No server
   side session store: the cookie is self-contained and the principal is
   re-resolved on every request, so a removed principal is out on the next
   click, not at expiry.
6. `POST /desk/auth/logout` clears it.

Provider configuration lives in the estate: `desk/providers.d/<slug>.conf`
with `ISSUER`, `CLIENT_ID`, `CLIENT_SECRET_FILE`, `DISCOVERY` (the
`.well-known/openid-configuration` URL). The product ships no client ids.

## Cross-site protection on the front

The Desk v1 rule "no cookie" was a tailnet rule; the front needs one, so
the front listener adds:

- `SameSite=Lax` on every cookie (a cross-site POST never carries it);
- every state-changing request additionally requires `Sec-Fetch-Site:
  same-origin` and the form nonce from the companion spec;
- `Origin` header, when present, must equal the front origin.

The tailnet listener keeps its rules (no cookie, header identity,
`Sec-Fetch-Site`, nonce).

## The rig through the front (noVNC) - step two of this spec

Never a port. A rig is reached only as a WebSocket on the same origin,
after the same identity check.

- `GET /desk/rig/<session>` - the noVNC client, vendored into the product
  (no CDN, no external resource, CSP unchanged except `connect-src 'self'`
  and `script-src 'self'` for this page only). Rendered only for the
  session's **owner**; membership and read-all do not drive another
  person's browser. Operator access to a rig is a later rule, on the
  owner's word.
- `GET /desk/rig/<session>/ws` - WebSocket upgrade, same identity check,
  same owner rule, plus a one-time ticket: the page embeds
  `HMAC(key, principal, session, minute)`; the upgrade must carry it and it
  is valid for 60 seconds. The Desk bridges the WebSocket to the rig's
  VNC endpoint. Framing per RFC 6455 is implemented in the Desk (no
  dependency); binary frames only, no extensions.
- **No password reaches the browser.** The rig's VNC server listens on a
  unix socket, created by the rig at start. The bridge is the only client;
  the browser sees security type `None` because the bridge already is
  inside. Rigs opt in with `BROWSER_VNC_SOCK=yes` on the session row; the
  numeric `BROWSER_VNC` with `-rfbauth` stays for rigs that do not.
- **`-unixsock` alone is a hole.** Measured on a host 2026-09-08 (x11vnc
  0.9.16): `x11vnc -unixsock <sock> -nopw` creates the socket **and keeps
  listening on `0.0.0.0:5900` and `[::]:5905` without a password** - the
  option adds a listener, it does not replace one. The socket mode
  therefore means exactly `x11vnc -unixsock <sock> -rfbport 0 -nopw`
  (`-rfbport 0` measured: no TCP listener, socket kept), and the product's
  rig start refuses to run a socket rig with any other port argument. A
  test asserts the argument vector.
- **The socket directory is per account**, because the rig's account must
  be able to create the socket and the steward account must be able to
  connect: `/run/steward/rig/<account>/` 0710 owned `<account>:steward`
  (a `tmpfiles.d` line per account, written by the onboarding step). The
  socket is created by x11vnc under `umask 007` (0770 - x11vnc takes no
  mode argument; 0770 inside a 0710 directory is enough). The bridge
  enters through the group execute bit and connects.
- The CDP port stays loopback-only and is never bridged. It is the
  session's tool, not a human's.

The rig page is an add-on (companion spec: `request-rig`) - it appears on
`/desk/me` when the session has a rig.

## What a compromised box can do

Stated so the estate can decide what it accepts:

- read and alter traffic in cleartext between the browser and the host,
  including session cookies (12 h) and rig frames, for as long as it is
  compromised;
- it cannot mint an identity (no key), cannot log in as the application
  (no client secret), cannot reach anything on the host but the front
  port (ACL), cannot read the registry, and cannot order anything a
  captured cookie's principal could not order - which, by the companion
  spec, never reaches outside the estate.

Mitigations that are cheap and in v1: automatic OS updates on the box,
the proxy as the only listening service, a dedicated unprivileged account
for the hub's steward to measure the box, rate limiting on
`/desk/auth/*` (10 per minute per address), cookie lifetime 12 h. Later,
if the estate wants the box to see nothing: TLS passthrough (SNI
routing) to the host, which then terminates TLS itself - the same proxy
can do it, and the Desk code does not change.

## Tests

No network, no provider: the tests run a local stub provider in the
fixture (a small Node HTTP server serving a discovery document, a JWKS
with a test key, an authorization endpoint that redirects back with a
code, and a token endpoint that mints an `id_token` signed with that
key). Then:

- a valid login binds to the right principal; a token with a wrong `aud`,
  `iss`, expired `exp`, unknown `kid`, wrong `nonce`, or bad signature is
  refused with 403 and no cookie;
- the front listener ignores `tailscale-user-login`; the tailnet listener
  ignores cookies - a sentinel principal in the wrong carrier must not
  render;
- a removed principal is refused on the next request with a still-valid
  cookie;
- cross-site: a POST without `Sec-Fetch-Site: same-origin`, with a foreign
  `Origin`, or with a stale nonce is refused;
- rig: a ticket for another session or an old minute is refused; a domain
  member and a read-all viewer get 404 on another owner's rig; the bridge
  never forwards before the ticket check; the VNC socket path is derived
  from the session row, never from the request; a socket rig's argument
  vector contains `-rfbport 0` and no `-rfbauth`;
- front listener: refuses a non-CGNAT bind address, refuses a TCP peer
  other than the configured box, ignores `X-Real-IP` from any other peer.
- language and leak guards as for every product change.

## Non-goals

A web terminal; the box hosting anything but the proxy; domain-wide
registration; more than one host behind one front (a later spec when a
second host needs a public door); operator access to other people's
rigs.

## Build order

1. Product: `registry_principal_for_identity`, `OIDC_LOGIN` (shared with
   the companion spec, built once).
2. Product: the front listener, OIDC login and callback, session cookie,
   stub provider tests.
3. Estate: the public box (proxy, tailnet, a tag), the provider
   registrations (client ids and secrets are the operator's hands), the
   front address and port, the HMAC key file. The tailnet ACL is a bigger
   hand than one line when the tailnet runs on the default allow-all
   policy: the first real policy must preserve everything that works
   today, so it is written as a proposal from measured traffic and pasted
   by the operator.
4. Rehearsal: the operator logs in through the front with a provider
   account, redeems a rehearsal invitation, reaches `/desk/me`, is
   offboarded.
5. Product: the rig bridge and the socket-mode rig start (`-unixsock
   <sock> -rfbport 0`); estate: the per-account socket directories;
   rehearsal again with a rig - and a listener sweep (`ss -ltnp`) proving
   no VNC TCP port appeared.
6. The first invited person.
