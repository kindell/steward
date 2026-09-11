#!/bin/bash
# test/bridge-answer.test.sh - every row of the spec's table as a decision from flags alone.
#
# THE LIBRARY DECIDES, THE ADAPTER MEASURES. bridge_classify_candidate takes seven
# flags the adapter gathered (is the pid alive, is it the owner's uid, does the
# generation know its birth, does it carry this launch's nonce inside the window, is it
# under the stored pane, under any pane, is a dead file known to history) and prints one
# word. bridge_answer folds those words with the generation state, tmux presence, the
# runtime veto and the census flag into one of seven answers. Neither touches a machine,
# so every row of the table in the spec is one line here.
#
# TWO GUARDS ARE THE WHOLE POINT:
#   - a fresh pid (birth unknown) is ours ONLY with the launch claim (B4). Time and place
#     do not prove that our spawn created a process; the nonce does.
#   - census is done only when the generation says exactly "1" (B11). A census that wrote
#     blocked:<reason> must keep the row unknown, not read as first-ever.
set -u
here="$(CDPATH= cd -- "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
pass=0; fail=0
ok()  { pass=$((pass+1)); printf '  ok   %s\n' "$1"; }
bad() { fail=$((fail+1)); printf '  FAIL %s\n     %s\n' "$1" "${2:-}"; }
is()  { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "wanted '$3', got '$2'"; fi; }
. "$here/lib/bridge.sh" || { echo "cannot source lib/bridge.sh"; exit 1; }
C() { bridge_classify_candidate "$@"; }

echo "== classify: alive uid birth_known launch_claim stored any dead_match =="
is "known pid in stored pane = managed"        "$(C 1 1 1 0 1 1 0)" "live:managed"
is "known pid under another pane = moved"      "$(C 1 1 1 0 0 1 0)" "live:moved"
is "known pid under no pane = orphan"          "$(C 1 1 1 0 0 0 0)" "live:orphan"
is "fresh pid WITH launch claim = managed"     "$(C 1 1 0 1 1 1 0)" "live:managed"
is "fresh pid without claim = unclassifiable"  "$(C 1 1 0 0 1 1 0)" "unclassifiable"
is "alive, wrong uid = unclassifiable"         "$(C 1 0 1 0 1 1 0)" "unclassifiable"
is "alive, wrong uid, even with claim"         "$(C 1 0 0 1 1 1 0)" "unclassifiable"
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
# THE FALL-THROUGH MUST NOT RESCUE THE MUTATION: with gen=alive the answer below the live
# count is also "unknown", so a broken count would pass by accident. gone-noreceipt would
# fall through to no-process - the word the correct code must never say for two live pids.
is "two live, gen gone -> still unknown, never no-process" "$(bridge_answer 'live:managed live:managed' gone-noreceipt 0 0 1)" "unknown"
is "two live of different kinds = split-brain"   "$(bridge_answer 'live:managed live:orphan' alive 1 0 1)" "unknown"
is "one unclassifiable poisons"                  "$(bridge_answer 'unclassifiable live:managed' alive 1 0 1)" "unknown"
is "one unclassifiable, gen gone -> still unknown" "$(bridge_answer 'unclassifiable' gone-noreceipt 0 0 1)" "unknown"
is "unknown gen_state word = unknown"            "$(bridge_answer '' bogus 0 0 1)" "unknown"

printf '\n%d passed, %d failed\n' "$pass" "$fail"; [ "$fail" -eq 0 ]
