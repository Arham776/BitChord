//! Ordinary playback through the production decoder and mixer, without a device.
//! playback_render INPUT OUTPUT [--mode enhanced] [--rate 48000] [--chunk 7]
//! [--preset reference|speaker|headphone|dac] [--wet 1] [--speed 1]
//! [--capture DIR] [--seconds 30] [--start 0.5]
use native_core::{
    mixer::{
        run_mixer, Command, EngineEvents, NerdSnapshot, TrackInfo, TrackSource, TransitionPlan,
    },
    ClarityPreset, ClarityTuning, PlaybackState, SoundMode, TrackEndReason,
};
use std::{
    collections::HashMap,
    sync::{
        atomic::{AtomicBool, AtomicU64, Ordering},
        Arc, Mutex,
    },
    time::{Duration, Instant},
};
struct Events {
    ended: Arc<AtomicBool>,
    errors: Arc<Mutex<Vec<String>>>,
}
impl EngineEvents for Events {
    fn state_changed(&self, _: PlaybackState) {}
    fn track_ended(&self, _: TrackEndReason, _: String) {
        self.ended.store(true, Ordering::Release);
    }
    fn error(&self, message: String) {
        eprintln!("engine: {message}");
        self.errors.lock().unwrap().push(message);
    }
    fn handoff(&self, _: TrackInfo) {}
    fn duration_changed(&self, _: f64) {}
}
fn main() {
    let args: Vec<String> = std::env::args().skip(1).collect();
    assert!(
        args.len() >= 2,
        "usage: playback_render INPUT OUTPUT [options]"
    );
    let option = |name: &str| {
        args.iter()
            .position(|v| v == name)
            .and_then(|i| args.get(i + 1))
    };
    let rate = option("--rate")
        .map(|v| v.parse::<u32>().unwrap())
        .unwrap_or(48000);
    assert!((8000..=384000).contains(&rate));
    let chunk = option("--chunk")
        .map(|v| v.parse::<usize>().unwrap())
        .unwrap_or(4096);
    let mode = if option("--mode").map(String::as_str) == Some("enhanced") {
        SoundMode::Enhanced
    } else {
        SoundMode::Transparent
    };
    let preset = match option("--preset").map(String::as_str) {
        Some("speaker") => ClarityPreset::Speaker,
        Some("headphone") => ClarityPreset::Headphone,
        Some("dac") => ClarityPreset::Dac,
        _ => ClarityPreset::Reference,
    };
    let wet = option("--wet")
        .map(|v| v.parse::<f32>().unwrap())
        .unwrap_or(1.0);
    let speed = option("--speed")
        .map(|v| v.parse::<f32>().unwrap())
        .unwrap_or(1.0);
    let seconds = option("--seconds")
        .map(|v| v.parse::<f64>().unwrap())
        .unwrap_or(600.0);
    let (buffered, position, duration) = (
        Arc::new(AtomicU64::new(0)),
        Arc::new(AtomicU64::new(0)),
        Arc::new(AtomicU64::new(0)),
    );
    let shutdown = Arc::new(AtomicBool::new(false));
    let flush_ring = Arc::new(AtomicBool::new(false));
    let bail_flush = Arc::new(AtomicBool::new(false));
    let ended = Arc::new(AtomicBool::new(false));
    let nerd = Arc::new(Mutex::new(NerdSnapshot::default()));
    let errors = Arc::new(Mutex::new(Vec::new()));
    let (tx, rx) = crossbeam_channel::unbounded();
    let (producer, mut consumer) = rtrb::RingBuffer::new(rate as usize * 2);
    let worker = {
        let buffered = buffered.clone();
        let shutdown = shutdown.clone();
        let nerd = nerd.clone();
        let ended = ended.clone();
        let errors = errors.clone();
        let flush_ring = flush_ring.clone();
        let bail_flush = bail_flush.clone();
        std::thread::spawn(move || {
            run_mixer(
                rx,
                producer,
                buffered,
                position,
                duration,
                rate,
                Arc::new(Events { ended, errors }),
                shutdown,
                flush_ring,
                bail_flush,
                nerd,
            )
        })
    };
    tx.send(Command::SetPreferAppleAac(
        option("--apple-aac").map(String::as_str) == Some("1"),
    ))
    .unwrap();
    tx.send(Command::SetSoundMode(mode)).unwrap();
    tx.send(Command::SetClarityTuning(ClarityTuning {
        preset,
        wet,
        trims_db: vec![0.0; 8],
    }))
    .unwrap();
    tx.send(Command::SetPlaybackSpeed(speed)).unwrap();
    tx.send(Command::SetDecodeChunk(chunk)).unwrap();
    if let Some(dir) = option("--capture") {
        tx.send(Command::StartDiagnosticCapture {
            directory: dir.clone(),
            seconds: 30.0,
        })
        .unwrap();
    }
    let (reply, response) = crossbeam_channel::bounded(1);
    tx.send(Command::Load {
        request: TrackSource {
            source: args[0].clone(),
            title: "Offline fixture".into(),
            artist: String::new(),
            start_seconds: 0.0,
            plan: TransitionPlan::default(),
            headers: HashMap::new(),
            claimed_kbps: 0,
            duration_seconds: 0.0,
            loudness_db: None,
        },
        reply,
    })
    .unwrap();
    let info = response
        .recv_timeout(Duration::from_secs(30))
        .unwrap()
        .unwrap();
    eprintln!(
        "{}: {} Hz, {} channels → {} Hz; {:?}",
        info.codec, info.sample_rate, info.channels, rate, mode
    );
    if let Some(start) = option("--start") {
        // An explicit seek must not use the short-track cue clearance rule.
        // The offline consumer acknowledges the same flush barrier as output.
        // Load also requests a flush. Acknowledge it first so the following
        // wait observes the seek's fresh barrier rather than the load barrier.
        flush_ring.store(false, Ordering::Release);
        bail_flush.store(false, Ordering::Release);
        tx.send(Command::ObserveUnderruns(Arc::new(AtomicU64::new(0))))
            .unwrap();
        tx.send(Command::Seek {
            seconds: start.parse().unwrap(),
        })
        .unwrap();
        // Wait for the worker to request the flush before consuming any old PCM.
        let seek_deadline = Instant::now() + Duration::from_secs(30);
        while !flush_ring.load(Ordering::Acquire) && Instant::now() < seek_deadline {
            std::thread::sleep(Duration::from_micros(100));
        }
        assert!(
            flush_ring.load(Ordering::Acquire),
            "seek was not acknowledged"
        );
        while consumer.pop().is_ok() {}
        buffered.store(0, Ordering::Relaxed);
        flush_ring.store(false, Ordering::Release);
    }
    let mut pcm = Vec::new();
    let deadline = Instant::now() + Duration::from_secs(300);
    while Instant::now() < deadline && pcm.len() < (seconds * rate as f64 * 2.0) as usize {
        let mut n = 0;
        while consumer.slots() >= 2 {
            pcm.push(consumer.pop().unwrap());
            pcm.push(consumer.pop().unwrap());
            n += 2;
        }
        if n > 0 {
            let _ = buffered.fetch_update(Ordering::Relaxed, Ordering::Relaxed, |v| {
                Some(v.saturating_sub(n / 2))
            });
        }
        if ended.load(Ordering::Acquire) {
            break;
        }
        std::thread::sleep(Duration::from_micros(100));
    }
    let (done, finished) = crossbeam_channel::bounded(1);
    tx.send(Command::FinishDiagnosticCapture { reply: Some(done) })
        .unwrap();
    finished
        .recv_timeout(Duration::from_secs(30))
        .unwrap()
        .unwrap();
    tx.send(Command::Shutdown).unwrap();
    shutdown.store(true, Ordering::Release);
    worker.join().unwrap();
    assert!(
        errors.lock().unwrap().is_empty(),
        "Playback errors: {:?}",
        errors.lock().unwrap()
    );
    native_core::diagnostics::write_float_wav(std::path::Path::new(&args[1]), rate, &pcm).unwrap();
    eprintln!("{} frames; {:?}", pcm.len() / 2, nerd.lock().unwrap());
}
