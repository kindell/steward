#!/bin/bash
# lib/usage.sh - the usage seam: how much of a subscription window is spent?
#
# THE MEASUREMENT THAT STARTED THIS. A session died in the middle of a task
# because the five-hour window behind it had reached 100 percent. Nobody had a
# number to look at beforehand, and the failure read as a broken session rather
# than an empty budget. The number existed the whole time; nothing in the
# product had ever asked for it.
#
# THE ONE RULE: THE ESTATE MEASURES, THE PRODUCT PROJECTS. The product never
# talks to a provider. Every provider has its own network address, its own credential
# directory, its own answer shape, and half of one answer is text meant for a
# human to read. A product that hardcoded any of that would be one estate wired
# into a library. So the measurement is a command the estate supplies, named by
# STEWARD_USAGE_CMD, and this file only runs it, validates what comes back, and
# hands rows on. Same shape as the liveness seam next door.
#
# A WINDOW BELONGS TO A LOGIN, NOT TO A SESSION. Several sessions can run on one
# login and they all drain the same window; several logins can share one plan.
# Keying rows on the session would report the same window several times over as
# though each were its own budget, and would have nothing at all to say about a
# login with no session running. The first column is the login slug, and the
# login register is the vocabulary for it.
#
# A BAD NUMBER IS `unknown`, NEVER 0 AND NEVER 100. Both of those are readable
# answers a view would render and a person would act on - 0 means go ahead, 100
# means stop - and a parse that failed measured neither. The raw text that did
# not parse is kept in the note, so the estate can fix its shim from the
# evidence rather than from a guess.
#
# used_percent HAS THREE WORDS, AND THE TWO NON-NUMBERS MEAN DIFFERENT THINGS:
#   0-100           a measured share of this window
#   unknown         we asked and got no readable answer back
#   not-applicable  this row's window HAS no percentage, by construction
# The third arrived with usage-design r2 (2026-09-09) for rows that are not a
# quota at all - `tokens-written`, `exhausted` - which an estate wants beside
# the quota rows, grouped and sorted with them, and which used to have no honest
# word: `unknown` there would have claimed a failed measurement that was never
# attempted. The spelling is the fleet's (kindell/butler fleet/src/core.js, per
# butler's reading of it), not a new coinage, so two spellings of one idea do
# not become two vocabularies. ABSENCE IS STILL `unknown`: usage_for below says
# `unknown` for a window nobody mentioned, never `not-applicable`, because a row
# that is missing did not tell us its window has no percentage - it told us
# nothing.
#
# rc IS ALWAYS 0. This layer REPORTS. What went wrong is a word in a row and a
# sentence on stderr, never a return code a caller has to translate back into a
# reason it can show.

# USAGE_SEAM_REASON - why the seam produced no measurement, or "" when it
# answered. Read by usage_for to fill the reason field of a window it has no row
# for. A VARIABLE and not a row, for the reason the liveness twin gives at
# length: a row would have to carry a login name, and any name it carried could
# collide with a login the command really reported.
#
# USAGE_DROPPED - how many answered rows were refused by the validation below.
# Exported so a caller can surface it; also named on stderr, once, with the
# reasons.
#
# THIS MEANS usage_rows MUST NOT BE CALLED IN A COMMAND SUBSTITUTION by a caller
# that wants either variable: `$( )` is a subshell and neither would come back.
# Redirect its stdout to a file instead.
USAGE_SEAM_REASON=""
USAGE_DROPPED=0

# The provider vocabulary: the login register closed set, plus the
# pay-as-you-go source that has no login row of its own yet.
_USAGE_EXTRA_PROVIDERS="openai-api"

