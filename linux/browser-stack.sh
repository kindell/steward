#!/bin/bash
# ~/bin/browser-stack.sh — the browser stack on a Linux session host, idempotent.
#
# ┌──────────────────────────────────────────────────────────────────────────┐
# │ THE SOURCE IS THE MANIFEST'S: linux/browser-stack.sh                      │
# │ This file is a DEPLOYED COPY and is overwritten by the next deploy.       │
# │                                                                          │
# │ If you edit it here: send the change to whoever owns the checkout, or it  │
# │ disappears without a trace. That has happened in several homes, more than │
# │ once — and whoever deploys notices nothing, because it is SOMEBODY        │
# │ ELSE'S work being discarded.                                             │
# │                                                                          │
# │ Reading a document's contents and knowing who owns it are two different   │
# │ things.                                                                   │
# └──────────────────────────────────────────────────────────────────────────┘
#
# ONE SCREEN PER PROFILE: every rig's browser gets its own Xvfb display with its
# own VNC port, so that you connect to the screen you meant and never share one
# by accident — and one rig's windows can never cover another's. Linux has no
# console limit; the cost is ~30 MB per screen. WHICH rigs actually exist, with
# which displays, ports and accounts, lives in the registry ($SCREENS below) —
# not here.
#
# The per-screen keyboard fix: Apple's VNC client sends Option as Meta_L
# (keycode 205) — measured 2026-08-06. Each xmodmap expression is issued
# separately: chained, the first failure silently killed the rest.
set -u
export PATH="/usr/bin:/bin:$PATH"

# THE SCREEN SIZE LIVES IN ONE PLACE. A hardcoded value repeated across several
# lines is rarely found in full when it changes — measured once: four of five
# places were found, one at a time, and the fifth was forgotten.
W=1600 H=1000

