import ArtemisKit
import CoreGraphics
import CoreText
import Foundation
import ImageIO

// artemis-cli list <game folder>                     every visible file, with its source
// artemis-cli extract <game folder> <out> [prefix...]  writes files (all, or under prefixes)
// artemis-cli run <game folder> [waits] [steps]      boots the game headless and reports
let arguments = Array(CommandLine.arguments.dropFirst())
guard arguments.count >= 2 else {
    print("usage: artemis-cli list|extract|run <game folder> ...")
    exit(2)
}
let command = arguments[0]
let game = URL(fileURLWithPath: arguments[1])
// A Shiori game folder's `base/` has its `patch/` beside it.
let patch: URL? = {
    let sibling = game.deletingLastPathComponent().appendingPathComponent("patch", isDirectory: true)
    return game.lastPathComponent == "base" && FileManager.default.fileExists(atPath: sibling.path) ? sibling : nil
}()
let fs = try ArtemisFileSystem(gameRoot: game, patchRoot: patch)

/// Presents nothing; logs what it's asked to do and resolves waits immediately.
@MainActor
final class HeadlessHost: ArtemisHost {
    static let presentational: Set<String> = [
        "lyc", "lyprop", "lydel", "lytween", "lytweendel", "lyevent", "lydrag", "lyedit", "trans", "flip",
        "font", "fontdefault", "chgmsg", "rp", "rt", "print", "caption", "ruby", "indent", "glyph",
        "rclick", "hide", "skip", "backlog", "autosave", "automode", "writebacklog", "delonpush", "setonpush",
        "delonclick", "setonclick", "setonrollover", "setondrag", "setondragout", "link", "linkenable",
        "linkdisable", "keyconfig", "mouse", "splay", "sstop", "sfade", "seplay", "sestop", "sefade", "voice",
        "video", "anime", "backloglayer", "takess", "savess", "scetween", "scein", "sceout", "tweenset",
        "alreadyread", "reset", "setonautomodein", "setonautomodeout", "setoncontrolskipin",
        "setoncontrolskipout", "setonsoundfinish", "delonsoundfinish", "dialog", "openbrowser", "save",
        "load", "file", "tag", "btn_off", "info_hide_on", "info_hide_off",
    ]

    var counts: [String: Int] = [:]
    var unhandled: [String] = []
    var texts: [String] = []
    var logLines: [String] = []

    func perform(_ tag: ArtemisTag, interpreter: ArtemisInterpreter) -> ArtemisTagOutcome {
        counts[tag.name, default: 0] += 1
        switch tag.name {
        case "wait":
            return .wait("wait \(tag["time"] ?? "")")
        case "stop":
            return .wait("stop")
        default:
            return Self.presentational.contains(tag.name) ? .done : .unhandled
        }
    }

    func show(text: String, interpreter: ArtemisInterpreter) -> ArtemisTagOutcome {
        texts.append(text)
        return .done
    }

    func log(_ message: String) {
        logLines.append(message)
        if !message.hasPrefix("debug:") && !message.hasPrefix("lua:") { print("· \(message)") }
    }
}

/// The BOOT script from system.ini ([IOS], else [WINDOWS]), defaulting to system/first.iet.
func bootScript() -> String {
    guard let data = try? fs.data("system.ini") else { return "system/first.iet" }
    var section = ""
    var boots: [String: String] = [:]
    for raw in decodeScriptText(data).split(whereSeparator: \.isNewline) {
        let line = raw.trimmingCharacters(in: .whitespaces)
        if line.hasPrefix("[") { section = line; continue }
        if line.uppercased().hasPrefix("BOOT"), let eq = line.firstIndex(of: "=") {
            boots[section] = line[line.index(after: eq)...].trimmingCharacters(in: .whitespaces)
        }
    }
    return boots["[IOS]"] ?? boots["[WINDOWS]"] ?? "system/first.iet"
}

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
case "cat":
    // artemis-cli cat <game> <path>: one file's text, printed (read in memory; nothing is written).
    guard arguments.count >= 3 else { print("cat needs a path"); exit(2) }
    guard let data = try fs.data(arguments[2]) else { print("no \(arguments[2])"); exit(1) }
    print(decodeScriptText(data))
