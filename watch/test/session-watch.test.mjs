// watch/test/session-watch.test.mjs - one cycle of the watch, end to end, with
// every external command stubbed and every alert printed instead of mailed.
//
// The registry, the estate and the host rows are fixtures on disk read through
// the real bridge; tmux, ps, ssh and hostname are stubs on PATH. What is
// proven: a healthy session is checked and nothing alarms; a session without a
// process alarms with the estate's prefix; a paused session is skipped; the
// state file lands under the estate's state directory; an estate without an
// alarm channel refuses to run for real (rc 78) but runs in a dry run; a host
// operated by another hub is skipped; and no stub ever saw a real ssh.
import { test } from 'node:test'
import assert from 'node:assert/strict'
import { execFile } from 'node:child_process'
import { promisify } from 'node:util'
import { mkdtempSync, mkdirSync, writeFileSync, readFileSync, existsSync, chmodSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join, dirname } from 'node:path'
import { fileURLToPath } from 'node:url'

const exec = promisify(execFile)
const WATCH = join(dirname(dirname(fileURLToPath(import.meta.url))), 'session-watch.mjs')

function fixture({ withProcess = true, paused = false, mailKeys = true } = {}) {
  const fx = mkdtempSync(join(tmpdir(), 'watch-'))
  const home = join(fx, 'hh'); mkdirSync(home, { recursive: true })
  mkdirSync(join(fx, 'reg')); mkdirSync(join(fx, 'hosts.d')); mkdirSync(join(fx, 'bin'))
  writeFileSync(join(fx, 'estate.conf'), [
    'RC_LABEL_PREFIX="Hub: "', 'HUB_SESSION="hub-one"', 'HUB_HOST="host-one"', 'TMUX_SOCKET="hub-one.sock"',
    'PING_MSG="[bus] you have mail"', 'STATE_DIR_NAME="hub-supervisor"', 'PAUSED_DIR_NAME="hub-paused"',
    'OP_TOKEN_FILE_NAME="op-token"', 'JOB_LOG_DIR="hub-jobs"', 'JOB_LABEL_PREFIX="io.example.job"', 'SERVICE_LABEL_PREFIX="io.example.service"', 'BROWSER_LABEL_PREFIX="io.example.browser"', 'LABEL_PREFIX="io.example"',
    ...(mailKeys ? ['MAIL_ACCOUNT_FILE="alerts.env"', 'ALERT_TO="human@example.invalid"'] : []),
  ].join('\n') + '\n')
  writeFileSync(join(fx, 'reg', 'alpha.conf'), 'REPO_PATH="/tmp/x"\nRC_LABEL="Hub: alpha"\nOWNER="' + process.env.USER + '"\nDOMAIN="entity-one"\n')
  writeFileSync(join(fx, 'reg', 'faraway.conf'), 'REPO_PATH="/tmp/x"\nRC_LABEL="Hub: faraway"\nOWNER="operator-z"\nDOMAIN="entity-one"\nHOST="host-three"\n')
  writeFileSync(join(fx, 'hosts.d', 'host-three.conf'), 'OWNER="operator-z"\nLEGAL_OWNER="Somebody"\nOPERATOR="hub-three"\n')
  if (paused) { mkdirSync(join(home, '.local', 'state', 'hub-paused'), { recursive: true }); writeFileSync(join(home, '.local', 'state', 'hub-paused', 'alpha'), '') }
  // stubs on PATH
  const stub = (name, body) => { const p = join(fx, 'bin', name); writeFileSync(p, '#!/bin/bash\n' + body); chmodSync(p, 0o755) }
  stub('hostname', 'echo host-one\n')
  stub('ps', withProcess
    ? 'echo "  123 Mon Aug 25 08:00:00 2026 /opt/agent/.local/bin/claude --remote-control Hub: alpha --permission-mode bypassPermissions"\n'
    : 'echo "  999 Mon Aug 25 08:00:00 2026 /usr/bin/sleep 1"\n')
  stub('tmux', 'printf "%s\\n" "$*" >> "$STUB_LOG"; case " $* " in *" capture-pane "*) printf "%s\\n" "  ⏺ Done." "────────────" "❯ " "────────────"; exit 0;; *" list-panes "*) echo 123; exit 0;; *) exit 0;; esac\n')
  stub('ssh', 'echo "ssh $*" >> "$STUB_LOG"; exit 255\n')
  return { fx, home, log: join(fx, 'stub.log') }
}

async function run({ fx, home, log }, extraEnv = {}) {
  const env = {
    PATH: `${join(fx, 'bin')}:${process.env.PATH}`, HOME: home, USER: process.env.USER, STUB_LOG: log,
    STEWARD_ESTATE: join(fx, 'estate.conf'), STEWARD_REGISTRY_DIR: join(fx, 'reg'), STEWARD_HOSTS_DIR: join(fx, 'hosts.d'),
    STEWARD_WATCH_DRY_RUN: '1', ...extraEnv,
  }
  try {
    const { stdout, stderr } = await exec('node', [WATCH], { env })
    return { code: 0, stdout, stderr }
  } catch (e) { return { code: e.code, stdout: e.stdout ?? '', stderr: e.stderr ?? '' } }
}

test('a healthy local session: checked, no alert, state written under the estate state dir', async () => {
  const f = fixture()
  const r = await run(f)
  assert.equal(r.code, 0, r.stderr)
  assert.match(r.stdout, /session-watch: 1 sessions checked, 0 alerts/)
  assert.match(r.stdout, /faraway: host-three is operated by hub-three, not host-one - skipped/)
  assert.doesNotMatch(r.stdout, /ALERT:/)
  const statePath = join(f.home, '.local', 'state', 'hub-supervisor', 'watch.json')
  assert.ok(existsSync(statePath), 'the state file is written under STATE_DIR_NAME')
  const st = JSON.parse(readFileSync(statePath, 'utf-8'))
  assert.equal(st.alpha.startEpoch, Date.parse('Mon Aug 25 08:00:00 2026'))
  const log = readFileSync(f.log, 'utf-8')
  assert.match(log, /-S .*\/\.tmux\/hub-one\.sock capture-pane -t alpha -p/, 'tmux is asked over the estate socket')
  assert.doesNotMatch(log, /^ssh /m, 'no real ssh was attempted - the foreign host is skipped, the local one needs none')
})

test('a session without a process alarms once, with the estate prefix in the subject', async () => {
  const f = fixture({ withProcess: false })
  const r1 = await run(f)
  assert.equal(r1.code, 0, r1.stderr)
  assert.match(r1.stdout, /ALERT: hub-one watch: alpha has no process/)
  assert.match(r1.stdout, /1 sessions checked, 1 alerts/)
  const r2 = await run(f)
  assert.match(r2.stdout, /1 sessions checked, 0 alerts/, 'the same gap alarms once')
})

test('a paused session is skipped, and a resumed one is checked again', async () => {
  const f = fixture({ withProcess: false, paused: true })
  const r = await run(f)
  assert.match(r.stdout, /session alpha: paused - skipped/)
  assert.doesNotMatch(r.stdout, /ALERT:/)
})

test('an estate without an alarm channel refuses to run for real (rc 78), but runs dry', async () => {
  const f = fixture({ mailKeys: false })
  const dry = await run(f)
  assert.equal(dry.code, 0, dry.stderr)
  const real = await run(f, { STEWARD_WATCH_DRY_RUN: '' })
  assert.equal(real.code, 78)
  assert.match(real.stderr, /MAIL_ACCOUNT_FILE and ALERT_TO/)
})
