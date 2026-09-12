#!/bin/bash
# test/bridge-classify.test.sh - candidates by name never by order; poison is a LINE;
# a missing field is schema, not foreign; empty fields survive framing (US, not tab).
#
# WHY A LINE AND NOT A VARIABLE (A2, 2026-09-11): the first draft counted broken files
# in a shell variable set inside bridge_candidates. Every caller captured the output
# with $(...), so the variable was set in a subshell and the caller read zero. Poison
# is now a line on stdout, and this suite counts lines.
#
# WHY US AND NOT TAB (B8): tab is IFS whitespace, and `read` collapses a run of
# whitespace, so a row with an EMPTY name shifted every later field one to the left.
# The unit separator (byte 31) is not whitespace; an empty field survives EMPTY, and a
# literal "-" stays a literal "-" (a sentinel would have made the two collide).
#
# WHY SCHEMA BEFORE MEMBERSHIP (A3): a file missing `tmux` used to be "foreign" and
# silently skipped. A vendor rename of that field would then have turned every row
# into no-process and authorised a spawn. Now a record is validated whole first.
set -u
here="$(CDPATH= cd -- "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
pass=0; fail=0
ok()  { pass=$((pass+1)); printf '  ok   %s\n' "$1"; }
bad() { fail=$((fail+1)); printf '  FAIL %s\n     %s\n' "$1" "${2:-}"; }
is()  { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "wanted '$3', got '$2'"; fi; }
has() { case "$2" in *"$3"*) ok "$1" ;; *) bad "$1" "missing '$3' in: $2" ;; esac; }
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
. "$here/lib/bridge.sh" || { echo "cannot source lib/bridge.sh"; exit 1; }
US="$(printf '\037')"
ID="s-0000000000000001"; D="$T/sessions"; mkdir -p "$D"
mk() { # <pid> <tmux> <name> ; file is <pid>.json
  printf '{"pid":%s,"procStart":123,"tmux":"%s","name":"%s","nameSince":1789000000000,"sessionId":"aaaa-bbbb","startedAt":1789000000000,"status":"idle","bridgeSessionId":"SECRET","messagingSocketPath":"/tmp/SECRET.sock"}\n' "$1" "$2" "$3" > "$D/$1.json"
}
oks()    { printf '%s\n' "$1" | grep -c "^ok$US"; }
poison() { printf '%s\n' "$1" | grep -c "^!unclassifiable$US"; }
fld()    { printf '%s\n' "$1" | grep "^ok$US" | head -1 | cut -d "$US" -f "$2"; }

echo "== 1. one well-formed file: one ok line, fields by position, no secret =="
mk 100 "$ID:@0.%0" "Alpha→Beta"
out="$(bridge_candidates "$ID" "$D")"
is "1a one ok" "$(oks "$out")" "1"; is "1b no poison" "$(poison "$out")" "0"
is "1c pid" "$(fld "$out" 3)" "100"; is "1d tmux" "$(fld "$out" 5)" "$ID:@0.%0"; is "1e name" "$(fld "$out" 6)" "Alpha→Beta"
case "$out" in *SECRET*) bad "1f no secret leaks" "$out" ;; *) ok "1f no secret leaks" ;; esac
ino1="$(fld "$out" 11)"; case "$ino1" in ''|*[!0-9]*|0) bad "1g inode is a positive integer" "$ino1" ;; *) ok "1g inode is a positive integer" ;; esac
is "1h inode equals stat's answer for the path" "$ino1" "$(stat -c %i "$D/100.json" 2>/dev/null || stat -f %i "$D/100.json")"
is "1i inode is stable across two reads" "$(fld "$(bridge_candidates "$ID" "$D")" 11)" "$ino1"
# NOT CLAIMED: that a recreated file gets a NEW inode. ext4 reuses a freed inode number at once,
# so freshness cannot rest on the inode alone - the plan pairs it with mtime (D10, measured here).

echo "== 2. a complete file for another id is silent; a prefix of the id is not the id =="
mk 101 "s-0000000000000002:@0.%0" "Other"; mk 102 "${ID}0:@0.%0" "Prefix"
out="$(bridge_candidates "$ID" "$D")"; is "2a one ok" "$(oks "$out")" "1"; is "2b no poison" "$(poison "$out")" "0"

