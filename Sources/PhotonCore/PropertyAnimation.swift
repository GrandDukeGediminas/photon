import Foundation

/// A keyframe animation on a bindable scene value. Port of docs/re/tools/anim_eval.py, traced from
/// wallpaper64.exe (docs/re/04 §5.1): Anim_ParseKeys 0x1401a8ce0, Anim_WrapLoop 0x1401a98b0,
/// Timeline_Advance 0x1401a9f60, Channel_Sample 0x1401a9bc0, frame pick in Bindings_Tick 0x140171440.
public final class PropertyAnimation {
    struct Key {
        var frame: Int
        var value: Float
        var step = false
        var back = SIMD2<Float>(0, 0) // (x, y); (0,0) when disabled
        var front = SIMD2<Float>(0, 0)
        var hasBack = false
        var hasFront = false
    }

    final class Channel {
        let keys: [Key]
        private var cache: [Int: Float] = [:]
        init(_ keys: [Key]) { self.keys = keys }
        func at(_ frame: Int) -> Float {
            if let v = cache[frame] { return v }
            let v = PropertyAnimation.sample(keys, frame)
            cache[frame] = v
            return v
        }
    }

    let channels: [Channel]
    public let fps: Float
    public let length: Int
    public let duration: Float
    /// `options.name`, used by SceneScript `getAnimation(name)`.
    public let name: String
    /// SceneScript-writable playback rate (property-animation table, docs/re/08 §3.10).
    public var rate: Float = 1
    /// `options.parent.key` (entry +0x90, read only when `parent` is an object with a string `key`, 0x1401a5269).
    public let parentKey: String
    /// The animation whose timeline drives this one (entry +0xb0, `Binder_Register` 0x1401767b3 / 0x1401769dd): its
    /// time, frame duration, length and rate are used; the channels stay this animation's own (docs/re/04 §5).
    public weak var timelineParent: PropertyAnimation?
    let frameDuration: Float
    let mirror: Bool
    let single: Bool
    public private(set) var time: Float = 0
    private var backwards = false
    private var finished = false
    public var paused: Bool
    /// `options.events` (SceneScript animationEvent, docs/re/08 §7): time in seconds and the event JSON.
    public let events: [(time: Float, json: String)]
    /// Events crossed by `advance` since the last `takeEvents()`.
    public private(set) var firedEvents: [String] = []
    public func takeEvents() -> [String] { defer { firedEvents.removeAll() }; return firedEvents }

    public var channelCount: Int { channels.count }

    public init?(json: Any?) {
        guard let obj = json as? [String: Any], let anim = obj["animation"] as? [String: Any] else { return nil }
        let opts = (anim["options"] as? [String: Any]) ?? [:]
        let fps = (opts["fps"] as? NSNumber)?.floatValue ?? 0
        let length = (opts["length"] as? NSNumber)?.intValue ?? 0
        guard fps > 0 else { return nil }
        let duration = Float(length) / fps
        guard duration > 0 else { return nil }
        self.fps = fps
        self.length = length
        self.duration = duration
        frameDuration = 1 / fps
        name = (opts["name"] as? String) ?? (anim["name"] as? String) ?? ""
        parentKey = ((opts["parent"] as? [String: Any])?["key"] as? String) ?? ""
        mirror = (opts["mode"] as? String) == "mirror"
        single = (opts["mode"] as? String) == "single"
        paused = (opts["startpaused"] as? Bool) ?? false
        events = ScriptAnimationEvents.parse(opts["events"], frameDuration: 1 / fps)
        let wrap = (opts["wraploop"] as? Bool) ?? false
        // `relative` is tested for presence only; applies to c0–c2 when `value` is a 3-component string.
        let base: [Float]? = anim["relative"] != nil ? Self.relativeBase(obj["value"]) : nil

        var chans: [Channel] = []
        for (ci, name) in ["c0", "c1", "c2", "c3"].enumerated() {
            guard let list = anim[name] as? [Any] else { break } // a missing channel stops the chain
            var keys = Self.parseKeys(list, offset: base.flatMap { ci < 3 ? $0[ci] : nil } ?? 0)
            if wrap { keys = Self.wrapLoop(keys, length) }
            chans.append(Channel(keys))
        }
        guard !chans.isEmpty else { return nil }
        channels = chans
    }

    static func relativeBase(_ v: Any?) -> [Float]? {
        guard let s = v as? String else { return nil }
        if s.isEmpty { return [0, 0, 0] }
        let parts = s.split(separator: " ", omittingEmptySubsequences: true)
        guard parts.count >= 2, s.contains(" ") else { return nil }
        func atof(_ x: Substring?) -> Float { x.flatMap { Float($0) ?? Float($0.prefix(while: { "+-.0123456789eE".contains($0) })) } ?? 0 }
        return [atof(parts[0]), atof(parts[1]), atof(parts.count > 2 ? parts[2] : nil)]
    }

    static func parseKeys(_ list: [Any], offset: Float) -> [Key] {
        var keys: [Key] = []
        var last = -1
        for item in list {
            let k = (item as? [String: Any]) ?? [:]
            let frame = (k["frame"] as? NSNumber)?.intValue ?? 0
            if frame <= last { continue } // non-increasing frames are dropped
            var value = (k["value"] as? NSNumber)?.floatValue ?? 0
            if offset != 0, k["value"] is NSNumber { value += offset }
            var key = Key(frame: frame, value: value)
            if (k["step"] as? Bool) == true || (k["step"] as? NSNumber)?.boolValue == true {
                key.step = true
            } else {
                if let b = k["back"] as? [String: Any], (b["enabled"] as? Bool) == true {
                    key.hasBack = true
                    key.back = SIMD2((b["x"] as? NSNumber)?.floatValue ?? 0, (b["y"] as? NSNumber)?.floatValue ?? 0)
                }
                if let f = k["front"] as? [String: Any], (f["enabled"] as? Bool) == true {
                    key.hasFront = true
                    key.front = SIMD2((f["x"] as? NSNumber)?.floatValue ?? 0, (f["y"] as? NSNumber)?.floatValue ?? 0)
                }
            }
            keys.append(key)
            last = frame
        }
        return keys
    }

