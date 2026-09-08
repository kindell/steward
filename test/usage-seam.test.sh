#!/bin/bash
# test/usage-seam.test.sh - the usage seam: how much of a window is spent?
#
# THE MEASUREMENT IS INJECTED, AND HERE THAT IS A COST RULE AS WELL AS A SAFETY
# ONE. A real usage shim talks to a provider over the network, per login, and a
# suite that called it for real would spend a real budget to test a parser.
# Every case below is a stub written by this file; nothing here may ever name a
# real account, a real credential directory or a real network address.
#
# THE ROWS ARE VALIDATED, NOT TRUSTED. The shim is an estate program, its
# Claude-side half is text parsing, and the number it produces lands in a view a
# person acts on. A percent that did not parse is the word `unknown`; it is
# never 0 and never 100, because both of those are readable answers and neither
# was measured.
#
# A DROPPED ROW IS NEVER SILENT AND NEVER DATA. A row for a login the register
# does not know cannot be shown - it would name an account nobody can check -
# but a measurement that vanished without a word is the silence this family of
# files exists to make impossible, so the count and the reasons go to stderr.
set -u

here="$(CDPATH= cd -- "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
pass=0; fail=0
ok()  { pass=$((pass+1)); printf '  ok   %s\n' "$1"; }
bad() { fail=$((fail+1)); printf '  FAIL %s\n     %s\n' "$1" "${2:-}"; }
is()  { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "wanted '$3', got '$2'"; fi; }
has() { case "$2" in *"$3"*) ok "$1" ;; *) bad "$1" "missing '$3' in: $2" ;; esac; }

FX="$(mktemp -d)"; trap 'rm -rf "$FX"' EXIT
mkdir -p "$FX/home" "$FX/estate" "$FX/logins.d"
HOME="$FX/home"; export HOME
STEWARD_ESTATE_ROOT="$FX"; export STEWARD_ESTATE_ROOT

# THE LOGIN REGISTER IS THE VOCABULARY FOR THE FIRST COLUMN. Two rows, so a
# lookup that answers "yes" to everything and a lookup that answers "yes" to
# nothing are both visible; a single-row register cannot tell them apart.
for slug in alpha beta; do
  { printf 'PRINCIPAL="a"\nACCOUNT="%s@fixture.invalid"\n' "$slug"
    printf 'PROVIDER="claude-max"\nCONFIG_DIR="cfg-%s"\nLEGAL_OWNER="a"\n' "$slug"
  } > "$FX/logins.d/$slug.conf"
done

printf 'LABEL_PREFIX="com.fixture.claude"\nHUB_HOST="h1"\nOP_TOKEN_FILE_NAME="fixture-token"\n' \
  > "$FX/estate/steward.conf"

# shellcheck source=/dev/null
. "$here/lib/registry.sh"
# shellcheck source=/dev/null
. "$here/lib/usage.sh"

TAB="$(printf '\t')"

stub() { # <name> <body> - writes an executable shim, echoes its absolute path
  printf '#!/bin/bash\n%s\n' "$2" > "$FX/$1"; chmod +x "$FX/$1"; printf '%s' "$FX/$1"
}

# THE ROWS ARE READ BACK FROM A FILE, NEVER FROM `$(usage_rows)`. usage_rows
# sets USAGE_SEAM_REASON and USAGE_DROPPED in the CALLER's shell, and a command
# substitution is a subshell: captured that way, both would come back as
# whatever they were before the call.
run_rows() { # <cmd> [extra env assignments are the caller's job]
  STEWARD_USAGE_CMD="$1" usage_rows >"$FX/rows" 2>"$FX/err"
  ROWS="$(cat "$FX/rows")"; ERR="$(cat "$FX/err")"
}

echo "== an unconfigured seam is a normal state, and says so without noise =="
( unset STEWARD_USAGE_CMD; usage_rows >"$FX/rows" 2>"$FX/err"
  printf '%s' "$USAGE_SEAM_REASON" > "$FX/reason" )
is "unset: stdout stays empty" "$(cat "$FX/rows")" ""
is "unset: stderr stays empty too" \
   "$( [ -s "$FX/err" ] && echo yes || echo no )" "no"
is "unset: the reason is seam-not-configured" "$(cat "$FX/reason")" "seam-not-configured"
( unset STEWARD_USAGE_CMD; usage_rows >/dev/null 2>&1
  usage_for alpha 5h "" > "$FX/unconf.row" )
