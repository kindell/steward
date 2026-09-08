# Desk Services - Registry and Verbs Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Give the product a second identity source on `principals.d`, an `invites.d` register, and the verbs that issue, list, revoke, redeem and reverse an invitation - all measurable from a fixture, with no host touched for real.

**Architecture:** Everything lives in the two files the estate already reads: `lib/registry.sh` holds the readers, writers and the invite category; `bin/steward` holds the verbs as `cmd_*` functions dispatched from the top-level `case`. The one new shipped file is `linux/steward-account-helper`, the root-owned helper the sudoers line allows, which is the only path from the steward account to `useradd`. Every host-touching action in `invite redeem` and `offboard` goes through an external command (`sudo`, `ssh-keygen`, `ssh-keyscan`, `bash <product>/linux/deploy-self.sh`) so a fixture can put a shim for it on PATH.

**Tech Stack:** bash (product scripts run on Linux hosts, tests ALSO run on macOS bash 3.2 with BSD grep/sed/date - no `declare -A`, no `mapfile`, no `readarray`, no `date -d`, no `sed -i ''` differences unguarded, no GNU-only flags), Node 22 stdlib only where the desk is touched

**Spec:** docs/superpowers/specs/2026-09-08-desk-services-design.md (and the shared step from docs/superpowers/specs/2026-09-08-desk-front-design.md)

**Out of scope (plan 2):** the Desk order spool in `desk/serve.mjs`, `steward desk apply`, `/desk/me`, `/desk/invite/<token>`, `/desk/admin/invites`, requests and grants, the `claude-login` and `forge-login` actions, and the spec's measurements 1-3. Measurement 4 (`sudo -n` and the helper on a real host) belongs to the estate, not to this plan.

## Global Constraints

- All code, comments, test names, commit messages and copy in English; ASCII only (`-`, never a long dash; no non-ASCII letters).
- `test/language.test.sh` sweeps the repo for Swedish words. Run it in every task's step 4: `PATH=/opt/homebrew/opt/node@22/bin:/opt/homebrew/bin:$PATH bash test/language.test.sh`.
- The sweep reads `git ls-files`, so a NEW file is invisible to it until it is staged. `git add <new files>` before running it, or the guard reports a clean tree over an unswept file.
- The product is estate-agnostic: NO estate, host, person or company names anywhere. Use neutral fixture names (`alice`, `acme`, `host-a`, `example.test`, `login-a@example.test`).
- TDD: failing test first, watched to fail, minimal code, watched to pass. At least one commit per task.
- Tests never ssh, tmux, systemd, sudo, useradd, codex, opencode or claude for real, never touch the real `$HOME` config, never use the network. Every such command is a PATH shim in the fixture.
- No test-only knobs in production code. An env var that exists only to make a test pass is forbidden. `STEWARD_ESTATE_ROOT`, `HOME`, `PATH` and the existing documented variables (`STEWARD_HOME_LOOKUP_CMD`, lib/registry.sh:3561; `STEWARD_AUTHORIZED_KEYS`, linux/hub/enroll:113; `STEWARD_PRINCIPAL_DIR`, `STEWARD_ENTITY_DIR`, `STEWARD_ACCOUNT_DIR`, `STEWARD_LOGINS_DIR`, `STEWARD_REGISTRY_DIR`, `STEWARD_HOSTS_DIR`) are fine.
- Test file idiom is the repo's own: `pass=0; fail=0`, `ok()`, `bad()`, `is()`, `has()`, fixture in `mktemp -d`, `trap ... EXIT`, and a final `printf '\n  %d passed, %d failed\n' "$pass" "$fail"` plus `[ "$fail" -eq 0 ]`. That last phrasing is the one `tools/run-tests.sh` parses (tools/run-tests.sh:97).
- Each test run command is `bash test/<name>.test.sh`.
- Registry rows are `KEY="value"` conf files. New categories follow the existing shape: `registry_principal_load` (lib/registry.sh:1725), `registry_principal_for_login` (:1780), `registry_principal_write` (:1806), `cmd_registry_principal_add` (bin/steward:1789), `_principal_validate_row` (bin/steward:1173), and `logins.d` (lib/registry.sh:3506-3787) for a category with required-field validation and a reader that never sources.
- The one writer core is `registry_row_write` (lib/registry.sh:1376). It REFUSES when the destination exists (rc 65), so an in-place update needs the sibling this plan adds; nothing may hand-roll a second transaction.
- The `registry` noun dispatch is `cmd_registry` (bin/steward:1341-1394); the top-level dispatch `case` is bin/steward:5097-5173.
- Never hardcode a `/home/<x>` home in production code. `_registry_owner_home <unix-username>` (lib/registry.sh:3567) is the estate's home lookup and honours `STEWARD_HOME_LOOKUP_CMD`.
- Secrets: the invite token is printed exactly once by `invite issue`; only its SHA-256 digest is stored. The receipt and `invite ls` never show a token.
- `bin/steward` runs under `set -uo pipefail` (bin/steward:40). Read every possibly-unset variable as `${VAR:-}`.
- After the last task run the whole product aggregate: `STEWARD_ESTATE_ROOT=<path to the estate checkout> PATH=/opt/homebrew/opt/node@22/bin:/opt/homebrew/bin:$PATH bash tools/run-tests.sh .` It takes about 5 minutes and ends with a line beginning `suites found=`.

---

### Task 1: `OIDC_LOGIN` on `principals.d` and `registry_principal_for_identity`

**Files:**
- Modify: `lib/registry.sh` (the principals block, lines 1702-1800)
- Test: `test/principal-identity.test.sh` (create)

