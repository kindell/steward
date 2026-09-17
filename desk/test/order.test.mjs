// desk/test/order.mjs - what the desk may write, and every refusal before it writes.
//
// THE PURE HALF HAS ITS OWN SUITE for the reason bridge.mjs does: a validation chain
// exercised only through a running server is tested against whatever that server is
// willing to produce. Every refusal here is reachable from a plain object.

import test from 'node:test';
import assert from 'node:assert/strict';
import { writeFileSync, mkdtempSync, chmodSync } from 'node:fs';
import { join } from 'node:path';
import { tmpdir } from 'node:os';
import { loadFormKey, mintNonce, verifyNonce, orderId, validateOrder, ACTIONS } from '../order.mjs';

const KEY = Buffer.from('k'.repeat(40));
const T = mkdtempSync(join(tmpdir(), 'order-'));

const okReq = (over) => Object.assign({
  method: 'POST',
  contentType: 'application/x-www-form-urlencoded',
  bodyBytes: 100,
  fetchSite: 'same-origin',
  fields: { nonce: mintNonce(KEY, 'alice', 'gen-1'), action: 'claude-login' },
}, over || {});
const okEnv = (over) => Object.assign({ key: KEY, principal: 'alice', generation: 'gen-1' }, over || {});

// ── the key file ────────────────────────────────────────────────────────────
// THE REFUSALS ARE THE SESSION KEY'S, WORD FOR WORD IN SHAPE. An operator who has
// installed one has learned both, and a second vocabulary for the same class of file
// is a second thing to get wrong.
test('a missing form key is refused, naming what is missing', () => {
  assert.throws(() => loadFormKey(join(T, 'nope')), /form key file is missing/);
});

test('a form key the world can read is refused', () => {
  const p = join(T, 'loose'); writeFileSync(p, 'k'.repeat(40)); chmodSync(p, 0o644);
  assert.throws(() => loadFormKey(p), /mode 0600/);
});

test('a form key shorter than 32 bytes is refused', () => {
  const p = join(T, 'short'); writeFileSync(p, 'abc'); chmodSync(p, 0o600);
  assert.throws(() => loadFormKey(p), /at least 32 bytes/);
});

test('a good key file loads', () => {
  const p = join(T, 'good'); writeFileSync(p, 'k'.repeat(40) + '\n'); chmodSync(p, 0o600);
  assert.equal(loadFormKey(p).length, 40, 'and the trailing newline is not part of it');
});

// ── the nonce ───────────────────────────────────────────────────────────────
test('a nonce is bound to the generation', () => {
  const n = mintNonce(KEY, 'alice', 'gen-1');
  assert.equal(verifyNonce(KEY, n, 'alice', 'gen-1'), true);
  assert.equal(verifyNonce(KEY, n, 'alice', 'gen-2'), false, 'a page from an older generation cannot order');
});

// THE PRINCIPAL IS IN THE MAC AND NOT ONLY BESIDE IT. Where the identity check is
// weaker than it is on the tailnet, this is what stops one person's page posting as
// another's.
test('a nonce is bound to the principal', () => {
  const n = mintNonce(KEY, 'alice', 'gen-1');
  assert.equal(verifyNonce(KEY, n, 'bob', 'gen-1'), false);
});

test('a nonce from another key does not verify', () => {
  const n = mintNonce(Buffer.from('j'.repeat(40)), 'alice', 'gen-1');
  assert.equal(verifyNonce(KEY, n, 'alice', 'gen-1'), false);
});

// A LENGTH MISMATCH IS A REFUSAL, NEVER AN EXCEPTION. timingSafeEqual throws on
// unequal lengths, and a handler expecting a boolean would get a 500 for what is a
// client-side fault.
test('a nonce of the wrong length is refused and does not throw', () => {
  for (const v of ['', 'x', undefined, null, 'x'.repeat(200)])
    assert.equal(verifyNonce(KEY, v, 'alice', 'gen-1'), false);
});

