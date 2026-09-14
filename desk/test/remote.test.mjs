// desk/test/remote.test.mjs — reading the estates this desk consumes.
//
// TWO QUESTIONS, DELIBERATELY SEPARATE, because conflating them is how a fleet
// view lies:
//
//   Is the ESTATE readable?  ok | stale | unavailable, from meta.json and the
//                            snapshot's own age.
//   Does THIS VIEWER have rows there?  a file whose identity matches, or none.
//
// An estate that answers perfectly and holds nothing of yours is not a broken
// estate, and an estate that cannot be reached is not an empty one. A single
// "is there anything to show" flag would render both as the same blank space —
// which is the equivalence this product has already paid to learn twice.
//
// AND THE JOIN IS ON IDENTITY, NEVER ON THE FILE NAME. The remote generation is
// named by THAT estate's principal slugs, which this estate does not govern. A
// reader that opened `<my-slug>.json` over there would be trusting a stranger's
// spelling to decide whose sessions it is about.
import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdtempSync, mkdirSync, writeFileSync, symlinkSync, rmSync } from 'node:fs';
import { join } from 'node:path';
import os from 'node:os';
import { loadRemotes } from '../remote.mjs';

const NOW = Date.parse('2026-09-14T10:00:00Z');
const MAXAGE = 900;
const ME = ['tailscale:alice@example.invalid', 'oidc:issuer:107148'];

function fixture() {
  const dir = mkdtempSync(join(os.tmpdir(), 'desk-remote-'));
  return {
    dir,
    // estate(name, meta, files) — files is { '<slug>.json': <object> }
    estate(name, meta, files) {
      const r = join(dir, 'remote', name);
      mkdirSync(join(r, 'gen-1'), { recursive: true });
      if (meta !== null) writeFileSync(join(r, 'meta.json'), typeof meta === 'string' ? meta : JSON.stringify(meta));
      for (const [f, body] of Object.entries(files || {})) {
        writeFileSync(join(r, 'gen-1', f), typeof body === 'string' ? body : JSON.stringify(body));
      }
      symlinkSync('gen-1', join(r, 'current'));
      return this;
    },
    read(identity = ME) { return loadRemotes(dir, identity, { now: NOW, maxAgeSeconds: MAXAGE }); },
    done() { rmSync(dir, { recursive: true, force: true }); }
  };
}
const view = (viewer, identity, generatedAt, sessions = []) =>
  ({ schemaVersion: 1, host: 'h', generatedAt, registryRevision: 'abc1234',
     viewer, viewerIdentity: identity, readAll: false, entities: [], projects: [], sessions });

test('an estate that answered hands over the viewer matched by identity, not by name', () => {
  const f = fixture().estate('butler',
    { estate: 'butler', fetchedAt: '2026-09-14T09:59:00Z', status: 'ok' },
    { // THE SLUG OVER THERE IS NOT THE SLUG HERE. `alice-far` is this person on that
      // estate; a reader joining on the local slug would open alice.json and find
      // a different human.
      'alice-far.json': view('alice-far', ['tailscale:alice@example.invalid'], '2026-09-14T09:58:00Z', [{ id: 's-1' }]),
      'other.json': view('other', ['tailscale:bob@example.invalid'], '2026-09-14T09:58:00Z', [{ id: 's-2' }]),
      '_operator.json': view('_operator', [], '2026-09-14T09:58:00Z', [{ id: 's-1' }, { id: 's-2' }])
    });
  const [e] = f.read();
  assert.equal(e.estate, 'butler');
  assert.equal(e.status, 'ok');
  assert.equal(e.snap.viewer, 'alice-far');
  assert.equal(e.snap.sessions.length, 1);
  assert.equal(e.fetchedAt, '2026-09-14T09:59:00Z');
  f.done();
});

test('the operator file is never the match, because it names nobody', () => {
  // Its identity array is present and EMPTY. If an empty array counted as a
  // match, one request would hand a person the whole of another estate.
  const f = fixture().estate('butler',
    { estate: 'butler', fetchedAt: '2026-09-14T09:59:00Z', status: 'ok' },
    { '_operator.json': view('_operator', [], '2026-09-14T09:58:00Z', [{ id: 's-1' }]) });
  const [e] = f.read();
  assert.equal(e.status, 'ok');
  assert.equal(e.snap, null, 'no file is this viewer');
  f.done();
});

test('an estate with nothing of yours is ok and empty, not unavailable', () => {
  const f = fixture().estate('butler',
    { estate: 'butler', fetchedAt: '2026-09-14T09:59:00Z', status: 'ok' },
    { 'other.json': view('other', ['tailscale:bob@example.invalid'], '2026-09-14T09:58:00Z') });
  const [e] = f.read();
  assert.equal(e.status, 'ok');
  assert.equal(e.snap, null);
  assert.equal(e.reason, undefined, 'nothing went wrong, so nothing is explained');
  f.done();
});

