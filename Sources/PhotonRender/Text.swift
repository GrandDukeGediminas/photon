import Foundation
import Metal
import PhotonCore
import simd

/// A text object (docs/re/04 §4.3, §4.3.1). Text is a layer: it shares `Layer_Render` 0x1401e8aa0 with images,
/// with text-specific hooks for geometry (vt+0x110 0x140258900), the composite draw (vtE0 0x140257c30,
/// vtE8 0x140257d70), the direct draw (vtF0 0x140258050) and the screen anchor (vt+0xa8 0x1402585c0).
final class TextObject: SceneObject {
    enum Anchor: Int { case none, center, top, topright, right, bottomright, bottom, bottomleft, left, topleft }

    let resources: SceneResources
    weak var scene: SceneRenderer?
    let library: FontLibrary

    // Reflected text fields (Text_RegisterProps 0x140258ca0; defaults from Text_Ctor 0x140256ae0).
    var text = ""
    var font = "systemfont_arial"
    var pointSize: Float = 32
    var padding = SIMD2<Float>(32, 32)
    var spacing = SIMD2<Float>(0, 0)
    var maxWidth: Float = 500
    var maxRows = 1
    var backgroundColor = SIMD3<Float>(0, 0, 0)
    var backgroundBrightness: Float = 1
    var opaqueBackground = false, limitWidth = false, limitRows = false, limitUseEllipsis = false, blockAlign = false
    var msdf = false, outline = false, blur = false, dropShadow = false
    // Text effect parameters (+0x520…+0x54c; Text_Ctor defaults).
    var outlineThickness: Float = 4
    var outlineColor = SIMD3<Float>(0, 0, 0)
    var blurSize: Float = 6
    var dropShadowSize: Float = 6
    var dropShadowOpacity: Float = 1
    var dropShadowOffset = SIMD2<Float>(4, 4)
    var dropShadowColor = SIMD3<Float>(0, 0, 0)
    /// `depthtest` +0x5a0 (enum 0x14025b0e0, table built at 0x14025a4a6: "disabled" = 1 first, "enabled" = 0; the ctor
    /// default is 0 = enabled, and any other string takes the first entry, disabled).
    var depthTestEnabled = true
    var horizontalAlign = 1 // left 0, center 1, right 2
    var verticalAlign = 1   // bottom 0, center 1, top 2
    var anchor = Anchor.none

    // Layer fields (Layer_RegisterProps 0x1401ee520).
    var color = SIMD3<Float>(1, 1, 1)
    var alpha: Float = 1
    var brightness: Float = 1
    var colorBlendMode = 0
    var clampUVs = true
    var effects: [Effect] = []
    var compositeSteps = 0
    /// `Layer_LoadEffects` 0x1401e6f50 (text calls it at 0x140256df9): blend mode, `ledsource`, scene fog, or being a
    /// dependency (`SceneData_Load` 0x1401881b0) force the dedicated composite.
    var needComposite: Bool {
        loadBlendComposite || ledSource || resources.fogFlags != 0 || isDependency
    }
    /// flags304 & 0x10 from the blend mode is fixed at load (`Layer_LoadEffects` 0x1401e6f50); a later script write of
    /// `colorBlendMode` does not switch the layer to the composite path (see ImageLayer.loadBlendComposite).
    private(set) var loadBlendComposite = false
    var ledSource = false
    /// Text vt+0x68 0x1402577e0: visible, or `flags304 & 0x1100`.
    override var renderVisible: Bool { effectiveVisible || ledSource || isDependency }
    var hasComposite: Bool { compositeSteps > 0 || needComposite }

