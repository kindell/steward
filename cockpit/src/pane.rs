// cockpit/src/pane.rs — an embedded session, spawned into a real pty.
//
// WHY A MUTEX-GUARDED PARSER, NOT A SECOND mpsc. probe.rs's own channel is
// right for its job because every individual answer is data the loop must
// not lose — a probe result IS the thing being reported. A pty's raw bytes
// are different: nothing downstream cares about any one chunk, only about
// the CURRENT screen a redraw wants right now. Routing every chunk through a
// channel would force the render loop to drain everything that arrived since
// the last frame just to reach the same up-to-date `Screen` a `Mutex`
// already hands over directly. So the reader thread holds the lock only for
// the few microseconds `Parser::process` needs per chunk, the render path
// holds it only long enough to clone the `Screen` (which is `Clone`), and
// neither side blocks the other for longer than that. main.rs's own
// probe-result channel is untouched by this choice — the `recv`-ban and the
// `try_recv` drain there still apply to probes exactly as before.
//
// DROP KILLS THE WHOLE PROCESS GROUP, NOT JUST THE DIRECT CHILD. The pty
// child calls `setsid()` before it execs (portable-pty's own unix spawn
// path), so its pid is also its own process group id. portable-pty's default
// `Child::kill` only sends the direct pid a SIGHUP — measured against the
// embedding spike: killing just that pid left a grandchild still holding the
// pipe open, so the pty never saw EOF and the reader thread never exited.
// Sending the SIGNAL TO THE NEGATIVE PID reaches the whole group in one call,
// the same effect as a shell's `kill -- -$pid`.

use std::io::{self, Read, Write};
use std::sync::{Arc, Mutex};
use std::thread;

use portable_pty::{native_pty_system, Child, CommandBuilder, MasterPty, PtySize};

pub struct Pane {
    parser: Arc<Mutex<vt100::Parser>>,
    // WRITER BEHIND A MUTEX SO `send` CAN TAKE `&self`. The pty's own
    // writer half needs `&mut` to write; the brief's own contract for this
    // struct is `send(&self, ...)`, matched here by making the mutability
    // interior rather than requiring every caller to hold `&mut Pane`.
    writer: Mutex<Box<dyn Write + Send>>,
    master: Box<dyn MasterPty + Send>,
    child: Box<dyn Child + Send + Sync>,
}

impl Pane {
    /// Spawns `argv` into a fresh 24x80 pty. See `spawn_sized` for a caller
    /// that knows the real terminal size up front (main.rs, once attached).
    pub fn spawn(argv: &[String]) -> io::Result<Pane> {
        Self::spawn_sized(argv, 24, 80)
    }

    pub fn spawn_sized(argv: &[String], rows: u16, cols: u16) -> io::Result<Pane> {
        let (prog, rest) = argv.split_first().ok_or_else(|| {
            io::Error::new(
                io::ErrorKind::InvalidInput,
                "Pane::spawn needs at least one argv element",
            )
        })?;

        let pty_system = native_pty_system();
        let pair = pty_system
            .openpty(PtySize {
                rows,
                cols,
                pixel_width: 0,
                pixel_height: 0,
            })
            .map_err(to_io_err)?;

        let mut cmd = CommandBuilder::new(prog);
        cmd.args(rest);
        let child = pair.slave.spawn_command(cmd).map_err(to_io_err)?;
        // The slave end is only needed to spawn the child; this side reads
        // and writes through the master from here on, so there is nothing
        // left for the slave handle to do but hold an fd open.
        drop(pair.slave);

        let mut reader = pair.master.try_clone_reader().map_err(to_io_err)?;
        let writer = pair.master.take_writer().map_err(to_io_err)?;

        let parser = Arc::new(Mutex::new(vt100::Parser::new(rows, cols, 0)));
        let reader_parser = Arc::clone(&parser);
        thread::spawn(move || {
            let mut buf = [0u8; 4096];
            loop {
                match reader.read(&mut buf) {
                    Ok(0) => break, // EOF: the child (or the whole group) is gone.
                    Ok(n) => {
                        if let Ok(mut p) = reader_parser.lock() {
                            p.process(&buf[..n]);
                        }
                    }
                    // A read error means the master side is no longer
                    // usable (the child exited and the pty was torn down);
                    // there is nothing left to read, so the thread ends
                    // rather than spin.
                    Err(_) => break,
                }
            }
        });

        Ok(Pane {
            parser,
            writer: Mutex::new(writer),
            master: pair.master,
            child,
        })
    }

    /// A snapshot of the current screen, for `tui_term::widget::PseudoTerminal`
    /// to render. `vt100::Screen` is `Clone`, so this hands back an owned
    /// value rather than a guard the caller would have to hold across a
    /// frame — the render path never blocks the reader thread for longer
    /// than the clone itself takes.
    pub fn screen(&self) -> vt100::Screen {
        self.parser
            .lock()
            .unwrap_or_else(|poison| poison.into_inner())
            .screen()
            .clone()
    }

