import Foundation
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

    private let api = SoundCloudAPI.shared
    private let cache = Cache.shared
    private let player = Player()
    private var searchTask: Task<Void, Never>?
    private var playTask: Task<Void, Never>?
    private var artworkTask: Task<Void, Never>?
    private var playSerial = 0

    init() {
        let stored = UserDefaults.standard.object(forKey: "volume") as? Double
        volume = stored ?? 0.6

        player.onPosition = { [weak self] position, duration in
            guard let self else { return }
            self.position = position
            if duration > 0 { self.duration = duration }
            self.playing = self.player.isPlaying
        }
        player.onEnd = { [weak self] in
            self?.advance()
        }
        player.setVolume(Float(volume))
        likes = Self.loadLikes()
    }

    var visible: [Track] {
        switch view {
        case .search: return results
        case .likes: return likes.map(\.track)
        }
    }

    var hint: String {
        if let status { return status }
        return searching ? "SEARCHING" : ""
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

    private func scheduleSearch() {
        searchTask?.cancel()
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 2 else {
            results = []
            searching = false
            return
        }
        searchTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 400_000_000)
            guard !Task.isCancelled, let self else { return }
            await self.runSearch(trimmed)
        }
    }

    private func runSearch(_ text: String) async {
        searching = true
        status = nil
        defer { searching = false }
        do {
            let found = try await api.search(text)
            results = found
            selected = 0
        } catch {
            results = []
            status = "NO CONNECTION"
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
        status = "LOADING"
        artwork = nil
        position = 0
        duration = Double(track.duration)
        loadArtwork(track)

        playTask = Task { [weak self] in
            guard let self else { return }

            if let file = self.cache.hit(track.id) {
                self.player.play(url: file)
                self.status = nil
                return
            }

            do {
                let full = track.media.isEmpty ? try await self.api.track(id: track.id) : track
                let url = try await self.api.streamURL(for: full)
                guard serial == self.playSerial, !Task.isCancelled else { return }
                self.current = full
                self.player.play(url: url)
                self.status = nil
                self.download(id: full.id, url: url)
            } catch {
                guard serial == self.playSerial else { return }
                self.status = "TRACK UNAVAILABLE"
                self.advance()
            }
        }
    }

    private func download(id: Int, url: URL) {
        guard cache.hit(id) == nil, !cache.isBusy(id) else { return }
        Task.detached(priority: .utility) {
            _ = await Cache.shared.download(id: id, from: url)
        }
    }

    private func loadArtwork(_ track: Track) {
        guard let raw = track.artwork, let url = URL(string: raw) else { return }
        artworkTask?.cancel()
        artworkTask = Task { [weak self] in
            guard let (data, _) = try? await URLSession.shared.data(from: url) else { return }
            guard !Task.isCancelled else { return }
            self?.artwork = UIImage(data: data)
        }
    }

    func togglePlay() {
        player.toggle()
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
    }

    func setVolume(_ value: Double) {
        volume = min(max(0, value), 1)
        player.setVolume(Float(volume))
        UserDefaults.standard.set(volume, forKey: "volume")
    }

    func advance() {
        guard !visible.isEmpty else { return }
        if selected + 1 < visible.count {
            selected += 1
            play(visible[selected])
        }
    }

    func goBack() {
        guard !visible.isEmpty, selected > 0 else { return }
        selected -= 1
        play(visible[selected])
    }

    func select(_ index: Int) {
        guard index < visible.count else { return }
        selected = index
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
    }

    func clearCache() {
        cache.clear()
        status = "CACHE CLEARED"
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
