// SPDX-FileCopyrightText: 2026 qoo-oji
// SPDX-License-Identifier: MIT

import Cunrar
import Foundation

// Fork addition: walk every entry in one pass (see docs/SequentialRead.md).

extension Archive {
    /// Opens the archive once and visits its entries in archive order.
    ///
    /// For each entry `body` decides what to do: return `nil` to skip the entry, or a closure that receives
    /// the entry's decompressed bytes in chunks. The chunks are delivered while unrar tests the entry, so the
    /// entry's CRC is verified; a mismatch throws after the chunks were delivered.
    ///
    /// `extract(_:)` reopens the archive and walks the headers from the start for every entry. In a solid
    /// archive a skipped entry still has to be decompressed, so reading all entries one by one costs time
    /// proportional to the square of the archive size. This walks the archive once.
    ///
    /// Throwing from `body` or from a chunk closure stops the walk and rethrows that error.
    public func forEachEntry(_ body: (Entry) throws -> ((Data) throws -> Void)?) throws {
        var flags = RAROpenArchiveDataEx()
        flags.OpenMode = UInt32(RAR_OM_EXTRACT)
        flags.CmtBuf = nil
        flags.CmtBufSize = 0
        var header = RARHeaderDataEx()
        try Archive.withOpenArchive(source: self.source, password: self.password, flags: &flags) { data, _ in
            while true {
                let result = RARReadHeaderEx(data, &header)
                if result == ERAR_END_ARCHIVE {
                    return
                }
                guard result == ERAR_SUCCESS else {
                    throw UnrarError.fromErrorCode(result)
                }
                guard let consumer = try body(Entry(header)) else {
                    let skipped = RARProcessFile(data, RAR_SKIP, nil, nil)
                    guard skipped == ERAR_SUCCESS else {
                        throw UnrarError.fromErrorCode(skipped)
                    }
                    continue
                }
                try withoutActuallyEscaping(consumer) { consumer in
                    let context = ChunkContext(consumer)
                    let pointer = Unmanaged.passRetained(context).toOpaque()
                    defer { Unmanaged<ChunkContext>.fromOpaque(pointer).release() }
                    RARSetCallback(data, chunkCallback, Int(bitPattern: pointer))
                    let processed = RARProcessFile(data, RAR_TEST, nil, nil)
                    RARSetCallback(data, nil, 0)
                    if let error = context.error {
                        throw error
                    }
                    guard processed == ERAR_SUCCESS else {
                        throw UnrarError.fromErrorCode(processed)
                    }
                }
            }
        }
    }
}

/// Holds the chunk closure of the entry being tested and the first error it threw.
private final class ChunkContext {
    let consumer: (Data) throws -> Void
    var error: Error?

    init(_ consumer: @escaping (Data) throws -> Void) {
        self.consumer = consumer
    }
}

/// Returning -1 makes unrar abandon the entry (`RARProcessFile` then fails); the error kept in the
/// context is what the caller sees.
private let chunkCallback: UNRARCALLBACK = { message, userData, p1, p2 in
    guard message == UCM_PROCESSDATA.rawValue,
        let contextPointer = UnsafeRawPointer(bitPattern: userData),
        let bytes = UnsafeRawPointer(bitPattern: p1)
    else {
        return 0
    }
    let context = Unmanaged<ChunkContext>.fromOpaque(contextPointer).takeUnretainedValue()
    guard context.error == nil else {
        return -1
    }
    do {
        try context.consumer(Data(bytes: bytes, count: p2))
        return 0
    } catch {
        context.error = error
        return -1
    }
}
