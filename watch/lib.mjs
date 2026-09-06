// watch/lib.mjs - the session watch's pure decision functions.
//
// Carried over from the estate's watchdog (2026-09-06), where every function
// here was written against a measured incident. Nothing in this file touches a
// process, a file or the network: the orchestrator observes, these functions
// decide, and each decision is a value the tests can assert on. That is what
// lets a five-minute cycle be proven without waiting five minutes.
//
// NOTHING ESTATE-SPECIFIC LIVES HERE. The hub's name, the tmux socket, the ping
// text, the alert recipient, the subject prefix and the verdict strings that the
// estate's own tools emit all arrive as arguments - the estate's data, the
// product's mechanism.
import { readFileSync } from 'node:fs'

// THE REGISTRY IS NOT PARSED HERE. The estate's copy carried its own reader of
// the session rows and the host rows - a second reader of one truth, with its
// own defaults. The watch reads through watch/bin/registry-dump, which sources
// lib/registry.sh and prints what it says (see estate.mjs). What remains here
// is the decision over what the registry answered.

// sessionScope - WHERE A SESSION STANDS RELATIVE TO THE WATCH THAT IS RUNNING.
//
// The hub's own name used to be written in as "home": everything with another
// HOST was read over ssh and alarmed from here. That was true while one machine
// was the fleet's only hub. With a hub per machine, "home" is the machine the
// watch stands ON, and a host operated by ANOTHER hub is not ours to read or
// alarm - the same OPERATOR rule the host probe uses.
//
//   local    HOST absent or equal to our hub - ps/tmux read locally, actions taken
//   remote   another host that WE operate (OPERATOR = our hub, or unknown) - read over ssh
//   foreign  another host operated by ANOTHER hub - skipped entirely
//
// An unknown operator counts as ours: a host without a hosts.d row was always
// ours before, and silently ceasing to watch it would be the same silent-health
// class as RC_LABEL="".
export function sessionScope(session, { localHub, operators = {} } = {}) {
  const host = session?.host
  if (!host || host === localHub) return 'local'
  const op = operators[host]
  if (op && op !== localHub) return 'foreign'
  return 'remote'
}

// findProcessByPanePid - LIVENESS FOR AN RC-FREE SESSION.
//
// findProcess looks for "--remote-control <label>". An RC-free session has no
// such flag at all. Merely making them visible to the watch without this would
// have swapped a false green for a false red: "no process" every third minute
// about a healthy session.
//
// THE BINDING IS THE PANE. It is the same lesson the prefix trap taught the
// supervisor: the label was only a FINDER of candidate pids, and the pane has
// carried the identity since. The pane's pid is fetched with the exact form
// `tmux list-panes -t '=<name>'`, never a prefix match.
//
// AN UNKNOWN PID GIVES null, NEVER THE NEAREST LINE. If tmux did not answer we
// do not know whether the session lives, and decide() alarms rather than
// guesses. A prefix match on the pid would be the same fault one level down:
// 12 is not 123.
export function findProcessByPanePid(psText, panePid) {
  const pid = String(panePid ?? '').trim()
  if (!/^\d+$/.test(pid)) return null
  for (const line of psText.split('\n')) {
    const m = line.match(/^\s*(\d+)\s+(\w{3} \w{3} [ \d]\d \d{2}:\d{2}:\d{2} \d{4})\s+/)
    if (!m || m[1] !== pid) continue
    return { pid: Number(m[1]), startEpoch: Date.parse(m[2]), resumed: startedResumed(line) }
  }
  return null
}

// A PROCESS STARTED WITH --resume IS ALREADY RESUMED, and the watch reads that
// off the process line, never off the pane. The supervisor respawns a dead
// session with `--resume <sid>`; the watch then sees a new startEpoch and, if
// the pane rules do not recognise the client's current glyphs, a "fresh" pane -
// and types /resume into a session that is already resumed. The picker opens
// on an empty list and the modal eats every message until a human presses Esc.
// The process line is the one fact that does not move with client releases.
function startedResumed(psLine) {
  return /\s--resume(\s|$)/.test(psLine)
}

export function findProcess(psText, rcLabel) {
  for (const line of psText.split('\n')) {
    if (!line.includes(`--remote-control ${rcLabel} `) && !line.trimEnd().endsWith(`--remote-control ${rcLabel}`)
        && !line.includes(`--remote-control "${rcLabel}"`)) continue
    // THE COMMAND MUST BE THE CLAUDE BINARY. The tmux server carries the
    // session's whole start command (label included) in its own process line
    // for as long as the server lives - without the anchor it matches, and the
    // watch sees a "living" session whose claude is dead. Measured on a session
    // host: supervision stood looking at the tmux server while the pane showed
    // a shell prompt.
    const m = line.match(/^\s*(\d+)\s+(\w{3} \w{3} [ \d]\d \d{2}:\d{2}:\d{2} \d{4})\s+\S*claude /)
    if (!m) continue
    return { pid: Number(m[1]), startEpoch: Date.parse(m[2]), resumed: startedResumed(line) }
  }
  return null
}

