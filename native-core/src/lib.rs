//! native-core — BitChord's analyzer + playback engine behind one UniFFI boundary.
//!
//! The FFI surface (spec §2/§3.1): a narrow `PlayerEngine` object for playback
//! control, one callback interface for engine events, and the analyzer's
//! decode/DSP entry points. Swift and Kotlin bindings are generated from this
//! surface — no hand-written C header.

use std::sync::atomic::{AtomicBool, AtomicU32, AtomicU64, Ordering};
use std::sync::{Arc, Mutex};

use analyzer::BeatSpectrogram;
use cpal::traits::{DeviceTrait, HostTrait, StreamTrait};
use cpal::ErrorKind;
use mixer::{Command, EngineEvents, TrackInfo, TrackSource, TransitionPlan, TransitionStyle};

uniffi::setup_scaffolding!();

pub mod analyzer;
pub mod decode;
pub mod eq;
pub mod mixer;

/// The audio render thread's scheduling class.
///
/// Thread Performance Checker named the pairing that started this: a
/// user-interactive thread waiting on a default-QoS mixer. The wait is gone —
/// a seek queues and returns, like every player upstream — but the mixer's own
/// class still decides how it competes with everything else in the app for the
/// CPU. A render thread that gets scheduled late misses a real-time deadline,
/// the ring drains, and the dropout is audible as a stutter.
///
/// This used to be built only for macOS, on the reading that the class was a
/// desktop concern. iOS has the same API and the same problem, and the cost of
/// the omission was worse there: a Darwin thread inherits its creator's class,
/// and the mixer is spawned from the engine-startup task, which is `.utility` —
/// so the decoder ran in the same band as the artwork fetches and the automix
/// analysis it is supposed to outrank, and every page the listener opened took
/// the CPU it needed. That is the "navigation makes the music stutter" report.
mod qos {
    /// Puts the calling thread in the user-interactive class.
    ///
    /// The relative priority argument is 0: the mixer keeps the class that a
    /// gesture runs at rather than claiming a higher band than the UI, so this
    /// cannot outrank the main thread. It only stops the mixer being starved
    /// by it.
    #[cfg(target_vendor = "apple")]
    pub fn raise_current_thread() {
        // SAFETY: `pthread_set_qos_class_self_np` reads the calling thread's
        // QoS and stores a class on it. No pointer argument, nothing to get
        // wrong, and the return value only reports an unavailable class.
        unsafe {
            libc::pthread_set_qos_class_self_np(libc::qos_class_t::QOS_CLASS_USER_INTERACTIVE, 0);
        }
    }

    /// Nothing to raise: only Apple platforms express a scheduling class here,
    /// and on the others the equivalent is the platform's own audio policy.
    #[cfg(not(target_vendor = "apple"))]
    pub fn raise_current_thread() {}
}
pub mod metadata;
pub mod spatial;
pub mod time_stretch;
pub mod transition_filter;

// ---- FFI data types ---------------------------------------------------------

#[derive(uniffi::Enum, Clone, Copy, Debug, PartialEq, Eq)]
pub enum PlaybackState {
    Stopped,
    Buffering,
    Playing,
    Paused,
}

#[derive(uniffi::Enum, Clone, Copy, Debug, PartialEq, Eq)]
pub enum TrackEndReason {
    /// Ran out of track with nothing queued behind it.
    Natural,
    /// Replaced by an explicit load.
    Skipped,
    Error,
}

#[derive(uniffi::Enum, Debug, Clone, Copy, PartialEq, Eq)]
pub enum TransitionStyleRec {
    EqualPower,
    DjFilter,
    DjBlend,
    Gapless,
}

impl From<TransitionStyleRec> for TransitionStyle {
    fn from(value: TransitionStyleRec) -> Self {
        match value {
            TransitionStyleRec::EqualPower => TransitionStyle::EqualPower,
            TransitionStyleRec::DjFilter => TransitionStyle::DjFilter,
            TransitionStyleRec::DjBlend => TransitionStyle::DjBlend,
            TransitionStyleRec::Gapless => TransitionStyle::Gapless,
        }
    }
}

#[derive(uniffi::Record, Debug, Clone)]
pub struct TransitionPlanRec {
    pub style: TransitionStyleRec,
    pub bass_swap: bool,
    pub bass_swap_fraction: f64,
    pub filter_sweep: f64,
    pub vocal_overlap: f64,
    /// Explicit fade length for this pair; 0 = engine's crossfade window.
    pub fade_seconds: f64,
    /// Where the blend ends, as a position in the outgoing track's timeline;
    /// 0 = the file end. The planner picks it (the ranked mix-out anchor) and
    /// derives the bass swap and vocal overlap from the window it defines, so
    /// the mixer has to arm from it rather than from the file's last byte.
    pub transition_end_seconds: f64,
    /// Where the incoming track is cued (Automix mix-in point). 0 = top.
    ///
    /// Bounded by the planner: a mix-in is the top of the incoming track's own
    /// intro, snapped to a downbeat, and never more than `MAX_CUE_SECONDS` /
    /// `MAX_CUE_BEATS` / `MAX_CUE_FRACTION` into the file. 0 also means "no
    /// usable beat grid", in which case the next record plays from the top
    /// rather than from a guess.
    pub cue_seconds: f64,
    /// Tempo stretch — applied by the mixer. Pitch-preserving: the handoff
    /// stretch runs through WSOLA (`time_stretch`), held for the blend, then
    /// glided back to unity over `post_glide_seconds`.
    pub playback_rate: f64,
    /// See `mixer::TransitionPlan::bed_fraction`.
    pub bed_fraction: f64,
    /// See `mixer::TransitionPlan::bed_gain_db`.
    pub bed_gain_db: f64,
    /// See `mixer::TransitionPlan::dip_depth`.
    pub dip_depth: f64,
    /// See `mixer::TransitionPlan::dip_width`.
    pub dip_width: f64,
    /// See `mixer::TransitionPlan::post_glide_seconds`.
    pub post_glide_seconds: f64,
    /// The outgoing track's length as the planner measured it. See
    /// `mixer::TransitionPlan::outgoing_duration_seconds` — it is what makes a
    /// transition schedulable when the container declares no duration of its
    /// own.
    pub outgoing_duration_seconds: f64,
}

impl From<TransitionPlanRec> for TransitionPlan {
    fn from(rec: TransitionPlanRec) -> Self {
        TransitionPlan {
            style: rec.style.into(),
            bass_swap: rec.bass_swap,
            bass_swap_fraction: rec.bass_swap_fraction,
            filter_sweep: rec.filter_sweep,
            vocal_overlap: rec.vocal_overlap,
            fade_seconds: rec.fade_seconds,
            transition_end_seconds: rec.transition_end_seconds,
            cue_seconds: rec.cue_seconds,
            playback_rate: rec.playback_rate,
            bed_fraction: rec.bed_fraction,
            bed_gain_db: rec.bed_gain_db,
            dip_depth: rec.dip_depth,
            dip_width: rec.dip_width,
            post_glide_seconds: rec.post_glide_seconds,
            outgoing_duration_seconds: rec.outgoing_duration_seconds,
        }
    }
}

#[derive(uniffi::Record, Debug, Clone)]
pub struct LoadRequest {
    /// Local file path (security-scoped bookmarks resolved Swift-side) or an
    /// http(s) URL for the streaming reader.
    pub source: String,
    pub title: String,
    pub artist: String,
    /// Start offset (Automix cue). 0 = top.
    pub start_seconds: f64,
    pub plan: Option<TransitionPlanRec>,
    /// HTTP headers the streaming reader must present (User-Agent, Origin,
    /// Referer). googlevideo bakes the minting client into the URL and
    /// compares these on the media fetch — a mismatch throttles or 403s.
    pub headers: Option<std::collections::HashMap<String, String>>,
    /// Resolver-claimed bitrate (0 = unknown).
    pub claimed_kbps: Option<u32>,
    /// Per-track loudness from the player response (`None` for local files
    /// and substitutes). Upstream's `StreamResolver.loudnessDbFor`; the mixer
    /// stays at unity gain without one.
    pub loudness_db: Option<f64>,
    /// Track length the caller knows (catalogue response or local metadata).
    ///
    /// Not a convenience field: it is what makes a transition schedulable at
    /// all. Plenty of containers declare no duration — a bare MP3 with no Xing
    /// tag, a progressively-fetched MP4 whose `moov` has not arrived, most WebM
    /// — and with no end to schedule against the mixer cannot arm the incoming
    /// track, so the queue advances by a cut rather than a blend. The
    /// container's own figure still wins where it has one; this is the
    /// fallback.
    pub duration_seconds: Option<f64>,
}

