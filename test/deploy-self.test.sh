#!/bin/bash
# test/deploy-self.test.sh — the host's own entry point. Tested WITHOUT root and
# WITHOUT touching a real home: sudo is stubbed, apply is stubbed, and everything
# is measured on what the entry point PASSES ON. What must be shown here is the
# routing and the refusals, not the installation — that has its own suite.
#
# A HERMETIC FIXTURE, and this is why. The original version ran the entry point
# DIRECTLY from this checkout — and the entry point resolves its own location to
# find the core. The provenance gate then measures THAT directory's HEAD against
# ORIGIN, which meant every run measured THIS checkout against a real network
# fetch. The suite was green only because the branch happened to be named
# something other than main: green or red depended on a branch name rather than
# on what the suite claimed to measure, and gates three and four were NEVER
# reached in any case because provenance had already failed first. A mutation
# that removed the deploy_sources_clean call survived the suite untouched
# (pass=11 fail=0).
#
# The suite therefore builds its OWN throwaway repo: a local bare origin, branch
# main, clean sources — no network fetch, and no dependence on which branch THIS
# checkout happens to sit on.
set -u
here="$(CDPATH= cd -- "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
S="$here/linux/deploy-self.sh"   # the master file — for the static policy checks only
pass=0; fail=0
ok(){ pass=$((pass+1)); }
bad(){ echo "FAIL: $1"; fail=$((fail+1)); }
check(){ d="$1"; shift; if "$@"; then ok; else bad "$d"; fi; }

FX="$(mktemp -d)"

# ── THE FIXTURE REPO ───────────────────────────────────────────────────
# The entry point, the executor and the core are copied INTO the fixture — that
# copy is what runs, so the resolved product root (and therefore the provenance
# gate) points at the fixture's repo rather than at this checkout.
mkdir -p "$FX/repo/linux" "$FX/repo/lib"
cp "$here/linux/deploy-self.sh"   "$FX/repo/linux/deploy-self.sh"
cp "$here/linux/deploy-apply.sh"  "$FX/repo/linux/deploy-apply.sh"
cp "$here/lib/deploy-core.sh"     "$FX/repo/lib/deploy-core.sh"
printf 'x\n' > "$FX/repo/linux/tool-a"
# THE PRODUCT'S OWN COMMAND, STUBBED. After a successful apply the deploy
# regenerates the desk by calling `bin/steward desk snapshot` in its own
# checkout - so the fixture's checkout needs that file, and a stub is what
# makes the call measurable without a registry, a snapshot or jq. It records
# its argv AND its STEWARD_ESTATE_ROOT - the snapshot reads the registry
# through that variable, and a deploy that forgot to pass it would still look
# green here if only argv were checked.
mkdir -p "$FX/repo/bin"
cat > "$FX/repo/bin/steward" <<EOF
#!/bin/bash
echo "\$*" >> "$FX/steward.calls"
echo "env STEWARD_ESTATE_ROOT=\$STEWARD_ESTATE_ROOT" >> "$FX/steward.calls"
echo "env STEWARD_ESTATE=\${STEWARD_ESTATE-<unset>}" >> "$FX/steward.calls"
exit "\${STEWARD_STUB_RC:-0}"
EOF
chmod 755 "$FX/repo/bin/steward"
: > "$FX/steward.calls"
cat > "$FX/repo/linux/deploy-manifest" <<'EOF'
linux/tool-a  bin/tool-a  755  bin
EOF

# THE REAL BRIDGE, FOR THE CASES BELOW THAT DO NOT OVERRIDE STEWARD_DESK_DIR.
# Most cases stub the desk resolution away with STEWARD_DESK_DIR, but a case
# that wants to prove the ACTUAL desk-paths call works has to carry the real
# bridge and the library it sources - desk-paths reads lib/registry.sh two
# hops up from itself, and that library reads STATE_DIR_NAME out of an estate
# file, so both are copied into the fixture repo and a minimal estate file is
# written for it. They are committed with the fixture's init commit like
# everything else in the repo; neither is a manifest source, and the
# provenance and cleanliness gates under test read manifest sources only, so
# their presence changes nothing those gates measure.
mkdir -p "$FX/repo/desk/bin" "$FX/repo/estate"
cp "$here/desk/bin/desk-paths" "$FX/repo/desk/bin/desk-paths"
chmod 755 "$FX/repo/desk/bin/desk-paths"
cp "$here/lib/registry.sh" "$FX/repo/lib/registry.sh"
STATE_DIR_NAME_FX="fixture-state"
printf 'STATE_DIR_NAME="%s"\n' "$STATE_DIR_NAME_FX" > "$FX/repo/estate/steward.conf"
( cd "$FX/repo" && git init -q -b main \
    && git add -A \
    && git -c user.email=t@t -c user.name=t commit -qm init )
