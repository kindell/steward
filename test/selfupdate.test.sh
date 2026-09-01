#!/bin/bash
# test/selfupdate.test.sh — `steward selfupdate`, the verb that brings the two
# checkouts an operator actually runs from up to date, and refuses loudly
# rather than doing anything clever with work it did not write.
#
# THE CONTRACT UNDER TEST, in one place:
#
#   1. the PRODUCT (this repo, found from where bin/steward itself lives) is
#      pulled --ff-only
#   2. the ESTATE, when the operator config or STEWARD_ESTATE_ROOT names one
#      and that name is a git checkout, is pulled --ff-only too
#   3. the cockpit is rebuilt when — and only when — this machine has already
#      built one, and SKIPs loudly when there is no cargo to rebuild it with
#   4. one receipt line per repo: `<name>: <from> -> <to>` or `already current`
#
#   REFUSALS, both rc 65: a dirty tree in either checkout (named, never
#   stashed), and a pull that cannot fast-forward (reconcile it by hand). A
#   MISSING estate root is not a refusal at all — it is an ordinary
#   product-only update that says so.
#
# WHY THE FIXTURE COPIES bin/steward INTO A THROWAWAY REPO. The verb derives
# the product root from its own file's location, which is the whole design:
# an operator's symlink on PATH must still update the checkout it aims at.
# Run straight out of this working tree, the suite would therefore pull THIS
# repo — a test that mutates the tree it is measuring. So each case builds a
# private product checkout and runs the copy that lives inside it. Nothing
# here touches the real checkout, the real ~/.config/steward, or any remote.
#
# WHY BUNDLES ARE THE ORIGIN. A `git bundle` is a single file that clone and
# fetch both speak, so an upstream that gains a commit is one re-bundle away
# and needs no daemon, no bare directory dance and no network. Re-creating
# the bundle is exactly what "someone pushed while you were out" looks like
# from the checkout's side.
#
# Exit code: 0 = the verb keeps its contract · 1 = it does not
set -u

here="$(CDPATH= cd -- "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
STEWARD_SRC="$here/bin/steward"
pass=0; fail=0
ok()   { pass=$((pass+1)); printf '  ok   %s\n' "$1"; }
bad()  { fail=$((fail+1)); printf '  FAIL %s\n     %s\n' "$1" "${2:-}"; }
is()   { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "wanted '$3', got '$2'"; fi; }
has()  { case "$2" in *"$3"*) ok "$1" ;; *) bad "$1" "missing '$3' in: $2" ;; esac; }
hasnt(){ case "$2" in *"$3"*) bad "$1" "unwanted '$3' found in: $2" ;; *) ok "$1" ;; esac; }

FX="$(mktemp -d)"; trap 'rm -rf "$FX"' EXIT

# The fixture repos are committed by a fixture identity, so the suite never
# reads — or needs — whatever identity the machine running it has.
export GIT_AUTHOR_NAME="fixture" GIT_AUTHOR_EMAIL="fixture@example.invalid"
export GIT_COMMITTER_NAME="fixture" GIT_COMMITTER_EMAIL="fixture@example.invalid"

# ── THE CARGO STUBS ────────────────────────────────────────────────────────
# One records its argv, one fails. Neither compiles anything: what the verb
# owes the operator is the right command line and an honest rc, and a real
# cargo run would measure Rust rather than this verb. The log path is derived
# from the stub's own location so no environment has to carry it in.
mkdir -p "$FX/bin"
cat > "$FX/bin/cargo" <<'STUB'
#!/bin/bash
printf '%s\n' "$*" >> "$(dirname "$0")/../cargo.log"
STUB
cat > "$FX/bin/cargo-broken" <<'STUB'
#!/bin/bash
printf '%s\n' "$*" >> "$(dirname "$0")/../cargo.log"
echo "error: could not compile cockpit" >&2
exit 101
STUB
chmod +x "$FX/bin/cargo" "$FX/bin/cargo-broken"

# A PATH holding only the handful of external programs this script reaches
# for, and no cargo of any kind. Inheriting the caller's PATH for the
# cargo-missing case would make that case depend on whether the machine
# running the suite happens to have Rust installed — the one case whose whole
# subject is a machine that does not.
mkdir -p "$FX/toolbin"
for _t in bash sh git dirname readlink stat basename sed grep cat; do
  _p="$(command -v "$_t" 2>/dev/null)" && ln -sf "$_p" "$FX/toolbin/$_t"
done

# ── THE FIXTURE ────────────────────────────────────────────────────────────
n_case=0
W=""

