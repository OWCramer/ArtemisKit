import CoreGraphics
import Foundation
import ImageIO

/// Sound and video for the player (the iOS app plugs AVFoundation in; headless runs don't).
@MainActor
public protocol ArtemisMediaDelegate: AnyObject {
    /// `splay`/`sstop`/`sfade`/`seplay`/`sestop`/`sefade`/`voice`, as tags.
    func soundTag(_ tag: ArtemisTag, data: (String) -> Data?)
    /// Shows an OS dialog (`[dialog]`): OK only, or OK/Cancel when `cancellable`, with an
    /// optional text field. Call `answer(ok, text)` when the reader responds.
    func presentDialog(title: String, message: String, cancellable: Bool, textField: Bool,
                       answer: @escaping (Bool, String?) -> Void)
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
        /// Until the reader answers an OS dialog.
        case dialog
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
    /// Waits interrupted by buttons or the right-click menu, restored when they return.
    private var savedWaits: [Wait] = [] {
        didSet {
            // The reading position an interrupt (menu, button) left from is what [save] keeps.
            if oldValue.isEmpty, !savedWaits.isEmpty { checkpoint = captureState(wait: savedWaits[0]) }
            if savedWaits.isEmpty { checkpoint = nil }
        }
    }
    private var checkpoint: ArtemisSaveState?
    private var screenshot: CGImage?
    private var music: [String: String]?
    public var traceMessages = ProcessInfo.processInfo.environment["ARTEMIS_TRACE_MSG"] != nil
    public private(set) var rightClickAllowed = true
    /// `[setonpush key=...]` handlers by key id (2 = right button, 27 = Esc, ...).
    private var keyHandlers: [String: [String: String]] = [:]
    private var rightClickFile = "rclick.iet"
    public private(set) var failure: String?

    public init(gameRoot: URL, patchRoot: URL? = nil) throws {
        let fs = try ArtemisFileSystem(gameRoot: gameRoot, patchRoot: patchRoot)
        fileSystem = fs
        let (width, height) = Self.stageSize(fs)
        stage = ArtemisStage(width: Double(width), height: Double(height)) { file in
            for candidate in [file, file + ".png", file + ".jpg", file + ".bmp", file + ".jpeg"] {
                if let data = try? fs.data(candidate), let image = decodeImage(data) { return image }
                // Save thumbnails live on disk, by absolute path.
                if candidate.hasPrefix("/"), let data = FileManager.default.contents(atPath: candidate),
                   let image = decodeImage(data) { return image }
            }
            return nil
        }
        interpreter = ArtemisInterpreter(fileSystem: fs, stageWidth: width, stageHeight: height)
        interpreter.host = self
        interpreter.systemVariable = { [weak self] name in self?.systemVariable(name) }
    }

    /// Where `[save]` files go (the game's saves folder in Shiori).
    public var savePath: URL?
    public private(set) var autoMode = false
    public private(set) var skipMode = false

    /// The engine's read-only system variables (Artemis spec, system_variables.txt).
    private func systemVariable(_ name: String) -> String? {
        switch name {
        case "s.current_message_layer": return messages.current
        case "s.status.automode": return autoMode ? "1" : "0"
        case "s.status.commandskip", "s.status.controlskip": return skipMode ? "1" : "0"
        case "s.status.alreadyread", "s.status.avoid": return "0"
        case "s.status.screendirection", "s.status.screendirectionprevious": return "1"
        case "s.status.statusbar": return "0"
        case "s.savepath": return savePath?.path ?? "savedata"
        case "s.datapath": return fileSystem.gameRoot.path
        case "s.engineversion": return "2200"
        case "s.iphonelanguage": return Locale.current.language.languageCode?.identifier ?? "en"
        case "s.iphonemodel": return "iPhone"
        case "s.iphoneversion": return ProcessInfo.processInfo.operatingSystemVersionString
        default: return nil
        }
    }

    /// Boots the game's BOOT script and runs to the first wait.
    public func start() throws {
        loadGlobals()
        try interpreter.boot(Self.bootScript(fileSystem))
        runInterpreter()
    }

    // MARK: Driving

