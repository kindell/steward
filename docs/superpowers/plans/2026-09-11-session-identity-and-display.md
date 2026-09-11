# Session Identity and Display Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Supervision identifies a session by the vendor's bridge file (ID ↔ pid+birth token ↔ pane), never by its Remote Control label; the label is rendered from the register and renamed through the existing `/rename` cycle bound to the managed pane.

**Architecture:** `lib/bridge.sh` holds pure decision functions (parse candidates by name, classify from measured flags, fold into one of four answers, keep a bounded generation). `linux/bridge-observe.sh` is the **one adapter**: it measures (processes, panes, `/proc`) and prints one line per row in a fixed vocabulary; the supervisor, watch, liveness-host and the census all consume that line and never parse bridge JSON themselves. `RC_LABEL` survives only as a legacy override with precedence until the last row is migrated.

**Tech Stack:** bash 3.2-compatible shell (`set -u`, no arrays in libs), jq, tmux, Linux `/proc`; Node `node:test` for `watch/`.

**Spec:** `docs/superpowers/specs/2026-09-11-session-identity-and-display-design.md` (38c719c). Read it first; each task cites its section.

**Revision:** second version, after the advisor's review of 4dc2b74 (13 findings, all folded in; cited as *A1…A13* where they landed).

## Global Constraints

- Never read or log `bridgeSessionId` or `messagingSocketPath`. jq selects fields by name; no `.[]`, no whole-file dumps.
- Every write (kill, `send-keys`, `kill-session`, spawn) requires an answer of *identified* or *no-process* **observed on two consecutive rounds**, and the broad runtime veto empty for destruction. On *identity-unknown* nothing is written, ever.
- `pid` is never trusted alone: a live process is matched on OS birth token (Linux: boot id + `/proc/<pid>/stat` field 22); a dead bridge file is matched on `pid:procStart` against the generation's history.
- No label match (`--remote-control <string>` in argv) decides anything after Task 5. Tests stub `pgrep` to fail loudly if asked for a label.
- Every `send-keys` targets the bridge file's exact `tmux` value (`<id>:@N.%M`), never `$NAME`.
- Config dir resolves through `registry_login_config_dir "$LOGIN" "<owner unix user>"`, never login alone.
- Poison travels **in band**: an unclassifiable file is a line in the adapter's output, never a shell variable set inside a command substitution (A2).
- Tests never touch the machine: tmux, pgrep, ps, kill and `/proc` are shims/fixtures (`STEWARD_KILL`, `BRIDGE_PROC_ROOT`, `PATH`). No `sed -i` in tests (A6). **No literal tab characters in test source** — write `$(printf '\t')`.
- Commit after every green step with the estate's author identity: `git -c user.name="Jon Kindell" -c user.email="jon+butler@varvet.com" commit …`, ending `Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>` / `Claude-Session: https://claude.ai/code/session_01RMVoAh7XJUuje1PCq3tEQX`.
- Branch `session-identity-display`; push after each task; merge is butler's.
- Bash suites: `bash test/<name>.test.sh` (`ok`/`FAIL` lines, non-zero exit on any FAIL). Watch: `cd watch && npm test`.

---

## File Structure

| file | responsibility |
|---|---|
| `lib/bridge.sh` (new) | pure: candidate parsing with in-band poison, OS birth token, classification, four-way answer, generation file, `bridge_is_descendant` |
| `linux/bridge-observe.sh` (new) | **the adapter**: measures one row (or `--all`) and prints the fixed vocabulary line(s); sole runtime reader of bridge JSON |
| `linux/session-supervisor-linux.sh` (modify) | consumes the adapter line; two-round + veto; rename cycle bound to the pane; grace; generation writes |
| `linux/deploy-manifest` (modify) | ships `lib/bridge.sh`, `linux/bridge-observe.sh`, `linux/bridge-census.sh` |
| `watch/bin/registry-dump` (modify) | `configDir`, `runtime`, `ownerUser` per session |
| `watch/lib.mjs` (modify) | `parseObserveLine`; `findProcess` removed from decisions |
| `watch/session-watch.mjs`, `watch/restart-session.mjs` (modify) | run the adapter, parse one line |
| `linux/liveness-host.sh` (modify) | `agent` for claude rows from the adapter line |
| `lib/registry.sh` (modify) | `registry_session_rc_enabled`, `registry_session_rendered_unique`, `registry_session_work_rule`, `registry_graph_mutation_gate`, `registry_session_retarget_gate`, `registry_display_for_target` |
| `bin/steward`, `linux/hub/enroll` (modify) | call the gates; verb `registry session derive` |
| `linux/bridge-census.sh` (new) | P0 census with `census=1` or `census=blocked:<reason>` |
| tests | `test/bridge-classify.test.sh`, `test/bridge-answer.test.sh`, `test/bridge-generation.test.sh`, `test/bridge-observe.test.sh`, `test/supervisor-bridge.test.sh`, `test/registry-graph-gate.test.sh` (new); `test/registry-session-display.test.sh`, `test/session-rc-label-unique.test.sh`, `test/liveness-host.test.sh`, `test/identity-schema.test.sh`, `test/supervisor-reap.test.sh`, `watch/test/lib.test.mjs` (modify) |

---

### Task 1: `lib/bridge.sh` — candidates by name, poison in band, birth token

Spec §1 "candidate"; A2, A3.

**Files:** Create `lib/bridge.sh`; Test `test/bridge-classify.test.sh`.

**Interfaces:**
- `bridge_candidates <id> <sessions-dir>` → stdout, one line per file that concerns `<id>` or is broken:
  - accepted: `ok<TAB>path<TAB>pid<TAB>procStart<TAB>tmux<TAB>name<TAB>nameSince<TAB>sessionId<TAB>startedAt<TAB>mtime_ms`
  - poison: `!unclassifiable<TAB>path<TAB>reason`
  Files that are complete, typed, and name **another** id are silent (foreign). rc 0 always. Any control character (tab, CR, LF, DEL) inside `tmux`, `name` or `sessionId` is `!unclassifiable` (framing).
- `bridge_os_birth <pid>` → `<boot_id>:<start_ticks>`; rc 1 and empty when `/proc/<pid>` is absent. Honors `BRIDGE_PROC_ROOT`.
- `bridge_is_descendant <pid> <ancestor>` → rc 0 when `<ancestor>` is on `<pid>`'s parent chain (via `ps -o ppid=`, max 40 hops). Moved here from the supervisor so the adapter can use it.

- [ ] **Step 1: Write the failing test**

