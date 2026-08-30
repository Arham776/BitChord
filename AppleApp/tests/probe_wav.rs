use native_core::decode::{SourceKind, SymphoniaDecoder};

#[test]
fn probe_real_wav() {
    let path = std::env::home_dir().map(|h| h).unwrap_or_default();
    let wav = format!("{}/Music/BitChordTest/Track A - Morning Tone.wav", std::env::var("HOME").unwrap());
    let mut d = SymphoniaDecoder::open(&SourceKind::Path(wav)).expect("open");
    println!("rate={} channels={} duration={:?} frames={:?}", d.sample_rate(), d.channels(), d.duration_seconds(), d.decoded_frames());
    let mut total = 0;
    loop {
        let chunk = d.read_stereo(1024).unwrap();
        if chunk.is_empty() { break; }
        total += chunk.len() / 2;
    }
    println!("decoded frames={} position={}", total, d.position_seconds());
}
