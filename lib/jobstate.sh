#!/bin/bash
# lib/jobstate.sh — the job state store: canonical, machine-owned, never sourced.
#
# JOBS ARE RUNTIME STATE, NOT REGISTRY ENTRIES. A registry row is declared in
# advance, committed and deployed through a gate; a job is born mid-conversation
# and must never travel that cycle. So its row lives under the state home, in
# the registry's conf idiom (KEY="value") but read by a PARSER — these rows are
# written by machinery under inherited environments, and sourcing writable
# input hands that environment a shell. The proof lives in the test suite.
#
# THE KEY IS THE ID: j-<16hex>, opaque, immutable, stable across attempts.
# Branches, paths, thread keys and JSON joins all key on it; the slug is
# presentation and appears nowhere down here.

jobstate_home() {
  if [ -n "${STEWARD_JOB_STATE_HOME:-}" ]; then
    printf '%s\n' "$STEWARD_JOB_STATE_HOME"; return 0
  fi
  if ! command -v registry_state_dir_name >/dev/null 2>&1; then
    local _here; _here="$(CDPATH= cd -- "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    # shellcheck source=registry.sh
    . "$_here/registry.sh" || { echo "jobstate: could not load the registry" >&2; return 78; }
  fi
  local n; n="$(registry_state_dir_name)" || return 78
  printf '%s\n' "$HOME/.local/state/$n/jobs"
}

jobstate_mint_id() {
  printf 'j-%s\n' "$(od -An -N8 -tx1 /dev/urandom | tr -d ' \n')"
}

# jobstate_create <id> <KEY=value>... — refuses an existing id (65) and an
# invalid field (64). Values may not contain newlines: one line is one field,
# and a value that could smuggle a second line could smuggle a second FIELD.
jobstate_create() {
  local id="${1:-}"; shift || true
  case "$id" in j-????????????????) ;; *) echo "jobstate: bad id '$id'" >&2; return 64 ;; esac
  local home; home="$(jobstate_home)" || return $?
  [ -e "$home/$id/row" ] && { echo "jobstate: $id already exists" >&2; return 65; }
  local kv key val out=""
  for kv in "$@"; do
    key="${kv%%=*}"; val="${kv#*=}"
    case "$key" in
      *[!A-Z0-9_]*|"") echo "jobstate: invalid field name '$key'" >&2; return 64 ;;
    esac
    case "$val" in *$'\n'*) echo "jobstate: newline in value of $key" >&2; return 64 ;; esac
    out="${out}${key}=${val}"$'\n'
  done
  mkdir -p "$home/$id/outbox" || return 73
  printf '%s' "$out" > "$home/$id/row.tmp.$$" && mv "$home/$id/row.tmp.$$" "$home/$id/row"
  printf 'v0 created %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >> "$home/$id/journal"
}

# jobstate_read <id> — strict parse into JOB_<KEY> in the CALLER. rc 66 when
# the row is missing, 65 when any line fails the grammar: a row we cannot
# fully parse is a row we do not half-trust.
jobstate_read() {
  local id="${1:-}" home line key val
  home="$(jobstate_home)" || return $?
  [ -f "$home/$id/row" ] || { echo "jobstate: no such job $id" >&2; return 66; }
  # Clear previous read so a missing field reads as unset, never as leftovers.
  local v; for v in $(compgen -v JOB_ 2>/dev/null); do unset "$v"; done
  while IFS= read -r line || [ -n "$line" ]; do
    [ -z "$line" ] && continue
    case "$line" in
      [A-Z]*=*) key="${line%%=*}"; val="${line#*=}" ;;
      *) echo "jobstate: corrupt row line in $id: $line" >&2; return 65 ;;
    esac
    case "$key" in *[!A-Z0-9_]*) echo "jobstate: corrupt field name in $id" >&2; return 65 ;; esac
    printf -v "JOB_$key" '%s' "$val"
  done < "$home/$id/row"
}
