#!/bin/bash
# Assertable invariants of the deploy path: no service verbs, no home-directory
# expansion in targets, and the hub never computes a hash.
set -u
here="$(CDPATH= cd -- "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
A="$here/linux/deploy-apply.sh"
pass=0; fail=0
ok()  { pass=$((pass+1)); }
bad() { echo "FAIL: $1"; fail=$((fail+1)); }

strip() { grep -v '^\s*#' "$1"; }   # comments may mention anything at all

# 1. The only systemctl verb is daemon-reload. Anything that starts, stops or
# enables a unit would make a deploy an operational action, and a deploy that
# restarts services cannot be run safely while sessions are live.
if strip "$A" | grep -E 'systemctl|SYSTEMCTL' | grep -Ev 'daemon-reload|STEWARD_DEPLOY_SYSTEMCTL' | grep -Eq 'restart|stop|start|enable|disable'; then
  bad "forbidden systemctl verb in apply"; else ok; fi

# 2. No ~ or $HOME in target path construction inside apply. The executor runs
# as root, so a tilde would expand to root's home rather than the target user's
# — writing the fleet's files into the wrong place with full privileges.
#
# (The awk idiom !~ (does-not-match) contains a tilde for an entirely different
# reason, e.g. `$1!~/^#/` in the last-good filter. Only the TOKEN !~ is removed
# from the stream before the tilde search — character-precise, not line-coarse,
# so a genuine tilde violation sharing a line with an awk !~ operator is still
# caught.)
# ANCHORED. The pattern used to be a bare \$HOME, which also matched
# $HOME_ROOT — a different variable, holding a path the caller passed in
# explicitly. A guard that cannot tell a variable from a variable's prefix
# reports the safe case as the dangerous one, and a guard that cries wolf is
# turned off. \b after HOME excludes $HOME_ROOT and $HOMES while still
# catching $HOME and ${HOME}.
if strip "$A" | grep -qE '\$\{?HOME\}?\b'; then bad 'apply uses $HOME'; else ok; fi
if strip "$A" | sed 's/!~//g' | grep -q '"\~\|~/' ; then bad "apply uses ~"; else ok; fi

# 3. The hub never computes a hash. Whoever computes the hash can also lie about
# the result, so the measurement belongs on the host that is being changed.
# Skipped when the hub's entry point is not part of this checkout — it is estate
# code, named by the estate, and the estate's own suite asserts the same
# invariant. STEWARD_HUB_ENTRY names it when there is one to check.
B="${STEWARD_HUB_ENTRY:-}"
if [ -f "$B" ] && strip "$B" | sed -n '/deploy)/,/;;/p' | grep -Eq 'md5|md5sum|shasum'; then
  bad "the hub computes a hash"; else ok; fi

# 4. bash 3.2 prohibitions. This code has to run on hosts whose default bash is
# 3.2, where associative arrays, readarray/mapfile, find -printf and grep -P do
# not exist. A construct that works only on the developer's machine is a latent
# failure on every other one.
if [ -f "$B" ] && strip "$B" | grep -Eq 'declare -A|readarray|mapfile|find [^|]*-printf|grep -P'; then
  bad "bash 3.2-forbidden construct in the hub entry point"; else ok; fi
# 4b. The same prohibitions in the core. It went ungated when the core was
# lifted out of the hub, which matters MORE rather than less now that the host
# path sources the same file: a fault there is a fault in BOTH entry points at
# once.
L="$here/lib/deploy-core.sh"
if [ -f "$L" ] && strip "$L" | grep -Eq 'declare -A|readarray|mapfile|find [^|]*-printf|grep -P'; then
  bad "bash 3.2-forbidden construct in lib/deploy-core.sh"; else ok; fi

# 5. THE WRITE IS GENUINELY ATOMIC, not atomic by the grace of one install
# implementation.
#
# Measured on a Linux host (GNU coreutils 9.4): `install` over an existing file
# truncates it in the SAME inode. BSD's install (macOS) renames instead — and so
# the entire fixture suite was green while the deploy could not succeed even
# once against a Linux host, because the post-check required an inode change
# that never happened. A test that only runs on the developer's platform
# measures the developer's platform.
#
# The invariant is therefore asserted about the FORM of the code rather than the
# behaviour of the environment:
if strip "$A" | grep -Eq '^[[:space:]]*install .*"\$dst"[[:space:]]*(\||\|\||&&|;|$)'; then
  bad 'install writes directly to "$dst" — it must go via a sibling name plus mv (install truncates in place on GNU)'
else ok; fi
if strip "$A" | grep -q 'mv -f "$tmp_dst" "$dst"'; then ok; else
  bad 'the rename step is missing — without it the inode does not change and the post-check can never pass on GNU'; fi

echo "pass=$pass fail=$fail"
[ "$fail" -eq 0 ]
