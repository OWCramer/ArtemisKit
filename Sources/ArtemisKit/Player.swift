import CoreGraphics
import Foundation

/// Sound and video for the player (the iOS app plugs AVFoundation in; headless runs don't).
@MainActor
public protocol ArtemisMediaDelegate: AnyObject {
    /// `splay`/`sstop`/`sfade`/`seplay`/`sestop`/`sefade`/`voice`, as tags.
    func soundTag(_ tag: ArtemisTag, data: (String) -> Data?)
    /// Plays a movie; call `finished` when it ends or is skipped.
    func playVideo(_ data: Data, fileExtension: String, finished: @escaping () -> Void) -> Bool
}

/// Runs an Artemis game: the interpreter plus the stage, waits, input and media.
/// Drive it with `update(time:)` every frame and `tap(at:)` on touches.
@MainActor
public final class ArtemisPlayer: ArtemisHost {
    public enum Wait: Equatable {
        case none
        /// Until `until` ms; a tap ends it early when `skippable`.
        case time(until: Double, skippable: Bool)
        /// Until a layer event fires.
        case stop
        /// Until a tap (end of a page of text).
        case click
        /// Until the movie ends or is skipped.
        case video
    }

    public let interpreter: ArtemisInterpreter
    public let stage: ArtemisStage
    public let fileSystem: ArtemisFileSystem
    public weak var media: ArtemisMediaDelegate?
    public private(set) var wait: Wait = .none
    public private(set) var now: Double = 0
    public private(set) var log: [String] = []
    public var onLog: ((String) -> Void)?
    public let messages = ArtemisMessages()
    public private(set) lazy var textRenderer = ArtemisTextRenderer { [fileSystem] path in try? fileSystem.data(path) }
    /// Text of the current message layer (for logs).
    public var messageText: String { messages.currentLayer.text }
    /// Prose left over after an `@` click wait, shown when the reader taps.
    private var pendingText: String?
    public private(set) var failure: String?

    public init(gameRoot: URL, patchRoot: URL? = nil) throws {
        let fs = try ArtemisFileSystem(gameRoot: gameRoot, patchRoot: patchRoot)
        fileSystem = fs
        let (width, height) = Self.stageSize(fs)
        stage = ArtemisStage(width: Double(width), height: Double(height)) { file in
            for candidate in [file, file + ".png", file + ".jpg", file + ".bmp", file + ".jpeg"] {
                if let data = try? fs.data(candidate), let image = decodeImage(data) { return image }
            }
            return nil
        }
        interpreter = ArtemisInterpreter(fileSystem: fs, stageWidth: width, stageHeight: height)
        interpreter.host = self
    }

    /// Boots the game's BOOT script and runs to the first wait.
    public func start() throws {
        try interpreter.boot(Self.bootScript(fileSystem))
        runInterpreter()
    }

    // MARK: Driving

    /// Advances the clock (ms): tweens move, timed waits end, the script continues.
    public func update(time: Double) {
        now = time
        stage.update(time: time)
        if case let .time(until, _) = wait, time >= until {
            wait = .none
            runInterpreter()
        }
    }

    /// A tap at a stage point.
    public func tap(at point: CGPoint) {
        switch wait {
        case let .time(_, skippable):
            guard skippable else { return }
            finishTweensNow()
            wait = .none
            runInterpreter()
        case .click:
            wait = .none
            if let rest = pendingText {
                pendingText = nil
                if case .wait = show(text: rest, interpreter: interpreter) { return }
            }
            runInterpreter()
        case .stop:
            guard let (_, event) = stage.clickTarget(at: point) else { return }
            wait = .none
            do {
                try interpreter.fireEvent(event.attributes)
            } catch {
                record("event failed: \(error)")
            }
            runInterpreter()
        case .video, .none:
            break
        }
    }

    public func videoFinished() {
        guard wait == .video else { return }
        wait = .none
        runInterpreter()
    }

    private func finishTweensNow() {
        stage.update(time: now + 1_000_000)
    }

    private func runInterpreter() {
        let state = interpreter.run(maxSteps: 5_000_000)
        switch state {
        case let .failed(message):
            failure = message
            record("FAILED: \(message)")
        case .finished:
            record("script finished")
        case .running:
            record("step budget exhausted at \(interpreter.location)")
        case .waiting:
            break
        }
    }

    private func record(_ message: String) {
        log.append(message)
        onLog?(message)
    }

    // MARK: ArtemisHost

    public func log(_ message: String) {
        record(message)
    }

    public func show(text: String, interpreter: ArtemisInterpreter) -> ArtemisTagOutcome {
        // `@` in prose waits for a click.
        if let at = text.firstIndex(of: "@") {
            messages.append(String(text[..<at]))
            let rest = String(text[text.index(after: at)...])
            pendingText = rest.isEmpty ? nil : rest
            wait = .click
            return .wait("click")
        }
        messages.append(text)
        return .done
    }