**Interfaces:**
- Consumes: `_registry_words` (lib/registry.sh:532), `registry_printable` (:551), `registry_principal_dir` (:1697), `_registry_login_valid` (:1703).
- Produces:
  - `_registry_oidc_login_valid <word>` - rc 0 when the word matches `^[a-z0-9][a-z0-9-]*:[A-Za-z0-9._~-]+$`.
  - `registry_principal_load <slug>` additionally sets `PRINCIPAL_OIDC_LOGIN` (the row's words joined by single spaces, case preserved) and `PRINCIPAL_OIDC_EMAIL`. A row with neither `TAILSCALE_LOGIN` nor `OIDC_LOGIN` is rc 1; the refusal names `TAILSCALE_LOGIN`.
  - `registry_principal_for_identity <source> <value>` - `<source>` is `tailscale` or `oidc`. rc 0 and the slug on stdout for exactly one row, rc 1 for none, rc 65 for more than one (both named on stderr), rc 64 for an unknown source.
  - `registry_principal_for_login <login>` - unchanged contract, now a wrapper for `registry_principal_for_identity tailscale`.

- [ ] **Step 1: Write the failing test**

Create `test/principal-identity.test.sh`:

```bash
#!/bin/bash
# test/principal-identity.test.sh - principals.d carries TWO identity sources.
# A tailnet login is an address and is matched case-insensitively; an OIDC
# identity is <issuer-slug>:<subject>, and the SUBJECT is case-sensitive - a
# provider that mints a base64url subject mints "aB" and "Ab" as two people.
set -u
here="$(CDPATH= cd -- "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
pass=0; fail=0
ok()  { pass=$((pass+1)); printf '  ok   %s\n' "$1"; }
bad() { fail=$((fail+1)); printf '  FAIL %s\n     %s\n' "$1" "${2:-}"; }
is()  { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "wanted '$3', got '$2'"; fi; }
has() { case "$2" in *"$3"*) ok "$1" ;; *) bad "$1" "missing '$3' in: $2" ;; esac; }
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
ROOT="$T/estate"; mkdir -p "$ROOT/principals.d" "$ROOT/estate"
printf 'ESTATE_NAME="fixture"\n' > "$ROOT/estate/steward.conf"
export STEWARD_ESTATE_ROOT="$ROOT" STEWARD_CONFIG_FILE="$T/no-such-config"
. "$here/lib/registry.sh"
echo "principal-identity"

printf 'NAME="Alice"\nTAILSCALE_LOGIN="login-a@example.test"\nOIDC_LOGIN="issuer-a:SUB-1"\nOIDC_EMAIL="alice@example.test"\n' \
  > "$ROOT/principals.d/alice.conf"
printf 'NAME="Bo"\nOIDC_LOGIN="issuer-a:SUB-2 issuer-b:SUB-3"\n' > "$ROOT/principals.d/bo.conf"

registry_principal_load alice; rc=$?
is  "a row with both sources loads" "$rc" "0"
is  "the tailnet login is exposed" "$PRINCIPAL_TAILSCALE_LOGIN" "login-a@example.test"
is  "the oidc identity is exposed" "$PRINCIPAL_OIDC_LOGIN" "issuer-a:SUB-1"
is  "the display email is exposed" "$PRINCIPAL_OIDC_EMAIL" "alice@example.test"

registry_principal_load bo; rc=$?
is  "a row with ONLY an oidc identity loads" "$rc" "0"
is  "and carries no tailnet login" "$PRINCIPAL_TAILSCALE_LOGIN" ""
is  "and exposes both oidc words" "$PRINCIPAL_OIDC_LOGIN" "issuer-a:SUB-2 issuer-b:SUB-3"

printf 'NAME="Nobody"\n' > "$ROOT/principals.d/nobody.conf"
registry_principal_load nobody 2>"$T/err"; rc=$?
is  "a row with neither source is refused" "$rc" "1"
has "and still names TAILSCALE_LOGIN" "$(cat "$T/err")" "TAILSCALE_LOGIN"
is  "a refused load leaves nothing behind" "$PRINCIPAL_OIDC_LOGIN" ""

printf 'NAME="Bad"\nOIDC_LOGIN="no-colon-here"\n' > "$ROOT/principals.d/bad.conf"
registry_principal_load bad 2>"$T/err"; rc=$?
is  "an oidc word without a subject is refused" "$rc" "1"
has "and names the field" "$(cat "$T/err")" "OIDC_LOGIN"
rm -f "$ROOT/principals.d/bad.conf"

is  "the oidc lookup finds the row" "$(registry_principal_for_identity oidc issuer-a:SUB-1)" "alice"
is  "the second word of a list resolves" "$(registry_principal_for_identity oidc issuer-b:SUB-3)" "bo"
registry_principal_for_identity oidc issuer-a:sub-1 >/dev/null 2>&1; rc=$?
is  "the SUBJECT is case-sensitive" "$rc" "1"
registry_principal_for_identity oidc issuer-a:SUB-9 >/dev/null 2>&1; rc=$?
is  "an unknown oidc identity is rc 1" "$rc" "1"
registry_principal_for_identity elsewhere x >/dev/null 2>&1; rc=$?
is  "an unknown source is rc 64" "$rc" "64"

is  "the tailscale source resolves" "$(registry_principal_for_identity tailscale login-a@example.test)" "alice"
is  "and is case-insensitive" "$(registry_principal_for_identity tailscale LOGIN-A@EXAMPLE.TEST)" "alice"
is  "the old wrapper is unchanged" "$(registry_principal_for_login login-a@example.test)" "alice"

printf 'NAME="Twin"\nOIDC_LOGIN="issuer-a:SUB-1"\n' > "$ROOT/principals.d/twin.conf"
registry_principal_for_identity oidc issuer-a:SUB-1 >"$T/out" 2>"$T/err"; rc=$?
is  "an oidc identity on two rows is rc 65" "$rc" "65"
is  "and prints no slug" "$(cat "$T/out")" ""
has "and names both rows" "$(cat "$T/err")" "twin"
rm -f "$ROOT/principals.d/twin.conf"

printf '\n  %d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
```

- [ ] **Step 2: Run test to verify it fails**
  Run: `bash test/principal-identity.test.sh`
  Expected: FAIL with `registry_principal_for_identity: command not found` and `wanted 'issuer-a:SUB-1', got ''` for the `PRINCIPAL_OIDC_LOGIN` assertions.

- [ ] **Step 3: Write minimal implementation**

In `lib/registry.sh`, immediately after `_registry_login_valid` (line 1705), add:

```bash
# _registry_oidc_login_valid <word> - the shape an OIDC identity has here:
# "<issuer-slug>:<subject>". The issuer half is OURS (a slug we choose per
# provider) and is therefore a slug; the subject half is the PROVIDER'S and is
# taken as-is within a conservative charset - it is an opaque string that we
# compare and never parse.
#
# THE SUBJECT IS NEVER CASE-FOLDED, and that is the whole reason this is a
# separate validator rather than a second call to the login one. A tailnet
# login is an address, where case carries no meaning; a subject can be
# base64url, where two spellings are two different people. Folding it would
# merge two humans into one row's worth of authority.
_registry_oidc_login_valid() {
  [[ "${1:-}" =~ ^[a-z0-9][a-z0-9-]*:[A-Za-z0-9._~-]+$ ]]
}
```

Replace the body of `registry_principal_load` (lines 1725-1760) with:

```bash
registry_principal_load() {
  PRINCIPAL_ID=""; PRINCIPAL_NAME=""; PRINCIPAL_TAILSCALE_LOGIN=""; PRINCIPAL_DESK_READ_ALL=""
  PRINCIPAL_OIDC_LOGIN=""; PRINCIPAL_OIDC_EMAIL=""
  local slug="${1:-}" d f
  [ -n "$slug" ] || return 1
  registry_valid_name "$slug" || { echo "registry: invalid principal slug" >&2; return 1; }
  d="$(registry_principal_dir)" || return 78
  f="$d/$slug.conf"
  [ -f "$f" ] || { echo "registry: no such principal: $slug" >&2; return 1; }
  local NAME="" TAILSCALE_LOGIN="" DESK_READ_ALL="" OIDC_LOGIN="" OIDC_EMAIL=""
  # shellcheck source=/dev/null
  source "$f" || return 1
  if [ -z "$NAME" ]; then
    echo "registry: $slug.conf missing NAME" >&2
    return 1
  fi
  _registry_words "$TAILSCALE_LOGIN"
  local w normalized=""
  for w in "${REGISTRY_WORDS[@]+"${REGISTRY_WORDS[@]}"}"; do
    if ! _registry_login_valid "$w"; then
      echo "registry: $slug.conf has an invalid TAILSCALE_LOGIN word '$(registry_printable "$w")'" >&2
      return 1
    fi
    normalized="${normalized:+$normalized }$(printf '%s' "$w" | tr '[:upper:]' '[:lower:]')"
  done
  # OIDC_LOGIN IS THE SECOND SOURCE, VALIDATED PER WORD LIKE THE FIRST. No case
  # folding - see _registry_oidc_login_valid.
  _registry_words "$OIDC_LOGIN"
  local oidc=""
  for w in "${REGISTRY_WORDS[@]+"${REGISTRY_WORDS[@]}"}"; do
    if ! _registry_oidc_login_valid "$w"; then
      echo "registry: $slug.conf has an invalid OIDC_LOGIN word '$(registry_printable "$w")' (expected <issuer-slug>:<subject>)" >&2
      return 1
    fi
    oidc="${oidc:+$oidc }$w"
  done
  # AT LEAST ONE SOURCE. A principal no entrance can resolve is a row that
  # grants nothing and can never be matched - refused the same way a missing
  # field is. The message still names TAILSCALE_LOGIN because that is the
  # source every existing row carries and the one a reader looks for first.
  if [ -z "$normalized" ] && [ -z "$oidc" ]; then
    echo "registry: $slug.conf missing/invalid identity - a principal needs TAILSCALE_LOGIN, OIDC_LOGIN, or both" >&2
    return 1
  fi
  case "$DESK_READ_ALL" in
    ""|yes) ;;
    *) echo "registry: $slug.conf DESK_READ_ALL must be yes or absent" >&2; return 1 ;;
  esac
  PRINCIPAL_ID="$slug"; PRINCIPAL_NAME="$NAME"
  PRINCIPAL_TAILSCALE_LOGIN="$normalized"
  PRINCIPAL_OIDC_LOGIN="$oidc"
  # INFORMATIONAL ONLY, and never used for lookup: an email moves between
  # people, a subject does not.
  PRINCIPAL_OIDC_EMAIL="$OIDC_EMAIL"
  PRINCIPAL_DESK_READ_ALL="$DESK_READ_ALL"
}
```

Replace `registry_principal_for_login` (lines 1780-1800) with the pair below (keep the long comment block above it as it stands and add the reference to the new function):

```bash
registry_principal_for_identity() {
  local src="${1:-}" want="${2:-}" d f hits="" slug
  case "$src" in
    tailscale) want="$(printf '%s' "$want" | tr '[:upper:]' '[:lower:]')" ;;
    oidc)      : ;;
    *) echo "registry: unknown identity source '$(registry_printable "$src")' (allowed: tailscale, oidc)" >&2; return 64 ;;
  esac
  [ -n "$want" ] || return 1
  d="$(registry_principal_dir)" || return 78
  [ -d "$d" ] || return 1
  for f in "$d"/*.conf; do
    [ -e "$f" ] || continue
    slug="$(basename "$f" .conf)"
    # EVERY ROW IS LOADED IN A SUBSHELL and the containment test runs INSIDE
    # it - see the block comment above: a hostile conf sourced deep inside
    # registry_principal_load must never reach this function's own locals.
    if ( registry_principal_load "$slug" >/dev/null 2>&1 && \
         case "$src" in
           tailscale) case " $PRINCIPAL_TAILSCALE_LOGIN " in *" $want "*) true ;; *) false ;; esac ;;
           *)         case " $PRINCIPAL_OIDC_LOGIN "      in *" $want "*) true ;; *) false ;; esac ;;
         esac ); then
      hits="$hits $slug"
    fi
  done
  set -- $hits
  case $# in
    0) return 1 ;;
    1) printf '%s\n' "$1"; return 0 ;;
    *) echo "registry: the identity maps to more than one principal:$hits - refusing to pick" >&2; return 65 ;;
  esac
}

# registry_principal_for_login <login> - the tailnet half of the function
# above, kept under its old name because every existing caller (the desk
# bridge, the principal-add pre-check, the under-lock validator) asks exactly
# this question. Same return codes, same output.
registry_principal_for_login() {
  registry_principal_for_identity tailscale "${1:-}"
}
```

- [ ] **Step 4: Run test to verify it passes**
  Run: `bash test/principal-identity.test.sh`, then `bash test/registry-principal.test.sh` (the sibling suite must stay green), then `git add test/principal-identity.test.sh` and `PATH=/opt/homebrew/opt/node@22/bin:/opt/homebrew/bin:$PATH bash test/language.test.sh`.

- [ ] **Step 5: Commit**
  `git add lib/registry.sh test/principal-identity.test.sh`
  `git commit -m "feat(registry): OIDC_LOGIN as a second identity source on principals.d"`

---

### Task 2: `steward registry principal add --oidc-login`

**Files:**
- Modify: `bin/steward` - `_principal_validate_row` (lines 1173-1205), `cmd_registry_principal_add` (lines 1789-1918), the usage header comment near line 37
- Test: `test/principal-identity-verb.test.sh` (create)

**Interfaces:**
- Consumes: `registry_principal_for_identity <source> <value>` (rc 0 slug / 1 none / 65 ambiguous / 64 bad source), `registry_principal_write <slug> <content> <validate_fn>`, `_registry_emit_kv KEY VALUE`, `_registry_words`, `registry_printable`, `_reg_fail <want_json> <msg>`, `_json`.
- Produces: `steward registry principal add <slug> --name N [--tailscale-login L]... [--oidc-login I]... [--oidc-email E] [--read-all] [--json]`. rc 0 on write; rc 64 for a missing slug/name, a malformed word, or no identity at all; rc 65 when a word already belongs to another principal (pre-check); rc 70 when the under-lock validator catches it. The row carries `OIDC_LOGIN` and `OIDC_EMAIL` lines only when they were given, so a tailnet-only row is byte-identical to what the verb wrote before.
- Produces: `_principal_validate_row` also compares `OIDC_LOGIN` and `OIDC_EMAIL` against `_REGW_EXPECT_OIDC_LOGIN` / `_REGW_EXPECT_OIDC_EMAIL` and re-asks the register-wide uniqueness question per OIDC word under the lock.

- [ ] **Step 1: Write the failing test**

Create `test/principal-identity-verb.test.sh`:

```bash
#!/bin/bash
# test/principal-identity-verb.test.sh - the write side of the second identity
# source: one identity, one human, enforced before the lock and again under it.
set -u
here="$(CDPATH= cd -- "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
pass=0; fail=0
ok()  { pass=$((pass+1)); printf '  ok   %s\n' "$1"; }
bad() { fail=$((fail+1)); printf '  FAIL %s\n     %s\n' "$1" "${2:-}"; }
is()  { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "wanted '$3', got '$2'"; fi; }
has() { case "$2" in *"$3"*) ok "$1" ;; *) bad "$1" "missing '$3' in: $2" ;; esac; }
no()  { case "$2" in *"$3"*) bad "$1" "found '$3' in: $2" ;; *) ok "$1" ;; esac; }
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
ROOT="$T/estate"; mkdir -p "$ROOT/principals.d" "$ROOT/estate"
printf 'ESTATE_NAME="fixture"\n' > "$ROOT/estate/steward.conf"
export STEWARD_ESTATE_ROOT="$ROOT" STEWARD_CONFIG_FILE="$T/no-such-config"
S="$here/bin/steward"
echo "principal-identity-verb"

out="$(bash "$S" registry principal add alice --name Alice --oidc-login issuer-a:SUB-1 2>&1)"; rc=$?
is  "an oidc-only principal is written" "$rc" "0"
has "the row carries the identity" "$(cat "$ROOT/principals.d/alice.conf")" 'OIDC_LOGIN="issuer-a:SUB-1"'
no  "and no empty tailnet line" "$(cat "$ROOT/principals.d/alice.conf")" 'TAILSCALE_LOGIN=""'

out="$(bash "$S" registry principal add bo --name Bo --tailscale-login login-b@example.test 2>&1)"; rc=$?
is  "a tailnet-only principal still works" "$rc" "0"
no  "and carries no empty oidc line" "$(cat "$ROOT/principals.d/bo.conf")" 'OIDC_LOGIN=""'

out="$(bash "$S" registry principal add cy --name Cy --oidc-login 'issuer-a:SUB-9 issuer-b:SUB-9' \
        --oidc-email cy@example.test --tailscale-login login-c@example.test 2>&1)"; rc=$?
is  "both sources on one row" "$rc" "0"
has "both oidc words are written" "$(cat "$ROOT/principals.d/cy.conf")" 'OIDC_LOGIN="issuer-a:SUB-9 issuer-b:SUB-9"'
has "the display email is written" "$(cat "$ROOT/principals.d/cy.conf")" 'OIDC_EMAIL="cy@example.test"'

out="$(bash "$S" registry principal add dee --name Dee 2>&1)"; rc=$?
is  "no identity at all is rc 64" "$rc" "64"
has "and says what is missing" "$out" "identity"

out="$(bash "$S" registry principal add ell --name Ell --oidc-login 'no-colon' 2>&1)"; rc=$?
is  "a malformed oidc word is rc 64" "$rc" "64"
is  "and nothing was written" "$(ls "$ROOT/principals.d" | grep -c ell)" "0"

out="$(bash "$S" registry principal add twin --name Twin --oidc-login issuer-a:SUB-1 2>&1)"; rc=$?
is  "a duplicate oidc identity is refused before the write" "$rc" "65"
has "and names the other principal" "$out" "alice"
is  "and nothing was written" "$(ls "$ROOT/principals.d" | grep -c twin)" "0"

out="$(bash "$S" registry principal add dedupe --name Dedupe \
        --oidc-login issuer-a:SUB-7 --oidc-login issuer-a:SUB-7 2>&1)"; rc=$?
is  "a word repeated within the row is de-duplicated" "$rc" "0"
has "and written once" "$(cat "$ROOT/principals.d/dedupe.conf")" 'OIDC_LOGIN="issuer-a:SUB-7"'

echo "== the ATOMIC gate: uniqueness is re-asked UNDER the register's write lock =="
_DUP='NAME="Raced"
OIDC_LOGIN="issuer-b:SUB-9"'
_rc=0
( export STEWARD_ESTATE_ROOT="$ROOT" STEWARD_CONFIG_FILE="$T/no-such-config"
  . "$here/lib/registry.sh"
  eval "$(sed -n '/^_principal_validate_row()/,/^}/p' "$here/bin/steward")"
  export _REGW_EXPECT_NAME="Raced" _REGW_EXPECT_TAILSCALE_LOGIN="" \
         _REGW_EXPECT_OIDC_LOGIN="issuer-b:SUB-9" _REGW_EXPECT_OIDC_EMAIL="" \
         _REGW_EXPECT_DESK_READ_ALL=""
  registry_principal_write raced "$_DUP" _principal_validate_row ) >/dev/null 2>&1 || _rc=$?
is  "the under-lock validator refuses a colliding oidc word" \
    "$( [ "$_rc" -ne 0 ] && echo refused || echo passed )" "refused"
if [ -e "$ROOT/principals.d/raced.conf" ]; then
  bad "no colliding row must be published" "found $ROOT/principals.d/raced.conf"
else
  ok "no colliding row published"
fi

printf '\n  %d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
```

- [ ] **Step 2: Run test to verify it fails**
  Run: `bash test/principal-identity-verb.test.sh`
  Expected: FAIL with `steward registry principal add: unknown flag '--oidc-login'` and rc 64 where rc 0 was wanted.

- [ ] **Step 3: Write minimal implementation**

In `bin/steward`, replace `_principal_validate_row` (lines 1173-1205) with:

```bash
_principal_validate_row() {
  local file="$1" NAME="" TAILSCALE_LOGIN="" DESK_READ_ALL="" OIDC_LOGIN="" OIDC_EMAIL=""
  # shellcheck source=/dev/null
  source "$file" || { echo "registry: staged principal file did not source: $file" >&2; return 70; }
  if [ "$NAME" != "${_REGW_EXPECT_NAME:-}" ]; then
    echo "registry: staged principal file's NAME does not match what was written: $file" >&2
    return 70
  fi
  if [ "$TAILSCALE_LOGIN" != "${_REGW_EXPECT_TAILSCALE_LOGIN:-}" ]; then
    echo "registry: staged principal file's TAILSCALE_LOGIN does not match what was written: $file" >&2
    return 70
  fi
  if [ "$OIDC_LOGIN" != "${_REGW_EXPECT_OIDC_LOGIN:-}" ]; then
    echo "registry: staged principal file's OIDC_LOGIN does not match what was written: $file" >&2
    return 70
  fi
  if [ "$OIDC_EMAIL" != "${_REGW_EXPECT_OIDC_EMAIL:-}" ]; then
    echo "registry: staged principal file's OIDC_EMAIL does not match what was written: $file" >&2
    return 70
  fi
  if [ "$DESK_READ_ALL" != "${_REGW_EXPECT_DESK_READ_ALL:-}" ]; then
    echo "registry: staged principal file's DESK_READ_ALL does not match what was written: $file" >&2
    return 70
  fi
  # THE REGISTER-WIDE QUESTION, ASKED UNDER THE LOCK, PER WORD, PER SOURCE.
  # Both lists are lists, and uniqueness holds per word in either of them.
  local w other rc2 src
  for src in tailscale oidc; do
    case "$src" in
      tailscale) _registry_words "$TAILSCALE_LOGIN" ;;
      *)         _registry_words "$OIDC_LOGIN" ;;
    esac
    for w in "${REGISTRY_WORDS[@]+"${REGISTRY_WORDS[@]}"}"; do
      other="$(registry_principal_for_identity "$src" "$w" 2>/dev/null)"; rc2=$?
      case "$rc2" in
        0)
          echo "registry: the identity '$w' already belongs to principal '$other' - one identity, one human - refusing" >&2
          return 70
          ;;
        65)
          echo "registry: the identity '$w' already maps to more than one principal - refusing to add a third - one identity, one human" >&2
          return 70
          ;;
      esac
    done
  done
  return 0
}
```

In `cmd_registry_principal_add`, replace the declaration line and the flag loop's head (lines 1790-1813) with:

```bash
cmd_registry_principal_add() {
  local want_json="" slug="" name="" read_all="" oidc_email="" a
  local logins=() oidcs=()
  for a in "$@"; do [ "$a" = "--json" ] && want_json=1; done

  while [ $# -gt 0 ]; do
    case "$1" in
      --json) shift ;;
      --name)
        [ $# -ge 2 ] || { _reg_fail "$want_json" "steward registry principal add: --name needs a value" 64; return 64; }
        name="$2"; shift 2 ;;
      --tailscale-login)
        [ $# -ge 2 ] || { _reg_fail "$want_json" "steward registry principal add: --tailscale-login needs a value" 64; return 64; }
        logins+=("$2"); shift 2 ;;
      --oidc-login)
        [ $# -ge 2 ] || { _reg_fail "$want_json" "steward registry principal add: --oidc-login needs a value" 64; return 64; }
        oidcs+=("$2"); shift 2 ;;
      --oidc-email)
        [ $# -ge 2 ] || { _reg_fail "$want_json" "steward registry principal add: --oidc-email needs a value" 64; return 64; }
        oidc_email="$2"; shift 2 ;;
      --read-all)
        read_all="yes"; shift ;;
      -*)
        _reg_fail "$want_json" "steward registry principal add: unknown flag '$1'" 64; return 64 ;;
      *)
        if [ -n "$slug" ]; then
          _reg_fail "$want_json" "steward registry principal add: one principal at a time" 64; return 64
        fi
        slug="$1"; shift ;;
    esac
  done
```

Replace the requirement line (1821) with a check that runs after the library is sourced. That is, delete line 1821 (`[ "${#logins[@]}" -gt 0 ] || ...`) and, after the `. "$HERE/lib/registry.sh"` line (1824), keep the existing tailnet collection loop unchanged but delete its trailing `[ "${#login_words[@]}" -gt 0 ] || ...` guard (line 1848). Then insert, immediately after the tailnet `login_joined` assembly (after line 1852):

```bash
  # THE OIDC LIST, COLLECTED THE SAME WAY: repeated flags and space-separated
  # values are one list, every word validated on its own, duplicates within the
  # row collapsed. No case folding - the subject half is the provider's.
  local ojoined="" oone
  for oone in "${oidcs[@]+"${oidcs[@]}"}"; do
    ojoined="${ojoined:+$ojoined }$oone"
  done
  _registry_words "$ojoined"
  local oseen="" oidc_words=()
  for w in "${REGISTRY_WORDS[@]+"${REGISTRY_WORDS[@]}"}"; do
    if ! _registry_oidc_login_valid "$w"; then
      _reg_fail "$want_json" "steward registry principal add: --oidc-login '$(registry_printable "$w")' must look like <issuer-slug>:<subject>" 64
      return 64
    fi
    case " $oseen " in *" $w "*) continue ;; esac
    oseen="$oseen $w"
    oidc_words+=("$w")
  done
  local oidc_joined=""
  for w in "${oidc_words[@]+"${oidc_words[@]}"}"; do
    oidc_joined="${oidc_joined:+$oidc_joined }$w"
  done
  # AT LEAST ONE SOURCE, the same rule the reader enforces. Checked here so the
  # verb refuses before staging rather than writing a row its own reader will
  # not load.
  if [ -z "$login_joined" ] && [ -z "$oidc_joined" ]; then
    _reg_fail "$want_json" "steward registry principal add: an identity is required - give --tailscale-login, --oidc-login, or both" 64
    return 64
  fi
  if [ -n "$oidc_email" ]; then
    case "$oidc_email" in
      *[[:space:]]*) _reg_fail "$want_json" "steward registry principal add: --oidc-email must not contain whitespace" 64; return 64 ;;
    esac
  fi
```

Replace the tailnet-only pre-check (lines 1854-1863) with:

```bash
  # DUPLICATE, BEFORE THE WRITE, PER WORD, PER SOURCE - see the comment above
  # this function. This is the FAST PATH; _principal_validate_row is the
  # guarantee.
  local other
  for w in "${login_words[@]+"${login_words[@]}"}"; do
    other="$(registry_principal_for_identity tailscale "$w" 2>/dev/null)"
    if [ -n "$other" ]; then
      _reg_fail "$want_json" "steward registry principal add: the login '$w' already belongs to principal '$other' - one identity, one human" 65
      return 65
    fi
  done
  for w in "${oidc_words[@]+"${oidc_words[@]}"}"; do
    other="$(registry_principal_for_identity oidc "$w" 2>/dev/null)"
    if [ -n "$other" ]; then
      _reg_fail "$want_json" "steward registry principal add: the identity '$w' already belongs to principal '$other' - one identity, one human" 65
      return 65
    fi
  done
```

Replace the serialization block (lines 1868-1896) with:

```bash
  local kv_name kv_login kv_oidc kv_omail rc kv_err
  kv_err="$(mktemp)" || { _reg_fail "$want_json" "steward registry principal add: cannot create a temporary file" 70; return 70; }
  kv_name="$(_registry_emit_kv NAME "$name" 2>"$kv_err")"; rc=$?
  if [ "$rc" -ne 0 ]; then
    rm -f "$kv_err"
    _reg_fail "$want_json" "steward registry principal add: --name contains a control character or newline" 64
    return 64
  fi
  kv_login="$(_registry_emit_kv TAILSCALE_LOGIN "$login_joined" 2>"$kv_err")"; rc=$?
  if [ "$rc" -ne 0 ]; then
    rm -f "$kv_err"
    _reg_fail "$want_json" "steward registry principal add: --tailscale-login contains a control character or newline" 64
    return 64
  fi
  kv_oidc="$(_registry_emit_kv OIDC_LOGIN "$oidc_joined" 2>"$kv_err")"; rc=$?
  if [ "$rc" -ne 0 ]; then
    rm -f "$kv_err"
    _reg_fail "$want_json" "steward registry principal add: --oidc-login contains a control character or newline" 64
    return 64
  fi
  kv_omail="$(_registry_emit_kv OIDC_EMAIL "$oidc_email" 2>"$kv_err")"; rc=$?
  rm -f "$kv_err"
  if [ "$rc" -ne 0 ]; then
    _reg_fail "$want_json" "steward registry principal add: --oidc-email contains a control character or newline" 64
    return 64
  fi

  _REGW_EXPECT_NAME="$name"
  _REGW_EXPECT_TAILSCALE_LOGIN="$login_joined"
  _REGW_EXPECT_OIDC_LOGIN="$oidc_joined"
  _REGW_EXPECT_OIDC_EMAIL="$oidc_email"
  _REGW_EXPECT_DESK_READ_ALL="$read_all"
  local rw_err; rw_err="$(mktemp)" || {
    _reg_fail "$want_json" "steward registry principal add: cannot create a temporary file" 70
    return 70
  }
  # A FIELD THAT WAS NOT GIVEN GETS NO LINE. A row with only a tailnet login
  # must be byte-identical to what this verb wrote before OIDC existed - the
  # register is in git, and a diff on every row would hide the one that
  # changed meaning.
  local content
  content="$(printf '# %s - principal, written by steward registry principal add.\n%s' "$slug" "$kv_name")"
  [ -n "$login_joined" ] && content="$content"$'\n'"$kv_login"
  [ -n "$oidc_joined" ]  && content="$content"$'\n'"$kv_oidc"
  [ -n "$oidc_email" ]   && content="$content"$'\n'"$kv_omail"
  [ -n "$read_all" ]     && content="$content"$'\n''DESK_READ_ALL="yes"'
  content="$content"$'\n'
```

Replace the report block (lines 1909-1917) with:

```bash
  local file; file="$(registry_principal_dir)/$slug.conf"
  if [ -n "$want_json" ]; then
    local ra_bool=false; [ -n "$read_all" ] && ra_bool=true
    _json ok true kind principal slug "$slug" name "$name" \
      tailscaleLogin "$login_joined" oidcLogin "$oidc_joined" oidcEmail "$oidc_email" \
      readAll "$ra_bool" file "$file"
  else
    printf 'steward: wrote principals.d/%s.conf (principal %s, identities %s%s)\n' \
      "$slug" "$name" "${login_joined:-none}${oidc_joined:+ $oidc_joined}" \
      "$( [ -n "$read_all" ] && printf ', read-all' )"
  fi
  return 0
}
```

Finally update the usage header near bin/steward:37 by adding the line:

```
#   steward registry principal add <slug> --name N [--tailscale-login L]... [--oidc-login <issuer>:<sub>]... [--oidc-email E] [--read-all] [--json]
```

- [ ] **Step 4: Run test to verify it passes**
  Run: `bash test/principal-identity-verb.test.sh`, then `bash test/registry-principal.test.sh`, `bash test/principal-identity.test.sh`, `bash test/writer-census.test.sh`, then `git add test/principal-identity-verb.test.sh` and `PATH=/opt/homebrew/opt/node@22/bin:/opt/homebrew/bin:$PATH bash test/language.test.sh`.

- [ ] **Step 5: Commit**
  `git add bin/steward test/principal-identity-verb.test.sh`
  `git commit -m "feat(registry): principal add writes and guards OIDC identities"`

---

### Task 3: `desk/bin/principal-for-login` takes a source

**Files:**
- Modify: `desk/bin/principal-for-login` (the whole argument handling, lines 1-40)
- Test: `test/desk-principal-lookup.test.sh` (create)

**Interfaces:**
- Consumes: `registry_principal_for_identity <source> <value>` from `lib/registry.sh`.
- Produces: `principal-for-login <login>` (one argument, unchanged: the tailnet source) and `principal-for-login <source> <value>` (two arguments). Exit codes pass through unchanged: 0 slug on stdout, 1 none, 64 wrong argument count or unknown source, 65 ambiguous, 78 the library was not found. `desk/serve.mjs` calls the one-argument form (desk/serve.mjs:389) and is NOT touched by this task.

- [ ] **Step 1: Write the failing test**

Create `test/desk-principal-lookup.test.sh`:

```bash
#!/bin/bash
# test/desk-principal-lookup.test.sh - the desk's bridge answers for BOTH
# entrances. The one-argument form is what the server calls today and must not
# move; the two-argument form is what the front will call.
set -u
here="$(CDPATH= cd -- "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
pass=0; fail=0
ok()  { pass=$((pass+1)); printf '  ok   %s\n' "$1"; }
bad() { fail=$((fail+1)); printf '  FAIL %s\n     %s\n' "$1" "${2:-}"; }
is()  { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "wanted '$3', got '$2'"; fi; }
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
ROOT="$T/estate"; mkdir -p "$ROOT/principals.d" "$ROOT/estate"
printf 'ESTATE_NAME="fixture"\n' > "$ROOT/estate/steward.conf"
export STEWARD_ESTATE_ROOT="$ROOT" STEWARD_CONFIG_FILE="$T/no-such-config"
B="$here/desk/bin/principal-for-login"
printf 'NAME="Alice"\nTAILSCALE_LOGIN="login-a@example.test"\nOIDC_LOGIN="issuer-a:SUB-1"\n' \
  > "$ROOT/principals.d/alice.conf"
echo "desk-principal-lookup"

out="$(bash "$B" login-a@example.test)"; rc=$?
is  "one argument still means the tailnet source" "$out" "alice"
is  "and exits 0" "$rc" "0"

out="$(bash "$B" tailscale login-a@example.test)"; rc=$?
is  "two arguments, tailscale" "$out" "alice"

out="$(bash "$B" oidc issuer-a:SUB-1)"; rc=$?
is  "two arguments, oidc" "$out" "alice"

bash "$B" oidc issuer-a:SUB-9 >/dev/null 2>&1; rc=$?
is  "an unknown identity is rc 1" "$rc" "1"
bash "$B" elsewhere x >/dev/null 2>&1; rc=$?
is  "an unknown source is rc 64" "$rc" "64"
bash "$B" >/dev/null 2>&1; rc=$?
is  "no argument is rc 64" "$rc" "64"
bash "$B" a b c >/dev/null 2>&1; rc=$?
is  "three arguments is rc 64" "$rc" "64"

printf 'NAME="Twin"\nOIDC_LOGIN="issuer-a:SUB-1"\n' > "$ROOT/principals.d/twin.conf"
bash "$B" oidc issuer-a:SUB-1 >/dev/null 2>&1; rc=$?
is  "an ambiguous identity is rc 65" "$rc" "65"

printf '\n  %d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
```

- [ ] **Step 2: Run test to verify it fails**
  Run: `bash test/desk-principal-lookup.test.sh`
  Expected: FAIL on `two arguments, tailscale` and the two-argument oidc cases with rc 64 (`usage: principal-for-login <login>`).

- [ ] **Step 3: Write minimal implementation**

In `desk/bin/principal-for-login`, replace the header's exit-code block and the last two lines. The exit-code comment becomes:

```bash
# ARGUMENTS. Two forms, because the desk has two entrances and one identity
# function:
#   principal-for-login <login>            the tailnet source (what the
#                                          tailnet listener calls today)
#   principal-for-login <source> <value>   source in tailscale|oidc
#
# EXIT CODES ARE THE LIBRARY'S, PASSED THROUGH UNCHANGED, because the caller
# treats every non-zero the same way - no desk - and must never be tempted to
# recover from one of them:
#   0   the slug on stdout: exactly one row carries this identity
#   1   no row carries it
#   65  more than one row carries it - the library refuses to pick, and so do we
#   78  the estate does not load
#   64  this script was called with the wrong number of arguments, or with a
#       source the library does not know
```

and the tail becomes:

```bash
case $# in
  1) registry_principal_for_identity tailscale "$1" ;;
  2) registry_principal_for_identity "$1" "$2" ;;
  *) echo "usage: principal-for-login <login> | principal-for-login <source> <value>" >&2; exit 64 ;;
esac
```

- [ ] **Step 4: Run test to verify it passes**
  Run: `bash test/desk-principal-lookup.test.sh`, then `bash test/desk-serve.test.sh` and `bash test/deploy-manifest.test.sh` (the bridge is a manifest target), then `git add test/desk-principal-lookup.test.sh` and `PATH=/opt/homebrew/opt/node@22/bin:/opt/homebrew/bin:$PATH bash test/language.test.sh`.

- [ ] **Step 5: Commit**
  `git add desk/bin/principal-for-login test/desk-principal-lookup.test.sh`
  `git commit -m "feat(desk): the identity bridge answers for both entrances"`

---

### Task 4: `registry_row_replace`, a SHA-256 helper, and the `DESK_ORIGIN` estate value

**Files:**
- Modify: `lib/registry.sh` - after `registry_row_write` (insert at line 1530), after `registry_entity_write` (add `registry_entity_replace`), the estate-value reader `_registry_estate_value` (lines 1873-1903) and the accessor block near line 2024
- Test: `test/registry-row-replace.test.sh` (create)

**Interfaces:**
- Consumes: `_registry_restore_exit_trap`, `_registry_stat_id`, `registry_entity_dir`, `registry_entity_load`, `_registry_estate_value`.
- Produces:
  - `registry_row_replace <dir> <slug> <content> <validate_fn> <readback_fn> <label>` - the in-place twin of `registry_row_write`. Same lock, stage, validate, chmod, readback. rc 64 invalid slug, rc 65 the destination does NOT exist (there is nothing to replace) or is a symlink, rc 75 lock held, rc 78 the register directory is unreadable, rc 70 any write/validate/publish/readback failure. On a readback failure the PREVIOUS content is restored and the function refuses.
  - `registry_entity_replace <slug> <content> <validate_fn>` - the entity-register wrapper over it.
  - `_registry_sha256` - reads stdin, prints the lowercase hex digest on stdout. rc 78 when neither `sha256sum` nor `shasum` is on PATH.
  - `registry_desk_origin` - the estate's `DESK_ORIGIN` value (form `^https?://[A-Za-z0-9.-]+(:[0-9]+)?$`), or rc 78 with the standard "an estate's names are never guessed" refusal.

- [ ] **Step 1: Write the failing test**

Create `test/registry-row-replace.test.sh`:

```bash
#!/bin/bash
# test/registry-row-replace.test.sh - the in-place twin of the one writer core.
# A row's STATE changes (an invitation is revoked, a team gains a member) and
# registry_row_write refuses a destination that exists, by design. This is the
# other half: same lock, same validation, same readback - and a readback that
# fails puts the PREVIOUS bytes back, because a half-replaced row is worse
# than a refused one.
set -u
here="$(CDPATH= cd -- "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
pass=0; fail=0
ok()  { pass=$((pass+1)); printf '  ok   %s\n' "$1"; }
bad() { fail=$((fail+1)); printf '  FAIL %s\n     %s\n' "$1" "${2:-}"; }
is()  { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "wanted '$3', got '$2'"; fi; }
has() { case "$2" in *"$3"*) ok "$1" ;; *) bad "$1" "missing '$3' in: $2" ;; esac; }
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
ROOT="$T/estate"; mkdir -p "$ROOT/entities.d" "$ROOT/estate"
printf 'ESTATE_NAME="fixture"\nDESK_ORIGIN="https://desk.example.test"\n' > "$ROOT/estate/steward.conf"
export STEWARD_ESTATE_ROOT="$ROOT" STEWARD_CONFIG_FILE="$T/no-such-config"
. "$here/lib/registry.sh"
echo "registry-row-replace"

printf 'NAME="Acme"\nMEMBERS="alice"\n' > "$ROOT/entities.d/acme.conf"
always_ok() { return 0; }
always_bad() { return 70; }

registry_entity_replace acme 'NAME="Acme"
MEMBERS="alice bo"
' always_ok; rc=$?
is  "a replace succeeds" "$rc" "0"
has "and the new bytes are on disk" "$(cat "$ROOT/entities.d/acme.conf")" 'MEMBERS="alice bo"'
registry_entity_load acme
is  "and the loader sees them" "$ENTITY_MEMBERS" "alice bo"
is  "the mode is 600" \
    "$(stat -c %a "$ROOT/entities.d/acme.conf" 2>/dev/null || stat -f %Lp "$ROOT/entities.d/acme.conf")" "600"

registry_entity_replace nosuch 'NAME="X"
MEMBERS="alice"
' always_ok 2>"$T/err"; rc=$?
is  "replacing a row that does not exist is rc 65" "$rc" "65"
has "and says so" "$(cat "$T/err")" "no such"

registry_entity_replace acme 'NAME="Acme"
MEMBERS="alice bo cy"
' always_bad 2>/dev/null; rc=$?
is  "a refusing validator is rc 70" "$rc" "70"
has "and the previous bytes survive" "$(cat "$ROOT/entities.d/acme.conf")" 'MEMBERS="alice bo"'

# A row the register's OWN loader cannot read must not be published: the
# readback runs under the lock, and the previous content comes back.
registry_entity_replace acme 'MEMBERS="alice bo cy"
' always_ok 2>/dev/null; rc=$?
is  "a row that does not load back is refused" "$rc" "70"
has "and the previous bytes are restored" "$(cat "$ROOT/entities.d/acme.conf")" 'NAME="Acme"'
has "with the previous members" "$(cat "$ROOT/entities.d/acme.conf")" 'MEMBERS="alice bo"'

ln -s "$ROOT/entities.d/acme.conf" "$ROOT/entities.d/link.conf"
registry_entity_replace link 'NAME="X"
MEMBERS="alice"
' always_ok 2>"$T/err"; rc=$?
is  "a symlink destination is refused" "$rc" "65"
has "and names the reason" "$(cat "$T/err")" "symlink"
rm -f "$ROOT/entities.d/link.conf"

registry_entity_replace 'BAD/SLUG' 'NAME="X"
' always_ok 2>/dev/null; rc=$?
is  "an invalid slug is rc 64" "$rc" "64"

# The lock is released on every path - a second replace in the same shell must
# not meet a stale lock.
registry_entity_replace acme 'NAME="Acme"
MEMBERS="alice"
' always_ok; rc=$?
is  "a later replace still gets the lock" "$rc" "0"

echo "== the digest helper =="
is  "sha256 of the empty string" "$(printf '' | _registry_sha256)" \
    "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
is  "sha256 of a known string" "$(printf 'abc' | _registry_sha256)" \
    "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"

echo "== the estate names the desk's origin =="
is  "DESK_ORIGIN resolves" "$(registry_desk_origin)" "https://desk.example.test"
printf 'ESTATE_NAME="fixture"\n' > "$ROOT/estate/steward.conf"
registry_desk_origin >/dev/null 2>"$T/err"; rc=$?
is  "a missing DESK_ORIGIN refuses with 78" "$rc" "78"
has "and names the key" "$(cat "$T/err")" "DESK_ORIGIN"

printf '\n  %d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
```

- [ ] **Step 2: Run test to verify it fails**
  Run: `bash test/registry-row-replace.test.sh`
  Expected: FAIL with `registry_entity_replace: command not found`, `_registry_sha256: command not found` and `registry_desk_origin: command not found`.

- [ ] **Step 3: Write minimal implementation**

In `lib/registry.sh`, insert after `registry_row_write` ends (line 1529):

```bash
# registry_row_replace <dir> <slug> <content> <validate_fn> <readback_fn> <label>
# - the IN-PLACE twin of registry_row_write, for the rows whose STATE changes
# after they are written: an invitation moving from open to revoked, an
# entity's MEMBERS gaining a person.
#
# WHY A SEPARATE FUNCTION AND NOT A FLAG ON THE WRITER. The writer's step 2 and
# step 6 both refuse a destination that exists, and they refuse it twice on
# purpose - "this row is new" is the one guarantee every caller of that
# function has. A flag would put "create" and "overwrite" one typo apart in
# every call site in the product. Two names, two intentions.
#
# THE TRANSACTION IS THE SAME, step for step: lock the DIRECTORY, recheck under
# it, stage under a non-.conf name at umask 077, run the caller's validate_fn
# on the STAGED bytes, chmod 0600, publish, read back through the register's
# OWN loader under the same lock, release.
#
# TWO DIFFERENCES, AND ONLY TWO:
#   * the recheck INVERTS - the destination must EXIST and be a regular file.
#     A missing row is rc 65 (there is nothing to replace, and creating one
#     here would let a typo mint a row through the update path); a symlink is
#     rc 65 too, because a link's target can be swapped between the check and
#     the write.
#   * the publish is `mv`, which is atomic over an existing name. Before it,
#     the CURRENT bytes are copied to a second stage - so a readback failure
#     can put them back. registry_row_write can simply delete what it
#     published; this function cannot, because deleting would take the
#     previous row with it.
registry_row_replace() {
  local dir="$1" slug="$2" content="$3" validate_fn="$4" readback_fn="$5" label="$6"
  if ! [[ "$slug" =~ ^[a-z0-9][a-z0-9-]*$ ]]; then
    echo "registry: refusing - invalid slug '$slug' (allowed: a-z0-9-, must start a-z0-9)" >&2
    return 64
  fi
  if [ ! -d "$dir" ]; then
    echo "registry: REFUSING - the $label register is not readable: $dir" >&2
    return 78
  fi
  local final="$dir/$slug.conf"
  local lock="$dir/.write.lock"
  local tries=0
  while ! mkdir "$lock" 2>/dev/null; do
    if [ ! -d "$lock" ] && [ ! -w "$dir" ]; then
      echo "registry: could not create the write lock - the $label register is not writable: $lock" >&2
      return 78
    fi
    tries=$((tries+1))
    if [ "$tries" -ge 20 ]; then
      echo "registry: another write holds the registry lock, refusing: $lock" >&2
      echo "registry: if no write is in progress, remove it with: rmdir $lock" >&2
      return 75
    fi
    sleep 0.1
  done
  local _prev_trap; _prev_trap="$(trap -p EXIT)"
  if [ -z "$_prev_trap" ]; then
    trap 'rmdir "'"$lock"'" 2>/dev/null' EXIT
  fi

  # 2. RECHECK, INVERTED, under the lock.
  if [ -L "$final" ]; then
    echo "registry: refusing - the $label row is a symlink: $final" >&2
    rmdir "$lock" 2>/dev/null; _registry_restore_exit_trap "$_prev_trap"
    return 65
  fi
  if [ ! -f "$final" ]; then
    echo "registry: refusing - no such $label row to replace: $final" >&2
    rmdir "$lock" 2>/dev/null; _registry_restore_exit_trap "$_prev_trap"
    return 65
  fi

  # 3. STAGE the new bytes, and BACK UP the old ones.
  local _prev_umask; _prev_umask="$(umask)"
  umask 077
  local stage backup
  stage="$(mktemp "$dir/.stage.XXXXXX" 2>/dev/null)"
  backup="$(mktemp "$dir/.backup.XXXXXX" 2>/dev/null)"
  umask "$_prev_umask"
  if [ -z "$stage" ] || [ -z "$backup" ]; then
    echo "registry: could not create a staging file in $dir" >&2
    rm -f "$stage" "$backup"; rmdir "$lock" 2>/dev/null; _registry_restore_exit_trap "$_prev_trap"
    return 70
  fi
  if ! cat "$final" > "$backup"; then
    echo "registry: could not back up the current $label row: $final" >&2
    rm -f "$stage" "$backup"; rmdir "$lock" 2>/dev/null; _registry_restore_exit_trap "$_prev_trap"
    return 70
  fi
  if ! printf '%s' "$content" > "$stage"; then
    echo "registry: could not write the staged $label file: $stage" >&2
    rm -f "$stage" "$backup"; rmdir "$lock" 2>/dev/null; _registry_restore_exit_trap "$_prev_trap"
    return 70
  fi

  # 4. VALIDATE THE STAGED BYTES.
  if ! "$validate_fn" "$stage"; then
    rm -f "$stage" "$backup"; rmdir "$lock" 2>/dev/null; _registry_restore_exit_trap "$_prev_trap"
    return 70
  fi

  # 5. chmod, hard refuse on failure.
  if ! chmod 0600 "$stage"; then
    echo "registry: could not set the mode of the staged $label file: $stage" >&2
    rm -f "$stage" "$backup"; rmdir "$lock" 2>/dev/null; _registry_restore_exit_trap "$_prev_trap"
    return 70
  fi

  # 6. PUBLISH by rename over the existing name.
  if ! mv "$stage" "$final"; then
    echo "registry: could not publish the staged $label file over $final" >&2
    rm -f "$stage" "$backup"; rmdir "$lock" 2>/dev/null; _registry_restore_exit_trap "$_prev_trap"
    return 70
  fi

  # 7. CANONICAL READBACK, same lock, the register's own loader. On failure the
  # backup goes back - the caller asked for a change, not for a loss.
  if ! ( "$readback_fn" "$slug" >/dev/null 2>&1 ); then
    if ! mv "$backup" "$final"; then
      echo "registry: REFUSING and COULD NOT RESTORE - the previous $label row is at $backup" >&2
      rmdir "$lock" 2>/dev/null; _registry_restore_exit_trap "$_prev_trap"
      return 70
    fi
    chmod 0600 "$final" 2>/dev/null
    echo "registry: replaced $final but it does not load back through the registry - the previous row was restored, refusing" >&2
    rmdir "$lock" 2>/dev/null; _registry_restore_exit_trap "$_prev_trap"
    return 70
  fi
  rm -f "$backup"

  # 8. RELEASE.
  rmdir "$lock" 2>/dev/null
  _registry_restore_exit_trap "$_prev_trap"
  return 0
}

# _registry_sha256 - the digest of STDIN, lowercase hex, on stdout.
#
# TWO TOOLS, IN ORDER, because neither exists on both platforms this library
# runs on: sha256sum (Linux) and shasum -a 256 (macOS). Both print
# "<hex>  <name>", so the first space-delimited field is the digest. Neither
# present is a REFUSAL, never an empty string: an empty digest compared against
# a stored one would make every token match nothing, which reads as "wrong
# token" instead of "this machine cannot check tokens".
_registry_sha256() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum | cut -d' ' -f1
  elif command -v shasum >/dev/null 2>&1; then
    shasum -a 256 | cut -d' ' -f1
  else
    echo "registry: REFUSING - no sha256 tool on PATH (looked for sha256sum and shasum)" >&2
    return 78
  fi
}
```

Insert after `registry_entity_write` (it ends around line 1545):

```bash
# registry_entity_replace <slug> <content> <validate_fn> - THIN WRAPPER over
# registry_row_replace, the in-place twin of registry_entity_write: same
# directory (honoring STEWARD_ENTITY_DIR), same loader, same "entity" label.
# It exists because MEMBERS grows - a person joins a team long after the row
# was written.
registry_entity_replace() {
  local slug="$1" content="$2" validate_fn="$3"
  local dir; dir="$(registry_entity_dir)" || return 78
  registry_row_replace "$dir" "$slug" "$content" "$validate_fn" registry_entity_load "entity"
}
```

In `_registry_estate_value`, add `DESK_ORIGIN=""` to the local reset list (line 1873-1876) and a branch to the `case` (after the `PAUSED_DIR_NAME` branch, line 1896):

```bash
    DESK_ORIGIN)          _varde="$DESK_ORIGIN" ;;
```

And beside the other accessors (after line 2025):

```bash
# DESK_ORIGIN - the browser-facing origin of this estate's desk, scheme and
# authority only. It is what an invitation link is built from, and it is the
# estate's to state: another installation's desk answers on another name, and
# a product that guessed one would print a link that reaches somebody else's
# machine. A trailing slash is refused rather than trimmed - a value that is
# quietly repaired is a value nobody fixes.
registry_desk_origin()          { _registry_estate_value DESK_ORIGIN          '^https?://[A-Za-z0-9.-]+(:[0-9]+)?$'; }
```

- [ ] **Step 4: Run test to verify it passes**
  Run: `bash test/registry-row-replace.test.sh`, then `bash test/registry-org-verbs.test.sh` and `bash test/registry-account.test.sh` (the writer core is shared), then `git add test/registry-row-replace.test.sh` and `PATH=/opt/homebrew/opt/node@22/bin:/opt/homebrew/bin:$PATH bash test/language.test.sh`.

- [ ] **Step 5: Commit**
  `git add lib/registry.sh test/registry-row-replace.test.sh`
  `git commit -m "feat(registry): in-place row replace, a sha256 helper and DESK_ORIGIN"`

---

### Task 5: the `invites.d` category - loader, validator, writer, token

**Files:**
- Modify: `lib/registry.sh` - a new block after the logins block (append after `registry_login_config_dir`, near line 3960)
- Test: `test/invite-registry.test.sh` (create)

**Interfaces:**
- Consumes: `_registry_estate_root`, `registry_row_write`, `registry_row_replace`, `_registry_sha256`, `_registry_login_dir_state` pattern (copied, not called), `_REGISTRY_LOGIN_PROVIDERS` (lib/registry.sh:3513), `registry_printable`.
- Produces:
  - `registry_invite_dir` - `$STEWARD_INVITE_DIR` or `<estate root>/invites.d`.
  - `registry_invite_load <id>` - a LINE PARSER, never a `source`. Sets `INVITE_ID INVITE_NAME INVITE_PRINCIPAL INVITE_ENTITY INVITE_HOST INVITE_RUNTIME INVITE_PROVIDER INVITE_TOKEN_SHA256 INVITE_ISSUED_BY INVITE_ISSUED_AT INVITE_EXPIRES_AT INVITE_STATE INVITE_REDEEMED_LOGIN INVITE_REDEEMED_AT INVITE_EFFECTIVE_STATE`. rc 0, rc 1 (no such row, or content refused), rc 78 (the register or the file's own state refuses). `INVITE_EFFECTIVE_STATE` is `expired` when `STATE=open` and `EXPIRES_AT` is in the past, otherwise it equals `STATE` - computed at read time, never written.
  - `registry_invite_list` - one id per line, sorted; rc 78 when the register directory does not exist.
  - `registry_invite_write <id> <content> <validate_fn>` / `registry_invite_replace <id> <content> <validate_fn>`.
  - `registry_invite_mint_id` - `inv-` plus 8 hex, unused in the register; rc 70 after five collisions.
  - `registry_invite_mint_token` - 32 bytes of `/dev/urandom` as base64url with no padding, on stdout; rc 70 when the read is short.
  - `registry_invite_for_digest <hex>` - the id of the row whose `TOKEN_SHA256` equals the digest. rc 0 one, rc 1 none, rc 65 more than one.
  - `registry_invite_open_for_principal <slug>` - the id of an invite for that principal whose effective state is `open`. rc 0 one, rc 1 none, rc 65 more than one.

- [ ] **Step 1: Write the failing test**

Create `test/invite-registry.test.sh`:

```bash
#!/bin/bash
# test/invite-registry.test.sh - invites.d: the operator's word, recorded
# before the person exists. The row holds a DIGEST, never a token, so a
# readable register is not an open door - and expiry is computed on every read
# rather than written, so a row nobody looked at is not silently still valid.
set -u
here="$(CDPATH= cd -- "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
pass=0; fail=0
ok()  { pass=$((pass+1)); printf '  ok   %s\n' "$1"; }
bad() { fail=$((fail+1)); printf '  FAIL %s\n     %s\n' "$1" "${2:-}"; }
is()  { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "wanted '$3', got '$2'"; fi; }
has() { case "$2" in *"$3"*) ok "$1" ;; *) bad "$1" "missing '$3' in: $2" ;; esac; }
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
ROOT="$T/estate"; mkdir -p "$ROOT/invites.d" "$ROOT/estate"
printf 'ESTATE_NAME="fixture"\n' > "$ROOT/estate/steward.conf"
export STEWARD_ESTATE_ROOT="$ROOT" STEWARD_CONFIG_FILE="$T/no-such-config"
. "$here/lib/registry.sh"
echo "invite-registry"

NOW="$(date -u +%s)"
FUTURE=$((NOW + 86400))
PAST=$((NOW - 86400))

write_row() { # <id> <state> <expires> <digest>
  local id="$1" state="$2" exp="$3" digest="$4"
  {
    printf 'NAME="Alice Example"\n'
    printf 'PRINCIPAL="alice"\n'
    printf 'ENTITY="acme"\n'
    printf 'HOST="host-a"\n'
    printf 'RUNTIME="claude-code"\n'
    printf 'PROVIDER="claude-max"\n'
    printf 'TOKEN_SHA256="%s"\n' "$digest"
    printf 'ISSUED_BY="operator"\n'
    printf 'ISSUED_AT="%s"\n' "$NOW"
    printf 'EXPIRES_AT="%s"\n' "$exp"
    printf 'STATE="%s"\n' "$state"
  } > "$ROOT/invites.d/$id.conf"
  chmod 600 "$ROOT/invites.d/$id.conf"
}
D1="$(printf 'token-one' | _registry_sha256)"
D2="$(printf 'token-two' | _registry_sha256)"
write_row inv-0000000a open "$FUTURE" "$D1"
write_row inv-0000000b open "$PAST"   "$D2"

registry_invite_load inv-0000000a; rc=$?
is  "a valid row loads" "$rc" "0"
is  "and exposes the principal" "$INVITE_PRINCIPAL" "alice"
is  "and the entity" "$INVITE_ENTITY" "acme"
is  "and the host" "$INVITE_HOST" "host-a"
is  "and the runtime" "$INVITE_RUNTIME" "claude-code"
is  "and the digest" "$INVITE_TOKEN_SHA256" "$D1"
is  "and the state" "$INVITE_STATE" "open"
is  "and the effective state" "$INVITE_EFFECTIVE_STATE" "open"
is  "and no redemption yet" "$INVITE_REDEEMED_LOGIN" ""

registry_invite_load inv-0000000b
is  "a past expiry reads as expired" "$INVITE_EFFECTIVE_STATE" "expired"
is  "without rewriting the stored state" "$INVITE_STATE" "open"
has "and the row on disk still says open" "$(cat "$ROOT/invites.d/inv-0000000b.conf")" 'STATE="open"'

registry_invite_load inv-nosuch 2>"$T/err"; rc=$?
is  "a missing row is rc 1" "$rc" "1"
is  "a refused load leaves nothing behind" "$INVITE_PRINCIPAL" ""

printf 'NAME="X"\nPRINCIPAL="alice"\n' > "$ROOT/invites.d/inv-0000000c.conf"
chmod 600 "$ROOT/invites.d/inv-0000000c.conf"
registry_invite_load inv-0000000c 2>"$T/err"; rc=$?
is  "a row missing required keys is rc 1" "$rc" "1"
has "and names a missing key" "$(cat "$T/err")" "missing required key"
rm -f "$ROOT/invites.d/inv-0000000c.conf"

printf 'PRINCIPAL="alice"\nSTATE="open"\nWHATEVER="x"\n' > "$ROOT/invites.d/inv-0000000d.conf"
chmod 600 "$ROOT/invites.d/inv-0000000d.conf"
registry_invite_load inv-0000000d 2>"$T/err"; rc=$?
is  "an unknown key is rc 1" "$rc" "1"
has "and names it" "$(cat "$T/err")" "WHATEVER"
rm -f "$ROOT/invites.d/inv-0000000d.conf"

write_row inv-0000000e nonsense "$FUTURE" "$D1"
registry_invite_load inv-0000000e 2>"$T/err"; rc=$?
is  "an unknown STATE is rc 1" "$rc" "1"
has "and names the vocabulary" "$(cat "$T/err")" "open"
rm -f "$ROOT/invites.d/inv-0000000e.conf"

# THE ROW IS NEVER SOURCED. A command substitution in a value must land in the
# value, not in a shell.
rm -f "$T/DETONATED"
printf 'NAME="X"\nPRINCIPAL="alice"\nENTITY="acme"\nHOST="host-a"\nRUNTIME="claude-code"\nPROVIDER="claude-max"\nTOKEN_SHA256="%s"\nISSUED_BY="operator"\nISSUED_AT="%s"\nEXPIRES_AT="%s"\nSTATE="open"\n' \
  '$(touch '"$T"'/DETONATED)' "$NOW" "$FUTURE" > "$ROOT/invites.d/inv-0000000f.conf"
chmod 600 "$ROOT/invites.d/inv-0000000f.conf"
registry_invite_load inv-0000000f >/dev/null 2>&1; rc=$?
is  "a substitution in a value is refused" "$rc" "1"
if [ -e "$T/DETONATED" ]; then bad "the payload must never run" "found $T/DETONATED"; else ok "the payload never ran"; fi
rm -f "$ROOT/invites.d/inv-0000000f.conf"

echo "== lookups =="
is  "the digest lookup finds the row" "$(registry_invite_for_digest "$D1")" "inv-0000000a"
registry_invite_for_digest "$(printf 'nothing' | _registry_sha256)" >/dev/null 2>&1; rc=$?
is  "an unknown digest is rc 1" "$rc" "1"
is  "the open-invite lookup finds the row" "$(registry_invite_open_for_principal alice)" "inv-0000000a"
registry_invite_open_for_principal nobody >/dev/null 2>&1; rc=$?
is  "no open invite is rc 1" "$rc" "1"
is  "the listing names both rows" "$(registry_invite_list | tr '\n' ' ')" "inv-0000000a inv-0000000b "

echo "== minting =="
tok="$(registry_invite_mint_token)"; rc=$?
is  "minting a token succeeds" "$rc" "0"
case "$tok" in
  *[!A-Za-z0-9_-]*) bad "a token is base64url only" "got '$tok'" ;;
  *) ok "a token is base64url only" ;;
esac
if [ "${#tok}" -ge 43 ]; then ok "a token is at least 43 characters (32 bytes)"; else bad "a token is at least 43 characters" "got ${#tok}"; fi
tok2="$(registry_invite_mint_token)"
if [ "$tok" != "$tok2" ]; then ok "two tokens differ"; else bad "two tokens differ" "both '$tok'"; fi
id="$(registry_invite_mint_id)"
case "$id" in
  inv-[0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f]) ok "a minted id is inv- plus 8 hex" ;;
  *) bad "a minted id is inv- plus 8 hex" "got '$id'" ;;
esac

echo "== the writer and the in-place replace =="
_invite_ok() { return 0; }
content="$(cat "$ROOT/invites.d/inv-0000000a.conf")"
registry_invite_write inv-00000010 "$content
" _invite_ok; rc=$?
is  "the writer publishes a row" "$rc" "0"
registry_invite_load inv-00000010
is  "and it loads back" "$INVITE_PRINCIPAL" "alice"
registry_invite_write inv-00000010 "$content
" _invite_ok 2>/dev/null; rc=$?
is  "writing over an existing row is rc 65" "$rc" "65"
registry_invite_replace inv-00000010 "$(printf '%s\n' "$content" | sed 's/^STATE=.*/STATE="revoked"/')
" _invite_ok; rc=$?
is  "the replace succeeds" "$rc" "0"
registry_invite_load inv-00000010
is  "and the state moved" "$INVITE_EFFECTIVE_STATE" "revoked"

printf '\n  %d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
```

- [ ] **Step 2: Run test to verify it fails**
  Run: `bash test/invite-registry.test.sh`
  Expected: FAIL with `registry_invite_load: command not found` on the first assertion and `command not found` for every other new function.

- [ ] **Step 3: Write minimal implementation**

Append to `lib/registry.sh`, after the logins block:

```bash
# -- INVITES: THE OPERATOR'S WORD, RECORDED BEFORE THE PERSON EXISTS --------
#
# Registration is CLOSED: the invitation is the only door. A row here says a
# named human may become a principal with an account on one host, and carries
# the DIGEST of the one-time link token - never the token. A readable register
# is therefore not an open door, which matters because this register is in git
# and on every host the deploy reaches.
#
# THIS REGISTER IS NEVER SOURCED, for the same reason logins.d is not: the row
# is a security artifact, and `source` on it means any line can run as the
# steward account. The parser below is the login reader's, adapted - anchored
# KEY="VALUE" per line, an allowlist of keys, no substitutions in values.
_REGISTRY_INVITE_REQUIRED="NAME PRINCIPAL ENTITY HOST RUNTIME PROVIDER TOKEN_SHA256 ISSUED_BY ISSUED_AT EXPIRES_AT STATE"
_REGISTRY_INVITE_OPTIONAL="REDEEMED_LOGIN REDEEMED_AT"
# THE STORED VOCABULARY IS THREE, NOT FOUR. `expired` is a MEASUREMENT taken on
# every read (EXPIRES_AT against the clock), never a written state: a row whose
# validity ran out while nobody looked at it must read as expired the first
# time anybody does, and a state that needs a writer to become true is a state
# that is wrong until somebody runs something.
_REGISTRY_INVITE_STATES="open redeemed revoked"

registry_invite_dir() {
  if [ -n "${STEWARD_INVITE_DIR:-}" ]; then
    printf '%s\n' "$STEWARD_INVITE_DIR"
  else
    printf '%s\n' "$(_registry_estate_root)/invites.d"
  fi
}

# registry_invite_id_valid <id> - "inv-" and exactly eight hex digits. A random
# slug, never derived from the person: an id that encoded a name would leak the
# name into every log line that carries the id.
registry_invite_id_valid() {
  case "${1:-}" in inv-*) : ;; *) return 1 ;; esac
  case "${1#inv-}" in *[!0123456789abcdef]*|"") return 1 ;; esac
  [ "${#1}" -eq 12 ]
}

registry_invite_list() {
  local dir; dir="$(registry_invite_dir)"
  if [ ! -d "$dir" ]; then
    echo "registry: REFUSING to list invites - the invite register does not exist: $dir" >&2
    return 78
  fi
  local f
  for f in "$dir"/*.conf; do
    [ -e "$f" ] || [ -L "$f" ] || continue
    basename "$f" .conf
  done | sort
}

registry_invite_load() {
  INVITE_ID=""; INVITE_NAME=""; INVITE_PRINCIPAL=""; INVITE_ENTITY=""; INVITE_HOST=""
  INVITE_RUNTIME=""; INVITE_PROVIDER=""; INVITE_TOKEN_SHA256=""; INVITE_ISSUED_BY=""
  INVITE_ISSUED_AT=""; INVITE_EXPIRES_AT=""; INVITE_STATE=""
  INVITE_REDEEMED_LOGIN=""; INVITE_REDEEMED_AT=""; INVITE_EFFECTIVE_STATE=""
  local id="${1:-}" dir f
  if ! registry_invite_id_valid "$id"; then
    echo "registry: invalid invite id '$(registry_printable "$id")' (expected inv- and eight hex digits)" >&2
    return 1
  fi
  dir="$(registry_invite_dir)" || return 78
  if [ -L "$dir" ]; then
    echo "registry: the invite register is a symlink, refusing: $dir" >&2
    return 78
  fi
  f="$dir/$id.conf"
  if [ -L "$f" ]; then
    echo "registry: invite '$id' is a symlink, refusing: $f" >&2
    return 78
  fi
  if [ ! -f "$f" ]; then
    echo "registry: no such invite: $id" >&2
    return 1
  fi
  local mode; mode="$(_registry_mode_of "$f")" || {
    echo "registry: cannot read the mode of invite '$id': $f" >&2; return 78; }
  if _registry_group_or_other_writable "$mode"; then
    echo "registry: invite '$id' is group- or other-writable (mode $mode), refusing: $f" >&2
    return 78
  fi

  local lineno=0 line key value seen="" k
  local v_NAME="" v_PRINCIPAL="" v_ENTITY="" v_HOST="" v_RUNTIME="" v_PROVIDER=""
  local v_TOKEN_SHA256="" v_ISSUED_BY="" v_ISSUED_AT="" v_EXPIRES_AT="" v_STATE=""
  local v_REDEEMED_LOGIN="" v_REDEEMED_AT=""
  local allowed=" $_REGISTRY_INVITE_REQUIRED $_REGISTRY_INVITE_OPTIONAL "
  while IFS= read -r line || [ -n "$line" ]; do
    lineno=$((lineno+1))
    case "$line" in
      *[[:cntrl:]]*)
        echo "registry: $f:$lineno: control character in the line, refusing" >&2
        return 1 ;;
    esac
    case "$line" in ''|'#'*) continue ;; esac
    if ! [[ "$line" =~ ^([A-Z_]+)=\"([^\"]*)\"$ ]]; then
      echo "registry: $f:$lineno: each setting must be written exactly KEY=\"VALUE\" on its own line" >&2
      return 1
    fi
    key="${BASH_REMATCH[1]}"; value="${BASH_REMATCH[2]}"
    case "$allowed" in
      *" $key "*) ;;
      *) echo "registry: $f:$lineno: unknown key '$key' (allowed:$allowed)" >&2
         return 1 ;;
    esac
    case " $seen " in
      *" $key "*) echo "registry: $f:$lineno: duplicate key '$key'" >&2; return 1 ;;
    esac
    seen="$seen $key"
    case "$value" in
      *'$'*|*'`'*|*'\'*)
        echo "registry: $f:$lineno: '$key' contains a substitution or escape character, refusing" >&2
        return 1 ;;
    esac
    eval "v_$key=\$value"
  done < "$f"

  for k in $_REGISTRY_INVITE_REQUIRED; do
    case " $seen " in
      *" $k "*) ;;
      *) echo "registry: $f: missing required key '$k'" >&2; return 1 ;;
    esac
  done

  # NAME is the display name of a human: free text, non-empty.
  if [ -z "$v_NAME" ]; then
    echo "registry: $f: NAME must not be empty (the invited person's display name)" >&2
    return 1
  fi
  # PRINCIPAL is the slug redemption will MINT - the same form as an entity's
  # MEMBERS entry and a session's OWNER, because the identity gate compares
  # them directly.
  if ! [[ "$v_PRINCIPAL" =~ ^[a-z][a-z0-9-]*$ ]]; then
    echo "registry: $f: invalid PRINCIPAL '$(registry_printable "$v_PRINCIPAL")' (a-z, then a-z 0-9 and hyphen)" >&2
    return 1
  fi
  local nm
  for nm in ENTITY HOST ISSUED_BY; do
    eval "value=\$v_$nm"
    if ! [[ "$value" =~ ^[a-z0-9][a-z0-9-]*$ ]]; then
      echo "registry: $f: invalid $nm '$(registry_printable "$value")' (a-z 0-9 and hyphen)" >&2
      return 1
    fi
  done
  # THE RUNTIME VOCABULARY IS registry_load's OWN (lib/registry.sh, the session
  # reader): an invitation that names a runtime the session register refuses
  # would be an invitation nobody can redeem.
  case "$v_RUNTIME" in
    claude-code|opencode|codex) ;;
    *) echo "registry: $f: invalid RUNTIME '$(registry_printable "$v_RUNTIME")' (one of: claude-code opencode codex)" >&2
       return 1 ;;
  esac
  # THE PROVIDER VOCABULARY IS THE LOGIN REGISTER'S, for the same reason:
  # redemption writes a logins.d row carrying this value.
  case " $_REGISTRY_LOGIN_PROVIDERS " in
    *" $v_PROVIDER "*) ;;
    *) echo "registry: $f: invalid PROVIDER '$(registry_printable "$v_PROVIDER")' (one of: $_REGISTRY_LOGIN_PROVIDERS)" >&2
       return 1 ;;
  esac
  if ! [[ "$v_TOKEN_SHA256" =~ ^[0-9a-f]{64}$ ]]; then
    echo "registry: $f: TOKEN_SHA256 must be 64 lowercase hex digits" >&2
    return 1
  fi
  for nm in ISSUED_AT EXPIRES_AT; do
    eval "value=\$v_$nm"
    if ! [[ "$value" =~ ^[0-9]+$ ]]; then
      echo "registry: $f: $nm must be epoch seconds, got '$(registry_printable "$value")'" >&2
      return 1
    fi
  done
  case " $_REGISTRY_INVITE_STATES " in
    *" $v_STATE "*) ;;
    *) echo "registry: $f: invalid STATE '$(registry_printable "$v_STATE")' (one of: $_REGISTRY_INVITE_STATES)" >&2
       return 1 ;;
  esac
  if [ -n "$v_REDEEMED_AT" ] && ! [[ "$v_REDEEMED_AT" =~ ^[0-9]+$ ]]; then
    echo "registry: $f: REDEEMED_AT must be epoch seconds, got '$(registry_printable "$v_REDEEMED_AT")'" >&2
    return 1
  fi

  INVITE_ID="$id"; INVITE_NAME="$v_NAME"; INVITE_PRINCIPAL="$v_PRINCIPAL"
  INVITE_ENTITY="$v_ENTITY"; INVITE_HOST="$v_HOST"; INVITE_RUNTIME="$v_RUNTIME"
  INVITE_PROVIDER="$v_PROVIDER"; INVITE_TOKEN_SHA256="$v_TOKEN_SHA256"
  INVITE_ISSUED_BY="$v_ISSUED_BY"; INVITE_ISSUED_AT="$v_ISSUED_AT"
  INVITE_EXPIRES_AT="$v_EXPIRES_AT"; INVITE_STATE="$v_STATE"
  INVITE_REDEEMED_LOGIN="$v_REDEEMED_LOGIN"; INVITE_REDEEMED_AT="$v_REDEEMED_AT"
  # EXPIRY IS MEASURED HERE AND WRITTEN NOWHERE.
  INVITE_EFFECTIVE_STATE="$v_STATE"
  if [ "$v_STATE" = "open" ] && [ "$v_EXPIRES_AT" -le "$(date -u +%s)" ]; then
    INVITE_EFFECTIVE_STATE="expired"
  fi
  return 0
}

