#!/bin/bash
# test/session-new-rc-label.test.sh - what a NEW row says about its tile name, and what the
# supervisor makes of each thing it could say.
#
# THREE STATES, NOT TWO. session-supervisor-linux.sh's RC_LABEL branch: line ABSENT -> the tile
# derives from the row (registry_session_display, Team or Team->Project, 2026-09-06); line PRESENT
# AND EMPTY -> RC-free, no tile (M14's _registry_gate_rc_free is about exactly this); a VALUE ->
# verbatim. session-new.sh used to write RC_PREFIX+slug into every new row; the estate's
# RC_LABEL_PREFIX is "" since 09-06, so that was the bare slug - a verbatim label that the gate
# read as NOT-FREE and that blocked derivation until a manual derive. Found by the hub 2026-09-12
# as "a variable computed and never read" in the supervisor; the template was the other half.
#
# THE FIRST FIX WRITTEN FOR THIS WAS WRONG - RC_LABEL="" - and every existing suite stayed green,
# because none of them said what the template writes. This one does: absent is the only state that
# means derive, and the mutation to either of the other two costs an assertion.
set -u
here="$(CDPATH= cd -- "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
pass=0; fail=0
ok()  { pass=$((pass+1)); printf '  ok   %s\n' "$1"; }
bad() { fail=$((fail+1)); printf '  FAIL %s\n     %s\n' "$1" "${2:-}"; }
is()  { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "wanted '$3', got '$2'"; fi; }
NEW="$here/linux/session-new.sh"; SUP="$here/linux/session-supervisor-linux.sh"

echo "== 1. the dropped link is gone from both files =="
is "1a no RC_PREFIX in the supervisor"   "$(grep -cE '^[^#]*RC_PREFIX' "$SUP")" "0"
is "1b no RC_PREFIX in session-new"      "$(grep -cE '^[^#]*RC_PREFIX' "$NEW")" "0"

echo "== 2. the conf template session-new writes has NO RC_LABEL line (absent = derive) =="
a="$(grep -n '<<CONFEOF' "$NEW" | head -1 | cut -d: -f1)"; b="$(awk -v a="$a" 'NR>a && /^CONFEOF$/ {print NR; exit}' "$NEW")"
tpl="$(sed -n "$((a+1)),$((b-1))p" "$NEW")"
is "2a template found" "$([ -n "$a" ] && [ -n "$b" ] && echo yes)" "yes"
is "2b zero RC_LABEL= lines in the template" "$(printf '%s\n' "$tpl" | grep -cE '^\s*RC_LABEL=')" "0"

echo "== 3. the supervisor's three states, on the extracted branch =="
FX="$(mktemp -d)"; trap 'rm -rf "$FX"' EXIT
s="$(grep -nE "^if grep -q '\^RC_LABEL=' \"\\\$CONF\"" "$SUP" | head -1 | cut -d: -f1)"
e="$(awk -v s="$s" 'NR>s && /^fi$/ {print NR; exit}' "$SUP")"
branch="$(sed -n "${s},${e}p" "$SUP")"
run() { printf 'CONF="%s"; DISPLAY="Team→Thing"; DISPLAY_ERR="x"\n%s\nprintf "%%s|%%s" "$RC_LABEL" "$DISPLAY_ERR"\n' "$1" "$branch" > "$FX/r.sh"; /bin/bash "$FX/r.sh" 2>/dev/null; }
printf 'ID="s-1"\n' > "$FX/absent.conf";  printf 'ID="s-1"\nRC_LABEL=""\n' > "$FX/empty.conf";  printf 'ID="s-1"\nRC_LABEL="Verbatim"\n' > "$FX/value.conf"
is "3a ABSENT  -> derived display"        "$(run "$FX/absent.conf" | cut -d'|' -f1)" "Team→Thing"
is "3b EMPTY   -> RC-free (empty label)"   "$(run "$FX/empty.conf"  | cut -d'|' -f1)" ""
is "3c VALUE   -> verbatim"                "$(run "$FX/value.conf"  | cut -d'|' -f1)" "Verbatim"
is "3d a verbatim value clears a derivation error beside it" "$(run "$FX/value.conf" | cut -d'|' -f2)" ""

printf '\n  %d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
