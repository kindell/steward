#!/bin/bash
# test/visibility-fields.test.sh — the two fields that carry a visibility
# declaration, read and validated like every other registry field.
#
# THIS FILE TESTS THE DECLARATION, NOT THE RULE. Whether a given person may see
# a given session is decided in lib/visibility.sh and tested there. Here the
# only question is whether the registry reads these two fields honestly and
# refuses a malformed one — a conf that declares something the loader silently
# ignores is a declaration nobody can rely on.
#
# THE VOCABULARY IS CLOSED. `private` or nothing. A third word would be a
# declaration whose meaning no consumer knows, and the consumer is a view that
# would have to guess.
set -u

here="$(CDPATH= cd -- "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
pass=0; fail=0
ok()  { pass=$((pass+1)); printf '  ok   %s\n' "$1"; }
bad() { fail=$((fail+1)); printf '  FAIL %s\n     %s\n' "$1" "${2:-}"; }
is()  { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "wanted '$3', got '$2'"; fi; }

FX="$(mktemp -d)"; trap 'rm -rf "$FX"' EXIT
mkdir -p "$FX/sessions.d" "$FX/estate"
printf 'LABEL_PREFIX="com.fixture.claude"\nHUB_HOST="h1"\nOP_TOKEN_FILE_NAME="t"\n' \
  > "$FX/estate/steward.conf"
export STEWARD_REGISTRY_DIR="$FX/sessions.d" STEWARD_ESTATE_ROOT="$FX"
# shellcheck source=/dev/null
. "$here/lib/registry.sh"

conf() { # <name> <extra lines>
  # NOTE: the trailing conversion is %b, not %s. printf's %s never expands
  # escapes INSIDE a substituted argument — only inside the format string
  # itself — so a caller's '...\nVISIBLE_TO="..."\n' would land on the conf
  # file as the four literal characters backslash-n, not a newline, and the
  # sourced line would silently misparse. %b interprets \n in the argument
  # the way every call site below assumes. Verified against the bash on this
  # box (3.2.57): %s left literal "\n" in the file; %b did not.
  printf 'HOST="h1"\nOWNER="alice"\nDOMAIN="acme"\nRC_LABEL="L"\nREPO_PATH="/tmp/x"\nID="%s"\n%b' \
    "$1" "$2" > "$FX/sessions.d/$1.conf"
}

echo "== the fields are read =="
conf both 'VISIBILITY="private"\nVISIBLE_TO="board other-group"\n'
( registry_load both >/dev/null 2>&1 && printf '%s|%s' "$VISIBILITY" "$VISIBLE_TO" ) > "$FX/out"
is "both values arrive" "$(cat "$FX/out")" "private|board other-group"

echo "== absence is the normal case, not an error =="
conf plain ''
( registry_load plain >/dev/null 2>&1; printf '%s|%s|%s' "$?" "$VISIBILITY" "$VISIBLE_TO" ) > "$FX/out"
is "a conf with neither field loads clean, both empty" "$(cat "$FX/out")" "0||"

# NO RESET IS A LEAK. Every field registry_load reads must be cleared before the
# source, or a value from the previous load survives into a conf that never
# declared it — and here that would grant a session a visibility its own conf
# does not state.
echo "== neither field leaks between loads =="
leak="$( registry_load both  >/dev/null 2>&1
         registry_load plain >/dev/null 2>&1
         printf '%s|%s' "$VISIBILITY" "$VISIBLE_TO" )"
is "both are empty after loading a conf without them" "$leak" "|"

echo "== the vocabulary is closed =="
conf loud 'VISIBILITY="public"\n'
( registry_load loud >/dev/null 2>&1; printf '%s' "$?" ) > "$FX/out"
is "a third word is refused" "$(cat "$FX/out")" "1"
err="$( registry_load loud 2>&1 >/dev/null )"
case "$err" in *VISIBILITY*) ok "the refusal names the field" ;;
  *) bad "the refusal names the field" "$err" ;; esac

echo "== a group name is a name =="
conf bad_group 'VISIBLE_TO="Board"\n'
( registry_load bad_group >/dev/null 2>&1; printf '%s' "$?" ) > "$FX/out"
is "an uppercase group name is refused" "$(cat "$FX/out")" "1"
conf slashy 'VISIBLE_TO="../etc"\n'
( registry_load slashy >/dev/null 2>&1; printf '%s' "$?" ) > "$FX/out"
is "a path-shaped group name is refused" "$(cat "$FX/out")" "1"

# EVERY NAME IN THE LIST, not just the first. A list validated by its head is a
# list an attacker appends to.
conf second_bad 'VISIBLE_TO="board ../etc"\n'
( registry_load second_bad >/dev/null 2>&1; printf '%s' "$?" ) > "$FX/out"
is "a bad name LATER in the list is refused too" "$(cat "$FX/out")" "1"

echo "== a legitimate multi-group list survives =="
conf many 'VISIBLE_TO="board audit-2026 steering"\n'
( registry_load many >/dev/null 2>&1; printf '%s' "$VISIBLE_TO" ) > "$FX/out"
is "three groups, intact" "$(cat "$FX/out")" "board audit-2026 steering"

echo
printf 'pass=%s fail=%s\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
