//! Source-time playback policy. Detection reads dry stereo PCM; no file writes
//! or analysis run on the output callback. Unfinished files have no tail bound.
use crate::decode::{SourceKind, SymphoniaDecoder};
use std::collections::HashMap;
use std::sync::{Mutex, OnceLock};

#[derive(uniffi::Record, Clone, Debug, Default)]
pub struct PlaybackInterval {
    pub start_seconds: f64,
    pub end_seconds: f64,
}
#[derive(uniffi::Record, Clone, Debug, Default)]
pub struct PlaybackRegions {
    pub audible_start_seconds: f64,
    pub audible_end_seconds: Option<f64>,
    pub excluded: Vec<PlaybackInterval>,
}
impl PlaybackRegions {
    pub fn normalized(mut self, duration: f64) -> Self {
        if !self.audible_start_seconds.is_finite() {
            self.audible_start_seconds = 0.0;
        }
        self.audible_start_seconds = self.audible_start_seconds.max(0.0);
        self.audible_end_seconds = self
            .audible_end_seconds
            .filter(|e| e.is_finite() && *e > self.audible_start_seconds);
        if duration > 0.0 {
            self.audible_start_seconds = self.audible_start_seconds.min(duration);
            self.audible_end_seconds = self.audible_end_seconds.map(|e| e.min(duration));
        }
        self.excluded.retain(|s| {
            s.start_seconds.is_finite()
                && s.end_seconds.is_finite()
                && s.start_seconds >= 0.0
                && s.end_seconds > s.start_seconds
        });
        for segment in &mut self.excluded {
            if duration > 0.0 {
                segment.end_seconds = segment.end_seconds.min(duration);
            }
        }
        self.excluded.retain(|s| s.end_seconds > s.start_seconds);
        self.excluded
            .sort_by(|a, b| a.start_seconds.total_cmp(&b.start_seconds));
        let mut merged: Vec<PlaybackInterval> = Vec::new();
        for segment in self.excluded {
            if let Some(last) = merged
                .last_mut()
                .filter(|s| segment.start_seconds <= s.end_seconds)
            {
                last.end_seconds = last.end_seconds.max(segment.end_seconds);
            } else {
                merged.push(segment);
            }
        }
        self.excluded = merged;
        self
    }
    pub fn effective_end(&self, duration: f64) -> f64 {
        let mut end = self.audible_end_seconds.unwrap_or(duration);
        for s in self.excluded.iter().rev() {
            if end > 0.0 && s.end_seconds >= end - 0.05 && s.start_seconds < end {
                end = s.start_seconds;
            }
        }
        end
    }
    pub fn next_allowed(&self, mut position: f64) -> f64 {
        position = position.max(self.audible_start_seconds);
        for s in &self.excluded {
            if position >= s.start_seconds && position < s.end_seconds {
                position = s.end_seconds;
            }
        }
        position
    }
}
fn registry() -> &'static Mutex<HashMap<String, PlaybackRegions>> {
    static REGIONS: OnceLock<Mutex<HashMap<String, PlaybackRegions>>> = OnceLock::new();
    REGIONS.get_or_init(|| Mutex::new(HashMap::new()))
}
pub fn get(source: &str) -> PlaybackRegions {
    registry()
        .lock()
        .unwrap()
        .get(source)
        .cloned()
        .unwrap_or_default()
}
pub fn put(source: String, regions: PlaybackRegions) {
    let mut entries = registry().lock().unwrap();
    if entries.len() > 256 {
        entries.clear();
    }
    entries.insert(source, regions);
}

