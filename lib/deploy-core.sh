#!/bin/bash
# lib/deploy-core.sh — the deploy core, shared by the hub and the host.
#
# WHY IT EXISTS. Until 2026-08-18 the provenance gate, the home list and the
# stage builder lived inside the hub's `deploy` subcommand. Once a host had to
# be able to roll out to its OWN homes there were two ways: clone the code, or
# share it. The estate already had four copies of its bus client in production,
# and one of them (a session owner's relay receiver, md5 ccdc803c against the
# repo's e1705b61) was the receiving end for five live sessions — so we knew
# what cloning costs. What multiplies must be the CHECKOUT, never the content.
#
# The core therefore carries none of the transport's concerns: no ssh, no scp,
# no hashing (the hub never computes a hash, because whoever computes it can
# also lie about the result). It measures provenance against ORIGIN, never
# against the hub, and that is what makes the host path equivalent.
#
# The functions return; they never exit. This file is sourced by a calling
# shell (the hub's CLI, linux/deploy-self.sh, or a test) and must not kill that
# process. The caller owns the exit code.

# ── PROVENANCE GATE ────────────────────────────────────────────────
# A deploy requires the checkout to BE origin/main, not merely to contain it.
# Weaker checks (an is-ancestor test in one direction only) let an unpushed
# commit or a stale checkout through.
#
# THE GATE READS ORIGIN, IT DOES NOT WRITE TO THE CHECKOUT.
#
# This used to open with `git fetch -q origin`, and fetch WRITES: it creates
# .git/FETCH_HEAD and updates the remote-tracking refs. A checkout that is
# readable but not writable therefore failed the gate for a reason that had
# nothing to do with provenance. MEASURED 2026-08-19, one product checkout
# shared read-only between two tenants on one machine (root:root, a+rX):
#
#   git fetch origin      ->  error: cannot open '.git/FETCH_HEAD': Permission
#                             denied                                  (rc 255)
#   git ls-remote origin main ->  rc 0, prints origin/main's sha
#
# And the message the gate printed was "Is the remote reachable?" — the remote
# was perfectly reachable; the local directory was not writable. TWO CAUSES
# SHARING ONE MESSAGE sends whoever is debugging off to check DNS and firewalls
# for a permissions problem. The same fault class this file's caller already
# carries a scar for, in its rc-1 branch.
#
# ls-remote answers exactly the question the gate asks — what is origin/main's
# sha right now — and asks nothing of the local directory but the right to read
# it. The sha is then compared against HEAD directly rather than against the
# remote-tracking ref, because there no longer IS an updated tracking ref: not
# writing is the whole point.
#
# WHAT THIS GIVES UP, stated rather than discovered later: after a successful
# gate the checkout's origin/main ref is NOT updated, so a later `git status`
# may still describe the branch as behind. That is a cosmetic staleness in a
# tool the deploy does not consult. What the deploy consults is the comparison
# below, and that one now uses a value fetched fresh from the remote every run.
deploy_check_provenance() {
  local REPO="$1"
  local _remote_sha
  if ! _remote_sha="$(git -C "$REPO" ls-remote origin main 2>/dev/null | awk 'NR==1{print $1}')" \
     || [ -z "$_remote_sha" ]; then
    echo "GATE FAILED: cannot read main from origin — a deploy requires known provenance." >&2
    echo "Check: git -C $REPO ls-remote origin main" >&2
    echo "  Is the remote reachable, and does it have a branch named main?" >&2
    return 65
  fi
  local _branch
  _branch="$(git -C "$REPO" symbolic-ref --short HEAD 2>/dev/null)"
  if [ "$_branch" != "main" ]; then
    echo "GATE FAILED: the checkout is on branch '$_branch', not main." >&2
    echo "Deploy requires main. Run: git -C $REPO checkout main" >&2
    return 65
  fi
  # EVERY COMPARISON BELOW USES $_remote_sha, NEVER THE origin/main REF. The ref
  # is a local cache that only `fetch` refreshes, and this gate deliberately does
  # not fetch — so consulting it would compare HEAD against whatever the last
  # fetch happened to leave behind, possibly days old. A gate that reads a stale
  # cache and reports it as provenance is worse than no gate: it is confident.
  local _head
  _head="$(git -C "$REPO" rev-parse HEAD)"
  if [ "$_head" = "$_remote_sha" ]; then
    : # exactly HEAD == origin's main — provenance is known
  else
    # THE REMOTE'S COMMIT MAY NOT EXIST HERE AT ALL. Without a fetch, a checkout
    # that is behind has never seen the newer commit, and `merge-base
    # --is-ancestor` against an unknown object fails — which would fall through
    # to "DIVERGED" and send the reader off to sort out a relationship that is
    # simply "run pull". The existence check separates the two.
    if ! git -C "$REPO" cat-file -e "${_remote_sha}^{commit}" 2>/dev/null; then
      echo "GATE FAILED: the checkout is BEHIND origin/main — its commit ${_remote_sha} is not in this checkout." >&2
      echo "Run: git -C $REPO pull --ff-only" >&2
    elif git -C "$REPO" merge-base --is-ancestor "$_head" "$_remote_sha" 2>/dev/null; then
      echo "GATE FAILED: the checkout is BEHIND origin/main." >&2
      echo "Run: git -C $REPO pull --ff-only" >&2
    elif git -C "$REPO" merge-base --is-ancestor "$_remote_sha" "$_head" 2>/dev/null; then
      echo "GATE FAILED: the checkout is AHEAD of origin/main (an unpushed commit)." >&2
      echo "Run: git -C $REPO push origin main" >&2
    else
      echo "GATE FAILED: the checkout has DIVERGED from origin/main." >&2
      echo "Sort out the relationship to origin by hand before deploying." >&2
    fi
    return 65
  fi
  DEPLOY_SHA="$_head"
  return 0
}

