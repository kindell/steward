// cockpit/src/probe.rs — asking the fleet, one session at a time, without
// blocking the view.
//
// THE PROBER IS A COMMAND TEMPLATE, INJECTED. Production wires it to
// `steward assets {} --json`; the suite feeds `printf` stubs that stand in
// for it — the same injected-template shape as engine.rs, and for the same
// reason: a probe that could only be tried against a live estate would be
// tried once by hand and then rot. But the resemblance stops at the seam:
// engine.rs's template is fixed at construction and never has per-item data
// spliced into it afterward. This module's template gets a session name
// spliced into it on every call — the first place in this codebase that
// hands untrusted per-item data to a shell string. That is exactly why
// `run_probe` validates the session name before building the command,
// rather than trusting the charset check some upstream caller may already
// have done.
//
// SEQUENTIAL, ON PURPOSE. Each probe costs a real round trip (~1.7s,
// measured against the live ssh path — see bin/steward's cmd_assets). This
// module could hide that behind a pool of threads, but that would hide the
// fleet's actual latency behind an implementation detail the inspector has
// no control over. One thread, one session at a time, in the order given —
// the cockpit inherits the cost visibly instead of pretending it isn't
// there.
//
// A RESULT IS KEYED TO THE SESSION IT ANSWERED FOR, never to a row. app.rs's
// `apply_probe` already assumes this; this module is what produces the pairs
// it consumes.
//
// FAILURE IS AN ANSWER, NEVER SILENCE. `ok:false` becomes `Failed` carrying
// the engine's own reason; output that will not parse becomes `Failed` with
// a reason naming that; a command that cannot even be spawned or that dies
// becomes `Failed` too. No branch below drops a session on the floor.
//
// A DECLARES-NOTHING SESSION (an empty `assets` array) IS NOT PROBE-WORTHY,
// but if a caller sends one anyway, this module answers honestly rather than
// invent a status word for zero measurements. It emits `Failed` with a
// reason naming the emptiness, not a skip — a skip would mean the caller
// waits forever for a message that never comes, indistinguishable from the
// receiving end from a probe that silently died. A `Failed` a caller can
// choose to render or ignore; a message that never arrives, it cannot.
//
// THE THREAD DIES QUIETLY WHEN THE RECEIVER IS DROPPED. `Sender::send`
// returns an `Err` once nothing is listening any more — that error is the
// stop signal, not a fault to report. The loop treats it as "you can go
// home now", never a reason to panic.

use serde::Deserialize;
use std::process::Command;
use std::sync::mpsc::{self, Receiver};
use std::thread;

use crate::app::ProbeResult;

#[derive(Debug, Deserialize)]
struct ProbedAsset {
    #[allow(dead_code)]
    asset: String,
    status: String,
    detail: String,
}

#[derive(Debug, Deserialize)]
struct Answer {
    ok: bool,
    reason: Option<String>,
    #[serde(default)]
    assets: Vec<ProbedAsset>,
}

// is_safe_session_name — the charset this module is willing to splice into
// a shell string: `^[a-z][a-z0-9-]*$`. Upstream is expected to have already
// validated the session name against the same shape, but this module does
// not trust that — see the module doc for why. A hand-rolled `chars()` walk
// rather than a regex dependency: the language is three rules wide.
fn is_safe_session_name(session: &str) -> bool {
    let mut chars = session.chars();
    match chars.next() {
        Some(c) if c.is_ascii_lowercase() => {}
        _ => return false,
    }
    chars.all(|c| c.is_ascii_lowercase() || c.is_ascii_digit() || c == '-')
}

