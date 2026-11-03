import Foundation

final class Cache {
    static let shared = Cache()

    let dir: URL
    private let lock = NSLock()
    private var busy: Set<Int> = []

    init() {
        let base = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        dir = base.appendingPathComponent("tracks", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    func hit(_ id: Int) -> URL? {
        let url = dir.appendingPathComponent("\(id).audio")
        let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
        return size > 0 ? url : nil
    }

    func remove(_ id: Int) {
        try? FileManager.default.removeItem(at: dir.appendingPathComponent("\(id).audio"))
    }

    func clear() {
        let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        for file in files { try? FileManager.default.removeItem(at: file) }
    }

    func size() -> Int64 {
        let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.fileSizeKey])) ?? []
        return files.reduce(0) { sum, url in
            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            return sum + Int64(size)
        }
    }

    func isBusy(_ id: Int) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return busy.contains(id)
    }

    /// Downloads the resolved stream into a single file. Returns true on success.
    func download(id: Int, from url: URL) async -> Bool {
        lock.lock()
        if busy.contains(id) { lock.unlock(); return false }
        busy.insert(id)
        lock.unlock()
        defer {
            lock.lock(); busy.remove(id); lock.unlock()
        }

        let target = dir.appendingPathComponent("\(id).audio")
        let part = dir.appendingPathComponent("\(id).part")
        try? FileManager.default.removeItem(at: part)

        do {
            if url.path.contains(".m3u8") || url.absoluteString.contains("m3u8") {
                try await downloadHLS(from: url, to: part)
            } else {
                try await downloadFile(from: url, to: part)
            }
            let size = (try? FileManager.default.attributesOfItem(atPath: part.path)[.size] as? Int) ?? 0
            guard size > 1024 else {
                try? FileManager.default.removeItem(at: part)
                return false
            }
            try? FileManager.default.removeItem(at: target)
            try FileManager.default.moveItem(at: part, to: target)
            return true
        } catch {
            try? FileManager.default.removeItem(at: part)
            return false
        }
    }

    private func downloadFile(from url: URL, to target: URL) async throws {
        let (data, response) = try await URLSession.shared.data(from: url)
        if let http = response as? HTTPURLResponse, http.statusCode >= 400 {
            throw URLError(.badServerResponse)
        }
        try data.write(to: target, options: .atomic)
    }

    private func downloadHLS(from url: URL, to target: URL) async throws {
        var playlistURL = url
        var playlist = try await text(playlistURL)

        if let variant = firstVariant(in: playlist, base: playlistURL) {
            playlistURL = variant
            playlist = try await text(playlistURL)
        }

        if playlist.contains("#EXT-X-KEY") {
            throw URLError(.cannotDecodeContentData)
        }

        let base = playlistURL.deletingLastPathComponent()
        var output = Data()

        for raw in playlist.split(separator: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { continue }

            if line.hasPrefix("#EXT-X-MAP:") {
                if let uri = attribute("URI", in: line), let segment = URL(string: uri, relativeTo: base) {
                    output.append(try await data(segment))
                }
                continue
            }
            if line.hasPrefix("#") { continue }
            guard let segment = URL(string: line, relativeTo: base) else { continue }
            output.append(try await data(segment))
        }

        guard output.count > 1024 else { throw URLError(.zeroByteResource) }
        try output.write(to: target, options: .atomic)
    }

    private func firstVariant(in playlist: String, base: URL) -> URL? {
        let lines = playlist.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
        for (index, line) in lines.enumerated() where line.hasPrefix("#EXT-X-STREAM-INF") {
            if index + 1 < lines.count, let url = URL(string: lines[index + 1], relativeTo: base) {
                return url
            }
        }
        return nil
    }

    private func attribute(_ name: String, in line: String) -> String? {
        guard let range = line.range(of: "\(name)=\"") else { return nil }
        let rest = line[range.upperBound...]
        guard let end = rest.firstIndex(of: "\"") else { return nil }
        return String(rest[..<end])
    }

    private func text(_ url: URL) async throws -> String {
        let (data, _) = try await URLSession.shared.data(from: url)
        return String(decoding: data, as: UTF8.self)
    }

    private func data(_ url: URL) async throws -> Data {
        let (data, response) = try await URLSession.shared.data(from: url)
        if let http = response as? HTTPURLResponse, http.statusCode >= 400 {
            throw URLError(.badServerResponse)
        }
        return data
    }
}