# ── THE PRODUCT'S MANIFEST PLUS THE ESTATE'S ───────────────────────
# deploy_manifest_compose <product-manifest> <estate-manifest|""> — writes a
# composed manifest to a temporary file and echoes its path.
#
# WHY TWO FILES. The product carries the mechanism's rows. An estate's manifest
# rows point at files that describe THAT estate — its own documents, its own
# instance. A stranger who clones the product must not inherit rows for
# documents they do not have.
#
# WHY COMPOSE RATHER THAN READ BOTH EVERYWHERE. Everything downstream — the
# source list, the stage, apply, the loneliness sweep, the retirement of
# dropped rows — works against ONE manifest and against the SET of all targets.
# Two manifests read separately would give the sweep half a picture: a file
# present in the estate's manifest but not the product's would look like a lone
# candidate. The union is therefore built once, here, and the rest of the chain
# is untouched.
#
# LOUD IN BOTH DIRECTIONS. The line below is always printed: how many rows each
# manifest contributed, and when the estate's is absent, that it is absent. A
# silent composition would make "the estate manifest vanished" indistinguishable
# from "the estate has no rows" — and that difference decides whether a set of
# documents quietly stops being deployed.
#
# The estate's file is OPTIONAL: a stranger has no estate, and that is a valid
# state, not an error. But if a path is GIVEN and the file is missing, that is a
# configuration error (78) — the estate claimed to have rows and cannot show
# them.
deploy_manifest_compose() {
  local PROD="$1" ESTATE_MF="${2:-}"
  if [ ! -f "$PROD" ]; then
    echo "GATE FAILED: product manifest missing: $PROD" >&2
    return 65
  fi
  local n_prod n_estate=0 OUT
  n_prod="$(grep -v '^#' "$PROD" | awk 'NF>=4' | wc -l | tr -d ' ')"
  OUT="$(mktemp)" || { echo "deploy: cannot create composed manifest" >&2; return 70; }
  cat "$PROD" > "$OUT"
  if [ -n "$ESTATE_MF" ]; then
    if [ ! -f "$ESTATE_MF" ]; then
      echo "GATE FAILED: estate manifest given but missing: $ESTATE_MF" >&2
      rm -f "$OUT"; return 78
    fi
    printf '\n' >> "$OUT"
    cat "$ESTATE_MF" >> "$OUT"
    n_estate="$(grep -v '^#' "$ESTATE_MF" | awk 'NF>=4' | wc -l | tr -d ' ')"
    echo "MANIFEST product=$n_prod estate=$n_estate ($ESTATE_MF)" >&2
  else
    echo "MANIFEST product=$n_prod estate=NONE (no estate file given — mechanism rows only)" >&2
  fi
  # UNIQUENESS APPLIES TO THE UNION. Two manifests that are each valid on their
  # own can together point two sources at the same target, and then row order
  # silently decides which one wins. The format guard sees one file at a time;
  # this sees both.
  local dupes
  dupes="$(grep -v '^#' "$OUT" | awk 'NF>=4 {print $2}' | sort | uniq -d)"
  if [ -n "$dupes" ]; then
    echo "GATE FAILED: same target in both manifests: $(printf '%s' "$dupes" | tr '\n' ' ')" >&2
    rm -f "$OUT"; return 78
  fi
  echo "$OUT"
}

