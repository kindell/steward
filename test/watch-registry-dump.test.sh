#!/bin/bash
# test/watch-registry-dump.test.sh — the watch's one window into the registry.
#
# The watch reads sessions, hosts and the estate through lib/registry.sh, never
# with a parser of its own: this bridge sources the library and prints what it
# says. An ordinary malformed row is skipped and named; invalid account
# identity refuses the dump rather than publishing an incomplete watch set. An
# RC-free row and a migrated row without a label line both come out with an
# empty rcLabel (supervised on the pane); the required estate keys refuse, the
# optional ones come out empty.
set -u
here="$(CDPATH= cd -- "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
pass=0; fail=0
ok()  { pass=$((pass+1)); printf '  ok   %s\n' "$1"; }
bad() { fail=$((fail+1)); printf '  FAIL %s\n     %s\n' "$1" "${2:-}"; }
is()  { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "wanted '$3', got '$2'"; fi; }
has() { case "$2" in *"$3"*) ok "$1" ;; *) bad "$1" "missing '$3' in: $2" ;; esac; }
DUMP="$here/watch/bin/registry-dump"

FX="$(mktemp -d)"; trap 'rm -rf "$FX"' EXIT
mkdir -p "$FX/reg" "$FX/hosts.d" "$FX/accounts.d"
cat > "$FX/estate.conf" <<'EOF'
RC_LABEL_PREFIX="Hub: "
HUB_SESSION="hub-one"
HUB_HOST="host-one"
TMUX_SOCKET="hub-one.sock"
PING_MSG="[bus] you have mail"
STATE_DIR_NAME="hub-supervisor"
PAUSED_DIR_NAME="hub-paused"
OP_TOKEN_FILE_NAME="op-token"
JOB_LOG_DIR="hub-jobs"
JOB_LABEL_PREFIX="io.example.job"
SERVICE_LABEL_PREFIX="io.example.service"
BROWSER_LABEL_PREFIX="io.example.browser"
LABEL_PREFIX="io.example"
EOF
printf 'REPO_PATH="/tmp/x"\nRC_LABEL="Hub: alpha"\nOWNER="operator-a"\nDOMAIN="entity-one"\n' > "$FX/reg/alpha.conf"
printf 'REPO_PATH="/tmp/x"\nRC_LABEL=""\nOWNER="operator-m"\nDOMAIN="machine"\nHOST="host-two"\n' > "$FX/reg/machine.conf"
printf 'ID="s-00000000000000aa"\nSLUG="gamma"\nACCOUNT="operator-a-hub"\nTARGET_ENTITY="e-0000000000000001"\nREPO_PATH="/tmp/x"\nOWNER="operator-a"\nDOMAIN="entity-one"\n' > "$FX/reg/s-00000000000000aa.conf"
printf 'PRINCIPAL="operator-a"\nUSERNAME="operator-a"\nHOST="host-one"\n' > "$FX/accounts.d/operator-a-hub.conf"
printf 'RC_LABEL="Hub: broken"\nOWNER="operator-a"\nDOMAIN="d"\n' > "$FX/reg/broken.conf"   # no REPO_PATH: the registry refuses it
printf 'OWNER="operator-a"\nLEGAL_OWNER="Somebody"\nOPERATOR="hub-one"\n' > "$FX/hosts.d/host-two.conf"
printf 'OWNER="operator-b"\nLEGAL_OWNER="Somebody"\nOPERATOR="hub-two"\n' > "$FX/hosts.d/host-three.conf"
run() { STEWARD_ESTATE="$FX/estate.conf" STEWARD_REGISTRY_DIR="$FX/reg" STEWARD_HOSTS_DIR="$FX/hosts.d" STEWARD_ACCOUNT_DIR="$FX/accounts.d" bash "$DUMP" "$@"; }

