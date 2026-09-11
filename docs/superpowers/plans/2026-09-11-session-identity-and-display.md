# Session Identity and Display Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Supervision identifies a session by the vendor's bridge file (ID ↔ pid+birth token ↔ pane) with launch provenance it can prove, never by its Remote Control label; the label is rendered from the register and renamed through the existing `/rename` cycle bound to the managed pane.

**Architecture:** `lib/bridge.sh` holds pure decision functions (built). `linux/bridge-observe.sh` is the **one, read-only adapter** for `claude-code` rows only; it prints one line per row in a fixed vocabulary and writes nothing. **Only the supervisor mutates state**, from a line it read this round, behind a keyed two-round gate whose key names the action and its exact target. OpenCode and Codex rows keep their existing supervision untouched. Watch, liveness-host and the census consume the same line.

**Tech Stack:** bash 3.2-compatible shell, jq 1.7, tmux, Linux `/proc`, python3 ≥ 3.9 (`pidfd`); Node `node:test` for `watch/`.

**Spec:** `docs/superpowers/specs/2026-09-11-session-identity-and-display-design.md` (38c719c).

**Revision:** fifth version, after the advisor's fourth pass on 9ee16ff (12 findings, cited *D1…D12*; the advisor also ran the built suites: 93 green, now 103). **Done: Tasks 1–3** (`55e677a` `d14db58` `a8d33f1` `9eaed35` `cde906e` `610d63e` `3862019`). **Next: Task 1b, then 4, 4b, 5** — executed with TDD and reviewed as diffs.

## Global Constraints

