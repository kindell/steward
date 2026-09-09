#!/bin/bash
# lib/scaffold.sh — estate_scaffold: write a fresh estate, first team and first
# session into a target directory, with NO machine side effects. Pure enough for
# the suite to drive against a temp dir; the installer and (later) the Rust TUI
# call it for real. Presentation-free: return codes and JSON, never pretty-print.

# estate_scaffold <dir> org=<> team=<> owner=<> session=<> [assets=<>]
# rc 0 ok · 64 bad/missing arg · 65 estate already exists · 70 write failure
estate_scaffold() {
  local dir="${1:-}"; shift 2>/dev/null || true
  [ -n "$dir" ] || { echo "scaffold: target directory required" >&2; return 64; }
  local org="" team="" owner="" session="" assets=""
  local kv
  for kv in "$@"; do
    case "$kv" in
      org=*)     org="${kv#org=}" ;;
      team=*)    team="${kv#team=}" ;;
      owner=*)   owner="${kv#owner=}" ;;
      session=*) session="${kv#session=}" ;;
      assets=*)  assets="${kv#assets=}" ;;
      *) echo "scaffold: unknown argument '$kv'" >&2; return 64 ;;
    esac
  done
  # THE NAMES ARE VALIDATED, NOT GUESSED. Each must match the form its register
  # requires, so a typo refuses here rather than at first load.
  # Must start with a-z (not digit or dash) and contain only a-z0-9-.
  case "$org" in [a-z]*) ;; *) echo "scaffold: org must start with a-z ('$org')" >&2; return 64 ;; esac
  case "$org" in *[!a-z0-9-]*) echo "scaffold: org must be lower-case a-z0-9- ('$org')" >&2; return 64 ;; esac
  case "$team" in [a-z]*) ;; *) echo "scaffold: team must start with a-z ('$team')" >&2; return 64 ;; esac
  case "$team" in *[!a-z0-9-]*) echo "scaffold: team must be lower-case a-z0-9- ('$team')" >&2; return 64 ;; esac
  case "$owner" in [a-z]*) ;; *) echo "scaffold: owner must start with a-z ('$owner')" >&2; return 64 ;; esac
  case "$owner" in *[!a-z0-9-]*) echo "scaffold: owner must be lower-case a-z0-9- ('$owner')" >&2; return 64 ;; esac
  case "$session" in [a-z]*) ;; *) echo "scaffold: session must start with a-z ('$session')" >&2; return 64 ;; esac
  case "$session" in *[!a-z0-9-]*) echo "scaffold: session must be lower-case a-z0-9- ('$session')" >&2; return 64 ;; esac
  # ASSETS IS WRITTEN INTO A CONF THAT registry_load LATER SOURCES. Unlike the
  # four name fields above, it is not a bare token — it is a space-separated
  # list of "<type>" or "<type>:<arg>" entries — but it still lands unescaped
  # inside double quotes in a shell-sourced file, so a stray `"` in the value
  # closes the string early and anything after it (`;`, backticks, `$(...)`)
  # runs as shell when the conf is sourced. Restrict it to a safe character
  # set up front rather than trying to escape it on the way out.
  case "$assets" in
    *[!A-Za-z0-9:._@\ -]*) echo "scaffold: assets must contain only [A-Za-z0-9:._@-] and spaces ('''$assets''')" >&2; return 64 ;;
  esac

  if [ -e "$dir/estate/steward.conf" ]; then
    echo "scaffold: an estate already exists at $dir/estate/steward.conf — refusing to overwrite" >&2
    return 65
  fi
  # mcp.d IS IN THE LIST FOR THE SAME REASON entities.d IS. Every register here
  # draws the distinction between EMPTY and UNREADABLE — registry_mcp_list
  # refuses with 78 on a missing directory rather than printing nothing — so an
  # estate scaffolded without it answers "the capability register cannot be
  # read" the first time anything asks what a session is granted, which is not
  # what a fresh estate means.
  #
  # accounts.d AND logins.d ARE THE SAME GAP, measured in the writer census: a
  # scaffolded estate could not resolve a single session's principal
  # (registry_account_load) or answer the empty-vs-unreadable question for its
  # own login register (registry_login_list, rc 78 on a missing directory) —
  # from birth, the same failure shape hosts.d had before it was added here.
  #
  # invites.d IS THE THIRD, and it is the one that stopped onboarding dead. An
  # invitation is the ONLY door into this estate, and registry_row_write refuses
  # a register that does not exist — so `steward invite issue` on a freshly
  # scaffolded estate answered "the invite register is not readable", rc 78, and
  # the first step of onboarding could not be taken at all.
  #
  # EVERY MODE HERE IS PINNED, NEVER LEFT TO THE AMBIENT umask. Measured on a
  # Debian/Ubuntu host, whose default umask is 002 (user-private groups): every
  # register came out 0775, and the invite and login loaders REFUSE a group- or
  # other-writable register on purpose — a row at mode 600 inside a directory
  # anybody can write to is not protected by its mode, because anybody can
  # rename it away and drop their own file under the same name. So `invite
  # issue` wrote its row, its own canonical readback refused the register it had
  # just written into, and the writer deleted the row and returned 70. The
  # product's own onboarding path, broken by the host's umask, on the platform
  # this product is for. A mode that depends on the host is not a decision.
  #
  # `mkdir -m`, NOT `mkdir` FOLLOWED BY `chmod`, and for two reasons. There is
  # no window in which the directory exists at the looser mode (browser-stack.sh
  # documents the same choice for the same reason), and `-m` is applied ONLY
  # when this call is the one creating the directory — an estate directory
  # somebody already tightened or loosened by hand is left exactly as it is,
  # the rule bin/steward's config init already follows. A register that IS
  # loose is not silently repaired here; it is refused by the loader, which now
  # names the remedy.
  #
  # THE ESTATE ROOT IS CREATED FIRST, on its own. `mkdir -m MODE -p a/b` applies
  # MODE to `b` only; every parent it has to create along the way gets the
  # ambient umask, so a one-shot call would have pinned the registers and left
  # the directory holding them group-writable — and renaming a register is as
  # good as writing to it.
  mkdir -m 0755 -p "$dir" 2>/dev/null \
    || { echo "scaffold: could not create $dir" >&2; return 70; }
  local _sc_reg _sc_mode
  for _sc_reg in estate sessions.d entities.d projects.d mcp.d jobs.d \
                 services.d browsers.d hosts.d accounts.d logins.d invites.d; do
    # 0700 FOR THE TWO REGISTERS WHOSE LOADERS CHECK. logins.d and invites.d
    # carry security artifacts — which account pays, and the digest of a
    # one-time link token — and their readers refuse a loose directory. Pinning
    # them at 0700 means the check they make is a check the product itself can
    # always pass.
    case "$_sc_reg" in
      logins.d|invites.d) _sc_mode=0700 ;;
      *)                  _sc_mode=0755 ;;
    esac
    mkdir -m "$_sc_mode" -p "$dir/$_sc_reg" 2>/dev/null \
      || { echo "scaffold: could not create $dir/$_sc_reg" >&2; return 70; }
  done

  # FIFTEEN FIELDS. The 13 the installer already wrote, plus ESTATE_NAME and
  # SCHEMA_VERSION — without which registry_estate_name refuses (measured
  # 2026-08-27: today's installer produces an unreadable estate). No
  # RC_LABEL_PREFIX: labels are Team or Team->Project, and a row without a
  # target falls back to its bare name (2026-09-06).
  {
    printf 'ESTATE_NAME="%s"\n'          "$org"
    printf 'SCHEMA_VERSION="3"\n'
    printf 'LABEL_PREFIX="com.%s.claude"\n'      "$org"
    # ONE HUB PER MACHINE, NAMED AFTER THE MACHINE. The hub session's slug is
    # the hostname -- the same value as HUB_HOST -- never "<org>-hub": the
    # first session is the house, and its label follows the Team form like
    # every other session (rule of 2026-08-29, restated 2026-09-05).
    printf 'HUB_SESSION="%s"\n'                  "$(hostname -s)"
    printf 'HUB_HOST="%s"\n'                     "$(hostname -s)"
    printf 'HUB_SSH="%s@%s"\n'                   "$(id -un)" "$(hostname -s)"
    printf 'JOB_LOG_DIR="%s-jobs"\n'             "$org"
    printf 'TMUX_SOCKET="%s.sock"\n'             "$org"
    printf 'PING_MSG="[bus] you have mail — read your inbox"\n'
    printf 'STATE_DIR_NAME="%s-supervisor"\n'    "$org"
    printf 'PAUSED_DIR_NAME="%s-paused"\n'       "$org"
    printf 'JOB_LABEL_PREFIX="com.%s.job"\n'     "$org"
    printf 'SERVICE_LABEL_PREFIX="com.%s.service"\n' "$org"
    printf 'BROWSER_LABEL_PREFIX="com.%s.browser"\n' "$org"
    printf 'OP_TOKEN_FILE_NAME="%s-service-account"\n' "$org"
  } > "$dir/estate/steward.conf" || { echo "scaffold: could not write estate file" >&2; return 70; }
  chmod 600 "$dir/estate/steward.conf" || { echo "scaffold: could not set mode" >&2; return 70; }

  # THE FIRST TEAM. An entity with the owner as its sole member. This is what
  # makes the session belong to a team rather than to a bare domain.
  {
    printf '# %s — team, written by estate_scaffold.\n' "$team"
    printf 'NAME="%s"\n' "$team"
    printf 'MEMBERS="%s"\n' "$owner"
  } > "$dir/entities.d/$team.conf" || { echo "scaffold: could not write team" >&2; return 70; }

  # THE FIRST SESSION. It belongs to the team via DOMAIN=<team>; ID is the
  # immutable key (equal to the session name here). ASSETS is the declaration
  # subsystem B will read.
  {
    printf '# %s — first session, written by estate_scaffold.\n' "$session"
    printf 'HOST="%s"\n' "$(hostname -s)"
    printf 'REPO_PATH="%s"\n' "$dir"
    printf 'RC_LABEL="%s: %s"\n' "$org" "$session"
    printf 'PERMISSION_MODE="bypassPermissions"\n'
    printf 'OWNER="%s"\n' "$owner"
    printf 'DOMAIN="%s"\n' "$team"
    printf 'ID="%s"\n' "$session"
    printf 'ASSETS="%s"\n' "$assets"
  } > "$dir/sessions.d/$session.conf" || { echo "scaffold: could not write session" >&2; return 70; }
  chmod 600 "$dir/sessions.d/$session.conf" "$dir/entities.d/$team.conf" 2>/dev/null

  return 0
}
