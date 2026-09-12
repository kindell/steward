#!/bin/bash
# test/run-tests-rust-not-run.test.sh - a rust suite on a host without cargo is NOT RUN, said in the
# summary as rust=not-run, and is neither red nor swept under; with cargo it is ok or RED like any suite.
#
# Both steward homes lacked Rust on 2026-09-12 and every full gate carried one red meaning "no
# cargo here". A red that is always there is a red nobody reads. The missing tool is still never
# green: the line says NOT RUN with the path, and the summary carries it.
set -u
here="$(CDPATH= cd -- "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
pass=0; fail=0
ok()  { pass=$((pass+1)); printf '  ok   %s\n' "$1"; }
bad() { fail=$((fail+1)); printf '  FAIL %s\n     %s\n' "$1" "${2:-}"; }
has() { case "$2" in *"$3"*) ok "$1" ;; *) bad "$1" "missing '$3' in: $(printf '%s' "$2" | tr '\n' ' ' | cut -c1-200)" ;; esac; }
hasnt() { case "$2" in *"$3"*) bad "$1" "unexpected '$3' in: $(printf '%s' "$2" | tr '\n' ' ' | cut -c1-200)" ;; *) ok "$1" ;; esac; }
FX="$(mktemp -d)"; trap 'rm -rf "$FX"' EXIT
mkdir -p "$FX/tree/tools" "$FX/tree/test" "$FX/tree/cockpit" "$FX/bin"; cp "$here/tools/run-tests.sh" "$FX/tree/tools/"
printf '#!/bin/bash\necho "pass=1 fail=0"\n' > "$FX/tree/test/tiny.test.sh"; chmod +x "$FX/tree/test/tiny.test.sh"
run() { ( cd "$FX/tree" && CARGO="$1" bash tools/run-tests.sh . 2>&1 ); }

echo "== 1. no cargo: NOT RUN, said, not red, not swept =="
out="$(run "$FX/bin/no-such-cargo")"; rc=$?
has   "1a NOT RUN line names the suite and the path" "$out" "NOT RUN cockpit"
has   "1b ... with the path that was looked at"      "$out" "$FX/bin/no-such-cargo"
has   "1c summary carries rust=not-run"              "$out" "rust=not-run"
has   "1d and red=0"                                 "$out" "red=0"
hasnt "1e the sweep does not REFUSE a suite that was said not to run" "$out" "REFUSED"
[ "$rc" -eq 0 ] && ok "1f runner rc 0" || bad "1f runner rc $rc"
echo "== 2. a cargo that passes: ok, rust=ok =="
printf '#!/bin/bash\nexit 0\n' > "$FX/bin/cargo-ok"; chmod +x "$FX/bin/cargo-ok"
out="$(run "$FX/bin/cargo-ok")"
has "2a ok line"          "$out" "ok     cockpit"
has "2b summary rust=ok"  "$out" "rust=ok"
echo "== 3. a cargo that fails: RED, counted, rust=RED =="
printf '#!/bin/bash\nexit 1\n' > "$FX/bin/cargo-red"; chmod +x "$FX/bin/cargo-red"
out="$(run "$FX/bin/cargo-red")"
has "3a RED line"          "$out" "RED    cockpit"
has "3b counted in red="   "$out" "red=1"
has "3c summary rust=RED"  "$out" "rust=RED"
echo "== 4. no rust suite in the tree: rust=none =="
rm -rf "$FX/tree/cockpit"; out="$(run "$FX/bin/cargo-ok")"
has "4a summary rust=none" "$out" "rust=none"

printf '\n  %d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