registry_invite_write() {
  local id="$1" content="$2" validate_fn="$3"
  local dir; dir="$(registry_invite_dir)" || return 78
  registry_row_write "$dir" "$id" "$content" "$validate_fn" registry_invite_load "invite"
}

registry_invite_replace() {
  local id="$1" content="$2" validate_fn="$3"
  local dir; dir="$(registry_invite_dir)" || return 78
  registry_row_replace "$dir" "$id" "$content" "$validate_fn" registry_invite_load "invite"
}

# registry_invite_mint_id - inv- and eight hex, unused in the register. Same
# shape as the session id minted by the hub's enroll, and minted the same way:
# read urandom, assert the shape, check the register, retry a bounded number of
# times, REFUSE rather than return something unchecked.
registry_invite_mint_id() {
  local dir cand tries=0
  dir="$(registry_invite_dir)" || return 78
  while [ "$tries" -lt 5 ]; do
    cand="inv-$(head -c 4 /dev/urandom 2>/dev/null | od -An -tx1 | tr -d ' \n')"
    if registry_invite_id_valid "$cand" && [ ! -e "$dir/$cand.conf" ]; then
      printf '%s\n' "$cand"; return 0
    fi
    tries=$((tries+1))
  done
  echo "registry: could not mint a unique invite id" >&2
  return 70
}