    /// The stage with message text on top (headless snapshots).
    public func renderSnapshot(scale: Double = 1) -> CGImage? {
        guard let base = stage.render(scale: scale) else { return nil }
        let w = base.width, h = base.height
        guard let context = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return base }
        context.draw(base, in: CGRect(x: 0, y: 0, width: w, height: h))
        context.translateBy(x: 0, y: CGFloat(h))
        context.scaleBy(x: scale, y: -scale)
        for layer in messages.layers.values.sorted(by: { $0.id < $1.id }) { textRenderer.draw(layer, in: context) }
        return context.makeImage()
    }

    public func perform(_ tag: ArtemisTag, interpreter: ArtemisInterpreter) -> ArtemisTagOutcome {
        switch tag.name {
        case "lyc":
            stage.create(tag)
        case "lyprop":
            stage.setProperties(tag)
        case "lydel":
            stage.deleteLayer(tag["id"] ?? "")
        case "lytween":
            let end = stage.tween(tag, now: now)
            if tag["sync"] == "1", end.isFinite { return waitTime(until: end, skippable: tag["input"] != "0") }
        case "lytweendel":
            stage.deleteTweens(tag)
        case "lyevent":
            stage.event(tag)
        case "lyevent_enable":
            stage.event(tag, enable: true)
        case "lyevent_disable":
            stage.event(tag, enable: false)
        case "flip":
            stage.present(transition: nil)
        case "trans":
            stage.present(transition: tag)
            let time = tag.number("time")
            if time > 0 { return waitTime(until: now + time, skippable: tag["input"] != "0") }
        case "wait":
            if tag["se"] != nil || tag["voice"] != nil { return .done } // sound-completion waits: not yet
            let time = tag.number("time")
            if time > 0 { return waitTime(until: now + time, skippable: tag["input"] != "0") }
        case "stop":
            wait = .stop
            return .wait("stop")
        case "rp":
            messages.clear()
        case "rt":
            messages.append("\n")
        case "chgmsg":
            messages.change(to: tag["id"])
        case "/chgmsg":
            messages.change(to: nil)
        case "font":
            messages.setFont(tag)
        case "fontdefault":
            messages.setFont(tag, defaults: true)
        case "print":
            messages.append(tag["data"] ?? "")
        case "video":
            guard let file = tag["file"], let data = try? fileSystem.data(file) else { return .done }
            if let media, media.playVideo(data, fileExtension: (file as NSString).pathExtension, finished: { [weak self] in
                self?.videoFinished()
            }) {
                wait = .video
                return .wait("video")
            }
        case "splay", "sstop", "sfade", "seplay", "sestop", "sefade", "voice", "vstop":
            media?.soundTag(tag) { [fileSystem] path in try? fileSystem.data(path) }
        case "system:get_layer_info":
            let name = tag["name"] ?? "li"
            for (key, value) in stage.layerInfo(style: tag["style"]) { interpreter.variables["\(name).\(key)"] = value }
        case "system:get_sound_info", "system:get_message_size", "system:get_backlog_size", "system:get_message_tags":
            interpreter.variables[tag["name"] ?? ""] = "0"
        default:
            // Closing tags of block-style tags ([/font], [/voice], [/chgmsg]) end nothing here.
            if tag.name.hasPrefix("/") { return .done }
            return Self.acceptedSilently.contains(tag.name) ? .done : .unhandled
        }
        return .done
    }

    private func waitTime(until: Double, skippable: Bool) -> ArtemisTagOutcome {
        wait = .time(until: until, skippable: skippable)
        return .wait("time")
    }

    /// Tags that change nothing visible yet (input setup, backlog, fonts, ...).
    static let acceptedSilently: Set<String> = [
        "caption", "ruby", "indent", "glyph", "rclick", "hide", "skip",
        "backlog", "autosave", "automode", "writebacklog", "delonpush", "setonpush", "delonclick", "setonclick",
        "setonrollover", "setondrag", "setondragout", "link", "linkenable", "linkdisable", "keyconfig", "mouse",
        "anime", "backloglayer", "takess", "savess", "scetween", "scein", "sceout", "tweenset", "alreadyread", "reset",
        "setonautomodein", "setonautomodeout", "setoncontrolskipin", "setoncontrolskipout", "setonsoundfinish",
        "delonsoundfinish", "dialog", "openbrowser", "save", "load", "file", "btn_off", "info_hide_on", "info_hide_off",
        "lyevent_delete", "lydrag", "lyedit", "gesture_enable", "gesture_disable", "key_enable", "key_disable",
        "exec", "tag", "prohibit",
    ]

    // MARK: Config

    static func stageSize(_ fs: ArtemisFileSystem) -> (Int, Int) {
        let ini = iniValues(fs)
        let width = Int(ini["[IOS]WIDTH"] ?? ini["[WINDOWS]WIDTH"] ?? "") ?? 1280
        let height = Int(ini["[IOS]HEIGHT"] ?? ini["[WINDOWS]HEIGHT"] ?? "") ?? 720
        return (width, height)
    }

    static func bootScript(_ fs: ArtemisFileSystem) -> String {
        let ini = iniValues(fs)
        return ini["[IOS]BOOT"] ?? ini["[WINDOWS]BOOT"] ?? "system/first.iet"
    }

    /// system.ini as "[SECTION]KEY" -> value.
    static func iniValues(_ fs: ArtemisFileSystem) -> [String: String] {
        guard let data = try? fs.data("system.ini") else { return [:] }
        var section = ""
        var values: [String: String] = [:]
        for raw in decodeScriptText(data).split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix(";") { continue }
            if line.hasPrefix("[") { section = line.uppercased(); continue }
            guard let eq = line.firstIndex(of: "=") else { continue }
            let key = line[..<eq].trimmingCharacters(in: .whitespaces).uppercased()
            values[section + key] = line[line.index(after: eq)...].trimmingCharacters(in: .whitespaces)
        }
        return values
    }
}
