//! Decode (spec §3.1): symphonia-based decode pipeline and the streaming
//! `MediaSource` reader.
//!
//! Two source shapes: a local file (plain path — security-scoped bookmarks are
//! resolved by the Swift layer before reaching here) and an HTTP URL. The
//! HTTP path is `HttpMediaSource`: a background fetch thread pulls bounded
//! 1 MiB ranges (upstream `ChunkedDataSource` — unbounded googlevideo reads
//! are throttled to playback speed). A path that still has a sibling `.grow`
//! marker is a `GrowingFile`: Ktor is appending the rest of the track, and
//! reads wait at EOF until `.complete` appears. symphonia only requires a
//! `MediaSource`, so the same decoder drives both.
//!
//! Milestone-4 gate note (spec §3.4): symphonia 0.6 ships no Opus codec. The
//! app mirrors upstream's `pickAac`/`isM4a` preference so streamed playback
//! targets AAC/MP4 renditions; FLAC/MP3/ALAC/Vorbis/PCM/AIFF are covered
//! natively. Opus-in-WebM is the documented residual gap.

pub mod resampler;

use std::collections::HashMap;
use std::fs::File;
use std::io::{Read, Seek, SeekFrom};
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::sync::{Arc, Condvar, Mutex};
use std::thread::JoinHandle;
use std::time::{Duration, Instant};

use symphonia::core::audio::{Audio, Channels, GenericAudioBufferRef, Position};
use symphonia::core::codecs::audio::{AudioDecoder, AudioDecoderOptions};
use symphonia::core::codecs::CodecParameters;
use symphonia::core::errors::Error as SymphoniaError;
use symphonia::core::formats::probe::Hint;
use symphonia::core::formats::{FormatOptions, FormatReader, SeekMode, SeekTo};
use symphonia::core::io::{MediaSource, MediaSourceStream, MediaSourceStreamOptions};
use symphonia::core::meta::MetadataOptions;
use symphonia::core::units::Time;

/// Where a track's bytes come from. `Path` is used verbatim; `Url` goes
/// through [`HttpMediaSource`].
#[derive(Debug, Clone)]
pub enum SourceKind {
    Path(String),
    Url(String),
}

impl SourceKind {
    pub fn parse(source: &str) -> SourceKind {
        if source.starts_with("http://") || source.starts_with("https://") {
            SourceKind::Url(source.to_string())
        } else {
            SourceKind::Path(source.to_string())
        }
    }
}

/// Fully decoded stream state for one track.
pub struct SymphoniaDecoder {
    format: Box<dyn FormatReader>,
    decoder: Box<dyn AudioDecoder>,
    track_id: u32,
    sample_rate: u32,
    channels: usize,
    duration_secs: Option<f64>,
    decoded_frames: u64,
    /// Interleaved stereo f32 left over from the last decoded packet.
    pending: Vec<f32>,
    pending_cursor: usize,
}

#[derive(Debug)]
pub struct DecodeError(pub String);

impl std::fmt::Display for DecodeError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "{}", self.0)
    }
}

impl std::error::Error for DecodeError {}

fn open_audio_decoder(
    audio: &symphonia::core::codecs::audio::AudioCodecParameters,
) -> Result<Box<dyn AudioDecoder>, DecodeError> {
    let codecs = symphonia::default::get_codecs();
    let opts = AudioDecoderOptions::default();
    log::info!(
        "audio params extra={}B ch={:?} rate={:?} profile={:?}",
        audio.extra_data.as_ref().map(|d| d.len()).unwrap_or(0),
        audio.channels.as_ref().map(|c| c.count()),
        audio.sample_rate,
        audio.profile,
    );
    match codecs.make_audio_decoder(audio, &opts) {
        Ok(d) => return Ok(d),
        Err(e) => log::warn!("AAC decoder rejected container config: {e}"),
    }

    // YouTube itag-18 esds often advertises HE-AAC/SBR or a 960-sample frame.
    // Symphonia's AAC decoder only accepts AAC-LC, 1024 samples, ≤2 channels.
    // Rebuild a minimal LC stereo AudioSpecificConfig from the track rate.
    let rate = audio.sample_rate.unwrap_or(44_100);
    let mut stripped = audio.clone();
    stripped.extra_data = Some(lc_stereo_asc(rate).into());
    stripped.profile = None;
    stripped.channels = Some(Channels::from(Position::FRONT_LEFT | Position::FRONT_RIGHT));
    stripped.sample_rate = Some(rate);
    log::warn!("retrying as AAC-LC stereo {rate} Hz");
    codecs
        .make_audio_decoder(&stripped, &opts)
        .map_err(|e| DecodeError(format!("decoder: {e}")))
}