    /// Advances the clock (ms): tweens move, timed waits end, the script continues.
    public func update(time: Double) {
        now = time
        stage.update(time: time)
        if wait != waitKind {
            if waitKind == .click { interpreter.callLuaEvent("onClickWaitOut") }
            if wait == .click { interpreter.callLuaEvent("onClickWaitIn") }
            waitKind = wait
            waitStarted = time
        }
        interpreter.callLuaEvent("onEnterFrame")
        messages.advanceReveal(by: max(0, time - lastUpdate), instant: skipMode)
        lastUpdate = time
        switch wait {
        case let .time(until, _):
            if time >= until || skipMode {
                if skipMode { finishTweensNow() }
                wait = .none
                runInterpreter()
            }
        case .click:
            let autoDelay = Double(interpreter.value(of: "s.automodewait") ?? "") ?? 2000
            if messages.isRevealing { waitStarted = time }
            if skipMode || (autoMode && !messages.isRevealing && time - waitStarted >= max(300, autoDelay)) {
                advance()
            }
        case .stop:
            // Skip ends where the reader has to choose.
            if skipMode { skipMode = false }
        default:
            break
        }
    }

    private var waitKind: Wait = .none
    private var lastUpdate: Double = 0
    private var waitStarted: Double = 0

    /// Toggles auto mode (text advances by itself after s.automodewait ms).
    public func setAutoMode(_ on: Bool) {
        autoMode = on
        if on { skipMode = false }
    }

    /// Toggles skip mode (text and waits fly by until a choice or a tap).
    public func setSkipMode(_ on: Bool) {
        skipMode = on
        if on { autoMode = false }
    }

    /// Hides the message window and text until the next tap (`[exec command=hide]`).
    public func toggleHide() {
        if hidden { unhide(); return }
        guard hideAllowed else { return }
        hidden = true
        hiddenLayers = []
        for id in hideWindows {
            if let layer = stage.layer(id), layer.visible {
                layer.visible = false
                hiddenLayers.append(id)
            }
        }
        stage.present(transition: nil)
    }

    private func unhide() {
        hidden = false
        for id in hiddenLayers { stage.layer(id)?.visible = true }
        hiddenLayers = []
        stage.present(transition: nil)
    }

    /// True while the reader has hidden the text.
    public private(set) var hidden = false
    private var hiddenLayers: [String] = []
    private var hideWindows: [String] = ["80", "81", "82", "90"]
    private var hideAllowed = true

    /// A tap at a stage point.
    public func tap(at point: CGPoint) {
        interpreter.pointer = point
        if hidden { unhide(); return }
        if autoMode || skipMode {
            autoMode = false
            skipMode = false
            return
        }
        switch wait {
        case .stop:
            guard let (_, event) = stage.clickTarget(at: point) else { return }
            wait = .none
            fire(event.attributes, interrupt: false)
        case .click, .time:
            // On-screen buttons (MENU, quick save, ...) stay live while text waits; they
            // interrupt the wait and hand it back when they return.
            if case .click = wait, let (_, event) = stage.clickTarget(at: point) {
                savedWaits.append(wait)
                wait = .none
                fire(event.attributes, interrupt: true)
                return
            }
            advance()
        case .video, .none, .dialog:
            break
        }
    }

    public enum DragPhase { case began, moved, ended }

    /// A finger dragging on the stage: `lyevent` dragin / drag / dragout on the layer it
    /// started on (sliders), while the script waits on buttons.
    public func drag(_ phase: DragPhase, at point: CGPoint) {
        interpreter.pointer = point
        switch phase {
        case .began:
            dragLayer = stage.eventTarget(at: point, type: "dragin") ?? stage.eventTarget(at: point, type: "drag")
            fireDrag("dragin")
        case .moved:
            fireDrag("drag")
        case .ended:
            fireDrag("dragout")
            dragLayer = nil
        }
    }

    private var dragLayer: String?

    private func fireDrag(_ type: String) {
        guard wait == .stop, let id = dragLayer, let event = stage.events[id]?[type], event.enabled else { return }
        wait = .none
        fire(event.attributes, interrupt: false)
    }

    /// Ends the current wait the way a plain tap does (advance text, skip a wait).
    public func advance() {
        switch wait {
        case let .time(_, skippable):
            guard skippable else { return }
            finishTweensNow()
            wait = .none
            runInterpreter()
        case .click:
            if messages.isRevealing {
                messages.revealAll()
                return
            }
            wait = .none
            if let rest = pendingText {
                pendingText = nil
                if case .wait = show(text: rest, interpreter: interpreter) { return }
            }
            runInterpreter()
        default:
            break
        }
    }