    // Derived state.
    var block: TextBlock?
    /// Layer size (+0x2f0) = text bounds + 2·padding; the JSON `size` is overwritten.
    var size = SIMD2<Float>(2, 2)
    /// Alignment offset (+0x2f8) from horizontalalign / verticalalign.
    var alignOffset = SIMD2<Float>(0, 0)
    var targets: [RenderTarget] = []
    var rtSize = SIMD2<Int>(4, 4)
    var pendingClears: [(RenderTarget, [Float])] = []
    var effectQuad: Quad?, objectQuad: Quad?, backgroundQuad: Quad?, clearAlphaQuad: Quad?
    var layerWorldSaved = Mat.identity
    var layerMVP = Mat.identity
    /// The layout request's depth byte (req+0x19, `Text_Rebuild` 0x14025746a–0x140257485): perspective scene (C+0x118 &
    /// 0x400 clear) and `depthtest` enabled. It selects the `_depth` font and background materials.
    var depthFlag: Bool { !resources.sceneOrtho && depthTestEnabled }
    private var fontMaterials: [String: Material] = [:]
    /// `Font_DrawBlock` 0x1401b3430 material caches: basefont[rgba][_msdf][_depth].json; the MSDF variants are created per
    /// combo index (0x1401b3b60) with OUTLINE_ENABLED / BLUR_ENABLED / DROP_SHADOW_ENABLED.
    func fontMaterial(color: Bool, msdf: Bool, combos: [String: Int]) -> Material {
        let path = "materials/fonts/basefont\(color ? "rgba" : "")\(msdf ? "_msdf" : "")\(depthFlag ? "_depth" : "").json"
        let key = path + combos.keys.sorted().joined(separator: ",")
        if let m = fontMaterials[key] { return m }
        let m = combos.isEmpty ? resources.material(path) : resources.material(path, override: ["combos": combos])
        fontMaterials[key] = m
        return m
    }
    /// 0x1402582ff–0x140258326: fontbackground_depth.json under the same condition.
    var backgroundMaterial: Material { fontMaterial(path: depthFlag ? "materials/fonts/fontbackground_depth.json" : "materials/fonts/fontbackground.json") }
    func fontMaterial(path: String) -> Material {
        if let m = fontMaterials[path] { return m }
        let m = resources.material(path)
        fontMaterials[path] = m
        return m
    }
    var composeMaterial: Material?
    var clearAlphaMaterial: Material?

    init(json: [String: Any], id: Int, resources: SceneResources) {
        self.resources = resources
        library = FontLibrary.shared(resources)
        super.init(json: json, id: id)

        // A `script` on the text value (clocks, dates, …) starts from this `value`; SceneScript.swift writes
        // the script's result through `scriptSetText`, which rebuilds when the string changes.
        text = Self.string(json["text"]) ?? ""
        if let f = Self.string(json["font"]) { font = f }
        if let v = Self.float(json["pointsize"]) { pointSize = v }
        if let v = Self.vec2(json["padding"]) { padding = v }
        if let v = Self.vec2(json["spacing"]) { spacing = v }
        if let v = Self.float(json["maxwidth"]) { maxWidth = v }
        if let v = Self.float(json["maxrows"]) { maxRows = Int(v) }
        if let c = Self.vec3(json["backgroundcolor"]) { backgroundColor = c }
        if let v = Self.float(json["backgroundbrightness"]) { backgroundBrightness = v }
        opaqueBackground = jsonBool(json["opaquebackground"], default: false)
        limitWidth = jsonBool(json["limitwidth"], default: false)
        limitRows = jsonBool(json["limitrows"], default: false)
        limitUseEllipsis = jsonBool(json["limituseellipsis"], default: false)
        blockAlign = jsonBool(json["blockalign"], default: false)
        msdf = jsonBool(json["msdf"], default: false)
        outline = jsonBool(json["outline"], default: false)
        blur = jsonBool(json["blur"], default: false)
        dropShadow = jsonBool(json["dropshadow"], default: false)
        if let v = Self.float(json["outlinethickness"]) { outlineThickness = v }
        if let c = Self.vec3(json["outlinecolor"]) { outlineColor = c }
        if let v = Self.float(json["blursize"]) { blurSize = v }
        if let v = Self.float(json["dropshadowsize"]) { dropShadowSize = v }
        if let v = Self.float(json["dropshadowopacity"]) { dropShadowOpacity = v }
        if let v = Self.vec2(json["dropshadowoffset"]) { dropShadowOffset = v }
        if let c = Self.vec3(json["dropshadowcolor"]) { dropShadowColor = c }
        if json["depthtest"] != nil { depthTestEnabled = Self.string(json["depthtest"]) == "enabled" }
        // Enum loaders: unknown strings take the first table entry (left / center / none).
        switch Self.string(json["horizontalalign"]) {
        case nil: break
        case "center": horizontalAlign = 1
        case "right": horizontalAlign = 2
        default: horizontalAlign = 0
        }
        switch Self.string(json["verticalalign"]) {
        case nil: break
        case "top": verticalAlign = 2
        case "bottom": verticalAlign = 0
        default: verticalAlign = 1
        }
        if let a = Self.string(json["anchor"]) {
            let names = ["none", "center", "top", "topright", "right", "bottomright", "bottom", "bottomleft", "left", "topleft"]
            anchor = Anchor(rawValue: names.firstIndex(of: a) ?? 0) ?? .none
        }

        if let c = Self.vec3(json["color"]) { color = c }
        if let a = Self.float(json["alpha"]) { alpha = a }
        if let b = Self.float(json["brightness"]) { brightness = b }
        colorBlendMode = (unwrapUserValue(json["colorBlendMode"]) as? NSNumber)?.intValue ?? 0
        loadBlendComposite = colorBlendMode != 0 && colorBlendMode != 31
        clampUVs = jsonBool(json["clampuvs"], default: true)
        ledSource = jsonBool(json["ledsource"], default: false)
        for key in ["alpha", "brightness", "color", "backgroundcolor", "backgroundbrightness"] {
            if let a = PropertyAnimation(json: json[key]) { animations[key] = a }
        }

        var effectID = 1 << 20
        for (ei, e) in ((json["effects"] as? [[String: Any]]) ?? []).enumerated() {
            guard let file = e["file"] as? String else { continue }
            effectID += 1
            let eid = (e["id"] as? NSNumber)?.intValue ?? effectID
            guard let effect = Effect(path: file, instance: e, id: eid, scene: resources) else { continue }
            effect.jsonIndex = ei
            if effect.visible { compositeSteps += 1 + effect.composeCount }
            effects.append(effect)
        }
        makeComposeMaterial()
        rebuild()
    }