/// Two-byte AudioSpecificConfig: AAC-LC, stereo, 1024-sample frames.
fn lc_stereo_asc(sample_rate: u32) -> [u8; 2] {
    let freq_idx: u16 = match sample_rate {
        96_000 => 0,
        88_200 => 1,
        64_000 => 2,
        48_000 => 3,
        44_100 => 4,
        32_000 => 5,
        24_000 => 6,
        22_050 => 7,
        16_000 => 8,
        12_000 => 9,
        11_025 => 10,
        8_000 => 11,
        _ => 4,
    };
    let bits: u16 = (2 << 11) | (freq_idx << 7) | (2 << 3);
    [(bits >> 8) as u8, bits as u8]
}

impl SymphoniaDecoder {
    pub fn open(source: &SourceKind, headers: &HashMap<String, String>) -> Result<Self, DecodeError> {
        let mss: MediaSourceStream = match source {
            SourceKind::Path(path) => {
                let boxed: Box<dyn MediaSource> = if GrowingFile::is_growing(path) {
                    Box::new(
                        GrowingFile::open(path)
                            .map_err(|e| DecodeError(format!("open {path}: {e}")))?,
                    )
                } else {
                    Box::new(
                        File::open(path).map_err(|e| DecodeError(format!("open {path}: {e}")))?,
                    )
                };
                MediaSourceStream::new(boxed, MediaSourceStreamOptions::default())
            }
            SourceKind::Url(url) => {
                let http = HttpMediaSource::open(url, headers)
                    .map_err(|e| DecodeError(format!("open {url}: {e}")))?;
                MediaSourceStream::new(Box::new(http), MediaSourceStreamOptions::default())
            }
        };

        let mut hint = Hint::new();
        if let SourceKind::Path(path) = source {
            if let Some(ext) = std::path::Path::new(path).extension().and_then(|e| e.to_str()) {
                hint.with_extension(ext);
            }
        }

        let probe = symphonia::default::get_probe();
        let format = probe
            .probe(&hint, mss, FormatOptions::default(), MetadataOptions::default())
            .map_err(|e| DecodeError(format!("probe: {e}")))?;

        let track = format
            .tracks()
            .iter()
            .find(|t| {
                t.codec_params
                    .as_ref()
                    .and_then(|p| p.audio())
                    .is_some_and(|a| a.sample_rate.is_some())
            })
            .or_else(|| format.tracks().first())
            .ok_or_else(|| DecodeError("no audio track".into()))?
            .clone();

        let track_id = track.id;
        let audio_params: CodecParameters = track
            .codec_params
            .clone()
            .ok_or_else(|| DecodeError("no codec params".into()))?;
        let audio = audio_params
            .audio()
            .cloned()
            .ok_or_else(|| DecodeError("track is not audio".into()))?;
        let sample_rate = audio
            .sample_rate
            .ok_or_else(|| DecodeError("no sample rate".into()))?;
        let channels = audio.channels.as_ref().map(|c| c.count()).unwrap_or(2).max(1);
        // ISO-MP4 often has mdhd timescale ≠ sample rate (muxed itag 18), so
        // `num_frames` is left unset. Use the container duration + timebase.
        let duration_secs = match (track.time_base, track.duration) {
            (Some(tb), Some(dur)) => {
                let secs = tb.calc_duration_saturating(dur).as_secs_f64();
                if secs > 0.0 { Some(secs) } else { None }
            }
            _ => track
                .num_frames
                .filter(|&f| f > 0)
                .map(|f| f as f64 / sample_rate as f64),
        };

        let decoder = open_audio_decoder(&audio)?;

        let label = match source {
            SourceKind::Path(p) => p.rsplit('/').next().unwrap_or(p),
            SourceKind::Url(_) => "url",
        };
        log::info!(
            "opened {label}: rate={sample_rate} ch={channels} duration={duration_secs:?}s frames={:?}",
            track.num_frames
        );

        Ok(Self {
            format,
            decoder,
            track_id,
            sample_rate,
            channels,
            duration_secs,
            decoded_frames: 0,
            pending: Vec::new(),
            pending_cursor: 0,
        })
    }

