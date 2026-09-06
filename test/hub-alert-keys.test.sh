#!/bin/bash
# test/hub-alert-keys.test.sh — the watch's alarm channel as estate data.
#
# MAIL_ACCOUNT_FILE names ONE file under the mail-accounts directory - never a
# path, never the content. ALERT_TO is the address the alarms go to. Both are
# read like every estate value: form-checked, and ABSENT IS A REFUSAL (rc 78),
# not a default - a watch without an alarm channel must say so, not fall silent.
set -u
here="$(CDPATH= cd -- "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
pass=0; fail=0
ok()  { pass=$((pass+1)); printf '  ok   %s\n' "$1"; }
bad() { fail=$((fail+1)); printf '  FAIL %s\n     %s\n' "$1" "${2:-}"; }
is()  { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "wanted '$3', got '$2'"; fi; }
FX="$(mktemp -d)"; trap 'rm -rf "$FX"' EXIT
ask() { # <estate-file> <function> -> stdout
  env -i PATH="$PATH" HOME="$FX" STEWARD_ESTATE="$1" bash -c 'source "$0"/lib/registry.sh; '"$2" "$here" 2>&1
}
rc_of() { env -i PATH="$PATH" HOME="$FX" STEWARD_ESTATE="$1" bash -c 'source "$0"/lib/registry.sh; '"$2" "$here" >/dev/null 2>&1; echo $?; }

printf 'HUB_SESSION="hub-one"\nMAIL_ACCOUNT_FILE="alerts.env"\nALERT_TO="human@example.invalid"\n' > "$FX/ok.conf"
printf 'HUB_SESSION="hub-one"\n' > "$FX/bare.conf"
printf 'MAIL_ACCOUNT_FILE="../../etc/passwd"\nALERT_TO="not an address"\n' > "$FX/bad.conf"

echo "1. both keys read from the estate"
is "the account file name" "$(ask "$FX/ok.conf" registry_mail_account_file)" "alerts.env"
is "the alert recipient"   "$(ask "$FX/ok.conf" registry_alert_to)" "human@example.invalid"

echo "2. absent is a refusal, never a default"
is "no MAIL_ACCOUNT_FILE: rc 78" "$(rc_of "$FX/bare.conf" registry_mail_account_file)" "78"
is "no ALERT_TO: rc 78"          "$(rc_of "$FX/bare.conf" registry_alert_to)" "78"

echo "3. the form: a file NAME, never a path; an address, not free text"
is "a climbing file name is refused, rc 78" "$(rc_of "$FX/bad.conf" registry_mail_account_file)" "78"
is "a non-address is refused, rc 78"        "$(rc_of "$FX/bad.conf" registry_alert_to)" "78"
case "$(ask "$FX/bad.conf" registry_mail_account_file)" in *"expected the form"*) ok "the refusal names the form" ;; *) bad "the refusal names the form" ;; esac

echo "4. the two probe hooks: optional, a command line beginning with a path"
printf 'JOB_STATUS_CMD="/opt/probe/jobs --json"\nHOST_STATUS_CMD="relative/cmd"\n' > "$FX/hooks.conf"
is "JOB_STATUS_CMD read"                       "$(ask "$FX/hooks.conf" registry_job_status_cmd)" "/opt/probe/jobs --json"
is "a relative HOST_STATUS_CMD is refused, rc 78" "$(rc_of "$FX/hooks.conf" registry_host_status_cmd)" "78"
is "absent hook: rc 78 for the reader (the bridge turns it into unset)" "$(rc_of "$FX/bare.conf" registry_job_status_cmd)" "78"

echo
printf '%s: %d passed, %d failed\n' "$(basename "$0")" "$pass" "$fail"
[ "$fail" -eq 0 ]
