import { test } from 'node:test';
import assert from 'node:assert/strict';
import { mkdtempSync, writeFileSync, readFileSync } from 'node:fs';
import { join } from 'node:path';
import { tmpdir } from 'node:os';
import { createHash, generateKeyPairSync, createSign } from 'node:crypto';
import http from 'node:http';
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

// A KEY THIS FILE KNOWS, SPELLED IN A FORM THE PARSER CANNOT READ, IS A
// REFUSAL AND NOT A SILENT DROP. Every required key is caught by the "is
// missing" loop, so for those a dropped line is at least reported by another
// name; for an optional key - ENDPOINT_ORIGINS is the first - the line simply
// vanishes, the desk starts, and the first real login fails with the very
// "off its own origin" line that key exists to end. A key this file does NOT
// know stays ignored, exactly as before: an estate conf may carry rows this
// parser has no business policing, and taking the whole front down over one
// of those would be a worse outage than the one this refusal closes.
test('loadProviders refuses a key it knows written in a form it cannot read', () => {
  const base = 'ISSUER="https://a.example.test"\nDISCOVERY="https://a.example.test/d"\nCLIENT_ID="c"\nCLIENT_SECRET_FILE="/f"\n';
  const bad = (line, re) => assert.throws(() => loadProviders(providersDir({ 'x.conf': base + line + '\n' })), re);
  const form = /x\.conf: ENDPOINT_ORIGINS must be written as ENDPOINT_ORIGINS="<value>"/;
  bad('ENDPOINT_ORIGINS=https://t.example.test', form);          // unquoted
  bad("ENDPOINT_ORIGINS='https://t.example.test'", form);        // single quotes
  bad('ENDPOINT_ORIGINS="https://t.example.test" # note', form); // a comment after the closing quote
  bad('export ENDPOINT_ORIGINS="https://t.example.test"', form); // export-prefixed
  bad('  ENDPOINT_ORIGINS="https://t.example.test"', form);      // indented
  // A required key spelled the same way is named the same way, rather than
  // reported as missing when it is right there in the file.
  assert.throws(() => loadProviders(providersDir({
    'x.conf': 'ISSUER="https://a.example.test"\nDISCOVERY=https://a.example.test/d\nCLIENT_ID="c"\nCLIENT_SECRET_FILE="/f"\n'
  })), /x\.conf: DISCOVERY must be written as DISCOVERY="<value>"/);
  // A key this file does not know is not this file's business - including the
  // near misses, which differ from a known key by a letter or by case.
  const p = loadProviders(providersDir({
    'x.conf': base + 'ENDPOINT_ORIGIN="https://t.example.test"\nendpoint_origins="https://t.example.test"\nSOMETHING_ELSE=whatever\n'
  }));
  assert.equal(p.size, 1);
  assert.deepStrictEqual(p.get('x').endpointOrigins, []);
});

test('discover fetches the four endpoints once and caches them', async (t) => {
  const stub = await startStub();
  t.after(() => stub.close());
  let calls = 0;
  const counting = (u, o) => { calls++; return fetch(u, o); };
  const prov = { slug: 'p', issuer: stub.issuer, issuerTemplate: null, clientId: 'cid', clientSecretFile: '/f', discovery: stub.origin + '/.well-known/openid-configuration' };
  const doc = await discover(prov, counting);
  assert.equal(doc.authorization_endpoint, stub.origin + '/authorize');
  assert.equal(doc.token_endpoint, stub.origin + '/token');
  assert.equal(doc.jwks_uri, stub.origin + '/jwks');
  await discover(prov, counting);
  assert.equal(calls, 1);
});

test('discover refuses a document that names another issuer', async (t) => {
  const stub = await startStub({ issuer: 'https://accounts.example.test' });
  t.after(() => stub.close());
  const prov = { slug: 'iss-mismatch', issuer: 'https://provider.example.test', issuerTemplate: null, clientId: 'cid', clientSecretFile: '/f', discovery: stub.origin + '/.well-known/openid-configuration' };
  await assert.rejects(discover(prov), /discovery for iss-mismatch names another issuer/);
});

