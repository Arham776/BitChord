//! Compact port of upstream `TransitionPolicy` + `planTransition` for a pair of files.

use super::audio_analysis;
use super::beat::{self, Grid, WINDOW_SECONDS};
use super::resample;
use super::vocal;
use crate::mixer::{TransitionPlan, TransitionStyle};

const MIN_BEATMATCH_CONFIDENCE: f64 = 0.55;
const MIN_DJ_CONFIDENCE: f64 = 0.2;
const MIN_BPM: f64 = 40.0;
const MAX_BPM: f64 = 220.0;
const MAX_STRETCH_DEVIATION: f64 = 0.04;
const VOCAL_ACTIVE_THRESHOLD: f64 = 0.6;
const FILTER_SWEEP: f64 = 1.0;
const AUTO_TRANSITION_MAX_BEATS: f64 = 16.0;
const AUTO_TRANSITION_MAX_SECONDS: f64 = 12.0;
const AUTO_MIN_SECONDS: f64 = 4.0;
const AUTO_FAST_TRACK_MIN_SECONDS: f64 = 6.0;
/// Upstream `AUTO_FALLBACK_SECONDS` — the fade used when no analysis landed.
const AUTO_FALLBACK_SECONDS: f64 = 8.0;
/// Upstream `MIN_SMART_DURATION_SECONDS` — a track shorter than this gets a
/// plain crossfade rather than a smart transition.
const MIN_SMART_DURATION_SECONDS: f64 = 45.0;
/// Pickup inside this margin of the end is the outro, not a mix-in
/// (upstream `incomingCuePoint`: `pickup < duration - 10`).
const MIX_IN_END_MARGIN_SECONDS: f64 = 10.0;
/// Upstream bass-swap tuning constants (TransitionPlanner.kt:351-364).
const HANDOFF_FRACTION: f64 = 0.5;
const DEFAULT_BASS_SWAP_FRACTION: f64 = 0.7;
const MAX_BASS_SWAP_FRACTION: f64 = 0.85;
const MIN_BASS_STRUCTURE_SCORE: f64 = 0.25;
const BASS_SWAP_MAX_SECONDS: f64 = 6.0;
/// Upstream gapless handoff length (TransitionPlanner.kt:901).
const GAPLESS_FADE_SECONDS: f64 = 0.12;
/// Upstream `MAX_DISCARDED_MUSIC_SECONDS` — a mix-out anchor may not skip more
/// than this much audible music.
const MAX_DISCARDED_MUSIC_SECONDS: f64 = 12.0;
/// Upstream `AUDIBLE_ENERGY_FRACTION` — the energy threshold that counts a
/// point as audible when measuring skipped music.
const AUDIBLE_ENERGY_FRACTION: f64 = 0.1;
/// Upstream WSOLA phrase-switch constants (TransitionPlanner.kt:329-374).
const MIN_FADE_BEATS: usize = 4;
const MAX_FADE_BEATS: usize = 16;
const MAX_OVERLAP_SECONDS: f64 = 16.0;
const ARRANGEMENT_OVERLAP_BEATS: f64 = 8.0;
const MIN_CLEARANCE_SECONDS: f64 = 5.0;
const VOCAL_CLASH_TOLERANCE: f64 = 0.05;

#[derive(Clone, Default)]
struct Analysis {
    bpm: f64,
    beat_interval: f64,
    beat_confidence: f64,
    downbeats: Vec<f64>,
    first_beat: f64,
    duration: f64,
    /// Detected key (e.g. "C major") and its confidence — phase-1
    /// `AnalyzeKeyAndTimbre`.
    key: String,
    key_confidence: f64,
    /// Where the audible content ends (trailing silence trimmed) — phase-1
    /// `AnalyzeEnvelope`. 0 means unknown.
    content_end: f64,
    outro_start: f64,
    mix_out_time: f64,
    mix_in_time: f64,
    audible_start_time: f64,
    mix_in_candidates: Vec<audio_analysis::MixCuePoint>,
    mix_out_candidates: Vec<audio_analysis::MixCuePoint>,
    energy_curve: Vec<audio_analysis::EnergyPoint>,
    low_energy_curve: Vec<audio_analysis::EnergyPoint>,
    /// DSP per-frame vocal mask (parallel to `energy_curve`), from
    /// `AnalyzeKeyAndTimbre`. Drives `vocalActivityBetween` /
    /// `simultaneousVocalFraction`.
    vocal_activity_mask: Vec<f64>,
    /// The full beat grid, for downbeat snapping.
    beats: Vec<f64>,
    vocal_mask: Vec<f32>,
    vocal_times: Vec<f64>,
    /// Whole-track DSP vocal heuristic (`AnalyzeKeyAndTimbre`), not the model
    /// mask mean.
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
    outgoing_text: &str,
    incoming_text: &str,
    album_sequential: bool,
    crossfade_seconds: f64,
    skip_vocals: bool,
    decode: impl Fn(&str, f64, f64, bool) -> Option<(Vec<f32>, u32, f64)>,
    duration_of: impl Fn(&str) -> f64,
) -> TransitionPlan {
    let fade = if crossfade_seconds > 0.0 {
        crossfade_seconds.clamp(1.0, 12.0)
    } else {
        AUTO_FALLBACK_SECONDS
    };
    // Upstream `BLOCKED_TEXT`: spoken or already-performed material is never
    // smart-mixed — fall back to a plain equal-power crossfade.
    if blocked_text(outgoing_text) || blocked_text(incoming_text) {
        return plain_fallback(fade);
    }
    let out = analyze(outgoing_path, skip_vocals, &decode, duration_of(outgoing_path));

    // Upstream gapless path (TransitionPlanner.kt:893-905): an album played
    // through in order gets a seamless 0.12 s handoff instead of a mix, unless
    // the outgoing track has an interior energy cliff worth mixing out of.
    if album_sequential {
        let (anchor, _) = resolve_mix_out_anchor(&out);
        let end = if out.content_end > 0.0 {
            out.content_end
        } else {
            out.duration
        };
        let has_interior_mix_out = anchor > 0.0 && anchor < end - 1.0;
        if !has_interior_mix_out {
            return TransitionPlan {
                style: TransitionStyle::Gapless,
                bass_swap: false,
                bass_swap_fraction: DEFAULT_BASS_SWAP_FRACTION,
                filter_sweep: 0.0,
                vocal_overlap: 0.0,
                fade_seconds: GAPLESS_FADE_SECONDS,
                cue_seconds: 0.0,
                playback_rate: 1.0,
            };
        }
    }

    let inc = analyze(incoming_path, skip_vocals, &decode, duration_of(incoming_path));

    // The most ambitious move: a beat-matched, harmonically-compatible pair gets
    // a WSOLA phrase-switch before the adaptive overlap (upstream `phraseSwitch`).
    if let Some(plan) = phrase_switch(&out, &inc) {
        return plan;
    }
    plan_from(&out, &inc, fade)
}

