import Foundation

struct Transcoding: Equatable {
    let url: String
    let preset: String
    let proto: String
}

struct Track: Identifiable, Equatable {
    let id: Int
    var title: String
    var artist: String
    var duration: Int
    var permalink: String
    var artwork: String?
    var media: [Transcoding]
    var authorization: String
}

struct StoredTrack: Codable, Equatable {
    var id: Int
    var title: String
    var artist: String
    var duration: Int
    var permalink: String
    var artwork: String?

    var track: Track {
        Track(
            id: id,
            title: title,
            artist: artist,
            duration: duration,
            permalink: permalink,
            artwork: artwork,
            media: [],
            authorization: ""
        )
    }

    init(_ track: Track) {
        id = track.id
        title = track.title
        artist = track.artist
        duration = track.duration
        permalink = track.permalink
        artwork = track.artwork
    }
}

private struct APIUser: Decodable {
    let username: String?
}

private struct APIMedia: Decodable {
    struct Item: Decodable {
        struct Format: Decodable {
            let proto: String?
            enum CodingKeys: String, CodingKey { case proto = "protocol" }
        }
        let url: String?
        let preset: String?
        let format: Format?
    }
    let transcodings: [Item]?
}

private struct APITrack: Decodable {
    let id: Int?
    let title: String?
    let duration: Double?
    let permalink_url: String?
    let artwork_url: String?
    let user: APIUser?
    let media: APIMedia?
    let track_authorization: String?
}

private struct SearchResponse: Decodable {
    let collection: [APITrack]?
}

final class SoundCloudAPI {
    static let shared = SoundCloudAPI()

    private let fallbackClientID = "OGA0P5R5U4CpyooNe9OUcnjIMxao2hB2"
    private let userAgent = "Mozilla/5.0 (iPhone; CPU iPhone OS 15_8 like Mac OS X)"

    private var clientID: String {
        if let saved = UserDefaults.standard.string(forKey: "client_id"), saved.count == 32 {
            return saved
        }
        return fallbackClientID
    }

    private func request(_ url: URL) async throws -> Data {
        var req = URLRequest(url: url)
        req.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        req.timeoutInterval = 12
        let (data, response) = try await URLSession.shared.data(for: req)
        if let http = response as? HTTPURLResponse, http.statusCode >= 400 {
            throw APIError.http(http.statusCode)
        }
        return data
    }

    func search(_ query: String) async throws -> [Track] {
        do {
            return try await search(query, clientID: clientID)
        } catch {
            guard let fresh = try? await refreshClientID() else { throw error }
            return try await search(query, clientID: fresh)
        }
    }

    private func search(_ query: String, clientID: String) async throws -> [Track] {
        var comps = URLComponents(string: "https://api-v2.soundcloud.com/search/tracks")!
        comps.queryItems = [
            URLQueryItem(name: "q", value: query),
            URLQueryItem(name: "client_id", value: clientID),
            URLQueryItem(name: "limit", value: "10")
        ]
        let data = try await request(comps.url!)
        let decoded = try JSONDecoder().decode(SearchResponse.self, from: data)
        return (decoded.collection ?? []).compactMap(map)
    }

    private func map(_ item: APITrack) -> Track? {
        guard let id = item.id else { return nil }
        let media = (item.media?.transcodings ?? []).compactMap { t -> Transcoding? in
            guard let url = t.url else { return nil }
            let proto = t.format?.proto ?? ""
            if proto.contains("encrypted") { return nil }
            return Transcoding(url: url, preset: t.preset ?? "", proto: proto)
        }
        if media.isEmpty { return nil }
        return Track(
            id: id,
            title: item.title ?? "untitled",
            artist: item.user?.username ?? "unknown",
            duration: Int(((item.duration ?? 0) / 1000).rounded()),
            permalink: item.permalink_url ?? "",
            artwork: item.artwork_url.map(bigArtwork),
            media: media,
            authorization: item.track_authorization ?? ""
        )
    }

    private func bigArtwork(_ url: String) -> String {
        url.replacingOccurrences(of: "-large.", with: "-t500x500.")
    }

    func track(id: Int) async throws -> Track {
        var comps = URLComponents(string: "https://api-v2.soundcloud.com/tracks/\(id)")!
        comps.queryItems = [URLQueryItem(name: "client_id", value: clientID)]
        let data = try await request(comps.url!)
        struct Single: Decodable { let id: Int? }
        let decoded = try JSONDecoder().decode(APITrack.self, from: data)
        guard let track = map(decoded) else { throw APIError.unavailable }
        return track
    }

    private func pick(_ media: [Transcoding]) -> Transcoding? {
        for preset in ["aac_160k", "abr_sq", "aac_96k"] {
            if let hit = media.first(where: { $0.preset == preset }) { return hit }
        }
        return media.first
    }

    func streamURL(for track: Track) async throws -> URL {
        guard let transcoding = pick(track.media) else { throw APIError.unavailable }
        var comps = URLComponents(string: transcoding.url)!
        comps.queryItems = [
            URLQueryItem(name: "client_id", value: clientID),
            URLQueryItem(name: "track_authorization", value: track.authorization)
        ]
        let data = try await request(comps.url!)
        struct Stream: Decodable { let url: String }
        let stream = try JSONDecoder().decode(Stream.self, from: data)
        guard let url = URL(string: stream.url) else { throw APIError.unavailable }
        return url
    }

    func refreshClientID() async throws -> String {
        let html = try await request(URL(string: "https://soundcloud.com/")!)
        let text = String(decoding: html, as: UTF8.self)
        let assets = matches(in: text, pattern: #"https://a-v2\.sndcdn\.com/assets/[A-Za-z0-9\-_]+\.js"#)
        for asset in assets.prefix(6) {
            guard let url = URL(string: asset),
                  let data = try? await request(url) else { continue }
            let js = String(decoding: data, as: UTF8.self)
            if let id = matches(in: js, pattern: #"client_id:\s*"([a-zA-Z0-9]{32})""#).first {
                UserDefaults.standard.set(id, forKey: "client_id")
                return id
            }
        }
        throw APIError.noClientID
    }

    private func matches(in text: String, pattern: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let range = NSRange(text.startIndex..., in: text)
        return regex.matches(in: text, range: range).compactMap { match in
            let group = match.numberOfRanges > 1 ? 1 : 0
            guard let r = Range(match.range(at: group), in: text) else { return nil }
            return String(text[r])
        }
    }
}

enum APIError: LocalizedError {
    case http(Int)
    case unavailable
    case noClientID

    var errorDescription: String? {
        switch self {
        case .http(let code): return "HTTP \(code)"
        case .unavailable: return "TRACK UNAVAILABLE"
        case .noClientID: return "NO CLIENT ID"
        }
    }
}
