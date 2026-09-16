// desk/bridge.mjs - reading what desk/bin/desk-paths printed.
//
// ITS OWN FILE BECAUSE IT IS THE ONLY PART OF THE STARTUP PATH THAT CAN BE
// TESTED WITHOUT STARTING A SERVER. serve.mjs runs the bridge itself and the
// suite drives it as a child process; that is right for what it proves, but it
// means the parser can only be exercised through output the bridge is willing
// to produce - and the bridge now refuses to produce the shape this file
// guards against. A pure function with its own suite is the honest way to
// prove a guard whose input the rest of the system will not generate.
//
// WHY A REPEATED KEY IS A REFUSAL AND NOT A PREFERENCE. The bridge is
// line-oriented, and the reader this replaces kept the LAST line for a key:
// `found[m[1]] = m[2]`. Measured 2026-09-10 on the shipped bridge, before it
// was hardened: an estate value carrying a newline emitted a SECOND `origin=`
// line after the real one, and the front would have started on the second -
// no error, no journal line, a desk running on an origin nobody typed. The
// bridge now refuses to emit such a value, which closes that route. This
// closes the shape.
//
// Preferring the first line would be no better than preferring the last. Two
// lines for one key mean the bridge produced something nobody intended, and a
// reader that silently picks one is how that stays invisible.

const KEYS = ['dir', 'sock', 'origin', 'providers', 'session_key', 'prefix'];
// `(.*)` AND NOT `(.+)`, BECAUSE AN EMPTY VALUE IS A VALUE. The expression used to
// demand at least one character, so an emitted `prefix=` did not match the line at
// all, was skipped, and reached the caller as an ABSENT key. That is exactly wrong
// for the one key whose empty string is meaningful: a desk on its own hostname
// mounts at the root, where `/desk` is repetition in every link and every address
// bar. Absent means "the estate said nothing, apply the default"; present and empty
// means "the estate chose the root". A reader that cannot tell them apart silently
// converts the second into the first - and the front then answers somewhere the
// redirect URI registered with the provider does not point. No error, no journal
// line, and the breakage lands on the people logging in rather than on us.
//
// THE REQUIRED PAIR IS NOT WEAKENED BY THIS. dir and sock are checked below for
// truthiness, so an empty one of them is still no answer; and the duplicate guard
// keys off the property being present, not off its value, so widening the value
// expression opens no route past it. Both are pinned by their own tests.
const LINE = new RegExp('^(' + KEYS.join('|') + ')=(.*)$');

// parseBridge(out) -> { ok: true, found } | { ok: false, reason }
// `reason` is a complete operator-facing sentence; the caller decides how to
// report and with which exit code.
export function parseBridge(out) {
  const found = {};
  for (const line of String(out).split('\n')) {
    const m = line.match(LINE);
    if (!m) continue;
    const [, key, value] = m;
    if (Object.prototype.hasOwnProperty.call(found, key)) {
      return {
        ok: false,
        reason: 'desk-paths printed the key \'' + key + '\' more than once; '
              + 'one of them is not what the estate says, and choosing either '
              + 'would hide that',
      };
    }
    found[key] = value;
  }
  if (!found.dir || !found.sock) {
    return { ok: false, reason: 'desk-paths printed neither a dir= nor a sock= line' };
  }
  return { ok: true, found };
}
