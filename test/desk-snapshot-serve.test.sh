#!/bin/bash
# test/desk-snapshot-serve.test.sh — the producer's half of a cross-estate read:
# hand over THIS estate's current desk generation, and nothing else.
#
# WHY THE CLAIMS ARE SHAPED LIKE THIS. The script sits behind an ssh forced
# command on a machine another estate reads. Everything it will ever be asked is
# therefore an input it did not choose, so the suite spends most of its claims on
# what it must REFUSE to be steered by, not on the happy path:
#
#   - an argument (a client can append words to an ssh command line)
#   - SSH_ORIGINAL_COMMAND (which is where those words actually arrive)
#   - the rest of the desk directory, which holds OTHER estates' files once this
#     estate also consumes. A producer that tarred its whole desk directory would
#     relay estate A's viewer files to estate B on the next fetch, and nothing in
#     either estate's register would record that it happened.
#
# The last one is the claim that bites. The other two are cheap to keep right;
# that one is one `tar -C` argument away from being wrong, and wrong silently.
set -u
here="$(CDPATH= cd -- "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SERVE="$here/desk/bin/desk-snapshot-serve"
pass=0; fail=0
ok()  { pass=$((pass+1)); printf '  ok   %s\n' "$1"; }
bad() { fail=$((fail+1)); printf '  FAIL %s\n     %s\n' "$1" "${2:-}"; }
is()  { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "wanted '$3', got '$2'"; fi; }
has() { case "$2" in *"$3"*) ok "$1" ;; *) bad "$1" "missing '$3' in: $2" ;; esac; }
no()  { case "$2" in *"$3"*) bad "$1" "unexpectedly present: '$3' in: $2" ;; *) ok "$1" ;; esac; }

