//! Compact port of upstream `TransitionPolicy` + `planTransition` for a pair of files.

use super::audio_analysis;
use super::beat::{self, Grid, WINDOW_SECONDS};
use super::resample;
use super::vocal;
use crate::mixer::{TransitionPlan, TransitionStyle, MAX_DUCK_DEPTH};
use std::sync::Arc;

const MIN_BEATMATCH_CONFIDENCE: f64 = 0.55;
const MIN_DJ_CONFIDENCE: f64 = 0.2;
const MIN_BPM: f64 = 40.0;
const MAX_BPM: f64 = 220.0;
/// How far a Beatmatched pair may drift from unity and still stretch.
///
/// Apple AutoMix's documented failure mode is comic warps (reviewers report
/// ~0.75×–1.5×). Beatmatched stretch stays inside this band; DjAssisted never
/// stretches at all — it rides filters instead.
const MAX_STRETCH_DEVIATION: f64 = 0.04;
/// Alias used at call sites that stretch an incoming track onto the outgoing.
const MAX_BEATMATCH_STRETCH: f64 = MAX_STRETCH_DEVIATION;
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
/// Upstream `TrackAnalyzer.MIN_DECODED_FRACTION` — how much of the container's
/// stated duration must actually decode before the whole-track pass is trusted.
///
/// Not 1.0: a decoder legitimately comes up a frame or two short of the
/// container's rounding, and refusing over that would refuse everything. Not
/// lower either: the failure this catches is a still-downloading file, and the
/// cost of trusting one is a mix-out anchor placed where the bytes ran out.
const MIN_DECODED_FRACTION: f64 = 0.95;
/// Pickup inside this margin of the end is the outro, not a mix-in
/// (upstream `incomingCuePoint`: `pickup < duration - 10`).
const MIX_IN_END_MARGIN_SECONDS: f64 = 10.0;
/// How deep a mix-in may reach, in seconds, in beats, and as a fraction of the
/// incoming track.
///
/// A DJ enters the next record at the top of its own intro. Each bound exists
/// for a different track:
///
/// * `MAX_CUE_SECONDS` is the one that normally bites — four bars is about 7 s
///   at 140 BPM, so anything past that is a skip, not a mix-in.
/// * `MAX_CUE_BEATS` stops a slow track turning 16 beats into half a minute,
///   which is what the seconds bound would otherwise allow at 40 BPM.
/// * `MAX_CUE_FRACTION` is a floor under both, for short material: 6 % of a
///   one-minute clip is 3.6 s, and an 8 s skip there is 13 % of the record. It
///   never binds above about 133 s, where the seconds bound takes over.
const MAX_CUE_SECONDS: f64 = 8.0;
const MAX_CUE_BEATS: f64 = 16.0;
const MAX_CUE_FRACTION: f64 = 0.06;
/// Upstream bass-swap tuning constants (TransitionPlanner.kt:351-364).
const HANDOFF_FRACTION: f64 = 0.5;
const DEFAULT_BASS_SWAP_FRACTION: f64 = 0.7;
const MAX_BASS_SWAP_FRACTION: f64 = 0.85;
const MIN_BASS_STRUCTURE_SCORE: f64 = 0.25;
const BASS_SWAP_MAX_SECONDS: f64 = 6.0;
/// Album tracks played in order still join, they just do not get a DJ blend.
///
/// Upstream uses 0.12 s here (TransitionPlanner.kt:901), which is a splice.
/// A few seconds of equal-power is the shortest ramp that still reads as one
/// record giving way to the next.
const GAPLESS_FADE_SECONDS: f64 = AUTO_MIN_SECONDS;
/// Upstream `MAX_DISCARDED_MUSIC_SECONDS` — a mix-out anchor may not skip more
/// than this much audible music.
const MAX_DISCARDED_MUSIC_SECONDS: f64 = 12.0;
/// Upstream `AUDIBLE_ENERGY_FRACTION` — the energy threshold that counts a
/// point as audible when measuring skipped music.
const AUDIBLE_ENERGY_FRACTION: f64 = 0.1;
/// Upstream WSOLA phrase-switch constants (TransitionPlanner.kt:329-374),
/// plus the long blend a confident, unclashing pair is allowed.
const MIN_FADE_BEATS: usize = 4;
/// Upstream ceiling. A confident beat match may go further; see
/// [`LONG_BLEND_BEATS`].
const UPSTREAM_MAX_FADE_BEATS: usize = 16;
const UPSTREAM_MAX_OVERLAP_SECONDS: f64 = 16.0;
/// Apple-style long blend: up to 64 beats / 32 s when both grids are trusted
/// and the vocal-clash loop does not shrink it. 64 beats at 120 BPM is 32 s.
const LONG_BLEND_BEATS: usize = 64;
const LONG_BLEND_SECONDS: f64 = 32.0;
/// After the blend, walk the matched tempo back to the record's own over
/// this many beats of the tempo it was matched to.
const POST_BLEND_GLIDE_BEATS: f64 = 32.0;
/// Incoming level while it plays underneath, before the swap.
const BED_GAIN_DB: f64 = -14.0;
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
    /// Phrase starts, for snapping a transition onto a boundary.
    phrase_boundaries: Vec<f64>,
    section_boundaries: Vec<f64>,
    segment_boundaries: Vec<f64>,
    energy_curve: Vec<audio_analysis::EnergyPoint>,
    low_energy_curve: Vec<audio_analysis::EnergyPoint>,
    pace_curve: Vec<audio_analysis::EnergyPoint>,
    /// DSP per-frame vocal mask (parallel to `energy_curve`), from
    /// `AnalyzeKeyAndTimbre`. Drives `vocalActivityBetween` /
    /// `simultaneousVocalFraction`.
    vocal_activity_mask: Vec<f64>,
    drum_activity_mask: Vec<f64>,
    bass_activity_mask: Vec<f64>,
    /// The full beat grid, for downbeat snapping.
    beats: Vec<f64>,
    vocal_mask: Vec<f32>,
    vocal_times: Vec<f64>,
    /// Whole-track DSP vocal heuristic (`AnalyzeKeyAndTimbre`), not the model
    /// mask mean.
    vocal_probability: f64,
    /// Where the strongest analysis for this track came from.
    /// `music_understanding` | `beat_this` | `dsp` | `disk_cache`.
    analysis_source: String,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum Tier {
    Beatmatched,
    DjAssisted,
    Plain,
}

/// Analysis cache — the difference between planning as a decision and planning
/// as a workload.
///
/// One [`analyze`] is three decodes of the same file (whole track, head window,
/// vocal window), a resample, and two ONNX passes, which for a four-minute
/// track is seconds of CPU. The app asks for the same pair over and over:
/// `syncEngineQueueNext` alone is reached from nine call sites, and each one
/// re-plans the track that follows the current one. Uncached, that is the whole
/// analysis re-run for every transport command — and it runs at the same
/// priority band as the audio decoder, which is why opening a page could be
/// heard as a stutter.
///
/// The plan itself is *not* cached: it also depends on the crossfade setting,
/// the caller's text and the album flag, all of which are cheap to re-apply.
/// Only the analysis — the expensive, purely file-derived half — is kept.
///
/// The compute runs under the lock on purpose. Two callers asking for the same
/// track is the common case, and serialising means the second one waits and
/// then hits, instead of both decoding the same file at once.
mod analysis_cache {
    use super::Analysis;
    use std::collections::{HashMap, VecDeque};
    use std::sync::{Arc, Mutex, OnceLock};

    /// Enough for the head and tail of a queue; beyond that, re-decoding costs
    /// less than holding it. Each entry is tens to hundreds of kilobytes.
    const CAPACITY: usize = 6;

    type Key = (String, u64, bool);

    #[derive(Default)]
    struct Cache {
        entries: HashMap<Key, Arc<Analysis>>,
        /// Insertion order, for eviction. A key never appears twice: it is only
        /// pushed on a miss, and a hit returns before that.
        order: VecDeque<Key>,
    }

    fn cache() -> &'static Mutex<Cache> {
        static CACHE: OnceLock<Mutex<Cache>> = OnceLock::new();
        CACHE.get_or_init(|| Mutex::new(Cache::default()))
    }

    pub(super) fn clear() {
        let mut guard = cache().lock().unwrap_or_else(|poisoned| poisoned.into_inner());
        guard.entries.clear();
        guard.order.clear();
    }

    /// File length is part of the key because a streamed download is appended
    /// to under a stable path: a still-growing file must produce a fresh
    /// analysis, and a finished one must keep hitting.
    fn len_of(path: &str) -> u64 {
        std::fs::metadata(path).map(|m| m.len()).unwrap_or(0)
    }

    pub(super) fn get_or_compute(
        path: &str,
        skip_vocals: bool,
        compute: impl FnOnce() -> Analysis,
    ) -> Arc<Analysis> {
        let key: Key = (path.to_string(), len_of(path), skip_vocals);
        // A panic while analysing must not poison the cache for the session.
        let mut guard = cache().lock().unwrap_or_else(|poisoned| poisoned.into_inner());
        if let Some(hit) = guard.entries.get(&key) {
            return hit.clone();
        }
        let analysis = Arc::new(compute());
        guard.entries.insert(key.clone(), analysis.clone());
        guard.order.push_back(key);
        while guard.order.len() > CAPACITY {
            if let Some(evicted) = guard.order.pop_front() {
                guard.entries.remove(&evicted);
            }
        }
        analysis
    }

    pub(super) fn invalidate(path: &str) {
        let norm = path.strip_prefix("file://").unwrap_or(path);
        let mut guard = cache().lock().unwrap_or_else(|poisoned| poisoned.into_inner());
        let doomed: Vec<Key> = guard
            .entries
            .keys()
            .filter(|(p, _, _)| {
                let p_norm = p.strip_prefix("file://").unwrap_or(p);
                p_norm == norm
            })
            .cloned()
            .collect();
        for key in doomed {
            guard.entries.remove(&key);
            guard.order.retain(|k| k != &key);
        }
    }

    pub(super) fn get_cached_energy_curve(path: &str) -> Option<Vec<super::audio_analysis::EnergyPoint>> {
        let norm_path = path.strip_prefix("file://").unwrap_or(path);
        let guard = cache().lock().unwrap_or_else(|poisoned| poisoned.into_inner());
        guard.entries.iter().find(|(k, _)| {
            let k_norm = k.0.strip_prefix("file://").unwrap_or(&k.0);
            k_norm == norm_path
        }).map(|(_, v)| v.energy_curve.clone())
    }
}

