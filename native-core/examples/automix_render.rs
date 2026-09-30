//! Offline audition / scoring of Automix transitions.
//!
//! ```text
//! cargo run --example automix_render -- <outgoing> <incoming> <out.wav>
//! cargo run --example automix_render -- --score-only <outgoing> <incoming>
//! cargo run --example automix_render -- --score-dir <fixtures_dir>
//! ```
//!
//! `--score-dir` expects pairs named `NN-out.*` / `NN-in.*` (same stem prefix)
//! and prints a Smoothness Index line per pair without rendering audio.

use std::collections::HashMap;
use std::path::Path;
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::sync::{Arc, Mutex};

use native_core::decode::{SourceKind, SymphoniaDecoder};
use native_core::mixer::{
    run_mixer, Command, EngineEvents, NerdSnapshot, TrackInfo, TrackSource, TransitionPlan,
};
use native_core::{PlaybackState, TrackEndReason};

struct LogEvents;

impl EngineEvents for LogEvents {
    fn state_changed(&self, state: PlaybackState) {
        eprintln!("state {state:?}");
    }
    fn track_ended(&self, reason: TrackEndReason, _source: String) {
        eprintln!("ended {reason:?}");
    }
    fn error(&self, message: String) {
        eprintln!("error {message}");
    }
    fn handoff(&self, info: TrackInfo) {
        eprintln!("handoff {}", info.title);
    }
    fn duration_changed(&self, seconds: f64) {
        eprintln!("duration {seconds:.2}s");
    }
}

fn file_duration(path: &str) -> f64 {
    let kind = SourceKind::parse(path);
    SymphoniaDecoder::open(&kind, &HashMap::new())
        .ok()
        .and_then(|decoder| decoder.duration_seconds())
        .filter(|seconds| seconds.is_finite() && *seconds > 0.0)
        .unwrap_or(0.0)
}

/// The planner's decode callback. `mono` asks for a downmix; otherwise the
/// buffer stays interleaved stereo.
fn decode_window(
    path: &str,
    start: f64,
    duration: f64,
    mono: bool,
) -> Option<(Vec<f32>, u32, f64)> {
    let kind = SourceKind::parse(path);
    let mut decoder = SymphoniaDecoder::open(&kind, &HashMap::new()).ok()?;
    if start > 0.0 {
        decoder.seek_seconds(start).ok()?;
    }
    let actual = decoder.position_seconds();
    let rate = decoder.sample_rate();
    if rate == 0 {
        return None;
    }
    let want = (duration.max(0.0) * rate as f64) as usize;
    let mut samples = Vec::new();
    while samples.len() < want.saturating_mul(2) {
        let chunk = decoder.read_stereo(4096).ok()?;
        if chunk.is_empty() {
            break;
        }
        samples.extend_from_slice(&chunk);
    }
    if mono {
        let mixed: Vec<f32> = samples
            .chunks_exact(2)
            .map(|pair| (pair[0] + pair[1]) * 0.5)
            .collect();
        Some((mixed, rate, actual))
    } else {
        Some((samples, rate, actual))
    }
}

fn write_wav(path: &Path, interleaved: &[f32], rate: u32) {
    let mut bytes = Vec::with_capacity(44 + interleaved.len() * 2);
    let data_len = (interleaved.len() * 2) as u32;
    bytes.extend_from_slice(b"RIFF");
    bytes.extend_from_slice(&(36 + data_len).to_le_bytes());
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
    bytes.extend_from_slice(&data_len.to_le_bytes());
    for sample in interleaved {
        let clipped = (sample.clamp(-1.0, 1.0) * 32767.0) as i16;
        bytes.extend_from_slice(&clipped.to_le_bytes());
    }
    std::fs::write(path, bytes).expect("write wav");
}

