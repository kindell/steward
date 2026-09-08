// desk/test/serve.test.mjs - the server, driven as a real child process over a
// real unix socket, against a real fixture estate.
//
// THE LOOKUP IS NOT STUBBED. An earlier draft of this task offered the server a
// STEWARD_DESK_PRINCIPAL_LOOKUP knob so a suite could aim it at a shell stub;
// that knob is a way to make the gate answer whatever a caller wants, shipped in
// production code, and it is not here. Instead the suite builds a fixture estate
// with principals.d rows and lets serve.mjs run its own bridge against it, so
// what is measured is the gate that will actually run.
//
// The estate carries two hand-written rows d1/d2 that BOTH claim the same login.
// The registry's write verb refuses to create that, but a human editing files
// can, and the library reports rc 65 for it - the "never a guess" case. A gate
// that picked the first row would hand one person another person's desk.
//
// Nothing here touches the machine's real config: HOME, STEWARD_ESTATE_ROOT and
// STEWARD_CONFIG_FILE are all mktemp locations, and so is the socket.
import test, { before, after, describe, it } from 'node:test';
import assert from 'node:assert/strict';
import http from 'node:http';
import net from 'node:net';
import os from 'node:os';
import { spawn } from 'node:child_process';
import { mkdtempSync, mkdirSync, writeFileSync, readFileSync, appendFileSync, unlinkSync, rmSync, existsSync, statSync, symlinkSync, chmodSync } from 'node:fs';
import { join, dirname } from 'node:path';
import { tmpdir } from 'node:os';
import { fileURLToPath } from 'node:url';

const SERVE = fileURLToPath(new URL('../serve.mjs', import.meta.url));
const LOOKUP_BIN = fileURLToPath(new URL('../bin/principal-for-login', import.meta.url));

// The front's own two imports: a stub OpenID provider, and the minter whose
// output the front must accept and whose forgeries it must not.
import { startStub } from './oidc-stub.mjs';
import { mintSession } from '../cookie.mjs';

// THE FIXTURE LIVES SOMEWHERE WITH A SHORT NAME, AND THAT IS NOT FUSSINESS. A
// unix socket path is capped by sockaddr_un (104 bytes on macOS), and this
// platform's os.tmpdir() is a 45-byte path on its own: a socket under it, in a
// mkdtemp directory, under the fixture HOME, is over the limit and the kernel
// TRUNCATES rather than refusing. Measured here on 2026-09-08 before serve.mjs
// grew the guard that now refuses it. /tmp keeps the whole path short enough to
// exercise the real default path; the guard itself is tested further down.
const TMP_BASE = existsSync('/tmp') ? '/tmp' : tmpdir();

const ESTATE_CONF = [
  'ESTATE_NAME="fixture"',
  'LABEL_PREFIX="com.fixture.claude"',
  'JOB_LABEL_PREFIX="com.fixture.job"',
  'SERVICE_LABEL_PREFIX="com.fixture.svc"',
  'RC_LABEL_PREFIX=""',
  'HUB_SESSION="hub"',
  'HUB_HOST="h1"',
  'STATE_DIR_NAME="fixture-supervisor"',
  'PAUSED_DIR_NAME="fixture-paused"',
  'TMUX_SOCKET="fixture.sock"',
  'OP_TOKEN_FILE_NAME="fixture-token"',
  'PING_MSG="mail"',
  ''
].join('\n');

const now = () => new Date().toISOString().replace(/\.\d+Z$/, 'Z');

function snapshotFor(viewer, readAll, sessions) {
  return {
    schemaVersion: 1,
    host: 'h1',
    generatedAt: now(),
    registryRevision: 'abc1234',
    viewer,
    readAll,
    entities: [{ id: 'team', name: 'Team', managedBy: null, members: ['a', 'b'], member: !readAll }],
    projects: [{ id: 'work', name: 'Work', parent: 'team' }],
    sessions
  };
}

const sessionOne = {
  id: 's-1', slug: 'work-a', label: 'Work A', owner: 'a', mine: false,
  domain: 'team', project: 'work', runtime: 'codex', host: 'h1', repo: 'repo',
  liveness: { state: 'running', measuredAt: '2026-09-08T00:00:00Z', ageSeconds: 60 },
  mcp: [{ id: 'shared', name: 'shared', axis: 'entity', source: 'team' }]
};

// The session only the read-all viewer's file carries. Its id is hex so it
// MATCHES the server's session route - a route miss would prove nothing about
// whether one viewer can read another viewer's file.
const sessionHidden = {
  id: 's-00ff', slug: 'other-c', label: 'Other', owner: 'c', mine: false,
  domain: 'e1', project: null, runtime: 'codex', host: 'h1', repo: 'repo',
  liveness: { state: 'unknown', measuredAt: '2026-09-08T00:00:00Z', ageSeconds: null },
  mcp: []
};

let T, ROOT, HOME, DESK, GEN, SOCK, child, childErr = '';

// Build an estate with only the rows the gate reads.
function buildEstate(root) {
  mkdirSync(join(root, 'estate'), { recursive: true });
  mkdirSync(join(root, 'principals.d'), { recursive: true });
  writeFileSync(join(root, 'estate', 'steward.conf'), ESTATE_CONF);
  writeFileSync(join(root, 'principals.d', 'a.conf'), 'NAME="Ann"\nTAILSCALE_LOGIN="a@example.com"\nDESK_READ_ALL="yes"\n');
  writeFileSync(join(root, 'principals.d', 'b.conf'), 'NAME="Ben"\nTAILSCALE_LOGIN="b@example.com"\n');
  writeFileSync(join(root, 'principals.d', 'c.conf'), 'NAME="Cy"\nTAILSCALE_LOGIN="c@example.com"\n');
  writeFileSync(join(root, 'principals.d', 'd1.conf'), 'NAME="Dee One"\nTAILSCALE_LOGIN="two@example.com"\n');
  writeFileSync(join(root, 'principals.d', 'd2.conf'), 'NAME="Dee Two"\nTAILSCALE_LOGIN="two@example.com"\n');
}

const childEnv = (over) => Object.assign({
  PATH: process.env.PATH,
  HOME,
  STEWARD_ESTATE_ROOT: ROOT,
  STEWARD_CONFIG_FILE: join(T, 'no-such-config'),
  STEWARD_DESK_DIR: DESK,
  STEWARD_DESK_SOCK: SOCK
}, over || {});

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

// HOW LONG A SERVER IS GIVEN TO COME UP, AND WHY IT IS NOT FIVE SECONDS.
// Every readiness wait below is a 25 ms POLL, so a server that is up in 40 ms
// is waited for for 40 ms and this number costs nothing on a quiet box - it
// is the ceiling before the wait is called a failure, not a sleep. What has
// to fit under it is a full node spawn plus an estate load plus a bridge that
// forks a subshell per principal row, on a box that may be running several
// sibling suites at once. Five seconds is inside the range that machine
// actually takes, which is why this suite failed sometimes and passed
// sometimes with nothing wrong; twenty is far outside it. A real hang still
// ends here, with the same message, twenty seconds later.
const UP_CAP_MS = 20000;

async function waitForSocket(path, capMs) {
  const until = Date.now() + capMs;
  while (Date.now() < until) {
    if (existsSync(path)) return true;
    await sleep(25);
  }
  return false;
}

function req(method, path, headers) {
  return new Promise((resolve, reject) => {
    const r = http.request({ socketPath: SOCK, path, method, headers: headers || {}, agent: false }, (res) => {
      let body = '';
      res.setEncoding('utf8');
      res.on('data', (c) => { body += c; });
      res.on('end', () => resolve({ status: res.statusCode, headers: res.headers, body }));
    });
    r.on('error', reject);
    r.end();
  });
}

const get = (path, headers) => req('GET', path, headers);
const B = { 'tailscale-user-login': 'b@example.com' };
const A = { 'tailscale-user-login': 'a@example.com' };

// SELF_ORIGIN_BODY - the exact refusal text a self-origin request gets. Kept
// as one constant so a typo in the production string shows up as a failing
// equality, not a passing substring match.
const SELF_ORIGIN_BODY = "a request from the desk's own host cannot be attributed to a person";

// firstSelfAddr - one non-internal address of the test host itself, the same
// set serve.mjs collects at startup. Used to prove the gate refuses a real
// forwarded-address collision, not just a hand-picked STEWARD_DESK_SELF_ADDRS
// value.
function firstSelfAddr() {
  for (const ifaces of Object.values(os.networkInterfaces())) {
    for (const iface of ifaces || []) {
      if (!iface.internal) return iface.address;
    }
  }
  return null;
}

// runToExit - start serve.mjs with an env that should make it refuse, and
// collect how it refused. Used for the two startup refusals (64 and 78). A
// mutation that lets the server start instead of refusing must not hang this
// suite forever, so a caller who never exits on its own is killed after 5s
// and reported as { code: null }, which fails the caller's own assertion on
// a specific exit code rather than blocking every test after it.
function runToExit(env) {
  return new Promise((resolve) => {
    const p = spawn(process.execPath, [SERVE], { env, stdio: ['ignore', 'ignore', 'pipe'] });
    let err = '';
    p.stderr.setEncoding('utf8');
    p.stderr.on('data', (c) => { err += c; });
    const t = setTimeout(() => { p.kill('SIGKILL'); resolve({ code: null, err }); }, 5000);
    t.unref();
    p.on('close', (code) => { clearTimeout(t); resolve({ code, err }); });
  });
}

