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
const discoveryCache = new Map(); // cacheKey(provider) -> { doc, at }

function cacheKey(provider) {
  // The slug plus the discovery URL: a real deployed provider has exactly
  // one discovery URL per slug, so this is the same key as "by slug" there.
  // Keying on the URL too keeps two distinct provider records (same slug,
  // different discovery endpoint) from shadowing each other's cache entry.
  return provider.slug + '::' + provider.discovery;
}

export async function discover(provider, fetchImpl = fetch) {
  const key = cacheKey(provider);
  const hit = discoveryCache.get(key);
  if (hit && Date.now() - hit.at < DISCOVERY_TTL_MS) return hit.doc;
  const res = await fetchImpl(provider.discovery, { headers: { accept: 'application/json' } });
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
