#!/usr/bin/env node
// runtime/codex-thread.js - the smallest client that lets a supervised session
// own one Codex thread: create it once, then run one turn per letter.
//
// WHY THIS SHAPE. Codex offers four ways into a thread and only one of them is
// usable here. `codex exec` is the simplest, keeps a stable UUID and resumes
// correctly - but threads it creates are marked `source: exec` and NEVER appear
// in the operator's Codex app, so the human loses the conversation the machine
// is having. `codex queue` only adds to the queue of a thread the daemon is
// already holding. The app-server does appear, and it is the whole contract:
// thread/start, thread/resume, turn/start, and the item/turn notifications.
// Measured 2026-09-07 against 0.153.4.
//
// The transport is `--listen stdio://`: line-delimited JSON-RPC on a child
// process, no websocket, no daemon, no port. The daemon's control socket works
// too, but it speaks websocket over a unix socket and needs an extra library -
// and it holds a write lock, so a thread it owns cannot be resumed by anyone
// else. A short-lived stdio child takes the lock only while the turn runs.
//
//   codex-thread.js turn --cwd DIR --message-file FILE --thread-file PATH
//                        [--name NAME] [--instructions FILE] [--sandbox MODE]
//                        [--model MODEL] [--mcp-config FILE] [--timeout SECONDS]
//
// One verb, because a thread cannot exist without a turn: `thread/start` alone
// leaves nothing on disk, and resuming it fails with "no rollout found for
// thread id" (measured). So the first letter both starts the thread and runs
// in it. --thread-file is the session's memory of which thread is its own: read
// when it exists, written when the thread is born.
//
// stdout carries the agent's final message and nothing else, so a shell can
// capture it directly.
'use strict';
const { spawn } = require('child_process');
const fs = require('fs');
const os = require('os');
const path = require('path');

const EX_USAGE = 64, EX_UNAVAILABLE = 69, EX_SOFTWARE = 70, EX_TEMPFAIL = 75, EX_CONFIG = 78;

function refuse(code, message) {
  process.stderr.write('codex-thread: REFUSING - ' + message + '\n');
  process.exit(code);
}

function parseArgs(argv) {
  const out = { _: [] };
  for (let i = 0; i < argv.length; i++) {
    const a = argv[i];
    if (a.startsWith('--')) {
      const key = a.slice(2);
      const next = argv[i + 1];
      if (next === undefined || next.startsWith('--')) out[key] = true;
      else { out[key] = next; i++; }
    } else out._.push(a);
  }
  return out;
}

