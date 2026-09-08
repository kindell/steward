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
// A BRIDGE THAT CANNOT ANSWER AT ALL IS NOT THIS DECISION. Missing, not
// executable, hung past its timeout, exiting some code that is neither 1 nor
// 65, or printing something that is not a slug - all four mean the desk is
// completely down, and that is an outage: logged once, answered 503, never
// folded into the silent 403 the policy path uses for an unknown or
// ambiguous login. principal-for-login's own executable bit is also checked
// once at startup, so a bridge that a deploy broke is caught before the first
// request rather than on it.
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
// THE SOCKET IS THE DEFAULT, AND IT IS THE OWNER'S ALONE - see below. On a
// host whose serve tool runs inside a sandbox that cannot dial a filesystem
// socket at all, no amount of retrying fixes that: every request lands as a
// dead 502 no matter the socket's path or its mode, while the same tool
// aimed at a loopback address gets a normal 200 with the identity header
// still attached. STEWARD_DESK_LISTEN exists for exactly that host, and only
// for it. Choosing it costs something the socket gave for free: a socket's
// permission bits refuse every other local account before a byte of HTTP is
// parsed, and a loopback port refuses nobody local - any account on the same
// machine can connect and set the same header itself. So loopback mode is
// for a host where every local account already belongs to the one person
// this desk is for, and the socket stays the answer everywhere the serve
// tool can reach it.
//
// ENVIRONMENT
//   STEWARD_DESK_DIR    the desk directory. Unset -> the `dir=` line from
//                       desk/bin/desk-paths.
//   STEWARD_DESK_SOCK   the unix socket to listen on, chmod 0600 after listen.
//                       Unset -> the `sock=` line from desk/bin/desk-paths.
//                       The variable and the bridge's `sock=` line are both
//                       never USED when STEWARD_DESK_LISTEN is set - the
//                       bridge may still be asked for its `dir=` line if
//                       STEWARD_DESK_DIR is unset.
//   STEWARD_DESK_LISTEN opt-in loopback TCP mode, as `<host>:<port>`. Unset
//                       -> the unix socket above, unchanged. See the operator
//                       note above headed "THE SOCKET IS THE DEFAULT, AND IT
//                       IS THE OWNER'S ALONE" for when this is the right
//                       choice, listenSocket for the chmod that phrase
//                       describes, and bindSocket for why the socket is the
//                       default everywhere else.
//   STEWARD_DESK_MAX_AGE  seconds before a snapshot is stale. Unset -> 900.
//   STEWARD_DESK_SELF_ADDRS  extra addresses that count as this host
//                            (space-separated); the interfaces' own
//                            addresses are always included.
//
// EXIT CODES
//   64  A setting that cannot be honoured: STEWARD_DESK_MAX_AGE that is not a
//       positive number (a silent fallback there would serve a stale desk
//       forever), a socket path the kernel would truncate (see below), a bind
//       failure on the socket or the loopback address, a socket path another
//       live desk already holds (never stolen - see bindSocket below), or a
//       STEWARD_DESK_LISTEN value that does not name a loopback host with a
//       usable port (see parseListen below).
//   78  desk/bin/desk-paths could not answer, or desk/bin/principal-for-login
//       is not runnable (checked once at startup with accessSync). A guessed
//       path, or a gate nobody could even ask, is a second desk nobody is
//       reading, so there is no fallback for either.
// =======================================================================

