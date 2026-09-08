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

export async function discover(provider, fetchImpl = fetch) {
  const key = cacheKey(provider);
  const hit = discoveryCache.get(key);
  if (hit && Date.now() - hit.at < DISCOVERY_TTL_MS) return hit.doc;
  const res = await timedFetch(fetchImpl, provider.discovery, { headers: { accept: 'application/json' } });
  if (!res.ok) throw new Error('discovery for ' + provider.slug + ' answered ' + res.status);
  const doc = await res.json();
  for (const k of ['issuer', 'authorization_endpoint', 'token_endpoint', 'jwks_uri']) {
    if (typeof doc[k] !== 'string' || !doc[k]) throw new Error('discovery for ' + provider.slug + ' lacks ' + k);
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

async function jwksFor(provider, doc, kid, fetchImpl) {
  const cacheKey = provider.slug + '::' + doc.jwks_uri;
  let entry = jwksCache.get(cacheKey);
  if (!entry || !entry.keys.has(kid)) {
    // Refresh once on an unknown kid (rotation), never more: a second miss is
    // a token this provider did not sign, not a cache that is behind.
    const res = await timedFetch(fetchImpl, doc.jwks_uri, { headers: { accept: 'application/json' } });
    if (!res.ok) throw new Error('jwks for ' + provider.slug + ' answered ' + res.status);
    const body = await res.json();
    const keys = new Map();
    for (const k of (body.keys || [])) {
      if (k.kty !== 'RSA' || !k.kid) continue;
      if (k.use && k.use !== 'sig') continue;
      keys.set(k.kid, createPublicKey({ key: k, format: 'jwk' }));
    }
    entry = { keys, at: Date.now() };
    jwksCache.set(cacheKey, entry);
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
  return 'oidc:' + provider.slug + ':' + (claims.tid ? claims.tid + '.' : '') + claims.sub;
}