// spawnUp - a SECOND server instance, its own process, its own socket. Used
// by the outage and socket-ownership tests below, which each need a server
// that actually starts (unlike runToExit's callers) so a request can be sent
// to it. Resolves once the socket exists; the caller reads stderr through
// getErr() whenever it matters in the test.
function spawnUp(env, sockPath) {
  return new Promise((resolve, reject) => {
    const p = spawn(process.execPath, [SERVE], { env, stdio: ['ignore', 'ignore', 'pipe'] });
    let err = '';
    p.stderr.setEncoding('utf8');
    p.stderr.on('data', (c) => { err += c; });
    (async () => {
      const up = await waitForSocket(sockPath, UP_CAP_MS);
      if (!up) {
        try { p.kill('SIGKILL'); } catch { /* already gone */ }
        reject(new Error('server never bound ' + sockPath + '; stderr so far: ' + err));
        return;
      }
      resolve({ proc: p, getErr: () => err });
    })();
  });
}

async function stopSpawned(handle) {
  if (handle.proc.exitCode !== null) return;
  const done = new Promise((r) => handle.proc.on('close', r));
  handle.proc.kill('SIGTERM');
  await Promise.race([done, sleep(2000)]);
  if (handle.proc.exitCode === null) handle.proc.kill('SIGKILL');
}

// freePort - listen on port 0 with a throwaway server, read back what the
// kernel picked, close it, and hand the number to a test. There is a race
// between the close and the desk's own listen, the same race any test that
// picks "a free port" runs; it is not reproducible any other way.
function freePort() {
  return new Promise((resolve, reject) => {
    const s = net.createServer();
    s.on('error', reject);
    s.listen(0, '127.0.0.1', () => {
      const { port } = s.address();
      s.close(() => resolve(port));
    });
  });
}

function reqHttp(host, port, method, path, headers) {
  return new Promise((resolve, reject) => {
    const r = http.request({ host, port, path, method, headers: headers || {} }, (res) => {
      let body = '';
      res.setEncoding('utf8');
      res.on('data', (c) => { body += c; });
      res.on('end', () => resolve({ status: res.statusCode, headers: res.headers, body }));
    });
    r.on('error', reject);
    r.end();
  });
}

function spawnDesk(env) {
  const p = spawn(process.execPath, [SERVE], { env, stdio: ['ignore', 'ignore', 'pipe'] });
  let err = '';
  p.stderr.setEncoding('utf8');
  p.stderr.on('data', (c) => { err += c; });
  return { proc: p, getErr: () => err };
}

// spawnUpTcp - like spawnUp, but there is no socket file to poll for, so
// readiness is "a request got a response at all" instead.
async function spawnUpTcp(env, host, port, capMs) {
  const handle = spawnDesk(env);
  const until = Date.now() + (capMs || UP_CAP_MS);
  while (Date.now() < until) {
    if (handle.proc.exitCode !== null) {
      throw new Error('server exited before answering; code ' + handle.proc.exitCode + '; stderr: ' + handle.getErr());
    }
    try {
      await reqHttp(host, port, 'GET', '/desk/', {});
      return handle;
    } catch {
      await sleep(25);
    }
  }
  try { handle.proc.kill('SIGKILL'); } catch { /* already gone */ }
  throw new Error('server never answered on ' + host + ':' + port + '; stderr: ' + handle.getErr());
}

function reqTo(sockPath, method, path, headers) {
  return new Promise((resolve, reject) => {
    const r = http.request({ socketPath: sockPath, path, method, headers: headers || {}, agent: false }, (res) => {
      let body = '';
      res.setEncoding('utf8');
      res.on('data', (c) => { body += c; });
      res.on('end', () => resolve({ status: res.statusCode, headers: res.headers, body }));
    });
    r.on('error', reject);
    r.end();
  });
}

const writeB = () => writeFileSync(join(GEN, 'b.json'), JSON.stringify(snapshotFor('b', false, [sessionOne])));

before(async () => {
  T = mkdtempSync(join(TMP_BASE, 'dk-'));
  ROOT = join(T, 'estate');
  HOME = join(T, 'home');
  DESK = join(T, 'desk');
  GEN = join(DESK, 'gen-1');
  SOCK = join(T, 'd.sock');
  mkdirSync(HOME, { recursive: true });
  buildEstate(ROOT);

  // THE GENERATIONS LAYOUT, MIRRORED. The producer writes gen-<ts>/ and moves
  // the `current` symlink; a server that read <dir>/<viewer>.json would find
  // nothing here, which is the reason for building it this way.
  mkdirSync(GEN, { recursive: true });
  writeB();
  writeFileSync(join(GEN, 'a.json'), JSON.stringify(snapshotFor('a', true, [sessionOne, sessionHidden])));
  symlinkSync('gen-1', join(DESK, 'current'));

  child = spawn(process.execPath, [SERVE], { env: childEnv(), stdio: ['ignore', 'ignore', 'pipe'] });
  child.stderr.setEncoding('utf8');
  child.stderr.on('data', (c) => { childErr += c; });
  const up = await waitForSocket(SOCK, UP_CAP_MS);
  assert.ok(up, 'the server never created its socket; stderr: ' + childErr);
});

after(async () => {
  if (child && child.exitCode === null) {
    const done = new Promise((r) => child.on('close', r));
    child.kill('SIGTERM');
    await Promise.race([done, sleep(2000)]);
    if (child.exitCode === null) child.kill('SIGKILL');
  }
  if (T) rmSync(T, { recursive: true, force: true });
});

test('no login header is 403', async () => {
  assert.equal((await get('/desk/', {})).status, 403);
});

test('unknown login is 403', async () => {
  assert.equal((await get('/desk/', { 'tailscale-user-login': 'x@example.com' })).status, 403);
});

test('a login on two principals is 403, never a guess', async () => {
  const r = await get('/desk/', { 'tailscale-user-login': 'two@example.com' });
  assert.equal(r.status, 403);
  const unknown = await get('/desk/', { 'tailscale-user-login': 'x@example.com' });
  assert.equal(r.body, unknown.body, '403 must have one body, whatever the reason');
});

test('a malformed header value is 403 without a lookup', async () => {
  for (const v of ['', ' ', 'b@example.com x', 'b@example.com\u00e9', 'a'.repeat(300)]) {
    assert.equal((await get('/desk/', { 'tailscale-user-login': v })).status, 403, 'accepted: ' + JSON.stringify(v));
  }
});

test('two copies of the header are 403, never the first one', async () => {
  const r = await get('/desk/', { 'tailscale-user-login': ['a@example.com', 'b@example.com'] });
  assert.equal(r.status, 403);
});

test('no other carrier of a login is consulted', async () => {
  assert.equal((await get('/desk/?tailscale-user-login=b@example.com', {})).status, 403);
  assert.equal((await get('/desk/', { cookie: 'tailscale-user-login=b@example.com' })).status, 403);
  assert.equal((await get('/desk/', { 'x-forwarded-user': 'b@example.com' })).status, 403);
});

test('a known login gets the index', async () => {
  const r = await get('/desk/', B);
  assert.equal(r.status, 200);
  assert.ok(r.body.includes('work-a'));
});

test('the login is matched case-insensitively, by the library', async () => {
  assert.equal((await get('/desk/', { 'tailscale-user-login': 'B@Example.COM' })).status, 200);
});

test('a session outside the view is the same 404 as an unknown id', async () => {
  const r1 = await get('/desk/session/s-9', B);
  const r2 = await get('/desk/session/s-00ff', B);
  assert.equal(r1.status, 404);
  assert.deepEqual([r1.status, r1.body], [r2.status, r2.body]);
  // and the read-all viewer, whose file does carry it, sees it
  assert.equal((await get('/desk/session/s-00ff', A)).status, 200);
});

test('an unknown route has the same 404 body', async () => {
  const r1 = await get('/desk/nothing', B);
  const r2 = await get('/desk/session/s-9', B);
  assert.equal(r1.status, 404);
  assert.equal(r1.body, r2.body);
});

test('outside the prefix is 404', async () => {
  assert.equal((await get('/', B)).status, 404);
  assert.equal((await get('/desk', B)).status, 404);
  assert.equal((await get('/etc/passwd', B)).status, 404);
});

test('a traversal in an id never leaves the routes', async () => {
  for (const p of ['/desk/team/../../etc/passwd', '/desk/session/s-1/../s-00ff', '/desk/project/%2e%2e%2f']) {
    assert.equal((await get(p, B)).status, 404, 'routed: ' + p);
  }
});

test('the team and project pages answer for ids in the view', async () => {
  assert.equal((await get('/desk/team/team', B)).status, 200);
  assert.equal((await get('/desk/project/work', B)).status, 200);
  assert.equal((await get('/desk/team/e1', B)).status, 404);
});

