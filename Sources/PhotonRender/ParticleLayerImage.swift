import Foundation
import Metal
import PhotonCore
import simd

// layerimage emitter sampling (#43, gaps6/particles/layerimage_ref.py) and the particle object's `dependencies`
// (docs/re/05 §S5.4).

/// One downsampled pixel kept by the capture: RGB and int16 coordinates centred on the texture (y down).
struct PLayerPoint {
    var r: UInt8, g: UInt8, b: UInt8
    var x: Int16, y: Int16
    /// Byte 3 of the engine's u64 point: 0xff, or the puppet bone the point follows (0x1401d6d30).
    var bone: UInt8 = 0xff
}

/// The "emitter image" sampling record (0xd8 bytes, shared per (layer id, mask path)): state 0 capture pending,
/// 1 readback pending, 2 ready. `LayerImage_GetPoints` 0x1401d3ae0 drives it; here the capture is encoded by the
/// particle object's render and read back once the GPU has finished (a frame or so later).
final class PLayerImage {
    weak var layer: ImageLayer?
    let mask: GPUTexture?
    private(set) var points: [PLayerPoint] = []
    /// Record +0x68: inverse bind-pose world per puppet bone, built with the bone assignment at capture time.
    private(set) var invBind: [simd_float4x4] = []
    /// The previous frame's puppet bones in layer space (puppet +0x348 = bone world × layer world of the last frame),
    /// snapshotted by the emitter each frame; nil until a frame has passed (the engine then uses identity).
    var prevLayerSpaceBones: [simd_float4x4]?
    var snapshotFrame = -1
    private var state = 0
    private var requested = false
    private var readback: (buffer: MTLBuffer, w4: Int, h4: Int, texW: Int, texH: Int, scale: Float)?
    /// The command buffer carrying the capture: one frame later its readback is waited on, like the engine's staging
    /// Map (one-frame latch +0x48/+0x4c), so the points never depend on GPU timing.
    private var captureBuffer: MTLCommandBuffer?

    init(layer: ImageLayer, mask: GPUTexture?) {
        self.layer = layer
        self.mask = mask
    }

    /// Once per frame (before the system simulates): the previous frame's puppet layer-space bones (puppet +0x348).
    private var lastLayerSpace: [simd_float4x4]?
    func frameTick() {
        guard let layer, let pup = layer.puppet else { return }
        prevLayerSpaceBones = lastLayerSpace
        let W = layer.world
        lastLayerSpace = pup.boneWorld.map { W * $0 }
    }

    /// `0x1401d42b0`: capture again.
    func invalidate() { state = 0; requested = false }

    /// True once points are available. State 0 asks the next render to capture.
    func getPoints() -> Bool {
        switch state {
        case 0:
            requested = true
            return false
        case 1:
            guard let cb = captureBuffer, cb.status.rawValue >= MTLCommandBufferStatus.committed.rawValue,
                  let rb = readback else { return false }
            cb.waitUntilCompleted()
            captureBuffer = nil
            extract(rb)
            readback = nil
            state = 2
            return true
        default:
            return true
        }
    }

