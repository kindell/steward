// desk/render.mjs - one snapshot in, one HTML string out. Nothing else.
//
// THIS MODULE IS PURE ON PURPOSE. It reads no clock, opens no file, spawns
// nothing and knows no environment variable. Everything a page says is in the
// snapshot it was handed, which is why the footer says "measured at
// <generatedAt>" and never "as of now": the reader must be able to tell how old
// the answer is, and a renderer that consulted a clock would quietly report the
// age of the READING instead of the age of the MEASUREMENT.
//
// TWO RULES CARRY THE WHOLE SAFETY ARGUMENT, and both are asserted in
// desk/test/render.test.mjs:
//
//   1. Every value goes through escapeHtml on its way into the page. There is
//      no raw-HTML escape hatch here, no innerHTML, no template that trusts its
//      input - a display name is data, and data from the estate is never markup.
//   2. Every field read from the snapshot is destructured BY NAME from the
//      contract in desk/SCHEMA.md. A row is never spread, stringified or
//      iterated, so a key the producer adds tomorrow - or a key an unfiltered
//      document accidentally carried - cannot reach a page by being present.
//      The test fixture carries an `extra` sentinel to prove it.
//
// No page emits a <script> tag and no link leaves the /desk/ prefix - the one
// href that is not a path is the empty `data:` icon below, which fetches
// nothing - so the server's `default-src 'none'` policy costs the view
// nothing.