pub(super) fn clear_analysis_cache() {
    analysis_cache::clear();
    overlays::clear();
}

/// External analysis overlay (Music Understanding, disk cache, …) merged onto
/// the DSP/ONNX result after `analyze` finishes. Rhythm/key/structure from a
/// stronger source win; envelope/energy from DSP stay unless the overlay
/// supplies replacements.
#[derive(Clone, Debug, Default)]
pub struct AnalysisOverlay {
    pub bpm: Option<f64>,
    pub beat_confidence: Option<f64>,
    pub beat_interval: Option<f64>,
    pub beats: Option<Vec<f64>>,
    pub downbeats: Option<Vec<f64>>,
    pub key: Option<String>,
    pub key_confidence: Option<f64>,
    pub phrase_boundaries: Option<Vec<f64>>,
    pub vocal_probability: Option<f64>,
    pub content_end: Option<f64>,
    pub audible_start: Option<f64>,
    pub outro_start: Option<f64>,
    pub mix_in_time: Option<f64>,
    /// `music_understanding` | `disk_cache` | …
    pub source: String,
}

mod overlays {
    use super::AnalysisOverlay;
    use std::collections::HashMap;
    use std::sync::{Mutex, OnceLock};

    fn map() -> &'static Mutex<HashMap<String, AnalysisOverlay>> {
        static MAP: OnceLock<Mutex<HashMap<String, AnalysisOverlay>>> = OnceLock::new();
        MAP.get_or_init(|| Mutex::new(HashMap::new()))
    }

    pub(super) fn clear() {
        map().lock().unwrap_or_else(|p| p.into_inner()).clear();
    }

    pub(super) fn put(path: &str, overlay: AnalysisOverlay) {
        let key = path.strip_prefix("file://").unwrap_or(path).to_string();
        map()
            .lock()
            .unwrap_or_else(|p| p.into_inner())
            .insert(key, overlay);
    }

    pub(super) fn get(path: &str) -> Option<AnalysisOverlay> {
        let key = path.strip_prefix("file://").unwrap_or(path);
        map()
            .lock()
            .unwrap_or_else(|p| p.into_inner())
            .get(key)
            .cloned()
    }
}

/// Register an external analysis overlay for `path`. The next `plan_pair`
/// analysis of that file merges it on top of DSP/ONNX results. Returns true
/// when stored.
pub fn seed_analysis_overlay(path: &str, overlay: AnalysisOverlay) -> bool {
    if path.is_empty() {
        return false;
    }
    // Drop any cached analysis so the next plan re-runs with the overlay.
    analysis_cache::invalidate(path);
    overlays::put(path, overlay);
    true
}

/// Sources used by the most recent `plan_pair` (outgoing, incoming).
pub fn last_analysis_sources() -> (String, String) {
    last_sources::get()
}

mod last_sources {
    use std::sync::{Mutex, OnceLock};

    fn pair() -> &'static Mutex<(String, String)> {
        static PAIR: OnceLock<Mutex<(String, String)>> = OnceLock::new();
        PAIR.get_or_init(|| Mutex::new((String::new(), String::new())))
    }

    pub(super) fn set(outgoing: &str, incoming: &str) {
        let out = if outgoing.is_empty() {
            "dsp"
        } else {
            outgoing
        };
        let inc = if incoming.is_empty() {
            "dsp"
        } else {
            incoming
        };
        *pair().lock().unwrap_or_else(|p| p.into_inner()) = (out.into(), inc.into());
    }

    pub(super) fn get() -> (String, String) {
        pair().lock().unwrap_or_else(|p| p.into_inner()).clone()
    }
}

fn apply_overlay(analysis: &mut Analysis, overlay: &AnalysisOverlay) {
    // Prefer Beat This / DSP tempo when MU reports a clear half/double of an
    // already-trusted grid (common with electronic tracks). Key/structure from
    // MU still apply.
    let trust_existing_tempo = analysis.beat_confidence >= 0.55
        && !analysis.downbeats.is_empty()
        && analysis.bpm > 0.0;
    let overlay_bpm = overlay.bpm.filter(|b| *b > 0.0);
    let tempo_octave = overlay_bpm.is_some_and(|bpm| {
        let ratio = bpm / analysis.bpm;
        (ratio - 2.0).abs() < 0.12 || (ratio - 0.5).abs() < 0.06
            || (ratio - 3.0).abs() < 0.15 || (ratio - 1.0 / 3.0).abs() < 0.05
    });
    let accept_overlay_tempo = !(trust_existing_tempo && tempo_octave);

    if accept_overlay_tempo {
        if let Some(bpm) = overlay_bpm {
            analysis.bpm = bpm;
        }
        if let Some(c) = overlay.beat_confidence {
            analysis.beat_confidence = c.clamp(0.0, 1.0);
        }
        if let Some(interval) = overlay.beat_interval.filter(|i| *i > 0.0) {
            analysis.beat_interval = interval;
        } else if analysis.bpm > 0.0 {
            analysis.beat_interval = 60.0 / analysis.bpm;
        }
        if let Some(beats) = overlay.beats.as_ref().filter(|b| b.len() >= 2) {
            analysis.beats = beats.clone();
            analysis.first_beat = beats[0];
        }
        if let Some(downbeats) = overlay.downbeats.as_ref().filter(|d| !d.is_empty()) {
            analysis.downbeats = downbeats.clone();
        }
    } else if let Some(bpm) = overlay_bpm {
        log::info!(
            "automix overlay: keeping {:.1} bpm grid; ignoring MU tempo {:.1} (octave)",
            analysis.bpm,
            bpm
        );
    }
    if let Some(key) = overlay.key.as_ref().filter(|k| !k.is_empty()) {
        analysis.key = key.clone();
    }
    if let Some(c) = overlay.key_confidence {
        analysis.key_confidence = c.clamp(0.0, 1.0);
    }
    if let Some(phrases) = overlay.phrase_boundaries.as_ref().filter(|p| !p.is_empty()) {
        analysis.phrase_boundaries = phrases.clone();
        // Treat phrase overlays as section hints when MU provides hierarchy as phrases.
        if analysis.section_boundaries.is_empty() {
            analysis.section_boundaries = phrases.clone();
        }
    }
    if let Some(v) = overlay.vocal_probability {
        analysis.vocal_probability = v.clamp(0.0, 1.0);
    }
    if let Some(end) = overlay.content_end.filter(|e| *e > 0.0) {
        analysis.content_end = end;
    }
    if let Some(start) = overlay.audible_start.filter(|s| s.is_finite() && *s >= 0.0) {
        analysis.audible_start_time = start;
    }
    if let Some(outro) = overlay.outro_start.filter(|s| *s > 0.0) {
        analysis.outro_start = outro;
    }
    if let Some(mix_in) = overlay.mix_in_time.filter(|s| *s > 0.0) {
        analysis.mix_in_time = mix_in;
    }
    if !overlay.source.is_empty() {
        // Keep a blended label when we refused the MU tempo but took structure.
        if !accept_overlay_tempo && analysis.analysis_source == "beat_this" {
            analysis.analysis_source = "beat_this+music_understanding".into();
        } else {
            analysis.analysis_source = overlay.source.clone();
        }
        log::info!(
            "automix overlay [{}]: bpm={:.1} conf={:.2} key={} phrases={}",
            analysis.analysis_source,
            analysis.bpm,
            analysis.beat_confidence,
            analysis.key,
            analysis.phrase_boundaries.len()
        );
    }
}

/// Locates the next local energy dip in the audio curve for the given source
/// within [position_seconds + 0.1, position_seconds + 2.0].
/// Used to defer source swap execution so crossfades happen in a valley.
pub fn next_energy_dip(source: &str, position_seconds: f64) -> Option<f64> {
    let curve = analysis_cache::get_cached_energy_curve(source)?;
    find_next_energy_dip(&curve, position_seconds)
}

