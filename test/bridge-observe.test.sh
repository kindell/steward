#!/bin/bash
# THE FIXTURES ARE /proc-SHAPED (BRIDGE_PROC_ROOT). Measured on minin 2026-09-12: without saying so, the
# OS facts layer picks the darwin backend there and the suite measures the HOST instead of its fixtures.
export BRIDGE_OS=linux

# PORTABILITY (measured on minin, macOS, 2026-09-12): touch -d, stat -c and sed -i spell differently on BSD.
# mtime is set through python3 (required on both platforms by bridge-kill); inode and mtime are read with
# both stat dialects; the observation queue is shortened with tail, never sed -i.
set_mtime() { python3 -c 'import os,sys; t=int(sys.argv[2]); os.utime(sys.argv[1],(t,t))' "$1" "$2"; }
inode_of() { stat -c %i "$1" 2>/dev/null || stat -f %i "$1"; }
mtime_of() { stat -c %Y "$1" 2>/dev/null || stat -f %m "$1"; }
# test/bridge-observe.test.sh - the one adapter: it measures, asks lib/bridge.sh, prints one
# fifteen-field line, and WRITES NOTHING. Spec §1; plan v6 Task 4.
#
# EVERY FACT IS A FIXTURE. tmux, pgrep, ps and id are shims over files; /proc is a directory
# with stat, environ, uptime and boot_id; the bridge files are written by hand. The clock is
# two overrides (wall and uptime). Nothing here touches the machine.
#
# THE CLAIMS ARE NUMBERED AS IN THE PLAN. Each names the field it reads, because the line is
# the contract and a consumer reads it by position.
set -u
here="$(CDPATH= cd -- "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OBS="${OBS_OVERRIDE:-$here/linux/bridge-observe.sh}"   # OBS_OVERRIDE: a mutated copy, for the mutation runs
pass=0; fail=0
ok()  { pass=$((pass+1)); printf '  ok   %s\n' "$1"; }
bad() { fail=$((fail+1)); printf '  FAIL %s\n     %s\n' "$1" "${2:-}"; }
is()  { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "wanted '$3', got '$2'"; fi; }
has() { case "$2" in *"$3"*) ok "$1" ;; *) bad "$1" "missing '$3' in: $2" ;; esac; }
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
US="$(printf '\037')"
HOMEDIR="$T/home"; ROOT="$T/estate"; LIBS="$T/libs"; BIN="$T/bin"; PROC="$T/proc"; SD="$T/state"
mkdir -p "$HOMEDIR/.claude/sessions" "$LIBS" "$BIN" "$SD" "$PROC/sys/kernel/random" \
         "$ROOT/estate" "$ROOT/sessions.d" "$ROOT/entities.d" "$ROOT/accounts.d" "$ROOT/principals.d" "$ROOT/logins.d" "$ROOT/projects.d" "$ROOT/mcp.d"
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
mkdir -p "$T/memory"
printf 'NAME="Alpha"\nMEMBERS="a"\n' > "$ROOT/entities.d/alpha.conf"
printf 'NAME="Person A"\n' > "$ROOT/principals.d/p.conf"
printf 'NAME="Person Q"\n' > "$ROOT/principals.d/q.conf"
printf 'PRINCIPAL="p"\nHOST="h1"\nUSERNAME="a"\n' > "$ROOT/accounts.d/a-h1.conf"
printf 'PRINCIPAL="p"\nHOST="h1"\nUSERNAME="b"\n' > "$ROOT/accounts.d/b-h1.conf"
printf 'PRINCIPAL="q"\nACCOUNT="q@example.test"\nPROVIDER="claude-team"\nCONFIG_DIR="~/.claude-logins/q"\nLEGAL_OWNER="Q"\n' > "$ROOT/logins.d/q-login.conf"
cp "$here/lib/registry.sh" "$here/lib/bridge.sh" "$LIBS/"
ID="s-0000000000000001"; ID2="s-0000000000000002"
row_full() { # <id> [KEY="value" ...] - an override REPLACES the default line: the row parser refuses a duplicate key
  local id="$1" f l k; shift; f="$ROOT/sessions.d/$id.conf"
  printf 'OWNER="a"\nHOST="h1"\nDOMAIN="alpha"\nREPO_PATH="%s/Projects/repo"\nID="%s"\nACCOUNT="a-h1"\nRC_LABEL="Fixture: x"\n' "$HOMEDIR" "$id" > "$f"
  for l in "$@"; do k="${l%%=*}"; grep -v "^$k=" "$f" > "$f.n"; mv "$f.n" "$f"; printf '%s\n' "$l" >> "$f"; done
}
# ---- shims -------------------------------------------------------------------------------------
PROCTAB="$T/proctab"; PANES_ALL="$T/panes-all"; PANES_SESS="$T/panes-sess"; HAS_SESSION="$T/has-session"; TUPLE="$T/tuple"; PANEMAP="$T/panemap"
export PROCTAB PANES_ALL PANES_SESS HAS_SESSION TUPLE PANEMAP
export TMUX_LOG="$T/tmux.log" PGREP_LOG="$T/pgrep.log" LABEL_LOG="$T/label.log" PROC_TOUCH="$T/proc-touch.log"
cat > "$BIN/tmux" <<'EOF'
#!/bin/bash
printf '%s\n' "$*" >> "$TMUX_LOG"
argv=("$@"); [ "${argv[0]:-}" = "-S" ] && argv=("${argv[@]:2}")
case "${argv[0]:-}" in
  has-session) [ -f "$HAS_SESSION" ] ;;
  list-sessions) [ -n "${T_NO_SERVER:-}" ] && { echo "no server running on $2" >&2; exit 1; }
              # tmux 3.4, MEASURED: session formats expand here and NOT through display-message -t "=name".
              [ -f "$HAS_SESSION" ] && cat "$TUPLE"; exit 0 ;;
  list-panes) [ -n "${T_NO_SERVER:-}" ] && { echo "no server running on $2" >&2; exit 1; }
              for a in "${argv[@]}"; do [ "$a" = "-a" ] && { [ -n "${T_PANES_ALL_FAIL:-}" ] && { echo "lost server" >&2; exit 1; }; cat "$PANES_ALL"; exit 0; }; done
              [ -n "${T_PANES_SESS_FAIL:-}" ] && { echo "lost server" >&2; exit 1; }; [ -f "$HAS_SESSION" ] && cat "$PANES_SESS"; exit 0 ;;
  display-message)
    tgt=""; prev=""; fmt=""; for a in "${argv[@]}"; do [ "$prev" = "-t" ] && tgt="$a"; prev="$a"; fmt="$a"; done
    case "$fmt" in
      '#{session_id}:#{session_created}') : ;;   # tmux 3.4 answers NOTHING here (measured on the live host)
      '#{pane_pid}') awk -v t="$tgt" '$1==t {print $2}' "$PANEMAP" ;;
    esac; exit 0 ;;
  *) exit 0 ;;
