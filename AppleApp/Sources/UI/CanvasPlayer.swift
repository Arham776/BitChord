import SwiftUI
import AVFoundation
import CoreImage
#if os(iOS)
import UIKit
#else
import AppKit
#endif

/// One silent, looping decoder per visible cover. Playback follows visibility
/// and the song's transport state, matching upstream CanvasArtworkPlayer.
struct CanvasPlayer: View {
    let url: URL
    var fallbackURL: URL? = nil
    var isPlaying: Bool = true // Kept for existing sleeve/album call sites.
    var fitPortrait = false
    var sampleFrames = false
    var onAspect: (CGFloat) -> Void = { _ in }
    var onRendered: (Bool) -> Void = { _ in }
    var onFrame: (Data) -> Void = { _ in }
    @Environment(\.scenePhase) private var scenePhase
    @State private var visible = false

    var body: some View {
        CanvasPlayerLayer(configuration: CanvasConfiguration(
            url: url, fallback: fallbackURL,
            active: visible && scenePhase == .active && isPlaying,
            fitPortrait: fitPortrait, sampleFrames: sampleFrames,
            onAspect: onAspect, onRendered: onRendered, onFrame: onFrame
        ))
        .allowsHitTesting(false)
        .onAppear { visible = true }
        .onDisappear { visible = false }
    }
}

private struct CanvasConfiguration {
    let url: URL
    let fallback: URL?
    let active: Bool
    let fitPortrait: Bool
    let sampleFrames: Bool
    let onAspect: (CGFloat) -> Void
    let onRendered: (Bool) -> Void
    let onFrame: (Data) -> Void
}

#if os(macOS)
private struct CanvasPlayerLayer: NSViewRepresentable {
    var configuration: CanvasConfiguration
    func makeNSView(context: Context) -> CanvasVideoView {
        let view = CanvasVideoView(frame: .zero)
        view.configure(configuration)
        return view
    }
    func updateNSView(_ view: CanvasVideoView, context: Context) { view.configure(configuration) }
    static func dismantleNSView(_ view: CanvasVideoView, coordinator: ()) { view.teardown() }
}
typealias PlatformCanvasView = NSView
#else
private struct CanvasPlayerLayer: UIViewRepresentable {
    var configuration: CanvasConfiguration
    func makeUIView(context: Context) -> CanvasVideoView {
        let view = CanvasVideoView(frame: .zero)
        view.configure(configuration)
        return view
    }
    func updateUIView(_ view: CanvasVideoView, context: Context) { view.configure(configuration) }
    static func dismantleUIView(_ view: CanvasVideoView, coordinator: ()) { view.teardown() }
}
typealias PlatformCanvasView = UIView
#endif

final class CanvasVideoView: PlatformCanvasView {
    private let player = AVPlayer()
    private let playerLayer = AVPlayerLayer()
    private var configuration: CanvasConfiguration?
    private var currentURL: URL?
    private var cachedRemoteRetryURL: URL?
    private var generation = 0
    private var triedFallback = false
    private var triedCachedRemoteRetry = false
    private var readyObserver: NSKeyValueObservation?
    private var statusObserver: NSKeyValueObservation?
    private var sizeObserver: NSKeyValueObservation?
    private var endObserver: NSObjectProtocol?
    private var failedObserver: NSObjectProtocol?
    private var frameTimer: Timer?
    private var videoOutput: AVPlayerItemVideoOutput?
    private var clipAspect: CGFloat = 0
    private var ready = false
    private var sampling = false
    private var lastSampleTime = -Double.infinity

    override init(frame: CGRect) {
        super.init(frame: frame)
        installLayer()
        player.isMuted = true
        player.volume = 0
        player.preventsDisplaySleepDuringVideoPlayback = false
        player.audiovisualBackgroundPlaybackPolicy = .pauses
        playerLayer.player = player
        playerLayer.opacity = 0
    }
    required init?(coder: NSCoder) { fatalError("init(coder:)") }

    fileprivate func configure(_ value: CanvasConfiguration) {
        let wasActive = configuration?.active ?? false
        configuration = value
        if currentURL != value.url {
            currentURL = value.url
            generation += 1
            let requestGeneration = generation
            triedFallback = false
            triedCachedRemoteRetry = false
            cachedRemoteRetryURL = nil
            clearItem()
            value.onRendered(false)
            value.onAspect(0)
            Task { [weak self] in
                let local = value.url.isFileURL ? value.url : await CanvasFileCache.shared.cachedFile(for: value.url)
                guard let self, self.generation == requestGeneration else { return }
                self.mount(local, cachedRemoteRetryURL: local == value.url ? nil : value.url)
            }
        }
        layoutVideo()
        if value.active {
            if !wasActive { lastSampleTime = -.infinity }
            player.play()
            startFrameTimer()
        } else {
            player.pause()
            frameTimer?.invalidate()
            frameTimer = nil
        }
    }

    func teardown() {
        generation += 1
        frameTimer?.invalidate()
        frameTimer = nil
        clearItem()
        currentURL = nil
        cachedRemoteRetryURL = nil
        configuration = nil
    }

    private func clearItem() {
        readyObserver = nil
        statusObserver = nil
        sizeObserver = nil
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        if let failedObserver { NotificationCenter.default.removeObserver(failedObserver) }
        endObserver = nil
        failedObserver = nil
        player.pause()
        player.replaceCurrentItem(with: nil)
        videoOutput = nil
        playerLayer.opacity = 0
        clipAspect = 0
        ready = false
        lastSampleTime = -.infinity
    }

