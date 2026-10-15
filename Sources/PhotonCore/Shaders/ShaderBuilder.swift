import Foundation

/// Assembles a shader program's HLSL the way `sub_140162ac0` does (docs/re/02 §1.1, §3).
public final class ShaderBuilder {
    public struct Request: Hashable {
        public var shader: String
        /// Material pass combos (keys are uppercased on input, as `sub_140154480` does).
        public var combos: [String: Int]
        /// Texture slots that have a texture bound, with their .tex format code.
        public var boundTextures: [Int: Int32]
        /// Texture flags per bound slot (bits 20+ select component combos).
        public var textureFlags: [Int: Int32]
        /// Formats of textures available to `formatcombo` slots, including shader defaults (0x1401a6902).
        public var formatTextures: [Int: Int32]
        /// Scene-level combos `sub_1401a5c40` sets on every program: `SCENE_ORTHO` (C+0x118 & 0x400, 0x1401a6403) and
        /// `HDR` (C+0x118 & 0x2000, 0x1401a6721).
        public var sceneCombos: [String: Int]
        /// Scene `general.lightconfig` packed as `C+0x121c` (scene load 0x140187b52–0x140187d00): point count in bits 0–3,
        /// spot 4–7, tube 8–11, directional 12–15, then 2-bit shadow/cookie counts.
        public var lightConfig: UInt32
        /// Scene fog flags (`C+0x118` bit 23 = `fogdistance`, bit 24 = `fogheight`, `Scene_UpdateFog` 0x140186440), as
        /// bit 0 = distance, bit 1 = height.
        public var fogFlags: Int = 0
        /// `C+0x1ac`, the shadow quality: `LIGHTS_SHADOW_MAPPING_QUALITY` of lit programs with shadowed lights.
        public var shadowQuality: Int = 0

        public init(shader: String, combos: [String: Int] = [:], boundTextures: [Int: Int32] = [:], textureFlags: [Int: Int32] = [:],
                    formatTextures: [Int: Int32] = [:], sceneCombos: [String: Int] = [:], lightConfig: UInt32 = 0, fogFlags: Int = 0,
                    shadowQuality: Int = 0) {
            self.fogFlags = fogFlags
            self.shadowQuality = shadowQuality
            self.formatTextures = formatTextures
            self.sceneCombos = sceneCombos
            self.lightConfig = lightConfig
            self.shader = shader
            self.combos = Dictionary(combos.map { ($0.key.uppercased(), $0.value) }, uniquingKeysWith: { _, b in b })
            self.boundTextures = boundTextures
            self.textureFlags = textureFlags
        }
    }

    public struct Program {
        public let vertex: HLSLTranslator.Output
        public let fragment: HLSLTranslator.Output
        public let combos: [String: Int]
        public let info: ShaderSourceLoader.Info
        /// The translated `.geom` stage, when the program has one (`GS_ENABLED` builds, docs/re/02 §1.1).
        public var geometry: HLSLTranslator.Output? = nil
        /// Vertex + geometry folded into one Metal vertex function (`GeometryEmulation`); nil when the geometry stage
        /// cannot be emulated (the program then has no geometry stage, like the engine's program flag 1 clear).
        public var emulation: GeometryEmulation.Result? = nil
        /// Why `emulation` is nil although `geometry` is set.
        public var emulationError: String? = nil
        /// The geometry stage's macros after preprocessing (`GeometryEmulation.buildNative` evaluates `[maxvertexcount]`).
        public var geometryMacros: [String: String] = [:]
    }

    /// `PHOTON_NOGS=1` (A/B only): build every program as if the device had no geometry shaders: `GS_ENABLED` is never
    /// defined and `.geom` files are not loaded, so particles take the engine's non-GS quad path.
    public static let noGeometryShaders = ProcessInfo.processInfo.environment["PHOTON_NOGS"] == "1"

    public enum Error: Swift.Error { case missingSource(String) }

    public let sources: ShaderSourceLoader

    public init(sources: ShaderSourceLoader) { self.sources = sources }