```bash
#!/bin/bash
# test/bridge-classify.test.sh - bridge files are read by name, never by order; a broken
# file is a LINE the caller sees, not a variable that dies in a subshell (A2); a file
# missing a field is unsupported schema, never "foreign" (A3).
set -u
here="$(CDPATH= cd -- "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
pass=0; fail=0
ok()  { pass=$((pass+1)); printf '  ok   %s\n' "$1"; }
bad() { fail=$((fail+1)); printf '  FAIL %s\n     %s\n' "$1" "${2:-}"; }
is()  { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "wanted '$3', got '$2'"; fi; }
has() { case "$2" in *"$3"*) ok "$1" ;; *) bad "$1" "missing '$3' in: $2" ;; esac; }
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
TAB="$(printf '\t')"
. "$here/lib/bridge.sh" || { echo "cannot source lib/bridge.sh"; exit 1; }
ID="s-0000000000000001"; D="$T/sessions"; mkdir -p "$D"
mk() { # <file> <pid> <tmux> <name>
  printf '{"pid":%s,"procStart":123,"tmux":"%s","name":"%s","nameSince":1789000000000,"sessionId":"aaaa-bbbb","startedAt":1789000000000,"status":"idle","bridgeSessionId":"SECRET","messagingSocketPath":"/tmp/SECRET.sock"}\n' "$2" "$3" "$4" > "$D/$1"
}
oks()    { printf '%s\n' "$1" | grep -c "^ok$TAB"; }
poison() { printf '%s\n' "$1" | grep -c "^!unclassifiable$TAB"; }
echo "== 1. one well-formed file for the id: one ok line, secrets never on stdout =="
mk 100.json 100 "$ID:@0.%0" "Alpha→Beta"
out="$(bridge_candidates "$ID" "$D")"
is "1a one ok" "$(oks "$out")" "1"; is "1b no poison" "$(poison "$out")" "0"
has "1c pid field" "$out" "${TAB}100${TAB}"; has "1d tmux field" "$out" "${TAB}$ID:@0.%0${TAB}"
case "$out" in *SECRET*) bad "1e no secret leaks" "$out" ;; *) ok "1e no secret leaks" ;; esac
echo "== 2. a COMPLETE file for another id is silent (foreign) =="
mk 101.json 101 "s-0000000000000002:@0.%0" "Other"
out="$(bridge_candidates "$ID" "$D")"; is "2a one ok" "$(oks "$out")" "1"; is "2b no poison" "$(poison "$out")" "0"
echo "== 3. a prefix of the id is not the id =="
mk 102.json 102 "${ID}0:@0.%0" "Prefix"
out="$(bridge_candidates "$ID" "$D")"; is "3a still one ok" "$(oks "$out")" "1"
echo "== 4. broken files are POISON LINES, each named, counted by the caller from stdout =="
printf '{"pid":103,"tmux":"%s"' "$ID:@1.%1" > "$D/103.json"                         # truncated
ln -s "$D/100.json" "$D/104.json"                                                     # symlink to a valid file
ln -s "$D/does-not-exist.json" "$D/108.json"                                          # DANGLING symlink (A3)
head -c 70000 /dev/zero | tr '\0' 'x' > "$D/105.json"                                 # oversized
printf '{"pid":"abc","procStart":1,"tmux":"%s","name":"x","nameSince":1,"sessionId":"s","startedAt":1}\n' "$ID:@2.%2" > "$D/106.json"   # wrong type
printf '{"pid":109,"procStart":1,"name":"no tmux at all","nameSince":1,"sessionId":"s","startedAt":1}\n' > "$D/109.json"              # MISSING tmux: schema, not foreign (A3)
printf '{"pid":110,"procStart":1,"tmux":"%s","name":"tab\\there","nameSince":1,"sessionId":"s","startedAt":1}\n' "$ID:@3.%3" > "$D/110.json"  # control char in name (A3)
out="$(bridge_candidates "$ID" "$D")"
is "4a accepted unchanged" "$(oks "$out")" "1"
is "4b six poison lines" "$(poison "$out")" "6"
for f in 103 104 105 106 108 109; do has "4c $f named" "$out" "$f.json"; done
has "4d control char refused" "$out" "110.json"
echo "== 5. two complete files for one id are TWO ok lines - the library never picks =="
rm -f "$D"/10[3-9].json "$D/110.json"; mk 107.json 107 "$ID:@3.%3" "Second"
out="$(bridge_candidates "$ID" "$D")"; is "5a two ok" "$(oks "$out")" "2"
echo "== 6. OS birth token from a /proc fixture; comm with spaces/parens does not shift the field =="
P="$T/proc"; mkdir -p "$P/sys/kernel/random" "$P/4242" "$P/4243"; printf 'boot-1111\n' > "$P/sys/kernel/random/boot_id"
printf '4242 (claude) S 1 4242 4242 0 -1 4194560 100 0 0 0 5 5 0 0 20 0 1 0 987654 1000 200 1\n' > "$P/4242/stat"
printf '4243 (my (odd) claude) S 1 1 1 0 -1 0 0 0 0 0 0 0 0 0 20 0 1 0 555 0 0 0\n' > "$P/4243/stat"
is "6a token" "$(BRIDGE_PROC_ROOT="$P" bridge_os_birth 4242)" "boot-1111:987654"
is "6b odd comm" "$(BRIDGE_PROC_ROOT="$P" bridge_os_birth 4243)" "boot-1111:555"
BRIDGE_PROC_ROOT="$P" bridge_os_birth 9999 >/dev/null 2>&1; is "6c gone pid rc 1" "$?" "1"
echo "== 7. descendant walk through a ps shim =="
BIN="$T/bin"; mkdir -p "$BIN"; cat > "$BIN/ps" <<'EOF'
pid=""; prev=""; for a in "$@"; do [ "$prev" = "-p" ] && pid="$a"; prev="$a"; done
case "$pid" in 30) echo " 20";; 20) echo " 10";; 10) echo " 1";; *) exit 1;; esac
EOF
chmod 755 "$BIN/ps"
PATH="$BIN:$PATH" bridge_is_descendant 30 10; is "7a 30 descends from 10" "$?" "0"
PATH="$BIN:$PATH" bridge_is_descendant 30 99; is "7b not from 99" "$?" "1"
printf '\n%d passed, %d failed\n' "$pass" "$fail"; [ "$fail" -eq 0 ]
```

- [ ] **Step 2: Run** `bash test/bridge-classify.test.sh` → `cannot source lib/bridge.sh`, exit 1.

- [ ] **Step 3: Write the library**

```bash
#!/bin/bash
# lib/bridge.sh - the vendor's local bridge attestation, read strictly and by name.
#
# THE FILE IS AN UNDOCUMENTED VENDOR FORMAT (<CLAUDE_CONFIG_DIR>/sessions/<pid>.json).
# Measured 2026-09-11 (P1): appears within 1 s of spawn, follows /rename within 1 s,
# is removed on clean exit and TERM, is LEFT BEHIND on KILL -9, and its `tmux` field
# records the session name AT REGISTRATION and does not follow a rename. Nothing here
# trusts it as authority: every candidate is classified, never picked.
#
# POISON TRAVELS IN BAND. A broken file is a `!unclassifiable` LINE on stdout, so a
# caller that captured the output in $(...) still sees it. The first draft set a
# shell variable, which dies at the subshell boundary; the caller saw zero (A2).
#
# SCHEMA FIRST, MEMBERSHIP SECOND. A record is validated COMPLETELY before its tmux is
# compared with the id. A file missing `tmux` is unsupported schema and is poison -
# never "foreign", which would let a vendor rename of that field turn every row into
# no-process and authorise a spawn (A3).
#
# TWO FIELDS ARE NEVER READ: bridgeSessionId and messagingSocketPath.
# bash 3.2: no arrays, no `local -n`, no ${var,,}.
set -u
BRIDGE_MAX_BYTES="${BRIDGE_MAX_BYTES:-65536}"

_bridge_size() { wc -c < "$1" 2>/dev/null | tr -d ' '; }
_bridge_mtime_ms() { local s; s="$(stat -c %Y "$1" 2>/dev/null || stat -f %m "$1" 2>/dev/null)" || return 1; printf '%s000' "$s"; }
_bridge_poison() { printf '!unclassifiable\t%s\t%s\n' "$1" "$2"; }

bridge_candidates() { # <id> <sessions-dir>
  local id="${1:-}" dir="${2:-}" f sz row
  [ -n "$id" ] && [ -d "$dir" ] || return 0
  for f in "$dir"/*.json; do
    # -L BEFORE -e: a dangling symlink fails -e and would be skipped silently (A3)
    if [ -L "$f" ]; then _bridge_poison "$f" symlink; continue; fi
    [ -e "$f" ] || continue
    if [ ! -f "$f" ]; then _bridge_poison "$f" "not a regular file"; continue; fi
    sz="$(_bridge_size "$f")"
    if [ -z "$sz" ] || [ "$sz" -gt "$BRIDGE_MAX_BYTES" ]; then _bridge_poison "$f" "size ${sz:-?} > $BRIDGE_MAX_BYTES"; continue; fi
    row="$(jq -r --arg id "$id" '
      def ctl: test("[ -]");
      if type != "object" then "!notobject"
      elif ((.pid|type) != "number") or ((.procStart|type) != "number") or ((.tmux|type) != "string")
        or ((.name|type) != "string") or ((.nameSince|type) != "number") or ((.sessionId|type) != "string")
        or ((.startedAt|type) != "number") then "!types"
      elif (.tmux|ctl) or (.name|ctl) or (.sessionId|ctl) then "!control-char"
      elif (.tmux | test("^" + ($id | gsub("[.^$*+?()\\[\\]{}|\\\\-]"; "\\\\" + .)) + ":@[0-9]+\\.%[0-9]+$")) | not then "!foreign"
      else [(.pid|tostring), (.procStart|tostring), .tmux, .name, (.nameSince|tostring), .sessionId, (.startedAt|tostring)] | join("\t") end
    ' "$f" 2>/dev/null)" || row="!json"
    case "$row" in
      "!foreign") continue ;;
      "!json"|"!notobject"|"!types"|"!control-char"|"") _bridge_poison "$f" "${row#!}"; continue ;;
    esac
    printf 'ok\t%s\t%s\t%s\n' "$f" "$row" "$(_bridge_mtime_ms "$f")"
  done
  return 0
}

bridge_os_birth() { # <pid> -> boot_id:start_ticks ; rc 1 when gone
  local pid="${1:-}" root="${BRIDGE_PROC_ROOT:-/proc}" boot stat rest
  case "$pid" in ''|*[!0-9]*) return 1 ;; esac
  [ -r "$root/$pid/stat" ] || return 1
  boot="$(cat "$root/sys/kernel/random/boot_id" 2>/dev/null)" || return 1
  stat="$(cat "$root/$pid/stat" 2>/dev/null)" || return 1
  rest="${stat##*) }"        # split AFTER the last ")": comm may hold spaces and parens
  set -- $rest               # $1 = field 3 (state) ... starttime = field 22 = $20
  [ "$#" -ge 20 ] || return 1
  printf '%s:%s' "$boot" "${20}"
}

bridge_is_descendant() { # <pid> <ancestor> ; the supervisor's is_descendant, moved here
  local pid="${1:-}" target="${2:-}" n=0
  while [ -n "$pid" ] && [ "$pid" -gt 1 ] 2>/dev/null && [ "$n" -lt 40 ]; do
    [ "$pid" = "$target" ] && return 0
    pid="$(ps -o ppid= -p "$pid" 2>/dev/null | tr -d ' ')"; n=$((n+1))
  done
  return 1
}
```