    private func mount(_ url: URL, cachedRemoteRetryURL: URL? = nil) {
        self.cachedRemoteRetryURL = cachedRemoteRetryURL
        clearItem()
        let item = AVPlayerItem(url: url)
        let output = AVPlayerItemVideoOutput(pixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
        ])
        item.add(output)
        videoOutput = output
        // Install observers before assigning the item: cached clips may become
        // ready immediately. Each callback checks item identity after hopping.
        sizeObserver = item.observe(\.presentationSize, options: [.initial, .new]) { [weak self] item, _ in
            let size = item.presentationSize
            Task { @MainActor [weak self] in
                guard let self, self.player.currentItem === item, size.height > 0 else { return }
                self.clipAspect = size.width / size.height
                self.configuration?.onAspect(self.clipAspect)
                self.layoutVideo()
            }
        }
        statusObserver = item.observe(\.status, options: [.new]) { [weak self] item, _ in
            guard item.status == .failed else { return }
            Task { @MainActor [weak self] in
                guard self?.player.currentItem === item else { return }
                self?.useFallback()
            }
        }
        readyObserver = playerLayer.observe(\.isReadyForDisplay, options: [.new]) { [weak self] layer, _ in
            guard layer.isReadyForDisplay else { return }
            Task { @MainActor [weak self] in
                guard let self, self.player.currentItem === item else { return }
                self.layoutVideo()
                self.revealIfReady()
            }
        }
        endObserver = NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.player.currentItem === item else { return }
                self.player.seek(to: .zero, toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] _ in
                    Task { @MainActor [weak self] in
                        guard let self, self.player.currentItem === item else { return }
                        if self.configuration?.active == true { self.player.play() }
                    }
                }
            }
        }
        failedObserver = NotificationCenter.default.addObserver(forName: .AVPlayerItemFailedToPlayToEndTime, object: item, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard self?.player.currentItem === item else { return }
                self?.useFallback()
            }
        }
        player.replaceCurrentItem(with: item)
        if configuration?.active == true { player.play(); startFrameTimer() }
    }

    private func useFallback() {
        let error = player.currentItem?.error?.localizedDescription ?? "unknown playback error"
        NSLog("[BitChord] animated artwork video failed at %@: %@",
              currentURL?.host ?? "local cache", error)
        configuration?.onRendered(false)
        playerLayer.opacity = 0
        if !triedCachedRemoteRetry, let remote = cachedRemoteRetryURL {
            triedCachedRemoteRetry = true
            NSLog("[BitChord] retrying animated artwork directly from %@ after cached playback failed",
                  remote.host ?? "remote host")
            mount(remote)
            return
        }
        guard !triedFallback, let fallback = configuration?.fallback else {
            player.pause()
            return
        }
        triedFallback = true
        mount(fallback)
    }

    private func revealIfReady() {
        guard playerLayer.isReadyForDisplay, clipAspect > 0, bounds.width > 0, bounds.height > 0 else { return }
        guard !ready else { return }
        ready = true
        configuration?.onRendered(true)
        CATransaction.begin()
        CATransaction.setAnimationDuration(0.32)
        playerLayer.opacity = 1
        CATransaction.commit()
    }

    private func startFrameTimer() {
        guard frameTimer == nil else { return }
        frameTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.sampleFrameIfNeeded() }
        }
    }

    private func sampleFrameIfNeeded() {
        revealIfReady()
        guard ready, configuration?.active == true, configuration?.sampleFrames == true,
              !sampling, CACurrentMediaTime() - lastSampleTime >= 3,
              let output = videoOutput else { return }
        let time = output.itemTime(forHostTime: CACurrentMediaTime())
        guard output.hasNewPixelBuffer(forItemTime: time),
              let buffer = output.copyPixelBuffer(forItemTime: time, itemTimeForDisplay: nil) else { return }
        sampling = true
        lastSampleTime = CACurrentMediaTime()
        let requestedGeneration = generation
        Task { [weak self] in
            let data = await Task.detached(priority: .utility) { CanvasFrameRenderer.render(buffer) }.value
            guard let self else { return }
            self.sampling = false
            guard self.generation == requestedGeneration, let data else { return }
            self.configuration?.onFrame(data)
        }
    }

    private func layoutVideo() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if configuration?.fitPortrait == true, clipAspect > 0, clipAspect < 1 {
            let size = PlayerLayout.containedCanvasSize(bounds: bounds.size, aspect: clipAspect)
            playerLayer.videoGravity = .resizeAspect
            playerLayer.frame = CGRect(x: (bounds.width - size.width) / 2, y: 0, width: size.width, height: size.height)
        } else {
            playerLayer.videoGravity = .resizeAspectFill
            playerLayer.frame = bounds
        }
        CATransaction.commit()
    }

    #if os(macOS)
    private func installLayer() {
        wantsLayer = true
        layer?.masksToBounds = true
        layer?.addSublayer(playerLayer)
    }
    override func layout() { super.layout(); layoutVideo(); revealIfReady() }
    #else
    private func installLayer() {
        clipsToBounds = true
        backgroundColor = .clear
        layer.addSublayer(playerLayer)
    }
    override func layoutSubviews() { super.layoutSubviews(); layoutVideo(); revealIfReady() }
    #endif
}

private enum CanvasFrameRenderer {
    static let context = CIContext(options: [.cacheIntermediates: false])
    static func render(_ buffer: CVPixelBuffer) -> Data? {
        let image = CIImage(cvPixelBuffer: buffer)
        let scale = min(1, 120 / max(image.extent.width, image.extent.height))
        let small = image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        return context.jpegRepresentation(of: small, colorSpace: colorSpace, options: [:])
    }
}