# THE RIG SHOWS HUMAN TIME, THE HOST LOGS UTC. Rigs exist so that a person can
# look at them over VNC, and that audience reads local time. If the host runs
# UTC the browser reports UTC, and every clock reading in a screenshot from it
# is wrong against the viewer's clock — by two hours in summer time, with
# nothing to say so. A value that is right in its own context and wrong when it
# crosses a boundary; here the boundary is the timezone.
#
# TZ is set PER BROWSER, not on the host: the system, the logs and the
# timestamps in job output keep UTC, which is right for them. This is not two
# pictures of time on one machine — it is one picture for machines and one for
# people, with different audiences. RIG_TZ can be set in the environment for a
# host that stands somewhere else.
start_screen() { # <display> <profile> <cdp-port> <vnc-port>
  # NEVER SET --remote-allow-origins. It opens CDP to any web page in the
  # browser. Solve it in the client instead (suppress_origin=True) — Chromium
  # answers 403 to WS handshakes that carry an Origin header.
  #
  # NEVER REUSE A DISPLAY NUMBER. A number that changes meaning makes old notes
  # misleading.
  #
  # A CLIENT'S LOGINS DO NOT BELONG IN A PRIVATE PROFILE. One profile per
  # client, and not for tidiness.
  local d="$1" prof="$2" cdp="$3" vnc="$4"
  DISPLAY=":$d"
  pgrep -u "$(id -u)" -f "Xvfb :$d " >/dev/null || { Xvfb ":$d" -screen 0 "${W}x${H}x24" & sleep 2; }
  DISPLAY=":$d" setxkbmap -layout se -option "" -option lv3:alt_switch 2>/dev/null
  DISPLAY=":$d" xmodmap -e "keycode 205 = Meta_L Meta_L Meta_L Meta_L" 2>/dev/null || true
  DISPLAY=":$d" xmodmap -e "remove mod1 = Meta_L" 2>/dev/null || true
  DISPLAY=":$d" xmodmap -e "add mod5 = Meta_L" 2>/dev/null || true
  # --start-maximized IS A REQUEST TO A WINDOW MANAGER, and there is none here.
  # Chromium therefore keeps its default size in the middle of a 1600x1000
  # screen, which shows up as black bands around the window. Explicit
  # dimensions are also right WITH a WM: the screen holds only one window.
  #
  # THE GPU FLAGS ARE NOT COSMETIC. Without them Chromium falls back on
  # SwiftShader — software rendering — even though the machine has real GPU
  # hardware and /dev/dri exists. Measured: one renderer sat at 70 % CPU while
  # the GPU tool reported 0 % GPU load. A single heavy page could eat a whole
  # core, and one orphaned renderer burned 57.7 hours of CPU before anyone
  # noticed. Xvfb has no GLX, so the path to the card goes through EGL.
  #
  # THE GROUPS ARE TAKEN EXPLICITLY, NOT INHERITED. An account can be put in
  # video+render to reach /dev/dri, but systemd's USER MANAGER keeps the
  # credentials it started with: a process systemd launches still sees only the
  # original groups, while a fresh ssh login sees video+render. Measured, not
  # assumed — and 'systemctl --user daemon-reexec' does not help.
  #
  # The consequence would have been a SILENT REGRESSION: restart the browsers
  # from an ssh session and they get GPU access, but the moment the timer
  # restarts one after a crash it is lost again, with no error.
  #
  # 'sg' is setuid and re-reads /etc/group, so it succeeds where setpriv fails
  # ('setgroups failed: Operation not permitted'). Nested to get both groups:
  # render for renderD128 (EGL), video for card1.
  #
  # The alternative was restarting systemd --user, which would have killed the
  # other live sessions on the machine for the sake of a GPU flag. Wrong price.
  #
  # A STALE SINGLETONLOCK BLOCKS THE START SILENTLY. Measured 2026-08-10: after
  # a kill -9, ~/chrome-profiles/<profile>/Singleton* remains and refers to a
  # dead pid. Chromium then refuses to start — but THE SCRIPT sees no error,
  # because the pgrep guard correctly reports that no process exists and the
  # start is backgrounded with output to /dev/null. The result is a screen that
  # looks set up and is empty.
  #
  # We touch the locks ONLY in the branch where the guard has just established
  # that no process holds the profile — otherwise we would be the very fault we
  # are trying to avoid, two instances on one profile.
  #
  # 0700 IS A REQUIREMENT, NOT A HAPPY SIDE EFFECT. A bare `mkdir -p` under
  # umask 0002 gives 0775, and the only thing that tightened the directory
  # afterwards was Chromium doing it itself at startup. The proof is our own
  # fossils: empty directories sat at 0775 for HOURS, because no browser ever
  # started in them.
  #
  # There were two windows of exposure: a short one between mkdir and Chromium's
  # chmod, and an unbounded one if Chromium NEVER starts (wrong display, missing
  # group, crash before initialisation, a change of browser) — then the
  # directory stays world-readable and nothing says so. The next time it is used
  # it carries real logins. (Checked: grepping for chmod/mkdir -m/umask across
  # the whole file gives zero hits outside this line.)
  #
  # -m sets the mode AT CREATION, so there is no window at all. And it is
  # self-documenting: the line says 0700 is required, instead of trusting
  # somebody else to tighten it. Write the rationale AS THE CONDITION.
  mkdir -m 700 -p "$HOME/chrome-profiles/$prof" 2>/dev/null
  # ...and refuse to start in a directory SOMEBODY ELSE created with the wrong
  # mode. That also catches the case where the directory already existed, and
  # turns the absence of an alarm into a measurement.
  _pm="$(stat -c %a "$HOME/chrome-profiles/$prof" 2>/dev/null || echo '?')"
  if [ "$_pm" != "700" ]; then
    echo "browser-stack: REFUSING to start $prof — the profile directory has mode $_pm, the requirement is 700." >&2
    echo "  A profile that will hold real logins must not be readable by other accounts." >&2
    echo "  chmod 700 \"$HOME/chrome-profiles/$prof\" and run again." >&2
    return 1
  fi
  if ! pgrep -u "$(id -u)" -f "user-data-dir=$HOME/chrome-profiles/$prof" >/dev/null; then
    rm -f "$HOME/chrome-profiles/$prof"/Singleton* 2>/dev/null
  fi
  pgrep -u "$(id -u)" -f "user-data-dir=$HOME/chrome-profiles/$prof" >/dev/null || \
    DISPLAY=":$d" TZ="${RIG_TZ:-Europe/Stockholm}" sg video -c "sg render -c \"exec chromium-browser --user-data-dir='$HOME/chrome-profiles/$prof' \
      --remote-debugging-port=$cdp --no-first-run \
      --force-prefers-reduced-motion \
      --window-position=0,0 --window-size=$W,$H\"" >/dev/null 2>&1 &
  pgrep -u "$(id -u)" -f "x11vnc -display :$d " >/dev/null || \
    x11vnc -display ":$d" -rfbport "$vnc" -localhost -rfbauth "$HOME/.vnc/passwd" \
      -forever -shared -quiet \
      -defer 5 -wait 5 -speeds lan -nodpms >/dev/null 2>&1 &
    # NO -threads: it is documented as experimental in x11vnc and STOPPED
    # FORWARDING INPUT when it was added for performance — mouse and keyboard
    # died at the same time, on both screens, even with no router involved.
    # XTEST worked throughout (measured with xdotool), so the fault was in the
    # server, not in X. The performance win was not worth a desktop you cannot
    # touch.
    # Nor -noxrecord: it disables scroll detection.
  ensure_autocutsel "$d" CLIPBOARD
  ensure_autocutsel "$d" PRIMARY
  warn_dangerous_flags "$prof"
}

