#!/bin/bash
# test/registry-word-in-list.test.sh - the shared membership helper, and the five
# gates that hang on it.
#
# WHY ITS OWN SUITE. `_registry_word_in_list` is one function with five callers,
# and until 2026-09-09 it was `case " $list " in *" $w "*` - a substring test
# over a space-separated RUN, not membership. A needle naming two adjacent
# entries matched both at once: `claude-max claude-team` passed the provider
# check and `unix-account desk-oidc` passed the mandate register's accept-channel
# check, both rc 0. The hole was found in the mandate register and traced back
# here, which is where it always was.
#
# THREE OF THE FIVE CALLERS GATE WHO MUST NAME A MODEL ACCOUNT before a session,
# a job or a service may run (LOGIN_REQUIRED_FOR). With the old form a required
# list `alice bob` was matched by an "owner" literally called `alice bob`, and an
# owner `b c` passed a list `a b c d`. Neither is reachable through today's name
# grammar - slugs carry no spaces - which is exactly the "unlikely until someone
# edits the register by hand" that the RC-label duplicate turned out to be the
# same morning. The property is asserted here rather than argued.
#
# AND THE NORMAL PATHS ARE PROVEN UNCHANGED, per call site: changing a helper
# four other gates depend on has to be shown harmless, not assumed.
set -u
here="$(CDPATH= cd -- "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
. "$here/lib/registry.sh"
pass=0; fail=0
ok()  { pass=$((pass+1)); printf '  ok   %s\n' "$1"; }
bad() { fail=$((fail+1)); printf '  FAIL %s\n     %s\n' "$1" "${2:-}"; }
yes() { if _registry_word_in_list "$2" "$3"; then ok "$1"; else bad "$1" "wanted a match for '$2' in '$3'"; fi; }
no()  { if _registry_word_in_list "$2" "$3"; then bad "$1" "'$2' matched '$3' and should not have"; else ok "$1"; fi; }
echo "registry-word-in-list"

echo "== a member is a member =="
yes "the first entry"            a          "a b c d"
yes "an entry in the middle"     c          "a b c d"
yes "the last entry"             d          "a b c d"
yes "a one-entry list"           only       "only"
yes "an entry with hyphens"      claude-max "claude-max claude-team opencode-chatgpt codex-openai"

echo "== a run of two entries is NOT one entry - the hole this suite exists for =="
no  "two adjacent entries"       "a b"      "a b c d"
no  "two more, further in"       "b c"      "a b c d"
no  "the whole list as a needle" "a b c d"  "a b c d"
no  "two real providers"         "claude-max claude-team" "claude-max claude-team opencode-chatgpt codex-openai"
no  "any needle carrying a space" "a  b"    "a b c d"
no  "a needle that is only space" " "       "a b c d"
no  "a needle with a tab"        "$(printf 'a\tb')" "a b c d"

echo "== a prefix or suffix of an entry is not the entry =="
no  "a prefix of an entry"       cla        "claude-max claude-team"
no  "a suffix of an entry"       max        "claude-max claude-team"
no  "an entry with a character added" claude-maxx "claude-max claude-team"
no  "a needle that is a substring spanning a boundary" "x-team" "claude-max claude-team"

echo "== emptiness matches nothing, in either position =="
no  "an empty needle in a list"  ""         "a b c d"
no  "an empty needle in an empty list" ""   ""
no  "a real needle in an empty list" a      ""
no  "an empty needle in a one-entry list" "" "only"

echo "== the split is THIS function's, not the caller's =="
# Measured 2026-09-10 on bash 3.2: a caller wrote `IFS=$'\t' read -r a b c
# <<<"$(fn)"`, and on 3.2 that temporary assignment is VISIBLE inside the
# substitution (it is not on 5.x). Everything the substitution called then ran
# with IFS=TAB, `for e in $list` stopped splitting a space-separated list, the
# provider check refused a value it was listing as allowed, and eighteen
# assertions in another suite failed one register away from the cause. The
# helper pins its own IFS now, so no caller's state can answer this question -
# and this property IS measurable on bash 5, which does not leak.
# NOT `( IFS=...; yes ... )` - a subshell keeps its own copy of the counters, so
# every assertion inside one is invisible to the summary and a FAILURE there is
# lost silently. Measured on the first version of this block: four assertions
# ran and the count did not move. IFS is saved and restored instead.
_ifs_was="$IFS"
IFS=$'\t'; yes "with IFS=TAB a space-separated list still splits" claude-team "$_REGISTRY_LOGIN_PROVIDERS"
IFS=$'\t'; no  "...and a two-entry value is still refused"        "claude-max claude-team" "$_REGISTRY_LOGIN_PROVIDERS"
IFS=,;      yes "with IFS=comma too"                               desk-oidc "$_REGISTRY_MANDATE_ACCEPT_CHANNELS"
IFS=;       yes "and with IFS set empty"                           unix-account "$_REGISTRY_MANDATE_ACCEPT_CHANNELS"
IFS="$_ifs_was"

echo "== the five call sites' NORMAL paths are unchanged =="
# Each line is the exact question its call site asks, with the values that site
# really uses. These are what would break if the helper got stricter than
# membership.
yes "logins.d PROVIDER: a real provider is accepted"   claude-team  "$_REGISTRY_LOGIN_PROVIDERS"
no  "logins.d PROVIDER: an unknown one is not"         claude-pro   "$_REGISTRY_LOGIN_PROVIDERS"
yes "mandates.d ACCEPT_SOURCE: unix-account is a channel"  unix-account "$_REGISTRY_MANDATE_ACCEPT_CHANNELS"
yes "mandates.d ACCEPT_SOURCE: desk-oidc is a channel"     desk-oidc    "$_REGISTRY_MANDATE_ACCEPT_CHANNELS"
no  "mandates.d ACCEPT_SOURCE: the bus is not"             bus          "$_REGISTRY_MANDATE_ACCEPT_CHANNELS"
yes "mandates.d SCOPE: beneficiary is a key"           beneficiary  "$_REGISTRY_MANDATE_SCOPE_KEYS"
yes "mandates.d RESERVE: hard-cap is a key"            hard-cap     "$_REGISTRY_MANDATE_RESERVE_KEYS"
# The three LOGIN_REQUIRED_FOR gates: an owner in the required list, and one not.
yes "LOGIN_REQUIRED_FOR: a listed principal is required to name a login"     alice "alice bob"
yes "LOGIN_REQUIRED_FOR: the second listed principal too"                    bob   "alice bob"
no  "LOGIN_REQUIRED_FOR: an unlisted principal is not"                       carol "alice bob"
no  "LOGIN_REQUIRED_FOR: a 'principal' spanning two names is not one of them" "alice bob" "alice bob"

echo
printf '%s passed, %s failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
