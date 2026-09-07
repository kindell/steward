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
// thread/start, thread/resume, thread/queue/add, and the item/turn
// notifications. Measured 2026-09-07 against 0.153.4.
//
// THE TRANSPORT IS THE OWNER'S DAEMON. The Codex app keeps one app-server
// daemon per account (`codex app-server daemon`, a websocket on a unix socket
// under ~/.codex/app-server-control/), and that daemon holds the WRITE LOCK on
// every thread the app has open - for as long as the project is open, not just
// while the human types. A second process that resumes the same thread over
// `--listen stdio://` forks the rollout or is refused. Measured 2026-09-07:
// two retries ten minutes apart hit the same lock. So this client is a second
// CLIENT of the same daemon, never a second writer: it appends the letter to
// the thread's queue (`thread/queue/add`) and the daemon runs it - at once if
// the thread is idle, after the human's turn otherwise. The app shows the turn
// as it happens.
//
// There is NO automatic fallback to a stdio child when the daemon is not
// running: a fallback on the same thread recreates two writers the moment the
// app comes back between the check and the write. Without the daemon the
// letter stays where it is and the exit code (69) says what to start.
// `--transport stdio` remains as an EXPLICIT choice for a host that has no
// daemon at all; it is never chosen for you.
//
//   codex-thread.js turn --cwd DIR --message-file FILE --thread-file PATH
//                        --client-id ID [--name NAME] [--instructions FILE]
//                        [--sandbox MODE] [--model MODEL] [--mcp-config FILE]
//                        [--timeout SECONDS] [--transport daemon|stdio]
//
// --client-id is the letter's own id. It travels as `clientUserMessageId`, comes
// back on the userMessage item as `clientId`, is persisted in the rollout, and
// is readable afterwards through `thread/read`. That makes every letter
// idempotent WITHOUT local state: a client that died after queueing asks the
// thread "was this letter answered?" and prints the answer it finds, or waits
// for the turn already running, or queues. Measured 2026-09-07, all five.
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
const crypto = require('crypto');
const fs = require('fs');
const net = require('net');
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

// Where the owner's daemon listens. CODEX_HOME is Codex's own override for
// ~/.codex; the product's own name wins over both so a test can point at a
// fake daemon without a home directory.
function daemonSocket() {
  if (process.env.STEWARD_CODEX_DAEMON_SOCK) return process.env.STEWARD_CODEX_DAEMON_SOCK;
  const home = process.env.CODEX_HOME || path.join(os.homedir(), '.codex');
  return path.join(home, 'app-server-control', 'app-server-control.sock');
}

// --- transports ---------------------------------------------------------------
// Both deliver newline-free JSON documents one at a time to onMessage(text),
// accept write(text), and report onClose(). Whatever else they are is theirs.

