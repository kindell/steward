// watch/restart-session.mjs - the escalation path: restart a registered
// session's process and resume the conversation at once (seconds, not the
// watch's five-minute window). Usage: restart-session.mjs <session> [reason]
//
// The row comes through the ONE reader (estate.mjs), the socket from the
// estate; the notice is the watch's own words in English.
import { execFile } from 'node:child_process'
import { promisify } from 'node:util'
import { homedir } from 'node:os'
import { join } from 'node:path'
import { findProcess, paneState } from './lib.mjs'
import { runResume, injectNote, capturePane, sleep } from './resume.mjs'
import { listSessions, estate as readEstate } from './estate.mjs'

const exec = promisify(execFile)

const name = process.argv[2]
const reason = process.argv[3] ?? 'on request (for instance an MCP reload)'
if (!name) { console.error('usage: restart-session.mjs <session> [reason]'); process.exit(64) }

const est = await readEstate()
const SOCK = join(homedir(), '.tmux', est.tmuxSocket)
const row = (await listSessions()).find(s => s.name === name)
if (!row) { console.error(`${name}: not a session the registry knows`); process.exit(1) }
if (row.rcLabel === '') { console.error(`${name}: an RC-free session is found on its pane, not its label - restart it through its supervisor`); process.exit(1) }
const { rcLabel } = row

const ps = async () => (await exec('ps', ['-ax', '-o', 'pid=,lstart=,command='], { maxBuffer: 8 * 1024 * 1024 })).stdout

const before = findProcess(await ps(), rcLabel)
if (!before) { console.error(`${name}: no process to restart`); process.exit(1) }
console.log(`killing ${name} (pid ${before.pid})...`)
await exec('kill', [String(before.pid)])

// Wait for the respawn (the supervisor and any environment refresh can take a
// while) and a fresh start screen.
let proc = null
for (let i = 0; i < 45; i++) {
  await sleep(4000)
  proc = findProcess(await ps(), rcLabel)
  if (proc && proc.pid !== before.pid) {
    const pane = paneState(await capturePane(SOCK, name))
    if (pane?.fresh && !pane.busy) break
  }
  proc = null
}
if (!proc) { console.error(`${name}: no fresh respawn within 3 minutes - check the supervisor`); process.exit(1) }
console.log(`respawned (pid ${proc.pid}) - resuming...`)

const result = await runResume(SOCK, name)
if (!result.ok) {
  console.error(`resume failed: ${result.reason}\n${result.paneText ?? ''}`)
  process.exit(1)
}
await injectNote(SOCK, name, `[the hub] Your process was restarted ${reason} and the conversation is resumed. A resume is invisible from inside - new pid ${proc.pid}, MCP servers reloaded.`)
console.log(`${name}: restarted + resumed + notice injected (pid ${before.pid} -> ${proc.pid})`)
process.exit(0)
