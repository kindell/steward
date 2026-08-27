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

  if [ -e "$dir/estate/steward.conf" ]; then
    echo "scaffold: an estate already exists at $dir/estate/steward.conf — refusing to overwrite" >&2
    return 65
  fi
  mkdir -p "$dir"/{estate,sessions.d,entities.d,projects.d,jobs.d,services.d,browsers.d,hosts.d} 2>/dev/null \
    || { echo "scaffold: could not create $dir" >&2; return 70; }

  # SIXTEEN FIELDS. The 14 the installer already wrote, plus ESTATE_NAME and
  # SCHEMA_VERSION — without which registry_estate_name refuses (measured
  # 2026-08-27: today's installer produces an unreadable estate).
  {
    printf 'ESTATE_NAME="%s"\n'          "$org"
    printf 'SCHEMA_VERSION="3"\n'
    printf 'LABEL_PREFIX="com.%s.claude"\n'      "$org"
    printf 'RC_LABEL_PREFIX="%s: "\n'            "$org"
    printf 'HUB_SESSION="%s-hub"\n'              "$org"
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

  # The team and session are written in Task 2; this task establishes a loadable
  # estate skeleton. The variables team/owner/session/assets are already parsed.
  return 0
}