echo "== 3. broken files are poison lines, each named =="
printf '{"pid":103,"tmux":"%s"' "$ID:@1.%1" > "$D/103.json"                        # truncated -> json
ln -s "$D/100.json" "$D/104.json"                                                    # symlink
ln -s "$D/nope.json" "$D/108.json"                                                   # dangling symlink
head -c 70000 /dev/zero | tr '\0' 'x' > "$D/105.json"                                # size
printf '{"pid":"abc","procStart":1,"tmux":"%s","name":"x","nameSince":1,"sessionId":"s","startedAt":1}\n' "$ID:@2.%2" > "$D/106.json"   # types
printf '{"pid":109,"procStart":1,"name":"no tmux","nameSince":1,"sessionId":"s","startedAt":1}\n' > "$D/109.json"                  # types (missing tmux)
printf '{"pid":110,"procStart":1,"tmux":"%s","name":"tab\\there","nameSince":1,"sessionId":"s","startedAt":1}\n' "$ID:@3.%3" > "$D/110.json"  # control-char
printf '{"pid":999,"procStart":1,"tmux":"%s","name":"x","nameSince":1,"sessionId":"s","startedAt":1}\n' "$ID:@4.%4" > "$D/111.json"          # filename-pid
out="$(bridge_candidates "$ID" "$D")"
is "3a accepted unchanged" "$(oks "$out")" "1"
is "3b eight poison lines" "$(poison "$out")" "8"
for f in 103 104 105 106 108 109 110 111; do has "3c $f named" "$out" "$f.json"; done
has "3d filename-pid reason" "$out" "filename-pid"
# THE REASON IS THE CLAIM: a file without tmux must be poison BECAUSE of schema. If the id
# test ran first, jq would choke on null and the reason would read "json" - still named, still
# poison, and the schema-first guard would be gone without any assertion noticing.
is "3e 109 reason is types (schema), not json" "$(printf '%s\n' "$out" | grep 109.json | cut -d "$US" -f 3)" "types"
is "3f 110 reason is control-char" "$(printf '%s\n' "$out" | grep 110.json | cut -d "$US" -f 3)" "control-char"

echo "== 3b. procStart: the vendor writes it as a NUMBER on one build and a STRING on another =="
# MEASURED on basement 2026-09-11: "procStart":"54058753" - a string. P1 measured a number. It is an
# opaque token we only compare, so both are read and both become the same digits; anything else is poison.
# (this section keeps only its own files; section 5 counts what section 4 left)
printf '{"pid":120,"procStart":"54058753","tmux":"%s","name":"Str","nameSince":1,"sessionId":"s","startedAt":1}\n' "$ID:@7.%7" > "$D/120.json"
out="$(bridge_candidates "$ID" "$D" | grep "${US}120${US}")"
is "3b1 a string procStart is accepted" "$(printf '%s\n' "$out" | cut -d "$US" -f 4)" "54058753"
printf '{"pid":121,"procStart":54058753,"tmux":"%s","name":"Num","nameSince":1,"sessionId":"s","startedAt":1}\n' "$ID:@7.%7" > "$D/121.json"
out="$(bridge_candidates "$ID" "$D" | grep "${US}121${US}")"
is "3b2 a number procStart gives the SAME digits" "$(printf '%s\n' "$out" | cut -d "$US" -f 4)" "54058753"
printf '{"pid":122,"procStart":"5405 8753","tmux":"%s","name":"Bad","nameSince":1,"sessionId":"s","startedAt":1}\n' "$ID:@7.%7" > "$D/122.json"
is "3b3 a string that is not digits is poison" "$(bridge_candidates "$ID" "$D" | grep '122.json' | cut -d "$US" -f 3)" "types"
printf '{"pid":125,"procStart":"abc","tmux":"%s","name":"Word","nameSince":1,"sessionId":"s","startedAt":1}\n' "$ID:@7.%7" > "$D/125.json"
is "3b3b a word is poison too - the shape is digits, not 'any string'" "$(bridge_candidates "$ID" "$D" | grep '125.json' | cut -d "$US" -f 3)" "types"
printf '{"pid":126,"procStart":"","tmux":"%s","name":"Empty","nameSince":1,"sessionId":"s","startedAt":1}\n' "$ID:@7.%7" > "$D/126.json"
is "3b3c an empty string is poison" "$(bridge_candidates "$ID" "$D" | grep '126.json' | cut -d "$US" -f 3)" "types"
rm -f "$D/125.json" "$D/126.json"

