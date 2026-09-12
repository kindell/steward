#!/bin/bash
# test/supervisor-bridge.test.sh - claude rows are supervised through the adapter's answer;
# every destructive step is a KEYED two-round suspect; a spawn writes its claim before
# new-session; the close goes to the parsed $N after re-reading the tuple; and an OpenCode
# row never meets any of it (plan v6 Task 5; spec D1 D2 D5 D7 D12, E1-E4).
#
# THE OBSERVER IS A SHIM HERE. Its measuring is proven in test/bridge-observe.test.sh; this
# suite proves what the supervisor DOES with each answer, so the shim prints the line the
# claim needs and logs that it was asked. bridge-kill is a recorder for the same reason.
# tmux, pgrep and ps are shims over files; /proc is BRIDGE_PROC_ROOT; the nonce comes from
# STEWARD_NONCE_CMD. Nothing here touches the machine.
set -u
here="$(CDPATH= cd -- "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SUP="${SUP_OVERRIDE:-$here/linux/session-supervisor-linux.sh}"   # SUP_OVERRIDE: a mutated copy, for the mutation runs
pass=0; fail=0
ok()  { pass=$((pass+1)); printf '  ok   %s\n' "$1"; }
bad() { fail=$((fail+1)); printf '  FAIL %s\n     %s\n' "$1" "${2:-}"; }
is()  { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "wanted '$3', got '$2'"; fi; }
has() { case "$2" in *"$3"*) ok "$1" ;; *) bad "$1" "missing '$3' in: $2" ;; esac; }
hasnt(){ case "$2" in *"$3"*) bad "$1" "unexpectedly present '$3' in: $2" ;; *) ok "$1" ;; esac; }
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
US="$(printf '\037')"
HOMEDIR="$T/home"; ROOT="$T/estate"; LIBS="$T/libs"; BIN="$T/bin"; PROC="$T/proc"
mkdir -p "$HOMEDIR/.local/bin" "$HOMEDIR/Projects/repo" "$HOMEDIR/scripts/runtime" "$HOMEDIR/.claude/sessions" "$LIBS" "$BIN" "$PROC/sys/kernel/random" "$PROC/4242" \
         "$ROOT/estate" "$ROOT/sessions.d" "$ROOT/entities.d" "$ROOT/accounts.d" "$ROOT/projects.d" "$ROOT/mcp.d" "$T/memory"
cat > "$ROOT/estate/steward.conf" <<'EOF'
ESTATE_NAME="fixture"
LABEL_PREFIX="com.fixture.claude"
JOB_LABEL_PREFIX="com.fixture.job"
SERVICE_LABEL_PREFIX="com.fixture.svc"
RC_LABEL_PREFIX="Fixture: "
HUB_SESSION="hub"
HUB_HOST="h1"
STATE_DIR_NAME="fixture-supervisor"
PAUSED_DIR_NAME="fixture-paused"
TMUX_SOCKET="fixture.sock"
OP_TOKEN_FILE_NAME="fixture-token"
PING_MSG="you have unread mail"
EOF
ME="$(id -un)"
printf 'NAME="Alpha"\nMEMBERS="a"\n' > "$ROOT/entities.d/alpha.conf"
printf 'PRINCIPAL="a"\nHOST="h1"\nUSERNAME="%s"\n' "$ME" > "$ROOT/accounts.d/a-h1.conf"
cp "$here/lib/registry.sh" "$here/lib/bridge.sh" "$here/lib/mcprender.sh" "$here/lib/mcpspawn.sh" "$LIBS/"
printf '#!/bin/sh\nexit 0\n' > "$HOMEDIR/.local/bin/claude"; chmod 755 "$HOMEDIR/.local/bin/claude"
ADAPTER="$HOMEDIR/scripts/runtime/opencode-session.sh"; printf '#!/bin/sh\nexit 0\n' > "$ADAPTER"; chmod 755 "$ADAPTER"
NAME="s-0000000000000001"; OC="s-0000000000000002"; PORT=4097
cat > "$ROOT/sessions.d/$NAME.conf" <<EOF
OWNER="a"
HOST="h1"
DOMAIN="alpha"
REPO_PATH="$HOMEDIR/Projects/repo"
ID="$NAME"
ACCOUNT="a-h1"
RC_LABEL="Alpha→Thing"
CLAUDE_MEMORY_ROOT="$T/memory"
EOF
cat > "$ROOT/sessions.d/$OC.conf" <<EOF
OWNER="a"
HOST="h1"
DOMAIN="alpha"
REPO_PATH="$HOMEDIR/Projects/repo"
ID="$OC"
ACCOUNT="a-h1"
RC_LABEL=""
KIND="advisor"
RUNTIME="opencode"
MODEL="openai/example-model"
OPENCODE_VERSION="1.18.14"
OPENCODE_PORT="$PORT"
AUTO_APPROVE="true"
CLAUDE_MEMORY_ROOT="$T/memory"
EOF
# ---- /proc fixture: boot id, uptime, and the pane shell 4242 (birth boot-s:100) -------------------
printf 'boot-s\n' > "$PROC/sys/kernel/random/boot_id"; printf '500.00 400.00\n' > "$PROC/uptime"
pstat() { # <pid> <comm> <ppid> <pgrp> <tty_nr> <tpgid> <starttime>
  mkdir -p "$PROC/$1"; printf '%s (%s) S %s %s %s %s %s 0 0 0 0 0 0 0 0 0 20 0 1 0 %s 0 0 0\n' "$1" "$2" "$3" "$4" "$4" "$5" "$6" "$7" > "$PROC/$1/stat"   # starttime is field 22
}
pstat 4242 bash 1 4242 34816 4243 100      # the pane shell: its tty's foreground group is claude's
pstat 4243 claude 4242 4243 34816 4243 111 # the managed claude, birth boot-s:111
# ---- shims -----------------------------------------------------------------------------------------
PROCTAB="$T/proctab"; TUPLE="$T/tuple"; OBSLINE="$T/obs-line"
export PROCTAB TUPLE OBSLINE T_HAS_SESSION="$T/has-session" T_KILL_FAILS="$T/kill-fails" T_NEW_FAILS="$T/new-fails" T_GEN_AT_SPAWN="$T/gen-at-spawn"
export TMUX_LOG="$T/tmux.log" PGREP_LOG="$T/pgrep.log" OBS_LOG="$T/obs.log" BKILL_LOG="$T/bkill.log" STATE="$HOMEDIR/.local/state/fixture-supervisor"
export OBS_SELF="$NAME" OBS_DIR="$T/obs-other"; mkdir -p "$T/obs-other"
export T_FG_CMD="$T/fg-cmd" T_SENDKEYS="$T/sendkeys" T_RECEIPT="$T/receipt" T_RENAME_EFFECT="$T/rename-effect" T_BUSY="$T/busy" OBSQUEUE="$T/obs-queue" T_KILL_LOCKS_STATE="$T/kill-locks-state" T_SENDKEYS_FAIL="$T/sendkeys-fail" T_ENTER_FAIL="$T/enter-fail" OBS_SIDE_EFFECT="$T/obs-side-effect"
cat > "$BIN/tmux" <<'EOF'
#!/bin/bash
printf '%s\n' "$*" >> "$TMUX_LOG"
argv=("$@"); [ "${argv[0]:-}" = "-S" ] && argv=("${argv[@]:2}")
last="${argv[${#argv[@]}-1]}"
case "${argv[0]:-}" in
  has-session)  [ -f "$T_HAS_SESSION" ] ;;
  list-panes)   [ -f "$T_HAS_SESSION" ] && echo 4242; exit 0 ;;
  list-clients) exit 0 ;;
  # tmux 3.4, MEASURED on the live host: session formats expand through list-sessions, never through
  # display-message -t "=name" - which answers nothing at all there. Pane targets do work.
  list-sessions) [ -f "$T_HAS_SESSION" ] && cat "$TUPLE"; exit 0 ;;
  display-message) case "$last" in *session_id*) : ;; *pane_current_command*) cat "$T_FG_CMD" 2>/dev/null || echo claude ;; *pane_pid*) echo 4242 ;; esac; exit 0 ;;
  send-keys) tgt=""; prev=""; txt=""; for a in "${argv[@]}"; do [ "$prev" = "-t" ] && tgt="$a"; [ "$prev" = "-l" ] && txt="$a"; prev="$a"; done
             [ -f "$T_SENDKEYS_FAIL" ] && exit 1
             [ -f "$T_ENTER_FAIL" ] && [ "$last" = Enter ] && exit 1
             printf '%s\n' "$tgt" >> "$T_SENDKEYS"
             # THE RENAME'S EFFECT (measured P1): within a second the bridge file reports the new name with nameSince
             # advanced, and the pane shows the receipt. T_RENAME_EFFECT selects how faithful the fixture is:
             #   full    -> bridge name = desired, nameSince + 1, receipt in the pane
             #   receipt -> the pane shows the receipt and nameSince advances, but the bridge still says the OLD name
             #   noadvance -> bridge name = desired but nameSince unchanged
             case "$txt" in "/rename "*) d="${txt#/rename }"; printf '%s\n' "$d" > "$T_RECEIPT"
                case "$(cat "$T_RENAME_EFFECT" 2>/dev/null)" in
                  full) awk -v US="$(printf '\037')" -v d="$d" 'BEGIN{FS=OFS=US} {$6=d; $7=$7+1; print}' "$OBSLINE" > "$OBSLINE.n" && mv "$OBSLINE.n" "$OBSLINE" ;;
                  receipt) awk -v US="$(printf '\037')" 'BEGIN{FS=OFS=US} {$7=$7+1; print}' "$OBSLINE" > "$OBSLINE.n" && mv "$OBSLINE.n" "$OBSLINE" ;;
                  noadvance) awk -v US="$(printf '\037')" -v d="$d" 'BEGIN{FS=OFS=US} {$6=d; print}' "$OBSLINE" > "$OBSLINE.n" && mv "$OBSLINE.n" "$OBSLINE" ;;
                esac ;; esac; exit 0 ;;
  kill-session) [ -f "$T_KILL_FAILS" ] && exit 1; rm -f "$T_HAS_SESSION"; [ -f "$T_KILL_LOCKS_STATE" ] && chmod 500 "$STATE"; exit 0 ;;
  new-session)  cp "$STATE"/s-0000000000000001.generation "$T_GEN_AT_SPAWN" 2>/dev/null
                [ -f "$T_NEW_FAILS" ] && exit 1
                for a in "${argv[@]}"; do [ "$a" = "-P" ] && echo 4242; done; touch "$T_HAS_SESSION"; exit 0 ;;
  capture-pane) [ -f "$T_BUSY" ] && echo "esc to interrupt"; [ -s "$T_RECEIPT" ] && printf 'Session renamed to: %s\n' "$(cat "$T_RECEIPT")"; exit 0 ;;
  *) exit 0 ;;
