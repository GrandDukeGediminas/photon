import Foundation

/// GLSL-dialect → HLSL, following `sub_1400f5cb0` (docs/re/02 §2.2–2.7).
public struct HLSLTranslator {
    public enum Stage: Int { case vertex = 0, geometry = 1, fragment = 2 }

    struct Variable {
        var type: Int
        var name: String
        var arrayCount: Int
        var packed: Bool
        var direction: Int // 1 = in, 2 = out, 0 = other
    }

    public struct Uniform {
        public let name: String
        public let hlslType: String
        public let arrayCount: Int
        public let buffer: Int
    }

    public struct Output {
        public let hlsl: String
        /// Non-texture uniforms in declaration order, with their constant buffer.
        public let uniforms: [Uniform]
        /// Texture slots declared (g_Texture0…9) and their dialect type index.
        public let textures: [Int: Int]
        /// Varying name → first TEXCOORD index and declared HLSL type, as emitted (geometry stage: its `out`s).
        public let varyingRegisters: [String: (register: Int, type: String)]
        /// The list the engine's translator hands to the next stage (`sub_1400f5cb0` 0x1400f5f75–0x1400f6073): the vertex
        /// stage's varyings with `gl_Position` appended, or the geometry stage's `out` declarations.
        var exported: [Variable] = []
    }

    let stage: Stage
    let defines: [String: String]
    /// Fragment stage only: the vertex stage's varyings (name → TEXCOORD index). D3D11 drivers tolerate a
    /// pixel shader whose inputs don't line up with the vertex outputs; Metal does not link such pipelines.
    /// So fragment varyings take the vertex register of the same name, and varyings the vertex stage never
    /// writes become zero-initialised locals.
    let linkedVaryings: [String: (register: Int, type: String)]?
    /// Geometry stage only: the vertex stage's exported varyings. The engine builds the geometry `VS_OUTPUT` from this list
    /// (direction 1, vertex order, `gl_Position` last) and drops the geometry source's own `in` declarations
    /// (0x1400f5f96–0x1400f6065), so both stages share one struct and the vertex→geometry link is by name.
    let inputVaryings: [Variable]?

    public init(stage: Stage, defines: [String: String], linkedVaryings: [String: (register: Int, type: String)]? = nil) {
        self.stage = stage
        self.defines = defines
        self.linkedVaryings = linkedVaryings
        self.inputVaryings = nil
    }

    init(stage: Stage, defines: [String: String], linkedVaryings: [String: (register: Int, type: String)]?, inputVaryings: [Variable]?) {
        self.stage = stage
        self.defines = defines
        self.linkedVaryings = linkedVaryings
        self.inputVaryings = inputVaryings
    }