    /// state 0 → 1 (0x1401d3caa..0x1401d3d7e): fit the composite to 3840×2160 keeping aspect, quarter it (min 2) and
    /// draw it with downsample_quarter (WRITEALPHA, OPACITYMASK when there is a mask) into a CPU-readable copy.
    func encodeCapture(_ ctx: RenderContext) {
        guard state == 0, requested, let layer, layer.needComposite, let rt = layer.targets.first else { return }
        let src = rt.texture
        let (w4, h4, scale) = Self.captureSize(src.width, src.height)
        let dev = ctx.device
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm, width: w4, height: h4, mipmapped: false)
        d.usage = [.renderTarget]
        d.storageMode = .private
        guard let dst = dev.makeTexture(descriptor: d),
              let buf = dev.makeBuffer(length: w4 * h4 * 4, options: .storageModeShared),
              let pipe = Self.pipeline(dev) else { return }
        ctx.endEncoder()
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = dst
        pass.colorAttachments[0].loadAction = .dontCare
        pass.colorAttachments[0].storeAction = .store
        guard let e = ctx.commandBuffer.makeRenderCommandEncoder(descriptor: pass) else { return }
        e.setRenderPipelineState(pipe.state)
        e.setFragmentTexture(src, index: 0)
        e.setFragmentTexture(mask?.texture ?? src, index: 1)
        e.setFragmentSamplerState(pipe.sampler, index: 0)
        var k = SIMD4<Float>(1 / Float(src.width), 1 / Float(src.height), mask != nil ? 1 : 0, 0)
        e.setFragmentBytes(&k, length: 16, index: 0)
        e.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        e.endEncoding()
        guard let blit = ctx.commandBuffer.makeBlitCommandEncoder() else { return }
        blit.copy(from: dst, sourceSlice: 0, sourceLevel: 0, sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
                  sourceSize: MTLSize(width: w4, height: h4, depth: 1), to: buf, destinationOffset: 0,
                  destinationBytesPerRow: w4 * 4, destinationBytesPerImage: w4 * h4 * 4)
        blit.endEncoding()
        captureBuffer = ctx.commandBuffer
        readback = (buf, w4, h4, src.width, src.height, scale)
        state = 1
    }

    /// layerimage_ref.capture_size.
    static func captureSize(_ w: Int, _ h: Int) -> (Int, Int, Float) {
        var W = w, H = h
        if W > 0xf00 || H > 0x870 {
            let a = Float(W) / Float(H)
            if a >= Float(1.7777778) { W = 0xf00; H = Int(Float(3840) / a) } else { H = 0x870; W = Int(a * Float(2160)) }
        }
        let w4 = max(W / 4, 2), h4 = max(H / 4, 2)
        return (w4, h4, Float(w) / Float(w4))
    }

    /// 0x1401d40de..0x1401d41dc: column-major scan, alpha ≥ 127, x = trunc(col·scale − (w >> 1) + scale/2).
    private func extract(_ rb: (buffer: MTLBuffer, w4: Int, h4: Int, texW: Int, texH: Int, scale: Float)) {
        let px = rb.buffer.contents().assumingMemoryBound(to: UInt8.self)
        let half = rb.scale * 0.5, hw = Float(rb.texW >> 1), hh = Float(rb.texH >> 1)
        var out: [PLayerPoint] = []
        for col in 0..<rb.w4 {
            for row in 0..<rb.h4 {
                let o = (row * rb.w4 + col) * 4
                guard px[o + 3] >= 0x7f else { continue }
                let x = ((Float(col) * rb.scale) - hw) + half, y = ((Float(row) * rb.scale) - hh) + half
                out.append(PLayerPoint(r: px[o], g: px[o + 1], b: px[o + 2], x: Int16(truncatingIfNeeded: Int(x)),
                                       y: Int16(truncatingIfNeeded: Int(y))))
            }
        }
        // Debug (PHOTON_LISTRIDE=n): keep every n-th point so the emulator replay of 0x1401d6d30 stays tractable.
        if let k = ProcessInfo.processInfo.environment["PHOTON_LISTRIDE"].flatMap(Int.init), k > 1 {
            out = stride(from: 0, to: out.count, by: k).map { out[$0] }
        }
        points = out
        if let layer, layer.puppet != nil, let mdl = layer.puppetFile { assignBones(mdl) }
    }

    /// `0x1401d6d30` (puppet layers, run when the readback completes): bind world per bone (the MDLS override matrix when
    /// present, else the local bind, composed with the parent's world), record +0x68 = inverse(bind world); then each hit
    /// box b (bone b) is the rectangle (±hx, ±hy) through box·bindWorld[b], tested in pixel space (x, −y) with
    /// u = (y − C1.y)·e1.y + (x − C1.x)·e1.x ∈ [0, |e1|²], v likewise on the C2→C3 edge. A point inside takes the bone
    /// (inside two rectangles: "conflict"); a point inside none keeps the rectangle it violates least; conflict points
    /// finally copy the bone of the nearest non-conflict point (squared distance in raw point coordinates).
    private func assignBones(_ mdl: MdlFile) {
        let nb = mdl.bones.count
        guard nb > 0 else { return }
        var world: [simd_float4x4] = []
        for (i, b) in mdl.bones.enumerated() {
            let L = Puppet.matrix(rowMajorRowVector: i < mdl.bindOverrideBones.count ? mdl.bindOverrideBones[i] : b.localBind)
            world.append(b.parent >= 0 && b.parent < world.count ? world[b.parent] * L : L)
        }
        invBind = world.map { $0.inverse }
        let n = points.count
        var assigned = [Bool](repeating: false, count: n), conflict = assigned
        var nearest = [Float](repeating: 0, count: n)
        for (bi, box) in mdl.hitBoxes.enumerated() where bi < nb {
            // Rows of box · world (row-vector): (z·W2 + y·W1) + x·W0, row 3 adds W3.
            let B = box.matrix, W = world[bi]
            let w0 = W.columns.0, w1 = W.columns.1, w2 = W.columns.2, w3 = W.columns.3
            func row(_ k: Int) -> SIMD2<Float> {
                let x = B[4 * k], y = B[4 * k + 1], z = B[4 * k + 2]
                return SIMD2((z * w2.x + y * w1.x) + x * w0.x, (z * w2.y + y * w1.y) + x * w0.y)
            }
            let r0 = row(0), r1 = row(1), r2 = row(2)
            let r3 = SIMD2(B[12] * w0.x + (B[13] * w1.x + (B[14] * w2.x + w3.x)),
                           B[12] * w0.y + (B[13] * w1.y + (B[14] * w2.y + w3.y)))
            let a = box.halfExtents.x, bb = box.halfExtents.y
            let t = SIMD2(r2.x * 0 + r3.x, r2.y * 0 + r3.y) // the corner's z = 0 row, then row 3
            let c1 = SIMD2((a * r0.x + bb * r1.x) + t.x, (a * r0.y + bb * r1.y) + t.y)
            let c2 = SIMD2(((-a) * r0.x + bb * r1.x) + t.x, ((-a) * r0.y + bb * r1.y) + t.y)
            let c3 = SIMD2(((-a) * r0.x + (-bb) * r1.x) + t.x, ((-a) * r0.y + (-bb) * r1.y) + t.y)
            let e1 = c2 - c1, e2 = c3 - c2
            let l1 = e1.y * e1.y + e1.x * e1.x, l2 = e2.y * e2.y + e2.x * e2.x
            for k in 0..<n {
                let px = Float(points[k].x), py = Float(-Int32(points[k].y))
                let u = (py - c1.y) * e1.y + (px - c1.x) * e1.x
                let v = (py - c2.y) * e2.y + (px - c2.x) * e2.x
                if u >= 0 && l1 >= u && v >= 0 && l2 >= v {
                    if points[k].bone != 0xff && assigned[k] { conflict[k] = true }
                    points[k].bone = UInt8(truncatingIfNeeded: bi)
                    assigned[k] = true
                } else if !assigned[k] {
                    var d: Float = 0 > u ? -u : 0
                    if u > l1, u - l1 > d { d = u - l1 }
                    if 0 > v, -v > d { d = -v }
                    if v > l2, v - l2 > d { d = v - l2 }
                    if nearest[k] == 0 || nearest[k] > d { nearest[k] = d; points[k].bone = UInt8(truncatingIfNeeded: bi) }
                }
            }
        }
        defer {
            if PDump.want("bones") {
                PDump.write(["kind": "bones", "pts": points.map { [Int($0.x), Int($0.y), Int($0.bone)] },
                             "invbind": invBind.map { PDump.mat($0) }])
            }
        }
        for s in 0..<n where conflict[s] {
            var best = Float.greatestFiniteMagnitude, bone: UInt8 = 0xff
            let sx = Float(points[s].x), sy = Float(points[s].y)
            for r in 0..<n where !conflict[r] {
                let dy = Float(points[r].y) - sy, dx = Float(points[r].x) - sx
                let d2 = dy * dy + dx * dx
                if best > d2 { best = d2; bone = points[r].bone }
            }
            points[s].bone = bone
        }
    }

    private static var pipelines: [ObjectIdentifier: (state: MTLRenderPipelineState, sampler: MTLSamplerState)] = [:]
    private static let pipeLock = NSLock()
    /// downsample_quarter.frag/.vert: four bilinear taps at ±2 texels, ×0.25; OPACITYMASK multiplies alpha by mask.r.
    private static func pipeline(_ dev: MTLDevice) -> (state: MTLRenderPipelineState, sampler: MTLSamplerState)? {
        pipeLock.withLock {
            if let p = pipelines[ObjectIdentifier(dev)] { return p }
            guard let lib = try? dev.makeLibrary(source: """
            #include <metal_stdlib>
            using namespace metal;
            struct V { float4 p [[position]]; float2 uv; };
            vertex V dsV(uint i [[vertex_id]]) {
                float2 uv = float2((i << 1) & 2, i & 2);
                V o; o.p = float4(uv * float2(2, -2) + float2(-1, 1), 0, 1); o.uv = uv; return o;
            }
            fragment float4 dsF(V in [[stage_in]], texture2d<float> t [[texture(0)]], texture2d<float> m [[texture(1)]],
                                sampler s [[sampler(0)]], constant float4 &k [[buffer(0)]]) {
                float2 tx = k.xy;
                float4 a = t.sample(s, in.uv - tx * 2) + t.sample(s, in.uv + tx * 2)
                         + t.sample(s, in.uv + float2(-tx.x, tx.y) * 2) + t.sample(s, in.uv + float2(tx.x, -tx.y) * 2);
                a *= 0.25;
                if (k.z > 0) a.a *= m.sample(s, in.uv).r;
                return a;
            }
            """, options: nil) else { return nil }
            let d = MTLRenderPipelineDescriptor()
            d.vertexFunction = lib.makeFunction(name: "dsV")
            d.fragmentFunction = lib.makeFunction(name: "dsF")
            d.colorAttachments[0].pixelFormat = .rgba8Unorm
            guard let st = try? dev.makeRenderPipelineState(descriptor: d) else { return nil }
            let sd = MTLSamplerDescriptor()
            sd.minFilter = .linear; sd.magFilter = .linear
            sd.sAddressMode = .clampToEdge; sd.tAddressMode = .clampToEdge
            guard let smp = dev.makeSamplerState(descriptor: sd) else { return nil }
            pipelines[ObjectIdentifier(dev)] = (st, smp)
            return (st, smp)
        }
    }
}