git clone -q --bare "$FX/repo" "$FX/origin.git"
( cd "$FX/repo" && git remote add origin "$FX/origin.git" && git fetch -q origin )
SF="$FX/repo/linux/deploy-self.sh"   # the RUNNABLE copy, inside the fixture

mkdir -p "$FX/bin" "$FX/reg"
# The sudo stub echoes its arguments AND is steerable through SUDO_RC — NO root,
# NO real apply. A stub that always returned 0 tested only the happy path and
# never the rc 1/127 branches, so the whole rc-translation block survived the
# suite untested; deleting it was a mutation the suite could not feel.
cat > "$FX/bin/sudo" <<'EOF'
#!/bin/bash
echo "SUDO-CALL: $*"
exit "${SUDO_RC:-0}"
EOF
chmod 755 "$FX/bin/sudo"
printf 'HOST="testhost"\nOWNER="alfa"\nDOMAIN="d"\n' > "$FX/reg/a.conf"

# THE DESK DIRECTORY IS THE HOST'S ANSWER TO "IS THERE A DESK HERE". The
# producer already honours STEWARD_DESK_DIR as the operator's override, so the
# deploy's presence check honours the same variable rather than inventing a
# second opinion - which is also what makes the two cases below measurable
# without a registry, an estate or a real state directory.
DESKDIR="$FX/desk"; mkdir -p "$DESKDIR"
NODESKDIR="$FX/no-such-desk"    # deliberately never created

# A HERMETIC HOME. Once the deploy writes a systemd drop-in under
# $HOME/.config, a fixture that leaves HOME aimed at this account's real
# home would write into it. $FX/home is the fixture's own account; every
# case below reads its drop-ins under $FX/home/.config/systemd/user.
mkdir -p "$FX/home"

# THE SYSTEMCTL STUB, IN ITS OWN DIRECTORY SO IT CAN BE LEFT OFF PATH. One
# case (systemctl absent) needs a PATH with no systemctl at all - a stub that
# always answers rc 0 the way sudo's does cannot express "not installed", so
# it lives in $FX/binsys and run() includes that directory unless
# NO_SYSTEMCTL_STUB is set. It records its argv (for the "called exactly
# once with daemon-reload" case) and is steerable through SYSTEMCTL_RC.
mkdir -p "$FX/binsys"
cat > "$FX/binsys/systemctl" <<EOF
#!/bin/bash
echo "\$*" >> "$FX/systemctl.calls"
exit "\${SYSTEMCTL_RC:-0}"
EOF
chmod 755 "$FX/binsys/systemctl"
: > "$FX/systemctl.calls"

