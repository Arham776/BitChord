//! Mixer (spec §3.1): cpal output + gapless/crossfade mixing.
//!
//! Foundation decision (milestone-4 spike, spec §3.4): **hand-rolled blending,
//! not oddio.** oddio's last release was 2023-10; the scoped fallback needed no
//! downstream changes, and per-voice sample blending in the render loop gives
//! exact control over the equal-power curve and the per-stream DSP stages the
//! spec requires ahead of the blend. Two voices, roles swapping at every
//! transition — the same topology as upstream's active/standby ExoPlayer pair.
//!
//! The transition execution loop is the Rust port of upstream
//! `CrossfadeController`'s decisions: equal-power sin/cos gain pair, 30 ms
//! fade cadence (rendered per chunk here, finer than upstream's tick), the
//! four `TransitionStyle` filter rides with upstream's verbatim constants,
//! arm-lead/timeout, and the 120 ms bail ramp.

use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

use crossbeam_channel::{Receiver, Sender};
use rtrb::Producer;

use crate::decode::resampler::StreamResampler;
use crate::decode::{SourceKind, SymphoniaDecoder};
use crate::eq::{EqCurve, EqualizerProcessor};
use crate::spatial::SpatialRenderer;
use crate::time_stretch::TimeStretch;
use crate::transition_filter::TransitionFilter;

/// Callback surface — the UniFFI-generated Swift side implements this.
pub trait EngineEvents: Send + Sync {
    fn state_changed(&self, state: crate::PlaybackState);
    fn track_ended(&self, reason: crate::TrackEndReason);
    fn error(&self, message: String);
    /// The incoming track became audible: current-track metadata flips now
    /// (upstream fires `onHandoff` as the first note sounds, not at blend end).
    fn handoff(&self, info: TrackInfo);
    fn duration_changed(&self, seconds: f64);
}

#[derive(Debug, Clone)]
pub struct TrackInfo {
    pub title: String,
    pub artist: String,
    pub source: String,
    pub duration_seconds: f64,
    pub codec: String,
    pub sample_rate: u32,
    pub bit_depth: u32,
    pub channels: u32,
    pub kbps: u32,
}

/// What to load and how a transition out of/into it should be rendered.
#[derive(Debug, Clone)]
pub struct TrackSource {
    pub source: String,
    pub title: String,
    pub artist: String,
    /// Start position (Automix cue point). 0 = top.
    pub start_seconds: f64,
    pub plan: TransitionPlan,
    /// HTTP headers for the streaming reader (User-Agent, Origin, Referer).
    pub headers: std::collections::HashMap<String, String>,
    /// Claimed bitrate from the resolver (0 = unknown).
    pub claimed_kbps: u32,
    /// Per-track loudness from the catalogue/player response (`None` for local
    /// files and substitutes, which carry no figure). Upstream keeps the same
    /// map (`StreamResolver.loudnessDbFor`) and the enhancer stays off without
    /// one — normalizing against a made-up number would be worse than not
    /// normalizing.
    pub loudness_db: Option<f64>,
    /// Track length the *caller* knows, from the catalogue response or local
    /// metadata. 0 = unknown.
    ///
    /// The decoder can only report a duration the container declares, and plenty
    /// of what this engine plays declares none: a bare MP3 without a Xing/LAME
    /// duration tag, a progressively-fetched MP4 whose `moov` has not arrived
    /// yet, most WebM. That is not a cosmetic gap — a transition is *scheduled*
    /// against the end of the outgoing track, so with no end there is nowhere
    /// to schedule it, the incoming is never armed, and the queue advances by a
    /// cut at end-of-stream. The caller resolved the track and already has the
    /// number, so it is passed in rather than re-derived.
    pub duration_seconds: f64,
}

/// Port of upstream `playback.smart.TransitionStyle`.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum TransitionStyle {
    EqualPower,
    DjFilter,
    DjBlend,
    Gapless,
}

/// The style fields of upstream `TransitionPlan` — everything the render
/// needs and nothing else. Without analysis (v1) the default renders a plain
/// equal-power fade with filters open, exactly upstream's unanalysed fallback.
#[derive(Debug, Clone)]
pub struct TransitionPlan {
    pub style: TransitionStyle,
    pub bass_swap: bool,
    pub bass_swap_fraction: f64,
    pub filter_sweep: f64,
    pub vocal_overlap: f64,
    /// Explicit fade length for this pair; 0 = engine's crossfade window.
    pub fade_seconds: f64,
    /// Where the blend *ends*, as a position in the outgoing track's own
    /// timeline; 0 means "at the file end".
    ///
    /// The planner chooses this — `outgoing_mix_end`, the ranked mix-out anchor,
    /// which is allowed to sit up to 12 s inside the track — and derives
    /// `bass_swap_fraction` and `vocal_overlap` from the window it defines.
    /// Without it the mixer armed the fade from the file's last byte instead, so
    /// on any track whose anchor is interior the entire blend — gains and both
    /// filter rides together — landed late by however much the anchor is early.
    pub transition_end_seconds: f64,
    pub cue_seconds: f64,
    /// Tempo stretch for the incoming voice's WSOLA stage. Held for the whole
    /// blend, then glided back to unity over `post_glide_seconds`.
    pub playback_rate: f64,
    /// Fade progress where the incoming bed ends and the rise into the swap
    /// begins. 0 means there is no bed — an equal-power fade or a gapless cut.
    pub bed_fraction: f64,
    /// Incoming level during the bed, in dB. About −14 is "playing underneath".
    pub bed_gain_db: f64,
    /// Depth of the one-beat dip in the incoming track just before the bass
    /// swap, 0…1. 0 means the rise is monotonic. The outgoing track never dips.
    pub dip_depth: f64,
    /// Width of that dip as a fraction of the fade. One beat of the shared grid.
    pub dip_width: f64,
    /// How long after the blend the incoming tempo glides home, in seconds.
    /// 0 releases the stretch as the blend ends.
    pub post_glide_seconds: f64,
    /// The outgoing track's length, as the planner measured it. 0 = unknown.
    ///
    /// A transition is scheduled against a planned mix-out anchor or the
    /// outgoing track's end. The decoder cannot always report its duration;
    /// this value lets a plain overlap start before end-of-stream in that case.
    ///
    /// The planner has the figure already — it measured the track to find its
    /// mix-out anchor — so it travels with the plan rather than being asked for
    /// again.
    pub outgoing_duration_seconds: f64,
}

impl Default for TransitionPlan {
    fn default() -> Self {
        Self {
            style: TransitionStyle::EqualPower,
            bass_swap: false,
            bass_swap_fraction: 0.7,
            filter_sweep: 0.0,
            vocal_overlap: 0.0,
            fade_seconds: 0.0,
            transition_end_seconds: 0.0,
            cue_seconds: 0.0,
            playback_rate: 1.0,
            bed_fraction: 0.0,
            bed_gain_db: 0.0,
            dip_depth: 0.0,
            dip_width: 0.0,
            post_glide_seconds: 0.0,
            outgoing_duration_seconds: 0.0,
        }
    }
}

pub enum Command {
    Load {
        request: TrackSource,
        reply: Sender<Result<TrackInfo, String>>,
    },
    /// Same track, better source: open the replacement *at the outgoing voice's
    /// own position* and equal-power crossfade into it over
    /// `crossfade_seconds`. This is upstream's standby-player version swap
    /// (`swapCurrentToVersion`), and the reason it exists is that the reload
    /// path — stop, open, seek — puts a hole in the audio that nothing after it
    /// can hide. The position comes from the engine, not the caller: the
    /// caller only knows the audible playhead, which trails the decoder by the
    /// whole ring.
    SwapSource {
        request: TrackSource,
        crossfade_seconds: f64,
        reply: Sender<Result<TrackInfo, String>>,
    },
    QueueNext {
        request: TrackSource,
    },
    Play,
    Pause,
    Stop,
    /// Move the playhead. Carries no reply: a seek is a request, and blocking
    /// the caller's thread on the mixer's answer is a priority inversion when the
    /// caller is the main thread — which is exactly what a tap on a lyric line
    /// is. Both Android's `MediaPlayer.seekTo` and ExoPlayer's `seekTo` return
    /// before the seek lands, and the position reconciles from the playhead
    /// afterwards. A refusal arrives as an error event instead.
    Seek { seconds: f64 },
    SetVolume(f32),
    SetCrossfadeWindow(f64),
    SetSpatial(bool),
    SetHeadYaw(f32),
    /// Manual filter aim on the current or incoming stream (shared's planner
    /// drives this once analysis exists). Overridden by the automatic ride
    /// while a transition is in flight.
    SetVoiceFilter {
        incoming: bool,
        low_hz: f32,
        high_hz: f32,
    },
    OpenFilters,
    SetPlaybackSpeed(f32),
    SetSkipSilence(bool),
    /// Full equaliser tuning: the ten-slot gains and Qs, the make-up preamp
    /// (computed once by the caller, never on the audio thread), and balance.
    SetEqTuning {
        enabled: bool,
        gains_db: [f32; crate::eq::EqLayout::SLOTS],
        qs: [f32; crate::eq::EqLayout::SLOTS],
        preamp_db: f32,
        balance: f32,
    },
    /// Loudness-normalization master switch. Per-voice gains stay where they
    /// are; the render multiplies by them only while this is set, so toggling
    /// needs no reload.
    SetLoudnessEnabled(bool),
    /// AirPods / speaker swap: new ring producer plus the device's native rate.
    SetOutputFormat {
        rate: u32,
        producer: Producer<f32>,
    },
    Shutdown,
}

// ---- Crossfade constants (verbatim from upstream CrossfadeController) ------

const BAIL_MS: u64 = 120;
const ARM_LEAD_MS: u64 = 4_000;
const ARM_TIMEOUT_MS: u64 = 12_000;
/// Leave this much of the incoming track after a cue so a mix-in cannot
/// land in the outro (upstream `MIN_INCOMING_CLEARANCE_SECONDS`).
const MIN_INCOMING_CLEARANCE_S: f64 = 5.0;
/// Longest mix-in the mixer will open a track at, in seconds and as a fraction
/// of its duration. The planner owns the decision (`analyzer::plan`) and adds a
/// beat-based bound on top; these are the two the mixer can restate, so a plan
/// that somehow arrives too deep is caught before it reaches `seek_seconds`.
///
/// The fraction is a floor for short material, not a ceiling for long: 6 % of a
/// one-minute clip is under four seconds, and an eight-second skip there is an
/// eighth of the record.
const MAX_CUE_SECONDS: f64 = 8.0;
const MAX_CUE_FRACTION: f64 = 0.06;
/// Upstream `swapCurrentToVersion`'s `swapCrossfadeMs` — the equal-power
/// crossfade a same-track source swap (quality upgrade, alternate version)
/// runs over. Long enough to hide a decoder swap, short enough that a
/// same-timeline blend never reads as an edit.
const SWAP_CROSSFADE_MS: f64 = 550.0;

const FILTER_ENTRY_HZ: f64 = 7_000.0;
const FILTER_FLOOR_HZ: f64 = 300.0;
const BASS_SWAP_HZ: f64 = 200.0;
const BASS_SWAP_WIDTH: f64 = 0.10;
const FILTER_SWEEP_SHAPE: f64 = 0.75;
const ENTRY_HIGH_PASS_HZ: f64 = 1_200.0;
const ENTRY_OPEN_BY: f64 = 0.6;
const ENTRY_SHAPE: f64 = 0.35;
const VOCAL_SEPARATION_FLOOR_HZ: f64 = 1_600.0;
const VOCAL_SEPARATION_HIGH_PASS_HZ: f64 = 700.0;
const BLEND_ENTRY_HIGH_PASS_HZ: f64 = 520.0;
const BLEND_ENTRY_OPEN_BY: f64 = 0.45;
const BLEND_ENTRY_CLASH_HIGH_PASS_HZ: f64 = 950.0;
const BLEND_ENTRY_CLASH_OPEN_BY: f64 = 0.7;
const BLEND_EXIT_FROM: f64 = 0.3;
const BLEND_EXIT_LOW_PASS_HZ: f64 = 2_200.0;
const BLEND_EXIT_CLASH_FROM: f64 = 0.12;
const BLEND_EXIT_CLASH_LOW_PASS_HZ: f64 = 1_100.0;

/// Deepest dip a plan may ask for, as a fraction of the incoming gain.
///
/// A one-beat notch of this depth is about −9 dB on the record being brought
/// in. The outgoing track is untouched, so the blend dips a few dB and
/// recovers. Deeper than this reads as the transition losing the thread.
pub(crate) const MAX_DUCK_DEPTH: f64 = 0.65;

/// How long the incoming bed takes to rise out of silence, so the blend does
/// not open on a step.
const BED_ATTACK_SECONDS: f64 = 0.040;

/// Equal-power fall: `cos` of the half turn. Used by the bail ramp and as half
/// of the plain crossfade.
fn fall_gain(progress: f64) -> f32 {
    (progress.clamp(0.0, 1.0) * core::f64::consts::PI / 2.0).cos() as f32
}

fn rise_gain(progress: f64) -> f32 {
    (progress.clamp(0.0, 1.0) * core::f64::consts::PI / 2.0).sin() as f32
}

/// Smoothstep: zero slope at both ends.
fn smoothstep(p: f64) -> f64 {
    let p = p.clamp(0.0, 1.0);
    p * p * (3.0 - 2.0 * p)
}

fn db_to_gain(db: f64) -> f64 {
    10.0_f64.powf(db / 20.0)
}

/// One-beat notch in the incoming gain, centred just before the bass swap.
///
/// Incoming only. The record already playing is the reference; dipping it
/// would dip the song the listener came for. Because the notch sits in a gain
/// that is otherwise climbing, the shape is "gains, quickly loses, gains".
fn dip_gain(progress: f64, plan: &TransitionPlan) -> f32 {
    let depth = plan.dip_depth.clamp(0.0, MAX_DUCK_DEPTH);
    if depth <= 0.0 {
        return 1.0;
    }
    let width = plan.dip_width.clamp(0.015, 0.25);
    let swap = plan.bass_swap_fraction.clamp(0.05, 0.95);
    let centre = (swap - width * 0.5).clamp(0.02, 0.95);
    let x = (progress.clamp(0.0, 1.0) - centre) / (width * 0.5);
    (1.0 - depth * (-x * x).exp()) as f32
}

/// DJ envelope: a ramp across the whole blend, with a bed at the open.
///
/// * The incoming track eases up from silence over ~40 ms, then climbs to
///   unity across the rest of the blend. A one-beat dip can still notch that
///   climb just before the low end changes hands.
/// * The outgoing track stays at full level while that bed is opening, then
///   follows a cos fall over the same span the incoming is climbing. The two
///   move together. Holding the outgoing at unity until a late swap, then
///   dropping it, is a cut once the blend itself is short.
fn automix_gains(progress: f64, plan: &TransitionPlan) -> (f32, f32) {
    let p = progress.clamp(0.0, 1.0);
    let swap = plan.bass_swap_fraction.clamp(0.15, 0.92);
    let bed_end = plan.bed_fraction.clamp(0.05, swap - 0.02);
    let bed = db_to_gain(plan.bed_gain_db).clamp(0.02, 0.5);
    let attack = if plan.fade_seconds > 0.0 {
        (BED_ATTACK_SECONDS / plan.fade_seconds).clamp(0.004, 0.12)
    } else {
        0.02
    };
    let rise = if p <= attack {
        bed * smoothstep(p / attack)
    } else {
        let t = ((p - attack) / (1.0 - attack)).clamp(0.0, 1.0);
        bed + (1.0 - bed) * smoothstep(t)
    };
    let fall = if p <= bed_end {
        1.0
    } else {
        let t = ((p - bed_end) / (1.0 - bed_end)).clamp(0.0, 1.0);
        (t * core::f64::consts::PI / 2.0).cos()
    };
    ((rise * dip_gain(p, plan) as f64) as f32, fall as f32)
}

/// The `(rise, fall)` gain pair for fade progress `p`.
///
/// Which pair is correct depends on whether the two sides carry the same
/// signal, and getting that wrong is audible either way:
///
/// * Different tracks with no DJ envelope are uncorrelated, so their powers
///   add and the equal-power pair holds the level still (`rise² + fall² = 1`).
/// * A source swap is one recording on both sides, aligned, so the amplitudes
///   add. The equal-power pair would then peak at `√2·sin(p·π/2 + π/4)` —
///   +3.01 dB through the middle of every upgrade. A linear pair sums to 1.
/// * A planned DJ blend is neither: [`automix_gains`] holds the outgoing track
///   up while the incoming one plays underneath, then hands over.
fn fade_gains(progress: f64, same_signal: bool) -> (f32, f32) {
    let p = progress.clamp(0.0, 1.0);
    if same_signal {
        (p as f32, (1.0 - p) as f32)
    } else {
        (rise_gain(p), fall_gain(p))
    }
}

/// Geometric interpolation between two cutoffs — pitch is logarithmic.
fn glide(from: f64, to: f64, amount: f64) -> f64 {
    from * (to / from).powf(amount.clamp(0.0, 1.0))
}

fn entry_high_pass(progress: f64, amount: f64, top_hz: f64, open_by: f64) -> f32 {
    let remaining = (1.0 - progress / open_by).clamp(0.0, 1.0);
    glide(
        TransitionFilter::off_hz() as f64,
        top_hz,
        amount * remaining.powf(ENTRY_SHAPE),
    ) as f32
}

fn bass_cutoff(amount: f64) -> f32 {
    glide(TransitionFilter::off_hz() as f64, BASS_SWAP_HZ, amount) as f32
}

fn blend_exit_low_pass(progress: f64, clash: f64) -> f32 {
    let from = BLEND_EXIT_FROM + (BLEND_EXIT_CLASH_FROM - BLEND_EXIT_FROM) * clash;
    let amount = ((progress - from) / (1.0 - from)).clamp(0.0, 1.0);
    let floor = glide(BLEND_EXIT_LOW_PASS_HZ, BLEND_EXIT_CLASH_LOW_PASS_HZ, clash);
    glide(TransitionFilter::open_hz() as f64, floor, amount) as f32
}

fn ride_filter_sweep(progress: f64, plan: &TransitionPlan, out: &mut TransitionFilter, inc: &mut TransitionFilter) {
    let sweep = plan.filter_sweep.clamp(0.0, 1.0);
    if sweep <= 0.0 {
        out.open();
        inc.open();
        return;
    }
    let open = TransitionFilter::open_hz() as f64;
    let entry = glide(open, FILTER_ENTRY_HZ, sweep);
    let floor = glide(open, FILTER_FLOOR_HZ, sweep);
    let cutoff = glide(entry, floor, progress.powf(FILTER_SWEEP_SHAPE));
    out.set_cutoffs(cutoff as f32, TransitionFilter::off_hz());
    inc.set_cutoffs(
        TransitionFilter::open_hz(),
        entry_high_pass(progress, sweep, ENTRY_HIGH_PASS_HZ, ENTRY_OPEN_BY),
    );
}

fn ride_vocal_separation(progress: f64, plan: &TransitionPlan, out: &mut TransitionFilter, inc: &mut TransitionFilter) {
    let amount = plan.vocal_overlap.clamp(0.0, 1.0);
    if amount <= 0.0 {
        out.open();
        inc.open();
        return;
    }
    let open = TransitionFilter::open_hz() as f64;
    let floor = glide(open, VOCAL_SEPARATION_FLOOR_HZ, amount);
    out.set_cutoffs(
        glide(open, floor, progress.powf(FILTER_SWEEP_SHAPE)) as f32,
        TransitionFilter::off_hz(),
    );
    inc.set_cutoffs(
        TransitionFilter::open_hz(),
        entry_high_pass(progress, amount, VOCAL_SEPARATION_HIGH_PASS_HZ, ENTRY_OPEN_BY),
    );
}

fn ride_bass_swap(progress: f64, plan: &TransitionPlan, out: &mut TransitionFilter, inc: &mut TransitionFilter) {
    let swap_at = plan.bass_swap_fraction.clamp(0.05, 0.95);
    let handover = ((progress - swap_at) / BASS_SWAP_WIDTH * 0.5 + 0.5).clamp(0.0, 1.0);
    let clash = plan.vocal_overlap.clamp(0.0, 1.0);
    let entry = bass_cutoff(1.0 - handover).max(entry_high_pass(
        progress,
        1.0,
        glide(BLEND_ENTRY_HIGH_PASS_HZ, BLEND_ENTRY_CLASH_HIGH_PASS_HZ, clash),
        BLEND_ENTRY_OPEN_BY + (BLEND_ENTRY_CLASH_OPEN_BY - BLEND_ENTRY_OPEN_BY) * clash,
    ));
    inc.set_cutoffs(TransitionFilter::open_hz(), entry);
    out.set_cutoffs(blend_exit_low_pass(progress, clash), bass_cutoff(handover));
}

fn ride_filters(progress: f64, plan: &TransitionPlan, out: &mut TransitionFilter, inc: &mut TransitionFilter) {
    match plan.style {
        TransitionStyle::DjFilter => ride_filter_sweep(progress, plan, out, inc),
        TransitionStyle::DjBlend => {
            if plan.bass_swap {
                ride_bass_swap(progress, plan, out, inc)
            } else {
                ride_vocal_separation(progress, plan, out, inc)
            }
        }
        // An album played through: any filtering would be an edit the record
        // didn't ask for.
        TransitionStyle::Gapless => {
            out.open();
            inc.open();
        }
        TransitionStyle::EqualPower => ride_vocal_separation(progress, plan, out, inc),
    }
}

// ---- Voices ----------------------------------------------------------------

const CHUNK_FRAMES: usize = 512;