    func makeComposeMaterial() {
        guard needComposite, composeMaterial == nil else { return }
        // Text_CreateComposeMaterial (vt+0xc0, 0x140257840).
        let combos: [String: Any] = ["BLENDMODE": colorBlendMode, "FOG_COMPUTED": 1]
        var inst: [String: Any] = ["combos": combos]
        // 0x140257a92–0x140257af8: perspective scene, `depthtest` enabled and scene version ≥ 2 → "depthtest": "enabled".
        if depthFlag && resources.sceneVersion >= 2 { inst["depthtest"] = "enabled" }
        composeMaterial = resources.material(resources.composeMaterialPath, override: inst)
    }

    /// `SceneData_Load` 0x1401881b0 → text vt+0x110 0x140258900 when the dependency newly needs a composite.
    func markDependency() {
        guard !isDependency else { return }
        let had = needComposite
        isDependency = true
        if !had { makeComposeMaterial(); rebuild() }
    }

    // MARK: - Value loading (docs/re/04 §0)

    static func string(_ v: Any?) -> String? {
        switch unwrapUserValue(v) {
        case let s as String: return s
        case let n as NSNumber: return n.stringValue
        default: return nil
        }
    }

    /// Float loader: tag ≤ 3 including null (→ 0).
    static func float(_ v: Any?) -> Float? {
        let u = unwrapUserValue(v)
        if u is NSNull { return 0 }
        if let n = u as? NSNumber { return n.floatValue }
        return nil
    }

    /// vec2 loader: a number fills both components, a string is "x y" (missing → 0).
    static func vec2(_ v: Any?) -> SIMD2<Float>? {
        let u = unwrapUserValue(v)
        if let n = u as? NSNumber { return SIMD2(n.floatValue, n.floatValue) }
        if let s = u as? String {
            let f = s.split(whereSeparator: { $0 == " " }).map { Float($0) ?? 0 }
            return SIMD2(f.first ?? 0, f.count > 1 ? f[1] : 0)
        }
        return nil
    }

    // MARK: - Layout and geometry

    /// Padding applies only when the layer composites or draws a background (0x140258900).
    var effectivePadding: SIMD2<Float> {
        hasComposite || opaqueBackground ? simd_min(padding, SIMD2(512, 512)) : .zero
    }

