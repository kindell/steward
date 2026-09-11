# lib/listeners.sh - what is listening on loopback, and who it belongs to.
#
# ITS OWN FILE BECAUSE IT HAD TO BE ASKED A QUESTION IT COULD NOT BE ASKED
# INSIDE session-approve.sh. That script runs top to bottom against a live tmux
# pane and a live bus, so the probe could not be exercised without a session -
# and the one thing it most needed to be asked, "what do you do when you cannot
# measure?", was therefore never asked.
#
# The answer turned out to be: report a PASS. Measured 2026-09-11 on macOS by
# the session being approved. The probe was built on ss(8), which does not exist
# on darwin; every pipeline yielded the empty string, so N=0, account=0,
# session=0, and the criterion "no listeners started by THIS SESSION" held
# because nothing had been counted. lsof on the same host at the same moment
# showed NINE loopback listeners. The verdict happened to be right - that
# session had started nothing - but by luck, and luck is not a criterion.
#
# The original comment block argued at length that the unknown must become a
# NUMBER rather than a void. On that host the whole surface became a void.
#
# SO THE ABSENCE OF A TOOL IS AN ERROR, NOT AN EMPTY RESULT. listeners_probe
# returns 70 and sets LISTENERS_TOOL=none, and it leaves the counts EMPTY
# rather than zero - zero is an answer, and answering zero here would be
# indistinguishable from a clean machine, which is the whole defect.
#
# Sets, for the caller to read:
#   LISTENERS_TOOL     ss | lsof | none
#   LISTENERS_N        loopback listeners on the machine, all owners ('' if unmeasured)
#   LISTENERS_ACCOUNT  of those, the ones attributable to this uid ('' if unmeasured)
#   LISTENERS_ROWS     one line per attributable listener: `    <addr>  pid=<pid>`
#
# The ROWS carry `pid=<n>` in ss's own spelling whichever tool produced them, so
# a caller that walks a process tree does not have to know which host it is on.

# _listeners_loopback_only - keep the lines whose address is loopback.
# NOT A PORT-CLASS NARROWING: the whole loopback surface, exactly as before.
_listeners_loopback_only() { awk '/127\.0\.0\.1/ || /\[::1\]/'; }

listeners_probe() {
  LISTENERS_TOOL="none"; LISTENERS_N=""; LISTENERS_ACCOUNT=""; LISTENERS_ROWS=""

  if command -v ss >/dev/null 2>&1; then
    LISTENERS_TOOL="ss"
    LISTENERS_N="$(ss -ltn 2>/dev/null | _listeners_loopback_only | grep -c .)"
    LISTENERS_ROWS="$(ss -ltnp 2>/dev/null | _listeners_loopback_only \
                      | awk '/users:/ {print "    " $4 "  " $NF}')"
  elif command -v lsof >/dev/null 2>&1; then
    LISTENERS_TOOL="lsof"
    # -nP: no name or port resolution, so the address is comparable as text and
    # the probe cannot block on DNS while measuring.
    LISTENERS_N="$(lsof -nP -iTCP -sTCP:LISTEN 2>/dev/null | _listeners_loopback_only | grep -c .)"
    # THE SAME SHAPE AS ss's ROWS, built from lsof's columns: the address is the
    # field before "(LISTEN)" and the pid is column 2. A caller walking a
    # process tree reads `pid=<n>` either way and never learns which host it is
    # running on - which is the point of the shared spelling.
    # -a IS LOAD-BEARING: lsof ORs its selections by default, so without it this
    # asks for "(TCP listeners) OR (this uid's open files)" - and the second
    # half is not a near-miss, it is every open file the account has. MEASURED
    # on both platforms: 455 rows against 5 on Linux, 15477 against 17 on
    # macOS. Without -a the approval report lists the account's FILES under a
    # heading that says listeners: the wrong CLASS of object, thousands of them.
    #
    # AN EARLIER VERSION OF THIS COMMENT CLAIMED SOMETHING ELSE - that the OR
    # returns other accounts' listeners and attributes them to this one. That is
    # wrong, and two measurements say so. A non-root lsof is not handed another
    # uid's sockets: on Linux, as one of five accounts, it returned five rows
    # all its own where root saw eight accounts; on macOS it returned sixteen,
    # all its own, while netstat counted twenty-nine listening sockets on the
    # same machine - thirteen this account cannot see. The inode is visible in
    # /proc/net/tcp on Linux, but the process mapping needs another uid's
    # /proc/<pid>/fd. So the attribution lie is unreachable, and -a is
    # load-bearing for the class of object rather than for whose it is.
    LISTENERS_ROWS="$(lsof -nP -a -iTCP -sTCP:LISTEN -u "$(id -u)" 2>/dev/null \
                      | _listeners_loopback_only \
                      | awk '{ for (i = NF; i > 1; i--) if ($i ~ /:[0-9]+$/) { addr = $i; break }
                               if (addr != "") print "    " addr "  pid=" $2; addr = "" }')"
  else
    echo "listeners: REFUSING - neither ss nor lsof is present, so the loopback surface cannot be measured on this host" >&2
    echo "listeners: an unmeasured criterion is not a passed one; install one of them or state the platform as unsupported" >&2
    return 70
  fi

  LISTENERS_ACCOUNT="$(printf '%s' "$LISTENERS_ROWS" | grep -c .)"
  return 0
}
