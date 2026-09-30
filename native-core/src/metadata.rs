//! Metadata reads via lofty (spec §4) — used by LocalMusicView's scanner and
//! the Now Playing artwork fallback. Tag *writing* for downloads lands at
//! milestone 9 behind the same crate.

use std::borrow::Cow;

use lofty::config::WriteOptions;
use lofty::picture::{MimeType, Picture, PictureType};
use lofty::prelude::*;
use lofty::probe::Probe;
use lofty::tag::Tag;

use crate::TrackMetadata;

pub fn read_track_metadata(path: &str) -> Option<TrackMetadata> {
    let tagged = Probe::open(path).ok()?.read().ok()?;
    let properties = tagged.properties();
    let duration = properties.duration().as_secs_f64();

    let tag = tagged.primary_tag().or_else(|| tagged.first_tag());
    let text = |f: fn(&Tag) -> Option<Cow<'_, str>>| -> String {
        tag.and_then(f).map(|s| s.into_owned()).unwrap_or_default()
    };

    let artwork = tag
        .map(|t| {
            t.pictures()
                .first()
                .map(|picture| picture.data().to_vec())
                .unwrap_or_default()
        })
        .unwrap_or_default();

    Some(TrackMetadata {
        title: text(Tag::title),
        artist: text(Tag::artist),
        album: text(Tag::album),
        duration_seconds: duration,
        artwork,
    })
}

/// Write ID3/Vorbis/MP4 tags onto a downloaded file (spec §4).
pub fn write_track_tags(
    path: &str,
    title: &str,
    artist: &str,
    album: &str,
    artwork: &[u8],
) -> bool {
    let mut tagged = match Probe::open(path).and_then(|p| p.read()) {
        Ok(t) => t,
        Err(e) => {
            log::warn!("tag write: open {path}: {e}");
            return false;
        }
    };
    let tag = if let Some(existing) = tagged.primary_tag_mut() {
        existing
    } else {
        let tag_type = tagged.primary_tag_type();
        tagged.insert_tag(Tag::new(tag_type));
        match tagged.primary_tag_mut() {
            Some(t) => t,
            None => return false,
        }
    };
    tag.set_title(title.to_string());
    tag.set_artist(artist.to_string());
    if !album.is_empty() {
        tag.set_album(album.to_string());
    }
    if !artwork.is_empty() {
        let mime = if artwork.len() >= 3 && artwork[0] == 0xFF && artwork[1] == 0xD8 {
            MimeType::Jpeg
        } else {
            MimeType::Png
        };
        let picture = Picture::unchecked(artwork.to_vec())
            .pic_type(PictureType::CoverFront)
            .mime_type(mime)
            .build();
        tag.remove_picture_type(PictureType::CoverFront);
        tag.push_picture(picture);
    }
    match tagged.save_to_path(path, WriteOptions::default()) {
        Ok(()) => true,
        Err(e) => {
            log::warn!("tag write: save {path}: {e}");
            false
        }
    }
}

/// Quick directory scan: returns paths of files with audio-ish extensions.
/// Deep format probing happens on load; this keeps folder scans instant.
pub fn looks_like_audio(path: &std::path::Path) -> bool {
    matches!(
        path.extension()
            .and_then(|e| e.to_str())
            .map(|e| e.to_ascii_lowercase())
            .as_deref(),
        Some(
            "mp3"
                | "flac"
                | "m4a"
                | "mp4"
                | "aac"
                | "ogg"
                | "opus"
                | "wav"
                | "aiff"
                | "aif"
                | "wma"
                | "webm"
        )
    )
}

/// ReplayGain is a gain referenced to the ReplayGain calibration, not a LUFS
/// measurement. YouTube's relative loudness never enters this tag path.
#[derive(Default, Debug, Clone)]
pub struct ReplayGain {
    pub track_db: Option<f64>,
    pub album_db: Option<f64>,
    pub track_peak: Option<f64>,
    pub album_peak: Option<f64>,
}
pub fn read_replay_gain(path: &str) -> ReplayGain {
    let Some(tagged) = Probe::open(path).ok().and_then(|p| p.read().ok()) else {
        return ReplayGain::default();
    };
    let Some(tag) = tagged.primary_tag().or_else(|| tagged.first_tag()) else {
        return ReplayGain::default();
    };
    let value = |key| {
        tag.get_string(key)
            .and_then(|v| v.trim().trim_end_matches("dB").trim().parse::<f64>().ok())
            .filter(|v| v.is_finite())
    };
    ReplayGain {
        track_db: value(lofty::tag::ItemKey::ReplayGainTrackGain),
        album_db: value(lofty::tag::ItemKey::ReplayGainAlbumGain),
        track_peak: value(lofty::tag::ItemKey::ReplayGainTrackPeak),
        album_peak: value(lofty::tag::ItemKey::ReplayGainAlbumPeak),
    }
}
impl ReplayGain {
    pub fn gain_db(&self, mode: crate::LoudnessMode) -> Option<f64> {
        let (db, peak) = match mode {
            crate::LoudnessMode::Off => return None,
            crate::LoudnessMode::Track => (self.track_db, self.track_peak),
            crate::LoudnessMode::Album => (
                self.album_db.or(self.track_db),
                self.album_peak.or(self.track_peak),
            ),
        };
        let mut db = db?.clamp(-15.0, 15.0);
        if let Some(peak) = peak.filter(|p| *p > 0.0) {
            db = db.min(-0.5 - 20.0 * peak.log10());
        }
        Some(db)
    }
}

#[cfg(test)]
mod loudness_tests {
    use super::*;
    use crate::{LoudnessMeasurement, LoudnessMode};
    #[test]
    fn album_gain_falls_back_to_track_and_respects_peak() {
        let tags = ReplayGain {
            track_db: Some(6.0),
            track_peak: Some(0.5),
            ..Default::default()
        };
        assert_eq!(tags.gain_db(LoudnessMode::Off), None);
        let track = tags.gain_db(LoudnessMode::Track).unwrap();
        assert!((track - 5.520599913).abs() < 1e-6);
        assert_eq!(tags.gain_db(LoudnessMode::Album), Some(track));
        let album = ReplayGain {
            album_db: Some(-3.0),
            album_peak: Some(1.0),
            ..tags
        };
        assert_eq!(album.gain_db(LoudnessMode::Album), Some(-3.0));
    }
    #[test]
    fn measured_lufs_and_relative_loudness_have_distinct_gain_semantics() {
        let measurement = LoudnessMeasurement {
            track_lufs: -20.0,
            album_lufs: Some(-16.0),
            true_peak_dbtp: Some(-8.0),
        };
        assert_eq!(measurement.gain_db(LoudnessMode::Track), Some(6.0));
        assert_eq!(measurement.gain_db(LoudnessMode::Album), Some(2.0));
        assert_eq!(measurement.gain_db(LoudnessMode::Off), None);
        assert_eq!(
            crate::mixer::loudness_gain(Some(-20.0), true),
            (1.0, Some(0.0))
        );
    }
}