// paneBusy - ONE place for "is the session working right now?".
//
// The check existed in THREE copies (paneState, resumeStep, the resume engine)
// and when a client release moved 'esc to interrupt' into the permanent status
// line they broke one at a time, in turn, while the author believed the fix was
// done. A copied condition line is three bugs waiting for the same change.
//
// Looks only at the BOTTOM of the pane (the signal sits above the input box)
// and never at the footer line (the double arrow) - everything higher up is
// transcript, and a session that WRITES about 'esc to interrupt' must not match
// itself.
export function paneBusy(paneText) {
  if (paneText == null) return false
  // THE REGION IS COMPUTED IN ONE PLACE. The line here used to read
  // `.slice(-8).filter(l => !l.includes('⏵⏵'))` - literally the same facts
  // _region('bottom(8)') computes for the rule engine. Two expressions for the
  // same thing diverge at the first change, and that kind of duplicate is what
  // has cost most in this tree: a real fix applied to one of two places.
  const tail = _region(paneText, 'bottom(8)')
  return tail.includes('esc to interrupt') || tail.includes('… (')
}

// -- SIGNALS AS DATA: blocked and unreadable ---------------------------------
//
// busy, fresh and stuckText are derived in code above and stay there. They
// carry three measured incidents - the footer, the transcript matching itself,
// and the echo without a frame - and the logic that catches them is not touched.
//
// THE NEWER SIGNALS ARE DATA, for a definite reason. The pattern for the
// permission dialog is SECOND-HAND: it comes from another implementation's rule
// file, not from a pane anybody here has seen blocked. The negative half is
// verified (zero hits in six live panes); the positive half is not. A pattern
// nobody has seen live must cost one line to correct, not a code change and a
// deploy.
const _RULE_FILE = new URL('./pane-rules.json', import.meta.url)
let _RULES = null
export function paneRules() {
  if (_RULES == null) {
    _RULES = JSON.parse(readFileSync(_RULE_FILE, 'utf8')).rules
  }
  return _RULES
}

// AN UNKNOWN REGION THROWS. A misspelled region that merely yields zero hits is
// a rule that LOOKS in force and is not - the same silent half-function the rest
// of this tree refuses to accept.
function _region(paneText, spec) {
  if (spec === 'whole') return paneText
  const m = /^bottom\((\d+)\)$/.exec(spec)
  if (!m) throw new Error(`pane-rules: unknown region '${spec}'`)
  // THE FOOTER IS EXCLUDED, for the same reason as in paneBusy: permanent text
  // in the status line made every upgraded session eternally busy.
  return paneText.split('\n').slice(-Number(m[1])).filter(l => !l.includes('⏵⏵')).join('\n')
}

function _matches(text, rule) {
  const all = (rule.contains || []).every(c => text.includes(c))
  if (!all) return false
  const groups = rule.any || []
  if (groups.length === 0) return true
  return groups.some(g => g.every(c => text.includes(c)))
}

// paneSignals: run the rules and return { unreadable, blocked }.
// UNREADABLE ALWAYS WINS. A screen that cannot be interpreted must not be
// interpreted - letting another rule answer there would be guessing, which is
// the whole purpose of having the state.
export function paneSignals(paneText, rules = paneRules()) {
  let blocked = false
  for (const r of rules) {
    if (!_matches(_region(paneText, r.region), r)) continue
    if (r.state === 'unreadable') return { unreadable: true, blocked: null }
    if (r.state === 'blocked') blocked = true
  }
  return { unreadable: false, blocked }
}

export function paneState(paneText, rules = undefined) {
  if (paneText == null) return null
  // UNREADABLE IS MEASURED FIRST, and when it fires NOTHING else is measured.
  // The fields are set to null - not false - because null means "not measured"
  // in this house, while false would be a claim we have no cover for.
  const _sig = paneSignals(paneText, rules === undefined ? paneRules() : rules)
  if (_sig.unreadable) {
    return { busy: null, fresh: null, stuckText: null, blocked: null, unreadable: true }
  }
  // BUSY DETECTION LOOKS ONLY AT THE BOTTOM of the pane, never at the footer.
  //
  // Two distinct traps, both observed the same day:
  // 1. THE FOOTER. A client release put 'esc to interrupt' PERMANENTLY in the
  //    status line. A blind includes() therefore makes EVERY upgraded session
  //    eternally "busy" - the watch silently stops detecting stuck input,
  //    redelivering bus mail and auto-resuming. It degrades without an error.
  // 2. THE TRANSCRIPT. The pane holds the conversation's own text, and a session
  //    that WRITES about 'esc to interrupt' matches itself. The hub's own pane
  //    had five hits, two of which were this very reasoning.
  //
  // The signal sits right above the input box, i.e. in the last lines. The
  // footer (double arrow) is excluded, and everything higher is transcript.
  const busy = paneBusy(paneText)
  const fresh = paneText.includes('/remote-control is active') && !paneText.includes('⏺')
  let stuckText = null
  if (!busy) {
    // ONLY the input box counts: the line '❯ text' framed by rule lines on
    // BOTH sides. Sent messages are echoed in the transcript with the same
    // prefix but without frames - matching those produced the redelivery loop
    // (delivered messages "stuck" again in the watch's eyes).
    const lines = paneText.split('\n')
    const border = /^\s*─+\s*$/
    for (let i = 1; i < lines.length - 1; i++) {
      if (!/^❯ .*\S/.test(lines[i])) continue
      if (border.test(lines[i - 1]) && border.test(lines[i + 1])) {
        stuckText = lines[i].replace(/^❯\s*/, '').trim()
      }
    }
  }
  return { busy, fresh, stuckText, blocked: _sig.blocked, unreadable: false }
}