/// Ten-millisecond stereo windows, both RMS and peak must be below the gates.
/// Never sum L+R: out-of-phase music must not disappear into a mono detector.
pub fn boundaries(quiet: &[bool], window: f64, duration: f64, complete: bool) -> PlaybackRegions {
    let first = quiet.iter().position(|q| !q);
    let Some(first) = first else {
        return PlaybackRegions::default();
    }; // all-silent: preserve timeline
    let last = quiet.iter().rposition(|q| !q).unwrap();
    let head = first as f64 * window;
    let tail = duration - (last + 1) as f64 * window;
    PlaybackRegions {
        audible_start_seconds: if head >= 0.35 {
            (head - 0.1).max(0.0)
        } else {
            0.0
        },
        audible_end_seconds: if complete && tail >= 0.35 {
            Some(((last + 1) as f64 * window + 0.1).min(duration))
        } else {
            None
        },
        excluded: vec![],
    }
}
pub fn detect(source: &str, complete: bool) -> Result<PlaybackRegions, String> {
    if source.starts_with("http") {
        return Err("boundary analysis requires local bytes".into());
    }
    let complete = complete
        && (!std::path::Path::new(&format!("{source}.grow")).exists()
            || std::path::Path::new(&format!("{source}.complete")).exists());
    let _lease = SourceLease::new(source);
    let mut decoder = SymphoniaDecoder::open_available(&SourceKind::parse(source), &HashMap::new())
        .map_err(|e| e.to_string())?;
    let rate = decoder.sample_rate().max(1) as usize;
    let size = (rate / 100).max(1);
    let mut quiet = Vec::new();
    let mut samples = 0usize;
    let mut squares = [0f64; 2];
    let mut peak = 0f32;
    let mut frames = 0usize;
    loop {
        let data = decoder.read_stereo(4096).map_err(|e| e.to_string())?;
        if data.is_empty() {
            break;
        }
        for frame in data.chunks_exact(2) {
            for (channel, &s) in frame.iter().enumerate() {
                squares[channel] += (s as f64).powi(2);
                peak = peak.max(s.abs());
            }
            samples += 2;
            frames += 1;
            if samples == size * 2 {
                quiet.push(
                    squares
                        .iter()
                        .all(|sum| (sum / (samples / 2) as f64).sqrt() < 0.001)
                        && peak < 0.003162278,
                );
                samples = 0;
                squares = [0.0; 2];
                peak = 0.0;
            }
        }
        if !complete && frames >= rate * 30 {
            break;
        }
    }
    if samples > 0 {
        quiet.push(
            squares
                .iter()
                .all(|sum| (sum / (samples / 2) as f64).sqrt() < 0.001)
                && peak < 0.003162278,
        );
    }
    Ok(boundaries(
        &quiet,
        size as f64 / rate as f64,
        frames as f64 / rate as f64,
        complete,
    ))
}