warn_dangerous_flags() { # <profile> — warn if a FOREIGN instance opens the profile
  # A CHECK INSIDE start_screen IS NOT ENOUGH. One proposal was a guard there
  # that would make --remote-allow-origins impossible in the script's OWN
  # invocation — but it does not catch the flag if chromium is started BY HAND,
  # alongside the script. A script cannot know about something it never started.
  #
  # What does catch it is the timer noticing a foreign instance on one of our
  # profiles. It runs every three minutes and writes to the journal until
  # somebody acts.
  #
  # WARN, DO NOT KILL: killing somebody's logged-in browser is worse than the
  # flag. Whoever reads the line decides.
  #
  # READS /proc/<pid>/cmdline, NOT pgrep -f with the string in the pattern.
  # pgrep -f matches its OWN command when the pattern appears in the command
  # line — the same trap can be walked into twice in one day, and it comes back
  # with pkill -f over ssh. A guard that alarms on itself soon does not alarm at
  # all.
  local prof="$1" pid args
  for pid in $(pgrep -u "$(id -u)" -f "user-data-dir=$HOME/chrome-profiles/$prof" 2>/dev/null); do
    args="$(tr '\0' ' ' < "/proc/$pid/cmdline" 2>/dev/null)" || continue
    case "$args" in
      *--remote-allow-origins*)
        echo "browser-stack: WARNING pid $pid on profile $prof runs with --remote-allow-origins — CDP is open to any web page in that browser" >&2 ;;
    esac
    case "$args" in
      *--disable-web-security*)
        echo "browser-stack: WARNING pid $pid on profile $prof runs with --disable-web-security" >&2 ;;
    esac
  done
}

ensure_autocutsel() { # <display> <selection> — exactly ONE per screen and selection
  # THIS GUARD LEAKED 491 PROCESSES IN FOUR HOURS.
  # The search pattern read "autocutsel -selection CLIPBOARD -display :6" while
  # the start read "autocutsel -display :6 -selection CLIPBOARD" — the arguments
  # in the wrong order. pgrep therefore matched a command line that had never
  # existed, and the timer started two more every three minutes until the X
  # server's client limit ran out and NOTHING new could connect to the screen.
  # The symptom looked like Chromium failing to fill the window; the real fault
  # was that nothing could ask the screen about anything at all any more.
  #
  # The pattern is now built from the SAME string that starts the process, so
  # the two cannot drift apart again. Surplus is cleaned up — a broken guard
  # should heal itself, not accumulate.
  local d="$1" sel="$2"
  local args="-display :$d -selection $sel"
  local pids; pids=$(pgrep -u "$(id -u)" -f "autocutsel $args" 2>/dev/null)
  local n; n=$(printf '%s' "$pids" | grep -c . )
  if [ "$n" -eq 0 ]; then
    # shellcheck disable=SC2086
    autocutsel $args -fork 2>/dev/null
  elif [ "$n" -gt 1 ]; then
    echo "browser-stack: $n autocutsel for :$d/$sel — cleaning up the surplus" >&2
    printf '%s\n' "$pids" | tail -n +2 | xargs -r kill 2>/dev/null
  fi
}

