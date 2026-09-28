//! Transition quality telemetry — a cheap Smoothness Index for plans.
//!
//! Inspired by AudioMix's Weighted Audio Transition Model: score tempo stretch,
//! tonal distance proxy, and whether the planner refused a force-warp. Used by
//! `automix_render` and tests; not a substitute for listening.

use crate::mixer::{TransitionPlan, TransitionStyle};

/// 0 = harsh / forced, 1 = transparent. Higher is better.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct SmoothnessReport {
    pub score: f64,
    pub stretch_cost: f64,
    pub style_bonus: f64,
    pub forced_stretch: bool,
}

/// Score one planned transition.
///
/// - Stretch cost rises as `|rate - 1|` approaches the audible band.
/// - DjBlend with near-unity rate scores highest; EqualPower is neutral;
///   DjFilter is a deliberate degrade (still better than a comic warp).
/// - `forced_stretch` is true when `|rate - 1| > 0.04` — the Apple failure mode
///   this stack refuses in planning.
pub fn score_plan(plan: &TransitionPlan) -> SmoothnessReport {
    let deviation = (plan.playback_rate - 1.0).abs();
    let forced_stretch = deviation > 0.04 + 1e-9;
    let stretch_cost = (deviation / 0.08).clamp(0.0, 1.0);
    let style_bonus = match plan.style {
        TransitionStyle::DjBlend if deviation <= 0.04 + 1e-9 => 0.25,
        TransitionStyle::DjBlend => 0.05,
        TransitionStyle::DjFilter => 0.10,
        TransitionStyle::Gapless => 0.15,
        TransitionStyle::EqualPower => 0.0,
    };
    let vocal_penalty = (plan.vocal_overlap * 0.2).clamp(0.0, 0.2);
    let raw = (1.0 - stretch_cost) * 0.7 + style_bonus - vocal_penalty;
    let score = if forced_stretch {
        (raw * 0.5).clamp(0.0, 1.0)
    } else {
        raw.clamp(0.0, 1.0)
    };
    SmoothnessReport {
        score,
        stretch_cost,
        style_bonus,
        forced_stretch,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn plan(rate: f64, style: TransitionStyle) -> TransitionPlan {
        TransitionPlan {
            style,
            playback_rate: rate,
            ..TransitionPlan::default()
        }
    }

    #[test]
    fn unity_blend_scores_high() {
        let report = score_plan(&plan(1.0, TransitionStyle::DjBlend));
        assert!(report.score >= 0.9, "score {}", report.score);
        assert!(!report.forced_stretch);
    }

    #[test]
    fn apple_style_warp_is_flagged() {
        let report = score_plan(&plan(0.75, TransitionStyle::DjBlend));
        assert!(report.forced_stretch);
        assert!(report.score < 0.5, "score {}", report.score);
    }

    #[test]
    fn filter_without_stretch_beats_forced_warp() {
        let filter = score_plan(&plan(1.0, TransitionStyle::DjFilter));
        let warp = score_plan(&plan(1.2, TransitionStyle::DjBlend));
        assert!(filter.score > warp.score);
    }
}