is "unset: usage_for answers with the seam reason, in eight fields" \
   "$(cat "$FX/unconf.row")" \
   "alpha${TAB}-${TAB}5h${TAB}unknown${TAB}${TAB}${TAB}${TAB}seam-not-configured"
is "unset: and that row really has eight fields" \
   "$(awk -F'\t' '{print NF}' "$FX/unconf.row")" "8"

echo "== the four misconfigurations each get their own word =="
reason_after() { # <cmd> - the seam reason left by one call
  STEWARD_USAGE_CMD="$1" usage_rows >"$FX/rows" 2>"$FX/err"
  printf '%s' "$USAGE_SEAM_REASON"
}
is "a bare command name is refused as not-a-path" "$(reason_after "true")" "seam-not-a-path"
is "bare name: stdout stays empty" "$(cat "$FX/rows")" ""
is "bare name: stderr says so" "$( [ -s "$FX/err" ] && echo yes || echo no )" "yes"

# A RELATIVE PATH IS REFUSED BEFORE THE SHIM IS EVER RUN. `./shim` carries a
# slash, so a "contains a slash" test would run whatever sits in the directory
# that happened to be current; the marker file proves it did not.
cat > "$FX/relshim" <<'EOF'
#!/bin/bash
echo ran > "$(dirname "$0")/relshim.ran"
EOF
chmod +x "$FX/relshim"
( cd "$FX" || exit 1
  rm -f relshim.ran
  STEWARD_USAGE_CMD="./relshim" usage_rows >rel.out 2>rel.err
  printf '%s' "$USAGE_SEAM_REASON" > rel.reason )
is "a relative path is refused as not-absolute" "$(cat "$FX/rel.reason")" "seam-not-absolute"
is "relative path: stdout stays empty" "$(cat "$FX/rel.out")" ""
is "relative path: the shim was NEVER executed" \
   "$( [ -e "$FX/relshim.ran" ] && echo yes || echo no )" "no"

is "a path that names nothing is not-found" \
   "$(reason_after "$FX/does-not-exist")" "seam-not-found"
is "missing path: stderr names the path" \
   "$(grep -q "$FX/does-not-exist" "$FX/err" && echo yes || echo no)" "yes"

printf '#!/bin/bash\ntrue\n' > "$FX/noexec"; chmod -x "$FX/noexec"
is "a file without its exec bit is not-executable" \
   "$(reason_after "$FX/noexec")" "seam-not-executable"

echo "== a shim that answers well has its rows carried through verbatim =="
R1="alpha${TAB}claude-max${TAB}5h${TAB}63${TAB}2026-09-08T09:49:00.000Z${TAB}2026-09-08T08:49:00.000Z${TAB}bud-1${TAB}"
R2="alpha${TAB}claude-max${TAB}week${TAB}16${TAB}2026-09-12T00:00:00.000Z${TAB}2026-09-08T08:49:00.000Z${TAB}bud-1${TAB}"
R3="beta${TAB}codex-openai${TAB}5h${TAB}0${TAB}${TAB}2026-09-08T08:49:00.000Z${TAB}${TAB}plan pro"
# THE EXPECTED TEXT IS WRITTEN ONCE, in R1..R3 above, and the stub is built
# from those same variables. A fixture that spells the answer twice can agree
# with itself while both copies are wrong.
good="$(stub good "cat <<'ROWS'
$R1
$R2
$R3
ROWS")"
run_rows "$good"
is "three rows in, three rows out" "$(printf '%s\n' "$ROWS" | grep -c .)" "3"
is "the first row is carried through unchanged" "$(printf '%s\n' "$ROWS" | sed -n 1p)" "$R1"
is "the second row is carried through unchanged" "$(printf '%s\n' "$ROWS" | sed -n 2p)" "$R2"
is "the third row is carried through unchanged" "$(printf '%s\n' "$ROWS" | sed -n 3p)" "$R3"
is "nothing was dropped" "$USAGE_DROPPED" "0"
is "a clean answer says nothing on stderr" "$ERR" ""
is "and the seam reason is empty - it answered" "$USAGE_SEAM_REASON" ""

echo "== the lookup finds a window, and names absence when it cannot =="
is "usage_for returns the matching row" "$(usage_for alpha week "$ROWS")" "$R2"
is "a window the answer never mentioned is unknown, with a reason" \
   "$(usage_for alpha month "$ROWS")" \
   "alpha${TAB}-${TAB}month${TAB}unknown${TAB}${TAB}${TAB}${TAB}not-in-answer"
