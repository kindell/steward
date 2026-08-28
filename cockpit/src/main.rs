mod app;
mod engine;
mod inspector;
mod list;
mod mark;
mod pane;
mod probe;
mod terminal;
mod verb;

// cockpit/src/main.rs — where the cockpit starts.
//
// WHY THIS EXISTS AT ALL. The engine answers `steward sessions --json` with the
// whole fleet, and until now the only way to look at it was a shell loop
// written by hand. This binary is the view.
//
// IT IS DELIBERATELY THIN. Reading the engine belongs to engine.rs, deciding a
// mark belongs to mark.rs, drawing the list belongs to list.rs, drawing the
// detail panel belongs to inspector.rs, keyboard/probe/mode state belongs to
// app.rs, asking the fleet belongs to probe.rs, the embedded session belongs
// to pane.rs, and the argv/ownership decisions belong to verb.rs. Everything
// this file knows is how to put them in order and keep the loop alive —
// which is what keeps each of the others testable without a terminal.
//
// THE SPLIT IS 60/40, LIST LEFT. The list's row format is the wider of the
// two (name, owner, mark, tmux, agent, assets all on one line); the
// inspector reads down a narrower column of labeled fields. A simple
// percentage split, not a measured one — either panel still says something
// honest at odd terminal widths, it just wraps.
//
// THE PROBE CHANNEL IS NEVER BLOCKING-READ IN THE DRAW PATH. `try_recv`
// drains whatever has arrived since the last frame and returns immediately
// either way; a `recv` here would freeze the whole picture — keys included —
// behind whichever probe is still in flight, defeating the one thing this
// plan exists to prove: the list stays alive while sessions answer around
// it. This still holds with a pane attached — `pane::Pane` runs its OWN
// reader thread behind its own Mutex (see pane.rs's module doc for why that
// one is not a second channel), so a probe landing while attached is drained
// exactly the same way it was in Browsing.
//
// TWO MODES, ONE LOOP. Browsing draws the list and the inspector, same as
// every earlier plan. Attached draws the embedded pane instead and routes
// every key but the detach chord into it. `pane` (the `Option<pane::Pane>`
// below `app`) is owned here, not on `App`, because spawning and killing a
// real process is an I/O side effect main.rs already owns everywhere else —
// app.rs decides the MODE (pure, testable), main.rs decides what runs.

use app::{apply_probe, handle_key, App, Mode, DETACH_HINT};
use ratatui::crossterm::event::{self, Event, KeyEvent, KeyEventKind, KeyModifiers};
use ratatui::layout::{Constraint, Direction, Layout};
use ratatui::style::{Color, Style};
use ratatui::text::Line;
use ratatui::widgets::{Paragraph, Widget};
use std::io;
use std::process::ExitCode;
use std::time::Duration;
use tui_term::widget::PseudoTerminal;
use verb::AttachMode;

// THE ENGINE COMMAND IS CONFIGURABLE and defaults to the real one. The suite
// never reaches this function — it tests the modules beneath it — but a
// default that led nowhere would make the binary useless without a wrapper.
fn engine_cmd() -> String {
    std::env::var("COCKPIT_ENGINE_CMD")
        .unwrap_or_else(|_| "steward sessions --json".to_string())
}

// THE PROBE COMMAND IS CONFIGURABLE THE SAME WAY, same reasoning as
// `engine_cmd` — see probe.rs's module doc for the `{}` templating.
fn assets_cmd() -> String {
    std::env::var("COCKPIT_ASSETS_CMD")
        .unwrap_or_else(|_| "steward assets {} --json".to_string())
}

// THE TMUX BINARY IS CONFIGURABLE, same reasoning again — a suite (or an
// estate whose PATH does not carry `tmux`) aims this elsewhere; a real run
// defaults to whatever `tmux` resolves to on the account's PATH.
fn tmux_bin() -> String {
    std::env::var("COCKPIT_TMUX_BIN").unwrap_or_else(|_| "tmux".to_string())
}