esac
EOF
cat > "$BIN/pgrep" <<'EOF'
#!/bin/bash
pat=""; prev=""; for a in "$@"; do [ "$prev" = "-f" ] && pat="$a"; prev="$a"; done
printf '%s\n' "$pat" >> "$PGREP_LOG"; case "$pat" in *remote-control*) echo LABEL >> "$LABEL_LOG";; esac; [ -n "${T_PGREP_FAIL:-}" ] && exit 2
found=0; while read -r pid ppid uid argv; do case "$pid" in ""|\#*) continue;; esac
  printf '%s' "$argv" | grep -Eq -- "$pat" && { printf '%s\n' "$pid"; found=1; }; done < "$PROCTAB"; [ "$found" = 1 ]
EOF
cat > "$BIN/ps" <<'EOF'
#!/bin/bash
pid=""; prev=""; want=""; for a in "$@"; do [ "$prev" = "-p" ] && pid="$a"; [ "$prev" = "-o" ] && want="$a"; prev="$a"; done
while read -r p pp u rest; do case "$p" in ""|\#*) continue;; esac
  [ "$p" = "$pid" ] && { case "$want" in uid=) printf ' %s\n' "$u";; *) printf ' %s\n' "$pp";; esac; exit 0; }; done < "$PROCTAB"; exit 1