    pub fn sample_rate(&self) -> u32 {
        self.sample_rate
    }

    pub fn channels(&self) -> usize {
        self.channels
    }

    /// Source-domain duration in seconds, when the container declares it.
    pub fn duration_seconds(&self) -> Option<f64> {
        self.duration_secs
    }

    /// Source-domain frames decoded since open/last seek.
    pub fn decoded_frames(&self) -> u64 {
        self.decoded_frames
    }

    /// Source-domain position in seconds.
    pub fn position_seconds(&self) -> f64 {
        self.decoded_frames as f64 / self.sample_rate as f64
    }

    /// Seeks to `seconds` in source time. Symphonia reports the actual
    /// timestamp landed on; decoded-frame counting restarts from there.
    pub fn seek_seconds(&mut self, seconds: f64) -> Result<(), DecodeError> {
        let time = Time::try_from_secs_f64(seconds.max(0.0))
            .ok_or_else(|| DecodeError("bad seek time".into()))?;
        let to = SeekTo::Time { time, track_id: Some(self.track_id) };
        match self.format.seek(SeekMode::Accurate, to) {
            Ok(seeked_to) => {
                self.decoder.reset();
                self.pending.clear();
                self.pending_cursor = 0;
                self.decoded_frames = match self.time_base() {
                    Some(tb) => tb
                        .calc_time_saturating(seeked_to.actual_ts)
                        .as_secs_f64()
                        .mul_add(self.sample_rate as f64, 0.5) as u64,
                    None => 0,
                };
                Ok(())
            }
            Err(e) => Err(DecodeError(format!("seek: {e}"))),
        }
    }

    fn time_base(&self) -> Option<symphonia::core::units::TimeBase> {
        self.format
            .tracks()
            .iter()
            .find(|t| t.id == self.track_id)
            .and_then(|t| t.time_base)
    }

