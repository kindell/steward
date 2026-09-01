// cockpit/src/inspector.rs — the detail panel for whatever row is selected.
//
// THE LIST CARRIES MARKS; THE INSPECTOR CARRIES WORDS. list.rs renders one
// glyph per asset because a row has no room for more — the mark answers only
// "did we measure this". This panel is where the rest of the answer lives:
// the status word a probe returned, the full detail string, and the reason a
// failed probe gave. Nothing here is new information the engine or the
// prober didn't already produce; this is where it finally gets spelled out.
//
// A PROBE RESULT CARRIES ONE ANSWER PER ASSET. probe.rs stopped folding a
// multi-asset answer into one status/detail pair — see probe.rs's
// `run_probe` — precisely because painting every declared asset with one
// shared status is false health: a session with one asset up and one down
// must not render as uniformly "up". Each line here looks up ITS OWN
// asset's answer by name in `ProbeResult::Answered`'s `Vec<AssetAnswer>`. A
// declared asset the probe did not individually answer for renders "not
// measured individually" — never a status copied from a different asset.
//
// EVERY CELL SAYS SOMETHING. No selection is a hint, not a blank screen; an
// absent field is a dash, not an empty column; a declared-but-unprobed asset
// says "probing", not nothing; a failed probe shows its reason, never just
// silence where a status word would have been. This is the same rule list.rs
// and mark.rs already follow, applied one level deeper.

use crate::app::{AssetAnswer, ProbeResult};
use crate::engine::Session;
use crate::mark::{asset_mark, mark_char, Mark};
use ratatui::buffer::Buffer;
use ratatui::layout::Rect;
use ratatui::widgets::{Paragraph, Widget};

// find_answer — the lookup this whole fix hinges on: a declared asset's
// answer by name, not by position. Looking these up positionally (asset 0
// gets answer 0) would silently misattribute the moment the probe's array
// and the session's declared order ever drifted apart; matching by name is
// what makes "each asset's own status" actually true.
fn find_answer<'a>(answers: &'a [AssetAnswer], asset: &str) -> Option<&'a AssetAnswer> {
    answers.iter().find(|a| a.asset == asset)
}