import http from 'node:http';
import net from 'node:net';
import os from 'node:os';
import { readFileSync, unlinkSync, chmodSync, mkdirSync, existsSync, accessSync, constants } from 'node:fs';
import { execFileSync } from 'node:child_process';
import { join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';
import { pageIndex, pageTeam, pageProject, pageSession } from './render.mjs';

const HERE = dirname(fileURLToPath(import.meta.url));
const LOOKUP = join(HERE, 'bin', 'principal-for-login');
const PATHS_BRIDGE = join(HERE, 'bin', 'desk-paths');

// A BRIDGE THAT CANNOT EVEN RUN IS AN OUTAGE, CHECKED ONCE, NOT PER REQUEST.
// A deploy that drops the executable bit, or omits the file, must fail loudly
// at startup rather than presenting every viewer with "No desk for this
// login." forever.
try {
  accessSync(LOOKUP, constants.X_OK);
} catch {
  console.error('desk: ' + LOOKUP + ' is missing or not executable; the desk cannot start');
  process.exit(78);
}

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

// parseListen - STEWARD_DESK_LISTEN as a loopback host and a port, or a
// refusal before a single socket call is made. The host must be exactly one
// of the three spellings loopback actually has; anything else would let a
// request from elsewhere on the network reach a desk whose only gate is a
// header a loopback-only bind would have made unreachable to begin with. The
// port must be a real, singular port: 0 means "let the kernel pick", which is
// useless here because nothing outside this process could ever be told what
// it picked. The spelling `localhost` is accepted but never passed to
// listen() as written: it goes through the resolver, and a resolver on this
// kind of host can hand back only ::1, leaving a caller aimed at 127.0.0.1
// refused - so the loopback guarantee has to be a literal address, never
// resolver-mediated.
const LOOPBACK_HOSTS = new Set(['127.0.0.1', '::1', 'localhost']);
function parseListen(raw) {
  const i = raw.lastIndexOf(':');
  const host = i === -1 ? raw : raw.slice(0, i);
  const portRaw = i === -1 ? '' : raw.slice(i + 1);
  if (!LOOPBACK_HOSTS.has(host)) {
    console.error('desk: STEWARD_DESK_LISTEN must name a loopback host (127.0.0.1, ::1, or localhost), got ' +
      JSON.stringify(raw));
    process.exit(64);
  }
  const port = Number(portRaw);
  if (!/^[0-9]+$/.test(portRaw) || port < 1 || port > 65535 || portRaw !== String(port)) {
    console.error('desk: STEWARD_DESK_LISTEN port must be an integer from 1 to 65535, got ' + JSON.stringify(raw));
    process.exit(64);
  }
  return { host: host === 'localhost' ? '127.0.0.1' : host, port };
}

const MAX_AGE = maxAge();
const LISTEN_RAW = process.env.STEWARD_DESK_LISTEN;
const LISTEN = LISTEN_RAW ? parseListen(LISTEN_RAW) : null;

let DIR = process.env.STEWARD_DESK_DIR;
let SOCK = process.env.STEWARD_DESK_SOCK;
if (LISTEN) {
  // Loopback mode touches no socket path at all: no desk-paths call for
  // `sock=`, no length check, no chmod, no unlink. desk-paths may still be
  // asked for `dir=` when that alone is missing. SOCK is dropped here even
  // when STEWARD_DESK_SOCK was set in the environment, so cleanUp below has
  // nothing to act on and never unlinks a file this process did not create.
  if (!DIR) DIR = deskPaths().dir;
  SOCK = undefined;
} else if (!DIR || !SOCK) {
  const p = deskPaths();
  DIR = DIR || p.dir;
  SOCK = SOCK || p.sock;
}

// THE KERNEL TRUNCATES A LONG SOCKET PATH INSTEAD OF REFUSING IT. sockaddr_un
// holds 104 bytes on macOS and 108 on Linux, and a bind() past that does not
// fail: measured 2026-09-08, a 110-byte path listened as its own first 107
// bytes, so `ls` showed a socket with a chopped-off name, every client got
// ENOENT on the real path, and the only symptom was a desk nobody could reach.
// A refusal at startup is what this file's exit codes exist for. Loopback
// mode never touches a socket path, so it never hits this either.
const SOCK_MAX = 103;
if (!LISTEN && Buffer.byteLength(SOCK) > SOCK_MAX) {
  console.error('desk: the socket path is ' + Buffer.byteLength(SOCK) + ' bytes, over the kernel limit of ' +
    SOCK_MAX + ', and would be silently truncated: ' + SOCK);
  process.exit(64);
}

// normalizeAddr - one comparable form, used for both SELF_ADDRS members and
// every forwarded-header entry, so the two sides of the comparison are never
// normalized two different ways:
//   - a bracketed IPv6 literal (`[addr]` or `[addr]:port`, the RFC 3986
//     host:port form) loses the brackets and any port outside them;
//   - an unbracketed address with a trailing `:<port>` loses that suffix,
//     but only when what remains has no colon of its own - a bare IPv6
//     address always has more than one colon, so this never eats part of one;
//   - a trailing `%zone` suffix is dropped (an IPv6 link-local address
//     carries the interface it was seen on, and that suffix is local to this
//     process, never something a forwarded header would reproduce the same
//     way twice);
//   - a leading `::ffff:` (the IPv4-mapped IPv6 form some platforms use) is
//     dropped so a mapped and a bare form of the same address compare equal;
//   - the whole thing is trimmed and lowercased.
function normalizeAddr(raw) {
  let a = String(raw).trim().toLowerCase();
  if (a.startsWith('[')) {
    const close = a.indexOf(']');
    if (close !== -1) a = a.slice(1, close);
  } else {
    const lastColon = a.lastIndexOf(':');
    if (lastColon !== -1) {
      const portPart = a.slice(lastColon + 1);
      const hostPart = a.slice(0, lastColon);
      if (/^[0-9]+$/.test(portPart) && !hostPart.includes(':')) a = hostPart;
    }
  }
  const zone = a.indexOf('%');
  if (zone !== -1) a = a.slice(0, zone);
  if (a.startsWith('::ffff:')) a = a.slice(7);
  return a;
}

// SELF_ADDRS - every address this host answers to, collected ONCE at
// startup, never per request: the interfaces' own non-internal addresses
// (loopback excluded on purpose - the serve tool forwards the tailnet
// address, never 127.0.0.1, so a bare loopback hit without the header is the
// existing gate's business, not this one), plus whatever
// STEWARD_DESK_SELF_ADDRS names for a host where that is not the whole
// picture (a second tailnet interface, a container's own address). Because
// this is read once, a desk started before the tailnet interface has its
// address never learns it later - the gate is then a silent no-op for that
// address until the process is restarted, or the operator names the address
// in STEWARD_DESK_SELF_ADDRS up front.
const SELF_ADDRS = new Set();
let ownInterfaces;
try {
  ownInterfaces = os.networkInterfaces();
} catch (e) {
  console.error('desk: could not read the host\'s own network interfaces: ' + (e && e.message ? e.message : e));
  process.exit(78);
}
for (const ifaces of Object.values(ownInterfaces)) {
  for (const iface of ifaces || []) {
    if (!iface.internal) SELF_ADDRS.add(normalizeAddr(iface.address));
  }
}
for (const extra of (process.env.STEWARD_DESK_SELF_ADDRS || '').split(/\s+/)) {
  if (extra) SELF_ADDRS.add(normalizeAddr(extra));
}

// A NODE CANNOT VOUCH FOR A PERSON WHEN IT IS THE ONE ASKING. Measured on a
// two-account host: the tailnet client identifies the NODE, and a node is
// registered to one login - so a request the desk's own host sends toward
// this desk's own socket carries the node owner's login header and
// `x-forwarded-for: <the node's own tailnet address>`, no matter which local
// account on that host actually made the request. For that request the
// header is not forged and still names the wrong person: the server has no
// way to tell which local account sent it, so refusing is the only honest
// answer. The host's own outbound firewall rule is the first line of
// defense against this; this check is the second, so a host without that
// rule is not left open. It matters only in the socket mode, where the
// socket's permission bits mean only the serve tool can reach this server in
// the first place - the loopback-listen mode already accepts that any local
// process can set its own headers, and this check adds nothing to a cost
// already paid there.
//
// ANY ENTRY IN THE CHAIN WINS, NOT ONLY THE FIRST ONE. This server is the
// TERMINUS of the forwarded-for chain, never a hop: the proxy in front of it
// inserts the inbound node's own address and APPENDS a client-supplied
// X-Forwarded-For to that, rather than replacing it. So the self address can
// land anywhere in the list, and a gate that trusted only the first entry is
// bypassed by one header a local account sets itself: a request sent as
// `x-forwarded-for: 198.51.100.9` arrives here as
// `198.51.100.9, <the node's own address>`, self last. Because this server
// never forwards the request on, scanning every entry costs nothing a
// legitimate remote caller pays for - a real chain never happens to contain
// this host's own address, so refusing on any match never refuses a real one.
const SELF_ORIGIN_FORBIDDEN = "a request from the desk's own host cannot be attributed to a person";

// selfOriginAddrs - every comma-separated entry of the forwarded-for header,
// each normalized exactly the way SELF_ADDRS is (see normalizeAddr), so a
// match on any one of them is a match. Node already joins repeated headers
// with ", " before handler code ever sees them - only set-cookie is
// delivered as an array - so the Array.isArray branch below exists only to
// feed that join-then-split the same way regardless, never as a live path.
function selfOriginAddrs(req) {
  const raw = req.headers['x-forwarded-for'];
  if (!raw) return [];
  const joined = Array.isArray(raw) ? raw.join(', ') : String(raw);
  return joined.split(',').map((entry) => normalizeAddr(entry));
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
// The shape a principal slug has: registry_valid_name minus the leading `_`
// the registry reserves for the operator file, so this is the registry's own
// charset, not merely a superset that happens to be safe.
const SLUG_RE = /^[a-z0-9-]+$/;

// logBridgeOutage - the ONE line an outage gets. Never the header value's own
// text: only its length, because that value is attacker-reachable and a log
// is not the place to reflect it back. What an operator needs is what failed
// and how - a code, a signal, an exit status - not the login that triggered it.
function logBridgeOutage(login, e) {
  const bits = [];
  if (e) {
    if (e.code) bits.push('code=' + e.code);
    if (e.signal) bits.push('signal=' + e.signal);
    if (typeof e.status === 'number') bits.push('rc=' + e.status);
    if (!bits.length) bits.push('detail=' + String(e.message || e).slice(0, 120));
  } else {
    bits.push('unexpected-output');
  }
  const len = typeof login === 'string' ? login.length : 0;
  console.error('desk: principal-for-login failed (' + bits.join(' ') + '), login length ' + len);
}

// principalFor - exactly one slug, or nothing, or an outage. Never a guess.
//
// rc 1 (no row claims the login) and rc 65 (two rows claim it) are the
// POLICY path: an unknown or ambiguous login is an ordinary event on a shared
// tailnet, so those two stay silent and become a 403. Everything else - the
// bridge missing or not executable, the 5s timeout, an estate that stopped
// loading (rc 78), any other exit code, or output that is not a bare slug -
// means the desk is down, not that this viewer was refused, so it is logged
// once and reported as an outage for the caller to turn into a 503.
function principalFor(login) {
  if (typeof login !== 'string' || !LOGIN_RE.test(login)) return { slug: null, outage: false };
  let out;
  try {
    out = execFileSync(LOOKUP, [login], { encoding: 'utf8', timeout: 5000, stdio: ['ignore', 'pipe', 'pipe'] });
  } catch (e) {
    if (e && (e.status === 1 || e.status === 65)) return { slug: null, outage: false };
    logBridgeOutage(login, e);
    return { slug: null, outage: true };
  }
  const slug = out.trim();
  if (slug && SLUG_RE.test(slug)) return { slug, outage: false };
  logBridgeOutage(login, null);
  return { slug: null, outage: true };
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

  // A NODE CANNOT VOUCH FOR A PERSON. Checked before the login header is even
  // read - see SELF_ORIGIN_FORBIDDEN above for why a self-origin request's
  // login header is true and still names the wrong person, and for why every
  // entry of the chain is checked, not only the first.
  const selfMatch = selfOriginAddrs(req).find((addr) => SELF_ADDRS.has(addr));
  if (selfMatch !== undefined) {
    console.error('desk: refused self-origin request from ' + selfMatch);
    return send(res, 403, SELF_ORIGIN_FORBIDDEN, { 'content-type': 'text/plain; charset=utf-8' });
  }

  // ONLY THE HEADER TAILSCALE SERVE SETS. It strips a client-sent copy before
  // forwarding, so this value came from the tailnet's own identity and not from
  // the request. Nothing else - no query parameter, no cookie, no other header
  // - is consulted, so there is nothing else to spoof.
  const { slug: principal, outage } = principalFor(req.headers['tailscale-user-login']);
  if (outage) return send(res, 503, NO_MEASUREMENT); // a dead gate is an outage, never a refusal
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
  } catch (e) {
    console.error('desk: render threw: ' + (e && e.message ? e.message : e));
    return send(res, 503, NO_MEASUREMENT); // a snapshot this renderer cannot read is not a page
  }
  if (html === null) return send(res, 404, NOT_FOUND); // same body as unknown: no oracle
  send(res, 200, html);
});