is "a login the answer never mentioned is unknown too" \
   "$(usage_for beta week "$ROWS")" \
   "beta${TAB}-${TAB}week${TAB}unknown${TAB}${TAB}${TAB}${TAB}not-in-answer"

echo "== a login the register does not know is dropped, counted and named =="
unknown_login="$(stub unknownlogin "cat <<'ROWS'
$R1
gamma${TAB}claude-max${TAB}5h${TAB}20${TAB}${TAB}2026-09-08T08:49:00.000Z${TAB}${TAB}
ROWS")"
run_rows "$unknown_login"
is "the known row survives" "$ROWS" "$R1"
is "the unknown login is counted" "$USAGE_DROPPED" "1"
is "one line on stderr names the count and the reasons" "$ERR" \
   "usage: 1 row(s) dropped: unknown login (1), unknown provider (0), malformed (0)"

echo "== a provider outside the vocabulary is dropped the same way =="
unknown_provider="$(stub unknownprovider "cat <<'ROWS'
alpha${TAB}some-other-provider${TAB}5h${TAB}20${TAB}${TAB}2026-09-08T08:49:00.000Z${TAB}${TAB}
ROWS")"
run_rows "$unknown_provider"
is "nothing is printed" "$ROWS" ""
is "the unknown provider is counted" "$USAGE_DROPPED" "1"
has "and stderr names the reason" "$ERR" "unknown provider (1)"

echo "== openai-api is in the vocabulary, and a month window is a window =="
paid="$(stub paid "cat <<'ROWS'
beta${TAB}openai-api${TAB}month${TAB}7${TAB}2026-10-01T00:00:00.000Z${TAB}2026-09-08T08:49:00.000Z${TAB}acct-9${TAB}
ROWS")"
run_rows "$paid"
is "the pay-as-you-go row is kept verbatim" "$ROWS" \
   "beta${TAB}openai-api${TAB}month${TAB}7${TAB}2026-10-01T00:00:00.000Z${TAB}2026-09-08T08:49:00.000Z${TAB}acct-9${TAB}"
is "and nothing was dropped" "$USAGE_DROPPED" "0"

echo "== a percent that did not parse is the word unknown, never a number =="
# EVERY ONE OF THESE IS A REAL SHAPE the text-parsing half of a shim can
# produce: the rendered percent sign, an out-of-range number, a fraction, a
# negative, an empty column, and a word.
percents="$(stub percents "cat <<'ROWS'
alpha${TAB}claude-max${TAB}w-sign${TAB}63%${TAB}${TAB}${TAB}${TAB}
alpha${TAB}claude-max${TAB}w-high${TAB}101${TAB}${TAB}${TAB}${TAB}
alpha${TAB}claude-max${TAB}w-frac${TAB}63.5${TAB}${TAB}${TAB}${TAB}
alpha${TAB}claude-max${TAB}w-neg${TAB}-1${TAB}${TAB}${TAB}${TAB}
alpha${TAB}claude-max${TAB}w-empty${TAB}${TAB}${TAB}${TAB}${TAB}
alpha${TAB}claude-max${TAB}w-word${TAB}unknown${TAB}${TAB}${TAB}${TAB}
alpha${TAB}claude-max${TAB}w-zero${TAB}0${TAB}${TAB}${TAB}${TAB}
alpha${TAB}claude-max${TAB}w-full${TAB}100${TAB}${TAB}${TAB}${TAB}
alpha${TAB}claude-max${TAB}w-note${TAB}63%${TAB}${TAB}${TAB}${TAB}plan pro
ROWS")"
run_rows "$percents"
is "a percent sign is not a number" "$(usage_for alpha w-sign "$ROWS")" \
   "alpha${TAB}claude-max${TAB}w-sign${TAB}unknown${TAB}${TAB}${TAB}${TAB}parse:63%"
is "101 is not a number this contract accepts" "$(usage_for alpha w-high "$ROWS")" \
   "alpha${TAB}claude-max${TAB}w-high${TAB}unknown${TAB}${TAB}${TAB}${TAB}parse:101"
is "a fraction is not an integer" "$(usage_for alpha w-frac "$ROWS")" \
   "alpha${TAB}claude-max${TAB}w-frac${TAB}unknown${TAB}${TAB}${TAB}${TAB}parse:63.5"
is "a negative is not in range" "$(usage_for alpha w-neg "$ROWS")" \
   "alpha${TAB}claude-max${TAB}w-neg${TAB}unknown${TAB}${TAB}${TAB}${TAB}parse:-1"
