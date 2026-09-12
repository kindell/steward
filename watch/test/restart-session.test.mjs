// watch/test/restart-session.test.mjs - the escalation path acts only on identified:managed, kills
// only through the pin, and refuses everything else before anything is signalled. The observer
// and the kill helper are stubs on PATH (STEWARD_BRIDGE_OBSERVE / STEWARD_BRIDGE_KILL); the
// registry and estate are fixtures read through the real bridge. Only the refusal paths run here:
// they return before the respawn poll, so the suite stays fast.
import { test } from 'node:test'
import assert from 'node:assert/strict'
import { execFile } from 'node:child_process'
import { promisify } from 'node:util'
import { mkdtempSync, mkdirSync, writeFileSync, readFileSync, chmodSync, existsSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join, dirname } from 'node:path'
import { fileURLToPath } from 'node:url'

const exec = promisify(execFile)
const RESTART = join(dirname(dirname(fileURLToPath(import.meta.url))), 'restart-session.mjs')
const US = String.fromCharCode(31)

function fixture({ identity = 'managed', killRc = 0 } = {}) {
  const fx = mkdtempSync(join(tmpdir(), 'restart-'))
  const home = join(fx, 'hh'); mkdirSync(home, { recursive: true }); mkdirSync(join(fx, 'reg')); mkdirSync(join(fx, 'bin')); mkdirSync(join(fx, 'hosts.d'))
  writeFileSync(join(fx, 'estate.conf'), [
    'RC_LABEL_PREFIX="Hub: "', 'HUB_SESSION="hub-one"', 'HUB_HOST="host-one"', 'TMUX_SOCKET="hub-one.sock"',
    'PING_MSG="[bus] you have mail"', 'STATE_DIR_NAME="hub-supervisor"', 'PAUSED_DIR_NAME="hub-paused"',
    'OP_TOKEN_FILE_NAME="op-token"', 'JOB_LOG_DIR="hub-jobs"', 'JOB_LABEL_PREFIX="io.example.job"', 'SERVICE_LABEL_PREFIX="io.example.service"', 'BROWSER_LABEL_PREFIX="io.example.browser"', 'LABEL_PREFIX="io.example"',
  ].join('\n') + '\n')
  writeFileSync(join(fx, 'reg', 'alpha.conf'), 'REPO_PATH="/tmp/x"\nRC_LABEL="Hub: alpha"\nOWNER="' + process.env.USER + '"\nDOMAIN="entity-one"\n')
  writeFileSync(join(fx, 'reg', 'advisor.conf'), 'REPO_PATH="/tmp/x"\nRC_LABEL=""\nOWNER="' + process.env.USER + '"\nDOMAIN="entity-one"\nKIND="advisor"\nRUNTIME="opencode"\nMODEL="openai/m"\nOPENCODE_VERSION="1.0.0"\nOPENCODE_PORT="4097"\nAUTO_APPROVE="true"\nCLAUDE_MEMORY_ROOT="/tmp/m"\n')
  const stub = (name, body) => { const p = join(fx, 'bin', name); writeFileSync(p, '#!/bin/bash\n' + body); chmodSync(p, 0o755) }
  const line = identity === 'managed'
    ? ['alpha', 'identified:managed', '4243', 'boot-r:111', 'alpha:@0.%0', 'Hub: alpha', '1789000000000', 'alive', 'live:managed', '', '4243', 't', '1789000000000', '$7:1', '777']
    : ['alpha', identity, '', '', '', '', '', 'none', 'unclassifiable', '', '', '', '', '', '']
  stub('bridge-observe', `printf '%s\\n' "${line.join(US)}"\n`)
  stub('bridge-kill', `printf '%s\\n' "$*" >> "$KILL_LOG"; [ ${killRc} -ne 0 ] && { echo "bridge-kill: REFUSING - birth differs" >&2; exit ${killRc}; }; echo "killed $1 $2 TERM"\n`)
  return { fx, home, killLog: join(fx, 'kill.log') }
}
async function run({ fx, home, killLog }, name) {
  const env = { PATH: process.env.PATH, HOME: home, USER: process.env.USER, KILL_LOG: killLog,
    STEWARD_ESTATE: join(fx, 'estate.conf'), STEWARD_REGISTRY_DIR: join(fx, 'reg'), STEWARD_HOSTS_DIR: join(fx, 'hosts.d'),
    STEWARD_BRIDGE_OBSERVE: join(fx, 'bin', 'bridge-observe'), STEWARD_BRIDGE_KILL: join(fx, 'bin', 'bridge-kill') }
  try { const { stdout, stderr } = await exec('node', [RESTART, name], { env, timeout: 20000 }); return { code: 0, stdout, stderr } }
  catch (e) { return { code: e.code, stdout: e.stdout ?? '', stderr: e.stderr ?? '' } }
}
const killed = (f) => existsSync(f.killLog) ? readFileSync(f.killLog, 'utf-8') : ''

test('an OpenCode row is refused before anything is observed or signalled', async () => {
  const f = fixture(); const r = await run(f, 'advisor')
  assert.equal(r.code, 1); assert.match(r.stderr, /opencode row is restarted through its own supervisor/); assert.equal(killed(f), '')
})
test('identity unknown: nothing is killed on that', async () => {
  const f = fixture({ identity: 'unknown' }); const r = await run(f, 'alpha')
  assert.equal(r.code, 1); assert.match(r.stderr, /identity is 'unknown'/); assert.equal(killed(f), '')
})
test('identity no-process: nothing to kill, nothing signalled', async () => {
  const f = fixture({ identity: 'no-process' }); const r = await run(f, 'alpha')
  assert.equal(r.code, 1); assert.match(r.stderr, /identity is 'no-process'/); assert.equal(killed(f), '')
})
test('the pin refuses (rc 65): the script stops and says to re-observe; the helper saw pid, birth and TERM', async () => {
  const f = fixture({ killRc: 65 }); const r = await run(f, 'alpha')
  assert.equal(r.code, 1); assert.match(r.stderr, /the pin REFUSED/); assert.match(r.stderr, /Re-observe/)
  assert.equal(killed(f).trim(), '4243 boot-r:111 TERM')
})
test('an unknown session name is refused', async () => {
  const f = fixture(); const r = await run(f, 'nobody')
  assert.equal(r.code, 1); assert.match(r.stderr, /not a session the registry knows/)
})
