import Foundation

/// Turns an ES module (a SceneScript binding or a `scripts/jsmodules/*.js` file) into a classic-script
/// function expression that JavaScriptCore can evaluate (docs/re/08 §2.2, §5).
///
/// JSC's public API has no module loader and no way to read a module namespace, so each module becomes
///
///     (function(__require){'use strict';const X=__require("wemath");…  <body, exports stripped>
///     ;return{get init(){return init},…};})
///
/// - `import … from 'M'` statements are hoisted to the prologue as `const` bindings resolved through
///   `__require` (specifier lower-cased, `.js` appended, as in the engine's resolve callback 0x1816469c0).
///   Their original text is blanked out with spaces so line/column numbers in errors still match.
/// - `export` is removed from declarations; the exported names come back as getters on the returned
///   object, so reads of `ns.scriptProperties` etc. see the current binding (live for the exporter).
///
/// Deviations from real ES modules (documented in docs/re/08 §5 terms):
/// - named imports (`import {a} from`) are snapshots taken when the importer runs, not live bindings;
///   namespace imports (`import * as M`) are live, which is what the corpus uses (181 of 181 imports);
/// - top-level `await` is a syntax error (the corpus never uses it);
/// - the module body is a function body: `return` at top level would not be a syntax error, and `arguments`
///   is visible; `this` at top level is `undefined`, as in a module;
/// - strict mode comes from the inserted directive, as modules are always strict.
enum ScriptModule {
    struct Result {
        var source: String
        var exports: [String]
        var imports: [String]
    }

    private struct Token {
        enum Kind { case ident, punct, string, template, regex, number }
        var kind: Kind
        var start: Int // byte offsets into the UTF-8 buffer
        var end: Int
        var depth: Int // bracket depth before the token
        var newlineBefore: Bool
    }

