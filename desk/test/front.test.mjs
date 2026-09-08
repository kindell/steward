import { test } from 'node:test';
import assert from 'node:assert/strict';
import { normalizeAddr, isCgnat, isLoopback, parseFrontListen, parseFrontPeer, visitorAddress, RateLimiter } from '../front.mjs';

test('normalizeAddr strips brackets, ports, zones and the v4-in-v6 prefix', () => {
  assert.equal(normalizeAddr('[::1]:443'), '::1');
  assert.equal(normalizeAddr('127.0.0.1:8080'), '127.0.0.1');
  assert.equal(normalizeAddr('::ffff:100.64.0.9'), '100.64.0.9');
  assert.equal(normalizeAddr('FE80::1%eth0'), 'fe80::1');
});

test('normalizeAddr matches the original serve.mjs behaviour exactly', () => {
  assert.equal(normalizeAddr('::ffff:'), '');
  assert.equal(normalizeAddr('example.com:8080'), 'example.com');
  assert.equal(normalizeAddr('fe80::1:443'), 'fe80::1:443');
});

test('isCgnat is exactly 100.64.0.0/10', () => {
  assert.equal(isCgnat('100.64.0.0'), true);
  assert.equal(isCgnat('100.127.255.255'), true);
  assert.equal(isCgnat('100.128.0.0'), false);
  assert.equal(isCgnat('100.63.255.255'), false);
  assert.equal(isCgnat('10.0.0.1'), false);
  assert.equal(isCgnat('::1'), false);
  // Three digits is not the same as an octet.
  assert.equal(isCgnat('100.64.999.999'), false);
  assert.equal(isCgnat('100.64.0.256'), false);
  assert.equal(isCgnat('100.256.0.1'), false);
  assert.equal(isCgnat('999.64.0.1'), false);
});

// AN OCTET HAS ONE SPELLING. A padded octet passes a range check and is not
// the address the kernel will report: `100.064.0.1` is kept verbatim by
// parseFrontPeer, the socket layer says `100.64.0.1`, the two never compare
// equal, and every visitor is told they are not the front peer - for ever,
// from a setting that reads as correct. It has to fail where it is written.
test('a padded octet is not an address, in the range check or in either setting', () => {
  for (const padded of ['100.064.0.1', '100.64.00.1', '0100.64.0.1', '100.64.0.01']) {
    assert.equal(isCgnat(padded), false, padded);
    assert.throws(() => parseFrontPeer(padded), /^Error: STEWARD_DESK_FRONT_PEER/, padded);
    assert.throws(() => parseFrontListen(padded + ':8443'), /^Error: STEWARD_DESK_FRONT_LISTEN/, padded);
  }
  // The canonical spelling of the same address is still accepted, so the
  // check refuses the padding and not the address.
  assert.equal(isCgnat('100.64.0.1'), true);
  assert.equal(parseFrontPeer('100.64.0.1'), '100.64.0.1');
});

test('isLoopback accepts the two literal spellings only', () => {
  assert.equal(isLoopback('127.0.0.1'), true);
  assert.equal(isLoopback('::1'), true);
  assert.equal(isLoopback('localhost'), false);
  assert.equal(isLoopback('127.0.0.2'), false);
});

test('parseFrontListen accepts CGNAT and loopback with a canonical port', () => {
  assert.deepEqual(parseFrontListen('100.64.0.1:8443'), { host: '100.64.0.1', port: 8443 });
  assert.deepEqual(parseFrontListen('127.0.0.1:18443'), { host: '127.0.0.1', port: 18443 });
  assert.deepEqual(parseFrontListen('[::1]:18443'), { host: '::1', port: 18443 });
});

test('parseFrontListen refuses any other bind', () => {
  for (const raw of ['0.0.0.0:8443', '[::]:8443', '10.0.0.5:8443', 'localhost:8443', '100.64.0.1', '100.64.0.1:0', '100.64.0.1:08443', '100.64.0.1:70000']) {
    assert.throws(() => parseFrontListen(raw), /^Error: STEWARD_DESK_FRONT_LISTEN/, raw);
  }
});

test('parseFrontPeer normalizes and refuses a non-tailnet peer', () => {
  assert.equal(parseFrontPeer('100.98.0.8'), '100.98.0.8');
  assert.equal(parseFrontPeer('::ffff:127.0.0.1'), '127.0.0.1');
  assert.throws(() => parseFrontPeer('203.0.113.7'), /^Error: STEWARD_DESK_FRONT_PEER/);
  assert.throws(() => parseFrontPeer(''), /^Error: STEWARD_DESK_FRONT_PEER/);
});

const fakeReq = (remote, realIp) => ({ socket: { remoteAddress: remote }, headers: realIp === undefined ? {} : { 'x-real-ip': realIp } });

test('visitorAddress trusts x-real-ip only from the configured peer, and only as one IP literal', () => {
  assert.equal(visitorAddress(fakeReq('100.98.0.8', '203.0.113.9'), '100.98.0.8'), '203.0.113.9');
  assert.equal(visitorAddress(fakeReq('::ffff:100.98.0.8', '[2001:db8::9]:443'), '100.98.0.8'), '2001:db8::9');
  // A list is not what the box writes, so it is not believed at all: the
  // budget falls back to the box rather than keying on a visitor-chosen half.
  assert.equal(visitorAddress(fakeReq('100.98.0.8', '203.0.113.9, 10.0.0.1'), '100.98.0.8'), '100.98.0.8');
  // Neither is anything that is not an address.
  assert.equal(visitorAddress(fakeReq('100.98.0.8', 'example.test'), '100.98.0.8'), '100.98.0.8');
  assert.equal(visitorAddress(fakeReq('100.98.0.8', '999.1.1.1'), '100.98.0.8'), '100.98.0.8');
  assert.equal(visitorAddress(fakeReq('100.98.0.8', '../../etc/passwd'), '100.98.0.8'), '100.98.0.8');
  assert.equal(visitorAddress(fakeReq('100.98.0.8'), '100.98.0.8'), '100.98.0.8');
  assert.equal(visitorAddress(fakeReq('100.98.0.9', '203.0.113.9'), '100.98.0.8'), null);
});