#[derive(uniffi::Record, Debug, Clone)]
pub struct TrackInfoRec {
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

#[derive(uniffi::Record, Debug, Clone)]
pub struct NerdStatsRec {
    pub codec: String,
    pub sample_rate: u32,
    pub bit_depth: u32,
    pub channels: u32,
    pub kbps: u32,
    /// Applied loudness correction in dB (`None` = unity: switch off or no
    /// figure). The pipeline panel reads this, not the setting.
    pub loudness_gain_db: Option<f32>,
    /// Pearson correlation between the two encodings of the last source swap,
    /// measured on the samples that were blended. `None` until one has run.
    /// The swap fades a recording into another copy of itself, so this is what
    /// decides whether its linear fade is the level-flat one.
    pub swap_correlation: Option<f64>,
}

#[derive(uniffi::Record, Debug, Clone)]
pub struct DecodedRegion {
    /// Interleaved stereo (or mono when `mono` was requested) f32 samples.
    pub samples: Vec<f32>,
    pub sample_rate: u32,
    pub start_seconds: f64,
}

#[derive(uniffi::Record, Debug, Clone)]
pub struct TrackMetadata {
    pub title: String,
    pub artist: String,
    pub album: String,
    pub duration_seconds: f64,
    /// Encoded artwork bytes (JPEG/PNG as embedded), empty when none.
    pub artwork: Vec<u8>,
}

#[derive(uniffi::Record, Debug, Clone)]
pub struct MelSpectrogramResult {
    pub frames: u64,
    pub mels: u64,
    /// Row-major [frames][mels], log1p(1000·magnitude).
    pub values: Vec<f32>,
}

#[derive(uniffi::Error, Debug, Clone, PartialEq, Eq)]
pub enum EngineError {
    NoOutputDevice,
    StreamInit(String),
    LoadFailed(String),
    NotStarted,
}

impl std::fmt::Display for EngineError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            EngineError::NoOutputDevice => write!(f, "no audio output device"),
            EngineError::StreamInit(e) => write!(f, "stream init failed: {e}"),
            EngineError::LoadFailed(e) => write!(f, "load failed: {e}"),
            EngineError::NotStarted => write!(f, "engine not started"),
        }
    }
}

impl std::error::Error for EngineError {}

/// Engine events delivered from the mixer thread — implementors must hop to
/// the main thread as needed.
#[uniffi::export(callback_interface)]
pub trait EngineCallback: Send + Sync {
    fn on_state_changed(&self, state: PlaybackState);
    fn on_track_ended(&self, reason: TrackEndReason);
    fn on_error(&self, message: String);
    /// The incoming track became audible — current-track metadata flips here.
    fn on_handoff(&self, info: TrackInfoRec);
    fn on_duration_changed(&self, seconds: f64);
}

struct CallbackHolder(Arc<Box<dyn EngineCallback>>);
unsafe impl Send for CallbackHolder {}
unsafe impl Sync for CallbackHolder {}

/// Fan-out cell: the mixer holds this and forwards events to whatever
/// callback is registered (registration may happen before or after start).
#[derive(Default)]
struct SharedEvents {
    inner: Mutex<Option<CallbackHolder>>,
}

impl EngineEvents for SharedEvents {
    fn state_changed(&self, state: PlaybackState) {
        if let Some(holder) = self.inner.lock().unwrap().as_ref() {
            holder.0.on_state_changed(state);
        }
    }
    fn track_ended(&self, reason: TrackEndReason) {
        if let Some(holder) = self.inner.lock().unwrap().as_ref() {
            holder.0.on_track_ended(reason);
        }
    }
    fn error(&self, message: String) {
        if let Some(holder) = self.inner.lock().unwrap().as_ref() {
            holder.0.on_error(message);
        }
    }
    fn handoff(&self, info: TrackInfo) {
        if let Some(holder) = self.inner.lock().unwrap().as_ref() {
            holder.0.on_handoff(TrackInfoRec {
                title: info.title,
                artist: info.artist,
                source: info.source,
                duration_seconds: info.duration_seconds,
                codec: info.codec,
                sample_rate: info.sample_rate,
                bit_depth: info.bit_depth,
                channels: info.channels,
                kbps: info.kbps,
            });
        }
    }
    fn duration_changed(&self, seconds: f64) {
        if let Some(holder) = self.inner.lock().unwrap().as_ref() {
            holder.0.on_duration_changed(seconds);
        }
    }
}

#[derive(uniffi::Object)]
pub struct PlayerEngine {
    commands: crossbeam_channel::Sender<Command>,
    command_rx: Mutex<Option<crossbeam_channel::Receiver<Command>>>,
    events: Arc<SharedEvents>,
    buffered_frames: Arc<AtomicU64>,
    callback_underruns: Arc<AtomicU64>,
    output_rebuilds: Arc<AtomicU64>,
    output_xruns: Arc<AtomicU64>,
    /// Peak absolute sample the output callback actually wrote, as f32 bits.
    /// `0.0` means the callback is being fed silence — which distinguishes
    /// "the ring is empty/quiet" from "the stream is not reaching the speaker".
    output_peak: Arc<AtomicU32>,
    position_ms: Arc<AtomicU64>,
    duration_ms: Arc<AtomicU64>,
    volume_bits: Arc<AtomicU32>,
    flush_ring: Arc<AtomicBool>,
    bail_flush: Arc<AtomicBool>,
    /// When set, the device callback outputs silence immediately — pause must
    /// not wait for the mixer to drain ~2 s of already-queued samples.
    output_paused: Arc<AtomicBool>,
    started: AtomicBool,
    stream: Arc<Mutex<Option<cpal::Stream>>>,
    rebuilding: Arc<AtomicBool>,
    output_rate: Arc<AtomicU32>,
    output_channels: Arc<AtomicU32>,
    /// The format the host platform asked for, `0` meaning "no opinion". iOS
    /// knows the hardware format because the `AVAudioSession` owns it there, and
    /// cpal's own answer is the RemoteIO unit's opinion of the same thing; when
    /// the two disagree the unit can fail to start without an error worth
    /// reading. macOS has no such owner, so it leaves these at `0` and cpal's
    /// device choice stands.
    requested_rate: Arc<AtomicU32>,
    requested_channels: Arc<AtomicU32>,
    /// The name of the device the output was last opened on, for the audio
    /// pipeline readout. Empty until a stream is built. `Mutex` rather than an
    /// atomic because a device name is a `String` and there is no reason to
    /// pretend otherwise; the panel reads it, nothing writes it in a loop.
    device_name: Arc<Mutex<String>>,
    nerd: Arc<Mutex<mixer::NerdSnapshot>>,
    /// Requested PCM word length (0 = PCM_16, 1 = FLOAT_32). Read when a
    /// stream is (re)built; changing it rebuilds the unit.
    pcm_mode: Arc<AtomicU32>,
    /// Prefer a USB audio device over the system default (upstream
    /// `preferUsbDac`). Advisory on iOS, where the session owns the route;
    /// a real device choice on macOS.
    prefer_usb: Arc<AtomicBool>,
    /// Loudness-normalization master switch (upstream
    /// `loudnessNormalization`, on by default).
    loudness_enabled: Arc<AtomicBool>,
    /// Automix analysis tier (EFFICIENT / BALANCED / PERFORMANCE). Read when
    /// a plan is computed; no rebuild involved.
    automix_tier: Arc<Mutex<AutomixTier>>,
    /// The output control built at `start`, retained so later setting changes
    /// (PCM mode, route preference) can ask for the same rebuild a route
    /// change gets.
    control: Mutex<Option<OutputControl>>,
}

/// What the engine actually opened, for the audio pipeline readout.
///
/// A snapshot rather than a live query: the answer changes only when the route
/// does, and the readout is a panel the listener opens to look at, not a
/// dashboard polling a device. `started` is separate from the format because
/// "nothing is open yet" and "something is open" are the two states worth
/// telling apart — the first means the panel is empty for a reason, and the
/// second means every row below it is real.
/// Requested PCM word length at the output boundary.
///
/// Upstream's `OutputPcmMode`, minus the 24-bit rung: Media3's sink chain has
/// no packed-24 path (its own comment says so), and neither does this one —
/// CoreAudio converts whatever the unit is opened as, so a 24-bit request
/// would name a depth that was never written. PCM_16 opens the unit as int16
/// (quantized at the callback); FLOAT_32 is the lossless path and the mix
/// format throughout.
#[derive(uniffi::Enum, Clone, Copy, Debug, PartialEq, Eq)]
pub enum OutputPcmMode {
    Pcm16,
    Float32,
}

impl OutputPcmMode {
    /// Stored settings predate this enum and one of them names a rung that
    /// never existed here — both fall back to the lossless path rather than
    /// the lossy one, because a wrong default should cost nothing audible.
    fn parse(mode: &str) -> Self {
        match mode {
            "FLOAT_32" | "PCM_24" => OutputPcmMode::Float32,
            _ => OutputPcmMode::Pcm16,
        }
    }

    fn label(self) -> &'static str {
        match self {
            OutputPcmMode::Pcm16 => "PCM_16",
            OutputPcmMode::Float32 => "FLOAT_32",
        }
    }
}

