// watch/session-watch.mjs - the session watch: one cycle of observation and
// decision over every session the hub is responsible for.
//
// Carried over from the estate's watchdog (2026-09-06). The core is here:
// liveness per session (the pane's pid for an RC-free row, the label
// otherwise), the pause and restart markers, auto-resume with a notice, stuck
// input, blocked, logged out, the bus's unacknowledged and unreadable mail, the
// mechanical answerer, and the alarm channel. Two probes - jobs and hosts - run
// only if the estate names a command for them. What was macOS-only in the
// estate's copy (a desktop service watch, a binary pin, branded browser
// bundles, browser activity) stays in the estate.
//
// NOTHING ESTATE-SPECIFIC LIVES HERE. The registry is read through the one
// reader (estate.mjs -> registry-dump -> lib/registry.sh); the socket, the ping
// text, the state and pause directories, the alarm channel and the probe hooks
// are the estate's keys. "Home" is the machine the watch stands on (hostname,
// STEWARD_LOCAL_HUB in tests), and the account the watch runs as is the one
// whose sessions it can inspect.
//
// DRY RUN: STEWARD_WATCH_DRY_RUN=1 prints every alert instead of mailing it,
// and tolerates an estate without an alarm channel. Everything else runs.
import { execFile } from 'node:child_process'
import { promisify } from 'node:util'
import { readFileSync, readdirSync, writeFileSync, mkdirSync, statSync, unlinkSync } from 'node:fs'
import { homedir, userInfo } from 'node:os'
import { join, dirname } from 'node:path'
import { fileURLToPath } from 'node:url'
import { sessionScope, findProcess, findProcessByPanePid, paneState, decide, busAlert, malformedAlert, parseBusDump, jobAlerts, groupJobAlerts, hostAlerts, HOST_UNKNOWN_CYCLES, authExpired, authAlerts, restartIntentFresh, credentialAlerts } from './lib.mjs'
import { sendMail } from './send-mail.mjs'
import { runResume, injectNote, sleep, redeliverStuck, clearStuckInput } from './resume.mjs'
import { listSessions, hostOperators, estate as readEstate } from './estate.mjs'

const exec = promisify(execFile)
const HERE = dirname(fileURLToPath(import.meta.url))
// THE PRODUCT'S OWN CLI, FOUND FROM HERE AND NOT FROM PATH. A watch that
// resolved `steward` through PATH would run whichever copy a login shell
// happened to find first - and on a host that has both a checkout and a
// deployed home that is a real choice, made silently, by an environment this
// process does not control.
const STEWARD_BIN = join(HERE, '..', 'bin', 'steward')
const DRY = !!process.env.STEWARD_WATCH_DRY_RUN
// The cap on a restart marker. An intent ages: a marker older than this is
// forgotten, not current, and a real crash after it must alarm.
const MAX_RESTART_MS = 15 * 60 * 1000

// THE BUS LIBRARY IS ONE HOP UP IN A DEPLOYED HOME (scripts/bus beside
// scripts/watch) and under linux/hub in the checkout. The same two-layout
// resolution as the hub library's own.
function busLib() {
  for (const p of [join(HERE, '..', 'bus', 'lib.sh'), join(HERE, '..', 'linux', 'hub', 'lib.sh')]) {
    try { statSync(p); return p } catch {}
  }
  return null
}
function busBin(name) {
  for (const p of [join(HERE, '..', 'bus', 'bin', name), join(HERE, '..', 'linux', 'hub', 'bin', name)]) {
    try { statSync(p); return p } catch {}
  }
  return null
}

