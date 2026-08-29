//! Bindgen entry point (spec §2) — the official UniFFI route to the
//! `uniffi-bindgen` CLI: a bin in the crate itself, enabled with
//! `--features uniffi/cli`. See scripts/build-native-core.sh.
fn main() {
    uniffi::uniffi_bindgen_main()
}
