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
use std::process::{Command, Stdio};

#[test]
fn no_tty_exits_with_ex_ioerr() {
    let out = Command::new(env!("CARGO_BIN_EXE_cockpit"))
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .output()
        .expect("cockpit binary should be runnable");

    // The binary must not succeed without a terminal - if it ever does, this test
    // is measuring a different program and the assertion below would be vacuous.
    assert!(!out.status.success(), "cockpit exited 0 without a tty");
    assert_eq!(
        out.status.code(),
        Some(74),
        "without a tty cockpit must exit EX_IOERR (74), got {:?}; stderr: {}",
        out.status.code(),
        String::from_utf8_lossy(&out.stderr)
    );
    // And it must say why, on stderr, before it goes.
    let err = String::from_utf8_lossy(&out.stderr);
    assert!(err.starts_with("cockpit: "), "the reason is not named: {err}");
}
