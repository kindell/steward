#!/bin/bash
# Tests for linux/deploy-apply.sh — fixture-based, unprivileged, portable.
# Run: bash test/deploy-apply.test.sh
set -u
here="$(CDPATH= cd -- "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
A="$here/linux/deploy-apply.sh"
pass=0; fail=0
ok()  { pass=$((pass+1)); }
bad() { echo "FAIL: $1"; fail=$((fail+1)); }
check() { local d="$1"; shift; if "$@"; then ok; else bad "$d"; fi }
# -e alone is not enough to prove a symlink is gone: -e resolves the link and
# is FALSE for a broken symlink whether or not the link itself was removed.
# -L checks the link entry itself, independent of its target.
gone() { [ ! -e "$1" ] && [ ! -L "$1" ]; }

# Fixture: a stage, two homes and a state directory. A small manifest with two
# kinds of row.
rig() {
  FX="$(mktemp -d)"
  mkdir -p "$FX/stage/src/linux" "$FX/stage/src/docs" \
           "$FX/home1/bin" "$FX/home2/bin" "$FX/state" "$FX/bin"
  printf '#!/bin/bash\necho old-A\n' > "$FX/stage/src/linux/tool-a"
  printf 'norm A\n'                  > "$FX/stage/src/docs/norm.md"
  cat > "$FX/stage/deploy-manifest" <<'EOF'
linux/tool-a  bin/tool-a           755  bin
docs/norm.md  scripts/docs/norm.md 644  docs
EOF
  # systemctl stub: logs its calls, so the policy suite's claim that nothing
  # other than daemon-reload is ever issued can be measured rather than assumed.
  printf '#!/bin/bash\necho "$@" >> "%s/sc.log"\n' "$FX" > "$FX/bin/systemctl"
  chmod +x "$FX/bin/systemctl"
}
run() { # run [extra apply arguments...] <home>...
  ( export PATH="$FX/bin:$PATH" \
      STEWARD_DEPLOY_STATE="$FX/state" STEWARD_DEPLOY_INSTALL_OWNER=off \
      STEWARD_SWEEP_PATH_ALL="$FX/home1/bin:$FX/home2/bin" \
      STEWARD_DEPLOY_SYSTEMCTL="$FX/bin/systemctl"
    bash "$A" "$FX/stage" fakesha1 "$@" 2>&1 )
}

# ── 1. BOOTSTRAP: no last-good => say so out loud, record BEFORE, install ──
rig
printf 'HANDMADE\n' > "$FX/home1/bin/tool-a"   # present before the first deploy
u="$(run "$FX/home1")"; rc=$?
check "bootstrap: rc 0"                    [ "$rc" -eq 0 ]
case "$u" in *BOOTSTRAP*) ok ;; *) bad "bootstrap is not said out loud: $u" ;; esac
check "bootstrap: the file was installed"  grep -q old-A "$FX/home1/bin/tool-a"
lg="$FX/state/$(basename "$FX/home1").last-good"
check "bootstrap: last-good written"       [ -f "$lg" ]
check "bootstrap: before-state recorded"   grep -q "^# BEFORE bin/tool-a " "$lg"
grep -q "^# BEFORE scripts/docs/norm.md MISSING" "$lg" && ok || bad "BEFORE: a missing file was not noted"
case "$u" in *"COMPARED="*) ok ;; *) bad "the report has no COMPARED count: $u" ;; esac
# The mode on last-good: the fixture directory is writable, but the file itself
# must still land at 600 — it records what every home looked like.
mode="$(ls -l "$lg" | cut -c1-10)"
check "last-good: mode 600"                [ "$mode" = "-rw-------" ]

# ── 2. A CLEAN RE-RUN: everything matches => OK, and the home is named UNTOUCHED ──
u="$(run "$FX/home1")"; rc=$?
check "clean re-run: rc 0"                 [ "$rc" -eq 0 ]
case "$u" in *"UNTOUCHED-HOME"*home1*) ok ;; *) bad "an untouched home is not named: $u" ;; esac