    /// Reads up to `max_frames` source-domain frames as interleaved stereo
    /// f32 (mono is upmixed; >2 channels fold onto L/R). Empty slice = EOS.
    pub fn read_stereo(&mut self, max_frames: usize) -> Result<Vec<f32>, DecodeError> {
        let mut out = Vec::with_capacity(max_frames * 2);
        if self.pending_cursor < self.pending.len() {
            let take = (self.pending.len() - self.pending_cursor).min(max_frames * 2);
            out.extend_from_slice(&self.pending[self.pending_cursor..self.pending_cursor + take]);
            self.pending_cursor += take;
        }

        let mut interleaved: Vec<f32> = Vec::new();
        let mut skipped = 0u32;
        while out.len() < max_frames * 2 {
            let packet = match self.format.next_packet() {
                Ok(Some(p)) => p,
                Ok(None) => break,
                Err(SymphoniaError::IoError(ref e))
                    if e.kind() == std::io::ErrorKind::UnexpectedEof =>
                {
                    break
                }
                Err(e) => {
                    // Muxed MP4 interleaves video samples; a single bad packet
                    // must not kill the audio track.
                    log::debug!("next_packet: {e}");
                    skipped += 1;
                    if skipped > 256 {
                        break;
                    }
                    continue;
                }
            };
            if packet.track_id != self.track_id {
                continue;
            }
            let decoded = match self.decoder.decode(&packet) {
                Ok(d) => d,
                Err(SymphoniaError::DecodeError(e)) => {
                    log::debug!("decode error, skipping packet: {e}");
                    continue;
                }
                Err(e) => {
                    log::debug!("decode: {e}");
                    break;
                }
            };

            interleaved.clear();
            copy_interleaved_f32(&decoded, &mut interleaved);
            let frames = decoded.frames();
            self.decoded_frames += frames as u64;

            let ch = self.channels.max(1);
            let mut i = 0;
            while i < interleaved.len() && out.len() < max_frames * 2 {
                let l = interleaved[i];
                let r = if ch >= 2 {
                    interleaved.get(i + 1).copied().unwrap_or(l)
                } else {
                    l
                };
                out.push(l);
                out.push(r);
                i += ch;
            }
            if i < interleaved.len() {
                self.pending.clear();
                self.pending.extend_from_slice(&interleaved[i..]);
                self.pending_cursor = 0;
            }
        }
        Ok(out)
    }
}

fn copy_interleaved_f32(buffer: &GenericAudioBufferRef<'_>, dst: &mut Vec<f32>) {
    match buffer {
        GenericAudioBufferRef::F32(buf) => buf.copy_to_vec_interleaved(dst),
        GenericAudioBufferRef::F64(buf) => {
            let mut tmp: Vec<f64> = Vec::new();
            buf.copy_to_vec_interleaved(&mut tmp);
            dst.extend(tmp.iter().map(|v| *v as f32));
        }
        _ => buffer.copy_to_vec_interleaved(dst),
    }
}

// ---------------------------------------------------------------------------
// Growing file (Ktor still writing the rest)
// ---------------------------------------------------------------------------

/// A file that is still being appended to — sibling `{path}.grow` is created
/// when the first chunk lands, `{path}.complete` when the last range arrives.
/// `{path}.len` holds googlevideo `clen`.
///
/// itag-18 is faststart (moov in the first megabyte). Reporting the full
/// `clen` as a seekable length makes Symphonia's ISOMP4 demuxer seek to the
/// end before probe returns — playback waits for the whole download, which is
/// the opposite of upstream ExoPlayer (start after ~500 ms of buffer). While
/// the file is growing we look like a progressive stream: not seekable, no
/// byte length, reads wait at EOF until `.complete`.
struct GrowingFile {
    file: File,
    path: PathBuf,
    declared_len: Option<u64>,
}

impl GrowingFile {
    fn is_growing(path: &str) -> bool {
        Path::new(&format!("{path}.grow")).exists()
            && !Path::new(&format!("{path}.complete")).exists()
    }

    fn open(path: &str) -> std::io::Result<Self> {
        let declared_len = std::fs::read_to_string(format!("{path}.len"))
            .ok()
            .and_then(|s| s.trim().parse().ok())
            .filter(|n: &u64| *n > 0);
        Ok(Self {
            file: File::open(path)?,
            path: PathBuf::from(path),
            declared_len,
        })
    }

    fn is_complete(&self) -> bool {
        Path::new(&format!("{}.complete", self.path.display())).exists()
    }

    fn wait_for_len(&self, needed: u64) -> std::io::Result<()> {
        let deadline = Instant::now() + Duration::from_secs(120);
        loop {
            let len = std::fs::metadata(&self.path)?.len();
            if len >= needed {
                return Ok(());
            }
            if self.is_complete() {
                return if len >= needed {
                    Ok(())
                } else {
                    Err(std::io::Error::new(
                        std::io::ErrorKind::UnexpectedEof,
                        "growing file ended short",
                    ))
                };
            }
            if Instant::now() >= deadline {
                return Err(std::io::Error::new(
                    std::io::ErrorKind::TimedOut,
                    "timed out waiting for download",
                ));
            }
            std::thread::sleep(Duration::from_millis(8));
        }
    }
}

