import Foundation
import PhotonCore
import simd

/// Scene camera paths: `camera.paths` (a list of path files) played when no camera object is active
/// (docs/re/04 §3.4, loader-keys.md §6.7).
///
/// `CameraPath_Load` 0x140198e20 reads one file: `paths` must be an array; each member must be an object with a
/// non-empty `transforms` array, and `disabled: true` drops it. `duration` is `Json_AsFloat`. Each transform (object,
/// `disabled: true` skips it but it still counts for the timestamp spread) gives a 0x2c-byte key
/// `{time, eye, center, up, zoom}`: eye/center/up are strings parsed token by token with `atof` (missing → 0),
/// `zoom` is `Json_AsFloat` when present (`find`), else 1, and `timestamp` is used when numeric, else the key is spread
/// evenly: `index / (count − 1) · duration` (index 0 → 0).
///
/// Playback (`Scene_Update` 0x1401894a9–0x140189b07, path index S+0xe4, key index S+0xe8, elapsed S+0xec):
/// between k0 and k1 a cubic Hermite with both tangents ½(p1 − p0) per component of eye, centre, up and zoom; before k0
/// or after the last key the key's values are held. The advance threshold is k1.time, or `duration − k0.time` past the
/// last key, or `k1.time + k0.time` before k0 (engine quirk). After `elapsed += dt` crosses it the key advances while
/// `duration > keys[k+1].time`, otherwise the next path starts (wrapping) with elapsed 0.
///
/// `camerafade` (S+0xe0 bit 2, default on) loads `materials/util/fade.json` when paths exist (0x140181bb5) and draws
/// it after the combine (`Renderer_Frame` 0x140180c0b–0x140180cc5): remaining = duration − elapsed;
/// alpha = 1 − 2·remaining in the last ½ s, 1 − 2·elapsed in the first ½ s, else nothing.
final class SceneCameraPaths {
    struct Key {
        var time: Float
        var eye: SIMD3<Float>, center: SIMD3<Float>, up: SIMD3<Float>
        var zoom: Float
    }
    struct Path {
        var keys: [Key]
        var duration: Float
    }

    var paths: [Path] = []
    var pathIndex = 0, keyIndex = 0
    var elapsed: Float = 0

    init(files: [String], fs: AssetFileSystem) {
        for f in files { paths += Self.load(fs.readJSON(f)) }
    }

    var isEmpty: Bool { paths.isEmpty }

    /// `atof` per token: the token is parsed, then the scan skips to the next space and over the spaces.
    static func vec3(_ v: Any?) -> SIMD3<Float> {
        guard let s = v as? String else { return .zero }
        var out = SIMD3<Float>(0, 0, 0)
        var rest = Substring(s)
        for i in 0..<3 {
            out[i] = cAtof(rest)
            if let sp = rest.firstIndex(of: " ") { rest = rest[sp...].drop(while: { $0 == " " }) } else { rest = rest[rest.endIndex...] }
        }
        return out
    }

    /// C `atof` (0x1402d06ac) then `cvtsd2ss`.
    static func cAtof(_ s: Substring) -> Float { Float(String(s).withCString { strtod($0, nil) }) }

    /// `Json_AsFloat` 0x140086220 for the value types a path file can hold.
    static func asFloat(_ v: Any?) -> Float {
        if let n = v as? NSNumber { return n.floatValue }
        return 0
    }

    static func load(_ json: Any?) -> [Path] {
        guard let root = json as? [String: Any], let list = root["paths"] as? [Any] else { return [] }
        var out: [Path] = []
        for item in list {
            guard let p = item as? [String: Any], let transforms = p["transforms"] as? [Any], !transforms.isEmpty else { continue }
            if jsonBool(p["disabled"], default: false) { continue }
            let duration = asFloat(p["duration"])
            var keys: [Key] = []
            for (i, t) in transforms.enumerated() {
                guard let k = t as? [String: Any] else { continue }
                if jsonBool(k["disabled"], default: false) { continue }
                var time: Float = 0
                if let n = k["timestamp"] as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID() {
                    time = n.floatValue
                } else if i != 0 {
                    time = Float(i) / Float(transforms.count - 1) * duration
                }
                keys.append(Key(time: time, eye: vec3(k["eye"]), center: vec3(k["center"]), up: vec3(k["up"]),
                                zoom: k["zoom"] != nil ? asFloat(k["zoom"]) : 1))
            }
            out.append(Path(keys: keys, duration: duration))
        }
        return out
    }

