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
//   STEWARD_DESK_FRONT_LISTEN  opt-in SECOND listener for the public front,
//                       as `<addr>:<port>`. See "THE FRONT" below.
//   STEWARD_DESK_FRONT_PEER    the one socket peer that second listener
//                       answers. Required with the line above, refused
//                       without it.
//
// THE FRONT IS A SECOND LISTENER WITH A SECOND IDENTITY SOURCE, AND THE TWO
// NEVER MIX. The tailnet listener above believes one header and no cookie;
// the front believes one cookie this desk minted itself (desk/cookie.mjs) and
// no header. A request that arrives on the socket carrying a session cookie
// is answered exactly as one carrying nothing, and a request on the front
// carrying `tailscale-user-login` is answered exactly as one carrying
// nothing - so neither entrance can be talked into the other's gate.
//
// THE FRONT ANSWERS ONE PEER. A public proxy box terminates TLS off-host and
// forwards here; it is the only address allowed to connect (the tailnet ACL
// says so, and front.mjs's visitorAddress says so a second time), which is
// what makes its `x-real-ip` believable as the visitor's address - nothing
// else can reach the port to write one. Every other peer gets 403 before a
// header, a cookie or a path is read. The self-origin check that guards the
// tailnet listener is NOT applied here: it exists because a node vouches for
// a node, and the front's identity is a signed cookie, not a node.
//
// THE PROXY BOX HOLDS NOTHING. Discovery, the token exchange and the id_token
// signature check all happen in this process (desk/oidc.mjs), so the box can
// forward bytes and nothing more. The identity the provider proves is
// resolved to a principal by the registry's own bridge, exactly as a tailnet
// login is - and the cookie carries that IDENTITY rather than the principal,
// so the same question is asked of the registry again on every front request,
// through a memo that holds each identity's answer - a slug, or nobody - for
// at most five seconds. Removing a person's OIDC word, or moving it to
// somebody else, therefore takes effect within five seconds and not at their
// cookie's expiry twelve hours later. The memo exists because the bridge
// forks a subshell per principal row and execFileSync blocks both listeners;
// see principalForIdentityCached.
//
// EXIT CODES
//   64  A setting that cannot be honoured: STEWARD_DESK_MAX_AGE that is not a
//       positive number (a silent fallback there would serve a stale desk
//       forever), a socket path the kernel would truncate (see below), a bind
//       failure on the socket or the loopback address, a socket path another
//       live desk already holds (never stolen - see bindSocket below), or a
//       STEWARD_DESK_LISTEN value that does not name a loopback host with a
//       usable port (see parseListen below). With the front asked for: only
//       one of its two variables set, a front listen address that is neither
//       the tailnet's nor loopback, a front peer that is neither, or a bind
//       failure on the front's own address (see desk/front.mjs).
//   78  desk/bin/desk-paths could not answer, desk/bin/principal-for-login
//       is not runnable (checked once at startup with accessSync), or the
//       host's own network interfaces could not be read. A guessed path, a
//       gate nobody could even ask, or a self-address set built on a partial
//       read is a second desk nobody is reading, so there is no fallback for
//       any of the three. With the front enabled, also: desk-paths printed no
//       origin=, providers= or session_key= line, the session key file cannot
//       be loaded, or desk/providers.d names no provider. A front that
//       started without one of those would be a login page that can never
//       finish a login, which is worse than a desk that refused to start.
// =======================================================================

