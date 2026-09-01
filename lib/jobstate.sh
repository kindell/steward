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
  local kv key val out="VERSION=0"$'\n'
  for kv in "$@"; do
    key="${kv%%=*}"; val="${kv#*=}"
    case "$key" in
      *[!A-Z0-9_]*|""|VERSION) echo "jobstate: invalid field name '$key'" >&2; return 64 ;;
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

_jobstate_now() { printf '%s\n' "${JOBSTATE_NOW:-$(date +%s)}"; }

# jobstate_transition <id> <expected-version> <KEY=value>... — the ONLY write
# path after create. Compare-and-swap on VERSION: the caller states the version
# it read, and a row that has moved refuses with rc 75. The journal line is
# written in the same breath as the row swap; a refused transition writes
# nothing anywhere.
jobstate_transition() {
  local id="${1:-}" expect="${2:-}"; shift 2 || return 64
  local home; home="$(jobstate_home)" || return $?
  local lock="$home/$id/write-lock"
  mkdir "$lock" 2>/dev/null || { echo "jobstate: concurrent write on $id" >&2; return 75; }
  # The lock is released on EVERY exit path below.
  local rc=0
  _jobstate_transition_locked "$id" "$expect" "$@" || rc=$?
  rmdir "$lock" 2>/dev/null
  return "$rc"
}

_jobstate_transition_locked() {
  local id="$1" expect="$2"; shift 2
  jobstate_read "$id" || return $?
  [ "${JOB_VERSION:-}" = "$expect" ] || { echo "jobstate: version is ${JOB_VERSION:-unset}, caller expected $expect" >&2; return 75; }
  local kv key val
  for kv in "$@"; do
    key="${kv%%=*}"; val="${kv#*=}"
    case "$key" in *[!A-Z0-9_]*|""|VERSION) echo "jobstate: invalid field '$key'" >&2; return 64 ;; esac
    case "$val" in *$'\n'*) echo "jobstate: newline in value of $key" >&2; return 64 ;; esac
    printf -v "JOB_$key" '%s' "$val"
  done
  local new=$((expect + 1))
  local out="VERSION=$new"$'\n' v name
  for v in $(compgen -v JOB_); do
    name="${v#JOB_}"; [ "$name" = "VERSION" ] && continue
    out="${out}${name}=${!v}"$'\n'
  done
  local home; home="$(jobstate_home)"
  printf '%s' "$out" > "$home/$id/row.tmp.$$" && mv "$home/$id/row.tmp.$$" "$home/$id/row" || return 73
  printf 'v%d %s %s\n' "$new" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*" >> "$home/$id/journal"
}

# Leases bind a PROCESS to a job for a bounded time. A lease without a living
# owner is by definition free [R 3.3]; expiry is the clock, liveness pinning
# comes later in the runner. Format: "<owner> <expires-at-epoch>".
jobstate_lease_acquire() {
  local id="$1" owner="$2" ttl="$3" home f now holder until
  home="$(jobstate_home)" || return $?; f="$home/$id/lease"; now="$(_jobstate_now)"
  if [ -f "$f" ]; then
    read -r holder until < "$f"
    if [ "$now" -lt "$until" ] && [ "$holder" != "$owner" ]; then
      echo "jobstate: lease held by $holder until $until" >&2; return 75
    fi
  fi
  printf '%s %s\n' "$owner" "$((now + ttl))" > "$f.tmp.$$" && mv "$f.tmp.$$" "$f"
}

jobstate_lease_renew() {
  local id="$1" owner="$2" home f holder until now
  home="$(jobstate_home)" || return $?; f="$home/$id/lease"; now="$(_jobstate_now)"
  [ -f "$f" ] || { echo "jobstate: no lease to renew" >&2; return 75; }
  read -r holder until < "$f"
  [ "$holder" = "$owner" ] && [ "$now" -lt "$until" ] || { echo "jobstate: lease not held by $owner" >&2; return 75; }
  local ttl=$((until - now < 60 ? 60 : until - now))
  printf '%s %s\n' "$owner" "$((now + ttl))" > "$f.tmp.$$" && mv "$f.tmp.$$" "$f"
}

jobstate_lease_holder() {
  local id="$1" home f holder until
  home="$(jobstate_home)" || return $?; f="$home/$id/lease"
  [ -f "$f" ] || return 1
  read -r holder until < "$f"
  [ "$(_jobstate_now)" -lt "$until" ] || return 1
  printf '%s\n' "$holder"
}