FX="$(mktemp -d)"; trap 'rm -rf "$FX"' EXIT
mkdir -p "$FX/estate" "$FX/home"
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
mkgen() { # <gen-name> -> a generation with two viewer files
  mkdir -p "$DESK/$1"
  printf '{"host":"fixture","viewer":"alice"}'    > "$DESK/$1/alice.json"
  printf '{"host":"fixture","viewer":"_operator"}' > "$DESK/$1/_operator.json"
  chmod 700 "$DESK/$1"; chmod 600 "$DESK/$1"/*.json
}
run() { # runs the producer in the fixture; OUT is stdout, ERR stderr, RC the code
  OUT="$( HOME="$FX/home" STEWARD_ESTATE_ROOT="$FX" STEWARD_CONFIG_FILE="$FX/no-such-config" \
          STEWARD_REGISTRY_LIB="$here/lib/registry.sh" \
          bash "$SERVE" "$@" 2>"$FX/err" )"; RC=$?
  ERR="$(cat "$FX/err")"
}
# tar output is binary; capture it to a file instead of a variable
# THE SORT IS PINNED TO THE C LOCALE in both helpers below. An unpinned `sort`
# orders by the runner's locale - '_operator' before 'alice' under C, after it
# under en_US - so an expected string written on one machine is a failing test on
# the next. The suite would then be measuring the HOST, which is the same defect
# the mode-bit fixtures in this repo already pin against.
runtar() {
  HOME="$FX/home" STEWARD_ESTATE_ROOT="$FX" STEWARD_CONFIG_FILE="$FX/no-such-config" \
    STEWARD_REGISTRY_LIB="$here/lib/registry.sh" \
    bash "$SERVE" "$@" >"$FX/out.tar" 2>"$FX/err"; RC=$?
  ERR="$(cat "$FX/err")"
  LIST="$(tar tf "$FX/out.tar" 2>/dev/null | sed 's|^\./||' | grep -v '^$' | LC_ALL=C sort | tr '\n' ' ')"
}

echo "== 1. the happy path: the current generation, whole =="
mkgen gen-1000
ln -sfn gen-1000 "$DESK/current"
runtar
is  "1a rc 0"                                   "$RC" "0"
is  "1b every viewer file of the generation"    "$LIST" "_operator.json alice.json "
is  "1c nothing on stderr"                      "$ERR" ""
# THE BYTES ARE THE PRODUCER'S, UNCHANGED. A transport that rewrote content would
# make `generatedAt` a claim about the fetch instead of about the run.
tar -C "$FX" -xf "$FX/out.tar" ./alice.json 2>/dev/null
is  "1d the file arrives byte for byte"         "$(cat "$FX/alice.json" 2>/dev/null)" '{"host":"fixture","viewer":"alice"}'

echo "== 2. the whole desk directory is NOT the current generation =="
# THE CLAIM THAT BITES. Once this estate consumes others, `remote/` holds their
# viewer files, and older generations sit beside `current` until they are pruned.
# A producer that tarred the desk directory would relay both.
mkgen gen-0999
mkdir -p "$DESK/remote/otherestate/current"
printf '{"host":"otherestate","viewer":"bob"}' > "$DESK/remote/otherestate/current/bob.json"
runtar
is  "2a rc 0 with neighbours present"           "$RC" "0"
is  "2b still only the current generation"      "$LIST" "_operator.json alice.json "
no  "2c no other estate's file travels"         "$LIST" "bob.json"
no  "2d no previous generation travels"         "$LIST" "gen-0999"
no  "2e the remote tree does not travel"        "$LIST" "remote"

echo "== 3. it cannot be steered =="
# A FORCED COMMAND RECEIVES WHATEVER THE CLIENT APPENDED. Both channels are
# tested because they are different channels: argv is what a `command=` entry
# passes on some configurations, SSH_ORIGINAL_COMMAND is where openssh puts the
# client's words. Refusing argv and ignoring the variable is the whole contract.
runtar ../../../etc
is  "3a an argument is refused"                 "$RC" "64"
has "3b ...and says so"                         "$ERR" "takes no argument"
is  "3c ...and writes no tar"                   "$(wc -c < "$FX/out.tar" | tr -d ' ')" "0"
OUT="$( HOME="$FX/home" STEWARD_ESTATE_ROOT="$FX" STEWARD_CONFIG_FILE="$FX/no-such-config" \
        STEWARD_REGISTRY_LIB="$here/lib/registry.sh" SSH_ORIGINAL_COMMAND='tar cf - /etc/passwd' \
        bash "$SERVE" 2>/dev/null | tar tf - 2>/dev/null | sed 's|^\./||' | grep -v '^$' | LC_ALL=C sort | tr '\n' ' ' )"
is  "3d SSH_ORIGINAL_COMMAND changes nothing"   "$OUT" "_operator.json alice.json "

echo "== 4. nothing to hand over is a NAMED state, not an empty tar =="
# AN EMPTY ANSWER AND A MISSING ANSWER LOOK THE SAME TO A CONSUMER that only
# checks rc 0. The consumer's rule is that a bad answer never replaces a good
# one, and it can only keep that rule if this side distinguishes the cases.
rm -f "$DESK/current"
runtar
is  "4a no current generation is rc 69"         "$RC" "69"
has "4b ...and names what is missing"           "$ERR" "no current generation"
is  "4c ...and writes no tar"                   "$(wc -c < "$FX/out.tar" | tr -d ' ')" "0"
ln -sfn gen-does-not-exist "$DESK/current"
runtar
is  "4d a dangling current is rc 69 too"        "$RC" "69"
rm -rf "$DESK"
runtar
is  "4e no desk directory at all is rc 69"      "$RC" "69"

echo "== 5. an estate that will not load is rc 78, never a guess =="
run() { :; }
OUT="$( HOME="$FX/home" STEWARD_ESTATE_ROOT="$FX/no-such-estate" \
        STEWARD_CONFIG_FILE="$FX/no-such-config" \
        STEWARD_REGISTRY_LIB="$here/lib/registry.sh" \
        bash "$SERVE" 2>"$FX/err" )"; RC=$?
is  "5a an unreadable estate is rc 78"          "$RC" "78"
is  "5b ...and writes nothing to stdout"        "$OUT" ""
# rc 78 AND rc 69 ARE DIFFERENT REPAIRS: 78 is "this home is not set up", 69 is
# "it is set up and has not run yet". A single failure code would send the reader
# to the wrong one half the time.
ERR="$(cat "$FX/err")"
no  "5c ...and does not claim a missing generation" "$ERR" "no current generation"

printf '\n%d passed, %d failed\n' "$pass" "$fail"; [ "$fail" -eq 0 ]