struct Voice {
    decoder: SymphoniaDecoder,
    resample_l: StreamResampler,
    resample_r: StreamResampler,
    speed_l: StreamResampler,
    speed_r: StreamResampler,
    spatial: SpatialRenderer,
    filter: TransitionFilter,
    gain: f32,
    /// Cue offset at open; zeroed by a seek (decoder position then runs from
    /// file start).
    base_position: f64,
    info: TrackInfo,
    finished: bool,
    /// Device-domain frames emitted (post-resample).
    emitted_dev_frames: u64,
    /// Rate the post-decode DSP is currently running at; changes on a route
    /// rebuild, so it is a field rather than a constructor argument.
    device_rate: u32,
    /// Scratch so the two channels resample with shared phase state.
    channel_l: Vec<f32>,
    channel_r: Vec<f32>,
    /// Device-domain samples decoded/resampled but not yet served, plus the
    /// read cursor — pull never returns more than the caller asked for.
    pending_dev: Vec<f32>,
    pending_dev_cursor: usize,
    skip_silence: bool,
    /// Consecutive silent frames in the *device* domain. Dividing by the
    /// source rate (the earlier bug) made the 1 s floor shrink on 48/96 kHz
    /// output — the "make the music sound rushed" failure upstream raised
    /// `MIN_SILENCE_US` to avoid.
    silent_dev_frames: u64,
    /// The listener's own speed, applied by the speed resampler. Allowed to
    /// move pitch — that is what a speed control is.
    ///
    /// Kept strictly separate from `plan_rate`: folding the handoff stretch
    /// into this resampler is exactly what made it a pitch bend, and the two
    /// being distinguishable here is what stops that coming back.
    effective_speed: f32,
    /// Automix handoff stretch, applied by WSOLA so it moves tempo without
    /// moving pitch. `None` whenever the rate is unity.
    stretch: Option<TimeStretch>,
    /// The handoff stretch has come home to unity and the stage is holding
    /// unplaced samples. It is drained into the output on the next pull rather
    /// than dropped, so retiring it is a handover and not a ~12 ms splice.
    stretch_draining: bool,
    /// Automix tempo stretch target; drives `stretch` and nothing else.
    plan_rate: f64,
    /// The stretch the plan asked for. Held for the blend, then the value the
    /// post-blend glide walks back to unity from.
    base_plan_rate: f64,
    /// Post-blend glide length, from the plan. 0 means release at the blend end.
    post_glide_seconds: f64,
    /// Output frames the glide spans, and how many have been rendered. Both
    /// zero unless a glide is in progress.
    glide_total_frames: u64,
    glide_done_frames: u64,
    /// The track length this voice plans against, if known. `None` means the
    /// container declared none and the caller supplied none, and every
    /// transition that would be scheduled against the end of this track is
    /// therefore impossible.
    known_duration: Option<f64>,
    /// Catalogue loudness figure for the normalization stage (`None` = no
    /// figure, no correction). The master switch lives on the mixer state, so
    /// this is the measurement only.
    loudness_db: Option<f64>,
}

impl Voice {
    /// `cue` marks a fresh start — a track being cued or mixed in — which the
    /// 5-second clearance rule may pull back to the top rather than let it open
    /// inside the outro. A source swap continues a track that is already
    /// playing, so its position is where the listener actually is and nothing
    /// may move it.
    fn open(
        request: &TrackSource,
        spatial_enabled: bool,
        head_yaw: f32,
        device_rate: u32,
        playback_speed: f32,
        skip_silence: bool,
        cue: bool,
    ) -> Result<Voice, String> {
        let kind = SourceKind::parse(&request.source);
        let mut decoder = SymphoniaDecoder::open(&kind, &request.headers)
            .map_err(|e| e.to_string())?;
        let src_rate = decoder.sample_rate();
        // Spatial + transition filter run in the device domain, after
        // resample — same 15 ms Haas window the DAC hears, and clip
        // harmonics never hit the sinc. Upstream's processor is also at
        // the sink rate; an earlier port ran this on source PCM and then
        // resampled the hard-clipped output, which rang.
        let mut spatial = SpatialRenderer::new(device_rate);
        spatial.set_enabled(spatial_enabled && decoder.channels() >= 2);
        spatial.set_head_yaw(head_yaw);
        let decoder_duration = decoder.duration_seconds();
        let mut duration = known_duration(decoder_duration, request.duration_seconds);
        // A download still in progress reports the container length of the
        // bytes on disk. Scheduling the blend against that starts the next
        // song in the middle of this one, over whatever fragment has arrived.
        // The catalogue figure is the length the blend has to land on.
        if source_still_growing(&request.source) && request.duration_seconds > duration + 1.0 {
            duration = request.duration_seconds;
        }
        let start = if cue {
            let cleared = clamp_start_seconds(request.start_seconds, duration);
            bound_mix_in_depth(cleared, &request.plan, duration)
        } else {
            request.start_seconds.max(0.0)
        };
        if start > 0.0 {
            decoder.seek_seconds(start).map_err(|e| e.to_string())?;
        }
        log::info!(
            "voice opened: title={:?} requested_start={:.3}s clamped_start={:.3}s actual_start={:.3}s \
             duration={:.1}s (container={:?} declared={:.1}s) source_rate={} device_rate={}",
            request.title,
            request.start_seconds,
            start,
            decoder.position_seconds(),
            duration,
            decoder_duration,
            request.duration_seconds,
            src_rate,
            device_rate,
        );
        let plan_rate = if request.plan.playback_rate > 0.05 {
            request.plan.playback_rate
        } else {
            1.0
        };
        // The handoff stretch is *not* engaged here. It exists to hold two
        // records on one grid for the length of a blend, and `start_fade` is
        // where a blend begins — a `Load` (a tap on the queue, a skip) carries
        // the same plan record but has no blend to serve, and opening the stage
        // on it would leave a track playing 3 % slow for its whole length with
        // nothing to release it. `plan_rate` is recorded either way so the
        // glide has a number to walk from.
        let effective = (playback_speed as f64).clamp(0.5, 2.0) as f32;
        Ok(Voice {
            resample_l: StreamResampler::new(src_rate, device_rate),
            resample_r: StreamResampler::new(src_rate, device_rate),
            speed_l: speed_resampler(device_rate, effective),
            speed_r: speed_resampler(device_rate, effective),
            spatial,
            filter: TransitionFilter::new(2, device_rate),
            gain: 1.0,
            base_position: 0.0,
            info: TrackInfo {
                title: request.title.clone(),
                artist: request.artist.clone(),
                source: request.source.clone(),
                duration_seconds: duration,
                codec: decoder.codec().to_string(),
                sample_rate: src_rate,
                bit_depth: decoder.bit_depth(),
                channels: decoder.channels() as u32,
                kbps: request.claimed_kbps,
            },
            decoder,
            finished: false,
            emitted_dev_frames: 0,
            device_rate,
            channel_l: Vec::new(),
            channel_r: Vec::new(),
            pending_dev: Vec::new(),
            pending_dev_cursor: 0,
            skip_silence,
            silent_dev_frames: 0,
            effective_speed: effective,
            stretch: None,
            stretch_draining: false,
            plan_rate,
            base_plan_rate: plan_rate,
            post_glide_seconds: request.plan.post_glide_seconds.max(0.0),
            glide_total_frames: 0,
            glide_done_frames: 0,
            known_duration: (duration > 0.0).then_some(duration),
            loudness_db: request.loudness_db,
        })
    }

    fn set_playback_speed(&mut self, speed: f32, device_rate: u32) {
        let effective = (speed as f64).clamp(0.5, 2.0) as f32;
        if (effective - self.effective_speed).abs() < 0.001 {
            return;
        }
        self.effective_speed = effective;
        self.speed_l = speed_resampler(device_rate, effective);
        self.speed_r = speed_resampler(device_rate, effective);
    }

    /// Moves the automix handoff stretch to `rate`.
    ///
    /// Engages the WSOLA stage on the way up and retires it on the way back to
    /// unity. Retiring is a flush-and-drop rather than a bypass: at a rate of
    /// exactly 1.0 the stage reconstructs its input sample for sample, so the
    /// drained tail meets the pass-through with nothing to hear — which is what
    /// lets the glide land on unity at the end of a blend and leave nothing
    /// behind but the audio.
    fn set_plan_rate(&mut self, rate: f64) {
        let rate = if rate.is_finite() && rate > 0.0 { rate } else { 1.0 };
        self.plan_rate = rate;
        if (rate - 1.0).abs() <= 1e-4 {
            // Hold the stage until the next pull drains it.
            self.stretch_draining = self.stretch.is_some();
        } else if let Some(stretch) = self.stretch.as_mut() {
            stretch.set_rate(rate);
        } else {
            self.stretch = Some(TimeStretch::new(rate));
        }
    }

    /// The natural end of a stretched stream: drain the stage into the pending
    /// buffer and drop it. Returns the drained samples so the caller can splice
    /// them in ahead of whatever comes next.
    fn drain_stretch(&mut self) -> Vec<f32> {
        match self.stretch.as_mut() {
            Some(stretch) => {
                stretch.flush();
                let tail = stretch.take();
                self.stretch = None;
                tail
            }
            None => Vec::new(),
        }
    }

    /// Releases the tempo stretch a beatmatched handoff stacked on this voice.
    ///
    /// The stretch exists only to hold two tracks on a shared grid for the
    /// length of the blend. Upstream undoes it unconditionally and idempotently
    /// the moment the fade ends — `CrossfadeController.finish` and `retire`
    /// both call `setPlaybackSpeed(AppSettings.playbackSpeed.value)` — because a
    /// voice that keeps it plays fast for its whole length: +3 % tempo and +51
    /// cents on every track that ever arrived through a beatmatched blend, with
    /// the published position running at the stretched rate as well.
    ///
    /// The guarantee for a voice that never got to glide: a skip, a bail, a
    /// cut at end-of-stream. Snaps the rate to unity and drains the stage on
    /// the next pull. A finished blend does not come here first — it calls
    /// [`Voice::begin_tempo_glide`] and this runs when that glide lands.
    fn release_plan_stretch(&mut self, speed: f32, device_rate: u32) {
        self.glide_total_frames = 0;
        self.glide_done_frames = 0;
        if (self.plan_rate - 1.0).abs() < f64::EPSILON && !self.stretch_draining {
            return;
        }
        // Clear the multiplier *before* re-deriving, or `set_playback_speed`
        // would simply stack the stretch back on.
        self.plan_rate = 1.0;
        self.stretch_draining = self.stretch.is_some();
        self.set_playback_speed(speed, device_rate);
    }

    /// Starts the post-blend walk from the matched tempo back to the record's
    /// own. No-op when the plan asked for none, in which case the caller
    /// releases immediately.
    fn begin_tempo_glide(&mut self, device_rate: u32) {
        if self.post_glide_seconds <= 0.05 || (self.base_plan_rate - 1.0).abs() < 1e-4 {
            return;
        }
        let frames = (self.post_glide_seconds * device_rate.max(1) as f64)
            .round()
            .max(1.0) as u64;
        self.glide_total_frames = frames;
        self.glide_done_frames = 0;
        self.set_plan_rate(self.base_plan_rate);
    }

    /// Sets the stretch to where the glide has reached. Call once per rendered
    /// chunk, before the pull, then [`Voice::note_glide_frames`] with what
    /// came out.
    fn drive_tempo_glide(&mut self, device_rate: u32, speed: f32) {
        if self.glide_total_frames == 0 {
            return;
        }
        let p = (self.glide_done_frames as f64 / self.glide_total_frames as f64).clamp(0.0, 1.0);
        if p >= 1.0 {
            self.release_plan_stretch(speed, device_rate);
            return;
        }
        let target = glided_plan_rate(self.base_plan_rate, p);
        if (target - self.plan_rate).abs() >= 1e-5 {
            self.set_plan_rate(target);
        }
    }

    fn note_glide_frames(&mut self, frames: u64) {
        if self.glide_total_frames > 0 {
            self.glide_done_frames = self.glide_done_frames.saturating_add(frames);
        }
    }

    /// Rebuild post-decode DSP for a new DAC rate (AirPods connect/disconnect).
    fn retarget_device(&mut self, device_rate: u32, spatial_enabled: bool, head_yaw: f32) {
        let src = self.info.sample_rate.max(1);
        self.device_rate = device_rate;
        let enabled = self.spatial.enabled();
        self.resample_l = StreamResampler::new(src, device_rate);
        self.resample_r = StreamResampler::new(src, device_rate);
        self.speed_l = speed_resampler(device_rate, self.effective_speed);
        self.speed_r = speed_resampler(device_rate, self.effective_speed);
        let mut spatial = SpatialRenderer::new(device_rate);
        spatial.set_enabled(enabled && spatial_enabled && self.info.channels >= 2);
        spatial.set_head_yaw(head_yaw);
        self.spatial = spatial;
        self.filter = TransitionFilter::new(2, device_rate);
        self.pending_dev.clear();
        self.pending_dev_cursor = 0;
    }

    fn position_seconds(&self) -> f64 {
        let decoder = self.base_position + self.decoder.position_seconds();
        // The WSOLA stage holds roughly a frame of input it has not placed yet,
        // so the decoder runs that far ahead of the audio the listener is
        // hearing. Bounded at `FRAME + SEARCH` — about 12 ms — and only while a
        // handoff stretch is running, but a playhead that leads the sound is
        // the same bug as one that trails it.
        (decoder - self.stretch_latency_seconds()).max(0.0)
    }

    /// How far ahead of the output the decoder is running, in source seconds.
    fn stretch_latency_seconds(&self) -> f64 {
        self.stretch
            .as_ref()
            .map(|stretch| stretch.latency_frames() / self.device_rate.max(1) as f64)
            .unwrap_or(0.0)
    }

    /// Where this voice's *next served sample* sits on the source timeline.
    ///
    /// [`position_seconds`] is the decoder's read head, which runs ahead of the
    /// output by whatever `pending_dev` is holding. Opening a replacement
    /// source at that figure would leave it up to a full decode batch — around
    /// 190 ms at 22.05 kHz — behind the voice it is replacing, and a
    /// same-timeline crossfade that far out of alignment is heard as a doubled
    /// voice rather than as a quality change. Resampling preserves time, so the
    /// un-served device tail converts straight back to source seconds; the
    /// playback-speed factor maps it through the speed resampler.
    fn emitted_position_seconds(&self) -> f64 {
        let pending_frames =
            (self.pending_dev.len().saturating_sub(self.pending_dev_cursor) / 2) as f64;
        let pending_seconds =
            pending_frames / self.device_rate.max(1) as f64 * self.effective_speed as f64;
        (self.position_seconds() - pending_seconds).max(0.0)
    }

    /// Remaining source-domain seconds the decoder still holds, if known.
    ///
    /// `info.duration_seconds` rather than the decoder's own figure, so a
    /// container that declares no length still schedules: `remaining_seconds`
    /// is what the arming and the fade start are both measured against, and
    /// `None` here means "there is no end to schedule against", which is a cut,
    /// not a blend.
    fn remaining_seconds(&self) -> Option<f64> {
        let total = self.known_duration?;
        Some((total - self.decoder.position_seconds()).max(0.0))
    }

    /// Pulls up to `frames` device-domain interleaved stereo frames.
    /// Pulls up to `frames` device-domain interleaved stereo frames. Never
    /// returns more than asked: decoded batches overshooting the request are
    /// stashed in `pending_dev` and served on later calls.
    fn pull(&mut self, frames: usize, device_rate: u32) -> Vec<f32> {
        let want = (frames * 2).max(2);
        let mut out: Vec<f32> = Vec::with_capacity(want);

        let serve_pending = |out: &mut Vec<f32>, voice: &mut Voice| {
            let remaining = want - out.len();
            if remaining == 0 || voice.pending_dev_cursor >= voice.pending_dev.len() {
                return;
            }
            let take = (voice.pending_dev.len() - voice.pending_dev_cursor).min(remaining);
            out.extend_from_slice(&voice.pending_dev[voice.pending_dev_cursor..voice.pending_dev_cursor + take]);
            voice.pending_dev_cursor += take;
            voice.emitted_dev_frames += (take / 2) as u64;
        };
        serve_pending(&mut out, self);

        // The handoff stretch has landed on unity: flush the stage and serve
        // what it was still holding before decoding anything more, so the
        // handover to the plain path is sample-continuous.
        if self.stretch_draining {
            self.stretch_draining = false;
            let tail = self.drain_stretch();
            if !tail.is_empty() {
                let remaining = want - out.len();
                let take = tail.len().min(remaining);
                out.extend_from_slice(&tail[..take]);
                self.emitted_dev_frames += (take / 2) as u64;
                if take < tail.len() {
                    self.pending_dev = tail;
                    self.pending_dev_cursor = take;
                }
                if out.len() >= want {
                    return out;
                }
            }
        }

        while out.len() < want && !self.finished {
            let src = self.decoder.read_stereo(4096).unwrap_or_default();
            if src.is_empty() {
                self.finished = true;
                // Drain the resampler tails into the pending buffer.
                let tail_l = self.resample_l.flush();
                let tail_r = self.resample_r.flush();
                let n = tail_l.len().min(tail_r.len());
                self.pending_dev.clear();
                self.pending_dev_cursor = 0;
                for i in 0..n {
                    self.pending_dev.push(tail_l[i]);
                    self.pending_dev.push(tail_r[i]);
                }
                // A stretch still running at end of stream gets flushed, or the
                // last few milliseconds of the record are simply gone. The
                // resampler tail goes *through* it rather than being pasted onto
                // its output, so the two arrive in the order the chain actually
                // produced them.
                if self.stretch.is_some() {
                    let input = core::mem::take(&mut self.pending_dev);
                    let mut tail = self
                        .stretch
                        .as_mut()
                        .expect("checked above")
                        .process_and_take(&input);
                    let mut rest = self.drain_stretch();
                    tail.append(&mut rest);
                    self.pending_dev = tail;
                }
                // Device-domain DSP (spatial, then transition filter) — same
                // order as upstream's sink processors, at the rate the DAC hears.
                self.spatial.process(&mut self.pending_dev);
                self.filter.process(&mut self.pending_dev);
                serve_pending(&mut out, self);
                break;
            }
            self.channel_l.clear();
            self.channel_r.clear();
            for pair in src.chunks_exact(2) {
                self.channel_l.push(pair[0]);
                self.channel_r.push(pair[1]);
            }

            let out_l = self.resample_l.process(&self.channel_l);
            let out_r = self.resample_r.process(&self.channel_r);
            let n = out_l.len().min(out_r.len());
            let (speed_l, speed_r) = if (self.effective_speed - 1.0).abs() < 0.001 {
                (out_l, out_r)
            } else {
                (
                    self.speed_l.process(&out_l[..n]),
                    self.speed_r.process(&out_r[..n]),
                )
            };
            let n = speed_l.len().min(speed_r.len());
            self.pending_dev.clear();
            self.pending_dev_cursor = 0;
            for i in 0..n {
                self.pending_dev.push(speed_l[i]);
                self.pending_dev.push(speed_r[i]);
            }
            // The handoff stretch runs here: in the device domain, after the
            // listener's own speed (which is allowed to move pitch) and before
            // the spatial and transition stages — so the blend's EQ is shaping
            // the stretched signal rather than being stretched itself, and a
            // filter sweep lands on the beat it was aimed at.
            if self.stretch.is_some() {
                let input = core::mem::take(&mut self.pending_dev);
                self.pending_dev = self
                    .stretch
                    .as_mut()
                    .expect("checked above")
                    .process_and_take(&input);
            }
            // Classify silence on the dry buffer. Spatial's 0.82 makeup
            // would otherwise pull quiet music under the threshold whenever
            // widening is on. DSP still runs so the delay line stays
            // continuous across a drop.
            let silent = self.skip_silence && is_silent(&self.pending_dev);
            self.spatial.process(&mut self.pending_dev);
            self.filter.process(&mut self.pending_dev);
            if silent {
                self.silent_dev_frames += (self.pending_dev.len() / 2) as u64;
                // Upstream MIN_SILENCE_US = 1 s: keep the first second so a
                // breath still lands, then trim the rest of the gap. Upstream
                // keeps a 20 % sliver (capped at 2 s) at 10 % volume rather
                // than cutting to true digital silence, so a skipped gap still
                // reads as a gap and never clicks.
                if silence_exceeds_floor(self.silent_dev_frames, device_rate) {
                    let silent_s = self.silent_dev_frames as f64 / device_rate as f64;
                    if silent_s <= MIN_SILENCE_SECS + MAX_SILENCE_KEEP_SECS {
                        // Keep every 5th frame (20 % retention) at −20 dB.
                        let mut kept: Vec<f32> =
                            Vec::with_capacity(self.pending_dev.len() / 5 + 2);
                        for frame in self.pending_dev.chunks_exact(2).step_by(5) {
                            kept.push(frame[0] * MIN_VOLUME_TO_KEEP);
                            kept.push(frame[1] * MIN_VOLUME_TO_KEEP);
                        }
                        self.pending_dev = kept;
                        self.pending_dev_cursor = 0;
                    } else {
                        self.pending_dev.clear();
                        self.pending_dev_cursor = 0;
                        continue;
                    }
                }
            } else {
                self.silent_dev_frames = 0;
            }
            serve_pending(&mut out, self);
        }
        out
    }
}

