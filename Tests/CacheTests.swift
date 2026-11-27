import XCTest
@testable import VLSWMPlayer

final class CacheTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    private func write(_ bytes: [UInt8], name: String = "sample") throws -> URL {
        let url = dir.appendingPathComponent(name)
        try Data(bytes).write(to: url)
        return url
    }

    func testDetectsM4A() throws {
        var bytes = [UInt8](repeating: 0, count: 4)
        bytes += Array("ftypM4A ".utf8)
        bytes += [UInt8](repeating: 0, count: 8)
        let url = try write(bytes)
        XCTAssertEqual(Cache.shared.fileExtension(for: url), "m4a")
    }

    func testDetectsMp3() throws {
        var bytes = Array("ID3".utf8)
        bytes += [UInt8](repeating: 0, count: 16)
        let url = try write(bytes)
        XCTAssertEqual(Cache.shared.fileExtension(for: url), "mp3")
    }

    func testDetectsOgg() throws {
        var bytes = Array("OggS".utf8)
        bytes += [UInt8](repeating: 0, count: 16)
        let url = try write(bytes)
        XCTAssertEqual(Cache.shared.fileExtension(for: url), "ogg")
    }

    func testDetectsAdts() throws {
        var bytes: [UInt8] = [0xFF, 0xF1]
        bytes += [UInt8](repeating: 0, count: 16)
        let url = try write(bytes)
        XCTAssertEqual(Cache.shared.fileExtension(for: url), "mp3")
    }
}
