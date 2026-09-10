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