# A PATH THAT CLAIMS A TOOL IS ABSENT MUST BE THE WHOLE PATH, not a prefix onto
# the real one. Case (d) below asserts "no systemctl on PATH" - and it used to
# build that as `$FX/bin:$PATH` with the stub directory merely left out. Leaving
# out the stub removes the STUB; it does not remove the host's own
# /usr/bin/systemctl, which is exactly what a Linux host has. macOS passed the
# case by accident (there is no systemctl to find); Linux found the real one,
# reloaded a real user manager, and the line about the absent manager was never
# written: 65/1 on every Linux host since the case was added. Same class, same
# repair as liveness-host (07d203d): every command on this machine EXCEPT the one
# under test, symlinked into one directory that IS the path.
mkdir -p "$FX/binall"
ln -s /usr/bin/* "$FX/binall/" 2>/dev/null
ln -s /bin/*     "$FX/binall/" 2>/dev/null
rm -f "$FX/binall/systemctl"

run() {  # run <hostname answer> <host argument>
  ( if [ -n "${NO_SYSTEMCTL_STUB:-}" ]; then _rp="$FX/bin:$FX/binall"      # absence: the WHOLE path
    else                                    _rp="$FX/binsys:$FX/bin:$PATH"  # presence: the stub, then the world
    fi
    export PATH="$_rp"
    export HOME="$FX/home"
    # LEFT UNSET UNLESS THE CALLER SET IT. Production reads this with
    # ${STEWARD_DESK_DIR:-}, so unset and empty behave identically to the code
    # under test - but a case that wants to exercise the REAL desk-paths
    # bridge needs the fixture's environment to look like a real deploy's,
    # where nobody sets this variable at all unless overriding the default.
    # A prefix assignment on the call (STEWARD_DESK_DIR="$X" run ...) is
    # visible here only for the duration of this function call and never
    # leaks to a later run() that does not set it.
    if [ -n "${STEWARD_DESK_DIR+x}" ]; then
      export STEWARD_DESK_DIR
    fi
    export STEWARD_REGISTRY_DIR="$FX/reg"
    # THE ESTATE IS EXPLICIT IN THE FIXTURE TOO. deploy-self.sh refuses (78)
    # without an estate, by design — so a fixture that omits it measures the
    # refusal instead of the thing under test. The fixture repo doubles as the
    # estate here: it holds the registry the run reads.
    export STEWARD_ESTATE="$FX/repo"
    export STEWARD_DEPLOY_HOSTNAME="$1"
    export SUDO_RC="${SUDO_RC:-0}"
    export SYSTEMCTL_RC="${SYSTEMCTL_RC:-0}"
    bash "$SF" "$2" 2>&1 )
}

echo "== the wrong machine is a REFUSAL, not a detour =="
u="$(run othermachine testhost)"; rc=$?
check "rc 65 when hostname is not the host" [ "$rc" -eq 65 ]
case "$u" in *testhost*|*othermachine*) ok ;; *) bad "the refusal does not name the machines: $u" ;; esac
case "$u" in *SUDO-CALL*) bad "apply was called ANYWAY — a refusal after execution" ;; *) ok ;; esac
# Rc 65 can also come from the provenance gate — without this case, a mutation
# that disables the machine check itself survives, because the exit code happens
# to be the same for an ENTIRELY different reason.
case "$u" in *"REFUSED"*) ok ;; *) bad "refusal text missing — the machine check may never have run: $u" ;; esac

echo "== no argument: a usage error =="
u="$( export PATH="$FX/bin:$PATH"; bash "$SF" 2>&1 )"; rc=$?
check "rc 64 without a host" [ "$rc" -eq 64 ]

echo "== an unknown host in the registry =="
u="$(run testhost doesnotexist)"; rc=$?
check "rc 78 for a host with no sessions" [ "$rc" -eq 78 ]

echo "== CONTROL GROUP: right machine, clean tree, main==origin/main => execution =="
# Gates one (provenance), three (manifest sources) and four (source cleanliness)
# must ALL pass here and actually be REACHED — otherwise they are merely passed
# by accident because something earlier failed first, which is exactly what the
# review found.
u1="$(SUDO_RC=0 run testhost testhost)"; rc=$?
check "clean tree: rc 0" [ "$rc" -eq 0 ]
case "$u1" in *SUDO-CALL*) ok ;; *) bad "execution was never reached: $u1" ;; esac
case "$u1" in *"is not this machine"*) bad "the machine check misfired — it IS the right machine" ;; *) ok ;; esac
case "$u1" in *"execution failure"*) bad "an error line despite a successful sudo (rc 0): $u1" ;; *) ok ;; esac

echo "== the sudo stub's rc 1/127 branches are exercised for real (delete them and the mutation FALLS) =="
u="$(SUDO_RC=1 run testhost testhost)"; rc=$?
check "sudo stub rc 1: rc 70" [ "$rc" -eq 70 ]
case "$u" in *"execution failure"*) ok ;; *) bad "no execution-failure text (rc 1): $u" ;; esac
case "$u" in *"sudo"*) ok ;; *) bad "sudo is not named in the rc 1 text: $u" ;; esac
case "$u" in *"apply"*) ok ;; *) bad "apply is not named in the rc 1 text — BOTH causes must be named: $u" ;; esac

u="$(SUDO_RC=127 run testhost testhost)"; rc=$?
check "sudo stub rc 127: rc 70" [ "$rc" -eq 70 ]
case "$u" in *"execution failure"*"command not found"*) ok ;; *) bad "wrong text for rc 127: $u" ;; esac

echo "== the deploy REGENERATES THE DESK, and only after an apply that worked =="
# THE DEPLOY IS THE REVOCATION. A home that lost a person, or a person who lost
# a row, keeps being described by the generation on disk until somebody writes
# a new one - and the timer's next round is five minutes away. So the deploy
# writes it: seconds after the rollout, the desk shows the estate the rollout
# installed. The refresh timer exists for liveness, not for this.
: > "$FX/steward.calls"
u="$(SUDO_RC=0 STEWARD_DESK_DIR="$DESKDIR" run testhost testhost)"; rc=$?
check "a successful apply still exits 0" [ "$rc" -eq 0 ]
case "$(cat "$FX/steward.calls")" in *"desk snapshot"*) ok ;; *) bad "the deploy did not regenerate the desk after a successful apply: '$(cat "$FX/steward.calls")'" ;; esac
# THE SNAPSHOT MUST READ THE ESTATE, NOT THE HOME. Measured 2026-09-08: the
# snapshot unit runs with no STEWARD_ESTATE_ROOT, so on a hub account whose
# HOME is not the estate checkout the registry root defaults to ~/scripts -
# that account's own two rows instead of the estate's twenty-five. The deploy
# already knows the estate (it just provenance-gated it), so the call it makes
# here must carry the canonical estate root.
estate_root_expect="$(CDPATH= cd -- "$FX/repo" && pwd)"
case "$(cat "$FX/steward.calls")" in
  *"env STEWARD_ESTATE_ROOT=$estate_root_expect"*) ok ;;
  *) bad "the desk snapshot call did not carry the canonical estate root ($estate_root_expect): '$(cat "$FX/steward.calls")'" ;;
esac
# THE OPERATOR'S STEWARD_ESTATE (a directory, to this script) MUST NOT REACH
# THE CHILD - lib/registry.sh reads a variable of the same name as the estate
# FILE, and an inherited directory makes it refuse. run() exports
# STEWARD_ESTATE as the fixture repo for every case (line ~119 above), so this
# proves the deploy strips it before calling the steward stub.
case "$(cat "$FX/steward.calls")" in
  *"env STEWARD_ESTATE=<unset>"*) ok ;;
  *) bad "STEWARD_ESTATE reached the steward stub instead of being stripped: '$(cat "$FX/steward.calls")'" ;;
esac

# A FAILED APPLY MUST NOT PUBLISH A NEW GENERATION. What went onto the disk is
# then unknown, and a desk regenerated from a half-applied rollout describes an
# estate that does not exist on that host.
# WITH THE DESK DIRECTORY PRESENT, so what stops the producer here is the
# failed apply and not the desk-presence check one line below it.
: > "$FX/steward.calls"
u="$(SUDO_RC=1 STEWARD_DESK_DIR="$DESKDIR" run testhost testhost)"; rc=$?
case "$(cat "$FX/steward.calls")" in *"desk snapshot"*) bad "the desk was regenerated after an apply that FAILED" ;; *) ok ;; esac

# A SNAPSHOT THAT FAILED IS NOT A CLEAN DEPLOY. The files landed, so the run is
# not a refusal - but the desk is now describing the previous generation, and a
# green exit code would hide that until somebody happened to read a page.
: > "$FX/steward.calls"
u="$(SUDO_RC=0 STEWARD_STUB_RC=3 STEWARD_DESK_DIR="$DESKDIR" run testhost testhost)"; rc=$?
check "apply 0, snapshot 3: rc 70" [ "$rc" -eq 70 ]
case "$u" in *desk*) ok ;; *) bad "the failure text does not name the desk: $u" ;; esac
case "$u" in *SUDO-CALL*) ok ;; *) bad "the apply itself never ran, so the case measures the wrong failure: $u" ;; esac

# A HOST WITH NO DESK MUST NOT BE MADE TO TAKE ONE. Every home on every host
# receives the desk's files and units, and only the hub account ever enables
# them; the desk directory is created by the first snapshot that account's own
# timer runs. So on every other account - and on the hub account before the
# operator has turned the desk on - there is no desk, and a deploy that ran the
# producer anyway would mint a generation nobody serves, in a directory nobody
# asked for, and would fail the whole rollout (rc 70) the day the producer
# refused for a reason that has nothing to do with the rollout.
: > "$FX/steward.calls"
u="$(SUDO_RC=0 STEWARD_DESK_DIR="$NODESKDIR" run testhost testhost)"; rc=$?
check "no desk on this host: a successful apply still exits 0" [ "$rc" -eq 0 ]
case "$(cat "$FX/steward.calls")" in *"desk snapshot"*) bad "the producer ran on a host with no desk" ;; *) ok ;; esac
case "$u" in *"no desk on this host"*) ok ;; *) bad "the skip is silent - nothing says why no snapshot was taken: $u" ;; esac
case "$u" in *"$NODESKDIR"*) ok ;; *) bad "the skip line does not name the directory it looked for: $u" ;; esac

echo "== the desk units learn the estate through a drop-in, the way activation binds a session =="
# UNLIKE THE SNAPSHOT ABOVE, THIS RUNS ON EVERY DEPLOY, DESK OR NO DESK: the
# units this writes for (steward-desk.service, steward-desk-snapshot.service)
# get their files and units on every home regardless of whether that account
# has ever turned the desk on - so the drop-in is written the same way, not
# gated on STEWARD_DESK_DIR existing. No desk dir is set for this block on
# purpose, to prove the two are independent.
rm -rf "$FX/home/.config"; : > "$FX/systemctl.calls"
estate_root_expect="$(CDPATH= cd -- "$FX/repo" && pwd)"
expect_dropin="[Service]
Environment=STEWARD_ESTATE_ROOT=$estate_root_expect"
DROPIN1="$FX/home/.config/systemd/user/steward-desk.service.d/50-estate.conf"
DROPIN2="$FX/home/.config/systemd/user/steward-desk-snapshot.service.d/50-estate.conf"

echo "-- (a) both drop-ins exist with exactly the expected two lines --"
u="$(SUDO_RC=0 run testhost testhost)"; rc=$?
check "a green deploy still exits 0" [ "$rc" -eq 0 ]
if [ -f "$DROPIN1" ]; then
  got1="$(cat "$DROPIN1")"
  if [ "$got1" = "$expect_dropin" ]; then ok; else bad "steward-desk.service drop-in content: got [$got1] want [$expect_dropin]"; fi
else bad "drop-in missing: $DROPIN1"; fi
if [ -f "$DROPIN2" ]; then
  got2="$(cat "$DROPIN2")"
  if [ "$got2" = "$expect_dropin" ]; then ok; else bad "steward-desk-snapshot.service drop-in content: got [$got2] want [$expect_dropin]"; fi
else bad "drop-in missing: $DROPIN2"; fi

echo "-- (b) systemctl --user daemon-reload, called exactly once --"
reload_count="$(grep -c -- '--user daemon-reload' "$FX/systemctl.calls" 2>/dev/null || true)"
check "daemon-reload called exactly once" [ "${reload_count:-0}" -eq 1 ]

echo "-- (c) a reload failure is rc 70, named on stderr --"
: > "$FX/systemctl.calls"
u="$(SUDO_RC=0 SYSTEMCTL_RC=1 run testhost testhost)"; rc=$?
check "systemctl reload failure: rc 70" [ "$rc" -eq 70 ]
case "$u" in *"did not reload"*) ok ;; *) bad "no reload-failure text: $u" ;; esac
case "$u" in *"daemon-reload"*) ok ;; *) bad "the failure text does not tell the operator how to recover: $u" ;; esac

echo "-- (d) no systemctl on PATH: rc unchanged, one line, files still written --"
: > "$FX/systemctl.calls"
rm -rf "$FX/home/.config"
u="$(SUDO_RC=0 NO_SYSTEMCTL_STUB=1 run testhost testhost)"; rc=$?
check "no user manager present: rc unchanged (0)" [ "$rc" -eq 0 ]
case "$u" in *"no user"*"manager"*) ok ;; *) bad "no line about the absent user manager: $u" ;; esac
[ -s "$FX/systemctl.calls" ] && bad "systemctl was called despite being off PATH" || ok
[ -f "$DROPIN1" ] && [ -f "$DROPIN2" ] && ok || bad "the drop-ins were not written when systemctl is absent"

echo "-- (e) a second deploy leaves the drop-in byte-identical --"
cp "$DROPIN1" "$FX/before1"; cp "$DROPIN2" "$FX/before2"
u="$(SUDO_RC=0 run testhost testhost)"; rc=$?
check "second deploy: rc 0" [ "$rc" -eq 0 ]
if cmp -s "$FX/before1" "$DROPIN1"; then ok; else bad "steward-desk.service drop-in changed across a second deploy"; fi
if cmp -s "$FX/before2" "$DROPIN2"; then ok; else bad "steward-desk-snapshot.service drop-in changed across a second deploy"; fi

echo "== the stage gets an UNPREDICTABLE name — measured on the BEHAVIOUR =="
# The old variant looked for the string 'mktemp' on a non-comment line in the
# entry point — satisfied by an end-of-line comment without the script ever
# calling mktemp itself (the core's deploy_stage does). A change to a predictable
# name in the core would have passed that guard. What is measured instead is that
# TWO runs really do get different stage paths.
u2="$(run testhost testhost)"; rc=$?
check "second run: rc 0" [ "$rc" -eq 0 ]
path1="$(printf '%s' "$u1" | grep -oE '/[^ ]*/deploy-apply\.sh' | head -1)"
path2="$(printf '%s' "$u2" | grep -oE '/[^ ]*/deploy-apply\.sh' | head -1)"
[ -n "$path1" ] && [ -n "$path2" ] && ok || bad "the stage path is not visible in the sudo call: $u1 / $u2"
check "two runs get different stage paths" [ "$path1" != "$path2" ]
if grep -vE '^\s*#' "$here/lib/deploy-core.sh" | grep -q 'mktemp'; then ok; else
  bad "the core's stage is not built with mktemp — apply can become the victim of its own deploy"; fi

