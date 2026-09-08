#!/bin/bash
# linux/deploy-self.sh <host> [--accept-drift <home> --file <target>]… — a
# host's own rollout to its OWN homes, from its OWN checkout.
#
# WHY IT EXISTS. Originally the product was installed FROM the hub INTO other
# machines: the hub built the stage and scp'd it. The consequence was that a
# fleet could be made independent in operation and still fetch its code from
# the hub — independent in operation, dependent for updates.
#
# But the hub was never the source of truth: the provenance gate measures
# against ORIGIN (fetch, HEAD == origin/main, branch main, clean sources). The
# hub was merely the machine that happened to run the command. If the host runs
# the same gate against the same origin, the rollout is equivalent — and the
# hub leaves the update path.
#
# THE MACHINE IS CHECKED FIRST, before anything that acts. An entry point that
# can aim at somebody else's host would be the hub again, minus the hub's
# gates. The registry lookup (which homes belong to <host>) is a READ, not an
# action — it may run before the machine check so that an unknown host reports
# 78 (configuration) rather than being mistaken for 65 (wrong machine, a
# refusal). But NO gate that actually DOES something (provenance, source
# cleanliness, stage, sudo) may run before `hostname -s` is confirmed to be
# this very host.
#
# NO MANIFEST ROW FOR THIS FILE. The tool that updates a host lives in the
# CHECKOUT, not in the image it writes — otherwise it updates itself in the
# middle of its own run.
set -uo pipefail

