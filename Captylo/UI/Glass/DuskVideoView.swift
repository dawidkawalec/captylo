import AVFoundation
import AppKit
import SwiftUI

/// The living "Zmierzch" background: the seamless dusk loop (`Resources/Video/dusk-loop.mp4`,
/// rendered from our own photo by `scripts/make-dusk-video.sh`) in an `AVPlayerLayer`, muted,
/// aspect fill. One player per window (the window's single `DuskBackground` owns it). The layer
/// stays transparent until the first frame is ready, so the photo underneath is the poster and
/// the fallback when the file is missing or cannot play.
///
/// Plays only while `isPlaying` (the window is key in the active app and Reduce Motion is off)
/// and the window is on screen (not occluded, not minimized); otherwise it pauses on the
/// current frame. Decoding runs in the media engine, so a playing loop costs about 1 % CPU.
@MainActor
struct DuskVideoView: NSViewRepresentable {
    var isPlaying: Bool

    func makeNSView(context: Context) -> DuskVideoHostView {
        let view = DuskVideoHostView()
        view.wantsPlayback = isPlaying
        return view
    }

    func updateNSView(_ nsView: DuskVideoHostView, context: Context) {
        nsView.wantsPlayback = isPlaying
    }

    static func dismantleNSView(_ nsView: DuskVideoHostView, coordinator: ()) {
        nsView.tearDown()
    }
}

final class DuskVideoHostView: NSView {
    static let resourceName = "dusk-loop"
    static let resourceExtension = "mp4"
    /// Cross-fade from the photo poster to the first video frame.
    private static let revealDuration: CFTimeInterval = 0.6

    static var videoURL: URL? {
        Bundle.main.url(forResource: resourceName, withExtension: resourceExtension)
    }

    /// Set from SwiftUI: key window in the active app, Reduce Motion off.
    var wantsPlayback = false {
        didSet {
            if wantsPlayback != oldValue { updatePlayback() }
        }
    }

    private let playerLayer = AVPlayerLayer()
    private var player: AVQueuePlayer?
    private var looper: AVPlayerLooper?
    private var readyObservation: NSKeyValueObservation?
    private var isTornDown = false

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.masksToBounds = true
        playerLayer.videoGravity = .resizeAspectFill
        playerLayer.opacity = 0
        playerLayer.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
        layer?.addSublayer(playerLayer)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        playerLayer.frame = bounds
        CATransaction.commit()
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        super.viewWillMove(toWindow: newWindow)
        if let window {
            NotificationCenter.default.removeObserver(self, name: NSWindow.didChangeOcclusionStateNotification, object: window)
        }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let window {
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(occlusionDidChange),
                name: NSWindow.didChangeOcclusionStateNotification,
                object: window
            )
            makePlayerIfNeeded()
        }
        updatePlayback()
    }

    @objc private func occlusionDidChange(_ notification: Notification) {
        updatePlayback()
    }

    /// Stops for good (the style changed or the window closed).
    func tearDown() {
        isTornDown = true
        readyObservation?.invalidate()
        readyObservation = nil
        player?.pause()
        looper?.disableLooping()
        looper = nil
        playerLayer.player = nil
        player = nil
        NotificationCenter.default.removeObserver(self)
    }

    private func makePlayerIfNeeded() {
        guard player == nil, !isTornDown, let url = Self.videoURL else { return }
        let player = AVQueuePlayer()
        player.isMuted = true
        player.preventsDisplaySleepDuringVideoPlayback = false
        player.allowsExternalPlayback = false
        let item = AVPlayerItem(asset: AVURLAsset(url: url))
        looper = AVPlayerLooper(player: player, templateItem: item)
        playerLayer.player = player
        self.player = player

        readyObservation = playerLayer.observe(\.isReadyForDisplay, options: [.initial, .new]) { [weak self] _, _ in
            Task { @MainActor in self?.revealIfReady() }
        }
    }

    private func revealIfReady() {
        guard playerLayer.isReadyForDisplay, playerLayer.opacity == 0 else { return }
        CATransaction.begin()
        CATransaction.setAnimationDuration(Self.revealDuration)
        CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(name: .easeInEaseOut))
        playerLayer.opacity = 1
        CATransaction.commit()
    }

    private var isOnScreen: Bool {
        guard let window else { return false }
        return window.occlusionState.contains(.visible) && !window.isMiniaturized
    }

    private func updatePlayback() {
        guard let player else { return }
        if wantsPlayback && isOnScreen {
            if player.rate == 0 { player.play() }
        } else if player.rate != 0 {
            player.pause()
        }
    }
}
