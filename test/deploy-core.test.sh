#!/bin/bash
# test/deploy-core.test.sh — lib/deploy-core.sh tested DIRECTLY, with neither a
# hub nor a host. The core is shared by both entry points; a fault here is a
# fault in both paths at once, which is precisely why it is tested on its own.
set -uo pipefail
# pipefail HERE deliberately: the callers run with the same flag, and the first
# finding below (grep -v returns 1 on a manifest with no non-comment rows) is
# only visible if the test shell shares it — a test without pipefail would not
# have measured the thing that broke.
here="$(CDPATH= cd -- "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
pass=0; fail=0
ok(){ pass=$((pass+1)); }
bad(){ echo "FAIL: $1"; fail=$((fail+1)); }
check(){ d="$1"; shift; if "$@"; then ok; else bad "$d"; fi; }

. "$here/lib/deploy-core.sh"

echo "== the home list from the registry =="
fx="$(mktemp -d)"; mkdir -p "$fx/sessions.d"
printf 'HOST="host-one"\nOWNER="alfa"\nDOMAIN="d"\n'     > "$fx/sessions.d/a.conf"
printf 'HOST="host-one"\nOWNER="beta"\nDOMAIN="d"\n' > "$fx/sessions.d/b.conf"
printf 'HOST="host-one"\nOWNER="alfa"\nDOMAIN="d"\n'     > "$fx/sessions.d/c.conf"
printf 'HOST="host-two"\nOWNER="gamma"\nDOMAIN="d"\n'      > "$fx/sessions.d/d.conf"
h="$(deploy_home_list "$fx/sessions.d" host-one)"; rc=$?
check "home list rc 0"                      [ "$rc" -eq 0 ]
check "two homes, not three (dedup by owner)" [ "$(printf '%s' "$h" | wc -w | tr -d ' ')" -eq 2 ]
case "$h" in *"/home/alfa"*)     ok ;; *) bad "alfa is missing: $h" ;; esac
case "$h" in *"/home/beta"*) ok ;; *) bad "beta is missing: $h" ;; esac
case "$h" in *"/home/gamma"*)   bad "another host's home leaked in: $h" ;; *) ok ;; esac

h="$(deploy_home_list "$fx/sessions.d" doesnotexist 2>/dev/null)"; rc=$?
check "an unknown host gives rc 78" [ "$rc" -eq 78 ]

echo "== the sources from the manifest =="
printf '# a comment\nlinux/a.sh  bin/a  755  bin\nlinux/b.sh  bin/b  644  bin\n' > "$fx/manifest"
k="$(deploy_manifest_sources "$fx/manifest")"; rc=$?
check "sources rc 0"       [ "$rc" -eq 0 ]
check "two sources"        [ "$(printf '%s\n' "$k" | grep -c .)" -eq 2 ]
case "$k" in *"#"*) bad "the comment came through" ;; *) ok ;; esac
deploy_manifest_sources "$fx/does-not-exist" >/dev/null 2>&1; rc=$?
check "a missing manifest gives rc 65" [ "$rc" -eq 65 ]

echo "== sources: an empty result is not an error under pipefail (FINDING 1) =="
# grep -v returns 1 when NO row survives — comments-only and zero bytes are both
# valid, empty manifests, not errors. Without an explicit "return 0" in
# deploy_manifest_sources, the pipefail shell's rc for the function becomes
# grep -v's, and a valid deploy would abort with rc 1 and no diagnosis at all.
printf '# comments only\n# more comments\n' > "$fx/comments-only"
k="$(deploy_manifest_sources "$fx/comments-only")"; rc=$?
check "comments only: rc 0"        [ "$rc" -eq 0 ]
check "comments only: empty output" [ -z "$k" ]

: > "$fx/zero-byte"
k="$(deploy_manifest_sources "$fx/zero-byte")"; rc=$?
check "0-byte manifest: rc 0"        [ "$rc" -eq 0 ]
check "0-byte manifest: empty output" [ -z "$k" ]
# CONTROL GROUP (above, "sources rc 0"/"two sources"): a manifest WITH rows
# still yields its rows and rc 0 — that branch must not have been disturbed.