    /// Combo resolution (`sub_1401a5c40` steps 3 and 7): declared defaults fill missing combos, and
    /// `formatcombo` slots with a bound texture get `TEX<n>FORMAT`.
    public func resolveCombos(_ request: Request, info: ShaderSourceLoader.Info) -> [String: Int] {
        var combos = request.combos
        for c in info.combos where combos[c.name] == nil { combos[c.name] = c.defaultValue }
        // Lit programs get the scene's light counts (0x1401a5d49–0x1401a6400, only when LIGHTING is non-zero), the 2-bit
        // shadow/cookie counts, and with any shadow count `LIGHTS_SHADOW_MAPPING = 1` plus
        // `LIGHTS_SHADOW_MAPPING_QUALITY = C+0x1ac`; with any cookie count `LIGHTS_COOKIE = 1` (docs/re/06 §6.5).
        if (combos["LIGHTING"] ?? 0) != 0 {
            let lc = request.lightConfig
            combos["LIGHTS_POINT"] = Int(lc & 0xf)
            combos["LIGHTS_SPOT"] = Int((lc >> 4) & 0xf)
            combos["LIGHTS_TUBE"] = Int((lc >> 8) & 0xf)
            combos["LIGHTS_DIRECTIONAL"] = Int((lc >> 12) & 0xf)
            combos["LIGHTS_SPOT_SHADOW_COOKIE"] = Int((lc >> 20) & 3)
            combos["LIGHTS_SPOT_SHADOW"] = Int((lc >> 16) & 3)
            combos["LIGHTS_SPOT_COOKIE"] = Int((lc >> 18) & 3)
            combos["LIGHTS_DIRECTIONAL_SHADOW"] = Int((lc >> 22) & 3)
            combos["LIGHTS_POINT_SHADOW"] = Int((lc >> 24) & 3)
            let shadows = ((lc >> 20) & 3) + ((lc >> 16) & 3) + ((lc >> 22) & 3) + ((lc >> 24) & 3)
            if shadows > 0 {
                combos["LIGHTS_SHADOW_MAPPING"] = 1
                combos["LIGHTS_SHADOW_MAPPING_QUALITY"] = request.shadowQuality
            }
            if ((lc >> 18) & 3) + ((lc >> 20) & 3) > 0 { combos["LIGHTS_COOKIE"] = 1 }
        }
        for (k, v) in request.sceneCombos { combos[k] = v }
        // 0x1401a64a0–0x1401a666f: with scene fog on (C+0x118 & 0x1800000), a program whose combos have FOG ≠ 0 (after the
        // shader defaults, e.g. `// [COMBO] {"combo":"FOG","default":1}`) gets FOG_DIST / FOG_HEIGHT = 1.
        if request.fogFlags != 0, (combos["FOG"] ?? 0) != 0 {
            if request.fogFlags & 1 != 0 { combos["FOG_DIST"] = 1 }
            if request.fogFlags & 2 != 0 { combos["FOG_HEIGHT"] = 1 }
        }
        for (slot, s) in info.samplers where s.formatCombo {
            if let format = request.boundTextures[slot] ?? request.formatTextures[slot] { combos["TEX\(slot)FORMAT"] = Int(format) }
        }
        return combos
    }

