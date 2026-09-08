// desk/cookie.mjs - the front's cookies.
//
// THE SESSION IS THE COOKIE. No server-side store: the value is the IDENTITY
// the provider proved, the issue time, and an HMAC over both under a key only
// this host holds. A forged value fails the mac; a copied value is the same
// session (that is what a session cookie is, and the 12 h lifetime bounds it).
// The key file is generated once by the estate, mode 0600, never shipped by
// the product.
//
// THE COOKIE CARRIES THE IDENTITY, NOT THE PRINCIPAL, because the principal
// is an ANSWER and the identity is the QUESTION. A cookie that named the
// principal could only ever be checked against "does that row still exist",
// and a row that exists while no longer claiming this identity - the word
// removed from OIDC_LOGIN, or moved to somebody else - would keep serving the
// person for the cookie's whole twelve hours. Carrying the identity lets
// serve.mjs ask the registry the same question the login asked, on every
// request, and get today's answer.
//
// THE IDENTITY IS BASE64URL INSIDE THE COOKIE. Its own form is
// `oidc:<slug>:<sub>` (or `oidc:<slug>:<tid>.<sub>`), which carries both `:`
// and `.` - and `.` is the separator of the cookie's three fields. Encoding
// it keeps the value one field, in a charset that cannot grow a separator,
// and the decode happens only after the MAC has verified.

import { createHmac, timingSafeEqual } from 'node:crypto';
import { readFileSync, statSync } from 'node:fs';

// The identity the front mints a session for, in the form desk/oidc.mjs's
// identityOf builds: the source, the provider slug, and a subject out of the
// URL-safe unreserved set with a multi-tenant provider's tenant folded in as
// `<tid>.<sub>`. Checked on the way out of the cookie, after the MAC.
const IDENTITY_RE = /^oidc:[a-z0-9][a-z0-9-]*:[A-Za-z0-9._~-]+$/;
// The charset base64url produces, checked before the MAC so that nothing but
// a padding-free base64url word is ever decoded.
const B64URL_RE = /^[A-Za-z0-9_-]+$/;

export function parseCookies(header) {
  const out = new Map();
  if (typeof header !== 'string') return out;
  for (const part of header.split(';')) {
    const i = part.indexOf('=');
    if (i === -1) continue;
    const name = part.slice(0, i).trim();
    if (!name) continue;
    out.set(name, part.slice(i + 1).trim());
  }
  return out;
}

// serializeCookie - one shape for every cookie the desk sets. __Host- prefix
// (the browser refuses it without Secure, Path=/ and no Domain), HttpOnly (no
// script reads it), SameSite=Lax (a cross-site POST never carries it).
export function serializeCookie(name, value, { maxAge }) {
  return name + '=' + value + '; Path=/; HttpOnly; Secure; SameSite=Lax; Max-Age=' + maxAge;
}

const b64u = (buf) => Buffer.from(buf).toString('base64url');

// ONE KEY, TWO PURPOSES, AND THE MAC SAYS WHICH. The session cookie and the
// state cookie are signed under the same host key, so without a label a value
// minted for one would verify as the other - and a state body is chosen in
// part by the flow, while a session body is an encoded identity. The label is
// part of the MAC input, never of the cookie, so nothing on the wire changes
// and a value from the wrong purpose simply fails the mac.
function mac(key, label, body) {
  return b64u(createHmac('sha256', key).update(label + ' ' + body).digest());
}

function macEquals(a, b) {
  const ba = Buffer.from(String(a)); const bb = Buffer.from(String(b));
  return ba.length === bb.length && timingSafeEqual(ba, bb);
}

export function loadSessionKey(path) {
  let st;
  try { st = statSync(path); } catch { throw new Error('session key file is missing'); }
  if ((st.mode & 0o777) !== 0o600) throw new Error('session key file must be mode 0600');
  if (st.uid !== process.getuid()) throw new Error('session key file must be owned by the desk account');
  const key = Buffer.from(readFileSync(path, 'utf8').trim());
  if (key.length < 32) throw new Error('session key must be at least 32 bytes');
  return key;
}

export function mintSession(key, identity, issuedAt) {
  const body = b64u(identity) + '.' + issuedAt;
  return body + '.' + mac(key, 'session', body);
}

// verifySession - the identity this cookie was minted for, or null. THE MAC
// COMES BEFORE THE DECODE: the two fields are charset-checked, the MAC is
// compared over exactly the bytes on the wire, and only then is the first
// field decoded and held to the identity's own form. So a value this host
// never minted is never parsed, and a value it did mint cannot carry a shape
// the caller does not expect.
export function verifySession(key, value, now, maxAgeSec = 43200) {
  const parts = String(value || '').split('.');
  if (parts.length !== 3) return null;
  const [encoded, issuedRaw, sig] = parts;
  if (!B64URL_RE.test(encoded) || !/^[0-9]+$/.test(issuedRaw)) return null;
  if (!macEquals(sig, mac(key, 'session', encoded + '.' + issuedRaw))) return null;
  const identity = Buffer.from(encoded, 'base64url').toString('utf8');
  if (!IDENTITY_RE.test(identity)) return null;
  const age = now - Number(issuedRaw);
  if (age < 0 || age > maxAgeSec) return null;
  return identity;
}

export function mintState(key, fields) {
  const body = b64u(JSON.stringify(fields));
  return body + '.' + mac(key, 'state', body);
}

export function verifyState(key, value, now, maxAgeSec = 600) {
  const parts = String(value || '').split('.');
  if (parts.length !== 2) return null;
  const [body, sig] = parts;
  if (!macEquals(sig, mac(key, 'state', body))) return null;
  let fields;
  try { fields = JSON.parse(Buffer.from(body, 'base64url').toString('utf8')); } catch { return null; }
  if (!fields || typeof fields.issuedAt !== 'number') return null;
  const age = now - fields.issuedAt;
  if (age < 0 || age > maxAgeSec) return null;
  return fields;
}
