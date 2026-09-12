#!/usr/bin/env python3
"""linux/bridge-kill.py <pid> <birth> [SIGNAL] - pinned check-and-signal (D6).

A bare `kill <pid>` races: between the supervisor's check and its signal the pid can be
reused, and the signal lands on a stranger. Here the process is PINNED first
(os.pidfd_open), its birth token (boot_id:starttime ticks, exactly as lib/bridge.sh's
bridge_os_birth computes it) is read AFTER the pin, compared with the token the caller
saw, and the signal is sent to the pin - never to the number.

Exit codes: 0 signalled; 64 usage; 65 refused (gone, birth differs, empty birth, zombie,
no stat); 69 pidfd unavailable - and then NOTHING is sent: there is no fallback to kill.

STEWARD_KILL names a recorder run as `STEWARD_KILL <pid> <SIGNAL>` INSTEAD of the real
signal (tests). BRIDGE_PROC_ROOT replaces /proc (tests). STEWARD_FORCE_NO_PIDFD=1
simulates a python without pidfd_open.
"""
import os
import signal
import subprocess
import sys

PROC = os.environ.get("BRIDGE_PROC_ROOT", "/proc")


def usage(msg):
    sys.stderr.write("bridge-kill: %s\nusage: bridge-kill.py <pid> <birth> [SIGNAL]\n" % msg)
    return 64


def refuse(msg):
    sys.stderr.write("bridge-kill: REFUSING - %s\n" % msg)
    return 65


def parse_signal(name):
    """TERM, SIGTERM or 15 -> (signal.Signals, 'TERM'); None when it names nothing."""
    if name.isdigit():
        try:
            sig = signal.Signals(int(name))
        except ValueError:
            return None
    else:
        key = name if name.startswith("SIG") else "SIG" + name
        sig = getattr(signal.Signals, key, None) if key.isidentifier() else None
        if sig is None:
            return None
    return sig, sig.name[3:]


def birth_of(pid):
    """boot_id:ticks and the state letter, read from PROC. None when there is no stat."""
    try:
        with open(os.path.join(PROC, "sys", "kernel", "random", "boot_id")) as f:
            boot = f.read().strip()
        with open(os.path.join(PROC, str(pid), "stat")) as f:
            stat = f.read()
    except OSError:
        return None
    # The comm field may contain spaces and parentheses: split AFTER the last ")".
    rest = stat.rsplit(")", 1)[-1].split()
    if len(rest) < 20 or not boot:
        return None
    return "%s:%s" % (boot, rest[19]), rest[0]


def birth_of_darwin(pid):
    """(boot_sec:start_epoch, state) from ps(1) and sysctl(8) - MEASURED on minin 2026-09-12: darwin has
    no /proc and no pidfd. The same words lib/bridge.sh's darwin backend produces. None when gone."""
    try:
        bt = subprocess.run(["sysctl", "-n", "kern.boottime"], capture_output=True, text=True, check=False).stdout
        ps = subprocess.run(["ps", "-o", "stat=,lstart=", "-p", str(pid)], capture_output=True, text=True, check=False).stdout
    except OSError:
        return None
    import re, time
    m = re.search(r"sec = (\d+)", bt)
    line = ps.strip().splitlines()
    if not m or not line:
        return None
    parts = line[0].split(None, 1)
    if len(parts) < 2:
        return None
    state, lstart = parts[0], parts[1].strip()
    try:
        epoch = int(time.mktime(time.strptime(lstart, "%a %b %d %H:%M:%S %Y")))
    except ValueError:
        return None
    return "%s:%d" % (m.group(1), epoch), state[:1]


def main_darwin(pid, birth, sig, sig_name):
    """NO PIN EXISTS HERE. The birth is re-read immediately before the signal and must equal the caller's;
    the window between that read and kill(2) is the one a reused pid could slip through, and a reused pid
    would also need the same start second. That is the best darwin offers, and it is said in the receipt."""
    if not birth:
        return refuse("empty birth token; an empty key matches nothing")
    seen = birth_of_darwin(pid)
    if seen is None:
        return refuse("pid %d is gone (no ps line)" % pid)
    token, state = seen
    if state in ("Z", "X"):
        return refuse("pid %d is a zombie (state %s); it is dead, not ours to signal" % (pid, state))
    if token != birth:
        return refuse("pid %d birth is %s, caller saw %s; the number was reused" % (pid, token, birth))
    recorder = os.environ.get("STEWARD_KILL")
    if recorder:
        if subprocess.run([recorder, str(pid), sig_name], check=False).returncode != 0:
            return refuse("the signal recorder %r returned non-zero; nothing is claimed delivered" % recorder)
    else:
        try:
            os.kill(pid, sig)
        except ProcessLookupError:
            return refuse("pid %d died between its ps line and the signal" % pid)
    print("killed %d %s %s (darwin: birth re-read before the signal, no pin)" % (pid, birth, sig_name))
    return 0


def main(argv):
    if len(argv) < 2 or len(argv) > 3:
        return usage("two or three arguments")
    pid_s, birth = argv[0], argv[1]
    sig_s = argv[2] if len(argv) == 3 else "TERM"
    if not pid_s.isdigit() or int(pid_s) < 1:
        return usage("pid must be a positive integer, got %r" % pid_s)
    pid = int(pid_s)
    parsed = parse_signal(sig_s)
    if parsed is None:
        return usage("unknown signal %r" % sig_s)
    sig, sig_name = parsed
    os_name = os.environ.get("BRIDGE_OS") or sys.platform
    if os_name.startswith("darwin"):
        return main_darwin(pid, birth, sig, sig_name)
    if os.environ.get("STEWARD_FORCE_NO_PIDFD") == "1" or not hasattr(os, "pidfd_open"):
        sys.stderr.write("bridge-kill: pidfd unavailable on this python/kernel; nothing sent (no fallback to kill)\n")
        return 69
    if not birth:
        return refuse("empty birth token; an empty key matches nothing")
    try:
        fd = os.pidfd_open(pid)
    except ProcessLookupError:
        return refuse("pid %d is gone" % pid)
    except OSError as e:
        return refuse("pidfd_open(%d): %s" % (pid, e))
    try:
        # PINNED. From here on the pid names exactly one process incarnation.
        seen = birth_of(pid)
        if seen is None:
            return refuse("pid %d is pinned but has no readable stat (gone)" % pid)
        token, state = seen
        if state in ("Z", "X"):
            return refuse("pid %d is a zombie (state %s); it is dead, not ours to signal" % (pid, state))
        if token != birth:
            return refuse("pid %d birth is %s, caller saw %s; the number was reused" % (pid, token, birth))
        recorder = os.environ.get("STEWARD_KILL")
        if recorder:
            # THE RECORDER STANDS IN FOR THE SIGNAL, so its failure is the signal's failure: no receipt.
            if subprocess.run([recorder, str(pid), sig_name], check=False).returncode != 0:
                return refuse("the signal recorder %r returned non-zero; nothing is claimed delivered" % recorder)
        else:
            try:
                signal.pidfd_send_signal(fd, sig)
            except ProcessLookupError:
                return refuse("pid %d died between its stat and the signal" % pid)
    finally:
        os.close(fd)
    print("killed %d %s %s" % (pid, birth, sig_name))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