# registry_invite_mint_token - 32 bytes of /dev/urandom, base64url, unpadded.
#
# THE LENGTH IS ASSERTED, not assumed. A short read from urandom (a restricted
# container, a broken device) would produce a SHORTER token that still looks
# like a token, and the digest of a short token is a perfectly valid digest -
# the weakness would be invisible in the row and in the link. base64 of 32
# bytes is 44 characters with one '=' of padding, so 43 after stripping it.
registry_invite_mint_token() {
  local raw tok
  raw="$(head -c 32 /dev/urandom 2>/dev/null | base64 | tr -d '\n' | tr '+/' '-_' | tr -d '=')"
  tok="$raw"
  if [ "${#tok}" -lt 43 ]; then
    echo "registry: REFUSING - could not read 32 bytes of randomness for an invite token" >&2
    return 70
  fi
  printf '%s\n' "$tok"
}

# registry_invite_for_digest <hex> - which invitation a presented token belongs
# to. The CALLER digests the token; this function never sees one.
#
# EVERY ROW IS LOADED IN A SUBSHELL, the same reason the principal lookup gives:
# a malformed row must not leak its values into this function's locals.
registry_invite_for_digest() {
  local want="${1:-}" dir f id hits=""
  [[ "$want" =~ ^[0-9a-f]{64}$ ]] || return 1
  dir="$(registry_invite_dir)" || return 78
  [ -d "$dir" ] || return 1
  for f in "$dir"/*.conf; do
    [ -e "$f" ] || continue
    id="$(basename "$f" .conf)"
    if ( registry_invite_load "$id" >/dev/null 2>&1 && [ "$INVITE_TOKEN_SHA256" = "$want" ] ); then
      hits="$hits $id"
    fi
  done
  set -- $hits
  case $# in
    0) return 1 ;;
    1) printf '%s\n' "$1"; return 0 ;;
    *) echo "registry: the token digest matches more than one invite:$hits - refusing to pick" >&2; return 65 ;;
  esac
}

# registry_invite_open_for_principal <slug> - the OPEN invitation for a
# principal, if there is one. Expiry counts: an expired row is not open, so a
# second invitation for the same person is allowed once the first has run out.
registry_invite_open_for_principal() {
  local want="${1:-}" dir f id hits=""
  [ -n "$want" ] || return 1
  dir="$(registry_invite_dir)" || return 78
  [ -d "$dir" ] || return 1
  for f in "$dir"/*.conf; do
    [ -e "$f" ] || continue
    id="$(basename "$f" .conf)"
    if ( registry_invite_load "$id" >/dev/null 2>&1 \
         && [ "$INVITE_PRINCIPAL" = "$want" ] && [ "$INVITE_EFFECTIVE_STATE" = "open" ] ); then
      hits="$hits $id"
    fi
  done
  set -- $hits
  case $# in
    0) return 1 ;;
    1) printf '%s\n' "$1"; return 0 ;;
    *) echo "registry: more than one open invite for '$want':$hits" >&2; return 65 ;;
  esac
}
```

- [ ] **Step 4: Run test to verify it passes**
  Run: `bash test/invite-registry.test.sh`, then `bash test/logins-registry.test.sh` and `bash test/registry-row-replace.test.sh`, then `git add test/invite-registry.test.sh` and `PATH=/opt/homebrew/opt/node@22/bin:/opt/homebrew/bin:$PATH bash test/language.test.sh`.

- [ ] **Step 5: Commit**
  `git add lib/registry.sh test/invite-registry.test.sh`
  `git commit -m "feat(registry): invites.d - loader, writer, digest lookup and token minting"`

---

### Task 6: `steward invite issue`, `invite ls`, `invite revoke`

**Files:**
- Modify: `bin/steward` - new `cmd_invite*` functions (append after `cmd_registry_session_check`, near line 2770), the top-level dispatch `case` (line 5097), the usage header near line 37
- Test: `test/invite-verbs.test.sh` (create)

**Interfaces:**
- Consumes: `registry_invite_dir`, `registry_invite_load`, `registry_invite_list`, `registry_invite_write`, `registry_invite_replace`, `registry_invite_mint_id`, `registry_invite_mint_token`, `registry_invite_open_for_principal`, `registry_invite_id_valid`, `_registry_sha256`, `registry_desk_origin`, `registry_principal_dir`, `registry_entity_load`, `registry_host_dir`, `registry_host_load`, `registry_account_dir`, `registry_account_load`, `_REGISTRY_LOGIN_PROVIDERS`, `_registry_emit_kv`, `_reg_fail`, `_json`.
- Produces:
  - `steward invite issue --name <n> --principal <slug> --entity <e> --host <h> [--runtime <r>] [--provider <p>] [--days <n>] [--issued-by <slug>] [--json]`. rc 0 and the link on stdout, printed once; rc 64 for a missing or malformed flag; rc 65 when the principal already exists, the entity or the host does not resolve, an open invite for that principal already exists (its id is named), or the issuing principal cannot be resolved; rc 70/75/78 from the writer.
  - `steward invite ls [--json]`. rc 0. Columns: `id principal name entity host runtime provider state expires`. Never a token.
  - `steward invite revoke <id> [--json]`. rc 0 when the row moves to `revoked` or already is; rc 64 for a malformed id; rc 65 for a redeemed row; rc 78 when the row does not exist.
  - `_invite_validate_row <staged-file>` - the validate_fn for both the writer and the replace: re-reads the STAGED bytes through `registry_invite_load` in a one-row register and compares every field against `_REGW_EXPECT_INV_*`.

- [ ] **Step 1: Write the failing test**

Create `test/invite-verbs.test.sh`:

```bash
#!/bin/bash
# test/invite-verbs.test.sh - the operator's three verbs. The token is printed
# ONCE and stored never; the listing cannot leak what the register does not
# hold; and every refusal happens before a row exists.
set -u
here="$(CDPATH= cd -- "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
pass=0; fail=0
ok()  { pass=$((pass+1)); printf '  ok   %s\n' "$1"; }
bad() { fail=$((fail+1)); printf '  FAIL %s\n     %s\n' "$1" "${2:-}"; }
is()  { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "wanted '$3', got '$2'"; fi; }
has() { case "$2" in *"$3"*) ok "$1" ;; *) bad "$1" "missing '$3' in: $2" ;; esac; }
no()  { case "$2" in *"$3"*) bad "$1" "found '$3' in: $2" ;; *) ok "$1" ;; esac; }
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
ROOT="$T/estate"
mkdir -p "$ROOT/invites.d" "$ROOT/entities.d" "$ROOT/hosts.d" "$ROOT/principals.d" \
         "$ROOT/accounts.d" "$ROOT/estate"
printf 'ESTATE_NAME="fixture"\nDESK_ORIGIN="https://desk.example.test"\n' > "$ROOT/estate/steward.conf"
printf 'NAME="Acme"\nMEMBERS="operator"\n' > "$ROOT/entities.d/acme.conf"
printf 'OWNER="operator"\nLEGAL_OWNER="Acme Ltd"\nOPERATOR="operator"\n' > "$ROOT/hosts.d/host-a.conf"
printf 'NAME="Operator"\nTAILSCALE_LOGIN="login-op@example.test"\n' > "$ROOT/principals.d/operator.conf"
printf 'PRINCIPAL="operator"\nHOST="host-a"\nUSERNAME="%s"\n' "$(id -un)" > "$ROOT/accounts.d/operator-host-a.conf"
export STEWARD_ESTATE_ROOT="$ROOT" STEWARD_CONFIG_FILE="$T/no-such-config"
S="$here/bin/steward"
echo "invite-verbs"

out="$(bash "$S" invite issue --name "Alice Example" --principal alice --entity acme --host host-a 2>&1)"; rc=$?
is  "issue succeeds" "$rc" "0"
has "and prints a link on the estate's origin" "$out" "https://desk.example.test/desk/invite/"
link="$(printf '%s\n' "$out" | grep -o 'https://desk.example.test/desk/invite/[A-Za-z0-9_-]*' | head -1)"
token="${link##*/}"
if [ "${#token}" -ge 43 ]; then ok "the link carries a full token"; else bad "the link carries a full token" "got '${token}'"; fi

id="$(ls "$ROOT/invites.d" | sed 's/\.conf$//' | head -1)"
row="$(cat "$ROOT/invites.d/$id.conf")"
no  "the row does not hold the token" "$row" "$token"
has "the row holds the digest" "$row" "TOKEN_SHA256=\"$(printf '%s' "$token" | { if command -v sha256sum >/dev/null 2>&1; then sha256sum; else shasum -a 256; fi; } | cut -d' ' -f1)\""
has "the row names the principal" "$row" 'PRINCIPAL="alice"'
has "the row defaults the runtime" "$row" 'RUNTIME="claude-code"'
has "the row defaults the provider" "$row" 'PROVIDER="claude-max"'
has "the row names the issuer" "$row" 'ISSUED_BY="operator"'
has "the row is open" "$row" 'STATE="open"'
is  "the row is mode 600" \
    "$(stat -c %a "$ROOT/invites.d/$id.conf" 2>/dev/null || stat -f %Lp "$ROOT/invites.d/$id.conf")" "600"

lsout="$(bash "$S" invite ls 2>&1)"; rc=$?
is  "ls succeeds" "$rc" "0"
has "and names the invitation" "$lsout" "$id"
has "and its state" "$lsout" "open"
no  "and never a token" "$lsout" "$token"

jsonout="$(bash "$S" invite ls --json 2>&1)"
is  "ls --json is valid json" "$(printf '%s' "$jsonout" | jq -e 'type=="array"' >/dev/null 2>&1 && echo yes)" "yes"
is  "and carries the row" "$(printf '%s' "$jsonout" | jq -r '.[0].principal')" "alice"
no  "and no token field" "$jsonout" "$token"

out="$(bash "$S" invite issue --name "Alice Again" --principal alice --entity acme --host host-a 2>&1)"; rc=$?
is  "a second open invite for the same principal is rc 65" "$rc" "65"
has "and names the existing invitation" "$out" "$id"

printf 'NAME="Bo"\nTAILSCALE_LOGIN="login-b@example.test"\n' > "$ROOT/principals.d/bo.conf"
out="$(bash "$S" invite issue --name "Bo" --principal bo --entity acme --host host-a 2>&1)"; rc=$?
is  "inviting an existing principal is rc 65" "$rc" "65"
has "and says why" "$out" "already"

out="$(bash "$S" invite issue --name "Cy" --principal cy --entity nosuch --host host-a 2>&1)"; rc=$?
is  "an unknown entity is rc 65" "$rc" "65"
out="$(bash "$S" invite issue --name "Cy" --principal cy --entity acme --host nosuch 2>&1)"; rc=$?
is  "an unknown host is rc 65" "$rc" "65"
out="$(bash "$S" invite issue --name "Cy" --principal cy --entity acme --host host-a --runtime nonsense 2>&1)"; rc=$?
is  "an unknown runtime is rc 64" "$rc" "64"
out="$(bash "$S" invite issue --name "Cy" --principal cy --entity acme --host host-a --provider nonsense 2>&1)"; rc=$?
is  "an unknown provider is rc 64" "$rc" "64"
out="$(bash "$S" invite issue --name "Cy" --principal cy --entity acme --host host-a --days 0 2>&1)"; rc=$?
is  "zero days is rc 64" "$rc" "64"
is  "and none of those wrote a row" "$(ls "$ROOT/invites.d" | wc -l | tr -d ' ')" "1"

out="$(bash "$S" invite revoke "$id" 2>&1)"; rc=$?
is  "revoke succeeds" "$rc" "0"
has "and the row moved" "$(cat "$ROOT/invites.d/$id.conf")" 'STATE="revoked"'
out="$(bash "$S" invite revoke "$id" 2>&1)"; rc=$?
is  "revoking twice is a no-op, rc 0" "$rc" "0"
out="$(bash "$S" invite revoke inv-00000099 2>&1)"; rc=$?
is  "revoking a row that does not exist is rc 78" "$rc" "78"
out="$(bash "$S" invite revoke nonsense 2>&1)"; rc=$?
is  "a malformed id is rc 64" "$rc" "64"

# A revoked invitation frees the principal for a new one.
out="$(bash "$S" invite issue --name "Alice Example" --principal alice --entity acme --host host-a 2>&1)"; rc=$?
is  "a fresh invitation after a revoke succeeds" "$rc" "0"

printf '\n  %d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
```

- [ ] **Step 2: Run test to verify it fails**
  Run: `bash test/invite-verbs.test.sh`
  Expected: FAIL with `steward: unknown command 'issue' for estate 'invite'` and rc 64 where rc 0 was wanted.

- [ ] **Step 3: Write minimal implementation**

In `bin/steward`, append after `cmd_registry_session_check` ends:

```bash
# -- INVITATIONS ------------------------------------------------------------
#
# Registration is CLOSED. `invite issue` records the operator's word, prints
# the one-time link ONCE, and stores only the digest; `invite ls` reads the
# register; `invite revoke` moves a row to revoked. Redemption is its own verb.

# _invite_validate_row <staged-file> - the validate_fn both the invite writer
# and the invite replace call under the register's write lock. It does NOT
# source what it validates (this register's reader never does either): the
# staged bytes are copied into a one-row register and read back through
# registry_invite_load, so "valid" means exactly what every later reader will
# see. Same technique as _registry_validate_login_stage.
_invite_validate_row() {
  local file="$1" dir rc=0
  dir="$(mktemp -d)" || { echo "registry: cannot stage-validate an invite row" >&2; return 70; }
  cp "$file" "$dir/inv-00000000.conf" || { rm -rf "$dir"; return 70; }
  chmod 600 "$dir/inv-00000000.conf"
  ( STEWARD_INVITE_DIR="$dir"; registry_invite_load inv-00000000 >/dev/null 2>&1 ) || rc=70
  if [ "$rc" -ne 0 ]; then
    rm -rf "$dir"
    echo "registry: the staged invite row does not parse with the register's own reader: $file" >&2
    return 70
  fi
  # THE FIELD NAME IS RESOLVED THROUGH INDIRECT EXPANSION, NOT AN INLINE `case`
  # INSIDE $( ) - bash 3.2 (macOS) mis-parses that shape, and this file runs on
  # it. See the same note in _registry_validate_login_stage.
  local got k varname want
  for k in NAME PRINCIPAL ENTITY HOST RUNTIME PROVIDER TOKEN_SHA256 ISSUED_BY \
           ISSUED_AT EXPIRES_AT STATE REDEEMED_LOGIN REDEEMED_AT; do
    varname="INVITE_$k"
    got="$( STEWARD_INVITE_DIR="$dir"; registry_invite_load inv-00000000 >/dev/null 2>&1; printf '%s' "${!varname}" )"
    eval "want=\"\${_REGW_EXPECT_INV_$k:-}\""
    if [ "$got" != "$want" ]; then
      rm -rf "$dir"
      echo "registry: staged invite row's $k does not match what was written: $file" >&2
      return 70
    fi
  done
  rm -rf "$dir"
  return 0
}

# _invite_compose - the row's bytes, from the _REGW_EXPECT_INV_* values the
# caller has already set. ONE serializer for issue, revoke and redeem, so the
# three can never write three different shapes of the same row.
#
# The optional pair is written only when it has a value: a redeemed row carries
# REDEEMED_LOGIN/REDEEMED_AT, an open one carries no empty lines for them.
_invite_compose() { # <id>
  local id="$1" k kv line body="" kv_err rc
  kv_err="$(mktemp)" || return 70
  for k in NAME PRINCIPAL ENTITY HOST RUNTIME PROVIDER TOKEN_SHA256 ISSUED_BY \
           ISSUED_AT EXPIRES_AT STATE REDEEMED_LOGIN REDEEMED_AT; do
    eval "kv=\"\${_REGW_EXPECT_INV_$k:-}\""
    case "$k" in
      REDEEMED_LOGIN|REDEEMED_AT) [ -n "$kv" ] || continue ;;
    esac
    line="$(_registry_emit_kv "$k" "$kv" 2>"$kv_err")"; rc=$?
    if [ "$rc" -ne 0 ]; then rm -f "$kv_err"; return 64; fi
    body="$body$line
"
  done
  rm -f "$kv_err"
  printf '# %s - invitation, written by steward invite.\n%s' "$id" "$body"
}

# _invite_load_expect <id> - load a row and copy every field into the
# _REGW_EXPECT_INV_* values, so a caller can change ONE of them and recompose
# the whole row without retyping the rest.
_invite_load_expect() { # <id>
  registry_invite_load "$1" || return $?
  _REGW_EXPECT_INV_NAME="$INVITE_NAME"
  _REGW_EXPECT_INV_PRINCIPAL="$INVITE_PRINCIPAL"
  _REGW_EXPECT_INV_ENTITY="$INVITE_ENTITY"
  _REGW_EXPECT_INV_HOST="$INVITE_HOST"
  _REGW_EXPECT_INV_RUNTIME="$INVITE_RUNTIME"
  _REGW_EXPECT_INV_PROVIDER="$INVITE_PROVIDER"
  _REGW_EXPECT_INV_TOKEN_SHA256="$INVITE_TOKEN_SHA256"
  _REGW_EXPECT_INV_ISSUED_BY="$INVITE_ISSUED_BY"
  _REGW_EXPECT_INV_ISSUED_AT="$INVITE_ISSUED_AT"
  _REGW_EXPECT_INV_EXPIRES_AT="$INVITE_EXPIRES_AT"
  _REGW_EXPECT_INV_STATE="$INVITE_STATE"
  _REGW_EXPECT_INV_REDEEMED_LOGIN="$INVITE_REDEEMED_LOGIN"
  _REGW_EXPECT_INV_REDEEMED_AT="$INVITE_REDEEMED_AT"
  return 0
}

