import CryptoKit
import CLua
import CoreGraphics
import Foundation

/// A tag ready for the host: attribute expressions evaluated.
public struct ArtemisTag: Sendable, CustomStringConvertible {
    public let name: String
    public let attributes: [String: String]
    /// Attribute order as written (some tags care, e.g. for positional data).
    public let order: [String]

    public subscript(_ key: String) -> String? { attributes[key] }

    public func number(_ key: String, default value: Double = 0) -> Double {
        attributes[key].flatMap { ArtemisValue.number(from: $0) } ?? value
    }

    public var description: String {
        "[\(name)" + order.map { " \($0)=\"\(attributes[$0] ?? "")\"" }.joined() + "]"
    }
}

/// What a tag did, as reported by the host.
public enum ArtemisTagOutcome: Sendable {
    /// Done; carry on.
    case done
    /// The host doesn't know this tag (logged once per name).
    case unhandled
    /// Pause the script until the host resumes it (a click, a timer, a transition).
    case wait(String)
}

/// Presentation and input for the interpreter: layers, text, sound, waits.
@MainActor
public protocol ArtemisHost: AnyObject {
    func perform(_ tag: ArtemisTag, interpreter: ArtemisInterpreter) -> ArtemisTagOutcome
    func show(text: String, interpreter: ArtemisInterpreter) -> ArtemisTagOutcome
    func log(_ message: String)
    /// Engine state Lua asks for that only the host knows (time, input, wait status,
    /// memory saves); nil answers nil.
    func luaQuery(_ name: String, _ arguments: [String], interpreter: ArtemisInterpreter) -> String?
}

public extension ArtemisHost {
    func luaQuery(_ name: String, _ arguments: [String], interpreter: ArtemisInterpreter) -> String? { nil }
}

public struct ArtemisScriptError: Error, CustomStringConvertible {
    public let description: String
}

/// Runs an older-generation Artemis game's scripts: tags, labels, macros, expressions,
/// variables and Lua. Everything visible is delegated to the host.
@MainActor
public final class ArtemisInterpreter {
    public enum State: Equatable, Sendable {
        case running
        case waiting(String)
        case finished
        case failed(String)
    }

    struct Frame {
        var script: ArtemisScript
        var pc: Int
        /// Macro attributes (and `local` variables) visible by name inside this frame.
        var locals: [String: String]
        var isMacro: Bool
        /// Set for calls made from Lua: running stops when this frame returns.
        var barrier = false
        /// An event that interrupted a wait (a button during a text wait, right-click):
        /// returning from it hands the wait back to the host.
        var interrupt = false
        /// The right-click script's frame (a second right-click unwinds to its *leave).
        var rightClick = false
        /// A newer-generation event handler's own frame (its serial): a jump in the handler
        /// lands here, and its `return` comes back to the wait below.
        var event = 0
    }

    /// Reported as the waiting reason when an interrupt returns.
    public static let interruptReturned = "interrupt-returned"

    public let fileSystem: ArtemisFileSystem
    public weak var host: ArtemisHost?

    /// What `[var system="os"]` answers: "iphone", unless the game is a PC build of the Lua ADV
    /// framework with tables for Windows and none for iOS (NUKITASHI's `system/table/list_*.tbl`;
    /// its Android table is a stub): then "windows", whose tables are complete. The framework
    /// still turns touch on for Windows.
    lazy var reportedOS: String = {
        let tables = fileSystem.files.keys.map { $0.lowercased() }.filter { $0.hasPrefix("system/table/list_") }
        let hasIOS = tables.contains { $0.hasPrefix("system/table/list_ios") }
        let hasWindows = tables.contains { $0.hasPrefix("system/table/list_windows") }
        return !hasIOS && hasWindows ? "windows" : "iphone"
    }()
    public private(set) var state: State = .running
    public var variables: [String: String] = [:]
    /// Tag name -> (file, label) for tags defined by `macroadd`.
    public internal(set) var macros: [String: (file: String, label: String)] = [:]
    /// Positional parameter names from tag.ini.
    public private(set) var tagParameters: [String: [String]] = [:]

    var frames: [Frame] = []
    private var scripts: [String: ArtemisScript] = [:]
    nonisolated(unsafe) private var lua: OpaquePointer?
    nonisolated(unsafe) private var luaHost = ArtemisLuaHost()
    private var reportedUnhandled: Set<String> = []
    /// Tags the game's tag filter is handling now. The older games' filters never see tags they
    /// issue themselves; the newer generation's (its Lua `tags` table) see any but their own
    /// (`tags.system_info` issues [autoplay], which `tags.autoplay` handles).
    private var filteringTags: Set<String> = []
    /// Commands run, for runaway-loop protection in headless runs.
    public private(set) var steps = 0

    public init(fileSystem: ArtemisFileSystem, stageWidth: Int, stageHeight: Int) {
        self.fileSystem = fileSystem
        if let data = try? fileSystem.data("tag.ini") { tagParameters = Self.parseTagIni(decodeScriptText(data, encoding: fileSystem.encoding)) }
        variables["sc.width"] = String(stageWidth)
        variables["sc.height"] = String(stageHeight)
        variables["os.name"] = "iphone"
        startLua(stageWidth: stageWidth, stageHeight: stageHeight)
    }

    deinit {
        if let lua { artemis_lua_close(lua) }
    }

    /// `[reset]`: a fresh engine (new Lua state, no macros or variables) that keeps `g.`.
    public func resetForReboot(keeping globals: [String: String]) {
        let width = Int(variables["sc.width"] ?? "") ?? 1280, height = Int(variables["sc.height"] ?? "") ?? 720
        if let lua { artemis_lua_close(lua) }
        lua = nil
        frames = []
        macros = [:]
        queuedTags = []
        luaEventHandlers = [:]
        variables = globals
        variables["sc.width"] = String(width)
        variables["sc.height"] = String(height)
        variables["os.name"] = "iphone"
        startLua(stageWidth: width, stageHeight: height)
    }

    // MARK: - Running

    /// Starts at the top of a script (the game's BOOT script).
    public func boot(_ path: String) throws {
        frames = [Frame(script: try script(path), pc: 0, locals: [:], isMacro: false)]
        state = .running
    }

    /// Runs until the script waits, ends or fails.
    @discardableResult
    public func run(maxSteps: Int = .max) -> State {
        if case .waiting = state { state = .running }
        runQueuedTags()
        var budget = maxSteps
        while case .running = state, budget > 0 {
            step()
            budget -= 1
        }
        return state
    }

    /// Resumes after a wait the host has finished.
    @discardableResult
    public func resume() -> State {
        state = .running
        return run()
    }

    /// The tag the script runs next, if the next command is a tag (glyph placement).
    public var nextTagName: String? {
        guard let frame = frames.last, frame.pc < frame.script.commands.count else { return nil }
        if case let .tag(name, _) = frame.script.commands[frame.pc].kind { return name }
        return nil
    }