// spawn_attached_pane — build the tmux argv through verb::attach_argv (which
// never omits `-S`) and hand it to pane::Pane::spawn_sized. Called ONLY after
// app.rs has already moved `app.mode` to `Attached`, which only happens once
// `verb::enter_allowed` has already said yes — this function trusts that
// decision rather than re-checking ownership itself.
fn spawn_attached_pane(app: &App) -> io::Result<pane::Pane> {
    let session = app.fleet.sessions.get(app.selected).ok_or_else(|| {
        io::Error::new(io::ErrorKind::NotFound, "no session is selected")
    })?;
    // NEVER A GUESSED SOCKET. Same rule verb::attach_argv itself enforces —
    // a bare `tmux attach` would fall back to the default socket, which on
    // the machine that runs the cockpit is the live one. STEWARD_TMUX_SOCKET
    // is therefore required, not defaulted: an unset variable means "this
    // caller has not told the cockpit which socket to use," and the honest
    // answer is a refusal, never a guess at the live path.
    let socket = std::env::var("STEWARD_TMUX_SOCKET").map_err(|_| {
        io::Error::new(
            io::ErrorKind::NotFound,
            "STEWARD_TMUX_SOCKET is not set — refusing to guess a socket",
        )
    })?;
    let mut argv = vec![tmux_bin()];
    argv.extend(verb::attach_argv(&socket, &session.name, AttachMode::Interactive));

    let (cols, rows) = ratatui::crossterm::terminal::size().unwrap_or((80, 24));
    pane::Pane::spawn_sized(&argv, rows, cols)
}

// key_to_bytes — translate a KeyEvent into the bytes a real terminal would
// have sent the pty for it. Covers the keys an interactive shell or a
// full-screen program actually reacts to; anything not recognized sends
// nothing rather than a guess that could corrupt the child's input stream.
fn key_to_bytes(key: KeyEvent) -> Vec<u8> {
    use ratatui::crossterm::event::KeyCode;
    match key.code {
        KeyCode::Char(c) if key.modifiers.contains(KeyModifiers::CONTROL) && c.is_ascii_alphabetic() => {
            // Ctrl-<letter> — the classic control-code mapping: 'a' (0x61)
            // and 'A' (0x41) both become 0x01, and so on through the
            // alphabet.
            vec![(c.to_ascii_uppercase() as u8) & 0x1f]
        }
        // Ctrl-4..Ctrl-7 ARE THE SAME BYTES AS Ctrl-\/]/^/_. Same ambiguity
        // app.rs's `is_detach` documents: without the kitty keyboard
        // protocol, crossterm reports the digit for control bytes 0x1C-0x1F
        // rather than the punctuation most people think of them as. '5' can
        // never reach here while attached — app.rs's detach chord consumes
        // it first — but '4', '6' and '7' still need the ORIGINAL control
        // byte forwarded (a program inside the pane bound to Ctrl-\ for
        // SIGQUIT expects 0x1C, not the printable digit '4').
        KeyCode::Char(c @ '4'..='7') if key.modifiers.contains(KeyModifiers::CONTROL) => {
            vec![c as u8 - b'4' + 0x1c]
        }
        KeyCode::Char(c) => {
            let mut buf = [0u8; 4];
            c.encode_utf8(&mut buf).as_bytes().to_vec()
        }
        KeyCode::Enter => vec![b'\r'],
        KeyCode::Backspace => vec![0x7f],
        KeyCode::Tab => vec![b'\t'],
        KeyCode::Esc => vec![0x1b],
        KeyCode::Up => b"\x1b[A".to_vec(),
        KeyCode::Down => b"\x1b[B".to_vec(),
        KeyCode::Right => b"\x1b[C".to_vec(),
        KeyCode::Left => b"\x1b[D".to_vec(),
        KeyCode::Home => b"\x1b[H".to_vec(),
        KeyCode::End => b"\x1b[F".to_vec(),
        KeyCode::PageUp => b"\x1b[5~".to_vec(),
        KeyCode::PageDown => b"\x1b[6~".to_vec(),
        KeyCode::Delete => b"\x1b[3~".to_vec(),
        _ => Vec::new(),
    }
}

