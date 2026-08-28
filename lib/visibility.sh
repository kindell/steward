#!/bin/bash
# lib/visibility.sh — who may see a session, decided in one place.
#
# THIS IS A RENDERING RULE, NOT ACCESS CONTROL, and the distinction matters
# enough to state before anything else. The registry is readable; a caller can
# point STEWARD_REGISTRY_DIR anywhere and read any conf directly. What this
# function decides is what the TOOLS show and offer — the difference between a
# wall and a road that was never built. The real boundary is file permissions on
# the hosts.
#
# ONE PLACE. A rule scattered across a renderer, a command and a gate is a rule
# that drifts, and each copy drifts in a direction nobody chose. This file is
# the product's only answer to the question.
#
# REFUSAL IS THE DEFAULT. An unreadable conf, a missing owner, an entity that
# will not load: all answer NO. A registry that cannot be read must never become
# a permit — bus/lib.sh established that rule for the message gate and the same
# reasoning holds here.

# _visibility_member_of <person> <entity-id> — rc 0 if the entity loads and
# names that person in MEMBERS.
#
# Runs the load in a SUBSHELL so the ENTITY_* globals it sets never reach the
# caller: this function is asked several times in a row while the caller is
# mid-decision, and a load leaking into that would answer the next question with
# the previous entity's members.
_visibility_member_of() {
  local person="${1:-}" ent="${2:-}"
  [ -n "$person" ] && [ -n "$ent" ] || return 1
  ( registry_entity_load "$ent" >/dev/null 2>&1 || exit 1
    case " ${ENTITY_MEMBERS:-} " in *" $person "*) exit 0 ;; *) exit 1 ;; esac )
}

# session_visible_to <viewer> <session> — rc 0 visible, rc 1 not.
# Prints nothing on stdout; a reason reaches stderr only when the lookup itself
# could not be made.
session_visible_to() {
  local viewer="${1:-}" session="${2:-}"
  # AN EMPTY VIEWER IS NOT A WILDCARD. A caller that could not determine who is
  # asking must get nothing, not everything — the failure mode of the opposite
  # choice is silent and total.
  [ -n "$viewer" ] && [ -n "$session" ] || return 1

  if ! command -v registry_load >/dev/null 2>&1; then
    local _here; _here="$(CDPATH= cd -- "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    # shellcheck source=registry.sh
    . "$_here/registry.sh" || { echo "visibility: could not load the registry" >&2; return 1; }
  fi

  # SNAPSHOT EVERYTHING BEFORE ASKING ANYTHING ELSE. registry_load writes into
  # this shell, and _visibility_member_of loads entities; reading these fields
  # later would read whatever the last load left behind.
  registry_load "$session" >/dev/null 2>&1 || return 1
  local owner="${OWNER:-}" domain="${DOMAIN:-}"
  local vis="${VISIBILITY:-}" grants="${VISIBLE_TO:-}"
  [ -n "$owner" ] || return 1

  # 1. The owner, always — a private session is private FROM others, never from
  #    the person whose session it is.
  [ "$viewer" = "$owner" ] && return 0

  # 2. A group grant, BEFORE the private check. A board session sets both
  #    fields: private to withdraw it from the team, and a grant to hand it to
  #    the group. Checking private first would make the pair useless in exactly
  #    the case it exists for.
  local g
  for g in $grants; do
    _visibility_member_of "$viewer" "$g" && return 0
  done

  # 3. Private withdraws everything the derivation would otherwise give.
  [ "$vis" = "private" ] && return 1

  # 4. The derived team view: the entity that owns the work.
  [ -n "$domain" ] || return 1
  _visibility_member_of "$viewer" "$domain" && return 0

  # 5. ONE hop up MANAGED_BY, and only one. registry_entity_load follows the
  #    chain further with cycle detection, but visibility deliberately does not:
  #    a customer of a customer is not the same work, and a rule that walked the
  #    whole chain would grant an ever-widening circle nobody declared.
  local parent
  parent="$( registry_entity_load "$domain" >/dev/null 2>&1 && printf '%s' "${ENTITY_MANAGED_BY:-}" )"
  [ -n "$parent" ] || return 1
  _visibility_member_of "$viewer" "$parent" && return 0

  return 1
}
