#!/bin/bash
# test/estate-login-verb.test.sh — `steward <estate> login [session]`: the
# laptop-side login. Finds WHOSE home on WHICH machine the session lives in,
# then lands the operator there for the runtime's own /login — the one step
# no script can do for them.
#
# WHY THIS EXISTS. Measured 2026-09-05, the first machine-steward login: the
# session had moved into a second account (the machine steward) on a host the
# hub only deploys to, and the only way to reach its /login prompt was a raw
# ssh + tmux -S <socket> attach line dictated by hand. `steward login` could
# not help — it runs on the session's host, as the session's owner, and the
# person sat on a laptop, logged in as someone else. The product's job is to
# carry the person to that exact seat: two hops, the first read-only (where
# is the seat?), the second interactive (sit down).
#
# HERMETIC: no real ssh. STEWARD_SSH points at a stub that logs every command
# line it is asked to run and answers the read-only hop from a canned file.
# The interactive hop (-t) is logged only — nothing here ever runs a login.
set -u

here="$(CDPATH= cd -- "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
STEWARD="$here/bin/steward"
pass=0; fail=0
ok()  { pass=$((pass+1)); printf '  ok   %s\n' "$1"; }
bad() { fail=$((fail+1)); printf '  FAIL %s\n     %s\n' "$1" "${2:-}"; }
is()  { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "wanted '$3', got '$2'"; fi; }
has() { case "$2" in *"$3"*) ok "$1" ;; *) bad "$1" "missing '$3' in: $2" ;; esac; }
hasnt() { case "$2" in *"$3"*) bad "$1" "unexpectedly found '$3' in: $2" ;; *) ok "$1" ;; esac; }

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
mkdir -p "$T/estates.d" "$T/bin"

cat > "$T/estates.d/myestate.conf" <<'EOF'
SSH="op@h1"
ESTATE_ROOT="/home/op/estate"
PRODUCT_DIR="/home/op/steward"
EOF

# THE STUB. Every call is logged as one line (its full argv). A call that is
# NOT interactive (no -t) is the read-only hop and gets the canned answer:
# four lines — key, owner, host, the answering account's HOME — with the rc
# in answer.rc. An interactive call is logged and nothing more.
SSHLOG="$T/sshlog"
cat > "$T/bin/ssh" <<EOF
#!/bin/bash
printf '%s\n' "\$*" >> "$SSHLOG"
[ "\$1" = "-t" ] && exit 0
rc=\$(cat "$T/answer.rc")
# THE REAL REMOTE SPEAKS ITS REFUSAL ON STDERR — the stub keeps the channels apart.
if [ "\$rc" -eq 0 ]; then cat "$T/answer"; else cat "$T/answer" >&2; fi
exit \$rc
EOF
chmod +x "$T/bin/ssh"

answer() { printf '%s\n' "$@" > "$T/answer"; }
run() { : > "$SSHLOG"
        STEWARD_ESTATES_D="$T/estates.d" STEWARD_SSH="$T/bin/ssh" \
        bash "$STEWARD" "$@" 2>&1; }
calls() { wc -l < "$SSHLOG" | tr -d ' '; }
hop1() { sed -n 1p "$SSHLOG"; }
hop2() { sed -n 2p "$SSHLOG"; }

echo "== the session lives in ANOTHER account's home: land there, as that account =="
answer "s-0000000000000001" "steward" "h1" "/home/op"; echo 0 > "$T/answer.rc"
out="$(run myestate login byslug)"; rc=$?
is   "rc 0"                                            "$rc" "0"
is   "exactly two hops"                                "$(calls)" "2"
has  "hop 1 goes to the estate's own ssh target"       "$(hop1)" "op@h1"
has  "hop 1 carries the handle"                        "$(hop1)" 'N="byslug"'
has  "hop 1 asks the estate to resolve it"             "$(hop1)" 'resolve "$N"'
has  "hop 2 is interactive"                            "$(hop2)" "-t "
has  "hop 2 lands as the OWNER on the session's HOST"  "$(hop2)" "steward@h1"
has  "hop 2 runs the hub-side login verb with the KEY" "$(hop2)" "login s-0000000000000001"
has  "hop 2 aims the estate root at the owner's home"  "$(hop2)" 'STEWARD_ESTATE_ROOT="$HOME/estate"'
has  "the verb SAYS where it is taking the person"     "$out" "steward"
has  "...and on which machine"                         "$out" "h1"

echo "== the owner IS the estate's ssh account: hop 2 reuses the card's target =="
answer "work" "op" "h1" "/home/op"; echo 0 > "$T/answer.rc"
run myestate login work >/dev/null; rc=$?
is   "rc 0"                                   "$rc" "0"
has  "hop 2 goes to the card's ssh target"    "$(hop2)" "-t op@h1"
has  "hop 2 runs login with the key"          "$(hop2)" "login work"

echo "== an estate root OUTSIDE the answering home is passed through untouched =="
cat > "$T/estates.d/shared.conf" <<'EOF'
SSH="op@h1"
ESTATE_ROOT="/srv/estate"
PRODUCT_DIR="/home/op/steward"
EOF
answer "work" "steward" "h1" "/home/op"; echo 0 > "$T/answer.rc"
run shared login work >/dev/null
has  "hop 2 carries the shared root as-is" "$(hop2)" 'STEWARD_ESTATE_ROOT="/srv/estate"'

echo "== no session name: the estate's hub session is the target =="
answer "hub" "op" "h1" "/home/op"; echo 0 > "$T/answer.rc"
run myestate login >/dev/null; rc=$?
is   "rc 0"                                              "$rc" "0"
has  "hop 1 reads HUB_SESSION off the estate when no name is given" "$(hop1)" "HUB_SESSION"
has  "hop 2 logs in to what the estate answered"          "$(hop2)" "login hub"

echo "== the estate does not know the handle: one hop, its own words, its own rc =="
printf 'estate-status: no session %s in the registry\n' "ghost" > "$T/answer"; echo 65 > "$T/answer.rc"
out="$(run myestate login ghost)"; rc=$?
is   "rc is the estate's own (65)"        "$rc" "65"
is   "only the read-only hop ran"         "$(calls)" "1"
has  "the estate's own refusal is shown"  "$out" "no session ghost"

echo "== a malformed answer is refused, never used as an ssh target =="
answer "work" "steward;rm -rf /" "h1" "/home/op"; echo 0 > "$T/answer.rc"
out="$(run myestate login work)"; rc=$?
is   "rc 78"                              "$rc" "78"
is   "no interactive hop"                 "$(calls)" "1"
has  "refusal says the answer was bad"    "$out" "could not read"

echo "== a bad session name is refused before any ssh =="
out="$(run myestate login 'x;y')"; rc=$?
is   "rc 64"          "$rc" "64"
is   "no ssh at all"  "$(calls)" "0"

echo
echo "pass=$pass fail=$fail"
[ "$fail" -eq 0 ]
