// This Source Code Form is subject to the terms of the Mozilla Public License, v. 2.0.
// If a copy of the MPL was not distributed with this file, You can obtain one at
// https://mozilla.org/MPL/2.0/.

import Foundation

/// The files an Artemis game sees: its `.pfs` archives plus loose files, resolved the way
/// the engine resolves them (the engine's `spec/pack_file.txt`), with Shiori's patch
/// folder on top.
///
/// The **root archive** is `<exe name>.pfs`, or `root.pfs`; its files appear at their own
/// paths. Every other archive behaves like a folder named after itself, wherever it sits:
/// `image.pfs` holds `image/bar.png`, `chara/face.pfs` holds `chara/face/large/a.png`.
/// Each archive can be patched by `name.pfs.000` … `.999`, later numbers overriding
/// earlier ones. Paths are matched case-insensitively, as on Windows.
///
/// Lookup order: `patch/`, loose files, the root archive, then the folder archives.
public final class ArtemisFileSystem: @unchecked Sendable {
    public enum Source: Hashable, Sendable {
        case archive(URL)
        case loose(URL)
        case patch(URL)
    }

    public struct File: Hashable, Sendable {
        /// Path as the game spells it, `/` separated.
        public let path: String
        public let size: UInt64
        public let source: Source
        let entry: PFSArchive.Entry?
    }

    public let gameRoot: URL
    /// Archives in load order: folder archives, then the root archive (each set's base
    /// followed by its numbered patches, later ones overriding earlier ones).
    public let archives: [PFSArchive]
    /// Every visible file, keyed by lowercased path; overridden copies are dropped.
    public let files: [String: File]
    /// The game's text encoding: Shift-JIS (CP932) unless `system.ini` says
    /// `CHARSET = UTF-8`, as newer games do.
    public private(set) var encoding = artemisScriptEncoding

    public init(gameRoot: URL, patchRoot: URL? = nil) throws {
        self.gameRoot = gameRoot
        let sets = try Self.archiveSets(in: gameRoot, patchRoot: patchRoot)
        var archives: [PFSArchive] = []
        var files: [String: File] = [:]
        // Lowest precedence first; later assignments win.
        for set in sets.sorted(by: { !$0.isRoot && $1.isRoot }) {
            for url in set.urls {
                let archive = try PFSArchive(url: url)
                archives.append(archive)
                for entry in archive.entries {
                    let path = set.mount.isEmpty ? entry.path : set.mount + "/" + entry.path
                    files[path.lowercased()] = File(path: path, size: entry.size, source: .archive(archive.url), entry: entry)
                }
            }
        }
        for (relative, url, size) in Self.looseFiles(in: gameRoot, skipping: { $0.contains(".pfs") }) {
            files[relative.lowercased()] = File(path: relative, size: size, source: .loose(url), entry: nil)
        }
        if let patchRoot {
            for (relative, url, size) in Self.looseFiles(in: patchRoot, skipping: { $0.contains(".pfs") }) {
                files[relative.lowercased()] = File(path: relative, size: size, source: .patch(url), entry: nil)
            }
        }
        self.archives = archives
        self.files = files
        if let ini = try? data("system.ini"),
           String(decoding: ini, as: UTF8.self).range(of: #"(?im)^\s*CHARSET\s*=\s*UTF-?8"#, options: .regularExpression) != nil {
            encoding = .utf8
        }
    }

    public func file(_ path: String) -> File? {
        files[resolveMagic(path).replacingOccurrences(of: "\\", with: "/").lowercased()]
    }

    /// `e:setMagicPath{"bg", "background"}`: `:bg/x` reads `background/x`.
    private var magicPaths: [String: String] = [:]
    private let magicLock = NSLock()

    public func setMagicPath(_ word: String, to path: String) {
        magicLock.lock()
        defer { magicLock.unlock() }
        magicPaths[word] = path.isEmpty ? nil : path
    }

    func resolveMagic(_ path: String) -> String {
        guard path.hasPrefix(":") else { return path }
        let body = path.dropFirst()
        let end = body.firstIndex(where: { $0 == "/" || $0 == "\\" }) ?? body.endIndex
        magicLock.lock()
        let target = magicPaths[String(body[..<end])]
        magicLock.unlock()
        guard let target else { return path }
        return target + body[end...]
    }

