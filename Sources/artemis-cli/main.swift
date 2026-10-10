import ArtemisKit
import CoreGraphics
import CoreText
import Foundation
import Metal
import ImageIO

// artemis-cli list <game folder>                     every visible file, with its source
// artemis-cli extract <game folder> <out> [prefix...]  writes files (all, or under prefixes)
// artemis-cli run <game folder> [waits] [steps]      boots the game headless and reports
setvbuf(stdout, nil, _IOLBF, 0)  // Line by line, so a run cut short still shows where it got to.
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
    // ARTEMIS_NO_PATCH=1: the game as Steam delivered it.
    guard ProcessInfo.processInfo.environment["ARTEMIS_NO_PATCH"] == nil else { return nil }
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
case "mjainfo":
    // artemis-cli mjainfo <game> <path>: the structure of an MJA movie (in memory only).
    guard arguments.count >= 3, let data = try fs.data(arguments[2]) else { print("mjainfo needs a path"); exit(2) }
    let bytes = [UInt8](data)
    func u32(_ o: Int) -> Int { Int(bytes[o]) | Int(bytes[o+1]) << 8 | Int(bytes[o+2]) << 16 | Int(bytes[o+3]) << 24 }
    print("size \(bytes.count), magic \(String(bytes: bytes[0..<4], encoding: .ascii) ?? "?"), u32s \((1..<8).map { u32($0 * 4) })")
    var soi: [Int] = []
    var i = 0
    while i + 1 < bytes.count, soi.count < 12 { if bytes[i] == 0xFF, bytes[i+1] == 0xD8, i + 2 < bytes.count, bytes[i+2] == 0xFF { soi.append(i) }; i += 1 }
    print("first JPEG starts: \(soi)")
    for o in soi.prefix(6) where o >= 8 { print("  before \(o): \(bytes[(o-8)..<o].map { String(format: "%02x", $0) }.joined(separator: " "))") }
    if let first = soi.first, let image = CGImageSourceCreateWithData(Data(bytes[first...]) as CFData, nil).flatMap({ CGImageSourceCreateImageAtIndex($0, 0, nil) }) {
        print("first frame \(image.width)x\(image.height) alpha \(image.alphaInfo.rawValue)")
    }
    // Colour (saturation) and brightness of each half of the first frames: grey halves are alpha.
    for (n, o) in soi.prefix(4).enumerated() {
        guard let image = CGImageSourceCreateWithData(Data(bytes[o...]) as CFData, nil).flatMap({ CGImageSourceCreateImageAtIndex($0, 0, nil) }) else { continue }
        let w = image.width, h = image.height
        var px = [UInt8](repeating: 0, count: w * h * 4)
        let ctx = CGContext(data: &px, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4, space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        func stats(_ rows: Range<Int>, _ cols: Range<Int>) -> String {
            var sat = 0.0, lum = 0.0, n = 0.0
            for y in stride(from: rows.lowerBound, to: rows.upperBound, by: 3) { for x in stride(from: cols.lowerBound, to: cols.upperBound, by: 3) {
                let i = (y * w + x) * 4; let r = Double(px[i]), g = Double(px[i+1]), b = Double(px[i+2])
                sat += max(r, g, b) - min(r, g, b); lum += (r + g + b) / 3; n += 1 } }
            return String(format: "sat %.1f lum %.1f", sat / n, lum / n)
        }
        print("frame \(n): top [\(stats(0..<h/2, 0..<w))] bottom [\(stats(h/2..<h, 0..<w))] left [\(stats(0..<h, 0..<w/2))] right [\(stats(0..<h, w/2..<w))]")
    }
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
        if let os2 = CTFontCopyTable(font, CTFontTableTag(kCTFontTableOS2), []) as Data?, os2.count >= 78 {
            func i16(_ o: Int) -> Int { Int(Int16(bitPattern: UInt16(os2[os2.startIndex + o]) << 8 | UInt16(os2[os2.startIndex + o + 1]))) }
            func u16(_ o: Int) -> Int { Int(UInt16(os2[os2.startIndex + o]) << 8 | UInt16(os2[os2.startIndex + o + 1])) }
            print("unitsPerEm \(CTFontGetUnitsPerEm(font)); typo ascender \(i16(68)) descender \(i16(70)) lineGap \(i16(72)); win ascent \(u16(74)) descent \(u16(76))")
        }
        print("CoreText ascent \(CTFontGetAscent(font)) descent \(CTFontGetDescent(font)) leading \(CTFontGetLeading(font)) cap \(CTFontGetCapHeight(font)) at size \(size)")
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
case "shaders":
    // artemis-cli shaders <game>: translates every GLSL shader the game ships to Metal and compiles it.
    let device = MTLCreateSystemDefaultDevice()
    var good = 0, bad = 0
    for file in fs.files.values.sorted(by: { $0.path < $1.path }) where file.path.lowercased().hasSuffix(".glsl") {
        let data = try fs.data(of: file)
        guard let source = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .shiftJIS),
              let program = ArtemisShaderProgram(glsl: source) else {
            print("✗ \(file.path): didn't translate")
            bad += 1
            continue
        }
        do {
            _ = try device?.makeLibrary(source: program.metalSource, options: nil)
            print("✓ \(file.path): \(program.uniforms.map(\.name).joined(separator: ",")) | \(program.textures.joined(separator: ","))")
            good += 1
        } catch {
            print("✗ \(file.path): \(error)")
            bad += 1
        }
    }
    print("\(good) compiled, \(bad) failed")
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
            player.traceWaits = ProcessInfo.processInfo.environment["ARTEMIS_TRACE_WAITS"] != nil
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
                    autoreleasepool { player.update(time: time) }
                case .stop, .click:
                    autoreleasepool { player.update(time: time + 5000) }
                    // ARTEMIS_CHECK80=1: waits where layer 80 is hidden but text would still show.
                    if ProcessInfo.processInfo.environment["ARTEMIS_CHECK80"] != nil, player.stage.layer("80")?.visible == false {
                        let showing = player.messages.layers.filter { !$0.value.layered && $0.value.visible && !$0.value.pageHidden
                            && $0.value.alpha > 0 && !$0.value.text.trimmingCharacters(in: .whitespaces).isEmpty && !$0.key.hasPrefix("basefont") }
                        if !showing.isEmpty { print("check80: \(showing.keys.sorted()) at \(player.interpreter.location) hidden=\(player.hidden)") }
                    }
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
                    // ARTEMIS_TEXTS=1: the text on screen at each tap.
                    if ProcessInfo.processInfo.environment["ARTEMIS_TEXTS"] != nil {
                        for (id, layer) in player.messages.layers where !layer.text.trimmingCharacters(in: .whitespaces).isEmpty
                            && !id.hasPrefix("basefont") { print("  text \(id): \(layer.text.prefix(60))") }
                    }
                    let tappedText = player.wait == .click
                    autoreleasepool { if tap.x < 0 { player.rightClick() } else { player.tap(at: tap) } }
                    // ARTEMIS_SKIP=1: skip mode after each tap on text (it stops at choices; a
                    // tap at a [stop] is a choice or a button, which skip would ignore).
                    if ProcessInfo.processInfo.environment["ARTEMIS_SKIP"] != nil, tappedText { player.setSkipMode(true, force: true) }
                case .video:
                    player.videoFinished()
                case .videoLayer:
                    // Video layers play out on the clock.
                    time += 16
                    autoreleasepool { player.update(time: time) }
                case .dialog, .sound:
                    break loop
                case .none:
                    break loop
                }
                if player.failure != nil { break loop }
            }
            print("stopped: \(player.wait) at \(player.interpreter.location), t=\(Int(time)) ms, script \(player.interpreter.state)")
            if let failure = player.failure { print("FAILED: \(failure)") }
            print("message layer: \(player.messages.current)")
            for layer in player.messages.layers.values where !layer.text.isEmpty {
                print("  ~\(layer.id)\(layer.pageHidden ? " (hidden)" : ""): \(layer.text.prefix(120).replacingOccurrences(of: "\n", with: " / "))")
            }
            func dump(_ layer: ArtemisLayer, _ depth: Int) {
                print(String(repeating: "  ", count: depth) + "\(layer.id) \(layer.file ?? (layer.color.map { String($0, radix: 16) } ?? "-")) \(Int(layer.width))x\(Int(layer.height)) @\(Int(layer.left)),\(Int(layer.top)) a=\(Int(layer.alpha)) s=\(Int(layer.xscale)) v=\(layer.visible) img=\(layer.image != nil)")
                layer.children.forEach { dump($0, depth + 1) }
            }
            player.saveGlobals()  // As the app does when it leaves the game.
            if ProcessInfo.processInfo.environment["ARTEMIS_TREE"] != nil { player.stage.root.children.forEach { dump($0, 0) } }
            // ARTEMIS_HIT=x,y: which layers take a click / rollover there at the end.
            if let hit = ProcessInfo.processInfo.environment["ARTEMIS_HIT"]?.split(separator: ",").compactMap({ Double($0) }), hit.count == 2 {
                let point = CGPoint(x: hit[0], y: hit[1])
                print("hit \(point): click \(player.stage.clickTarget(at: point)?.layer ?? "none"), rollover \(player.stage.eventTarget(at: point, type: "rollover") ?? "none")")
                for (id, events) in player.stage.events where id.hasPrefix("1.80.120") { print("  events \(id): \(events.keys.sorted()) enabled \(events.values.map(\.enabled))") }
            }
            // ARTEMIS_METAL=1: through the Metal renderer the app uses, instead of Core Graphics.
            let metal = ProcessInfo.processInfo.environment["ARTEMIS_METAL"] != nil
            guard let image = metal ? metalSnapshot(player) : player.renderSnapshot() else { print("render failed"); return }
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


