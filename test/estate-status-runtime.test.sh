#!/bin/bash
# test/estate-status-runtime.test.sh — the status table must say WHICH RUNTIME a
# session runs, and on which model.
#
# WHY THE COLUMNS EXIST. Until now every session in the table was a Claude
# session, so the runtime was implicit and correct by accident. Once a second
# runtime lives on the same machine, a reader cannot tell from the table whether
# a down session is a Claude session that died or an OpenCode session that was
# never dispatched — and those need different repairs. An implicit fact stops
# being true the moment there are two of something.
#
# READ, NEVER SOURCED. The conf is parsed with the same non-executing `sed` the
# host and owner columns already use. A read-only status command must not
# execute estate session files: sourcing them would run whatever they contain,
# on a machine that carries several people's sessions.
#
# THE DEFAULTS ARE PART OF THE CONTRACT. A conf without RUNTIME is a Claude
# session — every existing conf predates the field, and rendering them as "?"
# would make seventeen healthy rows look unknown. A missing MODEL is "-" and not
# empty, because an empty cell in a column-aligned table reads as a rendering
# fault rather than as "this runtime has no model".
set -u
here="$(CDPATH= cd -- "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
pass=0; fail=0
ok()  { pass=$((pass+1)); printf '  ok   %s\n' "$1"; }
bad() { fail=$((fail+1)); printf '  FAIL %s\n     %s\n' "$1" "${2:-}"; }
har()    { case "$2" in *"$3"*) ok "$1" ;; *) bad "$1" "saknade '$3' i:\n$2" ;; esac; }
saknar() { case "$2" in *"$3"*) bad "$1" "hittade oväntat '$3'" ;; *) ok "$1" ;; esac; }

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
mkdir -p "$T/sessions.d" "$T/estate" "$T/bin" "$T/home/.tmux"

cat > "$T/estate/steward.conf" <<'EOF'
LABEL_PREFIX="com.prov.claude"
RC_LABEL_PREFIX="Prov: "
HUB_SESSION="provnav"
HUB_HOST="provvard"
STATE_DIR_NAME="prov-tillsyn"
PAUSED_DIR_NAME="prov-pausad"
JOB_LOG_DIR="prov-jobb"
TMUX_SOCKET="prov.sock"
EOF

# NAMNEN BÄR INTE SVARET. Fixturen hette först claudesess/opencodesess, och då
# passerade "raden bär sin runtime" på att NAMNET innehöll ordet — ett prov som
# mäter sin egen fixtur. Neutrala namn tvingar checken att läsa kolumnen.
# En DEFAULT Claude-conf: ingen RUNTIME-rad alls, som varenda befintlig conf.
cat > "$T/sessions.d/alfa.conf" <<'EOF'
HOST="provvard"
OWNER="provuser"
DOMAIN="prov"
RC_LABEL="Prov Claude"
EOF

# En OpenCode-conf med modell.
cat > "$T/sessions.d/beta.conf" <<'EOF'
HOST="provvard"
OWNER="provuser"
DOMAIN="prov"
RC_LABEL="Prov OpenCode"
RUNTIME="opencode"
MODEL="openai/gpt-5.3-codex"
EOF

# tmux-stubb: bada sessionerna ar uppe. Exaktformen =namn maste bevaras.
cat > "$T/bin/tmux" <<'EOF'
#!/bin/bash
echo "$@" >> "${TMUX_LOGG:?}"
case "$*" in *has-session*) exit 0 ;; esac
exit 0
EOF
chmod +x "$T/bin/tmux"

: > "$T/tmuxlogg"
ut="$( STEWARD_ESTATE_ROOT="$T" STEWARD_REGISTRY_DIR="$T/sessions.d" \
       STEWARD_SELF_HOST="provvard" STEWARD_SELF_USER="provuser" \
       STEWARD_TMUX_BIN="$T/bin/tmux" TMUX_LOGG="$T/tmuxlogg" \
       HOME="$T/home" PATH="$T/bin:$PATH" \
       bash "$here/linux/estate-status.sh" 2>&1 )"; rc=$?

