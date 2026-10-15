import Foundation
import JavaScriptCore
import simd

/// `layer.setParent(parent, keepTransform | attachment, keepTransform)` (wrapper 0x1401e00b0 → Obj_SetParent 0x1401de750).
extension SceneScriptEngine {
    /// 0x1401e00b0: argument 0 resolves through host +0x1510 vt+0x18 (wrapper, name or id string, index); `keep` is set
    /// when argument 1 or 2 is a true boolean; an int argument 1 is the attachment index, a string one is looked up on
    /// the new parent (vt+0x70). A null parent always passes −1. A false result throws "Invalid parent configuration.".
    func scriptSetParent(_ o: SceneObject, _ args: [JSValue]) {
        let parent = args.first.flatMap { $0.isNull || $0.isUndefined ? nil : resolveLayer($0) }
        var keep = false
        var attach = -1
        if args.count > 1 {
            let a = args[1]
            if a.isBoolean { keep = a.toBool() }
            else if let p = parent, a.isNumber, let d = a.toNumber()?.doubleValue, d == d.rounded(), abs(d) < 2_147_483_648 { attach = Int(d); _ = p }
            else if let p = parent, a.isString { attach = p.attachmentIndex(a.toString() ?? "") }
        }
        if args.count > 2, args[2].isBoolean, args[2].toBool() { keep = true }
        if !Self.objSetParent(o, parent, keep: keep, attachment: parent == nil ? -1 : attach, objects: scene.objects) {
            context.exception = JSValue(newErrorFromMessage: "Invalid parent configuration.", in: context)
        }
    }

    /// +0x120 bit 2: a passthrough image (`Image_Ctor` 0x1401fb35f).
    private static func passthroughBit(_ o: SceneObject) -> Bool { (o as? ImageLayer)?.passthrough ?? false }

    /// 0x1401ddb50: passthrough depth of a subtree, own bit + the deepest child.
    private static func passthroughDepth(_ o: SceneObject, _ objects: [SceneObject]) -> Int {
        let own = passthroughBit(o) ? 1 : 0
        var d = own
        for c in objects where c.parent === o { d = max(d, passthroughDepth(c, objects) + own) }
        return d
    }

    /// 0x1401dd7d0: the object's matrix without scale: rotation (+0x14c) and origin, the parent's attachment (vt+0x78),
    /// then the parent's own such matrix.
    private static func worldNoScale(_ o: SceneObject) -> simd_float4x4 {
        var m = Mat.translate(o.origin) * Mat.rotation(o.angles)
        if let p = o.parent {
            if let a = p.attachmentTransform(o.attachmentIndex) { m = a * m }
            m = worldNoScale(p) * m
        }
        return m
    }

    /// Obj_SetParent 0x1401de750. Same parent and attachment: nothing to do. The object leaves its old parent first; then
    /// parenting to itself, or a chain with more than three passthrough images (ancestors with +0x120 & 4 counted from the
    /// new parent, plus the passthrough depth of the object's own subtree), fails and leaves the object without a parent.
    /// Without `keep` the parent and attachment are just linked. With `keep` and no attachment the world transform is
    /// preserved: origin = translation of inverse(parent world) · world, angles from inverse(parent R·T) · own R·T
    /// (0x1401dd7d0 chains, scale-free), scale = old scale × |columns of the old scale-1 world| / |columns of the new
    /// scale-1 world|; with `keep` and an attachment, origin and angles become 0 and the scale stays.
    @discardableResult
    static func objSetParent(_ o: SceneObject, _ parent: SceneObject?, keep: Bool, attachment: Int, objects: [SceneObject]) -> Bool {
        if o.parent === parent {
            if parent == nil { return true }
            if o.attachmentIndex == attachment { return true }
        }
        func link(_ p: SceneObject?, _ a: Int) {
            o.parent = p
            o.parentID = p?.id
            o.scriptAttachment = p.map { (ObjectIdentifier($0), a) }
        }
        var chain = 0
        var fail = o === parent
        if !fail {
            var c = parent
            while let p = c { if passthroughBit(p) { chain += 1 }; c = p.parent }
            if passthroughDepth(o, objects) + chain > 3 { fail = true }
        }
        if fail {
            link(nil, -1)
            return false
        }
        guard keep else { link(parent, attachment); return true }

        let wOld = o.world
        let mp = parent?.world ?? matrix_identity_float4x4
        let local = mp.inverse * wOld
        let ap = parent.map(worldNoScale) ?? matrix_identity_float4x4
        let r = ap.inverse * worldNoScale(o)
        let oldScale = o.scale
        o.scale = SIMD3(1, 1, 1)
        let w2 = o.world
        link(parent, attachment)
        guard attachment < 0 else {
            o.origin = .zero
            o.angles = .zero
            o.scale = oldScale
            return true
        }
        o.origin = SIMD3(local.columns.3.x, local.columns.3.y, local.columns.3.z)
        // Euler extraction as getAttachmentAngles (0x1401dec8e–0x1401ded56): elements in glm memory order.
        func e(_ i: Int) -> Float { r[i / 4][i % 4] }
        let z = atan2f(e(1), e(0))
        let y = atan2f(-e(2), (e(6) * e(6) + e(10) * e(10)).squareRoot())
        let sz = sinf(z), cz = cosf(z)
        let x = atan2f(sz * e(8) - cz * e(9), cz * e(5) - sz * e(4))
        o.angles = SIMD3(x, y, z)
        let w3 = o.world
        var s = SIMD3<Float>(1, 1, 1)
        for i in 0..<3 {
            let l3 = simd_length(w3[i])
            if l3 > Float.ulpOfOne { s[i] = 1 / l3 }
            s[i] = oldScale[i] * simd_length(w2[i]) * s[i]
        }
        o.scale = s
        return true
    }
}