/// Media3 `DEFAULT_SILENCE_THRESHOLD_LEVEL` (1024 of int16 full scale).
const SILENCE_THRESHOLD: f32 = 1024.0 / 32768.0;
/// Upstream `PlaybackService.MIN_SILENCE_US` — shortest gap we'll trim.
const MIN_SILENCE_SECS: f64 = 1.0;
/// Upstream Media3 `DEFAULT_MAX_SILENCE_TO_KEEP_DURATION_US` (2 s) — cap on the
/// sliver of a trimmed gap that is kept.
const MAX_SILENCE_KEEP_SECS: f64 = 2.0;
/// Upstream Media3 `DEFAULT_MIN_VOLUME_TO_KEEP_PERCENTAGE` (10) — the kept
/// sliver is faded to −20 dB rather than true digital silence.
const MIN_VOLUME_TO_KEEP: f32 = 0.1;

/// Upstream `PlaybackService.MIN/MAX_LOUDNESS_GAIN_MB`: the enhancer's target
/// gain is the track's loudness figure negated, clamped to −15 dB … +3 dB.
/// A figure is a measurement of *this* track, so the correction can only ever
/// be its inverse; the clamp is what stops a bad figure from pinning the
/// output.
pub const MIN_LOUDNESS_GAIN_DB: f64 = -15.0;
pub const MAX_LOUDNESS_GAIN_DB: f64 = 3.0;

/// The loudness correction for one voice: linear gain plus the applied dB for
/// the readout. `(1.0, None)` whenever there is nothing to correct with — the
/// switch off, no figure, or a non-finite one — which is also what the nerd
/// stats and the pipeline panel report, so "no correction" reads as absent
/// rather than as zero.
pub fn loudness_gain(loudness_db: Option<f64>, enabled: bool) -> (f32, Option<f32>) {
    match (enabled, loudness_db) {
        (true, Some(db)) if db.is_finite() => {
            let gain_db = (-db).clamp(MIN_LOUDNESS_GAIN_DB, MAX_LOUDNESS_GAIN_DB);
            (10f64.powf(gain_db / 20.0) as f32, Some(gain_db as f32))
        }
        _ => (1.0, None),
    }
}

/// The track length the engine will plan a transition against.
///
/// The container's own figure wins when it has one — it is measured from the
/// bytes actually being decoded, and a catalogue figure can be a rounding of a
/// different edit of the same record. The caller's figure is the fallback for
/// the containers that declare nothing, which is where a transition either gets
/// scheduled or does not happen at all.
fn known_duration(container: Option<f64>, declared: f64) -> f64 {
    container
        .filter(|d| d.is_finite() && *d > 0.0)
        .or_else(|| Some(declared).filter(|d| d.is_finite() && *d > 0.0))
        .unwrap_or(0.0)
}

/// `.grow` without `.complete` is a stream that has not finished arriving.
fn source_still_growing(path: &str) -> bool {
    if path.is_empty() || path.contains("://") {
        return false;
    }
    let grow = format!("{path}.grow");
    let complete = format!("{path}.complete");
    std::path::Path::new(&grow).is_file() && !std::path::Path::new(&complete).exists()
}

fn speed_resampler(device_rate: u32, speed: f32) -> StreamResampler {
    let speed = speed.clamp(0.5, 2.0) as f64;
    StreamResampler::with_rates(device_rate as f64 * speed, device_rate as f64)
}

/// The stretch ratio at fade progress `p`: `base` walked to unity, or unity if
/// there is nothing to walk.
///
/// A *step* in the rate is a step in pitch as well as tempo:
/// `release_plan_stretch` undoing a 3 % stretch is 51 cents arriving in one
/// frame, at whatever gain the blend had reached. Upstream does exactly that,
/// and James Cridland's write-up of Apple's AutoMix names the audible artefact
/// of the smoother version of the same trick — "a bit of obvious speed slowing"
/// — as the mark of a real transition rather than a fault. What makes it read as
/// a move rather than a glitch is the ramp.
///
/// Geometric, because rate is a ratio: an exponential sweep is a constant slope
/// in cents per second, so the ear hears an even glide rather than a fast start
/// and a slow crawl. At `p = 1` it is exactly 1.0, which is the whole point —
/// the release then finds the rate already at unity and is a no-op, so there is
/// nothing to snap.
fn glided_plan_rate(base: f64, p: f64) -> f64 {
    if !base.is_finite() || base <= 0.0 || (base - 1.0).abs() < 1e-6 {
        return 1.0;
    }
    let p = p.clamp(0.0, 1.0);
    if p >= 1.0 {
        1.0
    } else {
        base.powf(1.0 - p)
    }
}

fn is_silent(interleaved: &[f32]) -> bool {
    // Empty is "no audio yet" (resampler still priming), not a gap to trim.
    if interleaved.is_empty() {
        return false;
    }
    interleaved.iter().all(|s| s.abs() < SILENCE_THRESHOLD)
}

fn silence_exceeds_floor(silent_dev_frames: u64, device_rate: u32) -> bool {
    silent_dev_frames as f64 / device_rate.max(1) as f64 > MIN_SILENCE_SECS
}

/// A voice's fade gain with the loudness correction folded in.
///
/// The fade gain (`voice.gain`) is the mix; the loudness gain is the level.
/// Multiplying here rather than in `Voice::pull` keeps the measurement (peak
/// classification for skip-silence) on the uncorrected signal — a quiet track
/// turned up is still a quiet track as far as gap detection is concerned.
fn applied_gain(voice: &Voice, loudness_enabled: bool) -> f32 {
    voice.gain * loudness_gain(voice.loudness_db, loudness_enabled).0
}

/// A cue in the last few seconds is the outro, not a mix-in. Fall back to
/// the top of the file rather than starting the next song near its end.
fn clamp_start_seconds(requested: f64, duration: f64) -> f64 {
    let requested = requested.max(0.0);
    if requested <= 0.0 {
        return 0.0;
    }
    if duration <= 0.0 {
        return requested;
    }
    if requested >= (duration - MIN_INCOMING_CLEARANCE_S).max(0.0) {
        log::warn!(
            "cue {requested:.1}s is within {MIN_INCOMING_CLEARANCE_S}s of duration {duration:.1}s; starting at 0"
        );
        return 0.0;
    }
    requested
}

/// The last bound on a planned mix-in, applied to the value about to reach
/// `seek_seconds`.
///
/// The planner already applies this three ways, so this is deliberately
/// redundant. It is here because of how the original bug got so far: nothing
/// between the analysis and the decoder was willing to disagree with the layer
/// above it, and a plan asking to start the next record a minute in was obeyed
/// all the way down. A redundant check costs a comparison.
///
/// Only a *planned* mix-in is bounded. `start_seconds` doubles as a resume
/// position — `loadCurrent(startAt:)` after a cold restore carries a timestamp
/// minutes into the track and no plan — and clamping that would throw the
/// listener back to the top of a song they had just reopened.
fn bound_mix_in_depth(requested: f64, plan: &TransitionPlan, duration: f64) -> f64 {
    if requested <= 0.0 || duration <= 0.0 || plan.cue_seconds <= 0.0 {
        return requested;
    }
    let ceiling = MAX_CUE_SECONDS.min(duration * MAX_CUE_FRACTION);
    if requested > ceiling {
        log::warn!(
            "planned mix-in at {requested:.1}s exceeds the {MAX_CUE_SECONDS}s / \
             {MAX_CUE_FRACTION} bound for a {duration:.1}s track; starting at 0"
        );
        return 0.0;
    }
    requested
}

// ---- Transition state -------------------------------------------------------

#[derive(PartialEq, Clone, Copy)]
#[allow(dead_code)]
enum Phase {
    Idle,
    Arming,
    Fading,
}

struct TransitionState {
    phase: Phase,
    fade_frames: u64,
    handed_off: bool,
    plan: TransitionPlan,
    arm_deadline: Instant,
    /// A same-track source swap (quality upgrade / alternate version) rather
    /// than a queue advance. Upstream fades these with a plain equal-power
    /// curve and no filter ride — filtering a track against itself would edit
    /// the record — and never reports a track change for them.
    swap: bool,
}

struct RetiringVoice {
    voice: Voice,
    from_gain: f32,
    started_at: Instant,
}

struct MixerState {
    current: Option<Voice>,
    incoming: Option<Voice>,
    pending_next: Option<TrackSource>,
    /// Latched once a transition has been found unschedulable, so the warning
    /// about it is one line per track rather than one per chunk.
    warned_no_duration: bool,
    transition: Option<TransitionState>,
    retiring: Vec<RetiringVoice>,
    playing: bool,
    volume: f32,
    crossfade_window_s: f64,
    spatial_enabled: bool,
    head_yaw: f32,
    device_rate: u32,
    /// Frames pushed to the ring minus frames the callback consumed. The
    /// render loop needs this to know how much audio is still *audible* (ring
    /// backlog counts toward a track's tail).
    buffered_frames: Arc<AtomicU64>,
    position_ms: Arc<AtomicU64>,
    duration_ms: Arc<AtomicU64>,
    events: Arc<dyn EngineEvents>,
    state: crate::PlaybackState,
    /// Set by Load/Stop; the device callback discards leftover ring samples
    /// so the previous track cannot keep sounding under the new one.
    flush_ring: Arc<AtomicBool>,
    /// Set by hard_cut (skip / Load / Stop); the device callback ramps down
    /// the outgoing audio over 120 ms before discarding the backlog.
    bail_flush: Arc<AtomicBool>,
    playback_speed: f32,
    skip_silence: bool,
    eq: EqualizerProcessor,
    nerd: Arc<Mutex<NerdSnapshot>>,
    /// Loudness-normalization master switch (upstream
    /// `AppSettings.loudnessNormalization`, on by default). Per-voice figures
    /// ride on the voices; this decides whether the render uses them.
    loudness_enabled: bool,
    /// Correlation probe for a source swap, see [`SwapProbe`].
    swap_probe: SwapProbe,
}

/// Measures how correlated the two sides of a source swap really are.
///
/// A swap fades one recording into another copy of itself, and which gain pair
/// keeps that level-flat depends entirely on the correlation `ρ` between the
/// two encodings: the linear pair is flat at ρ=1 and the equal-power pair at
/// ρ=0, and the port's deviation from flat with the linear pair is
/// `10·log10((1+ρ)/2)` — 0 dB at ρ=1, −0.11 at 0.95, −1.25 at 0.5.
///
/// Nothing else can supply that number, because it depends on how two encoders
/// of one master differ, so it has to come from a real upgrade. This reads it
/// off the samples that are genuinely being blended: both voices are already
/// decoded and aligned by the time they are rendered, so the probe costs a few
/// multiplies per sample for the length of the fade — no extra decoding and no
/// perturbation of what the listener hears.
#[derive(Default)]
struct SwapProbe {
    /// The outgoing voice's samples for the current chunk.
    current: Vec<f32>,
    /// How many of those the incoming voice's chunk also covers.
    len: usize,
    sum_aa: f64,
    sum_ab: f64,
    sum_bb: f64,
}

impl SwapProbe {
    fn reset(&mut self) {
        self.len = 0;
        self.sum_aa = 0.0;
        self.sum_ab = 0.0;
        self.sum_bb = 0.0;
    }

    /// Records the outgoing side of a chunk.
    fn observe_current(&mut self, frames: &[f32]) {
        if self.current.len() < frames.len() {
            self.current.resize(frames.len(), 0.0);
        }
        self.len = frames.len();
        self.current[..self.len].copy_from_slice(frames);
        for sample in &self.current[..self.len] {
            self.sum_aa += (*sample as f64) * (*sample as f64);
        }
    }

    /// Records the incoming side and the cross term. The fade gains are
    /// positive scalars, so they cancel out of a normalised correlation and
    /// the raw samples can be used on both sides.
    fn observe_incoming(&mut self, frames: &[f32]) {
        let n = frames.len().min(self.len);
        for index in 0..n {
            let outgoing = self.current[index] as f64;
            let incoming = frames[index] as f64;
            self.sum_ab += outgoing * incoming;
            self.sum_bb += incoming * incoming;
        }
    }

    /// Pearson correlation at zero lag, or `None` until both sides have been
    /// seen and both carry signal.
    fn correlation(&self) -> Option<f64> {
        if self.sum_aa <= 0.0 || self.sum_bb <= 0.0 {
            return None;
        }
        Some(self.sum_ab / (self.sum_aa.sqrt() * self.sum_bb.sqrt()))
    }
}

#[derive(Debug, Clone, Default)]
pub struct NerdSnapshot {
    pub codec: String,
    pub sample_rate: u32,
    pub bit_depth: u32,
    pub channels: u32,
    pub kbps: u32,
    /// Applied loudness correction in dB (`None` = no correction: switch off
    /// or no figure). The pipeline panel reads this, not the switch — the
    /// switch is the request, this is the answer.
    pub loudness_gain_db: Option<f32>,
    /// Pearson correlation between the two encodings of the last source swap,
    /// measured on the samples that were actually blended. `None` until a swap
    /// has run. This is data about the catalogue — how alike two encoders of one
    /// master are — and it is the only number that says whether the swap's
    /// linear fade is the flat one.
    pub swap_correlation: Option<f64>,
}

impl MixerState {
    fn set_state(&mut self, state: crate::PlaybackState) {
        if self.state != state {
            self.state = state;
            self.events.state_changed(state);
        }
    }

    fn publish_nerd(&self, info: &TrackInfo, loudness_db: Option<f64>) {
        let (_, gain_db) = loudness_gain(loudness_db, self.loudness_enabled);
        if let Ok(mut nerd) = self.nerd.lock() {
            // Preserved: it describes the last swap, not this track.
            let correlation = nerd.swap_correlation;
            *nerd = NerdSnapshot {
                codec: info.codec.clone(),
                sample_rate: info.sample_rate,
                bit_depth: info.bit_depth,
                channels: info.channels,
                kbps: info.kbps,
                loudness_gain_db: gain_db,
                swap_correlation: correlation,
            };
        }
    }

    /// Upstream `retire` + skip: drop every voice and the pending next so a
    /// user-chosen track cannot mix with the one it replaced.
    ///
    /// Rather than hard-clearing the output ring on a sample boundary (which
    /// produces an audible click), triggers `bail_flush`: the output callback
    /// smoothly ramps out the next 120 ms of buffered audio and discards the
    /// remaining backlog before the new track starts.
    fn hard_cut(&mut self) {
        self.transition = None;
        self.incoming = None;
        self.pending_next = None;
        self.retiring.clear();
        self.current = None;
        self.bail_flush.store(true, Ordering::Release);
    }

    /// Gapless: the current track ended and the next file is already queued.
    fn promote_pending(&mut self) {
        let Some(request) = self.pending_next.take() else {
            return;
        };
        match Voice::open(
            &request,
            self.spatial_enabled,
            self.head_yaw,
            self.device_rate,
            self.playback_speed,
            self.skip_silence,
            true,
        ) {
            Ok(mut voice) => {
                voice.gain = 1.0;
                voice.release_plan_stretch(self.playback_speed, self.device_rate);
                let info = voice.info.clone();
                let duration = info.duration_seconds;
                let (_, gain_db) = loudness_gain(voice.loudness_db, self.loudness_enabled);
                if let Ok(mut nerd) = self.nerd.lock() {
                    let correlation = nerd.swap_correlation;
                    *nerd = NerdSnapshot {
                        codec: info.codec.clone(),
                        sample_rate: info.sample_rate,
                        bit_depth: info.bit_depth,
                        channels: info.channels,
                        kbps: info.kbps,
                        loudness_gain_db: gain_db,
                        swap_correlation: correlation,
                    };
                }
                log::info!("promoted pending next: {}", info.title);
                self.current = Some(voice);
                self.duration_ms
                    .store((duration * 1000.0) as u64, Ordering::Relaxed);
                if duration > 0.0 {
                    self.events.duration_changed(duration);
                }
                self.publish_audible_position();
                self.events.handoff(info);
            }
            Err(e) => {
                log::warn!("promote pending failed for {}: {e}", request.title);
                self.events.error(format!("could not prepare next track: {e}"));
            }
        }
    }

    fn promote_incoming(&mut self) {
        if let Some(mut incoming) = self.incoming.take() {
            incoming.gain = 1.0;
            incoming.filter.open();
            // It is the session voice now; a beatmatched handoff's stretch does
            // not outlive the blend it was for.
            incoming.release_plan_stretch(self.playback_speed, self.device_rate);
            let info = incoming.info.clone();
            let duration = info.duration_seconds;
            self.current = Some(incoming);
            self.duration_ms
                .store((duration * 1000.0) as u64, Ordering::Relaxed);
            if duration > 0.0 {
                self.events.duration_changed(duration);
            }
            let db = self.current.as_ref().and_then(|v| v.loudness_db);
            self.publish_nerd(&info, db);
            self.publish_audible_position();
            self.events.handoff(info);
        }
        self.transition = None;
    }

    /// Replaces the current voice's source in place, crossfading into the
    /// replacement — upstream `swapCurrentToVersion`.
    ///
    /// The replacement opens at the outgoing voice's *emitted* position, so the
    /// moment the fade starts both voices are reading the same instant of the
    /// same recording. The fade is driven by the incoming voice's own output,
    /// so it waits for the decoder to prime rather than guessing how long that
    /// takes; until then the outgoing voice stays at unity and nothing is lost.
    fn swap_source(
        &mut self,
        request: TrackSource,
        crossfade_seconds: f64,
    ) -> Result<TrackInfo, String> {
        if self.current.is_none() {
            return Err("no track to swap".into());
        }
        // A queue transition in flight belongs to the track that is leaving.
        // Abandoning it here would promote an incoming track we are about to
        // discard, so the swap is refused instead and the caller can retry.
        if self.transition.is_some() {
            return Err("a transition is already running".into());
        }
        // The blend has not armed yet, but it is inside the window where it
        // will. A 550 ms source swap would take the only transition slot, the
        // song change would never arm, and the next track would cut in.
        if self.pending_next.is_some() {
            if let Some(current) = &self.current {
                let plan = self
                    .pending_next
                    .as_ref()
                    .map(|request| request.plan.clone())
                    .unwrap_or_default();
                let fade_s = self.blend_seconds(
                    plan.fade_seconds,
                    current.known_duration.unwrap_or(0.0),
                );
                let tail = self.audible_tail_s(&plan, current);
                let horizon = fade_s + ARM_LEAD_MS as f64 / 1000.0;
                if tail.is_finite() && tail <= horizon {
                    return Err("a transition is already running".into());
                }
            }
        }
        let anchor = self
            .current
            .as_ref()
            .map(|voice| voice.emitted_position_seconds())
            .unwrap_or(0.0);
        let mut request = request;
        request.start_seconds = anchor;
        let mut voice = Voice::open(
            &request,
            self.spatial_enabled,
            self.head_yaw,
            self.device_rate,
            self.playback_speed,
            self.skip_silence,
            false,
        )?;
        voice.gain = 0.0; // silent until the fade lifts it
        let info = voice.info.clone();
        let seconds = if crossfade_seconds > 0.0 {
            crossfade_seconds
        } else {
            SWAP_CROSSFADE_MS / 1000.0
        };
        let fade_frames = (seconds * self.device_rate as f64).max(1.0) as u64;
        log::info!(
            "source swap: {} at {:.3}s, {:.0}ms crossfade",
            info.source,
            anchor,
            seconds * 1000.0
        );
        self.swap_probe.reset();
        self.incoming = Some(voice);
        self.transition = Some(TransitionState {
            phase: Phase::Fading,
            fade_frames,
            handed_off: true,
            plan: TransitionPlan::default(),
            arm_deadline: Instant::now(),
            swap: true,
        });
        // Same track, same instant: the timeline does not move, so this only
        // re-points the playhead at the replacement voice.
        self.publish_audible_position();
        Ok(info)
    }

    /// Arms a transition when the current track's audible tail is close
    /// enough. Returns true if a transition was created.
    /// Where the outgoing track ends, on its own timeline, or `INFINITY` when
    /// nothing knows.
    ///
    /// The planned anchor is authoritative for when to transition. The
    /// duration figures are the fallback when no anchor was analyzed.
    ///
    /// 1. `transition_end_seconds` — the planner's ranked mix-out anchor, which
    ///    is where the blend is meant to *finish* and can sit up to 12 s inside
    ///    the track. Using it is what stops a whole blend landing late.
    /// 2. `outgoing_duration_seconds` — the planner's measurement of the track,
    ///    which exists for exactly the case the decoder cannot cover.
    /// 3. The live decoder's own remaining time, which is the file end and is
    ///    `None` for a container that declares no length.
    ///
    /// The second is not redundant with the third on purpose: the planner reads
    /// the track through the metadata reader to find its mix-out anchor, so it
    /// has a figure in hand whether or not the decoder that will play the track
    /// was able to work one out.
    fn outgoing_end_s(&self, plan: &TransitionPlan, current: &Voice) -> f64 {
        if plan.transition_end_seconds > 0.0 {
            return plan.transition_end_seconds;
        }
        if current.known_duration.is_some() {
            return current.known_duration.unwrap_or(0.0);
        }
        if plan.outgoing_duration_seconds > 0.0 {
            return plan.outgoing_duration_seconds;
        }
        current.position_seconds() + current.remaining_seconds().unwrap_or(f64::INFINITY)
    }

    /// The audible tail left in the outgoing track, in seconds, or `INFINITY`
    /// when the end is unknown and therefore unschedulable.
    fn audible_tail_s(&self, plan: &TransitionPlan, current: &Voice) -> f64 {
        let end_s = self.outgoing_end_s(plan, current);
        if !end_s.is_finite() {
            return f64::INFINITY;
        }
        let buffered_s =
            self.buffered_frames.load(Ordering::Relaxed) as f64 / self.device_rate as f64;
        (end_s - current.position_seconds()).max(0.0) + buffered_s
    }

