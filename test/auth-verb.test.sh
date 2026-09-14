#!/bin/bash
# test/auth-verb.test.sh — `steward auth`: the one verb a person uses to sign a
# Claude account in, and to see which ones are signed in already.
#
# WHY IT EXISTS, and it is an ergonomics measurement rather than a defect. To
# sign in to one account on one machine, an operator had to type:
#
#   STEWARD_ESTATE_ROOT=$HOME/Projects/<estate> \
#     ~/scripts/bin/steward registry login shell <login-slug> --account <account-slug>
#   claude auth login
#
# Six things to know for one act: an environment variable, a full path, the word
# `registry` (which is where logins are STORED, not what one is DOING), two slugs
# that must be looked up, and a second command run inside the first. Every one of
# them is a place to get it wrong, and getting it wrong means credentials land in
# the wrong directory — which is the incident this whole register exists to
# prevent. A tool that is unpleasant enough gets worked around, and the
# workaround is a bare `claude auth login` in whatever directory one happens to
# be standing in.
#
# THE VERB IS `auth` AND NOT `login` because `steward login [session]` already
# exists and means something else: it signs in a SESSION's runtime on the machine
# that session lives on. Two different acts under one word would be worse than a
# long command.
#
# NO NETWORK, NO REAL SIGN-IN. STEWARD_AUTH_CMD is the seam the sign-in runs
# through; every case below points it at a stub that records its argv and its
# environment.
set -u
here="$(CDPATH= cd -- "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
STEWARD="$here/bin/steward"
pass=0; fail=0
ok()  { pass=$((pass+1)); printf '  ok   %s\n' "$1"; }
bad() { fail=$((fail+1)); printf '  FAIL %s\n     %s\n' "$1" "${2:-}"; }
is()  { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "wanted '$3', got '$2'"; fi; }
has() { case "$2" in *"$3"*) ok "$1" ;; *) bad "$1" "missing '$3' in: $2" ;; esac; }
no()  { case "$2" in *"$3"*) bad "$1" "unexpectedly present: '$3' in: $2" ;; *) ok "$1" ;; esac; }