/// The plain equal-power fallback shared by the speech guard and the tier.
fn plain_fallback(fade: f64) -> TransitionPlan {
    TransitionPlan {
        style: TransitionStyle::EqualPower,
        bass_swap: false,
        bass_swap_fraction: DEFAULT_BASS_SWAP_FRACTION,
        filter_sweep: 0.0,
        vocal_overlap: 0.0,
        fade_seconds: fade,
        cue_seconds: 0.0,
        playback_rate: 1.0,
    }
}

/// Upstream `BLOCKED_TEXT` regex — `\b(podcast|episode|audiobook|live|concert|performance)\b`
/// case-insensitive — checked with word boundaries, no regex dependency.
fn blocked_text(text: &str) -> bool {
    const BLOCKED: [&str; 6] = [
        "podcast",
        "episode",
        "audiobook",
        "live",
        "concert",
        "performance",
    ];
    let lower = text.to_lowercase();
    let bytes = lower.as_bytes();
    for word in BLOCKED {
        let mut start = 0;
        while let Some(relative) = lower[start..].find(word) {
            let absolute = start + relative;
            let before_ok = absolute == 0 || !bytes[absolute - 1].is_ascii_alphanumeric();
            let end = absolute + word.len();
            let after_ok = end == bytes.len() || !bytes[end].is_ascii_alphanumeric();
            if before_ok && after_ok {
                return true;
            }
            start = absolute + word.len();
        }
    }
    false
}

fn analyze(
    path: &str,
    skip_vocals: bool,
    decode: &impl Fn(&str, f64, f64, bool) -> Option<(Vec<f32>, u32, f64)>,
    duration: f64,
) -> Analysis {
    let mut analysis = Analysis {
        duration,
        ..Analysis::default()
    };
    let head_len = if duration > 0.0 {
        WINDOW_SECONDS.min(duration)
    } else {
        WINDOW_SECONDS
    };

    // Whole-track DSP analysis — envelope, tempo (PLL), key/chroma, spectral
    // bands, structure, and the DSP vocal heuristic. This is upstream's
    // `AnalyzeAudio`, the evidence the policy works from when the Beat This!
    // model is absent (which is the shipped state).
    if duration > 0.0 {
        if let Some((mono, rate, _)) = decode(path, 0.0, duration, true) {
            let mono_analysis = resample(&mono, rate as f64, audio_analysis::ANALYSIS_RATE);
            let audio = audio_analysis::analyze_audio(
                &mono_analysis,
                audio_analysis::ANALYSIS_RATE,
                duration,
            );
            analysis.bpm = audio.bpm;
            analysis.beat_interval = audio.beat_interval;
            analysis.beat_confidence = audio.beat_confidence;
            analysis.downbeats = audio.downbeats;
            analysis.first_beat = audio.first_beat;
            analysis.key = audio.key;
            analysis.key_confidence = audio.key_confidence;
            analysis.content_end = audio.content_end_time;
            analysis.outro_start = audio.outro_start_time;
            analysis.mix_out_time = audio.mix_out_time;
            analysis.mix_in_time = audio.mix_in_time;
            analysis.audible_start_time = audio.audible_start_time;
            analysis.mix_in_candidates = audio.mix_in_candidates;
            analysis.mix_out_candidates = audio.mix_out_candidates;
            analysis.energy_curve = audio.energy_curve;
            analysis.low_energy_curve = audio.low_energy_curve;
            analysis.vocal_activity_mask = audio.vocal_activity_mask;
            analysis.beats = audio.beats;
            analysis.vocal_probability = audio.vocal_probability;
        }
    }

    // The Beat This! ONNX grid, when loaded, overrides the DSP tempo with a
    // stronger beat/downbeat grid on the head window.
    if let Some((mono, rate, offset)) = decode(path, 0.0, head_len, true) {
        if let Some(grid) = beat::track(&mono, rate as f64, offset) {
            fill_grid(&mut analysis, grid);
        }
    }

    // EFFICIENT tier: the beat grid (small graph) stays, the open-unmix vocal
    // model (the expensive half) does not run. The per-frame mask it produces
    // drives vocal-clash avoidance; the scalar `vocal_probability` above stays
    // the DSP heuristic, matching upstream's two-signal split.
    if !skip_vocals {
        let vocal_window = vocal::MAX_WINDOW_SECONDS;
        ingest_vocals(&mut analysis, path, 0.0, head_len.min(vocal_window), decode);
        // Upstream `mergeMasks`: the open-unmix head mask is higher quality than
        // the DSP heuristic, so where it exists it overrides the DSP mask on the
        // energy-curve grid.
        merge_open_unmix_mask(&mut analysis);
    }
    analysis
}