extension ParticleInstance {
    /// `0x14022cfa0(inst, obj+0x940)` (docs/re/05 §S5.4): the object's `dependencies` entries `{id, type, index, mask}`
    /// link the k-th layerimage emitter (`emitterimage`) or the k-th collisionmodel operator (`collisionmodel`) of
    /// this instance to the scene object `id`. Called for the system and every child created later.
    func linkDependencies() {
        guard let deps = host.json["dependencies"] as? [Any], let scene = host.scene else { return }
        var imageEmitters: [Int] = [], modelOps: [Int] = []
        for (k, e) in emitters.enumerated() where e.def.kind == .layerImage { imageEmitters.append(k) }
        for (k, op) in def.operators.enumerated() { if case .collisionModel = op { modelOps.append(k) } }
        guard !imageEmitters.isEmpty || !modelOps.isEmpty else { return }
        for d in deps {
            guard let o = d as? [String: Any], let id = (o["id"] as? NSNumber)?.intValue else { continue }
            let index = (o["index"] as? NSNumber)?.intValue ?? 0
            guard let obj = scene.objects.first(where: { $0.id == id }) else { continue }
            switch o["type"] as? String {
            case "emitterimage":
                guard imageEmitters.indices.contains(index), let layer = obj as? ImageLayer else { continue }
                let mask = (o["mask"] as? String) ?? ""
                emitters[imageEmitters[index]].image = host.layerImage(layer, mask: mask)
            case "collisionmodel":
                guard modelOps.indices.contains(index) else { continue }
                collisionModels[modelOps[index]] = obj
            default: break
            }
        }
    }
}
