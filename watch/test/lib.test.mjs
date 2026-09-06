// watch/test/lib.test.mjs - the session watch's decision functions, specified.
//
// Carried over from the estate's suite (2026-09-06). Every test here is a
// measured incident or a control group for one; the fixture names are neutral
// on purpose, and the estate's ping text, subject prefix and verdict strings
// are passed in as the estate's data rather than assumed.
import { test } from 'node:test'
import assert from 'node:assert/strict'
import { sessionScope, findProcess, findProcessByPanePid, paneState, decide, resumeStep, busAlert, malformedAlert, parseBusDump, fleetHttp, browserActivity, claudePin, unpinnedSessions, brandedBrowsers, jobAlerts, groupJobAlerts, hostAlerts, authExpired, authAlerts, browserSleep, restartIntentFresh } from '../lib.mjs'

const PING = '[bus] you have mail - read your inbox (the command is in your instructions)'
const OPTS = { pingText: PING, subjectPrefix: 'hub-one watch', attachHint: 'tmux -S ~/.tmux/hub-one.sock attach -t <session>' }

test('fleetHttp: reachable => no action, state reset', () => {
  const r = fleetHttp({ killed: true, alerted: true }, true)
  assert.deepEqual(r, { action: null, alert: false, next: {} })
})

test('fleetHttp: unreachable => respawn first, mail only if the respawn did not help, then dedup', () => {
  const r1 = fleetHttp({}, false)
  assert.equal(r1.action, 'respawn')
  assert.equal(r1.alert, false)
  const r2 = fleetHttp(r1.next, false)
  assert.equal(r2.action, null)
  assert.equal(r2.alert, true)
  const r3 = fleetHttp(r2.next, false)
  assert.equal(r3.alert, false) // dedup
  const r4 = fleetHttp(r3.next, true)
  assert.deepEqual(r4.next, {}) // reachable again => full reset
})

const PS = `  123 Tue Jul 22 09:00:00 2026 /opt/agent/.local/bin/claude --remote-control Hub: alpha --permission-mode bypassPermissions
  456 Mon Jul 21 23:52:19 2026 /opt/agent/.local/bin/claude --remote-control Hub: beta --permission-mode bypassPermissions`






// AN RC-FREE SESSION IS FOUND ON THE PANE, NOT ON THE LABEL.
//
// findProcess looks for "--remote-control <label>". An RC-free session has no
// such flag, so the search returns null every round and the watch alarms "no
// process" about a perfectly healthy session. Making them VISIBLE without this
// would have swapped a false green for a false red.
//
// The binding is the tmux session's PANE, exactly what the supervisor learned
// from the prefix trap: the label was only a FINDER of candidate pids. The
// pane's pid comes from `tmux list-panes -t '=<name>'` - the exact form.
test('findProcessByPanePid: finds the process by pid, not by label', () => {
  const ps = [
    '  123 Mon Aug 25 08:00:00 2026 /opt/agent/.local/bin/claude --permission-mode bypassPermissions --name "Machine"',
    '  456 Mon Aug 25 08:00:00 2026 tmux new-session -d -s machine -c /x',
  ].join('\n')
  const p = findProcessByPanePid(ps, '123')
  assert.equal(p.pid, 123)
  assert.equal(p.startEpoch, Date.parse('Mon Aug 25 08:00:00 2026'))
})

test('findProcessByPanePid: an empty or unknown pid gives null, never a guess', () => {
  const ps = '  123 Mon Aug 25 08:00:00 2026 /opt/agent/.local/bin/claude --name "Machine"'
  // A pid absent from ps => the process is gone. Null, not the nearest line.
  assert.equal(findProcessByPanePid(ps, '999'), null)
  // An empty pid => tmux did not answer. Unknown is not dead, but it is not
  // alive either: null, and decide() alarms rather than guesses.
  assert.equal(findProcessByPanePid(ps, ''), null)
  assert.equal(findProcessByPanePid(ps, null), null)
})

test('findProcessByPanePid: a pid prefix does not match (12 is not 123)', () => {
  const ps = '  123 Mon Aug 25 08:00:00 2026 /opt/agent/.local/bin/claude --name "X"'
  assert.equal(findProcessByPanePid(ps, '12'), null)
})

test('findProcess: pid + start time; null when the label is absent', () => {
  const p = findProcess(PS, 'Hub: alpha')
  assert.equal(p.pid, 123)
  assert.equal(new Date(p.startEpoch).getFullYear(), 2026)
  assert.equal(findProcess(PS, 'Hub: gamma'), null)
})

const BORDER = '─'.repeat(40)

test('paneState: busy / fresh / stuck / normal', () => {
  assert.deepEqual(paneState('something\nesc to interrupt\n❯ hi'), { busy: true, fresh: false, stuckText: null, blocked: false, unreadable: false })
  assert.deepEqual(paneState('/remote-control is active · x\n❯ \n'), { busy: false, fresh: true, stuckText: null, blocked: false, unreadable: false })
  assert.deepEqual(paneState(`⏺ Answer done\n${BORDER}\n❯ fix the thing\n${BORDER}\nbypass`), { busy: false, fresh: false, stuckText: 'fix the thing', blocked: false, unreadable: false })
  assert.deepEqual(paneState(`⏺ Answer\n${BORDER}\n❯ \n${BORDER}\n`), { busy: false, fresh: false, stuckText: null, blocked: false, unreadable: false })
})

test('paneState: a transcript echo of a sent message (no frames) is NOT stuck', () => {
  // The redelivery loop: delivered messages show in the transcript as '❯ text'
  // but only the input box has rule lines around it.
  const pane = `❯ [from the hub: ...] an old delivered message\n⏺ Done, I have answered.\n${BORDER}\n❯ \n${BORDER}\n  ⏵⏵ bypass`
  assert.deepEqual(paneState(pane), { busy: false, fresh: false, stuckText: null, blocked: false, unreadable: false })
})

test('paneState: an echo in the transcript + text in the framed input box => the input box wins', () => {
  const pane = `❯ old echo\n⏺ Answer\n${BORDER}\n❯ new stuck text\n${BORDER}\n  ⏵⏵ bypass`
  assert.equal(paneState(pane).stuckText, 'new stuck text')
})

test('decide: respawn+fresh gives a resume action ONCE per incarnation; a resume blesses', () => {
  const obs = { name: 'alpha', proc: { pid: 9, startEpoch: 2000 }, pane: { busy: false, fresh: true, stuckText: null } }
  const r1 = decide({ startEpoch: 1000 }, obs, '2026-07-22T09:00:00Z', OPTS)
  assert.equal(r1.alerts.length, 0)
  assert.deepEqual(r1.actions, [{ type: 'resume', session: 'alpha' }])
  assert.equal(r1.next.autoResumedFor, 2000)
  assert.equal(r1.next.startEpoch, 1000) // not blessed until resumed
  // the same incarnation again (e.g. the auto-resume failed/aborted) -> no new action
  const r2 = decide(r1.next, obs, '2026-07-22T09:10:00Z', OPTS)
  assert.equal(r2.alerts.length, 0)
  assert.equal(r2.actions.length, 0)
  assert.equal(r2.next.startEpoch, 1000)
  // the pane is no longer fresh (resumed) -> bless the startEpoch, no new action
  const resumed = decide(r2.next, { ...obs, pane: { busy: false, fresh: false, stuckText: null } }, '2026-07-22T09:20:00Z', OPTS)
  assert.equal(resumed.alerts.length, 0)
  assert.equal(resumed.actions.length, 0)
  assert.equal(resumed.next.startEpoch, 2000)
})

test('decide: pane=null at a respawn postpones the decision and does NOT bless the new startEpoch', () => {
  const obsUnknownPane = { name: 'alpha', proc: { pid: 9, startEpoch: 2000 }, pane: null }
  const r1 = decide({ startEpoch: 1000 }, obsUnknownPane, '2026-07-22T09:00:00Z', OPTS)
  assert.equal(r1.alerts.length, 0)
  assert.equal(r1.actions.length, 0)
  assert.equal(r1.next.startEpoch, 1000) // not blessed
  const obsFreshPane = { name: 'alpha', proc: { pid: 9, startEpoch: 2000 }, pane: { busy: false, fresh: true, stuckText: null } }
  const r2 = decide(r1.next, obsFreshPane, '2026-07-22T09:10:00Z', OPTS)
  assert.equal(r2.alerts.length, 0)
  assert.deepEqual(r2.actions, [{ type: 'resume', session: 'alpha' }])
  assert.equal(r2.next.autoResumedFor, 2000)
})

