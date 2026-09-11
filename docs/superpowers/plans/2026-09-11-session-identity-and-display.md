# Session Identity and Display Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Supervision identifies a session by the vendor's bridge file (ID ↔ pid+birth token ↔ pane) with launch provenance it can prove, never by its Remote Control label; the label is rendered from the register and renamed through the existing `/rename` cycle bound to the managed pane.

**Architecture:** `lib/bridge.sh` holds pure decision functions (built: Tasks 1–3). `linux/bridge-observe.sh` is the **one, read-only adapter**: it measures and prints one line per row in a fixed vocabulary and writes nothing. **Only the supervisor mutates state**, and only from a line it read this round, behind a keyed two-round gate. Watch, liveness-host and the census consume the same line. `RC_LABEL` survives only as a legacy override until the last row is migrated.

**Tech Stack:** bash 3.2-compatible shell, jq 1.7, tmux, Linux `/proc`; Node `node:test` for `watch/`.

**Spec:** `docs/superpowers/specs/2026-09-11-session-identity-and-display-design.md` (38c719c).

**Revision:** fourth version, after the advisor's third pass on 38000ba (12 findings, cited *C1…C12*). **Done: Tasks 1–3** (`55e677a`, `d14db58`, `a8d33f1`, `9eaed35`, `cde906e`). **Tasks 4–7 revised and awaiting the fourth pass before execution.** Tasks 8–12 are outlines.

## Global Constraints

- Never read or log `bridgeSessionId` or `messagingSocketPath`. jq selects fields by name.
- **The adapter never writes.** Every mutation — generation, suspect keys, grace — is the supervisor's, made from a line it read this round.
- Every destructive or typing action requires the **same keyed observation** on two consecutive rounds, where the key names the **intended action and its target** (C6); a different key resets. Destruction also passes the supervisor's **existing** human-client/debris veto (C5).
- A live process is ours only when the generation knows its birth **or** it carries this launch's nonce inside the launch window. **The trust boundary is the unix uid:** same-uid code can read the generation and copy the nonce; the nonce closes *accidental* replacement (a Claude typed into the pane), not adversarial same-uid code. Measured 2026-09-11: `env STEWARD_LAUNCH_NONCE=… claude …; exec bash` gives the nonce to `claude` and **not** to the fallback shell (C8).
- **Equality of birth tokens requires both sides non-empty** (C3). `lib/bridge.sh`'s matchers already refuse an empty key; the adapter's own comparisons must too.
- Grace is a **deadline on a monotonic clock** (`/proc/uptime`), not on wall time; wall time is used only to compare the vendor's `startedAt` with our launch, and a discontinuity on either clock is `unknown`, never `alive` (C9).
- Config dir resolves through `registry_login_config_dir "$LOGIN" "<owner>"`; the login row must pass `registry_login_principal_gate` against the row's `ACCOUNT`. Expected uid is the **row owner's**. A row without `ACCOUNT` is not inferred from `OWNER`: it is `unknown account-missing`, and **ACCOUNT migration is a named P0 prerequisite** (C11).
- Fields travel with the **unit separator** (`$(printf '\037')`); an empty value travels **empty** (a sentinel collided with a real `-`); consumers read with `IFS="$US"`.
- No label match decides anything after Task 5; test `pgrep` shims fail loudly on `remote-control`.
- **No literal tab bytes, and no backslash-u escapes in any file written through a JSON-carrying tool**; jq uses `explode`/`implode`. Tests never touch the machine.
- Commit after every green step with the estate author: `git -c user.name="Jon Kindell" -c user.email="jon+butler@varvet.com" commit …` ending `Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>` / `Claude-Session: https://claude.ai/code/session_01RMVoAh7XJUuje1PCq3tEQX`. Branch `session-identity-display`; merge is butler's.

---

## File Structure

