// desk/front.mjs - the rules of the public front's listener.
//
// The front is a second listener on the host's tailnet address that exactly
// one peer, the public proxy box, may reach (the tailnet ACL lets only the
// box's tag at the port; this module refuses every other peer a second time).
// The box terminates TLS and forwards the visitor's address as x-real-ip;
// that header is believed only when the TCP peer is the box, because the box
// is the only thing that can reach the port at all. Nothing here reads a
// login header or a cookie: identity is serve.mjs's business.

import { isIP } from 'node:net';

// normalizeAddr - one spelling per address, so a set lookup or an equality is
// a real comparison: brackets and an IPv4 port stripped, an IPv6 zone
// stripped, the ::ffff: prefix of an IPv4-mapped address stripped, lowercased.
export function normalizeAddr(raw) {
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

// isCgnat - 100.64.0.0/10: the tailnet's own address range. The second octet
// carries the /10: 64..127. EVERY OCTET IS RANGE-CHECKED, not merely counted
// in digits: an octet spelled `999` is three digits and is not a value, and a
// check that says yes to it says yes about something the rest of this file
// will then compare, bind or log.
//
// AND AN OCTET MUST BE SPELLED THE ONE WAY THE KERNEL SPELLS IT. A numeric
// range check alone says yes to a zero-padded octet such as `064`, and
// parseFrontPeer then keeps that string verbatim while the socket layer
// reports the same peer with the octet spelled `64` - so the two never compare
// equal, visitorAddress returns null for every visitor, and the whole front
// answers "Forbidden: not the front peer" for ever, one log line a minute,
// from a setting that looks right.
// node:net's own parser refuses the padded form too (isIP returns 0), and it
// is the parser the rest of this file already trusts.
export function isCgnat(addr) {
  const s = String(addr);
  if (isIP(s) !== 4) return false;
  const octets = s.split('.').map(Number);
  return octets[0] === 100 && octets[1] >= 64 && octets[1] <= 127;
}

export function isLoopback(addr) {
  return addr === '127.0.0.1' || addr === '::1';
}

function splitHostPort(raw) {
  const s = String(raw);
  const br = s.match(/^\[([^\]]+)\]:(.*)$/);
  if (br) return [br[1], br[2]];
  const i = s.lastIndexOf(':');
  if (i === -1) return [s, ''];
  return [s.slice(0, i), s.slice(i + 1)];
}

// parseFrontListen - STEWARD_DESK_FRONT_LISTEN as `<addr>:<port>`. The address
// must be the tailnet's (CGNAT) or loopback (harmless: reaches nobody off the
// host; the test suite lives there). 0.0.0.0 and :: are refused by name in
// the message because they are the mistake this check exists for. The port is
// an integer written once and canonically, never 0.
export function parseFrontListen(raw) {
  const [hostRaw, portRaw] = splitHostPort(raw);
  const host = normalizeAddr(hostRaw);
  if (!(isCgnat(host) || isLoopback(host))) {
    throw new Error('STEWARD_DESK_FRONT_LISTEN must name a tailnet (100.64.0.0/10) or loopback address, never 0.0.0.0 or ::, got ' + JSON.stringify(raw));
  }
  const port = Number(portRaw);
  if (!/^[0-9]+$/.test(portRaw) || port < 1 || port > 65535 || portRaw !== String(port)) {
    throw new Error('STEWARD_DESK_FRONT_LISTEN port must be an integer from 1 to 65535, got ' + JSON.stringify(raw));
  }
  return { host, port };
}

// parseFrontPeer - the one address allowed to connect: the proxy box's tailnet
// address (or loopback, in the test suite).
export function parseFrontPeer(raw) {
  const peer = normalizeAddr(raw);
  if (!(isCgnat(peer) || isLoopback(peer))) {
    throw new Error('STEWARD_DESK_FRONT_PEER must be the proxy box\'s tailnet (100.64.0.0/10) or loopback address, got ' + JSON.stringify(raw));
  }
  return peer;
}

// visitorAddress - null when the socket peer is not the box (the caller must
// refuse); otherwise the visitor as the box reported it, or the box itself
// when it reported nothing believable.
//
// X-REAL-IP IS BELIEVED ONLY AS A SINGLE WELL-FORMED IP LITERAL. The box
// overwrites the header with the connection's own remote address (Caddy
// `header_up X-Real-IP {remote_host}`, nginx `proxy_set_header X-Real-IP
// $remote_addr;`), so exactly one address arrives and it is an address. A
// comma means a list, which this header never is when the box sets it, and
// anything net.isIP does not recognise is not an address at all. Either way
// the value is dropped and the budget keys on the box - a visitor who sends
// junk shares one bucket rather than minting a fresh one per request.
export function visitorAddress(req, peer) {
  const remote = normalizeAddr(req.socket && req.socket.remoteAddress);
  if (remote !== peer) return null;
  const hdr = req.headers['x-real-ip'];
  if (typeof hdr !== 'string' || hdr.trim() === '') return peer;
  if (hdr.includes(',')) return peer;
  const v = normalizeAddr(hdr);
  return isIP(v) === 0 ? peer : v;
}

