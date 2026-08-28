// cockpit/src/verb.rs — the three verbs, as pure logic, and the owner gate.
//
// WHY THIS EXISTS. The cockpit offers a session three things: watch it
// (already built), enter it (drive its terminal), and ask it (send a bus
// message without leaving the list). `enter` and `ask` both act ON another
// session, so both need a decision made somewhere that isn't tangled up with
// ratatui or a spawned process — a decision that a test can hold to account
// without a terminal or a socket. This module IS that somewhere: it owns no
// `Command`, spawns nothing, touches no file. It answers "is this allowed"
// and "what argv would this build", and returns a bool or a `Vec<String>`
// either way. Whoever calls it is the one that actually runs anything.
//
// THE OWNER GATE IS NARROWER THAN IT LOOKS. `enter` is an interactive attach
// — it puts real keystrokes into a real terminal that is itself signed in as
// somebody's Claude login. That is not a privilege question. Root on the
// machine, or any other operator, does not get to attach to a login that
// isn't theirs by virtue of being root — the gate checks ownership, not
// rank. `view` and `ask` are read and message; they cross the team boundary
// on purpose. `enter` never does, for anyone, ever.

/// True only when `session_owner` and `viewer` are equal AND both non-empty.
/// An empty viewer is never a wildcard — a caller that failed to determine
/// who is asking must not be treated as an owner by default.
pub fn enter_allowed(session_owner: &str, viewer: &str) -> bool {
    !viewer.is_empty() && session_owner == viewer
}

/// How `attach_argv` should shape the tmux call: full control, or read-only.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum AttachMode {
    Interactive,
    ReadOnly,
}

/// Builds the argv for a tmux attach, socket named explicitly and first.
///
/// NEVER A BARE `tmux attach`. tmux falls back to its default socket when
/// none is given, and on the build host that default socket is the live
/// one — a bare attach here would reach across into a real, running session
/// instead of the one the cockpit was aimed at. `-S <socket>` is therefore
/// always the first pair in the returned argv, never optional, never
/// inferred.
pub fn attach_argv(socket: &str, session: &str, mode: AttachMode) -> Vec<String> {
    let mut argv = vec![
        "-S".to_string(),
        socket.to_string(),
        "attach-session".to_string(),
        "-t".to_string(),
        session.to_string(),
    ];
    if mode == AttachMode::ReadOnly {
        argv.push("-r".to_string());
    }
    argv
}

/// Builds the argv for a bus-send call: `[recipient, "<envelope>\n<body>"]`.
///
/// `bus_bin` names the binary the caller will spawn; this function does not
/// touch it beyond taking it in, since the argv it returns is what gets
/// passed TO that binary, not the binary's own path. It stays a parameter
/// (rather than dropping out of the signature) so the call site reads as
/// "spawn `bus_bin` with this argv" in one place. When `ask` is wired, its
/// caller is meant to take `bus_bin` from `COCKPIT_BUS_CMD` and offer no
/// `ask` verb at all when that variable is unset, never a guessed path — the
/// bus lives in the estate, so a hardcoded path has no place in this crate.
/// `ask` is not wired in this plan: `ask_argv` is pure logic with no caller yet.
///
/// THE ENVELOPE IS REQUIRED, NOT OPTIONAL. The bus refuses any body whose
/// first line is not `CLASS topic: title` (exit 65) — so this function takes
/// the envelope as its own argument rather than letting a caller fold it
/// into `body` and maybe forget it. A caller with no envelope has no `ask`
/// to build.
pub fn ask_argv(_bus_bin: &str, recipient: &str, envelope: &str, body: &str) -> Vec<String> {
    vec![recipient.to_string(), format!("{envelope}\n{body}")]
}

#[cfg(test)]
mod tests {
    use super::*;

    // THE OWNER GATE. enter is interactive attach — it acts on someone's Claude
    // login. It crosses no team boundary, and NOT EVEN root changes that: the
    // gate is ownership, not privilege. view and ask cross the boundary; enter
    // never does.
    #[test]
    fn the_owner_may_enter() {
        assert!(enter_allowed("alice", "alice"));
    }
    #[test]
    fn a_teammate_may_not_enter() {
        assert!(!enter_allowed("alice", "bob"));
    }
    #[test]
    fn an_empty_viewer_may_not_enter() {
        assert!(!enter_allowed("alice", ""));
    }
    #[test]
    fn an_empty_owner_admits_no_one() {
        assert!(!enter_allowed("", ""));
    }

    // ATTACH ALWAYS ISOLATES ITS SOCKET. A bare `tmux attach` falls back to the
    // default socket, which on the build host is the LIVE one. The socket is
    // always the first argument pair.
    #[test]
    fn attach_argv_names_the_socket_explicitly() {
        let a = attach_argv("/tmp/x.sock", "sess", AttachMode::Interactive);
        assert_eq!(a[0], "-S");
        assert_eq!(a[1], "/tmp/x.sock");
        assert!(a.contains(&"attach-session".to_string()));
        assert!(a.contains(&"sess".to_string()));
        assert!(!a.contains(&"-r".to_string()));
    }
    // VIEW IS READ-ONLY: -r, the flag where only detach/switch keys reach tmux.
    #[test]
    fn view_adds_read_only() {
        let a = attach_argv("/tmp/x.sock", "sess", AttachMode::ReadOnly);
        assert!(a.contains(&"-r".to_string()));
    }
    // ask CARRIES AN ENVELOPE. The bus refuses a body without one; the cockpit
    // must not offer an ask the bus then rejects.
    #[test]
    fn ask_argv_puts_the_envelope_first() {
        let a = ask_argv("/x/bus-send", "target", "FRAGA topic: title", "body");
        assert_eq!(a[0], "target");
        assert!(a[1].starts_with("FRAGA topic: title"));
        assert!(a[1].contains("body"));
    }
    // THE ENVELOPE IS NON-NEGOTIABLE. The bus refuses a body whose first line is
    // not `CLASS topic: title` (rc 65). ask_argv must never build a call the bus
    // will reject — so it takes the envelope as a required argument, and a caller
    // with no envelope has no ask to offer.
}
