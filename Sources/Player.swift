import AVFoundation
import Foundation

final class Player {
    private let player = AVPlayer()
    private var observer: Any?
    private var endObserver: NSObjectProtocol?
    private var failObserver: NSObjectProtocol?

    var onEnd: ((AVPlayerItem?) -> Void)?
    var onFail: ((AVPlayerItem?) -> Void)?
    var onPosition: ((Double, Double) -> Void)?

    var currentItem: AVPlayerItem? {
        player.currentItem
    }

    init() {
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, mode: .default)
        try? session.setActive(true)

        observer = player.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 0.25, preferredTimescale: 600),
            queue: .main
        ) { [weak self] time in
            guard let self else { return }
            let position = time.seconds.isFinite ? max(0, time.seconds) : 0
            var duration: Double = 0
            if let item = self.player.currentItem {
                let value = item.duration.seconds
                if value.isFinite, value > 0 { duration = value }
            }
            self.onPosition?(position, duration)
        }

        endObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: nil,
            queue: .main
        ) { [weak self] note in
            self?.onEnd?(note.object as? AVPlayerItem)
        }

        failObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemFailedToPlayToEndTime,
            object: nil,
            queue: .main
        ) { [weak self] note in
            self?.onFail?(note.object as? AVPlayerItem)
        }
    }

    deinit {
        if let observer { player.removeTimeObserver(observer) }
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        if let failObserver { NotificationCenter.default.removeObserver(failObserver) }
    }

    func play(url: URL) {
        let item = AVPlayerItem(url: url)
        item.preferredForwardBufferDuration = 5
        player.replaceCurrentItem(with: item)
        player.play()
        Log.write("player.play \(url.absoluteString.prefix(90))")
    }

    func toggle() {
        if player.timeControlStatus == .playing {
            player.pause()
        } else {
            player.play()
        }
    }

    var isPlaying: Bool {
        player.timeControlStatus == .playing
    }

    var itemStatus: String {
        guard let item = player.currentItem else { return "none" }
        switch item.status {
        case .readyToPlay: return "ready"
        case .failed: return "failed(\(item.error?.localizedDescription ?? "?"))"
        default: return "unknown"
        }
    }

    func seek(_ seconds: Double) {
        player.seek(to: CMTime(seconds: max(0, seconds), preferredTimescale: 600))
    }

    func setVolume(_ value: Float) {
        player.volume = min(1, max(0, value))
    }

    func stop() {
        player.pause()
        player.replaceCurrentItem(with: nil)
    }
}