seed() { # <workspace> <name> [extra] — an upstream repo plus its bundle
  local w="$1" n="$2" d="$1/src/$2"
  mkdir -p "$d"
  git init -q "$d" 2>/dev/null
  git -C "$d" symbolic-ref HEAD refs/heads/main
  printf 'first\n' > "$d/README"
  if [ "$n" = "product" ]; then
    mkdir -p "$d/bin" "$d/cockpit"
    cp "$STEWARD_SRC" "$d/bin/steward"; chmod +x "$d/bin/steward"
    printf 'cockpit/target/\n' > "$d/.gitignore"
    printf '[package]\nname = "cockpit"\nversion = "0.0.0"\n' > "$d/cockpit/Cargo.toml"
  fi
  git -C "$d" add -A
  git -C "$d" commit -qm "first"
  git -C "$d" bundle create "$w/$n.bundle" --all >/dev/null 2>&1
}

advance() { # <workspace> <name> <text> — one more commit upstream, re-bundled
  local w="$1" n="$2" d="$1/src/$2"
  printf '%s\n' "$3" >> "$d/README"
  git -C "$d" commit -qam "$3"
  git -C "$d" bundle create "$w/$n.bundle" --all >/dev/null 2>&1
}

fixture() { # -> $W: a fresh product checkout, a fresh estate checkout, a home
  n_case=$((n_case+1))
  W="$FX/w$n_case"
  mkdir -p "$W/home"
  seed "$W" product
  seed "$W" estate
  git clone -q "$W/product.bundle" "$W/product" 2>/dev/null
  git clone -q "$W/estate.bundle" "$W/estate" 2>/dev/null
  # A machine that has built the cockpit before. The file is ignored by the
  # checkout's own .gitignore, exactly as a real target/ directory is.
  mkdir -p "$W/product/cockpit/target/release"
  printf '#!/bin/sh\ntrue\n' > "$W/product/cockpit/target/release/cockpit"
  chmod +x "$W/product/cockpit/target/release/cockpit"
  rm -f "$FX/cargo.log"
}

sha() { git -C "$1" rev-parse --short HEAD 2>/dev/null; }

RUN_PATH=""
run() { # <workspace> [VAR=value ...] — selfupdate, both streams merged
  local w="$1"; shift
  env -i PATH="${RUN_PATH:-$PATH}" HOME="$w/home" GIT_CONFIG_NOSYSTEM=1 "$@" \
    bash "$w/product/bin/steward" selfupdate 2>&1
}

cargo_log() { cat "$FX/cargo.log" 2>/dev/null; }

echo "== 1. a clean update: both checkouts move, and each says how far =="
fixture
advance "$W" product "second"
advance "$W" estate "second"
from_p="$(sha "$W/product")"; from_e="$(sha "$W/estate")"
out="$(run "$W" STEWARD_ESTATE_ROOT="$W/estate" STEWARD_CARGO_BIN="$FX/bin/cargo")"; rc=$?
to_p="$(sha "$W/product")"; to_e="$(sha "$W/estate")"
is   "clean update: rc 0" "$rc" "0"
has  "clean update: the product receipt names both ends" "$out" "product: $from_p -> $to_p"
has  "clean update: the estate receipt names both ends"  "$out" "estate: $from_e -> $to_e"
if [ "$from_p" != "$to_p" ]; then ok "clean update: the product actually moved"; else bad "clean update: the product actually moved" "still at $from_p"; fi
if [ "$from_e" != "$to_e" ]; then ok "clean update: the estate actually moved"; else bad "clean update: the estate actually moved" "still at $from_e"; fi
has  "clean update: the working tree carries the new commit" "$(cat "$W/product/README")" "second"
has  "clean update: the cockpit was rebuilt" "$out" "cockpit: rebuilt"
has  "clean update: cargo was called with the release manifest" "$(cargo_log)" \
     "build --release --manifest-path $W/product/cockpit/Cargo.toml"

echo "== 2. the receipts are stdout; a clean run says nothing on stderr =="
fixture
advance "$W" product "second"
from_p="$(sha "$W/product")"
onlyout="$(env -i PATH="$PATH" HOME="$W/home" GIT_CONFIG_NOSYSTEM=1 \
  STEWARD_ESTATE_ROOT="$W/estate" STEWARD_CARGO_BIN="$FX/bin/cargo" \
  bash "$W/product/bin/steward" selfupdate 2>/dev/null)"; rc=$?
onlyerr="$(env -i PATH="$PATH" HOME="$W/home" GIT_CONFIG_NOSYSTEM=1 \
  STEWARD_ESTATE_ROOT="$W/estate" STEWARD_CARGO_BIN="$FX/bin/cargo" \
  bash "$W/product/bin/steward" selfupdate 2>&1 >/dev/null)"
