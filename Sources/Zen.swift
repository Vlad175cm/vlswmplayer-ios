import Foundation

enum Genre: String, CaseIterable, Codable {
    case hipHop
    case electronic
    case hardstyle
    case ambient
    case rock
    case pop
    case other

    var label: String {
        switch self {
        case .hipHop: return "HIP-HOP"
        case .electronic: return "ELECTRONIC"
        case .hardstyle: return "HARDSTYLE"
        case .ambient: return "AMBIENT"
        case .rock: return "ROCK"
        case .pop: return "POP"
        case .other: return "OTHER"
        }
    }

    var query: String {
        switch self {
        case .hipHop: return "hip hop"
        case .electronic: return "electronic"
        case .hardstyle: return "hardstyle"
        case .ambient: return "ambient"
        case .rock: return "rock"
        case .pop: return "pop"
        case .other: return ""
        }
    }

    static func bucket(genre: String, tags: String) -> Genre {
        let text = "\(genre) \(tags)".lowercased()
        func has(_ needles: [String]) -> Bool {
            needles.contains { text.contains($0) }
        }

        if has(["hardstyle", "hardtekk", "hardtek", "hardcore", "rawstyle", "uptempo", "frenchcore", "gabber"]) {
            return .hardstyle
        }
        if has(["hip-hop", "hip hop", "hiphop", "rap", "trap", "drill", "phonk", "grime", "boom bap", "mylancore", "cloud rap", "sexyswag", "bftd", "widepeek"]) {
            return .hipHop
        }
        if has(["electronic", "edm", "dance", "house", "techno", "electro", "dubstep", "dnb", "drum & bass", "drum and bass", "trance", "idm", "synth", "garage", "jungle", "breakbeat", "hyperpop", "bass"]) {
            return .electronic
        }
        if has(["ambient", "chill", "lofi", "lo-fi", "drone", "downtempo", "sleep", "study"]) {
            return .ambient
        }
        if has(["rock", "metal", "punk", "grunge", "indie", "shoegaze"]) {
            return .rock
        }
        if has(["pop", "r&b", "rnb", "soul", "funk", "disco"]) {
            return .pop
        }
        return .other
    }
}

struct ZenState {
    static let queueTarget = 20
    static let queueLow = 5
    static let artistWindow = 10

    private(set) var queue: [Track] = []
    private(set) var index = 0
    private(set) var active = false
    private(set) var loading = false
    private(set) var serial = 0
    private(set) var error: String?
    private(set) var weights: [Genre: Int] = [:]

    private var baseWeights: [Genre: Int] = [:]
    private var pool: [Genre] = []
    private var recent: [String] = []
    private var seen: Set<Int> = []
    private var excluded: Set<Int> = []
    private var liked: Set<Int> = []

    var current: Track? {
        guard queue.indices.contains(index) else { return nil }
        return queue[index]
    }

    var needsRefill: Bool {
        max(0, queue.count - index - 1) < Self.queueLow
    }

    mutating func begin(likes: [Track]) -> Bool {
        queue = []
        index = 0
        active = false
        loading = false
        serial += 1
        error = nil
        weights = [:]
        baseWeights = [:]
        pool = []
        recent = []
        seen = []
        excluded = []
        liked = Set(likes.map(\.id))

        for track in likes {
            let genre = Genre.bucket(genre: track.genre, tags: track.tags)
            weights[genre, default: 0] += 1
        }
        guard !weights.isEmpty else { return false }
        baseWeights = weights
        pool = buildPool(weights)
        active = true
        return true
    }

    mutating func beginLoading() {
        loading = true
        error = nil
    }

    mutating func finishLoading(error message: String? = nil) {
        loading = false
        error = message
    }

    mutating func nextGenre() -> Genre? {
        if pool.isEmpty {
            pool = buildPool(weights)
        }
        if pool.isEmpty {
            pool = buildPool(baseWeights)
        }
        guard !pool.isEmpty else { return nil }
        return pool.removeFirst()
    }

    mutating func enqueue(_ candidates: [Track], target: Genre) {
        var scored: [(score: Int, order: Int, track: Track)] = []
        for (order, track) in candidates.enumerated() {
            guard accepts(track) else { continue }
            let bucket = Genre.bucket(genre: track.genre, tags: track.tags)
            let score: Int
            if bucket == target {
                score = 6
            } else if target == .other || bucket == .other {
                score = 1
            } else {
                score = -3
            }
            scored.append((score, order, track))
        }
        scored.sort { left, right in
            if left.score != right.score { return left.score > right.score }
            return left.order < right.order
        }

        for item in scored {
            guard queue.count < Self.queueTarget else { break }
            guard accepts(item.track) else { continue }
            guard seen.insert(item.track.id).inserted else { continue }

            let artist = artistOf(item.track)
            if !artist.isEmpty {
                recent.append(artist)
                if recent.count > Self.artistWindow {
                    recent.removeFirst(recent.count - Self.artistWindow)
                }
            }
            queue.append(item.track)
        }
    }

    private func accepts(_ track: Track) -> Bool {
        guard track.id != 0,
              !track.media.isEmpty,
              track.duration >= 30,
              !seen.contains(track.id),
              !excluded.contains(track.id),
              !liked.contains(track.id) else { return false }
        let artist = artistOf(track)
        return !recent.contains(artist)
    }

    private func artistOf(_ track: Track) -> String {
        var key = track.artistKey.trimmingCharacters(in: .whitespacesAndNewlines)
        if key.isEmpty {
            key = track.artist
        }
        if let cut = key.firstIndex(where: { $0 == "(" || $0 == "[" }) {
            key = String(key[..<cut])
        }
        return key.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private func buildPool(_ source: [Genre: Int]) -> [Genre] {
        let maxWeight = Genre.allCases
            .map { min(max(source[$0] ?? 0, 0), 4) }
            .max() ?? 0
        var result: [Genre] = []
        for step in 0..<maxWeight {
            for genre in Genre.allCases where (source[genre] ?? 0) > step {
                result.append(genre)
            }
        }
        return result
    }

    mutating func next() -> Track? {
        guard index + 1 < queue.count else { return nil }
        index += 1
        return current
    }

    mutating func previous() -> Track? {
        guard index > 0 else { return nil }
        index -= 1
        return current
    }

    mutating func skip() -> Track? {
        if let track = current {
            excluded.insert(track.id)
            let genre = Genre.bucket(genre: track.genre, tags: track.tags)
            weights[genre] = max(0, (weights[genre] ?? 0) - 2)
            pool = []
        }
        return next()
    }

    mutating func onLike(_ track: Track, liked: Bool) {
        let genre = Genre.bucket(genre: track.genre, tags: track.tags)
        if liked {
            weights[genre, default: 0] += 3
        } else {
            weights[genre] = max(0, (weights[genre] ?? 0) - 2)
        }
        pool = []
    }

    mutating func markFailed() {
        if let track = current {
            excluded.insert(track.id)
        }
    }

    mutating func mergeQueue(_ other: ZenState) {
        if other.queue.count >= queue.count {
            queue = other.queue
            seen = other.seen
            recent = other.recent
        }
        loading = false
        if index >= queue.count {
            index = max(0, queue.count - 1)
        }
    }
}