    /// Right-click (two-finger tap on iOS): opens the game's right-click script (its menu),
    /// or inside it, leaves. Ignored during transitions and movies, or when the game turned
    /// right-click off.
    public func rightClick() {
        // A key handler on the right button (key 2) takes precedence, e.g. menus bind it to
        // their *leave.
        if press(key: "2") { return }
        guard rightClickAllowed else { return }
        switch wait {
        case .click, .stop:
            if !interpreter.inRightClickScript { savedWaits.append(wait) }
            wait = .none
            do {
                try interpreter.rightClick(file: rightClickFile)
            } catch {
                record("right-click failed: \(error)")
            }
            runInterpreter()
        default:
            break
        }
    }

    /// Runs a `[setonpush]` key handler, if one is set. Returns whether one ran.
    @discardableResult
    public func press(key: String) -> Bool {
        guard var handler = keyHandlers[key] else { return false }
        switch wait {
        case .click, .stop, .time:
            let interrupt = wait != .stop
            if interrupt, handler["call"] == "1" { savedWaits.append(wait) }
            if !interrupt, handler["call"] != "1" { handler["call"] = "0" }
            wait = .none
            fire(handler, interrupt: interrupt)
            return true
        default:
            return false
        }
    }

    private func fire(_ attributes: [String: String], interrupt: Bool) {
        do {
            try interpreter.fireEvent(attributes, interrupt: interrupt)
        } catch {
            record("event failed: \(error)")
        }
        runInterpreter()
    }

    public func videoFinished() {
        guard wait == .video else { return }
        wait = .none
        runInterpreter()
    }

    private func finishTweensNow() {
        stage.update(time: now + 1_000_000)
    }

    /// User actions requested by `[exec]`, run once the script has yielded.
    private var pendingExec: ((ArtemisPlayer) -> Void)?

