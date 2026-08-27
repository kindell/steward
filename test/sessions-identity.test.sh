#!/bin/bash
# test/sessions-identity.test.sh — the identity layer: who is this session?
#
# IDENTITY IS THE FREE LAYER. It is a local file read: no network, no host, no
# subprocess that can hang. That is why it is separated from liveness, which is
# none of those things — mixing a safe read with an unsafe one in the same
# function makes the safe one inherit the unsafe one's failure modes.
#
# HERMETIC. A fixture registry, never the real one. The claims here are about
# the shape of a row, not about any particular estate's sessions.
set -u

here="$(CDPATH= cd -- "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
pass=0; fail=0
ok()  { pass=$((pass+1)); printf '  ok   %s\n' "$1"; }
bad() { fail=$((fail+1)); printf '  FAIL %s\n     %s\n' "$1" "${2:-}"; }
is()  { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "wanted '$3', got '$2'"; fi; }

FX="$(mktemp -d)"; trap 'rm -rf "$FX"' EXIT
mkdir -p "$FX/sessions.d" "$FX/entities.d" "$FX/estate"

# registry_load REFUSES without an estate file — LABEL_PREFIX, HUB_HOST and
# OP_TOKEN_FILE_NAME are read unconditionally, not just when a conf omits the
# field they default. A fixture that skips this file is not "no estate
# configured", it is every session in it failing to load with rc 78 — a
# different bug than the one this suite exists to test.
printf 'LABEL_PREFIX="com.fixture.claude"\nHUB_HOST="h1"\nOP_TOKEN_FILE_NAME="fixture-token"\n' \
  > "$FX/estate/steward.conf"

printf 'HOST="h1"\nOWNER="alice"\nDOMAIN="acme"\nRC_LABEL="L"\nREPO_PATH="/tmp/x"\nID="full"\nASSETS="widget other:thing"\n' \
  > "$FX/sessions.d/full.conf"
printf 'HOST="h1"\nOWNER="bob"\nDOMAIN="team-one"\nRC_LABEL="L"\nREPO_PATH="/tmp/x"\nID="bare"\n' \
  > "$FX/sessions.d/bare.conf"

# TWO ENTITY RELATIONS, NOT ONE. MEMBERS names the people who work FOR an
# entity; MANAGED_BY names the entity this one is a client of. They are
# different facts and a row that flattened them would lose the distinction the
# registry deliberately makes.
printf 'NAME="Acme"\nMANAGED_BY="team-one"\n' > "$FX/entities.d/acme.conf"
printf 'NAME="Team One"\nMEMBERS="alice bob"\n' > "$FX/entities.d/team-one.conf"

export STEWARD_REGISTRY_DIR="$FX/sessions.d"
export STEWARD_ESTATE_ROOT="$FX"
# shellcheck source=/dev/null
. "$here/lib/sessions.sh"

field() { printf '%s\n' "$1" | awk -F'\t' -v r="$2" -v c="$3" '$1==r{print $c}'; }

echo "== a row carries every identity field =="
out="$(session_identity_rows)"; rc=$?
is "rc 0" "$rc" "0"
is "two sessions, two rows" "$(printf '%s\n' "$out" | grep -c .)" "2"
is "name"            "$(field "$out" full 1)" "full"
is "id"              "$(field "$out" full 2)" "full"
is "owner"           "$(field "$out" full 3)" "alice"
is "domain"          "$(field "$out" full 4)" "acme"
is "host"            "$(field "$out" full 5)" "h1"
is "entity name"     "$(field "$out" full 6)" "Acme"
is "entity relation" "$(field "$out" full 7)" "client"
is "assets"          "$(field "$out" full 8)" "widget other:thing"

echo "== the other relation is read as itself =="
is "a team entity says team" "$(field "$out" bare 7)" "team"
is "and names itself"        "$(field "$out" bare 6)" "Team One"

# AN EMPTY FIELD IS A DASH, NOT AN EMPTY COLUMN. A row whose columns shift
# because one was blank is a row every consumer parses wrong, and the consumer
# here is a cockpit that would render the shift as data.
echo "== nothing declared is a dash, never a blank column =="
is "no assets is a dash" "$(field "$out" bare 8)" "-"
is "the row still has eight fields" \
   "$(printf '%s\n' "$out" | awk -F'\t' '$1=="bare"{print NF}')" "8"

# AN UNKNOWN ENTITY IS NOT AN ERROR. A session may name a domain no entity file
# describes yet; that is a gap in the registry, not a failure of this read.
echo "== a domain with no entity file still yields a row =="
printf 'HOST="h1"\nOWNER="carol"\nDOMAIN="nosuch"\nRC_LABEL="L"\nREPO_PATH="/tmp/x"\nID="orphan"\n' \
  > "$FX/sessions.d/orphan.conf"
out2="$(session_identity_rows)"
is "the orphan is listed"        "$(field "$out2" orphan 1)" "orphan"
is "its entity name is a dash"   "$(field "$out2" orphan 6)" "-"
is "its relation is a dash"      "$(field "$out2" orphan 7)" "-"

# AN UNREADABLE REGISTRY MUST REFUSE. Empty output from a missing directory is
# indistinguishable from an estate with no sessions.
echo "== an unreadable registry refuses, never prints empty =="
out3="$(STEWARD_REGISTRY_DIR="$FX/does-not-exist" session_identity_rows 2>/dev/null)"; rc3=$?
is "rc is non-zero" "$( [ "$rc3" -ne 0 ] && echo yes || echo no )" "yes"
is "and nothing was printed" "$out3" ""

echo
printf 'pass=%s fail=%s\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
