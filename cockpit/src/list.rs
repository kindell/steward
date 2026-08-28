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

    // ACCOUNTING LINES GO FIRST. `Paragraph` clips at `area.height` with no
    // marker, and whatever is pushed last is the first casualty of a short
    // area — the live fleet is already taller than a typical terminal. Putting
    // hidden/unreadable ahead of the session rows is what keeps them on screen
    // when something has to give.

    // C1: UNREADABLE NAMES ARE MEANT TO BE SEEN, unlike `hidden` — they are
    // faults the operator must fix, not a rule's quiet withholding. Dropping
    // them renders the remaining fleet as clean and complete, which is the
    // failure the client-spec was written against.
    if !f.unreadable.is_empty() {
        lines.push(format!(
            "(!) {} unreadable: {}",
            f.unreadable.len(),
            f.unreadable.join(" ")
        ));
    }

    if f.hidden > 0 {
        lines.push(format!("({} session(s) not visible to you)", f.hidden));
    }

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
        let mut row = format!(
            "{:<28} {:<10} {} {:<9} {:<10} {}",
            s.name, s.owner, m, s.liveness.tmux, s.liveness.agent, assets
        );
        // I3: A REASON IS RENDERED WHEN THE ENGINE GAVE ONE, visibly tied to
        // the row it explains. An `unknown` without a reason is the same
        // silence the model was built to make impossible.
        if let Some(reason) = &s.liveness.reason {
            row.push(' ');
            row.push_str(reason);
        }
        lines.push(row);
    }

    // I2: A TOO-SHORT AREA GETS A MARKER, NOT SILENT CLIPPING. `Paragraph`
    // would otherwise drop the tail with no sign anything was cut — which
    // looks exactly like a fleet that happened to be short.
    let height = area.height as usize;
    if height > 0 && lines.len() > height {
        let overflow = lines.len() - (height - 1);
        lines.truncate(height - 1);
        lines.push(format!("… {overflow} more row(s)"));
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

    // C1: UNREADABLE IS A FAULT THE OPERATOR MUST FIX, not a rule's quiet
    // withholding like `hidden` — so unlike hidden, these names are *meant* to
    // be seen. A view that parsed `unreadable` and never rendered it would
    // show the remaining fleet as clean and complete, which is the exact
    // failure the client-spec names.
    #[test]
    fn unreadable_names_are_on_screen() {
        let f = Fleet { sessions: vec![], hidden: 0, unreadable: vec!["broken-a".into(), "broken-b".into()] };
        let out = draw(&f);
        assert!(out.contains("broken-a"), "unreadable name missing:\n{out}");
        assert!(out.contains("broken-b"), "unreadable name missing:\n{out}");
        assert!(out.contains('2'), "unreadable count missing:\n{out}");
    }

    #[test]
    fn an_empty_unreadable_list_does_not_shout() {
        let f = fleet(vec![sess("alpha", &[], "up", None)], 0);
        let out = draw(&f);
        assert!(!out.contains("unreadable"), "should stay quiet with no unreadable:\n{out}");
    }

    // I2: TRUNCATION EATS THE HIDDEN LINE FIRST, because `Paragraph` clips at
    // `area.height` with no marker and the hidden line was pushed last. Live
    // at today's 21-line fleet in a 20-row area. The accounting lines must
    // survive truncation by being drawn first, not last.
    fn draw_in(f: &Fleet, width: u16, height: u16) -> String {
        let mut t = Terminal::new(TestBackend::new(width, height)).unwrap();
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

    #[test]
    fn the_hidden_line_survives_a_too_short_area() {
        // 20 sessions + a hidden line, drawn into an area only 20 rows tall —
        // the live shape measured on today's fleet.
        let sessions: Vec<Session> = (0..20)
            .map(|i| sess(&format!("s{i}"), &[], "up", None))
            .collect();
        let f = fleet(sessions, 1);
        let out = draw_in(&f, 60, 20);
        assert!(out.contains("not visible"), "hidden line was clipped:\n{out}");
    }

    #[test]
    fn an_overflow_marker_names_the_hidden_row_count() {
        let sessions: Vec<Session> = (0..25)
            .map(|i| sess(&format!("s{i}"), &[], "up", None))
            .collect();
        let f = fleet(sessions, 0);
        let out = draw_in(&f, 60, 10);
        assert!(out.contains("more"), "no overflow marker in a clipped area:\n{out}");
    }

    #[test]
    fn nothing_changes_when_everything_fits() {
        let f = fleet(vec![sess("alpha", &[], "up", None)], 0);
        let out = draw_in(&f, 60, 10);
        assert!(!out.contains("more"), "an overflow marker appeared when nothing overflowed:\n{out}");
    }

    // I3: `liveness.reason` IS DROPPED. All 20 live sessions carry
    // `reason: "seam-not-configured"` and render as bare "unknown unknown"
    // with no why. An `unknown` without a reason is the same silence the
    // model was built to make impossible.
    #[test]
    fn a_reason_is_shown_beside_the_row_it_explains() {
        // Wide enough that the owner column and the reason both survive the
        // row without being clipped by the area width.
        let out = draw_in(
            &fleet(
                vec![sess("alpha", &[], "unknown", Some("seam-not-configured"))],
                0,
            ),
            100,
            10,
        );
        let row = out.lines().find(|l| l.contains("alpha")).unwrap_or("");
        assert!(row.contains("seam-not-configured"), "reason missing from row: {row}");
    }

    #[test]
    fn no_reason_means_no_trailing_noise() {
        let out = draw_in(&fleet(vec![sess("alpha", &[], "up", None)], 0), 100, 10);
        let row = out.lines().find(|l| l.contains("alpha")).unwrap_or("");
        // No reason attached, and nothing in mark.rs's vocabulary looks like one.
        assert!(!row.contains("seam"), "unexpected reason noise: {row}");
    }

    // F6: THE OWNER COLUMN. On a two-person estate the owner is how you tell
    // whose session it is — the spec's team-level table names it alongside
    // liveness and assets.
    #[test]
    fn the_owner_appears_in_the_row() {
        let s = Session {
            name: "alpha".into(),
            owner: "jon".into(),
            host: "h".into(),
            assets: vec![],
            liveness: Liveness {
                tmux: "up".into(),
                agent: "running".into(),
                model: None,
                reason: None,
            },
        };
        let out = draw_in(&fleet(vec![s], 0), 100, 10);
        let row = out.lines().find(|l| l.contains("alpha")).unwrap_or("");
        assert!(row.contains("jon"), "owner missing from row: {row}");
    }
}
