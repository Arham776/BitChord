//! SpatialRenderer (spec §3.3): verbatim f32 port of upstream
//! `SpatialAudioProcessor` — mid/side widening + delayed one-pole-lowpassed
//! crossfeed, applied per stream pre-mix, sample-identical passthrough when
//! disabled.
