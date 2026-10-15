// This Source Code Form is subject to the terms of the Mozilla Public License, v. 2.0.
// If a copy of the MPL was not distributed with this file, You can obtain one at
// https://mozilla.org/MPL/2.0/.

import Foundation

/// Text encoding of this Artemis generation's scripts (Shift-JIS, Windows code page 932).
public let artemisScriptEncoding = String.Encoding(
    rawValue: CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.dosJapanese.rawValue))
)

/// Decodes script bytes in the game's encoding (CP932 unless `system.ini` says UTF-8),
/// falling back to the other one and then lossy UTF-8.
public func decodeScriptText(_ data: Data, encoding: String.Encoding = artemisScriptEncoding) -> String {
    if data.starts(with: [0xEF, 0xBB, 0xBF]), let text = String(data: data.dropFirst(3), encoding: .utf8) { return text }
    return String(data: data, encoding: encoding)
        ?? String(data: data, encoding: encoding == .utf8 ? artemisScriptEncoding : .utf8)
        ?? String(decoding: data, as: UTF8.self)
}

/// One step of a parsed script.
public struct ScriptCommand: Sendable {
    public enum Kind: Sendable {
        /// `[name key=value ...]`. Values keep their `$` when they're expressions.
        case tag(name: String, attributes: [(String, String)])
        /// Prose to show in the message window.
        case text(String)
        /// `*name` (with any `|title` part removed).
        case label(String)
        /// `[lua] ... [/lua]`, as raw bytes (Lua source is ASCII; strings inside stay CP932).
        case lua(Data)
        /// `#name a,b,c` when the file enables line tags.
        case lineTag(name: String, arguments: [String])
    }

    public let kind: Kind
    /// 1-based source line.
    public let line: Int
}

/// A parsed `.iet` / `.txt` script, with label positions and block structure resolved.
public struct ArtemisScript: Sendable {
    public let path: String
    public let commands: [ScriptCommand]
    /// Label name -> index of the label command.
    public let labels: [String: Int]
    /// For `if` / `elseif` / `else`: index of the next branch or the `/if`. For `/if`: itself.
    let nextBranch: [Int: Int]
    /// For `if` / `elseif` / `else`: index of the matching `/if`.
    let endIf: [Int: Int]
    /// `loop` -> its `/loop`, and `/loop` -> its `loop`.
    let loopPartner: [Int: Int]

    public init(path: String, data: Data, encoding: String.Encoding = artemisScriptEncoding) {
        self.init(path: path, commands: data.starts(with: Array("ASB\0".utf8))
            ? ASBParser.parse(data, encoding: encoding) : ScriptParser.parse(data, encoding: encoding))
    }

    /// A script made of commands directly (the tags queued after one that waits).
    init(path: String, commands: [ScriptCommand]) {
        self.path = path
        self.commands = commands
        var labels: [String: Int] = [:]
        var nextBranch: [Int: Int] = [:]
        var endIf: [Int: Int] = [:]
        var loopPartner: [Int: Int] = [:]
        var ifStack: [[Int]] = []
        var loopStack: [Int] = []
        for (index, command) in commands.enumerated() {
            switch command.kind {
            case let .label(name):
                if labels[name] == nil { labels[name] = index }
            case let .tag(name, _):
                switch name {
                case "if":
                    ifStack.append([index])
                case "elseif", "else":
                    if var branches = ifStack.popLast() {
                        branches.append(index)
                        ifStack.append(branches)
                    }
                case "/if":
                    if let branches = ifStack.popLast() {
                        for (i, branch) in branches.enumerated() {
                            nextBranch[branch] = i + 1 < branches.count ? branches[i + 1] : index
                            endIf[branch] = index
                        }
                    }
                case "loop":
                    loopStack.append(index)
                case "/loop":
                    if let start = loopStack.popLast() {
                        loopPartner[start] = index
                        loopPartner[index] = start
                    }
                default:
                    break
                }
            default:
                break
            }
        }
        self.labels = labels
        self.nextBranch = nextBranch
        self.endIf = endIf
        self.loopPartner = loopPartner
    }
}