# ── 3. A HAND EDIT: a third md5 value => REFUSED, with the hand-edit diagnosis ──
printf '#!/bin/bash\necho HAND\n' > "$FX/home1/bin/tool-a"
u="$(run "$FX/home1")"; rc=$?
check "hand edit: rc 65"                   [ "$rc" -eq 65 ]
case "$u" in *REFUSAL*home1*tool-a*) ok ;; *) bad "the refusal names neither file nor home: $u" ;; esac
case "$u" in *"hand edit"*) ok ;; *) bad "the three-way diagnosis does not say hand edit: $u" ;; esac
check "hand edit: the file was NOT overwritten" grep -q HAND "$FX/home1/bin/tool-a"

# ── 4. INTERRUPTION SIGNATURE: deployed = incoming source => diagnose 'interrupted' ──
rig
run "$FX/home1" >/dev/null                                        # bootstrap
printf '#!/bin/bash\necho new-A\n' > "$FX/stage/src/linux/tool-a" # a new version
cp "$FX/stage/src/linux/tool-a" "$FX/home1/bin/tool-a"            # "interrupted": it got written
u="$(run "$FX/home1")"; rc=$?
check "interruption: rc 65"                [ "$rc" -eq 65 ]
case "$u" in *"interrupted run"*--accept-drift*) ok ;; *) bad "interruption diagnosis + advice missing: $u" ;; esac

# ── 5. A REGISTRY ROW RECONCILES ITS DIRECTORY ──
# THE PRUNE IS WHY THIS ROW TYPE EXISTS. Without it, a conf removed in the hub keeps
# being loaded on the host: the session stays registered locally, the
# supervisor keeps starting it, and nothing says why. This is the oldest
# failure shape in the house — absence that looks like health — on the one
# spot where the hub BELIEVES it has spoken.
rig                                    # fresh fixture; $FX is rebuilt
mkdir -p "$FX/stage/src/projects.d" "$FX/home1/scripts/projects.d"
printf 'NAME="Kept"\nPARENT="team"\n'  > "$FX/stage/src/projects.d/kept.conf"
printf 'NAME="Fresh"\nPARENT="team"\n' > "$FX/stage/src/projects.d/fresh.conf"
printf 'projects.d scripts/projects.d 644 registry\n' >> "$FX/stage/deploy-manifest"
# already on the host, still delivered -> gets updated
printf 'NAME="Stale"\nPARENT="old"\n'  > "$FX/home1/scripts/projects.d/kept.conf"
# already on the host, NOT delivered -> gets removed
printf 'NAME="Gone"\nPARENT="team"\n'  > "$FX/home1/scripts/projects.d/gone.conf"
# not a conf -> must survive; a live home carries six .bak-omdop siblings
printf 'backup\n'                       > "$FX/home1/scripts/projects.d/gone.conf.bak-omdop"

u="$(run "$FX/home1")"; rc=$?
check "registry row: rc 0"                 [ "$rc" -eq 0 ]
check "a delivered conf is installed"      [ -f "$FX/home1/scripts/projects.d/fresh.conf" ]
check "a delivered conf is updated"        grep -q 'PARENT="team"' "$FX/home1/scripts/projects.d/kept.conf"
check "an undelivered conf is pruned"      [ ! -e "$FX/home1/scripts/projects.d/gone.conf" ]
check "a non-conf survives the prune"      [ -f "$FX/home1/scripts/projects.d/gone.conf.bak-omdop" ]

# NOTHING HAPPENS SILENTLY. Both the prune and an overwrite of a conf that
# DIFFERED must show up in the output — otherwise a registry row would be the
# one place in the whole deploy where files change without the report saying
# so.
case "$u" in *"PRUNED"*gone.conf*) ok ;; *) bad "the prune is not visible in the output: $u" ;; esac
case "$u" in *"RECONCILED"*kept.conf*) ok ;; *) bad "the overwrite is not visible in the output: $u" ;; esac
case "$u" in *"RECONCILED"*fresh.conf*) bad "a NEW file is not a reconciliation: $u" ;; *) ok ;; esac