    /// Where the script is, for logs and `e:getScriptStack()`.
    public var location: String {
        guard let frame = frames.last else { return "(finished)" }
        let line = frame.pc < frame.script.commands.count ? frame.script.commands[frame.pc].line : -1
        return "\(frame.script.path):\(line)"
    }

    private func step() {
        guard var frame = frames.last else {
            state = .finished
            return
        }
        guard frame.pc < frame.script.commands.count else {
            // Falling off the end of a file returns, as if it ended with [return].
            if frames.count > 1 { doReturn() } else { state = .finished; frames.removeAll() }
            return
        }
        let command = frame.script.commands[frame.pc]
        frame.pc += 1
        frames[frames.count - 1] = frame
        steps += 1
        do {
            try execute(command)
        } catch {
            state = .failed("\(location): \(error)")
        }
    }

    private func execute(_ command: ScriptCommand) throws {
        switch command.kind {
        case .label:
            break
        case let .text(text):
            if let host, case let .wait(reason) = host.show(text: text, interpreter: self) { state = .waiting(reason) }
        case let .lua(code):
            // Like the engine, a broken Lua block is reported and skipped, not fatal.
            do {
                try runLua(code, chunk: "\(frames.last?.script.path ?? "?"):\(command.line)")
            } catch {
                host?.log("lua error (continuing): \(error)")
            }
        case let .lineTag(name, arguments):
            let names = tagParameters[name] ?? []
            var attributes: [(String, String)] = []
            for (index, argument) in arguments.enumerated() {
                attributes.append((index < names.count ? names[index] : String(index), argument))
            }
            try perform(name: name, rawAttributes: attributes)
        case let .tag(name, attributes):
            try perform(name: name, rawAttributes: attributes)
        }
    }

    // MARK: - Tags

    private func perform(name: String, rawAttributes: [(String, String)]) throws {
        switch name {
        case "if":
            try branch(condition: rawAttributes)
            return
        case "elseif", "else":
            // Reached in normal flow, the branch above was taken and is done: leave via /if.
            // (A chosen elseif/else is entered just past its tag, so it never arrives here.)
            skipToEndIf()
            return
        case "/if":
            return
        case "loop":
            try loopStart(rawAttributes)
            return
        case "/loop":
            loopEnd()
            return
        default:
            break
        }
        let tag = try evaluate(name: name, rawAttributes)
        // Tags in a queued frame came from Lua and went through the filter when issued.
        if frames.last?.script.path != Self.queuePath, try filterTag(tag) { return }
        try perform(tag)
    }

    /// Runs the game's `e:setTagFilter` function for this tag, if any. True when the filter
    /// handled the tag and it shouldn't run. Tags the filter issues itself aren't filtered.
    func filterTag(_ tag: ArtemisTag) throws -> Bool {
        guard let lua, defersLuaCalls ? !filteringTags.contains(tag.name) : filteringTags.isEmpty else { return false }
        filteringTags.insert(tag.name)
        defer { filteringTags.remove(tag.name) }
        let encoding = fileSystem.encoding
        // A trailing nil keeps the buffers non-empty for tags without parameters.
        var keys: [UnsafeMutablePointer<CChar>?] = tag.order.map { strdup(luaBytes($0, encoding)) } + [nil]
        var values: [UnsafeMutablePointer<CChar>?] = tag.order.map { strdup(luaBytes(tag[$0] ?? "", encoding)) } + [nil]
        defer {
            keys.forEach { free($0) }
            values.forEach { free($0) }
        }
        var error: UnsafeMutablePointer<CChar>?
        let result = keys.withUnsafeMutableBufferPointer { keyBuffer in
            values.withUnsafeMutableBufferPointer { valueBuffer in
                keyBuffer.baseAddress!.withMemoryRebound(to: UnsafePointer<CChar>?.self, capacity: keyBuffer.count) { k in
                    valueBuffer.baseAddress!.withMemoryRebound(to: UnsafePointer<CChar>?.self, capacity: valueBuffer.count) { v in
                        artemis_lua_filter_tag(lua, luaBytes(tag.name, encoding), Int32(tag.order.count), k, v, &error)
                    }
                }
            }
        }
        if let error {
            host?.log("lua tag filter \(tag.name) (continuing): \(luaString(error, encoding))")
            free(error)
        }
        // What the filter queued runs once its Lua returns, before the next command (the
        // framework's [exkey]: a queued [@] that waits for the click it is named after).
        if luaDepth == 0, defersLuaCalls, !holdingDeferredLua { flushDeferredLua() }
        return result == 1
    }

    /// Runs one evaluated tag: control flow and variables here, macros as calls, the rest
    /// through the host.
    public func perform(_ tag: ArtemisTag) throws {
        switch tag.name {
        case "call":
            try call(file: tag["file"], label: tag["label"], locals: [:], isMacro: false)
        case "jump":
            try jump(file: tag["file"], label: tag["label"])
        case "return":
            doReturn()
        case "var":
            try setVariable(tag)
        case "calllua":
            do { try callLua(tag) } catch {
                host?.log("lua error (continuing) at \(location): \(error)")
                // ARTEMIS_LUA_ON_ERROR=<lua> (debugging): runs after each Lua error.
                if let code = ProcessInfo.processInfo.environment["ARTEMIS_LUA_ON_ERROR"] {
                    do { try runLua(Data(code.utf8), chunk: "on-error") } catch { host?.log("on-error: \(error)") }
                }
            }
        case "macroadd":
            try addMacros(file: tag["file"] ?? "")
        case "macrodel":
            let file = (tag["file"] ?? "").lowercased()
            macros = macros.filter { $0.value.file.lowercased() != file }
        case "tag":
            // [tag data="name,key,value,..."]: runs any tag; backslash escapes commas.
            if let tag = Self.tag(fromData: tag["data"] ?? "") { try perform(tag) }
        case "debugprint", "debug", "debugreload":
            host?.log("debug: \(tag["data"] ?? tag.description)")
        case "exit":
            state = .finished
        default:
            if let macro = macros[tag.name] {
                try call(file: macro.file, label: macro.label, locals: tag.attributes, isMacro: true)
                return
            }
            guard let host else { return }
            switch host.perform(tag, interpreter: self) {
            case .done:
                break
            case let .wait(reason):
                state = .waiting(reason)
            case .unhandled:
                if reportedUnhandled.insert(tag.name).inserted {
                    host.log("unhandled tag \(tag) at \(location)")
                }
            }
        }
    }

    /// Evaluates attribute values that are expressions (`$...`).
    func evaluate(name: String, _ raw: [(String, String)]) throws -> ArtemisTag {
        var attributes: [String: String] = [:]
        var order: [String] = []
        for (key, value) in raw {
            let evaluated: String
            if value.hasPrefix("$$") {
                // Indirection: the expression names the variable to read.
                let name = try expression(String(value.dropFirst(2))).text
                evaluated = self.value(of: name) ?? "0"
            } else if value.hasPrefix("$") {
                evaluated = try expression(String(value.dropFirst())).text
            } else {
                evaluated = value
            }
            if attributes[key] == nil { order.append(key) }
            attributes[key] = evaluated
        }
        return ArtemisTag(name: name, attributes: attributes, order: order)
    }