impl Read for GrowingFile {
    fn read(&mut self, buf: &mut [u8]) -> std::io::Result<usize> {
        loop {
            let pos = self.file.stream_position()?;
            let n = self.file.read(buf)?;
            if n > 0 {
                return Ok(n);
            }
            if self.is_complete() {
                return Ok(0);
            }
            let len = std::fs::metadata(&self.path)?.len();
            if len > pos {
                self.file.seek(SeekFrom::Start(pos))?;
                continue;
            }
            self.wait_for_len(pos + 1)?;
            self.file.seek(SeekFrom::Start(pos))?;
        }
    }
}

impl Seek for GrowingFile {
    fn seek(&mut self, pos: SeekFrom) -> std::io::Result<u64> {
        let current = self.file.stream_position()?;
        let on_disk = std::fs::metadata(&self.path).ok().map(|m| m.len()).unwrap_or(current);
        let end = if self.is_complete() {
            on_disk
        } else {
            // Progressive: End(0) is "how far have we got", not the eventual
            // clen — answering clen here is what made probe wait for the last byte.
            on_disk
        };
        let target = match pos {
            SeekFrom::Start(offset) => offset as i64,
            SeekFrom::Current(delta) => current as i64 + delta,
            SeekFrom::End(delta) => end as i64 + delta,
        };
        if target < 0 {
            return Err(std::io::Error::new(
                std::io::ErrorKind::InvalidInput,
                "negative seek",
            ));
        }
        let target = target as u64;
        self.wait_for_len(target)?;
        self.file.seek(SeekFrom::Start(target))
    }
}

impl MediaSource for GrowingFile {
    fn is_seekable(&self) -> bool {
        self.is_complete()
    }

    fn byte_len(&self) -> Option<u64> {
        if self.is_complete() {
            return std::fs::metadata(&self.path).ok().map(|m| m.len()).or(self.declared_len);
        }
        // Unknown length until the last range lands — sequential probe of the
        // first megabyte (moov) is enough to start, and Read waits for more.
        None
    }
}

// ---------------------------------------------------------------------------
// HTTP streaming source
// ---------------------------------------------------------------------------

struct StreamBuffer {
    data: Vec<u8>,
    /// File offset of `data[0]`.
    start: u64,
    read_pos: u64,
    total_len: Option<u64>,
    fetch_dead: bool,
    fetch_error: Option<String>,
}

impl StreamBuffer {
    fn end(&self) -> u64 {
        self.start + self.data.len() as u64
    }
    fn loaded(&self) -> u64 {
        self.end().saturating_sub(self.read_pos)
    }
}

struct FetchState {
    buffer: Mutex<StreamBuffer>,
    cond: Condvar,
    /// Generation counter — incremented on every range restart so a stale
    /// fetcher from a superseded request cannot keep writing.
    generation: AtomicU64,
    kill: AtomicBool,
}

/// `MediaSource` backed by a background ranged HTTP fetcher.
struct HttpMediaSource {
    url: String,
    headers: HashMap<String, String>,
    state: Arc<FetchState>,
    fetcher: Mutex<Option<JoinHandle<()>>>,
}

impl HttpMediaSource {
    fn open(url: &str, headers: &HashMap<String, String>) -> Result<Self, String> {
        let state = Arc::new(FetchState {
            buffer: Mutex::new(StreamBuffer {
                data: Vec::with_capacity(1 << 20),
                start: 0,
                read_pos: 0,
                total_len: None,
                fetch_dead: false,
                fetch_error: None,
            }),
            cond: Condvar::new(),
            generation: AtomicU64::new(0),
            kill: AtomicBool::new(false),
        });
        let source = Self {
            url: url.to_string(),
            headers: headers.clone(),
            state: state.clone(),
            fetcher: Mutex::new(None),
        };
        source.spawn_fetch(0);
        Ok(source)
    }