/// The current frame through `ArtemisMetalRenderer`, read back.
@MainActor
func metalSnapshot(_ player: ArtemisPlayer) -> CGImage? {
    // ARTEMIS_REVEAL=n: the text as it looks n characters into typing.
    if let count = ProcessInfo.processInfo.environment["ARTEMIS_REVEAL"].flatMap(Double.init) {
        for layer in player.messages.layers.values where !layer.text.isEmpty { layer.revealed = count }
    }
    guard let renderer = ArtemisMetalRenderer(),
          let target = renderer.makeTarget(width: Int(player.stage.width), height: Int(player.stage.height), readable: true),
          let buffer = renderer.queue.makeCommandBuffer() else { return nil }
    renderer.render(stage: player.stage, texts: player.metalTexts(scale: 1), textsVisible: player.messageTextVisible,
                    into: target, commandBuffer: buffer)
    buffer.commit()
    buffer.waitUntilCompleted()
    // ARTEMIS_METAL_BENCH=n: renders the frame n more times at the iPhone Air's drawable size
    // (2240×1260), advancing animations 33 ms each, and reports the time per frame.
    if let runs = ProcessInfo.processInfo.environment["ARTEMIS_METAL_BENCH"].flatMap(Int.init),
       let big = renderer.makeTarget(width: 2240, height: 1260) {
        var cpu = 0.0, gpu = 0.0, step = 0.0, texts = 0.0
        var clock = player.now
        for _ in 0 ..< runs {
            clock += 16.7
            let updateStart = Date()
            player.update(time: clock)
            step += Date().timeIntervalSince(updateStart)
            let textStart = Date()
            _ = player.metalTexts(scale: 1.4)
            texts += Date().timeIntervalSince(textStart)
            let start = Date()
            guard let frame = renderer.queue.makeCommandBuffer() else { break }
            renderer.render(stage: player.stage, texts: player.metalTexts(scale: 1.4), textsVisible: false, into: big, commandBuffer: frame)
            frame.commit()
            cpu += Date().timeIntervalSince(start)
            frame.waitUntilCompleted()
            gpu += frame.gpuEndTime - frame.gpuStartTime
        }
        print(String(format: "metal bench: update %.2f ms, texts %.2f ms, render %.2f ms CPU, %.2f ms GPU per frame, %d groups",
                     step / Double(runs) * 1000, texts / Double(runs) * 1000, cpu / Double(runs) * 1000,
                     gpu / Double(runs) * 1000, renderer.lastGroupCount))
    }
    return ArtemisMetalRenderer.image(from: target)
}
