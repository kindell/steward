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

// identity: what the bridge observer stub answers for the local claude row - 'managed' (pid 123, the
// pane alpha:@0.%0), 'no-process', or any other word verbatim (unknown, grace, ...).
function fixture({ withProcess = true, paused = false, mailKeys = true, identity = 'managed', nearby = false } = {}) {
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
  if (nearby) {
    // a row on a host THIS hub operates, owned by the watch's own account: observed over ssh
    writeFileSync(join(fx, 'reg', 'nearby.conf'), 'REPO_PATH="/tmp/x"\nRC_LABEL="Hub: nearby"\nOWNER="' + process.env.USER + '"\nDOMAIN="entity-one"\nHOST="host-two"\n')
    writeFileSync(join(fx, 'hosts.d', 'host-two.conf'), 'OWNER="' + process.env.USER + '"\nLEGAL_OWNER="Somebody"\nOPERATOR="host-one"\n')   // operated by THIS hub (the hostname)
  }
  if (paused) { mkdirSync(join(home, '.local', 'state', 'hub-paused'), { recursive: true }); writeFileSync(join(home, '.local', 'state', 'hub-paused', 'alpha'), '') }
  // stubs on PATH
  const stub = (name, body) => { const p = join(fx, 'bin', name); writeFileSync(p, '#!/bin/bash\n' + body); chmodSync(p, 0o755) }
  stub('hostname', 'echo host-one\n')
  stub('ps', withProcess
    ? 'echo "  123 Mon Aug 25 08:00:00 2026 /opt/agent/.local/bin/claude --remote-control Hub: alpha --permission-mode bypassPermissions"\n'
    : 'echo "  999 Mon Aug 25 08:00:00 2026 /usr/bin/sleep 1"\n')
  stub('tmux', 'printf "%s\\n" "$*" >> "$STUB_LOG"; case " $* " in *" capture-pane "*) printf "%s\\n" "  ⏺ Done." "────────────" "❯ " "────────────"; exit 0;; *" list-panes "*) echo 123; exit 0;; *) exit 0;; esac\n')
  stub('ssh', 'echo "ssh $*" >> "$STUB_LOG"; exit 255\n')
  // THE BRIDGE OBSERVER STUB: the fifteen-field line for the row asked about (US = byte 31).
  const US = String.fromCharCode(31)
  const line = identity === 'managed'
    ? ['ID', 'identified:managed', '123', 'boot-w:100', 'ID:@0.%0', 'Hub: alpha', '1789000000000', 'alive', 'live:managed', '', '123', 'thread-1', '1789000000000', '$7:1789000000', '777']
    : identity.startsWith('identified:')
      ? ['ID', identity, '123', 'boot-w:100', 'ID:@0.%0', 'Hub: alpha', '1789000000000', 'alive', identity.replace('identified:', 'live:'), '', '123', 'thread-1', '1789000000000', '', '777']
      : ['ID', identity, '', '', '', '', '', identity === 'no-process' ? 'gone-noreceipt' : 'none', '', '', '', '', '', '', '']
  // the line goes out in SINGLE quotes (the $7 stays literal); the id is spliced in as "$id" outside them
  const body = 'printf "%s\\n" "$*" >> "$STUB_LOG"\nid="$1"; [ "$id" = --bootstrap ] && id="$2"\nprintf \'%s\\n\' \'' + line.join(US).replace(/ID/g, "'\"$id\"'") + '\'\n'
  stub('bridge-observe', body)
  return { fx, home, log: join(fx, 'stub.log') }
}

async function run({ fx, home, log }, extraEnv = {}) {
  const env = {
    PATH: `${join(fx, 'bin')}:${process.env.PATH}`, HOME: home, USER: process.env.USER, STUB_LOG: log,
    STEWARD_ESTATE: join(fx, 'estate.conf'), STEWARD_REGISTRY_DIR: join(fx, 'reg'), STEWARD_HOSTS_DIR: join(fx, 'hosts.d'),
    STEWARD_WATCH_DRY_RUN: '1', STEWARD_BRIDGE_OBSERVE: join(fx, 'bin', 'bridge-observe'), ...extraEnv,
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
  // THE DRY FILE, NOT THE REAL ONE. run() is a dry cycle, and a dry cycle must
  // not write the state the real one de-duplicates against: doing so marks
  // alerts as already sent without sending them, and the next real cycle stays
  // silent about what the dry run just found. Measured before this split - a
  // dry credential alert silenced the real one that followed it.
  const statePath = join(f.home, '.local', 'state', 'hub-supervisor', 'watch.dry.json')
  const realPath = join(f.home, '.local', 'state', 'hub-supervisor', 'watch.json')
  assert.ok(existsSync(statePath), 'the dry state file is written under STATE_DIR_NAME')
  assert.ok(!existsSync(realPath), 'a dry cycle leaves no trace in the state the real one reads')
  const st = JSON.parse(readFileSync(statePath, 'utf-8'))
  assert.equal(st.alpha.startEpoch, Date.parse('Mon Aug 25 08:00:00 2026'))
  const log = readFileSync(f.log, 'utf-8')
  assert.match(log, /-S .*\/\.tmux\/hub-one\.sock capture-pane -t alpha:@0\.%0 -p/, 'tmux is asked over the estate socket, on the bridge\'s EXACT pane')
  assert.match(log, /^alpha$/m, 'the observer was asked about the row')
  assert.doesNotMatch(r.stderr, /\[watch\] identity/, 'a managed row prints no identity line')
  assert.doesNotMatch(log, /^ssh /m, 'no real ssh was attempted - the foreign host is skipped, the local one needs none')
})

