// SPDX-FileCopyrightText: 2026 qoo-oji
// SPDX-License-Identifier: MIT

import XCTest

@testable import Unrar

/// `forEachEntry` must deliver the same bytes as `extract(_:)`, in archive order, in one pass.
final class SequentialReadTests: XCTestCase {
    private func fixture(_ name: String) throws -> URL {
        try XCTUnwrap(Bundle.module.url(forResource: name, withExtension: "rar"))
    }

    private func readAll(_ archive: Archive) throws -> [(name: String, data: Data)] {
        var result: [(name: String, data: Data)] = []
        try archive.forEachEntry { entry in
            guard !entry.directory else { return nil }
            result.append((entry.fileName, Data()))
            let index = result.count - 1
            return { chunk in result[index].data.append(chunk) }
        }
        return result
    }

    func testMatchesExtractInArchiveOrder() throws {
        for (name, password) in [("test", nil), ("multibyte", nil), ("blake2", nil), ("solid", nil), ("encrypted", "password")] as [(String, String?)]
        {
            let url = try fixture(name)
            for archive in [try Archive(fileURL: url, password: password), try Archive(data: Data(contentsOf: url), password: password)] {
                let read = try readAll(archive)
                let files = try archive.entries().filter { !$0.directory }
                XCTAssertEqual(read.map(\.name), files.map(\.fileName), name)
                for (entry, item) in zip(files, read) {
                    XCTAssertEqual(item.data, try archive.extract(entry), "\(name): \(entry.fileName)")
                }
            }
        }
    }

    func testSolidArchiveHasSeveralEntries() throws {
        let read = try readAll(try Archive(fileURL: try fixture("solid")))
        XCTAssertEqual(read.count, 4)
        XCTAssertTrue(read.allSatisfy { !$0.data.isEmpty })
    }

    func testSkippedEntriesAreNotDelivered() throws {
        let archive = try Archive(fileURL: try fixture("solid"))
        var visited: [String] = []
        var delivered = Data()
        try archive.forEachEntry { entry in
            visited.append(entry.fileName)
            guard entry.fileName.hasSuffix("file3.txt") else { return nil }
            return { delivered.append($0) }
        }
        XCTAssertEqual(visited, try archive.entries().map(\.fileName))
        let third = try XCTUnwrap(try archive.entries().first { $0.fileName.hasSuffix("file3.txt") })
        XCTAssertEqual(delivered, try archive.extract(third))
    }

    private struct Stop: Error {}

    func testThrowingFromTheChunkClosureStopsTheWalk() throws {
        let archive = try Archive(fileURL: try fixture("solid"))
        var visited = 0
        XCTAssertThrowsError(
            try archive.forEachEntry { _ in
                visited += 1
                return { _ in throw Stop() }
            }
        ) { error in
            XCTAssertTrue(error is Stop)
        }
        XCTAssertEqual(visited, 1)
    }

    func testThrowingFromBodyStopsTheWalk() throws {
        let archive = try Archive(fileURL: try fixture("solid"))
        XCTAssertThrowsError(try archive.forEachEntry { _ in throw Stop() }) { error in
            XCTAssertTrue(error is Stop)
        }
    }

    func testBadCRCThrows() throws {
        let archive = try Archive(fileURL: try fixture("badcrc"))
        XCTAssertThrowsError(try archive.forEachEntry { _ in { _ in } }) { error in
            XCTAssertEqual(error as? UnrarError, .badData)
        }
    }

    func testEncryptedWithoutPasswordThrows() throws {
        let archive = try Archive(fileURL: try fixture("encrypted"))
        XCTAssertThrowsError(try archive.forEachEntry { _ in { _ in } }) { error in
            XCTAssertEqual(error as? UnrarError, .missingPassword)
        }
    }
}
