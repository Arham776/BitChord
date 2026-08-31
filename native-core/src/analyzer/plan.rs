//! Compact port of upstream `TransitionPolicy` + `planTransition` for a pair of files.

use super::beat::{self, Grid, WINDOW_SECONDS};
use super::estimate_tempo;
use super::vocal;
use crate::mixer::{TransitionPlan, TransitionStyle};

const MIN_BEATMATCH_CONFIDENCE: f64 = 0.55;
const MIN_DJ_CONFIDENCE: f64 = 0.2;
const MIN_BPM: f64 = 40.0;
const MAX_BPM: f64 = 220.0;
const MAX_STRETCH_DEVIATION: f64 = 0.04;
const VOCAL_ACTIVE_THRESHOLD: f64 = 0.6;
const FILTER_SWEEP: f64 = 1.0;
const AUTO_TRANSITION_MAX_SECONDS: f64 = 12.0;
const AUTO_MIN_SECONDS: f64 = 4.0;
const AUTO_FAST_TRACK_MIN_SECONDS: f64 = 6.0;
/// Pickup inside this margin of the end is the outro, not a mix-in
/// (upstream `incomingCuePoint`: `pickup < duration - 10`).
const MIX_IN_END_MARGIN_SECONDS: f64 = 10.0;

#[derive(Clone, Default)]
struct Analysis {
    bpm: f64,
    beat_interval: f64,
    beat_confidence: f64,
    downbeats: Vec<f64>,
    first_beat: f64,
    duration: f64,
    vocal_mask: Vec<f32>,
    vocal_times: Vec<f64>,
    vocal_probability: f64,
}

#[derive(Clone, Copy, PartialEq, Eq)]
enum Tier {
    Beatmatched,
    DjAssisted,
    Plain,
}

pub fn plan_pair(
    outgoing_path: &str,
    incoming_path: &str,
    crossfade_seconds: f64,
    decode: impl Fn(&str, f64, f64, bool) -> Option<(Vec<f32>, u32, f64)>,
    duration_of: impl Fn(&str) -> f64,
) -> TransitionPlan {
    let fade = if crossfade_seconds > 0.0 {
        crossfade_seconds.clamp(2.0, 12.0)
    } else {
        6.0
    };
    let out = analyze(outgoing_path, &decode, duration_of(outgoing_path));
    let inc = analyze(incoming_path, &decode, duration_of(incoming_path));
    plan_from(&out, &inc, fade)
}

fn analyze(
    path: &str,
    decode: &impl Fn(&str, f64, f64, bool) -> Option<(Vec<f32>, u32, f64)>,
    duration: f64,
) -> Analysis {
    let mut analysis = Analysis {
        duration,
        ..Analysis::default()
    };
    let window = WINDOW_SECONDS;
    let head_len = if duration > 0.0 { window.min(duration) } else { window };

    // Head: mix-in grid + first_beat. Tail (when far enough from the head): mix-out
    // tempo takes precedence, matching TrackAnalyzer's Pass 2 windows.
    if let Some((mono, rate, offset)) = decode(path, 0.0, head_len, true) {
        if let Some(grid) = beat::track(&mono, rate as f64, offset) {
            fill_grid(&mut analysis, grid);
        } else {
            let bpm = estimate_tempo(&mono, rate as f64);
            analysis.bpm = bpm;
            analysis.beat_interval = 60.0 / bpm.max(1.0);
            analysis.beat_confidence = 0.15;
        }
    }
    let tail_start = (duration - window).max(0.0);
    if duration > 0.0 && tail_start > window / 2.0 {
        if let Some((mono, rate, offset)) = decode(path, tail_start, window, true) {
            if let Some(grid) = beat::track(&mono, rate as f64, offset) {
                // Tail tempo is what mix-out beatmatching wants. Mix-in
                // anchors must stay on the head window — merging tail
                // downbeats (t ≈ duration − WINDOW) into the same list made
                // `incoming_cue` pick a point in the outro, so the next
                // song started a few seconds from its end.
                let first = analysis.first_beat;
                let downbeats = analysis.downbeats.clone();
                fill_grid(&mut analysis, grid);
                analysis.first_beat = first;
                analysis.downbeats = downbeats;
            }
        }
    }

    ingest_vocals(&mut analysis, path, 0.0, head_len.min(22.8), decode);
    if duration > 0.0 && tail_start > window / 2.0 {
        ingest_vocals(&mut analysis, path, tail_start, 22.8, decode);
    }
    if !analysis.vocal_mask.is_empty() {
        analysis.vocal_probability = analysis.vocal_mask.iter().map(|v| *v as f64).sum::<f64>()
            / analysis.vocal_mask.len() as f64;
    }
    analysis
}

