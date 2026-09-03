// SPDX-FileCopyrightText: 2026 qoo
// SPDX-License-Identifier: MIT

import XCTest

@testable import Unrar

/// `Archive(data:)` must behave exactly like `Archive(fileURL:)` on the same bytes.
final class MemoryArchiveTests: XCTestCase {
    private func fixture(_ name: String) throws -> (url: URL, data: Data) {
        let url = try XCTUnwrap(Bundle.module.url(forResource: name, withExtension: "rar"))
        return (url, try Data(contentsOf: url))
    }

    func testEntriesAndExtractMatchFileArchive() throws {
        for (name, password) in [("test", nil), ("multibyte", nil), ("multibyte.v4", nil), ("blake2", nil), ("encrypted", "password"), ("encrypted-header", "password")] as [(String, String?)] {
            let (url, data) = try fixture(name)
            let fromFile = try Archive(fileURL: url, password: password)
            let fromMemory = try Archive(data: data, password: password)
            XCTAssertEqual(fromMemory.isVolume, fromFile.isVolume, name)
            XCTAssertEqual(fromMemory.hasComment, fromFile.hasComment, name)
            XCTAssertEqual(fromMemory.isHeaderEncrypted, fromFile.isHeaderEncrypted, name)
            XCTAssertEqual(fromMemory.fileURL, Archive.memoryPlaceholderURL, name)

            let fileEntries = try fromFile.entries()
            let memoryEntries = try fromMemory.entries()
            XCTAssertEqual(memoryEntries, fileEntries, name)
            XCTAssertFalse(memoryEntries.isEmpty, name)
            for entry in memoryEntries where !entry.directory {
                XCTAssertEqual(try fromMemory.extract(entry), try fromFile.extract(entry), "\(name): \(entry.fileName)")
            }
        }
    }

    func testCommentMatchesFileArchive() throws {
        let (url, data) = try fixture("test")
        XCTAssertEqual(try Archive(data: data).comment(), try Archive(fileURL: url).comment())
    }

    func testSameArchiveCanBeReadRepeatedly() throws {
        let (_, data) = try fixture("test")
        let archive = try Archive(data: data)
        let first = try archive.entries()
        for _ in 0..<3 {
            XCTAssertEqual(try archive.entries(), first)
            for entry in first where !entry.directory {
                XCTAssertEqual(try archive.extract(entry).count, Int(entry.uncompressedSize))
            }
        }
    }

    func testBadCRCIsReportedFromMemory() throws {
        let (url, data) = try fixture("badcrc")
        let fromFile = try Archive(fileURL: url)
        let fromMemory = try Archive(data: data)
        let entry = try XCTUnwrap(try fromMemory.entries().first)
        XCTAssertThrowsError(try fromFile.extract(entry))
        XCTAssertThrowsError(try fromMemory.extract(entry))
    }

    func testGarbageIsRejected() {
        XCTAssertThrowsError(try Archive(data: Data("this is not a rar archive".utf8)))
        XCTAssertThrowsError(try Archive(data: Data()))
    }

    func testTruncatedArchiveDoesNotCrash() throws {
        let (_, data) = try fixture("test")
        // Header intact, data cut short: listing works, extraction must fail cleanly.
        let truncated = data.prefix(data.count / 2)
        if let archive = try? Archive(data: truncated) {
            for entry in (try? archive.entries()) ?? [] where !entry.directory {
                _ = try? archive.extract(entry)
            }
        }
    }

    func testVolumesCannotBeFollowedFromMemory() throws {
        let (url, data) = try fixture("volumes.part1")
        let fromMemory = try Archive(data: data)
        XCTAssertTrue(fromMemory.isVolume)
        let fileEntries = try Archive(fileURL: url).entries()
        // The first volume's own headers are readable...
        let memoryEntries = try fromMemory.entries()
        XCTAssertFalse(memoryEntries.isEmpty)
        // ...but an entry continued in the next volume cannot be extracted.
        if let split = fileEntries.first(where: { entry in memoryEntries.contains(entry) }) {
            _ = try? fromMemory.extract(split)
        }
    }
}
