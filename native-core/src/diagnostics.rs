//! Opt-in bounded PCM capture. No capture or file I/O runs in the output callback.
use sha2::{Digest, Sha256};
use std::{
    cell::{Cell, RefCell},
    io::{BufWriter, Read, Write},
    path::{Path, PathBuf},
};
thread_local! {static CAPTURE:RefCell<Option<Capture>>=const{RefCell::new(None)};static DECODE_CHUNK:Cell<usize>=const{Cell::new(4096)};static APPLE_AAC:Cell<bool>=const{Cell::new(false)};}
struct Capture {
    dir: PathBuf,
    seconds: f64,
    limit: usize,
    decoder_limit: usize,
    decoder_rate: u32,
    rate: u32,
    stages: [Vec<f32>; 3],
    source: String,
    fingerprint: Option<std::thread::JoinHandle<String>>,
    complete: bool,
    settings_history: Vec<serde_json::Value>,
}
pub fn prefer_apple_aac() -> bool {
    APPLE_AAC.with(Cell::get)
}
pub fn set_prefer_apple_aac(value: bool) {
    APPLE_AAC.with(|v| v.set(value));
}
pub fn enabled() -> bool {
    CAPTURE.with(|c| c.borrow().is_some())
}
pub fn record_settings(settings: serde_json::Value) {
    CAPTURE.with(|c| {
        if let Some(c) = &mut *c.borrow_mut() {
            if c.settings_history.len() >= 1024
                || c.settings_history
                    .last()
                    .is_some_and(|v| v["settings"] == settings)
            {
                return;
            }
            let seconds = c.stages[2].len() as f64 / 2.0 / c.rate as f64;
            c.settings_history
                .push(serde_json::json!({"output_seconds":seconds,"settings":settings}));
        }
    });
}
pub fn set_chunk(frames: usize) {
    DECODE_CHUNK.with(|c| c.set(frames.clamp(1, 65536)));
}
pub fn chunk() -> usize {
    DECODE_CHUNK.with(Cell::get)
}
pub fn start(dir: String, seconds: f64, rate: u32) -> Result<(), String> {
    let path = PathBuf::from(dir);
    std::fs::create_dir_all(&path).map_err(|e| e.to_string())?;
    CAPTURE.with(|c| {
        *c.borrow_mut() = Some(Capture {
            dir: path,
            seconds: seconds.clamp(0.1, 30.0),
            limit: (seconds.clamp(0.1, 30.0) * rate as f64) as usize * 2,
            decoder_limit: (seconds.clamp(0.1, 30.0) * rate as f64) as usize * 2,
            decoder_rate: rate,
            complete: false,
            settings_history: Vec::new(),
            rate,
            stages: std::array::from_fn(|_| Vec::new()),
            source: String::new(),
            fingerprint: None,
        })
    });
    Ok(())
}
pub fn source(path: &str, rate: u32) {
    CAPTURE.with(|c| {
        if let Some(c) = &mut *c.borrow_mut() {
            if !c.source.is_empty() {
                return;
            } // One recording per capture; transitions appear in downstream stages.
            c.source = path.into();
            c.decoder_rate = rate;
            c.decoder_limit = (c.seconds * rate as f64) as usize * 2;
            c.complete = complete_file(path);
            if c.complete {
                let source = c.source.clone();
                c.fingerprint = Some(std::thread::spawn(move || {
                    fingerprint(Path::new(&source)).unwrap_or_else(|_| "unavailable".into())
                }));
            }
        }
    });
}
pub fn capture_voice(stage: usize, source: &str, pcm: &[f32]) {
    let matches = CAPTURE.with(|c| c.borrow().as_ref().is_some_and(|c| c.source == source));
    if matches {
        capture(stage, pcm);
    }
}
pub fn capture(stage: usize, pcm: &[f32]) {
    CAPTURE.with(|c| {
        if let Some(c) = &mut *c.borrow_mut() {
            let n = pcm.len().min(
                (if stage == 0 { c.decoder_limit } else { c.limit })
                    .saturating_sub(c.stages[stage].len()),
            );
            c.stages[stage].extend_from_slice(&pcm[..n]);
        }
    });
}
pub fn finish(
    snapshot: crate::mixer::NerdSnapshot,
    settings: serde_json::Value,
    completion: impl FnOnce(Result<(), String>) + Send + 'static,
) {
    let capture = CAPTURE.with(|c| c.borrow_mut().take());
    let Some(c) = capture else {
        completion(Ok(()));
        return;
    };
    // File writes and whole-source hashing must not starve the playback ring.
    std::thread::spawn(move || {
        completion(save(c, snapshot, settings));
    });
}
fn save(
    c: Capture,
    snapshot: crate::mixer::NerdSnapshot,
    settings: serde_json::Value,
) -> Result<(), String> {
    for (i, name) in ["decoder", "voice", "protected"].iter().enumerate() {
        write_float_wav(
            &c.dir.join(format!("{name}.wav")),
            if i == 0 { c.decoder_rate } else { c.rate },
            &c.stages[i],
        )
        .map_err(|e| e.to_string())?;
    }
    let complete_at_finish = complete_file(&c.source);
    let encoded_bytes = std::fs::metadata(&c.source).ok().map(|m| m.len());
    let final_fingerprint = if complete_at_finish {
        fingerprint(Path::new(&c.source)).ok()
    } else {
        None
    };
    let peaks: Vec<f32> = c
        .stages
        .iter()
        .map(|p| {
            p.iter()
                .filter(|x| x.is_finite())
                .map(|x| x.abs())
                .fold(0.0, f32::max)
        })
        .collect();
    let start_fingerprint = c.fingerprint.and_then(|task| task.join().ok());
    let metadata = serde_json::json!({"source":c.source,"source_sha256":final_fingerprint,"source_sha256_at_start":start_fingerprint,"encoded_bytes_at_finish":encoded_bytes,"source_complete_at_capture_finish":complete_at_finish,"codec":snapshot.codec,"decoder":snapshot.decoder_implementation,"decoded_layout":snapshot.decoded_layout,"source_complete_at_capture_start":c.complete,"settings_at_finish":settings,"settings_history":c.settings_history,"queue_target_ms":snapshot.queued_target_ms,"decoded_rate":c.decoder_rate,"decoded_channels":snapshot.channels,"output_rate":c.rate,"active_stages":snapshot.active_stages,"converter_delay_frames":snapshot.converter_delay_frames,"peaks":peaks,"protection_reduction_db":snapshot.protection_reduction_db,"protection_interventions":snapshot.protection_interventions,"build_revision":snapshot.build_revision,"capture_limit_seconds":c.limit as f64/2.0/c.rate as f64});
    std::fs::write(
        c.dir.join("capture.json"),
        serde_json::to_vec_pretty(&metadata).unwrap(),
    )
    .map_err(|e| e.to_string())
}
fn complete_file(path: &str) -> bool {
    Path::new(path).is_file()
        && (!Path::new(&format!("{path}.grow")).exists()
            || Path::new(&format!("{path}.complete")).exists())
}
pub fn fingerprint(path: &Path) -> std::io::Result<String> {
    let mut f = std::fs::File::open(path)?;
    let mut hash = Sha256::new();
    let mut bytes = [0u8; 65536];
    loop {
        let n = f.read(&mut bytes)?;
        if n == 0 {
            break;
        }
        hash.update(&bytes[..n]);
    }
    Ok(format!("{:x}", hash.finalize()))
}
pub fn write_float_wav(path: &Path, rate: u32, pcm: &[f32]) -> std::io::Result<()> {
    let mut f = BufWriter::new(std::fs::File::create(path)?);
    let bytes = (pcm.len() * 4) as u32;
    f.write_all(b"RIFF")?;
    f.write_all(&(36 + bytes).to_le_bytes())?;
    f.write_all(b"WAVEfmt ")?;
    f.write_all(&16u32.to_le_bytes())?;
    f.write_all(&3u16.to_le_bytes())?;
    f.write_all(&2u16.to_le_bytes())?;
    f.write_all(&rate.to_le_bytes())?;
    f.write_all(&(rate * 8).to_le_bytes())?;
    f.write_all(&8u16.to_le_bytes())?;
    f.write_all(&32u16.to_le_bytes())?;
    f.write_all(b"data")?;
    f.write_all(&bytes.to_le_bytes())?;
    for s in pcm {
        f.write_all(&s.to_le_bytes())?;
    }
    f.flush()
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn capture_completeness_requires_present_finished_file() {
        assert!(!complete_file("https://example.invalid/audio"));
        let path =
            std::env::temp_dir().join(format!("bitchord-capture-complete-{}", std::process::id()));
        let source = path.to_string_lossy().into_owned();
        assert!(!complete_file(&source));
        std::fs::write(&path, [0u8; 4]).unwrap();
        assert!(complete_file(&source));
        std::fs::write(format!("{source}.grow"), []).unwrap();
        assert!(!complete_file(&source));
        std::fs::write(format!("{source}.complete"), []).unwrap();
        assert!(complete_file(&source));
        std::fs::remove_file(path).unwrap();
        std::fs::remove_file(format!("{source}.grow")).unwrap();
        std::fs::remove_file(format!("{source}.complete")).unwrap();
        assert!(!complete_file(&source));
    }
}