# THE DIRECTORY IS CREATED BY WHOEVER WILL USE IT, in start_screen — not by an
# unconditional list up here.
#
# CREATING PROFILE DIRECTORIES UNCONDITIONALLY IN EVERY HOME GIVES EMPTY SHELLS
# WITH REAL NAMES in homes that should never have them — they look like
# configuration and are not. And unlike a file you can delete for good, the
# shape is SELF-RECREATING: the deletion looks done and is back on the next run,
# because the next run rebuilds the list.
#
# A SYMPTOM AND A MECHANISM REPORTED FROM TWO INDEPENDENT DIRECTIONS is stronger
# evidence than either alone. And the placement was ironic: the unconditional
# list sat two lines above the comment explaining that the registry can vary per
# home — the principle was written and its counterexample left standing right
# above it.
#
# THE SCREEN TABLE MAY LIVE PER HOME. More than one person can share a machine,
# and the second one needs their own screen in order to SEE a page — reviewing a
# visual change cannot be done by reading HTML source.
#
# OWN SCREEN, OWN PROCESS, OWN HOME — not an extra profile belonging to another
# user. A shared profile gives shared cookies, and a shared process means both
# see the same logins. The goal is to be able to SEE a page, not to share an
# identity.
#
# The instances behind these lessons — who, which home, which date, which line
# went wrong — belong in the estate's own documentation, not here.
#
# The format is four fields: <display> <profile> <cdp-port> <vnc-port>, one line
# per rig. "#" is a comment, blank lines are skipped.
#
# A FILE RATHER THAN A SECOND COPY OF THE SCRIPT: a second copy would have
# become a decoy that answers, and this tree has measured instances of exactly
# that.
#
# NO BUILT-IN DEFAULT TABLE, NO SILENT FALLBACK. If the file is missing the
# script refuses rather than guessing whose rigs it should start — a silent
# fallback of the form "${DOMAIN:-$NAME}" is one of this codebase's scars.
#
# THE PATH NAMES THE TOOL, NOT THE ESTATE. Until 2026-08-19 the directory
# carried the estate's own name instead of the tool's — a name in a runtime
# path, and that was what kept this file from moving into the product. The old
# name is not written out here: the leak guard catches it, and a comment that
# quotes what it abolishes makes the file impossible to approve. It is in the
# history for anyone who wants it.
#
# NO SILENT FALLBACK TO THE OLD NAME, and that is a deliberate choice two lines
# below the comment saying a silent fallback is one of this codebase's scars.
# The reason is measured rather than assumed: the directory did NOT exist in any
# home on either Linux host, their timers were `disabled` and `not-found`
# respectively, and the journal had zero entries. There was nothing to migrate.
#
# Should an unmeasured machine still carry the old name, the outcome is a LOUD
# refusal naming the path it looked for — the line below. That is the right
# outcome: a fallback would instead have read a registry nobody maintains and
# started rigs from it, silently.
SCREENS="$HOME/.config/browser-stack/screens"
if [ ! -f "$SCREENS" ]; then
  echo "browser-stack: REFUSING — the rig registry is missing: $SCREENS" >&2
  echo "  The format is four fields per line: <display> <profile> <cdp-port> <vnc-port>" >&2
  echo "  ('#' is a comment, blank lines are skipped)." >&2
  echo "  Create the file with one line per rig and run again." >&2
  exit 78
fi

while read -r _d _prof _cdp _vnc; do
  case "${_d:-}" in ''|\#*) continue ;; esac
  start_screen "$_d" "$_prof" "$_cdp" "$_vnc"
done < "$SCREENS"
exit 0