test('decide: pane=null leaves an ongoing stuck count unchanged', () => {
  const prev = { startEpoch: 1000, stuck: { text: 'run the scan', alerted: false } }
  const obsUnknownPane = { name: 'delta', proc: { pid: 1, startEpoch: 1000 }, pane: null }
  const r1 = decide(prev, obsUnknownPane, '2026-07-22T09:00:00Z', OPTS)
  assert.equal(r1.alerts.length, 0)
  assert.deepEqual(r1.next.stuck, { text: 'run the scan', alerted: false })
})

test('decide: a missing process alarms once per gap, with the estate prefix in the subject', () => {
  const gone = { name: 'beta', proc: null, pane: null }
  const r1 = decide({ startEpoch: 1000 }, gone, '2026-07-22T09:00:00Z', OPTS)
  assert.equal(r1.alerts.length, 1)
  assert.match(r1.alerts[0].subject, /has no process/)
  assert.match(r1.alerts[0].subject, /^hub-one watch: /)
  const r2 = decide(r1.next, gone, '2026-07-22T09:10:00Z', OPTS)
  assert.equal(r2.alerts.length, 0)
})

test('decide: an UNMEASURABLE process never alarms - and does not latch the alarm for a real gap', () => {
  // THE FINDING. The human received "<session> has no claude process. The
  // supervisor may be stuck". The watch had not measured anything at all: the
  // session is owned by somebody else, and the hub's ssh into that account goes
  // through a BOUND KEY that answers rc 0 WITHOUT running the command. `ps`
  // returned the relay's refusal text, findProcess found no label in that
  // string, and proc became null. The catch block was never reached.
  //
  // The watch would have said exactly the same about a FULLY HEALTHY session.
  //
  // The same file had the rule written already, two hundred lines away: the bus
  // health computes `inspectable` and logs once without mailing. The process
  // path never got that check. A real fix, applied to one of two places.
  const unmeasurable = { name: 'gamma', proc: null, procUnknown: true, pane: null }
  const r1 = decide({}, unmeasurable, '2026-08-26T20:18:24Z', OPTS)
  assert.equal(r1.alerts.length, 0, 'an unmeasurable process must not alarm')

  // AND IT MUST NOT ACKNOWLEDGE EITHER. The latch missingAlerted exists so a gap
  // mails once, not every cycle. If an unmeasurable run sets it, the next REAL
  // gap is swallowed silently - swapping a false alarm for a missing one.
  assert.notEqual(r1.next.missingAlerted, true, 'unmeasurable must not set the latch')
  const real = { name: 'gamma', proc: null, pane: null }
  const r2 = decide(r1.next, real, '2026-08-26T20:30:00Z', OPTS)
  assert.equal(r2.alerts.length, 1, 'a real gap after an unmeasurable one must still alarm')
  assert.match(r2.alerts[0].subject, /has no process/)
})

test('decide: stuck x2 => reinject action (no mail); alarm only if the text is still there AFTER redelivery', () => {
  const mk = (t) => ({ name: 'delta', proc: { pid: 1, startEpoch: 1000 }, pane: { busy: false, fresh: false, stuckText: t } })
  const r1 = decide({ startEpoch: 1000 }, mk('run the scan'), '2026-07-22T09:00:00Z', OPTS)
  assert.equal(r1.alerts.length, 0)
  assert.equal(r1.actions.length, 0)
  const r2 = decide(r1.next, mk('run the scan'), '2026-07-22T09:10:00Z', OPTS)
  assert.equal(r2.alerts.length, 0)
  assert.deepEqual(r2.actions, [{ type: 'reinject', session: 'delta', text: 'run the scan', isPing: false }])
  // the orchestrator did NOT act (busy) => reinjected unset => the same action again
  const r2b = decide(r2.next, mk('run the scan'), '2026-07-22T09:15:00Z', OPTS)
  assert.deepEqual(r2b.actions, [{ type: 'reinject', session: 'delta', text: 'run the scan', isPing: false }])
  assert.equal(r2b.alerts.length, 0)
  // the orchestrator acted and set reinjected - the text is STILL there => one alert
  const afterReinject = { ...r2b.next, stuck: { text: 'run the scan', reinjected: true, alerted: false } }
  const r3 = decide(afterReinject, mk('run the scan'), '2026-07-22T09:20:00Z', OPTS)
  assert.equal(r3.alerts.length, 1)
  assert.match(r3.alerts[0].subject, /redelivery failed/)
  assert.match(r3.alerts[0].body, /run the scan/)
  const r4 = decide(r3.next, mk('run the scan'), '2026-07-22T09:25:00Z', OPTS)
  assert.equal(r4.alerts.length, 0) // dedup
  const r5 = decide(r4.next, mk(null), '2026-07-22T09:30:00Z', OPTS)
  assert.equal(r5.next.stuck, null)
})

test('decide: a stuck bus ping => reinject, then clearStuck - NEVER mail', () => {
  const mk = (t) => ({ name: 'alpha', proc: { pid: 1, startEpoch: 1000 }, pane: { busy: false, fresh: false, stuckText: t } })
  const r1 = decide({ startEpoch: 1000 }, mk(PING), '2026-07-22T09:00:00Z', OPTS)
  assert.equal(r1.alerts.length, 0)
  const r2 = decide(r1.next, mk(PING), '2026-07-22T09:05:00Z', OPTS)
  assert.equal(r2.alerts.length, 0)
  assert.deepEqual(r2.actions, [{ type: 'reinject', session: 'alpha', text: PING, isPing: true }])
  const afterReinject = { ...r2.next, stuck: { text: PING, reinjected: true, alerted: false } }
  const r3 = decide(afterReinject, mk(PING), '2026-07-22T09:10:00Z', OPTS)
  assert.equal(r3.alerts.length, 0)
  assert.deepEqual(r3.actions, [{ type: 'clearStuck', session: 'alpha' }])
  const r4 = decide(r3.next, mk(PING), '2026-07-22T09:15:00Z', OPTS)
  assert.equal(r4.alerts.length, 0) // still silent, clears again
  assert.deepEqual(r4.actions, [{ type: 'clearStuck', session: 'alpha' }])
})

// THE PING TEXT IS THE ESTATE'S. Without it in opts, nothing is a ping - a
// stuck line is then real text and goes the alert way. The watch must never
// compare against a text of its own.
test('decide: without a ping text in opts, the same line is real text, not a ping', () => {
  const mk = (t) => ({ name: 'alpha', proc: { pid: 1, startEpoch: 1000 }, pane: { busy: false, fresh: false, stuckText: t } })
  const r1 = decide({ startEpoch: 1000 }, mk(PING), '2026-07-22T09:00:00Z', {})
  const r2 = decide(r1.next, mk(PING), '2026-07-22T09:05:00Z', {})
  assert.deepEqual(r2.actions, [{ type: 'reinject', session: 'alpha', text: PING, isPing: false }])
})

test('decide: old stuck state (alerted without reinjected) => reinject, not a new mail', () => {
  const mk = (t) => ({ name: 'beta', proc: { pid: 1, startEpoch: 1000 }, pane: { busy: false, fresh: false, stuckText: t } })
  const prev = { startEpoch: 1000, stuck: { text: 'an old note', alerted: true } }
  const r = decide(prev, mk('an old note'), '2026-07-22T09:00:00Z', OPTS)
  assert.equal(r.alerts.length, 0)
  assert.deepEqual(r.actions, [{ type: 'reinject', session: 'beta', text: 'an old note', isPing: false }])
})

test('resumeStep: start screen (fresh) -> type-resume', () => {
  const pane = `Welcome to Claude Code\n\n/remote-control is active · Hub: alpha\n❯ \n`
  assert.equal(resumeStep(pane).action, 'type-resume')
})