is "an empty percent is unmeasured, not zero" "$(usage_for alpha w-empty "$ROWS")" \
   "alpha${TAB}claude-max${TAB}w-empty${TAB}unknown${TAB}${TAB}${TAB}${TAB}parse:"
is "a word is unmeasured too, and the raw word is kept" "$(usage_for alpha w-word "$ROWS")" \
   "alpha${TAB}claude-max${TAB}w-word${TAB}unknown${TAB}${TAB}${TAB}${TAB}parse:unknown"
is "0 is a measurement and survives" "$(usage_for alpha w-zero "$ROWS")" \
   "alpha${TAB}claude-max${TAB}w-zero${TAB}0${TAB}${TAB}${TAB}${TAB}"
is "100 is a measurement and survives" "$(usage_for alpha w-full "$ROWS")" \
   "alpha${TAB}claude-max${TAB}w-full${TAB}100${TAB}${TAB}${TAB}${TAB}"
is "a note the shim wrote keeps its place, with the parse note appended" \
   "$(usage_for alpha w-note "$ROWS")" \
   "alpha${TAB}claude-max${TAB}w-note${TAB}unknown${TAB}${TAB}${TAB}${TAB}plan pro; parse:63%"
is "a rewritten percent is not a dropped row" "$USAGE_DROPPED" "0"

echo "== a timestamp that did not parse is emptied, and says so =="
stamps="$(stub stamps "cat <<'ROWS'
alpha${TAB}claude-max${TAB}t-resets${TAB}10${TAB}in 47 minutes${TAB}2026-09-08T08:49:00.000Z${TAB}${TAB}
alpha${TAB}claude-max${TAB}t-measured${TAB}10${TAB}${TAB}yesterday${TAB}${TAB}
alpha${TAB}claude-max${TAB}t-both${TAB}10${TAB}soon${TAB}later${TAB}${TAB}
ROWS")"
run_rows "$stamps"
is "a reset time that is prose becomes empty, with a parse note" \
   "$(usage_for alpha t-resets "$ROWS")" \
   "alpha${TAB}claude-max${TAB}t-resets${TAB}10${TAB}${TAB}2026-09-08T08:49:00.000Z${TAB}${TAB}parse:in 47 minutes"
is "so does a measurement time" "$(usage_for alpha t-measured "$ROWS")" \
   "alpha${TAB}claude-max${TAB}t-measured${TAB}10${TAB}${TAB}${TAB}${TAB}parse:yesterday"
is "two bad stamps leave two notes, in field order" \
   "$(usage_for alpha t-both "$ROWS")" \
   "alpha${TAB}claude-max${TAB}t-both${TAB}10${TAB}${TAB}${TAB}${TAB}parse:soon; parse:later"

echo "== the shape of a row: six is enough, eight is the contract =="
shapes="$(stub shapes "cat <<'ROWS'
alpha${TAB}claude-max${TAB}s-six${TAB}12${TAB}${TAB}2026-09-08T08:49:00.000Z
alpha${TAB}claude-max${TAB}s-eight${TAB}12${TAB}${TAB}2026-09-08T08:49:00.000Z${TAB}${TAB}
alpha${TAB}claude-max${TAB}s-five${TAB}12${TAB}
alpha${TAB}claude-max${TAB}${TAB}12${TAB}${TAB}
alpha${TAB}claude-max${TAB}has space${TAB}12${TAB}${TAB}
ROWS")"
run_rows "$shapes"
is "six fields is a whole row, padded to eight" "$(usage_for alpha s-six "$ROWS")" \
   "alpha${TAB}claude-max${TAB}s-six${TAB}12${TAB}${TAB}2026-09-08T08:49:00.000Z${TAB}${TAB}"
is "eight fields with the last two empty is kept as it stands" \
   "$(usage_for alpha s-eight "$ROWS")" \
   "alpha${TAB}claude-max${TAB}s-eight${TAB}12${TAB}${TAB}2026-09-08T08:49:00.000Z${TAB}${TAB}"
is "two rows survive" "$(printf '%s\n' "$ROWS" | grep -c .)" "2"
is "five fields, an empty window and a window with a space are all dropped" \
   "$USAGE_DROPPED" "3"
has "and stderr counts them as malformed" "$ERR" "malformed (3)"

echo "== every row printed has exactly eight fields =="
is "no row is short or long" \
   "$(printf '%s\n' "$ROWS" | awk -F'\t' 'NF!=8{n++} END{print n+0}')" "0"

