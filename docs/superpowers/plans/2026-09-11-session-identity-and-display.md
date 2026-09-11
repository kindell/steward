# Session Identity and Display Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Supervision identifies a session by the vendor's bridge file (ID ↔ pid+birth token ↔ pane) with launch provenance it can prove, never by its Remote Control label; the label is rendered from the register and renamed through the existing `/rename` cycle bound to the managed pane.

**Architecture:** `lib/bridge.sh` holds pure decision functions. `linux/bridge-observe.sh` is the **one, read-only adapter**: it measures and prints one line per row in a fixed vocabulary and writes nothing. **Only the supervisor mutates state** — generation, suspects, grace — and only from a line it just read. Watch, liveness-host and the census consume the same line. `RC_LABEL` survives only as a legacy override with precedence until the last row is migrated.

**Tech Stack:** bash 3.2-compatible shell, jq, tmux, Linux `/proc`; Node `node:test` for `watch/`.

**Spec:** `docs/superpowers/specs/2026-09-11-session-identity-and-display-design.md` (38c719c).

**Revision:** third version, after the advisor's second plan pass on 894c94c (13 findings, cited *B1…B13*). **Executable now: Tasks 1–3.** Tasks 4–7 are written to the keystroke but wait for a third pass on the provenance and mutation model. Tasks 8–12 are outlines.

## Global Constraints

- Never read or log `bridgeSessionId` or `messagingSocketPath`. jq selects fields by name.
- **The adapter never writes.** Every mutation — generation, suspect keys, grace — is the supervisor's, made from a line it read this round (B3).
- Every destructive or typing action requires the **same keyed observation** (`answer pid birth`) on two consecutive rounds; a different answer resets the key (B6). The broad runtime veto is scoped to **this row's tmux session panes**, never the whole socket (B7).
- A live process is ours only when the generation knows its birth **or** it carries this launch's nonce in its environment inside the launch window (B4). A dead bridge file is matched on `pid:procStart`.
- Config dir resolves through `registry_login_config_dir "$LOGIN" "<owner>"`; the login row must pass `registry_login_principal_gate` against the row's `ACCOUNT` (B8). Expected uid is the **row owner's** uid, not the observer's.
- Fields travel with the **unit separator** (byte 31, `$(printf '\037')`; not whitespace, so empty fields survive `read`) (B8). Any control byte in an emitted value or path is poison.
- No label match decides anything after Task 5; test `pgrep` shims fail loudly on `remote-control`.
- Tests never touch the machine. **No literal tab bytes, and no `\u` escape sequences anywhere in a file that passes through a JSON-carrying tool** — write `$(printf '\t')`; in jq use `explode`/`implode` (B1).
- Commit after every green step with the estate author: `git -c user.name="Jon Kindell" -c user.email="jon+butler@varvet.com" commit …` ending `Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>` / `Claude-Session: https://claude.ai/code/session_01RMVoAh7XJUuje1PCq3tEQX`. Branch `session-identity-display`; merge is butler's.

---

## File Structure

| file | responsibility |
|---|---|
| `lib/bridge.sh` (new) | pure: candidates with in-band poison and US framing, OS birth token, `bridge_is_descendant`, classification, four-way answer, generation file, keyed suspect helpers |
| `linux/bridge-observe.sh` (new) | **read-only adapter**: `<id>`, `--all`, `--bootstrap <id>`; prints ten US-separated fields; never writes |
| `linux/session-supervisor-linux.sh` (modify) | reads the line; owns every write; nonce at spawn; keyed two-round gate; rename cycle to the pane |
| `linux/deploy-manifest` (modify) | ships `lib/bridge.sh`, `linux/bridge-observe.sh`, `linux/bridge-census.sh` |
| `watch/bin/registry-dump`, `watch/lib.mjs`, `watch/session-watch.mjs`, `watch/restart-session.mjs` (modify) | consume the line; remote socket built on the remote; guarded kill |
| `linux/liveness-host.sh` (modify) | `agent` from the line |
| `lib/registry.sh` (modify) | `registry_session_rc_enabled`, gates, `registry_display_for_target`, stop-receipt fields |
| `bin/steward`, `linux/hub/enroll` (modify) | gates; verbs `registry session derive`, `registry session stopped` |
| `linux/bridge-census.sh` (new) | P0 via `--bootstrap` facts |

---

### Task 1: `lib/bridge.sh` — candidates by name, poison in band, US framing, birth token

Spec §1; B1, B8.

**Files:** Create `lib/bridge.sh`; Test `test/bridge-classify.test.sh`.

**Interfaces:**
- `US="$(printf '\037')"` — the field separator for every line this library or the adapter emits.
- `bridge_candidates <id> <sessions-dir>` → per file that concerns `<id>` or is broken:
  - `ok US path US pid US procStart US tmux US name US nameSince US sessionId US startedAt US mtime_ms`
  - `!unclassifiable US path US reason`
  Complete, typed files naming another id are silent. An empty value is emitted as `-`. Poison reasons: `symlink`, `not-regular`, `size`, `json`, `notobject`, `types`, `control-char`, `filename-pid` (file name ≠ JSON pid), `stat`, `path-control`.
- `bridge_os_birth <pid>` → `<boot_id>:<start_ticks>`; rc 1 when gone. `BRIDGE_PROC_ROOT`.
- `bridge_is_descendant <pid> <ancestor>` — the supervisor's walk, moved here.

- [ ] **Step 1: Write the failing test**