// ── the id ──────────────────────────────────────────────────────────────────
// WHAT THE SPOOL NEEDS FROM AN ID is that it sorts oldest-first as a filename, so
// the apply step can read the order of work off a directory listing.
test('ids sort oldest first as plain strings', () => {
  const a = orderId(1_700_000_000_000), b = orderId(1_700_000_001_000);
  assert.ok(a < b, 'an earlier order sorts before a later one');
  assert.equal(a.length, 26);
});

test('two ids from the same millisecond differ', () => {
  const t = 1_700_000_000_000;
  assert.notEqual(orderId(t), orderId(t));
});

// ── the validation chain ────────────────────────────────────────────────────
test('a good order is accepted and carries what apply needs', () => {
  const r = validateOrder(okReq(), okEnv());
  assert.equal(r.ok, true);
  assert.equal(r.order.principal, 'alice');
  assert.equal(r.order.action, 'claude-login');
  assert.match(r.order.id, /^[0-9A-HJKMNP-TV-Z]{26}$/);
  assert.equal(typeof r.order.at, 'number');
});

test('every refusal names a status and a reason, and none throws', () => {
  const cases = [
    [okReq({ method: 'GET' }), 405],
    [okReq({ contentType: 'application/json' }), 415],
    [okReq({ bodyBytes: 4097 }), 413],
    [okReq({ fetchSite: 'cross-site' }), 403],
    [okReq({ fetchSite: undefined }), 403],
    [okReq({ fields: { nonce: 'no', action: 'claude-login' } }), 409],
    [okReq({ fields: { nonce: mintNonce(KEY, 'alice', 'gen-1'), action: 'rm-rf' } }), 400],
  ];
  for (const [req, status] of cases) {
    const r = validateOrder(req, okEnv());
    assert.equal(r.ok, false);
    assert.equal(r.status, status, JSON.stringify(req.fields || req.method));
    assert.ok(r.reason && r.reason.length > 0, 'a refusal says why');
  }
});

// A BROWSER THAT SENDS NO Sec-Fetch-Site IS REFUSED RATHER THAN TRUSTED. Treating
// its absence as "probably fine" makes the check opt-in for anyone able to omit it.
test('a missing Sec-Fetch-Site is refused, not waved through', () => {
  assert.equal(validateOrder(okReq({ fetchSite: undefined }), okEnv()).status, 403);
  assert.equal(validateOrder(okReq({ fetchSite: 'none' }), okEnv()).status, 403);
});

// THE ORDER OF THE CHECKS IS PART OF THE CONTRACT. A request that fails two of them
// must report the EARLIER one: a stale page should be told it is stale, not that its
// action is unknown, or the reader repairs the wrong thing.
test('the earlier refusal wins when a request fails two checks', () => {
  const r = validateOrder(okReq({ method: 'GET', fields: { nonce: 'no', action: 'rm-rf' } }), okEnv());
  assert.equal(r.status, 405, 'method comes before the nonce and the allowlist');
  const s = validateOrder(okReq({ fields: { nonce: 'no', action: 'rm-rf' } }), okEnv());
  assert.equal(s.status, 409, 'and a stale nonce is reported before an unknown action');
});

// ONE OPEN ORDER PER PERSON PER ACTION. Two identical orders are two runs of the
// same privileged verb, and the second acts on a world the first one changed.
test('a second open order for the same action is refused', () => {
  const r = validateOrder(okReq(), okEnv({ openActions: ['claude-login'] }));
  assert.equal(r.status, 409);
  const other = validateOrder(okReq(), okEnv({ openActions: ['forge-login'] }));
  assert.equal(other.ok, true, 'a different action is not blocked by it');
});

// THE ALLOWLIST IS A VALUE so adding an action is one line in one place. This pins
// that the validator reads that value rather than a condition of its own.
test('every allowlisted action is accepted', () => {
  for (const a of ACTIONS) {
    const req = okReq({ fields: { nonce: mintNonce(KEY, 'alice', 'gen-1'), action: a } });
    assert.equal(validateOrder(req, okEnv()).ok, true, a);
  }
});
