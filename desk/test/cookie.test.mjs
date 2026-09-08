import { test } from 'node:test';
import assert from 'node:assert/strict';
import { mkdtempSync, writeFileSync, chmodSync } from 'node:fs';
import { join } from 'node:path';
import { tmpdir } from 'node:os';
import { createHmac } from 'node:crypto';
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

test('a session and a state are not each other, even under the same key', () => {
  // Both cookies are signed under the one host key, so the MAC input carries
  // a label. Without it a body that parses as the other shape would verify.
  const session = mintSession(KEY, 'alice', 1000);
  assert.equal(verifyState(KEY, session.split('.').slice(1).join('.'), 1000), null);
  const state = mintState(KEY, { state: 's1', nonce: 'n1', verifier: 'v1', provider: 'stub', issuedAt: 1000 });
  assert.equal(verifySession(KEY, state, 1000), null);
  // And the label is what does it: a MAC over the same body under the wrong
  // label - or under no label, the way it was signed before - is refused.
  const rawMac = (data) => createHmac('sha256', KEY).update(data).digest('base64url');
  assert.equal(verifySession(KEY, 'alice.1000.' + rawMac('alice.1000'), 1000), null);
  const stateBody = state.split('.')[0];
  assert.equal(verifyState(KEY, stateBody + '.' + rawMac('session ' + stateBody), 1000), null);
  assert.equal(verifyState(KEY, stateBody + '.' + rawMac('state ' + stateBody), 1000).provider, 'stub');
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