/// CPU budget for Automix analysis (upstream `AutomixPerformanceMode`).
///
/// rten runs single-threaded — there is no intra-op pool to resize, so the
/// thread counts (1 / 2 / 4) have no knob here. What the tier does control is
/// how much analysis runs at all: EFFICIENT skips the open-unmix vocal model
/// (the expensive half) and plans from the beat grid plus energy, which is
/// upstream's own "yields to decoding and playback" in effect if not in
/// mechanism. BALANCED and PERFORMANCE both run the full graphs.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum AutomixTier {
    Efficient,
    Balanced,
    Performance,
}

impl AutomixTier {
    fn parse(mode: &str) -> Self {
        match mode {
            "EFFICIENT" => AutomixTier::Efficient,
            "PERFORMANCE" => AutomixTier::Performance,
            _ => AutomixTier::Balanced,
        }
    }

    /// Whether the vocal-separation model runs for this plan.
    fn runs_vocal_model(self) -> bool {
        self != AutomixTier::Efficient
    }

    /// Label for the plan log, so a transition can be traced back to the tier
    /// that produced it.
    fn name(self) -> &'static str {
        match self {
            AutomixTier::Efficient => "EFFICIENT",
            AutomixTier::Balanced => "BALANCED",
            AutomixTier::Performance => "PERFORMANCE",
        }
    }
}

#[derive(uniffi::Record, Debug, Clone)]
pub struct OutputDeviceRec {
    pub name: String,
    pub sample_rate: u32,
    pub channels: u32,
    pub started: bool,
    /// Word length the unit was actually opened as (`PCM_16` = int16 stream,
    /// `FLOAT_32` = float). The setting is the request; this is the answer.
    pub sample_format: String,
}

/// Monotonic output counters for a device playback trace. Compare deltas while
/// a track is playing; the output callback also runs while the queue is idle.
#[derive(uniffi::Record, Debug, Clone)]
pub struct OutputHealthRec {
    pub buffered_frames: u64,
    pub callback_underruns: u64,
    pub output_rebuilds: u64,
    pub output_xruns: u64,
    /// Peak absolute sample the device callback last wrote (0.0 = silence).
    pub output_peak: f32,
}

#[uniffi::export]
impl PlayerEngine {
    #[uniffi::constructor]
    pub fn new() -> Arc<Self> {
        let (tx, rx) = crossbeam_channel::unbounded::<Command>();
        Arc::new(Self {
            commands: tx,
            command_rx: Mutex::new(Some(rx)),
            events: Arc::new(SharedEvents::default()),
            buffered_frames: Arc::new(AtomicU64::new(0)),
            callback_underruns: Arc::new(AtomicU64::new(0)),
            output_rebuilds: Arc::new(AtomicU64::new(0)),
            output_xruns: Arc::new(AtomicU64::new(0)),
            output_peak: Arc::new(AtomicU32::new(0.0f32.to_bits())),
            position_ms: Arc::new(AtomicU64::new(0)),
            duration_ms: Arc::new(AtomicU64::new(0)),
            volume_bits: Arc::new(AtomicU32::new(1.0f32.to_bits())),
            flush_ring: Arc::new(AtomicBool::new(false)),
            bail_flush: Arc::new(AtomicBool::new(false)),
            output_paused: Arc::new(AtomicBool::new(false)),
            started: AtomicBool::new(false),
            stream: Arc::new(Mutex::new(None)),
            rebuilding: Arc::new(AtomicBool::new(false)),
            output_rate: Arc::new(AtomicU32::new(0)),
            output_channels: Arc::new(AtomicU32::new(2)),
            requested_rate: Arc::new(AtomicU32::new(0)),
            requested_channels: Arc::new(AtomicU32::new(0)),
            device_name: Arc::new(Mutex::new(String::new())),
            nerd: Arc::new(Mutex::new(mixer::NerdSnapshot::default())),
            pcm_mode: Arc::new(AtomicU32::new(if cfg!(target_os = "ios") { 1 } else { 0 })),
            prefer_usb: Arc::new(AtomicBool::new(false)),
            loudness_enabled: Arc::new(AtomicBool::new(true)),
            automix_tier: Arc::new(Mutex::new(AutomixTier::Balanced)),
            control: Mutex::new(None),
        })
    }

    pub fn register_callback(&self, callback: Box<dyn EngineCallback>) {
        *self.events.inner.lock().unwrap() = Some(CallbackHolder(Arc::from(callback)));
    }

    /// Opens the output device and starts the mixer thread.
    ///
    /// `rate` and `channels` are the host platform's own figures when it has
    /// them — iOS reads them off the `AVAudioSession`, which owns the hardware
    /// format there, and passes them in so the audio unit and the session agree
    /// by construction. `None` asks cpal, which is the only answer available
    /// everywhere else.
    pub fn start(&self, rate: Option<f64>, channels: Option<u32>) -> Result<(), EngineError> {
        let _ = env_logger::Builder::from_env(env_logger::Env::default().default_filter_or("info"))
            .try_init();
        if self.started.swap(true, Ordering::SeqCst) {
            return Ok(());
        }
        let host = cpal::default_host();
        let Some(device) = pick_output_device(&host, self.prefer_usb.load(Ordering::Relaxed)) else {
            self.started.store(false, Ordering::Release);
            return Err(EngineError::NoOutputDevice);
        };
        // Remember the platform's request before asking cpal, so a later
        // rebuild (route change) resolves the same way the first start did.
        if let Some(r) = rate.filter(|r| *r > 0.0) {
            self.requested_rate.store(r as u32, Ordering::Relaxed);
        }
        if let Some(c) = channels.filter(|c| *c > 0) {
            self.requested_channels.store(c, Ordering::Relaxed);
        }
        let supported = match device.default_output_config() {
            Ok(config) => config,
            Err(e) => {
                self.started.store(false, Ordering::Release);
                return Err(EngineError::StreamInit(e.to_string()));
            }
        };
        let (sample_rate, channels) = choose_format(
            &self.requested_rate,
            &self.requested_channels,
            supported.sample_rate(),
            supported.channels() as usize,
        );
        self.output_rate.store(sample_rate, Ordering::Relaxed);
        self.output_channels.store(channels as u32, Ordering::Relaxed);
        // The device's own name, because "no sound" is otherwise indistinguishable
        // from "the wrong output". A machine with no real sink (a VM, a session
        // with nothing plugged in) resolves to a null device that drains as fast
        // as the callback fires, which looks exactly like a mixer running far too
        // fast — so the name is what tells those two apart.
        *self.device_name.lock().unwrap() = device.to_string();
        log::info!(
            "output {device} — {sample_rate} Hz, {channels} ch"
        );

        // ~2 s of stereo at 192 kHz — big enough that a 24 kHz AirPods
        // rebuild can reuse the same capacity without shrinking.
        let ring_cap = (sample_rate.max(192_000) as usize) * 2 * 2;
        let (producer, consumer) = rtrb::RingBuffer::<f32>::new(ring_cap);
        let rx = self
            .command_rx
            .lock()
            .unwrap()
            .take()
            .ok_or(EngineError::NotStarted)?;
        let buffered = self.buffered_frames.clone();
        let position = self.position_ms.clone();
        let duration = self.duration_ms.clone();
        let events = self.events.clone();
        let shutdown = Arc::new(AtomicBool::new(false));
        let mixer_flush = self.flush_ring.clone();
        let mixer_bail = self.bail_flush.clone();
        let nerd = self.nerd.clone();

        std::thread::Builder::new()
            .name("native-core-mixer".into())
            .spawn(move || {
                qos::raise_current_thread();
                mixer::run_mixer(
                    rx,
                    producer,
                    buffered,
                    position,
                    duration,
                    sample_rate,
                    events,
                    shutdown,
                    mixer_flush,
                    mixer_bail,
                    nerd,
                )
            })
            .map_err(|e| EngineError::StreamInit(e.to_string()))?;

        let control = OutputControl {
            commands: self.commands.clone(),
            stream: self.stream.clone(),
            rebuilding: self.rebuilding.clone(),
            rebuild_forced: Arc::new(AtomicBool::new(false)),
            output_rate: self.output_rate.clone(),
            output_channels: self.output_channels.clone(),
            requested_rate: self.requested_rate.clone(),
            requested_channels: self.requested_channels.clone(),
            device_name: self.device_name.clone(),
            volume_bits: self.volume_bits.clone(),
            buffered: self.buffered_frames.clone(),
            callback_underruns: self.callback_underruns.clone(),
            output_rebuilds: self.output_rebuilds.clone(),
            output_xruns: self.output_xruns.clone(),
            output_peak: self.output_peak.clone(),
            flush_ring: self.flush_ring.clone(),
            bail_flush: self.bail_flush.clone(),
            output_paused: self.output_paused.clone(),
            pcm_mode: self.pcm_mode.clone(),
            prefer_usb: self.prefer_usb.clone(),
        };
        let pcm16 = self.pcm_mode.load(Ordering::Relaxed) == 0;
        let stream = open_output_stream(&device, sample_rate, channels, pcm16, consumer, &control)?;
        stream
            .play()
            .map_err(|e| EngineError::StreamInit(e.to_string()))?;
        *self.stream.lock().unwrap() = Some(stream);
        *self.control.lock().unwrap() = Some(control);
        Ok(())
    }

