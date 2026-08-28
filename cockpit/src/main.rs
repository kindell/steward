// cockpit/src/main.rs — where the cockpit starts.
//
// WHY THIS EXISTS AT ALL. The engine answers `steward sessions --json` with the
// whole fleet, and until now the only way to look at it was a shell loop
// written by hand. This binary is the view.
//
// IT IS DELIBERATELY THIN. Reading the engine belongs to engine.rs, deciding a
// mark belongs to mark.rs, drawing belongs to list.rs. Everything this file
// knows is how to put them in order — which is what keeps each of the other
// three testable without a terminal.

fn main() {
    println!("cockpit: not built yet");
}

#[cfg(test)]
mod tests {
    // THE FIRST TEST IS ABOUT THE HARNESS, NOT THE CODE. Its job is to prove
    // that `cargo test` actually runs inside the canonical suite — a suite that
    // never runs is indistinguishable from a suite that passes, and this
    // project has met that failure often enough to check it deliberately.
    #[test]
    fn the_harness_runs_at_all() {
        assert_eq!(2 + 2, 4);
    }
}