echo "== the stage =="
mkdir -p "$fx/repo/linux"
printf 'a\n' > "$fx/repo/linux/a.sh"; printf 'b\n' > "$fx/repo/linux/b.sh"
printf 'apply\n' > "$fx/apply.sh"
s="$(deploy_stage "$fx/repo" "$fx/manifest" "$fx/apply.sh" linux/a.sh linux/b.sh)"; rc=$?
check "stage rc 0"                     [ "$rc" -eq 0 ]
check "stage: the manifest was copied" [ -f "$s/deploy-manifest" ]
check "stage: apply was copied"        [ -f "$s/deploy-apply.sh" ]
check "stage: the source under src/"   [ -f "$s/src/linux/a.sh" ]
check "stage: both sources"            [ -f "$s/src/linux/b.sh" ]
case "$s" in /tmp/*|/var/folders/*) ok ;; *) bad "the stage is not in a temp directory: $s" ;; esac
# A PREDICTABLE NAME IS A ROOT VULNERABILITY: the stage is executed as root, so
# a name a local user could pre-create or symlink is an invitation.
s2="$(deploy_stage "$fx/repo" "$fx/manifest" "$fx/apply.sh" linux/a.sh)"
check "two stages get different names" [ "$s" != "$s2" ]
rm -rf "$s" "$s2"

deploy_stage "$fx/repo" "$fx/manifest" "$fx/apply.sh" linux/does-not-exist.sh >/dev/null 2>&1; rc=$?
check "a missing source gives rc 70" [ "$rc" -eq 70 ]

# THE MANIFEST AND APPLY COPIES WERE UNCHECKED, unlike the source copy above. A
# silent cp failure there left a stage that REPORTED rc 0 with no manifest or no
# apply script — the caller's sudo -n then gave 127, which was read as "sudo
# denied or missing". The wrong machine took the blame for a file error.
u="$(deploy_stage "$fx/repo" "$fx/manifest-does-not-exist" "$fx/apply.sh" linux/a.sh 2>&1)"; rc=$?
check "a missing manifest gives rc 70, not a silent rc 0" [ "$rc" -eq 70 ]
case "$u" in *"manifest"*) ok ;; *) bad "the target name is missing from the error: $u" ;; esac

u="$(deploy_stage "$fx/repo" "$fx/manifest" "$fx/apply-does-not-exist.sh" linux/a.sh 2>&1)"; rc=$?
check "a missing apply gives rc 70, not a silent rc 0" [ "$rc" -eq 70 ]
case "$u" in *"apply"*) ok ;; *) bad "the target name is missing from the error: $u" ;; esac

echo "== clean sources (uncommitted changes) =="
# THE HOST PATH NEEDS THE SAME GATE: deploy_sources_clean must live in the core
# so the host's entry point gets the same dirty-source refusal as the hub —
# otherwise only ONE of the two paths guards against deploying uncommitted
# content.
rk="$fx/cleanrepo"; mkdir -p "$rk/linux"
( cd "$rk" && git init -q && git config user.email p@p && git config user.name p )
printf 'source\n' > "$rk/linux/source.sh"
printf 'unrelated\n' > "$rk/unrelated.txt"
( cd "$rk" && git add -A && git commit -qm init )

# CONTROL GROUP: everything committed => rc 0. Without this case the gate is a
# blockade rather than a gate.
deploy_sources_clean "$rk" linux/source.sh; rc=$?
check "clean sources: a clean tree gives rc 0" [ "$rc" -eq 0 ]

# PROVOKE THE FAULT: a committed source is modified without being committed.
printf 'changed\n' >> "$rk/linux/source.sh"
u="$(deploy_sources_clean "$rk" linux/source.sh 2>&1)"; rc=$?
check "clean sources: a dirty source gives rc 65" [ "$rc" -eq 65 ]
case "$u" in *"linux/source.sh"*) ok ;; *) bad "the file name is missing from the error: $u" ;; esac
( cd "$rk" && git checkout -q -- linux/source.sh )

# THE GATE GUARDS THE SOURCES, NOT THE WORKING TREE: a dirty file that is not a
# manifest source must not fail the gate.
printf 'an unrelated change\n' >> "$rk/unrelated.txt"
deploy_sources_clean "$rk" linux/source.sh; rc=$?
check "clean sources: a dirty non-source has no effect" [ "$rc" -eq 0 ]

# THE EMPTINESS GUARD BELONGS IN THE FUNCTION: a call with NO sources against a
# dirty tree must give rc 0, not 65 — `git status --porcelain --` without path
# arguments is a whole-tree check, and the tree IS dirty here (an unrelated file
# was modified above). A guard every caller must remember to set is exactly the
# kind of mistake that left this gate out of the core to begin with.
deploy_sources_clean "$rk"; rc=$?
check "clean sources: no sources against a dirty tree gives rc 0" [ "$rc" -eq 0 ]
( cd "$rk" && git checkout -q -- unrelated.txt )

# THE SYMLINK CASE FOR THE HUB CLI LIVES IN THE ESTATE. It asserts that the
# hub's own entry point resolves its symlink before locating this core — and
# that entry point is estate code, not product code. Testing it from here would
# mean the product asserting on a file it does not own. Moved to the estate's
# suite (the estate's own deploy suite) 2026-08-19; the equivalent case for
# deploy-self.sh, which IS product, stays in test/deploy-self.test.sh.


echo "== provenance =="
r="$fx/gitrepo"; mkdir -p "$r"
( cd "$r" && git init -q && git config user.email p@p && git config user.name p \
  && printf 'x\n' > f && git add f && git commit -qm x )
deploy_check_provenance "$r" >/dev/null 2>&1; rc=$?
check "no origin: REFUSAL 65, not a silent pass" [ "$rc" -eq 65 ]

# THE GATE READS ORIGIN AND WRITES NOTHING.
#
# It used to open with `git fetch`, and fetch writes .git/FETCH_HEAD. A checkout
# that is readable but NOT WRITABLE therefore failed for a reason with nothing to
# do with provenance — and the message blamed the remote. MEASURED 2026-08-19 on
# a product checkout shared read-only between two tenants on one machine:
#
#   git fetch origin           ->  cannot open '.git/FETCH_HEAD': Permission
#                                  denied                              (rc 255)
#   git ls-remote origin main  ->  rc 0, prints the sha
#
# THE CONTROL GROUP IS THE WHOLE POINT: a clean, up-to-date checkout whose
# DIRECTORY IS READ-ONLY must PASS. Without this case the change is invisible —
# the suite was green both before and after it, because every other fixture is
# writable and never exercised the difference.
#
# Skipped when running as root, and loudly: root writes through a 0555
# directory, so the fixture would prove nothing and a silent skip would look
# exactly like a pass.
echo "== provenance: a READ-ONLY checkout passes =="
ro="$fx/ro"; mkdir -p "$ro"
( cd "$ro" && git init -q -b main && git config user.email p@p && git config user.name p \
  && printf 'x\n' > f && git add f && git commit -qm x )
git init -q --bare -b main "$fx/ro-origin.git"
( cd "$ro" && git remote add origin "$fx/ro-origin.git" && git push -q origin main )
if [ "$(id -u)" -eq 0 ]; then
  echo "  SKIPPED: running as root — a 0555 directory does not stop root, so the"
  echo "  fixture cannot measure what it claims. Not counted as a pass."
else
  chmod -R a-w "$ro/.git"
  deploy_check_provenance "$ro" >/dev/null 2>&1; rc=$?
  chmod -R u+w "$ro/.git"
  check "read-only checkout, clean and current: rc 0" [ "$rc" -eq 0 ]
  # AND THE GATE STILL REFUSES what it should: read-only must not become a
  # blanket pass. The same directory, one commit ahead of its origin, must fail.
  ( cd "$ro" && printf 'y\n' > g && git add g && git commit -qm y )
  chmod -R a-w "$ro/.git"
  u="$(deploy_check_provenance "$ro" 2>&1)"; rc=$?
  chmod -R u+w "$ro/.git"
  check "read-only checkout, one commit AHEAD: rc 65" [ "$rc" -eq 65 ]
  case "$u" in *AHEAD*) ok ;; *) bad "the refusal does not say AHEAD: $u" ;; esac
fi

# NO fetch ANYWHERE IN THE CORE. The read-only case above would keep passing if
# somebody reintroduced a fetch guarded by a conditional, so the prohibition is
# asserted about the FORM of the code as well as its behaviour.
if grep -vE '^\s*#' "$here/lib/deploy-core.sh" | grep -Eq 'git .*fetch'; then
  bad "the core fetches — that writes to the checkout and breaks a read-only product"; else ok; fi
rm -rf "$fx"

echo "== policy: the core must not carry the hub's concerns =="
if grep -vE '^\s*#' "$here/lib/deploy-core.sh" | grep -Eq '(^|[^a-z])(ssh|scp)($|[^a-z])'; then
  bad "the core contains ssh/scp — transport belongs to the caller"; else ok; fi
if grep -vE '^\s*#' "$here/lib/deploy-core.sh" | grep -Eq 'md5|shasum'; then
  bad "the core computes a hash — the hub must never compute one"; else ok; fi

echo "== registry rows carry a directory, not a file =="
# A REGISTRY ROW'S SOURCE IS A DIRECTORY. deploy_stage's file check
# (`[ -f "$REPO/$_k" ]`) refuses a directory outright, so without this the row
# dies as "source exists in neither" — a refusal naming the wrong cause.
rfx="$(mktemp -d)"; mkdir -p "$rfx/repo/projects.d" "$rfx/apply"
printf 'NAME="One"\nPARENT="team"\n'   > "$rfx/repo/projects.d/one.conf"
printf 'NAME="Two"\nPARENT="team"\n'   > "$rfx/repo/projects.d/two.conf"
# A non-conf file in the same directory must NOT travel: the registry reads
# *.conf, and a stray backup or editor swapfile is not registry data.
printf 'stale\n'                       > "$rfx/repo/projects.d/one.conf.bak-x"
printf '#!/bin/bash\n'                 > "$rfx/apply/deploy-apply.sh"
printf 'projects.d scripts/projects.d 644 registry\n' > "$rfx/manifest"

st="$(deploy_stage "$rfx/repo" "$rfx/manifest" "$rfx/apply/deploy-apply.sh" projects.d)"; rc=$?
check "a registry row stages rc 0"        [ "$rc" -eq 0 ]
check "the directory's confs are staged"  [ -f "$st/src/projects.d/one.conf" ]
check "both confs are staged"             [ -f "$st/src/projects.d/two.conf" ]
check "non-conf files do not travel"      [ ! -e "$st/src/projects.d/one.conf.bak-x" ]

# AN EMPTY REGISTRY DIRECTORY IS A REAL STATE, NOT AN ERROR: an estate may
# declare a register it has not populated yet. It must stage as an empty
# directory, so the applier can prune a host that still holds old confs.
mkdir -p "$rfx/repo/empty.d"
printf 'empty.d scripts/empty.d 644 registry\n' > "$rfx/manifest2"
st2="$(deploy_stage "$rfx/repo" "$rfx/manifest2" "$rfx/apply/deploy-apply.sh" empty.d)"; rc=$?
check "an empty registry directory stages rc 0" [ "$rc" -eq 0 ]
check "and stages as a directory"               [ -d "$st2/src/empty.d" ]

# A MISSING DIRECTORY MUST REFUSE. Same rule as a missing file: a row naming
# something that does not exist is a manifest error, and silence would deploy
# a host that is missing a register nobody noticed was declared.
printf 'nosuch.d scripts/nosuch.d 644 registry\n' > "$rfx/manifest3"
out="$(deploy_stage "$rfx/repo" "$rfx/manifest3" "$rfx/apply/deploy-apply.sh" nosuch.d 2>&1)"; rc=$?
check "a missing registry directory refuses" [ "$rc" -ne 0 ]
case "$out" in *nosuch.d*) ok ;; *) bad "the refusal names the missing directory: $out" ;; esac
rm -rf "$rfx"

echo "pass=$pass fail=$fail"
[ "$fail" -eq 0 ]
