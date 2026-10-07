import ArtemisKit
import Foundation

// artemis-cli list <game folder>             every visible file, with its source
// artemis-cli extract <game folder> <out> [prefix...]   writes files (all, or under prefixes)
let arguments = CommandLine.arguments.dropFirst()
guard let command = arguments.first, arguments.count >= 2 else {
    print("usage: artemis-cli list|extract <game folder> [out] [prefix...]")
    exit(2)
}
let game = URL(fileURLWithPath: arguments.dropFirst().first!)
let fs = try ArtemisFileSystem(gameRoot: game)

switch command {
case "list":
    for archive in fs.archives {
        print("# \(archive.url.lastPathComponent) (pf\(archive.version.rawValue), \(archive.entries.count) files)")
    }
    for file in fs.files.values.sorted(by: { $0.path < $1.path }) {
        let source: String
        switch file.source {
        case let .archive(url): source = url.lastPathComponent
        case .loose: source = "loose"
        case .patch: source = "patch"
        }
        print("\(file.size)\t\(source)\t\(file.path)")
    }
case "extract":
    guard arguments.count >= 3 else { print("extract needs an output folder"); exit(2) }
    let out = URL(fileURLWithPath: Array(arguments)[2])
    let prefixes = Array(arguments.dropFirst(3)).map { $0.lowercased() }
    var count = 0
    for file in fs.files.values where prefixes.isEmpty || prefixes.contains(where: { file.path.lowercased().hasPrefix($0) }) {
        let target = out.appendingPathComponent(file.path)
        try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fs.data(of: file).write(to: target)
        count += 1
    }
    print("extracted \(count) files to \(out.path)")
default:
    print("unknown command \(command)")
    exit(2)
}
