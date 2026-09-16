// desk/mount.mjs - where this desk is mounted, as ONE exported binding.
//
// THE SPEC ASKS FOR ONE EXPORTED CONSTANT and this is it: every route, every
// redirect location, every rendered href and the OAuth redirect URI derive from
// MOUNT. Thirteen literal '/desk...' strings in serve.mjs and three hrefs in
// render.mjs used to say it separately, which is thirteen places to forget.
//
// WHY A LIVE BINDING AND NOT A PARAMETER. render.mjs is a pure rendering module
// with 56 call sites in its own suite; threading the mount through every page
// function would make every one of those assert something it is not about. ESM
// exports are LIVE BINDINGS - an importer that reads MOUNT sees the value as it
// is now, not as it was at import time - so serve.mjs can resolve it once at
// startup and render.mjs reads the same word without a signature between them.
//
// WHY IT IS SETTABLE AT ALL, given this file would rather it were not: the value
// comes from the estate through desk-paths, and modules are imported before any
// of that is read. The alternative is an environment variable, which is a
// test-only knob wearing a coat. setMount is called exactly once, from serve.mjs,
// before the route table is built.
//
// THE DEFAULT IS '/desk' SO EVERY DEPLOYMENT THAT EXISTS TODAY IS BYTE-IDENTICAL.
// A desk sharing a host with other things needs the prefix; a desk given a
// hostname of its own does not, and there the empty string is the right answer.

export const DEFAULT_MOUNT = '/desk';

export let MOUNT = DEFAULT_MOUNT;

// THE FORM IS THE SPEC'S, and the same one desk-paths enforces on the estate key:
// the empty string, or a string that starts with '/', does not end with '/', and
// carries only unreserved characters (RFC 3986: ALPHA DIGIT - . _ ~). Zero
// segments is the empty string; a segment must be non-empty, which is what rejects
// a trailing slash and a doubled one.
//
// IT IS CHECKED IN BOTH PLACES ON PURPOSE. desk-paths refuses a malformed value at
// the estate; this refuses one that reached the front by any other route. A guard
// that trusts its caller to have checked is a guard that covers the caller it
// happened to think of.
const FORM = /^(\/[A-Za-z0-9._~-]+)*$/;

export function validateMount(v) {
  if (typeof v !== 'string') return { ok: false, reason: 'the mount must be a string' };
  if (!FORM.test(v)) {
    return {
      ok: false,
      reason: "'" + v + "' is not a mount path: it must be empty, or start with '/', "
            + "not end with '/', and carry only unreserved characters",
    };
  }
  return { ok: true, value: v };
}

// setMount(v) -> { ok: true } | { ok: false, reason }. It never throws: the caller
// is a startup path that exits 78 with the key named, and an exception there would
// lose the reason on the way up.
export function setMount(v) {
  const r = validateMount(v);
  if (!r.ok) return r;
  MOUNT = r.value;
  return { ok: true };
}

// THE ROOT IS THE CASE EVERY CALLER GETS WRONG. With MOUNT='' the index is '/',
// not '' - a redirect to the empty string is not a location, and an href of ''
// means "this page". Callers say at(''), at('/'), at('/auth/login') and get a
// path that is correct at every mount, including the root.
export function at(rest) {
  if (rest === '' || rest === '/') return MOUNT === '' ? '/' : MOUNT + '/';
  return MOUNT + rest;
}

// reAt(rest) - at(rest) escaped for use inside a RegExp, because the route table is
// built from patterns and not from string equality.
//
// THE MOUNT'S OWN CHARACTER SET IS WHY THIS IS SHORT AND WHY IT IS STILL HERE. The
// form above admits only unreserved characters and '/', so the only one that means
// anything to a regular expression is '.', which would otherwise match any single
// character: a desk at /a.b would answer at /axb. That is the whole hazard - no
// quantifiers, no anchors, no groups can reach this value.
//
// It is escaped anyway, and centrally, because the NEXT person to widen the form is
// not going to come back and read this paragraph. A guard written for the character
// set that exists today covers today's character set; one written at the point where
// the value becomes a pattern covers whatever the form later admits.
export function reAt(rest) {
  return at(rest).replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
}
