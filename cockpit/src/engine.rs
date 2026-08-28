// cockpit/src/engine.rs — reading the fleet, and refusing honestly.
//
// THE ENGINE IS A COMMAND, NOT A LIBRARY CALL. `steward sessions --json` already
// knows the registry, the visibility rule and the liveness seam; re-deriving any
// of that here would be a second truth that drifts. So this file runs it and
// parses what comes back.
//
// AND IT IS INJECTED. COCKPIT_ENGINE_CMD names the command. A real run aims it
// at the real one; the suite aims it at a stub. Without that seam this view
// could only be tried against a live estate — tried once by hand, then rotting.
//
// EVERY FAILURE IS AN Err WITH A REASON. A broken engine that yielded an empty
// fleet would draw an empty screen and look correct, which is the silence this
// whole system is built against. There is no path here that turns a failure
// into "no sessions".

use serde::Deserialize;
use std::process::Command;

#[derive(Debug, Deserialize)]
pub struct Liveness {
    pub tmux: String,
    pub agent: String,
    pub model: Option<String>,
    pub reason: Option<String>,
}

#[derive(Debug, Deserialize)]
pub struct Session {
    pub name: String,
    pub owner: String,
    pub host: String,
    pub assets: Vec<String>,
    pub liveness: Liveness,
}

#[derive(Debug, Deserialize)]
pub struct Fleet {
    #[serde(default)]
    pub sessions: Vec<Session>,
    #[serde(default)]
    pub hidden: u32,
    #[serde(default)]
    pub unreadable: Vec<String>,
}

// The engine's refusal shape, which is json too — a consumer that asked for
// json gets json back even when the answer is no.
#[derive(Debug, Deserialize)]
struct Refusal {
    ok: bool,
    reason: Option<String>,
}

pub fn read_fleet(cmd: &str) -> Result<Fleet, String> {
    let out = Command::new("bash")
        .arg("-c")
        .arg(cmd)
        .output()
        .map_err(|e| format!("could not run the engine: {e}"))?;

    let stdout = String::from_utf8_lossy(&out.stdout).to_string();

    // A NON-ZERO EXIT IS NOT AN EMPTY FLEET. Say what the engine said on stderr,
    // because that is where its refusals go.
    if !out.status.success() {
        let stderr = String::from_utf8_lossy(&out.stderr).trim().to_string();
        // The refusal may still be json on stdout; prefer its own words.
        if let Ok(r) = serde_json::from_str::<Refusal>(&stdout) {
            if !r.ok {
                return Err(r.reason.unwrap_or_else(|| "the engine refused".into()));
            }
        }
        return Err(if stderr.is_empty() {
            format!("the engine exited {}", out.status)
        } else {
            stderr
        });
    }

    // AN `ok:false` WITH A ZERO EXIT IS STILL A REFUSAL. Check the document, not
    // only the exit code — the two are separate channels and the engine uses both.
    if let Ok(r) = serde_json::from_str::<Refusal>(&stdout) {
        if !r.ok {
            return Err(r.reason.unwrap_or_else(|| "the engine refused".into()));
        }
    }

    serde_json::from_str::<Fleet>(&stdout)
        .map_err(|e| format!("the engine's answer did not parse: {e}"))
}

#[cfg(test)]
mod tests {
    use super::*;

    // THE ENGINE IS INJECTED, and that is not only a testing convenience: a view
    // that could only be tried against a live estate would be tried once by hand
    // and then rot. Every case here is a stub command.
    fn stub(body: &str) -> String {
        format!("printf '%s' '{}'", body.replace('\'', "'\\''"))
    }

    #[test]
    fn reads_a_fleet() {
        let json = r#"{"ok":true,"hidden":2,"unreadable":[],"sessions":[
            {"name":"alpha","id":"alpha","owner":"a","domain":"d","host":"h1",
             "entity":null,"assets":["widget"],
             "liveness":{"daemon":"loaded","tmux":"up","agent":"running",
                         "runtime":"claude-code","model":"opus",
                         "lastActivity":null,"reason":null}}]}"#;
        let f = read_fleet(&stub(json)).expect("should parse");
        assert_eq!(f.sessions.len(), 1);
        assert_eq!(f.sessions[0].name, "alpha");
        assert_eq!(f.sessions[0].assets, vec!["widget"]);
        assert_eq!(f.sessions[0].liveness.tmux, "up");
        assert_eq!(f.hidden, 2);
    }

    // A COUNT THAT IS ZERO IS STILL A COUNT. The engine always emits `hidden`,
    // and a reader that treated a missing field as "no hiding" would guess.
    #[test]
    fn hidden_is_read_even_at_zero() {
        let json = r#"{"ok":true,"hidden":0,"unreadable":[],"sessions":[]}"#;
        let f = read_fleet(&stub(json)).expect("should parse");
        assert_eq!(f.hidden, 0);
        assert!(f.sessions.is_empty());
    }

    // UNREADABLE IS NOT HIDDEN. One is a fault, the other a rule's refusal, and
    // the engine keeps them apart — so must the reader.
    #[test]
    fn unreadable_is_its_own_list() {
        let json = r#"{"ok":true,"hidden":1,"unreadable":["broken"],"sessions":[]}"#;
        let f = read_fleet(&stub(json)).expect("should parse");
        assert_eq!(f.unreadable, vec!["broken"]);
        assert_eq!(f.hidden, 1);
    }

    // A NULL IS NOT AN EMPTY STRING. `model: null` means measured-and-absent;
    // rendering it as "" would make a measured emptiness look like a value.
    #[test]
    fn a_null_model_stays_none() {
        let json = r#"{"ok":true,"hidden":0,"unreadable":[],"sessions":[
            {"name":"a","id":"a","owner":"o","domain":"d","host":"h","entity":null,
             "assets":[],"liveness":{"daemon":"missing","tmux":"down","agent":"not-running",
             "runtime":"claude-code","model":null,"lastActivity":null,"reason":"x"}}]}"#;
        let f = read_fleet(&stub(json)).expect("should parse");
        assert_eq!(f.sessions[0].liveness.model, None);
        assert_eq!(f.sessions[0].liveness.reason.as_deref(), Some("x"));
    }

    // EVERY FAILURE SAYS WHY. A view that got an empty fleet from a broken
    // engine would draw an empty screen and look correct — the exact silence
    // the whole system is built against. Each of these must be an Err with a
    // reason a human can act on.
    #[test]
    fn a_command_that_fails_is_an_error_not_an_empty_fleet() {
        let e = read_fleet("exit 3").unwrap_err();
        assert!(!e.is_empty(), "the refusal must say something");
    }

    #[test]
    fn output_that_is_not_json_is_an_error() {
        let e = read_fleet("echo not json at all").unwrap_err();
        assert!(!e.is_empty());
    }

    #[test]
    fn a_refusal_from_the_engine_is_an_error() {
        // The engine's own refusal shape: ok:false with a reason.
        let e = read_fleet(&stub(r#"{"ok":false,"reason":"registry unreadable"}"#))
            .unwrap_err();
        assert!(e.contains("registry unreadable"),
                "the engine's own reason must survive, got: {e}");
    }
}