/// The newer generation's compiled scripts (`.asb`, NUKITASHI's `system/ui.asb`): `ASB\0`, a
/// byte, a u32 record count, then records, each a u32 kind: 1 a label (its name), 0 a tag (its name, its
/// source line, a u32 attribute count, then name and value pairs). Strings are a u32 length,
/// the bytes and a NUL. The same commands an `.iet` file parses to.
enum ASBParser {
    static func parse(_ data: Data, encoding: String.Encoding) -> [ScriptCommand] {
        let bytes = [UInt8](data)
        var position = 9
        func u32() -> Int? {
            guard position + 4 <= bytes.count else { return nil }
            defer { position += 4 }
            return Int(bytes[position]) | Int(bytes[position + 1]) << 8 | Int(bytes[position + 2]) << 16 | Int(bytes[position + 3]) << 24
        }
        func string() -> String? {
            guard let length = u32(), length >= 0, position + length <= bytes.count else { return nil }
            defer { position += length + 1 }
            return decodeScriptText(Data(bytes[position..<(position + length)]), encoding: encoding)
        }
        var commands: [ScriptCommand] = []
        var line = 0
        while position < bytes.count {
            guard let kind = u32() else { break }
            switch kind {
            case 1:
                guard let name = string() else { return commands }
                commands.append(ScriptCommand(kind: .label(name), line: line))
            case 0:
                guard let name = string(), let source = u32(), let count = u32(), count < 10_000 else { return commands }
                line = source
                var attributes: [(String, String)] = []
                for _ in 0..<count {
                    guard let key = string(), let value = string() else { return commands }
                    attributes.append((key, value))
                }
                commands.append(ScriptCommand(kind: .tag(name: name, attributes: attributes), line: line))
            default:
                // Not seen yet: stop rather than misread the rest.
                return commands
            }
        }
        return commands
    }
}

enum ScriptParser {
    static func parse(_ data: Data, encoding: String.Encoding) -> [ScriptCommand] {
        var commands: [ScriptCommand] = []
        var autoInsert: [String: [ScriptCommand.Kind]] = [:]
        var lineTagPrefix: Character?
        var luaBuffer: Data?
        var luaStartLine = 0
        var pendingTag = ""
        var pendingTagLine = 0
        var inBlockComment = false

        let lines = data.split(separator: 0x0A, omittingEmptySubsequences: false)
        for (offset, rawLine) in lines.enumerated() {
            let lineNumber = offset + 1
            var lineData = Data(rawLine)
            if lineData.last == 0x0D { lineData.removeLast() }

            if var buffer = luaBuffer {
                let text = decodeScriptText(lineData, encoding: encoding)
                if text.trimmingCharacters(in: .whitespaces).lowercased().hasPrefix("[/lua]") {
                    commands.append(ScriptCommand(kind: .lua(buffer), line: luaStartLine))
                    luaBuffer = nil
                } else {
                    buffer.append(lineData)
                    buffer.append(0x0A)
                    luaBuffer = buffer
                }
                continue
            }

            var text = decodeScriptText(lineData, encoding: encoding)
            // /* block comments */, possibly spanning lines.
            if inBlockComment {
                guard let end = text.range(of: "*/") else { continue }
                text = String(text[end.upperBound...])
                inBlockComment = false
            }
            while let start = text.range(of: "/*"), !isInsideQuotes(text, start.lowerBound) {
                if let end = text.range(of: "*/", range: start.upperBound ..< text.endIndex) {
                    text.removeSubrange(start.lowerBound ..< end.upperBound)
                } else {
                    text = String(text[..<start.lowerBound])
                    inBlockComment = true
                    break
                }
            }
            if !pendingTag.isEmpty {
                // A tag continued from earlier lines; comments still apply line by line.
                pendingTag += " " + stripComment(text)
                if tagIsClosed(pendingTag) {
                    text = pendingTag
                    pendingTag = ""
                    parseLine(text, line: pendingTagLine, into: &commands, autoInsert: &autoInsert,
                              lineTagPrefix: &lineTagPrefix, isContinuation: true)
                }
                continue
            }

            let trimmed = text.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix(";") { continue }
            if trimmed.lowercased() == "[lua]" {
                luaBuffer = Data()
                luaStartLine = lineNumber
                continue
            }
            let stripped = stripComment(text)
            if stripped.trimmingCharacters(in: .whitespaces).isEmpty {
                // A truly empty line (not a comment-only one) is a "blank line" for autoinsert.
                if trimmed.isEmpty, let insert = autoInsert["blankline"] {
                    commands += insert.map { ScriptCommand(kind: $0, line: lineNumber) }
                }
                continue
            }
            if !tagIsClosed(stripped) {
                pendingTag = stripped
                pendingTagLine = lineNumber
                continue
            }
            // A trailing comment, like a trailing tag, keeps the lineend insert off.
            let endsInComment = stripped.count < text.count
            parseLine(stripped, line: lineNumber, into: &commands, autoInsert: &autoInsert,
                      lineTagPrefix: &lineTagPrefix, isContinuation: false, endsInComment: endsInComment)
        }
        return commands
    }