pub(crate) fn find_next_energy_dip(
    curve: &[audio_analysis::EnergyPoint],
    position_seconds: f64,
) -> Option<f64> {
    if curve.is_empty() {
        return None;
    }
    let window_start = position_seconds + 0.1;
    let window_end = position_seconds + 2.0;

    let current_energy = curve
        .iter()
        .min_by(|a, b| {
            (a.time - position_seconds)
                .abs()
                .total_cmp(&(b.time - position_seconds).abs())
        })
        .map(|p| p.energy)
        .unwrap_or(1.0);

    let candidates: Vec<(usize, &audio_analysis::EnergyPoint)> = curve
        .iter()
        .enumerate()
        .filter(|(_, p)| p.time >= window_start && p.time <= window_end)
        .collect();

    if candidates.is_empty() {
        return None;
    }

    let mut local_minima = Vec::new();
    for (idx, p) in &candidates {
        let left_energy = if *idx > 0 { curve[*idx - 1].energy } else { p.energy };
        let right_energy = if *idx + 1 < curve.len() { curve[*idx + 1].energy } else { p.energy };
        if p.energy <= left_energy && p.energy <= right_energy {
            local_minima.push(*p);
        }
    }

    if let Some(best) = local_minima
        .iter()
        .filter(|p| p.energy < current_energy * 0.95 || p.energy < 0.7)
        .min_by(|a, b| a.energy.total_cmp(&b.energy))
    {
        return Some(best.time);
    }

    if let Some((_, min_cand)) = candidates
        .iter()
        .min_by(|(_, a), (_, b)| a.energy.total_cmp(&b.energy))
    {
        if min_cand.energy < current_energy * 0.8 && min_cand.energy < 0.6 {
            return Some(min_cand.time);
        }
    }

    None
}

/// [`analyze`], memoised on the file's identity and the vocal-model switch.
fn analyze_cached(
    path: &str,
    skip_vocals: bool,
    decode: &impl Fn(&str, f64, f64, bool) -> Option<(Vec<f32>, u32, f64)>,
    duration: f64,
) -> Arc<Analysis> {
    if duration <= 0.0 {
        // A caller that handed us something that is not a readable audio file —
        // a `yt:<videoId>` identifier rather than a path, most likely — lands
        // here, and the degradation is otherwise silent: `analyze` skips its
        // whole-track branch because the window is `duration` seconds long, so
        // `bpm` stays 0 and `assess` can only return `Tier::Plain`. Every
        // transition becomes a plain crossfade and nothing says why. The other
        // side of the pair still analyses normally, which is what made this so
        // hard to see: the plan's cue looked right.
        log::warn!(
            "automix: no duration for {path} — whole-track analysis and tempo verdict \
             skipped, so this pair can only plan a plain crossfade (not a readable audio file?)"
        );
    }
    analysis_cache::get_or_compute(path, skip_vocals, || analyze(path, skip_vocals, decode, duration))
}

pub fn plan_pair(
    outgoing_path: &str,
    incoming_path: &str,
    outgoing_text: &str,
    incoming_text: &str,
    album_sequential: bool,
    crossfade_seconds: f64,
    skip_vocals: bool,
    tier_label: &str,
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
    //
    // Even this one carries the outgoing track's length, because a plain
    // crossfade is still *scheduled* against the end of the outgoing track and
    // the mixer has to know where that is.
    let outgoing_duration = duration_of(outgoing_path);
    let out = analyze_cached(outgoing_path, skip_vocals, &decode, outgoing_duration);
    // Spoken or already-performed material is never smart-mixed. The fallback
    // is still anchored on the outgoing content end, so it does not wait out
    // the trailing silence and then cut.
    if blocked_text(outgoing_text) || blocked_text(incoming_text) {
        return plain_fallback(fade, &out);
    }

    // Upstream gapless path (TransitionPlanner.kt:893-905): an album played
    // through in order skips the DJ blend, unless the outgoing track has an
    // interior energy cliff worth mixing out of. The join itself is still a
    // ramp — upstream's 0.12 s handoff is a cut.
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
                transition_end_seconds: 0.0,
                cue_seconds: 0.0,
                playback_rate: 1.0,
                bed_fraction: 0.0,
                bed_gain_db: 0.0,
                dip_depth: 0.0,
                dip_width: 0.0,
                post_glide_seconds: 0.0,
                outgoing_duration_seconds: outgoing_duration,
            };
        }
    }

    let inc = analyze_cached(incoming_path, skip_vocals, &decode, duration_of(incoming_path));

    // The most ambitious move: a beat-matched, harmonically-compatible pair gets
    // a WSOLA phrase-switch before the adaptive overlap (upstream `phraseSwitch`).
    let plan = phrase_switch(&out, &inc).unwrap_or_else(|| plan_from(&out, &inc, fade));
    log_plan(&out, &inc, &plan, tier_label);
    plan
}

/// One line per planned transition, with the evidence that produced it.
///
/// The bug this exists to make diagnosable was invisible from the outside: a
/// track that lost forty-five seconds to a mix-in sounded exactly like a track
/// that had always been cued that way, and the mixer's `voice opened: …` line
/// reports the symptom (a large `start`) without the cause. These are the
/// inputs to [`incoming_cue`] and to [`assess`], so a wrong cue can be traced to
/// the read that produced it.
fn log_plan(outgoing: &Analysis, incoming: &Analysis, plan: &TransitionPlan, tier: &str) {
    let grid = |a: &Analysis| {
        format!(
            "bpm={:.1} conf={:.2} beat={:.3} downbeats={} audible={:.1} content_end={:.1} dur={:.1} vocal_p={:.2}",
            a.bpm,
            a.beat_confidence,
            a.beat_interval,
            a.downbeats.len(),
            a.audible_start_time,
            a.content_end,
            a.duration,
            a.vocal_probability,
        )
    };
    log::info!(
        "automix plan [{}] style={:?} cue={:.2}s fade={:.2}s end={:.1}s rate={:.4} \
         bed={:.2}@{:.0}dB dip={:.2} glide={:.1}s vocal_overlap={:.2} bass_swap={}@{:.2}",
        tier,
        plan.style,
        plan.cue_seconds,
        plan.fade_seconds,
        plan.transition_end_seconds,
        plan.playback_rate,
        plan.bed_fraction,
        plan.bed_gain_db,
        plan.dip_depth,
        plan.post_glide_seconds,
        plan.vocal_overlap,
        plan.bass_swap,
        plan.bass_swap_fraction,
    );
    log::info!(
        "automix out [{}]: {}",
        if outgoing.analysis_source.is_empty() {
            "dsp"
        } else {
            &outgoing.analysis_source
        },
        grid(outgoing)
    );
    log::info!(
        "automix in [{}]: {}",
        if incoming.analysis_source.is_empty() {
            "dsp"
        } else {
            &incoming.analysis_source
        },
        grid(incoming)
    );
    last_sources::set(&outgoing.analysis_source, &incoming.analysis_source);
}