| file | responsibility |
|---|---|
| `lib/bridge.sh` (built) | candidates with in-band poison and US framing; OS birth token; `bridge_is_descendant`; classification; four-way answer; generation with dead-file history; keyed suspect |
| `linux/bridge-observe.sh` (new) | **read-only adapter**: `<id>`, `--all`, `--bootstrap <id>`; **fourteen** US fields; never writes |
| `linux/bridge-kill.sh` (new) | atomic check-and-signal: reads the OS birth and sends the signal in one scoped step, refusing mismatch (C12); used by the supervisor and watch |
| `linux/session-supervisor-linux.sh` (modify) | reads the line; owns every write; claim persisted before spawn; keyed two-round gate incl. action+target; existing veto kept |
| `linux/deploy-manifest` (modify) | ships `lib/bridge.sh`, `linux/bridge-observe.sh`, `linux/bridge-kill.sh`, `linux/bridge-census.sh` |
| `watch/bin/registry-dump`, `watch/lib.mjs`, `watch/session-watch.mjs`, `watch/restart-session.mjs` (modify) | consume the line; remote socket on the remote; kill via `bridge-kill.sh` |
| `linux/liveness-host.sh` (modify) | `agent` from the line |
| `lib/registry.sh`, `bin/steward`, `linux/hub/enroll` (modify) | display refusal, gates, verbs (later tasks) |
| `linux/bridge-census.sh` (new) | P0 via `--bootstrap` |

---

### Tasks 1–3 — DONE (as built)

- `bridge_candidates <id> <dir>` → `ok US path US pid US procStart US tmux US name US nameSince US sessionId US startedAt US mtime_ms` or `!unclassifiable US path US reason`; empty values travel empty; poison reasons `symlink not-regular size json notobject types control-char filename-pid stat path-control`. `bridge_os_birth <pid>` → `boot_id:ticks`. `bridge_is_descendant <pid> <ancestor>`. (31 assertions.)
- `bridge_classify_candidate <alive> <uid_ok> <birth_known> <launch_claim> <stored> <any> <dead_match>` → `live:managed|live:moved|live:orphan|stale|unclassifiable`. `bridge_answer <classes> <gen_state> <tmux_present> <veto> <census>` → `identified:managed|identified:orphan|identified:moved|no-process|unknown|wait-veto|grace`. (30 assertions.)
- `bridge_gen_path/get/write` (atomic; unknown key refuses the whole write; history `pid:procStart:birth` bounded 8). `bridge_gen_matches_live <sd> <id> <pid> <birth>` and `bridge_gen_matches_dead <sd> <id> <pid> <procStart>` — **both refuse an empty key**. `bridge_suspect_key <arg>…` joins every argument (`-` for empty); `bridge_suspect_confirmed <file> <key>` → rc 0 only when the file already held exactly that key, and always rewrites it. (32 assertions.)

---

### Task 4: `linux/bridge-observe.sh` — read-only, fourteen fields, `--bootstrap`

Spec §1; C1, C2, C3, C6, C9, C11.

**Files:** Create `linux/bridge-observe.sh`; Test `test/bridge-observe.test.sh`; `linux/deploy-manifest` rows for `lib/bridge.sh` (755 lib, after line 58) and `linux/bridge-observe.sh` (755 scripts, after line 37).