# AN EMPTY DELIVERY EMPTIES THE REGISTRY — but must not delete the directory.
# "Exists and is empty" and "is missing" are different states: the register's
# own list function refuses on the second and returns nothing on the first.
rig
mkdir -p "$FX/stage/src/empty.d" "$FX/home1/scripts/empty.d"
printf 'empty.d scripts/empty.d 644 registry\n' >> "$FX/stage/deploy-manifest"
printf 'NAME="Old"\nPARENT="t"\n' > "$FX/home1/scripts/empty.d/old.conf"
u="$(run "$FX/home1")"; rc=$?
check "empty delivery: rc 0"               [ "$rc" -eq 0 ]
check "empty delivery prunes the conf"     [ ! -e "$FX/home1/scripts/empty.d/old.conf" ]
check "but keeps the directory"            [ -d "$FX/home1/scripts/empty.d" ]

# A MISSING SOURCE DIRECTORY IS NOT AN EMPTY DELIVERY. "Exists and is empty"
# and "does not exist" are different states, and a measurement that cannot be
# made must REFUSE, never silently report empty — that is the difference
# between pruning a register down to nothing on purpose and a stage that
# never staged the directory at all wiping out a whole host's register with
# rc 0 and no REFUSAL.
rig
mkdir -p "$FX/home1/scripts/missing.d"     # on the host already, never re-staged
printf 'missing.d scripts/missing.d 644 registry\n' >> "$FX/stage/deploy-manifest"
printf 'NAME="Untouched"\nPARENT="t"\n' > "$FX/home1/scripts/missing.d/keep.conf"
u="$(run "$FX/home1")"; rc=$?
check "a missing source directory: rc 70, not 0"    [ "$rc" -eq 70 ]
case "$u" in *"missing.d"*) ok ;; *) bad "the missing directory is not named in the output: $u" ;; esac
check "the target directory is left untouched"      [ -f "$FX/home1/scripts/missing.d/keep.conf" ]

# THE DELIMITER MUST NOT BE ABLE TO APPEAR IN WHAT IT DELIMITS. POSIX allows
# '|' in a filename. Delivering "a|b.conf" must not make an UNRELATED,
# undelivered "b.conf" look delivered just because the delivered-name string
# contains "b.conf" as a substring.
rig
mkdir -p "$FX/stage/src/pipe.d" "$FX/home1/scripts/pipe.d"
printf 'NAME="Pipe"\n' > "$FX/stage/src/pipe.d/a|b.conf"
printf 'pipe.d scripts/pipe.d 644 registry\n' >> "$FX/stage/deploy-manifest"
printf 'NAME="Stale"\n' > "$FX/home1/scripts/pipe.d/b.conf"
u="$(run "$FX/home1")"; rc=$?
check "delimiter-safety: rc 0"                        [ "$rc" -eq 0 ]
check "the delivered pipe-name conf is installed"      [ -f "$FX/home1/scripts/pipe.d/a|b.conf" ]
check "an unrelated undelivered conf is still pruned, even though its basename is a substring of a delivered name" \
  [ ! -e "$FX/home1/scripts/pipe.d/b.conf" ]

# A BROKEN SYMLINK IS STILL A *.conf FOR PRUNING PURPOSES. "[ -f ]" is false
# for a broken symlink, so a stale, undelivered *.conf that happens to be a
# dangling symlink was neither installed nor pruned — it sat there forever,
# which breaks the interface requirement that an undelivered *.conf is
# removed.
rig
mkdir -p "$FX/stage/src/link.d" "$FX/home1/scripts/link.d"
printf 'link.d scripts/link.d 644 registry\n' >> "$FX/stage/deploy-manifest"
ln -s /does-not-exist "$FX/home1/scripts/link.d/broken.conf"
u="$(run "$FX/home1")"; rc=$?
check "a broken symlink conf: rc 0"                   [ "$rc" -eq 0 ]
check "an undelivered broken symlink is pruned, not left forever" \
  gone "$FX/home1/scripts/link.d/broken.conf"