import http from 'node:http';
import net from 'node:net';
import os from 'node:os';
import { readFileSync, unlinkSync, chmodSync, mkdirSync, existsSync, accessSync, constants } from 'node:fs';
import { execFileSync } from 'node:child_process';
import { join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';
import { pageIndex, pageTeam, pageProject, pageSession, pageLogin, ICON } from './render.mjs';
import { normalizeAddr, parseFrontListen, parseFrontPeer, visitorAddress, RateLimiter } from './front.mjs';
import { parseCookies, serializeCookie, loadSessionKey, mintSession, verifySession, mintState, verifyState } from './cookie.mjs';
import { loadProviders, discover, beginLogin, exchangeCode, verifyIdToken, identityOf } from './oidc.mjs';

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
//
// THE BRIDGE PRINTS UP TO FIVE LINES AND THIS READER REQUIRES TWO. dir= and
// sock= are always there; origin=, providers= and session_key= are printed
// only when the estate names them, because a desk with no front has none of
// the three and must not be refused for their absence. The front's own
// startup block below is what requires them, and only when the front is on.
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
    const m = line.match(/^(dir|sock|origin|providers|session_key)=(.+)$/);
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

// FRONT - null unless the operator asked for the second listener, and a
// refusal rather than a half-configured one whenever they asked for it and
// something it needs is missing. Everything below is measured ONCE, here, at
// startup: the two variables must arrive together (one alone is a typo, and
// guessing the other would either publish a desk nobody meant to publish or
// open a port that answers nobody), the estate must name an origin, a
// providers directory and a key file, and at least one provider must be
// readable.
const FRONT_LISTEN_RAW = process.env.STEWARD_DESK_FRONT_LISTEN;
const FRONT_PEER_RAW = process.env.STEWARD_DESK_FRONT_PEER;
let FRONT = null;
if (FRONT_LISTEN_RAW || FRONT_PEER_RAW) {
  if (!FRONT_LISTEN_RAW || !FRONT_PEER_RAW) {
    console.error('desk: STEWARD_DESK_FRONT_LISTEN and STEWARD_DESK_FRONT_PEER must be set together');
    process.exit(64);
  }
  let frontListen, frontPeer;
  try {
    frontListen = parseFrontListen(FRONT_LISTEN_RAW);
    frontPeer = parseFrontPeer(FRONT_PEER_RAW);
  } catch (e) {
    console.error('desk: ' + (e && e.message ? e.message : e));
    process.exit(64);
  }
  const p = deskPaths();
  for (const k of ['origin', 'providers', 'session_key']) {
    if (!p[k]) {
      console.error('desk: the front needs a ' + k + '= line from desk-paths ' +
        '(DESK_ORIGIN, desk/providers.d, DESK_SESSION_KEY_FILE in the estate)');
      process.exit(78);
    }
  }
  let sessionKey, providers;
  try {
    sessionKey = loadSessionKey(p.session_key);
  } catch (e) {
    console.error('desk: the front\'s session key cannot be used: ' + (e && e.message ? e.message : e));
    process.exit(78);
  }
  try {
    providers = loadProviders(p.providers);
  } catch (e) {
    console.error('desk: ' + (e && e.message ? e.message : e));
    process.exit(78);
  }
  if (providers.size === 0) {
    console.error('desk: desk/providers.d names no provider, so the front could never finish a login');
    process.exit(78);
  }
  // No second bridge to check here: the front asks principal-for-login, the
  // same bridge the tailnet listener asks, and its runnability was checked
  // once at the top of this file for both.
  FRONT = {
    listen: frontListen, peer: frontPeer, origin: p.origin, key: sessionKey,
    providers, limiter: new RateLimiter(10, 60000),
    // Built once, here, rather than on every request for the chooser: the
    // provider set comes from disk at startup and never changes while this
    // process runs, so pageLogin's output is the same string every time it
    // would otherwise be called.
    chooserHtml: pageLogin(providers),
    // THE COOKIE PATH HAS ITS OWN, GENEROUS BUDGET. The limiter above guards
    // the three auth paths; every other path on the front resolves a cookie
    // to a principal, and that is the expensive question (a process per
    // principal row). The memo holds the answer for five seconds, so a single
    // visitor cannot make the desk ask more than that - but a request that
    // does not ask the bridge still reads a snapshot and renders a page, and
    // both listeners share one event loop. Two a second, sustained, is far
    // above a person reading their desk and far below what it takes to
    // occupy the process.
    cookieLimiter: new RateLimiter(120, 60000)
  };
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

// normalizeAddr - one comparable form for an address; see front.mjs.

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
  if (!extra) continue;
  const n = normalizeAddr(extra);
  if (n) SELF_ADDRS.add(n);
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
  // `img-src data:` IS NOT A LOOSENING OF `default-src 'none'` IN ANY
  // DIRECTION THAT MATTERS: no origin is named, so an image can still come
  // from nowhere on the network. It is here for the one image the pages
  // declare, the empty `data:` icon in desk/render.mjs, which exists so the
  // browser does not go and ask for /favicon.ico with the session cookie on
  // it. Without this the icon would be refused by the page's own policy and
  // the operator's console would carry a violation on every page view.
  'content-security-policy': "default-src 'none'; img-src data:; style-src 'unsafe-inline'; base-uri 'none'; form-action 'none'"
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
const NOT_FOUND = '<!doctype html><meta charset="utf-8"><title>Steward Desk</title>' + ICON + '<p>Not found.</p>';
const FORBIDDEN = '<!doctype html><meta charset="utf-8"><title>Steward Desk</title>' + ICON +
  '<p>No desk for this login.</p>';
const NO_MEASUREMENT = '<!doctype html><meta charset="utf-8"><title>Steward Desk</title>' + ICON +
  '<p>The desk has no fresh measurement. Try again in a minute.</p>';

// The shape a tailnet login has. Checked BEFORE the bridge is spawned, so a
// hostile or malformed header value never becomes an argument to a process.
const LOGIN_RE = /^[A-Za-z0-9._%+@-]{1,254}$/;
// The shape a principal slug has: registry_valid_name minus the leading `_`
// the registry reserves for the operator file, so this is the registry's own
// charset, not merely a superset that happens to be safe.
const SLUG_RE = /^[a-z0-9-]+$/;

// logBridgeOutage - the ONE line an outage gets. Never the value's own text:
// only its length, because that value is attacker-reachable and a log is not
// the place to reflect it back. What an operator needs is what failed and how
// - a code, a signal, an exit status - not the login that triggered it.
function logBridgeOutage(value, e) {
  const bridge = 'principal-for-login';
  const bits = [];
  if (e) {
    if (e.code) bits.push('code=' + e.code);
    if (e.signal) bits.push('signal=' + e.signal);
    if (typeof e.status === 'number') bits.push('rc=' + e.status);
    if (!bits.length) bits.push('detail=' + String(e.message || e).slice(0, 120));
  } else {
    bits.push('unexpected-output');
  }
  const len = typeof value === 'string' ? value.length : 0;
  console.error('desk: ' + bridge + ' failed (' + bits.join(' ') + '), value length ' + len);
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

// principalForIdentity - the same bridge, asked in its two-argument form: a
// source and a value. The rc reading is principalFor's, word for word, and for
// the same reasons - rc 1 and rc 65 are policy (nobody, or two people, claim
// this identity), everything else is an outage.
//
// THE SHAPE IS CHECKED BEFORE THE PROCESS IS SPAWNED, exactly as LOGIN_RE is
// checked before a tailnet login becomes an argument. This is the registry's
// own OIDC_LOGIN word form (lib/registry.sh, _registry_oidc_login_valid):
// an issuer slug, a colon, and a subject out of the URL-safe unreserved set -
// which is what identityOf builds, with the tenant folded into the subject as
// `<tid>.<sub>` when the provider is multi-tenant.
const IDENTITY_RE = /^[a-z0-9][a-z0-9-]*:[A-Za-z0-9._~-]{1,300}$/;
function principalForIdentity(source, value) {
  if (typeof value !== 'string' || !IDENTITY_RE.test(value)) return { slug: null, outage: false };
  let out;
  try {
    out = execFileSync(LOOKUP, [source, value], { encoding: 'utf8', timeout: 5000, stdio: ['ignore', 'pipe', 'pipe'] });
  } catch (e) {
    if (e && (e.status === 1 || e.status === 65)) return { slug: null, outage: false };
    logBridgeOutage(value, e);
    return { slug: null, outage: true };
  }
  const slug = out.trim();
  if (slug && SLUG_RE.test(slug)) return { slug, outage: false };
  logBridgeOutage(value, null);
  return { slug: null, outage: true };
}

// THE ANSWER IS REMEMBERED FOR FIVE SECONDS, BECAUSE ASKING COSTS A PROCESS.
// The bridge forks a subshell per principal row, so the question is O(rows):
// measured in review 2026-09-08 at 33.8 ms for five rows, 99.7 ms for twenty
// and 223.5 ms for fifty - and execFileSync blocks the event loop, which both
// listeners share. Asked once per front request, that is a ceiling of a few
// requests a second for the whole desk, the operator's tailnet view included,
// and anybody holding a valid cookie could sit at it with one loop.
//
// Five seconds is short enough that revocation is still a thing that happens
// while the operator is watching, and long enough that a person clicking
// around their desk asks once rather than once a click.
//
// A NEGATIVE ANSWER IS CACHED TOO. A removed word must stay removed for the
// same five seconds a granted one stays granted; caching only the yes would
// mean every refused request pays the process, which is the cost this exists
// to bound - and the refused are exactly who would send the most of them.
// AN OUTAGE IS NOT CACHED: it is not an answer, and the next request is the
// one that finds the bridge working again.
const IDENTITY_CACHE_MS = 5000;
const IDENTITY_CACHE_MAX = 1000;
const identityCache = new Map();
function principalForIdentityCached(source, value) {
  const key = source + ' ' + value;
  const now = Date.now();
  const hit = identityCache.get(key);
  if (hit && now - hit.at < IDENTITY_CACHE_MS) return { slug: hit.slug, outage: false };
  const answer = principalForIdentity(source, value);
  if (answer.outage) return answer;
  // The map is bounded like the rate limiter's: only identities carried by a
  // cookie this host signed reach here, but a bound that is never tested is
  // not a bound. Stale entries first, and a clear if that was not enough -
  // the cost of a clear is a re-ask, never a wrong answer.
  if (identityCache.size >= IDENTITY_CACHE_MAX) {
    for (const [k, v] of identityCache) if (now - v.at >= IDENTITY_CACHE_MS) identityCache.delete(k);
    if (identityCache.size >= IDENTITY_CACHE_MAX) identityCache.clear();
  }
  identityCache.set(key, { slug: answer.slug, at: now });
  return answer;
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

  return servePage(req, res, principal, HEADERS);
});

// servePage - the part both entrances share: once SOMEBODY is known, the route
// table and the snapshot decide the rest, and they decide it the same way for
// a tailnet login and for a front cookie. The header set is a parameter
// because that is the only thing the two answers differ in (the front allows
// `form-action 'self'` for its logout button); every status and every body
// below is the same on both, which is what keeps the two entrances from
// becoming two behaviours.
function servePage(req, res, principal, headers) {
  let path;
  try {
    path = new URL(req.url, 'http://desk').pathname;
  } catch {
    return send(res, 404, NOT_FOUND, headers);
  }

  const route = ROUTES.map(([re, fn]) => [path.match(re), fn]).find(([m]) => m);
  if (!route) return send(res, 404, NOT_FOUND, headers);

  const snap = loadSnapshot(principal);
  if (!snap) return send(res, 503, NO_MEASUREMENT, headers);

  let html;
  try {
    html = route[1](snap, route[0][1]);
  } catch (e) {
    console.error('desk: render threw: ' + (e && e.message ? e.message : e));
    return send(res, 503, NO_MEASUREMENT, headers); // a snapshot this renderer cannot read is not a page
  }
  if (html === null) return send(res, 404, NOT_FOUND, headers); // same body as unknown: no oracle
  send(res, 200, html, headers);
}

// ===========================================================================
// THE FRONT. A second listener, one peer, and a cookie instead of a header.
// Everything below runs only when FRONT is set; a desk without a front never
// evaluates a line of it.

// FRONT_HEADERS - the tailnet's header set with one change: the logout button
// is a form that posts back here, so `form-action` must allow 'self' where the
// tailnet listener, which has no form on any page, allows nothing. Everything
// else - no-store, nosniff, DENY, no-referrer, default-src 'none' - is the
// same set, so a front page is no less locked down than a socket page.
const FRONT_HEADERS = Object.assign({}, HEADERS, {
  'content-security-policy': HEADERS['content-security-policy'].replace("form-action 'none'", "form-action 'self'")
});

// Two more fixed refusal bodies, and they are plain text rather than HTML for
// the same reason the self-origin refusal is: neither is a page a person
// browses to, and both are read by an operator in a log or a curl.
const PEER_FORBIDDEN = 'Forbidden: not the front peer.';
const TOO_MANY = 'Too many requests.';
const PLAIN = { 'content-type': 'text/plain; charset=utf-8' };

const SESSION_COOKIE = '__Host-desk-session';
const STATE_COOKIE = '__Host-desk-oauth';
const SESSION_MAX_AGE = 43200; // twelve hours, the same bound verifySession applies
const STATE_MAX_AGE = 600;     // ten minutes, long enough for one login

const nowSec = () => Math.floor(Date.now() / 1000);

// clearCookie - the only value other than a freshly minted one that may reach
// serializeCookie. That function concatenates its value bare, so nothing
// derived from a request is ever handed to it: what goes in is this empty
// string, mintSession's output, or mintState's output, and nothing else.
const clearCookie = (name) => serializeCookie(name, '', { maxAge: 0 });

// THE OPERATOR GETS THE REASON, THE VISITOR GETS THE SAME 403 AS EVERY OTHER
// REFUSAL, AND NEITHER EVER GETS THE MATERIAL. desk/oidc.mjs refuses with
// messages that name a slug and a reason and nothing else; anything else came
// from somewhere that never promised that - readFileSync on the client secret
// names the secret's own path in its ENOENT - so an unrecognised error is
// logged by its class alone. The token, the code and the secret appear in no
// branch of either.
const SAFE_REASON = /^(id_token: |discovery for |token endpoint for |jwks for )/;
function refusalReason(e) {
  const msg = e && typeof e.message === 'string' ? e.message.split('\n')[0] : '';
  if (SAFE_REASON.test(msg)) return msg;
  return e && e.constructor && e.constructor.name ? e.constructor.name : 'error';
}

// authLogin - GET /desk/auth/login. Without a provider it is the chooser page;
// with a known one it mints the state cookie and sends the visitor on. The
// state cookie carries the PKCE verifier and the nonce as well as the state,
// signed under the host's key, so the callback needs no server-side store to
// know that this browser started this login.
async function authLogin(url, res) {
  const slug = url.searchParams.get('provider');
  if (slug === null) return send(res, 200, FRONT.chooserHtml, FRONT_HEADERS);
  const provider = FRONT.providers.get(slug);
  // An unknown provider is the same 404 as an unknown route: asking which
  // slugs exist is answered by the chooser page, not by a difference here.
  if (!provider) return send(res, 404, NOT_FOUND, FRONT_HEADERS);
  let doc;
  try {
    doc = await discover(provider);
  } catch (e) {
    console.error('desk front: discovery failed for ' + slug + ': ' + refusalReason(e));
    return send(res, 503, NO_MEASUREMENT, FRONT_HEADERS); // a provider that is down is not this person's fault
  }
  const begun = beginLogin(provider, doc, FRONT.origin + '/desk/auth/callback');
  const state = mintState(FRONT.key, {
    state: begun.state, nonce: begun.nonce, verifier: begun.verifier, provider: slug, issuedAt: nowSec()
  });
  return send(res, 303, '', Object.assign({}, FRONT_HEADERS, {
    location: begun.url,
    'set-cookie': serializeCookie(STATE_COOKIE, state, { maxAge: STATE_MAX_AGE })
  }));
}

// authCallback - GET /desk/auth/callback. The state cookie must verify AND
// must match the state the provider echoed; then the code is exchanged and the
// id_token verified in this process. Every failure between here and a
// principal is the same 403 with the state cookie cleared, so the callback is
// never an oracle about which step failed.
async function authCallback(url, cookies, res) {
  const refuse = () => send(res, 403, FORBIDDEN, Object.assign({}, FRONT_HEADERS, {
    'set-cookie': clearCookie(STATE_COOKIE)
  }));
  const fields = verifyState(FRONT.key, cookies.get(STATE_COOKIE), nowSec());
  if (!fields || url.searchParams.get('state') !== fields.state) return refuse();
  const provider = FRONT.providers.get(fields.provider);
  const code = url.searchParams.get('code');
  if (!provider || !code) return refuse();
  let claims;
  try {
    const doc = await discover(provider);
    const token = await exchangeCode(provider, doc, {
      code, verifier: fields.verifier, redirectUri: FRONT.origin + '/desk/auth/callback'
    });
    claims = await verifyIdToken(provider, doc, token, { nonce: fields.nonce });
  } catch (e) {
    console.error('desk front: login refused (' + fields.provider + '): ' + refusalReason(e));
    return refuse();
  }
  const identity = identityOf(provider, claims);
  const { slug, outage } = principalForIdentityCached('oidc', identity.slice('oidc:'.length));
  if (outage) return send(res, 503, NO_MEASUREMENT, FRONT_HEADERS);
  if (!slug) return refuse(); // invitation binding attaches here (services plan)
  // THE COOKIE CARRIES THE IDENTITY, NOT THE SLUG THIS LOGIN RESOLVED TO. The
  // slug is today's answer and it is asked again on every request, at most
  // five seconds old (principalForIdentityCached); minting it
  // into the cookie would freeze it for twelve hours. It is resolved here only
  // so that an identity no row claims never gets a session at all.
  return send(res, 303, '', Object.assign({}, FRONT_HEADERS, {
    location: '/desk/',
    'set-cookie': [
      serializeCookie(SESSION_COOKIE, mintSession(FRONT.key, identity, nowSec()), { maxAge: SESSION_MAX_AGE }),
      clearCookie(STATE_COOKIE)
    ]
  }));
}

// authLogout - POST /desk/auth/logout. SameSite=Lax already keeps the cookie
// off a cross-site POST, so these two checks are the second lock rather than
// the first: `sec-fetch-site` must say the request came from this origin, and
// an Origin header, when the browser sent one, must be this origin exactly.
function authLogout(req, res) {
  if (req.headers['sec-fetch-site'] !== 'same-origin') return send(res, 403, FORBIDDEN, FRONT_HEADERS);
  if (req.headers.origin !== undefined && req.headers.origin !== FRONT.origin) {
    return send(res, 403, FORBIDDEN, FRONT_HEADERS);
  }
  // BOTH COOKIES GO. A login begun and abandoned leaves __Host-desk-oauth in
  // the browser for its full ten minutes, and a person who just logged out has
  // said they are done - the callback clears both, and so does this.
  return send(res, 303, '', Object.assign({}, FRONT_HEADERS, {
    location: '/desk/auth/login',
    'set-cookie': [clearCookie(SESSION_COOKIE), clearCookie(STATE_COOKIE)]
  }));
}

// A PEER REFUSAL IS A LINE PER MINUTE, NOT A LINE PER PACKET. Every request
// from a peer that is not the box is refused before anything is read, so a
// scan of the port would otherwise write the journal full - and a log a
// person cannot read is a log nobody reads. The first refusal is logged at
// once, because the operator wants to know that it started; after that the
// minute is counted and one line reports the count.
let refusedPeers = 0;
let refusedSince = 0;
const REFUSAL_LOG_MS = 60000;
function noteRefusedPeer(addr) {
  const now = Date.now();
  if (refusedSince === 0) {
    refusedSince = now;
    refusedPeers = 0;
    return console.error('desk front: refused peer ' + addr);
  }
  refusedPeers++;
  if (now - refusedSince < REFUSAL_LOG_MS) return;
  console.error('desk front: refused ' + refusedPeers + ' connection(s) from peers other than the box in the last minute');
  refusedSince = now;
  refusedPeers = 0;
}

// handleFront - the whole front request, in the order the gates have to run:
// the peer first (before a header, a cookie or a path is read), then the
// method, then the route, then the navigation check, then the rate limiter on
// the auth paths, then the cookie. EVERYTHING FREE COMES BEFORE THE BUDGET:
// a hit is a scarce thing a visitor gets ten of a minute, and only a request
// this desk is actually going to work for may spend one.
async function handleFront(req, res) {
  const visitor = visitorAddress(req, FRONT.peer);
  if (visitor === null) {
    noteRefusedPeer(normalizeAddr(req.socket.remoteAddress));
    return send(res, 403, PEER_FORBIDDEN, Object.assign({}, FRONT_HEADERS, PLAIN));
  }

  let url;
  try {
    url = new URL(req.url, FRONT.origin);
  } catch {
    return send(res, 404, NOT_FOUND, FRONT_HEADERS);
  }
  const path = url.pathname;
  const cookies = parseCookies(req.headers.cookie);

  // THE METHOD IS CHECKED BEFORE THE BUDGET IS SPENT. A rate-limit hit is a
  // scarce thing a visitor gets ten of per minute, and a method this desk
  // would refuse anyway must not cost one of them. POST is a method here only
  // for the logout form.
  const readMethod = req.method === 'GET' || req.method === 'HEAD';
  const logoutPost = req.method === 'POST' && path === '/desk/auth/logout';
  if (!readMethod && !logoutPost) {
    return send(res, 405, '', Object.assign({}, FRONT_HEADERS, { allow: 'GET, HEAD' }));
  }

  // AND HEAD IS ONE OF THOSE METHODS ON THE AUTH PATHS. Each of the three
  // answers exactly one method - GET for the login and the callback, POST for
  // the logout - and every other method was refused above, so HEAD is the one
  // that used to reach the limiter, spend a hit and 404. Measured on this
  // branch: ten HEADs of /desk/auth/login then that visitor's own GET of the
  // same path was 429, which is verbatim the lockout the paragraph above
  // exists to prevent. It is refused here, BEFORE the budget, naming the one
  // method the path does answer. The desk's pages keep HEAD: they are pages,
  // and a HEAD of one costs a snapshot read and nothing scarce.
  if (path.startsWith('/desk/auth/') && req.method === 'HEAD') {
    const allow = path === '/desk/auth/logout' ? 'POST' : 'GET';
    return send(res, 405, '', Object.assign({}, FRONT_HEADERS, { allow }));
  }

  // THE AUTH PATHS ARE THE ONLY ONES A STRANGER CAN REACH, so they are the
  // ones that carry a cost: each one spawns a bridge or talks to a provider.
  // Ten per minute per visitor is far above what a person clicking a login
  // button does and far below what a scan needs to be useful. The 429 still
  // comes before any provider is contacted.
  if (path.startsWith('/desk/auth/')) {
    // THE ROUTE IS MATCHED BEFORE THE BUDGET IS SPENT, for the same reason the
    // method is: a request this desk answers with 404 costs it nothing, so it
    // must cost the visitor nothing either. It used to cost a hit, and that
    // was reachable from any other site: ten `<img src=".../desk/auth/logout">`
    // on a page or in an HTML mail make the victim's own browser spend the
    // victim's own ten hits from the victim's own address, and the first real
    // click on /desk/auth/login then meets 429 for a minute, renewably.
    const matched = (req.method === 'GET' && (path === '/desk/auth/login' || path === '/desk/auth/callback')) || logoutPost;
    if (!matched) return send(res, 404, NOT_FOUND, FRONT_HEADERS);

    // AND A SUBRESOURCE IS NOT A CLICK. The route match above closes the 404
    // path; /desk/auth/login is a real route, so ten image loads of it would
    // still be ten 200s and ten hits. `sec-fetch-dest` is the browser's own
    // word for what the answer is going to be used as: `document` is a
    // navigation - the only way a person reaches these three - and image,
    // script, style, empty and the rest are a subresource some page asked
    // for. A request without the header at all is allowed through: old
    // browsers and curl send none, and this is a second lock rather than the
    // first, exactly as `sec-fetch-site` is in authLogout.
    const dest = req.headers['sec-fetch-dest'];
    if (dest !== undefined && dest !== 'document') return send(res, 403, FORBIDDEN, FRONT_HEADERS);

    // AND THE BARE CHOOSER IS NOT WORK, SO IT IS NOT CHARGED FOR. The lock
    // above is a SECOND lock, and it falls open when the header is absent -
    // Apple Mail, Outlook desktop and Safari before 16.4 send none - so the
    // HTML-mail vector above still reaches `GET /desk/auth/login` itself and
    // still spends the victim's ten hits from the victim's own address, and
    // the victim's first real click is 429 for a minute, renewably.
    //
    // The answer is that this page is not a cost. `GET /desk/auth/login` with
    // no `provider` lists the providers already held in memory: no bridge is
    // spawned, no provider is contacted, no file is read, no cookie is minted
    // and nothing is remembered. The three requests that DO work stay metered
    // - the provider redirect (discovery, a state cookie), the callback (a
    // token exchange and the bridge) and the logout - so the budget still
    // bounds everything it was written to bound.
    if (req.method === 'GET' && path === '/desk/auth/login' && !url.searchParams.has('provider')) {
      return authLogin(url, res);
    }

    if (!FRONT.limiter.hit(visitor, Date.now())) {
      return send(res, 429, TOO_MANY, Object.assign({}, FRONT_HEADERS, PLAIN, { 'retry-after': '60' }));
    }
    // One of the three, or `matched` would be false: GET is the only read
    // method left on these paths, because HEAD was refused above.
    if (path === '/desk/auth/login') return authLogin(url, res);
    if (path === '/desk/auth/callback') return authCallback(url, cookies, res);
    return authLogout(req, res);
  }

  // Past the auth block the method is a read: logoutPost is the only other
  // way through the check above, and its path returned inside that block.

  // IDENTITY IS THE COOKIE, AND THE REGISTRY SAYS WHOSE IT IS - EVERY TIME. No
  // login header is read on this listener, by any path, ever. A visitor
  // without a valid cookie is sent to the login page rather than refused,
  // because they are not refused - they have not said who they are yet.
  //
  // The cookie proves an identity a provider signed for; it does not prove a
  // principal, and it is not allowed to. So the same bridge the callback asked
  // is asked again here, with the same argument: nobody claims this identity
  // any more (rc 1), or two rows do (rc 65), and the session is over within
  // five seconds rather than at the cookie's expiry twelve hours later. Five
  // and not zero because the question costs a process per row - see
  // principalForIdentityCached, and the limiter just below, which is the
  // other half of the same bound.
  const identity = verifySession(FRONT.key, cookies.get(SESSION_COOKIE), nowSec());
  if (!identity) {
    return send(res, 303, '', Object.assign({}, FRONT_HEADERS, { location: '/desk/auth/login' }));
  }
  // THE BUDGET IS SPENT WHERE THE WORK IS, and past this line the work is a
  // bridge (or a memo of one), a snapshot read and a rendered page. A visitor
  // without a cookie never reaches here - they were redirected above, which
  // costs nothing - so this budget belongs to the people who are logged in,
  // one per visitor address, and a stolen cookie is worth no more of the
  // desk's time than the person it was stolen from has.
  if (!FRONT.cookieLimiter.hit(visitor, Date.now())) {
    return send(res, 429, TOO_MANY, Object.assign({}, FRONT_HEADERS, PLAIN, { 'retry-after': '60' }));
  }
  const { slug, outage } = principalForIdentityCached('oidc', identity.slice('oidc:'.length));
  if (outage) return send(res, 503, NO_MEASUREMENT, FRONT_HEADERS);
  if (!slug) {
    return send(res, 403, FORBIDDEN, Object.assign({}, FRONT_HEADERS, {
      'set-cookie': clearCookie(SESSION_COOKIE)
    }));
  }
  return servePage(req, res, slug, FRONT_HEADERS);
}

// frontServer - handleFront is async, and an unhandled rejection would take
// the whole desk down, tailnet listener included. So every throw that no
// branch above caught lands here as the ordinary 503, logged by its class.
function frontServer() {
  return http.createServer((req, res) => {
    handleFront(req, res).catch((e) => {
      console.error('desk front: request failed: ' + refusalReason(e));
      if (res.headersSent) res.end();
      else send(res, 503, NO_MEASUREMENT, FRONT_HEADERS);
    });
  });
}

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

// The front is a SECOND listener, never a replacement: the tailnet entrance
// above binds either way, and a bind failure here is the same rc 64 a bind
// failure there is.
let FRONT_SERVER = null;
if (FRONT) {
  FRONT_SERVER = frontServer();
  FRONT_SERVER.on('error', (e) => {
    console.error('desk: could not bind the front at ' + FRONT.listen.host + ':' + FRONT.listen.port +
      ': ' + (e && e.code ? e.code : e));
    process.exit(64);
  });
  FRONT_SERVER.listen(FRONT.listen.port, FRONT.listen.host, () => {
    console.error('desk: front listening on ' + FRONT.listen.host + ':' + FRONT.listen.port +
      ' for peer ' + FRONT.peer);
  });
}

for (const sig of ['SIGTERM', 'SIGINT']) {
  process.on(sig, () => {
    server.close();
    if (FRONT_SERVER) FRONT_SERVER.close();
    cleanUp();
    process.exit(0);
  });
}
