#!/bin/bash
# test/estate-status-sort.test.sh — the estate-listing table's own --sort,
# reordering the rows on the underlying field, never the rendered text.
#
# WHY THIS EXISTS. `steward sessions --sort` (1503e29) never reached the
# ESTATE listing form (`steward <estate> ls`): measured live, `steward
# <estate> ls --sort slug` neither sorted nor refused — the flag was silently
# swallowed on the way from bin/steward's dispatcher into cmd_ls. Silent
# flag-swallowing is worse than the flag not existing at all. This suite
# covers the RENDERER's half of the fix: linux/estate-status.sh, the script
# that actually owns this table's raw '|'-delimited rows before the final
# `column -t` render. bin/steward's own plumbing (the dispatcher forwarding
# the flag, and cmd_ls validating it before ever touching ssh) has no test
# harness for the ssh-based estate routes to extend — there is none in this
# suite today — so that half is covered by direct manual verification of the
# generated remote command string; this file only exercises the script both
# sides of that ssh hop actually run.
#
# THE FIXTURE DISAGREES ON PURPOSE, same shape as test/sessions-command.test.sh's
# --sort fixture: three sessions whose NAME order disagrees with SLUG order,
# OWNER order, HOST order and RC_LABEL (display) order. A fixture that agreed
# under every key could not tell "the flag reordered the rows" from "the rows
# were already in that order".
set -u
here="$(CDPATH= cd -- "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
pass=0; fail=0
ok()  { pass=$((pass+1)); printf '  ok   %s\n' "$1"; }
bad() { fail=$((fail+1)); printf '  FAIL %s\n     %s\n' "$1" "${2:-}"; }
is()  { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "wanted '$3', got '$2'"; fi; }
has() { case "$2" in *"$3"*) ok "$1" ;; *) bad "$1" "missing '$3' in: $2" ;; esac; }

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
mkdir -p "$T/sessions.d" "$T/estate" "$T/bin" "$T/home/.tmux"

cat > "$T/estate/steward.conf" <<'EOF'
LABEL_PREFIX="com.example.claude"
RC_LABEL_PREFIX="Example: "
HUB_SESSION="examplehub"
HUB_HOST="examplehost"
STATE_DIR_NAME="example-supervisor"
PAUSED_DIR_NAME="example-paused"
JOB_LOG_DIR="example-jobs"
TMUX_SOCKET="example.sock"
EOF

# name=asess: OWNER first alphabetically, HOST last, SLUG last, display first.
printf 'HOST="hzz"\nOWNER="aowner"\nDOMAIN="example"\nRC_LABEL="rlA"\nSLUG="zzz-slug"\n' \
  > "$T/sessions.d/asess.conf"
# name=msess: OWNER middle, HOST middle, NO SLUG (the dash case), display middle.
printf 'HOST="hmm"\nOWNER="mowner"\nDOMAIN="example"\nRC_LABEL="rlM"\n' \
  > "$T/sessions.d/msess.conf"
# name=zsess: OWNER last, HOST first, SLUG first, display last.
printf 'HOST="haa"\nOWNER="zowner"\nDOMAIN="example"\nRC_LABEL="rlZ"\nSLUG="aaa-slug"\n' \
  > "$T/sessions.d/zsess.conf"

cat > "$T/bin/tmux" <<'EOF'
#!/bin/bash
exit 0
EOF
chmod +x "$T/bin/tmux"

run() { STEWARD_ESTATE_ROOT="$T" STEWARD_REGISTRY_DIR="$T/sessions.d" \
        STEWARD_SELF_HOST="examplehost" STEWARD_SELF_USER="exampleuser" \
        HOME="$T/home" PATH="$T/bin:$PATH" \
        bash "$here/linux/estate-status.sh" "$@"; }
# THE ORDER OF THE THREE SESSION NAMES, READ OFF THE TABLE'S OWN SESSION
# COLUMN — not a substring search, which cannot tell order from mere
# presence. `column -t`'s leading ownership-marker column is '*' for a row the
# viewer owns and a single space otherwise; awk's default whitespace-FS
# collapses the space marker into nothing (SESSION lands in $1) but keeps the
# '*' as its own field (SESSION lands in $2) — so this scans every field on
# the line for the one that IS a session name, rather than trusting a fixed
# column number either way.
order() {
  printf '%s\n' "$1" | awk '{ for (i = 1; i <= NF; i++) if ($i ~ /^(asess|msess|zsess)$/) { print $i; next } }' | tr '\n' ','
}

echo "== estate-status --sort: default order is unchanged =="
is "default order is name order" "$(order "$(run)")" "asess,msess,zsess,"

echo "== estate-status --sort name: same as today's order, named explicitly =="
is "name order" "$(order "$(run --sort name)")" "asess,msess,zsess,"

echo "== estate-status --sort owner: alphabetical by OWNER =="
is "owner order" "$(order "$(run --sort owner)")" "asess,msess,zsess,"

echo "== estate-status --sort host: alphabetical by HOST, disagrees with name order =="
is "host order" "$(order "$(run --sort host)")" "zsess,msess,asess,"

echo "== estate-status --sort display: alphabetical by RC_LABEL =="
is "display order" "$(order "$(run --sort display)")" "asess,msess,zsess,"

echo "== estate-status --sort slug: alphabetical by SLUG, dash (no slug) last =="
is "slug order, dash last" "$(order "$(run --sort slug)")" "zsess,asess,msess,"

echo "== estate-status --sort with an unknown key refuses, listing the valid ones =="
uerr="$(mktemp)"
uout="$(run --sort bogus 2>"$uerr")"; urc=$?
uerrtext="$(cat "$uerr")"; rm -f "$uerr"
is "rc is 64" "$urc" "64"
is "stdout is empty" "$uout" ""
has "names the bad key" "$uerrtext" "bogus"
has "lists slug"    "$uerrtext" "slug"
has "lists display" "$uerrtext" "display"
has "lists owner"   "$uerrtext" "owner"
has "lists host"    "$uerrtext" "host"
has "lists name"    "$uerrtext" "name"

echo "== estate-status: an unrelated unknown flag still refuses rc 64 (unchanged) =="
berr="$(mktemp)"
bout="$(run --bogus 2>"$berr")"; brc=$?
berrtext="$(cat "$berr")"; rm -f "$berr"
is "rc is 64" "$brc" "64"
is "stdout is empty" "$bout" ""
has "names the bad option" "$berrtext" "bogus"

echo "== estate-status: --mine and --sort still combine =="
mout="$(STEWARD_ESTATE_ROOT="$T" STEWARD_REGISTRY_DIR="$T/sessions.d" \
        STEWARD_SELF_HOST="examplehost" STEWARD_SELF_USER="aowner" \
        HOME="$T/home" PATH="$T/bin:$PATH" \
        bash "$here/linux/estate-status.sh" --mine --sort host 2>&1)"
is "only the owned row" "$(order "$mout")" "asess,"

echo
printf 'pass=%s fail=%s\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
