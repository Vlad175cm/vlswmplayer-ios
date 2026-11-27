import SwiftUI
import UniformTypeIdentifiers

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
                "artwork": item.artwork ?? "",
                "genre": item.genre ?? "",
                "tags": item.tags ?? ""
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
                artwork: item["artwork"] as? String,
                genre: item["genre"] as? String,
                tags: item["tags"] as? String
            )
        }
    }
}