fn print_plan(plan: &TransitionPlan) {
    let smooth = native_core::analyzer::score_plan(plan);
    println!(
        "style={:?} cue={:.2}s fade={:.2}s end={:.2}s rate={:.4} bed={:.2}@{:.1}dB dip={:.2}x{:.2} glide={:.1}s swap={}@{:.2} vocal={:.2}",
        plan.style,
        plan.cue_seconds,
        plan.fade_seconds,
        plan.transition_end_seconds,
        plan.playback_rate,
        plan.bed_fraction,
        plan.bed_gain_db,
        plan.dip_depth,
        plan.dip_width,
        plan.post_glide_seconds,
        plan.bass_swap,
        plan.bass_swap_fraction,
        plan.vocal_overlap,
    );
    println!(
        "smoothness={:.3} stretch_cost={:.3} style_bonus={:.3} forced_stretch={}",
        smooth.score, smooth.stretch_cost, smooth.style_bonus, smooth.forced_stretch
    );
    if smooth.forced_stretch {
        eprintln!(
            "warning: playback_rate {:.4} exceeds the transparent ±4% band — planner should refuse this",
            plan.playback_rate
        );
    }
}

fn plan_for(outgoing: &str, incoming: &str) -> TransitionPlan {
    native_core::analyzer::plan_pair(
        outgoing,
        incoming,
        "",
        "",
        false,
        0.0,
        file_duration(outgoing),
        file_duration(incoming),
        false,
        "render",
        decode_window,
        file_duration,
    )
}

fn score_pair(outgoing: &str, incoming: &str, label: &str) {
    let plan = plan_for(outgoing, incoming);
    let smooth = native_core::analyzer::score_plan(&plan);
    let (out_src, in_src) = native_core::analyzer::last_analysis_sources();
    println!(
        "{label}\tstyle={:?}\trate={:.4}\tsmooth={:.3}\tforced={}\tout_src={}\tin_src={}",
        plan.style, plan.playback_rate, smooth.score, smooth.forced_stretch, out_src, in_src
    );
    if smooth.forced_stretch {
        eprintln!("{label}: FAIL forced_stretch rate={}", plan.playback_rate);
    }
}

fn pair_prefix(path: &Path) -> Option<String> {
    let name = path.file_stem()?.to_str()?;
    name.strip_suffix("-out")
        .or_else(|| name.strip_suffix("-in"))
        .map(str::to_string)
}

fn score_dir(dir: &Path) {
    let mut entries: Vec<_> = std::fs::read_dir(dir)
        .unwrap_or_else(|e| panic!("read {dir:?}: {e}"))
        .filter_map(|e| e.ok())
        .map(|e| e.path())
        .filter(|p| p.is_file())
        .collect();
    entries.sort();
    let mut outs = std::collections::BTreeMap::new();
    let mut ins = std::collections::BTreeMap::new();
    for path in &entries {
        let Some(prefix) = pair_prefix(path) else {
            continue;
        };
        let name = path.file_name().and_then(|n| n.to_str()).unwrap_or("");
        if name.contains("-out.") {
            outs.insert(prefix, path.clone());
        } else if name.contains("-in.") {
            ins.insert(prefix, path.clone());
        }
    }
    let mut pairs = Vec::new();
    for (prefix, out) in &outs {
        if let Some(incoming) = ins.get(prefix) {
            pairs.push((prefix.clone(), out.clone(), incoming.clone()));
        }
    }
    if pairs.is_empty() {
        eprintln!(
            "score-dir expects matching *-out.* / *-in.* pairs; found {} out, {} in",
            outs.len(),
            ins.len()
        );
        std::process::exit(2);
    }
    let mut failures = 0usize;
    for (label, out, incoming) in &pairs {
        let plan = plan_for(&out.to_string_lossy(), &incoming.to_string_lossy());
        let smooth = native_core::analyzer::score_plan(&plan);
        let (out_src, in_src) = native_core::analyzer::last_analysis_sources();
        println!(
            "{label}\tstyle={:?}\trate={:.4}\tsmooth={:.3}\tforced={}\tout_src={}\tin_src={}",
            plan.style, plan.playback_rate, smooth.score, smooth.forced_stretch, out_src, in_src
        );
        if smooth.forced_stretch {
            failures += 1;
        }
    }
    if failures > 0 {
        std::process::exit(1);
    }
}

