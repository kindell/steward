// desk/order.mjs - what the desk is allowed to write, and the checks that come
// before it writes.
//
// THE SERVER WRITES EXACTLY ONE KIND OF FILE, INTO EXACTLY ONE DIRECTORY, and
// nothing else, ever. A button is a <form method="post">; the server validates the
// request and appends one order to the spool. Everything that ACTS on an order is a
// separate, privileged process reading that directory - the desk itself is a
// read-only view on a socket and must stay one.
//
// THIS FILE IS THE PURE HALF, for the same reason desk/bridge.mjs is: a validation
// chain that can only be exercised through a running server is a validation chain
// tested through whatever the server is willing to produce. Every refusal below is
// reachable from a unit test with a plain object.

import { createHmac, timingSafeEqual, randomBytes } from 'node:crypto';
import { statSync, readFileSync } from 'node:fs';

const b64u = (buf) => Buffer.from(buf).toString('base64url');

// THE FORM KEY IS ITS OWN KEY, NOT THE SESSION KEY, and the reason is that they
// answer different questions. The session key signs a cookie that says WHO a
// returning visitor is; this one signs a token that says WHICH PAGE a form came
// from. Signing both under one key would mean a value minted for one could verify
// as the other unless a label kept them apart - and the label is what does that in
// cookie.mjs, between two purposes on the same listener. These two are on DIFFERENT
// listeners: the tailnet desk has no session key at all, and it is where most
// buttons will be.
//
// ONE KEY FOR BOTH LISTENERS, THOUGH. The front and the tailnet desk render the
// same forms for the same principals; two form keys would mean a page rendered by
// one could not be posted to the other, which is a difference nobody asked for.
//
// THE REFUSALS ARE THE SESSION KEY'S, DELIBERATELY IDENTICAL: an operator who has
// installed one of these has learned the shape of both, and a second vocabulary for
// the same class of file is a second thing to get wrong.
export function loadFormKey(path) {
  let st;
  try { st = statSync(path); } catch { throw new Error('form key file is missing'); }
  if ((st.mode & 0o777) !== 0o600) throw new Error('form key file must be mode 0600');
  if (st.uid !== process.getuid()) throw new Error('form key file must be owned by the desk account');
  const key = Buffer.from(readFileSync(path, 'utf8').trim());
  if (key.length < 32) throw new Error('form key must be at least 32 bytes');
  return key;
}

// THE NONCE BINDS A FORM TO A PRINCIPAL AND A GENERATION. A page rendered from
// generation N carries a nonce for N; when the snapshot moves on, that page can no
// longer order. That is the whole of its job - the identity is settled before this
// by the listener (a tailnet header the proxy sets, or a session cookie), and
// cross-site posting is refused by Sec-Fetch-Site.
//
// IT IS STILL A SECRET RATHER THAN A PLAIN GENERATION NUMBER, and that was a
// decision rather than an inheritance. On the tailnet the identity check already
// carries the weight, so an unsigned token would do today's job - and that is
// exactly the argument that ages badly. A listener without a trusted identity
// header is not hypothetical; the front is one. Quietly replacing a specified
// control with a weaker one because it happens to be redundant in today's
// deployment is how the redundancy stops being redundant unnoticed.
//
// THE PRINCIPAL IS IN THE MAC AND NOT ONLY BESIDE IT, so a nonce minted for one
// person's page cannot be posted as another's even where the identity check is
// weaker than it is here.
export function mintNonce(key, principal, generation) {
  return b64u(createHmac('sha256', key).update('form ' + principal + ' ' + generation).digest());
}

// TIMING-SAFE, AND LENGTH-CHECKED FIRST because timingSafeEqual throws on a length
// mismatch rather than returning false - an unequal-length value must be a refusal,
// never an exception that reaches a handler expecting a boolean.
export function verifyNonce(key, value, principal, generation) {
  const want = Buffer.from(mintNonce(key, principal, generation));
  const got = Buffer.from(String(value || ''));
  return want.length === got.length && timingSafeEqual(want, got);
}

// ULID-SHAPED, NOT A ULID LIBRARY. What the spool needs from an id is that it sorts
// oldest-first as a filename and never collides; a 48-bit millisecond timestamp in
// Crockford base32 followed by 80 bits of randomness gives both, and the apply step
// can read the order of work off `ls` without parsing anything.
const C32 = '0123456789ABCDEFGHJKMNPQRSTVWXYZ';
export function orderId(now = Date.now(), rnd = randomBytes) {
  let t = '';
  let ms = now;
  for (let i = 0; i < 10; i++) { t = C32[ms % 32] + t; ms = Math.floor(ms / 32); }
  const r = rnd(10);
  let s = '';
  for (let i = 0; i < 16; i++) {
    const bit = i * 5;
    const byte = bit >> 3;
    const v = ((r[byte] << 8 | (r[byte + 1] || 0)) >> (11 - (bit & 7))) & 31;
    s += C32[v];
  }
  return t + s;
}

