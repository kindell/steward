#!/bin/bash
# test/hub-per-host.test.sh — the hub address is PER HOST, not per estate.
#
# WHY THIS EXISTS. `estate/steward.conf` is ONE file for a whole estate, and the
# deploy puts the same copy in every home — measured 2026-09-05: line 74 of
# `~/scripts/estate/steward.conf` is identical in all nineteen homes on
# basement. It carries HUB_SESSION / HUB_HOST / HUB_SSH, and nine consumers in
# the product read them: the bus relay's target, three alarm senders, what
# estate-status and liveness call "here", the hub library, and install.sh.
#
# A federation of hubs breaks that assumption. Two hubs in one estate means the
# value must depend on the HOST, not on the estate — otherwise every session on
# basement keeps relaying to the machine the hub just left.
#
# THE FALLBACK IS PER KEY, NOT PER FILE, and it is one-directional: a host row
# may override, a missing key falls back to the estate, and a MALFORMED key
# refuses with rc 78 rather than falling back. That last one is the whole point
# of the file — a mistyped relay target must not quietly become the other hub's
# address. A silent fallback there is indistinguishable from success.
#
# ADDITIVE BY CONSTRUCTION: with no HUB_* keys in hosts.d the answers are the
# estate's, byte for byte. That is what lets this land before the cut.
set -u

here="$(CDPATH= cd -- "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
pass=0; fail=0
ok()  { pass=$((pass+1)); printf '  ok   %s\n' "$1"; }
bad() { fail=$((fail+1)); printf '  FAIL %s\n     %s\n' "$1" "${2:-}"; }
is()   { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "wanted '$3', got '$2'"; fi; }
has()  { case "$2" in *"$3"*) ok "$1" ;; *) bad "$1" "missing '$3' in: $2" ;; esac; }

FX="$(mktemp -d)"; trap 'rm -rf "$FX"' EXIT
mkdir -p "$FX/estate" "$FX/hosts.d"

cat > "$FX/estate/steward.conf" <<'EOF'
RC_LABEL_PREFIX="Prov: "
HUB_SESSION="estatehub"
HUB_HOST="estatehub"
HUB_SSH="a@1"
JOB_LOG_DIR="logs"
TMUX_SOCKET="prov"
EOF

# ask <self-host> <function> [extra host conf lines written to hosts.d/x.conf]
# Each call is its own process: the reader must not depend on what a previous
# one left behind in the shell.
ask() { # <self-host> <function>
  env -i PATH="$PATH" HOME="$FX/home" \
      STEWARD_ESTATE="$FX/estate/steward.conf" \
      STEWARD_HOSTS_DIR="$FX/hosts.d" \
      STEWARD_SELF_HOST="$1" \
      bash -c 'source "$0"/lib/registry.sh; '"$2" "$here" 2>&1
}
rc_of() { # <self-host> <function> -> rc
  env -i PATH="$PATH" HOME="$FX/home" \
      STEWARD_ESTATE="$FX/estate/steward.conf" \
      STEWARD_HOSTS_DIR="$FX/hosts.d" \
      STEWARD_SELF_HOST="$1" \
      bash -c 'source "$0"/lib/registry.sh; '"$2" "$here" >/dev/null 2>&1; echo $?
}

echo "1. Additive: no host rows at all — the estate still answers"
is "hub_ssh faller till estaten"     "$(ask x registry_hub_ssh)"     "a@1"
is "hub_session faller till estaten" "$(ask x registry_hub_session)" "estatehub"
is "hub_host faller till estaten"    "$(ask x registry_hub_host)"    "estatehub"

echo
echo "2. The own host's row wins"
cat > "$FX/hosts.d/x.conf" <<'EOF'
OWNER="steward"
LEGAL_OWNER="Prov AB"
OPERATOR="x"
HUB_SESSION="xhub"
HUB_HOST="xhub"
HUB_SSH="b@2"
EOF
is "hub_ssh ur egen värds rad"     "$(ask x registry_hub_ssh)"     "b@2"
is "hub_session ur egen värds rad" "$(ask x registry_hub_session)" "xhub"
is "hub_host ur egen värds rad"    "$(ask x registry_hub_host)"    "xhub"

