#!/bin/bash
# Assertable invariants of the deploy path: no service verbs, no home-directory
# expansion in targets, and the hub never computes a hash.
set -u
here="$(CDPATH= cd -- "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
A="$here/linux/deploy-apply.sh"
pass=0; fail=0
ok()  { pass=$((pass+1)); }
bad() { echo "FAIL: $1"; fail=$((fail+1)); }

# [[:space:]] AND NOT \s. `\s` is a GNU extension; BSD grep - which is the grep on
# the very platform this file exists to protect - does not promise it. It went
# unnoticed while the sweep below covered two files, neither of which had a comment
# naming a forbidden construct. The moment the sweep widened to the whole tree it
# would have matched the comments that forbid mapfile and turned the PORTABILITY
# GUARD into a false failure ON DARWIN ONLY.
strip() { grep -v '^[[:space:]]*#' "$1"; }   # comments may mention anything at all

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

# 4. bash 3.2 prohibitions, OVER EVERY SHELL FILE IN THE TREE. This code has to
# run on hosts whose default bash is 3.2, where associative arrays,
# readarray/mapfile, find -printf and grep -P do not exist. A construct that works
# only on the developer's machine is a latent failure on every other one.
#
# THIS USED TO NAME TWO FILES, and that is why it is written this way now. The rule
# above was stated universally and enforced on the hub entry point and
# lib/deploy-core.sh - so every file added after the check was written was exempt in
# silence. desk/apply.sh was written months later with two mapfile calls in it, the
# whole suite was green on Linux, and the defect was found by a NEIGHBOUR'S MACHINE
# after a full darwin run: 5 passed, 20 failed, nineteen of them downstream of the
# first. A guard whose subject is a hand-kept list does not grow with the tree, and
# its coverage shrinks every time the tree does grow.
#
# THE SWEEP IS CHEAP AND THE TREE WAS ALREADY CLEAN. Measured, and the number is
# written with its lens and its tree because it cannot be re-taken without them - the
# first version of this comment said "193 shell files" and that was a third lens at a
# fourth moment, before the widening's own commits added files:
#
#   194 (union of *.sh and a shell shebang, 07c28d9)   what this loop walks
#   194 actually swept                                 this file is exempt, see below
#   177 (*.sh only, 07c28d9)                           a different question
#   194 (file --mime-type, 07c28d9)                    a third
#
# Of those: two real hits, both in desk/apply.sh; four comments that name the
# constructs in order to forbid them; two self-references in this file's own pattern.
# Widening cost nothing because the rule had been followed everywhere a person
# happened to remember it - which is exactly why nobody noticed the enforcement had
# stopped growing.
#
# WHAT IT STILL DOES NOT CATCH, said here so nobody reads this as complete: the other
# half of the same darwin failure was "${arr[@]}" on an EMPTY array under `set -u`,
# which 3.2 treats as an unbound variable rather than an empty word list. That is not
# a construct, it is a state, and no grep can see it. Only running on 3.2 can.
_b32_files() {
  # git ls-files when this is a checkout, find otherwise - and neither -printf nor
  # -regex, which are the very extensions being forbidden here.
  if command -v git >/dev/null 2>&1 && [ -d "$here/.git" ]; then
    ( cd "$here" && git ls-files )
  else
    ( cd "$here" && find . -type f | sed 's|^\./||' )
  fi
}
b32_hits=""
# `while IFS= read -r` AND NOT `for _rel in $(...)`. Word splitting on the listing
# breaks a path containing a space into pieces that each fail `[ -f ]` below and are
# skipped WITHOUT A WORD - which is the same failure this whole check exists to
# remove: coverage that quietly stops including something when a person does an
# ordinary thing. Measured when this was written: 0 of 194 tracked paths (union of
# *.sh and a shell shebang, 07c28d9) contain whitespace, so the fault was latent and
# not active. That is a reason to fix it cheaply, not a reason to leave it: the first
# path with a space in it would have been skipped silently, and a guard that is
# silent about what it did not read is worse than one that was never widened.
#
# The here-document is the house's own form for this, for the house's own reason:
# bash 3.2 has no mapfile, which is the construct this very check forbids.
while IFS= read -r _rel; do
  [ -n "$_rel" ] || continue
  _f="$here/$_rel"
  [ -f "$_f" ] || continue
  # THIS FILE IS EXEMPT, and the reason is not convenience: it must contain the
  # forbidden words in order to forbid them, so a sweep that included it would always
  # fail. It needs no static check of its own because it is EXECUTED on both
  # platforms - a bash 4 construct in here does not go unnoticed, it kills the guard
  # on darwin, which is a louder signal than the one this loop produces.
  case "$_rel" in test/deploy-policy.test.sh) continue ;; esac
  # A SHELL FILE IS ONE THAT SAYS SO. Extension or shebang - `file --mime-type` is
  # not portable enough to be the thing a portability guard depends on.
  case "$_rel" in
    *.sh) : ;;
    *) head -1 "$_f" 2>/dev/null | grep -q '^#!.*\(ba\)\?sh' || continue ;;
  esac
  if strip "$_f" | grep -Eq 'declare -A|readarray|mapfile|find [^|]*-printf|grep -P'; then
    b32_hits="$b32_hits $_rel"
  fi
done <<EOF
$(_b32_files)
EOF
if [ -n "$b32_hits" ]; then
  bad "bash 3.2-forbidden construct in:$b32_hits"; else ok; fi

# 4b. AND THE PATTERN STILL MATCHES A KNOWN VIOLATION. A sweep that finds nothing and
# a sweep that CANNOT find anything print the same zero, and the second is the shape
# that let desk/apply.sh through. Consistent numbers are not a check: what makes this
# one a check is that the line below MUST match, so an edit that breaks the alternation
# turns the silence into a failure instead of into a pass.
#
# WHAT THIS COVERS AND WHAT IT DOES NOT. It guards the PATTERN, which is the part most
# likely to rot under editing. It does not guard the FILE WALK above - that was
# verified by hand when the sweep was widened, by appending a mapfile line to
# desk/fetch.sh and confirming the guard named that file and went red (pass=6 fail=1),
# then restoring it and confirming green (pass=7 fail=0). That check is a person's,
# not the suite's, and saying so is the point.
if printf 'mapfile -t x < <(echo y)\n' | grep -Eq 'declare -A|readarray|mapfile|find [^|]*-printf|grep -P'; then
  ok; else bad "the bash 3.2 pattern no longer matches a known violation"; fi

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