    /// One `Scene_Update` step: returns eye, centre, up and zoom for this frame (before shake) and advances by `dt`.
    func step(_ dt: Float) -> (eye: SIMD3<Float>, center: SIMD3<Float>, up: SIMD3<Float>, zoom: Float)? {
        guard !paths.isEmpty, pathIndex < paths.count else { return nil }
        let path = paths[pathIndex]
        guard keyIndex < path.keys.count else {
            // An all-disabled path has no keys (the engine reads past the vector); move on.
            advancePath()
            return nil
        }
        let k0 = path.keys[keyIndex]
        let k1 = keyIndex + 1 < path.keys.count ? path.keys[keyIndex + 1] : nil
        var result = (eye: k0.eye, center: k0.center, up: k0.up, zoom: k0.zoom)
        let threshold: Float
        if elapsed >= k0.time, let k1 {
            let t = (elapsed - k0.time) / (k1.time - k0.time)
            let t2 = t * t, t3 = t2 * t
            let h00 = 2 * t3 - 3 * t2 + 1, h10 = t3 - 2 * t2 + t, h01 = 3 * t2 - 2 * t3, h11 = t3 - t2
            func herm(_ a: Float, _ b: Float) -> Float {
                let m = (b - a) * 0.5
                return h00 * a + h10 * m + h01 * b + h11 * m
            }
            func herm3(_ a: SIMD3<Float>, _ b: SIMD3<Float>) -> SIMD3<Float> { SIMD3(herm(a.x, b.x), herm(a.y, b.y), herm(a.z, b.z)) }
            result = (herm3(k0.eye, k1.eye), herm3(k0.center, k1.center), herm3(k0.up, k1.up), herm(k0.zoom, k1.zoom))
            threshold = k1.time
        } else if elapsed >= k0.time {
            threshold = path.duration - k0.time
        } else {
            threshold = (k1?.time ?? 0) + k0.time
        }
        elapsed += dt
        if elapsed > threshold {
            if keyIndex + 1 < path.keys.count, path.duration > path.keys[keyIndex + 1].time {
                keyIndex += 1
            } else {
                advancePath()
            }
        }
        return result
    }

    private func advancePath() {
        keyIndex = 0
        elapsed = 0
        pathIndex = pathIndex + 1 >= paths.count ? 0 : pathIndex + 1
    }

    /// Fade alpha for this frame (0x140180c23–0x140180c8c), after the step.
    var fadeAlpha: Float {
        guard pathIndex < paths.count else { return 0 }
        let duration = paths[pathIndex].duration
        let remaining = duration - elapsed
        if remaining < 0.5 { return 1 - 2 * remaining }
        if remaining > duration - 0.5 { return 1 - 2 * (duration - remaining) }
        return 0
    }
}

/// A camera object's `path` file (`Camera_Load` 0x1401f2030): `paths` is an array of objects, each an animation of the
/// camera with `options` (required, the property-animation options; a path without valid options is dropped),
/// `events`, `eye` / `center` / `up` (objects with keyframe channels `c0`…`c2`, 0x1401f1bc0), `zoom` and `fov`
/// (keyframe arrays), and the reflected `visible` / `name` (CameraPath_RegisterProps 0x140004540).
/// `Camera_Update` 0x1401f2ad0 plays one path at a time, chosen by `queuemode` (+0x350: `random` 0 = default,
/// `sequential` 1; enum table built at 0x1401f37f7–0x1401f38a4).
final class CameraPathAnimation {
    let options: [String: Any]
    let json: [String: Any]
    var visible: Bool
    let name: String
    private(set) var master: PropertyAnimation?
    private(set) var eye: PropertyAnimation?, center: PropertyAnimation?, up: PropertyAnimation?
    private(set) var zoom: PropertyAnimation?, fov: PropertyAnimation?
    let single: Bool

    init?(_ p: [String: Any]) {
        guard let opts = p["options"] as? [String: Any] else { return nil }
        options = opts
        json = p
        visible = jsonBool(p["visible"], default: true)
        name = (p["name"] as? String) ?? ""
        single = (opts["mode"] as? String) == "single"
        guard build() else { return nil }
    }

    /// Timeline_Init via the options loader 0x1401a96b0 (fails like PropertyAnimation for fps ≤ 0 or length 0).
    @discardableResult
    func build() -> Bool {
        var opts = options
        opts["events"] = json["events"]
        func anim(_ channels: [String: Any]) -> PropertyAnimation? {
            var a = channels
            a["options"] = opts
            return PropertyAnimation(json: ["animation": a])
        }
        master = anim(["c0": [["frame": 0, "value": 0]]])
        guard let master else { return false }
        func vec(_ v: Any?) -> PropertyAnimation? {
            guard let o = v as? [String: Any] else { return nil }
            var ch: [String: Any] = [:]
            for c in ["c0", "c1", "c2"] { if let l = o[c] as? [Any] { ch[c] = l } }
            return ch.isEmpty ? nil : anim(ch)
        }
        func scalar(_ v: Any?) -> PropertyAnimation? { (v as? [Any]).flatMap { anim(["c0": $0]) } }
        eye = vec(json["eye"]); center = vec(json["center"]); up = vec(json["up"])
        zoom = scalar(json["zoom"]); fov = scalar(json["fov"])
        for a in [eye, center, up, zoom, fov] { a?.timelineParent = master }
        return true
    }

