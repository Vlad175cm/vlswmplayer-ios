import AVFoundation
import Foundation
import SwiftUI
import UniformTypeIdentifiers

struct LocalTrack: Codable, Identifiable, Equatable {
    var id: String
    var title: String
    var artist: String
    var duration: Int
    var file: String
    var artworkFile: String?

    var numericID: Int {
        var hash = 5381
        for byte in id.utf8 {
            hash = ((hash << 5) &+ hash) &+ Int(byte)
        }
        return abs(hash)
    }

    var url: URL {
        LocalLibrary.uploadedDir.appendingPathComponent(file)
    }

    var track: Track {
        Track(
            id: numericID,
            title: title,
            artist: artist,
            duration: duration,
            permalink: "",
            artwork: artworkFile.map { "file:" + LocalLibrary.artworkDir.appendingPathComponent($0).path },
            media: [],
            authorization: "",
            localURL: url
        )
    }
}

enum LocalLibrary {
    static let supported = ["mp3", "m4a", "aac", "wav", "aiff", "aif", "flac", "alac", "caf"]

    static var docs: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    }

    static var uploadedDir: URL {
        let url = docs.appendingPathComponent("uploaded", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    static var artworkDir: URL {
        let url = docs.appendingPathComponent("artwork", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    static var indexURL: URL {
        docs.appendingPathComponent("uploaded.json")
    }

    static func load() -> [LocalTrack] {
        guard let data = try? Data(contentsOf: indexURL),
              let decoded = try? JSONDecoder().decode([LocalTrack].self, from: data) else {
            return []
        }
        return decoded.filter { FileManager.default.fileExists(atPath: $0.url.path) }
    }

    static func save(_ tracks: [LocalTrack]) {
        guard let data = try? JSONEncoder().encode(tracks) else { return }
        try? data.write(to: indexURL, options: .atomic)
    }

    static func isSupported(_ url: URL) -> Bool {
        supported.contains(url.pathExtension.lowercased())
    }

    static func importFiles(
        _ urls: [URL],
        existing: [LocalTrack],
        progress: @escaping (Int, Int, String) -> Void
    ) -> (added: [LocalTrack], skipped: Int) {
        let usable = urls.filter(isSupported)
        Log.write("import: \(urls.count) picked, \(usable.count) supported")
        var names = Set(existing.map(\.id))
        var added: [LocalTrack] = []
        var skipped = 0

        for (index, source) in usable.enumerated() {
            progress(index, usable.count, source.lastPathComponent)
            let base = source.lastPathComponent
            guard !names.contains(base) else {
                skipped += 1
                continue
            }

            let destination = uploadedDir.appendingPathComponent(base)
            if FileManager.default.fileExists(atPath: destination.path) {
                try? FileManager.default.removeItem(at: destination)
            }
            let access = source.startAccessingSecurityScopedResource()
            defer { if access { source.stopAccessingSecurityScopedResource() } }
            do {
                try FileManager.default.copyItem(at: source, to: destination)
            } catch {
                skipped += 1
                Log.write("import skip \(base): \(error.localizedDescription)")
                continue
            }

            let asset = AVURLAsset(url: destination)
            let duration = Int(asset.duration.seconds.rounded())
            let metadata = asset.commonMetadata

            func item(_ key: AVMetadataKey) -> AVMetadataItem? {
                metadata.first { $0.commonKey == key }
            }

            let title = item(.commonKeyTitle)?.stringValue
                ?? source.deletingPathExtension().lastPathComponent
            let artist = item(.commonKeyArtist)?.stringValue ?? "unknown"

            var artworkName: String?
            if let artworkData = item(.commonKeyArtwork)?.dataValue {
                let name = sanitize(base) + ".img"
                let path = artworkDir.appendingPathComponent(name)
                try? artworkData.write(to: path)
                artworkName = name
            }

            let track = LocalTrack(
                id: base,
                title: title,
                artist: artist,
                duration: duration,
                file: base,
                artworkFile: artworkName
            )
            names.insert(base)
            added.append(track)
        }

        progress(usable.count, usable.count, "")
        Log.write("import done: added=\(added.count) skipped=\(skipped)")
        return (added, skipped)
    }

    static func delete(_ track: LocalTrack) {
        try? FileManager.default.removeItem(at: track.url)
        if let art = track.artworkFile {
            try? FileManager.default.removeItem(at: artworkDir.appendingPathComponent(art))
        }
    }

    static func sanitize(_ name: String) -> String {
        name.map { $0.isLetter || $0.isNumber ? $0 : "_" }.reduce(into: "") { $0.append($1) }
    }
}

struct LikesFile: FileDocument {
    static var readableContentTypes: [UTType] { [.json] }
    static var writableContentTypes: [UTType] { [.json] }

    var data: Data

    init(data: Data) {
        self.data = data
    }

    init(configuration: ReadConfiguration) throws {
        data = configuration.file.regularFileContents ?? Data()
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}

enum LikesTransfer {
    static func encode(_ likes: [StoredTrack]) -> Data {
        let tracks = likes.map { item -> [String: Any] in
            [
                "id": String(item.id),
                "title": item.title,
                "artist": item.artist,
                "duration": item.duration,
                "url": item.permalink,
                "artwork": item.artwork as Any
            ].compactMapValues { $0 is NSNull ? nil : $0 }
        }
        let document: [String: Any] = [
            "app": "vlswmplayer",
            "version": 1,
            "kind": "likes",
            "tracks": tracks
        ]
        return (try? JSONSerialization.data(withJSONObject: document, options: [.prettyPrinted])) ?? Data()
    }

    static func decode(_ data: Data) -> [StoredTrack] {
        guard let object = try? JSONSerialization.jsonObject(with: data),
              let root = object as? [String: Any] else { return [] }
        let items = (root["tracks"] as? [[String: Any]]) ?? []
        return items.compactMap { item in
            guard let rawID = item["id"] else { return nil }
            let id: Int
            if let number = rawID as? Int {
                id = number
            } else if let text = rawID as? String, let number = Int(text) {
                id = number
            } else {
                return nil
            }
            return StoredTrack(
                id: id,
                title: item["title"] as? String ?? "untitled",
                artist: item["artist"] as? String ?? "unknown",
                duration: item["duration"] as? Int ?? 0,
                permalink: item["url"] as? String ?? "",
                artwork: item["artwork"] as? String
            )
        }
    }
}