    /// `Text_Rebuild` 0x140256f20 + geometry rebuild 0x140258900.
    func rebuild() {
        var req = TextLayoutRequest()
        req.font = font
        req.pointSize = pointSize
        req.spacing = spacing
        req.horizontalAlign = horizontalAlign
        req.maxWidth = limitWidth ? maxWidth : 0
        req.maxRows = limitRows ? maxRows : 0
        req.ellipsis = limitUseEllipsis
        req.blockAlign = blockAlign
        req.msdf = msdf || outline || blur || dropShadow
        let b = TextLayout.build(text, req, library: library)
        block = b

        // Alignment offset: x from horizontalalign, y from verticalalign using the face ascender/descender.
        let lh = b.lineHeight, n = Float(b.lineCount)
        var off = SIMD2<Float>(0, b.maxY - b.height * 0.5)
        switch horizontalAlign {
        case 0: off.x = b.width * 0.5
        case 2: off.x = -b.width * 0.5
        default: break
        }
        switch verticalAlign {
        case 0: off.y -= b.descender - (n - 1) * lh
        case 1: off.y -= (b.ascender - (n - 1) * lh) * 0.5
        default: off.y -= b.ascender
        }
        alignOffset = off

        let pad = effectivePadding
        size = SIMD2(b.width, b.height) + 2 * pad
        // vt+0x128 0x140258ab0: rt size = (int)size, uvScale 1, linear filtering.
        let W = Int(size.x), H = Int(size.y)
        let ts = SIMD2(Float(W), Float(H))
        effectQuad = Quad(size: SIMD2(2, 2), textureSize: ts, uvScale: SIMD2(1, 1), flags: .centered)
        objectQuad = Quad(size: SIMD2(Float(W), Float(H)), textureSize: ts, uvScale: SIMD2(1, 1), flags: [.centered, .inset])
        backgroundQuad = Quad(size: SIMD2(Float(max(W, 4)), Float(max(H, 4))), textureSize: ts, uvScale: SIMD2(1, 1), flags: [])
        clearAlphaQuad = Quad(size: size, textureSize: SIMD2(1, 1), uvScale: SIMD2(1, 1), flags: .centered)
        if hasComposite {
            allocateTargets(W, H)
            if clearAlphaMaterial == nil { clearAlphaMaterial = resources.material("materials/util/composelayer_clearalpha.json") }
        }
    }

    /// `Layer_AllocRenderTargets` 0x1401ea500 with the text sizes.
    func allocateTargets(_ w: Int, _ h: Int) {
        targets.forEach { resources.targets.release($0) }
        targets = []
        let W = max(w, 4), H = max(h, 4)
        rtSize = SIMD2(W, H)
        let format = renderTargetFormat(hdr: resources.hdr)
        let count = min(2, compositeSteps + (needComposite ? 1 : 0))
        for i in 0..<count {
            let name = (needComposite && i == 0) ? "_rt_imageLayerComposite_\(id)_a"
                : SceneObject.scratchName("sc.\(W).\(H).b\(clampUVs ? "c" : "r")\(i)", for: self)
            targets.append(resources.targets.acquire(name, width: W, height: H, format: format, samplerFlags: clampUVs ? 2 : 0))
        }
        for effect in effects {
            for k in effect.fbos.indices {
                let f = effect.fbos[k]
                var fw = (f.width ?? 0xFFFF) <= 4096 ? f.width! : W
                var fh = (f.height ?? 0xFFFF) <= 4096 ? f.height! : H
                if let fit = f.fit, fit <= 4096 {
                    if fw >= fh { let nw = min(fit, fw); fh = Int(Float(fh) / Float(fw) * Float(nw)); fw = nw }
                    else { let nh = min(fit, fh); fw = Int(Float(fw) / Float(fh) * Float(nh)); fh = nh }
                }
                var name = f.name
                if f.unique { name += "_\(effect.id)" } else { name += "_\(fw)_\(fh)_\(f.scale)" }
                if let existing = f.target {
                    existing.resize(device: resources.device, width: fw, height: fh)
                } else {
                    effect.fbos[k].target = resources.targets.acquire(name, width: fw, height: fh, scale: f.scale,
                                                                      format: ImageLayer.fboFormat(f.format), samplerFlags: f.repeatUVs ? 0 : 2)
                }
                if let clear = f.clear, let rt = effect.fbos[k].target { pendingClears.append((rt, clear)) }
            }
        }
    }

    /// Text world (vt+0x80 0x140256e10): the object world with the alignment offset applied locally.
    var layerWorld: simd_float4x4 { world * Mat.translate(SIMD3(alignOffset.x, alignOffset.y, 0)) }