esac
EOF
cat > "$BIN/pgrep" <<'EOF'
#!/bin/bash
pat=""; prev=""; for a in "$@"; do [ "$prev" = "-f" ] && pat="$a"; prev="$a"; done
printf '%s\n' "$pat" >> "$PGREP_LOG"; [ -n "$pat" ] || exit 1
found=0; while read -r pid ppid argv; do case "$pid" in ""|\#*) continue;; esac
  printf '%s' "$argv" | grep -Eq -- "$pat" && { printf '%s\n' "$pid"; found=1; }; done < "$PROCTAB"; [ "$found" = 1 ]
EOF
cat > "$BIN/ps" <<'EOF'
#!/bin/bash
pid=""; prev=""; for a in "$@"; do [ "$prev" = "-p" ] && pid="$a"; prev="$a"; done; [ -n "$pid" ] || exit 1
while read -r p pp rest; do case "$p" in ""|\#*) continue;; esac; [ "$p" = "$pid" ] && { printf ' %s\n' "$pp"; exit 0; }; done < "$PROCTAB"; exit 1
EOF
cat > "$BIN/observe" <<'EOF'
#!/bin/bash
# A QUEUE OF LINES (one per call) stands in for the world changing between two observations in one
# round; when it is empty the static line answers.
printf '%s\n' "$*" >> "$OBS_LOG"
id="$1"; [ "$id" = --bootstrap ] && id="$2"
if [ "$id" != "$OBS_SELF" ]; then
  if [ -f "$OBS_DIR/$id" ]; then cat "$OBS_DIR/$id"; else printf '%s\037unknown\037\037\037\037\037\037none\037\037\037\037\037\037\037\n' "$id"; fi
  [ -f "$OBS_SIDE_EFFECT" ] && bash "$OBS_SIDE_EFFECT" "$id"; exit 0