// resumeStep: a pure step machine for the /resume procedure. Given a fresh
// capture-pane text, return the next step the orchestrator should take. The
// orchestrator loops: fresh capture -> resumeStep -> act -> fresh capture ...
// (at most six iterations, then abort). 'escape' closes a modal and aborts.
export function resumeStep(paneText) {
  if (paneText == null || paneText.trim() === '') return { action: 'abort', reason: 'empty or unknown pane' }
  // THE SAME FOOTER TRAP as in paneState: with the permanent status line a
  // blind includes() aborts EVERY resume as "busy" - freshly started sessions
  // are then never resumed and stand empty. Observed right after three sessions
  // were restarted: all three refused a resume on an empty start screen.
  if (paneBusy(paneText)) return { action: 'abort', reason: 'the session is busy' }
  if (/^\s*❯ 1\. Resume from summary/m.test(paneText)) return { action: 'press-enter', reason: 'summary dialog visible' }
  // AN EMPTY PICKER IS CLOSED, NOT ENTERED: Enter on "No conversations found"
  // does nothing, and an abort that leaves the modal open leaves the session
  // deaf. Measured on a hub session: an hour without input until a human's Esc.
  if (paneText.includes('No conversations found')) return { action: 'escape', reason: 'the resume picker is empty - nothing to resume' }
  if (paneText.includes('Ctrl+A to show all projects')) return { action: 'press-enter', reason: 'resume picker visible' }
  if (paneText.includes('⏺')) return { action: 'done', reason: 'conversation visible - resumed' }
  if (paneText.includes('/remote-control is active')) return { action: 'type-resume', reason: 'start screen (fresh)' }
  return { action: 'abort', reason: 'unknown pane state' }
}

// THE PING TEXT IS THE ESTATE'S, not a constant here. The watch recognises a
// bus ping in an input box by EXACT string comparison, to tell it from real
// user input; a stuck ping is contentless and durably queued, so it is
// redelivered or cleared silently and must NEVER produce an alarm. The text
// itself comes from the registry (PING_MSG) and is handed to decide() by the
// orchestrator - the same text the bus types into the pane.

