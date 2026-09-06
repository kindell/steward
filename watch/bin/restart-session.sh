#!/bin/bash
# watch/bin/restart-session.sh <session> [reason] - restart a registered
# session and resume it at once. See restart-session.mjs.
set -uo pipefail
cd "$(dirname "$0")/.."
exec "${STEWARD_NODE:-node}" restart-session.mjs "$@"