- [ ] **Step 4: Run** → all `ok`.
- [ ] **Step 5: Mutations** (each must go red, then be reverted) — swap the `!types` and `!foreign` branches → 4c 109 fails. `-e` before `-L` → 4c 108 fails. Drop the `ctl` test → 4d fails. `${20}`→`${19}` → 6a/6b fail.
- [ ] **Step 6: Commit** — `bridge: attestation read by name; a broken file is a line, and a missing field is schema, not foreign`.

---

### Task 2: `lib/bridge.sh` — classification and the four-way answer

Spec §1 tables; A4 (launch claim), A11 (census string).

**Files:** Modify `lib/bridge.sh` (append); Test `test/bridge-answer.test.sh`.

**Interfaces:**
- `bridge_classify_candidate <alive> <uid_ok> <birth_known> <in_launch_window> <stored_pane_has_pid> <any_pane_has_pid> <dead_match> <startedAt_ms> <launch_ms>` → one word: `live:managed` `live:moved` `live:orphan` `stale` `unclassifiable`.
  - `birth_known` = this pid+birth is the generation's current or in history.
  - `in_launch_window` = the generation has an open launch (launch_ms set, no pid recorded, grace rounds not exhausted). A fresh pid is ours **only** under this claim and only if `startedAt_ms ≥ launch_ms` (A4).
  - `dead_match` = (pid, procStart) is in the generation's history (A4).
- `bridge_answer <classes> <gen_state> <tmux_present> <veto> <census>` → `identified:managed` `identified:orphan` `identified:moved` `no-process` `unknown` `wait-veto` `grace`. `<census>` is the string from the generation; only exactly `1` counts as done (A11).

- [ ] **Step 1: Write the failing test**

```bash
#!/bin/bash
# test/bridge-answer.test.sh - every row of the spec's table as a decision from flags alone.
set -u
here="$(CDPATH= cd -- "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
pass=0; fail=0
ok()  { pass=$((pass+1)); printf '  ok   %s\n' "$1"; }
bad() { fail=$((fail+1)); printf '  FAIL %s\n     %s\n' "$1" "${2:-}"; }
is()  { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "wanted '$3', got '$2'"; fi; }
. "$here/lib/bridge.sh" || exit 1
C() { bridge_classify_candidate "$@"; }
echo "== classify: alive uid birth_known in_window stored any dead_match startedAt launch =="
is "known pid in stored pane = managed"        "$(C 1 1 1 0 1 1 0 2000 1000)" "live:managed"
is "known pid under another pane = moved"      "$(C 1 1 1 0 0 1 0 2000 1000)" "live:moved"
is "known pid under no pane = orphan"          "$(C 1 1 1 0 0 0 0 2000 1000)" "live:orphan"
is "FRESH pid inside launch window, stored pane = managed" "$(C 1 1 0 1 1 1 0 2000 1000)" "live:managed"
is "fresh pid OUTSIDE launch window = unclassifiable (A4)" "$(C 1 1 0 0 1 1 0 2000 1000)" "unclassifiable"
is "fresh pid in window but started before launch = unclassifiable" "$(C 1 1 0 1 1 1 0 500 1000)" "unclassifiable"
is "alive, wrong uid = unclassifiable"         "$(C 1 0 1 0 1 1 0 2000 1000)" "unclassifiable"
is "dead, (pid,procStart) in history = stale"  "$(C 0 1 0 0 0 0 1 2000 1000)" "stale"
is "dead, unknown to history = unclassifiable" "$(C 0 1 0 0 0 0 0 2000 1000)" "unclassifiable"
echo "== answer: classes gen tmux veto census =="
is "first-ever (census=1)"                       "$(bridge_answer ''  none 0 0 1)" "no-process"
is "pre-census = unknown"                        "$(bridge_answer ''  none 0 0 '')" "unknown"
is "census blocked = unknown (A11)"              "$(bridge_answer ''  none 0 0 'blocked:split-brain')" "unknown"
is "manual tmux before first spawn, veto empty"  "$(bridge_answer ''  none 1 0 1)" "no-process"
is "manual tmux before first spawn, veto held"   "$(bridge_answer ''  none 1 1 1)" "wait-veto"
is "planned stop"                                "$(bridge_answer ''  gone-receipt 0 0 1)" "no-process"
is "crash (no receipt)"                          "$(bridge_answer ''  gone-noreceipt 0 0 1)" "no-process"
is "crash, veto runtime under pane"              "$(bridge_answer ''  gone-noreceipt 1 1 1)" "wait-veto"
is "launched, no attestation, in grace"          "$(bridge_answer ''  grace 1 0 1)" "grace"
is "launched, no attestation, past grace"        "$(bridge_answer ''  alive 1 0 1)" "unknown"
is "managed"                                     "$(bridge_answer 'live:managed' alive 1 0 1)" "identified:managed"
is "orphan"                                      "$(bridge_answer 'live:orphan'  alive 0 0 1)" "identified:orphan"
is "moved"                                       "$(bridge_answer 'live:moved'   alive 0 0 1)" "identified:moved"
is "stale only = as none"                        "$(bridge_answer 'stale' gone-noreceipt 0 0 1)" "no-process"
is "stale + live = identified"                   "$(bridge_answer 'stale live:managed' alive 1 0 1)" "identified:managed"
is "two live = split-brain"                      "$(bridge_answer 'live:managed live:managed' alive 1 0 1)" "unknown"
is "one unclassifiable poisons"                  "$(bridge_answer 'unclassifiable live:managed' alive 1 0 1)" "unknown"
printf '\n%d passed, %d failed\n' "$pass" "$fail"; [ "$fail" -eq 0 ]
```

- [ ] **Step 2: Run** → red.
- [ ] **Step 3: Append**

```bash
# ---- classification (all inputs measured by the caller; this only decides) ----
bridge_classify_candidate() { # alive uid_ok birth_known in_window stored any dead_match startedAt launch
  local alive="${1:-0}" uid_ok="${2:-0}" known="${3:-0}" win="${4:-0}" stored="${5:-0}" any="${6:-0}" dead="${7:-0}" started="${8:-0}" launch="${9:-0}"
  if [ "$alive" = 1 ]; then
    [ "$uid_ok" = 1 ] || { printf 'unclassifiable'; return 0; }
    # A LIVE PID IS OURS IN EXACTLY TWO WAYS: the generation knows its birth, or it
    # appeared inside a bounded launch claim (we spawned, no pid recorded yet, still
    # in grace) and it started no earlier than that launch. Anything else - a fresh
    # claude somebody started under our tmux name - is unclassifiable (A4).
    if [ "$known" != 1 ]; then
      [ "$win" = 1 ] && [ "$started" -ge "$launch" ] 2>/dev/null || { printf 'unclassifiable'; return 0; }
    fi
    if [ "$stored" = 1 ]; then printf 'live:managed'; elif [ "$any" = 1 ]; then printf 'live:moved'; else printf 'live:orphan'; fi
    return 0
  fi
  if [ "$dead" = 1 ]; then printf 'stale'; else printf 'unclassifiable'; fi
}

# ---- the answer -----------------------------------------------------------------
# THE VETO IS AN ACTION GATE, NOT A FIFTH IDENTITY: no-process with the runtime veto
# held is wait-veto, so the caller neither closes nor spawns without pretending not to know.
bridge_answer() { # classes gen_state tmux_present veto census
  local classes="${1:-}" gen="${2:-none}" tmux="${3:-0}" veto="${4:-0}" census="${5:-}"
  local w live=0 unclass=0 kind=""
  for w in $classes; do case "$w" in live:*) live=$((live+1)); kind="${w#live:}" ;; stale) : ;; *) unclass=$((unclass+1)) ;; esac; done
  [ "$unclass" -eq 0 ] || { printf 'unknown'; return 0; }
  [ "$live" -le 1 ]    || { printf 'unknown'; return 0; }
  [ "$live" -eq 1 ]    && { printf 'identified:%s' "$kind"; return 0; }
  case "$gen" in
    grace) printf 'grace'; return 0 ;;
    alive) printf 'unknown'; return 0 ;;
    none)  [ "$census" = 1 ] || { printf 'unknown'; return 0; } ;;
    gone-receipt|gone-noreceipt) : ;;
    *) printf 'unknown'; return 0 ;;
  esac
  if [ "$veto" = 1 ]; then printf 'wait-veto'; else printf 'no-process'; fi
}
```

- [ ] **Step 4: Run** → green.
- [ ] **Step 5: Mutations** — drop the `win` requirement → "fresh pid OUTSIDE window" fails; `[ "$census" = 1 ]`→`[ -n "$census" ]` → "census blocked" fails; `-le 1`→`-le 2` → split-brain fails.
- [ ] **Step 6: Commit** — `bridge: a fresh pid is ours only under a launch claim; census is done only when it says 1`.

---

### Task 3: `lib/bridge.sh` — the generation, with dead-file history

Spec §1 "Persisted launch generation"; A4.

**Files:** Modify `lib/bridge.sh` (append); Test `test/bridge-generation.test.sh`.

