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
#
# ...WHICH IS WHY STDERR IS THE CHANNEL, AND WHY IT MUST NOT BE EMPTY. Measured
# 2026-08-28: an unset variable, a path that does not exist, a real file without
# its exec bit, a bare command name, a command that exits non-zero and a command
# whose output does not parse were BYTE-IDENTICAL — rc 0, nothing on either
# stream, a full column of `unknown` with no reason anywhere. rc stays 0; every
# distinguishable branch below says out loud what was wrong and what was tried.
# The unset case is the one deliberate exception: an estate that has not wired a
# shim yet is a normal state, and a warning printed on every run is a warning
# nobody reads by the second week.

# LIVENESS_SEAM_REASON — why the seam produced no measurement, or "" when it
# answered. Read by liveness_for to fill the reason field of a session it has no
# row for. It is a VARIABLE and not a row in the output on purpose: a row would
# have to carry a name, and any name it carried could collide with a session the
# command reported — which is the fabrication hazard this pair of files was
# already fixed for once.
#
# THIS MEANS liveness_rows MUST NOT BE CALLED IN A COMMAND SUBSTITUTION by a
# caller that wants the reason: `$( )` is a subshell and the variable would not
# come back. Redirect its stdout to a file instead; bin/steward does.
LIVENESS_SEAM_REASON=""

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