# A REGISTRY ROW WRITES ATOMICALLY, LIKE EVERY OTHER ROW TYPE IN THIS FILE.
# Force the install of a delivered conf to fail AFTER its content would have
# already overwritten the target if written in place (an invalid mode makes
# chmod fail, deterministically, on a file that a straight `cp` would already
# have truncated). Written atomically (temp name + rename), the original
# survives the failed install untouched.
rig
mkdir -p "$FX/stage/src/atomic.d" "$FX/home1/scripts/atomic.d"
printf 'NAME="New"\n' > "$FX/stage/src/atomic.d/x.conf"
printf 'atomic.d scripts/atomic.d 999 registry\n' >> "$FX/stage/deploy-manifest"
printf 'NAME="Original"\n' > "$FX/home1/scripts/atomic.d/x.conf"
u="$(run "$FX/home1")"; rc=$?
check "an invalid mode: refused, not rc 0"            [ "$rc" -ne 0 ]
check "a failed install leaves the original conf untouched, not truncated in place" \
  grep -q 'NAME="Original"' "$FX/home1/scripts/atomic.d/x.conf"
check "no leftover temp file after a failed install" \
  bash -c '! ls "$1"/.deploy-tmp.* >/dev/null 2>&1' _ "$FX/home1/scripts/atomic.d"

# ── C1: A SYMLINKED REGISTRY-ROW COMPONENT REFUSES, LIKE EVERY OTHER ROW TYPE.
# apply_registry_row used a raw `mkdir -p`, the one row type with no symlink
# vault: with ~/scripts symlinked out of the home, install wrote outside the
# home AS ROOT, rc 0. This is the component-level case: the directory named
# directly by the manifest target is itself the symlink.
#
# ISOLATED MANIFEST — ONLY the registry row. rig()'s own docs row also
# targets scripts/docs/norm.md, which shares the same symlinked "scripts"
# parent and would trip its OWN (already-guarded) ensure_dir call first,
# masking whether the registry row's own check does anything at all.
rig
mkdir -p "$FX/stage/src/projects.d"
printf 'NAME="X"\n' > "$FX/stage/src/projects.d/x.conf"
printf 'projects.d scripts/projects.d 644 registry\n' > "$FX/stage/deploy-manifest"
OUTSIDE="$(mktemp -d)"
chmod 700 "$OUTSIDE"
ln -s "$OUTSIDE" "$FX/home1/scripts"    # ~/scripts symlinked OUT of the home
u="$(run "$FX/home1")"; rc=$?
check "C1: symlinked scripts/ under a registry row: rc 65"  [ "$rc" -eq 65 ]
case "$u" in *symlink*) ok ;; *) bad "the symlink is not named: $u" ;; esac
check "C1: nothing installed outside the home"               [ ! -e "$OUTSIDE/x.conf" ]
mode_outside="$(ls -ld "$OUTSIDE" | cut -c1-10)"
check "C1: the directory outside the home is untouched (700)" [ "$mode_outside" = "drwx------" ]
rm -rf "$OUTSIDE"

# ── C1b: THE PRUNE SIDE — THE ONE THAT DELETES. With ~/scripts/projects.d
# symlinked out of the home, the measured bug DELETED foreign files outside
# the home as root, rc 0: the prune loop lists "$DSTD"/*.conf and DSTD
# resolved through the link. Here the symlink is the LEAF component, not the
# parent, and the outside directory pre-exists with a foreign, undelivered
# conf that must survive.
rig
mkdir -p "$FX/stage/src/projects.d" "$FX/home1/scripts"
printf 'NAME="X"\n' > "$FX/stage/src/projects.d/x.conf"
printf 'projects.d scripts/projects.d 644 registry\n' >> "$FX/stage/deploy-manifest"
OUTSIDE="$(mktemp -d)"
printf 'NAME="Foreign"\n' > "$OUTSIDE/foreign.conf"     # undelivered: would be PRUNED without the guard
ln -s "$OUTSIDE" "$FX/home1/scripts/projects.d"         # the leaf itself symlinked OUT of the home
u="$(run "$FX/home1")"; rc=$?
check "C1b: symlinked scripts/projects.d: rc 65"             [ "$rc" -eq 65 ]
case "$u" in *symlink*) ok ;; *) bad "the symlink is not named: $u" ;; esac
check "C1b: nothing installed outside the home"               [ ! -f "$OUTSIDE/x.conf" ]
check "C1b: a foreign file outside the home SURVIVES — not pruned as root" \
  [ -f "$OUTSIDE/foreign.conf" ]
