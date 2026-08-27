#!/bin/bash
# lib/liveness.sh — the liveness seam: is a session actually running?
#
# THE PRODUCT DOES NOT MEASURE THIS ITSELF, AND CANNOT. Liveness means reading a
# launch manager, a multiplexer socket and a log file — all of them named by an
# estate's own conventions, on an estate's own operating system. A product that
# hardcoded those would be one estate's tool wearing a product's name.
#
# So the measurement is a command the estate supplies, named by
# STEWARD_LIVENESS_CMD. Same shape as the asset probers: the product dispatches,
# the estate owns the machine knowledge.
#
# THE SEAM IS ALSO A SAFETY BOUNDARY. The real command reads a live multiplexer
# socket — the same socket that carries running conversations. A suite that
# called it for real could type into one. Injecting it is what lets the whole
# layer be tested without ever touching a live session.
#
# ONE CALL PER RUN, NOT ONE PER SESSION. The contract takes no arguments and
# returns the whole fleet, deliberately: the asset layer makes one remote round
# trip per session at roughly a second and three quarters each, and liveness
# must not inherit that cost.
#
# rc IS ALWAYS 0. This layer REPORTS. A caller that wants to act on health reads
# the words; the return code would only say whether a command ran, which is
# already visible as `unknown`.

# _liveness_word <value> <valid...> — echo the value if it is in the closed set,
# otherwise `unknown`.
#
# THE VOCABULARY IS CLOSED PER FIELD. A command that answers `excellent` for a
# daemon is a broken command, and a broken command must never be able to invent
# a word a view would render as healthy.
_liveness_word() {
  local v="${1:-}" c; shift
  for c in "$@"; do [ "$v" = "$c" ] && { printf '%s' "$v"; return 0; }; done
  printf 'unknown'
}

# liveness_rows — one TSV row per MEASURED session on stdout:
#   name<TAB>daemon<TAB>tmux<TAB>agent<TAB>runtime<TAB>model<TAB>last_activity
# Sessions the command did not mention are simply absent here; liveness_for is
# what turns that absence into `unknown`. rc 0 always.
liveness_rows() {
  local cmd="${STEWARD_LIVENESS_CMD:-}"
  [ -n "$cmd" ] && [ -x "$cmd" ] || return 0
  local out; out="$("$cmd" 2>/dev/null)" || return 0
  [ -n "$out" ] || return 0

  # A MISSING KEY AND AN EXPLICIT null ARE DIFFERENT FACTS, and jq is asked to
  # keep them apart: `has()` distinguishes "the command looked and found
  # nothing" (null, rendered as a dash) from "the command never looked"
  # (absent, rendered as unknown). Collapsing them would turn an unmeasured
  # field into a measured emptiness.
  printf '%s' "$out" | jq -r '
    .sessions // {} | to_entries[] |
    .key as $n | .value as $v |
    [ $n,
      ($v.daemon  // "unknown"),
      ($v.tmux    // "unknown"),
      ($v.agent   // "unknown"),
      ($v.runtime // "unknown"),
      (if ($v|has("model"))        then ($v.model        // "-") else "unknown" end),
      (if ($v|has("lastActivity")) then ($v.lastActivity // "-") else "unknown" end)
    ] | @tsv' 2>/dev/null | while IFS=$'\t' read -r n d t a r m l; do
      printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$n" \
        "$(_liveness_word "$d" loaded missing unknown)" \
        "$(_liveness_word "$t" up down unknown)" \
        "$(_liveness_word "$a" running not-running unknown)" \
        "${r:-unknown}" "${m:--}" "${l:-unknown}"
    done
  return 0
}

# liveness_for <name> <rows> — the session's row, or a fully-unknown one.
#
# THIS IS WHERE ABSENCE BECOMES A WORD. liveness_rows prints only what was
# measured; a caller that read a missing name as "nothing to report" would be
# reading silence as health. Every caller gets seven fields, always.
liveness_for() {
  local name="${1:-}" rows="${2:-}" hit
  hit="$(printf '%s\n' "$rows" | awk -F'\t' -v n="$name" '$1==n{print; exit}')"
  if [ -n "$hit" ]; then printf '%s\n' "$hit"; return 0; fi
  printf '%s\tunknown\tunknown\tunknown\tunknown\t-\tunknown\n' "$name"
  return 0
}
