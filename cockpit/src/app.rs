// cockpit/src/app.rs — the state a keypress or a probe result changes.
//
// EVERYTHING ELSE IN THIS CRATE IS A PURE READ: engine.rs asks the fleet a
// question once, mark.rs and list.rs turn what came back into glyphs and text.
// Nothing so far remembers what happened a moment ago. An inspector needs
// that — which row is selected, and what each probe answered — and this file
// is where that memory lives. It stays a plain struct and two free functions
// on purpose: no thread, no terminal, no clock. A test drives it with a
// `KeyEvent` and a `ProbeResult` the same way a real run would, and never
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
use crate::verb;
use crossterm::event::{KeyCode, KeyEvent, KeyModifiers};
use std::collections::HashMap;

// Mode — which of the two loops main.rs is running. Browsing draws the list
// and the inspector, same as every plan before this one; Attached hands the
// whole frame to the embedded pane and every key but the detach chord to the
// child. The mode lives on App (not as a separate flag pane.rs owns) because
// a keypress is what changes it, and handle_key is the one place a keypress
// already changes state.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Mode {
    Browsing,
    Attached,
}

// THE DETACH CHORD IS Ctrl-]. tmux already owns C-b — reusing it, or anything
// a finger could half-remember as it, would mean a detach attempt sometimes
// reaches tmux instead of the cockpit. Ctrl-] has no tmux meaning to collide
// with, and is rare enough in ordinary shell use that an operator attached to
// a real session will not trigger it by accident.
// THE HINT NAMES BOTH READINGS. is_detach below accepts Ctrl-5 because it is
// the same byte — and on keyboard layouts where `]` sits behind AltGr (Swedish
// among them), Ctrl-5 is the only comfortable way to type the chord at all.
// A hint that only says Ctrl-] tells those operators their one good exit does
// not exist. Measured: the first real operator's first detach.
pub const DETACH_HINT: &str = "Ctrl-] / Ctrl-5 detach";

pub struct App {
    pub fleet: Fleet,
    pub selected: usize,
    pub probes: HashMap<String, ProbeResult>,
    pub quit: bool,
    pub mode: Mode,
    // THE VIEWER IS RESOLVED ONCE, AT CONSTRUCTION — not read fresh from the
    // environment on every Enter. The seam is the same one the engine uses
    // (lib/sessions.sh: STEWARD_VIEWER, falling back to `id -un`), but a test
    // that wants a deterministic owner/viewer pair sets this field directly
    // rather than mutating process environment a parallel test thread might
    // also be reading.
    pub viewer: String,
    // A REFUSAL IS A THING TO SHOW, NOT A THING TO LOG. `enter` on a session
    // someone else owns must stay visible until the operator moves on or
    // tries again — silently doing nothing is the exact failure mode the
    // owner gate exists to avoid drawing.
    pub refusal: Option<String>,
}

impl App {
    pub fn new(fleet: Fleet) -> App {
        App {
            fleet,
            selected: 0,
            probes: HashMap::new(),
            quit: false,
            mode: Mode::Browsing,
            viewer: resolve_viewer(),
            refusal: None,
        }
    }
}

// resolve_viewer — STEWARD_VIEWER first, `id -un` as the fallback. THE SAME
// SEAM THE ENGINE USES: a caller that already knows who is asking (a wrapper
// script, a test harness) sets the variable rather than trusting whichever
// account happens to be running this binary. An empty result is not a
// wildcard — verb::enter_allowed already refuses an empty viewer on its own,
// so a failed `id -un` fails closed rather than admitting everyone.
fn resolve_viewer() -> String {
    if let Ok(v) = std::env::var("STEWARD_VIEWER") {
        if !v.is_empty() {
            return v;
        }
    }
    std::process::Command::new("id")
        .arg("-un")
        .output()
        .ok()
        .filter(|o| o.status.success())
        .and_then(|o| String::from_utf8(o.stdout).ok())
        .map(|s| s.trim().to_string())
        .unwrap_or_default()
}