    /// Evaluates an expression. Malformed ones (games ship a few, e.g. a missing `+`) are
    /// logged once and read as empty, rather than stopping the game.
    public func expression(_ source: String) throws -> ArtemisValue {
        do {
            return try ArtemisExpression.evaluate(source) { self.value(of: $0) }
        } catch {
            if reportedUnhandled.insert("expr:" + source).inserted {
                host?.log("bad expression at \(location) (read as empty): \(error)")
            }
            return .string("")
        }
    }

    /// A variable as scripts see it: the innermost macro's attributes first.
    /// The last pointer/touch position (stage pixels), for `e:getMousePoint()`.
    public var pointer = CGPoint.zero
    /// Lua functions set with `e:setEventHandler` (onEnterFrame, onClickWaitIn, ...).
    public private(set) var luaEventHandlers: [String: String] = [:]

    /// Calls a Lua event handler, if set (errors are logged).
    public func callLuaEvent(_ event: String) {
        guard let function = luaEventHandlers[event] else { return }
        do {
            try callLua(ArtemisTag(name: "calllua", attributes: ["function": function], order: ["function"]))
        } catch {
            host?.log("lua \(event) (\(function)): \(error)")
            luaEventHandlers[event] = nil
        }
    }

    /// Read-only system variables the engine provides (`s.current_message_layer`, ...).
    public var systemVariable: ((String) -> String?)?

    public func value(of name: String) -> String? {
        if name.hasPrefix("s."), let value = systemVariable?(name) { return value }
        for frame in frames.reversed() {
            if let local = frame.locals[name] { return local }
            if frame.isMacro { break }
        }
        return variables[name]
    }

    // MARK: Control flow

    private func branch(condition raw: [(String, String)]) throws {
        let index = frames[frames.count - 1].pc - 1
        let script = frames[frames.count - 1].script
        if try condition(raw) { return }
        // Not taken: the first true elseif, else the else, else past /if.
        var next = script.nextBranch[index]
        while let candidate = next {
            guard case let .tag(candidateName, attributes) = script.commands[candidate].kind else { break }
            if candidateName == "elseif", try !condition(attributes) {
                next = script.nextBranch[candidate]
                continue
            }
            frames[frames.count - 1].pc = candidate + 1
            return
        }
    }

    private func condition(_ raw: [(String, String)]) throws -> Bool {
        // "estiamte" is a typo some games ship; the engine evidently accepts it.
        let estimate = raw.first { ["estimate", "estiamte", "exp"].contains($0.0) }?.1 ?? "0"
        let source = estimate.hasPrefix("$") ? String(estimate.dropFirst()) : estimate
        return try expression(source).isTrue
    }

    private func skipToEndIf() {
        let index = frames[frames.count - 1].pc - 1
        if let end = frames[frames.count - 1].script.endIf[index] {
            frames[frames.count - 1].pc = end + 1
        }
    }

    private func loopStart(_ raw: [(String, String)]) throws {
        let index = frames[frames.count - 1].pc - 1
        if try !condition(raw.isEmpty ? [("estimate", "1")] : raw), let end = frames[frames.count - 1].script.loopPartner[index] {
            frames[frames.count - 1].pc = end + 1
        }
    }

    private func loopEnd() {
        let index = frames[frames.count - 1].pc - 1
        if let start = frames[frames.count - 1].script.loopPartner[index] {
            frames[frames.count - 1].pc = start
        }
    }

    // MARK: Calls

    public func script(_ path: String) throws -> ArtemisScript {
        let key = path.replacingOccurrences(of: "\\", with: "/").lowercased()
        if let script = scripts[key] { return script }
        guard let data = try fileSystem.data(path) else { throw ArtemisScriptError(description: "no script \(path)") }
        let script = ArtemisScript(path: path, data: data, encoding: fileSystem.encoding)
        scripts[key] = script
        return script
    }

    private func target(file: String?, label: String?) throws -> (ArtemisScript, Int) {
        let script = try file.flatMap { $0.isEmpty ? nil : $0 }.map { try self.script($0) } ?? frames.last!.script
        guard let label, !label.isEmpty else { return (script, 0) }
        let name = label.hasPrefix("*") ? String(label.dropFirst()) : label
        guard let index = script.labels[name] else {
            throw ArtemisScriptError(description: "no label *\(name) in \(script.path)")
        }
        return (script, index)
    }

    func call(file: String?, label: String?, locals: [String: String], isMacro: Bool, barrier: Bool = false) throws {
        let (script, index) = try target(file: file, label: label)
        frames.append(Frame(script: script, pc: index, locals: locals, isMacro: isMacro, barrier: barrier))
    }

    private func jump(file: String?, label: String?) throws {
        // A jump to a label the script doesn't define (shipped typos, e.g. Memory's Dogma's
        // `selend52_end`) is reported and skipped, so the reader isn't stranded.
        guard let (script, index) = try? target(file: file, label: label) else {
            host?.log("jump to missing \(file ?? "") *\(label ?? "") at \(location); continuing")
            return
        }
        frames[frames.count - 1].script = script
        frames[frames.count - 1].pc = index
    }

    private func doReturn() {
        guard !frames.isEmpty else { return }
        let finished = frames.removeLast()
        if frames.isEmpty { state = .finished }
        if finished.barrier { barrierReached = true }
        if finished.interrupt, !frames.isEmpty { state = .waiting(Self.interruptReturned) }
    }

    // MARK: Save state

    func savedFrames(upTo limit: Int? = nil) -> [ArtemisSaveState.Frame] {
        frames.prefix(limit ?? frames.count).filter { $0.script.path != Self.queuePath }.map {
            .init(file: $0.script.path, pc: $0.pc, locals: $0.locals, isMacro: $0.isMacro,
                  interrupt: $0.interrupt, rightClick: $0.rightClick)
        }
    }

    /// Index of the first interrupt frame (a button or the right-click menu), if any.
    var firstInterruptIndex: Int? { frames.firstIndex { $0.interrupt } }

    func restore(frames saved: [ArtemisSaveState.Frame], running: Bool = false) throws {
        frames = try saved.map {
            Frame(script: try script($0.file), pc: $0.pc, locals: $0.locals, isMacro: $0.isMacro,
                  interrupt: $0.interrupt, rightClick: $0.rightClick)
        }
        state = running ? .running : .waiting("loaded")
    }

