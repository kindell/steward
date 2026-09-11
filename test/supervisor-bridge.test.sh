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
export T_FG_CMD="$T/fg-cmd" T_SENDKEYS="$T/sendkeys" T_RECEIPT="$T/receipt" T_RENAME_EFFECT="$T/rename-effect" T_BUSY="$T/busy"
cat > "$BIN/tmux" <<'EOF'
#!/bin/bash
printf '%s\n' "$*" >> "$TMUX_LOG"
argv=("$@"); [ "${argv[0]:-}" = "-S" ] && argv=("${argv[@]:2}")
last="${argv[${#argv[@]}-1]}"
case "${argv[0]:-}" in
  has-session)  [ -f "$T_HAS_SESSION" ] ;;
  list-panes)   [ -f "$T_HAS_SESSION" ] && echo 4242; exit 0 ;;
  list-clients) exit 0 ;;
  display-message) case "$last" in *session_id*) [ -f "$T_HAS_SESSION" ] && cat "$TUPLE" ;; *pane_current_command*) cat "$T_FG_CMD" 2>/dev/null || echo claude ;; *pane_pid*) echo 4242 ;; esac; exit 0 ;;
  send-keys) tgt=""; prev=""; txt=""; for a in "${argv[@]}"; do [ "$prev" = "-t" ] && tgt="$a"; [ "$prev" = "-l" ] && txt="$a"; prev="$a"; done
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
  kill-session) [ -f "$T_KILL_FAILS" ] && exit 1; rm -f "$T_HAS_SESSION"; exit 0 ;;
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
printf '%s\n' "$*" >> "$OBS_LOG"; cat "$OBSLINE"
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
MANAGED() { line identified:managed 4243 boot-s:111 "$NAME:@0.%0" "Alpha→Thing" 1789000000000 alive live:managed "" 4243 thread-4243 1789000000000 '$7:1789000000' 777; }
run() { # [id]
  : > "$TMUX_LOG"; : > "$PGREP_LOG"; : > "$OBS_LOG"; : > "$BKILL_LOG"
  HOME="$HOMEDIR" STEWARD_ESTATE_ROOT="$ROOT" STEWARD_CONFIG_FILE="$T/no-such-config" STEWARD_REGISTRY_LIB="$LIBS/registry.sh" STEWARD_BRIDGE_LIB="$LIBS/bridge.sh" \
  STEWARD_TMUX_SOCKET="$T/fixture.sock" STEWARD_BRIDGE_OBSERVE="$BIN/observe" STEWARD_BRIDGE_KILL="$BIN/bkill" STEWARD_NONCE_CMD="$BIN/nonce" \
  BRIDGE_PROC_ROOT="$PROC" STEWARD_KEY_SETTLE_SEC=0 PATH="$BIN:$PATH" bash "$SUP" "${1:-$NAME}" >"$T/out" 2>&1; RC=$?; OUT="$(cat "$T/out")"
}
reset() { rm -rf "$STATE"; mkdir -p "$STATE"; rm -f "$T_HAS_SESSION" "$T_KILL_FAILS" "$T_NEW_FAILS" "$T_GEN_AT_SPAWN" "$T_FG_CMD" "$T_RECEIPT" "$T_BUSY" "$T_RENAME_EFFECT"; : > "$T_SENDKEYS"
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
is "22a round one: nothing typed (the rename is a keyed two-round suspect)" "$(grep -c . "$T_SENDKEYS")" "0"
is "22b pending_for recorded" "$(gget pending_for)" "Alpha→Thing"; is "22c pending_since = the observation that must advance" "$(gget pending_since)" "1789000000000"
run; is "22d round two: two send-keys (text, Enter), both to the bridge's exact pane" "$(sk "$NAME:@0.%0")" "2"; is "22e never to the bare session name" "$(sk "$NAME")" "0"
is "22f rename_tries=1" "$(gget rename_tries)" "1"; is "22g not yet applied" "$(gget applied)" ""
run; is "22h round three: applied from the FULL receipt (pane + bridge name + nameSince advanced)" "$(gget applied)" "Alpha→Thing"
is "22i applied_nameSince is the advanced one" "$(gget applied_nameSince)" "1789000000001"; is "22j pending cleared" "$(gget pending_for)" ""
[ -f "$STATE/$NAME.rename-pending" ] && bad "22k trace file gone" "" || ok "22k trace file gone"; has "22l says receipted" "$OUT" "receipted"
run; is "22m a further round types nothing (desired = applied)" "$(grep -c . "$T_SENDKEYS")" "2"

echo "== 23. receipt LEVELS: the pane line alone, or the bridge name without an advanced nameSince, is not applied =="
reset; touch "$T_HAS_SESSION"; echo receipt > "$T_RENAME_EFFECT"; OLD; run; run; run
is "23a pane receipt and nameSince advanced, but the bridge still says Old -> applied stays empty" "$(gget applied)" ""
reset; touch "$T_HAS_SESSION"; echo noadvance > "$T_RENAME_EFFECT"; OLD; run; run; run
is "23b bridge says desired but nameSince unchanged -> applied stays empty" "$(gget applied)" ""

echo "== 24-25. the foreground must be the managed claude: command AND tty AND process group =="
reset; touch "$T_HAS_SESSION"; echo full > "$T_RENAME_EFFECT"; echo vim > "$T_FG_CMD"; OLD; run; run; run
is "24a foreground vim -> nothing typed" "$(grep -c . "$T_SENDKEYS")" "0"; has "24b says so" "$OUT" "foreground"
reset; touch "$T_HAS_SESSION"; echo full > "$T_RENAME_EFFECT"; pstat 4243 claude 4242 4243 34817 4243 111; OLD; run; run; run
is "25a same tpgid, different tty_nr -> nothing typed" "$(grep -c . "$T_SENDKEYS")" "0"
reset; touch "$T_HAS_SESSION"; echo full > "$T_RENAME_EFFECT"; pstat 4242 bash 1 4242 34816 4300 100; OLD; run; run; run
is "25b the tty's foreground group is another process -> nothing typed" "$(grep -c . "$T_SENDKEYS")" "0"

echo "== 26. a busy pane between the two rounds restarts the count =="
reset; touch "$T_HAS_SESSION"; echo full > "$T_RENAME_EFFECT"; OLD; run; touch "$T_BUSY"; run; rm -f "$T_BUSY"; run
is "26a busy in between: round three still types nothing" "$(grep -c . "$T_SENDKEYS")" "0"; run; is "26b round four types" "$(grep -c . "$T_SENDKEYS")" "2"

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

echo "== 21. the bridge library missing on a claude row is a refusal; an OpenCode row does not care =="
reset; mv "$LIBS/bridge.sh" "$LIBS/bridge.sh.away"; touch "$T_HAS_SESSION"; MANAGED; run; is "21a rc 78" "$RC" "78"; has "21b names the library" "$OUT" "bridge"
run "$OC"; is "21c opencode still supervised (rc 0)" "$RC" "0"; mv "$LIBS/bridge.sh.away" "$LIBS/bridge.sh"

printf '\n%d passed, %d failed\n' "$pass" "$fail"; [ "$fail" -eq 0 ]