// is_detach — the one chord that means "leave Attached", recognized by its
// modifiers as well as its code. `KeyEvent::from(KeyCode::Char(']'))` (no
// modifiers) is a plain bracket keystroke meant for the child, not a detach —
// only Ctrl-] detaches.
fn is_detach(key: KeyEvent) -> bool {
    if !key.modifiers.contains(KeyModifiers::CONTROL) {
        return false;
    }
    match key.code {
        // Ctrl-] as documented, and as every test in this module (and
        // anything built via `KeyEvent::new`) constructs it directly.
        KeyCode::Char(']') => true,
        // THE SAME PHYSICAL KEYSTROKE, READ THE OTHER WAY. Ctrl-\, Ctrl-],
        // Ctrl-^ and Ctrl-_ all send one of the raw bytes 0x1C-0x1F —
        // exactly the same bytes a Ctrl-4..Ctrl-7 keypress sends on most
        // keyboards, because the terminal has no way to tell the two
        // apart without the kitty keyboard protocol, which this cockpit
        // does not enable (see terminal.rs). crossterm's own non-kitty
        // parser resolves that ambiguity by reporting the digit — measured
        // live against a real tmux pane feeding this program's stdin,
        // where a physical Ctrl-] arrived here as Char('5') + CONTROL, not
        // Char(']') + CONTROL. Treating the two as equivalent is what
        // makes the documented chord actually fire outside kitty.
        KeyCode::Char('5') => true,
        _ => false,
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

// handle_key — the only place a keypress becomes a state change. In
// Browsing: `Up`/`Down` move the selection with saturation at both ends;
// `q` requests quit; `Enter` on the selected row either attaches (the
// viewer owns it) or sets a visible refusal (it does not); every other key
// is ignored in silence, because later plans are what give those keys
// meaning, not this one inventing behavior for them early.
//
// IN ATTACHED, THIS FUNCTION DOES ALMOST NOTHING ON PURPOSE. Every key
// except the detach chord belongs to the child process, not to this
// program's own state — main.rs is what forwards it to `pane.send`. This
// function's whole job while attached is recognizing the one chord that
// exits, which is also why `q` must NOT be special-cased here for that mode:
// a `q` typed into a real program running inside the pane (a pager, an
// editor) has to reach it, never quit the cockpit instead.
pub fn handle_key(app: &mut App, key: KeyEvent) {
    if app.mode == Mode::Attached {
        if is_detach(key) {
            app.mode = Mode::Browsing;
        }
        return;
    }

    match key.code {
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
        KeyCode::Enter => {
            app.refusal = None;
            if let Some(session) = app.fleet.sessions.get(app.selected) {
                if verb::enter_allowed(&session.owner, &app.viewer) {
                    // OWNERSHIP FIRST, THEN REACH. Ownership is the durable
                    // answer (a foreign session stays foreign when remote
                    // attach lands one day); reach is a capability gap. A
                    // session on another host cannot be attached to the
                    // LOCAL tmux — trying anyway spawned a client that died
                    // with tmux's "can't find session", leaving the operator
                    // in an attached view of a corpse. Measured on the real
                    // hub, first enter on a remote-host session.
                    if session.host == app.fleet.hub {
                        app.mode = Mode::Attached;
                    } else {
                        app.refusal = Some(format!(
                            "{} runs on {} — remote view/enter not yet",
                            session.label(), session.host
                        ));
                    }
                } else {
                    // NAMES OWNERSHIP, NOT PERMISSION. "denied" or "not
                    // allowed" would read like a rank the operator lacks;
                    // the actual reason is narrower and more specific than
                    // that — this session belongs to someone else, and
                    // enter never crosses that line for anyone, root
                    // included.
                    app.refusal = Some(format!(
                        "{} is owned by {} — enter stays with the owner",
                        session.label(), session.owner
                    ));
                }
            }
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
    use crossterm::event::{KeyCode, KeyEvent, KeyModifiers};

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
                    slug: None,
                    display: None,
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
            hub: "h".to_string(),
        }
    }

    // A SECOND FIXTURE, OWNER CHOSEN BY THE CALLER — the enter/refusal tests
    // need a session whose owner and the app's viewer can be set
    // independently, which fleet_of's hardcoded "alice" cannot express.
    fn fleet_owned_by(name: &str, owner: &str) -> Fleet {
        Fleet {
            sessions: vec![Session {
                name: name.to_string(),
                slug: None,
                display: None,
                owner: owner.to_string(),
                host: "h".to_string(),
                assets: vec!["x".to_string()],
                liveness: Liveness {
                    tmux: "unknown".to_string(),
                    agent: "unknown".to_string(),
                    model: None,
                    reason: None,
                },
            }],
            hidden: 0,
            unreadable: Vec::new(),
            hub: "h".to_string(),
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
        assert_eq!(app.mode, Mode::Browsing);
    }

    // SELECTION SATURATES. Wrapping teleports the eye; a list this short has no
    // need for it, and saturation is the behavior a stressed operator predicts.
    #[test]
    fn down_moves_and_saturates_at_the_end() {
        let mut app = App::new(fleet_of(&["a", "b", "c"]));
        handle_key(&mut app, KeyEvent::from(KeyCode::Down));
        handle_key(&mut app, KeyEvent::from(KeyCode::Down));
        handle_key(&mut app, KeyEvent::from(KeyCode::Down));
        handle_key(&mut app, KeyEvent::from(KeyCode::Down));
        assert_eq!(app.selected, 2);
    }

    #[test]
    fn up_saturates_at_zero() {
        let mut app = App::new(fleet_of(&["a", "b", "c"]));
        handle_key(&mut app, KeyEvent::from(KeyCode::Up));
        assert_eq!(app.selected, 0);
    }

    #[test]
    fn q_requests_quit() {
        let mut app = App::new(fleet_of(&["a"]));
        assert!(!app.quit);
        handle_key(&mut app, KeyEvent::from(KeyCode::Char('q')));
        assert!(app.quit);
    }

    // AN UNRECOGNIZED KEY CHANGES NOTHING. Later plans give more keys
    // meaning; this one must not guess at behavior for them early.
    #[test]
    fn an_unhandled_key_is_ignored_silently() {
        let mut app = App::new(fleet_of(&["a", "b"]));
        handle_key(&mut app, KeyEvent::from(KeyCode::Char('z')));
        assert_eq!(app.selected, 0);
        assert!(!app.quit);
    }

    // AN EMPTY FLEET MUST NOT PANIC ON KEYS. Zero rows, every key: no panic,
    // selected stays 0, q still quits.
    #[test]
    fn keys_on_an_empty_fleet_do_not_panic() {
        let mut app = App::new(fleet_of(&[]));
        handle_key(&mut app, KeyEvent::from(KeyCode::Down));
        assert_eq!(app.selected, 0);
        handle_key(&mut app, KeyEvent::from(KeyCode::Up));
        assert_eq!(app.selected, 0);
        handle_key(&mut app, KeyEvent::from(KeyCode::Char('q')));
        assert!(app.quit);
    }

    // CTRL-] DETACHES, A PLAIN ']' DOES NOT. The chord is defined by its
    // modifiers as much as its code — this is exactly the information the
    // old `KeyCode`-only signature threw away before it ever reached here.
    #[test]
    fn ctrl_rbracket_detaches_from_attached_mode() {
        let mut app = App::new(fleet_of(&["a"]));
        app.mode = Mode::Attached;
        handle_key(
            &mut app,
            KeyEvent::new(KeyCode::Char(']'), KeyModifiers::CONTROL),
        );
        assert_eq!(app.mode, Mode::Browsing);
    }

    // THE SAME PHYSICAL KEYSTROKE, AS A REAL TERMINAL ACTUALLY REPORTS IT.
    // Measured live 2026-08-28 against a real tmux pane: without the kitty
    // keyboard protocol, crossterm's parser cannot tell Ctrl-] apart from
    // Ctrl-5 (both send the same raw byte), and it resolves the ambiguity
    // by reporting the digit. A regression here would mean the documented
    // chord — the one written into the status line — silently stops
    // working the moment it is pressed for real, while every test using
    // the bracket form directly kept passing.
    #[test]
    fn ctrl_5_also_detaches_the_same_physical_keystroke() {
        let mut app = App::new(fleet_of(&["a"]));
        app.mode = Mode::Attached;
        handle_key(
            &mut app,
            KeyEvent::new(KeyCode::Char('5'), KeyModifiers::CONTROL),
        );
        assert_eq!(app.mode, Mode::Browsing);
    }

    // A PLAIN '5' (NO CONTROL) MUST NOT DETACH — it is an ordinary digit a
    // program running inside the pane is entitled to receive.
    #[test]
    fn a_plain_five_does_not_detach() {
        let mut app = App::new(fleet_of(&["a"]));
        app.mode = Mode::Attached;
        handle_key(&mut app, KeyEvent::from(KeyCode::Char('5')));
        assert_eq!(app.mode, Mode::Attached);
    }

    // A PLAIN q QUITS IN BROWSING BUT MUST REACH THE CHILD WHILE ATTACHED —
    // a pager or an editor running inside the pane has its own `q`, and the
    // cockpit must not steal the keystroke from it.
    #[test]
    fn plain_q_quits_in_browsing_but_not_attached() {
        let mut browsing = App::new(fleet_of(&["a"]));
        handle_key(&mut browsing, KeyEvent::from(KeyCode::Char('q')));
        assert!(browsing.quit);

        let mut attached = App::new(fleet_of(&["a"]));
        attached.mode = Mode::Attached;
        handle_key(&mut attached, KeyEvent::from(KeyCode::Char('q')));
        assert!(!attached.quit);
        assert_eq!(attached.mode, Mode::Attached);
    }

    // ENTER ON A SESSION THE VIEWER OWNS ATTACHES.
    #[test]
    fn enter_on_an_owned_session_attaches() {
        let mut app = App::new(fleet_owned_by("a", "alice"));
        app.viewer = "alice".to_string();
        handle_key(&mut app, KeyEvent::from(KeyCode::Enter));
        assert_eq!(app.mode, Mode::Attached);
        assert!(app.refusal.is_none());
    }

    // ENTER ON A SESSION THE VIEWER DOES NOT OWN IS REFUSED VISIBLY — it
    // must stay in Browsing AND leave a message behind, not just do nothing.
    // A silent no-op here would be indistinguishable from a dropped
    // keystroke, and an operator would have no way to tell the two apart.
    #[test]
    fn enter_on_a_foreign_session_is_refused_visibly() {
        let mut app = App::new(fleet_owned_by("a", "alice"));
        app.viewer = "bob".to_string();
        handle_key(&mut app, KeyEvent::from(KeyCode::Enter));
        assert_eq!(app.mode, Mode::Browsing);
        assert!(app.refusal.is_some());
    }

    // THE REFUSAL NAMES OWNERSHIP, NOT PERMISSION. "denied" reads like a
    // rank the operator lacks; the actual reason is narrower — this session
    // belongs to someone else, full stop, and that is what the message says.
    #[test]
    fn the_refusal_names_ownership_not_permission() {
        let mut app = App::new(fleet_owned_by("a", "alice"));
        app.viewer = "bob".to_string();
        handle_key(&mut app, KeyEvent::from(KeyCode::Enter));
        let msg = app.refusal.expect("a refusal message");
        assert!(msg.contains("alice"), "refusal should name the owner: {msg}");
        assert!(!msg.to_lowercase().contains("denied"));
        assert!(!msg.to_lowercase().contains("permission"));
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

    // A THIRD FIXTURE, HOST CHOSEN BY THE CALLER — the remote-gate tests need
    // a session whose host and the fleet's hub differ. The hub stays "h" like
    // every other fixture here; the session's host is the variable.
    fn fleet_on_host(name: &str, owner: &str, host: &str) -> Fleet {
        let mut f = fleet_owned_by(name, owner);
        f.sessions[0].host = host.to_string();
        f
    }

    // ENTER ON A REMOTE SESSION REFUSES VISIBLY. The plan scoped remote
    // attach out — but out means a visible line, never a local tmux client
    // spawned against a session that lives elsewhere and dying with tmux's
    // own error. Measured on the real hub: the first enter an operator ever
    // tried was a remote-host session, and the cockpit attached a corpse.
    #[test]
    fn enter_on_a_remote_session_refuses_visibly() {
        let mut app = App::new(fleet_on_host("far-session", "alice", "elsewhere"));
        app.viewer = "alice".to_string();
        handle_key(&mut app, KeyEvent::from(KeyCode::Enter));
        assert_eq!(app.mode, Mode::Browsing, "a remote session must not attach");
        let r = app.refusal.expect("the refusal must be visible");
        assert!(r.contains("remote"), "the refusal names the gap: {r}");
        assert!(r.contains("elsewhere"), "the refusal names the host: {r}");
    }

    // AND A LOCAL ONE STILL ATTACHES — host equal to the hub is the whole
    // meaning of local.
    #[test]
    fn enter_on_a_local_owned_session_attaches() {
        let mut app = App::new(fleet_on_host("near-session", "alice", "h"));
        app.viewer = "alice".to_string();
        handle_key(&mut app, KeyEvent::from(KeyCode::Enter));
        assert_eq!(app.mode, Mode::Attached);
        assert_eq!(app.refusal, None);
    }

    // OWNERSHIP IS CHECKED BEFORE REACH. A foreign session on a remote host
    // gets the ownership refusal — the durable truth — not the capability
    // gap, which would read as "come back when remote lands" to someone the
    // owner gate will still refuse then.
    #[test]
    fn a_foreign_remote_session_refuses_on_ownership_not_reach() {
        let mut app = App::new(fleet_on_host("far-session", "alice", "elsewhere"));
        app.viewer = "bob".to_string();
        handle_key(&mut app, KeyEvent::from(KeyCode::Enter));
        assert_eq!(app.mode, Mode::Browsing);
        let r = app.refusal.expect("the refusal must be visible");
        assert!(r.contains("owned by alice"), "ownership first: {r}");
        assert!(!r.contains("remote"), "reach must not mask ownership: {r}");
    }
}
