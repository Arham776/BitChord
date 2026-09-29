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
//! Symphonia 0.6.1 has no bundled Opus decoder, so the one missing codec is
//! supplied by the libopus adapter. This lets configured sources serve WebM and
//! Ogg Opus directly instead of forcing an AAC fallback.

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
use symphonia::core::codecs::audio::well_known::CODEC_ID_OPUS;
use symphonia::core::codecs::audio::{AudioDecoder, AudioDecoderOptions};
use symphonia::core::codecs::registry::RegisterableAudioDecoder;
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
    codec: String,
    bit_depth: u32,
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
    let opts = AudioDecoderOptions::default();
    if audio.codec == CODEC_ID_OPUS {
        return symphonia_adapter_libopus::OpusDecoder::try_registry_new(audio, &opts)
            .map_err(|e| DecodeError(format!("Opus decoder: {e}")));
    }
    let codecs = symphonia::default::get_codecs();
    // Per decode, and a decode is now a routine event, so this is `debug`.
    // The one-line summary (`opened …: codec=… rate=… duration=…`) stays at
    // `info`, where it describes the result rather than the attempt.
    log::debug!(
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

    // itag 18 / HE-AAC: Symphonia has no SBR. Strip to the LC core so the
    // track still plays (half-rate, no air band) when the resolver could not
    // land itag 140. Silence is worse; the resolver still prefers AAC-LC.
    let rate = audio.sample_rate.unwrap_or(44_100);
    if is_he_aac(audio) {
        log::warn!("HE-AAC/SBR at {rate} Hz — decoding LC core only (no reconstructed highs)");
    }
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

/// MPEG-4 AudioSpecificConfig: AOT 5 = SBR, 29 = HE-AACv2/PS. LC+SBR
/// also appends syncExtensionType 0x2B7 after the core ASC.
fn is_he_aac(audio: &symphonia::core::codecs::audio::AudioCodecParameters) -> bool {
    audio
        .extra_data
        .as_ref()
        .is_some_and(|d| is_he_aac_config(d.as_ref()))
}

fn is_he_aac_config(extra: &[u8]) -> bool {
    if extra.is_empty() {
        return false;
    }
    match aac_audio_object_type(extra) {
        Some(5 | 29) => true,
        Some(2) => extra.len() > 4 || has_sbr_sync(extra),
        _ => has_sbr_sync(extra),
    }
}

/// 11-bit `syncExtensionType` 0x2B7 that marks an SBR extension after LC.
fn has_sbr_sync(extra: &[u8]) -> bool {
    if extra.len() < 2 {
        return false;
    }
    let mut acc = 0u32;
    let mut bits = 0u32;
    for &b in extra {
        acc = (acc << 8) | u32::from(b);
        bits += 8;
        while bits >= 11 {
            if (acc >> (bits - 11)) & 0x7FF == 0x2B7 {
                return true;
            }
            bits -= 1;
        }
    }
    false
}

fn aac_audio_object_type(extra: &[u8]) -> Option<u8> {
    if extra.is_empty() {
        return None;
    }
    let aot = extra[0] >> 3;
    if aot != 31 {
        return Some(aot);
    }
    if extra.len() < 2 {
        return None;
    }
    Some(32 + (((extra[0] & 0x07) << 3) | (extra[1] >> 5)))
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

fn codec_label(
    source: &SourceKind,
    audio: &symphonia::core::codecs::audio::AudioCodecParameters,
) -> String {
    use symphonia::core::codecs::audio::well_known::*;

    // The codec id is authoritative. In particular, ALAC is commonly stored
    // in an .m4a container, so extension-first detection mislabeled lossless
    // Apple Lossless files as AAC and prevented the exact-PCM route from ever
    // qualifying them.
    if audio.codec == CODEC_ID_FLAC {
        return "FLAC".into();
    }
    if audio.codec == CODEC_ID_ALAC {
        return "ALAC".into();
    }
    if matches!(
        audio.codec,
        CODEC_ID_PCM_S32LE
            | CODEC_ID_PCM_S32LE_PLANAR
            | CODEC_ID_PCM_S32BE
            | CODEC_ID_PCM_S32BE_PLANAR
            | CODEC_ID_PCM_S24LE
            | CODEC_ID_PCM_S24LE_PLANAR
            | CODEC_ID_PCM_S24BE
            | CODEC_ID_PCM_S24BE_PLANAR
            | CODEC_ID_PCM_S16LE
            | CODEC_ID_PCM_S16LE_PLANAR
            | CODEC_ID_PCM_S16BE
            | CODEC_ID_PCM_S16BE_PLANAR
            | CODEC_ID_PCM_S8
            | CODEC_ID_PCM_S8_PLANAR
            | CODEC_ID_PCM_U32LE
            | CODEC_ID_PCM_U32LE_PLANAR
            | CODEC_ID_PCM_U32BE
            | CODEC_ID_PCM_U32BE_PLANAR
            | CODEC_ID_PCM_U24LE
            | CODEC_ID_PCM_U24LE_PLANAR
            | CODEC_ID_PCM_U24BE
            | CODEC_ID_PCM_U24BE_PLANAR
            | CODEC_ID_PCM_U16LE
            | CODEC_ID_PCM_U16LE_PLANAR
            | CODEC_ID_PCM_U16BE
            | CODEC_ID_PCM_U16BE_PLANAR
            | CODEC_ID_PCM_U8
            | CODEC_ID_PCM_U8_PLANAR
    ) {
        return "PCM".into();
    }
    if matches!(
        audio.codec,
        CODEC_ID_PCM_F32LE
            | CODEC_ID_PCM_F32LE_PLANAR
            | CODEC_ID_PCM_F32BE
            | CODEC_ID_PCM_F32BE_PLANAR
            | CODEC_ID_PCM_F64LE
            | CODEC_ID_PCM_F64LE_PLANAR
            | CODEC_ID_PCM_F64BE
            | CODEC_ID_PCM_F64BE_PLANAR
    ) {
        return "PCM Float".into();
    }
    if audio.codec == CODEC_ID_PCM_ALAW {
        return "G.711 A-law".into();
    }
    if audio.codec == CODEC_ID_PCM_MULAW {
        return "G.711 μ-law".into();
    }
    let from_path = match source {
        SourceKind::Path(p) => std::path::Path::new(p)
            .extension()
            .and_then(|e| e.to_str())
            .map(|e| e.to_ascii_lowercase()),
        SourceKind::Url(u) => {
            let path = u.split('?').next().unwrap_or(u);
            std::path::Path::new(path)
                .extension()
                .and_then(|e| e.to_str())
                .map(|e| e.to_ascii_lowercase())
        }
    };
    match from_path.as_deref() {
        Some("flac") => return "FLAC".into(),
        Some("alac") => return "ALAC".into(),
        Some("mp3") => return "MP3".into(),
        Some("ogg" | "oga") => return "Vorbis".into(),
        Some("wav") => return "WAVE".into(),
        Some("aiff" | "aif") => return "AIFF".into(),
        Some("opus" | "webm") => return "Opus".into(),
        Some("m4a" | "aac" | "mp4") => {
            if audio.profile.is_some() {
                return "AAC".into();
            }
            return "AAC".into();
        }
        _ => {}
    }
    "AAC".into()
}

impl SymphoniaDecoder {
    pub fn open(
        source: &SourceKind,
        headers: &HashMap<String, String>,
    ) -> Result<Self, DecodeError> {
        Self::open_inner(source, headers, true)
    }

    /// Like [`open`], but a download that is still appending ends at the bytes
    /// on disk. Planning uses this. Playback uses [`open`], which waits, so a
    /// song never stops in the middle of its own download.
    pub fn open_available(
        source: &SourceKind,
        headers: &HashMap<String, String>,
    ) -> Result<Self, DecodeError> {
        Self::open_inner(source, headers, false)
    }

    fn open_inner(
        source: &SourceKind,
        headers: &HashMap<String, String>,
        block_on_growth: bool,
    ) -> Result<Self, DecodeError> {
        let mss: MediaSourceStream = match source {
            SourceKind::Path(path) => {
                let boxed: Box<dyn MediaSource> = if GrowingFile::is_growing(path) {
                    let growing = if block_on_growth {
                        GrowingFile::open(path)
                    } else {
                        GrowingFile::open_mode(path, false)
                    };
                    Box::new(growing.map_err(|e| DecodeError(format!("open {path}: {e}")))?)
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
            if let Some(ext) = std::path::Path::new(path)
                .extension()
                .and_then(|e| e.to_str())
            {
                hint.with_extension(ext);
            }
        }

        let probe = symphonia::default::get_probe();
        let format = probe
            .probe(
                &hint,
                mss,
                FormatOptions::default(),
                MetadataOptions::default(),
            )
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
        let channels = audio
            .channels
            .as_ref()
            .map(|c| c.count())
            .unwrap_or(2)
            .max(1);
        // ISO-MP4 often has mdhd timescale ≠ sample rate (muxed itag 18), so
        // `num_frames` is left unset. Use the container duration + timebase.
        let duration_secs = match (track.time_base, track.duration) {
            (Some(tb), Some(dur)) => {
                let secs = tb.calc_duration_saturating(dur).as_secs_f64();
                if secs > 0.0 {
                    Some(secs)
                } else {
                    None
                }
            }
            _ => track
                .num_frames
                .filter(|&f| f > 0)
                .map(|f| f as f64 / sample_rate as f64),
        };

        let decoder = open_audio_decoder(&audio)?;
        let codec = codec_label(source, &audio);
        // Only report source bit depth for codecs with a meaningful integer PCM
        // precision. Lossy codecs decode to float, which is not their encoded
        // source depth and must not be presented as one.
        let bit_depth = if matches!(codec.as_str(), "FLAC" | "ALAC" | "PCM" | "PCM Float") {
            audio.bits_per_sample.unwrap_or(0)
        } else {
            0
        };

        let label = match source {
            SourceKind::Path(p) => p.rsplit('/').next().unwrap_or(p),
            SourceKind::Url(_) => "url",
        };
        log::info!(
            "opened {label}: codec={codec} rate={sample_rate} ch={channels} bits={bit_depth} duration={duration_secs:?}s frames={:?}",
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
            codec,
            bit_depth,
        })
    }

    pub fn sample_rate(&self) -> u32 {
        self.sample_rate
    }

    pub fn channels(&self) -> usize {
        self.channels
    }

    pub fn codec(&self) -> &str {
        &self.codec
    }

    pub fn bit_depth(&self) -> u32 {
        self.bit_depth
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
        let to = SeekTo::Time {
            time,
            track_id: Some(self.track_id),
        };
        match self.format.seek(SeekMode::Accurate, to) {
            Ok(seeked_to) => {
                self.decoder.reset();
                self.pending.clear();
                self.pending_cursor = 0;
                // Frame counting restarts from where the seek landed. The
                // container's timestamp is the better answer when it has one,
                // but a stream with no real timestamps (raw WAV, ADTS) reports
                // zero there — and trusting that restarts the playhead at the
                // file start while the audio is in the middle of the song. The
                // requested time is the honest fallback.
                let requested = seconds.max(0.0);
                let landed = self
                    .time_base()
                    .map(|tb| tb.calc_time_saturating(seeked_to.actual_ts).as_secs_f64())
                    .filter(|t| t.is_finite() && *t > 0.0)
                    .unwrap_or(requested);
                self.decoded_frames = (landed * self.sample_rate as f64).round() as u64;
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
    /// Playback waits for bytes that have not arrived yet. Analysis must not:
    /// a plan that blocks until `.complete` runs at the end of the song, which
    /// is after the blend it was supposed to schedule.
    block: bool,
}

impl GrowingFile {
    fn is_growing(path: &str) -> bool {
        Path::new(&format!("{path}.grow")).exists()
            && !Path::new(&format!("{path}.complete")).exists()
    }

    fn open(path: &str) -> std::io::Result<Self> {
        Self::open_mode(path, true)
    }

    fn open_mode(path: &str, block: bool) -> std::io::Result<Self> {
        let declared_len = std::fs::read_to_string(format!("{path}.len"))
            .ok()
            .and_then(|s| s.trim().parse().ok())
            .filter(|n: &u64| *n > 0);
        Ok(Self {
            file: File::open(path)?,
            path: PathBuf::from(path),
            declared_len,
            block,
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
            if self.is_complete() || !self.block {
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
        let on_disk = std::fs::metadata(&self.path)
            .ok()
            .map(|m| m.len())
            .unwrap_or(current);
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
        if self.block {
            self.wait_for_len(target)?;
        } else if !self.is_complete() && target > on_disk {
            return Err(std::io::Error::new(
                std::io::ErrorKind::UnexpectedEof,
                "analysis read stopped at the bytes downloaded so far",
            ));
        }
        self.file.seek(SeekFrom::Start(target))
    }
}

impl MediaSource for GrowingFile {
    fn is_seekable(&self) -> bool {
        self.is_complete()
    }

    fn byte_len(&self) -> Option<u64> {
        if self.is_complete() {
            return std::fs::metadata(&self.path)
                .ok()
                .map(|m| m.len())
                .or(self.declared_len);
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

    /// Bytes already fetched that sit at or after `read_pos`. Zero when the
    /// cursor has been left behind `start` (a seek restarted the window
    /// without moving the cursor — the old `loaded()` treated that as a
    /// huge positive length and the read path underflowed).
    fn loaded(&self) -> u64 {
        if self.read_pos < self.start {
            0
        } else {
            self.end().saturating_sub(self.read_pos)
        }
    }

    /// Index of `read_pos` inside `data`, if it still lands in the window.
    fn cursor(&self) -> Option<usize> {
        let rel = self.read_pos.checked_sub(self.start)?;
        let rel = usize::try_from(rel).ok()?;
        (rel <= self.data.len()).then_some(rel)
    }
}

fn lock_buf(mutex: &Mutex<StreamBuffer>) -> std::sync::MutexGuard<'_, StreamBuffer> {
    mutex.lock().unwrap_or_else(|e| e.into_inner())
}

fn lock_handle(
    mutex: &Mutex<Option<JoinHandle<()>>>,
) -> std::sync::MutexGuard<'_, Option<JoinHandle<()>>> {
    mutex.lock().unwrap_or_else(|e| e.into_inner())
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
            let mut buf = lock_buf(&self.state.buffer);
            buf.fetch_dead = false;
            buf.fetch_error = None;
            // Keep an overlapping tail when the new origin still sits inside
            // the current window; otherwise drop it — appending onto stale
            // bytes would desync `start` from the HTTP range.
            if from >= buf.start && from <= buf.end() {
                let cut = (from - buf.start) as usize;
                let cut = cut.min(buf.data.len());
                buf.data.drain(..cut);
            } else {
                buf.data.clear();
            }
            buf.start = from;
            buf.read_pos = from;
        }
        self.state.kill.store(false, Ordering::SeqCst);
        let url = self.url.clone();
        let headers = self.headers.clone();
        let state = self.state.clone();
        let handle = std::thread::Builder::new()
            .name("native-core-http".into())
            .spawn(move || fetch_loop(url, headers, state, from, generation))
            .expect("spawn fetch thread");
        *lock_handle(&self.fetcher) = Some(handle);
    }
}

/// googlevideo throttles an open-ended `Range: bytes=N-` down to playback
/// speed (~15 kB/s). Bounded 1 MiB ranges arrive at line rate — same as
/// upstream `ChunkedDataSource` (2 MiB there; 1 MiB here because some
/// networks 403 a first range larger than that).
const HTTP_CHUNK: u64 = 1 * 1024 * 1024;

fn fetch_loop(
    url: String,
    headers: HashMap<String, String>,
    state: Arc<FetchState>,
    from: u64,
    generation: u64,
) {
    let result = (|| -> Result<(), String> {
        let mut pos = from;
        loop {
            if state.kill.load(Ordering::SeqCst)
                || state.generation.load(Ordering::SeqCst) != generation
            {
                return Ok(());
            }
            let known_total = lock_buf(&state.buffer).total_len;
            if known_total.is_some_and(|t| pos >= t) {
                return Ok(());
            }
            let end = known_total
                .map(|t| (pos + HTTP_CHUNK - 1).min(t.saturating_sub(1)))
                .unwrap_or(pos + HTTP_CHUNK - 1);
            let range = format!("bytes={pos}-{end}");
            let mut req = ureq::get(&url).set("Range", &range);
            for (key, value) in &headers {
                req = req.set(key, value);
            }
            let response = match req.call() {
                Ok(r) => r,
                // Past EOF (MP4 probe seeking to moov, or a CDN that does not
                // honour a range past Content-Length). Same as a clean end.
                Err(ureq::Error::Status(416, _)) => return Ok(()),
                Err(e) => return Err(format!("GET: {e}")),
            };

            {
                let mut buf = lock_buf(&state.buffer);
                if buf.total_len.is_none() {
                    if let Some(range) = response.header("content-range") {
                        if let Some(total) =
                            range.rsplit('/').next().and_then(|t| t.parse::<u64>().ok())
                        {
                            if total > 0 {
                                buf.total_len = Some(total);
                            }
                        }
                    } else if let Some(len) = response
                        .header("content-length")
                        .and_then(|l| l.parse::<u64>().ok())
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
                    let mut buf = lock_buf(&state.buffer);
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
                        let buf = lock_buf(&state.buffer);
                        buf.loaded() as i64
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
            let total = lock_buf(&state.buffer).total_len;
            if got < HTTP_CHUNK || total.is_some_and(|t| pos >= t) {
                return Ok(());
            }
        }
    })();

    let mut buf = lock_buf(&state.buffer);
    if let Err(e) = result {
        log::error!("HttpMediaSource fetch failed: {e}");
        buf.fetch_error = Some(e);
    }
    buf.fetch_dead = true;
    state.cond.notify_all();
}

impl Read for HttpMediaSource {
    fn read(&mut self, out: &mut [u8]) -> std::io::Result<usize> {
        let mut buf = lock_buf(&self.state.buffer);
        loop {
            if let Some(err) = &buf.fetch_error {
                if buf.loaded() == 0 {
                    return Err(std::io::Error::other(err.clone()));
                }
                // Serve what remains before surfacing the failure.
            }
            if let Some(offset) = buf.cursor() {
                let available = buf.data.len().saturating_sub(offset);
                if available > 0 {
                    let take = out.len().min(available);
                    out[..take].copy_from_slice(&buf.data[offset..offset + take]);
                    buf.read_pos += take as u64;
                    // Drop consumed bytes behind a 4 MB window so the buffer does
                    // not grow without bound on long tracks.
                    const KEEP_BEHIND: usize = 4 * 1024 * 1024;
                    let consumed = buf
                        .read_pos
                        .saturating_sub(buf.start)
                        .min(buf.data.len() as u64) as usize;
                    if consumed > KEEP_BEHIND {
                        let cut = consumed - KEEP_BEHIND;
                        buf.data.drain(..cut);
                        buf.start += cut as u64;
                    }
                    return Ok(take);
                }
            }
            if buf.fetch_dead {
                return Ok(0); // clean EOF
            }
            buf = self.state.cond.wait(buf).unwrap_or_else(|e| e.into_inner());
        }
    }
}

impl Seek for HttpMediaSource {
    fn seek(&mut self, pos: SeekFrom) -> std::io::Result<u64> {
        let total = lock_buf(&self.state.buffer).total_len;
        let mut buf = lock_buf(&self.state.buffer);
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

        // MP4 probe commonly seeks to the moov atom past the first range, or
        // back into bytes already dropped by KEEP_BEHIND. Either side of the
        // window needs a fresh ranged fetch — and `read_pos` must move with
        // `start` or the next read underflows.
        if target < buf.start || target > buf.end() {
            drop(buf);
            self.state.kill.store(true, Ordering::SeqCst);
            if let Some(handle) = lock_handle(&self.fetcher).take() {
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
        lock_buf(&self.state.buffer).total_len
    }
}

impl Drop for HttpMediaSource {
    fn drop(&mut self) {
        self.state.kill.store(true, Ordering::SeqCst);
        self.state.cond.notify_all();
        if let Some(handle) = lock_handle(&self.fetcher).take() {
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
        assert!(matches!(
            SourceKind::parse("/tmp/a.flac"),
            SourceKind::Path(_)
        ));
    }

    #[test]
    fn opus_uses_the_bundled_libopus_decoder() {
        let mut audio = symphonia::core::codecs::audio::AudioCodecParameters::new();
        audio
            .for_codec(CODEC_ID_OPUS)
            .with_sample_rate(48_000)
            .with_channels(Channels::from(Position::FRONT_LEFT | Position::FRONT_RIGHT));

        assert!(
            open_audio_decoder(&audio).is_ok(),
            "the Opus branch must construct the bundled decoder",
        );
    }

    #[test]
    fn growing_file_waits_only_with_grow_marker() {
        assert!(!GrowingFile::is_growing("/tmp/bitchord-no-such.mp4"));
    }

    /// A still-downloading file ends where the bytes end, for analysis. The
    /// playback opener would sit here for two minutes waiting on `.complete`.
    #[test]
    fn an_analysis_read_does_not_wait_for_the_rest_of_the_download() {
        let dir = std::env::temp_dir().join("bitchord-growing-analysis");
        std::fs::create_dir_all(&dir).unwrap();
        let path = dir.join("partial.wav");
        let rate = 44_100u32;
        let frames = rate as usize / 10;
        let mut bytes = Vec::new();
        bytes.extend_from_slice(b"RIFF");
        bytes.extend_from_slice(&(36 + (frames * 4) as u32).to_le_bytes());
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
        bytes.extend_from_slice(&((frames * 4) as u32).to_le_bytes());
        bytes.extend(std::iter::repeat(0).take(frames * 4));
        std::fs::write(&path, bytes).unwrap();
        let path_str = path.display().to_string();
        std::fs::write(format!("{path_str}.grow"), b"").unwrap();
        let _ = std::fs::remove_file(format!("{path_str}.complete"));

        let started = std::time::Instant::now();
        let mut decoder = SymphoniaDecoder::open_available(
            &SourceKind::parse(&path_str),
            &std::collections::HashMap::new(),
        )
        .unwrap();
        let mut total = 0usize;
        loop {
            let chunk = decoder.read_stereo(4096).unwrap();
            if chunk.is_empty() {
                break;
            }
            total += chunk.len();
        }
        assert!(total > 0, "the bytes already on disk should decode");
        assert!(
            started.elapsed() < std::time::Duration::from_secs(2),
            "analysis waited {:?} for a download that is still in progress",
            started.elapsed()
        );
    }

    #[test]
    fn lc_asc_is_not_he_aac() {
        let asc = lc_stereo_asc(44_100);
        assert_eq!(aac_audio_object_type(&asc), Some(2));
        assert!(!is_he_aac_config(&asc));
    }

    #[test]
    fn long_itag18_extra_is_he_aac() {
        // 25-byte esds: LC core plus SBR extension (the "aac too complex" path).
        let mut extra = lc_stereo_asc(22_050).to_vec();
        extra.extend_from_slice(&[0u8; 23]);
        assert!(is_he_aac_config(&extra));
    }

    #[test]
    fn sbr_and_ps_aot_are_he_aac() {
        assert_eq!(aac_audio_object_type(&[0x2B, 0x10]), Some(5));
        assert!(is_he_aac_config(&[0x2B, 0x10]));
        assert_eq!(aac_audio_object_type(&[0xE8, 0x10]), Some(29));
        assert!(is_he_aac_config(&[0xE8, 0x10]));
    }

    #[test]
    fn stream_buffer_loaded_is_zero_when_cursor_is_behind_window() {
        let buf = StreamBuffer {
            data: vec![],
            start: 7_000_000,
            read_pos: 0,
            total_len: Some(7_737_024),
            fetch_dead: false,
            fetch_error: None,
        };
        assert_eq!(buf.loaded(), 0);
        assert_eq!(buf.cursor(), None);
    }

    #[test]
    fn stream_buffer_cursor_stays_in_window() {
        let buf = StreamBuffer {
            data: vec![0; 1024],
            start: 1000,
            read_pos: 1500,
            total_len: None,
            fetch_dead: false,
            fetch_error: None,
        };
        assert_eq!(buf.cursor(), Some(500));
        assert_eq!(buf.loaded(), 524);
    }
}