    /// vt+0xa8 0x1402585c0: keeps the text on a screen edge when cover/contain fitting crops the scene. Uses the
    /// crops `cl, ct, cr, cb` (R+0x110), recovered here from the ortho projection.
    func anchorOffset(_ frame: FrameState, _ scene: SceneRenderer) -> SIMD2<Float> {
        guard anchor != .none, scene.isOrtho else { return .zero }
        let p = frame.proj
        let rl = 2 / p[0][0], tb = 2 / p[1][1]
        let l = (-p[3][0] * rl - rl) / 2, b = (-p[3][1] * tb - tb) / 2
        let cl = l, cr = scene.orthoSize.x - (l + rl), cb = b, ct = scene.orthoSize.y - (b + tb)
        let midX = (cl - cr) * 0.5, midY = (cb - ct) * 0.5
        switch anchor {
        case .none: return .zero
        case .center: return SIMD2(midX, midY)
        case .top: return SIMD2(midX, -ct)
        case .topright: return SIMD2(-cr, -ct)
        case .right: return SIMD2(-cr, midY)
        case .bottomright: return SIMD2(-cr, cb)
        case .bottom: return SIMD2(midX, cb)
        case .bottomleft: return SIMD2(cl, cb)
        case .left: return SIMD2(cl, midY)
        case .topleft: return SIMD2(cl, -ct)
        }
    }

    // MARK: - Render

    override func update(_ dt: Float) { super.update(dt) }

    override func apply(_ key: String, _ v: [Float]) {
        switch key {
        case "alpha": if let a = v.first { alpha = a }
        case "brightness": if let b = v.first { brightness = b }
        case "color": if v.count >= 3 { color = SIMD3(v[0], v[1], v[2]) }
        case "backgroundcolor": if v.count >= 3 { backgroundColor = SIMD3(v[0], v[1], v[2]) }
        case "backgroundbrightness": if let b = v.first { backgroundBrightness = b }
        default: super.apply(key, v)
        }
    }

    var blend: BlendState { BlendState(mode: colorBlendMode == 31 ? .additive : .translucent) }
    /// Text_Ctor 0x140256cc7 always sets +0x120 |= 0x100.
    override var isTransparent: Bool { true }