echo "1. sessions"
out="$(run sessions 2>"$FX/err")"; rc=$?
is  "rc 0" "$rc" "0"
is  "three rows come out (the refused one does not)" "$(printf '%s\n' "$out" | grep -c .)" "3"
has "the refused row is named on stderr" "$(cat "$FX/err")" "broken: the registry refuses the row"
a="$(printf '%s\n' "$out" | jq -c 'select(.name=="alpha")')"
is  "alpha: rcLabel" "$(printf '%s' "$a" | jq -r .rcLabel)" "Hub: alpha"
is  "alpha: label is the display" "$(printf '%s' "$a" | jq -r .label)" "Hub: alpha"
is  "alpha: host defaults to the hub host (the registry's rule, not the watch's)" "$(printf '%s' "$a" | jq -r .host)" "host-one"
is  "alpha: owner" "$(printf '%s' "$a" | jq -r .owner)" "operator-a"
m="$(printf '%s\n' "$out" | jq -c 'select(.name=="machine")')"
is  "RC-free row: rcLabel is empty, the row is IN" "$(printf '%s' "$m" | jq -r .rcLabel)" ""
is  "RC-free row: host as written" "$(printf '%s' "$m" | jq -r .host)" "host-two"
g="$(printf '%s\n' "$out" | jq -c 'select(.name=="s-00000000000000aa")')"
is  "migrated row: rcLabel empty (no label line, a target instead)" "$(printf '%s' "$g" | jq -r .rcLabel)" ""
is  "migrated row: slug"  "$(printf '%s' "$g" | jq -r .slug)" "gamma"
is  "migrated row: id"    "$(printf '%s' "$g" | jq -r .id)" "s-00000000000000aa"

printf 'ACCOUNT="missing-account"\nOWNER="operator-a"\nHOST="host-one"\nDOMAIN="entity-one"\nRC_LABEL="Bad"\nREPO_PATH="/tmp/x"\n' > "$FX/reg/account-broken.conf"
out="$(run sessions 2>"$FX/account-err")"; rc=$?
is  "invalid account identity refuses the whole dump with rc 78" "$rc" "78"
is  "the refused dump prints no partial rows" "$out" ""
has "the account refusal is diagnosed" "$(cat "$FX/account-err")" "missing-account"
rm -f "$FX/reg/account-broken.conf"

echo "2. hosts"
is "hosts.d => {host: OPERATOR}" "$(run hosts 2>/dev/null | jq -Sc .)" '{"host-three":"hub-two","host-two":"hub-one"}'

echo "3. estate"
e="$(run estate 2>/dev/null)"; rc=$?
is  "rc 0" "$rc" "0"
is  "hubSession"  "$(printf '%s' "$e" | jq -r .hubSession)" "hub-one"
is  "tmuxSocket"  "$(printf '%s' "$e" | jq -r .tmuxSocket)" "hub-one.sock"
is  "pingMsg"     "$(printf '%s' "$e" | jq -r .pingMsg)" "[bus] you have mail"
is  "the alarm channel is EMPTY when the estate names none (the watch decides)" "$(printf '%s' "$e" | jq -r '.mailAccountFile + "|" + .alertTo')" "|"
is  "the probe hooks are EMPTY when absent"    "$(printf '%s' "$e" | jq -r '.jobStatusCmd + "|" + .hostStatusCmd')" "|"
printf 'MAIL_ACCOUNT_FILE="alerts.env"\nALERT_TO="human@example.invalid"\nJOB_STATUS_CMD="/opt/probe/jobs --json"\n' >> "$FX/estate.conf"
e="$(run estate 2>/dev/null)"
is  "...and filled when present" "$(printf '%s' "$e" | jq -r '.mailAccountFile + "|" + .alertTo + "|" + .jobStatusCmd')" "alerts.env|human@example.invalid|/opt/probe/jobs --json"
printf 'RC_LABEL_PREFIX="Hub: "\nHUB_HOST="host-one"\n' > "$FX/estate-bare.conf"
STEWARD_ESTATE="$FX/estate-bare.conf" STEWARD_REGISTRY_DIR="$FX/reg" bash "$DUMP" estate >/dev/null 2>&1; rc=$?
is  "a required key missing (HUB_SESSION): rc 78" "$rc" "78"
bash "$DUMP" >/dev/null 2>&1; rc=$?
is  "no subcommand: rc 64" "$rc" "64"

echo
printf '%s: %d passed, %d failed\n' "$(basename "$0")" "$pass" "$fail"
[ "$fail" -eq 0 ]
