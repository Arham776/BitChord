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
    effective_speed: f32,
    /// Automix tempo stretch; multiplied into `effective_speed`.
    plan_rate: f64,
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
        let duration = decoder.duration_seconds().unwrap_or(0.0);
        let start = if cue {
            clamp_start_seconds(request.start_seconds, duration)
        } else {
            request.start_seconds.max(0.0)
        };
        if start > 0.0 {
            decoder.seek_seconds(start).map_err(|e| e.to_string())?;
        }
        log::info!(
            "voice opened: title={:?} requested_start={:.3}s clamped_start={:.3}s actual_start={:.3}s source_rate={} device_rate={}",
            request.title,
            request.start_seconds,
            start,
            decoder.position_seconds(),
            src_rate,
            device_rate,
        );
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
            device_rate,
            channel_l: Vec::new(),
            channel_r: Vec::new(),
            pending_dev: Vec::new(),
            pending_dev_cursor: 0,
            skip_silence,
            silent_dev_frames: 0,
            effective_speed: effective,
            plan_rate,
            loudness_db: request.loudness_db,
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
        self.base_position + self.decoder.position_seconds()
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
    eq: EqualizerProcessor,
    nerd: Arc<Mutex<NerdSnapshot>>,
    /// Loudness-normalization master switch (upstream
    /// `AppSettings.loudnessNormalization`, on by default). Per-voice figures
    /// ride on the voices; this decides whether the render uses them.
    loudness_enabled: bool,
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
            *nerd = NerdSnapshot {
                codec: info.codec.clone(),
                sample_rate: info.sample_rate,
                bit_depth: info.bit_depth,
                channels: info.channels,
                kbps: info.kbps,
                loudness_gain_db: gain_db,
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
            true,
        ) {
            Ok(mut voice) => {
                voice.gain = 1.0;
                let info = voice.info.clone();
                let duration = info.duration_seconds;
                let (_, gain_db) = loudness_gain(voice.loudness_db, self.loudness_enabled);
                if let Ok(mut nerd) = self.nerd.lock() {
                    *nerd = NerdSnapshot {
                        codec: info.codec.clone(),
                        sample_rate: info.sample_rate,
                        bit_depth: info.bit_depth,
                        channels: info.channels,
                        kbps: info.kbps,
                        loudness_gain_db: gain_db,
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
            fade_frames.min(incoming_cap_frames).max(1)
        };
        let p = if span == 0 {
            1.0
        } else {
            (emitted as f64 / span as f64).clamp(0.0, 1.0)
        };
        let rise = rise_gain(p);
        let fall = fall_gain(p);
        let plan = self.transition.as_ref().map(|t| (t.plan.clone(), t.swap));
        if let (Some(current), Some(incoming), Some((plan, swap))) =
            (&mut self.current, &mut self.incoming, plan)
        {
            current.gain = fall;
            incoming.gain = rise;
            if swap {
                // A source swap is the same recording against itself, so any
                // ride here would be an edit the record never asked for.
                // Upstream's standby players run this fade unfiltered.
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
                if let Some(mut incoming) = self.incoming.take() {
                    incoming.gain = 1.0;
                    incoming.filter.open();
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
        // The mixer blends to interleaved stereo, so the equaliser is a single
        // stereo instance on the mixed stream.
        eq: EqualizerProcessor::new(device_rate, 2),
        nerd,
        // Upstream's default: normalization on unless the listener says off.
        // The engine owner's first `set_loudness_enabled` reconciles this with
        // the stored setting either way.
        loudness_enabled: true,
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

        if let Some(voice) = &mut state.current {
            if state.playing {
                let frames = voice.pull(CHUNK_FRAMES, state.device_rate);
                if !frames.is_empty() {
                    audible = true;
                    produced = produced.max(frames.len());
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
            loudness_db: None,
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
            loudness_db: None,
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
            loudness_db: None,
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

    struct SwapHarness {
        tx: crossbeam_channel::Sender<Command>,
        consumer: rtrb::Consumer<f32>,
        buffered: std::sync::Arc<AtomicU64>,
        position: std::sync::Arc<AtomicU64>,
        events: std::sync::Arc<RecordedEvents>,
        nerd: std::sync::Arc<std::sync::Mutex<NerdSnapshot>>,
        shutdown: std::sync::Arc<AtomicBool>,
        handle: Option<std::thread::JoinHandle<()>>,
    }

    impl SwapHarness {
        fn new(tag: &str) -> (SwapHarness, std::path::PathBuf, std::path::PathBuf) {
            let dir = std::env::temp_dir().join(format!("bitchord-mixer-{tag}"));
            std::fs::create_dir_all(&dir).unwrap();
            let low = dir.join("low.wav");
            let high = dir.join("high.wav");
            test_wav(&low, 8.0, 440.0);
            test_wav(&high, 8.0, 660.0);

            let events = std::sync::Arc::new(RecordedEvents::default());
            let (tx, rx) = crossbeam_channel::unbounded::<Command>();
            let (producer_side, consumer) = rtrb::RingBuffer::<f32>::new(44_100 * 2 * 2);
            let buffered = std::sync::Arc::new(AtomicU64::new(0));
            let position = std::sync::Arc::new(AtomicU64::new(0));
            let duration = std::sync::Arc::new(AtomicU64::new(0));
            let shutdown = std::sync::Arc::new(AtomicBool::new(false));
            let nerd = std::sync::Arc::new(std::sync::Mutex::new(NerdSnapshot::default()));
            let handle = std::thread::spawn({
                let events = events.clone();
                let buffered = buffered.clone();
                let position = position.clone();
                let duration = duration.clone();
                let shutdown = shutdown.clone();
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
                        std::sync::Arc::new(AtomicBool::new(false)),
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
        let (mut harness, low, _) = SwapHarness::new("swap-refuse");
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
        let (mut harness, low, high) = SwapHarness::new("swap-crossfade");
        harness
            .tx
            .send(Command::Load {
                request: SwapHarness::source(&low, "Low", 96),
                reply: crossbeam_channel::bounded(1).0,
            })
            .unwrap();

        // Get well into the track, so the voice has served audio and holds a
        // partially drained decode batch (the state the old code mis-seeked).
        drain_frames(&mut harness.consumer, &harness.buffered, 44_100 * 2);
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

        // Long enough for the crossfade to run out of the replacement's own
        // output, plus the ring that was already full of the old source.
        for _ in 0..40 {
            drain_frames(&mut harness.consumer, &harness.buffered, 44_100 / 4);
            if harness.nerd.lock().unwrap().kbps == 320 {
                break;
            }
        }

        assert_eq!(
            harness.nerd.lock().unwrap().kbps,
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
}
