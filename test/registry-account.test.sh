#!/bin/bash
# test/registry-account.test.sh — `steward registry account add`, the
# accounts.d register and its loader (registry_account_load), and the
# (ACCOUNT, SLUG) composite-uniqueness helper.
#
# accounts.d closes a gap the entity register never had to close: a bare
# username is not an identity — the same human already runs sessions under
# more than one host, and a username alone is neither unique across hosts
# nor stable enough to carry a bus address, history, or process ownership.
# An account names the (principal, host) pair a session's slug is scoped
# inside — see lib/registry.sh's own "ACCOUNTS" section for the design.
#
# THE WRITER IS NOT REIMPLEMENTED HERE. registry_account_write is a thin
# wrapper over the SAME transaction test/registry-org-verbs.test.sh already
# proves adversarially (lock, stage, chmod-hard-refuse, no-clobber publish,
# canonical readback, fail-closed rollback) — this suite does not repeat
# that matrix. What IS specific to accounts, and therefore IS proved here:
# the host-must-exist gate, the subshelled host load (a hostile hosts.d row
# must not clobber this verb's own locals the way a hostile managed-by
# entity once could on the client-add path), and the serializer's escaping
# on the two account fields that carry it differently — USERNAME (no
# semantic check in the loader, so a malicious payload round-trips through
# the real writer+loader byte-for-byte) and PRINCIPAL (validated by the
# loader itself, so the writer's own readback step catches and rolls back a
# malformed value — defence in depth, proved directly, not assumed).
#
# HERMETIC: a fresh mktemp estate per run, STEWARD_CONFIG_FILE pinned to a
# path that cannot exist.
set -u

here="$(CDPATH= cd -- "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
STEWARD="$here/bin/steward"
pass=0; fail=0
ok()  { pass=$((pass+1)); printf '  ok   %s\n' "$1"; }
bad() { fail=$((fail+1)); printf '  FAIL %s\n     %s\n' "$1" "${2:-}"; }
is()    { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "wanted '$3', got '$2'"; fi; }
has()   { case "$2" in *"$3"*) ok "$1" ;; *) bad "$1" "missing '$3' in: $2" ;; esac; }
absent(){ if [ ! -e "$2" ]; then ok "$1"; else bad "$1" "unexpectedly exists: $2"; fi; }

FX="$(mktemp -d)"; trap 'rm -rf "$FX"' EXIT
mkdir -p "$FX/estate" "$FX/accounts.d" "$FX/hosts.d" "$FX/sessions.d"

# THE ESTATE FILE, the same required-key set test/registry-org-verbs.test.sh
# fills out — the account verb sources lib/registry.sh, and a half-built
# estate would make every refusal below a fixture bug instead of a
# measurement of the verb.
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

ACCT="$FX/accounts.d"
HOSTS="$FX/hosts.d"
SESS="$FX/sessions.d"

# ONE VALID HOST — the minimal field set registry_host_load requires
# (OWNER, LEGAL_OWNER, OPERATOR), the same shape as a real hosts.d row.
cat > "$HOSTS/h1.conf" <<'EOF'
OWNER="a"
LEGAL_OWNER="Fixture Co"
OPERATOR="a"
EOF

# run <args...> — a hermetic invocation. STEWARD_CONFIG_FILE is aimed at a
# path that cannot exist, so the operator config never contributes a value
# the fixture did not set.
run() {
  STEWARD_ESTATE_ROOT="$FX" STEWARD_CONFIG_FILE="$FX/no-such-config" \
  bash "$STEWARD" registry account "$@" 2>&1
}

# load_account <slug> — round trip through the REAL loader, in a subshell so
# ACCOUNT_* never leaks between checks. Prints "PRINCIPAL|HOST|USERNAME" on
# success, nothing on failure (rc preserved).
load_account() {
  (
    STEWARD_ESTATE_ROOT="$FX"
    # shellcheck source=/dev/null
    . "$here/lib/registry.sh"
    registry_account_load "$1" >/dev/null 2>&1 || exit 1
    printf '%s|%s|%s' "$ACCOUNT_PRINCIPAL" "$ACCOUNT_HOST" "$ACCOUNT_USERNAME"
  )
}

