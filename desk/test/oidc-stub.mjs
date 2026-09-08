// A stub OpenID provider for the desk's tests: discovery, JWKS, authorize,
// token. Nothing here is shipped. One RS256 key per start; the token endpoint
// mints whatever the test asked for, so every refusal path has a fixture.
import http from 'node:http';
import { generateKeyPairSync, createSign, randomUUID } from 'node:crypto';

const b64u = (b) => Buffer.from(b).toString('base64url');

export async function startStub(opts = {}) {
  const { publicKey, privateKey } = generateKeyPairSync('rsa', { modulusLength: 2048 });
  const jwk = publicKey.export({ format: 'jwk' });
  const kid = 'k1';
  const stub = { lastAuthorize: null, tokenResponse: null, keyPair: { publicKey, privateKey }, kid, tokenCalls: [] };

  stub.mintIdToken = (claims = {}, o = {}) => {
    const now = Math.floor(Date.now() / 1000);
    const header = { alg: o.alg || 'RS256', typ: 'JWT', kid: o.kid || kid };
    const payload = Object.assign({
      iss: stub.issuer, aud: stub.lastAuthorize ? stub.lastAuthorize.get('client_id') : 'cid',
      iat: now, exp: now + 300, sub: 'sub-1', email: 'alice@example.test',
      nonce: stub.lastAuthorize ? stub.lastAuthorize.get('nonce') : undefined
    }, opts.tid ? { tid: opts.tid } : {}, claims);
    const signingInput = b64u(JSON.stringify(header)) + '.' + b64u(JSON.stringify(payload));
    const sig = createSign('RSA-SHA256').update(signingInput).sign(o.key || privateKey);
    return signingInput + '.' + b64u(sig);
  };

  const server = http.createServer((req, res) => {
    const u = new URL(req.url, stub.origin);
    const json = (code, body) => { res.writeHead(code, { 'content-type': 'application/json' }); res.end(JSON.stringify(body)); };
    if (u.pathname === '/.well-known/openid-configuration') {
      return json(200, { issuer: stub.issuer, authorization_endpoint: stub.origin + '/authorize', token_endpoint: stub.origin + '/token', jwks_uri: stub.origin + '/jwks' });
    }
    if (u.pathname === '/jwks') return json(200, { keys: [Object.assign({ kid, use: 'sig', alg: 'RS256' }, jwk)] });
    if (u.pathname === '/authorize') {
      stub.lastAuthorize = u.searchParams;
      const back = new URL(u.searchParams.get('redirect_uri'));
      back.searchParams.set('code', 'CODE');
      back.searchParams.set('state', u.searchParams.get('state'));
      res.writeHead(302, { location: back.toString() }); return res.end();
    }
    if (u.pathname === '/token' && req.method === 'POST') {
      let body = ''; req.setEncoding('utf8');
      req.on('data', (c) => { body += c; });
      req.on('end', () => {
        const form = new URLSearchParams(body);
        stub.tokenCalls.push({ form, auth: req.headers.authorization || null });
        if (form.get('code') !== 'CODE' || !form.get('code_verifier')) return json(400, { error: 'invalid_grant' });
        return json(200, stub.tokenResponse || { id_token: stub.mintIdToken(), token_type: 'Bearer' });
      });
      return;
    }
    json(404, { error: 'not_found' });
  });
  await new Promise((r) => server.listen(0, '127.0.0.1', r));
  stub.origin = 'http://127.0.0.1:' + server.address().port;
  stub.issuer = opts.issuer || stub.origin;
  stub.close = () => new Promise((r) => server.close(r));
  stub.id = randomUUID();
  return stub;
}
