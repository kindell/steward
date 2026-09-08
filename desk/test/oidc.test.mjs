import { test } from 'node:test';
import assert from 'node:assert/strict';
import { mkdtempSync, writeFileSync, mkdirSync } from 'node:fs';
import { join } from 'node:path';
import { tmpdir } from 'node:os';
import { createHash, generateKeyPairSync } from 'node:crypto';
import { loadProviders, discover, beginLogin, exchangeCode, verifyIdToken, identityOf } from '../oidc.mjs';
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
  assert.equal(identityOf(f.prov, claims), 'oidc:p:tenant-1.sub-1');
  await assert.rejects(verifyIdToken(f.prov, f.doc, f.stub.mintIdToken({ tid: 'tenant-2' }), { nonce: f.begun.nonce }), /id_token: iss/);
  await assert.rejects(verifyIdToken(f.prov, f.doc, f.stub.mintIdToken({ tid: undefined }), { nonce: f.begun.nonce }), /id_token: tid/);
  await f.stub.close();
});

test('every provider fetch carries an abort signal', async () => {
  // A fresh slug so the discovery and JWKS caches from earlier tests miss,
  // and every one of the three provider calls (discovery, token, jwks)
  // actually happens through the recording fetchImpl below.
  const stub = await startStub();
  const secretDir = mkdtempSync(join(tmpdir(), 'desk-sec-'));
  writeFileSync(join(secretDir, 's'), 'shh-secret\n');
  const prov = {
    slug: 'q', issuer: stub.issuer, issuerTemplate: null, clientId: 'cid',
    clientSecretFile: join(secretDir, 's'), discovery: stub.origin + '/.well-known/openid-configuration'
  };
  const seen = [];
  const recording = (u, o) => { seen.push(o); return fetch(u, o); };
  const doc = await discover(prov, recording);
  const begun = beginLogin(prov, doc, 'https://desk.example.test/desk/auth/callback');
  const r = await fetch(begun.url, { redirect: 'manual' });
  const back = new URL(r.headers.get('location'));
  const tok = await exchangeCode(prov, doc, { code: back.searchParams.get('code'), verifier: begun.verifier, redirectUri: 'https://desk.example.test/desk/auth/callback' }, recording);
  await verifyIdToken(prov, doc, tok, { nonce: begun.nonce }, recording);
  assert.equal(seen.length, 3);
  assert.ok(seen.every((o) => o && o.signal instanceof AbortSignal));
  await stub.close();
});