    static func transform(_ src: String) -> Result {
        let bytes = Array(src.utf8)
        let toks = tokenize(bytes)
        func text(_ t: Token) -> String { String(decoding: bytes[t.start..<t.end], as: UTF8.self) }
        func isIdent(_ i: Int, _ s: String) -> Bool { i < toks.count && toks[i].kind == .ident && text(toks[i]) == s }
        func isPunct(_ i: Int, _ s: String) -> Bool { i < toks.count && toks[i].kind == .punct && text(toks[i]) == s }

        var blank: [(Int, Int)] = []       // byte ranges replaced by whitespace
        var prologue: [String] = []
        var exports: [(name: String, local: String)] = []
        var imports: [String] = []
        var tail: [String] = []
        var importCounter = 0
        var replaceInsert: [(Int, String)] = [] // (byte offset, text) inserted for `export default <expr>`

        func unquote(_ t: Token) -> String {
            let s = text(t)
            return String(s.dropFirst().dropLast())
        }
        func requireExpr(_ spec: String) -> String {
            "__require(\(jsonString(spec)))"
        }
        /// End of a statement starting at token `i`: a `;` at the same depth, or a newline before a token that
        /// cannot continue the expression (approximate ASI).
        func statementEnd(from i: Int) -> Int {
            let d = toks[i].depth
            var j = i + 1
            while j < toks.count {
                let t = toks[j]
                if t.depth < d { return j - 1 }
                if t.depth == d {
                    if t.kind == .punct && text(t) == ";" { return j }
                    if t.newlineBefore && j > i + 1 {
                        let prev = toks[j - 1]
                        let prevText = text(prev)
                        let prevContinues = prev.kind == .punct && !([")", "]", "}"].contains(prevText))
                        let cur = text(t)
                        let curContinues = t.kind == .punct && [".", ",", "?", ":", "+", "-", "*", "/", "%", "&&", "||", "??",
                                                                  "=", "==", "===", "!=", "!==", "<", ">", "<=", ">=", "&", "|",
                                                                  "^", "(", "[", "?.", "=>", "**", "<<", ">>", ">>>"].contains(cur)
                        if !prevContinues && !curContinues
                            && !(t.kind == .ident && ["in", "instanceof", "of"].contains(cur)) { return j - 1 }
                    }
                }
                j += 1
            }
            return toks.count - 1
        }

        var i = 0
        while i < toks.count {
            let t = toks[i]
            guard t.depth == 0, t.kind == .ident, i == 0 || !isPunct(i - 1, ".") else { i += 1; continue }
            let word = text(t)
            if word == "import" && !isPunct(i + 1, "(") && !isPunct(i + 1, ".") {
                // import 'M'; | import X from 'M' | import * as X from 'M' | import {a, b as c} from 'M' | import X, {…}
                var j = i + 1
                var defaultName: String?
                var nsName: String?
                var named: [(String, String)] = []
                if j < toks.count, toks[j].kind == .string {
                    let spec = unquote(toks[j])
                    imports.append(spec)
                    prologue.append("\(requireExpr(spec));")
                    let end = isPunct(j + 1, ";") ? j + 1 : j
                    blank.append((t.start, toks[end].end))
                    i = end + 1
                    continue
                }
                while j < toks.count && !isIdent(j, "from") {
                    if toks[j].kind == .ident && !isIdent(j, "as") && !isPunct(j - 1, "{") && !isPunct(j - 1, ",") && isPunct(j - 1, "*") == false
                        && defaultName == nil && nsName == nil && named.isEmpty && j == i + 1 {
                        defaultName = text(toks[j])
                    } else if isPunct(j, "*") && isIdent(j + 1, "as") && j + 2 < toks.count {
                        nsName = text(toks[j + 2]); j += 2
                    } else if isPunct(j, "{") {
                        j += 1
                        while j < toks.count && !isPunct(j, "}") {
                            if toks[j].kind == .ident || toks[j].kind == .string {
                                let imported = toks[j].kind == .string ? unquote(toks[j]) : text(toks[j])
                                var local = imported
                                if isIdent(j + 1, "as") && j + 2 < toks.count { local = text(toks[j + 2]); j += 2 }
                                named.append((imported, local))
                            }
                            j += 1
                        }
                    }
                    j += 1
                }
                guard j + 1 < toks.count, toks[j + 1].kind == .string else { i += 1; continue }
                let spec = unquote(toks[j + 1])
                imports.append(spec)
                importCounter += 1
                let tmp = "__imp\(importCounter)"
                prologue.append("const \(tmp)=\(requireExpr(spec));")
                if let n = nsName { prologue.append("const \(n)=\(tmp);") }
                if let d = defaultName { prologue.append("const \(d)=\(tmp).default;") }
                if !named.isEmpty {
                    prologue.append("const {" + named.map { $0.0 == $0.1 ? $0.0 : "\(jsonString($0.0)):\($0.1)" }.joined(separator: ",") + "}=\(tmp);")
                }
                let end = isPunct(j + 2, ";") ? j + 2 : j + 1
                blank.append((t.start, toks[end].end))
                i = end + 1
                continue
            }
            if word == "export" {
                let n = i + 1
                guard n < toks.count else { break }
                let next = text(toks[n])
                if ["function", "class", "async"].contains(next) {
                    // export function f / export async function f / export function* f / export class C
                    var j = n
                    if next == "async" { j += 1 }
                    j += 1
                    if isPunct(j, "*") { j += 1 }
                    if j < toks.count, toks[j].kind == .ident { exports.append((text(toks[j]), text(toks[j]))) }
                    blank.append((t.start, t.end))
                    i = n
                    continue
                }
                if ["var", "let", "const"].contains(next) {
                    blank.append((t.start, t.end))
                    let end = statementEnd(from: n)
                    let d = toks[n].depth
                    var j = n + 1
                    var expectName = true
                    while j <= end && j < toks.count {
                        if toks[j].depth == d {
                            if expectName && toks[j].kind == .ident { exports.append((text(toks[j]), text(toks[j]))) }
                            expectName = toks[j].kind == .punct && text(toks[j]) == ","
                        } else {
                            expectName = false
                        }
                        j += 1
                    }
                    i = n + 1
                    continue
                }
                if next == "default" {
                    // export default function f(){} | export default class C {} | export default <expr>
                    let k = n + 1
                    if k < toks.count, ["function", "class", "async"].contains(text(toks[k])) {
                        var j = k
                        if text(toks[k]) == "async" { j += 1 }
                        j += 1
                        if isPunct(j, "*") { j += 1 }
                        if j < toks.count, toks[j].kind == .ident {
                            exports.append(("default", text(toks[j])))
                            blank.append((t.start, toks[n].end))
                        } else {
                            // anonymous: `export default function(){}` → `var __default = function(){}`
                            blank.append((t.start, toks[n].end))
                            replaceInsert.append((t.start, "var __default="))
                            exports.append(("default", "__default"))
                        }
                    } else {
                        blank.append((t.start, toks[n].end))
                        replaceInsert.append((t.start, "var __default="))
                        exports.append(("default", "__default"))
                    }
                    i = n + 1
                    continue
                }
                if isPunct(n, "{") || isPunct(n, "*") {
                    // export {a, b as c} [from 'M'] | export * from 'M'
                    var j = n
                    var list: [(String, String)] = []
                    var star = false
                    if isPunct(n, "*") { star = true; j += 1 } else {
                        j += 1
                        while j < toks.count && !isPunct(j, "}") {
                            if toks[j].kind == .ident {
                                let local = text(toks[j])
                                var name = local
                                if isIdent(j + 1, "as") && j + 2 < toks.count { name = text(toks[j + 2]); j += 2 }
                                list.append((name, local))
                            }
                            j += 1
                        }
                        j += 1
                    }
                    var end = j - 1
                    if isIdent(j, "from"), j + 1 < toks.count, toks[j + 1].kind == .string {
                        let spec = unquote(toks[j + 1])
                        imports.append(spec)
                        importCounter += 1
                        let tmp = "__imp\(importCounter)"
                        prologue.append("const \(tmp)=\(requireExpr(spec));")
                        if star { tail.append("__reexport.push(\(tmp));") }
                        for (name, local) in list { exports.append((name, "\(tmp)[\(jsonString(local))]")) }
                        end = j + 1
                    } else {
                        exports.append(contentsOf: list)
                    }
                    if isPunct(end + 1, ";") { end += 1 }
                    blank.append((t.start, toks[min(end, toks.count - 1)].end))
                    i = end + 1
                    continue
                }
            }
            i += 1
        }

        // Apply edits (blank ranges keep newlines so error positions stay valid).
        var out = bytes
        for (s, e) in blank {
            for k in s..<min(e, out.count) where out[k] != UInt8(ascii: "\n") && out[k] != UInt8(ascii: "\r") { out[k] = UInt8(ascii: " ") }
        }
        var body = String(decoding: out, as: UTF8.self)
        if !replaceInsert.isEmpty {
            // Insert at byte offsets (descending so earlier offsets stay valid).
            var b = Array(body.utf8)
            for (pos, s) in replaceInsert.sorted(by: { $0.0 > $1.0 }) {
                let ins = Array(s.utf8)
                // Overwrite the blanked `export default` bytes where possible to keep columns.
                let room = min(ins.count, b.count - pos)
                var k = 0
                while k < room && b[pos + k] == UInt8(ascii: " ") { k += 1 }
                if k >= ins.count {
                    b.replaceSubrange(pos..<(pos + ins.count), with: ins)
                } else {
                    b.insert(contentsOf: ins, at: pos)
                }
            }
            body = String(decoding: b, as: UTF8.self)
        }

        var seen = Set<String>()
        var getters: [String] = []
        for (name, local) in exports where !seen.contains(name) {
            seen.insert(name)
            let key = name.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "_" || $0 == "$" }) ? name : jsonString(name)
            getters.append("get \(key)(){return \(local)}")
        }
        let reexport = tail.isEmpty ? "" : "const __reexport=[];" + tail.joined()
        let ret = reexport.isEmpty
            ? "return{\(getters.joined(separator: ","))};"
            : "\(reexport)const __ns={\(getters.joined(separator: ","))};for(const m of __reexport)for(const k of Object.keys(m))if(!(k in __ns)&&k!=='default')Object.defineProperty(__ns,k,{get(){return m[k]},enumerable:true});return __ns;"
        let source = "(function(__require){'use strict';" + prologue.joined() + body + "\n;" + ret + "})"
        return Result(source: source, exports: Array(seen), imports: imports)
    }

    static func jsonString(_ s: String) -> String {
        var r = "\""
        for c in s.unicodeScalars {
            switch c {
            case "\"": r += "\\\""
            case "\\": r += "\\\\"
            case "\n": r += "\\n"
            case "\r": r += "\\r"
            case "\t": r += "\\t"
            default:
                if c.value < 0x20 { r += String(format: "\\u%04x", c.value) } else { r.unicodeScalars.append(c) }
            }
        }
        return r + "\""
    }

    // MARK: - Lexer

    private static let regexPrecedingWords: Set<String> = ["return", "typeof", "instanceof", "in", "of", "new", "delete", "void",
                                                           "throw", "case", "do", "else", "yield", "await"]

    private static func tokenize(_ b: [UInt8]) -> [Token] {
        var toks: [Token] = []
        var i = 0
        let n = b.count
        var depth = 0
        // Stack of open brackets; `T` marks a template substitution `${`.
        var stack: [UInt8] = []
        var newline = false

        func isIdentStart(_ c: UInt8) -> Bool { (c >= 65 && c <= 90) || (c >= 97 && c <= 122) || c == 95 || c == 36 || c >= 0x80 }
        func isIdentPart(_ c: UInt8) -> Bool { isIdentStart(c) || (c >= 48 && c <= 57) }
        /// Length of a non-ASCII whitespace sequence at `k` (NBSP, U+2000–U+200A, U+202F, U+205F, U+3000,
        /// BOM; line/paragraph separators are handled as newlines), else 0. Workshop scripts use NBSP.
        func unicodeSpace(_ k: Int) -> Int {
            guard b[k] >= 0x80 else { return 0 }
            if b[k] == 0xC2, k + 1 < n, b[k + 1] == 0xA0 { return 2 }
            if b[k] == 0xE2, k + 2 < n, b[k + 1] == 0x80, (0x80...0x8A).contains(b[k + 2]) || b[k + 2] == 0xAF || b[k + 2] == 0xA8 || b[k + 2] == 0xA9 { return 3 }
            if b[k] == 0xE2, k + 2 < n, b[k + 1] == 0x81, b[k + 2] == 0x9F { return 3 }
            if b[k] == 0xE3, k + 2 < n, b[k + 1] == 0x80, b[k + 2] == 0x80 { return 3 }
            if b[k] == 0xEF, k + 2 < n, b[k + 1] == 0xBB, b[k + 2] == 0xBF { return 3 }
            return 0
        }
        func regexAllowed() -> Bool {
            guard let last = toks.last else { return true }
            switch last.kind {
            case .number, .string, .template, .regex: return false
            case .ident:
                let w = String(decoding: b[last.start..<last.end], as: UTF8.self)
                return regexPrecedingWords.contains(w)
            case .punct:
                let p = String(decoding: b[last.start..<last.end], as: UTF8.self)
                return !(p == ")" || p == "]" || p == "}" || p == "++" || p == "--")
            }
        }
        /// Scans template characters from `i` (just after ` or a closing `}` of a substitution).
        /// Returns true if it stopped at `${` (a substitution opens), false at the closing backtick.
        func scanTemplate() -> Bool {
            while i < n {
                let c = b[i]
                if c == UInt8(ascii: "\\") { i += 2; continue }
                if c == UInt8(ascii: "`") { i += 1; return false }
                if c == UInt8(ascii: "$") && i + 1 < n && b[i + 1] == UInt8(ascii: "{") { i += 2; return true }
                i += 1
            }
            return false
        }

        while i < n {
            let c = b[i]
            if c == 10 || c == 13 { newline = true; i += 1; continue }
            if c == 32 || c == 9 || c == 11 || c == 12 { i += 1; continue }
            if c == 0xE2, i + 2 < n, b[i + 1] == 0x80, b[i + 2] == 0xA8 || b[i + 2] == 0xA9 { newline = true; i += 3; continue }
            let us = unicodeSpace(i)
            if us > 0 { i += us; continue }
            let start = i
            // Comments
            if c == UInt8(ascii: "/") && i + 1 < n && b[i + 1] == UInt8(ascii: "/") {
                while i < n && b[i] != 10 && b[i] != 13 { i += 1 }
                continue
            }
            if c == UInt8(ascii: "/") && i + 1 < n && b[i + 1] == UInt8(ascii: "*") {
                i += 2
                while i + 1 < n && !(b[i] == UInt8(ascii: "*") && b[i + 1] == UInt8(ascii: "/")) {
                    if b[i] == 10 { newline = true }
                    i += 1
                }
                i += 2
                continue
            }
            var kind: Token.Kind
            let d = depth
            if (isIdentStart(c) || c == UInt8(ascii: "\\")) && unicodeSpace(i) == 0 {
                while i < n && (isIdentPart(b[i]) || b[i] == UInt8(ascii: "\\")) && unicodeSpace(i) == 0 { i += 1 }
                kind = .ident
            } else if c >= 48 && c <= 57 || (c == UInt8(ascii: ".") && i + 1 < n && b[i + 1] >= 48 && b[i + 1] <= 57) {
                i += 1
                while i < n && (isIdentPart(b[i]) || b[i] == UInt8(ascii: ".")
                                || ((b[i] == UInt8(ascii: "+") || b[i] == UInt8(ascii: "-")) && (b[i - 1] == UInt8(ascii: "e") || b[i - 1] == UInt8(ascii: "E")))) { i += 1 }
                kind = .number
            } else if c == UInt8(ascii: "\"") || c == UInt8(ascii: "'") {
                i += 1
                while i < n && b[i] != c && b[i] != 10 {
                    if b[i] == UInt8(ascii: "\\") { i += 1 }
                    i += 1
                }
                i += 1
                kind = .string
            } else if c == UInt8(ascii: "`") {
                i += 1
                if scanTemplate() { stack.append(UInt8(ascii: "T")); depth += 1 }
                kind = .template
            } else if c == UInt8(ascii: "/") && regexAllowed() {
                i += 1
                var inClass = false
                while i < n && b[i] != 10 {
                    if b[i] == UInt8(ascii: "\\") { i += 2; continue }
                    if b[i] == UInt8(ascii: "[") { inClass = true } else if b[i] == UInt8(ascii: "]") { inClass = false }
                    else if b[i] == UInt8(ascii: "/") && !inClass { break }
                    i += 1
                }
                i += 1
                while i < n && isIdentPart(b[i]) { i += 1 }
                kind = .regex
            } else {
                kind = .punct
                switch c {
                case UInt8(ascii: "{"), UInt8(ascii: "("), UInt8(ascii: "["):
                    stack.append(c); depth += 1; i += 1
                case UInt8(ascii: "}"):
                    if stack.last == UInt8(ascii: "T") {
                        // End of a template substitution: continue the template.
                        stack.removeLast(); depth -= 1
                        i += 1
                        if scanTemplate() { stack.append(UInt8(ascii: "T")); depth += 1 }
                        toks.append(Token(kind: .template, start: start, end: i, depth: depth, newlineBefore: newline))
                        newline = false
                        continue
                    }
                    if !stack.isEmpty { stack.removeLast() }
                    depth = max(0, depth - 1); i += 1
                case UInt8(ascii: ")"), UInt8(ascii: "]"):
                    if !stack.isEmpty { stack.removeLast() }
                    depth = max(0, depth - 1); i += 1
                default:
                    // Multi-char operators (only the ones the statement-end heuristic cares about need be exact).
                    let ops = [">>>=", "...", "===", "!==", "**=", "<<=", ">>=", ">>>", "&&=", "||=", "??=",
                               "=>", "==", "!=", "<=", ">=", "&&", "||", "??", "?.", "++", "--", "+=", "-=", "*=", "/=",
                               "%=", "&=", "|=", "^=", "**", "<<", ">>"]
                    var matched = 1
                    for op in ops {
                        let ob = Array(op.utf8)
                        if i + ob.count <= n && Array(b[i..<(i + ob.count)]) == ob { matched = ob.count; break }
                    }
                    i += matched
                }
            }
            toks.append(Token(kind: kind, start: start, end: min(i, n), depth: kind == .punct && (c == UInt8(ascii: "}") || c == UInt8(ascii: ")") || c == UInt8(ascii: "]")) ? depth : d,
                              newlineBefore: newline))
            newline = false
        }
        return toks
    }
}