echo "== TWO TREES, TWO SHAS: the receipt must not silently carry the estate's =="
# deploy_check_provenance sets the global DEPLOY_SHA, and deploy-self.sh calls it
# twice — product, then estate. The second call used to overwrite the first, so
# the `DEPLOY sha=` receipt identified the ESTATE while claiming to identify the
# deploy. MEASURED 2026-08-19 on a machine with two estates cloned from the SAME
# product: both receipts named their own estate's sha and the product's appeared
# nowhere. Here the fixture repo is BOTH trees, so the shas are equal and no
# assertion can tell them apart — what is asserted is that both are REPORTED.
case "$u1" in *"PROVENANCE product="*"estate="*) ok ;; *) bad "the provenance line names neither tree: $u1" ;; esac

echo "== the manifest is missing: gate 3 (deploy_manifest_sources), rc 65 =="
mv "$FX/repo/linux/deploy-manifest" "$FX/repo/linux/deploy-manifest.bak"
u="$(run testhost testhost)"; rc=$?
check "manifest missing: rc 65" [ "$rc" -eq 65 ]
case "$u" in *SUDO-CALL*) bad "apply was called despite a missing manifest" ;; *) ok ;; esac
mv "$FX/repo/linux/deploy-manifest.bak" "$FX/repo/linux/deploy-manifest"

