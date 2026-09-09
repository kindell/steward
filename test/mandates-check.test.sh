#!/bin/bash
# test/mandates-check.test.sh - the register-wide measurement: does the mandate
# register hang together with the registers it points into?
#
# A CLEAN REGISTER IS THE CONTROL GROUP. Every finding below is proved against
# a register that reads rc 0 with nothing on stdout - otherwise "it found the
# broken row" cannot be told from "it complains about everything".
#
# THE FINDING THIS FILE EXISTS FOR IS FALSE-CONSENT: a row signed from a channel
# that authenticates SOMEONE ELSE. That is not a malformed row; it is a yes that
# nobody gave, and the check names it as such with both names in the line.
set -u
here="$(CDPATH= cd -- "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
. "$here/lib/registry.sh"
pass=0; fail=0
ok()  { pass=$((pass+1)); printf '  ok   %s\n' "$1"; }
bad() { fail=$((fail+1)); printf '  FAIL %s\n     %s\n' "$1" "${2:-}"; }
is()  { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "wanted '$3', got '$2'"; fi; }
has() { case "$2" in *"$3"*) ok "$1" ;; *) bad "$1" "missing '$3' in: $2" ;; esac; }
FX="$(mktemp -d)"; trap 'rm -rf "$FX"' EXIT
mkdir -p "$FX/logins.d" "$FX/accounts.d" "$FX/mandates.d"; chmod 700 "$FX/logins.d" "$FX/accounts.d" "$FX/mandates.d"
# STEWARD_ACCOUNT_DIR, SINGULAR - read out of registry_account_dir, not guessed by
# analogy with the other two. The first run set the plural, the loader read the
# estate's REAL accounts.d, and the control group failed with "no such account":
# a fixture pointed at the wrong world, which is the one failure a control
# group cannot tell you about from the inside.
export STEWARD_LOGINS_DIR="$FX/logins.d" STEWARD_ACCOUNT_DIR="$FX/accounts.d" STEWARD_MANDATES_DIR="$FX/mandates.d"
w() { cat > "$1"; chmod 600 "$1"; }   # a pinned row
# THE WORLD THE MANDATES POINT INTO: two people, two payers, two accounts.
printf 'PRINCIPAL="simon"\nACCOUNT="s@ex.test"\nPROVIDER="claude-team"\nCONFIG_DIR="~/.claude-logins/sv"\nLEGAL_OWNER="Varvet"\n' | w "$FX/logins.d/simon-varvet.conf"
printf 'PRINCIPAL="jon"\nACCOUNT="j@ex.test"\nPROVIDER="claude-team"\nCONFIG_DIR="~/.claude-logins/jp"\nLEGAL_OWNER="Point"\n'  | w "$FX/logins.d/jon-point.conf"
printf 'PRINCIPAL="simon"\nHOST="h1"\nUSERNAME="simon"\n' | w "$FX/accounts.d/simon-basement.conf"
printf 'PRINCIPAL="jon"\nHOST="h1"\nUSERNAME="jon"\n'     | w "$FX/accounts.d/jon-basement.conf"
mandate() { # <id> <principal> <logins> <payer> <accept-source>
  printf 'PRINCIPAL="%s"\nLOGINS="%s"\nLEGAL_OWNER_APPROVED="%s"\nSCOPE="beneficiary:varvet project:steward"\nRESERVE="open-below:25 hard-cap:50 min-days-left:2 idle-hours:48"\nVALID_FROM="2026-09-10T00:00:00Z"\nTERMS_VERSION="v1"\nACCEPTED_AT="2026-09-09T21:00:00Z"\nACCEPT_SOURCE="%s"\n' "$2" "$3" "$4" "$5" | w "$FX/mandates.d/$1.conf"; }
check() { registry_mandate_check 2>/dev/null; }

echo "== 0. the control group: a coherent register is silent and rc 0 =="
mandate ok-unix simon simon-varvet Varvet unix-account:simon-basement
mandate ok-oidc simon simon-varvet Varvet desk-oidc:simon
out="$(check)"; rc=$?; is "rc 0" "$rc" "0"; is "nothing on stdout" "$out" ""

