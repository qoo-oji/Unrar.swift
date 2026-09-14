# Unrar

[![Swift](https://github.com/mtgto/Unrar.swift/workflows/Swift/badge.svg)](https://github.com/mtgto/Unrar.swift/actions?query=workflow%3ASwift)
[![swift-format](https://github.com/mtgto/Unrar.swift/workflows/swift-format/badge.svg)](https://github.com/mtgto/Unrar.swift/actions?query=workflow%3Aswift-format)

Swift library wraps unrar C++ library provided by [rarlib](https://www.rarlab.com/rar_add.htm).

## Feature

- [x] Supported
  - [x] List entries of archive
  - [x] Extract to memory
  - [x] Extract encrypted archive by password
  - [x] Get comment from the archive
  - [x] Get comment from archive entries
  - [x] SFX archive
  - [x] Extract from archive on the memory (`Archive(data:)`, fork addition)
  - [x] Read every entry in one pass (`forEachEntry`, fork addition; fast for solid archives)
- [ ] Unsupported
  - [ ] Extract to file
  - [ ] Multi-Volume (and never for archives on the memory)

## Usage

```swift
import Unrar

let archive = try Archive(path: "/path/to/archive.rar")
let comment = try archive.comment()
let entries = try archive.entries()
let extractedData = try archive.extract(entries[0])

// An archive held in memory (e.g. one stored inside another archive):
// nothing is written to disk, the bytes are read in place.
let inner = try Archive(data: bytes)

// Every entry in archive order, opening the archive once (a solid archive is decompressed once).
try archive.forEachEntry { entry in
    entry.directory ? nil : { chunk in output.append(chunk) }
}
```

Details of this fork's changes: [docs/MemoryArchive.md](docs/MemoryArchive.md) and [docs/SequentialRead.md](docs/SequentialRead.md) (Japanese).

## Installation

### Swift Package Manager (SPM)

Add `https://github.com/mtgto/Unrar.swift` to your Package.swift.

## Related projects

- [UnrarKit](https://github.com/abbeycode/UnrarKit) Have many unit tests, but no SPM support.
- [Unrar4iOS](https://github.com/ararog/Unrar4iOS) No maintenance.

## License

Swift parts of this software is released under the MIT License, see [LICENSE.txt](LICENSE.txt).

C++ library has different license. See [Sources/Cunrar/readme.txt](Sources/Cunrar/readme.txt).