test('resumeStep: resume picker -> press-enter', () => {
  const pane = `   Resume session (1 of 25)\n     some project\n   ❯ Check whether the agent is active\n     9 hours ago · main · 13MB\n     Ctrl+A to show all projects · Ctrl+B to only show current branch · Space to preview · Ctrl+R to rename · Type to search · Esc to cancel\n`
  assert.equal(resumeStep(pane).action, 'press-enter')
})

test('resumeStep: summary dialog -> press-enter', () => {
  const pane = `  ❯ 1. Resume from summary (recommended)\n    2. Resume full session as-is\n    3. Don't ask me again\n  Enter to confirm · Esc to cancel\n`
  assert.equal(resumeStep(pane).action, 'press-enter')
})

test('resumeStep: conversation visible (⏺) -> done', () => {
  const pane = `⏺ I am ready to continue.\n❯ \nbypass permissions\n`
  assert.equal(resumeStep(pane).action, 'done')
})

test('resumeStep: busy -> abort', () => {
  const pane = `Working on it...\nesc to interrupt\n`
  assert.equal(resumeStep(pane).action, 'abort')
})

test('resumeStep: empty pane -> abort', () => {
  assert.equal(resumeStep('').action, 'abort')
  assert.equal(resumeStep('   \n').action, 'abort')
})

test('resumeStep: pane=null (unknown state) -> abort', () => {
  assert.equal(resumeStep(null).action, 'abort')
})

test('resumeStep: unknown/unexpected state -> abort', () => {
  const pane = `Something entirely different that matches no known pattern\n`
  assert.equal(resumeStep(pane).action, 'abort')
})

test('resumeStep: a conversation that QUOTES picker text gives done, not press-enter', () => {
  const pane = '⏺ We discussed Resume session and Resume from summary in the watch code\n❯ \n  ⏵⏵ bypass permissions on'
  const r = resumeStep(pane)
  assert.equal(r.action, 'done')
})

test('paneState: a spinner without esc-to-interrupt counts as busy (the false-stuck fix)', () => {
  const pane = '✽ Improvising… (15m 9s · ↓ 21.4k tokens)\n❯ Do you need to restart every session?\n'
  const st = paneState(pane)
  assert.equal(st.busy, true)
  assert.equal(st.stuckText, null)
})

test('busAlert: empty inbox => neither ping nor alert', () => {
  const r = busAlert({}, [], 2000)
  assert.equal(r.alert, null)
  assert.equal(r.reping, false)
  assert.deepEqual(r.next, { name: null })
})

test('busAlert: under 15 min => neither ping nor alert', () => {
  const records = [{ name: 'a', ageSec: 900, from: 'alpha', text: 'hi' }]
  const r = busAlert({}, records, 2000)
  assert.equal(r.alert, null)
  assert.equal(r.reping, false)
})

test('busAlert: 15-45 min => re-ping but NO mail', () => {
  const records = [{ name: '100-alpha-1.json', ageSec: 901, from: 'alpha', text: 'check the log' }]
  const r = busAlert({}, records, 2000)
  assert.equal(r.alert, null)
  assert.equal(r.reping, true)
  // every cycle in the interval => still re-ping, still no mail
  const r2 = busAlert(r.next, [{ name: '100-alpha-1.json', ageSec: 2699, from: 'alpha', text: 'check the log' }], 3000)
  assert.equal(r2.alert, null)
  assert.equal(r2.reping, true)
})

test('busAlert: over 45 min => mail (count/age/from/text) + continued re-ping', () => {
  const records = [
    { name: '100-alpha-1.json', ageSec: 2701, from: 'alpha', text: 'check the log' },
    { name: '200-beta-2.json', ageSec: 300, from: 'beta', text: 'other' },
  ]
  const r = busAlert({}, records, 2000)
  assert.deepEqual(r.alert, { count: 2, oldestAgeMin: 45, from: 'alpha', text: 'check the log' })
  assert.equal(r.reping, true)
  assert.deepEqual(r.next, { name: '100-alpha-1.json' })
})

test('busAlert: the same oldest file again over 45 min => the mail is deduplicated, the re-ping remains', () => {
  const records = [{ name: '100-alpha-1.json', ageSec: 2701, from: 'alpha', text: 'check the log' }]
  const r1 = busAlert({}, records, 2000)
  assert.ok(r1.alert)
  const recordsLater = [{ name: '100-alpha-1.json', ageSec: 3600, from: 'alpha', text: 'check the log' }]
  const r2 = busAlert(r1.next, recordsLater, 3000)
  assert.equal(r2.alert, null)
  assert.equal(r2.reping, true)
  assert.deepEqual(r2.next, r1.next)
})

test('busAlert: a new oldest file (the old one acked) => a new mail at escalation', () => {
  const first = [{ name: '100-alpha-1.json', ageSec: 2701, from: 'alpha', text: 'first' }]
  const r1 = busAlert({}, first, 2000)
  const second = [{ name: '200-alpha-2.json', ageSec: 2750, from: 'alpha', text: 'second' }]
  const r2 = busAlert(r1.next, second, 3000)
  assert.ok(r2.alert)
  assert.equal(r2.alert.text, 'second')
  assert.deepEqual(r2.next, { name: '200-alpha-2.json' })
})

test('busAlert: the text is truncated to 100 characters', () => {
  const longText = 'x'.repeat(150)
  const records = [{ name: 'a', ageSec: 2800, from: 'beta', text: longText }]
  const r = busAlert({}, records, 2000)
  assert.equal(r.alert.text.length, 100)
  assert.equal(r.alert.text, 'x'.repeat(100))
})

test('malformedAlert: empty malformed/ => no alert', () => {
  const r = malformedAlert(0, 0)
  assert.equal(r.alert, null)
  assert.equal(r.next, 0)
})

test('malformedAlert: the first unreadable record alarms (threshold zero, no age)', () => {
  const r = malformedAlert(0, 1)
  assert.ok(r.alert)
  assert.equal(r.alert.count, 1)
  assert.equal(r.next, 1)
})

test('malformedAlert: an unchanged count does NOT alarm again (dedup on the count)', () => {
  const r = malformedAlert(1, 1)
  assert.equal(r.alert, null)
  assert.equal(r.next, 1)
})

test('malformedAlert: a NEW unreadable record alarms even when one already existed', () => {
  const r = malformedAlert(1, 2)
  assert.ok(r.alert)
  assert.equal(r.alert.count, 2)
})

test('malformedAlert: a cleaned malformed/ (count -> 0) resets; the next file alarms again', () => {
  const cleared = malformedAlert(2, 0)
  assert.equal(cleared.alert, null)
  assert.equal(cleared.next, 0)
  const again = malformedAlert(cleared.next, 1)
  assert.ok(again.alert)
})

test('parseBusDump: NODIR => no files, no malformed, noDir=true', () => {
  const r = parseBusDump('NODIR\n', 2000)
  assert.equal(r.noDir, true)
  assert.equal(r.files.length, 0)
  assert.equal(r.malformedCount, 0)
})

test('parseBusDump: two inbox records + a malformed count are parsed', () => {
  const dump = '===F===\n{"from":"hub-one","text":"a","ts":1000}\n===F===\n{"from":"alpha","text":"b","ts":1500}\n===MALFORMED===\n0\n'
  const r = parseBusDump(dump, 2000)
  assert.equal(r.files.length, 2)
  assert.equal(r.files[0].from, 'hub-one')
  assert.equal(r.files[0].ageSec, 1000)  // 2000 - 1000
  assert.equal(r.files[1].ageSec, 500)
  assert.equal(r.malformedCount, 0)
})

test('parseBusDump: the malformed count is picked out of the dump', () => {
  const r = parseBusDump('===F===\n{"from":"x","ts":1900}\n===MALFORMED===\n3\n', 2000)
  assert.equal(r.malformedCount, 3)
  assert.equal(r.files.length, 1)
})

test('parseBusDump: EACCES => eacces=true, DISTINCT from empty and NODIR', () => {
  const r = parseBusDump('EACCES\n', 2000)
  assert.equal(r.eacces, true)
  assert.notEqual(r.noDir, true)
  assert.equal(r.files.length, 0)
})

