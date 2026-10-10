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
    /// Whether an effect/voice channel (`seplay id`) is still sounding.
    func isSoundPlaying(_ id: String) -> Bool
    /// Plays a full-screen movie; call `finished` when it ends or is skipped. Returns false
    /// when it can't be played, and the script carries on.
    func playVideo(_ source: ArtemisVideoSource, finished: @escaping () -> Void) -> Bool
    /// `[openbrowser]`, `e:callShellExecute`.
    func openURL(_ url: URL)
    /// `[vibrate]`.
    func vibrate()
    /// `e:writeClipboard`.
    func copyToClipboard(_ text: String)
    /// Playback state of the music (`id` nil) or an effect channel: playing, gain (0...1000)
    /// and pan (-1000...1000), for `get_sound_info`.
    func soundInfo(_ id: String?) -> (playing: Bool, gain: Double, pan: Double)?
    /// Effect channel ids with a sound loaded.
    var soundChannels: [String] { get }
}

public extension ArtemisMediaDelegate {
    func openURL(_ url: URL) {}
    func vibrate() {}
    func copyToClipboard(_ text: String) {}
    func soundInfo(_ id: String?) -> (playing: Bool, gain: Double, pan: Double)? { nil }
    var soundChannels: [String] { [] }
}

/// Where a full-screen movie comes from: loose files are streamed from disk (they can be
/// hundreds of MB); archived ones are in memory.
public enum ArtemisVideoSource {
    case file(URL)
    case data(Data, fileExtension: String)

    public var fileExtension: String {
        switch self {
        case let .file(url): return url.pathExtension.lowercased()
        case let .data(_, ext): return ext.lowercased()
        }
    }
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
        /// Until a sound channel finishes (`[wait se=...]`); a tap ends it when skippable.
        case sound(String, skippable: Bool)
        /// Until a video layer ends (`[wait video=...]`); a tap ends it when skippable.
        case videoLayer(String, skippable: Bool)
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
    public private(set) lazy var textRenderer: ArtemisTextRenderer = {
        let renderer = ArtemisTextRenderer { [fileSystem] path in try? fileSystem.data(path) }
        renderer.indentPairs = { [weak self] in self?.messages.indentPairs ?? [:] }
        renderer.newerGeneration = interpreter.defersLuaCalls
        return renderer
    }()
    /// Text of the current message layer (for logs).
    public var messageText: String { messages.currentLayer.text }
    /// Prose left over after an `@` click wait, shown when the reader taps.
    private var pendingText: String?
    /// Pages read so far (speaker, text), oldest first, for the backlog.
    public private(set) var history: [(speaker: String?, text: String)] = []

