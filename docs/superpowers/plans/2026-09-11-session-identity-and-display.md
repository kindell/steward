# Session Identity and Display Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Supervision identifies a session by the vendor's bridge file (ID ↔ pid+birth token ↔ pane), never by its Remote Control label; the label is rendered from the register and renamed through the existing `/rename` cycle bound to the managed pane.

**Architecture:** One new library, `lib/bridge.sh`, holds pure decision functions (classify a candidate file, fold candidates + generation into one of four answers). The Linux supervisor gathers facts (processes, panes, /proc) and asks the library; watch and liveness-host consume the same classification through `watch/bin/registry-dump` and the library. `RC_LABEL` survives only as a legacy override with precedence until the last row is migrated.

**Tech Stack:** bash 3.2-compatible shell (`set -u`, no arrays in libs), jq, tmux, Linux `/proc`; Node `node:test` for `watch/`.

**Spec:** `docs/superpowers/specs/2026-09-11-session-identity-and-display-design.md` (fb0a7d7). Read it first; every task cites the section it implements.

## Global Constraints

- Never read or log `bridgeSessionId` or `messagingSocketPath` from a bridge file. jq selects fields by name; no `.[]`, no whole-file dumps.
- Every write action (kill, `send-keys`, `kill-session`, spawn) requires an adapter answer of *identified* or *no-process*. On *identity-unknown* nothing is written.
- `pid` is never trusted alone: the OS birth token (Linux: boot id + `/proc/<pid>/stat` field 22) is compared on every use.
- No label match (`--remote-control <string>` in argv) may decide anything after Task 4. Tests stub `pgrep` to fail loudly if it is asked for a label.
- Every `send-keys` in the rename cycle targets the bridge file's exact `tmux` value (`<id>:@N.%M`), never `$NAME`.
- Config dir resolves through `registry_login_config_dir "$LOGIN" "<owner unix user>"`, never login alone.
- Tests never touch the machine: tmux, pgrep, ps, kill and `/proc` are shims/fixtures (`STEWARD_KILL`, `BRIDGE_PROC_ROOT`, `PATH`).
- Commit after every green step, with the estate's author identity: `git -c user.name="Jon Kindell" -c user.email="jon+butler@varvet.com" commit …`, ending in `Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>` and `Claude-Session: https://claude.ai/code/session_01RMVoAh7XJUuje1PCq3tEQX`.
- Work on branch `session-identity-display`. Push after each task. Merge is butler's; never merge to main here.
- Bash suites run as `bash test/<name>.test.sh`; they print `ok`/`FAIL` lines and exit non-zero on any FAIL. Watch suites run as `cd watch && npm test`.

---

## File Structure

| file | responsibility |
|---|---|
| `lib/bridge.sh` (new) | pure functions: candidate parsing, OS birth token, classification, the four-way answer, generation file read/write |
| `linux/session-supervisor-linux.sh` (modify) | gathers facts, asks `lib/bridge.sh`, acts; rename cycle bound to the pane; grace; generation writes |
| `linux/deploy-manifest` (modify) | ships `lib/bridge.sh` and `linux/bridge-census.sh` |
| `watch/bin/registry-dump` (modify) | adds `configDir` and `runtime` per session |
| `watch/lib.mjs` (modify) | `findProcessByBridge`; `findProcess` removed from decisions |
| `watch/session-watch.mjs`, `watch/restart-session.mjs` (modify) | use the bridge lookup |
| `linux/liveness-host.sh` (modify) | `agent` for claude rows from bridge classification |
| `lib/registry.sh` (modify) | `registry_session_rendered_unique`, work-rule gate, display refusal path |
| `bin/steward` (modify) | `registry session add` calls the gates; new verb `registry session derive <id>` |
| `linux/hub/enroll` (modify) | calls the gates |
| `linux/bridge-census.sh` (new) | P0: one-time bootstrap census |
| `test/bridge-classify.test.sh`, `test/bridge-answer.test.sh`, `test/bridge-generation.test.sh` (new) | unit suites for the library |
| `test/supervisor-bridge.test.sh` (new) | integration suite with shims for Task 4–6 |
| `test/identity-schema.test.sh`, `test/session-rc-label-unique.test.sh` (modify) | contract updates |
| `watch/test/lib.test.mjs` (modify) | bridge lookup tests |

---

### Task 1: `lib/bridge.sh` — candidate parsing and OS birth token

Implements spec §1 "candidate" and "verified-live/stale/unclassifiable" inputs.

**Files:**
- Create: `lib/bridge.sh`
- Test: `test/bridge-classify.test.sh`

**Interfaces:**
- Produces: `bridge_candidates <id> <sessions-dir>` → one line per accepted candidate: `path<TAB>pid<TAB>procStart<TAB>tmux<TAB>name<TAB>nameSince<TAB>sessionId<TAB>startedAt<TAB>mtime_ms`; rejected files go to stderr as `bridge: unclassifiable <path>: <reason>` and set `BRIDGE_UNCLASSIFIABLE=<count>`. rc 0 always (absence is a measurement).
- Produces: `bridge_os_birth <pid>` → `<boot_id>:<start_ticks>` on stdout, rc 1 and empty when the pid has no `/proc` entry. Honors `BRIDGE_PROC_ROOT` (default `/proc`).

- [ ] **Step 1: Write the failing test**

```bash
#!/bin/bash
# test/bridge-classify.test.sh - lib/bridge.sh reads bridge files by name, never by order,
# and turns a pid into an OS birth token it can compare later.
set -u
here="$(CDPATH= cd -- "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
pass=0; fail=0
ok()  { pass=$((pass+1)); printf '  ok   %s\n' "$1"; }
bad() { fail=$((fail+1)); printf '  FAIL %s\n     %s\n' "$1" "${2:-}"; }
is()  { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "wanted '$3', got '$2'"; fi; }
has() { case "$2" in *"$3"*) ok "$1" ;; *) bad "$1" "missing '$3' in: $2" ;; esac; }
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
. "$here/lib/bridge.sh" || { echo "cannot source lib/bridge.sh"; exit 1; }
ID="s-0000000000000001"; D="$T/sessions"; mkdir -p "$D"
mk() { # <file> <pid> <tmux> <name> [<extra-json>]
  printf '{"pid":%s,"procStart":123,"tmux":"%s","name":"%s","nameSince":1789000000000,"sessionId":"aaaa-bbbb","startedAt":1789000000000,"status":"idle","bridgeSessionId":"SECRET","messagingSocketPath":"/tmp/SECRET.sock"%s}\n' \
    "$2" "$3" "$4" "${5:-}" > "$D/$1"
}
echo "== 1. one well-formed file for the id is one candidate, secrets never on stdout =="
mk 100.json 100 "$ID:@0.%0" "Alpha→Beta"
out="$(bridge_candidates "$ID" "$D" 2>"$T/err")"
is "1a one line" "$(printf '%s\n' "$out" | grep -c .)" "1"
has "1b pid" "$out" "	100	"
has "1c tmux" "$out" "	$ID:@0.%0	"
case "$out$(cat "$T/err")" in *SECRET*) bad "1d no secret leaks" "$out" ;; *) ok "1d no secret leaks" ;; esac
echo "== 2. a file for another id is not a candidate =="
mk 101.json 101 "s-0000000000000002:@0.%0" "Other"
out="$(bridge_candidates "$ID" "$D" 2>/dev/null)"
is "2a still one line" "$(printf '%s\n' "$out" | grep -c .)" "1"
echo "== 3. the id must be delimited exactly - a prefix match is not a match =="
mk 102.json 102 "${ID}0:@0.%0" "Prefix"
out="$(bridge_candidates "$ID" "$D" 2>/dev/null)"
is "3a prefix rejected" "$(printf '%s\n' "$out" | grep -c .)" "1"
echo "== 4. malformed, symlinked and oversized files are unclassifiable, counted, named on stderr =="
printf '{"pid":103,"tmux":"%s"' "$ID:@1.%1" > "$D/103.json"            # truncated
ln -s "$D/100.json" "$D/104.json"                                        # symlink
head -c 70000 /dev/zero | tr '\0' 'x' > "$D/105.json"                    # oversized
printf '{"pid":"abc","tmux":"%s","name":"x","nameSince":1,"sessionId":"s","startedAt":1}\n' "$ID:@2.%2" > "$D/106.json"  # wrong type
out="$(bridge_candidates "$ID" "$D" 2>"$T/err")"
is "4a accepted unchanged" "$(printf '%s\n' "$out" | grep -c .)" "1"
is "4b four unclassifiable" "$BRIDGE_UNCLASSIFIABLE" "4"
has "4c truncated named" "$(cat "$T/err")" "103.json"
has "4d symlink named" "$(cat "$T/err")" "104.json"
has "4e oversized named" "$(cat "$T/err")" "105.json"
has "4f type named" "$(cat "$T/err")" "106.json"
echo "== 5. two files for one id are TWO candidates - the library never picks =="
mk 107.json 107 "$ID:@3.%3" "Second"
out="$(bridge_candidates "$ID" "$D" 2>/dev/null)"
is "5a two lines" "$(printf '%s\n' "$out" | grep -c .)" "2"
echo "== 6. OS birth token from a /proc fixture =="
P="$T/proc"; mkdir -p "$P/sys/kernel/random" "$P/4242"
printf 'boot-1111\n' > "$P/sys/kernel/random/boot_id"
printf '4242 (claude) S 1 4242 4242 0 -1 4194560 100 0 0 0 5 5 0 0 20 0 1 0 987654 1000 200 18446744073709551615\n' > "$P/4242/stat"
is "6a token" "$(BRIDGE_PROC_ROOT="$P" bridge_os_birth 4242)" "boot-1111:987654"
BRIDGE_PROC_ROOT="$P" bridge_os_birth 9999 >/dev/null 2>&1; is "6b gone pid rc 1" "$?" "1"
echo "== 7. a comm with spaces or parens in /proc stat does not shift the start field =="
mkdir -p "$P/4243"; printf '4243 (my (odd) claude) S 1 1 1 0 -1 0 0 0 0 0 0 0 0 0 20 0 1 0 555 0 0 0\n' > "$P/4243/stat"
is "7a token" "$(BRIDGE_PROC_ROOT="$P" bridge_os_birth 4243)" "boot-1111:555"
printf '\n%d passed, %d failed\n' "$pass" "$fail"; [ "$fail" -eq 0 ]
```

- [ ] **Step 2: Run to verify it fails**

Run: `bash test/bridge-classify.test.sh`
Expected: `cannot source lib/bridge.sh` and exit 1.

- [ ] **Step 3: Write the library**