echo "== a hung shim is killed at the deadline =="
# STEWARD_USAGE_TIMEOUT injects the deadline so this suite never waits the real
# default. The stub forks a sub-sleep first, so the assertion covers a
# descendant the direct pid alone would not reach.
rm -f "$FX/hang.child.pid"
hang="$(stub hang 'sleep 100 & echo $! > "'"$FX"'/hang.child.pid"; sleep 100')"
STEWARD_USAGE_TIMEOUT=1 STEWARD_USAGE_CMD="$hang" usage_rows >"$FX/hang.out" 2>"$FX/hang.err"
is "hung shim: stdout stays empty" "$(cat "$FX/hang.out")" ""
is "hung shim: the reason is seam-timeout" "$USAGE_SEAM_REASON" "seam-timeout"
is "hung shim: stderr names the deadline" \
   "$(grep -qi 'did not answer\|killed' "$FX/hang.err" && echo yes || echo no)" "yes"
sleep 0.2
childpid="$(cat "$FX/hang.child.pid" 2>/dev/null)"
is "hung shim: its own child was reaped by the group kill" \
   "$( [ -n "$childpid" ] && kill -0 "$childpid" 2>/dev/null && echo alive || echo dead )" "dead"

# TIMING SANITY AT A LARGER LIMIT. `date +%s` has whole-second resolution, so a
# 1s deadline cannot be bounded fairly at "under twice"; a 3s deadline keeps the
# same one-second truncation slop small next to the 6s bound, so this catches a
# real regression without being sensitive to where a second boundary falls.
rm -f "$FX/hang3.child.pid"
hang3="$(stub hang3 'sleep 100 & echo $! > "'"$FX"'/hang3.child.pid"; sleep 100')"
t0="$(date +%s)"
STEWARD_USAGE_TIMEOUT=3 STEWARD_USAGE_CMD="$hang3" usage_rows >"$FX/hang3.out" 2>"$FX/hang3.err"
t1="$(date +%s)"
is "hung shim: seam-timeout at a different injected limit too" "$USAGE_SEAM_REASON" "seam-timeout"
is "hung shim: returned in under twice the injected limit" \
   "$( [ "$((t1 - t0))" -lt 6 ] && echo yes || echo no )" "yes"

echo "== a shim that fails, and one that answers nothing =="
failing="$(stub failing 'echo "the provider refused" >&2; exit 3')"
run_rows "$failing"
is "a failing shim prints no rows" "$ROWS" ""
is "and says seam-failed" "$USAGE_SEAM_REASON" "seam-failed"
has "and keeps the words of the shim as evidence" "$ERR" "the provider refused"

silent="$(stub silent 'exit 0')"
run_rows "$silent"
is "an empty answer is not an empty fleet" "$USAGE_SEAM_REASON" "seam-no-output"

echo "== registry_usage_cmd: absent, present, not absolute =="
base='LABEL_PREFIX="com.fixture.claude"
HUB_HOST="h1"
OP_TOKEN_FILE_NAME="fixture-token"'
printf '%s\n' "$base" > "$FX/estate/steward.conf"
v="$(registry_usage_cmd)"; rc=$?
is "no USAGE_CMD line: rc 0" "$rc" "0"
is "no USAGE_CMD line: prints nothing" "$v" ""
printf '%s\nUSAGE_CMD="/abs/usage-shim"\n' "$base" > "$FX/estate/steward.conf"
v="$(registry_usage_cmd)"; rc=$?
is "a well-formed USAGE_CMD: rc 0" "$rc" "0"
is "a well-formed USAGE_CMD: prints the value" "$v" "/abs/usage-shim"
printf '%s\nUSAGE_CMD="relative/usage-shim"\n' "$base" > "$FX/estate/steward.conf"
registry_usage_cmd >/dev/null 2>"$FX/reg.err"; rc=$?
is "a relative USAGE_CMD: rc 78" "$rc" "78"
has "a relative USAGE_CMD: the refusal names the field" "$(cat "$FX/reg.err")" "USAGE_CMD"
printf '%s\n' "$base" > "$FX/estate/steward.conf"

echo "== the suite never names a real provider address =="
# A guard on the fixture itself: the stubs above must stay stubs. The pattern is
# assembled at runtime so it never appears whole in this file, which would make
# the check find itself and fail on every run no matter what the library does.
_no_net='http'; _no_net="${_no_net}s://"
if grep -q "$_no_net" "$here/test/usage-seam.test.sh"; then
  bad "the suite must not name a network address" "found a match"
else
  ok "the suite names no network address"
fi

echo
printf 'pass=%s fail=%s\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