    pub fn load_track(&self, request: LoadRequest) -> Result<TrackInfoRec, EngineError> {
        self.output_paused.store(false, Ordering::Release);
        let (reply_tx, reply_rx) = crossbeam_channel::bounded::<Result<TrackInfo, String>>(1);
        self.send(Command::Load {
            request: to_track_source(request),
            reply: reply_tx,
        })?;
        match reply_rx.recv_timeout(std::time::Duration::from_secs(30)) {
            Ok(Ok(info)) => Ok(info_to_rec(info)),
            Ok(Err(e)) => Err(EngineError::LoadFailed(e)),
            Err(_) => Err(EngineError::LoadFailed("load timed out".into())),
        }
    }

    /// Replaces the playing source with a better one for the same recording,
    /// crossfading into it — upstream `swapCurrentToVersion`. The replacement
    /// opens at the engine's own position rather than `request.start_seconds`:
    /// the caller only knows the audible playhead, which trails the decoder by
    /// the whole output ring, and a crossfade between two copies of the same
    /// audio is only inaudible while they are aligned.
    pub fn swap_source(
        &self,
        request: LoadRequest,
        crossfade_seconds: f64,
    ) -> Result<TrackInfoRec, EngineError> {
        let (reply_tx, reply_rx) = crossbeam_channel::bounded::<Result<TrackInfo, String>>(1);
        self.send(Command::SwapSource {
            request: to_track_source(request),
            crossfade_seconds,
            reply: reply_tx,
        })?;
        match reply_rx.recv_timeout(std::time::Duration::from_secs(30)) {
            Ok(Ok(info)) => Ok(info_to_rec(info)),
            Ok(Err(e)) => Err(EngineError::LoadFailed(e)),
            Err(_) => Err(EngineError::LoadFailed("swap timed out".into())),
        }
    }

    pub fn next_energy_dip(&self, source: String, position_seconds: f64) -> Option<f64> {
        analyzer::next_energy_dip(&source, position_seconds)
    }

    pub fn queue_next(&self, request: LoadRequest) -> Result<(), EngineError> {
        self.send(Command::QueueNext { request: to_track_source(request) })
    }

    pub fn play(&self) -> Result<(), EngineError> {
        self.output_paused.store(false, Ordering::Release);
        self.send(Command::Play)
    }

    pub fn pause(&self) -> Result<(), EngineError> {
        self.output_paused.store(true, Ordering::Release);
        self.send(Command::Pause)
    }

    pub fn stop(&self) -> Result<(), EngineError> {
        self.bail_flush.store(true, Ordering::Release);
        self.send(Command::Stop)
    }

    /// Moves the playhead. Returns as soon as the request is queued.
    ///
    /// It does not wait for the mixer to apply it, and deliberately so. This is
    /// called straight from a lyric-line tap on the main thread, and waiting
    /// there put a user-interactive thread behind a default-QoS mixer for up to
    /// fifteen seconds — Thread Performance Checker named it, and the UI stall it
    /// caused was the "navigating stutters the song" half of the report. Every
    /// player upstream is asynchronous here too. A refusal comes back as an
    /// error event; the position readout reconciles from the playhead on the
    /// next tick either way.
    pub fn seek(&self, seconds: f64) {
        if self
            .send(Command::Seek {
                seconds: seconds.max(0.0),
            })
            .is_err()
        {
            log::warn!("seek dropped — engine not started");
        }
    }

    /// What the output is, for the audio pipeline panel. Reports `started:
    /// false` before the first stream is built rather than inventing a device.
    pub fn output_device(&self) -> OutputDeviceRec {
        let format = if self.pcm_mode.load(Ordering::Relaxed) == 0 && !cfg!(target_os = "ios") {
            "PCM_16"
        } else {
            "FLOAT_32"
        };
        OutputDeviceRec {
            name: self.device_name.lock().unwrap().clone(),
            sample_rate: self.output_rate.load(Ordering::Relaxed),
            channels: self.output_channels.load(Ordering::Relaxed),
            started: self.started.load(Ordering::Relaxed)
                && self.output_rate.load(Ordering::Relaxed) > 0,
            sample_format: format.to_string(),
        }
    }

    pub fn output_health(&self) -> OutputHealthRec {
        OutputHealthRec {
            buffered_frames: self.buffered_frames.load(Ordering::Relaxed),
            callback_underruns: self.callback_underruns.load(Ordering::Relaxed),
            output_rebuilds: self.output_rebuilds.load(Ordering::Relaxed),
            output_xruns: self.output_xruns.load(Ordering::Relaxed),
            output_peak: f32::from_bits(self.output_peak.load(Ordering::Relaxed)),
        }
    }

    /// Re-opens the output stream on whatever route is current now.
    ///
    /// The app calls this after a route change or an interruption, because it
    /// owns the `AVAudioSession` and is the only side that can re-activate it:
    /// a RemoteIO unit built while the session is down is never pulled by the
    /// audio daemon, which looks exactly like a mixer with nothing to say.
    /// `force` skips the reuse check — see `on_stream_error` for why a route
    /// change can never be detected by that check on iOS.
    pub fn request_output_rebuild(&self, force: bool) -> Result<(), EngineError> {
        let control = self.control.lock().unwrap().clone();
        match control {
            Some(control) => {
                control.request_rebuild(force);
                Ok(())
            }
            None => Err(EngineError::NotStarted),
        }
    }

    pub fn position_seconds(&self) -> f64 {
        self.position_ms.load(Ordering::Relaxed) as f64 / 1000.0
    }

    pub fn duration_seconds(&self) -> f64 {
        self.duration_ms.load(Ordering::Relaxed) as f64 / 1000.0
    }

    pub fn set_volume(&self, gain: f32) {
        self.volume_bits
            .store(gain.clamp(0.0, 1.0).to_bits(), Ordering::Relaxed);
        let _ = self.commands.send(Command::SetVolume(gain.clamp(0.0, 1.0)));
    }

    pub fn set_crossfade_window(&self, seconds: f64) -> Result<(), EngineError> {
        self.send(Command::SetCrossfadeWindow(seconds))
    }

    pub fn set_spatial_enabled(&self, enabled: bool) -> Result<(), EngineError> {
        self.send(Command::SetSpatial(enabled))
    }

    /// Head yaw, normalized −1..1 (iOS `HeadTracker` feeds this; macOS passes 0).
    pub fn set_head_rotation(&self, yaw: f32) -> Result<(), EngineError> {
        self.send(Command::SetHeadYaw(yaw))
    }

    pub fn set_voice_filter(&self, incoming: bool, low_hz: f32, high_hz: f32) -> Result<(), EngineError> {
        self.send(Command::SetVoiceFilter { incoming, low_hz, high_hz })
    }

    pub fn open_transition_filters(&self) -> Result<(), EngineError> {
        self.send(Command::OpenFilters)
    }

    pub fn set_playback_speed(&self, speed: f32) -> Result<(), EngineError> {
        self.send(Command::SetPlaybackSpeed(speed.clamp(0.5, 2.0)))
    }

    pub fn set_skip_silence(&self, enabled: bool) -> Result<(), EngineError> {
        self.send(Command::SetSkipSilence(enabled))
    }

    /// Sets the equaliser tuning (upstream `EqualizerProcessor.setTuning`).
    ///
    /// `gains_db` and `qs` are the ten-slot [`crate::eq::EqLayout`] values —
    /// slots 0..6 the manual tab (low shelf at 60 Hz, high shelf at 14 kHz,
    /// bells between), slots 7..9 the tone pad (250 Hz shelf, 1 kHz bell,
    /// 4 kHz shelf). The make-up preamp is computed here, once, from the
    /// summed response so the audio thread never walks it. `balance` is the
    /// −1..1 output trim (ignored for mono). `enabled = false` is a flat curve
    /// and centred balance — it glides down rather than cutting out.
    pub fn set_eq_tuning(
        &self,
        enabled: bool,
        gains_db: Vec<f32>,
        qs: Vec<f32>,
        balance: f32,
    ) -> Result<(), EngineError> {
        let curve = crate::eq::EqCurve::of(&gains_db, &qs);
        self.send(Command::SetEqTuning {
            enabled,
            gains_db: curve.gains_db,
            qs: curve.qs,
            preamp_db: curve.preamp_db,
            balance,
        })
    }