```bash
#!/bin/bash
# lib/bridge.sh - the vendor's local bridge attestation, read strictly and by name.
#
# THE FILE IS AN UNDOCUMENTED VENDOR FORMAT (<CLAUDE_CONFIG_DIR>/sessions/<pid>.json).
# Measured 2026-09-11 (P1): it appears within 1 s of spawn, follows /rename within
# 1 s, is removed on clean exit and TERM, is LEFT BEHIND on KILL -9, and its `tmux`
# field records the session name AT REGISTRATION and does not follow a rename.
# Nothing here trusts it as authority: every candidate is classified, never picked.
#
# TWO FIELDS ARE NEVER READ: bridgeSessionId and messagingSocketPath. jq is given
# the fields by name, so a future secret added beside them cannot ride out.
#
# NO ARRAYS, NO LOCAL -n, NO ${var,,}: this file must run on bash 3.2 (macOS twin).
set -u

BRIDGE_MAX_BYTES="${BRIDGE_MAX_BYTES:-65536}"
BRIDGE_UNCLASSIFIABLE=0

_bridge_size() { wc -c < "$1" 2>/dev/null | tr -d ' '; }
_bridge_mtime_ms() { # portable enough: seconds*1000
  local s; s="$(stat -c %Y "$1" 2>/dev/null || stat -f %m "$1" 2>/dev/null)" || return 1
  printf '%s000' "$s"
}

# bridge_candidates <id> <sessions-dir> -> accepted candidates, one per line:
#   path pid procStart tmux name nameSince sessionId startedAt mtime_ms   (tab separated)
# Rejected files are counted in BRIDGE_UNCLASSIFIABLE and named on stderr. rc 0 always.
bridge_candidates() {
  local id="${1:-}" dir="${2:-}" f sz row
  BRIDGE_UNCLASSIFIABLE=0
  [ -n "$id" ] && [ -d "$dir" ] || return 0
  for f in "$dir"/*.json; do
    [ -e "$f" ] || continue
    if [ -L "$f" ]; then echo "bridge: unclassifiable $f: symlink" >&2; BRIDGE_UNCLASSIFIABLE=$((BRIDGE_UNCLASSIFIABLE+1)); continue; fi
    if [ ! -f "$f" ]; then echo "bridge: unclassifiable $f: not a regular file" >&2; BRIDGE_UNCLASSIFIABLE=$((BRIDGE_UNCLASSIFIABLE+1)); continue; fi
    sz="$(_bridge_size "$f")"
    if [ -z "$sz" ] || [ "$sz" -gt "$BRIDGE_MAX_BYTES" ]; then echo "bridge: unclassifiable $f: size $sz exceeds $BRIDGE_MAX_BYTES" >&2; BRIDGE_UNCLASSIFIABLE=$((BRIDGE_UNCLASSIFIABLE+1)); continue; fi
    # THE tmux FIELD DECIDES MEMBERSHIP FIRST, so a file for another row is silently
    # not ours (not an error), while a file that IS ours and is broken is named.
    row="$(jq -r --arg id "$id" '
      if type != "object" then "!notobject"
      elif ((.tmux // "") | test("^" + ($id | gsub("[.^$*+?()\\[\\]{}|\\\\-]"; "\\\\" + .)) + ":@[0-9]+\\.%[0-9]+$")) | not then "!foreign"
      elif ((.pid|type) != "number") or ((.procStart|type) != "number") or ((.name|type) != "string")
           or ((.nameSince|type) != "number") or ((.sessionId|type) != "string") or ((.startedAt|type) != "number") then "!types"
      else [(.pid|tostring), (.procStart|tostring), .tmux, .name, (.nameSince|tostring), .sessionId, (.startedAt|tostring)] | join("\t") end
    ' "$f" 2>/dev/null)" || row="!json"
    case "$row" in
      "!foreign") continue ;;
      "!json"|"!notobject"|"!types"|"")
        echo "bridge: unclassifiable $f: ${row#!}" >&2; BRIDGE_UNCLASSIFIABLE=$((BRIDGE_UNCLASSIFIABLE+1)); continue ;;
    esac
    printf '%s\t%s\t%s\n' "$f" "$row" "$(_bridge_mtime_ms "$f")"
  done
  return 0
}

# bridge_os_birth <pid> -> "<boot_id>:<start_ticks>" ; rc 1 when the pid is gone.
# Field 22 of /proc/<pid>/stat is starttime in clock ticks since boot. The comm
# field (2) may contain spaces and parentheses, so the line is split AFTER the
# last ")" - never on whitespace from the start.
bridge_os_birth() {
  local pid="${1:-}" root="${BRIDGE_PROC_ROOT:-/proc}" boot stat rest
  case "$pid" in ''|*[!0-9]*) return 1 ;; esac
  [ -r "$root/$pid/stat" ] || return 1
  boot="$(cat "$root/sys/kernel/random/boot_id" 2>/dev/null)" || return 1
  stat="$(cat "$root/$pid/stat" 2>/dev/null)" || return 1
  rest="${stat##*) }"
  # rest now begins at field 3 (state); starttime is field 22 => index 20 in rest
  set -- $rest
  [ "$#" -ge 20 ] || return 1
  printf '%s:%s' "$boot" "${20}"
}
```

- [ ] **Step 4: Run to verify it passes**

Run: `bash test/bridge-classify.test.sh`
Expected: all `ok`, `N passed, 0 failed`.

- [ ] **Step 5: Prove the guards with mutations (each must turn a test red, then be reverted)**

- Replace `elif ((.tmux // "") | test(...)) | not then "!foreign"` with a prefix test (`startswith($id)`) → 3a fails.
- Delete the symlink branch → 4b/4d fail.
- Change `${20}` to `${19}` in `bridge_os_birth` → 6a and 7a fail.

- [ ] **Step 6: Commit**

```bash
git add lib/bridge.sh test/bridge-classify.test.sh
git -c user.name="Jon Kindell" -c user.email="jon+butler@varvet.com" commit -m "bridge: the vendor's attestation read by name, never by order

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01RMVoAh7XJUuje1PCq3tEQX"
```

---

### Task 2: `lib/bridge.sh` — classification and the four-way answer

Implements spec §1 "Each candidate is classified", "The adapter's answer", and the bootstrap table.

**Files:**
- Modify: `lib/bridge.sh` (append)
- Test: `test/bridge-answer.test.sh`

**Interfaces:**
- Consumes: candidate lines from Task 1.
- Produces: `bridge_classify_candidate <alive> <uid_ok> <birth_ok> <stored_pane_has_pid> <any_pane_has_pid> <mtime_ms> <launch_ms> <gen_match>` → prints one of `live:managed`, `live:orphan`, `live:moved`, `stale`, `unclassifiable`. Inputs are `1`/`0` flags gathered by the caller (the supervisor), so the decision is testable without a machine.
- Produces: `bridge_answer <classes> <gen_state> <tmux_present> <veto> <census_done>` → prints `identified:managed`, `identified:orphan`, `identified:moved`, `no-process`, `unknown`, `wait-veto`, `grace`. `<classes>` is a space-separated list of classification words (may be empty); `<gen_state>` ∈ `none|gone-receipt|gone-noreceipt|alive|grace`; the rest are `1`/`0`.

- [ ] **Step 1: Write the failing test**

```bash
#!/bin/bash
# test/bridge-answer.test.sh - every row of the spec's bootstrap table, and every
# cell of the answer table, as a decision the library makes from flags alone.
set -u
here="$(CDPATH= cd -- "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
pass=0; fail=0
ok()  { pass=$((pass+1)); printf '  ok   %s\n' "$1"; }
bad() { fail=$((fail+1)); printf '  FAIL %s\n     %s\n' "$1" "${2:-}"; }
is()  { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "wanted '$3', got '$2'"; fi; }
. "$here/lib/bridge.sh" || exit 1
echo "== classify: alive uid birth stored any mtime launch gen =="
is "live in stored pane = managed"     "$(bridge_classify_candidate 1 1 1 1 1 2000 1000 1)" "live:managed"
is "live under another pane = moved"   "$(bridge_classify_candidate 1 1 1 0 1 2000 1000 1)" "live:moved"
is "live under no pane = orphan"       "$(bridge_classify_candidate 1 1 1 0 0 2000 1000 1)" "live:orphan"
is "dead, matches a generation = stale" "$(bridge_classify_candidate 0 1 0 0 0 2000 1000 1)" "stale"
is "dead, matches no generation = unclassifiable" "$(bridge_classify_candidate 0 1 0 0 0 2000 1000 0)" "unclassifiable"
is "alive but birth mismatch (pid reuse) = unclassifiable" "$(bridge_classify_candidate 1 1 0 1 1 2000 1000 1)" "unclassifiable"
is "alive but wrong uid = unclassifiable" "$(bridge_classify_candidate 1 0 1 1 1 2000 1000 1)" "unclassifiable"
is "file predates our launch = unclassifiable" "$(bridge_classify_candidate 1 1 1 1 1 500 1000 1)" "unclassifiable"
echo "== answer: classes gen tmux veto census =="
is "first-ever (post-census)"                 "$(bridge_answer ''                   none          0 0 1)" "no-process"
is "pre-census, no generation = unknown"      "$(bridge_answer ''                   none          0 0 0)" "unknown"
is "manual tmux before first spawn, veto empty" "$(bridge_answer ''                 none          1 0 1)" "no-process"
is "manual tmux before first spawn, veto held" "$(bridge_answer ''                  none          1 1 1)" "unknown"
is "planned stop"                             "$(bridge_answer ''                   gone-receipt  0 0 1)" "no-process"
is "unplanned exit (crash)"                   "$(bridge_answer ''                   gone-noreceipt 0 0 1)" "no-process"
is "crash but veto runtime under pane"        "$(bridge_answer ''                   gone-noreceipt 1 1 1)" "wait-veto"
is "generation alive, no attestation, in grace" "$(bridge_answer ''                 grace         1 0 1)" "grace"
is "generation alive, no attestation, past grace" "$(bridge_answer ''               alive         1 0 1)" "unknown"
is "managed"                                  "$(bridge_answer 'live:managed'       alive         1 0 1)" "identified:managed"
is "orphan"                                   "$(bridge_answer 'live:orphan'        alive         0 0 1)" "identified:orphan"
is "moved"                                    "$(bridge_answer 'live:moved'         alive         0 0 1)" "identified:moved"
is "stale only reads as none"                 "$(bridge_answer 'stale'              gone-noreceipt 0 0 1)" "no-process"
is "stale + live = identified"                "$(bridge_answer 'stale live:managed' alive         1 0 1)" "identified:managed"
is "two live = split-brain"                   "$(bridge_answer 'live:managed live:managed' alive 1 0 1)" "unknown"
is "one unclassifiable poisons the answer"    "$(bridge_answer 'unclassifiable live:managed' alive 1 0 1)" "unknown"
is "unclassifiable alone"                     "$(bridge_answer 'unclassifiable'     none          0 0 1)" "unknown"
printf '\n%d passed, %d failed\n' "$pass" "$fail"; [ "$fail" -eq 0 ]
```

- [ ] **Step 2: Run to verify it fails**

Run: `bash test/bridge-answer.test.sh`
Expected: FAIL lines with `bridge_classify_candidate: command not found`.

- [ ] **Step 3: Append the decision functions**

