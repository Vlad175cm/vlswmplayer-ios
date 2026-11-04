import AVFoundation
import Foundation
import MediaPlayer
import UIKit

@MainActor
final class Model: ObservableObject {
    enum ViewMode {
        case search
        case likes
    }

    @Published var query = ""
    @Published var results: [Track] = []
    @Published var likes: [StoredTrack] = []
    @Published var view: ViewMode = .search
    @Published var selected = 0
    @Published var current: Track?
    @Published var status: String?
    @Published var searching = false
    @Published var artwork: UIImage?
    @Published var position: Double = 0
    @Published var duration: Double = 0
    @Published var playing = false
    @Published var volume: Double
    @Published var cached = false

    private let api = SoundCloudAPI.shared
    private let cache = Cache.shared
    private let player = Player()
    private var searchTask: Task<Void, Never>?
    private var playTask: Task<Void, Never>?
    private var artworkTask: Task<Void, Never>?
    private var playSerial = 0
    private var failStreak = 0
    private var playStartedAt = Date()
    private var loggedStart = false
    private var loggedStall = false
    private var endHandled = false
    private var durationPublished = false
    private var resumeAfterInterruption = false

    init() {
        let stored = UserDefaults.standard.object(forKey: "volume") as? Double
        volume = stored ?? 0.6

        player.onPosition = { [weak self] position, duration in
            guard let self else { return }
            self.position = position
            if duration > 0 { self.duration = duration }
            self.playing = self.player.isPlaying
            if position > 1 { self.failStreak = 0 }
            if !self.loggedStall, Date().timeIntervalSince(self.playStartedAt) > 2.5, position < 0.1 {
                self.loggedStall = true
                Log.write("stall id=\(self.current?.id ?? -1) cached=\(self.cached) status=\(self.player.itemStatus)")
            }
            if duration > 0, !self.durationPublished {
                self.durationPublished = true
                self.updateNowPlaying()
            }
            if position > 0.4, !self.loggedStart {
                self.loggedStart = true
                let ms = Int(Date().timeIntervalSince(self.playStartedAt) * 1000)
                Log.write("started id=\(self.current?.id ?? -1) after \(ms)ms cached=\(self.cached)")
            }
            if self.duration > 1, position >= self.duration - 0.6 {
                self.handleEnd(reason: "timer")
            }
        }
        player.onEnd = { [weak self] item in
            guard let self, let item, item === self.player.currentItem else { return }
            self.handleEnd(reason: "notification")
        }
        player.onFail = { [weak self] item in
            guard let self, let item, item === self.player.currentItem else { return }
            Log.write("track failed id=\(self.current?.id ?? -1)")
            self.finish(success: false)
        }
        player.setVolume(Float(volume))
        likes = Self.loadLikes()
        setupRemoteCommands()
        setupSessionObservers()
        Log.write("app start build=1.1.0 likes=\(likes.count)")
    }

    var visible: [Track] {
        switch view {
        case .search: return results
        case .likes: return likes.map(\.track)
        }
    }

    var hint: String {
        if let status { return status }
        if searching { return "SEARCHING" }
        return cached ? "CACHED" : ""
    }

    func setView(_ mode: ViewMode) {
        guard view != mode else { return }
        view = mode
        selected = 0
    }

    func toggleView() {
        setView(view == .search ? .likes : .search)
    }

    func setQuery(_ text: String) {
        guard query != text else { return }
        query = text
        scheduleSearch()
    }