// cleanUp only ever touches SOCK, so in loopback mode - where SOCK is cleared
// to undefined right after the mode branch above, whatever the environment
// held - it has nothing to do.
const cleanUp = () => {
  if (!SOCK) return;
  try { unlinkSync(SOCK); } catch { /* already gone */ }
};

// listenTarget - what to name in a bind failure or the startup log line: the
// socket path in the default mode, the host and port in loopback mode.
const listenTarget = () => (LISTEN ? LISTEN.host + ':' + LISTEN.port : SOCK);

server.on('error', (e) => {
  console.error('desk: could not bind ' + listenTarget() + ': ' + (e && e.code ? e.code : e));
  process.exit(64);
});

function listenSocket() {
  server.listen(SOCK, () => {
    // THE SOCKET IS THE OWNER'S ALONE. The serve tool that fronts this desk
    // runs as the same account; every other account on the machine is
    // refused by the filesystem, before a single byte of HTTP is parsed. The
    // umask is set before this call, so there is no window where the socket
    // exists at a wider mode.
    chmodSync(SOCK, 0o600);
    console.error('desk: listening on ' + SOCK);
  });
}

function listenTcp() {
  server.listen(LISTEN.port, LISTEN.host, () => {
    console.error('desk: listening on ' + LISTEN.host + ':' + LISTEN.port);
  });
}

// bindSocket - a socket path that already exists is either STALE (the process
// that made it is gone, and the file is a leftover) or LIVE (another desk is
// answering on it right now). Only the stale case may be unlinked; stealing
// the path out from under a live process would mean two desks momentarily
// both believe they own it, and the file this server actually creates could
// end up owned by neither. connect() is the only cheap way to tell them
// apart: ECONNREFUSED (nobody home) means stale, a successful connect means
// live.
function bindSocket() {
  mkdirSync(dirname(SOCK), { recursive: true });
  if (!existsSync(SOCK)) return listenSocket();
  const probe = net.connect(SOCK);
  probe.on('connect', () => {
    probe.destroy();
    console.error('desk: another desk holds the socket at ' + SOCK);
    process.exit(64);
  });
  probe.on('error', () => {
    // Not live: an unlink here races nothing, because nothing was listening.
    try { unlinkSync(SOCK); } catch { /* already gone */ }
    listenSocket();
  });
}

process.umask(0o077);
if (LISTEN) {
  listenTcp();
} else {
  bindSocket();
}

for (const sig of ['SIGTERM', 'SIGINT']) {
  process.on(sig, () => { server.close(); cleanUp(); process.exit(0); });
}