fn ingest_vocals(
    analysis: &mut Analysis,
    path: &str,
    start: f64,
    duration: f64,
    decode: &impl Fn(&str, f64, f64, bool) -> Option<(Vec<f32>, u32, f64)>,
) {
    let Some((stereo, rate, offset)) = decode(path, start, duration, false) else {
        return;
    };
    let (left, right) = split_stereo(&stereo);
    let Some(mask) = vocal::track(&left, &right, rate as f64) else {
        return;
    };
    let hop = vocal::HOP as f64 / vocal::SAMPLE_RATE;
    for (index, value) in mask.into_iter().enumerate() {
        analysis.vocal_times.push(offset + index as f64 * hop);
        analysis.vocal_mask.push(value);
    }
}

fn fill_grid(analysis: &mut Analysis, grid: Grid) {
    analysis.bpm = grid.bpm;
    analysis.beat_interval = grid.beat_interval;
    analysis.beat_confidence = grid.beat_confidence;
    analysis.downbeats = grid.downbeats;
    analysis.first_beat = grid.first_beat;
}

fn split_stereo(interleaved: &[f32]) -> (Vec<f32>, Vec<f32>) {
    let mut left = Vec::with_capacity(interleaved.len() / 2);
    let mut right = Vec::with_capacity(interleaved.len() / 2);
    for pair in interleaved.chunks_exact(2) {
        left.push(pair[0]);
        right.push(pair[1]);
    }
    (left, right)
}

fn plan_from(outgoing: &Analysis, incoming: &Analysis, fade: f64) -> TransitionPlan {
    let tier = assess(outgoing, incoming);
    let cue = incoming_cue(incoming);
    if matches!(tier, Tier::Plain) {
        return TransitionPlan {
            style: TransitionStyle::EqualPower,
            bass_swap: false,
            bass_swap_fraction: 0.7,
            filter_sweep: 0.0,
            vocal_overlap: 0.0,
            fade_seconds: fade,
            cue_seconds: cue,
            playback_rate: 1.0,
        };
    }

    let out_bpm = outgoing.bpm;
    let in_bpm = incoming.bpm;
    let ratio = normalized_tempo_ratio(out_bpm, in_bpm);
    let same_beat = (1.0 - ratio).abs() <= 0.05
        && (outgoing.beat_confidence >= 0.2 || incoming.beat_confidence >= 0.2);
    let playback_rate = if (0.9..=1.1).contains(&ratio) {
        ((1.0 / ratio).clamp(0.9, 1.1) * 10_000.0).round() / 10_000.0
    } else {
        1.0
    };
    let vocal_conflict = outgoing.vocal_probability >= 0.62 && incoming.vocal_probability >= 0.62;
    let overlap_beats = if !vocal_conflict && (1.0 - ratio).abs() > 0.07 {
        16.0
    } else {
        8.0
    };
    let beat_seconds = if out_bpm > 0.0 { 60.0 / out_bpm } else { 0.5 };
    let min_overlap = if out_bpm >= 140.0 {
        AUTO_FAST_TRACK_MIN_SECONDS
    } else {
        AUTO_MIN_SECONDS
    };
    let overlap = (overlap_beats * beat_seconds).clamp(min_overlap, AUTO_TRANSITION_MAX_SECONDS);
    let vocal_overlap = vocal_overlap_amount(outgoing, incoming, overlap, cue, playback_rate);

    TransitionPlan {
        style: if same_beat && matches!(tier, Tier::Beatmatched) {
            TransitionStyle::DjBlend
        } else {
            TransitionStyle::DjFilter
        },
        bass_swap: true,
        bass_swap_fraction: 0.7,
        filter_sweep: if same_beat { 0.0 } else { FILTER_SWEEP },
        vocal_overlap,
        fade_seconds: overlap.max(fade.min(AUTO_TRANSITION_MAX_SECONDS)),
        cue_seconds: cue,
        playback_rate,
    }
}

fn assess(outgoing: &Analysis, incoming: &Analysis) -> Tier {
    if !(MIN_BPM..=MAX_BPM).contains(&outgoing.bpm) || !(MIN_BPM..=MAX_BPM).contains(&incoming.bpm) {
        return Tier::Plain;
    }
    if outgoing.beat_confidence < MIN_DJ_CONFIDENCE && incoming.beat_confidence < MIN_DJ_CONFIDENCE {
        return Tier::Plain;
    }
    let stretch = outgoing.bpm / align_tempo_octave(outgoing.bpm, incoming.bpm).max(1e-6);
    let far = (stretch - 1.0).abs() > MAX_STRETCH_DEVIATION;
    let weak = outgoing.beat_confidence < MIN_BEATMATCH_CONFIDENCE
        || incoming.beat_confidence < MIN_BEATMATCH_CONFIDENCE;
    if far || weak {
        Tier::DjAssisted
    } else {
        Tier::Beatmatched
    }
}

