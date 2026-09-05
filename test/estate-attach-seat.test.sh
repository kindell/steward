#!/bin/bash
# test/estate-attach-seat.test.sh — `steward <estate> attach <session>` lands
# in the OWNER's home on the session's HOST, not in whatever home the estate
# card's ssh target happens to open.
#
# WHY. A session's tmux server runs in its owner's home, under the owner's
# socket. Until 2026-09-05 attach opened the card's ssh target and looked for
# the session there — right as long as every session the card knew lived in
# that one account, and wrong the day one moved into the machine steward's
# home: "can't find session", while the session ran fine one home over. The
# seat is resolved the same way `steward <estate> login` resolves it (see
# test/estate-login-verb.test.sh): one read-only hop to ask, one interactive
# hop to sit down.
#
# HERMETIC: the same ssh stub shape as the login suite — every call logged,
# the read-only hop answered from a canned file, the interactive hop logged
# only.
set -u

here="$(CDPATH= cd -- "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
STEWARD="$here/bin/steward"
pass=0; fail=0
ok()  { pass=$((pass+1)); printf '  ok   %s\n' "$1"; }
bad() { fail=$((fail+1)); printf '  FAIL %s\n     %s\n' "$1" "${2:-}"; }
is()  { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "wanted '$3', got '$2'"; fi; }
has() { case "$2" in *"$3"*) ok "$1" ;; *) bad "$1" "missing '$3' in: $2" ;; esac; }

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
mkdir -p "$T/estates.d" "$T/bin"

cat > "$T/estates.d/myestate.conf" <<'EOF'
SSH="op@h1"
ESTATE_ROOT="/home/op/estate"
PRODUCT_DIR="/home/op/steward"
EOF

SSHLOG="$T/sshlog"
cat > "$T/bin/ssh" <<EOF
#!/bin/bash
printf '%s\n' "\$*" >> "$SSHLOG"
[ "\$1" = "-t" ] && exit 0
rc=\$(cat "$T/answer.rc")
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

echo "== attach lands in the OWNER's home on the session's HOST =="
answer "s-0000000000000001" "steward" "h1" "/home/op"; echo 0 > "$T/answer.rc"
run myestate attach byslug >/dev/null; rc=$?
is   "rc 0"                                            "$rc" "0"
is   "exactly two hops"                                "$(calls)" "2"
has  "hop 1 asks the estate where the seat is"         "$(hop1)" 'resolve "$N"'
has  "hop 2 is interactive, as the owner on the host"  "$(hop2)" "-t steward@h1"
has  "hop 2 attaches by the resolved KEY"              "$(hop2)" 'N="s-0000000000000001"'
has  "hop 2 reads the socket from the owner's estate root" "$(hop2)" 'R="$HOME/estate"'

echo "== the owner IS the card's account: hop 2 reuses the card's target =="
answer "work" "op" "h1" "/home/op"; echo 0 > "$T/answer.rc"
run myestate attach work >/dev/null
has  "hop 2 goes to the card's ssh target"    "$(hop2)" "-t op@h1"
has  "hop 2 attaches by the key"              "$(hop2)" 'N="work"'

echo "== the estate does not know the handle: one hop, its own words =="
printf 'estate-status: no session %s in the registry\n' "ghost" > "$T/answer"; echo 65 > "$T/answer.rc"
out="$(run myestate attach ghost)"; rc=$?
is   "rc is the estate's own (65)"        "$rc" "65"
is   "only the read-only hop ran"         "$(calls)" "1"
has  "the estate's own refusal is shown"  "$out" "no session ghost"

echo "== a bad session name is refused before any ssh =="
run myestate attach 'x;y' >/dev/null; rc=$?
is   "rc 64"          "$rc" "64"
is   "no ssh at all"  "$(calls)" "0"

echo
echo "pass=$pass fail=$fail"
[ "$fail" -eq 0 ]