test('discover refuses an endpoint on another origin', async (t) => {
  const stub = await startStub({ jwksUri: 'https://provider.example.test/jwks' });
  t.after(() => stub.close());
  const prov = { slug: 'off-origin', issuer: stub.issuer, issuerTemplate: null, clientId: 'cid', clientSecretFile: '/f', discovery: stub.origin + '/.well-known/openid-configuration' };
  await assert.rejects(discover(prov), /discovery for off-origin points jwks_uri off its own origin/);
});

// A DOCUMENT SHAPED LIKE THE PROVIDERS THAT SPLIT THEIR ENDPOINTS. Google's
// real document names the token endpoint and the JWKS on two hosts that are
// not the issuer's, permanently and by design - so the same-origin rule alone
// makes such a provider impossible rather than merely misconfigured. Nothing
// here reaches the network: the document is served by the fake fetch below.
const SPLIT_ORIGIN_DOC = {
  issuer: 'https://accounts.google.com',
  authorization_endpoint: 'https://accounts.google.com/o/oauth2/v2/auth',
  token_endpoint: 'https://oauth2.googleapis.com/token',
  jwks_uri: 'https://www.googleapis.com/oauth2/v3/certs'
};
const serving = (doc) => async () => new Response(JSON.stringify(doc), { status: 200 });
const providerRow = (extra) => 'ISSUER="https://accounts.google.com"\n' +
  'DISCOVERY="https://accounts.google.com/.well-known/openid-configuration"\n' +
  'CLIENT_ID="cid"\nCLIENT_SECRET_FILE="/f"\n' + (extra === undefined ? '' : 'ENDPOINT_ORIGINS="' + extra + '"\n');
const providerFrom = (slug, extra) => loadProviders(providersDir({ [slug + '.conf']: providerRow(extra) })).get(slug);

test('a provider whose estate named no extra origin still refuses an off-origin token_endpoint', async () => {
  const prov = providerFrom('no-extras');
  assert.deepEqual(prov.endpointOrigins, []);
  await assert.rejects(discover(prov, serving(SPLIT_ORIGIN_DOC)),
    /discovery for no-extras points token_endpoint off its own origin/);
});

test('a provider whose estate named the extra origins accepts a document that uses them', async () => {
  const prov = providerFrom('named-extras', 'https://oauth2.googleapis.com https://www.googleapis.com');
  assert.deepEqual(prov.endpointOrigins, ['https://oauth2.googleapis.com', 'https://www.googleapis.com']);
  const doc = await discover(prov, serving(SPLIT_ORIGIN_DOC));
  assert.equal(doc.token_endpoint, SPLIT_ORIGIN_DOC.token_endpoint);
  assert.equal(doc.jwks_uri, SPLIT_ORIGIN_DOC.jwks_uri);
  assert.equal(doc.authorization_endpoint, SPLIT_ORIGIN_DOC.authorization_endpoint);
});

test('an origin the estate did not name is refused even for a provider that named others', async () => {
  const prov = providerFrom('unnamed-fourth', 'https://oauth2.googleapis.com https://www.googleapis.com');
  const doc = Object.assign({}, SPLIT_ORIGIN_DOC, { jwks_uri: 'https://keys.example.test/certs' });
  await assert.rejects(discover(prov, serving(doc)),
    /discovery for unnamed-fourth points jwks_uri off its own origin/);
});

test('a named extra origin adds to the base origin, it never replaces it', async () => {
  const prov = providerFrom('adds-only', 'https://tokens.example.test');
  assert.deepEqual(prov.endpointOrigins, ['https://tokens.example.test']);
  const doc = {
    issuer: 'https://accounts.google.com',
    authorization_endpoint: 'https://accounts.google.com/o/oauth2/v2/auth',
    token_endpoint: 'https://accounts.google.com/token',
    jwks_uri: 'https://accounts.google.com/certs'
  };
  const got = await discover(prov, serving(doc));
  assert.equal(got.token_endpoint, doc.token_endpoint);
  assert.equal(got.jwks_uri, doc.jwks_uri);
});

