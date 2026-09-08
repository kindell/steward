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
