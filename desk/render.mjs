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
// No page emits a <script> tag and no link leaves the /desk/ prefix, so the
// server's `default-src 'none'` policy costs the view nothing.

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

// LAYOUT - the only place a document shell is written. `title` is the heading
// this page carries; the <title> element is the same on every page so a browser
// tab never becomes a place where an estate's names are read out of context.
function LAYOUT(title, body, snap) {
  const { generatedAt, host } = snap;
  return '<!doctype html>' +
    '<meta charset="utf-8">' +
    '<meta name="viewport" content="width=device-width,initial-scale=1">' +
    '<title>Steward Desk</title>' +
    '<style>' + CSS + '</style>' +
    '<h1>' + h(title) + '</h1>' +
    body +
    '<footer>measured at ' + h(generatedAt) + ' on ' + h(host) +
    ' &middot; <a href="/desk/">desk</a></footer>';
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

// age - the liveness answer as a reader wants it: a state word, and how old the
// activity behind it is. A missing age is `unknown`, never blank and never the
// language's word for absence.
const age = (ageSeconds) =>
  (ageSeconds === null || ageSeconds === undefined || Number.isNaN(Number(ageSeconds))
    ? 'unknown'
    : String(ageSeconds) + 's');

const livenessWord = (lv) => orNone(lv.state) + ', last activity ' + age(lv.ageSeconds);

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
// The pages. Each returns an HTML string, or null when the id names nothing
// this viewer's file carries - the server turns that null into the SAME 404 an
// unknown route gets, so the page functions never have to know the difference
// between "does not exist" and "not yours".

export function pageIndex(snap) {
  const v = readSnapshot(snap);
  let body = '';

  body += section('Teams', v.entities.length
    ? table(v.entities.map((e) =>
        rawRow(e.name === undefined ? e.id : e.name,
          link('team', e.id, e.id) + (e.member ? tag('member') : tag('through a manager')))))
    : empty('No teams in this view.'));

  body += section('Projects', v.projects.length
    ? table(v.projects.map((p) =>
        rawRow(p.name === undefined ? p.id : p.name,
          link('project', p.id, p.id) +
          (p.parent ? ' under ' + link('team', p.parent, p.parent) : ''))))
    : empty('No projects in this view.'));

  // Sessions are grouped by the entity that owns them, because that is the
  // question a reader arrives with: what is my team running right now.
  const groups = [];
  for (const s of v.sessions) {
    const key = orNone(s.domain);
    let g = groups.find((x) => x.key === key);
    if (!g) { g = { key, list: [] }; groups.push(g); }
    g.list.push(s);
  }
  body += section('Sessions', groups.length
    ? groups.map((g) => '<h3>' + h(g.key) + '</h3>' + sessionTable(g.list)).join('')
    : empty('No sessions in this view.'));

  return LAYOUT('Desk for ' + orNone(v.viewer), body, v);
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

  const projects = v.projects.filter((p) => p.parent === e.id);
  body += section('Projects', projects.length
    ? table(projects.map((p) => rawRow(p.name === undefined ? p.id : p.name, link('project', p.id, p.id))))
    : empty('No projects in this view.'));

  body += section('Sessions', sessionTable(v.sessions.filter((s) => s.domain === e.id)));

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
    row('last activity', age(s.liveness.ageSeconds))
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