test('the headers are the gate', async () => {
  const r = await get('/desk/', B);
  const want = {
    'cache-control': 'no-store',
    'x-content-type-options': 'nosniff',
    'x-frame-options': 'DENY',
    'referrer-policy': 'no-referrer'
  };
  for (const [k, v] of Object.entries(want)) assert.equal(r.headers[k], v);
  assert.ok(r.headers['content-security-policy'].startsWith("default-src 'none'"));
  assert.ok(r.headers['content-type'].startsWith('text/html'));
});

test('the refusals carry the same headers as a page', async () => {
  for (const r of [await get('/desk/', {}), await get('/desk/nothing', B)]) {
    assert.equal(r.headers['cache-control'], 'no-store');
    assert.equal(r.headers['x-frame-options'], 'DENY');
  }
});

test('HEAD is allowed and carries no body', async () => {
  const r = await req('HEAD', '/desk/', B);
  assert.equal(r.status, 200);
  assert.equal(r.body, '');
});

test('POST is 405', async () => {
  const r = await req('POST', '/desk/', B);
  assert.equal(r.status, 405);
  assert.equal(r.headers.allow, 'GET, HEAD');
});

test('the socket is the owner s alone', () => {
  assert.equal(statSync(SOCK).mode & 0o777, 0o600);
});

test('a viewer with no snapshot file is 503', async () => {
  assert.equal((await get('/desk/', { 'tailscale-user-login': 'c@example.com' })).status, 503);
});

test('a stale snapshot is 503', async () => {
  const snap = snapshotFor('b', false, [sessionOne]);
  snap.generatedAt = new Date(Date.now() - 2 * 3600e3).toISOString().replace(/\.\d+Z$/, 'Z');
  writeFileSync(join(GEN, 'b.json'), JSON.stringify(snap));
  try {
    assert.equal((await get('/desk/', B)).status, 503);
  } finally {
    writeB();
  }
});

test('a malformed snapshot is 503', async () => {
  writeFileSync(join(GEN, 'b.json'), '{');
  try {
    const r = await get('/desk/', B);
    assert.equal(r.status, 503);
    const stale = r.body;
    writeFileSync(join(GEN, 'b.json'), JSON.stringify({ schemaVersion: 2, host: 'h1', generatedAt: now() }));
    const r2 = await get('/desk/', B);
    assert.equal(r2.status, 503, 'a schema this server does not know is not a page');
    assert.equal(r2.body, stale, '503 must have one body, whatever the reason');
  } finally {
    writeB();
  }
});

test('the snapshot is read again on every request', async () => {
  assert.equal((await get('/desk/', B)).status, 200, 'the good file must be served after the bad ones');
});

test('a bad max age is a refusal at startup, never a silent default', async () => {
  const r = await runToExit(childEnv({ STEWARD_DESK_MAX_AGE: 'soon' }));
  assert.equal(r.code, 64);
  assert.ok(/STEWARD_DESK_MAX_AGE/.test(r.err), r.err);
  assert.equal(r.err.trim().split('\n').length, 1);
});

test('a socket path the kernel would truncate is a refusal, never a bind', async () => {
  const tooLong = join(tmpdir(), 'd'.repeat(120) + '.sock');
  const r = await runToExit(childEnv({ STEWARD_DESK_SOCK: tooLong }));
  assert.equal(r.code, 64);
  assert.ok(/socket path/.test(r.err), r.err);
  // Nothing exists under the truncated prefix either - the property that
  // actually matters, since !existsSync(tooLong) alone would hold no matter
  // what the server did (a 120-character path could never exist regardless).
  const truncated = tooLong.slice(0, 103);
  assert.ok(!existsSync(truncated), 'nothing must be bound under the truncated prefix: ' + truncated);
});

test('an estate that does not load is a refusal, never a guessed path', async () => {
  const bare = join(T, 'bare');
  mkdirSync(bare, { recursive: true });
  const env = childEnv({ STEWARD_ESTATE_ROOT: bare });
  delete env.STEWARD_DESK_DIR;
  delete env.STEWARD_DESK_SOCK;
  const r = await runToExit(env);
  assert.equal(r.code, 78);
});

test('the default paths come from the bridge, not from a literal', async () => {
  const env = childEnv();
  delete env.STEWARD_DESK_DIR;
  delete env.STEWARD_DESK_SOCK;
  const p = spawn(process.execPath, [SERVE], { env, stdio: ['ignore', 'ignore', 'pipe'] });
  let err = '';
  p.stderr.setEncoding('utf8');
  p.stderr.on('data', (c) => { err += c; });
  const want = join(HOME, '.local', 'state', 'fixture-supervisor', 'desk.sock');
  try {
    const until = Date.now() + UP_CAP_MS;
    while (Date.now() < until && !existsSync(want)) await sleep(25);
    assert.ok(existsSync(want), 'the bridge s socket was never created; stderr: ' + err);
    assert.equal(statSync(want).mode & 0o777, 0o600);
    assert.ok(existsSync(dirname(want)));
  } finally {
    const done = new Promise((r) => p.on('close', r));
    p.kill('SIGTERM');
    await Promise.race([done, sleep(2000)]);
  }
});

// This pins the SILENT 403 PATH only: rc 1 (no such login) and rc 65 (two
// rows claim it) are ordinary events on a shared tailnet and must never fill
// a log. It is not a claim that this server never logs anything - the outage
// tests further down use their own child processes and assert the opposite:
// exactly one console.error line, every time the bridge cannot answer at all.
// This shared child only ever exercises the policy path (unknown login,
// ambiguous login, malformed header), so its stderr stays at the one startup
// line for the whole suite.
test('the server writes nothing but one startup line to stderr on the silent 403 path', () => {
  assert.equal(childErr.trim().split('\n').length, 1, childErr);
  assert.ok(childErr.includes(SOCK));
  assert.ok(!/SENTINEL|Error|error:/.test(childErr), childErr);
});

// ---------------------------------------------------------------------------
// A REQUEST FROM THE DESK'S OWN HOST CANNOT BE ATTRIBUTED TO A PERSON. The
// tailnet client identifies the node, not the local account, so traffic the
// desk host originates toward its own socket carries the node owner's login
// no matter which local account actually sent it. These come after the
// stderr-line pin above (the shared child now logs an extra refusal line for
// each test that hits it), and before the outage block, which needs the
// shared child to stay on the silent 403 path for ITS OWN assertions too -
// none of those are stderr line counts, so the extra lines here do not
// disturb them.

test('a request forwarded from the desk own host is refused', async (t) => {
  const addr = firstSelfAddr();
  if (!addr) {
    t.skip('no non-internal interface address on this host');
    return;
  }
  const r = await get('/desk/', Object.assign({ 'x-forwarded-for': addr }, B));
  assert.equal(r.status, 403);
  assert.equal(r.body, SELF_ORIGIN_BODY);
  assert.ok(!r.body.includes('work-a'), 'no desk content must leak into a self-origin refusal');
});

test('STEWARD_DESK_SELF_ADDRS extends what counts as the desk s own host', async () => {
  const sock2 = join(T, 'self-addrs.sock');
  const env = childEnv({ STEWARD_DESK_SOCK: sock2, STEWARD_DESK_SELF_ADDRS: '192.0.2.7' });
  let handle;
  try {
    handle = await spawnUp(env, sock2);
    const r = await reqTo(sock2, 'GET', '/desk/', Object.assign({ 'x-forwarded-for': '192.0.2.7' }, B));
    assert.equal(r.status, 403);
    assert.equal(r.body, SELF_ORIGIN_BODY);
  } finally {
    if (handle) await stopSpawned(handle);
  }
});

test('a forwarded address that is not self does not affect the gate', async () => {
  const r = await get('/desk/', Object.assign({ 'x-forwarded-for': '198.51.100.9' }, B));
  assert.equal(r.status, 200);
  assert.ok(r.body.includes('work-a'));
});

test('no x-forwarded-for header at all is unaffected', async () => {
  const r = await get('/desk/', B);
  assert.equal(r.status, 200);
  assert.ok(r.body.includes('work-a'));
});

// ANY ENTRY WINS, NOT THE FIRST ONE. This desk is the terminus of the chain,
// never a hop: the proxy in front of it inserts the inbound node's own
// address and APPENDS a client-supplied X-Forwarded-For rather than
// replacing it, so the self address can land anywhere in the list. A gate
// that only read the first entry is bypassed by one header a local account
// can set itself: `curl -H 'x-forwarded-for: 198.51.100.9'` arrives here as
// `198.51.100.9, <node addr>`, self last. Reading every entry costs nothing
// a real remote caller pays for, since a legitimate chain never happens to
// contain this host's own address.
test('a forwarded chain with self last is still refused', async (t) => {
  const addr = firstSelfAddr();
  if (!addr) {
    t.skip('no non-internal interface address on this host');
    return;
  }
  const r = await get('/desk/', Object.assign({ 'x-forwarded-for': '198.51.100.9, ' + addr }, B));
  assert.equal(r.status, 403);
  assert.equal(r.body, SELF_ORIGIN_BODY);
});