# ── MANIFEST SOURCES ───────────────────────────────────────────────
# The source column (field 1) of a manifest, one per line. The caller uses the
# list both to check for uncommitted changes against its checkout and to build
# the stage — which keeps the core ignorant of which repo instance the sources
# should be checked against.
deploy_manifest_sources() {
  local MANIFEST="$1"
  if [ ! -f "$MANIFEST" ]; then
    echo "GATE FAILED: manifest missing: $MANIFEST" >&2
    return 65
  fi
  # Explicit return 0: the caller runs with `set -o pipefail`, and grep -v
  # returns 1 when the manifest has not a single non-comment line (only
  # comments, or zero bytes). Without this line the function's return value
  # becomes the last pipeline element's rc, and an empty-but-valid manifest
  # looks like a failure — the deploy would abort with rc 1 and no diagnosis at
  # all, long before the same-machine check and the home list had run.
  grep -v '^#' "$MANIFEST" | awk 'NF>=4 {print $1}' | sort -u
  return 0
}

# ── UNCOMMITTED CHANGES IN THE MANIFEST'S SOURCES ──────────────────
# Takes the REPO as its own argument (deploy_manifest_sources does not — it
# knows only the manifest) so it can be measured against the GIT CHECKOUT that
# is actually being deployed. This must live in the core, not only in the hub:
# the host's entry point shares the same gate, otherwise only ONE of the two
# paths guards against deploying uncommitted content — and a gate present in
# one path and missing in the other is exactly the asymmetry the core exists to
# prevent.
deploy_sources_clean() {
  local REPO="$1"
  shift
  # AN EMPTY SOURCE LIST MEANS NOTHING TO CHECK. The guard belongs HERE, not in
  # every caller — `git status --porcelain --` without path arguments is a
  # whole-tree check, and a guard every caller must remember to set is exactly
  # the kind of mistake that left this gate out of the core to begin with (see
  # the file header). An unrelated dirty working tree must never fail a deploy
  # that has no sources to check.
  [ "$#" -eq 0 ] && return 0
  # EVERY SOURCE IS MEASURED AGAINST ITS OWN REPO. With two roots, a whole-tree
  # question against one of them is blind to the other — the gate would have
  # guarded the mechanism and let the estate's files through uncommitted, or
  # the reverse. A gate that measures a subset of what is deployed does not
  # guard the deploy.
  local REPO2="${DEPLOY_STAGE_REPO2:-}"
  local _own="" _other="" _k
  for _k in "$@"; do
    # [ -e ], NOT [ -f ]: a registry row's source is a DIRECTORY
    # (entities.d, projects.d), and [ -f ] is false for one — so a directory
    # source fell out of BOTH lists, silently, and never reached
    # `git status`. `git status --porcelain -- <dir>` already reports a dirty
    # directory correctly; the check above it was just never letting one
    # through.
    if [ -e "$REPO/$_k" ]; then _own="$_own $_k"
    elif [ -n "$REPO2" ] && [ -e "$REPO2/$_k" ]; then _other="$_other $_k"
    fi
  done
  local _dirty=""
  [ -n "$_own" ] && _dirty="$(git -C "$REPO" status --porcelain -- $_own 2>/dev/null)"
  if [ -n "$_other" ]; then
    local _d2; _d2="$(git -C "$REPO2" status --porcelain -- $_other 2>/dev/null)"
    [ -n "$_d2" ] && _dirty="$_dirty${_dirty:+
}$_d2"
  fi
  if [ -n "$_dirty" ]; then
    echo "GATE FAILED: the manifest's sources have uncommitted changes:" >&2
    echo "$_dirty" >&2
    return 65
  fi
  return 0
}