// RateLimiter - a trailing window per key, in memory. The desk is one process
// on one host, so a map is the whole store.
//
// THE MAP IS BOUNDED AND THE PRUNE IS AMORTIZED, because both the size and
// the cost are things a stranger can drive. A scan from many addresses would
// otherwise grow the map without limit; pruning every key on every call would
// otherwise make each request cost the whole map, so a big map makes the next
// request more expensive, which is the wrong direction under load.
//
// The cap: when the map is full and the key is new, hit() returns false and
// the map does not grow - the caller 429s. That is a deliberate trade. Under
// a flood of fresh keys a genuine new visitor can be refused while the flood
// occupies the map, but every key already in the map keeps its own budget,
// and a full window later the prune frees room again. An unbounded map is
// the worse failure: it never comes back.
//
// THE SWEEP IS RATED BY TIME, NOT BY FULLNESS. Sweeping because the map is
// full means sweeping on every call once it is, which is the amortization
// undone at exactly the moment it matters: a full map is when a sweep costs
// most and a flood is what fills it. Measured at the deployed settings, a
// per-call sweep of a full map cost 0.47 ms of synchronous work per request
// against 0.0002 ms with room to spare - and both listeners live in one
// process, so that time is the operator's desk too.
const PRUNE_EVERY = 256;
export class RateLimiter {
  constructor(limit, windowMs, maxKeys = 10000) {
    this.limit = limit;
    this.windowMs = windowMs;
    this.maxKeys = maxKeys;
    this.hits = new Map();
    this.sincePrune = 0;
    this.lastPrune = -Infinity;
  }
  // THE SWEEP DATES ITSELF BY WHAT IT KEPT, NOT BY WHEN IT RAN. A sweep keeps
  // every entry up to a window old, so when it leaves the map at the cap the
  // next one is due as soon as the OLDEST SURVIVOR goes stale - which is
  // sooner than a window from now, and is the first moment there is anything
  // to free. Dating it `now` instead made a full map wait a whole window past
  // a sweep that freed nothing: measured with RateLimiter(10, 60000, 10000) a
  // flood filled the map at t=0, the sweep at t=59000 kept all of it, and a
  // new legitimate visitor was refused from t=60001 until t=119001 - 59
  // seconds of 429 against a map holding nothing but dead entries.
  prune(now) {
    const floor = now - this.windowMs;
    let oldest = Infinity;
    for (const [k, times] of this.hits) {
      const kept = times.filter((t) => t > floor);
      if (kept.length === 0) {
        this.hits.delete(k);
      } else {
        this.hits.set(k, kept);
        if (kept[0] < oldest) oldest = kept[0]; // a key's list is in arrival order
      }
    }
    this.sincePrune = 0;
    this.lastPrune = this.hits.size >= this.maxKeys && oldest !== Infinity ? oldest : now;
  }
  hit(key, now) {
    // Every 256th call, and at the cap at most once per window - so the sweep
    // is amortized in the ordinary case and a full map costs one sweep per
    // window rather than one per request. A FULL MAP WHOSE SWEEP IS NOT DUE
    // REFUSES A NEW KEY WITHOUT SWEEPING: the previous sweep dated itself by
    // the oldest entry it kept, so the sweep falls due exactly when that entry
    // goes stale and there is room to free - and until then a sweep really
    // would free nothing and only spend the whole map on this one request.
    if (++this.sincePrune >= PRUNE_EVERY ||
        (this.hits.size >= this.maxKeys && now - this.lastPrune >= this.windowMs)) this.prune(now);
    const floor = now - this.windowMs;
    // Between prunes this key's own list can hold entries older than the
    // window, so the window is applied here too: the trailing-window count is
    // never the sweep's leftovers.
    const times = (this.hits.get(key) || []).filter((t) => t > floor);
    if (times.length >= this.limit) {
      this.hits.set(key, times);
      return false;
    }
    if (!this.hits.has(key) && this.hits.size >= this.maxKeys) return false;
    times.push(now);
    this.hits.set(key, times);
    return true;
  }
}
