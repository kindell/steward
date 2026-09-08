# Desk Front (listener, OIDC login, session cookie) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A second Desk listener on the host's tailnet address that a public proxy box forwards to, where a visitor logs in with an OpenID Connect provider and the Desk itself verifies the token and issues a self-contained session cookie.

**Architecture:** `desk/serve.mjs` keeps its tailnet listener untouched and gains a second `http.Server` when `STEWARD_DESK_FRONT_LISTEN` is set. Three new stdlib-only modules carry the front's logic: `desk/front.mjs` (listen address and peer rules), `desk/cookie.mjs` (cookie parsing and the HMAC session), `desk/oidc.mjs` (providers, discovery, PKCE, code exchange, `id_token` verification). Identity on the front is the cookie and nothing else; identity on the tailnet is the header and nothing else. Two bash bridges (`desk/bin/desk-paths`, new `desk/bin/principal-exists`) remain the only readers of the estate, as today.

**Tech Stack:** Node 22 standard library only (`node:http`, `node:crypto`, `node:net`, global `fetch`), bash 3.2-compatible bridges, `node:test` suites under `desk/test/`, bash suites under `test/`.

**Spec:** `docs/superpowers/specs/2026-09-08-desk-front-design.md` (17d4c87). Companion: `docs/superpowers/specs/2026-09-08-desk-services-design.md`; its plan `docs/superpowers/plans/2026-09-08-desk-services-registry.md` is being executed on another branch and this plan depends on two of its tasks (see Dependencies).

## Scope of this plan

Build order steps 2 of the spec: the front listener, the OIDC login and callback, the session cookie, the cross-site rules, the stub-provider tests, and the operator documentation. **Not in this plan:** the rig bridge and the socket-mode rig start (spec build order step 5). That is a separate subsystem (a WebSocket server, `desk/filter.jq` fields, `linux/browser-stack.sh`) and gets its own plan, `2026-09-08-desk-rig-bridge.md`, once this one is on `main`.

## Dependencies on the services branch

Two things this plan calls are built by the services plan on another branch:

1. `desk/bin/principal-for-login <source> <value>` two-argument form (services plan Task 3), with `<source>` in `tailscale|oidc`, same exit codes as today (0 slug, 1 none, 65 ambiguous, 78 estate, 64 usage). Until it is on `main`, Task 6's login test that binds an identity is red. **Do Tasks 1-5 first; start Task 6 only after `git log origin/main -- desk/bin/principal-for-login` shows the two-argument commit, then rebase this branch on it.**
2. `OIDC_LOGIN` on the principal row (services plan Task 1) - the fixture rows in Task 6 use it.

Nothing else overlaps: this plan touches no `lib/registry.sh` and no `bin/steward`.

## Global Constraints

- English and ASCII only in code, comments, tests, docs and commit messages (`test/language.test.sh` sweeps `git ls-files`; `git add` new files before running it).
- No estate, host, person or company names in product code or fixtures: use `alice`, `acme`, `host-a`, `example.test`, `100.64.0.1`.
- Node 22 standard library only where the desk is touched; no npm dependency, no CDN.
- No test-only knobs in production code (`desk/test/serve.test.mjs:4-10` records the rejection of a lookup stub). Tests use real bridges against a fixture estate root and a local stub provider.
- TDD per task: failing test, run, minimal code, run, commit. One commit per task.
- Bridges (`desk/bin/*`) must run under bash 3.2: no associative arrays, no `\|` in grep, no `mapfile`.
- The desk headers are the gate: every response carries the `HEADERS` set from `desk/serve.mjs:326-333`; the front adds `set-cookie` and, on the front only, relaxes `form-action` to `'self'` for the logout form.
- Refusals never name a path from the machine and never say why beyond the fixed bodies `FORBIDDEN`, `NOT_FOUND`, `NO_MEASUREMENT` (`desk/serve.mjs:340-347`).
- Every new shipped file needs a row in `linux/deploy-manifest` (`test/deploy-manifest.test.sh` refuses an unlisted `desk/` file); `desk/test/` is never shipped.
- The front listener binds a CGNAT address (`100.64.0.0/10`) **or a loopback address** (`127.0.0.1`, `::1`) and refuses everything else, `0.0.0.0` and `::` included. Loopback is a deliberate widening of the spec's "CGNAT only": a loopback bind reaches nobody off the host, and the test suite needs it. Record the widening in the spec in Task 7.
- Cookies: `__Host-` prefix, `HttpOnly`, `Secure`, `SameSite=Lax`, `Path=/`. Session lifetime 43200 s (12 h). State cookie 600 s.
- Rate limit on `/desk/auth/*`: 10 requests per 60 s per visitor address (the `x-real-ip` the box forwards), in memory.

## File structure

| file | responsibility | task |
|---|---|---|
| `desk/front.mjs` (new) | `parseFrontListen`, `isCgnat`, `isLoopback`, `normalizeAddr` (moved here from serve.mjs and re-exported), `visitorAddress`, `RateLimiter` | 1 |
| `desk/cookie.mjs` (new) | `parseCookies`, `serializeCookie`, `loadSessionKey`, `mintSession`, `verifySession`, `mintState`, `verifyState` | 2 |
| `desk/bin/desk-paths` (modify) | three optional lines: `origin=`, `providers=`, `session_key=` | 3 |
| `desk/bin/principal-exists` (new) | rc 0 when `principals.d/<slug>.conf` exists under the estate root, 1 when not, 78 when the estate does not load | 3 |
| `desk/oidc.mjs` (new) | `loadProviders`, `discover`, `beginLogin`, `exchangeCode`, `verifyIdToken`, `identityOf` | 4, 5 |
| `desk/test/oidc-stub.mjs` (new, test only) | a stub OpenID provider: discovery, JWKS, authorize, token | 4 |
| `desk/serve.mjs` (modify) | the front server, its routes, cookie identity, cross-site rules | 6 |
| `desk/test/front.test.mjs`, `desk/test/cookie.test.mjs`, `desk/test/oidc.test.mjs` (new) | unit suites, run by the existing `test/desk-serve.test.sh` wrapper (`node --test test/*.mjs` in `desk/`) | 1, 2, 4, 5 |
| `desk/test/serve.test.mjs` (modify) | the front listener end to end | 6 |
| `test/desk-paths.test.sh` (new) | the bridges under bash | 3 |
| `linux/deploy-manifest`, `linux/steward-desk.service`, `desk/SCHEMA.md`, `README.md`, the spec | shipping and documentation | 7 |

---

### Task 1: `desk/front.mjs` - the front's address, peer and rate rules

**Files:**
- Create: `desk/front.mjs`
- Create: `desk/test/front.test.mjs`
- Modify: `desk/serve.mjs:235-262` (`normalizeAddr` moves to `front.mjs`; serve imports it)

**Interfaces:**
- Produces:
  - `normalizeAddr(raw: string) -> string` - strips `[...]`, `:port` on IPv4 forms, `%zone`, `::ffff:` prefix, lowercases. Exactly the behaviour of today's `desk/serve.mjs:235`.
  - `isCgnat(addr: string) -> boolean` - true for IPv4 in `100.64.0.0/10`.
  - `isLoopback(addr: string) -> boolean` - true for `127.0.0.1`, `::1` (after `normalizeAddr`).
  - `parseFrontListen(raw: string) -> { host: string, port: number }` - throws `Error` with a message starting `STEWARD_DESK_FRONT_LISTEN` when the host is neither CGNAT nor loopback, or the port is not an integer 1-65535 written canonically.
  - `parseFrontPeer(raw: string) -> string` - `normalizeAddr` of a CGNAT or loopback address, else throws `Error` starting `STEWARD_DESK_FRONT_PEER`.
  - `visitorAddress(req, peer: string) -> string | null` - when `normalizeAddr(req.socket.remoteAddress) === peer`, the first comma-separated entry of `req.headers['x-real-ip']` normalized, or the peer itself when the header is absent; `null` when the socket peer is not `peer` (the caller refuses the request).
  - `class RateLimiter { constructor(limit: number, windowMs: number); hit(key: string, now: number) -> boolean }` - `true` while the key has had fewer than `limit` hits in the trailing window, `false` once it reaches `limit`; prunes keys older than the window on each call.

- [ ] **Step 1: Write the failing test**

Create `desk/test/front.test.mjs`:

```js
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { normalizeAddr, isCgnat, isLoopback, parseFrontListen, parseFrontPeer, visitorAddress, RateLimiter } from '../front.mjs';

test('normalizeAddr strips brackets, ports, zones and the v4-in-v6 prefix', () => {
  assert.equal(normalizeAddr('[::1]:443'), '::1');
  assert.equal(normalizeAddr('127.0.0.1:8080'), '127.0.0.1');
  assert.equal(normalizeAddr('::ffff:100.64.0.9'), '100.64.0.9');
  assert.equal(normalizeAddr('FE80::1%eth0'), 'fe80::1');
});

test('isCgnat is exactly 100.64.0.0/10', () => {
  assert.equal(isCgnat('100.64.0.0'), true);
  assert.equal(isCgnat('100.127.255.255'), true);
  assert.equal(isCgnat('100.128.0.0'), false);
  assert.equal(isCgnat('100.63.255.255'), false);
  assert.equal(isCgnat('10.0.0.1'), false);
  assert.equal(isCgnat('::1'), false);
});

test('isLoopback accepts the two literal spellings only', () => {
  assert.equal(isLoopback('127.0.0.1'), true);
  assert.equal(isLoopback('::1'), true);
  assert.equal(isLoopback('localhost'), false);
  assert.equal(isLoopback('127.0.0.2'), false);
});

test('parseFrontListen accepts CGNAT and loopback with a canonical port', () => {
  assert.deepEqual(parseFrontListen('100.64.0.1:8443'), { host: '100.64.0.1', port: 8443 });
  assert.deepEqual(parseFrontListen('127.0.0.1:18443'), { host: '127.0.0.1', port: 18443 });
  assert.deepEqual(parseFrontListen('[::1]:18443'), { host: '::1', port: 18443 });
});

test('parseFrontListen refuses any other bind', () => {
  for (const raw of ['0.0.0.0:8443', '[::]:8443', '10.0.0.5:8443', 'localhost:8443', '100.64.0.1', '100.64.0.1:0', '100.64.0.1:08443', '100.64.0.1:70000']) {
    assert.throws(() => parseFrontListen(raw), /^Error: STEWARD_DESK_FRONT_LISTEN/, raw);
  }
});

test('parseFrontPeer normalizes and refuses a non-tailnet peer', () => {
  assert.equal(parseFrontPeer('100.98.0.8'), '100.98.0.8');
  assert.equal(parseFrontPeer('::ffff:127.0.0.1'), '127.0.0.1');
  assert.throws(() => parseFrontPeer('203.0.113.7'), /^Error: STEWARD_DESK_FRONT_PEER/);
  assert.throws(() => parseFrontPeer(''), /^Error: STEWARD_DESK_FRONT_PEER/);
});

const fakeReq = (remote, realIp) => ({ socket: { remoteAddress: remote }, headers: realIp === undefined ? {} : { 'x-real-ip': realIp } });

test('visitorAddress trusts x-real-ip only from the configured peer', () => {
  assert.equal(visitorAddress(fakeReq('100.98.0.8', '203.0.113.9'), '100.98.0.8'), '203.0.113.9');
  assert.equal(visitorAddress(fakeReq('::ffff:100.98.0.8', '203.0.113.9, 10.0.0.1'), '100.98.0.8'), '203.0.113.9');
  assert.equal(visitorAddress(fakeReq('100.98.0.8'), '100.98.0.8'), '100.98.0.8');
  assert.equal(visitorAddress(fakeReq('100.98.0.9', '203.0.113.9'), '100.98.0.8'), null);
});

test('RateLimiter allows limit hits per window and forgets old ones', () => {
  const rl = new RateLimiter(3, 60000);
  assert.equal(rl.hit('a', 1000), true);
  assert.equal(rl.hit('a', 2000), true);
  assert.equal(rl.hit('a', 3000), true);
  assert.equal(rl.hit('a', 4000), false);
  assert.equal(rl.hit('b', 4000), true);
  assert.equal(rl.hit('a', 61001), true);
});
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd desk && node --test test/front.test.mjs`
Expected: FAIL - `Cannot find module '../front.mjs'`.

- [ ] **Step 3: Write minimal implementation**

