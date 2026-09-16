// desk/test/bridge.test.mjs - the bridge reader, on its own.
//
// These are the cases the serve suite cannot reach: it spawns serve.mjs
// against a fixture estate and lets it run the real bridge, and the real
// bridge refuses to print the shapes below. That is the right design for both
// - but a guard whose input the system will not generate still has to be
// proven against something.

import test from 'node:test';
import assert from 'node:assert/strict';
import { parseBridge } from '../bridge.mjs';

const OK = 'dir=/d\nsock=/d/desk.sock\n';

test('the two required lines are read', () => {
  const r = parseBridge(OK);
  assert.equal(r.ok, true);
  assert.equal(r.found.dir, '/d');
  assert.equal(r.found.sock, '/d/desk.sock');
});

test('the optional lines are read when present', () => {
  const r = parseBridge(OK + 'origin=https://desk.example\nproviders=/p\nsession_key=/k\n');
  assert.equal(r.ok, true);
  assert.equal(r.found.origin, 'https://desk.example');
  assert.equal(r.found.providers, '/p');
  assert.equal(r.found.session_key, '/k');
});

test('a missing dir or sock is a refusal', () => {
  assert.equal(parseBridge('sock=/d/desk.sock\n').ok, false);
  assert.equal(parseBridge('dir=/d\n').ok, false);
});

test('unknown lines are ignored, as they always were', () => {
  const r = parseBridge(OK + 'something=else\n');
  assert.equal(r.ok, true);
  assert.equal(r.found.something, undefined);
});

// THE REASON THIS FILE EXISTS.
test('a repeated key is refused, not resolved by position', () => {
  const r = parseBridge(OK + 'origin=https://desk.example\norigin=https://elsewhere.example\n');
  assert.equal(r.ok, false, 'two origin= lines must not produce a started desk');
  assert.match(r.reason, /origin/, 'the refusal names the repeated key');
});

test('the refusal does not depend on which line came last', () => {
  const first = parseBridge(OK + 'origin=https://a.example\norigin=https://b.example\n');
  const other = parseBridge(OK + 'origin=https://b.example\norigin=https://a.example\n');
  assert.equal(first.ok, false);
  assert.equal(other.ok, false);
});

test('a repeated required key is refused too', () => {
  assert.equal(parseBridge('dir=/d\ndir=/other\nsock=/d/desk.sock\n').ok, false);
});

// A KEY THAT IS PRESENT AND EMPTY IS NOT AN ABSENT KEY, and the difference is
// about to matter: DESK_PREFIX makes the empty string a LEGAL value - it is what
// a desk on its own hostname must have, where `/desk` is repetition in every
// link. The reader used `(.+)`, which requires at least one character, so an
// emitted `prefix=` did not match, was skipped, and read as absent. A front would
// then fall back to the default mount and answer somewhere the redirect URI
// registered with the provider does not point - no error, no journal line, and
// the breakage lands on the people logging in.
//
// Measured against a KNOWN key, so membership of KEYS could not confound it:
// parseBridge('dir=/d\nsock=/s\norigin=\n') returned {dir, sock} and no origin.
test('a present-but-empty value is kept, not read as absent', () => {
  const r = parseBridge(OK + 'prefix=\n');
  assert.equal(r.ok, true);
  assert.equal(Object.prototype.hasOwnProperty.call(r.found, 'prefix'), true,
    'an emitted prefix= line must reach the caller');
  assert.equal(r.found.prefix, '', 'and it must arrive as the empty string');
});

// THE TWO ABSENCES MUST STAY TELLABLE APART. `absent` means the estate said
// nothing and the default applies; `present and empty` means the estate chose the
// empty mount. A reader that cannot distinguish them has no way to honour the
// second, which is the whole point of the key.
test('an absent key stays absent, and is not an empty string', () => {
  const r = parseBridge(OK);
  assert.equal(Object.prototype.hasOwnProperty.call(r.found, 'prefix'), false);
  assert.equal(r.found.prefix, undefined);
});

