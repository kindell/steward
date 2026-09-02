#!/bin/bash
# test/login-exec-rule.test.sh — THE ONE execution rule every launch branch
# uses, and the reason it is one and not four.
#
# THE FIXTURE CARRIES BOTH POISONS. Every case below runs with an ambient
# CLAUDE_CONFIG_DIR aimed at the WRONG account and an ambient ANTHROPIC_API_KEY.
# Either one alone turns a green line into the wrong account paying: the
# directory decides where credentials are read, and a key WINS over
# subscription auth regardless of directory. A suite that sets neither would
# certify a rule that scopes nothing.
set -u
here="$(CDPATH= cd -- "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
. "$here/lib/registry.sh"
pass=0; fail=0
ok()  { pass=$((pass+1)); printf '  ok   %s\n' "$1"; }
bad() { fail=$((fail+1)); printf '  FAIL %s\n     %s\n' "$1" "${2:-}"; }
is()  { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "wanted '$3', got '$2'"; fi; }
has() { case "$2" in *"$3"*) ok "$1" ;; *) bad "$1" "missing '$3' in: $2" ;; esac; }

FX="$(mktemp -d)"; trap 'rm -rf "$FX"' EXIT
mkdir -p "$FX/logins.d" "$FX/estate/estate" "$FX/home"
export STEWARD_LOGINS_DIR="$FX/logins.d"
export STEWARD_ESTATE_ROOT="$FX/estate"
printf 'LABEL_PREFIX="com.example.claude"\nLEGACY_LOGIN="acme-old"\n' \
  > "$FX/estate/estate/steward.conf"
cat > "$FX/homelookup" <<STUB
#!/bin/bash
[ "\$1" = "alice" ] && printf '%s\n' "$FX/home"
STUB
chmod +x "$FX/homelookup"
export STEWARD_HOME_LOOKUP_CMD="$FX/homelookup"

# THE AMBIENT POISON.
export CLAUDE_CONFIG_DIR="$FX/home/.claude-logins/wrong"
export ANTHROPIC_API_KEY="sk-should-never-survive"
export ANTHROPIC_AUTH_TOKEN="tok-should-never-survive"

row() { printf '%s\n' "$@" > "$FX/logins.d/$1.conf"; chmod 600 "$FX/logins.d/$1.conf"; }
mkrow() { # <slug> <provider> <configdir>
  printf 'PRINCIPAL="alice"\nACCOUNT="acct-acme-team"\nPROVIDER="%s"\nCONFIG_DIR="%s"\nLEGAL_OWNER="Acme"\n' \
    "$2" "$3" > "$FX/logins.d/$1.conf"
  chmod 600 "$FX/logins.d/$1.conf"
}

echo "== 1. an absent login yields an EMPTY prefix, rc 0 =="
out="$( registry_login_exec_prefix "" alice )"; rc=$?
is "empty slug gives rc 0" "$rc" "0"
is "empty slug gives an empty prefix" "$out" ""

echo "== 2. a resolved login gives the whole rule, in order =="
mkrow named claude-team "~/.claude-logins/acme"
out="$( registry_login_exec_prefix named alice )"
is "the prefix is exactly the rule, in the rule's order" "$out" \
   "/usr/bin/env -u ANTHROPIC_API_KEY -u ANTHROPIC_AUTH_TOKEN -u CLAUDE_CONFIG_DIR CLAUDE_CONFIG_DIR=$FX/home/.claude-logins/acme"

# THE PREFIX IS EXECUTED, NOT ONLY COMPARED. env stops parsing options at the
# first assignment, so a `-u` written after it is not a harmless no-op but an
# outright failure — and a suite that only string-matched would have shipped a
# prefix that refuses to run.
#
# /usr/bin/true, NOT /bin/true: this estate's own hosts do not all carry
# /bin/true (measured on a recent macOS release — /bin/true is simply
# absent there), while /usr/bin/true is present on every host this suite
# has run on, macOS and Linux alike.
$out /usr/bin/true 2>/dev/null
is "the prefix actually executes" "$?" "0"