// decide - the per-session decision.
//
// prev: {startEpoch, missingAlerted?, autoResumedFor?, blocked?,
//        stuck?: {text, alerted, reinjected?}}
// opts: { pingText, subjectPrefix, attachHint }
//   pingText      the bus ping, for recognising a stuck ping (see above)
//   subjectPrefix the alert subject's prefix - the estate's, so an inbox still
//                 says whose watch is speaking
//   attachHint    the command a human runs to reach the session (the estate
//                 knows its socket name; this file does not)
//
// The stuck flow is action-first: text stuck for two checks in a row => action
// 'reinject' (the orchestrator redelivers and sets reinjected AFTER a successful
// attempt - the busy guard may postpone it). If the same text is still there
// EVEN after redelivery: real text => one alert; a bus ping => 'clearStuck'.
export function decide(prev = {}, obs, nowIso, opts = {}) {
  const pfx = opts.subjectPrefix ?? 'watch'
  const alerts = []
  const actions = []
  const next = { ...prev }
  const s = obs.name

  // UNMEASURABLE IS NOT ABSENT. If the session is owned by somebody else, the
  // hub's ssh reaches that account through a BOUND KEY that answers rc 0
  // without running the command - ps yields relay noise, findProcess finds
  // nothing, and proc is null without any measurement having been made. The
  // same answer a healthy session would have given. The latch is left ALONE:
  // an unmeasurable run must not acknowledge away the next real gap. The same
  // rule as claudePin, brandedBrowsers and hostAlerts.
  if (obs.procUnknown) return { alerts, actions, next }

  if (!obs.proc) {
    if (!prev.missingAlerted) {
      alerts.push({ subject: `${pfx}: ${s} has no process`, body: `The session ${s} has no claude process (${nowIso}). The supervisor may be stuck.` })
      next.missingAlerted = true
    }
    return { alerts, actions, next }
  }
  next.missingAlerted = false

  // UNREADABLE COUNTS AS UNKNOWN. A pane showing a dialog cannot be interpreted,
  // exactly like a pane we could not capture at all - the difference is only why.
  //
  // AND THE EARLY RETURN CARRIES MORE THAN IT SEEMS TO: without it the run falls
  // through to the closing branch, where stuckText is null and next.stuck is
  // therefore reset. The memory of an unsent line would be erased the moment
  // somebody opened the resume menu, and the redelivery would never happen.
  if (obs.pane == null || obs.pane.unreadable) {
    return { alerts, actions, next }
  }

  if (prev.startEpoch && obs.proc.startEpoch !== prev.startEpoch) {
    // A RESPAWN WITH --resume IS THE SUPERVISOR'S RESUME, DONE. Whatever the
    // pane looks like, typing /resume on top of it is the failure described at
    // startedResumed: bless it and leave the keyboard alone.
    if (obs.pane.fresh && !obs.proc.resumed) {
      // respawned and standing on the start screen: let the orchestrator
      // auto-resume - at most one attempt per process incarnation, even if the
      // attempt aborts.
      if (next.autoResumedFor !== obs.proc.startEpoch) {
        actions.push({ type: 'resume', session: s })
        next.autoResumedFor = obs.proc.startEpoch
      }
      return { alerts, actions, next } // do not bless until resumed
    }
    next.startEpoch = obs.proc.startEpoch // resumed/active -> bless
  } else if (!prev.startEpoch) {
    next.startEpoch = obs.proc.startEpoch
  }

  // BLOCKED: THE SESSION IS WAITING FOR A HUMAN.
  //
  // Unacknowledged mail used to alarm after fifteen minutes - but a blocked
  // session CANNOT acknowledge, it stands at a question. The clock measured the
  // wrong thing and late, and said "something is missing" when the answer was
  // "something is needed".
  //
  // THE CADENCE IS THE STUCK PATTERN'S: the first observation notes, the second
  // acts. The watch cycles every five minutes, so the alarm comes after 5-10
  // minutes. An alarm on the FIRST observation would have been noise every time
  // the human is sitting right there answering - the normal case, not the
  // exception.
  //
  // THE MEMORY IS RESET when the session stops waiting. Without that the first
  // alarm is the only one ever, and the next time somebody is left standing it
  // does not show: the same silent degradation the footer gave.
  if (obs.pane.blocked) {
    if (prev.blocked && !prev.blocked.alerted) {
      const hint = opts.attachHint ? `\n\nOpen it in the app or run:\n\n  ${opts.attachHint}` : ''
      alerts.push({ subject: `${pfx}: ${s} is waiting for an answer`, body: `The session ${s} stands at a question and is waiting for a human - it has done so for at least two watch cycles (${nowIso}).\n\nIt cannot acknowledge mail or continue working until somebody answers.${hint}` })
      next.blocked = { alerted: true }
    } else {
      next.blocked = prev.blocked ?? { alerted: false }
    }
  } else {
    next.blocked = null
  }

  const st = obs.pane.stuckText ?? null
  if (st) {
    if (prev.stuck && prev.stuck.text === st) {
      const isPing = opts.pingText != null && st === opts.pingText
      if (!prev.stuck.reinjected) {
        actions.push({ type: 'reinject', session: s, text: st, isPing })
        next.stuck = { ...prev.stuck }
      } else if (isPing) {
        actions.push({ type: 'clearStuck', session: s })
        next.stuck = { ...prev.stuck }
      } else if (!prev.stuck.alerted) {
        alerts.push({ subject: `${pfx}: redelivery failed in ${s}`, body: `The input box in ${s} still holds the same unsent text EVEN after the watch's automatic redelivery:\n\n"${st}"\n\nReinject it manually according to the procedure (the text above is the source if the box gets cleared). (${nowIso})` })
        next.stuck = { text: st, reinjected: true, alerted: true }
      }
    } else {
      next.stuck = { text: st, alerted: false }
    }
  } else {
    next.stuck = null
  }
  return { alerts, actions, next }
}

// fleetHttp: a pure decision for the reachability of an HTTP service that binds
// its address at START - if the machine's address changes while it runs, the
// process is silently unreachable (it happened; the service lay dead for an
// unknown time until a review found it). Checked from outside every cycle:
// unreachable => respawn action (kill; the supervisor restarts it with a fresh
// lookup); still unreachable AFTER the respawn => ONE alert (deduplicated until
// reachable again).
// prev: {killed?, alerted?} - fully reset when the service answers.
export function fleetHttp(prev = {}, reachable) {
  if (reachable) return { action: null, alert: false, next: {} }
  if (!prev.killed) return { action: 'respawn', alert: false, next: { killed: true } }
  if (!prev.alerted) return { action: null, alert: true, next: { killed: true, alerted: true } }
  return { action: null, alert: false, next: prev }
}

// Unacknowledged bus mail: at 15 minutes the recipient is PINGED again (a
// contentless ping, busy-gated - costs nothing); mail to the human first at 45
// minutes, when the re-pings have demonstrably not helped (a genuinely stuck
// session). Mailing the human at 15 minutes made them the sessions' secretary.
export const BUS_ALERT_THRESHOLD_SEC = 15 * 60
export const BUS_ESCALATE_THRESHOLD_SEC = 45 * 60