echo "estate-status: runtime och modell"
[ "$rc" -eq 0 ] && ok "kommandot lyckas" || bad "kommandot lyckas" "rc=$rc:\n$ut"

har "rubriken bär RUNTIME"        "$ut" "RUNTIME"
har "rubriken bär MODEL"          "$ut" "MODEL"
har "opencode-raden bär modellen" "$ut" "openai/gpt-5.3-codex"

# DEFAULTEN: en conf UTAN RUNTIME-rad är en Claude-session, inte en okänd.
rad_claude="$(printf '%s\n' "$ut" | grep alfa || true)"
case "$rad_claude" in
  *claude-code*) ok "conf utan RUNTIME renderas som claude-code" ;;
  *) bad "conf utan RUNTIME renderas inte som claude-code" "rad: '$rad_claude'" ;;
esac
case "$rad_claude" in
  *"?"*) bad "conf utan RUNTIME renderas som okänd — defaulten är kontraktet" "rad: '$rad_claude'" ;;
  *) ok "conf utan RUNTIME är inte okänd" ;;
esac
# SAKNAD MODELL ÄR "-", INTE TOMT. En tom cell i en kolumnjusterad tabell läses
# som ett renderingsfel, inte som "den här runtimen har ingen modell".
# MODELLKOLUMNEN, INTE VILKET BINDESTRECK SOM HELST. Timerkolumnen bär redan
# "-", så en naken sökning efter bindestreck passerade innan kolumnen fanns.
case "$rad_claude" in
  *"claude-code"*" - "*|*"claude-code"*" -") ok "saknad modell renderas som - EFTER runtime" ;;
  *) bad "saknad modell renderas inte som - efter runtime" "rad: '$rad_claude'" ;;
esac

rad_oc="$(printf '%s\n' "$ut" | grep beta || true)"
case "$rad_oc" in
  *opencode*) ok "opencode-raden bär sin runtime" ;;
  *) bad "opencode-raden bär inte sin runtime" "rad: '$rad_oc'" ;;
esac

# DE BEFINTLIGA KOLUMNERNA FÅR INTE TAPPAS. Nya fält som knuffar bort gamla är
# en tyst regression: tabellen ser komplett ut och saknar det man kom för.
har "ägarskap markeras fortfarande" "$ut" "*"
har "tmux-läget finns kvar"         "$ut" "up"
har "RC_LABEL finns kvar"           "$ut" "Prov Claude"

# EXAKTFORMEN =namn ÄR EN INVARIANT, inte en detalj: tmux prefixmatchar, och en
# session vars namn är prefix av en systers lånar annars systerns svar.
har "tmux frågas med exaktformen" "$(cat "$T/tmuxlogg")" "has-session -t =alfa"

# CONFEN FÅR INTE KÖRAS. Ett kommando som bara läser status ska inte exekvera
# estatets sessionsfiler — de kan innehålla vad som helst och maskinen bär
# flera människors sessioner.
cat > "$T/sessions.d/farlig.conf" <<'EOF'
HOST="provvard"
OWNER="provuser"
DOMAIN="prov"
RC_LABEL="Farlig"
RUNTIME="claude-code"
EOF
printf 'touch "%s/KORDES"\n' "$T" >> "$T/sessions.d/farlig.conf"
STEWARD_ESTATE_ROOT="$T" STEWARD_REGISTRY_DIR="$T/sessions.d" \
  STEWARD_SELF_HOST="provvard" STEWARD_SELF_USER="provuser" \
  STEWARD_TMUX_BIN="$T/bin/tmux" TMUX_LOGG="$T/tmuxlogg" \
  HOME="$T/home" PATH="$T/bin:$PATH" \
  bash "$here/linux/estate-status.sh" >/dev/null 2>&1
[ -f "$T/KORDES" ] && bad "confen KÖRDES — status får bara läsa" \
                   || ok "confen lästes utan att köras"

echo
printf '%s klarade, %s föll\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
