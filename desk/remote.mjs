// desk/remote.mjs - the estates this desk CONSUMES, read off disk.
// (spec: docs/superpowers/specs/2026-09-13-desk-across-estates-design.md)
//
// TWO QUESTIONS, KEPT SEPARATE, because conflating them is how a fleet view
// lies:
//
//   Is the ESTATE readable?           -> status: ok | stale | unavailable
//   Does THIS VIEWER have rows there? -> snap: the matched document, or null
//
// An estate that answers perfectly and holds nothing of yours is not a broken
// estate, and an estate that cannot be reached is not an empty one. One flag
// for "is there anything to show" would render both as the same blank space,
// and this product has paid twice to learn that an unmeasurable rendered as a
// negative fact sends someone to repair what is not broken.
//
// THE JOIN IS ON IDENTITY, NEVER ON THE FILE NAME. A remote generation is named
// by THAT estate's principal slugs, which this estate does not govern and did
// not choose. Opening `<my-slug>.json` over there would be trusting a
// stranger's spelling to decide whose sessions this is about - and the day two
// estates each have a `jon` who are different people, that reader hands one of
// them the other's work. So every file in the generation is read and the one
// whose viewerIdentity shares a word with this viewer's is the answer.
//
// THIS MODULE ONLY READS. It never fetches, never writes, and holds no opinion
// about how the bytes arrived; desk/fetch.sh put them there and recorded in
// meta.json how that went.
import { readdirSync, readFileSync, statSync } from 'node:fs';
import { join } from 'node:path';

// AN EMPTY IDENTITY MATCHES NOTHING, ON EITHER SIDE. `_operator` carries an
// empty array by design - it is the unfiltered view and belongs to no person -
// and a local principal whose row nobody finished writing carries one too. If
// empty matched empty, one request would hand a person a whole estate.
function shares(a, b) {
  if (!Array.isArray(a) || !Array.isArray(b) || a.length === 0 || b.length === 0) return false;
  const set = new Set(a.filter((w) => typeof w === 'string' && w.length > 0));
  return b.some((w) => typeof w === 'string' && set.has(w));
}

function readJSON(path) {
  try { return JSON.parse(readFileSync(path, 'utf8')); } catch { return null; }
}

// loadRemotes(deskDir, viewerIdentity, { now, maxAgeSeconds }) -> one row per
// consumed estate, sorted by name. Never throws: a desk with no remote/ tree is
// the ordinary state for most machines in a fleet, and an unreadable estate is
// a row that says so rather than an exception that loses the other estates.
export function loadRemotes(deskDir, viewerIdentity, { now = Date.now(), maxAgeSeconds = 900 } = {}) {
  const base = join(deskDir, 'remote');
  let names;
  try {
    names = readdirSync(base).filter((n) => {
      try { return statSync(join(base, n)).isDirectory(); } catch { return false; }
    });
  } catch {
    return [];
  }
  names.sort();

  return names.map((estate) => {
    const dir = join(base, estate);
    const meta = readJSON(join(dir, 'meta.json'));
    // EVERY ROW CARRIES `snap`, PRESENT AND null WHEN THERE IS NOTHING. A field
    // that is sometimes absent makes a consumer write `x.snap && ...` and read
    // "absent" and "nothing" as one thing - the same reason viewerIdentity is an
    // empty array on the operator file rather than a missing key.
    if (!meta || typeof meta.status !== 'string') {
      return { estate, status: 'unavailable', snap: null,
               reason: 'this estate has no readable meta.json, so nothing here says how the last fetch went' };
    }
    if (meta.status !== 'ok') {
      // THE ROWS ON DISK ARE THE LAST THING THAT WAS TRUE, and they stay on
      // disk - desk/fetch.sh keeps them precisely so a later success has
      // something to compare against. They are NOT returned: rendering them
      // under a live heading is the lie this seam exists to prevent.
      return { estate, status: 'unavailable', snap: null, fetchedAt: meta.fetchedAt,
               reason: meta.reason || 'the last fetch failed without naming a cause' };
    }

    let files;
    try { files = readdirSync(join(dir, 'current')).filter((f) => f.endsWith('.json')); } catch { files = null; }
    if (files === null) {
      return { estate, status: 'unavailable', snap: null, fetchedAt: meta.fetchedAt,
               reason: 'the last fetch reported ok but left no readable generation' };
    }

    // ONE BAD FILE IS NOT A BAD ESTATE. A colleague's unreadable row must not
    // hide yours; one corrupt byte in somebody else's file would otherwise
    // blank the estate for everyone who reads it.
    let mine = null;
    let sawIdentityField = false;
    let sawAnyDocument = false;
    for (const f of files) {
      const doc = readJSON(join(dir, 'current', f));
      if (!doc || typeof doc !== 'object') continue;
      sawAnyDocument = true;
      if (Object.prototype.hasOwnProperty.call(doc, 'viewerIdentity')) sawIdentityField = true;
      if (mine === null && shares(viewerIdentity, doc.viewerIdentity)) mine = doc;
    }

    // A PRODUCER TOO OLD TO NAME IDENTITIES IS A REAL STATE DURING A ROLLOUT,
    // and it must fail toward showing LESS rather than toward guessing. Falling
    // back to the file name here would quietly reintroduce exactly the join
    // this field exists to replace, and it would do it only on the estates that
    // had not been updated yet - the ones nobody is looking at.
    if (sawAnyDocument && !sawIdentityField) {
      return { estate, status: 'unavailable', snap: null, fetchedAt: meta.fetchedAt,
               reason: 'this estate\'s producer does not state viewerIdentity, so no row here can be matched to a person' };
    }

    if (mine === null) {
      // NOT AN ERROR, AND SAID SO BY CARRYING NO REASON. You simply have
      // nothing on this estate, which is a fact about you and not about it.
      return { estate, status: 'ok', fetchedAt: meta.fetchedAt, snap: null };
    }

    const age = (now - Date.parse(mine.generatedAt)) / 1000;
    const ageSeconds = Number.isFinite(age) ? Math.max(0, Math.round(age)) : null;
    // STALE SHOWS ITS ROWS. They are the best answer that exists, and hiding
    // them would turn a producer that stopped an hour ago into an estate that
    // looks empty. The age travels beside them so the reader can weigh it.
    const stale = ageSeconds === null || ageSeconds > maxAgeSeconds;
    return { estate, status: stale ? 'stale' : 'ok', fetchedAt: meta.fetchedAt, ageSeconds, snap: mine };
  });
}
