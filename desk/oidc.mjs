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
import { randomBytes, createHash, createPublicKey, createVerify } from 'node:crypto';

const SLUG_RE = /^[a-z0-9-]+$/;
const REQUIRED = ['DISCOVERY', 'CLIENT_ID', 'CLIENT_SECRET_FILE'];

// A PROVIDER IS REACHED OVER TLS OR NOT AT ALL. Loopback is the exception,
// and only as a literal: a name that resolves to loopback today resolves
// somewhere else tomorrow, so only the three spellings the socket layer can
// produce are accepted. The test suite's stub provider lives there; a real
// provider never does.
const LOOPBACK_HOSTS = new Set(['127.0.0.1', '::1', '[::1]']);
function isSecureUrl(u) {
  return u.protocol === 'https:' || LOOPBACK_HOSTS.has(u.hostname);
}

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
    let discoveryUrl;
    try { discoveryUrl = new URL(row.DISCOVERY); } catch { throw new Error('provider ' + file + ': DISCOVERY is not a URL'); }
    if (!isSecureUrl(discoveryUrl)) throw new Error('provider ' + file + ': DISCOVERY must be https, or loopback');
    out.set(slug, {
      slug, issuer: hasIss ? row.ISSUER : null, issuerTemplate: hasTpl ? row.ISSUER_TEMPLATE : null,
      clientId: row.CLIENT_ID, clientSecretFile: row.CLIENT_SECRET_FILE, discovery: row.DISCOVERY
    });
  }
  return out;
}

const DISCOVERY_TTL_MS = 3600 * 1000;
const discoveryCache = new Map(); // cacheKey(provider) -> { doc, at }

function cacheKey(provider) {
  // The slug plus the discovery URL: a real deployed provider has exactly
  // one discovery URL per slug, so this is the same key as "by slug" there.
  // Keying on the URL too keeps two distinct provider records (same slug,
  // different discovery endpoint) from shadowing each other's cache entry.
  return provider.slug + '::' + provider.discovery;
}

// EVERY CALL TO A PROVIDER IS BOUNDED. A provider that accepts the connection
// and never answers would otherwise hang a login forever; ten seconds is
// longer than any healthy discovery, JWKS or token exchange takes.
const FETCH_TIMEOUT_MS = 10000;
function timedFetch(fetchImpl, url, init) {
  return fetchImpl(url, Object.assign({}, init || {}, { signal: AbortSignal.timeout(FETCH_TIMEOUT_MS) }));
}

// AND EVERY ANSWER IS BOUNDED IN SIZE AS WELL AS IN TIME. The provider is a
// trusted party by construction, so this is the compromised-provider case: a
// discovery document or a JWKS of a gigabyte would otherwise be read whole
// into this process, and every key in such a JWKS handed to createPublicKey.
// 64 KiB is far above any real document of either kind - a JWKS of a hundred
// keys is a few kilobytes - so the cap also bounds the key count without
// counting keys.
//
// THE CAP IS MEASURED WHILE THE BODY ARRIVES, NOT AFTER IT HAS. A declared
// content-length over the cap is refused before a byte of the body is read,
// but a chunked answer declares nothing, and reading such a body to the end
// first bounds what is PARSED rather than what is RECEIVED - which is the
// wrong thing to bound when the sender is the one being defended against.
// Measured in review 2026-09-08 against a hostile provider on loopback: 512
// MiB chunked took the process from 45 to 598 MiB of RSS and then refused
// with V8's own "Cannot create a string longer than 0x1fffffe8" - not this
// cap's message at all, so the operator's log said "Error" and not why. So
// the chunks are summed as they land and the stream is abandoned the moment
// the sum passes the cap: leaving the for-await early cancels it, and the
// transfer stops.
//
// The message keeps the caller's own prefix, because serve.mjs allowlists
// those four prefixes for the operator's log and degrades anything else to a
// class name.
const MAX_BODY_BYTES = 65536;
async function boundedText(res, tooBig) {
  if (!res.body) return await res.text(); // no stream to read: an empty body
  let total = 0;
  const chunks = [];
  for await (const chunk of res.body) {
    total += chunk.length;
    if (total > MAX_BODY_BYTES) throw new Error(tooBig);
    chunks.push(chunk);
  }
  return Buffer.concat(chunks).toString('utf8');
}
async function boundedJson(res, what) {
  const declared = res.headers.get('content-length');
  const tooBig = what + ' answered a body over ' + MAX_BODY_BYTES + ' bytes';
  if (declared !== null && Number(declared) > MAX_BODY_BYTES) throw new Error(tooBig);
  const text = await boundedText(res, tooBig);
  try {
    return JSON.parse(text);
  } catch {
    throw new Error(what + ' answered something that is not JSON');
  }
}