# _invite_self_principal - which principal is running this verb, measured from
# the register rather than typed. The unix account this process runs as is
# matched against accounts.d on this machine; its PRINCIPAL is the answer. rc 1
# and nothing when no row matches - the caller turns that into a refusal that
# names --issued-by, because guessing who signed an invitation is exactly the
# kind of guess this register exists to prevent.
_invite_self_principal() {
  local me d f slug u p
  me="$(id -un)"
  d="$(registry_account_dir)" || return 78
  [ -d "$d" ] || return 1
  for f in "$d"/*.conf; do
    [ -e "$f" ] || continue
    slug="$(basename "$f" .conf)"
    u="$( registry_account_load "$slug" >/dev/null 2>&1 && printf '%s' "$ACCOUNT_USERNAME" )"
    [ "$u" = "$me" ] || continue
    p="$( registry_account_load "$slug" >/dev/null 2>&1 && printf '%s' "$ACCOUNT_PRINCIPAL" )"
    [ -n "$p" ] || continue
    printf '%s\n' "$p"; return 0
  done
  return 1
}

cmd_invite_issue() {
  local want_json="" name="" principal="" entity="" host="" runtime="claude-code" \
        provider="claude-max" days="7" issued_by="" a
  for a in "$@"; do [ "$a" = "--json" ] && want_json=1; done
  while [ $# -gt 0 ]; do
    case "$1" in
      --json) shift ;;
      --name)      [ $# -ge 2 ] || { _reg_fail "$want_json" "steward invite issue: --name needs a value"; return 64; };      name="$2"; shift 2 ;;
      --principal) [ $# -ge 2 ] || { _reg_fail "$want_json" "steward invite issue: --principal needs a value"; return 64; }; principal="$2"; shift 2 ;;
      --entity)    [ $# -ge 2 ] || { _reg_fail "$want_json" "steward invite issue: --entity needs a value"; return 64; };    entity="$2"; shift 2 ;;
      --host)      [ $# -ge 2 ] || { _reg_fail "$want_json" "steward invite issue: --host needs a value"; return 64; };      host="$2"; shift 2 ;;
      --runtime)   [ $# -ge 2 ] || { _reg_fail "$want_json" "steward invite issue: --runtime needs a value"; return 64; };   runtime="$2"; shift 2 ;;
      --provider)  [ $# -ge 2 ] || { _reg_fail "$want_json" "steward invite issue: --provider needs a value"; return 64; };  provider="$2"; shift 2 ;;
      --days)      [ $# -ge 2 ] || { _reg_fail "$want_json" "steward invite issue: --days needs a value"; return 64; };      days="$2"; shift 2 ;;
      --issued-by) [ $# -ge 2 ] || { _reg_fail "$want_json" "steward invite issue: --issued-by needs a value"; return 64; }; issued_by="$2"; shift 2 ;;
      *) _reg_fail "$want_json" "steward invite issue: unexpected argument '$1'"; return 64 ;;
    esac
  done

  # shellcheck source=lib/registry.sh
  . "$HERE/lib/registry.sh"

  [ -n "$name" ] || { _reg_fail "$want_json" "steward invite issue: --name is required (the invited person's display name)"; return 64; }
  case "$name" in
    *'$'*|*'`'*|*'\'*|*'"'*)
      _reg_fail "$want_json" "steward invite issue: --name must not contain a quote, a backslash or a substitution character"; return 64 ;;
  esac
  local nm v
  for nm in principal entity host; do
    eval "v=\$$nm"
    [ -n "$v" ] || { _reg_fail "$want_json" "steward invite issue: --$nm is required"; return 64; }
    if ! [[ "$v" =~ ^[a-z][a-z0-9-]*$ ]]; then
      _reg_fail "$want_json" "steward invite issue: invalid --$nm '$v' (a-z, then a-z 0-9 and hyphen)"; return 64
    fi
  done
  case "$runtime" in
    claude-code|opencode|codex) ;;
    *) _reg_fail "$want_json" "steward invite issue: invalid --runtime '$runtime' (one of: claude-code opencode codex)"; return 64 ;;
  esac
  case " $_REGISTRY_LOGIN_PROVIDERS " in
    *" $provider "*) ;;
    *) _reg_fail "$want_json" "steward invite issue: invalid --provider '$provider' (one of: $_REGISTRY_LOGIN_PROVIDERS)"; return 64 ;;
  esac
  if ! [[ "$days" =~ ^[0-9]+$ ]] || [ "$days" -lt 1 ] || [ "$days" -gt 365 ]; then
    _reg_fail "$want_json" "steward invite issue: --days must be a whole number of days between 1 and 365"; return 64
  fi

  # THE PRINCIPAL MUST NOT EXIST. An invitation MINTS a principal; aiming one at
  # a person who already has a row would bind a second identity to them through
  # a door meant for strangers.
  if [ -e "$(registry_principal_dir)/$principal.conf" ]; then
    _reg_fail "$want_json" "steward invite issue: principal '$principal' already exists - an invitation mints a principal, it does not extend one"
    return 65
  fi
  if ! ( registry_entity_load "$entity" >/dev/null 2>&1 ); then
    _reg_fail "$want_json" "steward invite issue: no such entity '$entity' - register the entity before inviting somebody into it"
    return 65
  fi
  if ! ( registry_host_load "$(registry_host_dir)/$host.conf" >/dev/null 2>&1 ); then
    _reg_fail "$want_json" "steward invite issue: no such host '$host' - the account and the first session live on a host the register knows"
    return 65
  fi
  local open_id
  open_id="$(registry_invite_open_for_principal "$principal" 2>/dev/null)" || open_id=""
  if [ -n "$open_id" ]; then
    _reg_fail "$want_json" "steward invite issue: an open invitation for '$principal' already exists: $open_id - revoke it or let it expire"
    return 65
  fi
  if [ -z "$issued_by" ]; then
    issued_by="$(_invite_self_principal)" || issued_by=""
  fi
  if [ -z "$issued_by" ]; then
    _reg_fail "$want_json" "steward invite issue: could not resolve which principal is issuing this invitation from the account register - pass --issued-by <slug>"
    return 65
  fi
  if ! [[ "$issued_by" =~ ^[a-z][a-z0-9-]*$ ]]; then
    _reg_fail "$want_json" "steward invite issue: invalid --issued-by '$issued_by'"; return 64
  fi

  local origin; origin="$(registry_desk_origin)" || return 78

  local id token digest now expires
  id="$(registry_invite_mint_id)" || return 70
  token="$(registry_invite_mint_token)" || return 70
  digest="$(printf '%s' "$token" | _registry_sha256)" || return 78
  now="$(date -u +%s)"
  expires=$((now + days * 86400))

  _REGW_EXPECT_INV_NAME="$name"
  _REGW_EXPECT_INV_PRINCIPAL="$principal"
  _REGW_EXPECT_INV_ENTITY="$entity"
  _REGW_EXPECT_INV_HOST="$host"
  _REGW_EXPECT_INV_RUNTIME="$runtime"
  _REGW_EXPECT_INV_PROVIDER="$provider"
  _REGW_EXPECT_INV_TOKEN_SHA256="$digest"
  _REGW_EXPECT_INV_ISSUED_BY="$issued_by"
  _REGW_EXPECT_INV_ISSUED_AT="$now"
  _REGW_EXPECT_INV_EXPIRES_AT="$expires"
  _REGW_EXPECT_INV_STATE="open"
  _REGW_EXPECT_INV_REDEEMED_LOGIN=""
  _REGW_EXPECT_INV_REDEEMED_AT=""

  local content rc rw_err
  content="$(_invite_compose "$id")" || {
    _reg_fail "$want_json" "steward invite issue: a field carries a control character or newline"; return 64; }
  rw_err="$(mktemp)" || { _reg_fail "$want_json" "steward invite issue: cannot create a temporary file"; return 70; }
  registry_invite_write "$id" "$content" _invite_validate_row 2>"$rw_err"; rc=$?
  if [ "$rc" -ne 0 ]; then
    _reg_fail "$want_json" "steward invite issue: $(tr '\n' ' ' < "$rw_err")"
    rm -f "$rw_err"
    return "$rc"
  fi
  rm -f "$rw_err"

  # THE LINK IS PRINTED HERE AND NOWHERE ELSE, EVER. The row holds the digest;
  # there is no path in the product that can print this string a second time.
  local link="$origin/desk/invite/$token"
  if [ -n "$want_json" ]; then
    _json ok true kind invite id "$id" principal "$principal" entity "$entity" host "$host" \
      runtime "$runtime" provider "$provider" expires "$expires" link "$link"
  else
    printf 'steward: invitation %s for %s (%s) on %s, valid %s day(s)\n' \
      "$id" "$principal" "$name" "$host" "$days"
    printf 'steward: this link is shown ONCE and is stored nowhere - send it now:\n'
    printf '%s\n' "$link"
  fi
  return 0
}

cmd_invite_ls() {
  local want_json="" a
  for a in "$@"; do
    case "$a" in
      --json) want_json=1 ;;
      *) _reg_fail "" "steward invite ls: unexpected argument '$a'"; return 64 ;;
    esac
  done
  # shellcheck source=lib/registry.sh
  . "$HERE/lib/registry.sh"
  local ids rc=0
  ids="$(registry_invite_list)" || return $?
  if [ -n "$want_json" ]; then
    local tmp; tmp="$(mktemp)" || return 70
    local id
    for id in $ids; do
      ( registry_invite_load "$id" >/dev/null 2>&1 || exit 0
        _json id "$INVITE_ID" name "$INVITE_NAME" principal "$INVITE_PRINCIPAL" \
          entity "$INVITE_ENTITY" host "$INVITE_HOST" runtime "$INVITE_RUNTIME" \
          provider "$INVITE_PROVIDER" state "$INVITE_EFFECTIVE_STATE" \
          issuedBy "$INVITE_ISSUED_BY" issuedAt "$INVITE_ISSUED_AT" \
          expiresAt "$INVITE_EXPIRES_AT" redeemedLogin "$INVITE_REDEEMED_LOGIN" ) >> "$tmp"
    done
    jq -s . < "$tmp"; rc=$?
    rm -f "$tmp"
    return "$rc"
  fi
  printf '%-12s %-12s %-10s %-10s %-12s %-9s %s\n' ID PRINCIPAL ENTITY HOST RUNTIME STATE NAME
  local id
  for id in $ids; do
    ( registry_invite_load "$id" >/dev/null 2>&1 || exit 0
      printf '%-12s %-12s %-10s %-10s %-12s %-9s %s\n' \
        "$INVITE_ID" "$INVITE_PRINCIPAL" "$INVITE_ENTITY" "$INVITE_HOST" \
        "$INVITE_RUNTIME" "$INVITE_EFFECTIVE_STATE" "$INVITE_NAME" )
  done
  return 0
}

cmd_invite_revoke() {
  local want_json="" id="" a
  for a in "$@"; do [ "$a" = "--json" ] && want_json=1; done
  while [ $# -gt 0 ]; do
    case "$1" in
      --json) shift ;;
      -*) _reg_fail "$want_json" "steward invite revoke: unknown flag '$1'"; return 64 ;;
      *) if [ -n "$id" ]; then _reg_fail "$want_json" "steward invite revoke: one invitation at a time"; return 64; fi
         id="$1"; shift ;;
    esac
  done
  # shellcheck source=lib/registry.sh
  . "$HERE/lib/registry.sh"
  if ! registry_invite_id_valid "$id"; then
    _reg_fail "$want_json" "steward invite revoke: invalid invitation id '$id' (expected inv- and eight hex digits)"
    return 64
  fi
  if [ ! -f "$(registry_invite_dir)/$id.conf" ]; then
    _reg_fail "$want_json" "steward invite revoke: no such invitation '$id'"
    return 78
  fi
  _invite_load_expect "$id" >/dev/null 2>&1 || {
    _reg_fail "$want_json" "steward invite revoke: invitation '$id' does not load - repair the row"
    return 78; }
  if [ "$INVITE_STATE" = "revoked" ]; then
    if [ -n "$want_json" ]; then _json ok true kind invite id "$id" state revoked changed false
    else printf 'steward: invitation %s is already revoked\n' "$id"; fi
    return 0
  fi
  if [ "$INVITE_STATE" = "redeemed" ]; then
    _reg_fail "$want_json" "steward invite revoke: invitation '$id' was already redeemed - it stays as history; offboard the principal instead"
    return 65
  fi
  _REGW_EXPECT_INV_STATE="revoked"
  local content rc rw_err
  content="$(_invite_compose "$id")" || {
    _reg_fail "$want_json" "steward invite revoke: a field carries a control character or newline"; return 64; }
  rw_err="$(mktemp)" || { _reg_fail "$want_json" "steward invite revoke: cannot create a temporary file"; return 70; }
  registry_invite_replace "$id" "$content" _invite_validate_row 2>"$rw_err"; rc=$?
  if [ "$rc" -ne 0 ]; then
    _reg_fail "$want_json" "steward invite revoke: $(tr '\n' ' ' < "$rw_err")"
    rm -f "$rw_err"; return "$rc"
  fi
  rm -f "$rw_err"
  if [ -n "$want_json" ]; then _json ok true kind invite id "$id" state revoked changed true
  else printf 'steward: invitation %s revoked - the link no longer opens anything\n' "$id"; fi
  return 0
}

cmd_invite() {
  case "${1:-}" in
    issue)  shift; cmd_invite_issue "$@" ;;
    ls)     shift; cmd_invite_ls "$@" ;;
    revoke) shift; cmd_invite_revoke "$@" ;;
    *) fel "steward invite: unknown verb '${1:-}' (allowed: issue, ls, revoke)" 64 ;;
  esac
}
```

In the top-level dispatch `case` (bin/steward:5097), add before `registry)`:

```bash
  invite)   shift; cmd_invite "$@"; exit $? ;;
```

And add to the usage header near line 37:

```
#   steward invite issue --name N --principal P --entity E --host H [--runtime R] [--provider V] [--days D] [--issued-by P] [--json]
#   steward invite ls [--json]
#   steward invite revoke <inv-id> [--json]
```

- [ ] **Step 4: Run test to verify it passes**
  Run: `bash test/invite-verbs.test.sh`, then `bash test/invite-registry.test.sh` and `bash test/doctor.test.sh`, then `git add test/invite-verbs.test.sh` and `PATH=/opt/homebrew/opt/node@22/bin:/opt/homebrew/bin:$PATH bash test/language.test.sh`.

- [ ] **Step 5: Commit**
  `git add bin/steward test/invite-verbs.test.sh`
  `git commit -m "feat(invite): issue, ls and revoke - the link is printed once, the digest is stored"`

---

### Task 7: `linux/steward-account-helper` - the one privileged path

**Files:**
- Create: `linux/steward-account-helper`
- Test: `test/account-helper.test.sh` (create)

**Interfaces:**
- Consumes: nothing from the product. The helper takes NO input but its two arguments and reads nothing from the environment - it is the only thing a sudoers line allows, so anything it read would be a way to steer root.
- Produces:
  - `steward-account-helper add <username>` - creates the unix account when it does not exist (home mode 750, the `video` and `render` groups when they exist, a locked password, lingering enabled) and writes the per-account rig socket directory fragment `/etc/tmpfiles.d/steward-rig-<username>.conf` holding `d /run/steward/rig/<username> 0710 <username> steward -`. Idempotent. Every action prints one `helper: <what>` line; the fragment's line is `helper: tmpfiles /etc/tmpfiles.d/steward-rig-<username>.conf`.
  - `steward-account-helper lock <username> [--archive-home]` - disables lingering (which takes the account's user manager and its session units down with it), locks the password and expires the account. With `--archive-home` it also moves the home to `/home/.offboarded/<username>-<YYYY-MM-DD>` and prints `helper: archived <destination>`.
  - Exit codes: 0 done - 64 usage, or an argument outside `^[a-z][a-z0-9-]{1,31}$` - 70 an action failed - 77 not running as root.
  - The sudoers line the estate installs, quoted in the file's header: `steward ALL=(root) NOPASSWD: /usr/local/sbin/steward-account-helper`.

- [ ] **Step 1: Write the failing test**

Create `test/account-helper.test.sh`:

```bash
#!/bin/bash
# test/account-helper.test.sh - the privileged helper, measured on what it
# CALLS. Nothing here runs as root and nothing here creates an account: id,
# getent, useradd, usermod, passwd, loginctl, install, systemd-tmpfiles, chmod,
# mkdir and mv are all shims on PATH that record their argv. What must be shown
# is the argument guard, the receipt lines and the exact commands - the account
# creation itself is the operating system's job and is not ours to test.
set -u
here="$(CDPATH= cd -- "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
H="$here/linux/steward-account-helper"
pass=0; fail=0
ok()  { pass=$((pass+1)); printf '  ok   %s\n' "$1"; }
bad() { fail=$((fail+1)); printf '  FAIL %s\n     %s\n' "$1" "${2:-}"; }
is()  { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "wanted '$3', got '$2'"; fi; }
has() { case "$2" in *"$3"*) ok "$1" ;; *) bad "$1" "missing '$3' in: $2" ;; esac; }
no()  { case "$2" in *"$3"*) bad "$1" "found '$3' in: $2" ;; *) ok "$1" ;; esac; }
FX="$(mktemp -d)"; trap 'rm -rf "$FX"' EXIT
mkdir -p "$FX/bin" "$FX/home/alice"
echo "account-helper"

mkshim() { # <name> <body>
  cat > "$FX/bin/$1" <<EOF
#!/bin/bash
echo "$1 \$*" >> "$FX/calls"
$2
EOF
  chmod 755 "$FX/bin/$1"
}
: > "$FX/calls"
mkshim id 'echo "${FAKE_UID:-0}"'
# getent answers for the account only when $FX/exists says so - that is how the
# "already there" branch is exercised without a real account database.
mkshim getent 'case "$1" in
  passwd) if [ -f "'"$FX"'/exists" ]; then echo "$2:x:1001:1001::'"$FX"'/home/$2:/bin/bash"; exit 0; fi; exit 2 ;;
  group)  case "$2" in video) exit 0 ;; *) exit 2 ;; esac ;;
esac
exit 2'
mkshim useradd 'touch "'"$FX"'/exists"; exit 0'
mkshim usermod 'exit 0'
mkshim passwd 'exit 0'
mkshim loginctl 'exit 0'
mkshim install 'cat > /dev/null; exit 0'
mkshim systemd-tmpfiles 'exit 0'
mkshim chmod 'exit 0'
mkshim mkdir 'exit 0'
mkshim mv 'exit 0'

run() { ( export PATH="$FX/bin:$PATH"; bash "$H" "$@" ); }

echo "== the argument guard =="
out="$(run 2>&1)"; rc=$?
is  "no arguments is rc 64" "$rc" "64"
has "and the usage names the sudoers line" "$out" "NOPASSWD: /usr/local/sbin/steward-account-helper"
out="$(run add 2>&1)"; rc=$?
is  "add without a name is rc 64" "$rc" "64"
out="$(run add 'Alice' 2>&1)"; rc=$?
is  "an upper-case name is rc 64" "$rc" "64"
out="$(run add 'a' 2>&1)"; rc=$?
is  "a one-character name is rc 64" "$rc" "64"
out="$(run add 'alice; rm -rf /' 2>&1)"; rc=$?
is  "a name with a metacharacter is rc 64" "$rc" "64"
out="$(run add "$(printf 'a%.0s' $(seq 1 40))" 2>&1)"; rc=$?
is  "a name over 32 characters is rc 64" "$rc" "64"
out="$(run frobnicate alice 2>&1)"; rc=$?
is  "an unknown sub-command is rc 64" "$rc" "64"
is  "and none of those called anything" "$(wc -l < "$FX/calls" | tr -d ' ')" "0"

echo "== it refuses when it is not root =="
out="$( ( export PATH="$FX/bin:$PATH" FAKE_UID=1000; bash "$H" add alice ) 2>&1 )"; rc=$?
is  "a non-root run is rc 77" "$rc" "77"
has "and says so" "$out" "root"

echo "== add, on a host where the account does not exist =="
: > "$FX/calls"; rm -f "$FX/exists"
out="$(run add alice 2>&1)"; rc=$?
is  "add succeeds" "$rc" "0"
calls="$(cat "$FX/calls")"
has "it creates the account" "$calls" "useradd --create-home --shell /bin/bash alice"
has "it tightens the home" "$calls" "chmod 750 $FX/home/alice"
has "it adds the group that exists" "$calls" "usermod -aG video alice"
no  "and not the group that does not" "$calls" "usermod -aG render alice"
has "it locks the password" "$calls" "passwd -l alice"
has "it enables lingering" "$calls" "loginctl enable-linger alice"
has "it installs the rig fragment" "$calls" "install -m 0644 /dev/stdin /etc/tmpfiles.d/steward-rig-alice.conf"
has "it applies the fragment" "$calls" "systemd-tmpfiles --create /etc/tmpfiles.d/steward-rig-alice.conf"
has "the receipt names the fragment" "$out" "helper: tmpfiles /etc/tmpfiles.d/steward-rig-alice.conf"
has "the receipt names the account" "$out" "helper: account alice"

echo "== add, on a host where the account already exists =="
: > "$FX/calls"; touch "$FX/exists"
out="$(run add alice 2>&1)"; rc=$?
is  "a second add succeeds" "$rc" "0"
calls="$(cat "$FX/calls")"
no  "and does not create the account again" "$calls" "useradd"
has "but still reports the fragment" "$out" "helper: tmpfiles /etc/tmpfiles.d/steward-rig-alice.conf"

echo "== lock =="
: > "$FX/calls"; touch "$FX/exists"
out="$(run lock alice 2>&1)"; rc=$?
is  "lock succeeds" "$rc" "0"
calls="$(cat "$FX/calls")"
has "it stops lingering (and with it the session units)" "$calls" "loginctl disable-linger alice"
has "it locks the password" "$calls" "usermod --lock alice"
has "it expires the account" "$calls" "usermod --expiredate 1 alice"
no  "and it does not touch the home" "$calls" "mv "

: > "$FX/calls"
out="$(run lock alice --archive-home 2>&1)"; rc=$?
is  "lock --archive-home succeeds" "$rc" "0"
calls="$(cat "$FX/calls")"
has "it makes the archive root" "$calls" "mkdir -p /home/.offboarded"
has "it moves the home under a dated name" "$calls" "mv $FX/home/alice /home/.offboarded/alice-"
has "and the receipt names the destination" "$out" "helper: archived /home/.offboarded/alice-"

: > "$FX/calls"; rm -f "$FX/exists"
out="$(run lock alice 2>&1)"; rc=$?
is  "locking an account that does not exist is rc 70" "$rc" "70"
has "and says which one" "$out" "alice"

printf '\n  %d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
```

- [ ] **Step 2: Run test to verify it fails**
  Run: `bash test/account-helper.test.sh`
  Expected: FAIL with `bash: .../linux/steward-account-helper: No such file or directory` and rc 127 on every case.

- [ ] **Step 3: Write minimal implementation**

Create `linux/steward-account-helper` (mode 755):

```bash
#!/bin/bash
# linux/steward-account-helper - the ONE privileged action the product needs.
#
# Creating a unix account needs root; the hub runs as the steward account. The
# alternative to this file is unrestricted sudo for the steward account, which
# is not a boundary at all: it makes every bug in every product script a root
# bug. So the estate installs exactly one line,
#
#   steward ALL=(root) NOPASSWD: /usr/local/sbin/steward-account-helper
#
# and this file is what stands behind it. On a host where the steward account
# already has unrestricted sudo the line is redundant and is installed anyway,
# so the product measures the same thing on every host - and the day a host
# restricts that account, nothing changes.
#
# IT TAKES NO INPUT BUT ITS ARGUMENTS. No environment variable steers it, no
# file configures it, and it never reads stdin. Anything it read would be a way
# to steer root through a line that was written to be narrow.
#
# IT VALIDATES ITS OWN ARGUMENT. A sudoers line permits a COMMAND, not an
# argument, so a caller can pass anything; the guard has to live here.
#
# Exit codes: 0 done - 64 usage or a bad argument - 70 an action failed -
# 77 not running as root.
set -uo pipefail

usage() {
  cat >&2 <<'USAGE'
usage: steward-account-helper add <username>
       steward-account-helper lock <username> [--archive-home]

  add   create the account when it is missing (home 750, groups video and
        render where they exist, a locked password, lingering enabled) and
        write the per-account rig socket directory fragment. Idempotent.
  lock  stop lingering (which takes the account's user manager and its session
        units with it), lock the password and expire the account.
        --archive-home also moves the home under /home/.offboarded.

The estate grants this file, and nothing else, through:
  steward ALL=(root) NOPASSWD: /usr/local/sbin/steward-account-helper
USAGE
  exit 64
}

fail() { echo "helper: REFUSING - $1" >&2; exit "${2:-70}"; }

ACTION="${1:-}"; USERNAME="${2:-}"; shift 2 2>/dev/null || true
ARCHIVE=""
while [ $# -gt 0 ]; do
  case "$1" in
    --archive-home) ARCHIVE=1; shift ;;
    *) usage ;;
  esac
done
case "$ACTION" in add|lock) ;; *) usage ;; esac
# THE SHAPE, ENUMERATED. Between 2 and 32 characters, starting with a letter -
# the shape a unix account name has on the hosts this runs on, and narrow
# enough that the name can never be anything but a name.
if ! [[ "$USERNAME" =~ ^[a-z][a-z0-9-]{1,31}$ ]]; then
  usage
fi
[ "$(id -u)" = "0" ] || fail "this helper must run as root (through the estate's sudoers line)" 77

# home_of <username> - the account's home from the SYSTEM's own database, never
# a /home literal. The archive ROOT below is a fixed location the operator
# looks in; a home is not, and guessing one would move the wrong directory.
home_of() {
  local h
  h="$(getent passwd "$1" 2>/dev/null | cut -d: -f6)"
  h="${h%%$'\n'*}"
  case "$h" in
    /*) printf '%s\n' "$h" ;;
    *)  return 1 ;;
  esac
}

if [ "$ACTION" = "add" ]; then
  if ! getent passwd "$USERNAME" >/dev/null 2>&1; then
    useradd --create-home --shell /bin/bash "$USERNAME" \
      || fail "useradd failed for '$USERNAME'"
    echo "helper: account $USERNAME created"
  else
    echo "helper: account $USERNAME already exists"
  fi
  HOME_DIR="$(home_of "$USERNAME")" \
    || fail "the account database has no absolute home for '$USERNAME'"
  # 750: the owner works in it, the steward account's group reaches it, nobody
  # else on the machine reads it. This is the boundary the bus's cross-home
  # delivery exists to respect.
  chmod 750 "$HOME_DIR" || fail "could not set mode 750 on $HOME_DIR"
  echo "helper: home $HOME_DIR mode 750"
  # THE GROUPS ARE OPTIONAL, PER HOST. A host with no graphics stack has no
  # render group, and refusing there would make a headless host un-onboardable
  # for a reason that has nothing to do with the person.
  for g in video render; do
    if getent group "$g" >/dev/null 2>&1; then
      usermod -aG "$g" "$USERNAME" || fail "could not add '$USERNAME' to group '$g'"
      echo "helper: group $g"
    else
      echo "helper: group $g absent on this host, skipped"
    fi
  done
  # NO PASSWORD, EVER. The account is reached over ssh with a key or as its own
  # user manager; a password is one more credential nobody rotates.
  passwd -l "$USERNAME" >/dev/null 2>&1 || fail "could not lock the password for '$USERNAME'"
  echo "helper: password locked"
  loginctl enable-linger "$USERNAME" || fail "could not enable lingering for '$USERNAME'"
  echo "helper: lingering enabled"
  # THE RIG SOCKET DIRECTORY, PER ACCOUNT. The rig's account must be able to
  # create the socket and the steward account must be able to connect to it, so
  # the directory is 0710 owned <account>:steward. Harmless on an account that
  # never gets a rig: an empty directory under /run.
  FRAGMENT="/etc/tmpfiles.d/steward-rig-$USERNAME.conf"
  printf 'd /run/steward/rig/%s 0710 %s steward -\n' "$USERNAME" "$USERNAME" \
    | install -m 0644 /dev/stdin "$FRAGMENT" \
    || fail "could not write $FRAGMENT"
  systemd-tmpfiles --create "$FRAGMENT" || fail "could not apply $FRAGMENT"
  echo "helper: tmpfiles $FRAGMENT"
  exit 0
fi

# lock - the reverse of add, in reverse order.
getent passwd "$USERNAME" >/dev/null 2>&1 \
  || fail "no such account '$USERNAME' - nothing to lock"
# DISABLE-LINGER IS WHAT STOPS THE WORK. It takes the account's user manager
# down, and every session unit under it with the manager - which is the only
# way the steward account can stop another person's sessions without a shell in
# their home.
loginctl disable-linger "$USERNAME" || fail "could not disable lingering for '$USERNAME'"
echo "helper: lingering disabled (the user manager and its units are down)"
usermod --lock "$USERNAME" || fail "could not lock '$USERNAME'"
echo "helper: password locked"
usermod --expiredate 1 "$USERNAME" || fail "could not expire '$USERNAME'"
echo "helper: account expired"
if [ -n "$ARCHIVE" ]; then
  HOME_DIR="$(home_of "$USERNAME")" \
    || fail "the account database has no absolute home for '$USERNAME'"
  # THE ARCHIVE ROOT IS FIXED AND THE SOURCE IS NOT. Where a home lives is the
  # system's answer; where an archived home waits for the operator's word is a
  # place a human has to be able to find, so it is one path, named here.
  DEST="/home/.offboarded/$USERNAME-$(date -u +%Y-%m-%d)"
  mkdir -p /home/.offboarded || fail "could not create /home/.offboarded"
  mv "$HOME_DIR" "$DEST" || fail "could not archive $HOME_DIR to $DEST"
  echo "helper: archived $DEST"
  echo "helper: NOTHING WAS DELETED - the archive is removed on the operator's word, never by this helper"
fi
exit 0
```

- [ ] **Step 4: Run test to verify it passes**
  Run: `chmod 755 linux/steward-account-helper`, then `bash test/account-helper.test.sh`, then `git add linux/steward-account-helper test/account-helper.test.sh` and `PATH=/opt/homebrew/opt/node@22/bin:/opt/homebrew/bin:$PATH bash test/language.test.sh`, then `bash test/deploy-manifest.test.sh` (the helper is deliberately NOT a manifest row: it is installed to /usr/local/sbin by the estate, not into a home).

- [ ] **Step 5: Commit**
  `git add linux/steward-account-helper test/account-helper.test.sh`
  `git commit -m "feat(hosts): the root account helper the sudoers line allows"`

---

### Task 8: `steward invite redeem` - twelve resumable steps

**Files:**
- Modify: `bin/steward` - `cmd_invite_redeem` and its helpers, added beside the other `cmd_invite*` functions; the `cmd_invite` dispatch; the usage header
- Test: `test/invite-redeem.test.sh` (create)

**Interfaces:**
- Consumes: everything Task 6 produced, plus `cmd_registry_principal_add`, `cmd_registry_account_add`, `cmd_registry_login_add`, `cmd_registry_session_add`, `registry_entity_replace`, `registry_entity_load`, `registry_entity_dir`, `registry_account_dir`, `registry_login_dir`, `registry_dir`, `registry_account_slug_available`, `_registry_owner_home`, `_registry_emit_kv`, `registry_state_dir_name`, `registry_hub_host`, `registry_hub_ssh`, `_registry_estate_root`.
- Consumes as external commands, every one shimmable on PATH: `sudo -n /usr/local/sbin/steward-account-helper add <username>`, `sudo -n -u <username> <cmd>`, `ssh-keygen`, `ssh-keyscan`, `bash <product>/linux/deploy-self.sh <host>`, `bash <product>/bin/steward desk snapshot`.
- Produces: `steward invite redeem <token> --identity <source>:<value> [--email <e>] [--json]`.
  - rc 0 when all twelve steps have left their mark; rc 64 for a malformed argument; rc 65 when the token matches no row, the row is not effectively `open`, the identity already maps to a principal, or the invitation names a runtime the session writer cannot yet write; rc 70 when a step fails; rc 77 when `sudo -n` cannot run the helper.
  - One receipt line per step on stdout, each `<n>/12 <label>: <what happened>`, where "what happened" is either an action or `already done`.
  - A receipt file at `$HOME/.local/state/<STATE_DIR_NAME>/invites/<inv-id>.receipt.json` (directory 0700, file 0600), rewritten after every step: `{"schemaVersion":1,"invite":"inv-...","principal":"...","state":"running|done|failed","at":<epoch>,"lines":[...]}`. It never carries a token.
  - Re-running continues at the first step whose mark is absent; a step whose mark is present is reported and skipped.
  - Derived names: account slug `<principal>-<host>`, unix username `<principal>`, login slug `<principal>-<provider>`, session slug `<entity>-<principal>`, session repository the account's own home.

- [ ] **Step 1: Write the failing test**

Create `test/invite-redeem.test.sh`:

```bash
#!/bin/bash
# test/invite-redeem.test.sh - redemption, end to end, with every host-touching
# command replaced by a shim that records its argv. Nothing here creates an
# account, generates a real key, reaches a network or runs systemd.
#
# THE FIXTURE CARRIES ITS OWN PRODUCT TREE, the same technique
# test/deploy-self.test.sh uses: bin/steward resolves its own root, so the copy
# under the fixture is what runs and its linux/deploy-self.sh and
# desk/snapshot.sh are stubs that record instead of act.
set -u
here="$(CDPATH= cd -- "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
pass=0; fail=0
ok()  { pass=$((pass+1)); printf '  ok   %s\n' "$1"; }
bad() { fail=$((fail+1)); printf '  FAIL %s\n     %s\n' "$1" "${2:-}"; }
is()  { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "wanted '$3', got '$2'"; fi; }
has() { case "$2" in *"$3"*) ok "$1" ;; *) bad "$1" "missing '$3' in: $2" ;; esac; }
no()  { case "$2" in *"$3"*) bad "$1" "found '$3' in: $2" ;; *) ok "$1" ;; esac; }
FX="$(mktemp -d)"; trap 'rm -rf "$FX"' EXIT
echo "invite-redeem"

# -- the product tree -------------------------------------------------------
mkdir -p "$FX/product/bin" "$FX/product/lib" "$FX/product/linux" "$FX/product/desk/bin"
cp "$here/bin/steward"      "$FX/product/bin/steward"
cp "$here/lib/registry.sh"  "$FX/product/lib/registry.sh"
chmod 755 "$FX/product/bin/steward"
cat > "$FX/product/linux/deploy-self.sh" <<EOF
#!/bin/bash
echo "deploy-self \$*" >> "$FX/calls"
mkdir -p "$FX/home/alice/scripts/lib"
: > "$FX/home/alice/scripts/lib/registry.sh"
exit 0
EOF
cat > "$FX/product/desk/snapshot.sh" <<EOF
#!/bin/bash
echo "snapshot \$*" >> "$FX/calls"
exit 0
EOF
chmod 755 "$FX/product/linux/deploy-self.sh" "$FX/product/desk/snapshot.sh"
S="$FX/product/bin/steward"

# -- the estate -------------------------------------------------------------
ROOT="$FX/estate"
mkdir -p "$ROOT/invites.d" "$ROOT/entities.d" "$ROOT/hosts.d" "$ROOT/principals.d" \
         "$ROOT/accounts.d" "$ROOT/logins.d" "$ROOT/sessions.d" "$ROOT/estate"
cat > "$ROOT/estate/steward.conf" <<'EOF'
ESTATE_NAME="acme"
DESK_ORIGIN="https://desk.example.test"
STATE_DIR_NAME="fixture-state"
HUB_SESSION="host-a"
HUB_HOST="host-a"
HUB_SSH="steward@host-a"
EOF
printf 'NAME="Acme"\nMEMBERS="operator"\n' > "$ROOT/entities.d/acme.conf"
printf 'OWNER="operator"\nLEGAL_OWNER="Acme Ltd"\nOPERATOR="operator"\n' > "$ROOT/hosts.d/host-a.conf"
printf 'NAME="Operator"\nTAILSCALE_LOGIN="login-op@example.test"\n' > "$ROOT/principals.d/operator.conf"
printf 'PRINCIPAL="operator"\nHOST="host-a"\nUSERNAME="%s"\n' "$(id -un)" > "$ROOT/accounts.d/operator-host-a.conf"

# -- the hub's own home -----------------------------------------------------
HUBHOME="$FX/hubhome"
mkdir -p "$HUBHOME/.ssh" "$HUBHOME/scripts/bus/bin"
: > "$HUBHOME/.ssh/authorized_keys"
printf 'ssh-ed25519 AAAAHUBKEY hub\n' > "$HUBHOME/.ssh/id_ed25519.pub"
: > "$HUBHOME/scripts/bus/bin/bus-relay-in"

# -- the home lookup and the shims ------------------------------------------
mkdir -p "$FX/bin" "$FX/home"
cat > "$FX/bin/homelookup" <<EOF
#!/bin/bash
echo "$FX/home/\$1"
EOF
chmod 755 "$FX/bin/homelookup"

# sudo: records argv, then EITHER models the helper OR runs the rest of the
# command locally. Modelling the helper is what makes the account appear, so a
# second run can find the mark and skip the step.
cat > "$FX/bin/sudo" <<EOF
#!/bin/bash
echo "sudo \$*" >> "$FX/calls"
args=()
user=""
while [ \$# -gt 0 ]; do
  case "\$1" in
    -n) shift ;;
    -u) user="\$2"; shift 2 ;;
    *) args+=("\$1"); shift ;;
  esac
done
case "\${args[0]:-}" in
  */steward-account-helper)
    mkdir -p "$FX/home/\${args[2]}/.ssh"
    echo "helper: account \${args[2]} created"
    echo "helper: tmpfiles /etc/tmpfiles.d/steward-rig-\${args[2]}.conf"
    exit 0 ;;