case "hex":
    // artemis-cli hex <game> <path> [bytes]: the start of one file in hex (in memory only).
    guard arguments.count >= 3, let data = try fs.data(arguments[2]) else { print("hex needs a path"); exit(2) }
    let count = arguments.count > 3 ? Int(arguments[3]) ?? 512 : 512
    let bytes = [UInt8](data.prefix(count))
    print("\(data.count) bytes")
    for row in stride(from: 0, to: bytes.count, by: 16) {
        let slice = bytes[row..<min(row + 16, bytes.count)]
        let hex = slice.map { String(format: "%02x", $0) }.joined(separator: " ")
        let text = String(slice.map { $0 >= 32 && $0 < 127 ? Character(UnicodeScalar($0)) : "." })
        print(String(format: "%06x  ", row) + hex.padding(toLength: 48, withPad: " ", startingAt: 0) + "  " + text)
    }
case "font":
    // artemis-cli font <game> <path> [text] [size]: whether CoreText can use a font file, and how
    // wide it sets the text (in memory only).
    guard arguments.count >= 3, let data = try fs.data(arguments[2]) else { print("font needs a path"); exit(2) }
    if let descriptor = CTFontManagerCreateFontDescriptorFromData(data as CFData) {
        let sample = arguments.count > 3 ? arguments[3] : "Who should"
        let size = arguments.count > 4 ? Double(arguments[4]) ?? 30 : 30
        let font = CTFontCreateWithFontDescriptor(descriptor, size, nil)
        let glyphs = Array(sample.utf16)
        var ids = [CGGlyph](repeating: 0, count: glyphs.count)
        CTFontGetGlyphsForCharacters(font, glyphs, &ids, glyphs.count)
        var advances = [CGSize](repeating: .zero, count: glyphs.count)
        let width = CTFontGetAdvancesForGlyphs(font, .horizontal, ids, &advances, ids.count)
        print("\(CTFontCopyPostScriptName(font)) (\(data.count) bytes): \"\(sample)\" (\(glyphs.count) characters) at \(size) px is \(width) px")
        print("CoreText ascent \(CTFontGetAscent(font)) descent \(CTFontGetDescent(font)) leading \(CTFontGetLeading(font)) unitsPerEm \(CTFontGetUnitsPerEm(font))")
        if let os2 = CTFontCopyTable(font, CTFontTableTag(kCTFontTableOS2), []) as Data?, os2.count >= 78 {
            func int16(_ offset: Int) -> Int { Int(Int16(bitPattern: UInt16(os2[os2.startIndex + offset]) << 8 | UInt16(os2[os2.startIndex + offset + 1]))) }
            print("fsSelection \(String(int16(62), radix: 2)) OS/2 typo ascender \(int16(68)) descender \(int16(70)) lineGap \(int16(72)), win ascent \(UInt16(bitPattern: Int16(int16(74)))) descent \(UInt16(bitPattern: Int16(int16(76))))")
        }
    } else {
        print("CoreText can't read \(arguments[2]) (\(data.count) bytes)")
    }
case "commands":
    // artemis-cli commands <game> <script> [count]: a script as parsed (.iet, .txt or .asb).
    guard arguments.count >= 3, let data = try fs.data(arguments[2]) else { print("commands needs a script"); exit(2) }
    let script = ArtemisScript(path: arguments[2], data: data, encoding: fs.encoding)
    print("\(script.commands.count) commands, \(script.labels.count) labels")
    for command in script.commands.prefix(arguments.count > 3 ? Int(arguments[3]) ?? 40 : 40) {
        print(command.line, command.kind)
    }
case "extract":
    guard arguments.count >= 3 else { print("extract needs an output folder"); exit(2) }
    let out = URL(fileURLWithPath: arguments[2])
    let prefixes = arguments.dropFirst(3).map { $0.lowercased() }
    var count = 0
    for file in fs.files.values where prefixes.isEmpty || prefixes.contains(where: { file.path.lowercased().hasPrefix($0) }) {
        let target = out.appendingPathComponent(file.path)
        try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fs.data(of: file).write(to: target)
        count += 1
    }
    print("extracted \(count) files to \(out.path)")