// busAlert: the pure decision for the bus watch. Given the watch state for ONE
// recipient (prev), its unacknowledged inbox files (files, any order - the
// oldest = the largest ageSec wins, regardless of the order given) and the
// current epoch, decide whether an alert goes out.
//
// files: [{name, ageSec, from, text}] - as bus_list_unacked builds them (name =
// the inbox file name, unique per record).
//
// Dedup: one alert per oldest file - as long as the same file stays the oldest
// (unacknowledged) no new alert is sent. When that file is acked or disappears
// and another becomes the oldest (or the inbox empties), the state resets and
// the next threshold crossing alarms anew.
//
// Returns: { alert: null | {count, oldestAgeMin, from, text}, reping: bool,
//            next } - alert is raw data (no finished mail text); the caller
// knows the recipient's name and builds subject/body itself (cf. decide(),
// which has obs.name). reping=true means "ping the recipient again now" -
// every cycle while the oldest record is past the 15-minute threshold (the ping
// is contentless and busy-gated, so repeating it is free). Mail dedup per oldest
// file as before, but only at the escalation threshold.
export function busAlert(prev = {}, files = [], nowEpoch) {
  if (!files.length) return { alert: null, reping: false, next: { name: null } }
  const oldest = files.reduce((a, b) => (b.ageSec > a.ageSec ? b : a))
  if (oldest.ageSec <= BUS_ALERT_THRESHOLD_SEC) return { alert: null, reping: false, next: prev }
  if (oldest.ageSec <= BUS_ESCALATE_THRESHOLD_SEC) return { alert: null, reping: true, next: prev }
  if (prev && prev.name === oldest.name) return { alert: null, reping: true, next: prev }
  const text = (oldest.text ?? '').slice(0, 100)
  return {
    alert: { count: files.length, oldestAgeMin: Math.floor(oldest.ageSec / 60), from: oldest.from ?? '', text },
    reping: true,
    next: { name: oldest.name },
  }
}

// malformedAlert: the pure decision for UNREADABLE bus mail. The reader moves a
// record it cannot parse to malformed/ instead of done/ - but the alarm for
// unacknowledged mail (busAlert above) looks only at the INBOX, so without this
// a malformed file would merely have changed hiding place: once buried in done,
// now parked in malformed, silent either way.
//
// A malformed file must NEVER arise - the relay writes atomically (mktemp + ln),
// so a half file never reaches the inbox. The threshold is therefore zero: a
// single file is an alert, regardless of age. Dedup on the COUNT: alarm only
// when more have arrived than last reported, so a lingering file does not mail
// every cycle but a new one does. When malformed/ is cleaned (count -> 0) the
// state resets and the next file alarms again.
export function malformedAlert(prevCount = 0, fileCount = 0) {
  if (fileCount > prevCount) {
    return { alert: { count: fileCount }, next: fileCount }
  }
  return { alert: null, next: fileCount }
}

// parseBusDump: a pure parser for the ssh dump of a remote session's bus
// directory. The watch runs on the hub but a remote session's inbox lives on
// its own host - the watch once read its OWN local file system for every
// session, so `readdirSync(~/.config/agent-bus/<remote>/inbox)` gave ENOENT,
// which `catch` swallowed to []. The central 15-minute alarm had therefore
// never applied to a single remote session, and the malformed check inherited
// the blindness. "Cannot see" indistinguishable from "empty".
//
// The remote fetch now runs over ssh as the owner (the same path as ps, crossing
// no 0750 boundary because it runs AS the owner), and the dump has the form:
//   ===F===\n<json>\n===F===\n<json>\n...===MALFORMED===\n<count>
// or a bare "NODIR" if the bus directory does not exist yet (no mail ever - not
// an error). Returns: { files:[{name,ts,from,text,ageSec}], malformedCount,
// noDir }. name is synthetic (the index) - busAlert dedups on it, and a remote
// file has no stable file name in the dump, so the index suffices for "the same
// oldest".
export function parseBusDump(stdout, nowEpoch) {
  const s = String(stdout ?? '')
  if (s.trim() === 'NODIR') return { files: [], malformedCount: 0, noDir: true }
  // EACCES: the directory exists but could not be read. Must be TOLD APART from
  // empty - that is the whole purpose. Signalled as eacces, handled as
  // unreachability (an alert).
  if (s.trim() === 'EACCES') return { files: [], malformedCount: 0, eacces: true }
  const [inboxPart, mfPart = ''] = s.split('===MALFORMED===')
  const malformedCount = parseInt(mfPart.trim(), 10) || 0
  const files = []
  const chunks = inboxPart.split('===F===').map(c => c.trim()).filter(Boolean)
  chunks.forEach((chunk, i) => {
    let from = '', text = '', ts = 0
    try {
      const d = JSON.parse(chunk)
      from = d.from ?? ''; text = d.text ?? ''
      if (Number.isFinite(d.ts)) ts = d.ts
    } catch { /* a broken file in the dump - still counts as mail, age unknown */ }
    files.push({ name: `remote-${i}`, from, text, ts, ageSec: nowEpoch - ts })
  })
  return { files, malformedCount, noDir: false }
}

// browserActivity: a pure merge of CDP observations into activity state.
// A review's critique: letting EACH DOMAIN decide whether it wants to report
// activity is fragile, because the judgement "this domain only has sporadic
// human use" can flip within the hour (they proved it on themselves the same
// evening). So the watch observes CENTRALLY instead: an established TCP
// connection to a profile's debug port from anything OTHER than the browser
// itself means somebody is driving the profile - whether an MCP server, a
// domain script or a one-off client.
//
// obs: {<domain>: <count of non-browser clients>} from this cycle.
// prev/return: {<domain>: {lastSeen: <ISO>, samples: <n>}}
// This is a FLOOR, not exact: five-minute sampling misses short bursts. A
// domain that wants the exact moment writes its own trace log - but NO
// automation reads that, and the sleep decision rests solely on this
// measurement.
export function browserActivity(prev = {}, obs = {}, nowIso) {
  const next = { ...prev }
  for (const [domain, clients] of Object.entries(obs)) {
    const before = next[domain] ?? { lastSeen: null, samples: 0 }
    next[domain] = clients > 0
      ? { lastSeen: nowIso, samples: before.samples + 1 }
      : { ...before }
  }
  return next
}