test('parseBusDump: an empty inbox with the directory present => zero files, noDir=false', () => {
  const r = parseBusDump('===MALFORMED===\n0\n', 2000)
  assert.equal(r.noDir, false)
  assert.equal(r.files.length, 0)
})

test('parseBusDump: broken json in the dump still counts as a record', () => {
  const r = parseBusDump('===F===\n{half\n===MALFORMED===\n0\n', 2000)
  assert.equal(r.files.length, 1)
  assert.equal(r.files[0].from, '')  // could not be parsed, but counts
})

test('browserActivity: clients => lastSeen is set and samples count up', () => {
  const r1 = browserActivity({}, { profile1: 2, profile2: 0 }, '2026-07-31T10:00:00Z')
  assert.equal(r1.profile1.lastSeen, '2026-07-31T10:00:00Z')
  assert.equal(r1.profile1.samples, 1)
  assert.equal(r1.profile2.lastSeen, null)   // no client => no activity
  const r2 = browserActivity(r1, { profile1: 1, profile2: 0 }, '2026-07-31T10:05:00Z')
  assert.equal(r2.profile1.samples, 2)
  assert.equal(r2.profile1.lastSeen, '2026-07-31T10:05:00Z')
})

test('browserActivity: a silent cycle NEVER erases an earlier lastSeen', () => {
  const seen = { profile3: { lastSeen: '2026-07-20T09:00:00Z', samples: 5 } }
  const r = browserActivity(seen, { profile3: 0 }, '2026-07-31T10:00:00Z')
  assert.equal(r.profile3.lastSeen, '2026-07-20T09:00:00Z')  // the history stands
  assert.equal(r.profile3.samples, 5)
})

test('browserActivity: an unknown domain in obs is added without touching the others', () => {
  const prev = { profile1: { lastSeen: '2026-07-31T09:00:00Z', samples: 3 } }
  const r = browserActivity(prev, { profile4: 1 }, '2026-07-31T10:00:00Z')
  assert.equal(r.profile1.samples, 3)
  assert.equal(r.profile4.samples, 1)
})

test('claudePin: matching inodes => no action, state reset', () => {
  const r = claudePin({ repaired: true, alerted: true }, { stableInode: 42, currentInode: 42 })
  assert.equal(r.action, null); assert.equal(r.alert, false)
  assert.deepEqual(r.next, {})
})

test('claudePin: drift => REPAIR first, do not alarm', () => {
  const r = claudePin({}, { stableInode: 1, currentInode: 2 })
  assert.equal(r.action, 'repin'); assert.equal(r.alert, false)
})

test('claudePin: persisting drift AFTER the repair => one alert', () => {
  const r = claudePin({ repaired: true }, { stableInode: 1, currentInode: 2 })
  assert.equal(r.action, null); assert.equal(r.alert, true)
})

test('claudePin: the alert is not repeated (dedup until they match again)', () => {
  const r = claudePin({ repaired: true, alerted: true }, { stableInode: 1, currentInode: 2 })
  assert.equal(r.alert, false)
})

test('claudePin: an unmeasurable state touches no state and never alarms', () => {
  // An observation that could not be made is not a fault.
  for (const obs of [{}, { stableInode: 1 }, { currentInode: 2 }, { stableInode: null, currentInode: 2 }]) {
    const prev = { repaired: true }
    const r = claudePin(prev, obs)
    assert.equal(r.alert, false, JSON.stringify(obs))
    assert.equal(r.action, null, JSON.stringify(obs))
    assert.deepEqual(r.next, prev, JSON.stringify(obs))
  }
})

test('unpinnedSessions: finds sessions running a binary other than the pinned one', () => {
  // EXACTLY the format the watch feeds in: ps -ax -o pid=,lstart=,command=
  const ps = [
    '  111 Sat Aug  1 19:46:47 2026 /opt/agent/.local/share/claude/stable/claude --remote-control Hub: delta --permission-mode bypassPermissions',
    '  222 Wed Jul 22 18:05:34 2026 /opt/agent/.local/bin/claude --remote-control Hub: alpha --permission-mode bypassPermissions',
    '  333 Sun Jul 19 12:06:53 2026 /usr/bin/grep claude',
  ].join('\n')
  const r = unpinnedSessions(ps, '/opt/agent/.local/share/claude/stable/claude')
  assert.equal(r.length, 1)
  assert.equal(r[0].rcLabel, 'Hub: alpha')
  assert.equal(r[0].bin, '/opt/agent/.local/bin/claude')
})

test('unpinnedSessions: all pinned => empty list', () => {
  const ps = '  111 Sat Aug  1 19:46:47 2026 /opt/agent/.local/share/claude/stable/claude --remote-control Hub: delta --permission-mode bypassPermissions'
  assert.deepEqual(unpinnedSessions(ps, '/opt/agent/.local/share/claude/stable/claude'), [])
})

// -- NEW SIGNALS: blocked and unreadable -------------------------------------
//
// WHY THEY ARE DATA AND NOT CODE. The patterns for the permission dialog are
// SECOND-HAND - they come from another implementation's rule file, not from a
// pane seen blocked here. The negative half is verified: zero hits in six live
// panes. The positive half is not.
//
// A pattern that could not be tried must therefore cost one line to correct,
// not a code change. The tests pass the rules in explicitly so they measure the
// MECHANISM and not the file that happens to lie beside it.
const R_BLOCK = [{ id: 'perm', state: 'blocked', region: 'bottom(8)', contains: ['esc to cancel'],
                   any: [['enter to confirm'], ['enter to select']] }]
const R_UNREAD = [{ id: 'resume-summary', state: 'unreadable', region: 'whole', contains: ['❯ 1. Resume from summary'] }]

test('paneState: a permission dialog near the bottom => blocked', () => {
  const pane = ['  ⏺ Earlier answer.', '', '  Do you want to proceed?',
    '  esc to cancel · enter to confirm', BORDER, '❯ ', BORDER].join('\n')
  const r = paneState(pane, R_BLOCK)
  assert.equal(r.blocked, true)
  assert.equal(r.busy, false)
})

// THE SAME REGION DISCIPLINE AS BUSY. A session that WRITES about the dialog
// otherwise matches itself - the transcript trap, and it applies to every new
// signal we add, not only the one that already got burned.
test('paneState: the transcript talking about the dialog does not taint blocked', () => {
  const pane = ['  I just wrote about esc to cancel and enter to confirm.',
    '', '', '', '', '', '', '', '', '', BORDER, '❯ ', BORDER].join('\n')
  assert.equal(paneState(pane, R_BLOCK).blocked, false)
})

// A SCREEN THAT CANNOT BE INTERPRETED MUST NOT BE INTERPRETED. Under a resume
// dialog the pane does not mirror the session's state: '❯ 1. Resume from
// summary' looks like the input box's text, and everything else is menu lines.
// Guessing there is the same fault as the footer - the watch degrades without
// saying so.
test('paneState: the resume dialog is unreadable, and the other fields are NOT measured', () => {
  const pane = ['  ❯ 1. Resume from summary', '    2. Start fresh'].join('\n')
  const r = paneState(pane, R_UNREAD)
  assert.equal(r.unreadable, true)
  assert.equal(r.busy, null)
  assert.equal(r.stuckText, null)
})

test('paneState: unreadable WINS over busy - otherwise the refusal would be void', () => {
  const pane = ['  ❯ 1. Resume from summary', '  esc to interrupt'].join('\n')
  assert.equal(paneState(pane, R_UNREAD).unreadable, true)
})

test('paneState: an ordinary pane is neither blocked nor unreadable', () => {
  const pane = ['  ⏺ Answer done.', BORDER, '❯ ', BORDER].join('\n')
  const r = paneState(pane, [...R_BLOCK, ...R_UNREAD])
  assert.equal(r.blocked, false)
  assert.equal(r.unreadable, false)
})

// AN UNKNOWN REGION NAME MUST REFUSE, not silently never match. A misspelled
// region that merely yields zero hits is a rule that looks in force and is not.
test('paneState: an unknown region throws instead of keeping quiet', () => {
  assert.throws(() => paneState('x', [{ id: 'bad', state: 'blocked', region: 'no_such', contains: ['x'] }]),
    /no_such/)
})