    /// `#require LightingV1` (`sub_140169140`): when `LIGHTING` is non-zero, the per-light uniform arrays sized by the
    /// `LIGHTS_*` combos and a `PerformLighting_V1` that unrolls one block per light. Otherwise nothing.
    /// Shadowed and cookie lights come first in each type (docs/re/02 §LightingV1, session 4). The feature arrays:
    /// `g_LFeature_ShadowProjection` / `…Transform` sized spotcookie + spotshadow + spotshadowcookie + 3·directionalshadow
    /// (0x140169a1e–0x140169a9f), `g_LFeature_ShadowPointProjection` / `…Transform` sized pointshadow
    /// (0x140169ad9–0x140169b4f). Point lights: the first `LIGHTS_POINT_SHADOW` blocks sample the atlas
    /// (0x140169be5–0x140169d23), the rest are plain. Spots come in four runs that share one index i
    /// (0x140169e79–0x14016a43f): shadow+cookie (`CalculateProjectedCoords`, `PerformShadowMapping`, cookie colour),
    /// cookie only, shadow only (cone falloff × shadow), plain. Directional lights: cascade blocks with p1..p3
    /// (0x14016a5a6–0x14016ae20) for the first `LIGHTS_DIRECTIONAL_SHADOW`, then plain ones.
    public static func lightingV1(_ combos: [String: Int]) -> String {
        guard (combos["LIGHTING"] ?? 0) != 0 else { return "" }
        let points = combos["LIGHTS_POINT"] ?? 0, spots = combos["LIGHTS_SPOT"] ?? 0
        let tubes = combos["LIGHTS_TUBE"] ?? 0, directionals = combos["LIGHTS_DIRECTIONAL"] ?? 0
        var s = ""
        if points != 0 {
            s += "uniform vec4 g_LPoint_Color[\(points)];\n"
            s += "uniform vec4 g_LPoint_Origin[\(points)];\n"
        }
        if spots != 0 {
            s += "uniform vec4 g_LSpot_Color[\(spots)];\n"
            s += "uniform vec4 g_LSpot_Origin[\(spots)];\n"
            s += "uniform vec4 g_LSpot_Direction[\(spots)];\n"
            s += "uniform vec4 g_LSpot_Exponent[\(spots)];\n"
        }
        if tubes != 0 {
            s += "uniform vec4 g_LTube_Color[\(tubes)];\n"
            s += "uniform vec4 g_LTube_OriginA[\(tubes)];\n"
            s += "uniform vec4 g_LTube_OriginB[\(tubes)];\n"
        }
        if directionals != 0 {
            s += "uniform vec4 g_LDirectional_Color[\(directionals)];\n"
            s += "uniform vec4 g_LDirectional_Direction[\(directionals)];\n"
        }
        let spotShadowCookie = combos["LIGHTS_SPOT_SHADOW_COOKIE"] ?? 0, spotCookie = combos["LIGHTS_SPOT_COOKIE"] ?? 0
        let spotShadow = combos["LIGHTS_SPOT_SHADOW"] ?? 0
        let features = spotShadowCookie + spotCookie + spotShadow + 3 * (combos["LIGHTS_DIRECTIONAL_SHADOW"] ?? 0)
        if features != 0 {
            s += "uniform mat4 g_LFeature_ShadowProjection[\(features)];\n"
            s += "uniform vec4 g_LFeature_ShadowProjectionTransform[\(features)];\n"
        }
        let pointShadows = min(combos["LIGHTS_POINT_SHADOW"] ?? 0, max(points, 0))
        if pointShadows != 0 {
            s += "uniform vec4 g_LFeature_ShadowPointProjection[\(pointShadows)];\n"
            s += "uniform vec4 g_LFeature_ShadowPointProjectionTransform[\(pointShadows)];\n"
        }
        s += "vec3 PerformLighting_V1(vec3 worldPos, vec3 color, vec3 normal, vec3 viewVector, vec3 specularTint, vec3 ambient, float roughness, float metallic)\n{\n\tvec3 light = CAST3(0.0);\n"
        func block(_ i: Int, _ body: String) { s += "{\n\tconst uint i = \(i)u;\n" + body + "}\n" }
        for i in 0..<pointShadows {
            block(i, "\tvec3 lightDelta = g_LPoint_Origin[i].xyz - worldPos;\n"
                + "\tvec4 projectedCoords = CalculateProjectedCoordsPoint(worldPos, g_LPoint_Origin[i].xyz, g_LFeature_ShadowPointProjection[i], g_LFeature_ShadowPointProjectionTransform[i]);\n"
                + "\tfloat shadowFactor = PerformPointShadowMapping(projectedCoords);\n"
                + "\tlight += ComputePBRLightShadow(normal, lightDelta, viewVector, color, g_LPoint_Color[i].rgb, g_LPoint_Color[i].w, g_LPoint_Origin[i].w, specularTint, ambient, roughness, metallic, shadowFactor);\n")
        }
        for i in pointShadows..<max(points, pointShadows) {
            block(i, "\tvec3 lightDelta = g_LPoint_Origin[i].xyz - worldPos;\n"
                + "\tlight += ComputePBRLightShadow(normal, lightDelta, viewVector, color, g_LPoint_Color[i].rgb, g_LPoint_Color[i].w, g_LPoint_Origin[i].w, specularTint, ambient, roughness, metallic, 1.0);\n")
        }
        let delta = "\tvec3 lightDelta = g_LSpot_Origin[i].xyz - worldPos;\n"
        let proj = "\tvec3 projectedCoords = CalculateProjectedCoords(worldPos, g_LFeature_ShadowProjection[i]);\n"
        let shadow = "\tfloat shadowFactor = PerformShadowMapping(projectedCoords, g_LFeature_ShadowProjectionTransform[i]);\n"
        let cookie = "\tvec3 colorCookie = texSample2D(COOKIE_SAMPLER, projectedCoords.xy).rgb;\n"
        let cone = "\tfloat spotCookie = -dot(normalize(lightDelta), g_LSpot_Direction[i].xyz);\n"
            + "\tspotCookie = smoothstep(g_LSpot_Direction[i].w, g_LSpot_Origin[i].w, spotCookie);\n"
        func spotLight(_ tint: String, _ factor: String) -> String {
            "\tlight += ComputePBRLightShadow(normal, lightDelta, viewVector, color, g_LSpot_Color[i].rgb * \(tint), g_LSpot_Color[i].w, g_LSpot_Exponent[i].x, specularTint, ambient, roughness, metallic, \(factor));\n"
        }
        var si = 0
        for _ in 0..<max(spotShadowCookie, 0) { block(si, delta + proj + shadow + cookie + spotLight("colorCookie", "shadowFactor")); si += 1 }
        for _ in 0..<max(spotCookie, 0) { block(si, delta + proj + cookie + spotLight("colorCookie", "1.0")); si += 1 }
        for _ in 0..<max(spotShadow, 0) { block(si, delta + cone + proj + shadow + spotLight("spotCookie", "shadowFactor")); si += 1 }
        while si < spots { block(si, delta + cone + spotLight("spotCookie", "1.0")); si += 1 }
        for i in 0..<max(tubes, 0) {
            block(i, "\tvec3 lightDelta = PointSegmentDelta(worldPos, g_LTube_OriginA[i].xyz, g_LTube_OriginB[i].xyz);\n"
                + "\tlight += ComputePBRLightShadow(normal, lightDelta, viewVector, color, g_LTube_Color[i].rgb, g_LTube_Color[i].w, g_LTube_OriginA[i].w, specularTint, ambient, roughness, metallic, 1.0);\n")
        }
        // Directional shadows (0x14016a57d–0x14016ae42): `const uint i`, then p1..p3 = k, k + 1, k + 2 where k starts at the
        // first directional feature (= the spot index after the shadow runs, 0x14016a2e7) and advances by ONE per light
        // (`mov r13d, r14d` with r14 = p1 + 1, 0x14016ae36), although Lights_Update writes three features per light.
        var p1 = spotShadowCookie + spotCookie + spotShadow
        var di = 0
        for _ in 0..<max(min(combos["LIGHTS_DIRECTIONAL_SHADOW"] ?? 0, directionals), 0) {
            s += "{\n\tconst uint i = \(di)u;\n\tconst uint p1 = \(p1)u;\n\tconst uint p2 = \(p1 + 1)u;\n\tconst uint p3 = \(p1 + 2)u;\n"
                + "\tvec4 projectedCoords1 = CalculateProjectedCoordsCascades(worldPos, g_LFeature_ShadowProjection[p1]);\n"
                + "\tvec4 projectedCoords2 = CalculateProjectedCoordsCascades(worldPos, g_LFeature_ShadowProjection[p2]);\n"
                + "\tvec4 projectedCoords3 = CalculateProjectedCoordsCascades(worldPos, g_LFeature_ShadowProjection[p3]);\n"
                + "\tprojectedCoords1.xyz = mix(projectedCoords1.xyz, projectedCoords2.xyz, projectedCoords1.w);\n"
                + "\tprojectedCoords1.xyz = mix(projectedCoords1.xyz, projectedCoords3.xyz, projectedCoords2.w);\n"
                + "\tvec4 uvTransforms = mix(g_LFeature_ShadowProjectionTransform[p1], g_LFeature_ShadowProjectionTransform[p2], projectedCoords1.w);\n"
                + "\tuvTransforms = mix(uvTransforms, g_LFeature_ShadowProjectionTransform[p3], projectedCoords2.w);\n"
                + "\tfloat shadowFactor = max(projectedCoords3.w, PerformShadowMapping(projectedCoords1.xyz, uvTransforms));\n"
                + "\tlight += ComputePBRLightShadowInfinite(normal, g_LDirectional_Direction[i].xyz, viewVector, color, g_LDirectional_Color[i].rgb, specularTint, ambient, roughness, metallic, shadowFactor);\n"
                + "}\n"
            di += 1; p1 += 1
        }
        while di < directionals {
            block(di, "\tlight += ComputePBRLightShadowInfinite(normal, g_LDirectional_Direction[i].xyz, viewVector, color, g_LDirectional_Color[i].rgb, specularTint, ambient, roughness, metallic, 1.0);\n")
            di += 1
        }
        s += "\treturn light;\n}\n"
        return s
    }