is  "streams: rc 0" "$rc" "0"
has "streams: the product receipt is on stdout" "$onlyout" "product: $from_p -> $(sha "$W/product")"
is  "streams: nothing on stderr" "$onlyerr" ""

echo "== 3. nothing upstream: 'already current', for both, and still rc 0 =="
fixture
out="$(run "$W" STEWARD_ESTATE_ROOT="$W/estate" STEWARD_CARGO_BIN="$FX/bin/cargo")"; rc=$?
is  "already current: rc 0" "$rc" "0"
has "already current: the product says so" "$out" "product: already current"
has "already current: the estate says so"  "$out" "estate: already current"
hasnt "already current: no arrow is printed for a repo that did not move" "$out" "->"

echo "== 4. a dirty product refuses, names itself, and never stashes =="
fixture
advance "$W" product "second"
printf 'local edit\n' >> "$W/product/README"
before_p="$(sha "$W/product")"; before_e="$(sha "$W/estate")"
out="$(run "$W" STEWARD_ESTATE_ROOT="$W/estate" STEWARD_CARGO_BIN="$FX/bin/cargo")"; rc=$?
is  "dirty product: rc 65" "$rc" "65"
has "dirty product: the refusal names the product"  "$out" "product"
has "dirty product: the refusal names the checkout" "$out" "$W/product"
hasnt "dirty product: nothing is stashed" "$out" "stash"
is  "dirty product: the product did not move" "$(sha "$W/product")" "$before_p"
is  "dirty product: the estate did not move either" "$(sha "$W/estate")" "$before_e"
has "dirty product: the local edit is still there" "$(cat "$W/product/README")" "local edit"
is  "dirty product: cargo was never called" "$(cargo_log)" ""

echo "== 5. a dirty ESTATE refuses before the product is touched =="
fixture
advance "$W" product "second"
printf 'local edit\n' >> "$W/estate/README"
before_p="$(sha "$W/product")"
out="$(run "$W" STEWARD_ESTATE_ROOT="$W/estate" STEWARD_CARGO_BIN="$FX/bin/cargo")"; rc=$?
is  "dirty estate: rc 65" "$rc" "65"
has "dirty estate: the refusal names the estate"   "$out" "estate"
has "dirty estate: the refusal names the checkout" "$out" "$W/estate"
hasnt "dirty estate: nothing is stashed" "$out" "stash"
is  "dirty estate: the product was left alone" "$(sha "$W/product")" "$before_p"

echo "== 6. untracked files are not dirt: an update runs straight through =="
fixture
advance "$W" product "second"
printf 'scratch\n' > "$W/product/NOTES.local"
from_p="$(sha "$W/product")"
out="$(run "$W" STEWARD_ESTATE_ROOT="$W/estate" STEWARD_CARGO_BIN="$FX/bin/cargo")"; rc=$?
is  "untracked: rc 0" "$rc" "0"
has "untracked: the product still updated" "$out" "product: $from_p -> $(sha "$W/product")"

echo "== 7. a pull that cannot fast-forward refuses and says reconcile =="
fixture
printf 'work of my own\n' > "$W/product/MINE"
git -C "$W/product" add MINE
git -C "$W/product" commit -qm "local work"
advance "$W" product "someone else was here"
before_p="$(sha "$W/product")"; before_e="$(sha "$W/estate")"
out="$(run "$W" STEWARD_ESTATE_ROOT="$W/estate" STEWARD_CARGO_BIN="$FX/bin/cargo")"; rc=$?
is  "non-ff: rc 65" "$rc" "65"
has "non-ff: the refusal names the product"   "$out" "product"
has "non-ff: the refusal names the checkout"  "$out" "$W/product"
has "non-ff: the operator is told to reconcile it by hand" "$out" "Reconcile it by hand"
is  "non-ff: the product stayed where it was" "$(sha "$W/product")" "$before_p"
is  "non-ff: the estate was not pulled either" "$(sha "$W/estate")" "$before_e"
is  "non-ff: cargo was never called" "$(cargo_log)" ""

echo "== 8. no estate root at all: a product-only update that says so =="
fixture
advance "$W" product "second"
from_p="$(sha "$W/product")"
out="$(run "$W" STEWARD_CARGO_BIN="$FX/bin/cargo")"; rc=$?
is  "no estate: rc 0 — a missing estate root is not an error" "$rc" "0"
has "no estate: the product receipt is still printed" "$out" "product: $from_p -> $(sha "$W/product")"
has "no estate: the run says the product was updated on its own" "$out" "product on its own"
hasnt "no estate: no estate receipt is invented" "$out" "estate: already current"

