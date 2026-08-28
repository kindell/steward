// cockpit/src/app.rs — the state a keypress or a probe result changes.
//
// EVERYTHING ELSE IN THIS CRATE IS A PURE READ: engine.rs asks the fleet a
// question once, mark.rs and list.rs turn what came back into glyphs and text.
// Nothing so far remembers what happened a moment ago. An inspector needs
// that — which row is selected, and what each probe answered — and this file
// is where that memory lives. It stays a plain struct and two free functions
// on purpose: no thread, no terminal, no clock. A test drives it with a
// `KeyCode` and a `ProbeResult` the same way a real run would, and never
// needs a screen to do it.
//
// SELECTION SATURATES, IT DOES NOT WRAP. Wrapping from the last row back to
// the first teleports the eye across the whole list on a single keypress —
// exactly the moment an operator is not looking at the top of the screen.
// Saturating at the ends is the boring behavior a stressed operator can
// predict without looking.
//
// A PROBE RESULT BINDS TO THE SESSION IT ANSWERED FOR, NOT TO WHATEVER ROW IS
// SELECTED WHEN IT LANDS. Probes fly concurrently and the operator keeps
// moving while they are in flight; keying results by the selection would let
// a late answer for row 3 land on whatever the operator has scrolled to by
// the time it arrives. `probes` is keyed by session name for exactly that
// reason.
//
// A FAILED PROBE IS AN ANSWER, NOT A THING TO DISCARD. mark.rs already has a
// glyph for "we tried and could not tell" (`?`), and it renders beside the
// reason the probe gave. Dropping a `Failed` on the floor here would make
// that glyph a dead branch and turn a measured failure back into silence —
// the exact failure mode this whole system exists to refuse.

use crate::engine::Fleet;
use crossterm::event::KeyCode;
use std::collections::HashMap;

pub struct App {
    pub fleet: Fleet,
    pub selected: usize,
    pub probes: HashMap<String, ProbeResult>,
    pub quit: bool,
}

impl App {
    pub fn new(fleet: Fleet) -> App {
        App {
            fleet,
            selected: 0,
            probes: HashMap::new(),
            quit: false,
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum ProbeResult {
    Answered { assets: Vec<AssetAnswer> },
    Failed { reason: String },
}

// AssetAnswer — one asset's own status and detail. The prober used to fold
// several of these into a single status/detail pair on the ProbeResult
// itself ("first + N more"); that fold was the plan defect this type fixes.
// Every asset a session declares gets to answer for itself now.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct AssetAnswer {
    pub asset: String,
    pub status: String,
    pub detail: String,
}

// handle_key — the only place a keypress becomes a state change. `Up`/`Down`
// move the selection with saturation at both ends; `q` requests quit; every
// other key is ignored in silence, because later plans are what give those
// keys meaning, not this one inventing behavior for them early.
pub fn handle_key(app: &mut App, key: KeyCode) {
    match key {
        KeyCode::Down => {
            // AN EMPTY FLEET HAS NO LAST ROW TO SATURATE AT. `len() - 1` on a
            // zero-length vec underflows a usize, so the empty case is
            // checked first rather than folded into the arithmetic below.
            if !app.fleet.sessions.is_empty() && app.selected + 1 < app.fleet.sessions.len() {
                app.selected += 1;
            }
        }
        KeyCode::Up => {
            if app.selected > 0 {
                app.selected -= 1;
            }
        }
        KeyCode::Char('q') => {
            app.quit = true;
        }
        _ => {}
    }
}

// apply_probe — binds a result to the session name it answered for. A later
// result for the same session replaces the earlier one: a retry that
// succeeds must be able to overwrite a stored failure, and there is no
// third state to reconcile them into.
pub fn apply_probe(app: &mut App, session: String, r: ProbeResult) {
    app.probes.insert(session, r);
}

pub fn probe_for<'a>(app: &'a App, name: &str) -> Option<&'a ProbeResult> {
    app.probes.get(name)
}