test('a forwarded chain with self first is still refused', async (t) => {
  const addr = firstSelfAddr();
  if (!addr) {
    t.skip('no non-internal interface address on this host');
    return;
  }
  const r = await get('/desk/', Object.assign({ 'x-forwarded-for': addr + ', 198.51.100.9' }, B));
  assert.equal(r.status, 403);
  assert.equal(r.body, SELF_ORIGIN_BODY);
});

test('a forwarded chain of two addresses, neither self, does not affect the gate', async () => {
  const r = await get('/desk/', Object.assign({ 'x-forwarded-for': '198.51.100.9, 203.0.113.5' }, B));
  assert.equal(r.status, 200);
  assert.ok(r.body.includes('work-a'));
});

test('the forwarded address is normalized: any entry wins, mapped IPv4 form stripped', async () => {
  const sock2 = join(T, 'self-norm.sock');
  const env = childEnv({ STEWARD_DESK_SOCK: sock2, STEWARD_DESK_SELF_ADDRS: '192.0.2.7' });
  let handle;
  try {
    handle = await spawnUp(env, sock2);
    const r = await reqTo(sock2, 'GET', '/desk/', Object.assign({ 'x-forwarded-for': '198.51.100.9, ::ffff:192.0.2.7' }, B));
    assert.equal(r.status, 403);
    assert.equal(r.body, SELF_ORIGIN_BODY);
  } finally {
    if (handle) await stopSpawned(handle);
  }
});

test('STEWARD_DESK_SELF_ADDRS is normalized the same way a header entry is: mapped IPv4 form', async () => {
  const sock2 = join(T, 'self-addrs-mapped.sock');
  const env = childEnv({ STEWARD_DESK_SOCK: sock2, STEWARD_DESK_SELF_ADDRS: '::ffff:192.0.2.7' });
  let handle;
  try {
    handle = await spawnUp(env, sock2);
    const r = await reqTo(sock2, 'GET', '/desk/', Object.assign({ 'x-forwarded-for': '192.0.2.7' }, B));
    assert.equal(r.status, 403);
    assert.equal(r.body, SELF_ORIGIN_BODY);
  } finally {
    if (handle) await stopSpawned(handle);
  }
});

test('a bracketed IPv6 literal with a trailing port is normalized to the bare address', async () => {
  const sock2 = join(T, 'self-bracket-port.sock');
  const env = childEnv({ STEWARD_DESK_SOCK: sock2, STEWARD_DESK_SELF_ADDRS: '192.0.2.7' });
  let handle;
  try {
    handle = await spawnUp(env, sock2);
    const r = await reqTo(sock2, 'GET', '/desk/', Object.assign({ 'x-forwarded-for': '[::ffff:192.0.2.7]:41234' }, B));
    assert.equal(r.status, 403);
    assert.equal(r.body, SELF_ORIGIN_BODY);
  } finally {
    if (handle) await stopSpawned(handle);
  }
});

// THE TRAILING-PORT GUARD NEVER EATS PART OF A BARE IPV6 ADDRESS. Stripping a
// trailing `:<port>` only applies when what remains still has no colon of its
// own (see normalizeAddr); without that guard a bare address like
// `2001:db8::7` is misread as host `2001:db8:` with port `7`, and a different
// address that merely shares the same prefix before the last colon would
// collide with it once both are truncated to `2001:db8:`.
test('a bare IPv6 self address is not truncated into colliding with an unrelated address', async () => {
  const sock2 = join(T, 'self-ipv6-guard.sock');
  const env = childEnv({ STEWARD_DESK_SOCK: sock2, STEWARD_DESK_SELF_ADDRS: '2001:db8::7' });
  let handle;
  try {
    handle = await spawnUp(env, sock2);
    const r = await reqTo(sock2, 'GET', '/desk/', Object.assign({ 'x-forwarded-for': '2001:db8::9' }, B));
    assert.equal(r.status, 200);
    assert.ok(r.body.includes('work-a'));
  } finally {
    if (handle) await stopSpawned(handle);
  }
});

// AN EXTRA ADDRESS THAT NORMALIZES TO EMPTY MUST NEVER JOIN SELF_ADDRS. The
// non-empty check on a STEWARD_DESK_SELF_ADDRS token runs on the raw token,
// before normalizeAddr strips it down - a token like `::ffff:` is non-empty
// on its own but normalizes to the empty string, and an empty string sitting
// in SELF_ADDRS would match the empty string a trailing comma in a
// forwarded-for header also normalizes to (a split on a trailing comma
// always yields one blank final entry).
test('an extra self address that normalizes to empty never matches a blank forwarded-for entry', async () => {
  const sock2 = join(T, 'self-addrs-empty.sock');
  const env = childEnv({ STEWARD_DESK_SOCK: sock2, STEWARD_DESK_SELF_ADDRS: '::ffff:' });
  let handle;
  try {
    handle = await spawnUp(env, sock2);
    const r = await reqTo(sock2, 'GET', '/desk/', Object.assign({ 'x-forwarded-for': '198.51.100.9,' }, B));
    assert.equal(r.status, 200);
    assert.ok(r.body.includes('work-a'));
  } finally {
    if (handle) await stopSpawned(handle);
  }
});

// ---------------------------------------------------------------------------
// A DEAD GATE IS AN OUTAGE, NOT A REFUSAL. Everything below spawns its own
// server, because the shared `child` above must stay on the silent 403 path
// for the assertion just above to mean anything.

test('a bridge that is not executable is an outage at startup, before a socket exists', async () => {
  const mode = statSync(LOOKUP_BIN).mode;
  chmodSync(LOOKUP_BIN, 0o600); // remove every exec bit
  try {
    const sock2 = join(T, 'noexec.sock');
    const r = await runToExit(childEnv({ STEWARD_DESK_SOCK: sock2 }));
    assert.equal(r.code, 78);
    assert.ok(/principal-for-login/.test(r.err), r.err);
    assert.equal(r.err.trim().split('\n').length, 1, r.err);
    assert.ok(!existsSync(sock2), 'no socket must exist when the bridge cannot even run');
  } finally {
    chmodSync(LOOKUP_BIN, mode);
  }
});

test('a bridge that fails on every request is a 503 outage, with one stderr line, never a silent 403', async () => {
  // STEWARD_DESK_DIR and STEWARD_DESK_SOCK are given directly, so this second
  // instance never calls desk-paths and starts fine even though the estate it
  // is pointed at cannot be sourced - the failure only shows up once a
  // request actually spawns principal-for-login.
  const dir2 = join(T, 'outage-desk');
  const gen2 = join(dir2, 'gen-1');
  mkdirSync(gen2, { recursive: true });
  writeFileSync(join(gen2, 'b.json'), JSON.stringify(snapshotFor('b', false, [sessionOne])));
  symlinkSync('gen-1', join(dir2, 'current'));
  const sock2 = join(T, 'outage.sock');
  const env = childEnv({
    STEWARD_DESK_DIR: dir2,
    STEWARD_DESK_SOCK: sock2,
    STEWARD_REGISTRY_LIB: join(T, 'no-such-registry.sh')
  });
  let handle;
  try {
    handle = await spawnUp(env, sock2);
    const stale = await get('/desk/', { 'tailscale-user-login': 'c@example.com' }); // main child, 503 no snapshot
    assert.equal(stale.status, 503);

    const r = await reqTo(sock2, 'GET', '/desk/', B);
    assert.equal(r.status, 503);
    assert.equal(r.body, stale.body, '503 must have one body, whatever the reason');

    const err = handle.getErr();
    const lines = err.trim().split('\n');
    assert.equal(lines.length, 2, err); // the startup line, and exactly one outage line
    assert.ok(/principal-for-login failed/.test(lines[1]), err);
    assert.ok(/rc=78/.test(lines[1]), err);
    assert.ok(!err.includes('b@example.com'), 'the header value itself must never be logged: ' + err);
  } finally {
    if (handle) await stopSpawned(handle);
  }
});

test('rc 1 and rc 65 stay the silent 403, never the 503 outage body', async () => {
  const unknown = await get('/desk/', { 'tailscale-user-login': 'x@example.com' });
  const ambiguous = await get('/desk/', { 'tailscale-user-login': 'two@example.com' });
  assert.equal(unknown.status, 403);
  assert.equal(ambiguous.status, 403);
  assert.equal(unknown.body, ambiguous.body);
});