export function escapeHtml(s) {
  if (s === null || s === undefined) return '';
  return String(s)
    .replace(/&/g, '&amp;')
    .replace(/</g, '&lt;')
    .replace(/>/g, '&gt;')
    .replace(/"/g, '&quot;')
    .replace(/'/g, '&#39;');
}

const h = escapeHtml;

// An absent value is a dash, never the word the language happens to use for
// absence: a page that printed a JS literal would be reporting on its own
// implementation instead of on the estate.
const NONE = '-';
const orNone = (v) => (v === null || v === undefined || v === '' ? NONE : String(v));

export const ICON = '<link rel="icon" href="data:,">';

const CSS = [
  'body{font:15px/1.5 system-ui,sans-serif;margin:2rem auto;max-width:52rem;padding:0 1rem;color:#111}',
  'h1{font-size:1.4rem;margin:0 0 .2rem}h2{font-size:1.05rem;margin:1.6rem 0 .4rem}',
  'table{border-collapse:collapse;width:100%;margin:.3rem 0}',
  'th,td{text-align:left;padding:.25rem .6rem .25rem 0;border-bottom:1px solid #e4e4e4;vertical-align:top}',
  'th{font-weight:600;white-space:nowrap}',
  'a{color:#0b5;text-decoration:none}a:hover{text-decoration:underline}',
  '.tag{font-size:.8rem;border:1px solid #bbb;border-radius:.6rem;padding:0 .4rem;margin-left:.3rem;color:#555}',
  'footer{margin-top:2.5rem;color:#666;font-size:.85rem;border-top:1px solid #e4e4e4;padding-top:.5rem}',
  'p.empty{color:#666}'
].join('');

// THE PAGE NAMES ITS OWN ICON SO THE BROWSER DOES NOT GO LOOKING FOR ONE.
// A page with no <link rel=icon> makes the browser ask for /favicon.ico on its
// own, and on the public front that request carries the session cookie - so
// every page view was TWO requests against a budget that is one per address,
// and a team behind one NAT shares that address. An empty data: URL is a
// declared icon the browser never fetches: no request, no second hit, and no
// bytes on the page beyond this line. serve.mjs names `img-src data:` in the
// policy for exactly this one image, which allows no origin and therefore no
// network fetch of any kind - see the comment on that header.

// LAYOUT - the only place a document shell is written. `title` is the heading
// this page carries; the <title> element is the same on every page so a browser
// tab never becomes a place where an estate's names are read out of context.
//
// A NULL SNAPSHOT IS A PAGE WITH NO FOOTER, NOT A PAGE WITH AN EMPTY ONE. The
// login page (pageLogin) is the only page written before anybody is known, so
// there is no measurement to date it by and no desk to link back to - a footer
// reading "measured at  on " would be a claim about the estate made out of two
// absent fields, and a link to /desk/ would send a stranger back to the login
// page they are already reading.
function LAYOUT(title, body, snap) {
  const { generatedAt, host } = snap || {};
  const foot = snap
    ? '<footer>measured at ' + h(generatedAt) + ' on ' + h(host) +
      ' &middot; <a href="/desk/">desk</a></footer>'
    : '';
  return '<!doctype html>' +
    '<meta charset="utf-8">' +
    '<meta name="viewport" content="width=device-width,initial-scale=1">' +
    '<title>Steward Desk</title>' +
    ICON +
    '<style>' + CSS + '</style>' +
    '<h1>' + h(title) + '</h1>' +
    body +
    foot;
}

// row - a label and a value, both escaped, in a two-column table. Every page is
// built from this and from list(), so there is exactly one code path that turns
// a value into markup.
const row = (label, value) => '<tr><th>' + h(label) + '</th><td>' + h(value) + '</td></tr>';
const rawRow = (label, html) => '<tr><th>' + h(label) + '</th><td>' + html + '</td></tr>';
const table = (rows) => (rows.length ? '<table>' + rows.join('') + '</table>' : '');
const section = (title, body) => '<h2>' + h(title) + '</h2>' + body;
const empty = (what) => '<p class="empty">' + h(what) + '</p>';
const tag = (word) => '<span class="tag">' + h(word) + '</span>';

// link - the href is built from the escaped id and always under /desk/. The
// route patterns in serve.mjs accept only [a-z0-9-] ids and s-<hex> session
// ids, so a link this function builds is a link that server can answer.
const link = (prefix, id, text) =>
  '<a href="/desk/' + prefix + '/' + h(id) + '">' + h(text) + '</a>';

// ---------------------------------------------------------------------------
// The contract readers. Each takes one raw row and returns a copy carrying
// ONLY the keys desk/SCHEMA.md names.

const arr = (v) => (Array.isArray(v) ? v : []);

function readEntity(e) {
  const { id, name, managedBy, members, member } = e;
  return { id, name, managedBy, members: arr(members), member: !!member };
}

function readProject(p) {
  const { id, name, parent } = p;
  return { id, name, parent };
}

function readAsset(a) {
  const { id, name, axis, source } = a;
  return { id, name, axis, source };
}

function readSession(s) {
  const { id, slug, label, owner, mine, domain, project, runtime, host, repo, liveness, mcp } = s;
  const lv = liveness && typeof liveness === 'object' ? liveness : {};
  const { state, measuredAt, ageSeconds } = lv;
  return {
    id, slug, label, owner, mine: !!mine, domain, project, runtime, host, repo,
    liveness: { state, measuredAt, ageSeconds },
    mcp: arr(mcp).map(readAsset)
  };
}

function readSnapshot(snap) {
  const { host, generatedAt, viewer, readAll, entities, projects, sessions } = snap;
  return {
    host, generatedAt, viewer, readAll: !!readAll,
    entities: arr(entities).map(readEntity),
    projects: arr(projects).map(readProject),
    sessions: arr(sessions).map(readSession)
  };
}

// formatAge - how old the activity behind a liveness answer is, IN THE UNIT THE
// READER THINKS IN. A raw second count is exact and unreadable the moment it
// passes a minute or two: `7200s` is a number to divide, `2 h` is an answer. The
// three thresholds are the ones a person uses out loud - seconds up to a minute,
// minutes up to an hour, hours after that - and the value is floored, never
// rounded up, so a desk never reports a session as fresher than it is.
//
// A MISSING AGE IS `unknown`, never blank and never the language's word for
// absence: "nobody could measure this" is a fact the reader has to be told.
export function formatAge(ageSeconds) {
  if (typeof ageSeconds !== 'number' || !Number.isFinite(ageSeconds) || ageSeconds < 0) return 'unknown';
  if (ageSeconds < 60) return Math.floor(ageSeconds) + ' s';
  if (ageSeconds < 3600) return Math.floor(ageSeconds / 60) + ' min';
  return Math.floor(ageSeconds / 3600) + ' h';
}

const livenessWord = (lv) => orNone(lv.state) + ', last activity ' + formatAge(lv.ageSeconds);

// sessionLine - one session as a table row: its handle links to its page, the
// label and the liveness answer sit beside it, and `mine` is marked so a viewer
// can tell their own work from a colleague's at a glance.
function sessionLine(s) {
  return '<tr><td>' + link('session', s.id, s.slug) + (s.mine ? tag('mine') : '') + '</td>' +
    '<td>' + h(s.label) + '</td>' +
    '<td>' + h(livenessWord(s.liveness)) + '</td></tr>';
}

const sessionTable = (list) =>
  (list.length
    ? '<table><tr><th>session</th><th>label</th><th>liveness</th></tr>' + list.map(sessionLine).join('') + '</table>'
    : empty('No sessions in this view.'));

// ---------------------------------------------------------------------------
// THE TREE. A desk's first question is not "what rows are in my file" but "who
// is doing what, for whom" - team, then the client that team manages, then the
// project, then the session working on it. Four lists, one per kind, made the
// reader rebuild that shape in their head from three tables that never named
// each other; one nested list IS the shape.
//
// EVERY ROW IN THE FILE APPEARS EXACTLY ONCE. The filter decided what the
// viewer may see; a view that then dropped a row because its parent happened
// not to be in the same file would be a second, invisible filter - and the
// rows it would drop are precisely the ones the visibility rule works hardest
// to include (a project reached through the viewer's own session, whose entity
// is not theirs to see). So each row hangs under its parent WHEN THAT PARENT IS
// IN THIS FILE, and stands as a root of its own when it is not.

// Order inside a level: by the display name, then by id so equal names never
// swap between two renderings of the same file. A session's display name is its
// `label` - the contract gives it no `name`, and sorting every session under one
// empty string would make the level's order the accident of the array.
const labelOf = (x) => {
  const n = (x.name === null || x.name === undefined) ? x.label : x.name;
  return (n === null || n === undefined) ? '' : String(n);
};
const idOf = (x) => (x.id === null || x.id === undefined ? '' : String(x.id));
function byNameThenId(a, b) {
  const an = labelOf(a); const bn = labelOf(b);
  if (an !== bn) return an < bn ? -1 : 1;
  return idOf(a) < idOf(b) ? -1 : idOf(a) > idOf(b) ? 1 : 0;
}

const push = (m, k, x) => { const l = m.get(k); if (l) l.push(x); else m.set(k, [x]); };

// plan - one pass that decides where every row hangs, before a byte of HTML is
// written. The walk below then only has to read these maps, so the placement
// rule is in one place and the recursion has nothing to decide.
function plan(v) {
  const entities = v.entities.slice().sort(byNameThenId);
  const projects = v.projects.slice().sort(byNameThenId);
  const sessions = v.sessions.slice().sort(byNameThenId);
  const entityIds = new Set(entities.map((e) => e.id));
  const projectIds = new Set(projects.map((p) => p.id));

  const childEntities = new Map(); const rootEntities = [];
  for (const e of entities) {
    // AN ENTITY WHOSE MANAGER IS NOT IN THIS FILE IS A ROOT, never a dropped
    // row: the viewer reached it through some other door, and the door it did
    // not reach is not a reason to hide it.
    if (e.managedBy && entityIds.has(e.managedBy)) push(childEntities, e.managedBy, e);
    else rootEntities.push(e);
  }
  const entityProjects = new Map(); const rootProjects = [];
  for (const p of projects) {
    if (p.parent && entityIds.has(p.parent)) push(entityProjects, p.parent, p);
    else rootProjects.push(p);
  }
  const projectSessions = new Map(); const entitySessions = new Map(); const rootSessions = [];
  for (const s of sessions) {
    if (s.project && projectIds.has(s.project)) push(projectSessions, s.project, s);
    else if (s.domain && entityIds.has(s.domain)) push(entitySessions, s.domain, s);
    else rootSessions.push(s);
  }
  return { entities, rootEntities, childEntities, entityProjects,
           projectSessions, entitySessions, rootProjects, rootSessions };
}

const li = (head, kids) => '<li>' + head + (kids.length ? '<ul>' + kids.join('') + '</ul>' : '') + '</li>';

const entityHead = (e) =>
  link('team', e.id, labelOf(e) || orNone(e.id)) + (e.member ? tag('member') : tag('through a manager'));
const projectHead = (p) => link('project', p.id, labelOf(p) || orNone(p.id));
// The session node answers the three things a reader asks of a running session
// without opening it: whose it is, whether it is alive, and how stale that
// answer is. `mine` is marked exactly as the session table marks it.
function sessionHead(s) {
  const st = orNone(s.liveness.state);
  const ag = formatAge(s.liveness.ageSeconds);
  // A STATE NOBODY MEASURED AND AN AGE NOBODY MEASURED ARE ONE FACT, NOT TWO:
  // "unknown - unknown" repeats the same absence twice where "unknown" says
  // it once.
  const live = (st === 'unknown' && ag === 'unknown') ? 'unknown' : st + ' - ' + ag;
  return link('session', s.id, orNone(s.slug)) + (s.mine ? tag('mine') : '') +
    ' - ' + h(orNone(s.label)) + ' - ' + h(orNone(s.owner)) +
    ' - ' + h(live);
}

const sessionNode = (s) => li(sessionHead(s), []);
const projectNode = (P, p) => li(projectHead(p), (P.projectSessions.get(p.id) || []).map(sessionNode));

// entityKids - a managed entity's whole subtree, then its own projects, then
// the sessions that hang on the entity itself. `seen` is what makes a MANAGED_BY
// CYCLE terminate: the registry refuses to load one, but a desk renders the
// document it was handed, and a document that carries a loop must still produce
// a page rather than a stack overflow.
function entityKids(P, e, seen) {
  const kids = [];
  for (const c of P.childEntities.get(e.id) || []) if (!seen.has(c.id)) kids.push(entityNode(P, c, seen));
  for (const p of P.entityProjects.get(e.id) || []) kids.push(projectNode(P, p));
  for (const s of P.entitySessions.get(e.id) || []) kids.push(sessionNode(s));
  return kids;
}
function entityNode(P, e, seen) {
  seen.add(e.id);
  return li(entityHead(e), entityKids(P, e, seen));
}

function forest(P) {
  const seen = new Set();
  const items = [];
  for (const e of P.rootEntities) items.push(entityNode(P, e, seen));
  for (const p of P.rootProjects) items.push(projectNode(P, p));
  for (const s of P.rootSessions) items.push(sessionNode(s));
  // A cycle has no root - every member names a manager that is present - so
  // nothing above reached it. Each unvisited entity is taken as a root here, in
  // order, and its own walk marks the rest of its loop as seen.
  for (const e of P.entities) if (!seen.has(e.id)) items.push(entityNode(P, e, seen));
  return items.length ? '<ul>' + items.join('') + '</ul>' : empty('Nothing in this view.');
}

// ---------------------------------------------------------------------------
// The pages. Each returns an HTML string, or null when the id names nothing
// this viewer's file carries - the server turns that null into the SAME 404 an
// unknown route gets, so the page functions never have to know the difference
// between "does not exist" and "not yours".

export function pageIndex(snap) {
  const v = readSnapshot(snap);
  return LAYOUT('Desk for ' + orNone(v.viewer), forest(plan(v)), v);
}

export function pageTeam(snap, id) {
  const v = readSnapshot(snap);
  const e = v.entities.find((x) => x.id === id);
  if (!e) return null;

  let body = table([
    row('id', orNone(e.id)),
    row('name', orNone(e.name)),
    row('managed by', orNone(e.managedBy)),
    row('members', e.members.length ? e.members.join(', ') : NONE),
    row('you are a member', e.member ? 'yes' : 'no')
  ]);

  // THE SAME TREE, ROOTED HERE. The entity itself is the page, so the node for
  // it is not repeated - what follows is everything under it, to any depth: the
  // entities it manages, its own projects, and the sessions that hang on it.
  const P = plan(v);
  const kids = entityKids(P, e, new Set([e.id]));

  // AND THEN THE SESSIONS THAT NAME THIS TEAM FROM OUTSIDE ITS OWN SUBTREE. A
  // session hangs under its PROJECT wherever that project sits in the forest,
  // and the filter deliberately hands a viewer projects whose parent entity
  // they cannot see (the own-session clause) - such a project is a ROOT here,
  // so its sessions never reached this page even though `domain` names this
  // very team. The index showed them and the team page did not, which is one
  // question answered two ways.
  //
  // ONLY THE SESSIONS THAT NAME THIS ENTITY travel: a root project can carry
  // sessions belonging to more than one team, and the others are not this
  // page's business. The rows are read out of the same plan, so the order
  // inside every appended node is the order the rest of the tree uses.
  const namesThis = (s) => s.domain === e.id;
  for (const p of P.rootProjects) {
    const own = (P.projectSessions.get(p.id) || []).filter(namesThis);
    if (own.length) kids.push(li(projectHead(p), own.map(sessionNode)));
  }
  for (const s of P.rootSessions) if (namesThis(s)) kids.push(sessionNode(s));

  body += section('Under this team', kids.length
    ? '<ul>' + kids.join('') + '</ul>'
    : empty('Nothing hangs under this team in this view.'));

  return LAYOUT(orNone(e.name), body, v);
}

export function pageProject(snap, id) {
  const v = readSnapshot(snap);
  const p = v.projects.find((x) => x.id === id);
  if (!p) return null;

  let body = table([
    row('id', orNone(p.id)),
    row('name', orNone(p.name))
  ]);
  body += table([rawRow('team', p.parent ? link('team', p.parent, p.parent) : h(NONE))]);
  body += section('Sessions', sessionTable(v.sessions.filter((s) => s.project === p.id)));

  return LAYOUT(orNone(p.name), body, v);
}

// pageLogin - the front's only page for a stranger: one link per provider.
//
// NOTHING ABOUT THE ESTATE IS ON IT. No snapshot is read here, so a person who
// has not logged in yet cannot learn a host, a name, a session or a
// measurement from the page that asks them to log in. The provider slugs are
// the estate's own file names (desk/providers.d/<slug>.conf), and they are the
// one thing a person must see to choose which door they were invited through.
// They are sorted so two renderings of the same set never differ, and escaped
// like every other value in this file even though loadProviders already
// refuses a file name that is not a slug.
export function pageLogin(providers) {
  const items = [...providers.keys()].sort().map((slug) =>
    '<li><a href="/desk/auth/login?provider=' + h(slug) + '">Log in with ' + h(slug) + '</a></li>').join('');
  return LAYOUT('Steward Desk',
    '<p>Log in with the account you were invited with.</p><ul>' + items + '</ul>', null);
}

export function pageSession(snap, id) {
  const v = readSnapshot(snap);
  const s = v.sessions.find((x) => x.id === id);
  if (!s) return null;

  let body = table([
    row('id', orNone(s.id)),
    row('handle', orNone(s.slug)),
    row('label', orNone(s.label)),
    row('owner', orNone(s.owner) + (s.mine ? ' (you)' : '')),
    rawRow('team', s.domain ? link('team', s.domain, s.domain) : h(NONE)),
    rawRow('project', s.project ? link('project', s.project, s.project) : h(NONE)),
    row('runtime', orNone(s.runtime)),
    row('host', orNone(s.host)),
    row('repository', orNone(s.repo)),
    row('liveness', orNone(s.liveness.state)),
    row('measured at', orNone(s.liveness.measuredAt)),
    row('last activity', formatAge(s.liveness.ageSeconds))
  ]);

  // THE ASSET TABLE NAMES THE GRANT, NEVER THE MEANS. id, axis and source say
  // WHICH asset the session may use and WHO granted it; the command line, the
  // arguments and the env file are not in the contract and are not printed
  // here, on any page, for any viewer.
  body += section('Granted assets', s.mcp.length
    ? '<table><tr><th>id</th><th>name</th><th>axis</th><th>source</th></tr>' +
      s.mcp.map((a) => '<tr><td>' + h(a.id) + '</td><td>' + h(a.name) + '</td><td>' +
        h(a.axis) + '</td><td>' + h(a.source) + '</td></tr>').join('') + '</table>'
    : empty('No granted assets in this view.'));

  return LAYOUT(orNone(s.slug), body, v);
}
