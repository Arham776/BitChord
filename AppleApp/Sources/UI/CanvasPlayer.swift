import SwiftUI
import AVFoundation
#if os(iOS)
import UIKit
#else
import AppKit
#endif

/// Looping motion artwork over the still cover (upstream `CanvasArtworkPlayer`).
///
/// Silent `AVPlayerLayer` cropped to fill. Fades in once a frame is ready so a
/// failed clip leaves the still sleeve showing. Loops by seeking to zero —
/// `AVPlayerLooper` is unreliable on the HLS Apple motion-art streams.
struct CanvasPlayer: View {
    let url: URL
    var fallbackURL: URL? = nil
    var isPlaying: Bool = true

    var body: some View {
        CanvasPlayerLayer(url: url, fallbackURL: fallbackURL, isPlaying: isPlaying)
            .allowsHitTesting(false)
    }
}

#if os(macOS)
private struct CanvasPlayerLayer: NSViewRepresentable {
    let url: URL
    var fallbackURL: URL?
    var isPlaying: Bool

    func makeNSView(context: Context) -> CanvasVideoView {
        let view = CanvasVideoView(frame: .zero)
        view.load(url, fallback: fallbackURL)
        view.setPlaying(isPlaying)
        return view
    }

    func updateNSView(_ view: CanvasVideoView, context: Context) {
        view.load(url, fallback: fallbackURL)
        view.setPlaying(isPlaying)
    }

    static func dismantleNSView(_ view: CanvasVideoView, coordinator: ()) {
        view.teardown()
    }
}
#else
private struct CanvasPlayerLayer: UIViewRepresentable {
    let url: URL
    var fallbackURL: URL?
    var isPlaying: Bool

    func makeUIView(context: Context) -> CanvasVideoView {
        let view = CanvasVideoView(frame: .zero)
        view.load(url, fallback: fallbackURL)
        view.setPlaying(isPlaying)
        return view
    }

    func updateUIView(_ view: CanvasVideoView, context: Context) {
        view.load(url, fallback: fallbackURL)
        view.setPlaying(isPlaying)
    }

    static func dismantleUIView(_ view: CanvasVideoView, coordinator: ()) {
        view.teardown()
    }
}
#endif

#if os(macOS)
typealias PlatformCanvasView = NSView
#else
typealias PlatformCanvasView = UIView
#endif

final class CanvasVideoView: PlatformCanvasView {
    private let player = AVPlayer()
    private let playerLayer = AVPlayerLayer()
    private var currentURL: URL?
    private var fallbackURL: URL?
    private var triedFallback = false
    private var wantPlaying = true
    private var readyObserver: NSKeyValueObservation?
    private var statusObserver: NSKeyValueObservation?
    private var endObserver: NSObjectProtocol?

    override init(frame: CGRect) {
        super.init(frame: frame)
        installLayer()
        player.isMuted = true
        player.preventsDisplaySleepDuringVideoPlayback = false
        playerLayer.player = player
        playerLayer.videoGravity = .resizeAspectFill
        playerLayer.opacity = 0
    }

    required init?(coder: NSCoder) { fatalError("init(coder:)") }

    deinit { teardown() }

    func load(_ url: URL, fallback: URL?) {
        if url == currentURL { return }
        currentURL = url
        fallbackURL = fallback
        triedFallback = false
        if url.isFileURL {
            mount(url)
            return
        }
        player.replaceCurrentItem(with: nil)
        playerLayer.opacity = 0
        let requested = url
        Task {
            let local = await CanvasFileCache.shared.cachedFile(for: requested)
            await MainActor.run { [weak self] in
                guard let self, self.currentURL == requested else { return }
                self.mount(local)
            }
        }
    }

    func setPlaying(_ playing: Bool) {
        wantPlaying = playing
        if playing { player.play() } else { player.pause() }
    }

    func teardown() {
        readyObserver = nil
        statusObserver = nil
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        endObserver = nil
        player.pause()
        player.replaceCurrentItem(with: nil)
        currentURL = nil
    }

    private func mount(_ url: URL) {
        playerLayer.opacity = 0
        readyObserver = nil
        statusObserver = nil
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        let item = AVPlayerItem(url: url)
        player.replaceCurrentItem(with: item)
        readyObserver = playerLayer.observe(\.isReadyForDisplay, options: [.new]) { [weak self] layer, _ in
            guard layer.isReadyForDisplay else { return }
            DispatchQueue.main.async { self?.fadeIn() }
        }
        statusObserver = item.observe(\.status, options: [.new]) { [weak self] item, _ in
            guard item.status == .failed else { return }
            DispatchQueue.main.async { self?.useFallback() }
        }
        endObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: item,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            self.player.seek(to: .zero)
            if self.wantPlaying { self.player.play() }
        }
        if wantPlaying { player.play() }
    }

    private func useFallback() {
        guard !triedFallback, let fallbackURL else { return }
        triedFallback = true
        currentURL = fallbackURL
        mount(fallbackURL)
    }

    private func fadeIn() {
        #if os(macOS)
        CATransaction.begin()
        CATransaction.setAnimationDuration(0.32)
        playerLayer.opacity = 1
        CATransaction.commit()
        #else
        UIView.animate(withDuration: 0.32) { self.playerLayer.opacity = 1 }
        #endif
    }

    #if os(macOS)
    private func installLayer() {
        wantsLayer = true
        layer?.masksToBounds = true
        layer?.addSublayer(playerLayer)
    }

    override func layout() {
        super.layout()
        playerLayer.frame = bounds
    }
    #else
    private func installLayer() {
        clipsToBounds = true
        backgroundColor = .clear
        layer.addSublayer(playerLayer)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        playerLayer.frame = bounds
    }
    #endif
}