test('a stale socket file is replaced, and the server binds behind it', async () => {
  // A LEFTOVER, NOT A LIVE SOCKET. Node's own server.close() unlinks the
  // path it was listening on, so a crashed process is the only real source
  // of a dead socket file - not reproducible by listen-then-close here. A
  // plain file at the path stands in for it: connect() fails on it exactly
  // the way it fails on a genuinely dead socket (some error, never
  // 'connect'), which is the only distinction serve.mjs's probe makes.
  const sock2 = join(T, 'stale.sock');
  writeFileSync(sock2, '');
  assert.ok(existsSync(sock2), 'the leftover file must exist before the server starts');

  // existsSync(sock2) is already true - it is our own placeholder file - so
  // waitForSocket's file-presence check would pass instantly and prove
  // nothing. Poll with a real request instead: the leftover file answers
  // ENOTSOCK until the server has actually replaced it and is listening.
  const env = childEnv({ STEWARD_DESK_SOCK: sock2 });
  const p = spawn(process.execPath, [SERVE], { env, stdio: ['ignore', 'ignore', 'pipe'] });
  let err = '';
  p.stderr.setEncoding('utf8');
  p.stderr.on('data', (c) => { err += c; });
  try {
    let r = null;
    const until = Date.now() + UP_CAP_MS;
    while (Date.now() < until) {
      try {
        r = await reqTo(sock2, 'GET', '/desk/', B);
        break;
      } catch {
        await sleep(25);
      }
    }
    assert.ok(r, 'the server never came up behind the leftover file; stderr: ' + err);
    assert.equal(r.status, 200);
  } finally {
    const done = new Promise((r2) => p.on('close', r2));
    p.kill('SIGTERM');
    await Promise.race([done, sleep(2000)]);
    if (p.exitCode === null) p.kill('SIGKILL');
  }
});

test('a socket path another desk holds is refused, and the first desk keeps serving', async () => {
  // The shared `child` from `before` is still listening on SOCK - a second
  // instance pointed at the exact same path must not steal it.
  const r = await runToExit(childEnv());
  assert.equal(r.code, 64);
  assert.ok(/another desk holds the socket/.test(r.err), r.err);
  assert.equal((await get('/desk/', B)).status, 200, 'the first desk must still answer');
});

test('the pages never name a path from the machine', async () => {
  const r = await get('/desk/session/s-1', B);
  assert.equal(r.status, 200);
  assert.ok(!r.body.includes(T));
  assert.ok(!r.body.includes('/usr/bin'));
  assert.ok(!/<script/i.test(r.body));
});

// ---------------------------------------------------------------------------
// STEWARD_DESK_LISTEN - the opt-in loopback TCP mode for a host whose serve
// tool cannot dial a filesystem socket. Every test here spawns its own
// server; the shared `child` above stays on the unix socket for every test
// above and below this block.

test('STEWARD_DESK_LISTEN with port 0 is refused, port 0 means any', async () => {
  const r = await runToExit(childEnv({ STEWARD_DESK_LISTEN: '127.0.0.1:0' }));
  assert.equal(r.code, 64);
});

test('STEWARD_DESK_LISTEN refuses a host that is not loopback', async () => {
  for (const bad of ['0.0.0.0:8090', '100.64.0.1:8090']) {
    const r = await runToExit(childEnv({ STEWARD_DESK_LISTEN: bad }));
    assert.equal(r.code, 64, bad);
    assert.ok(/loopback/.test(r.err), bad + ': ' + r.err);
  }
});

test('STEWARD_DESK_LISTEN without a port is refused', async () => {
  const r = await runToExit(childEnv({ STEWARD_DESK_LISTEN: 'localhost' }));
  assert.equal(r.code, 64, r.err);
});

test('STEWARD_DESK_LISTEN refuses a port written with a leading zero', async () => {
  // 08080, not 080: a leading zero on a privileged port (below 1024) would
  // fail to bind for its own reason (EACCES) and prove nothing about the
  // leading-zero check itself.
  const r = await runToExit(childEnv({ STEWARD_DESK_LISTEN: '127.0.0.1:08080' }));
  assert.equal(r.code, 64, r.err);
  assert.ok(/STEWARD_DESK_LISTEN port/.test(r.err), r.err);
});

test('STEWARD_DESK_LISTEN accepts the spelling localhost and binds it literally as 127.0.0.1', async () => {
  const port = await freePort();
  const env = childEnv({ STEWARD_DESK_LISTEN: 'localhost:' + port });
  delete env.STEWARD_DESK_SOCK;
  const handle = spawnDesk(env);
  try {
    const until = Date.now() + UP_CAP_MS;
    while (Date.now() < until && !/listening on/.test(handle.getErr())) {
      if (handle.proc.exitCode !== null) break;
      await sleep(25);
    }
    assert.ok(new RegExp('listening on 127\\.0\\.0\\.1:' + port).test(handle.getErr()), handle.getErr());
  } finally {
    await stopSpawned(handle);
  }
});

test('a free loopback port serves the same gate over TCP, and creates no socket file', async () => {
  const port = await freePort();
  const sock2 = join(T, 'loop-ok.sock');
  const env = childEnv({ STEWARD_DESK_LISTEN: '127.0.0.1:' + port, STEWARD_DESK_SOCK: sock2 });
  let handle;
  try {
    handle = await spawnUpTcp(env, '127.0.0.1', port, UP_CAP_MS);
    const withLogin = await reqHttp('127.0.0.1', port, 'GET', '/desk/', B);
    assert.equal(withLogin.status, 200);
    assert.ok(withLogin.body.includes('work-a'));
    const noLogin = await reqHttp('127.0.0.1', port, 'GET', '/desk/', {});
    assert.equal(noLogin.status, 403);
    assert.ok(!existsSync(sock2), 'loopback mode must not create a socket file');
    assert.ok(new RegExp('listening on 127\\.0\\.0\\.1:' + port).test(handle.getErr()), handle.getErr());
  } finally {
    if (handle) await stopSpawned(handle);
  }
});

test('a pre-existing file at STEWARD_DESK_SOCK survives a loopback server on SIGTERM', async () => {
  const port = await freePort();
  const sock2 = join(T, 'loop-preexisting.sock');
  writeFileSync(sock2, 'not a socket, and never touched by loopback mode');
  const env = childEnv({ STEWARD_DESK_LISTEN: '127.0.0.1:' + port, STEWARD_DESK_SOCK: sock2 });
  let handle;
  try {
    handle = await spawnUpTcp(env, '127.0.0.1', port, UP_CAP_MS);
    await stopSpawned(handle);
    assert.ok(existsSync(sock2), 'a loopback server must never unlink a file at STEWARD_DESK_SOCK on exit');
  } finally {
    if (handle) await stopSpawned(handle);
  }
});

test('loopback mode starts with STEWARD_DESK_SOCK unset entirely', async () => {
  const port = await freePort();
  const env = childEnv({ STEWARD_DESK_LISTEN: '127.0.0.1:' + port });
  delete env.STEWARD_DESK_SOCK;
  let handle;
  try {
    handle = await spawnUpTcp(env, '127.0.0.1', port, UP_CAP_MS);
    assert.equal((await reqHttp('127.0.0.1', port, 'GET', '/desk/', B)).status, 200);
  } finally {
    if (handle) await stopSpawned(handle);
  }
});

// Read back the file only after everything above has finished with it, so the
// suite leaves the fixture exactly as it found it.
test('the fixture is intact at the end', () => {
  assert.equal(JSON.parse(readFileSync(join(GEN, 'b.json'), 'utf8')).viewer, 'b');
});

