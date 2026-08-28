// cockpit/src/mark.rs — the last inch: from a session's asset state to a glyph.
//
// THIS IS THE ONLY PLACE THE COCKPIT COULD INVENT A STATE, which is exactly why
// it is a pure function in its own file rather than a match buried in the
// renderer. The status vocabulary is closed in the engine — up, local-only,
// down, unknown — and this translates it. It does not extend it.
//
// FOUR MARKS FOR MORE THAN FOUR SITUATIONS. The three words a successful probe
// can produce share one mark, because the question the mark answers is "did we
// measure this", not "what did we find" — the word itself is rendered beside it.
// The other three marks are the states no status word can express:
//
//   ◌  declared, probe not back yet — the normal state for the first second
//   ·  declares nothing at all — which is not health
//   ?  unmeasurable, and the reason is rendered beside it
//
// `·` AND `◌` ARE THE ONES THAT BREAK, because they are the only two that tempt
// a renderer into an empty cell. Thirteen of twenty-one sessions declared
// nothing when this was written.

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Mark {
    Measured,
    Measuring,
    Undeclared,
    Unmeasurable,
}

pub fn mark_char(m: Mark) -> char {
    match m {
        Mark::Measured => '●',
        Mark::Measuring => '◌',
        Mark::Undeclared => '·',
        Mark::Unmeasurable => '?',
    }
}

// asset_mark — `probed` carries the status word once a probe has answered, and
// None while none has. Plan 2 is what starts passing Some.
pub fn asset_mark(assets: &[String], probed: Option<&str>) -> Mark {
    // NOTHING DECLARED WINS OVER EVERYTHING. A session with no assets cannot be
    // measuring, measured or unmeasurable — there is nothing to measure, and
    // saying otherwise would invent a state out of an absence.
    if assets.is_empty() {
        return Mark::Undeclared;
    }
    match probed {
        None => Mark::Measuring,
        Some("up") | Some("local-only") | Some("down") => Mark::Measured,
        // `unknown` and anything else the engine should never emit both land
        // here. A broken engine must not be able to render as healthy.
        Some(_) => Mark::Unmeasurable,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn a(list: &[&str]) -> Vec<String> {
        list.iter().map(|s| s.to_string()).collect()
    }

    // THE SEVEN CASES THE SPEC NAMES. Three of them are the closed status
    // vocabulary; the other four are the states a status word cannot express,
    // and they are the reason this function exists rather than a match on a
    // string somewhere in the renderer.
    #[test]
    fn a_measured_asset_is_a_filled_dot() {
        assert_eq!(asset_mark(&a(&["rig"]), Some("up")), Mark::Measured);
        assert_eq!(asset_mark(&a(&["rig"]), Some("local-only")), Mark::Measured);
        assert_eq!(asset_mark(&a(&["rig"]), Some("down")), Mark::Measured);
    }

    // UNKNOWN IS NOT MEASURED. It is the word a probe uses when it could not
    // measure, and it must not share a mark with the three that could.
    #[test]
    fn unknown_is_unmeasurable_not_measured() {
        assert_eq!(asset_mark(&a(&["rig"]), Some("unknown")), Mark::Unmeasurable);
    }

    // DECLARED BUT NOT YET PROBED. The list renders before the probes return —
    // that is the whole reason the layers are separated — so this state is the
    // normal one for the first second of every run, not an edge case.
    #[test]
    fn declared_but_unprobed_is_measuring() {
        assert_eq!(asset_mark(&a(&["rig"]), None), Mark::Measuring);
    }

    // DECLARING NOTHING IS NOT HEALTH. Thirteen of twenty-one sessions declared
    // nothing when this was written, and rendering them as blank is what the
    // spec opens by complaining about.
    #[test]
    fn declaring_nothing_is_its_own_mark() {
        assert_eq!(asset_mark(&[], None), Mark::Undeclared);
        // And it stays undeclared even if something claims to have probed it —
        // there was nothing to probe.
        assert_eq!(asset_mark(&[], Some("up")), Mark::Undeclared);
    }

    // A WORD OUTSIDE THE VOCABULARY IS A BROKEN ENGINE, and a broken engine must
    // never render as healthy. The mark degrades to unmeasurable, never to
    // measured.
    #[test]
    fn a_word_outside_the_vocabulary_is_unmeasurable() {
        assert_eq!(asset_mark(&a(&["rig"]), Some("excellent")), Mark::Unmeasurable);
        assert_eq!(asset_mark(&a(&["rig"]), Some("")), Mark::Unmeasurable);
    }

    // THE FOUR CHARACTERS ARE DISTINCT. A rendering that used the same glyph
    // twice would collapse two states the whole model exists to separate.
    #[test]
    fn the_four_marks_are_four_different_characters() {
        let cs = [
            mark_char(Mark::Measured),
            mark_char(Mark::Measuring),
            mark_char(Mark::Undeclared),
            mark_char(Mark::Unmeasurable),
        ];
        let mut sorted = cs.to_vec();
        sorted.sort_unstable();
        sorted.dedup();
        assert_eq!(sorted.len(), 4, "got duplicates in {cs:?}");
    }
}