test('RateLimiter allows limit hits per window and forgets old ones', () => {
  const rl = new RateLimiter(3, 60000);
  assert.equal(rl.hit('a', 1000), true);
  assert.equal(rl.hit('a', 2000), true);
  assert.equal(rl.hit('a', 3000), true);
  assert.equal(rl.hit('a', 4000), false);
  assert.equal(rl.hit('b', 4000), true);
  assert.equal(rl.hit('a', 61001), true);
});

test('RateLimiter refuses a new key at the cap and keeps serving the keys it holds', () => {
  const rl = new RateLimiter(3, 60000, 2);
  assert.equal(rl.hit('a', 1000), true);
  assert.equal(rl.hit('b', 1000), true);
  assert.equal(rl.hits.size, 2);
  // The map is full: a third address is refused rather than admitted, and
  // the map does not grow by refusing it.
  assert.equal(rl.hit('c', 1000), false);
  assert.equal(rl.hits.size, 2);
  // The two keys already in the map still have their own budgets.
  assert.equal(rl.hit('a', 1100), true);
  assert.equal(rl.hit('b', 1100), true);
});

test('RateLimiter frees room again once a window has passed', () => {
  const rl = new RateLimiter(3, 60000, 2);
  assert.equal(rl.hit('a', 1000), true);
  assert.equal(rl.hit('b', 1000), true);
  assert.equal(rl.hit('c', 1000), false);
  // A full window later a and b are stale, so the prune that runs when the
  // map is at the cap empties it and the new key is admitted.
  assert.equal(rl.hit('c', 61001), true);
  assert.equal(rl.hits.has('a'), false);
  assert.equal(rl.hits.has('b'), false);
});

// A FULL MAP MUST NOT SWEEP ITSELF ON EVERY CALL. The sweep walks the whole
// map, so a cap that triggers one per call makes every request cost the map -
// the amortization undone at exactly the moment it matters, since a full map
// is when a sweep is most expensive and a flood of fresh keys is what fills
// it. Only the sweep count shows it: the return values are the same either
// way, which is why this test counts rather than measures.
test('RateLimiter sweeps a full map at most once per window', () => {
  class Counting extends RateLimiter {
    constructor(...a) { super(...a); this.prunes = 0; }
    prune(now) { this.prunes++; super.prune(now); }
  }
  const rl = new Counting(10, 60000, 50);
  for (let i = 0; i < 50; i++) assert.equal(rl.hit('k' + i, 1000), true);
  assert.equal(rl.hits.size, 50);
  const before = rl.prunes;
  // Two hundred calls with a full map, all inside one window: each new key is
  // refused, and refusing it costs no sweep.
  for (let i = 0; i < 200; i++) assert.equal(rl.hit('new' + i, 1001 + i), false);
  assert.ok(rl.prunes - before <= 1, 'a full map was swept ' + (rl.prunes - before) + ' times inside one window');
  assert.equal(rl.hits.size, 50);
  // A key already in the map still has its own budget while the map is full.
  assert.equal(rl.hit('k0', 1300), true);
  // A window later the sweep is due again, and the room comes back with it.
  assert.equal(rl.hit('new-late', 62000), true);
  assert.equal(rl.prunes - before, 2);
});

test('RateLimiter counts only the trailing window even when no prune has swept', () => {
  // The prune runs every 256th call, so between sweeps a key's own list can
  // hold entries older than the window; the count must not include them.
  const rl = new RateLimiter(2, 60000);
  assert.equal(rl.hit('a', 1000), true);
  assert.equal(rl.hit('a', 2000), true);
  assert.equal(rl.hit('a', 3000), false);
  assert.equal(rl.hit('a', 62001), true);
  assert.equal(rl.hit('a', 62002), true);
  assert.equal(rl.hit('a', 62003), false);
});

// A SWEEP THAT FREES NOTHING MUST NOT BUY A WHOLE WINDOW OF SILENCE. The
// sweep keeps every entry up to a window old, so entries it kept go stale
// moments after it ran; dating the sweep `now` made the map wait a second
// window before looking again, and in that gap a map of nothing but dead
// entries refuses every new visitor. Measured at the deployed settings: 59
// seconds of 429 for anybody who had not been seen before.
test('a sweep that keeps everything is due again when its oldest entry goes stale', () => {
  const rl = new RateLimiter(10, 60000, 10);
  for (let i = 0; i < 10; i++) assert.equal(rl.hit('k' + i, 0), true);
  // Just short of a window: the sweep runs, keeps all ten, and the new key is
  // refused because the map is full - which is the documented trade.
  assert.equal(rl.hit('flood', 59000), false);
  assert.equal(rl.hits.size, 10);
  // A second past the window every one of those ten is stale, so the sweep is
  // due on the entries' clock and not on the sweep's own.
  assert.equal(rl.hit('new-visitor', 60001), true,
    'a map holding nothing but dead entries must not refuse a live visitor');
  assert.equal(rl.hits.size, 1);
});