# liveness_rows — one TSV row per session the command ANSWERED ABOUT on stdout:
#   name<TAB>daemon<TAB>tmux<TAB>agent<TAB>runtime<TAB>model<TAB>last_activity<TAB>reason
# Sessions the command did not mention are simply absent here; liveness_for is
# what turns that absence into `unknown`. rc 0 always.
liveness_rows() {
  LIVENESS_SEAM_REASON=""
  local cmd="${STEWARD_LIVENESS_CMD:-}"

  if [ -z "$cmd" ]; then
    LIVENESS_SEAM_REASON="seam-not-configured"
    return 0
  fi
  # A PATH, NOT A COMMAND NAME. `[ -x ]` fails on anything unresolved, so a bare
  # name read exactly like every other silence — and it is the likeliest of the
  # mistakes, because most environment variables that name a command take one.
  # It is refused rather than resolved through PATH: what this seam runs reads a
  # socket carrying live conversations, and "whatever PATH happens to find"
  # is not a thing to hand that authority to.
  case "$cmd" in
    */*) ;;
    *) echo "liveness: STEWARD_LIVENESS_CMD must be a PATH to an executable, not the bare name '$cmd' — set it to the full path of the estate's shim" >&2
       LIVENESS_SEAM_REASON="seam-not-a-path"; return 0 ;;
  esac
  if [ ! -e "$cmd" ]; then
    echo "liveness: STEWARD_LIVENESS_CMD points at nothing: '$cmd' — no liveness was measured" >&2
    LIVENESS_SEAM_REASON="seam-not-found"; return 0
  fi
  if [ ! -x "$cmd" ]; then
    echo "liveness: STEWARD_LIVENESS_CMD is not executable: '$cmd' — no liveness was measured" >&2
    LIVENESS_SEAM_REASON="seam-not-executable"; return 0
  fi

  # THE COMMAND'S OWN STDERR IS EVIDENCE, NOT NOISE. `2>/dev/null` threw away
  # the one sentence that says which of these branches an operator is in.
  local errf; errf="$(mktemp)" || {
    echo "liveness: could not create a temporary file — no liveness was measured" >&2
    LIVENESS_SEAM_REASON="seam-failed"; return 0; }
  local out rc cerr
  out="$("$cmd" 2>"$errf")"; rc=$?
  cerr="$(tr '\n' ' ' < "$errf")"; rm -f "$errf"

  if [ "$rc" -ne 0 ]; then
    echo "liveness: the liveness command failed (rc $rc): '$cmd'${cerr:+ — it said: $cerr}" >&2
    LIVENESS_SEAM_REASON="seam-failed"; return 0
  fi
  # A COMMAND THAT SUCCEEDED AND STILL SAID SOMETHING has said something worth
  # reading — a shim warning about a host it skipped, say. It is not a failure,
  # so it does not become a reason; it is forwarded rather than swallowed.
  [ -z "$cerr" ] || echo "liveness: '$cmd' answered, and also said: $cerr" >&2

  if [ -z "$out" ]; then
    echo "liveness: the liveness command produced no output: '$cmd' — an empty answer is not an empty fleet" >&2
    LIVENESS_SEAM_REASON="seam-no-output"; return 0
  fi
  if ! printf '%s' "$out" | jq empty >/dev/null 2>&1; then
    echo "liveness: the liveness command's output is not valid JSON: '$cmd' — nothing was measured" >&2
    LIVENESS_SEAM_REASON="seam-unparseable"; return 0
  fi
  if [ "$(printf '%s' "$out" | jq -r '(.sessions|type) // "absent"' 2>/dev/null)" != "object" ]; then
    echo "liveness: the liveness command answered without a 'sessions' object: '$cmd' — nothing was measured" >&2
    LIVENESS_SEAM_REASON="seam-no-sessions-object"; return 0
  fi

  # A MISSING KEY AND AN EXPLICIT null ARE DIFFERENT FACTS, and jq is asked to
  # keep them apart: `has()` distinguishes "the command looked and found
  # nothing" (null, rendered as a dash) from "the command never looked"
  # (absent, rendered as unknown). Collapsing them would turn an unmeasured
  # field into a measured emptiness.
  #
  # `omitted` IS THE ESTATE'S OWN REASON FOR A SESSION IT COULD NOT MEASURE.
  # The omission rule is unchanged — an unmeasurable session is still left out
  # of `sessions` and never guessed — but a shim that knows why may say so, and
  # that sentence is worth more to a reader than "not in the answer". Every one
  # of its status fields is forced to `unknown` here: the estate is supplying a
  # REASON, not a measurement, and must not be able to smuggle a status word in
  # through this door.
  printf '%s' "$out" | jq -r '
    ((.sessions // {}) | to_entries[] |
      .key as $n | .value as $v |
      [ $n,
        ($v.daemon  // "unknown"),
        ($v.tmux    // "unknown"),
        ($v.agent   // "unknown"),
        ($v.runtime // "unknown"),
        (if ($v|has("model"))        then ($v.model        // "-") else "unknown" end),
        (if ($v|has("lastActivity")) then ($v.lastActivity // "-") else "unknown" end),
        "-"
      ]),
    ((.omitted // {}) | (if type == "object" then . else {} end) | to_entries[] |
      [ .key, "unknown", "unknown", "unknown", "unknown", "-", "-",
        ((.value | tostring) as $r |
          if ($r == "" or $r == "-") then "omitted-without-reason" else $r end)
      ])
    | @tsv' 2>/dev/null | while IFS=$'\t' read -r n d t a r m l rs; do
      # RUNTIME IS DELIBERATELY NOT PUT THROUGH _liveness_word, unlike the three
      # status fields beside it. A runtime is a NAME, not a state: the registry
      # already carries two and a third appears the day one is added, and
      # rewriting an unrecognised name to `unknown` would report "we could not
      # measure the runtime" about a runtime that was measured perfectly well.
      # The status words are a closed vocabulary because a view colours them; a
      # runtime name is rendered as itself.
      #
      # `${r:-unknown}` and `${l:-unknown}` conflate an explicit empty string
      # with an absent field — the very distinction this file exists to keep.
      # It is unreachable as written: the jq above never emits an empty field
      # (every branch substitutes "unknown" or "-"), and the contract does not
      # define what an empty string from a liveness command would mean. Left as
      # a floor for a future edit to land on, not as a translation.
      printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$n" \
        "$(_liveness_word "$d" loaded missing unknown)" \
        "$(_liveness_word "$t" up down unknown)" \
        "$(_liveness_word "$a" running not-running unknown)" \
        "${r:-unknown}" "${m:--}" "${l:-unknown}" "${rs:--}"
    done
  return 0
}

# liveness_for <name> <rows> — the session's row, or a fully-unknown one.
#
# THIS IS WHERE ABSENCE BECOMES A WORD. liveness_rows prints only what was
# measured; a caller that read a missing name as "nothing to report" would be
# reading silence as health. Every caller gets eight fields, always.
#
# AND THE EIGHTH FIELD IS WHY. An `unknown` with no reason is the same silence
# the whole model was built to make impossible — six causes rendering as one
# word, in a document a view reads and cannot add to. `-` means there is nothing
# to explain: the session was genuinely measured.
liveness_for() {
  local name="${1:-}" rows="${2:-}" hit
  hit="$(printf '%s\n' "$rows" | awk -F'\t' -v n="$name" '$1==n{print; exit}')"
  if [ -n "$hit" ]; then printf '%s\n' "$hit"; return 0; fi
  # THE SEAM'S OWN FAILURE OUTRANKS "not in the answer". If the command never
  # ran, saying the session was not among its answers would be true and
  # useless — there were no answers.
  local reason="${LIVENESS_SEAM_REASON:-}"
  [ -n "$reason" ] || reason="not-in-answer"
  printf '%s\tunknown\tunknown\tunknown\tunknown\t-\t-\t%s\n' "$name" "$reason"
  return 0
}