    private func runInterpreter() {
        defer {
            if let action = pendingExec {
                pendingExec = nil
                action(self)
            }
        }
        let state = interpreter.run(maxSteps: 5_000_000)
        switch state {
        case let .failed(message):
            failure = message
            record("FAILED: \(message)")
        case .finished:
            record("script finished")
        case .running:
            record("step budget exhausted at \(interpreter.location)")
        case .waiting(ArtemisInterpreter.interruptReturned):
            // A button or the right-click menu returned: back to the wait it interrupted.
            wait = savedWaits.popLast() ?? .none
            if wait == .none { runInterpreter() }
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
            if tag["sync"] == "1", end.isFinite { return waitTime(until: end, skippable: tag["input"] == "1") }
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
            // input: omitted or 1 lets a tap skip; 0 and 2 don't (2 only yields to skip mode).
            if time > 0 { return waitTime(until: now + time, skippable: tag["input"] == nil || tag["input"] == "1") }
        case "wait":
            if tag["se"] != nil || tag["voice"] != nil { return .done } // sound-completion waits: not yet
            let time = tag.number("time")
            // input: 1 lets a tap end it; omitted/0 and 2 don't.
            if time > 0 { return waitTime(until: now + time, skippable: tag["input"] == "1") }
        case "setonpush":
            guard let key = tag["key"] else { break }
            var attributes = tag.attributes
            attributes["key"] = nil
            if attributes["file"] == nil, attributes["label"] == nil { keyHandlers[key] = nil } else { keyHandlers[key] = attributes }
        case "delonpush":
            if let key = tag["key"] { keyHandlers[key] = nil }
        case "dialog":
            let varname = tag["varname"], textField = tag["textfield"]
            guard let media else {
                // Headless: answer OK.
                if let varname { interpreter.variables[varname] = "1" }
                return .done
            }
            wait = .dialog
            media.presentDialog(title: tag["title"] ?? "", message: tag["message"] ?? tag["messagae"] ?? "",
                                cancellable: varname != nil, textField: textField != nil) { [weak self] ok, text in
                guard let self, self.wait == .dialog else { return }
                if let varname { self.interpreter.variables[varname] = ok ? "1" : "0" }
                if let textField, let text {
                    let limit = tag["textfieldsize"].flatMap(Int.init)
                    self.interpreter.variables[textField] = limit.map { String(text.prefix($0)) } ?? text
                }
                self.wait = .none
                self.runInterpreter()
            }
            return .wait("dialog")
        case "save":
            save(to: tag["file"] ?? "save.dat")
        case "load":
            if load(from: tag["file"] ?? "save.dat", transition: tag) { return .wait("loaded") }
        case "takess":
            screenshot = renderSnapshot()
        case "savess":
            if let screenshot, let file = tag["file"] {
                writePNG(screenshot, to: resolveSavePath(file), width: tag["width"].flatMap(Int.init), height: tag["height"].flatMap(Int.init))
            }
        case "exec":
            switch tag["command"] {
            case "rclick": pendingExec = { $0.rightClick() }
            case "automode": setAutoMode(tag["mode"] != "0")
            case "skip": setSkipMode(tag["mode"].map { $0 != "0" } ?? !skipMode)
            case "hide": pendingExec = { $0.toggleHide() }
            default: break
            }
        case "hide":
            if let allow = tag["allow"] { hideAllowed = allow != "0" }
            if let window = tag["window"], !window.isEmpty {
                hideWindows = window.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
            }
        case "automode":
            if tag["allow"] == "0" { autoMode = false }
        case "skip":
            if tag["allow"] == "0" { skipMode = false }
        case "rclick":
            if let allow = tag["allow"] { rightClickAllowed = allow != "0" }
            if let file = tag["file"], !file.isEmpty { rightClickFile = file }
        case "stop":
            wait = .stop
            return .wait("stop")
        case "rp":
            messages.clear()
        case "rt":
            messages.append("\n")
        case "scetween":
            if tag["type"] == "in", tag["mode"] == "add", tag["param"] == "alpha" || tag["param"] == nil {
                messages.currentLayer.charDelay = max(0, tag.number("delay", default: 30))
            }
        case "sceout":
            messages.setPageHidden(true)
        case "scein":
            messages.setPageHidden(false)
        case "chgmsg":
            messages.change(to: tag["id"], push: tag["stack"] != "0")
            if traceMessages { record("chgmsg \(tag["id"] ?? "?") stack=\(tag["stack"] ?? "1") at \(interpreter.location)") }
        case "/chgmsg":
            messages.change(to: nil)
            if traceMessages { record("/chgmsg -> \(messages.current) at \(interpreter.location)") }
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
            if tag.name == "splay" { music = tag.attributes }
            if tag.name == "sstop" { music = nil }
            media?.soundTag(tag) { [fileSystem] path in try? fileSystem.data(path) }
        case "system:get_layer_info":
            let name = tag["name"] ?? "li"
            if let id = tag["id"] {
                // One layer: name.left, name.width, ...
                for (key, value) in stage.layerInfo(style: "map") where key.hasPrefix(id + ".") {
                    let field = String(key.dropFirst(id.count + 1))
                    if !field.contains(".") { interpreter.variables["\(name).\(field)"] = value }
                }
            } else {
                for (key, value) in stage.layerInfo(style: tag["style"]) { interpreter.variables["\(name).\(key)"] = value }
            }
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
        "caption", "ruby", "indent", "glyph",
        "backlog", "autosave", "writebacklog", "delonclick", "setonclick",
        "setonrollover", "setondrag", "setondragout", "link", "linkenable", "linkdisable", "keyconfig", "mouse",
        "anime", "backloglayer", "tweenset", "alreadyread", "reset",
        "setonautomodein", "setonautomodeout", "setoncontrolskipin", "setoncontrolskipout", "setonsoundfinish",
        "delonsoundfinish", "openbrowser", "file", "btn_off", "info_hide_on", "info_hide_off",
        "lyevent_delete", "lydrag", "lyedit", "gesture_enable", "gesture_disable", "key_enable", "key_disable",
        "tag", "prohibit",
    ]

    // MARK: Saves

    private func resolveSavePath(_ file: String) -> URL {
        if file.hasPrefix("/") { return URL(fileURLWithPath: file) }
        let root = savePath ?? fileSystem.gameRoot.appendingPathComponent("savedata", isDirectory: true)
        return root.appendingPathComponent(file)
    }

    private func waitName(_ wait: Wait) -> String {
        switch wait {
        case .click: return "click"
        case .stop: return "stop"
        default: return "none"
        }
    }

    func captureState(wait: Wait) -> ArtemisSaveState {
        // Inside a menu or button routine, keep only the reading position underneath it.
        let limit = interpreter.firstInterruptIndex
        let (messageLayers, current, stack, defaultFont) = messages.saved()
        return ArtemisSaveState(
            frames: interpreter.savedFrames(upTo: limit),
            variables: interpreter.variables.filter { !$0.key.hasPrefix("t.") && !$0.key.hasPrefix("g.") },
            layers: stage.savedLayers(), events: stage.savedEvents(),
            messages: messageLayers, currentMessage: current, messageStack: stack, defaultFont: defaultFont,
            wait: waitName(wait), pendingText: pendingText, keyHandlers: keyHandlers,
            rightClickFile: rightClickFile, rightClickAllowed: rightClickAllowed, hideWindows: hideWindows, music: music)
    }

    private func save(to file: String) {
        let state = checkpoint ?? captureState(wait: savedWaits.first ?? wait)
        let url = resolveSavePath(file)
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(state).write(to: url, options: .atomic)
            saveGlobals()
            record("saved \(url.lastPathComponent)")
        } catch {
            record("save failed: \(error)")
        }
    }

