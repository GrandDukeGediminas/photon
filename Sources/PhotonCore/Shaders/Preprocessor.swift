import Foundation

/// The engine's CPU preprocessor (docs/re/02 §2.1, `sub_14016b0e0`).
///
/// Evaluates `#if/#ifdef/#ifndef/#elif/#else/#endif/#define/#undef/#require` with C integer semantics,
/// undefined identifiers evaluating to 0 and `SHADERVERSION` predefined as 69. Lines in inactive
/// branches and the bodies of `/* */` comments are blanked so line numbers are preserved.
///
/// Difference from the engine: conditional directive lines are also blanked once evaluated, so the
/// downstream compiler never re-evaluates them. `#define`/`#undef` lines are kept as the engine does.
public struct ShaderPreprocessor {
    public var macros: [String: String] = ["SHADERVERSION": "69"]
    /// Full text after the name of each `#define` kept in the output, to spot redefinitions.
    var definitions: [String: String] = [:]
    /// Called for `#require <Name>`; returns replacement text.
    public var require: (String) -> String = { _ in "" }

    public init() {}

    static let directive = Regex(#"^\s*#\s*([a-z]+)\b\s*(.*)"#)

    public mutating func run(_ source: String) -> String {
        var out: [String] = []
        // Stack of (thisBranchActive, anyBranchTaken, parentActive)
        var stack: [(active: Bool, taken: Bool, parent: Bool)] = []
        var inBlockComment = false
        var active: Bool { stack.last?.active ?? true }

        for raw in ShaderSourceLoader.lines(source) {
            var line = String(raw)
            line = Self.blankBlockComments(line, inComment: &inBlockComment)
            let codePart = line.range(of: "//").map { String(line[..<$0.lowerBound]) } ?? line

            guard let m = Self.directive.firstMatch(in: codePart) else {
                out.append(active ? line : String(repeating: " ", count: line.count))
                continue
            }
            let keyword = m[1], rest = m[2].trimmingCharacters(in: .whitespaces)
            switch keyword {
            case "if", "ifdef", "ifndef":
                let parent = active
                var cond = false
                if parent {
                    switch keyword {
                    case "ifdef": cond = macros[Self.firstWord(rest)] != nil
                    case "ifndef": cond = macros[Self.firstWord(rest)] == nil
                    default: cond = evaluate(rest) != 0
                    }
                }
                stack.append((parent && cond, parent && cond, parent))
                out.append("")
            case "elif":
                if var top = stack.popLast() {
                    if top.parent && !top.taken && evaluate(rest) != 0 {
                        top.active = true; top.taken = true
                    } else {
                        top.active = false
                    }
                    stack.append(top)
                }
                out.append("")
            case "else":
                if var top = stack.popLast() {
                    top.active = top.parent && !top.taken
                    top.taken = true
                    stack.append(top)
                }
                out.append("")
            case "endif":
                _ = stack.popLast()
                out.append("")
            case "define" where active:
                let name = Self.firstWord(rest)
                var value = String(rest.dropFirst(name.count))
                // Function-like macros are recorded by name only; the engine never expands them in #if.
                let body = value.trimmingCharacters(in: .whitespaces)
                if value.hasPrefix("(") { value = "" }
                // FXC treats a redefinition with a different body as a warning (X1519) and uses the new body, as the
                // CPU pass does; glslang rejects it. The define block repeats a combo when a material combo and a
                // bound-texture combo share a name (`NORMALMAP 0` then `NORMALMAP 1`, docs/re/02 §3.3).
                if let old = definitions[name], old != body { out.append("#undef \(name)") }
                definitions[name] = body
                macros[name] = value.trimmingCharacters(in: .whitespaces)
                out.append(line)
            case "undef" where active:
                macros[Self.firstWord(rest)] = nil
                definitions[Self.firstWord(rest)] = nil
                out.append(line)
            case "require" where active:
                out.append(require(Self.firstWord(rest)))
            default:
                out.append(active ? line : String(repeating: " ", count: line.count))
            }
        }
        return out.joined(separator: "\n") + "\n"
    }

    static func firstWord(_ s: String) -> String {
        String(s.prefix(while: { $0.isLetter || $0.isNumber || $0 == "_" }))
    }

    static func blankBlockComments(_ line: String, inComment: inout Bool) -> String {
        guard inComment || line.contains("/*") else { return line }
        var chars = Array(line)
        var i = 0
        while i < chars.count {
            if inComment {
                if chars[i] == "*", i + 1 < chars.count, chars[i + 1] == "/" {
                    chars[i] = " "; chars[i + 1] = " "; i += 2; inComment = false; continue
                }
                chars[i] = " "
            } else if chars[i] == "/", i + 1 < chars.count {
                if chars[i + 1] == "/" { break }
                if chars[i + 1] == "*" { chars[i] = " "; chars[i + 1] = " "; i += 2; inComment = true; continue }
            }
            i += 1
        }
        return String(chars)
    }

    // MARK: - #if expression evaluation (sub_140167e10 / sub_140166a90)

    enum Token: Equatable { case num(Int), ident(String), op(String) }

    func evaluate(_ expr: String) -> Int {
        var p = Parser(tokens: expand(Self.tokenize(expr), depth: 0))
        return p.parse()
    }

    /// Expands identifiers recursively (depth limit 99); `defined X` / `defined(X)` become 0/1 first.
    func expand(_ tokens: [Token], depth: Int) -> [Token] {
        var out: [Token] = []
        var i = 0
        while i < tokens.count {
            let t = tokens[i]
            if case .ident("defined") = t {
                var j = i + 1
                var paren = false
                if j < tokens.count, tokens[j] == .op("(") { paren = true; j += 1 }
                if j < tokens.count, case .ident(let name) = tokens[j] {
                    out.append(.num(macros[name] != nil ? 1 : 0))
                    j += 1
                    if paren, j < tokens.count, tokens[j] == .op(")") { j += 1 }
                    i = j
                    continue
                }
                out.append(.num(0)); i += 1; continue
            }
            if case .ident(let name) = t {
                if depth < 99, let value = macros[name], !value.isEmpty {
                    let sub = expand(Self.tokenize(value), depth: depth + 1)
                    out.append(.op("(")); out.append(contentsOf: sub); out.append(.op(")"))
                } else {
                    out.append(.num(0))
                }
                i += 1
                continue
            }
            out.append(t)
            i += 1
        }
        return out
    }

    static func tokenize(_ s: String) -> [Token] {
        var tokens: [Token] = []
        let c = Array(s)
        var i = 0
        let two: Set<String> = ["!=", "==", "<=", ">=", "<<", ">>", "&&", "||"]
        while i < c.count {
            let ch = c[i]
            if ch.isWhitespace { i += 1; continue }
            if ch.isLetter || ch == "_" {
                var j = i
                while j < c.count, c[j].isLetter || c[j].isNumber || c[j] == "_" { j += 1 }
                tokens.append(.ident(String(c[i..<j]))); i = j; continue
            }
            if ch.isNumber {
                var j = i
                while j < c.count, c[j].isHexDigit || c[j] == "x" || c[j] == "X" || c[j] == "." { j += 1 }
                let text = String(c[i..<j])
                while j < c.count, "uUlLfF".contains(c[j]) { j += 1 }
                let v: Int
                if text.lowercased().hasPrefix("0x") { v = Int(text.dropFirst(2), radix: 16) ?? 0 }
                else if text.contains(".") { v = Int(Double(text) ?? 0) }
                else { v = Int(text) ?? 0 }
                tokens.append(.num(v)); i = j; continue
            }
            if i + 1 < c.count, two.contains(String(c[i...i + 1])) {
                tokens.append(.op(String(c[i...i + 1]))); i += 2; continue
            }
            tokens.append(.op(String(ch))); i += 1
        }
        return tokens
    }

    /// Precedence-climbing parser with C precedence; `&` and `|` behave as `&&`/`||` like the engine.
    struct Parser {
        var tokens: [Token]
        var pos = 0

        static let precedence: [String: Int] = [
            "||": 1, "|": 1, "&&": 2, "&": 2, "^": 3, "==": 4, "!=": 4,
            "<": 5, "<=": 5, ">": 5, ">=": 5, "<<": 6, ">>": 6, "+": 7, "-": 7, "*": 8, "/": 8, "%": 8,
        ]

        mutating func parse() -> Int { binary(0) }

        mutating func binary(_ minPrec: Int) -> Int {
            var lhs = unary()
            while pos < tokens.count, case .op(let op) = tokens[pos], let prec = Self.precedence[op], prec >= minPrec {
                pos += 1
                let rhs = binary(prec + 1)
                lhs = Self.apply(op, lhs, rhs)
            }
            return lhs
        }

        mutating func unary() -> Int {
            guard pos < tokens.count else { return 0 }
            let t = tokens[pos]
            pos += 1
            switch t {
            case .num(let v): return v
            case .ident: return 0
            case .op("("):
                let v = binary(0)
                if pos < tokens.count, tokens[pos] == .op(")") { pos += 1 }
                return v
            case .op("!"): return unary() == 0 ? 1 : 0
            case .op("-"): return -unary()
            case .op("+"): return unary()
            case .op("~"): return ~unary()
            default: return 0
            }
        }

        static func apply(_ op: String, _ a: Int, _ b: Int) -> Int {
            switch op {
            case "||", "|": return (a != 0 || b != 0) ? 1 : 0
            case "&&", "&": return (a != 0 && b != 0) ? 1 : 0
            case "^": return a ^ b
            case "==": return a == b ? 1 : 0
            case "!=": return a != b ? 1 : 0
            case "<": return a < b ? 1 : 0
            case "<=": return a <= b ? 1 : 0
            case ">": return a > b ? 1 : 0
            case ">=": return a >= b ? 1 : 0
            case "<<": return a << b
            case ">>": return a >> b
            case "+": return a &+ b
            case "-": return a &- b
            case "*": return a &* b
            case "/": return b == 0 ? 0 : a / b
            case "%": return b == 0 ? 0 : a % b
            default: return 0
            }
        }
    }
}