```bash
# ---- classification ---------------------------------------------------------
# bridge_classify_candidate <alive> <uid_ok> <birth_ok> <stored_pane_has_pid>
#                           <any_pane_has_pid> <mtime_ms> <launch_ms> <gen_match>
# All inputs are 1/0 (or numbers) gathered by the caller. Prints exactly one word.
#   live:managed   the pid is alive, ours, born as recorded, in the stored pane
#   live:orphan    alive, ours, born as recorded, under NO pane on the socket
#   live:moved     alive, ours, born as recorded, under a pane that is not the stored one
#   stale          not alive, but matches a generation we launched (KILL -9 leaves this)
#   unclassifiable everything else - never chosen, and it poisons the answer (see bridge_answer)
bridge_classify_candidate() {
  local alive="${1:-0}" uid_ok="${2:-0}" birth_ok="${3:-0}" stored="${4:-0}" any="${5:-0}" mtime="${6:-0}" launch="${7:-0}" gen="${8:-0}"
  if [ "$alive" = 1 ]; then
    [ "$uid_ok" = 1 ] && [ "$birth_ok" = 1 ] || { printf 'unclassifiable'; return 0; }
    [ "$mtime" -ge "$launch" ] 2>/dev/null || { printf 'unclassifiable'; return 0; }
    if [ "$stored" = 1 ]; then printf 'live:managed'
    elif [ "$any" = 1 ]; then printf 'live:moved'
    else printf 'live:orphan'; fi
    return 0
  fi
  if [ "$gen" = 1 ]; then printf 'stale'; else printf 'unclassifiable'; fi
}

# ---- the answer -------------------------------------------------------------
# bridge_answer <classes> <gen_state> <tmux_present> <veto> <census_done>
#   classes    space-separated words from bridge_classify_candidate (may be empty)
#   gen_state  none | gone-receipt | gone-noreceipt | alive | grace
#   tmux_present, veto, census_done  1/0
# Prints: identified:managed | identified:orphan | identified:moved | no-process |
#         unknown | wait-veto | grace
# THE VETO IS AN ACTION GATE, NOT A FIFTH IDENTITY: a no-process verdict with the
# broad runtime veto held is reported as wait-veto so the caller neither closes
# nor spawns, without pretending it does not know.
bridge_answer() {
  local classes="${1:-}" gen="${2:-none}" tmux="${3:-0}" veto="${4:-0}" census="${5:-0}"
  local w live=0 unclass=0 kind=""
  for w in $classes; do
    case "$w" in
      live:*) live=$((live+1)); kind="${w#live:}" ;;
      stale) : ;;
      *) unclass=$((unclass+1)) ;;
    esac
  done
  [ "$unclass" -eq 0 ] || { printf 'unknown'; return 0; }
  [ "$live" -le 1 ]    || { printf 'unknown'; return 0; }
  if [ "$live" -eq 1 ]; then printf 'identified:%s' "$kind"; return 0; fi
  # no live candidate
  case "$gen" in
    grace) printf 'grace'; return 0 ;;
    alive) printf 'unknown'; return 0 ;;   # our own process lives but nothing attests it
    none)  [ "$census" = 1 ] || { printf 'unknown'; return 0; } ;;
    gone-receipt|gone-noreceipt) : ;;
    *) printf 'unknown'; return 0 ;;
  esac
  if [ "$veto" = 1 ]; then printf 'wait-veto'; else printf 'no-process'; fi
}
```

- [ ] **Step 4: Run to verify it passes**

Run: `bash test/bridge-answer.test.sh` → all `ok`.

- [ ] **Step 5: Mutations**

- Remove the `[ "$unclass" -eq 0 ]` line → "one unclassifiable poisons" fails.
- Change `[ "$live" -le 1 ]` to `-le 2` → "two live = split-brain" fails.
- Remove the `mtime -ge launch` check → "file predates our launch" fails.

- [ ] **Step 6: Commit** — message `bridge: classify every candidate, answer one of four - a first match is never taken`.

---

### Task 3: `lib/bridge.sh` — the persisted launch generation

Implements spec §1 "Persisted launch generation".

**Files:**
- Modify: `lib/bridge.sh` (append)
- Test: `test/bridge-generation.test.sh`

**Interfaces:**
- Produces: `bridge_gen_path <state-dir> <id>` → `<state-dir>/<id>.generation`.
- Produces: `bridge_gen_write <state-dir> <id> key=value ...` — writes/merges keys: `pid birth procStart uid sessionId launch_ms bridge_name bridge_nameSince bridge_mtime applied applied_at stop_receipt census`. Appends `history=` bounded to the last 8 `pid:birth` pairs when `pid`/`birth` change.
- Produces: `bridge_gen_get <state-dir> <id> <key>` → value or empty; rc 1 when the file is absent.
- Produces: `bridge_gen_matches <state-dir> <id> <pid> <birth>` → rc 0 when the pair is the current one or in `history`.

- [ ] **Step 1: Write the failing test**

```bash
#!/bin/bash
# test/bridge-generation.test.sh - the generation is history and bootstrap, never a second truth.
set -u
here="$(CDPATH= cd -- "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
pass=0; fail=0
ok()  { pass=$((pass+1)); printf '  ok   %s\n' "$1"; }
bad() { fail=$((fail+1)); printf '  FAIL %s\n     %s\n' "$1" "${2:-}"; }
is()  { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "wanted '$3', got '$2'"; fi; }
. "$here/lib/bridge.sh" || exit 1
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
ID="s-0000000000000001"
echo "== 1. absent =="
bridge_gen_get "$T" "$ID" pid >/dev/null 2>&1; is "1a rc 1 when absent" "$?" "1"
echo "== 2. write and read =="
bridge_gen_write "$T" "$ID" pid=100 birth=b:1 uid=1001 launch_ms=1789000000000
is "2a pid" "$(bridge_gen_get "$T" "$ID" pid)" "100"
is "2b birth" "$(bridge_gen_get "$T" "$ID" birth)" "b:1"
echo "== 3. merge keeps unrelated keys =="
bridge_gen_write "$T" "$ID" applied="Alpha→Beta" applied_at=1789000001000
is "3a pid kept" "$(bridge_gen_get "$T" "$ID" pid)" "100"
is "3b applied" "$(bridge_gen_get "$T" "$ID" applied)" "Alpha→Beta"
echo "== 4. a new pid/birth pushes the old pair into bounded history =="
bridge_gen_write "$T" "$ID" pid=101 birth=b:2
bridge_gen_matches "$T" "$ID" 100 b:1; is "4a old pair still matches" "$?" "0"
bridge_gen_matches "$T" "$ID" 101 b:2; is "4b current matches" "$?" "0"
bridge_gen_matches "$T" "$ID" 100 b:9; is "4c wrong birth does not" "$?" "1"
i=3; while [ $i -le 12 ]; do bridge_gen_write "$T" "$ID" pid=$((100+i)) birth=b:$i; i=$((i+1)); done
bridge_gen_matches "$T" "$ID" 100 b:1; is "4d history is bounded to 8 - the oldest fell off" "$?" "1"
bridge_gen_matches "$T" "$ID" 105 b:5; is "4e a recent one is kept" "$?" "0"
echo "== 5. values with spaces and arrows survive =="
bridge_gen_write "$T" "$ID" applied="Point→Chalmers→HR Pilot"
is "5a" "$(bridge_gen_get "$T" "$ID" applied)" "Point→Chalmers→HR Pilot"
printf '\n%d passed, %d failed\n' "$pass" "$fail"; [ "$fail" -eq 0 ]
```

- [ ] **Step 2: Run to verify it fails** — `bridge_gen_get: command not found`.

- [ ] **Step 3: Append**

```bash
# ---- generation -------------------------------------------------------------
# <state-dir>/<id>.generation : key=value per line. History and bootstrap only:
# when a verified-live bridge file exists ITS fields win (spec §1). Written
# atomically (tmp + mv) so a reader never sees half a file.
bridge_gen_path() { printf '%s/%s.generation' "$1" "$2"; }

bridge_gen_get() { # <state-dir> <id> <key>
  local f; f="$(bridge_gen_path "$1" "$2")"
  [ -f "$f" ] || return 1
  sed -n "s/^$3=//p" "$f" | head -1
}

bridge_gen_matches() { # <state-dir> <id> <pid> <birth> -> rc 0 when current or in history
  local f cur hist pair="$3:$4"
  f="$(bridge_gen_path "$1" "$2")"; [ -f "$f" ] || return 1
  cur="$(sed -n 's/^pid=//p' "$f" | head -1):$(sed -n 's/^birth=//p' "$f" | head -1)"
  [ "$cur" = "$pair" ] && return 0
  hist="$(sed -n 's/^history=//p' "$f" | head -1)"
  case " $hist " in *" $pair "*) return 0 ;; esac
  return 1
}

bridge_gen_write() { # <state-dir> <id> key=value ...
  local dir="$1" id="$2" f tmp kv k v old_pid old_birth hist n
  shift 2
  f="$(bridge_gen_path "$dir" "$id")"; tmp="$f.tmp.$$"
  mkdir -p "$dir"
  old_pid="$(bridge_gen_get "$dir" "$id" pid 2>/dev/null)"; old_birth="$(bridge_gen_get "$dir" "$id" birth 2>/dev/null)"
  hist="$(bridge_gen_get "$dir" "$id" history 2>/dev/null)"
  : > "$tmp"
  [ -f "$f" ] && grep -v '^history=' "$f" > "$tmp"
  for kv in "$@"; do
    k="${kv%%=*}"; v="${kv#*=}"
    case "$k" in *[!A-Za-z0-9_]*|'') echo "bridge: generation key '$k' refused" >&2; rm -f "$tmp"; return 64 ;; esac
    grep -v "^$k=" "$tmp" > "$tmp.2"; mv "$tmp.2" "$tmp"
    printf '%s=%s\n' "$k" "$v" >> "$tmp"
    # a NEW pid pushes the OLD pair into history, bounded to the last 8
    if [ "$k" = pid ] && [ -n "$old_pid" ] && [ "$v" != "$old_pid" ] && [ -n "$old_birth" ]; then
      hist="$hist $old_pid:$old_birth"
    fi
  done
  hist="$(printf '%s\n' $hist | grep . | tail -8 | tr '\n' ' ')"; hist="${hist% }"
  [ -n "$hist" ] && printf 'history=%s\n' "$hist" >> "$tmp"
  mv -f "$tmp" "$f"
}
```

- [ ] **Step 4: Run** → all `ok`.
- [ ] **Step 5: Mutations** — change `tail -8` to `tail -20` → 4d fails; drop the `mv -f` atomicity (write directly) is not testable here; leave it, document.
- [ ] **Step 6: Commit** — `bridge: the launch generation is history and bootstrap, bounded, never a second truth`.

---

### Task 4: Supervisor — identity from the adapter, label out of decisions

Implements spec §1 in `linux/session-supervisor-linux.sh`. This is the largest task; it touches the health decision (`:1337`), the no-tmux spawn path (`:1731`), the veto/wedge path (`:1735`), the zombie path (`:1994-2005`), `reap_orphan_claude` (`:1115`), and `spawn_session` (`:1659`).

**Files:**
- Modify: `linux/session-supervisor-linux.sh`
- Modify: `linux/deploy-manifest` — add row `lib/bridge.sh                      scripts/lib/bridge.sh                755  lib` after the `lib/liveness.sh` row (line 58).
- Test: `test/supervisor-bridge.test.sh` (new; copies the shim harness shape of `test/supervisor-reap.test.sh`)

**Interfaces:**
- Consumes: `bridge_candidates`, `bridge_os_birth`, `bridge_classify_candidate`, `bridge_answer`, `bridge_gen_*` (Tasks 1–3).
- Produces (supervisor-internal): `bridge_gather` → sets `BRIDGE_ANSWER` (one of the seven words), `BRIDGE_PID`, `BRIDGE_BIRTH`, `BRIDGE_PANE` (the `tmux` field), `BRIDGE_NAME`, `BRIDGE_NAMESINCE` for an identified answer. `STEWARD_BRIDGE_GRACE_ROUNDS` (default 3).

- [ ] **Step 1: Write the failing test** (fixture shape: `test/supervisor-reap.test.sh`; the additions are a `sessions/` dir under `$HOMEDIR/.claude`, a `/proc` fixture, and a pgrep shim that **fails the test** if asked for a label)