    /// Restores a save. Returns whether it worked (the script then waits where the save was).
    private func load(from file: String, transition: ArtemisTag?) -> Bool {
        let url = resolveSavePath(file)
        guard let data = try? Data(contentsOf: url), let state = try? JSONDecoder().decode(ArtemisSaveState.self, from: data) else {
            record("load failed: no save at \(url.lastPathComponent)")
            return false
        }
        do {
            try interpreter.restore(frames: state.frames)
        } catch {
            record("load failed: \(error)")
            return false
        }
        let globals = interpreter.variables.filter { $0.key.hasPrefix("g.") }
        interpreter.variables = state.variables.merging(globals) { _, global in global }
        stage.restore(layers: state.layers, events: state.events)
        messages.restore(state.messages, current: state.currentMessage, stack: state.messageStack, defaultFont: state.defaultFont)
        pendingText = state.pendingText
        keyHandlers = state.keyHandlers
        rightClickFile = state.rightClickFile
        rightClickAllowed = state.rightClickAllowed
        hideWindows = state.hideWindows
        savedWaits = []
        hidden = false
        autoMode = false
        skipMode = false
        // Music as it was.
        media?.soundTag(ArtemisTag(name: "sstop", attributes: [:], order: [])) { _ in nil }
        if let music = state.music {
            self.music = music
            media?.soundTag(ArtemisTag(name: "splay", attributes: music, order: music.keys.sorted())) { [fileSystem] in try? fileSystem.data($0) }
        }
        let type = transition?["type"]
        stage.present(transition: type.map { ArtemisTag(name: "trans", attributes: ["type": $0, "time": transition?["time"] ?? "500"], order: ["type", "time"]) })
        switch state.wait {
        case "click": wait = .click
        case "stop": wait = .stop
        default: wait = .none
        }
        record("loaded \(url.lastPathComponent)")
        return true
    }

    private var globalsURL: URL { resolveSavePath("global.json") }

    private func loadGlobals() {
        guard let data = try? Data(contentsOf: globalsURL),
              let globals = try? JSONDecoder().decode([String: String].self, from: data) else { return }
        interpreter.variables.merge(globals) { _, saved in saved }
    }

    /// Writes `g.` variables (they live outside save slots). Call when leaving the game too.
    public func saveGlobals() {
        let globals = interpreter.variables.filter { $0.key.hasPrefix("g.") }
        try? FileManager.default.createDirectory(at: globalsURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? JSONEncoder().encode(globals).write(to: globalsURL, options: .atomic)
    }

    private func writePNG(_ image: CGImage, to url: URL, width: Int?, height: Int?) {
        var output = image
        if let width, let height, width > 0, height > 0,
           let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                   space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                   bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) {
            context.interpolationQuality = .high
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            output = context.makeImage() ?? image
        }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil) else { return }
        CGImageDestinationAddImage(destination, output, nil)
        CGImageDestinationFinalize(destination)
    }

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
