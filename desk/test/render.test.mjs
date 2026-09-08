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
import { escapeHtml, formatAge, pageIndex, pageTeam, pageProject, pageSession } from '../render.mjs';

// between/count - the two ways a NESTED list is asserted from the outside. A
// tree that had collapsed back into four sibling lists would still contain
// every link, in the right order; what tells the two apart is whether a new
// <ul> opens between a parent's link and its child's.
const between = (h, a, b) => h.slice(h.indexOf(a), h.indexOf(b));
const count = (h, s) => h.split(s).length - 1;

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

// THE ICON IS THE ONE HREF THAT IS NOT A PATH, and it is named here by its
// exact value rather than waved through as a scheme: `data:,` fetches
// nothing, from nobody, ever. A second off-prefix link - a real data: image,
// a CDN, an avatar - still fails this test, which is the point of listing the
// exception instead of loosening the rule to "or a data: URL".
const ICON_HREF = 'data:,';

// AND EVERY PAGE NAMES ITS OWN ICON. Without this line the browser asks for
// /favicon.ico by itself, with the session cookie on it, so one page view
// costs two of the front's per-address rate-limit hits instead of one. The
// href is empty on purpose: a declared icon the browser never fetches.
test('every page declares an icon, so no page view costs a second request', () => {
  for (const h of allPages()) {
    assert.ok(h.includes('<link rel="icon" href="' + ICON_HREF + '">'), h.slice(0, 200));
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
      if (m[1] === ICON_HREF) continue;
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

// THE TEAM PAGE IS THE SAME TREE, ROOTED HERE. It used to list this entity's
// own projects and sessions and nothing else, which made a managed entity's
// work unreachable from the page of the team that manages it - the same
// half-answer the filter's one-rule fix removed on the data side. `idle` hangs
// under `e1`, which `team` manages, so it belongs on this page ONE LEVEL DOWN,
// inside e1's list, and never as a project of `team` itself.
test('the team page carries its members and the tree rooted at it', () => {
  const h = pageTeam(snap, 'team');
  assert.ok(h.includes('Te&lt;am&gt;'));
  assert.ok(h.includes('/desk/project/work'));
  assert.ok(h.includes('/desk/session/s-1'));
  assert.ok(h.indexOf('/desk/team/e1') < h.indexOf('/desk/project/idle'));
  assert.ok(between(h, '/desk/team/e1', '/desk/project/idle').includes('<ul>'));
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

// ---------------------------------------------------------------------------
// THE INDEX IS A TREE. Lists per kind answered "what rows are in my file"; the
// question a reader arrives with is "who is doing what for whom", and that is
// team > client > project > session, one shape, on one page.

const G = '2026-09-08T00:00:00Z';
const sess = (id, slug, over) => Object.assign({
  id, slug, label: slug, owner: 'a', mine: false, domain: null, project: null,
  runtime: 'codex', host: 'h1', repo: 'repo',
  liveness: { state: 'running', measuredAt: G, ageSeconds: 360 }, mcp: []
}, over || {});
const doc = (over) => Object.assign({
  schemaVersion: 1, host: 'h1', generatedAt: G, viewer: 'b', readAll: false,
  entities: [], projects: [], sessions: []
}, over);

const deep = doc({
  entities: [
    { id: 'team', name: 'Team', managedBy: null, members: ['b'], member: true },
    { id: 'client', name: 'Client', managedBy: 'team', members: [], member: false }
  ],
  projects: [{ id: 'work', name: 'Work', parent: 'client' }],
  sessions: [sess('s-1', 'work-a', { domain: 'client', project: 'work' })]
});

test('the index nests team, client, project, session in that order', () => {
  const h = pageIndex(deep);
  assert.ok(h.indexOf('/desk/team/team') < h.indexOf('/desk/team/client'));
  assert.ok(h.indexOf('/desk/team/client') < h.indexOf('/desk/project/work'));
  assert.ok(h.indexOf('/desk/project/work') < h.indexOf('/desk/session/s-1'));
  assert.ok(between(h, '/desk/team/team', '/desk/team/client').includes('<ul>'));
  assert.ok(between(h, '/desk/team/client', '/desk/project/work').includes('<ul>'));
  assert.ok(between(h, '/desk/project/work', '/desk/session/s-1').includes('<ul>'));
});

test('a team with no client in between still nests project and session', () => {
  const h = pageIndex(doc({
    entities: [{ id: 'team', name: 'Team', managedBy: null, members: ['b'], member: true }],
    projects: [{ id: 'work', name: 'Work', parent: 'team' }],
    sessions: [sess('s-1', 'work-a', { domain: 'team', project: 'work' })]
  }));
  assert.ok(h.indexOf('/desk/team/team') < h.indexOf('/desk/project/work'));
  assert.ok(h.indexOf('/desk/project/work') < h.indexOf('/desk/session/s-1'));
  assert.ok(between(h, '/desk/team/team', '/desk/project/work').includes('<ul>'));
  assert.ok(between(h, '/desk/project/work', '/desk/session/s-1').includes('<ul>'));
});

test('a session with no project sits under its entity, not inside a project', () => {
  const h = pageIndex(doc({
    entities: [{ id: 'team', name: 'Team', managedBy: null, members: ['b'], member: true }],
    projects: [{ id: 'work', name: 'Work', parent: 'team' }],
    sessions: [
      sess('s-1', 'work-a', { domain: 'team', project: 'work' }),
      sess('s-2', 'team-b', { domain: 'team' })
    ]
  }));
  assert.ok(h.indexOf('/desk/session/s-1') < h.indexOf('/desk/session/s-2'));
  // the project's own list has closed again before the project-less session
  assert.ok(between(h, '/desk/session/s-1', '/desk/session/s-2').includes('</ul>'));
});

test('an entity with nothing under it is still a node', () => {
  const h = pageIndex(doc({
    entities: [{ id: 'e2', name: 'E2', managedBy: null, members: ['b'], member: true }]
  }));
  assert.ok(h.includes('/desk/team/e2'));
});

// A CYCLE IS A REGISTRY FAULT, NOT A REASON TO HANG. Neither entity is a root
// (each has a manager that is present), so the walk has to reach them anyway,
// once each, without recursing through the loop forever.
test('a managedBy cycle terminates and each entity appears once', () => {
  const h = pageIndex(doc({
    entities: [
      { id: 'e1', name: 'E1', managedBy: 'e2', members: ['b'], member: true },
      { id: 'e2', name: 'E2', managedBy: 'e1', members: ['b'], member: true }
    ]
  }));
  assert.equal(count(h, '/desk/team/e1'), 1);
  assert.equal(count(h, '/desk/team/e2'), 1);
});

test('every entity in the snapshot appears exactly once in the index', () => {
  const h = pageIndex(snap);
  assert.equal(count(h, '/desk/team/team'), 1);
  assert.equal(count(h, '/desk/team/e1'), 1);
});

// NOTHING IN THE FILE IS UNREACHABLE FROM THE TREE. The filter hands a viewer
// the project their own session works on even when the entity above it is not
// theirs to see (the own-session clause), so a tree that only ever hung a
// project under a visible entity would drop exactly the row that fix restored.
// The same holds one level down for a session whose entity is not in the file.
test('a project whose entity is not in the file is still a node', () => {
  const h = pageIndex(doc({
    viewer: 'a',
    projects: [{ id: 'work', name: 'Work', parent: 'client' }],
    sessions: [sess('s-1', 'work-a', { domain: 'client', project: 'work', mine: true })]
  }));
  assert.ok(h.includes('/desk/project/work'));
  assert.ok(h.indexOf('/desk/project/work') < h.indexOf('/desk/session/s-1'));
});

// THE TEAM PAGE KEEPS EVERY SESSION THAT NAMES THE TEAM. The page was the
// entity's own subtree and nothing else, and a session hangs under its PROJECT
// whenever that project is in the file - so a session working on a project
// whose parent entity the viewer cannot see (the filter's own-session clause
// puts exactly those projects in the file) stood as a ROOT of the forest and
// vanished from the page of the very team it names. The index still showed it,
// which is what makes the absence a half-answer rather than a missing feature.
test('the team page keeps a session whose project hangs under an entity not in the file', () => {
  const h = pageTeam(doc({
    entities: [{ id: 'team', name: 'Team', managedBy: null, members: ['b'], member: true }],
    projects: [{ id: 'p-orphan', name: 'Orphan', parent: 'absent-entity' }],
    sessions: [sess('s-1', 'work-a', { domain: 'team', project: 'p-orphan' })]
  }), 'team');
  assert.ok(h.includes('/desk/session/s-1'), h);
  assert.ok(h.includes('/desk/project/p-orphan'), h);
  assert.ok(between(h, '/desk/project/p-orphan', '/desk/session/s-1').includes('<ul>'), h);
});

// AND ONLY THE SESSIONS THAT NAME IT. A root project can carry sessions from
// more than one entity; the ones that name somebody else are not this team's
// business, however visible they are elsewhere in the same file.
test('a root project on the team page carries only the sessions that name this team', () => {
  const h = pageTeam(doc({
    entities: [{ id: 'team', name: 'Team', managedBy: null, members: ['b'], member: true },
               { id: 'e2', name: 'E2', managedBy: null, members: ['b'], member: true }],
    projects: [{ id: 'p-orphan', name: 'Orphan', parent: 'absent-entity' }],
    sessions: [sess('s-1', 'work-a', { domain: 'team', project: 'p-orphan' }),
               sess('s-2', 'work-b', { domain: 'e2', project: 'p-orphan' })]
  }), 'team');
  assert.ok(h.includes('/desk/session/s-1'), h);
  assert.ok(!h.includes('/desk/session/s-2'), h);
});

test('a session with no entity and no project is still a node', () => {
  const h = pageIndex(doc({ viewer: 'a', sessions: [sess('s-1', 'work-a', { mine: true })] }));
  assert.ok(h.includes('/desk/session/s-1'));
});

test('a session node names its owner, its state and its age', () => {
  const h = pageIndex(deep);
  assert.ok(h.includes('work-a - a - running - 6 min'), h);
});

// THE AGE IS READ BY A HUMAN, so it is said in the unit that human thinks in.
// A number of seconds is exact and unreadable past a minute or two; `unknown`
// is what an age nobody could measure has to say out loud.
test('an age reads in the unit a reader thinks in', () => {
  assert.equal(formatAge(null), 'unknown');
  assert.equal(formatAge(undefined), 'unknown');
  assert.equal(formatAge(30), '30 s');
  assert.equal(formatAge(360), '6 min');
  assert.equal(formatAge(7200), '2 h');
});

// ANYTHING THAT IS NOT A FINITE, NON-NEGATIVE NUMBER IS `unknown`, not a
// coerced guess. The producer writes a JSON number or null - never a string,
// a boolean or an out-of-range value - so an age that fails that shape is
// unmeasurable, not merely small or large.
test('an age that is not a finite non-negative number reads unknown', () => {
  assert.equal(formatAge(''), 'unknown');
  assert.equal(formatAge(true), 'unknown');
  assert.equal(formatAge(-5), 'unknown');
  assert.equal(formatAge(Infinity), 'unknown');
});

// A SESSION NODE COLLAPSES "unknown - unknown" INTO ONE WORD. Two separate
// fields both saying the same absence read as one message read twice; a
// single "unknown" says it once.
test('a session node with an unknown state and an unknown age says it once', () => {
  const h = pageIndex(snap);
  assert.ok(h.includes(' - Mine - b - unknown</li>'), h);
  assert.ok(!h.includes('unknown - unknown'));
});