// A websocket client small enough to live here. The daemon speaks RFC 6455
// over a unix socket, which Node's built-in WebSocket cannot open and the
// product does not want a dependency for: every home on every host would need
// a node_modules. Client frames are masked (the RFC requires it), server
// frames are not; text frames may be fragmented; pings are answered.
class DaemonTransport {
  constructor(sockPath, onMessage, onClose, onError) {
    this.onMessage = onMessage; this.onClose = onClose; this.onError = onError;
    this.ready = false; this.buf = Buffer.alloc(0); this.fragments = []; this.http = '';
    this.sock = net.connect(sockPath);
    this.sock.on('error', (err) => onError(err));
    this.sock.on('close', () => onClose());
    this.sock.on('data', (d) => this.feed(d));
    this.key = crypto.randomBytes(16).toString('base64');
    this.sock.on('connect', () => {
      this.sock.write('GET / HTTP/1.1\r\nHost: localhost\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n' +
        'Sec-WebSocket-Key: ' + this.key + '\r\nSec-WebSocket-Version: 13\r\n\r\n');
    });
    this.opened = new Promise((resolve, reject) => { this.resolveOpen = resolve; this.rejectOpen = reject; });
  }
  feed(chunk) {
    if (!this.ready) {
      this.http += chunk.toString('latin1');
      const end = this.http.indexOf('\r\n\r\n');
      if (end < 0) return;
      const head = this.http.slice(0, end);
      if (!/^HTTP\/1\.1 101/.test(head)) { this.rejectOpen(new Error('daemon refused the websocket upgrade: ' + head.split('\r\n')[0])); return; }
      const want = crypto.createHash('sha1').update(this.key + '258EAFA5-E914-47DA-95CA-C5AB0DC85B11').digest('base64');
      if (!new RegExp('Sec-WebSocket-Accept: ' + want.replace(/[+/=]/g, '\\$&'), 'i').test(head)) {
        this.rejectOpen(new Error('daemon answered the websocket upgrade with a wrong accept key')); return;
      }
      this.ready = true;
      const rest = Buffer.from(this.http.slice(end + 4), 'latin1');
      this.http = '';
      this.resolveOpen();
      chunk = rest;
    }
    this.buf = Buffer.concat([this.buf, chunk]);
    for (;;) {
      if (this.buf.length < 2) return;
      const b0 = this.buf[0], b1 = this.buf[1];
      const fin = (b0 & 0x80) !== 0, op = b0 & 0x0f, masked = (b1 & 0x80) !== 0;
      let len = b1 & 0x7f, off = 2;
      if (len === 126) { if (this.buf.length < 4) return; len = this.buf.readUInt16BE(2); off = 4; }
      else if (len === 127) { if (this.buf.length < 10) return; len = Number(this.buf.readBigUInt64BE(2)); off = 10; }
      if (masked) off += 4;
      if (this.buf.length < off + len) return;
      let payload = this.buf.slice(off, off + len);
      if (masked) { const m = this.buf.slice(off - 4, off); payload = Buffer.from(payload.map((b, i) => b ^ m[i % 4])); }
      this.buf = this.buf.slice(off + len);
      if (op === 0x9) { this.frame(0xA, payload); continue; }    // ping -> pong
      if (op === 0x8) { this.sock.end(); continue; }             // close
      if (op === 0xA) continue;                                  // pong
      if (op === 0x1 || op === 0x2 || op === 0x0) {
        this.fragments.push(payload);
        if (!fin) continue;
        const text = Buffer.concat(this.fragments).toString('utf8');
        this.fragments = [];
        for (const line of text.split('\n')) if (line.trim()) this.onMessage(line);
      }
    }
  }
  frame(op, payload) {
    const mask = crypto.randomBytes(4);
    const len = payload.length;
    const head = len < 126 ? Buffer.from([0x80 | op, 0x80 | len])
      : len < 65536 ? Buffer.concat([Buffer.from([0x80 | op, 0x80 | 126]), (() => { const b = Buffer.alloc(2); b.writeUInt16BE(len); return b; })()])
      : Buffer.concat([Buffer.from([0x80 | op, 0x80 | 127]), (() => { const b = Buffer.alloc(8); b.writeBigUInt64BE(BigInt(len)); return b; })()]);
    const body = Buffer.from(payload.map((b, i) => b ^ mask[i % 4]));
    this.sock.write(Buffer.concat([head, mask, body]));
  }
  write(text) { this.frame(0x1, Buffer.from(text, 'utf8')); }
  end() { try { this.frame(0x8, Buffer.alloc(0)); this.sock.end(); } catch { /* already gone */ } }
  said() { return ''; }
}

// A short-lived app-server child on stdio. Kept for hosts without a daemon,
// chosen only by an explicit --transport stdio.
class StdioTransport {
  constructor(bin, onMessage, onClose, onError) {
    if (!fs.existsSync(bin)) refuse(EX_UNAVAILABLE, 'codex binary is missing: ' + bin);
    this.child = spawn(bin, ['app-server', '--listen', 'stdio://'], { stdio: ['pipe', 'pipe', 'pipe'] });
    this.child.on('error', (err) => onError(new Error('codex could not start: ' + err.message)));
    this.stderr = '';
    this.child.stderr.on('data', (d) => { this.stderr += d.toString(); });
    this.buf = '';
    this.child.stdout.on('data', (d) => {
      this.buf += d.toString();
      let nl;
      while ((nl = this.buf.indexOf('\n')) >= 0) {
        const line = this.buf.slice(0, nl).trim();
        this.buf = this.buf.slice(nl + 1);
        if (line) onMessage(line);
      }
    });
    this.child.on('close', () => onClose());
    this.opened = Promise.resolve();
  }
  write(text) { this.child.stdin.write(text + '\n'); }
  end() { try { this.child.stdin.end(); } catch { /* already gone */ } }
  said() { return this.stderr; }
}