pub fn render_inspector(s: Option<&Session>, probe: Option<&ProbeResult>, area: Rect, buf: &mut Buffer) {
    let mut lines: Vec<String> = Vec::new();

    let s = match s {
        Some(s) => s,
        // NO SELECTION IS NOT AN EMPTY PANEL. A blank inspector would look
        // exactly like an inspector that failed to draw; a hint tells the
        // operator this is the expected, resting state.
        None => {
            lines.push("no session selected".to_string());
            lines.push("select a session in the list to inspect it".to_string());
            Paragraph::new(lines.join("\n")).render(area, buf);
            return;
        }
    };

    // IDENTITY. `engine::Session` carries name, owner and host as plain
    // `String`s — there is no `domain` or `entity` field on this struct to
    // dash out, so only what the struct actually holds is rendered here.
    // THE INSPECTOR NAMES ALL THREE, because this is where a person goes to
    // find out exactly which row they are looking at: the display they
    // recognise, the handle they address it by, and the opaque key everything
    // machine-side uses. A display alone is ambiguous by design.
    lines.push(s.label().to_string());
    if let Some(h) = s.slug.as_deref() {
        lines.push(format!("slug: {}", h));
    }
    if s.display.is_some() {
        lines.push(format!("id: {}", s.key()));
    }
    lines.push(format!("owner: {}", s.owner));
    lines.push(format!("host: {}", s.host));

    // LIVENESS. All four fields, always — `model` is the one that can be
    // absent, and absent renders as a dash, never a blank cell.
    lines.push("liveness:".to_string());
    lines.push(format!("  tmux: {}", s.liveness.tmux));
    lines.push(format!("  agent: {}", s.liveness.agent));
    lines.push(format!(
        "  model: {}",
        s.liveness.model.as_deref().unwrap_or("-")
    ));
    // THE REASON GETS ITS OWN LINE, when the engine gave one. Folding it
    // onto an existing line would let a short area's truncation swallow it
    // along with something else; its own line is also what makes it visible
    // as a distinct, named fact rather than a suffix.
    if let Some(reason) = &s.liveness.reason {
        lines.push(format!("  reason: {reason}"));
    }

    // ASSETS. Declaring nothing says so; a declared asset always gets a
    // line, whichever of the three probe states it is in.
    lines.push("assets:".to_string());
    if s.assets.is_empty() {
        lines.push("  no assets declared".to_string());
    } else {
        match probe {
            // MEASURED: each declared asset looks up ITS OWN answer by
            // name and gets its own word and detail — this is the word
            // `list.rs`'s `●` can only gesture at, and it must never be
            // one asset's word painted onto another asset's line.
            Some(ProbeResult::Answered { assets: answers }) => {
                for asset in &s.assets {
                    match find_answer(answers, asset) {
                        Some(ans) => {
                            let mark = mark_char(asset_mark(
                                std::slice::from_ref(asset),
                                Some(ans.status.as_str()),
                            ));
                            lines.push(format!(
                                "  {mark} {asset}: {} — {}",
                                ans.status, ans.detail
                            ));
                        }
                        // DECLARED BUT NOT ANSWERED FOR INDIVIDUALLY. The
                        // probe answered the session but not this asset by
                        // name — never fabricate a status by copying a
                        // different asset's word onto this line.
                        None => {
                            let mark = mark_char(Mark::Unmeasurable);
                            lines.push(format!("  {mark} {asset}: not measured individually"));
                        }
                    }
                }
            }
            // UNMEASURABLE: a failed probe is an answer, not a blank — the
            // reason is what `?` stands in for on the list, and here it is
            // spelled out.
            Some(ProbeResult::Failed { reason }) => {
                let mark = mark_char(Mark::Unmeasurable);
                for asset in &s.assets {
                    lines.push(format!("  {mark} {asset}: failed — {reason}"));
                }
            }
            // MEASURING: declared, no probe result back yet. The normal
            // state for the first moment of every run, not an edge case —
            // see mark.rs.
            None => {
                let mark = mark_char(asset_mark(&s.assets, None));
                for asset in &s.assets {
                    lines.push(format!("  {mark} {asset}: probing..."));
                }
            }
        }
    }

    Paragraph::new(lines.join("\n")).render(area, buf);
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::engine::Liveness;
    use ratatui::backend::TestBackend;
    use ratatui::Terminal;

    #[allow(clippy::too_many_arguments)]
    fn sess(
        name: &str,
        owner: &str,
        host: &str,
        assets: &[&str],
        tmux: &str,
        agent: &str,
        model: Option<&str>,
        reason: Option<&str>,
    ) -> Session {
        Session {
            name: name.into(),
            slug: None,
            display: None,
            owner: owner.into(),
            host: host.into(),
            assets: assets.iter().map(|s| s.to_string()).collect(),
            liveness: Liveness {
                tmux: tmux.into(),
                agent: agent.into(),
                model: model.map(|m| m.to_string()),
                reason: reason.map(|r| r.to_string()),
            },
        }
    }

    // NO TTY. Same draw-into-a-buffer pattern as list.rs's tests.
    fn draw(s: Option<&Session>, probe: Option<&ProbeResult>) -> String {
        let mut t = Terminal::new(TestBackend::new(60, 20)).unwrap();
        t.draw(|frame| render_inspector(s, probe, frame.area(), frame.buffer_mut()))
            .unwrap();
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

    // IDENTITY: owner and host are plain `String`s on `engine::Session`, so
    // they are always present. The one identity-adjacent field that can be
    // absent is `liveness.model`, and absent must render as a dash, never a
    // blank cell.
    #[test]
    fn identity_fields_are_shown_with_dashes_for_absent() {
        let s = sess("alpha", "alice", "host-1", &[], "up", "running", None, None);
        let out = draw(Some(&s), None);
        assert!(out.contains("alpha"), "name missing:\n{out}");
        assert!(out.contains("alice"), "owner missing:\n{out}");
        assert!(out.contains("host-1"), "host missing:\n{out}");
        assert!(
            out.contains("model: -"),
            "an absent model must render as a dash, not a blank:\n{out}"
        );
    }

    #[test]
    fn the_liveness_reason_gets_its_own_line() {
        let s = sess(
            "alpha",
            "alice",
            "host-1",
            &[],
            "unknown",
            "unknown",
            None,
            Some("seam-not-configured"),
        );
        let out = draw(Some(&s), None);
        assert!(
            out.contains("seam-not-configured"),
            "the reason must be visible:\n{out}"
        );
        let reason_line = out
            .lines()
            .find(|l| l.contains("seam-not-configured"))
            .unwrap();
        assert!(
            !reason_line.contains("tmux") && !reason_line.contains("agent"),
            "the reason must sit on its own line, not folded onto another field's line: {reason_line:?}"
        );
    }

    #[test]
    fn a_probed_asset_shows_word_and_full_detail() {
        let s = sess("alpha", "alice", "host-1", &["rig"], "up", "running", None, None);
        let probe = ProbeResult::Answered {
            assets: vec![AssetAnswer {
                asset: "rig".to_string(),
                status: "up".to_string(),
                detail: "vnc:1 cdp:2".to_string(),
            }],
        };
        let out = draw(Some(&s), Some(&probe));
        assert!(out.contains("up"), "status word missing:\n{out}");
        assert!(out.contains("vnc:1 cdp:2"), "full detail missing:\n{out}");
    }

    // THE DISCRIMINATOR THE REVIEWER FOUND MISSING: two assets with
    // DIFFERENT statuses must each show THEIR OWN word on THEIR OWN line.
    // A copy-first bug (every line painted with the first asset's status)
    // must fail this test.
    #[test]
    fn two_assets_with_differing_statuses_each_show_their_own_word() {
        let s = sess(
            "alpha",
            "alice",
            "host-1",
            &["rig1", "rig2"],
            "up",
            "running",
            None,
            None,
        );
        let probe = ProbeResult::Answered {
            assets: vec![
                AssetAnswer {
                    asset: "rig1".to_string(),
                    status: "up".to_string(),
                    detail: "reachable".to_string(),
                },
                AssetAnswer {
                    asset: "rig2".to_string(),
                    status: "down".to_string(),
                    detail: "refused".to_string(),
                },
            ],
        };
        let out = draw(Some(&s), Some(&probe));
        let rig1_line = out.lines().find(|l| l.contains("rig1")).expect("rig1 line missing");
        let rig2_line = out.lines().find(|l| l.contains("rig2")).expect("rig2 line missing");
        assert!(
            rig1_line.contains("up") && rig1_line.contains("reachable"),
            "rig1 must show its own status and detail: {rig1_line:?}"
        );
        assert!(
            rig2_line.contains("down") && rig2_line.contains("refused"),
            "rig2 must show its own status and detail: {rig2_line:?}"
        );
        assert!(
            !rig2_line.contains("reachable"),
            "rig2 must not carry rig1's detail: {rig2_line:?}"
        );
        assert!(
            !rig1_line.contains("refused") && !rig1_line.contains("down"),
            "rig1 must not carry rig2's status or detail: {rig1_line:?}"
        );
    }

    // A DECLARED ASSET THE PROBE DID NOT ANSWER FOR INDIVIDUALLY must say
    // so honestly — never fall back to a copied status from a different
    // asset in the same answer.
    #[test]
    fn an_asset_without_its_own_answer_says_not_measured_individually() {
        let s = sess(
            "alpha",
            "alice",
            "host-1",
            &["rig1", "rig2"],
            "up",
            "running",
            None,
            None,
        );
        let probe = ProbeResult::Answered {
            assets: vec![AssetAnswer {
                asset: "rig1".to_string(),
                status: "up".to_string(),
                detail: "reachable".to_string(),
            }],
        };
        let out = draw(Some(&s), Some(&probe));
        let rig2_line = out.lines().find(|l| l.contains("rig2")).expect("rig2 line missing");
        assert!(
            rig2_line.contains("not measured individually"),
            "rig2 must say it was not answered for: {rig2_line:?}"
        );
        assert!(
            !rig2_line.contains("up") && !rig2_line.contains("reachable"),
            "rig2 must not copy rig1's status or detail: {rig2_line:?}"
        );
    }

    #[test]
    fn a_failed_probe_shows_the_reason_not_a_blank() {
        let s = sess("alpha", "alice", "host-1", &["rig"], "up", "running", None, None);
        let probe = ProbeResult::Failed {
            reason: "timed out".to_string(),
        };
        let out = draw(Some(&s), Some(&probe));
        assert!(out.contains("timed out"), "the failure reason must be visible:\n{out}");
    }

    #[test]
    fn an_unprobed_asset_says_probing() {
        let s = sess("alpha", "alice", "host-1", &["rig"], "up", "running", None, None);
        let out = draw(Some(&s), None);
        assert!(
            out.contains("probing"),
            "a declared, unprobed asset must say it is probing, never blank:\n{out}"
        );
    }

    #[test]
    fn no_selection_renders_a_hint_not_emptiness() {
        let out = draw(None, None);
        assert!(
            out.trim().len() > 0,
            "no selection must render a hint, not an empty screen"
        );
        assert!(
            out.contains("select") || out.contains("no session"),
            "the hint should say something about there being no selection:\n{out}"
        );
    }

    // NOT IN THE BRIEF'S SIX-TEST CONTRACT, but the content rule it names
    // explicitly ("no assets declared -> say so") deserves its own case
    // rather than riding along inside another test.
    #[test]
    fn no_assets_declared_says_so() {
        let s = sess("alpha", "alice", "host-1", &[], "up", "running", None, None);
        let out = draw(Some(&s), None);
        assert!(
            out.contains("no assets declared"),
            "a session with nothing declared must say so, not render an empty assets block:\n{out}"
        );
    }
}