```bash
#!/bin/bash
# test/bridge-classify.test.sh - candidates by name never by order; poison is a LINE;
# a missing field is schema, not foreign; empty fields survive framing (US, not tab).
set -u
here="$(CDPATH= cd -- "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
pass=0; fail=0
ok()  { pass=$((pass+1)); printf '  ok   %s\n' "$1"; }
bad() { fail=$((fail+1)); printf '  FAIL %s\n     %s\n' "$1" "${2:-}"; }
is()  { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "wanted '$3', got '$2'"; fi; }
has() { case "$2" in *"$3"*) ok "$1" ;; *) bad "$1" "missing '$3' in: $2" ;; esac; }
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
. "$here/lib/bridge.sh" || { echo "cannot source lib/bridge.sh"; exit 1; }
US="$(printf '\037')"
ID="s-0000000000000001"; D="$T/sessions"; mkdir -p "$D"
mk() { # <pid> <tmux> <name> ; file is <pid>.json
  printf '{"pid":%s,"procStart":123,"tmux":"%s","name":"%s","nameSince":1789000000000,"sessionId":"aaaa-bbbb","startedAt":1789000000000,"status":"idle","bridgeSessionId":"SECRET","messagingSocketPath":"/tmp/SECRET.sock"}\n' "$1" "$2" "$3" > "$D/$1.json"
}
oks()    { printf '%s\n' "$1" | grep -c "^ok$US"; }
poison() { printf '%s\n' "$1" | grep -c "^!unclassifiable$US"; }
fld()    { printf '%s\n' "$1" | grep "^ok$US" | head -1 | cut -d "$US" -f "$2"; }
echo "== 1. one well-formed file: one ok line, fields by position, no secret =="
mk 100 "$ID:@0.%0" "Alpha→Beta"
out="$(bridge_candidates "$ID" "$D")"
is "1a one ok" "$(oks "$out")" "1"; is "1b no poison" "$(poison "$out")" "0"
is "1c pid" "$(fld "$out" 3)" "100"; is "1d tmux" "$(fld "$out" 5)" "$ID:@0.%0"; is "1e name" "$(fld "$out" 6)" "Alpha→Beta"
case "$out" in *SECRET*) bad "1f no secret leaks" "$out" ;; *) ok "1f no secret leaks" ;; esac
echo "== 2. a complete file for another id is silent; a prefix of the id is not the id =="
mk 101 "s-0000000000000002:@0.%0" "Other"; mk 102 "${ID}0:@0.%0" "Prefix"
out="$(bridge_candidates "$ID" "$D")"; is "2a one ok" "$(oks "$out")" "1"; is "2b no poison" "$(poison "$out")" "0"
echo "== 3. broken files are poison lines, each named =="
printf '{"pid":103,"tmux":"%s"' "$ID:@1.%1" > "$D/103.json"                        # truncated -> json
ln -s "$D/100.json" "$D/104.json"                                                    # symlink
ln -s "$D/nope.json" "$D/108.json"                                                   # dangling symlink
head -c 70000 /dev/zero | tr '\0' 'x' > "$D/105.json"                                # size
printf '{"pid":"abc","procStart":1,"tmux":"%s","name":"x","nameSince":1,"sessionId":"s","startedAt":1}\n' "$ID:@2.%2" > "$D/106.json"   # types
printf '{"pid":109,"procStart":1,"name":"no tmux","nameSince":1,"sessionId":"s","startedAt":1}\n' > "$D/109.json"                  # types (missing tmux)
printf '{"pid":110,"procStart":1,"tmux":"%s","name":"tab\\there","nameSince":1,"sessionId":"s","startedAt":1}\n' "$ID:@3.%3" > "$D/110.json"  # control-char
printf '{"pid":999,"procStart":1,"tmux":"%s","name":"x","nameSince":1,"sessionId":"s","startedAt":1}\n' "$ID:@4.%4" > "$D/111.json"          # filename-pid
out="$(bridge_candidates "$ID" "$D")"
is "3a accepted unchanged" "$(oks "$out")" "1"
is "3b eight poison lines" "$(poison "$out")" "8"
for f in 103 104 105 106 108 109 110 111; do has "3c $f named" "$out" "$f.json"; done
has "3d filename-pid reason" "$out" "filename-pid"
echo "== 4. an EMPTY name survives framing as '-' (a tab-framed read would have collapsed it) =="
rm -f "$D"/10[1-9].json "$D"/11?.json
printf '{"pid":112,"procStart":1,"tmux":"%s","name":"","nameSince":1,"sessionId":"s","startedAt":1}\n' "$ID:@5.%5" > "$D/112.json"
out="$(bridge_candidates "$ID" "$D" | grep "${US}112${US}")"; is "4a name is -" "$(printf '%s\n' "$out" | cut -d "$US" -f 6)" "-"
is "4b sessionId still in place" "$(printf '%s\n' "$out" | cut -d "$US" -f 8)" "s"
echo "== 5. two complete files for one id are two ok lines =="
mk 107 "$ID:@3.%3" "Second"
out="$(bridge_candidates "$ID" "$D")"; is "5a three ok (100,112,107)" "$(oks "$out")" "3"
echo "== 6. birth token; odd comm does not shift the field =="
P="$T/proc"; mkdir -p "$P/sys/kernel/random" "$P/4242" "$P/4243"; printf 'boot-1111\n' > "$P/sys/kernel/random/boot_id"
printf '4242 (claude) S 1 4242 4242 0 -1 4194560 100 0 0 0 5 5 0 0 20 0 1 0 987654 1000 200 1\n' > "$P/4242/stat"
printf '4243 (my (odd) claude) S 1 1 1 0 -1 0 0 0 0 0 0 0 0 0 20 0 1 0 555 0 0 0\n' > "$P/4243/stat"
is "6a token" "$(BRIDGE_PROC_ROOT="$P" bridge_os_birth 4242)" "boot-1111:987654"
is "6b odd comm" "$(BRIDGE_PROC_ROOT="$P" bridge_os_birth 4243)" "boot-1111:555"
BRIDGE_PROC_ROOT="$P" bridge_os_birth 9999 >/dev/null 2>&1; is "6c gone rc 1" "$?" "1"
echo "== 7. descendant walk via a ps shim =="
BIN="$T/bin"; mkdir -p "$BIN"
cat > "$BIN/ps" <<'EOF'
#!/bin/sh
pid=""; prev=""; for a in "$@"; do [ "$prev" = "-p" ] && pid="$a"; prev="$a"; done
case "$pid" in 30) echo " 20";; 20) echo " 10";; 10) echo " 1";; *) exit 1;; esac
EOF
chmod 755 "$BIN/ps"
PATH="$BIN:$PATH" bridge_is_descendant 30 10; is "7a" "$?" "0"; PATH="$BIN:$PATH" bridge_is_descendant 30 99; is "7b" "$?" "1"
printf '\n%d passed, %d failed\n' "$pass" "$fail"; [ "$fail" -eq 0 ]
```

- [ ] **Step 2: Run** → `cannot source lib/bridge.sh`, exit 1.
- [ ] **Step 3: Write the library**

