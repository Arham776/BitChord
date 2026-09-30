//! Complete-source gated R128 measurement on decoded internal stereo PCM.
//! Called from a background analysis task, never the mixer or device callback.
use crate::{
    decode::{SourceKind, SymphoniaDecoder},
    LoudnessMeasurement,
};
use ebur128::{EbuR128, Mode};
use std::{collections::HashMap, path::Path};
pub fn measure(source: &str) -> Result<LoudnessMeasurement, String> {
    if source.starts_with("http:") || source.starts_with("https:") {
        return Err("Loudness measurement requires a complete local source".into());
    }
    if Path::new(&format!("{source}.grow")).exists()
        && !Path::new(&format!("{source}.complete")).exists()
    {
        return Err("Loudness measurement requires the complete recording".into());
    }
    let mut decoder = SymphoniaDecoder::open_available(&SourceKind::parse(source), &HashMap::new())
        .map_err(|e| e.to_string())?;
    let mut meter = EbuR128::new(
        2,
        decoder.sample_rate(),
        Mode::I | Mode::TRUE_PEAK | Mode::HISTOGRAM,
    )
    .map_err(|e| e.to_string())?;
    loop {
        let pcm = decoder.read_stereo(4096).map_err(|e| e.to_string())?;
        if pcm.is_empty() {
            break;
        }
        meter.add_frames_f32(&pcm).map_err(|e| e.to_string())?;
    }
    let track_lufs = meter.loudness_global().map_err(|e| e.to_string())?;
    if !track_lufs.is_finite() {
        return Err("The recording has no gated loudness measurement".into());
    }
    let peak = meter
        .true_peak(0)
        .map_err(|e| e.to_string())?
        .max(meter.true_peak(1).map_err(|e| e.to_string())?);
    Ok(LoudnessMeasurement {
        track_lufs,
        album_lufs: None,
        true_peak_dbtp: if peak > 0.0 {
            Some(20.0 * peak.log10())
        } else {
            None
        },
    })
}
#[cfg(test)]
mod tests {
    use super::*;
    // BS.1770 calibration: two identical 1 kHz channels at -23 dBFS sample
    // amplitude measure near -23 LUFS (summed channels cancel sine RMS loss).
    #[test]
    fn calibrated_stereo_tone_and_gating() {
        let mut meter = EbuR128::new(2, 48000, Mode::I | Mode::TRUE_PEAK).unwrap();
        let tone: Vec<f32> = (0..48000 * 10)
            .flat_map(|i| {
                let s = 10f32.powf(-23.0 / 20.0)
                    * (2.0 * std::f32::consts::PI * 1000.0 * i as f32 / 48000.0).sin();
                [s, s]
            })
            .collect();
        meter.add_frames_f32(&tone).unwrap();
        let measured = meter.loudness_global().unwrap();
        assert!((measured + 23.0).abs() < 0.1, "{measured}");
        meter.add_frames_f32(&vec![0.0; 48000 * 2 * 3]).unwrap();
        assert!((meter.loudness_global().unwrap() - measured).abs() < 0.2);
    }
}