echo "== 1. a row that does not load is named, and the rest are still measured =="
printf 'PRINCIPAL="simon"\n' | w "$FX/mandates.d/broken.conf"
out="$(check)"; rc=$?; is "rc 1" "$rc" "1"; has "the broken row is named" "$out" "broken does-not-load"
is "and only that row" "$(printf '%s\n' "$out" | grep -c .)" "1"; rm -f "$FX/mandates.d/broken.conf"

echo "== 2. a login the register does not know =="
mandate ghost simon simon-ghost Varvet unix-account:simon-basement
has "named as login-unknown" "$(check)" "ghost login-unknown simon-ghost"; rm -f "$FX/mandates.d/ghost.conf"

echo "== 3. the payer on the mandate must be the payer of the seat =="
mandate wrongpayer simon simon-varvet Point unix-account:simon-basement
out="$(check)"; has "named as payer-mismatch" "$out" "wrongpayer payer-mismatch simon-varvet"; has "with both names" "$out" "LEGAL_OWNER_APPROVED='Point' but the login's LEGAL_OWNER is 'Varvet'"
rm -f "$FX/mandates.d/wrongpayer.conf"

echo "== 4. FALSE-CONSENT: signed from a channel that authenticates someone else =="
mandate relay simon simon-varvet Varvet unix-account:jon-basement       # jon's account signing simon's mandate
out="$(check)"; rc=$?; is "rc 1" "$rc" "1"; has "named as FALSE-CONSENT, not as malformed" "$out" "relay FALSE-CONSENT"
has "with the signer's principal" "$out" "principal 'jon'"; has "and whose mandate it is" "$out" "the mandate is simon's"
has "and the rule" "$out" "only the seat's own principal may consent"
rm -f "$FX/mandates.d/relay.conf"
mandate oidc-other simon simon-varvet Varvet desk-oidc:jon               # a desk login as jon, for simon's mandate
has "the same over desk-oidc" "$(check)" "oidc-other FALSE-CONSENT"; rm -f "$FX/mandates.d/oidc-other.conf"
mandate noacct simon simon-varvet Varvet unix-account:nobody-basement
has "an account nobody has is signer-unknown, not a pass" "$(check)" "noacct signer-unknown"; rm -f "$FX/mandates.d/noacct.conf"

echo "== 5. two logins on one row: each is measured =="
mandate two simon "simon-varvet jon-point" Varvet unix-account:simon-basement
out="$(check)"; has "the second login's payer differs" "$out" "two payer-mismatch jon-point"
is "the first login passes silently" "$(printf '%s\n' "$out" | grep -c 'simon-varvet')" "0"; rm -f "$FX/mandates.d/two.conf"

echo "== 6. the register's own state refuses the whole measurement =="
chmod 770 "$FX/mandates.d"; check >/dev/null; rc=$?; is "a loose register is rc 78, not a list of findings" "$rc" "78"; chmod 700 "$FX/mandates.d"
rc=$(STEWARD_MANDATES_DIR="$FX/nowhere" registry_mandate_check >/dev/null 2>&1; echo $?); is "an absent register is rc 78" "$rc" "78"

echo "== 7. the control group still holds after all of that =="
out="$(check)"; rc=$?; is "rc 0 again" "$rc" "0"; is "silent again" "$out" ""
echo "== 8. nothing leaks into the caller =="
LOGIN_LEGAL_OWNER="sentinel"; ACCOUNT_PRINCIPAL="sentinel"; check >/dev/null
is "LOGIN_* untouched by the check" "$LOGIN_LEGAL_OWNER" "sentinel"; is "ACCOUNT_* untouched by the check" "$ACCOUNT_PRINCIPAL" "sentinel"
echo; printf '%s passed, %s failed\n' "$pass" "$fail"; [ "$fail" -eq 0 ]
