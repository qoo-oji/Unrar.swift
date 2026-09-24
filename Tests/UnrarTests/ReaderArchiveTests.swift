// SPDX-FileCopyrightText: 2026 qoo
// SPDX-License-Identifier: MIT

import XCTest

@testable import Unrar

/// `Archive(source: .reader(...))` must behave exactly like `Archive(fileURL:)` on the same bytes.
final class ReaderArchiveTests: XCTestCase {
    private func fixture(_ name: String) throws -> (url: URL, data: Data) {
        let url = try XCTUnwrap(Bundle.module.url(forResource: name, withExtension: "rar"))
        return (url, try Data(contentsOf: url))
    }

    /// A reader over `data` that returns at most `maxChunk` bytes per call (to exercise short reads)
    /// and counts its calls.
    private final class Counter: @unchecked Sendable { var calls = 0 }
    private func reader(_ data: Data, maxChunk: Int = .max, counter: Counter? = nil) -> Archive.PositionalReader {
        Archive.PositionalReader(size: Int64(data.count)) { offset, buffer in
            counter?.calls += 1
            guard offset >= 0, offset < Int64(data.count) else { return 0 }
            let start = Int(offset)
            let count = min(buffer.count, data.count - start, maxChunk)
            data.copyBytes(to: UnsafeMutableRawBufferPointer(rebasing: buffer[0..<count]), from: start..<(start + count))
            return count
        }
    }

    func testEntriesAndExtractMatchFileArchive() throws {
        for (name, password) in [("test", nil), ("multibyte", nil), ("multibyte.v4", nil), ("blake2", nil), ("encrypted", "password"), ("encrypted-header", "password")] as [(String, String?)] {
            let (url, data) = try fixture(name)
            let fromFile = try Archive(fileURL: url, password: password)
            for maxChunk in [Int.max, 7] {
                let counter = Counter()
                let fromReader = try Archive(source: .reader(reader(data, maxChunk: maxChunk, counter: counter)), password: password)
                XCTAssertEqual(fromReader.isVolume, fromFile.isVolume, name)
                XCTAssertEqual(fromReader.hasComment, fromFile.hasComment, name)
                XCTAssertEqual(fromReader.isHeaderEncrypted, fromFile.isHeaderEncrypted, name)
                XCTAssertEqual(fromReader.fileURL, Archive.memoryPlaceholderURL, name)
                let entries = try fromReader.entries()
                XCTAssertEqual(entries, try fromFile.entries(), name)
                XCTAssertFalse(entries.isEmpty, name)
                for entry in entries where !entry.directory {
                    XCTAssertEqual(try fromReader.extract(entry), try fromFile.extract(entry), "\(name): \(entry.fileName)")
                }
                XCTAssertGreaterThan(counter.calls, 0, name)
            }
        }
    }

    func testForEachEntryMatchesFileArchive() throws {
        let (url, data) = try fixture("test")
        func collect(_ archive: Archive) throws -> [String: Data] {
            var result: [String: Data] = [:]
            try archive.forEachEntry { entry in
                guard !entry.directory else { return nil }
                let name = entry.fileName
                return { chunk in result[name, default: Data()].append(chunk) }
            }
            return result
        }
        let fromFile = try collect(try Archive(fileURL: url))
        XCTAssertFalse(fromFile.isEmpty)
        XCTAssertEqual(try collect(try Archive(source: .reader(reader(data)))), fromFile)
    }

    func testReadErrorFailsCleanly() throws {
        let (_, data) = try fixture("test")
        // Fails every read: opening must throw, not crash.
        let failing = Archive.PositionalReader(size: Int64(data.count)) { _, _ in -1 }
        XCTAssertThrowsError(try Archive(source: .reader(failing)))
        // Fails only past the headers: listing works, extraction must fail cleanly.
        let archive = try Archive(source: .reader(reader(data)))
        let entries = try archive.entries()
        let cutoff = Int64(data.count / 2)
        let flaky = Archive.PositionalReader(size: Int64(data.count)) { offset, buffer in
            guard offset < cutoff else { return -1 }
            let start = Int(offset)
            let count = min(buffer.count, Int(cutoff) - start)
            data.copyBytes(to: UnsafeMutableRawBufferPointer(rebasing: buffer[0..<count]), from: start..<(start + count))
            return count
        }
        if let partial = try? Archive(source: .reader(flaky)) {
            for entry in entries where !entry.directory {
                _ = try? partial.extract(entry)
            }
        }
    }

    func testGarbageIsRejected() {
        let garbage = Data("this is not a rar archive".utf8)
        XCTAssertThrowsError(try Archive(source: .reader(reader(garbage))))
        XCTAssertThrowsError(try Archive(source: .reader(reader(Data()))))
    }

    func testVolumesCannotBeFollowedFromReader() throws {
        let (_, data) = try fixture("volumes.part1")
        let fromReader = try Archive(source: .reader(reader(data)))
        XCTAssertTrue(fromReader.isVolume)
        XCTAssertFalse(try fromReader.entries().isEmpty)
    }
}
