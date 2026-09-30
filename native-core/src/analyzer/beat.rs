//! Port of upstream `BeatTracker.kt` — Beat This! over the Slaney mel spectrogram.

use super::models;
use super::{
    compute_beat_spectrogram, resample, BEAT_SPECTROGRAM_MELS, BEAT_SPECTROGRAM_SAMPLE_RATE,
};

use rten_tensor::NdTensor;

pub const CHUNK_FRAMES: usize = 1500;
pub const BORDER_FRAMES: usize = 6;
pub const WINDOW_SECONDS: f64 = (CHUNK_FRAMES - 2 * BORDER_FRAMES) as f64 / 50.0;
const PEAK_WINDOW: i32 = 7;
const MIN_BEATS: usize = 8;
const MIN_TEMPO: f64 = 40.0;
const MAX_TEMPO: f64 = 220.0;
const FRAME_RATE: f64 = 50.0;

#[derive(Debug, Clone)]
pub struct Grid {
    pub beats: Vec<f64>,
    pub downbeats: Vec<f64>,
    pub bpm: f64,
    pub beat_interval: f64,
    pub first_beat: f64,
    pub beat_confidence: f64,
}

/// Track [pcm] already at any rate; resampled to the model's 22.05 kHz mono.
pub fn track(pcm: &[f32], sample_rate: f64, offset_seconds: f64) -> Option<Grid> {
    if pcm.is_empty() {
        return None;
    }
    let mono = if (sample_rate - BEAT_SPECTROGRAM_SAMPLE_RATE).abs() > 1.0 {
        resample(pcm, sample_rate, BEAT_SPECTROGRAM_SAMPLE_RATE)
    } else {
        pcm.to_vec()
    };
    let spectrogram = compute_beat_spectrogram(&mono, BEAT_SPECTROGRAM_SAMPLE_RATE);
    if spectrogram.frames == 0 {
        return None;
    }
    let (beat_logits, downbeat_logits) = infer(&spectrogram.values, spectrogram.frames)?;
    let beat_frames = pick_peaks(&beat_logits);
    let beats: Vec<f64> = beat_frames
        .iter()
        .map(|f| f / FRAME_RATE + offset_seconds)
        .collect();
    if beats.len() < MIN_BEATS {
        return None;
    }
    let bpm = tempo_from_beats(&beats);
    if bpm <= 0.0 {
        return None;
    }
    let downbeats: Vec<f64> = pick_peaks(&downbeat_logits)
        .into_iter()
        .map(|f| f / FRAME_RATE + offset_seconds)
        .map(|time| {
            beats
                .iter()
                .min_by(|a, b| (*a - time).abs().total_cmp(&(*b - time).abs()))
                .copied()
                .unwrap_or(beats[0])
        })
        .collect();
    let mut downbeats = downbeats;
    downbeats.sort_by(|a, b| a.total_cmp(b));
    downbeats.dedup_by(|a, b| (*a - *b).abs() < 1e-4);

    let peak_logits: Vec<f64> = beat_frames
        .iter()
        .map(|frame| {
            let i = frame.round() as isize;
            if i >= 0 && (i as usize) < beat_logits.len() {
                beat_logits[i as usize] as f64
            } else {
                0.0
            }
        })
        .collect();

    Some(Grid {
        bpm,
        beat_interval: 60.0 / bpm,
        first_beat: beats[0],
        beat_confidence: grid_confidence(&beats, &peak_logits),
        beats,
        downbeats,
    })
}

fn infer(values: &[f32], frames: usize) -> Option<(Vec<f32>, Vec<f32>)> {
    models::with_beat(|model| infer_chunks(model, values, frames)).flatten()
}

fn infer_chunks(
    model: &rten::Model,
    values: &[f32],
    frames: usize,
) -> Option<(Vec<f32>, Vec<f32>)> {
    let mels = BEAT_SPECTROGRAM_MELS;
    let input_id = *model.input_ids().first()?;
    let stride = CHUNK_FRAMES - 2 * BORDER_FRAMES;
    let mut beat_logits = vec![0.0f32; frames];
    let mut downbeat_logits = vec![0.0f32; frames];
    let mut start = 0usize;
    while start < frames {
        let length = CHUNK_FRAMES.min(frames - start);
        if length <= 2 * BORDER_FRAMES && start > 0 {
            break;
        }
        let chunk = values[start * mels..(start + length) * mels].to_vec();
        let tensor = NdTensor::from_data([1, length, mels], chunk);
        let outputs = model
            .run(vec![(input_id, tensor.into())], model.output_ids(), None)
            .ok()?;
        if outputs.len() < 2 {
            return None;
        }
        let beat = flatten_f32(&outputs[0])?;
        let downbeat = flatten_f32(&outputs[1])?;
        let keep_from = if start == 0 { 0 } else { BORDER_FRAMES };
        let keep_to = if start + length >= frames {
            length
        } else {
            length.saturating_sub(BORDER_FRAMES)
        };
        for index in keep_from..keep_to {
            let target = start + index;
            if target >= frames {
                break;
            }
            if index < beat.len() {
                beat_logits[target] = beat[index];
            }
            if index < downbeat.len() {
                downbeat_logits[target] = downbeat[index];
            }
        }
        if start + length >= frames {
            break;
        }
        start += stride;
    }
    Some((beat_logits, downbeat_logits))
}