    /// The define block: HLSL markers, `GS_ENABLED`, every combo, then bound-texture combos (`sub_140162ac0`,
    /// `sub_14016c400`, `sub_14016c800`). The engine defines `GS_ENABLED` for every program: the scene context is created
    /// with flags 0x100d (0x140110a19) and bit 3 of C+0x118 is what 0x140162dda tests. photon2 writes it only into programs
    /// whose sources mention it or that have a `.geom` stage; in every other program the define is unused, and leaving it
    /// out keeps their HLSL (and the compiled-shader cache) unchanged.
    public func defineBlock(_ combos: [String: Int], request: Request, info: ShaderSourceLoader.Info, geometryShaders: Bool = false) -> String {
        var s = "#define HLSL 1\n#define HLSL_SM40 1\n"
        if geometryShaders { s += "#define GS_ENABLED 1\n" }
        for (k, v) in combos.sorted(by: { $0.key < $1.key }) { s += "#define \(k) \(v)\n" }
        for slot in info.samplers.keys.sorted() {
            guard let sampler = info.samplers[slot], request.boundTextures[slot] != nil else { continue }
            if let combo = sampler.combo, !combo.isEmpty { s += "#define \(combo) 1\n" }
            let flags = request.textureFlags[slot] ?? 0
            for (j, combo) in sampler.componentCombos.enumerated() where flags & (0x100000 << j) != 0 {
                s += "#define \(combo) 1\n"
            }
        }
        return s
    }