echo "== 3. the ambient values never survive the rule =="
# Run a real command THROUGH the prefix and read what it saw. This is the
# measurement that matters: the string above is only a claim about it.
prefix="$( registry_login_exec_prefix named alice )"
seen="$( $prefix /bin/sh -c 'printf "%s|%s|%s" "${CLAUDE_CONFIG_DIR-UNSET}" "${ANTHROPIC_API_KEY-UNSET}" "${ANTHROPIC_AUTH_TOKEN-UNSET}"' )"
is "the child sees the resolved dir and no keys" "$seen" \
   "$FX/home/.claude-logins/acme|UNSET|UNSET"

echo "== 4. the transition legacy row resolves too =="
mkrow acme-old claude-max "~/.claude"
out="$( registry_login_exec_prefix acme-old alice )"
has "the legacy row resolves to the unnamed default" "$out" "CLAUDE_CONFIG_DIR=$FX/home/.claude"

echo "== 5. a provider with no recipe REFUSES, never silently does nothing =="
mkrow oc opencode-chatgpt "~/.claude-logins/oc"
( registry_login_exec_prefix oc alice >/dev/null 2>&1 ); is "opencode-chatgpt is rc 78" "$?" "78"
err="$( registry_login_exec_prefix oc alice 2>&1 >/dev/null )"
has "the refusal says the recipe is missing" "$err" "no isolation recipe"
mkrow cx codex-openai "~/.claude-logins/cx"
( registry_login_exec_prefix cx alice >/dev/null 2>&1 ); is "codex-openai is rc 78" "$?" "78"

echo "== 6. an unknown login REFUSES; it never falls through to empty =="
( registry_login_exec_prefix nosuch alice >/dev/null 2>&1 ); is "an unknown slug is rc 78" "$?" "78"
out="$( registry_login_exec_prefix nosuch alice 2>/dev/null )"
is "an unknown slug prints nothing at all" "$out" ""

echo "== 7. a resolved path that could be reinterpreted by a shell REFUSES =="
mkdir -p "$FX/odd home"
cat > "$FX/homelookup-odd" <<STUB
#!/bin/bash
[ "\$1" = "alice" ] && printf '%s\n' "$FX/odd home"
STUB
chmod +x "$FX/homelookup-odd"
( STEWARD_HOME_LOOKUP_CMD="$FX/homelookup-odd" registry_login_exec_prefix named alice >/dev/null 2>&1 )
is "a home with a space refuses" "$?" "78"

echo "== 8. registry_login_apply — the same rule, as real environment =="
( export CLAUDE_CONFIG_DIR="$FX/home/.claude-logins/wrong"
  export ANTHROPIC_API_KEY="sk-should-never-survive"
  registry_login_apply named alice
  printf '%s|%s|%s' "$CLAUDE_CONFIG_DIR" "${ANTHROPIC_API_KEY-UNSET}" "$?" ) > "$FX/applied"
is "apply sets the resolved dir and unsets the key" "$(cat "$FX/applied")" \
   "$FX/home/.claude-logins/acme|UNSET|0"

echo "== 8b. apply with an EMPTY slug scrubs but leaves the directory =="
( export CLAUDE_CONFIG_DIR="$FX/home/.claude-logins/wrong"
  export ANTHROPIC_API_KEY="sk-should-never-survive"
  registry_login_apply "" alice
  printf '%s|%s' "$CLAUDE_CONFIG_DIR" "${ANTHROPIC_API_KEY-UNSET}" ) > "$FX/applied2"
is "empty slug: key gone, directory kept" "$(cat "$FX/applied2")" \
   "$FX/home/.claude-logins/wrong|UNSET"

echo "pass=$pass fail=$fail"
[ "$fail" -eq 0 ]