    /// Requested PCM word length (`PCM_16` / `FLOAT_32`; a stored `PCM_24`
    /// from before the rung was removed maps to the lossless path). The unit
    /// is rebuilt when the answer differs — same rebuild a route change gets,
    /// so a toggle mid-track never cuts the blend.
    pub fn set_output_pcm_mode(&self, mode: String) -> Result<(), EngineError> {
        let parsed = OutputPcmMode::parse(&mode);
        let code = match parsed {
            OutputPcmMode::Pcm16 => 0,
            OutputPcmMode::Float32 => 1,
        };
        if self.pcm_mode.swap(code, Ordering::Relaxed) == code {
            return Ok(());
        }
        log::info!("output PCM mode -> {}", parsed.label());
        if let Some(control) = self.control.lock().unwrap().clone() {
            control.request_rebuild(true);
        }
        Ok(())
    }

    /// Prefer a USB DAC over the system default. Takes effect through the
    /// same rebuild path: the next device pick prefers the USB match, and the
    /// name check forces the swap even at an identical format.
    pub fn set_prefer_usb_dac(&self, enabled: bool) -> Result<(), EngineError> {
        if self.prefer_usb.swap(enabled, Ordering::Relaxed) == enabled {
            return Ok(());
        }
        if let Some(control) = self.control.lock().unwrap().clone() {
            control.request_rebuild(false);
        }
        Ok(())
    }

    /// Loudness-normalization master switch. No reload: the render reads the
    /// flag per chunk and the readout follows it.
    pub fn set_loudness_enabled(&self, enabled: bool) -> Result<(), EngineError> {
        self.loudness_enabled.store(enabled, Ordering::Relaxed);
        self.send(Command::SetLoudnessEnabled(enabled))
    }

    /// Automix analysis tier (`EFFICIENT` / `BALANCED` / `PERFORMANCE`). Read
    /// when a plan is computed; EFFICIENT skips the vocal model.
    pub fn set_automix_performance(&self, mode: String) {
        *self.automix_tier.lock().unwrap() = AutomixTier::parse(&mode);
    }

    pub fn nerd_stats(&self) -> NerdStatsRec {
        let snap = self.nerd.lock().unwrap().clone();
        NerdStatsRec {
            codec: snap.codec,
            sample_rate: snap.sample_rate,
            bit_depth: snap.bit_depth,
            channels: snap.channels,
            kbps: snap.kbps,
            loudness_gain_db: snap.loudness_gain_db,
            swap_correlation: snap.swap_correlation,
        }
    }

    // ---- Analysis entry points (spec §2, §1.3) -----------------------------

    /// Seek-bounded region decode — the contract upstream's `AudioDecoder`
    /// documents and `TrackAnalyzer` depends on: float PCM + sample rate +
    /// effective start, mono or stereo variant, null on failure.
    pub fn decode_region(
        &self,
        source: String,
        start_seconds: f64,
        duration_seconds: f64,
        mono: bool,
    ) -> Option<DecodedRegion> {
        decode_region_impl(&source, start_seconds, duration_seconds, mono).ok()
    }

    /// `ComputeBeatSpectrogram` over pre-resampled 22.05 kHz input.
    pub fn mel_spectrogram(&self, samples: Vec<f32>, sample_rate: f64) -> MelSpectrogramResult {
        let BeatSpectrogram { frames, values } =
            analyzer::compute_beat_spectrogram(&samples, sample_rate);
        MelSpectrogramResult {
            frames: frames as u64,
            mels: analyzer::BEAT_SPECTROGRAM_MELS as u64,
            values,
        }
    }

    /// Offline `Resample()` port (analysis path; playback resamples inline).
    pub fn resample_audio(&self, samples: Vec<f32>, input_rate: f64, output_rate: f64) -> Vec<f32> {
        analyzer::resample(&samples, input_rate, output_rate)
    }

    /// True once Beat This! loaded. Energy-based tempo planning still works
    /// without it — Automix falls back to a plain fade, matching upstream.
    pub fn analyzer_available(&self) -> bool {
        analyzer::analyzer_ready()
    }

    /// Plan an Automix transition from two local files (Beat This! + open-unmix
    /// when models are configured, energy/tempo otherwise). `outgoing_text` /
    /// `incoming_text` are the "title artist album" strings the speech/live
    /// guard reads.
    pub fn plan_automix(
        &self,
        outgoing_path: String,
        incoming_path: String,
        outgoing_text: String,
        incoming_text: String,
        album_sequential: bool,
        crossfade_seconds: f64,
    ) -> TransitionPlanRec {
        let tier = *self.automix_tier.lock().unwrap();
        plan_automix_impl_with_tier(
            &outgoing_path,
            &incoming_path,
            &outgoing_text,
            &incoming_text,
            album_sequential,
            crossfade_seconds,
            tier,
        )
    }
}

impl PlayerEngine {
    fn send(&self, cmd: Command) -> Result<(), EngineError> {
        self.commands
            .send(cmd)
            .map_err(|_| EngineError::NotStarted)
    }
}

#[derive(Clone)]
struct OutputControl {
    commands: crossbeam_channel::Sender<Command>,
    stream: Arc<Mutex<Option<cpal::Stream>>>,
    rebuilding: Arc<AtomicBool>,
    /// A forced rebuild arrived while one was already running. The worker
    /// re-runs for it rather than dropping it — see `request_rebuild`.
    rebuild_forced: Arc<AtomicBool>,
    output_rate: Arc<AtomicU32>,
    output_channels: Arc<AtomicU32>,
    requested_rate: Arc<AtomicU32>,
    requested_channels: Arc<AtomicU32>,
    device_name: Arc<Mutex<String>>,
    volume_bits: Arc<AtomicU32>,
    buffered: Arc<AtomicU64>,
    callback_underruns: Arc<AtomicU64>,
    output_rebuilds: Arc<AtomicU64>,
    output_xruns: Arc<AtomicU64>,
    output_peak: Arc<AtomicU32>,
    flush_ring: Arc<AtomicBool>,
    bail_flush: Arc<AtomicBool>,
    output_paused: Arc<AtomicBool>,
    pcm_mode: Arc<AtomicU32>,
    prefer_usb: Arc<AtomicBool>,
}

impl OutputControl {
    fn on_stream_error(&self, err: cpal::Error) {
        match err.kind() {
            ErrorKind::DeviceChanged => {
                // The route moved, and this has to force the rebuild. The
                // "is the existing stream still good?" comparison inside
                // `rebuild` cannot see a route change on iOS: cpal reports one
                // singleton "Default Device", so the name never changes, and
                // `choose_format` returns the AVAudioSession's own rate and
                // channel count because the app pins them, so those never
                // change either. Every term of that test is therefore true, and
                // a non-forced rebuild returned Ok having done nothing — which
                // is how unplugging AirPods left a stream whose device had
                // gone: silence, never recovered, with the mixer filling a ring
                // that nothing drains.
                log::info!("output route changed: {err}");
                self.request_rebuild(true);
            }
            ErrorKind::StreamInvalidated => {
                log::info!("output stream invalidated: {err}");
                self.request_rebuild(true);
            }
            ErrorKind::DeviceNotAvailable => {
                log::info!("output device unavailable: {err}");
                self.request_rebuild(true);
            }
            ErrorKind::Xrun => {
                self.output_xruns.fetch_add(1, Ordering::Relaxed);
                log::debug!("output xrun: {err}");
            }
            other => log::warn!("output stream error ({other:?}): {err}"),
        }
    }

    fn request_rebuild(&self, force: bool) {
        if force {
            self.rebuild_forced.store(true, Ordering::Release);
        }
        if self.rebuilding.swap(true, Ordering::AcqRel) {
            // A rebuild is already in flight. A forced request must not simply
            // be dropped: it is the app saying the session is active now, and
            // the run already under way may well have built its unit before
            // that was true. The worker below re-runs for it.
            return;
        }
        // This worker owns the rebuild; the flag only had to survive the race
        // above, and leaving it set would earn a needless second pass.
        self.rebuild_forced.store(false, Ordering::Release);
        let ctrl = self.clone();
        let _ = std::thread::Builder::new()
            .name("native-core-output-rebuild".into())
            .spawn(move || {
                let mut force = force;
                loop {
                    for attempt in 0..20 {
                        std::thread::sleep(std::time::Duration::from_millis(250));
                        match ctrl.rebuild(force) {
                            Ok(()) => break,
                            Err(EngineError::NoOutputDevice) if attempt < 19 => {
                                log::info!("waiting for an output device…");
                            }
                            // Route changes can also race CoreAudio while the
                            // new unit is being created. Keep retrying
                            // transient stream setup failures; a single failed
                            // attempt must not leave the engine permanently
                            // without an output callback.
                            Err(e) if attempt < 19 => {
                                log::info!("output rebuild attempt {} failed: {e}", attempt + 1);
                            }
                            Err(e) => {
                                log::warn!("output rebuild failed: {e}");
                                break;
                            }
                        }
                    }
                    // A forced request that arrived while this ran is the app
                    // saying the session is up. Honour it before finishing, so
                    // the unit is never left built against a session that was
                    // down.
                    if !ctrl.rebuild_forced.swap(false, Ordering::AcqRel) {
                        break;
                    }
                    log::info!("re-running the output rebuild for a later route event");
                    force = true;
                }
                ctrl.rebuilding.store(false, Ordering::Release);
            });
    }