// AN UNREADABLE PANE TOUCHES NO PANE-DEPENDENT STATE - the same rule as a pane we
// could not capture at all. The difference is only WHY it cannot be read: one is
// missing, the other shows a dialog.
//
// WITHOUT THE EARLY RETURN, STUCK TEXT IS FORGOTTEN. stuckText is null under a
// dialog, and the closing branch then sets next.stuck = null - the memory of an
// unsent line is erased the moment somebody opens the resume menu, and the
// redelivery never happens.
test('decide: an unreadable pane touches no pane-dependent state and does not forget stuck', () => {
  const prev = { startEpoch: 1, stuck: { text: 'fix the thing', alerted: false } }
  const obs = { name: 'x', proc: { startEpoch: 1 },
                pane: { busy: null, fresh: null, stuckText: null, blocked: null, unreadable: true } }
  const r = decide(prev, obs, '2026-08-26T00:00:00Z', OPTS)
  assert.deepEqual(r.actions, [])
  assert.deepEqual(r.alerts, [])
  assert.deepEqual(r.next.stuck, prev.stuck)
})

// -- BLOCKED WIRED IN: A WAITING SESSION IS A MEASUREMENT, NOT A CLOCK --------
//
// Unacknowledged mail alarms after fifteen minutes because we lacked a
// measurement. A blocked session CANNOT acknowledge - it stands at a question -
// so the clock measured the wrong thing and late.
//
// THE CADENCE IS THE STUCK PATTERN'S, not a new one: the first observation
// notes, the second acts. The watch cycles every five minutes, so 5-10 minutes
// against the mail alarm's fifteen, and with a reason that says what is needed
// instead of that something is missing. An alarm on the FIRST observation would
// have been noise every time the human is sitting right there answering.
const obsBlocked = (blocked) => ({ name: 'x', proc: { startEpoch: 1 },
  pane: { busy: false, fresh: false, stuckText: null, blocked, unreadable: false } })

test('decide: blocked ONCE does not alarm - the human may be answering right now', () => {
  const r = decide({ startEpoch: 1 }, obsBlocked(true), '2026-08-26T00:00:00Z', OPTS)
  assert.deepEqual(r.alerts, [])
  assert.equal(r.next.blocked.alerted, false)
})

test('decide: blocked TWICE in a row => one alert naming the session, with the attach hint', () => {
  const r1 = decide({ startEpoch: 1 }, obsBlocked(true), '2026-08-26T00:00:00Z', OPTS)
  const r2 = decide(r1.next, obsBlocked(true), '2026-08-26T00:05:00Z', OPTS)
  assert.equal(r2.alerts.length, 1)
  assert.match(r2.alerts[0].subject, /x/)
  assert.match(r2.alerts[0].body, /hub-one\.sock/)
  assert.equal(r2.next.blocked.alerted, true)
})

test('decide: still blocked does not alarm again - dedup', () => {
  const r1 = decide({ startEpoch: 1 }, obsBlocked(true), '2026-08-26T00:00:00Z', OPTS)
  const r2 = decide(r1.next, obsBlocked(true), '2026-08-26T00:05:00Z', OPTS)
  const r3 = decide(r2.next, obsBlocked(true), '2026-08-26T00:10:00Z', OPTS)
  assert.deepEqual(r3.alerts, [])
})

// A SESSION THAT HAS STOPPED WAITING MUST BE ABLE TO ALARM AGAIN. Without the
// reset the first alarm is the only one ever, and the next time somebody is left
// standing it does not show - the same silent degradation the footer gave.
test('decide: when the session stops waiting the memory resets, and the next wait alarms again', () => {
  const r1 = decide({ startEpoch: 1 }, obsBlocked(true), '2026-08-26T00:00:00Z', OPTS)
  const r2 = decide(r1.next, obsBlocked(true), '2026-08-26T00:05:00Z', OPTS)
  assert.equal(r2.alerts.length, 1)
  const r3 = decide(r2.next, obsBlocked(false), '2026-08-26T00:10:00Z', OPTS)
  assert.equal(r3.next.blocked, null)
  const r4 = decide(r3.next, obsBlocked(true), '2026-08-26T00:15:00Z', OPTS)
  const r5 = decide(r4.next, obsBlocked(true), '2026-08-26T00:20:00Z', OPTS)
  assert.equal(r5.alerts.length, 1)
})

test('paneState: the permanent footer does NOT make the session busy', () => {
  // A real capture from a freshly started, idle session.
  const pane = [
    '  Something earlier in the transcript.',
    '',
    '────────────────────────────────',
    '❯ ',
    '────────────────────────────────',
    '  ⏵⏵ bypass permissions on (shift+tab to cycle) · esc to interrupt · ← for agents        /rc',
  ].join('\n')
  assert.equal(paneState(pane).busy, false)
})

test('paneState: the transcript talking about esc to interrupt does not taint', () => {
  const pane = [
    '  I just wrote that esc to interrupt is in the footer.',
    '  And another line about esc to interrupt, far up in the transcript.',
    '', '', '', '', '', '', '', '',
    '────────────────────────────────',
    '❯ ',
    '────────────────────────────────',
    '  ⏵⏵ bypass permissions on · esc to interrupt · ← for agents        /rc',
  ].join('\n')
  assert.equal(paneState(pane).busy, false)
})

test('paneState: a real spinner NEAR the input box gives busy', () => {
  const pane = [
    '  ⏺ something done',
    '✽ Improvising… (15m 9s · 12.3k tokens)',
    '────────────────────────────────',
    '❯ ',
    '────────────────────────────────',
    '  ⏵⏵ bypass permissions on · esc to interrupt · ← for agents        /rc',
  ].join('\n')
  assert.equal(paneState(pane).busy, true)
})

test('paneState: esc to interrupt outside the footer near the bottom gives busy', () => {
  // Older client versions show it as its own line while the session works.
  const pane = [
    '  ⏺ working',
    '  esc to interrupt',
    '────────────────────────────────',
    '❯ ',
    '────────────────────────────────',
  ].join('\n')
  assert.equal(paneState(pane).busy, true)
})

test('resumeStep: the permanent footer does NOT abort a resume', () => {
  const pane = [
    '  /remote-control is active',
    '────────────────────────────────',
    '❯ ',
    '────────────────────────────────',
    '  ⏵⏵ bypass permissions on · esc to interrupt · ← for agents        /rc',
  ].join('\n')
  assert.equal(resumeStep(pane).action, 'type-resume')
})

test('resumeStep: a real busy line near the bottom still aborts', () => {
  const pane = [
    '  ⏺ working',
    '  esc to interrupt',
    '────────────────────────────────',
    '❯ ',
  ].join('\n')
  assert.equal(resumeStep(pane).action, 'abort')
})

test('brandedBrowsers: all stamps match => no action', () => {
  const r = brandedBrowsers({ rebuilt: true }, { current: 'v1', stamps: { profile1: 'v1', profile2: 'v1' } })
  assert.equal(r.action, null); assert.deepEqual(r.next, {})
})

test('brandedBrowsers: a stale clone => rebuild first, do not alarm', () => {
  const r = brandedBrowsers({}, { current: 'v2', stamps: { profile1: 'v1', profile2: 'v2' } })
  assert.equal(r.action, 'rebrand'); assert.equal(r.alert, false)
  assert.deepEqual(r.next.stale, ['profile1'])
})

test('brandedBrowsers: persisting drift after the rebuild => one alert', () => {
  const r = brandedBrowsers({ rebuilt: true }, { current: 'v2', stamps: { profile1: 'v1' } })
  assert.equal(r.alert, true)
})

test('brandedBrowsers: an unmeasurable state touches no state and never alarms', () => {
  for (const obs of [{}, { current: 'v1' }, { current: 'v1', stamps: {} }]) {
    const r = brandedBrowsers({ rebuilt: true }, obs)
    assert.equal(r.alert, false); assert.equal(r.action, null)
  }
})

// --- jobAlerts ---------------------------------------------------------------
// THE VERDICT STRINGS ARE THE ESTATE'S. The tests pass the estate's list in, so
// they measure the mechanism and not a vocabulary.
const JOPTS = { broken: ['never run', 'NO delivery found', 'RAN WITHOUT DELIVERY'], rcPrefix: 'last run exited rc=' }
const J = (job, verdict, extra = {}) => ({ job, verdict, last_run: 1785840000, ...extra })