// run_probe — one session, one command, one honest result. Never panics:
// every exit from this function is a `ProbeResult`, including the ones
// where the command could not even be started.
fn run_probe(cmd_template: &str, session: &str) -> ProbeResult {
    // VALIDATE BEFORE BUILDING THE COMMAND. `session` is about to be
    // spliced textually into a string handed to `bash -c` — a name
    // carrying `;` or `$(...)` would execute as shell instead of standing
    // for itself. See the module doc: this is the seam that pays for that,
    // so it checks here, where the value is actually used, rather than
    // trusting the caller.
    if !is_safe_session_name(session) {
        return ProbeResult::Failed {
            reason: "session name contains characters unsafe to hand to the probe".to_string(),
        };
    }

    let cmd = cmd_template.replace("{}", session);

    let out = match Command::new("bash").arg("-c").arg(&cmd).output() {
        Ok(o) => o,
        Err(e) => {
            return ProbeResult::Failed {
                reason: format!("could not run the probe: {e}"),
            };
        }
    };

    let stdout = String::from_utf8_lossy(&out.stdout).to_string();

    let answer: Answer = match serde_json::from_str(&stdout) {
        Ok(a) => a,
        Err(e) => {
            return ProbeResult::Failed {
                reason: format!("the probe's answer did not parse: {e}"),
            };
        }
    };

    if !answer.ok {
        return ProbeResult::Failed {
            reason: answer
                .reason
                .unwrap_or_else(|| "the probe refused".to_string()),
        };
    }

    // MULTI-ASSET FOLDS INTO FIRST + COUNT. A list's single mark cannot
    // honestly summarize several assets that might disagree, and inventing
    // a pessimistic fifth status word would only rename that dishonesty.
    // The inspector (a later task) shows every asset; this is a summary
    // for the row, not the whole answer.
    match answer.assets.split_first() {
        Some((first, rest)) => {
            let detail = if rest.is_empty() {
                first.detail.clone()
            } else {
                format!("{} +{} more", first.detail, rest.len())
            };
            ProbeResult::Answered {
                status: first.status.clone(),
                detail,
            }
        }
        // DECLARES NOTHING. Zero assets means zero measurements — no status
        // word in the vocabulary means "measured and there was nothing to
        // measure", and inventing one would look like a probe that ran and
        // found health where it found only absence. Failed, with a reason
        // that says exactly that, so the row shows *something* rather than
        // leaving the caller waiting on a message that will never arrive.
        None => ProbeResult::Failed {
            reason: "session declares no assets to probe".to_string(),
        },
    }
}