# ${BASH_SOURCE[0]} is the SYMLINK's path, not the target's, when the script is
# reached through a link (`ln -s .../linux/deploy-self.sh ~/bin/deploy-self` —
# the natural PATH installation). No `readlink -f` — it does not exist on the
# bash 3.2 baseline this code also runs on — so the link is resolved by hand.
# Without this, a symlinked run reports "deploy-core.sh: No such file or
# directory" followed by "deploy_home_list: command not found" — rc 127,
# untranslated, and the blame lands in the wrong place.
_self="${BASH_SOURCE[0]}"
while [ -L "$_self" ]; do
  _link="$(readlink "$_self")"
  case "$_link" in
    /*) _self="$_link" ;;
    *)  _self="$(dirname "$_self")/$_link" ;;
  esac
done
_linuxdir="$(CDPATH= cd -- "$(dirname "$_self")" && pwd)"
PRODUCT="$(CDPATH= cd -- "$_linuxdir/.." && pwd)"
. "$PRODUCT/lib/deploy-core.sh" || {
  echo "REFUSED: could not read the core: $PRODUCT/lib/deploy-core.sh" >&2
  exit 70
}

HOST_ARG="${1:-}"
if [ -z "$HOST_ARG" ]; then
  echo "Usage: bash <checkout>/linux/deploy-self.sh <host> [--accept-drift <home> --file <target>]…" >&2
  exit 64
fi
shift

# ── THE ESTATE ─────────────────────────────────────────────────────────────
# The product knows the mechanism; the ESTATE owns the registry, the homes and
# its own manifest rows. deploy-self.sh lives in the product's checkout, so it
# can no longer assume the registry sits in its own root.
#
# ORDER: STEWARD_ESTATE, then ~/.config/steward/config. NO CONVENTION, NO
# SILENT FALLBACK — if the estate is missing the tool refuses with rc 78 and
# says what is missing. The reason is a scar of our own: a silent fallback of
# the form ${DOMAIN:-$NAME} once gave a session a private credential directory
# instead of the domain's shared one, and everything looked healthy for two
# days. A tool that guesses where the estate lives makes the same mistake for
# strangers — against their homes.
ESTATE="${STEWARD_ESTATE:-}"
if [ -z "$ESTATE" ] && [ -f "$HOME/.config/steward/config" ]; then
  ESTATE="$(grep -m1 '^ESTATE=' "$HOME/.config/steward/config" 2>/dev/null | cut -d= -f2- | tr -d '"'"'"'')"
fi
if [ -z "$ESTATE" ]; then
  echo "REFUSED: no estate is designated. The product knows where the mechanism lives, never where YOU live." >&2
  echo "  set STEWARD_ESTATE=<path to your estate checkout>" >&2
  echo "  or put ESTATE=<path> in ~/.config/steward/config" >&2
  exit 78
fi
if [ ! -d "$ESTATE" ]; then
  echo "REFUSED: estate designated but does not exist: $ESTATE" >&2
  exit 78
fi
# CANONICAL, ONCE, FOR EVERY LATER CALLER THAT NEEDS TO HAND THE ESTATE TO A
# CHILD PROCESS THROUGH THE ENVIRONMENT (step 7 below, and the desk drop-in).
# $ESTATE may carry a relative path or a trailing "..", and a value burned
# into a child's environment or a unit file outlives this run - it has to be
# the real directory, not a description of how to get there from here.
ESTATE_ROOT="$(CDPATH= cd -- "$ESTATE" && pwd)" || {
  echo "REFUSED: could not resolve the estate to a real directory: $ESTATE" >&2
  exit 78
}


# ── 1. HOME LIST FROM THE REGISTRY (a read, not an action) ───────────
RD="${STEWARD_REGISTRY_DIR:-$ESTATE/sessions.d}"
HOMES="$(deploy_home_list "$RD" "$HOST_ARG")" || exit $?
echo "HOMES $HOST_ARG: $HOMES (source: $RD)"

# ── 2. THE MACHINE CHECK — FIRST AMONG THE THINGS THAT ACT ───────────
ME="${STEWARD_DEPLOY_HOSTNAME:-$(hostname -s)}"
if [ "$HOST_ARG" != "$ME" ]; then
  echo "REFUSED: '$HOST_ARG' is not this machine ($ME)." >&2
  echo "deploy-self only rolls out to its OWN host. For another host, deploy" >&2
  echo "from the hub instead." >&2
  exit 65
fi

# ── 3. THE PROVENANCE GATE ───────────────────────────────────────────
deploy_check_provenance "$PRODUCT" || exit $?
PRODUCT_SHA="$DEPLOY_SHA"
# BOTH TREES ARE PROVENANCE-GATED. The deploy carries files from the product
# AND from the estate; a gate that only measures the product would let through
# an estate that is behind origin, has diverged, or sits on the wrong branch —
# and the estate's rows can be half the manifest. Half the rollout ungated is
# not half a gate; it is none.
deploy_check_provenance "$ESTATE" || exit $?
ESTATE_SHA="$DEPLOY_SHA"

# TWO TREES, TWO SHAS, AND THE RECEIPT ONLY HAS ROOM FOR ONE.
#
# deploy_check_provenance sets the global DEPLOY_SHA, so the second call
# silently overwrote the first: the `DEPLOY sha=…` receipt — the one line that
# says WHAT was rolled out — carried the ESTATE's sha while claiming to identify
# the deploy. MEASURED 2026-08-19: two estates on one machine, cloned from the
# SAME product (8c9d7d9), produced receipts reading 5df2acb and c97e427 — their
# own estate shas. The product's sha appeared nowhere in the log.
#
# The line was correct until the day the trees were split: one tree, one sha, no
# ambiguity. The split changed the field's MEANING without changing its FORM,
# which is why nothing failed and nobody noticed. The estate's catalogue calls
# that "a state name is a contract with the past".
#
# `sha=` therefore keeps its original meaning — the MECHANISM's version — and
# the estate's is printed here, beside it, rather than smuggled into the same
# field. Deliberately NOT a third positional argument to deploy-apply.sh:
# apply's argument list is an interface two repos depend on, and renaming a
# sentinel across that boundary has already broken this estate's fixtures once.
DEPLOY_SHA="$PRODUCT_SHA"
echo "PROVENANCE product=$PRODUCT_SHA estate=$ESTATE_SHA"

# ── 4. MANIFEST SOURCES + THE CLEANLINESS GATE ───────────────────────
# The same gate the hub runs (deploy_sources_clean) — shared core, shared gate.
# A gate present in the hub path and missing in the host path would be exactly
# the asymmetry lib/deploy-core.sh exists to prevent.
#
# The second root: the estate's sources. Lookup is product first, then estate —
# unambiguous because the double-life guard forbids a file from living in both.
# A missing estate manifest is valid (a stranger has no estate) — the
# composition prints which case applied.
export DEPLOY_STAGE_REPO2="$ESTATE"
ESTATE_MANIFEST=""; [ -f "$ESTATE/estate/deploy-manifest" ] && ESTATE_MANIFEST="$ESTATE/estate/deploy-manifest"
MANIFEST="$(deploy_manifest_compose "$PRODUCT/linux/deploy-manifest" "$ESTATE_MANIFEST")" || exit $?
SOURCES="$(deploy_manifest_sources "$MANIFEST")" || exit $?
deploy_sources_clean "$PRODUCT" $SOURCES || exit $?

# ── 5. STAGE — always built with mktemp -d (see deploy_stage in the core):
# a predictable name in a shared directory is a root vulnerability. The stage
# is executed as root, and a local user who can pre-create or symlink the
# directory gets their own apply script run as root.
STAGE="$(deploy_stage "$PRODUCT" "$MANIFEST" "$PRODUCT/linux/deploy-apply.sh" $SOURCES)" || exit $?
trap 'rm -rf "$STAGE"' EXIT

# ── 6. EXECUTE — locally, no ssh/scp: sudo -n runs apply on this machine ──
sudo -n bash "$STAGE/deploy-apply.sh" "$STAGE" "$DEPLOY_SHA" "$@" $HOMES
rc=$?
# TWO CAUSES MUST NOT SHARE ONE MESSAGE — but rc 1 is AMBIGUOUS in a way
# rc 127 is not. deploy-apply.sh runs `set -uo pipefail` WITHOUT `-e`: an
# unbound variable anywhere in its ~400 lines exits 1, exactly like a denied
# `sudo -n`. (An earlier version of this comment claimed apply "cannot"
# produce 1 or 127 — it can, if it crashes on a fault of its own, because it
# lacks -e.) Printing only "sudo denied" over an apply bug sends the debugger
# off to write a sudoers rule for the wrong problem. The message below names
# BOTH possibilities and gives a way to tell them apart: a denied sudo -n
# prints nothing at all above this line; an apply dying on its own fault has
# already printed its OWN lines before aborting.
case "$rc" in
  1)   echo "execution failure (rc 1): either sudo -n was denied, or deploy-apply.sh aborted on a fault of its own (unbound variable — it runs pipefail but not -e)." >&2
       echo "  Tell them apart: a denied sudo prints nothing above this line. If apply printed its own lines before dying, the fault is INSIDE apply, not in sudo." >&2
       rc=70 ;;
  127) echo "execution failure: command not found — either sudo is missing, or the stage carries no deploy-apply.sh ($STAGE/deploy-apply.sh)." >&2; rc=70 ;;
esac

# -- 7. THE DESK UNITS LEARN THE ESTATE THROUGH A DROP-IN, THE WAY ACTIVATION
# BINDS A SESSION --------------------------------------------------------
# MEASURED 2026-09-08, the same round that found step 8 below carrying no
# estate either: steward-desk-snapshot.service runs with no
# STEWARD_ESTATE_ROOT of its own, so its registry root defaulted to whatever
# ~/scripts happened to resolve to on the account that ran it. Fixed by hand
# on that host with a drop-in of this exact shape, then removed here so the
# next deploy does not have to be told twice.
#
# THE DEPLOY WRITES IT, NOT ACTIVATION AND NOT THE UNIT TEMPLATE. Activation
# (linux/session-new.sh, `_dropdir=...50-estate.conf` above) writes a
# PER-INSTANCE drop-in because a session's estate is a fact only activation
# knows, at the moment a new instance is born. The desk units carry no
# instance - there is one desk per account, not one per session - so there
# is no activation-shaped moment for them; the deploy is what plays that
# role instead, because the deploy already knows the estate (it just
# provenance-gated it, above) and runs on every host that has a checkout,
# whether or not that account has ever turned the desk on. A value baked
# into the unit template itself would work for one estate per account and
# break the day a second one lands on the same machine - the same reason
# activation writes a drop-in rather than editing its template.
#
# EVERY DEPLOY, DESK OR NO DESK - unlike step 8 below, this does not wait
# for a desk directory to exist. Every home on every host gets the desk's
# unit files regardless of whether that account has enabled them (see
# desk/SCHEMA.md), so the environment they would read is written the same
# way: on every deploy, so the day the account turns the desk on the units
# are already correctly wired.
#
# ONLY $HOME, NEVER ANOTHER ACCOUNT'S OWN. This account's own systemd user
# manager reads only its own config; deploy-self.sh runs once per invoking
# account, and writing into a different home's config here would be the
# skeleton acting on a home nobody asked it to touch. (Projecting this
# through the register to every home on the host is a later design, not
# this change.)
#
# TMP THEN MOVE, so a reader mid-write never sees a torn file - and the two
# lines written are byte-identical to what session-new.sh writes for a
# session, because both express the same fact for the same variable.
_desk_dropdir_base="${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user"
for _desk_unit in steward-desk.service steward-desk-snapshot.service; do
  _dd="$_desk_dropdir_base/$_desk_unit.d"
  _dst="$_dd/50-estate.conf"
  mkdir -p "$_dd" \
    && _tmp="$_dd/.50-estate.conf.$$" \
    && printf '[Service]\nEnvironment=STEWARD_ESTATE_ROOT=%s\n' "$ESTATE_ROOT" > "$_tmp" \
    && mv -f "$_tmp" "$_dst"
  if [ $? -ne 0 ]; then
    rm -f "$_dd/.50-estate.conf.$$"
    echo "deploy-self: could not write the desk drop-in: $_dst" >&2
    rc=70
  fi
done
if command -v systemctl >/dev/null 2>&1; then
  systemctl --user daemon-reload
  _reload_rc=$?
  if [ "$_reload_rc" -ne 0 ]; then
    echo "deploy-self: the desk drop-in was written but systemd did not reload (rc $_reload_rc) - the desk units keep their old environment until 'systemctl --user daemon-reload'" >&2
    rc=70
  fi
else
  echo "deploy-self: the desk drop-in was written; no user systemd manager is present on this host"
fi

# --- 8. THE DESK: REGENERATED HERE, BECAUSE THE DEPLOY IS THE REVOCATION ---
# The desk hands each person a file that was FILTERED WHEN IT WAS WRITTEN, so
# what a person may see is decided by the last snapshot and by nothing at
# request time. A rollout that removes somebody's row, or moves a session out
# of their reach, therefore changes nothing at all until a new generation is
# written: the old one keeps answering, correctly, about an estate that is no
# longer there. The refresh timer would get to it within five minutes. Five
# minutes is the wrong latency for a withdrawal, and it is the deploy - not the
# timer - that knows a withdrawal just happened.
#
# ONLY AFTER AN APPLY THAT WORKED. A failed apply leaves the homes in a state
# nobody has measured, and a desk regenerated from that describes an estate
# that exists on no machine.
#
# ITS FAILURE IS NOT A DETAIL. The files landed, so this is not a refusal - but
# the desk is now serving the PREVIOUS generation while claiming to be current,
# and a green exit code hides that until somebody happens to read a page. Rc 70
# says: the rollout happened, the view of it did not.
#
# ONLY ON A HOST THAT HAS A DESK. Every home on every host gets the desk's
# files and its unit files; only ONE account per host ever enables them, and
# the desk directory comes into being when that account's first enabled round
# runs. So on every other account, and on the hub account before the operator
# has turned the desk on, the directory is simply not there - and a deploy that
# ran the producer anyway would create a desk nobody serves and, worse, could
# fail the whole rollout with rc 70 for a producer fault that has nothing to do
# with what was rolled out. The directory existing is the host saying yes; from
# then on every deploy refreshes it, and a withdrawal lands in seconds.
#
# THE DIRECTORY IS ASKED FOR THE WAY THE PRODUCER ASKS FOR IT: the operator's
# STEWARD_DESK_DIR first, otherwise the product's own desk/bin/desk-paths. The
# product's bridge and not a deployed home's, because it is the product's
# snapshot.sh that the line below runs, and that script resolves the bridge
# beside itself - a check reading any other copy would be answering about a
# directory this run is not going to write.
#
# BOTH CALLS CARRY STEWARD_ESTATE_ROOT="$ESTATE_ROOT" EXPLICITLY. MEASURED
# 2026-09-08 on a two-account host: steward-desk-snapshot.service runs
# desk/snapshot.sh with no STEWARD_ESTATE_ROOT set, so the registry root
# defaulted to ~/scripts - which, on a hub account whose HOME is not the
# estate checkout, holds only that account's own two rows. The desk showed
# two sessions instead of twenty-five. The deploy already knows the estate
# (it provenance-gated it in step 3, above); desk-paths and the snapshot both
# resolve the registry root the same way (lib/registry.sh's
# _registry_estate_root), so both need the same value. NOT exported for the
# whole script: the sudo apply step above must not see it change.
if [ "$rc" -eq 0 ]; then
  desk_dir="${STEWARD_DESK_DIR:-}"
  if [ -z "$desk_dir" ] && [ -x "$PRODUCT/desk/bin/desk-paths" ]; then
    desk_dir="$(STEWARD_ESTATE_ROOT="$ESTATE_ROOT" "$PRODUCT/desk/bin/desk-paths" 2>/dev/null | sed -n 's/^dir=//p')"
  fi
  if [ -n "$desk_dir" ] && [ -d "$desk_dir" ]; then
    # bin/steward is a manifest source now (linux/deploy-manifest), so the
    # cleanliness/provenance gate above already covers the file this line runs.
    STEWARD_ESTATE_ROOT="$ESTATE_ROOT" bash "$PRODUCT/bin/steward" desk snapshot
    snap_rc=$?
    if [ "$snap_rc" -ne 0 ]; then
      echo "deploy-self: desk snapshot failed (rc $snap_rc) - the desk shows the previous generation until the timer runs" >&2
      rc=70
    fi
  elif [ -n "$desk_dir" ]; then
    echo "deploy-self: no desk on this host (no $desk_dir) - snapshot skipped"
  else
    echo "deploy-self: no desk on this host (the desk directory could not be resolved) - snapshot skipped"
  fi
fi
exit "$rc"
