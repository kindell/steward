#!/bin/bash
# test/codex-thread-daemon.test.sh - the thread client is a second CLIENT of
# the owner's Codex daemon, never a second writer, and a letter is idempotent
# by its own id.
#
# WHY. The Codex app holds a thread's write lock while the project is open. The
# only way to run a letter in that thread without forking it is through the
# same daemon: append to its queue, correlate by the letter's id, and read the
# thread back when this process cannot remember what it did. Measured live
# 2026-09-07; this suite pins the protocol so a change in either side shows up
# here first. The daemon is a fake on a unix socket speaking the same websocket
# JSON-RPC, written without a library for the same reason the client is.
#
# CLAIMS:
#   1. No daemon socket: exit 69, the refusal says what to start, and no
#      stdio child is spawned (STEWARD_CODEX_BIN points at a tripwire).
#   2. A fresh letter is queued with clientUserMessageId = --client-id, the
#      resume carries the thread id ALONE, and the answer is the agentMessage
#      of THAT turn - a message from another turn is not the answer.
#   3. A letter the thread already answered is never queued again; its answer
#      is printed from thread/read.
#   4. A letter already in the queue is not added twice; the client waits.
#   5. A turn that ends failed exits 78 with the daemon's reason.
#   6. --client-id is mandatory (64): without it nothing is idempotent.
set -u
here="$(CDPATH= cd -- "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CLIENT="$here/runtime/codex-thread.js"
pass=0; fail=0
ok()  { pass=$((pass+1)); printf '  ok   %s\n' "$1"; }
bad() { fail=$((fail+1)); printf '  FAIL %s\n     %s\n' "$1" "${2:-}"; }
is()  { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "wanted '$3', got '$2'"; fi; }
has() { case "$2" in *"$3"*) ok "$1" ;; *) bad "$1" "missing '$3' in: $2" ;; esac; }
hasnt(){ case "$2" in *"$3"*) bad "$1" "unexpectedly present '$3' in: $2" ;; *) ok "$1" ;; esac; }

command -v node >/dev/null 2>&1 || { echo "codex-thread-daemon: node is required"; exit 1; }
T="$(mktemp -d)"; trap 'rm -rf "$T"; [ -n "${DPID:-}" ] && kill "$DPID" 2>/dev/null' EXIT
# Short path: AF_UNIX paths are capped near 104 bytes and mktemp on macOS is long.
SOCK="$T/d.sock"
printf 'hello thread\n' > "$T/msg.txt"
printf 'thread-1\n' > "$T/thread"
cat > "$T/tripwire" <<'EOF'
#!/bin/sh
echo "TRIPWIRE: a stdio child was spawned" >&2; exit 99
EOF
chmod 755 "$T/tripwire"

# --- the fake daemon ----------------------------------------------------------
# Scenario comes from $SCENARIO: fresh | answered | queued | failed. It records
# every request it receives to $LOG, one JSON per line.
cat > "$T/daemon.js" <<'EOF'
const net=require('net'),crypto=require('crypto'),fs=require('fs');
const [,,sock,scenario,log]=process.argv;
const rec=(o)=>fs.appendFileSync(log,JSON.stringify(o)+'\n');
function frame(text){const p=Buffer.from(text,'utf8');let h;if(p.length<126)h=Buffer.from([0x81,p.length]);else{h=Buffer.alloc(4);h[0]=0x81;h[1]=126;h.writeUInt16BE(p.length,2);}return Buffer.concat([h,p]);}
net.createServer((c)=>{let buf=Buffer.alloc(0),up=false;
 const send=(o)=>c.write(frame(JSON.stringify(o)));
 const notify=(m,p)=>send({jsonrpc:'2.0',method:m,params:p});
 const turnFor=(cid,tid)=>{setTimeout(()=>{
   notify('turn/started',{turn:{id:tid}});
   notify('item/completed',{threadId:'thread-1',turnId:tid,item:{type:'userMessage',id:'u1',clientId:cid}});
   // noise from ANOTHER turn on the same thread: must not be taken as the answer
   notify('item/completed',{threadId:'thread-1',turnId:'other-turn',item:{type:'agentMessage',id:'x',text:'NOT YOURS'}});
   if(scenario==='failed'){notify('turn/completed',{threadId:'thread-1',turn:{id:tid,status:'failed',error:{message:'unauthorized: login expired'}}});return;}
   notify('item/completed',{threadId:'thread-1',turnId:tid,item:{type:'agentMessage',id:'a1',text:'the daemon answer'}});
   notify('turn/completed',{threadId:'thread-1',turn:{id:tid,status:'completed'}});},30);};
 c.on('data',(d)=>{buf=Buffer.concat([buf,d]);
  if(!up){const s=buf.toString('latin1'),e=s.indexOf('\r\n\r\n');if(e<0)return;const key=/Sec-WebSocket-Key: (.*)\r\n/.exec(s)[1];
    const acc=crypto.createHash('sha1').update(key+'258EAFA5-E914-47DA-95CA-C5AB0DC85B11').digest('base64');
    c.write('HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: '+acc+'\r\n\r\n');up=true;buf=buf.slice(e+4);}
  for(;;){if(buf.length<2)return;const b1=buf[1];let len=b1&0x7f,off=2;if(len===126){if(buf.length<4)return;len=buf.readUInt16BE(2);off=4;}else if(len===127){if(buf.length<10)return;len=Number(buf.readBigUInt64BE(2));off=10;}
   const masked=(b1&0x80)!==0;if(masked)off+=4;if(buf.length<off+len)return;let p=buf.slice(off,off+len);if(masked){const m=buf.slice(off-4,off);p=Buffer.from(p.map((b,i)=>b^m[i%4]));}
   const op=buf[0]&0x0f;buf=buf.slice(off+len);if(op===8){c.end();return;}if(op!==1)continue;
   let msg;try{msg=JSON.parse(p.toString('utf8'))}catch{continue}
   if(msg.method)rec({method:msg.method,params:msg.params||null});
   const reply=(r)=>send({jsonrpc:'2.0',id:msg.id,result:r});
   const m=msg.method,q=msg.params||{};
   if(m==='initialize')reply({userAgent:'fake'});
   else if(m==='thread/resume')reply({thread:{id:q.threadId,status:{type:'idle'}}});
   else if(m==='thread/read'){const turns=[{id:'turn-old',status:'completed',items:[{type:'userMessage',clientId:'letter-old'},{type:'agentMessage',text:'old answer'}]}];
     if(scenario==='answered')turns.push({id:'turn-done',status:'completed',items:[{type:'userMessage',clientId:'letter-1'},{type:'agentMessage',text:'the earlier answer'}]});
     reply({thread:{id:q.threadId,turns}});}
   else if(m==='thread/queue/list'){reply({data:scenario==='queued'?[{id:'q-1',clientUserMessageId:'letter-1'}]:[],nextCursor:null});if(scenario==='queued')turnFor('letter-1','turn-q');}
   else if(m==='thread/queue/add'){reply({queuedSubmission:{id:'q-new',clientUserMessageId:q.clientUserMessageId}});turnFor(q.clientUserMessageId,'turn-new');}
   else if(msg.id!==undefined)reply({});
  }});
}).listen(sock);
EOF

