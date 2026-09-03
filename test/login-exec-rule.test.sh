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

echo "== 1b. an absent login STILL scrubs the two auth overrides =="
# THE SCRUB IS NO LONGER CONDITIONAL. It used to sit behind the same `if` as
# the config directory, so an absent LOGIN produced an EMPTY prefix and the
# consumer kept whatever auth override its environment carried. An API key
# WINS over subscription auth, so such a session ran on API billing while
# every view showed the subscription. The DIRECTORY stays conditional -- see
# the control group on the second assertion below.
out="$( registry_login_exec_prefix "" alice )"; rc=$?
is "empty slug gives rc 0" "$rc" "0"
is "empty slug gives the scrub, without a config dir" "$out" \
   "/usr/bin/env -u ANTHROPIC_API_KEY -u ANTHROPIC_AUTH_TOKEN"
# EXECUTED, NOT ONLY COMPARED -- and the control group runs in the OTHER
# direction: the ambient DIRECTORY must still survive. Were it unset here,
# every LOGIN-less session would have changed account silently, which is the
# opposite error of the same class.
seen="$( $out /bin/sh -c 'printf "%s|%s|%s" "${CLAUDE_CONFIG_DIR-UNSET}" "${ANTHROPIC_API_KEY-UNSET}" "${ANTHROPIC_AUTH_TOKEN-UNSET}"' )"
is "the ambient DIRECTORY survives (that is the transition) but no key does" "$seen" \
   "$FX/home/.claude-logins/wrong|UNSET|UNSET"

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

echo "== 2b. the caller's IFS never decides whether keys are scrubbed =="
# Finding 1: `for k in $_REGISTRY_LOGIN_SCRUB` splits on IFS. A caller with a
# non-default IFS around either form must not silently collapse the scrub
# list into one word.
out="$( IFS=:; registry_login_exec_prefix named alice )"
has "under IFS=: the prefix still carries both -u flags" "$out" \
   "-u ANTHROPIC_API_KEY -u ANTHROPIC_AUTH_TOKEN -u CLAUDE_CONFIG_DIR"

( IFS=:
  export CLAUDE_CONFIG_DIR="$FX/home/.claude-logins/wrong"
  export ANTHROPIC_API_KEY="sk-should-never-survive"
  export ANTHROPIC_AUTH_TOKEN="tok-should-never-survive"
  registry_login_apply named alice
  printf '%s|%s' "${ANTHROPIC_API_KEY-UNSET}" "${ANTHROPIC_AUTH_TOKEN-UNSET}" ) > "$FX/ifs-applied"
is "under IFS=: apply still unsets both keys" "$(cat "$FX/ifs-applied")" "UNSET|UNSET"

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

echo "== 7b. apply refuses the same space-in-home input as the prefix =="
# Finding 3: the shell-metacharacter guard used to live in the prefix form
# only, so the two forms accepted different inputs. There is now one shared
# resolver, so apply must refuse the same fixture the prefix refuses above.
( export CLAUDE_CONFIG_DIR="$FX/home/.claude-logins/wrong"
  export STEWARD_HOME_LOOKUP_CMD="$FX/homelookup-odd"
  registry_login_apply named alice
  printf '%s|%s' "$?" "$CLAUDE_CONFIG_DIR" ) > "$FX/applied-odd"
is "apply refuses a home with a space, rc 78, directory untouched" "$(cat "$FX/applied-odd")" \
   "78|$FX/home/.claude-logins/wrong"

echo "== 8. registry_login_apply — the same rule, as real environment =="
( export CLAUDE_CONFIG_DIR="$FX/home/.claude-logins/wrong"
  export ANTHROPIC_API_KEY="sk-should-never-survive"
  export ANTHROPIC_AUTH_TOKEN="tok-should-never-survive"
  registry_login_apply named alice
  printf '%s|%s|%s|%s' "$CLAUDE_CONFIG_DIR" "${ANTHROPIC_API_KEY-UNSET}" "${ANTHROPIC_AUTH_TOKEN-UNSET}" "$?" ) > "$FX/applied"
is "apply sets the resolved dir and unsets both keys" "$(cat "$FX/applied")" \
   "$FX/home/.claude-logins/acme|UNSET|UNSET|0"

echo "== 8b. apply with an EMPTY slug scrubs but leaves the directory =="
( export CLAUDE_CONFIG_DIR="$FX/home/.claude-logins/wrong"
  export ANTHROPIC_API_KEY="sk-should-never-survive"
  registry_login_apply "" alice
  printf '%s|%s' "$CLAUDE_CONFIG_DIR" "${ANTHROPIC_API_KEY-UNSET}" ) > "$FX/applied2"
is "empty slug: key gone, directory kept" "$(cat "$FX/applied2")" \
   "$FX/home/.claude-logins/wrong|UNSET"

echo "== 9. apply resolves FIRST: on rc 78 the environment is untouched =="
# Finding 4: apply used to unset CLAUDE_CONFIG_DIR before validating the
# slug, so a caller that drops the rc ran against the runtime's unnamed
# default (the LEGACY login's own directory). Resolve now happens before any
# mutation, so a refusal must leave CLAUDE_CONFIG_DIR and both keys exactly
# as the caller had them.
( export CLAUDE_CONFIG_DIR="$FX/home/.claude-logins/wrong"
  export ANTHROPIC_API_KEY="sk-should-never-survive"
  export ANTHROPIC_AUTH_TOKEN="tok-should-never-survive"
  registry_login_apply nosuch alice
  printf '%s|%s|%s|%s' "$?" "$CLAUDE_CONFIG_DIR" "${ANTHROPIC_API_KEY-UNSET}" "${ANTHROPIC_AUTH_TOKEN-UNSET}" ) > "$FX/applied-fail"
is "apply on an unknown slug leaves the ambient environment untouched" "$(cat "$FX/applied-fail")" \
   "78|$FX/home/.claude-logins/wrong|sk-should-never-survive|tok-should-never-survive"

echo "pass=$pass fail=$fail"
[ "$fail" -eq 0 ]