echo "== 9. an estate root that names nothing, and one that is no checkout =="
fixture
advance "$W" product "second"
out="$(run "$W" STEWARD_ESTATE_ROOT="$W/nowhere" STEWARD_CARGO_BIN="$FX/bin/cargo")"; rc=$?
is  "absent estate root: rc 0" "$rc" "0"
has "absent estate root: it is named in the note" "$out" "$W/nowhere"
has "absent estate root: still a product-only update" "$out" "product on its own"
mkdir -p "$W/plainbox"
out="$(run "$W" STEWARD_ESTATE_ROOT="$W/plainbox" STEWARD_CARGO_BIN="$FX/bin/cargo")"; rc=$?
is  "estate root is no checkout: rc 0" "$rc" "0"
has "estate root is no checkout: the note says why" "$out" "not a git checkout"

echo "== 10. the estate root read from the operator config file (FORMAT=1) =="
fixture
advance "$W" product "second"
advance "$W" estate "second"
mkdir -p "$W/home/.config/steward"
printf 'FORMAT=1\nSTEWARD_ESTATE_ROOT=%s\n' "$W/estate" > "$W/home/.config/steward/config"
chmod 600 "$W/home/.config/steward/config"
from_e="$(sha "$W/estate")"
out="$(run "$W" STEWARD_CARGO_BIN="$FX/bin/cargo")"; rc=$?
is  "config file: rc 0" "$rc" "0"
has "config file: the estate named by the file was pulled" "$out" "estate: $from_e -> $(sha "$W/estate")"

echo "== 11. no cargo anywhere: a loud SKIP, not a silent one, and not a failure =="
fixture
advance "$W" product "second"
from_p="$(sha "$W/product")"
RUN_PATH="$FX/toolbin"
out="$(run "$W" STEWARD_ESTATE_ROOT="$W/estate")"; rc=$?
RUN_PATH=""
is  "no cargo: rc 0 — a skipped rebuild is not a failed update" "$rc" "0"
has "no cargo: the cockpit line says SKIP" "$out" "cockpit: SKIP"
has "no cargo: the note names cargo" "$out" "cargo"
has "no cargo: the note names the way out" "$out" "STEWARD_CARGO_BIN"
has "no cargo: the pull itself still happened" "$out" "product: $from_p -> $(sha "$W/product")"

echo "== 12. a cockpit this machine never built is not rebuilt behind its back =="
fixture
rm -rf "$W/product/cockpit/target"
out="$(run "$W" STEWARD_ESTATE_ROOT="$W/estate" STEWARD_CARGO_BIN="$FX/bin/cargo")"; rc=$?
is  "no cockpit binary: rc 0" "$rc" "0"
has "no cockpit binary: the line says there is nothing to rebuild" "$out" "nothing to rebuild"
is  "no cockpit binary: cargo was never called" "$(cargo_log)" ""

echo "== 13. a rebuild that fails is a failure, after honest pull receipts =="
fixture
advance "$W" product "second"
from_p="$(sha "$W/product")"
out="$(run "$W" STEWARD_ESTATE_ROOT="$W/estate" STEWARD_CARGO_BIN="$FX/bin/cargo-broken")"; rc=$?
is  "broken build: rc 70" "$rc" "70"
has "broken build: the pull receipt was printed first" "$out" "product: $from_p -> $(sha "$W/product")"
has "broken build: the failure is named" "$out" "cockpit"

echo "== 14. a product root that is no checkout refuses rather than guessing =="
mkdir -p "$FX/loose/bin" "$FX/loose/home"
cp "$STEWARD_SRC" "$FX/loose/bin/steward"; chmod +x "$FX/loose/bin/steward"
out="$(env -i PATH="$PATH" HOME="$FX/loose/home" GIT_CONFIG_NOSYSTEM=1 \
  bash "$FX/loose/bin/steward" selfupdate 2>&1)"; rc=$?
is  "loose install: rc 65" "$rc" "65"
has "loose install: the refusal names the root it looked at" "$out" "$FX/loose"
has "loose install: the refusal says what it wanted" "$out" "git checkout"

echo "== 15. the verb takes no arguments, and the usage lists it =="
fixture
out="$(env -i PATH="$PATH" HOME="$W/home" GIT_CONFIG_NOSYSTEM=1 \
  bash "$W/product/bin/steward" selfupdate --now 2>&1)"; rc=$?
is  "argument: rc 64" "$rc" "64"
has "argument: the usage line is shown" "$out" "steward selfupdate"
out="$(env -i PATH="$PATH" HOME="$W/home" GIT_CONFIG_NOSYSTEM=1 \
  bash "$W/product/bin/steward" --help 2>&1)"; rc=$?
is  "help: rc 0" "$rc" "0"
has "help: selfupdate is listed" "$out" "steward selfupdate"

echo
printf 'pass=%s fail=%s\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
