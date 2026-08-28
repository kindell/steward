mod app;
mod engine;
mod inspector;
mod list;
mod mark;
mod probe;

// cockpit/src/main.rs — where the cockpit starts.
//
// WHY THIS EXISTS AT ALL. The engine answers `steward sessions --json` with the
// whole fleet, and until now the only way to look at it was a shell loop
// written by hand. This binary is the view.
//
// IT IS DELIBERATELY THIN. Reading the engine belongs to engine.rs, deciding a
// mark belongs to mark.rs, drawing the list belongs to list.rs, drawing the
// detail panel belongs to inspector.rs, keyboard/probe state belongs to
// app.rs, asking the fleet belongs to probe.rs. Everything this file knows is
// how to put them in order and keep the loop alive — which is what keeps each
// of the others testable without a terminal.
//
// THE SPLIT IS 60/40, LIST LEFT. The list's row format is the wider of the
// two (name, owner, mark, tmux, agent, assets all on one line); the
// inspector reads down a narrower column of labeled fields. A simple
// percentage split, not a measured one — either panel still says something
// honest at odd terminal widths, it just wraps.
//
// THE CHANNEL IS NEVER BLOCKING-READ IN THE DRAW PATH. `try_recv` drains
// whatever has arrived since the last frame and returns immediately either
// way; a `recv` here would freeze the whole picture — keys included — behind
// whichever probe is still in flight, defeating the one thing this plan
// exists to prove: the list stays alive while sessions answer around it.

use app::{App, handle_key, apply_probe};
use ratatui::crossterm::event::{self, Event};
use ratatui::crossterm::terminal::{disable_raw_mode, enable_raw_mode};
use ratatui::layout::{Constraint, Direction, Layout};
use ratatui::{Terminal, backend::CrosstermBackend};
use std::io::stdout;
use std::time::Duration;

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

fn main() {
    let fleet = match engine::read_fleet(&engine_cmd()) {
        Ok(f) => f,
        Err(e) => {
            // A FAILURE TO READ IS NOT AN EMPTY FLEET, and it must not be drawn
            // as one. Say it on stderr and exit non-zero.
            eprintln!("cockpit: {e}");
            std::process::exit(70);
        }
    };

    let mut app = App::new(fleet);

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

    if enable_raw_mode().is_err() {
        eprintln!("cockpit: this needs a terminal");
        std::process::exit(69);
    }
    let mut term = match Terminal::new(CrosstermBackend::new(stdout())) {
        Ok(t) => t,
        Err(e) => {
            let _ = disable_raw_mode();
            eprintln!("cockpit: {e}");
            std::process::exit(70);
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

    loop {
        // I4: THE ONE ACTION THIS PROGRAM EXISTS FOR gets its error handled
        // like every other failure here — not discarded. `cockpit | head -1`
        // reaches this via EPIPE (Rust ignores SIGPIPE), and a discarded draw
        // error exits 0 as if nothing happened, which is exactly the silence
        // this whole system refuses everywhere else.
        let drawn = term.draw(|frame| {
            let cols = Layout::default()
                .direction(Direction::Horizontal)
                .constraints([Constraint::Percentage(60), Constraint::Percentage(40)])
                .split(frame.area());
            list::render_list(&app.fleet, app.selected, &app.probes, cols[0], frame.buffer_mut());
            let selected = app.fleet.sessions.get(app.selected);
            let probe = selected.and_then(|s| app.probes.get(&s.name));
            inspector::render_inspector(selected, probe, cols[1], frame.buffer_mut());
        });
        if let Err(e) = drawn {
            let _ = disable_raw_mode();
            eprintln!("cockpit: {e}");
            std::process::exit(70);
        }

        // A SHORT POLL, NOT A BLOCKING READ. 50ms is short enough that a
        // probe landing mid-wait shows up on the next frame without the
        // operator noticing the delay, and long enough not to spin the CPU.
        match event::poll(Duration::from_millis(50)) {
            Ok(true) => {
                if let Ok(Event::Key(key)) = event::read() {
                    handle_key(&mut app, key.code);
                }
            }
            Ok(false) => {}
            Err(e) => {
                let _ = disable_raw_mode();
                eprintln!("cockpit: {e}");
                std::process::exit(70);
            }
        }

        // DRAIN WHATEVER HAS ARRIVED, NEVER WAIT FOR MORE. `try_recv`
        // returns immediately once the channel is empty; the loop's next
        // `event::poll` is what paces this program, not the prober.
        while let Ok((session, result)) = rx.try_recv() {
            apply_probe(&mut app, session, result);
        }

        if app.quit {
            break;
        }
    }

    let _ = disable_raw_mode();
}