    private var trimmedQuery: String {
        query.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func scheduleSearch() {
        searchTask?.cancel()
        let text = trimmedQuery
        guard text.count >= 2 else {
            results = []
            searching = false
            return
        }
        searchTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 400_000_000)
            guard !Task.isCancelled, let self else { return }
            await self.runSearch(text)
        }
    }

    private func runSearch(_ text: String) async {
        searching = true
        defer {
            if self.trimmedQuery == text { searching = false }
        }
        do {
            let found = try await api.search(text)
            guard !Task.isCancelled, trimmedQuery == text else { return }
            results = found
            selected = 0
            status = nil
            Log.write("search ok q=\(text) n=\(found.count)")
        } catch {
            guard !Task.isCancelled, trimmedQuery == text else { return }
            results = []
            status = "NO CONNECTION"
            Log.write("search error q=\(text): \(error.localizedDescription)")
        }
    }

    func playSelected() {
        guard selected < visible.count else { return }
        play(visible[selected])
    }

    func play(_ track: Track) {
        playSerial += 1
        let serial = playSerial
        playTask?.cancel()

        current = track
        playStartedAt = Date()
        loggedStart = false
        loggedStall = false
        endHandled = false
        durationPublished = false
        status = "LOADING"
        artwork = nil
        position = 0
        duration = Double(track.duration)
        cached = false
        loadArtwork(track)

        if let file = cache.hit(track.id) {
            cached = true
            player.play(url: file)
            status = nil
            Log.write("play cached id=\(track.id)")
            updateNowPlaying()
            return
        }

        playTask = Task { [weak self] in
            guard let self else { return }
            do {
                let full = track.media.isEmpty ? try await self.api.track(id: track.id) : track
                let url = try await self.api.streamURL(for: full)
                guard serial == self.playSerial, !Task.isCancelled else { return }
                self.current = full
                self.player.play(url: url)
                self.status = nil
                self.updateNowPlaying()
                self.download(id: full.id, url: url)
            } catch {
                guard serial == self.playSerial else { return }
                self.status = "TRACK UNAVAILABLE"
                Log.write("resolve error id=\(track.id): \(error.localizedDescription)")
                self.finish(success: false)
            }
        }
    }

    private func download(id: Int, url: URL) {
        guard cache.hit(id) == nil, !cache.isBusy(id) else { return }
        Task.detached(priority: .utility) { [weak self] in
            let ok = await Cache.shared.download(id: id, from: url)
            guard ok else { return }
            await MainActor.run {
                guard let self, self.current?.id == id else { return }
                self.cached = true
            }
        }
    }

    private func handleEnd(reason: String) {
        guard !endHandled else { return }
        endHandled = true
        Log.write(
            "end \(reason) id=\(current?.id ?? -1) pos=\(Int(position)) dur=\(Int(duration)) "
            + "next=\(selected + 1)/\(visible.count)"
        )
        finish(success: position > 1)
    }

    private func finish(success: Bool) {
        if success {
            failStreak = 0
            advance()
            return
        }
        failStreak += 1
        if failStreak >= 2 {
            status = "TRACK UNAVAILABLE"
            player.stop()
            playing = false
            updateNowPlaying()
            Log.write("giving up after \(failStreak) failures")
            return
        }
        advance()
    }

    private func loadArtwork(_ track: Track) {
        guard let raw = track.artwork, let url = URL(string: raw) else { return }
        artworkTask?.cancel()
        artworkTask = Task { [weak self] in
            guard let (data, _) = try? await URLSession.shared.data(from: url) else { return }
            guard !Task.isCancelled else { return }
            self?.artwork = UIImage(data: data)
            self?.updateNowPlaying()
        }
    }

    func togglePlay() {
        player.toggle()
        playing = player.isPlaying
        updateNowPlaying()
    }

    func seek(by delta: Double) {
        let target = min(max(0, position + delta), duration > 0 ? duration : .greatestFiniteMagnitude)
        player.seek(target)
        position = target
    }

    func seek(toFraction fraction: Double) {
        guard duration > 0 else { return }
        let target = duration * min(max(0, fraction), 1)
        player.seek(target)
        position = target
        updateNowPlaying()
    }

    func setVolume(_ value: Double) {
        volume = min(max(0, value), 1)
        player.setVolume(Float(volume))
        UserDefaults.standard.set(volume, forKey: "volume")
    }

    func advance() {
        guard !visible.isEmpty else { return }
        selected = (selected + 1) % visible.count
        Log.write("advance to index=\(selected) id=\(visible[selected].id)")
        play(visible[selected])
    }

    func goBack() {
        guard !visible.isEmpty else { return }
        selected = (selected - 1 + visible.count) % visible.count
        Log.write("back to index=\(selected) id=\(visible[selected].id)")
        play(visible[selected])
    }

    func select(_ index: Int) {
        guard index < visible.count else { return }
        selected = index
        Log.write("tap index=\(index) id=\(visible[index].id) view=\(view)")
        play(visible[index])
    }

    func isLiked(_ id: Int) -> Bool {
        likes.contains { $0.id == id }
    }

    func toggleLike() {
        guard selected < visible.count else { return }
        toggleLike(visible[selected])
    }

    func toggleLikeCurrent() {
        guard let track = current else { return }
        toggleLike(track)
    }

    private func toggleLike(_ track: Track) {
        if let index = likes.firstIndex(where: { $0.id == track.id }) {
            likes.remove(at: index)
        } else {
            likes.insert(StoredTrack(track), at: 0)
        }
        Self.saveLikes(likes)
        if view == .likes {
            selected = min(selected, max(0, likes.count - 1))
        }
        Log.write("like id=\(track.id) total=\(likes.count)")
    }

    func clearCache() {
        cache.clear()
        cached = false
        status = "CACHE CLEARED"
    }

    // MARK: - system integration

    private func setupRemoteCommands() {
        let center = MPRemoteCommandCenter.shared()

        _ = center.playCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.remotePlay() }
            return .success
        }
        _ = center.pauseCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.remotePause() }
            return .success
        }
        _ = center.togglePlayPauseCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.remoteToggle() }
            return .success
        }
        _ = center.nextTrackCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.advance() }
            return .success
        }
        _ = center.previousTrackCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.goBack() }
            return .success
        }
        _ = center.changePlaybackPositionCommand.addTarget { [weak self] event in
            guard let event = event as? MPChangePlaybackPositionCommandEvent else {
                return .commandFailed
            }
            Task { @MainActor in self?.seekTo(seconds: event.positionTime) }
            return .success
        }
        _ = center.likeCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.toggleLikeCurrent() }
            return .success
        }

        center.playCommand.isEnabled = true
        center.pauseCommand.isEnabled = true
        center.togglePlayPauseCommand.isEnabled = true
        center.nextTrackCommand.isEnabled = true
        center.previousTrackCommand.isEnabled = true
        center.changePlaybackPositionCommand.isEnabled = true
        center.likeCommand.isEnabled = true
    }

    private func setupSessionObservers() {
        let center = NotificationCenter.default
        center.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: nil,
            queue: .main
        ) { [weak self] note in
            Task { @MainActor in self?.handleInterruption(note) }
        }
        center.addObserver(
            forName: AVAudioSession.routeChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] note in
            Task { @MainActor in self?.handleRouteChange(note) }
        }
    }

    private func handleInterruption(_ note: Notification) {
        guard let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: raw) else { return }
        switch type {
        case .began:
            resumeAfterInterruption = playing
            player.pause()
            playing = false
            updateNowPlaying()
            Log.write("interruption began, resume=\(resumeAfterInterruption)")
        case .ended:
            let options = (note.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt)
                .map(AVAudioSession.InterruptionOptions.init(rawValue:)) ?? []
            if options.contains(.shouldResume), resumeAfterInterruption {
                resumeAfterInterruption = false
                try? AVAudioSession.sharedInstance().setActive(true)
                player.play()
                playing = true
                updateNowPlaying()
                Log.write("interruption ended, resumed")
            }
        @unknown default:
            break
        }
    }

    private func handleRouteChange(_ note: Notification) {
        guard let raw = note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt,
              let reason = AVAudioSession.RouteChangeReason(rawValue: raw) else { return }
        if reason == .oldDeviceUnavailable {
            player.pause()
            playing = false
            updateNowPlaying()
            Log.write("headphones disconnected, paused")
        }
    }

    private func remotePlay() {
        try? AVAudioSession.sharedInstance().setActive(true)
        player.play()
        playing = true
        updateNowPlaying()
    }

    private func remotePause() {
        player.pause()
        playing = false
        updateNowPlaying()
    }

    private func remoteToggle() {
        player.toggle()
        playing = player.isPlaying
        updateNowPlaying()
    }

    func seekTo(seconds: Double) {
        let target = min(max(0, seconds), duration > 0 ? duration : seconds)
        player.seek(target)
        position = target
        updateNowPlaying()
    }

    private func updateNowPlaying() {
        guard let track = current else {
            MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
            return
        }
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: track.title,
            MPMediaItemPropertyArtist: track.artist,
            MPMediaItemPropertyPlaybackDuration: duration > 0 ? duration : Double(track.duration),
            MPNowPlayingInfoPropertyElapsedPlaybackTime: position,
            MPNowPlayingInfoPropertyPlaybackRate: playing ? 1.0 : 0.0,
            MPNowPlayingInfoPropertyMediaType: MPNowPlayingInfoMediaType.audio.rawValue
        ]
        if let image = artwork {
            info[MPMediaItemPropertyArtwork] = MPMediaItemArtwork(boundsSize: image.size) { _ in image }
        }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }

    // MARK: - likes storage

    private static var likesURL: URL {
        let base = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("likes.json")
    }

    private static func loadLikes() -> [StoredTrack] {
        guard let data = try? Data(contentsOf: likesURL),
              let decoded = try? JSONDecoder().decode([StoredTrack].self, from: data)
        else { return [] }
        return decoded
    }

    private static func saveLikes(_ likes: [StoredTrack]) {
        guard let data = try? JSONEncoder().encode(likes) else { return }
        try? data.write(to: likesURL, options: .atomic)
    }
}