echo "== a dirty manifest source: gate 4 (deploy_sources_clean), rc 65 =="
printf 'changed\n' >> "$FX/repo/linux/tool-a"
u="$(run testhost testhost)"; rc=$?
check "dirty source: rc 65" [ "$rc" -eq 65 ]
case "$u" in *"linux/tool-a"*) ok ;; *) bad "the file name is missing from the error: $u" ;; esac
case "$u" in *SUDO-CALL*) bad "apply was called despite a dirty source" ;; *) ok ;; esac
( cd "$FX/repo" && git checkout -q -- linux/tool-a )

echo "== deploy-self.sh reached through a SYMLINK, as the hub entry point is =="
# ${BASH_SOURCE[0]} is the SYMLINK's path, not the target's, so the entry point
# must resolve the link itself before working out the product root — otherwise
# the natural PATH installation (`ln -s .../deploy-self.sh ~/bin/deploy-self`,
# the form the docs list the command in) reports "deploy-core.sh: No such file or
# directory" followed by "deploy_home_list: command not found", rc 127,
# untranslated.
symdir="$(mktemp -d)"
ln -s "$SF" "$symdir/deploy-self"
u="$( export PATH="$FX/bin:$PATH" STEWARD_REGISTRY_DIR="$FX/reg" STEWARD_DEPLOY_HOSTNAME=testhost SUDO_RC=0
      export STEWARD_ESTATE="$FX/repo"   # the same estate as run() — without it the case measures the refusal, not the symlink
      export HOME="$FX/home"   # this run reaches rc 0 and now writes the desk drop-in - never the real ~/.config
      bash "$symdir/deploy-self" testhost 2>&1 )"; rc=$?