echo "== 3c. procStart on darwin is a DATE, and the discriminator is pidDomain =="
# MEASURED on butler (macOS 25.5) 2026-09-12: the vendor writes "procStart":"Sat Sep 12 08:40:24 2026"
# - ps(1)'s lstart words, not digits. Every bridge file on the host read as "types" poison, so every
# candidate was unclassifiable and the adapter answered unknown for a session that was plainly running.
#
# THE SHAPE IS NOT THE DISCRIMINATOR, pidDomain IS. Deciding from the value's looks is how the digit
# string got read as "any string will do" once already; a date that arrives without pidDomain=darwin
# is still poison, so a Linux build cannot start smuggling words through this gate.
#
# AND IT NORMALISES AS UTC. The vendor writes procStart in UTC while ps(1) prints lstart in LOCAL time
# - measured +2h apart on three live pids the same second. Parsed in their own zones both name the same
# instant; parsed in one zone they are 7200s apart forever, and the mismatch would read as "wrong
# process" rather than "wrong timezone". jq's mktime is UTC, which is why this is one call and not a
# date(1) dance.
printf '{"pid":130,"pidDomain":"darwin","procStart":"Sat Sep 12 08:40:24 2026","tmux":"%s","name":"Dar","nameSince":1,"sessionId":"s","startedAt":1}\n' "$ID:@7.%7" > "$D/130.json"
out="$(bridge_candidates "$ID" "$D" | grep "${US}130${US}")"
is "3c1 a darwin lstart date is accepted, normalised to UTC epoch" "$(printf '%s\n' "$out" | cut -d "$US" -f 4)" "1789202424"
printf '{"pid":131,"procStart":"Sat Sep 12 08:40:24 2026","tmux":"%s","name":"NoDom","nameSince":1,"sessionId":"s","startedAt":1}\n' "$ID:@7.%7" > "$D/131.json"
is "3c2 the same date WITHOUT pidDomain=darwin is still poison" "$(bridge_candidates "$ID" "$D" | grep '131.json' | cut -d "$US" -f 3)" "types"
printf '{"pid":132,"pidDomain":"darwin","procStart":"not a date","tmux":"%s","name":"Bad","nameSince":1,"sessionId":"s","startedAt":1}\n' "$ID:@7.%7" > "$D/132.json"
is "3c3 pidDomain=darwin does not make any string legal" "$(bridge_candidates "$ID" "$D" | grep '132.json' | cut -d "$US" -f 3)" "types"
printf '{"pid":133,"pidDomain":"darwin","procStart":"54058753","tmux":"%s","name":"DarNum","nameSince":1,"sessionId":"s","startedAt":1}\n' "$ID:@7.%7" > "$D/133.json"
out="$(bridge_candidates "$ID" "$D" | grep "${US}133${US}")"
is "3c4 a digit string on darwin still reads as itself" "$(printf '%s\n' "$out" | cut -d "$US" -f 4)" "54058753"
rm -f "$D/130.json" "$D/131.json" "$D/132.json" "$D/133.json"
printf '{"pid":123,"procStart":54058753.5,"tmux":"%s","name":"Frac","nameSince":1,"sessionId":"s","startedAt":1}\n' "$ID:@7.%7" > "$D/123.json"
is "3b4 a fractional procStart is poison" "$(bridge_candidates "$ID" "$D" | grep '123.json' | cut -d "$US" -f 3)" "types"
printf '{"pid":124,"procStart":null,"tmux":"%s","name":"Null","nameSince":1,"sessionId":"s","startedAt":1}\n' "$ID:@7.%7" > "$D/124.json"
is "3b5 a null procStart is poison" "$(bridge_candidates "$ID" "$D" | grep '124.json' | cut -d "$US" -f 3)" "types"
rm -f "$D"/12*.json

