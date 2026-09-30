//! Low-level Reference response for comparison against Lastwave's actual C++.
use native_core::{sound::Clarity, ClarityPreset, ClarityTuning, SoundMode};
use std::io::Write;
fn main() {
    let a: Vec<String> = std::env::args().skip(1).collect();
    let rate: u32 = a[0].parse().unwrap();
    let hz: f64 = a[1].parse().unwrap();
    let side = a[2] == "1";
    let mut x: Vec<f32> = (0..rate)
        .flat_map(|i| {
            let x = 0.001 * (2.0 * std::f64::consts::PI * hz * i as f64 / rate as f64).sin() as f32;
            [x, if side { -x } else { x }]
        })
        .collect();
    let mut c = Clarity::new(rate);
    let preset = match a.get(4).map(String::as_str) {
        Some("1") => ClarityPreset::Speaker,
        Some("2") => ClarityPreset::Headphone,
        Some("3") => ClarityPreset::Dac,
        _ => ClarityPreset::Reference,
    };
    c.set(
        SoundMode::Enhanced,
        ClarityTuning {
            preset,
            ..Default::default()
        },
    );
    c.process(&mut x);
    let mut f = std::fs::File::create(&a[3]).unwrap();
    for s in x {
        f.write_all(&s.to_le_bytes()).unwrap();
    }
}
