// desk/test/render.test.mjs - the pages are pure functions of one snapshot.
//
// RENDERING IS WHERE A READ-ONLY VIEW STOPS BEING READ-ONLY IF IT IS SLOPPY.
// Two properties are asserted over and over here because they are the whole
// safety argument: every value that reaches the page went through escapeHtml,
// and no key outside desk/SCHEMA.md's contract is ever read. The fixture
// therefore carries an `extra` key with a sentinel in it - a page that
// stringifies a row instead of destructuring it prints the sentinel and fails.
import test from 'node:test';
import assert from 'node:assert/strict';
import { escapeHtml, pageIndex, pageTeam, pageProject, pageSession } from '../render.mjs';

const snap = {
  schemaVersion: 1,
  host: 'h1',
  generatedAt: '2026-09-08T00:00:00Z',
  registryRevision: 'abc1234',
  viewer: 'b',
  readAll: false,
  entities: [
    { id: 'team', name: 'Te<am>', managedBy: null, members: ['a', 'b'], member: true },
    { id: 'e1', name: 'Other', managedBy: 'team', members: ['c'], member: false }
  ],
  projects: [
    { id: 'work', name: 'Work', parent: 'team' },
    { id: 'idle', name: 'Idle', parent: 'e1' }
  ],
  sessions: [
    {
      id: 's-1', slug: 'work-a', label: 'Wo"rk', owner: 'a', mine: false,
      domain: 'team', project: 'work', runtime: 'codex', host: 'h1', repo: 'repo',
      liveness: { state: 'running', measuredAt: '2026-09-08T00:00:00Z', ageSeconds: 60 },
      mcp: [{ id: 'shared', name: 'shared', axis: 'entity', source: 'team' }],
      extra: '<script>SENTINEL</script>'
    },
    {
      id: 's-2', slug: 'team-b', label: 'Mine', owner: 'b', mine: true,
      domain: 'team', project: null, runtime: 'claude-code', host: 'h1', repo: 'repo',
      liveness: { state: 'unknown', measuredAt: '2026-09-08T00:00:00Z', ageSeconds: null },
      mcp: []
    },
    {
      id: 's-3', slug: 'team-c', label: 'Idle One', owner: 'c', mine: false,
      domain: 'team', project: null, runtime: 'codex', host: 'h1', repo: 'repo',
      liveness: { state: 'not-running', measuredAt: '2026-09-08T00:00:00Z', ageSeconds: 300 },
      mcp: []
    }
  ]
};

const allPages = () => [
  pageIndex(snap),
  pageTeam(snap, 'team'),
  pageProject(snap, 'work'),
  pageSession(snap, 's-1'),
  pageSession(snap, 's-2')
];

test('escapeHtml replaces all five', () => {
  assert.equal(escapeHtml('&<>"\''), '&amp;&lt;&gt;&quot;&#39;');
});

test('escapeHtml survives a non-string', () => {
  assert.equal(escapeHtml(null), '');
  assert.equal(escapeHtml(undefined), '');
  assert.equal(escapeHtml(60), '60');
});

test('every value is escaped', () => {
  const h = pageIndex(snap);
  assert.ok(h.includes('Te&lt;am&gt;'));
  assert.ok(!h.includes('<am>'));
});

test('an unknown key never renders', () => {
  assert.ok(!pageSession(snap, 's-1').includes('SENTINEL'));
});

test('unknown ids are null, not a page', () => {
  assert.equal(pageSession(snap, 's-9'), null);
  assert.equal(pageTeam(snap, 'x'), null);
  assert.equal(pageProject(snap, 'x'), null);
});

test('the session page names axis, never a command', () => {
  const h = pageSession(snap, 's-1');
  assert.ok(h.includes('entity'));
  assert.ok(!h.includes('/usr/bin'));
});

test('no script tag is ever emitted', () => {
  for (const h of allPages()) assert.ok(!/<script/i.test(h));
});

test('every page is a document with one title', () => {
  for (const h of allPages()) {
    assert.ok(h.startsWith('<!doctype html>'));
    assert.ok(h.includes('<meta charset="utf-8">'));
    assert.ok(h.includes('<title>Steward Desk</title>'));
  }
});

test('the footer names the measurement, not the reading', () => {
  for (const h of allPages()) {
    assert.ok(h.includes('measured at 2026-09-08T00:00:00Z on h1'), h.slice(-200));
  }
});

test('no link leaves the desk prefix', () => {
  for (const h of allPages()) {
    for (const m of h.matchAll(/href="([^"]*)"/g)) {
      assert.ok(m[1].startsWith('/desk/'), 'link outside the prefix: ' + m[1]);
    }
  }
});

test('the index names the teams, the projects and the sessions', () => {
  const h = pageIndex(snap);
  assert.ok(h.includes('/desk/team/team'));
  assert.ok(h.includes('/desk/project/work'));
  assert.ok(h.includes('/desk/session/s-1'));
  assert.ok(h.includes('work-a'));
});

test('the index marks membership and ownership', () => {
  const h = pageIndex(snap);
  assert.ok(h.includes('member'));
  assert.ok(h.includes('mine'));
});

test('the team page carries its members, its projects and its sessions', () => {
  const h = pageTeam(snap, 'team');
  assert.ok(h.includes('Te&lt;am&gt;'));
  assert.ok(h.includes('/desk/project/work'));
  assert.ok(h.includes('/desk/session/s-1'));
  assert.ok(!h.includes('/desk/project/idle'));
});

test('the project page carries only its own sessions', () => {
  const h = pageProject(snap, 'work');
  assert.ok(h.includes('/desk/session/s-1'));
  assert.ok(!h.includes('/desk/session/s-2'));
});

test('a null age reads unknown, never null', () => {
  const h = pageSession(snap, 's-2');
  assert.ok(h.includes('unknown'));
  assert.ok(!h.includes('null'));
});

// T3's contract names three liveness states (running, unknown, not-running);
// the other fixtures only ever exercise the first two, so this one session
// carries the third and both places that show liveness are checked.
test('a not-running session renders its own state, on its own page and on the index', () => {
  const page = pageSession(snap, 's-3');
  assert.ok(page.includes('not-running'));
  const index = pageIndex(snap);
  assert.ok(index.includes('not-running'));
});

test('the session page renders the mcp table by id, axis and source', () => {
  const h = pageSession(snap, 's-1');
  assert.ok(h.includes('<table'));
  assert.ok(h.includes('shared'));
  assert.ok(h.includes('team'));
});

test('a quote in a label cannot break out of an attribute', () => {
  const h = pageSession(snap, 's-1');
  assert.ok(h.includes('Wo&quot;rk'));
  assert.ok(!h.includes('Wo"rk'));
});

test('an empty snapshot still renders a page', () => {
  const empty = { schemaVersion: 1, host: 'h1', generatedAt: '2026-09-08T00:00:00Z', viewer: 'c', readAll: false, entities: [], projects: [], sessions: [] };
  const h = pageIndex(empty);
  assert.ok(h.includes('<title>Steward Desk</title>'));
  assert.equal(pageSession(empty, 's-1'), null);
});

test('missing arrays are not a crash', () => {
  const bare = { schemaVersion: 1, host: 'h1', generatedAt: '2026-09-08T00:00:00Z', viewer: 'c', readAll: false };
  assert.ok(pageIndex(bare).includes('<title>Steward Desk</title>'));
  assert.equal(pageTeam(bare, 'team'), null);
});