try {
  const est = await readEstate()
  const SOCK = join(homedir(), '.tmux', est.tmuxSocket)
  const STATE_DIR = join(homedir(), '.local', 'state', est.stateDirName)
  // TWO FILES, AND A DRY RUN NEVER TOUCHES THE ONE THAT MATTERS. Every alarm
  // here de-duplicates against the previous cycle's state, so a dry run that
  // wrote the real file would mark alerts as "already sent" WITHOUT sending
  // them - and the next real cycle would stay silent about exactly what the dry
  // run just found.
  //
  // MEASURED, not reasoned: a dry cycle at the estate's own threshold produced
  // one credential alert and wrote its key; the real cycle immediately after,
  // same threshold and same rows, produced ZERO. The alarm was silenced by the
  // act of measuring it. This was never specific to credentials - the job, host
  // and bus alarms in this file have de-duplicated the same way since they were
  // written.
  //
  // A dry run READS its own file as well, so repeated dry runs still behave
  // like consecutive cycles for anyone testing the de-duplication - they simply
  // do it in a world of their own.
  const STATE_PATH = join(STATE_DIR, DRY ? 'watch.dry.json' : 'watch.json')
  const PAUSED_DIR = join(homedir(), '.local', 'state', est.pausedDirName)
  const RESTART_DIR = join(STATE_DIR, 'restart')
  const PREFIX = `${est.hubSession} watch`
  const ME = userInfo().username
  if (!DRY && (!est.mailAccountFile || !est.alertTo)) {
    console.error('session-watch: REFUSING - the estate names no alarm channel (MAIL_ACCOUNT_FILE and ALERT_TO). A watch that cannot alarm is not a watch; set STEWARD_WATCH_DRY_RUN=1 to run without one.')
    process.exit(78)
  }
  const accountFile = est.mailAccountFile ? join(homedir(), '.config', 'mail-accounts', est.mailAccountFile) : ''
  let sent = 0
  const mail = async (subject, text) => {
    if (DRY) { console.log(`ALERT: ${subject}\n${text}\n`); sent++; return }
    await sendMail({ to: est.alertTo, subject, text }, { accountFile })
    sent++
  }
  const decideOpts = { pingText: est.pingMsg, subjectPrefix: PREFIX, attachHint: `tmux -S ~/.tmux/${est.tmuxSocket} attach -t <session>` }

  // THE WATCH IS THE HUB'S, NOT ONE MACHINE'S. "Home" is the machine the watch
  // stands on, and a host operated by another hub (hosts.d OPERATOR) is skipped
  // entirely: not read, not alarmed, not counted.
  const localHub = process.env.STEWARD_LOCAL_HUB || (await exec('hostname', ['-s'])).stdout.trim()
  const operators = await hostOperators()
  const scopeOf = new Map()
  const sessions = []
  for (const s of await listSessions()) {
    const scope = sessionScope(s, { localHub, operators })
    if (scope === 'foreign') { console.log(`${s.name}: ${s.host} is operated by ${operators[s.host]}, not ${localHub} - skipped`); continue }
    scopeOf.set(s.name, scope)
    sessions.push(s)
  }

  let state = {}
  try { state = JSON.parse(readFileSync(STATE_PATH, 'utf-8')) } catch {}

  const { stdout: psText } = await exec('ps', ['-ax', '-o', 'pid=,lstart=,command='], { maxBuffer: 8 * 1024 * 1024 })
  const ssh = (s, cmd) => exec('ssh', ['-oBatchMode=yes', '-oConnectTimeout=8', '-l', s.owner, s.host, cmd], { maxBuffer: 8 * 1024 * 1024 })

  const authObs = []
  for (const s of sessions) {
    try {
      // REMOTE SESSIONS (another host that we operate): the same observations,
      // fetched over ssh. The ps format is identical, so findProcess /
      // paneState / decide are reused untouched. Actions are NEVER taken
      // remotely - the host's own supervision owns the resurrection.
      const remote = scopeOf.get(s.name) === 'remote'
      let psLocal = psText
      if (remote) {
        try { psLocal = (await ssh(s, 'ps -eo pid=,lstart=,args=')).stdout }
        catch { psLocal = '' /* an unreachable host: proc=null => the missing alarm, which is right */ }
      }
      // CENTRALLY INSPECTABLE? A session whose owner's account the hub does not
      // reach cannot be MEASURED from here - a bound key answers rc 0 with relay
      // noise, so neither the catch above nor an empty ps reveals it. Its health
      // is owned by the host's own supervisor. Locally, the account the watch
      // runs as is the one it can inspect; another owner's tmux is 0750 away.
      const procInspectable = remote ? s.owner === ME : (!s.owner || s.owner === ME)
      // AN RC-FREE SESSION IS FOUND ON THE PANE, NOT ON THE LABEL. If tmux does
      // not answer the pid is empty and findProcessByPanePid gives null, which is
      // right: we do not know whether it lives, and unknown must not look healthy.
      let proc
      if (s.rcLabel === '') {
        let panePid = ''
        try {
          const { stdout } = remote
            ? await ssh(s, `tmux list-panes -t '=${s.name}' -F '#{pane_pid}'`)
            : await exec('tmux', ['-S', SOCK, 'list-panes', '-t', `=${s.name}`, '-F', '#{pane_pid}'])
          panePid = stdout.trim().split('\n')[0] || ''
        } catch { panePid = '' }
        proc = findProcessByPanePid(psLocal, panePid)
      } else {
        proc = findProcess(psLocal, s.rcLabel)
      }
      let pane = null, paneRaw = ''
      if (proc) {
        try {
          const { stdout } = remote
            ? await ssh(s, `tmux capture-pane -t ${s.name} -p`)
            : await exec('tmux', ['-S', SOCK, 'capture-pane', '-t', s.name, '-p'])
          paneRaw = stdout
          pane = paneState(stdout)
        } catch { pane = null }
      }
      const nowIso = new Date().toISOString()
      const nowMs = Date.now()
      // PAUSED ON PURPOSE IS NOT A FAULT. Without this the watch mails "no
      // process" every five minutes about a session somebody switched off - and
      // then the alarms are noise. The marker is the intent; the missing process
      // is only the consequence.
      let paused = false
      try {
        paused = remote
          ? await ssh(s, `test -f $HOME/.local/state/${est.pausedDirName}/${s.name}`).then(() => true, () => false)
          : (statSync(join(PAUSED_DIR, s.name)), true)
      } catch { paused = false }
      if (paused) {
        state[s.name] = { ...(state[s.name] || {}), paused: true }
        console.log(`session ${s.name}: paused - skipped`)
        continue
      }
      if (state[s.name]?.paused) state[s.name] = { ...state[s.name], paused: false }
      // A DELIBERATE RESTART IS NOT A CRASH. Without this the watch cannot tell
      // "somebody restarted it on purpose" from "it died", and does the only thing
      // it can - auto-resumes and mails. THE MARKER IS ONE-SHOT and consumed here;
      // a marker left behind would silence the next REAL crash, so it also has a
      // cap: older than MAX_RESTART_MS it is forgotten and removed.
      const restartPath = join(RESTART_DIR, s.name)
      let restartIntent = false
      if (!remote) {
        try {
          const st = statSync(restartPath)
          if (restartIntentFresh(st.mtimeMs, nowMs, MAX_RESTART_MS)) restartIntent = true
          else { try { unlinkSync(restartPath) } catch {}
                 console.log(`session ${s.name}: restart marker older than ${MAX_RESTART_MS / 60000} min - ignored and removed`) }
        } catch { restartIntent = false }
      }
      // The process may be gone between the kill and the respawn. Under the
      // intent that absence is expected and must not alarm.
      if (restartIntent && !proc) {
        console.log(`session ${s.name}: a deliberate restart is in progress - the process is not back yet, skipped`)
        continue
      }
      // The login state is read from the SAME pane already captured.
      authObs.push({ name: s.name, expired: pane ? authExpired(paneRaw) : false })
      const { alerts, actions, next } = decide(state[s.name], { name: s.name, proc, procUnknown: !procInspectable, pane }, nowIso, decideOpts)
      state[s.name] = next
      for (const a of alerts) {
        try { await mail(a.subject, a.body) }
        catch (e) { console.error(`mail error (${s.name}): ${e.message}`) }
      }
      for (const act of actions) {
        // Remote actions are not taken: observation over ssh, action locally on
        // the host. A failed remote resume would be worse than an honest alarm.
        if (remote) { console.log(`remote session ${s.name}: action ${act.type} is left to the host's supervision`); continue }
        if (act.type === 'reinject') {
          // reinjected is set ONLY after a successful redelivery - the busy guard
          // in redeliverStuck otherwise defers to the next cycle (decide then
          // issues the same action again).
          try {
            const r = await redeliverStuck(SOCK, s.name, act.text, act.isPing)
            if (r.ok) state[s.name] = { ...state[s.name], stuck: { text: act.text, reinjected: true, alerted: false } }
          } catch (e) { console.error(`redelivery error (${s.name}): ${e.message}`) }
          continue
        }
        if (act.type === 'clearStuck') {
          try { await clearStuckInput(SOCK, s.name) } catch (e) { console.error(`clear error (${s.name}): ${e.message}`) }
          continue
        }
        if (act.type !== 'resume') continue
        // The intent wins over the resume: a restart somebody ASKED for must give
        // a FRESH thread, not a resumed one. The marker is consumed here whatever
        // happens - it has done its job by being read.
        if (restartIntent) {
          try { unlinkSync(restartPath) } catch {}
          state[s.name] = { ...state[s.name], startEpoch: proc.startEpoch }
          console.log(`session ${s.name}: deliberate restart (pid ${proc.pid}) - no auto-resume, no alarm`)
          continue
        }
        try {
          const result = await runResume(SOCK, s.name)
          if (result.ok) {
            state[s.name] = { ...state[s.name], startEpoch: proc.startEpoch }
            try {
              await injectNote(SOCK, s.name, `[the watch] Your process died unexpectedly and was respawned at ${new Date(proc.startEpoch).toISOString()}; I have auto-resumed the conversation. A resume is invisible from inside - your context is continuous but the process history has a break (new pid ${proc.pid}). MCP servers are reloaded.`)
              await sleep(1000)
            } catch (e) { console.error(`notice error (${s.name}): ${e.message}`) }
            try { await mail(`${PREFIX}: auto-resumed ${s.name}`, `${s.name} respawned (pid ${proc.pid}) and was auto-resumed by the watch. (${nowIso})`) }
            catch (e) { console.error(`mail error (${s.name}): ${e.message}`) }
          } else {
            try { await mail(`${PREFIX}: auto-resume failed in ${s.name} - do it by hand`, `${s.name} respawned (pid ${proc.pid}) but the auto-resume failed: ${result.reason}.\n\nPane excerpt:\n${result.paneText ?? '(no pane)'}\n\nRun the resume procedure by hand. (${nowIso})`) }
            catch (e) { console.error(`mail error (${s.name}): ${e.message}`) }
          }
        } catch (e) { console.error(`resume error (${s.name}): ${e.message}`) }
      }
    } catch (e) { console.error(`watch error (${s.name}): ${e.message}`) }
  }

  // --- the login: is any session logged out? --------------------------------
  // Long-lived sessions hold their copy of the login in memory; jobs are fresh
  // processes and never notice.
  try {
    const { alerts, next } = authAlerts(state.authAlerts, authObs)
    state.authAlerts = next
    for (const a of alerts) {
      try {
        await mail(`${PREFIX}: ${a.session} is logged out - it will not answer until you log in`,
          `The session ${a.session} answers "Login expired · Please run /login" instead of doing anything.\n\n`
            + `This affects ONLY long-lived sessions - scheduled jobs are fresh processes and are not affected.\n\n`
            + `Remedy: run /login in the session. It costs no restart and no conversation.\n`
            + `(${new Date().toISOString()})`)
      } catch (e) { console.error(`mail error (auth:${a.session}): ${e.message}`) }
    }
  } catch (e) { console.error(`login check error: ${e.message}`) }

  // --- the bus: MACHINE ANSWERS BEFORE MODEL ANSWERS ------------------------
  // Before the bus sweep alarms about unacknowledged mail, FRAGA records in the
  // hub's own inbox are answered mechanically from the catalogue. THE ORDER IS
  // NOT COSMETIC: run after the alarm, a question the hub could answer in a
  // second generates an unacknowledged alarm to a human. A question outside the
  // catalogue is LEFT on purpose and takes the ordinary path. A fault here must
  // not abort the sweep: the answerer is a shortcut, and a broken shortcut falls
  // back on the main road.
  try {
    const answerer = busBin('bus-fraga-svar')
    if (answerer) {
      const { stdout } = await exec('bash', [answerer, est.hubSession])
      const t = stdout.trim()
      if (t && !/: 0 answered/.test(t)) console.log(t)
    }
  } catch (e) { console.error(`answerer: ${e.message}`) }

  // --- the bus: unacknowledged mail ------------------------------------------
  const busRecipients = [...new Set(sessions.map(s => s.name))]
  const busByName = new Map(sessions.map(s => [s.name, s]))
  const busState = state.bus && typeof state.bus === 'object' ? state.bus : {}
  const nowEpoch = Math.floor(Date.now() / 1000)
  // The ssh dump of a remote session's bus directory: inbox json + malformed
  // count in ONE round trip, as the owner. EACCES != EMPTY: an unreadable
  // directory is reported as such, never as zero records.
  const busDumpCmd = (n) =>
    `d="$HOME/.config/agent-bus/${n}"; [ -d "$d" ] || { echo NODIR; exit 0; }; ` +
    `[ -r "$d/inbox" ] || { echo EACCES; exit 0; }; ` +
    `for f in "$d"/inbox/*.json; do [ -e "$f" ] || continue; echo "===F==="; cat "$f"; echo; done; ` +
    `echo "===MALFORMED==="; ls "$d"/malformed/*.json 2>/dev/null | wc -l`
  for (const name of busRecipients) {
    try {
      const sess = busByName.get(name)
      const remote = scopeOf.get(name) === 'remote'
      // THE HUB INSPECTS ONLY ITS OWN ACCOUNT. Another person's account is
      // closed on purpose: the hub's only key into it is the BOUND delivery key,
      // which can deliver mail and nothing else. Such a session's bus health is
      // owned by its OWN supervisor on the host. Logged once per run, never
      // mailed - otherwise a deliberate isolation becomes recurring noise.
      const inspectable = remote ? sess.owner === ME : (!sess.owner || sess.owner === ME)
      let files = [], mcount = 0, reachErr = null
      if (!inspectable) {
        console.log(`bus: ${name} is owned by ${sess.owner} - not inspectable from here (bound key), its health is the host's supervisor's`)
        busState[name] = { ...(busState[name] ?? {}), foreignOwner: true }
        continue
      }
      if (remote) {
        try {
          const { stdout } = await ssh(sess, busDumpCmd(name))
          const parsed = parseBusDump(stdout, nowEpoch)
          if (parsed.eacces) { reachErr = `EACCES: the bus directory of ${name} could not be read (permissions)` }
          else { files = parsed.files; mcount = parsed.malformedCount }
        } catch (e) { reachErr = e.message /* an unreachable host: DISTINCT from empty, alarmed below */ }
      } else {
        const inbox = join(homedir(), '.config', 'agent-bus', name, 'inbox')
        let entries = []
        try { entries = readdirSync(inbox).filter(f => f.endsWith('.json')) } catch { entries = [] }
        files = entries.map(f => {
          let from = '', text = '', ts = 0
          try {
            const data = JSON.parse(readFileSync(join(inbox, f), 'utf-8'))
            from = data.from ?? ''; text = data.text ?? ''
            if (Number.isFinite(data.ts)) ts = data.ts
          } catch { /* an unreadable record - treat as very old, alarm rather than keep quiet */ }
          return { name: f, ageSec: nowEpoch - ts, from, text }
        })
        const malformedDir = join(homedir(), '.config', 'agent-bus', name, 'malformed')
        try { mcount = readdirSync(malformedDir).filter(f => f.endsWith('.json')).length } catch { mcount = 0 }
      }
      const prevState = busState[name] ?? {}
      // CANNOT REACH != NOTHING TO REACH. An unreachable remote host must not look
      // like an empty inbox. Alarm on unreachability (deduplicated until it is
      // reachable again), and do NOT touch the bus/malformed state, so a gap does
      // not reset the dedup.
      if (reachErr) {
        busState[name] = { ...prevState, unreachable: true }
        if (!prevState.unreachable) {
          const line = `${PREFIX}: cannot reach the inbox of ${name} on ${sess.host} (${sess.owner}) - the bus alarm is BLIND for the session until the host answers`
          try { await mail(line, `${line}\n\nssh error: ${reachErr}\n\nWhile this stands, an unacknowledged or unreadable record may lie unseen. (${new Date().toISOString()})`) }
          catch (e) { console.error(`mail error (bus-unreach:${name}): ${e.message}`) }
        }
        continue
      }
      const { alert, reping, next } = busAlert(prevState, files, nowEpoch)
      busState[name] = { ...next, malformed: prevState.malformed ?? 0, unreachable: false }
      // The re-ping is an ACTION, and this watch never acts remotely: a remote
      // session gets its re-ping from its OWN supervisor on the host.
      if (reping && !remote) {
        const lib = busLib()
        if (lib) {
          try { await exec('bash', ['-c', `source '${lib}' && bus_tmux_ping '${name}'`]) }
          catch (e) { console.error(`re-ping error (bus:${name}): ${e.message}`) }
        }
      }
      // THE CONTENT DOES NOT TRAVEL, and that is an ownership boundary, not
      // caution: the line once carried the message's TEXT in the subject of a
      // mail to one address, and mail to another person's session would have had
      // its content mailed to somebody else. The sender stays; the content goes.
      if (alert) {
        const line = `${PREFIX}: ${alert.count} unacknowledged to ${name} despite re-pings (oldest ${alert.oldestAgeMin}m, from ${alert.from})`
        try { await mail(line, `${line}\n\nThe session does not react to bus pings - look at it. (${new Date().toISOString()})`) }
        catch (e) { console.error(`mail error (bus:${name}): ${e.message}`) }
      }
      // UNREADABLE mail in malformed/ - must never happen (the relay writes atomically).
      const mres = malformedAlert(busState[name].malformed ?? 0, mcount)
      busState[name] = { ...busState[name], malformed: mres.next }
      if (mres.alert) {
        const line = `${PREFIX}: ${mres.alert.count} UNREADABLE record(s) to ${name} in malformed/ (must never happen - the relay writes atomically)`
        try { await mail(line, `${line}\n\nA record could not be parsed and was parked in malformed/ instead of being buried in done. Look at the files. (${new Date().toISOString()})`) }
        catch (e) { console.error(`mail error (bus-malformed:${name}): ${e.message}`) }
      }
    } catch (e) { console.error(`bus error (${name}): ${e.message}`) }
  }
  state.bus = busState

  // --- jobs: has every scheduled job actually delivered? ---------------------
  // ONLY IF THE ESTATE NAMES A PROBE (JOB_STATUS_CMD). A FAILED MEASUREMENT
  // TOUCHES NO STATE: if the tool crashes, an empty job list would otherwise
  // equal "all healthy" - and the next cycle would alarm about everything again.
  if (est.jobStatusCmd) {
    try {
      let jobs = null
      try {
        const { stdout } = await exec('bash', ['-c', est.jobStatusCmd], { maxBuffer: 4 * 1024 * 1024 })
        const parsed = JSON.parse(stdout)
        if (Array.isArray(parsed.jobs) && parsed.jobs.length) jobs = parsed.jobs
      } catch (e) { console.error(`job probe failed: ${e.message}`) }
      if (jobs) {
        const { alerts, next } = jobAlerts(state.jobAlerts, jobs)
        state.jobAlerts = next
        // Seven jobs with the same known cause are ONE event, not seven mails.
        const { groups, singles } = groupJobAlerts(alerts)
        for (const g of groups) {
          const subject = `${PREFIX}: ${g.jobs.length} jobs stopped by the same cause`
          const body = `The following jobs alarmed at the same time:\n\n${g.jobs.map(j => `  - ${j}`).join('\n')}`
            + `\n\nKNOWN CAUSE: ${g.cause}\n`
            + `\nThis is ONE event, not ${g.jobs.length}. Investigate the cause, not the jobs.`
            + ` (${new Date().toISOString()})`
          try { await mail(subject, body) } catch (e) { console.error(`mail error (job group): ${e.message}`) }
        }
        for (const a of singles) {
          // A job that went well but carries a known cause must NOT get a subject
          // saying "ok" - the mail would read as confirmation, not as a warning.
          const subject = a.verdict.startsWith('ok') && a.cause
            ? `${PREFIX}: ${a.job} went through BUT has a known fault in its output`
            : `${PREFIX}: the job ${a.job} - ${a.verdict}`
          const body = `${a.job}: ${a.verdict}.\n\n`
            + (a.lastRun ? `Last run: ${new Date(a.lastRun * 1000).toISOString()}.\n` : '')
            + (a.cause ? `\nKNOWN CAUSE: ${a.cause}\n` : '')
            + (a.note ? `\nAbout the receipt: ${a.note}\n` : '')
            + `\nThe job RAN - it is the delivery that is missing, which an exit code would never have shown.`
            + ` (${new Date().toISOString()})`
          try { await mail(subject, body) } catch (e) { console.error(`mail error (job:${a.job}): ${e.message}`) }
        }
      }
    } catch (e) { console.error(`job alarm error: ${e.message}`) }
  }

  // --- credentials: is a refresh token about to run out? ---------------------
  // WHY THIS RUNS THE PRODUCT'S OWN VERB rather than the estate's shim. The
  // seam is bash and this file is node; running the shim here would put the
  // seam's field counting, its stamp grammar and its closed state vocabulary
  // into a second language. `steward registry credentials --json` is the one
  // reader, and this is one of its two consumers.
  //
  // A FAILED MEASUREMENT TOUCHES NO STATE, the same rule the job probe lives
  // under: if the verb cannot answer, an empty row list would read as "every
  // credential is fine" and the state would be rewritten to say so - and the
  // next cycle, with a working verb, would then alarm about everything at once.
  {
    try {
      let rows = null
      try {
        const { stdout } = await exec(STEWARD_BIN, ['registry', 'credentials', '--json'],
                                      { maxBuffer: 4 * 1024 * 1024, timeout: 60000 })
        const parsed = JSON.parse(stdout)
        if (Array.isArray(parsed.rows)) rows = parsed.rows
      } catch (e) { console.error(`credential probe failed: ${e.message}`) }
      if (rows) {
        const days = Number(est.credentialWarnDays || 3)
        const { alerts, next } = credentialAlerts(state.credentialAlerts, rows, new Date().toISOString(), { days })
        state.credentialAlerts = next
        for (const a of alerts) {
          // THE SUBJECT SAYS WHICH LOGIN AND HOW LONG, because a subject that
          // said only "a credential expires" is a subject somebody reads on a
          // phone and postpones. The three kinds are deliberately different
          // sentences: one is a warning, one is an outage, and one is a
          // measurement this alarm could not read.
          const subject = a.kind === 'expired'
            ? `${PREFIX}: the login ${a.login} has an EXPIRED refresh token - it cannot sign in`
            : a.kind === 'unreadable-deadline'
              ? `${PREFIX}: the login ${a.login} has a refresh deadline that cannot be read`
              : `${PREFIX}: the login ${a.login} needs a new sign-in within ${a.days} day(s)`
          const body = `Login: ${a.login}\n`
            + `Refresh token expires: ${a.refreshExpires || '(none reported)'}\n`
            + `Measured at: ${a.measuredAt || '(not stamped)'}\n\n`
            + (a.kind === 'expired'
                ? 'This login can no longer refresh its session. Somebody must sign in again on the host that owns it.'
                : a.kind === 'unreadable-deadline'
                  ? 'The seam reported a deadline this alarm could not parse. It is being reported rather than'
                    + ' ignored, because a deadline nobody can read is not a deadline that has been checked.'
                  : `The refresh token runs out inside the estate's warning window of ${a.days} day(s).`
                    + ' Signing in again before then avoids an outage; after it, the session stops mid-work.')
            + `\n\nThe deadline above is what the estate's own credential reader measured. This message is the`
            + ` only place that compared it to a clock. (${new Date().toISOString()})`
          try { await mail(subject, body) } catch (e) { console.error(`mail error (credential:${a.login}): ${e.message}`) }
        }
      }
    } catch (e) { console.error(`credential alarm error: ${e.message}`) }
  }

  // --- hosts: do the machines we operate answer? -----------------------------
  if (est.hostStatusCmd) {
    try {
      let snapshot = null
      try {
        const { stdout } = await exec('bash', ['-c', est.hostStatusCmd], { maxBuffer: 4 * 1024 * 1024, timeout: 120000 })
        const parsed = JSON.parse(stdout)
        if (Array.isArray(parsed.hosts) && parsed.hosts.length) snapshot = parsed
      } catch (e) { console.error(`host probe failed: ${e.message}`) }
      if (snapshot) {
        const { alerts, next } = hostAlerts(state.hostAlerts, snapshot)
        state.hostAlerts = next
        for (const a of alerts) {
          const what = { http: 'does not answer', cert: 'certificate', capacity: 'capacity', unmeasured: 'UNMEASURED' }[a.kind] ?? a.kind
          const subject = `${PREFIX}: ${a.host}/${a.addr} - ${what}`
          const body = `${a.addr} on the host ${a.host}: ${a.detail}.\n`
            + (a.owner ? `The address is owned by ${a.owner}.\n` : '')
            + (a.kind === 'unmeasured'
              ? `\nThis is not an established fault - it is that we DO NOT KNOW, and have not for ${HOST_UNKNOWN_CYCLES} measurements in a row. Silence is not health.`
              : '')
            + `\n(${new Date().toISOString()})`
          try { await mail(subject, body) } catch (e) { console.error(`mail error (host:${a.addr}): ${e.message}`) }
        }
      }
    } catch (e) { console.error(`host alarm error: ${e.message}`) }
  }

  mkdirSync(dirname(STATE_PATH), { recursive: true, mode: 0o700 })
  writeFileSync(STATE_PATH, JSON.stringify(state, null, 1))
  console.log(`session-watch: ${sessions.length} sessions checked, ${sent} alerts`)
} catch (e) {
  console.error(`session-watch: fatal: ${e.stack || e.message}`)
  process.exit(e?.code === 78 || /exit code 78|code 78/.test(String(e?.message)) ? 78 : 1)
}
process.exit(0)