FX="$(mktemp -d)"; trap 'rm -rf "$FX"' EXIT
mkdir -p "$FX/estate" "$FX/logins.d" "$FX/accounts.d" "$FX/home/.claude-logins"
chmod 700 "$FX/logins.d"; chmod 755 "$FX/home/.claude-logins"
cat > "$FX/estate/steward.conf" <<'EOF'
ESTATE_NAME="fixture"
SCHEMA_VERSION="3"
LABEL_PREFIX="com.fixture.claude"
RC_LABEL_PREFIX="fixture: "
HUB_SESSION="fixture-hub"
HUB_HOST="h1"
HUB_SSH="a@h1"
JOB_LOG_DIR="fixture-jobs"
TMUX_SOCKET="fixture.sock"
PING_MSG="you have mail"
STATE_DIR_NAME="fixture-supervisor"
PAUSED_DIR_NAME="fixture-paused"
JOB_LABEL_PREFIX="com.fixture.job"
SERVICE_LABEL_PREFIX="com.fixture.service"
BROWSER_LABEL_PREFIX="com.fixture.browser"
OP_TOKEN_FILE_NAME="fixture-token"
EOF
ME="$(id -un)"
# THE PRODUCTION SHAPE: one human with two accounts on one host - their own home
# and the machine account a hub runs as - plus a second human whose login must
# never be openable from here.
printf 'PRINCIPAL="me"\nHOST="h1"\nUSERNAME="%s"\n' "$ME"      > "$FX/accounts.d/a-self.conf"
printf 'PRINCIPAL="me"\nHOST="h1"\nUSERNAME="machine"\n'       > "$FX/accounts.d/a-machine.conf"
printf 'PRINCIPAL="them"\nHOST="h1"\nUSERNAME="stranger"\n'    > "$FX/accounts.d/a-them.conf"
chmod 600 "$FX/accounts.d"/*.conf
cat > "$FX/homes" <<STUB
case "\$1" in
  $ME) printf '$FX/home\n' ;;
  machine) printf '/srv/homes/machine\n' ;;
  stranger) printf '/srv/homes/stranger\n' ;;
  *) exit 1 ;;
esac
STUB
chmod +x "$FX/homes"
# the sign-in seam: records argv and the one variable that decides where
# credentials land, then succeeds
cat > "$FX/authcmd" <<'STUB'
#!/bin/bash
{ printf 'argv:%s\n' "$*"; printf 'dir:%s\n' "${CLAUDE_CONFIG_DIR:-<unset>}"; } >> "$AUTHLOG"
exit "${AUTHRC:-0}"
STUB
chmod +x "$FX/authcmd"

run() {
  : > "$FX/authlog"
  OUT="$( STEWARD_ESTATE_ROOT="$FX" STEWARD_CONFIG_FILE="$FX/no-such-config" \
          STEWARD_SELF_HOST=h1 STEWARD_HOME_LOOKUP_CMD="$FX/homes" \
          STEWARD_AUTH_CMD="$FX/authcmd" AUTHLOG="$FX/authlog" AUTHRC="${AUTHRC:-0}" \
          bash "$STEWARD" auth "$@" 2>"$FX/err" )"; RC=$?
  ERR="$(cat "$FX/err")"; LOG="$(cat "$FX/authlog" 2>/dev/null)"
}
add() { STEWARD_ESTATE_ROOT="$FX" STEWARD_CONFIG_FILE="$FX/no-such-config" STEWARD_SELF_HOST=h1 \
        STEWARD_HOME_LOOKUP_CMD="$FX/homes" bash "$STEWARD" registry login add "$@" --json >/dev/null 2>&1; }
add mine   --principal me   --account me@example.test    --provider claude-team --config-dir '~/.claude-logins/mine'   --legal-owner 'Acme'
add work   --principal me   --account work@example.test  --provider claude-max  --config-dir '~/.claude-logins/work'   --legal-owner 'Widgets'
add theirs --principal them --account them@example.test  --provider claude-team --config-dir '~/.claude-logins/theirs' --legal-owner 'Acme'
mkdir -p "$FX/home/.claude-logins/mine"; chmod 700 "$FX/home/.claude-logins/mine"
printf '{}' > "$FX/home/.claude-logins/mine/.credentials.json"; chmod 600 "$FX/home/.claude-logins/mine/.credentials.json"

echo "== 1. with no argument it SHOWS, and never signs anything in =="
# A LISTING MUST NOT ACT. This is the command a person runs when they do not yet
# know what they want, and the one most likely to be typed by mistake.
run
is  "1a rc 0"                                    "$RC" "0"
has "1b names the login that is signed in"       "$OUT" "mine"
has "1c ...and says so in words"                 "$OUT" "signed in"
has "1d names the one that is not"               "$OUT" "work"
has "1e ...and says that in words too"           "$OUT" "no credential"
has "1f names who pays, per row"                 "$OUT" "Widgets"
is  "1g and nothing was signed in"               "$LOG" ""
# ANOTHER PERSON'S LOGIN IS LISTED, NOT HIDDEN, and named as theirs. Hiding it
# would make a register that holds it look like one that does not, and the
# operator would go looking for a row that is already there.
has "1h another person's login is shown"         "$OUT" "theirs"
has "1i ...as not this account's to open"        "$OUT" "not yours"

echo "== 2. one name, and the whole act =="
AUTHRC=0 run work
is  "2a rc 0"                                    "$RC" "0"
has "2b the sign-in ran"                         "$LOG" "argv:"
has "2c ...with the login's own directory"       "$LOG" "dir:$FX/home/.claude-logins/work"
has "2d the banner names who pays"               "$OUT" "Widgets"
# THE DIRECTORY IS CREATED, 0700, BY THIS PROCESS. A first sign-in has nowhere to
# put credentials otherwise, and a mode inherited from the operator's umask is
# the one thing the login register refuses to trust.
is  "2e the directory now exists"                "$([ -d "$FX/home/.claude-logins/work" ] && echo yes || echo no)" "yes"
is  "2f ...and is 0700 whatever the umask"       "$(stat -c '%a' "$FX/home/.claude-logins/work" 2>/dev/null || stat -f '%Lp' "$FX/home/.claude-logins/work")" "700"

echo "== 3. a name is a prefix, not a slug to look up =="
# THE SLUG IS THE REGISTER'S WORD, not the operator's. Requiring it exactly is
# what sent people to `registry login ls` first, every time.
: > "$FX/authlog"; AUTHRC=0 run wor
has "3a a unique prefix resolves"                "$LOG" "dir:$FX/home/.claude-logins/work"
: > "$FX/authlog"; run me
is  "3b an ambiguous name refuses"               "$([ "$RC" -ne 0 ] && echo yes || echo no)" "yes"
has "3c ...and lists what it could have meant"   "$ERR$OUT" "mine"
is  "3d ...and signs nothing in"                 "$LOG" ""
run nosuchlogin
is  "3e an unknown name refuses"                 "$([ "$RC" -ne 0 ] && echo yes || echo no)" "yes"
has "3f ...and shows what IS available"          "$ERR$OUT" "work"

echo "== 4. it refuses what it cannot do, by name =="
run theirs
is  "4a another person's login refuses rc 77"    "$RC" "77"
has "4b ...and names whose home it is"           "$ERR" "/srv/homes/stranger"
is  "4c ...and signs nothing in"                 "$LOG" ""
# ALREADY SIGNED IN IS NOT AN ERROR AND NOT A NO-OP TO HIDE. Re-authenticating is
# a real thing to want and a bad thing to do by accident: it can switch the
# account under every session already running on that directory.
run mine
is  "5a an already-signed-in login does nothing" "$LOG" ""
has "5b ...and says why"                         "$OUT" "already signed in"
has "5c ...and names the way to do it anyway"    "$OUT" "--reauth"
AUTHRC=0 run mine --reauth
has "5d --reauth signs in"                       "$LOG" "dir:$FX/home/.claude-logins/mine"

echo "== 6. a failed sign-in is reported as failed =="
# The seam's exit status is the verb's: a tool that said "signed in" because it
# had finished running would be worse than no tool.
AUTHRC=7 run work --reauth
is  "6a the sign-in's failure is the verb's"     "$([ "$RC" -ne 0 ] && echo yes || echo no)" "yes"
no  "6b ...and it never claims success"          "$OUT" "✓"

printf '\n%d passed, %d failed\n' "$pass" "$fail"; [ "$fail" -eq 0 ]
