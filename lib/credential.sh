#!/bin/bash
# lib/credential.sh - the credential seam: WHEN does a login's credential run out?
#
# THE MEASUREMENT THAT STARTED THIS. Seven sessions on one login sat with
# Remote Control down for most of a day. tmux was up, the supervisor rounds
# were green, the processes were alive - every instrument the product had said
# the homes were fine, because they were. What had ended was the login's
# refresh token, at a moment nobody could see, and the first anyone knew of it
# was a human saying "my sessions are disconnected". The number that would have
# said it was sitting in a file on disk the whole time, hours before the
# failure, and nothing in the product had ever asked for it.
#
# A DEADLINE IS NOT A STATE. This seam reports WHEN, never WHETHER: no field
# here says `expired`. That word is a comparison against a clock, and the clock
# belongs to whoever raises the alarm - a view rendering "in 40 minutes", a
# doctor probe with a threshold, an operator reading a table. A seam that
# baked the comparison in would freeze one policy into the measurement, and
# every reader that wanted a different threshold would have to un-derive it.
# Say the time; let the caller say the verdict.
#
# AND NEVER A PATH. The row carries times, a word and a note - never where the
# credential file lives. A path inside somebody's home is not needed to answer
# this row's question, and the row is read by more people than that home's
# owner. The estate's shim may name a path ON STDERR, to the operator fixing
# it; the row that travels into views and documents may not.
#
# NEVER THE VALUE, NEVER ITS LENGTH. The only things that leave this seam are
# timestamps and closed vocabulary. A token's value never appears in a row, a
# note, or an error message - and neither does its length, which is a fact
# about a secret and belongs to it. The estate's shim reads the credential; the
# product never learns anything about it but when it stops working.
#
# THE ONE RULE, SAME AS THE TWINS NEXT DOOR: THE ESTATE MEASURES, THE PRODUCT
# PROJECTS. Where a credential lives, what format it is in, which provider
# spells expiry in milliseconds and which in seconds - all of that is one
# estate's arrangement. The product runs a command named by
# STEWARD_CREDENTIAL_CMD, validates what comes back, and hands rows on.
#
# A ROW BELONGS TO A LOGIN, NOT TO A SESSION, and this is the whole reason the
# seam is not folded into either neighbour. The usage seam keys on (login,
# provider, WINDOW) and a credential has no window; the liveness seam keys on a
# session and a login can have NO SESSION RUNNING AT ALL and still be the one
# that fails next. The login with nothing running is exactly the row an
# operator most needs to see before starting work on it.
#
# rc IS ALWAYS 0. This layer REPORTS. What went wrong is a word in a row and a
# sentence on stderr, never a return code a caller has to translate back.

# CREDENTIAL_SEAM_REASON - why the seam produced no measurement, or "" when it
# answered. CREDENTIAL_DROPPED - how many answered rows the validation refused.
# VARIABLES AND NOT ROWS, for the reason the twins give at length: a row would
# have to carry a login name, and any name it carried could collide with a
# login the command really reported.
#
# THIS MEANS credential_rows MUST NOT BE CALLED IN A COMMAND SUBSTITUTION by a
# caller that wants either variable: `$( )` is a subshell and neither comes
# back. Redirect its stdout to a file instead.
CREDENTIAL_SEAM_REASON=""
CREDENTIAL_DROPPED=0

# THE STATE VOCABULARY IS CLOSED, because a view colours by it and an alarm
# branches on it. Four words, and the difference between the last three is the
# difference between three different things an operator must do:
#   measured        both times below are what the credential says
#   no-credential   this login HAS no credential to expire. Not a failed
#                   measurement - an operator does nothing about it.
#
#                   ITS OWN WORD, AND NOT usage's `not-applicable`, though both
#                   are "this is not a number". They mean different things and
#                   sharing a spelling would hide the difference: a window that
#                   is `not-applicable` has no percentage BY CONSTRUCTION and
#                   never will - it is permanent. A login with no credential is
#                   TEMPORARY: somebody signs in and there is one. A view that
#                   greys out the first is right; greying out the second hides
#                   the row an operator is about to act on. (butler, 2026-09-10)
#   unreadable      the credential is there and could not be read. The reason
#                   is in the note. An operator fixes a permission or a path.
#   unknown         we asked and got back nothing we could read. An operator
#                   fixes the shim.
# `unknown` is also what absence becomes - see credential_for at the bottom.
_CREDENTIAL_STATES="measured no-credential unreadable unknown"