test('meta says unavailable: the reason is carried through and no rows are shown', () => {
  const f = fixture().estate('butler',
    { estate: 'butler', fetchedAt: '2026-09-14T09:40:00Z', status: 'unavailable',
      reason: 'ssh: connect to host 10.0.0.9 port 22: Connection timed out' },
    { 'alice-far.json': view('alice-far', ME, '2026-09-14T09:00:00Z', [{ id: 's-1' }]) });
  const [e] = f.read();
  assert.equal(e.status, 'unavailable');
  assert.match(e.reason, /Connection timed out/);
  // THE STALE ROWS ARE ON DISK AND MUST NOT BE SHOWN. They are the last thing
  // that WAS true, and a page that renders them under a live heading is the
  // lie this whole seam exists to prevent.
  assert.equal(e.snap, null);
  f.done();
});

test('a producer too old to name identities makes the estate unavailable, not guessable', () => {
  // The field is ABSENT, not empty. During a rollout this is a real state, and
  // it must fail toward showing less - never toward matching on the slug.
  const old = view('alice-far', ME, '2026-09-14T09:58:00Z');
  delete old.viewerIdentity;
  const f = fixture().estate('butler',
    { estate: 'butler', fetchedAt: '2026-09-14T09:59:00Z', status: 'ok' },
    { 'alice-far.json': old });
  const [e] = f.read();
  assert.equal(e.status, 'unavailable');
  assert.match(e.reason, /identit/i);
  assert.equal(e.snap, null);
  f.done();
});

test('an old snapshot is stale: the rows are shown AND the age is', () => {
  const f = fixture().estate('butler',
    { estate: 'butler', fetchedAt: '2026-09-14T09:59:00Z', status: 'ok' },
    { 'alice-far.json': view('alice-far', ME, '2026-09-14T08:00:00Z', [{ id: 's-1' }]) });
  const [e] = f.read();
  assert.equal(e.status, 'stale');
  assert.equal(e.snap.sessions.length, 1, 'stale rows are still the best answer there is');
  assert.equal(e.ageSeconds, 7200);
  f.done();
});

test('a missing or malformed meta.json is unavailable, and says which', () => {
  let f = fixture().estate('a', null, { 'x.json': view('x', ME, '2026-09-14T09:58:00Z') });
  let [e] = f.read();
  assert.equal(e.status, 'unavailable');
  assert.match(e.reason, /meta/i);
  f.done();

  f = fixture().estate('a', '{not json', { 'x.json': view('x', ME, '2026-09-14T09:58:00Z') });
  [e] = f.read();
  assert.equal(e.status, 'unavailable');
  assert.match(e.reason, /meta/i);
  f.done();
});

test('a malformed viewer file does not take the estate down with it', () => {
  // ONE BAD FILE IS NOT A BAD ESTATE. The match is over every file; a colleague's
  // unreadable row must not hide yours, or one corrupt byte in somebody else's
  // file would blank the estate for everyone.
  const f = fixture().estate('butler',
    { estate: 'butler', fetchedAt: '2026-09-14T09:59:00Z', status: 'ok' },
    { 'broken.json': '{{{',
      'alice-far.json': view('alice-far', ME, '2026-09-14T09:58:00Z', [{ id: 's-1' }]) });
  const [e] = f.read();
  assert.equal(e.status, 'ok');
  assert.equal(e.snap.viewer, 'alice-far');
  f.done();
});

test('several estates come back sorted, and one failure does not hide another', () => {
  const f = fixture()
    .estate('skeppsbron', { estate: 'skeppsbron', fetchedAt: '2026-09-14T09:59:00Z', status: 'ok' },
            { 'j.json': view('j', ME, '2026-09-14T09:58:00Z', [{ id: 's-9' }]) })
    .estate('butler', { estate: 'butler', fetchedAt: '2026-09-14T09:30:00Z', status: 'unavailable', reason: 'refused' },
            { 'j.json': view('j', ME, '2026-09-14T09:00:00Z') });
  const got = f.read();
  assert.deepEqual(got.map((x) => x.estate), ['butler', 'skeppsbron']);
  assert.equal(got[0].status, 'unavailable');
  assert.equal(got[1].status, 'ok');
  f.done();
});

test('no remote directory at all is an empty list, not a throw', () => {
  const dir = mkdtempSync(join(os.tmpdir(), 'desk-remote-'));
  assert.deepEqual(loadRemotes(dir, ME, { now: NOW, maxAgeSeconds: MAXAGE }), []);
  rmSync(dir, { recursive: true, force: true });
});

test('a viewer with no identity of their own matches nothing, anywhere', () => {
  // A LOCAL PRINCIPAL WITH NO IDENTITY WORDS is a row nobody has finished
  // writing. It must not become a wildcard that matches every empty array on
  // every estate.
  const f = fixture().estate('butler',
    { estate: 'butler', fetchedAt: '2026-09-14T09:59:00Z', status: 'ok' },
    { '_operator.json': view('_operator', [], '2026-09-14T09:58:00Z'),
      'alice-far.json': view('alice-far', ME, '2026-09-14T09:58:00Z') });
  const [e] = f.read([]);
  assert.equal(e.status, 'ok');
  assert.equal(e.snap, null);
  f.done();
});
