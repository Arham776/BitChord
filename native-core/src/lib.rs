//! native-core — BitChord's analyzer + playback engine behind one UniFFI boundary.
//!
//! Milestone-1 scaffold (spec §8): empty module tree plus a single exported
//! symbol so the whole bindings → XCFramework → SwiftUI pipeline is provable
//! end to end before real logic lands.

uniffi::setup_scaffolding!();

pub mod analyzer; // spec §2 — milestone 5
pub mod decode; // spec §3.1 — milestones 4-6
pub mod mixer; // spec §3.1 — milestones 4, 6-7
pub mod spatial; // spec §3.3 — milestone 8
pub mod transition_filter; // spec §3.5 — milestone 7

/// Scaffold smoke test: the SwiftUI shell displays this to prove the
/// staticlib links and the UniFFI-generated Swift bindings work.
#[uniffi::export]
pub fn core_version() -> String {
    env!("CARGO_PKG_VERSION").to_string()
}