// spawn_prober — one background thread, sessions probed sequentially in the
// given order. `{}` in `cmd_template` is replaced with each session name in
// turn; every session gets exactly one result, sent as soon as it is known.
//
// THE THREAD NEVER PANICS ON A DROPPED RECEIVER. `Sender::send` returning an
// `Err` means nobody is listening any more — the loop just stops, quietly,
// rather than treating a closed channel as a fault.
pub fn spawn_prober(cmd_template: String, sessions: Vec<String>) -> Receiver<(String, ProbeResult)> {
    let (tx, rx) = mpsc::channel();

    thread::spawn(move || {
        for session in sessions {
            let result = run_probe(&cmd_template, &session);
            if tx.send((session, result)).is_err() {
                // The receiver is gone. Nothing left to do here but stop.
                return;
            }
        }
    });

    rx
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::time::Duration;

    // THE PROBER IS A COMMAND TEMPLATE, injected. The suite feeds printf
    // stubs; production feeds `steward assets {} --json`. `{}` is a textual
    // substitution done by `spawn_prober` itself (not a shell positional
    // arg), so a stub can put `{}` straight into a `case` subject and get
    // back a different canned answer per session — the same seam shape as
    // engine.rs.
    fn stub_for(body_by_session: &[(&str, &str)]) -> String {
        let mut arms = String::new();
        for (session, body) in body_by_session {
            arms.push_str(&format!(
                "  {}) printf '%s' '{}' ;;\n",
                session,
                body.replace('\'', "'\\''")
            ));
        }
        format!("case '{{}}' in\n{arms}esac", arms = arms)
    }

    fn recv(rx: &Receiver<(String, ProbeResult)>) -> (String, ProbeResult) {
        rx.recv_timeout(Duration::from_secs(5))
            .expect("expected a probe result before the timeout")
    }

    #[test]
    fn results_arrive_per_session_in_order() {
        let cmd = stub_for(&[
            ("alpha", r#"{"ok":true,"session":"alpha","assets":[{"asset":"x","status":"up","detail":"reachable"}]}"#),
            ("beta", r#"{"ok":true,"session":"beta","assets":[{"asset":"x","status":"up","detail":"reachable"}]}"#),
        ]);
        let full_cmd = cmd;
        let rx = spawn_prober(full_cmd, vec!["alpha".to_string(), "beta".to_string()]);

        let (name1, _) = recv(&rx);
        assert_eq!(name1, "alpha");
        let (name2, _) = recv(&rx);
        assert_eq!(name2, "beta");
    }

    #[test]
    fn a_status_and_detail_survive_the_parse() {
        let cmd = stub_for(&[(
            "one",
            r#"{"ok":true,"session":"one","assets":[{"asset":"x","status":"up","detail":"vnc:1 cdp:2"}]}"#,
        )]);
        let full_cmd = cmd;
        let rx = spawn_prober(full_cmd, vec!["one".to_string()]);

        let (name, result) = recv(&rx);
        assert_eq!(name, "one");
        match result {
            ProbeResult::Answered { status, detail } => {
                assert_eq!(status, "up");
                assert_eq!(detail, "vnc:1 cdp:2");
            }
            other => panic!("expected Answered, got {other:?}"),
        }
    }

    // AN EMPTY ASSETS LIST IS NOT PROBE-WORTHY — but if the caller sends
    // such a session anyway, the answer must be honest, not invented. This
    // implementation chose Failed with a reason (see the module doc and
    // run_probe's None arm): a skip would mean the caller waits on a
    // message that never comes, indistinguishable at the receiving end
    // from a probe that silently died — exactly the silence this whole
    // system refuses everywhere else. A Failed a caller can render or
    // discard; a missing message it cannot tell apart from a hang.
    #[test]
    fn a_declares_nothing_session_yields_no_fabricated_status() {
        let cmd = stub_for(&[(
            "empty",
            r#"{"ok":true,"session":"empty","assets":[]}"#,
        )]);
        let full_cmd = cmd;
        let rx = spawn_prober(full_cmd, vec!["empty".to_string()]);

        let (name, result) = recv(&rx);
        assert_eq!(name, "empty");
        match result {
            ProbeResult::Answered { status, .. } => {
                panic!("expected no fabricated status, got Answered({status})")
            }
            ProbeResult::Failed { reason } => {
                assert!(!reason.is_empty(), "the reason must say something");
            }
        }
    }

    #[test]
    fn ok_false_becomes_failed_with_the_engines_reason() {
        let cmd = stub_for(&[(
            "bad",
            r#"{"ok":false,"reason":"registry unreadable"}"#,
        )]);
        let full_cmd = cmd;
        let rx = spawn_prober(full_cmd, vec!["bad".to_string()]);

        let (_, result) = recv(&rx);
        match result {
            ProbeResult::Failed { reason } => {
                assert_eq!(reason, "registry unreadable");
            }
            other => panic!("expected Failed, got {other:?}"),
        }
    }

    #[test]
    fn garbage_output_becomes_failed_not_silence() {
        let full_cmd = "echo not-json".to_string();
        let rx = spawn_prober(full_cmd, vec!["one".to_string()]);

        let (_, result) = recv(&rx);
        match result {
            ProbeResult::Failed { reason } => {
                assert!(!reason.is_empty(), "the reason must say something");
            }
            other => panic!("expected Failed, got {other:?}"),
        }
    }

    #[test]
    fn a_dying_command_becomes_failed() {
        let full_cmd = "exit 3".to_string();
        let rx = spawn_prober(full_cmd, vec!["one".to_string()]);

        let (_, result) = recv(&rx);
        match result {
            ProbeResult::Failed { reason } => {
                assert!(!reason.is_empty(), "the reason must say something");
            }
            other => panic!("expected Failed, got {other:?}"),
        }
    }

    // MULTI-ASSET: the first asset's status and detail are kept, and the
    // detail names how many more there were. Two assets -> "+1 more".
    #[test]
    fn several_assets_fold_into_first_plus_count() {
        let cmd = stub_for(&[(
            "multi",
            r#"{"ok":true,"session":"multi","assets":[{"asset":"a","status":"up","detail":"reachable"},{"asset":"b","status":"down","detail":"refused"}]}"#,
        )]);
        let full_cmd = cmd;
        let rx = spawn_prober(full_cmd, vec!["multi".to_string()]);

        let (_, result) = recv(&rx);
        match result {
            ProbeResult::Answered { status, detail } => {
                assert_eq!(status, "up");
                assert!(
                    detail.contains("+1 more"),
                    "expected the detail to name the extra asset, got: {detail}"
                );
            }
            other => panic!("expected Answered, got {other:?}"),
        }
    }

    // AN UNSAFE SESSION NAME NEVER REACHES THE SHELL. `run_probe` splices
    // `session` textually into the command it hands to `bash -c`; a name
    // carrying `;` or `$(...)` would otherwise execute as shell rather than
    // stand for itself. The stub here always touches a marker file as a
    // side effect of actually running — proving the marker is absent proves
    // the command was never spawned at all, not merely that its injected
    // half failed.
    fn marker_path(label: &str) -> std::path::PathBuf {
        std::env::temp_dir().join(format!(
            "steward-probe-unsafe-name-marker-{}-{}",
            std::process::id(),
            label
        ))
    }

    #[test]
    fn a_semicolon_in_the_session_name_is_rejected_and_the_probe_never_runs() {
        let marker = marker_path("semicolon");
        let _ = std::fs::remove_file(&marker);
        let cmd = format!(
            "touch {} && printf '%s' '{{\"ok\":true,\"assets\":[]}}'",
            marker.display()
        );
        let rx = spawn_prober(cmd, vec!["evil;touch pwned".to_string()]);

        let (_, result) = recv(&rx);
        match result {
            ProbeResult::Failed { reason } => {
                assert_eq!(
                    reason,
                    "session name contains characters unsafe to hand to the probe"
                );
            }
            other => panic!("expected Failed, got {other:?}"),
        }
        assert!(
            !marker.exists(),
            "the probe command must never be spawned for an unsafe session name"
        );
        let _ = std::fs::remove_file(&marker);
    }

    #[test]
    fn a_command_substitution_in_the_session_name_is_rejected_and_the_probe_never_runs() {
        let marker = marker_path("subshell");
        let _ = std::fs::remove_file(&marker);
        let cmd = format!(
            "touch {} && printf '%s' '{{\"ok\":true,\"assets\":[]}}'",
            marker.display()
        );
        let rx = spawn_prober(cmd, vec!["evil$(touch pwned)".to_string()]);

        let (_, result) = recv(&rx);
        match result {
            ProbeResult::Failed { reason } => {
                assert_eq!(
                    reason,
                    "session name contains characters unsafe to hand to the probe"
                );
            }
            other => panic!("expected Failed, got {other:?}"),
        }
        assert!(
            !marker.exists(),
            "the probe command must never be spawned for an unsafe session name"
        );
        let _ = std::fs::remove_file(&marker);
    }

    // THE THREAD MUST NOT PANIC WHEN THE RECEIVER IS DROPPED MID-RUN. Two
    // sessions queued, drop the receiver immediately, then give the thread
    // a moment: nothing here can observe a panic directly, but a crashed
    // probe thread would otherwise be a silent, undetectable failure mode.
    // This test's real job is to exist as a place a panic would show up
    // under `cargo test` (a panicking thread prints to stderr and the test
    // binary still exits non-zero only if the panic unwinds past a
    // `Result`-returning boundary — here it simply proves the drop path
    // does not hang or abort the test process).
    #[test]
    fn dropping_the_receiver_does_not_hang_or_panic() {
        let cmd = stub_for(&[
            ("a", r#"{"ok":true,"session":"a","assets":[]}"#),
            ("b", r#"{"ok":true,"session":"b","assets":[]}"#),
        ]);
        let full_cmd = cmd;
        let rx = spawn_prober(full_cmd, vec!["a".to_string(), "b".to_string(), "c".to_string()]);
        drop(rx);
        thread::sleep(Duration::from_millis(200));
        // Reaching this line without hanging is the assertion.
    }
}