    fn rebuild(&self, force: bool) -> Result<(), EngineError> {
        let host = cpal::default_host();
        let device = pick_output_device(&host, self.prefer_usb.load(Ordering::Relaxed))
            .ok_or(EngineError::NoOutputDevice)?;
        // A route/DAC change is a *different* device even at the same format —
        // without the name check the comparison below would keep the old
        // stream on the old device.
        let device_changed = device.to_string() != *self.device_name.lock().unwrap();
        let supported = device
            .default_output_config()
            .map_err(|e| EngineError::StreamInit(e.to_string()))?;
        // The same resolution `PlayerEngine::start` applies, so a rebuild after
        // a route change cannot land on a different format than the first start.
        let (rate, channels) = choose_format(
            &self.requested_rate,
            &self.requested_channels,
            supported.sample_rate(),
            supported.channels() as usize,
        );
        let prev_rate = self.output_rate.load(Ordering::Relaxed);
        let prev_ch = self.output_channels.load(Ordering::Relaxed);
        if !force && !device_changed && rate == prev_rate && channels as u32 == prev_ch
            && self.stream.lock().unwrap().is_some()
        {
            log::info!("output still {rate} Hz / {channels} ch — keeping stream");
            return Ok(());
        }

        let cap = (rate.max(192_000) as usize) * 2 * 2;
        let (producer, consumer) = rtrb::RingBuffer::<f32>::new(cap);

        // Prove the replacement before giving anything up. Opening it first
        // means a failed attempt — a route still settling, the session not yet
        // re-activated, CoreAudio racing us — leaves the previous stream
        // exactly where it was, still draining the ring the mixer is still
        // filling. Tearing the old stream down first instead made every
        // transient failure permanent: no stream to play and a producer nothing
        // reads, so the mixer filled its ring once and then sat still for good.
        //
        // The new stream starts against an empty ring and simply outputs
        // silence until it is switched in below; the old one keeps playing real
        // audio throughout.
        let stream = open_output_stream(
            &device,
            rate,
            channels,
            self.pcm_mode.load(Ordering::Relaxed) == 0,
            consumer,
            self,
        )?;
        stream
            .play()
            .map_err(|e| EngineError::StreamInit(e.to_string()))?;

        // From here the swap cannot fail. Mute both units for the handover so
        // the outgoing ring's backlog — seconds of it — cannot double the
        // incoming audio while it drains.
        let user_paused = self.output_paused.load(Ordering::Acquire);
        self.output_paused.store(true, Ordering::Release);
        self.flush_ring.store(true, Ordering::Release);
        if self
            .commands
            .send(Command::SetOutputFormat { rate, producer })
            .is_err()
        {
            self.output_paused.store(user_paused, Ordering::Release);
            return Err(EngineError::NotStarted);
        }
        // Hand the new stream in and drop the old one, whose device has gone.
        let previous = self.stream.lock().unwrap().replace(stream);
        drop(previous);
        self.output_paused.store(user_paused, Ordering::Release);
        self.output_rate.store(rate, Ordering::Relaxed);
        self.output_channels.store(channels as u32, Ordering::Relaxed);
        // A rebuild after a route change is a *different* device, so the name
        // is re-read here rather than left as the one the first start found.
        *self.device_name.lock().unwrap() = device.to_string();
        self.output_rebuilds.fetch_add(1, Ordering::Relaxed);
        log::info!("output rebuilt: {device} — {rate} Hz, {channels} ch");
        Ok(())
    }
}

/// The format the host platform asked for, falling back to cpal's answer.
///
/// A hint of `0` means "no opinion" and takes cpal's figure. A requested
/// channel count of 1 is honoured rather than read as unset — a mono session
/// is a real configuration, and treating it as absent would hand the audio unit
/// a different channel count than the session believes it has.
/// The output device to open: the system default, unless the listener asked
/// to prefer a USB DAC and one is actually attached (upstream
/// `applyOutputRoute` / `setPreferredAudioDevice`, minus the Android routing
/// API — here the choice is which cpal device to open).
///
/// Name match rather than device id: cpal gives no stable identifier across
/// route changes, and "USB" in the product name is what every class-compliant
/// DAC reports through CoreAudio. No match falls back to the default rather
/// than failing — an absent DAC must never mean silence.
fn pick_output_device(host: &cpal::Host, prefer_usb: bool) -> Option<cpal::Device> {
    let fallback = host.default_output_device();
    if !prefer_usb {
        return fallback;
    }
    // cpal 0.18 has no `Device::name` — the human name is the `Display`
    // impl, same string the pipeline readout already reports.
    let usb = host.output_devices().ok().and_then(|mut devices| {
        devices.find(|d| d.to_string().to_lowercase().contains("usb"))
    });
    match usb {
        Some(d) => {
            log::info!("preferring USB output: {d}");
            Some(d)
        }
        None => {
            log::info!("USB DAC preferred but none attached; using system default");
            fallback
        }
    }
}

fn choose_format(
    requested_rate: &AtomicU32,
    requested_channels: &AtomicU32,
    device_rate: u32,
    device_channels: usize,
) -> (u32, usize) {
    let rate = match requested_rate.load(Ordering::Relaxed) {
        0 => device_rate,
        r => r,
    };
    let channels = match requested_channels.load(Ordering::Relaxed) {
        0 => device_channels,
        c => c as usize,
    };
    (rate.max(1), channels.max(1))
}

fn open_output_stream(
    device: &cpal::Device,
    sample_rate: u32,
    channels: usize,
    pcm16: bool,
    mut consumer: rtrb::Consumer<f32>,
    control: &OutputControl,
) -> Result<cpal::Stream, EngineError> {
    let config = cpal::StreamConfig {
        channels: channels as u16,
        sample_rate,
        buffer_size: cpal::BufferSize::Default,
    };
    let volume = control.volume_bits.clone();
    let buffered = control.buffered.clone();
    let callback_underruns = control.callback_underruns.clone();
    let output_peak = control.output_peak.clone();
    let flush_ring = control.flush_ring.clone();
    let bail_flush = control.bail_flush.clone();
    let paused = control.output_paused.clone();
    let err_ctrl = control.clone();
    // PCM_16 opens the unit as int16: the ring stays f32 throughout (mix, EQ
    // and volume all run in float, exactly as upstream's processors run before
    // the sink's conversion) and quantization happens once, at the boundary.
    // FLOAT_32 is the passthrough — the mix format is the wire format.
    //
    // On iOS CoreAudio, RemoteIO requires 32-bit float streams; CPAL's i16 path
    // fails to render to hardware or produces silence/choppy audio. Force f32 on iOS.
    let pcm16 = if cfg!(target_os = "ios") {
        false
    } else {
        pcm16
    };
    if pcm16 {
        let mut scratch: Vec<f32> = Vec::new();
        let mut bail_ramp = BailRamp {
            buffer: Vec::with_capacity((sample_rate as usize * 120 / 1000) * 2),
            cursor: 0,
            total_frames: 0,
        };
        device
            .build_output_stream(
                config,
                move |data: &mut [i16], _| {
                    if scratch.len() < data.len() {
                        scratch.resize(data.len(), 0.0);
                    }
                    let frames = &mut scratch[..data.len()];
                    render_f32(
                        &mut consumer,
                        &volume,
                        &buffered,
                        &callback_underruns,
                        &output_peak,
                        &flush_ring,
                        &bail_flush,
                        &paused,
                        &mut bail_ramp,
                        sample_rate,
                        channels,
                        frames,
                    );
                    for (out, s) in data.iter_mut().zip(frames.iter()) {
                        *out = clamp16_from_float(*s);
                    }
                },
                move |err| err_ctrl.on_stream_error(err),
                None,
            )
            .map_err(|e| EngineError::StreamInit(e.to_string()))
    } else {
        let mut bail_ramp = BailRamp {
            buffer: Vec::with_capacity((sample_rate as usize * 120 / 1000) * 2),
            cursor: 0,
            total_frames: 0,
        };
        device
            .build_output_stream(
                config,
                move |data: &mut [f32], _| {
                    render_f32(
                        &mut consumer,
                        &volume,
                        &buffered,
                        &callback_underruns,
                        &output_peak,
                        &flush_ring,
                        &bail_flush,
                        &paused,
                        &mut bail_ramp,
                        sample_rate,
                        channels,
                        data,
                    );
                },
                move |err| err_ctrl.on_stream_error(err),
                None,
            )
            .map_err(|e| EngineError::StreamInit(e.to_string()))
    }
}

/// Quantizes a normalized f32 to signed 16-bit, matching upstream
/// `PcmBoundary.clamp16FromFloat` exactly: scale by 32768 (asymmetric full
/// scale, so −1.0 → −32768 and +1.0 → +32767), and Java `Math.round`'s
/// half-toward-positive-infinity rounding rather than Rust's half-away-from-zero.
fn clamp16_from_float(f: f32) -> i16 {
    if f.is_nan() {
        return 0;
    }
    let scaled = f * 32768.0f32;
    if scaled <= -32768.0 {
        return i16::MIN;
    }
    if scaled >= 32767.0 {
        return i16::MAX;
    }
    (scaled + 0.5).floor() as i16
}

