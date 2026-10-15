import Foundation

/// Geometry-shader emulation for Metal, which has no geometry stage.
///
/// The engine always compiles particle programs with their `.geom` stage (scene context flags 0x100d, bit 3 →
/// `#define GS_ENABLED 1` in `ShaderProgram_LoadSources` 0x140162ac0; GS compiled as `gs_5_0` by
/// `ShaderProgram_CompileStage` 0x1400d44e0 and created with `CreateGeometryShader` (device vt+0x68, no stream output) at
/// 0x1400d5e1f; bound with `GSSetShader` + `GSSetConstantBuffers(b0, b1)` in `ShaderProgram_Bind` 0x1400d7440). Particle
/// vertex buffers are then point lists, one point per element (docs/re/05 §5.3).
///
/// photon2 folds the vertex and geometry stages into one Metal vertex function. The draw is a non-indexed triangle list,
/// one instance per input point, `3 · (maxvertexcount − 2)` vertices per instance; the point's attributes step per instance.
/// Each vertex invocation runs the program's vertex `main` on its instance's point, then the geometry `main`, and keeps the
/// one emitted vertex that is its corner of its triangle when the emitted strips are converted to a list:
/// strip triangle j uses strip vertices (j, j+1, j+2) for even j and (j+1, j, j+2) for odd j (D3D11 and Metal define strips
/// the same way), triangles in emission order, strips in `RestartStrip` order, instances in point order. Triangle slots past
/// the ones the GS produced get one shared clip-space point outside the view volume, so they are zero-area and clipped.
/// The output geometry, its order and winding are those of the engine's GS; only the floating-point evaluation is Metal's.
public enum GeometryEmulation {
    public struct Result {
        /// The combined vertex-stage HLSL (vertex `main`, geometry `main`, entry `main`).
        public let hlsl: String
        /// `[maxvertexcount(n)]` after macro expansion.
        public let maxVertexCount: Int
        /// The source calls `RestartStrip`: the entry runs the geometry shader twice (find the triangle, then its vertex).
        public let restarts: Bool

        /// Vertices per input point in the emulated draw.
        public var listVertexCount: Int { 3 * max(maxVertexCount - 2, 0) }
        /// `buildNative` only: the pass-through vertex stage (`hlsl` is then the geometry stage).
        public var nativeVertexHLSL: String? = nil
    }

    public enum Failure: Swift.Error, CustomStringConvertible {
        case unsupported(String)
        public var description: String { switch self { case .unsupported(let s): return "GS emulation: \(s)" } }
    }

    /// The same composition for a device with a native geometry stage (Vulkan on Linux, `PHOTON_NATIVE_GS=1`):
    /// `hlsl` is a geometry shader and `nativeVertexHLSL` a pass-through vertex shader. The vertex stage forwards the
    /// point's VS_INPUT and SV_VertexID; the geometry stage runs the program's vertex `main` and geometry `main` once per
    /// point, exactly the text and data flow of the emulated function, collects the emitted vertices and their strip
    /// positions, and appends each triangle as an independent triangle in D3D11's strip order ((i, i+1, i+2) for even,
    /// (i+1, i, i+2) for odd strip triangles: Vulkan's own strip order for odd triangles is (i, i+2, i+1), another
    /// provoking vertex). Keeping the vertex math inside the geometry stage gives the shader compiler the same
    /// expression trees as the emulation, so the two paths produce the same pixels, not only the same triangles.
    /// Constant buffers are the emulation's merged blocks; the backend binds the vertex stage's bytes to them.
    ///
    /// `passThrough` (the check behind `PHOTON_NATIVE_GS=passthrough`): `hlsl` is instead a geometry shader that passes
    /// each triangle of the *emulated* draw through unchanged (`nativeVertexHLSL` nil: the emulated vertex function
    /// stays). The native pair renders byte-identical to that, which shows that the two paths emit the same triangles
    /// with the same attribute bits and isolates what the driver's geometry-stage path changes (docs/linux-port.md §2.2).
    public static func buildNative(vertex: HLSLTranslator.Output, geometry: HLSLTranslator.Output,
                                   geometryMacros: [String: String], passThrough: Bool = false) throws -> Result {
        try build(vertexHLSL: vertex.hlsl, geometryHLSL: geometry.hlsl, geometryMacros: geometryMacros, capture: false,
                  native: passThrough ? .passThrough : .native)
    }