rm -rf "$OUTSIDE"

# ── C4: OWNER, LIKE THE FILE ROW BRANCH. apply_registry_row must read
# STEWARD_DEPLOY_INSTALL_OWNER the same way the file branch's `install -o/-g`
# does. Isolated with a manifest holding ONLY a registry row, so a chown
# failure on some OTHER row type cannot mask this row's own behavior.
# STEWARD_DEPLOY_INSTALL_OWNER is left UNSET here (not "off"): $USERNAME
# (home1) is not a real account on this machine, so a genuine chown attempt
# fails — exactly as a plain file row already fails under the same condition
# (measured: `install -o home1 -g home1 ...` -> "unknown group home1", rc 1).
rig
mkdir -p "$FX/stage/src/owner.d"
printf 'NAME="X"\n' > "$FX/stage/src/owner.d/x.conf"
printf 'owner.d scripts/owner.d 644 registry\n' > "$FX/stage/deploy-manifest"
u="$( export PATH="$FX/bin:$PATH" STEWARD_DEPLOY_STATE="$FX/state" \
    STEWARD_DEPLOY_SYSTEMCTL="$FX/bin/systemctl" STEWARD_SWEEP_PATH_ALL="$FX/home1/bin"
  bash "$A" "$FX/stage" fakesha1 "$FX/home1" 2>&1 )"; rc=$?
check "C4: registry row without OWNER=off does not silently succeed" [ "$rc" -ne 0 ]
check "C4: the conf was not installed"                                [ ! -f "$FX/home1/scripts/owner.d/x.conf" ]

# ── 6. TWO HOMES: a refusal in one does not stop the other; rc is still 65 ──
rig
run "$FX/home1" >/dev/null; run "$FX/home2" >/dev/null
printf 'HAND\n' > "$FX/home1/bin/tool-a"
u="$(run "$FX/home1" "$FX/home2")"; rc=$?
check "two homes: rc 65"                   [ "$rc" -eq 65 ]
case "$u" in *"HOME $FX/home1 RESULT=REFUSED"*) ok ;; *) bad "home1 is not REFUSED in the report" ;; esac
case "$u" in *"HOME $FX/home2 RESULT=OK"*) ok ;; *) bad "home2 is not OK in the report" ;; esac

# ── 7. A missing stage/manifest => 78 ──
u="$( STEWARD_DEPLOY_STATE="$FX/state" bash "$A" "$FX/does-not-exist" sha 2>&1 )"; rc=$?
check "missing stage: rc 78"               [ "$rc" -eq 78 ]

# ── 8. THE LONELINESS SWEEP: a duplicate on a PATH location is caught, BEFORE install ──
rig
mkdir -p "$FX/home1/old-place"
printf 'old content\n' > "$FX/home1/old-place/tool-a"   # the decoy
u="$( export PATH="$FX/bin:$PATH" STEWARD_DEPLOY_STATE="$FX/state" \
    STEWARD_DEPLOY_INSTALL_OWNER=off STEWARD_DEPLOY_SYSTEMCTL="$FX/bin/systemctl" \
    STEWARD_SWEEP_PATH_ALL="$FX/home1/bin:$FX/home1/old-place"
  bash "$A" "$FX/stage" fakesha1 "$FX/home1" 2>&1 )"; rc=$?
check "sweep: rc 65"                       [ "$rc" -eq 65 ]
case "$u" in *DECOY*old-place/tool-a*) ok ;; *) bad "the decoy is not named: $u" ;; esac
check "sweep: BEFORE install (the target was not written)" [ ! -f "$FX/home1/bin/tool-a" ]

# ── 9. A symlink TO THE TARGET passes (same inode/realpath = harmless) ──
rig
run "$FX/home1" >/dev/null    # install + last-good
mkdir -p "$FX/home1/linkplace"
ln -s "$FX/home1/bin/tool-a" "$FX/home1/linkplace/tool-a"
u="$( export PATH="$FX/bin:$PATH" STEWARD_DEPLOY_STATE="$FX/state" \
    STEWARD_DEPLOY_INSTALL_OWNER=off STEWARD_DEPLOY_SYSTEMCTL="$FX/bin/systemctl" \
    STEWARD_SWEEP_PATH_ALL="$FX/home1/bin:$FX/home1/linkplace"
  bash "$A" "$FX/stage" fakesha1 "$FX/home1" 2>&1 )"; rc=$?