- Never read or log `bridgeSessionId` or `messagingSocketPath`.
- **Bridge identity applies to `claude-code` rows only.** A row with `RUNTIME=opencode|codex` (the supervisor's `ADAPTER` set) keeps today's port/pane supervision; the adapter answers `not-applicable` for it and the supervisor never consults the bridge for it (D1).
- **The adapter never writes.** Only the supervisor mutates state, from a line read this round.
- Every destructive or typing action requires the **same keyed observation on two consecutive rounds**, the key naming the action **and its exact target** (`reap pid birth` · `close session_id session_created` · `spawn absent` · `rename pid birth pane desired pending_since`), **re-read immediately before the action**; any difference resets and exits (D5). Destruction also passes the supervisor's **existing** activity/debris veto (D2).
- A live process is ours only when the generation knows its birth **or** it is a proven launch child: open launch, inside the monotonic window, same boot id, carries the nonce, **descends from the recorded launch pane incarnation**, its bridge file is not an inode that existed before the spawn, and `startedAt`/`mtime` are not older than the launch (D4, D8, D10). Trust boundary: the unix uid (measured: the fallback shell does not inherit the nonce).
- Birth equality requires both sides non-empty. Clocks: grace on `/proc/uptime` **with the boot id**; wall time only for the vendor's `startedAt`/`mtime`; any discontinuity → `unknown` (D8).
- Candidate fields in the adapter line are **blank unless the answer starts `identified:`** (D9).
- A stop receipt is written **after** the destruction succeeded and the target tuple is absent; `stop_intent` may precede it (D12).
- Spawn writes nothing it has not validated: nonce `^[0-9a-f]{32}$`, numeric wall and uptime, tmux exit status 0, numeric pane pid, non-empty pane birth — else the claim is closed and the row degraded (D7).
- Fields travel with the unit separator; empty travels empty. No literal tab bytes, no backslash-u escapes in files written through JSON-carrying tools. Tests never touch the machine. **A commit requires every touched suite green in the same script; the gate is code, not memory.**
- Commit with the estate author (`git -c user.name="Jon Kindell" -c user.email="jon+butler@varvet.com" …`, `Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>`, `Claude-Session: https://claude.ai/code/session_01RMVoAh7XJUuje1PCq3tEQX`). Branch `session-identity-display`; merge is butler's.

---

## File Structure

| file | responsibility |
|---|---|
| `lib/bridge.sh` (built; T1b adds inode) | candidates (US framing, in-band poison, **inode**), OS birth, descendant walk, classification, four-way answer, generation with closed vocabulary and dead-file history, keyed suspect |
| `linux/bridge-observe.sh` (new) | read-only adapter: `<id>`, `--all`, `--bootstrap <id>`; **fourteen** fields; `not-applicable` for non-claude rows |
| `linux/bridge-kill.py` (new) | python3: `pidfd_open` → verify `/proc/<pid>/stat` birth on the pinned process → `pidfd_send_signal`; rc 65 mismatch, rc 69 when pidfd is unavailable — no silent downgrade (D6) |
| `linux/session-supervisor-linux.sh` (modify) | claude rows: line → keyed gate → existing veto → action; opencode rows: untouched |
| `linux/deploy-manifest` (modify) | ships `lib/bridge.sh`, `linux/bridge-observe.sh`, `linux/bridge-kill.py`, `linux/bridge-census.sh` |
| `watch/…`, `linux/liveness-host.sh`, `lib/registry.sh`, `bin/steward`, `linux/hub/enroll`, `linux/bridge-census.sh` | later tasks |

---

### Tasks 1–3 — DONE (as built)

`bridge_candidates <id> <dir>` → `ok US path US pid US procStart US tmux US name US nameSince US sessionId US startedAt US mtime_ms` | `!unclassifiable US path US reason`. `bridge_os_birth <pid>` → `boot_id:ticks`. `bridge_is_descendant`. `bridge_classify_candidate <alive> <uid_ok> <birth_known> <launch_claim> <stored> <any> <dead_match>`. `bridge_answer <classes> <gen_state> <tmux_present> <veto> <census>`. `bridge_gen_get/write` (closed vocabulary `BRIDGE_GEN_KEYS`, atomic, history bounded 8), `bridge_gen_matches_live/dead` (refuse empty keys), `bridge_suspect_key`, `bridge_suspect_confirmed`.

### Task 1b: candidates carry the inode (D10)

**Files:** `lib/bridge.sh`, `test/bridge-classify.test.sh`.
**Interface change:** the `ok` line gains an **eleventh** field `inode` (`stat -c %i` | `stat -f %i`); a stat failure is `!unclassifiable … stat` as today. `BRIDGE_GEN_KEYS` already lists `launch_inodes`.
- [ ] Test: claim 1g `fld 11` is a positive integer; a file replaced by a new one (rm + recreate) yields a different inode. Mutation: emit `0` → 1g fails.
- [ ] Commit — `bridge: a candidate carries its inode, so a file that predates the spawn can be told from one it made`.

---

### Task 4: `linux/bridge-observe.sh` — read-only, fourteen fields, `--bootstrap`, `not-applicable`

Spec §1; D1, D3, D4, D5, D8, D9, D10.

**Interfaces:**
- **Line — fourteen US fields, empty when absent:** `1 id · 2 answer · 3 pid · 4 birth · 5 pane · 6 name · 7 nameSince · 8 gen_state · 9 classes · 10 launch_child · 11 procStart · 12 sessionId · 13 bridge_mtime · 14 tmux_tuple`
  - `answer` ∈ `bridge_answer`'s seven words plus `uninspectable` and **`not-applicable`** (row is not `claude-code`, D1).
  - 3–7, 11–13 are **blank unless `answer` starts `identified:`** (D9).
  - 10 `launch_child` ∈ `1|0|` — a nonce-bearing runtime descends from the recorded launch pane **incarnation** (pane pid alive with the recorded birth).
  - 14 `tmux_tuple` = `<session_id>:<session_created>` (tmux `#{session_id}` is `$N`; both required non-empty when the session exists), else empty (D5).
- Modes: `<id>` · `--all` (rows this uid owns; others `uninspectable`) · `--bootstrap <id>` (classification ignores generation and claim; **`bridge_answer` is called with `gen_state=none` and `census=1`**, field 8 reports `bootstrap` — D3).
- Refusal reasons (field 9, answer `unknown`): `row-does-not-load` `account-missing` `account-does-not-resolve` `owner-uid-unknown` `login-account-mismatch` `config-dir-unreadable` `sessions-dir-unreadable` `launch-clock-discontinuity`.
- **Launch claim for a candidate** (all required): open launch (`launch_ms` set, `pid` empty, `launch_boot_id` = current boot id, `now_uptime − launch_uptime < GRACE_MS`) · `startedAt ≥ launch_ms` · `mtime_ms ≥ launch_ms − 1000` · inode ∉ `launch_inodes` · `/proc/<pid>/environ` has `STEWARD_LAUNCH_NONCE=<nonce>` · `bridge_is_descendant pid launch_pane_pid` with `same_nonempty "$(bridge_os_birth launch_pane_pid)" launch_pane_birth` (D4, D8, D10).
- **Clock discontinuity** (D8): `launch_boot_id ≠ boot id` **or** `now_ms < launch_ms` **or** `now_uptime < launch_uptime` → `unknown launch-clock-discontinuity`.
- Env: `STEWARD_STATE_DIR`, `STEWARD_TMUX_SOCKET`; `STEWARD_REGISTRY_LIB`, `STEWARD_BRIDGE_LIB`, `BRIDGE_PROC_ROOT`, `STEWARD_BRIDGE_GRACE_MS` (600000), `STEWARD_NOW_MS`, `STEWARD_NOW_UPTIME_MS`, `STEWARD_SELF_HOST`.

- [ ] **Step 1: Failing test** `test/bridge-observe.test.sh` — fixture as `test/supervisor-reap.test.sh` plus `/proc/{<pid>/stat,<pid>/environ,uptime,sys/kernel/random/boot_id}`, `id` shim, clock overrides. Claims:
1. known birth in stored pane → `identified:managed`; f11–13 filled; generation byte-identical afterwards.
2. fresh pid, no launch → `unknown`.
3. open launch + nonce + descends from launch pane (alive, recorded birth) + startedAt/mtime/inode fresh → `identified:managed`.
4. same, nonce absent → `unknown`. 5. same, nonce present, **not** a descendant of the launch pane → `unknown` (D4). 6. same, descendant, but the launch pane's birth differs from the recorded one (pane recreated) → `unknown` (D4). 7. same, inode ∈ `launch_inodes` → `unknown` (D10). 8. same, `mtime` older than launch − 1 s → `unknown`.
9. window elapsed → `unknown`. 10. `now_ms < launch_ms` → `… launch-clock-discontinuity`. 11. `now_uptime < launch_uptime` → same. 12. `launch_boot_id ≠ boot_id` → same (D8).
13. moved; 14. orphan; 15. stale → `no-process`; 16. two live → `unknown` **and fields 3–7, 11–13 empty** (D9); 17. poison + live → `unknown`, fields empty (D9).
18. unrelated live claude under another session → `no-process`; another pane of **this** id → `wait-veto`.
19. launch recorded, past window, pane shell alive, **no** nonce child → f10 `0`, f8 `gone-noreceipt`; with a nonce child alive → f10 `1`, f8 `alive`, answer `unknown`.
20. generation `pid` set, `birth` empty, process gone → `gone-noreceipt`.
21. `--all`: other uid → `uninspectable`. 22. `sessions/` unreadable → `unknown … sessions-dir-unreadable`. 23. principal gate fails → `login-account-mismatch`. 24. no `ACCOUNT` → `account-missing`.
25. `--bootstrap`, live legacy, no generation → `identified:managed`; **`--bootstrap`, empty row, no generation → `no-process`** (D3); plain call on the same rows → `unknown`.
26. tmux present → f14 `$N:<created>` from the shim; absent → empty (D5).
27. `RUNTIME="opencode"` row → `not-applicable`, all other fields empty, no `/proc` or bridge reads attempted (D1; the `pgrep` shim records any call → count 0).
28. `LABEL_LOG` empty after every claim.

- [ ] **Step 3: Implement** — as v4's script with these changes: refuse `not-applicable` right after `registry_load` when `${RUNTIME:-claude-code}` ≠ `claude-code`; `lbirth` check and `bridge_is_descendant "$pid" "$lpid"` and inode/mtime freshness folded into `claim=1`; `LB="$(cat "$PROC/sys/kernel/random/boot_id")"`, `launch_boot_id` compared; `--bootstrap` calls `bridge_answer "$classes" none "$tmux_present" "$veto" 1` and prints `bootstrap` in field 8; after `ans` is computed: `case "$ans" in identified:*) : ;; *) L_PID=""; L_BIRTH=""; L_PANE=""; L_NAME=""; L_SINCE=""; L_PS=""; L_SID=""; L_MTIME="" ;; esac`; `tuple="$(tmuxc display-message -p -t "=$id" '#{session_id}:#{session_created}')"` with both halves required non-empty (else `unknown tmux-tuple-incomplete`).
- [ ] **Step 5: Mutations** — one per claim group: write on managed (1); veto on `all_panes` (18); skip nonce (4); skip descent (5); skip pane birth (6); skip inode (7); skip boot id (12); first of two live (16); leave L_* on unknown (16/17); bootstrap with gen `bootstrap` (25); claude-only scope removed (27).
- [ ] **Step 6: Commit** — `bridge-observe: read-only, fourteen fields, a launch child proven by nonce, pane incarnation and inode`.

---

### Task 4b: `linux/bridge-kill.py` — pinned check-and-signal (D6)

**Interfaces:** `bridge-kill.py <pid> <birth> [SIGNAL]` (python3 ≥ 3.9). Validates `pid` (positive int) and `SIGNAL` (name in `signal.Signals` or int); `fd = os.pidfd_open(pid)` (rc 65 if the pid is gone); reads `/proc/<pid>/stat` **after** the pidfd pins the process and computes `boot_id:ticks` the same way as `bridge_os_birth`; rc 65 unless equal to `<birth>` and both non-empty; `signal.pidfd_send_signal(fd, sig)`; prints `killed <pid> <birth> <SIGNAL>`. If `os.pidfd_open` is missing → rc 69 `pidfd unavailable` and **no** fallback to `kill`. Honors `STEWARD_KILL` (a recorder invoked as `STEWARD_KILL <pid> <SIGNAL>` **instead of** `pidfd_send_signal`) and `BRIDGE_PROC_ROOT`.
- [ ] Test `test/bridge-kill.test.sh`: match → recorder called with `<pid> TERM`; mismatch → rc 65, recorder not called; empty birth → 65; gone pid → 65; bad signal name → 64; `python3 -c 'import os; os.pidfd_open'` absent (simulated via `STEWARD_FORCE_NO_PIDFD=1`) → 69. Mutation: compare only pid → mismatch claim fails.
- [ ] Commit — `bridge-kill: the process is pinned before its birth is read, and the signal goes to the pin`.

---

### Task 5: Supervisor — claude rows on the adapter; claim before spawn; keyed action gate; existing veto kept; OpenCode untouched

Spec §1; D1, D2, D5, D7, D12.

**Files:** supervisor; `test/supervisor-bridge.test.sh`; rewrite `test/supervisor-reap.test.sh` claims 2/3; **required runs:** `test/supervisor-opencode.test.sh`, `-mcp-guard`, `-zombie-veto`, `-reap`.

**Interfaces (internal):** `observe_row` → `B_ANS B_PID B_BIRTH B_PANE B_NAME B_SINCE B_GEN B_CLASSES B_CHILD B_PS B_SID B_MTIME B_TUPLE`. `NO_PROCESS_CONFIRMED` (1/empty). Everything below runs **only when `[ -z "$ADAPTER" ]`**; the OpenCode branch is byte-identical to today (D1).

- [ ] **Step 1: Failing tests** — claims:
1. managed, display changed → healthy; no label pgrep; no kill; generation gains `pid birth procStart sessionId bridge_mtime`.
2. **`RUNTIME="opencode"` row → the supervisor never calls the observer, and today's port-based health decides** (D1; observer wrapper counts 0 calls; `test/supervisor-opencode.test.sh` green).
3. managed dead, another pane of **this** id → `wait-veto` each round, nothing written.
4. managed dead, a claude under **another** session, tmux present → round one key `close $N:<created>`, nothing; round two → **reaches the existing activity/debris gate** (the old `SUSPECT` block at 1731–1761 is not executed: assert `SUSPECT` is absent after round two and the zombie repair ran once) (D2).
5. moved → nothing.
6. orphan → round one key `reap pid birth`; round two: `bridge-kill.py` recorder shows `<pid> TERM`; orphan→moved→orphan → no kill; `/proc/<pid>` gone between rounds → no kill.
7. stale, tmux absent → round one key `spawn absent`; round two: one spawn.
8. tmux absent round one, **human creates `=<id>`** before round two → key differs → no kill, no spawn (D5).
9. `close` confirmed, but the tuple **changes** (`$N` or created) between confirmation and the kill site → reset, exit, nothing killed (D5).
10. split-brain → nothing; 11. poison+live → nothing; 12. pre-census → no spawn; 13. post-census first-ever → two rounds, one spawn.
14. grace by uptime deadline; extra observer invocations in one round change nothing.
15. spawn: before `new-session` the generation holds `launch_ms launch_uptime_ms launch_boot_id launch_nonce launch_inodes spawn_state=pending` (the tmux shim asserts the file); after: `launch_pane_pid launch_pane_birth spawn_state=started`; `new-session` failing → `spawn_state=failed:<epoch>`, claim closed (D7 / v4 C4).
16. spawn validation: a nonce shim yielding 31 hex chars → no `new-session`, `spawn_state=failed:…`, degraded (D7); unreadable `/proc/uptime` → same.
17. `STEWARD_LAUNCH_NONCE=<value>` before `claude` in the launch string, not after `;`.
18. zombie path: `stop_intent` written before `kill-session`; `stop_receipt` **only** after `kill-session` returned 0 and `has-session` is false (a shim where `kill-session` fails → intent present, receipt absent) (D12).
19. display fails on a live managed row → supervised, `.display-degraded` once; on confirmed no-process → rc 78.
20. `launch_child` `0` past the window → crash path respawns.

- [ ] **Step 3: Implement**
  - After line 81: source `lib/bridge.sh`, `_bridge_ok=1`, no exit. After the pause guard (:154) and `CFG_ROOT` (:358): `if [ -z "$ADAPTER" ]; then [ "${_bridge_ok:-}" = 1 ] || { echo "… REFUSING: $BRIDGE_LIB does not define bridge_answer" >&2; exit 78; }; fi`. `OBSERVE`, `BKILL` from env or beside `$0`.
  - Line 1337 (claude rows only): `observe_row; if [ "$B_ANS" = identified:managed ]; then …bind…`. The OpenCode path keeps `claude_alive_in_session`'s **port-based** sibling untouched (do not delete the opencode branch functions; delete only the label-based claude ones).
  - **Replace lines 1731–1761 entirely** for claude rows with the case below; the OpenCode branch keeps its original block (D2):

```bash
if [ -z "$ADAPTER" ]; then
  case "$B_ANS" in
    identified:managed) : ;;
    identified:moved) rm -f "$SUSPECT"; echo "session-supervisor: $NAME — identified but MOVED (pid $B_PID, not under $B_PANE). Nothing written." >&2; exit 0 ;;
    unknown) rm -f "$SUSPECT"; [ "$B_GEN" = alive ] && [ ! -f "$STATE_DIR/$NAME.identity-degraded" ] && { touch "$STATE_DIR/$NAME.identity-degraded"; echo "session-supervisor: $NAME — DEGRADED: our process lives but nothing attests it." >&2; }
             echo "session-supervisor: $NAME — identity-unknown ($B_CLASSES). Nothing written." >&2; exit 0 ;;
    grace|wait-veto) rm -f "$SUSPECT"; exit 0 ;;
    identified:orphan)
      bridge_suspect_confirmed "$SUSPECT" "$(bridge_suspect_key reap "$B_PID" "$B_BIRTH")" || exit 0
      python3 "$BKILL" "$B_PID" "$B_BIRTH" TERM >&2; rm -f "$SUSPECT"; exit 0 ;;
    no-process)
      [ -z "${DISPLAY_ERR:-}" ] || { echo "session-supervisor: $NAME — REFUSING to spawn: the display does not derive: $DISPLAY_ERR" >&2; exit 78; }
      if [ -n "$B_TUPLE" ]; then _np_key="$(bridge_suspect_key close "$B_TUPLE")"; else _np_key="$(bridge_suspect_key spawn absent)"; fi
      bridge_suspect_confirmed "$SUSPECT" "$_np_key" || exit 0
      rm -f "$SUSPECT"; NO_PROCESS_CONFIRMED=1; NP_TUPLE="$B_TUPLE" ;;
    *) echo "session-supervisor: $NAME — adapter answered '$B_ANS', unknown here. Nothing written." >&2; exit 0 ;;
  esac
  if [ -n "${NO_PROCESS_CONFIRMED:-}" ]; then
    if [ -z "$NP_TUPLE" ]; then tmuxc has-session -t "=$NAME" 2>/dev/null && { echo "session-supervisor: $NAME — a tmux session appeared after 'spawn absent' was confirmed; resetting." >&2; exit 0; }; spawn_session; exit 0; fi
    # tmux present: fall into the EXISTING activity/debris gate (old lines 1762-1992 keep running below)
  else
    exit 0    # a managed row that reached here has nothing more to do this round
  fi
fi
```
  - Zombie repair (:1994), guarded by `NO_PROCESS_CONFIRMED`: re-read the tuple: `_now="$(tmuxc display-message -p -t "=$NAME" '#{session_id}:#{session_created}' 2>/dev/null)"; [ "$_now" = "$NP_TUPLE" ] || { echo "… tmux tuple changed before close; resetting." >&2; exit 0; }`; `bridge_gen_write … stop_intent="zombie-$(date +%s)"`; `tmuxc kill-session -t "=$NAME" && ! tmuxc has-session -t "=$NAME" 2>/dev/null && bridge_gen_write … stop_receipt="zombie-$(date +%s)"` (D12); then `spawn_session`.
  - `spawn_session` (D7): validate before writing — `NONCE` matches `^[0-9a-f]{32}$`; `WALL=$(( $(date +%s) * 1000 ))`, `UP="$(awk '{printf "%d",$1*1000}' "$PROCR/uptime")"`, `BOOT="$(cat "$PROCR/sys/kernel/random/boot_id")"` all non-empty numeric/uuid; `INODES="$(for f in "$CFG_ROOT"/sessions/*.json; do [ -e "$f" ] && stat -c %i "$f"; done | tr '\n' ' ')"`; write `launch_ms launch_uptime_ms launch_boot_id launch_nonce launch_inodes spawn_state=pending pid= birth= stop_receipt=` **before** `new-session`; `pane_pid="$(tmuxc new-session -d -P -F '#{pane_pid}' …)"; rc=$?`; require `rc=0`, numeric `pane_pid`, non-empty `bridge_os_birth "$pane_pid"` → write `launch_pane_pid launch_pane_birth spawn_state=started`; else `spawn_state="failed:$(date +%s)" launch_nonce= launch_ms= launch_uptime_ms= launch_boot_id= launch_inodes=` and degraded.
  - Delete `matching_claude_pids`, `CLAUDE_PAT`, `RC_LBL_PAT`, `claude_alive_in_session`, local `is_descendant`; keep the OpenCode functions and `runtime_alive_in_session`.
- [ ] **Step 5: Mutations** — bridge logic applied to opencode rows (2); old 1731–1761 left in place (4); key without tuple (8); no tuple re-read at the kill site (9); receipt before kill (18); no nonce validation (16); kill on first sighting (6).
- [ ] **Step 6: Commit** — `supervisor: claude rows on the adapter, a claim before the spawn, the target re-read before the close, and OpenCode untouched`.

---

### Task 6: Display as a fact; rename two-round to the pane; tty-checked foreground — as v4 (rename key `rename pid birth pane desired pending_since`, two rounds immediately before typing; reset on every other branch; `tty_nr`+`tpgid` both sides; degraded marker cleared on recovery).

### Task 7: Watch — the fourteen-field line, the remote socket built on the remote, kills only through `bridge-kill.py` (rc 65 → refuse, re-observe), info line on stderr asserted — as v4.

### Tasks 8–12 — OUTLINES (as v3/v4; fourteen fields; census via `--bootstrap`; ACCOUNT migration named as P0 prerequisite).

---

## Gates carried by this plan

P0 census preceded by ACCOUNT migration of every legacy row. P1b (cases A and B) before Task 11's first derive. P2 macOS twin (python3 ≥ 3.9 there too, or `bridge-kill` refuses with 69), bash 3.2 for `test/bridge-*.test.sh`. P3 manual census; Task 9 strict mode.

## Self-review

D1 → `not-applicable` + `ADAPTER` guard + `supervisor-opencode` required. D2 → old block replaced for claude rows; assertion that `SUSPECT` is absent and the zombie repair ran. D3 → bootstrap calls `bridge_answer` with `none`/`1`; empty-row claim. D4 → claim requires descent from the launch pane incarnation. D5 → tuple `$N:created`, re-read before close, spawn-absent reset on appearance. D6 → python3 pidfd, no fallback. D7 → validation before the pending write and after `new-session`. D8 → `launch_boot_id`. D9 → fields blanked unless identified. D10 → T1b inode + `launch_inodes` + mtime/startedAt in the claim. D11 → built (`610d63e`, `3862019`). D12 → intent before, receipt after success.
