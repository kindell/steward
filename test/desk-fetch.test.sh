#!/bin/bash
# test/desk-fetch.test.sh — the consumer's half of a cross-estate read.
#
# THE WHOLE SUITE IS ABOUT WHAT HAPPENS WHEN AN ESTATE ANSWERS BADLY, because
# that is the only interesting case. A fetch that works is one tar; a fetch that
# half-works is how a fleet view silently loses a host — and a fleet view that
# silently loses a host is indistinguishable from a host with nothing on it.
# That equivalence is the defect this product has already paid to learn twice
# (the liveness seam, then `uncensused`), so it is asserted here in both
# directions: the reason must be PRESENT and the stale rows must be ABSENT.
#
# NO SSH. The transport is a seam (STEWARD_DESK_FETCH_CMD) that receives the
# estate name and writes a tar to stdout. Every fixture below is a stub on that
# seam: a good stream, a truncated one, one that exits non-zero, one that writes
# nothing at all, and one that writes something that is not a tar.
set -u
here="$(CDPATH= cd -- "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FETCH="$here/desk/fetch.sh"
pass=0; fail=0
ok()  { pass=$((pass+1)); printf '  ok   %s\n' "$1"; }
bad() { fail=$((fail+1)); printf '  FAIL %s\n     %s\n' "$1" "${2:-}"; }
is()  { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "wanted '$3', got '$2'"; fi; }
has() { case "$2" in *"$3"*) ok "$1" ;; *) bad "$1" "missing '$3' in: $2" ;; esac; }
no()  { case "$2" in *"$3"*) bad "$1" "unexpectedly present: '$3' in: $2" ;; *) ok "$1" ;; esac; }
isdir()  { if [ -d "$2" ]; then ok "$1"; else bad "$1" "not a directory: $2"; fi; }

FX="$(mktemp -d)"; trap 'rm -rf "$FX"' EXIT
mkdir -p "$FX/estate" "$FX/home" "$FX/stub"
cat > "$FX/estate/steward.conf" <<'EOF'
ESTATE_NAME="fixture"
SCHEMA_VERSION="3"
LABEL_PREFIX="com.fixture.claude"
RC_LABEL_PREFIX="fixture: "
HUB_SESSION="fixture-hub"
HUB_HOST="h1"
HUB_SSH="a@h1"
JOB_LOG_DIR="fixture-jobs"
TMUX_SOCKET="fixture.sock"
PING_MSG="you have mail"
STATE_DIR_NAME="fixture-supervisor"
PAUSED_DIR_NAME="fixture-paused"
JOB_LABEL_PREFIX="com.fixture.job"
SERVICE_LABEL_PREFIX="com.fixture.service"
BROWSER_LABEL_PREFIX="com.fixture.browser"
OP_TOKEN_FILE_NAME="fixture-token"
EOF
DESK="$FX/home/.local/state/fixture-supervisor/desk"
REMOTES="$FX/estate/desk-remotes.conf"

# ── the seam: one stub, whose behaviour per estate is a file it reads ────────
# The stub answers by MODE so a single fixture covers every failure shape.
cat > "$FX/stub/fetch-cmd" <<'STUB'
#!/bin/bash
# $1 is the estate name. The mode file says how to misbehave for it.
est="$1"
mode="$(cat "$FXDIR/mode.$est" 2>/dev/null || echo good)"
case "$mode" in
  good)      tar -C "$FXDIR/src/$est" -cf - . ;;
  truncated) tar -C "$FXDIR/src/$est" -cf - . | head -c 120 ;;
  garbage)   printf 'this is not a tar archive at all' ;;
  empty)     : ;;
  fail)      echo "ssh: connect to host $est port 22: Connection refused" >&2; exit 255 ;;
  notgen)    tar -C "$FXDIR/notgen" -cf - . ;;
esac
STUB
chmod 755 "$FX/stub/fetch-cmd"
mkdir -p "$FX/notgen"; printf 'hello' > "$FX/notgen/readme.txt"

src() { # <estate> <generatedAt> — build what that estate would hand over
  mkdir -p "$FX/src/$1"
  printf '{"host":"%s","viewer":"alice","generatedAt":"%s"}\n'     "$1" "$2" > "$FX/src/$1/alice.json"
  printf '{"host":"%s","viewer":"_operator","generatedAt":"%s"}\n' "$1" "$2" > "$FX/src/$1/_operator.json"
}
mode() { printf '%s' "$2" > "$FX/mode.$1"; }

run() {
  OUT="$( HOME="$FX/home" STEWARD_ESTATE_ROOT="$FX" STEWARD_CONFIG_FILE="$FX/no-such-config" \
          STEWARD_REGISTRY_LIB="$here/lib/registry.sh" \
          STEWARD_DESK_REMOTES="$REMOTES" \
          STEWARD_DESK_FETCH_CMD="$FX/stub/fetch-cmd" FXDIR="$FX" \
          bash "$FETCH" "$@" 2>"$FX/err" )"; RC=$?
  ERR="$(cat "$FX/err")"
}
meta()  { cat "$DESK/remote/$1/meta.json" 2>/dev/null; }
files() { ls "$DESK/remote/$1/current/" 2>/dev/null | LC_ALL=C sort | tr '\n' ' '; }
gen_of(){ readlink "$DESK/remote/$1/current" 2>/dev/null; }

printf 'estate-b  alice@10.0.0.1  id_desk_fetch\nestate-a      bob@10.0.0.2      id_desk_fetch\n' > "$REMOTES"
src estate-b 2026-09-13T20:00:00Z
src estate-a     2026-09-13T20:00:05Z