echo
echo "3. Another host's row is not mine"
is "annan värd ser estatens ssh"     "$(ask y registry_hub_ssh)"     "a@1"
is "annan värd ser estatens session" "$(ask y registry_hub_session)" "estatehub"

echo
echo "4. The fallback is per KEY, not per file"
cat > "$FX/hosts.d/x.conf" <<'EOF'
OWNER="steward"
LEGAL_OWNER="Prov AB"
OPERATOR="x"
HUB_SSH="b@2"
EOF
is "raden utan HUB_SESSION faller till estaten" "$(ask x registry_hub_session)" "estatehub"
is "men HUB_SSH i samma rad gäller"             "$(ask x registry_hub_ssh)"     "b@2"

echo
echo "5. A malformed value REFUSES — it never falls back"
cat > "$FX/hosts.d/x.conf" <<'EOF'
OWNER="steward"
LEGAL_OWNER="Prov AB"
OPERATOR="x"
HUB_SSH="bara-en-vard"
EOF
is  "fel form ger rc 78"                "$(rc_of x registry_hub_ssh)" "78"
has "felet namnger värdfilen"           "$(ask x registry_hub_ssh)"   "x.conf"
has "felet säger vad som förväntades"   "$(ask x registry_hub_ssh)"   "expected the form"
case "$(ask x registry_hub_ssh)" in
  *a@1*) bad "vägran läcker inte estatens värde" "estatens 'a@1' stod i utdatan" ;;
  *)     ok  "vägran läcker inte estatens värde" ;;
esac

cat > "$FX/hosts.d/x.conf" <<'EOF'
OWNER="steward"
LEGAL_OWNER="Prov AB"
OPERATOR="x"
HUB_SESSION="INTE EN SLUG"
EOF
is "fel form på HUB_SESSION ger rc 78" "$(rc_of x registry_hub_session)" "78"

echo
echo "6. An empty key is an absent key, not a refusal"
cat > "$FX/hosts.d/x.conf" <<'EOF'
OWNER="steward"
LEGAL_OWNER="Prov AB"
OPERATOR="x"
HUB_SSH=""
EOF
is "tom nyckel faller till estaten" "$(ask x registry_hub_ssh)" "a@1"

echo
echo "7. The self-host name is used to build a path — it must not traverse"
rm -f "$FX/hosts.d/x.conf"
mkdir -p "$FX/annat"
cat > "$FX/annat/steward.conf" <<'EOF'
HUB_SSH="ondska@3"
EOF
is "punkt-punkt-namn läser ingen fil utanför hosts.d" \
   "$(ask '../annat/steward' registry_hub_ssh)" "a@1"
is "tomt värdnamn faller till estaten" "$(ask '' registry_hub_ssh)" "a@1"

echo
echo "8. STEWARD_SELF_HOST wins over hostname(1) — the same two sources the rest uses"
cat > "$FX/hosts.d/stub.conf" <<'EOF'
OWNER="steward"
LEGAL_OWNER="Prov AB"
OPERATOR="stub"
HUB_SSH="stub@9"
EOF
mkdir -p "$FX/bin"
printf '#!/bin/sh\necho stub\n' > "$FX/bin/hostname"; chmod 755 "$FX/bin/hostname"
out="$(env -i PATH="$FX/bin:$PATH" HOME="$FX/home" \
    STEWARD_ESTATE="$FX/estate/steward.conf" STEWARD_HOSTS_DIR="$FX/hosts.d" \
    bash -c 'source "$0"/lib/registry.sh; registry_hub_ssh' "$here" 2>&1)"
is "utan STEWARD_SELF_HOST används hostname -s" "$out" "stub@9"

echo
printf '%s: %d passed, %d failed\n' "$(basename "$0")" "$pass" "$fail"
[ "$fail" -eq 0 ]
