import XCTest
@testable import VLSWMPlayer

final class LikesTransferTests: XCTestCase {
    func testRoundTripKeepsGenreAndTags() {
        let items = [
            StoredTrack(
                id: 1,
                title: "A",
                artist: "B",
                duration: 10,
                permalink: "https://soundcloud.com/a",
                artwork: "https://x/y.png",
                genre: "Ambient",
                tags: "chill"
            ),
            StoredTrack(
                id: 2,
                title: "C",
                artist: "D",
                duration: 20,
                permalink: "https://soundcloud.com/c",
                artwork: nil,
                genre: nil,
                tags: nil
            )
        ]
        let decoded = LikesTransfer.decode(LikesTransfer.encode(items))
        XCTAssertEqual(decoded.count, 2)
        XCTAssertEqual(decoded[0].id, 1)
        XCTAssertEqual(decoded[0].genre, "Ambient")
        XCTAssertEqual(decoded[0].tags, "chill")
        XCTAssertEqual(decoded[1].genre ?? "", "")
        XCTAssertEqual(decoded[1].tags ?? "", "")
    }

    func testDecodeOldJSONWithoutGenre() {
        let json = #"{"tracks":[{"id":"7","title":"x","artist":"y","duration":1}]}"#
        let decoded = LikesTransfer.decode(Data(json.utf8))
        XCTAssertEqual(decoded.map(\.id), [7])
        XCTAssertNil(decoded[0].genre)
        XCTAssertEqual(decoded[0].track.genre, "")
    }

    func testDecodeAcceptsNumberAndStringIDs() {
        let json = #"{"tracks":[{"id":7,"title":"x"},{"id":"8","title":"y"}]}"#
        let decoded = LikesTransfer.decode(Data(json.utf8))
        XCTAssertEqual(decoded.map(\.id), [7, 8])
    }

    func testDecodeGarbageIsEmpty() {
        XCTAssertTrue(LikesTransfer.decode(Data("nope".utf8)).isEmpty)
    }
}
