import Foundation
import PhotonCore
import PhotonRender

/// `photon-tool dump-mdl <file.mdl>`: prints what `MdlFile` parsed, as JSON in the same shape as the emulator replay of
/// `Mdl_Load` 0x140261880 (docs/re/tools/mdl_emu_load.py), so the two can be diffed field by field.
func dumpMdl(_ args: [String]) {
    guard let path = args.first, let data = FileManager.default.contents(atPath: path) else {
        print("usage: photon-tool dump-mdl <file.mdl>"); return
    }
    do {
        let m = try MdlFile(data: data)
        print(String(data: try JSONSerialization.data(withJSONObject: mdlSummary(m), options: [.sortedKeys]), encoding: .utf8)!)
    } catch { print("{\"error\": \"\(error)\"}") }
}

func mdlSummary(_ m: MdlFile) -> [String: Any] {
    func f(_ v: Float) -> Any { v.isFinite ? Double(v) : String(describing: v) }
    func fl(_ a: [Float]) -> [Any] { a.map(f) }
    func v3(_ v: SIMD3<Float>) -> [Any] { [f(v.x), f(v.y), f(v.z)] }
    var out: [String: Any] = ["version": m.version]
    out["meshes"] = m.meshes.map { me -> [String: Any] in
        [
            "flags": me.flags, "vflags": me.vertexFlags, "stride": me.stride, "materials": me.materials,
            "blendRows": me.blendRowCount, "bmin": v3(me.boundsMin), "bmax": v3(me.boundsMax),
            "vbytes": me.vertices.count, "indices": me.indices.count, "c1bytes": me.positionC1?.count ?? 0,
            "sections": me.sections.map { [$0.slot, Int($0.orderOffset), $0.first, $0.count] },
            "clips": me.clipGroups.map { ["id": $0.id, "mask": $0.maskTexture, "flags": $0.flags, "a": $0.a, "b": $0.b,
                                          "parent": $0.parent, "blend": $0.additive ? 2 : 1] as [String: Any] },
            "morphScale": f(me.morphScale), "morphNV": me.morphVertexCount,
            "targets": me.morphTargets.map { t -> [String: Any] in
                ["id": t.id, "name": t.name, "pos": t.positions.count * 2, "nrm": t.normals.count * 2, "ext": t.extra.count * 2,
                 "alpha": t.alpha.count * 2, "mflags": t.modifierFlags, "mbone": t.modifierBone,
                 "mrange": [f(t.modifierRange.x), f(t.modifierRange.y)]]
            },
        ]
    }
    out["bones"] = m.bones.enumerated().map { i, b -> [String: Any] in
        ["name": b.name, "flags": b.flags, "parent": b.parent, "matrix": fl(b.localBind), "phys": b.physicsJSON,
         "chain": i < m.boneChain.count ? m.boneChain[i] : -1]
    }
    out["handles"] = m.handles.map { h -> [String: Any] in
        ["name": h.name, "bone": h.bone, "type": h.type, "matrix": fl(h.matrix), "constraints": h.constraints.count]
    }
    out["constraintCount"] = m.constraintCount
    out["drawOrderBase"] = m.drawOrderBase.map { Int($0) }
    out["hitOrder"] = m.hitOrder
    out["hitBoxes"] = m.hitBoxes.count
    out["overrideBones"] = m.bindOverrideBones.count
    out["mdle"] = m.editorPose.count / 64
    out["attachments"] = m.attachments.map { ["bone": $0.bone, "name": $0.name, "matrix": fl($0.matrix)] as [String: Any] }
    out["anims"] = m.animations.map { a -> [String: Any] in
        var d: [String: Any] = [
            "id": a.id, "name": a.name, "mode": a.modeName, "fps": f(a.fps), "frames": a.frames, "flags": a.flags,
            "trackFlags": a.trackFlags, "keyed": a.tracks.map { $0.samples.isEmpty ? 0 : 1 },
            "handleTracks": a.handleTracks.map { $0.unkeyed ? 1 : 0 }, "constraintTracks": a.constraintTracks.map { $0.unkeyed ? 1 : 0 },
            "blend": a.blendTracks.count, "alpha": a.alphaTracks.count, "order": a.orderTracks.count,
            "morph": a.morphTracks.map { t -> Any in t.map { $0.map { [$0.index, $0.samples.count] } } ?? NSNull() },
            "bmin": v3(a.boundsMin), "bmax": v3(a.boundsMax),
            "events": a.events.map { [f($0.time), $0.json] },
        ]
        if let r = a.reference { d["ref"] = [r.index, r.frameA, r.frameB, Int(r.rootFrame), r.bone] }
        return d
    }
    return out
}

/// `photon-tool rootmotion-replay <file.mdl> <cases.json>`: prints `RootMotionReplay.run` results as JSON.
func rootMotionReplay(_ args: [String]) {
    guard args.count >= 2, let d = FileManager.default.contents(atPath: args[0]), let m = try? MdlFile(data: d),
          let cj = FileManager.default.contents(atPath: args[1]),
          let cases = (try? JSONSerialization.jsonObject(with: cj)) as? [[String: Any]] else {
        print("usage: photon-tool rootmotion-replay <file.mdl> <cases.json>"); return
    }
    let out = RootMotionReplay.run(mdl: m, cases: cases)
    print(String(data: try! JSONSerialization.data(withJSONObject: out), encoding: .utf8)!)
}
