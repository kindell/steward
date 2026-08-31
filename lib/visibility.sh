#!/bin/bash
# lib/visibility.sh — who may see a session, decided in one place.
#
# THIS IS A RENDERING RULE, NOT ACCESS CONTROL, and the distinction matters
# enough to state before anything else. The registry is readable; a caller can
# set STEWARD_REGISTRY_DIR to any directory and read any conf directly. What
# this function decides is what the TOOLS show and offer — the difference
# between a wall and a road that was never built. The real boundary is file
# permissions on the hosts.
#
# ONE PLACE. A rule scattered across a renderer, a command and a gate is a rule
# that drifts, and each copy drifts in a direction nobody chose. This file is
# the product's only answer to the question.
#
# REFUSAL IS THE DEFAULT. An unreadable conf, a missing owner, an entity that
# will not load: all answer NO. A registry that cannot be read must never become
# a permit — bus/lib.sh established that rule for the message gate and the same
# reasoning holds here.
#
# AND THE CALLER CANNOT TELL THE TWO APART, BY DESIGN. This function answers in
# a return code and has two outcomes, not three: "this viewer has no claim" and
# "we could not resolve who would have one" both come back as rc 1. A caller
# that counts refusals is counting both, and must not describe its count as a
# policy decision — see the `hidden` section of docs/client-spec.md, rewritten
# 2026-08-28 after a live read found a registry gap being reported that way.

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
  local target_project="${TARGET_PROJECT:-}" target_entity="${TARGET_ENTITY:-}"
  [ -n "$owner" ] || return 1

  # 1. The owner, always — a private session is private FROM others, never from
  #    the person whose session it is.
  [ "$viewer" = "$owner" ] && return 0

  # 2. A group grant, BEFORE the private check. A board session sets both
  #    fields: private to withdraw it from the team, and a grant to hand it to
  #    the group. Checking private first would make the pair useless in exactly
  #    the case it exists for.
  #
  #    THE SPLIT IS WANTED; THE GLOB IS NOT. An unquoted `$grants` is word
  #    splitting AND pathname expansion, so the same conf and the same viewer
  #    answer differently from different working directories. Measured
  #    2026-08-28 with VISIBLE_TO="*" on a private session: from a cwd holding
  #    a file named after a real group, the asterisk became that group and a
  #    non-member was let in. lib/registry.sh validates this field, and the
  #    validation cannot help — the expansion happens after it, here.
  #
  #    THE SPLIT IS CAPTURED INTO AN ARRAY rather than looped under `set -f`,
  #    because the loop RETURNS from inside itself on a match: a restore after
  #    the loop would never run on the path that matters and would leave
  #    globbing disabled in the caller's shell. One line under the flag.
  local _had_f; case "$-" in *f*) _had_f=1 ;; *) _had_f="" ;; esac
  set -f
  # shellcheck disable=SC2206  # splitting is intended here; globbing is off
  local _grant_list=( $grants )
  [ -n "$_had_f" ] || set +f
  local g
  for g in "${_grant_list[@]+"${_grant_list[@]}"}"; do
    _visibility_member_of "$viewer" "$g" && return 0
  done

  # 3. Private withdraws everything the derivation would otherwise give.
  [ "$vis" = "private" ] && return 1

  # 4. THE TARGET IS THE ANSWER; DOMAIN IS ONLY THE LEGACY FALLBACK. A new-shape
  #    row states which entity owns the work in TARGET_ENTITY, and its DOMAIN is
  #    whatever the row carried before — after a migration that value can name
  #    an entity that never existed.
  #
  #    MEASURED 2026-08-31: a machine session whose TARGET_ENTITY named a real
  #    team was HIDDEN from that team's members, because this rule read the
  #    stale DOMAIN, found no such entity, and failed closed. Failing closed is
  #    the right DEFAULT and the WRONG ANSWER when the target resolves — and it
  #    was silent: the engine simply reported one row fewer.
  #
  #    Order: the declared target first, the legacy value second. An old-shape
  #    row carries no target and reads exactly as before.
  local owning_entity=""
  [ -n "$target_entity" ] && owning_entity="$target_entity"
  [ -n "$owning_entity" ] || owning_entity="$domain"
  [ -n "$owning_entity" ] || return 1
  _visibility_member_of "$viewer" "$owning_entity" && return 0
  domain="$owning_entity"

  # 4b. A NEW-SHAPE SESSION AIMED AT A PROJECT. Its DOMAIN is a legacy-derived
  #     value equal to the project slug — NOT an entity — so rule 4 missed it,
  #     and a member of the team that owns the project's work could not see it.
  #     The owning entity is the project's PARENT: resolve it, check membership,
  #     and hand it to rule 5 below so the one MANAGED_BY hop (a client's work
  #     seen by the managing team) still applies. Old-shape sessions carry no
  #     TARGET_PROJECT and skip this block entirely — their reading is unchanged.
  if [ -n "$target_project" ]; then
    local proj_parent
    proj_parent="$( registry_project_load "$target_project" >/dev/null 2>&1 && printf '%s' "${PROJECT_PARENT:-}" )"
    if [ -n "$proj_parent" ]; then
      _visibility_member_of "$viewer" "$proj_parent" && return 0
      domain="$proj_parent"
    fi
  fi

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
