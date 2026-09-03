// SPDX-FileCopyrightText: 2021 mtgto <hogerappa@gmail.com>
// SPDX-License-Identifier: MIT

import Cunrar
import Foundation

// NOTE: This class is not thread safe.
public struct Archive: Sendable {
    /// Where the archive bytes come from.
    public enum Source: Sendable {
        case file(URL)
        /// The archive held in memory. Nothing is written to disk; unrar reads the buffer
        /// directly (fork addition, see `RAROpenArchiveMem` in Cunrar). Multi-volume
        /// archives cannot be followed from memory.
        case memory(Data)
    }

    public let source: Source
    /// The archive file. For an in-memory archive this is the placeholder `memory:` URL;
    /// check `source` to tell the two apart.
    public var fileURL: URL {
        switch source {
        case .file(let url): return url
        case .memory: return Archive.memoryPlaceholderURL
        }
    }
    static let memoryPlaceholderURL = URL(string: "memory:")!
    public let password: String?
    public let isVolume: Bool
    public let hasComment: Bool  // maximum comment size = 0x40000 (MAXCMTSIZE in rardefs.hpp)
    public let isHeaderEncrypted: Bool
    public let isFirstVolume: Bool

    public init(path: String, password: String? = nil) throws {
        try self.init(fileURL: URL(fileURLWithPath: path), password: password)
    }

    public init(fileURL: URL, password: String? = nil) throws {
        try self.init(source: .file(fileURL), password: password)
    }

    /// Opens an archive held in memory. The bytes are read in place for every operation,
    /// so nothing is written to disk. Not for multi-volume archives.
    public init(data: Data, password: String? = nil) throws {
        try self.init(source: .memory(data), password: password)
    }

    public init(source: Source, password: String? = nil) throws {
        self.source = source
        self.password = password

        var flags = RAROpenArchiveDataEx()
        flags.OpenMode = UInt32(RAR_OM_LIST)
        flags.CmtBuf = nil
        flags.CmtBufW = nil
        flags.CmtBufSize = 0

        let opened: (isVolume: Bool, hasComment: Bool, isHeaderEncrypted: Bool, isFirstVolume: Bool) = try Archive.withOpenArchive(source: source, password: password, flags: &flags) { _, flags in
            (
                flags.Flags & UInt32(ROADF_VOLUME) != 0,
                flags.Flags & UInt32(ROADF_COMMENT) != 0,
                flags.Flags & UInt32(ROADF_ENCHEADERS) != 0,
                flags.Flags & UInt32(ROADF_FIRSTVOLUME) != 0
            )
        }
        self.isVolume = opened.isVolume
        self.hasComment = opened.hasComment
        self.isHeaderEncrypted = opened.isHeaderEncrypted
        self.isFirstVolume = opened.isFirstVolume
    }

    public func entries() throws -> [Entry] {
        var entries: [Entry] = []
        var flags = RAROpenArchiveDataEx()
        flags.OpenMode = UInt32(RAR_OM_LIST)
        flags.CmtBuf = nil
        flags.CmtBufW = nil
        flags.CmtBufSize = 0

        var header = RARHeaderDataEx()
        try Archive.withOpenArchive(source: self.source, password: self.password, flags: &flags) { data, _ in
            loop: repeat {
                let result = RARReadHeaderEx(data, &header)
                switch result {
                case ERAR_SUCCESS:
                    entries.append(Entry(header))
                case ERAR_END_ARCHIVE:
                    break loop
                default:
                    throw UnrarError.fromErrorCode(result)
                }
            } while RARProcessFile(data, RAR_SKIP, nil, nil) == ERAR_SUCCESS
        }

        return entries
    }

    public func comment() throws -> String {
        var flags = RAROpenArchiveDataEx()
        flags.OpenMode = UInt32(RAR_OM_LIST)
        let buffer = UnsafeMutablePointer<Int8>.allocate(capacity: 0x40001)
        flags.CmtBuf = buffer
        flags.CmtBufW = nil
        flags.CmtBufSize = 0x40001

        defer {
            buffer.deallocate()
        }
        return try Archive.withOpenArchive(source: self.source, password: self.password, flags: &flags) { _, flags in
            if flags.CmtState == ERAR_SMALL_BUF {
                // TODO: Update comment buffer size
                throw UnrarError.unknownFormat
            }
            if flags.Flags & UInt32(ROADF_COMMENT) == 0 {
                return ""
            }
            return String(cString: buffer)
        }
    }

    class Callback {
        let callback: (Data, Progress) -> Void
        let progress: Progress

        init(_ uncompressedSize: UInt64, _ callback: @escaping (Data, Progress) -> Void) {
            self.callback = callback
            self.progress = Progress(totalUnitCount: Int64(uncompressedSize))
        }
    }