    override func render(_ ctx: RenderContext, _ frame: FrameState, _ scene: SceneRenderer) {
        if ProcessInfo.processInfo.environment["PHOTON_TEXTDEBUG"] != nil, let b = block {
            NSLog("text %d vis=%d '%@' block=(%.1f,%.1f,%.1f,%.1f) size=%@ world=%@ verts=%d alpha=%.3f scale=%@ color=%@", id, effectiveVisible ? 1 : 0, text,
                  b.minX, b.minY, b.maxX, b.maxY, "\(size)", "\(layerWorld.columns.3)", b.grayVertices.count / 5, alpha, "\(scale)", "\(color)")
        }
        guard renderVisible, block != nil else { return }
        if Frustum.layerCulled(frame, world: layerWorld, offset: SIMD3(alignOffset.x, alignOffset.y, 0), size: size,
                               exempt: ledSource || isDependency) { return }
        for (rt, c) in pendingClears {
            ctx.bind(rt.texture)
            ctx.clear(MTLClearColor(red: Double(c[0]), green: Double(c[1]), blue: Double(c[2]), alpha: Double(c[3])))
            ctx.unbind()
        }
        pendingClears.removeAll()
        let W2 = layerWorld
        let a = anchorOffset(frame, scene)
        let anchored = Mat.translate(SIMD3(a.x, a.y, 0))

        if !hasComposite {
            guard effectiveVisible else { return }
            let saved = frame.model
            frame.model = saved * anchored * W2
            withPerspective(frame, scene) { drawDirect(ctx, frame, scene) }
            frame.model = saved
            return
        }

        // Effect / composite path (Layer_Render). Text layers always need the background snapshot (vt+0x118), except
        // under a passthrough parent (`+0x180` with `+0x120 & 4`, 0x1401e8f63).
        if (parent as? ImageLayer)?.passthrough != true { ctx.copyCurrent(into: scene.fullFrameBuffer.texture) }
        let savedModel = frame.model, savedView = frame.view, savedProj = frame.proj
        layerWorldSaved = W2
        layerMVP = frame.proj * frame.view * W2
        let total = needComposite ? compositeSteps : compositeSteps - 1
        var src = total & 1
        guard !targets.isEmpty else { return }
        if targets.count == 1 { src = 0 }
        ctx.bind(targets[src].texture)
        drawCompositeBackground(ctx, frame, scene, world: W2)
        frame.model = Mat.identity; frame.view = Mat.identity
        frame.proj = Mat.orthoLH(l: 0, r: Float(rtSize.x), b: 0, t: Float(rtSize.y), zn: -1000, zf: 1000)
        drawIntoComposite(ctx, frame, scene)
        ctx.unbind()

        frame.model = Mat.identity; frame.view = Mat.identity
        frame.proj = Mat.orthoLH(l: -1, r: 1, b: -1, t: 1, zn: -1000, zf: 1000)
        var step = 0
        var finalEffect: Effect?
        var finalPass = 0
        var fbCopied = false
        effectLoop: for effect in effects where effect.visible {
            var dst = targets.count > 1 ? 1 - src : src
            var bound = false
            for p in effect.passes.indices {
                if !needComposite && step == total {
                    // 0x1401e9c3e → 0x1401e9c54: the bound-target epilogue still runs before leaving.
                    finalEffect = effect; finalPass = p
                    if bound { step += 1; ctx.unbind(); src = dst }
                    break effectLoop
                }
                if !bound {
                    bound = true
                    if effect.readsFrameBuffer && !fbCopied { ctx.copyCurrent(into: scene.fullFrameBuffer.texture); fbCopied = true }
                    ctx.bind(targets[dst].texture)
                }
                runPass(effect, p, src: src, final: false, ctx, frame, scene)
                if effect.passes[p].compose {
                    step += 1
                    if step < total { ctx.unbind(); swap(&src, &dst); ctx.bind(targets[dst].texture) }
                }
            }
            if bound { step += 1; ctx.unbind(); src = dst }
        }
        frame.model = savedModel; frame.view = savedView; frame.proj = savedProj

        guard effectiveVisible else { return }
        let m = frame.model, v = frame.view, pr = frame.proj
        frame.model = m * anchored * W2
        if perspective && scene.isOrtho { scene.pushPerspective(frame) }   // Layer_Render 0x1401e9e9f
        defer { frame.view = v; frame.proj = pr }
        if needComposite, let C = composeMaterial {
            draw(C, objectQuad!.mesh, ctx, frame, scene, blend: blend, color: SIMD3(1, 1, 1), alpha: 1,
                 textures: [0: BoundTexture(target: targets[src])])
        } else if let fe = finalEffect {
            if !fbCopied && fe.readsFrameBuffer { ctx.copyCurrent(into: scene.fullFrameBuffer.texture) }
            for p in finalPass..<fe.passes.count { runPass(fe, p, src: src, final: true, ctx, frame, scene) }
        }
        frame.model = m
    }

    var hdrColor: SIMD3<Float> { color * ((scene?.frame.hdr ?? false) ? brightness : 1) }
    var hdrBackground: SIMD3<Float> { backgroundColor * ((scene?.frame.hdr ?? false) ? backgroundBrightness : 1) }

    /// Direct draw, vtF0 0x140258050. `frame.model` holds the anchored layer world.
    func drawDirect(_ ctx: RenderContext, _ frame: FrameState, _ scene: SceneRenderer) {
        guard let b = block else { return }
        let base = frame.model
        if opaqueBackground {
            let pad = effectivePadding
            frame.model = base * Mat.translate(SIMD3(-0.5 * b.width - pad.x, -0.5 * b.height - pad.y, 0))
            draw(backgroundMaterial, backgroundQuad!.mesh, ctx, frame, scene, blend: blend, color: hdrBackground, alpha: alpha)
        }
        // Text block centred on the layer: minX → -w/2, maxY → +h/2.
        frame.model = base * Mat.translate(SIMD3(-0.5 * b.width - min(b.minX, 0), 0.5 * b.height - b.maxY, 0))
        drawGlyphs(ctx, frame, scene, blend: blend)
        frame.model = base
    }