    /// A later plan for the track already armed, applied only while the fade
    /// has not started.
    ///
    /// The safety overlap is queued as soon as the next file's first bytes
    /// exist, and the analysed plan can take longer than that. Dropping the
    /// analysed plan because the safety one already armed is how a blend that
    /// was ready still played out to the file's last byte.
    fn upgrade_armed_plan(&mut self, request: TrackSource) {
        let still_waiting = self
            .transition
            .as_ref()
            .is_some_and(|transition| transition.phase == Phase::Arming && !transition.swap);
        if !still_waiting {
            log::debug!("queueNext ignored; transition already fading");
            return;
        }
        let cue = request.start_seconds.max(0.0);
        let track = self
            .current
            .as_ref()
            .and_then(|voice| voice.known_duration)
            .unwrap_or(0.0);
        let fade_s = self.blend_seconds(request.plan.fade_seconds, track);
        let rate = if request.plan.playback_rate > 0.05 {
            request.plan.playback_rate
        } else {
            1.0
        };
        let glide = request.plan.post_glide_seconds.max(0.0);
        if let Some(transition) = &mut self.transition {
            if fade_s > 0.0 {
                transition.fade_frames = (fade_s * self.device_rate as f64) as u64;
            }
            transition.plan = request.plan;
        }
        if let Some(voice) = &mut self.incoming {
            voice.base_plan_rate = rate;
            voice.plan_rate = rate;
            voice.post_glide_seconds = glide;
            if (voice.decoder.position_seconds() - cue).abs() > 0.05 {
                voice.base_position = 0.0;
                voice.spatial.flush();
                voice.filter.flush();
                voice.pending_dev.clear();
                voice.pending_dev_cursor = 0;
                voice.silent_dev_frames = 0;
                voice.finished = false;
                if let Err(e) = voice.decoder.seek_seconds(cue) {
                    log::warn!("could not move the armed cue to {cue:.2}s: {e}");
                }
            }
        }
        log::info!(
            "updated armed transition: fade={fade_s:.1}s cue={cue:.2}s rate={rate:.4}"
        );
    }

    /// Opens a different file on a transition that has not started sounding.
    ///
    /// This is how a better encode of the next record joins the blend: the
    /// ramp the listener hears is the song change, not a second crossfade
    /// laid on top of it. Once the fade is audible the voice stays — swapping
    /// it then is the cut this exists to avoid.
    fn retarget_armed_source(&mut self, request: TrackSource) {
        match Voice::open(
            &request,
            self.spatial_enabled,
            self.head_yaw,
            self.device_rate,
            self.playback_speed,
            self.skip_silence,
            true,
        ) {
            Ok(mut voice) => {
                voice.gain = 0.0;
                let track = self
                    .current
                    .as_ref()
                    .and_then(|current| current.known_duration)
                    .unwrap_or(0.0);
                let fade_s = self.blend_seconds(request.plan.fade_seconds, track);
                let rate = if request.plan.playback_rate > 0.05 {
                    request.plan.playback_rate
                } else {
                    1.0
                };
                voice.base_plan_rate = rate;
                voice.plan_rate = rate;
                voice.post_glide_seconds = request.plan.post_glide_seconds.max(0.0);
                if let Some(transition) = &mut self.transition {
                    if fade_s > 0.0 {
                        transition.fade_frames = (fade_s * self.device_rate as f64) as u64;
                    }
                    transition.plan = request.plan;
                }
                log::info!(
                    "retargeted armed transition to {} fade={fade_s:.1}s",
                    voice.info.source
                );
                self.incoming = Some(voice);
            }
            Err(e) => {
                log::warn!("could not retarget the armed transition: {e}");
            }
        }
    }

    fn consider_arm(&mut self) {
        if self.transition.is_some() || self.pending_next.is_none() || !self.playing {
            return;
        }
        let Some(current) = &self.current else {
            return;
        };
        if current.finished {
            return;
        }
        // Unknown or implausibly short duration (muxed MP4 used to report
        // AAC packet counts as PCM frames): wait for real EOS instead of
        // blending immediately. Upstream uses ExoPlayer's container duration.
        if current.known_duration.unwrap_or(0.0) < 2.0
            && current.position_seconds() < 2.0
        {
            return;
        }
        // The plan decides both where the blend ends and how long it runs —
        // upstream arms from `plan.transitionStart` (CrossfadeController.kt:713)
        // and starts the fade from the same window (`:731` → `:967`). Arming
        // from the file end instead prepared the incoming only after the moment
        // the fade was already due, which pushed the whole blend late.
        let plan = self
            .pending_next
            .as_ref()
            .map(|request| request.plan.clone())
            .unwrap_or_default();
        let window_s = self.effective_fade_seconds(current.known_duration.unwrap_or(0.0));
        let fade_s = if plan.fade_seconds > 0.0 {
            self.blend_seconds(plan.fade_seconds, current.known_duration.unwrap_or(0.0))
        } else {
            window_s
        };
        let audible_tail_s = self.audible_tail_s(&plan, current);
        if !audible_tail_s.is_finite() {
            // There is no end to schedule against, so there is no blend: the
            // incoming is never armed and the queue advances by a cut at
            // end-of-stream. Worth saying out loud, because from the outside it
            // is indistinguishable from a crossfade setting of zero.
            if !self.warned_no_duration {
                self.warned_no_duration = true;
                log::warn!(
                    "no transition can be scheduled for {:?}: neither the container nor the \
                     caller knows how long it is, so there is no end to schedule against. The \
                     next track will be cut in at the end rather than mixed. Pass \
                     LoadRequest.durationSeconds, or have the planner set \
                     TransitionPlan.outgoing_duration_seconds.",
                    current.info.title,
                );
            }
            return;
        }
        let need_s = fade_s + ARM_LEAD_MS as f64 / 1000.0;
        if audible_tail_s > need_s {
            return;
        }

        let request = self.pending_next.take().unwrap();
        let fade_frames = (fade_s * self.device_rate as f64) as u64;
        match Voice::open(
            &request,
            self.spatial_enabled,
            self.head_yaw,
            self.device_rate,
            self.playback_speed,
            self.skip_silence,
            true,
        ) {
            Ok(mut voice) => {
                voice.gain = 0.0; // silent until the fade lifts it
                log::info!("armed next track: {}", request.title);
                self.incoming = Some(voice);
                self.transition = Some(TransitionState {
                    phase: Phase::Arming,
                    fade_frames,
                    handed_off: false,
                    plan,
                    arm_deadline: Instant::now() + Duration::from_millis(ARM_TIMEOUT_MS),
                    swap: false,
                });
            }
            Err(e) => {
                // Upstream gives up and lets the queue move on plainly: a
                // missed crossfade rather than a broken one.
                log::warn!("arm failed for {}: {e}", request.title);
                self.events.error(format!("could not prepare next track: {e}"));
                self.transition = None;
            }
        }
    }

    fn effective_fade_seconds(&self, total: f64) -> f64 {
        // A fade that swallows a third of a song stops being a transition —
        // upstream's `fadeFor` cap. Applied against the *current* track.
        let window = self.crossfade_window_s.max(0.0);
        if total > 0.0 {
            return window.min(total / 3.0);
        }
        window
    }

    /// A planned fade, kept off a half-second floor.
    ///
    /// Analysis of a partial file, or a grid snap onto the mix-out, can hand
    /// the mixer a fade of a few hundred milliseconds. On a track with room
    /// for four seconds, that figure is a cut and the floor replaces it. A
    /// plan that already asked for a real blend is left alone, including one
    /// that spends most of a short record — the planner chose that length.
    fn blend_seconds(&self, plan_fade: f64, track_seconds: f64) -> f64 {
        let planned = plan_fade.max(0.0);
        if planned == 0.0 || planned >= 4.0 {
            return planned;
        }
        if track_seconds > 0.0 && track_seconds < 12.0 {
            return planned;
        }
        4.0
    }

    /// Starts the fade the moment the audible tail has shrunk to it — or, for
    /// gapless (zero window), at the exact end.
    fn consider_start_fade(&mut self) {
        let Some(t) = &self.transition else {
            return;
        };
        if t.phase != Phase::Arming {
            return;
        }
        let Some(current) = &self.current else {
            return;
        };
        let Some(_incoming) = &self.incoming else {
            return;
        };
        if Instant::now() > t.arm_deadline {
            // Incoming never became ready; queue moves on plainly.
            log::warn!("arm timeout; dropping transition");
            self.incoming = None;
            self.transition = None;
            return;
        }
        let fade_s = t.fade_frames as f64 / self.device_rate as f64;
        // The blend starts when the *rendered* playhead crosses the plan, not
        // when the audible tail estimate does. The audible figure adds the ring
        // backlog, which moves with how full the device buffer is, so the same
        // plan started on a different beat every time. The next sample this
        // voice will emit is the one that has to land on the downbeat, and it
        // is checked once per chunk, so the error is at most 512 frames.
        let start_s = {
            let end_s = self.outgoing_end_s(&t.plan, current);
            if !end_s.is_finite() {
                return;
            }
            (end_s - fade_s).max(0.0)
        };
        if current.emitted_position_seconds() + 1e-4 < start_s {
            return;
        }
        self.start_fade();
    }

    fn start_fade(&mut self) {
        let Some(mut voice) = self.incoming.take() else {
            return;
        };
        // The blend is what the handoff stretch is for, so the stage goes live
        // here rather than at open. It holds this rate until the blend ends;
        // the glide home starts in `finish_transition`.
        if (voice.base_plan_rate - 1.0).abs() > 1e-4 {
            log::info!(
                "handoff stretch engaged: rate={:.4} ({:.0} cents, pitch preserved)",
                voice.base_plan_rate,
                1200.0 * (voice.base_plan_rate.ln() / 2f64.ln()).abs(),
            );
            voice.set_plan_rate(voice.base_plan_rate);
        }
        let info = voice.info.clone();
        log::info!("fade start + handoff: {}", info.title);
        self.duration_ms
            .store((info.duration_seconds * 1000.0) as u64, Ordering::Relaxed);
        self.incoming = Some(voice);
        if let Some(t) = &mut self.transition {
            t.phase = Phase::Fading;
            t.handed_off = true;
        }
        let db = self.incoming.as_ref().and_then(|v| v.loudness_db);
        self.publish_nerd(&info, db);
        // Playhead follows the incoming track from this moment — upstream
        // swaps the session player at handoff. Leaving it on the outgoing
        // voice published a time near that track's end under the new
        // duration, so the next song appeared to start in its outro.
        self.publish_audible_position();
        self.events.handoff(info);
    }

    /// Drives gains + filter ride for the fade in flight. Returns true when
    /// the transition finished this chunk.
    fn drive_fade(&mut self) -> bool {
        if !self
            .transition
            .as_ref()
            .is_some_and(|t| t.phase == Phase::Fading)
        {
            return false;
        }
        let Some(incoming) = &self.incoming else {
            return false;
        };
        let incoming_cap_frames = incoming
            .remaining_seconds()
            .map(|remaining| {
                let played = incoming.emitted_dev_frames as f64;
                let total_from_cue = played + remaining * self.device_rate as f64;
                ((total_from_cue / 3.0) as u64).max(1)
            })
            .unwrap_or(u64::MAX);
        let emitted = incoming.emitted_dev_frames;
        let fade_frames = self.transition.as_ref().map(|t| t.fade_frames).unwrap_or(0);
        let span = if fade_frames == 0 {
            0
        } else {
            let capped = fade_frames.min(incoming_cap_frames).max(1);
            // The third-of-the-record cap is for a genuinely short song. A cap
            // under a second, against a plan that asked for more, is a partial
            // container duration — and using it is how a blend collapses into
            // a half-second cut.
            if fade_frames > self.device_rate as u64 && capped < self.device_rate as u64 {
                fade_frames
            } else {
                capped
            }
        };
        let p = if span == 0 {
            1.0
        } else {
            (emitted as f64 / span as f64).clamp(0.0, 1.0)
        };
        let plan = self.transition.as_ref().map(|t| (t.plan.clone(), t.swap));
        let swap = plan.as_ref().is_some_and(|(_, swap)| *swap);
        let dj = plan.as_ref().is_some_and(|(plan, _)| {
            !swap && plan.bed_fraction > 0.0 && matches!(
                plan.style,
                TransitionStyle::DjBlend | TransitionStyle::DjFilter
            )
        });
        // A swap needs the linear pair. A plain crossfade needs equal-power.
        // A DJ blend holds the outgoing record up and brings the next one in
        // underneath. The tempo stretch is *held* here — walking it during the
        // fade is how two matched grids drift into a flam. It glides home
        // after the blend, on the promoted voice.
        let (rise, fall) = if dj {
            automix_gains(p, &plan.as_ref().unwrap().0)
        } else {
            fade_gains(p, swap)
        };
        if let (Some(current), Some(incoming), Some((plan, _))) =
            (&mut self.current, &mut self.incoming, plan)
        {
            current.gain = fall;
            incoming.gain = rise;
            if swap {
                // A source swap is the same recording against itself, so any
                // ride here would be an edit the record never asked for.
                current.filter.open();
                incoming.filter.open();
            } else {
                ride_filters(p, &plan, &mut current.filter, &mut incoming.filter);
            }
        }
        p >= 1.0 || self.current.as_ref().is_some_and(|c| c.finished)
    }

    fn finish_transition(&mut self) {
        let swap = self.transition.as_ref().is_some_and(|t| t.swap);
        if let Some(t) = &self.transition {
            if t.handed_off {
                if swap {
                    // The one measurement that can only come from a device:
                    // how alike two encodings of one master are. Recorded
                    // rather than asserted, because it is data about the
                    // catalogue, not a property of this code.
                    let correlation = self.swap_probe.correlation();
                    match correlation {
                        Some(rho) => log::info!(
                            "source swap correlation: rho={rho:.4} \
                             (linear-fade deviation from flat: {:.2} dB)",
                            10.0 * ((1.0 + rho) / 2.0).log10()
                        ),
                        None => log::info!(
                            "source swap correlation: unmeasurable (no signal overlapped)"
                        ),
                    }
                    if let Ok(mut nerd) = self.nerd.lock() {
                        nerd.swap_correlation = correlation;
                    }
                    // Condition in-place source swap on Pearson correlation rho >= 0.85
                    // so mismatched recordings/transcodes do not cut over.
                    if let Some(rho) = correlation {
                        if rho < 0.85 {
                            log::warn!(
                                "source swap rejected: rho={rho:.4} < 0.85 \
                                 (mismatched recording or transcode)"
                            );
                            self.incoming = None;
                            if let Some(current) = &mut self.current {
                                current.gain = 1.0;
                                current.filter.open();
                            }
                            self.transition = None;
                            return;
                        }
                    }
                }
                if let Some(mut incoming) = self.incoming.take() {
                    incoming.gain = 1.0;
                    incoming.filter.open();
                    // Hold the matched tempo through the blend, then walk it
                    // home. A swap has nothing to walk, and a plan with no
                    // glide releases here so the stretch cannot outlive the mix.
                    let glide = !swap
                        && incoming.post_glide_seconds > 0.05
                        && (incoming.base_plan_rate - 1.0).abs() > 1e-4;
                    if glide {
                        incoming.begin_tempo_glide(self.device_rate);
                    } else {
                        incoming.release_plan_stretch(self.playback_speed, self.device_rate);
                    }
                    let info = incoming.info.clone();
                    self.current = Some(incoming);
                    if swap {
                        // The readout should name the source that is actually
                        // playing, and that only becomes true here.
                        let db = self.current.as_ref().and_then(|v| v.loudness_db);
                        self.publish_nerd(&info, db);
                    }
                }
                // Old current dropped; its tail is spent by definition of the
                // fade end.
            } else {
                // Never audible; drop the incoming scratch voice.
                self.incoming = None;
                if let Some(current) = &mut self.current {
                    current.gain = 1.0;
                }
            }
        }
        self.transition = None;
    }

    /// 120 ms ramp-away for an interrupted transition — no click.
    fn bail(&mut self) {
        let Some(t) = &self.transition else {
            return;
        };
        if !t.handed_off {
            // Nothing was ever audible; no ramp to run.
            self.incoming = None;
            self.transition = None;
            if let Some(current) = &mut self.current {
                current.gain = 1.0;
                current.filter.open();
            }
            return;
        }
        // Open glided (never snapped): the incoming track is audible and its
        // low end may be mid-handover.
        if let Some(incoming) = &mut self.incoming {
            incoming.filter.open();
            incoming.gain = 1.0;
            // A seek abandoned the blend. The glide is for a mix that finished,
            // not for one that was interrupted.
            incoming.release_plan_stretch(self.playback_speed, self.device_rate);
        }
        if let Some(mut current) = self.current.take() {
            let from_gain = current.gain;
            current.filter.open();
            self.retiring.push(RetiringVoice {
                voice: current,
                from_gain,
                started_at: Instant::now(),
            });
        }
        self.transition = None;
    }

    fn stop_all(&mut self) {
        self.hard_cut();
        self.playing = false;
        self.set_state(crate::PlaybackState::Stopped);
    }

    /// Playhead the listener hears: decoder time minus samples still in the
    /// output ring (not yet consumed by the device callback). After handoff
    /// this is the incoming track — the session has already moved on.
    fn publish_audible_position(&mut self) {
        let handed_off = self.transition.as_ref().is_some_and(|t| t.handed_off);
        let swap = self.transition.as_ref().is_some_and(|t| t.swap);
        let Some(voice) = (if handed_off {
            self.incoming.as_ref().or(self.current.as_ref())
        } else {
            self.current.as_ref()
        }) else {
            return;
        };
        let buffered_s = self.buffered_frames.load(Ordering::Relaxed) as f64
            / self.device_rate.max(1) as f64;
        // Incoming has not filled the ring yet; subtracting the outgoing
        // backlog would clamp a just-cued track to 0 every time. Only the
        // current (session) voice's own backlog counts.
        //
        // A source swap is the exception: it is the same track at the same
        // instant, so the ring backlog still belongs to the timeline and comes
        // off exactly as it does mid-track. Publishing the replacement's
        // decoder head instead would throw the playhead forward by the whole
        // ring depth.
        let audible = if handed_off && !swap {
            voice.position_seconds().max(0.0)
        } else {
            (voice.position_seconds() - buffered_s).max(0.0)
        };
        self.position_ms
            .store((audible * 1000.0) as u64, Ordering::Relaxed);
    }
}

/// The mixer thread entry: owns voices + the ring producer.
#[allow(clippy::too_many_arguments)]
pub fn run_mixer(
    commands: Receiver<Command>,
    mut ring: Producer<f32>,
    buffered_frames: Arc<AtomicU64>,
    position_ms: Arc<AtomicU64>,
    duration_ms: Arc<AtomicU64>,
    device_rate: u32,
    events: Arc<dyn EngineEvents>,
    shutdown: Arc<AtomicBool>,
    flush_ring: Arc<AtomicBool>,
    bail_flush: Arc<AtomicBool>,
    nerd: Arc<Mutex<NerdSnapshot>>,
) {
    let mut state = MixerState {
        current: None,
        incoming: None,
        pending_next: None,
        warned_no_duration: false,
        transition: None,
        retiring: Vec::new(),
        playing: false,
        volume: 1.0,
        crossfade_window_s: 0.0,
        spatial_enabled: false,
        head_yaw: 0.0,
        device_rate,
        buffered_frames,
        position_ms,
        duration_ms,
        events,
        state: crate::PlaybackState::Stopped,
        flush_ring,
        bail_flush,
        playback_speed: 1.0,
        skip_silence: false,
        // The mixer blends to interleaved stereo, so the equaliser is a single
        // stereo instance on the mixed stream.
        eq: EqualizerProcessor::new(device_rate, 2),
        nerd,
        // Upstream's default: normalization on unless the listener says off.
        // The engine owner's first `set_loudness_enabled` reconciles this with
        // the stored setting either way.
        loudness_enabled: true,
        swap_probe: SwapProbe::default(),
    };

    loop {
        if shutdown.load(Ordering::Relaxed) {
            return;
        }

        // Drain commands.
        while let Ok(cmd) = commands.try_recv() {
            handle_command(&mut state, cmd, &mut ring);
        }

        if state.playing {
            render_available(&mut state, &mut ring);
            std::thread::sleep(Duration::from_millis(4));
        } else {
            // Idle: still service commands promptly, low CPU.
            std::thread::sleep(Duration::from_millis(20));
        }
    }
}

