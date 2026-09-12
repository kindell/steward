#!/bin/bash
# test/supervisor-pane-pids-all-windows.test.sh - the session's pane pids come from EVERY window.
#
# WHY. session-supervisor-linux.sh's own comment above session_pane_pids: fixture-proven on
# tmux 3.6b, `list-panes -t "=name"` lists ONLY the session's CURRENT window. A human attaches,
# opens a second window (it becomes current), detaches -> claude lives on in window 0, invisible
# to both the alive check and the kill veto -> two rounds of "no runtime" -> kill-session destroys
# the live conversation. `-s` is the one flag that keeps the kill inside the scope of its own veto.
#
# It was asserted nowhere. The hub found the gap 2026-09-12 while retiring an estate assertion that
# measured the same thing against the old supervisor: of five behaviours the estate suite could no
# longer reach, this was the only one the product suites did not carry. A stub tmux that answers
# with the window-2 pane ONLY when asked with -s makes the flag load-bearing here.
set -u
here="$(CDPATH= cd -- "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
pass=0; fail=0
ok()  { pass=$((pass+1)); printf '  ok   %s\n' "$1"; }
bad() { fail=$((fail+1)); printf '  FAIL %s\n     %s\n' "$1" "${2:-}"; }
is()  { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "wanted '$3', got '$2'"; fi; }
SUP="$here/linux/session-supervisor-linux.sh"

echo "== 1. the rule: session_pane_pids asks tmux for every window =="
line="$(grep -E '^session_pane_pids\(\)' "$SUP")"
is "1a session_pane_pids exists" "$([ -n "$line" ] && echo yes)" "yes"
is "1b and passes -s to list-panes" "$(printf '%s' "$line" | grep -c 'list-panes -s')" "1"

echo "== 2. the behaviour: a pane in window 2 is seen only through -s =="
FX="$(mktemp -d)"; trap 'rm -rf "$FX"' EXIT
# The stub stands in for tmuxc: window 1 (current) holds pane 1111; window 2 holds pane 2222.
# Without -s a real tmux lists only the current window; the stub does the same.
cat > "$FX/run.sh" <<RUN
NAME="s-test"
tmuxc() { case " \$* " in *" -s "*) printf '1111\n2222\n' ;; *) printf '1111\n' ;; esac; }
$line
session_pane_pids | tr '\n' ' '
RUN
out="$(/bin/bash "$FX/run.sh" 2>/dev/null | sed 's/ *$//')"
is "2a both windows' panes are returned" "$out" "1111 2222"
is "2b the window-2 pane is among them" "$(printf '%s' "$out" | grep -c 2222)" "1"

printf '\n  %d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
