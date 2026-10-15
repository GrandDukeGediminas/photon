import Foundation
import PhotonCore

/// Keyframe animations on effect pass constants (`constantshadervalues` entries with an `animation` block).
///
/// In the engine every bindable value goes through the same binding manager: `Value_LoadDynamic` 0x1401a4db0 creates
/// the animation record for any property descriptor, constants included, and `Bindings_Tick` 0x140171440 advances
/// and samples it each frame (0x1401723b1–0x1401726ad) before the scripts' update. SceneScript reaches these through
/// `getAnimation()` on the effect wrapper (`thisObject` of a constant script; host +0x78 = 0x14018db00 matches the
/// animation's `options.name` or the bound property name), which the corpus uses for album-art fades driven by the
/// media hooks.
final class ScriptConstantAnimations {
    struct Entry {
        let effect: Effect
        let pass: Int
        let key: String
        let animation: PropertyAnimation
    }
    private(set) var entries: [Entry] = []

    init(objects: [SceneObject]) {
        for o in objects { add(o) }
    }

    func add(_ o: SceneObject) {
        let effects: [Effect]
        if let i = o as? ImageLayer { effects = i.effects } else if let t = o as? TextObject { effects = t.effects } else { return }
        for (ei, e) in ((o.json["effects"] as? [Any]) ?? []).enumerated() {
            guard let e = e as? [String: Any], let effect = effects.first(where: { $0.jsonIndex == ei }) else { continue }
            for (pi, p) in ((e["passes"] as? [Any]) ?? []).enumerated() {
                guard let csv = (p as? [String: Any])?["constantshadervalues"] as? [String: Any] else { continue }
                for k in csv.keys.sorted() {
                    if let a = PropertyAnimation(json: csv[k]) { entries.append(Entry(effect: effect, pass: pi, key: k, animation: a)) }
                }
            }
        }
    }

    /// Advance and write the sampled channels into the pass material's constant (only when the channel count
    /// matches the constant's component count, as for object properties).
    func update(_ dt: Float) {
        for e in entries {
            if e.animation.timelineParent == nil { e.animation.advance(dt) }
            for p in e.effect.passes where p.jsonIndex == e.pass {
                guard let m = p.material else { continue }
                let comps = m.program?.info.values.values.first(where: { $0.materialKey == e.key })?.components ?? e.animation.channelCount
                guard let v = e.animation.value(arity: comps) else { continue }
                m.constants[e.key] = v.map { NSNumber(value: $0) }
            }
        }
    }

    /// `getAnimation(name)` on an effect: the first constant animation of that effect whose `options.name` or
    /// constant name is `name`.
    func find(effect: Effect, name: String) -> PropertyAnimation? {
        entries.first { $0.effect === effect && ($0.animation.name == name || $0.key == name) }?.animation
    }
}