esac
exec "\${args[@]}"
EOF
chmod 755 "$FX/bin/sudo"
cat > "$FX/bin/ssh-keygen" <<EOF
#!/bin/bash
echo "ssh-keygen \$*" >> "$FX/calls"
f=""; prev=""
for a in "\$@"; do [ "\$prev" = "-f" ] && f="\$a"; prev="\$a"; done
[ -n "\$f" ] && { mkdir -p "\$(dirname "\$f")"; printf 'PRIVATE\n' > "\$f"; printf 'ssh-ed25519 AAAANEWKEY new\n' > "\$f.pub"; }
exit 0
EOF
chmod 755 "$FX/bin/ssh-keygen"
cat > "$FX/bin/ssh-keyscan" <<EOF
#!/bin/bash
echo "ssh-keyscan \$*" >> "$FX/calls"
echo "|1|hashed|hashed ssh-ed25519 AAAAHOSTKEY"
exit 0
EOF
chmod 755 "$FX/bin/ssh-keyscan"
: > "$FX/calls"

run() {
  ( export PATH="$FX/bin:$PATH"
    export HOME="$HUBHOME"
    export STEWARD_ESTATE_ROOT="$ROOT"
    export STEWARD_CONFIG_FILE="$FX/no-such-config"
    export STEWARD_HOME_LOOKUP_CMD="$FX/bin/homelookup"
    export STEWARD_AUTHORIZED_KEYS="$HUBHOME/.ssh/authorized_keys"
    bash "$S" "$@" )
}

# -- issue, then redeem -----------------------------------------------------
out="$(run invite issue --name "Alice Example" --principal alice --entity acme --host host-a 2>&1)"
is  "the fixture can issue" "$?" "0"
link="$(printf '%s\n' "$out" | grep -o 'https://desk.example.test/desk/invite/[A-Za-z0-9_-]*' | head -1)"
TOKEN="${link##*/}"
INV="$(ls "$ROOT/invites.d" | sed 's/\.conf$//' | head -1)"

out="$(run invite redeem "$TOKEN" --identity oidc:issuer-a:SUB-1 --email alice@example.test 2>&1)"; rc=$?
is  "redeem succeeds" "$rc" "0"
has "step 1 names the invitation" "$out" "1/12"
has "step 12 closes the row" "$out" "12/12"

echo "== the rows redemption wrote =="
has "a principal row, bound to the identity" "$(cat "$ROOT/principals.d/alice.conf")" 'OIDC_LOGIN="issuer-a:SUB-1"'
has "and the display email" "$(cat "$ROOT/principals.d/alice.conf")" 'OIDC_EMAIL="alice@example.test"'
has "an account row" "$(cat "$ROOT/accounts.d/alice-host-a.conf")" 'PRINCIPAL="alice"'
has "the entity gained the member" "$(cat "$ROOT/entities.d/acme.conf")" 'MEMBERS="operator alice"'
has "a login row" "$(cat "$ROOT/logins.d/alice-claude-max.conf")" 'PROVIDER="claude-max"'
has "the login names the directory by the tilde form" "$(cat "$ROOT/logins.d/alice-claude-max.conf")" 'CONFIG_DIR="~/.claude-logins/claude-max"'
sess="$(grep -l 'SLUG="acme-alice"' "$ROOT"/sessions.d/*.conf | head -1)"
if [ -n "$sess" ]; then ok "a session row for the first session"; else bad "a session row for the first session" "none found"; fi
sid="$(basename "$sess" .conf)"
has "the session rides the login" "$(cat "$sess")" "LOGIN=\"alice-claude-max\""

echo "== the bus enrolment =="
if [ -f "$FX/home/alice/.ssh/id_busrelay_$sid" ]; then ok "a relay key under the session id"; else bad "a relay key under the session id" "missing"; fi
has "the hub carries the relay row" "$(cat "$HUBHOME/.ssh/authorized_keys")" "bus-relay-in $sid\""
has "and the row carries the estate root" "$(cat "$HUBHOME/.ssh/authorized_keys")" "STEWARD_ESTATE_ROOT=$ROOT"
has "the account carries the delivery key" "$(cat "$FX/home/alice/.ssh/authorized_keys")" "bus-relay-deliver"
has "and it is the hub's key" "$(cat "$FX/home/alice/.ssh/authorized_keys")" "AAAAHUBKEY"
has "restrict on both" "$(cat "$FX/home/alice/.ssh/authorized_keys")" "restrict,command="

echo "== the seeds the first ssh needs =="
has "the hub's host key is in known_hosts" "$(cat "$FX/home/alice/.ssh/known_hosts")" "AAAAHOSTKEY"
has "onboarding.env names the estate root" "$(cat "$FX/home/alice/onboarding.env")" "STEWARD_ESTATE_ROOT=$ROOT"
has "and the hub" "$(cat "$FX/home/alice/onboarding.env")" "STEWARD_HUB_SSH=steward@host-a"

echo "== the host-touching commands were all shims =="
calls="$(cat "$FX/calls")"
has "the helper was called through sudo -n" "$calls" "steward-account-helper add alice"
has "the skeleton was deployed" "$calls" "deploy-self host-a"
has "the desk was snapshotted" "$calls" "snapshot"

echo "== the receipt =="
R="$HUBHOME/.local/state/fixture-state/invites/$INV.receipt.json"
if [ -f "$R" ]; then ok "a receipt file was written"; else bad "a receipt file was written" "no $R"; fi
is  "the receipt is mode 600" "$(stat -c %a "$R" 2>/dev/null || stat -f %Lp "$R")" "600"
is  "the receipt is done" "$(jq -r .state "$R")" "done"
is  "the receipt carries twelve lines" "$(jq -r '.lines | length' "$R")" "12"
no  "and never the token" "$(cat "$R")" "$TOKEN"

echo "== the invitation is closed =="
has "the row is redeemed" "$(cat "$ROOT/invites.d/$INV.conf")" 'STATE="redeemed"'
has "and names the bound identity" "$(cat "$ROOT/invites.d/$INV.conf")" 'REDEEMED_LOGIN="oidc:issuer-a:SUB-1"'
no  "and still holds no token" "$(cat "$ROOT/invites.d/$INV.conf")" "$TOKEN"

echo "== the same token cannot be used twice =="
out="$(run invite redeem "$TOKEN" --identity oidc:issuer-a:SUB-2 2>&1)"; rc=$?
is  "a redeemed invitation refuses, rc 65" "$rc" "65"
has "and says which state it is in" "$out" "redeemed"
out="$(run invite redeem not-a-real-token --identity oidc:issuer-a:SUB-2 2>&1)"; rc=$?
is  "an unknown token refuses, rc 65" "$rc" "65"
out="$(run invite redeem "$TOKEN" --identity nonsense:x 2>&1)"; rc=$?
is  "an unknown identity source refuses, rc 64" "$rc" "64"

echo "== resumable: a redemption interrupted after step 4 continues, not restarts =="
out="$(run invite issue --name "Bo Example" --principal bo --entity acme --host host-a 2>&1)"
link2="$(printf '%s\n' "$out" | grep -o 'https://desk.example.test/desk/invite/[A-Za-z0-9_-]*' | head -1)"
TOKEN2="${link2##*/}"
INV2="$(grep -l 'PRINCIPAL="bo"' "$ROOT"/invites.d/*.conf | head -1)"
INV2="$(basename "$INV2" .conf)"
# Simulate an interrupted run: the first four marks are placed by hand.
mkdir -p "$FX/home/bo/.ssh"
printf 'NAME="Bo Example"\nOIDC_LOGIN="issuer-b:SUB-9"\n' > "$ROOT/principals.d/bo.conf"
printf 'PRINCIPAL="bo"\nHOST="host-a"\nUSERNAME="bo"\n' > "$ROOT/accounts.d/bo-host-a.conf"
: > "$FX/calls"
out="$(run invite redeem "$TOKEN2" --identity oidc:issuer-b:SUB-9 2>&1)"; rc=$?
is  "the resumed redemption succeeds" "$rc" "0"
has "step 2 was already done" "$out" "2/12 principal: already done"
has "step 4 was already done" "$out" "4/12 account: already done"
has "step 5 still ran" "$out" "5/12 membership:"
has "the entity gained the second member" "$(cat "$ROOT/entities.d/acme.conf")" "bo"
calls="$(cat "$FX/calls")"
no  "and nothing re-created the account" "$calls" "steward-account-helper add bo"

printf '\n  %d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
```

- [ ] **Step 2: Run test to verify it fails**
  Run: `bash test/invite-redeem.test.sh`
  Expected: FAIL with `steward invite: unknown verb 'redeem' (allowed: issue, ls, revoke)` and rc 64 where rc 0 was wanted.

- [ ] **Step 3: Write minimal implementation**

In `bin/steward`, beside the other `cmd_invite*` functions, add:

```bash
# -- REDEMPTION -------------------------------------------------------------
#
# Twelve steps, each with a MARK of its own on disk. The verb never remembers
# where it was: it ASKS, step by step, whether that step's mark is already
# there. A step that fails leaves every earlier mark standing and exits
# non-zero, and the next run continues at the first step whose mark is absent.
# That is the whole resumption design - a progress file could disagree with the
# machine, and the machine is what the next step depends on.
#
# THE FIRST SESSION IS NOT STARTED HERE. It cannot run before the person's own
# model login exists, and that is the Desk's first button, not this verb's job.

_REDEEM_LINES=""
_REDEEM_RECEIPT=""
_REDEEM_INVITE=""
_REDEEM_PRINCIPAL=""

# _redeem_note <n> <label> <text> - one receipt line, printed and recorded.
_redeem_note() {
  local line; line="$1/12 $2: $3"
  printf '%s\n' "$line"
  _REDEEM_LINES="$_REDEEM_LINES$line
"
}

# _redeem_receipt <state> - the receipt file, rewritten after every step so an
# interrupted run leaves the lines it did reach. 0700 directory, 0600 file,
# and never a token: the digest is the only thing about the link that is ever
# written down.
_redeem_receipt() {
  local state="$1"
  [ -n "$_REDEEM_RECEIPT" ] || return 0
  local dir; dir="$(dirname "$_REDEEM_RECEIPT")"
  mkdir -p "$dir" 2>/dev/null || return 0
  chmod 700 "$dir" 2>/dev/null
  local tmp; tmp="$(mktemp "$dir/.receipt.XXXXXX")" || return 0
  printf '%s' "$_REDEEM_LINES" | jq -R -s -c \
    --arg inv "$_REDEEM_INVITE" --arg p "$_REDEEM_PRINCIPAL" --arg st "$state" \
    --argjson at "$(date -u +%s)" \
    '{schemaVersion:1,invite:$inv,principal:$p,state:$st,at:$at,
      lines:(split("\n")|map(select(length>0)))}' > "$tmp" 2>/dev/null || { rm -f "$tmp"; return 0; }
  chmod 600 "$tmp" 2>/dev/null
  mv "$tmp" "$_REDEEM_RECEIPT" 2>/dev/null
  return 0
}

# _redeem_fail <msg> <rc> - a refusal that writes the receipt before it leaves.
_redeem_fail() {
  echo "steward invite redeem: $1" >&2
  _redeem_receipt failed
  return "${2:-70}"
}