    static let declKeywords = ["attribute", "varying", "in", "out", "uniform"]
    static let typeRegexes: [Regex] = ShaderTables.types.map { Regex(#"(\w+)[\s]+"# + $0.glsl + #"[\s]+(\w+)(\[[\d\w]+\])?"#) }
    static let mainRegex = Regex(#"\bvoid[\s]+main[\s]*\([\s]*\)[\s\r\n]*\{"#)

    public func translate(_ source: String) -> Output {
        var attributes: [(name: String, hlsl: String, semantic: String)] = []
        var varyings: [Variable] = []
        var systemValues: [(hlsl: String, name: String, semantic: String)] = []
        var uniforms: [Variable] = []
        var body = ""
        body.reserveCapacity(source.count)

        for raw in ShaderSourceLoader.lines(source) {
            let line = String(raw)
            let trimmed = line.drop(while: { $0 == " " || $0 == "\t" })
            guard let keyword = Self.declKeywords.first(where: { kw in
                trimmed.hasPrefix(kw) && trimmed.dropFirst(kw.count).first.map { $0 == " " || $0 == "\t" } == true
            }) else {
                body += line + "\n"
                continue
            }
            if keyword == "attribute" {
                if let a = ShaderTables.attributes.first(where: { Self.containsWord(line, $0.name) }),
                   !attributes.contains(where: { $0.name == a.name }) {
                    attributes.append(a)
                }
                continue
            }
            guard let v = parseDeclaration(line) else { continue } // "HLSL var error": line dropped
            switch keyword {
            case "uniform":
                uniforms.append(v)
            default:
                if v.name == "gl_VertexID" { systemValues.append(("uint", v.name, "SV_VERTEXID")) }
                else if v.name == "gl_InstanceID" { systemValues.append(("uint", v.name, "SV_INSTANCEID")) }
                else { varyings.append(v) }
            }
        }
        if stage == .vertex {
            varyings.append(Variable(type: ShaderTables.typeVec4, name: "gl_Position", arrayCount: 0, packed: false, direction: 0))
        }

        var header = ShaderTables.prelude
        header += defines["BACKBUFFER_MS"] != nil ? ShaderTables.backBufferMS : ShaderTables.backBuffer

        // Structs
        switch stage {
        case .vertex:
            header += "struct VS_INPUT\n{\n"
            // Pin each attribute to its engine attribute id so Metal vertex descriptors are fixed per name.
            for a in attributes {
                let id = ShaderTables.attributes.firstIndex(where: { $0.name == a.name }) ?? 0
                header += "[[vk::location(\(id))]] \(a.hlsl) \(a.name) : \(a.semantic);\n"
            }
            header += "};\n\n"
            header += Self.varyingStruct("VS_OUTPUT", varyings.filter { $0.direction == 0 })
        case .geometry:
            let inputs = inputVaryings.map { $0.map { v -> Variable in var v = v; v.direction = 1; return v } }
            header += Self.varyingStruct("VS_OUTPUT", inputs ?? varyings.filter { $0.direction == 1 })
            header += Self.varyingStruct("PS_INPUT", varyings.filter { $0.direction == 2 })
        case .fragment:
            header += source.contains("gl_FragColor")
                ? "struct PS_OUTPUT\n{\nfloat4 gl_FragColor : SV_TARGET;\n};\n" : "struct PS_OUTPUT {};\n"
            header += Self.varyingStruct("VS_OUTPUT", varyings.filter { $0.direction == 0 && (linkedVaryings == nil || linkedVaryings![$0.name] != nil) },
                                         linked: linkedVaryings)
        }

        // Textures
        var textures: [Int: Int] = [:]
        for u in uniforms where u.type >= ShaderTables.typeSampler2D && u.type <= ShaderTables.typeSampler3D {
            guard u.name.hasPrefix("g_Texture"), u.name.count == 10, let slot = Int(String(u.name.last!)) else { continue }
            textures[slot] = u.type
            let n = u.name
            switch u.type {
            case ShaderTables.typeSampler3D:
                header += "Texture3D \(n):register(t\(slot));\nSamplerState \(n)SamplerState:register(s\(slot));\n"
            case ShaderTables.typeComparison:
                header += "Texture2D \(n):register(t\(slot));\nSamplerComparisonState \(n)SamplerComparisonState:register(s\(slot));\n"
            case ShaderTables.typeBackBuffer where defines["BACKBUFFER_MS"] != nil:
                header += "Texture2DMS<float4> \(n):register(t\(slot));\n"
            default:
                header += "Texture2D \(n):register(t\(slot));\nSamplerState \(n)SamplerState:register(s\(slot));\n"
            }
        }

        // Constant buffers
        var buffers: [[String]] = [[], [], [], []]
        var reflected: [Uniform] = []
        for u in uniforms where u.type < ShaderTables.typeSampler2D || u.type > ShaderTables.typeSampler3D {
            let buffer = (ShaderTables.builtinBuffers[u.name] ?? .statics).rawValue
            if buffer == ShaderTables.Buffer.lights.rawValue { continue } // generated from LIGHTS_* combos
            let decl: String
            if u.packed {
                let el = ShaderTables.packedElement(u.type)
                let k = (u.arrayCount + 3) / 4
                decl = "const \(el) \(u.name)[\(k)];\n"
                reflected.append(Uniform(name: u.name, hlslType: el, arrayCount: k, buffer: buffer))
            } else if buffer == ShaderTables.Buffer.animation.rawValue {
                let count = Self.arraySize(defines["BONECOUNT"] ?? "1", defines: defines)
                decl = "const float4x3 g_Bones[\(max(count, 1))];\n"
                reflected.append(Uniform(name: u.name, hlslType: "float4x3", arrayCount: max(count, 1), buffer: buffer))
            } else {
                let t = ShaderTables.types[u.type].hlsl
                decl = "const \(t) \(u.name)\(u.arrayCount > 0 ? "[\(u.arrayCount)]" : "");\n"
                reflected.append(Uniform(name: u.name, hlslType: t, arrayCount: u.arrayCount, buffer: buffer))
            }
            if !buffers[buffer].contains(decl) { buffers[buffer].append(decl) }
        }
        let names = ["g_bufStatic", "g_bufDynamic", "g_bufAnimation"]
        for b in 0..<3 where !buffers[b].isEmpty {
            header += "cbuffer \(names[b]):register(b\(b))\n{\n" + buffers[b].joined() + "}\n"
        }
        // `g_bufLights` (0x1400f74d5–0x1400f7e06): emitted when a light uniform is declared; its members come from the
        // LIGHTS_* defines, not from the declarations. The shadow-feature members follow the light arrays (strings
        // 0x140487848–0x140487910); photon2 fills members by name, so only their presence and sizes matter here.
        if uniforms.contains(where: { ShaderTables.builtinBuffers[$0.name] == .lights }) {
            func count(_ k: String) -> Int { Self.arraySize(defines[k] ?? "0", defines: defines) }
            var members: [(String, String, Int)] = []
            let p = count("LIGHTS_POINT"), s = count("LIGHTS_SPOT"), t = count("LIGHTS_TUBE"), d = count("LIGHTS_DIRECTIONAL")
            if p != 0 { members += [("float4", "g_LPoint_Color", p), ("float4", "g_LPoint_Origin", p)] }
            if s != 0 {
                members += [("float4", "g_LSpot_Color", s), ("float4", "g_LSpot_Origin", s), ("float4", "g_LSpot_Direction", s),
                            ("float4", "g_LSpot_Exponent", s)]
            }
            if t != 0 { members += [("float4", "g_LTube_Color", t), ("float4", "g_LTube_OriginA", t), ("float3", "g_LTube_OriginB", t)] }
            if d != 0 { members += [("float4", "g_LDirectional_Color", d), ("float3", "g_LDirectional_Direction", d)] }
            let features = count("LIGHTS_SPOT_SHADOW_COOKIE") + count("LIGHTS_SPOT_SHADOW") + count("LIGHTS_SPOT_COOKIE")
                + 3 * count("LIGHTS_DIRECTIONAL_SHADOW")
            if features != 0 {
                members += [("float4x4", "g_LFeature_ShadowProjection", features), ("float4", "g_LFeature_ShadowProjectionTransform", features)]
            }
            let pointShadows = count("LIGHTS_POINT_SHADOW")
            if pointShadows != 0 {
                members += [("float4", "g_LFeature_ShadowPointProjection", pointShadows),
                            ("float4", "g_LFeature_ShadowPointProjectionTransform", pointShadows)]
            }
            header += "cbuffer g_bufLights:register(b3)\n{\n"
            for (type, name, n) in members {
                header += "const \(type) \(name)[\(n)];\n"
                reflected.append(Uniform(name: name, hlslType: type, arrayCount: n, buffer: ShaderTables.Buffer.lights.rawValue))
            }
            header += "}\n"
        }

        let rewritten = rewriteMain(Self.staticConsts(body), attributes: attributes.map(\.name), varyings: varyings,
                                    uniforms: uniforms, systemValues: systemValues)
        var registers: [String: (register: Int, type: String)] = [:]
        var reg = 0
        let outDirection = stage == .geometry ? 2 : 0
        for v in varyings where v.direction == outDirection && v.name != "gl_Position" && v.name != "gl_ViewportIndex" {
            registers[v.name] = (reg, Self.declaredType(v))
            reg += Self.registerCount(v)
        }
        var out = Output(hlsl: header + Self.returnFromUncalledFunctions(rewritten), uniforms: reflected, textures: textures,
                         varyingRegisters: registers)
        out.exported = varyings.filter { $0.direction == outDirection }
        return out
    }

    // MARK: - FXC compatibility

    static let functionHeader = Regex(#"(?:^|[\s;}])([A-Za-z_][A-Za-z0-9_]*)\s+([A-Za-z_][A-Za-z0-9_]*)\s*\([^;{}#]*\)\s*(?::\s*[A-Za-z_][A-Za-z0-9_]*\s*)?$"#)

    /// FXC (D3DCompile in the engine) only analyses functions reachable from `main`, so a non-void helper whose body has
    /// no `return` at all (all of them preprocessed away, e.g. `ShadowMask` with `SHADOWMASK 0` in workshop shadow_map)
    /// compiles when nothing calls it; glslang rejects it while parsing. Such uncalled functions get a `return (T)0;`.
    /// A called one is left alone, so it still fails like FXC's X3080.
    /// `Hlsl_StaticConsts` 0x1400f3ea0 (called on the declaration-stripped body at 0x1400f6991, before the `main` rewrite):
    /// every line whose first non-blank (space/tab) text is the word `const` (followed by the end of the line or a character
    /// that is neither alphanumeric nor `_`) gets `static ` inserted before it, at any brace depth. A global `const` is a
    /// cbuffer constant in HLSL and needs a literal initialiser (X3011); `static const` takes any expression. Without this,
    /// FXC rejected workshop shaders whose global constants use expressions (tone_mapping, phantomtransitionfx,
    /// audio_responsive_oscilloscope; unknowns SH15).
    static func staticConsts(_ body: String) -> String {
        var out = ""
        out.reserveCapacity(body.count + 64)
        var first = true
        for line in body.split(separator: "\n", omittingEmptySubsequences: false) {
            if !first { out += "\n" }
            first = false
            let indent = line.prefix(while: { $0 == " " || $0 == "\t" })
            let rest = line.dropFirst(indent.count)
            if rest.hasPrefix("const"), rest.dropFirst(5).first.map({ !($0.isLetter || $0.isNumber || $0 == "_") }) ?? true {
                out += indent + "static " + rest
            } else {
                out += line
            }
        }
        return out
    }

    static func returnFromUncalledFunctions(_ text: String) -> String {
        let chars = Array(text.utf16)
        var depth = 0, i = 0, headerStart = 0
        var inserts: [(Int, String)] = []
        var openStack: [(pos: Int, type: String?, name: String)] = []
        while i < chars.count {
            let c = chars[i]
            if c == 0x2F, i + 1 < chars.count, chars[i + 1] == 0x2F { // `//` comment: skip to end of line
                while i < chars.count && chars[i] != 0x0A { i += 1 }
                continue
            }
            if c == 0x7B { // {
                if depth == 0 {
                    let header = String(utf16CodeUnits: Array(chars[headerStart..<i]), count: i - headerStart)
                    if let m = functionHeader.firstMatch(in: header), !["void", "struct", "cbuffer", "return"].contains(m[1]), m[2] != "main" {
                        openStack.append((i, m[1], m[2]))
                    } else {
                        openStack.append((i, nil, ""))
                    }
                }
                depth += 1
            } else if c == 0x7D { // }
                depth -= 1
                if depth == 0, let open = openStack.popLast() {
                    if let type = open.type {
                        let body = String(utf16CodeUnits: Array(chars[(open.pos + 1)..<i]), count: i - open.pos - 1)
                        if body.range(of: #"\breturn\b"#, options: .regularExpression) == nil {
                            // Whole-word `name(` occurrences; one is the definition itself.
                            let re = try? NSRegularExpression(pattern: "\\b" + NSRegularExpression.escapedPattern(for: open.name) + "\\s*\\(")
                            let calls = re?.numberOfMatches(in: text, range: NSRange(location: 0, length: (text as NSString).length)) ?? 2
                            if calls <= 1 { inserts.append((i, "\treturn (\(type))0;\n")) }
                        }
                    }
                    headerStart = i + 1
                }
                if depth < 0 { depth = 0 }
            } else if c == 0x3B, depth == 0 { // ;
                headerStart = i + 1
            }
            i += 1
        }
        guard !inserts.isEmpty else { return text }
        var out = chars
        for (pos, s) in inserts.reversed() { out.insert(contentsOf: Array(s.utf16), at: pos) }
        return String(utf16CodeUnits: out, count: out.count)
    }

    // MARK: - Declarations

    /// `sub_1400f4810`: the first type whose regex matches decides the declaration.
    func parseDeclaration(_ line: String) -> Variable? {
        for (i, re) in Self.typeRegexes.enumerated() {
            guard let m = re.firstMatch(in: line) else { continue }
            var count = 0
            if !m[3].isEmpty {
                count = Self.arraySize(String(m[3].dropFirst().dropLast()), defines: defines)
            }
            let packed = count > 0 && [ShaderTables.typeFloat, ShaderTables.typeVec2, ShaderTables.typeInt, ShaderTables.typeUint].contains(i)
            let direction = m[1] == "in" ? 1 : m[1] == "out" ? 2 : 0
            return Variable(type: i, name: m[2], arrayCount: count, packed: packed, direction: direction)
        }
        return nil
    }

    static func arraySize(_ text: String, defines: [String: String]) -> Int {
        let t = text.trimmingCharacters(in: .whitespaces)
        if let c = t.first, c.isNumber { return Int(t.prefix(while: { $0.isNumber })) ?? 0 }
        return Int((defines[t] ?? "").trimmingCharacters(in: .whitespaces)) ?? 0
    }

    static func declaredType(_ v: Variable) -> String {
        let t = v.packed ? "float4" : ShaderTables.types[v.type].hlsl
        return registerCount(v) > 1 ? "\(t)[\(registerCount(v))]" : t
    }

    static func vectorWidth(_ t: String) -> Int? {
        switch t {
        case "float": return 1
        case "float2": return 2
        case "float3": return 3
        case "float4": return 4
        default: return nil
        }
    }

    /// Expression converting `expr` of HLSL type `from` to `to` (truncate or zero-pad vectors).
    static func convert(_ expr: String, from: String, to: String) -> String? {
        guard let a = vectorWidth(from), let b = vectorWidth(to) else { return nil }
        if a == b { return expr }
        if b < a { return b == 1 ? "\(expr).x" : "\(expr).\(String("xyzw".prefix(b)))" }
        let pad = Array(repeating: "0", count: b - a).joined(separator: ", ")
        return "\(to)(\(expr), \(pad))"
    }

    static func registerCount(_ v: Variable) -> Int {
        guard v.arrayCount > 0 && v.arrayCount * (v.type + 1) > 4 else { return 1 }
        let per = v.type == ShaderTables.typeVec2 ? 2 : 4
        return (v.arrayCount + per - 1) / per
    }

    /// `sub_1400f52e0`. With `linked`, TEXCOORD indices come from the vertex stage.
    static func varyingStruct(_ name: String, _ vars: [Variable], linked: [String: (register: Int, type: String)]? = nil) -> String {
        var s = "struct \(name)\n{\n"
        var texcoord = 0
        for v in vars {
            if let linked, let l = linked[v.name] {
                texcoord = l.register
                // Declare with the vertex stage's type so the stages link; reads are converted in main.
                if l.type != declaredType(v), vectorWidth(l.type) != nil, !v.packed {
                    s += "[[vk::location(\(texcoord))]] \(l.type) \(v.name) : TEXCOORD\(texcoord);\n"
                    texcoord += 1
                    continue
                }
            }
            let t = v.packed ? "float4" : ShaderTables.types[v.type].hlsl
            var regs = 1
            var suffix = ""
            if v.arrayCount > 0 && v.arrayCount * (v.type + 1) > 4 {
                let per = v.type == ShaderTables.typeVec2 ? 2 : 4
                regs = (v.arrayCount + per - 1) / per
                suffix = "[\(regs)]"
            }
            let sem: String
            switch v.name {
            case "gl_Position": sem = "SV_POSITION"; regs = 0
            case "gl_ViewportIndex": sem = "SV_ViewportArrayIndex"; regs = 0
            default: sem = "TEXCOORD\(texcoord)"
            }
            // glslang numbers locations by struct position; pin them to the semantic index so stages link.
            // Metal cannot return arrays from a vertex function, so multi-register varyings become name_k members.
            if !suffix.isEmpty {
                for k in 0..<regs {
                    s += "[[vk::location(\(texcoord + k))]] \(t) \(v.name)_\(k) : TEXCOORD\(texcoord + k);\n"
                }
                texcoord += regs
                continue
            }
            let loc = sem.hasPrefix("TEXCOORD") ? "[[vk::location(\(texcoord))]] " : ""
            texcoord += regs
            s += "\(loc)\(t) \(v.name)\(suffix) : \(sem);\n"
        }
        return s + "};\n\n"
    }

    // MARK: - main()

    func rewriteMain(_ body: String, attributes: [String], varyings: [Variable], uniforms: [Variable],
                     systemValues: [(hlsl: String, name: String, semantic: String)]) -> String {
        guard let range = Self.mainRegex.firstRange(in: body) else { return body }
        let ns = body as NSString
        let before = ns.substring(to: range.location)
        var after = ns.substring(from: range.location + range.length)

        let sv = systemValues.map { ",\($0.hlsl) \($0.name):\($0.semantic)" }.joined()
        var signature: String
        var unpack = ""
        var writeBack = ""

        // Packed uniform arrays are unpacked at the top of main. The engine uses an HLSL array cast
        // ((float[16])x), which only FXC accepts; an explicit loop gives the same values.
        for u in uniforms where u.packed {
            unpack += Self.unpackArray(name: u.name, type: u.type, count: u.arrayCount, source: u.name)
        }

        switch stage {
        case .vertex:
            signature = "VS_OUTPUT main(VS_INPUT IN\(sv))\n{\n\tVS_OUTPUT OUT;\n"
            for v in varyings where v.packed {
                let t = ShaderTables.types[v.type].hlsl
                let len = Self.paddedLength(type: v.type, count: v.arrayCount)
                // The engine writes `= (T[len])0`, which only FXC accepts.
                let zeros = Array(repeating: "(\(t))0", count: len).joined(separator: ", ")
                unpack += "\(t) accessArray\(v.name)[\(len)] = { \(zeros) };\n"
                writeBack += Self.packArray(name: v.name, type: v.type, count: v.arrayCount)
            }
        case .fragment:
            signature = "PS_OUTPUT main(VS_OUTPUT IN\(sv))\n{\n\tPS_OUTPUT OUT;\n"
            if let linked = linkedVaryings {
                for v in varyings where v.direction == 0 && !v.packed {
                    guard let l = linked[v.name], l.type != Self.declaredType(v),
                          let conv = Self.convert("IN." + v.name, from: l.type, to: Self.declaredType(v)) else { continue }
                    unpack += "\(Self.declaredType(v)) linked_\(v.name) = \(conv);\n"
                }
                for v in varyings where v.direction == 0 && linked[v.name] == nil {
                    let t = v.packed ? "float4" : ShaderTables.types[v.type].hlsl
                    let arr = Self.registerCount(v) > 1 || (v.arrayCount > 0 && v.arrayCount * (v.type + 1) > 4) ? "[\(Self.registerCount(v))]" : ""
                    unpack += arr.isEmpty ? "\(t) unlinked_\(v.name) = (\(t))0;\n" : "\(t) unlinked_\(v.name)\(arr); [unroll] for (int ul_\(v.name) = 0; ul_\(v.name) < \(Self.registerCount(v)); ++ul_\(v.name)) unlinked_\(v.name)[ul_\(v.name)] = (\(t))0;\n"
                }
            }
            for v in varyings where v.packed {
                let isArray = v.arrayCount * (v.type + 1) > 4
                unpack += Self.unpackArray(name: v.name, type: v.type, count: v.arrayCount, source: "IN." + v.name, sourceIsArray: isArray, splitMembers: true,
                                           registers: Self.registerCount(v))
            }
        case .geometry:
            let triangles = after.contains("[input:triangles]") || before.contains("[input:triangles]")
            after = after.replacingOccurrences(of: "[input:triangles]", with: "")
            signature = triangles
                ? "void main(triangle VS_OUTPUT IN[3], inout TriangleStream<PS_INPUT> OUT\(sv))\n{\n\t"
                : "void main(point VS_OUTPUT IN[1], inout TriangleStream<PS_INPUT> OUT\(sv))\n{\n\t"
        }

        // Identifier replacement map
        var map: [String: String] = [:]
        switch stage {
        case .vertex:
            for a in attributes { map[a] = "IN." + a }
            for v in varyings { map[v.name] = v.packed ? "accessArray" + v.name : "OUT." + v.name }
        case .fragment:
            for v in varyings {
                if let linked = linkedVaryings, !v.packed {
                    if linked[v.name] == nil { map[v.name] = "unlinked_" + v.name; continue }
                    if let l = linked[v.name], l.type != Self.declaredType(v), Self.convert("x", from: l.type, to: Self.declaredType(v)) != nil {
                        map[v.name] = "linked_" + v.name; continue
                    }
                }
                map[v.name] = v.packed ? "accessArray" + v.name : "IN." + v.name
            }
            map["gl_FragColor"] = "OUT.gl_FragColor"
        case .geometry:
            break
        }
        for u in uniforms where u.packed { map[u.name] = "accessArray" + u.name }
        after = Self.replaceIdentifiers(after, map)

        if stage != .geometry, let last = after.lastIndex(of: "}") {
            after.insert(contentsOf: writeBack + "\treturn OUT;\n", at: last)
        }
        return before + signature + unpack + after
    }

    /// Number of logical elements the engine's accessArray covers: 4*ceil(n*comps/4)/comps.
    static func paddedLength(type: Int, count: Int) -> Int {
        let comps = type == ShaderTables.typeVec2 ? 2 : 1
        return 4 * ((count * comps + 3) / 4) / comps
    }

    /// `sourceIsArray` is false for a packed varying that fits one register (declared without `[k]`).
    /// `registers`: float4 registers backing the source. Uniform arrays get the engine's ceil(n/4)
    /// (docs/re/02 §2.7); varyings get ceil(n/2) for vec2 like the struct declaration.
    static func unpackArray(name: String, type: Int, count: Int, source: String, sourceIsArray: Bool = true, splitMembers: Bool = false,
                            registers: Int? = nil) -> String {
        let t = ShaderTables.types[type].hlsl
        let len = paddedLength(type: type, count: count)
        let comps = type == ShaderTables.typeVec2 ? 2 : 1
        let regs = sourceIsArray ? (registers ?? (count + 3) / 4) : 1
        // The engine's vec2 sizing under-allocates registers (docs/re/02 §2.7); reads past them yield 0.
        func element(_ flat: Int) -> String {
            if flat / 4 >= regs { return "0" }
            if sourceIsArray && splitMembers { return "\(source)_\(flat / 4)[\(flat % 4)]" }
            return sourceIsArray ? "\(source)[\(flat / 4)][\(flat % 4)]" : "\(source)[\(flat % 4)]"
        }
        var parts: [String] = []
        for i in 0..<len {
            parts.append(comps == 2 ? "\(t)(\(element(i * 2)), \(element(i * 2 + 1)))" : element(i))
        }
        return "\(t) accessArray\(name)[\(len)] = { \(parts.joined(separator: ", ")) };\n"
    }

    static func packArray(name: String, type: Int, count: Int) -> String {
        let regs = type == ShaderTables.typeVec2 ? (count + 1) / 2 : (count + 3) / 4
        let comps = type == ShaderTables.typeVec2 ? 2 : 1
        var s = ""
        for r in 0..<regs {
            var parts: [String] = []
            for c in 0..<4 {
                let flat = r * 4 + c
                let el = flat / comps
                parts.append(comps == 2 ? "accessArray\(name)[\(el)][\(flat % 2)]" : "accessArray\(name)[\(el)]")
            }
            let isArray = count * (type + 1) > 4
            s += "OUT.\(name)\(isArray ? "_\(r)" : "") = float4(\(parts.joined(separator: ", ")));\n"
        }
        return s
    }

    /// Maximal runs of [A-Za-z0-9_] are looked up and replaced verbatim (no `.`/comment/string checks).
    static func replaceIdentifiers(_ text: String, _ map: [String: String]) -> String {
        guard !map.isEmpty else { return text }
        var out = ""
        out.reserveCapacity(text.count + text.count / 8)
        var token = ""
        for ch in text {
            if ch.isASCII && (ch.isLetter || ch.isNumber || ch == "_") {
                token.append(ch)
            } else {
                if !token.isEmpty { out += map[token] ?? token; token = "" }
                out.append(ch)
            }
        }
        if !token.isEmpty { out += map[token] ?? token }
        return out
    }

    static func containsWord(_ line: String, _ word: String) -> Bool {
        var search = line.startIndex..<line.endIndex
        while let r = line.range(of: word, range: search) {
            let beforeOK = r.lowerBound == line.startIndex || !Self.isIdent(line[line.index(before: r.lowerBound)])
            let afterOK = r.upperBound == line.endIndex || !Self.isIdent(line[r.upperBound])
            if beforeOK && afterOK { return true }
            search = r.upperBound..<line.endIndex
        }
        return false
    }

    static func isIdent(_ c: Character) -> Bool { c.isASCII && (c.isLetter || c.isNumber || c == "_") }
}
