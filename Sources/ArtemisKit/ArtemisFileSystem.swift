import Foundation

/// The files an Artemis game sees: its `.pfs` archives plus loose files, resolved the way
/// the engine resolves them, with Shiori's patch folder on top.
///
/// Archives come in sets: `root.pfs`, then updates `root.pfs.000`, `root.pfs.001`, ...,
/// each overriding the ones before (newer games split content across several sets, e.g.
/// `system.pfs`, `scenario_en.pfs`, `voice.pfs`). Paths are matched case-insensitively,
/// as on Windows.
///
/// Lookup order: `patch/` loose files, then archives from the last-loaded update back to
/// the first, then loose files beside the archives (where newer games keep `system.ini`,
/// `tag.ini` and `Config.lua`).
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

    /// Archives in load order (later ones override earlier ones).
    public let archives: [PFSArchive]
    /// Every visible file, keyed by lowercased path; overridden copies are dropped.
    public let files: [String: File]

    public init(gameRoot: URL, patchRoot: URL? = nil) throws {
        let archives = try Self.archiveURLs(in: gameRoot).map(PFSArchive.init(url:))
        self.archives = archives

        var files: [String: File] = [:]
        // Lowest precedence first; later assignments win.
        for (relative, url, size) in Self.looseFiles(in: gameRoot, skipping: { $0.contains(".pfs") }) {
            files[relative.lowercased()] = File(path: relative, size: size, source: .loose(url), entry: nil)
        }
        for archive in archives {
            for entry in archive.entries {
                files[entry.path.lowercased()] = File(path: entry.path, size: entry.size, source: .archive(archive.url), entry: entry)
            }
        }
        if let patchRoot {
            for (relative, url, size) in Self.looseFiles(in: patchRoot, skipping: { _ in false }) {
                files[relative.lowercased()] = File(path: relative, size: size, source: .patch(url), entry: nil)
            }
        }
        self.files = files
    }

    public func file(_ path: String) -> File? {
        files[path.replacingOccurrences(of: "\\", with: "/").lowercased()]
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

    /// `.pfs` files in the game folder, in the order Artemis loads them: each set's base
    /// archive followed by its numbered updates. Sets are ordered by name, with `root` first.
    public static func archiveURLs(in gameRoot: URL) throws -> [URL] {
        let names = try FileManager.default.contentsOfDirectory(atPath: gameRoot.path)
        var sets: [String: [(Int, String)]] = [:]
        for name in names {
            let lower = name.lowercased()
            guard let range = lower.range(of: ".pfs") else { continue }
            let base = String(lower[..<range.lowerBound])
            let suffix = lower[range.upperBound...]
            if suffix.isEmpty {
                sets[base, default: []].append((-1, name))
            } else if suffix.first == ".", let number = Int(suffix.dropFirst()) {
                sets[base, default: []].append((number, name))
            }
        }
        let order = sets.keys.sorted { a, b in
            if a == "root" || b == "root" { return a == "root" && b != "root" }
            return a < b
        }
        return order.flatMap { base in
            sets[base]!.sorted { $0.0 < $1.0 }.map { gameRoot.appendingPathComponent($0.1) }
        }
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