    fn spawn_fetch(&self, from: u64) {
        let generation = self.state.generation.fetch_add(1, Ordering::SeqCst) + 1;
        {
            let mut buf = self.state.buffer.lock().unwrap();
            buf.fetch_dead = false;
            buf.fetch_error = None;
            // Trim everything before the new fetch start.
            if from >= buf.start {
                let cut = (from - buf.start) as usize;
                let cut = cut.min(buf.data.len());
                buf.data.drain(..cut);
                buf.start = from;
            }
        }
        self.state.kill.store(false, Ordering::SeqCst);
        let url = self.url.clone();
        let headers = self.headers.clone();
        let state = self.state.clone();
        let handle = std::thread::Builder::new()
            .name("native-core-http".into())
            .spawn(move || fetch_loop(url, headers, state, from, generation))
            .expect("spawn fetch thread");
        *self.fetcher.lock().unwrap() = Some(handle);
    }
}

/// googlevideo throttles an open-ended `Range: bytes=N-` down to playback
/// speed (~15 kB/s). Bounded 1 MiB ranges arrive at line rate — same as
/// upstream `ChunkedDataSource` (2 MiB there; 1 MiB here because some
/// networks 403 a first range larger than that).
const HTTP_CHUNK: u64 = 1 * 1024 * 1024;

fn fetch_loop(url: String, headers: HashMap<String, String>, state: Arc<FetchState>, from: u64, generation: u64) {
    let result = (|| -> Result<(), String> {
        let mut pos = from;
        loop {
            if state.kill.load(Ordering::SeqCst)
                || state.generation.load(Ordering::SeqCst) != generation
            {
                return Ok(());
            }
            let end = pos + HTTP_CHUNK - 1;
            let range = format!("bytes={pos}-{end}");
            let mut req = ureq::get(&url).set("Range", &range);
            for (key, value) in &headers {
                req = req.set(key, value);
            }
            let response = req.call().map_err(|e| format!("GET: {e}"))?;

            {
                let mut buf = state.buffer.lock().unwrap();
                if buf.total_len.is_none() {
                    if let Some(range) = response.header("content-range") {
                        if let Some(total) =
                            range.rsplit('/').next().and_then(|t| t.parse::<u64>().ok())
                        {
                            if total > 0 {
                                buf.total_len = Some(total);
                            }
                        }
                    } else if let Some(len) =
                        response.header("content-length").and_then(|l| l.parse::<u64>().ok())
                    {
                        buf.total_len = Some(pos + len);
                    }
                }
            }

            let mut reader = response.into_reader();
            let mut chunk = [0u8; 64 * 1024];
            let mut got: u64 = 0;
            loop {
                if state.kill.load(Ordering::SeqCst)
                    || state.generation.load(Ordering::SeqCst) != generation
                {
                    return Ok(());
                }
                let n = reader.read(&mut chunk).map_err(|e| format!("read: {e}"))?;
                if n == 0 {
                    break;
                }
                got += n as u64;
                {
                    let mut buf = state.buffer.lock().unwrap();
                    buf.data.extend_from_slice(&chunk[..n]);
                    state.cond.notify_all();
                }
                loop {
                    if state.kill.load(Ordering::SeqCst)
                        || state.generation.load(Ordering::SeqCst) != generation
                    {
                        return Ok(());
                    }
                    let buffered = {
                        let buf = state.buffer.lock().unwrap();
                        (buf.end().saturating_sub(buf.read_pos)) as i64
                    };
                    if buffered < 32 * 1024 * 1024 {
                        break;
                    }
                    std::thread::sleep(std::time::Duration::from_millis(50));
                }
            }
            if got == 0 {
                return Ok(());
            }
            pos += got;
            let total = state.buffer.lock().unwrap().total_len;
            if got < HTTP_CHUNK || total.is_some_and(|t| pos >= t) {
                return Ok(());
            }
        }
    })();

    let mut buf = state.buffer.lock().unwrap();
    if let Err(e) = result {
        log::error!("HttpMediaSource fetch failed: {e}");
        buf.fetch_error = Some(e);
    }
    buf.fetch_dead = true;
    state.cond.notify_all();
}