# ── HOME LIST FROM THE REGISTRY ────────────────────────────────────
deploy_home_list() {
  local RD="$1" HOST="$2"
  local HOMES=""
  local _f _h _o _home
  for _f in "$RD"/*.conf; do
    [ -e "$_f" ] || continue
    _h="$(sed -n 's/^HOST="\(.*\)"/\1/p' "$_f" | head -1)"
    [ "$_h" = "$HOST" ] || continue
    _o="$(sed -n 's/^OWNER="\(.*\)"/\1/p' "$_f" | head -1)"
    [ -n "$_o" ] || continue
    _home="/home/$_o"
    case " $HOMES " in
      *" $_home "*) ;;
      *) HOMES="$HOMES $_home" ;;
    esac
  done
  HOMES="${HOMES# }"
  if [ -z "$HOMES" ]; then
    echo "unknown host: no session in the registry has HOST=\"$HOST\" ($RD)" >&2
    return 78
  fi
  echo "$HOMES"
}

# ── STAGE ──────────────────────────────────────────────────────────
# A PREDICTABLE NAME IS A ROOT VULNERABILITY: the stage is executed as root, so
# a name a local user could pre-create or symlink is an invitation. mktemp -d
# gives a name nobody could predict or pre-create.
#
# TWO ROOTS SINCE 2026-08-19. The manifest's source column is relative to ONE
# repo, but once product and estate are separate the sources live in two: the
# mechanism's files in the product, the estate's documents in the estate. The
# first live run out of the product died on the first estate row — "cp: cannot
# stat .../docs/...". The boundary only became visible once it was actually
# crossed; composition solved the ROWS and said nothing about where a source
# lives.
#
# Lookup is product first, then estate. This is NOT a guess but unambiguous by
# construction: the double-life guard forbids the same repo-relative path from
# existing in both trees, so at most one tree can answer. If that guarantee
# falls, this ordering falls with it — which is why the guard and this function
# belong together, and why the dependency is written here and not only in the
# guard's own file.
#
# If the file is missing from BOTH, that is an error, and the error names both
# roots: a source nobody owns is either a misspelled manifest row or a file
# that moved without the manifest following it.
deploy_stage() {
  local REPO="$1" MANIFEST="$2" APPLY="$3"
  local REPO2="${DEPLOY_STAGE_REPO2:-}"
  shift 3
  local STAGE
  STAGE="$(mktemp -d)" || { echo "deploy: cannot create stage directory" >&2; return 70; }
  mkdir -p "$STAGE/src"
  # BOTH cp calls below must be checked, exactly as the source copy is: an
  # unchecked cp that fails leaves a stage WITHOUT a manifest or WITHOUT the
  # apply script but with rc 0 — deploy_stage reports success, and running the
  # stage gives rc 127 (file not found). The caller maps 127 to "sudo -n denied
  # or missing" — so the wrong machine takes the blame for a file error.
  cp "$MANIFEST" "$STAGE/deploy-manifest" || { echo "deploy: cannot copy manifest to $STAGE/deploy-manifest" >&2; rm -rf "$STAGE"; return 70; }
  local _k
  for _k in "$@"; do
    mkdir -p "$STAGE/src/$(dirname "$_k")"
    # A DIRECTORY SOURCE IS A REGISTRY ROW. Only *.conf travels: the register
    # reads that glob, and a backup or a swapfile beside a conf is not registry
    # data. An EMPTY directory is a valid state — an estate may declare a
    # register it has not populated — so the directory is created either way,
    # which is also what lets the applier prune a host that still holds confs.
    local _dsrc=""
    if [ -d "$REPO/$_k" ]; then _dsrc="$REPO/$_k"
    elif [ -n "$REPO2" ] && [ -d "$REPO2/$_k" ]; then _dsrc="$REPO2/$_k"; fi
    if [ -n "$_dsrc" ]; then
      mkdir -p "$STAGE/src/$_k" || { echo "deploy: cannot create stage dir for $_k" >&2; rm -rf "$STAGE"; return 70; }
      local _c
      for _c in "$_dsrc"/*.conf; do
        [ -f "$_c" ] || continue          # the glob is literal when nothing matches
        cp "$_c" "$STAGE/src/$_k/" || { echo "deploy: cannot copy $_c" >&2; rm -rf "$STAGE"; return 70; }
      done
      continue
    fi
    local _src=""
    if [ -f "$REPO/$_k" ]; then _src="$REPO/$_k"
    elif [ -n "$REPO2" ] && [ -f "$REPO2/$_k" ]; then _src="$REPO2/$_k"
    else
      echo "deploy: source $_k exists in neither $REPO${REPO2:+ nor $REPO2}" >&2
      rm -rf "$STAGE"; return 70
    fi
    cp "$_src" "$STAGE/src/$_k" || { echo "deploy: cannot copy source $_k" >&2; rm -rf "$STAGE"; return 70; }
  done
  cp "$APPLY" "$STAGE/deploy-apply.sh" || { echo "deploy: cannot copy apply to $STAGE/deploy-apply.sh" >&2; rm -rf "$STAGE"; return 70; }
  echo "$STAGE"
}