    public func build(_ request: Request) throws -> Program {
        let info = sources.info(shader: request.shader)
        let combos = resolveCombos(request, info: info)
        func source(_ ext: String) -> String? { sources.load(stage: "shaders/\(request.shader).\(ext)") }
        guard var vertSource = source("vert") else { throw Error.missingSource("shaders/\(request.shader).vert") }
        guard let fragSource = source("frag") else { throw Error.missingSource("shaders/\(request.shader).frag") }
        // `.geom` is optional and only read when the device has geometry shaders (0x140162cb7; empty → no GS stage).
        let geomSource = Self.noGeometryShaders ? nil : source("geom").flatMap { $0.isEmpty ? nil : $0 }
        let gsDefine = !Self.noGeometryShaders
            && (geomSource != nil || vertSource.contains("GS_ENABLED") || fragSource.contains("GS_ENABLED"))
        if Self.noGeometryShaders && request.shader == "genericropeparticle" {
            // PHOTON_NOGS only: the engine's non-GS rope vertex shader offsets every corner by −1 (`right * uvs.x * 2.0 - 1.0`,
            // an operator-precedence slip in a path the engine never runs, unknowns P26). The A/B path centres the strip.
            vertSource = vertSource.replacingOccurrences(of: "position += right * uvs.x * 2.0 - 1.0;",
                                                         with: "position += right * (uvs.x * 2.0 - 1.0);")
        }
        let defines = defineBlock(combos, request: request, info: info, geometryShaders: gsDefine)

        func stage(_ src: String, _ st: HLSLTranslator.Stage, linked: [String: (register: Int, type: String)]? = nil,
                   inputs: [HLSLTranslator.Variable]? = nil) -> (HLSLTranslator.Output, [String: String]) {
            var pp = ShaderPreprocessor()
            pp.require = { name in name == "LightingV1" ? Self.lightingV1(combos) : "" }
            let processed = pp.run(defines + src)
            return (HLSLTranslator(stage: st, defines: pp.macros, linkedVaryings: linked, inputVaryings: inputs).translate(processed), pp.macros)
        }
        let vertex = stage(vertSource, .vertex).0
        guard let geomSource else {
            return Program(vertex: vertex, fragment: stage(fragSource, .fragment, linked: vertex.varyingRegisters).0, combos: combos, info: info)
        }
        // With a geometry stage the translator chains the varying lists VS → GS → PS (0x1400f5f75–0x1400f6073): the GS input
        // struct is the VS output list and the PS input struct is the GS `out` list.
        let (geometry, gsMacros) = stage(geomSource, .geometry, inputs: vertex.exported)
        var program = Program(vertex: vertex, fragment: stage(fragSource, .fragment, linked: geometry.varyingRegisters).0,
                              combos: combos, info: info)
        program.geometry = geometry
        program.geometryMacros = gsMacros
        do {
            program.emulation = try GeometryEmulation.build(vertex: vertex, geometry: geometry, geometryMacros: gsMacros)
        } catch {
            program.emulationError = "\(error)"
        }
        return program
    }

    /// The emulated vertex function with a capture buffer (`photon-tool gs-check`): every list vertex's emitted record.
    public func buildCapture(_ request: Request) throws -> (program: Program, capture: GeometryEmulation.Result)? {
        let program = try build(request)
        guard let geometry = program.geometry, program.emulation != nil,
              let geomSource = sources.load(stage: "shaders/\(request.shader).geom") else { return nil }
        var pp = ShaderPreprocessor()
        let info = sources.info(shader: request.shader)
        _ = pp.run(defineBlock(program.combos, request: request, info: info, geometryShaders: true) + geomSource)
        return (program, try GeometryEmulation.build(vertex: program.vertex, geometry: geometry, geometryMacros: pp.macros, capture: true))
    }
}