// One JSON-RPC conversation over one transport.
class Client {
  constructor(transport, timeoutMs) {
    this.transportName = transport;
    this.id = 0;
    this.pending = new Map();
    this.listeners = [];
    this.closed = false;
    this.timeoutMs = timeoutMs;
    const onMessage = (line) => this.take(line);
    const onClose = () => {
      this.closed = true;
      for (const p of this.pending.values()) p.reject(new Error('app-server closed the connection'));
      this.pending.clear();
    };
    const onError = (err) => {
      this.closed = true;
      this.connectError = err;
      if (this.t && this.t.rejectOpen) this.t.rejectOpen(err);
      for (const p of this.pending.values()) p.reject(err);
      this.pending.clear();
    };
    this.t = transport === 'stdio'
      ? new StdioTransport(codexBin(), onMessage, onClose, onError)
      : new DaemonTransport(daemonSocket(), onMessage, onClose, onError);
  }
  take(line) {
    let msg;
    try { msg = JSON.parse(line); } catch { return; }
    if (msg.id !== undefined && this.pending.has(msg.id)) {
      const p = this.pending.get(msg.id);
      this.pending.delete(msg.id);
      if (msg.error) p.reject(new Error(msg.error.message || JSON.stringify(msg.error)));
      else p.resolve(msg.result);
      return;
    }
    // A REQUEST FROM THE SERVER, not a notification: it has both a method
    // and an id, and it is WAITING for an answer. Ignoring one hangs the turn
    // until the timeout - measured 2026-09-07: a turn that only wanted to run
    // an MCP tool sat silent for 460 seconds. There is no human at this pane,
    // so the policy is answered here, once, in the open: tool calls the
    // registry already granted are approved; anything else is declined.
    if (msg.method && msg.id !== undefined) { this.answerRequest(msg); return; }
    if (msg.method) for (const fn of this.listeners) fn(msg);
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
    this.t.write(JSON.stringify({ jsonrpc: '2.0', id: msg.id, result }));
  }
  notify(method, params) {
    const m = { jsonrpc: '2.0', method };
    if (params) m.params = params;
    this.t.write(JSON.stringify(m));
  }
  request(method, params) {
    const id = ++this.id;
    const m = { jsonrpc: '2.0', id, method };
    if (params) m.params = params;
    return new Promise((resolve, reject) => {
      if (this.closed) return reject(this.connectError || new Error('app-server is gone'));
      const timer = setTimeout(() => {
        this.pending.delete(id);
        reject(new Error(method + ' timed out'));
      }, this.timeoutMs);
      this.pending.set(id, {
        resolve: (v) => { clearTimeout(timer); resolve(v); },
        reject: (e) => { clearTimeout(timer); reject(e); },
      });
      this.t.write(JSON.stringify(m));
    });
  }
  async handshake() {
    await this.t.opened;
    // experimentalApi is what unlocks the granular approval form AND the
    // thread/queue methods. Without it the server answers
    // "askForApproval.granular requires experimentalApi capability" - and the
    // only other choice, `never`, REFUSES every MCP tool rather than allowing
    // it. Measured 2026-09-07 against 0.153.4.
    await this.request('initialize', {
      clientInfo: { name: 'steward', title: 'Steward session', version: '1' },
      capabilities: { experimentalApi: true },
    });
    this.notify('initialized');
  }
  end() { this.t.end(); }
  said() { return this.t.said(); }
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

function lastAgentText(items) {
  let text = null;
  for (const it of items || []) if (it && it.type === 'agentMessage' && it.text) text = it.text;
  return text;
}

async function cmdTurn(args) {
  const cwd = args.cwd;
  const file = args['message-file'];
  const threadFile = args['thread-file'];
  const clientId = args['client-id'];
  const transport = args.transport && args.transport !== true ? String(args.transport) : 'daemon';
  if (!cwd || cwd === true) refuse(EX_USAGE, 'turn needs --cwd');
  if (!file || file === true) refuse(EX_USAGE, 'turn needs --message-file');
  if (!clientId || clientId === true) refuse(EX_USAGE, 'turn needs --client-id (the letter\'s own id; it is what makes a letter idempotent)');
  if (transport !== 'daemon' && transport !== 'stdio') refuse(EX_USAGE, '--transport is daemon or stdio');
  if (!fs.existsSync(cwd)) refuse(EX_UNAVAILABLE, 'working directory is missing: ' + cwd);
  if (!fs.existsSync(file)) refuse(EX_UNAVAILABLE, 'message file is missing: ' + file);
  const text = fs.readFileSync(file, 'utf8');
  if (!text.trim()) refuse(EX_USAGE, 'the message file is empty');
  if (transport === 'stdio') {
    process.stderr.write('codex-thread: transport stdio was chosen explicitly - this takes the thread\'s write lock; ' +
      'never use it on a thread the owner\'s app may have open\n');
  } else if (!fs.existsSync(daemonSocket())) {
    // NO FALLBACK. The letter stays staged, the round reports degraded, and the
    // exit code says what to start. Falling back to a stdio child here would
    // recreate two writers the moment the app comes back.
    refuse(EX_UNAVAILABLE, 'the owner\'s Codex daemon is not running (no socket at ' + daemonSocket() + '). ' +
      'Start it in the owner\'s account: codex app-server daemon start. The letter stays staged until then.');
  }

  let threadId = null;
  if (args.thread && args.thread !== true) threadId = String(args.thread);
  else if (threadFile && threadFile !== true && fs.existsSync(threadFile)) {
    const stored = fs.readFileSync(threadFile, 'utf8').trim();
    if (stored) threadId = stored;
  }

  const timeoutMs = Number(args.timeout || 600) * 1000;
  const c = new Client(transport, timeoutMs);
  // The turn this letter belongs to, once known. Everything the daemon says
  // about OTHER turns - the human's, an earlier letter's - is not ours to
  // report: a shared daemon speaks about the whole thread.
  let myTurn = null;
  const messages = [];
  let failure = null;
  // A FATAL failure is one the environment caused - an expired login, a
  // refused account. It is not the same as a turn that ran and said nothing,
  // and the exit code says which: 78 for "fix your environment", 75 for
  // "try again".
  let fatal = false;
  let resolveFinished;
  const finished = new Promise((resolve) => { resolveFinished = resolve; });
  c.on((msg) => {
    const p = msg.params || {};
    if (msg.method === 'item/completed') {
      const item = p.item || {};
      // The letter's id comes back on its own userMessage, in the same notice
      // as the turn id. That is the correlation - not "the next turn that
      // starts", which on a shared thread may be the human's.
      if (item.type === 'userMessage' && item.clientId === clientId && p.turnId) myTurn = p.turnId;
      if (item.type === 'agentMessage' && item.text && myTurn && p.turnId === myTurn) messages.push(item.text);
    } else if (msg.method === 'turn/completed') {
      // A COMPLETED TURN IS NOT A SUCCESSFUL ONE. The notification carries a
      // status, and a failed turn arrives here with its reason in
      // turn.error.message. Treating the notification itself as success
      // reported "the turn completed without an answer" for a login that had
      // expired - the cause was in the message we threw away. Measured on
      // macOS 2026-09-07 by the product's integrator.
      const t = p.turn || {};
      if (!myTurn || t.id !== myTurn) return;
      if (t.status && t.status !== 'completed') {
        failure = (t.error && (t.error.message || t.error.code)) || ('turn status ' + t.status);
        fatal = true;
      }
      resolveFinished();
    } else if (msg.method === 'error' || msg.method === 'thread/error' || msg.method === 'turn/failed') {
      // AN ERROR NOTICE THAT WILL NOT BE RETRIED IS THE ANSWER. Ignoring it
      // and waiting for a turn that never comes turns an unauthorized
      // account into a silent model. On a shared daemon an error about
      // another turn is not ours; one without a turn id is about the account.
      if (p.turnId && myTurn && p.turnId !== myTurn) return;
      const info = p.codexErrorInfo || p.error || {};
      failure = (typeof info === 'string' ? info : (info.message || info.code || JSON.stringify(info))) ||
                JSON.stringify(p).slice(0, 300);
      if (p.codexErrorInfo) failure = String(p.codexErrorInfo) + (p.message ? ': ' + p.message : '');
      if (p.willRetry === false || msg.method !== 'error') { fatal = true; resolveFinished(); }
    }
  });
  const guard = new Promise((resolve) => setTimeout(() => {
    failure = failure || 'the turn did not finish within ' + (timeoutMs / 1000) + 's' +
      (myTurn ? '' : ' (the letter is queued behind another turn; the next round finds it by its id)');
    resolve();
  }, timeoutMs));

  let born = false;
  let recovered = null;
  try {
    await c.handshake();
    if (threadId) {
      // RESUME WITH THE ID ALONE on the daemon. The thread is the app's as much
      // as ours, and resume also accepts sandbox, approval and config - which
      // would silently re-arm the human's open thread with this letter's
      // settings. Those belong to the thread's birth, below. The stdio child
      // is alone with the thread and keeps the full form.
      const params = transport === 'daemon' ? { threadId } : Object.assign(threadParams(args, cwd), { threadId });
      await c.request('thread/resume', params);
      if (transport === 'daemon') {
        // IDEMPOTENCE IS A READING, NOT A FILE. Was this letter already turned
        // into a turn - by a client that died after queueing, or by the round
        // before this one? The thread says so, by the letter's own id.
        const read = await c.request('thread/read', { threadId, includeTurns: true });
        const turns = (read && read.thread && read.thread.turns) || [];
        const mine = turns.filter((t) => (t.items || []).some((it) => it && it.type === 'userMessage' && it.clientId === clientId));
        const done = mine.find((t) => t.status === 'completed' || t.status === 'failed' || t.status === 'interrupted');
        const running = done ? null : mine[0];
        if (done) {
          if (done.status !== 'completed') {
            recovered = { failure: (done.error && (done.error.message || done.error.code)) || ('turn status ' + done.status) };
          } else {
            const answer = lastAgentText(done.items);
            recovered = answer ? { answer } : { failure: 'the earlier turn for this letter completed without an answer' };
          }
          process.stderr.write('codex-thread: letter ' + clientId + ' already ran as turn ' + done.id + ' (' + done.status + '); nothing queued\n');
        } else if (running) {
          myTurn = running.id;
          process.stderr.write('codex-thread: letter ' + clientId + ' is already running as turn ' + running.id + '; waiting for it\n');
        } else {
          // Queued but not yet a turn? Then it is in the queue by our id, and
          // adding it again would answer the letter twice.
          let queued = false;
          try {
            const q = await c.request('thread/queue/list', { threadId });
            queued = ((q && q.data) || []).some((s) => s && s.clientUserMessageId === clientId);
          } catch (err) { process.stderr.write('codex-thread: thread/queue/list: ' + err.message + '\n'); }
          if (queued) process.stderr.write('codex-thread: letter ' + clientId + ' is already queued; waiting for its turn\n');
          else await c.request('thread/queue/add', { threadId, input: [{ type: 'text', text }], clientUserMessageId: clientId });
        }
      }
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
      if (transport === 'daemon') await c.request('thread/queue/add', { threadId, input: [{ type: 'text', text }], clientUserMessageId: clientId });
    }
    if (transport === 'stdio') {
      const t = await c.request('turn/start', { threadId, input: [{ type: 'text', text }], clientUserMessageId: clientId });
      if (t && t.turn && t.turn.id) myTurn = t.turn.id;
    }
    if (!recovered) await Promise.race([finished, guard]);
  } catch (err) {
    const said = c.said();
    const code = (err && (err.code === 'ECONNREFUSED' || err.code === 'ENOENT' || /ENOENT|ECONNREFUSED/.test(err.message || ''))) ? EX_UNAVAILABLE : EX_TEMPFAIL;
    refuse(code, (code === EX_UNAVAILABLE ? 'the owner\'s Codex daemon did not answer at ' + daemonSocket() + ': ' : '') +
      err.message + (said ? '\n  app-server said: ' + lastLines(said) : ''));
  } finally { c.end(); }

  if (recovered && recovered.failure) { failure = recovered.failure; fatal = true; }
  if (recovered && recovered.answer) messages.push(recovered.answer);
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

// Is the owner's daemon there? A liveness question a supervisor or doctor can
// ask without a letter: 0 and the socket path, or 69 and what to start.
function cmdDaemon() {
  const sock = daemonSocket();
  if (!fs.existsSync(sock)) refuse(EX_UNAVAILABLE, 'no daemon socket at ' + sock + ' - start it in the owner\'s account: codex app-server daemon start');
  process.stdout.write(sock + '\n');
}

async function main() {
  const argv = process.argv.slice(2);
  const verb = argv[0];
  const args = parseArgs(argv.slice(1));
  if (verb === 'turn') await cmdTurn(args);
  else if (verb === 'which') process.stdout.write(codexBinReal() + '\n');
  else if (verb === 'preflight') cmdPreflight(args);
  else if (verb === 'daemon') cmdDaemon();
  else refuse(EX_USAGE, 'usage: codex-thread.js turn|which|preflight|daemon ...');
  process.exit(0);
}

main().catch((err) => refuse(EX_SOFTWARE, err && err.message ? err.message : String(err)));
