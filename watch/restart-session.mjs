// watch/restart-session.mjs - the escalation path: restart a registered claude-code session's
// process and resume the conversation at once (seconds, not the watch's five-minute window).
// Usage: restart-session.mjs <session> [reason]
//
// THE PROCESS IS NAMED BY THE BRIDGE ADAPTER AND KILLED THROUGH THE PIN (spec §1; plan Task 7).
// linux/bridge-observe.sh answers what the row's managed process is; only identified:managed is
// ever acted on. The kill goes through linux/bridge-kill.py with the pid AND its birth token: the
// helper pins the process before it reads the birth, and refuses (rc 65) when the process under
// that pid is not the one observed - then this script re-observes instead of killing anything.
// Nothing here ever runs `kill`, and nothing here finds a process by its label.
//
// The row comes through the ONE reader (estate.mjs), the socket from the estate; every keystroke
// goes to the bridge's exact pane; the notice is the watch's own words in English.
import { execFile } from 'node:child_process'
import { promisify } from 'node:util'
import { homedir } from 'node:os'
import { join, dirname } from 'node:path'
import { statSync } from 'node:fs'
import { fileURLToPath } from 'node:url'
import { parseObserveLine, paneState } from './lib.mjs'
import { runResume, injectNote, capturePane, sleep } from './resume.mjs'
import { listSessions, estate as readEstate } from './estate.mjs'

const exec = promisify(execFile)
const HERE = dirname(fileURLToPath(import.meta.url))
function beside(envName, ...candidates) {
  if (process.env[envName]) return process.env[envName]
  for (const p of candidates) { try { statSync(p); return p } catch {} }
  return null
}
const OBSERVE = beside('STEWARD_BRIDGE_OBSERVE', join(HERE, '..', 'bridge-observe.sh'), join(HERE, '..', 'linux', 'bridge-observe.sh'))
const BKILL = beside('STEWARD_BRIDGE_KILL', join(HERE, '..', 'bridge-kill.py'), join(HERE, '..', 'linux', 'bridge-kill.py'))

const name = process.argv[2]
const reason = process.argv[3] ?? 'on request (for instance an MCP reload)'
if (!name) { console.error('usage: restart-session.mjs <session> [reason]'); process.exit(64) }

const est = await readEstate()
const SOCK = join(homedir(), '.tmux', est.tmuxSocket)
const STATE_DIR = join(homedir(), '.local', 'state', est.stateDirName)
const row = (await listSessions()).find(s => s.name === name)
if (!row) { console.error(`${name}: not a session the registry knows`); process.exit(1) }
if ((row.runtime || 'claude-code') !== 'claude-code') { console.error(`${name}: a ${row.runtime} row is restarted through its own supervisor, not here`); process.exit(1) }
if (!OBSERVE || !BKILL) { console.error(`${name}: the bridge observer or kill helper is not beside this script (observer ${OBSERVE ?? 'missing'}, helper ${BKILL ?? 'missing'})`); process.exit(78) }

const observe = async () => {
  const { stdout } = await exec('bash', [OBSERVE, row.id], { env: { ...process.env, STEWARD_STATE_DIR: STATE_DIR, STEWARD_TMUX_SOCKET: SOCK } })
  return parseObserveLine(stdout, row.id)
}

let before
try { before = await observe() } catch (e) { console.error(`${name}: the observer's answer could not be read: ${e.message}`); process.exit(1) }
if (before.answer !== 'identified:managed') {
  console.error(`${name}: identity is '${before.answer}' (${before.classes || 'no classes'}), not identified:managed - nothing is killed on that`)
  process.exit(1)
}
console.log(`killing ${name} (pid ${before.pid}, birth ${before.birth}) through the pin...`)
try { await exec(BKILL, [String(before.pid), before.birth, 'TERM']) }
catch (e) {
  if (e.code === 65) { console.error(`${name}: the pin REFUSED - the process under pid ${before.pid} is not the one observed (${(e.stderr ?? '').trim()}). Re-observe and try again; nothing was signalled.`); process.exit(1) }
  console.error(`${name}: bridge-kill failed (rc ${e.code}): ${(e.stderr ?? e.message).trim()}`); process.exit(1)
}

// Wait for the respawn (the supervisor and any environment refresh can take a while): a NEW
// identified:managed with a different pid, and a fresh start screen in ITS pane.
let after = null
for (let i = 0; i < 45; i++) {
  await sleep(4000)
  let o
  try { o = await observe() } catch { continue }
  if (o.answer === 'identified:managed' && o.pid !== before.pid) {
    const pane = paneState(await capturePane(SOCK, o.pane))
    if (pane?.fresh && !pane.busy) { after = o; break }
  }
}
if (!after) { console.error(`${name}: no fresh identified respawn within 3 minutes - check the supervisor`); process.exit(1) }
console.log(`respawned (pid ${after.pid}, pane ${after.pane}) - resuming...`)

const result = await runResume(SOCK, after.pane)
if (!result.ok) {
  console.error(`resume failed: ${result.reason}\n${result.paneText ?? ''}`)
  process.exit(1)
}
await injectNote(SOCK, after.pane, `[the hub] Your process was restarted ${reason} and the conversation is resumed. A resume is invisible from inside - new pid ${after.pid}, MCP servers reloaded.`)
console.log(`${name}: restarted + resumed + notice injected (pid ${before.pid} -> ${after.pid})`)
process.exit(0)