fn handle_command(state: &mut MixerState, cmd: Command, ring: &mut Producer<f32>) {
    match cmd {
        Command::Load { request, reply } => {
            // Upstream: a skip/replace is not a blend. `onSkipRequested` bails
            // and `setMediaItems` replaces the session playlist; the spare is
            // `stop()`+`clearMediaItems()`. Mixing the old voice under the new
            // one reads as the tap being ignored.
            state.hard_cut();
            match Voice::open(
                &request,
                state.spatial_enabled,
                state.head_yaw,
                state.device_rate,
                state.playback_speed,
                state.skip_silence,
                true,
            ) {
                Ok(voice) => {
                    let info = voice.info.clone();
                    let duration = voice.info.duration_seconds;
                    let (_, gain_db) = loudness_gain(voice.loudness_db, state.loudness_enabled);
                    if let Ok(mut nerd) = state.nerd.lock() {
                        *nerd = NerdSnapshot {
                            codec: info.codec.clone(),
                            sample_rate: info.sample_rate,
                            bit_depth: info.bit_depth,
                            channels: info.channels,
                            kbps: info.kbps,
                            loudness_gain_db: gain_db,
                            // A new track clears the previous swap's figure.
                            swap_correlation: None,
                        };
                    }
                    state.current = Some(voice);
                    state.playing = true;
                    state.position_ms.store(0, Ordering::Relaxed);
                    state
                        .duration_ms
                        .store((duration * 1000.0) as u64, Ordering::Relaxed);
                    state.set_state(crate::PlaybackState::Playing);
                    if duration > 0.0 {
                        state.events.duration_changed(duration);
                    }
                    let _ = reply.send(Ok(info));
                }
                Err(e) => {
                    state.set_state(crate::PlaybackState::Stopped);
                    let _ = reply.send(Err(e));
                }
            }
        }
        Command::SwapSource {
            request,
            crossfade_seconds,
            reply,
        } => {
            match state.swap_source(request, crossfade_seconds) {
                Ok(info) => {
                    let _ = reply.send(Ok(info));
                }
                Err(e) => {
                    let _ = reply.send(Err(e));
                }
            }
        }
        Command::QueueNext { request } => {
            if request.source.is_empty() {
                state.pending_next = None;
            } else if state.current.as_ref().is_some_and(|c| c.info.source == request.source) {
                // Same path as the playing voice is normally a duplicate and is
                // dropped. A planned fade is the repeat-one / single-item
                // repeat-all self-mix: open a second reader on the same file and
                // blend the track into itself.
                if request.plan.fade_seconds > 0.0 {
                    log::info!(
                        "queued self-mix for {} fade={:.1}s",
                        request.title,
                        request.plan.fade_seconds
                    );
                    state.pending_next = Some(request);
                } else {
                    log::debug!("queueNext ignored; already current");
                }
            } else if state.incoming.as_ref().is_some_and(|c| c.info.source == request.source) {
                // The early overlap can arm before analysis finishes. Replacing
                // it once the fade has started would replay this song after the
                // handoff; replacing the plan while it is still waiting moves
                // the blend to where the analysis said it should be.
                state.upgrade_armed_plan(request);
            } else if state
                .transition
                .as_ref()
                .is_some_and(|transition| transition.phase == Phase::Arming && !transition.swap)
            {
                // Not audible yet. A better encode of the incoming record, or a
                // queue change, replaces the armed voice. Doing this once the
                // fade is sounding would cut the blend.
                state.retarget_armed_source(request);
            } else if state.incoming.as_ref().is_some_and(|incoming| {
                incoming.info.title == request.title && incoming.info.artist == request.artist
            }) {
                log::info!("held a same-song source change; the blend is already audible");
            } else {
                state.pending_next = Some(request);
            }
        }
        Command::Play => {
            if state.current.is_some() {
                state.playing = true;
                state.set_state(crate::PlaybackState::Playing);
            }
        }
        Command::Pause => {
            // Silence the DAC immediately (output_paused) but keep the
            // already-mixed ring: those samples are the playhead. Flushing
            // them made pause snappy and resume skip ahead by ~2 s.
            state.publish_audible_position();
            state.playing = false;
            state.set_state(crate::PlaybackState::Paused);
        }
        Command::Stop => {
            state.stop_all();
        }
        Command::Seek { seconds } => {
            if state.transition.is_some() {
                state.bail();
            }
            match &mut state.current {
                Some(voice) => {
                    let r = voice.decoder.seek_seconds(seconds);
                    match r {
                        Ok(()) => {
                            voice.base_position = 0.0;
                            voice.spatial.flush();
                            voice.filter.flush();
                            voice.pending_dev.clear();
                            voice.pending_dev_cursor = 0;
                            voice.silent_dev_frames = 0;
                            voice.finished = false;
                            state.flush_ring.store(true, Ordering::Release);
                            state.buffered_frames.store(0, Ordering::Relaxed);
                            state.position_ms.store((seconds * 1000.0) as u64, Ordering::Relaxed);
                        }
                        Err(e) => {
                            state.events.error(format!("seek failed: {e}"));
                        }
                    }
                }
                None => {
                    state.events.error("seek ignored — nothing playing".into());
                }
            }
        }
        Command::SetVolume(v) => state.volume = v.clamp(0.0, 1.0),
        Command::SetCrossfadeWindow(s) => state.crossfade_window_s = s.max(0.0),
        Command::SetSpatial(enabled) => {
            state.spatial_enabled = enabled;
            if let Some(current) = &mut state.current {
                current.spatial.set_enabled(enabled);
            }
            if let Some(incoming) = &mut state.incoming {
                incoming.spatial.set_enabled(enabled);
            }
        }
        Command::SetHeadYaw(yaw) => {
            state.head_yaw = yaw;
            if let Some(current) = &mut state.current {
                current.spatial.set_head_yaw(yaw);
            }
            if let Some(incoming) = &mut state.incoming {
                incoming.spatial.set_head_yaw(yaw);
            }
        }
        Command::SetVoiceFilter { incoming, low_hz, high_hz } => {
            let target = if incoming {
                state.incoming.as_mut()
            } else {
                state.current.as_mut()
            };
            if let Some(voice) = target {
                voice.filter.set_cutoffs(low_hz, high_hz);
            }
        }
        Command::OpenFilters => {
            if let Some(current) = &mut state.current {
                current.filter.open();
            }
            if let Some(incoming) = &mut state.incoming {
                incoming.filter.open();
            }
        }
        Command::SetPlaybackSpeed(speed) => {
            state.playback_speed = speed.clamp(0.5, 2.0);
            if let Some(v) = &mut state.current {
                v.set_playback_speed(state.playback_speed, state.device_rate);
            }
            if let Some(v) = &mut state.incoming {
                v.set_playback_speed(state.playback_speed, state.device_rate);
            }
        }
        Command::SetSkipSilence(enabled) => {
            state.skip_silence = enabled;
            if let Some(v) = &mut state.current {
                v.skip_silence = enabled;
            }
            if let Some(v) = &mut state.incoming {
                v.skip_silence = enabled;
            }
        }
        Command::SetLoudnessEnabled(enabled) => {
            state.loudness_enabled = enabled;
            // The readout follows the switch without a reload: the gain each
            // voice *would* apply is recomputed for the one that is audible.
            if let Some(current) = &state.current {
                let info = current.info.clone();
                let db = current.loudness_db;
                state.publish_nerd(&info, db);
            }
        }
        Command::SetEqTuning { enabled, gains_db, qs, preamp_db, balance } => {
            state.eq.set_tuning(
                enabled,
                &EqCurve { gains_db, qs, preamp_db },
                balance,
            );
        }
        Command::SetOutputFormat { rate, producer } => {
            *ring = producer;
            let rate = rate.max(1);
            if rate != state.device_rate {
                log::info!("output format {} Hz -> {rate} Hz", state.device_rate);
                state.device_rate = rate;
                state.eq.retarget(rate, 2);
                let spatial = state.spatial_enabled;
                let yaw = state.head_yaw;
                if let Some(v) = &mut state.current {
                    v.retarget_device(rate, spatial, yaw);
                }
                if let Some(v) = &mut state.incoming {
                    v.retarget_device(rate, spatial, yaw);
                }
                for ret in &mut state.retiring {
                    ret.voice.retarget_device(rate, spatial, yaw);
                }
            }
            // The ring we just abandoned held everything between the playhead
            // and the decoder's read head, and it is gone — nothing drained it,
            // because the unit it fed is the one being replaced. Re-point the
            // voice at the playhead so the song continues where the listener
            // was, instead of silently skipping the whole ring depth, which is
            // seconds of music, the moment the output route changes.
            let resume_s = state.position_ms.load(Ordering::Relaxed) as f64 / 1000.0;
            if resume_s > 0.0 {
                if let Some(voice) = &mut state.current {
                    match voice.decoder.seek_seconds(resume_s) {
                        Ok(()) => {
                            voice.base_position = 0.0;
                            voice.spatial.flush();
                            voice.filter.flush();
                            voice.pending_dev.clear();
                            voice.pending_dev_cursor = 0;
                            voice.silent_dev_frames = 0;
                            voice.finished = false;
                            log::info!("output changed; resuming at {resume_s:.3}s");
                        }
                        Err(e) => log::warn!("re-seek after output change failed: {e}"),
                    }
                }
            }
            state.flush_ring.store(true, Ordering::Release);
            state.buffered_frames.store(0, Ordering::Relaxed);
        }
        Command::Shutdown => {
            state.stop_all();
        }
    }
}