    /// Right-click (`[rclick]`): runs the right-click script as an interrupt; inside it, a
    /// second right-click unwinds its calls and goes to its `*leave` label.
    public func rightClick(file: String) throws {
        if let index = frames.lastIndex(where: { $0.rightClick }) {
            frames.removeSubrange((index + 1)...)
            let script = frames[index].script
            frames[index].pc = script.labels["leave"] ?? script.commands.count
        } else {
            let script = try script(file)
            frames.append(Frame(script: script, pc: 0, locals: [:], isMacro: false, interrupt: true, rightClick: true))
        }
        state = .running
    }

    public var inRightClickScript: Bool { frames.contains { $0.rightClick } }

    private var barrierReached = false

    /// A layer event fired while the script waits (a button press at `[stop]`): runs the
    /// event's `handler` tag first, then calls (`call="1"`, coming back to the wait) or
    /// jumps to its `file`/`label`.
    /// With `interrupt`, the event fired during a wait that isn't a [stop] (a text wait):
    /// a call returns to that wait instead of re-running a command.
    /// Whether an event handler fired during a non-[stop] wait runs as an interrupt that
    /// returns to that wait (the newer generation's handler-only key and button events).
    public func returnsToWait(_ attributes: [String: String], interrupt: Bool) -> Bool {
        interrupt && defersLuaCalls && !frames.isEmpty && attributes["file"] == nil && attributes["label"] == nil
            && attributes["call"] != "1"
    }

    public func fireEvent(_ attributes: [String: String], interrupt: Bool = false) throws {
        let file = attributes["file"], label = attributes["label"]
        if file != nil || label != nil {
            if attributes["call"] == "1" {
                if interrupt {
                    let (script, index) = try target(file: file, label: label)
                    frames.append(Frame(script: script, pc: index, locals: [:], isMacro: false, interrupt: true))
                } else {
                    // Re-run the waiting command (usually [stop]) after the call returns.
                    frames[frames.count - 1].pc = max(0, frames[frames.count - 1].pc - 1)
                    try call(file: file, label: label, locals: [:], isMacro: false)
                }
            } else {
                try jump(file: file, label: label)
            }
        }
        // The newer generation runs a handler with nowhere to go as a call that comes back to
        // the wait ([stop], or [@] beside text): NUKITASHI's buttons either only note the click
        // (`calllua btn_clickex`) or jump to a `popfuncNN` label that ends in `return`.
        var eventSerial = 0
        if returnsToWait(attributes, interrupt: interrupt) {
            // During text or a timed wait: an empty frame to come back from. A handler that
            // jumps (right-click's MWOFF: `jump ui.asb*msgoff`, which ends in `return`) runs
            // in it; one that doesn't falls off its end. Either way the wait resumes.
            eventSerials += 1
            eventSerial = eventSerials
            var frame = Frame(script: ArtemisScript(path: Self.queuePath, commands: []), pc: 0, locals: [:], isMacro: false, interrupt: true)
            frame.event = eventSerial
            frames.append(frame)
        } else if file == nil, label == nil, !interrupt, defersLuaCalls, !frames.isEmpty {
            frames[frames.count - 1].pc = max(0, frames[frames.count - 1].pc - 1)
            eventSerials += 1
            eventSerial = eventSerials
            var frame = frames[frames.count - 1]
            frame.event = eventSerial
            frame.barrier = false
            frame.interrupt = false
            frame.rightClick = false
            frames.append(frame)
        }
        if let handler = attributes["handler"], !handler.isEmpty {
            // The handler tag sees every parameter of the event (lyevent.txt), file and
            // label included: handler="jump" jumps to the event's own target.
            var handlerAttributes = attributes
            handlerAttributes["handler"] = nil
            if eventSerial != 0 { holdingDeferredLua = true }
            defer { holdingDeferredLua = false }
            try perform(ArtemisTag(name: handler, attributes: handlerAttributes, order: handlerAttributes.keys.sorted()))
        }
        if eventSerial != 0 {
            // A handler that didn't jump leaves its frame as it was: drop it, so what it
            // queued runs in the script's own place (a choice's `e:enqueueTag jump`) and what
            // it called returns straight to the wait. A handler that jumped (a button's
            // `popfuncNN`) keeps its frame, and its `return` comes back to the wait.
            if let index = frames.lastIndex(where: { $0.event == eventSerial }), index > 0,
               frames[index].pc == frames[index - 1].pc, frames[index].script.path == frames[index - 1].script.path {
                frames.remove(at: index)
            }
            state = .running
            if luaDepth == 0 { flushDeferredLua() }
            return
        }
        state = .running
    }

    /// Runs a call to completion (for `e:tag{"call", ...}` from Lua). Waits inside are skipped.
    func runNested(file: String?, label: String?) throws {
        let depth = frames.count
        try call(file: file, label: label, locals: [:], isMacro: false, barrier: true)
        var guardSteps = 2_000_000
        while frames.count > depth, guardSteps > 0 {
            if case .waiting = state { state = .running }
            guard case .running = state else { break }
            step()
            guardSteps -= 1
        }
        barrierReached = false
        if case .waiting = state { state = .running }
    }

    // MARK: Macros and tag.ini

    private func addMacros(file: String) throws {
        let script = try script(file)
        for name in script.labels.keys where macros[name] == nil || true {
            macros[name] = (file, name)
        }
    }