```bash
#!/bin/bash
# lib/bridge.sh - the vendor's local bridge attestation, read strictly and by name.
#
# THE FILE IS AN UNDOCUMENTED VENDOR FORMAT (<CLAUDE_CONFIG_DIR>/sessions/<pid>.json).
# Measured 2026-09-11 (P1): appears within 1 s of spawn, follows /rename within 1 s, is
# removed on clean exit and TERM, is LEFT BEHIND on KILL -9, and its `tmux` field records
# the session name AT REGISTRATION. Nothing here trusts it: every candidate is classified.
#
# POISON TRAVELS IN BAND as a `!unclassifiable` line. FIELDS TRAVEL WITH THE UNIT
# SEPARATOR (byte 31): tab is IFS whitespace and `read` collapses an empty field, so a row
# with an empty name shifted every later field one to the left. US is not whitespace.
# SCHEMA FIRST, MEMBERSHIP SECOND: a file missing `tmux` is poison, never "foreign".
# TWO FIELDS ARE NEVER READ: bridgeSessionId and messagingSocketPath.
# bash 3.2: no arrays, no `local -n`, no ${var,,}. jq uses explode/implode, never a
# backslash-u class: a class written that way was decoded into raw bytes by a tool once.
set -u
BRIDGE_MAX_BYTES="${BRIDGE_MAX_BYTES:-65536}"
US="$(printf '\037')"

_bridge_size() { wc -c < "$1" 2>/dev/null | tr -d ' '; }
_bridge_mtime_ms() { local s; s="$(stat -c %Y "$1" 2>/dev/null || stat -f %m "$1" 2>/dev/null)" || return 1; printf '%s000' "$s"; }
_bridge_poison() { printf '!unclassifiable%s%s%s%s\n' "$US" "$1" "$US" "$2"; }
_bridge_has_ctl() { LC_ALL=C printf '%s' "$1" | LC_ALL=C tr -d '\040-\176\200-\377' | LC_ALL=C grep -q .; }   # any byte < 32 or = 127

bridge_candidates() { # <id> <sessions-dir>
  local id="${1:-}" dir="${2:-}" f sz row base mtime
  [ -n "$id" ] && [ -d "$dir" ] || return 0
  for f in "$dir"/*.json; do
    if _bridge_has_ctl "$f"; then _bridge_poison "$(printf '%s' "$f" | LC_ALL=C tr -c '\040-\176' '?')" path-control; continue; fi
    if [ -L "$f" ]; then _bridge_poison "$f" symlink; continue; fi
    [ -e "$f" ] || continue
    if [ ! -f "$f" ]; then _bridge_poison "$f" not-regular; continue; fi
    sz="$(_bridge_size "$f")"; if [ -z "$sz" ] || [ "$sz" -gt "$BRIDGE_MAX_BYTES" ]; then _bridge_poison "$f" size; continue; fi
    base="$(basename "$f" .json)"
    row="$(jq -r --arg id "$id" --arg base "$base" '
      def ctl: (explode | any(. < 32 or . == 127));
      def esc: gsub("[.^$*+?()\\[\\]{}|\\\\-]"; "\\\\" + .);
      def us: ([31] | implode);
      if type != "object" then "!notobject"
      elif ((.pid|type) != "number") or ((.procStart|type) != "number") or ((.tmux|type) != "string")
        or ((.name|type) != "string") or ((.nameSince|type) != "number") or ((.sessionId|type) != "string")
        or ((.startedAt|type) != "number") then "!types"
      elif (.tmux|ctl) or (.name|ctl) or (.sessionId|ctl) then "!control-char"
      elif ((.pid|tostring) != $base) then "!filename-pid"
      elif (.tmux | test("^" + ($id|esc) + ":@[0-9]+[.]%[0-9]+$")) | not then "!foreign"
      else [(.pid|tostring), (.procStart|tostring), .tmux, (if .name == "" then "-" else .name end),
            (.nameSince|tostring), (if .sessionId == "" then "-" else .sessionId end), (.startedAt|tostring)] | join(us) end
    ' "$f" 2>/dev/null)" || row="!json"
    case "$row" in
      "!foreign") continue ;;
      "!"*|"") _bridge_poison "$f" "${row#!}"; continue ;;
    esac
    mtime="$(_bridge_mtime_ms "$f")" || { _bridge_poison "$f" stat; continue; }
    printf 'ok%s%s%s%s%s%s\n' "$US" "$f" "$US" "$row" "$US" "$mtime"
  done
  return 0
}

bridge_os_birth() { # <pid> -> boot_id:start_ticks ; rc 1 when gone
  local pid="${1:-}" root="${BRIDGE_PROC_ROOT:-/proc}" boot stat rest
  case "$pid" in ''|*[!0-9]*) return 1 ;; esac
  [ -r "$root/$pid/stat" ] || return 1
  boot="$(cat "$root/sys/kernel/random/boot_id" 2>/dev/null)" || return 1
  stat="$(cat "$root/$pid/stat" 2>/dev/null)" || return 1
  rest="${stat##*) }"; set -- $rest; [ "$#" -ge 20 ] || return 1
  printf '%s:%s' "$boot" "${20}"
}

bridge_is_descendant() { # <pid> <ancestor>
  local pid="${1:-}" target="${2:-}" n=0
  while [ -n "$pid" ] && [ "$pid" -gt 1 ] 2>/dev/null && [ "$n" -lt 40 ]; do
    [ "$pid" = "$target" ] && return 0
    pid="$(ps -o ppid= -p "$pid" 2>/dev/null | tr -d ' ')"; n=$((n+1))
  done
  return 1
}
```

- [ ] **Step 4: Run** → green (B1: eight poison files, eight expected).
- [ ] **Step 5: Mutations** — swap `!types` and `!foreign` → 3c 109 fails; `-e` before `-L` → 108 fails; drop `ctl` → 110 fails; drop `filename-pid` → 111 fails; `join(us)`→`join("|")` → 4a/4b fail; `${20}`→`${19}` → 6a/6b fail.
- [ ] **Step 6: Commit** — `bridge: attestation read by name, framed with US, poison in band`.

---

### Task 2: classification and the four-way answer

Spec §1; B4 (provenance flag), B11.

**Interfaces:**
- `bridge_classify_candidate <alive> <uid_ok> <birth_known> <launch_claim> <stored_pane_has_pid> <any_pane_has_pid> <dead_match>` → `live:managed` `live:moved` `live:orphan` `stale` `unclassifiable`.
  - `launch_claim` = **all** of: generation has an open launch (`launch_ms` set, `pid` empty), now < `launch_ms + GRACE_MS`, candidate `startedAt ≥ launch_ms`, **and the candidate's environment carries this launch's nonce** (B4). The adapter computes it; the library only trusts the flag.