```bash
#!/bin/bash
# test/supervisor-bridge.test.sh - the supervisor identifies its session by the bridge
# file, never by the label. Spec §1, 2026-09-11.
set -u
here="$(CDPATH= cd -- "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SUP="$here/linux/session-supervisor-linux.sh"
pass=0; fail=0
ok()  { pass=$((pass+1)); printf '  ok   %s\n' "$1"; }
bad() { fail=$((fail+1)); printf '  FAIL %s\n     %s\n' "$1" "${2:-}"; }
is()  { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "wanted '$3', got '$2'"; fi; }
has() { case "$2" in *"$3"*) ok "$1" ;; *) bad "$1" "missing '$3' in: $2" ;; esac; }
hasnt(){ case "$2" in *"$3"*) bad "$1" "unexpectedly present '$3' in: $2" ;; *) ok "$1" ;; esac; }
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
HOMEDIR="$T/home"; ROOT="$T/estate"; LIBS="$T/libs"; BIN="$T/bin"; PROC="$T/proc"
mkdir -p "$HOMEDIR/.local/bin" "$HOMEDIR/.claude/sessions" "$HOMEDIR/Projects/repo" "$LIBS" "$BIN" \
         "$ROOT/estate" "$ROOT/sessions.d" "$ROOT/entities.d" "$ROOT/accounts.d" "$ROOT/projects.d" "$ROOT/mcp.d" \
         "$PROC/sys/kernel/random" "$HOMEDIR/.local/state/fixture-supervisor"
printf 'boot-1\n' > "$PROC/sys/kernel/random/boot_id"
cat > "$ROOT/estate/steward.conf" <<'EOF'
ESTATE_NAME="fixture"
LABEL_PREFIX="com.fixture.claude"
JOB_LABEL_PREFIX="com.fixture.job"
SERVICE_LABEL_PREFIX="com.fixture.svc"
RC_LABEL_PREFIX="Fixture: "
STATE_DIR_NAME="fixture-supervisor"
EOF
printf 'NAME="Alpha"\nMEMBERS="a"\n' > "$ROOT/entities.d/alpha.conf"
cp "$here/lib/registry.sh" "$here/lib/mcprender.sh" "$here/lib/mcpspawn.sh" "$here/lib/bridge.sh" "$LIBS/"
printf '#!/bin/sh\nexit 0\n' > "$HOMEDIR/.local/bin/claude"; chmod 755 "$HOMEDIR/.local/bin/claude"
ID="s-0000000000000001"; LABEL='Fixture: alpha'
cat > "$ROOT/sessions.d/$ID.conf" <<EOF
OWNER="a"
HOST="h1"
DOMAIN="alpha"
REPO_PATH="$HOMEDIR/Projects/repo"
ID="$ID"
RC_LABEL="$LABEL"
EOF
PROCTAB="$T/proctab"; PANES_ALL="$T/panes-all"; PANES_MINE="$T/panes-mine"; HAS_SESSION="$T/has-session"
export PROCTAB PANES_ALL PANES_MINE HAS_SESSION
# tmux: has-session obeys $HAS_SESSION; list-panes -a -> PANES_ALL; -s -t =ID -> PANES_MINE;
# display-message -t '<id>:@N.%M' '#{pane_pid}' -> first line of PANES_MINE (the stored pane)
cat > "$BIN/tmux" <<'EOF'
printf '%s\n' "$*" >> "$TMUX_LOG"
argv=("$@"); [ "${argv[0]:-}" = "-S" ] && argv=("${argv[@]:2}")
case "${argv[0]:-}" in
  has-session) [ -f "$HAS_SESSION" ] ;;
  list-panes) for a in "${argv[@]}"; do [ "$a" = "-a" ] && { cat "$PANES_ALL"; exit 0; }; done; cat "$PANES_MINE" ;;
  display-message) head -1 "$PANES_MINE" ;;
  *) exit 0 ;;
esac
EOF
# pgrep: any -f with "remote-control" is a LABEL MATCH - forbidden after Task 4; record and fail loudly
cat > "$BIN/pgrep" <<'EOF'
pat=""; prev=""; for a in "$@"; do [ "$prev" = "-f" ] && pat="$a"; prev="$a"; done
printf '%s\n' "$pat" >> "$PGREP_LOG"
case "$pat" in *remote-control*) echo "LABEL PGREP" >> "$LABEL_LOG";; esac
found=0; while read -r pid ppid argv; do case "$pid" in ""|\#*) continue;; esac
  printf '%s' "$argv" | grep -Eq -- "$pat" && { printf '%s\n' "$pid"; found=1; }; done < "$PROCTAB"; [ "$found" = 1 ]
EOF
cat > "$BIN/ps" <<'EOF'
pid=""; prev=""; want=""; for a in "$@"; do [ "$prev" = "-p" ] && pid="$a"; [ "$prev" = "-o" ] && want="$a"; prev="$a"; done
while read -r p pp rest; do case "$p" in ""|\#*) continue;; esac
  [ "$p" = "$pid" ] && { case "$want" in uid=) printf ' 1001\n';; *) printf ' %s\n' "$pp";; esac; exit 0; }; done < "$PROCTAB"; exit 1
EOF
printf '#!/bin/sh\nprintf "%%s\\n" "$1" >> "$KILL_LOG"\n' > "$BIN/killrec"
chmod 755 "$BIN/tmux" "$BIN/pgrep" "$BIN/ps" "$BIN/killrec"
export TMUX_LOG="$T/tmux.log" PGREP_LOG="$T/pgrep.log" KILL_LOG="$T/kill.log" LABEL_LOG="$T/label.log"
CLAUDE="$HOMEDIR/.local/bin/claude"
proc() { # <pid> <start_ticks>  -> /proc fixture entry (alive)
  mkdir -p "$PROC/$1"; printf '%s (claude) S 1 %s %s 0 -1 0 0 0 0 0 0 0 0 0 20 0 1 0 %s 0 0 0\n' "$1" "$1" "$1" "$2" > "$PROC/$1/stat"
}
bridge() { # <pid> <pane> <name>
  printf '{"pid":%s,"procStart":%s,"tmux":"%s","name":"%s","nameSince":1789000000000,"sessionId":"t-1","startedAt":1789000000000,"status":"idle"}\n' \
    "$1" "$1" "$2" "$3" > "$HOMEDIR/.claude/sessions/$1.json"
}
gen() { STEWARD_BRIDGE_UID=1001 bash -c ". '$LIBS/bridge.sh'; bridge_gen_write '$HOMEDIR/.local/state/fixture-supervisor' '$ID' $*"; }
run() {
  : > "$TMUX_LOG"; : > "$PGREP_LOG"; : > "$KILL_LOG"; : > "$LABEL_LOG"
  HOME="$HOMEDIR" STEWARD_ESTATE_ROOT="$ROOT" STEWARD_CONFIG_FILE="$T/no-such-config" \
  STEWARD_REGISTRY_LIB="$LIBS/registry.sh" STEWARD_BRIDGE_LIB="$LIBS/bridge.sh" \
  STEWARD_TMUX_SOCKET="$T/fixture.sock" STEWARD_KILL="$BIN/killrec" BRIDGE_PROC_ROOT="$PROC" \
  STEWARD_BRIDGE_UID=1001 STEWARD_BRIDGE_GRACE_ROUNDS=2 PATH="$BIN:$PATH" \
  bash "$SUP" "$ID" >"$T/out" 2>&1; echo $? > "$T/rc"
}
reset() { rm -rf "$PROC"/[0-9]* "$HOMEDIR/.claude/sessions"/* "$HOMEDIR/.local/state/fixture-supervisor"/*; : > "$PROCTAB"; : > "$PANES_ALL"; : > "$PANES_MINE"; rm -f "$HAS_SESSION"; }
census() { gen census=1; }

echo "== 1. managed: bridge file names a live pid in the stored pane; display changed - still healthy, no label pgrep =="
reset; census; touch "$HAS_SESSION"
printf '4242 1 -bash\n4243 4242 %s --remote-control "SOMETHING ELSE ENTIRELY"\n' "$CLAUDE" > "$PROCTAB"
printf '4242\n' > "$PANES_MINE"; printf '4242\n' > "$PANES_ALL"; proc 4243 111; bridge 4243 "$ID:@0.%0" "Old Name"
gen pid=4243 birth=boot-1:111 uid=1001 launch_ms=1
run
is "1a rc 0" "$(cat "$T/rc")" "0"
hasnt "1b no ZOMBIE verdict" "$(cat "$T/out")" "ZOMBIE"
hasnt "1c no kill" "$(cat "$KILL_LOG")" "4243"
is "1d pgrep never asked for a label" "$(grep -c . "$LABEL_LOG")" "0"

echo "== 2. a second claude in another pane while the managed one is dead -> not alive; nothing killed =="
reset; census; touch "$HAS_SESSION"
printf '4242 1 -bash\n4300 1 -bash\n4301 4300 %s --remote-control "x"\n' "$CLAUDE" > "$PROCTAB"
printf '4242\n4300\n' > "$PANES_MINE"; printf '4242\n4300\n' > "$PANES_ALL"
gen pid=4243 birth=boot-1:111 uid=1001 launch_ms=1   # 4243 is gone: no /proc, no bridge
run
hasnt "2a the other claude is not killed" "$(cat "$KILL_LOG")" "4301"
has "2b not healthy: the round does not clear as managed" "$(cat "$T/out")" "no-process"

echo "== 3. moved: live pid under a pane that is not the stored one -> nothing written, alarm =="
reset; census; touch "$HAS_SESSION"
printf '4242 1 -bash\n4400 1 -bash\n4401 4400 %s\n' "$CLAUDE" > "$PROCTAB"
printf '4242\n' > "$PANES_MINE"; printf '4242\n4400\n' > "$PANES_ALL"; proc 4401 222; bridge 4401 "$ID:@0.%0" "N"
gen pid=4401 birth=boot-1:222 uid=1001 launch_ms=1
run
is "3a nothing killed" "$(grep -c . "$KILL_LOG")" "0"
has "3b moved named" "$(cat "$T/out")" "moved"
hasnt "3c no spawn" "$(cat "$TMUX_LOG")" "new-session"

echo "== 4. orphan: live pid under NO pane, tmux gone -> reaped by pid, then respawn allowed next round =="
reset; census
printf '4500 1 %s\n' "$CLAUDE" > "$PROCTAB"; : > "$PANES_ALL"; proc 4500 333; bridge 4500 "$ID:@0.%0" "N"
gen pid=4500 birth=boot-1:333 uid=1001 launch_ms=1
run
has "4a orphan reaped" "$(cat "$KILL_LOG")" "4500"

echo "== 5. stale: KILL -9 left a file; pid gone; matches generation -> respawn after two rounds =="
reset; census
bridge 4600 "$ID:@0.%0" "N"      # no /proc entry: dead
gen pid=4600 birth=boot-1:444 uid=1001 launch_ms=1
run; run
has "5a respawned" "$(cat "$TMUX_LOG")" "new-session"
[ -f "$HOMEDIR/.claude/sessions/4600.json" ] && ok "5b the vendor's stale file is not deleted by us" || bad "5b the vendor's stale file is not deleted by us"

echo "== 6. split-brain: two live files for the id -> nothing written =="
reset; census; touch "$HAS_SESSION"
printf '4242 1 -bash\n4701 4242 %s\n4702 4242 %s\n' "$CLAUDE" "$CLAUDE" > "$PROCTAB"; printf '4242\n' > "$PANES_MINE"; printf '4242\n' > "$PANES_ALL"
proc 4701 1; proc 4702 2; bridge 4701 "$ID:@0.%0" "A"; bridge 4702 "$ID:@0.%0" "B"
gen pid=4701 birth=boot-1:1 uid=1001 launch_ms=1
run
is "6a nothing killed" "$(grep -c . "$KILL_LOG")" "0"; has "6b split-brain named" "$(cat "$T/out")" "split-brain"

echo "== 7. malformed + live -> unknown, nothing written =="
reset; census; touch "$HAS_SESSION"
printf '4242 1 -bash\n4801 4242 %s\n' "$CLAUDE" > "$PROCTAB"; printf '4242\n' > "$PANES_MINE"; printf '4242\n' > "$PANES_ALL"
proc 4801 5; bridge 4801 "$ID:@0.%0" "A"; printf '{"pid":' > "$HOMEDIR/.claude/sessions/4802.json"
gen pid=4801 birth=boot-1:5 uid=1001 launch_ms=1
run
is "7a nothing killed" "$(grep -c . "$KILL_LOG")" "0"; has "7b unknown" "$(cat "$T/out")" "identity-unknown"

echo "== 8. pre-census existing row, no generation -> unknown, no spawn =="
reset
run
hasnt "8a no spawn" "$(cat "$TMUX_LOG")" "new-session"; has "8b census named" "$(cat "$T/out")" "census"

echo "== 9. post-census first-ever -> exactly one spawn =="
reset; census
run
is "9a one new-session" "$(grep -c new-session "$TMUX_LOG")" "1"

echo "== 10. grace: just spawned, no bridge yet -> nothing for N rounds, then degraded, still nothing =="
reset; census; touch "$HAS_SESSION"
printf '4242 1 -bash\n4901 4242 %s\n' "$CLAUDE" > "$PROCTAB"; printf '4242\n' > "$PANES_MINE"; printf '4242\n' > "$PANES_ALL"; proc 4901 7
gen pid=4901 birth=boot-1:7 uid=1001 launch_ms=1 grace_rounds=0
run; has "10a grace" "$(cat "$T/out")" "grace"; run; run
has "10b degraded after grace" "$(cat "$T/out")" "degraded"
is "10c never killed" "$(grep -c . "$KILL_LOG")" "0"
printf '\n%d passed, %d failed\n' "$pass" "$fail"; [ "$fail" -eq 0 ]
```

