// tests/exit_codes.rs - the exit code a caller sees when cockpit cannot have a terminal.
//
// A TUI that is started without a tty (from a job, a pipe, an ssh command with no
// pty) fails before it draws anything, and the only thing the caller gets is the
// code. It must name the CLASS of failure: what fails is an ioctl on the device
// (enable_raw_mode, or writing the alternate-screen sequences), so it is EX_IOERR
// (74) and not EX_UNAVAILABLE (69). Measured on darwin 2026-09-14: without a tty
// the underlying error is "Device not configured (os error 6)", ENXIO.
//
// 69 is not free in this fleet - it already means "the thing you asked for is not
// available here" (bridge-kill on a python without pidfd, desk-snapshot-serve with
// no current generation). An operator who reads 69 goes looking for a missing
// dependency; the actual repair is "give it a terminal".
use std::os::unix::process::CommandExt;
use std::process::{Command, Stdio};

#[test]
fn no_tty_exits_with_ex_ioerr() {
    // THE CHILD MUST HAVE NO CONTROLLING TERMINAL, and closing stdin is not the
    // same thing. Measured on darwin 2026-09-14, three environments, one binary:
    //
    //   no controlling terminal at all   -> 74, "Device not configured" (this case)
    //   controlling tty, stdin /dev/null -> 70, "Failed to initialize input reader"
    //   controlling tty, stdin inherited -> the TUI runs
    //
    // crossterm opens /dev/tty, not fd 0, so a test that only nulls stdin measures
    // whichever terminal the RUNNER happened to have: 74 from a gate or a job, 70
    // from a developer's terminal. setsid() makes the child a session leader with
    // no controlling terminal, so this test measures the same thing everywhere.
    // Found by the Linux steward, who asked the question the assertion could not
    // answer about itself.
    let mut cmd = Command::new(env!("CARGO_BIN_EXE_cockpit"));
    cmd.stdin(Stdio::null()).stdout(Stdio::piped()).stderr(Stdio::piped());
    unsafe {
        cmd.pre_exec(|| {
            // setsid() fails with EPERM only if the caller is already a process
            // group leader; the child of a fork never is, so a failure here is
            // real and must not be swallowed into a misleading exit code.
            if libc::setsid() == -1 {
                return Err(std::io::Error::last_os_error());
            }
            Ok(())
        });
    }
    let out = cmd.output().expect("cockpit binary should be runnable");

    // The binary must not succeed without a terminal - if it ever does, this test
    // is measuring a different program and the assertion below would be vacuous.
    assert!(!out.status.success(), "cockpit exited 0 without a tty");
    assert_eq!(
        out.status.code(),
        Some(74),
        "with no controlling terminal cockpit must exit EX_IOERR (74), got {:?}; stderr: {}",
        out.status.code(),
        String::from_utf8_lossy(&out.stderr)
    );
    // And it must say why, on stderr, before it goes.
    let err = String::from_utf8_lossy(&out.stderr);
    assert!(err.starts_with("cockpit: "), "the reason is not named: {err}");
}