Create `desk/front.mjs`:

```js
// desk/front.mjs - the rules of the public front's listener.
//
// The front is a second listener on the host's tailnet address that exactly
// one peer, the public proxy box, may reach (the tailnet ACL lets only the
// box's tag at the port; this module refuses every other peer a second time).
// The box terminates TLS and forwards the visitor's address as x-real-ip;
// that header is believed only when the TCP peer is the box, because the box
// is the only thing that can reach the port at all. Nothing here reads a
// login header or a cookie: identity is serve.mjs's business.

// normalizeAddr - one spelling per address, so a set lookup or an equality is
// a real comparison: brackets and an IPv4 port stripped, an IPv6 zone
// stripped, the ::ffff: prefix of an IPv4-mapped address stripped, lowercased.
export function normalizeAddr(raw) {
  let s = String(raw || '').trim().toLowerCase();
  const br = s.match(/^\[([^\]]+)\](?::\d+)?$/);
  if (br) s = br[1];
  else if (/^\d+\.\d+\.\d+\.\d+:\d+$/.test(s)) s = s.slice(0, s.lastIndexOf(':'));
  const zone = s.indexOf('%');
  if (zone !== -1) s = s.slice(0, zone);
  if (s.startsWith('::ffff:') && /^\d+\.\d+\.\d+\.\d+$/.test(s.slice(7))) s = s.slice(7);
  return s;
}

// isCgnat - 100.64.0.0/10: the tailnet's own address range. The second octet
// carries the /10: 64..127.
export function isCgnat(addr) {
  const m = String(addr).match(/^100\.(\d{1,3})\.\d{1,3}\.\d{1,3}$/);
  if (!m) return false;
  const second = Number(m[1]);
  return second >= 64 && second <= 127;
}

export function isLoopback(addr) {
  return addr === '127.0.0.1' || addr === '::1';
}

function splitHostPort(raw) {
  const s = String(raw);
  const br = s.match(/^\[([^\]]+)\]:(.*)$/);
  if (br) return [br[1], br[2]];
  const i = s.lastIndexOf(':');
  if (i === -1) return [s, ''];
  return [s.slice(0, i), s.slice(i + 1)];
}

// parseFrontListen - STEWARD_DESK_FRONT_LISTEN as `<addr>:<port>`. The address
// must be the tailnet's (CGNAT) or loopback (harmless: reaches nobody off the
// host; the test suite lives there). 0.0.0.0 and :: are refused by name in
// the message because they are the mistake this check exists for. The port is
// an integer written once and canonically, never 0.
export function parseFrontListen(raw) {
  const [hostRaw, portRaw] = splitHostPort(raw);
  const host = normalizeAddr(hostRaw);
  if (!(isCgnat(host) || isLoopback(host))) {
    throw new Error('STEWARD_DESK_FRONT_LISTEN must name a tailnet (100.64.0.0/10) or loopback address, never 0.0.0.0 or ::, got ' + JSON.stringify(raw));
  }
  const port = Number(portRaw);
  if (!/^[0-9]+$/.test(portRaw) || port < 1 || port > 65535 || portRaw !== String(port)) {
    throw new Error('STEWARD_DESK_FRONT_LISTEN port must be an integer from 1 to 65535, got ' + JSON.stringify(raw));
  }
  return { host, port };
}

// parseFrontPeer - the one address allowed to connect: the proxy box's tailnet
// address (or loopback, in the test suite).
export function parseFrontPeer(raw) {
  const peer = normalizeAddr(raw);
  if (!(isCgnat(peer) || isLoopback(peer))) {
    throw new Error('STEWARD_DESK_FRONT_PEER must be the proxy box\'s tailnet (100.64.0.0/10) or loopback address, got ' + JSON.stringify(raw));
  }
  return peer;
}

// visitorAddress - null when the socket peer is not the box (the caller must
// refuse); otherwise the visitor as the box reported it, or the box itself
// when it reported nothing. Only the FIRST x-real-ip entry counts: the box
// writes exactly one, and anything after a comma came from the visitor.
export function visitorAddress(req, peer) {
  const remote = normalizeAddr(req.socket && req.socket.remoteAddress);
  if (remote !== peer) return null;
  const hdr = req.headers['x-real-ip'];
  if (typeof hdr !== 'string' || hdr.trim() === '') return peer;
  return normalizeAddr(hdr.split(',')[0]);
}

// RateLimiter - a trailing window per key, in memory. The desk is one process
// on one host, so a map is the whole store; keys idle for a window are pruned
// on every call so a scan of the internet does not grow it without bound.
export class RateLimiter {
  constructor(limit, windowMs) {
    this.limit = limit;
    this.windowMs = windowMs;
    this.hits = new Map();
  }
  hit(key, now) {
    const floor = now - this.windowMs;
    for (const [k, times] of this.hits) {
      const kept = times.filter((t) => t > floor);
      if (kept.length === 0) this.hits.delete(k); else this.hits.set(k, kept);
    }
    const times = this.hits.get(key) || [];
    if (times.length >= this.limit) return false;
    times.push(now);
    this.hits.set(key, times);
    return true;
  }
}
```

Then in `desk/serve.mjs`: delete the `normalizeAddr` function at :235-262 and add to the imports at the top:

```js
import { normalizeAddr } from './front.mjs';
```

Keep the explanatory comment block above the deleted function, shortened to one line pointing at `front.mjs`.

- [ ] **Step 4: Run tests to verify they pass**

