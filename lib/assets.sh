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
