import CryptoKit
import Foundation

/// An Artemis `.pfs` archive (`pf6`, or `pf8` whose file data is encrypted).
///
/// Layout, little-endian:
///
///     "pf" + version ("6" or "8")
///     u32 index size              (bytes from offset 7 to the end of the index)
///     u32 file count
///     per file: u32 name length, name (UTF-8, `\` separated), u32 0, u32 offset, u32 size
///     a table of the entries' offset-field positions (unused here)
///
/// `pf8` XORs each file's bytes with the SHA-1 of the index (the bytes from offset 7 to
/// 7 + index size), repeating the 20-byte key from the start of every file.
public final class PFSArchive: @unchecked Sendable {
    public struct Entry: Hashable, Sendable {
        /// Path inside the archive, `/` separated, as the game spells it.
        public let path: String
        public let offset: UInt64
        public let size: UInt64
    }

    public enum Version: Character, Sendable {
        case pf6 = "6"
        case pf8 = "8"
    }

    public enum Failure: Error, Equatable {
        case notAnArchive
        case unsupportedVersion(Character)
        case truncatedIndex
        case entryOutOfBounds(String)
    }

    public let url: URL
    public let version: Version
    public let entries: [Entry]
    private let key: [UInt8]?
    private let handle: FileHandle
    private let lock = NSLock()

    public init(url: URL) throws {
        self.url = url
        handle = try FileHandle(forReadingFrom: url)
        let fileSize = try handle.seekToEnd()
        try handle.seek(toOffset: 0)
        guard let header = try handle.read(upToCount: 11), header.count == 11,
              header[0] == UInt8(ascii: "p"), header[1] == UInt8(ascii: "f")
        else { throw Failure.notAnArchive }
        let versionCharacter = Character(UnicodeScalar(header[2]))
        guard let version = Version(rawValue: versionCharacter) else { throw Failure.unsupportedVersion(versionCharacter) }
        self.version = version
        let indexSize = UInt64(Self.u32(header, 3))
        let count = Int(Self.u32(header, 7))
        guard 7 + indexSize <= fileSize else { throw Failure.truncatedIndex }

        try handle.seek(toOffset: 7)
        guard let index = try handle.read(upToCount: Int(indexSize)), index.count == Int(indexSize) else {
            throw Failure.truncatedIndex
        }
        key = version == .pf8 ? Array(Insecure.SHA1.hash(data: index)) : nil

        // `index` starts at file offset 7; the count is its first 4 bytes.
        var position = 4
        var entries: [Entry] = []
        entries.reserveCapacity(count)
        for _ in 0 ..< count {
            guard position + 4 <= index.count else { throw Failure.truncatedIndex }
            let nameLength = Int(Self.u32(index, position))
            position += 4
            guard position + nameLength + 12 <= index.count else { throw Failure.truncatedIndex }
            let nameBytes = index[index.startIndex + position ..< index.startIndex + position + nameLength]
            position += nameLength
            let offset = UInt64(Self.u32(index, position + 4))
            let size = UInt64(Self.u32(index, position + 8))
            position += 12
            let name = String(decoding: nameBytes, as: UTF8.self).replacingOccurrences(of: "\\", with: "/")
            guard offset + size <= fileSize else { throw Failure.entryOutOfBounds(name) }
            entries.append(Entry(path: name, offset: offset, size: size))
        }
        self.entries = entries
    }

    deinit {
        try? handle.close()
    }

    /// The bytes of one file, decrypted.
    public func data(for entry: Entry) throws -> Data {
        lock.lock()
        defer { lock.unlock() }
        try handle.seek(toOffset: entry.offset)
        guard var data = try handle.read(upToCount: Int(entry.size)), data.count == Int(entry.size) else {
            throw Failure.entryOutOfBounds(entry.path)
        }
        if let key {
            data.withUnsafeMutableBytes { bytes in
                for i in 0 ..< bytes.count { bytes[i] ^= key[i % key.count] }
            }
        }
        return data
    }

    private static func u32(_ data: Data, _ offset: Int) -> UInt32 {
        let start = data.startIndex + offset
        return UInt32(data[start]) | UInt32(data[start + 1]) << 8 | UInt32(data[start + 2]) << 16 | UInt32(data[start + 3]) << 24
    }
}