EOF
cat > "$BIN/id" <<'EOF'
#!/bin/bash
case "$*" in "-u a") echo "${FIX_UID_A:-1001}";; "-u b") echo 1002;; "-u") echo "${FIX_OBS_UID:-1001}";; "-un") echo a;; *) echo 1001;; esac
EOF
chmod 755 "$BIN"/*
# ---- fixture helpers ---------------------------------------------------------------------------
printf 'boot-1\n' > "$PROC/sys/kernel/random/boot_id"
proc() { # <pid> <ticks> [state] [environ-line]
  mkdir -p "$PROC/$1"; printf '%s (claude) %s 1 %s %s 0 -1 0 0 0 0 0 0 0 0 0 20 0 1 0 %s 0 0 0\n' "$1" "${3:-S}" "$1" "$1" "$2" > "$PROC/$1/stat"
  printf '%s\0HOME=/x\0' "${4:-NOTHING=1}" > "$PROC/$1/environ"
}
bridge() { # <pid> <pane> <name> [startedAt] [procStart]
  printf '{"pid":%s,"procStart":%s,"tmux":"%s","name":"%s","nameSince":1789000000000,"sessionId":"thread-%s","startedAt":%s,"status":"idle"}\n' \
    "$1" "${5:-$1}" "$2" "$3" "$1" "${4:-1789000000000}" > "$HOMEDIR/.claude/sessions/$1.json"
}
gen() { bash -c ". '$LIBS/bridge.sh'; bridge_gen_write '$SD' '$ID' $*"; }
LINE=""; OBS_RC=0
obs() { # [--bootstrap|--all] <id>  -> LINE
  : > "$LABEL_LOG"; : > "$PGREP_LOG"
  LINE="$(env HOME="$HOMEDIR" STEWARD_ESTATE_ROOT="$ROOT" STEWARD_REGISTRY_LIB="$LIBS/registry.sh" STEWARD_BRIDGE_LIB="$LIBS/bridge.sh" \
    STEWARD_STATE_DIR="$SD" STEWARD_TMUX_SOCKET="$T/fixture.sock" BRIDGE_PROC_ROOT="$PROC" STEWARD_SELF_HOST=h1 \
    ${NOW_MS:+STEWARD_NOW_MS=$NOW_MS} ${NOW_UP:+STEWARD_NOW_UPTIME_MS=$NOW_UP} STEWARD_BRIDGE_GRACE_MS=600000 \
    T_NO_SERVER="${T_NO_SERVER:-}" T_PANES_ALL_FAIL="${T_PANES_ALL_FAIL:-}" T_PANES_SESS_FAIL="${T_PANES_SESS_FAIL:-}" T_PGREP_FAIL="${T_PGREP_FAIL:-}" \
    PATH="$BIN:$PATH" ${OBS_TIMEOUT:+timeout $OBS_TIMEOUT} bash "$OBS" "$@" 2>"$T/obs.err")"; OBS_RC=$?   # NOW_MS/NOW_UP empty = the observer reads the clock itself
}
f() { printf '%s\n' "$LINE" | head -1 | cut -d "$US" -f "$1"; }
nf() { printf '%s\n' "$LINE" | head -1 | awk -F "$US" '{print NF}'; }
reset() {
  rm -rf "$PROC"/[0-9]* "$HOMEDIR/.claude/sessions"/* "$SD"/* "$ROOT/sessions.d"/*; : > "$PROCTAB"; : > "$PANES_ALL"; : > "$PANES_SESS"; : > "$PANEMAP"; : > "$TUPLE"; rm -f "$HAS_SESSION"
  NOW_MS=1789000100000; NOW_UP=500000; unset FIX_UID_A FIX_OBS_UID T_NO_SERVER T_PANES_ALL_FAIL T_PANES_SESS_FAIL T_PGREP_FAIL; row_full "$ID"
  printf '500000.00 400.00\n' > "$PROC/uptime"
}
live_managed() { # standard managed setup: pane 4242 (shell) -> 4243 (claude), bridge for 4243, generation knows birth
  touch "$HAS_SESSION"; printf '$7:1789000000\n' > "$TUPLE"
  printf '4242 1 1001 -bash\n4243 4242 1001 /home/a/.local/bin/claude --remote-control "Whatever"\n' > "$PROCTAB"
  printf '4242\n' > "$PANES_SESS"; printf '4242\n' > "$PANES_ALL"; printf '%s:@0.%%0 4242\n' "$ID" > "$PANEMAP"
  proc 4243 111; bridge 4243 "$ID:@0.%0" "Alpha→Thing"
  gen pid=4243 birth=boot-1:111 procStart=4243 uid=1001 census=1
}
gen_snapshot() { cat "$SD/$ID.generation" 2>/dev/null | sort; }

echo "== 1. managed: known birth in stored pane =="
reset; live_managed; before="$(gen_snapshot)"; obs "$ID"
is "1a answer" "$(f 2)" "identified:managed"; is "1b fifteen fields" "$(nf)" "15"
is "1c pid" "$(f 3)" "4243"; is "1d birth" "$(f 4)" "boot-1:111"; is "1e pane" "$(f 5)" "$ID:@0.%0"; is "1f name" "$(f 6)" "Alpha→Thing"
is "1g procStart" "$(f 11)" "4243"; is "1h sessionId" "$(f 12)" "thread-4243"; case "$(f 13)" in ''|*[!0-9]*) bad "1i mtime numeric" "$(f 13)";; *) ok "1i mtime numeric";; esac
is "1j inode is the candidate file's inode (F2)" "$(f 15)" "$(inode_of "$HOMEDIR/.claude/sessions/4243.json")"
is "1k the observer wrote NOTHING to the generation" "$(gen_snapshot)" "$before"
is "1l no label pgrep" "$(grep -c . "$LABEL_LOG")" "0"

echo "== 2. fresh pid, no launch -> unknown =="
reset; live_managed; rm -f "$SD"/*; gen census=1; obs "$ID"; is "2a fresh pid, census done, no launch -> unknown" "$(f 2)" "unknown"

echo "== 3-8. the launch claim: open launch + window + nonce + descent from the launch pane incarnation + fresh file =="
claim_setup() { # <environ-line> <pane-descends 1|0> <lpane-birth-ok 1|0>
  reset; touch "$HAS_SESSION"; printf '$7:1789000000\n' > "$TUPLE"
  printf '4242 1 1001 -bash\n4243 4242 1001 claude\n4300 1 1001 -bash\n' > "$PROCTAB"
  printf '4242\n4300\n' > "$PANES_SESS"; printf '4242\n4300\n' > "$PANES_ALL"
  if [ "$2" = 1 ]; then printf '%s:@0.%%0 4242\n' "$ID" > "$PANEMAP"; else printf '%s:@0.%%0 4300\n' "$ID" > "$PANEMAP"; printf '4243 4300 1001 claude\n4242 1 1001 -bash\n' > "$PROCTAB"; fi
  proc 4242 100; proc 4243 111 S "$1"
  bridge 4243 "$ID:@0.%0" "Fresh" 1789000050000
  lb="boot-1:100"; [ "$3" = 1 ] || lb="boot-1:999"
  gen pid= birth= launch_ms=1789000000000 launch_uptime_ms=400000 launch_boot_id=boot-1 launch_nonce=0123456789abcdef0123456789abcdef launch_pane_pid=4242 launch_pane_birth="$lb" launch_inodes="" census=1
}
claim_setup "STEWARD_LAUNCH_NONCE=0123456789abcdef0123456789abcdef" 1 1; obs "$ID"; is "3 open launch + nonce + descent + fresh -> managed" "$(f 2)" "identified:managed"
claim_setup "STEWARD_LAUNCH_NONCE=zzz" 1 1;    obs "$ID"; is "4 wrong nonce -> unknown" "$(f 2)" "unknown"
claim_setup "STEWARD_LAUNCH_NONCE=0123456789abcdef0123456789abcdef" 0 1; obs "$ID"; is "5 not a descendant of the launch pane -> unknown" "$(f 2)" "unknown"
claim_setup "STEWARD_LAUNCH_NONCE=0123456789abcdef0123456789abcdef" 1 0; obs "$ID"; is "6 launch pane birth differs (pane recreated) -> unknown" "$(f 2)" "unknown"
# THE INODE ONLY DECIDES INSIDE THE ONE-SECOND SLACK. An mtime far older than the launch is refused by
# the mtime rule alone (claim 8); the inode matters for a file whose mtime is within the slack the
# supervisor's seconds-granular clock needs (launch - 1000 <= mtime < launch). Measured: the first
# version of this claim used a 2020 mtime and a mutation that dropped the inode clause survived.
claim_setup "STEWARD_LAUNCH_NONCE=0123456789abcdef0123456789abcdef" 1 1; ino="$(inode_of "$HOMEDIR/.claude/sessions/4243.json")"; gen launch_inodes="$ino"; set_mtime "$HOMEDIR/.claude/sessions/4243.json" 1788999999; obs "$ID"
is "7a inode in snapshot AND mtime just before launch (inside the slack) -> unknown (pre-existing)" "$(f 2)" "unknown"
claim_setup "STEWARD_LAUNCH_NONCE=0123456789abcdef0123456789abcdef" 1 1; set_mtime "$HOMEDIR/.claude/sessions/4243.json" 1788999999; obs "$ID"
is "7c inode NOT in snapshot, mtime inside the slack -> managed (the slack is honoured)" "$(f 2)" "identified:managed"
claim_setup "STEWARD_LAUNCH_NONCE=0123456789abcdef0123456789abcdef" 1 1; ino="$(inode_of "$HOMEDIR/.claude/sessions/4243.json")"; gen launch_inodes="$ino"; obs "$ID"
is "7b inode in snapshot but mtime fresh -> managed (inode reuse is normal)" "$(f 2)" "identified:managed"
claim_setup "STEWARD_LAUNCH_NONCE=0123456789abcdef0123456789abcdef" 1 1; set_mtime "$HOMEDIR/.claude/sessions/4243.json" 1577836800; obs "$ID"; is "8 mtime older than launch -> unknown" "$(f 2)" "unknown"

echo "== 9-12. clocks =="
claim_setup "STEWARD_LAUNCH_NONCE=0123456789abcdef0123456789abcdef" 1 1; NOW_UP=1100000; obs "$ID"; is "9 window elapsed -> unknown" "$(f 2)" "unknown"
claim_setup "STEWARD_LAUNCH_NONCE=0123456789abcdef0123456789abcdef" 1 1; NOW_MS=1788999999000; obs "$ID"; is "10 wall stepped back -> discontinuity" "$(f 2)" "unknown"; has "10b reason" "$(f 9)" "launch-clock-discontinuity"
claim_setup "STEWARD_LAUNCH_NONCE=0123456789abcdef0123456789abcdef" 1 1; NOW_UP=300000; obs "$ID"; has "11 uptime went back -> discontinuity" "$(f 9)" "launch-clock-discontinuity"
claim_setup "STEWARD_LAUNCH_NONCE=0123456789abcdef0123456789abcdef" 1 1; gen launch_boot_id=boot-OLD; obs "$ID"; has "12 boot id differs -> discontinuity" "$(f 9)" "launch-clock-discontinuity"

echo "== 13-15. moved, orphan, stale =="
reset; live_managed; printf '4300 1 1001 -bash\n4243 4300 1001 claude\n4242 1 1001 -bash\n' > "$PROCTAB"; printf '4242\n4300\n' > "$PANES_ALL"; obs "$ID"
is "13 live under another pane -> moved" "$(f 2)" "identified:moved"
reset; live_managed; rm -f "$HAS_SESSION"; : > "$PANES_ALL"; : > "$PANES_SESS"; printf '4243 1 1001 claude\n' > "$PROCTAB"; obs "$ID"
is "14 live under no pane -> orphan" "$(f 2)" "identified:orphan"
reset; bridge 4600 "$ID:@0.%0" "Dead" 1789000000000 4600; gen pid=4600 birth=boot-1:444 procStart=4600 census=1; gen pid= birth= procStart=; obs "$ID"
is "15a stale (pid:procStart in history), tmux absent -> no-process" "$(f 2)" "no-process"; has "15b classes say stale" "$(f 9)" "stale"

echo "== 16-17. unknown answers carry NO candidate fields =="
reset; live_managed; proc 4244 112; bridge 4244 "$ID:@1.%1" "Second"; printf '%s:@1.%%1 4242\n' "$ID" >> "$PANEMAP"; printf '4244 4242 1001 claude\n' >> "$PROCTAB"; gen pid=4244 birth=boot-1:112 procStart=4244; obs "$ID"
is "16a two live -> unknown" "$(f 2)" "unknown"; is "16b pid field empty" "$(f 3)" ""; is "16c name field empty" "$(f 6)" ""; is "16d inode field empty" "$(f 15)" ""
reset; live_managed; printf '{"pid":' > "$HOMEDIR/.claude/sessions/4299.json"; obs "$ID"
is "17a poison + live -> unknown" "$(f 2)" "unknown"; is "17b pid field empty" "$(f 3)" ""

echo "== 18. the veto is THIS session's panes, not the socket =="
reset; live_managed; rm -f "$PROC/4243/stat"; rm -f "$HOMEDIR/.claude/sessions/4243.json"; gen pid=4243 birth=boot-1:111 stop_receipt=
printf '4242 1 1001 -bash\n4300 1 1001 -bash\n4301 4300 1001 claude\n' > "$PROCTAB"; printf '4242\n' > "$PANES_SESS"; printf '4242\n4300\n' > "$PANES_ALL"; obs "$ID"
is "18a unrelated live claude under another session -> no-process" "$(f 2)" "no-process"
printf '4242\n4300\n' > "$PANES_SESS"; obs "$ID"; is "18b the same claude under a pane of THIS id -> wait-veto" "$(f 2)" "wait-veto"

echo "== 19. launch child: the pane shell is tmux, not the child =="
reset; touch "$HAS_SESSION"; printf '$7:1\n' > "$TUPLE"; printf '4242 1 1001 -bash\n' > "$PROCTAB"; printf '4242\n' > "$PANES_SESS"; printf '4242\n' > "$PANES_ALL"; proc 4242 100
gen pid= birth= launch_ms=1789000000000 launch_uptime_ms=400000 launch_boot_id=boot-1 launch_nonce=0123456789abcdef0123456789abcdef launch_pane_pid=4242 launch_pane_birth=boot-1:100 census=1
NOW_UP=1100000; obs "$ID"; is "19a past window, pane shell alive, no nonce child -> child 0" "$(f 10)" "0"; is "19b gen_state gone-noreceipt" "$(f 8)" "gone-noreceipt"
printf '4243 4242 1001 claude\n' >> "$PROCTAB"; proc 4243 111 S "STEWARD_LAUNCH_NONCE=0123456789abcdef0123456789abcdef"; obs "$ID"
is "19c nonce child alive, not registered -> child 1" "$(f 10)" "1"; is "19d gen_state alive" "$(f 8)" "alive"; is "19e answer unknown" "$(f 2)" "unknown"

echo "== 20. H6: a generation pid WITHOUT a birth is invalid state, never gone (a spawn would follow) =="
reset; gen pid=4700 birth= census=1; obs "$ID"; is "20a pid without birth -> unknown" "$(f 2)" "unknown"; has "20b reason generation-invalid" "$(f 9)" "generation-invalid"
reset; live_managed; rm -f "$HOMEDIR/.claude/sessions/4243.json"; gen pid=4243 birth=; obs "$ID"; is "20c LIVE pid, empty birth, no bridge -> unknown, not no-process" "$(f 2)" "unknown"
reset; live_managed; gen launch_pane_pid=4242 launch_pane_birth=; obs "$ID"; has "20d launch_pane_pid without its birth -> generation-invalid" "$(f 9)" "generation-invalid"
reset; live_managed; gen launch_ms=1789000000000 launch_uptime_ms=400000 launch_boot_id=boot-1 launch_nonce='abc123'; obs "$ID"; has "20e a stored nonce that is not 32 lowercase hex -> generation-invalid" "$(f 9)" "generation-invalid"
reset; live_managed; gen pid=4243 birth=boot-1:abc; obs "$ID"; has "20f a birth whose ticks are not digits is not a birth" "$(f 9)" "generation-invalid"

echo "== 21-24. refusals =="
reset; row_full "$ID2" 'OWNER="b"' 'ACCOUNT="b-h1"'; obs --all
is "21 --all: a row owned by another uid is uninspectable" "$(printf '%s\n' "$LINE" | grep "^$ID2$US" | cut -d "$US" -f 2)" "uninspectable"
is "21b --all prints THIS row too" "$(printf '%s\n' "$LINE" | grep -c "^$ID$US")" "1"
reset; printf 'garbage\n' > "$ROOT/sessions.d/$ID2.conf"; obs --all
is "21c --all: a row that does not load is REPORTED, not skipped" "$(printf '%s\n' "$LINE" | grep "^$ID2$US" | cut -d "$US" -f 9)" "row-does-not-load"
reset; chmod 000 "$HOMEDIR/.claude/sessions"; obs "$ID"; chmod 755 "$HOMEDIR/.claude/sessions"; has "22 sessions/ unreadable" "$(f 9)" "sessions-dir-unreadable"
reset; row_full "$ID" 'LOGIN="q-login"'; obs "$ID"; has "23 login principal != account principal" "$(f 9)" "login-account-mismatch"
reset; grep -v '^ACCOUNT=' "$ROOT/sessions.d/$ID.conf" > "$T/r" && mv "$T/r" "$ROOT/sessions.d/$ID.conf"; obs "$ID"; has "24 no ACCOUNT -> account-missing" "$(f 9)" "account-missing"

echo "== 25. bootstrap: the census sees what the plain call refuses =="
reset; live_managed; rm -f "$SD"/*; obs "$ID"; is "25a plain, no generation -> unknown" "$(f 2)" "unknown"
# MEASURED IN PRODUCTION 2026-09-12 (basement, Jon's home): ten live rows without a generation answered
# unknown/unclassifiable and read as a broken observer; the difference was visible only in the generation
# directory. A live candidate with NO generation and no census is an UNCENSUSED row, and the reason says so.
has "25a2 the reason names the cause: uncensused, run the census" "$(f 9)" "uncensused"
obs --bootstrap "$ID"; is "25b bootstrap -> managed" "$(f 2)" "identified:managed"; is "25c gen_state says bootstrap" "$(f 8)" "bootstrap"
reset; rm -f "$SD"/*; obs --bootstrap "$ID"; is "25d bootstrap, empty row -> no-process" "$(f 2)" "no-process"

echo "== 26. the tmux tuple =="
reset; live_managed; obs "$ID"; is "26a tuple present" "$(f 14)" '$7:1789000000'
reset; obs "$ID"; is "26b tuple empty when tmux absent" "$(f 14)" ""

echo "== 27. runtimes =="
reset; row_full "$ID" 'RUNTIME="opencode"' 'MODEL="openai/gpt-5"' 'OPENCODE_VERSION="1.0.0"' 'OPENCODE_PORT="4096"' 'AUTO_APPROVE="false"' "CLAUDE_MEMORY_ROOT=\"$T/memory\""; obs "$ID"; is "27a opencode -> not-applicable" "$(f 2)" "not-applicable"; is "27b no pgrep at all" "$(grep -c . "$PGREP_LOG")" "0"
reset; live_managed; proc 4243 111 Z; obs "$ID"; is "27c a zombie candidate is not live -> stale (in history) -> no-process/wait" "$(f 9)" "stale"

echo "== 29. G1: not-applicable reads NO clock and NO /proc - the refusal comes before them =="
# A FIFO WITH NO WRITER IS THE RECORDER: a read of it blocks. If the observer read uptime or the boot id
# before the runtime gate, this claim would hang and the timeout would report rc 124.
reset; row_full "$ID" 'RUNTIME="opencode"' 'MODEL="openai/gpt-5"' 'OPENCODE_VERSION="1.0.0"' 'OPENCODE_PORT="4096"' 'AUTO_APPROVE="false"' "CLAUDE_MEMORY_ROOT=\"$T/memory\""
rm -f "$PROC/uptime" "$PROC/sys/kernel/random/boot_id"; mkfifo "$PROC/uptime" "$PROC/sys/kernel/random/boot_id"
OBS_TIMEOUT=3 obs "$ID"; is "29a not-applicable answered without touching the FIFOs (no timeout)" "$OBS_RC" "0"; is "29b answer" "$(f 2)" "not-applicable"
rm -f "$PROC/uptime" "$PROC/sys/kernel/random/boot_id"; printf 'boot-1\n' > "$PROC/sys/kernel/random/boot_id"; printf '500000.00 400.00\n' > "$PROC/uptime"

echo "== 30-32. G2: a census that cannot be read is unknown WITH its reason, never an empty set =="
reset; live_managed; T_PANES_ALL_FAIL=1 obs "$ID"; is "30a list-panes -a fails with a known managed process -> unknown (never orphan)" "$(f 2)" "unknown"; has "30b reason" "$(f 9)" "tmux-panes-unreadable"
reset; live_managed; T_PANES_SESS_FAIL=1 obs "$ID"; is "31a has-session yes but the session's panes unreadable -> unknown (never no-process)" "$(f 2)" "unknown"; has "31b reason" "$(f 9)" "tmux-session-panes-unreadable"
reset; live_managed; rm -f "$PROC/4243/stat" "$HOMEDIR/.claude/sessions/4243.json"; gen pid=4243 birth=boot-1:111 stop_receipt=; printf '4242 1 1001 -bash\n4243 4242 1001 claude\n' > "$PROCTAB"
T_PGREP_FAIL=1 obs "$ID"; is "32a pgrep rc 2 with a live veto -> unknown (never no-process)" "$(f 2)" "unknown"; has "32b reason" "$(f 9)" "pgrep-failed"
reset; gen pid=4600 birth=boot-1:444 procStart=4600 census=1; gen pid= birth= procStart=; bridge 4600 "$ID:@0.%0" "Dead" 1789000000000 4600
T_NO_SERVER=1 obs "$ID"; is "32c tmux's own 'no server running' is an ABSENCE: the stale row is still no-process" "$(f 2)" "no-process"

echo "== 33-34. G3: a launch is whole, and the launch child descends from the pane INCARNATION =="
claim_setup "STEWARD_LAUNCH_NONCE=0123456789abcdef0123456789abcdef" 1 1; gen launch_boot_id=; obs "$ID"; is "33a empty launch_boot_id -> unknown" "$(f 2)" "unknown"; has "33b reason discontinuity" "$(f 9)" "launch-clock-discontinuity"
reset; touch "$HAS_SESSION"; printf '$7:1\n' > "$TUPLE"; printf '4242 1 1001 -bash\n4243 4242 1001 claude\n' > "$PROCTAB"; printf '4242\n' > "$PANES_SESS"; printf '4242\n' > "$PANES_ALL"
proc 4242 100; proc 4243 111 S "STEWARD_LAUNCH_NONCE=0123456789abcdef0123456789abcdef"
gen pid= birth= launch_ms=1789000000000 launch_uptime_ms=400000 launch_boot_id=boot-1 launch_nonce=0123456789abcdef0123456789abcdef launch_pane_pid=4242 launch_pane_birth=boot-1:999 census=1
NOW_UP=1100000; obs "$ID"; is "34a past window, nonce child under a REUSED pane pid (birth differs) -> child 0" "$(f 10)" "0"; is "34b gen_state gone-noreceipt, not alive" "$(f 8)" "gone-noreceipt"
gen launch_pane_birth=boot-1:100; obs "$ID"; is "34c same setup with the recorded incarnation -> child 1" "$(f 10)" "1"

echo "== 35. G4: state text is validated before arithmetic =="
reset; live_managed; gen launch_ms=abc launch_uptime_ms=400000 launch_boot_id=boot-1; obs "$ID"; is "35a launch_ms=abc -> unknown" "$(f 2)" "unknown"; has "35b reason generation-invalid" "$(f 9)" "generation-invalid"
reset; live_managed; gen pid=abc; obs "$ID"; has "35c pid=abc -> generation-invalid" "$(f 9)" "generation-invalid"
reset; live_managed; NOW_MS=abc obs "$ID"; has "35d STEWARD_NOW_MS=abc -> clock-invalid" "$(f 9)" "clock-invalid"; is "35e and unknown" "$(f 2)" "unknown"
reset; live_managed; rm -f "$PROC/uptime"; NOW_UP="" obs "$ID"; has "35f unreadable uptime -> clock-invalid" "$(f 9)" "clock-invalid"; printf '500000.00 400.00\n' > "$PROC/uptime"
reset; live_managed; gen launch_ms=1789000000000 launch_uptime_ms=400000 launch_boot_id=boot-1 launch_pane_pid=4242 launch_pane_birth=boot-1:100; obs "$ID"
is "35g a WHOLE launch beside a managed process still reads managed (validation does not refuse valid state)" "$(f 2)" "identified:managed"
is "35h no diagnostics on stderr across the invalid-state claims" "$(grep -c 'syntax error\|integer expression\|unbound variable' "$T/obs.err")" "0"

echo "== 36. K4: a live candidate whose procStart contradicts the generation is not identified =="
reset; live_managed; gen procStart=4243; bridge 4243 "$ID:@0.%0" "Alpha→Thing" 1789000000000 9999; obs "$ID"
is "36a same pid+birth, vendor procStart 9999 vs recorded 4243 -> unknown" "$(f 2)" "unknown"; has "36b unclassifiable" "$(f 9)" "unclassifiable"
hasnt "36b2 a row WITH a generation is never called uncensused" "$(f 9)" "uncensused"
reset; live_managed; gen procStart=; bridge 4243 "$ID:@0.%0" "Alpha→Thing" 1789000000000 9999; obs "$ID"
is "36c a generation without a procStart (first bind) still identifies" "$(f 2)" "identified:managed"

echo "== 28. never a label =="
is "28 LABEL_LOG empty across the suite" "$(cat "$T/label.log" 2>/dev/null | wc -l | tr -d ' ')" "0"

printf '\n%d passed, %d failed\n' "$pass" "$fail"; [ "$fail" -eq 0 ]
