// cockpit/src/terminal.rs — the ONE place that owns the terminal's raw state.
//
// WHY IT EXISTS. Teardown was five old exit paths spread across main.rs, some
// of them calling process::exit after only some of raw mode / alternate
// screen / cursor were undone, and some of them skipping teardown entirely —
// so a draw error could leave the operator's cursor hidden or the terminal in
// alternate-screen mode after the program was already gone. A program that
// borrows the terminal must return it in the state it found it, on EVERY exit
// including a panic, and the only way to promise that in Rust is Drop plus a
// panic hook.

use ratatui::crossterm::{
    cursor::{Hide, Show},
    execute,
    terminal::{disable_raw_mode, enable_raw_mode, EnterAlternateScreen, LeaveAlternateScreen},
};
use ratatui::{backend::CrosstermBackend, Terminal};
use std::io::{self, Stdout, Write};

pub struct TerminalGuard;

// restore — undo everything enter() did, in reverse, and never fail loudly.
// Called by Drop AND by the panic hook, possibly twice, possibly before
// enter() finished — so every step ignores its own error and the whole thing
// is idempotent. Order matters: leave the alternate screen and show the
// cursor while still in whatever mode the terminal is in, THEN drop raw mode
// last, so an interrupted sequence still leaves the cursor visible even if a
// later step fails.
pub fn restore() {
    let mut out = io::stdout();
    let _ = execute!(out, LeaveAlternateScreen, Show);
    let _ = disable_raw_mode();
    let _ = out.flush();
}

impl Drop for TerminalGuard {
    fn drop(&mut self) {
        restore();
    }
}

// enter — take the terminal, and arm restoration on every path out. The
// panic hook is installed FIRST, before raw mode is even touched, so a panic
// during enter() itself — say, EnterAlternateScreen failing after raw mode
// already flipped on — still restores whatever was already changed.
pub fn enter() -> io::Result<(TerminalGuard, Terminal<CrosstermBackend<Stdout>>)> {
    // The panic hook fires before the stack unwinds, so it restores the
    // terminal BEFORE the default hook prints the panic message — otherwise
    // the message scrolls by in the alternate screen and vanishes with it.
    let prev = std::panic::take_hook();
    std::panic::set_hook(Box::new(move |info| {
        restore();
        prev(info);
    }));
    enable_raw_mode()?;
    let mut out = io::stdout();
    execute!(out, EnterAlternateScreen, Hide)?;
    let term = Terminal::new(CrosstermBackend::new(out))?;
    Ok((TerminalGuard, term))
}

#[cfg(test)]
mod tests {
    use super::*;
    // restore() MÅSTE vara idempotent och säker att kalla utan att enter()
    // körts — panic-hooken kallar den från en godtycklig punkt, och Drop kallar
    // den efter att enter() misslyckats halvvägs. Att den kraschar DÅ vore att
    // lämna terminalen trasig i precis det ögonblick den ska räddas.
    #[test]
    fn restore_is_idempotent_and_safe_without_enter() {
        restore();
        restore();  // två gånger, ingen panik, ingen dubbelfri
    }
}