test('loadProviders refuses an ENDPOINT_ORIGINS entry that is not an origin the estate can mean', () => {
  const bad = (v, re) => assert.throws(() => loadProviders(providersDir({ 'x.conf': providerRow(v) })), re);
  bad('http://tokens.example.test', /x\.conf: ENDPOINT_ORIGINS must be https, or loopback/);
  bad('https://x.example/token', /x\.conf: ENDPOINT_ORIGINS must name an origin only/);
  bad('not a url', /x\.conf: ENDPOINT_ORIGINS is not a URL/);
  bad('https://x.example?tenant=1', /x\.conf: ENDPOINT_ORIGINS must name an origin only/);
  bad('https://x.example#frag', /x\.conf: ENDPOINT_ORIGINS must name an origin only/);
  bad('https://someone:pw@x.example', /x\.conf: ENDPOINT_ORIGINS must name an origin only/);
  bad('https://x.example https://x.example', /x\.conf: ENDPOINT_ORIGINS names https:\/\/x\.example twice/);
  // Absent, empty, or nothing but spacing is today's behaviour: no extras.
  assert.deepEqual(providerFrom('absent').endpointOrigins, []);
  assert.deepEqual(providerFrom('empty', '').endpointOrigins, []);
  assert.deepEqual(providerFrom('spaces', '   ').endpointOrigins, []);
  // An entry is kept as an origin, so a bare root slash is the same origin.
  assert.deepEqual(providerFrom('slash', 'https://x.example/').endpointOrigins, ['https://x.example']);
});

// AN ENTRY WHOSE ORIGIN IS THE STRING "null" IS A WILDCARD, NOT AN ORIGIN.
// new URL('x://127.0.0.1') has an empty path, no query, no fragment, no
// userinfo and a loopback hostname, so every guard above passes it - but a
// URL with a scheme the standard does not call special reports its origin as
// the literal string "null", and so does EVERY such URL. Storing one would
// put that whole class in the allowed set at once.
test('loadProviders refuses an ENDPOINT_ORIGINS entry that has no origin to name', async () => {
  assert.throws(() => providerFrom('opaque', 'x://127.0.0.1'),
    /opaque\.conf: ENDPOINT_ORIGINS must name an origin only/);
  // With no such entry to widen it, an endpoint of that class is held by the
  // origin gate itself - not waved through it and caught one line later by
  // the plaintext check.
  const doc = Object.assign({}, SPLIT_ORIGIN_DOC, { token_endpoint: 'zz://evil.example/token' });
  await assert.rejects(discover(providerFrom('opaque-doc'), serving(doc)),
    /discovery for opaque-doc points token_endpoint off its own origin/);
});

// THE SCHEMA SHOWS ONE SPELLING AND IT IS THE ONE THE LOADER READS. An
// operator copies what the schema shows, so a spelling the loader would
// refuse - or, before this round, silently drop - makes the schema itself the
// bug. The example is lifted out of the file and run through the loader here,
// with its <placeholders> filled in.
const SCHEMA = readFileSync(new URL('../SCHEMA.md', import.meta.url), 'utf8');