**Interfaces:**
- **Line — fourteen US-separated fields, empty when absent:**
  `1 id · 2 answer · 3 pid · 4 birth · 5 pane · 6 name · 7 nameSince · 8 gen_state · 9 classes · 10 launch_child · 11 procStart · 12 sessionId · 13 bridge_mtime · 14 session_created`
  - 3–7, 11–13 describe the single verified-live candidate (C1: the supervisor binds `procStart`, `sessionId`, `bridge_mtime` from here, so a later KILL -9 file matches `bridge_gen_matches_dead`).
  - 10 `launch_child` ∈ `1|0|` — whether a **nonce-bearing runtime** currently descends from the recorded launch pane (C2: the pane's own pid is the `; exec bash` shell and survives Claude; it proves tmux, not the child).
  - 14 `session_created` — tmux `#{session_created}` for `=<id>` when present, else empty (C6: the no-process key needs a stable tmux identity).
- `bridge-observe.sh <id>` read-only; `--all` (rows this uid owns; others `uninspectable`); `--bootstrap <id>` (classification ignores generation and claim; `gen_state=bootstrap`; census treated as done — census only).
- Refusal reasons in field 9: `row-does-not-load`, `account-missing` (C11), `account-does-not-resolve`, `owner-uid-unknown`, `login-account-mismatch`, `config-dir-unreadable`, `sessions-dir-unreadable`, `launch-clock-discontinuity` (C9).
- Env: `STEWARD_STATE_DIR`, `STEWARD_TMUX_SOCKET` (required); `STEWARD_REGISTRY_LIB`, `STEWARD_BRIDGE_LIB`, `BRIDGE_PROC_ROOT`, `STEWARD_BRIDGE_GRACE_MS` (600000), `STEWARD_NOW_MS`, `STEWARD_NOW_UPTIME_MS` (test overrides), `STEWARD_SELF_HOST`.

**Clocks (C9).** The generation records `launch_ms` (wall) and `launch_uptime_ms` (from `/proc/uptime`, field 1 × 1000). The launch is *open* iff `pid` is empty and `now_uptime_ms − launch_uptime_ms < GRACE_MS`. If `now_uptime_ms < launch_uptime_ms` (reboot) or `now_ms < launch_ms` (wall stepped back) the row is `unknown launch-clock-discontinuity`; nothing is written and an operator clears the claim. `startedAt ≥ launch_ms` stays a wall comparison because the vendor writes wall time.

- [ ] **Step 1: Failing test** (`test/bridge-observe.test.sh`; fixture as `test/supervisor-reap.test.sh` plus `/proc` with `stat`, `environ` and `uptime`, an `id` shim, `STEWARD_NOW_MS`/`STEWARD_NOW_UPTIME_MS`). Claims — each names the field it reads:
1. known birth in stored pane → f2 `identified:managed`; f11/f12/f13 carry procStart/sessionId/mtime; generation file byte-identical afterwards.
2. fresh pid, no launch → `unknown`.
3. open launch, in window, nonce in `environ`, started after → `identified:managed`.
4. same, no nonce → `unknown`.
5. same, nonce, but `now_uptime` past the window → `unknown`.
6. same, nonce, in window, but `now_ms < launch_ms` (wall stepped back) → `unknown … launch-clock-discontinuity`.
7. `now_uptime < launch_uptime` (reboot) → same reason.
8. moved; 9. orphan; 10. stale by pid:procStart → `no-process`; 11. two live → `unknown`; 12. poison line → `unknown`.
13. unrelated live claude under **another** session's pane, this row dead → `no-process`.
14. launch recorded, past window, pane shell alive but **no nonce-bearing descendant** → f10 `0`, f8 `gone-noreceipt` (C2); variant with a nonce-bearing descendant still alive but not yet registered → f10 `1`, f8 `alive` → `unknown`.
15. generation `pid` set, `birth` **empty**, process gone → `gone-noreceipt`, never `alive` (C3).
16. `--all` with a row of another uid → `uninspectable`.
17. `sessions/` unreadable → `unknown … sessions-dir-unreadable`.
18. `LOGIN` failing the principal gate → `unknown … login-account-mismatch`.
19. row without `ACCOUNT` → `unknown … account-missing` (C11).
20. `--bootstrap` on a live legacy process with no generation → `identified:managed` while the plain call says `unknown`.
21. tmux present → f14 equals the shim's `session_created`; absent → empty.
22. `LABEL_LOG` empty after every claim.

- [ ] **Step 2: Run** → red.
- [ ] **Step 3: Implement**

```bash
#!/bin/bash
# linux/bridge-observe.sh <id> | --all | --bootstrap <id> - THE adapter. Read-only: it measures,
# asks lib/bridge.sh, prints one fourteen-field line. It writes NOTHING; the supervisor owns state.
set -u
REG_LIB="${STEWARD_REGISTRY_LIB:-$HOME/scripts/lib/registry.sh}"; . "$REG_LIB" || exit 78
BRIDGE_LIB="${STEWARD_BRIDGE_LIB:-$(dirname "$REG_LIB")/bridge.sh}"; . "$BRIDGE_LIB" || exit 78
SD="${STEWARD_STATE_DIR:?}"; SOCK="${STEWARD_TMUX_SOCKET:?}"; GRACE_MS="${STEWARD_BRIDGE_GRACE_MS:-600000}"
PROC="${BRIDGE_PROC_ROOT:-/proc}"
NOW_MS="${STEWARD_NOW_MS:-$(( $(date +%s) * 1000 ))}"
NOW_UP="${STEWARD_NOW_UPTIME_MS:-$(awk '{printf "%d", $1*1000}' "$PROC/uptime" 2>/dev/null || printf 0)}"
RUNTIME_VETO_PAT='(^|[ /])(claude|opencode)'
tmuxc() { command tmux -S "$SOCK" "$@"; }
line() { local first=1 a; for a in "$@"; do [ "$first" = 1 ] && first=0 || printf '%s' "$US"; printf '%s' "$a"; done; printf '\n'; }
env_has_nonce() { [ -n "${2:-}" ] && LC_ALL=C tr '\0' '\n' < "$PROC/$1/environ" 2>/dev/null | grep -qx "STEWARD_LAUNCH_NONCE=$2"; }
same_nonempty() { [ -n "${1:-}" ] && [ "$1" = "${2:-}" ]; }                       # C3
refuse() { line "$1" "$2" "" "" "" "" "" "$3" "$4" "" "" "" "" ""; }
observe() { # <id> <bootstrap 0|1>
  local id="$1" boot="${2:-0}" owner cfg uid classes="" tmux_present veto gen_state gp launch lup nonce census lpid child="" created=""
  local tag path pid pstart tmuxf name since sid started mtime alive uid_ok known claim stored any dead birth sp p q c open_launch
  local L_PID="" L_BIRTH="" L_PANE="" L_NAME="" L_SINCE="" L_PS="" L_SID="" L_MTIME="" all_panes sess_panes
  registry_load "$id" >/dev/null 2>&1 || { refuse "$id" unknown none row-does-not-load; return; }
  [ -n "${ACCOUNT:-}" ] || { refuse "$id" unknown none account-missing; return; }                 # C11
  owner="$( registry_account_load "$ACCOUNT" >/dev/null 2>&1 && printf '%s' "$ACCOUNT_USERNAME" )"
  [ -n "$owner" ] || { refuse "$id" unknown none account-does-not-resolve; return; }
  uid="$(id -u "$owner" 2>/dev/null)" || { refuse "$id" unknown none owner-uid-unknown; return; }
  [ "$uid" = "$(id -u)" ] || { refuse "$id" uninspectable none other-owner; return; }
  if [ -n "${LOGIN:-}" ]; then
    registry_login_principal_gate "$LOGIN" "$ACCOUNT" >/dev/null 2>&1 || { refuse "$id" unknown none login-account-mismatch; return; }
    cfg="$(registry_login_config_dir "$LOGIN" "$owner" 2>/dev/null)" || cfg=""
  else cfg="$(eval printf '%s' "~$owner")/.claude"; fi
  [ -n "$cfg" ] && [ -r "$cfg" ] && [ -x "$cfg" ] || { refuse "$id" unknown none config-dir-unreadable; return; }
  if [ -d "$cfg/sessions" ] && ! { [ -r "$cfg/sessions" ] && [ -x "$cfg/sessions" ]; }; then refuse "$id" unknown none sessions-dir-unreadable; return; fi
  all_panes="$(tmuxc list-panes -a -F '#{pane_pid}' 2>/dev/null)"; sess_panes="$(tmuxc list-panes -s -t "=$id" -F '#{pane_pid}' 2>/dev/null)"
  if tmuxc has-session -t "=$id" 2>/dev/null; then tmux_present=1; created="$(tmuxc display-message -p -t "=$id" '#{session_created}' 2>/dev/null)"; else tmux_present=0; fi
  launch="$(bridge_gen_get "$SD" "$id" launch_ms 2>/dev/null)"; launch="${launch:-0}"
  lup="$(bridge_gen_get "$SD" "$id" launch_uptime_ms 2>/dev/null)"; lup="${lup:-0}"
  nonce="$(bridge_gen_get "$SD" "$id" launch_nonce 2>/dev/null)"; gp="$(bridge_gen_get "$SD" "$id" pid 2>/dev/null)"
  census="$(bridge_gen_get "$SD" "$id" census 2>/dev/null)"; lpid="$(bridge_gen_get "$SD" "$id" launch_pane_pid 2>/dev/null)"
  if [ "$launch" != 0 ]; then                                                                            # C9: clocks
    if [ "$NOW_MS" -lt "$launch" ] || [ "$NOW_UP" -lt "$lup" ]; then refuse "$id" unknown clock launch-clock-discontinuity; return; fi
  fi
  open_launch=0; [ "$launch" != 0 ] && [ -z "$gp" ] && [ $((NOW_UP - lup)) -lt "$GRACE_MS" ] && open_launch=1
  # C2: the launch CHILD is a nonce-bearing runtime descending from the launch pane, not the pane shell
  if [ -n "$lpid" ] && [ -n "$nonce" ]; then
    child=0; for p in $(pgrep -u "$uid" -f "$RUNTIME_VETO_PAT" 2>/dev/null); do bridge_is_descendant "$p" "$lpid" && env_has_nonce "$p" "$nonce" && { child=1; break; }; done
  fi
  while IFS="$US" read -r tag path pid pstart tmuxf name since sid started mtime; do
    [ -n "$tag" ] || continue
    [ "$tag" = '!unclassifiable' ] && { classes="$classes unclassifiable"; continue; }
    alive=0; uid_ok=0; known=0; claim=0; stored=0; any=0; dead=0; birth=""
    if birth="$(bridge_os_birth "$pid")"; then
      alive=1
      [ "$(ps -o uid= -p "$pid" 2>/dev/null | tr -d ' ')" = "$uid" ] && uid_ok=1
      if [ "$boot" = 1 ]; then known=1
      else
        bridge_gen_matches_live "$SD" "$id" "$pid" "$birth" && known=1
        [ "$open_launch" = 1 ] && [ "${started:-0}" -ge "$launch" ] 2>/dev/null && env_has_nonce "$pid" "$nonce" && claim=1
      fi
      sp="$(tmuxc display-message -p -t "$tmuxf" '#{pane_pid}' 2>/dev/null)"; [ -n "$sp" ] && bridge_is_descendant "$pid" "$sp" && stored=1
      for p in $all_panes; do bridge_is_descendant "$pid" "$p" && { any=1; break; }; done
    else
      [ "$boot" = 1 ] || { bridge_gen_matches_dead "$SD" "$id" "$pid" "$pstart" && dead=1; }
    fi
    c="$(bridge_classify_candidate "$alive" "$uid_ok" "$known" "$claim" "$stored" "$any" "$dead")"; classes="$classes $c"
    case "$c" in live:*) L_PID="$pid"; L_BIRTH="$birth"; L_PANE="$tmuxf"; L_NAME="$name"; L_SINCE="$since"; L_PS="$pstart"; L_SID="$sid"; L_MTIME="$mtime" ;; esac
  done <<EOF
$(bridge_candidates "$id" "$cfg/sessions")
EOF
  gen_state=none
  if [ "$boot" = 1 ]; then gen_state=bootstrap; census=1
  elif [ -n "$gp" ]; then
    if same_nonempty "$(bridge_os_birth "$gp" 2>/dev/null)" "$(bridge_gen_get "$SD" "$id" birth 2>/dev/null)"; then gen_state=alive      # C3
    elif [ -n "$(bridge_gen_get "$SD" "$id" stop_receipt 2>/dev/null)" ]; then gen_state=gone-receipt; else gen_state=gone-noreceipt; fi
  elif [ "$open_launch" = 1 ]; then gen_state=grace
  elif [ "$launch" != 0 ]; then if [ "$child" = 1 ]; then gen_state=alive; else gen_state=gone-noreceipt; fi                       # C2
  fi
  veto=0; for p in $(pgrep -u "$uid" -f "$RUNTIME_VETO_PAT" 2>/dev/null); do for q in $sess_panes; do bridge_is_descendant "$p" "$q" && { veto=1; break 2; }; done; done
  line "$id" "$(bridge_answer "$classes" "$gen_state" "$tmux_present" "$veto" "$census")" "$L_PID" "$L_BIRTH" "$L_PANE" "$L_NAME" "$L_SINCE" "$gen_state" "${classes# }" "$child" "$L_PS" "$L_SID" "$L_MTIME" "$created"
}
case "${1:-}" in
  --all) for n in $(registry_list); do registry_load "$n" >/dev/null 2>&1 || continue; [ "${HOST:-}" = "${STEWARD_SELF_HOST:-$(hostname -s)}" ] || continue; observe "$n" 0; done ;;
  --bootstrap) [ -n "${2:-}" ] || { echo "usage: bridge-observe.sh --bootstrap <id>" >&2; exit 64; }; observe "$2" 1 ;;
  '') echo "usage: bridge-observe.sh <id> | --all | --bootstrap <id>" >&2; exit 64 ;;
  *) observe "$1" 0 ;;
esac
```
- [ ] **Step 5: Mutations** — write the generation on managed → 1 fails; veto on `all_panes` → 13 fails; skip `env_has_nonce` → 4 fails; take the first of two live → 11 fails; `same_nonempty` → plain `=` → 15 fails; child = pane shell alive → 14 fails; drop the clock checks → 6/7 fail.
- [ ] **Step 6: Commit** — `bridge-observe: read-only, fourteen fields, a launch is proven by its nonce and its child`.

---

### Task 4b: `linux/bridge-kill.sh` — atomic check-and-signal (C12)

**Interfaces:** `bridge-kill.sh <pid> <birth> [SIGNAL]` → reads `bridge_os_birth "$pid"`, refuses (rc 65, message names both tokens) unless it equals `<birth>` **and both are non-empty**, otherwise sends the signal (default TERM) and prints `killed <pid> <birth> <signal>`. Honors `STEWARD_KILL` (test recorder) and `BRIDGE_PROC_ROOT`.
- [ ] Test `test/bridge-kill.test.sh`: match → kill recorded; mismatch → rc 65, no kill; empty birth → rc 65; gone pid → rc 65. Mutation: drop the non-empty check → "empty birth" claim fails. Commit — `bridge-kill: the birth is read and the signal sent in one step, or neither`.

---

### Task 5: Supervisor — owns every write; claim before spawn; keyed action gate; existing veto kept

Spec §1; C1, C3, C4, C5, C6.

**Files:** supervisor; `test/supervisor-bridge.test.sh`; rewrite `test/supervisor-reap.test.sh` claims 2/3.

**Interfaces (internal):** `observe_row` sets `B_ANS B_PID B_BIRTH B_PANE B_NAME B_SINCE B_GEN B_CLASSES B_CHILD B_PS B_SID B_MTIME B_CREATED` from the fourteen fields. `NO_PROCESS_CONFIRMED` (1/empty) hands a confirmed no-process to the **existing** flow below line 1762 instead of acting inline (C5).

- [ ] **Step 1: Failing tests** — claims:
1. managed, display changed → healthy; no label pgrep; no kill; generation gains `pid birth procStart sessionId bridge_mtime` (C1).
2. managed dead, **another pane of THIS id** holds a claude, tmux present → `wait-veto` every round; nothing written (C5 distinction).
3. managed dead, a claude under **another session** → round one key `close … session_created=<c>` stored, no action; round two: the flow reaches the existing zombie repair, `kill-session` then one `new-session`.
4. moved → nothing written.
5. orphan → round one key stored, no kill; round two kill through `bridge-kill.sh` (recorded with birth); orphan → moved → orphan → no kill; `/proc/<pid>` removed between rounds → no kill.
6. stale, tmux absent → round one key `spawn … absent`, no spawn; round two one spawn.
7. tmux absent on round one, a **human creates** `=<id>` before round two → key differs (`close … session_created`) → **no** kill, no spawn (C6).
8. split-brain → nothing; 9. malformed+live → nothing; 10. pre-census → no spawn; 11. post-census first-ever → two rounds, one spawn.
12. grace by uptime deadline; N observer invocations in one round change nothing.
13. spawn: generation carries `launch_ms launch_uptime_ms launch_nonce spawn_state=pending` **before** `new-session` (the tmux shim asserts the file exists when called), then `launch_pane_pid launch_pane_birth spawn_state=started` after; a shim that fails `new-session` → `spawn_state=failed:<epoch>`, nonce and launch cleared (C4).
14. `STEWARD_LAUNCH_NONCE=<value>` appears in the child launch string before `claude` and not after the `;` (C8).
15. display fails on a live managed row → supervised, `.display-degraded` once; on no-process → rc 78.
16. `launch_child` `0` past window → `gone-noreceipt` → the crash path respawns (C2 end-to-end).

- [ ] **Step 3: Implement**
  - Placement: source `lib/bridge.sh` after line 81 (`_bridge_ok=1`, no exit); refuse only after the pause guard (:154) and `CFG_ROOT` (:358). `OBSERVE`, `BKILL` paths from `STEWARD_BRIDGE_OBSERVE`/`STEWARD_BRIDGE_KILL` or beside `$0`.
  - `observe_row()` reads fourteen fields with `IFS="$US"`.
  - Line 1337: `observe_row; if [ "$B_ANS" = identified:managed ]; then rm -f "$SUSPECT" "$STATE_DIR/$NAME.identity-degraded"; bridge_gen_write "$STATE_DIR" "$NAME" pid="$B_PID" birth="$B_BIRTH" procStart="$B_PS" sessionId="$B_SID" bridge_mtime="$B_MTIME" uid="$(id -u)" bridge_name="$B_NAME" bridge_nameSince="$B_SINCE" launch_nonce= launch_pane_pid= launch_pane_birth= launch_ms= launch_uptime_ms= spawn_state=bound`.
  - Replace lines 1731-1743:

```bash
case "$B_ANS" in
  identified:managed) : ;;
  identified:moved) rm -f "$SUSPECT"; echo "session-supervisor: $NAME — identified but MOVED (pid $B_PID, not under $B_PANE). Nothing written." >&2; exit 0 ;;
  unknown)
    rm -f "$SUSPECT"
    if [ "$B_GEN" = alive ] && [ ! -f "$STATE_DIR/$NAME.identity-degraded" ]; then touch "$STATE_DIR/$NAME.identity-degraded"; echo "session-supervisor: $NAME — DEGRADED: our process lives but nothing attests it." >&2; fi
    echo "session-supervisor: $NAME — identity-unknown ($B_CLASSES). Nothing written." >&2; exit 0 ;;
  grace|wait-veto) rm -f "$SUSPECT"; exit 0 ;;
  identified:orphan)
    bridge_suspect_confirmed "$SUSPECT" "$(bridge_suspect_key reap "$B_PID" "$B_BIRTH")" || exit 0
    "$BKILL" "$B_PID" "$B_BIRTH" TERM >&2; rm -f "$SUSPECT"; exit 0 ;;
  no-process)
    [ -z "${DISPLAY_ERR:-}" ] || { echo "session-supervisor: $NAME — REFUSING to spawn: the display does not derive: $DISPLAY_ERR" >&2; exit 78; }
    if tmuxc has-session -t "=$NAME" 2>/dev/null; then _np_key="$(bridge_suspect_key close "$B_CREATED")"; else _np_key="$(bridge_suspect_key spawn absent)"; fi
    bridge_suspect_confirmed "$SUSPECT" "$_np_key" || exit 0                     # C6: action + target
    rm -f "$SUSPECT"; NO_PROCESS_CONFIRMED=1 ;;                                    # C5: fall through to the existing flow
  *) echo "session-supervisor: $NAME — adapter answered '$B_ANS', unknown here. Nothing written." >&2; exit 0 ;;
esac
if [ -n "${NO_PROCESS_CONFIRMED:-}" ] && ! tmuxc has-session -t "=$NAME" 2>/dev/null; then spawn_session; exit 0; fi
# with tmux present the confirmed no-process continues into the EXISTING activity/debris veto
# below (lines 1762-1992 today); the zombie repair there is the only place kill-session runs.
```
  - In the zombie repair (:1994): before `kill-session`, `bridge_gen_write "$STATE_DIR" "$NAME" stop_receipt="zombie-$(date +%s)"`; it runs only when `NO_PROCESS_CONFIRMED` is set (guard the block).
  - `spawn_session` (C4, C8):

```bash
spawn_session() {
  ensure_workspace_trusted
  rm -f "$SUSPECT"
  NONCE="$(od -An -N16 -tx1 /dev/urandom | tr -d ' \n')"
  bridge_gen_write "$STATE_DIR" "$NAME" launch_ms="$(( $(date +%s) * 1000 ))" launch_uptime_ms="$(awk '{printf "%d", $1*1000}' "${BRIDGE_PROC_ROOT:-/proc}/uptime")" launch_nonce="$NONCE" spawn_state=pending pid= birth= stop_receipt= || exit 70
  [ -n "$SID" ] && printf '%s %s\n' "$SID" "$(( ${_tries:-0} + 1 ))" > "$RESUME_TRY"
  printf '%s\n' "$SID" > "$LAUNCH_MARK"
  local pane_pid
  if [ -n "$ADAPTER" ]; then
    pane_pid="$(tmuxc new-session -d -P -F '#{pane_pid}' -s "$NAME" -c "$REPO" "${CRED_ENV_ARGS[@]}" "exec \"$ADAPTER\" \"$NAME\"")"
  else
    pane_pid="$(tmuxc new-session -d -P -F '#{pane_pid}' -s "$NAME" -c "$REPO" "${CRED_ENV_ARGS[@]}" "${LOGIN_PREFIX}STEWARD_LAUNCH_NONCE=$NONCE $HOME/.local/bin/$CLAUDE_CMD; exec bash")"
  fi
  if [ -z "$pane_pid" ]; then bridge_gen_write "$STATE_DIR" "$NAME" spawn_state="failed:$(date +%s)" launch_nonce= launch_ms= launch_uptime_ms=; echo "session-supervisor: $NAME — spawn FAILED; the launch claim is closed." >&2; return 70; fi
  bridge_gen_write "$STATE_DIR" "$NAME" launch_pane_pid="$pane_pid" launch_pane_birth="$(bridge_os_birth "$pane_pid" 2>/dev/null)" spawn_state=started
  …existing MCP/trust tail unchanged…
}
```
  (`LOGIN_PREFIX` already ends in `env -u … CLAUDE_CONFIG_DIR=… ` so appending `STEWARD_LAUNCH_NONCE=$NONCE` keeps it inside the same `env` invocation; for a row without LOGIN the prefix is `/usr/bin/env -u ANTHROPIC_API_KEY -u ANTHROPIC_AUTH_TOKEN ` per `registry_login_exec_prefix`'s empty-slug branch, so the assignment still lands on `claude` and not on the shell after `;` — C8, measured.)
  - Delete `matching_claude_pids`, `CLAUDE_PAT`, `RC_LBL_PAT`, `claude_alive_in_session`, local `is_descendant`.
- [ ] **Step 5: Mutations** — kill on first orphan sighting → 5 fails; key without `session_created` → 7 fails; write the claim after `new-session` → 13 fails; inline `kill-session` in the case → 2/3 fail; `same_nonempty`→`=` in the adapter → 16's sibling fails.
- [ ] **Step 6: Commit** — `supervisor: one observation, one owner of state, a claim before the spawn, and the old veto kept`.

---

### Task 6: Display as a fact; rename to the pane, two rounds; receipt with advancing nameSince; tty-checked foreground

Spec §2; C7, previous B9.

As before, plus (C7): a **rename suspect** — `bridge_suspect_key rename "$B_PID" "$B_BIRTH" "$B_PANE" "$DESIRED" "$PENDING_SINCE"` must be confirmed on two consecutive rounds **immediately before `type_line`**; any round that is busy, foreground-mismatched, unknown/moved, or has a different desired resets it (the confirm call is made only in the branch that would type; every other branch `rm -f "$RENAME_SUSPECT"`). Foreground check reads `tty_nr` and `tpgid` from both the pane shell and the managed pid. `.display-degraded` cleared on recovery.
Claims 13–17 as before, plus 18: desired ≠ applied on a fresh managed row → **no** `send-keys` on round one, one on round two; 19: a busy pane between the two rounds → the count restarts.

---

### Task 7: Watch — the line, the remote socket, the kill helper

As before, with (C12): `restart-session.mjs` never calls `kill` itself; it runs `bash ~/scripts/bridge-kill.sh <pid> <birth> TERM` and treats rc 65 as "refuse, re-observe". Info lines: `session-watch.mjs` has no info-kind alert path; add `console.error(\`[watch] identity ${o.answer} for ${s.id}\`)` at the decision and assert it in a test that captures stderr. `parseObserveLine` requires **fourteen** fields.

---

### Tasks 8–12 — OUTLINES (contracts as in v3; field count fourteen; census requires `ACCOUNT` on every row it seeds and lists `account-missing` rows as a named prerequisite).

---

## Gates carried by this plan

P0 census — **preceded by ACCOUNT migration of every legacy row on the host** (C11). P1b cases A and B before Task 11's first derive. P2 macOS twin, bash 3.2 for `test/bridge-*.test.sh`. P3 manual census; Task 9 strict mode.

## Self-review

C1 → fourteen fields, binding writes procStart/sessionId/mtime. C2 → `launch_child` from a nonce-bearing descendant of the launch pane; pane shell alive is tmux, not child. C3 → `same_nonempty` in the adapter; matchers already refuse empty (T3 built). C4 → claim persisted before `new-session`, `spawn_state` pending/started/failed/bound. C5 → confirmed no-process with tmux present falls into the existing veto flow; only the zombie repair kills; another pane of this id is `wait-veto` from the adapter. C6 → keys `reap pid birth`, `close session_created`, `spawn absent`. C7 → rename suspect two rounds, reset on every other branch. C8 → trust boundary stated as same uid; fallback shell measured not to inherit. C9 → uptime deadline, wall only for the vendor comparison, discontinuity → unknown. C10 → built (empty travels empty). C11 → `account-missing`, migration as P0 prerequisite. C12 → `bridge-kill.sh`; info line on stderr and asserted.
Executable as written after the fourth pass: Tasks 4, 4b, 5. Tasks 6–7 full code awaiting the same pass. Tasks 8–12 outlines.
