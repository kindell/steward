// desk/serve.mjs - Steward Desk: a read-only page per person, over a unix
// socket, in front of files somebody else already wrote.
//
// ============================ OPERATOR NOTES ============================
//
// WHAT IT DOES. It answers four routes under /desk/ with HTML built from ONE
// file: the snapshot belonging to the person the request's login names. It
// opens no registry, runs no ssh, starts nothing and writes nothing. A desk
// that could act would need an authorisation model; a desk that only reads a
// file that was filtered when it was written needs the file to be right, and
// desk/filter.jq is where that is decided and reviewed.
//
// THE GATE IS ONE HEADER. `tailscale-user-login`, set by Tailscale Serve in
// front of this socket, which strips a client-sent copy of it before it
// forwards. No query parameter, no cookie, no second header and no address is
// ever consulted, so there is nothing else for a client to set. The value must
// look like a login (/^[A-Za-z0-9._%+@-]{1,254}$/) before the bridge is even
// spawned; two copies of the header arrive joined by ", " and fail that test,
// as does anything else that is not a single well-formed word. The login is
// then resolved by desk/bin/principal-for-login, which is the registry's own
// answer: exactly one row, or no desk. A login two rows claim is refused, never
// guessed - guessing there hands one person another person's desk.
//
// THE PATH IS THE GENERATIONS LAYOUT. The producer writes
// <STEWARD_DESK_DIR>/gen-<epoch>/<principal>.json and then moves the symlink
// <STEWARD_DESK_DIR>/current onto that directory, so this server reads
// <dir>/current/<principal>.json and never <dir>/<principal>.json. During the
// sub-millisecond swap a read can miss; that ENOENT is a 503, the same as a
// snapshot that is missing, malformed or stale, because all four mean the same
// thing to a reader: there is no fresh measurement to show you right now.
//
// STALENESS IS MEASURED ON THE FILE'S OWN `generatedAt`, NEVER ON ITS mtime.
// The producer writes a fresh file every run, so mtime says when the file was
// written and generatedAt says when the estate was measured - and those differ
// exactly when it matters, e.g. a file copied or restored. See loadSnapshot.
//
// ENVIRONMENT
//   STEWARD_DESK_DIR    the desk directory. Unset -> the `dir=` line from
//                       desk/bin/desk-paths.
//   STEWARD_DESK_SOCK   the unix socket to listen on, chmod 0600 after listen.
//                       Unset -> the `sock=` line from desk/bin/desk-paths.
//   STEWARD_DESK_MAX_AGE  seconds before a snapshot is stale. Unset -> 900.
//
// EXIT CODES
//   64  A setting that cannot be honoured: STEWARD_DESK_MAX_AGE that is not a
//       positive number (a silent fallback there would serve a stale desk
//       forever), or a socket path the kernel would truncate (see below).
//   78  desk/bin/desk-paths could not answer. A guessed path is a second desk
//       nobody is reading, so there is no fallback.
// =======================================================================