case "run":
    let maxWaits = arguments.count > 2 ? Int(arguments[2]) ?? 50 : 50
    let maxSteps = arguments.count > 3 ? Int(arguments[3]) ?? 2_000_000 : 2_000_000
    MainActor.assumeIsolated {
        let host = HeadlessHost()
        let interpreter = ArtemisInterpreter(fileSystem: fs, stageWidth: 1280, stageHeight: 720)
        interpreter.host = host
        let boot = bootScript()
        print("boot \(boot)")
        do { try interpreter.boot(boot) } catch { print("boot failed: \(error)"); return }
        var waits = 0
        loop: while true {
            let state = interpreter.run(maxSteps: maxSteps)
            switch state {
            case let .waiting(reason):
                waits += 1
                if waits <= 40 || waits % 50 == 0 { print("wait #\(waits) \(reason) at \(interpreter.location)") }
                if waits >= maxWaits { break loop }
            case .finished:
                print("finished")
                break loop
            case let .failed(message):
                print("FAILED: \(message)")
                break loop
            case .running:
                print("step budget used up at \(interpreter.location)")
                break loop
            }
        }
        print("steps: \(interpreter.steps), variables: \(interpreter.variables.count), macros: \(interpreter.macros.count)")
        print("text lines shown: \(host.texts.count)")
        for text in host.texts.prefix(8) { print("  » \(text)") }
        let top = host.counts.sorted { $0.value > $1.value }.prefix(25).map { "\($0.key)×\($0.value)" }
        print("host tags: \(top.joined(separator: " "))")
    }
case "video":
    // artemis-cli video <file> [seconds]: decodes a movie on a simulated clock and times it.
    let url = URL(fileURLWithPath: arguments[1])
    let seconds = arguments.count > 2 ? Double(arguments[2]) ?? 10 : 10
    guard let video = ArtemisVideo(url: url) else { print("can't decode \(url.lastPathComponent)"); exit(1) }
    let start = Date()
    var frames = 0, audioSamples = 0
    var t = 0.0
    while t < seconds * 1000, !video.isFinished {
        if video.update(time: t) { frames += 1 }
        audioSamples += video.audio(upTo: t / 1000 + 0.5).count / 2
        t += 1000 / video.frameRate
    }
    let elapsed = Date().timeIntervalSince(start)
    print("\(video.width)x\(video.height) @ \(String(format: "%.2f", video.frameRate)) fps: \(frames) frames in \(String(format: "%.2f", elapsed)) s (\(String(format: "%.1f", elapsed / Double(max(1, frames)) * 1000)) ms/frame), \(audioSamples) audio frames at \(video.audioSampleRate) Hz")
    if let image = video.image, arguments.count > 3 {
        let destination = CGImageDestinationCreateWithURL(URL(fileURLWithPath: arguments[3]) as CFURL, "public.png" as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, image, nil)
        CGImageDestinationFinalize(destination)
    }
    exit(0)
case "decode":
    // artemis-cli decode <game> <path>: decodes an Ogg Vorbis file from the game.
    guard arguments.count >= 3, let data = try fs.data(arguments[2]) else { print("no such file"); exit(1) }
    let start = Date()
    if let pcm = decodeOggVorbis(data) {
        print("\(arguments[2]): \(pcm.channels) ch, \(pcm.sampleRate) Hz, \(pcm.frameCount) frames (\(String(format: "%.1f", Double(pcm.frameCount) / Double(pcm.sampleRate))) s), decoded in \(String(format: "%.2f", Date().timeIntervalSince(start))) s")
    } else {
        print("not Ogg Vorbis")
    }