echo "== 1. account add: PRINCIPAL/HOST/USERNAME, mode, round trip via registry_account_load =="
out="$(run add a-h1 --principal a --host h1 --json)"; rc=$?
is "1: rc 0"          "$rc" "0"
is "1: ok true"       "$(printf '%s' "$out" | jq -r '.ok')" "true"
is "1: kind account"  "$(printf '%s' "$out" | jq -r '.kind')" "account"
is "1: slug echoed"   "$(printf '%s' "$out" | jq -r '.slug')" "a-h1"
is "1: file mode 600" "$(stat -c '%a' "$ACCT/a-h1.conf" 2>/dev/null || stat -f '%Lp' "$ACCT/a-h1.conf")" "600"
is "1: loads back via registry_account_load — --username defaults to --principal" \
  "$(load_account a-h1)" "a|h1|a"

echo "== 1b. account add: explicit --username, round trip =="
out="$(run add a-h1-work --principal a --host h1 --username awork --json)"; rc=$?
is "1b: rc 0" "$rc" "0"
is "1b: loads back with the explicit username" "$(load_account a-h1-work)" "a|h1|awork"

echo "== 1c. missing --principal refuses rc 64, nothing written =="
out="$(run add nope1 --host h1 --json)"; rc=$?
is "1c: rc 64" "$rc" "64"
is "1c: ok false" "$(printf '%s' "$out" | jq -r '.ok')" "false"
absent "1c: nothing written" "$ACCT/nope1.conf"

echo "== 1d. missing --host refuses rc 64, nothing written =="
out="$(run add nope2 --principal a --json)"; rc=$?
is "1d: rc 64" "$rc" "64"
absent "1d: nothing written" "$ACCT/nope2.conf"

echo "== 1e. bad --principal form refuses rc 64, nothing written =="
out="$(run add nope3 --principal Bad_Principal --host h1 --json)"; rc=$?
is "1e: rc 64" "$rc" "64"
absent "1e: nothing written" "$ACCT/nope3.conf"

echo "== 1f. bad --host form refuses rc 64, nothing written =="
out="$(run add nope4 --principal a --host H1_Bad --json)"; rc=$?
is "1f: rc 64" "$rc" "64"
absent "1f: nothing written" "$ACCT/nope4.conf"

echo "== 1g. bad --username form refuses rc 64, nothing written =="
out="$(run add nope5 --principal a --host h1 --username Bad_User --json)"; rc=$?
is "1g: rc 64" "$rc" "64"
absent "1g: nothing written" "$ACCT/nope5.conf"

echo "== 2. HOST must exist: --host ghost (no hosts.d/ghost.conf) refuses rc 78, names it, nothing written =="
out="$(run add ghosted --principal a --host ghost --json)"; rc=$?
is "2: rc 78" "$rc" "78"
is "2: ok false" "$(printf '%s' "$out" | jq -r '.ok')" "false"
has "2: reason names the missing host" "$(printf '%s' "$out" | jq -r '.reason')" "ghost"
absent "2: nothing written" "$ACCT/ghosted.conf"

echo "== 3. THE INJECTION SUITE — a hostile hosts.d row must not clobber the caller's slug/principal via bash's dynamic scope =="
# cmd_registry_account_add calls registry_host_load on the HOST's own conf
# to check it resolves. registry_host_load SOURCES that conf and does not
# declare its own fields `local`. Called un-subshelled, an assignment in
# the conf using the SAME NAME as one of this function's own locals (slug,
# principal — lowercase, not the uppercase fields registry_host_load itself
# sets) overwrites that local via bash's dynamic scoping. The PoC slug
# "../pwned" resolves relative to accounts.d and lands in the estate root,
# which already exists — the same shape C1 in registry-org-verbs.test.sh
# proved on the entity-write side, now proved on this verb's host-read side.
cat > "$HOSTS/evilhost.conf" <<'EOF'
OWNER="a"
LEGAL_OWNER="Fixture Co"
OPERATOR="a"
slug="../pwned"
principal="CLOBBERED"
EOF
out="$(run add goodslug --principal a --host evilhost --json)"; rc=$?
is "3: rc 0 — the legitimate write still succeeds" "$rc" "0"
is "3: the response names the CALLER's slug, not the injected one" \
  "$(printf '%s' "$out" | jq -r '.slug')" "goodslug"