test('jobAlerts: healthy and undeclared jobs never alarm', () => {
  const r = jobAlerts({}, [J('a', 'ok'), J('b', 'undeclared delivery')], JOPTS)
  assert.deepEqual(r.alerts, [])
  assert.deepEqual(r.next, {}, 'healthy jobs must not linger in the state')
})

test('jobAlerts: every broken verdict alarms', () => {
  const jobs = [J('a', 'never run'), J('b', 'NO delivery found'),
                J('c', 'RAN WITHOUT DELIVERY'), J('d', 'last run exited rc=1')]
  const r = jobAlerts({}, jobs, JOPTS)
  assert.equal(r.alerts.length, 4)
  assert.deepEqual(r.alerts.map(a => a.job), ['a', 'b', 'c', 'd'])
})

test('jobAlerts: the same broken state alarms once, not every cycle', () => {
  const jobs = [J('a', 'RAN WITHOUT DELIVERY')]
  const r1 = jobAlerts({}, jobs, JOPTS)
  assert.equal(r1.alerts.length, 1)
  const r2 = jobAlerts(r1.next, jobs, JOPTS)
  assert.equal(r2.alerts.length, 0, 'dedup')
  const r3 = jobAlerts(r2.next, jobs, JOPTS)
  assert.equal(r3.alerts.length, 0)
})

test('jobAlerts: a change to ANOTHER broken state is new information', () => {
  const r1 = jobAlerts({}, [J('a', 'NO delivery found')], JOPTS)
  const r2 = jobAlerts(r1.next, [J('a', 'last run exited rc=1')], JOPTS)
  assert.equal(r2.alerts.length, 1)
  assert.equal(r2.alerts[0].verdict, 'last run exited rc=1')
})

test('jobAlerts: a recovered job drops out of the state => the next failure alarms again', () => {
  const r1 = jobAlerts({}, [J('a', 'RAN WITHOUT DELIVERY')], JOPTS)
  const r2 = jobAlerts(r1.next, [J('a', 'ok')], JOPTS)
  assert.deepEqual(r2.next, {})
  const r3 = jobAlerts(r2.next, [J('a', 'RAN WITHOUT DELIVERY')], JOPTS)
  assert.equal(r3.alerts.length, 1, 'the same fault again after recovery IS a new event')
})

test('jobAlerts: the note about what the receipt attests travels with the alert', () => {
  const r = jobAlerts({}, [J('a', 'RAN WITHOUT DELIVERY', { note: 'the receipt is written by the model' })], JOPTS)
  assert.equal(r.alerts[0].note, 'the receipt is written by the model')
})

test('jobAlerts: the default vocabulary is English, and the estate may replace it', () => {
  assert.equal(jobAlerts({}, [J('a', 'never run')]).alerts.length, 1)
  assert.equal(jobAlerts({}, [J('a', 'never run')], { broken: ['broken!'], rcPrefix: 'rc:' }).alerts.length, 0)
  assert.equal(jobAlerts({}, [J('a', 'broken!')], { broken: ['broken!'], rcPrefix: 'rc:' }).alerts.length, 1)
})

// --- hostAlerts --------------------------------------------------------------
const HOPTS = { noAnswer: 'NO ANSWER', httpPrefix: 'HTTP ', capacity: /DISK|MEMORY/ }
const EP = (addr, over = {}) => ({ addr, owner: 'alpha', httpVerdict: 'answers 200', certStatus: 'ok', certVerdict: 'cert until X', ...over })
const HOST = (endpoints, over = {}) => ({ hosts: [{ host: 'h1', diskPct: 20, memPct: 20, capacityVerdict: 'disk 20% · memory 20%', endpoints, ...over }] })

test('hostAlerts: all healthy => no alerts, no state', () => {
  const r = hostAlerts({}, HOST([EP('a.example')]), HOPTS)
  assert.deepEqual(r.alerts, [])
  assert.deepEqual(r.next, { alerted: {}, unknown: {} })
})

test('hostAlerts: an address that does not answer alarms at once, then dedup', () => {
  const snap = HOST([EP('a.example', { httpVerdict: 'NO ANSWER' })])
  const r1 = hostAlerts({}, snap, HOPTS)
  assert.equal(r1.alerts.length, 1)
  assert.equal(r1.alerts[0].kind, 'http')
  assert.equal(r1.alerts[0].owner, 'alpha', 'the alert must say who owns the address')
  assert.equal(hostAlerts(r1.next, snap, HOPTS).alerts.length, 0, 'dedup')
})

test('hostAlerts: an HTTP error code alarms, and a change of code is new information', () => {
  const r1 = hostAlerts({}, HOST([EP('a.example', { httpVerdict: 'HTTP 500' })]), HOPTS)
  assert.equal(r1.alerts.length, 1)
  const r2 = hostAlerts(r1.next, HOST([EP('a.example', { httpVerdict: 'HTTP 502' })]), HOPTS)
  assert.equal(r2.alerts.length, 1)
})

test('hostAlerts: an address that answers again resets => the next failure alarms', () => {
  const r1 = hostAlerts({}, HOST([EP('a.example', { httpVerdict: 'NO ANSWER' })]), HOPTS)
  const r2 = hostAlerts(r1.next, HOST([EP('a.example')]), HOPTS)
  assert.deepEqual(r2.next.alerted, {})
  assert.equal(hostAlerts(r2.next, HOST([EP('a.example', { httpVerdict: 'NO ANSWER' })]), HOPTS).alerts.length, 1)
})

test('hostAlerts: a cert near expiry alarms ONCE, not every five minutes for three weeks', () => {
  const snap = HOST([EP('a.example', { certStatus: 'warn', certVerdict: 'CERT EXPIRES SOON' })])
  const r1 = hostAlerts({}, snap, HOPTS)
  assert.equal(r1.alerts.length, 1)
  assert.equal(r1.alerts[0].kind, 'cert')
  let st = r1.next
  for (let i = 0; i < 20; i++) {
    const r = hostAlerts(st, snap, HOPTS)
    assert.equal(r.alerts.length, 0, `cycle ${i} alarmed again`)
    st = r.next
  }
})

test('hostAlerts: warn => expired is new information', () => {
  const r1 = hostAlerts({}, HOST([EP('a.example', { certStatus: 'warn' })]), HOPTS)
  const r2 = hostAlerts(r1.next, HOST([EP('a.example', { certStatus: 'expired' })]), HOPTS)
  assert.equal(r2.alerts.length, 1)
  assert.equal(r2.alerts[0].detail !== undefined, true)
})

test('hostAlerts: an UNMEASURED cert does not alarm at once but after three cycles in a row, once', () => {
  const snap = HOST([EP('a.example', { certStatus: 'unknown' })])
  let st = {}, fired = []
  for (let i = 0; i < 6; i++) {
    const r = hostAlerts(st, snap, HOPTS)
    fired.push(r.alerts.length)
    st = r.next
  }
  assert.deepEqual(fired, [0, 0, 1, 0, 0, 0], 'exactly once, at the third measurement')
})

test('hostAlerts: unmeasured becoming measurable resets the counter', () => {
  const bad = HOST([EP('a.example', { certStatus: 'unknown' })])
  const good = HOST([EP('a.example')])
  let st = hostAlerts({}, bad, HOPTS).next
  st = hostAlerts(st, bad, HOPTS).next          // 2 in a row
  st = hostAlerts(st, good, HOPTS).next         // measurable again
  assert.deepEqual(st.unknown, {})
  const r = hostAlerts(st, bad, HOPTS)
  assert.equal(r.alerts.length, 0, 'the counter must start over, not continue from 2')
})

test('hostAlerts: unmeasured and broken use DIFFERENT words', () => {
  const un = hostAlerts({ unknown: { 'h1|a.example|cert': 2 } }, HOST([EP('a.example', { certStatus: 'unknown' })]), HOPTS)
  const br = hostAlerts({}, HOST([EP('a.example', { certStatus: 'expired' })]), HOPTS)
  assert.equal(un.alerts[0].kind, 'unmeasured')
  assert.equal(br.alerts[0].kind, 'cert')
  assert.notEqual(un.alerts[0].kind, br.alerts[0].kind)
})

