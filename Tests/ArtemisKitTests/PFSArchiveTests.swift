import CryptoKit
import Foundation
import Testing
@testable import ArtemisKit

/// Builds `.pfs` archives in the layout Artemis uses, for tests.
private func makeArchive(_ files: [(String, Data)], version: Character = "6") -> Data {
    // Index (from offset 7): count, entries, then the offset table.
    var entries = Data()
    var offsetFieldPositions: [Int] = []
    for (name, _) in files {
        let nameBytes = Data(name.replacingOccurrences(of: "/", with: "\\").utf8)
        entries.append(u32(nameBytes.count))
        entries.append(nameBytes)
        entries.append(u32(0))
        offsetFieldPositions.append(7 + 4 + entries.count) // patched below
        entries.append(u32(0)) // offset
        entries.append(u32(0)) // size
    }
    var table = u32(files.count + 1)
    for position in offsetFieldPositions { table.append(u64(position)) }
    table.append(u64(0))
    table.append(u32(0))
    var index = u32(files.count) + entries + table
    let dataStart = 7 + index.count

    // Fill in offsets and sizes now that the index length is known.
    var offset = dataStart
    var cursor = 4
    for (name, data) in files {
        cursor += 4 + Data(name.utf8).count + 4
        index.replaceSubrange(cursor ..< cursor + 4, with: u32(offset))
        index.replaceSubrange(cursor + 4 ..< cursor + 8, with: u32(data.count))
        cursor += 8
        offset += data.count
    }

    // The header's file count is the index's first field.
    var archive = Data("pf".utf8) + Data([UInt8(String(version).utf8.first!)]) + u32(index.count) + index
    let key = Array(Insecure.SHA1.hash(data: index))
    for (_, data) in files {
        var bytes = [UInt8](data)
        if version == "8" { for i in bytes.indices { bytes[i] ^= key[i % key.count] } }
        archive.append(contentsOf: bytes)
    }
    return archive
}

private func u32(_ value: Int) -> Data {
    withUnsafeBytes(of: UInt32(value).littleEndian) { Data($0) }
}

private func u64(_ value: Int) -> Data {
    withUnsafeBytes(of: UInt64(value).littleEndian) { Data($0) }
}

private func temporaryFolder() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("artemis-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

@Suite struct PFSArchiveTests {
    @Test func readsPF6() throws {
        let folder = try temporaryFolder()
        let url = folder.appendingPathComponent("root.pfs")
        try makeArchive([("Config.lua", Data("-- config".utf8)), ("system/first.iet", Data("[var]".utf8))]).write(to: url)
        let archive = try PFSArchive(url: url)
        #expect(archive.version == .pf6)
        #expect(archive.entries.map(\.path) == ["Config.lua", "system/first.iet"])
        #expect(try archive.data(for: archive.entries[1]) == Data("[var]".utf8))
    }

    @Test func decryptsPF8() throws {
        let folder = try temporaryFolder()
        let url = folder.appendingPathComponent("root.pfs")
        let text = Data(String(repeating: "ast = { block = {} }\n", count: 5).utf8)
        try makeArchive([("script/main.ast", text)], version: "8").write(to: url)
        let archive = try PFSArchive(url: url)
        #expect(archive.version == .pf8)
        #expect(try archive.data(for: archive.entries[0]) == text)
    }

    @Test func rejectsOtherFiles() throws {
        let folder = try temporaryFolder()
        let url = folder.appendingPathComponent("root.pfs")
        try Data("PK\u{3}\u{4}not an archive".utf8).write(to: url)
        #expect(throws: PFSArchive.Failure.notAnArchive) { try PFSArchive(url: url) }
    }

    @Test func updatesOverrideAndPatchWins() throws {
        let game = try temporaryFolder()
        let patch = try temporaryFolder()
        try makeArchive([("tag.ini", Data("base".utf8)), ("bg/a.png", Data("A".utf8))]).write(to: game.appendingPathComponent("root.pfs"))
        try makeArchive([("tag.ini", Data("update 1".utf8))]).write(to: game.appendingPathComponent("root.pfs.001"))
        try makeArchive([("tag.ini", Data("update 0".utf8)), ("bg/b.png", Data("B".utf8))]).write(to: game.appendingPathComponent("root.pfs.000"))
        try makeArchive([("voice/x.ogg", Data("X".utf8))]).write(to: game.appendingPathComponent("voice.pfs"))
        try Data("loose".utf8).write(to: game.appendingPathComponent("system.ini"))
        try FileManager.default.createDirectory(at: patch.appendingPathComponent("BG"), withIntermediateDirectories: true)
        try Data("patched".utf8).write(to: patch.appendingPathComponent("BG/A.png"))

        #expect(try ArtemisFileSystem.archiveURLs(in: game).map(\.lastPathComponent)
            == ["root.pfs", "root.pfs.000", "root.pfs.001", "voice.pfs"])
        let fs = try ArtemisFileSystem(gameRoot: game, patchRoot: patch)
        #expect(try fs.data("tag.ini") == Data("update 1".utf8))
        #expect(try fs.data("bg/b.png") == Data("B".utf8))
        #expect(try fs.data("BG\\a.PNG") == Data("patched".utf8))
        #expect(try fs.data("voice/x.ogg") == Data("X".utf8))
        #expect(try fs.data("system.ini") == Data("loose".utf8))
        #expect(fs.file("missing.txt") == nil)
    }
}