- [ ] **Step 2: Run to verify it fails** — `bash test/supervisor-bridge.test.sh`: 1d fails (label pgrep is asked today), 3/6/7 write or misclassify, 8 spawns.

- [ ] **Step 3: Implement in the supervisor**

3a. Load the library beside the registry (after line 81, where `_reg_ok=1` is set):

```bash
BRIDGE_LIB="${STEWARD_BRIDGE_LIB:-$(dirname "$REG_LIB")/bridge.sh}"
if ! . "$BRIDGE_LIB" 2>/dev/null || ! declare -F bridge_answer >/dev/null 2>&1; then
  echo "session-supervisor: $NAME — REFUSING to start: $BRIDGE_LIB does not define bridge_answer — deploy the product first." >&2
  exit 78
fi
BRIDGE_DIR="$CFG_ROOT/sessions"          # CFG_ROOT is resolved at :360-362 through LOGIN + owner
BRIDGE_UID="${STEWARD_BRIDGE_UID:-$(id -u)}"
GRACE_ROUNDS="${STEWARD_BRIDGE_GRACE_ROUNDS:-3}"
```

3b. Add the fact gatherer after `runtime_alive_in_session` (after line 1038):

```bash
# bridge_gather - collect the facts lib/bridge.sh decides on, and set BRIDGE_ANSWER.
# Every fact is measured here, once per round, and the DECISION is the library's.
bridge_gather() {
  BRIDGE_ANSWER=""; BRIDGE_PID=""; BRIDGE_BIRTH=""; BRIDGE_PANE=""; BRIDGE_NAME=""; BRIDGE_NAMESINCE=""
  local classes="" line path pid pstart tmuxf name since sid started mtime
  local alive uid_ok birth_ok stored any gen_ok birth stored_pane_pid p all_panes tmux_present veto census gen_state launch_ms
  all_panes="$(tmuxc list-panes -a -F '#{pane_pid}' 2>/dev/null)"
  tmuxc has-session -t "=$NAME" 2>/dev/null && tmux_present=1 || tmux_present=0
  launch_ms="$(bridge_gen_get "$STATE_DIR" "$NAME" launch_ms 2>/dev/null || printf 0)"
  census="$(bridge_gen_get "$STATE_DIR" "$NAME" census 2>/dev/null || printf 0)"; [ "$census" = 1 ] || census=0
  while IFS="$(printf '\t')" read -r path pid pstart tmuxf name since sid started mtime; do
    [ -n "$path" ] || continue
    alive=0; uid_ok=0; birth_ok=0; stored=0; any=0; gen_ok=0
    if birth="$(bridge_os_birth "$pid")"; then
      alive=1
      [ "$(ps -o uid= -p "$pid" 2>/dev/null | tr -d ' ')" = "$BRIDGE_UID" ] && uid_ok=1
      # birth_ok: the generation recorded this pid with this birth, OR no generation yet claims this pid (fresh registration during grace)
      if bridge_gen_matches "$STATE_DIR" "$NAME" "$pid" "$birth"; then birth_ok=1
      elif [ -z "$(bridge_gen_get "$STATE_DIR" "$NAME" pid 2>/dev/null)" ]; then birth_ok=1
      elif [ "$(bridge_gen_get "$STATE_DIR" "$NAME" pid 2>/dev/null)" != "$pid" ]; then birth_ok=1   # a new pid we have not recorded yet
      fi
      stored_pane_pid="$(tmuxc display-message -p -t "$tmuxf" '#{pane_pid}' 2>/dev/null)"
      [ -n "$stored_pane_pid" ] && is_descendant "$pid" "$stored_pane_pid" && stored=1
      for p in $all_panes; do is_descendant "$pid" "$p" && { any=1; break; }; done
    else
      bridge_gen_matches "$STATE_DIR" "$NAME" "$pid" "boot-any:$pstart" 2>/dev/null && gen_ok=1
      [ "$(bridge_gen_get "$STATE_DIR" "$NAME" pid 2>/dev/null)" = "$pid" ] && gen_ok=1
    fi
    c="$(bridge_classify_candidate "$alive" "$uid_ok" "$birth_ok" "$stored" "$any" "$mtime" "$launch_ms" "$gen_ok")"
    classes="$classes $c"
    case "$c" in live:*) BRIDGE_PID="$pid"; BRIDGE_BIRTH="$birth"; BRIDGE_PANE="$tmuxf"; BRIDGE_NAME="$name"; BRIDGE_NAMESINCE="$since" ;; esac
  done <<EOF
$(bridge_candidates "$NAME" "$BRIDGE_DIR" 2>>"$STATE_DIR/$NAME.bridge-stderr")
EOF
  [ "${BRIDGE_UNCLASSIFIABLE:-0}" -eq 0 ] || classes="$classes unclassifiable"
  # generation state
  gen_state=none
  if gp="$(bridge_gen_get "$STATE_DIR" "$NAME" pid 2>/dev/null)" && [ -n "$gp" ]; then
    if bridge_os_birth "$gp" >/dev/null 2>&1 && [ "$(bridge_os_birth "$gp")" = "$(bridge_gen_get "$STATE_DIR" "$NAME" birth)" ]; then
      gr="$(bridge_gen_get "$STATE_DIR" "$NAME" grace_rounds 2>/dev/null || printf 99)"
      if [ "${gr:-99}" -lt "$GRACE_ROUNDS" ]; then gen_state=grace; bridge_gen_write "$STATE_DIR" "$NAME" grace_rounds=$((gr+1)); else gen_state=alive; fi
    elif [ -n "$(bridge_gen_get "$STATE_DIR" "$NAME" stop_receipt 2>/dev/null)" ]; then gen_state=gone-receipt
    else gen_state=gone-noreceipt; fi
  fi
  runtime_alive_in_session && veto=1 || veto=0
  BRIDGE_ANSWER="$(bridge_answer "$classes" "$gen_state" "$tmux_present" "$veto" "$census")"
  case "$BRIDGE_ANSWER" in
    identified:managed) rm -f "$STATE_DIR/$NAME.degraded"
      bridge_gen_write "$STATE_DIR" "$NAME" pid="$BRIDGE_PID" birth="$BRIDGE_BIRTH" uid="$BRIDGE_UID" bridge_name="$BRIDGE_NAME" bridge_nameSince="$BRIDGE_NAMESINCE" grace_rounds="$GRACE_ROUNDS" ;;
    identified:moved) echo "session-supervisor: $NAME — identified but MOVED: pid $BRIDGE_PID lives under a pane that is not $BRIDGE_PANE. Nothing written. Restore the tmux name '$NAME' or stop it deliberately." >&2 ;;
    unknown)
      case "$classes" in *live:*live:*) echo "session-supervisor: $NAME — identity-unknown: split-brain, more than one live bridge file for this id. Nothing written." >&2 ;;
                        *) echo "session-supervisor: $NAME — identity-unknown ($classes / gen=$gen_state / census=$census). Nothing written." >&2 ;; esac
      [ "$census" = 1 ] || echo "session-supervisor: $NAME — no bootstrap census recorded for this row: run linux/bridge-census.sh before supervision may act." >&2 ;;
    grace) echo "session-supervisor: $NAME — grace: spawned, waiting for the bridge registration." >&2 ;;
  esac
  if [ "$gen_state" = alive ] && [ "$BRIDGE_ANSWER" = unknown ] && [ ! -f "$STATE_DIR/$NAME.degraded" ]; then
    touch "$STATE_DIR/$NAME.degraded"; echo "session-supervisor: $NAME — DEGRADED: our process lives but nothing attests it after $GRACE_ROUNDS rounds." >&2
  fi
}
```

3c. Replace the health decision. Line 1337 `if claude_alive_in_session; then` becomes:

```bash
bridge_gather
if [ "$BRIDGE_ANSWER" = "identified:managed" ]; then
```

3d. Replace the no-tmux / veto / suspect block at lines 1731-1743 with:

```bash
case "$BRIDGE_ANSWER" in
  identified:managed) : ;;                     # handled above
  identified:moved|unknown|grace) exit 0 ;;    # nothing written on these, ever
  wait-veto) rm -f "$SUSPECT"; echo "session-supervisor: $NAME — no-process, but a runtime still lives under the pane; waiting." >&2; exit 0 ;;
  identified:orphan)
    reap_orphan_claude; exit 0 ;;
  no-process)
    if ! tmuxc has-session -t "=$NAME" 2>/dev/null; then spawn_session; exit 0; fi
    if [ ! -f "$SUSPECT" ]; then touch "$SUSPECT"; exit 0; fi ;;
esac
```

3e. `reap_orphan_claude` (line 1115) becomes ID-bound:

```bash
reap_orphan_claude() {
  [ "$BRIDGE_ANSWER" = "identified:orphan" ] || return 0
  [ -n "$BRIDGE_PID" ] || return 0
  [ "$(bridge_os_birth "$BRIDGE_PID" 2>/dev/null)" = "$BRIDGE_BIRTH" ] || { echo "session-supervisor: $NAME — orphan $BRIDGE_PID changed birth token between decision and kill; not touched." >&2; return 0; }
  ${STEWARD_KILL:-kill} "$BRIDGE_PID" 2>/dev/null && echo "session-supervisor: $NAME — reaped orphan $BRIDGE_PID ($BRIDGE_BIRTH): under no pane on the socket." >&2
}
```