# _redeem_session_id <account> <slug> - the id of the row carrying that pair,
# or nothing. A resumed run has to find the session it created LAST time; the
# id was minted then and is not derivable from anything.
_redeem_session_id() {
  local account="$1" slug="$2" d f a s
  d="$(registry_dir)"
  [ -d "$d" ] || return 1
  for f in "$d"/*.conf; do
    [ -e "$f" ] || continue
    a="$( ACCOUNT=""; source "$f" 2>/dev/null; printf '%s' "$ACCOUNT" )"
    s="$( SLUG="";    source "$f" 2>/dev/null; printf '%s' "$SLUG" )"
    [ "$a" = "$account" ] && [ "$s" = "$slug" ] || continue
    basename "$f" .conf
    return 0
  done
  return 1
}

# _redeem_validate_entity <staged-file> - the validate_fn for the MEMBERS
# update. Every field of the row is compared, not only the one that changed: a
# serializer that silently dropped MANAGED_BY or MCP_ASSETS would take a
# relation with it, and the row would still look plausible.
_redeem_validate_entity() {
  local file="$1" NAME="" MEMBERS="" MANAGED_BY="" MCP_ASSETS=""
  # shellcheck source=/dev/null
  source "$file" || { echo "registry: staged entity file did not source: $file" >&2; return 70; }
  local k got want
  for k in NAME MEMBERS MANAGED_BY MCP_ASSETS; do
    eval "got=\$$k"
    eval "want=\"\${_REGW_EXPECT_ENT_$k:-}\""
    if [ "$got" != "$want" ]; then
      echo "registry: staged entity file's $k does not match what was written: $file" >&2
      return 70
    fi
  done
  return 0
}

cmd_invite_redeem() {
  local want_json="" token="" identity="" email="" a
  for a in "$@"; do [ "$a" = "--json" ] && want_json=1; done
  while [ $# -gt 0 ]; do
    case "$1" in
      --json) shift ;;
      --identity) [ $# -ge 2 ] || { _reg_fail "$want_json" "steward invite redeem: --identity needs a value"; return 64; }
                  identity="$2"; shift 2 ;;
      --email)    [ $# -ge 2 ] || { _reg_fail "$want_json" "steward invite redeem: --email needs a value"; return 64; }
                  email="$2"; shift 2 ;;
      -*) _reg_fail "$want_json" "steward invite redeem: unknown flag '$1'"; return 64 ;;
      *) if [ -n "$token" ]; then _reg_fail "$want_json" "steward invite redeem: one token at a time"; return 64; fi
         token="$1"; shift ;;
    esac
  done
  [ -n "$token" ] || { _reg_fail "$want_json" "steward invite redeem: a token is required"; return 64; }
  [ -n "$identity" ] || { _reg_fail "$want_json" "steward invite redeem: --identity <source>:<value> is required"; return 64; }

  # THE SOURCE IS THE PART BEFORE THE FIRST COLON, AND ONLY THE FIRST. An OIDC
  # value is itself "<issuer>:<subject>", so splitting on the last colon (or on
  # every one) would hand the lookup half a subject.
  local src="${identity%%:*}" val="${identity#*:}"
  case "$src" in
    tailscale|oidc) ;;
    *) _reg_fail "$want_json" "steward invite redeem: --identity source must be tailscale or oidc, got '$src'"; return 64 ;;
  esac
  [ -n "$val" ] && [ "$val" != "$identity" ] || {
    _reg_fail "$want_json" "steward invite redeem: --identity must be <source>:<value>"; return 64; }

  # shellcheck source=lib/registry.sh
  . "$HERE/lib/registry.sh"

  # -- STEP 1: the token, the row, and the two refusals ---------------------
  local digest id
  digest="$(printf '%s' "$token" | _registry_sha256)" || return 78
  id="$(registry_invite_for_digest "$digest" 2>/dev/null)" || id=""
  if [ -z "$id" ]; then
    # THE SAME ANSWER FOR WRONG, USED AND EXPIRED. A refusal that distinguished
    # them would let anybody with a guess learn which tokens once existed.
    _reg_fail "$want_json" "steward invite redeem: no open invitation matches this token"
    return 65
  fi
  registry_invite_load "$id" >/dev/null 2>&1 || {
    _reg_fail "$want_json" "steward invite redeem: invitation '$id' does not load - repair the row"; return 78; }
  if [ "$INVITE_EFFECTIVE_STATE" != "open" ]; then
    _reg_fail "$want_json" "steward invite redeem: invitation '$id' is $INVITE_EFFECTIVE_STATE, not open"
    return 65
  fi
  local bound
  bound="$(registry_principal_for_identity "$src" "$val" 2>/dev/null)"; local brc=$?
  if [ "$brc" -eq 0 ] || [ "$brc" -eq 65 ]; then
    _reg_fail "$want_json" "steward invite redeem: the identity '$identity' already belongs to a principal${bound:+ ('$bound')} - one identity, one human"
    return 65
  fi

  local P="$INVITE_PRINCIPAL" ENT="$INVITE_ENTITY" HOSTN="$INVITE_HOST"
  local RT="$INVITE_RUNTIME" PROV="$INVITE_PROVIDER" PERSON="$INVITE_NAME"
  local ACCOUNT="$P-$HOSTN" USERNAME="$P" LOGIN="$P-$PROV" SLUG="$ENT-$P"
  _REDEEM_INVITE="$id"; _REDEEM_PRINCIPAL="$P"; _REDEEM_LINES=""
  local state_dir; state_dir="$(registry_state_dir_name)" || return 78
  _REDEEM_RECEIPT="$HOME/.local/state/$state_dir/invites/$id.receipt.json"

  # THE ONE RUNTIME THIS PATH CAN FINISH. `registry session add` writes no
  # RUNTIME line, so a codex or opencode row would come out as the default and
  # the session would run the wrong agent - a silent wrong answer. Refused
  # here, before anything is written, naming the cause.
  if [ "$RT" != "claude-code" ]; then
    _reg_fail "$want_json" "steward invite redeem: invitation '$id' names runtime '$RT', and the session writer can only finish 'claude-code' - issue the invitation with --runtime claude-code"
    return 65
  fi

  _redeem_note 1 invite "$id for $P on $HOSTN, identity $identity"
  _redeem_receipt running

  local out rc

  # -- STEP 2: the principal ------------------------------------------------
  if [ -e "$(registry_principal_dir)/$P.conf" ]; then
    _redeem_note 2 principal "already done"
  else
    local idflag="--oidc-login"
    [ "$src" = "tailscale" ] && idflag="--tailscale-login"
    if [ "$src" = "oidc" ] && [ -n "$email" ]; then
      out="$(cmd_registry_principal_add "$P" --name "$PERSON" "$idflag" "$val" --oidc-email "$email" 2>&1)"; rc=$?
    else
      out="$(cmd_registry_principal_add "$P" --name "$PERSON" "$idflag" "$val" 2>&1)"; rc=$?
    fi
    [ "$rc" -eq 0 ] || { _redeem_fail "step 2 (principal) failed: $out" "$rc"; return "$rc"; }
    _redeem_note 2 principal "principals.d/$P.conf written"
  fi
  _redeem_receipt running

  # -- STEP 3: the unix account, through the privileged helper --------------
  local home helper_out=""
  home="$(_registry_owner_home "$USERNAME" 2>/dev/null)" || home=""
  if [ -n "$home" ] && [ -d "$home" ]; then
    _redeem_note 3 account-unix "already done ($home)"
  else
    helper_out="$(sudo -n /usr/local/sbin/steward-account-helper add "$USERNAME" 2>&1)"; rc=$?
    if [ "$rc" -ne 0 ]; then
      # THE MESSAGE NAMES THE SUDOERS LINE, because the overwhelmingly likely
      # cause is that the estate has not installed it on this host, and a bare
      # "sudo failed" sends the reader to the wrong machine.
      _redeem_fail "step 3 (unix account) could not run the helper through 'sudo -n'. The estate installs exactly one line for it: steward ALL=(root) NOPASSWD: /usr/local/sbin/steward-account-helper. The helper said: $helper_out" 77
      return 77
    fi
    home="$(_registry_owner_home "$USERNAME" 2>/dev/null)" || home=""
    [ -n "$home" ] || { _redeem_fail "step 3 (unix account): the helper reported success but the account database still has no home for '$USERNAME'" 70; return 70; }
    _redeem_note 3 account-unix "$USERNAME created, home $home"
  fi
  _redeem_receipt running

  # -- STEP 4: the account row ----------------------------------------------
  if [ -e "$(registry_account_dir)/$ACCOUNT.conf" ]; then
    _redeem_note 4 account "already done"
  else
    out="$(cmd_registry_account_add "$ACCOUNT" --principal "$P" --host "$HOSTN" --username "$USERNAME" 2>&1)"; rc=$?
    [ "$rc" -eq 0 ] || { _redeem_fail "step 4 (account) failed: $out" "$rc"; return "$rc"; }
    _redeem_note 4 account "accounts.d/$ACCOUNT.conf written"
  fi
  _redeem_receipt running

  # -- STEP 5: membership of the entity -------------------------------------
  registry_entity_load "$ENT" >/dev/null 2>&1 || {
    _redeem_fail "step 5 (membership): entity '$ENT' does not load" 78; return 78; }
  case " $ENTITY_MEMBERS " in
    *" $P "*) _redeem_note 5 membership "already done" ;;
    *)
      local new_members="${ENTITY_MEMBERS:+$ENTITY_MEMBERS }$P"
      _REGW_EXPECT_ENT_NAME="$ENTITY_NAME"
      _REGW_EXPECT_ENT_MEMBERS="$new_members"
      _REGW_EXPECT_ENT_MANAGED_BY="$ENTITY_MANAGED_BY"
      _REGW_EXPECT_ENT_MCP_ASSETS="$ENTITY_MCP_ASSETS"
      local ec kv_err ent_content
      kv_err="$(mktemp)" || { _redeem_fail "step 5 (membership): cannot create a temporary file" 70; return 70; }
      ent_content="$(printf '# %s - entity, updated by steward invite redeem.\n' "$ENT")"
      for a in NAME MEMBERS MANAGED_BY MCP_ASSETS; do
        eval "ec=\"\${_REGW_EXPECT_ENT_$a:-}\""
        case "$a" in
          MANAGED_BY|MCP_ASSETS) [ -n "$ec" ] || continue ;;
        esac
        ent_content="$ent_content$(_registry_emit_kv "$a" "$ec" 2>"$kv_err")
"
      done
      rm -f "$kv_err"
      out="$(registry_entity_replace "$ENT" "$ent_content" _redeem_validate_entity 2>&1)"; rc=$?
      [ "$rc" -eq 0 ] || { _redeem_fail "step 5 (membership) failed: $out" "$rc"; return "$rc"; }
      _redeem_note 5 membership "$P added to entity $ENT"
      ;;
  esac
  _redeem_receipt running

  # -- STEP 6: the login row ------------------------------------------------
  if [ -e "$(registry_login_dir)/$LOGIN.conf" ]; then
    _redeem_note 6 login "already done"
  else
    # THE CONFIG DIRECTORY IS WRITTEN IN THE TILDE FORM the login register's own
    # resolver requires (registry_login_config_dir): the row names a directory
    # RELATIVE to the account's home, and the home is resolved at read time
    # against the account. An absolute path here would be refused by the reader.
    #
    # ACCOUNT is the provider-side name, not our slug. At redemption the person
    # has not logged in yet, so the best name we have is the one the identity
    # carries - the email when it was given, the identity value otherwise. It
    # is updatable later without moving any credentials.
    local provider_account="${email:-$val}"
    out="$(cmd_registry_login_add "$LOGIN" --principal "$P" --account "$provider_account" \
           --provider "$PROV" --config-dir "~/.claude-logins/$PROV" --legal-owner "$P" 2>&1)"; rc=$?
    [ "$rc" -eq 0 ] || { _redeem_fail "step 6 (login) failed: $out" "$rc"; return "$rc"; }
    _redeem_note 6 login "logins.d/$LOGIN.conf written"
  fi
  _redeem_receipt running

  # -- STEP 7: the first session row ----------------------------------------
  local sid
  sid="$(_redeem_session_id "$ACCOUNT" "$SLUG" 2>/dev/null)" || sid=""
  if [ -n "$sid" ]; then
    _redeem_note 7 session "already done ($sid)"
  else
    # THE REPOSITORY IS THE ACCOUNT'S OWN HOME. An invitation names no repo, and
    # the first session's workspace is the person's own machine account - the
    # one directory that exists, belongs to them, and needs no further word.
    out="$(cmd_registry_session_add --account "$ACCOUNT" --entity "$ENT" --slug "$SLUG" \
           --repo "$home" --host "$HOSTN" --login "$LOGIN" --json 2>&1)"; rc=$?
    [ "$rc" -eq 0 ] || { _redeem_fail "step 7 (session) failed: $out" "$rc"; return "$rc"; }
    sid="$(printf '%s' "$out" | jq -r '.id // empty' 2>/dev/null)"
    [ -n "$sid" ] || { _redeem_fail "step 7 (session): the writer reported success but named no id" 70; return 70; }
    _redeem_note 7 session "$sid (slug $SLUG) written"
  fi
  _redeem_receipt running

  # -- STEP 8: relay key, relay row, delivery key ---------------------------
  # The three halves of the bus enrolment the hub's own enroll performs for a
  # session that asks for itself. Here the hub does all three, because the
  # person has no shell yet and nothing on their side can ask.
  local relay_key="$home/.ssh/id_busrelay_$sid"
  local hub_ak="${STEWARD_AUTHORIZED_KEYS:-$HOME/.ssh/authorized_keys}"
  local acct_ak="$home/.ssh/authorized_keys"
  local relay_root="$HOME/scripts"
  local hub_pub="$HOME/.ssh/id_ed25519.pub"
  local have_key="" have_row="" have_deliver=""
  [ -f "$relay_key" ] && have_key=1
  grep -q "bus-relay-in $sid\"" "$hub_ak" 2>/dev/null && have_row=1
  grep -q "bus-relay-deliver" "$acct_ak" 2>/dev/null && have_deliver=1
  if [ -n "$have_key" ] && [ -n "$have_row" ] && [ -n "$have_deliver" ]; then
    _redeem_note 8 bus "already done"
  else
    # THE RELAY MUST EXIST BEFORE THE ROW NAMES IT. enroll learned this the hard
    # way: a key line naming a path that is not there kills the new session's
    # OUTBOUND channel, and the only party who can see the failure is the one
    # party who cannot report it.
    if [ ! -f "$relay_root/bus/bin/bus-relay-in" ]; then
      _redeem_fail "step 8 (bus): the relay is missing at $relay_root/bus/bin/bus-relay-in - the key line would name a path that does not exist, and the new session's outbound channel would be dead without it being able to say so" 70
      return 70
    fi
    [ -f "$hub_pub" ] || { _redeem_fail "step 8 (bus): the hub has no public key at $hub_pub, so the delivery key cannot be installed" 70; return 70; }
    if [ -z "$have_key" ]; then
      sudo -n -u "$USERNAME" ssh-keygen -q -t ed25519 -N "" -f "$relay_key" \
        -C "$HOSTN-$USERNAME-$SLUG" >/dev/null 2>&1 \
        || { _redeem_fail "step 8 (bus): could not generate the relay key at $relay_key" 70; return 70; }
    fi
    local relay_pub
    relay_pub="$(sudo -n -u "$USERNAME" cat "$relay_key.pub" 2>/dev/null)"
    [ -n "$relay_pub" ] || { _redeem_fail "step 8 (bus): could not read the relay public key at $relay_key.pub" 70; return 70; }
    if [ -z "$have_row" ]; then
      # THE LINE CARRIES THE ESTATE ROOT. sshd strips the environment from a
      # forced command, so a relay that resolved recipients through an unset
      # root would see only the hub's own rows and answer "unknown recipient"
      # for everybody else - the same fix the hub's enroll carries.
      printf 'restrict,command="STEWARD_ESTATE_ROOT=%s /bin/bash %s/bus/bin/bus-relay-in %s" %s\n' \
        "$(_registry_estate_root)" "$relay_root" "$sid" "$relay_pub" >> "$hub_ak" \
        || { _redeem_fail "step 8 (bus): could not append the relay row to $hub_ak" 70; return 70; }
    fi
    if [ -z "$have_deliver" ]; then
      printf 'restrict,command="%s/scripts/bus/bin/bus-relay-deliver" %s\n' \
        "$home" "$(cat "$hub_pub")" \
        | sudo -n -u "$USERNAME" tee -a "$acct_ak" >/dev/null \
        || { _redeem_fail "step 8 (bus): could not install the delivery key in $acct_ak" 70; return 70; }
    fi
    _redeem_note 8 bus "relay key, relay row and delivery key in place for $sid"
  fi
  _redeem_receipt running

  # -- STEP 9: the seeds the first ssh to the hub needs ---------------------
  # MEASURED ON A HOST 2026-09-08: without these the first ssh from the new
  # account to the hub fails on an unknown host key, and the skeleton deploy
  # stops there. The step was missing from the manual routine, which is why it
  # is a step here rather than a note in a document.
  local hub_host known_hosts="$home/.ssh/known_hosts" onboarding="$home/onboarding.env"
  hub_host="$(registry_hub_host)" || return 78
  local have_kh="" have_env=""
  grep -q "." "$known_hosts" 2>/dev/null && have_kh=1
  [ -f "$onboarding" ] && have_env=1
  if [ -n "$have_kh" ] && [ -n "$have_env" ]; then
    _redeem_note 9 seeds "already done"
  else
    if [ -z "$have_kh" ]; then
      ssh-keyscan -H "$hub_host" 2>/dev/null | sudo -n -u "$USERNAME" tee -a "$known_hosts" >/dev/null \
        || { _redeem_fail "step 9 (seeds): could not seed $known_hosts with the hub's host key" 70; return 70; }
    fi
    if [ -z "$have_env" ]; then
      local hub_ssh; hub_ssh="$(registry_hub_ssh)" || return 78
      printf 'STEWARD_ESTATE_ROOT=%s\nSTEWARD_HUB_HOST=%s\nSTEWARD_HUB_SSH=%s\n' \
        "$(_registry_estate_root)" "$hub_host" "$hub_ssh" \
        | sudo -n -u "$USERNAME" tee "$onboarding" >/dev/null \
        || { _redeem_fail "step 9 (seeds): could not write $onboarding" 70; return 70; }
    fi
    _redeem_note 9 seeds "known_hosts and onboarding.env written in $home"
  fi
  _redeem_receipt running

  # -- STEP 10: the rig socket directory ------------------------------------
  # The helper writes the per-account tmpfiles fragment as part of `add`, and
  # says so on its own output. This step ASKS FOR THAT SENTENCE rather than
  # reading /etc: the hub may not be the machine, and a step that guessed would
  # report a directory nobody made. When step 3 was skipped there is no output
  # to read, so the helper is called again - it is idempotent by contract.
  if [ -z "$helper_out" ]; then
    helper_out="$(sudo -n /usr/local/sbin/steward-account-helper add "$USERNAME" 2>&1)"; rc=$?
    [ "$rc" -eq 0 ] || { _redeem_fail "step 10 (rig socket directory): the helper refused: $helper_out" 70; return 70; }
  fi
  local fragment
  fragment="$(printf '%s\n' "$helper_out" | sed -n 's/^helper: tmpfiles //p' | head -1)"
  if [ -z "$fragment" ]; then
    _redeem_fail "step 10 (rig socket directory): the helper reported no tmpfiles fragment for '$USERNAME' - a rig for this account would have nowhere to put its socket" 70
    return 70
  fi
  _redeem_note 10 rig-socket-dir "$fragment"
  _redeem_receipt running

  # -- STEP 11: the skeleton, and the desk ----------------------------------
  if [ -f "$home/scripts/lib/registry.sh" ]; then
    _redeem_note 11 skeleton "already done"
  else
    out="$(bash "$HERE/linux/deploy-self.sh" "$HOSTN" 2>&1)"; rc=$?
    [ "$rc" -eq 0 ] || { _redeem_fail "step 11 (skeleton) failed: $out" "$rc"; return "$rc"; }
    _redeem_note 11 skeleton "deployed into $home/scripts"
  fi
  # THE SNAPSHOT HAS NO MARK AND RUNS EVERY TIME. It is a projection of the
  # register, cheap and idempotent, and the register changed on the step above.
  bash "$HERE/bin/steward" desk snapshot >/dev/null 2>&1 || true
  _redeem_receipt running

  # -- STEP 12: close the invitation ----------------------------------------
  _invite_load_expect "$id" >/dev/null 2>&1 || {
    _redeem_fail "step 12 (invitation): '$id' no longer loads" 78; return 78; }
  if [ "$INVITE_STATE" = "redeemed" ]; then
    _redeem_note 12 invitation "already done"
  else
    _REGW_EXPECT_INV_STATE="redeemed"
    _REGW_EXPECT_INV_REDEEMED_LOGIN="$identity"
    _REGW_EXPECT_INV_REDEEMED_AT="$(date -u +%s)"
    local content
    content="$(_invite_compose "$id")" || { _redeem_fail "step 12 (invitation): a field carries a control character" 64; return 64; }
    out="$(registry_invite_replace "$id" "$content" _invite_validate_row 2>&1)"; rc=$?
    [ "$rc" -eq 0 ] || { _redeem_fail "step 12 (invitation) failed: $out" "$rc"; return "$rc"; }
    _redeem_note 12 invitation "$id redeemed by $identity"
  fi
  _redeem_receipt done

  if [ -n "$want_json" ]; then
    _json ok true kind redeem invite "$id" principal "$P" account "$ACCOUNT" \
      login "$LOGIN" session "$sid" home "$home" receipt "$_REDEEM_RECEIPT"
  else
    printf 'steward: %s is redeemed - session %s exists and is NOT started; it starts once the person has logged in to their own model account.\n' \
      "$id" "$sid"
  fi
  return 0
}
```

Extend `cmd_invite`'s `case` with:

```bash
    redeem) shift; cmd_invite_redeem "$@" ;;
```

and its refusal text to `(allowed: issue, ls, revoke, redeem)`. Add to the usage header near line 37:

```
#   steward invite redeem <token> --identity <tailscale|oidc>:<value> [--email E] [--json]
```

- [ ] **Step 4: Run test to verify it passes**
  Run: `bash test/invite-redeem.test.sh`, then `bash test/invite-verbs.test.sh`, `bash test/registry-session-add.test.sh`, `bash test/registry-login-verb.test.sh`, `bash test/writer-census.test.sh`, then `git add test/invite-redeem.test.sh` and `PATH=/opt/homebrew/opt/node@22/bin:/opt/homebrew/bin:$PATH bash test/language.test.sh`.

- [ ] **Step 5: Commit**
  `git add bin/steward test/invite-redeem.test.sh`
  `git commit -m "feat(invite): redeem - twelve resumable steps from token to a session that exists"`

---

### Task 9: `steward offboard <principal> [--keep-home]`

**Files:**
- Modify: `bin/steward` - `cmd_offboard` and its helpers, added after `cmd_invite_redeem`; the top-level dispatch `case`; the usage header
- Test: `test/offboard.test.sh` (create)

**Interfaces:**
- Consumes: `registry_principal_load`, `registry_principal_dir`, `registry_account_dir`, `registry_account_load`, `registry_login_dir`, `registry_login_load`, `registry_login_list`, `registry_dir`, `registry_entity_dir`, `registry_entity_load`, `registry_entity_replace`, `registry_invite_list`, `registry_invite_load`, `registry_state_dir_name`, `_registry_owner_home`, `_registry_emit_kv`, `_redeem_validate_entity` (Task 8), `_reg_fail`, `_json`.
- Consumes as external commands: `sudo -n /usr/local/sbin/steward-account-helper lock <username> [--archive-home]`, `bash <product>/bin/steward desk snapshot`.
- Produces: `steward offboard <principal> [--keep-home] [--json]`.
  - rc 0 when everything is removed (or already gone); rc 64 for a malformed argument; rc 78 when the principal has no row; rc 70 when a step fails; rc 77 when `sudo -n` cannot run the helper.
  - One line per thing removed, on stdout, each `offboard: <what>`. A second run over the same principal prints `offboard: nothing left to remove` and exits 0.
  - A receipt file at `$HOME/.local/state/<STATE_DIR_NAME>/offboards/<principal>.receipt.json` (directory 0700, file 0600) with `{"schemaVersion":1,"principal":"...","state":"done|failed","at":<epoch>,"removed":[...]}`.
  - Order is the reverse of redemption: stop the work, unbind the bus, remove the rows (session, login, account, membership, principal), lock the unix account, archive the home, snapshot the desk. The invitation row is NOT touched - it stays as history at `STATE=redeemed`.

- [ ] **Step 1: Write the failing test**

Create `test/offboard.test.sh`:

```bash
#!/bin/bash
# test/offboard.test.sh - the exact reverse of a redemption, and the receipt
# that makes a rehearsal cleanable. Nothing here locks a real account: the
# helper is reached through a sudo shim that records its argv.
set -u
here="$(CDPATH= cd -- "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
pass=0; fail=0
ok()  { pass=$((pass+1)); printf '  ok   %s\n' "$1"; }
bad() { fail=$((fail+1)); printf '  FAIL %s\n     %s\n' "$1" "${2:-}"; }
is()  { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "wanted '$3', got '$2'"; fi; }
has() { case "$2" in *"$3"*) ok "$1" ;; *) bad "$1" "missing '$3' in: $2" ;; esac; }
no()  { case "$2" in *"$3"*) bad "$1" "found '$3' in: $2" ;; *) ok "$1" ;; esac; }
FX="$(mktemp -d)"; trap 'rm -rf "$FX"' EXIT
echo "offboard"

mkdir -p "$FX/product/bin" "$FX/product/lib" "$FX/product/desk"
cp "$here/bin/steward" "$FX/product/bin/steward"
cp "$here/lib/registry.sh" "$FX/product/lib/registry.sh"
chmod 755 "$FX/product/bin/steward"
cat > "$FX/product/desk/snapshot.sh" <<EOF
#!/bin/bash
echo "snapshot \$*" >> "$FX/calls"
exit 0
EOF
chmod 755 "$FX/product/desk/snapshot.sh"
S="$FX/product/bin/steward"

ROOT="$FX/estate"
mkdir -p "$ROOT/invites.d" "$ROOT/entities.d" "$ROOT/hosts.d" "$ROOT/principals.d" \
         "$ROOT/accounts.d" "$ROOT/logins.d" "$ROOT/sessions.d" "$ROOT/estate"
cat > "$ROOT/estate/steward.conf" <<'EOF'
ESTATE_NAME="acme"
STATE_DIR_NAME="fixture-state"
HUB_SESSION="host-a"
HUB_HOST="host-a"
HUB_SSH="steward@host-a"
EOF
printf 'NAME="Acme"\nMEMBERS="operator alice"\n' > "$ROOT/entities.d/acme.conf"
printf 'OWNER="operator"\nLEGAL_OWNER="Acme Ltd"\nOPERATOR="operator"\n' > "$ROOT/hosts.d/host-a.conf"
printf 'NAME="Alice"\nOIDC_LOGIN="issuer-a:SUB-1"\n' > "$ROOT/principals.d/alice.conf"
printf 'NAME="Operator"\nTAILSCALE_LOGIN="login-op@example.test"\n' > "$ROOT/principals.d/operator.conf"
printf 'PRINCIPAL="alice"\nHOST="host-a"\nUSERNAME="alice"\n' > "$ROOT/accounts.d/alice-host-a.conf"
cat > "$ROOT/logins.d/alice-claude-max.conf" <<'EOF'
PRINCIPAL="alice"
ACCOUNT="alice@example.test"
PROVIDER="claude-max"
CONFIG_DIR="~/.claude-logins/claude-max"
LEGAL_OWNER="alice"
EOF
chmod 600 "$ROOT/logins.d/alice-claude-max.conf"
SID="s-00000000000000aa"
cat > "$ROOT/sessions.d/$SID.conf" <<EOF
ID="$SID"
ACCOUNT="alice-host-a"
SLUG="acme-alice"
TARGET_ENTITY="acme"
DOMAIN="acme"
HOST="host-a"
REPO_PATH="$FX/home/alice"
OWNER="alice"
PERMISSION_MODE="bypassPermissions"
LOGIN="alice-claude-max"
EOF
# The invitation that created her - it must survive as history.
NOW="$(date -u +%s)"
cat > "$ROOT/invites.d/inv-0000000a.conf" <<EOF
NAME="Alice"
PRINCIPAL="alice"
ENTITY="acme"
HOST="host-a"
RUNTIME="claude-code"
PROVIDER="claude-max"
TOKEN_SHA256="$(printf 'x' | { if command -v sha256sum >/dev/null 2>&1; then sha256sum; else shasum -a 256; fi; } | cut -d' ' -f1)"
ISSUED_BY="operator"
ISSUED_AT="$NOW"
EXPIRES_AT="$((NOW + 86400))"
STATE="redeemed"
REDEEMED_LOGIN="oidc:issuer-a:SUB-1"
REDEEMED_AT="$NOW"
EOF
chmod 600 "$ROOT/invites.d/inv-0000000a.conf"

HUBHOME="$FX/hubhome"; mkdir -p "$HUBHOME/.ssh"
printf 'restrict,command="STEWARD_ESTATE_ROOT=%s /bin/bash %s/scripts/bus/bin/bus-relay-in %s" ssh-ed25519 AAAAALICE alice\n' \
  "$ROOT" "$HUBHOME" "$SID" > "$HUBHOME/.ssh/authorized_keys"
printf 'restrict,command="keep me" ssh-ed25519 AAAAOTHER other\n' >> "$HUBHOME/.ssh/authorized_keys"
mkdir -p "$FX/home/alice/.ssh"

mkdir -p "$FX/bin"
cat > "$FX/bin/homelookup" <<EOF
#!/bin/bash
echo "$FX/home/\$1"
EOF
chmod 755 "$FX/bin/homelookup"
cat > "$FX/bin/sudo" <<EOF
#!/bin/bash
echo "sudo \$*" >> "$FX/calls"
case "\$*" in
  *--archive-home*) rm -rf "$FX/home/alice"; echo "helper: archived /home/.offboarded/alice-2026-09-08" ;;
esac
exit 0
EOF
chmod 755 "$FX/bin/sudo"
: > "$FX/calls"

run() {
  ( export PATH="$FX/bin:$PATH"
    export HOME="$HUBHOME"
    export STEWARD_ESTATE_ROOT="$ROOT"
    export STEWARD_CONFIG_FILE="$FX/no-such-config"
    export STEWARD_HOME_LOOKUP_CMD="$FX/bin/homelookup"
    export STEWARD_AUTHORIZED_KEYS="$HUBHOME/.ssh/authorized_keys"
    bash "$S" "$@" )
}

out="$(run offboard nobody 2>&1)"; rc=$?
is  "an unknown principal is rc 78" "$rc" "78"
out="$(run offboard 'Not A Slug' 2>&1)"; rc=$?
is  "a malformed principal is rc 64" "$rc" "64"

out="$(run offboard alice 2>&1)"; rc=$?
is  "offboard succeeds" "$rc" "0"

echo "== every row is gone =="
if [ ! -e "$ROOT/sessions.d/$SID.conf" ]; then ok "the session row is removed"; else bad "the session row is removed" "still there"; fi
if [ ! -e "$ROOT/logins.d/alice-claude-max.conf" ]; then ok "the login row is removed"; else bad "the login row is removed" "still there"; fi
if [ ! -e "$ROOT/accounts.d/alice-host-a.conf" ]; then ok "the account row is removed"; else bad "the account row is removed" "still there"; fi
if [ ! -e "$ROOT/principals.d/alice.conf" ]; then ok "the principal row is removed"; else bad "the principal row is removed" "still there"; fi
is  "the membership is gone" "$(sed -n 's/^MEMBERS="\(.*\)"/\1/p' "$ROOT/entities.d/acme.conf")" "operator"
has "the invitation survives as history" "$(cat "$ROOT/invites.d/inv-0000000a.conf")" 'STATE="redeemed"'

echo "== the bus is unbound =="
ak="$(cat "$HUBHOME/.ssh/authorized_keys")"
no  "the relay row is gone" "$ak" "$SID"
has "and the other key line is untouched" "$ak" "AAAAOTHER"

echo "== the host was touched only through the helper =="
calls="$(cat "$FX/calls")"
has "the account was locked" "$calls" "steward-account-helper lock alice"
has "and the home archived" "$calls" "steward-account-helper lock alice --archive-home"
has "the desk was snapshotted" "$calls" "snapshot"

echo "== the receipt lists everything removed =="
R="$HUBHOME/.local/state/fixture-state/offboards/alice.receipt.json"
if [ -f "$R" ]; then ok "a receipt file was written"; else bad "a receipt file was written" "no $R"; fi
is  "the receipt is mode 600" "$(stat -c %a "$R" 2>/dev/null || stat -f %Lp "$R")" "600"
is  "the receipt is done" "$(jq -r .state "$R")" "done"
has "it names the session" "$(cat "$R")" "$SID"
has "it names the login" "$(cat "$R")" "alice-claude-max"
has "it names the account" "$(cat "$R")" "alice-host-a"
has "it names the principal" "$(cat "$R")" "principals.d/alice.conf"
has "it says the home was archived, not deleted" "$(cat "$R")" "archived"

echo "== a second run is a no-op =="
: > "$FX/calls"
out="$(run offboard alice 2>&1)"; rc=$?
is  "the second run is rc 0" "$rc" "0"
has "and says there was nothing left" "$out" "nothing left to remove"

echo "== --keep-home leaves the home alone =="
printf 'NAME="Bo"\nOIDC_LOGIN="issuer-b:SUB-9"\n' > "$ROOT/principals.d/bo.conf"
printf 'PRINCIPAL="bo"\nHOST="host-a"\nUSERNAME="bo"\n' > "$ROOT/accounts.d/bo-host-a.conf"
mkdir -p "$FX/home/bo"
: > "$FX/calls"
out="$(run offboard bo --keep-home 2>&1)"; rc=$?
is  "offboard --keep-home succeeds" "$rc" "0"
calls="$(cat "$FX/calls")"
has "the account is still locked" "$calls" "steward-account-helper lock bo"
no  "but the home is not archived" "$calls" "--archive-home"
if [ -d "$FX/home/bo" ]; then ok "and the home is still there"; else bad "and the home is still there" "gone"; fi

printf '\n  %d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
```

- [ ] **Step 2: Run test to verify it fails**
  Run: `bash test/offboard.test.sh`
  Expected: FAIL with `steward: unknown command '' for estate 'offboard'` and rc 64 where rc 78 and rc 0 were wanted.

- [ ] **Step 3: Write minimal implementation**

In `bin/steward`, after `cmd_invite_redeem`, add:

```bash
# -- OFFBOARDING ------------------------------------------------------------
#
# The exact reverse of a redemption, in reverse order: stop the work, unbind
# the bus, remove the rows, lock the account, archive the home. It prints one
# line per thing removed, and THAT LIST IS WHY THE VERB EXISTS - a rehearsal
# is only worth running if it can be cleaned up afterwards, and a cleanup is
# only trustworthy if it says what it did.
#
# NOTHING IRREPLACEABLE IS DELETED. The home is MOVED, by the helper, under
# /home/.offboarded; the invitation row stays exactly as it is, redeemed, as
# the history of how the person arrived. Removing either is an operator's word,
# not a verb's.

_OFFBOARD_REMOVED=""
_OFFBOARD_RECEIPT=""
_OFFBOARD_PRINCIPAL=""

_offboard_note() { # <text>
  printf 'offboard: %s\n' "$1"
  _OFFBOARD_REMOVED="$_OFFBOARD_REMOVED$1
"
}

_offboard_receipt() { # <state>
  [ -n "$_OFFBOARD_RECEIPT" ] || return 0
  local dir; dir="$(dirname "$_OFFBOARD_RECEIPT")"
  mkdir -p "$dir" 2>/dev/null || return 0
  chmod 700 "$dir" 2>/dev/null
  local tmp; tmp="$(mktemp "$dir/.receipt.XXXXXX")" || return 0
  printf '%s' "$_OFFBOARD_REMOVED" | jq -R -s -c \
    --arg p "$_OFFBOARD_PRINCIPAL" --arg st "$1" --argjson at "$(date -u +%s)" \
    '{schemaVersion:1,principal:$p,state:$st,at:$at,
      removed:(split("\n")|map(select(length>0)))}' > "$tmp" 2>/dev/null || { rm -f "$tmp"; return 0; }
  chmod 600 "$tmp" 2>/dev/null
  mv "$tmp" "$_OFFBOARD_RECEIPT" 2>/dev/null
  return 0
}

# _offboard_accounts <principal> - the account slugs belonging to the person.
# SUBSHELLED SOURCE, the same reason registry_account_slug_available gives: a
# hostile or malformed row must not overwrite this loop's own operands.
_offboard_accounts() {
  local want="$1" d f slug p
  d="$(registry_account_dir)" || return 78
  [ -d "$d" ] || return 0
  for f in "$d"/*.conf; do
    [ -e "$f" ] || continue
    slug="$(basename "$f" .conf)"
    p="$( registry_account_load "$slug" >/dev/null 2>&1 && printf '%s' "$ACCOUNT_PRINCIPAL" )"
    [ "$p" = "$want" ] && printf '%s\n' "$slug"
  done
  return 0
}

# _offboard_sessions <account-slug> - the session ids filed under that account.
_offboard_sessions() {
  local want="$1" d f a
  d="$(registry_dir)"
  [ -d "$d" ] || return 0
  for f in "$d"/*.conf; do
    [ -e "$f" ] || continue
    a="$( ACCOUNT=""; source "$f" 2>/dev/null; printf '%s' "$ACCOUNT" )"
    [ "$a" = "$want" ] && basename "$f" .conf
  done
  return 0
}

# _offboard_logins <principal> - the login slugs belonging to the person.
_offboard_logins() {
  local want="$1" slug p
  registry_login_list 2>/dev/null | while IFS= read -r slug; do
    [ -n "$slug" ] || continue
    p="$( registry_login_load "$slug" >/dev/null 2>&1 && printf '%s' "$LOGIN_PRINCIPAL" )"
    [ "$p" = "$want" ] && printf '%s\n' "$slug"
  done
  return 0
}

cmd_offboard() {
  local want_json="" principal="" keep_home="" a
  for a in "$@"; do [ "$a" = "--json" ] && want_json=1; done
  while [ $# -gt 0 ]; do
    case "$1" in
      --json) shift ;;
      --keep-home) keep_home=1; shift ;;
      -*) _reg_fail "$want_json" "steward offboard: unknown flag '$1'"; return 64 ;;
      *) if [ -n "$principal" ]; then _reg_fail "$want_json" "steward offboard: one principal at a time"; return 64; fi
         principal="$1"; shift ;;
    esac
  done
  [ -n "$principal" ] || { _reg_fail "$want_json" "steward offboard: a principal is required"; return 64; }
  if ! [[ "$principal" =~ ^[a-z][a-z0-9-]*$ ]]; then
    _reg_fail "$want_json" "steward offboard: invalid principal '$principal' (a-z, then a-z 0-9 and hyphen)"; return 64
  fi

  # shellcheck source=lib/registry.sh
  . "$HERE/lib/registry.sh"

  local pconf; pconf="$(registry_principal_dir)/$principal.conf"
  local accounts; accounts="$(_offboard_accounts "$principal")"
  if [ ! -e "$pconf" ] && [ -z "$accounts" ]; then
    _reg_fail "$want_json" "steward offboard: no such principal '$principal' - nothing to offboard"
    return 78
  fi

  _OFFBOARD_PRINCIPAL="$principal"; _OFFBOARD_REMOVED=""
  local state_dir; state_dir="$(registry_state_dir_name)" || return 78
  _OFFBOARD_RECEIPT="$HOME/.local/state/$state_dir/offboards/$principal.receipt.json"

  local acct sid sids="" username="" home="" out rc
  local hub_ak="${STEWARD_AUTHORIZED_KEYS:-$HOME/.ssh/authorized_keys}"

  # 1. STOP THE WORK, THROUGH THE HELPER. `lock` disables lingering, which
  # takes the account's user manager down and every session unit with it. It is
  # the only way the steward account can stop another person's sessions without
  # a shell in their home.
  for acct in $accounts; do
    username="$( registry_account_load "$acct" >/dev/null 2>&1 && printf '%s' "$ACCOUNT_USERNAME" )"
    [ -n "$username" ] || continue
    out="$(sudo -n /usr/local/sbin/steward-account-helper lock "$username" 2>&1)"; rc=$?
    if [ "$rc" -ne 0 ]; then
      echo "steward offboard: could not run the helper through 'sudo -n' (the estate installs: steward ALL=(root) NOPASSWD: /usr/local/sbin/steward-account-helper). The helper said: $out" >&2
      _offboard_receipt failed
      return 77
    fi
    _offboard_note "unix account $username locked, lingering disabled (its session units are down)"
  done

  # 2. UNBIND THE BUS. The relay ROW lives in the hub's own authorized_keys and
  # is ours to remove; the relay KEY and the delivery key live in the person's
  # home and travel with it into the archive.
  for acct in $accounts; do
    for sid in $(_offboard_sessions "$acct"); do
      sids="$sids $sid"
      if grep -q "bus-relay-in $sid\"" "$hub_ak" 2>/dev/null; then
        cp "$hub_ak" "$hub_ak.bak-$(date +%s)" 2>/dev/null || true
        local tmp_ak; tmp_ak="$(mktemp)" || { _offboard_receipt failed; return 70; }
        grep -v "bus-relay-in $sid\"" "$hub_ak" > "$tmp_ak" \
          || true   # grep exits 1 on an empty result, which is a valid outcome
        mv "$tmp_ak" "$hub_ak" || { _offboard_receipt failed; return 70; }
        _offboard_note "relay row for $sid removed from $hub_ak"
      fi
    done
  done

  # 3. THE ROWS, INNERMOST FIRST. A session references a login and an account;
  # removing the account first would leave a row referencing nothing, and every
  # reader in the fleet is a concurrent reader.
  for sid in $sids; do
    if [ -e "$(registry_dir)/$sid.conf" ]; then
      rm -f "$(registry_dir)/$sid.conf" || { _offboard_receipt failed; return 70; }
      _offboard_note "sessions.d/$sid.conf removed"
    fi
  done
  local lg
  for lg in $(_offboard_logins "$principal"); do
    rm -f "$(registry_login_dir)/$lg.conf" || { _offboard_receipt failed; return 70; }
    _offboard_note "logins.d/$lg.conf removed"
  done
  for acct in $accounts; do
    if [ -e "$(registry_account_dir)/$acct.conf" ]; then
      # THE HOME IS RESOLVED WHILE THE ROW STILL EXISTS. Once the account row is
      # gone there is nothing left that names the unix account, and the archive
      # step below would have nothing to ask about.
      username="$( registry_account_load "$acct" >/dev/null 2>&1 && printf '%s' "$ACCOUNT_USERNAME" )"
      home="$(_registry_owner_home "$username" 2>/dev/null)" || home=""
      rm -f "$(registry_account_dir)/$acct.conf" || { _offboard_receipt failed; return 70; }
      _offboard_note "accounts.d/$acct.conf removed"
    fi
  done

  # 4. MEMBERSHIP, in every entity that carries the person.
  local edir; edir="$(registry_entity_dir)"
  local ef eid members newm w
  for ef in "$edir"/*.conf; do
    [ -e "$ef" ] || continue
    eid="$(basename "$ef" .conf)"
    registry_entity_load "$eid" >/dev/null 2>&1 || continue
    case " $ENTITY_MEMBERS " in *" $principal "*) ;; *) continue ;; esac
    newm=""
    for w in $ENTITY_MEMBERS; do
      [ "$w" = "$principal" ] && continue
      newm="${newm:+$newm }$w"
    done
    _REGW_EXPECT_ENT_NAME="$ENTITY_NAME"
    _REGW_EXPECT_ENT_MEMBERS="$newm"
    _REGW_EXPECT_ENT_MANAGED_BY="$ENTITY_MANAGED_BY"
    _REGW_EXPECT_ENT_MCP_ASSETS="$ENTITY_MCP_ASSETS"
    local ent_content="" ec kv_err
    kv_err="$(mktemp)" || { _offboard_receipt failed; return 70; }
    ent_content="$(printf '# %s - entity, updated by steward offboard.\n' "$eid")"
    for a in NAME MEMBERS MANAGED_BY MCP_ASSETS; do
      eval "ec=\"\${_REGW_EXPECT_ENT_$a:-}\""
      case "$a" in
        MANAGED_BY|MCP_ASSETS) [ -n "$ec" ] || continue ;;
      esac
      ent_content="$ent_content$(_registry_emit_kv "$a" "$ec" 2>"$kv_err")
"
    done
    rm -f "$kv_err"
    out="$(registry_entity_replace "$eid" "$ent_content" _redeem_validate_entity 2>&1)"; rc=$?
    [ "$rc" -eq 0 ] || { echo "steward offboard: could not update entity '$eid': $out" >&2; _offboard_receipt failed; return "$rc"; }
    _offboard_note "membership of entity $eid removed"
  done

  # 5. THE PRINCIPAL.
  if [ -e "$pconf" ]; then
    rm -f "$pconf" || { _offboard_receipt failed; return 70; }
    _offboard_note "principals.d/$principal.conf removed"
  fi

  # 6. THE HOME. Archived by the helper, never deleted, and only when there is
  # still a home to archive - a resumed run must not fail on a move that has
  # already happened.
  if [ -z "$keep_home" ] && [ -n "$home" ] && [ -d "$home" ]; then
    out="$(sudo -n /usr/local/sbin/steward-account-helper lock "$username" --archive-home 2>&1)"; rc=$?
    if [ "$rc" -ne 0 ]; then
      echo "steward offboard: the helper could not archive the home: $out" >&2
      _offboard_receipt failed
      return 70
    fi
    _offboard_note "home archived, not deleted: $(printf '%s\n' "$out" | sed -n 's/^helper: archived //p' | head -1)"
  elif [ -n "$keep_home" ]; then
    _offboard_note "home kept in place (--keep-home)"
  fi

  # 7. THE INVITATION STAYS. Said out loud, because "the exact reverse" would
  # otherwise read as "the invitation goes too".
  local inv
  for inv in $(registry_invite_list 2>/dev/null); do
    ( registry_invite_load "$inv" >/dev/null 2>&1 && [ "$INVITE_PRINCIPAL" = "$principal" ] ) || continue
    _offboard_note "invitation $inv KEPT as history (state $( registry_invite_load "$inv" >/dev/null 2>&1; printf '%s' "$INVITE_STATE" ))"
  done

  bash "$HERE/bin/steward" desk snapshot >/dev/null 2>&1 || true

  if [ -z "$_OFFBOARD_REMOVED" ]; then
    printf 'offboard: nothing left to remove for %s\n' "$principal"
  fi
  _offboard_receipt done
  if [ -n "$want_json" ]; then
    _json ok true kind offboard principal "$principal" receipt "$_OFFBOARD_RECEIPT"
  fi
  return 0
}
```

In the top-level dispatch `case` (bin/steward:5097), add beside `invite)`:

```bash
  offboard) shift; cmd_offboard "$@"; exit $? ;;
```

Add to the usage header near line 37:

```
#   steward offboard <principal> [--keep-home] [--json]
```

Note on the second run: after the first offboard the principal row and the accounts are gone, so the early guard returns rc 78 - which is NOT what the second-run case wants. Make the guard fall through to a quiet success when the row is absent AND a receipt for this principal already exists:

```bash
  if [ ! -e "$pconf" ] && [ -z "$accounts" ]; then
    local state_dir_probe; state_dir_probe="$(registry_state_dir_name 2>/dev/null)" || state_dir_probe=""
    if [ -n "$state_dir_probe" ] && [ -f "$HOME/.local/state/$state_dir_probe/offboards/$principal.receipt.json" ]; then
      # ALREADY OFFBOARDED. A second run is a no-op, not a refusal: a cleanup
      # somebody re-runs to be sure must be safe to re-run.
      printf 'offboard: nothing left to remove for %s\n' "$principal"
      return 0
    fi
    _reg_fail "$want_json" "steward offboard: no such principal '$principal' - nothing to offboard"
    return 78
  fi
```

- [ ] **Step 4: Run test to verify it passes**
  Run: `bash test/offboard.test.sh`, then `bash test/invite-redeem.test.sh`, `bash test/registry-org-verbs.test.sh`, `bash test/logins-registry.test.sh`, `bash test/writer-census.test.sh`, then `git add test/offboard.test.sh` and `PATH=/opt/homebrew/opt/node@22/bin:/opt/homebrew/bin:$PATH bash test/language.test.sh`.
  Then run the whole product aggregate, which takes about 5 minutes and ends with a line beginning `suites found=`: `STEWARD_ESTATE_ROOT=<path to the estate checkout> PATH=/opt/homebrew/opt/node@22/bin:/opt/homebrew/bin:$PATH bash tools/run-tests.sh .` Every suite must read `ok`; no `RED`, no `SILENT`.

- [ ] **Step 5: Commit**
  `git add bin/steward test/offboard.test.sh`
  `git commit -m "feat(offboard): the reverse of a redemption, with a receipt of everything removed"`