    /// vtE0 0x140257c30: an opaque background clears the composite to the background colour; otherwise the
    /// scene under the layer is copied in with alpha 0 (composelayer_clearalpha) so effects bleed real colours.
    func drawCompositeBackground(_ ctx: RenderContext, _ frame: FrameState, _ scene: SceneRenderer, world: simd_float4x4) {
        if opaqueBackground {
            let c = hdrBackground
            ctx.clear(MTLClearColor(red: Double(c.x), green: Double(c.y), blue: Double(c.z), alpha: Double(alpha)))
        } else if let M = clearAlphaMaterial {
            let saved = frame.model
            frame.model = world
            draw(M, clearAlphaQuad!.mesh, ctx, frame, scene, blend: BlendState(mode: .normal, alphaWrite: true), color: SIMD3(1, 1, 1), alpha: 1,
                 textures: [0: BoundTexture(target: scene.fullFrameBuffer)])
            frame.model = saved
        }
    }

    /// vtE8 0x140257d70: glyphs into the composite in pixel space, offset by the padding.
    func drawIntoComposite(_ ctx: RenderContext, _ frame: FrameState, _ scene: SceneRenderer) {
        guard let b = block else { return }
        let pad = effectivePadding
        frame.model = Mat.translate(SIMD3(pad.x - min(b.minX, 0), pad.y - b.minY, 0))
        drawGlyphs(ctx, frame, scene, blend: BlendState(mode: .translucent, alphaWrite: true))
    }

    /// The effect values `Text_EffectParams` 0x140258b80 hands the layout: outline thickness max(t, 1) when `outline`,
    /// blur max(b, 0.01) when `blur`, shadow size max(s, 0.01) and the offset only when `dropshadow`.
    var effectParams: (outline: Float, blur: Float, shadow: Float, offset: SIMD2<Float>) {
        (outline ? max(outlineThickness, 1) : 0, blur ? max(blurSize, 0.01) : 0,
         dropShadow ? max(dropShadowSize, 0.01) : 0, dropShadow ? dropShadowOffset : .zero)
    }

    /// `Font_MsdfCombos` 0x1401b3b60: combos and g_RenderVar0…3 for the MSDF font shader. Range 24 (C+0xa8),
    /// k = 32/pointsize·0.24 converts layout pixels to atlas pixels; outline ≤ 5.1, blur/shadow/offset ≤ 6, and when
    /// blur + outline > 5.1 the outline becomes max(5.1 − blur, 0).
    func msdfState() -> (combos: [String: Int], vars: [String: UniformValue]) {
        let e = effectParams
        var combos: [String: Int] = [:]
        if e.outline >= 1 { combos["OUTLINE_ENABLED"] = 1 }
        if e.blur > 0 { combos["BLUR_ENABLED"] = 1 }
        if e.shadow > 0 || e.offset.x * e.offset.x + e.offset.y * e.offset.y > 1.1920929e-7 { combos["DROP_SHADOW_ENABLED"] = 1 }
        let k = 32 / min(max(pointSize, 1), 256) * 0.24   // block+0xa8 = clamped point size
        var ol = min(5.1, k * e.outline)
        let bl = min(6, k * e.blur), sh = min(6, k * e.shadow)
        let ox = min(6, k * e.offset.x), oy = min(6, k * e.offset.y)
        if bl + ol > 5.1 { ol = max(5.1 - bl, 0) }
        let vars: [String: UniformValue] = [
            "g_RenderVar0": .floats([24, ol, bl, sh]),
            "g_RenderVar1": .floats([outlineColor.x, outlineColor.y, outlineColor.z, ox]),
            "g_RenderVar2": .floats([dropShadowColor.x, dropShadowColor.y, dropShadowColor.z, oy]),
            "g_RenderVar3": .floats([dropShadowOpacity, 0, 0, 0]),
        ]
        return (combos, vars)
    }