impl Read for HttpMediaSource {
    fn read(&mut self, out: &mut [u8]) -> std::io::Result<usize> {
        let mut buf = self.state.buffer.lock().unwrap();
        loop {
            if let Some(err) = &buf.fetch_error {
                if buf.loaded() == 0 {
                    return Err(std::io::Error::other(err.clone()));
                }
                // Serve what remains before surfacing the failure.
            }
            if buf.loaded() > 0 {
                let offset = (buf.read_pos - buf.start) as usize;
                let take = out.len().min(buf.data.len() - offset);
                out[..take].copy_from_slice(&buf.data[offset..offset + take]);
                buf.read_pos += take as u64;
                // Drop consumed bytes behind a 4 MB window so the buffer does
                // not grow without bound on long tracks.
                const KEEP_BEHIND: usize = 4 * 1024 * 1024;
                let consumed = (buf.read_pos - buf.start) as usize;
                if consumed > KEEP_BEHIND {
                    let cut = consumed - KEEP_BEHIND;
                    buf.data.drain(..cut);
                    buf.start += cut as u64;
                }
                return Ok(take);
            }
            if buf.fetch_dead {
                return Ok(0); // clean EOF
            }
            buf = self.state.cond.wait(buf).unwrap();
        }
    }
}

impl Seek for HttpMediaSource {
    fn seek(&mut self, pos: SeekFrom) -> std::io::Result<u64> {
        let total = self.state.buffer.lock().unwrap().total_len;
        let mut buf = self.state.buffer.lock().unwrap();
        let target = match pos {
            SeekFrom::Start(offset) => offset as i64,
            SeekFrom::Current(delta) => buf.read_pos as i64 + delta,
            SeekFrom::End(delta) => {
                let end = total
                    .ok_or_else(|| std::io::Error::other("seek from end with unknown length"))?
                    as i64;
                end + delta
            }
        };
        if target < 0 {
            return Err(std::io::Error::other("negative seek"));
        }
        let target = target as u64;

        if target > buf.end() {
            // Outside the fetched window: restart the ranged fetch there.
            drop(buf);
            // Kill the current fetcher first so it stops appending behind us.
            self.state.kill.store(true, Ordering::SeqCst);
            if let Some(handle) = self.fetcher.lock().unwrap().take() {
                let _ = handle.join();
            }
            self.spawn_fetch(target);
        } else {
            buf.read_pos = target;
        }
        Ok(target)
    }
}

impl MediaSource for HttpMediaSource {
    fn is_seekable(&self) -> bool {
        true
    }

    fn byte_len(&self) -> Option<u64> {
        self.state.buffer.lock().unwrap().total_len
    }
}

impl Drop for HttpMediaSource {
    fn drop(&mut self) {
        self.state.kill.store(true, Ordering::SeqCst);
        self.state.cond.notify_all();
        if let Some(handle) = self.fetcher.lock().unwrap().take() {
            let _ = handle.join();
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn source_kind_parse() {
        assert!(matches!(
            SourceKind::parse("https://example.com/a.webm"),
            SourceKind::Url(_)
        ));
        assert!(matches!(
            SourceKind::parse("http://example.com/a.webm"),
            SourceKind::Url(_)
        ));
        assert!(matches!(SourceKind::parse("/tmp/a.flac"), SourceKind::Path(_)));
    }

    #[test]
    fn growing_file_waits_only_with_grow_marker() {
        assert!(!GrowingFile::is_growing("/tmp/bitchord-no-such.mp4"));
    }
}