    static func parseTagIni(_ text: String) -> [String: [String]] {
        var result: [String: [String]] = [:]
        var section: String?
        for raw in text.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix(";") { continue }
            if line.hasPrefix("["), line.hasSuffix("]") {
                section = String(line.dropFirst().dropLast())
                result[section!] = []
            } else if let section, let eq = line.firstIndex(of: "=") {
                result[section, default: []].append(String(line[line.index(after: eq)...]).trimmingCharacters(in: .whitespaces))
            }
        }
        return result
    }

    // MARK: Variables

    private func setVariable(_ tag: ArtemisTag) throws {
        guard let name = tag["name"] ?? (tag["system"] == "delete" ? "" : nil) else { return }
        // `data` wins over `system` (var.txt). Functions that only act (delete) return nil.
        let value: String?
        if let data = tag["data"] {
            value = data
        } else if let system = tag["system"] {
            value = systemFunction(system, tag)
        } else {
            value = ""
        }
        guard let value else { return }
        if (tag["writelocal"] == "1" || tag["local"] == "1"), !frames.isEmpty, tag["system"] != "var_exist" {
            frames[frames.count - 1].locals[name] = value
        } else {
            variables[name] = value
        }
    }

    /// Bytes of `text` in the game's encoding (the engine's string positions are bytes).
    private func byteCount(_ text: String) -> Int {
        text.data(using: fileSystem.encoding, allowLossyConversion: true)?.count ?? text.utf8.count
    }

    /// Characters of `text` up to `bytes` bytes in the game's encoding.
    private func characters(_ text: String, upToBytes bytes: Int) -> Int {
        var total = 0, count = 0
        for character in text {
            total += byteCount(String(character))
            if total > bytes { break }
            count += 1
        }
        return count
    }

    /// `[var system=...]` engine functions. nil: the function doesn't store a value.
    private func systemFunction(_ name: String, _ tag: ArtemisTag) -> String? {
        let source = tag["source"] ?? ""
        switch name {
        case "var_exist":
            let target = tag["target"] ?? ""
            if tag["local"] == "1" { return frames.last?.locals[target] != nil ? "1" : "0" }
            return value(of: target) != nil ? "1" : "0"
        case "file_exist", "file_exists":
            var file = tag["file"] ?? ""
            // save="1": relative to the save folder. Otherwise game files, or absolute paths.
            if tag["save"] == "1", !file.hasPrefix("/"), let root = value(of: "s.savepath") { file = root + "/" + file }
            let exists = fileSystem.file(file) != nil || (file.hasPrefix("/") && FileManager.default.fileExists(atPath: file))
            return exists ? "1" : "0"
        case "os":
            return reportedOS
        case "length":
            // Bytes in the game's encoding; mode=1 counts characters.
            return String(tag["mode"] == "1" ? source.count : byteCount(source))
        case "substr":
            let characters = Array(source)
            var start = Int(tag.number("position", default: tag.number("start")))
            var length = tag["length"].map { Int(ArtemisValue.number(from: $0) ?? 0) } ?? Int.max
            if tag["mode"] != "1" {
                // Byte positions: convert to characters.
                let startCharacters = self.characters(source, upToBytes: max(0, start))
                if length != Int.max {
                    let rest = String(characters[min(characters.count, startCharacters)...])
                    length = self.characters(rest, upToBytes: max(0, length))
                }
                start = startCharacters
            }
            start = max(0, start)
            guard start < characters.count else { return "" }
            let end = length == Int.max ? characters.count : min(characters.count, start + max(0, length))
            return String(characters[start ..< end])
        case "find":
            // Byte position of `string` in `source`, -1 when absent.
            guard let range = source.range(of: tag["string"] ?? "") else { return "-1" }
            return String(byteCount(String(source[..<range.lowerBound])))
        case "explode":
            // Splits `source` by `delimiter` into name.0, name.1, ... and name.size;
            // `escape` (default backslash) protects a delimiter.
            let delimiter = tag["delimiter"] ?? ","
            let escape = tag["escape"] ?? "\\"
            var parts: [String] = []
            if delimiter.isEmpty {
                parts = source.map(String.init)
            } else {
                var current = ""
                var rest = Substring(source)
                while !rest.isEmpty {
                    if !escape.isEmpty, rest.hasPrefix(escape + delimiter) {
                        current += delimiter
                        rest = rest.dropFirst(escape.count + delimiter.count)
                    } else if rest.hasPrefix(delimiter) {
                        parts.append(current)
                        current = ""
                        rest = rest.dropFirst(delimiter.count)
                    } else {
                        current.append(rest.removeFirst())
                    }
                }
                parts.append(current)
            }
            let base = tag["name"] ?? ""
            for (index, part) in parts.enumerated() { variables["\(base).\(index)"] = part }
            variables["\(base).size"] = String(parts.count)
            return nil
        case "implode":
            let base = tag["source"] ?? ""
            let size = Int(value(of: base + ".size") ?? "") ?? 0
            return (0 ..< size).map { value(of: "\(base).\($0)") ?? "" }.joined(separator: tag["delimiter"] ?? ",")
        case "delete":
            // The variable itself first; when it doesn't exist, its children (delete.txt).
            // No name: everything.
            guard let target = tag["name"], !target.isEmpty else {
                variables.removeAll()
                return nil
            }
            if variables[target] != nil {
                variables[target] = nil
            } else {
                let prefix = target + "."
                for key in variables.keys where key.hasPrefix(prefix) { variables[key] = nil }
            }
            return nil
        case "random":
            let low = tag["min"].flatMap { ArtemisValue.number(from: $0) }.map { Int($0) } ?? 0
            let high = tag["max"].flatMap { ArtemisValue.number(from: $0) }.map { Int($0) } ?? Int(Int32.max)
            return String(Int.random(in: min(low, high) ... max(low, high)))
        case "unixtime":
            return String(Int(Date().timeIntervalSince1970))
        case "base64_encode":
            return (source.data(using: fileSystem.encoding, allowLossyConversion: true) ?? Data(source.utf8)).base64EncodedString()
        case "url_encode":
            return source.addingPercentEncoding(withAllowedCharacters: .alphanumerics.union(CharacterSet(charactersIn: "-._~"))) ?? source
        case "url_decode":
            return source.replacingOccurrences(of: "+", with: " ").removingPercentEncoding ?? source
        case "character_reference_to_utf8":
            return Self.decodeCharacterReferences(source)
        case "convert_encoding", "to_sjis", "to_utf8":
            // Strings here are Unicode throughout; conversions are for byte-level tricks the
            // engine needed on Windows.
            return source
        case "hmac_sha1_base64":
            let key = SymmetricKey(data: Data((tag["key"] ?? "").utf8))
            let mac = HMAC<Insecure.SHA1>.authenticationCode(for: Data((tag["message"] ?? "").utf8), using: key)
            return Data(mac).base64EncodedString()
        case "file_crc":
            guard let data = try? fileSystem.data(tag["file"] ?? "") else { return "0" }
            var text = String(Self.crc32(data), radix: 16)
            text = String(repeating: "0", count: max(0, 8 - text.count)) + text
            if tag["caps"] == "1" { text = text.uppercased() }
            return (tag["zerox"] == "1" ? "0x" : "") + text
        case "get_exe_parameter":
            return nil
        case "minimize":
            return "0"
        case "screen_width":
            return variables["sc.width"] ?? "1280"
        case "screen_height":
            return variables["sc.height"] ?? "720"
        case "fullscreen":
            return "1"
        case "date":
            // name.year, .month, .day, .hour, .minute, .second
            let parts = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute, .second], from: .now)
            let base = tag["name"] ?? "date"
            for (field, value) in [("year", parts.year), ("month", parts.month), ("day", parts.day),
                                   ("hour", parts.hour), ("minute", parts.minute), ("second", parts.second)] {
                variables["\(base).\(field)"] = String(value ?? 0)
            }
            let formatter = DateFormatter()
            formatter.dateFormat = "yyyy/MM/dd HH:mm:ss"
            return formatter.string(from: .now)
        case "file_update_time":
            // A file's modification time, formatted (yyyy/MM/dd, hh:mm:ss), or `noexist`.
            var file = tag["file"] ?? ""
            if tag["save"] == "1", !file.hasPrefix("/"), let root = value(of: "s.savepath") { file = root + "/" + file }
            guard let date = (try? FileManager.default.attributesOfItem(atPath: file))?[.modificationDate] as? Date else {
                return tag["noexist"] ?? "0"
            }
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            // The engine's hh is the 24-hour clock.
            formatter.dateFormat = (tag["format"] ?? "yyyy/MM/dd HH:mm:ss").replacingOccurrences(of: "hh", with: "HH")
            return formatter.string(from: date)
        default:
            if let host, case .done = host.perform(ArtemisTag(name: "system:" + name, attributes: tag.attributes, order: tag.order), interpreter: self) {
                // The host stores what it computes (pseudo-arrays, or `name` itself).
                return nil
            }
            if reportedUnhandled.insert("system:" + name).inserted {
                host?.log("unhandled var system=\(name) at \(location)")
            }
            return ""
        }
    }

    /// A tag from `name,key,value,...` (the `tag` tag, get_backlog_tags).
    static func tag(fromData data: String) -> ArtemisTag? {
        var fields: [String] = []
        var current = ""
        var escaped = false
        for character in data {
            if escaped {
                current.append(character)
                escaped = false
            } else if character == "\\" {
                escaped = true
            } else if character == "," {
                fields.append(current)
                current = ""
            } else {
                current.append(character)
            }
        }
        fields.append(current)
        guard let name = fields.first?.trimmingCharacters(in: .whitespaces), !name.isEmpty else { return nil }
        var attributes: [String: String] = [:], order: [String] = []
        var i = 1
        while i + 1 < fields.count {
            attributes[fields[i]] = fields[i + 1]
            order.append(fields[i])
            i += 2
        }
        return ArtemisTag(name: name, attributes: attributes, order: order)
    }

    /// `name,key,value,...` for a tag, escaping commas and backslashes.
    static func tagData(_ name: String, _ pairs: [(String, String)]) -> String {
        func escape(_ text: String) -> String {
            text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: ",", with: "\\,")
        }
        return ([escape(name)] + pairs.flatMap { [escape($0.0), escape($0.1)] }).joined(separator: ",")
    }

    // MARK: Lua queries

    /// Tags queued by `e:enqueueTag`, run when the script next runs.
    private var queuedTags: [ArtemisTag] = []

    private func runQueuedTags() {
        while !queuedTags.isEmpty, case .running = state {
            let tag = queuedTags.removeFirst()
            if Self.traceLua { host?.log("trace: queued \(tag.name) at \(location)") }
            do { try perform(tag) } catch { host?.log("queued tag \(tag.name): \(error)") }
            // A queued tag that waits (the framework's stop2(): a dialog's [stop]) and the tags
            // queued after it go into a frame of their own, as script: an event during the wait
            // re-runs the waiting tag as it would a script command, and when the wait ends the
            // rest of the queue runs in order before the script it was queued from goes on.
            if defersLuaCalls, case .waiting = state {
                pushQueueFrame([tag] + queuedTags)
                queuedTags.removeAll()
            }
        }
    }

    /// The path of those frames; saves leave them out (a load resumes the script they came from).
    static let queuePath = "~queued"

    private static let unitSeparator = "\u{1F}", recordSeparator = "\u{1E}"

    func luaQuery(_ name: String, _ arguments: [String]) -> String? {
        let us = Self.unitSeparator, rs = Self.recordSeparator
        switch name {
        case "block":
            // e:getScriptBlock{file=, index=}: command, line and parameters.
            let file = arguments.first ?? ""
            guard let script = file.isEmpty ? frames.last?.script : try? self.script(file),
                  case let index = arguments.count > 1 ? Int(Double(arguments[1]) ?? -1) : 0,
                  index >= 0, index < script.commands.count else { return nil }
            let command = script.commands[index]
            var fields: [String]
            switch command.kind {
            case let .tag(tagName, attributes):
                fields = [tagName, String(command.line)] + attributes.flatMap { [$0.0, $0.1] }
            case let .lineTag(tagName, values):
                fields = [tagName, String(command.line)] + values.enumerated().flatMap { [String($0.offset), $0.element] }
            case let .text(text):
                fields = ["print", String(command.line), "data", text]
            case let .label(label):
                fields = ["label", String(command.line), "name", label]
            case .lua:
                fields = ["lua", String(command.line)]
            }
            return fields.joined(separator: us)
        case "size":
            let file = arguments.first ?? ""
            guard let script = file.isEmpty ? frames.last?.script : try? self.script(file) else { return nil }
            return String(script.commands.count)
        case "setStack":
            // e:setScriptStack: keep the frames that still match, outermost first.
            let records = (arguments.first ?? "").components(separatedBy: rs).filter { !$0.isEmpty }
            var rebuilt: [Frame] = []
            for (depth, record) in records.enumerated() {
                let parts = record.components(separatedBy: us)
                guard parts.count == 2, let index = Double(parts[1]).map({ Int($0) }) else { continue }
                if depth < frames.count, frames[depth].script.path == parts[0] {
                    var frame = frames[depth]
                    frame.pc = index
                    rebuilt.append(frame)
                } else if let script = try? script(parts[0]) {
                    rebuilt.append(Frame(script: script, pc: index, locals: [:], isMacro: false))
                }
            }
            if !rebuilt.isEmpty { frames = rebuilt }
            return nil
        case "enqueue":
            let parts = (arguments.first ?? "").components(separatedBy: us)
            guard let tagName = parts.first, !tagName.isEmpty else { return nil }
            var attributes: [String: String] = [:], order: [String] = []
            var i = 1
            while i + 1 < parts.count {
                attributes[parts[i]] = parts[i + 1]
                order.append(parts[i])
                i += 2
            }
            queuedTags.append(ArtemisTag(name: tagName, attributes: attributes, order: order))
            if Self.traceLua { host?.log("trace: \(String(repeating: "  ", count: luaDepth))e:enqueueTag \(tagName) \(order.map { "\($0)=\(attributes[$0] ?? "")" }.joined(separator: " "))") }
            return nil
        case "exists":
            // Absolute paths are files on disk: the save folder (`s.savepath`), whose saves
            // the newer generation checks before listing a slot.
            let path = arguments.first ?? ""
            if path.hasPrefix("/") { return FileManager.default.fileExists(atPath: path) ? "1" : "0" }
            return fileSystem.file(path) != nil ? "1" : "0"
        case "magicPath":
            fileSystem.setMagicPath(arguments.first ?? "", to: arguments.count > 1 ? arguments[1] : "")
            return nil
        default:
            return host?.luaQuery(name, arguments, interpreter: self)
        }
    }

    /// Runs the game's `e:setEventFilter` function before an event fires: false when the
    /// filter swallowed it (returned 1 or 2).
    func filterEvent(tagName: String, attributes: [String: String]) -> Bool {
        guard let lua else { return true }
        let encoding = fileSystem.encoding
        let order = attributes.keys.sorted()
        var keys: [UnsafeMutablePointer<CChar>?] = order.map { strdup(luaBytes($0, encoding)) } + [nil]
        var values: [UnsafeMutablePointer<CChar>?] = order.map { strdup(luaBytes(attributes[$0] ?? "", encoding)) } + [nil]
        defer {
            keys.forEach { free($0) }
            values.forEach { free($0) }
        }
        var error: UnsafeMutablePointer<CChar>?
        let result = keys.withUnsafeMutableBufferPointer { keyBuffer in
            values.withUnsafeMutableBufferPointer { valueBuffer in
                keyBuffer.baseAddress!.withMemoryRebound(to: UnsafePointer<CChar>?.self, capacity: keyBuffer.count) { k in
                    valueBuffer.baseAddress!.withMemoryRebound(to: UnsafePointer<CChar>?.self, capacity: valueBuffer.count) { v in
                        artemis_lua_filter_event(lua, luaBytes(tagName, encoding), Int32(order.count), k, v, &error)
                    }
                }
            }
        }
        if let error {
            host?.log("lua event filter (continuing): \(luaString(error, encoding))")
            free(error)
        }
        return result <= 0
    }

    static func decodeCharacterReferences(_ text: String) -> String {
        var result = ""
        var rest = Substring(text)
        while let start = rest.range(of: "&#") {
            result += rest[..<start.lowerBound]
            let after = rest[start.upperBound...]
            guard let end = after.firstIndex(of: ";") else { result += rest[start.lowerBound...]; return result }
            let body = after[..<end]
            let scalar = body.first == "x" || body.first == "X" ? UInt32(body.dropFirst(), radix: 16) : UInt32(body)
            if let scalar, let unicode = Unicode.Scalar(scalar) {
                result.unicodeScalars.append(unicode)
            } else {
                result += rest[start.lowerBound ... end]
            }
            rest = after[after.index(after: end)...]
        }
        return result + rest
    }

    static func crc32(_ data: Data) -> UInt32 {
        var table = [UInt32](repeating: 0, count: 256)
        for i in 0 ..< 256 {
            var c = UInt32(i)
            for _ in 0 ..< 8 { c = c & 1 != 0 ? 0xEDB8_8320 ^ (c >> 1) : c >> 1 }
            table[i] = c
        }
        var crc: UInt32 = 0xFFFF_FFFF
        for byte in data { crc = table[Int((crc ^ UInt32(byte)) & 0xFF)] ^ (crc >> 8) }
        return crc ^ 0xFFFF_FFFF
    }

    // MARK: - Lua

    private func startLua(stageWidth: Int, stageHeight: Int) {
        // The Lua state lives no longer than the interpreter, so it holds it unretained.
        let context = Unmanaged.passUnretained(self)
        luaHost.context = UnsafeMutableRawPointer(context.toOpaque())
        luaHost.tag = { context, name, count, keys, values in
            let interpreter = Unmanaged<ArtemisInterpreter>.fromOpaque(context!).takeUnretainedValue()
            MainActor.assumeIsolated { interpreter.luaTag(name: name!, count: Int(count), keys: keys!, values: values!) }
        }
        luaHost.var = { context, name in
            let interpreter = Unmanaged<ArtemisInterpreter>.fromOpaque(context!).takeUnretainedValue()
            // Unset variables read as "0" (first-boot checks rely on it).
            let value = MainActor.assumeIsolated { interpreter.value(of: luaString(name!, interpreter.fileSystem.encoding)) } ?? "0"
            return strdup(luaBytes(value, interpreter.fileSystem.encoding))
        }
        luaHost.debug = { context, message in
            let interpreter = Unmanaged<ArtemisInterpreter>.fromOpaque(context!).takeUnretainedValue()
            MainActor.assumeIsolated { interpreter.host?.log("lua: \(luaString(message!, interpreter.fileSystem.encoding))") }
        }
        luaHost.read_file = { context, path, length in
            let interpreter = Unmanaged<ArtemisInterpreter>.fromOpaque(context!).takeUnretainedValue()
            guard let data = try? interpreter.fileSystem.data(luaString(path!, interpreter.fileSystem.encoding)) else { return nil }
            length?.pointee = data.count
            let buffer = malloc(max(1, data.count))!.assumingMemoryBound(to: CChar.self)
            data.withUnsafeBytes { buffer.update(from: $0.bindMemory(to: CChar.self).baseAddress!, count: data.count) }
            return buffer
        }
        luaHost.script_stack = { context in
            let interpreter = Unmanaged<ArtemisInterpreter>.fromOpaque(context!).takeUnretainedValue()
            let text = MainActor.assumeIsolated {
                // Outermost first; the current position is the last entry (stacks[#stacks]).
                interpreter.frames.map { "\($0.script.path)\t\($0.pc)" }.joined(separator: "\n")
            }
            return strdup(luaBytes(text, interpreter.fileSystem.encoding))
        }
        luaHost.unsupported = { context, method in
            let interpreter = Unmanaged<ArtemisInterpreter>.fromOpaque(context!).takeUnretainedValue()
            MainActor.assumeIsolated {
                let name = "e:" + String(cString: method!)
                if interpreter.reportedUnhandled.insert(name).inserted { interpreter.host?.log("unsupported \(name) at \(interpreter.location)") }
            }
        }
        luaHost.mouse_point = { context, x, y in
            let interpreter = Unmanaged<ArtemisInterpreter>.fromOpaque(context!).takeUnretainedValue()
            let point = MainActor.assumeIsolated { interpreter.pointer }
            x?.pointee = point.x
            y?.pointee = point.y
        }
        luaHost.query = { context, name, count, args, length in
            let interpreter = Unmanaged<ArtemisInterpreter>.fromOpaque(context!).takeUnretainedValue()
            let encoding = interpreter.fileSystem.encoding
            let arguments = (0 ..< Int(count)).map { luaString(args![$0]!, encoding) }
            let answer = MainActor.assumeIsolated { interpreter.luaQuery(String(cString: name!), arguments) }
            guard let answer else { return nil }
            let bytes = answer.data(using: encoding, allowLossyConversion: true) ?? Data(answer.utf8)
            length?.pointee = bytes.count
            let buffer = malloc(max(1, bytes.count))!.assumingMemoryBound(to: CChar.self)
            bytes.withUnsafeBytes { buffer.update(from: $0.bindMemory(to: CChar.self).baseAddress!, count: bytes.count) }
            return buffer
        }
        luaHost.set_event_handler = { context, event, function in
            let interpreter = Unmanaged<ArtemisInterpreter>.fromOpaque(context!).takeUnretainedValue()
            let name = String(cString: event!), value = luaString(function!, interpreter.fileSystem.encoding)
            MainActor.assumeIsolated { interpreter.luaEventHandlers[name] = value.isEmpty ? nil : value }
        }
        lua = withUnsafePointer(to: &luaHost) { artemis_lua_open($0) }
        artemis_lua_set_number(lua, "sc_width", Double(stageWidth))
        artemis_lua_set_number(lua, "sc_height", Double(stageHeight))
    }

    private func luaTag(name: UnsafePointer<CChar>, count: Int, keys: UnsafePointer<UnsafePointer<CChar>?>, values: UnsafePointer<UnsafePointer<CChar>?>) {
        var attributes: [String: String] = [:]
        var order: [String] = []
        for i in 0 ..< count {
            let key = luaString(keys[i]!, fileSystem.encoding)
            attributes[key] = luaString(values[i]!, fileSystem.encoding)
            order.append(key)
        }
        var tag = ArtemisTag(name: luaString(name, fileSystem.encoding), attributes: attributes, order: order)
        // The newer generation hands expressions to the engine this way (`cond`:
        // e:tag{"var", name="t.cond", data="$0!=1"}), so `$` values are evaluated as in scripts.
        if defersLuaCalls, attributes.values.contains(where: { $0.hasPrefix("$") }),
           let evaluated = try? evaluate(name: tag.name, order.map { ($0, attributes[$0] ?? "") }) {
            tag = evaluated
        }
        if Self.traceLua { host?.log("trace: \(String(repeating: "  ", count: luaDepth))e:tag \(tag.name) \(order.map { "\($0)=\(attributes[$0] ?? "")" }.joined(separator: " "))") }
        do {
            // The newer generation's e:tag goes through its tag filter too.
            if defersLuaCalls, try filterTag(tag) { return }
            if tag.name == "call", defersLuaCalls, luaDepth > 0 {
                deferredLuaCalls.append((tag["file"], tag["label"]))
            } else if tag.name == "call" {
                try runNested(file: tag["file"], label: tag["label"])
            } else {
                let previous = state
                try perform(tag)
                // A wait requested from inside Lua can't suspend Lua; carry on. The newer
                // generation's framework relies on it taking effect once Lua returns.
                if case .waiting = state, case .running = previous {
                    if defersLuaCalls, luaDepth > 0 { deferredLuaWait = state; deferredLuaWaitTag = tag }
                    state = .running
                }
            }
        } catch {
            host?.log("lua e:tag \(tag): \(error)")
        }
    }

    private func runLua(_ code: Data, chunk: String) throws {
        let error = code.withUnsafeBytes { bytes in
            artemis_lua_run(lua, bytes.bindMemory(to: CChar.self).baseAddress, code.count, chunk)
        }
        if let error {
            let message = luaString(error, fileSystem.encoding)
            free(error)
            throw ArtemisScriptError(description: "lua: \(message)")
        }
    }

    /// The newer generation (compiled `.asb` scripts, NUKITASHI) runs its whole game in a Lua
    /// framework that queues tags with `e:tag{"call", label="estagNN"}` and expects them, and
    /// any wait they start, to take effect after the Lua function returns, as the engine does.
    /// The older games are written for calls that finish inside Lua, which Shiori keeps.
    static let traceLua = ProcessInfo.processInfo.environment["ARTEMIS_TRACE_LUA"] != nil
    lazy var defersLuaCalls: Bool = fileSystem.files.keys.contains { $0.lowercased().hasSuffix(".asb") }
    private var luaDepth = 0
    private var eventSerials = 0
    /// While an event handler runs: what its Lua queued waits until its frame is settled.
    private var holdingDeferredLua = false
    private var deferredLuaCalls: [(file: String?, label: String?)] = []
    private var deferredLuaWait: State?
    /// The tag that started it (a dialog's e:tag{"stop"} inside estag_call).
    private var deferredLuaWaitTag: ArtemisTag?

    /// Puts tags that waited outside the script (queued, or from Lua) in a frame of their own,
    /// as script, so an event during the wait re-runs the waiting tag as it would a script
    /// command, and what follows runs in order when the wait ends.
    private func pushQueueFrame(_ tags: [ArtemisTag]) {
        let commands = tags.map { tag in
            ScriptCommand(kind: .tag(name: tag.name, attributes: tag.order.map { ($0, tag[$0] ?? "") }), line: 0)
        }
        frames.append(Frame(script: ArtemisScript(path: Self.queuePath, commands: commands), pc: 1, locals: [:], isMacro: false))
    }

    /// After the outermost Lua call: the tags it queued with `e:enqueueTag` (run now, as the
    /// engine runs them once Lua returns), the calls it made (first one on top), then its wait.
    private func flushDeferredLua() {
        runQueuedTags()
        let calls = deferredLuaCalls
        deferredLuaCalls = []
        for pending in calls.reversed() {
            do { try call(file: pending.file, label: pending.label, locals: [:], isMacro: false) } catch {
                host?.log("lua e:tag call \(pending.file ?? "") *\(pending.label ?? ""): \(error)")
            }
        }
        if let wait = deferredLuaWait {
            deferredLuaWait = nil
            if case .running = state {
                state = wait
                if let tag = deferredLuaWaitTag { pushQueueFrame([tag]) }
            }
            deferredLuaWaitTag = nil
        }
    }

    private func callLua(_ tag: ArtemisTag) throws {
        guard let function = tag["function"] else { return }
        if Self.traceLua { host?.log("trace: \(String(repeating: "  ", count: luaDepth))lua \(function) at \(location)") }
        luaDepth += 1
        defer {
            luaDepth -= 1
            if luaDepth == 0, defersLuaCalls, !holdingDeferredLua { flushDeferredLua() }
        }
        var keys: [UnsafeMutablePointer<CChar>?] = []
        var values: [UnsafeMutablePointer<CChar>?] = []
        for key in tag.order where key != "function" {
            keys.append(strdup(luaBytes(key, fileSystem.encoding)))
            values.append(strdup(luaBytes(tag[key] ?? "", fileSystem.encoding)))
        }
        defer {
            keys.forEach { free($0) }
            values.forEach { free($0) }
        }
        let error = keys.withUnsafeBufferPointer { keyBuffer in
            values.withUnsafeBufferPointer { valueBuffer in
                keyBuffer.baseAddress!.withMemoryRebound(to: UnsafePointer<CChar>?.self, capacity: keyBuffer.count) { k in
                    valueBuffer.baseAddress!.withMemoryRebound(to: UnsafePointer<CChar>?.self, capacity: valueBuffer.count) { v in
                        artemis_lua_call(lua, luaBytes(function, fileSystem.encoding), Int32(keys.count), k, v)
                    }
                }
            }
        }
        if let error {
            let message = luaString(error, fileSystem.encoding)
            free(error)
            throw ArtemisScriptError(description: "lua \(function): \(message)")
        }
    }
}

/// Lua works in the game's bytes (CP932 or UTF-8); these convert at the boundary.
func luaString(_ pointer: UnsafePointer<CChar>, _ encoding: String.Encoding) -> String {
    let data = Data(bytes: pointer, count: strlen(pointer))
    return String(data: data, encoding: encoding) ?? String(cString: pointer)
}

func luaBytes(_ string: String, _ encoding: String.Encoding) -> [CChar] {
    let data = string.data(using: encoding, allowLossyConversion: true) ?? Data(string.utf8)
    return data.map { CChar(bitPattern: $0) } + [0]
}
