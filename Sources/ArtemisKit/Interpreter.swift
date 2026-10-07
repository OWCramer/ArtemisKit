import CLua
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
    }

    public let fileSystem: ArtemisFileSystem
    public weak var host: ArtemisHost?
    public private(set) var state: State = .running
    public var variables: [String: String] = [:]
    /// Tag name -> (file, label) for tags defined by `macroadd`.
    public private(set) var macros: [String: (file: String, label: String)] = [:]
    /// Positional parameter names from tag.ini.
    public private(set) var tagParameters: [String: [String]] = [:]

    var frames: [Frame] = []
    private var scripts: [String: ArtemisScript] = [:]
    nonisolated(unsafe) private var lua: OpaquePointer?
    nonisolated(unsafe) private var luaHost = ArtemisLuaHost()
    private var reportedUnhandled: Set<String> = []
    /// Commands run, for runaway-loop protection in headless runs.
    public private(set) var steps = 0

    public init(fileSystem: ArtemisFileSystem, stageWidth: Int, stageHeight: Int) {
        self.fileSystem = fileSystem
        if let data = try? fileSystem.data("tag.ini") { tagParameters = Self.parseTagIni(decodeScriptText(data)) }
        variables["sc.width"] = String(stageWidth)
        variables["sc.height"] = String(stageHeight)
        variables["os.name"] = "iphone"
        startLua(stageWidth: stageWidth, stageHeight: stageHeight)
    }

    deinit {
        if let lua { artemis_lua_close(lua) }
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
        try perform(tag)
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
            do { try callLua(tag) } catch { host?.log("lua error (continuing) at \(location): \(error)") }
        case "macroadd":
            try addMacros(file: tag["file"] ?? "")
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
            let evaluated = value.hasPrefix("$") ? try expression(String(value.dropFirst())).text : value
            if attributes[key] == nil { order.append(key) }
            attributes[key] = evaluated
        }
        return ArtemisTag(name: name, attributes: attributes, order: order)
    }

    public func expression(_ source: String) throws -> ArtemisValue {
        try ArtemisExpression.evaluate(source) { self.value(of: $0) }
    }

    /// A variable as scripts see it: the innermost macro's attributes first.
    public func value(of name: String) -> String? {
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
        let script = ArtemisScript(path: path, data: data)
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
        let (script, index) = try target(file: file, label: label)
        frames[frames.count - 1].script = script
        frames[frames.count - 1].pc = index
    }

    private func doReturn() {
        guard !frames.isEmpty else { return }
        let finished = frames.removeLast()
        if frames.isEmpty { state = .finished }
        if finished.barrier { barrierReached = true }
    }

    private var barrierReached = false

    /// A layer event fired while the script waits (a button press at `[stop]`): runs the
    /// event's `handler` tag first, then calls (`call="1"`, coming back to the wait) or
    /// jumps to its `file`/`label`.
    public func fireEvent(_ attributes: [String: String]) throws {
        let file = attributes["file"], label = attributes["label"]
        if file != nil || label != nil {
            if attributes["call"] == "1" {
                // Re-run the waiting command (usually [stop]) after the call returns.
                frames[frames.count - 1].pc = max(0, frames[frames.count - 1].pc - 1)
                try call(file: file, label: label, locals: [:], isMacro: false)
            } else {
                try jump(file: file, label: label)
            }
        }
        if let handler = attributes["handler"], !handler.isEmpty {
            var handlerAttributes = attributes
            for key in ["file", "label", "call", "handler", "penetration"] { handlerAttributes[key] = nil }
            try perform(ArtemisTag(name: handler, attributes: handlerAttributes, order: handlerAttributes.keys.sorted()))
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
        guard let name = tag["name"] else { return }
        let value: String
        if let system = tag["system"] {
            value = systemFunction(system, tag)
        } else {
            value = tag["data"] ?? ""
        }
        if tag["local"] == "1", !frames.isEmpty {
            frames[frames.count - 1].locals[name] = value
        } else {
            variables[name] = value
        }
    }

    /// `[var system=...]` engine functions.
    private func systemFunction(_ name: String, _ tag: ArtemisTag) -> String {
        switch name {
        case "var_exist":
            let target = tag["target"] ?? tag["data"] ?? ""
            return value(of: target) != nil ? "1" : "0"
        case "file_exist":
            return fileSystem.file(tag["file"] ?? "") != nil ? "1" : "0"
        case "os":
            return "iphone"
        case "length":
            return String((tag["source"] ?? tag["data"] ?? "").count)
        case "substr":
            let source = Array(tag["source"] ?? tag["data"] ?? "")
            let start = max(0, Int(tag.number("start")))
            let length = Int(tag.number("length", default: Double(source.count)))
            guard start < source.count else { return "" }
            return String(source[start ..< min(source.count, start + max(0, length))])
        case "explode":
            // Splits `source` by `delimiter` into name.0, name.1, ... and name.size.
            let source = tag["source"] ?? tag["data"] ?? ""
            let delimiter = tag["delimiter"] ?? ","
            let parts = delimiter.isEmpty ? source.map(String.init) : source.components(separatedBy: delimiter)
            let base = tag["name"] ?? ""
            for (index, part) in parts.enumerated() { variables["\(base).\(index)"] = part }
            variables["\(base).size"] = String(parts.count)
            return String(parts.count)
        case "delete":
            let target = tag["target"] ?? tag["name"] ?? ""
            variables[target] = nil
            let prefix = target + "."
            for key in variables.keys where key.hasPrefix(prefix) { variables[key] = nil }
            return ""
        case "screen_width":
            return variables["sc.width"] ?? "1280"
        case "screen_height":
            return variables["sc.height"] ?? "720"
        case "fullscreen":
            return "1"
        case "date":
            let formatter = DateFormatter()
            formatter.dateFormat = "yyyy/MM/dd HH:mm:ss"
            return formatter.string(from: .now)
        case "file_update_time":
            return "0"
        default:
            if let host, case .done = host.perform(ArtemisTag(name: "system:" + name, attributes: tag.attributes, order: tag.order), interpreter: self) {
                return variables[tag["name"] ?? ""] ?? ""
            }
            if reportedUnhandled.insert("system:" + name).inserted {
                host?.log("unhandled var system=\(name) at \(location)")
            }
            return ""
        }
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
            let value = MainActor.assumeIsolated { interpreter.value(of: luaString(name!)) } ?? "0"
            return strdup(luaBytes(value))
        }
        luaHost.debug = { context, message in
            let interpreter = Unmanaged<ArtemisInterpreter>.fromOpaque(context!).takeUnretainedValue()
            MainActor.assumeIsolated { interpreter.host?.log("lua: \(luaString(message!))") }
        }
        luaHost.read_file = { context, path, length in
            let interpreter = Unmanaged<ArtemisInterpreter>.fromOpaque(context!).takeUnretainedValue()
            guard let data = try? interpreter.fileSystem.data(luaString(path!)) else { return nil }
            length?.pointee = data.count
            let buffer = malloc(max(1, data.count))!.assumingMemoryBound(to: CChar.self)
            data.withUnsafeBytes { buffer.update(from: $0.bindMemory(to: CChar.self).baseAddress!, count: data.count) }
            return buffer
        }
        luaHost.script_stack = { context in
            let interpreter = Unmanaged<ArtemisInterpreter>.fromOpaque(context!).takeUnretainedValue()
            let text = MainActor.assumeIsolated {
                interpreter.frames.reversed().map { "\($0.script.path)\t\($0.pc)" }.joined(separator: "\n")
            }
            return strdup(luaBytes(text))
        }
        luaHost.unsupported = { context, method in
            let interpreter = Unmanaged<ArtemisInterpreter>.fromOpaque(context!).takeUnretainedValue()
            MainActor.assumeIsolated {
                let name = "e:" + String(cString: method!)
                if interpreter.reportedUnhandled.insert(name).inserted { interpreter.host?.log("unsupported \(name) at \(interpreter.location)") }
            }
        }
        lua = withUnsafePointer(to: &luaHost) { artemis_lua_open($0) }
        artemis_lua_set_number(lua, "sc_width", Double(stageWidth))
        artemis_lua_set_number(lua, "sc_height", Double(stageHeight))
    }

    private func luaTag(name: UnsafePointer<CChar>, count: Int, keys: UnsafePointer<UnsafePointer<CChar>?>, values: UnsafePointer<UnsafePointer<CChar>?>) {
        var attributes: [String: String] = [:]
        var order: [String] = []
        for i in 0 ..< count {
            let key = luaString(keys[i]!)
            attributes[key] = luaString(values[i]!)
            order.append(key)
        }
        let tag = ArtemisTag(name: luaString(name), attributes: attributes, order: order)
        do {
            if tag.name == "call" {
                try runNested(file: tag["file"], label: tag["label"])
            } else {
                let previous = state
                try perform(tag)
                // A wait requested from inside Lua can't suspend Lua; carry on.
                if case .waiting = state, case .running = previous { state = .running }
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
            let message = luaString(error)
            free(error)
            throw ArtemisScriptError(description: "lua: \(message)")
        }
    }

    private func callLua(_ tag: ArtemisTag) throws {
        guard let function = tag["function"] else { return }
        var keys: [UnsafeMutablePointer<CChar>?] = []
        var values: [UnsafeMutablePointer<CChar>?] = []
        for key in tag.order where key != "function" {
            keys.append(strdup(luaBytes(key)))
            values.append(strdup(luaBytes(tag[key] ?? "")))
        }
        defer {
            keys.forEach { free($0) }
            values.forEach { free($0) }
        }
        let error = keys.withUnsafeBufferPointer { keyBuffer in
            values.withUnsafeBufferPointer { valueBuffer in
                keyBuffer.baseAddress!.withMemoryRebound(to: UnsafePointer<CChar>?.self, capacity: keys.count) { k in
                    valueBuffer.baseAddress!.withMemoryRebound(to: UnsafePointer<CChar>?.self, capacity: values.count) { v in
                        artemis_lua_call(lua, luaBytes(function), Int32(keys.count), k, v)
                    }
                }
            }
        }
        if let error {
            let message = luaString(error)
            free(error)
            throw ArtemisScriptError(description: "lua \(function): \(message)")
        }
    }
}

/// Lua works in the game's bytes (CP932); these convert at the boundary.
func luaString(_ pointer: UnsafePointer<CChar>) -> String {
    let data = Data(bytes: pointer, count: strlen(pointer))
    return String(data: data, encoding: artemisScriptEncoding) ?? String(cString: pointer)
}

func luaBytes(_ string: String) -> [CChar] {
    let data = string.data(using: artemisScriptEncoding, allowLossyConversion: true) ?? Data(string.utf8)
    return data.map { CChar(bitPattern: $0) } + [0]
}