    /// The file on disk, for loose and patch files (archived ones have none).
    public func url(_ path: String) -> URL? {
        switch file(path)?.source {
        case let .loose(url), let .patch(url): return url
        default: return nil
        }
    }

    public func data(_ path: String) throws -> Data? {
        guard let file = file(path) else { return nil }
        return try data(of: file)
    }

    public func data(of file: File) throws -> Data {
        switch file.source {
        case let .loose(url), let .patch(url):
            return try Data(contentsOf: url)
        case let .archive(url):
            guard let archive = archives.first(where: { $0.url == url }), let entry = file.entry else {
                throw CocoaError(.fileNoSuchFile)
            }
            return try archive.data(for: entry)
        }
    }

    struct ArchiveSet {
        /// Folder the archive stands in for (`image`, `chara/face`); empty for the root.
        var mount: String
        var isRoot: Bool
        /// The base archive followed by its numbered patches, in order.
        var urls: [URL]
    }

    /// Every `.pfs` set under the game folder, grouped with its numbered patches. Archives in
    /// the patch folder join the set at the same path (the NUKITASHI R18 patch's
    /// `NUKITASHI.pfs.010` etc.), and replace a game archive with the same name.
    static func archiveSets(in gameRoot: URL, patchRoot: URL? = nil) throws -> [ArchiveSet] {
        var groups: [String: [(Int, URL)]] = [:]
        var exeNames: Set<String> = []
        for folder in [gameRoot] + (patchRoot.map { [$0] } ?? []) {
            let rootPath = folder.standardizedFileURL.path
            guard let enumerator = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: [.isRegularFileKey]) else { continue }
            for case let url as URL in enumerator {
                let path = url.standardizedFileURL.path
                guard path.hasPrefix(rootPath + "/") else { continue }
                let relative = String(path.dropFirst(rootPath.count + 1))
                let lower = relative.lowercased()
                if !lower.contains("/"), lower.hasSuffix(".exe") { exeNames.insert(String(lower.dropLast(4))) }
                guard let range = lower.range(of: ".pfs", options: .backwards) else { continue }
                let suffix = lower[range.upperBound...]
                let named = String(relative[..<relative.index(relative.startIndex, offsetBy: lower.distance(from: lower.startIndex, to: range.lowerBound))])
                // A patch archive's folder matches the game's whatever its case.
                let mount = groups.keys.first { $0.lowercased() == named.lowercased() } ?? named
                let number: Int
                if suffix.isEmpty { number = -1 } else if suffix.first == ".", let n = Int(suffix.dropFirst()) { number = n } else { continue }
                var group = groups[mount, default: []]
                group.removeAll { $0.0 == number }
                group.append((number, url))
                groups[mount] = group
            }
        }
        // The root archive: the one named after the exe, else root.pfs.
        let topLevel = groups.keys.filter { !$0.contains("/") }
        let root = topLevel.first { exeNames.contains($0.lowercased()) } ?? topLevel.first { $0.lowercased() == "root" }
        return groups.keys.sorted { $0.lowercased() < $1.lowercased() }.map { mount in
            ArchiveSet(mount: mount == root ? "" : mount, isRoot: mount == root,
                       urls: groups[mount]!.sorted { $0.0 < $1.0 }.map(\.1))
        }
    }

    /// `.pfs` files under the game folder, in load order.
    public static func archiveURLs(in gameRoot: URL) throws -> [URL] {
        try archiveSets(in: gameRoot).sorted { !$0.isRoot && $1.isRoot }.flatMap(\.urls)
    }

    private static func looseFiles(in root: URL, skipping skip: (String) -> Bool) -> [(String, URL, UInt64)] {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey]) else { return [] }
        let rootPath = root.standardizedFileURL.path
        var result: [(String, URL, UInt64)] = []
        for case let url as URL in enumerator {
            guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]), values.isRegularFile == true else { continue }
            let path = url.standardizedFileURL.path
            guard path.hasPrefix(rootPath + "/") else { continue }
            let relative = String(path.dropFirst(rootPath.count + 1))
            if skip(relative.lowercased()) || relative.hasPrefix(".") { continue }
            result.append((relative, url, UInt64(values.fileSize ?? 0)))
        }
        return result
    }
}
