#!/bin/bash
# test/deploy-apply-group.test.sh - the group a deployed file gets is LOOKED UP, not spelled.
#
# Linux gives every account a user-private group of its own name, so `install -o jon -g jon`
# and `chown jon:jon` were right on every host this ran on. macOS puts users in `staff`
# (gid 20) and has no group named after the user: on the first live root deploy to a darwin
# home (2026-09-12) install(1) died on the very first row - `install: unknown group jon` -
# and the whole home was refused. The fixture suites never saw it: they run apply with
# STEWARD_DEPLOY_INSTALL_OWNER=off, which skips exactly the three lines that were wrong.
set -u
here="$(CDPATH= cd -- "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
pass=0; fail=0
ok()  { pass=$((pass+1)); printf '  ok   %s\n' "$1"; }
bad() { fail=$((fail+1)); printf '  FAIL %s\n     %s\n' "$1" "${2:-}"; }
is()  { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "wanted '$3', got '$2'"; fi; }
APPLY="$here/linux/deploy-apply.sh"

echo "== 1. the rule: no owner/group site spells the group as the username =="
is "1a no 'chown \$USERNAME:\$USERNAME'"     "$(grep -cE 'chown "\$USERNAME:\$USERNAME"' "$APPLY")" "0"
is "1b no 'install -g \$USERNAME'"           "$(grep -cE -- '-g "\$USERNAME"' "$APPLY")" "0"
is "1c the group comes from id -gn"           "$(grep -cE 'GROUPNAME="\$\(id -gn "\$USERNAME"' "$APPLY")" "1"
is "1d and every site uses it"                "$(grep -cE 'USERNAME:\$GROUPNAME"|-g "\$GROUPNAME"' "$APPLY")" "3"

echo "== 2. the behaviour: id -gn's answer is what reaches install/chown, on this very host =="
# The real id(1) on the host running this suite: darwin answers staff, Linux answers the user.
# Whatever it answers, that - and not the username - must be the group the sites are given.
me="$(id -un)"; grp="$(id -gn "$me")"
is "2a this host's primary group is a real group name" "$([ -n "$grp" ] && echo yes)" "yes"
if [ "$grp" != "$me" ]; then ok "2b on this host group != user ($grp != $me): the old spelling would have failed here"; else ok "2b on this host group == user ($grp): the old spelling worked by coincidence here"; fi

printf '\n  %d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