import http from 'node:http';
import { readFileSync, unlinkSync, chmodSync, mkdirSync, existsSync } from 'node:fs';
import { execFileSync } from 'node:child_process';
import { join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';
import { pageIndex, pageTeam, pageProject, pageSession } from './render.mjs';

const HERE = dirname(fileURLToPath(import.meta.url));
const LOOKUP = join(HERE, 'bin', 'principal-for-login');
const PATHS_BRIDGE = join(HERE, 'bin', 'desk-paths');

function maxAge() {
  const raw = process.env.STEWARD_DESK_MAX_AGE;
  if (raw === undefined || raw === '') return 900;
  const n = Number(raw);
  if (!Number.isFinite(n) || n <= 0) {
    console.error('desk: STEWARD_DESK_MAX_AGE must be a positive number of seconds, got ' + JSON.stringify(raw));
    process.exit(64);
  }
  return n;
}

// deskPaths - the two defaults, asked of the bridge exactly once at startup and
// never guessed. Only spawned when something is actually missing, so a unit
// that names both paths never pays for it.
function deskPaths() {
  let out;
  try {
    out = execFileSync(PATHS_BRIDGE, [], { encoding: 'utf8', timeout: 10000, stdio: ['ignore', 'pipe', 'pipe'] });
  } catch (e) {
    if (e && e.stderr) process.stderr.write(String(e.stderr));
    console.error('desk: desk-paths could not name the desk directory and socket');
    process.exit(78);
  }
  const found = {};
  for (const line of out.split('\n')) {
    const m = line.match(/^(dir|sock)=(.+)$/);
    if (m) found[m[1]] = m[2];
  }
  if (!found.dir || !found.sock) {
    console.error('desk: desk-paths printed neither a dir= nor a sock= line');
    process.exit(78);
  }
  return found;
}

const MAX_AGE = maxAge();
let DIR = process.env.STEWARD_DESK_DIR;
let SOCK = process.env.STEWARD_DESK_SOCK;
if (!DIR || !SOCK) {
  const p = deskPaths();
  DIR = DIR || p.dir;
  SOCK = SOCK || p.sock;
}

// THE KERNEL TRUNCATES A LONG SOCKET PATH INSTEAD OF REFUSING IT. sockaddr_un
// holds 104 bytes on macOS and 108 on Linux, and a bind() past that does not
// fail: measured 2026-09-08, a 110-byte path listened as its own first 107
// bytes, so `ls` showed a socket with a chopped-off name, every client got
// ENOENT on the real path, and the only symptom was a desk nobody could reach.
// A refusal at startup is what this file's exit codes exist for.
const SOCK_MAX = 103;
if (Buffer.byteLength(SOCK) > SOCK_MAX) {
  console.error('desk: the socket path is ' + Buffer.byteLength(SOCK) + ' bytes, over the kernel limit of ' +
    SOCK_MAX + ', and would be silently truncated: ' + SOCK);
  process.exit(64);
}

const HEADERS = {
  'content-type': 'text/html; charset=utf-8',
  'cache-control': 'no-store',
  'x-content-type-options': 'nosniff',
  'x-frame-options': 'DENY',
  'referrer-policy': 'no-referrer',
  'content-security-policy': "default-src 'none'; style-src 'unsafe-inline'; base-uri 'none'; form-action 'none'"
};

const send = (res, status, body, extra) => {
  res.writeHead(status, extra ? Object.assign({}, HEADERS, extra) : HEADERS);
  res.end(body);
};

// ONE BODY PER REFUSAL. A 404 that said "that session is not yours" and a 404
// that said "no such session" would together be an oracle: ask for an id, read
// which sentence came back, and learn whether it exists. So a session outside
// the view, an unknown id and an unknown route all get this exact string, and
// every reason for a 403 gets that one.
const NOT_FOUND = '<!doctype html><meta charset="utf-8"><title>Steward Desk</title><p>Not found.</p>';
const FORBIDDEN = '<!doctype html><meta charset="utf-8"><title>Steward Desk</title><p>No desk for this login.</p>';
const NO_MEASUREMENT = '<!doctype html><meta charset="utf-8"><title>Steward Desk</title>' +
  '<p>The desk has no fresh measurement. Try again in a minute.</p>';

// The shape a tailnet login has. Checked BEFORE the bridge is spawned, so a
// hostile or malformed header value never becomes an argument to a process.
const LOGIN_RE = /^[A-Za-z0-9._%+@-]{1,254}$/;
// The shape a principal slug has, checked before it becomes a path segment.
const SLUG_RE = /^[A-Za-z0-9._-]+$/;

function principalFor(login) { // exactly one, or nothing - never a guess
  if (typeof login !== 'string' || !LOGIN_RE.test(login)) return null;
  let slug;
  try {
    // stderr is captured, not inherited: an unknown login is an ordinary event
    // on a shared tailnet, and the log must not fill with it.
    slug = execFileSync(LOOKUP, [login], { encoding: 'utf8', timeout: 5000, stdio: ['ignore', 'pipe', 'pipe'] }).trim();
  } catch {
    return null; // rc 1 none, rc 65 two, rc 78 no estate - all of them: no desk
  }
  return slug && SLUG_RE.test(slug) ? slug : null;
}

// loadSnapshot - the viewer's file out of the CURRENT generation, or null.
//
// null means missing, malformed, of an unknown schema, or stale, and the caller
// turns every one of them into the same 503. STALENESS IS THE FILE'S OWN
// `generatedAt`, NOT ITS mtime: mtime says when the bytes were written, and a
// restored or copied file has a young mtime and an old measurement inside. The
// reader is asking how old the ANSWER is.
function loadSnapshot(principal) {
  try {
    const snap = JSON.parse(readFileSync(join(DIR, 'current', principal + '.json'), 'utf8'));
    if (snap.schemaVersion !== 1 || !snap.generatedAt) return null;
    const age = (Date.now() - Date.parse(snap.generatedAt)) / 1000;
    if (!Number.isFinite(age) || age > MAX_AGE) return null;
    return snap;
  } catch {
    return null;
  }
}

const ROUTES = [
  [/^\/desk\/$/, (s) => pageIndex(s)],
  [/^\/desk\/team\/([a-z0-9-]+)$/, (s, id) => pageTeam(s, id)],
  [/^\/desk\/project\/([a-z0-9-]+)$/, (s, id) => pageProject(s, id)],
  [/^\/desk\/session\/(s-[a-f0-9]+)$/, (s, id) => pageSession(s, id)]
];

const server = http.createServer((req, res) => {
  if (req.method !== 'GET' && req.method !== 'HEAD') return send(res, 405, '', { allow: 'GET, HEAD' });

  // ONLY THE HEADER TAILSCALE SERVE SETS. It strips a client-sent copy before
  // forwarding, so this value came from the tailnet's own identity and not from
  // the request. Nothing else - no query parameter, no cookie, no other header
  // - is consulted, so there is nothing else to spoof.
  const principal = principalFor(req.headers['tailscale-user-login']);
  if (!principal) return send(res, 403, FORBIDDEN);

  let path;
  try {
    path = new URL(req.url, 'http://desk').pathname;
  } catch {
    return send(res, 404, NOT_FOUND);
  }

  const route = ROUTES.map(([re, fn]) => [path.match(re), fn]).find(([m]) => m);
  if (!route) return send(res, 404, NOT_FOUND);

  const snap = loadSnapshot(principal);
  if (!snap) return send(res, 503, NO_MEASUREMENT);

  let html;
  try {
    html = route[1](snap, route[0][1]);
  } catch {
    return send(res, 503, NO_MEASUREMENT); // a snapshot this renderer cannot read is not a page
  }
  if (html === null) return send(res, 404, NOT_FOUND); // same body as unknown: no oracle
  send(res, 200, html);
});

const cleanUp = () => { try { unlinkSync(SOCK); } catch { /* already gone */ } };

mkdirSync(dirname(SOCK), { recursive: true });
if (existsSync(SOCK)) unlinkSync(SOCK);
server.listen(SOCK, () => {
  // THE SOCKET IS THE OWNER'S ALONE. Tailscale Serve runs as the same account;
  // every other account on the machine is refused by the filesystem, before a
  // single byte of HTTP is parsed.
  chmodSync(SOCK, 0o600);
  console.error('desk: listening on ' + SOCK);
});

for (const sig of ['SIGTERM', 'SIGINT']) {
  process.on(sig, () => { server.close(); cleanUp(); process.exit(0); });
}