// probe_status_word — the ONE word the list's single mark needs. mark.rs's
// own doc is explicit that the mark answers "did we measure this", never
// "what did we find" — so a session with several assets still only needs
// its FIRST answer's status here; the inspector (not this function) is
// where every asset gets its own word. Lives beside apply_probe/probe_for
// rather than in mark.rs on purpose: mark.rs's vocabulary is closed over
// `Mark` and plain status strings, and knows nothing about `ProbeResult` —
// keeping this here keeps that module free of the probe subsystem's shape.
//
// A Failed probe answers "unknown" — the same word mark.rs already treats
// as unmeasurable, because a failed probe measured nothing.
//
// JUDGMENT CALL — Answered with an EMPTY assets Vec: the prober itself
// never produces this (probe.rs's None arm turns zero declared assets into
// Failed before app.rs ever sees an Answered), but apply_probe does not
// require every caller to route through the prober, so the case is real.
// Returning None here would claim "still measuring" — a lie, since an
// answer already arrived, it just named nothing. The honest word is the
// same "unknown" a Failed uses: an answer naming zero measurements
// measured nothing either, and mark.rs already knows how to render
// "unknown" as unmeasurable rather than healthy.
pub fn probe_status_word(r: &ProbeResult) -> Option<&str> {
    match r {
        ProbeResult::Answered { assets } => match assets.first() {
            Some(a) => Some(a.status.as_str()),
            None => Some("unknown"),
        },
        ProbeResult::Failed { .. } => Some("unknown"),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::engine::{Liveness, Session};
    use crossterm::event::KeyCode;

    // BUILT FROM THE ENGINE'S OWN STRUCTS, not from a fixture json string —
    // this module never re-parses anything, so it constructs the shapes it
    // needs directly. Every session declares the same one asset; liveness is
    // left at "unknown" because nothing here reads it.
    fn fleet_of(names: &[&str]) -> Fleet {
        Fleet {
            sessions: names
                .iter()
                .map(|n| Session {
                    name: n.to_string(),
                    owner: "alice".to_string(),
                    host: "h".to_string(),
                    assets: vec!["x".to_string()],
                    liveness: Liveness {
                        tmux: "unknown".to_string(),
                        agent: "unknown".to_string(),
                        model: None,
                        reason: None,
                    },
                })
                .collect(),
            hidden: 0,
            unreadable: Vec::new(),
        }
    }

    // A FRESH APP HAS NOTHING SELECTED, PROBED OR QUEUED TO QUIT. Not named
    // in the brief's contract, but App::new is part of the interface this
    // task produces and a caller downstream needs its starting state pinned.
    #[test]
    fn new_starts_at_zero_with_no_probes_and_no_quit() {
        let app = App::new(fleet_of(&["a", "b"]));
        assert_eq!(app.selected, 0);
        assert!(app.probes.is_empty());
        assert!(!app.quit);
    }

    // SELECTION SATURATES. Wrapping teleports the eye; a list this short has no
    // need for it, and saturation is the behavior a stressed operator predicts.
    #[test]
    fn down_moves_and_saturates_at_the_end() {
        let mut app = App::new(fleet_of(&["a", "b", "c"]));
        handle_key(&mut app, KeyCode::Down);
        handle_key(&mut app, KeyCode::Down);
        handle_key(&mut app, KeyCode::Down);
        handle_key(&mut app, KeyCode::Down);
        assert_eq!(app.selected, 2);
    }

    #[test]
    fn up_saturates_at_zero() {
        let mut app = App::new(fleet_of(&["a", "b", "c"]));
        handle_key(&mut app, KeyCode::Up);
        assert_eq!(app.selected, 0);
    }

    #[test]
    fn q_requests_quit() {
        let mut app = App::new(fleet_of(&["a"]));
        assert!(!app.quit);
        handle_key(&mut app, KeyCode::Char('q'));
        assert!(app.quit);
    }

    // AN UNRECOGNIZED KEY CHANGES NOTHING. Later plans give more keys
    // meaning; this one must not guess at behavior for them early.
    #[test]
    fn an_unhandled_key_is_ignored_silently() {
        let mut app = App::new(fleet_of(&["a", "b"]));
        handle_key(&mut app, KeyCode::Char('z'));
        assert_eq!(app.selected, 0);
        assert!(!app.quit);
    }

    // AN EMPTY FLEET MUST NOT PANIC ON KEYS. Zero rows, every key: no panic,
    // selected stays 0, q still quits.
    #[test]
    fn keys_on_an_empty_fleet_do_not_panic() {
        let mut app = App::new(fleet_of(&[]));
        handle_key(&mut app, KeyCode::Down);
        assert_eq!(app.selected, 0);
        handle_key(&mut app, KeyCode::Up);
        assert_eq!(app.selected, 0);
        handle_key(&mut app, KeyCode::Char('q'));
        assert!(app.quit);
    }

    // A PROBE RESULT LANDS ON ITS SESSION, not on the selected one — the user
    // may have moved on while the probe was in flight.
    #[test]
    fn a_probe_result_binds_to_its_session_not_the_selection() {
        let mut app = App::new(fleet_of(&["a", "b"]));
        assert_eq!(app.selected, 0); // selection is on "a"
        apply_probe(
            &mut app,
            "b".to_string(),
            ProbeResult::Answered {
                assets: vec![AssetAnswer {
                    asset: "x".to_string(),
                    status: "up".to_string(),
                    detail: "reachable".to_string(),
                }],
            },
        );
        assert!(probe_for(&app, "b").is_some());
        assert!(probe_for(&app, "a").is_none());
    }

    // A FAILED PROBE IS AN ANSWER. It must be stored, not dropped — the mark
    // layer renders it as ? with the reason.
    #[test]
    fn a_failed_probe_is_kept_with_its_reason() {
        let mut app = App::new(fleet_of(&["a"]));
        apply_probe(
            &mut app,
            "a".to_string(),
            ProbeResult::Failed {
                reason: "timed out".to_string(),
            },
        );
        match probe_for(&app, "a") {
            Some(ProbeResult::Failed { reason }) => assert_eq!(reason, "timed out"),
            other => panic!("expected a stored Failed, got {other:?}"),
        }
    }

    // LATER ANSWERS WIN. A retry that succeeds must replace a stored failure.
    #[test]
    fn a_second_result_replaces_the_first() {
        let mut app = App::new(fleet_of(&["a"]));
        apply_probe(
            &mut app,
            "a".to_string(),
            ProbeResult::Failed {
                reason: "timed out".to_string(),
            },
        );
        apply_probe(
            &mut app,
            "a".to_string(),
            ProbeResult::Answered {
                assets: vec![AssetAnswer {
                    asset: "x".to_string(),
                    status: "up".to_string(),
                    detail: "reachable".to_string(),
                }],
            },
        );
        match probe_for(&app, "a") {
            Some(ProbeResult::Answered { assets }) => {
                assert_eq!(assets[0].status, "up")
            }
            other => panic!("expected the retry to have replaced the failure, got {other:?}"),
        }
    }

    // THE MARK ANSWERS "DID WE MEASURE", NOT "WHAT DID WE FIND" — several
    // assets still only need their FIRST answer's status here; the
    // inspector is where each asset gets its own word.
    #[test]
    fn probe_status_word_is_the_first_answers_status() {
        let r = ProbeResult::Answered {
            assets: vec![
                AssetAnswer {
                    asset: "a".to_string(),
                    status: "up".to_string(),
                    detail: "reachable".to_string(),
                },
                AssetAnswer {
                    asset: "b".to_string(),
                    status: "down".to_string(),
                    detail: "refused".to_string(),
                },
            ],
        };
        assert_eq!(probe_status_word(&r), Some("up"));
    }

    // A FAILED PROBE MEASURED NOTHING — the word is "unknown", the same
    // word mark.rs already treats as unmeasurable.
    #[test]
    fn probe_status_word_for_failed_is_unknown() {
        let r = ProbeResult::Failed {
            reason: "timed out".to_string(),
        };
        assert_eq!(probe_status_word(&r), Some("unknown"));
    }

    // JUDGMENT CALL: an Answered with zero AssetAnswers has no first
    // answer to report. Treating it as "still measuring" (None) would be
    // a lie — an answer already arrived, it just named nothing. "unknown"
    // is the honest word: an answer pointing at zero measurements
    // measured nothing either, same as a Failed.
    #[test]
    fn probe_status_word_for_an_empty_answer_is_unknown() {
        let r = ProbeResult::Answered { assets: vec![] };
        assert_eq!(probe_status_word(&r), Some("unknown"));
    }
}
