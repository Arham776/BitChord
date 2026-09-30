use native_core::decode::{SourceKind, SymphoniaDecoder};
fn main() {
    env_logger::init();
    let a: Vec<String> = std::env::args().collect();
    let mut d = SymphoniaDecoder::open(&SourceKind::parse(&a[1]), &Default::default()).unwrap();
    eprintln!(
        "before {:?} / {}",
        d.duration_seconds(),
        d.position_seconds()
    );
    d.seek_seconds(a[3].parse().unwrap()).unwrap();
    eprintln!("after seek {}", d.position_seconds());
    let mut pcm = Vec::new();
    loop {
        let x = d.read_stereo(4096).unwrap();
        if x.is_empty() {
            break;
        }
        pcm.extend(x);
    }
    eprintln!(
        "{} frames, position {}",
        pcm.len() / 2,
        d.position_seconds()
    );
    native_core::diagnostics::write_float_wav(std::path::Path::new(&a[2]), d.sample_rate(), &pcm)
        .unwrap();
}