// THE ALLOWLIST IS A VALUE, NOT A CONDITION, so that adding an action is one line in
// one place and the validator cannot be made to accept something by a caller that
// forgot to check. v1 carries the actions the services spec names.
// `invite-redeem` IS NOT A BUTTON and that is why it was not in the spec's table of
// v1 actions: the five there are things a person does once they are already known.
// This one is what makes them known, and it is ordered by the invitation page rather
// than by a form on /desk/me.
//
// IT BELONGS IN THE SAME ALLOWLIST ANYWAY. The spool is the only thing the server
// writes, so every order goes through this list or the applying side is handed
// something no validator ever looked at. Leaving it out would have meant the
// validator refusing the one order apply can actually run - which it did, across two
// branches, until this line.
export const ACTIONS = ['invite-redeem', 'claude-login', 'start-session', 'forge-login', 'request-rig', 'request-session'];

// validateOrder - the services spec's list, IN ITS ORDER, and the order is part of
// the contract. Cheap structural refusals come before anything that needs the key or
// the spool, so a malformed request never reaches a comparison; and the nonce is
// checked before the action, so a stale page is told it is stale rather than that
// its action is unknown.
//
// Returns { ok: true, order } or { ok: false, status, reason }. It NEVER throws: the
// caller is a request handler, and an exception there becomes a 500 for what is
// always a client-side fault.
export function validateOrder(req, env) {
  const { method, contentType, bodyBytes, fetchSite, fields } = req;
  const { key, principal, generation, openActions } = env;

  if (method !== 'POST') return { ok: false, status: 405, reason: 'orders are posted' };
  if (String(contentType || '').split(';')[0].trim() !== 'application/x-www-form-urlencoded')
    return { ok: false, status: 415, reason: 'an order is a form submission' };
  if (!(bodyBytes <= 4096)) return { ok: false, status: 413, reason: 'an order body is at most 4 KiB' };

  // SAME-ORIGIN OR NOTHING, and a browser that sends no Sec-Fetch-Site is refused
  // rather than trusted. The header is how a form post from another site is told
  // apart from one of ours; treating its absence as "probably fine" would make the
  // check opt-in for anyone able to omit it.
  if (fetchSite !== 'same-origin')
    return { ok: false, status: 403, reason: 'an order comes from this desk, and says so' };

  const nonce = (fields && fields.nonce) || '';
  if (!verifyNonce(key, nonce, principal, generation))
    return { ok: false, status: 409, reason: 'this page is no longer current - reload and try again' };

  const action = (fields && fields.action) || '';
  if (!ACTIONS.includes(action))
    return { ok: false, status: 400, reason: 'unknown action' };

  // ONE OPEN ORDER PER PERSON PER ACTION. Two identical orders in the spool are two
  // runs of the same privileged verb, and the second one acts on a world the first
  // one changed. The caller counts what is open; this decides what that means.
  if (Array.isArray(openActions) && openActions.includes(action))
    return { ok: false, status: 409, reason: 'that order is already queued' };

  return {
    ok: true,
    order: {
      id: orderId(),
      principal,
      action,
      args: (fields && fields.args) || {},
      at: Math.floor(Date.now() / 1000),
      origin: env.origin || 'tailnet',
    },
  };
}

// appendOrder - the ONLY write the server makes, and the only one it will ever make.
//
// THE DIRECTORY'S MODE IS SET ON EVERY WRITE, and the second call is not redundant:
// mkdir's `mode` is masked by the umask, so a spool created under 022 comes out 0755
// and the argument that asked for 0700 is the thing that reads as if it worked. The
// chmod is what actually makes it 0700.
//
// IT SETS RATHER THAN CHECKS, and the comment says so on purpose. A directory the
// group or the world can write is a directory where somebody else chooses what a
// privileged process does, so this closes it every time rather than refusing and
// leaving it open. WHAT IT DOES NOT DO is verify ownership or refuse a symlink, the
// way the registry's own loaders do for their registers - the spool is created and
// owned by this server, so that chain has no second writer to disagree with yet. If
// the spool ever becomes something an operator places by hand, this is the line that
// has to grow those two refusals, and this paragraph is the record that it has not.
//
// WRITTEN TO A TEMPORARY NAME AND RENAMED, because the applying side scans the
// directory and a half-written order is a parse failure it would move aside with a
// receipt. rename(2) within one directory is atomic, so the applier sees a whole file
// or no file - never a partial one. The temporary name carries a dot prefix so a
// scan that globs *.json cannot pick it up even in the instant before the rename.
export function appendOrder(fs, dir, order) {
  fs.mkdirSync(dir, { recursive: true, mode: 0o700 });
  fs.chmodSync(dir, 0o700);
  const tmp = dir + '/.' + order.id + '.json.tmp';
  const dst = dir + '/' + order.id + '.json';
  fs.writeFileSync(tmp, JSON.stringify(order) + '\n', { mode: 0o600 });
  fs.renameSync(tmp, dst);
  return dst;
}

// openActionsFor - which actions this principal already has queued, for the one-open-
// order-per-action rule. READ FROM THE SPOOL AND NOT FROM A SNAPSHOT: the snapshot is
// a generation old by construction, and two orders written between two generations
// would both pass a check made against it.
export function openActionsFor(fs, dir, principal) {
  let names;
  try { names = fs.readdirSync(dir); } catch { return []; }
  const out = [];
  for (const n of names) {
    if (!n.endsWith('.json') || n.startsWith('.')) continue;
    try {
      const o = JSON.parse(fs.readFileSync(dir + '/' + n, 'utf8'));
      if (o && o.principal === principal && typeof o.action === 'string') out.push(o.action);
    } catch { /* a file the server did not write, or a partial one: not an open order */ }
  }
  return out;
}
