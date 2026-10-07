import Foundation

/// A value in Artemis expressions: numbers and strings, converted the way the scripts expect.
public enum ArtemisValue: Equatable, Sendable {
    case number(Double)
    case string(String)

    public init(_ text: String) {
        if let number = ArtemisValue.number(from: text) { self = .number(number) } else { self = .string(text) }
    }

    static func number(from text: String) -> Double? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }
        if trimmed.hasPrefix("0x") || trimmed.hasPrefix("0X"), let value = UInt64(trimmed.dropFirst(2), radix: 16) {
            return Double(value)
        }
        // Only plain decimal numbers count; "1e3" or "inf" stay strings.
        guard trimmed.allSatisfy({ $0.isNumber || $0 == "." || $0 == "-" || $0 == "+" }),
              let value = Double(trimmed) else { return nil }
        return value
    }

    public var text: String {
        switch self {
        case let .string(s): return s
        case let .number(n): return ArtemisValue.format(n)
        }
    }

    public var numberValue: Double {
        switch self {
        case let .number(n): return n
        case let .string(s): return ArtemisValue.number(from: s) ?? 0
        }
    }

    public var isTrue: Bool {
        switch self {
        case let .number(n): return n != 0
        case let .string(s):
            if let n = ArtemisValue.number(from: s) { return n != 0 }
            return !s.isEmpty
        }
    }

    static func format(_ n: Double) -> String {
        if n.isFinite, n == n.rounded(), abs(n) < 1e15 { return String(Int64(n)) }
        return String(n)
    }
}

public struct ExpressionError: Error, CustomStringConvertible {
    public let description: String
}

/// Parses and evaluates Artemis `$` expressions.
public enum ArtemisExpression {
    /// Evaluates `source` (without the leading `$`). `lookup` resolves variable names.
    public static func evaluate(_ source: String, lookup: @escaping (String) -> String?) throws -> ArtemisValue {
        var parser = Parser(tokens: try tokenize(source), lookup: lookup)
        let value = try parser.parseOr()
        guard parser.position == parser.tokens.count else {
            throw ExpressionError(description: "unexpected \(parser.tokens[parser.position]) in \(source)")
        }
        return value
    }

    enum Token: Equatable, CustomStringConvertible {
        case number(Double)
        case string(String)
        case name(String)
        case op(String)

        var description: String {
            switch self {
            case let .number(n): return String(n)
            case let .string(s): return "'\(s)'"
            case let .name(n): return n
            case let .op(o): return o
            }
        }
    }

    static func tokenize(_ source: String) throws -> [Token] {
        var tokens: [Token] = []
        let characters = Array(source)
        var i = 0
        while i < characters.count {
            let c = characters[i]
            if c == " " || c == "\t" || c == "\n" || c == "\r" { i += 1; continue }
            if c == "'" || c == "\"" {
                var s = ""
                i += 1
                while i < characters.count, characters[i] != c {
                    if characters[i] == "\\", i + 1 < characters.count { i += 1 }
                    s.append(characters[i])
                    i += 1
                }
                i += 1
                tokens.append(.string(s))
                continue
            }
            if c.isNumber || (c == "." && i + 1 < characters.count && characters[i + 1].isNumber) {
                var s = ""
                if c == "0", i + 1 < characters.count, characters[i + 1] == "x" || characters[i + 1] == "X" {
                    i += 2
                    while i < characters.count, characters[i].isHexDigit { s.append(characters[i]); i += 1 }
                    tokens.append(.number(Double(UInt64(s, radix: 16) ?? 0)))
                    continue
                }
                while i < characters.count, characters[i].isNumber || characters[i] == "." { s.append(characters[i]); i += 1 }
                // A number glued to letters is a name (rare, e.g. "1syou").
                if i < characters.count, characters[i].isLetter || characters[i] == "_" {
                    while i < characters.count, isNameCharacter(characters[i]) { s.append(characters[i]); i += 1 }
                    tokens.append(.name(s))
                } else {
                    tokens.append(.number(Double(s) ?? 0))
                }
                continue
            }
            // `name.(expression)`: a computed name segment; `.rest` continues the name.
            if c == ".", i + 1 < characters.count, characters[i + 1] == "(" {
                tokens.append(.op(".("))
                i += 2
                continue
            }
            if c == ".", i + 1 < characters.count, isNameCharacter(characters[i + 1]), case .op(")") = tokens.last {
                tokens.append(.op("."))
                i += 1
                continue
            }
            if isNameStart(c) {
                var s = ""
                while i < characters.count, isNameCharacter(characters[i]) || characters[i] == "." {
                    // A dot continues the name only when a name character follows.
                    if characters[i] == ".", !(i + 1 < characters.count && isNameCharacter(characters[i + 1])) { break }
                    s.append(characters[i])
                    i += 1
                }
                tokens.append(.name(s))
                continue
            }
            let two = i + 1 < characters.count ? String(characters[i ... i + 1]) : ""
            if ["==", "!=", "<=", ">=", "&&", "||", "<>"].contains(two) {
                tokens.append(.op(two == "<>" ? "!=" : two))
                i += 2
                continue
            }
            if "+-*/%<>!()=".contains(c) {
                tokens.append(.op(c == "=" ? "==" : String(c)))
                i += 1
                continue
            }
            throw ExpressionError(description: "unexpected character \(c) in \(source)")
        }
        return tokens
    }