fi
if [ -s "$OBSQUEUE" ]; then head -1 "$OBSQUEUE"; sed -i 1d "$OBSQUEUE"; else cat "$OBSLINE"; fi
[ -f "$OBS_SIDE_EFFECT" ] && bash "$OBS_SIDE_EFFECT" "$id"; exit 0
EOF
cat > "$BIN/bkill" <<'EOF'
#!/bin/bash
printf '%s\n' "$*" >> "$BKILL_LOG"; echo "killed $1 $2 ${3:-TERM}"
EOF
cat > "$BIN/nonce" <<'EOF'
#!/bin/bash
cat "$NONCE_FILE"
EOF
chmod 755 "$BIN"/*
export NONCE_FILE="$T/nonce"; printf '0123456789abcdef0123456789abcdef\n' > "$NONCE_FILE"
GEN="$STATE/$NAME.generation"; SUSPECT="$STATE/$NAME.suspect"
gen() { bash -c ". '$LIBS/bridge.sh'; bridge_gen_write '$STATE' '$NAME' $*"; }
gget() { sed -n "s/^$1=//p" "$GEN" 2>/dev/null | head -1; }
line() { # <answer> <pid> <birth> <pane> <name> <since> <gen> <classes> <child> <ps> <sid> <mtime> <tuple> <inode>
  printf '%s' "$NAME" > "$OBSLINE"; for a in "$@"; do printf '%s%s' "$US" "$a" >> "$OBSLINE"; done; printf '\n' >> "$OBSLINE"
}
qline() { local keep; keep="$(cat "$OBSLINE")"; line "$@"; cat "$OBSLINE" >> "$OBSQUEUE"; printf '%s\n' "$keep" > "$OBSLINE"; }
MANAGED() { line identified:managed 4243 boot-s:111 "$NAME:@0.%0" "Alpha→Thing" 1789000000000 alive live:managed "" 4243 thread-4243 1789000000000 '$7:1789000000' 777; }
run() { # [id]
  : > "$TMUX_LOG"; : > "$PGREP_LOG"; : > "$OBS_LOG"; : > "$BKILL_LOG"
  HOME="$HOMEDIR" STEWARD_ESTATE_ROOT="$ROOT" STEWARD_CONFIG_FILE="$T/no-such-config" STEWARD_REGISTRY_LIB="$LIBS/registry.sh" STEWARD_BRIDGE_LIB="$LIBS/bridge.sh" \
  STEWARD_TMUX_SOCKET="$T/fixture.sock" STEWARD_BRIDGE_OBSERVE="$BIN/observe" STEWARD_BRIDGE_KILL="$BIN/bkill" STEWARD_NONCE_CMD="$BIN/nonce" \
  BRIDGE_PROC_ROOT="$PROC" STEWARD_KEY_SETTLE_SEC=0 STEWARD_SELF_HOST=h1 PATH="$BIN:$PATH" bash "$SUP" "${1:-$NAME}" >"$T/out" 2>&1; RC=$?; OUT="$(cat "$T/out")"   # a caller's VAR=x run reaches the supervisor: bash exports a function call's prefix assignments
}
reset() { chmod 700 "$STATE" 2>/dev/null; rm -rf "$STATE" "$T/obs-other"; mkdir -p "$STATE" "$T/obs-other"; : > "$OBSQUEUE"; rm -f "$T_KILL_LOCKS_STATE" "$T_SENDKEYS_FAIL" "$T_ENTER_FAIL" "$OBS_SIDE_EFFECT"; rm -f "$T_HAS_SESSION" "$T_KILL_FAILS" "$T_NEW_FAILS" "$T_GEN_AT_SPAWN" "$T_FG_CMD" "$T_RECEIPT" "$T_BUSY" "$T_RENAME_EFFECT"; : > "$T_SENDKEYS"
  printf '4242 1 -bash\n' > "$PROCTAB"; printf '$7:1789000000\n' > "$TUPLE"; gen census=1; pstat 4242 bash 1 4242 34816 4243 100; pstat 4243 claude 4242 4243 34816 4243 111; row_claude; }
row_claude() { # [extra KEY="v" lines...] - the claude row, RC_LABEL="Alpha→Thing" unless overridden
  { printf 'OWNER="a"\nHOST="h1"\nDOMAIN="alpha"\nREPO_PATH="%s/Projects/repo"\nID="%s"\nACCOUNT="a-h1"\nCLAUDE_MEMORY_ROOT="%s/memory"\n' "$HOMEDIR" "$NAME" "$T"
    if [ $# -eq 0 ]; then printf 'RC_LABEL="Alpha→Thing"\n'; else printf '%s\n' "$@"; fi; } > "$ROOT/sessions.d/$NAME.conf"
}
sk() { grep -c "^$1\$" "$T_SENDKEYS"; }   # send-keys calls to exactly this target
tl() { grep -c "$1" "$TMUX_LOG"; }
gen_snapshot() { sort "$GEN" 2>/dev/null; }

echo "== 1. managed: healthy, no label pgrep, no kill, the generation binds the process =="
reset; touch "$T_HAS_SESSION"; MANAGED; run
is "1a rc 0" "$RC" "0"; is "1b observer asked once" "$(grep -c . "$OBS_LOG")" "1"; is "1c asked about THIS row" "$(head -1 "$OBS_LOG")" "$NAME"
is "1d no label pgrep" "$(grep -c 'remote-control' "$PGREP_LOG")" "0"; is "1e no kill-session" "$(tl kill-session)" "0"; is "1f no new-session" "$(tl new-session)" "0"
is "1g pid bound" "$(gget pid)" "4243"; is "1h birth bound" "$(gget birth)" "boot-s:111"; is "1i procStart" "$(gget procStart)" "4243"; is "1j sessionId" "$(gget sessionId)" "thread-4243"
is "1k bridge_mtime" "$(gget bridge_mtime)" "1789000000000"; is "1l bridge_inode" "$(gget bridge_inode)" "777"; is "1m bridge_name" "$(gget bridge_name)" "Alpha→Thing"
gen applied="Alpha→Thing"; run; before="$(gen_snapshot)"; run; is "1n a second managed round rewrites nothing" "$(gen_snapshot)" "$before"

echo "== 2. an OpenCode row never meets the adapter: today's block decides (D1/E2) =="
reset; rm -f "$T_HAS_SESSION"; run "$OC"
is "2a observer never called" "$(grep -c . "$OBS_LOG")" "0"; is "2b spawned through the adapter when tmux is absent" "$(tl "new-session.*$ADAPTER")" "1"
hasnt "2c no nonce on an OpenCode launch" "$(cat "$TMUX_LOG")" "STEWARD_LAUNCH_NONCE"
[ -f "$STATE/$OC.generation" ] && bad "2d no generation written for OpenCode" "$(cat "$STATE/$OC.generation")" || ok "2d no generation written for OpenCode"
touch "$T_HAS_SESSION"; printf '4242 1 -bash\n4243 4242 /x/claude --remote-control "Other"\n' > "$PROCTAB"; run "$OC"
is "2e a foreign runtime in the pane vetoes (WARNING, nothing done)" "$(tl kill-session)$(tl new-session)" "00"; has "2f the old warning text" "$OUT" "does not match this session's pattern"
printf '4242 1 -bash\n' > "$PROCTAB"; run "$OC"; is "2g round one: suspect only" "$(tl kill-session)" "0"; [ -f "$STATE/$OC.suspect" ] && ok "2h suspect marker set" || bad "2h suspect marker set" ""
run "$OC"; is "2i round two: the old kill by name" "$(tl 'kill-session -t =s-0000000000000002')" "1"; is "2j and the adapter respawn" "$(tl "new-session.*$ADAPTER")" "1"

echo "== 3. wait-veto: nothing, every round =="
reset; touch "$T_HAS_SESSION"; gen pid=4243 birth=boot-s:111; line wait-veto "" "" "" "" "" gone-noreceipt "" "" "" "" "" '$7:1789000000' ""; before="$(gen_snapshot)"
run; run; is "3a nothing killed, nothing spawned" "$(tl kill-session)$(tl new-session)" "00"; is "3b generation untouched" "$(gen_snapshot)" "$before"; [ -f "$SUSPECT" ] && bad "3c no suspect" "" || ok "3c no suspect"

echo "== 4. no-process with tmux present: keyed close, then the EXISTING debris gate, once (D2) =="
reset; touch "$T_HAS_SESSION"; gen pid=4243 birth=boot-s:111; line no-process "" "" "" "" "" gone-noreceipt "" "" "" "" "" '$7:1789000000' ""
run; is "4a round one: nothing" "$(tl kill-session)$(tl new-session)" "00"; is "4b the key names the tuple" "$(cat "$SUSPECT" 2>/dev/null)" 'close $7:1789000000'
run; is "4c round two: the zombie repair ran once" "$(tl kill-session)" "1"; is "4d respawn once" "$(tl new-session)" "1"
[ -f "$SUSPECT" ] && bad "4e SUSPECT absent afterwards" "" || ok "4e SUSPECT absent afterwards"
hasnt "4f the OLD two-round block did not run (its text is absent)" "$OUT" "ZOMBIE PANE"
is "4g the close went to the parsed \$N, not the name (E4)" "$(tl 'kill-session -t \$7')" "1"

echo "== 4b. a LIVE round between two no-process rounds resets the count (measured on the deployed supervisor 2026-09-12) =="
# The hub's P1b case B: a silent no-process round at 05:57:56 left its mark; the session lived until
# 06:14:36; the next no-process round at 06:14:43 acted at once as "the second in a row". Same tuple (the
# tmux session survived the process), so the key would match. A managed round in between must reset it -
# and it does, at the live path's "the resume took" line; this section pins that (a mutation that only
# touched the case block survived, because the reset lives there and not in the case).
reset; touch "$T_HAS_SESSION"; gen pid=4243 birth=boot-s:111; line no-process "" "" "" "" "" gone-noreceipt "" "" "" "" "" '$7:1789000000' ""
run; is "4b1 round one: suspect keyed" "$(cat "$SUSPECT" 2>/dev/null)" 'close $7:1789000000'
line identified:managed 4243 boot-s:111 "$NAME:@0.%0" "Alpha→Thing" 1 alive live:managed "" 4243 thread-4243 1 '$7:1789000000' 777; run
[ -f "$SUSPECT" ] && bad "4b2 a managed round clears the suspect" "$(cat "$SUSPECT")" || ok "4b2 a managed round clears the suspect"
line no-process "" "" "" "" "" gone-noreceipt "" "" "" "" "" '$7:1789000000' ""; run
is "4b3 the next no-process round is round ONE again: nothing closed" "$(tl kill-session)$(tl new-session)" "00"
run; is "4b4 and the one after it closes" "$(tl kill-session)" "1"

echo "== 5. moved: nothing =="
reset; touch "$T_HAS_SESSION"; line identified:moved 4243 boot-s:111 "$NAME:@0.%0" "X" 1 alive live:moved "" 4243 t 1 '$7:1' 1; before="$(gen_snapshot)"; run
is "5a nothing" "$(tl kill-session)$(tl new-session)" "00"; is "5b no bkill" "$(grep -c . "$BKILL_LOG")" "0"; is "5c generation untouched" "$(gen_snapshot)" "$before"; has "5d says MOVED" "$OUT" "MOVED"

echo "== 6. orphan: keyed reap on the pin =="
ORPHAN() { line identified:orphan 4243 boot-s:111 "$NAME:@0.%0" "X" 1 alive live:orphan "" 4243 t 1 "" 1; }
reset; ORPHAN; run; is "6a round one: no kill" "$(grep -c . "$BKILL_LOG")" "0"; is "6b key = reap pid birth" "$(cat "$SUSPECT")" "reap 4243 boot-s:111"
run; is "6c round two: bridge-kill got pid birth TERM" "$(cat "$BKILL_LOG")" "4243 boot-s:111 TERM"; [ -f "$SUSPECT" ] && bad "6d suspect cleared" "" || ok "6d suspect cleared"
reset; ORPHAN; run; line identified:moved 4243 boot-s:111 "$NAME:@0.%0" "X" 1 alive live:moved "" 4243 t 1 '$7:1' 1; run; ORPHAN; run
is "6e orphan, moved, orphan: no kill" "$(grep -c . "$BKILL_LOG")" "0"
reset; ORPHAN; run; line no-process "" "" "" "" "" gone-noreceipt stale "" "" "" "" "" ""; run; is "6f pid gone between rounds: no kill" "$(grep -c . "$BKILL_LOG")" "0"

echo "== 7. stale, tmux absent: key 'spawn absent', one spawn on round two =="
reset; line no-process "" "" "" "" "" gone-noreceipt stale "" "" "" "" "" ""; run
is "7a round one: no spawn" "$(tl new-session)" "0"; is "7b key" "$(cat "$SUSPECT")" "spawn absent"
run; is "7c round two: one spawn" "$(tl new-session)" "1"; is "7d no kill" "$(tl kill-session)" "0"

echo "== 8. a human creates the session between the rounds: the key differs, nothing happens (D5) =="
reset; line no-process "" "" "" "" "" gone-noreceipt "" "" "" "" "" "" ""; run; is "8a key spawn absent" "$(cat "$SUSPECT")" "spawn absent"
touch "$T_HAS_SESSION"; line no-process "" "" "" "" "" gone-noreceipt "" "" "" "" "" '$9:1789000500' ""; run
is "8b no spawn, no kill" "$(tl kill-session)$(tl new-session)" "00"; is "8c the key is now the close key" "$(cat "$SUSPECT")" 'close $9:1789000500'
# THE RACE INSIDE ONE ROUND: the observer measured "absent", the key confirmed, and a session appears
# before new-session. The shim's line is static, so this IS that race: has-session says yes at spawn time.
reset; line no-process "" "" "" "" "" gone-noreceipt "" "" "" "" "" "" ""; run; touch "$T_HAS_SESSION"; run
is "8d a session that appeared between the observer and the spawn blocks the spawn" "$(tl new-session)" "0"; has "8e and says so" "$OUT" "appeared after"

echo "== 9. the tuple is re-read at the kill site (D5, E3, E4) =="
reset; touch "$T_HAS_SESSION"; gen pid=4243 birth=boot-s:111; line no-process "" "" "" "" "" gone-noreceipt "" "" "" "" "" '$7:1789000000' ""; run
printf '$7:1789000900\n' > "$TUPLE"; run; is "9a tuple changed before close: nothing killed" "$(tl kill-session)" "0"; is "9b nothing spawned" "$(tl new-session)" "0"; has "9c says why" "$OUT" "tuple changed"
[ -f "$SUSPECT" ] && bad "9d suspect reset" "$(cat "$SUSPECT")" || ok "9d suspect reset"
is "9e no stop_intent written" "$(gget stop_intent)" ""
reset; touch "$T_HAS_SESSION"; gen pid=4243 birth=boot-s:111; line no-process "" "" "" "" "" gone-noreceipt "" "" "" "" "" '$7:1789000000' ""; run; touch "$T_KILL_FAILS"; run
is "9f kill-session failed: no receipt" "$(gget stop_receipt)" ""; case "$(gget stop_intent)" in zombie-*) ok "9g intent written before the attempt";; *) bad "9g intent written before the attempt" "$(gget stop_intent)";; esac
is "9h no spawn after a failed close" "$(tl new-session)" "0"; has "9i says so" "$OUT" "did not verifiably succeed"

echo "== 10-12. unknown answers: nothing, and a degraded marker when our process lives unattested =="
reset; touch "$T_HAS_SESSION"; line unknown "" "" "" "" "" alive "live:managed live:managed" "" "" "" "" '$7:1' ""; before="$(gen_snapshot)"; run
is "10a split-brain: nothing" "$(tl kill-session)$(tl new-session)$(grep -c . "$BKILL_LOG")" "000"; is "10b generation untouched" "$(gen_snapshot)" "$before"
[ -f "$STATE/$NAME.identity-degraded" ] && ok "10c degraded marker (gen alive, unattested)" || bad "10c degraded marker (gen alive, unattested)" ""
reset; touch "$T_HAS_SESSION"; line unknown "" "" "" "" "" alive "unclassifiable live:managed" "" "" "" "" '$7:1' ""; run; is "11 poison + live: nothing" "$(tl kill-session)$(tl new-session)" "00"
reset; rm -f "$GEN"; line unknown "" "" "" "" "" none "" "" "" "" "" "" ""; run; run; is "12 pre-census: no spawn, twice" "$(tl new-session)" "0"
[ -f "$STATE/$NAME.identity-degraded" ] && bad "12b no degraded marker when gen is none" "" || ok "12b no degraded marker when gen is none"

echo "== 13. post-census first-ever: two rounds, one spawn =="
reset; line no-process "" "" "" "" "" none "" "" "" "" "" "" ""; run; run; is "13 one spawn" "$(tl new-session)" "1"

echo "== 14. grace: nothing, and the observer is read-only so asking it again changes nothing =="
reset; touch "$T_HAS_SESSION"; gen launch_ms=1 launch_uptime_ms=1; line grace "" "" "" "" "" grace "" "" "" "" "" '$7:1' ""; before="$(gen_snapshot)"; run; run
is "14a nothing" "$(tl kill-session)$(tl new-session)" "00"; is "14b generation untouched over two rounds" "$(gen_snapshot)" "$before"

echo "== 15. the spawn writes its claim BEFORE new-session and closes it AFTER (D7) =="
reset; printf '{"pid":9,"tmux":"x"}\n' > "$HOMEDIR/.claude/sessions/9.json"; ino9="$(stat -c %i "$HOMEDIR/.claude/sessions/9.json")"
line no-process "" "" "" "" "" gone-noreceipt "" "" "" "" "" "" ""; run; run
is "15a one new-session" "$(tl new-session)" "1"
g="$(cat "$T_GEN_AT_SPAWN" 2>/dev/null)"
has "15b launch_ms set before new-session" "$g" "launch_ms="; has "15c launch_uptime_ms=500000" "$g" "launch_uptime_ms=500000"; has "15d launch_boot_id=boot-s" "$g" "launch_boot_id=boot-s"
has "15e launch_nonce" "$g" "launch_nonce=0123456789abcdef0123456789abcdef"; has "15f launch_inodes holds the pre-existing file's inode" "$g" "launch_inodes=$ino9"; has "15g spawn_state=pending at that moment" "$g" "spawn_state=pending"
has "15h pid cleared" "$g" "pid="; has "15i stop_receipt cleared" "$(printf '%s\n' "$g" | grep '^stop_receipt=')" "stop_receipt="
is "15j after: launch_pane_pid" "$(gget launch_pane_pid)" "4242"; is "15k after: launch_pane_birth" "$(gget launch_pane_birth)" "boot-s:100"; is "15l after: spawn_state=started" "$(gget spawn_state)" "started"
rm -f "$HOMEDIR/.claude/sessions/9.json"
reset; touch "$T_NEW_FAILS"; line no-process "" "" "" "" "" gone-noreceipt "" "" "" "" "" "" ""; run; run
case "$(gget spawn_state)" in failed:*) ok "15m new-session failed: spawn_state=failed:<epoch>";; *) bad "15m new-session failed: spawn_state=failed:<epoch>" "$(gget spawn_state)";; esac
is "15n claim closed (nonce cleared)" "$(gget launch_nonce)" ""; is "15o launch_ms cleared" "$(gget launch_ms)" ""

echo "== 16. spawn validation: a bad nonce or an unreadable uptime is a failed spawn, never a launch =="
reset; printf '0123456789abcdef0123456789abcde\n' > "$NONCE_FILE"; line no-process "" "" "" "" "" gone-noreceipt "" "" "" "" "" "" ""; run; run
is "16a 31 hex chars: no new-session" "$(tl new-session)" "0"; case "$(gget spawn_state)" in failed:*) ok "16b spawn_state=failed";; *) bad "16b spawn_state=failed" "$(gget spawn_state)";; esac; has "16c says nonce" "$OUT" "nonce"
printf '0123456789abcdef0123456789abcdef\n' > "$NONCE_FILE"
reset; mv "$PROC/uptime" "$PROC/uptime.away"; line no-process "" "" "" "" "" gone-noreceipt "" "" "" "" "" "" ""; run; run
is "16d unreadable uptime: no new-session" "$(tl new-session)" "0"; case "$(gget spawn_state)" in failed:*) ok "16e spawn_state=failed";; *) bad "16e spawn_state=failed" "$(gget spawn_state)";; esac
mv "$PROC/uptime.away" "$PROC/uptime"

echo "== 17. the nonce rides in front of claude, never behind the ';' =="
reset; line no-process "" "" "" "" "" gone-noreceipt "" "" "" "" "" "" ""; run; run
ns="$(grep 'new-session' "$TMUX_LOG" | head -1)"; cmd="${ns##*fixture.sock }"
case "$ns" in *"STEWARD_LAUNCH_NONCE=0123456789abcdef0123456789abcdef "*"claude"*) ok "17a nonce before claude";; *) bad "17a nonce before claude" "$ns";; esac
case "${ns##*;}" in *STEWARD_LAUNCH_NONCE*) bad "17b not after the ';'" "$ns";; *) ok "17b not after the ';'";; esac
has "17c -P -F pane_pid asked" "$ns" "-P -F #{pane_pid}"

echo "== 18. zombie path receipts (D12) =="
reset; touch "$T_HAS_SESSION"; gen pid=4243 birth=boot-s:111; line no-process "" "" "" "" "" gone-noreceipt "" "" "" "" "" '$7:1789000000' ""; run; run
case "$(gget stop_intent)" in zombie-*) ok "18a intent";; *) bad "18a intent" "$(gget stop_intent)";; esac
# the spawn that followed re-opened the claim, which clears stop_receipt: the receipt is proven by the order of tmux calls
is "18b kill-session before new-session" "$(grep -n 'kill-session\|new-session' "$TMUX_LOG" | head -2 | cut -d: -f2 | cut -d' ' -f3 | tr '\n' ' ')" "kill-session new-session "
is "18c has-session asked on \$7 after the kill" "$(grep -c 'has-session -t \$7' "$TMUX_LOG")" "1"

echo "== 20. launch_child 0 past the window: the crash path respawns =="
reset; gen launch_ms=1 launch_uptime_ms=1 launch_nonce=abc; line no-process "" "" "" "" "" gone-noreceipt "" 0 "" "" "" "" ""; run; run; is "20 one spawn" "$(tl new-session)" "1"

echo "== 22. rename: desired != applied on a fresh managed row -> two rounds, then /rename to the EXACT pane, applied only on the full receipt =="
OLD() { line identified:managed 4243 boot-s:111 "$NAME:@0.%0" "Old" 1789000000000 alive live:managed "" 4243 thread-4243 1789000000000 '$7:1789000000' 777; }
reset; touch "$T_HAS_SESSION"; echo full > "$T_RENAME_EFFECT"; OLD; run
is "22a round one: the baseline is seeded, nothing typed" "$(grep -c . "$T_SENDKEYS")" "0"
is "22b pending_for recorded" "$(gget pending_for)" "Alpha→Thing"; is "22c pending_since = the observation that must advance" "$(gget pending_since)" "1789000000000"
run; is "22a2 round two: the keyed suspect's first sighting, nothing typed" "$(grep -c . "$T_SENDKEYS")" "0"
run; is "22d round three: two send-keys (text, Enter), both to the bridge's exact pane" "$(sk "$NAME:@0.%0")" "2"; is "22e never to the bare session name" "$(sk "$NAME")" "0"
is "22f rename_tries=1" "$(gget rename_tries)" "1"; is "22g not yet applied" "$(gget applied)" ""
run; is "22h round four: applied from the FULL receipt (pane + bridge name + nameSince advanced)" "$(gget applied)" "Alpha→Thing"
is "22i applied_nameSince is the advanced one" "$(gget applied_nameSince)" "1789000000001"; is "22j pending cleared" "$(gget pending_for)" ""
[ -f "$STATE/$NAME.rename-pending" ] && bad "22k trace file gone" "" || ok "22k trace file gone"; has "22l says receipted" "$OUT" "receipted"
run; is "22m a further round types nothing (desired = applied)" "$(grep -c . "$T_SENDKEYS")" "2"

echo "== 23. receipt LEVELS: the pane line alone, or the bridge name without an advanced nameSince, is not applied =="
reset; touch "$T_HAS_SESSION"; echo receipt > "$T_RENAME_EFFECT"; OLD; run; run; run; run
is "23a pane receipt and nameSince advanced, but the bridge still says Old -> applied stays empty" "$(gget applied)" ""
reset; touch "$T_HAS_SESSION"; echo noadvance > "$T_RENAME_EFFECT"; OLD; run; run; run; run
is "23b bridge says desired but nameSince unchanged -> applied stays empty" "$(gget applied)" ""

echo "== 23b. P1b case B, MEASURED 2026-09-12: a resumed process whose bridge ALREADY reports the desired name is not a receipt =="
# The deployed supervisor resumed the hub's thread with --remote-control 'Steward→Basement (P1b-B)'; the
# bridge file reported that name with a fresh nameSince; the tile in claude.ai stayed on the OLD name for
# five minutes and longer. So a bridge that reads desired from the start proves nothing about the tile:
# the cycle must still type /rename and take the pane's own receipt line.
RESUMED() { line identified:managed 4243 boot-s:111 "$NAME:@0.%0" "Alpha→Thing" 1789000000005 alive live:managed "" 4243 thread-4243 1789000000000 '$7:1789000000' 777; }
reset; touch "$T_HAS_SESSION"; echo full > "$T_RENAME_EFFECT"; RESUMED; run
is "23b1 baseline seeded from the resumed bridge's own nameSince" "$(gget pending_since)" "1789000000005"
is "23b2 nothing receipted from the bridge alone" "$(gget applied)" ""
run; run
is "23b3 /rename IS typed although the bridge already read desired" "$(sk "$NAME:@0.%0")" "2"
run; is "23b4 applied only after the pane's receipt line and an advanced nameSince" "$(gget applied)" "Alpha→Thing"

echo "== 24-25. the foreground is measured on the tty, never by the command's name =="
# THE PRODUCTION SHAPE, MEASURED ON THE LIVE HOST 2026-09-11: the launch string ends "; exec bash" in a
# non-interactive shell, so claude never gets a process group of its own - pane shell and claude share
# pgid, and tmux reports the pane's current command as "bash" for a perfectly healthy session. A guard
# that required the command to be "claude" passed every fixture and would have blocked every real rename.
reset; touch "$T_HAS_SESSION"; echo full > "$T_RENAME_EFFECT"; echo bash > "$T_FG_CMD"
pstat 4242 bash 1 4242 34816 4242 100; pstat 4243 claude 4242 4242 34816 4242 111   # one group, as in production
OLD; run; run; run
is "24a the production shape types (pane command 'bash', one shared process group)" "$(grep -c . "$T_SENDKEYS")" "2"
pstat 4242 bash 1 4242 34816 4243 100; pstat 4243 claude 4242 4243 34816 4243 111   # back to the fixture's own shape
reset; touch "$T_HAS_SESSION"; echo full > "$T_RENAME_EFFECT"; pstat 4243 claude 4242 4243 34817 4243 111; OLD; run; run; run; run
is "25a same tpgid, different tty_nr -> nothing typed" "$(grep -c . "$T_SENDKEYS")" "0"; has "25a2 and says the foreground changed" "$OUT" "foreground"
reset; touch "$T_HAS_SESSION"; echo full > "$T_RENAME_EFFECT"; pstat 4242 bash 1 4242 34816 4300 100; OLD; run; run; run; run
is "25b a human's command takes the tty (another foreground group) -> nothing typed" "$(grep -c . "$T_SENDKEYS")" "0"
reset; touch "$T_HAS_SESSION"; echo full > "$T_RENAME_EFFECT"; pstat 4243 claude 4242 4299 34816 4243 111; OLD; run; run; run; run
is "25c the managed process is not IN the foreground group -> nothing typed" "$(grep -c . "$T_SENDKEYS")" "0"

echo "== 26. a busy pane between the two rounds restarts the count =="
reset; touch "$T_HAS_SESSION"; echo full > "$T_RENAME_EFFECT"; OLD; run; run; touch "$T_BUSY"; run; rm -f "$T_BUSY"; run
is "26a busy in between: the round after it still types nothing" "$(grep -c . "$T_SENDKEYS")" "0"; run; is "26b the next identical round types" "$(grep -c . "$T_SENDKEYS")" "2"

echo "== 27. an RC-free row (RC_LABEL=\"\") spawns without --remote-control and WITH --name = the derived display =="
printf 'NAME="Thing"\nPARENT="alpha"\n' > "$ROOT/projects.d/thing.conf"
reset; row_claude 'RC_LABEL=""' 'TARGET_PROJECT="thing"'; line no-process "" "" "" "" "" gone-noreceipt "" "" "" "" "" "" ""; run; run
ns="$(grep 'new-session' "$TMUX_LOG" | head -1)"; hasnt "27a no --remote-control" "$ns" "remote-control"; has "27b --name carries the derived display" "$ns" '--name "Alpha→Thing"'

echo "== 28. the display as a fact: a running row whose display no longer derives is DEGRADED once, recovers, alarms again =="
reset; row_claude 'TARGET_PROJECT="nope"'; touch "$T_HAS_SESSION"; MANAGED; run
is "28a rc 0: identity keeps it alive" "$RC" "0"; [ -f "$STATE/$NAME.display-degraded" ] && ok "28b degraded marker" || bad "28b degraded marker" ""; has "28c alarm names the display" "$OUT" "display"
run; is "28d second round: no second alarm" "$(grep -c 'no longer derives' "$T/out")" "0"
printf 'NAME="Nope"\nPARENT="alpha"\n' > "$ROOT/projects.d/nope.conf"; run; [ -f "$STATE/$NAME.display-degraded" ] && bad "28e recovered: marker cleared" "" || ok "28e recovered: marker cleared"
rm -f "$ROOT/projects.d/nope.conf"; run; has "28f broken again: alarms once more" "$OUT" "no longer derives"
is "28g nothing typed into the pane while degraded (no desired)" "$(grep -c . "$T_SENDKEYS")" "0"
rm -f "$T_HAS_SESSION"; line no-process "" "" "" "" "" gone-noreceipt "" "" "" "" "" "" ""; run; run
is "28h a NEW spawn with an unresolvable display is refused, rc 78" "$RC" "78"; is "28i and nothing spawned" "$(tl new-session)" "0"; has "28j the refusal names the missing link" "$OUT" "nope"

echo "== 29. the re-ping goes to the exact pane too =="
reset; touch "$T_HAS_SESSION"; MANAGED; gen applied="Alpha→Thing"; mkdir -p "$HOMEDIR/.config/agent-bus/$NAME/inbox"; printf '{}' > "$HOMEDIR/.config/agent-bus/$NAME/inbox/1789000000-x.json"; run
is "29a ping typed to the bridge's pane" "$(sk "$NAME:@0.%0")" "2"; is "29b never to the bare name" "$(sk "$NAME")" "0"; rm -rf "$HOMEDIR/.config/agent-bus"

echo "== 36. J3: the rename's receipt and type are judged on a FRESH observation =="
# type: seed, suspect, then at the type boundary the process is gone -> nothing typed
reset; touch "$T_HAS_SESSION"; echo full > "$T_RENAME_EFFECT"; OLD; run; run
qline identified:managed 4243 boot-s:111 "$NAME:@0.%0" "Old" 1789000000000 alive live:managed "" 4243 thread-4243 1789000000000 '$7:1789000000' 777   # the round's alive check: still managed
qline identified:managed 4243 boot-s:111 "$NAME:@0.%0" "Old" 1789000000000 alive live:managed "" 4243 thread-4243 1789000000000 '$7:1789000000' 777   # the rename step's first re-observation
qline no-process "" "" "" "" "" gone-noreceipt "" "" "" "" "" '$7:1789000000' ""                                                                # immediately before typing: gone
run; is "36a the process vanished immediately before typing -> nothing typed" "$(grep -c . "$T_SENDKEYS")" "0"; has "36b says so" "$OUT" "changed immediately before typing"
# receipt: pane shows it, the static line says desired+advanced, but the fresh observation at the boundary says the process is gone
reset; touch "$T_HAS_SESSION"; echo full > "$T_RENAME_EFFECT"; OLD; run; run; run   # typed; the static line now reads desired, nameSince advanced
qline identified:managed 4243 boot-s:111 "$NAME:@0.%0" "Alpha→Thing" 1789000000001 alive live:managed "" 4243 thread-4243 1789000000000 '$7:1789000000' 777
qline no-process "" "" "" "" "" gone-noreceipt "" "" "" "" "" '$7:1789000000' ""
run; is "36c the receipt is not written from a stale observation" "$(gget applied)" ""; has "36d says the process changed" "$OUT" "changed between the round's observation and the rename step"

echo "== 36b. K1: the foreground is read AFTER the final observation - a subprocess that takes the tty during it stops the keys =="
reset; touch "$T_HAS_SESSION"; echo full > "$T_RENAME_EFFECT"; OLD; run; run
# THE FLIP HAPPENS DURING THE THIRD OBSERVATION OF THE ROUND - the final one before the keys (the
# first is the alive check, the second the rename step's receipt recheck). A flip on any earlier call
# would be caught by the ordinary foreground check in either order and prove nothing about the order.
# The foreground is a tty fact, so the flip is one: a human's command takes the tty's process group.
printf '[ "$(grep -c . "%s")" -eq 3 ] && printf "4242 (bash) S 1 4242 4242 34816 4300 0 0 0 0 0 0 0 0 0 0 20 0 1 0 100 0 0 0\\n" > "%s"\n' "$OBS_LOG" "$PROC/4242/stat" > "$OBS_SIDE_EFFECT"
run
is "36e the foreground flipped during the final observation -> nothing typed" "$(grep -c . "$T_SENDKEYS")" "0"; has "36f says the foreground changed" "$OUT" "foreground"

echo "== 36c. K2: the immediate recheck includes the vendor's procStart =="
reset; touch "$T_HAS_SESSION"; echo full > "$T_RENAME_EFFECT"; OLD; run; run
qline identified:managed 4243 boot-s:111 "$NAME:@0.%0" "Old" 1789000000000 alive live:managed "" 4243 thread-4243 1789000000000 '$7:1789000000' 777
qline identified:managed 4243 boot-s:111 "$NAME:@0.%0" "Old" 1789000000000 alive live:managed "" 4243 thread-4243 1789000000000 '$7:1789000000' 777
qline identified:managed 4243 boot-s:111 "$NAME:@0.%0" "Old" 1789000000000 alive live:managed "" 9999 thread-4243 1789000000000 '$7:1789000000' 777
run; is "36g same pid, birth and pane but another procStart immediately before typing -> nothing typed" "$(grep -c . "$T_SENDKEYS")" "0"; has "36h names the procStart" "$OUT" "procStart 9999"
reset; touch "$T_HAS_SESSION"; echo full > "$T_RENAME_EFFECT"; OLD; run; run; run
qline identified:managed 4243 boot-s:111 "$NAME:@0.%0" "Alpha→Thing" 1789000000001 alive live:managed "" 4243 thread-4243 1789000000000 '$7:1789000000' 777
qline identified:managed 4243 boot-s:111 "$NAME:@0.%0" "Alpha→Thing" 1789000000001 alive live:managed "" 9999 thread-4243 1789000000000 '$7:1789000000' 777
run; is "36i a procStart contradiction at the receipt boundary -> not receipted" "$(gget applied)" ""

echo "== 37. J4: rename-state writes are receipts; an unreadable baseline is re-seeded, never coerced to 0 =="
reset; touch "$T_HAS_SESSION"; echo full > "$T_RENAME_EFFECT"; gen pending_for="Alpha→Thing" pending_since=abc rename_tries=0
line identified:managed 4243 boot-s:111 "$NAME:@0.%0" "Alpha→Thing" 1789000000001 alive live:managed "" 4243 thread-4243 1789000000000 '$7:1789000000' 777; printf 'Alpha→Thing\n' > "$T_RECEIPT"
run; is "37a pane receipt + bridge desired + corrupt baseline -> NOT receipted" "$(gget applied)" ""; is "37b baseline re-seeded from the current observation" "$(gget pending_since)" "1789000000001"
reset; touch "$T_HAS_SESSION"; echo full > "$T_RENAME_EFFECT"; OLD; run; chmod 500 "$STATE"; run; run; chmod 700 "$STATE"
is "37c with the state unwritable nothing is typed (the attempt could not be counted, the suspect could not be kept)" "$(grep -c . "$T_SENDKEYS")" "0"

echo "== 38. J7: type_line reports delivery; a failed literal is no attempt, a failed Enter is a loud partial one =="
reset; touch "$T_HAS_SESSION"; echo full > "$T_RENAME_EFFECT"; OLD; run; run; touch "$T_SENDKEYS_FAIL"; run
is "38a literal failed -> rename_tries stays 0" "$(gget rename_tries)" "0"; has "38b says nothing reached the pane" "$OUT" "nothing reached the pane"
reset; touch "$T_HAS_SESSION"; echo full > "$T_RENAME_EFFECT"; OLD; run; run; touch "$T_ENTER_FAIL"; run
is "38c Enter failed -> counted as an attempt" "$(gget rename_tries)" "1"; has "38d and loud about the partial delivery" "$OUT" "PARTIAL delivery"; is "38e one send-keys only (no retry in the round)" "$(grep -c . "$T_SENDKEYS")" "1"

echo "== 30. H1: the action boundary re-observes, and acts only on the SAME answer and key =="
# THE QUEUE: the round's first observation must still CONFIRM the key (orphan again); only the re-observation
# at the action boundary sees the changed world. One queued line would have been eaten by the alive check.
reset; ORPHAN; run; qline identified:orphan 4243 boot-s:111 "$NAME:@0.%0" "X" 1 alive live:orphan "" 4243 t 1 "" 1; qline identified:moved 4243 boot-s:111 "$NAME:@0.%0" "X" 1 alive live:moved "" 4243 t 1 '$7:1' 1; run
is "30a orphan confirmed, then MOVED at the boundary -> no kill" "$(grep -c . "$BKILL_LOG")" "0"; has "30b says so" "$OUT" "re-observation before the action differs"
[ -f "$SUSPECT" ] && bad "30c suspect reset" "" || ok "30c suspect reset"
reset; line no-process "" "" "" "" "" gone-noreceipt "" "" "" "" "" "" ""; run; qline no-process "" "" "" "" "" gone-noreceipt "" "" "" "" "" "" ""; qline identified:managed 4243 boot-s:111 "$NAME:@0.%0" "Alpha→Thing" 1 alive live:managed "" 4243 t 1 "" 777; run
is "30d spawn-absent confirmed, then IDENTIFIED at the boundary -> no spawn" "$(tl new-session)" "0"
reset; touch "$T_HAS_SESSION"; gen pid=4243 birth=boot-s:111; line no-process "" "" "" "" "" gone-noreceipt "" "" "" "" "" '$7:1789000000' ""; run
qline no-process "" "" "" "" "" gone-noreceipt "" "" "" "" "" '$7:1789000000' ""; qline wait-veto "" "" "" "" "" gone-noreceipt "" "" "" "" "" '$7:1789000000' ""; run
is "30e close confirmed, then WAIT-VETO at the boundary -> no kill, no intent" "$(tl kill-session)$(gget stop_intent)" "0"
reset; ORPHAN; run; qline identified:orphan 4243 boot-s:111 "$NAME:@0.%0" "X" 1 alive live:orphan "" 4243 t 1 "" 1; qline identified:orphan 4300 boot-s:222 "$NAME:@0.%0" "X" 1 alive live:orphan "" 4300 t 1 "" 1; run
is "30f orphan, but a DIFFERENT pid at the boundary -> no kill" "$(grep -c . "$BKILL_LOG")" "0"

echo "== 31. H2: the kill helper is executed as itself, and its absence is a refusal =="
reset; ORPHAN; run; run; is "31a the helper ran (a bash shim with a shebang, executed directly)" "$(cat "$BKILL_LOG")" "4243 boot-s:111 TERM"
chmod 644 "$BIN/bkill"; reset; ORPHAN; run; run; is "31b not executable -> nothing signalled" "$(grep -c . "$BKILL_LOG")" "0"; has "31c says the helper is missing" "$OUT" "kill helper"; chmod 755 "$BIN/bkill"

echo "== 32. H3: a generation write that fails gates the action =="
reset; line no-process "" "" "" "" "" gone-noreceipt "" "" "" "" "" "" ""; run; chmod 500 "$STATE"; run; chmod 700 "$STATE"
is "32a pending claim unwritable -> no new-session" "$(tl new-session)" "0"; has "32b says the claim could not be written" "$OUT" "could not be written"
reset; touch "$T_HAS_SESSION"; gen pid=4243 birth=boot-s:111; line no-process "" "" "" "" "" gone-noreceipt "" "" "" "" "" '$7:1789000000' ""; run; chmod 500 "$STATE"; run; chmod 700 "$STATE"
is "32c stop_intent unwritable -> no kill" "$(tl kill-session)" "0"; has "32d says so" "$OUT" "stop intent could not be written"
reset; touch "$T_HAS_SESSION"; gen pid=4243 birth=boot-s:111; line no-process "" "" "" "" "" gone-noreceipt "" "" "" "" "" '$7:1789000000' ""; run; touch "$T_KILL_LOCKS_STATE"; run; chmod 700 "$STATE"
is "32e closed, but the receipt unwritable -> NO spawn" "$(tl new-session)" "0"; is "32f the kill did happen" "$(tl kill-session)" "1"; has "32g says: no spawn without a receipt" "$OUT" "NO spawn without a receipt"

echo "== 33. H4: the observer's line is a fifteen-field contract =="
reset; printf '%s\037no-process\n' "$NAME" > "$OBSLINE"; run; run; is "33a a two-field no-process with the right id -> no action" "$(tl new-session)" "0"; has "33b unreadable" "$OUT" "observer-unreadable"
reset; MANAGED; cp "$OBSLINE" "$T/l1"; cat "$T/l1" >> "$OBSLINE"; touch "$T_HAS_SESSION"; run; has "33c two lines -> unreadable" "$OUT" "observer-unreadable"; is "33d nothing bound" "$(gget pid)" ""
reset; line no-process 4243 "" "" "" "" gone-noreceipt "" "" "" "" "" "" ""; run; run; is "33e no-process carrying a pid violates the invariant -> no spawn" "$(tl new-session)" "0"
reset; line identified:managed "" "" "" "" "" alive live:managed "" "" "" "" "" ""; touch "$T_HAS_SESSION"; run; is "33f identified without pid/birth/pane -> unreadable, nothing bound" "$(gget pid)" ""
reset; line bogus-answer "" "" "" "" "" none "" "" "" "" "" "" ""; run; run; is "33g an answer outside the vocabulary -> nothing" "$(tl new-session)$(tl kill-session)" "00"
# K5: an identified row is TYPED and names THIS row's exact pane - or it is not an identified row
reset; touch "$T_HAS_SESSION"; echo full > "$T_RENAME_EFFECT"; line identified:managed 4243 boot-s:111 "s-0000000000000009:@0.%0" "Old" 1789000000000 alive live:managed "" 4243 thread-4243 1789000000000 '$7:1789000000' 777; run; run; run; run
is "33m identified with a FOREIGN pane -> nothing bound" "$(gget pid)" ""; is "33n and nothing typed anywhere" "$(grep -c . "$T_SENDKEYS")" "0"; has "33o unreadable" "$OUT" "observer-unreadable"
reset; touch "$T_HAS_SESSION"; echo full > "$T_RENAME_EFFECT"; line identified:managed 4243 boot-s:111 "$NAME:@0.%0" "Old" 1789000000000 alive live:managed "" "" thread-4243 1789000000000 '$7:1789000000' 777; run; run; run; run
is "33p identified with an EMPTY procStart -> nothing bound" "$(gget pid)" ""; is "33q nothing typed" "$(grep -c . "$T_SENDKEYS")" "0"
reset; touch "$T_HAS_SESSION"; line identified:managed 4243 boot-s:111 "$NAME:@x.%0" "Old" 1789000000000 alive live:managed "" 4243 thread-4243 1789000000000 '$7:1789000000' 777; run; is "33r a pane with a non-numeric window is not a pane" "$(gget pid)" ""
reset; touch "$T_HAS_SESSION"; line identified:managed 4243 boot-s:abc "$NAME:@0.%0" "Old" 1789000000000 alive live:managed "" 4243 thread-4243 1789000000000 '$7:1789000000' 777; run; is "33s a birth without numeric ticks is not a birth" "$(gget pid)" ""
reset; touch "$T_HAS_SESSION"; line identified:managed 4243 boot-s:111 "$NAME:@0.%0" "Old" "" alive live:managed "" 4243 thread-4243 1789000000000 '$7:1789000000' 777; run; is "33t an empty nameSince on an identified row is refused" "$(gget pid)" ""
reset; touch "$T_HAS_SESSION"; line identified:managed 4243 boot-s:111 "$NAME:@0.%0" "Old" 1789000000000 alive live:managed "" 4243 thread-4243 1789000000000 '$7:1789000000' ""; run; is "33u an empty inode on an identified row is refused" "$(gget pid)" ""
reset; touch "$T_HAS_SESSION"; line identified:managed 4243 boot-s:111 "${NAME}0:@0.%0" "Old" 1789000000000 alive live:managed "" 4243 thread-4243 1789000000000 '$7:1789000000' 777; run; is "33v a pane whose session is a superstring of this id is foreign" "$(gget pid)" ""
reset; touch "$T_HAS_SESSION"; line identified:managed 4243 boot-s:111 "$NAME:@0.%0.%1" "Old" 1789000000000 alive live:managed "" 4243 thread-4243 1789000000000 '$7:1789000000' 777; run; is "33w K6: '<id>:@0.%0.%1' is not a pane" "$(gget pid)" ""
reset; touch "$T_HAS_SESSION"; line identified:managed 4243 boot-s:111 "$NAME:@0.%0:@1.%1" "Old" 1789000000000 alive live:managed "" 4243 thread-4243 1789000000000 '$7:1789000000' 777; run; is "33x K6: '<id>:@0.%0:@1.%1' is not a pane" "$(gget pid)" ""
reset; line no-process "" "" "" "" "" gone-noreceipt "" "" "" "" "" ""; run; run; is "33h a FOURTEEN-field no-process (inode missing) is not the contract -> no spawn" "$(tl new-session)" "0"
reset; line no-process "" "" "" "" "" alive "" "" "" "" "" "" ""; run; run; is "33i K3: no-process beside gen_state=alive is impossible output -> no spawn, twice" "$(tl new-session)" "0"; has "33j unreadable" "$OUT" "observer-unreadable"
reset; touch "$T_HAS_SESSION"; gen pid=4243 birth=boot-s:111; line no-process "" "" "" "" "" grace "" "" "" "" "" '$7:1789000000' ""; run; run; is "33k no-process beside grace -> no close" "$(tl kill-session)" "0"
reset; touch "$T_HAS_SESSION"; line grace "" "" "" "" "" alive "" "" "" "" "" '$7:1789000000' ""; run; has "33l grace beside alive is refused too" "$OUT" "observer-unreadable"

echo "== 34. H5: a syntactically broken bridge.sh ends nothing for OpenCode and refuses a claude row =="
# THE BROKEN LIBRARY EXITS: a sourced `exit` ends the sourcing shell, which is what "a broken bridge.sh can
# end the whole OpenCode round" means in practice (a bare syntax error is survived by bash's source).
cp "$LIBS/bridge.sh" "$LIBS/bridge.sh.good"; printf 'echo "bridge.sh is broken" >&2\nexit 3\n' > "$LIBS/bridge.sh"
reset; rm -f "$T_HAS_SESSION"; run "$OC"; is "34a OpenCode round rc 0 with a broken bridge.sh" "$RC" "0"; is "34b and it spawned through the adapter" "$(tl "new-session.*$ADAPTER")" "1"
reset; touch "$T_HAS_SESSION"; MANAGED; run; is "34c a claude row refuses, rc 78" "$RC" "78"; has "34d names the library" "$OUT" "bridge"
mv "$LIBS/bridge.sh.good" "$LIBS/bridge.sh"

echo "== 35. H7: the bind is the WHOLE record, and a refused claim is not a resume attempt =="
reset; touch "$T_HAS_SESSION"; MANAGED; gen applied="Alpha→Thing"; run
line identified:managed 4243 boot-s:111 "$NAME:@0.%0" "Alpha→Thing" 1789000000000 alive live:managed "" 4243 thread-NEW 1789000000000 '$7:1789000000' 777; run
is "35a a changed sessionId is rebound" "$(gget sessionId)" "thread-NEW"
line identified:managed 4243 boot-s:111 "$NAME:@0.%0" "Alpha→Thing" 1789000000000 alive live:managed "" 9999 thread-NEW 1789000000000 '$7:1789000000' 777; run
is "35b K4: the same pid+birth with ANOTHER procStart is a contradiction - NOT rebound" "$(gget procStart)" "4243"
[ -f "$STATE/$NAME.identity-degraded" ] && ok "35b2 and the row is marked degraded" || bad "35b2 and the row is marked degraded" ""; has "35b3 loud, once" "$OUT" "contradiction is not rebound"
run; is "35b4 the second round does not repeat the alarm" "$(grep -c 'contradiction is not rebound' "$T/out")" "0"
line identified:managed 4243 boot-s:111 "$NAME:@0.%0" "Alpha→Thing" 1789000000000 alive live:managed "" 4243 thread-NEW 1789000000000 '$7:1789000000' 778; run
is "35c a changed inode (same procStart) is rebound" "$(gget bridge_inode)" "778"
reset; printf 'bad\n' > "$NONCE_FILE"; line no-process "" "" "" "" "" gone-noreceipt "" "" "" "" "" "" ""; run; run; run; run
[ -f "$STATE/$NAME.resume-try" ] && bad "35d refused claims do not count as resume attempts" "$(cat "$STATE/$NAME.resume-try")" || ok "35d refused claims do not count as resume attempts"
[ -f "$STATE/$NAME.launched" ] && bad "35e no launch mark without a launch" "" || ok "35e no launch mark without a launch"
printf '0123456789abcdef0123456789abcdef\n' > "$NONCE_FILE"

echo "== 39. Task 9b: the HOST GATE - a live row's applied or pending display reserves it on this host =="
OTHER="s-0000000000000003"
other_gen() { bash -c ". '$LIBS/bridge.sh'; bridge_gen_write '$STATE' '$OTHER' $*"; }
other_row() { printf 'OWNER="a"\nHOST="h1"\nDOMAIN="alpha"\nREPO_PATH="%s/Projects/repo"\nID="%s"\nACCOUNT="a-h1"\nRC_LABEL="Other Thing"\n' "$HOMEDIR" "$OTHER" > "$ROOT/sessions.d/$OTHER.conf"; }
# WHAT HOLDS A DISPLAY IS A LIVE BRIDGE FILE (M3): the other row is ASKED, and only identified:* counts.
other_live() { printf '%s\037identified:managed\0374300\037boot-s:300\037%s:@0.%%0\037%s\0371\037alive\037live:managed\037\0374300\037t\0371\037$9:1\037778\n' "$OTHER" "$OTHER" "${1:-Other Thing}" > "$T/obs-other/$OTHER"; }
other_dead() { printf '%s\037no-process\037\037\037\037\037\037gone-noreceipt\037\037\037\037\037\037\037\n' "$OTHER" > "$T/obs-other/$OTHER"; }
reset; other_row; other_live; other_gen applied="Alpha→Thing" census=1
line no-process "" "" "" "" "" gone-noreceipt "" "" "" "" "" "" ""; run; out1="$OUT"; run
is "39a the display is applied by a LIVE row: spawn refused" "$(tl new-session)" "0"; is "39b rc 78" "$RC" "78"; has "39c names the holder (first round, alarm once)" "$out1" "reserved on this host by the live row 's-0000000000000003'"
run; is "39d the alarm is once (marker)" "$(grep -c 'reserved on this host' "$T/out")" "0"
other_dead; run; run; is "39e the holder has NO live bridge file -> the display is free -> one spawn" "$(tl new-session)" "1"
[ -f "$STATE/$NAME.display-reserved" ] && bad "39f marker cleared when free" "" || ok "39f marker cleared when free"
reset; other_row; other_live "Something Else"; other_gen pending_for="Alpha→Thing" census=1
line no-process "" "" "" "" "" gone-noreceipt "" "" "" "" "" "" ""; run; run; is "39g a PENDING display reserves too" "$(tl new-session)" "0"
reset; other_row; other_live "Alpha→Thing"; other_gen census=1
line no-process "" "" "" "" "" gone-noreceipt "" "" "" "" "" "" ""; run; run; is "39h the live bridge's REPORTED name is the additional collision guard" "$(tl new-session)" "0"
reset; other_row; other_live "Something Else"; other_gen applied="Something Else" census=1
line no-process "" "" "" "" "" gone-noreceipt "" "" "" "" "" "" ""; run; run; is "39i another display reserves nothing" "$(tl new-session)" "1"
# the rename step
reset; other_row; other_live; other_gen applied="Alpha→Thing" census=1
touch "$T_HAS_SESSION"; echo full > "$T_RENAME_EFFECT"; OLD; run; out1="$OUT"; run; run; run
is "39j a managed row whose desired is reserved: nothing typed" "$(grep -c . "$T_SENDKEYS")" "0"; is "39k no baseline seeded" "$(gget pending_for)" ""; has "39l refused to rename, loud (first round, once)" "$out1" "REFUSING to rename"
is "39l2 and not repeated" "$(grep -c 'REFUSING to rename' "$T/out")" "0"
# ANOTHER UNIX ACCOUNT, THE SAME LOGIN. This is the only shape in which another owner's row can collide
# at all: the key is the LOGIN, so two homes only share a namespace when they share a login - one human
# with two unix accounts on one host, which is exactly the pair the credential seam was repaired for. The
# other home is 0750 from here, so the row can be RENDERED from the register but never ASKED.
mkdir -p "$ROOT/logins.d"; chmod 700 "$ROOT/logins.d"
printf 'PRINCIPAL="a"\nACCOUNT="a@example.test"\nPROVIDER="claude-team"\nCONFIG_DIR="~/.claude-logins/shared"\nLEGAL_OWNER="Fixture"\n' > "$ROOT/logins.d/shared-login.conf"
chmod 600 "$ROOT/logins.d/shared-login.conf"
printf 'PRINCIPAL="a"\nHOST="h1"\nUSERNAME="b"\n' > "$ROOT/accounts.d/b-h1.conf"
printf 'OWNER="b"\nHOST="h1"\nDOMAIN="alpha"\nREPO_PATH="%s/Projects/repo"\nID="s-0000000000000004"\nACCOUNT="b-h1"\nLOGIN="shared-login"\nRC_LABEL="Alpha→Thing"\n' "$HOMEDIR" > "$ROOT/sessions.d/s-0000000000000004.conf"
reset; row_claude 'RC_LABEL="Alpha→Thing"' 'LOGIN="shared-login"'; line no-process "" "" "" "" "" gone-noreceipt "" "" "" "" "" "" ""; run; out1="$OUT"; run
is "39m non-strict: the other home's identical display is noted, not refused (one spawn)" "$(tl new-session)" "1"; has "39n the note names the row and the strict knob" "$out1" "STEWARD_RESERVATION_STRICT"
reset; row_claude 'RC_LABEL="Alpha→Thing"' 'LOGIN="shared-login"'; line no-process "" "" "" "" "" gone-noreceipt "" "" "" "" "" "" ""
STEWARD_RESERVATION_STRICT=1 run; out1="$OUT"; STEWARD_RESERVATION_STRICT=1 run
is "39o strict: refused, manual census required" "$(tl new-session)" "0"; has "39p says so" "$out1" "MANUAL CENSUS REQUIRED"
reset; row_claude 'RC_LABEL="Alpha→Thing"'; line no-process "" "" "" "" "" gone-noreceipt "" "" "" "" "" "" ""
STEWARD_RESERVATION_STRICT=1 run; STEWARD_RESERVATION_STRICT=1 run
is "39q a row under ANOTHER login key is not blocked, even in strict mode (two tile lists)" "$(tl new-session)" "1"
rm -f "$ROOT/sessions.d/s-0000000000000004.conf" "$ROOT/accounts.d/b-h1.conf" "$ROOT/logins.d/shared-login.conf"

echo "== 40. Task 9b, advisor M4: the check and the write it authorises are ONE critical section =="
# THE LOCK IS HELD WHILE THE GATE RUNS. The observer is called from inside the gate, so a shim that tries
# to take the same lock measures the critical section from within it - no timing, no sleep.
reset; other_row; other_live "Something Else"; other_gen census=1
# ONLY THE CALLS THE GATE MAKES COUNT - the round's own observation of THIS row runs before the gate, and
# is not in the critical section.
printf '[ "$1" = "%s" ] && exit 0\nmkdir "%s" 2>/dev/null && { echo FREE >> "%s"; rmdir "%s"; } || echo HELD >> "%s"\n' "$NAME" "$STATE/.display-reservation.lock" "$T/lockprobe" "$STATE/.display-reservation.lock" "$T/lockprobe" > "$OBS_SIDE_EFFECT"
: > "$T/lockprobe"; line no-process "" "" "" "" "" gone-noreceipt "" "" "" "" "" "" ""; run; run
is "40a the lock was held every time the gate looked" "$(grep -c FREE "$T/lockprobe")" "0"
case "$(grep -c HELD "$T/lockprobe")" in 0) bad "40b and it was actually probed" "no probe ran" ;; *) ok "40b and it was actually probed" ;; esac
rm -f "$OBS_SIDE_EFFECT"
[ -d "$STATE/.display-reservation.lock" ] && bad "40c the lock is released at the end of the round" "" || ok "40c the lock is released at the end of the round"
is "40d the spawn happened under it" "$(tl new-session)" "1"
is "40e and the claim RESERVED the display for the next asker" "$(gget pending_for)" "Alpha→Thing"

echo "== 41. a lock another supervisor holds stands the round down; a stale one is broken =="
reset; other_row; other_dead; line no-process "" "" "" "" "" gone-noreceipt "" "" "" "" "" "" ""; run
mkdir -p "$STATE/.display-reservation.lock"; run
is "41a a held lock: no spawn" "$(tl new-session)" "0"; has "41b and says why" "$OUT" "another supervisor holds the display reservation lock"
touch -d @1700000000 "$STATE/.display-reservation.lock"; run
is "41c a lock older than the limit is broken and the round proceeds" "$(tl new-session)" "1"; has "41d loudly" "$OUT" "breaking it"
[ -d "$STATE/.display-reservation.lock" ] && bad "41e and released again" "" || ok "41e and released again"
reset; touch "$T_HAS_SESSION"; echo full > "$T_RENAME_EFFECT"; OLD; run; mkdir -p "$STATE/.display-reservation.lock"; run; run
is "41f a held lock stops the rename step too" "$(grep -c . "$T_SENDKEYS")" "0"; has "41g and says so" "$OUT" "no rename step this round"
rmdir "$STATE/.display-reservation.lock"

echo "== 42. an unwritable state directory is NOT contention =="
reset; line no-process "" "" "" "" "" gone-noreceipt "" "" "" "" "" "" ""; run; chmod 500 "$STATE"; run; chmod 700 "$STATE"
hasnt "42a it never claims another supervisor holds the lock" "$OUT" "another supervisor holds"
has "42b it says the lock cannot be created there" "$OUT" "cannot be created"
is "42c and nothing was spawned (the claim write refuses on the same directory)" "$(tl new-session)" "0"

echo "== 21. the bridge library missing on a claude row is a refusal; an OpenCode row does not care =="
reset; mv "$LIBS/bridge.sh" "$LIBS/bridge.sh.away"; touch "$T_HAS_SESSION"; MANAGED; run; is "21a rc 78" "$RC" "78"; has "21b names the library" "$OUT" "bridge"
run "$OC"; is "21c opencode still supervised (rc 0)" "$RC" "0"; mv "$LIBS/bridge.sh.away" "$LIBS/bridge.sh"

printf '\n%d passed, %d failed\n' "$pass" "$fail"; [ "$fail" -eq 0 ]