    /// Sends raw bytes to the child, as if typed at the pty.
    pub fn send(&self, bytes: &[u8]) {
        if let Ok(mut w) = self.writer.lock() {
            let _ = w.write_all(bytes);
            let _ = w.flush();
        }
    }

    /// Tells the kernel AND the parser about a terminal resize. Both must
    /// change together: the kernel side is what delivers SIGWINCH to the
    /// child, and the parser side is what keeps `screen()` the right shape
    /// for the frame ratatui is about to draw.
    pub fn resize(&self, rows: u16, cols: u16) {
        let _ = self.master.resize(PtySize {
            rows,
            cols,
            pixel_width: 0,
            pixel_height: 0,
        });
        if let Ok(mut p) = self.parser.lock() {
            p.set_size(rows, cols);
        }
    }
}

impl Drop for Pane {
    fn drop(&mut self) {
        if let Some(pid) = self.child.process_id() {
            // SAFETY: `kill(2)` with a negative pid signals the whole
            // process group. The child called `setsid()` before it exec'd
            // (portable-pty's own unix spawn path), so its pid IS that
            // group's id — this reaches any grandchild the direct child
            // spawned too, not just the direct child itself.
            unsafe {
                libc::kill(-(pid as i32), libc::SIGKILL);
            }
        }
        // Reap: without wait(), a killed child stays a zombie — still
        // visible to `kill(pid, 0)` — until something collects its exit
        // status. Dropping the Pane must leave no trace an operator (or a
        // test) could mistake for the child still being alive.
        let _ = self.child.wait();
    }
}

fn to_io_err(e: anyhow::Error) -> io::Error {
    io::Error::new(io::ErrorKind::Other, e.to_string())
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::time::{Duration, Instant};

    // NO TMUX IN THIS SUITE. Feeding known bytes straight to a `vt100::Parser`
    // is the spec's own testability rule: proving an escape sequence renders
    // needs no live multiplexer, and this crate's socket guard (the estate's
    // kokpit-socketvakt.test.sh) forbids the real thing outright.
    #[test]
    fn the_parser_renders_plain_text() {
        let mut p = vt100::Parser::new(5, 20, 0);
        p.process(b"hello");
        let first_row = p.screen().contents().lines().next().unwrap_or("").to_string();
        assert_eq!(first_row.trim_end(), "hello");
    }

    #[test]
    fn an_escape_sequence_moves_the_cursor_not_prints_itself() {
        let mut p = vt100::Parser::new(5, 20, 0);
        // CUP: move to row 3, col 5 (1-indexed in the escape, 0-indexed in
        // vt100's own cell coordinates), then print "hi".
        p.process(b"\x1b[3;5Hhi");
        let screen = p.screen();
        assert_eq!(screen.cell(2, 4).and_then(|c| c.contents().chars().next()), Some('h'));
        // THE ESCAPE ITSELF MUST NOT APPEAR AS TEXT — a parser that failed to
        // recognize CUP would print the literal bytes instead of moving the
        // cursor.
        let contents = screen.contents();
        assert!(!contents.contains('\x1b'));
        assert!(!contents.contains("[3;5H"));
    }

    // spawn() IS EXERCISED AGAINST A HARMLESS COMMAND, NEVER TMUX — the
    // socket guard forbids the real multiplexer in this suite, and spawn's
    // whole contract ("run argv in a pty, stream its output") is provable
    // with any argv at all.
    #[test]
    fn spawn_streams_a_commands_output_through_the_pty() {
        let pane = Pane::spawn(&[
            "bash".to_string(),
            "-c".to_string(),
            "printf hi".to_string(),
        ])
        .expect("spawn should succeed");

        let deadline = Instant::now() + Duration::from_secs(5);
        let mut seen = String::new();
        while Instant::now() < deadline {
            seen = pane.screen().contents();
            if seen.contains("hi") {
                break;
            }
            thread::sleep(Duration::from_millis(20));
        }
        assert!(seen.contains("hi"), "expected \"hi\" on screen, got: {seen:?}");
    }

    #[test]
    fn dropping_the_pane_kills_the_child() {
        let pane = Pane::spawn(&["bash".to_string(), "-c".to_string(), "sleep 30".to_string()])
            .expect("spawn should succeed");
        let pid = pane.child.process_id().expect("a pid");

        drop(pane);

        // kill(pid, 0) sends no signal; it only reports whether the pid
        // could be signaled at all. A gone-and-reaped process answers
        // ESRCH — this is the assertion, not a sleep-and-hope: it polls
        // briefly only because SIGKILL delivery and reaping are not
        // instantaneous across a thread boundary.
        let deadline = Instant::now() + Duration::from_secs(5);
        let mut alive = true;
        while Instant::now() < deadline {
            alive = unsafe { libc::kill(pid as i32, 0) } == 0;
            if !alive {
                break;
            }
            thread::sleep(Duration::from_millis(20));
        }
        assert!(!alive, "child pid {pid} should be gone after Pane::drop");
    }
}