test('SCHEMA.md shows one ENDPOINT_ORIGINS spelling, the loader reads it, and it says what a bad entry costs', () => {
  const shown = SCHEMA.match(/^\s*ENDPOINT_ORIGINS=.*$/gm) || [];
  assert.equal(shown.length, 1, 'exactly one spelling, so there is one form to copy');
  let n = 0;
  const line = shown[0].trim().replace(/<[^>]+>/g, () => 'h' + (++n) + '.example.test');
  const p = loadProviders(providersDir({ 'documented.conf': providerRow() + line + '\n' }));
  assert.deepStrictEqual(p.get('documented').endpointOrigins,
    ['https://h1.example.test', 'https://h2.example.test']);
  // And the paragraph says the two things "further https origins" alone does
  // not: loopback http is accepted here on DISCOVERY's own rule, and a bad
  // entry stops the desk at start rather than being found at the first login.
  const para = SCHEMA.slice(SCHEMA.indexOf('`ENDPOINT_ORIGINS`'), SCHEMA.indexOf('\n3. '));
  assert.match(para, /loopback/);
  assert.match(para, /78/);
});

test('discover refuses a plaintext endpoint on a host that is not loopback', async (t) => {
  // The endpoints sit on the issuer's own origin, so the origin check has
  // nothing to say and the scheme check is the one that must refuse. Only
  // loopback may be plaintext, and this host is not loopback.
  const stub = await startStub({ issuer: 'http://provider.example.test', endpointBase: 'http://provider.example.test' });
  t.after(() => stub.close());
  const prov = { slug: 'plaintext', issuer: 'http://provider.example.test', issuerTemplate: null, clientId: 'cid', clientSecretFile: '/f', discovery: stub.origin + '/.well-known/openid-configuration' };
  await assert.rejects(discover(prov), /discovery for plaintext names a plaintext authorization_endpoint/);
});

test('loadProviders refuses a DISCOVERY that is not https and not loopback', () => {
  const row = (d) => 'ISSUER="https://a.example.test"\nDISCOVERY="' + d + '"\nCLIENT_ID="c"\nCLIENT_SECRET_FILE="/f"\n';
  assert.throws(() => loadProviders(providersDir({ 'x.conf': row('http://provider.example.test/.well-known/openid-configuration') })),
    /x\.conf: DISCOVERY must be https, or loopback/);
  assert.throws(() => loadProviders(providersDir({ 'x.conf': row('not a url') })), /x\.conf: DISCOVERY is not a URL/);
  // Loopback over plaintext is the one exception, and it is what the suite uses.
  assert.equal(loadProviders(providersDir({ 'x.conf': row('http://127.0.0.1:9/.well-known/openid-configuration') })).size, 1);
});

test('beginLogin builds a PKCE S256 authorization URL with fresh state and nonce', async (t) => {
  const stub = await startStub();
  t.after(() => stub.close());
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
});

