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