/// Renders while the ring has room for a chunk.
fn render_available(state: &mut MixerState, ring: &mut Producer<f32>) {
    let chunk_samples = CHUNK_FRAMES * 2;
    loop {
        // Maintenance, evaluated per chunk rather than once per top-up.
        //
        // These decisions are about where the *audible* playhead is — arm the
        // incoming, start the fade — and this loop renders until the ring is
        // full, which is however much the device callback has drained since the
        // previous pass. While the callback keeps up, that is a handful of
        // chunks and checking once was equivalent. When it does not — a cold
        // ring, a slow decoder, a harness draining as fast as it can — a single
        // pass can render the whole fade window, or the whole track, before the
        // check runs again, and the blend lands wherever the ring ran out
        // instead of where the plan said.
        //
        // Upstream evaluates this on a 30 ms timer (`CrossfadeController.tick`),
        // which is the shape matched here: a cadence tied to the playhead, not
        // to buffer occupancy.
        state.consider_arm();
        state.consider_start_fade();
        let free = ring.slots();
        if free < chunk_samples {
            break;
        }
        let mut scratch = vec![0.0f32; chunk_samples];
        let mut audible = false;
        // Samples actually rendered this pass — zero padding beyond this is
        // NOT audio and must not enter the ring (it would pin `buffered` and
        // stall every tail computation after the current track ends).
        let mut produced = 0usize;

        // Fade drive.
        let transition_done = state.drive_fade();
        if transition_done {
            state.finish_transition();
        }

        // Gapless fallback: current ended with an incoming already armed, or
        // a pending next that never got a fade window (unknown duration).
        let current_finished = state.current.as_ref().is_some_and(|c| c.finished);
        if current_finished && state.transition.is_none() {
            if state.incoming.is_some() {
                state.promote_incoming();
            } else if state.pending_next.is_some() {
                state.promote_pending();
            }
        }

        // Retiring voices (bail/skip ramps) keep decoding while they fade.
        let mut keep_retiring = Vec::new();
        while let Some(mut ret) = state.retiring.pop() {
            let elapsed = ret.started_at.elapsed().as_millis() as f64 / BAIL_MS as f64;
            if elapsed < 1.0 {
                let frames = ret.voice.pull(CHUNK_FRAMES, state.device_rate);
                if !frames.is_empty() {
                    audible = true;
                    produced = produced.max(frames.len());
                    let gain = ret.from_gain
                        * fall_gain(elapsed)
                        * loudness_gain(ret.voice.loudness_db, state.loudness_enabled).0;
                    for (i, s) in frames.iter().enumerate() {
                        if i < scratch.len() {
                            scratch[i] += s * gain;
                        }
                    }
                }
                keep_retiring.push(ret);
            }
        }
        state.retiring = keep_retiring;

        // A swap fades a recording into another copy of itself, so the one
        // number that decides whether the curve is right is how correlated the
        // two copies are, and only a real upgrade can supply it. The samples
        // are already decoded and aligned here, so the probe is nearly free.
        let swap_fade = state.transition.as_ref().is_some_and(|t| t.swap);
        if let Some(voice) = &mut state.current {
            if state.playing {
                let rate = state.device_rate;
                let speed = state.playback_speed;
                voice.drive_tempo_glide(rate, speed);
                let frames = voice.pull(CHUNK_FRAMES, rate);
                voice.note_glide_frames((frames.len() / 2) as u64);
                if !frames.is_empty() {
                    audible = true;
                    produced = produced.max(frames.len());
                    if swap_fade {
                        state.swap_probe.observe_current(&frames);
                    }
                    let gain = applied_gain(voice, state.loudness_enabled);
                    for (i, s) in frames.iter().enumerate() {
                        if i < scratch.len() {
                            scratch[i] += s * gain;
                        }
                    }
                }
            }
        }
        if state.playing {
            state.publish_audible_position();
        }

        let incoming_renders = state
            .transition
            .as_ref()
            .is_some_and(|t| t.phase == Phase::Fading);
        if let Some(voice) = &mut state.incoming {
            if state.playing && incoming_renders {
                let frames = voice.pull(CHUNK_FRAMES, state.device_rate);
                if !frames.is_empty() {
                    audible = true;
                    produced = produced.max(frames.len());
                    if swap_fade {
                        state.swap_probe.observe_incoming(&frames);
                    }
                    let gain = applied_gain(voice, state.loudness_enabled);
                    for (i, s) in frames.iter().enumerate() {
                        if i < scratch.len() {
                            scratch[i] += s * gain;
                        }
                    }
                }
            }
        }

        if !audible {
            // No voice produced audio this chunk. The queue is truly spent
            // only when nothing is loaded, mid-transition, or winding down —
            // a finished current voice alone still has the armed incoming
            // promotion (above) or must end the queue.
            let any_pending = state.current.as_ref().is_some_and(|c| !c.finished)
                || state.incoming.is_some()
                || state.pending_next.is_some()
                || state.transition.is_some();
            let ring_drained = state.buffered_frames.load(Ordering::Relaxed) == 0;
            if !any_pending && ring_drained && state.retiring.is_empty() {
                if state.playing {
                    log::info!("queue drained; natural end");
                    state.playing = false;
                    state.set_state(crate::PlaybackState::Stopped);
                    state.events.track_ended(crate::TrackEndReason::Natural);
                }
                break;
            }
        }

        // Push interleaved, clamped — only what the voices actually rendered.
        let mut pushed = 0;
        if produced > 0 {
            state.eq.process(&mut scratch[..produced]);
            for s in scratch.into_iter().take(produced) {
                if ring.push(s.clamp(-1.0, 1.0)).is_ok() {
                    pushed += 1;
                } else {
                    break;
                }
            }
        }
        state
            .buffered_frames
            .fetch_add(pushed as u64 / 2, Ordering::Relaxed);
        if pushed < chunk_samples {
            break;
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::atomic::{AtomicBool, AtomicU64};
    use std::sync::{Arc, Mutex};

    #[derive(Default)]
    struct RecordedEvents {
        handoffs: Mutex<Vec<String>>,
        ended: Mutex<Vec<&'static str>>,
        states: Mutex<Vec<&'static str>>,
        errors: Mutex<Vec<String>>,
        position_ms: Option<Arc<AtomicU64>>,
        position_at_handoff: Mutex<Vec<u64>>,
    }

    impl EngineEvents for RecordedEvents {
        fn state_changed(&self, state: crate::PlaybackState) {
            self.states.lock().unwrap().push(match state {
                crate::PlaybackState::Stopped => "stopped",
                crate::PlaybackState::Buffering => "buffering",
                crate::PlaybackState::Playing => "playing",
                crate::PlaybackState::Paused => "paused",
            });
        }
        fn track_ended(&self, reason: crate::TrackEndReason) {
            self.ended.lock().unwrap().push(match reason {
                crate::TrackEndReason::Natural => "natural",
                crate::TrackEndReason::Skipped => "skipped",
                crate::TrackEndReason::Error => "error",
            });
        }
        fn error(&self, message: String) {
            self.errors.lock().unwrap().push(message);
        }
        fn handoff(&self, info: TrackInfo) {
            if let Some(position) = &self.position_ms {
                self.position_at_handoff
                    .lock()
                    .unwrap()
                    .push(position.load(Ordering::Relaxed));
            }
            self.handoffs.lock().unwrap().push(info.title);
        }
        fn duration_changed(&self, _seconds: f64) {}
    }

    fn test_wav(path: &std::path::Path, seconds: f32, freq: f32) {
        // Minimal 44.1 kHz stereo 16-bit PCM WAV.
        let rate = 44_100u32;
        let frames = (rate as f32 * seconds) as usize;
        let data_len = frames * 4;
        let mut bytes = Vec::new();
        bytes.extend_from_slice(b"RIFF");
        bytes.extend_from_slice(&(36 + data_len as u32).to_le_bytes());
        bytes.extend_from_slice(b"WAVE");
        bytes.extend_from_slice(b"fmt ");
        bytes.extend_from_slice(&16u32.to_le_bytes());
        bytes.extend_from_slice(&1u16.to_le_bytes()); // PCM
        bytes.extend_from_slice(&2u16.to_le_bytes());
        bytes.extend_from_slice(&rate.to_le_bytes());
        bytes.extend_from_slice(&(rate * 4).to_le_bytes());
        bytes.extend_from_slice(&4u16.to_le_bytes());
        bytes.extend_from_slice(&16u16.to_le_bytes());
        bytes.extend_from_slice(b"data");
        bytes.extend_from_slice(&(data_len as u32).to_le_bytes());
        for i in 0..frames {
            let t = i as f32 / rate as f32;
            let v = (0.3 * (2.0 * std::f32::consts::PI * freq * t).sin() * 32767.0) as i16;
            bytes.extend_from_slice(&v.to_le_bytes());
            bytes.extend_from_slice(&v.to_le_bytes());
        }
        std::fs::write(path, bytes).unwrap();
    }

    /// Clicks on one channel, silence on the other, so a mix can be split back
    /// into the two records.
    fn click_wav(path: &std::path::Path, seconds: f32, bpm: f64, left: bool) {
        let rate = 44_100u32;
        let frames = (rate as f32 * seconds) as usize;
        let interval = (rate as f64 * 60.0 / bpm).round() as usize;
        let burst = rate as usize * 8 / 1000;
        let data_len = frames * 4;
        let mut bytes = Vec::new();
        bytes.extend_from_slice(b"RIFF");
        bytes.extend_from_slice(&(36 + data_len as u32).to_le_bytes());
        bytes.extend_from_slice(b"WAVE");
        bytes.extend_from_slice(b"fmt ");
        bytes.extend_from_slice(&16u32.to_le_bytes());
        bytes.extend_from_slice(&1u16.to_le_bytes());
        bytes.extend_from_slice(&2u16.to_le_bytes());
        bytes.extend_from_slice(&rate.to_le_bytes());
        bytes.extend_from_slice(&(rate * 4).to_le_bytes());
        bytes.extend_from_slice(&4u16.to_le_bytes());
        bytes.extend_from_slice(&16u16.to_le_bytes());
        bytes.extend_from_slice(b"data");
        bytes.extend_from_slice(&(data_len as u32).to_le_bytes());
        for i in 0..frames {
            let within = i % interval;
            let sample = if within < burst {
                let t = within as f32 / rate as f32;
                let env = (-t * 500.0).exp();
                (env * (2.0 * std::f32::consts::PI * 4000.0 * t).sin() * 0.8 * 32767.0) as i16
            } else {
                0
            };
            let (l, r) = if left { (sample, 0) } else { (0, sample) };
            bytes.extend_from_slice(&l.to_le_bytes());
            bytes.extend_from_slice(&r.to_le_bytes());
        }
        std::fs::write(path, bytes).unwrap();
    }

    #[test]
    fn gapless_queue_advances_and_fires_handoff() {
        let dir = std::env::temp_dir().join("bitchord-mixer-test");
        std::fs::create_dir_all(&dir).unwrap();
        let a = dir.join("a.wav");
        let b = dir.join("b.wav");
        test_wav(&a, 1.0, 440.0);
        test_wav(&b, 1.0, 660.0);

        let events = std::sync::Arc::new(RecordedEvents::default());
        let (tx, rx) = crossbeam_channel::unbounded::<Command>();
        let (consumer_side, mut consumer) = rtrb::RingBuffer::<f32>::new(44_100 * 2 * 2);
        let buffered = std::sync::Arc::new(AtomicU64::new(0));
        let position = std::sync::Arc::new(AtomicU64::new(0));
        let duration = std::sync::Arc::new(AtomicU64::new(0));
        let shutdown = std::sync::Arc::new(AtomicBool::new(false));

        let handle = std::thread::spawn({
            let events = events.clone();
            let buffered = buffered.clone();
            let position = position.clone();
            let duration = duration.clone();
            let shutdown = shutdown.clone();
            move || {
                run_mixer(rx, consumer_side, buffered, position, duration, 44_100, events, shutdown, std::sync::Arc::new(AtomicBool::new(false)), std::sync::Arc::new(AtomicBool::new(false)), std::sync::Arc::new(Mutex::new(NerdSnapshot::default())))
            }
        });

        tx.send(Command::Load {
            request: TrackSource {
                source: a.display().to_string(),
                title: "A".into(),
                artist: String::new(),
                start_seconds: 0.0,
                plan: TransitionPlan::default(),
                headers: std::collections::HashMap::new(),
                claimed_kbps: 0,
            loudness_db: None,
            duration_seconds: 0.0,
            },
            reply: crossbeam_channel::bounded(1).0,
        })
        .unwrap();
        tx.send(Command::QueueNext {
            request: TrackSource {
                source: b.display().to_string(),
                title: "B".into(),
                artist: String::new(),
                start_seconds: 0.0,
                plan: TransitionPlan::default(),
                headers: std::collections::HashMap::new(),
                claimed_kbps: 0,
            loudness_db: None,
            duration_seconds: 0.0,
            },
        })
        .unwrap();

        // Drain the ring the way the device callback would, saturating the
        // shared counter (regression: a plain fetch_sub wrapped u64 and
        // wedged every tail computation — no handoff ever fired).
        let deadline = std::time::Instant::now() + std::time::Duration::from_secs(20);
        loop {
            while let Ok(_) = consumer.pop() {
                let mut current = buffered.load(Ordering::Relaxed);
                while current > 0 {
                    match buffered.compare_exchange_weak(
                        current,
                        current - 1,
                        Ordering::Relaxed,
                        Ordering::Relaxed,
                    ) {
                        Ok(_) => break,
                        Err(v) => current = v,
                    }
                }
            }
            let handoffs = events.handoffs.lock().unwrap();
            if !handoffs.is_empty() || std::time::Instant::now() > deadline {
                break;
            }
            drop(handoffs);
            std::thread::sleep(std::time::Duration::from_millis(5));
        }

        let handoffs = events.handoffs.lock().unwrap().clone();
        assert_eq!(handoffs, vec!["B".to_string()], "handoff to B must fire");

        shutdown.store(true, Ordering::Relaxed);
        let _ = handle.join();
    }

    /// Repeat-one / single-item repeat-all with Automix: the same file must be
    /// accepted as pending-next when it carries a fade, so the track can blend
    /// into itself instead of stopping at EOS.
    #[test]
    fn a_planned_self_mix_is_accepted_and_hands_off() {
        let dir = std::env::temp_dir().join("bitchord-mixer-self-mix");
        std::fs::create_dir_all(&dir).unwrap();
        let a = dir.join("loop.wav");
        test_wav(&a, 3.0, 440.0);

        let events = std::sync::Arc::new(RecordedEvents::default());
        let (tx, rx) = crossbeam_channel::unbounded::<Command>();
        let (consumer_side, mut consumer) = rtrb::RingBuffer::<f32>::new(44_100 * 2 * 4);
        let buffered = std::sync::Arc::new(AtomicU64::new(0));
        let position = std::sync::Arc::new(AtomicU64::new(0));
        let duration = std::sync::Arc::new(AtomicU64::new(0));
        let shutdown = std::sync::Arc::new(AtomicBool::new(false));

        let handle = std::thread::spawn({
            let events = events.clone();
            let buffered = buffered.clone();
            let position = position.clone();
            let duration = duration.clone();
            let shutdown = shutdown.clone();
            move || {
                run_mixer(
                    rx,
                    consumer_side,
                    buffered,
                    position,
                    duration,
                    44_100,
                    events,
                    shutdown,
                    std::sync::Arc::new(AtomicBool::new(false)),
                    std::sync::Arc::new(AtomicBool::new(false)),
                    std::sync::Arc::new(Mutex::new(NerdSnapshot::default())),
                )
            }
        });

        let path = a.display().to_string();
        tx.send(Command::Load {
            request: TrackSource {
                source: path.clone(),
                title: "Loop".into(),
                artist: String::new(),
                start_seconds: 0.0,
                plan: TransitionPlan::default(),
                headers: std::collections::HashMap::new(),
                claimed_kbps: 0,
                loudness_db: None,
                duration_seconds: 3.0,
            },
            reply: crossbeam_channel::bounded(1).0,
        })
        .unwrap();
        tx.send(Command::QueueNext {
            request: TrackSource {
                source: path,
                title: "Loop".into(),
                artist: String::new(),
                start_seconds: 0.0,
                plan: TransitionPlan {
                    fade_seconds: 1.0,
                    ..TransitionPlan::default()
                },
                headers: std::collections::HashMap::new(),
                claimed_kbps: 0,
                loudness_db: None,
                duration_seconds: 3.0,
            },
        })
        .unwrap();

        let deadline = std::time::Instant::now() + std::time::Duration::from_secs(20);
        loop {
            while let Ok(_) = consumer.pop() {
                let mut current = buffered.load(Ordering::Relaxed);
                while current > 0 {
                    match buffered.compare_exchange_weak(
                        current,
                        current - 1,
                        Ordering::Relaxed,
                        Ordering::Relaxed,
                    ) {
                        Ok(_) => break,
                        Err(v) => current = v,
                    }
                }
            }
            let handoffs = events.handoffs.lock().unwrap();
            if !handoffs.is_empty() || std::time::Instant::now() > deadline {
                break;
            }
            drop(handoffs);
            std::thread::sleep(std::time::Duration::from_millis(5));
        }

        let handoffs = events.handoffs.lock().unwrap().clone();
        let ended = events.ended.lock().unwrap().clone();
        assert_eq!(
            handoffs,
            vec!["Loop".to_string()],
            "self-mix must hand off into the same title, not drain: ended={ended:?}"
        );

        shutdown.store(true, Ordering::Relaxed);
        let _ = handle.join();
    }

    #[test]
    fn load_pushes_current_voice_into_the_ring() {
        let dir = std::env::temp_dir().join("bitchord-mixer-current");
        std::fs::create_dir_all(&dir).unwrap();
        let a = dir.join("solo.wav");
        test_wav(&a, 0.5, 440.0);

        let events = std::sync::Arc::new(RecordedEvents::default());
        let (tx, rx) = crossbeam_channel::unbounded::<Command>();
        let (consumer_side, mut consumer) = rtrb::RingBuffer::<f32>::new(44_100 * 2 * 2);
        let buffered = std::sync::Arc::new(AtomicU64::new(0));
        let position = std::sync::Arc::new(AtomicU64::new(0));
        let duration = std::sync::Arc::new(AtomicU64::new(0));
        let shutdown = std::sync::Arc::new(AtomicBool::new(false));

        let handle = std::thread::spawn({
            let events = events.clone();
            let buffered = buffered.clone();
            let position = position.clone();
            let duration = duration.clone();
            let shutdown = shutdown.clone();
            move || {
                run_mixer(
                    rx,
                    consumer_side,
                    buffered,
                    position,
                    duration,
                    44_100,
                    events,
                    shutdown,
                    std::sync::Arc::new(AtomicBool::new(false)),
                    std::sync::Arc::new(AtomicBool::new(false)),
                    std::sync::Arc::new(Mutex::new(NerdSnapshot::default())),
                )
            }
        });

        tx.send(Command::Load {
            request: TrackSource {
                source: a.display().to_string(),
                title: "solo".into(),
                artist: String::new(),
                start_seconds: 0.0,
                plan: TransitionPlan::default(),
                headers: std::collections::HashMap::new(),
                claimed_kbps: 0,
            loudness_db: None,
            duration_seconds: 0.0,
            },
            reply: crossbeam_channel::bounded(1).0,
        })
        .unwrap();

        let deadline = std::time::Instant::now() + std::time::Duration::from_secs(3);
        let mut samples = 0usize;
        while std::time::Instant::now() < deadline && samples == 0 {
            while consumer.pop().is_ok() {
                samples += 1;
            }
            std::thread::sleep(std::time::Duration::from_millis(5));
        }
        assert!(samples > 0, "current voice must reach the ring (got {samples})");

        shutdown.store(true, Ordering::Relaxed);
        let _ = handle.join();
    }

    #[test]
    fn cold_resume_seek_at_180_seconds_outputs_pcm_from_that_position() {
        // A seekable source must start directly at the requested timestamp:
        // restoring a saved playhead must not decode 180 seconds of audio, and
        // the first ring samples must contain the signal at that position.
        let a = std::env::temp_dir().join(format!(
            "bitchord-mixer-resume-{}.wav",
            std::process::id()
        ));
        test_wav(&a, 190.0, 997.0);

        let events = Arc::new(RecordedEvents::default());
        let (tx, rx) = crossbeam_channel::unbounded::<Command>();
        let (producer, mut consumer) = rtrb::RingBuffer::<f32>::new(44_100 * 2 * 2);
        let buffered = Arc::new(AtomicU64::new(0));
        let position = Arc::new(AtomicU64::new(0));
        let duration = Arc::new(AtomicU64::new(0));
        let shutdown = Arc::new(AtomicBool::new(false));
        let handle = std::thread::spawn({
            let (events, buffered, position, duration, shutdown) = (
                events.clone(),
                buffered.clone(),
                position.clone(),
                duration.clone(),
                shutdown.clone(),
            );
            move || {
                run_mixer(
                    rx,
                    producer,
                    buffered,
                    position,
                    duration,
                    44_100,
                    events,
                    shutdown,
                    Arc::new(AtomicBool::new(false)),
                    Arc::new(AtomicBool::new(false)),
                    Arc::new(Mutex::new(NerdSnapshot::default())),
                )
            }
        });

        let (reply, result) = crossbeam_channel::bounded(1);
        tx.send(Command::Load {
            request: TrackSource {
                source: a.display().to_string(),
                title: "resume".into(),
                artist: String::new(),
                start_seconds: 180.0,
                plan: TransitionPlan::default(),
                headers: std::collections::HashMap::new(),
                claimed_kbps: 0,
                loudness_db: None,
            duration_seconds: 0.0,
            },
            reply,
        })
        .unwrap();
        result.recv_timeout(std::time::Duration::from_secs(3)).unwrap().unwrap();

        let deadline = std::time::Instant::now() + std::time::Duration::from_secs(3);
        let mut first_samples = Vec::new();
        while std::time::Instant::now() < deadline && first_samples.len() < 256 {
            while first_samples.len() < 256 {
                match consumer.pop() {
                    Ok(sample) => first_samples.push(sample),
                    Err(_) => break,
                }
            }
            if first_samples.len() < 256 {
                std::thread::sleep(std::time::Duration::from_millis(2));
            }
        }
        assert_eq!(first_samples.len(), 256, "mixer did not fill the output ring");
        let peak = first_samples.iter().map(|sample| sample.abs()).fold(0.0, f32::max);
        assert!(peak > 0.1, "first ring PCM is silent (peak {peak})");
        let started_at = position.load(Ordering::Relaxed) as f64 / 1000.0;
        assert!(
            (179.9..181.0).contains(&started_at),
            "audible position should start at 180 s, got {started_at:.3} s"
        );

        shutdown.store(true, Ordering::Relaxed);
        let _ = handle.join();
        let _ = std::fs::remove_file(a);
    }

    #[test]
    fn silence_floor_uses_device_rate_not_source_rate() {
        // The bug: 44100 device frames at 96 kHz is 0.46 s, well under the
        // 1 s floor. Dividing by a 44.1 kHz source rate treated it as 1 s
        // and ate musical pauses.
        assert!(!super::silence_exceeds_floor(44_100, 96_000));
        assert!(!super::silence_exceeds_floor(48_000, 48_000));
        assert!(super::silence_exceeds_floor(48_001, 48_000));
        assert!(super::silence_exceeds_floor(96_001, 96_000));
    }

    #[test]
    fn silence_classifier_matches_media3_int16_threshold() {
        let just_under = 1023.0 / 32768.0;
        let just_over = 1025.0 / 32768.0;
        assert!(super::is_silent(&vec![just_under; 64]));
        assert!(!super::is_silent(&vec![just_over; 64]));
        let mut mixed = vec![0.0f32; 64];
        mixed[10] = just_over;
        assert!(!super::is_silent(&mixed));
        assert!(!super::is_silent(&[]));
    }

    #[test]
    fn cue_in_the_outro_starts_at_zero() {
        assert_eq!(super::clamp_start_seconds(0.0, 180.0), 0.0);
        assert_eq!(super::clamp_start_seconds(12.0, 180.0), 12.0);
        assert_eq!(super::clamp_start_seconds(176.0, 180.0), 0.0);
        assert_eq!(super::clamp_start_seconds(175.0, 180.0), 0.0);
        assert_eq!(super::clamp_start_seconds(174.9, 180.0), 174.9);
        assert_eq!(super::clamp_start_seconds(8.0, 0.0), 8.0);
    }

    /// A plan cannot talk the decoder into starting a record a minute in.
    ///
    /// Regression-shaped, and deliberately redundant with the planner's own
    /// bounds: the reason the deep cue reached the decoder at all is that every
    /// layer trusted the one above it, so the last layer before `seek_seconds`
    /// gets to disagree.
    #[test]
    fn a_planned_mix_in_cannot_reach_past_the_depth_bound() {
        let planned = TransitionPlan {
            cue_seconds: 45.0,
            ..TransitionPlan::default()
        };
        // The shape of the original bug: a plan asking to start a minute in.
        assert_eq!(super::bound_mix_in_depth(45.0, &planned, 210.0), 0.0);
        assert_eq!(super::bound_mix_in_depth(48.0, &planned, 210.0), 0.0);
        // A legal mix-in passes untouched, on either bound.
        let legal = TransitionPlan {
            cue_seconds: 6.0,
            ..TransitionPlan::default()
        };
        assert_eq!(super::bound_mix_in_depth(6.0, &legal, 210.0), 6.0);
        assert_eq!(super::bound_mix_in_depth(7.5, &legal, 210.0), 7.5);
        // The fraction is a floor for short material, not a ceiling for long:
        // eight seconds is a fifth of a one-minute clip and nothing at all in a
        // four-minute song.
        let eight = TransitionPlan {
            cue_seconds: 8.0,
            ..TransitionPlan::default()
        };
        assert_eq!(super::bound_mix_in_depth(8.0, &eight, 240.0), 8.0);
        assert_eq!(super::bound_mix_in_depth(8.0, &eight, 60.0), 0.0);
        assert_eq!(super::bound_mix_in_depth(3.5, &eight, 60.0), 3.5);
    }

    /// ...and a resume seek is none of its business.
    ///
    /// `start_seconds` carries two different intents: a mix-in point from the
    /// planner, and — from `loadCurrent(startAt:)` after a cold restore — a
    /// timestamp minutes into a track the listener was partway through. Only the
    /// first is a mix-in, and the tell is the plan: a resume carries none.
    #[test]
    fn a_resume_seek_is_not_treated_as_a_mix_in() {
        let no_plan = TransitionPlan::default();
        assert_eq!(no_plan.cue_seconds, 0.0);
        assert_eq!(super::bound_mix_in_depth(180.0, &no_plan, 240.0), 180.0);
        assert_eq!(super::bound_mix_in_depth(45.0, &no_plan, 210.0), 45.0);
        // And an unknown duration cannot be bounded, so it is passed through for
        // the outro rule to deal with.
        assert_eq!(super::bound_mix_in_depth(45.0, &planned_at(45.0), 0.0), 45.0);
    }

    fn planned_at(cue: f64) -> TransitionPlan {
        TransitionPlan {
            cue_seconds: cue,
            ..TransitionPlan::default()
        }
    }

    /// A queued transition must *overlap*: the incoming track has to be
    /// audible while the outgoing one still has music left, or there is no
    /// transition, there is a cut.
    ///
    /// This is the whole claim Automix makes, asserted directly rather than
    /// inferred from gains. The handoff is the engine saying "the incoming is
    /// audible now", so what matters at that moment is how much of the outgoing
    /// track is still to play — if the answer is nothing, the two never
    /// overlapped and the listener heard a song end and a song start.
    #[test]
    fn a_planned_transition_overlaps_rather_than_waits_for_the_end() {
        let dir = std::env::temp_dir().join("bitchord-mixer-overlap");
        std::fs::create_dir_all(&dir).unwrap();
        let a = dir.join("a.wav");
        let b = dir.join("b.wav");
        // Eight seconds each, so there is room to be early by a real margin.
        test_wav(&a, 8.0, 440.0);
        test_wav(&b, 8.0, 660.0);

        let events = std::sync::Arc::new(RecordedEvents::default());
        let (tx, rx) = crossbeam_channel::unbounded::<Command>();
        let (consumer_side, mut consumer) = rtrb::RingBuffer::<f32>::new(44_100 * 2 * 2);
        let buffered = std::sync::Arc::new(AtomicU64::new(0));
        let position = std::sync::Arc::new(AtomicU64::new(0));
        let duration = std::sync::Arc::new(AtomicU64::new(0));
        let shutdown = std::sync::Arc::new(AtomicBool::new(false));

        let handle = std::thread::spawn({
            let events = events.clone();
            let buffered = buffered.clone();
            let position = position.clone();
            let duration = duration.clone();
            let shutdown = shutdown.clone();
            move || {
                run_mixer(
                    rx,
                    consumer_side,
                    buffered,
                    position,
                    duration,
                    44_100,
                    events,
                    shutdown,
                    std::sync::Arc::new(AtomicBool::new(false)),
                    std::sync::Arc::new(AtomicBool::new(false)),
                    std::sync::Arc::new(Mutex::new(NerdSnapshot::default())),
                )
            }
        });

        // Two seconds of blend ending at 6 s into an 8 s track: the handoff must
        // land while two more seconds of the outgoing are still coming.
        let fade = 2.0f64;
        tx.send(Command::Load {
            request: TrackSource {
                source: a.display().to_string(),
                title: "A".into(),
                artist: String::new(),
                start_seconds: 0.0,
                plan: TransitionPlan::default(),
                headers: std::collections::HashMap::new(),
                claimed_kbps: 0,
                loudness_db: None,
                duration_seconds: 0.0,
            },
            reply: crossbeam_channel::bounded(1).0,
        })
        .unwrap();
        tx.send(Command::QueueNext {
            request: TrackSource {
                source: b.display().to_string(),
                title: "B".into(),
                artist: String::new(),
                start_seconds: 0.0,
                plan: TransitionPlan {
                    style: TransitionStyle::DjBlend,
                    bass_swap: false,
                    fade_seconds: fade,
                    transition_end_seconds: 6.0,
                    ..TransitionPlan::default()
                },
                headers: std::collections::HashMap::new(),
                claimed_kbps: 0,
                loudness_db: None,
                duration_seconds: 0.0,
            },
        })
        .unwrap();

        let at = drain_until_handoff(
            &mut consumer,
            &buffered,
            &position,
            &events,
            20,
        )
        .expect("no handoff fired");
        assert!(
            at <= 6.0 + 0.6,
            "the handoff fired at {at:.2}s, past the 6 s blend anchor"
        );
        assert!(
            at <= 8.0 - 0.5,
            "the handoff fired at {at:.2}s of an 8 s track — that is a cut at the end, not a mix"
        );

        shutdown.store(true, std::sync::atomic::Ordering::Relaxed);
        tx.send(Command::Shutdown).ok();
        let _ = handle.join();
    }

    /// 116 BPM clicks, sped up to 120, stay on the outgoing 120 BPM grid through
    /// the overlap, then settle back to 116 once the post-blend glide ends.
    #[test]
    fn a_beatmatched_blend_holds_the_grid_then_glides_home() {
        let dir = std::env::temp_dir().join("bitchord-mixer-beats");
        std::fs::create_dir_all(&dir).unwrap();
        let a = dir.join("out.wav");
        let b = dir.join("in.wav");
        click_wav(&a, 10.0, 120.0, true);
        click_wav(&b, 36.0, 116.0, false);

        let events = std::sync::Arc::new(RecordedEvents::default());
        let (tx, rx) = crossbeam_channel::unbounded::<Command>();
        let (consumer_side, mut consumer) = rtrb::RingBuffer::<f32>::new(44_100 * 2);
        let buffered = std::sync::Arc::new(AtomicU64::new(0));
        let position = std::sync::Arc::new(AtomicU64::new(0));
        let duration = std::sync::Arc::new(AtomicU64::new(0));
        let shutdown = std::sync::Arc::new(AtomicBool::new(false));
        let handle = std::thread::spawn({
            let events = events.clone();
            let buffered = buffered.clone();
            let position = position.clone();
            let duration = duration.clone();
            let shutdown = shutdown.clone();
            move || {
                run_mixer(
                    rx,
                    consumer_side,
                    buffered,
                    position,
                    duration,
                    44_100,
                    events,
                    shutdown,
                    std::sync::Arc::new(AtomicBool::new(false)),
                    std::sync::Arc::new(AtomicBool::new(false)),
                    std::sync::Arc::new(Mutex::new(NerdSnapshot::default())),
                )
            }
        });

        let rate = 44_100usize;
        // Eight seconds of blend ending one second before the outgoing file,
        // so the bed (before the bass swap) is long enough to compare grids.
        let fade = 8.0;
        let end = 9.0;
        tx.send(Command::Load {
            request: TrackSource {
                source: a.display().to_string(),
                title: "A".into(),
                artist: String::new(),
                start_seconds: 0.0,
                plan: TransitionPlan::default(),
                headers: std::collections::HashMap::new(),
                claimed_kbps: 0,
                loudness_db: None,
                duration_seconds: 10.0,
            },
            reply: crossbeam_channel::bounded(1).0,
        })
        .unwrap();
        tx.send(Command::QueueNext {
            request: TrackSource {
                source: b.display().to_string(),
                title: "B".into(),
                artist: String::new(),
                start_seconds: 0.0,
                plan: TransitionPlan {
                    style: TransitionStyle::DjBlend,
                    bass_swap: true,
                    bass_swap_fraction: 0.6,
                    fade_seconds: fade,
                    transition_end_seconds: end,
                    playback_rate: 120.0 / 116.0,
                    bed_fraction: 0.45,
                    bed_gain_db: -14.0,
                    dip_depth: 0.0,
                    dip_width: 0.05,
                    // 32 beats of the matched 120 BPM grid.
                    post_glide_seconds: 32.0 * 0.5,
                    ..TransitionPlan::default()
                },
                headers: std::collections::HashMap::new(),
                claimed_kbps: 0,
                loudness_db: None,
                duration_seconds: 36.0,
            },
        })
        .unwrap();

        let want = rate * 28;
        let mut samples = Vec::with_capacity(want * 2);
        let deadline = std::time::Instant::now() + std::time::Duration::from_secs(120);
        while samples.len() / 2 < want && std::time::Instant::now() < deadline {
            match consumer.pop() {
                Ok(sample) => {
                    samples.push(sample);
                    if samples.len() % 2 == 0 {
                        let mut current = buffered.load(Ordering::Relaxed);
                        while current > 0 {
                            match buffered.compare_exchange_weak(
                                current,
                                current - 1,
                                Ordering::Relaxed,
                                Ordering::Relaxed,
                            ) {
                                Ok(_) => break,
                                Err(v) => current = v,
                            }
                        }
                    }
                }
                Err(_) => std::thread::sleep(std::time::Duration::from_millis(2)),
            }
        }
        shutdown.store(true, Ordering::Relaxed);
        tx.send(Command::Shutdown).ok();
        let _ = handle.join();
        assert!(
            samples.len() / 2 > rate * 27,
            "only captured {:.1}s",
            samples.len() as f64 / 2.0 / rate as f64
        );

        let onsets = |channel: usize, from_s: f64, until_s: f64| -> Vec<usize> {
            let frames = samples.len() / 2;
            let start = ((from_s * rate as f64) as usize).min(frames);
            let end = ((until_s * rate as f64) as usize).min(frames);
            let mut peaks = Vec::new();
            let mut i = start.max(1);
            while i + 1 < end {
                let level = samples[i * 2 + channel].abs();
                if level > 0.05
                    && level >= samples[(i - 1) * 2 + channel].abs()
                    && level >= samples[(i + 1) * 2 + channel].abs()
                {
                    peaks.push(i);
                    i += rate / 10;
                } else {
                    i += 1;
                }
            }
            peaks
        };

        // Fade runs 1s..9s; the bass swap is at 0.6 of that, so 1.4s..5.4s is
        // still the bed — both records full-band, the incoming underneath.
        let left = onsets(0, 1.4, 5.4);
        let right = onsets(1, 1.4, 5.4);
        assert!(left.len() >= 4, "outgoing clicks in the overlap: {}", left.len());
        assert!(right.len() >= 4, "incoming clicks in the overlap: {}", right.len());
        let mut worst = 0.0f64;
        for beat in &left {
            let nearest = right
                .iter()
                .map(|other| (*other as isize - *beat as isize).unsigned_abs())
                .min()
                .unwrap_or(usize::MAX);
            let ms = nearest as f64 / rate as f64 * 1000.0;
            worst = worst.max(ms);
        }
        assert!(
            worst < 15.0,
            "beats drifted by {worst:.1} ms during the blend"
        );

        // The glide is 16 s from the end of the blend (t = 9), so past t = 25
        // the incoming record is back at its own 116 BPM.
        let home = onsets(1, 25.4, 27.6);
        assert!(home.len() >= 3, "not enough clicks after the glide: {}", home.len());
        let expected = rate as f64 * 60.0 / 116.0;
        for pair in home.windows(2) {
            let gap = (pair[1] - pair[0]) as f64;
            let error = (gap - expected).abs() / expected;
            assert!(
                error < 0.02,
                "after the glide the spacing was {gap:.0} samples, {error:.3} off 116 BPM"
            );
        }
    }

    /// The engine's length for a track, and which of the two sources wins.
    ///
    /// The container's own figure is measured from the bytes being decoded and
    /// is the better answer; the caller's is the only answer when the container
    /// declares none, which is the case that decides whether a transition gets
    /// scheduled at all.
    #[test]
    fn a_container_without_a_duration_falls_back_to_the_callers_figure() {
        assert_eq!(super::known_duration(Some(210.0), 209.0), 210.0, "the container wins");
        assert_eq!(super::known_duration(Some(0.0), 210.0), 210.0, "a zero is not a duration");
        assert_eq!(super::known_duration(None, 210.0), 210.0, "the caller fills the gap");
        assert_eq!(super::known_duration(None, 0.0), 0.0, "and unknown stays unknown");
        assert_eq!(super::known_duration(None, f64::NAN), 0.0);
        assert_eq!(super::known_duration(Some(f64::NAN), 210.0), 210.0);
    }


    /// The mix-out anchor is a preferred musical point near the end, distinct
    /// from the recording's duration. That anchor schedules the fade; this
    /// duration still limits the fade and protects the recording's tail.
    #[test]
    fn the_recording_duration_takes_precedence_over_its_mix_out_anchor() {
        let dir = std::env::temp_dir().join("bitchord-mixer-anchor-duration");
        std::fs::create_dir_all(&dir).unwrap();
        let path = dir.join("duration.wav");
        test_wav(&path, 10.0, 440.0);
        let request = TrackSource {
            source: path.display().to_string(),
            title: "A".into(),
            artist: String::new(),
            start_seconds: 0.0,
            plan: TransitionPlan {
                transition_end_seconds: 8.0,
                outgoing_duration_seconds: 10.0,
                fade_seconds: 1.0,
                ..TransitionPlan::default()
            },
            headers: std::collections::HashMap::new(),
            claimed_kbps: 0,
            loudness_db: None,
            duration_seconds: 10.0,
        };
        let voice = Voice::open(&request, false, 0.0, 44_100, 1.0, false, false).unwrap();
        let state = MixerState {
            current: Some(voice),
            incoming: None,
            pending_next: None,
            warned_no_duration: false,
            transition: None,
            retiring: Vec::new(),
            playing: true,
            volume: 1.0,
            crossfade_window_s: 4.0,
            spatial_enabled: false,
            head_yaw: 0.0,
            device_rate: 44_100,
            buffered_frames: Arc::new(AtomicU64::new(0)),
            position_ms: Arc::new(AtomicU64::new(0)),
            duration_ms: Arc::new(AtomicU64::new(0)),
            events: Arc::new(RecordedEvents::default()),
            state: crate::PlaybackState::Playing,
            flush_ring: Arc::new(AtomicBool::new(false)),
            bail_flush: Arc::new(AtomicBool::new(false)),
            playback_speed: 1.0,
            skip_silence: false,
            eq: EqualizerProcessor::new(44_100, 2),
            nerd: Arc::new(Mutex::new(NerdSnapshot::default())),
            loudness_enabled: false,
            swap_probe: SwapProbe::default(),
        };
        let current = state.current.as_ref().unwrap();
        assert_eq!(state.outgoing_end_s(&request.plan, current), 8.0);
        assert_eq!(state.effective_fade_seconds(current.known_duration.unwrap()), 10.0 / 3.0);
    }

    /// Drain the ring the way the device callback would (decrementing the
    /// shared counter) for a fixed number of frames.
    fn drain_frames(consumer: &mut rtrb::Consumer<f32>, buffered: &AtomicU64, frames: usize) {
        let mut popped = 0usize;
        let target = frames * 2;
        let deadline = std::time::Instant::now() + std::time::Duration::from_secs(30);
        while popped < target && std::time::Instant::now() < deadline {
            match consumer.pop() {
                Ok(_) => {
                    popped += 1;
                    // `render_f32` counts frames, not samples; decrementing per
                    // sample would drain the shared counter twice as fast and
                    // make the audible playhead look like the decoder head.
                    if popped % 2 == 0 {
                        let mut current = buffered.load(Ordering::Relaxed);
                        while current > 0 {
                            match buffered.compare_exchange_weak(
                                current,
                                current - 1,
                                Ordering::Relaxed,
                                Ordering::Relaxed,
                            ) {
                                Ok(_) => break,
                                Err(v) => current = v,
                            }
                        }
                    }
                }
                Err(_) => std::thread::sleep(std::time::Duration::from_millis(1)),
            }
        }
    }

    /// Drains until the handoff fires, returning the playhead at that moment.
    ///
    /// The playhead is the number a caller needs: the handoff is the engine
    /// saying "the incoming track is audible now", so how far into the outgoing
    /// track that happens is exactly whether there was a transition or a cut.
    fn drain_until_handoff(
        consumer: &mut rtrb::Consumer<f32>,
        buffered: &AtomicU64,
        position: &AtomicU64,
        events: &RecordedEvents,
        seconds: u64,
    ) -> Option<f64> {
        let deadline = std::time::Instant::now() + std::time::Duration::from_secs(seconds);
        loop {
            while consumer.pop().is_ok() {
                let mut current = buffered.load(Ordering::Relaxed);
                while current > 0 {
                    match buffered.compare_exchange_weak(
                        current,
                        current - 1,
                        Ordering::Relaxed,
                        Ordering::Relaxed,
                    ) {
                        Ok(_) => break,
                        Err(v) => current = v,
                    }
                }
            }
            if !events.handoffs.lock().unwrap().is_empty() {
                // The mixer publishes the incoming track's playhead at handoff,
                // which is its own cue rather than the outgoing tail — so this is
                // the *outgoing* position only if the handoff had not been
                // published yet. Sampled before the check on the next pass, this
                // is close enough for a margin measured in seconds.
                return Some(position.load(Ordering::Relaxed) as f64 / 1000.0);
            }
            if std::time::Instant::now() > deadline {
                return None;
            }
            std::thread::sleep(std::time::Duration::from_millis(5));
        }
    }

    #[test]
    fn crossfade_handoff_playhead_is_incoming_not_outgoing_tail() {
        let dir = std::env::temp_dir().join("bitchord-mixer-xfade-pos");
        std::fs::create_dir_all(&dir).unwrap();
        let a = dir.join("out.wav");
        let b = dir.join("in.wav");
        test_wav(&a, 3.0, 440.0);
        test_wav(&b, 3.0, 660.0);

        let position = std::sync::Arc::new(AtomicU64::new(0));
        let events = std::sync::Arc::new(RecordedEvents {
            position_ms: Some(position.clone()),
            ..RecordedEvents::default()
        });
        let (tx, rx) = crossbeam_channel::unbounded::<Command>();
        let (consumer_side, mut consumer) = rtrb::RingBuffer::<f32>::new(44_100 * 2 * 4);
        let buffered = std::sync::Arc::new(AtomicU64::new(0));
        let duration = std::sync::Arc::new(AtomicU64::new(0));
        let shutdown = std::sync::Arc::new(AtomicBool::new(false));

        let handle = std::thread::spawn({
            let events = events.clone();
            let buffered = buffered.clone();
            let position = position.clone();
            let duration = duration.clone();
            let shutdown = shutdown.clone();
            move || {
                run_mixer(
                    rx,
                    consumer_side,
                    buffered,
                    position,
                    duration,
                    44_100,
                    events,
                    shutdown,
                    std::sync::Arc::new(AtomicBool::new(false)),
                    std::sync::Arc::new(AtomicBool::new(false)),
                    std::sync::Arc::new(Mutex::new(NerdSnapshot::default())),
                )
            }
        });

        tx.send(Command::SetCrossfadeWindow(1.0)).unwrap();
        tx.send(Command::Load {
            request: TrackSource {
                source: a.display().to_string(),
                title: "A".into(),
                artist: String::new(),
                start_seconds: 0.0,
                plan: TransitionPlan::default(),
                headers: std::collections::HashMap::new(),
                claimed_kbps: 0,
            loudness_db: None,
            duration_seconds: 0.0,
            },
            reply: crossbeam_channel::bounded(1).0,
        })
        .unwrap();
        tx.send(Command::QueueNext {
            request: TrackSource {
                source: b.display().to_string(),
                title: "B".into(),
                artist: String::new(),
                start_seconds: 0.0,
                plan: TransitionPlan::default(),
                headers: std::collections::HashMap::new(),
                claimed_kbps: 0,
            loudness_db: None,
            duration_seconds: 0.0,
            },
        })
        .unwrap();

        drain_until_handoff(&mut consumer, &buffered, &position, &events, 20);

        let handoffs = events.handoffs.lock().unwrap().clone();
        assert_eq!(handoffs, vec!["B".to_string()], "handoff to B must fire");
        let at = events.position_at_handoff.lock().unwrap().clone();
        assert_eq!(at.len(), 1);
        // Outgoing is 3 s; fade starts with ~1 s left, so the old playhead
        // would be ~2000 ms. Incoming must be at (or very near) its cue.
        assert!(
            at[0] < 1_500,
            "handoff playhead {} ms is the outgoing tail, not the incoming start",
            at[0]
        );

        shutdown.store(true, Ordering::Relaxed);
        let _ = handle.join();
    }

    /// The blend has to end where the *plan* says, not at the file's last byte.
    ///
    /// Regression: the mixer armed the fade from `duration`, so a plan whose
    /// anchor sits inside the track — which is the whole point of the ranked
    /// mix-out anchor, and is allowed to be 12 s early — had its entire blend
    /// pushed to the end, taking the bass swap and both filter rides with it.
    ///
    /// The ring is deliberately small here so the decoder cannot run far ahead
    /// of what has been drained, which is what makes the count below a direct
    /// reading of "how far into the outgoing track the blend started".
    #[test]
    fn the_blend_ends_at_the_plans_anchor_not_the_file_end() {
        let dir = std::env::temp_dir().join("bitchord-mixer-anchor");
        std::fs::create_dir_all(&dir).unwrap();
        let a = dir.join("out.wav");
        let b = dir.join("in.wav");
        test_wav(&a, 10.0, 440.0);
        test_wav(&b, 10.0, 660.0);

        let events = std::sync::Arc::new(RecordedEvents::default());
        let (tx, rx) = crossbeam_channel::unbounded::<Command>();
        // ~250 ms: small enough that pre-buffering cannot mask the anchor.
        let (consumer_side, mut consumer) = rtrb::RingBuffer::<f32>::new(44_100 / 4 * 2);
        let buffered = std::sync::Arc::new(AtomicU64::new(0));
        let position = std::sync::Arc::new(AtomicU64::new(0));
        let duration = std::sync::Arc::new(AtomicU64::new(0));
        let shutdown = std::sync::Arc::new(AtomicBool::new(false));
        let handle = std::thread::spawn({
            let events = events.clone();
            let buffered = buffered.clone();
            let position = position.clone();
            let duration = duration.clone();
            let shutdown = shutdown.clone();
            move || {
                run_mixer(
                    rx,
                    consumer_side,
                    buffered,
                    position,
                    duration,
                    44_100,
                    events,
                    shutdown,
                    std::sync::Arc::new(AtomicBool::new(false)),
                    std::sync::Arc::new(AtomicBool::new(false)),
                    std::sync::Arc::new(Mutex::new(NerdSnapshot::default())),
                )
            }
        });

        let source = |path: &std::path::Path, title: &str, plan: TransitionPlan| TrackSource {
            source: path.display().to_string(),
            title: title.into(),
            artist: String::new(),
            start_seconds: 0.0,
            plan,
            headers: std::collections::HashMap::new(),
            claimed_kbps: 0,
            loudness_db: None,
            duration_seconds: 0.0,
        };

        tx.send(Command::SetCrossfadeWindow(1.0)).unwrap();
        tx.send(Command::Load {
            request: source(&a, "A", TransitionPlan::default()),
            reply: crossbeam_channel::bounded(1).0,
        })
        .unwrap();
        // A 10 s outgoing track, but the blend is wanted 3 s in with a 1 s fade,
        // so it must start at roughly 2 s of outgoing audio — not at 9 s.
        tx.send(Command::QueueNext {
            request: source(
                &b,
                "B",
                TransitionPlan {
                    fade_seconds: 1.0,
                    transition_end_seconds: 3.0,
                    ..TransitionPlan::default()
                },
            ),
        })
        .unwrap();

        let mut drained = 0usize;
        let deadline = std::time::Instant::now() + std::time::Duration::from_secs(20);
        while std::time::Instant::now() < deadline {
            while consumer.pop().is_ok() {
                drained += 1;
                let mut current = buffered.load(Ordering::Relaxed);
                while current > 0 {
                    match buffered.compare_exchange_weak(
                        current,
                        current - 1,
                        Ordering::Relaxed,
                        Ordering::Relaxed,
                    ) {
                        Ok(_) => break,
                        Err(v) => current = v,
                    }
                }
            }
            if !events.handoffs.lock().unwrap().is_empty() {
                break;
            }
            std::thread::sleep(std::time::Duration::from_millis(2));
        }

        assert!(
            !events.handoffs.lock().unwrap().is_empty(),
            "the blend must happen at all"
        );
        let started_at = drained as f64 / 2.0 / 44_100.0;
        assert!(
            started_at < 5.0,
            "the blend started {started_at:.2}s in, which is the file end — the plan's anchor was ignored"
        );
        assert!(
            started_at > 0.5,
            "the blend started {started_at:.2}s in, implausibly early"
        );

        shutdown.store(true, Ordering::Relaxed);
        let _ = handle.join();
    }

    /// The two crossfade curves, and why they have to differ.
    ///
    /// Regression: a source swap used the equal-power pair, so the same
    /// recording on both sides — correlated, and aligned by construction —
    /// summed to √2 through the middle of the fade, and every quality upgrade
    /// was heard as the volume lifting and settling back.
    #[test]
    fn swap_fade_is_level_flat_while_a_track_fade_is_power_flat() {
        let mut worst_swap_db = 0.0f64;
        let mut worst_track_db = 0.0f64;
        for step in 0..=1000 {
            let p = step as f64 / 1000.0;

            // Correlated sides: amplitudes add, so the sum must stay at 1.
            let (rise, fall) = fade_gains(p, true);
            let sum = rise as f64 + fall as f64;
            worst_swap_db = worst_swap_db.max(20.0 * sum.log10().abs());

            // Uncorrelated sides: powers add, so the power sum must stay at 1.
            let (rise, fall) = fade_gains(p, false);
            let power = (rise as f64).powi(2) + (fall as f64).powi(2);
            worst_track_db = worst_track_db.max(10.0 * power.log10().abs());
        }
        assert!(worst_swap_db < 1e-4, "swap fade swells by {worst_swap_db} dB");
        assert!(worst_track_db < 1e-4, "track fade dips by {worst_track_db} dB");

        // What a plain equal-power pair costs when both sides are the same
        // signal — recorded so the branch above cannot quietly be undone, and
        // so the reason the incoming no longer uses one is written down where
        // the arithmetic is.
        let quarter = core::f64::consts::FRAC_PI_4;
        let bump_db = 20.0 * (quarter.sin() + quarter.cos()).log10();
        assert!(
            (bump_db - 3.01).abs() < 0.02,
            "expected the √2 bump at the midpoint, got {bump_db} dB"
        );
    }

    /// A plain crossfade is equal-power: silent at the open, unity at the
    /// close, and level-flat the whole way. A DJ blend is a different curve.
    #[test]
    fn a_plain_crossfade_is_equal_power_and_starts_from_silence() {
        let (first_rise, first_fall) = fade_gains(0.0, false);
        let (last_rise, last_fall) = fade_gains(1.0, false);
        assert!(first_rise.abs() < 1e-6, "a crossfade opens on silence, got {first_rise}");
        assert!((first_fall - 1.0).abs() < 1e-6);
        assert!((last_rise - 1.0).abs() < 1e-6);
        assert!(last_fall.abs() < 1e-6);
        let mut worst_db = 0.0f64;
        for step in 0..=1000 {
            let (rise, fall) = fade_gains(step as f64 / 1000.0, false);
            let power = (rise as f64).powi(2) + (fall as f64).powi(2);
            worst_db = worst_db.max(10.0 * power.log10().abs());
        }
        assert!(worst_db < 1e-4, "equal-power moved the level by {worst_db} dB");
    }

    /// Bed, then a rise, then the outgoing lets go. The incoming is already
    /// audible while the outgoing is still at full level, and a one-beat dip
    /// sits just before the swap.
    #[test]
    fn a_dj_blend_beds_the_incoming_track_then_swaps() {
        let plan = TransitionPlan {
            style: TransitionStyle::DjBlend,
            bass_swap: true,
            bass_swap_fraction: 0.62,
            bed_fraction: 0.4,
            bed_gain_db: -14.0,
            dip_depth: 0.5,
            dip_width: 0.08,
            fade_seconds: 12.0,
            ..TransitionPlan::default()
        };
        let bed = 10.0_f64.powf(-14.0 / 20.0) as f32;
        let (open_rise, open_fall) = automix_gains(0.0, &plan);
        assert!(open_rise.abs() < 1e-4, "the bed eases in from silence, got {open_rise}");
        assert!((open_fall - 1.0).abs() < 1e-4, "the outgoing stays up, got {open_fall}");

        let (bed_rise, bed_fall) = automix_gains(0.2, &plan);
        assert!(
            bed_rise > bed * 0.5 && bed_rise < 0.45,
            "early in the blend the incoming is underneath, got {bed_rise}"
        );
        assert!((bed_fall - 1.0).abs() < 1e-4, "the outgoing is still the record");

        let (late_rise, late_fall) = automix_gains(0.95, &plan);
        assert!(late_rise > 0.95, "after the swap the incoming is the record, got {late_rise}");
        assert!(late_fall < 0.35, "after the swap the outgoing is leaving, got {late_fall}");

        // The dip is on the incoming, just before the swap, and the outgoing
        // gain at that moment is still full. Sample a half-width either side
        // of the notch so the comparison is the dip, not the climb into it.
        let before = automix_gains(0.54, &plan).0;
        let notch = automix_gains(0.58, &plan).0;
        let after = automix_gains(0.70, &plan).0;
        assert!(
            notch < before * 0.85 && after > notch,
            "expected a dip then a recovery, got {before} -> {notch} -> {after}"
        );
        let outgoing_at_dip = automix_gains(0.58, &plan).1;
        assert!(
            outgoing_at_dip > 0.75,
            "the dip is on the incoming; the outgoing is still leaving slowly, got {outgoing_at_dip}"
        );
    }

    /// A handoff stretch that is stepped back to unity at the end of a blend is
    /// a pitch step, because the stretch is a resample.
    ///
    /// Regression-shaped: `release_plan_stretch` used to fire at the fade's end
    /// and land the rate on 1.0 in a single frame — a 3 % stretch is 51 cents,
    /// arriving in one sample. The glide walks there instead, so the release
    /// finds unity already reached and changes nothing.
    #[test]
    fn the_handoff_tempo_glide_lands_on_unity_rather_than_stepping() {
        let base = 1.03f64;
        assert!(
            (base - 1.0).abs() > 1e-4,
            "this test is about a non-unity rate"
        );
        // Monotone, and strictly inside the range the whole way.
        let mut previous = f64::INFINITY;
        for step in 0..=1000 {
            let p = step as f64 / 1000.0;
            let target = glided_plan_rate(base, p);
            assert!(
                target <= previous + 1e-12 && target >= 1.0 - 1e-12,
                "glide at {p} was {target}, outside (1.0, {previous}]"
            );
            previous = target;
        }
        // Exactly unity at the end, so `release_plan_stretch`'s early-out is
        // what actually runs and there is nothing to snap.
        assert_eq!(glided_plan_rate(base, 1.0), 1.0);
        // A unity plan is not glided at all.
        assert_eq!(glided_plan_rate(1.0, 0.5), 1.0);
    }

    /// A beatmatched handoff stretches the incoming track so the two share a
    /// grid for the blend. That stretch must not survive the blend.
    ///
    /// Regression: the port baked `plan_rate` into the voice's speed resampler
    /// at `Voice::open` and nothing ever cleared it, so every track that
    /// arrived through a beatmatched or phrase-switch blend played ~3 % fast for
    /// its entire length — +51 cents, with the published position running at the
    /// stretched rate too. Upstream resets the player's speed in both
    /// `finish()` and `retire()`.
    ///
    /// The stretch is a WSOLA stage now rather than a rate change, so the
    /// assertion is on the stage: engaged at the plan's rate while the blend
    /// runs, gone and drained once it ends.
    #[test]
    fn a_promoted_voice_drops_the_handoff_tempo_stretch() {
        let dir = std::env::temp_dir().join("bitchord-mixer-stretch");
        std::fs::create_dir_all(&dir).unwrap();
        let path = dir.join("a.wav");
        test_wav(&path, 4.0, 440.0);

        let request = TrackSource {
            source: path.display().to_string(),
            title: "A".into(),
            artist: String::new(),
            start_seconds: 0.0,
            // What the planner hands a beatmatched handoff.
            plan: TransitionPlan {
                playback_rate: 1.03,
                ..TransitionPlan::default()
            },
            headers: std::collections::HashMap::new(),
            claimed_kbps: 0,
            loudness_db: None,
            duration_seconds: 0.0,
        };
        let mut voice = Voice::open(&request, false, 0.0, 44_100, 1.0, false, false).unwrap();
        // The listener's own speed is untouched by the handoff — that is the
        // point of routing the stretch through its own stage. It used to be
        // multiplied by the plan rate, which is the bug in its other form.
        assert!(
            (voice.effective_speed - 1.0).abs() < 1e-6,
            "the handoff must not touch the speed control, got {}",
            voice.effective_speed
        );
        // And nothing is running yet: the stage is for a blend, and this voice
        // has not entered one. A `Load` — a tap on the queue, a skip — carries
        // the same plan record, and engaging here would leave the track playing
        // 3 % slow for its whole length with nothing to release it.
        assert!(
            voice.stretch.is_none(),
            "a fresh open must not engage the handoff stretch"
        );
        assert_eq!(voice.base_plan_rate, 1.03, "but the plan's ratio is remembered");

        // The blend engages it...
        voice.set_plan_rate(voice.base_plan_rate);
        assert!(voice.stretch.is_some());
        assert!((voice.stretch.as_ref().unwrap().rate() - 1.03).abs() < 1e-9);

        // The blend holds the rate. Walking it during the fade is the flam.
        assert!((voice.plan_rate - 1.03).abs() < 1e-9);
        // With no post-blend glide requested, release is immediate and arms
        // the drain. The stage is still holding a frame; dropping it there
        // would punch a hole. It goes on the next pull.
        voice.release_plan_stretch(1.0, 44_100);
        assert!(
            voice.stretch_draining,
            "release must drain the stage rather than drop it"
        );
        assert!(
            (voice.effective_speed - 1.0).abs() < 1e-6,
            "the stretch outlived the blend: {}",
            voice.effective_speed
        );
        assert!((voice.plan_rate - 1.0).abs() < 1e-9);
        let _ = voice.pull(512, 44_100);
        assert!(!voice.stretch_draining);
        assert!(voice.stretch.is_none(), "the stretch outlived the blend");

        // A later user speed change must not resurrect it.
        voice.set_playback_speed(1.25, 44_100);
        assert!(
            (voice.effective_speed - 1.25).abs() < 1e-6,
            "a speed change re-stacked the stretch: {}",
            voice.effective_speed
        );
        assert!(
            voice.stretch.is_none(),
            "a speed change must not bring the handoff stage back"
        );
    }

    /// Retiring the stretch must not swallow the samples it was still holding.
    ///
    /// The stage buffers roughly a frame of input it has not placed. Dropping it
    /// on release would punch a ~12 ms hole in the track at the exact moment the
    /// blend hands it over and its gain reaches unity — the worst possible place
    /// for a discontinuity, and one no level assertion on the blend would catch
    /// because the blend is already over.
    #[test]
    fn retiring_the_stretch_drains_rather_than_drops() {
        let dir = std::env::temp_dir().join("bitchord-mixer-stretch");
        std::fs::create_dir_all(&dir).unwrap();
        let path = dir.join("drain.wav");
        test_wav(&path, 3.0, 440.0);

        let request = TrackSource {
            source: path.display().to_string(),
            title: "A".into(),
            artist: String::new(),
            start_seconds: 0.0,
            plan: TransitionPlan {
                playback_rate: 1.03,
                ..TransitionPlan::default()
            },
            headers: std::collections::HashMap::new(),
            claimed_kbps: 0,
            loudness_db: None,
            duration_seconds: 0.0,
        };
        let mut voice = Voice::open(&request, false, 0.0, 44_100, 1.0, false, false).unwrap();
        // Run the blend part of the way so the stage has something buffered.
        for _ in 0..40 {
            let frames = voice.pull(512, 44_100);
            assert!(!frames.is_empty(), "the voice stopped producing audio");
        }
        voice.set_plan_rate(voice.base_plan_rate);
        voice.release_plan_stretch(1.0, 44_100);
        let before = voice.emitted_dev_frames;
        let frames = voice.pull(512, 44_100);
        assert!(
            !frames.is_empty(),
            "the drain must hand over what the stage was holding, not return nothing"
        );
        assert!(
            voice.emitted_dev_frames > before,
            "the drained samples were never emitted"
        );
        assert!(voice.stretch.is_none(), "the stage should be gone after the drain");
    }

    /// Drain `frames` and return the RMS of what came out.
    fn rms_frames(consumer: &mut rtrb::Consumer<f32>, buffered: &AtomicU64, frames: usize) -> f64 {
        let mut sum = 0.0f64;
        let mut count = 0usize;
        let target = frames * 2;
        let deadline = std::time::Instant::now() + std::time::Duration::from_secs(30);
        while count < target && std::time::Instant::now() < deadline {
            match consumer.pop() {
                Ok(sample) => {
                    sum += (sample as f64) * (sample as f64);
                    count += 1;
                    if count % 2 == 0 {
                        let mut current = buffered.load(Ordering::Relaxed);
                        while current > 0 {
                            match buffered.compare_exchange_weak(
                                current,
                                current - 1,
                                Ordering::Relaxed,
                                Ordering::Relaxed,
                            ) {
                                Ok(_) => break,
                                Err(v) => current = v,
                            }
                        }
                    }
                }
                Err(_) => std::thread::sleep(std::time::Duration::from_millis(1)),
            }
        }
        if count == 0 {
            return 0.0;
        }
        (sum / count as f64).sqrt()
    }

    /// How well a swap actually lines up.
    ///
    /// Swapping to a byte-identical copy makes alignment directly measurable:
    /// if the two sides are sample-aligned and the fade is linear, the blend
    /// *is* the original signal at unity and the level cannot move. Whatever
    /// deviation shows up here is comb cancellation — what a listener hears as
    /// a hollow, phasey moment instead of a quality change.
    #[test]
    fn swap_to_an_identical_copy_reports_its_alignment() {
        let (mut harness, low, _) = SwapHarness::new("swap-level");
        let copy = low.with_file_name("low-copy.wav");
        std::fs::copy(&low, &copy).unwrap();

        harness
            .tx
            .send(Command::Load {
                request: SwapHarness::source(&low, "Low", 96),
                reply: crossbeam_channel::bounded(1).0,
            })
            .unwrap();
        drain_frames(&mut harness.consumer, &harness.buffered, 44_100);
        let before = rms_frames(&mut harness.consumer, &harness.buffered, 44_100 / 4);
        assert!(before > 0.0, "the track must be producing audio");

        let (reply_tx, reply_rx) = crossbeam_channel::bounded(1);
        harness
            .tx
            .send(Command::SwapSource {
                request: SwapHarness::source(&copy, "Copy", 320),
                crossfade_seconds: SWAP_CROSSFADE_MS / 1000.0,
                reply: reply_tx,
            })
            .unwrap();
        reply_rx
            .recv_timeout(std::time::Duration::from_secs(10))
            .expect("the mixer must answer a swap")
            .expect("the swap must be accepted");

        // Short windows, so a 550 ms fade cannot be averaged away by the
        // single-voice audio either side of it. Drain until the probe reports,
        // which is the moment the fade completed.
        let mut worst_db = 0.0f64;
        let mut correlation: Option<f64> = None;
        let deadline = std::time::Instant::now() + std::time::Duration::from_secs(15);
        while std::time::Instant::now() < deadline {
            let window = rms_frames(&mut harness.consumer, &harness.buffered, 44_100 / 20);
            if window > 0.0 {
                let db = 20.0 * (window / before).log10();
                if db.abs() > worst_db.abs() {
                    worst_db = db;
                }
            }
            correlation = harness.nerd.lock().unwrap().swap_correlation;
            if correlation.is_some() {
                break;
            }
        }
        eprintln!(
            "[swap-alignment] worst level deviation through the fade: {worst_db:.2} dB, rho={correlation:?}"
        );
        // Measured at 0.00 dB: the two sides are sample-aligned and the linear
        // fade makes the blend the original signal. 2 dB leaves room for a
        // future rate change between the two sources while still catching a
        // genuine misalignment, which reads as a deep comb notch.
        assert!(
            worst_db.abs() < 2.0,
            "the swap is misaligned by {worst_db} dB of comb"
        );
        // The probe has to be able to say "these are the same signal" — that is
        // the measurement everything else here rests on.
        let rho = correlation.expect("a completed swap must report a correlation");
        assert!(
            rho > 0.99,
            "two byte-identical copies must correlate at 1.0, got {rho}"
        );
        harness.finish();
    }

    struct SwapHarness {
        tx: crossbeam_channel::Sender<Command>,
        consumer: rtrb::Consumer<f32>,
        buffered: std::sync::Arc<AtomicU64>,
        position: std::sync::Arc<AtomicU64>,
        events: std::sync::Arc<RecordedEvents>,
        nerd: std::sync::Arc<std::sync::Mutex<NerdSnapshot>>,
        shutdown: std::sync::Arc<AtomicBool>,
        flush_ring: std::sync::Arc<AtomicBool>,
        bail_flush: std::sync::Arc<AtomicBool>,
        handle: Option<std::thread::JoinHandle<()>>,
    }

    impl SwapHarness {
        fn new(tag: &str) -> (SwapHarness, std::path::PathBuf, std::path::PathBuf) {
            let dir = std::env::temp_dir().join(format!("bitchord-mixer-{tag}"));
            std::fs::create_dir_all(&dir).unwrap();
            let low = dir.join("low.wav");
            let high = dir.join("high.wav");
            test_wav(&low, 8.0, 440.0);
            test_wav(&high, 8.0, 440.0);

            let events = std::sync::Arc::new(RecordedEvents::default());
            let (tx, rx) = crossbeam_channel::unbounded::<Command>();
            let (producer_side, consumer) = rtrb::RingBuffer::<f32>::new(44_100 * 2 * 2);
            let buffered = std::sync::Arc::new(AtomicU64::new(0));
            let position = std::sync::Arc::new(AtomicU64::new(0));
            let duration = std::sync::Arc::new(AtomicU64::new(0));
            let shutdown = std::sync::Arc::new(AtomicBool::new(false));
            let flush_ring = std::sync::Arc::new(AtomicBool::new(false));
            let bail_flush = std::sync::Arc::new(AtomicBool::new(false));
            let nerd = std::sync::Arc::new(std::sync::Mutex::new(NerdSnapshot::default()));
            let handle = std::thread::spawn({
                let events = events.clone();
                let buffered = buffered.clone();
                let position = position.clone();
                let duration = duration.clone();
                let shutdown = shutdown.clone();
                let flush_ring = flush_ring.clone();
                let bail_flush = bail_flush.clone();
                let nerd = nerd.clone();
                move || {
                    run_mixer(
                        rx,
                        producer_side,
                        buffered,
                        position,
                        duration,
                        44_100,
                        events,
                        shutdown,
                        flush_ring,
                        bail_flush,
                        nerd,
                    )
                }
            });
            (
                SwapHarness {
                    tx,
                    consumer,
                    buffered,
                    position,
                    events,
                    nerd,
                    shutdown,
                    flush_ring,
                    bail_flush,
                    handle: Some(handle),
                },
                low,
                high,
            )
        }

        fn source(path: &std::path::Path, title: &str, kbps: u32) -> TrackSource {
            TrackSource {
                source: path.display().to_string(),
                title: title.into(),
                artist: String::new(),
                start_seconds: 0.0,
                plan: TransitionPlan::default(),
                headers: std::collections::HashMap::new(),
                claimed_kbps: kbps,
                loudness_db: None,
            duration_seconds: 0.0,
            }
        }

        fn finish(mut self) {
            self.shutdown.store(true, Ordering::Relaxed);
            if let Some(handle) = self.handle.take() {
                let _ = handle.join();
            }
        }
    }

    #[test]
    fn source_swap_without_a_current_track_is_refused() {
        let (harness, low, _) = SwapHarness::new("swap-refuse");
        let (reply_tx, reply_rx) = crossbeam_channel::bounded(1);
        harness
            .tx
            .send(Command::SwapSource {
                request: SwapHarness::source(&low, "Low", 96),
                crossfade_seconds: SWAP_CROSSFADE_MS / 1000.0,
                reply: reply_tx,
            })
            .unwrap();
        let reply = reply_rx
            .recv_timeout(std::time::Duration::from_secs(10))
            .expect("the mixer must answer a swap");
        assert!(reply.is_err(), "nothing is playing, so there is nothing to swap");
        harness.finish();
    }

    /// The regression this guards: upgrading the source used to be a `loadTrack`
    /// — stop, open, seek — which put an audible hole in the song and reset the
    /// playhead. A swap must instead crossfade in place, keep the timeline, and
    /// never be reported as the queue moving on.
    #[test]
    fn source_swap_promotes_the_replacement_without_a_handoff() {
        let (mut harness, low, _) = SwapHarness::new("swap-crossfade");
        let high = low.with_file_name("high.wav");
        std::fs::copy(&low, &high).unwrap();
        harness
            .tx
            .send(Command::Load {
                request: SwapHarness::source(&low, "Low", 96),
                reply: crossbeam_channel::bounded(1).0,
            })
            .unwrap();

        drain_frames(&mut harness.consumer, &harness.buffered, 44_100);
        let _ = rms_frames(&mut harness.consumer, &harness.buffered, 44_100 / 4);
        let before = harness.position.load(Ordering::Relaxed);
        assert!(before > 0, "the track must be advancing before the swap");

        let (reply_tx, reply_rx) = crossbeam_channel::bounded(1);
        harness
            .tx
            .send(Command::SwapSource {
                request: SwapHarness::source(&high, "High", 320),
                crossfade_seconds: SWAP_CROSSFADE_MS / 1000.0,
                reply: reply_tx,
            })
            .unwrap();
        let reply = reply_rx
            .recv_timeout(std::time::Duration::from_secs(10))
            .expect("the mixer must answer a swap");
        assert!(reply.is_ok(), "swap must be accepted, got {reply:?}");

        let deadline = std::time::Instant::now() + std::time::Duration::from_secs(15);
        while std::time::Instant::now() < deadline {
            let _ = rms_frames(&mut harness.consumer, &harness.buffered, 44_100 / 20);
            if harness.nerd.lock().unwrap().kbps == 320 {
                break;
            }
        }

        let kbps = harness.nerd.lock().unwrap().kbps;
        assert_eq!(
            kbps,
            320,
            "the promoted source must be the one the readout names"
        );
        assert!(
            harness.events.handoffs.lock().unwrap().is_empty(),
            "a source swap is not a track change and must not fire a handoff"
        );
        let after = harness.position.load(Ordering::Relaxed);
        assert!(
            after >= before,
            "the playhead moved backwards across a swap: {before} ms -> {after} ms"
        );
        harness.finish();
    }

    /// When a candidate replacement is a mismatched recording or corrupt transcode
    /// (Pearson correlation rho < 0.85), the source swap must be rejected:
    /// the replacement voice is dropped, the original track remains playing at unity gain,
    /// and the nerd readout does not promote to the new source.
    #[test]
    fn source_swap_with_mismatched_recording_is_rejected() {
        let (mut harness, low, _) = SwapHarness::new("swap-rejected");
        let dir = low.parent().unwrap();
        let mismatched = dir.join("mismatched.wav");
        test_wav(&mismatched, 8.0, 660.0); // 660 Hz vs 440 Hz -> rho near 0

        harness
            .tx
            .send(Command::Load {
                request: SwapHarness::source(&low, "Low", 96),
                reply: crossbeam_channel::bounded(1).0,
            })
            .unwrap();

        drain_frames(&mut harness.consumer, &harness.buffered, 44_100 * 2);

        let (reply_tx, reply_rx) = crossbeam_channel::bounded(1);
        harness
            .tx
            .send(Command::SwapSource {
                request: SwapHarness::source(&mismatched, "Mismatched", 320),
                crossfade_seconds: SWAP_CROSSFADE_MS / 1000.0,
                reply: reply_tx,
            })
            .unwrap();
        let reply = reply_rx
            .recv_timeout(std::time::Duration::from_secs(10))
            .expect("the mixer must answer a swap");
        assert!(reply.is_ok(), "swap initiation should succeed");

        // Drain enough frames for the 550ms crossfade to run and finish_transition to trigger
        for _ in 0..40 {
            drain_frames(&mut harness.consumer, &harness.buffered, 44_100 / 4);
            if harness.nerd.lock().unwrap().swap_correlation.is_some() {
                break;
            }
        }

        let (rho, kbps) = {
            let nerd = harness.nerd.lock().unwrap();
            (nerd.swap_correlation.expect("swap correlation must be measured"), nerd.kbps)
        };
        assert!(
            rho < 0.85,
            "mismatched 440Hz vs 660Hz must yield rho < 0.85, got {rho}"
        );
        assert_eq!(
            kbps, 96,
            "kbps must NOT be promoted to 320 when swap is rejected"
        );
        harness.finish();
    }

    /// A route change replaces the ring. Everything between the playhead and
    /// the decoder's read head is in the abandoned ring and nothing has played
    /// it, so the voice has to be re-pointed at the playhead — otherwise the
    /// listener loses the whole ring depth, seconds of music, the moment their
    /// headphones disconnect.
    #[test]
    fn output_format_change_resumes_at_the_playhead() {
        let (mut harness, low, _) = SwapHarness::new("route-change");
        harness
            .tx
            .send(Command::Load {
                request: SwapHarness::source(&low, "Low", 96),
                reply: crossbeam_channel::bounded(1).0,
            })
            .unwrap();

        // Long enough that the playhead is well inside the track and the ring
        // is deep enough for a skip to be unmistakable.
        drain_frames(&mut harness.consumer, &harness.buffered, 44_100 * 2);
        let before = harness.position.load(Ordering::Relaxed);
        assert!(before > 0, "the track must be advancing");

        // Replace the output exactly as a route-change rebuild does.
        let (producer, mut consumer) = rtrb::RingBuffer::<f32>::new(48_000 * 2 * 2);
        harness
            .tx
            .send(Command::SetOutputFormat {
                rate: 48_000,
                producer,
            })
            .unwrap();

        // The old consumer is dead now; drain the replacement.
        drain_frames(&mut consumer, &harness.buffered, 48_000 / 2);
        let after = harness.position.load(Ordering::Relaxed);

        assert!(
            after + 500 >= before,
            "the playhead restarted instead of continuing: {before} ms -> {after} ms"
        );
        assert!(
            after < before + 1_500,
            "the playhead skipped the abandoned ring: {before} ms -> {after} ms"
        );
        harness.finish();
    }

    /// Skipping a track (Command::Load) must trigger a deferred bail flush
    /// rather than an immediate hard cut of the ring, so the audio ramps out
    /// over 120 ms without a click.
    #[test]
    fn skip_load_triggers_bail_flush_not_instant_flush() {
        let (mut harness, low, high) = SwapHarness::new("skip-bail");
        harness
            .tx
            .send(Command::Load {
                request: SwapHarness::source(&low, "Low", 96),
                reply: crossbeam_channel::bounded(1).0,
            })
            .unwrap();

        // Drain some frames so playback is active.
        drain_frames(&mut harness.consumer, &harness.buffered, 44_100);

        // Reset the bail_flush and flush_ring flags in harness
        harness.bail_flush.store(false, Ordering::Relaxed);
        harness.flush_ring.store(false, Ordering::Relaxed);

        // Issue a skip by loading a new track.
        harness
            .tx
            .send(Command::Load {
                request: SwapHarness::source(&high, "High", 320),
                reply: crossbeam_channel::bounded(1).0,
            })
            .unwrap();

        // Wait for mixer to process Command::Load.
        let deadline = std::time::Instant::now() + std::time::Duration::from_secs(5);
        while !harness.bail_flush.load(Ordering::Acquire) && std::time::Instant::now() < deadline {
            std::thread::sleep(std::time::Duration::from_millis(5));
        }

        assert!(
            harness.bail_flush.load(Ordering::Acquire),
            "Command::Load must set bail_flush for the 120 ms ramp"
        );
        assert!(
            !harness.flush_ring.load(Ordering::Acquire),
            "Command::Load must not perform an immediate hard flush_ring"
        );

        harness.finish();
    }
}
