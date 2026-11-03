import Foundation

final class Cache {
    static let shared = Cache()

    let dir: URL
    private let lock = NSLock()
    private var busy: Set<Int> = []

    private lazy var session: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 20
        config.timeoutIntervalForResource = 60
        config.httpAdditionalHeaders = ["User-Agent": "Mozilla/5.0 (iPhone; CPU iPhone OS 15_8 like Mac OS X)"]
        return URLSession(configuration: config)
    }()

    init() {
        let base = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        dir = base.appendingPathComponent("tracks", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    private let extensions = ["m4a", "mp3", "ogg", "audio"]

    func hit(_ id: Int) -> URL? {
        for ext in extensions {
            let url = dir.appendingPathComponent("\(id).\(ext)")
            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            if size > 1024 { return url }
        }
        return nil
    }

    func remove(_ id: Int) {
        for ext in extensions {
            try? FileManager.default.removeItem(at: dir.appendingPathComponent("\(id).\(ext)"))
        }
    }

    private func fileExtension(for url: URL) -> String {
        guard let handle = try? FileHandle(forReadingFrom: url),
              let head = try? handle.read(upToCount: 16),
              head.count >= 8 else { return "m4a" }
        try? handle.close()
        if head[4..<8].elementsEqual(Array("ftyp".utf8)) { return "m4a" }
        if head.starts(with: [0x49, 0x44, 0x33]) { return "mp3" }
        if head.starts(with: [0x4F, 0x67, 0x67, 0x53]) { return "ogg" }
        if head.count > 1, head[0] == 0xFF, (head[1] & 0xE0) == 0xE0 { return "mp3" }
        return "m4a"
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

        let part = dir.appendingPathComponent("\(id).part")
        try? FileManager.default.removeItem(at: part)

        do {
            let hls = await isHLS(url)
            Log.write("cache start \(id) hls=\(hls)")
            var succeeded = false
            var lastError: Error = URLError(.unknown)
            for attempt in 0..<2 {
                do {
                    try? FileManager.default.removeItem(at: part)
                    if hls {
                        try await downloadHLS(from: url, to: part)
                    } else {
                        try await downloadFile(from: url, to: part)
                    }
                    succeeded = true
                    break
                } catch {
                    lastError = error
                    Log.write("cache retry \(id) attempt=\(attempt): \(error.localizedDescription)")
                    try? await Task.sleep(nanoseconds: 800_000_000)
                }
            }
            if !succeeded { throw lastError }
            let size = (try? FileManager.default.attributesOfItem(atPath: part.path)[.size] as? Int) ?? 0
            guard size > 1024 else {
                try? FileManager.default.removeItem(at: part)
                return false
            }
            let ext = fileExtension(for: part)
            let target = dir.appendingPathComponent("\(id).\(ext)")
            remove(id)
            try FileManager.default.moveItem(at: part, to: target)
            Log.write("cache ok \(id) bytes=\(size) ext=\(ext)")
            return true
        } catch {
            try? FileManager.default.removeItem(at: part)
            Log.write("cache fail \(id): \(error.localizedDescription)")
            return false
        }
    }

    private func isHLS(_ url: URL) async -> Bool {
        if url.absoluteString.contains("m3u8") { return true }
        var req = URLRequest(url: url)
        req.httpMethod = "HEAD"
        if let (_, response) = try? await session.data(for: req),
           let http = response as? HTTPURLResponse,
           let type = http.value(forHTTPHeaderField: "Content-Type") {
            return type.contains("mpegurl")
        }
        return false
    }

    private func downloadFile(from url: URL, to target: URL) async throws {
        let (data, response) = try await session.data(from: url)
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
        let (data, _) = try await session.data(from: url)
        return String(decoding: data, as: UTF8.self)
    }

    private func data(_ url: URL) async throws -> Data {
        var lastError: Error = URLError(.unknown)
        for _ in 0..<2 {
            do {
                let (data, response) = try await session.data(from: url)
                if let http = response as? HTTPURLResponse, http.statusCode >= 400 {
                    throw URLError(.badServerResponse)
                }
                return data
            } catch {
                lastError = error
                try? await Task.sleep(nanoseconds: 300_000_000)
            }
        }
        throw lastError
    }
}