// claudePin: the pin against the current client version. A desktop OS keys its
// data-protection grants on the RESOLVED binary path, so every new version is a
// new "app" without a grant - hence a hard link at a stable path, which all the
// hub's machinery starts through.
//
// THE PROBLEM IT SOLVES: the pin was updated by a script run by hand. It was
// found nine days stale after an upgrade - nine days of needless prompts,
// discovered only because somebody asked. A ritual that must be performed by
// hand sooner or later is not performed.
//
// SELF-HEALING, like fleetHttp: the drift is repaired (the pin script runs),
// and only when the repair has NOT helped does an alert go out. Re-pinning
// touches no running process - they hold their own inode open; it is the NEXT
// start that gets the new binary.
//
// obs: {stableInode, currentInode} - null/undefined when something is missing.
// prev/return: {repaired?, alerted?} - fully reset when they match again.
export function claudePin(prev = {}, obs = {}) {
  const { stableInode, currentInode } = obs
  // Cannot be judged (a missing link or a missing pin) - do not touch the state,
  // and do not alarm: an observation that could not be made is not a fault.
  if (!stableInode || !currentInode) return { action: null, alert: false, next: prev }
  if (stableInode === currentInode) return { action: null, alert: false, next: {} }
  if (!prev.repaired) return { action: 'repin', alert: false, next: { repaired: true } }
  if (!prev.alerted) return { action: null, alert: true, next: { repaired: true, alerted: true } }
  return { action: null, alert: false, next: prev }
}

// unpinnedSessions: which sessions run a binary OTHER than the pinned one. They
// keep prompting until restarted, and a restart costs their live conversation -
// so this is an OBSERVATION, never an action. The watch must not restart a
// session to get rid of a prompt.
export function unpinnedSessions(psText, stablePath) {
  const out = []
  for (const line of psText.split('\n')) {
    // DO NOT ANCHOR ON THE PID: the ps line carries lstart between pid and
    // command ("PID Mon  3 09:41:02 2026 /path/claude ..."). A first test used
    // an invented format without lstart and therefore passed against a regex
    // that never matched live - the same trap as the rest of that day, in a test.
    const m = line.match(/(\S*claude) --remote-control (\S+(?: \S+)*?) --permission-mode/)
    if (!m) continue
    if (m[1] !== stablePath) out.push({ bin: m[1], rcLabel: m[2] })
  }
  return out
}

// brandedBrowsers: are the domains' own browser bundles built against the
// browser that is actually running? The clones are stamped with the version
// they were made from. At a browser upgrade they go stale, the launcher falls
// back on the original, and every icon becomes the generic one again - silently.
//
// The same drift as the client pin, which lay nine days wrong because the
// ritual was performed by hand. Self-healing per the fleetHttp pattern: rebuild
// first, alarm only if the rebuild did not help.
//
// obs: {current, stamps: {<domain>: <version|null>}}
export function brandedBrowsers(prev = {}, obs = {}) {
  const { current, stamps } = obs
  if (!current || !stamps || !Object.keys(stamps).length) return { action: null, alert: false, next: prev }
  const stale = Object.entries(stamps).filter(([, v]) => v !== current).map(([d]) => d)
  if (!stale.length) return { action: null, alert: false, next: {} }
  if (!prev.rebuilt) return { action: 'rebrand', alert: false, next: { rebuilt: true, stale } }
  if (!prev.alerted) return { action: null, alert: true, next: { rebuilt: true, alerted: true, stale } }
  return { action: null, alert: false, next: prev }
}

// ---------------------------------------------------------------------------
// jobAlerts / hostAlerts: the cord between measurement and alarm.
//
// Two measuring tools had been built - job delivery and host status - which
// were both useful only if somebody opened the status page. Every fault that
// week was of the same kind: a gate silent for weeks, a router log empty for
// eleven days, the watch dead after a version upgrade. None of them was a
// MEASUREMENT fault. Something measured correctly and nobody looked.

// jobAlerts: which jobs are mailed about?
//
// THE VERDICT STRINGS ARE THE ESTATE'S. The job probe emits them in its own
// words; this function only needs to know which of them mean "broken" and
// which prefix a failed run carries. They arrive in opts:
//   opts.broken   list of verdict strings that mean broken
//   opts.rcPrefix prefix of the verdict for a run that exited non-zero
//
// AN UNDECLARED DELIVERY DOES NOT ALARM. It is a standing debt, not an event -
// a mail every five minutes about the same debt teaches the reader to delete
// the watch's mail unread. It shows on the page, the right place for something
// that is true all the time.
//
// DEDUP PER JOB AND VERDICT: the same job in the same broken state alarms once.
// Changing to ANOTHER broken state is new information and alarms again (a run
// that went from "no delivery" to "rc=1" has changed character). A healthy job
// drops out of the state entirely, so its next failure is a new alert.
//
// A KNOWN CAUSE ALARMS EVEN WHEN THE JOB WENT WELL. A dead token can stand in
// the log while the run exits 0: the job completes, the delivery exists - but
// the data has holes. Alarming only on broken verdicts would have left exactly
// that silence in place. The dedup is therefore on verdict AND cause together.
//
// prev/return next: {<job>: <the verdict|cause we alarmed about>}
export function jobAlerts(prev = {}, jobs = [], opts = {}) {
  const brokenList = opts.broken ?? ['never run', 'NO delivery found', 'RAN WITHOUT DELIVERY']
  const rcPrefix = opts.rcPrefix ?? 'last run exited rc='
  const broken = v => brokenList.includes(v) || v.startsWith(rcPrefix)
  const alerts = []
  const next = {}
  for (const j of jobs) {
    const v = j.verdict ?? ''
    const cause = j.cause ?? ''
    if (!broken(v) && !cause) continue
    const key = `${v}|${cause}`
    next[j.job] = key
    if (prev[j.job] === key) continue
    alerts.push({ job: j.job, verdict: v, note: j.note ?? '', cause, lastRun: j.last_run ?? 0 })
  }
  return { alerts, next }
}

