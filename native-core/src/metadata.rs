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
        Some("mp3" | "flac" | "m4a" | "mp4" | "aac" | "ogg" | "opus" | "wav" | "aiff" | "aif" | "wma" | "webm")
    )
}