fn align_tempo_octave(outgoing_bpm: f64, incoming_bpm: f64) -> f64 {
    if outgoing_bpm <= 0.0 || incoming_bpm <= 0.0 {
        return incoming_bpm;
    }
    let mut aligned = incoming_bpm;
    while aligned / outgoing_bpm > 1.5 {
        aligned /= 2.0;
    }
    while aligned / outgoing_bpm < 0.67 {
        aligned *= 2.0;
    }
    aligned
}

fn normalized_tempo_ratio(current: f64, next: f64) -> f64 {
    if current <= 0.0 || next <= 0.0 {
        return 1.0;
    }
    let mut ratio = next / current;
    while ratio > 1.5 {
        ratio /= 2.0;
    }
    while ratio < 0.67 {
        ratio *= 2.0;
    }
    ratio
}

fn incoming_cue(analysis: &Analysis) -> f64 {
    let duration = analysis.duration;
    let in_mix_in_window = |t: f64| {
        t >= 0.0 && (duration <= 0.0 || t < duration - MIX_IN_END_MARGIN_SECONDS)
    };
    let pickup = analysis.first_beat.max(0.0);
    if pickup > 0.0 && in_mix_in_window(pickup) {
        if let Some(db) = analysis
            .downbeats
            .iter()
            .copied()
            .find(|t| *t >= pickup && in_mix_in_window(*t))
        {
            return db;
        }
        return pickup;
    }
    if analysis.downbeats.len() >= 8 {
        let t = analysis.downbeats[8.min(analysis.downbeats.len() - 1)];
        if in_mix_in_window(t) {
            return t;
        }
    }
    // A late-only grid is the outro. Starting at 0 is the unanalysed fallback,
    // not a cue into the last bars.
    0.0
}

fn vocal_overlap_amount(
    outgoing: &Analysis,
    incoming: &Analysis,
    overlap: f64,
    cue: f64,
    rate: f64,
) -> f64 {
    if outgoing.vocal_mask.is_empty() || incoming.vocal_mask.is_empty() {
        return 0.0;
    }
    // Head-window analyses: treat the overlap as the last `overlap` seconds of
    // the captured outgoing mask against the incoming mask from `cue`.
    let out_end = outgoing
        .vocal_times
        .last()
        .copied()
        .unwrap_or(0.0);
    let out_start = (out_end - overlap).max(0.0);
    let mut both = 0;
    let mut total = 0;
    let mut in_index = 0usize;
    for (index, time) in outgoing.vocal_times.iter().copied().enumerate() {
        if time < out_start {
            continue;
        }
        if time > out_end {
            break;
        }
        total += 1;
        if outgoing.vocal_mask[index] < VOCAL_ACTIVE_THRESHOLD as f32 {
            continue;
        }
        let target = cue + (time - out_start) * rate;
        while in_index + 1 < incoming.vocal_times.len()
            && incoming.vocal_times[in_index + 1] <= target
        {
            in_index += 1;
        }
        if in_index < incoming.vocal_mask.len()
            && incoming.vocal_mask[in_index] >= VOCAL_ACTIVE_THRESHOLD as f32
        {
            both += 1;
        }
    }
    if total == 0 {
        0.0
    } else {
        both as f64 / total as f64
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn analysis(first_beat: f64, duration: f64, downbeats: Vec<f64>) -> Analysis {
        Analysis {
            first_beat,
            duration,
            downbeats,
            ..Analysis::default()
        }
    }

    #[test]
    fn incoming_cue_uses_head_downbeat_not_outro() {
        let cue = incoming_cue(&analysis(
            1.2,
            200.0,
            vec![1.2, 3.0, 5.0, 180.0, 184.0, 188.0, 192.0, 196.0, 198.0],
        ));
        assert!(
            (cue - 1.2).abs() < 1e-9,
            "cue {cue} should be the first mix-in downbeat, not the outro"
        );
    }

    #[test]
    fn incoming_cue_does_not_index_into_sorted_outro_beats() {
        // The old fallback picked downbeats[8] after merging and sorting tail
        // times, which for a 3-minute track is ~duration − WINDOW.
        let cue = incoming_cue(&analysis(
            0.0,
            180.0,
            vec![150.0, 154.0, 158.0, 162.0, 166.0, 170.0, 174.0, 176.0, 178.0],
        ));
        assert_eq!(cue, 0.0, "outro-only grid must not become a mix-in cue");
    }

    #[test]
    fn incoming_cue_rejects_pickup_in_the_last_ten_seconds() {
        let cue = incoming_cue(&analysis(175.0, 180.0, vec![175.0, 177.0, 179.0]));
        assert_eq!(cue, 0.0);
    }
}
