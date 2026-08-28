#!/bin/bash
# test/sessions-hidden.test.sh — seeing less must look different from there
# being less.
#
# THE COUNT IS THE WHOLE POINT. A filtered list that simply omits what the
# viewer may not see is indistinguishable from a fleet that small — the exact
# silence this project exists to prevent, one layer up from the one the spec
# opens with. So the document carries a number.
#
# AND IT IS A NUMBER, NEVER NAMES. Enumerating what someone may not see is
# leaking precisely the thing being withheld. A count says "there is more here"
# without saying what.
set -u

here="$(CDPATH= cd -- "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
STEWARD="$here/bin/steward"
pass=0; fail=0
ok()  { pass=$((pass+1)); printf '  ok   %s\n' "$1"; }
bad() { fail=$((fail+1)); printf '  FAIL %s\n     %s\n' "$1" "${2:-}"; }
is()  { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "wanted '$3', got '$2'"; fi; }
has() { case "$2" in *"$3"*) ok "$1" ;; *) bad "$1" "missing '$3' in: $2" ;; esac; }
hasnt(){ case "$2" in *"$3"*) bad "$1" "found '$3'" ;; *) ok "$1" ;; esac; }

FX="$(mktemp -d)"; trap 'rm -rf "$FX"' EXIT
mkdir -p "$FX/sessions.d" "$FX/entities.d" "$FX/estate"
printf 'LABEL_PREFIX="com.fixture.claude"\nHUB_HOST="h1"\nOP_TOKEN_FILE_NAME="t"\n' \
  > "$FX/estate/steward.conf"
printf 'NAME="Team A"\nMEMBERS="alice bob"\n' > "$FX/entities.d/team-a.conf"
printf 'NAME="Team B"\nMEMBERS="bob"\n'       > "$FX/entities.d/team-b.conf"

sess() { printf 'HOST="h1"\nOWNER="%s"\nDOMAIN="%s"\nRC_LABEL="L"\nREPO_PATH="/tmp/x"\nID="%s"\n%b' \
  "$2" "$3" "$1" "${4:-}" > "$FX/sessions.d/$1.conf"; }
sess mine   alice team-a
sess shared bob   team-a
sess theirs bob   team-b                        # alice is not in team-b
sess secret bob   team-a 'VISIBILITY="private"\n'

run() { STEWARD_REGISTRY_DIR="$FX/sessions.d" STEWARD_ESTATE_ROOT="$FX" \
        STEWARD_VIEWER="$1" bash "$STEWARD" sessions "${@:2}" 2>/dev/null; }

echo "== alice sees two of four, and is told there are two more =="
j="$(run alice --json)"
is "two sessions listed" "$(printf '%s' "$j" | jq -r '.sessions | length')" "2"
is "and two hidden"      "$(printf '%s' "$j" | jq -r '.hidden')" "2"
has "her own is there"     "$(printf '%s' "$j" | jq -r '.sessions[].name')" "mine"
has "the shared one too"   "$(printf '%s' "$j" | jq -r '.sessions[].name')" "shared"

# THE NAMES OF WHAT IS HIDDEN MUST NOT APPEAR ANYWHERE IN THE DOCUMENT.
# Not in `sessions`, not in `unreadable`, not in a stray field. This assertion
# reads the WHOLE document as text on purpose.
echo "== and nothing in the document names what she may not see =="
hasnt "the other team's session is not named" "$j" "theirs"
hasnt "the private session is not named"      "$j" "secret"

echo "== bob owns them and sees all four, hidden is zero =="
jb="$(run bob --json)"
is "four sessions" "$(printf '%s' "$jb" | jq -r '.sessions | length')" "4"
is "nothing hidden" "$(printf '%s' "$jb" | jq -r '.hidden')" "0"

# `hidden` IS ALWAYS PRESENT, even at zero. An absent key would make a consumer
# that reads it have to distinguish "no hidden sessions" from "this engine does
# not report hiding" — and it would guess.
echo "== hidden is always in the document =="
is "type is number even at zero" "$(printf '%s' "$jb" | jq -r '.hidden | type')" "number"

echo "== a stranger sees nothing, and is told so =="
jc="$(run carol --json)"
is "no sessions"   "$(printf '%s' "$jc" | jq -r '.sessions | length')" "0"
is "four hidden"   "$(printf '%s' "$jc" | jq -r '.hidden')" "4"
is "ok is still true — this is an answer, not a failure" \
   "$(printf '%s' "$jc" | jq -r '.ok')" "true"

echo "== the human form says it too =="
t="$(run alice)"
has "the visible session is listed" "$t" "mine"
has "and the count is stated"       "$t" "2"
hasnt "without naming the hidden"   "$t" "theirs"

echo
printf 'pass=%s fail=%s\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