test('hostAlerts: a full disk alarms, healthy thresholds do not', () => {
  const full = HOST([EP('a.example')], { capacityVerdict: 'DISK 91% · memory 20%' })
  assert.equal(hostAlerts({}, full, HOPTS).alerts[0].kind, 'capacity')
  assert.equal(hostAlerts({}, HOST([EP('a.example')]), HOPTS).alerts.length, 0)
})

test('hostAlerts: unmeasurable capacity (no ssh) follows the unmeasured rule', () => {
  const snap = HOST([EP('a.example')], { diskPct: null, capacityVerdict: 'capacity UNKNOWN (no ssh)' })
  let st = {}, fired = []
  for (let i = 0; i < 4; i++) { const r = hostAlerts(st, snap, HOPTS); fired.push(r.alerts.length); st = r.next }
  assert.deepEqual(fired, [0, 0, 1, 0])
})

test('hostAlerts: several addresses alarm independently of each other', () => {
  const snap = HOST([EP('a.example', { httpVerdict: 'NO ANSWER' }), EP('b.example')])
  const r1 = hostAlerts({}, snap, HOPTS)
  assert.equal(r1.alerts.length, 1)
  const snap2 = HOST([EP('a.example', { httpVerdict: 'NO ANSWER' }), EP('b.example', { httpVerdict: 'NO ANSWER' })])
  const r2 = hostAlerts(r1.next, snap2, HOPTS)
  assert.equal(r2.alerts.length, 1, 'only the new address')
  assert.equal(r2.alerts[0].addr, 'b.example')
})

test('hostAlerts: the estate chooses the words for no-answer and capacity', () => {
  const opts = { noAnswer: 'SILENT', httpPrefix: 'CODE ', capacity: /FULL/ }
  const r = hostAlerts({}, HOST([EP('a.example', { httpVerdict: 'SILENT' })], { capacityVerdict: 'FULL 95%' }), opts)
  assert.deepEqual(r.alerts.map(a => a.kind).sort(), ['capacity', 'http'])
  assert.equal(hostAlerts({}, HOST([EP('a.example', { httpVerdict: 'NO ANSWER' })]), opts).alerts.length, 0)
})

test('jobAlerts: a known cause travels into the alert', () => {
  // Seven jobs in four domains died on an account's spending cap, found ten
  // days later. An alert that only says rc=1 sends the reader to the wrong log.
  const r = jobAlerts({}, [J('a', 'last run exited rc=1', { cause: 'the account spending cap was hit' })], JOPTS)
  assert.equal(r.alerts[0].cause, 'the account spending cap was hit')
})

test('jobAlerts: without a known cause the field is empty, never undefined in the mail', () => {
  const r = jobAlerts({}, [J('a', 'last run exited rc=1')], JOPTS)
  assert.equal(r.alerts[0].cause, '')
})

test('jobAlerts: a known cause alarms EVEN when the verdict is ok', () => {
  // An invalid grant can stand in the log while the job exits 0 - green but with
  // holes in the data. Without this that silence would have stood.
  const r = jobAlerts({}, [J('a', 'ok', { cause: 'the OAuth token is dead' })], JOPTS)
  assert.equal(r.alerts.length, 1)
  assert.equal(r.alerts[0].verdict, 'ok')
  assert.equal(r.alerts[0].cause, 'the OAuth token is dead')
})

test('jobAlerts: ok with a cause is deduplicated, and resets when the cause goes away', () => {
  const withCause = [J('a', 'ok', { cause: 'token dead' })]
  const r1 = jobAlerts({}, withCause, JOPTS)
  assert.equal(r1.alerts.length, 1)
  assert.equal(jobAlerts(r1.next, withCause, JOPTS).alerts.length, 0, 'dedup')
  const r3 = jobAlerts(r1.next, [J('a', 'ok')], JOPTS)
  assert.deepEqual(r3.next, {}, 'the cause gone => the job drops out of the state')
  assert.equal(jobAlerts(r3.next, withCause, JOPTS).alerts.length, 1, 'a return is a new event')
})

test('jobAlerts: the same verdict but a NEW cause is new information', () => {
  const r1 = jobAlerts({}, [J('a', 'last run exited rc=1', { cause: 'spending cap' })], JOPTS)
  const r2 = jobAlerts(r1.next, [J('a', 'last run exited rc=1', { cause: 'logged out' })], JOPTS)
  assert.equal(r2.alerts.length, 1)
  assert.equal(r2.alerts[0].cause, 'logged out')
})

// --- groupJobAlerts ----------------------------------------------------------
test('groupJobAlerts: the same known cause becomes ONE event', () => {
  // Seven jobs in four domains died on a spending cap. Seven mails about the
  // same thing are read as one - or none.
  const alerts = ['a', 'b', 'c'].map(j => ({ job: j, verdict: 'last run exited rc=1', cause: 'spending cap' }))
  const { groups, singles } = groupJobAlerts(alerts)
  assert.equal(groups.length, 1)
  assert.deepEqual(groups[0].jobs, ['a', 'b', 'c'])
  assert.equal(singles.length, 0)
})

test('groupJobAlerts: DIFFERENT causes are never grouped together', () => {
  const { groups, singles } = groupJobAlerts([
    { job: 'a', cause: 'spending cap' }, { job: 'b', cause: 'logged out' },
  ])
  assert.equal(groups.length, 0, 'two separate events are not one')
  assert.equal(singles.length, 2)
})

test('groupJobAlerts: a lone cause becomes an ordinary alert, not a group of one', () => {
  const { groups, singles } = groupJobAlerts([{ job: 'a', cause: 'spending cap' }])
  assert.equal(groups.length, 0)
  assert.deepEqual(singles.map(s => s.job), ['a'])
})

test('groupJobAlerts: jobs WITHOUT a cause always get their own alerts', () => {
  const { groups, singles } = groupJobAlerts([
    { job: 'a', verdict: 'RAN WITHOUT DELIVERY', cause: '' },
    { job: 'b', verdict: 'NO delivery found', cause: '' },
  ])
  assert.equal(groups.length, 0)
  assert.equal(singles.length, 2)
})

test('groupJobAlerts: a group and singles at the same time - nothing is lost', () => {
  const { groups, singles } = groupJobAlerts([
    { job: 'a', cause: 'cap' }, { job: 'b', cause: 'cap' },
    { job: 'c', cause: '' }, { job: 'd', cause: 'alone' },
  ])
  assert.equal(groups.length, 1)
  assert.deepEqual(groups[0].jobs, ['a', 'b'])
  assert.deepEqual(singles.map(s => s.job).sort(), ['c', 'd'])
})

// --- authExpired / authAlerts ------------------------------------------------
const PANE = (...lines) => lines.join('\n')

test('authExpired: a fresh logout line is recognised', () => {
  assert.equal(authExpired(PANE('❯ question', '', '⏺ Login expired · Please run /login', '', '✻ Baked for 0s')), true)
})

test('authExpired: text that MENTIONS the string does not match', () => {
  // This session writes about logouts. It must not match itself - the same trap
  // paneBusy fell into with 'esc to interrupt'.
  assert.equal(authExpired('I am reasoning about ⏺ Login expired · Please run /login in a sentence'), false)
  assert.equal(authExpired(PANE('the code does: ⏺ Login expired', 'and then more text')), false)
})

test('authExpired: an old line far up in the transcript is ignored', () => {
  const old = PANE('⏺ Login expired · Please run /login', ...Array(40).fill('later answer'))
  assert.equal(authExpired(old), false, 'the line stays forever - only the bottom counts')
})

test('authExpired: an empty or missing pane is not a logout', () => {
  assert.equal(authExpired(null), false)
  assert.equal(authExpired(''), false)
})

test('authAlerts: alarms once per session, not every five minutes', () => {
  const obs = [{ name: 'alpha', expired: true }]
  const r1 = authAlerts({}, obs)
  assert.deepEqual(r1.alerts, [{ session: 'alpha' }])
  assert.equal(authAlerts(r1.next, obs).alerts.length, 0, 'dedup')
})

