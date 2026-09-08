import { test } from 'node:test';
import assert from 'node:assert/strict';
import { mkdtempSync, writeFileSync, chmodSync } from 'node:fs';
import { join } from 'node:path';
import { tmpdir } from 'node:os';
import { createHmac } from 'node:crypto';
import { parseCookies, serializeCookie, loadSessionKey, mintSession, verifySession, mintState, verifyState } from '../cookie.mjs';

const KEY = Buffer.from('0123456789abcdef0123456789abcdef');
const OTHER = Buffer.from('fedcba9876543210fedcba9876543210');

// The MAC over exactly the bytes given, with no label of its own: the tests
// below build both a labelled and an unlabelled one out of it.
const rawMac = (data) => createHmac('sha256', KEY).update(data).digest('base64url');

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

test('a session round-trips the identity, and fails on the wrong key, a tampered body, or age', () => {
  const ID = 'oidc:stub:sub-1';
  const encoded = Buffer.from(ID).toString('base64url');
  const v = mintSession(KEY, ID, 1000);
  assert.equal(v, encoded + '.1000.' + v.split('.')[2]);
  assert.match(v, /^[A-Za-z0-9_-]+\.1000\.[A-Za-z0-9_-]+$/);
  assert.equal(verifySession(KEY, v, 1000 + 43200), ID);
  assert.equal(verifySession(KEY, v, 1000 + 43201), null);
  assert.equal(verifySession(KEY, v, 999), null);
  assert.equal(verifySession(OTHER, v, 2000), null);
  assert.equal(verifySession(KEY, v.replace(encoded, Buffer.from('oidc:stub:sub-2').toString('base64url')), 2000), null);
  assert.equal(verifySession(KEY, 'not.a.cookie', 2000), null);
  assert.equal(verifySession(KEY, '', 2000), null);
});

test('a tenant identity survives the encoding, and a body that is not an identity does not verify', () => {
  // The multi-tenant form carries a dot inside the subject, which is the
  // cookie's own field separator - the encoding is what keeps it one field.
  const ID = 'oidc:work:9f8e.sub-1';
  const v = mintSession(KEY, ID, 1000);
  assert.equal(v.split('.').length, 3);
  assert.equal(verifySession(KEY, v, 1000), ID);
  // A correctly signed body that decodes to something other than an identity
  // is refused: a principal slug, a tailnet login, an empty word.
  for (const body of ['alice', 'tailscale:alice@example.test', '', 'oidc:stub:', 'oidc::sub-1', 'oidc:stub:sub 1']) {
    const forged = mintSession(KEY, body, 1000);
    assert.equal(verifySession(KEY, forged, 1000), null, JSON.stringify(body));
  }
  // And so is a first field that is not base64url at all, before any decode.
  assert.equal(verifySession(KEY, 'oidc:stub:sub-1.1000.' + rawMac('session oidc:stub:sub-1.1000'), 1000), null);
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
  const session = mintSession(KEY, 'oidc:stub:sub-1', 1000);
  assert.equal(verifyState(KEY, session.split('.').slice(1).join('.'), 1000), null);
  const state = mintState(KEY, { state: 's1', nonce: 'n1', verifier: 'v1', provider: 'stub', issuedAt: 1000 });
  assert.equal(verifySession(KEY, state, 1000), null);
  // And the label is what does it: a MAC over the same body under the wrong
  // label - or under no label, the way it was signed before - is refused.
  const sessionBody = session.split('.').slice(0, 2).join('.');
  assert.equal(verifySession(KEY, sessionBody + '.' + rawMac(sessionBody), 1000), null);
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
