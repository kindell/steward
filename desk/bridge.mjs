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
  // THE REFUSAL MUST NOT SAY THE WRONG ONE OF THE TWO THINGS THIS FILE IS ABOUT.
  // It used to read "printed neither a dir= nor a sock= line" in every case, which
  // was already wrong when only ONE was missing - and widening the value expression
  // above made it wrong in a second, sharper way: a `dir=` printed with nothing
  // after it now MATCHES the line, is recorded as present-and-empty, and lands
  // here. The bridge did print a line. Saying it printed none sends the reader to
  // desk-paths' emit() looking for a line that is already there.
  //
  // In a reader whose whole subject is the difference between ABSENT and
  // PRESENT-BUT-EMPTY, a message that collapses them is the one thing it must not
  // do. The state is hard to reach on purpose - dir and sock are derived, not read
  // from a key - but "it cannot happen" is the sentence this file exists to
  // disbelieve.
  if (!found.dir || !found.sock) {
    const naming = (k) => Object.prototype.hasOwnProperty.call(found, k)
      ? "'" + k + "=' was printed with nothing after it"
      : "no '" + k + "=' line was printed";
    const missing = ['dir', 'sock'].filter((k) => !found[k]);
    // AND THE FIXED HALF MUST NOT NAME ONE OF THE TWO EITHER. The first attempt at
    // this repair opened with "the desk has no directory to serve from" in every
    // case - so a missing SOCKET produced a sentence that began by blaming the
    // directory and then correctly named the socket. The same defect as the one
    // being fixed, one layer up: a constant clause asserting the wrong one of the
    // two things this reader exists to keep apart. Found by measuring all five
    // cases rather than reading the code.
    //
    // So the lead names the REQUIREMENT, which is true whichever key is at fault,
    // and everything specific lives in the named parts.
    return {
      ok: false,
      reason: 'desk-paths must print both a dir= and a sock= line: ' + missing.map(naming).join('; '),
    };
  }
  return { ok: true, found };
}

// bridgeSpawnReason - why the bridge could not be RUN, as opposed to what it
// printed. parseBridge above answers the second question; nothing answered the
// first, and the difference is not academic.
//
// MEASURED 2026-09-18, four causes through execFileSync with serve.mjs's own
// options. Only ONE of them carries its reason in e.stderr:
//
//   the bridge exits non-zero   status=78   e.stderr: 'desk-paths: no DESK_ORIGIN'
//   spawn fails                 code=ENOENT     e.stderr EMPTY
//   killed by a signal          signal=SIGKILL  e.stderr EMPTY
//   the call times out          code=ETIMEDOUT  e.stderr EMPTY
//
// serve.mjs wrote e.stderr and then one fixed sentence, so three of the four
// arrived as the same line with no cause attached. A reader of that line could
// not tell a bridge that REFUSED from one that never started, and those want
// opposite investigations: the first is the estate's configuration, the second
// is the host running out of something.
//
// That mattered on the day it was written. A desk-serve assertion had been
// failing intermittently on one platform and not another for a working day,
// and the only string that could have separated the two readings was this one.
//
// A spawn that fails for want of a file descriptor or a process slot is
// EMFILE or EAGAIN here - the shape an intermittent, load-dependent,
// platform-bound failure actually has, and the shape this function exists to
// let a reader see.
export function bridgeSpawnReason(e) {
  if (!e) return 'no error was reported';
  // ORDER IS BY HOW MUCH THE FIELD NARROWS. A code names a kernel refusal and
  // is the most specific thing available; a status means the bridge ran and
  // chose to refuse, which its own stderr will already have explained; a
  // signal means something outside both killed it.
  if (e.code) return 'the bridge could not be run: ' + e.code;
  if (typeof e.status === 'number') return 'the bridge exited ' + e.status;
  if (e.signal) return 'the bridge was killed by ' + e.signal;
  return 'the reason was not reported by the runtime';
}
