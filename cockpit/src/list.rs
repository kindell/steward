// cockpit/src/list.rs — the session list.
//
// IT KNOWS NOTHING ABOUT WHERE THE DATA CAME FROM. engine.rs read it, mark.rs
// decided the glyph; this draws. Keeping those apart is what lets the first two
// be tested without a terminal and this one without an estate.
//
// THE HIDDEN COUNT IS ON SCREEN WHEN IT IS NOT ZERO. The engine reports how many
// rows the visibility rule withheld, and a view that dropped that number would
// render a filtered fleet as a small one — the same silence, one layer up. At
// zero it stays quiet, because a line that always says "0 hidden" is noise and
// noise is what people learn to stop reading.

use crate::engine::Fleet;
use crate::mark::{asset_mark, mark_char};
use ratatui::buffer::Buffer;
use ratatui::layout::Rect;
use ratatui::widgets::{Paragraph, Widget};

pub fn render_list(f: &Fleet, area: Rect, buf: &mut Buffer) {
    let mut lines: Vec<String> = Vec::new();

    if f.sessions.is_empty() {
        // AN EMPTY FLEET IS AN ANSWER. A blank screen would look exactly like a
        // view that failed to draw.
        lines.push("no sessions visible".to_string());
    }

    for s in &f.sessions {
        // NOTHING HAS PROBED YET IN THIS PLAN, so `None` is always what we pass.
        // Plan 2 is what starts handing a real status word in here.
        let m = mark_char(asset_mark(&s.assets, None));
        let assets = if s.assets.is_empty() {
            "—".to_string()
        } else {
            s.assets.join(" ")
        };
        lines.push(format!(
            "{:<28} {} {:<9} {:<10} {}",
            s.name, m, s.liveness.tmux, s.liveness.agent, assets
        ));
    }

    if f.hidden > 0 {
        lines.push(format!("({} session(s) not visible to you)", f.hidden));
    }

    Paragraph::new(lines.join("\n")).render(area, buf);
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::engine::{Fleet, Liveness, Session};
    use ratatui::backend::TestBackend;
    use ratatui::Terminal;

    fn sess(name: &str, assets: &[&str], tmux: &str, reason: Option<&str>) -> Session {
        Session {
            name: name.into(),
            owner: "o".into(),
            host: "h".into(),
            assets: assets.iter().map(|s| s.to_string()).collect(),
            liveness: Liveness {
                tmux: tmux.into(),
                agent: "running".into(),
                model: None,
                reason: reason.map(|s| s.to_string()),
            },
        }
    }

    // NO TTY. TestBackend draws into a buffer we can assert on, cell by cell —
    // which is the only way a view gets tested inside a suite at all.
    fn draw(f: &Fleet) -> String {
        let mut t = Terminal::new(TestBackend::new(60, 10)).unwrap();
        t.draw(|frame| render_list(f, frame.area(), frame.buffer_mut())).unwrap();
        let b = t.backend().buffer().clone();
        (0..b.area.height)
            .map(|y| {
                (0..b.area.width)
                    .map(|x| b[(x, y)].symbol().to_string())
                    .collect::<String>()
            })
            .collect::<Vec<_>>()
            .join("\n")
    }

    fn fleet(sessions: Vec<Session>, hidden: u32) -> Fleet {
        Fleet { sessions, hidden, unreadable: vec![] }
    }

    #[test]
    fn a_session_appears_with_its_name() {
        let out = draw(&fleet(vec![sess("alpha", &["rig"], "up", None)], 0));
        assert!(out.contains("alpha"), "got:\n{out}");
    }

    // THE TWO MARKS THAT ACTUALLY OCCUR IN THIS PLAN. Nothing probes yet, so a
    // declared asset renders as measuring and an undeclared one as its own dot.
    // Rendering either as a blank is the failure the spec opens by naming.
    #[test]
    fn declared_and_undeclared_get_different_marks() {
        let out = draw(&fleet(
            vec![
                sess("declares", &["rig"], "up", None),
                sess("declares-not", &[], "up", None),
            ],
            0,
        ));
        let declared = out.lines().find(|l| l.contains("declares ")).unwrap_or("");
        let undeclared = out.lines().find(|l| l.contains("declares-not")).unwrap_or("");
        assert!(declared.contains('◌'), "declared row: {declared}");
        assert!(undeclared.contains('·'), "undeclared row: {undeclared}");
    }

    // SEEING LESS MUST SHOW. The engine reports how many rows it withheld; a
    // view that dropped that number would render a filtered fleet as a small
    // one, which is the same silence one layer up.
    #[test]
    fn the_hidden_count_is_on_screen() {
        let out = draw(&fleet(vec![sess("alpha", &[], "up", None)], 4));
        assert!(out.contains('4'), "the hidden count is missing:\n{out}");
    }

    #[test]
    fn a_zero_hidden_count_does_not_shout() {
        let out = draw(&fleet(vec![sess("alpha", &[], "up", None)], 0));
        assert!(!out.contains("not visible"), "should stay quiet at zero:\n{out}");
    }

    // AN EMPTY FLEET IS NOT A BLANK SCREEN. Zero sessions and a broken engine
    // must not look alike, and the engine's own refusal is an Err handled
    // elsewhere — so this case is the honest one and it still says something.
    #[test]
    fn an_empty_fleet_says_so() {
        let out = draw(&fleet(vec![], 0));
        assert!(out.trim().len() > 0, "an empty fleet drew nothing at all");
    }
}