#[derive(Default)]
struct BailRamp {
    buffer: Vec<f32>,
    cursor: usize,
    total_frames: usize,
}

/// Drains the mixer's ring into `data`: volume applied, underruns zero-filled,
/// leftover-ring flush, 120 ms deferred bail ramp-out, and pause-silence handled.
/// The one render path both output formats share — the word length is a property
/// of the unit, not of the mix.
#[allow(clippy::too_many_arguments)]
fn render_f32(
    consumer: &mut rtrb::Consumer<f32>,
    volume: &Arc<AtomicU32>,
    buffered: &Arc<AtomicU64>,
    callback_underruns: &Arc<AtomicU64>,
    output_peak: &Arc<AtomicU32>,
    flush_ring: &Arc<AtomicBool>,
    bail_flush: &Arc<AtomicBool>,
    paused: &Arc<AtomicBool>,
    bail_ramp: &mut BailRamp,
    sample_rate: u32,
    channels: usize,
    data: &mut [f32],
) {
    if flush_ring.swap(false, Ordering::AcqRel) {
        bail_ramp.buffer.clear();
        bail_ramp.cursor = 0;
        bail_ramp.total_frames = 0;
        while consumer.pop().is_ok() {}
        buffered.store(0, Ordering::Relaxed);
    }
    if bail_flush.swap(false, Ordering::AcqRel) {
        // 120 ms ramp-down (matching upstream BAIL_MS).
        // The mixer ring always contains interleaved stereo (2 channels).
        let bail_frames = ((sample_rate as usize * 120) / 1000).max(1);
        let bail_samples = bail_frames * 2;
        bail_ramp.buffer.clear();
        bail_ramp.cursor = 0;
        for _ in 0..bail_samples {
            match consumer.pop() {
                Ok(sample) => bail_ramp.buffer.push(sample),
                Err(_) => break,
            }
        }
        bail_ramp.total_frames = (bail_ramp.buffer.len() / 2).max(1);
        // Deferred flush: discard the remaining old audio backlog in the ring,
        // so the new track can enter an empty ring without playing seconds of the old track.
        while consumer.pop().is_ok() {}
        buffered.store(0, Ordering::Relaxed);
    }
    if paused.load(Ordering::Acquire) {
        data.fill(0.0);
        output_peak.store(0.0f32.to_bits(), Ordering::Relaxed);
        return;
    }
    let vol = f32::from_bits(volume.load(Ordering::Relaxed));
    let mut underflowed = false;
    let mut pop = || {
        if bail_ramp.cursor < bail_ramp.buffer.len() {
            let sample = bail_ramp.buffer[bail_ramp.cursor];
            let frame_index = bail_ramp.cursor / 2;
            let progress = (frame_index as f64 / bail_ramp.total_frames as f64).clamp(0.0, 1.0);
            let bail_gain = (progress * core::f64::consts::PI / 2.0).cos() as f32;
            bail_ramp.cursor += 1;
            sample * bail_gain
        } else {
            match consumer.pop() {
                Ok(sample) => sample,
                Err(_) => {
                    underflowed = true;
                    0.0
                }
            }
        }
    };
    match channels {
        1 => {
            for frame in data.iter_mut() {
                let l = pop();
                let r = pop();
                *frame = (l + r) * 0.5 * vol;
            }
        }
        2 => {
            for sample in data.iter_mut() {
                *sample = pop() * vol;
            }
        }
        _ => {
            let frames = data.len() / channels;
            for frame in 0..frames {
                let l = pop();
                let r = pop();
                let base = frame * channels;
                for slot in &mut data[base..base + channels] {
                    *slot = 0.0;
                }
                data[base] = l * vol;
                data[base + 1] = r * vol;
            }
        }
    }
    // What actually left the callback. Zero here with a non-zero ring means the
    // data is silent; non-zero here with no audible output means the stream is
    // not reaching the speaker.
    let mut peak = 0.0f32;
    for sample in data.iter() {
        let magnitude = sample.abs();
        if magnitude > peak {
            peak = magnitude;
        }
    }
    output_peak.store(peak.to_bits(), Ordering::Relaxed);
    if underflowed {
        callback_underruns.fetch_add(1, Ordering::Relaxed);
    }
    let consumed = (data.len() / channels.max(1)) as u64;
    let mut current = buffered.load(Ordering::Relaxed);
    while current > 0 {
        let next = current.saturating_sub(consumed);
        match buffered.compare_exchange_weak(
            current,
            next,
            Ordering::Relaxed,
            Ordering::Relaxed,
        ) {
            Ok(_) => break,
            Err(observed) => current = observed,
        }
    }
}

fn to_track_source(request: LoadRequest) -> TrackSource {
    TrackSource {
        source: request.source,
        title: request.title,
        artist: request.artist,
        start_seconds: request.start_seconds,
        plan: request.plan.map(Into::into).unwrap_or_default(),
        headers: request.headers.unwrap_or_default(),
        claimed_kbps: request.claimed_kbps.unwrap_or(0),
        loudness_db: request.loudness_db.filter(|db| db.is_finite()),
        duration_seconds: request
            .duration_seconds
            .filter(|d| d.is_finite() && *d > 0.0)
            .unwrap_or(0.0),
    }
}

fn info_to_rec(info: TrackInfo) -> TrackInfoRec {
    TrackInfoRec {
        title: info.title,
        artist: info.artist,
        source: info.source,
        duration_seconds: info.duration_seconds,
        codec: info.codec,
        sample_rate: info.sample_rate,
        bit_depth: info.bit_depth,
        channels: info.channels,
        kbps: info.kbps,
    }
}

fn plan_automix_impl_with_tier(
    outgoing: &str,
    incoming: &str,
    outgoing_text: &str,
    incoming_text: &str,
    album_sequential: bool,
    crossfade_seconds: f64,
    tier: AutomixTier,
) -> TransitionPlanRec {
    let skip_vocals = !tier.runs_vocal_model();
    if skip_vocals {
        log::info!("automix: EFFICIENT tier — beat grid + energy, vocal model skipped");
    }
    let plan = analyzer::plan_pair(
        outgoing,
        incoming,
        outgoing_text,
        incoming_text,
        album_sequential,
        crossfade_seconds,
        skip_vocals,
        tier.name(),
        |path, start, dur, mono| {
            decode_region_impl(path, start, dur, mono)
                .ok()
                .map(|r| (r.samples, r.sample_rate, r.start_seconds))
        },
        |path| {
            metadata::read_track_metadata(path)
                .map(|m| m.duration_seconds)
                .unwrap_or(0.0)
        },
    );
    TransitionPlanRec {
        style: match plan.style {
            TransitionStyle::EqualPower => TransitionStyleRec::EqualPower,
            TransitionStyle::DjFilter => TransitionStyleRec::DjFilter,
            TransitionStyle::DjBlend => TransitionStyleRec::DjBlend,
            TransitionStyle::Gapless => TransitionStyleRec::Gapless,
        },
        bass_swap: plan.bass_swap,
        bass_swap_fraction: plan.bass_swap_fraction,
        filter_sweep: plan.filter_sweep,
        vocal_overlap: plan.vocal_overlap,
        fade_seconds: plan.fade_seconds,
        transition_end_seconds: plan.transition_end_seconds,
        cue_seconds: plan.cue_seconds,
        playback_rate: plan.playback_rate,
        bed_fraction: plan.bed_fraction,
        bed_gain_db: plan.bed_gain_db,
        dip_depth: plan.dip_depth,
        dip_width: plan.dip_width,
        post_glide_seconds: plan.post_glide_seconds,
        outgoing_duration_seconds: plan.outgoing_duration_seconds,
    }
}

/// lofty-backed metadata read for the local library scanner (spec §4).
#[uniffi::export]
pub fn read_track_metadata(path: String) -> Option<TrackMetadata> {
    metadata::read_track_metadata(&path)
}

/// Write title/artist/album/artwork onto a downloaded file.
#[uniffi::export]
pub fn write_track_tags(
    path: String,
    title: String,
    artist: String,
    album: String,
    artwork: Vec<u8>,
) -> bool {
    metadata::write_track_tags(&path, &title, &artist, &album, &artwork)
}

/// Locates the next local energy dip in the audio curve for the given source
/// within [position_seconds + 0.1, position_seconds + 2.0].
#[uniffi::export]
pub fn next_energy_dip(source: String, position_seconds: f64) -> Option<f64> {
    analyzer::next_energy_dip(&source, position_seconds)
}

/// Load Automix ONNX graphs. Paths are bundle-resolved by Swift; empty unloads.
#[uniffi::export]
pub fn configure_analyzer(beat_model_path: String, vocal_model_path: String) -> bool {
    analyzer::configure(&beat_model_path, &vocal_model_path)
}

