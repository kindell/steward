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

# ── 5. TWO HOMES: a refusal in one does not stop the other; rc is still 65 ──
rig
run "$FX/home1" >/dev/null; run "$FX/home2" >/dev/null
printf 'HAND\n' > "$FX/home1/bin/tool-a"
u="$(run "$FX/home1" "$FX/home2")"; rc=$?
check "two homes: rc 65"                   [ "$rc" -eq 65 ]
case "$u" in *"HOME $FX/home1 RESULT=REFUSED"*) ok ;; *) bad "home1 is not REFUSED in the report" ;; esac
case "$u" in *"HOME $FX/home2 RESULT=OK"*) ok ;; *) bad "home2 is not OK in the report" ;; esac

# ── 6. A missing stage/manifest => 78 ──
u="$( STEWARD_DEPLOY_STATE="$FX/state" bash "$A" "$FX/does-not-exist" sha 2>&1 )"; rc=$?
check "missing stage: rc 78"               [ "$rc" -eq 78 ]

# ── 7. THE LONELINESS SWEEP: a duplicate on a PATH location is caught, BEFORE install ──
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

# ── 8. A symlink TO THE TARGET passes (same inode/realpath = harmless) ──
rig
run "$FX/home1" >/dev/null    # install + last-good
mkdir -p "$FX/home1/linkplace"
ln -s "$FX/home1/bin/tool-a" "$FX/home1/linkplace/tool-a"
u="$( export PATH="$FX/bin:$PATH" STEWARD_DEPLOY_STATE="$FX/state" \
    STEWARD_DEPLOY_INSTALL_OWNER=off STEWARD_DEPLOY_SYSTEMCTL="$FX/bin/systemctl" \
    STEWARD_SWEEP_PATH_ALL="$FX/home1/bin:$FX/home1/linkplace"
  bash "$A" "$FX/stage" fakesha1 "$FX/home1" 2>&1 )"; rc=$?
check "symlink to the target: rc 0"        [ "$rc" -eq 0 ]

# ── 9. A git working copy is exempt (a clone is a source, not a decoy) ──
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

echo "pass=$pass fail=$fail"
[ "$fail" -eq 0 ]