3f. `spawn_session` (line 1659): remove the `reap_orphan_claude` call (the orphan path calls it explicitly now); after `tmuxc new-session …` write the generation:

```bash
bridge_gen_write "$STATE_DIR" "$NAME" launch_ms="$(date +%s)000" grace_rounds=0 stop_receipt=
```

3g. Delete `matching_claude_pids`, `CLAUDE_PAT`, `RC_LBL_PAT` and `claude_alive_in_session` (lines 951-968, 989-999). `RUNTIME_VETO_PAT` and `runtime_alive_in_session` stay.

3h. The zombie block (lines 1994-2005): keep the kill-session + spawn, but it is reached only via `no-process` with `$SUSPECT` present; write `stop_receipt=zombie-<epoch>` to the generation before `kill-session`.

- [ ] **Step 4: Run** — `bash test/supervisor-bridge.test.sh` and the whole existing supervisor suite set: `for t in test/supervisor-*.test.sh; do bash "$t" || echo "RED: $t"; done`. `test/supervisor-reap.test.sh` will go red on claim 2/3 (label-based orphan reap) — **rewrite those two claims** to plant a bridge file for the orphan instead of relying on the label, and add the moved case. Expected: all green.

- [ ] **Step 5: Mutations** — re-add a `pgrep -f "$RC_LABEL"` anywhere in the decision path → 1d fails. Make `bridge_answer` return `identified:orphan` for moved → 3a fails (kill). Skip the census check → 8a fails.

- [ ] **Step 6: Commit** — `supervisor: identity is the bridge file, never the label - four answers, nothing written on unknown`. Push.

---

### Task 5: Display from the registry; refusal instead of slug fallback

Implements spec §2 first paragraph and §3 "Refusal is asymmetric" (new-spawn half), §4 RC-free alignment.

**Files:**
- Modify: `linux/session-supervisor-linux.sh:677-681` and `:703-704`
- Modify: `lib/registry.sh` `registry_session_display` (:3925-3991): when `RC_LABEL` line is present and **empty**, still derive from target for `--name` use — expose a second function `registry_session_rc_enabled <id>` → rc 0 unless `RC_LABEL=""`.
- Test: `test/registry-session-display.test.sh` (extend) and `test/supervisor-bridge.test.sh` (extend)

**Interfaces:**
- Produces: `registry_session_rc_enabled <id>` → rc 0 when the row is RC-enabled (no `RC_LABEL` line, or a non-empty one), rc 1 when `RC_LABEL=""`.

- [ ] **Step 1: Failing tests** — append to `test/registry-session-display.test.sh`:

```bash
echo "== rc-enabled: absent line yes, non-empty yes, empty no =="
mk_row nolabel;   registry_session_rc_enabled nolabel;   is "absent = enabled" "$?" "0"
mk_row_label lab "Some→Thing"; registry_session_rc_enabled lab; is "non-empty = enabled" "$?" "0"
mk_row_label free "";          registry_session_rc_enabled free; is "empty = RC-free" "$?" "1"
echo "== display for an RC-free row with a target is still derived (for --name) =="
is "free derives" "$(registry_session_display free)" "Alpha→Thing"
echo "== a target that does not resolve REFUSES - no prefix+slug invention =="
printf 'ID="broken"\nSLUG="broken"\nOWNER="a"\nHOST="h1"\nTARGET_PROJECT="no-such-project"\n' > "$ROOT/sessions.d/broken.conf"
registry_session_display broken >/dev/null 2>"$T/err"; rc=$?
[ "$rc" -ne 0 ] && ok "broken refuses" || bad "broken refuses" "rc 0"
has "names the link" "$(cat "$T/err")" "no-such-project"
```
(`mk_row`/`mk_row_label` are the suite's existing helpers; use their real names as found in the file.)

And to `test/supervisor-bridge.test.sh`:

```bash
echo "== 11. no RC_LABEL line + unresolvable target -> refuse spawn rc 78, name the link =="
reset; census
printf 'OWNER="a"\nHOST="h1"\nDOMAIN="alpha"\nREPO_PATH="%s/Projects/repo"\nID="%s"\nTARGET_PROJECT="ghost"\n' "$HOMEDIR" "$ID" > "$ROOT/sessions.d/$ID.conf"
run; is "11a rc 78" "$(cat "$T/rc")" "78"; has "11b names ghost" "$(cat "$T/out")" "ghost"; hasnt "11c no spawn" "$(cat "$TMUX_LOG")" "new-session"
echo "== 12. RC_LABEL=\"\" is RC-free: no --remote-control, --name carries the display =="
reset; census
printf 'NAME="Thing"\nPARENT="alpha"\n' > "$ROOT/projects.d/thing.conf"
printf 'OWNER="a"\nHOST="h1"\nDOMAIN="alpha"\nREPO_PATH="%s/Projects/repo"\nID="%s"\nTARGET_PROJECT="thing"\nRC_LABEL=""\n' "$HOMEDIR" "$ID" > "$ROOT/sessions.d/$ID.conf"
run; hasnt "12a no remote-control" "$(cat "$TMUX_LOG")" "remote-control"; has "12b name is derived" "$(cat "$TMUX_LOG")" "--name \"Alpha→Thing\""
```

- [ ] **Step 2: Run** → red.

- [ ] **Step 3: Implement**

`lib/registry.sh`, after `registry_session_display`:

```bash
# registry_session_rc_enabled <id> - rc 0 unless the row says RC_LABEL="" (the RC-FREE choice).
# An ABSENT line means "rendered" and is RC-enabled; only the deliberate empty string opts out.
registry_session_rc_enabled() {
  local conf; conf="$(registry_dir)/${1:-}.conf"
  [ -f "$conf" ] || return 1
  if grep -q '^RC_LABEL=""$' "$conf" 2>/dev/null; then return 1; fi
  return 0
}
```

In `registry_session_display`, the branch `if [ -n "$label" ]; then … fi` already falls through on empty to the target derivation — leave it. Remove the final `printf '%s\n' "$_prefix$slug"` fallback **only when a target exists but failed**: `registry_display_for` already returns non-zero and propagates (`|| return $?`) — the fallback is reached only with no target at all, which is the legacy RC-free-no-target case. Keep that one; it is byte-identical behaviour for legacy rows.

Supervisor `:677-681` becomes:

```bash
if registry_session_rc_enabled "$NAME"; then
  RC_LABEL="$(registry_session_display "$NAME" 2>"$STATE_DIR/$NAME.display-stderr")" || {
    echo "session-supervisor: $NAME — REFUSING to start: the display does not derive: $(cat "$STATE_DIR/$NAME.display-stderr")" >&2
    exit 78
  }
else
  RC_LABEL=""
fi
```
and `:703-704` becomes:

```bash
SESSION_NAME="$(sed -n 's/^SESSION_NAME="\(.*\)"/\1/p' "$CONF" 2>/dev/null | head -1)"
[ -n "$SESSION_NAME" ] || SESSION_NAME="$(registry_session_display "$NAME" 2>/dev/null || printf '%s' "$RC_LABEL")"
```

- [ ] **Step 4: Run** the two suites → green. Run `bash test/registry-session-display.test.sh` fully.
- [ ] **Step 5: Mutation** — restore the `$RC_PREFIX$NAME` fallback → 11a/11b fail.
- [ ] **Step 6: Commit** — `display: the supervisor asks the registry, and a display that does not derive refuses the spawn`.

---

### Task 6: The rename cycle bound to the managed pane; applied = receipt

Implements spec §2 "Rename reuses the existing cycle", "Receipt", "Last-applied state"; §3 host reservation of pending names is Task 9.

**Files:**
- Modify: `linux/session-supervisor-linux.sh` — `type_line` (:1283), the cycle (:1365-1403), `spawn_session` RENAME_PENDING write (:1677), `rename_receipt_seen` use.
- Test: `test/supervisor-bridge.test.sh` (extend with a shell canary)

**Interfaces:**
- `type_line <text>` gains a first argument: the exact pane target. Signature becomes `type_line <pane-target> <text>`.
- New `pane_foreground_is_managed <pane-target> <pid>` → rc 0 when the pane's `#{pane_current_command}` is `claude` **and** the tty's foreground pgid (`/proc/<pane_pid>/stat` field 8) equals the managed pid's pgid (field 5). Both read through `BRIDGE_PROC_ROOT`.

- [ ] **Step 1: Failing tests**

```bash
echo "== 13. rename pending: desired != applied -> /rename typed to the EXACT pane, canary untouched =="
reset; census; touch "$HAS_SESSION"
printf 'NAME="Thing"\nPARENT="alpha"\n' > "$ROOT/projects.d/thing.conf"
printf 'OWNER="a"\nHOST="h1"\nDOMAIN="alpha"\nREPO_PATH="%s/Projects/repo"\nID="%s"\nTARGET_PROJECT="thing"\n' "$HOMEDIR" "$ID" > "$ROOT/sessions.d/$ID.conf"
# window 0 = managed claude (pane pid 4242), window 1 = a shell canary that is CURRENT (pane pid 4250)
printf '4242 1 -bash\n4243 4242 %s\n4250 1 -bash\n' "$CLAUDE" > "$PROCTAB"; printf '4242\n4250\n' > "$PANES_MINE"; printf '4242\n4250\n' > "$PANES_ALL"
proc 4243 111; mkdir -p "$PROC/4242"; printf '4242 (bash) S 1 4242 4242 0 4243 0 0 0 0 0 0 0 0 0 20 0 1 0 100 0 0 0\n' > "$PROC/4242/stat"
printf '4243 (claude) S 4242 4243 4242 0 4243 0 0 0 0 0 0 0 0 0 20 0 1 0 111 0 0 0\n' > "$PROC/4243/stat"
bridge 4243 "$ID:@0.%0" "Old"
gen pid=4243 birth=boot-1:111 uid=1001 launch_ms=1 applied="Old" grace_rounds=9
# tmux shim: capture-pane on the exact pane returns the receipt only after send-keys was seen
cat > "$BIN/tmux" <<'EOF'
printf '%s\n' "$*" >> "$TMUX_LOG"
argv=("$@"); [ "${argv[0]:-}" = "-S" ] && argv=("${argv[@]:2}")
case "${argv[0]:-}" in
  has-session) [ -f "$HAS_SESSION" ] ;;
  list-panes) for a in "${argv[@]}"; do [ "$a" = "-a" ] && { cat "$PANES_ALL"; exit 0; }; done; cat "$PANES_MINE" ;;
  display-message) case "$*" in *pane_current_command*) echo claude;; *) head -1 "$PANES_MINE";; esac ;;
  send-keys) tgt=""; prev=""; for a in "${argv[@]}"; do [ "$prev" = "-t" ] && tgt="$a"; prev="$a"; done; printf '%s\n' "$tgt" >> "$SENDKEYS_TARGETS" ;;
  capture-pane) grep -q . "$SENDKEYS_TARGETS" 2>/dev/null && echo "Session renamed to: Alpha→Thing" ;;
  *) exit 0 ;;
esac
EOF
chmod 755 "$BIN/tmux"; export SENDKEYS_TARGETS="$T/sendkeys.targets"; : > "$SENDKEYS_TARGETS"
run
is "13a every send-keys went to the exact pane" "$(sort -u "$SENDKEYS_TARGETS" | tr '\n' ' ')" "$ID:@0.%0 "
hasnt "13b never to the bare session name" "$(cat "$SENDKEYS_TARGETS")" "^$ID$"
run
is "13c applied updated from the receipt" "$(bash -c ". '$LIBS/bridge.sh'; bridge_gen_get '$HOMEDIR/.local/state/fixture-supervisor' '$ID' applied")" "Alpha→Thing"
echo "== 14. foreground is a subprocess, not claude -> nothing typed this round =="
: > "$SENDKEYS_TARGETS"; sed -i 's/echo claude/echo vim/' "$BIN/tmux"
gen applied="Old"
run
is "14a nothing typed" "$(grep -c . "$SENDKEYS_TARGETS")" "0"
```

- [ ] **Step 2: Run** → red (today `send-keys -t $NAME`).

- [ ] **Step 3: Implement**

```bash
type_line() { # <pane-target> <text>
  tmuxc send-keys -t "$1" -l "$2" 2>/dev/null
  sleep "${STEWARD_KEY_SETTLE_SEC:-2}"
  tmuxc send-keys -t "$1" Enter 2>/dev/null
  TYPED_THIS_ROUND=1
}
# pane_foreground_is_managed <pane-target> <managed-pid> - the pane's foreground is the managed claude:
# tmux reports claude as the current command AND the tty's foreground process group is the managed pid's.
pane_foreground_is_managed() {
  local pane_pid fg mypg root="${BRIDGE_PROC_ROOT:-/proc}"
  [ "$(tmuxc display-message -p -t "$1" '#{pane_current_command}' 2>/dev/null)" = "claude" ] || return 1
  pane_pid="$(tmuxc display-message -p -t "$1" '#{pane_pid}' 2>/dev/null)"; [ -n "$pane_pid" ] || return 1
  fg="$(set -- $(sed 's/^.*) //' "$root/$pane_pid/stat" 2>/dev/null); printf '%s' "${6:-}")"   # field 8 tpgid
  mypg="$(set -- $(sed 's/^.*) //' "$root/$2/stat" 2>/dev/null); printf '%s' "${3:-}")"        # field 5 pgrp
  [ -n "$fg" ] && [ "$fg" = "$mypg" ]
}
```

The cycle (replacing :1365-1403), inside the `identified:managed` branch:

```bash
DESIRED="$RC_LABEL"                                   # rendered or legacy, per Task 5
APPLIED="$(bridge_gen_get "$STATE_DIR" "$NAME" applied 2>/dev/null)"
if [ -n "$DESIRED" ] && [ "$DESIRED" != "$APPLIED" ]; then
  printf '%s\n' "$DESIRED" > "$RENAME_PENDING"
  _rn_tries="$(bridge_gen_get "$STATE_DIR" "$NAME" rename_tries 2>/dev/null || printf 0)"
  _rn_pane="$(tmuxc capture-pane -p -t "$BRIDGE_PANE" 2>/dev/null)"
  if rename_receipt_seen "$_rn_pane" "$DESIRED" && [ "$BRIDGE_NAME" = "$DESIRED" ]; then
    bridge_gen_write "$STATE_DIR" "$NAME" applied="$DESIRED" applied_at="$(date +%s)000" rename_tries=0
    rm -f "$RENAME_PENDING"
    echo "session-supervisor: $NAME — rename receipted: pane and bridge both report '$DESIRED'" >&2
  elif rename_pane_busy "$_rn_pane"; then :
  elif [ "${_rn_tries:-0}" -ge 5 ]; then
    echo "session-supervisor: $NAME — RENAME NOT CONFIRMED after $_rn_tries attempts; pending stays." >&2
  elif ! pane_foreground_is_managed "$BRIDGE_PANE" "$BRIDGE_PID"; then
    echo "session-supervisor: $NAME — rename pending, but the managed pane's foreground is not claude; not typing." >&2
  elif [ "$(bridge_os_birth "$BRIDGE_PID" 2>/dev/null)" != "$BRIDGE_BIRTH" ]; then :
  else
    type_line "$BRIDGE_PANE" "/rename $DESIRED"
    bridge_gen_write "$STATE_DIR" "$NAME" rename_tries=$(( _rn_tries + 1 ))
  fi
fi
```

`spawn_session`: replace `printf '%s %s\n' 0 "$RC_LABEL" > "$RENAME_PENDING"` with `bridge_gen_write "$STATE_DIR" "$NAME" rename_tries=0` (pending is derived from desired≠applied every round; the file is a trace only).

- [ ] **Step 4: Run** → green. Also run `test/supervisor-mcp-guard.test.sh`, `test/supervisor-opencode.test.sh`, `test/supervisor-zombie-veto.test.sh` — update any that asserted `send-keys -t $NAME`.
- [ ] **Step 5: Mutations** — `type_line "$NAME" …` → 13a fails. Drop the foreground check → 14a fails. Accept the pane receipt without `BRIDGE_NAME = DESIRED` → 13c passes falsely; add to the fixture a capture that says renamed while the bridge still says Old and assert applied stays Old.
- [ ] **Step 6: Commit** — `rename: every keystroke goes to the bridge file's pane, and applied is the receipt, not the reported name`. Push.

---

### Task 7: Watch and restart-session on the bridge file

Implements spec §1 consumer census rows for `watch/`.

**Files:**
- Modify: `watch/bin/registry-dump` — per-session `configDir` (empty when not resolvable) and `runtime`.
- Modify: `watch/lib.mjs` — add `findProcessByBridge(bridgeText, id, psText)`; keep `findProcessByPanePid`; delete `findProcess` after callers move.
- Modify: `watch/session-watch.mjs:143-154`, `watch/restart-session.mjs:25-40`.
- Test: `watch/test/lib.test.mjs`

**Interfaces:**
- `registry-dump sessions` rows gain `configDir` (string, may be `""`) and `runtime` (`claude-code|opencode|codex`).
- `findProcessByBridge(bridgeText, id, psText)` → `{pid, startEpoch, resumed, pane, name} | null | 'uninspectable' | 'unknown'`. `bridgeText` is the concatenation the watch reads with `cat <configDir>/sessions/*.json 2>/dev/null` **piped through** `jq -c '{pid,procStart,tmux,name,nameSince,sessionId,startedAt}'` on the host — secrets never reach Node.

- [ ] **Step 1: Failing tests** (append to `watch/test/lib.test.mjs`)

```js
import { findProcessByBridge } from '../lib.mjs'
const PS = `  4243 Thu Sep 11 09:00:00 2026 /home/a/.local/bin/claude --remote-control "Whatever"
  4300 Thu Sep 11 09:01:00 2026 /home/a/.local/bin/claude --remote-control "Whatever"`
const B1 = JSON.stringify({pid:4243,procStart:1,tmux:'s-1:@0.%0',name:'Alpha→Thing',nameSince:1,sessionId:'t',startedAt:1})
test('findProcessByBridge: exactly one candidate for the id => the process, by pid, label ignored', () => {
  const r = findProcessByBridge(B1, 's-1', PS)
  assert.equal(r.pid, 4243); assert.equal(r.pane, 's-1:@0.%0'); assert.equal(r.name, 'Alpha→Thing')
})
test('findProcessByBridge: a candidate for another id is not ours', () => {
  const other = JSON.stringify({pid:4300,procStart:1,tmux:'s-2:@0.%0',name:'x',nameSince:1,sessionId:'t',startedAt:1})
  assert.equal(findProcessByBridge(other, 's-1', PS), null)
})
test('findProcessByBridge: prefix of the id is not the id', () => {
  const pre = JSON.stringify({pid:4300,procStart:1,tmux:'s-10:@0.%0',name:'x',nameSince:1,sessionId:'t',startedAt:1})
  assert.equal(findProcessByBridge(pre, 's-1', PS), null)
})
test('findProcessByBridge: two candidates => unknown, never the first', () => {
  const two = B1 + '\n' + JSON.stringify({pid:4300,procStart:1,tmux:'s-1:@1.%1',name:'y',nameSince:1,sessionId:'t',startedAt:1})
  assert.equal(findProcessByBridge(two, 's-1', PS), 'unknown')
})
test('findProcessByBridge: a malformed line poisons the answer', () => {
  assert.equal(findProcessByBridge(B1 + '\n{"pid":', 's-1', PS), 'unknown')
})
test('findProcessByBridge: candidate pid absent from ps => null (dead), not the label', () => {
  const dead = JSON.stringify({pid:9999,procStart:1,tmux:'s-1:@0.%0',name:'x',nameSince:1,sessionId:'t',startedAt:1})
  assert.equal(findProcessByBridge(dead, 's-1', PS), null)
})
test('findProcessByBridge: empty bridge text with configDir unknown => uninspectable', () => {
  assert.equal(findProcessByBridge(null, 's-1', PS), 'uninspectable')
})
```

- [ ] **Step 2: Run** `cd watch && npm test` → red (`findProcessByBridge is not exported`).

- [ ] **Step 3: Implement** in `watch/lib.mjs`:

```js
// findProcessByBridge(bridgeText, id, psText) - the session's process by the vendor's bridge
// attestation, never by its label. bridgeText is one compact JSON object per line, already
// reduced on the host to the seven fields we read (jq -c '{pid,procStart,tmux,name,nameSince,sessionId,startedAt}').
// null   = no candidate, or the candidate's pid is not in ps (dead)
// 'unknown'       = more than one candidate, or a malformed line - never pick
// 'uninspectable' = we could not read the home (bridgeText null)
export function findProcessByBridge(bridgeText, id, psText) {
  if (bridgeText === null || bridgeText === undefined) return 'uninspectable'
  const re = new RegExp('^' + id.replace(/[.*+?^${}()|[\]\\]/g, '\\$&') + ':@\\d+\\.%\\d+$')
  const cands = []
  for (const line of String(bridgeText).split('\n')) {
    if (!line.trim()) continue
    let o; try { o = JSON.parse(line) } catch { return 'unknown' }
    if (typeof o !== 'object' || o === null) return 'unknown'
    if (typeof o.tmux !== 'string' || !re.test(o.tmux)) continue
    if (typeof o.pid !== 'number' || typeof o.name !== 'string') return 'unknown'
    cands.push(o)
  }
  if (cands.length > 1) return 'unknown'
  if (cands.length === 0) return null
  const c = cands[0]
  for (const line of psText.split('\n')) {
    const m = line.match(/^\s*(\d+)\s+(\w{3} \w{3} [ \d]\d \d{2}:\d{2}:\d{2} \d{4})\s+/)
    if (!m || Number(m[1]) !== c.pid) continue
    return { pid: c.pid, startEpoch: Date.parse(m[2]), resumed: /\s--resume(\s|$)/.test(line), pane: c.tmux, name: c.name }
  }
  return null
}
```

`registry-dump` sessions branch: add `--arg configDir "$( [ -n "${LOGIN:-}" ] && registry_login_config_dir "$LOGIN" "$(registry_account_load "${ACCOUNT:-}" >/dev/null 2>&1 && printf '%s' "$ACCOUNT_USERNAME")" 2>/dev/null || printf '' )"` and `--arg runtime "${RUNTIME:-claude-code}"`, and both fields to the object.

`session-watch.mjs:143-154`: replace the `if (s.rcLabel === '') … else proc = findProcess(...)` with:

```js
let bridgeText = null
if (procInspectable && s.configDir) {
  const cmd = `for f in ${JSON.stringify(s.configDir)}/sessions/*.json; do [ -f "$f" ] && jq -c '{pid,procStart,tmux,name,nameSince,sessionId,startedAt}' "$f" 2>/dev/null; done`
  try { bridgeText = (remote ? await ssh(s, cmd) : await exec('bash', ['-c', cmd])).stdout } catch { bridgeText = null }
}
const r = findProcessByBridge(bridgeText, s.id, psLocal)
proc = (r && typeof r === 'object') ? r : null
if (r === 'unknown' || r === 'uninspectable') obs.identity = r   // decide() must not raise "missing" on these - see Step 3b
```

3b. In `decide()` (lib.mjs:262): when `obs.identity === 'unknown' || obs.identity === 'uninspectable'`, emit no `missing` alarm and no restart action; add one info line `identity ${obs.identity}`. Add a test: `decide({}, {name:'s-1', proc:null, identity:'unknown'}, now, OPTS)` → `actions` empty, no alert containing `missing`.

`restart-session.mjs`: read `configDir` from the row; `before = findProcessByBridge(await bridgeText(), row.id, await ps())`; refuse (`exit 1`) on `'unknown'`/`'uninspectable'`/null with a message naming which.

Delete `findProcess` and its tests once no caller remains (`grep -rn findProcess watch/`).

- [ ] **Step 4: Run** `cd watch && npm test` → green.
- [ ] **Step 5: Mutations** — return `cands[0]` when `cands.length > 1` → "two candidates" fails. Skip the `re.test` anchor → "prefix" fails.
- [ ] **Step 6: Commit** — `watch: the process by the bridge file, unknown when it cannot tell, uninspectable when it may not look`. Push.

---

### Task 8: `linux/liveness-host.sh` corroborates with the bridge

Implements spec §1 "liveness-host corroborates with the bridge file".

**Files:**
- Modify: `linux/liveness-host.sh` (claude branch near line 444-470: where `agent` is decided from panes/pgrep)
- Test: `test/liveness-host.test.sh` (extend)

**Interfaces:**
- Consumes `bridge_candidates`, `bridge_os_birth` (sourced from `$(dirname "$REG_LIB")/bridge.sh`; when absent, liveness-host keeps today's pane answer and prints `bridge-lib-missing` in the row's `note`).
- Produces: `agent=running` for a claude row only when a pane descendant runtime exists **and** exactly one bridge candidate names a live pid; `agent=not-running` when neither; `agent=unknown` when they disagree or candidates >1. (`lib/liveness.sh` must accept `unknown` for `agent` — check its vocabulary and add it if closed.)

- [ ] **Step 1: Failing test** — in `test/liveness-host.test.sh`, plant a `sessions/<pid>.json` for the fixture row and assert `agent=running`; plant two → `agent=unknown`; plant none but pane runtime present → `agent=unknown`.
- [ ] **Step 2: Run** → red.
- [ ] **Step 3: Implement** — after the pane/runtime determination for claude rows, compute `n=$(bridge_candidates "$id" "$cfg/sessions" 2>/dev/null | awk -F'\t' '{ if (system("kill -0 " $2 " 2>/dev/null")==0) c++ } END{print c+0}')` and fold: `pane_runtime && n==1 → running; !pane_runtime && n==0 → not-running; else unknown`. (`cfg` is resolved per row through `registry_login_config_dir "$LOGIN" "$owner"`.)
- [ ] **Step 4: Run** → green. Also `bash test/sessions-liveness.test.sh`.
- [ ] **Step 5: Mutation** — ignore `n` → the "two files" case wrongly says running.
- [ ] **Step 6: Commit** — `liveness-host: the pane says something lives, the bridge says which - disagreement is unknown`.

---

### Task 9: Gates — rendered uniqueness at write, work rule, host reservation

Implements spec §3.

**Files:**
- Modify: `lib/registry.sh` — new `registry_session_rendered_unique <id-or-candidate-conf>` and `registry_session_work_rule <login> <project> [<exclude-id>]`.
- Modify: `bin/steward` `cmd_registry_session_add` and `linux/hub/enroll` — call both gates before writing; refusals rc 65 naming the colliding row.
- Modify: `linux/session-supervisor-linux.sh` — at spawn and before typing a rename, refuse when another live bridge file in a readable home already reports the desired string (host reservation).
- Modify: `test/session-rc-label-unique.test.sh` → rendered-string uniqueness; new claims for the work rule and RUNTIME exemption.

**Interfaces:**
- `registry_session_rendered_unique <candidate-conf-path>` → rc 0, or rc 65 with `registry: display '<s>' is already rendered by <id>`; only rows with `RUNTIME` unset/`claude-code` and RC-enabled count; `LIFECYCLE="retired"` rows do not.
- `registry_session_work_rule <login> <project> [<exclude-id>]` → rc 0, or rc 65 naming the existing row; considers non-retired `claude-code` rows only.

- [ ] **Step 1: Failing tests** — rewrite `test/session-rc-label-unique.test.sh` claims: (a) two rows rendering `Alpha→Thing` → second refused at `session add`; (b) same string, one row `RUNTIME="codex"` → allowed; (c) one row `LIFECYCLE="retired"` → allowed; (d) `RC_LABEL=""` rows do not reserve; (e) two `claude-code` rows with `LOGIN="jon-point"` and `TARGET_PROJECT="thing"` → refused with the existing id in the message; (f) same but one `RUNTIME="opencode"` → allowed.
- [ ] **Step 2: Run** → red.
- [ ] **Step 3: Implement** the two functions by iterating `registry_list`, loading each row in a subshell, skipping retired/non-claude/RC-free, comparing `registry_session_display` output (for `rendered_unique`) or `LOGIN`+`TARGET_PROJECT` (for `work_rule`). Wire into `cmd_registry_session_add` right before the conf is written, and into `enroll` at the same point (both already call `registry_login_principal_gate` — add the two calls beside it). Supervisor: before `spawn_session` and before `type_line` in Task 6's cycle, scan `$HOME/../*/.claude*/sessions/*.json` readable to this uid via `bridge_candidates` for **any** id and refuse if a live candidate's `name` equals `$DESIRED` and its pid is not `$BRIDGE_PID`.
- [ ] **Step 4: Run** → green; run `test/registry-session-add.test.sh`, `test/hub-enroll-conf.test.sh`.
- [ ] **Step 5: Mutations** — count retired rows → (c) fails; ignore RUNTIME → (b)/(f) fail.
- [ ] **Step 6: Commit** — `gates: a rendered display is reserved once per estate at write, once per host at spawn`. Push.

---

### Task 10: P0 — the bootstrap census

Implements spec §1 "Bootstrap".

**Files:**
- Create: `linux/bridge-census.sh`
- Modify: `linux/deploy-manifest` — row `linux/bridge-census.sh             scripts/bridge-census.sh             755  scripts`
- Test: `test/bridge-census.test.sh`

**Interfaces:**
- `bridge-census.sh [--again]` — for every row of this host (`registry_list`, `HOST` = self) that this uid may inspect: gather candidates, live pids, tmux; write the generation with `census=1`, `pid`/`birth` when exactly one live candidate, `stop_receipt=census-<epoch>` when none; print one receipt line per row `census <id> <answer> pid=<n|-> birth=<t|->`. Refuses to run when any row already has `census=1` unless `--again`.

- [ ] **Step 1: Failing test** — fixture with three rows: one live bridge → generation has pid/birth/census=1; one nothing → census=1 + stop_receipt; one with two live → census=1 and a `census-note=split-brain`, no pid. Second run without `--again` → rc 65.
- [ ] **Step 2: Run** → red. **Step 3: Implement** (reuse `bridge_gather`'s logic by sourcing `lib/bridge.sh` and the supervisor's `is_descendant` — copy `is_descendant` into `lib/bridge.sh` as `bridge_is_descendant` and have the supervisor call that). **Step 4: Run** → green. **Step 5: Mutation** — skip the `census=1` write → the supervisor suite's claim 9 fails. **Step 6: Commit** — `census: existing rows get a generation once, deliberately, before supervision may act`.

---

### Task 11: Migration verb and the first row

Implements spec §4.

**Files:**
- Modify: `bin/steward` — new verb `registry session derive <id>`: refuses unless `registry_session_display` resolves without the label (temporarily unset `RC_LABEL` in a subshell load), deletes the `RC_LABEL=` line (never empties it), runs `registry_session_rendered_unique`, commits with the estate author, prints the rendered display.
- Test: `test/registry-session-derive.test.sh`

- [ ] **Step 1: Failing test** — a row with `RC_LABEL="Old"` and a resolvable target → after `derive`, no `RC_LABEL` line, `registry_session_display` = rendered; a row whose target does not resolve → rc 65, file byte-identical; a row whose rendered string collides → rc 65, byte-identical.
- [ ] **Step 2-4** as above. **Step 5: Mutation** — write `RC_LABEL=""` instead of deleting → the "no RC_LABEL line" assertion fails (and the supervisor would go RC-free: spec §4's trap). **Step 6: Commit** — `derive: a row moves from its typed label to the rendered one by losing a line, never by emptying it`.

**Live gate (not a code step):** P1b cases A and B with a human, and P3 census for any login on more than one host or estate, **before** `derive` is run on a live row. Then derive one work row, watch two rounds, confirm `applied` in its generation.

---

### Task 12: Remove legacy precedence

Implements spec §4 last paragraph. **Only when** `grep -l '^RC_LABEL="[^"]' <estate>/sessions.d/*.conf` is empty on every estate.

**Files:**
- Modify: `lib/registry.sh` `registry_session_display` — the `if [ -n "$label" ]` branch is removed; a non-empty `RC_LABEL` becomes a load-time **warning** for one release, then a refusal.
- Modify: `test/registry-session-display.test.sh`, `test/identity-schema.test.sh` — the contract line becomes "a non-empty RC_LABEL is not read".

- [ ] Steps as above; commit `display: the typed label no longer wins - it is not read`.

---

## Gates carried by this plan (from the spec)

- **P0** census (Task 10) runs on each host before Task 4's supervisor is deployed there.
- **P1b** human level-3 acceptance, cases A and B, before Task 11's first live derive.
- **P2** macOS twin: the butler estate implements the same contract in its `session-supervisor.sh`; `test/bridge-*.test.sh` must pass under bash 3.2 (`brew install bash@3.2` or the mini itself) before Task 4 is considered portable.
- **P3** manual census for cross-host/cross-estate logins before their first derive.
- **procStart precision** per OS: measured in P2; on Linux the birth token is boot id + start ticks (Task 1), independent of vendor `procStart`.

## Self-review

Spec coverage: §1 → Tasks 1–4, 8, 10; §2 → Tasks 5–6; §3 → Task 9; §4 → Tasks 11–12; §5 fixtures → distributed per task, the state-machine list is Task 4's claims 1–10 plus 13–14. Type consistency: `bridge_answer` words are used verbatim in Task 4's `case`; `type_line <pane> <text>` in Task 6 matches its new signature; `findProcessByBridge` return contract is the same in lib and callers. Placeholders: none in Tasks 1–7 and 9, which carry full test and implementation
code. **Tasks 8, 10, 11 and 12 are outlined, not fully coded**: their step
bodies name the files, interfaces, claims and mutations but compress the code.
They sit behind Task 7 and the P0/P1b gates, and the adapter's real shape after
Tasks 1–4 will change details in them. **Before executing any of them, expand it
to full step code with writing-plans again** — do not execute an outline.