export async function discover(provider, fetchImpl = fetch) {
  const key = cacheKey(provider);
  const hit = discoveryCache.get(key);
  if (hit && Date.now() - hit.at < DISCOVERY_TTL_MS) return hit.doc;
  const res = await timedFetch(fetchImpl, provider.discovery, { headers: { accept: 'application/json' } });
  if (!res.ok) throw new Error('discovery for ' + provider.slug + ' answered ' + res.status);
  const doc = await boundedJson(res, 'discovery for ' + provider.slug);
  for (const k of ['issuer', 'authorization_endpoint', 'token_endpoint', 'jwks_uri']) {
    if (typeof doc[k] !== 'string' || !doc[k]) throw new Error('discovery for ' + provider.slug + ' lacks ' + k);
  }
  // A DISCOVERY DOCUMENT IS NOT A LICENCE TO POINT ANYWHERE. Until here the
  // document is a stranger's JSON: whoever answers the discovery URL gets to
  // name the endpoint the desk will post the client secret to and the JWKS it
  // will verify signatures against. So the document must stay inside what the
  // estate already named.
  //
  // The issuer: a fixed-ISSUER provider's document must name that issuer byte
  // for byte, exactly as the id_token's iss is compared later. A template
  // provider's issuer varies by tenant and is checked per token instead, so
  // its endpoints are held to the discovery URL's own origin.
  let base;
  if (provider.issuer) {
    if (doc.issuer !== provider.issuer) throw new Error('discovery for ' + provider.slug + ' names another issuer');
    base = doc.issuer;
  } else {
    base = provider.discovery;
  }
  let baseOrigin;
  try { baseOrigin = new URL(base).origin; } catch { throw new Error('discovery for ' + provider.slug + ' has no usable origin'); }
  for (const k of ['authorization_endpoint', 'token_endpoint', 'jwks_uri']) {
    let u;
    try { u = new URL(doc[k]); } catch { throw new Error('discovery for ' + provider.slug + ' points ' + k + ' off its own origin'); }
    if (u.origin !== baseOrigin) throw new Error('discovery for ' + provider.slug + ' points ' + k + ' off its own origin');
    if (!isSecureUrl(u)) throw new Error('discovery for ' + provider.slug + ' names a plaintext ' + k);
  }
  const kept = { issuer: doc.issuer, authorization_endpoint: doc.authorization_endpoint, token_endpoint: doc.token_endpoint, jwks_uri: doc.jwks_uri };
  discoveryCache.set(key, { doc: kept, at: Date.now() });
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

export async function exchangeCode(provider, doc, { code, verifier, redirectUri }, fetchImpl = fetch) {
  // The secret is read at call time, never held: a rotated file takes effect
  // on the next login without a restart, and no copy lives in this process
  // between logins.
  const secret = readFileSync(provider.clientSecretFile, 'utf8').trim();
  const form = new URLSearchParams({
    grant_type: 'authorization_code', code, redirect_uri: redirectUri,
    client_id: provider.clientId, client_secret: secret, code_verifier: verifier
  });
  const res = await timedFetch(fetchImpl, doc.token_endpoint, {
    method: 'POST', body: form.toString(),
    headers: { 'content-type': 'application/x-www-form-urlencoded', accept: 'application/json' }
  });
  if (!res.ok) throw new Error('token endpoint for ' + provider.slug + ' answered ' + res.status);
  const body = await res.json();
  if (typeof body.id_token !== 'string' || !body.id_token) throw new Error('token endpoint for ' + provider.slug + ' returned no id_token');
  return body.id_token;
}

const jwksCache = new Map(); // slug + '::' + jwks_uri -> { keys: Map<kid, KeyObject>, at }

// A cache younger than this is trusted even on an unknown kid: an unknown
// kid this soon after the last fetch is a bad token, not a rotation, and
// refetching on every bad kid would let a single forged token drive
// unlimited JWKS requests.
const JWKS_MIN_REFRESH_MS = 60000;

async function jwksFor(provider, doc, kid, fetchImpl) {
  const cacheKey = provider.slug + '::' + doc.jwks_uri;
  const entry = jwksCache.get(cacheKey);
  const stale = !entry || (!entry.keys.has(kid) && Date.now() - entry.at >= JWKS_MIN_REFRESH_MS);
  if (!stale) return entry.keys.get(kid) || null;
  // Refresh on a cache miss, or on an unknown kid once the cache is at
  // least a minute old (rotation) - at most once per verification either way.
  const res = await timedFetch(fetchImpl, doc.jwks_uri, { headers: { accept: 'application/json' } });
  if (!res.ok) throw new Error('jwks for ' + provider.slug + ' answered ' + res.status);
  const body = await boundedJson(res, 'jwks for ' + provider.slug);
  const keys = new Map();
  for (const k of (body.keys || [])) {
    if (k.kty !== 'RSA' || !k.kid) continue;
    if (k.use && k.use !== 'sig') continue;
    // A KEY THAT NAMES ITS OWN ALGORITHM IS TAKEN AT ITS WORD. Every
    // signature here is verified as RS256, so a key published as RS512 is not
    // a key for this verification - keeping it would mean verifying an RS256
    // signature with a key its owner said was for something else. A key that
    // names no alg is unconstrained and stays.
    if (k.alg && k.alg !== 'RS256') continue;
    keys.set(k.kid, createPublicKey({ key: k, format: 'jwk' }));
  }
  const fresh = { keys, at: Date.now() };
  jwksCache.set(cacheKey, fresh);
  return fresh.keys.get(kid) || null;
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
  if (!header || typeof header !== 'object') refuse('malformed');
  if (!claims || typeof claims !== 'object') refuse('malformed');
  if (header.alg !== 'RS256') refuse('alg');
  if (typeof header.kid !== 'string') refuse('kid');
  let key;
  try {
    key = await jwksFor(provider, doc, header.kid, fetchImpl);
  } catch {
    // A JWKS fetch can fail (non-2xx) or time out (the bounded signal
    // aborts it); either way the caller gets the same id_token: prefix as
    // every other refusal, never a raw endpoint error or an AbortError.
    refuse('jwks unavailable');
  }
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
  if (!Number.isFinite(claims.exp) || claims.exp <= now) refuse('exp');
  if (!Number.isFinite(claims.iat) || Math.abs(claims.iat - now) > 300) refuse('iat');
  // nbf WHEN THE PROVIDER SENDS ONE - and it does; Microsoft always has. A
  // token that is not yet valid is not valid, and without this check its only
  // bound was the iat skew window. Absent it says nothing, so absent is fine;
  // present and not a number is a claim that cannot be honoured.
  if (claims.nbf !== undefined && (!Number.isFinite(claims.nbf) || claims.nbf > now + 300)) refuse('nbf');
  // The nonce must be a string as well as equal: a caller with no nonce at
  // hand would otherwise pass undefined, and a token that simply carries no
  // nonce claim would match it.
  if (typeof nonce !== 'string' || claims.nonce !== nonce) refuse('nonce');
  if (typeof claims.sub !== 'string' || !claims.sub) refuse('sub');
  return { sub: claims.sub, tid, email: typeof claims.email === 'string' ? claims.email : null };
}

export function identityOf(provider, claims) {
  const tenant = provider.issuerTemplate && claims.tid ? claims.tid + '.' : '';
  return 'oidc:' + provider.slug + ':' + tenant + claims.sub;
}