function lastLines(text) {
  return text.replace(/\x1b\[[0-9;]*m/g, '').trim().split('\n').slice(-3).join('\n  ');
}

// THE RESOLVED BINARY, symlinks followed. On macOS /opt/homebrew/bin/codex is a
// link and the shell tool's own binary sits beside the TARGET, not beside the
// link - a check that looks next to the link finds nothing and passes silently.
function codexBinReal() {
  const b = codexBin();
  try { return fs.realpathSync(b); } catch { return b; }
}

function codexBin() {
  const explicit = process.env.STEWARD_CODEX_BIN;
  if (explicit) return explicit;
  // ONE NAME, SEVERAL HOMES. The Linux installer puts codex in ~/.local/bin;
  // on macOS it arrives as a Homebrew cask in /opt/homebrew/bin, and a
  // non-interactive ssh session has no Homebrew on PATH at all. Measured on
  // minin 2026-09-07: the default found nothing and the refusal named a path
  // that was never going to exist there.
  const candidates = [
    path.join(os.homedir(), '.local', 'bin', 'codex'),
    path.join(os.homedir(), '.codex', 'packages', 'standalone', 'current', 'bin', 'codex'),
    '/opt/homebrew/bin/codex',
    '/usr/local/bin/codex',
  ];
  for (const c of candidates) { if (fs.existsSync(c)) return c; }
  return candidates[0];
}

// One JSON-RPC conversation over one short-lived app-server child.
class Client {
  constructor(timeoutMs) {
    const bin = codexBin();
    if (!fs.existsSync(bin)) refuse(EX_UNAVAILABLE, 'codex binary is missing: ' + bin);
    this.child = spawn(bin, ['app-server', '--listen', 'stdio://'], {
      stdio: ['pipe', 'pipe', 'pipe'],
    });
    this.child.on('error', (err) => refuse(EX_UNAVAILABLE, 'codex could not start: ' + err.message));
    this.stderr = '';
    this.child.stderr.on('data', (d) => { this.stderr += d.toString(); });
    this.buf = '';
    this.id = 0;
    this.pending = new Map();
    this.listeners = [];
    this.closed = false;
    this.child.stdout.on('data', (d) => this.feed(d.toString()));
    this.child.on('close', () => {
      this.closed = true;
      for (const p of this.pending.values()) p.reject(new Error('app-server closed the connection'));
      this.pending.clear();
    });
    this.timeoutMs = timeoutMs;
  }
  feed(chunk) {
    this.buf += chunk;
    let nl;
    while ((nl = this.buf.indexOf('\n')) >= 0) {
      const line = this.buf.slice(0, nl).trim();
      this.buf = this.buf.slice(nl + 1);
      if (!line) continue;
      let msg;
      try { msg = JSON.parse(line); } catch { continue; }
      if (msg.id !== undefined && this.pending.has(msg.id)) {
        const p = this.pending.get(msg.id);
        this.pending.delete(msg.id);
        if (msg.error) p.reject(new Error(msg.error.message || JSON.stringify(msg.error)));
        else p.resolve(msg.result);
        continue;
      }
      // A REQUEST FROM THE SERVER, not a notification: it has both a method
      // and an id, and it is WAITING for an answer. Ignoring one hangs the turn
      // until the timeout - measured 2026-09-07: a turn that only wanted to run
      // an MCP tool sat silent for 460 seconds. There is no human at this pane,
      // so the policy is answered here, once, in the open: tool calls the
      // registry already granted are approved; anything else is declined.
      if (msg.method && msg.id !== undefined) { this.answerRequest(msg); continue; }
      if (msg.method) for (const fn of this.listeners) fn(msg);
    }
  }
  on(fn) { this.listeners.push(fn); }
  answerRequest(msg) {
    const m = msg.method || '';
    const params = msg.params || {};
    // AN EXACT LIST, AND WHAT IS BEING ASKED - not a substring of the name.
    // The first version approved anything whose method contained "mcp" or
    // "tool", which is a guess about names rather than a decision about
    // questions: `item/tool/requestUserInput` asks the HUMAN for input and
    // would have been answered with an empty accept. The product's integrator
    // named this before it cost anything (2026-09-07).
    //
    // The estate's grant IS the approval for a tool the register put in this
    // thread's config, and a second yes at call time adds nothing but a place
    // to hang. Everything else - a sandbox escape, a command, a skill, a
    // question meant for a person - is declined, because saying yes to those
    // needs a human at the pane.
    const TOOL_CALL_APPROVALS = ['mcpServer/elicitation/request'];
    const kind = (params._meta && params._meta.codex_approval_kind) || '';
    const approve = TOOL_CALL_APPROVALS.indexOf(m) !== -1 &&
                    (kind === '' || kind === 'mcp_tool_call');
    // The decision word is the server's, not ours. Log the exact request the
    // first time each method is seen, so a wrong word shows up as a rejection
    // WITH its cause instead of a silent no.
    if (!this.seenRequests) this.seenRequests = {};
    if (!this.seenRequests[m]) {
      this.seenRequests[m] = 1;
      process.stderr.write('codex-thread: server asked ' + m + ' -> ' + JSON.stringify(msg.params || {}).slice(0, 300) + '\n');
    }
    // Two different answer shapes, because the server asks two different
    // questions. An MCP tool call arrives as an ELICITATION and wants
    // {action: accept|decline}; an execution approval wants {decision}.
    // Answering one in the other's words is a silent no.
    const result = m.indexOf('elicitation') !== -1
      ? (approve ? { action: 'accept', content: {} } : { action: 'decline' })
      : (approve ? { decision: 'approved' } : { decision: 'denied' });
    if (!approve) {
      process.stderr.write('codex-thread: declined ' + m + (kind ? ' [' + kind + ']' : '') +
        ' - only a tool the register granted is approved without a human\n');
    }
    this.child.stdin.write(JSON.stringify({ jsonrpc: '2.0', id: msg.id, result }) + '\n');
  }
  notify(method, params) {
    const m = { jsonrpc: '2.0', method };
    if (params) m.params = params;
    this.child.stdin.write(JSON.stringify(m) + '\n');
  }
  request(method, params) {
    const id = ++this.id;
    const m = { jsonrpc: '2.0', id, method };
    if (params) m.params = params;
    return new Promise((resolve, reject) => {
      if (this.closed) return reject(new Error('app-server is gone'));
      const timer = setTimeout(() => {
        this.pending.delete(id);
        reject(new Error(method + ' timed out'));
      }, this.timeoutMs);
      this.pending.set(id, {
        resolve: (v) => { clearTimeout(timer); resolve(v); },
        reject: (e) => { clearTimeout(timer); reject(e); },
      });
      this.child.stdin.write(JSON.stringify(m) + '\n');
    });
  }
  async handshake() {
    // experimentalApi is what unlocks the granular approval form. Without it
    // the server answers "askForApproval.granular requires experimentalApi
    // capability" - and the only other choice, `never`, REFUSES every MCP tool
    // rather than allowing it. Measured 2026-09-07 against 0.153.4.
    await this.request('initialize', {
      clientInfo: { name: 'steward', title: 'Steward session', version: '1' },
      capabilities: { experimentalApi: true },
    });
    this.notify('initialized');
  }
  end() { try { this.child.stdin.end(); } catch { /* already gone */ } }
}

// MCP: the estate renders one file per session in the shape Claude Code reads
// ({"mcpServers": {name: {command, args, env}}}). Codex takes the same servers
// under a different key, so the adapter translates rather than the estate
// keeping two documents that must agree. A server the estate does not grant is
// a server the thread never sees.
function mcpServers(file) {
  if (!file || file === true) return null;
  if (!fs.existsSync(file)) refuse(EX_UNAVAILABLE, 'mcp config is missing: ' + file);
  let doc;
  try { doc = JSON.parse(fs.readFileSync(file, 'utf8')); }
  catch (err) { refuse(EX_UNAVAILABLE, 'mcp config is not JSON: ' + err.message); }
  const src = doc.mcpServers || {};
  const out = {};
  for (const [name, v] of Object.entries(src)) {
    if (!v || typeof v !== 'object') continue;
    // Only stdio servers translate one to one. A remote server is declared
    // differently and is skipped loudly rather than mistranslated.
    if (!v.command) { process.stderr.write('codex-thread: skipping non-stdio mcp server ' + name + '\n'); continue; }
    const entry = { command: v.command };
    if (Array.isArray(v.args) && v.args.length) entry.args = v.args;
    if (v.env && typeof v.env === 'object' && Object.keys(v.env).length) entry.env = v.env;
    out[name] = entry;
  }
  return Object.keys(out).length ? out : null;
}

function threadParams(args, cwd) {
  // APPROVAL POLICY IS NOT ONE KNOB. `never` means "never ask" - and for an MCP
  // tool call that resolves to a REFUSAL, not to a yes: measured 2026-09-07,
  // the thread reported every history tool "blocked because the tools require
  // approval and the policy is never". The granular form is what says yes on
  // the session's behalf without a human at the pane.
  const p = { cwd, sandbox: args.sandbox || 'read-only', approvalPolicy: args.approval === 'granular'
    ? { granular: { mcp_elicitations: false, rules: false, sandbox_approval: false, request_permissions: false, skill_approval: false } }
    : (args.approval && args.approval !== true ? String(args.approval) : 'never') };
  if (args.model && args.model !== true) p.model = String(args.model);
  const servers = mcpServers(args['mcp-config']);
  if (servers) p.config = Object.assign({}, p.config, { mcp_servers: servers });
  return p;
}

async function cmdTurn(args) {
  const cwd = args.cwd;
  const file = args['message-file'];
  const threadFile = args['thread-file'];
  if (!cwd || cwd === true) refuse(EX_USAGE, 'turn needs --cwd');
  if (!file || file === true) refuse(EX_USAGE, 'turn needs --message-file');
  if (!fs.existsSync(cwd)) refuse(EX_UNAVAILABLE, 'working directory is missing: ' + cwd);
  if (!fs.existsSync(file)) refuse(EX_UNAVAILABLE, 'message file is missing: ' + file);
  const text = fs.readFileSync(file, 'utf8');
  if (!text.trim()) refuse(EX_USAGE, 'the message file is empty');

  let threadId = null;
  if (args.thread && args.thread !== true) threadId = String(args.thread);
  else if (threadFile && threadFile !== true && fs.existsSync(threadFile)) {
    const stored = fs.readFileSync(threadFile, 'utf8').trim();
    if (stored) threadId = stored;
  }

  const timeoutMs = Number(args.timeout || 600) * 1000;
  const c = new Client(timeoutMs);
  const messages = [];
  let failure = null;
  // A FATAL failure is one the environment caused - an expired login, a
  // refused account. It is not the same as a turn that ran and said nothing,
  // and the exit code says which: 78 for "fix your environment", 75 for
  // "try again".
  let fatal = false;
  const finished = new Promise((resolve) => {
    c.on((msg) => {
      const p = msg.params || {};
      if (msg.method === 'item/completed') {
        const item = p.item || {};
        if (item.type === 'agentMessage' && item.text) messages.push(item.text);
      } else if (msg.method === 'turn/completed') {
        // A COMPLETED TURN IS NOT A SUCCESSFUL ONE. The notification carries a
        // status, and a failed turn arrives here with its reason in
        // turn.error.message. Treating the notification itself as success
        // reported "the turn completed without an answer" for a login that had
        // expired - the cause was in the message we threw away. Measured on
        // macOS 2026-09-07 by the product's integrator.
        const t = p.turn || {};
        if (t.status && t.status !== 'completed') {
          failure = (t.error && (t.error.message || t.error.code)) || ('turn status ' + t.status);
          fatal = true;
        }
        resolve();
      } else if (msg.method === 'error' || msg.method === 'thread/error' || msg.method === 'turn/failed') {
        // AN ERROR NOTICE THAT WILL NOT BE RETRIED IS THE ANSWER. Ignoring it
        // and waiting for a turn that never comes turns an unauthorized
        // account into a silent model.
        const info = p.codexErrorInfo || p.error || {};
        failure = (typeof info === 'string' ? info : (info.message || info.code || JSON.stringify(info))) ||
                  JSON.stringify(p).slice(0, 300);
        if (p.codexErrorInfo) failure = String(p.codexErrorInfo) + (p.message ? ': ' + p.message : '');
        if (p.willRetry === false || msg.method !== 'error') { fatal = true; resolve(); }
      }
    });
  });
  const guard = new Promise((resolve) => setTimeout(() => {
    failure = failure || 'the turn did not finish within ' + (timeoutMs / 1000) + 's';
    resolve();
  }, timeoutMs));

  let born = false;
  try {
    await c.handshake();
    if (threadId) {
      await c.request('thread/resume', Object.assign(threadParams(args, cwd), { threadId }));
    } else {
      const params = threadParams(args, cwd);
      if (args.instructions && args.instructions !== true) {
        if (!fs.existsSync(args.instructions)) refuse(EX_UNAVAILABLE, 'instructions file is missing: ' + args.instructions);
        params.developerInstructions = fs.readFileSync(args.instructions, 'utf8');
      }
      const started = await c.request('thread/start', params);
      threadId = started && started.thread && started.thread.id;
      if (!threadId) throw new Error('thread/start returned no id');
      born = true;
      // The name is what the human sees in their thread list. Without it every
      // session is titled by the first sentence of its first letter.
      if (args.name && args.name !== true) {
        try { await c.request('thread/name/set', { threadId, name: String(args.name) }); }
        catch (err) { process.stderr.write('codex-thread: could not name the thread: ' + err.message + '\n'); }
      }
    }
    await c.request('turn/start', { threadId, input: [{ type: 'text', text }] });
    await Promise.race([finished, guard]);
  } catch (err) {
    refuse(EX_TEMPFAIL, err.message + (c.stderr ? '\n  app-server said: ' + lastLines(c.stderr) : ''));
  } finally { c.end(); }

  if (failure) refuse(fatal ? EX_CONFIG : EX_TEMPFAIL, 'the turn did not complete: ' + failure);
  if (!messages.length) refuse(EX_TEMPFAIL, 'the turn completed without an answer');
  // The id is written only after a turn has actually run in the thread: a
  // remembered id that cannot be resumed is worse than none.
  if (born && threadFile && threadFile !== true) {
    fs.mkdirSync(path.dirname(threadFile), { recursive: true });
    fs.writeFileSync(threadFile, threadId + '\n', { mode: 0o600 });
  }
  if (args['print-thread']) process.stderr.write('thread ' + threadId + '\n');
  process.stdout.write(messages[messages.length - 1].replace(/\s+$/, '') + '\n');
}

// PREFLIGHT LIVES HERE, WITH THE PATH LIST. The shell had its own copy of the
// default path and its own timeout, and on the host this check was written for
// it found neither the binary (the list is here, not there) nor a `timeout`
// (macOS has none outside Homebrew, and launchd's PATH has no Homebrew). It
// passed in silence. One list, one timer, one place. Measured by the product's
// integrator 2026-09-07.
function cmdPreflight(args) {
  const host = path.join(path.dirname(codexBinReal()), 'codex-code-mode-host');
  if (!fs.existsSync(host)) { process.stdout.write('no code-mode host beside ' + codexBinReal() + '\n'); return; }
  const seconds = Number(args.timeout || 5);
  const r = require('child_process').spawnSync(host, ['--help'], { timeout: seconds * 1000, stdio: 'ignore' });
  if (r.error && r.error.code === 'ETIMEDOUT') {
    refuse(EX_CONFIG, 'codex-code-mode-host hangs (' + host + '). On macOS this is Gatekeeper holding the binary:\n' +
      '  xattr -d com.apple.quarantine ' + host + '\n' +
      '  Every shell tool call would time out and the model would answer from guesswork.');
  }
  if (r.status !== 0 && !r.error) {
    process.stderr.write('codex-thread: code-mode host answered rc ' + r.status + ' (not a hang; continuing)\n');
  }
  process.stdout.write('code-mode host ok: ' + host + '\n');
}

async function main() {
  const argv = process.argv.slice(2);
  const verb = argv[0];
  const args = parseArgs(argv.slice(1));
  if (verb === 'turn') await cmdTurn(args);
  else if (verb === 'which') process.stdout.write(codexBinReal() + '\n');
  else if (verb === 'preflight') cmdPreflight(args);
  else refuse(EX_USAGE, 'usage: codex-thread.js turn|which|preflight ...');
  process.exit(0);
}

main().catch((err) => refuse(EX_SOFTWARE, err && err.message ? err.message : String(err)));