/// Engine version for the About pane.
#[uniffi::export]
pub fn core_version() -> String {
    env!("CARGO_PKG_VERSION").to_string()
}

fn decode_region_impl(
    source: &str,
    start_seconds: f64,
    duration_seconds: f64,
    mono: bool,
) -> Result<DecodedRegion, String> {
    let kind = decode::SourceKind::parse(source);
    let empty_headers = std::collections::HashMap::new();
    // Analysis must not wait out a download. Playback still does: a plan that
    // blocks until the file is complete is a plan that arrives after the blend.
    let mut decoder = decode::SymphoniaDecoder::open_available(&kind, &empty_headers)
        .map_err(|e| e.to_string())?;
    if start_seconds > 0.0 {
        decoder.seek_seconds(start_seconds).map_err(|e| e.to_string())?;
    }
    let actual_start = decoder.position_seconds();
    let rate = decoder.sample_rate();
    let want_frames = (duration_seconds.max(0.0) * rate as f64) as usize;
    let mut samples: Vec<f32> = Vec::with_capacity(want_frames * 2);
    while samples.len() < want_frames * 2 {
        let chunk = decoder.read_stereo(4096).map_err(|e| e.to_string())?;
        if chunk.is_empty() {
            break;
        }
        samples.extend_from_slice(&chunk);
    }
    if mono {
        let mono_samples: Vec<f32> = samples
            .chunks_exact(2)
            .map(|pair| (pair[0] + pair[1]) * 0.5)
            .collect();
        return Ok(DecodedRegion {
            samples: mono_samples,
            sample_rate: rate,
            start_seconds: actual_start,
        });
    }
    Ok(DecodedRegion {
        samples,
        sample_rate: rate,
        start_seconds: actual_start,
    })
}

#[cfg(test)]
mod tests {
    use super::choose_format;
    use std::sync::atomic::AtomicU32;

    fn pick(rate: u32, channels: u32, dev_rate: u32, dev_channels: usize) -> (u32, usize) {
        choose_format(&AtomicU32::new(rate), &AtomicU32::new(channels), dev_rate, dev_channels)
    }

    #[test]
    fn no_hint_takes_cpals_figures() {
        assert_eq!(pick(0, 0, 48_000, 2), (48_000, 2));
    }

    #[test]
    fn a_platform_hint_overrides_cpals_figures() {
        // The iOS case: the session says 44.1 kHz, cpal's RemoteIO unit says
        // 48 kHz, and the session is the one that owns the hardware.
        assert_eq!(pick(44_100, 2, 48_000, 2), (44_100, 2));
    }

    #[test]
    fn a_mono_hint_is_honoured_rather_than_read_as_unset() {
        // Zero is the only "no opinion" marker. One is a real configuration,
        // and discarding it would hand the unit two channels for a session that
        // believes it has one.
        assert_eq!(pick(48_000, 1, 48_000, 2), (48_000, 1));
    }

    #[test]
    fn hints_are_resolved_independently() {
        assert_eq!(pick(44_100, 0, 48_000, 6), (44_100, 6));
        assert_eq!(pick(0, 1, 48_000, 6), (48_000, 1));
    }

    #[test]
    fn a_zero_device_figure_is_never_handed_to_cpal() {
        // Nothing should reach the unit as 0 Hz or 0 channels, whatever the
        // source of the zero. A hint of 0 means "no opinion" and falls through
        // to the device; a device that also reports 0 is floored at 1 rather
        // than passed on.
        assert_eq!(choose_format(
            &AtomicU32::new(0),
            &AtomicU32::new(0),
            0,
            0
        ), (1, 1));
        assert_eq!(choose_format(
            &AtomicU32::new(48_000),
            &AtomicU32::new(2),
            0,
            0
        ), (48_000, 2));
    }

    #[test]
    fn pcm_mode_parses_the_two_upstream_rungs() {
        use super::{AutomixTier, OutputPcmMode};
        assert_eq!(OutputPcmMode::parse("PCM_16"), OutputPcmMode::Pcm16);
        assert_eq!(OutputPcmMode::parse("FLOAT_32"), OutputPcmMode::Float32);
        // The removed PCM_24 rung and anything unknown fall to the lossless
        // path, never the lossy one.
        assert_eq!(OutputPcmMode::parse("PCM_24"), OutputPcmMode::Float32);
        assert_eq!(OutputPcmMode::parse(""), OutputPcmMode::Pcm16);
        assert_eq!(AutomixTier::parse("EFFICIENT"), AutomixTier::Efficient);
        assert_eq!(AutomixTier::parse("PERFORMANCE"), AutomixTier::Performance);
        assert_eq!(AutomixTier::parse("BALANCED"), AutomixTier::Balanced);
        assert!(!AutomixTier::Efficient.runs_vocal_model());
        assert!(AutomixTier::Balanced.runs_vocal_model());
        assert!(AutomixTier::Performance.runs_vocal_model());
    }

    #[test]
    fn loudness_correction_matches_upstream_clamps() {
        use super::mixer::loudness_gain;
        // Upstream: gainMb = round(-loudnessDb * 100) clamped to [-1500, 300].
        // A track 7 dB hot asks for -(-7) = ... precisely: gain = -loudnessDb
        // = +7 dB, clamped to +3 dB → 10^(3/20) ≈ 1.4125.
        let (gain, db) = loudness_gain(Some(-7.0), true);
        assert_eq!(db, Some(3.0));
        assert!((gain - 1.4125375).abs() < 1e-5);
        // A track 20 dB quiet asks for -20 dB, clamped to -15 dB.
        let (gain, db) = loudness_gain(Some(20.0), true);
        assert_eq!(db, Some(-15.0));
        assert!((gain - 10f32.powf(-15.0 / 20.0)).abs() < 1e-6);
        // Unity figure, switch off, missing figure, NaN: all unity, all None.
        assert_eq!(loudness_gain(Some(0.0), true), (1.0, Some(0.0)));
        assert_eq!(loudness_gain(Some(-7.0), false), (1.0, None));
        assert_eq!(loudness_gain(None, true), (1.0, None));
        assert_eq!(loudness_gain(Some(f64::NAN), true), (1.0, None));
    }

    #[test]
    fn bail_flush_ramps_output_down_over_120ms_and_flushes_backlog() {
        use super::{render_f32, BailRamp};
        use std::sync::atomic::{AtomicBool, AtomicU32, AtomicU64};
        use std::sync::Arc;

        let rate = 48_000u32;
        let channels = 2usize;
        let total_samples = (rate as usize * 2) * channels;
        let (mut producer, mut consumer) = rtrb::RingBuffer::<f32>::new(total_samples * 2);
        for _ in 0..total_samples {
            producer.push(1.0).unwrap();
        }

        let volume = Arc::new(AtomicU32::new(1.0f32.to_bits()));
        let buffered = Arc::new(AtomicU64::new((total_samples / channels) as u64));
        let underruns = Arc::new(AtomicU64::new(0));
        let peak = Arc::new(AtomicU32::new(0));
        let flush_ring = Arc::new(AtomicBool::new(false));
        let bail_flush = Arc::new(AtomicBool::new(true));
        let paused = Arc::new(AtomicBool::new(false));
        let mut bail_ramp = BailRamp {
            buffer: Vec::with_capacity((rate as usize * 120 / 1000) * 2),
            cursor: 0,
            total_frames: 0,
        };

        let chunk_size = 512;
        let mut output_samples = Vec::new();
        let total_chunks = ((rate as usize * 150 / 1000) * channels) / chunk_size;

        let mut chunk = vec![0.0f32; chunk_size];
        for _ in 0..total_chunks {
            render_f32(
                &mut consumer,
                &volume,
                &buffered,
                &underruns,
                &peak,
                &flush_ring,
                &bail_flush,
                &paused,
                &mut bail_ramp,
                rate,
                channels,
                &mut chunk,
            );
            output_samples.extend_from_slice(&chunk);
        }

        let bail_samples = (rate as usize * 120 / 1000) * 2;
        assert_eq!(bail_ramp.buffer.len(), bail_samples);
        assert!((output_samples[0] - 1.0).abs() < 1e-3);
        let mid_sample = bail_samples / 2;
        let mid_val = output_samples[mid_sample];
        assert!((mid_val - std::f32::consts::FRAC_1_SQRT_2).abs() < 0.05, "expected ~0.707 at midpoint, got {mid_val}");

        let end_sample = bail_samples - 2;
        assert!(output_samples[end_sample] < 0.05, "expected near 0.0 at end of ramp, got {}", output_samples[end_sample]);

        for (i, &s) in output_samples[bail_samples..].iter().enumerate() {
            assert_eq!(s, 0.0, "sample at +{}ms beyond bail should be silent, got {s}", (bail_samples + i) / (rate as usize * 2 / 1000));
        }

        assert!(consumer.pop().is_err());
    }
}
