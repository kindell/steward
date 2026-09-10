#!/bin/bash
# login-probe.sh <path-to-steward-checkout> - measures every intermediate value the
# login listing depends on, in the SAME fixture shape test section 10 builds.
# Run on both platforms; the first line that differs is the answer.
set -u
here="${1:?usage: login-probe.sh /path/to/steward}"
FX="$(mktemp -d)"; trap 'rm -rf "$FX"' EXIT
mkdir -p "$FX/estate" "$FX/logins.d" "$FX/accounts.d"
chmod 700 "$FX/logins.d"; chmod 755 "$FX/accounts.d"
printf 'LABEL_PREFIX="com.fixture.claude"\nHUB_HOST="h1"\nOP_TOKEN_FILE_NAME="t"\nLEGACY_LOGIN="legacy"\n' > "$FX/estate/steward.conf"
printf 'PRINCIPAL="alice"\nHOST="h1"\n' > "$FX/accounts.d/acct-acme-team.conf"; chmod 600 "$FX/accounts.d/acct-acme-team.conf"
printf 'PRINCIPAL="alice"\nACCOUNT="acct-acme-team"\nPROVIDER="claude-team"\nCONFIG_DIR="~/.claude-logins/row1"\nLEGAL_OWNER="Acme Corp"\n' > "$FX/logins.d/row1.conf"; chmod 600 "$FX/logins.d/row1.conf"
cat > "$FX/homelookup" <<'STUB'
case "$1" in alice) printf '/srv/homes/alice\n' ;; *) exit 1 ;; esac
STUB
chmod +x "$FX/homelookup"
echo "== platform =="
printf '  uname=%s  bash=%s  hostname -s=%s\n' "$(uname -s)" "$BASH_VERSION" "$(hostname -s 2>/dev/null || echo ERR)"
echo "== library, in the fixture's environment =="
STEWARD_ESTATE_ROOT="$FX" STEWARD_CONFIG_FILE="$FX/no-such-config" \
STEWARD_SELF_HOST=h1 STEWARD_HOME_LOOKUP_CMD="$FX/homelookup" \
bash -c '. "$1/lib/registry.sh"
  printf "  self_host=[%s]  (STEWARD_SELF_HOST=[%s])\n" "$(_registry_self_host)" "${STEWARD_SELF_HOST:-}"
  printf "  account_dir=[%s]\n" "$(registry_account_dir)"
  printf "  glob matches: "; for f in "$(registry_account_dir)"/*.conf; do printf "[%s] " "$f"; done; echo
  registry_account_load acct-acme-team >/dev/null 2>&1
  printf "  account_load rc=%s principal=[%s] host=[%s] username=[%s]\n" "$?" "$ACCOUNT_PRINCIPAL" "$ACCOUNT_HOST" "$ACCOUNT_USERNAME"
  registry_login_load row1 >/dev/null 2>&1
  printf "  login_load   rc=%s principal=[%s] account=[%s] cfgdir_raw=[%s]\n" "$?" "$LOGIN_PRINCIPAL" "$LOGIN_ACCOUNT" "$LOGIN_CONFIG_DIR_RAW"
  u="$(registry_login_unix_account row1)"; printf "  unix_account rc=%s -> [%s]\n" "$?" "$u"
  printf "  config_dir   -> [%s]\n" "$(registry_login_config_dir row1 "${u:-alice}" 2>&1)"
  printf "  login_state  -> [%s]\n" "$(registry_login_state row1 | tr "\t" " ")"' _ "$here"
echo "== the verb itself, same environment =="
STEWARD_ESTATE_ROOT="$FX" STEWARD_CONFIG_FILE="$FX/no-such-config" \
STEWARD_SELF_HOST=h1 STEWARD_HOME_LOOKUP_CMD="$FX/homelookup" \
bash "$here/bin/steward" registry login ls 2>&1 | sed 's/^/  /'
echo "== and what the verb sees of its own environment =="
STEWARD_ESTATE_ROOT="$FX" STEWARD_CONFIG_FILE="$FX/no-such-config" \
STEWARD_SELF_HOST=h1 STEWARD_HOME_LOOKUP_CMD="$FX/homelookup" \
bash "$here/bin/steward" registry login shell row1 -- sh -c 'printf "  in-verb: SELF_HOST=[%s] ESTATE_ROOT=[%s] CLAUDE_CONFIG_DIR=[%s]\n" "${STEWARD_SELF_HOST:-}" "${STEWARD_ESTATE_ROOT:-}" "${CLAUDE_CONFIG_DIR:-}"' 2>&1 | sed 's/^/  /'