case "$u" in *"No such file"*) bad "sourcing broke through the symlink: $u" ;; *) ok ;; esac
case "$u" in *"command not found"*) bad "the symlink did not resolve — a follow-on error (command not found): $u" ;; *) ok ;; esac
check "symlink: it reaches execution (rc 0)" [ "$rc" -eq 0 ]
case "$u" in *SUDO-CALL*) ok ;; *) bad "execution was never reached through the symlink: $u" ;; esac
rm -rf "$symdir"

echo "== the sourcing is checked — a broken core gives 70, not a raw bash error =="
corelessdir="$(mktemp -d)"; mkdir -p "$corelessdir/linux"
cp "$SF" "$corelessdir/linux/deploy-self.sh"   # this tree has NO lib/deploy-core.sh
u="$( export PATH="$FX/bin:$PATH" STEWARD_REGISTRY_DIR="$FX/reg" STEWARD_DEPLOY_HOSTNAME=testhost HOME="$FX/home"
      bash "$corelessdir/linux/deploy-self.sh" testhost 2>&1 )"; rc=$?
check "broken core: rc 70" [ "$rc" -eq 70 ]
case "$u" in *"could not read the core"*) ok ;; *) bad "the error message is missing: $u" ;; esac
rm -rf "$corelessdir"