fn main() -> ExitCode {
    let fleet = match engine::read_fleet(&engine_cmd()) {
        Ok(f) => f,
        Err(e) => {
            // A FAILURE TO READ IS NOT AN EMPTY FLEET, and it must not be drawn
            // as one. Say it on stderr and exit non-zero. This happens BEFORE
            // terminal::enter() — no terminal state has been touched yet, so
            // there is nothing for a guard to clean up.
            eprintln!("cockpit: {e}");
            return ExitCode::from(70);
        }
    };

    let mut app = App::new(fleet);
    // THE EMBEDDED SESSION, WHEN ONE IS ATTACHED. Lives here, not on `App` —
    // see this file's module doc. `None` in Browsing, always; `Some` only
    // while `app.mode` is `Attached`, and the two are kept in lockstep by
    // the loop below, never by a third place deciding independently.
    let mut pane: Option<pane::Pane> = None;

    // ONLY SESSIONS THAT DECLARE SOMETHING ARE PROBE-WORTHY. probe.rs's own
    // `run_probe` already turns a declares-nothing session into a `Failed`
    // rather than fabricate a status for zero measurements — sending one
    // into the queue at all would only pay a round trip for an answer this
    // program already knows without asking.
    let probing_sessions: Vec<String> = app
        .fleet
        .sessions
        .iter()
        .filter(|s| !s.assets.is_empty())
        .map(|s| s.name.clone())
        .collect();
    let rx = probe::spawn_prober(assets_cmd(), probing_sessions);

    // THE ONE PLACE RAW MODE, THE ALTERNATE SCREEN, AND THE CURSOR ARE
    // TOUCHED. terminal::enter() installs the panic hook before it changes
    // anything, AND restores on its own Err paths before returning — no
    // TerminalGuard exists yet here for a Drop to clean up with, so
    // enter() itself undoes whatever it managed to change. Exiting
    // directly on Err is therefore safe.
    let (_guard, mut term) = match terminal::enter() {
        Ok(v) => v,
        Err(e) => {
            eprintln!("cockpit: {e}");
            std::process::exit(69);
        }
    };
    // WITHOUT THIS, WHATEVER WAS ON SCREEN BEFORE (a shell prompt, a
    // previous program) BLEEDS THROUGH. `Terminal::draw` diffs against its
    // own internal buffer, which starts blank — it only writes cells that
    // differ from that internal record, not cells that differ from what the
    // physical terminal actually shows. A cell this program also wants blank
    // is never written at all, so old content sitting there stays. One
    // explicit clear before the first frame is what makes the picture honest
    // from frame one.
    let _ = term.clear();

    // THE EXIT CODE A LOOP ERROR EARNS. Defaults to success; a draw or poll
    // error downgrades it and requests quit, so the loop still exits through
    // its one normal path — `_guard` drops on the way out of `main` either
    // way, there is no second teardown to keep in sync with this one.
    let mut exit_code = ExitCode::SUCCESS;

    loop {
        // I4: THE ONE ACTION THIS PROGRAM EXISTS FOR gets its error handled
        // like every other failure here — not discarded. `cockpit | head -1`
        // reaches this via EPIPE (Rust ignores SIGPIPE), and a discarded draw
        // error exits 0 as if nothing happened, which is exactly the silence
        // this whole system refuses everywhere else.
        let drawn = term.draw(|frame| {
            let rows = Layout::default()
                .direction(Direction::Vertical)
                .constraints([Constraint::Min(0), Constraint::Length(1)])
                .split(frame.area());
            let body = rows[0];
            let status = rows[1];

            match app.mode {
                Mode::Browsing => {
                    let cols = Layout::default()
                        .direction(Direction::Horizontal)
                        .constraints([Constraint::Percentage(60), Constraint::Percentage(40)])
                        .split(body);
                    list::render_list(
                        &app.fleet,
                        app.selected,
                        &app.probes,
                        cols[0],
                        frame.buffer_mut(),
                    );
                    let selected = app.fleet.sessions.get(app.selected);
                    let probe = selected.and_then(|s| app.probes.get(&s.name));
                    inspector::render_inspector(selected, probe, cols[1], frame.buffer_mut());
                }
                Mode::Attached => {
                    if let Some(p) = &pane {
                        let screen = p.screen();
                        PseudoTerminal::new(&screen).render(body, frame.buffer_mut());
                    }
                }
            }

            let status_line = match app.mode {
                // A REFUSAL OUTLIVES THE KEYPRESS THAT CAUSED IT — it stays
                // on screen until the next Enter clears it (app.rs's own
                // handle_key does that), so an operator who looked away for
                // a frame still sees why nothing happened.
                Mode::Browsing => app
                    .refusal
                    .clone()
                    .unwrap_or_else(|| "↑/↓ move   Enter attach   q quit".to_string()),
                Mode::Attached => DETACH_HINT.to_string(),
            };
            let style = if app.mode == Mode::Browsing && app.refusal.is_some() {
                Style::default().fg(Color::Red)
            } else {
                Style::default()
            };
            Paragraph::new(Line::styled(status_line, style)).render(status, frame.buffer_mut());
        });
        if let Err(e) = drawn {
            eprintln!("cockpit: {e}");
            exit_code = ExitCode::from(70);
            app.quit = true;
        }

        // A SHORT POLL, NOT A BLOCKING READ. 50ms is short enough that a
        // probe landing mid-wait shows up on the next frame without the
        // operator noticing the delay, and long enough not to spin the CPU.
        // Skipped once a draw error above already requested quit — there is
        // no picture left worth taking more keys for.
        if !app.quit {
            match event::poll(Duration::from_millis(50)) {
                Ok(true) => match event::read() {
                    Ok(Event::Key(key)) => {
                        // KITTY KEYBOARD PROTOCOL CAN REPORT RELEASE (AND
                        // REPEAT) EVENTS ON TOP OF PRESS. Handling anything
                        // but Press would either double every keystroke sent
                        // to the child pty, or double every state change
                        // handle_key makes — filtered once, here, rather
                        // than taught to every caller downstream.
                        if key.kind == KeyEventKind::Press {
                            let was_attached = app.mode == Mode::Attached;
                            handle_key(&mut app, key);
                            if was_attached {
                                if app.mode == Mode::Attached {
                                    // Still attached: this key was not the
                                    // detach chord, so it belongs to the
                                    // child, not to this program's own state.
                                    if let Some(p) = &pane {
                                        let bytes = key_to_bytes(key);
                                        if !bytes.is_empty() {
                                            p.send(&bytes);
                                        }
                                    }
                                } else {
                                    // handle_key just detached. Dropping the
                                    // pane here kills the tmux CLIENT
                                    // process this pty was running, NOT the
                                    // session — the session keeps running on
                                    // the socket regardless of whether
                                    // anyone is attached to it.
                                    pane = None;
                                }
                            } else if app.mode == Mode::Attached {
                                // handle_key just moved INTO Attached — spawn
                                // the real pane now, having trusted the
                                // ownership decision app.rs already made.
                                match spawn_attached_pane(&app) {
                                    Ok(p) => pane = Some(p),
                                    Err(e) => {
                                        app.mode = Mode::Browsing;
                                        app.refusal = Some(format!("could not attach: {e}"));
                                    }
                                }
                            }
                        }
                    }
                    Ok(Event::Resize(cols, rows)) => {
                        if let Some(p) = &pane {
                            p.resize(rows, cols);
                        }
                        let _ = term.autoresize();
                    }
                    _ => {}
                },
                Ok(false) => {}
                Err(e) => {
                    eprintln!("cockpit: {e}");
                    exit_code = ExitCode::from(70);
                    app.quit = true;
                }
            }
        }

        // DRAIN WHATEVER HAS ARRIVED, NEVER WAIT FOR MORE. `try_recv`
        // returns immediately once the channel is empty; the loop's next
        // `event::poll` is what paces this program, not the prober. Drained
        // in BOTH modes — a probe can land while the operator is attached,
        // and the answer should be waiting in the inspector on detach, not
        // lost because Attached skipped the drain.
        while let Ok((session, result)) = rx.try_recv() {
            apply_probe(&mut app, session, result);
        }

        if app.quit {
            break;
        }
    }

    // `_guard` drops here, restoring raw mode, the alternate screen and the
    // cursor in one place regardless of which path through the loop above
    // set `exit_code`. `pane` (if any) drops right after, killing whatever
    // tmux client it was still running — after the terminal is already
    // restored, which is fine: `Pane::drop` only signals processes, it never
    // touches stdio, so the order between the two guards does not matter.
    exit_code
}