    static func isNameStart(_ c: Character) -> Bool { c.isLetter || c == "_" || (!c.isASCII && !c.isWhitespace) }
    static func isNameCharacter(_ c: Character) -> Bool { c.isLetter || c.isNumber || c == "_" || (!c.isASCII && !c.isWhitespace) }

    struct Parser {
        let tokens: [Token]
        let lookup: (String) -> String?
        var position = 0

        init(tokens: [Token], lookup: @escaping (String) -> String?) {
            self.tokens = tokens
            self.lookup = lookup
        }

        mutating func next() -> Token? {
            guard position < tokens.count else { return nil }
            defer { position += 1 }
            return tokens[position]
        }

        func peekOp() -> String? {
            guard position < tokens.count, case let .op(o) = tokens[position] else { return nil }
            return o
        }

        mutating func parseOr() throws -> ArtemisValue {
            var left = try parseAnd()
            while peekOp() == "||" || peekName("or") {
                position += 1
                let right = try parseAnd()
                left = .number(left.isTrue || right.isTrue ? 1 : 0)
            }
            return left
        }

        func peekName(_ word: String) -> Bool {
            guard position < tokens.count, case let .name(n) = tokens[position] else { return false }
            return n == word
        }

        mutating func parseAnd() throws -> ArtemisValue {
            var left = try parseComparison()
            while peekOp() == "&&" || peekName("and") {
                position += 1
                let right = try parseComparison()
                left = .number(left.isTrue && right.isTrue ? 1 : 0)
            }
            return left
        }

        mutating func parseComparison() throws -> ArtemisValue {
            var left = try parseAdditive()
            while let op = peekOp(), ["==", "!=", "<", ">", "<=", ">="].contains(op) {
                position += 1
                let right = try parseAdditive()
                left = .number(compare(left, op, right) ? 1 : 0)
            }
            return left
        }

        func compare(_ a: ArtemisValue, _ op: String, _ b: ArtemisValue) -> Bool {
            let an = ArtemisValue.number(from: a.text), bn = ArtemisValue.number(from: b.text)
            if let an, let bn {
                switch op {
                case "==": return an == bn
                case "!=": return an != bn
                case "<": return an < bn
                case ">": return an > bn
                case "<=": return an <= bn
                default: return an >= bn
                }
            }
            // An empty (unset) value compares equal to 0 as well as to "".
            let at = a.text, bt = b.text
            if op == "==" { return at == bt || (at.isEmpty && bn == 0) || (bt.isEmpty && an == 0) }
            if op == "!=" { return !(at == bt || (at.isEmpty && bn == 0) || (bt.isEmpty && an == 0)) }
            switch op {
            case "<": return at < bt
            case ">": return at > bt
            case "<=": return at <= bt
            default: return at >= bt
            }
        }

        mutating func parseAdditive() throws -> ArtemisValue {
            var left = try parseMultiplicative()
            while let op = peekOp(), op == "+" || op == "-" {
                position += 1
                let right = try parseMultiplicative()
                if op == "+" {
                    // Numbers add; anything involving a string concatenates.
                    if case .number = left, case .number = right {
                        left = .number(left.numberValue + right.numberValue)
                    } else {
                        left = .string(left.text + right.text)
                    }
                } else {
                    left = .number(left.numberValue - right.numberValue)
                }
            }
            return left
        }

        mutating func parseMultiplicative() throws -> ArtemisValue {
            var left = try parseUnary()
            while let op = peekOp(), op == "*" || op == "/" || op == "%" {
                position += 1
                let right = try parseUnary()
                let a = left.numberValue, b = right.numberValue
                switch op {
                case "*": left = .number(a * b)
                case "/": left = .number(b == 0 ? 0 : a / b)
                default: left = .number(b == 0 ? 0 : a.truncatingRemainder(dividingBy: b))
                }
            }
            return left
        }

        mutating func parseUnary() throws -> ArtemisValue {
            if peekOp() == "!" || peekName("not") {
                position += 1
                return .number(try parseUnary().isTrue ? 0 : 1)
            }
            if peekOp() == "-" {
                position += 1
                return .number(-(try parseUnary().numberValue))
            }
            if peekOp() == "+" {
                position += 1
                return try parseUnary()
            }
            return try parsePrimary()
        }

        mutating func parsePrimary() throws -> ArtemisValue {
            guard let token = next() else { throw ExpressionError(description: "expression ends early") }
            switch token {
            case let .number(n): return .number(n)
            case let .string(s): return .string(s)
            case var .name(n):
                if n == "true" { return .number(1) }
                if n == "false" { return .number(0) }
                // Computed segments: g.read.scene.(t.i).done
                while position < tokens.count {
                    if tokens[position] == .op(".(") {
                        position += 1
                        let segment = try parseOr()
                        guard next() == .op(")") else { throw ExpressionError(description: "missing ) in name") }
                        n += "." + segment.text
                    } else if tokens[position] == .op("."), position + 1 < tokens.count, case let .name(rest) = tokens[position + 1] {
                        position += 2
                        n += "." + rest
                    } else {
                        break
                    }
                }
                // Variables keep their stored text; numeric text acts as a number.
                // Unset variables are 0, as in the engine.
                guard let value = lookup(n) else { return .number(0) }
                return ArtemisValue(value)
            case .op("("):
                let value = try parseOr()
                guard next() == .op(")") else { throw ExpressionError(description: "missing )") }
                return value
            case let .op(o):
                throw ExpressionError(description: "unexpected \(o)")
            }
        }
    }
}