    /// Parses one logical line (labels, line tags, or a mix of tags and prose).
    private static func parseLine(
        _ text: String, line: Int, into commands: inout [ScriptCommand],
        autoInsert: inout [String: [ScriptCommand.Kind]], lineTagPrefix: inout Character?, isContinuation: Bool,
        endsInComment: Bool = false
    ) {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix("*") {
            let name = trimmed.dropFirst().split(whereSeparator: { $0 == "|" || $0 == " " || $0 == "\t" }).first.map(String.init) ?? ""
            commands.append(ScriptCommand(kind: .label(name), line: line))
            return
        }
        if let prefix = lineTagPrefix, trimmed.first == prefix {
            let body = trimmed.dropFirst()
            let parts = body.split(maxSplits: 1, whereSeparator: { $0 == " " || $0 == "\t" })
            let name = parts.first.map(String.init) ?? ""
            let arguments = parts.count > 1
                ? parts[1].split(separator: ",", omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: .whitespaces) }
                : []
            commands.append(ScriptCommand(kind: .lineTag(name: name, arguments: arguments), line: line))
            return
        }

        var pieces: [ScriptCommand.Kind] = []
        var hasText = false
        for piece in splitTagsAndText(text) {
            switch piece {
            case let .text(prose):
                if prose.trimmingCharacters(in: .whitespaces).isEmpty { continue }
                hasText = true
                pieces.append(.text(prose))
            case let .tag(name, attributes):
                if name == "&autoinsert" {
                    let target = attributes.first { $0.0 == "target" }?.1 ?? ""
                    let command = attributes.first { $0.0 == "command" }?.1 ?? ""
                    autoInsert[target] = splitTagsAndText(command).filter {
                        if case .tag = $0 { return true }
                        return false
                    }
                    continue
                }
                if name == "&linetag" {
                    let allow = attributes.first { $0.0 == "allow" }?.1 ?? "1"
                    let prefix = attributes.first { $0.0 == "prefix" }?.1 ?? "#"
                    lineTagPrefix = allow == "0" ? nil : prefix.first
                    continue
                }
                pieces.append(.tag(name: name, attributes: attributes))
            default:
                pieces.append(piece)
            }
        }
        // The engine inserts these only next to prose: a line that starts with a tag gets no
        // linehead, and one that ends with a tag or a comment gets no lineend
        // (`Praise her[rt]` in a choice list stays one line).
        if hasText, case .text = pieces.first, let head = autoInsert["linehead"] { pieces = head + pieces }
        if hasText, !endsInComment, case .text = pieces.last, let end = autoInsert["lineend"] { pieces += end }
        commands += pieces.map { ScriptCommand(kind: $0, line: line) }
    }

    /// Splits a line into `[tags]` and the text between them (quotes respected).
    static func splitTagsAndText(_ line: String) -> [ScriptCommand.Kind] {
        var result: [ScriptCommand.Kind] = []
        var text = ""
        var index = line.startIndex
        while index < line.endIndex {
            let character = line[index]
            if character == "[" {
                if let end = closingBracket(in: line, from: index) {
                    if !text.isEmpty {
                        result.append(.text(text))
                        text = ""
                    }
                    let inner = String(line[line.index(after: index) ..< end])
                    result.append(parseTag(inner))
                    index = line.index(after: end)
                    continue
                }
            }
            text.append(character)
            index = line.index(after: index)
        }
        if !text.isEmpty { result.append(.text(text)) }
        return result
    }

    private static func closingBracket(in line: String, from start: String.Index) -> String.Index? {
        var quoted = false
        var index = line.index(after: start)
        while index < line.endIndex {
            let character = line[index]
            if character == "\\" {
                index = line.index(after: index)
                if index < line.endIndex { index = line.index(after: index) }
                continue
            }
            if character == "\"" { quoted.toggle() }
            if character == "]", !quoted { return index }
            index = line.index(after: index)
        }
        return nil
    }

    /// `name key=value key="value with spaces"` -> a tag command.
    static func parseTag(_ inner: String) -> ScriptCommand.Kind {
        var scanner = inner[...]
        func skipSpace() { while let c = scanner.first, c == " " || c == "\t" { scanner.removeFirst() } }
        skipSpace()
        var name = ""
        while let c = scanner.first, c != " ", c != "\t", c != "=" { name.append(c); scanner.removeFirst() }
        var attributes: [(String, String)] = []
        while true {
            skipSpace()
            guard !scanner.isEmpty else { break }
            var key = ""
            while let c = scanner.first, c != " ", c != "\t", c != "=" { key.append(c); scanner.removeFirst() }
            skipSpace()
            guard scanner.first == "=" else {
                if !key.isEmpty { attributes.append((key, "")) }
                continue
            }
            scanner.removeFirst()
            skipSpace()
            var value = ""
            if scanner.first == "\"" {
                scanner.removeFirst()
                while let c = scanner.first {
                    scanner.removeFirst()
                    if c == "\\", let next = scanner.first {
                        scanner.removeFirst()
                        value.append(next == "\"" ? "\"" : next == "\\" ? "\\" : next)
                        if next != "\"" && next != "\\" { value.insert("\\", at: value.index(before: value.endIndex)) }
                        continue
                    }
                    if c == "\"" { break }
                    value.append(c)
                }
            } else {
                while let c = scanner.first, c != " ", c != "\t" { value.append(c); scanner.removeFirst() }
            }
            attributes.append((key, value))
        }
        return .tag(name: name, attributes: attributes)
    }

    /// Removes a `//` comment outside quotes and brackets' quoted values.
    static func stripComment(_ line: String) -> String {
        var quoted = false
        var previous: Character?
        var index = line.startIndex
        while index < line.endIndex {
            let character = line[index]
            if character == "\"" && previous != "\\" { quoted.toggle() }
            if character == "/", !quoted {
                let next = line.index(after: index)
                if next < line.endIndex, line[next] == "/" {
                    // Keep URLs like http://... in prose.
                    if previous != ":" { return String(line[..<index]) }
                }
            }
            previous = character
            index = line.index(after: index)
        }
        return line
    }

    static func isInsideQuotes(_ line: String, _ position: String.Index) -> Bool {
        line[..<position].filter { $0 == "\"" }.count % 2 == 1
    }

    /// Whether every `[` opened outside quotes is closed.
    static func tagIsClosed(_ line: String) -> Bool {
        var depth = 0
        var quoted = false
        var previous: Character?
        for character in line {
            if character == "\"" && previous != "\\" && depth > 0 { quoted.toggle() }
            if !quoted {
                if character == "[" { depth += 1 }
                if character == "]" { depth = max(0, depth - 1) }
            }
            previous = character
        }
        return depth == 0
    }
}