echo "== policy: the entry point's transport is LOCAL =="
if grep -vE '^\s*#' "$S" | grep -Eq '(^|[^a-z])(ssh|scp)($|[^a-z])'; then
  bad "the whole point of the host entry point is to avoid ssh — it calls ssh/scp"; else ok; fi

echo "== the REAL desk-paths bridge, exercised with no STEWARD_DESK_DIR override =="
# Every case above stubs the desk resolution away with STEWARD_DESK_DIR. This
# case does not - it proves the ACTUAL bridge deploy-self.sh falls back to
# (desk/bin/desk-paths, reading the fixture's own estate/steward.conf through
# STEWARD_ESTATE_ROOT) resolves a real directory and the snapshot runs against
# it. Placed LAST, after every other case, so the state directory it creates
# cannot change what an earlier case above observed.
STATEDIR="$FX/home/.local/state/$STATE_DIR_NAME_FX/desk"; mkdir -p "$STATEDIR"
: > "$FX/steward.calls"
u="$(SUDO_RC=0 run testhost testhost)"; rc=$?
check "the real bridge: a successful apply still exits 0" [ "$rc" -eq 0 ]
case "$(cat "$FX/steward.calls")" in
  *"desk snapshot"*) ok ;;
  *) bad "the real bridge did not resolve a directory the deploy could take a snapshot in: '$(cat "$FX/steward.calls")'" ;;
esac
estate_root_expect="$(CDPATH= cd -- "$FX/repo" && pwd)"
case "$(cat "$FX/steward.calls")" in
  *"env STEWARD_ESTATE_ROOT=$estate_root_expect"*) ok ;;
  *) bad "the real-bridge snapshot call did not carry the canonical estate root ($estate_root_expect): '$(cat "$FX/steward.calls")'" ;;
esac
case "$u" in
  *"could not be resolved"*) bad "the real bridge worked but the deploy still reported it could not resolve the desk: $u" ;;
  *) ok ;;
esac

echo "== the bridge refusing (estate file unreadable): rc 70, diagnosis printed =="
# STEWARD_DESK_DIR stays unset here too, so resolution falls through to the
# real bridge - and the bridge refuses because its estate file is gone. This
# is the case a STEWARD_ESTATE directory leaking into the library used to
# produce silently (rc 0, snapshot skipped, nothing on stderr).
mv "$FX/repo/estate/steward.conf" "$FX/repo/estate/steward.conf.bak"
: > "$FX/steward.calls"
u="$(SUDO_RC=0 run testhost testhost)"; rc=$?
check "the bridge refusing: rc 70" [ "$rc" -eq 70 ]
case "$u" in *"could not be resolved"*) ok ;; *) bad "no diagnosis for the unresolved desk directory: $u" ;; esac
case "$(cat "$FX/steward.calls")" in
  *"desk snapshot"*) bad "the snapshot ran despite the bridge refusing" ;;
  *) ok ;;
esac
mv "$FX/repo/estate/steward.conf.bak" "$FX/repo/estate/steward.conf"

rm -rf "$FX"
echo "pass=$pass fail=$fail"
[ "$fail" -eq 0 ]