// ---------------------------------------------------------------------------
// THE FRONT - a second listener, for exactly one peer, whose identity is a
// cookie this desk minted rather than a header a proxy set. Everything below
// runs against a real child process, a real OpenID provider (the stub in
// test/oidc-stub.mjs), and the same fixture estate the tailnet tests use, with
// one principal bound by OIDC_LOGIN instead of TAILSCALE_LOGIN.
//
// THE FRONT CHILD GETS ITS OWN SOCKET PATH. The shared `child` from the root
// `before` still holds SOCK, and a second desk aimed at that path refuses to
// start with rc 64 - which is its own test further up, and would here hide
// everything this block is trying to measure.
describe('the front listener', () => {
  let stub, port, peerHandle, KEYFILE;
  const FRONT_ORIGIN = 'https://desk.example.test';
  const cookieOf = (res) => (res.headers['set-cookie'] || []).map((c) => c.split(';')[0]);

  // frontEstate - the same fixture rows, plus the three things a front needs
  // the estate to name: an origin, a providers directory, and a key file.
  function frontEstate() {
    buildEstate(ROOT);
    appendFileSync(join(ROOT, 'estate', 'steward.conf'),
      'DESK_ORIGIN="' + FRONT_ORIGIN + '"\nDESK_SESSION_KEY_FILE="' + KEYFILE + '"\n');
    mkdirSync(join(ROOT, 'desk', 'providers.d'), { recursive: true });
    writeFileSync(join(T, 'secret'), 'shh\n');
    writeFileSync(join(ROOT, 'desk', 'providers.d', 'stub.conf'),
      'ISSUER="' + stub.issuer + '"\nDISCOVERY="' + stub.origin + '/.well-known/openid-configuration"\n' +
      'CLIENT_ID="cid"\nCLIENT_SECRET_FILE="' + join(T, 'secret') + '"\n');
    // e binds by OIDC identity; a (read-all) and b keep their tailnet logins.
    writeFileSync(join(ROOT, 'principals.d', 'e.conf'), 'NAME="Eve"\nOIDC_LOGIN="stub:sub-1"\n');
  }

  const frontEnv = (over) => childEnv(Object.assign({ STEWARD_DESK_SOCK: join(T, 'front.sock') }, over));

  before(async () => {
    stub = await startStub();
    KEYFILE = join(T, 'session.key');
    writeFileSync(KEYFILE, 'k'.repeat(44) + '\n');
    chmodSync(KEYFILE, 0o600);
    frontEstate();
    writeFileSync(join(GEN, 'e.json'), JSON.stringify(snapshotFor('e', false, [])));
    port = await freePort();
    peerHandle = await spawnUpTcp(frontEnv({
      STEWARD_DESK_FRONT_LISTEN: '127.0.0.1:' + port, STEWARD_DESK_FRONT_PEER: '127.0.0.1'
    }), '127.0.0.1', port, UP_CAP_MS);
  });

  after(async () => {
    if (peerHandle) await stopSpawned(peerHandle);
    if (stub) await stub.close();
  });

  const front = (method, path, headers) => reqHttp('127.0.0.1', port, method, path, headers);

  // ONE VISITOR ADDRESS PER TEST, so one test's rate-limit budget is never
  // spent by another's - which is not a trick but exactly how the front reads
  // the world: the socket peer is always the box, and the visitor is whoever
  // the box says it is, so two people behind the same box have two budgets.
  // Without this the block shares a single budget of ten auth requests and
  // adding a test silently 429s the one after it (measured while writing
  // these).
  const visitor = (n) => ({ 'x-real-ip': '203.0.113.' + n });
  const from = (n, headers) => Object.assign(visitor(n), headers || {});

  // The identity row e claims, and the row itself: the cookie carries the
  // identity, so a test that hand-mints a session mints one of these.
  const IDENTITY = 'oidc:stub:sub-1';
  const KEY = () => Buffer.from('k'.repeat(44));
  const ROW_E = () => join(ROOT, 'principals.d', 'e.conf');
  const sessionFor = (id) => '__Host-desk-session=' + mintSession(KEY(), id, Math.floor(Date.now() / 1000));

  it('starts both listeners: the socket still answers the header, the front ignores it', async () => {
    const viaSock = await req('GET', '/desk/', B);
    assert.equal(viaSock.status, 200);
    const viaFront = await front('GET', '/desk/', B);
    assert.equal(viaFront.status, 303);
    assert.equal(viaFront.headers.location, '/desk/auth/login');
  });

  it('the socket ignores a cookie', async () => {
    const r = await req('GET', '/desk/', { cookie: sessionFor(IDENTITY) });
    assert.equal(r.status, 403);
  });

  it('logs in end to end and lands on the desk as the bound principal', async () => {
    const chooser = await front('GET', '/desk/auth/login', visitor(10));
    assert.equal(chooser.status, 200);
    assert.match(chooser.body, /href="\/desk\/auth\/login\?provider=stub"/);
    const go = await front('GET', '/desk/auth/login?provider=stub', visitor(10));
    assert.equal(go.status, 303);
    const state = cookieOf(go).find((c) => c.startsWith('__Host-desk-oauth='));
    assert.ok(state);
    const back = await fetch(go.headers.location, { redirect: 'manual' });
    const cb = new URL(back.headers.get('location'));
    assert.equal(cb.origin + cb.pathname, FRONT_ORIGIN + '/desk/auth/callback');
    const done = await front('GET', cb.pathname + cb.search, from(10, { cookie: state }));
    assert.equal(done.status, 303);
    assert.equal(done.headers.location, '/desk/');
    const session = cookieOf(done).find((c) => c.startsWith('__Host-desk-session='));
    assert.ok(session);
    // The state cookie is cleared in the same answer: two set-cookie lines.
    assert.ok(cookieOf(done).includes('__Host-desk-oauth='));
    const page = await front('GET', '/desk/', from(10, { cookie: session }));
    assert.equal(page.status, 200);
    // The snapshot names its viewer by slug, and the index page is titled from
    // it - the principal row's display name never reaches the file.
    assert.match(page.body, /Desk for e/);
    assert.match(page.headers['content-security-policy'], /form-action 'self'/);
  });

  it('a callback without its state cookie, or with a foreign state, is refused', async () => {
    const r1 = await front('GET', '/desk/auth/callback?code=CODE&state=x', visitor(11));
    assert.equal(r1.status, 403);
    const go = await front('GET', '/desk/auth/login?provider=stub', visitor(11));
    const state = cookieOf(go).find((c) => c.startsWith('__Host-desk-oauth='));
    const r2 = await front('GET', '/desk/auth/callback?code=CODE&state=other', from(11, { cookie: state }));
    assert.equal(r2.status, 403);
    assert.equal(cookieOf(r2).some((c) => c.startsWith('__Host-desk-session=')), false);
  });

  // THE STATE COMPARE IS ITS OWN LOCK, AND THIS TEST HOLDS ONLY IT. The test
  // above refuses a callback with a foreign state, but it never drives
  // /authorize - so with the state compare deleted the flow still stops at the
  // nonce, and the assertion passes for a reason that has nothing to do with
  // the state. Measured: that mutation left the suite fully green. Here the
  // whole login is driven, so the nonce in the token is this login's own and
  // would verify; the ONLY thing wrong is the state the provider echoed. The
  // refusal must therefore come from the state compare, and it must come
  // before the code is redeemed.
  it('a callback whose state does not match the state cookie is refused before the exchange', async () => {
    const go = await front('GET', '/desk/auth/login?provider=stub', visitor(17));
    assert.equal(go.status, 303);
    const state = cookieOf(go).find((c) => c.startsWith('__Host-desk-oauth='));
    assert.ok(state);
    const back = await fetch(go.headers.location, { redirect: 'manual' });
    const cb = new URL(back.headers.get('location'));
    const echoed = cb.searchParams.get('state');
    assert.ok(echoed);
    const redeemedBefore = stub.tokenCalls.length;
    cb.searchParams.set('state', 'not-the-state-this-browser-began-with');
    const done = await front('GET', cb.pathname + cb.search, from(17, { cookie: state }));
    assert.equal(done.status, 403);
    assert.equal(cookieOf(done).some((c) => c.startsWith('__Host-desk-session=')), false,
      'a callback with the wrong state must mint no session');
    assert.equal(stub.tokenCalls.length, redeemedBefore,
      'the refusal must come before the code is redeemed, not from verifying what came back');
    // The control: the same cookie, the same code, the state put back - and it
    // is a session. So the state is the only difference between the two.
    cb.searchParams.set('state', echoed);
    const ok = await front('GET', cb.pathname + cb.search, from(17, { cookie: state }));
    assert.equal(ok.status, 303);
    assert.ok(cookieOf(ok).some((c) => c.startsWith('__Host-desk-session=')));
  });

  it('an unknown provider is the same 404 as an unknown route', async () => {
    const bad = await front('GET', '/desk/auth/login?provider=nope', visitor(12));
    const nowhere = await front('GET', '/desk/auth/nothing', visitor(12));
    assert.equal(bad.status, 404);
    assert.equal(bad.body, nowhere.body);
  });

  // REVOCATION IS THE REGISTRY'S ANSWER, NOT A FILE'S EXISTENCE. The cookie
  // carries the identity, so the question asked on every click is the one the
  // login asked - which of the two ways an operator takes somebody off the
  // front happened is not something the front has to know.
  // The row goes back in a finally for the same reason a stub is closed in
  // one: a red assertion here would otherwise leave the fixture broken and
  // every test after it would fail for a reason that is not its own.
  const restoreRowE = () => writeFileSync(ROW_E(), 'NAME="Eve"\nOIDC_LOGIN="stub:sub-1"\n');

  // WITHIN FIVE SECONDS, NOT AT EXPIRY. The registry's answer is memoised per
  // identity for five seconds, because asking costs a process per principal
  // row, so an edit to the rows reaches a live cookie on the click after the
  // memo goes stale rather than on the very next one. That is what these two
  // tests measure now: not "immediately", and not "in twelve hours".
  const REVOKE_CAP_MS = 7000;
  const pollFront = async (want, headers) => {
    const started = Date.now();
    let res = await front('GET', '/desk/', headers);
    while (res.status !== want && Date.now() - started < REVOKE_CAP_MS) {
      await sleep(250);
      res = await front('GET', '/desk/', headers);
    }
    return { res, waited: Date.now() - started };
  };

  it('removing the OIDC word revokes the session within the memo, not at expiry', async () => {
    const headers = from(20, { cookie: sessionFor(IDENTITY) });
    assert.equal((await front('GET', '/desk/', headers)).status, 200);
    const primed = Date.now();
    try {
      // The row stays and keeps a tailnet login: only the front's word goes,
      // which is the natural edit for "off the front, still on the tailnet".
      writeFileSync(ROW_E(), 'NAME="Eve"\nTAILSCALE_LOGIN="eve@example.test"\n');
      const first = await front('GET', '/desk/', headers);
      // The answer measured a moment ago is still the answer: that is the memo,
      // and it is the whole reason the desk does not fork a subshell per click.
      // The claim is only made when it is measurable - a box that took two
      // seconds to send one request has nothing to say about a five-second memo.
      if (Date.now() - primed < 2000) {
        assert.equal(first.status, 200, 'an answer measured a moment ago must be remembered, not re-asked per request');
      }
      const { res: gone, waited } = await pollFront(403, headers);
      assert.equal(gone.status, 403, 'the removal must reach the cookie within ' + REVOKE_CAP_MS + ' ms (waited ' + waited + ')');
      assert.ok(cookieOf(gone).includes('__Host-desk-session='), 'the cookie must be cleared with the refusal');
    } finally {
      restoreRowE();
    }
    const back = await pollFront(200, headers);
    assert.equal(back.res.status, 200, 'the word back is the session back, within the same five seconds');
  });

  it('deleting the row revokes the session within the memo too', async () => {
    const headers = from(21, { cookie: sessionFor(IDENTITY) });
    assert.equal((await front('GET', '/desk/', headers)).status, 200);
    try {
      unlinkSync(ROW_E());
      const { res: gone, waited } = await pollFront(403, headers);
      assert.equal(gone.status, 403, 'the deletion must reach the cookie within ' + REVOKE_CAP_MS + ' ms (waited ' + waited + ')');
      assert.ok(cookieOf(gone).includes('__Host-desk-session='), 'the cookie must be cleared with the refusal');
    } finally {
      restoreRowE();
    }
    assert.equal((await pollFront(200, headers)).res.status, 200, 'the row back is the session back');
  });

  // AN OUTAGE IS NOT AN ANSWER, SO IT IS NOT REMEMBERED. The memo above holds
  // "this identity is e" and "this identity is nobody" for five seconds each,
  // and both of those are answers the registry gave. A bridge that could not
  // answer at all gave neither. If that non-answer were remembered, one blip
  // of one request would be served to everybody holding a cookie for the next
  // five seconds as "nobody" - and "nobody" on the front is 403 WITH THE
  // SESSION COOKIE CLEARED, so a hiccup in the bridge would log the whole
  // desk out and make them all log in again.
  //
  // THE BLIP IS MADE BY TAKING THE LIBRARY OUT FROM UNDER THE BRIDGE for
  // exactly one request. STEWARD_REGISTRY_LIB points this child's bridge at a
  // shim that sources the real library; deleting the shim makes the bridge
  // exit 78 - the same outage the "a bridge that fails on every request" test
  // further up produces, arrived at transiently - and putting it back makes
  // the next request answerable again. No knob in the product, and nothing
  // stubbed: the bridge that runs here is the bridge that ships.
  //
  // Verified by mutation: with `if (answer.outage) return answer;` removed
  // from principalForIdentityCached, the second request below is 403 with a
  // cleared cookie instead of 200.
  it('an outage is not remembered, so the request after it is answered again', async () => {
    const shim = join(T, 'flaky-registry.sh');
    const realLib = fileURLToPath(new URL('../../lib/registry.sh', import.meta.url));
    const putShimBack = () => writeFileSync(shim, '. "' + realLib + '"\n');
    putShimBack();
    const p2 = await freePort();
    const headers = from(25, { cookie: sessionFor(IDENTITY) });
    let h;
    try {
      h = await spawnUpTcp(frontEnv({
        STEWARD_DESK_SOCK: join(T, 'outage-memo.sock'),
        STEWARD_DESK_FRONT_LISTEN: '127.0.0.1:' + p2,
        STEWARD_DESK_FRONT_PEER: '127.0.0.1',
        STEWARD_REGISTRY_LIB: shim
      }), '127.0.0.1', p2, UP_CAP_MS);
      // The window starts here: everything from the outage to the answer after
      // it has to fall inside the memo, or this test measures nothing.
      const began = Date.now();
      unlinkSync(shim);
      const down = await reqHttp('127.0.0.1', p2, 'GET', '/desk/', headers);
      assert.equal(down.status, 503, 'a bridge that cannot answer is an outage, not a refusal');
      assert.equal((down.headers['set-cookie'] || []).length, 0,
        'an outage must not clear the session cookie: nobody said this person was gone');
      putShimBack();
      const back = await reqHttp('127.0.0.1', p2, 'GET', '/desk/', headers);
      const elapsed = Date.now() - began;
      assert.equal(back.status, 200,
        'the request after an outage must ask again and get today s answer, not the outage');
      assert.ok(elapsed < 5000,
        'both requests must fall inside the five-second memo for this to measure anything (took ' +
        elapsed + ' ms) - a red here is a stalled box, not a broken memo');
    } finally {
      try { unlinkSync(shim); } catch { /* already gone */ }
      if (h) await stopSpawned(h);
    }
  });

  it('an identity no row claims is refused even with a cookie this host minted', async () => {
    const r = await front('GET', '/desk/', { cookie: sessionFor('oidc:stub:nobody') });
    assert.equal(r.status, 403);
    assert.ok(cookieOf(r).includes('__Host-desk-session='));
  });

  it('a cookie forged under another key, or tampered, is not a session', async () => {
    const bad = '__Host-desk-session=' + mintSession(Buffer.from('x'.repeat(44)), IDENTITY, Math.floor(Date.now() / 1000));
    const r = await front('GET', '/desk/', { cookie: bad });
    assert.equal(r.status, 303);
    // And so is this host's own MAC over a body edited afterwards.
    const mine = mintSession(KEY(), IDENTITY, Math.floor(Date.now() / 1000)).split('.');
    const tampered = Buffer.from('oidc:stub:sub-2').toString('base64url') + '.' + mine[1] + '.' + mine[2];
    assert.equal((await front('GET', '/desk/', { cookie: '__Host-desk-session=' + tampered })).status, 303);
  });

  it('logout needs same-origin and a matching Origin, then clears the cookie', async () => {
    const cookie = sessionFor(IDENTITY);
    assert.equal((await front('POST', '/desk/auth/logout', from(13, { cookie }))).status, 403);
    assert.equal((await front('POST', '/desk/auth/logout', from(13, { cookie, 'sec-fetch-site': 'cross-site' }))).status, 403);
    assert.equal((await front('POST', '/desk/auth/logout', from(13, { cookie, 'sec-fetch-site': 'same-origin', origin: 'https://evil.example.test' }))).status, 403);
    const ok = await front('POST', '/desk/auth/logout', from(13, { cookie, 'sec-fetch-site': 'same-origin', origin: FRONT_ORIGIN }));
    assert.equal(ok.status, 303);
    assert.ok(cookieOf(ok).includes('__Host-desk-session='));
    // A login begun and abandoned must not outlive the logout either.
    assert.ok(cookieOf(ok).includes('__Host-desk-oauth='));
  });

  // The visitor address is what the box reported, so two visitors behind the
  // same box have two budgets - which is the whole point of reading x-real-ip
  // rather than the socket peer, since the socket peer is always the box.
  it('rate limits the auth paths per visitor address', async () => {
    // The PROVIDER REDIRECT, not the bare chooser: the chooser does no work
    // and is not charged for (see the test below), so a budget measured on it
    // would be a budget nobody spends.
    let last;
    for (let i = 0; i < 11; i++) last = await front('GET', '/desk/auth/login?provider=stub', { 'x-real-ip': '203.0.113.77' });
    assert.equal(last.status, 429);
    assert.equal(last.headers['retry-after'], '60');
    const other = await front('GET', '/desk/auth/login?provider=stub', { 'x-real-ip': '203.0.113.78' });
    assert.equal(other.status, 303);
  });

  // THE PAGE THAT DOES NO WORK IS NOT CHARGED FOR. The sec-fetch-dest lock
  // above is a second lock and it falls open when the header is absent -
  // Apple Mail, Outlook desktop and Safari before 16.4 send none - so ten
  // `<img src="https://.../desk/auth/login">` in an HTML mail still reach the
  // chooser from the victim's own address. If that page cost a hit, the
  // victim's own first click would be 429 for a minute, renewably. It costs
  // nothing, so the budget is whole for the requests that do work: no
  // sec-fetch header here at all, which is exactly the client the lock above
  // cannot see.
  it('the bare chooser page does not spend the auth budget', async () => {
    for (let i = 0; i < 10; i++) {
      const r = await front('GET', '/desk/auth/login', visitor(24));
      assert.equal(r.status, 200, 'the chooser answers, request ' + (i + 1));
    }
    const go = await front('GET', '/desk/auth/login?provider=stub', visitor(24));
    assert.equal(go.status, 303, 'the budget must be untouched by ten chooser views');
  });

  // AND THE COOKIE PATH HAS ITS OWN, LARGER BUDGET. The auth limiter guards
  // three paths; every other path on the front resolves a cookie, reads a
  // snapshot and renders - and both listeners share one event loop, so a
  // single logged-in visitor (or one stolen cookie) could otherwise hold the
  // whole desk, the operator's tailnet view included, at whatever rate one
  // loop can drive. 120 a minute is far above a person reading their desk.
  it('the cookie path is rate limited per visitor, not per cookie', async () => {
    const cookie = sessionFor(IDENTITY);
    for (let i = 0; i < 120; i++) {
      const r = await front('GET', '/desk/', from(22, { cookie }));
      assert.equal(r.status, 200, 'request ' + (i + 1) + ' is inside the budget');
    }
    const over = await front('GET', '/desk/', from(22, { cookie }));
    assert.equal(over.status, 429, 'the 121st request in a minute is over the budget');
    assert.equal(over.headers['retry-after'], '60');
    // The same cookie from another address is another visitor: the budget is
    // the address's, the way the auth budget is, so one person behind the box
    // cannot spend everybody else's.
    assert.equal((await front('GET', '/desk/', from(23, { cookie }))).status, 200);
  });

  // THE WHOLE FLOW, AND THE TOKEN IS THE ONLY THING WRONG. Everything up to
  // the id_token succeeds - the state cookie verifies, the provider echoes
  // the state, the code is redeemed - and the desk still refuses, because it
  // verified the token itself rather than trusting the exchange.
  it('a bad id_token is 403 with no session cookie and the state cookie cleared', async () => {
    stub.tokenResponse = { id_token: stub.mintIdToken({ aud: 'other' }), token_type: 'Bearer' };
    const redeemedBefore = stub.tokenCalls.length;
    try {
      const go = await front('GET', '/desk/auth/login?provider=stub', visitor(14));
      assert.equal(go.status, 303);
      const state = cookieOf(go).find((c) => c.startsWith('__Host-desk-oauth='));
      assert.ok(state);
      const back = await fetch(go.headers.location, { redirect: 'manual' });
      const cb = new URL(back.headers.get('location'));
      const done = await front('GET', cb.pathname + cb.search, from(14, { cookie: state }));
      assert.equal(done.status, 403);
      assert.equal((done.headers['set-cookie'] || []).some((c) => c.startsWith('__Host-desk-session=')), false,
        'a refused login must set no session cookie');
      assert.ok((done.headers['set-cookie'] || []).some((c) => c.startsWith('__Host-desk-oauth=') && /Max-Age=0/.test(c)),
        'the state cookie must be cleared with the refusal');
      // The code really was redeemed, so the refusal came from verifying the
      // token here and not from a gate before the exchange.
      assert.equal(stub.tokenCalls.length, redeemedBefore + 1);
    } finally {
      stub.tokenResponse = null;
    }
  });

  // A method this desk would refuse anyway must not cost a rate-limit hit:
  // otherwise a HEAD sweep of the login path locks a visitor out of logging
  // in. HEAD is in the loop because that is exactly what used to happen - it
  // passed the method gate, spent a hit and 404ed, and the visitor's own next
  // GET was 429.
  it('a refused method does not spend the auth budget', async () => {
    for (const method of ['DELETE', 'HEAD']) {
      for (let i = 0; i < 12; i++) {
        const r = await front(method, '/desk/auth/login', visitor(15));
        assert.equal(r.status, 405, method + ' on an auth path is 405, never 429 and never 404');
      }
    }
    // The provider redirect is what a hit buys, so that is what proves the
    // budget is whole - the bare chooser is free either way.
    const ok = await front('GET', '/desk/auth/login?provider=stub', visitor(15));
    assert.equal(ok.status, 303, 'the budget must be untouched by the refused methods');
  });

  // NEITHER DOES A PATH THIS DESK DOES NOT ANSWER. GET is reachable from any
  // other site - a page or an HTML mail with ten
  // `<img src="https://.../desk/auth/logout">` in it - so a 404 that spent a
  // hit let a stranger lock a person out of their own login from that
  // person's own address, for a minute at a time, renewably.
  it('a path the desk does not answer does not spend the auth budget', async () => {
    for (let i = 0; i < 10; i++) {
      const r = await front('GET', '/desk/auth/nonsense', visitor(18));
      assert.equal(r.status, 404, 'an unrouted auth path is 404, never 429');
    }
    // GET /desk/auth/logout is the attack's own URL: the logout answers POST,
    // so this is the 404 above by another name.
    for (let i = 0; i < 10; i++) {
      assert.equal((await front('GET', '/desk/auth/logout', visitor(18))).status, 404);
    }
    const ok = await front('GET', '/desk/auth/login?provider=stub', visitor(18));
    assert.equal(ok.status, 303, 'the budget must be untouched by the paths the desk does not answer');
  });

  // AND THE ROUTES THAT DO EXIST ARE NOT SPENDABLE AS SUBRESOURCES. Closing
  // the 404 path alone leaves /desk/auth/login itself: ten image loads of it
  // would be ten 200s and ten hits. The browser says what it wants the answer
  // for, and only a navigation - `document` - is a person at this desk.
  it('a subresource GET of an auth path is refused before the budget', async () => {
    for (const dest of ['image', 'script', 'style', 'empty', 'iframe']) {
      const r = await front('GET', '/desk/auth/login', from(19, { 'sec-fetch-dest': dest }));
      assert.equal(r.status, 403, 'sec-fetch-dest: ' + dest + ' is a subresource, not a click');
    }
    for (let i = 0; i < 10; i++) {
      assert.equal((await front('GET', '/desk/auth/login', from(19, { 'sec-fetch-dest': 'image' }))).status, 403);
    }
    // The person's own click, and a client that sends no such header at all,
    // both still get the page - and the budget is still whole for them.
    assert.equal((await front('GET', '/desk/auth/login', from(19, { 'sec-fetch-dest': 'document' }))).status, 200);
    assert.equal((await front('GET', '/desk/auth/login', visitor(19))).status, 200);
    assert.equal((await front('GET', '/desk/auth/login?provider=stub', from(19, { 'sec-fetch-dest': 'document' }))).status, 303,
      'and the budget is still whole for the request that does work');
  });

  // The 405 names the one method the path answers, so a client that meets it
  // is told what to do rather than only what not to.
  it('a HEAD on an auth path names the method that path answers', async () => {
    assert.equal((await front('HEAD', '/desk/auth/login', visitor(16))).headers.allow, 'GET');
    assert.equal((await front('HEAD', '/desk/auth/callback', visitor(16))).headers.allow, 'GET');
    assert.equal((await front('HEAD', '/desk/auth/logout', visitor(16))).headers.allow, 'POST');
    // The desk's own pages still answer HEAD - the budget is not theirs.
    const page = await front('HEAD', '/desk/', from(16, { cookie: sessionFor(IDENTITY) }));
    assert.equal(page.status, 200);
    assert.equal(page.body, '');
  });

  it('refuses to start on a public bind, without a peer, or with a peer off the tailnet', async () => {
    for (const over of [
      { STEWARD_DESK_FRONT_LISTEN: '0.0.0.0:18443', STEWARD_DESK_FRONT_PEER: '127.0.0.1' },
      { STEWARD_DESK_FRONT_LISTEN: '127.0.0.1:18443' },
      { STEWARD_DESK_FRONT_LISTEN: '127.0.0.1:18443', STEWARD_DESK_FRONT_PEER: '203.0.113.1' }
    ]) {
      // Its own socket path, so a refusal here is the front's own and never
      // the "another desk holds the socket" rc 64 the shared child would give.
      const r = await runToExit(frontEnv(Object.assign({ STEWARD_DESK_SOCK: join(T, 'front-refuse.sock') }, over)));
      assert.equal(r.code, 64, JSON.stringify(over));
    }
  });

  it('refuses to start when the estate names no key, no providers and no origin', async () => {
    const bare = join(T, 'front-bare');
    mkdirSync(join(bare, 'estate'), { recursive: true });
    mkdirSync(join(bare, 'principals.d'), { recursive: true });
    writeFileSync(join(bare, 'estate', 'steward.conf'), readFileSync(join(ROOT, 'estate', 'steward.conf'), 'utf8')
      .split('\n').filter((l) => !/^DESK_/.test(l)).join('\n'));
    const env = frontEnv({
      STEWARD_ESTATE_ROOT: bare,
      STEWARD_DESK_SOCK: join(T, 'front-bare.sock'),
      STEWARD_DESK_FRONT_LISTEN: '127.0.0.1:18444',
      STEWARD_DESK_FRONT_PEER: '127.0.0.1'
    });
    const r = await runToExit(env);
    assert.equal(r.code, 78, r.err);
    assert.ok(/origin/.test(r.err), r.err);
  });
});

// A FRONT WHOSE PEER IS NOT US: every request is refused before identity is
// read. It leans on the estate rows the block above wrote (origin, providers,
// key), which is why it comes after it.
describe('the front peer gate', () => {
  it('refuses a socket peer other than the configured box', async () => {
    const port = await freePort();
    const h = await spawnUpTcp(childEnv({
      STEWARD_DESK_SOCK: join(T, 'peer-gate.sock'),
      STEWARD_DESK_FRONT_LISTEN: '127.0.0.1:' + port,
      STEWARD_DESK_FRONT_PEER: '100.64.0.9'
    }), '127.0.0.1', port, UP_CAP_MS);
    try {
      const r = await reqHttp('127.0.0.1', port, 'GET', '/desk/auth/login');
      assert.equal(r.status, 403);
      assert.equal(r.headers['content-type'], 'text/plain; charset=utf-8');
      assert.equal(r.body, 'Forbidden: not the front peer.');
    } finally {
      await stopSpawned(h);
    }
  });
});