/// Resamples the open-unmix head mask onto the energy-curve grid and overrides
/// the DSP vocal mask where the open-unmix mask covers (upstream `mergeMasks`).
fn merge_open_unmix_mask(analysis: &mut Analysis) {
    if analysis.vocal_mask.is_empty() || analysis.vocal_times.is_empty() {
        return;
    }
    let last_vocal_time = *analysis.vocal_times.last().unwrap();
    let mut cursor = 0usize;
    for (index, point) in analysis.energy_curve.iter().enumerate() {
        if point.time > last_vocal_time + 0.5 {
            break; // beyond the head window; the DSP mask stands.
        }
        while cursor + 1 < analysis.vocal_times.len()
            && (analysis.vocal_times[cursor + 1] - point.time).abs()
                < (analysis.vocal_times[cursor] - point.time).abs()
        {
            cursor += 1;
        }
        if cursor < analysis.vocal_mask.len() && index < analysis.vocal_activity_mask.len() {
            let probability = (analysis.vocal_mask[cursor] as f64
                * if point.energy > 0.25 { 1.0 } else { 0.3 })
            .clamp(0.0, 1.0);
            analysis.vocal_activity_mask[index] = probability;
        }
    }
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

// ---- Bass-swap placement (upstream `bassSwapFractionFor`) ------------------

fn average_low_energy(
    curve: &[audio_analysis::EnergyPoint],
    from: f64,
    until: f64,
) -> Option<f64> {
    if until <= from {
        return None;
    }
    let mut index = curve.partition_point(|p| p.time < from);
    let mut sum = 0.0;
    let mut count = 0usize;
    while index < curve.len() && curve[index].time < until {
        let point = &curve[index];
        if point.time.is_finite() && point.energy.is_finite() && point.energy >= 0.0 {
            sum += point.energy;
            count += 1;
        }
        index += 1;
    }
    if count > 0 {
        Some(sum / count as f64)
    } else {
        None
    }
}

fn low_energy_reference(curve: &[audio_analysis::EnergyPoint]) -> Option<f64> {
    let mut energies: Vec<f64> = curve
        .iter()
        .map(|p| p.energy)
        .filter(|e| e.is_finite() && *e >= 0.0)
        .collect();
    if energies.is_empty() {
        return None;
    }
    energies.sort_by(|a, b| a.total_cmp(b));
    let upper_decile = energies[((energies.len() - 1) as f64 * 0.9) as usize];
    let reference = upper_decile.max(energies.last().copied().unwrap_or(0.0) * 0.25);
    if reference > 1e-9 {
        Some(reference)
    } else {
        None
    }
}

fn low_energy_resolution(curve: &[audio_analysis::EnergyPoint]) -> f64 {
    let mut gaps: Vec<f64> = curve
        .windows(2)
        .map(|w| w[1].time - w[0].time)
        .filter(|g| g.is_finite() && *g > 0.0)
        .collect();
    gaps.sort_by(|a, b| a.total_cmp(b));
    gaps.get(gaps.len() / 2).copied().unwrap_or(0.0)
}

fn low_energy_change(
    curve: &[audio_analysis::EnergyPoint],
    reference: Option<f64>,
    at: f64,
    window_seconds: f64,
) -> Option<f64> {
    if curve.is_empty() || window_seconds <= 0.0 {
        return None;
    }
    let reference = reference?;
    let before = average_low_energy(curve, at - window_seconds, at)?;
    let after = average_low_energy(curve, at, at + window_seconds)?;
    Some((after / reference).clamp(0.0, 1.5) - (before / reference).clamp(0.0, 1.5))
}

/// Chooses one shared-grid beat for the low-end handoff from the low-energy
/// structure of both tracks (upstream `bassSwapFractionFor`).
fn bass_swap_fraction_for(
    outgoing: &Analysis,
    incoming: &Analysis,
    transition_start: f64,
    incoming_cue_time: f64,
    outgoing_beat_seconds: f64,
    incoming_beat_seconds: f64,
    overlap_seconds: f64,
    overlap_beats: usize,
) -> f64 {
    if overlap_seconds <= 0.0 {
        return DEFAULT_BASS_SWAP_FRACTION;
    }
    let latest_fraction =
        (MAX_BASS_SWAP_FRACTION.min(BASS_SWAP_MAX_SECONDS / overlap_seconds)).clamp(0.0, 1.0);
    let prior = DEFAULT_BASS_SWAP_FRACTION.min(latest_fraction);
    if overlap_beats < 2 {
        return prior;
    }

    let earliest_fraction = HANDOFF_FRACTION.min(latest_fraction);
    let earliest_beat =
        ((earliest_fraction * overlap_beats as f64 - 1e-9).ceil() as usize).clamp(1, overlap_beats - 1);
    let latest_beat =
        ((latest_fraction * overlap_beats as f64 + 1e-9).floor() as usize).clamp(earliest_beat, overlap_beats - 1);
    let candidates: Vec<usize> = (earliest_beat..=latest_beat).collect();
    // `minWithOrNull`: closest to the prior, then beat-on-a-bar preferred.
    let fallback_beat = match candidates.iter().min_by(|a, b| {
        let da = (**a as f64 / overlap_beats as f64 - prior).abs();
        let db = (**b as f64 / overlap_beats as f64 - prior).abs();
        da.total_cmp(&db)
            .then_with(|| (if **a % 4 == 0 { 0 } else { 1 }).cmp(&(if **b % 4 == 0 { 0 } else { 1 })))
    }) {
        Some(beat) => *beat,
        None => return prior,
    };

    let outgoing_reference = low_energy_reference(&outgoing.low_energy_curve);
    let incoming_reference = low_energy_reference(&incoming.low_energy_curve);
    let outgoing_window = outgoing_beat_seconds.max(
        low_energy_resolution(&outgoing.low_energy_curve) * 1.1,
    );
    let incoming_window = incoming_beat_seconds.max(
        low_energy_resolution(&incoming.low_energy_curve) * 1.1,
    );

    let mut strongest: Option<(usize, f64)> = None;
    for beat in &candidates {
        let outgoing_at = transition_start + *beat as f64 * outgoing_beat_seconds;
        let incoming_at = incoming_cue_time + *beat as f64 * incoming_beat_seconds;
        let incoming_change = low_energy_change(
            &incoming.low_energy_curve,
            incoming_reference,
            incoming_at,
            incoming_window,
        );
        let outgoing_change = low_energy_change(
            &outgoing.low_energy_curve,
            outgoing_reference,
            outgoing_at,
            outgoing_window,
        );
        if incoming_change.is_none() && outgoing_change.is_none() {
            continue;
        }
        let score = incoming_change.unwrap_or(0.0) - outgoing_change.unwrap_or(0.0);
        let candidate = (*beat, score);
        strongest = Some(match strongest {
            None => candidate,
            Some(current) => {
                // `maxWithOrNull`: score desc, then beat-on-bar, then closest to prior.
                let mut better = candidate.1 > current.1;
                if candidate.1 == current.1 {
                    let c_bar = if candidate.0 % 4 == 0 { 1 } else { 0 };
                    let s_bar = if current.0 % 4 == 0 { 1 } else { 0 };
                    better = c_bar > s_bar;
                    if c_bar == s_bar {
                        better = (candidate.0 as f64 / overlap_beats as f64 - prior).abs()
                            < (current.0 as f64 / overlap_beats as f64 - prior).abs();
                    }
                }
                if better {
                    candidate
                } else {
                    current
                }
            }
        });
    }

    let chosen_beat = match strongest {
        Some((beat, score)) if score >= MIN_BASS_STRUCTURE_SCORE => beat,
        _ => fallback_beat,
    };
    chosen_beat as f64 / overlap_beats as f64
}

// ---- Mix-out anchor ranking (upstream `rankMixOutCandidates`) ---------------

fn mix_out_type_score(kind: &str) -> f64 {
    match kind {
        "energy_cliff" | "interior_mix_out" => 0.95,
        "outro_start" => 0.9,
        "content_end" => 0.75,
        _ => 0.0,
    }
}

/// Audible seconds (energy ≥ 10 % of the track reference) between `start` and
/// `end`, measured on the energy curve (upstream `audibleSecondsBetween`).
fn audible_seconds_between(
    curve: &[audio_analysis::EnergyPoint],
    start: f64,
    end: f64,
) -> Option<f64> {
    if curve.len() < 2 || end <= start {
        return None;
    }
    let mut energies: Vec<f64> = curve
        .iter()
        .map(|p| p.energy)
        .filter(|e| e.is_finite() && *e >= 0.0)
        .collect();
    if energies.is_empty() {
        return None;
    }
    energies.sort_by(|a, b| a.total_cmp(b));
    let reference = energies[((energies.len() - 1) as f64 * 0.85) as usize];
    if reference <= 0.0 {
        return Some(0.0);
    }
    let threshold = reference * AUDIBLE_ENERGY_FRACTION;
    let first = curve.first().unwrap().time;
    let last = curve.last().unwrap().time;
    if !first.is_finite() || !last.is_finite() || last <= first {
        return None;
    }
    let sample_seconds = (last - first) / (curve.len() - 1) as f64;
    let mut audible = 0.0;
    for point in curve {
        if !point.time.is_finite() || point.time < start || point.time > end {
            continue;
        }
        if point.energy >= threshold {
            audible += sample_seconds;
        }
    }
    Some(audible)
}

/// Where the outgoing track's transition ends: the best-ranked mix-out
/// candidate inside the discarded-music budget, or the content end. Returns
/// `(time, discarded_music_seconds)` (upstream `resolveMixOutAnchor`).
fn resolve_mix_out_anchor(outgoing: &Analysis) -> (f64, f64) {
    let end = if outgoing.content_end > 0.0 {
        outgoing.content_end
    } else {
        outgoing.duration
    };
    if end <= 0.0 {
        return (0.0, 0.0);
    }
    let mut candidates = outgoing.mix_out_candidates.clone();
    if !candidates.iter().any(|c| (c.time - end).abs() < 0.05) {
        candidates.push(audio_analysis::MixCuePoint {
            time: end,
            score: 0.75,
            kind: "content_end".into(),
        });
    }

    let mut best: Option<(f64, f64, f64)> = None; // (rank_score, time, discarded)
    for candidate in &candidates {
        let measured = audible_seconds_between(&outgoing.energy_curve, candidate.time, end);
        let discarded = measured.unwrap_or((end - candidate.time).max(0.0));
        if discarded > MAX_DISCARDED_MUSIC_SECONDS {
            continue;
        }
        let rank_score = candidate.score + mix_out_type_score(&candidate.kind);
        best = Some(match best {
            None => (rank_score, candidate.time, discarded),
            Some((score, time, discarded_seconds)) => {
                if rank_score > score || (rank_score == score && candidate.time > time) {
                    (rank_score, candidate.time, discarded)
                } else {
                    (score, time, discarded_seconds)
                }
            }
        });
    }
    match best {
        Some((_, time, discarded)) => (time, discarded),
        None => (end, 0.0),
    }
}

// ---- Harmonic key routing (upstream TransitionPlanner key helpers) ----------

fn key_index(name: &str) -> Option<usize> {
    Some(match name {
        "C" => 0,
        "C♯" | "D♭" => 1,
        "D" => 2,
        "D♯" | "E♭" => 3,
        "E" => 4,
        "F" => 5,
        "F♯" | "G♭" => 6,
        "G" => 7,
        "G♯" | "A♭" => 8,
        "A" => 9,
        "A♯" | "B♭" => 10,
        "B" => 11,
        _ => return None,
    })
}

fn split_key(key: &str) -> (Option<usize>, Option<&str>) {
    let mut parts = key.trim().split(' ');
    let index = parts.next().and_then(key_index);
    let mode = parts.next();
    (index, mode)
}

fn key_distance(left: &str, right: &str) -> Option<usize> {
    let (left_index, left_mode) = split_key(left);
    let (right_index, right_mode) = split_key(right);
    let left_index = left_index?;
    let right_index = right_index?;
    let pitch = (left_index + 12 - right_index) % 12;
    let pitch = pitch.min((right_index + 12 - left_index) % 12);
    Some(pitch + if left_mode.is_some() && right_mode.is_some() && left_mode != right_mode {
        1
    } else {
        0
    })
}

/// A key the analyzer was not confident about is no key at all.
fn trusted_key(analysis: &Analysis) -> String {
    if analysis.key.is_empty() || analysis.key_confidence < 0.25 {
        String::new()
    } else {
        analysis.key.clone()
    }
}

/// Upstream `harmonicallyCompatible`: a second/fifth (same mode) or a second
/// (differing modes) is a move a DJ makes; anything wider is not.
fn harmonically_compatible(left: &str, right: &str) -> bool {
    let (left_index, left_mode) = split_key(left);
    let (right_index, right_mode) = split_key(right);
    let left_index = match left_index {
        Some(i) => i,
        None => return false,
    };
    let right_index = match right_index {
        Some(i) => i,
        None => return false,
    };
    let distance = (left_index + 12 - right_index) % 12;
    let distance = distance.min((right_index + 12 - left_index) % 12);
    if left_mode.is_some() && right_mode.is_some() && left_mode != right_mode {
        return distance <= 1;
    }
    distance <= 2 || distance == 5
}

fn plan_from(outgoing: &Analysis, incoming: &Analysis, fade: f64) -> TransitionPlan {
    let cue = incoming_cue(incoming);
    // Upstream `MIN_SMART_DURATION_SECONDS`: a track too short to spend a smart
    // transition on gets a plain crossfade (TransitionPlanner.kt:880-882).
    let too_short = (outgoing.duration > 0.0 && outgoing.duration < MIN_SMART_DURATION_SECONDS)
        || (incoming.duration > 0.0 && incoming.duration < MIN_SMART_DURATION_SECONDS);
    let tier = assess(outgoing, incoming);
    if matches!(tier, Tier::Plain) || too_short {
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
    // Upstream phrase-switch: a beat-matched, harmonically-compatible pair is
    // stretched to the outgoing tempo unclamped (the 0.9–1.1 band is only the
    // adaptive-overlap fallback). The mixer's effective clamp is 0.5–2.0.
    let harmonic = harmonically_compatible(&trusted_key(outgoing), &trusted_key(incoming));
    let playback_rate = if same_beat && harmonic {
        ((1.0 / ratio).clamp(0.5, 2.0) * 10_000.0).round() / 10_000.0
    } else if (0.9..=1.1).contains(&ratio) {
        ((1.0 / ratio).clamp(0.9, 1.1) * 10_000.0).round() / 10_000.0
    } else {
        1.0
    };
    let vocal_conflict = outgoing.vocal_probability >= 0.62 && incoming.vocal_probability >= 0.62;
    // Upstream `adaptiveOverlap`: a longer overlap also when the two keys are
    // far apart (a key-distance > 4 uses 16 beats even at a close tempo).
    let key_distance = key_distance(&trusted_key(outgoing), &trusted_key(incoming));
    let overlap_beats = if !vocal_conflict
        && ((1.0 - ratio).abs() > 0.07 || key_distance.is_some_and(|d| d > 4))
    {
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
    // `adaptiveOverlap` — the overlap length the policy proposes.
    let overlap = (overlap_beats * beat_seconds).clamp(min_overlap, AUTO_TRANSITION_MAX_SECONDS);

    // Upstream `maximumOverlap`: the 16-beat cap, the 40 %-of-mixEnd cap (the
    // outgoing track's ranked mix-out anchor, from phase-1 analysis), and the
    // 40 %-of-incoming cap (TransitionPlanner.kt:975-980).
    let outgoing_mix_end = resolve_mix_out_anchor(outgoing).0;
    let max_overlap = (AUTO_TRANSITION_MAX_BEATS * beat_seconds)
        .min(AUTO_TRANSITION_MAX_SECONDS)
        .min(outgoing_mix_end * 0.4)
        .min(if incoming.duration > 0.0 {
            incoming.duration * 0.4
        } else {
            AUTO_TRANSITION_MAX_SECONDS
        });

    // `handoffSeconds`: how long the handover itself takes, from the shared
    // beat grid (TransitionPlanner.kt:981-987).
    let handoff_beats = if same_beat { 8.0 } else { 4.0 };
    let handoff_seconds = if out_bpm > 0.0 {
        (handoff_beats * 60.0 / out_bpm).clamp(2.0, if same_beat { 6.0 } else { 5.0 })
    } else {
        4.0
    };

    // `desiredOverlap` / `actualOverlap` — the intro preroll is zero without
    // phase-1 structure, so the handoff's own length is the floor that keeps
    // the fade from finishing before the handover does (TransitionPlanner.kt:
    // 1038-1039).
    let desired_overlap = overlap.max(handoff_seconds * 0.42);
    let actual_overlap = desired_overlap.clamp(handoff_seconds.min(max_overlap), max_overlap);
    let fade_seconds = actual_overlap;

    // Per-beat low-energy handoff placement (upstream `bassSwapFractionFor`) —
    // only the DJ_BLEND style swaps bass, so only it needs the chosen beat.
    let transition_start = (outgoing_mix_end - fade_seconds).max(0.0);
    let incoming_beat_seconds = if in_bpm > 0.0 { 60.0 / in_bpm } else { 0.5 };
    let bass_swap_fraction = if same_beat {
        bass_swap_fraction_for(
            outgoing,
            incoming,
            transition_start,
            cue,
            beat_seconds,
            incoming_beat_seconds,
            fade_seconds,
            overlap_beats as usize,
        )
    } else {
        DEFAULT_BASS_SWAP_FRACTION
    };

    let vocal_overlap = planned_vocal_overlap(
        outgoing,
        incoming,
        transition_start,
        outgoing_mix_end,
        cue,
        playback_rate,
    );

    TransitionPlan {
        // Upstream `sameBeatBlend` gates on tempo ratio + beat confidence
        // alone — a DJ_ASSISTED pair that is tempo-close still blends, not
        // sweeps (TransitionPlanner.kt:965-967, 1073). No tier requirement.
        style: if same_beat {
            TransitionStyle::DjBlend
        } else {
            TransitionStyle::DjFilter
        },
        bass_swap: true,
        bass_swap_fraction,
        filter_sweep: if same_beat { 0.0 } else { FILTER_SWEEP },
        vocal_overlap,
        fade_seconds,
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
    // Phase-1 mix-in candidates, highest score first (`main_drop` > `intro_drop`
    // > `pickup`), matching upstream `incomingCuePoint`'s ranking.
    let mut ranked: Vec<&audio_analysis::MixCuePoint> =
        analysis.mix_in_candidates.iter().collect();
    ranked.sort_by(|a, b| b.score.total_cmp(&a.score));
    for candidate in ranked {
        if in_mix_in_window(candidate.time) {
            return candidate.time;
        }
    }
    // No structure analysis: fall back to the beat-grid heuristic.
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

/// Mean vocal activity over `start`..`end` on a track's own timeline (upstream
/// `vocalActivityBetween`). Null when the mask is absent or the window is empty.
fn vocal_activity_between(analysis: &Analysis, start: f64, end: f64) -> Option<f64> {
    let mask = &analysis.vocal_activity_mask;
    let curve = &analysis.energy_curve;
    if mask.is_empty() || mask.len() != curve.len() || end <= start {
        return None;
    }
    let mut sum = 0.0;
    let mut count = 0usize;
    for index in 0..mask.len() {
        let time = curve[index].time;
        if !time.is_finite() || time < start || time > end {
            continue;
        }
        let value = mask[index];
        if !value.is_finite() {
            continue;
        }
        sum += value;
        count += 1;
    }
    if count > 0 {
        Some(sum / count as f64)
    } else {
        None
    }
}

/// Both windows measurably singing at once (upstream `isVocalClash`).
fn is_vocal_clash(outgoing_activity: Option<f64>, incoming_activity: Option<f64>) -> bool {
    matches!((outgoing_activity, incoming_activity),
        (Some(out), Some(inc)) if out >= VOCAL_ACTIVE_THRESHOLD && inc >= VOCAL_ACTIVE_THRESHOLD)
}

/// The fraction of a planned overlap where **both** tracks sing at the same
/// instant (upstream `simultaneousVocalFraction`), mapping the outgoing
/// energy-curve samples onto the incoming timeline through `rate`.
fn simultaneous_vocal_fraction(
    outgoing: &Analysis,
    incoming: &Analysis,
    out_start: f64,
    out_end: f64,
    in_start: f64,
    rate: f64,
) -> Option<f64> {
    let out_mask = &outgoing.vocal_activity_mask;
    let out_curve = &outgoing.energy_curve;
    let in_mask = &incoming.vocal_activity_mask;
    let in_curve = &incoming.energy_curve;
    if out_mask.is_empty() || out_mask.len() != out_curve.len() {
        return None;
    }
    if in_mask.is_empty() || in_mask.len() != in_curve.len() {
        return None;
    }
    if out_end <= out_start {
        return None;
    }
    let step = if rate.is_finite() && rate > 0.0 { rate } else { 1.0 };
    let mut in_index = 0usize;
    let mut both = 0usize;
    let mut total = 0usize;
    for index in 0..out_mask.len() {
        let time = out_curve[index].time;
        if !time.is_finite() || time < out_start {
            continue;
        }
        if time > out_end {
            break;
        }
        total += 1;
        if out_mask[index] < VOCAL_ACTIVE_THRESHOLD {
            continue;
        }
        let target = in_start + (time - out_start) * step;
        while in_index + 1 < in_curve.len() && in_curve[in_index + 1].time <= target {
            in_index += 1;
        }
        if in_index < in_mask.len() && in_mask[in_index] >= VOCAL_ACTIVE_THRESHOLD {
            both += 1;
        }
    }
    if total > 0 {
        Some(both as f64 / total as f64)
    } else {
        None
    }
}

/// The render-time vocal separation amount, measured instant-by-instant over the
/// windows the plan actually blends (upstream `plannedVocalOverlap`).
fn planned_vocal_overlap(
    outgoing: &Analysis,
    incoming: &Analysis,
    transition_start: f64,
    transition_end: f64,
    incoming_cue_time: f64,
    incoming_playback_rate: f64,
) -> f64 {
    let outgoing_span = transition_end - transition_start;
    if outgoing_span <= 0.0 || !outgoing_span.is_finite() {
        return 0.0;
    }
    let rate = if incoming_playback_rate.is_finite() && incoming_playback_rate > 0.0 {
        incoming_playback_rate
    } else {
        1.0
    };
    simultaneous_vocal_fraction(
        outgoing,
        incoming,
        transition_start,
        transition_end,
        incoming_cue_time,
        rate,
    )
    .unwrap_or(0.0)
}

// ---- WSOLA beat-matched phrase-switch (upstream `planWsolaTransition`) ------

fn nearest_at_or_before(values: &[f64], target: f64) -> Option<f64> {
    values
        .iter()
        .copied()
        .filter(|v| v.is_finite() && *v >= 0.0 && *v <= target)
        .max_by(|a, b| a.total_cmp(b))
}

fn nearest_value(values: &[f64], target: f64, tolerance: f64) -> Option<f64> {
    values
        .iter()
        .copied()
        .filter(|v| v.is_finite() && (*v - target).abs() <= tolerance)
        .min_by(|a, b| (a - target).abs().total_cmp(&(b - target).abs()))
}

/// The earliest point the analysis claims the track makes sound (upstream
/// `audibleStartOf`).
fn audible_start_of(analysis: &Analysis) -> f64 {
    let mut best = f64::INFINITY;
    for value in [analysis.audible_start_time, analysis.first_beat] {
        if value.is_finite() && value >= 0.0 {
            best = best.min(value);
        }
    }
    if best.is_finite() {
        best
    } else {
        0.0
    }
}

/// Where the incoming track takes over: the best-ranked mix-in candidate,
/// snapped to a downbeat (upstream `incomingMixInPoint`).
fn incoming_mix_in_point(analysis: &Analysis) -> Option<f64> {
    let beat_seconds = if analysis.beat_interval > 0.0 {
        analysis.beat_interval
    } else if analysis.bpm > 0.0 {
        60.0 / analysis.bpm
    } else {
        0.0
    };
    let tolerance = 0.5f64.max(beat_seconds * 2.0);
    let mut ranked: Vec<&audio_analysis::MixCuePoint> =
        analysis.mix_in_candidates.iter().collect();
    ranked.sort_by(|a, b| b.score.total_cmp(&a.score));
    let target = ranked
        .first()
        .map(|c| c.time)
        .or(if analysis.mix_in_time > 0.0 {
            Some(analysis.mix_in_time)
        } else {
            None
        })?;
    nearest_value(&analysis.downbeats, target, tolerance).or(Some(target))
}

/// One pass of the vocal-clash gate (upstream `clashOver`).
#[allow(clippy::too_many_arguments)]
fn clash_over(
    outgoing: &Analysis,
    incoming: &Analysis,
    overlap_end_target: f64,
    outgoing_beat_seconds: f64,
    incoming_beat_seconds: f64,
    incoming_drop_time: f64,
    audible_start: f64,
    stretch_ratio: f64,
    beats: usize,
) -> bool {
    let out_start = overlap_end_target - beats as f64 * outgoing_beat_seconds;
    let in_start = audible_start.max(incoming_drop_time - beats as f64 * incoming_beat_seconds);
    let out_vocal = vocal_activity_between(outgoing, out_start, overlap_end_target);
    let in_vocal = vocal_activity_between(incoming, in_start, incoming_drop_time);
    let simultaneous = simultaneous_vocal_fraction(
        outgoing,
        incoming,
        out_start,
        overlap_end_target,
        in_start,
        stretch_ratio,
    );
    if simultaneous.is_some_and(|s| s > VOCAL_CLASH_TOLERANCE) {
        return true;
    }
    if is_vocal_clash(out_vocal, in_vocal) {
        return true;
    }
    if beats > 8 && out_vocal.is_some_and(|v| v >= VOCAL_ACTIVE_THRESHOLD) {
        let deep_vocal = vocal_activity_between(
            outgoing,
            out_start,
            overlap_end_target - 8.0 * outgoing_beat_seconds,
        );
        if deep_vocal.is_some_and(|v| v >= VOCAL_ACTIVE_THRESHOLD) {
            return true;
        }
    }
    false
}

/// Plans one beat-matched transition (upstream `planWsolaTransition`). `None`
/// is a routing decision — the caller falls back to the adaptive overlap.
fn plan_wsola_transition(outgoing: &Analysis, incoming: &Analysis) -> Option<TransitionPlan> {
    if assess(outgoing, incoming) != Tier::Beatmatched {
        return None;
    }
    let outgoing_bpm = outgoing.bpm;
    if outgoing_bpm <= 0.0 || incoming.bpm <= 0.0 {
        return None;
    }
    let incoming_bpm = align_tempo_octave(outgoing_bpm, incoming.bpm);
    let stretch_ratio = outgoing_bpm / incoming_bpm;

    let outgoing_length = outgoing.duration;
    let incoming_length = incoming.duration;
    if outgoing_length <= 0.0 || incoming_length <= 0.0 {
        return None;
    }

    let incoming_beat_seconds = 60.0 / incoming_bpm;
    let outgoing_beat_seconds = 60.0 / outgoing_bpm;

    let incoming_drop_time = incoming_mix_in_point(incoming)?;

    let content_end = if outgoing.content_end > 0.0 {
        outgoing.content_end
    } else {
        outgoing_length
    };
    let (mix_out_anchor, _) = resolve_mix_out_anchor(outgoing);
    let unshifted_overlap_end = outgoing_length.min(mix_out_anchor);
    let outgoing_arrangement_overlap = if (mix_out_anchor - content_end).abs() < 0.05 {
        (ARRANGEMENT_OVERLAP_BEATS * outgoing_beat_seconds).min(MAX_DISCARDED_MUSIC_SECONDS)
    } else {
        0.0
    };
    let overlap_end_target =
        MIN_CLEARANCE_SECONDS.max(unshifted_overlap_end - outgoing_arrangement_overlap);

    let audible_start = audible_start_of(incoming);
    let available_fade_beats =
        (incoming_drop_time - audible_start).max(0.0) / incoming_beat_seconds;
    let capped_by_overlap =
        ((MAX_OVERLAP_SECONDS / incoming_beat_seconds).floor() as usize / 4) * 4;
    if capped_by_overlap < MIN_FADE_BEATS {
        return None;
    }
    let mut fade_beats = MAX_FADE_BEATS
        .min(capped_by_overlap)
        .min(((available_fade_beats / 4.0).floor() as usize) * 4);
    if fade_beats < MIN_FADE_BEATS {
        fade_beats = MIN_FADE_BEATS;
    }

    while fade_beats > MIN_FADE_BEATS
        && clash_over(
            outgoing,
            incoming,
            overlap_end_target,
            outgoing_beat_seconds,
            incoming_beat_seconds,
            incoming_drop_time,
            audible_start,
            stretch_ratio,
            fade_beats,
        )
    {
        fade_beats -= 4;
    }

    let coverable_beats =
        ((incoming_drop_time - audible_start).max(0.0) / incoming_beat_seconds).floor() as usize;
    let overlap_beats = fade_beats.min(coverable_beats);
    if overlap_beats < 1 {
        return None;
    }

    let outgoing_overlap_seconds = overlap_beats as f64 * outgoing_beat_seconds;
    let overlap_seconds = overlap_beats as f64 * incoming_beat_seconds;

    let requested_incoming_handoff =
        incoming_drop_time + ARRANGEMENT_OVERLAP_BEATS * incoming_beat_seconds;
    let max_incoming_handoff = incoming_length - MIN_CLEARANCE_SECONDS;
    if max_incoming_handoff < incoming_drop_time {
        return None;
    }
    let incoming_handoff_time = requested_incoming_handoff.min(max_incoming_handoff);
    let incoming_cue_time = incoming_handoff_time - overlap_seconds;
    if incoming_cue_time < audible_start - 0.05 {
        return None;
    }

    let start_target = overlap_end_target - outgoing_overlap_seconds;
    let transition_start =
        nearest_at_or_before(&outgoing.downbeats, start_target).unwrap_or(start_target);
    if transition_start < MIN_CLEARANCE_SECONDS {
        return None;
    }
    let transition_end = transition_start + outgoing_overlap_seconds;
    if transition_end > outgoing_length + 0.05 {
        return None;
    }

    let incoming_resume_time = incoming_cue_time + overlap_seconds;
    if incoming_resume_time + MIN_CLEARANCE_SECONDS > incoming_length {
        return None;
    }

    let bass_swap_fraction = bass_swap_fraction_for(
        outgoing,
        incoming,
        transition_start,
        incoming_cue_time,
        outgoing_beat_seconds,
        incoming_beat_seconds,
        overlap_seconds,
        overlap_beats,
    );
    let vocal_overlap = planned_vocal_overlap(
        outgoing,
        incoming,
        transition_start,
        transition_end,
        incoming_cue_time,
        stretch_ratio,
    );

    Some(TransitionPlan {
        style: TransitionStyle::DjBlend,
        bass_swap: true,
        bass_swap_fraction,
        filter_sweep: 0.0,
        vocal_overlap,
        fade_seconds: transition_end - transition_start,
        cue_seconds: incoming_cue_time,
        playback_rate: (stretch_ratio * 10_000.0).round() / 10_000.0,
    })
}

/// The most ambitious move: run the incoming intro under the outgoing and close
/// on its drop, gated on harmonic compatibility (upstream `phraseSwitch`).
fn phrase_switch(outgoing: &Analysis, incoming: &Analysis) -> Option<TransitionPlan> {
    if !harmonically_compatible(&trusted_key(outgoing), &trusted_key(incoming)) {
        return None;
    }
    plan_wsola_transition(outgoing, incoming)
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
    fn bass_swap_fraction_defaults_and_stays_bounded() {
        let out = analysis(0.5, 200.0, vec![0.5, 1.0, 1.5, 2.0]);
        let inc = analysis(0.5, 200.0, vec![0.5, 1.0, 1.5, 2.0]);
        // Non-positive overlap returns the fixed default.
        assert!(
            (bass_swap_fraction_for(&out, &inc, 0.0, 0.5, 0.5, 0.5, 0.0, 16) - 0.7).abs() < 1e-9
        );
        // A normal overlap stays bounded even with no low-energy structure.
        let fraction = bass_swap_fraction_for(&out, &inc, 0.0, 0.5, 0.5, 0.5, 6.0, 16);
        assert!((0.0..=1.0).contains(&fraction), "fraction {fraction}");
    }

    #[test]
    fn is_vocal_clash_needs_both_sides_above_threshold() {
        assert!(is_vocal_clash(Some(0.8), Some(0.9)));
        assert!(!is_vocal_clash(Some(0.8), Some(0.5)));
        assert!(!is_vocal_clash(None, Some(0.9)));
        assert!(!is_vocal_clash(Some(0.9), None));
    }

    #[test]
    fn vocal_activity_between_averages_the_window() {
        let mut a = analysis(0.0, 200.0, vec![]);
        a.energy_curve = vec![
            audio_analysis::EnergyPoint { time: 0.0, energy: 1.0 },
            audio_analysis::EnergyPoint { time: 1.0, energy: 1.0 },
            audio_analysis::EnergyPoint { time: 2.0, energy: 1.0 },
            audio_analysis::EnergyPoint { time: 3.0, energy: 1.0 },
        ];
        a.vocal_activity_mask = vec![0.0, 0.5, 1.0, 0.5];
        // The [0.5, 2.5] window covers times 1.0 and 2.0 → mean of 0.5 and 1.0.
        let mean = vocal_activity_between(&a, 0.5, 2.5).unwrap();
        assert!((mean - 0.75).abs() < 1e-9, "mean {mean}");
    }

    #[test]
    fn phrase_switch_refuses_incompatible_keys() {
        let mut out = analysis(0.5, 200.0, vec![0.5, 1.0, 1.5, 2.0]);
        out.key = "C major".into();
        out.key_confidence = 0.9;
        out.bpm = 120.0;
        out.beat_confidence = 0.8;
        let mut inc = analysis(0.5, 200.0, vec![0.5, 1.0, 1.5, 2.0]);
        inc.key = "D♯ major".into(); // a minor third — not a compatible move
        inc.key_confidence = 0.9;
        inc.bpm = 120.0;
        inc.beat_confidence = 0.8;
        assert!(phrase_switch(&out, &inc).is_none());
    }

    #[test]
    fn harmonically_compatible_matches_upstream_semantics() {
        // A fifth and a second are compatible; a minor third is not.
        assert!(harmonically_compatible("C major", "G major"));
        assert!(harmonically_compatible("C major", "D major"));
        assert!(!harmonically_compatible("C major", "D♯ major"));
        // Differing modes are compatible only within a second.
        assert!(harmonically_compatible("C major", "C minor"));
        assert!(!harmonically_compatible("C major", "D minor"));
        assert!(!harmonically_compatible("C major", "G minor"));
        // Unknown keys are never compatible.
        assert!(!harmonically_compatible("", "C major"));
    }

    #[test]
    fn key_distance_matches_upstream_semantics() {
        assert_eq!(key_distance("C major", "C major"), Some(0));
        // A fifth is the closest relationship on the circle.
        assert_eq!(key_distance("C major", "G major"), Some(5));
        // Same pitch class but different mode charges one step.
        assert_eq!(key_distance("C major", "C minor"), Some(1));
        // An unknown key yields no distance.
        assert_eq!(key_distance("", "C major"), None);
        // A low-confidence key is not trusted.
        let mut a = analysis(0.0, 0.0, vec![]);
        a.key = "C major".into();
        a.key_confidence = 0.1;
        assert_eq!(trusted_key(&a), "");
    }

    #[test]
    fn blocked_text_matches_word_boundaries_only() {
        assert!(blocked_text("The Daily Podcast Episode 12"));
        assert!(blocked_text("Live at the Apollo (Concert)"));
        assert!(blocked_text("an audiobook performance"));
        // "alive" and "lively" are not "live"; "concerted" is not "concert".
        assert!(!blocked_text("Stay Alive"));
        assert!(!blocked_text("Lively Discussion"));
        assert!(!blocked_text("A Concerted Effort"));
        assert!(!blocked_text("Ordinary Song Title"));
    }

    #[test]
    fn interior_energy_cliff_wins_the_mix_out_anchor() {
        let mut out = analysis(0.5, 200.0, vec![0.5, 1.0, 1.5, 2.0]);
        out.content_end = 180.0;
        out.mix_out_candidates.push(audio_analysis::MixCuePoint {
            time: 175.0,
            score: 0.95,
            kind: "energy_cliff".into(),
        });
        // The cliff is 5 s before content end (inside the 12 s budget) and ranks
        // above the implicit content_end, so it is the anchor — and it is
        // interior, which is what gates the gapless path off.
        let (anchor, _) = resolve_mix_out_anchor(&out);
        assert!((anchor - 175.0).abs() < 1e-9, "anchor {anchor}");
        assert!(anchor < 180.0 - 1.0);
    }

    #[test]
    fn mix_out_anchor_falls_back_to_content_end() {
        let mut out = analysis(0.5, 200.0, vec![0.5, 1.0, 1.5, 2.0]);
        out.content_end = 180.0;
        // No mix-out candidates and no energy curve → content_end is the anchor
        // with no discarded-music charge.
        let (time, discarded) = resolve_mix_out_anchor(&out);
        assert!((time - 180.0).abs() < 1e-9, "time {time}");
        assert_eq!(discarded, 0.0);
    }

    #[test]
    fn short_track_gets_plain_crossfade_despite_strong_beat_evidence() {
        // Upstream MIN_SMART_DURATION_SECONDS=45: a sub-45s track must never get
        // a smart transition, even when its beat grid would otherwise qualify.
        let mut short = analysis(0.5, 30.0, vec![0.5, 1.0, 1.5, 2.0]);
        short.bpm = 120.0;
        short.beat_confidence = 0.8;
        let mut long = analysis(0.5, 200.0, vec![0.5, 1.0, 1.5, 2.0]);
        long.bpm = 120.0;
        long.beat_confidence = 0.8;

        let plan = plan_from(&long, &short, 8.0);
        assert_eq!(plan.style, TransitionStyle::EqualPower);
        assert!(!plan.bass_swap);
    }

    #[test]
    fn fade_is_capped_by_incoming_duration() {
        // A 30 s incoming track must not fade longer than 40 % of itself.
        let mut short = analysis(0.5, 30.0, vec![0.5, 1.0, 1.5, 2.0]);
        short.bpm = 90.0;
        short.beat_confidence = 0.8;
        let mut long = analysis(0.5, 200.0, vec![0.5, 1.0, 1.5, 2.0]);
        long.bpm = 90.0;
        long.beat_confidence = 0.8;
        // Without the cap, 16 beats at 90 BPM is ~10.7 s.
        let plan = plan_from(&long, &short, 8.0);
        assert!(plan.fade_seconds <= 30.0 * 0.4 + 1e-6, "fade {}", plan.fade_seconds);
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