fn main() {
    env_logger::init();
    let args: Vec<String> = std::env::args().skip(1).collect();
    if args.first().map(String::as_str) == Some("--score-only") {
        if args.len() < 3 {
            eprintln!("usage: automix_render --score-only <outgoing> <incoming>");
            std::process::exit(2);
        }
        score_pair(&args[1], &args[2], "pair");
        return;
    }
    if args.first().map(String::as_str) == Some("--score-dir") {
        if args.len() < 2 {
            eprintln!("usage: automix_render --score-dir <fixtures_dir>");
            std::process::exit(2);
        }
        score_dir(Path::new(&args[1]));
        return;
    }

    let outgoing = args.first().cloned();
    let incoming = args.get(1).cloned();
    let output = args.get(2).cloned();
    let (Some(outgoing), Some(incoming), Some(output)) = (outgoing, incoming, output) else {
        eprintln!("usage: automix_render <outgoing> <incoming> <out.wav>");
        eprintln!("       automix_render --score-only <outgoing> <incoming>");
        eprintln!("       automix_render --score-dir <fixtures_dir>");
        std::process::exit(2);
    };

    let out_duration = file_duration(&outgoing);
    let in_duration = file_duration(&incoming);
    let plan = plan_for(&outgoing, &incoming);
    print_plan(&plan);

    let fade = plan.fade_seconds.max(0.5);
    let end = if plan.transition_end_seconds > 0.0 {
        plan.transition_end_seconds
    } else {
        out_duration
    };
    // Arming looks four seconds ahead of the fade. Starting six seconds
    // before it leaves the decoder time to open the incoming file.
    let lead = 6.0;
    let start_at = (end - fade - lead).max(0.0);
    let capture_seconds = (end + plan.post_glide_seconds + 2.0 - start_at).max(8.0);

    let rate = 44_100u32;
    let events = Arc::new(LogEvents);
    let (tx, rx) = crossbeam_channel::unbounded::<Command>();
    let (consumer_side, mut consumer) = rtrb::RingBuffer::<f32>::new(rate as usize * 2);
    let buffered = Arc::new(AtomicU64::new(0));
    let position = Arc::new(AtomicU64::new(0));
    let duration = Arc::new(AtomicU64::new(0));
    let shutdown = Arc::new(AtomicBool::new(false));
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
                rate,
                events,
                shutdown,
                Arc::new(AtomicBool::new(false)),
                Arc::new(AtomicBool::new(false)),
                Arc::new(Mutex::new(NerdSnapshot::default())),
            )
        }
    });

    tx.send(Command::Load {
        request: TrackSource {
            source: outgoing.clone(),
            title: "outgoing".into(),
            artist: String::new(),
            start_seconds: start_at,
            plan: TransitionPlan::default(),
            headers: HashMap::new(),
            claimed_kbps: 0,
            loudness_db: None,
            duration_seconds: out_duration,
        },
        reply: crossbeam_channel::bounded(1).0,
    })
    .unwrap();
    tx.send(Command::QueueNext {
        request: TrackSource {
            source: incoming.clone(),
            title: "incoming".into(),
            artist: String::new(),
            start_seconds: plan.cue_seconds.max(0.0),
            plan: plan.clone(),
            headers: HashMap::new(),
            claimed_kbps: 0,
            loudness_db: None,
            duration_seconds: in_duration,
        },
    })
    .unwrap();

    let want = (capture_seconds * rate as f64) as usize;
    let mut samples = Vec::with_capacity(want * 2);
    let deadline = std::time::Instant::now() + std::time::Duration::from_secs(180);
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

    write_wav(Path::new(&output), &samples, rate);
    println!(
        "wrote {} ({:.1}s from {:.1}s of the outgoing track)",
        output,
        samples.len() as f64 / 2.0 / rate as f64,
        start_at
    );
}