    public func extract(_ entry: Entry, handler: @escaping (Data, Progress) -> Void) throws {
        if entry.uncompressedSize == 0 {
            let progress = Progress(totalUnitCount: 1)
            progress.completedUnitCount = 1
            handler(Data(), progress)
            return
        }
        let handlerPointer = Unmanaged<Callback>.passRetained(Callback(entry.uncompressedSize, handler)).toOpaque()
        let callback: UNRARCALLBACK = { msg, userData, p1, p2 in
            switch msg {
            case UCM_PROCESSDATA.rawValue:
                guard let mySelfPtr = UnsafeRawPointer(bitPattern: userData) else {
                    return 0
                }
                let handler = Unmanaged<Callback>.fromOpaque(mySelfPtr).takeUnretainedValue()
                if let ptr = UnsafeRawPointer(bitPattern: p1) {
                    let data = Data(bytes: ptr, count: p2)
                    handler.progress.completedUnitCount += Int64(p2)
                    handler.callback(data, handler.progress)
                    if handler.progress.isCancelled {
                        return -1
                    }
                }
            case UCM_NEEDPASSWORD.rawValue, UCM_NEEDPASSWORDW.rawValue:
                // TODO ?
                break
            default:
                // TODO error handling
                break
            }
            return 0
        }
        var flags = RAROpenArchiveDataEx()
        flags.OpenMode = UInt32(RAR_OM_EXTRACT)
        flags.CmtBuf = nil
        flags.CmtBufSize = 0
        var header = RARHeaderDataEx()
        defer {
            Unmanaged<Callback>.fromOpaque(handlerPointer).release()
        }
        try Archive.withOpenArchive(source: self.source, password: self.password, flags: &flags) { data, _ in
            loop: repeat {
                let result = RARReadHeaderEx(data, &header)
                switch result {
                case ERAR_SUCCESS:
                    // compare fileName
                    if Entry(header) == entry {
                        RARSetCallback(data, callback, Int(bitPattern: OpaquePointer(handlerPointer)))
                        let result = RARProcessFile(data, RAR_OM_EXTRACT, nil, nil)
                        RARSetCallback(data, nil, 0)
                        if result != ERAR_SUCCESS {
                            throw UnrarError.fromErrorCode(result)
                        }
                        break loop
                    }
                case ERAR_END_ARCHIVE:
                    // Not found
                    break loop
                default:
                    throw UnrarError.fromErrorCode(result)
                }
            } while RARProcessFile(data, RAR_SKIP, nil, nil) == ERAR_SUCCESS
        }
    }

    public func extract(_ entry: Entry) throws -> Data {
        var fullData = Data(capacity: Int(entry.uncompressedSize))
        try self.extract(entry) { (data, progress) in
            fullData.append(data)
        }
        if fullData.count == entry.uncompressedSize {
            return fullData
        } else {
            throw UnrarError.unknown
        }
    }

    /// Opens the archive, runs `body` with the unrar handle, and closes it again.
    ///
    /// Every public operation opens and closes the archive within one call. That is what
    /// makes the in-memory source safe: the buffer is only borrowed (`withUnsafeBytes`)
    /// for the duration of the call, so no copy of the archive bytes is needed.
    private static func withOpenArchive<T>(
        source: Source,
        password: String?,
        flags: inout RAROpenArchiveDataEx,
        _ body: (UnsafeMutableRawPointer, inout RAROpenArchiveDataEx) throws -> T
    ) throws -> T {
        switch source {
        case .file(let fileURL):
            let handle = fileURL.path.utf8CString.withUnsafeBufferPointer { (ptr) -> UnsafeMutableRawPointer? in
                flags.ArcName = UnsafeMutablePointer(mutating: ptr.baseAddress)
                return UnsafeMutableRawPointer(RAROpenArchiveEx(&flags))
            }
            return try Archive.run(handle: handle, password: password, flags: &flags, body)
        case .memory(let data):
            return try data.withUnsafeBytes { (bytes: UnsafeRawBufferPointer) -> T in
                let handle = UnsafeMutableRawPointer(RAROpenArchiveMem(&flags, bytes.baseAddress, bytes.count))
                return try Archive.run(handle: handle, password: password, flags: &flags, body)
            }
        }
    }

    private static func run<T>(
        handle: UnsafeMutableRawPointer?,
        password: String?,
        flags: inout RAROpenArchiveDataEx,
        _ body: (UnsafeMutableRawPointer, inout RAROpenArchiveDataEx) throws -> T
    ) throws -> T {
        guard let handle = handle, flags.OpenResult == ERAR_SUCCESS else {
            if let handle = handle {
                RARCloseArchive(handle)
            }
            throw UnrarError.badArchive
        }
        defer {
            RARCloseArchive(handle)
        }
        if let password = password {
            password.utf8CString.withUnsafeBufferPointer { (passwordPtr) -> Void in
                RARSetPassword(handle, UnsafeMutablePointer(mutating: passwordPtr.baseAddress))
            }
        }
        return try body(handle, &flags)
    }
}