echo "== 4. an EMPTY name survives framing as EMPTY; a literal dash stays a dash =="
rm -f "$D"/10[1-9].json "$D"/11?.json
printf '{"pid":112,"procStart":1,"tmux":"%s","name":"","nameSince":1,"sessionId":"s","startedAt":1}\n' "$ID:@5.%5" > "$D/112.json"
out="$(bridge_candidates "$ID" "$D" | grep "${US}112${US}")"; is "4a name is empty" "$(printf '%s\n' "$out" | cut -d "$US" -f 6)" ""
is "4b sessionId still in place" "$(printf '%s\n' "$out" | cut -d "$US" -f 8)" "s"
mk 113 "$ID:@6.%6" "-"
out="$(bridge_candidates "$ID" "$D" | grep "${US}113${US}")"; is "4c a literal dash is a dash" "$(printf '%s\n' "$out" | cut -d "$US" -f 6)" "-"
IFS="$US" read -r _tag _path _pid _ps _tmux _name _since _sid _rest <<EOF
$(bridge_candidates "$ID" "$D" | grep "${US}112${US}")
EOF
is "4d read with IFS=US keeps the empty field in place" "$_sid" "s"

echo "== 5. two complete files for one id are two ok lines =="
mk 107 "$ID:@3.%3" "Second"
out="$(bridge_candidates "$ID" "$D")"; is "5a four ok (100,112,113,107)" "$(oks "$out")" "4"

echo "== 6. birth token; odd comm does not shift the field =="
P="$T/proc"; mkdir -p "$P/sys/kernel/random" "$P/4242" "$P/4243"; printf 'boot-1111\n' > "$P/sys/kernel/random/boot_id"
printf '4242 (claude) S 1 4242 4242 0 -1 4194560 100 0 0 0 5 5 0 0 20 0 1 0 987654 1000 200 1\n' > "$P/4242/stat"
printf '4243 (my (odd) claude) S 1 1 1 0 -1 0 0 0 0 0 0 0 0 0 20 0 1 0 555 0 0 0\n' > "$P/4243/stat"
is "6a token" "$(BRIDGE_PROC_ROOT="$P" bridge_os_birth 4242)" "boot-1111:987654"
is "6b odd comm" "$(BRIDGE_PROC_ROOT="$P" bridge_os_birth 4243)" "boot-1111:555"
BRIDGE_PROC_ROOT="$P" bridge_os_birth 9999 >/dev/null 2>&1; is "6c gone rc 1" "$?" "1"
mkdir -p "$P/4244" "$P/4245"
printf '4244 (claude) Z 1 1 1 0 -1 0 0 0 0 0 0 0 0 0 20 0 1 0 777 0 0 0\n' > "$P/4244/stat"   # zombie: same birth, not alive
printf '4245 (claude) X 1 1 1 0 -1 0 0 0 0 0 0 0 0 0 20 0 1 0 778 0 0 0\n' > "$P/4245/stat"   # dead
BRIDGE_PROC_ROOT="$P" bridge_os_birth 4244 >/dev/null 2>&1; is "6d a zombie is not alive (rc 1)" "$?" "1"
is "6e and prints no token" "$(BRIDGE_PROC_ROOT="$P" bridge_os_birth 4244 2>/dev/null)" ""
BRIDGE_PROC_ROOT="$P" bridge_os_birth 4245 >/dev/null 2>&1; is "6f state X is dead too" "$?" "1"

echo "== 7. descendant walk via a ps shim =="
BIN="$T/bin"; mkdir -p "$BIN"
cat > "$BIN/ps" <<'EOF'
#!/bin/sh
pid=""; prev=""; for a in "$@"; do [ "$prev" = "-p" ] && pid="$a"; prev="$a"; done
case "$pid" in 30) echo " 20";; 20) echo " 10";; 10) echo " 1";; *) exit 1;; esac
EOF
chmod 755 "$BIN/ps"
PATH="$BIN:$PATH" bridge_is_descendant 30 10; is "7a" "$?" "0"; PATH="$BIN:$PATH" bridge_is_descendant 30 99; is "7b" "$?" "1"

printf '\n%d passed, %d failed\n' "$pass" "$fail"; [ "$fail" -eq 0 ]