check "symlink to the target: rc 0"        [ "$rc" -eq 0 ]

# ── 10. A git working copy is exempt (a clone is a source, not a decoy) ──
rig
mkdir -p "$FX/home1/Projects/clone/.git" "$FX/home1/Projects/clone/linux"
printf 'source code\n' > "$FX/home1/Projects/clone/linux/tool-a"
u="$( export PATH="$FX/bin:$PATH" STEWARD_DEPLOY_STATE="$FX/state" \
    STEWARD_DEPLOY_INSTALL_OWNER=off STEWARD_DEPLOY_SYSTEMCTL="$FX/bin/systemctl" \
    STEWARD_SWEEP_PATH_ALL="$FX/home1/bin:$FX/home1/Projects/clone/linux"
  bash "$A" "$FX/stage" fakesha1 "$FX/home1" 2>&1 )"; rc=$?
check "git clone: rc 0 (exempt)"           [ "$rc" -eq 0 ]

# ── 9b. TWO manifest rows with the SAME basename => no refusal (measured during
#        a domain's cutover: otherwise two legitimate targets report each other) ──
rig
printf 'linux/tool-a  scripts/alt/tool-a  755  scripts\n' >> "$FX/stage/deploy-manifest"
run "$FX/home1" >/dev/null    # bootstrap: both targets are installed
u="$( export PATH="$FX/bin:$PATH" STEWARD_DEPLOY_STATE="$FX/state" \
    STEWARD_DEPLOY_INSTALL_OWNER=off STEWARD_DEPLOY_SYSTEMCTL="$FX/bin/systemctl" \
    STEWARD_SWEEP_PATH_ALL="$FX/home1/bin:$FX/home1/scripts/alt"
  bash "$A" "$FX/stage" fakesha1 "$FX/home1" 2>&1 )"; rc=$?
check "same basename, two targets: rc 0"   [ "$rc" -eq 0 ]
case "$u" in *DECOY*) bad "legitimate targets reported each other: $u" ;; *) ok ;; esac

# ── 10. THE VALVE: --accept-drift requires --file; with one it passes and marks ──
rig
run "$FX/home1" >/dev/null
printf 'HANDFIX\n' > "$FX/home1/bin/tool-a"
u="$(run --accept-drift "$FX/home1" "$FX/home1")"; rc=$?
check "valve without --file: rc 64"        [ "$rc" -eq 64 ]
u="$(run --accept-drift "$FX/home1" --file bin/tool-a "$FX/home1")"; rc=$?
check "valve with --file: rc 0"            [ "$rc" -eq 0 ]
lg="$FX/state/$(basename "$FX/home1").last-good"
check "valve: an ACCEPT-DRIFT trace in last-good" grep -q "ACCEPT-DRIFT" "$lg"
check "valve: the file was overwritten from the source" grep -q old-A "$FX/home1/bin/tool-a"

# ── 11. RETIRED: a row that left the manifest is inherited, marked, in the new last-good ──
rig
run "$FX/home1" >/dev/null
grep -v 'norm.md' "$FX/stage/deploy-manifest" > "$FX/stage/m2" && mv "$FX/stage/m2" "$FX/stage/deploy-manifest"
run "$FX/home1" >/dev/null
lg="$FX/state/$(basename "$FX/home1").last-good"
grep -q "scripts/docs/norm.md .* RETIRED" "$lg" && ok || bad "the RETIRED row is missing"

# ── 12. C1: an existing directory's mode/owner is NEVER touched (the core
#         finding: a 700 directory silently became 755 via install -d) ──
rig
chmod 700 "$FX/home1/bin"
u="$(run "$FX/home1")"; rc=$?
check "existing directory: rc 0"           [ "$rc" -eq 0 ]
mode_bin="$(ls -ld "$FX/home1/bin" | cut -c1-10)"
check "existing directory: mode 700 UNTOUCHED" [ "$mode_bin" = "drwx------" ]