// Unmeasured must persist before it alarms. A single network failure against an
// address is not news; three cycles in a row (about 15 minutes) is. Broken, on
// the other hand, alarms at once - there the uncertainty is not the problem.
export const HOST_UNKNOWN_CYCLES = 3

// hostAlerts: addresses that do not answer, certificates about to expire, disks
// filling up - and what could not be measured.
//
// THREE CATEGORIES WITH DIFFERENT WORDS. "The certificate could not be read" is
// not "the certificate has expired", and a mail that mixes them teaches the
// reader to ignore both.
//
// THE VERDICT STRINGS ARE THE ESTATE'S, as in jobAlerts:
//   opts.noAnswer   the http verdict for an address that does not answer
//   opts.httpPrefix the http verdict prefix for an error code
//   opts.capacity   a regex over the capacity verdict that means a full disk or memory
//
// prev/return next: {alerted: {<key>: <the value we alarmed about>},
//                    unknown: {<key>: <cycles in a row>}}
export function hostAlerts(prev = {}, snapshot = {}, opts = {}) {
  const noAnswer = opts.noAnswer ?? 'NO ANSWER'
  const httpPrefix = opts.httpPrefix ?? 'HTTP '
  const capacity = opts.capacity ?? /DISK|MEMORY/
  const prevAlerted = prev.alerted ?? {}
  const prevUnknown = prev.unknown ?? {}
  const alerts = []
  const alerted = {}
  const unknown = {}

  // once: alarm once per (key, value). The value is part of it because a change
  // from one fault to another is new information, not a repetition.
  const once = (key, value, mk) => {
    alerted[key] = value
    if (prevAlerted[key] !== value) alerts.push(mk())
  }
  // sustained: alarm ONCE, at exactly the Nth cycle in a row. After that the
  // counter grows without further alerts; when it becomes measurable again the
  // key drops out of the state.
  const sustained = (key, mk) => {
    const n = (prevUnknown[key] ?? 0) + 1
    unknown[key] = n
    if (n === HOST_UNKNOWN_CYCLES) alerts.push(mk())
  }

  for (const h of snapshot.hosts ?? []) {
    for (const e of h.endpoints ?? []) {
      const key = `${h.host}|${e.addr}`
      const v = e.httpVerdict ?? ''
      if (v === noAnswer || v.startsWith(httpPrefix)) {
        once(`${key}|http`, v, () => ({ kind: 'http', host: h.host, addr: e.addr, owner: e.owner, detail: v }))
      }
      if (e.certStatus === 'warn' || e.certStatus === 'expired') {
        once(`${key}|cert`, e.certStatus, () => ({ kind: 'cert', host: h.host, addr: e.addr, owner: e.owner, detail: e.certVerdict ?? '' }))
      }
      if (e.certStatus === 'unknown') {
        sustained(`${key}|cert`, () => ({ kind: 'unmeasured', host: h.host, addr: e.addr, owner: e.owner, detail: 'the certificate could not be read' }))
      }
    }
    const capKey = `${h.host}|capacity`
    if (h.diskPct == null) {
      sustained(capKey, () => ({ kind: 'unmeasured', host: h.host, addr: 'the machine', detail: 'the capacity could not be measured (ssh does not answer)' }))
    } else if (capacity.test(h.capacityVerdict ?? '')) {
      once(capKey, h.capacityVerdict, () => ({ kind: 'capacity', host: h.host, addr: 'the machine', detail: h.capacityVerdict }))
    }
  }
  return { alerts, next: { alerted, unknown } }
}

// groupJobAlerts: seven jobs that die of the SAME cause are ONE event.
//
// An account's spending cap kicked in once and seven jobs in four domains died
// within a morning. With alerts on, the human would have received seven mails
// about the same thing - and seven mails that say the same thing are read as
// one, or none.
//
// Early warning cannot be built: the client exposes no consumption figure.
// What CAN be done is not to repeat oneself when it happens.
//
// Only the SAME known cause is grouped. Jobs without a cause, or with one each,
// are different events and get their own mails - otherwise a grouping would
// have hidden that two unrelated things broke at the same time.
export function groupJobAlerts(alerts = []) {
  const byCause = new Map()
  const singles = []
  for (const a of alerts) {
    if (!a.cause) { singles.push(a); continue }
    if (!byCause.has(a.cause)) byCause.set(a.cause, [])
    byCause.get(a.cause).push(a)
  }
  const groups = []
  for (const [cause, list] of byCause) {
    if (list.length >= 2) groups.push({ cause, jobs: list.map(x => x.job) })
    else singles.push(list[0])
  }
  return { groups, singles }
}