start_daemon() { # <scenario>
  rm -f "$SOCK" "$T/log"; : > "$T/log"
  node "$T/daemon.js" "$SOCK" "$1" "$T/log" & DPID=$!
  for i in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do [ -S "$SOCK" ] && break; sleep 0.1; done
}
stop_daemon() { kill "$DPID" 2>/dev/null; wait "$DPID" 2>/dev/null; DPID=""; }
run() { # extra args
  STEWARD_CODEX_DAEMON_SOCK="$SOCK" STEWARD_CODEX_BIN="$T/tripwire" \
    node "$CLIENT" turn --cwd "$T" --message-file "$T/msg.txt" --thread-file "$T/thread" --timeout 5 "$@" >"$T/out" 2>"$T/err"; echo "$?"
}
methods() { node -e 'const fs=require("fs");console.log(fs.readFileSync(process.argv[1],"utf8").trim().split("\n").filter(Boolean).map(l=>JSON.parse(l).method).join(" "))' "$T/log"; }
param() { node -e 'const fs=require("fs");const [f,m,k]=process.argv.slice(1);for(const l of fs.readFileSync(f,"utf8").trim().split("\n")){if(!l)continue;const o=JSON.parse(l);if(o.method===m){console.log(k==="*"?JSON.stringify(o.params):JSON.stringify(o.params[k]));process.exit(0)}}' "$T/log" "$1" "$2"; }

echo "codex-thread-daemon"

# 1. no daemon, no fallback
rm -f "$SOCK"
rc="$(run --client-id letter-1)"; err="$(cat "$T/err")"
is    "no socket exits 69" "$rc" "69"
has   "and says what to start" "$err" "codex app-server daemon start"
hasnt "and spawns no stdio child" "$err" "TRIPWIRE"

# 2. a fresh letter
start_daemon fresh
rc="$(run --client-id letter-1)"; err="$(cat "$T/err")"
is  "a fresh letter is answered" "$rc" "0"
is  "the answer is the agentMessage of the letter's own turn" "$(cat "$T/out")" "the daemon answer"
has "the letter was queued" "$(methods)" "thread/queue/add"
is  "with clientUserMessageId = the letter's id" "$(param thread/queue/add clientUserMessageId)" '"letter-1"'
is  "the resume carries the thread id alone" "$(param thread/resume '*')" '{"threadId":"thread-1"}'
has "and the thread was read first" "$(methods)" "thread/read"
hasnt "the client never starts a turn beside the queue" "$(methods)" "turn/start"
stop_daemon

# 3. already answered
start_daemon answered
rc="$(run --client-id letter-1)"; err="$(cat "$T/err")"
is    "an answered letter exits 0" "$rc" "0"
is    "and prints the earlier answer" "$(cat "$T/out")" "the earlier answer"
hasnt "and is not queued again" "$(methods)" "thread/queue/add"
has   "and the log says so" "$err" "already ran as turn turn-done"
stop_daemon

# 4. already queued
start_daemon queued
rc="$(run --client-id letter-1)"; err="$(cat "$T/err")"
is    "a queued letter is waited for" "$rc" "0"
is    "and its answer comes from its own turn" "$(cat "$T/out")" "the daemon answer"
hasnt "without a second queue/add" "$(methods)" "thread/queue/add"
stop_daemon

# 5. a failed turn
start_daemon failed
rc="$(run --client-id letter-1)"; err="$(cat "$T/err")"
is  "a failed turn exits 78" "$rc" "78"
has "with the daemon's reason" "$err" "login expired"
stop_daemon

# 6. the id is mandatory
start_daemon fresh
rc="$(run)"
is  "no --client-id is refused" "$rc" "64"
stop_daemon

printf '\n  %d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