# ── 13. A symlinked directory component in the target path => refuse with 65,
#         anything OUTSIDE the tree untouched (the measured finding: a ~/bin -> /etc symlink) ──
rig
OUTSIDE="$(mktemp -d)"
chmod 700 "$OUTSIDE"
ln -s "$OUTSIDE" "$FX/home1/scripts"    # scripts/docs/norm.md would land under scripts/
u="$(run "$FX/home1")"; rc=$?
check "symlink in the target path: rc 65"  [ "$rc" -eq 65 ]
case "$u" in *symlink*scripts*) ok ;; *) bad "the symlink is not named: $u" ;; esac
mode_outside="$(ls -ld "$OUTSIDE" | cut -c1-10)"
check "symlink in the target path: the target OUTSIDE the tree is untouched (700)" [ "$mode_outside" = "drwx------" ]
check "symlink in the target path: nothing installed into the decoy"              [ ! -e "$OUTSIDE/docs" ]
rm -rf "$OUTSIDE"

# ── 14. A file present in last-good but MISSING from the home now => REFUSED.
#         A deleted file IS drift — measured: RESULT=OK, silently reinstalled ──
rig
run "$FX/home1" >/dev/null              # bootstrap: both files are installed
rm -f "$FX/home1/bin/tool-a"            # a deletion in the home, after the deploy
u="$(run "$FX/home1")"; rc=$?
check "deleted file: rc 65"                [ "$rc" -eq 65 ]
case "$u" in *"bin/tool-a is missing"*"last-good"*) ok ;; *) bad "the refusal does not mention missing + last-good: $u" ;; esac
case "$u" in *"--accept-drift $FX/home1 --file bin/tool-a"*) ok ;; *) bad "the --accept-drift advice is missing: $u" ;; esac
check "deleted file: NOT silently reinstalled" [ ! -f "$FX/home1/bin/tool-a" ]
u="$(run --accept-drift "$FX/home1" --file bin/tool-a "$FX/home1")"; rc=$?
check "deleted file + valve: rc 0"         [ "$rc" -eq 0 ]
check "deleted file + valve: reinstalled"  grep -q old-A "$FX/home1/bin/tool-a"

# ── 15. COMPARED counts ACTUAL comparisons, not manifest rows — a last-good with
#         no usable rows must give COMPARED=0 and must NOT wrongly name the home
#         UNTOUCHED-HOME (measured: COMPARED=1 while zero files were compared,
#         and the home wrongly reported as untouched) ──
rig
lg="$FX/state/home1.last-good"
printf '# steward-deploy last-good user=home1 sha=xyz ts=2026-01-01T00:00:00Z count=0\n' > "$lg"
chmod 600 "$lg"
u="$(run "$FX/home1")"; rc=$?
check "empty last-good: rc 0"              [ "$rc" -eq 0 ]
case "$u" in *"HOME $FX/home1 RESULT=OK"*"COMPARED=0"*) ok ;; *) bad "COMPARED miscounted: $u" ;; esac
case "$u" in *"UNTOUCHED-HOME"*" $FX/home1"*) bad "the home was wrongly UNTOUCHED despite zero comparisons: $u" ;; *) ok ;; esac

# ── 16. The home root does not exist as a directory => refuse with 78, create
#         nothing silently (measured: the phantom home was created silently,
#         29 files were installed, rc 0) ──
rig
u="$(run "$FX/home-does-not-exist")"; rc=$?
check "phantom home: rc 78"                [ "$rc" -eq 78 ]
case "$u" in *"home root"*"does not exist"*) ok ;; *) bad "the phantom-home text is missing: $u" ;; esac
check "phantom home: the directory was NOT created silently" [ ! -d "$FX/home-does-not-exist" ]