is "3: goodslug.conf carries the CALLER's PRINCIPAL, not the injected one" \
  "$(load_account goodslug)" "a|evilhost|a"
absent "3: nothing written outside accounts.d via the injected slug (../pwned)" "$FX/pwned.conf"
is "3: no file OTHER than the attack fixture itself carries the injected principal" \
  "$(grep -rl 'CLOBBERED' "$FX" 2>/dev/null | grep -v '/evilhost\.conf$' || true)" ""

echo "== 4. serializer injection — USERNAME round-trips through the REAL writer+loader byte-for-byte, no side effect =="
# USERNAME carries no semantic form check inside registry_account_load
# (only this CLI verb's own --username flag does, at case 1g above) — so,
# unlike PRINCIPAL (see 4e below), a shell-metacharacter payload placed
# directly on USERNAME reaches _registry_emit_kv, gets published, and is
# expected to round-trip through the SAME blessed path a real caller uses:
# registry_account_write to publish, registry_account_load to read back.
# Bypasses the CLI's own --username regex on purpose, by calling the writer
# directly — the same posture C1b in registry-org-verbs.test.sh took
# against registry_entity_write's own slug check.
write_account_direct() { # <slug> <principal> <host> <username>
  (
    STEWARD_ESTATE_ROOT="$FX"
    # shellcheck source=/dev/null
    . "$here/lib/registry.sh"
    kv1="$(_registry_emit_kv PRINCIPAL "$2")"; rc=$?; [ "$rc" -eq 0 ] || exit "$rc"
    kv2="$(_registry_emit_kv HOST "$3")"; rc=$?; [ "$rc" -eq 0 ] || exit "$rc"
    kv3="$(_registry_emit_kv USERNAME "$4")"; rc=$?; [ "$rc" -eq 0 ] || exit "$rc"
    content="$(printf '# %s — account, test fixture.\n%s\n%s\n%s' "$1" "$kv1" "$kv2" "$kv3")"$'\n'
    _account_always_ok() { return 0; }
    registry_account_write "$1" "$content" _account_always_ok
  )
}

MARK1="$FX/PWNED-cmdsub-$$"
write_account_direct inj-cmdsub a h1 "\$(touch $MARK1)"; rc=$?
is "4a: rc 0" "$rc" "0"
absent "4a: no side-effect file — nothing executed at write time" "$MARK1"
is "4a: USERNAME loads back byte-for-byte through registry_account_load" \
  "$(load_account inj-cmdsub)" "a|h1|\$(touch $MARK1)"
absent "4a: still no side-effect file after the explicit load — nothing executed at read time" "$MARK1"

MARK2="$FX/PWNED-backtick-$$"
write_account_direct inj-backtick a h1 "\`touch $MARK2\`"; rc=$?
is "4b: rc 0" "$rc" "0"
absent "4b: no side-effect file" "$MARK2"
is "4b: loads back byte-for-byte" "$(load_account inj-backtick)" "a|h1|\`touch $MARK2\`"

write_account_direct inj-var a h1 '$HOME-is-not-expanded'; rc=$?
is "4c: rc 0" "$rc" "0"
is "4c: \$VAR form preserved literally, not expanded" "$(load_account inj-var)" 'a|h1|$HOME-is-not-expanded'

write_account_direct inj-backslash a h1 'back\slash\here'; rc=$?
is "4d: rc 0" "$rc" "0"
is "4d: backslash form round-trips exactly" "$(load_account inj-backslash)" 'a|h1|back\slash\here'