Run: `cd desk && node --test test/front.test.mjs test/serve.test.mjs`
Expected: PASS on both (serve's self-origin tests exercise the moved function).

- [ ] **Step 5: Commit**

```bash
git add desk/front.mjs desk/test/front.test.mjs desk/serve.mjs
git commit -m "desk front: the listener's rules - a tailnet or loopback bind, one peer, x-real-ip believed only from it, a rate window per visitor"
```

---

### Task 2: `desk/cookie.mjs` - cookies and the self-contained session

**Files:**
- Create: `desk/cookie.mjs`
- Create: `desk/test/cookie.test.mjs`

**Interfaces:**
- Produces:
  - `parseCookies(header: string | undefined) -> Map<string,string>` - name to raw value; malformed pairs skipped.
  - `serializeCookie(name, value, { maxAge: number }) -> string` - `name=value; Path=/; HttpOnly; Secure; SameSite=Lax; Max-Age=<n>`; `maxAge: 0` clears.
  - `loadSessionKey(path: string) -> Buffer` - reads the file; throws `Error` starting `session key` when missing, not mode `0600`, not owned by the process uid, or shorter than 32 bytes after trimming.
  - `mintSession(key: Buffer, principal: string, issuedAt: number) -> string` - `<principal>.<issuedAt>.<hmac>`, hmac = base64url(HMAC-SHA256(key, `<principal>.<issuedAt>`)).
  - `verifySession(key, value, now, maxAgeSec = 43200) -> string | null` - the principal when the mac matches (constant time) and `now - issuedAt` is within `[0, maxAgeSec]`; `null` otherwise. Principal must match `/^[a-z0-9-]+$/`.
  - `mintState(key, fields: {state, nonce, verifier, provider, issuedAt}) -> string` and `verifyState(key, value, now, maxAgeSec = 600) -> fields | null` - the OAuth state cookie: base64url(JSON) + `.` + mac.

- [ ] **Step 1: Write the failing test**

Create `desk/test/cookie.test.mjs`:

```js
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { mkdtempSync, writeFileSync, chmodSync } from 'node:fs';
import { join } from 'node:path';
import { tmpdir } from 'node:os';
import { parseCookies, serializeCookie, loadSessionKey, mintSession, verifySession, mintState, verifyState } from '../cookie.mjs';

const KEY = Buffer.from('0123456789abcdef0123456789abcdef');
const OTHER = Buffer.from('fedcba9876543210fedcba9876543210');

test('parseCookies reads pairs and skips junk', () => {
  const c = parseCookies('a=1; __Host-desk-session=x.y.z; junk; b=');
  assert.equal(c.get('a'), '1');
  assert.equal(c.get('__Host-desk-session'), 'x.y.z');
  assert.equal(c.get('b'), '');
  assert.equal(c.has('junk'), false);
  assert.equal(parseCookies(undefined).size, 0);
});

test('serializeCookie is __Host-shaped and clears with Max-Age=0', () => {
  assert.equal(serializeCookie('__Host-desk-session', 'v', { maxAge: 43200 }),
    '__Host-desk-session=v; Path=/; HttpOnly; Secure; SameSite=Lax; Max-Age=43200');
  assert.equal(serializeCookie('__Host-desk-session', '', { maxAge: 0 }),
    '__Host-desk-session=; Path=/; HttpOnly; Secure; SameSite=Lax; Max-Age=0');
});

test('a session round-trips, and fails on the wrong key, a tampered principal, or age', () => {
  const v = mintSession(KEY, 'alice', 1000);
  assert.match(v, /^alice\.1000\.[A-Za-z0-9_-]+$/);
  assert.equal(verifySession(KEY, v, 1000 + 43200), 'alice');
  assert.equal(verifySession(KEY, v, 1000 + 43201), null);
  assert.equal(verifySession(KEY, v, 999), null);
  assert.equal(verifySession(OTHER, v, 2000), null);
  assert.equal(verifySession(KEY, v.replace('alice', 'bob'), 2000), null);
  assert.equal(verifySession(KEY, 'not.a.cookie', 2000), null);
  assert.equal(verifySession(KEY, '', 2000), null);
});

test('a state cookie carries its fields and expires in ten minutes', () => {
  const f = { state: 's1', nonce: 'n1', verifier: 'v1', provider: 'google', issuedAt: 5000 };
  const v = mintState(KEY, f);
  assert.deepEqual(verifyState(KEY, v, 5600), f);
  assert.equal(verifyState(KEY, v, 5601), null);
  assert.equal(verifyState(OTHER, v, 5100), null);
  assert.equal(verifyState(KEY, v.slice(0, -2) + 'xx', 5100), null);
});

test('loadSessionKey insists on a private, long enough file', () => {
  const d = mkdtempSync(join(tmpdir(), 'desk-key-'));
  const p = join(d, 'k');
  assert.throws(() => loadSessionKey(p), /^Error: session key/);
  writeFileSync(p, 'short\n'); chmodSync(p, 0o600);
  assert.throws(() => loadSessionKey(p), /^Error: session key/);
  writeFileSync(p, 'x'.repeat(44) + '\n'); chmodSync(p, 0o644);
  assert.throws(() => loadSessionKey(p), /^Error: session key.*0600/);
  chmodSync(p, 0o600);
  assert.equal(loadSessionKey(p).length, 44);
});
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd desk && node --test test/cookie.test.mjs`
Expected: FAIL - `Cannot find module '../cookie.mjs'`.

- [ ] **Step 3: Write minimal implementation**

Create `desk/cookie.mjs`:

```js
// desk/cookie.mjs - the front's cookies.
//
// THE SESSION IS THE COOKIE. No server-side store: the value is the principal
// slug, the issue time, and an HMAC over both under a key only this host
// holds. A forged value fails the mac; a copied value is the same session
// (that is what a session cookie is, and the 12 h lifetime bounds it); a
// removed principal is refused on the next request because serve.mjs checks
// the row exists on every hit, never trusting the slug alone. The key file is
// generated once by the estate, mode 0600, never shipped by the product.

import { createHmac, timingSafeEqual } from 'node:crypto';
import { readFileSync, statSync } from 'node:fs';

const SLUG_RE = /^[a-z0-9-]+$/;

export function parseCookies(header) {
  const out = new Map();
  if (typeof header !== 'string') return out;
  for (const part of header.split(';')) {
    const i = part.indexOf('=');
    if (i === -1) continue;
    const name = part.slice(0, i).trim();
    if (!name) continue;
    out.set(name, part.slice(i + 1).trim());
  }
  return out;
}

// serializeCookie - one shape for every cookie the desk sets. __Host- prefix
// (the browser refuses it without Secure, Path=/ and no Domain), HttpOnly (no
// script reads it), SameSite=Lax (a cross-site POST never carries it).
export function serializeCookie(name, value, { maxAge }) {
  return name + '=' + value + '; Path=/; HttpOnly; Secure; SameSite=Lax; Max-Age=' + maxAge;
}

const b64u = (buf) => Buffer.from(buf).toString('base64url');

function mac(key, data) {
  return b64u(createHmac('sha256', key).update(data).digest());
}

function macEquals(a, b) {
  const ba = Buffer.from(String(a)); const bb = Buffer.from(String(b));
  return ba.length === bb.length && timingSafeEqual(ba, bb);
}

export function loadSessionKey(path) {
  let st;
  try { st = statSync(path); } catch { throw new Error('session key file is missing'); }
  if ((st.mode & 0o777) !== 0o600) throw new Error('session key file must be mode 0600');
  if (st.uid !== process.getuid()) throw new Error('session key file must be owned by the desk account');
  const key = Buffer.from(readFileSync(path, 'utf8').trim());
  if (key.length < 32) throw new Error('session key must be at least 32 bytes');
  return key;
}

export function mintSession(key, principal, issuedAt) {
  const body = principal + '.' + issuedAt;
  return body + '.' + mac(key, body);
}

export function verifySession(key, value, now, maxAgeSec = 43200) {
  const parts = String(value || '').split('.');
  if (parts.length !== 3) return null;
  const [principal, issuedRaw, sig] = parts;
  if (!SLUG_RE.test(principal) || !/^[0-9]+$/.test(issuedRaw)) return null;
  if (!macEquals(sig, mac(key, principal + '.' + issuedRaw))) return null;
  const age = now - Number(issuedRaw);
  if (age < 0 || age > maxAgeSec) return null;
  return principal;
}

export function mintState(key, fields) {
  const body = b64u(JSON.stringify(fields));
  return body + '.' + mac(key, body);
}

export function verifyState(key, value, now, maxAgeSec = 600) {
  const parts = String(value || '').split('.');
  if (parts.length !== 2) return null;
  const [body, sig] = parts;
  if (!macEquals(sig, mac(key, body))) return null;
  let fields;
  try { fields = JSON.parse(Buffer.from(body, 'base64url').toString('utf8')); } catch { return null; }
  if (!fields || typeof fields.issuedAt !== 'number') return null;
  const age = now - fields.issuedAt;
  if (age < 0 || age > maxAgeSec) return null;
  return fields;
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd desk && node --test test/cookie.test.mjs`
Expected: PASS, 5 tests.

- [ ] **Step 5: Commit**

```bash
git add desk/cookie.mjs desk/test/cookie.test.mjs
git commit -m "desk front: the session is the cookie - principal, issue time and an HMAC under the host's own key, nothing stored"
```

---

### Task 3: the bridges - `desk-paths` grows three optional lines, `principal-exists` is new

**Files:**
- Modify: `desk/bin/desk-paths:38-40`
- Create: `desk/bin/principal-exists`
- Create: `test/desk-paths.test.sh`

**Interfaces:**
- Consumes: `_registry_estate_value <KEY> <regex>` (`lib/registry.sh:1861`, rc 78 when missing or malformed), `_registry_estate_root` (`lib/registry.sh:70`), `registry_state_dir_name`.
- Produces:
  - `desk-paths` prints, after `dir=` and `sock=`, **when and only when the estate names them**: `origin=<DESK_ORIGIN>` (form `^https?://[A-Za-z0-9.-]+(:[0-9]+)?$`), `providers=<estate root>/desk/providers.d` (only when that directory exists), `session_key=<DESK_SESSION_KEY_FILE>` (form `^/.+$`). A malformed value is rc 78 with the key named on stderr; an absent value prints no line.
  - `principal-exists <slug>`: rc 0 when `<estate root>/principals.d/<slug>.conf` is a regular file, 1 when not, 64 on a slug not matching `^[a-z0-9-]+$` or wrong argument count, 78 when the estate does not load. Prints nothing.

- [ ] **Step 1: Write the failing test**

Create `test/desk-paths.test.sh`:

```bash
#!/bin/bash
# desk-paths grows three optional lines for the front; principal-exists is the
# per-request row check the front's cookie identity needs.
set -u
here="$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)"
pass=0; fail=0
ok()  { pass=$((pass+1)); printf '  ok   %s\n' "$1"; }
bad() { fail=$((fail+1)); printf '  FAIL %s\n     %s\n' "$1" "${2:-}"; }
is()  { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "wanted '$3', got '$2'"; fi; }
has() { case "$2" in *"$3"*) ok "$1" ;; *) bad "$1" "missing '$3' in: $2" ;; esac; }
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
ROOT="$T/estate"; mkdir -p "$ROOT/estate" "$ROOT/principals.d"
cat > "$ROOT/estate/steward.conf" <<'EOF'
ESTATE_NAME="fixture"
SCHEMA_VERSION="3"
HUB_SESSION="hub"
HUB_HOST="host-a"
HUB_SSH="hub@host-a"
LABEL_PREFIX="x."
RC_LABEL_PREFIX=""
TMUX_SOCKET="fx"
STATE_DIR_NAME="fixture-state"
PAUSED_DIR_NAME="fixture-paused"
PING_MSG="ping"
OP_TOKEN_NAME="op"
BUS_DIR_NAME="fixture-bus"
EOF
export STEWARD_ESTATE_ROOT="$ROOT" STEWARD_CONFIG_FILE="$T/no-such-config" HOME="$T/home"
mkdir -p "$HOME"
echo "desk-paths"

echo "== without front keys, exactly the two classic lines =="
out="$(bash "$here/desk/bin/desk-paths")"; rc=$?
is  "rc 0" "$rc" "0"
is  "two lines" "$(printf '%s\n' "$out" | wc -l | tr -d ' ')" "2"
has "dir line"  "$out" "dir=$HOME/.local/state/fixture-state/desk"
has "sock line" "$out" "sock=$HOME/.local/state/fixture-state/desk.sock"

echo "== with the front keys and a providers directory =="
printf 'DESK_ORIGIN="https://desk.example.test"\nDESK_SESSION_KEY_FILE="/var/fixture/key"\n' >> "$ROOT/estate/steward.conf"
mkdir -p "$ROOT/desk/providers.d"
out="$(bash "$here/desk/bin/desk-paths")"; rc=$?
is  "rc 0" "$rc" "0"
has "origin line"      "$out" "origin=https://desk.example.test"
has "providers line"   "$out" "providers=$ROOT/desk/providers.d"
has "session_key line" "$out" "session_key=/var/fixture/key"

echo "== a malformed origin is a refusal, not a guess =="
sed -i.bak 's|^DESK_ORIGIN=.*|DESK_ORIGIN="desk.example.test/desk"|' "$ROOT/estate/steward.conf"
bash "$here/desk/bin/desk-paths" >/dev/null 2>"$T/err"; rc=$?
is  "rc 78" "$rc" "78"
has "names the key" "$(cat "$T/err")" "DESK_ORIGIN"

echo "== principal-exists =="
printf 'NAME="Alice"\nTAILSCALE_LOGIN="alice@example.test"\n' > "$ROOT/principals.d/alice.conf"
bash "$here/desk/bin/principal-exists" alice; is "alice exists" "$?" "0"
bash "$here/desk/bin/principal-exists" bob;   is "bob does not" "$?" "1"
bash "$here/desk/bin/principal-exists" '../x' 2>/dev/null; is "a path is a usage error" "$?" "64"
bash "$here/desk/bin/principal-exists" 2>/dev/null; is "no argument is a usage error" "$?" "64"
out="$(bash "$here/desk/bin/principal-exists" alice)"; is "prints nothing" "$out" ""
STEWARD_ESTATE_ROOT="$T/nowhere" bash "$here/desk/bin/principal-exists" alice 2>/dev/null; is "no estate is 78" "$?" "78"

printf '\n  %d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash test/desk-paths.test.sh`
Expected: the "two classic lines" block passes; "origin line", "providers line", "session_key line" FAIL; every `principal-exists` line FAILS (file missing, rc 127).

- [ ] **Step 3: Write minimal implementation**

Replace the tail of `desk/bin/desk-paths` (from `base=` to the end) with:

```bash
base="$HOME/.local/state/$state"
printf 'dir=%s\n'  "$base/desk"
printf 'sock=%s\n' "$base/desk.sock"

# THE FRONT'S THREE LINES, printed only when the estate names them. A desk
# with no front has no origin, no providers and no key, and must not be
# refused for their absence; a desk WITH a front must never run on a guessed
# one, so a malformed value is rc 78 with the key named. The providers line
# follows the directory, not a key: the estate keeps desk/providers.d beside
# its registry, and an estate without the directory has no providers.
if grep -q '^DESK_ORIGIN=' "$STEWARD_ESTATE_ROOT/estate/steward.conf" 2>/dev/null; then
  origin="$(_registry_estate_value DESK_ORIGIN '^https?://[A-Za-z0-9.-]+(:[0-9]+)?$')" || exit 78
  printf 'origin=%s\n' "$origin"
fi
root="$(_registry_estate_root)" || exit 78
[ -d "$root/desk/providers.d" ] && printf 'providers=%s\n' "$root/desk/providers.d"
if grep -q '^DESK_SESSION_KEY_FILE=' "$STEWARD_ESTATE_ROOT/estate/steward.conf" 2>/dev/null; then
  keyfile="$(_registry_estate_value DESK_SESSION_KEY_FILE '^/.+$')" || exit 78
  printf 'session_key=%s\n' "$keyfile"
fi
exit 0
```

Check first with `sed -n 1861,1910p lib/registry.sh` that `_registry_estate_value` prints the value on stdout and returns 78 on a mismatch, and with `sed -n 70,90p lib/registry.sh` that `_registry_estate_root` prints the root; adjust the two calls to the exact signatures if they differ. If `STEWARD_ESTATE_ROOT` is not the variable the library resolves the root from, use `"$(_registry_estate_root)/estate/steward.conf"` in both `grep` lines instead.

Create `desk/bin/principal-exists`:

```bash
#!/bin/bash
# desk/bin/principal-exists <slug> - does the principal row still exist?
#
# THE FRONT'S COOKIE NAMES A PRINCIPAL; THE ROW DECIDES IF IT IS STILL ONE.
# A session cookie is self-contained (desk/cookie.mjs), so removing a person
# from the registry must take effect on their next click, not at the cookie's
# expiry. serve.mjs asks this bridge on every front request. It answers with
# an exit code and nothing else: 0 the row is there, 1 it is not, 64 the slug
# is not a slug (a path, an empty string, two arguments), 78 the estate does
# not load. Same library discovery as desk-paths.
set -uo pipefail
here="$(CDPATH= cd -- "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [ -n "${STEWARD_REGISTRY_LIB:-}" ]; then
  # shellcheck source=/dev/null
  . "$STEWARD_REGISTRY_LIB" || exit 78
elif [ -f "$here/../../lib/registry.sh" ]; then
  # shellcheck source=/dev/null
  . "$here/../../lib/registry.sh" || exit 78
else
  echo "principal-exists: the registry library was found in neither layout (from $here)" >&2
  exit 78
fi
[ $# -eq 1 ] || { echo "usage: principal-exists <slug>" >&2; exit 64; }
case "$1" in
  ''|*[!a-z0-9-]*) echo "principal-exists: not a slug" >&2; exit 64 ;;
esac
root="$(_registry_estate_root)" || exit 78
[ -d "$root/principals.d" ] || exit 78
[ -f "$root/principals.d/$1.conf" ] && exit 0
exit 1
```

`chmod 755 desk/bin/principal-exists`.

- [ ] **Step 4: Run test to verify it passes**

Run: `bash test/desk-paths.test.sh && bash test/desk-snapshot.test.sh`
Expected: `… passed, 0 failed` on both (snapshot's existing `desk-paths` use sees only the two classic lines in its fixture).

- [ ] **Step 5: Commit**

```bash
git add desk/bin/desk-paths desk/bin/principal-exists test/desk-paths.test.sh
git commit -m "desk bridges: desk-paths names the front's origin, providers and key when the estate does; principal-exists answers the cookie's question with an exit code"
```

---

### Task 4: `desk/oidc.mjs` part one - providers, discovery, the login redirect; the stub provider

**Files:**
- Create: `desk/oidc.mjs`
- Create: `desk/test/oidc-stub.mjs`
- Create: `desk/test/oidc.test.mjs`

**Interfaces:**
- Produces (in `desk/oidc.mjs`):
  - `loadProviders(dir: string) -> Map<slug, Provider>` where `Provider = { slug, issuer: string|null, issuerTemplate: string|null, clientId, clientSecretFile, discovery }`. Slug = file name without `.conf`, must match `/^[a-z0-9-]+$/`. Rows are `KEY="value"` lines; a row must have exactly one of `ISSUER` / `ISSUER_TEMPLATE` (the template must contain the literal `<tid>`), and all of `CLIENT_ID`, `CLIENT_SECRET_FILE`, `DISCOVERY`; otherwise throws `Error` naming the file and the key.
  - `async discover(provider, fetchImpl = fetch) -> { authorization_endpoint, token_endpoint, jwks_uri, issuer }` - fetched from `provider.discovery`, cached per provider for 3600 s; throws on a document lacking any of the four.
  - `beginLogin(provider, doc, redirectUri) -> { url: string, state: string, nonce: string, verifier: string }` - 32 random bytes base64url each for `state`, `nonce`, `verifier`; `url` = `doc.authorization_endpoint` with `response_type=code`, `client_id`, `redirect_uri`, `scope=openid email`, `state`, `nonce`, `code_challenge` = base64url(SHA-256(verifier)), `code_challenge_method=S256`.
- Produces (in `desk/test/oidc-stub.mjs`, test only):
  - `async startStub({ issuer?: string, tid?: string }) -> { origin, issuer, keyPair, kid, close(), lastAuthorize, mintIdToken(claims, {kid, key} = default) , tokenResponse }` - an `http.Server` on `127.0.0.1:0` serving `/.well-known/openid-configuration` (issuer = `issuer` or `origin`), `/jwks` (one RS256 key, `kid: 'k1'`), `/authorize` (records the query in `lastAuthorize`, responds `302` to `redirect_uri?code=CODE&state=<state>`), `/token` (accepts the form, checks `code === 'CODE'` and `code_verifier` present, returns `tokenResponse` - by default `{ id_token: mintIdToken({sub: 'sub-1', email: 'alice@example.test', nonce: <the nonce from lastAuthorize>}) }`). `mintIdToken(claims, opts)` signs RS256 with the stub's key, `iss` = issuer, `aud` = the `client_id` from `lastAuthorize`, `iat` = now, `exp` = now + 300, plus `tid` when the stub was started with one; every field can be overridden by `claims`.

- [ ] **Step 1: Write the failing test**

Create `desk/test/oidc-stub.mjs`:

```js
// A stub OpenID provider for the desk's tests: discovery, JWKS, authorize,
// token. Nothing here is shipped. One RS256 key per start; the token endpoint
// mints whatever the test asked for, so every refusal path has a fixture.
import http from 'node:http';
import { generateKeyPairSync, createSign, randomUUID } from 'node:crypto';

const b64u = (b) => Buffer.from(b).toString('base64url');

export async function startStub(opts = {}) {
  const { publicKey, privateKey } = generateKeyPairSync('rsa', { modulusLength: 2048 });
  const jwk = publicKey.export({ format: 'jwk' });
  const kid = 'k1';
  const stub = { lastAuthorize: null, tokenResponse: null, keyPair: { publicKey, privateKey }, kid, tokenCalls: [] };

  stub.mintIdToken = (claims = {}, o = {}) => {
    const now = Math.floor(Date.now() / 1000);
    const header = { alg: 'RS256', typ: 'JWT', kid: o.kid || kid };
    const payload = Object.assign({
      iss: stub.issuer, aud: stub.lastAuthorize ? stub.lastAuthorize.get('client_id') : 'cid',
      iat: now, exp: now + 300, sub: 'sub-1', email: 'alice@example.test',
      nonce: stub.lastAuthorize ? stub.lastAuthorize.get('nonce') : undefined
    }, opts.tid ? { tid: opts.tid } : {}, claims);
    const signingInput = b64u(JSON.stringify(header)) + '.' + b64u(JSON.stringify(payload));
    const sig = createSign('RSA-SHA256').update(signingInput).sign(o.key || privateKey);
    return signingInput + '.' + b64u(sig);
  };

  const server = http.createServer((req, res) => {
    const u = new URL(req.url, stub.origin);
    const json = (code, body) => { res.writeHead(code, { 'content-type': 'application/json' }); res.end(JSON.stringify(body)); };
    if (u.pathname === '/.well-known/openid-configuration') {
      return json(200, { issuer: stub.issuer, authorization_endpoint: stub.origin + '/authorize', token_endpoint: stub.origin + '/token', jwks_uri: stub.origin + '/jwks' });
    }
    if (u.pathname === '/jwks') return json(200, { keys: [Object.assign({ kid, use: 'sig', alg: 'RS256' }, jwk)] });
    if (u.pathname === '/authorize') {
      stub.lastAuthorize = u.searchParams;
      const back = new URL(u.searchParams.get('redirect_uri'));
      back.searchParams.set('code', 'CODE');
      back.searchParams.set('state', u.searchParams.get('state'));
      res.writeHead(302, { location: back.toString() }); return res.end();
    }
    if (u.pathname === '/token' && req.method === 'POST') {
      let body = ''; req.setEncoding('utf8');
      req.on('data', (c) => { body += c; });
      req.on('end', () => {
        const form = new URLSearchParams(body);
        stub.tokenCalls.push({ form, auth: req.headers.authorization || null });
        if (form.get('code') !== 'CODE' || !form.get('code_verifier')) return json(400, { error: 'invalid_grant' });
        return json(200, stub.tokenResponse || { id_token: stub.mintIdToken(), token_type: 'Bearer' });
      });
      return;
    }
    json(404, { error: 'not_found' });
  });
  await new Promise((r) => server.listen(0, '127.0.0.1', r));
  stub.origin = 'http://127.0.0.1:' + server.address().port;
  stub.issuer = opts.issuer || stub.origin;
  stub.close = () => new Promise((r) => server.close(r));
  stub.id = randomUUID();
  return stub;
}
```

Create `desk/test/oidc.test.mjs`:

```js
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { mkdtempSync, writeFileSync, mkdirSync } from 'node:fs';
import { join } from 'node:path';
import { tmpdir } from 'node:os';
import { createHash } from 'node:crypto';
import { loadProviders, discover, beginLogin } from '../oidc.mjs';
import { startStub } from './oidc-stub.mjs';

function providersDir(rows) {
  const d = mkdtempSync(join(tmpdir(), 'desk-prov-'));
  for (const [name, text] of Object.entries(rows)) writeFileSync(join(d, name), text);
  return d;
}

test('loadProviders reads ISSUER or ISSUER_TEMPLATE rows and refuses the rest', () => {
  const d = providersDir({
    'google.conf': 'ISSUER="https://accounts.example.test"\nDISCOVERY="https://accounts.example.test/.well-known/openid-configuration"\nCLIENT_ID="cid-g"\nCLIENT_SECRET_FILE="/var/fixture/g"\n',
    'microsoft.conf': '# comment\nISSUER_TEMPLATE="https://login.example.test/<tid>/v2.0"\nDISCOVERY="https://login.example.test/common/v2.0/.well-known/openid-configuration"\nCLIENT_ID="cid-m"\nCLIENT_SECRET_FILE="/var/fixture/m"\n',
    'README': 'not a row\n'
  });
  const p = loadProviders(d);
  assert.deepEqual([...p.keys()].sort(), ['google', 'microsoft']);
  assert.equal(p.get('google').issuer, 'https://accounts.example.test');
  assert.equal(p.get('google').issuerTemplate, null);
  assert.equal(p.get('microsoft').issuerTemplate, 'https://login.example.test/<tid>/v2.0');
  assert.equal(p.get('microsoft').issuer, null);
  assert.equal(p.get('microsoft').clientSecretFile, '/var/fixture/m');
});

test('loadProviders refuses a row missing a key, both issuer forms, a template without <tid>, or a bad slug', () => {
  const bad = (name, text, re) => assert.throws(() => loadProviders(providersDir({ [name]: text })), re);
  bad('x.conf', 'ISSUER="https://a"\nCLIENT_ID="c"\nCLIENT_SECRET_FILE="/f"\n', /DISCOVERY/);
  bad('x.conf', 'ISSUER="https://a"\nISSUER_TEMPLATE="https://b/<tid>"\nDISCOVERY="https://a/d"\nCLIENT_ID="c"\nCLIENT_SECRET_FILE="/f"\n', /exactly one/);
  bad('x.conf', 'ISSUER_TEMPLATE="https://b/tenant"\nDISCOVERY="https://a/d"\nCLIENT_ID="c"\nCLIENT_SECRET_FILE="/f"\n', /<tid>/);
  bad('Bad Name.conf', 'ISSUER="https://a"\nDISCOVERY="https://a/d"\nCLIENT_ID="c"\nCLIENT_SECRET_FILE="/f"\n', /slug/);
});

test('discover fetches the four endpoints once and caches them', async () => {
  const stub = await startStub();
  let calls = 0;
  const counting = (u, o) => { calls++; return fetch(u, o); };
  const prov = { slug: 'p', issuer: stub.issuer, issuerTemplate: null, clientId: 'cid', clientSecretFile: '/f', discovery: stub.origin + '/.well-known/openid-configuration' };
  const doc = await discover(prov, counting);
  assert.equal(doc.authorization_endpoint, stub.origin + '/authorize');
  assert.equal(doc.token_endpoint, stub.origin + '/token');
  assert.equal(doc.jwks_uri, stub.origin + '/jwks');
  await discover(prov, counting);
  assert.equal(calls, 1);
  await stub.close();
});

test('beginLogin builds a PKCE S256 authorization URL with fresh state and nonce', async () => {
  const stub = await startStub();
  const prov = { slug: 'p', issuer: stub.issuer, issuerTemplate: null, clientId: 'cid', clientSecretFile: '/f', discovery: stub.origin + '/.well-known/openid-configuration' };
  const doc = await discover(prov);
  const a = beginLogin(prov, doc, 'https://desk.example.test/desk/auth/callback');
  const b = beginLogin(prov, doc, 'https://desk.example.test/desk/auth/callback');
  assert.notEqual(a.state, b.state); assert.notEqual(a.nonce, b.nonce);
  const u = new URL(a.url);
  assert.equal(u.origin + u.pathname, stub.origin + '/authorize');
  assert.equal(u.searchParams.get('response_type'), 'code');
  assert.equal(u.searchParams.get('client_id'), 'cid');
  assert.equal(u.searchParams.get('redirect_uri'), 'https://desk.example.test/desk/auth/callback');
  assert.equal(u.searchParams.get('scope'), 'openid email');
  assert.equal(u.searchParams.get('state'), a.state);
  assert.equal(u.searchParams.get('nonce'), a.nonce);
  assert.equal(u.searchParams.get('code_challenge_method'), 'S256');
  assert.equal(u.searchParams.get('code_challenge'), createHash('sha256').update(a.verifier).digest('base64url'));
  await stub.close();
});
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd desk && node --test test/oidc.test.mjs`
Expected: FAIL - `Cannot find module '../oidc.mjs'`.

- [ ] **Step 3: Write minimal implementation**

Create `desk/oidc.mjs` (part one; Task 5 appends to it):

```js
// desk/oidc.mjs - OpenID Connect, done by the desk itself on the host.
//
// THE PROXY BOX HOLDS NOTHING. The client secret, the token exchange and the
// signature check all happen here, so a compromised box can forward bytes
// and nothing more. Standard library only: fetch for discovery, JWKS and the
// token endpoint; node:crypto for PKCE and RS256.
//
// Providers are estate data: desk/providers.d/<slug>.conf rows with ISSUER
// (compared byte for byte) or ISSUER_TEMPLATE (a literal <tid> replaced by
// the token's own tenant claim, for a multi-tenant provider that discovers
// through a common endpoint), DISCOVERY, CLIENT_ID and CLIENT_SECRET_FILE.
// The product ships no client id.

import { readdirSync, readFileSync } from 'node:fs';
import { join, basename } from 'node:path';
import { randomBytes, createHash } from 'node:crypto';

const SLUG_RE = /^[a-z0-9-]+$/;
const REQUIRED = ['DISCOVERY', 'CLIENT_ID', 'CLIENT_SECRET_FILE'];

function parseRow(text) {
  const out = {};
  for (const line of text.split('\n')) {
    const m = line.match(/^([A-Z_]+)="(.*)"\s*$/);
    if (m) out[m[1]] = m[2];
  }
  return out;
}

export function loadProviders(dir) {
  const out = new Map();
  for (const name of readdirSync(dir)) {
    if (!name.endsWith('.conf')) continue;
    const slug = basename(name, '.conf');
    const file = join(dir, name);
    if (!SLUG_RE.test(slug)) throw new Error('provider ' + file + ': the file name must be a slug');
    const row = parseRow(readFileSync(file, 'utf8'));
    for (const k of REQUIRED) if (!row[k]) throw new Error('provider ' + file + ': ' + k + ' is missing');
    const hasIss = Boolean(row.ISSUER); const hasTpl = Boolean(row.ISSUER_TEMPLATE);
    if (hasIss === hasTpl) throw new Error('provider ' + file + ': exactly one of ISSUER and ISSUER_TEMPLATE');
    if (hasTpl && !row.ISSUER_TEMPLATE.includes('<tid>')) throw new Error('provider ' + file + ': ISSUER_TEMPLATE must contain the literal <tid>');
    out.set(slug, {
      slug, issuer: hasIss ? row.ISSUER : null, issuerTemplate: hasTpl ? row.ISSUER_TEMPLATE : null,
      clientId: row.CLIENT_ID, clientSecretFile: row.CLIENT_SECRET_FILE, discovery: row.DISCOVERY
    });
  }
  return out;
}

const DISCOVERY_TTL_MS = 3600 * 1000;
const discoveryCache = new Map(); // slug -> { doc, at }

export async function discover(provider, fetchImpl = fetch) {
  const hit = discoveryCache.get(provider.slug);
  if (hit && Date.now() - hit.at < DISCOVERY_TTL_MS) return hit.doc;
  const res = await fetchImpl(provider.discovery, { headers: { accept: 'application/json' } });
  if (!res.ok) throw new Error('discovery for ' + provider.slug + ' answered ' + res.status);
  const doc = await res.json();
  for (const k of ['issuer', 'authorization_endpoint', 'token_endpoint', 'jwks_uri']) {
    if (typeof doc[k] !== 'string' || !doc[k]) throw new Error('discovery for ' + provider.slug + ' lacks ' + k);
  }
  const kept = { issuer: doc.issuer, authorization_endpoint: doc.authorization_endpoint, token_endpoint: doc.token_endpoint, jwks_uri: doc.jwks_uri };
  discoveryCache.set(provider.slug, { doc: kept, at: Date.now() });
  return kept;
}

const rand = () => randomBytes(32).toString('base64url');

export function beginLogin(provider, doc, redirectUri) {
  const state = rand(); const nonce = rand(); const verifier = rand();
  const u = new URL(doc.authorization_endpoint);
  u.searchParams.set('response_type', 'code');
  u.searchParams.set('client_id', provider.clientId);
  u.searchParams.set('redirect_uri', redirectUri);
  u.searchParams.set('scope', 'openid email');
  u.searchParams.set('state', state);
  u.searchParams.set('nonce', nonce);
  u.searchParams.set('code_challenge', createHash('sha256').update(verifier).digest('base64url'));
  u.searchParams.set('code_challenge_method', 'S256');
  return { url: u.toString(), state, nonce, verifier };
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd desk && node --test test/oidc.test.mjs`
Expected: PASS, 4 tests.

- [ ] **Step 5: Commit**

```bash
git add desk/oidc.mjs desk/test/oidc.test.mjs desk/test/oidc-stub.mjs
git commit -m "desk front: providers are estate rows, discovery is fetched once, the login redirect carries PKCE, state and nonce"
```

---

### Task 5: `desk/oidc.mjs` part two - code exchange and `id_token` verification

**Files:**
- Modify: `desk/oidc.mjs` (append)
- Modify: `desk/test/oidc.test.mjs` (append)

**Interfaces:**
- Consumes: `startStub` (Task 4), `discover`, `beginLogin`.
- Produces:
  - `async exchangeCode(provider, doc, { code, verifier, redirectUri }, fetchImpl = fetch) -> string` - POSTs `grant_type=authorization_code`, `code`, `redirect_uri`, `client_id`, `client_secret` (read from `provider.clientSecretFile`, trimmed, at call time), `code_verifier` as `application/x-www-form-urlencoded` to `doc.token_endpoint`; returns `id_token`; throws on non-2xx or a missing `id_token`.
  - `async verifyIdToken(provider, doc, token, { nonce, now = Math.floor(Date.now()/1000) }, fetchImpl = fetch) -> { sub, tid: string|null, email: string|null }` - throws `Error` whose message starts with `id_token:` on: malformed JWT, `alg` not `RS256`, unknown `kid` after one JWKS refresh, bad signature, `iss` mismatch (byte for byte with `provider.issuer`, or `provider.issuerTemplate` with `<tid>` replaced by the token's `tid` claim - a template provider with a token lacking `tid` is refused), `aud` not equal to `provider.clientId` (string or one-element array), `exp <= now`, `iat > now + 300` or `iat < now - 300`, `nonce` mismatch, `sub` missing.
  - `identityOf(provider, claims) -> string` - `oidc:<provider.slug>:<sub>`; for a template provider, `oidc:<slug>:<tid>/<sub>` so a personal and a work account with the same `sub` shape stay distinct.
  - JWKS cache per provider: `Map<slug, { keys: Map<kid, KeyObject>, at }>`, refreshed when a `kid` is unknown, at most once per verification.

- [ ] **Step 1: Write the failing test**

Append to `desk/test/oidc.test.mjs`:

```js
import { exchangeCode, verifyIdToken, identityOf } from '../oidc.mjs';
import { generateKeyPairSync } from 'node:crypto';

async function loginFixture(stubOpts = {}, provOver = {}) {
  const stub = await startStub(stubOpts);
  const secretDir = mkdtempSync(join(tmpdir(), 'desk-sec-'));
  writeFileSync(join(secretDir, 's'), 'shh-secret\n');
  const prov = Object.assign({
    slug: 'p', issuer: stub.issuer, issuerTemplate: null, clientId: 'cid',
    clientSecretFile: join(secretDir, 's'), discovery: stub.origin + '/.well-known/openid-configuration'
  }, provOver);
  const doc = await discover(prov);
  const begun = beginLogin(prov, doc, 'https://desk.example.test/desk/auth/callback');
  // Drive the stub's authorize endpoint as a browser would, so it records client_id and nonce.
  const r = await fetch(begun.url, { redirect: 'manual' });
  const back = new URL(r.headers.get('location'));
  return { stub, prov, doc, begun, code: back.searchParams.get('code'), state: back.searchParams.get('state') };
}

test('exchangeCode posts the form with the secret from the file and returns the id_token', async () => {
  const f = await loginFixture();
  const tok = await exchangeCode(f.prov, f.doc, { code: f.code, verifier: f.begun.verifier, redirectUri: 'https://desk.example.test/desk/auth/callback' });
  assert.equal(typeof tok, 'string');
  const call = f.stub.tokenCalls[0];
  assert.equal(call.form.get('grant_type'), 'authorization_code');
  assert.equal(call.form.get('client_secret'), 'shh-secret');
  assert.equal(call.form.get('code_verifier'), f.begun.verifier);
  await assert.rejects(exchangeCode(f.prov, f.doc, { code: 'WRONG', verifier: 'v', redirectUri: 'x' }), /token endpoint/);
  await f.stub.close();
});

test('a valid id_token verifies to its subject', async () => {
  const f = await loginFixture();
  const tok = await exchangeCode(f.prov, f.doc, { code: f.code, verifier: f.begun.verifier, redirectUri: 'https://desk.example.test/desk/auth/callback' });
  const claims = await verifyIdToken(f.prov, f.doc, tok, { nonce: f.begun.nonce });
  assert.deepEqual(claims, { sub: 'sub-1', tid: null, email: 'alice@example.test' });
  assert.equal(identityOf(f.prov, claims), 'oidc:p:sub-1');
  await f.stub.close();
});

test('every refusal the spec lists is a refusal', async () => {
  const f = await loginFixture();
  const now = Math.floor(Date.now() / 1000);
  const cases = [
    ['wrong aud', f.stub.mintIdToken({ aud: 'other' }), /id_token: aud/],
    ['wrong iss', f.stub.mintIdToken({ iss: 'https://evil.example.test' }), /id_token: iss/],
    ['expired', f.stub.mintIdToken({ exp: now - 1 }), /id_token: exp/],
    ['iat in the future', f.stub.mintIdToken({ iat: now + 600 }), /id_token: iat/],
    ['wrong nonce', f.stub.mintIdToken({ nonce: 'other' }), /id_token: nonce/],
    ['unknown kid', f.stub.mintIdToken({}, { kid: 'k9' }), /id_token: kid/],
    ['no sub', f.stub.mintIdToken({ sub: undefined }), /id_token: sub/],
    ['not a jwt', 'abc.def', /id_token: malformed/]
  ];
  const other = generateKeyPairSync('rsa', { modulusLength: 2048 });
  cases.push(['bad signature', f.stub.mintIdToken({}, { key: other.privateKey }), /id_token: signature/]);
  for (const [name, tok, re] of cases) {
    await assert.rejects(verifyIdToken(f.prov, f.doc, tok, { nonce: f.begun.nonce }), re, name);
  }
  await f.stub.close();
});

test('a template provider matches iss against the token tenant and keys identity by tenant', async () => {
  const f = await loginFixture({ issuer: 'https://login.example.test/tenant-1/v2.0', tid: 'tenant-1' },
    { issuer: null, issuerTemplate: 'https://login.example.test/<tid>/v2.0' });
  const tok = f.stub.mintIdToken();
  const claims = await verifyIdToken(f.prov, f.doc, tok, { nonce: f.begun.nonce });
  assert.equal(claims.tid, 'tenant-1');
  assert.equal(identityOf(f.prov, claims), 'oidc:p:tenant-1/sub-1');
  await assert.rejects(verifyIdToken(f.prov, f.doc, f.stub.mintIdToken({ tid: 'tenant-2' }), { nonce: f.begun.nonce }), /id_token: iss/);
  await assert.rejects(verifyIdToken(f.prov, f.doc, f.stub.mintIdToken({ tid: undefined }), { nonce: f.begun.nonce }), /id_token: tid/);
  await f.stub.close();
});
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd desk && node --test test/oidc.test.mjs`
Expected: FAIL - `exchangeCode` is not exported.

- [ ] **Step 3: Write minimal implementation**

Append to `desk/oidc.mjs`:

```js
import { createPublicKey, createVerify } from 'node:crypto';

export async function exchangeCode(provider, doc, { code, verifier, redirectUri }, fetchImpl = fetch) {
  // The secret is read at call time, never held: a rotated file takes effect
  // on the next login without a restart, and no copy lives in this process
  // between logins.
  const secret = readFileSync(provider.clientSecretFile, 'utf8').trim();
  const form = new URLSearchParams({
    grant_type: 'authorization_code', code, redirect_uri: redirectUri,
    client_id: provider.clientId, client_secret: secret, code_verifier: verifier
  });
  const res = await fetchImpl(doc.token_endpoint, {
    method: 'POST', body: form.toString(),
    headers: { 'content-type': 'application/x-www-form-urlencoded', accept: 'application/json' }
  });
  if (!res.ok) throw new Error('token endpoint for ' + provider.slug + ' answered ' + res.status);
  const body = await res.json();
  if (typeof body.id_token !== 'string' || !body.id_token) throw new Error('token endpoint for ' + provider.slug + ' returned no id_token');
  return body.id_token;
}

const jwksCache = new Map(); // slug -> { keys: Map<kid, KeyObject>, at }

async function jwksFor(provider, doc, kid, fetchImpl) {
  let entry = jwksCache.get(provider.slug);
  if (!entry || !entry.keys.has(kid)) {
    // Refresh once on an unknown kid (rotation), never more: a second miss is
    // a token this provider did not sign, not a cache that is behind.
    const res = await fetchImpl(doc.jwks_uri, { headers: { accept: 'application/json' } });
    if (!res.ok) throw new Error('jwks for ' + provider.slug + ' answered ' + res.status);
    const body = await res.json();
    const keys = new Map();
    for (const k of (body.keys || [])) {
      if (k.kty !== 'RSA' || !k.kid) continue;
      if (k.use && k.use !== 'sig') continue;
      keys.set(k.kid, createPublicKey({ key: k, format: 'jwk' }));
    }
    entry = { keys, at: Date.now() };
    jwksCache.set(provider.slug, entry);
  }
  return entry.keys.get(kid) || null;
}

const fromB64u = (s) => Buffer.from(s, 'base64url');
const refuse = (what) => { throw new Error('id_token: ' + what); };

export async function verifyIdToken(provider, doc, token, { nonce, now = Math.floor(Date.now() / 1000) }, fetchImpl = fetch) {
  const parts = String(token || '').split('.');
  if (parts.length !== 3) refuse('malformed');
  let header, claims;
  try {
    header = JSON.parse(fromB64u(parts[0]).toString('utf8'));
    claims = JSON.parse(fromB64u(parts[1]).toString('utf8'));
  } catch { refuse('malformed'); }
  if (!header || header.alg !== 'RS256') refuse('alg');
  if (typeof header.kid !== 'string') refuse('kid');
  const key = await jwksFor(provider, doc, header.kid, fetchImpl);
  if (!key) refuse('kid unknown');
  const ok = createVerify('RSA-SHA256').update(parts[0] + '.' + parts[1]).verify(key, fromB64u(parts[2]));
  if (!ok) refuse('signature');
  // From here the claims are the provider's words.
  let tid = null;
  if (provider.issuerTemplate) {
    if (typeof claims.tid !== 'string' || !/^[A-Za-z0-9-]+$/.test(claims.tid)) refuse('tid');
    tid = claims.tid;
    if (claims.iss !== provider.issuerTemplate.replace('<tid>', tid)) refuse('iss');
  } else if (claims.iss !== provider.issuer) refuse('iss');
  const aud = Array.isArray(claims.aud) ? (claims.aud.length === 1 ? claims.aud[0] : null) : claims.aud;
  if (aud !== provider.clientId) refuse('aud');
  if (typeof claims.exp !== 'number' || claims.exp <= now) refuse('exp');
  if (typeof claims.iat !== 'number' || Math.abs(claims.iat - now) > 300) refuse('iat');
  if (claims.nonce !== nonce) refuse('nonce');
  if (typeof claims.sub !== 'string' || !claims.sub) refuse('sub');
  return { sub: claims.sub, tid, email: typeof claims.email === 'string' ? claims.email : null };
}

export function identityOf(provider, claims) {
  return 'oidc:' + provider.slug + ':' + (claims.tid ? claims.tid + '/' : '') + claims.sub;
}
```

Move the `import { createPublicKey, createVerify }` line up to the module's import block (imports must lead the file); merge with the existing `node:crypto` import.

- [ ] **Step 4: Run test to verify it passes**

Run: `cd desk && node --test test/oidc.test.mjs`
Expected: PASS, 8 tests.

- [ ] **Step 5: Commit**

```bash
git add desk/oidc.mjs desk/test/oidc.test.mjs
git commit -m "desk front: the id_token is verified here - signature against JWKS, iss (or the tenant template), aud, exp, iat, nonce - and the identity is oidc:<slug>:<sub>"
```

---

### Task 6: the front server in `desk/serve.mjs`

**Files:**
- Modify: `desk/serve.mjs` (`deskPaths` :133-155, the mode block :186-204, new front server after the tailnet `server` :427-470, dispatch :531-536)
- Modify: `desk/render.mjs` (one new page: `pageLogin(providers, origin)`)
- Modify: `desk/test/serve.test.mjs` (front tests appended)

**Precondition:** `desk/bin/principal-for-login oidc <value>` is on `origin/main` (services plan Task 3) and this branch is rebased on it. Verify with `grep -n 'oidc' desk/bin/principal-for-login`.

**Interfaces:**
- Consumes: everything Tasks 1-5 export; `principal-for-login <source> <value>`; `principal-exists <slug>`; `desk-paths` lines `origin=`, `providers=`, `session_key=`.
- Produces:
  - Env knobs: `STEWARD_DESK_FRONT_LISTEN=<addr>:<port>` (enables the front), `STEWARD_DESK_FRONT_PEER=<addr>` (required with it; exit 64 when either is malformed or only one is set).
  - Startup, only when the front is enabled: `desk-paths` must print all three front lines (else exit 78 naming the missing one), `loadSessionKey(session_key)` (exit 78 on its error), `loadProviders(providers)` non-empty (exit 78), `accessSync(principal-exists, X_OK)` (exit 78).
  - Front routes (all other paths: same `ROUTES` as the tailnet, after the cookie gate):
    - `GET /desk/auth/login` - no `provider` query: 200, `pageLogin` (a list of one link per provider, `href="/desk/auth/login?provider=<slug>"`); with a known `provider`: set state cookie `__Host-desk-oauth` (600 s) and `303` to the authorization URL; unknown provider: 404 `NOT_FOUND`.
    - `GET /desk/auth/callback?code&state` - state cookie missing/invalid/mismatched `state`: 403 `FORBIDDEN`, clear the state cookie. Exchange + verify (any throw: 403 `FORBIDDEN`, logged once to stderr with the error class only, never the token). Identity resolves via `principal-for-login oidc <identity>`: rc 0 -> set `__Host-desk-session` (43200 s), clear the state cookie, `303 /desk/`; rc 1/65 -> 403 `FORBIDDEN`; other -> 503 `NO_MEASUREMENT`. (The services plan's invitation flow adds its branch at the rc 1 point; leave the comment `// invitation binding attaches here (services plan)` on that line.)
    - `POST /desk/auth/logout` - requires `sec-fetch-site: same-origin` and, when `origin` header present, `origin === FRONT_ORIGIN`; otherwise 403. Clears the session cookie, `303 /desk/auth/login`.
    - any `/desk/auth/*` request first passes the rate limiter (10 per 60 s per visitor address); over it: 429 with `retry-after: 60`, body `NOT_FOUND`-shaped emptiness is wrong here - use a fixed body `TOO_MANY = 'Too many requests.'`.
    - everything else: no valid session cookie -> `303 /desk/auth/login`; valid cookie but `principal-exists` rc 1 -> 403 `FORBIDDEN` and clear the cookie; rc 78/other -> 503; else the tailnet's route table and snapshot logic with `principal` from the cookie.
  - The front never reads `tailscale-user-login`; the tailnet server never reads `cookie`. The self-origin check (`SELF_ADDRS`) is not applied on the front; the peer check replaces it: a socket peer other than `FRONT_PEER` gets 403 with `content-type: text/plain` and body `PEER_FORBIDDEN = 'Forbidden: not the front peer.'`, before anything else is read.
  - Front headers = `HEADERS` with CSP `form-action 'self'` (the logout form) instead of `'none'`.
  - The redirect URI sent to the provider is `FRONT_ORIGIN + '/desk/auth/callback'` where `FRONT_ORIGIN` is the `origin=` line.

- [ ] **Step 1: Write the failing tests**

Append to `desk/test/serve.test.mjs` (reuse `T`, `ROOT`, `HOME`, `DESK`, `GEN`, `buildEstate`, `childEnv`, `freePort`, `spawnUpTcp`, `reqHttp`, `stopSpawned`, `writeB`-style snapshot writers already in the file; read lines 85-300 first for their exact shapes):

```js
import { startStub } from './oidc-stub.mjs';
import { mintSession } from '../cookie.mjs';

// The front: a second listener, identity from a cookie the desk issued.
describe('the front listener', () => {
  let stub, port, peerHandle, KEYFILE;
  const FRONT_ORIGIN = 'https://desk.example.test';
  const cookieOf = (res) => (res.headers['set-cookie'] || []).map((c) => c.split(';')[0]);

  function frontEstate() {
    buildEstate(ROOT);
    appendFileSync(join(ROOT, 'estate', 'steward.conf'),
      'DESK_ORIGIN="' + FRONT_ORIGIN + '"\nDESK_SESSION_KEY_FILE="' + KEYFILE + '"\n');
    mkdirSync(join(ROOT, 'desk', 'providers.d'), { recursive: true });
    writeFileSync(join(T, 'secret'), 'shh\n');
    writeFileSync(join(ROOT, 'desk', 'providers.d', 'stub.conf'),
      'ISSUER="' + stub.issuer + '"\nDISCOVERY="' + stub.origin + '/.well-known/openid-configuration"\nCLIENT_ID="cid"\nCLIENT_SECRET_FILE="' + join(T, 'secret') + '"\n');
    // e binds by OIDC identity; a (read-all) and b keep their tailnet logins.
    writeFileSync(join(ROOT, 'principals.d', 'e.conf'), 'NAME="Eve"\nOIDC_LOGIN="stub:sub-1"\n');
  }

  before(async () => {
    stub = await startStub();
    KEYFILE = join(T, 'session.key');
    writeFileSync(KEYFILE, 'k'.repeat(44) + '\n'); chmodSync(KEYFILE, 0o600);
    frontEstate();
    writeFileSync(join(GEN, 'e.json'), JSON.stringify(snapshotFor('e', false, [])));
    port = await freePort();
    peerHandle = await spawnUpTcp(childEnv({
      STEWARD_DESK_FRONT_LISTEN: '127.0.0.1:' + port, STEWARD_DESK_FRONT_PEER: '127.0.0.1'
    }), '127.0.0.1', port, 5000);
  });
  after(async () => { await stopSpawned(peerHandle); await stub.close(); });

  const front = (method, path, headers) => reqHttp('127.0.0.1', port, method, path, headers);

  it('starts both listeners: the socket still answers the header, the front ignores it', async () => {
    const viaSock = await req('GET', '/desk/', { [B]: 'b@example.com' });
    assert.equal(viaSock.status, 200);
    const viaFront = await front('GET', '/desk/', { [B]: 'b@example.com' });
    assert.equal(viaFront.status, 303);
    assert.equal(viaFront.headers.location, '/desk/auth/login');
  });

  it('the socket ignores a cookie', async () => {
    const key = Buffer.from('k'.repeat(44));
    const r = await req('GET', '/desk/', { cookie: '__Host-desk-session=' + mintSession(key, 'b', Math.floor(Date.now() / 1000)) });
    assert.equal(r.status, 403);
  });

  it('logs in end to end and lands on the desk as the bound principal', async () => {
    const chooser = await front('GET', '/desk/auth/login');
    assert.equal(chooser.status, 200);
    assert.match(chooser.body, /href="\/desk\/auth\/login\?provider=stub"/);
    const go = await front('GET', '/desk/auth/login?provider=stub');
    assert.equal(go.status, 303);
    const state = cookieOf(go).find((c) => c.startsWith('__Host-desk-oauth='));
    assert.ok(state);
    const back = await fetch(go.headers.location, { redirect: 'manual' });
    const cb = new URL(back.headers.get('location'));
    assert.equal(cb.origin + cb.pathname, FRONT_ORIGIN + '/desk/auth/callback');
    const done = await front('GET', cb.pathname + cb.search, { cookie: state });
    assert.equal(done.status, 303);
    assert.equal(done.headers.location, '/desk/');
    const session = cookieOf(done).find((c) => c.startsWith('__Host-desk-session='));
    assert.ok(session);
    const page = await front('GET', '/desk/', { cookie: session });
    assert.equal(page.status, 200);
    assert.match(page.body, /Eve/);
    assert.match(page.headers['content-security-policy'], /form-action 'self'/);
  });

  it('a callback without its state cookie, or with a foreign state, is refused', async () => {
    const r1 = await front('GET', '/desk/auth/callback?code=CODE&state=x');
    assert.equal(r1.status, 403);
    const go = await front('GET', '/desk/auth/login?provider=stub');
    const state = cookieOf(go).find((c) => c.startsWith('__Host-desk-oauth='));
    const r2 = await front('GET', '/desk/auth/callback?code=CODE&state=other', { cookie: state });
    assert.equal(r2.status, 403);
    assert.equal(cookieOf(r2).some((c) => c.startsWith('__Host-desk-session=')), false);
  });

  it('a removed principal is out on the next request with a still-valid cookie', async () => {
    const key = Buffer.from('k'.repeat(44));
    const cookie = '__Host-desk-session=' + mintSession(key, 'e', Math.floor(Date.now() / 1000));
    assert.equal((await front('GET', '/desk/', { cookie })).status, 200);
    unlinkSync(join(ROOT, 'principals.d', 'e.conf'));
    const gone = await front('GET', '/desk/', { cookie });
    assert.equal(gone.status, 403);
    writeFileSync(join(ROOT, 'principals.d', 'e.conf'), 'NAME="Eve"\nOIDC_LOGIN="stub:sub-1"\n');
  });

  it('a cookie forged under another key, or tampered, is not a session', async () => {
    const bad = '__Host-desk-session=' + mintSession(Buffer.from('x'.repeat(44)), 'e', Math.floor(Date.now() / 1000));
    const r = await front('GET', '/desk/', { cookie: bad });
    assert.equal(r.status, 303);
  });

  it('logout needs same-origin and a matching Origin, then clears the cookie', async () => {
    const key = Buffer.from('k'.repeat(44));
    const cookie = '__Host-desk-session=' + mintSession(key, 'e', Math.floor(Date.now() / 1000));
    assert.equal((await front('POST', '/desk/auth/logout', { cookie })).status, 403);
    assert.equal((await front('POST', '/desk/auth/logout', { cookie, 'sec-fetch-site': 'cross-site' })).status, 403);
    assert.equal((await front('POST', '/desk/auth/logout', { cookie, 'sec-fetch-site': 'same-origin', origin: 'https://evil.example.test' })).status, 403);
    const ok = await front('POST', '/desk/auth/logout', { cookie, 'sec-fetch-site': 'same-origin', origin: FRONT_ORIGIN });
    assert.equal(ok.status, 303);
    assert.ok(cookieOf(ok).includes('__Host-desk-session='));
  });

  it('rate limits the auth paths per visitor address', async () => {
    let last;
    for (let i = 0; i < 11; i++) last = await front('GET', '/desk/auth/login', { 'x-real-ip': '203.0.113.77' });
    assert.equal(last.status, 429);
    const other = await front('GET', '/desk/auth/login', { 'x-real-ip': '203.0.113.78' });
    assert.equal(other.status, 200);
  });

  it('refuses to start on a public bind, without a peer, or with a peer off the tailnet', async () => {
    for (const over of [
      { STEWARD_DESK_FRONT_LISTEN: '0.0.0.0:18443', STEWARD_DESK_FRONT_PEER: '127.0.0.1' },
      { STEWARD_DESK_FRONT_LISTEN: '127.0.0.1:18443' },
      { STEWARD_DESK_FRONT_LISTEN: '127.0.0.1:18443', STEWARD_DESK_FRONT_PEER: '203.0.113.1' }
    ]) {
      const r = await runToExit(childEnv(over));
      assert.equal(r.code, 64, JSON.stringify(over));
    }
  });
});

// A front whose peer is not us: every request is refused before identity is read.
describe('the front peer gate', () => {
  it('refuses a socket peer other than the configured box', async () => {
    const port = await freePort();
    const h = await spawnUpTcp(childEnv({
      STEWARD_DESK_FRONT_LISTEN: '127.0.0.1:' + port, STEWARD_DESK_FRONT_PEER: '100.64.0.9'
    }), '127.0.0.1', port, 5000);
    const r = await reqHttp('127.0.0.1', port, 'GET', '/desk/auth/login');
    assert.equal(r.status, 403);
    assert.equal(r.headers['content-type'], 'text/plain; charset=utf-8');
    await stopSpawned(h);
  });
});
```

Add `appendFileSync`, `chmodSync`, `unlinkSync`, `mkdirSync` to the `node:fs` import at the top of the file if missing, and `describe`, `it`, `before`, `after` from `node:test`. The existing `before` hooks build the estate for the tailnet tests; the front `describe` rebuilds its own rows in its `before` and must run after them (append at the end of the file). If the file's existing hooks start a socket-mode child that is still alive, the front child must use a different `STEWARD_DESK_SOCK` (`childEnv({ STEWARD_DESK_SOCK: join(T, 'front.sock'), … })`) so both can bind.

- [ ] **Step 2: Run test to verify it fails**

Run: `cd desk && node --test test/serve.test.mjs`
Expected: the new describe blocks FAIL (the child exits 64 - unknown front env is ignored today, so the front port never opens and `spawnUpTcp` times out; or `runToExit` returns 0).

- [ ] **Step 3: Write minimal implementation**

In `desk/render.mjs`, after `pageSession`, add and export:

```js
// pageLogin - the front's only page for a stranger: one link per provider.
// No snapshot is read, so nothing about the estate is on it.
export function pageLogin(providers) {
  const items = [...providers.keys()].sort().map((slug) =>
    '<li><a href="/desk/auth/login?provider=' + escapeHtml(slug) + '">Log in with ' + escapeHtml(slug) + '</a></li>').join('');
  return LAYOUT('Log in', '<h1>Steward Desk</h1><p>Log in with the account you were invited with.</p><ul>' + items + '</ul>', null);
}
```

Check `LAYOUT(title, body, snap)` at `desk/render.mjs:58` tolerates `snap === null` (it prints a footer from `snap`); if it does not, add `snap ? … : ''` around the footer's snapshot reads.

In `desk/serve.mjs`:

1. Imports: add
   ```js
   import { pageIndex, pageTeam, pageProject, pageSession, pageLogin } from './render.mjs';
   import { normalizeAddr, parseFrontListen, parseFrontPeer, visitorAddress, RateLimiter } from './front.mjs';
   import { parseCookies, serializeCookie, loadSessionKey, mintSession, verifySession, mintState, verifyState } from './cookie.mjs';
   import { loadProviders, discover, beginLogin, exchangeCode, verifyIdToken, identityOf } from './oidc.mjs';
   ```
2. `deskPaths()` :133-155: widen the regex to `/^(dir|sock|origin|providers|session_key)=(.+)$/` and keep the `dir`/`sock` requirement as is.
3. After the mode block (:204), add the front's configuration:
   ```js
   const FRONT_LISTEN_RAW = process.env.STEWARD_DESK_FRONT_LISTEN;
   const FRONT_PEER_RAW = process.env.STEWARD_DESK_FRONT_PEER;
   let FRONT = null;
   if (FRONT_LISTEN_RAW || FRONT_PEER_RAW) {
     if (!FRONT_LISTEN_RAW || !FRONT_PEER_RAW) {
       console.error('desk: STEWARD_DESK_FRONT_LISTEN and STEWARD_DESK_FRONT_PEER must be set together');
       process.exit(64);
     }
     let listen, peer;
     try { listen = parseFrontListen(FRONT_LISTEN_RAW); peer = parseFrontPeer(FRONT_PEER_RAW); } catch (e) {
       console.error('desk: ' + e.message); process.exit(64);
     }
     const p = deskPaths();
     for (const k of ['origin', 'providers', 'session_key']) {
       if (!p[k]) { console.error('desk: the front needs a ' + k + '= line from desk-paths (DESK_ORIGIN, desk/providers.d, DESK_SESSION_KEY_FILE in the estate)'); process.exit(78); }
     }
     let key, providers;
     try { key = loadSessionKey(p.session_key); } catch (e) { console.error('desk: ' + e.message); process.exit(78); }
     try { providers = loadProviders(p.providers); } catch (e) { console.error('desk: ' + e.message); process.exit(78); }
     if (providers.size === 0) { console.error('desk: desk/providers.d names no provider'); process.exit(78); }
     const EXISTS = join(HERE, 'bin', 'principal-exists');
     try { accessSync(EXISTS, constants.X_OK); } catch { console.error('desk: ' + EXISTS + ' is missing or not executable'); process.exit(78); }
     FRONT = { listen, peer, origin: p.origin, key, providers, exists: EXISTS, limiter: new RateLimiter(10, 60000) };
   }
   ```
4. Beside `principalFor`, add the two-argument lookup and the existence check:
   ```js
   // principalForIdentity - the same bridge, the two-argument form: a source and
   // a value. Same rc reading as principalFor.
   function principalForIdentity(source, value) {
     if (!/^[A-Za-z0-9._%+@:\/-]{1,300}$/.test(value)) return { slug: null, outage: false };
     let out;
     try {
       out = execFileSync(LOOKUP, [source, value], { encoding: 'utf8', timeout: 5000, stdio: ['ignore', 'pipe', 'pipe'] });
     } catch (e) {
       if (e && (e.status === 1 || e.status === 65)) return { slug: null, outage: false };
       logBridgeOutage(source + ':' + value, e);
       return { slug: null, outage: true };
     }
     const slug = out.trim();
     if (slug && SLUG_RE.test(slug)) return { slug, outage: false };
     logBridgeOutage(source + ':' + value, null);
     return { slug: null, outage: true };
   }

   // principalExists - rc 0 yes, 1 no, anything else an outage.
   function principalExists(slug) {
     try {
       execFileSync(FRONT.exists, [slug], { timeout: 5000, stdio: ['ignore', 'ignore', 'pipe'] });
       return { exists: true, outage: false };
     } catch (e) {
       if (e && e.status === 1) return { exists: false, outage: false };
       logBridgeOutage(slug, e);
       return { exists: false, outage: true };
     }
   }
   ```
5. Extract the tailnet handler's tail (from `let path;` through `send(res, 200, html)`) into `function servePage(req, res, principal, headers)` that takes the header set to use, and call it from the tailnet handler with `HEADERS`. Then the front server:
   ```js
   const FRONT_HEADERS = Object.assign({}, HEADERS, {
     'content-security-policy': HEADERS['content-security-policy'].replace("form-action 'none'", "form-action 'self'")
   });
   const PEER_FORBIDDEN = 'Forbidden: not the front peer.';
   const TOO_MANY = 'Too many requests.';
   const SESSION = '__Host-desk-session';
   const STATE = '__Host-desk-oauth';
   const nowSec = () => Math.floor(Date.now() / 1000);
   const clear = (name) => serializeCookie(name, '', { maxAge: 0 });

   function frontServer() {
     return http.createServer(async (req, res) => {
       const visitor = visitorAddress(req, FRONT.peer);
       if (visitor === null) {
         console.error('desk front: refused peer ' + normalizeAddr(req.socket.remoteAddress));
         return send(res, 403, PEER_FORBIDDEN, Object.assign({}, FRONT_HEADERS, { 'content-type': 'text/plain; charset=utf-8' }));
       }
       let url;
       try { url = new URL(req.url, FRONT.origin); } catch { return send(res, 404, NOT_FOUND, FRONT_HEADERS); }
       const path = url.pathname;
       const cookies = parseCookies(req.headers.cookie);

       if (path.startsWith('/desk/auth/')) {
         if (!FRONT.limiter.hit(visitor, Date.now())) return send(res, 429, TOO_MANY, Object.assign({}, FRONT_HEADERS, { 'retry-after': '60', 'content-type': 'text/plain; charset=utf-8' }));
         if (path === '/desk/auth/login' && req.method === 'GET') return authLogin(url, res);
         if (path === '/desk/auth/callback' && req.method === 'GET') return authCallback(url, cookies, res);
         if (path === '/desk/auth/logout' && req.method === 'POST') return authLogout(req, res);
         return send(res, 404, NOT_FOUND, FRONT_HEADERS);
       }
       if (req.method !== 'GET' && req.method !== 'HEAD') return send(res, 405, '', Object.assign({}, FRONT_HEADERS, { allow: 'GET, HEAD' }));

       // IDENTITY IS THE COOKIE, AND THE ROW MUST STILL BE THERE.
       const principal = verifySession(FRONT.key, cookies.get(SESSION), nowSec());
       if (!principal) return send(res, 303, '', Object.assign({}, FRONT_HEADERS, { location: '/desk/auth/login' }));
       const { exists, outage } = principalExists(principal);
       if (outage) return send(res, 503, NO_MEASUREMENT, FRONT_HEADERS);
       if (!exists) return send(res, 403, FORBIDDEN, Object.assign({}, FRONT_HEADERS, { 'set-cookie': clear(SESSION) }));
       return servePage(req, res, principal, FRONT_HEADERS);
     });
   }

   async function authLogin(url, res) {
     const slug = url.searchParams.get('provider');
     if (slug === null) return send(res, 200, pageLogin(FRONT.providers), FRONT_HEADERS);
     const provider = FRONT.providers.get(slug);
     if (!provider) return send(res, 404, NOT_FOUND, FRONT_HEADERS);
     let doc;
     try { doc = await discover(provider); } catch (e) { console.error('desk front: discovery failed for ' + slug + ': ' + e.message); return send(res, 503, NO_MEASUREMENT, FRONT_HEADERS); }
     const begun = beginLogin(provider, doc, FRONT.origin + '/desk/auth/callback');
     const state = mintState(FRONT.key, { state: begun.state, nonce: begun.nonce, verifier: begun.verifier, provider: slug, issuedAt: nowSec() });
     return send(res, 303, '', Object.assign({}, FRONT_HEADERS, { location: begun.url, 'set-cookie': serializeCookie(STATE, state, { maxAge: 600 }) }));
   }

   async function authCallback(url, cookies, res) {
     const fields = verifyState(FRONT.key, cookies.get(STATE), nowSec());
     const refuse = () => send(res, 403, FORBIDDEN, Object.assign({}, FRONT_HEADERS, { 'set-cookie': clear(STATE) }));
     if (!fields || url.searchParams.get('state') !== fields.state) return refuse();
     const provider = FRONT.providers.get(fields.provider);
     const code = url.searchParams.get('code');
     if (!provider || !code) return refuse();
     let claims;
     try {
       const doc = await discover(provider);
       const token = await exchangeCode(provider, doc, { code, verifier: fields.verifier, redirectUri: FRONT.origin + '/desk/auth/callback' });
       claims = await verifyIdToken(provider, doc, token, { nonce: fields.nonce });
     } catch (e) {
       // The reason is for the operator's log; the visitor gets the same 403 as
       // every other refusal. The token itself is never logged.
       console.error('desk front: login refused (' + fields.provider + '): ' + String(e && e.message).split('\n')[0]);
       return refuse();
     }
     const identity = identityOf(provider, claims);
     const { slug, outage } = principalForIdentity('oidc', identity.slice('oidc:'.length));
     if (outage) return send(res, 503, NO_MEASUREMENT, FRONT_HEADERS);
     if (!slug) return refuse(); // invitation binding attaches here (services plan)
     const session = mintSession(FRONT.key, slug, nowSec());
     return send(res, 303, '', Object.assign({}, FRONT_HEADERS, {
       location: '/desk/',
       'set-cookie': [serializeCookie(SESSION, session, { maxAge: 43200 }), clear(STATE)]
     }));
   }

   function authLogout(req, res) {
     if (req.headers['sec-fetch-site'] !== 'same-origin') return send(res, 403, FORBIDDEN, FRONT_HEADERS);
     if (req.headers.origin !== undefined && req.headers.origin !== FRONT.origin) return send(res, 403, FORBIDDEN, FRONT_HEADERS);
     return send(res, 303, '', Object.assign({}, FRONT_HEADERS, { location: '/desk/auth/login', 'set-cookie': clear(SESSION) }));
   }
   ```
   `send(res, status, body, extra)` at :335 merges `extra` over `HEADERS`; since `FRONT_HEADERS` already carries every header, passing it as `extra` yields the front set. Check that `send` writes `set-cookie` arrays correctly (`res.writeHead` accepts an array value); if it stringifies, use `res.setHeader` for that one key inside `send` when the value is an array.
6. Dispatch (:531-536): after the tailnet listen, add
   ```js
   if (FRONT) {
     const fs2 = frontServer();
     fs2.on('error', (e) => { console.error('desk: could not bind the front at ' + FRONT.listen.host + ':' + FRONT.listen.port + ': ' + (e && e.code ? e.code : e)); process.exit(64); });
     fs2.listen(FRONT.listen.port, FRONT.listen.host, () => {
       console.error('desk: front listening on ' + FRONT.listen.host + ':' + FRONT.listen.port + ' for peer ' + FRONT.peer);
     });
     for (const sig of ['SIGTERM', 'SIGINT']) process.on(sig, () => fs2.close());
   }
   ```
7. The `principal-for-login` value regex for `oidc` identities: `principalForIdentity` strips the `oidc:` prefix and passes `<slug>:<sub>` (or `<slug>:<tid>/<sub>`) as the value, matching the `OIDC_LOGIN` word form of the services plan (`<issuer-slug>:<subject>`). Confirm against `docs/superpowers/plans/2026-09-08-desk-services-registry.md` Task 1 that a `/` inside the subject is accepted by its word regex; if not, use `<tid>.<sub>`-style joining in `identityOf` (Task 5) and update its test.

- [ ] **Step 4: Run tests to verify they pass**

Run: `cd desk && node --test test/*.mjs` then `bash test/desk-serve.test.sh`
Expected: all green, including the pre-existing tailnet suites (the header-set test at `serve.test.mjs:390` still sees exactly `HEADERS` on the socket).

- [ ] **Step 5: Commit**

```bash
git add desk/serve.mjs desk/render.mjs desk/test/serve.test.mjs
git commit -m "desk front: a second listener for one peer - login by provider, the callback verifies the token here, the cookie is the identity, the row is checked on every click"
```

---

### Task 7: shipping and the operator's words

**Files:**
- Modify: `linux/deploy-manifest:174-182` (four rows)
- Modify: `linux/steward-desk.service:15-19` (header note)
- Modify: `desk/SCHEMA.md` (new section after "Reaching it from the tailnet", :152-216)
- Modify: `README.md:12-33` (one bullet)
- Modify: `docs/superpowers/specs/2026-09-08-desk-front-design.md:75-77` (the loopback widening)

**Interfaces:**
- Consumes: the file names from Tasks 1-6.

- [ ] **Step 1: Run the guards to see them fail**

Run: `bash test/deploy-manifest.test.sh; bash test/language.test.sh`
Expected: deploy-manifest FAILS naming `desk/front.mjs`, `desk/cookie.mjs`, `desk/oidc.mjs`, `desk/bin/principal-exists` as shipped-directory files without a row (read the failure text; if the test does not sweep `desk/`, it passes and step 3 still adds the rows). language passes or names a line to fix.

- [ ] **Step 2: Add the manifest rows**

After the `desk/bin/principal-for-login` row in `linux/deploy-manifest` add:

```
desk/front.mjs                   scripts/desk/front.mjs               644  scripts
desk/cookie.mjs                  scripts/desk/cookie.mjs              644  scripts
desk/oidc.mjs                    scripts/desk/oidc.mjs                644  scripts
desk/bin/principal-exists        scripts/desk/bin/principal-exists    755  scripts
```

- [ ] **Step 3: The unit header**

Append to the header comment of `linux/steward-desk.service` (after line 19):

```
# THE FRONT IS THE ESTATE'S CHOICE, SO ITS TWO KNOBS ARE NOT HERE EITHER. A host
# with a public front sets STEWARD_DESK_FRONT_LISTEN and STEWARD_DESK_FRONT_PEER
# in a drop-in the estate deploys (steward-desk.service.d/50-estate.conf); the
# product's unit stays the same file on every host. Everything else the front
# needs - origin, providers, key file - is read from the estate through
# desk/bin/desk-paths, never from here.
```

- [ ] **Step 4: The operator section in `desk/SCHEMA.md`**

After the "Reaching it from the tailnet" section, add:

````markdown
### Reaching it from the public front

A second door for people who are not on the tailnet: a public proxy box
terminates TLS for the estate's hostname and forwards to a second listener
on this host's tailnet address. The box holds no secret; the OpenID Connect
login runs here. Design: `docs/superpowers/specs/2026-09-08-desk-front-design.md`.

The estate provides, in this order:

1. `DESK_ORIGIN="https://<public hostname>"` and
   `DESK_SESSION_KEY_FILE="<absolute path>"` in `estate/steward.conf`. The key
   file is generated once, 0600, owned by the desk account, at least 32
   bytes: `umask 077; head -c 32 /dev/urandom | base64 > <path>`.
2. `desk/providers.d/<slug>.conf` beside the registry, one per provider:
   `ISSUER` (or `ISSUER_TEMPLATE` with a literal `<tid>` for a multi-tenant
   provider that discovers through a common endpoint), `DISCOVERY`,
   `CLIENT_ID`, `CLIENT_SECRET_FILE` (0600, the desk account's). The
   provider's redirect URI is `<DESK_ORIGIN>/desk/auth/callback`.
3. A drop-in `~/.config/systemd/user/steward-desk.service.d/50-estate.conf`:

       [Service]
       Environment=STEWARD_DESK_FRONT_LISTEN=<this host's tailnet addr>:<port>
       Environment=STEWARD_DESK_FRONT_PEER=<the box's tailnet addr>

   The bind must be a tailnet (100.64.0.0/10) or loopback address; the desk
   exits 64 on anything else. The peer is the only address whose requests
   are answered; every other peer gets a plain-text 403 before identity is
   read.
4. The tailnet ACL lets only the box's tag reach this host on that port.
5. The box: a reverse proxy with automatic certificates, forwarding to
   `<tailnet addr>:<port>` with the visitor's address as `X-Real-IP`.

What a visitor sees: `/desk/auth/login` lists the providers; after the
provider's login the desk verifies the `id_token` (signature against the
provider's JWKS, issuer, audience, expiry, nonce), maps
`oidc:<slug>:<subject>` to a principal row through `desk/bin/principal-for-login`
and sets `__Host-desk-session` for 12 hours. Every request re-checks that the
principal row still exists (`desk/bin/principal-exists`), so removing a row
logs the person out on their next click. `POST /desk/auth/logout` clears the
cookie. `/desk/auth/*` is rate limited to 10 requests per minute per visitor.

The front never reads the `tailscale-user-login` header; the tailnet socket
never reads a cookie.
````

- [ ] **Step 5: README bullet and the spec note**

In `README.md`'s "What it is" list, extend the Desk bullet (or add one) with: `a public front (OpenID Connect login, the box is only a proxy) - desk/SCHEMA.md, "Reaching it from the public front"`.

In the spec at :75-77 replace `The listener binds the tailnet address only - never 0.0.0.0 - and refuses to start when the address is not a CGNAT (100.64.0.0/10) address.` with `The listener binds the tailnet address (CGNAT, 100.64.0.0/10) or a loopback address - never 0.0.0.0 or :: - and refuses to start on anything else. Loopback is allowed because it reaches nobody off the host and the test suite needs it (plan 2026-09-08-desk-front.md).`

- [ ] **Step 6: Run the whole aggregate**

Run: `bash tools/run-tests.sh .`
Expected: `suites found=N ran=N red=0 silent=0`.

- [ ] **Step 7: Commit**

```bash
git add linux/deploy-manifest linux/steward-desk.service desk/SCHEMA.md README.md docs/superpowers/specs/2026-09-08-desk-front-design.md
git commit -m "desk front: shipped - manifest rows, the unit's drop-in rule, the operator's section, the loopback widening recorded in the spec"
```

---

## Self-review

**Spec coverage.** Two listeners / two carriers (Task 6: cookie ignored on socket, header ignored on front - tested). Proxy-only box, secret on host (Task 5 reads the secret file at call time). TCP front on tailnet address, CGNAT check, peer refusal, X-Real-IP trusted from peer only (Tasks 1, 6). OIDC steps 1-6 (Tasks 4-6: state cookie 10 min, PKCE, JWKS cache with one refresh, iss/template+tid, aud, exp, iat skew, nonce, tid recorded, identity `oidc:<slug>:<sub>`, session cookie 12 h self-contained, principal re-resolved per request, logout). Provider config in `desk/providers.d` (Task 4). Cross-site rules: SameSite=Lax on every cookie (Task 2), `Sec-Fetch-Site` + `Origin` on the state-changing POST (Task 6); the form nonce belongs to the companion spec's order forms and is built there. Rate limit 10/min (Task 6). Operator docs and estate steps (Task 7). Tests listed in the spec's "Tests" section: valid login binds (6), wrong aud/iss/exp/kid/nonce/signature refused (5), wrong carrier does not render (6), removed principal refused (6), cross-site POST refused (6), non-CGNAT bind and foreign peer refused (6), X-Real-IP ignored from another peer (1). **Not covered here, by design:** the rig section and the invitation binding branch (separate plans, named above).

**Placeholder scan.** No TBD/TODO. The one forward reference, "invitation binding attaches here", is a comment marking a seam for another plan, with the exact rc branch named.

**Type consistency.** `parseFrontListen -> {host, port}` used in Task 6 as `FRONT.listen.host/.port`; `visitorAddress(req, peer) -> string|null` used as such; `verifySession(key, value, now)` returns the slug string; `mintState/verifyState` field names `state, nonce, verifier, provider, issuedAt` match between Tasks 2 and 6; `discover(provider) -> doc` with `authorization_endpoint/token_endpoint/jwks_uri` used by `beginLogin/exchangeCode/verifyIdToken`; `identityOf` returns `oidc:<slug>:...` and Task 6 strips the prefix before the bridge call.
