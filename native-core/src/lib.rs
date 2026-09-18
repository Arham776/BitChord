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
pub mod metadata;
pub mod spatial;
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
    /// Where the incoming track is cued (Automix mix-in point). 0 = top.
    pub cue_seconds: f64,
    /// Tempo stretch — applied by the mixer via `speed_resampler`
    /// (ExoPlayer `setPlaybackSpeed` parity).
    pub playback_rate: f64,
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
            cue_seconds: rec.cue_seconds,
            playback_rate: rec.playback_rate,
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
    SeekFailed(String),
    NotStarted,
}

impl std::fmt::Display for EngineError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            EngineError::NoOutputDevice => write!(f, "no audio output device"),
            EngineError::StreamInit(e) => write!(f, "stream init failed: {e}"),
            EngineError::LoadFailed(e) => write!(f, "load failed: {e}"),
            EngineError::SeekFailed(e) => write!(f, "seek failed: {e}"),
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
    position_ms: Arc<AtomicU64>,
    duration_ms: Arc<AtomicU64>,
    volume_bits: Arc<AtomicU32>,
    flush_ring: Arc<AtomicBool>,
    /// When set, the device callback outputs silence immediately — pause must
    /// not wait for the mixer to drain ~2 s of already-queued samples.
    output_paused: Arc<AtomicBool>,
    started: AtomicBool,
    stream: Arc<Mutex<Option<cpal::Stream>>>,
    rebuilding: Arc<AtomicBool>,
    output_rate: Arc<AtomicU32>,
    output_channels: Arc<AtomicU32>,
    nerd: Arc<Mutex<mixer::NerdSnapshot>>,
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
            position_ms: Arc::new(AtomicU64::new(0)),
            duration_ms: Arc::new(AtomicU64::new(0)),
            volume_bits: Arc::new(AtomicU32::new(1.0f32.to_bits())),
            flush_ring: Arc::new(AtomicBool::new(false)),
            output_paused: Arc::new(AtomicBool::new(false)),
            started: AtomicBool::new(false),
            stream: Arc::new(Mutex::new(None)),
            rebuilding: Arc::new(AtomicBool::new(false)),
            output_rate: Arc::new(AtomicU32::new(0)),
            output_channels: Arc::new(AtomicU32::new(2)),
            nerd: Arc::new(Mutex::new(mixer::NerdSnapshot::default())),
        })
    }

    pub fn register_callback(&self, callback: Box<dyn EngineCallback>) {
        *self.events.inner.lock().unwrap() = Some(CallbackHolder(Arc::from(callback)));
    }

    /// Opens the output device and starts the mixer thread.
    pub fn start(&self) -> Result<(), EngineError> {
        let _ = env_logger::Builder::from_env(env_logger::Env::default().default_filter_or("info"))
            .try_init();
        if self.started.swap(true, Ordering::SeqCst) {
            return Ok(());
        }
        let device = cpal::default_host()
            .default_output_device()
            .ok_or(EngineError::NoOutputDevice)?;
        let supported = device
            .default_output_config()
            .map_err(|e| EngineError::StreamInit(e.to_string()))?;
        let sample_rate = supported.sample_rate();
        let channels = supported.channels() as usize;
        self.output_rate.store(sample_rate, Ordering::Relaxed);
        self.output_channels.store(channels as u32, Ordering::Relaxed);
        log::info!("output {sample_rate} Hz, {channels} ch");

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
        let nerd = self.nerd.clone();

        std::thread::Builder::new()
            .name("native-core-mixer".into())
            .spawn(move || {
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
                    nerd,
                )
            })
            .map_err(|e| EngineError::StreamInit(e.to_string()))?;

        let control = OutputControl {
            commands: self.commands.clone(),
            stream: self.stream.clone(),
            rebuilding: self.rebuilding.clone(),
            output_rate: self.output_rate.clone(),
            output_channels: self.output_channels.clone(),
            volume_bits: self.volume_bits.clone(),
            buffered: self.buffered_frames.clone(),
            flush_ring: self.flush_ring.clone(),
            output_paused: self.output_paused.clone(),
        };
        let stream = open_output_stream(&device, sample_rate, channels, consumer, &control)?;
        stream
            .play()
            .map_err(|e| EngineError::StreamInit(e.to_string()))?;
        *self.stream.lock().unwrap() = Some(stream);
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
        self.output_paused.store(true, Ordering::Release);
        self.flush_ring.store(true, Ordering::Release);
        self.send(Command::Stop)
    }

    pub fn seek(&self, seconds: f64) -> Result<(), EngineError> {
        let (reply_tx, reply_rx) = crossbeam_channel::bounded::<Result<(), String>>(1);
        self.send(Command::Seek {
            seconds: seconds.max(0.0),
            reply: reply_tx,
        })?;
        match reply_rx.recv_timeout(std::time::Duration::from_secs(15)) {
            Ok(Ok(())) => Ok(()),
            Ok(Err(e)) => Err(EngineError::SeekFailed(e)),
            Err(_) => Err(EngineError::SeekFailed("seek timed out".into())),
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

    pub fn set_eq_gains(&self, gains_db: Vec<f32>) -> Result<(), EngineError> {
        self.send(Command::SetEqGains(gains_db))
    }

    pub fn nerd_stats(&self) -> NerdStatsRec {
        let snap = self.nerd.lock().unwrap().clone();
        NerdStatsRec {
            codec: snap.codec,
            sample_rate: snap.sample_rate,
            bit_depth: snap.bit_depth,
            channels: snap.channels,
            kbps: snap.kbps,
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
    /// when models are configured, energy/tempo otherwise).
    pub fn plan_automix(
        &self,
        outgoing_path: String,
        incoming_path: String,
        crossfade_seconds: f64,
    ) -> TransitionPlanRec {
        plan_automix_impl(&outgoing_path, &incoming_path, crossfade_seconds)
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
    output_rate: Arc<AtomicU32>,
    output_channels: Arc<AtomicU32>,
    volume_bits: Arc<AtomicU32>,
    buffered: Arc<AtomicU64>,
    flush_ring: Arc<AtomicBool>,
    output_paused: Arc<AtomicBool>,
}

impl OutputControl {
    fn on_stream_error(&self, err: cpal::Error) {
        match err.kind() {
            ErrorKind::DeviceChanged => {
                log::info!("output route changed: {err}");
                self.request_rebuild(false);
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
                log::debug!("output xrun: {err}");
            }
            other => log::warn!("output stream error ({other:?}): {err}"),
        }
    }

    fn request_rebuild(&self, force: bool) {
        if self.rebuilding.swap(true, Ordering::AcqRel) {
            return;
        }
        let ctrl = self.clone();
        let _ = std::thread::Builder::new()
            .name("native-core-output-rebuild".into())
            .spawn(move || {
                for attempt in 0..20 {
                    std::thread::sleep(std::time::Duration::from_millis(250));
                    match ctrl.rebuild(force) {
                        Ok(()) => break,
                        Err(EngineError::NoOutputDevice) if attempt < 19 => {
                            log::info!("waiting for an output device…");
                        }
                        Err(e) => {
                            log::warn!("output rebuild failed: {e}");
                            break;
                        }
                    }
                }
                ctrl.rebuilding.store(false, Ordering::Release);
            });
    }

    fn rebuild(&self, force: bool) -> Result<(), EngineError> {
        let device = cpal::default_host()
            .default_output_device()
            .ok_or(EngineError::NoOutputDevice)?;
        let supported = device
            .default_output_config()
            .map_err(|e| EngineError::StreamInit(e.to_string()))?;
        let rate = supported.sample_rate();
        let channels = supported.channels() as usize;
        let prev_rate = self.output_rate.load(Ordering::Relaxed);
        let prev_ch = self.output_channels.load(Ordering::Relaxed);
        if !force && rate == prev_rate && channels as u32 == prev_ch {
            log::info!("output still {rate} Hz / {channels} ch — keeping stream");
            return Ok(());
        }

        let user_paused = self.output_paused.load(Ordering::Acquire);
        self.output_paused.store(true, Ordering::Release);
        self.flush_ring.store(true, Ordering::Release);
        // Drop the old stream so its callback/consumer die before we
        // hand the mixer a new producer.
        *self.stream.lock().unwrap() = None;

        let cap = (rate.max(192_000) as usize) * 2 * 2;
        let (producer, consumer) = rtrb::RingBuffer::<f32>::new(cap);
        self.commands
            .send(Command::SetOutputFormat { rate, producer })
            .map_err(|_| EngineError::NotStarted)?;
        self.output_rate.store(rate, Ordering::Relaxed);
        self.output_channels.store(channels as u32, Ordering::Relaxed);

        let stream = open_output_stream(&device, rate, channels, consumer, self)?;
        stream
            .play()
            .map_err(|e| EngineError::StreamInit(e.to_string()))?;
        *self.stream.lock().unwrap() = Some(stream);
        self.output_paused.store(user_paused, Ordering::Release);
        log::info!("output rebuilt: {rate} Hz, {channels} ch");
        Ok(())
    }
}

fn open_output_stream(
    device: &cpal::Device,
    sample_rate: u32,
    channels: usize,
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
    let flush_ring = control.flush_ring.clone();
    let paused = control.output_paused.clone();
    let err_ctrl = control.clone();
    device
        .build_output_stream(
            config,
            move |data: &mut [f32], _| {
                if flush_ring.swap(false, Ordering::AcqRel) {
                    while consumer.pop().is_ok() {}
                    buffered.store(0, Ordering::Relaxed);
                }
                if paused.load(Ordering::Acquire) {
                    data.fill(0.0);
                    return;
                }
                let vol = f32::from_bits(volume.load(Ordering::Relaxed));
                match channels {
                    1 => {
                        for frame in data.iter_mut() {
                            let l = consumer.pop().unwrap_or(0.0);
                            let r = consumer.pop().unwrap_or(0.0);
                            *frame = (l + r) * 0.5 * vol;
                        }
                    }
                    2 => {
                        for sample in data.iter_mut() {
                            *sample = consumer.pop().unwrap_or(0.0) * vol;
                        }
                    }
                    _ => {
                        let frames = data.len() / channels;
                        for frame in 0..frames {
                            let l = consumer.pop().unwrap_or(0.0);
                            let r = consumer.pop().unwrap_or(0.0);
                            let base = frame * channels;
                            for slot in &mut data[base..base + channels] {
                                *slot = 0.0;
                            }
                            data[base] = l * vol;
                            data[base + 1] = r * vol;
                        }
                    }
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
            },
            move |err| err_ctrl.on_stream_error(err),
            None,
        )
        .map_err(|e| EngineError::StreamInit(e.to_string()))
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

fn plan_automix_impl(outgoing: &str, incoming: &str, crossfade_seconds: f64) -> TransitionPlanRec {
    let plan = analyzer::plan_pair(
        outgoing,
        incoming,
        crossfade_seconds,
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
        cue_seconds: plan.cue_seconds,
        playback_rate: plan.playback_rate,
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
    let mut decoder = decode::SymphoniaDecoder::open(&kind, &empty_headers).map_err(|e| e.to_string())?;
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