**Interfaces:**
- `bridge_gen_path <sd> <id>`, `bridge_gen_get <sd> <id> <key>` (rc 1 when absent), `bridge_gen_write <sd> <id> key=value ...` (atomic tmp+mv; unknown-shaped key → rc 64).
- Keys: `pid birth procStart uid sessionId launch_ms grace_rounds bridge_name bridge_nameSince bridge_mtime applied applied_at applied_nameSince pending_for pending_since rename_tries stop_receipt census`.
- History entries are `pid:procStart:birth` (`-` for a never-observed birth). `bridge_gen_write` pushes the old triple when `pid` changes to a different non-empty value; bounded to the last 8.
- `bridge_gen_matches_live <sd> <id> <pid> <birth>` → rc 0 when current or in history by birth.
- `bridge_gen_matches_dead <sd> <id> <pid> <procStart>` → rc 0 when current or in history by procStart (A4).

- [ ] **Step 1: Write the failing test**

```bash
#!/bin/bash
# test/bridge-generation.test.sh - history and bootstrap, bounded, never a second truth;
# a DEAD file is matched on pid:procStart because its process cannot yield a birth (A4).
set -u
here="$(CDPATH= cd -- "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
pass=0; fail=0
ok()  { pass=$((pass+1)); printf '  ok   %s\n' "$1"; }
bad() { fail=$((fail+1)); printf '  FAIL %s\n     %s\n' "$1" "${2:-}"; }
is()  { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "wanted '$3', got '$2'"; fi; }
. "$here/lib/bridge.sh" || exit 1
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT; ID="s-0000000000000001"
bridge_gen_get "$T" "$ID" pid >/dev/null 2>&1; is "absent rc 1" "$?" "1"
bridge_gen_write "$T" "$ID" pid=100 birth=b:1 procStart=500 uid=1001 launch_ms=1789000000000
is "pid" "$(bridge_gen_get "$T" "$ID" pid)" "100"
bridge_gen_write "$T" "$ID" applied="Alpha→Beta"; is "merge keeps pid" "$(bridge_gen_get "$T" "$ID" pid)" "100"; is "applied" "$(bridge_gen_get "$T" "$ID" applied)" "Alpha→Beta"
bridge_gen_write "$T" "$ID" pid=101 birth=b:2 procStart=501
bridge_gen_matches_live "$T" "$ID" 100 b:1;  is "old live pair in history" "$?" "0"
bridge_gen_matches_dead "$T" "$ID" 100 500;  is "old DEAD pair by procStart" "$?" "0"
bridge_gen_matches_dead "$T" "$ID" 100 999;  is "wrong procStart no" "$?" "1"
bridge_gen_matches_live "$T" "$ID" 101 b:2;  is "current live" "$?" "0"
bridge_gen_write "$T" "$ID" pid= birth=;      is "clearing pid opens a launch claim (no push of empty)" "$(bridge_gen_get "$T" "$ID" pid)" ""
bridge_gen_matches_dead "$T" "$ID" 101 501;  is "cleared pid still in history" "$?" "0"
i=3; while [ $i -le 12 ]; do bridge_gen_write "$T" "$ID" pid=$((100+i)) birth=b:$i procStart=$((500+i)); i=$((i+1)); done
bridge_gen_matches_dead "$T" "$ID" 100 500;  is "bounded to 8: oldest fell off" "$?" "1"
bridge_gen_matches_dead "$T" "$ID" 105 505;  is "recent kept" "$?" "0"
bridge_gen_write "$T" "$ID" applied="Point→Chalmers→HR Pilot"; is "spaces/arrows survive" "$(bridge_gen_get "$T" "$ID" applied)" "Point→Chalmers→HR Pilot"
bridge_gen_write "$T" "$ID" "bad key=1" >/dev/null 2>&1; is "bad key rc 64" "$?" "64"
printf '\n%d passed, %d failed\n' "$pass" "$fail"; [ "$fail" -eq 0 ]
```

- [ ] **Step 2: Run** → red.
- [ ] **Step 3: Append**

```bash
# ---- generation: <state-dir>/<id>.generation, key=value, written atomically ----
bridge_gen_path() { printf '%s/%s.generation' "$1" "$2"; }
bridge_gen_get()  { local f; f="$(bridge_gen_path "$1" "$2")"; [ -f "$f" ] || return 1; sed -n "s/^$3=//p" "$f" | head -1; }
_bridge_gen_hist() { sed -n 's/^history=//p' "$(bridge_gen_path "$1" "$2")" 2>/dev/null | head -1; }
bridge_gen_matches_live() { # sd id pid birth
  local cur; cur="$(bridge_gen_get "$1" "$2" pid 2>/dev/null):$(bridge_gen_get "$1" "$2" birth 2>/dev/null)"
  [ "$cur" = "$3:$4" ] && return 0
  local h; for h in $(_bridge_gen_hist "$1" "$2"); do [ "${h%%:*}" = "$3" ] && [ "${h##*:}" = "$4" ] && return 0; done; return 1
}
bridge_gen_matches_dead() { # sd id pid procStart
  local cur; cur="$(bridge_gen_get "$1" "$2" pid 2>/dev/null):$(bridge_gen_get "$1" "$2" procStart 2>/dev/null)"
  [ "$cur" = "$3:$4" ] && return 0
  local h mid; for h in $(_bridge_gen_hist "$1" "$2"); do mid="${h#*:}"; mid="${mid%%:*}"; [ "${h%%:*}" = "$3" ] && [ "$mid" = "$4" ] && return 0; done; return 1
}
bridge_gen_write() { # sd id key=value ...
  local dir="$1" id="$2" f tmp kv k v old_pid old_ps old_b hist; shift 2
  f="$(bridge_gen_path "$dir" "$id")"; tmp="$f.tmp.$$"; mkdir -p "$dir"
  old_pid="$(bridge_gen_get "$dir" "$id" pid 2>/dev/null)"; old_ps="$(bridge_gen_get "$dir" "$id" procStart 2>/dev/null)"; old_b="$(bridge_gen_get "$dir" "$id" birth 2>/dev/null)"
  hist="$(_bridge_gen_hist "$dir" "$id")"
  : > "$tmp"; [ -f "$f" ] && grep -v '^history=' "$f" > "$tmp"
  for kv in "$@"; do
    k="${kv%%=*}"; v="${kv#*=}"
    case "$k" in *[!A-Za-z0-9_]*|'') echo "bridge: generation key '$k' refused" >&2; rm -f "$tmp"; return 64 ;; esac
    grep -v "^$k=" "$tmp" > "$tmp.2"; mv "$tmp.2" "$tmp"; printf '%s=%s\n' "$k" "$v" >> "$tmp"
    # a DIFFERENT pid (or a clearing of it) pushes the old triple into history
    if [ "$k" = pid ] && [ -n "$old_pid" ] && [ "$v" != "$old_pid" ]; then hist="$hist $old_pid:${old_ps:--}:${old_b:--}"; fi
  done
  hist="$(printf '%s\n' $hist | grep . | tail -8 | tr '\n' ' ')"; hist="${hist% }"
  [ -n "$hist" ] && printf 'history=%s\n' "$hist" >> "$tmp"
  mv -f "$tmp" "$f"
}
```

- [ ] **Step 4: Run** → green. **Step 5: Mutation** — `tail -8`→`tail -20` → "bounded" fails; push only when `v` non-empty → "cleared pid still in history" fails. **Step 6: Commit** — `bridge: the generation remembers dead files by pid and procStart, bounded`.

---

### Task 4: `linux/bridge-observe.sh` — the one adapter

Spec §1 "One strict adapter"; A1, A4, A8, A9.

**Files:** Create `linux/bridge-observe.sh`; Test `test/bridge-observe.test.sh`; `linux/deploy-manifest` rows `lib/bridge.sh → scripts/lib/bridge.sh 755 lib` (after line 58) and `linux/bridge-observe.sh → scripts/bridge-observe.sh 755 scripts` (after line 37).

**Interfaces:**
- `bridge-observe.sh <id>` → **one line**, nine tab-separated fields:
  `<id>  <answer>  <pid|->  <birth|->  <pane|->  <name|->  <nameSince|->  <gen_state>  <classes>`
  `<answer>` ∈ `bridge_answer`'s words plus `uninspectable` (config dir not readable by this uid) — never silent (A9).
- `bridge-observe.sh --all` → one line per row on this host.
- Env: `STEWARD_STATE_DIR` (required), `STEWARD_TMUX_SOCKET` (required), `STEWARD_REGISTRY_LIB`, `STEWARD_BRIDGE_LIB`, `BRIDGE_PROC_ROOT`, `STEWARD_BRIDGE_GRACE_ROUNDS` (3), `STEWARD_BRIDGE_UID` (`id -u`).
- Side effects: on `identified:managed` writes the generation (`pid birth procStart uid sessionId bridge_name bridge_nameSince bridge_mtime grace_rounds=<max>`); in grace increments `grace_rounds`. Never kills, never types.

- [ ] **Step 1: Write the failing test** (fixture in the shape of `test/supervisor-reap.test.sh`: estate, shims on `PATH` for `tmux`/`ps`/`pgrep`, `/proc` fixture; `$HOMEDIR/.claude/sessions/`; helpers `proc <pid> <ticks>`, `bridge <pid> <pane> <name> [<startedAt>]`, `gen key=value…`, `observe` = run the script and capture the line; `field <n>` = `cut -f<n>`)

