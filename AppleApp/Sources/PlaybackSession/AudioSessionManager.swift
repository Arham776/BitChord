import AVFoundation

/// Background audio session (spec §3.2). iOS needs `.playback` + activation
/// for lock-screen / Control Center continuity; macOS has no AVAudioSession.
enum AudioSessionManager {
    static func activate() {
#if os(iOS)
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, mode: .default, options: [])
        try? session.setActive(true)
#endif
    }
}