# usage_rows - one TSV row per window the command ANSWERED ABOUT, on stdout:
#   login<TAB>provider<TAB>window<TAB>used_percent<TAB>resets_at<TAB>measured_at<TAB>budget_id<TAB>note
# used_percent is 0-100, `unknown` or `not-applicable` - see the three-word note
# above. Windows the command did not mention are simply absent here; usage_for
# is what turns that absence into `unknown`. rc 0 always.
usage_rows() {
  USAGE_SEAM_REASON=""
  USAGE_DROPPED=0
  export USAGE_DROPPED
  local cmd="${STEWARD_USAGE_CMD:-}"

  if [ -z "$cmd" ]; then
    # THE UNSET CASE IS QUIET ON PURPOSE. An estate that has not wired a shim
    # yet is a normal state, and a warning printed on every run is a warning
    # nobody reads by the second week.
    USAGE_SEAM_REASON="seam-not-configured"
    return 0
  fi
  # A PATH, NOT A COMMAND NAME - refused rather than resolved through PATH. The
  # shim this seam runs reads a credential directory, and "whatever PATH happens
  # to find" is not a thing to hand that authority to.
  case "$cmd" in
    */*) ;;
    *) echo "usage: STEWARD_USAGE_CMD must be a PATH to an executable, not the bare name '$cmd' - set it to the full path of the estate shim" >&2
       USAGE_SEAM_REASON="seam-not-a-path"; return 0 ;;
  esac
  # ABSOLUTE, NOT MERELY "CONTAINS A SLASH". `./shim` carries a slash and would
  # resolve against whatever directory happened to be current when this ran.
  # Refused before the shim is ever touched.
  case "$cmd" in
    /*) ;;
    *) echo "usage: STEWARD_USAGE_CMD must be an absolute path (leading '/'), got '$cmd' - a relative path resolves against whatever directory happens to be current, which this seam may not depend on" >&2
       USAGE_SEAM_REASON="seam-not-absolute"; return 0 ;;
  esac
  if [ ! -e "$cmd" ]; then
    echo "usage: STEWARD_USAGE_CMD names a path that does not exist: '$cmd' - no usage was measured" >&2
    USAGE_SEAM_REASON="seam-not-found"; return 0
  fi
  if [ ! -x "$cmd" ]; then
    echo "usage: STEWARD_USAGE_CMD is not executable: '$cmd' - no usage was measured" >&2
    USAGE_SEAM_REASON="seam-not-executable"; return 0
  fi

  # THE STDERR OF THE COMMAND IS EVIDENCE, NOT NOISE - the one sentence that
  # says which branch an operator is in.
  local outf; outf="$(mktemp)" || {
    echo "usage: could not create a temporary file - no usage was measured" >&2
    USAGE_SEAM_REASON="seam-failed"; return 0; }
  local errf; errf="$(mktemp)" || {
    echo "usage: could not create a temporary file - no usage was measured" >&2
    rm -f "$outf"
    USAGE_SEAM_REASON="seam-failed"; return 0; }

  # -- THE OUTER DEADLINE ---------------------------------------------------
  # KNOWINGLY DUPLICATED from liveness_rows in lib/liveness.sh, which carries
  # the full evidence for every line of it: `set -m` around the backgrounding
  # is what puts the shim in its own process group so the group kill reaches a
  # child the shim forked; the watchdog is a subshell that sleeps ONCE and
  # signals, not a poll loop; it needs its own group for the same reason; USR1
  # is silenced before the trap is removed. Collapsing the two into one shared
  # runner is a separate change - doing it here would move a guard the liveness
  # seam depends on, in the same commit that adds a second caller for it.
  # A usage shim asks several providers over the network, so its honest answer
  # is slower than a local probe; the deadline guards against a HUNG shim, not
  # a slow measurement.
  local deadline="${STEWARD_USAGE_TIMEOUT:-30}"
  if ! [[ "$deadline" =~ ^[0-9]+$ ]] || [ "$deadline" -le 0 ]; then
    deadline=30
  fi

  local pid
  set -m
  "$cmd" >"$outf" 2>"$errf" &
  pid=$!
  set +m

  local timed_out=""
  trap 'timed_out=1' USR1
  set -m
  ( sleep "$deadline"; kill -USR1 $$ 2>/dev/null ) &
  local watchdog=$!
  set +m

  local rc
  wait "$pid" 2>/dev/null; rc=$?
  trap '' USR1
  kill -- "-$watchdog" 2>/dev/null
  wait "$watchdog" 2>/dev/null
  trap - USR1

  if [ -n "$timed_out" ]; then
    { kill -TERM -- "-$pid" 2>/dev/null
      sleep 0.2
      kill -KILL -- "-$pid" 2>/dev/null
      wait "$pid" 2>/dev/null
    } 2>/dev/null
    # WHAT A HUNG SHIM MANAGED TO SAY IS KEPT, exactly as the failure path below
    # keeps it. A shim that hung had usually already named the provider it was
    # waiting on, and that sentence is the only thing in the whole run that says
    # WHERE it stopped; deleting the file unread left an operator with a deadline
    # and nothing to act on. Flattened to one line for the same reason as below.
    local terr; terr="$(tr '\n' ' ' < "$errf")"
    rm -f "$outf" "$errf"
    echo "usage: the usage command did not answer within ${deadline}s and was killed: '$cmd'${terr:+ - before it was killed it said: $terr}" >&2
    USAGE_SEAM_REASON="seam-timeout"; return 0
  fi

  local cerr; cerr="$(tr '\n' ' ' < "$errf")"
  rm -f "$errf"

  if [ "$rc" -ne 0 ]; then
    rm -f "$outf"
    echo "usage: the usage command failed (rc $rc): '$cmd'${cerr:+ - it said: $cerr}" >&2
    USAGE_SEAM_REASON="seam-failed"; return 0
  fi
  # A COMMAND THAT SUCCEEDED AND STILL SAID SOMETHING has said something worth
  # reading - a login it skipped, say. Not a failure, so not a reason.
  [ -z "$cerr" ] || echo "usage: '$cmd' answered, and also said: $cerr" >&2

  if [ ! -s "$outf" ]; then
    rm -f "$outf"
    echo "usage: the usage command produced no output: '$cmd' - an empty answer is not an empty plan" >&2
    USAGE_SEAM_REASON="seam-no-output"; return 0
  fi

  # THE LOGIN REGISTER IS ASKED ONCE, NOT ONCE PER ROW. A register that refuses
  # (it does not exist, say) leaves the known set empty and every row is then
  # dropped as an unknown login - loudly, with the refusal of the register
  # itself already on stderr above it, which is the whole explanation.
  if ! command -v registry_login_list >/dev/null 2>&1; then
    local _here; _here="$(CDPATH= cd -- "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    # shellcheck source=registry.sh
    . "$_here/registry.sh" || {
      echo "usage: could not load the registry - no row can be checked against the login register" >&2
      rm -f "$outf"
      USAGE_SEAM_REASON="seam-failed"; return 0; }
  fi
  local known; known="$(registry_login_list | tr '\n' ' ')"

  local tab; tab="$(printf '\t')"
  local line rest tabs nf login provider window pct resets measured budget note
  local d_login=0 d_provider=0 d_malformed=0
  while IFS= read -r line || [ -n "$line" ]; do
    [ -n "$line" ] || continue
    # THE FIELD COUNT IS MEASURED BEFORE THE SPLIT. The contract distinguishes a
    # SHORT row (dropped) from a row whose last two columns are empty (kept),
    # and no splitter can tell those apart after the fact.
    tabs="${line//[!$tab]/}"
    nf=$(( ${#tabs} + 1 ))
    if [ "$nf" -lt 6 ] || [ "$nf" -gt 8 ]; then
      d_malformed=$((d_malformed+1)); continue
    fi
    # SPLIT BY HAND, NOT WITH `IFS=<tab> read`. MEASURED, not assumed: a tab is
    # IFS WHITESPACE, so `read` collapses a run of them into one separator and
    # an empty column simply disappears - a row whose reset time was blank came
    # out with the measurement time in that column and every field after it
    # shifted one place left. Every column here can legitimately be empty, so
    # the splitter has to be one that says so.
    while [ "$nf" -lt 8 ]; do line="$line$tab"; nf=$((nf+1)); done
    rest="$line"
    login="${rest%%$tab*}";    rest="${rest#*$tab}"
    provider="${rest%%$tab*}"; rest="${rest#*$tab}"
    window="${rest%%$tab*}";   rest="${rest#*$tab}"
    pct="${rest%%$tab*}";      rest="${rest#*$tab}"
    resets="${rest%%$tab*}";   rest="${rest#*$tab}"
    measured="${rest%%$tab*}"; rest="${rest#*$tab}"
    budget="${rest%%$tab*}";   rest="${rest#*$tab}"
    note="$rest"

    # A LOGIN THE REGISTER DOES NOT KNOW CANNOT BE SHOWN. The row names an
    # account nobody here can check, and a view that rendered it would be
    # reporting a budget the estate never declared.
    case " $known " in
      *" $login "*) ;;
      *) d_login=$((d_login+1)); continue ;;
    esac
    case " $_REGISTRY_LOGIN_PROVIDERS $_USAGE_EXTRA_PROVIDERS " in
      *" $provider "*) ;;
      *) d_provider=$((d_provider+1)); continue ;;
    esac
    # THE WINDOW IS A KEY, AND A KEY WITH A SPACE IN IT IS NOT A KEY. Free-form
    # after the known names, but it is what usage_for matches on and what a view
    # groups by.
    if ! [[ "$window" =~ ^[A-Za-z0-9._-]+$ ]]; then
      d_malformed=$((d_malformed+1)); continue
    fi

    # A PARSE FAILURE IS KEPT, NOT DROPPED. The row is evidence that the window
    # exists and was looked at; only the number is missing, and saying so is
    # worth more than saying nothing about the window at all.
    # AND A KEPT NUMBER IS WRITTEN CANONICALLY, not as the shim spelled it. A
    # shim that zero-pads is not lying about the number, so `0100` is accepted -
    # but emitted verbatim it would be compared against 100 by every later
    # reader and miss an EXHAUSTED window, and written into a document as a
    # number it would be a document nothing can read back.
    # THE THIRD WORD IS ACCEPTED LITERALLY, AND THE NUMBER GRAMMAR IS NOT
    # WIDENED FOR IT. `not-applicable` passes only as itself - exact spelling,
    # exact case - and _usage_percent_ok still admits nothing but 0-100. A
    # shim that writes `n/a` or `N/A` is rewritten to `unknown` with the raw
    # text in the note, exactly like any other word: the vocabulary is closed
    # because a view colours by it.
    if [ "$pct" = "not-applicable" ]; then
      :
    elif _usage_percent_ok "$pct"; then
      pct="$((10#$pct))"
    else
      note="$(_usage_note "$note" "$pct")"
      pct="unknown"
    fi
    if ! _usage_stamp_ok "$resets"; then
      note="$(_usage_note "$note" "$resets")"
      resets=""
    fi
    if ! _usage_stamp_ok "$measured"; then
      note="$(_usage_note "$note" "$measured")"
      measured=""
    fi

    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
      "$login" "$provider" "$window" "$pct" "$resets" "$measured" "$budget" "$note"
  done < "$outf"
  rm -f "$outf"

  USAGE_DROPPED=$((d_login + d_provider + d_malformed))
  export USAGE_DROPPED
  # ONE LINE, WITH THE COUNT AND THE REASONS. Nothing about a dropped row is
  # silent, and nothing about it is shown as data.
  if [ "$USAGE_DROPPED" -gt 0 ]; then
    echo "usage: $USAGE_DROPPED row(s) dropped: unknown login ($d_login), unknown provider ($d_provider), malformed ($d_malformed)" >&2
  fi
  return 0
}

# _usage_percent_ok <value> - true for an integer 0-100 and nothing else.
# Leading zeros are allowed here and canonicalised by the caller.
#
# THE SHAPE IS THE WHOLE CHECK, AND ARITHMETIC IS NOT PART OF IT. The first
# version of this asked `[[ $v =~ ^[0-9]+$ ]]` and then `[ "$((10#$v))" -le 100 ]`,
# which let a long digit string through: shell arithmetic is 64-bit and WRAPS, so
# `18446744073709551617` evaluates to 1 and `99999999999999999999999999` to a
# negative number, and both are `-le 100`. Roughly half of all long digit strings
# wrap to something small enough to pass - MEASURED, both of those were emitted as
# percentages of a subscription window. A percent is at most three characters, so
# the shape alone decides it and no value this function accepts can overflow
# anything the caller does with it afterwards.
#
# THE LENGTH BOUND RUNS FIRST so a pathological input is refused before the
# regular expression engine ever sees it.
_usage_percent_ok() {
  local v="${1:-}"
  [ "${#v}" -le 12 ] || return 1
  [[ "$v" =~ ^0*(100|[0-9]{1,2})$ ]] || return 1
  return 0
}

# _usage_stamp_ok <value> - true for an ISO 8601 UTC stamp, or for the empty
# string, which is the honest way to say a time is not known.
_usage_stamp_ok() {
  local v="${1:-}"
  [ -n "$v" ] || return 0
  [[ "$v" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9:.]+Z$ ]] || return 1
  return 0
}

# _usage_note <existing note> <raw value that did not parse> - the note with
# `parse:<raw>` appended, joined by `; ` when the shim already wrote one. The
# raw text is kept because it is the only evidence of what the shim actually
# produced; a note that said only "bad value" would send the estate looking.
_usage_note() {
  local have="${1:-}" raw="${2:-}"
  if [ -n "$have" ]; then
    printf '%s; parse:%s' "$have" "$raw"
  else
    printf 'parse:%s' "$raw"
  fi
}

# usage_for <login> <window> <rows> - the matching row, or a row of the same
# eight fields carrying the reason instead of a measurement.
#
# THIS IS WHERE ABSENCE BECOMES A WORD. usage_rows prints only what was
# measured; a caller that read a missing window as "nothing to report" would be
# reading silence as capacity.
usage_for() {
  local login="${1:-}" window="${2:-}" rows="${3:-}" hit
  hit="$(printf '%s\n' "$rows" | awk -F'\t' -v l="$login" -v w="$window" '$1==l && $3==w{print; exit}')"
  if [ -n "$hit" ]; then printf '%s\n' "$hit"; return 0; fi
  # THE FAILURE OF THE SEAM OUTRANKS "not in the answer". If the command never
  # ran, saying the window was not among its answers would be true and useless -
  # there were no answers.
  local reason="${USAGE_SEAM_REASON:-}"
  [ -n "$reason" ] || reason="not-in-answer"
  # THE PROVIDER IS A DASH, NOT A GUESS. A window nobody measured has no
  # provider this file may name: the login register would answer for the login,
  # but the row is about a WINDOW, and inventing its provider here would render
  # exactly like a measured one.
  printf '%s\t-\t%s\tunknown\t\t\t\t%s\n' "$login" "$window" "$reason"
  return 0
}