# ── 17. --accept-drift or --file with no value at the end of the line => rc 64,
#         NOT '$2: unbound variable' (rc 1, outside the documented rc table) ──
#
# THE FLAG IS SPELLED OUT, AND THE MESSAGE IS ASSERTED. This case used to pass
# `--fil` — the flag's old, pre-translation name. That is not a flag at all, so
# apply answered "unknown argument --fil" and exited 64: the SAME rc for an
# ENTIRELY different reason, and the case had measured argument validation for
# neither flag since the rename. MEASURED 2026-08-19, both branches side by side:
#
#   --fil    rc=64  deploy-apply: unknown argument --fil
#   --file   rc=64  deploy-apply: --file requires a value (target path)
#
# The same scar deploy-self.test.sh records about rc 65 arriving from the
# provenance gate: when two causes share an exit code, asserting the code alone
# asserts nothing. Both cases below therefore assert the MESSAGE as well.
rig
u="$(run --accept-drift)"; rc=$?
check "--accept-drift with no value: rc 64" [ "$rc" -eq 64 ]
case "$u" in *"--accept-drift requires a value"*) ok ;; *) bad "the refusal is not about the missing value: $u" ;; esac
case "$u" in *unbound*) bad "it crashed as an unbound variable: $u" ;; *) ok ;; esac
u="$(run --file)"; rc=$?
check "--file with no value: rc 64"         [ "$rc" -eq 64 ]
case "$u" in *"--file requires a value"*) ok ;; *) bad "the refusal is not about the missing value: $u" ;; esac
case "$u" in *unbound*) bad "it crashed as an unbound variable: $u" ;; *) ok ;; esac

# ── 18. The valve must match something real — the wrong home, or a --file that
#         is not a manifest target => rc 64 with the subject printed (measured:
#         an identical refusal again, with no word that the valve had not
#         matched) ──
rig
run "$FX/home1" >/dev/null
printf 'HAND\n' > "$FX/home1/bin/tool-a"
u="$(run --accept-drift "$FX/home2" --file bin/tool-a "$FX/home1")"; rc=$?
check "valve for the wrong home: rc 64"    [ "$rc" -eq 64 ]
case "$u" in *"the valve was given for"*"$FX/home2"*) ok ;; *) bad "the valve's error message does not name the home: $u" ;; esac
u="$(run --accept-drift "$FX/home1" --file bin/DOES-NOT-EXIST "$FX/home1")"; rc=$?
check "valve for an unknown target: rc 64" [ "$rc" -eq 64 ]
case "$u" in *"the valve was given for"*"bin/DOES-NOT-EXIST"*) ok ;; *) bad "the valve's error message does not name the file: $u" ;; esac

# ── 19. THE VALVE HOLDS ONE HOME. Given twice it used to overwrite the first
#         silently while --file kept accumulating, so a two-home run produced one
#         OK and one refusal whose text was IDENTICAL to the run without any valve
#         at all. Measured on basement 2026-08-22. The usage line's trailing "..."
#         is what makes the repeated form look supported. ──
rig
run "$FX/home1" >/dev/null
run "$FX/home2" >/dev/null
printf 'HAND\n' > "$FX/home1/bin/tool-a"
printf 'HAND\n' > "$FX/home2/bin/tool-a"
u="$(run --accept-drift "$FX/home1" --file bin/tool-a --accept-drift "$FX/home2" --file bin/tool-a "$FX/home1" "$FX/home2")"; rc=$?
check "the valve given twice: rc 64"        [ "$rc" -eq 64 ]
case "$u" in *"given twice"*) ok ;; *) bad "the refusal does not say the valve was given twice: $u" ;; esac
case "$u" in *"$FX/home1"*"$FX/home2"*) ok ;; *) bad "the refusal names neither home, so the dropped one is not visible: $u" ;; esac
case "$u" in *RESULT=OK*) bad "it deployed anyway — a refusal that installs is worse than the silence it replaced: $u" ;; *) ok ;; esac

# The usage line must not promise a repetition the parser refuses. This is the
# half of the fix that lives in prose: the guard above only fires AFTER someone
# wrote the form the documentation invited.
case "$(sed -n '1,12p' "$A")" in
  *'[--accept-drift <home> --file <target>]...'*)
    bad "the usage line still promises a repeatable --accept-drift that the parser refuses" ;;
  *) ok ;;
esac

echo "pass=$pass fail=$fail"
[ "$fail" -eq 0 ]
