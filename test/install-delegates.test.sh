#!/bin/bash
# test/install-delegates.test.sh — install.sh must not duplicate the estate
# writing. The inline `cat > .../estate/steward.conf` block was the source of
# truth drifting from the identity model (it wrote 14 fields, not 16, and no
# entities.d). After this task the installer delegates to estate_scaffold, so
# there is ONE writer.
set -u
here="$(CDPATH= cd -- "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
pass=0; fail=0
ok(){ pass=$((pass+1)); }; bad(){ echo "FAIL: $1"; fail=$((fail+1)); }
check(){ local d="$1"; shift; if "$@"; then ok; else bad "$d"; fi; }

I="$here/install.sh"
check "install.sh sources the scaffold engine" grep -q 'lib/scaffold.sh' "$I"
check "install.sh calls estate_scaffold" grep -q 'estate_scaffold' "$I"
# THE INLINE WRITER IS GONE. A second place that writes the estate conf is a
# second truth; the whole point of the engine is one writer.
check "no inline estate-conf heredoc remains" \
  bash -c '! grep -q "cat > .*estate/steward.conf" "$1"' _ "$I"
# THE SESSION IS NOT DOUBLE-WRITTEN EITHER. estate_scaffold already writes
# sessions.d/<session>.conf, so a second inline heredoc for the hub session
# would silently clobber it with a stale, 8-field version missing ID/ASSETS —
# reintroducing the exact drift this task removes for the estate conf.
check "no inline hub-session heredoc remains" \
  bash -c '! grep -q "cat > .*sessions.d/\$HUB.conf" "$1"' _ "$I"

echo; printf 'pass=%s fail=%s\n' "$pass" "$fail"; [ "$fail" -eq 0 ]
