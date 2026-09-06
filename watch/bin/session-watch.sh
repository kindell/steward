#!/bin/bash
# watch/bin/session-watch.sh - one watch cycle. Run by the estate's job every
# five minutes; the job's log carries this process's exit lines, and THOSE are
# the measurement of whether the watch runs - not the absence of alarms. A
# watch once died for two days on a runner regression while every alarm stayed
# quiet, and quiet looked like health.
#
# node is the one on PATH; STEWARD_NODE overrides it for a pinned binary.
set -uo pipefail
cd "$(dirname "$0")/.."
exec "${STEWARD_NODE:-node}" session-watch.mjs
