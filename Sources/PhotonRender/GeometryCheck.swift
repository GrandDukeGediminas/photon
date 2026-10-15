import Foundation
import Metal
import PhotonCore
import simd

/// `photon-tool gs-check <pdump.jsonl> <out.jsonl>`: replays PHOTON_PDUMP `gsin` records (ParticleRender) through the
/// emulated geometry stage built with a capture buffer, rasterization off, and writes every triangle-list vertex
/// (valid flag, emission index, clip position, TEXCOORD members) so an independent CPU evaluation of the engine's HLSL can be
/// compared with it (scratchpad r7/gs/tools/gs_ref.py).
public enum GeometryCheck {
    public static func run(dump: URL, out: URL, fs: AssetFileSystem, device: MTLDevice) throws {
        let builder = ShaderBuilder(sources: ShaderSourceLoader(fs: fs))
        let compiler = ShaderCompiler()
        let queue = device.makeCommandQueue()!
        guard let text = try? String(contentsOf: dump, encoding: .utf8) else { throw ShaderCompiler.Error.tool("gs-check", "no dump") }
        FileManager.default.createFile(atPath: out.path, contents: nil)
        let handle = try FileHandle(forWritingTo: out)
        var done = 0
        for line in text.split(separator: "\n") {
            guard let rec = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any], rec["kind"] as? String == "gsin",
                  let shader = rec["shader"] as? String, let combos = rec["combos"] as? [String: Int],
                  let stride = rec["stride"] as? Int, let count = rec["count"] as? Int, let attrs = rec["attributes"] as? [[Int]],
                  let vbits = rec["vertices"] as? [UInt32], let uni = rec["uniforms"] as? [String: [String: [UInt32]]] else { continue }
            guard let (program, cap) = try builder.buildCapture(.init(shader: shader, combos: combos)) else { continue }
            let stage = try compiler.compile(hlsl: cap.hlsl, stage: .vertex)
            let lib = try device.makeLibrary(source: stage.msl, options: nil)
            guard let fn = lib.makeFunction(name: stage.entryPoint) else { continue }
            let layout = VertexLayout(stride: stride, attributes: attrs.map {
                VertexLayout.Attribute(id: $0[0], format: MTLVertexFormat(rawValue: UInt($0[1]))!, offset: $0[2])
            }, stepPerInstance: true)
            let d = MTLRenderPipelineDescriptor()
            d.vertexFunction = fn
            d.vertexDescriptor = layout.descriptor(for: fn)
            d.isRasterizationEnabled = false
            let pso = try device.makeRenderPipelineState(descriptor: d)

            var values: [String: UniformValue] = [:]
            for (k, v) in uni {
                if let f = v["f"] { values[k] = .floats(f.map { Float(bitPattern: $0) }) }
                if let m = v["m"] {
                    let x = m.map { Float(bitPattern: $0) }
                    values[k] = .matrix(simd_float4x4(SIMD4(x[0], x[1], x[2], x[3]), SIMD4(x[4], x[5], x[6], x[7]),
                                                      SIMD4(x[8], x[9], x[10], x[11]), SIMD4(x[12], x[13], x[14], x[15])))
                }
            }
            let members = GeometryEmulation.captureMembers(geometryHLSL: program.geometry!.hlsl)
            let recStride = 4 * (6 + 4 * members.count)
            let listCount = cap.listVertexCount * count
            let capBuf = device.makeBuffer(length: max(listCount * recStride, 16), options: .storageModeShared)!
            let vb = device.makeBuffer(bytes: vbits, length: max(vbits.count * 4, 16), options: .storageModeShared)!

            let pass = MTLRenderPassDescriptor()
            pass.renderTargetWidth = 1; pass.renderTargetHeight = 1; pass.defaultRasterSampleCount = 1
            let cb = queue.makeCommandBuffer()!
            let e = cb.makeRenderCommandEncoder(descriptor: pass)!
            e.setRenderPipelineState(pso)
            for (index, l) in ShaderProgram.layouts(from: stage.reflection) {
                let bytes = RenderContext.pack(l, values)
                e.setVertexBytes(bytes, length: max(bytes.count, 16), index: index)
            }
            e.setVertexBuffer(vb, offset: 0, index: ShaderCompiler.vertexBufferIndex)
            e.setVertexBuffer(capBuf, offset: 0, index: 7)
            e.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: cap.listVertexCount, instanceCount: count)
            e.endEncoding()
            cb.commit()
            cb.waitUntilCompleted()
            let p = capBuf.contents().bindMemory(to: UInt32.self, capacity: listCount * recStride / 4)
            let words = Array(UnsafeBufferPointer(start: p, count: listCount * recStride / 4))
            var o = rec
            o["kind"] = "gsout"
            o["maxvertexcount"] = cap.maxVertexCount
            o["members"] = members.map { [$0.name, $0.type] }
            o["capture"] = words
            let data = try JSONSerialization.data(withJSONObject: o)
            handle.write(data); handle.write("\n".data(using: .utf8)!)
            done += 1
        }
        print("gs-check: \(done) draws captured")
    }
}
