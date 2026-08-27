#!/bin/bash
# lib/assets.sh — a session's assets, in two layers.
#
# DECLARED (this file's first half) is the registry's truth: what the session
# SHOULD reach, straight out of the conf. Hermetic, always testable.
#
# PROBED (second half, added in the next task) is health: whether each declared
# asset answers right now. Declared is not working, and any view that merges the
# two lies in the direction of "fine".
#
# Presentation-free: data on stdout, diagnosis on stderr, meaning in the return
# code. Rendering belongs to the cockpit.

# session_assets <session> — one asset per line on stdout.
# rc 0 ok (including zero assets) · rc 1 the session could not be loaded.
session_assets() {
  local s="${1:-}"
  [ -n "$s" ] || { echo "assets: session name required" >&2; return 1; }
  # The registry library may already be sourced by the caller; source it only if
  # its loader is absent, so a caller's own estate settings are not disturbed.
  if ! command -v registry_load >/dev/null 2>&1; then
    local _here; _here="$(CDPATH= cd -- "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    # shellcheck source=registry.sh
    . "$_here/registry.sh" || { echo "assets: could not load the registry" >&2; return 1; }
  fi
  registry_load "$s" >/dev/null 2>&1 || {
    echo "assets: unknown or unreadable session '$s'" >&2; return 1; }
  # SNAPSHOT BEFORE PRINTING. registry_load sets ASSETS in the CALLER's shell,
  # and a later registry_load overwrites it. A caller that loops over this
  # function's output while probing would otherwise read a value that changed
  # underneath it. Copy first, then print from the copy.
  local _list="${ASSETS:-}"
  # ZERO ASSETS IS A VALID ANSWER. printf on an empty string would emit one blank
  # line, which a caller counts as an asset — so the empty case prints nothing.
  [ -n "$_list" ] || return 0
  printf '%s\n' $_list   # deliberately unquoted: the field is a space-separated list
  return 0
}

# ── PROBING: is a declared asset actually answering? ────────────────────────
#
# THE FOURTH STATUS IS THE IMPORTANT ONE. up / local-only / down are what a
# successful measurement can find; `unknown` is what an UNSUCCESSFUL one must
# say. A probe that cannot run — no command, an unrecognised type, a host that
# did not answer — reports `unknown`, never `up` and never nothing. The whole
# model exists so that "declared" and "working" cannot be confused; letting an
# unmeasurable asset render as healthy would rebuild that confusion one layer up.
#
# THE MEASUREMENT IS INJECTABLE. STEWARD_ASSET_PROBE_CMD names a command taking
# <type> <arg> and printing "<status> <detail>". Production sets it to the real
# prober; the suite sets it to a stub. Without the seam this layer could not be
# tested at all, and an untested probe is a probe that quietly stops working.
#
# THE MEASUREMENT HAS A DEADLINE. A prober that hangs (a stuck socket, a stub
# with a runaway sleep) must not hang asset_probe with it — a hung probe of ONE
# asset would block a caller that polls a whole fleet serially, and it would
# report neither "up" nor "unknown": it would report NOTHING, which is worse
# than either. STEWARD_ASSET_PROBE_TIMEOUT sets the deadline in seconds
# (default below); crossing it is itself a measurement that could not be made,
# so it reports `unknown` with a timeout detail, same as any other failure.
#
# GNU `timeout` IS NOT GUARANTEED. Stock macOS does not ship it, and this code
# runs on macOS — see _asset_probe_run_with_timeout below for the fallback.
#
# rc IS ALWAYS 0. Probing REPORTS; it does not judge. A caller that wants to act
# on health reads the status word — the return code says only "the probe ran".

# _asset_probe_run_with_timeout <seconds> <cmd> [args...] — runs the command
# with a time limit, printing its stdout. rc 124 means the limit was hit and
# the command was killed (matching GNU timeout's convention); any other rc is
# the command's own.
_asset_probe_run_with_timeout() {
  local secs="$1"; shift
  if command -v timeout >/dev/null 2>&1; then
    timeout "$secs" "$@"
    return $?
  fi
  # PORTABLE FALLBACK. Run the command in the background, poll for it to
  # finish in fixed 0.2s steps against a deadline, and kill it if the deadline
  # passes before it does. This is what stands in for `timeout` on a plain
  # macOS install.
  #
  # THE KILL TARGETS THE WHOLE PROCESS GROUP, NOT JUST THE ONE PID. A stub
  # (or a real prober) is commonly a shell script that itself runs a slow
  # command — kill THAT ONE pid and the script dies but its child lives on,
  # orphaned, still holding our output pipe open; the caller then blocks on
  # that grandchild for however long IT takes, which is the exact hang this
  # function exists to prevent. `set -m` gives the background job its own
  # process group (pgid == pid), so `kill -- -$pid` reaches the whole subtree.
  # This all runs inside the subshell a caller's command substitution already
  # forked for us, so enabling job control here cannot leak out to the caller.
  local step="0.2" max_steps i=0 pid rc
  max_steps=$(( secs * 5 ))
  [ "$max_steps" -gt 0 ] || max_steps=1
  set -m
  "$@" &
  pid=$!
  while kill -0 "$pid" 2>/dev/null; do
    if [ "$i" -ge "$max_steps" ]; then
      kill -- "-$pid" 2>/dev/null
      wait "$pid" 2>/dev/null
      set +m
      return 124
    fi
    sleep "$step"
    i=$((i + 1))
  done
  wait "$pid"; rc=$?
  set +m
  return "$rc"
}

# asset_probe <asset> — prints "<asset> <status> <detail>", rc 0.
asset_probe() {
  local a="${1:-}" type arg cmd out probe_status detail rc timeout_s
  [ -n "$a" ] || { printf '%s %s %s\n' "$a" "unknown" "no-asset-given"; return 0; }
  # An asset is "<type>" or "<type>:<arg>" — split on the FIRST colon only, so
  # an argument containing colons survives intact.
  case "$a" in
    *:*) type="${a%%:*}"; arg="${a#*:}" ;;
    *)   type="$a";       arg="" ;;
  esac
  cmd="${STEWARD_ASSET_PROBE_CMD:-}"
  if [ -z "$cmd" ] || [ ! -x "$cmd" ]; then
    printf '%s unknown no-probe-command\n' "$a"
    return 0
  fi
  timeout_s="${STEWARD_ASSET_PROBE_TIMEOUT:-5}"
  out="$(_asset_probe_run_with_timeout "$timeout_s" "$cmd" "$type" "$arg" 2>/dev/null)"; rc=$?
  if [ "$rc" -eq 124 ]; then
    printf '%s unknown probe-timeout\n' "$a"
    return 0
  fi
  if [ "$rc" -ne 0 ] || [ -z "$out" ]; then
    printf '%s unknown probe-failed-rc%s\n' "$a" "$rc"
    return 0
  fi
  probe_status="$(printf '%s' "$out" | awk '{print $1}')"
  detail="$(printf '%s' "$out" | awk '{$1=""; sub(/^ /,""); print}')"
  # THE VOCABULARY IS CLOSED. A prober that answers something else is a broken
  # prober, and a broken prober must not be able to invent a status the cockpit
  # would render as healthy.
  case "$probe_status" in
    up|local-only|down) ;;
    *) probe_status="unknown"; detail="bad-status-from-probe" ;;
  esac
  printf '%s %s %s\n' "$a" "$probe_status" "${detail:-none}"
  return 0
}