    /// Timeline flag 0x40000000 (single mode reached the end).
    var finished: Bool { guard let m = master else { return true }; return single && m.time >= m.duration }

    /// 0x1401f2b95: a finished path is reset (flag cleared, time 0) when the next one is chosen.
    func reset() { build() }
}

/// The camera object's path player (`Camera_Update` 0x1401f2ad0).
final class CameraPathPlayer {
    var paths: [CameraPathAnimation]
    var current = -1                    // +0x2e0
    var queueMode = 0                   // +0x350: 0 random, 1 sequential
    var bag: [Int] = []                 // +0x328 shuffle bag
    var last: Int?                      // +0x340 / +0x344

    init(paths: [CameraPathAnimation], queueMode: Int) {
        self.paths = paths
        self.queueMode = queueMode
    }

    /// Picks the path to play this frame; nil when none.
    func select() -> CameraPathAnimation? {
        if current >= 0, current < paths.count {
            let p = paths[current]
            if !p.finished { return p }
            p.reset()
        }
        if queueMode == 1 {
            // Sequential: the next visible path (+0xf0 bit 0), trying each path once.
            for _ in 0..<paths.count {
                current = (current + 1) % paths.count
                if paths[current].visible { return paths[current] }
            }
            return nil
        }
        if queueMode != 0 { return nil }
        // Random: a shuffle bag of all paths, refilled when empty; an index equal to the last pick moves on by one.
        current = -1
        guard !paths.isEmpty else { return nil }
        if bag.isEmpty { bag = Array(paths.indices) }
        // 0x1401f2d77–0x1401f2da0: `std::uniform_int_distribution<int>{0, count − 1}` (0x140077e10, MSVC
        // `_Rng_from_urng_v2`: Lemire multiply with rejection) on the generator at +0x348, which the camera ctor
        // (0x14019073e) points at the render context's mt19937 C+0x1cd0: the same wall-clock-seeded generator the
        // particles draw from (`PRand`, PHOTON_SEED fixes it).
        var i = PRand.uniformIndex(bag.count)
        if let last {
            var n = 0
            while bag[i] == last && n < bag.count { i = (i + 1) % bag.count; n += 1 }
        }
        let pick = bag.remove(at: i)
        current = pick
        last = pick
        return paths[pick]
    }

    /// One update: advances the chosen path and returns the eye/centre/up (engine LookAt input) and zoom/fov.
    /// Unset vectors default from the camera's world matrix (eye = row 3, centre = eye − 5·normalize(row 2),
    /// up = normalize(row 1), 0x1401f2f5a–0x1401f3072).
    func update(_ dt: Float, world: simd_float4x4, ortho: Bool) -> (eye: SIMD3<Float>, center: SIMD3<Float>, up: SIMD3<Float>, zoom: Float?, fov: Float?)? {
        guard let p = select(), let master = p.master else { return nil }
        master.advance(dt)
        let r1 = SIMD3(world.columns.1.x, world.columns.1.y, world.columns.1.z)
        let r2 = SIMD3(world.columns.2.x, world.columns.2.y, world.columns.2.z)
        var eye = SIMD3(world.columns.3.x, world.columns.3.y, world.columns.3.z)
        var center = eye - simd_normalize(r2) * 5
        var up = simd_normalize(r1)
        func apply(_ a: PropertyAnimation?, _ v: inout SIMD3<Float>) {
            guard let vals = a?.value else { return }
            for i in 0..<min(3, vals.count) { v[i] = vals[i] }
        }
        apply(p.eye, &eye); apply(p.center, &center); apply(p.up, &up)
        // 0x1401f334e: ortho scenes take the zoom track (default 1), perspective scenes the fov track (default 50).
        let zoom: Float? = ortho ? (p.zoom?.value.first ?? 1) : nil
        let fov: Float? = ortho ? nil : (p.fov?.value.first ?? 50)
        return (eye, center, up, zoom, fov)
    }

    /// 0x1401f31f2–0x1401f3306: the camera's origin becomes the eye and its angles are read off the LookAt view matrix
    /// (z = atan2(m10, m00); y = atan2(−m20, √(m21² + m22²)); x = atan2(m02·sin z − m12·cos z, m11·cos z − m01·sin z)).
    static func angles(eye: SIMD3<Float>, center: SIMD3<Float>, up: SIMD3<Float>) -> SIMD3<Float> {
        let V = Mat.lookAtRH(eye: eye, center: center, up: up)
        // Engine row-vector m[r][c] = simd columns[r][c].
        func m(_ r: Int, _ c: Int) -> Float { V[r][c] }
        let z = atan2f(m(1, 0), m(0, 0))
        let s = sinf(z), c = cosf(z)
        let y = atan2f(-m(2, 0), sqrtf(m(2, 1) * m(2, 1) + m(2, 2) * m(2, 2)))
        let x = atan2f(m(0, 2) * s - m(1, 2) * c, m(1, 1) * c - m(0, 1) * s)
        return SIMD3(x, y, z)
    }
}
