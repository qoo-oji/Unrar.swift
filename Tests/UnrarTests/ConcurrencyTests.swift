// SPDX-FileCopyrightText: 2026 qoo
// SPDX-License-Identifier: MIT

import XCTest

@testable import Unrar

/// Operations on different archives in different threads must not see each other's errors.
///
/// unrar keeps its error state in one object (`ErrHandler`). With a single process-wide object, an
/// extraction that fails on one thread (a CRC error) makes a successful extraction on another thread
/// report that error, and opening an archive on one thread clears another thread's error.
final class ConcurrencyTests: XCTestCase {
    func testAFailingArchiveOnAnotherThreadDoesNotFailAGoodOne() throws {
        let good = try Archive(fileURL: try XCTUnwrap(Bundle.module.url(forResource: "test", withExtension: "rar")))
        let bad = try Archive(fileURL: try XCTUnwrap(Bundle.module.url(forResource: "badcrc", withExtension: "rar")))
        let goodEntries = try good.entries().filter { !$0.directory }
        let badEntry = try XCTUnwrap(try bad.entries().first)
        let expected = try goodEntries.map { try good.extract($0) }

        let stop = DispatchSemaphore(value: 0)
        let failingThreadDone = DispatchSemaphore(value: 0)
        let failing = Thread {
            while stop.wait(timeout: .now()) == .timedOut {
                _ = try? bad.extract(badEntry)
            }
            failingThreadDone.signal()
        }
        failing.start()

        var spuriousFailures = 0
        for _ in 0..<400 {
            for (entry, data) in zip(goodEntries, expected) {
                if (try? good.extract(entry)) != data { spuriousFailures += 1 }
            }
        }
        stop.signal()
        failingThreadDone.wait()
        XCTAssertEqual(spuriousFailures, 0)
    }
}
