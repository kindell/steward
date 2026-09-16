// desk/test/mount.mjs - where the desk is mounted, on its own.
//
// THE MOUNT IS ONE EXPORTED BINDING AND EVERY ROUTE DERIVES FROM IT, so these are
// the assertions that say what "derives from it" means. The serve suite proves the
// default is byte-identical to the literals it replaced; this file proves the value
// is actually USED, which a default-only suite cannot distinguish from a constant.

import test from 'node:test';
import assert from 'node:assert/strict';
import { MOUNT, DEFAULT_MOUNT, setMount, at, reAt, validateMount } from '../mount.mjs';

// THE FORM IS THE SPEC'S AND desk-paths ENFORCES THE SAME ONE. It is checked in both
// places on purpose: desk-paths guards the estate file, this guards every other way a
// value can arrive.
test('the form accepts exactly what the spec allows', () => {
  for (const ok of ['', '/desk', '/a/b', '/a-b.c_d~e'])
    assert.equal(validateMount(ok).ok, true, JSON.stringify(ok) + ' must be accepted');
  for (const bad of ['desk', '/desk/', '//', '/a b', '/a?b', '/a%20b', '/a#b'])
    assert.equal(validateMount(bad).ok, false, JSON.stringify(bad) + ' must be refused');
});

test('a refusal names the value and does not throw', () => {
  const r = validateMount('/desk/');
  assert.equal(r.ok, false);
  assert.match(r.reason, /\/desk\//);
});

test('a non-string is refused rather than coerced', () => {
  for (const v of [undefined, null, 7, {}])
    assert.equal(validateMount(v).ok, false);
});

// THE ROOT IS THE CASE EVERY CALLER GETS WRONG, and the reason the key exists at all:
// a desk on its own hostname has no use for a prefix. at('') must be '/' and never '',
// because a redirect to the empty string is not a location and an href of '' means
// "this page".
test('at() is correct at the default mount', () => {
  assert.equal(MOUNT, DEFAULT_MOUNT);
  assert.equal(at(''), '/desk/');
  assert.equal(at('/'), '/desk/');
  assert.equal(at('/auth/login'), '/desk/auth/login');
});

test('at() is correct at the root, where the empty string would be a bug', () => {
  assert.equal(setMount('').ok, true);
  assert.equal(at(''), '/', 'the index at the root is / and never the empty string');
  assert.equal(at('/'), '/');
  assert.equal(at('/auth/login'), '/auth/login');
});

test('at() is correct at a custom mount', () => {
  assert.equal(setMount('/a/b').ok, true);
  assert.equal(at(''), '/a/b/');
  assert.equal(at('/auth/callback'), '/a/b/auth/callback');
});

// A REFUSED VALUE MUST NOT MOVE THE MOUNT. Half-applying a bad value is worse than
// refusing it: the desk would answer somewhere neither the estate nor the default
// asked for.
test('a refused value leaves the mount where it was', () => {
  assert.equal(setMount('/good').ok, true);
  const before = at('/x');
  const r = setMount('/bad/');
  assert.equal(r.ok, false);
  assert.equal(at('/x'), before, 'the mount must not move on a refusal');
});

// reAt IS WHERE A MOUNT BECOMES A PATTERN. Only '.' in the permitted character set
// means anything to a regular expression - a desk at /a.b would otherwise answer at
// /axb - but the escaping is central so that widening the form later cannot reopen it.
test('reAt escapes a dot so a mount is not a wildcard', () => {
  assert.equal(setMount('/a.b').ok, true);
  const re = new RegExp('^' + reAt('/team/') + '([a-z0-9-]+)$');
  assert.equal(re.test('/a.b/team/x'), true, 'the real path must match');
  assert.equal(re.test('/axb/team/x'), false, 'a wildcard match must not');
});

test('reAt and at agree at every mount', () => {
  for (const m of ['', '/desk', '/a/b', '/a.b']) {
    assert.equal(setMount(m).ok, true);
    assert.equal(reAt('/x').replace(/\\/g, ''), at('/x'));
  }
});

// THE ROUTE TABLE'S OWN SHAPE, at the root - the mount where an off-by-one slash is
// easiest to write and hardest to see.
test('the index route matches at the root and nowhere else', () => {
  assert.equal(setMount('').ok, true);
  const re = new RegExp('^' + reAt('') + '$');
  assert.equal(re.test('/'), true);
  assert.equal(re.test(''), false);
  assert.equal(re.test('/desk/'), false);
});