// AND EMPTINESS MUST NOT WEAKEN THE REQUIRED PAIR. dir and sock are the two the
// desk cannot start without; an empty one of those is still no answer.
test('an empty dir or sock is still a refusal', () => {
  assert.equal(parseBridge('dir=\nsock=/d/desk.sock\n').ok, false);
  assert.equal(parseBridge('dir=/d\nsock=\n').ok, false);
});

// A REPEATED KEY STAYS A REFUSAL WHEN ONE OF THE TWO IS EMPTY. Widening the value
// expression must not open a route past the duplicate guard.
test('a repeated key is refused even when one value is empty', () => {
  assert.equal(parseBridge(OK + 'prefix=/a\nprefix=\n').ok, false);
  assert.equal(parseBridge(OK + 'prefix=\nprefix=/a\n').ok, false);
});

// THE REFUSAL NAMES WHICH KEY AND WHICH KIND OF ABSENCE. Widening the value
// expression made `dir=` with nothing after it reachable, and the old message
// called that "printed neither a dir= nor a sock= line" - it had printed one. A
// reader sent to look for a line that is already there debugs the wrong file. The
// old message was also wrong in the ordinary case, where only one of the two is
// missing and it claimed both were.
test('an empty required key is reported as printed-but-empty, and named', () => {
  const r = parseBridge('dir=\nsock=/d/desk.sock\n');
  assert.equal(r.ok, false);
  assert.match(r.reason, /'dir='/, 'the refusal names the key at fault');
  assert.match(r.reason, /nothing after it/, 'and says the line WAS printed');
  // NAMED AS A REQUIREMENT, NOT AS A FAULT. The lead says both keys must be
  // printed, so `sock=` appears in every refusal; what must not appear is a CLAIM
  // about sock. An earlier version of this assertion tested for the substring and
  // passed only because the lead happened not to contain it - it was measuring
  // presence where it meant accusation.
  assert.doesNotMatch(r.reason, /'sock=' was printed|no 'sock=' line/,
    'and does not accuse the key that was fine');
});

test('an absent required key is reported as never printed, and named', () => {
  const r = parseBridge('sock=/d/desk.sock\n');
  assert.equal(r.ok, false);
  assert.match(r.reason, /no 'dir=' line was printed/);
  assert.doesNotMatch(r.reason, /'sock=' was printed|no 'sock=' line/,
    'and does not accuse the key that was fine');
});

test('when both are gone the refusal names both', () => {
  const r = parseBridge('origin=https://d.example\n');
  assert.equal(r.ok, false);
  assert.match(r.reason, /dir=/);
  assert.match(r.reason, /sock=/);
});

// THE FIXED HALF OF THE SENTENCE MUST NOT NAME ONE OF THE TWO EITHER. The first
// repair opened every refusal with "the desk has no directory to serve from", so a
// missing SOCKET produced a sentence that began by blaming the directory and then
// correctly named the socket - the same defect it was fixing, one layer up. These
// assertions are about the CONSTANT clause, which is why they read it negatively:
// what must not be there is a claim about the key that was fine.
test('a missing sock is not reported as a missing directory', () => {
  const r = parseBridge('dir=/d\n');
  assert.equal(r.ok, false);
  assert.match(r.reason, /no 'sock=' line was printed/);
  assert.doesNotMatch(r.reason, /no directory/, 'the lead must not blame the directory');
  assert.doesNotMatch(r.reason, /'dir=' was printed/, 'and must not accuse dir at all');
});

test('an empty sock is not reported as a missing directory', () => {
  const r = parseBridge('dir=/d\nsock=\n');
  assert.equal(r.ok, false);
  assert.match(r.reason, /'sock=' was printed with nothing after it/);
  assert.doesNotMatch(r.reason, /no directory/);
});
