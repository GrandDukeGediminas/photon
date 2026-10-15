import Foundation

/// Animation events for SceneScript `animationEvent` (hook 6), shared by property animations and puppet/model
/// animation layers. Both run `Timeline_Advance` 0x1401a9f60, which takes an optional event list (timeline +0x18,
/// 0x28-byte records `{f32 time; std::string json}`) and pushes every event the step crossed (0x1401aa1c0):
/// - after `t = time ± dt`: forward (d > 0) fires `old <= e < t`, otherwise `t < e <= old`;
/// - loop mode only: a negative t wraps to `fmod(t + dur, dur)` and fires `t < e <= dur`; then t >= dur wraps to
///   `t2 = fmod(t, dur)` and, if `t2 < dur`, fires `0 <= e < t2`;
/// - single and mirror modes fire nothing beyond the first test.
public enum ScriptAnimationEvents {
    public enum Mode { case loop, mirror, single }

    public static func crossed(_ events: [(time: Float, json: String)], old: Float, delta d: Float, duration dur: Float,
                               mode: Mode) -> [String] {
        guard !events.isEmpty else { return [] }
        var out: [String] = []
        let t = old + d
        if d > 0 {
            for e in events where e.time >= old && e.time < t { out.append(e.json) }
        } else {
            for e in events where e.time > t && e.time <= old { out.append(e.json) }
        }
        guard mode == .loop else { return out }
        var time = t
        if time < 0 {
            time = fmodf(time + dur, dur)
            if time >= 0 { for e in events where e.time > time && e.time <= dur { out.append(e.json) } }
        }
        if time >= dur {
            let t2 = fmodf(time, dur)
            if t2 < dur { for e in events where e.time >= 0 && e.time < t2 { out.append(e.json) } }
        }
        return out
    }

    /// `options.events` of a property animation (`Value_LoadDynamic` 0x1401a57a3 → 0x1401a9410): an array of
    /// objects with a string `name` and a numeric `frame`; time = frame · frame duration, payload = the element as
    /// JSON (jsoncpp writes object keys sorted).
    public static func parse(_ v: Any?, frameDuration: Float) -> [(time: Float, json: String)] {
        guard let list = v as? [Any] else { return [] }
        var out: [(Float, String)] = []
        for item in list {
            guard let o = item as? [String: Any], o["name"] is String,
                  let f = o["frame"] as? NSNumber, CFGetTypeID(f) != CFBooleanGetTypeID() else { continue }
            guard let d = try? JSONSerialization.data(withJSONObject: o, options: [.sortedKeys]) else { continue }
            out.append((f.floatValue * frameDuration, String(decoding: d, as: UTF8.self)))
        }
        return out
    }
}