    enum NativeMode { case none, native, passThrough }

    /// `capture`: also write every emitted vertex's clip position and TEXCOORD registers into `RWByteAddressBuffer`
    /// register u7 (`photon-tool gs-check`), which needs a pipeline with rasterization disabled.
    static func build(vertex: HLSLTranslator.Output, geometry: HLSLTranslator.Output, geometryMacros: [String: String],
                      capture: Bool = false) throws -> Result {
        try build(vertexHLSL: vertex.hlsl, geometryHLSL: geometry.hlsl, geometryMacros: geometryMacros, capture: capture)
    }

    /// Raw-HLSL programs (`shaders/HLSL/*`, which bypass the translator, docs/re/02 §2.9): `defines` are prepended to both
    /// stages, which then go through photon2's preprocessor so conditionals are resolved before the stages are merged.
    /// Used by the wallpaper-switch transition (`dx11playlisttransition.geom`, WallpaperTransition).
    public static func buildRaw(vertexHLSL: String, geometryHLSL: String, defines: String) throws -> Result {
        var vpp = ShaderPreprocessor(), gpp = ShaderPreprocessor()
        let vs = vpp.run(defines + vertexHLSL.replacingOccurrences(of: "\r\n", with: "\n"))
        let gs = gpp.run(defines + geometryHLSL.replacingOccurrences(of: "\r\n", with: "\n"))
        return try build(vertexHLSL: vs, geometryHLSL: gs, geometryMacros: gpp.macros, capture: false)
    }