test('authAlerts: healthy sessions drop out of the state => the next logout alarms', () => {
  const r1 = authAlerts({}, [{ name: 'alpha', expired: true }])
  const r2 = authAlerts(r1.next, [{ name: 'alpha', expired: false }])
  assert.deepEqual(r2.next, {})
  assert.equal(authAlerts(r2.next, [{ name: 'alpha', expired: true }]).alerts.length, 1)
})

test('authAlerts: several sessions at once alarm separately', () => {
  // Two went within thirteen minutes - both must show.
  const r = authAlerts({}, [{ name: 'alpha', expired: true }, { name: 'hub-one', expired: true }])
  assert.deepEqual(r.alerts.map(a => a.session), ['alpha', 'hub-one'])
})

test('findProcess: finds the process in the LINUX ps format (lstart is identical)', () => {
  // Remote sessions are read via `ssh host ps -eo pid=,lstart=,args=` - the
  // fixture is copied from a session host's live output, not invented.
  const ps = ' 1636587 Thu Aug  6 12:10:01 2026 /opt/agent/.local/share/claude/versions/2.1.223/claude --continue --permission-mode bypassPermissions --remote-control Hub: machine'
  const p = findProcess(ps, 'Hub: machine')
  assert.ok(p, 'the process was not found')
  assert.equal(p.pid, 1636587)
})

test('findProcess: the tmux server process line NEVER matches', () => {
  // Copied from a session host's live pgrep output: the tmux server carries the
  // whole start command including the label. Without the binary anchor both
  // the Linux supervision and the watch saw a "living" session whose claude
  // was dead.
  const tmuxOnly = ' 1637265 Thu Aug  6 12:10:01 2026 tmux new-session -d -s machine -c /opt/agent/Projects/machine /opt/agent/.local/bin/claude --continue --permission-mode bypassPermissions --remote-control "Hub: machine"; exec bash'
  assert.equal(findProcess(tmuxOnly, 'Hub: machine'), null, 'the tmux server is not claude')
  const both = tmuxOnly + '\n 1637301 Thu Aug  6 12:10:03 2026 /opt/agent/.local/share/claude/versions/2.1.223/claude --continue --permission-mode bypassPermissions --remote-control Hub: machine'
  assert.equal(findProcess(both, 'Hub: machine').pid, 1637301, 'the claude line must win')
})

// --- browserSleep ------------------------------------------------------------
const sleepN = (n, obs, prev = {}, opts = { idleCycles: 12 }) => {
  let st = prev, fired = []
  for (let i = 0; i < n; i++) { const r = browserSleep(st, obs, opts); st = r.next; fired.push(...r.suspend) }
  return { st, fired }
}

test('browserSleep: a profile without clients sleeps AFTER the threshold, not before', () => {
  const { fired } = sleepN(11, { profile1: 0 })
  assert.deepEqual(fired, [], '11 cycles must not be enough')
  const { fired: f2 } = sleepN(12, { profile1: 0 })
  assert.deepEqual(f2, ['profile1'])
})

test('browserSleep: ONE connection resets the counter entirely', () => {
  // The most dangerous fault would be falling asleep in the middle of a job. A
  // scanner makes many short connections; each one must suffice to keep the
  // profile awake.
  let st = sleepN(11, { profile1: 0 }).st
  const r = browserSleep(st, { profile1: 1 }, { idleCycles: 12 })
  assert.deepEqual(r.suspend, [])
  assert.equal(r.next.profile1.idle, 0, 'the counter must start over from zero')
  const { fired } = sleepN(11, { profile1: 0 }, r.next)
  assert.deepEqual(fired, [], 'and then the whole threshold is required again')
})

test('browserSleep: a sleeping profile is not suspended over and over', () => {
  const { st } = sleepN(12, { profile1: 0 })
  const { fired } = sleepN(20, { profile1: 0 }, st)
  assert.deepEqual(fired, [], 'already asleep must not be sent again')
})

test('browserSleep: a sleeping profile that answers again counts as awake', () => {
  // The wake-up happens outside the watch. When clients appear the watch must
  // believe the MEASUREMENT, not its own bookkeeping.
  const { st } = sleepN(12, { profile1: 0 })
  assert.equal(st.profile1.suspended, true)
  const r = browserSleep(st, { profile1: 3 }, { idleCycles: 12 })
  assert.equal(r.next.profile1.suspended, false)
  assert.equal(r.next.profile1.idle, 0)
})

test('browserSleep: neverSleep protects a profile entirely', () => {
  const { fired } = sleepN(30, { profile3: 0 }, {}, { idleCycles: 12, neverSleep: ['profile3'] })
  assert.deepEqual(fired, [], 'a protected profile must never sleep')
})

test('browserSleep: several profiles are counted independently', () => {
  let st = {}
  for (let i = 0; i < 11; i++) st = browserSleep(st, { a: 0, b: 0 }, { idleCycles: 12 }).next
  const r = browserSleep(st, { a: 0, b: 4 }, { idleCycles: 12 })
  assert.deepEqual(r.suspend, ['a'], 'only the one without clients')
  assert.equal(r.next.b.idle, 0)
})

test('browserSleep: an unknown profile in obs creates state without sleeping at once', () => {
  const r = browserSleep({}, { fresh: 0 }, { idleCycles: 12 })
  assert.deepEqual(r.suspend, [])
  assert.equal(r.next.fresh.idle, 1)
})

// --- restartIntentFresh: the cap that stops a marker left behind ------------
// A marker left behind silences the next REAL crash. The cap is the whole
// protection, so it is tested with the time passed in instead of waited out.
test('restartIntentFresh: a fresh marker counts as intent', () => {
  assert.equal(restartIntentFresh(1000, 1000 + 60_000, 15 * 60_000), true)
})
test('restartIntentFresh: a marker exactly at the cap still counts', () => {
  assert.equal(restartIntentFresh(0, 15 * 60_000, 15 * 60_000), true)
})
test('restartIntentFresh: a marker OVER the cap is forgotten, not current', () => {
  assert.equal(restartIntentFresh(0, 15 * 60_000 + 1, 15 * 60_000), false)
})
test('restartIntentFresh: an mtime in the future (clock skew) counts as fresh', () => {
  assert.equal(restartIntentFresh(2000, 1000, 15 * 60_000), true)
})
test('restartIntentFresh: garbage values give false, never a silent intent', () => {
  assert.equal(restartIntentFresh(NaN, 1000, 1000), false)
  assert.equal(restartIntentFresh(1000, undefined, 1000), false)
})

// sessionScope - THE WATCH IS THE HUB'S, NOT ONE MACHINE'S. The hub's own name
// used to be written in as "home": every session with another HOST was read over
// ssh. With a hub per machine the watch must ask which machine IT stands on, and
// leave hosts operated by another hub alone - the same OPERATOR rule the host
// probe uses.
test('sessionScope: HOST = our hub => local, whatever the hub is called', () => {
  assert.equal(sessionScope({ host: 'host-two' }, { localHub: 'host-two' }), 'local')
  assert.equal(sessionScope({ host: 'hub-one' }, { localHub: 'hub-one' }), 'local')
})

test('sessionScope: a missing HOST => local (a row without a host lives where the watch stands)', () => {
  assert.equal(sessionScope({}, { localHub: 'host-two' }), 'local')
  assert.equal(sessionScope({ host: '' }, { localHub: 'host-two' }), 'local')
})

test('sessionScope: another host that WE operate => remote (read over ssh)', () => {
  const operators = { 'host-two': 'hub-one' }
  assert.equal(sessionScope({ host: 'host-two' }, { localHub: 'hub-one', operators }), 'remote')
})

test('sessionScope: another host without a known operator => remote (unknown is not somebody else\'s)', () => {
  assert.equal(sessionScope({ host: 'sandbox' }, { localHub: 'hub-one', operators: {} }), 'remote')
})

test('sessionScope: a host operated by ANOTHER hub => foreign (neither read nor alarmed)', () => {
  const operators = { 'host-two': 'host-two', 'hub-one': 'hub-one' }
  assert.equal(sessionScope({ host: 'host-two' }, { localHub: 'hub-one', operators }), 'foreign')
  assert.equal(sessionScope({ host: 'hub-one' }, { localHub: 'host-two', operators }), 'foreign')
})