// THE STUB IS CLOSED BY THE RUNNER, NOT BY THE LAST LINE OF THE TEST. A
// closing call after the assertions is skipped by a failing assertion, and the
// leaked listening server then keeps node --test's event loop alive: the
// failure is printed and the process hangs instead of exiting 1, which reads
// as a timeout rather than a red test. Measured on this branch - three red
// mutation runs each had to be killed at 150 s. t.after runs either way.
async function loginFixture(t, stubOpts = {}, provOver = {}) {
  const stub = await startStub(stubOpts);
  t.after(() => stub.close());
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

// Build a JWT by hand, the way the stub does, but with a payload segment
// that is exact literal text rather than the output of JSON.stringify - so
// a case can carry a value (a bare "1e999", or the bare literal "null")
// that JSON.stringify would never produce from a JS object.
function craftToken(stub, payloadText, opts = {}) {
  const b64u = (s) => Buffer.from(s).toString('base64url');
  const header = Object.assign({ alg: 'RS256', typ: 'JWT', kid: stub.kid }, opts.header || {});
  const signingInput = b64u(JSON.stringify(header)) + '.' + b64u(payloadText);
  const sig = createSign('RSA-SHA256').update(signingInput).sign(opts.key || stub.keyPair.privateKey);
  return signingInput + '.' + sig.toString('base64url');
}

test('exchangeCode posts the form with the secret from the file and returns the id_token', async (t) => {
  const f = await loginFixture(t);
  const tok = await exchangeCode(f.prov, f.doc, { code: f.code, verifier: f.begun.verifier, redirectUri: 'https://desk.example.test/desk/auth/callback' });
  assert.equal(typeof tok, 'string');
  const call = f.stub.tokenCalls[0];
  assert.equal(call.form.get('grant_type'), 'authorization_code');
  assert.equal(call.form.get('client_secret'), 'shh-secret');
  assert.equal(call.form.get('code_verifier'), f.begun.verifier);
  await assert.rejects(exchangeCode(f.prov, f.doc, { code: 'WRONG', verifier: 'v', redirectUri: 'x' }), /token endpoint/);
});

test('a valid id_token verifies to its subject', async (t) => {
  const f = await loginFixture(t);
  const tok = await exchangeCode(f.prov, f.doc, { code: f.code, verifier: f.begun.verifier, redirectUri: 'https://desk.example.test/desk/auth/callback' });
  const claims = await verifyIdToken(f.prov, f.doc, tok, { nonce: f.begun.nonce });
  assert.deepEqual(claims, { sub: 'sub-1', tid: null, email: 'alice@example.test' });
  assert.equal(identityOf(f.prov, claims), 'oidc:p:sub-1');
});

test('every refusal the spec lists is a refusal', async (t) => {
  const f = await loginFixture(t);
  const now = Math.floor(Date.now() / 1000);
  const cases = [
    ['wrong aud', f.stub.mintIdToken({ aud: 'other' }), /id_token: aud/],
    ['wrong iss', f.stub.mintIdToken({ iss: 'https://evil.example.test' }), /id_token: iss/],
    ['expired', f.stub.mintIdToken({ exp: now - 1 }), /id_token: exp/],
    ['iat in the future', f.stub.mintIdToken({ iat: now + 600 }), /id_token: iat/],
    ['wrong nonce', f.stub.mintIdToken({ nonce: 'other' }), /id_token: nonce/],
    ['unknown kid', f.stub.mintIdToken({}, { kid: 'k9' }), /id_token: kid/],
    ['no sub', f.stub.mintIdToken({ sub: undefined }), /id_token: sub/],
    ['not a jwt', 'abc.def', /id_token: malformed/],
    ['garbage segments', 'a.b.c', /id_token: malformed/],
    ['wrong alg', f.stub.mintIdToken({}, { alg: 'none' }), /id_token: alg/],
    ['not yet valid', f.stub.mintIdToken({ nbf: now + 600 }), /id_token: nbf/],
    ['nbf that is not a number', f.stub.mintIdToken({ nbf: 'soon' }), /id_token: nbf/]
  ];
  const other = generateKeyPairSync('rsa', { modulusLength: 2048 });
  cases.push(['bad signature', f.stub.mintIdToken({}, { key: other.privateKey }), /id_token: signature/]);
  // JSON permits a numeric literal so large it can only parse to Infinity;
  // JSON.stringify(Infinity) collapses back to null, so this payload has to
  // be written as literal text to reach the parser as the number it is.
  const infPayload = '{"iss":"' + f.stub.issuer + '","aud":"' + f.prov.clientId + '","iat":' + now +
    ',"exp":1e999,"sub":"sub-1","email":"alice@example.test","nonce":"' + f.begun.nonce + '"}';
  cases.push(['infinite exp', craftToken(f.stub, infPayload), /id_token: exp/]);
  cases.push(['payload is JSON null', craftToken(f.stub, 'null'), /id_token: malformed/]);
  for (const [name, tok, re] of cases) {
    await assert.rejects(verifyIdToken(f.prov, f.doc, tok, { nonce: f.begun.nonce }), re, name);
  }
});

test('identityOf does not tenant-scope a plain provider even if claims carry a tid', () => {
  const prov = { slug: 'p', issuerTemplate: null };
  assert.equal(identityOf(prov, { sub: 'sub-1', tid: 'tenant-x' }), 'oidc:p:sub-1');
});

test('a JWKS fetch failure refuses with the id_token prefix, not the raw endpoint error', async (t) => {
  const f = await loginFixture(t);
  const tok = await exchangeCode(f.prov, f.doc, { code: f.code, verifier: f.begun.verifier, redirectUri: 'https://desk.example.test/desk/auth/callback' });
  // A jwks_uri the stub answers 404 for: a fresh cache key (the URL differs
  // from the fixture's real one), so this is a genuine fetch, not a hit.
  const brokenDoc = Object.assign({}, f.doc, { jwks_uri: f.stub.origin + '/jwks-does-not-exist' });
  await assert.rejects(verifyIdToken(f.prov, brokenDoc, tok, { nonce: f.begun.nonce }), /id_token: jwks/);
});

test('a template provider matches iss against the token tenant and keys identity by tenant', async (t) => {
  const f = await loginFixture(t, { issuer: 'https://login.example.test/tenant-1/v2.0', tid: 'tenant-1' },
    { issuer: null, issuerTemplate: 'https://login.example.test/<tid>/v2.0' });
  const tok = f.stub.mintIdToken();
  const claims = await verifyIdToken(f.prov, f.doc, tok, { nonce: f.begun.nonce });
  assert.equal(claims.tid, 'tenant-1');
  assert.equal(identityOf(f.prov, claims), 'oidc:p:tenant-1.sub-1');
  await assert.rejects(verifyIdToken(f.prov, f.doc, f.stub.mintIdToken({ tid: 'tenant-2' }), { nonce: f.begun.nonce }), /id_token: iss/);
  await assert.rejects(verifyIdToken(f.prov, f.doc, f.stub.mintIdToken({ tid: undefined }), { nonce: f.begun.nonce }), /id_token: tid/);
});

test('every provider fetch carries an abort signal', async (t) => {
  // A fresh slug so the discovery and JWKS caches from earlier tests miss,
  // and every one of the three provider calls (discovery, token, jwks)
  // actually happens through the recording fetchImpl below.
  const stub = await startStub();
  t.after(() => stub.close());
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
});

test('an nbf inside the skew window, and no nbf at all, both verify', async (t) => {
  // nbf says nothing when it is absent, and a provider that sends one sends
  // it in the past - so only a token from the future is refused for it.
  const f = await loginFixture(t);
  const now = Math.floor(Date.now() / 1000);
  const withNbf = await verifyIdToken(f.prov, f.doc, f.stub.mintIdToken({ nbf: now - 10 }), { nonce: f.begun.nonce });
  assert.equal(withNbf.sub, 'sub-1');
  const without = await verifyIdToken(f.prov, f.doc, f.stub.mintIdToken(), { nonce: f.begun.nonce });
  assert.equal(without.sub, 'sub-1');
});

test('a JWKS key published under another algorithm is not a key for an RS256 signature', async (t) => {
  const f = await loginFixture(t, { jwksAlg: 'RS512' });
  // The key is the right kid and the right kty, and its owner says it is for
  // RS512 - so it is skipped, and the token's kid then resolves to nothing.
  await assert.rejects(verifyIdToken(f.prov, f.doc, f.stub.mintIdToken(), { nonce: f.begun.nonce }),
    /id_token: kid unknown/);
});

test('a discovery document over the cap is refused, declared or not', async (t) => {
  const origin = 'https://big.example.test';
  const base = { issuerTemplate: null, clientId: 'cid', clientSecretFile: '/f' };
  const doc = {
    issuer: origin, authorization_endpoint: origin + '/authorize',
    token_endpoint: origin + '/token', jwks_uri: origin + '/jwks'
  };
  const huge = JSON.stringify(Object.assign({ padding: 'x'.repeat(70000) }, doc));
  // A declared content-length over the cap is refused on the header alone.
  const declared = async () => new Response(huge, {
    status: 200, headers: { 'content-length': String(Buffer.byteLength(huge)) }
  });
  const provA = Object.assign({ slug: 'big-declared', issuer: origin, discovery: origin + '/a' }, base);
  await assert.rejects(discover(provA, declared),
    /discovery for big-declared answered a body over 65536 bytes/);
  // A chunked answer declares nothing, so the body is read and then measured.
  const undeclared = async () => new Response(new Blob([huge]).stream(), { status: 200 });
  const provB = Object.assign({ slug: 'big-chunked', issuer: origin, discovery: origin + '/b' }, base);
  await assert.rejects(discover(provB, undeclared),
    /discovery for big-chunked answered a body over 65536 bytes/);
  // A body inside the cap that is not JSON is named as such, not as a class.
  const notJson = async () => new Response('<html>an error page</html>', { status: 200 });
  const provC = Object.assign({ slug: 'not-json', issuer: origin, discovery: origin + '/c' }, base);
  await assert.rejects(discover(provC, notJson), /discovery for not-json answered something that is not JSON/);
  // And a small document still gets through the same reader.
  const fine = async () => new Response(JSON.stringify(doc), { status: 200 });
  const provD = Object.assign({ slug: 'small', issuer: origin, discovery: origin + '/d' }, base);
  assert.equal((await discover(provD, fine)).jwks_uri, origin + '/jwks');
});

test('a JWKS over the cap is refused rather than parsed into keys', async (t) => {
  const f = await loginFixture(t);
  const huge = JSON.stringify({ padding: 'x'.repeat(70000), keys: [] });
  const fat = async () => new Response(huge, {
    status: 200, headers: { 'content-length': String(Buffer.byteLength(huge)) }
  });
  // A jwks_uri this process has never fetched, so this is a real fetch.
  const doc = Object.assign({}, f.doc, { jwks_uri: f.stub.origin + '/jwks-fat' });
  await assert.rejects(verifyIdToken(f.prov, doc, f.stub.mintIdToken(), { nonce: f.begun.nonce }, fat),
    /id_token: jwks unavailable/);
});

// AND THE TOKEN ENDPOINT IS READ THROUGH THE SAME BOUND. It was the last
// provider read on a bare res.json(), which reads whatever arrives - so a
// hostile token endpoint could stream this process out of memory on the one
// request that happens after a person has already clicked through their
// provider's login. The stub here answers 200 and then streams, exactly as
// the discovery streamer below does, and the refusal must be the cap's own
// message rather than V8's string-length error.
test('a token endpoint that streams past the cap is refused, and the transfer is abandoned', async (t) => {
  const CHUNK = Buffer.alloc(65536, 0x20);
  const TOTAL = 32 * 1024 * 1024;
  let served = 0;
  const server = http.createServer((req, res) => {
    req.resume(); // the form body: read and dropped, this endpoint answers regardless
    req.on('end', () => {
      // No content-length, so the declared-length gate has nothing to say and
      // the reader is the only thing between this and the process's memory.
      res.writeHead(200, { 'content-type': 'application/json' });
      let closed = false;
      res.on('close', () => { closed = true; });
      res.on('error', () => { closed = true; });
      const pump = () => {
        while (!closed && served < TOTAL) {
          served += CHUNK.length;
          if (!res.write(CHUNK)) return res.once('drain', pump);
        }
        if (!closed) res.end();
      };
      pump();
    });
  });
  await new Promise((r) => server.listen(0, '127.0.0.1', r));
  t.after(() => new Promise((r) => server.close(r)));
  const origin = 'http://127.0.0.1:' + server.address().port;
  const secretFile = join(mkdtempSync(join(tmpdir(), 'desk-secret-')), 'client-secret');
  writeFileSync(secretFile, 'shh\n');
  const prov = {
    slug: 'token-streamer', issuer: origin, issuerTemplate: null, clientId: 'cid',
    clientSecretFile: secretFile, discovery: origin + '/.well-known/openid-configuration'
  };
  const doc = { token_endpoint: origin + '/token' };
  await assert.rejects(
    exchangeCode(prov, doc, { code: 'CODE', verifier: 'v', redirectUri: origin + '/cb' }),
    /token endpoint for token-streamer answered a body over 65536 bytes/);
  // The same bound the discovery streamer uses, for the same reason: what the
  // kernel and the client had already taken before the cancel landed counts,
  // and reading to the end would be the whole 32 MiB.
  assert.ok(served < 8 * 1024 * 1024,
    'the transfer must be abandoned at the cap, not read to the end: the endpoint sent ' + served + ' bytes');
});

// A body inside the cap that is not JSON is named as such here too, so an
// error page from a proxy in front of the provider does not reach the
// operator's log as a class name.
test('a token endpoint that answers something that is not JSON is named as such', async (t) => {
  const server = http.createServer((req, res) => {
    req.resume();
    req.on('end', () => {
      res.writeHead(200, { 'content-type': 'text/html' });
      res.end('<html>a proxy error page</html>');
    });
  });
  await new Promise((r) => server.listen(0, '127.0.0.1', r));
  t.after(() => new Promise((r) => server.close(r)));
  const origin = 'http://127.0.0.1:' + server.address().port;
  const secretFile = join(mkdtempSync(join(tmpdir(), 'desk-secret-')), 'client-secret');
  writeFileSync(secretFile, 'shh\n');
  const prov = {
    slug: 'token-html', issuer: origin, issuerTemplate: null, clientId: 'cid',
    clientSecretFile: secretFile, discovery: origin + '/.well-known/openid-configuration'
  };
  await assert.rejects(
    exchangeCode(prov, { token_endpoint: origin + '/token' }, { code: 'CODE', verifier: 'v', redirectUri: origin + '/cb' }),
    /token endpoint for token-html answered something that is not JSON/);
});

// THE CAP IS MEASURED WHILE THE BODY ARRIVES. The test above streams from a
// Blob, which is a stream the runtime already holds whole; this one is a real
// socket sending real chunks with no content-length, which is what a hostile
// provider looks like. The refusal must therefore arrive after a few chunks
// and not after all of them - so the server counts what it managed to send,
// and that count is the assertion. Reading the body to the end first would
// pass the message check and fail this one, which is exactly the difference.
test('a chunked body past the cap is refused while it arrives, not after it', async (t) => {
  const CHUNK = Buffer.alloc(65536, 0x20);
  const TOTAL = 32 * 1024 * 1024;
  let served = 0;
  const server = http.createServer((req, res) => {
    // No content-length: the answer is chunked, so the declared-length gate
    // above has nothing to say and the reader is the only thing left.
    res.writeHead(200, { 'content-type': 'application/json' });
    let closed = false;
    res.on('close', () => { closed = true; });
    res.on('error', () => { closed = true; });
    const pump = () => {
      while (!closed && served < TOTAL) {
        served += CHUNK.length;
        if (!res.write(CHUNK)) return res.once('drain', pump);
      }
      if (!closed) res.end();
    };
    pump();
  });
  await new Promise((r) => server.listen(0, '127.0.0.1', r));
  t.after(() => new Promise((r) => server.close(r)));
  const origin = 'http://127.0.0.1:' + server.address().port;
  const prov = {
    slug: 'streamer', issuer: origin, issuerTemplate: null, clientId: 'cid',
    clientSecretFile: '/f', discovery: origin + '/.well-known/openid-configuration'
  };
  await assert.rejects(discover(prov), /discovery for streamer answered a body over 65536 bytes/);
  // THE BOUND IS GENEROUS ON PURPOSE. Abandoning the stream does not stop the
  // sender mid-chunk: what the kernel and the client had already accepted
  // before the cancel landed still counts, and that is 2.5 MiB on this box,
  // steady across runs and under the whole suite's load. Eight is three times
  // that and a quarter of what reading to the end would be, so the assertion
  // separates the two answers without being a measurement of socket buffers.
  assert.ok(served < 8 * 1024 * 1024,
    'the transfer must be abandoned at the cap, not read to the end: the provider sent ' + served + ' bytes');
});