/// The plain equal-power fallback shared by the speech guard and the tier.
///
/// Anchored on the outgoing mix-out (or its content end), never on the file's
/// last byte — that is the silence after the song, and fading there is why a
/// transition waited for one record to finish before the next began.
fn plain_fallback(fade: f64, outgoing: &Analysis) -> TransitionPlan {
    let mut end = resolve_mix_out_anchor(outgoing).0;
    if end <= 0.0 {
        end = if outgoing.content_end > 0.0 {
            outgoing.content_end
        } else {
            outgoing.duration
        };
    }
    TransitionPlan {
        style: TransitionStyle::EqualPower,
        bass_swap: false,
        bass_swap_fraction: DEFAULT_BASS_SWAP_FRACTION,
        filter_sweep: 0.0,
        vocal_overlap: 0.0,
        fade_seconds: fade,
        transition_end_seconds: end,
        cue_seconds: 0.0,
        playback_rate: 1.0,
        bed_fraction: 0.0,
        bed_gain_db: 0.0,
        dip_depth: 0.0,
        dip_width: 0.0,
        post_glide_seconds: 0.0,
        outgoing_duration_seconds: outgoing.duration,
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
    //
    // The buffer is kept so the head window below can read it rather than
    // decoding the same file again: three decodes per track was the port's
    // shape, and the whole-track pass is the expensive one — measured at 2.8 s
    // of a 4.2 s plan for a pair of four-minute tracks, more than twice both
    // ONNX models together.
    let mut whole: Option<(Vec<f32>, u32)> = None;
    if duration > 0.0 {
        if let Some((mono, rate, _)) = decode(path, 0.0, duration, true) {
            let decoded_seconds = if rate > 0 {
                mono.len() as f64 / rate as f64
            } else {
                0.0
            };
            if decoded_seconds < duration * MIN_DECODED_FRACTION {
                // Upstream refuses a short whole-track decode outright rather
                // than publishing it (`TrackAnalyzer.structure`). An analysis
                // that stops where the bytes ran out is indistinguishable,
                // downstream, from a track that simply goes quiet: `content_end`
                // lands at the end of the *bytes* and the mix-out anchor with
                // it, and the audible symptom is the track faded out minutes
                // early. A missing analysis degrades to a plain crossfade; a
                // confidently wrong one does not degrade at all. This is exactly
                // a still-downloading file.
                log::warn!(
                    "whole-track analysis refused for {path}: decoded \
                     {decoded_seconds:.1}s of a {duration:.1}s container"
                );
            } else {
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
            analysis.phrase_boundaries = audio.phrase_boundaries;
            analysis.section_boundaries = audio.section_boundaries;
            analysis.segment_boundaries = audio.segment_boundaries;
            analysis.energy_curve = audio.energy_curve;
            analysis.low_energy_curve = audio.low_energy_curve;
            analysis.pace_curve = audio.pace_curve;
            analysis.vocal_activity_mask = audio.vocal_activity_mask;
            analysis.drum_activity_mask = audio.drum_activity_mask;
            analysis.bass_activity_mask = audio.bass_activity_mask;
            analysis.beats = audio.beats;
            analysis.vocal_probability = audio.vocal_probability;
            analysis.analysis_source = "dsp".into();
            }
            whole = Some((mono, rate));
        }
    }

    // The Beat This! ONNX grid, when loaded, overrides the DSP tempo with a
    // stronger beat/downbeat grid on the head window — which is the head of the
    // buffer just decoded, so it is a slice rather than a second decode. The
    // fallback exists only for the case where the whole-track decode failed
    // outright.
    //
    // Whether the model actually ran is worth saying out loud. The graphs are a
    // first-run download rather than a build input, so "Automix is on" and "a
    // beat model is installed" are different states, and a plan built on the DSP
    // estimator is a different — and noticeably worse — plan. The symptom is
    // invisible from the outside: transitions still happen, they are just
    // coarser, and `mix_in_candidates` in particular used to be derived here and
    // never revisited, so a model grid could not fix it even once installed.
    // Beat This! over the whole decoded buffer when we have it. The head-only
    // window left mix-out anchors on a DSP grid while intros looked great —
    // Apple AutoMix's quality lives at the *end* of the outgoing track.
    let model_grid = if let Some((mono, rate)) = whole.as_ref() {
        beat::track(mono, *rate as f64, 0.0)
    } else if let Some((mono, rate, offset)) = decode(path, 0.0, head_len, true) {
        beat::track(&mono, rate as f64, offset)
    } else {
        None
    };
    match model_grid {
        Some(grid) => {
            log::info!(
                "automix analysis {path}: beat model grid {:.1} bpm, {} downbeats, confidence {:.2}",
                grid.bpm,
                grid.downbeats.len(),
                grid.beat_confidence,
            );
            fill_grid(&mut analysis, grid);
        }
        None => {
            log::info!(
                "automix analysis {path}: no beat-model grid — DSP tempo only \
                 ({:.1} bpm, confidence {:.2}). Transitions will be coarser; \
                 install the Automix beat model in Settings.",
                analysis.bpm, analysis.beat_confidence,
            );
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
    if let Some(overlay) = overlays::get(path) {
        apply_overlay(&mut analysis, &overlay);
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
    analysis.beats = grid.beats;
    // The DSP phrases were built on the DSP grid. Eight downbeats is the same
    // 32-beat phrase, on the grid that actually won.
    analysis.phrase_boundaries = analysis.downbeats.iter().step_by(8).copied().collect();
    if analysis.analysis_source.is_empty() || analysis.analysis_source == "dsp" {
        analysis.analysis_source = "beat_this".into();
    }
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
        // Instrument-activity proxy: prefer the beat where outgoing bass falls
        // and incoming bass rises (Music Understanding–style activity masks).
        let out_bass_before = mask_activity_between(
            &outgoing.bass_activity_mask,
            &outgoing.energy_curve,
            outgoing_at - outgoing_window,
            outgoing_at,
        );
        let out_bass_after = mask_activity_between(
            &outgoing.bass_activity_mask,
            &outgoing.energy_curve,
            outgoing_at,
            outgoing_at + outgoing_window,
        );
        let in_bass_before = mask_activity_between(
            &incoming.bass_activity_mask,
            &incoming.energy_curve,
            incoming_at - incoming_window,
            incoming_at,
        );
        let in_bass_after = mask_activity_between(
            &incoming.bass_activity_mask,
            &incoming.energy_curve,
            incoming_at,
            incoming_at + incoming_window,
        );
        let bass_handoff = match (out_bass_before, out_bass_after, in_bass_before, in_bass_after) {
            (Some(ob), Some(oa), Some(ib), Some(ia)) => (ob - oa) + (ia - ib),
            _ => 0.0,
        };
        if incoming_change.is_none() && outgoing_change.is_none() && bass_handoff.abs() < 0.05 {
            continue;
        }
        let score =
            incoming_change.unwrap_or(0.0) - outgoing_change.unwrap_or(0.0) + bass_handoff * 0.35;
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
        "section_boundary" => 0.88,
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

/// Mean of a parallel activity mask over `start`..`end` (same grid as energy).
fn mask_activity_between(mask: &[f64], curve: &[audio_analysis::EnergyPoint], start: f64, end: f64) -> Option<f64> {
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

/// Bonus when pace drops across a candidate mix-out (structure + novelty cue).
fn pace_drop_bonus(analysis: &Analysis, time: f64) -> f64 {
    if analysis.pace_curve.len() < 4 {
        return 0.0;
    }
    let before = analysis
        .pace_curve
        .iter()
        .filter(|p| p.time >= time - 4.0 && p.time < time)
        .map(|p| p.energy)
        .collect::<Vec<_>>();
    let after = analysis
        .pace_curve
        .iter()
        .filter(|p| p.time >= time && p.time <= time + 4.0)
        .map(|p| p.energy)
        .collect::<Vec<_>>();
    if before.is_empty() || after.is_empty() {
        return 0.0;
    }
    let mean = |vals: &[f64]| vals.iter().sum::<f64>() / vals.len() as f64;
    let drop = mean(&before) - mean(&after);
    if drop > 0.08 {
        0.06
    } else if drop > 0.03 {
        0.03
    } else {
        0.0
    }
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
        let rank_score = candidate.score
            + mix_out_type_score(&candidate.kind)
            + pace_drop_bonus(outgoing, candidate.time);
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
    let entry = incoming_entry(incoming);
    // Upstream `MIN_SMART_DURATION_SECONDS`: a track too short to spend a smart
    // transition on gets a plain crossfade (TransitionPlanner.kt:880-882).
    let too_short = (outgoing.duration > 0.0 && outgoing.duration < MIN_SMART_DURATION_SECONDS)
        || (incoming.duration > 0.0 && incoming.duration < MIN_SMART_DURATION_SECONDS);
    let tier = assess(outgoing, incoming);
    if matches!(tier, Tier::Plain) || too_short {
        let mut plan = plain_fallback(fade, outgoing);
        // Still enter at the top of the music, not at a drop and not at the
        // file's last byte.
        plan.cue_seconds = entry;
        return plan;
    }

    let out_bpm = outgoing.bpm;
    let in_bpm = incoming.bpm;
    let ratio = normalized_tempo_ratio(out_bpm, in_bpm);
    let same_beat = (1.0 - ratio).abs() <= 0.05
        && (outgoing.beat_confidence >= 0.2 || incoming.beat_confidence >= 0.2);
    // Only Beatmatched may stretch, and only inside MAX_BEATMATCH_STRETCH.
    // DjAssisted used to warp up to ±10% on the 0.9–1.1 band — that is the
    // Apple failure mode (tempo morph that draws attention to itself). A weak
    // grid keeps unity rate and lets the filter ride mask the gap instead.
    let playback_rate = if matches!(tier, Tier::Beatmatched) {
        transparent_playback_rate(out_bpm, in_bpm, MAX_BEATMATCH_STRETCH).unwrap_or(1.0)
    } else {
        1.0
    };
    let vocal_conflict = outgoing.vocal_probability >= 0.62 && incoming.vocal_probability >= 0.62;
    // A confident beat match with both voices out of the way earns the long
    // blend. Two singers, or a weak grid, stays inside upstream's 8–16 beats.
    let long = long_blend_allowed(outgoing, incoming) && !vocal_conflict;
    let key_distance = key_distance(&trusted_key(outgoing), &trusted_key(incoming));
    let overlap_beats = if long {
        LONG_BLEND_BEATS as f64
    } else if !vocal_conflict
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
    let max_seconds = if long {
        LONG_BLEND_SECONDS
    } else {
        AUTO_TRANSITION_MAX_SECONDS
    };
    let max_beats_cap = if long {
        LONG_BLEND_BEATS as f64
    } else {
        AUTO_TRANSITION_MAX_BEATS
    };
    let overlap = (overlap_beats * beat_seconds).clamp(min_overlap, max_seconds);

    // Where the outgoing record should be gone: its mix-out anchor, pulled
    // forward by an arrangement overlap when that anchor is just the content
    // end (upstream `outgoingArrangementOverlap`).
    let (anchor, _) = resolve_mix_out_anchor(outgoing);
    let content_end = if outgoing.content_end > 0.0 {
        outgoing.content_end
    } else {
        outgoing.duration
    };
    let arrangement = if same_beat && (anchor - content_end).abs() < 0.05 && out_bpm > 0.0 {
        (ARRANGEMENT_OVERLAP_BEATS * 60.0 / out_bpm).min(MAX_DISCARDED_MUSIC_SECONDS)
    } else {
        0.0
    };
    let mix_end = (anchor - arrangement).max(0.0);
    let mut max_overlap = (max_beats_cap * beat_seconds)
        .min(max_seconds)
        .min((mix_end * 0.4).max(min_overlap))
        .min(if incoming.duration > 0.0 {
            (incoming.duration * 0.4).max(min_overlap)
        } else {
            max_seconds
        })
        .max(min_overlap);
    // Mixxx Auto DJ: fade length ≈ min(usable outro, usable intro) when both
    // sections are known. Caps the overlap before handoff math so the cue and
    // the fade agree.
    if let Some(cap) = section_fade_cap(outgoing, incoming) {
        max_overlap = max_overlap.min(cap.max(min_overlap));
    }

    let handoff_beats = if same_beat { 8.0 } else { 4.0 };
    let handoff_seconds = if out_bpm > 0.0 {
        (handoff_beats * 60.0 / out_bpm).clamp(2.0, if same_beat { 6.0 } else { 5.0 })
    } else {
        4.0
    };

    // The drop is the handoff, not the cue. Playback starts `overlap` earlier,
    // and never more than eight seconds past the entry.
    let drop = incoming_handoff(incoming, max_overlap);
    let aligned_in = align_tempo_octave(out_bpm, in_bpm);
    let requested_handoff = if same_beat && aligned_in > 0.0 {
        drop + ARRANGEMENT_OVERLAP_BEATS * 60.0 / aligned_in
    } else {
        drop
    };
    let max_in_handoff = incoming.duration - MIN_CLEARANCE_SECONDS;
    let handoff = if max_in_handoff >= drop {
        requested_handoff.min(max_in_handoff)
    } else {
        drop
    };

    // A Beatmatched pair with a transparent stretch earns DjBlend. Anything
    // else — DjAssisted, far tempo, refused stretch — rides filters so the
    // ear never hears a chipmunk or a slow-mo vocal.
    let beatmatched_blend =
        matches!(tier, Tier::Beatmatched) && same_beat && (playback_rate - 1.0).abs() <= MAX_BEATMATCH_STRETCH + 1e-6;

    let (transition_start, fade_seconds) = if beatmatched_blend && beat_seconds > 0.0 {
        let intro_span = handoff / playback_rate.max(0.8);
        let total = intro_span.clamp(12.0_f64.min(max_overlap), max_overlap);
        let target = (mix_end - total).max(0.0);
        let earliest = (mix_end - max_overlap).max(0.0);
        let start = aligned_transition_start(
            outgoing,
            target,
            (mix_end - 0.05).max(earliest),
            true,
            earliest,
        );
        realized_window(mix_end, start, total, min_overlap)
    } else {
        let desired = overlap.max(handoff_seconds * 0.42);
        let actual = desired.clamp(handoff_seconds.min(max_overlap), max_overlap);
        let target = (mix_end - actual).max(0.0);
        let earliest = (mix_end - max_overlap).max(0.0);
        let start = aligned_transition_start(
            outgoing,
            target,
            (mix_end - 0.05).max(earliest),
            desired > overlap + 0.5,
            earliest,
        );
        realized_window(mix_end, start, actual, min_overlap)
    };
    let cue = cue_for(entry, handoff, fade_seconds, playback_rate);

    let incoming_beat_seconds = if in_bpm > 0.0 { 60.0 / in_bpm } else { 0.5 };
    let bass_swap_fraction = if beatmatched_blend {
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
        transition_start + fade_seconds,
        cue,
        playback_rate,
    );
    let style = if beatmatched_blend {
        TransitionStyle::DjBlend
    } else {
        TransitionStyle::DjFilter
    };
    let shape = mix_shape(
        style,
        beatmatched_blend,
        vocal_overlap,
        vocal_conflict,
        fade_seconds,
        beat_seconds,
        bass_swap_fraction,
        playback_rate,
        out_bpm,
    );

    TransitionPlan {
        // Beatmatched + transparent stretch → DjBlend. DjAssisted used to
        // blend on tempo proximity alone; that stretched weak grids. Filter.
        style,
        bass_swap: true,
        bass_swap_fraction,
        filter_sweep: if same_beat { 0.0 } else { FILTER_SWEEP },
        vocal_overlap,
        fade_seconds,
        transition_end_seconds: transition_start + fade_seconds,
        cue_seconds: cue,
        playback_rate,
        bed_fraction: shape.bed_fraction,
        bed_gain_db: shape.bed_gain_db,
        dip_depth: shape.dip_depth,
        dip_width: shape.dip_width,
        post_glide_seconds: shape.post_glide_seconds,
        outgoing_duration_seconds: outgoing.duration,
    }
}

struct MixShape {
    bed_fraction: f64,
    bed_gain_db: f64,
    dip_depth: f64,
    dip_width: f64,
    post_glide_seconds: f64,
}

/// Bed, dip and post-blend glide for one planned blend. A plain crossfade
/// gets zeros, which is how the mixer knows to stay equal-power.
fn mix_shape(
    style: TransitionStyle,
    same_beat: bool,
    vocal_overlap: f64,
    vocal_conflict: bool,
    fade_seconds: f64,
    beat_seconds: f64,
    swap_fraction: f64,
    playback_rate: f64,
    bpm: f64,
) -> MixShape {
    if !matches!(style, TransitionStyle::DjBlend | TransitionStyle::DjFilter) {
        return MixShape {
            bed_fraction: 0.0,
            bed_gain_db: 0.0,
            dip_depth: 0.0,
            dip_width: 0.0,
            post_glide_seconds: 0.0,
        };
    }
    let clash = vocal_overlap.clamp(0.0, 1.0).max(if vocal_conflict { 0.7 } else { 0.0 });
    let dip = if same_beat {
        (0.28 + 0.5 * clash).clamp(0.0, MAX_DUCK_DEPTH)
    } else {
        (0.2 * clash).clamp(0.0, MAX_DUCK_DEPTH)
    };
    let rise = if fade_seconds > 0.0 && beat_seconds > 0.0 {
        (2.0 * beat_seconds / fade_seconds).clamp(0.08, 0.3)
    } else {
        0.15
    };
    let bed = (swap_fraction - rise).clamp(0.15, 0.8);
    let dip_width = if fade_seconds > 0.0 && beat_seconds > 0.0 {
        (beat_seconds / fade_seconds).clamp(0.02, 0.2)
    } else {
        0.06
    };
    let post_glide_seconds = if same_beat && (playback_rate - 1.0).abs() > 1e-3 && bpm > 0.0 {
        POST_BLEND_GLIDE_BEATS * 60.0 / bpm
    } else {
        0.0
    };
    MixShape {
        bed_fraction: bed,
        bed_gain_db: BED_GAIN_DB,
        dip_depth: dip,
        dip_width,
        post_glide_seconds,
    }
}

fn long_blend_allowed(outgoing: &Analysis, incoming: &Analysis) -> bool {
    assess(outgoing, incoming) == Tier::Beatmatched
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

/// Rate that brings the incoming tempo onto the outgoing one, or `None` when
/// the stretch would be audible. Octave-aligned first.
fn transparent_playback_rate(
    outgoing_bpm: f64,
    incoming_bpm: f64,
    max_deviation: f64,
) -> Option<f64> {
    if outgoing_bpm <= 0.0 || incoming_bpm <= 0.0 || max_deviation < 0.0 {
        return None;
    }
    let aligned = align_tempo_octave(outgoing_bpm, incoming_bpm);
    let rate = outgoing_bpm / aligned;
    if (rate - 1.0).abs() <= max_deviation {
        Some(((rate * 10_000.0).round()) / 10_000.0)
    } else {
        None
    }
}

/// Mixxx-style fade cap: min(outro length, intro length) when both sections
/// look real. `None` means "no useful section lengths — leave the beat math".
fn section_fade_cap(outgoing: &Analysis, incoming: &Analysis) -> Option<f64> {
    let content_end = if outgoing.content_end > 0.0 {
        outgoing.content_end
    } else {
        outgoing.duration
    };
    let outro_len = if outgoing.outro_start > 0.0 && content_end > outgoing.outro_start + 1.0 {
        content_end - outgoing.outro_start
    } else {
        return None;
    };
    let audible = if incoming.audible_start_time.is_finite() && incoming.audible_start_time >= 0.0 {
        incoming.audible_start_time
    } else {
        0.0
    };
    let intro_end = if incoming.mix_in_time > audible + 1.0 {
        incoming.mix_in_time
    } else {
        return None;
    };
    let intro_len = intro_end - audible;
    if outro_len < 2.0 || intro_len < 2.0 {
        return None;
    }
    Some(outro_len.min(intro_len))
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

/// Where playback of the incoming track starts: the earliest point it makes
/// sound, snapped to a downbeat, and bounded so a mix-in cannot skip the front
/// of the record.
///
/// This is not the drop. The drop is [`incoming_handoff`]; playback begins
/// `overlap` before that, and [`cue_for`] keeps the result within eight
/// seconds of this entry.
fn incoming_entry(analysis: &Analysis) -> f64 {
    let duration = analysis.duration;
    let beat_seconds = beat_seconds_of(analysis);
    let grid = beat_seconds > 0.0
        && analysis
            .downbeats
            .iter()
            .any(|d| d.is_finite() && *d >= 0.0);
    if !grid {
        // No grid, no skip. Without a beat to align to there is nothing to say
        // how deep a mix-in should reach, and the honest answer is the top of
        // the file: a missing analysis degrades to "play it from the start",
        // never to "start at a drop we guessed at".
        return 0.0;
    }

    // The earliest music, from the phase-1 candidates (a single `pickup` at the
    // pickup point) with the envelope's own measurement as the backstop.
    let entry = analysis
        .mix_in_candidates
        .iter()
        .filter(|c| c.time.is_finite() && c.time >= 0.0)
        .map(|c| c.time)
        .chain([analysis.audible_start_time].into_iter())
        .fold(f64::INFINITY, f64::min);
    let entry = if entry.is_finite() { entry } else { 0.0 };

    // Snap forward onto the grid: entering between beats is the one thing a
    // listener hears as "edited" rather than "mixed". Bounded to one beat past
    // the pickup, so a grid that starts late cannot drag the entry with it.
    let snapped = analysis
        .downbeats
        .iter()
        .copied()
        .filter(|d| d.is_finite() && *d >= entry - 1e-3 && *d <= entry + beat_seconds)
        .min_by(|a, b| a.total_cmp(b))
        .unwrap_or(entry);

    cap_cue(snapped, entry, beat_seconds, duration)
}

/// The tests still talk about the cue. It is the entry.
#[cfg(test)]
fn incoming_cue(analysis: &Analysis) -> f64 {
    incoming_entry(analysis)
}

/// A track's beat length, or 0 when there is no usable tempo. A BPM outside
/// the analyser's own range means the read failed, and a failed read must not
/// become a 32-beat cue.
fn beat_seconds_of(analysis: &Analysis) -> f64 {
    if !(MIN_BPM..=MAX_BPM).contains(&analysis.bpm) {
        return 0.0;
    }
    let from_bpm = 60.0 / analysis.bpm;
    if analysis.beat_interval.is_finite() && analysis.beat_interval > 0.0 {
        // Trust the grid's own interval when the two agree; the two can differ
        // by an octave after `align_tempo_octave`, and the grid is what the
        // downbeats are actually spaced at.
        if (analysis.beat_interval - from_bpm).abs() / from_bpm < 0.5 {
            return analysis.beat_interval;
        }
    }
    from_bpm
}

/// The three bounds on a mix-in. Together they mean a listener never loses the
/// front of a record to a transition, however long it is or however badly the
/// analysis read.
fn cap_cue(cue: f64, entry: f64, beat_seconds: f64, duration: f64) -> f64 {
    let in_mix_in_window = |t: f64| {
        t.is_finite()
            && t >= 0.0
            && (duration <= 0.0 || t < duration - MIX_IN_END_MARGIN_SECONDS)
    };
    let cue = if in_mix_in_window(cue) { cue } else { 0.0 };
    let mut cap = MAX_CUE_SECONDS.min(MAX_CUE_BEATS * beat_seconds);
    if duration > 0.0 {
        // On a long set or a DJ track, a flat 8 s cap still throws away music;
        // a fraction of the track keeps the skip proportional to the track.
        cap = cap.min(duration * MAX_CUE_FRACTION);
    }
    if cue <= cap {
        return cue;
    }
    // Over the cap, fall back to the pickup — which is the top of the music, and
    // what the track would have played from anyway.
    if entry <= cap && in_mix_in_window(entry) {
        entry
    } else {
        0.0
    }
}

/// Where the incoming arrangement arrives — the drop — if the overlap can
/// cover the distance from the entry. Otherwise the handoff is the entry plus
/// that overlap, which is a long intro played underneath, not a skip.
fn incoming_handoff(analysis: &Analysis, max_overlap_s: f64) -> f64 {
    let entry = incoming_entry(analysis);
    let budget = max_overlap_s.max(0.0);
    let beat = beat_seconds_of(analysis);
    let mut ranked: Vec<&audio_analysis::MixCuePoint> = analysis
        .mix_in_candidates
        .iter()
        .filter(|c| c.kind != "pickup" && c.time.is_finite() && c.time > entry + 0.25)
        .collect();
    ranked.sort_by(|a, b| b.score.total_cmp(&a.score));
    if let Some(drop) = ranked.first() {
        let snapped = if beat > 0.0 {
            nearest_value(&analysis.downbeats, drop.time, 0.5_f64.max(beat * 2.0))
                .unwrap_or(drop.time)
        } else {
            drop.time
        };
        if snapped >= entry && snapped - entry <= budget + 0.05 {
            return snapped;
        }
    }
    if analysis.mix_in_time.is_finite()
        && analysis.mix_in_time > entry + 0.25
        && analysis.mix_in_time - entry <= budget + 0.05
    {
        return analysis.mix_in_time;
    }
    entry + budget
}

/// Playback starts `overlap * rate` before the handoff, and never more than
/// eight seconds past the entry.
fn cue_for(entry: f64, handoff: f64, overlap: f64, rate: f64) -> f64 {
    let rate = if rate.is_finite() && rate > 0.0 { rate } else { 1.0 };
    let raw = if overlap.is_finite() {
        handoff - overlap * rate
    } else {
        entry
    };
    raw.max(entry).max(0.0).min(entry + MAX_CUE_SECONDS)
}

fn timed_near_or_before(values: &[f64], target: f64, tolerance: f64, minimum: f64) -> Option<f64> {
    values
        .iter()
        .copied()
        .filter(|v| v.is_finite() && *v >= minimum && *v <= target && target - *v <= tolerance)
        .max_by(|a, b| a.total_cmp(b))
}

fn nearest_timed(values: &[f64], target: f64, tolerance: f64, minimum: f64) -> Option<f64> {
    values
        .iter()
        .copied()
        .filter(|v| v.is_finite() && *v >= minimum && (*v - target).abs() <= tolerance)
        .min_by(|a, b| (*a - target).abs().total_cmp(&(*b - target).abs()))
}

/// Snaps a transition start onto the outgoing grid: a phrase boundary if one
/// is near, a downbeat otherwise (upstream `alignedTransitionStart`).
fn aligned_transition_start(
    analysis: &Analysis,
    target: f64,
    end: f64,
    prefer_earlier: bool,
    minimum: f64,
) -> f64 {
    let interval = beat_seconds_of(analysis);
    let phrase_tolerance = 1.0_f64.max(interval * 4.0);
    let downbeat_tolerance = 0.75_f64.max(interval * 2.0);
    let phrase = if prefer_earlier {
        timed_near_or_before(&analysis.phrase_boundaries, target, phrase_tolerance, minimum)
    } else {
        nearest_timed(&analysis.phrase_boundaries, target, phrase_tolerance, minimum)
    };
    let downbeat = if prefer_earlier {
        timed_near_or_before(&analysis.downbeats, target, downbeat_tolerance, minimum)
    } else {
        nearest_timed(&analysis.downbeats, target, downbeat_tolerance, minimum)
    };
    let chosen = phrase.or(downbeat).unwrap_or(target);
    if end < minimum {
        return chosen.max(0.0).min(end.max(0.0));
    }
    chosen.clamp(minimum, end)
}

/// The blend that actually plays, after the grid snap.
///
/// [`aligned_transition_start`] clamps onto `mix_end - 0.05`. When the only
/// boundary in range is the end itself, `mix_end - start` collapses, and a
/// floor of half a second rendered that collapse as a cut. Upstream's floor
/// is four seconds (six on a fast track). A snap that kept the blend is left
/// alone; a snap that ate it is discarded and the planned length is restored.
/// A tail shorter than the floor uses the tail — there is nothing else to
/// blend across.
fn realized_window(mix_end: f64, snapped_start: f64, desired: f64, minimum: f64) -> (f64, f64) {
    let mix_end = mix_end.max(0.0);
    let snapped = (mix_end - snapped_start).max(0.0);
    let minimum = minimum.min(mix_end);
    let fade = if snapped + 0.25 >= minimum {
        snapped.max(minimum)
    } else {
        desired.max(minimum)
    };
    let fade = fade.min(mix_end);
    ((mix_end - fade).max(0.0), fade)
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
    // Refuse the phrase-switch rather than warp past the transparent band —
    // the adaptive-overlap path will offer a filtered handoff instead.
    let stretch_ratio =
        transparent_playback_rate(outgoing_bpm, incoming.bpm, MAX_BEATMATCH_STRETCH)?;

    let outgoing_length = outgoing.duration;
    let incoming_length = incoming.duration;
    if outgoing_length <= 0.0 || incoming_length <= 0.0 {
        return None;
    }

    let incoming_beat_seconds = 60.0 / incoming_bpm;
    let outgoing_beat_seconds = 60.0 / outgoing_bpm;

    let long = long_blend_allowed(outgoing, incoming);
    let max_seconds = if long {
        LONG_BLEND_SECONDS
    } else {
        UPSTREAM_MAX_OVERLAP_SECONDS
    };
    let max_beats = if long {
        LONG_BLEND_BEATS
    } else {
        UPSTREAM_MAX_FADE_BEATS
    };
    // The drop, or the furthest handoff the overlap can reach. Never the cue.
    let incoming_drop_time = incoming_handoff(incoming, max_seconds);

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
        ((max_seconds / incoming_beat_seconds).floor() as usize / 4) * 4;
    if capped_by_overlap < MIN_FADE_BEATS {
        return None;
    }
    let mut fade_beats = max_beats
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
    let entry = incoming_entry(incoming);
    let incoming_cue_time = cue_for(entry, incoming_handoff_time, overlap_seconds, stretch_ratio);
    if incoming_cue_time < audible_start - 0.5 {
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

    let vocal_conflict = outgoing.vocal_probability >= 0.62 && incoming.vocal_probability >= 0.62;
    let style = TransitionStyle::DjBlend;
    let playback_rate = stretch_ratio;
    let fade_seconds = transition_end - transition_start;
    let shape = mix_shape(
        style,
        true,
        vocal_overlap,
        vocal_conflict,
        fade_seconds,
        outgoing_beat_seconds,
        bass_swap_fraction,
        playback_rate,
        outgoing_bpm,
    );
    Some(TransitionPlan {
        style,
        bass_swap: true,
        bass_swap_fraction,
        filter_sweep: 0.0,
        vocal_overlap,
        fade_seconds,
        transition_end_seconds: transition_end,
        cue_seconds: incoming_cue_time,
        playback_rate,
        bed_fraction: shape.bed_fraction,
        bed_gain_db: shape.bed_gain_db,
        dip_depth: shape.dip_depth,
        dip_width: shape.dip_width,
        post_glide_seconds: shape.post_glide_seconds,
        outgoing_duration_seconds: outgoing.duration,
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
    use std::sync::atomic::{AtomicUsize, Ordering};

    /// The cache is what stops a transport command from re-decoding both tracks.
    /// It must key on the file's *content identity*, not just its path: a
    /// streamed download is appended to under a stable name, and serving a
    /// half-downloaded file's analysis forever would misplace every cue.
    #[test]
    fn analysis_cache_hits_by_identity_and_misses_when_the_file_grows() {
        let dir = std::env::temp_dir().join("bitchord-plan-cache");
        std::fs::create_dir_all(&dir).unwrap();
        let path = dir.join("growing.bin");
        std::fs::write(&path, vec![0u8; 1024]).unwrap();
        let key = path.to_string_lossy().to_string();

        let computed = AtomicUsize::new(0);
        let mut compute = || {
            computed.fetch_add(1, Ordering::SeqCst);
            Analysis::default()
        };

        let first = analysis_cache::get_or_compute(&key, false, &mut compute);
        let second = analysis_cache::get_or_compute(&key, false, &mut compute);
        assert_eq!(computed.load(Ordering::SeqCst), 1, "a repeat must be a hit");
        assert!(Arc::ptr_eq(&first, &second), "a hit returns the same analysis");

        // The same path with more bytes is a different file as far as planning
        // is concerned.
        std::fs::write(&path, vec![0u8; 2048]).unwrap();
        let _ = analysis_cache::get_or_compute(&key, false, &mut compute);
        assert_eq!(
            computed.load(Ordering::SeqCst),
            2,
            "a grown file must be analysed again, not served from the cache"
        );

        // The vocal-model switch is part of the identity too.
        let _ = analysis_cache::get_or_compute(&key, true, &mut compute);
        assert_eq!(computed.load(Ordering::SeqCst), 3);
    }

    /// A track whose music starts at `first_beat`, on a 120 BPM grid. The
    /// pickup is reported the way the real analysis reports it — as both the
    /// envelope's `audible_start` and the grid's `first_beat` — because the
    /// cue is derived from whichever of them is earliest.
    fn analysis(first_beat: f64, duration: f64, downbeats: Vec<f64>) -> Analysis {
        Analysis {
            first_beat,
            audible_start_time: first_beat,
            duration,
            downbeats,
            bpm: 120.0,
            beat_interval: 0.5,
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
    fn transparent_playback_rate_refuses_apple_style_warps() {
        // 120 → 90 is a 25% stretch after octave alignment fails to help.
        assert!(transparent_playback_rate(120.0, 90.0, MAX_BEATMATCH_STRETCH).is_none());
        // 120 → 122 is ~1.67% — transparent.
        let rate = transparent_playback_rate(120.0, 122.0, MAX_BEATMATCH_STRETCH).unwrap();
        assert!((rate - 120.0 / 122.0).abs() < 1e-4, "rate {rate}");
        // Octave cousins: 60 against 120 aligns to unity.
        let octave = transparent_playback_rate(120.0, 60.0, MAX_BEATMATCH_STRETCH).unwrap();
        assert!((octave - 1.0).abs() < 1e-4, "octave {octave}");
    }

    #[test]
    fn dj_assisted_near_tempo_does_not_stretch() {
        // Same tempo neighbourhood, weak grids → DjAssisted. Must keep unity
        // rate and ride filters rather than warp (Apple's failure mode).
        let mut out = matched(0.5, 200.0);
        out.beat_confidence = 0.4; // below MIN_BEATMATCH_CONFIDENCE (0.55)
        let mut inc = matched(0.5, 200.0);
        inc.bpm = 126.0; // 5% fast — inside the old ±10% assisted band
        inc.beat_interval = 60.0 / 126.0;
        inc.beat_confidence = 0.4;
        assert_eq!(assess(&out, &inc), Tier::DjAssisted);
        let plan = plan_from(&out, &inc, 8.0);
        assert!(
            (plan.playback_rate - 1.0).abs() < 1e-9,
            "DjAssisted stretched to {}",
            plan.playback_rate
        );
        assert_eq!(plan.style, TransitionStyle::DjFilter);
        let smooth = super::super::smoothness::score_plan(&plan);
        assert!(!smooth.forced_stretch);
    }

    #[test]
    fn section_fade_cap_takes_the_shorter_section() {
        let mut out = matched(0.5, 200.0);
        out.outro_start = 170.0;
        out.content_end = 180.0; // 10 s outro
        let mut inc = matched(0.5, 200.0);
        inc.audible_start_time = 0.5;
        inc.mix_in_time = 6.5; // 6 s intro
        let cap = section_fade_cap(&out, &inc).expect("both sections known");
        assert!((cap - 6.0).abs() < 1e-9, "cap {cap}");
    }

    #[test]
    fn overlay_skips_half_tempo_when_beat_this_grid_is_trusted() {
        let mut analysis = matched(0.5, 200.0);
        analysis.bpm = 148.7;
        analysis.beat_interval = 60.0 / 148.7;
        analysis.beat_confidence = 0.75;
        analysis.downbeats = vec![0.0, 1.615, 3.23];
        analysis.analysis_source = "beat_this".into();
        analysis.key = "C minor".into();
        apply_overlay(
            &mut analysis,
            &AnalysisOverlay {
                bpm: Some(74.5),
                beat_confidence: Some(0.85),
                beat_interval: Some(60.0 / 74.5),
                beats: None,
                downbeats: Some(vec![0.0, 3.23]),
                key: Some("C minor".into()),
                key_confidence: Some(0.8),
                phrase_boundaries: Some(vec![8.0, 16.0]),
                vocal_probability: None,
                content_end: None,
                audible_start: None,
                outro_start: None,
                mix_in_time: None,
                source: "music_understanding".into(),
            },
        );
        assert!(
            (analysis.bpm - 148.7).abs() < 0.01,
            "kept Beat This tempo, got {}",
            analysis.bpm
        );
        assert_eq!(analysis.phrase_boundaries, vec![8.0, 16.0]);
        assert!(analysis.analysis_source.contains("music_understanding"));
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

    /// A mix-in is the top of the next record, not its drop.
    ///
    /// Regression: the cue used to be the highest-ranked phase-1 candidate, and
    /// that ranking put `main_drop` — 32 beats in — above `pickup`. Worse, when
    /// the DSP tempo read failed, `beat_interval` was 0, which sent the drop
    /// candidate to `intro_end_time`: the first moment the track got *loud*,
    /// capped at 48 s. That is a mix-*out* question used as a mix-in question,
    /// and it is where "the next song starts a minute in" came from.
    #[test]
    fn a_mix_in_never_reaches_for_the_drop() {
        // 120 BPM, pickup at 2 s, and a grid running the length of the track.
        let downbeats: Vec<f64> = (0..40).map(|i| 2.0 + i as f64 * 2.0).collect();
        let cue = incoming_cue(&analysis(2.0, 240.0, downbeats));
        assert!(
            (cue - 2.0).abs() < 1e-9,
            "a beat-aligned pickup at 2 s should cue at 2 s, got {cue}"
        );

        // And with the analysis reporting its pickup through the candidate list,
        // which is where the real value comes from.
        let with_candidate_grid: Vec<f64> = (0..40).map(|i| 2.0 + i as f64 * 2.0).collect();
        let mut with_candidate = analysis(2.0, 240.0, with_candidate_grid);
        with_candidate.audible_start_time = 2.0;
        with_candidate.mix_in_candidates = vec![audio_analysis::MixCuePoint {
            time: 2.0,
            score: 0.8,
            kind: "pickup".into(),
        }];
        assert!((incoming_cue(&with_candidate) - 2.0).abs() < 1e-9);
    }

    /// No usable grid means the top of the file, and never a guess.
    ///
    /// This is the degraded path in its purest form: the analysis is empty, so
    /// there is nothing to align to and nothing to say how deep a mix-in should
    /// reach. A plain crossfade from 0 is right; a crossfade from 45 s is the
    /// bug.
    #[test]
    fn a_mix_in_without_a_beat_grid_starts_at_the_top() {
        // No tempo at all.
        let mut blind = analysis(0.0, 200.0, vec![0.5, 1.0, 1.5, 2.0]);
        blind.bpm = 0.0;
        blind.beat_interval = 0.0;
        assert_eq!(incoming_cue(&blind), 0.0, "no tempo must not become a deep cue");

        // A tempo outside the analyser's own range means the read failed, and a
        // failed read must not turn into a 32-beat cue either.
        let mut absurd = analysis(0.0, 200.0, vec![0.5, 1.0, 1.5, 2.0]);
        absurd.bpm = 12.0;
        absurd.beat_interval = 5.0;
        assert_eq!(incoming_cue(&absurd), 0.0, "an out-of-range tempo is not a grid");

        // A tempo with no downbeats is no grid either.
        let mut no_downbeats = analysis(0.0, 200.0, vec![]);
        no_downbeats.audible_start_time = 1.0;
        assert_eq!(incoming_cue(&no_downbeats), 0.0);
    }

    /// The three bounds, each of which is the one that bites in its own case.
    #[test]
    fn a_mix_in_is_bounded_by_seconds_beats_and_the_track() {
        // Seconds: a pickup deep into the record is pulled back to eight.
        let deep: Vec<f64> = (0..40).map(|i| 30.0 + i as f64 * 0.5).collect();
        let mut slow = analysis(30.0, 240.0, deep);
        slow.audible_start_time = 30.0;
        let cue = incoming_cue(&slow);
        assert!(
            cue <= MAX_CUE_SECONDS + 1e-9,
            "cue {cue} exceeded the {MAX_CUE_SECONDS}s cap"
        );

        // Beats: 16 beats of a 40 BPM track is 24 s, so the beat cap is the one
        // that applies — and a failed read at 40 BPM must not become 32 beats.
        let slow_grid: Vec<f64> = (0..200).map(|i| 1.0 + i as f64 * 1.5).collect();
        let mut ballad = analysis(1.0, 600.0, slow_grid);
        ballad.bpm = 40.0;
        ballad.beat_interval = 1.5;
        ballad.audible_start_time = 40.0;
        let cue = incoming_cue(&ballad);
        assert!(
            cue <= MAX_CUE_BEATS * 1.5 + 1e-9,
            "cue {cue} exceeded {MAX_CUE_BEATS} beats"
        );

        // Fraction: short material gets a proportionally smaller entry, because
        // eight seconds is an eighth of a one-minute clip and nothing at all in
        // a four-minute song.
        let short: Vec<f64> = (0..200).map(|i| 0.2 + i as f64 * 0.5).collect();
        let mut brief = analysis(0.2, 60.0, short);
        brief.audible_start_time = 12.0;
        let cue = incoming_cue(&brief);
        assert!(
            cue <= 60.0 * MAX_CUE_FRACTION + 1e-9,
            "cue {cue} exceeded {MAX_CUE_FRACTION} of a one-minute track"
        );
    }

    /// The cue lands on a beat, because entering between beats is the one thing
    /// a listener hears as "edited" rather than "mixed".
    #[test]
    fn a_mix_in_lands_on_the_grid() {
        let downbeats: Vec<f64> = (0..40).map(|i| 0.25 + i as f64 * 0.5).collect();
        let mut track = analysis(0.25, 200.0, downbeats.clone());
        // A pickup that falls a little after a downbeat.
        track.audible_start_time = 1.4;
        let cue = incoming_cue(&track);
        assert!(
            downbeats.iter().any(|d| (d - cue).abs() < 1e-6),
            "cue {cue} is not on the grid"
        );
        assert!(
            cue >= 1.4 && cue <= 1.4 + 0.5 + 1e-6,
            "cue {cue} should be the first downbeat at or after the 1.4 s pickup"
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

    fn matched(first_beat: f64, duration: f64) -> Analysis {
        let step = 0.5;
        let downbeats: Vec<f64> = (0..((duration / step) as usize))
            .map(|i| first_beat + i as f64 * step)
            .filter(|t| *t < duration)
            .collect();
        let mut track = analysis(first_beat, duration, downbeats);
        track.beat_confidence = 0.9;
        track.content_end = duration;
        track.key = "C major".into();
        track.key_confidence = 0.9;
        track
    }

    /// An eight-bar intro is a runway, so the phrase switch fires and the cue
    /// stays at the top of that intro.
    #[test]
    fn phrase_switch_fires_on_an_eight_bar_intro_and_starts_at_the_entry() {
        let out = matched(0.5, 200.0);
        let mut inc = matched(0.5, 200.0);
        // 32 beats of intro: the drop, not the cue.
        inc.mix_in_candidates = vec![audio_analysis::MixCuePoint {
            time: 0.5 + 32.0 * 0.5,
            score: 0.95,
            kind: "main_drop".into(),
        }];
        let plan = phrase_switch(&out, &inc).expect("an eight-bar intro should phrase-switch");
        assert_eq!(plan.style, TransitionStyle::DjBlend);
        let entry = incoming_entry(&inc);
        assert!(
            plan.cue_seconds <= entry + MAX_CUE_SECONDS + 1e-6,
            "cue {} started more than {MAX_CUE_SECONDS}s past the entry {entry}",
            plan.cue_seconds
        );
        assert!(
            plan.cue_seconds < 0.5 + 32.0 * 0.5 - 1.0,
            "cue {} is the drop, not the entry",
            plan.cue_seconds
        );
        assert!(plan.bed_fraction > 0.0, "a phrase switch is a bed, not a crossfade");
    }

    #[test]
    fn a_cue_is_never_more_than_eight_seconds_past_the_entry() {
        assert!(
            (cue_for(1.0, 80.0, 8.0, 1.0) - 9.0).abs() < 1e-9,
            "80 - 8 = 72, which must clamp to entry + 8"
        );
        let out = matched(0.5, 240.0);
        let mut inc = matched(0.5, 240.0);
        inc.mix_in_candidates = vec![audio_analysis::MixCuePoint {
            time: 90.0,
            score: 0.95,
            kind: "main_drop".into(),
        }];
        let plan = plan_from(&out, &inc, 8.0);
        let entry = incoming_entry(&inc);
        assert!(
            plan.cue_seconds <= entry + MAX_CUE_SECONDS + 1e-6,
            "cue {} exceeded entry {entry} + {MAX_CUE_SECONDS}s",
            plan.cue_seconds
        );
    }

    #[test]
    fn a_plain_crossfade_ends_where_the_music_ends() {
        let mut out = analysis(0.5, 200.0, vec![]);
        out.bpm = 0.0;
        out.beat_interval = 0.0;
        out.content_end = 170.0;
        let inc = analysis(0.5, 200.0, vec![]);
        let plan = plan_from(&out, &inc, 8.0);
        assert_eq!(plan.style, TransitionStyle::EqualPower);
        assert!(
            (plan.transition_end_seconds - 170.0).abs() < 1e-6,
            "plain fade ended at {}, not the content end",
            plan.transition_end_seconds
        );
        assert_eq!(plan.bed_fraction, 0.0);
        assert_eq!(plan.dip_depth, 0.0);
    }

    /// A grid snap that lands on the mix-out used to leave `mix_end - start`
    /// at a few dozen milliseconds, and `.max(0.5)` turned every one of those
    /// into a half-second cut.
    #[test]
    fn a_snapped_start_cannot_shrink_the_blend_to_half_a_second() {
        let (start, fade) = realized_window(180.0, 179.95, 12.0, AUTO_MIN_SECONDS);
        assert!(
            (fade - 12.0).abs() < 1e-6,
            "a collapsed snap must restore the planned blend, got {fade}s"
        );
        assert!((start - 168.0).abs() < 1e-6, "start {start}");

        let (kept_start, kept_fade) = realized_window(180.0, 168.0, 12.0, AUTO_MIN_SECONDS);
        assert!((kept_fade - 12.0).abs() < 1e-6, "a good snap stays, got {kept_fade}");
        assert!((kept_start - 168.0).abs() < 1e-6);

        // The tail is the whole window: do not invent blend time the track
        // does not have.
        let (_, short) = realized_window(2.0, 1.9, 12.0, AUTO_MIN_SECONDS);
        assert!((short - 2.0).abs() < 1e-6, "short tail {short}");
    }

    #[test]
    fn a_clean_beatmatched_pair_blends_for_more_than_thirty_two_beats() {
        let out = matched(0.5, 240.0);
        let inc = matched(0.5, 240.0);
        let plan = phrase_switch(&out, &inc).expect("a clean pair should phrase-switch");
        let beats = plan.fade_seconds / 0.5;
        assert!(
            beats > 32.0,
            "fade {:.2}s is only {beats:.0} beats; a clean pair should run long",
            plan.fade_seconds
        );
    }

    #[test]
    fn a_vocal_clash_shrinks_the_long_blend() {
        let mut out = matched(0.5, 200.0);
        let mut inc = matched(0.5, 200.0);
        let curve: Vec<audio_analysis::EnergyPoint> = (0..400)
            .map(|i| audio_analysis::EnergyPoint {
                time: i as f64 * 0.5,
                energy: 1.0,
            })
            .collect();
        let mask = vec![1.0f64; curve.len()];
        out.energy_curve = curve.clone();
        inc.energy_curve = curve;
        out.vocal_activity_mask = mask.clone();
        inc.vocal_activity_mask = mask;
        out.vocal_probability = 0.9;
        inc.vocal_probability = 0.9;
        let plan = phrase_switch(&out, &inc).expect("a clash shrinks the blend, it does not refuse it");
        let beats = plan.fade_seconds / 0.5;
        assert!(
            beats <= 8.0,
            "a vocal clash left the blend at {beats:.0} beats"
        );
    }

    #[test]
    fn next_energy_dip_detects_local_valley_in_window() {
        let curve = vec![
            super::audio_analysis::EnergyPoint { time: 0.0, energy: 0.9 },
            super::audio_analysis::EnergyPoint { time: 0.5, energy: 0.8 },
            super::audio_analysis::EnergyPoint { time: 1.0, energy: 0.25 }, // dip
            super::audio_analysis::EnergyPoint { time: 1.5, energy: 0.75 },
            super::audio_analysis::EnergyPoint { time: 2.0, energy: 0.85 },
        ];
        // At position 0.0, window is [0.1, 2.0]. Local minimum at 1.0s.
        let dip = find_next_energy_dip(&curve, 0.0);
        assert_eq!(dip, Some(1.0));

        // When flat: no dip found
        let flat_curve = vec![
            super::audio_analysis::EnergyPoint { time: 0.0, energy: 0.9 },
            super::audio_analysis::EnergyPoint { time: 0.5, energy: 0.91 },
            super::audio_analysis::EnergyPoint { time: 1.0, energy: 0.92 },
            super::audio_analysis::EnergyPoint { time: 1.5, energy: 0.90 },
        ];
        assert_eq!(find_next_energy_dip(&flat_curve, 0.0), None);
    }
}
