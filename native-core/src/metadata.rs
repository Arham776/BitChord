//! Metadata reads via lofty (spec §4) — used by LocalMusicView's scanner and
//! the Now Playing artwork fallback. Tag *writing* for downloads lands at
//! milestone 9 behind the same crate.

use std::borrow::Cow;

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

/// Quick directory scan: returns paths of files with audio-ish extensions.
/// Deep format probing happens on load; this keeps folder scans instant.
pub fn looks_like_audio(path: &std::path::Path) -> bool {
    matches!(
        path.extension()
            .and_then(|e| e.to_str())
            .map(|e| e.to_ascii_lowercase())
            .as_deref(),
        Some("mp3" | "flac" | "m4a" | "mp4" | "aac" | "ogg" | "opus" | "wav" | "aiff" | "aif" | "wma" | "webm")
    )
}