/// Clamp the entire outgoing/incoming blend windows, not only their anchors.
pub fn constrain(
    mut plan: crate::TransitionPlanRec,
    out: PlaybackRegions,
    incoming: PlaybackRegions,
    out_duration: f64,
    in_duration: f64,
) -> crate::TransitionPlanRec {
    if out.audible_start_seconds == 0.0
        && out.audible_end_seconds.is_none()
        && out.excluded.is_empty()
        && incoming.audible_start_seconds == 0.0
        && incoming.audible_end_seconds.is_none()
        && incoming.excluded.is_empty()
    {
        return plan;
    }
    let out = out.normalized(out_duration);
    let incoming = incoming.normalized(in_duration);
    let end = out.effective_end(out_duration);
    let mut anchor = if plan.transition_end_seconds > 0.0 {
        if end > 0.0 {
            plan.transition_end_seconds.min(end)
        } else {
            plan.transition_end_seconds
        }
    } else {
        end
    };
    let mut fade = if plan.fade_seconds > 0.0 {
        plan.fade_seconds
    } else {
        1.0
    };
    let cue = incoming.next_allowed(plan.cue_seconds);
    for segment in out.excluded.iter().rev() {
        if segment.start_seconds < anchor && segment.end_seconds > anchor - fade {
            if anchor - segment.end_seconds >= 0.05 {
                fade = fade.min(anchor - segment.end_seconds);
            } else {
                anchor = segment.start_seconds;
            }
        }
    }
    fade = fade.min((anchor - out.audible_start_seconds).max(0.0));
    let incoming_end = incoming
        .excluded
        .iter()
        .find(|s| s.start_seconds >= cue)
        .map(|s| s.start_seconds)
        .unwrap_or_else(|| incoming.effective_end(in_duration));
    if incoming_end > 0.0 || in_duration > 0.0 {
        fade = fade.min((incoming_end - cue).max(0.0) / plan.playback_rate.max(0.5));
    }
    let gapless = fade < 0.05;
    if gapless {
        fade = 0.001;
    }
    if (fade - plan.fade_seconds).abs() > 0.05 || (cue - plan.cue_seconds).abs() > 0.05 {
        plan.style = crate::TransitionStyleRec::EqualPower;
        plan.bass_swap = false;
        plan.filter_sweep = 0.0;
        plan.bed_fraction = 0.0;
        plan.playback_rate = 1.0;
    }
    if gapless {
        plan.style = crate::TransitionStyleRec::Gapless;
    }
    plan.cue_seconds = cue;
    plan.transition_end_seconds = anchor;
    plan.fade_seconds = fade;
    plan
}
#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn edges_preserve_guards_and_partial_tail() {
        let mut q = vec![true; 100];
        q.extend(vec![false; 200]);
        q.extend(vec![true; 100]);
        let r = boundaries(&q, 0.01, 4.0, true);
        assert!((r.audible_start_seconds - 0.9).abs() < 0.001);
        assert_eq!(r.audible_end_seconds, Some(3.1));
        assert_eq!(boundaries(&q, 0.01, 4.0, false).audible_end_seconds, None);
        assert_eq!(
            boundaries(&[true; 100], 0.01, 1.0, true).audible_start_seconds,
            0.0
        );
    }
    #[test]
    fn intervals_merge_and_terminal_region_sets_end() {
        let r = PlaybackRegions {
            excluded: vec![
                PlaybackInterval {
                    start_seconds: 8.0,
                    end_seconds: 12.0,
                },
                PlaybackInterval {
                    start_seconds: 9.0,
                    end_seconds: 10.0,
                },
            ],
            ..Default::default()
        }
        .normalized(12.0);
        assert_eq!(r.excluded.len(), 1);
        assert_eq!(r.effective_end(12.0), 8.0);
        assert_eq!(r.next_allowed(9.0), 12.0);
    }
    fn fixture(
        name: &str,
        head: f32,
        music: f32,
        tail: f32,
        amplitude: f32,
        stereo: bool,
    ) -> std::path::PathBuf {
        let path = std::env::temp_dir().join(format!(
            "bitchord-regions-{}-{name}.wav",
            std::process::id()
        ));
        let rate = 10000u32;
        let frames = ((head + music + tail) * rate as f32) as usize;
        let length = frames as u32 * 8;
        let mut bytes = Vec::new();
        bytes.extend(b"RIFF");
        bytes.extend((36 + length).to_le_bytes());
        bytes.extend(b"WAVEfmt ");
        bytes.extend(16u32.to_le_bytes());
        bytes.extend(3u16.to_le_bytes());
        bytes.extend(2u16.to_le_bytes());
        bytes.extend(rate.to_le_bytes());
        bytes.extend((rate * 8).to_le_bytes());
        bytes.extend(8u16.to_le_bytes());
        bytes.extend(32u16.to_le_bytes());
        bytes.extend(b"data");
        bytes.extend(length.to_le_bytes());
        for i in 0..frames {
            let t = i as f32 / rate as f32;
            let value = if t >= head && t < head + music {
                amplitude * (t * 200.0 * std::f32::consts::PI).sin()
            } else {
                0.00003
            };
            bytes.extend(value.to_le_bytes());
            bytes.extend(if stereo {
                (-value).to_le_bytes()
            } else {
                0.0f32.to_le_bytes()
            });
        }
        std::fs::write(&path, bytes).unwrap();
        path
    }
    #[test]
    fn dry_stereo_detection_preserves_quiet_music_and_residual_noise() {
        for (name, stereo, level) in [("stereo", true, 0.01), ("quiet", false, 0.002)] {
            let path = fixture(name, 1.0, 2.0, 1.0, level, stereo);
            let r = detect(path.to_str().unwrap(), true).unwrap();
            assert!((r.audible_start_seconds - 0.9).abs() < 0.02, "{r:?}");
            assert!((r.audible_end_seconds.unwrap() - 3.1).abs() < 0.02, "{r:?}");
            std::fs::remove_file(path).unwrap();
        }
    }
    #[test]
    fn unfinished_recording_does_not_trim_tail_or_block() {
        let path = fixture("partial", 1.0, 2.0, 1.0, 0.1, true);
        std::fs::write(format!("{}.grow", path.display()), "").unwrap();
        let r = detect(path.to_str().unwrap(), true).unwrap();
        assert_eq!(r.audible_end_seconds, None);
        assert!((r.audible_start_seconds - 0.9).abs() < 0.02);
        std::fs::remove_file(format!("{}.grow", path.display())).unwrap();
        std::fs::remove_file(path).unwrap();
    }
    #[test]
    fn safe_windows_shorten_overlap_and_clear_incoming_exclusion() {
        let plan: crate::TransitionPlanRec = crate::mixer::TransitionPlan {
            fade_seconds: 10.0,
            transition_end_seconds: 110.0,
            cue_seconds: 1.0,
            ..Default::default()
        }
        .into();
        let out = PlaybackRegions {
            excluded: vec![PlaybackInterval {
                start_seconds: 100.0,
                end_seconds: 107.0,
            }],
            ..Default::default()
        };
        let incoming = PlaybackRegions {
            excluded: vec![
                PlaybackInterval {
                    start_seconds: 0.0,
                    end_seconds: 6.0,
                },
                PlaybackInterval {
                    start_seconds: 8.0,
                    end_seconds: 10.0,
                },
            ],
            ..Default::default()
        };
        let safe = constrain(plan, out, incoming, 120.0, 60.0);
        assert_eq!(safe.cue_seconds, 6.0);
        assert_eq!(safe.transition_end_seconds, 110.0);
        assert_eq!(safe.fade_seconds, 2.0);
    }
    #[test]
    fn insufficient_window_is_gapless_and_invalid_intervals_are_removed() {
        let plan = crate::mixer::TransitionPlan {
            fade_seconds: 4.0,
            ..Default::default()
        }
        .into();
        let incoming = PlaybackRegions {
            excluded: vec![PlaybackInterval {
                start_seconds: 0.0,
                end_seconds: 60.0,
            }],
            ..Default::default()
        };
        let safe = constrain(plan, PlaybackRegions::default(), incoming, 120.0, 60.0);
        assert_eq!(safe.style, crate::TransitionStyleRec::Gapless);
        let r = PlaybackRegions {
            excluded: vec![
                PlaybackInterval {
                    start_seconds: f64::NAN,
                    end_seconds: 5.0,
                },
                PlaybackInterval {
                    start_seconds: 9.0,
                    end_seconds: 2.0,
                },
            ],
            ..Default::default()
        }
        .normalized(10.0);
        assert!(r.excluded.is_empty());
    }
}

fn readers() -> &'static Mutex<HashMap<String, usize>> {
    static READERS: OnceLock<Mutex<HashMap<String, usize>>> = OnceLock::new();
    READERS.get_or_init(|| Mutex::new(HashMap::new()))
}
pub struct SourceLease(String);
impl SourceLease {
    pub fn new(source: &str) -> Self {
        *readers().lock().unwrap().entry(source.into()).or_default() += 1;
        Self(source.into())
    }
}
impl Drop for SourceLease {
    fn drop(&mut self) {
        let mut map = readers().lock().unwrap();
        if let Some(count) = map.get_mut(&self.0) {
            *count -= 1;
            if *count == 0 {
                map.remove(&self.0);
            }
        }
    }
}
#[uniffi::export]
pub fn source_has_playback_readers(source: String) -> bool {
    readers().lock().unwrap().contains_key(&source)
}
