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
//                        [--model MODEL] [--timeout SECONDS]
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

const EX_USAGE = 64, EX_UNAVAILABLE = 69, EX_SOFTWARE = 70, EX_TEMPFAIL = 75;

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

function codexBin() {
  const explicit = process.env.STEWARD_CODEX_BIN;
  if (explicit) return explicit;
  return path.join(os.homedir(), '.local', 'bin', 'codex');
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
      if (msg.method) for (const fn of this.listeners) fn(msg);
    }
  }
  on(fn) { this.listeners.push(fn); }
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
    await this.request('initialize', {
      clientInfo: { name: 'steward', title: 'Steward session', version: '1' },
    });
    this.notify('initialized');
  }
  end() { try { this.child.stdin.end(); } catch { /* already gone */ } }
}

function threadParams(args, cwd) {
  const p = { cwd, sandbox: args.sandbox || 'read-only', approvalPolicy: 'never' };
  if (args.model && args.model !== true) p.model = String(args.model);
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
  const finished = new Promise((resolve) => {
    c.on((msg) => {
      const p = msg.params || {};
      if (msg.method === 'item/completed') {
        const item = p.item || {};
        if (item.type === 'agentMessage' && item.text) messages.push(item.text);
      } else if (msg.method === 'turn/completed') resolve();
      else if (msg.method === 'turn/failed' || msg.method === 'thread/error') {
        failure = JSON.stringify(p).slice(0, 400);
        resolve();
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

  if (failure) refuse(EX_TEMPFAIL, 'the turn did not complete: ' + failure);
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

async function main() {
  const argv = process.argv.slice(2);
  const verb = argv[0];
  const args = parseArgs(argv.slice(1));
  if (verb === 'turn') await cmdTurn(args);
  else refuse(EX_USAGE, 'usage: codex-thread.js turn --cwd DIR --message-file FILE --thread-file PATH');
  process.exit(0);
}

main().catch((err) => refuse(EX_SOFTWARE, err && err.message ? err.message : String(err)));