Claims, each with its assertion:
1. one live file, pid in stored pane, generation knows the birth → field 2 `identified:managed`; after the run `bridge_gen_get pid` = that pid.
2. same, file's `name` changed → still `identified:managed`.
3. fresh pid (generation pid empty, **no launch**) with our tmux → `unknown`; generation `pid` still empty (A4).
4. `gen launch_ms=1 grace_rounds=0 pid= birth=`; fresh pid with `startedAt ≥ 1` in stored pane → `identified:managed` (launch claim honoured).
5. same as 4 but `startedAt` = 0 → `unknown`.
6. live pid under another pane → `identified:moved`.
7. live pid under no pane → `identified:orphan`.
8. dead file; generation history has `pid:procStart`; tmux absent → field 9 contains `stale`, field 2 `no-process` (gen `gone-noreceipt`).
9. dead file unknown to history → `unknown`.
10. two live files → `unknown`.
11. one live + a truncated file → `unknown` (A2 end-to-end).
12. `--all` with two rows, one whose config dir is `chmod 000` → that row's line has `uninspectable`, the other row unaffected.
13. `gen census=blocked:x`, no files, tmux absent → `unknown`.
14. `pgrep` shim records any pattern containing `remote-control` to `$LABEL_LOG`; after every claim `LABEL_LOG` is empty.

- [ ] **Step 2: Run** → red (script missing).
- [ ] **Step 3: Implement**

```bash
#!/bin/bash
# linux/bridge-observe.sh <id> | --all - THE adapter. It measures, asks lib/bridge.sh, and prints
# ONE line per row in a fixed vocabulary. The supervisor, watch, liveness-host and the census
# read this line; none of them reads the vendor's JSON (spec §1; A8).
set -u
REG_LIB="${STEWARD_REGISTRY_LIB:-$HOME/scripts/lib/registry.sh}"; . "$REG_LIB" || exit 78
BRIDGE_LIB="${STEWARD_BRIDGE_LIB:-$(dirname "$REG_LIB")/bridge.sh}"; . "$BRIDGE_LIB" || exit 78
SD="${STEWARD_STATE_DIR:?STEWARD_STATE_DIR}"; SOCK="${STEWARD_TMUX_SOCKET:?STEWARD_TMUX_SOCKET}"
UIDW="${STEWARD_BRIDGE_UID:-$(id -u)}"; GR="${STEWARD_BRIDGE_GRACE_ROUNDS:-3}"
tmuxc() { command tmux -S "$SOCK" "$@"; }
line() { printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$@"; }
RUNTIME_VETO_PAT='(^|[ /])(claude|opencode)'   # a RUNTIME pattern, never a label
observe() { # <id>
  local id="$1" owner cfg classes="" tmux_present veto gen_state gp gr launch census in_window all_panes
  local tag path pid pstart tmuxf name since sid started mtime alive uid_ok known stored any dead birth sp p q c
  local L_PID="-" L_BIRTH="-" L_PANE="-" L_NAME="-" L_SINCE="-" L_PS="-" L_SID="-" L_MTIME="-"
  registry_load "$id" >/dev/null 2>&1 || { line "$id" unknown - - - - - - "row-does-not-load"; return; }
  owner="$( registry_account_load "${ACCOUNT:-}" >/dev/null 2>&1 && printf '%s' "$ACCOUNT_USERNAME" )"
  if [ -n "${LOGIN:-}" ]; then cfg="$(registry_login_config_dir "$LOGIN" "${owner:-$(id -un)}" 2>/dev/null)" || cfg=""
  else cfg="$(eval printf '%s' "~${owner:-$(id -un)}")/.claude"; fi
  if [ -z "$cfg" ] || [ ! -r "$cfg" ] || [ ! -x "$cfg" ]; then line "$id" uninspectable - - - - - - "config-dir-unreadable"; return; fi
  all_panes="$(tmuxc list-panes -a -F '#{pane_pid}' 2>/dev/null)"
  tmuxc has-session -t "=$id" 2>/dev/null && tmux_present=1 || tmux_present=0
  launch="$(bridge_gen_get "$SD" "$id" launch_ms 2>/dev/null)"; launch="${launch:-0}"
  census="$(bridge_gen_get "$SD" "$id" census 2>/dev/null)"
  gp="$(bridge_gen_get "$SD" "$id" pid 2>/dev/null)"; gr="$(bridge_gen_get "$SD" "$id" grace_rounds 2>/dev/null)"; gr="${gr:-0}"
  in_window=0; [ "$launch" != 0 ] && [ -z "$gp" ] && [ "$gr" -lt "$GR" ] 2>/dev/null && in_window=1
  while IFS="$(printf '\t')" read -r tag path pid pstart tmuxf name since sid started mtime; do
    [ -n "$tag" ] || continue
    if [ "$tag" = '!unclassifiable' ]; then classes="$classes unclassifiable"; continue; fi
    alive=0; uid_ok=0; known=0; stored=0; any=0; dead=0; birth=""
    if birth="$(bridge_os_birth "$pid")"; then
      alive=1
      [ "$(ps -o uid= -p "$pid" 2>/dev/null | tr -d ' ')" = "$UIDW" ] && uid_ok=1
      bridge_gen_matches_live "$SD" "$id" "$pid" "$birth" && known=1
      sp="$(tmuxc display-message -p -t "$tmuxf" '#{pane_pid}' 2>/dev/null)"; [ -n "$sp" ] && bridge_is_descendant "$pid" "$sp" && stored=1
      for p in $all_panes; do bridge_is_descendant "$pid" "$p" && { any=1; break; }; done
    else
      bridge_gen_matches_dead "$SD" "$id" "$pid" "$pstart" && dead=1
    fi
    c="$(bridge_classify_candidate "$alive" "$uid_ok" "$known" "$in_window" "$stored" "$any" "$dead" "${started:-0}" "$launch")"
    classes="$classes $c"
    case "$c" in live:*) L_PID="$pid"; L_BIRTH="$birth"; L_PANE="$tmuxf"; L_NAME="$name"; L_SINCE="$since"; L_PS="$pstart"; L_SID="$sid"; L_MTIME="$mtime" ;; esac
  done <<EOF
$(bridge_candidates "$id" "$cfg/sessions")
EOF
  gen_state=none
  if [ -n "$gp" ]; then
    if [ "$(bridge_os_birth "$gp" 2>/dev/null)" = "$(bridge_gen_get "$SD" "$id" birth 2>/dev/null)" ]; then gen_state=alive
    elif [ -n "$(bridge_gen_get "$SD" "$id" stop_receipt 2>/dev/null)" ]; then gen_state=gone-receipt; else gen_state=gone-noreceipt; fi
  elif [ "$in_window" = 1 ]; then gen_state=grace; bridge_gen_write "$SD" "$id" grace_rounds=$((gr+1))
  elif [ "$launch" != 0 ]; then gen_state=alive     # launched, past grace, still nothing recorded: unknown per bridge_answer
  fi
  veto=0
  for p in $(pgrep -u "$UIDW" -f "$RUNTIME_VETO_PAT" 2>/dev/null); do for q in $all_panes; do bridge_is_descendant "$p" "$q" && { veto=1; break 2; }; done; done
  ans="$(bridge_answer "$classes" "$gen_state" "$tmux_present" "$veto" "$census")"
  [ "$ans" = identified:managed ] && bridge_gen_write "$SD" "$id" pid="$L_PID" birth="$L_BIRTH" procStart="$L_PS" uid="$UIDW" sessionId="$L_SID" bridge_name="$L_NAME" bridge_nameSince="$L_SINCE" bridge_mtime="$L_MTIME" grace_rounds="$GR"
  line "$id" "$ans" "$L_PID" "$L_BIRTH" "$L_PANE" "$L_NAME" "$L_SINCE" "$gen_state" "${classes# }"
}
case "${1:-}" in
  --all) for n in $(registry_list); do registry_load "$n" >/dev/null 2>&1 || continue; [ "${HOST:-}" = "${STEWARD_SELF_HOST:-$(hostname -s)}" ] || continue; observe "$n"; done ;;
  '') echo "usage: bridge-observe.sh <id> | --all" >&2; exit 64 ;;
  *) observe "$1" ;;
esac
```

- [ ] **Step 4: Run** → green.
- [ ] **Step 5: Mutations** — take the first `live:*` when two exist → claim 10 fails; treat `!unclassifiable` as skip → 11 fails; drop the `in_window` condition → 3 fails (generation pid must stay empty — assert it).
- [ ] **Step 6: Commit** — `bridge-observe: one adapter measures and prints one line; everything else reads the line`.

---

### Task 5: Supervisor on the adapter — two rounds, veto, nothing on unknown

Spec §1; A1, A5, A7.