// authExpired: does a session's pane show that its login has expired?
//
// TWO sessions were logged out within thirteen minutes while every scheduled
// job ran flawlessly. The difference is process lifetime: jobs are fresh
// processes that read the credentials file at every start; sessions had held
// their copy for days.
//
// DISCOVERED BY CHANCE - somebody happened to ask. Without this a session can
// stand silently logged out for hours: it answers a prompt with "Login expired"
// instead of doing anything, and nothing anywhere notices.
//
// THE REMEDY IS CHEAP (one /login, no restart, no lost conversation) but only
// if somebody KNOWS. Hence an alert and not self-healing: the watch must not
// run /login for the human - it is an act of authentication.
//
// Looks only at the BOTTOM of the pane, for the same reason as paneBusy: the
// line stays in the transcript forever after it happened, and a session that
// WRITES about logouts (this text, for instance) must not match itself.
export function authExpired(paneText) {
  if (paneText == null) return false
  return paneText.split('\n').slice(-25)
    .some(l => /^⏺ Login expired/.test(l.trim()))
}

// authAlerts: pure decision. Alarms ONCE per session until it answers again -
// otherwise a logged-out session would mail every five minutes.
// prev/return: {<session>: true}
export function authAlerts(prev = {}, observations = []) {
  const alerts = []
  const next = {}
  for (const o of observations) {
    if (!o.expired) continue
    next[o.name] = true
    if (!prev[o.name]) alerts.push({ session: o.name })
  }
  return { alerts, next }
}

// How many cycles in a row a profile must be untouched before it may sleep. The
// watch cycle is five minutes, so 12 = one hour. The threshold is deliberately
// much longer than a job's run time: a scanner was measured making MANY separate
// connections with seconds between them, and a profile must never fall asleep
// in the middle of a job.
export const BROWSER_IDLE_CYCLES = 12

// browserSleep: which browser profiles should sleep, and which should wake?
//
// THE DECISION RESTS ON ESTABLISHED CONNECTIONS, NOT ON A TIMESTAMP. The watch
// counts external clients against each profile's debug port itself. That is a
// direct measure of what is HAPPENING - unlike an activity file, which is a
// report of what has happened. The difference is decisive: the condition for
// sleeping becomes "nobody is connected", not "it has been a while", and then a
// profile structurally cannot fall asleep while somebody uses it.
//
// A review pointed out why it matters: a scanner marks activity and connects in
// the same breath, without retry. A wake-up triggered by a signal file would
// never have been in time - so profiles are woken SYNCHRONOUSLY before the job
// instead, and sleep is only for profiles nobody touches.
//
// obs: {<domain>: <count of external clients>}
// prev/return: {<domain>: {idle: <cycles in a row>, suspended: bool}}
export function browserSleep(prev = {}, obs = {}, opts = {}) {
  const cycles = opts.idleCycles ?? BROWSER_IDLE_CYCLES
  const keep = new Set(opts.neverSleep ?? [])
  const suspend = []
  const next = {}
  for (const [domain, clients] of Object.entries(obs)) {
    const before = prev[domain] ?? { idle: 0, suspended: false }
    if (clients > 0) {
      // Somebody is using it. ALWAYS reset - even if we believed it was asleep,
      // because then we were wrong and it is evidently up again.
      next[domain] = { idle: 0, suspended: false }
      continue
    }
    if (before.suspended) { next[domain] = before; continue }  // already asleep
    const idle = before.idle + 1
    if (idle >= cycles && !keep.has(domain)) {
      suspend.push(domain)
      next[domain] = { idle, suspended: true }
    } else {
      next[domain] = { idle, suspended: false }
    }
  }
  return { suspend, next }
}

// A DELIBERATE RESTART IS NOT A CRASH - but only while the intent is fresh.
//
// The watch cannot tell "somebody restarted it on purpose" from "it died"
// without a marker, and then does the only thing it can: auto-resumes the
// thread and mails the human. It happened when the hub was restarted to correct
// its own label - the restart succeeded, but the fresh start that was the whole
// purpose never came and the alarm was false. The same reasoning the pause marker
// already carries elsewhere: THE MARKER IS THE INTENT, NOT THE STATE.
//
// THE CAP IS WHAT MAKES IT SAFE. A marker left behind silences the next REAL
// crash, i.e. exactly what the watch exists for. An intent ages: after maxMs it
// is forgotten, not current, and should no longer speak for anybody.
//
// A pure function with the time passed in - otherwise the cap cannot be tested
// without waiting fifteen minutes.
export function restartIntentFresh(mtimeMs, nowMs, maxMs) {
  if (!Number.isFinite(mtimeMs) || !Number.isFinite(nowMs) || !Number.isFinite(maxMs)) return false
  // A future mtime: clock skew, or a marker somebody wrote wrong. Count it as
  // fresh - an intent that looks too young must not be read as too old.
  if (mtimeMs > nowMs) return true
  return nowMs - mtimeMs <= maxMs
}