    /// `Font_DrawBlock` 0x1401b3430: the outline-glyph mesh with basefont[_msdf][_depth], the colour mesh with
    /// basefontrgba[_depth] (colour glyphs stay on the raster atlas here, see FontAtlas).
    func drawGlyphs(_ ctx: RenderContext, _ frame: FrameState, _ scene: SceneRenderer, blend: BlendState) {
        guard var b = block else { return }
        let atlas = library.atlas
        let grayPage = b.msdf ? atlas.msdfPage : atlas.gray
        if b.grayGeneration != grayPage.generation || b.colorGeneration != atlas.color.generation {
            rebuild()
            guard let nb = block else { return }
            b = nb
        }
        if !b.grayIndices.isEmpty, let tex = atlas.bound(grayPage) {
            let mesh = Mesh(layout: .quad, vertices: b.grayVertices, indices: b.grayIndices, vertexCount: b.grayVertices.count / 5)
            if b.msdf {
                let st = msdfState()
                draw(fontMaterial(color: false, msdf: true, combos: st.combos), mesh, ctx, frame, scene, blend: blend, color: hdrColor,
                     alpha: alpha, textures: [0: tex], extra: st.vars)
            } else {
                draw(fontMaterial(color: false, msdf: false, combos: [:]), mesh, ctx, frame, scene, blend: blend, color: hdrColor,
                     alpha: alpha, textures: [0: tex])
            }
        }
        if !b.colorIndices.isEmpty, let tex = atlas.bound(atlas.color) {
            let mesh = Mesh(layout: .quad, vertices: b.colorVertices, indices: b.colorIndices, vertexCount: b.colorVertices.count / 5)
            draw(fontMaterial(color: true, msdf: false, combos: [:]), mesh, ctx, frame, scene, blend: blend, color: hdrColor,
                 alpha: alpha, textures: [0: tex])
        }
    }

    /// `RunPass` 0x1401ebf60 (same as ImageLayer.runPass, with the text blending: translucent, or additive for 31).
    func runPass(_ effect: Effect, _ p: Int, src: Int, final: Bool, _ ctx: RenderContext, _ frame: FrameState, _ scene: SceneRenderer) {
        let P = effect.passes[p]
        let T = P.target >= 0 ? effect.fbos[P.target].target : nil
        switch P.command {
        case .swap:
            guard P.source >= 0, P.target >= 0 else { return }
            for q in effect.passes.indices where effect.passes[q].command != .swap {
                func sw(_ x: Int) -> Int { x == P.source ? P.target : x == P.target ? P.source : x }
                effect.passes[q].source = sw(effect.passes[q].source)
                effect.passes[q].target = sw(effect.passes[q].target)
                effect.passes[q].binds = effect.passes[q].binds.map { (sw($0.fbo), $0.index) }
            }
        case .copy:
            let S = P.source >= 0 ? effect.fbos[P.source].target : nil
            if let S { ctx.bind(S.texture) }
            if let T { ctx.copyCurrent(into: T.texture) }
            if S != nil { ctx.unbind() }
        case .draw:
            guard let M = P.material else { return }
            if let T { ctx.bind(T.texture) }
            var overrides: [Int: BoundTexture] = [:]
            if P.binds.isEmpty {
                overrides[0] = BoundTexture(target: targets[src])
            } else {
                for bnd in P.binds {
                    if bnd.fbo >= 0, let rt = effect.fbos[bnd.fbo].target { overrides[bnd.index] = BoundTexture(target: rt) }
                    else if bnd.fbo < 0 { overrides[bnd.index] = BoundTexture(target: targets[src]) }
                }
            }
            let last = final && effect.lastNormalPass == p
            // Text vt+0x108 0x140258580: the last pass is translucent with depth test = the layout depth flag.
            if last { M.depthTest = depthFlag }
            frame.setEffectMatrices(world: layerWorldSaved, lmvp: layerMVP, size: size, final: final)
            if last {
                draw(M, objectQuad!.mesh, ctx, frame, scene, blend: blend, color: hdrColor, alpha: alpha, textures: overrides)
            } else {
                draw(M, effectQuad!.mesh, ctx, frame, scene, blend: BlendState(mode: M.blendMode, alphaWrite: true),
                     color: hdrColor, alpha: alpha, textures: overrides)
            }
            if T != nil { ctx.unbind() }
        }
    }

    func draw(_ m: Material, _ mesh: Mesh, _ ctx: RenderContext, _ frame: FrameState, _ scene: SceneRenderer,
              blend: BlendState, color: SIMD3<Float>, alpha: Float, textures: [Int: BoundTexture] = [:],
              extra: [String: UniformValue] = [:]) {
        var tex = textures
        for (slot, name) in m.textureNames where tex[slot] == nil && name.hasPrefix("_rt_") {
            if let rt = scene.namedTarget(name) { tex[slot] = BoundTexture(target: rt) }
        }
        var u = frame.builtins(color: color, alpha: alpha, target: ctx.current)
        u.merge(extra) { _, b in b }
        ctx.draw(material: m, mesh: mesh, uniforms: u, textures: tex, blend: blend)
    }
}