    /// Anim_WrapLoop: drop keys past `length`, close the loop at `length` with key 0's value.
    static func wrapLoop(_ input: [Key], _ length: Int) -> [Key] {
        var keys = input
        guard keys.count > 1 else { return keys }
        let k0 = keys[0]
        while keys.count > 1, keys[keys.count - 1].frame > length { keys.removeLast() }
        guard keys.count > 1 else { return keys }
        if keys[keys.count - 1].frame != length { keys.append(Key(frame: length, value: 0)) }
        var lastKey = keys[keys.count - 1]
        if k0.hasFront { lastKey.hasBack = true; lastKey.back = -k0.front } else { lastKey.hasBack = false; lastKey.back = .zero }
        lastKey.value = k0.value
        keys[keys.count - 1] = lastKey
        return keys
    }

    /// Channel_Sample at an integer frame.
    static func sample(_ keys: [Key], _ fr: Int) -> Float {
        guard let first = keys.first else { return 0 }
        if fr <= first.frame { return first.value }
        var i = 1
        while i < keys.count && !(keys[i - 1].frame <= fr && fr < keys[i].frame) { i += 1 }
        guard i < keys.count else { return keys[keys.count - 1].value }
        let p = keys[i - 1], q = keys[i]
        if p.frame == fr || q.step { return p.value }
        let span = Float(q.frame - p.frame)
        let h = span * 0.5
        let P0x = Float(p.frame), P3x = Float(q.frame)
        let P1x = h * p.front.x + P0x, P2x = h * q.back.x + P3x
        let x = Float(fr)
        var t: Float = 0 // integer division in the binary → always starts at 0
        var step: Float = 0.999
        for _ in 0..<1000 {
            let s = 1 - t
            let a = s * s * s * P0x
            let s3 = s * 3
            let b = s3 * s * t, c = s3 * t * t
            let xv = P1x * b + a + P2x * c + t * t * t * P3x
            if abs(xv - x) < 0.01 { break }
            step *= 0.5
            t = xv > x ? t - step : t + step
        }
        t = min(max(t, 0), 1)
        let P1y = p.value + p.front.y, P2y = q.value + q.back.y
        let s = 1 - t, s3 = s * 3
        return s3 * s * t * P1y + s * s * s * p.value + s3 * t * t * P2y + t * t * t * q.value
    }

    /// `Timeline_Advance` (docs/re/06 §3.1).
    public func advance(_ dt: Float) {
        guard !paused, !finished, duration > 0 else { return }
        if single && time >= duration { return }
        let dt = dt * rate
        if !events.isEmpty {
            firedEvents += ScriptAnimationEvents.crossed(events, old: time, delta: backwards ? -dt : dt, duration: duration,
                                                         mode: single ? .single : mirror ? .mirror : .loop)
        }
        var t = time + (backwards ? -dt : dt)
        if single {
            if t >= duration { t = duration; finished = true }
        } else if mirror {
            if backwards { if t <= 0 { t = -fmodf(t, duration); backwards = false } }
            else if t >= duration { t = duration - fmodf(t, duration); backwards = true }
        } else {
            if t < 0 { t = fmodf(t + duration, duration) }
            if t >= duration { t = fmodf(t, duration) }
        }
        time = t
    }

    /// `Binder_Register` parent link: an animation with a parent key takes the first animation on the same target
    /// that has no parent key of its own and whose bound property is named `key`, whichever registered first
    /// (unmatched children wait in the binder's +0x80 list until the parent arrives, 0x1401769dd).
    public static func link(_ animations: [(property: String, animation: PropertyAnimation)]) {
        for (_, child) in animations where !child.parentKey.isEmpty {
            child.timelineParent = animations.first { $0.property == child.parentKey && $0.animation.parentKey.isEmpty }?.animation
        }
    }

    // SceneScript controls (docs/re/08 §3.10, natives 0x1401707f0…0x1401708a0).
    public var isPlaying: Bool { !paused && !finished }
    public func play() { paused = false; if finished { finished = false; time = 0; backwards = false } }
    public func stop() { paused = true; finished = false; time = 0; backwards = false }
    public func setFrame(_ f: Float) { time = min(max(f / fps, 0), duration); finished = false }
    public var frame: Float { time * fps }

    /// Current value per channel: integer-frame samples blended linearly by the frame fraction. `time`, the frame
    /// duration and the length come from the timeline owner (`Bindings_Tick` 0x1401723d8: `[rdi+0x3c]`, `[rdi+0x38]`, …).
    public var value: [Float] {
        let owner = timelineParent ?? self
        let time = owner.time, frameDuration = owner.frameDuration, length = owner.length
        let frac = fmodf(time, frameDuration) / frameDuration
        let q = time / frameDuration
        let fi = abs(q) < 2_147_483_648 ? Int(q) : Int(Int32.min)
        let a = max(min(fi, length - 1), 0)
        let b = min(a + 1, length)
        return channels.map { $0.at(a) * (1 - frac) + $0.at(b) * frac }
    }

    /// The binding writes nothing unless the channel count matches the property's arity.
    public func value(arity: Int) -> [Float]? { channels.count == arity ? value : nil }
}