case "snapshot":
    // artemis-cli snapshot <game> <out.png> [x,y ...]: runs on a simulated clock; each
    // [stop] takes the next tap (stage pixels); renders the stage when taps run out.
    guard arguments.count >= 3 else { print("snapshot needs an output path"); exit(2) }
    let output = URL(fileURLWithPath: arguments[2])
    // "x,y" taps; "R" is a right-click.
    var taps = arguments.dropFirst(3).compactMap { pair -> CGPoint? in
        if pair == "R" { return CGPoint(x: -1, y: -1) }
        let parts = pair.split(separator: ",").compactMap { Double($0) }
        return parts.count == 2 ? CGPoint(x: parts[0], y: parts[1]) : nil
    }
    MainActor.assumeIsolated {
        do {
            let player = try ArtemisPlayer(gameRoot: game, patchRoot: patch)
            if let saves = ProcessInfo.processInfo.environment["ARTEMIS_SAVES"] { player.savePath = URL(fileURLWithPath: saves) }
            player.onLog = { message in
                if ProcessInfo.processInfo.environment["ARTEMIS_LUALOG"] != nil || (!message.hasPrefix("debug:") && !message.hasPrefix("lua:")) { print("· \(message)") }
            }
            try player.start()
            var time = 0.0
            var guardCount = 0
            // ARTEMIS_UNTIL=<ms>: stop the clock there (to look at the middle of a video).
            let until = ProcessInfo.processInfo.environment["ARTEMIS_UNTIL"].flatMap(Double.init) ?? .infinity
            loop: while guardCount < 2_000_000 {
                guardCount += 1
                if time >= until { break loop }
                switch player.wait {
                case let .time(end, _):
                    time = min(max(time + 16, end), until)
                    player.update(time: time)
                case .stop, .click:
                    player.update(time: time + 5000)
                    time += 5000
                    // The update may have moved on by itself (skip, auto, timers).
                    if player.wait != .stop, player.wait != .click { continue }
                    // In skip mode taps answer [stop]s (choices, menus); clicks are skipped.
                    if player.wait == .click, ProcessInfo.processInfo.environment["ARTEMIS_SKIP"] != nil {
                        if ProcessInfo.processInfo.environment["ARTEMIS_SKIP_TRACE"] != nil { print("skip re-enabled at \(player.interpreter.location)") }
                        player.setSkipMode(true, force: true)
                        continue
                    }
                    guard !taps.isEmpty else { break loop }
                    let tap = taps.removeFirst()
                    print("tap \(tap) at \(player.interpreter.location) (\(player.wait))")
                    if tap.x < 0 { player.rightClick() } else { player.tap(at: tap) }
                    // ARTEMIS_SKIP=1: skip mode after each tap (it stops at choices).
                    if ProcessInfo.processInfo.environment["ARTEMIS_SKIP"] != nil { player.setSkipMode(true, force: true) }
                case .video:
                    player.videoFinished()
                case .videoLayer:
                    // Video layers play out on the clock.
                    time += 16
                    player.update(time: time)
                case .dialog, .sound:
                    break loop
                case .none:
                    break loop
                }
                if player.failure != nil { break loop }
            }
            print("stopped: \(player.wait) at \(player.interpreter.location), t=\(Int(time)) ms")
            if let failure = player.failure { print("FAILED: \(failure)") }
            print("message layer: \(player.messages.current)")
            for layer in player.messages.layers.values where !layer.text.isEmpty {
                print("  ~\(layer.id)\(layer.pageHidden ? " (hidden)" : ""): \(layer.text.prefix(120).replacingOccurrences(of: "\n", with: " / "))")
            }
            func dump(_ layer: ArtemisLayer, _ depth: Int) {
                print(String(repeating: "  ", count: depth) + "\(layer.id) \(layer.file ?? (layer.color.map { String($0, radix: 16) } ?? "-")) \(Int(layer.width))x\(Int(layer.height)) @\(Int(layer.left)),\(Int(layer.top)) a=\(Int(layer.alpha)) s=\(Int(layer.xscale)) v=\(layer.visible) img=\(layer.image != nil)")
                layer.children.forEach { dump($0, depth + 1) }
            }
            if ProcessInfo.processInfo.environment["ARTEMIS_TREE"] != nil { player.stage.root.children.forEach { dump($0, 0) } }
            guard let image = player.renderSnapshot() else { print("render failed"); return }
            let destination = CGImageDestinationCreateWithURL(output as CFURL, "public.png" as CFString, 1, nil)!
            CGImageDestinationAddImage(destination, image, nil)
            CGImageDestinationFinalize(destination)
            print("wrote \(output.path)")
        } catch {
            print("failed: \(error)")
        }
    }
default:
    print("unknown command \(command)")
    exit(2)
}