echo "== 4e. PRINCIPAL IS validated by the loader itself — a malformed value is caught and rolled back by the writer's own readback step (defence in depth, not a gap) =="
# The same write_account_direct primitive, this time putting the payload on
# PRINCIPAL instead of USERNAME. _registry_emit_kv still escapes it and the
# publish still lands — but registry_row_write's step 7 (registry_account_load,
# under the same lock, right after publish) refuses the row because
# PRINCIPAL fails ^[a-z][a-z0-9-]*$, and the writer removes what it just
# published rather than leave a row it cannot itself read back.
MARK3="$FX/PWNED-principal-$$"
write_account_direct inj-principal "\$(touch $MARK3)" h1 a; rc=$?
is "4e: the writer refuses (rc 70) — its own readback validation rejects the row" "$rc" "70"
absent "4e: nothing left published under the final name — the rollback removed it" "$ACCT/inj-principal.conf"
absent "4e: no side-effect file — nothing executed even while the readback step re-sourced it" "$MARK3"

echo "== 4f. control byte (embedded newline) in PRINCIPAL refuses rc 64 at the serializer, nothing written =="
write_account_direct inj-newline "$(printf 'a\nb')" h1 a; rc=$?
is "4f: rc 64" "$rc" "64"
absent "4f: nothing written" "$ACCT/inj-newline.conf"

echo "== 4g. control byte (embedded tab) in USERNAME refuses rc 64 at the serializer, nothing written =="
write_account_direct inj-tab a h1 "$(printf 'a\tb')"; rc=$?
is "4g: rc 64" "$rc" "64"
absent "4g: nothing written" "$ACCT/inj-tab.conf"

echo "== 5. create-only: a second add on the same slug refuses rc 65, names the file, leaves it untouched =="
before="$(cat "$ACCT/a-h1.conf")"
out="$(run add a-h1 --principal a --host h1 --json)"; rc=$?
is "5: rc 65" "$rc" "65"
has "5: reason names the file" "$(printf '%s' "$out" | jq -r '.reason')" "a-h1.conf"
is "5: the original file is byte-identical afterward" "$(cat "$ACCT/a-h1.conf")" "$before"

echo "== 6. registry_account_slug_available — pure, not yet wired into any writer =="
# Sessions do not carry ACCOUNT/SLUG fields yet (a later step teaches
# session add to write them); a session conf that DOES carry them here is a
# hermetic TEST FIXTURE proving the scan works, not a real session shape.
cat > "$SESS/taken.conf" <<'EOF'
ACCOUNT="a-h1"
SLUG="alpha"
EOF
cat > "$SESS/other.conf" <<'EOF'
ACCOUNT="a-h1"
SLUG="beta"
EOF

check_available() {
  (
    STEWARD_ESTATE_ROOT="$FX"
    # shellcheck source=/dev/null
    . "$here/lib/registry.sh"
    registry_account_slug_available "$1" "$2"
  )
}

check_available a-h1 alpha; is "6a: (a-h1, alpha) is TAKEN — rc 1" "$?" "1"
check_available a-h1 gamma; is "6b: (a-h1, gamma) is available — rc 0" "$?" "0"
check_available other-account alpha; is "6c: same slug under a DIFFERENT account is available — rc 0" "$?" "0"

# 6d: A CONF MUST NOT SUPPRESS DETECTION OF ITS OWN PAIR. The scan sources
# each conf; a row that ALSO declares the function's own lowercase compare
# operands (account=/slug=) via bash dynamic scope would overwrite the query
# and report its own taken pair as "available" — a false negative on the one
# job this gate exists for. The source must never touch the caller's operands.
cat > "$SESS/hostile.conf" <<'EOF'
ACCOUNT="a-h1"
SLUG="squatter"
account="CLOBBERED"
slug="CLOBBERED"
EOF
check_available a-h1 squatter; is "6d: a conf declaring account=/slug= cannot fake 'available' for its own pair — rc 1" "$?" "1"
# And an unrelated query is still correctly available despite the hostile row.
check_available a-h1 free-slug; is "6e: unrelated pair still reads available past the hostile row — rc 0" "$?" "0"
rm -f "$SESS/hostile.conf"

echo "pass=$pass fail=$fail"
[ "$fail" -eq 0 ]
