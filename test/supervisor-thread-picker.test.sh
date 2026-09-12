#!/bin/bash
# test/supervisor-thread-picker.test.sh - the thread picker on the macOS twin.
#
# WHY A RULE AND NOT ONLY A BEHAVIOUR. The picker is a python heredoc. It used to sit INSIDE a
# $( ) substitution, and bash 3.2 - the /bin/bash every macOS LaunchDaemon runs - scans a
# substitution for its closing paren with naive quote tracking: an apostrophe in a python
# COMMENT opened a shell quote. The body itself already carries a note dated 2026-08-20 saying
# "NO APOSTROPHES in this comment" for exactly that reason; two possessives were added on
# 2026-08-31 anyway. Measured 2026-09-12 in the hub's own supervisor log on butler:
#   session-supervisor.sh: line 336: e: command not found
#   session-supervisor.sh: line 361: syntax error near unexpected token `('
# _pick came back empty and the round fell through to newest-by-content - the picker the
# block exists to replace. The failure is CONTEXT-DEPENDENT (the same block extracted alone
# parses), so a behaviour test on the extracted block cannot see it. The rule can: the
# heredoc must not live inside $( ). read -r -d '' has no such scanner.
set -u
here="$(CDPATH= cd -- "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
pass=0; fail=0
ok()  { pass=$((pass+1)); printf '  ok   %s\n' "$1"; }
bad() { fail=$((fail+1)); printf '  FAIL %s\n     %s\n' "$1" "${2:-}"; }
is()  { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "wanted '$3', got '$2'"; fi; }
SUP="$here/linux/session-supervisor-linux.sh"

echo "== 1. the rule: the picker heredoc is not inside a command substitution =="
n_bad="$(grep -cE '\$\(python3 - "\$HIST" <<' "$SUP")"
is "1a no \$(python3 - ... <<'PY') form remains" "$n_bad" "0"
n_ok="$(grep -cE "read -r -d '' _py <<'PY'" "$SUP")"
is "1b the heredoc is read with read -r -d '' instead" "$n_ok" "1"

echo "== 2. the behaviour: older human thread beats newer job thread, under /bin/bash 3.2 =="
FX="$(mktemp -d)"; trap 'rm -rf "$FX"' EXIT
H="$FX/hist"; mkdir -p "$H"
printf '{"type":"last-prompt","timestamp":"2026-09-12T10:00:00Z"}\n' > "$H/aaaa-human.jsonl"
printf '{"type":"queue-operation","timestamp":"2026-09-12T11:00:00Z"}\n' > "$H/bbbb-job.jsonl"
a="$(grep -nE "read -r -d '' _py <<'PY'" "$SUP" | head -1 | cut -d: -f1)"
b="$(awk -v a="$a" 'NR>a && /_pick="\$\(printf/ {print NR; exit}' "$SUP")"
{ printf 'HIST="%s"; _latest=""; _pick=""\n' "$H"; sed -n "${a},${b}p" "$SUP"; printf 'printf "%%s\\n" "$_pick"\n'; } > "$FX/run.sh"
out="$(/bin/bash "$FX/run.sh" 2>"$FX/err")"
is "2a no parse noise on stderr" "$(grep -cE 'error|not found|EOF' "$FX/err")" "0"
is "2b class is human" "$(printf '%s\n' "$out" | sed -n 1p)" "human"
is "2c and it is the OLDER human thread, not the newer job" "$(printf '%s\n' "$out" | sed -n 2p)" "$H/aaaa-human.jsonl"

printf '\n  %d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
