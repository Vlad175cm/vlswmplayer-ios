import XCTest
@testable import VLSWMPlayer

final class ZenTests: XCTestCase {
    private func track(
        _ id: Int,
        artist: String,
        genre: String,
        tags: String = "",
        duration: Int = 180
    ) -> Track {
        Track(
            id: id,
            title: "title \(id)",
            artist: artist,
            artistKey: artist,
            duration: duration,
            permalink: "https://soundcloud.com/\(artist)/\(id)",
            artwork: nil,
            genre: genre,
            tags: tags,
            media: [Transcoding(url: "u", preset: "aac_160k", proto: "hls")],
            authorization: ""
        )
    }

    func testMapsDirtyTags() {
        let cases: [(String, String, Genre)] = [
            ("Hip-hop & Rap", "", .hipHop),
            ("Trap", "", .hipHop),
            ("Dance & EDM", "", .electronic),
            ("hardstyle", "", .hardstyle),
            ("", "Hardtekk Tekk Hardstyle", .hardstyle),
            ("Ambient", "", .ambient),
            ("Soundtrack", "", .other),
            ("BFTD", "", .hipHop),
            ("sexyswag", "", .hipHop),
            ("2016", "", .other)
        ]
        for (genre, tags, expected) in cases {
            XCTAssertEqual(Genre.bucket(genre: genre, tags: tags), expected, "\(genre)/\(tags)")
        }
    }

    func testEmptyLikesDoNotStart() {
        var zen = ZenState()
        XCTAssertFalse(zen.begin(likes: []))
        XCTAssertFalse(zen.active)
    }

    func testBeginCountsWeights() {
        var zen = ZenState()
        XCTAssertTrue(zen.begin(likes: [
            track(1, artist: "a", genre: "Hip-hop & Rap"),
            track(2, artist: "b", genre: "Trap"),
            track(3, artist: "c", genre: "Ambient")
        ]))
        XCTAssertEqual(zen.weights[.hipHop] ?? -1, 2)
        XCTAssertEqual(zen.weights[.ambient] ?? -1, 1)
        XCTAssertTrue(zen.active)
    }

    func testEnqueueFiltersLikedShortAndMediaLess() {
        var zen = ZenState()
        _ = zen.begin(likes: [track(99, artist: "seed", genre: "Trap")])
        var short = track(1, artist: "a", genre: "Trap")
        short.duration = 10
        var noMedia = track(2, artist: "b", genre: "Trap")
        noMedia.media = []

        zen.enqueue([
            track(99, artist: "seed", genre: "Trap"),
            short,
            noMedia,
            track(3, artist: "c", genre: "Trap")
        ], target: .hipHop)

        XCTAssertEqual(zen.queue.map(\.id), [3])
    }

    func testArtistWindowKeepsOneTrackPerArtist() {
        var zen = ZenState()
        _ = zen.begin(likes: [track(99, artist: "seed", genre: "Trap")])
        let candidates = (0..<15).map { index in
            track(index + 1, artist: index < 3 ? "same" : "other", genre: "Trap")
        }
        zen.enqueue(candidates, target: .hipHop)
        XCTAssertEqual(zen.queue.count, 2)
        XCTAssertEqual(zen.queue[0].artist, "same")
        XCTAssertEqual(zen.queue[1].artist, "other")
    }

    func testNextAndPrevious() {
        var zen = ZenState()
        _ = zen.begin(likes: [track(99, artist: "seed", genre: "Trap")])
        zen.enqueue([
            track(1, artist: "a", genre: "Trap"),
            track(2, artist: "b", genre: "Trap")
        ], target: .hipHop)
        XCTAssertEqual(zen.current?.id, 1)
        XCTAssertEqual(zen.next()?.id, 2)
        XCTAssertEqual(zen.previous()?.id, 1)
        XCTAssertNil(zen.previous())
    }

    func testSkipExcludesAndLowersWeight() {
        var zen = ZenState()
        _ = zen.begin(likes: [
            track(99, artist: "seed", genre: "Trap"),
            track(100, artist: "seed2", genre: "Ambient")
        ])
        zen.enqueue([
            track(1, artist: "a", genre: "Trap"),
            track(2, artist: "b", genre: "Trap")
        ], target: .hipHop)
        let before = zen.weights[.hipHop] ?? 0
        XCTAssertEqual(zen.skip()?.id, 2)
        XCTAssertTrue(zen.queue.isEmpty == false)
        XCTAssertEqual(zen.weights[.hipHop] ?? -1, max(0, before - 2))
    }

    func testLikeRaisesWeight() {
        var zen = ZenState()
        _ = zen.begin(likes: [
            track(99, artist: "seed", genre: "Trap"),
            track(100, artist: "seed2", genre: "Ambient")
        ])
        zen.onLike(track(7, artist: "x", genre: "Ambient"), liked: true)
        XCTAssertEqual(zen.weights[.ambient] ?? -1, 4)
    }

    func testMergeKeepsPlayPosition() {
        var zen = ZenState()
        _ = zen.begin(likes: [track(99, artist: "seed", genre: "Trap")])
        zen.enqueue([
            track(1, artist: "a", genre: "Trap"),
            track(2, artist: "b", genre: "Trap"),
            track(3, artist: "c", genre: "Trap")
        ], target: .hipHop)
        XCTAssertEqual(zen.next()?.id, 2)

        var refreshed = zen
        refreshed.enqueue([
            track(4, artist: "d", genre: "Trap"),
            track(5, artist: "e", genre: "Trap")
        ], target: .hipHop)
        zen.mergeQueue(refreshed)

        XCTAssertEqual(zen.index, 1)
        XCTAssertEqual(zen.current?.id, 2)
        XCTAssertGreaterThanOrEqual(zen.queue.count, 5)
    }
}