    /// Keeps the page being cleared, when it's story text (not a menu's message layer).
    private func recordHistory() {
        let layer = messages.currentLayer
        guard ["adv", "novel"].contains(layer.id) else { return }
        let text = layer.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, history.last?.text != text else { return }
        let name = messages.layers["name"]?.text.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "【】"))
        history.append((name?.isEmpty == false ? name : nil, text))
        if history.count > 500 { history.removeFirst(history.count - 500) }
    }

    /// The backlog including the page on screen now.
    public var backlog: [(speaker: String?, text: String)] {
        var pages = history
        let current = messages.layers["adv"]?.text.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !current.isEmpty, pages.last?.text != current {
            let name = messages.layers["name"]?.text.trimmingCharacters(in: .whitespacesAndNewlines)
                .trimmingCharacters(in: CharacterSet(charactersIn: "【】"))
            pages.append((name?.isEmpty == false ? name : nil, current))
        }
        return pages
    }

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
    /// The layer a tap last rolled over.
    private var hoveredLayer: String?
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
        stage.loadVideo = { [weak self] file, loop in self?.openVideoLayer(file, loop: loop) }
        stage.drawMessageLayer = { [weak self] id, context in
            guard let self, let layer = self.messages.layers[id] else { return }
            self.textRenderer.draw(layer, in: context)
        }
    }

    /// Where `[save]` files go (the game's saves folder in Shiori).
    public var savePath: URL?
    public private(set) var autoMode = false {
        didSet {
            guard autoMode != oldValue else { return }
            queueEngineEvent(autoMode ? "automodein" : "automodeout")
            if let id = autoModeLayer { stage.layer(id)?.visible = autoMode }
        }
    }
    public private(set) var skipMode = false {
        didSet {
            guard skipMode != oldValue else { return }
            let kind = forceSkip ? "controlskip" : "commandskip"
            queueEngineEvent(kind + (skipMode ? "in" : "out"))
            if !skipMode { forceSkip = false }
        }
    }
    /// Skip that ignores read state (the engine's "control skip", Ctrl on Windows).
    public private(set) var forceSkip = false

    /// The engine's read-only system variables (Artemis spec, system_variables.txt).
    private func systemVariable(_ name: String) -> String? {
        switch name {
        case "s.current_message_layer": return messages.current
        // Asked by PC builds Shiori presents as Windows (see ArtemisInterpreter.reportedOS).
        case "s.windowsversion": return "10.0"
        case "s.status.automode": return autoMode ? "1" : "0"
        case "s.status.commandskip": return skipMode && !forceSkip ? "1" : "0"
        case "s.status.controlskip": return skipMode && forceSkip ? "1" : "0"
        case "s.status.alreadyread": return currentTextRead ? "1" : "0"
        case "s.status.avoid": return "0"
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
        // The engine's writable system variables start at its defaults (saved values win).
        for (name, value) in ["s.bgmvol": "1000", "s.sevol": "1000", "s.videovol": "1000", "s.automodewait": "2000"]
        where interpreter.variables[name] == nil {
            interpreter.variables[name] = value
        }
        loadGlobals()
        try interpreter.boot(Self.bootScript(fileSystem))
        runInterpreter()
    }

    // MARK: Driving

    /// Advances the clock (ms): tweens move, timed waits end, the script continues.
    // MARK: Input state for Lua (e:isDown, e:getTouchPoint, ...)

    /// Frames since boot (`e:getFrameNumber`).
    public private(set) var frameNumber = 0
    /// Keys held now, and the edges of the frame being run (key ids as strings: 1 = tap
    /// or left button, 2 = right button).
    private var keysDown: Set<String> = []
    private var pendingEdges: [String: Set<String>] = [:]
    private var frameEdges: [String: Set<String>] = [:]
    /// The finger on the stage, if any (id -> point).
    private var touches: [Int: CGPoint] = [:]

    private func noteKey(_ key: String, _ edge: String) {
        pendingEdges[edge, default: []].insert(key)
    }

    /// A finger went down or up at a stage point (from the presenter).
    public func touch(_ id: Int, at point: CGPoint?) {
        if let point {
            if touches[id] == nil { noteKey("1", "downEdge"); keysDown.insert("1") }
            touches[id] = point
            interpreter.pointer = point
        } else {
            touches[id] = nil
            if touches.isEmpty {
                keysDown.remove("1")
                noteKey("1", "upEdge")
            }
        }
    }

    public func update(time: Double) {
        now = time
        frameNumber += 1
        frameEdges = pendingEdges
        pendingEdges = [:]
        stage.holdsVideoFrames = skipMode
        // Layered message layers keep their place even if the game cleared the tree.
        for layer in messages.layers.values where layer.layered && stage.layer(layer.id)?.messageLayer != layer.id {
            stage.placeMessageLayer(layer.id)
        }
        stage.update(time: time)
        // Tween completion handlers (a choice's time limit) run like layer events, once
        // the script is waiting on buttons.
        pendingTweenHandlers += stage.takeFinishedHandlers()
        if wait == .stop, !pendingTweenHandlers.isEmpty {
            let handler = pendingTweenHandlers.removeFirst()
            if interpreter.filterEvent(tagName: "lytween", attributes: handler) {
                wait = .none
                fire(handler, interrupt: false)
            }
        }
        watchFinishEvents()
        runEngineEvents()
        updateGlyph()
        if wait != waitKind {
            if waitKind == .click { interpreter.callLuaEvent("onClickWaitOut") }
            if wait == .click { interpreter.callLuaEvent("onClickWaitIn") }
            waitKind = wait
            waitStarted = time
        }
        interpreter.callLuaEvent("onEnterFrame")
        if clickKeyPressed {
            clickKeyPressed = false
            if ArtemisInterpreter.traceLua, wait == .click { record("trace: click key advances") }
            if wait == .click { advance() }
        }
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
            // Read skip stops at text not read before (unless the game allows unread skip).
            if skipMode, !forceSkip, !skipUnread, alreadyReadEnabled, !currentTextRead { skipMode = false }
            let autoDelay = Double(interpreter.value(of: "s.automodewait") ?? "") ?? 2000
            if messages.isRevealing || (autoMode && voicePlaying) { waitStarted = time }
            if skipMode || (autoMode && !messages.isRevealing && time - waitStarted >= max(300, autoDelay)) {
                if ArtemisInterpreter.traceLua { record("trace: \(skipMode ? "skip" : "auto") advances") }
                advance()
            }
        case let .sound(id, _):
            if skipMode || !(media?.isSoundPlaying(id) ?? false) {
                wait = .none
                runInterpreter()
            }
        case let .videoLayer(id, _):
            if skipMode || !stage.isVideoPlaying(id) {
                wait = .none
                runInterpreter()
            }
        case .stop:
            // Skip ends where the reader has to choose; auto too when the game says so.
            if skipMode { skipMode = false }
            if autoMode, autoStopByStop { autoMode = false }
        default:
            break
        }
    }

    private var waitKind: Wait = .none
    private var pendingTweenHandlers: [[String: String]] = []

    /// A synced channel (the game's `g.syncse` list, voices) is still speaking.
    private var voicePlaying: Bool {
        guard let media else { return false }
        let ids = (interpreter.value(of: "g.syncse") ?? "").split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        return ids.contains { media.isSoundPlaying($0) }
    }
    private var lastUpdate: Double = 0
    private var waitStarted: Double = 0

    /// Toggles auto mode (text advances by itself after s.automodewait ms).
    public func setAutoMode(_ on: Bool) {
        guard !on || autoAllowed else { return }
        autoMode = on
        if on { skipMode = false }
    }

    /// Toggles skip mode: text and waits fly by until a choice or a tap, and, unless the
    /// game allows skipping unread text (or `force`), until text not read before.
    public func setSkipMode(_ on: Bool, force: Bool = false) {
        guard !on || skipAllowed else { return }
        if on { forceSkip = force }
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
    public private(set) var hidden = false {
        didSet { if hidden != oldValue { queueEngineEvent(hidden ? "hidein" : "hideout") } }
    }
    private var hiddenLayers: [String] = []
    private var hideWindows: [String] = ["80", "81", "82", "90"]
    private var hideAllowed = true

    /// A tap at a stage point.
    public func tap(at point: CGPoint) {
        interpreter.pointer = point
        noteKey("1", "decide")
        if hidden { unhide(); return }
        if skipMode {
            skipMode = false
            return
        }
        if autoMode, autoStopByClick {
            autoMode = false
            return
        }
        if wait == .stop || wait == .click, let link = linkTarget(at: point) {
            if wait == .click { markRead() }
            wait = .none
            fire(link, interrupt: false)
            return
        }
        // The newer generation's buttons, at a [stop] or beside text. When its Lua decides
        // what a click does (it set the click-wait keys), text only moves on when the key
        // handler presses one of them.
        if interpreter.defersLuaCalls, wait == .stop || wait == .click {
            let point = touchPoint(near: point)
            if wait == .stop || stage.clickTarget(at: point) != nil || clickKeys != nil {
                pressButton(at: point)
                return
            }
        }
        switch wait {
        case .stop:
            let point = touchPoint(near: point)
            guard let (_, event) = stage.clickTarget(at: point) else {
                // A click on nothing: the script's own key-1 handler (Ne no Kami's hide screen
                // comes back with [setonpush key="1"]), or out of the right-click script, whose
                // hide mode leaves nothing on screen to tap.
                if press(key: "1") { return }
                if interpreter.inRightClickScript { rightClick() }
                return
            }
            wait = .none
            fire(event.attributes, interrupt: false)
        case .click, .time, .sound, .videoLayer:
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

    /// A newer-generation button press. A finger has no hover, so the button under it is
    /// rolled over first, as the mouse would have; then its click; then the left button's own
    /// handler (key 1), which acts on the click the button noted: NUKITASHI's framework
    /// dispatches every button that way. Handlers that go nowhere leave the wait as it was
    /// ([stop], or the [@] beside text), as the engine runs events beside the script.
    private func pressButton(at point: CGPoint) {
        let waiting = wait
        func run(_ attributes: [String: String]) {
            guard wait == waiting else { return }
            wait = .none
            fire(attributes, interrupt: false)
        }
        if let id = stage.eventTarget(at: point, type: "rollover"), id != hoveredLayer,
           let event = stage.events[id]?["rollover"], event.attributes["file"] == nil, event.attributes["label"] == nil {
            hoveredLayer = id
            run(event.attributes)
        }
        if let (_, event) = stage.clickTarget(at: point) { run(event.attributes) }
        if let handler = keyHandlers["1"], handler["file"] == nil, handler["label"] == nil,
           interpreter.filterEvent(tagName: "setonpush", attributes: handler) {
            run(handler)
        }
    }

    /// The point itself if a button takes it, else the nearest point within 16 stage pixels
    /// that one does (rings of 8 directions), else the point.
    private func touchPoint(near point: CGPoint) -> CGPoint {
        if stage.clickTarget(at: point) != nil { return point }
        for radius in stride(from: 4.0, through: 16, by: 4) {
            for step in 0 ..< 8 {
                let angle = Double(step) * .pi / 4
                let candidate = CGPoint(x: point.x + radius * cos(angle), y: point.y + radius * sin(angle))
                if stage.clickTarget(at: candidate) != nil {
                    interpreter.pointer = candidate
                    return candidate
                }
            }
        }
        return point
    }

    public enum DragPhase { case began, moved, ended }

    /// A finger dragging on the stage: `lyevent` dragin / drag / dragout on the layer it
    /// started on (sliders), while the script waits on buttons.
    public func drag(_ phase: DragPhase, at point: CGPoint) {
        interpreter.pointer = point
        switch phase {
        case .began:
            dragLayer = stage.eventTarget(at: point, type: "dragin") ?? stage.eventTarget(at: point, type: "drag")
            draggedLayer = stage.draggableLayer(at: point)
            lastDragPoint = point
            fireDrag("dragin")
        case .moved:
            if let layer = draggedLayer, let last = lastDragPoint {
                stage.drag(layer, by: CGSize(width: point.x - last.x, height: point.y - last.y))
            }
            lastDragPoint = point
            fireDrag("drag")
        case .ended:
            fireDrag("dragout")
            dragLayer = nil
            draggedLayer = nil
            lastDragPoint = nil
        }
    }

    private var dragLayer: String?
    /// A `draggable` layer following the finger.
    private var draggedLayer: ArtemisLayer?
    private var lastDragPoint: CGPoint?

    /// Whether a drag starting here would move something (sliders, draggable layers).
    public func canDrag(at point: CGPoint) -> Bool {
        wait == .stop && (stage.eventTarget(at: point, type: "dragin") ?? stage.eventTarget(at: point, type: "drag")) != nil
            || stage.draggableLayer(at: point) != nil
    }

    private func fireDrag(_ type: String) {
        guard wait == .stop, let id = dragLayer, let event = stage.events[id]?[type], event.enabled else { return }
        wait = .none
        fire(event.attributes, interrupt: false)
    }

    /// A video layer's decoder, with its `_m` alpha video when the game has one.
    func openVideoLayer(_ file: String, loop: Bool) -> ArtemisVideo? {
        func open(_ path: String) -> ArtemisVideo? {
            let ext = (path as NSString).pathExtension
            return fileSystem.url(path).flatMap { ArtemisVideo(url: $0, loop: loop) }
                ?? (try? fileSystem.data(path)).flatMap { $0.flatMap { ArtemisVideo(data: $0, fileExtension: ext, loop: loop) } }
        }
        guard let video = open(file) else { return nil }
        let ext = (file as NSString).pathExtension
        let maskPath = (file as NSString).deletingPathExtension + "_m" + (ext.isEmpty ? "" : "." + ext)
        if fileSystem.file(maskPath) != nil { video.mask = open(maskPath) }
        return video
    }

    /// Ends the current wait the way a plain tap does (advance text, skip a wait).
    public func advance() {
        switch wait {
        case let .sound(_, skippable), let .videoLayer(_, skippable):
            guard skippable else { return }
            wait = .none
            runInterpreter()
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
            markRead()
            wait = .none
            if overflowPageBreak {
                overflowPageBreak = false
                recordHistory()
                if writeBacklog { recordBacklogPage(messages.currentLayer) }
                messages.clear()
            }
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
        noteKey("2", "decide")
        noteKey("2", "downEdge")
        noteKey("2", "upEdge")
        // A key handler on the right button (key 2) takes precedence, e.g. menus bind it to
        // their *leave.
        if press(key: "2") { return }
        // `[rclick allow=0]` stops the right-click script from opening, not from closing:
        // Ne no Kami's hides the text with a macro that turns it off, then waits for the
        // right-click that ends it.
        guard rightClickAllowed || interpreter.inRightClickScript else { return }
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
        guard let handler = keyHandlers[key] else { return false }
        noteKey(key, "decide")
        return fireHandler(handler, tagName: "setonpush")
    }

    /// Runs a `setonpush`-style handler (keys, engine events): as an interrupt during text
    /// and timed waits (returning to them when `call=1`), as a jump/call at a stop.
    @discardableResult
    private func fireHandler(_ attributes: [String: String], tagName: String) -> Bool {
        var handler = attributes
        guard interpreter.filterEvent(tagName: tagName, attributes: handler) else { return true }
        switch wait {
        case .click, .stop, .time:
            let interrupt = wait != .stop
            if interrupt, handler["call"] == "1" || interpreter.returnsToWait(handler, interrupt: true) { savedWaits.append(wait) }
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
        case let .waiting(reason):
            if traceWaits { record("trace: wait \(reason) at \(interpreter.location)") }
        }
    }

    /// Logs every wait the script stops at (debug).
    public var traceWaits = false

    private func record(_ message: String) {
        log.append(message)
        onLog?(message)
    }

    // MARK: ArtemisHost

    public func log(_ message: String) {
        record(message)
    }

    /// getScriptStatus numbers (e:getScriptStatus).
    private var scriptStatus: Int {
        if hidden { return 5 }
        switch wait {
        case .none: return 0
        case .click: return 1
        case let .time(_, skippable): return skippable ? 2 : 4
        case .stop: return 3
        case .video: return 7
        case .dialog: return 9
        case .sound, .videoLayer: return 1
        }
    }

    public func luaQuery(_ name: String, _ arguments: [String], interpreter: ArtemisInterpreter) -> String? {
        let us = "\u{1F}", rs = "\u{1E}"
        let first = arguments.first ?? ""
        switch name {
        case "now":
            return ArtemisValue.format(now.rounded())
        case "frame":
            return String(frameNumber)
        case "status":
            return String(scriptStatus)
        case "setStatus":
            // Only the documented safe use: stopped -> running.
            if first == "0", wait == .stop || wait == .click {
                wait = .none
                pendingExec = { $0.runInterpreter() }
            }
            return nil
        case "waitReason":
            var fields: [String] = []
            switch wait {
            case let .time(until, _): fields += ["time", ArtemisValue.format(until.rounded())]
            case .click where messages.isRevealing: fields += ["textTween", "1"]
            case let .sound(id, _): fields += ["sound", id]
            case let .videoLayer(id, _): fields += ["video", id]
            default: break
            }
            return fields.joined(separator: us)
        case "key":
            let kind = first, key = arguments.count > 1 ? arguments[1] : ""
            if let override = keyOverrides[key] ?? keyOverrides["*"] {
                let bit = ["push": 1, "down": 2, "downEdge": 4, "upEdge": 8, "decide": 16][kind] ?? 0
                return override & bit != 0 ? "1" : "0"
            }
            switch kind {
            case "down": return keysDown.contains(key) ? "1" : "0"
            case "push": return keysDown.contains(key) || frameEdges["downEdge"]?.contains(key) == true ? "1" : "0"
            default:
                // On touch screens a tap decides on release.
                return frameEdges[kind]?.contains(key) == true ? "1" : "0"
            }
        case "overrideKey":
            let key = first.isEmpty ? "*" : first
            if arguments.count > 1, let status = Double(arguments[1]).map({ Int($0) }), status >= 0 {
                keyOverrides[key] = status
                if status == 32, clickKeys?.contains(key) == true { clickKeyPressed = true }
            } else {
                keyOverrides[key] = nil
            }
            return nil
        case "touchCount":
            return String(touches.count)
        case "touches":
            return touches.map { "\($0.key)\(us)\(Int($0.value.x))\(us)\(Int($0.value.y))" }.joined(separator: rs)
        case "saveToMemory":
            let state = checkpoint ?? captureState(wait: savedWaits.first ?? wait)
            return (try? JSONEncoder().encode(state)).flatMap { String(data: $0, encoding: .utf8) }
        case "loadFromMemory":
            if let data = first.data(using: .utf8), let state = try? JSONDecoder().decode(ArtemisSaveState.self, from: data) {
                pendingExec = { player in
                    if player.restore(state, transition: nil) { player.runInterpreter() }
                }
            }
            return nil
        case "pngComments":
            let data = (try? fileSystem.data(first)) ?? (first.hasPrefix("/") ? FileManager.default.contents(atPath: first) : nil)
                ?? FileManager.default.contents(atPath: resolveSavePath(first).path)
            return data.map { Self.pngComments($0).flatMap { [$0.key, $0.value] }.joined(separator: us) }
        case "bindSurface":
            _ = stage.image(first)
            return nil
        case "unbindSurface":
            // The stage's image cache keeps what it decoded; nothing to release here.
            return nil
        case "touchHold":
            return nil
        case "clipboard":
            media?.copyToClipboard(first)
            return nil
        case "openURL":
            if let url = URL(string: first) { media?.openURL(url) }
            return nil
        default:
            if reportedLuaQueries.insert(name).inserted { record("unsupported Lua query \(name)") }
            return nil
        }
    }

    /// e:overrideKey statuses by key id ("*" = every key).
    private var keyOverrides: [String: Int] = [:]
    /// The newer generation's click-wait keys (`keyconfig role=0`); nil: any tap advances.
    private var clickKeys: Set<String>?
    /// One of them was pressed by the game's Lua: the click wait gives way on this frame.
    private var clickKeyPressed = false
    private var reportedLuaQueries: Set<String> = []

    /// tEXt chunks of a PNG (keyword -> text).
    static func pngComments(_ data: Data) -> [String: String] {
        var result: [String: String] = [:]
        var offset = 8
        let bytes = [UInt8](data)
        while offset + 8 <= bytes.count {
            let length = Int(bytes[offset]) << 24 | Int(bytes[offset + 1]) << 16 | Int(bytes[offset + 2]) << 8 | Int(bytes[offset + 3])
            let type = String(bytes: bytes[offset + 4 ..< offset + 8], encoding: .ascii) ?? ""
            let start = offset + 8
            guard start + length <= bytes.count else { break }
            if type == "tEXt", let zero = bytes[start ..< start + length].firstIndex(of: 0) {
                let key = String(decoding: bytes[start ..< zero], as: UTF8.self)
                let value = String(decoding: bytes[(zero + 1) ..< (start + length)], as: UTF8.self)
                result[key] = value
            }
            if type == "IEND" { break }
            offset = start + length + 4
        }
        return result
    }

    /// Backslash escapes in prose: `\;` `\@` `\ ` stand for the character itself (a leading
    /// `;` would be a comment, a bare `@` a click wait). `\@` becomes a placeholder so the
    /// click-wait split below leaves it alone.
    static func unescape(_ text: String) -> String {
        guard text.contains("\\") else { return text }
        var result = ""
        var escaped = false
        for character in text {
            if escaped {
                result.append(character == "@" ? "\u{E000}" : character)
                escaped = false
            } else if character == "\\" {
                escaped = true
            } else {
                result.append(character)
            }
        }
        return result
    }

    public func show(text raw: String, interpreter: ArtemisInterpreter) -> ArtemisTagOutcome {
        noteTextPosition()
        let text = Self.unescape(raw)
        // `@` in prose waits for a click.
        var head = text, rest: String?
        if let at = text.firstIndex(of: "@") {
            head = String(text[..<at])
            rest = String(text[text.index(after: at)...])
        }
        printProse(head.replacingOccurrences(of: "\u{E000}", with: "@"))
        // A page too long for its box waits for a click and continues on a new page.
        let layer = messages.currentLayer
        if let offset = textRenderer.overflowOffset(layer) {
            let overflow = layer.truncate(atUTF16: offset).replacingOccurrences(of: "@", with: "\\@")
            messages.touch(layer)
            pendingText = overflow.trimmingCharacters(in: .newlines) + (rest.map { "@" + $0 } ?? "")
            overflowPageBreak = true
            wait = .click
            return .wait("click")
        }
        if let rest {
            pendingText = rest.isEmpty ? nil : rest
            wait = .click
            return .wait("click")
        }
        return .done
    }

    /// The click wait ends a page that overflowed: clear it before the rest.
    private var overflowPageBreak = false

    /// Prose is a `print` to the engine, so the game's print tag filter (read-text colour,
    /// name substitution) sees each stretch between click waits first.
    private func printProse(_ text: String) {
        guard !text.isEmpty else { return }
        let tag = ArtemisTag(name: "print", attributes: ["data": text], order: ["data"])
        if (try? interpreter.filterTag(tag)) == true { return }
        messages.append(text)
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
        // Layered message layers were drawn in the tree; the rest go on top.
        for layer in messages.layers.values.sorted(by: { $0.id < $1.id }) where !layer.layered { textRenderer.draw(layer, in: context) }
        return context.makeImage()
    }

    /// Message text as the Metal renderer draws it: each layer's text drawn over the stage at
    /// `scale` (redrawn when the layer changes), and how much of it has typed out. A page
    /// still typing comes as two images, its even and its odd lines, so revealing one line
    /// down to its descenders can't uncover the line under it.
    public func metalTexts(scale: Double) -> [ArtemisMetalRenderer.Text] {
        var texts: [ArtemisMetalRenderer.Text] = []
        for (id, layer) in messages.layers.sorted(by: { $0.key < $1.key }) {
            guard !layer.text.isEmpty, !layer.pageHidden else {
                textImages[id] = nil
                continue
            }
            let count = Int(layer.revealed)
            let typing = count < layer.text.count
            let parities: [Int?] = typing ? [0, 1] : [nil]
            for parity in parities {
                let key = id + (parity.map { "#\($0)" } ?? "")
                let image: CGImage
                if let cached = textImages[key], cached.revision == layer.revision, cached.scale == scale {
                    image = cached.image
                } else {
                    guard let drawn = textRenderer.image(for: layer, stageWidth: stage.width, stageHeight: stage.height,
                                                         scale: scale, parity: parity) else { continue }
                    textImages[key] = (layer.revision, scale, drawn)
                    image = drawn
                }
                let reveal = typing ? textRenderer.revealRects(for: layer, count: count, parity: parity) : nil
                texts.append(ArtemisMetalRenderer.Text(id: id, image: image, reveal: reveal, layered: layer.layered))
            }
            // Drop the other form's images once a page finishes typing or starts again.
            for key in typing ? [id] : [id + "#0", id + "#1"] { textImages[key] = nil }
        }
        return texts
    }
    private var textImages: [String: (revision: Int, scale: Double, image: CGImage)] = [:]

    /// Text that isn't layered shows only while its window does (the message layers' parent, 80).
    public var messageTextVisible: Bool { stage.layer("80").map(\.visible) ?? true }

    /// A pixel shader `lyshader` names, as Metal. Windows builds load HLSL (`system/shader/pc`)
    /// or compiled shaders; the same effects ship as GLSL ES for the mobile and Switch builds
    /// (`mb`, `sw`), which translate. Nil when there's none (built-in effects stand in).
    private func shaderProgram(file: String) -> ArtemisShaderProgram? {
        let path = file.replacingOccurrences(of: "\\", with: "/")
        let name = ((path as NSString).lastPathComponent as NSString).deletingPathExtension
        let folder = (path as NSString).deletingLastPathComponent
        var candidates = [folder + "/" + name + ".glsl"]
        for platform in ["mb", "sw"] { candidates.append("system/shader/\(platform)/\(name).glsl") }
        for candidate in candidates {
            guard let data = try? fileSystem.data(candidate), let source = String(data: data, encoding: .utf8)
                    ?? String(data: data, encoding: .shiftJIS) else { continue }
            if let program = ArtemisShaderProgram(glsl: source) { return program }
            record("shader \(candidate) didn't translate")
        }
        return nil
    }

    public func perform(_ tag: ArtemisTag, interpreter: ArtemisInterpreter) -> ArtemisTagOutcome {
        switch tag.name {
        case "lyc":
            stage.create(tag)
        case "lyshader":
            guard let id = tag["id"] else { break }
            stage.shaderPrograms[id] = tag["file"].flatMap(shaderProgram(file:))
        case "lyprop":
            if let id = tag["id"], id.hasPrefix("~") {
                // A message layer ("~" alone is the default one).
                let layer = messages.layer(id == "~" ? "default" : String(id.dropFirst()))
                layer.offsetX = tag.number("left", default: layer.offsetX)
                layer.offsetY = tag.number("top", default: layer.offsetY)
                layer.alpha = max(0, min(255, tag.number("alpha", default: layer.alpha)))
                if let visible = tag["visible"] { layer.visible = visible != "0" }
                messages.touch(layer)
            } else if tag["id"] == "!" {
                var attributes = tag.attributes
                attributes["id"] = ""
                stage.setProperties(ArtemisTag(name: "lyprop", attributes: attributes, order: tag.order))
            } else {
                stage.setProperties(tag)
            }
        case "lydel":
            stage.deleteLayer(tag["id"] ?? "")
        case "lytween":
            let end = stage.tween(tag, now: now)
            if tag["sync"] == "1", end.isFinite { return waitTime(until: end, skippable: tag["input"] == "1") }
        case "lytweendel":
            stage.deleteTweens(tag)
        case "tweenset":
            stage.beginTweenSet(now: now)
        case "/tweenset":
            stage.endTweenSet()
        case "anime":
            stage.anime(tag, now: now)
        case "lyedit":
            stage.edit(tag)
        case "lydrag":
            // Start dragging this layer with the finger that's down (sliders jump to it).
            if let id = tag["id"], !touches.isEmpty, let layer = stage.layer(id) { draggedLayer = layer }
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
            if let id = tag["video"] {
                guard stage.isVideoPlaying(id), !skipMode else { return .done }
                wait = .videoLayer(id, skippable: tag["input"] == "1")
                return .wait("video")
            }
            if let id = tag["se"] ?? tag["voice"] {
                guard let media, media.isSoundPlaying(id), !skipMode else { return .done }
                wait = .sound(id, skippable: tag["input"] == "1")
                return .wait("sound")
            }
            let time = tag.number("time")
            // input: 1 lets a tap end it; omitted/0 and 2 don't.
            if time > 0 { return waitTime(until: now + time, skippable: tag["input"] == "1") }
        case "reset":
            pendingExec = { $0.resetEngine() }
            return .wait("reset")
        case "file":
            switch tag["command"] {
            case "copy":
                if let src = tag["src"], let dst = tag["dst"] {
                    let data = (try? fileSystem.data(src)) ?? FileManager.default.contents(atPath: resolveSavePath(src).path)
                    let target = resolveSavePath(dst)
                    try? FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
                    try? data?.write(to: target, options: .atomic)
                }
            case "delete":
                // Only inside the save folder: games delete their own temporary saves.
                if let target = tag["target"] {
                    let url = resolveSavePath(target).standardizedFileURL
                    let root = resolveSavePath(".").standardizedFileURL.path
                    if url.path.hasPrefix(root) { try? FileManager.default.removeItem(at: url) }
                }
            default:
                break
            }
        case "setonclick", "setonrollover", "setonrollout", "setondrag", "setondragin", "setondragout":
            // Older spellings of [lyevent mode=init type=...].
            var attributes = tag.attributes
            attributes["type"] = String(tag.name.dropFirst(5))
            attributes["mode"] = "init"
            stage.event(ArtemisTag(name: "lyevent", attributes: attributes, order: Array(attributes.keys)))
        case "delonclick", "delonrollover", "delonrollout", "delondrag", "delondragin", "delondragout":
            var attributes = tag.attributes
            attributes["type"] = String(tag.name.dropFirst(5))
            attributes["mode"] = "reset"
            stage.event(ArtemisTag(name: "lyevent", attributes: attributes, order: Array(attributes.keys)))
        case "setonautomodein", "setonautomodeout", "setoncommandskipin", "setoncommandskipout",
             "setoncontrolskipin", "setoncontrolskipout", "setonhidein", "setonhideout", "setonbacklogin",
             "setonbacklogout", "setondirchg", "setonwindowbutton":
            engineHandlers[String(tag.name.dropFirst(5))] = tag.attributes
        case "delonautomodein", "delonautomodeout", "deloncommandskipin", "deloncommandskipout",
             "deloncontrolskipin", "deloncontrolskipout", "delonhidein", "delonhideout", "delonbacklogin",
             "delonbacklogout", "delondirchg", "delonwindowbutton":
            engineHandlers[String(tag.name.dropFirst(5))] = nil
        case "setonsoundfinish":
            engineHandlers["soundfinish:" + (tag["id"] ?? "")] = tag.attributes
        case "delonsoundfinish":
            engineHandlers["soundfinish:" + (tag["id"] ?? "")] = nil
        case "setonvideofinish":
            engineHandlers["videofinish:" + (tag["id"] ?? "")] = tag.attributes
        case "delonvideofinish":
            engineHandlers["videofinish:" + (tag["id"] ?? "")] = nil
        case "lyrename":
            if let id = tag["id"], let to = tag["to"] { stage.rename(id, to: to) }
        case "alreadyread":
            alreadyReadEnabled = tag["mode"] != "0"
        case "writebacklog":
            writeBacklog = tag["mode"] == "1"
        case "backlog":
            if let allow = tag["allow"] { backlogAllowed = allow != "0" }
            if let includeFont = tag["includefont"] { backlogIncludesFont = includeFont != "0" }
            if tag["clear"] == "1" { backlogPages.removeAll() }
        case "backloglayer":
            backlogLayer(tag)
        case "openbrowser":
            if let url = tag["url"].flatMap(URL.init(string:)) { media?.openURL(url) }
        case "vibrate":
            media?.vibrate()
        case "callnative":
            // Native plug-ins (a Windows Steam wrapper, say) don't exist here: answer empty.
            if let result = tag["result"] { interpreter.variables[result] = "" }
        case "httpget", "httppost":
            // No network for game scripts: report a failed request.
            if let result = tag["result"] ?? tag["name"] { interpreter.variables[result] = "" }
            if let status = tag["status"] { interpreter.variables[status] = "0" }
        case "purchase":
            if let result = tag["result"] ?? tag["name"] { interpreter.variables[result] = "0" }
        case "system:get_backlog_size":
            interpreter.variables[tag["name"] ?? ""] = String(backlogPages.count)
        case "system:get_backlog_tags":
            let name = tag["name"] ?? ""
            let index = Int(tag.number("page"))
            let page = index >= 0 && index < backlogPages.count ? backlogPages[index] : []
            let tags = tag["allfont"] == "1" ? page : page.filter { !$0.hasPrefix("font,") }
            for (i, data) in tags.enumerated() { interpreter.variables["\(name).\(i)"] = data }
            interpreter.variables["\(name).size"] = String(tags.count)
        case "system:get_message_tags":
            let name = tag["name"] ?? ""
            let layer = tag["id"].map(messages.layer) ?? messages.currentLayer
            let tags = pageTags(layer, includeFont: tag["allfont"] == "1")
            for (i, data) in tags.enumerated() { interpreter.variables["\(name).\(i)"] = data }
            interpreter.variables["\(name).size"] = String(tags.count)
        case "system:get_message_layer_width":
            interpreter.variables[tag["name"] ?? ""] = ArtemisValue.format(textRenderer.measure(messages.currentLayer).width.rounded())
        case "system:get_message_layer_height":
            interpreter.variables[tag["name"] ?? ""] = ArtemisValue.format(textRenderer.measure(messages.currentLayer).height.rounded())
        case "system:get_message_layer_line_width":
            interpreter.variables[tag["name"] ?? ""] = ArtemisValue.format(textRenderer.measure(messages.currentLayer).lastLineWidth.rounded())
        case "system:get_message_layer_indent_nest":
            interpreter.variables[tag["name"] ?? ""] = "0"
        case "system:get_sound_info":
            let name = tag["name"] ?? ""
            func store(_ prefix: String, _ info: (playing: Bool, gain: Double, pan: Double)?) {
                interpreter.variables[prefix + "playing"] = info?.playing == true ? "1" : "0"
                if let info {
                    interpreter.variables[prefix + "gain"] = ArtemisValue.format(info.gain.rounded())
                    interpreter.variables[prefix + "pan"] = ArtemisValue.format(info.pan.rounded())
                }
            }
            if let id = tag["id"] {
                store(name + ".", media?.soundInfo(id))
            } else {
                store(name + ".", media?.soundInfo(nil))
                let channels = media?.soundChannels ?? []
                for (i, id) in channels.enumerated() {
                    interpreter.variables["\(name).\(i).id"] = id
                    store("\(name).\(i).", media?.soundInfo(id))
                }
                interpreter.variables["\(name).size"] = String(channels.count)
            }
        case "system:get_font":
            interpreter.variables["\(tag["name"] ?? "").size"] = "0"
        case "setonpush":
            guard let key = tag["key"] else { break }
            var attributes = tag.attributes
            if attributes["handler"] == nil { attributes["key"] = nil }  // A handler is told its key.
            // In the newer generation a handler alone (`handler=calllua`, NUKITASHI's key
            // dispatch) counts too.
            if attributes["file"] == nil, attributes["label"] == nil, attributes["handler"] == nil || !interpreter.defersLuaCalls {
                keyHandlers[key] = nil
            } else {
                keyHandlers[key] = attributes
            }
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
            if traceWaits { record("trace: dialog \(tag["title"] ?? "") — \(tag["message"] ?? "")") }
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
            if let file = tag["file"] {
                save(to: file)
            } else if interpreter.defersLuaCalls {
                // No file: the system data only (the newer generation's syssave, after its
                // Lua has put sys/gscr/conf into g. variables).
                writeGlobals()
            } else {
                save(to: "save.dat")
            }
        case "load":
            if load(from: tag["file"] ?? "save.dat", transition: tag) {
                if wait == .none, interpreter.defersLuaCalls { return .done }
                return .wait("loaded")
            }
        case "takess":
            screenshot = renderSnapshot()
        case "savess":
            if let screenshot, let file = tag["file"] {
                // The engine adds .png (save screens look for "<name>.png").
                let name = (file as NSString).pathExtension.isEmpty ? file + ".png" : file
                writePNG(screenshot, to: resolveSavePath(name), width: tag["width"].flatMap(Int.init), height: tag["height"].flatMap(Int.init))
            }
        case "exec":
            switch tag["command"] {
            case "rclick": pendingExec = { $0.rightClick() }
            case "automode": setAutoMode(tag["mode"] != "0")
            case "skip": setSkipMode(tag["mode"].map { $0 != "0" } ?? !skipMode)
            case "hide": pendingExec = { $0.toggleHide() }
            case "backlog": pendingExec = { $0.requestBacklog() }
            default: break
            }
        case "hide":
            if let allow = tag["allow"] { hideAllowed = allow != "0" }
            if let window = tag["window"], !window.isEmpty {
                hideWindows = window.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
            }
        case "automode":
            if let allow = tag["allow"] {
                autoAllowed = allow != "0"
                if !autoAllowed { autoMode = false }
            }
            if let layer = tag["layer"] { autoModeLayer = layer.isEmpty ? nil : layer } else if tag["allow"] != nil { autoModeLayer = nil }
            if let value = tag["stopbyclick"] { autoStopByClick = value != "0" }
            if let value = tag["stopbystop"] { autoStopByStop = value != "0" }
        case "skip":
            if let allow = tag["allow"] {
                skipAllowed = allow != "0"
                if !skipAllowed { skipMode = false }
            }
            if let unread = tag["unread"] { skipUnread = unread == "1" }
        case "keyconfig" where interpreter.defersLuaCalls && tag["role"] == "0":
            // Role 0: the keys that answer a click wait. NUKITASHI sets only its virtual key
            // 124, which its Lua presses (e:overrideKey) when a click should advance.
            clickKeys = Set((tag["keys"] ?? "").split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) })
        case "rclick":
            if let allow = tag["allow"] { rightClickAllowed = allow != "0" }
            if let file = tag["file"], !file.isEmpty { rightClickFile = file }
        case "stop":
            wait = .stop
            return .wait("stop")
        case "@":
            // The newer generation's click wait, between clickStart and clickEnd.
            wait = .click
            return .wait("click")
        case "rp":
            recordHistory()
            let store = tag["backlog"].map { $0 == "1" } ?? writeBacklog
            if store { recordBacklogPage(messages.currentLayer) }
            messages.clear()
        case "rt":
            // omitblankline: no second newline in a row.
            if tag["omitblankline"] == "1", messages.currentLayer.text.hasSuffix("\n") || messages.currentLayer.text.isEmpty { break }
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
            if let layered = tag["layered"], let id = tag["id"] {
                messages.setLayered(id, layered == "1")
                if layered == "1" { stage.placeMessageLayer(id) } else { stage.removeMessageLayer(id) }
            }
            if traceMessages { record("chgmsg \(tag["id"] ?? "?") stack=\(tag["stack"] ?? "1") at \(interpreter.location)") }
        case "/chgmsg":
            messages.change(to: nil)
            if traceMessages { record("/chgmsg -> \(messages.current) at \(interpreter.location)") }
        case "font":
            messages.setFont(tag)
        case "/font":
            messages.popFont()
        case "fontinit":
            messages.resetFont()
        case "fontdefault":
            messages.setFont(tag, defaults: true)
        case "ruby":
            messages.setRuby(tag["text"])
        case "/ruby":
            messages.setRuby(nil)
        case "link":
            messages.beginLink(tag.attributes)
        case "/link":
            messages.beginLink(nil)
        case "linkenable":
            messages.setLinksEnabled(true)
        case "linkdisable":
            messages.setLinksEnabled(false)
        case "indent":
            var pairs: [Character: Character] = [:]
            let characters = Array(tag["pair"] ?? "")
            var i = 0
            while i + 1 < characters.count {
                pairs[characters[i]] = characters[i + 1]
                i += 2
            }
            messages.indentPairs = pairs
            messages.indentNest = tag["nest"] == "1"
        case "glyph":
            glyph = (tag["layer"], tag["rplayer"], tag.number("left"), tag.number("top"),
                     tag.number("rpleft"), tag.number("rptop"), tag["homing"] == "1")
            lastGlyphState = ""
            updateGlyph()
        case "print":
            messages.append(Self.unescape(tag["data"] ?? "").replacingOccurrences(of: "\u{E000}", with: "@"))
        case "video":
            guard let file = tag["file"] else { return .done }
            let ext = (file as NSString).pathExtension
            if let id = tag["id"] {
                // A video layer: decoded here, frames shown on the stage.
                guard let video = openVideoLayer(file, loop: tag["loop"] == "1") else {
                    log("video layer \(file) can't be decoded; skipped")
                    return .done
                }
                stage.createVideo(id: id, file: file, video: video)
                return .done
            }
            let source: ArtemisVideoSource? = fileSystem.url(file).map { .file($0) }
                ?? (try? fileSystem.data(file)).flatMap { $0.map { .data($0, fileExtension: ext) } }
            if let source, let media, media.playVideo(source, finished: { [weak self] in
                self?.videoFinished()
            }) {
                wait = .video
                return .wait("video")
            }
        case "splay", "sstop", "sfade", "seplay", "sestop", "sefade", "voice", "vstop",
             "sxfade", "span", "sepan", "sfadein", "sfadeout", "sefadein", "sefadeout":
            // skippable=1 effects stay silent while skipping.
            if tag.name == "seplay" || tag.name == "voice", tag["skippable"] == "1", skipMode { return .done }
            if ["splay", "sxfade", "sfadein"].contains(tag.name) { music = tag.attributes }
            if tag.name == "sstop" || tag.name == "sfadeout" { music = nil }
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
        case "system:get_message_size":
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
    /// Tags with nothing to do here: Windows-only or legacy (mouse, keyconfig, ime, slider,
    /// uidel, avoid, statusbar), line breaking CoreText already does (prohibit, wordparts,
    /// indentmodify), and the window caption; plus common game macros' names.
    static let acceptedSilently: Set<String> = [
        "caption", "autosave", "keyconfig", "mouse", "prohibit", "wordparts", "indentmodify", "ime", "slider",
        "uidel", "avoid", "statusbar", "setonwindowbutton", "delonwindowbutton",
        "btn_off", "info_hide_on", "info_hide_off",
        "lyevent_delete", "gesture_enable", "gesture_disable", "key_enable", "key_disable",
    ]

    // MARK: Click-wait glyph

    /// `[glyph]`: line-end and page-end glyph layers, offsets, and whether they follow the text.
    private var lastGlyphState = ""
    private var glyph: (layer: String?, pageLayer: String?, left: Double, top: Double, pageLeft: Double, pageTop: Double, homing: Bool)?

    /// Shows the glyph at a click wait (at the end of the text when homing) and hides it
    /// otherwise; the page-end glyph when the wait ends the page.
    private func updateGlyph() {
        guard let glyph else { return }
        // Only when the wait or the text changed (layout is not free).
        let state = "\(wait)|\(messages.revision)|\(messages.current)"
        guard state != lastGlyphState else { return }
        lastGlyphState = state
        let atPageEnd = wait == .click && pendingText == nil && interpreter.nextTagName == "rp"
        let active = (atPageEnd ? glyph.pageLayer : nil) ?? glyph.layer
        for id in [glyph.layer, glyph.pageLayer].compactMap({ $0 }) {
            stage.layer(id)?.visible = wait == .click && id == active
        }
        guard wait == .click, let id = active, glyph.homing, let layer = stage.layer(id),
              let end = textRenderer.endPoint(messages.currentLayer) else { return }
        layer.left = end.x + (atPageEnd ? glyph.pageLeft : glyph.left)
        layer.top = end.y + (atPageEnd ? glyph.pageTop : glyph.top)
    }

    /// A tap on a `[link]` in the page on screen: its jump, like a button.
    private func linkTarget(at point: CGPoint) -> [String: String]? {
        for layer in messages.layers.values where layer.visible && !layer.pageHidden && !layer.links.isEmpty {
            for (index, rect) in textRenderer.linkRects(layer) where rect.insetBy(dx: -6, dy: -4).contains(point) {
                return layer.links[index].attributes
            }
        }
        return nil
    }

    // MARK: Engine events (setonautomodein, setonsoundfinish, ...)

    /// Handlers by event: automodein, commandskipout, hidein, backlogin, soundfinish:<id>,
    /// videofinish:<id>, ...
    private var engineHandlers: [String: [String: String]] = [:]
    private var pendingEngineEvents: [String] = []
    /// Sounds and video layers seen playing, to notice when they finish.
    private var watchedPlaying: Set<String> = []

    private func queueEngineEvent(_ name: String) {
        if engineHandlers[name] != nil { pendingEngineEvents.append(name) }
    }

    private func runEngineEvents() {
        while !pendingEngineEvents.isEmpty {
            let name = pendingEngineEvents.removeFirst()
            let tagName = "seton" + (name.split(separator: ":").first.map(String.init) ?? name)
            guard let handler = engineHandlers[name] else {
                // The newer generation follows modes through its event filter alone
                // (NUKITASHI's flg.skip comes from setoncontrolskipin/out).
                if interpreter.defersLuaCalls { _ = interpreter.filterEvent(tagName: tagName, attributes: [:]) }
                continue
            }
            fireHandler(handler, tagName: tagName)
        }
    }

    private func watchFinishEvents() {
        for key in engineHandlers.keys {
            let playing: Bool
            if key.hasPrefix("soundfinish:") {
                let id = String(key.dropFirst("soundfinish:".count))
                playing = id.isEmpty ? (media?.soundInfo(nil)?.playing ?? false) : (media?.isSoundPlaying(id) ?? false)
            } else if key.hasPrefix("videofinish:") {
                playing = stage.isVideoPlaying(String(key.dropFirst("videofinish:".count)))
            } else {
                continue
            }
            if playing {
                watchedPlaying.insert(key)
            } else if watchedPlaying.remove(key) != nil {
                pendingEngineEvents.append(key)
            }
        }
    }

    // MARK: Modes

    private var autoAllowed = true
    private var autoModeLayer: String?
    private var autoStopByClick = true
    private var autoStopByStop = true
    private var skipAllowed = true
    private var skipUnread = false

    // MARK: Read text

    private var alreadyReadEnabled = true
    /// Script positions of text the reader has passed (kept with the globals).
    private var readPositions: Set<String> = []
    private var currentTextPosition: String?
    /// Whether the text on screen had been read before (s.status.alreadyread).
    private var currentTextRead = false

    private func noteTextPosition() {
        let position = interpreter.location
        guard position != currentTextPosition else { return }
        currentTextPosition = position
        currentTextRead = readPositions.contains(position)
    }

    private func markRead() {
        guard alreadyReadEnabled, let position = currentTextPosition else { return }
        readPositions.insert(position)
    }

    // MARK: Built-in backlog

    private var backlogAllowed = true
    private var backlogIncludesFont = true
    private var writeBacklog = true
    /// Pages, oldest first, each a list of `tag`-tag data strings that redraw it.
    private var backlogPages: [[String]] = []
    private var backlogMargins = (top: 0.0, middle: 0.0, bottom: 0.0)

    /// Tags that reproduce a message layer's page: its font, then the text line by line.
    private func pageTags(_ layer: ArtemisMessages.Layer, includeFont: Bool) -> [String] {
        let annotation = interpreter.value(of: "s.backlog.annotation") ?? ""
        var tags: [String] = []
        if includeFont {
            let f = layer.font
            var pairs: [(String, String)] = [("left", ArtemisValue.format(f.left)), ("top", ArtemisValue.format(f.top)),
                                            ("width", ArtemisValue.format(f.width)), ("height", ArtemisValue.format(f.height)),
                                            ("size", ArtemisValue.format(f.size)), ("color", String(format: "0x%06X", f.color)),
                                            ("align", f.align), ("spacetop", ArtemisValue.format(f.spaceTop)),
                                            ("spacemiddle", ArtemisValue.format(f.lineSpacing)),
                                            ("spacebottom", ArtemisValue.format(f.spaceBottom)),
                                            ("rubysize", ArtemisValue.format(f.rubySize)), ("kerning", ArtemisValue.format(f.kerning))]
            if let face = f.face { pairs.insert(("face", face), at: 0) }
            tags.append(ArtemisInterpreter.tagData("font", pairs))
        }
        let lines = layer.text.components(separatedBy: "\n")
        for (i, line) in lines.enumerated() {
            if !line.isEmpty {
                var pairs = [("data", line)]
                if !annotation.isEmpty { pairs.append(("annotation", annotation)) }
                tags.append(ArtemisInterpreter.tagData("print", pairs))
            }
            if i < lines.count - 1 { tags.append("rt") }
        }
        return tags
    }

    private func recordBacklogPage(_ layer: ArtemisMessages.Layer) {
        guard !layer.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        let page = pageTags(layer, includeFont: true)
        guard backlogPages.last != page else { return }
        backlogPages.append(page)
        if backlogPages.count > 1000 { backlogPages.removeFirst(backlogPages.count - 1000) }
        backlogFonts.append(layer.font)
        backlogTexts.append(layer.text)
        if backlogFonts.count > 1000 {
            backlogFonts.removeFirst(backlogFonts.count - 1000)
            backlogTexts.removeFirst(backlogTexts.count - 1000)
        }
    }

    private var backlogFonts: [ArtemisMessages.Font] = []
    private var backlogTexts: [String] = []
    /// Height of the rendered backlog image (`backloglayer get_scroll_max`).
    private var backlogImageHeight = 0.0

    /// `[backloglayer]` (newer engines): renders every backlog page into a layer, newest at
    /// the bottom of the screen; the game scrolls it by moving the layer's top.
    private func backlogLayer(_ tag: ArtemisTag) {
        if tag["set_margin_top"] != nil || tag["set_margin_middle"] != nil || tag["set_margin_bottom"] != nil {
            backlogMargins = (tag.number("set_margin_top", default: backlogMargins.top),
                              tag.number("set_margin_middle", default: backlogMargins.middle),
                              tag.number("set_margin_bottom", default: backlogMargins.bottom))
        }
        if let name = tag["get_scroll_max"] {
            interpreter.variables[name] = ArtemisValue.format(max(0, backlogImageHeight - stage.height).rounded())
        }
        if let bind = tag["bind"] {
            if bind == "1", let id = tag["id"] {
                boundBacklogLayer = id
                renderBacklogLayer(id)
            } else if let id = boundBacklogLayer {
                stage.deleteLayer(id + ".~backlog")
                boundBacklogLayer = nil
            }
        }
    }

    private var boundBacklogLayer: String?

    private func renderBacklogLayer(_ id: String) {
        var heights: [Double] = []
        for (font, text) in zip(backlogFonts, backlogTexts) {
            let page = ArtemisMessages.Layer(id: "backlog")
            page.font = font
            page.text = text
            heights.append(textRenderer.measure(page).height)
        }
        let total = backlogMargins.top + heights.reduce(0, +)
            + Double(max(0, heights.count - 1)) * backlogMargins.middle + backlogMargins.bottom
        backlogImageHeight = max(total, 1)
        let width = Int(stage.width), height = Int(backlogImageHeight.rounded(.up))
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
        context.translateBy(x: 0, y: CGFloat(height))
        context.scaleBy(x: 1, y: -1)
        var y = backlogMargins.top
        for ((font, text), pageHeight) in zip(zip(backlogFonts, backlogTexts), heights) {
            let page = ArtemisMessages.Layer(id: "backlog")
            page.font = font
            page.font.top = y
            page.text = text
            textRenderer.draw(page, in: context)
            y += pageHeight + backlogMargins.middle
        }
        let layer = stage.ensureLayer(id + ".~backlog")
        layer.image = context.makeImage()
        layer.width = Double(width)
        layer.height = Double(height)
        layer.left = 0
        // Newest page at the bottom of the screen when the bound layer sits at top 0.
        layer.top = stage.height - Double(height)
        stage.present(transition: nil)
    }

    /// The reader asked for the backlog (Shiori's swipe, [exec command=backlog]): the game's
    /// own backlog if it binds one to the wheel/arrow keys, else nil so the presenter shows
    /// Shiori's.
    @discardableResult
    public func requestBacklog() -> Bool {
        for key in ["136", "38", "40"] where keyHandlers[key] != nil {
            if press(key: key) { return true }
        }
        queueEngineEvent("backlogin")
        return false
    }

    // MARK: Reset

    /// `[reset]`: the engine restarts from the boot script, keeping only `g.` variables.
    private func resetEngine() {
        writeGlobals()
        let globals = interpreter.variables.filter { Self.isPersistent($0.key) }
        stage.deleteLayer("")
        stage.present(transition: nil)
        messages.restore([], current: "default", stack: [], defaultFont: ArtemisMessages.Font())
        media?.soundTag(ArtemisTag(name: "sstop", attributes: [:], order: [])) { _ in nil }
        interpreter.resetForReboot(keeping: globals)
        keyHandlers = [:]
        engineHandlers = [:]
        savedWaits = []
        pendingText = nil
        hidden = false
        autoMode = false
        skipMode = false
        rightClickAllowed = true
        rightClickFile = "rclick.iet"
        wait = .none
        do {
            try interpreter.boot(Self.bootScript(fileSystem))
        } catch {
            failure = "reset: \(error)"
            return
        }
        record("engine reset")
        runInterpreter()
    }

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
            variables: interpreter.variables.filter { !$0.key.hasPrefix("t.") && !Self.isPersistent($0.key) },
            layers: stage.savedLayers(), events: stage.savedEvents(),
            messages: messageLayers, currentMessage: current, messageStack: stack, defaultFont: defaultFont,
            wait: waitName(wait), pendingText: pendingText, keyHandlers: keyHandlers,
            rightClickFile: rightClickFile, rightClickAllowed: rightClickAllowed, hideWindows: hideWindows, music: music)
    }

    private func save(to file: String) {
        interpreter.callLuaEvent("onSave")
        let state = checkpoint ?? captureState(wait: savedWaits.first ?? wait)
        let url = resolveSavePath(file)
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(state).write(to: url, options: .atomic)
            writeGlobals()
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
        guard restore(state, transition: transition) else { return false }
        record("loaded \(url.lastPathComponent)")
        return true
    }

    /// Puts a saved state back (a save file or e:loadFromMemory).
    private func restore(_ state: ArtemisSaveState, transition: ArtemisTag?) -> Bool {
        do {
            // A save taken mid-script (the newer generation saves from inside save.asb)
            // carries on from there.
            try interpreter.restore(frames: state.frames, running: state.wait == "none" && interpreter.defersLuaCalls)
        } catch {
            record("load failed: \(error)")
            return false
        }
        let globals = interpreter.variables.filter { Self.isPersistent($0.key) }
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
        interpreter.callLuaEvent("onLoad")
        return true
    }

    private var globalsURL: URL { resolveSavePath("global.json") }

    private func loadGlobals() {
        if let data = try? Data(contentsOf: resolveSavePath("read.json")),
           let positions = try? JSONDecoder().decode([String].self, from: data) {
            readPositions = Set(positions)
        }
        guard let data = try? Data(contentsOf: globalsURL),
              let globals = try? JSONDecoder().decode([String: String].self, from: data) else { return }
        interpreter.variables.merge(globals) { _, saved in saved }
    }

    /// Writes `g.` variables (they live outside save slots). Call when leaving the game too.
    /// Kept between sessions: `g.` variables, and the system variables the engine keeps
    /// in its system.dat (volumes, auto speed).
    static func isPersistent(_ name: String) -> Bool {
        name.hasPrefix("g.") || ["s.bgmvol", "s.sevol", "s.videovol", "s.automodewait"].contains(name)
            || name.hasPrefix("s.segain.")
    }

    /// Writes the `g.` variables (and read lines) out, as when the app leaves the game. The
    /// newer generation keeps its system, global and config data in Lua tables that reach the
    /// `g.` variables only when it saves (its onSave handler), so that runs first: a language
    /// picked at first launch would otherwise be asked again.
    public func saveGlobals() {
        if interpreter.defersLuaCalls { interpreter.callLuaEvent("onSave") }
        writeGlobals()
    }

    private func writeGlobals() {
        try? JSONEncoder().encode(Array(readPositions).sorted()).write(to: resolveSavePath("read.json"), options: .atomic)
        let globals = interpreter.variables.filter { Self.isPersistent($0.key) }
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
        for raw in decodeScriptText(data, encoding: fs.encoding).split(whereSeparator: \.isNewline) {
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