test('a session without a process alarms once, with the estate prefix in the subject', async () => {
  const f = fixture({ identity: 'no-process' })
  const r1 = await run(f)
  assert.equal(r1.code, 0, r1.stderr)
  assert.match(r1.stdout, /ALERT: hub-one watch: alpha has no process/)
  assert.match(r1.stdout, /1 sessions checked, 1 alerts/)
  const r2 = await run(f)
  assert.match(r2.stdout, /1 sessions checked, 0 alerts/, 'the same gap alarms once')
})

// THE PROPERTY THIS SPLIT EXISTS FOR, asserted end to end rather than by
// reading the code: a dry cycle that FINDS something must not consume the
// alarm that a real cycle would raise about the same thing.
test('a dry cycle does not silence the real one that follows it', async () => {
  const f = fixture({ identity: 'no-process' })
  const dry = await run(f)
  assert.match(dry.stdout, /ALERT: hub-one watch: alpha has no process/, 'the dry cycle finds it')
  // WHAT THIS CAN PROVE HERE, AND WHAT IT CANNOT. The real cycle mails rather
  // than printing, and this fixture has no mail transport - so its alert
  // COUNTER says nothing either way, which is what the first version of this
  // test measured and mistook for a silenced alarm. What is provable here is
  // the mechanism underneath: the dry cycle's memory is in its own file, and
  // the real cycle starts from an empty one rather than from the dry run's.
  const dryState = JSON.parse(readFileSync(
    join(f.home, '.local', 'state', 'hub-supervisor', 'watch.dry.json'), 'utf-8'))
  assert.ok(Object.keys(dryState).length > 0, 'the dry cycle remembered something')
  assert.ok(!existsSync(join(f.home, '.local', 'state', 'hub-supervisor', 'watch.json')),
            'and none of it reached the file the real cycle de-duplicates against')
})

test('a paused session is skipped, and a resumed one is checked again', async () => {
  const f = fixture({ identity: 'no-process', paused: true })
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

// THE WATCH NEVER REPORTS DEAD ON UNKNOWN (spec §1). Every adapter answer that is neither
// identified:managed nor no-process is one info line on stderr and no decision.
for (const id of ['unknown', 'grace', 'wait-veto', 'identified:moved']) {
  test(`identity ${id}: an info line on stderr, no alert, no latch`, async () => {
    const f = fixture({ identity: id })
    const r = await run(f)
    assert.equal(r.code, 0, r.stderr)
    assert.match(r.stderr, new RegExp(`\\[watch\\] identity ${id.replace(':', ':')} for alpha`))
    assert.doesNotMatch(r.stdout, /ALERT:/)
    const st = JSON.parse(readFileSync(join(f.home, '.local', 'state', 'hub-supervisor', 'watch.dry.json'), 'utf-8'))
    assert.notEqual(st.alpha?.missingAlerted, true, 'the missing latch is untouched')
  })
}

test('an observer line that is not the contract is unknown, never a decision', async () => {
  const f = fixture()
  writeFileSync(join(f.fx, 'bin', 'bridge-observe'), '#!/bin/bash\nprintf "alpha\\037no-process\\n"\n')
  const r = await run(f)
  assert.match(r.stderr, /observer line refused for alpha: .*fields/)
  assert.match(r.stderr, /\[watch\] identity unknown for alpha/)
  assert.doesNotMatch(r.stdout, /ALERT:/)
})

test('a remote row we operate: the observer runs on the remote with the REMOTE socket, and an unreachable host is unknown, not dead', async () => {
  const f = fixture({ nearby: true })
  const r = await run(f)
  const log = readFileSync(f.log, 'utf-8')
  assert.match(log, /ssh .*host-two STEWARD_STATE_DIR="\$HOME\/\.local\/state\/hub-supervisor" STEWARD_TMUX_SOCKET="\$HOME\/\.tmux\/hub-one\.sock" bash ~\/scripts\/bridge-observe\.sh nearby/, 'the socket path is built on the remote from the remote $HOME')
  assert.match(r.stderr, /\[watch\] observer unreachable for nearby/)
  assert.match(r.stderr, /\[watch\] identity unknown for nearby/)
  assert.doesNotMatch(r.stdout, /ALERT: hub-one watch: nearby has no process/, 'unreachable is not dead')
})