**Files:** Modify `linux/session-supervisor-linux.sh`; rewrite `test/supervisor-reap.test.sh` claims 2/3; Test `test/supervisor-bridge.test.sh` (Task 4's fixture plus `HAS_SESSION`, kill recorder; `STEWARD_BRIDGE_OBSERVE` pointing at the real `linux/bridge-observe.sh`).

**Interfaces (internal):** `observe_row` sets `B_ANS B_PID B_BIRTH B_PANE B_NAME B_SINCE B_GEN`. State files: `$STATE_DIR/$NAME.orphan-suspect`, `.identity-degraded`, `.display-degraded`, `.observe-stderr`.

- [ ] **Step 1: Failing tests** — claims:
1. managed, display changed in the file → rc 0, no `ZOMBIE`, no kill, `LABEL_LOG` empty.
2. other claude in other pane, managed dead, tmux present → round one: `SUSPECT` written, **no spawn**, nothing killed; round two: zombie path, `kill-session` then one `new-session` (A5).
3. moved → nothing written, `moved` in output, no `new-session`.
4. orphan → round one: `.orphan-suspect` written, **no kill**; round two: kill of that pid; birth re-read immediately before the kill (fixture removes `/proc/<pid>` between rounds in a variant → no kill).
5. stale, tmux absent → round one `SUSPECT`, no spawn; round two exactly one `new-session`; vendor's stale file untouched.
6. split-brain → nothing.
7. malformed + live → nothing.
8. pre-census → no spawn, output names the census.
9. post-census first-ever → round one `SUSPECT`, round two one spawn.
10. grace → nothing for N rounds, then `.identity-degraded` once, still nothing.
11. **managed row whose display no longer derives** → rc 0, `.display-degraded` written once, supervision continues (A7).
12. no-process and display does not derive → rc 78 naming the missing link, no spawn.

- [ ] **Step 2: Run** → red.
- [ ] **Step 3: Implement** (A1 placement):
  - After line 81: only source `lib/bridge.sh` and set `_bridge_ok=1` on success — **no exit here**.
  - After the pause guard (:154) and after `CFG_ROOT` (:358): `[ "${_bridge_ok:-}" = 1 ] || { echo "session-supervisor: $NAME — REFUSING: $BRIDGE_LIB does not define bridge_answer — deploy the product first." >&2; exit 78; }`; `OBSERVE="${STEWARD_BRIDGE_OBSERVE:-$(dirname "$0")/bridge-observe.sh}"`.
  - `observe_row() { IFS="$(printf '\t')" read -r _ B_ANS B_PID B_BIRTH B_PANE B_NAME B_SINCE B_GEN _ <<EOF
$(STEWARD_STATE_DIR="$STATE_DIR" STEWARD_TMUX_SOCKET="$SOCK" STEWARD_REGISTRY_LIB="$REG_LIB" STEWARD_BRIDGE_LIB="$BRIDGE_LIB" "$OBSERVE" "$NAME" 2>>"$STATE_DIR/$NAME.observe-stderr")
EOF
}`
  - Line 1337: `observe_row; if [ "$B_ANS" = identified:managed ]; then rm -f "$STATE_DIR/$NAME.orphan-suspect" "$STATE_DIR/$NAME.identity-degraded"` (the rest of the healthy branch follows; the rename cycle is Task 6).
  - Replace lines 1731-1743 with:

```bash
case "$B_ANS" in
  identified:managed) : ;;
  identified:moved) echo "session-supervisor: $NAME — identified but MOVED (pid $B_PID under a pane other than $B_PANE). Nothing written; restore the tmux name or stop it deliberately." >&2; exit 0 ;;
  unknown)
    if [ "$B_GEN" = alive ] && [ ! -f "$STATE_DIR/$NAME.identity-degraded" ]; then touch "$STATE_DIR/$NAME.identity-degraded"; echo "session-supervisor: $NAME — DEGRADED: our process lives but nothing attests it." >&2; fi
    echo "session-supervisor: $NAME — identity-unknown ($(tail -1 "$STATE_DIR/$NAME.observe-stderr" 2>/dev/null)). Nothing written." >&2
    grep -q 'census' "$STATE_DIR/$NAME.observe-stderr" 2>/dev/null || [ -n "$(bridge_gen_get "$STATE_DIR" "$NAME" census 2>/dev/null)" ] || echo "session-supervisor: $NAME — no bootstrap census for this row: run bridge-census.sh first." >&2
    exit 0 ;;
  grace|wait-veto) rm -f "$SUSPECT"; exit 0 ;;
  identified:orphan)
    if [ ! -f "$STATE_DIR/$NAME.orphan-suspect" ]; then touch "$STATE_DIR/$NAME.orphan-suspect"; exit 0; fi
    reap_orphan_claude; rm -f "$STATE_DIR/$NAME.orphan-suspect"; exit 0 ;;
  no-process)
    if [ -n "${DISPLAY_ERR:-}" ]; then echo "session-supervisor: $NAME — REFUSING to spawn: the display does not derive: $DISPLAY_ERR" >&2; exit 78; fi
    if [ ! -f "$SUSPECT" ]; then touch "$SUSPECT"; exit 0; fi
    if ! tmuxc has-session -t "=$NAME" 2>/dev/null; then rm -f "$SUSPECT"; spawn_session; exit 0; fi ;;
  *) echo "session-supervisor: $NAME — adapter answered '$B_ANS', which this supervisor does not know. Nothing written." >&2; exit 0 ;;
esac
```
  - `reap_orphan_claude`:

```bash
reap_orphan_claude() {
  [ "$B_ANS" = identified:orphan ] && [ -n "$B_PID" ] || return 0
  [ "$(bridge_os_birth "$B_PID" 2>/dev/null)" = "$B_BIRTH" ] || { echo "session-supervisor: $NAME — orphan $B_PID changed birth between decision and kill; not touched." >&2; return 0; }
  ${STEWARD_KILL:-kill} "$B_PID" 2>/dev/null && echo "session-supervisor: $NAME — reaped orphan $B_PID ($B_BIRTH): under no pane on the socket, two rounds." >&2
}
```
  - `spawn_session`: remove its `reap_orphan_claude` call and the `RENAME_PENDING` write; after `new-session`: `bridge_gen_write "$STATE_DIR" "$NAME" launch_ms="$(date +%s)000" grace_rounds=0 stop_receipt= pid= birth=`.
  - Zombie block (:1994): `bridge_gen_write "$STATE_DIR" "$NAME" stop_receipt="zombie-$(date +%s)"` before `kill-session`.
  - Delete `matching_claude_pids`, `CLAUDE_PAT`, `RC_LBL_PAT`, `claude_alive_in_session`, `is_descendant` (now `bridge_is_descendant`); keep `runtime_alive_in_session` (call `bridge_is_descendant`).
- [ ] **Step 4: Run** the new suite and `for t in test/supervisor-*.test.sh; do bash "$t" || echo "RED: $t"; done`. Rewrite `test/supervisor-reap.test.sh` claims 2/3 to plant bridge files and generations for the orphan and expect the kill on the **second** round.
- [ ] **Step 5: Mutations** — kill on round one → 4 fails; spawn on round one → 9 fails; `exit 78` at display resolution → 11 fails; skip the birth re-read → the 4-variant fails.
- [ ] **Step 6: Commit** — `supervisor: the adapter answers, two rounds before any write, nothing on unknown`. Push.

---

### Task 6: Display as a fact; rename bound to the pane; applied = receipt with advancing nameSince

Spec §2, §4 RC-free alignment; A6, A7.

**Files:** Modify `lib/registry.sh` (`registry_session_rc_enabled`), supervisor (:677-681, :703-704, `type_line`, cycle :1365-1403); Tests `test/registry-session-display.test.sh` (extend), `test/supervisor-bridge.test.sh` claims 13–15.

**Interfaces:**
- `registry_session_rc_enabled <id>` → rc 0 unless the row has `RC_LABEL=""`.
- `type_line <pane-target> <text>`.
- `pane_foreground_is_managed <pane-target> <pid>` → rc 0 when tmux `#{pane_current_command}` is `claude` **and** `/proc/<pane_pid>/stat` field 8 (tpgid) equals `/proc/<pid>/stat` field 5 (pgrp); both via `BRIDGE_PROC_ROOT`.
- `DISPLAY_ERR` — empty when the display derives; otherwise the registry's refusal text.
- Generation keys used: `applied applied_at applied_nameSince pending_for pending_since rename_tries`.

- [ ] **Step 1: Failing tests** — `test/registry-session-display.test.sh` gains: absent line → enabled; non-empty → enabled; `RC_LABEL=""` → rc 1; RC-free row with a target still derives; unresolvable target → non-zero, stderr names the project. `test/supervisor-bridge.test.sh` claims:
13. desired ≠ applied; window 0 = managed claude, window 1 = shell **current**. tmux shim: on the first `send-keys`, rewrites `$HOMEDIR/.claude/sessions/<pid>.json` with `name` = desired and `nameSince` = old+1, and thereafter `capture-pane` on the exact pane returns `Session renamed to: <desired>`. Assert: 13a all `send-keys -t` equal `$ID:@0.%0`; 13b none equal `$ID`; 13c after round two `applied` = desired and `applied_nameSince` > the pre-rename `nameSince`.
13d. variant: pane shows the receipt, bridge still `Old` → `applied` stays `Old`.
13e. variant: bridge says desired but `nameSince` unchanged → `applied` stays `Old`.
14. foreground `vim` (shim variant chosen by `$TMUX_SHIM_FG`) → nothing typed.
15. `RC_LABEL=""` → `new-session` line has no `--remote-control`, has `--name "Alpha→Thing"`.
- [ ] **Step 2: Run** → red.
- [ ] **Step 3: Implement**

`lib/registry.sh`:
```bash
# registry_session_rc_enabled <id> - rc 0 unless the row says RC_LABEL="" (the RC-FREE choice).
# An ABSENT line means "rendered" and is RC-enabled; only the deliberate empty string opts out.
registry_session_rc_enabled() {
  local conf; conf="$(registry_dir)/${1:-}.conf"; [ -f "$conf" ] || return 1
  grep -q '^RC_LABEL=""$' "$conf" 2>/dev/null && return 1; return 0
}
```
Supervisor `:677-681`:
```bash
DISPLAY_ERR=""
if registry_session_rc_enabled "$NAME"; then
  RC_LABEL="$(registry_session_display "$NAME" 2>"$STATE_DIR/$NAME.display-stderr")" || { RC_LABEL=""; DISPLAY_ERR="$(cat "$STATE_DIR/$NAME.display-stderr")"; }
else RC_LABEL=""; fi
```
`:703-704`:
```bash
SESSION_NAME="$(sed -n 's/^SESSION_NAME="\(.*\)"/\1/p' "$CONF" 2>/dev/null | head -1)"
[ -n "$SESSION_NAME" ] || SESSION_NAME="$(registry_session_display "$NAME" 2>/dev/null)" || SESSION_NAME="$(bridge_gen_get "$STATE_DIR" "$NAME" applied 2>/dev/null)"
[ -n "$SESSION_NAME" ] || SESSION_NAME="$RC_LABEL"
```
In the healthy branch, right after `observe_row`'s success: `if [ -n "$DISPLAY_ERR" ] && [ ! -f "$STATE_DIR/$NAME.display-degraded" ]; then touch "$STATE_DIR/$NAME.display-degraded"; echo "session-supervisor: $NAME — the display no longer derives ($DISPLAY_ERR); keeping the applied name, supervising on identity." >&2; fi` (A7).

```bash
type_line() { # <pane-target> <text>
  tmuxc send-keys -t "$1" -l "$2" 2>/dev/null; sleep "${STEWARD_KEY_SETTLE_SEC:-2}"; tmuxc send-keys -t "$1" Enter 2>/dev/null; TYPED_THIS_ROUND=1
}
pane_foreground_is_managed() { # <pane-target> <managed-pid>
  local pane_pid fg mypg root="${BRIDGE_PROC_ROOT:-/proc}"
  [ "$(tmuxc display-message -p -t "$1" '#{pane_current_command}' 2>/dev/null)" = claude ] || return 1
  pane_pid="$(tmuxc display-message -p -t "$1" '#{pane_pid}' 2>/dev/null)"; [ -n "$pane_pid" ] || return 1
  fg="$(set -- $(sed 's/^.*) //' "$root/$pane_pid/stat" 2>/dev/null); printf '%s' "${6:-}")"   # field 8 tpgid
  mypg="$(set -- $(sed 's/^.*) //' "$root/$2/stat" 2>/dev/null); printf '%s' "${3:-}")"        # field 5 pgrp
  [ -n "$fg" ] && [ "$fg" = "$mypg" ]
}
```
The cycle, replacing :1365-1403 inside the `identified:managed` branch:
```bash
DESIRED="$RC_LABEL"; APPLIED="$(bridge_gen_get "$STATE_DIR" "$NAME" applied 2>/dev/null)"
if [ -n "$DESIRED" ] && [ "$DESIRED" != "$APPLIED" ]; then
  if [ "$(bridge_gen_get "$STATE_DIR" "$NAME" pending_for 2>/dev/null)" != "$DESIRED" ]; then
    bridge_gen_write "$STATE_DIR" "$NAME" pending_for="$DESIRED" pending_since="$B_SINCE" rename_tries=0   # the observation that must ADVANCE
  fi
  PENDING_SINCE="$(bridge_gen_get "$STATE_DIR" "$NAME" pending_since)"
  _rn_tries="$(bridge_gen_get "$STATE_DIR" "$NAME" rename_tries 2>/dev/null)"; _rn_tries="${_rn_tries:-0}"
  _rn_pane="$(tmuxc capture-pane -p -t "$B_PANE" 2>/dev/null)"
  if rename_receipt_seen "$_rn_pane" "$DESIRED" && [ "$B_NAME" = "$DESIRED" ] && [ "$B_SINCE" -gt "${PENDING_SINCE:-0}" ] 2>/dev/null; then
    bridge_gen_write "$STATE_DIR" "$NAME" applied="$DESIRED" applied_at="$(date +%s)000" applied_nameSince="$B_SINCE" rename_tries=0 pending_for= pending_since=
    echo "session-supervisor: $NAME — rename receipted: pane and bridge both report '$DESIRED', nameSince advanced." >&2
  elif rename_pane_busy "$_rn_pane"; then :
  elif [ "$_rn_tries" -ge 5 ]; then echo "session-supervisor: $NAME — RENAME NOT CONFIRMED after $_rn_tries attempts; pending stays." >&2
  elif ! pane_foreground_is_managed "$B_PANE" "$B_PID"; then echo "session-supervisor: $NAME — rename pending; the managed pane's foreground is not claude; not typing." >&2
  elif [ "$(bridge_os_birth "$B_PID" 2>/dev/null)" != "$B_BIRTH" ]; then :
  else type_line "$B_PANE" "/rename $DESIRED"; bridge_gen_write "$STATE_DIR" "$NAME" rename_tries=$(( _rn_tries + 1 )); fi
fi
```
- [ ] **Step 4: Run** → green (also `test/supervisor-mcp-guard.test.sh`, `-opencode`, `-zombie-veto`; fix any that asserted `send-keys -t $NAME`).
- [ ] **Step 5: Mutations** — `type_line "$NAME"` → 13a fails; drop `-gt PENDING_SINCE` → 13e fails; drop `B_NAME = DESIRED` → 13d fails; drop the foreground test → 14 fails.
- [ ] **Step 6: Commit** — `rename: to the pane the bridge names, receipted only when pane, bridge and nameSince all agree`. Push.

---

### Task 7: Watch consumes the adapter line

Spec §1 consumer census; A8.

**Files:** Modify `watch/bin/registry-dump` (`configDir`, `runtime`, `ownerUser`), `watch/lib.mjs`, `watch/session-watch.mjs:143-154`, `watch/restart-session.mjs:25-40`; Test `watch/test/lib.test.mjs`.

**Interfaces:**
- `parseObserveLine(text)` → `{id, answer, pid, birth, pane, name, nameSince, gen, classes}`; `-` → `null`; `pid` → number; throws unless exactly nine tab-separated fields.
- Watch runs `bash ~/scripts/bridge-observe.sh <id>` with `STEWARD_STATE_DIR`/`STEWARD_TMUX_SOCKET` from the estate dump (locally via `exec`, remotely via `ssh`) and parses the one line. Node never reads bridge JSON (A8).
- `decide()`: `obs.answer` ∈ {`unknown`,`uninspectable`,`grace`,`wait-veto`} → no `missing` alarm, no restart action, one info line `identity <answer>`.

- [ ] **Step 1: Failing tests**

```js
import { parseObserveLine, decide } from '../lib.mjs'
const T = '\t'
const L = ['s-1','identified:managed','4243','boot-1:111','s-1:@0.%0','Alpha→Thing','1789000000000','alive','live:managed'].join(T)
test('parseObserveLine: nine fields', () => {
  const o = parseObserveLine(L); assert.equal(o.id, 's-1'); assert.equal(o.answer, 'identified:managed'); assert.equal(o.pid, 4243); assert.equal(o.pane, 's-1:@0.%0')
})
test('parseObserveLine: dashes are null', () => { assert.equal(parseObserveLine(['s-1','no-process','-','-','-','-','-','gone-noreceipt',''].join(T)).pid, null) })
test('parseObserveLine: wrong field count throws', () => { assert.throws(() => parseObserveLine('s-1' + T + 'unknown')) })
for (const a of ['unknown', 'uninspectable', 'grace', 'wait-veto']) {
  test(`decide: answer ${a} => no missing alarm, no restart`, () => {
    const r = decide({}, { name: 's-1', proc: null, answer: a }, '2026-09-11T10:00:00Z', OPTS)
    assert.equal(r.actions.length, 0); assert.ok(!r.alerts.some(x => /missing/i.test(typeof x === 'string' ? x : (x.subject ?? ''))))
  })
}
```
- [ ] **Step 2: Run** `cd watch && npm test` → red.
- [ ] **Step 3: Implement**

```js
export function parseObserveLine(text) {
  const f = String(text ?? '').replace(/\n$/, '').split('\t')
  if (f.length !== 9) throw new Error(`observe line: expected 9 fields, got ${f.length}`)
  const d = v => (v === '-' || v === '' ? null : v)
  return { id: f[0], answer: f[1], pid: d(f[2]) === null ? null : Number(f[2]), birth: d(f[3]), pane: d(f[4]), name: d(f[5]), nameSince: d(f[6]) === null ? null : Number(f[6]), gen: f[7], classes: f[8] }
}
```
`registry-dump`: add `--arg configDir "$cfg" --arg runtime "${RUNTIME:-claude-code}" --arg ownerUser "$owner"` where `owner="$(registry_account_load "${ACCOUNT:-}" >/dev/null 2>&1 && printf '%s' "$ACCOUNT_USERNAME")"` and `cfg="$( [ -n "${LOGIN:-}" ] && registry_login_config_dir "$LOGIN" "$owner" 2>/dev/null || printf '' )"`; add the three fields to the object.
`session-watch.mjs:143-154` → `const cmd = \`STEWARD_STATE_DIR="$HOME/.local/state/${est.stateDirName}" STEWARD_TMUX_SOCKET="${SOCK}" bash ~/scripts/bridge-observe.sh ${s.id}\`; let o; try { o = parseObserveLine((remote ? await ssh(s, cmd) : await exec('bash', ['-c', cmd])).stdout) } catch { o = { answer: 'unknown', pid: null } }; obs.answer = o.answer; proc = o.pid ? findProcessByPanePid(psLocal, o.pid) : null`.
`decide()` at the top: `if (['unknown','uninspectable','grace','wait-veto'].includes(obs.answer)) { return { actions: [], alerts: [], next: { ...prev, identity: obs.answer }, info: [\`identity ${obs.answer}\`] } }` (match the function's real return shape).
`restart-session.mjs`: run the same `cmd`; refuse unless `o.answer === 'identified:managed'`; kill `o.pid`; poll until a new line shows `identified:managed` with a different pid. Delete `findProcess` and its tests when `grep -rn findProcess watch/` is empty.
- [ ] **Step 4: Run** → green. **Step 5: Mutation** — accept 8 fields → the throw test fails. **Step 6: Commit** — `watch: one adapter line, parsed once - never the vendor's JSON, never the label`. Push.

---

### Task 8: `linux/liveness-host.sh` consumes the adapter — OUTLINE

Spec §1 "liveness-host corroborates". **Outline: expand with writing-plans before executing.** For claude rows: `agent` = `running` iff the adapter says `identified:managed`; `not-running` iff `no-process`; else `unknown` (check `lib/liveness.sh`'s `agent` vocabulary; add `unknown` with a test if closed). Claims: managed → running; orphan/moved/unknown → unknown; uninspectable → the row's existing cannot-measure path.

---

### Task 9: Gates — rendered uniqueness, work rule, host reservation

Spec §3; A9.

**Files:** Modify `lib/registry.sh` (`registry_session_rendered_unique`, `registry_session_work_rule`), `bin/steward:2793`, `bin/steward:6064`, `linux/hub/enroll:546` (beside `registry_login_principal_gate`), supervisor (host reservation before `spawn_session` and before `type_line`); rewrite `test/session-rc-label-unique.test.sh`.

**Interfaces:**
- `registry_session_rendered_unique <candidate-conf>` → rc 0, or rc 65 `registry: display '<s>' is already rendered by <id>`; counts rows with `RUNTIME` unset/`claude-code`, RC-enabled, `LIFECYCLE` ≠ `retired`.
- `registry_session_work_rule <login> <project> [<exclude-id>]` → rc 0 or rc 65 naming the row; non-retired `claude-code` rows only; **register lifecycle**, never process state.
- Host reservation: the supervisor runs `bridge-observe.sh --all` and refuses to spawn or type when another row's line has `answer` starting `identified:` and `name` = `$DESIRED`, **or** another row's generation has `pending_for` = `$DESIRED` (A9). Any `uninspectable` line → refuse with `manual census required` when `STEWARD_RESERVATION_STRICT=1` (default on hubs), else warn.
- [ ] Claims: (a) two rows rendering the same string → second `session add` refused; (b) same string, one `RUNTIME="codex"` → allowed; (c) one `LIFECYCLE="retired"` → allowed; (d) `RC_LABEL=""` reserves nothing; (e) two `claude-code` rows with `LOGIN="jon-point"`+`TARGET_PROJECT="thing"` → refused naming the existing id; (f) same, one `RUNTIME="opencode"` → allowed; (g) another row `pending_for` the same name → spawn refused; (h) an uninspectable row → strict refuses / non-strict warns. Mutations: ignore RUNTIME; count retired; ignore pending. Commit — `gates: a rendered display is reserved at write, and at spawn against live and pending names`.

---

### Task 9b: Retarget refusal and reverse dependency closure

Spec §2 "Retarget is not rename"; A10.

**Files:** Modify `lib/registry.sh` — `registry_graph_mutation_gate <kind> <slug> <field> <new-value>` at the top of `registry_entity_write` (:2016) and `registry_project_write` (:2039) when the row exists and `MANAGED_BY`/`PARENT` changes; `registry_session_retarget_gate <id> <field> <new-value>` in every writer that changes `TARGET_PROJECT`/`TARGET_ENTITY` on an existing row (locate with `grep -n 'TARGET_PROJECT=\|TARGET_ENTITY=' bin/steward linux/hub/*` — `cmd_registry_session_realign` and enroll's confirm path). Test `test/registry-graph-gate.test.sh`.

**Interfaces:**
- `registry_graph_mutation_gate` computes the **reverse closure**: every non-retired session row whose `TARGET_PROJECT`/`TARGET_ENTITY` resolves through `<slug>` (walking `PARENT` and `MANAGED_BY` upward, max 64). rc 65 naming the first affected row unless every affected row is stopped: generation `stop_receipt` non-empty **and** `bridge-observe.sh <id>` answers `no-process`. rc 0 when the set is empty or all stopped.
- `registry_session_retarget_gate` → rc 65 unless `bridge-observe.sh <id>` answers `no-process`.
- Claims: (a) `PARENT` change on a project with one live session → refused, names it; (b) same with the session stopped → allowed; (c) `MANAGED_BY` change two levels up → refused naming a leaf session; (d) retarget on a live row → refused; (e) on a stopped row → allowed. Mutations: walk one level only → (c) passes falsely; ignore the receipt → (b) fails.
- Commit — `graph: a shared edge does not move under a live session`.

---

### Task 10: P0 census — OUTLINE (A11)

`linux/bridge-census.sh [--again]`: per row on this host, run the adapter; write `census=1` **only** for `identified:managed` (record pid/birth/procStart) or `no-process` with the veto empty (`stop_receipt=census-<epoch>`); for anything else write `census=blocked:<answer>` — read as not done by `bridge_answer`, so the row stays unknown until an operator resolves it and re-runs with `--again`. Refuse a second run without `--again`. Manifest row. Expand before executing.

---

### Task 11: `registry session derive <id>` — OUTLINE (A12)

Add `registry_display_for_target <conf>`: loads the conf in a subshell and renders from `TARGET_PROJECT`/`TARGET_ENTITY` ignoring `RC_LABEL` (reads the fields it is handed; no temporary unset). `derive`: (1) `registry_display_for_target` succeeds; (2) `registry_session_rendered_unique` on a **temporary copy** with the `RC_LABEL` line removed; (3) only then replace the row atomically (tmp + `mv`) with the line deleted; (4) commit. Any refusal leaves the file byte-identical. Expand before executing.

---

### Task 12: Remove legacy precedence — OUTLINE

Only when no estate carries a non-empty `RC_LABEL`: `registry_session_display` stops reading the label (warning for one release, then refusal); `test/identity-schema.test.sh`'s contract line becomes "a non-empty RC_LABEL is not read".

---

## Gates carried by this plan

- **P0** census (Task 10) before Task 5's supervisor is enabled on a host.
- **P1b** cases A and B (human, level 3) before Task 11's first live derive.
- **P2** macOS twin in the butler estate; `test/bridge-*.test.sh` under bash 3.2.
- **P3** manual census for cross-host/cross-estate logins (Task 9's strict reservation turns it into a refusal).

## Self-review

Spec coverage: §1 → T1–T5, T8, T10; §2 → T6, T9b; §3 → T9; §4 → T11–T12; §5 fixtures → distributed (state machine: T4 claims 1–14, T5 claims 1–12; rename: T6 13–15; rules: T9/T9b).
Advisor findings: A1 → T5 placement; A2 → T1 poison lines + T4 claim 11; A3 → T1 schema-first, `-L` first, control chars; A4 → T2 launch window, T3 dead history, T4 `in_window`, T5 spawn clears pid; A5 → T5 two rounds for orphan and no-process + veto; A6 → T6 nameSince advancement, shim rewrites the fixture, no `sed -i`; A7 → T6 `DISPLAY_ERR`, T5 refusal only on spawn; A8 → T4 adapter, T7/T8 consume the line; A9 → T4 `--all` + uninspectable, T9 pending reservation + strict; A10 → T9b; A11 → T2 census string, T10 blocked; A12 → T11 target-only renderer, gate-then-replace; A13 → spec 38c719c.
Type consistency: `bridge_answer`'s words identical in T2, T4, T5, T7; the observe line has nine fields in T4, T5, T7; `type_line <pane> <text>` in T6 only; generation keys listed once in T3 and used by name in T5/T6.
Placeholders: none in T1–T7, T9, T9b. **T8, T10, T11, T12 are outlines and say so** — expand with writing-plans before executing any of them.