    static func build(vertexHLSL: String, geometryHLSL: String, geometryMacros: [String: String], capture: Bool,
                      native: NativeMode = .none) throws -> Result {
        var vs = vertexHLSL, gs = geometryHLSL

        // Constant buffers: D3D11 gives each stage its own b0/b1 (filled by the same `FillConstants` by name), so one merged
        // block per register holds the same values.
        var merged: [Int: (name: String, members: [(String, String)])] = [:]
        func takeCBuffers(_ text: inout String) {
            let re = try! NSRegularExpression(pattern: #"cbuffer\s+(\w+)\s*:\s*register\(b(\d+)\)\s*\{([^}]*)\}\s*;?"#)
            let ns = text as NSString
            for m in re.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
                let name = ns.substring(with: m.range(at: 1)), reg = Int(ns.substring(with: m.range(at: 2))) ?? 0
                var entry = merged[reg] ?? (name, [])
                for line in ns.substring(with: m.range(at: 3)).split(separator: "\n") {
                    let l = line.trimmingCharacters(in: .whitespaces)
                    guard !l.isEmpty, let member = memberName(l) else { continue }
                    if !entry.members.contains(where: { $0.0 == member }) { entry.members.append((member, l)) }
                }
                merged[reg] = entry
            }
            text = re.stringByReplacingMatches(in: text, range: NSRange(location: 0, length: ns.length), withTemplate: "")
        }
        takeCBuffers(&vs)
        takeCBuffers(&gs)

        // Vertex main → gs_emu_vs_main; its system-value parameters are fed from the instance (the point's vertex index).
        let vsMain = try! NSRegularExpression(pattern: #"\bVS_OUTPUT\s+main\s*\(\s*VS_INPUT\s+IN((?:\s*,\s*\w+\s+\w+\s*:\s*\w+)*)\s*\)"#)
        guard let vm = vsMain.firstMatch(in: vs, range: NSRange(location: 0, length: (vs as NSString).length)) else {
            throw Failure.unsupported("vertex main not found")
        }
        var vsArgs = "IN"
        let svText = (vs as NSString).substring(with: vm.range(at: 1))
        for part in svText.split(separator: ",") where !part.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let sem = part.split(separator: ":").last.map { $0.trimmingCharacters(in: .whitespaces).uppercased() } ?? ""
            vsArgs += sem == "SV_VERTEXID" ? ", gs_emu_iid" : ", 0u"
        }
        vs = (vs as NSString).replacingCharacters(in: vm.range, with: "VS_OUTPUT gs_emu_vs_main(VS_INPUT IN\(svText))")

        // Geometry main signature, streams, maxvertexcount.
        let gsMain = try! NSRegularExpression(pattern: #"\bvoid\s+main\s*\(\s*(point|line|triangle|lineadj|triangleadj)\s+(\w+)\s+(\w+)\s*\[\s*(\d+)\s*\]\s*,\s*inout\s+(Point|Line|Triangle)Stream\s*<\s*(\w+)\s*>\s*(\w+)"#)
        guard let gm = gsMain.firstMatch(in: gs, range: NSRange(location: 0, length: (gs as NSString).length)) else {
            throw Failure.unsupported("geometry main not found")
        }
        let gns = gs as NSString
        let primitive = gns.substring(with: gm.range(at: 1)), inputType = gns.substring(with: gm.range(at: 2))
        let inputName = gns.substring(with: gm.range(at: 3)), inputCount = gns.substring(with: gm.range(at: 4))
        let streamKind = gns.substring(with: gm.range(at: 5)), vertexType = gns.substring(with: gm.range(at: 6))
        let streamName = gns.substring(with: gm.range(at: 7))
        guard primitive == "point", inputCount == "1" else { throw Failure.unsupported("\(primitive) input with \(inputCount) vertices") }
        guard streamKind == "Triangle" else { throw Failure.unsupported("\(streamKind)Stream output") }
        gs = gns.replacingCharacters(in: gm.range, with: "void gs_emu_main(\(inputType) \(inputName)[1], uint \(streamName)")
        // Helper functions taking a stream: the stream becomes a dummy uint (the state is global).
        let streamParam = try! NSRegularExpression(pattern: #"inout\s+(?:Point|Line|Triangle)Stream\s*<\s*\w+\s*>\s*(\w+)"#)
        var streams: Set<String> = [streamName]
        for m in streamParam.matches(in: gs, range: NSRange(location: 0, length: (gs as NSString).length)) {
            streams.insert((gs as NSString).substring(with: m.range(at: 1)))
        }
        gs = streamParam.stringByReplacingMatches(in: gs, range: NSRange(location: 0, length: (gs as NSString).length), withTemplate: "uint $1")
        for s in streams {
            let e = NSRegularExpression.escapedPattern(for: s)
            gs = gs.replacingOccurrences(of: #"\b\#(e)\s*\.\s*Append\s*\("#, with: "gs_emu_Append(", options: .regularExpression)
            gs = gs.replacingOccurrences(of: #"\b\#(e)\s*\.\s*RestartStrip\s*\(\s*\)"#, with: "gs_emu_RestartStrip()", options: .regularExpression)
        }
        let restarts = gs.contains("gs_emu_RestartStrip()")
        let maxRe = try! NSRegularExpression(pattern: #"\[\s*maxvertexcount\s*\(([^\]]*)\)\s*\]"#)
        guard let mm = maxRe.firstMatch(in: gs, range: NSRange(location: 0, length: (gs as NSString).length)) else {
            throw Failure.unsupported("no [maxvertexcount]")
        }
        var pp = ShaderPreprocessor()
        pp.macros = geometryMacros
        let maxVertexCount = pp.evaluate((gs as NSString).substring(with: mm.range(at: 1)))
        guard (3...1024).contains(maxVertexCount) else { throw Failure.unsupported("maxvertexcount \(maxVertexCount)") }
        gs = maxRe.stringByReplacingMatches(in: gs, range: NSRange(location: 0, length: (gs as NSString).length), withTemplate: "")

        // Top-level declarations: the geometry text repeats the prelude, the shared includes and the shared VS_OUTPUT struct.
        // Identical chunks are dropped; a different chunk with a name the vertex text declares is renamed `gs_<name>`.
        let vsChunks = topLevelChunks(vs)
        let vsSet = Set(vsChunks.filter { !$0.preprocessor }.map { normalized($0.text) })
        let vsNames = Set(vsChunks.compactMap { declaredName($0.text) })
        var gsChunks = topLevelChunks(gs).filter { $0.preprocessor || !vsSet.contains(normalized($0.text)) }
        var renames: [String: String] = [:]
        for c in gsChunks where !c.preprocessor {
            if let n = declaredName(c.text), vsNames.contains(n), n != "gs_emu_main" { renames[n] = "gs_" + n }
        }
        if !renames.isEmpty {
            gsChunks = gsChunks.map { Chunk(text: HLSLTranslator.replaceIdentifiers($0.text, renames), preprocessor: $0.preprocessor) }
        }
        let positionMember = svPositionMember(geometryHLSL, structName: vertexType) ?? "gl_Position"
        // Vertex → geometry link: the translator gives both stages one struct (VS_OUTPUT); raw HLSL links by semantic.
        var link = "\tgs_emu_in[0] = gs_emu_vs_main(\(vsArgs));\n"
        if inputType != "VS_OUTPUT" {
            let outs = structMembers(vertexHLSL, structName: "VS_OUTPUT")
            link = "\tVS_OUTPUT gs_emu_vo = gs_emu_vs_main(\(vsArgs));\n"
            for m in structMembers(geometryHLSL, structName: inputType) {
                if let o = outs.first(where: { $0.semantic.uppercased() == m.semantic.uppercased() }) {
                    link += "\tgs_emu_in[0].\(m.name) = (\(m.type))gs_emu_vo.\(o.name);\n"
                } else {
                    link += "\tgs_emu_in[0].\(m.name) = (\(m.type))0;\n"
                }
            }
        }

        // Macros: each stage's text runs with its own macro state. The vertex text's macros are undefined after it and the
        // geometry text's `#define`s are each preceded by `#undef`.
        var vsMacros: [String] = []
        for line in vs.split(separator: "\n") {
            if let name = defineName(line) { vsMacros.append(name) }
        }

        var out = "// photon2 geometry-shader emulation (GeometryEmulation.swift): vertex + geometry stages in one vertex function\n"
        for reg in merged.keys.sorted() {
            let b = merged[reg]!
            out += "cbuffer \(b.name):register(b\(reg))\n{\n" + b.members.map { $0.1 + "\n" }.joined() + "}\n"
        }
        out += vs
        out += "\n"
        for name in Set(vsMacros).sorted() { out += "#undef \(name)\n" }
        let helpers = native == .native ? Self.nativeHelpers(vertexType: vertexType, maxVertexCount: maxVertexCount)
            : Self.helpers(vertexType: vertexType, maxVertexCount: maxVertexCount)
        var helpersPlaced = false
        for c in gsChunks {
            if c.preprocessor, let name = defineName(Substring(c.text)) { out += "#undef \(name)\n" }
            out += c.text
            if !c.text.hasSuffix("\n") { out += "\n" }
            if !helpersPlaced, !c.preprocessor, declaredName(c.text) == vertexType, c.text.contains("struct") {
                out += helpers
                helpersPlaced = true
            }
        }
        if !helpersPlaced { throw Failure.unsupported("stream vertex struct \(vertexType) not found") }

        if native == .passThrough {
            out += "\n[maxvertexcount(3)]\nvoid main(triangle \(vertexType) gs_pt[3], inout TriangleStream<\(vertexType)> gs_pt_stream)\n{\n"
            out += "\tgs_pt_stream.Append(gs_pt[0]);\n\tgs_pt_stream.Append(gs_pt[1]);\n\tgs_pt_stream.Append(gs_pt[2]);\n}\n"
            return Result(hlsl: out, maxVertexCount: maxVertexCount, restarts: restarts)
        }
        if native == .native {
            // Pass-through vertex stage: VS_INPUT members under private semantics, plus the vertex id (the point index).
            let inputs = structMembers(vertexHLSL, structName: "VS_INPUT")
            guard !inputs.isEmpty else { throw Failure.unsupported("native GS: VS_INPUT not found") }
            var pass = "\nstruct gs_nat_V\n{\n"
            for (k, m) in inputs.enumerated() { pass += "\t\(m.type) \(m.name) : GSNAT\(k);\n" }
            pass += "\tuint gs_nat_vid : GSNATVID;\n};\n"
            var vsOut = ""
            for reg in merged.keys.sorted() {
                let b = merged[reg]!
                vsOut += "cbuffer \(b.name):register(b\(reg))\n{\n" + b.members.map { $0.1 + "\n" }.joined() + "}\n"
            }
            vsOut += vs + pass
            vsOut += "gs_nat_V main(VS_INPUT IN, uint gs_nat_id : SV_VertexID)\n{\n\tgs_nat_V o;\n"
            for m in inputs { vsOut += "\to.\(m.name) = IN.\(m.name);\n" }
            vsOut += "\to.gs_nat_vid = gs_nat_id;\n\treturn o;\n}\n"
            out += pass
            out += "\n[maxvertexcount(\(3 * max(maxVertexCount - 2, 1)))]\n"
            out += "void main(point gs_nat_V gs_nat_p[1], inout TriangleStream<\(vertexType)> gs_nat_stream)\n{\n\tVS_INPUT IN;\n"
            for m in inputs { out += "\tIN.\(m.name) = gs_nat_p[0].\(m.name);\n" }
            out += "\tuint gs_emu_iid = gs_nat_p[0].gs_nat_vid;\n"
            out += "\t\(inputType) gs_emu_in[1];\n" + link
            out += "\tgs_emu_n = 0u;\n\tgs_emu_strip = 0u;\n\tgs_emu_main(gs_emu_in, 0u);\n"
            out += "\tfor (uint i = 2u; i < gs_emu_n; i++) {\n\t\tuint s = gs_nat_s[i];\n\t\tif (s < 2u) continue;\n"
            out += "\t\tif ((s & 1u) == 0u) { gs_nat_stream.Append(gs_nat_v[i - 2u]); gs_nat_stream.Append(gs_nat_v[i - 1u]); }\n"
            out += "\t\telse { gs_nat_stream.Append(gs_nat_v[i - 1u]); gs_nat_stream.Append(gs_nat_v[i - 2u]); }\n"
            out += "\t\tgs_nat_stream.Append(gs_nat_v[i]);\n\t\tgs_nat_stream.RestartStrip();\n\t}\n}\n"
            var r = Result(hlsl: out, maxVertexCount: maxVertexCount, restarts: restarts)
            r.nativeVertexHLSL = vsOut
            return r
        }

        // The capture variant returns nothing (Metal: no rasterization requires a void vertex function).
        out += "\n\(capture ? "void" : vertexType) main(VS_INPUT IN, uint gs_emu_vid : SV_VertexID, uint gs_emu_iid : SV_InstanceID)\n{\n"
        out += "\t\(inputType) gs_emu_in[1];\n" + link
        out += "\tgs_emu_tri = gs_emu_vid / 3u;\n\tgs_emu_corner = gs_emu_vid - gs_emu_tri * 3u;\n"
        out += "\tgs_emu_n = 0u;\n\tgs_emu_strip = 0u;\n\tgs_emu_tris = 0u;\n\tgs_emu_want = 0xffffffffu;\n"
        out += "\tgs_emu_out = (\(vertexType))0;\n"
        if restarts {
            out += "\tgs_emu_pass = 0u;\n\tgs_emu_main(gs_emu_in, 0u);\n\tbool gs_emu_ok = gs_emu_want != 0xffffffffu;\n"
            out += "\tgs_emu_n = 0u;\n\tgs_emu_strip = 0u;\n\tgs_emu_pass = 1u;\n\tif (gs_emu_ok) gs_emu_main(gs_emu_in, 0u);\n"
        } else {
            // One strip: triangle t is strip vertices t, t+1, t+2 (odd t swaps the first two).
            out += "\tuint gs_emu_c = gs_emu_corner;\n\tif ((gs_emu_tri & 1u) != 0u && gs_emu_c < 2u) gs_emu_c = 1u - gs_emu_c;\n"
            out += "\tgs_emu_want = gs_emu_tri + gs_emu_c;\n\tgs_emu_pass = 1u;\n\tgs_emu_main(gs_emu_in, 0u);\n"
            out += "\tbool gs_emu_ok = gs_emu_tri + 2u < gs_emu_n;\n"
        }
        out += "\t\(vertexType) gs_emu_v = gs_emu_out;\n"
        out += "\tif (!gs_emu_ok) gs_emu_v.\(positionMember) = float4(2.0, 2.0, 2.0, 1.0);\n"
        if capture {
            // Capture record per list vertex: valid flag, emission index, clip position, then every TEXCOORD member.
            let members = structMembers(geometryHLSL, structName: vertexType).filter { $0.name != positionMember }
            let stride = 4 * (2 + 4 + 4 * members.count)
            out += "\tuint gs_emu_rec = (gs_emu_iid * \(3 * max(maxVertexCount - 2, 0))u + gs_emu_vid) * \(stride)u;\n"
            out += "\tgs_emu_capture.Store2(gs_emu_rec, uint2(gs_emu_ok ? 1u : 0u, gs_emu_want));\n"
            out += "\tgs_emu_capture.Store4(gs_emu_rec + 8u, asuint(gs_emu_v.\(positionMember)));\n"
            for (k, m) in members.enumerated() {
                let pad: String
                switch m.type {
                case "float": pad = "float4(gs_emu_v.\(m.name), 0, 0, 0)"
                case "float2": pad = "float4(gs_emu_v.\(m.name), 0, 0)"
                case "float3": pad = "float4(gs_emu_v.\(m.name), 0)"
                default: pad = "float4(gs_emu_v.\(m.name))"
                }
                out += "\tgs_emu_capture.Store4(gs_emu_rec + \(24 + 16 * k)u, asuint(\(pad)));\n"
            }
        }
        out += capture ? "}\n" : "\treturn gs_emu_v;\n}\n"
        if capture { out = "RWByteAddressBuffer gs_emu_capture : register(u7);\n" + out }
        return Result(hlsl: out, maxVertexCount: maxVertexCount, restarts: restarts)
    }

    /// `buildNative`: every emitted vertex and its position in its strip, for the triangles the entry appends.
    static func nativeHelpers(vertexType: String, maxVertexCount: Int) -> String {
        """

        // Geometry-shader output of this invocation (GeometryEmulation.buildNative).
        static uint gs_emu_n;
        static uint gs_emu_strip;
        static \(vertexType) gs_nat_v[\(maxVertexCount)];
        static uint gs_nat_s[\(maxVertexCount)];
        void gs_emu_Append(\(vertexType) v)
        {
        \tif (gs_emu_n >= \(maxVertexCount)u) return;
        \tgs_nat_v[gs_emu_n] = v;
        \tgs_nat_s[gs_emu_n] = gs_emu_strip;
        \tgs_emu_strip++;
        \tgs_emu_n++;
        }
        void gs_emu_RestartStrip()
        {
        \tgs_emu_strip = 0u;
        }

        """
    }

    /// The members of the emitted vertex struct in declaration order (for the capture record).
    public static func captureMembers(geometryHLSL: String, structName: String = "PS_INPUT") -> [(name: String, type: String)] {
        let pos = svPositionMember(geometryHLSL, structName: structName) ?? "gl_Position"
        return structMembers(geometryHLSL, structName: structName).filter { $0.name != pos }.map { ($0.name, $0.type) }
    }

    static func helpers(vertexType: String, maxVertexCount: Int) -> String {
        """

        // Geometry-shader output state of this vertex invocation (GeometryEmulation.swift).
        static uint gs_emu_n;
        static uint gs_emu_strip;
        static uint gs_emu_tris;
        static uint gs_emu_tri;
        static uint gs_emu_corner;
        static uint gs_emu_want;
        static uint gs_emu_pass;
        static \(vertexType) gs_emu_out;
        void gs_emu_Append(\(vertexType) v)
        {
        \tif (gs_emu_n >= \(maxVertexCount)u) return;
        \tif (gs_emu_pass == 0u) {
        \t\tif (gs_emu_strip >= 2u) {
        \t\t\tif (gs_emu_tris == gs_emu_tri) {
        \t\t\t\tuint c = gs_emu_corner;
        \t\t\t\tif (((gs_emu_strip - 2u) & 1u) != 0u && c < 2u) c = 1u - c;
        \t\t\t\tgs_emu_want = gs_emu_n - 2u + c;
        \t\t\t}
        \t\t\tgs_emu_tris++;
        \t\t}
        \t} else if (gs_emu_n == gs_emu_want) {
        \t\tgs_emu_out = v;
        \t}
        \tgs_emu_strip++;
        \tgs_emu_n++;
        }
        void gs_emu_RestartStrip()
        {
        \tgs_emu_strip = 0u;
        }

        """
    }

    // MARK: - Text helpers

    struct Chunk {
        var text: String
        var preprocessor: Bool
    }

    /// Splits HLSL text into top-level pieces: preprocessor lines, and declarations ending at a depth-0 `;` or at the `}`
    /// that returns to depth 0 (plus a following `;`). Comments stay inside their chunk.
    static func topLevelChunks(_ text: String) -> [Chunk] {
        var chunks: [Chunk] = []
        let c = Array(text.unicodeScalars)
        var i = 0, depth = 0, start = 0
        var atLineStart = true
        func flush(_ end: Int, pre: Bool = false) {
            if end > start {
                var s = String.UnicodeScalarView()
                s.append(contentsOf: c[start..<end])
                let t = String(s)
                if !t.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { chunks.append(Chunk(text: t, preprocessor: pre)) }
            }
            start = end
        }
        while i < c.count {
            let ch = c[i]
            if ch == "/" && i + 1 < c.count && c[i + 1] == "/" {
                while i < c.count && c[i] != "\n" { i += 1 }
                continue
            }
            if ch == "/" && i + 1 < c.count && c[i + 1] == "*" {
                i += 2
                while i + 1 < c.count && !(c[i] == "*" && c[i + 1] == "/") { i += 1 }
                i += 2
                continue
            }
            if depth == 0 && atLineStart && ch == "#" {
                // A preprocessor line: whatever came before it on earlier lines is its own chunk.
                var lineStart = i
                while lineStart > start && c[lineStart - 1] != "\n" { lineStart -= 1 }
                flush(lineStart)
                while i < c.count && c[i] != "\n" { i += 1 }
                if i < c.count { i += 1 }
                flush(i, pre: true)
                atLineStart = true
                continue
            }
            if ch == "\n" { atLineStart = true } else if ch != " " && ch != "\t" && ch != "\r" { atLineStart = false }
            if ch == "{" { depth += 1 }
            if ch == "}" {
                depth = max(depth - 1, 0)
                if depth == 0 {
                    var j = i + 1
                    while j < c.count && (c[j] == " " || c[j] == "\t" || c[j] == "\r" || c[j] == "\n") { j += 1 }
                    if j < c.count && c[j] == ";" { i = j }
                    i += 1
                    flush(i)
                    continue
                }
            }
            if ch == ";" && depth == 0 {
                i += 1
                flush(i)
                continue
            }
            i += 1
        }
        flush(c.count)
        return chunks
    }

    static func normalized(_ s: String) -> String {
        s.split(whereSeparator: { $0 == " " || $0 == "\t" || $0 == "\n" || $0 == "\r" }).joined(separator: " ")
    }

    static let functionRe = try! NSRegularExpression(pattern: #"^\s*(?:\[[^\]]*\]\s*)*(?:(?:static|inline|precise)\s+)*[A-Za-z_][A-Za-z0-9_<>]*\s+([A-Za-z_][A-Za-z0-9_]*)\s*\("#)
    static let structRe = try! NSRegularExpression(pattern: #"^\s*struct\s+([A-Za-z_][A-Za-z0-9_]*)"#)
    static let variableRe = try! NSRegularExpression(pattern: #"^\s*(?:(?:static|const|uniform|groupshared)\s+)*[A-Za-z_][A-Za-z0-9_<>]*\s+([A-Za-z_][A-Za-z0-9_]*)\s*(?:\[[^\]]*\])?\s*(?::[^=;]*)?[=;]"#)

    /// The name a top-level chunk declares (function, struct or global), after leading comments.
    static func declaredName(_ chunk: String) -> String? {
        var lines: [Substring] = []
        for l in chunk.split(separator: "\n", omittingEmptySubsequences: false) {
            let t = l.trimmingCharacters(in: .whitespaces)
            if lines.isEmpty && (t.isEmpty || t.hasPrefix("//")) { continue }
            lines.append(l)
        }
        let text = lines.joined(separator: "\n")
        let r = NSRange(location: 0, length: (text as NSString).length)
        for re in [structRe, functionRe, variableRe] {
            if let m = re.firstMatch(in: text, range: r) { return (text as NSString).substring(with: m.range(at: 1)) }
        }
        return nil
    }

    static func memberName(_ line: String) -> String? {
        let re = try! NSRegularExpression(pattern: #"([A-Za-z_][A-Za-z0-9_]*)\s*(?:\[[^\]]*\])?\s*;"#)
        guard let m = re.firstMatch(in: line, range: NSRange(location: 0, length: (line as NSString).length)) else { return nil }
        return (line as NSString).substring(with: m.range(at: 1))
    }

    static func defineName(_ line: Substring) -> String? {
        let t = line.drop(while: { $0 == " " || $0 == "\t" })
        guard t.hasPrefix("#") else { return nil }
        let rest = t.dropFirst().drop(while: { $0 == " " || $0 == "\t" })
        guard rest.hasPrefix("define") else { return nil }
        let name = rest.dropFirst(6).drop(while: { $0 == " " || $0 == "\t" }).prefix(while: { $0.isLetter || $0.isNumber || $0 == "_" })
        return name.isEmpty ? nil : String(name)
    }

    /// Members (`T name : SEMANTIC;`) of a generated varying struct.
    static func structMembers(_ hlsl: String, structName: String) -> [(name: String, type: String, semantic: String)] {
        guard let r = hlsl.range(of: #"struct\s+\#(structName)\s*\{"#, options: .regularExpression), let end = hlsl.range(of: "};", range: r.upperBound..<hlsl.endIndex) else { return [] }
        let body = hlsl[r.upperBound..<end.lowerBound]
        let re = try! NSRegularExpression(pattern: #"(?:\[\[[^\]]*\]\]\s*)?(\w+)\s+(\w+)\s*:\s*(\w+)\s*;"#)
        var out: [(String, String, String)] = []
        for line in body.split(separator: "\n") {
            let l = String(line)
            guard let m = re.firstMatch(in: l, range: NSRange(location: 0, length: (l as NSString).length)) else { continue }
            let ns = l as NSString
            out.append((ns.substring(with: m.range(at: 2)), ns.substring(with: m.range(at: 1)), ns.substring(with: m.range(at: 3))))
        }
        return out
    }

    static func svPositionMember(_ hlsl: String, structName: String) -> String? {
        structMembers(hlsl, structName: structName).first { $0.semantic.uppercased() == "SV_POSITION" }?.name
    }
}
