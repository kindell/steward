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
import test, { before, after } from 'node:test';
import assert from 'node:assert/strict';
import http from 'node:http';
import { spawn } from 'node:child_process';
import { mkdtempSync, mkdirSync, writeFileSync, readFileSync, rmSync, existsSync, statSync, symlinkSync } from 'node:fs';
import { join, dirname } from 'node:path';
import { tmpdir } from 'node:os';
import { fileURLToPath } from 'node:url';

const SERVE = fileURLToPath(new URL('../serve.mjs', import.meta.url));

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

// runToExit - start serve.mjs with an env that should make it refuse, and
// collect how it refused. Used for the two startup refusals (64 and 78).
function runToExit(env) {
  return new Promise((resolve) => {
    const p = spawn(process.execPath, [SERVE], { env, stdio: ['ignore', 'ignore', 'pipe'] });
    let err = '';
    p.stderr.setEncoding('utf8');
    p.stderr.on('data', (c) => { err += c; });
    p.on('close', (code) => resolve({ code, err }));
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
  const up = await waitForSocket(SOCK, 5000);
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
  assert.ok(!existsSync(tooLong));
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
    const until = Date.now() + 5000;
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

test('the server writes nothing but one startup line to stderr', () => {
  assert.equal(childErr.trim().split('\n').length, 1, childErr);
  assert.ok(childErr.includes(SOCK));
  assert.ok(!/SENTINEL|Error|error:/.test(childErr), childErr);
});

test('the pages never name a path from the machine', async () => {
  const r = await get('/desk/session/s-1', B);
  assert.equal(r.status, 200);
  assert.ok(!r.body.includes(T));
  assert.ok(!r.body.includes('/usr/bin'));
  assert.ok(!/<script/i.test(r.body));
});

// Read back the file only after everything above has finished with it, so the
// suite leaves the fixture exactly as it found it.
test('the fixture is intact at the end', () => {
  assert.equal(JSON.parse(readFileSync(join(GEN, 'b.json'), 'utf8')).viewer, 'b');
});
