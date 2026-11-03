import AVFoundation
import Foundation

final class Player {
    private let player = AVPlayer()
    private var observer: Any?
    private var endObserver: NSObjectProtocol?

    var onEnd: (() -> Void)?
    var onPosition: ((Double, Double) -> Void)?

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
        ) { [weak self] _ in
            self?.onEnd?()
        }
    }

    deinit {
        if let observer { player.removeTimeObserver(observer) }
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
    }

    func play(url: URL, startAt: Double = 0) {
        let item = AVPlayerItem(url: url)
        player.replaceCurrentItem(with: item)
        if startAt > 0 {
            player.seek(to: CMTime(seconds: startAt, preferredTimescale: 600))
        }
        player.play()
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
