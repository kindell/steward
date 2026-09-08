// desk/front.mjs - the rules of the public front's listener.
//
// The front is a second listener on the host's tailnet address that exactly
// one peer, the public proxy box, may reach (the tailnet ACL lets only the
// box's tag at the port; this module refuses every other peer a second time).
// The box terminates TLS and forwards the visitor's address as x-real-ip;
// that header is believed only when the TCP peer is the box, because the box
// is the only thing that can reach the port at all. Nothing here reads a
// login header or a cookie: identity is serve.mjs's business.

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
// carries the /10: 64..127.
export function isCgnat(addr) {
  const m = String(addr).match(/^100\.(\d{1,3})\.\d{1,3}\.\d{1,3}$/);
  if (!m) return false;
  const second = Number(m[1]);
  return second >= 64 && second <= 127;
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
// when it reported nothing. Only the FIRST x-real-ip entry counts: the box
// writes exactly one, and anything after a comma came from the visitor.
export function visitorAddress(req, peer) {
  const remote = normalizeAddr(req.socket && req.socket.remoteAddress);
  if (remote !== peer) return null;
  const hdr = req.headers['x-real-ip'];
  if (typeof hdr !== 'string' || hdr.trim() === '') return peer;
  return normalizeAddr(hdr.split(',')[0]);
}

// RateLimiter - a trailing window per key, in memory. The desk is one process
// on one host, so a map is the whole store; keys idle for a window are pruned
// on every call so a scan of the internet does not grow it without bound.
export class RateLimiter {
  constructor(limit, windowMs) {
    this.limit = limit;
    this.windowMs = windowMs;
    this.hits = new Map();
  }
  hit(key, now) {
    const floor = now - this.windowMs;
    for (const [k, times] of this.hits) {
      const kept = times.filter((t) => t > floor);
      if (kept.length === 0) this.hits.delete(k); else this.hits.set(k, kept);
    }
    const times = this.hits.get(key) || [];
    if (times.length >= this.limit) return false;
    times.push(now);
    this.hits.set(key, times);
    return true;
  }
}