fn flatten_f32(value: &rten::Value) -> Option<Vec<f32>> {
    super::models::flatten_f32(value)
}

/// Frame indices that are local maxima over [PEAK_WINDOW] and positive.
pub fn pick_peaks(logits: &[f32]) -> Vec<f64> {
    let half = PEAK_WINDOW / 2;
    let mut peaks = Vec::new();
    for index in 0..logits.len() {
        if logits[index] <= 0.0 {
            continue;
        }
        let mut is_maximum = true;
        for offset in -half..=half {
            let neighbour = index as i32 + offset;
            if neighbour < 0 || neighbour as usize >= logits.len() {
                continue;
            }
            if logits[neighbour as usize] > logits[index] {
                is_maximum = false;
                break;
            }
        }
        if is_maximum {
            peaks.push(index as i32);
        }
    }

    let mut deduped = Vec::new();
    let mut index = 0usize;
    while index < peaks.len() {
        let mut mean = peaks[index] as f64;
        let mut count = 1.0;
        while index + 1 < peaks.len() && (peaks[index + 1] as f64 - mean) <= 1.0 {
            index += 1;
            count += 1.0;
            mean += (peaks[index] as f64 - mean) / count;
        }
        deduped.push(mean.round() as usize);
        index += 1;
    }

    deduped
        .into_iter()
        .map(|frame| {
            if frame == 0 || frame + 1 >= logits.len() {
                return frame as f64;
            }
            let left = logits[frame - 1] as f64;
            let centre = logits[frame] as f64;
            let right = logits[frame + 1] as f64;
            let denominator = left - 2.0 * centre + right;
            if denominator.abs() <= 1e-9 {
                return frame as f64;
            }
            frame as f64 + (0.5 * (left - right) / denominator).clamp(-0.5, 0.5)
        })
        .collect()
}

pub fn tempo_from_beats(beats: &[f64]) -> f64 {
    if beats.len() < MIN_BEATS {
        return 0.0;
    }
    let gaps: Vec<f64> = beats.windows(2).map(|w| w[1] - w[0]).collect();
    let rough = median(&gaps);
    if rough <= 0.0 {
        return 0.0;
    }
    let kept: Vec<f64> = gaps
        .iter()
        .copied()
        .filter(|g| (g - rough).abs() <= rough * 0.2)
        .collect();
    let interval = median(if kept.len() >= 4 { &kept } else { &gaps });
    if interval <= 0.0 {
        return 0.0;
    }
    let bpm = 60.0 / interval;
    if (MIN_TEMPO..=MAX_TEMPO).contains(&bpm) {
        bpm
    } else {
        0.0
    }
}

pub fn grid_confidence(beats: &[f64], peak_logits: &[f64]) -> f64 {
    if beats.len() < MIN_BEATS {
        return 0.0;
    }
    let gaps: Vec<f64> = beats.windows(2).map(|w| w[1] - w[0]).collect();
    let interval = median(&gaps);
    if interval <= 0.0 {
        return 0.0;
    }
    let regular = gaps
        .iter()
        .filter(|g| (*g - interval).abs() <= interval * 0.1)
        .count() as f64
        / gaps.len() as f64;
    let strength = 1.0 / (1.0 + (-(median(peak_logits) - 0.5)).exp());
    (0.35 + 0.4 * regular + 0.25 * strength).clamp(0.0, 0.95)
}

fn median(values: &[f64]) -> f64 {
    if values.is_empty() {
        return 0.0;
    }
    let mut sorted = values.to_vec();
    sorted.sort_by(|a, b| a.total_cmp(b));
    sorted[sorted.len() / 2]
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn tempo_from_regular_120_bpm_grid() {
        let beats: Vec<f64> = (0..16).map(|i| i as f64 * 0.5).collect();
        let bpm = tempo_from_beats(&beats);
        assert!((bpm - 120.0).abs() < 0.5, "bpm {bpm}");
        let conf = grid_confidence(&beats, &vec![2.0; beats.len()]);
        assert!(conf > 0.7, "conf {conf}");
    }
}