# credential_rows - one TSV row per login the command ANSWERED ABOUT, stdout:
#   login<TAB>provider<TAB>access_expires<TAB>refresh_expires<TAB>measured_at<TAB>state<TAB>note
# The note is written by THIS FILE, never forwarded from the shim - see the
# split below. A shim's seventh column is read (so the field count is checked)
# and discarded.
# The three time fields are ISO 8601 UTC or EMPTY; empty is the honest way to
# say a time is not known, and a `measured` row must carry at least one. Logins
# the command did not mention are absent here; credential_for turns that
# absence into a word. rc 0 always.
credential_rows() {
  CREDENTIAL_SEAM_REASON=""
  CREDENTIAL_DROPPED=0
  export CREDENTIAL_DROPPED
  local cmd="${STEWARD_CREDENTIAL_CMD:-}"

  if [ -z "$cmd" ]; then
    # THE UNSET CASE IS QUIET ON PURPOSE, as in the twins: an estate that has
    # not wired a shim yet is a normal state, and a warning printed every run
    # is a warning nobody reads by the second week.
    CREDENTIAL_SEAM_REASON="seam-not-configured"
    return 0
  fi
  # THE THIRD COPY. This file is the third seam and it copies from the other
  # two rather than sharing with them. That was decided deliberately (butler,
  # 2026-09-10) and it comes with an expiry, so the copy names its siblings
  # line by line and the reader can see the whole debt in one place:
  #
  #   the four path gates below   <- lib/usage.sh, usage_rows, verbatim
  #   the outer deadline block    <- lib/usage.sh, usage_rows, which itself
  #                                  copied it from lib/liveness.sh,
  #                                  liveness_rows, where the evidence for
  #                                  every line of it is written out
  #   _credential_stamp_ok        <- lib/usage.sh, _usage_stamp_ok, same
  #                                  grammar, renamed
  #   the register-asked-once and drop-and-count-loudly shape
  #                               <- lib/usage.sh, usage_rows
  #
  # WHY COPY NOW: this row prevents a repeat of six days of silence, while the
  # extraction prevents a drift that has not happened yet; and an extraction
  # would touch TWO deployed seams that both changed this week, which is a
  # bigger review surface than the whole new seam.
  #
  # A FOURTH COPY IS NOT ACCEPTABLE. The trigger for extracting all of this
  # into one shared runner is written in the hub's queue: a fourth seam, OR the
  # first divergence between these three. Whoever reaches either of those does
  # the extraction then, while it is still mechanical - waiting past that turns
  # it into archaeology.
  #
  # The gate matters more here than in either sibling: the shim this seam runs
  # READS A CREDENTIAL, and "whatever PATH happens to find" is not a thing to
  # hand that authority to.
  case "$cmd" in
    */*) ;;
    *) echo "credential: STEWARD_CREDENTIAL_CMD must be a PATH to an executable, not the bare name '$cmd' - set it to the full path of the estate shim" >&2
       CREDENTIAL_SEAM_REASON="seam-not-a-path"; return 0 ;;
  esac
  case "$cmd" in
    /*) ;;
    *) echo "credential: STEWARD_CREDENTIAL_CMD must be an absolute path (leading '/'), got '$cmd' - a relative path resolves against whatever directory happens to be current, which this seam may not depend on" >&2
       CREDENTIAL_SEAM_REASON="seam-not-absolute"; return 0 ;;
  esac
  if [ ! -e "$cmd" ]; then
    echo "credential: STEWARD_CREDENTIAL_CMD names a path that does not exist: '$cmd' - no credential was measured" >&2
    CREDENTIAL_SEAM_REASON="seam-not-found"; return 0
  fi
  if [ ! -x "$cmd" ]; then
    echo "credential: STEWARD_CREDENTIAL_CMD is not executable: '$cmd' - no credential was measured" >&2
    CREDENTIAL_SEAM_REASON="seam-not-executable"; return 0
  fi

  local outf; outf="$(mktemp)" || {
    echo "credential: could not create a temporary file - no credential was measured" >&2
    CREDENTIAL_SEAM_REASON="seam-failed"; return 0; }
  local errf; errf="$(mktemp)" || {
    echo "credential: could not create a temporary file - no credential was measured" >&2
    rm -f "$outf"
    CREDENTIAL_SEAM_REASON="seam-failed"; return 0; }

  # -- THE OUTER DEADLINE ---------------------------------------------------
  # KNOWINGLY DUPLICATED from usage_rows, which carries the full evidence for
  # every line: `set -m` puts the shim in its own process group so the group
  # kill reaches a child it forked; the watchdog sleeps ONCE and signals rather
  # than polling; USR1 is silenced before the trap is removed.
  #
  # THE DEFAULT IS SHORTER THAN USAGE'S, and deliberately: a usage shim asks
  # several providers over the network, while a credential shim reads local
  # files. Ten seconds is already far outside what reading a file can take, so
  # a shim that reaches it is hung, not slow.
  local deadline="${STEWARD_CREDENTIAL_TIMEOUT:-10}"
  if ! [[ "$deadline" =~ ^[0-9]+$ ]] || [ "$deadline" -le 0 ]; then
    deadline=10
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
    local terr; terr="$(tr '\n' ' ' < "$errf")"
    rm -f "$outf" "$errf"
    echo "credential: the credential command did not answer within ${deadline}s and was killed: '$cmd'${terr:+ - before it was killed it said: $terr}" >&2
    CREDENTIAL_SEAM_REASON="seam-timeout"; return 0
  fi

  local cerr; cerr="$(tr '\n' ' ' < "$errf")"
  rm -f "$errf"

  if [ "$rc" -ne 0 ]; then
    rm -f "$outf"
    echo "credential: the credential command failed (rc $rc): '$cmd'${cerr:+ - it said: $cerr}" >&2
    CREDENTIAL_SEAM_REASON="seam-failed"; return 0
  fi
  [ -z "$cerr" ] || echo "credential: '$cmd' answered, and also said: $cerr" >&2

  if [ ! -s "$outf" ]; then
    rm -f "$outf"
    echo "credential: the credential command produced no output: '$cmd' - an empty answer is not an estate without credentials" >&2
    CREDENTIAL_SEAM_REASON="seam-no-output"; return 0
  fi

  # THE LOGIN REGISTER IS ASKED ONCE, NOT ONCE PER ROW. A register that refuses
  # leaves the known set empty and every row is then dropped as an unknown
  # login - loudly, with the register's own refusal already on stderr above it.
  if ! command -v registry_login_list >/dev/null 2>&1; then
    local _here; _here="$(CDPATH= cd -- "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    # shellcheck source=registry.sh
    . "$_here/registry.sh" || {
      echo "credential: could not load the registry - no row can be checked against the login register" >&2
      rm -f "$outf"
      CREDENTIAL_SEAM_REASON="seam-failed"; return 0; }
  fi
  local known; known="$(registry_login_list | tr '\n' ' ')"

  local tab; tab="$(printf '\t')"
  local line rest tabs nf login provider access refresh measured state note
  local d_login=0 d_provider=0 d_malformed=0
  while IFS= read -r line || [ -n "$line" ]; do
    [ -n "$line" ] || continue
    # THE FIELD COUNT IS MEASURED BEFORE THE SPLIT, and for the reason the twin
    # gives: the contract distinguishes a SHORT row (dropped) from a row whose
    # last column is empty (kept), and no splitter can tell those apart after
    # the fact. Six fields are required; the note is the only optional one.
    # STATE IS NOT OPTIONAL, unlike usage's trailing pair: a missing state
    # would have to be inferred from whether the stamps parsed, and inferring
    # it is precisely the derivation this file refuses to make.
    tabs="${line//[!$tab]/}"
    nf=$(( ${#tabs} + 1 ))
    if [ "$nf" -lt 6 ] || [ "$nf" -gt 7 ]; then
      d_malformed=$((d_malformed+1)); continue
    fi
    # SPLIT BY HAND, NOT WITH `IFS=<tab> read`. MEASURED by the twin, not
    # assumed: a tab is IFS WHITESPACE, so `read` collapses a run of them into
    # one separator and an empty column simply disappears - which here would
    # slide a state word into a time field. Every time column can legitimately
    # be empty, so the splitter has to be one that says so.
    while [ "$nf" -lt 7 ]; do line="$line$tab"; nf=$((nf+1)); done
    rest="$line"
    login="${rest%%$tab*}";    rest="${rest#*$tab}"
    provider="${rest%%$tab*}"; rest="${rest#*$tab}"
    access="${rest%%$tab*}";   rest="${rest#*$tab}"
    refresh="${rest%%$tab*}";  rest="${rest#*$tab}"
    measured="${rest%%$tab*}"; rest="${rest#*$tab}"
    state="${rest%%$tab*}";    rest="${rest#*$tab}"
    # THE SHIM'S OWN NOTE IS DROPPED, NOT PASSED THROUGH. A free-text column
    # the product forwards verbatim is a column a shim can put anything in,
    # including the credential it just read - and this seam's rule is that no
    # value leaves it, whoever wrote the value. The note that survives is the
    # one this file builds out of its own closed vocabulary. A shim with
    # something to say says it on stderr, which is quoted as evidence and read
    # by a human, not rendered as a field.
    note=""

    # A LOGIN THE REGISTER DOES NOT KNOW CANNOT BE SHOWN. The row names an
    # account nobody here can check, and a view that rendered it would be
    # reporting a deadline the estate never declared.
    # EXACT MEMBERSHIP, NOT A SUBSTRING OVER A SPACE-RUN. These fields are
    # TAB separated, so a value may legally contain SPACES - and the old
    # `case " $known " in *" $login "*` form asks whether the value appears
    # between two spaces anywhere in the list, which a value SPANNING TWO
    # NEIGHBOURS satisfies. Measured on this file 2026-09-10: with a register
    # holding `alpha` and `beta`, a shim writing the single login value
    # `alpha beta` was published - a deadline shown for an account the estate
    # never declared, straight through the rule three lines above. The same
    # hole was closed across the register the day before; this seam was
    # written from the old shape.
    #
    # THE RULE THAT SEPARATES A SAFE USE FROM A HOLE (butler, from a sweep of
    # all 17 occurrences): it is a hole when the needle is FREE TEXT FROM
    # OUTSIDE, or when the list spans more rows than the needle's own origin.
    # Both are true here - the needle is a raw field from a foreign shim and
    # the list is the whole login register.
    if ! _registry_word_in_list "$login" "$known"; then
      d_login=$((d_login+1)); continue
    fi
    if ! _registry_word_in_list "$provider" "$_REGISTRY_LOGIN_PROVIDERS"; then
      d_provider=$((d_provider+1)); continue
    fi

    # A BAD TIME IS EMPTIED AND KEPT, NOT DROPPED - the row is still evidence
    # that the login was looked at, and the raw text goes in the note because
    # it is the only record of what the shim actually produced.
    if ! _credential_stamp_ok "$access"; then
      note="$(_credential_note "$note" "access" "not-a-stamp")"; access=""
    fi
    if ! _credential_stamp_ok "$refresh"; then
      note="$(_credential_note "$note" "refresh" "not-a-stamp")"; refresh=""
    fi
    if ! _credential_stamp_ok "$measured"; then
      note="$(_credential_note "$note" "measured" "not-a-stamp")"; measured=""
    fi

    # A WORD OUTSIDE THE VOCABULARY BECOMES `unknown`, exactly as usage rewrites
    # a percentage it cannot read: the vocabulary is closed because a view
    # colours by it, and a shim that writes `expired` or `ok` is not given a
    # fifth colour by accident.
    # EXACT MEMBERSHIP HERE TOO, and the failure it prevents is a FIFTH WORD:
    # the value `measured no-credential` spans two entries and would be
    # published verbatim as a state, giving every view that colours by this
    # column a word its palette does not have.
    if ! _registry_word_in_list "$state" "$_CREDENTIAL_STATES"; then
      note="$(_credential_note "$note" "state" "not-in-vocabulary")"; state="unknown"
    fi

    # A ROW THAT CLAIMS A MEASUREMENT AND CARRIES NONE IS NOT A MEASUREMENT.
    # This is a SHAPE check and not the clock comparison this file refuses to
    # make: it asks whether the row contains what its own word promises, never
    # whether the time has passed. Without it, a shim whose parse silently
    # produced two empty stamps would publish `measured` with nothing in it,
    # and a view would render a login as checked and fine when nothing about
    # its credential was ever read.
    if [ "$state" = "measured" ] && [ -z "$access" ] && [ -z "$refresh" ]; then
      note="$(_credential_note "$note" "state" "measured-without-a-time")"
      state="unknown"
    fi
    # AND THE MIRROR: a row that says there is nothing to expire, while
    # carrying a time, contradicts itself just as loudly. Which half is true is
    # not for this layer to guess, so it says it does not know and keeps both
    # the word and the times in the note for whoever fixes the shim.
    if [ "$state" = "no-credential" ] && { [ -n "$access" ] || [ -n "$refresh" ]; }; then
      note="$(_credential_note "$note" "state" "no-credential-with-a-time")"
      state="unknown"
    fi

    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
      "$login" "$provider" "$access" "$refresh" "$measured" "$state" "$note"
  done < "$outf"
  rm -f "$outf"

  CREDENTIAL_DROPPED=$((d_login + d_provider + d_malformed))
  export CREDENTIAL_DROPPED
  # ONE LINE, WITH THE COUNT AND THE REASONS. Nothing about a dropped row is
  # silent, and nothing about it is shown as data.
  if [ "$CREDENTIAL_DROPPED" -gt 0 ]; then
    echo "credential: $CREDENTIAL_DROPPED row(s) dropped: unknown login ($d_login), unknown provider ($d_provider), malformed ($d_malformed)" >&2
  fi
  return 0
}

# _credential_stamp_ok <value> - true for an ISO 8601 UTC stamp, or for the
# empty string, which is the honest way to say a time is not known. THE SAME
# GRAMMAR AS _usage_stamp_ok, knowingly duplicated with the twins.
_credential_stamp_ok() {
  local v="${1:-}"
  [ -n "$v" ] || return 0
  [[ "$v" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9:.]+Z$ ]] || return 1
  return 0
}

# _credential_note <existing note> <field> <what was wrong> - the note with
# `<field>:<complaint>` appended, joined by `; ` when there is already one.
#
# THE FIELD IS NAMED, unlike the twin's `parse:<raw>`, because this row has
# THREE time columns and a state: a note reading `parse:12345` would not say
# which of four fields the shim got wrong.
#
# AND THE RAW VALUE IS NOT QUOTED - THE DELIBERATE DIVERGENCE FROM THE TWIN.
# usage_rows keeps the text that failed to parse, and it is right to: a
# percentage that did not parse is a percentage, and the raw text is the only
# evidence of what the shim produced. Here the same move is a leak waiting for
# one bad shim. The contract says these columns carry timestamps; a shim with a
# field-order bug puts a TOKEN in one, the stamp check refuses it, and the note
# would then publish the secret into every log, view and document downstream -
# the seam's one absolute rule broken by the seam's own error path.
#
# TRUNCATING IS NOT THE ANSWER EITHER: a prefix of a secret is a secret, and a
# length is a fact about it. So the note says WHAT SHAPE WAS WRONG and never
# what the value was. The estate can reproduce the raw output by running its
# own shim, which it owns; the product does not need a copy to do that for it.
_credential_note() {
  local have="${1:-}" field="${2:-}" complaint="${3:-}"
  if [ -n "$have" ]; then
    printf '%s; %s:%s' "$have" "$field" "$complaint"
  else
    printf '%s:%s' "$field" "$complaint"
  fi
}

# credential_for <login> <rows> - the matching row, or a row of the same seven
# fields carrying the reason instead of a measurement.
#
# THIS IS WHERE ABSENCE BECOMES A WORD. credential_rows prints only what was
# answered about; a caller that read a missing login as "nothing to report"
# would be reading silence as a working credential - which is exactly the
# reading that let seven sessions sit disconnected for a day.
#
# ABSENCE IS `unknown`, NEVER `no-credential`. A login nobody mentioned did not
# tell us it has no credential; it told us nothing. The two words send an
# operator to two different places, and only one of them is honest here.
credential_for() {
  local login="${1:-}" rows="${2:-}" hit
  hit="$(printf '%s\n' "$rows" | awk -F'\t' -v l="$login" '$1==l{print; exit}')"
  if [ -n "$hit" ]; then
    printf '%s\n' "$hit"
    return 0
  fi
  printf '%s\t%s\t\t\t\t%s\t%s\n' \
    "$login" "" "unknown" "${CREDENTIAL_SEAM_REASON:-not-reported}"
}