- `bridge_answer <classes> <gen_state> <tmux_present> <veto> <census>` → `identified:managed` `identified:orphan` `identified:moved` `no-process` `unknown` `wait-veto` `grace`; only exactly `1` is census-done (B11).

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
echo "== classify: alive uid birth_known launch_claim stored any dead_match =="
is "known pid in stored pane = managed"        "$(C 1 1 1 0 1 1 0)" "live:managed"
is "known pid under another pane = moved"      "$(C 1 1 1 0 0 1 0)" "live:moved"
is "known pid under no pane = orphan"          "$(C 1 1 1 0 0 0 0)" "live:orphan"
is "fresh pid WITH launch claim = managed"     "$(C 1 1 0 1 1 1 0)" "live:managed"
is "fresh pid without claim = unclassifiable"  "$(C 1 1 0 0 1 1 0)" "unclassifiable"
is "alive, wrong uid = unclassifiable"         "$(C 1 0 1 0 1 1 0)" "unclassifiable"
is "dead, in history = stale"                  "$(C 0 1 0 0 0 0 1)" "stale"
is "dead, unknown to history = unclassifiable" "$(C 0 1 0 0 0 0 0)" "unclassifiable"
echo "== answer: classes gen tmux veto census =="
is "first-ever (census=1)"                       "$(bridge_answer ''  none 0 0 1)" "no-process"
is "pre-census = unknown"                        "$(bridge_answer ''  none 0 0 '')" "unknown"
is "census blocked = unknown"                    "$(bridge_answer ''  none 0 0 'blocked:split-brain')" "unknown"
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
bridge_classify_candidate() { # alive uid_ok birth_known launch_claim stored any dead_match
  local alive="${1:-0}" uid_ok="${2:-0}" known="${3:-0}" claim="${4:-0}" stored="${5:-0}" any="${6:-0}" dead="${7:-0}"
  if [ "$alive" = 1 ]; then
    [ "$uid_ok" = 1 ] || { printf 'unclassifiable'; return 0; }
    # OURS IN EXACTLY TWO WAYS: the generation knows this birth, or the adapter proved the
    # launch claim (open launch, inside the window, started after it, AND carrying this
    # launch's nonce in its environment - a replacement someone typed into the pane cannot
    # inherit that). Everything else is unclassifiable (B4).
    [ "$known" = 1 ] || [ "$claim" = 1 ] || { printf 'unclassifiable'; return 0; }
    if [ "$stored" = 1 ]; then printf 'live:managed'; elif [ "$any" = 1 ]; then printf 'live:moved'; else printf 'live:orphan'; fi; return 0
  fi
  if [ "$dead" = 1 ]; then printf 'stale'; else printf 'unclassifiable'; fi
}
bridge_answer() { # classes gen_state tmux_present veto census
  local classes="${1:-}" gen="${2:-none}" tmux="${3:-0}" veto="${4:-0}" census="${5:-}" w live=0 unclass=0 kind=""
  for w in $classes; do case "$w" in live:*) live=$((live+1)); kind="${w#live:}" ;; stale) : ;; *) unclass=$((unclass+1)) ;; esac; done
  [ "$unclass" -eq 0 ] || { printf 'unknown'; return 0; }
  [ "$live" -le 1 ] || { printf 'unknown'; return 0; }
  [ "$live" -eq 1 ] && { printf 'identified:%s' "$kind"; return 0; }
  case "$gen" in grace) printf 'grace'; return 0 ;; alive) printf 'unknown'; return 0 ;; none) [ "$census" = 1 ] || { printf 'unknown'; return 0; } ;; gone-receipt|gone-noreceipt) : ;; *) printf 'unknown'; return 0 ;; esac
  if [ "$veto" = 1 ]; then printf 'wait-veto'; else printf 'no-process'; fi
}
```
- [ ] **Step 4: Run** → green. **Step 5: Mutations** — drop the `claim` alternative → "fresh pid WITH launch claim" fails; `[ "$census" = 1 ]`→`[ -n "$census" ]` → "census blocked" fails; `-le 1`→`-le 2` → split-brain fails. **Step 6: Commit** — `bridge: a fresh pid is ours only with the launch nonce; census is done only when it says 1`.

---

### Task 3: the generation, with dead-file history and colon-safe birth (B2)

**Interfaces:** `bridge_gen_path/get/write` as before; keys add `launch_nonce launch_pane_pid launch_pane_birth`. History entries are `pid:procStart:birth` where `birth` itself contains a colon; matchers split off exactly two leading fields. Keyed suspect helpers (B6): `bridge_suspect_key <answer> <pid> <birth>`, `bridge_suspect_confirmed <file> <key>`.

- [ ] **Step 1: Failing test**

```bash
#!/bin/bash
# test/bridge-generation.test.sh - history and bootstrap, bounded, never a second truth;
# a DEAD file is matched on pid:procStart; a birth with a colon round-trips (B2);
# a suspect remembers WHAT it suspected (B6).
set -u
here="$(CDPATH= cd -- "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
pass=0; fail=0
ok()  { pass=$((pass+1)); printf '  ok   %s\n' "$1"; }
bad() { fail=$((fail+1)); printf '  FAIL %s\n     %s\n' "$1" "${2:-}"; }
is()  { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "wanted '$3', got '$2'"; fi; }
. "$here/lib/bridge.sh" || exit 1
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT; ID="s-0000000000000001"
bridge_gen_get "$T" "$ID" pid >/dev/null 2>&1; is "absent rc 1" "$?" "1"
bridge_gen_write "$T" "$ID" pid=100 birth=boot-x:1 procStart=500 uid=1001 launch_ms=1789000000000
is "pid" "$(bridge_gen_get "$T" "$ID" pid)" "100"
bridge_gen_matches_live "$T" "$ID" 100 boot-x:1; is "current live, colon in birth" "$?" "0"
bridge_gen_write "$T" "$ID" applied="Alpha→Beta"; is "merge keeps pid" "$(bridge_gen_get "$T" "$ID" pid)" "100"; is "applied" "$(bridge_gen_get "$T" "$ID" applied)" "Alpha→Beta"
bridge_gen_write "$T" "$ID" pid=101 birth=boot-x:2 procStart=501
bridge_gen_matches_live "$T" "$ID" 100 boot-x:1;  is "old live pair in history (B2)" "$?" "0"
bridge_gen_matches_live "$T" "$ID" 100 boot-y:1;  is "wrong boot id no" "$?" "1"
bridge_gen_matches_dead "$T" "$ID" 100 500;       is "old DEAD pair by procStart" "$?" "0"
bridge_gen_matches_dead "$T" "$ID" 100 999;       is "wrong procStart no" "$?" "1"
bridge_gen_write "$T" "$ID" pid= birth=;          is "clearing pid opens a launch claim" "$(bridge_gen_get "$T" "$ID" pid)" ""
bridge_gen_matches_dead "$T" "$ID" 101 501;       is "cleared pid still in history" "$?" "0"
i=3; while [ $i -le 12 ]; do bridge_gen_write "$T" "$ID" pid=$((100+i)) birth=boot-x:$i procStart=$((500+i)); i=$((i+1)); done
bridge_gen_matches_dead "$T" "$ID" 100 500;       is "bounded to 8: oldest fell off" "$?" "1"
bridge_gen_matches_dead "$T" "$ID" 105 505;       is "recent kept" "$?" "0"
bridge_gen_write "$T" "$ID" applied="Point→Chalmers→HR Pilot"; is "spaces/arrows survive" "$(bridge_gen_get "$T" "$ID" applied)" "Point→Chalmers→HR Pilot"
bridge_gen_write "$T" "$ID" "bad key=1" >/dev/null 2>&1; is "bad key rc 64" "$?" "64"
echo "== suspect: the SAME key twice in a row, reset by any other =="
S="$T/suspect"; K1="$(bridge_suspect_key identified:orphan 4500 boot-x:9)"; K2="$(bridge_suspect_key identified:moved 4500 boot-x:9)"
bridge_suspect_confirmed "$S" "$K1"; is "first sighting not confirmed" "$?" "1"
bridge_suspect_confirmed "$S" "$K1"; is "second identical sighting confirmed" "$?" "0"
bridge_suspect_confirmed "$S" "$K1"; bridge_suspect_confirmed "$S" "$K2"; is "a different answer is not confirmed" "$?" "1"
bridge_suspect_confirmed "$S" "$K1"; is "and it reset the original" "$?" "1"
K3="$(bridge_suspect_key identified:orphan 4501 boot-x:9)"
bridge_suspect_confirmed "$S" "$K1"; bridge_suspect_confirmed "$S" "$K3"; is "same answer, different pid, not confirmed" "$?" "1"
printf '\n%d passed, %d failed\n' "$pass" "$fail"; [ "$fail" -eq 0 ]
```

- [ ] **Step 2: Run** → red.
- [ ] **Step 3: Append**

```bash
# ---- generation: <state-dir>/<id>.generation, key=value, written atomically ----
bridge_gen_path() { printf '%s/%s.generation' "$1" "$2"; }
bridge_gen_get()  { local f; f="$(bridge_gen_path "$1" "$2")"; [ -f "$f" ] || return 1; sed -n "s/^$3=//p" "$f" | head -1; }
_bridge_gen_hist() { sed -n 's/^history=//p' "$(bridge_gen_path "$1" "$2")" 2>/dev/null | head -1; }
# an entry is pid:procStart:birth and birth is boot_id:ticks - strip TWO leading fields, keep the rest whole (B2)
_bridge_hist_pid()   { printf '%s' "${1%%:*}"; }
_bridge_hist_ps()    { local r="${1#*:}"; printf '%s' "${r%%:*}"; }
_bridge_hist_birth() { local r="${1#*:}"; printf '%s' "${r#*:}"; }
bridge_gen_matches_live() { # sd id pid birth
  [ "$(bridge_gen_get "$1" "$2" pid 2>/dev/null)" = "$3" ] && [ "$(bridge_gen_get "$1" "$2" birth 2>/dev/null)" = "$4" ] && return 0
  local h; for h in $(_bridge_gen_hist "$1" "$2"); do [ "$(_bridge_hist_pid "$h")" = "$3" ] && [ "$(_bridge_hist_birth "$h")" = "$4" ] && return 0; done; return 1
}
bridge_gen_matches_dead() { # sd id pid procStart
  [ "$(bridge_gen_get "$1" "$2" pid 2>/dev/null)" = "$3" ] && [ "$(bridge_gen_get "$1" "$2" procStart 2>/dev/null)" = "$4" ] && return 0
  local h; for h in $(_bridge_gen_hist "$1" "$2"); do [ "$(_bridge_hist_pid "$h")" = "$3" ] && [ "$(_bridge_hist_ps "$h")" = "$4" ] && return 0; done; return 1
}
bridge_gen_write() { # sd id key=value ...   atomic; pushes the old triple when pid changes; bounded 8
  local dir="$1" id="$2" f tmp kv k v old_pid old_ps old_b hist; shift 2
  f="$(bridge_gen_path "$dir" "$id")"; tmp="$f.tmp.$$"; mkdir -p "$dir"
  old_pid="$(bridge_gen_get "$dir" "$id" pid 2>/dev/null)"; old_ps="$(bridge_gen_get "$dir" "$id" procStart 2>/dev/null)"; old_b="$(bridge_gen_get "$dir" "$id" birth 2>/dev/null)"
  hist="$(_bridge_gen_hist "$dir" "$id")"
  : > "$tmp"; [ -f "$f" ] && grep -v '^history=' "$f" > "$tmp"
  for kv in "$@"; do
    k="${kv%%=*}"; v="${kv#*=}"
    case "$k" in *[!A-Za-z0-9_]*|'') echo "bridge: generation key '$k' refused" >&2; rm -f "$tmp"; return 64 ;; esac
    grep -v "^$k=" "$tmp" > "$tmp.2"; mv "$tmp.2" "$tmp"; printf '%s=%s\n' "$k" "$v" >> "$tmp"
    if [ "$k" = pid ] && [ -n "$old_pid" ] && [ "$v" != "$old_pid" ]; then hist="$hist $old_pid:${old_ps:--}:${old_b:--}"; fi
  done
  hist="$(printf '%s\n' $hist | grep . | tail -8 | tr '\n' ' ')"; hist="${hist% }"
  [ -n "$hist" ] && printf 'history=%s\n' "$hist" >> "$tmp"
  mv -f "$tmp" "$f"
}
# ---- keyed two-round suspect (B6): the SAME answer+pid+birth must be seen twice in a row ----
bridge_suspect_key() { printf '%s %s %s' "${1:-}" "${2:--}" "${3:--}"; }
bridge_suspect_confirmed() { # <file> <key> -> rc 0 when the file already held exactly this key; always rewrites the file with the key
  local f="$1" key="$2" prev=""
  [ -f "$f" ] && prev="$(cat "$f")"
  printf '%s\n' "$key" > "$f"
  [ "$prev" = "$key" ]
}
```
- [ ] **Step 4: Run** → green. **Step 5: Mutations** — `_bridge_hist_birth` as `${1##*:}` → "old live pair in history" fails; `tail -8`→`tail -20` → "bounded" fails; compare only the answer word in the suspect → "same answer, different pid" fails. **Step 6: Commit** — `bridge: colon-safe history, and a suspect that remembers what it suspected`.

---

### Task 4: `linux/bridge-observe.sh` — read-only, ten fields, `--bootstrap`

Spec §1; B3, B4, B5, B7, B8, B13.

**Files:** Create `linux/bridge-observe.sh`; Test `test/bridge-observe.test.sh`; `linux/deploy-manifest` rows `lib/bridge.sh → scripts/lib/bridge.sh 755 lib` (after line 58) and `linux/bridge-observe.sh → scripts/bridge-observe.sh 755 scripts` (after line 37).

**Interfaces:**
- Line: `id US answer US pid US birth US pane US name US nameSince US gen_state US classes US launch_pid_alive` — ten fields, `-` for empty. `launch_pid_alive` ∈ `1|0|-` (B5).
- `bridge-observe.sh <id>` — read-only. Never writes the generation or any file.
- `bridge-observe.sh --all` — every row on this host **whose owner is the observer's uid**; other owners' rows → `uninspectable` (B11).
- `bridge-observe.sh --bootstrap <id>` — same measurement, but classification ignores generation knowledge and the launch claim: a live same-uid process under a pane is `live:*`; `gen_state` is `bootstrap` and census is treated as done. For the census only (B13).
- Facts per live candidate: uid (`ps -o uid=`) = **owner's** uid (`id -u <owner>`); birth known (generation); `launch_claim` = open launch ∧ now < `launch_ms + GRACE_MS` ∧ `startedAt ≥ launch_ms` ∧ `/proc/<pid>/environ` contains `STEWARD_LAUNCH_NONCE=<generation.launch_nonce>` (B4); stored pane via `display-message -t <tmux> '#{pane_pid}'`; any pane via `list-panes -a`. Veto: runtime pids under **`list-panes -s -t =<id>`** only (B7).
- Refusals → `unknown` with the reason in `classes`: `row-does-not-load`, `account-does-not-resolve`, `owner-uid-unknown`, `login-account-mismatch` (B8), `config-dir-unreadable`, `sessions-dir-unreadable` (B8).
- Env: `STEWARD_STATE_DIR`, `STEWARD_TMUX_SOCKET` (required), `STEWARD_REGISTRY_LIB`, `STEWARD_BRIDGE_LIB`, `BRIDGE_PROC_ROOT`, `STEWARD_BRIDGE_GRACE_MS` (600000), `STEWARD_NOW_MS` (test override), `STEWARD_SELF_HOST`.

- [ ] **Step 1: Failing test** (`test/bridge-observe.test.sh`; fixture as `test/supervisor-reap.test.sh` plus `/proc` with `stat` and `environ` files, an `id` shim answering `-u <owner>` with a fixed uid, `STEWARD_NOW_MS`). Claims: (1) known birth in stored pane → `identified:managed`; **generation file byte-identical afterwards** (B3); (2) fresh pid, no launch → `unknown`; (3) open launch, in window, nonce in `environ`, started after → `identified:managed`; (4) same without the nonce → `unknown` (B4); (5) nonce present but window elapsed → `unknown`; (6) moved; (7) orphan; (8) stale by `pid:procStart` → `no-process`; (9) two live → `unknown`; (10) poison line → `unknown`; (11) unrelated live claude under **another** session's pane, this row dead → `no-process` (B7); (12) `launch_pane_pid` recorded and dead, past window, no candidates → field 10 `0`, `gen_state` `gone-noreceipt` (B5); (13) `--all` with a row of another uid → `uninspectable`; (14) `sessions/` unreadable → `unknown … sessions-dir-unreadable`; (15) `LOGIN` failing the principal gate → `unknown … login-account-mismatch`; (16) `--bootstrap` on a live legacy process with no generation → `identified:managed` while the plain call says `unknown` (B13); (17) `LABEL_LOG` empty after every claim.

- [ ] **Step 2: Run** → red.
- [ ] **Step 3: Implement**

```bash
#!/bin/bash
# linux/bridge-observe.sh <id> | --all | --bootstrap <id> - THE adapter. Read-only: it measures,
# asks lib/bridge.sh, prints one ten-field line. It writes NOTHING; the supervisor owns state (B3).
set -u
REG_LIB="${STEWARD_REGISTRY_LIB:-$HOME/scripts/lib/registry.sh}"; . "$REG_LIB" || exit 78
BRIDGE_LIB="${STEWARD_BRIDGE_LIB:-$(dirname "$REG_LIB")/bridge.sh}"; . "$BRIDGE_LIB" || exit 78
SD="${STEWARD_STATE_DIR:?}"; SOCK="${STEWARD_TMUX_SOCKET:?}"; GRACE_MS="${STEWARD_BRIDGE_GRACE_MS:-600000}"
PROC="${BRIDGE_PROC_ROOT:-/proc}"; NOW_MS="${STEWARD_NOW_MS:-$(( $(date +%s) * 1000 ))}"
RUNTIME_VETO_PAT='(^|[ /])(claude|opencode)'
tmuxc() { command tmux -S "$SOCK" "$@"; }
line() { printf '%s' "$1"; shift; for a in "$@"; do printf '%s%s' "$US" "$a"; done; printf '\n'; }
env_has_nonce() { [ -n "$2" ] && LC_ALL=C tr '\0' '\n' < "$PROC/$1/environ" 2>/dev/null | grep -qx "STEWARD_LAUNCH_NONCE=$2"; }
observe() { # <id> <bootstrap 0|1>
  local id="$1" boot="${2:-0}" owner cfg uid classes="" tmux_present veto gen_state gp launch nonce census lpid lalive="-" open_launch
  local tag path pid pstart tmuxf name since sid started mtime alive uid_ok known claim stored any dead birth sp p q c
  local L_PID="-" L_BIRTH="-" L_PANE="-" L_NAME="-" L_SINCE="-" all_panes sess_panes
  registry_load "$id" >/dev/null 2>&1 || { line "$id" unknown - - - - - - row-does-not-load -; return; }
  owner="$( registry_account_load "${ACCOUNT:-}" >/dev/null 2>&1 && printf '%s' "$ACCOUNT_USERNAME" )"
  [ -n "$owner" ] || { line "$id" unknown - - - - - - account-does-not-resolve -; return; }
  uid="$(id -u "$owner" 2>/dev/null)" || { line "$id" unknown - - - - - - owner-uid-unknown -; return; }
  [ "$uid" = "$(id -u)" ] || { line "$id" uninspectable - - - - - - other-owner -; return; }
  if [ -n "${LOGIN:-}" ]; then
    registry_login_principal_gate "$LOGIN" "${ACCOUNT:-}" >/dev/null 2>&1 || { line "$id" unknown - - - - - - login-account-mismatch -; return; }
    cfg="$(registry_login_config_dir "$LOGIN" "$owner" 2>/dev/null)" || cfg=""
  else cfg="$(eval printf '%s' "~$owner")/.claude"; fi
  [ -n "$cfg" ] && [ -r "$cfg" ] && [ -x "$cfg" ] || { line "$id" unknown - - - - - - config-dir-unreadable -; return; }
  if [ -d "$cfg/sessions" ] && ! { [ -r "$cfg/sessions" ] && [ -x "$cfg/sessions" ]; }; then line "$id" unknown - - - - - - sessions-dir-unreadable -; return; fi
  all_panes="$(tmuxc list-panes -a -F '#{pane_pid}' 2>/dev/null)"; sess_panes="$(tmuxc list-panes -s -t "=$id" -F '#{pane_pid}' 2>/dev/null)"
  tmuxc has-session -t "=$id" 2>/dev/null && tmux_present=1 || tmux_present=0
  launch="$(bridge_gen_get "$SD" "$id" launch_ms 2>/dev/null)"; launch="${launch:-0}"; nonce="$(bridge_gen_get "$SD" "$id" launch_nonce 2>/dev/null)"
  gp="$(bridge_gen_get "$SD" "$id" pid 2>/dev/null)"; census="$(bridge_gen_get "$SD" "$id" census 2>/dev/null)"
  lpid="$(bridge_gen_get "$SD" "$id" launch_pane_pid 2>/dev/null)"
  if [ -n "$lpid" ]; then [ "$(bridge_os_birth "$lpid" 2>/dev/null)" = "$(bridge_gen_get "$SD" "$id" launch_pane_birth 2>/dev/null)" ] && lalive=1 || lalive=0; fi
  open_launch=0; [ "$launch" != 0 ] && [ -z "$gp" ] && [ "$NOW_MS" -lt $((launch + GRACE_MS)) ] && open_launch=1
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
        [ "$open_launch" = 1 ] && [ "$started" -ge "$launch" ] 2>/dev/null && env_has_nonce "$pid" "$nonce" && claim=1
      fi
      sp="$(tmuxc display-message -p -t "$tmuxf" '#{pane_pid}' 2>/dev/null)"; [ -n "$sp" ] && bridge_is_descendant "$pid" "$sp" && stored=1
      for p in $all_panes; do bridge_is_descendant "$pid" "$p" && { any=1; break; }; done
    else
      [ "$boot" = 1 ] || { bridge_gen_matches_dead "$SD" "$id" "$pid" "$pstart" && dead=1; }
    fi
    c="$(bridge_classify_candidate "$alive" "$uid_ok" "$known" "$claim" "$stored" "$any" "$dead")"; classes="$classes $c"
    case "$c" in live:*) L_PID="$pid"; L_BIRTH="$birth"; L_PANE="$tmuxf"; L_NAME="$name"; L_SINCE="$since" ;; esac
  done <<EOF
$(bridge_candidates "$id" "$cfg/sessions")
EOF
  gen_state=none
  if [ "$boot" = 1 ]; then gen_state=bootstrap; census=1
  elif [ -n "$gp" ]; then
    if [ "$(bridge_os_birth "$gp" 2>/dev/null)" = "$(bridge_gen_get "$SD" "$id" birth 2>/dev/null)" ]; then gen_state=alive
    elif [ -n "$(bridge_gen_get "$SD" "$id" stop_receipt 2>/dev/null)" ]; then gen_state=gone-receipt; else gen_state=gone-noreceipt; fi
  elif [ "$open_launch" = 1 ]; then gen_state=grace
  elif [ "$launch" != 0 ]; then if [ "$lalive" = 0 ]; then gen_state=gone-noreceipt; else gen_state=alive; fi   # B5: a dead launch child is a crash, not a fiction
  fi
  veto=0; for p in $(pgrep -u "$uid" -f "$RUNTIME_VETO_PAT" 2>/dev/null); do for q in $sess_panes; do bridge_is_descendant "$p" "$q" && { veto=1; break 2; }; done; done
  line "$id" "$(bridge_answer "$classes" "$gen_state" "$tmux_present" "$veto" "$census")" "$L_PID" "$L_BIRTH" "$L_PANE" "$L_NAME" "$L_SINCE" "$gen_state" "${classes# }" "$lalive"
}
case "${1:-}" in
  --all) for n in $(registry_list); do registry_load "$n" >/dev/null 2>&1 || continue; [ "${HOST:-}" = "${STEWARD_SELF_HOST:-$(hostname -s)}" ] || continue; observe "$n" 0; done ;;
  --bootstrap) [ -n "${2:-}" ] || { echo "usage: bridge-observe.sh --bootstrap <id>" >&2; exit 64; }; observe "$2" 1 ;;
  '') echo "usage: bridge-observe.sh <id> | --all | --bootstrap <id>" >&2; exit 64 ;;
  *) observe "$1" 0 ;;
esac
```
- [ ] **Step 5: Mutations** — write the generation on managed → claim 1 fails (byte-identical check); veto on `all_panes` → 11 fails; skip `env_has_nonce` → 4 fails; take the first live of two → 9 fails.
- [ ] **Step 6: Commit** — `bridge-observe: read-only, ten fields, a launch is proven by its nonce`.

---

### Task 5: Supervisor — owns every write; nonce at spawn; keyed two-round gate

Spec §1; B1, B3, B5, B6.

**Files:** supervisor; `test/supervisor-bridge.test.sh`; rewrite `test/supervisor-reap.test.sh` claims 2/3.

- [ ] **Step 1: Failing tests** — twelve claims: (1) managed, display changed → healthy, no label pgrep, no kill; (2) other claude in other pane, managed dead, tmux present → round one: suspect key stored, **no** spawn; round two: `kill-session` then exactly one `new-session`; (3) moved → nothing written, `moved` in output; (4) orphan → round one: key `identified:orphan <pid> <birth>` stored, no kill; round two: kill; three-round variant orphan → moved → orphan: **no kill**; birth re-read before kill (variant removes `/proc/<pid>` between rounds → no kill); (5) stale, tmux absent → no spawn round one, one spawn round two, vendor file untouched; (6) split-brain → nothing; (7) malformed + live → nothing; (8) pre-census → no spawn, output names the census; (9) post-census first-ever → round one suspect, round two one spawn; (10) grace by **deadline**: `STEWARD_NOW_MS` advanced past `launch_ms + GRACE_MS` flips the answer; the observer wrapper counts invocations and N extra calls in one round change nothing (B3); (11) managed row whose display no longer derives → rc 0, `.display-degraded` once, still supervised; (12) no-process with a broken display → rc 78 naming the missing link, no spawn; (13) spawn passes `STEWARD_LAUNCH_NONCE=<value>` in the child environment and records `launch_nonce`, `launch_pane_pid`, `launch_pane_birth` in the generation.

- [ ] **Step 3: Implement**
  - Placement (B1): after line 81 only source `lib/bridge.sh` and set `_bridge_ok=1`; **refuse** (`exit 78`) only after the pause guard (:154) and after `CFG_ROOT` (:358). `OBSERVE="${STEWARD_BRIDGE_OBSERVE:-$(dirname "$0")/bridge-observe.sh}"`.
  - `observe_row() { IFS="$US" read -r _ B_ANS B_PID B_BIRTH B_PANE B_NAME B_SINCE B_GEN B_CLASSES B_LALIVE <<EOF
$(STEWARD_STATE_DIR="$STATE_DIR" STEWARD_TMUX_SOCKET="$SOCK" STEWARD_REGISTRY_LIB="$REG_LIB" STEWARD_BRIDGE_LIB="$BRIDGE_LIB" "$OBSERVE" "$NAME" 2>>"$STATE_DIR/$NAME.observe-stderr")
EOF
}`
  - Line 1337: `observe_row; if [ "$B_ANS" = identified:managed ]; then rm -f "$SUSPECT" "$STATE_DIR/$NAME.identity-degraded"; bridge_gen_write "$STATE_DIR" "$NAME" pid="$B_PID" birth="$B_BIRTH" uid="$(id -u)" bridge_name="$B_NAME" bridge_nameSince="$B_SINCE" launch_nonce= launch_pane_pid= launch_pane_birth= launch_ms=` — **binding closes the launch claim** (B4).
  - Replace lines 1731-1743:

```bash
KEY="$(bridge_suspect_key "$B_ANS" "$B_PID" "$B_BIRTH")"
case "$B_ANS" in
  identified:managed) : ;;
  identified:moved) rm -f "$SUSPECT"; echo "session-supervisor: $NAME — identified but MOVED (pid $B_PID under a pane other than $B_PANE). Nothing written; restore the tmux name or stop it deliberately." >&2; exit 0 ;;
  unknown)
    rm -f "$SUSPECT"
    if [ "$B_GEN" = alive ] && [ ! -f "$STATE_DIR/$NAME.identity-degraded" ]; then touch "$STATE_DIR/$NAME.identity-degraded"; echo "session-supervisor: $NAME — DEGRADED: our process lives but nothing attests it." >&2; fi
    echo "session-supervisor: $NAME — identity-unknown ($B_CLASSES). Nothing written." >&2
    [ -n "$(bridge_gen_get "$STATE_DIR" "$NAME" census 2>/dev/null)" ] || echo "session-supervisor: $NAME — no bootstrap census for this row: run bridge-census.sh first." >&2
    exit 0 ;;
  grace|wait-veto) rm -f "$SUSPECT"; exit 0 ;;
  identified:orphan)
    bridge_suspect_confirmed "$SUSPECT" "$KEY" || exit 0
    reap_orphan_claude; rm -f "$SUSPECT"; exit 0 ;;
  no-process)
    if [ -n "${DISPLAY_ERR:-}" ]; then echo "session-supervisor: $NAME — REFUSING to spawn: the display does not derive: $DISPLAY_ERR" >&2; exit 78; fi
    bridge_suspect_confirmed "$SUSPECT" "$KEY" || exit 0
    rm -f "$SUSPECT"
    if tmuxc has-session -t "=$NAME" 2>/dev/null; then bridge_gen_write "$STATE_DIR" "$NAME" stop_receipt="zombie-$(date +%s)"; tmuxc kill-session -t "=$NAME" 2>/dev/null; fi
    spawn_session; exit 0 ;;
  *) echo "session-supervisor: $NAME — adapter answered '$B_ANS', unknown to this supervisor. Nothing written." >&2; exit 0 ;;
esac
```
  - `reap_orphan_claude`:

```bash
reap_orphan_claude() {
  [ "$B_ANS" = identified:orphan ] && [ -n "$B_PID" ] || return 0
  [ "$(bridge_os_birth "$B_PID" 2>/dev/null)" = "$B_BIRTH" ] || { echo "session-supervisor: $NAME — orphan $B_PID changed birth between decision and kill; not touched." >&2; return 0; }
  ${STEWARD_KILL:-kill} "$B_PID" 2>/dev/null && echo "session-supervisor: $NAME — reaped orphan $B_PID ($B_BIRTH): under no pane on the socket, two keyed rounds." >&2
}
```
  - `spawn_session`: remove its `reap_orphan_claude` call and the `RENAME_PENDING` write. `NONCE="$(od -An -N16 -tx1 /dev/urandom | tr -d ' \n')"`; the child environment gains `STEWARD_LAUNCH_NONCE=$NONCE` through the same `env … VAR=value` prefix `LOGIN_PREFIX` builds (append after `CLAUDE_CONFIG_DIR=…`; for a row without LOGIN, prefix `env STEWARD_LAUNCH_NONCE=$NONCE`). Create with `pane_pid="$(tmuxc new-session -d -P -F '#{pane_pid}' -s "$NAME" -c "$REPO" …)"`; then `bridge_gen_write "$STATE_DIR" "$NAME" launch_ms="$(( $(date +%s) * 1000 ))" launch_nonce="$NONCE" launch_pane_pid="$pane_pid" launch_pane_birth="$(bridge_os_birth "$pane_pid" 2>/dev/null)" pid= birth= stop_receipt=`.
  - Delete `matching_claude_pids`, `CLAUDE_PAT`, `RC_LBL_PAT`, `claude_alive_in_session`, local `is_descendant` (callers use `bridge_is_descendant`). Keep `runtime_alive_in_session` for the veto.
- [ ] **Step 5: Mutations** — kill on the first orphan sighting → (4) fails; ignore pid in the key → the three-round variant fails; nonce not passed → an integration claim reproducing Task 4 claim 3 through the supervisor fails.
- [ ] **Step 6: Commit** — `supervisor: one observation, one owner of state, two keyed rounds before any write`.

---

### Task 6: Display as a fact; rename to the pane; receipt with advancing nameSince; tty-checked foreground (B9)

As the previous version's Task 6 (registry `registry_session_rc_enabled`; `DISPLAY_ERR` as a fact at :677-681; `SESSION_NAME` from display/applied/label; `type_line <pane> <text>`; the cycle keyed on `pending_for`/`pending_since` with `nameSince` advancement), with two changes:
- `pane_foreground_is_managed <pane-target> <pid>`: read `tty_nr` (field 7) and `tpgid` (field 8) from **both** `/proc/<pane_pid>/stat` and `/proc/<pid>/stat`; require the same nonzero `tty_nr`, equal `tpgid`s, and `tpgid` = the managed process's `pgrp` (field 5); keep `#{pane_current_command} = claude` as the independent canary (B9).
- When the display derives again on a degraded row: `rm -f "$STATE_DIR/$NAME.display-degraded"`, so the next transition alarms once (B9).
Claims 13–15 as before, plus (16) same `tpgid` but different `tty_nr` → nothing typed; (17) degraded → recovered → broken again → exactly two alarms.

---

### Task 7: Watch — remote socket built on the remote, guarded kill, strict parse (B10)

As before, with:
- Remote command: `cmd = \`STEWARD_STATE_DIR="$HOME/.local/state/${est.stateDirName}" STEWARD_TMUX_SOCKET="$HOME/.tmux/${est.tmuxSocket}" bash ~/scripts/bridge-observe.sh ${s.id}\`` — the socket path is **built on the remote from the remote `$HOME`**, never the hub's absolute path.
- `parseObserveLine`: split on `String.fromCharCode(31)`; exactly ten fields; `id` matches `/^s-[0-9a-f]{16}$/`; `answer` in the closed set; `pid`/`nameSince` numeric or null; single line; throws otherwise.
- `restart-session.mjs`: re-observe immediately before the kill and require the same `pid` **and** `birth`; otherwise refuse. Poll for a new `identified:managed` with a different pid.
- `decide()` returns its existing shape; the info line is appended as an `info`-kind alert that `session-watch` already logs; the test asserts it.

---

### Task 8: `liveness-host.sh` — OUTLINE (ten-field line; `agent` = running iff `identified:managed`, not-running iff `no-process`, else unknown; add `unknown` to `lib/liveness.sh`'s vocabulary with a test if closed).

### Task 9: Gates — OUTLINE with corrected contract (B11)

Registry gate at write: `registry_session_rendered_unique`, `registry_session_work_rule` on register lifecycle. **Host reservation reserves the generation's `applied` and `pending_for`** of every row **this uid owns**; rows of other owners are `uninspectable` and, under `STEWARD_RESERVATION_STRICT=1`, make a colliding desired name a refusal ("manual census required"). The live bridge name is an additional collision guard, not the reservation. Implementation to be written when Tasks 4–6 have landed.

### Task 9b: Retarget refusal — OUTLINE with corrected contract (B12)

The graph writers (`registry_entity_write`, `registry_project_write`) and the session retarget writers gate on **register state only**: a row is *stopped* when it carries `LIFECYCLE="stopped"` and `STOP_RECEIPT="<epoch>:<pid>:<birth>"`, written by a new hub verb `registry session stopped <id> <pid> <birth>` that the supervisor's stop transaction requests over the bus after the last bridge file is gone. The reverse closure walks `PARENT`/`MANAGED_BY` up to 64 levels across all hosts' rows. `lib/registry.sh` never calls the observer.

### Task 10: P0 census — OUTLINE (B13)

`bridge-census.sh` runs `bridge-observe.sh --bootstrap <id>` per row this uid owns; `identified:managed` → seed `pid birth procStart census=1`; `no-process` → `stop_receipt=census-<epoch> census=1`; anything else → `census=blocked:<answer>`. Rows of other owners are listed `uninspectable` and left alone (their owner's supervisor runs its own census).

### Task 11 / Task 12 — OUTLINE as before (target-only renderer, gate on a temporary copy, atomic replace; legacy removal last).

---

## Gates carried by this plan

P0 census before Task 5 is enabled on a host. P1b (cases A and B) before Task 11's first live derive. P2 macOS twin and bash 3.2 for `test/bridge-*.test.sh`. P3 manual census; Task 9's strict mode turns it into a refusal.

## Self-review

B1 → T1 count fixed (eight), `explode`/`implode` instead of a backslash-u class, the plan written through a tool that does not decode escapes. B2 → T3 colon-safe matchers with a round-trip claim. B3 → T4 read-only, T5 owns writes, grace by deadline, a claim counts invocations. B4 → nonce in the child environment, verified in `/proc/<pid>/environ`, claim closes on binding. B5 → `launch_pane_pid`/`birth` recorded; dead child past the window = `gone-noreceipt`. B6 → `bridge_suspect_confirmed` keyed on `answer pid birth`, reset on any other key; three-round fixture. B7 → veto on `list-panes -s -t =id`; control claim with an unrelated live claude. B8 → US framing, `-` for empty, `filename-pid`, `stat` poison, path control bytes, `sessions/` readability, `registry_login_principal_gate`, owner uid. B9 → `tty_nr`+`tpgid` on both sides; degraded marker cleared on recovery. B10 → remote socket from remote `$HOME`, guarded kill with birth re-check, strict parse, info asserted. B11 → applied+pending reservation from own state dir; other owners uninspectable/strict refusal. B12 → register-lifecycle stop receipt via a hub verb; the registry library never calls the observer. B13 → `--bootstrap` mode for the census only.
Executable as written: **Tasks 1–3.** Tasks 4–7: full code, awaiting a third pass. Tasks 8–12: outlines with corrected contracts.