echo "== 1. the happy path: two estates, two generations =="
mode estate-b good; mode estate-a good
run
is     "1a rc 0"                                  "$RC" "0"
isdir  "1b estate-b has a current generation"   "$DESK/remote/estate-b/current"
isdir  "1c estate-a has one too"                    "$DESK/remote/estate-a/current"
is     "1d estate-b's viewer files arrived"     "$(files estate-b)" "_operator.json alice.json "
has    "1e its meta says ok"                      "$(meta estate-b)" '"status":"ok"'
has    "1f ...and names the estate"               "$(meta estate-b)" '"estate":"estate-b"'
# THE TWO TIMES ARE DIFFERENT FACTS. generatedAt belongs to the producer and
# fetchedAt to the consumer; a design that collapsed them would make a fresh
# fetch of a stale snapshot read as current.
has    "1g meta carries fetchedAt"                "$(meta estate-b)" '"fetchedAt"'
has    "1h the viewer file keeps its own generatedAt" \
       "$(cat "$DESK/remote/estate-b/current/alice.json")" '2026-09-13T20:00:00Z'
no     "1i meta does not restate generatedAt"     "$(meta estate-b)" '"generatedAt"'

echo "== 2. the modes are the fetcher's, not the umask's =="
# The mode bits are the last gate on a directory full of other people's viewer
# files, so the process that writes them sets them - it does not inherit them.
is "2a the generation is 0700"  "$(stat -c '%a' "$DESK/remote/estate-b/current/" 2>/dev/null || stat -f '%Lp' "$DESK/remote/estate-b/current/")" "700"
is "2b each file is 0600"       "$(stat -c '%a' "$DESK/remote/estate-b/current/alice.json" 2>/dev/null || stat -f '%Lp' "$DESK/remote/estate-b/current/alice.json")" "600"

echo "== 3. a bad answer never replaces a good one =="
# EACH SHAPE GETS ITS OWN CASE because they fail at different points: a stream
# that stops mid-file, a stream that was never a tar, a command that exits
# non-zero, and a command that says nothing at all. A fetcher that only checked
# the exit status would swap in the first two.
good_gen="$(gen_of estate-b)"
# `notgen` IS A TAR THAT UNPACKS PERFECTLY and is not a generation - the one
# failure shape that survives both the exit status and the unpack. Without it
# the fetcher could swap in any well-formed tarball an estate happened to send.
for m in truncated garbage empty fail notgen; do
  mode estate-b "$m"; mode estate-a good
  run
  is "3-$m: the generation is unchanged"   "$(gen_of estate-b)" "$good_gen"
  is "3-$m: the rows are still readable"   "$(files estate-b)" "_operator.json alice.json "
  has "3-$m: meta says unavailable"        "$(meta estate-b)" '"status":"unavailable"'
  has "3-$m: meta names a reason"          "$(meta estate-b)" '"reason"'
  is "3-$m: rc is non-zero"                "$([ "$RC" -ne 0 ] && echo yes || echo no)" "yes"
done
# THE REASON IS THE POINT, not the word. A refusal that cannot say why is the
# silence this seam exists to end.
mode estate-b fail; run
has "3z the refusal carries the transport's own words" "$(meta estate-b)" "Connection refused"

echo "== 4. one dead estate does not hide a live one =="
# A fetcher that stopped at the first failure would let one unreachable machine
# make two others invisible, and the page would look like a two-estate fleet.
mode estate-b fail; mode estate-a good
src estate-a 2026-09-13T21:00:00Z
run
has "4a the live estate was still fetched"  "$(cat "$DESK/remote/estate-a/current/alice.json")" '2026-09-13T21:00:00Z'
has "4b ...and reads ok"                    "$(meta estate-a)" '"status":"ok"'
has "4c while the dead one reads unavailable" "$(meta estate-b)" '"status":"unavailable"'
is  "4d and the run's rc is the worst of them" "$([ "$RC" -ne 0 ] && echo yes || echo no)" "yes"

echo "== 5. an estate that recovers stops being unavailable =="
# A status that only ever gets worse is a status nobody trusts.
mode estate-b good; src estate-b 2026-09-13T22:00:00Z
run
is  "5a rc 0 once both answer"              "$RC" "0"
has "5b the recovered estate reads ok"      "$(meta estate-b)" '"status":"ok"'
has "5c ...with the new snapshot"           "$(cat "$DESK/remote/estate-b/current/alice.json")" '2026-09-13T22:00:00Z'
is  "5d ...and the generation moved"        "$([ "$(gen_of estate-b)" != "$good_gen" ] && echo yes || echo no)" "yes"

echo "== 6. the remotes list is read strictly =="
printf 'estate-b\n' > "$REMOTES"
run
is  "6a a line missing its target is refused"  "$RC" "65"
has "6b ...and names the line"                 "$ERR" "estate-b"
printf '# only a comment\n\n' > "$REMOTES"
run
is  "6c a list with no estates is rc 0"        "$RC" "0"
no  "6d ...and says nothing alarming"          "$ERR" "REFUS"
rm -f "$REMOTES"
run
is  "6e no list at all is rc 0, not an error"  "$RC" "0"
# AN ESTATE THAT CONSUMES NOTHING IS THE ORDINARY STATE for two of the three
# machines in this fleet. Refusing it would make the fetcher something one must
# remember not to install.

echo "== 7. only the named estates are touched =="
printf 'estate-a      bob@10.0.0.2      id_desk_fetch\n' > "$REMOTES"
before="$(gen_of estate-b)"
mode estate-a good; run
is  "7a an estate dropped from the list is left alone" "$(gen_of estate-b)" "$before"
# LEFT ALONE, NOT DELETED. Removing it would destroy the only record that the
# estate was ever readable, and a list edited by mistake would take the history
# with it. Pruning is an operator's act, not a fetch's.

printf '\n%d passed, %d failed\n' "$pass" "$fail"; [ "$fail" -eq 0 ]
