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
use crate::eq::GraphicEq;
use crate::spatial::SpatialRenderer;
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
    pub cue_seconds: f64,
    /// Tempo stretch — multiplied into the incoming voice's `speed_resampler`
    /// at open (and kept across later `set_playback_speed` calls).
    pub playback_rate: f64,
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
            cue_seconds: 0.0,
            playback_rate: 1.0,
        }
    }
}

pub enum Command {
    Load {
        request: TrackSource,
        reply: Sender<Result<TrackInfo, String>>,
    },
    QueueNext {
        request: TrackSource,
    },
    Play,
    Pause,
    Stop,
    Seek {
        seconds: f64,
        reply: Sender<Result<(), String>>,
    },
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
    SetEqGains(Vec<f32>),
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


/// Equal-power pair: rise² + fall² = 1, so the blend never dips.
fn rise_gain(progress: f64) -> f32 {
    (progress.clamp(0.0, 1.0) * core::f64::consts::PI / 2.0).sin() as f32
}

fn fall_gain(progress: f64) -> f32 {
    (progress.clamp(0.0, 1.0) * core::f64::consts::PI / 2.0).cos() as f32
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
    effective_speed: f32,
    /// Automix tempo stretch; multiplied into `effective_speed`.
    plan_rate: f64,
}

impl Voice {
    fn open(
        request: &TrackSource,
        spatial_enabled: bool,
        head_yaw: f32,
        device_rate: u32,
        playback_speed: f32,
        skip_silence: bool,
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
        let duration = decoder.duration_seconds().unwrap_or(0.0);
        let start = clamp_start_seconds(request.start_seconds, duration);
        if start > 0.0 {
            decoder.seek_seconds(start).map_err(|e| e.to_string())?;
        }
        let plan_rate = if request.plan.playback_rate > 0.05 {
            request.plan.playback_rate
        } else {
            1.0
        };
        let effective = (playback_speed as f64 * plan_rate).clamp(0.5, 2.0) as f32;
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
            channel_l: Vec::new(),
            channel_r: Vec::new(),
            pending_dev: Vec::new(),
            pending_dev_cursor: 0,
            skip_silence,
            silent_dev_frames: 0,
            effective_speed: effective,
            plan_rate,
        })
    }

    fn set_playback_speed(&mut self, speed: f32, device_rate: u32) {
        let effective = (speed as f64 * self.plan_rate).clamp(0.5, 2.0) as f32;
        if (effective - self.effective_speed).abs() < 0.001 {
            return;
        }
        self.effective_speed = effective;
        self.speed_l = speed_resampler(device_rate, effective);
        self.speed_r = speed_resampler(device_rate, effective);
    }

    /// Rebuild post-decode DSP for a new DAC rate (AirPods connect/disconnect).
    fn retarget_device(&mut self, device_rate: u32, spatial_enabled: bool, head_yaw: f32) {
        let src = self.info.sample_rate.max(1);
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
        self.base_position + self.decoder.position_seconds()
    }

    /// Remaining source-domain seconds the decoder still holds, if known.
    fn remaining_seconds(&self) -> Option<f64> {
        let total = self.decoder.duration_seconds()?;
        let pos = self.decoder.position_seconds();
        Some((total - pos).max(0.0))
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
                // breath still lands, then drop the rest of the gap.
                if silence_exceeds_floor(self.silent_dev_frames, device_rate) {
                    self.pending_dev.clear();
                    self.pending_dev_cursor = 0;
                    continue;
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

fn speed_resampler(device_rate: u32, speed: f32) -> StreamResampler {
    let speed = speed.clamp(0.5, 2.0) as f64;
    StreamResampler::with_rates(device_rate as f64 * speed, device_rate as f64)
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
    playback_speed: f32,
    skip_silence: bool,
    eq: GraphicEq,
    nerd: Arc<Mutex<NerdSnapshot>>,
}

#[derive(Debug, Clone, Default)]
pub struct NerdSnapshot {
    pub codec: String,
    pub sample_rate: u32,
    pub bit_depth: u32,
    pub channels: u32,
    pub kbps: u32,
}

impl MixerState {
    fn set_state(&mut self, state: crate::PlaybackState) {
        if self.state != state {
            self.state = state;
            self.events.state_changed(state);
        }
    }

    fn publish_nerd(&self, info: &TrackInfo) {
        if let Ok(mut nerd) = self.nerd.lock() {
            *nerd = NerdSnapshot {
                codec: info.codec.clone(),
                sample_rate: info.sample_rate,
                bit_depth: info.bit_depth,
                channels: info.channels,
                kbps: info.kbps,
            };
        }
    }

    /// Upstream `retire` + skip: drop every voice and the pending next so a
    /// user-chosen track cannot mix with the one it replaced.
    fn hard_cut(&mut self) {
        self.transition = None;
        self.incoming = None;
        self.pending_next = None;
        self.retiring.clear();
        self.current = None;
        self.flush_ring.store(true, Ordering::Release);
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
        ) {
            Ok(mut voice) => {
                voice.gain = 1.0;
                let info = voice.info.clone();
                let duration = info.duration_seconds;
                if let Ok(mut nerd) = self.nerd.lock() {
                    *nerd = NerdSnapshot {
                        codec: info.codec.clone(),
                        sample_rate: info.sample_rate,
                        bit_depth: info.bit_depth,
                        channels: info.channels,
                        kbps: info.kbps,
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
            let info = incoming.info.clone();
            let duration = info.duration_seconds;
            self.current = Some(incoming);
            self.duration_ms
                .store((duration * 1000.0) as u64, Ordering::Relaxed);
            if duration > 0.0 {
                self.events.duration_changed(duration);
            }
            self.publish_nerd(&info);
            self.publish_audible_position();
            self.events.handoff(info);
        }
        self.transition = None;
    }

    /// Arms a transition when the current track's audible tail is close
    /// enough. Returns true if a transition was created.
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
        if current.decoder.duration_seconds().unwrap_or(0.0) < 2.0
            && current.position_seconds() < 2.0
        {
            return;
        }
        let fade_s = self.effective_fade_seconds();
        let remaining_s = current.remaining_seconds().unwrap_or(f64::INFINITY);
        let buffered_s = self.buffered_frames.load(Ordering::Relaxed) as f64
            / self.device_rate as f64;
        let audible_tail_s = remaining_s + buffered_s;
        let need_s = fade_s + ARM_LEAD_MS as f64 / 1000.0;
        if audible_tail_s > need_s {
            return;
        }

        let request = self.pending_next.take().unwrap();
        let plan = request.plan.clone();
        let fade_frames =
            ((if plan.fade_seconds > 0.0 { plan.fade_seconds } else { fade_s })
                * self.device_rate as f64) as u64;
        match Voice::open(
            &request,
            self.spatial_enabled,
            self.head_yaw,
            self.device_rate,
            self.playback_speed,
            self.skip_silence,
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

    fn effective_fade_seconds(&self) -> f64 {
        // A fade that swallows a third of a song stops being a transition —
        // upstream's `fadeFor` cap. Applied against the *current* track.
        let window = self.crossfade_window_s.max(0.0);
        if let Some(current) = &self.current {
            if let Some(total) = current.decoder.duration_seconds() {
                if total > 0.0 {
                    return window.min(total / 3.0);
                }
            }
        }
        window
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
        let remaining_s = current.remaining_seconds().unwrap_or(f64::INFINITY);
        let buffered_s =
            self.buffered_frames.load(Ordering::Relaxed) as f64 / self.device_rate as f64;
        let audible_tail_s = remaining_s + buffered_s;
        if audible_tail_s > fade_s {
            return;
        }
        self.start_fade();
    }

    fn start_fade(&mut self) {
        let Some(voice) = self.incoming.take() else {
            return;
        };
        let info = voice.info.clone();
        log::info!("fade start + handoff: {}", info.title);
        self.duration_ms
            .store((info.duration_seconds * 1000.0) as u64, Ordering::Relaxed);
        self.incoming = Some(voice);
        if let Some(t) = &mut self.transition {
            t.phase = Phase::Fading;
            t.handed_off = true;
        }
        self.publish_nerd(&info);
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
            fade_frames.min(incoming_cap_frames).max(1)
        };
        let p = if span == 0 {
            1.0
        } else {
            (emitted as f64 / span as f64).clamp(0.0, 1.0)
        };
        let rise = rise_gain(p);
        let fall = fall_gain(p);
        let plan = self.transition.as_ref().map(|t| t.plan.clone());
        if let (Some(current), Some(incoming), Some(plan)) =
            (&mut self.current, &mut self.incoming, plan)
        {
            current.gain = fall;
            incoming.gain = rise;
            ride_filters(p, &plan, &mut current.filter, &mut incoming.filter);
        }
        p >= 1.0 || self.current.as_ref().is_some_and(|c| c.finished)
    }

    fn finish_transition(&mut self) {
        if let Some(t) = &self.transition {
            if t.handed_off {
                if let Some(mut incoming) = self.incoming.take() {
                    incoming.gain = 1.0;
                    incoming.filter.open();
                    self.current = Some(incoming);
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
        let audible = if handed_off {
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
    nerd: Arc<Mutex<NerdSnapshot>>,
) {
    let mut state = MixerState {
        current: None,
        incoming: None,
        pending_next: None,
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
        playback_speed: 1.0,
        skip_silence: false,
        eq: GraphicEq::new(device_rate),
        nerd,
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
            ) {
                Ok(voice) => {
                    let info = voice.info.clone();
                    let duration = voice.info.duration_seconds;
                    if let Ok(mut nerd) = state.nerd.lock() {
                        *nerd = NerdSnapshot {
                            codec: info.codec.clone(),
                            sample_rate: info.sample_rate,
                            bit_depth: info.bit_depth,
                            channels: info.channels,
                            kbps: info.kbps,
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
        Command::QueueNext { request } => {
            if request.source.is_empty() {
                state.pending_next = None;
            } else if state.current.as_ref().is_some_and(|c| c.info.source == request.source) {
                log::debug!("queueNext ignored; already current");
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
        Command::Seek { seconds, reply } => {
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
                            let _ = reply.send(Ok(()));
                        }
                        Err(e) => {
                            let _ = reply.send(Err(e.to_string()));
                        }
                    }
                }
                None => {
                    let _ = reply.send(Err("nothing playing".into()));
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
        Command::SetEqGains(gains) => {
            state.eq.set_gains_db(&gains);
        }
        Command::SetOutputFormat { rate, producer } => {
            *ring = producer;
            let rate = rate.max(1);
            if rate != state.device_rate {
                log::info!("output format {} Hz -> {rate} Hz", state.device_rate);
                state.device_rate = rate;
                state.eq.retarget(rate);
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
    // Maintenance: arm + start fade checks before rendering.
    state.consider_arm();
    state.consider_start_fade();
        let chunk_samples = CHUNK_FRAMES * 2;
    loop {
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
                    let gain = ret.from_gain * fall_gain(elapsed);
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

        if let Some(voice) = &mut state.current {
            if state.playing {
                let frames = voice.pull(CHUNK_FRAMES, state.device_rate);
                if !frames.is_empty() {
                    audible = true;
                    produced = produced.max(frames.len());
                    let gain = voice.gain;
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
                    let gain = voice.gain;
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
                run_mixer(rx, consumer_side, buffered, position, duration, 44_100, events, shutdown, std::sync::Arc::new(AtomicBool::new(false)), std::sync::Arc::new(Mutex::new(NerdSnapshot::default())))
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

    fn drain_until_handoff(
        consumer: &mut rtrb::Consumer<f32>,
        buffered: &AtomicU64,
        events: &RecordedEvents,
        seconds: u64,
    ) {
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
            if !events.handoffs.lock().unwrap().is_empty()
                || std::time::Instant::now() > deadline
            {
                break;
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
            },
        })
        .unwrap();

        drain_until_handoff(&mut consumer, &buffered, &events, 20);

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
}
