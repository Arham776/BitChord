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
use mixer::{Command, EngineEvents, TrackInfo, TrackSource, TransitionPlan, TransitionStyle};

uniffi::setup_scaffolding!();

pub mod analyzer;
pub mod decode;
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
    /// Tempo stretch — reflected but not yet applied (no time-stretch engine).
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
}

#[derive(uniffi::Record, Debug, Clone)]
pub struct TrackInfoRec {
    pub title: String,
    pub artist: String,
    pub source: String,
    pub duration_seconds: f64,
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
    stream: Mutex<Option<cpal::Stream>>,
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
            stream: Mutex::new(None),
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
        let config = cpal::StreamConfig {
            channels: supported.channels(),
            sample_rate,
            buffer_size: cpal::BufferSize::Default,
        };

        // ~2 s of stereo headroom.
        let (producer, mut consumer) = rtrb::RingBuffer::<f32>::new(sample_rate as usize * 2 * 2);
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
        let flush_ring = self.flush_ring.clone();
        let mixer_flush = flush_ring.clone();
        let output_paused = self.output_paused.clone();

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
                    channels,
                    events,
                    shutdown,
                    mixer_flush,
                )
            })
            .map_err(|e| EngineError::StreamInit(e.to_string()))?;

        let volume = self.volume_bits.clone();
        let buffered = self.buffered_frames.clone();
        let paused = output_paused;
        let stream = device
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
                    // Saturating decrement: the callback can run before the
                    // producer ever fills, and a plain fetch_sub would wrap
                    // u64::MAX and wedge every tail-length computation.
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
                move |err| log::warn!("output stream error: {err}"),
                None,
            )
            .map_err(|e| EngineError::StreamInit(e.to_string()))?;
        // cpal 0.15+ builds streams in a paused state — without play() the
        // device never drains the ring and the mixer stalls on a full buffer.
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
            Ok(Ok(info)) => Ok(TrackInfoRec {
                title: info.title,
                artist: info.artist,
                source: info.source,
                duration_seconds: info.duration_seconds,
            }),
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

    /// True once ONNX inference (milestone 5, `ort`) is wired in. Until then
    /// Automix runs the unanalysed fallback: plain equal-power crossfade.
    pub fn analyzer_available(&self) -> bool {
        false
    }
}

impl PlayerEngine {
    fn send(&self, cmd: Command) -> Result<(), EngineError> {
        self.commands
            .send(cmd)
            .map_err(|_| EngineError::NotStarted)
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
    }
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
            start_seconds: decoder.position_seconds(),
        });
    }
    Ok(DecodedRegion {
        samples,
        sample_rate: rate,
        start_seconds: decoder.position_seconds(),
    })
}

/// lofty-backed metadata read for the local library scanner (spec §4).
#[uniffi::export]
pub fn read_track_metadata(path: String) -> Option<TrackMetadata> {
    metadata::read_track_metadata(&path)
}

/// Engine version for the About pane.
#[uniffi::export]
pub fn core_version() -> String {
    env!("CARGO_PKG_VERSION").to_string()
}
