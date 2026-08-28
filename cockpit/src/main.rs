mod app;
mod engine;
mod list;
mod mark;

// cockpit/src/main.rs — where the cockpit starts.
//
// WHY THIS EXISTS AT ALL. The engine answers `steward sessions --json` with the
// whole fleet, and until now the only way to look at it was a shell loop
// written by hand. This binary is the view.
//
// IT IS DELIBERATELY THIN. Reading the engine belongs to engine.rs, deciding a
// mark belongs to mark.rs, drawing belongs to list.rs. Everything this file
// knows is how to put them in order — which is what keeps each of the other
// three testable without a terminal.

use ratatui::crossterm::terminal::{disable_raw_mode, enable_raw_mode};
use ratatui::{Terminal, backend::CrosstermBackend};
use std::io::stdout;

// THE ENGINE COMMAND IS CONFIGURABLE and defaults to the real one. The suite
// never reaches this function — it tests the three modules beneath it — but a
// default that led nowhere would make the binary useless without a wrapper.
fn engine_cmd() -> String {
    std::env::var("COCKPIT_ENGINE_CMD")
        .unwrap_or_else(|_| "steward sessions --json".to_string())
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
    // I4: THE ONE ACTION THIS PROGRAM EXISTS FOR gets its error handled like
    // every other failure here — not discarded. `cockpit | head -1` reaches
    // this via EPIPE (Rust ignores SIGPIPE), and a discarded draw error exits
    // 0 as if nothing happened, which is exactly the silence this whole
    // system refuses everywhere else.
    if let Err(e) = term.draw(|frame| list::render_list(&fleet, frame.area(), frame.buffer_mut())) {
        let _ = disable_raw_mode();
        eprintln!("cockpit: {e}");
        std::process::exit(70);
    }
    let _ = disable_raw_mode();
}
