import SwiftUI
import BitChordShared

/// A track's cover when it lives inside the file rather than beside it.
///
/// Upstream's `rememberRemoteArtworkUrl`, and the same lazy shape: a listing never
/// touches audio bytes, so a track whose art is in the tag arrives with no thumbnail
/// and the picture is pulled out of the file only for a row somebody actually looks
/// at. Every surface that draws a row — the library page, the queue, the mini player,
/// the player — gets it, which is upstream's list of callers too.
///
/// ## Why there is no cache in here
///
/// Upstream writes each extracted picture to a file and hands Coil the path, because a
/// Coil fetcher draws nothing that is not behind a URI. The bytes come back here and
/// the platform decodes them, so a cache would be a second thing to keep in step with
/// [ArtworkCache] — and the one that is already there knows how to budget itself. What
/// does the caching is `RemoteArtworkStore` in the shared module, which holds the
/// extracted pictures for the session, coalesces concurrent asks for one track into a
/// single ranged read, and forgets them when the share's address changes.
///
/// The difference from upstream is that an extracted cover does not survive a
/// relaunch, so a cold launch of an untagged share pays a few kilobytes per visible
/// row. That is the price of not inventing a file format for a picture that a library
/// will draw once or twice per session.
enum EmbeddedArtwork {

    /// The remote-library id of a row, when the picture may be inside its file.
    ///
    /// Nil — and no extraction, no task, no crossing into the shared module — unless
    /// the row has nothing else to draw *and* its id is one of ours. The order matters:
    /// the nil checks are free, and they keep the shared call off every YouTube row
    /// on the screen.
    static func trackId(of entry: QueueEntry) -> String? {
        guard entry.thumbnailUrl == nil, entry.artworkData == nil else { return nil }
        return WebDavBridge.shared.isRemoteId(videoId: entry.id) ? entry.id : nil
    }

    /// The bytes of the cover inside the file [id] names, or nil.
    ///
    /// Nil for anything that is not a remote-library track, and nil for one whose file
    /// has no picture in it — both are ordinary, neither is an error, and a row with
    /// no cover is a row.
    @discardableResult
    static func embeddedCoverData(id: String) async -> Data? {
        guard WebDavBridge.shared.isRemoteId(videoId: id),
              let fileUrl = WebDavBridge.shared.fileUrlOf(videoId: id)
        else { return nil }
        return await withCheckedContinuation { continuation in
            WebDavBridge.shared.embeddedCover(fileUrl: fileUrl) { image, error in
                // A failure is a missing cover, not a message: the caller wants to draw
                // something, and the alternative is a row that refuses to appear
                // because a range read did not answer.
                guard error == nil, let image else {
                    continuation.resume(returning: nil)
                    return
                }
                continuation.resume(returning: image.bytes as Data)
            }
        }
    }
}
