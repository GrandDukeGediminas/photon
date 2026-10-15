import Foundation
import PhotonCore
import simd

// Particle definition parse (docs/re/05 Part 1 §1, Part 2 §3–4, Part 3 §3, Part 4 §5.1). The engine compiles
// each list into bytecode records; here each record is a Swift value kept in JSON order. Values that the
// engine's override-binding records rescale (§5.3) are stored unscaled and multiplied by `PScales` at use.

struct PAudio {
    var mode = 0, exponent: Float = 2, lo: Float = 0.8, hi: Float = 1, start = 0, end = 1

    init(_ j: PJ) {
        mode = j.i("audioprocessingmode", 0)
        exponent = j.f("audioprocessingexponent", 2)
        let b = j.v3("audioprocessingbounds", SIMD3(0.8, 1, 0), scalar: { SIMD3($0, 0, 0) })
        lo = b.x; hi = b.y
        start = min(max(j.i("audioprocessingfrequencystart", 0), 0), 15)
        end = min(max(j.i("audioprocessingfrequencyend", 1), 0), 15)
        if start > end { swap(&start, &end) }
    }

    /// `0x14022a8a0`. There is no audio input yet, so the spectrum is silent (all bands 0).
    func response(_ bands: [Float]) -> Float {
        guard mode != 0 else { return 1 }
        var peak: Float = 0
        for k in start...end {
            let l = k < bands.count ? bands[k] : 0, r = k + 16 < bands.count ? bands[k + 16] : 0
            switch mode {
            case 1: peak = max(peak, l)
            case 2: peak = max(peak, r)
            case 3: peak = max(peak, (l + r) * 0.5)
            default: break
            }
        }
        var t = clamp01((peak - lo) / (hi - lo))
        t = t * t * (3 - 2 * t)
        return clamp01(powf(t, exponent))
    }
}

/// Life-blend block (Part 3 §1.4).
struct PBlend {
    var bis: Float = 0, rcpIn: Float = 1, boe: Float = 1, rcpOut: Float = 1
    var active = false

    init(_ j: PJ) {
        let bi = j.f("blendinstart", 0), be = j.f("blendinend", 0), bo = j.f("blendoutstart", 1), bE = j.f("blendoutend", 1)
        bis = min(bi, be - 0.0001)
        boe = max(bE, bo + 0.0001)
        rcpIn = SSEApprox.rcp(be - bis)   // rcpps 0x1401c2df3 / 0x1401c2e01 (ParseLifeBlend)
        rcpOut = SSEApprox.rcp(boe - bo)
        active = (be > 0.01 || bo < 0.99) && ((bo - be) > 0.01 || (be - bis) > 0.01 || (boe - bo) > 0.01)
    }

    @inline(__always) func factor(_ t: Float) -> Float {
        guard active else { return 1 }
        return clamp01((t - bis) * rcpIn) * clamp01((boe - t) * rcpOut)
    }
}

struct PEmitterDef {
    enum Kind { case sphere, box, layerImage }
    var kind: Kind
    var rate: Float, duration: Float, delay: Float
    var minPDur: Float, maxPDur: Float, minPDelay: Float, maxPDelay: Float
    var maxPerPeriod: Int, instantaneous: Int, flags: UInt32
    var audio: PAudio
    var origin: SIMD3<Float>, directions: SIMD3<Float>, sign: SIMD3<Float>
    var distMin: SIMD3<Float>, distMax: SIMD3<Float>
    var speedMin: Float, speedMax: Float
    var cp: Int
    var coneZ: Float
    /// layerimage (op 3, parse 0x1401c6b08, defaults 0x1401b9930): payload +0x78 offsetmin, +0x84 offsetmax − offsetmin.
    var offsetMin = SIMD3<Float>(0, 0, 0), offsetRange = SIMD3<Float>(0, 0, 0)

    init?(_ j: PJ, ortho: Bool) {
        switch j.s("name", "") {
        case "sphererandom": kind = .sphere
        case "boxrandom": kind = .box
        case "layerimage": kind = .layerImage
        default: return nil
        }
        rate = j.f("rate", 10)
        duration = j.f("duration", 0)
        delay = j.f("delay", 0)
        maxPDur = j.f("maxperiodicduration", 3)
        minPDur = min(j.f("minperiodicduration", 2), maxPDur)
        maxPDelay = j.f("maxperiodicdelay", 2)
        minPDelay = min(j.f("minperiodicdelay", 1), maxPDelay)
        maxPerPeriod = j.i("maxtoemitperperiod", 0)
        instantaneous = j.i("instantaneous", 0)
        flags = UInt32(truncatingIfNeeded: j.i("flags", kind == .layerImage ? 0x10000 : 0))
        audio = PAudio(j)
        origin = j.v3("origin", .zero)
        speedMin = j.f("speedmin", 0)
        speedMax = j.f("speedmax", 0)
        cp = PRemap.cp(j.i("controlpoint", 0))
        sign = .zero
        coneZ = -1
        switch kind {
        case .sphere:
            directions = j.v3("directions", SIMD3(1, 1, 0))
            sign = j.v3("sign", .zero)
            // 0x1401c61e7: dot(sign, sign) against FLT_EPSILON (0x34000000, 0x1404925e0).
            if simd_dot(sign, sign) > Float.ulpOfOne { flags |= 1 } else { flags &= ~1 }
            distMin = SIMD3(repeating: j.f("distancemin", 0))
            distMax = SIMD3(repeating: j.f("distancemax", ortho ? 256 : 1))
            coneZ = -cosf(j.f("cone", 0) * pPi)
        case .box:
            directions = j.v3("directions", ortho ? SIMD3(1, 1, 0) : SIMD3(1, 1, 1))
            distMin = j.v3("distancemin", .zero)
            distMax = j.v3("distancemax", ortho ? SIMD3(256, 256, 0) : SIMD3(1, 1, 1))
        case .layerImage:
            directions = .zero; distMin = .zero; distMax = .zero
            speedMin = j.f("speedmin", 0.1)
            speedMax = j.f("speedmax", 0.2)
            offsetMin = j.v3("offsetmin", ortho ? SIMD3(-5, -5, 0) : .zero)
            offsetRange = j.v3("offsetmax", ortho ? SIMD3(5, 5, 0) : .zero) - offsetMin
        }
    }
}

enum PInit {
    case lifetime(min: Float, max: Float, exp: Float)
    case size(min: Float, max: Float, exp: Float)
    case color(min: SIMD3<Float>, max: SIMD3<Float>, exp: Float)
    case hsv(hueMin: Float, hueStep: Float, steps: Int, hueRange: Float, satMin: Float, satRange: Float, valMin: Float, valRange: Float)
    case colorList(hsv: [SIMD3<Float>], noise: SIMD3<Float>)
    case alpha(min: Float, max: Float, exp: Float)
    case velocity(min: SIMD3<Float>, max: SIMD3<Float>, exp: Float)
    case inheritCPVelocity(min: Float, max: Float, cp: Int)
    case turbulentVelocity(TurbVel)
    case rotation(min: SIMD3<Float>, max: SIMD3<Float>, exp: Float)
    case positionOffset(dir: SIMD3<Float>, sign: SIMD3<Float>, scale: Float, distance: Float, timescale: Float, octaves: Int, useSign: Bool)
    case angularVelocity(min: SIMD3<Float>, max: SIMD3<Float>, exp: Float)
    case mapAround(MapAround)
    case mapBetween(MapBetween)
    case remap(PRemapInit)
    case inheritFromEvent(mode: Int)

    struct TurbVel {
        var speedMin: Float, speedMax: Float, phaseMin: Float, phaseMax: Float, timescale: Float, scale: Float, offset: Float
        var forward: SIMD3<Float>, right: SIMD3<Float>, audio: PAudio
    }

    struct MapAround {
        var count: Float, lo: Float, range: Float, speedMin: SIMD3<Float>, speedMax: SIMD3<Float>, axis: SIMD3<Float>, mirror: Bool, cp: Int
        /// The count override applies only when payload +0x54 & 1, which the parser never writes (#44): never.
        var countOverride: Bool { false }
        /// `0x1401c19e0` (payload +0x28 n, +0x34 u, +0x40 w): n = axis·(1/√((x² + y²) + z²)), an exactly zero axis giving
        /// (0, 0, 1); n.x = n.y = 0 → u = (1, 0, 0), w = (0, 1, 0); otherwise c = cross(n, (0, 0, 1)) = (n.y, −n.x, 0),
        /// u = c·(1/|c|), w = cross(n, c)·(1/|cross(n, c)|) (normalised from the unnormalised c). `axis` is stored raw.
        var basis: (n: SIMD3<Float>, u: SIMD3<Float>, w: SIMD3<Float>) {
            @inline(__always) func inv(_ v: SIMD3<Float>) -> Float { 1 / sqrtf((v.x * v.x + v.y * v.y) + v.z * v.z) }
            var n = SIMD3<Float>(0, 0, 1)
            if axis != .zero { let k = inv(axis); n = SIMD3(axis.x * k, axis.y * k, axis.z * k) }
            if n.x == 0 && n.y == 0 { return (n, SIMD3(1, 0, 0), SIMD3(0, 1, 0)) }
            let c = SIMD3<Float>(n.y - n.z * 0, n.z * 0 - n.x, n.x * 0 - n.y * 0)
            let ku = inv(c)
            let w0 = SIMD3<Float>(n.y * c.z - n.z * c.y, n.z * c.x - n.x * c.z, n.x * c.y - n.y * c.x)
            let kw = 1 / sqrtf((w0.y * w0.y + w0.x * w0.x) + w0.z * w0.z)
            return (n, SIMD3(c.x * ku, c.y * ku, c.z * ku), SIMD3(w0.x * kw, w0.y * kw, w0.z * kw))
        }
    }

    struct MapBetween {
        var count: Float, lo: Float, range: Float, mirror: Bool, cpStart: Int, cpEnd: Int, flags: Int
        var arcAmount: Float, arcDirection: SIMD3<Float>, sizeReduction: Float
        /// The count override record applies only when JSON flags & 0x10 (#44).
        var countOverride: Bool { flags & 0x10 != 0 }
        /// Reset by the periodic phase-start callback 0x14022f790 when JSON flags & 0x20 (#48).
        var periodicReset: Bool { flags & 0x20 != 0 }
    }

    static let inheritModes = ["setcolor", "multiplycolor", "setopacity", "multiplyopacity", "setcoloropacity",
                               "multiplycoloropacity", "setvelocity", "addvelocity", "setsize", "multiplysize", "setrotation",
                               "addrotation", "setangularvelocity", "addangularvelocity"]

    /// Returns nil for unknown names (silently skipped). `mask` collects the attribute "needs" bits (§4).
    static func parse(_ j: PJ, ortho: Bool, mask: inout UInt8) -> PInit? {
        let e = j.f("exponent", 1)
        switch j.s("name", "") {
        case "lifetimerandom": return .lifetime(min: j.f("min", 0), max: j.f("max", 1), exp: e)
        case "sizerandom": return .size(min: j.f("min", ortho ? 5 : 0.001), max: j.f("max", ortho ? 50 : 1), exp: e)
        case "colorrandom":
            return .color(min: j.v3("min", .zero) / 255, max: j.v3("max", SIMD3(255, 255, 255)) / 255, exp: e)
        case "hsvcolorrandom":
            let hmin = j.f("huemin", 0), hmax = j.f("huemax", 1)
            let steps = max(j.i("huesteps", 6), 0)
            var step: Float = 0
            if steps > 1 {
                var span = hmax - hmin
                if span == 0 { span = 1 }
                var denom = Float(steps - 1)
                if abs(fmodf(span, 1)) < 1.0 / 360 { denom += 1 }
                step = span / denom
            }
            let smin = j.f("saturationmin", 0.5), vmin = j.f("valuemin", 0.5)
            return .hsv(hueMin: hmin, hueStep: step, steps: steps, hueRange: hmax - hmin, satMin: smin,
                        satRange: j.f("saturationmax", 1) - smin, valMin: vmin, valRange: j.f("valuemax", 1) - vmin)
        case "colorlist":
            var list: [SIMD3<Float>] = []
            for c in (j.d["colors"] as? [Any]) ?? [] {
                let f = jsonFloats(c)
                if f.count >= 3 { list.append(HSV.fromRGB(SIMD3(f[0], f[1], f[2]))) }
            }
            if list.isEmpty { list = [SIMD3(0, 1, 1)] }
            return .colorList(hsv: list, noise: SIMD3(j.f("huenoise", 0), j.f("saturationnoise", 0), j.f("valuenoise", 0)))
        case "alpharandom": return .alpha(min: j.f("min", 0.05), max: j.f("max", 1), exp: e)
        case "velocityrandom":
            return .velocity(min: j.v3("min", ortho ? SIMD3(-32, -32, 0) : SIMD3(-1, -1, -1)),
                             max: j.v3("max", ortho ? SIMD3(32, 32, 0) : SIMD3(1, 1, 1)), exp: e)
        case "inheritcontrolpointvelocity":
            return .inheritCPVelocity(min: j.f("min", 0.1), max: j.f("max", 0.2), cp: PRemap.cp(j.i("controlpoint", 0)))
        case "turbulentvelocityrandom":
            return .turbulentVelocity(TurbVel(speedMin: j.f("speedmin", ortho ? 100 : 0.5), speedMax: j.f("speedmax", ortho ? 250 : 1),
                                              phaseMin: j.f("phasemin", 0), phaseMax: j.f("phasemax", 0.1),
                                              timescale: j.f("timescale", 1), scale: j.f("scale", 1), offset: j.f("offset", 0),
                                              forward: j.v3("forward", SIMD3(0, 1, 0)), right: j.v3("right", SIMD3(0, 0, 1)),
                                              audio: PAudio(j)))
        case "rotationrandom":
            mask |= 1
            let num: (Float) -> SIMD3<Float> = { SIMD3(0, 0, $0) }
            return .rotation(min: j.v3("min", .zero, scalar: num), max: j.v3("max", SIMD3(0, 0, 6.28318530717), scalar: num), exp: e)
        case "positionoffsetrandom":
            let sign = j.v3("sign", .zero)
            return .positionOffset(dir: j.v3("directions", ortho ? SIMD3(1, 1, 0) : SIMD3(1, 1, 1)), sign: sign,
                                   scale: j.f("scale", ortho ? 0.001 : 1), distance: j.f("distance", ortho ? 100 : 0.1),
                                   timescale: j.f("timescale", 1), octaves: min(max(j.i("octaves", 6), 1), 8),
                                   useSign: sign != .zero)
        case "angularvelocityrandom":
            mask |= 2
            let num: (Float) -> SIMD3<Float> = { SIMD3(0, 0, $0) }
            return .angularVelocity(min: j.v3("min", SIMD3(0, 0, -5), scalar: num), max: j.v3("max", SIMD3(0, 0, 5), scalar: num), exp: e)
        case "mapsequencearoundcontrolpoint":
            let b = j.v3("bounds", SIMD3(0, 1, 0))
            return .mapAround(MapAround(count: j.f("count", 32), lo: b.x, range: b.y - b.x, speedMin: j.v3("speedmin", .zero),
                                        speedMax: j.v3("speedmax", .zero), axis: j.v3("axis", SIMD3(0, 0, 1)),
                                        mirror: j.s("limitbehavior", "repeat") == "mirror", cp: PRemap.cp(j.i("controlpoint", 0))))
        case "mapsequencebetweencontrolpoints":
            let b = j.v3("bounds", SIMD3(0, 1, 0))
            return .mapBetween(MapBetween(count: j.f("count", 32), lo: b.x, range: b.y - b.x,
                                          mirror: j.s("limitbehavior", "repeat") == "mirror",
                                          cpStart: PRemap.cp(j.i("controlpointstart", 0)),
                                          cpEnd: PRemap.cp(j.i("controlpointend", 1)),
                                          flags: j.i("flags", 0), // Inferred key name.
                                          arcAmount: j.f("arcamount", 0.3), arcDirection: j.v3("arcdirection", SIMD3(0, 1, 0)),
                                          sizeReduction: j.f("sizereductionamount", 0.9)))
        case "remapinitialvalue":
            return .remap(PRemapInit(j))
        case "inheritinitialvaluefromevent":
            return .inheritFromEvent(mode: inheritModes.firstIndex(of: j.s("input", "setcolor")) ?? 15)
        default:
            return nil
        }
    }
}

/// Shared by `remapinitialvalue` and the `remapvalue` operator (Part 3 §19).
struct PRemap {
    static let ios = ["lifetimefraction", "maxlifetime", "size", "opacity", "speed", "rotation", "angularspeed",
                      "distancetocontrolpoint", "positionbetweentwocontrolpoints", "runtime", "timeofday", "particlesystemtime",
                      "layertime", "color", "position", "velocity", "controlpoint", "deltatocontrolpoint",
                      "directiontocontrolpoint", "layerorigin"]
    static let comps = ["all", "x", "y", "z", "sum", "average", "max", "min"]
    static let transforms = ["none", "sine", "square", "saw", "triangle", "simplexnoise", "fbmnoise"]
    static let ops = ["remap", "multiply", "add", "subtract"]

    var op: Int, input: Int, output: Int, inComp: Int, outComp: Int, transform: Int, octaves: Int, flags: Int
    var inMin: SIMD3<Float>, inRcp: SIMD3<Float>, outMin: SIMD3<Float>, outRange: SIMD3<Float>
    var inCP0: Int, outCP0: Int, inCP1: Int, outCP1: Int
    var inputScale: Float
    /// +0x100: FbmNorm(octaves) (noise vt+0x18).
    var norm: Float
    var blend: PBlend

    init(_ j: PJ) {
        op = Self.ops.firstIndex(of: j.s("operation", "multiply")) ?? 5
        input = Self.ios.firstIndex(of: j.s("input", "lifetimefraction")) ?? 21
        output = Self.ios.firstIndex(of: j.s("output", "size")) ?? 21
        inComp = Self.comps.firstIndex(of: j.s("inputcomponent", "all")) ?? 9
        outComp = Self.comps.firstIndex(of: j.s("outputcomponent", "all")) ?? 9
        transform = Self.transforms.firstIndex(of: j.s("transformfunction", "none")) ?? 8
        octaves = j.i("transformoctaves", 3)
        flags = j.i("flags", 0)
        inMin = j.v3("inputrangemin", .zero)
        let inMax = j.v3("inputrangemax", SIMD3(1, 1, 1))
        var r = inMax - inMin
        // 0x1401cedf3: an exactly zero range component becomes 2^-23.
        for k in 0..<3 where r[k] == 0 { r[k] = Float(bitPattern: 0x3400_0000) }
        inRcp = SSEApprox.rcp(r)   // rcpps 0x1401cee47 / 0x1401cee57 / 0x1401cee67
        outMin = j.v3("outputrangemin", .zero)
        outRange = j.v3("outputrangemax", SIMD3(1, 1, 1)) - outMin
        inCP0 = Self.cp(j.i("inputcontrolpoint0", 0)); inCP1 = Self.cp(j.i("inputcontrolpoint1", 1))
        outCP0 = Self.cp(j.i("outputcontrolpoint0", 0)); outCP1 = Self.cp(j.i("outputcontrolpoint1", 1))
        inputScale = j.f("transforminputscale", 2)
        norm = PNoise.fbmNorm(octaves)
        blend = PBlend(j)
    }

    /// Unsigned `min(cp, 7)`: a negative index becomes 7.
    static func cp(_ v: Int) -> Int { Int(min(UInt32(truncatingIfNeeded: v), 7)) }
}

/// `remapinitialvalue` (initializer type 15, InitParticle 0x14023b340 case 0x14023ce53): a separate scalar record
/// (rec+4 payload) that keeps the input range itself, not its reciprocal (gaps6/particles/initremap_ref.py).
struct PRemapInit {
    var op: Int, input: Int, output: Int, inComp: Int, outComp: Int, transform: Int, octaves: Int, flags: Int
    var inMin: SIMD3<Float>, inRange: SIMD3<Float>, outMin: SIMD3<Float>, outRange: SIMD3<Float>
    var inCP0: Int, outCP0: Int, inCP1: Int, outCP1: Int
    var inputScale: Float

    init(_ j: PJ) {
        op = PRemap.ops.firstIndex(of: j.s("operation", "multiply")) ?? 5
        // Filler 0x1401bc4b0 loads table entry [0x140484e88] (index 1, "maxlifetime"); the operator's filler 0x1401bfbb0
        // loads [0x140484e80] ("lifetimefraction").
        input = PRemap.ios.firstIndex(of: j.s("input", "maxlifetime")) ?? 21
        output = PRemap.ios.firstIndex(of: j.s("output", "size")) ?? 21
        inComp = PRemap.comps.firstIndex(of: j.s("inputcomponent", "all")) ?? 9
        outComp = PRemap.comps.firstIndex(of: j.s("outputcomponent", "all")) ?? 9
        transform = PRemap.transforms.firstIndex(of: j.s("transformfunction", "none")) ?? 8
        octaves = j.i("transformoctaves", 3)
        flags = j.i("flags", 0)
        inMin = j.v3("inputrangemin", .zero)
        inRange = j.v3("inputrangemax", SIMD3(1, 1, 1)) - inMin
        // parse 0x1401cae45: an exactly zero range component becomes 2^-23.
        for k in 0..<3 where inRange[k] == 0 { inRange[k] = Float(bitPattern: 0x3400_0000) }
        outMin = j.v3("outputrangemin", .zero)
        outRange = j.v3("outputrangemax", SIMD3(1, 1, 1)) - outMin
        inCP0 = PRemap.cp(j.i("inputcontrolpoint0", 0)); inCP1 = PRemap.cp(j.i("inputcontrolpoint1", 1))
        outCP0 = PRemap.cp(j.i("outputcontrolpoint0", 0)); outCP1 = PRemap.cp(j.i("outputcontrolpoint1", 1))
        inputScale = j.f("transforminputscale", 2)
    }
}

enum POp {
    case movement(gravity: SIMD3<Float>, drag: Float, flags: Int)
    case angularMovement(force: SIMD3<Float>, drag: Float, blend: PBlend)
    case alphaFade(fadeIn: Float, fadeOut: Float)
    case sizeChange(PChange)
    case colorChange(start: SIMD3<Float>, end: SIMD3<Float>, st: Float, rcp: Float)
    case alphaChange(PChange)
    case oscillatePosition(mask: SIMD3<Float>, fMin: Float, fMax: Float, phMin: Float, phMax: Float, sMin: Float, sMax: Float, blend: PBlend)
    case oscillateAlpha(POsc)
    case oscillateSize(POsc)
    case cpAttract(scale: Float, threshold: Float, deleteThreshold2: Float, cp: Int, flags: Int, blend: PBlend)
    case maintainDistanceToCP(distance: Float, variable: Float, cp: Int, blend: PBlend)
    case maintainDistanceBetweenCPs(start: Int, end: Int, blend: PBlend)
    case reduceMovementNearCP(inner: Float, rcp: Float, redIn: Float, redOut: Float, cp: Int, blend: PBlend)
    case turbulence(PTurb)
    case vortex(PVortex)
    case vortexV2(PVortex)
    case boids(sepT: Float, neighT: Float, maxSpeed: Float, sepF: Float, alignF: Float, cohF: Float, flags: Int)
    case capVelocity(maxSpeed: Float, blend: PBlend)
    case remap(PRemap)
    case inheritFromEvent(mode: Int, blend: PBlend)
    case collision(PCollision)
    case collisionQuad(PQuad)
    case collisionModel(PModelCollision)

    struct PChange { var sv: Float, ev: Float, st: Float, rcp: Float }
    struct POsc { var fMin: Float, fMax: Float, phMin: Float, phMax: Float, sMin: Float, sMax: Float, blend: PBlend }
    struct PTurb {
        var mask: SIMD3<Float>, scale: Float, speedMin: Float, speedMax: Float, phaseRange: Float, timescale: Float
        var axisBits: Int, audio: PAudio, blend: PBlend
    }
    struct PVortex {
        var offset: SIMD3<Float>, axis: SIMD3<Float>, inner: Float, rcp: Float, speedInner: Float, speedOuter: Float
        var flags: Int, cp: Int, audio: PAudio, blend: PBlend
        var centerForce: Float = 0, ringRadius: Float = 0, ringWidth: Float = 0, ringPullDistance: Float = 1, ringRcp: Float = 1, ringPullForce: Float = 0
    }
    struct PCollision {
        enum Shape { case plane, sphere, bounds }
        var shape: Shape, bounce: Float, behavior: Int, flags: Int, cp: Int
        var normal: SIMD3<Float> = SIMD3(0, 1, 0), distance: Float = 0, origin: SIMD3<Float> = .zero, radius: Float = 1
    }

    /// collisionquad (op 25; parse 0x1401cf725..0x1401cfd88, filler 0x1401c0870). See gaps6/particles/collision_ref.py.
    struct PQuad {
        var k: Float, behavior: Int, flags: Int, cp: Int
        var origin: SIMD3<Float>, n: SIMD3<Float>, u: SIMD3<Float>, v: SIMD3<Float>
        var raw: (n: SIMD3<Float>, u: SIMD3<Float>, v: SIMD3<Float>)
        /// +0xb0 = size.y / 2 (along U), +0xf0 = size.x / 2 (along V).
        var halfU: Float, halfV: Float
    }
    /// collisionmodel (op 26): one capsule per MDLS hit box of the linked model (`dependencies`, type collisionmodel).
    struct PModelCollision { var k: Float, behavior: Int, flags: Int }

    /// `0x14005eb80` glm::normalize: scalar 1/sqrt(x² + y² + z²), then v·inv.
    static func norm3(_ v: SIMD3<Float>) -> SIMD3<Float> {
        let l2 = (v.x * v.x + v.y * v.y) + v.z * v.z
        let inv = 1 / sqrtf(l2)
        return SIMD3(v.x * inv, v.y * inv, v.z * inv)
    }
    /// `0x14005ec40`.
    static func cross3(_ a: SIMD3<Float>, _ b: SIMD3<Float>) -> SIMD3<Float> {
        SIMD3(b.z * a.y - b.y * a.z, b.x * a.z - b.z * a.x, b.y * a.x - a.y * b.x)
    }

    static func change(_ j: PJ) -> PChange {
        let st = j.f("starttime", 0), et = j.f("endtime", 1)
        return PChange(sv: j.f("startvalue", 1), ev: j.f("endvalue", 0), st: st, rcp: SSEApprox.rcp(et - st)) // rcpps 0x1401cba90 / 0x1401cc056
    }

    static func osc(_ j: PJ, sMin: Float, sMax: Float, fMax: Float) -> POsc {
        POsc(fMin: j.f("frequencymin", 1), fMax: j.f("frequencymax", fMax), phMin: j.f("phasemin", 0),
             phMax: j.f("phasemax", pTwoPi), sMin: j.f("scalemin", sMin), sMax: j.f("scalemax", sMax), blend: PBlend(j))
    }

    static func parse(_ j: PJ, ortho P: Bool, mask: inout UInt8) -> POp? {
        let cp = PRemap.cp(j.i("controlpoint", 0))
        switch j.s("name", "") {
        case "movement":
            return .movement(gravity: j.v3("gravity", .zero), drag: j.f("drag", 0), flags: j.i("flags", 0))
        case "angularmovement":
            mask |= 3
            return .angularMovement(force: j.v3("force", .zero), drag: j.f("drag", 0), blend: PBlend(j))
        case "alphafade":
            mask |= 0x10
            return .alphaFade(fadeIn: j.f("fadeintime", 0.5), fadeOut: j.f("fadeouttime", 0.5))
        case "sizechange": return .sizeChange(change(j))
        case "colorchange":
            mask |= 8
            let st = j.f("starttime", 0), et = j.f("endtime", 1)
            return .colorChange(start: j.v3("startvalue", SIMD3(1, 1, 1)), end: j.v3("endvalue", .zero), st: st, rcp: SSEApprox.rcp(et - st)) // rcpps 0x1401cbe1b
        case "alphachange":
            mask |= 0x10
            return .alphaChange(change(j))
        case "oscillateposition":
            return .oscillatePosition(mask: j.v3("mask", SIMD3(1, 1, 0)), fMin: j.f("frequencymin", 1), fMax: j.f("frequencymax", 5),
                                      phMin: j.f("phasemin", 0), phMax: j.f("phasemax", pTwoPi), sMin: j.f("scalemin", 0),
                                      sMax: j.f("scalemax", P ? 10 : 0.5), blend: PBlend(j))
        case "oscillatealpha":
            mask |= 0x10
            return .oscillateAlpha(osc(j, sMin: 0, sMax: 1, fMax: 10))
        case "oscillatesize":
            return .oscillateSize(osc(j, sMin: 0.8, sMax: 1.2, fMax: 10))
        case "controlpointattract":
            let flags = j.i("flags", 0)
            if flags & 1 != 0 { mask |= 4 }
            let dt = j.f("deletethreshold", P ? 15 : 0.5)
            // `offset` is parsed but not used at runtime; workshop `origin` is never read.
            return .cpAttract(scale: j.f("scale", P ? 512 : 20), threshold: j.f("threshold", P ? 512 : 5),
                              deleteThreshold2: dt * dt, cp: cp, flags: flags, blend: PBlend(j))
        case "maintaindistancetocontrolpoint":
            return .maintainDistanceToCP(distance: j.f("distance", P ? 200 : 1), variable: j.f("variablestrength", 0), cp: cp, blend: PBlend(j))
        case "maintaindistancebetweencontrolpoints":
            return .maintainDistanceBetweenCPs(start: PRemap.cp(j.i("controlpointstart", 0)), end: PRemap.cp(j.i("controlpointend", 1)), blend: PBlend(j))
        case "reducemovementnearcontrolpoint":
            let inner = j.f("distanceinner", P ? 100 : 0.5), outer = j.f("distanceouter", P ? 350 : 1)
            let ri = j.f("reductioninner", 100)
            return .reduceMovementNearCP(inner: inner, rcp: outer == inner ? 1 : SSEApprox.rcp(outer - inner), redIn: ri, // rcpps 0x1401cd3b6
                                         redOut: j.f("reductionouter", 0), cp: cp, blend: PBlend(j))
        case "turbulence":
            let m = j.v3("mask", P ? SIMD3(1, 1, 0) : SIMD3(1, 1, 1))
            let bits = (m.x != 0 ? 1 : 0) | (m.y != 0 ? 2 : 0) | (m.z != 0 ? 4 : 0)
            if bits == 0 { return nil }
            return .turbulence(PTurb(mask: m, scale: j.f("scale", P ? 0.01 : 0.5), speedMin: j.f("speedmin", P ? 500 : 1),
                                     speedMax: j.f("speedmax", P ? 1000 : 5), phaseRange: j.f("phasemax", 0) - j.f("phasemin", 0),
                                     timescale: j.f("timescale", P ? 20 : 1), axisBits: bits, audio: PAudio(j), blend: PBlend(j)))
        case "vortex", "vortex_v2":
            let v2 = j.s("name", "") == "vortex_v2"
            var axis = j.v3("axis", SIMD3(0, 0, 1))
            if simd_length_squared(axis) < (v2 ? 0.001 : 1e-7) { axis = SIMD3(0, 0, 1) }
            if !v2 { axis = POp.norm3(axis) } // glm::normalize 0x14005eb80
            let inner = j.f("distanceinner", P ? 500 : 1), outer = j.f("distanceouter", P ? 650 : 2)
            let flags = j.i("flags", 0)
            var v = PVortex(offset: j.v3("offset", .zero), axis: axis, inner: inner, rcp: outer == inner ? 1 : SSEApprox.rcp(outer - inner), // rcpps 0x1401cdce0 / 0x1401ce27e
                            speedInner: j.f("speedinner", P ? 2500 : 1), speedOuter: j.f("speedouter", 0), flags: flags, cp: cp,
                            audio: PAudio(j), blend: PBlend(j))
            if v2 {
                v.centerForce = flags & 2 != 0 ? j.f("centerforce", 1) : 0
                v.ringRadius = j.f("ringradius", P ? 300 : 1)
                v.ringWidth = j.f("ringwidth", P ? 50 : 0.2)
                v.ringPullDistance = j.f("ringpulldistance", P ? 50 : 0.25)
                v.ringRcp = v.ringPullDistance == 0 ? 1 : SSEApprox.rcp(v.ringPullDistance) // 0x1401ce239 / rcpps 0x1401ce257
                v.ringPullForce = j.f("ringpullforce", P ? 10 : 0.05)
                return .vortexV2(v)
            }
            return .vortex(v)
        case "boids":
            return .boids(sepT: j.f("separationthreshold", P ? 20 : 0.02), neighT: j.f("neighborthreshold", P ? 50 : 0.2),
                          maxSpeed: j.f("maxspeed", P ? 500 : 1), sepF: j.f("separationfactor", 15),
                          alignF: j.f("alignmentfactor", 1), cohF: j.f("cohesionfactor", 2), flags: j.i("flags", 0))
        case "capvelocity":
            return .capVelocity(maxSpeed: j.f("maxspeed", P ? 100 : 1), blend: PBlend(j))
        case "remapvalue":
            let r = PRemap(j)
            if r.output == 13 { mask |= 8 }
            if r.output == 3 { mask |= 0x10 }
            return .remap(r)
        case "inheritvaluefromevent":
            return .inheritFromEvent(mode: PInit.inheritModes.firstIndex(of: j.s("input", "setcoloropacity")) ?? 15, blend: PBlend(j))
        case "collisionplane", "collisionsphere", "collisionbounds":
            let name = j.s("name", "")
            let beh = ["bounce", "slide", "stop", "delete"].firstIndex(of: j.s("collisionbehavior", "bounce")) ?? 0
            var c = PCollision(shape: name == "collisionplane" ? .plane : name == "collisionsphere" ? .sphere : .bounds,
                               bounce: -1 - j.f("bouncefactor", 0.5), behavior: beh, flags: j.i("flags", 0), cp: cp)
            if c.shape == .plane {
                c.normal = POp.norm3(j.v3("plane", SIMD3(0, 1, 0))) // glm::normalize 0x14005eb80 (a zero plane gives NaN)
                c.distance = j.f("distance", P ? -150 : 0)
            } else if c.shape == .sphere {
                c.origin = j.v3("origin", P ? SIMD3(0, -200, 0) : .zero)
                c.radius = j.f("radius", P ? 50 : 1)
            }
            return .collision(c)
        case "collisionquad":
            mask |= 4 // prevPos array
            let beh = ["bounce", "slide", "stop", "delete"].firstIndex(of: j.s("collisionbehavior", "bounce")) ?? 0
            var flags = j.i("flags", 0)
            if mask & 2 == 0 { flags &= ~2 } // no angular arrays: the parser drops the angular-velocity bit
            let n = norm3(j.v3("plane", SIMD3(0, 1, 0))), f = norm3(j.v3("forward", SIMD3(0, 0, 1)))
            let side = norm3(cross3(n, f)), fwd = norm3(cross3(side, n))
            let size = j.v3("size", P ? SIMD3(200, 200, 0) : SIMD3(1, 1, 0))
            return .collisionQuad(PQuad(k: -1 - j.f("bouncefactor", 0.5), behavior: beh, flags: flags, cp: cp,
                                        origin: j.v3("origin", P ? SIMD3(0, -150, 0) : .zero), n: n, u: fwd, v: side,
                                        raw: (n, fwd, side), halfU: size.y * 0.5, halfV: size.x * 0.5))
        case "collisionmodel":
            let beh = ["bounce", "slide", "stop", "delete"].firstIndex(of: j.s("collisionbehavior", "bounce")) ?? 0
            return .collisionModel(PModelCollision(k: -1 - j.f("bouncefactor", 0.5), behavior: beh, flags: j.i("flags", 0)))
        default:
            // collisionbox is a runtime no-op.
            return nil
        }
    }
}

struct PRendererDef {
    enum Kind: Int { case sprite = 1, spriteTrail = 2, rope = 3, ropeTrail = 4 }
    var kind: Kind
    var orientation = 0
    var axis = SIMD3<Float>(0, 1, 0), right = SIMD3<Float>(1, 0, 0), up2 = SIMD3<Float>(0, 0, -1)
    var flags = 0
    var length: Float = 0, maxLength: Float = 0, minLength: Float = 0
    var subdivision = 0, segments = 0, fadeFlags = 0

    init?(_ j: PJ) {
        switch j.s("name", "") {
        case "sprite": kind = .sprite
        case "spritetrail": kind = .spriteTrail
        case "rope": kind = .rope
        case "ropetrail": kind = .ropeTrail
        default: return nil
        }
        switch j.s("orientation", "screen") {
        case "upright": orientation = 1
        case "fixed": orientation = 2
        default: orientation = 0
        }
        // 0x1401c2759–0x1401c297f: an exactly zero axis becomes (0,1,0); otherwise 0x14005eb80 normalises it
        // (1/sqrt((x² + y²) + z²), then multiplied). right = normalize(az − ay·0, ax·0 − az·0, ay·0 − ax) and
        // up2 = normalize(cross(axis, right unnormalised)), both as 1/sqrt then multiply; axis.x = axis.z = 0 gives
        // right (1,0,0), up2 (0,0,−1).
        let a = j.v3("axis", .zero)
        if a.x == 0 && a.y == 0 && a.z == 0 {
            axis = SIMD3(0, 1, 0)
        } else {
            let inv = 1 / sqrtf((a.x * a.x + a.y * a.y) + a.z * a.z)
            axis = SIMD3(a.x * inv, a.y * inv, a.z * inv)
        }
        if axis.x == 0 && axis.z == 0 {
            right = SIMD3(1, 0, 0); up2 = SIMD3(0, 0, -1)
        } else {
            let z: Float = 0
            let r = SIMD3<Float>(axis.z - axis.y * z, axis.x * z - axis.z * z, axis.y * z - axis.x)
            let ir = 1 / sqrtf((r.x * r.x + r.y * r.y) + r.z * r.z)
            right = SIMD3(r.x * ir, r.y * ir, r.z * ir)
            let u = SIMD3<Float>(axis.y * r.z - axis.z * r.y, axis.z * r.x - axis.x * r.z, axis.x * r.y - axis.y * r.x)
            let iu = 1 / sqrtf((u.x * u.x + u.y * u.y) + u.z * u.z)
            up2 = SIMD3(u.x * iu, u.y * iu, u.z * iu)
        }
        flags = j.i("flags", 0)
        switch kind {
        case .spriteTrail:
            length = j.f("length", 0.05); maxLength = j.f("maxlength", 10); minLength = j.f("minlength", 0)
        case .rope:
            subdivision = min(max(j.i("subdivision", 4), 0), 32)
        case .ropeTrail:
            length = max(j.f("length", 1), 0.001)
            segments = min(max(j.i("segments", 4), 2), 32)
            subdivision = min(max(j.i("subdivision", 1), 0), 32)
            fadeFlags = (j.b("fadealpha", false) ? 1 : 0) | (j.b("fadesize", false) ? 2 : 0)
        case .sprite: break
        }
    }
}

struct PControlPointDef {
    var flags = 0, parent = 0
    var offset = SIMD3<Float>(0, 0, 0)
}

struct PChildDef {
    enum Kind: Int { case staticChild = 1, eventFollow = 2, eventSpawn = 3, eventDeath = 4 }
    var name: String
    var transform: simd_float4x4
    var kind: Kind
    var flags: Int, cpStart: Int, probability: Float, maxCount: Int

    init(_ j: PJ) {
        name = j.s("name", "")
        let o = j.v3("origin", .zero), a = j.v3("angles", .zero), s = j.v3("scale", SIMD3(1, 1, 1))
        let r = particleEulerMatrix(a)
        // column i (glm) = R row i × scale_i, column 3 = origin. Here simd columns are the engine rows.
        transform = simd_float4x4(SIMD4(r.columns.0 * s.x, 0), SIMD4(r.columns.1 * s.y, 0), SIMD4(r.columns.2 * s.z, 0), SIMD4(o, 1))
        switch j.s("type", "static") {
        case "eventfollow": kind = .eventFollow
        case "eventspawn": kind = .eventSpawn
        case "eventdeath": kind = .eventDeath
        default: kind = .staticChild
        }
        flags = j.i("flags", 0)
        cpStart = j.i("controlpointstartindex", 0)
        probability = kind == .staticChild ? 1 : j.f("probability", 1)
        maxCount = kind == .staticChild ? 10 : j.i("maxcount", 10)
    }
}

/// `ParticleDef` (0x1e0): the parsed, shared definition. Instances copy mutable state out of it.
final class ParticleDef {
    struct Flags {
        static let worldSpace: UInt32 = 0x1, randomFrame: UInt32 = 0x2, perspective: UInt32 = 0x4
        static let noColorOverride: UInt32 = 0x8, noSpeedOverride: UInt32 = 0x10, noCountOverride: UInt32 = 0x20
        static let noLifetimeOverride: UInt32 = 0x40, noSizeOverride: UInt32 = 0x80
        static let ropeShader: UInt32 = 0x10000, ropeUVScroll: UInt32 = 0x20000, ropeUVSmooth: UInt32 = 0x40000
        static let ropeTrailUVScroll: UInt32 = 0x80000, noColor: UInt32 = 0x200000, spriteSheet: UInt32 = 0x1000000
        static let spriteTrail: UInt32 = 0x2000000
    }

    let path: String
    var maxCount = 0
    var flags: UInt32 = 0
    var mask: UInt8 = 0
    var startTime: Float = 0
    var sequenceMultiplier: Float = 1
    var colorn = SIMD3<Float>(0, 0, 0)
    var animationRandom = false
    var material = ""
    var uvScaleInv: Float = 1
    var emitters: [PEmitterDef] = []
    var initializers: [PInit] = []
    var operators: [POp] = []
    var renderers: [PRendererDef] = []
    var controlPoints = [PControlPointDef](repeating: PControlPointDef(), count: 8)
    var children: [PChildDef] = []
    var childMask: UInt8 = 0
    /// def+0x1a4 / +0x1a8 for rope UVs (Part 4 §5.6): average lifetime and summed emission rate.
    var ropeLife: Float = 0, ropeRate: Float = 0

    init(path: String, json: [String: Any], ortho: Bool) {
        self.path = path
        let j = PJ(json)
        maxCount = max(j.i("maxcount", 0), 0)
        flags = UInt32(j.i("flags", 0) & 0xff)
        startTime = j.f("starttime", 0)
        sequenceMultiplier = j.f("sequencemultiplier", 1)
        animationRandom = j.s("animationmode", "sequence") == "randomframe"
        if animationRandom { flags |= Flags.randomFrame }
        material = j.s("material", "")

        // colorn / hascolor normalisation `ParticleJson::normalizeColor` 0x1401c45f0 (#46, gaps6/particles/colorn_ref.py).
        // It writes into a fresh JSON object, so the file's own `colorn` key is never read; the default is (1, 1, 1).
        // The last colour initializer wins; the operators are scanned only when there is none (first colorchange).
        var hasColor = false
        colorn = SIMD3(1, 1, 1)
        for e in (json["initializer"] as? [Any]) ?? [] {
            let o = PJ(e)
            switch o.s("name", "") {
            case "colorrandom":
                let mn = o.v3("min", .zero), mx = o.v3("max", SIMD3(255, 255, 255))
                let inv255 = Float(bitPattern: 0x3b80_8081)
                colorn = SIMD3((((mx.x - mn.x) * 0.5) + mn.x) * inv255, (((mx.y - mn.y) * 0.5) + mn.y) * inv255,
                               (((mx.z - mn.z) * 0.5) + mn.z) * inv255)
                hasColor = true
            case "hsvcolorrandom":
                func mid(_ a: Float, _ b: Float) -> Float {
                    let x = (b + a) * 0.5, m: Float = x > 0 ? x : 0
                    return m < 1 ? m : 1
                }
                colorn = HSV.toRGB(SIMD3(mid(o.f("huemin", 0), o.f("huemax", 1)), mid(o.f("saturationmin", 0.5), o.f("saturationmax", 1)),
                                         mid(o.f("valuemin", 0.5), o.f("valuemax", 1))))
                hasColor = true
            case "colorlist":
                if let c = Self.colorListColorn((o.d["colors"] as? [Any]) ?? []) { colorn = c }
                hasColor = true
            default: break
            }
        }
        if !hasColor {
            for e in (json["operator"] as? [Any]) ?? [] {
                let o = PJ(e)
                guard o.s("name", "") == "colorchange" else { continue }
                colorn = o.v3("startvalue", SIMD3(1, 1, 1))
                hasColor = true
                break
            }
        }
        if !hasColor { flags |= Flags.noColor }

        for (k, c) in ((json["controlpoint"] as? [Any]) ?? []).prefix(8).enumerated() {
            let o = PJ(c)
            controlPoints[k] = PControlPointDef(flags: o.i("flags", 0), parent: min(max(o.i("parentcontrolpoint", 0), 0), 7),
                                                offset: o.v3("offset", .zero))
        }
        for e in (json["emitter"] as? [Any]) ?? [] {
            if let d = PEmitterDef(PJ(e), ortho: ortho) { emitters.append(d) }
        }
        for e in (json["initializer"] as? [Any]) ?? [] {
            if let d = PInit.parse(PJ(e), ortho: ortho, mask: &mask) { initializers.append(d) }
        }
        for e in (json["operator"] as? [Any]) ?? [] {
            if let d = POp.parse(PJ(e), ortho: ortho, mask: &mask) {
                // Only output 16 (controlpoint) takes the CP over (#44).
                if case .remap(let r) = d, r.output == 16 {
                    controlPoints[r.outCP0].flags |= 0x10000
                }
                operators.append(d)
            }
        }
        var rlist = (json["renderer"] as? [Any]) ?? []
        if rlist.isEmpty { rlist = [["name": "sprite"]] }
        var hasRope = false, hasOther = false
        for e in rlist {
            let o = PJ(e)
            guard let r = PRendererDef(o) else { continue }
            switch r.kind {
            case .rope:
                hasRope = true
                if o.b("uvscrolling", false) { flags |= Flags.ropeUVScroll } else if o.b("uvsmoothing", true) { flags |= Flags.ropeUVSmooth }
                let s = o.f("uvscale", 1)
                if s != 0 { uvScaleInv = 1 / s }
            case .ropeTrail:
                hasOther = true
                if o.b("uvscrolling", false) { flags |= Flags.ropeTrailUVScroll }
                let s = o.f("uvscale", 1)
                if s != 0 { uvScaleInv = 1 / s }
            case .spriteTrail:
                hasOther = true
                flags |= Flags.spriteTrail
            case .sprite:
                hasOther = true
            }
            renderers.append(r)
        }
        if hasRope && !hasOther { flags |= Flags.ropeShader }

        // ParticleDef_Parse 0x1401c5490 keeps two locals that the rope renderer stores (0x1401cffd9 / 0x1401cffe9):
        // def+0x1a4 = min + 0.5·range of the first lifetimerandom, taken while the local is still 0 (0x1401c72d0–0x1401c72f5);
        // def+0x1a8 = the rate of the first sphere/box emitter, taken while the local is still 0 (0x1401c6ab4–0x1401c6ac8).
        for e in initializers where ropeLife == 0 {
            if case .lifetime(let mn, let mx, _) = e { ropeLife = mn + (mx - mn) * 0.5 }
        }
        for e in emitters where ropeRate == 0 { ropeRate = e.rate }

        for c in (json["children"] as? [Any]) ?? [] {
            let d = PChildDef(PJ(c))
            guard !d.name.isEmpty else { continue }
            children.append(d)
            if d.kind != .staticChild { childMask |= UInt8(1 << d.kind.rawValue) }
        }
    }

    /// colorlist: the first element that is a string with ≥ 3 space-separated tokens, as raw RGB (colorn_ref.colorn_colorlist).
    static func colorListColorn(_ colors: [Any]) -> SIMD3<Float>? {
        for e in colors {
            guard let str = unwrapUserValue(e) as? String else { continue }
            let c = Array(str.utf8), n = c.count
            func skipNon(_ j0: Int) -> Int { var j = j0; while j < n && c[j] != 32 { j += 1 }; return j }
            func skipSp(_ j0: Int) -> Int { var j = j0; while j < n && c[j] == 32 { j += 1 }; return j }
            func num(_ a: Int, _ b: Int) -> Float { a < b ? Float(String(decoding: c[a..<b], as: UTF8.self)) ?? 0 : 0 }
            var j = skipNon(0)
            guard j < n else { continue }
            j = skipSp(j)
            let j2 = skipNon(j)
            guard j2 < n else { continue }
            let j3 = skipSp(j2)
            let first = str.split(separator: " ").first.map { Float($0) ?? 0 } ?? 0
            return SIMD3(first, num(j, j2), num(j3, skipNon(j3)))
        }
        return nil
    }

    private final class Entry {
        weak var fs: AssetFileSystem?
        let def: ParticleDef
        init(fs: AssetFileSystem, def: ParticleDef) { self.fs = fs; self.def = def }
    }
    /// Weak on the file system so unloaded wallpapers' defs are dropped; locked for background scene loads.
    private static var cache: [String: Entry] = [:]
    private static let cacheLock = NSLock()

    /// FNV-keyed def cache in the engine; here keyed by file system (one per wallpaper) and path.
    static func load(_ path: String, fs: AssetFileSystem, ortho: Bool) -> ParticleDef? {
        let key = "\(ObjectIdentifier(fs).hashValue):\(ortho ? 1 : 0):\(path)"
        if let d = cacheLock.withLock({ cache[key] }), d.fs === fs { return d.def }
        guard let json = fs.readJSON(path) as? [String: Any] else {
            NSLog("photon: particle %@ missing", path)
            return nil
        }
        let d = ParticleDef(path: path, json: json, ortho: ortho)
        cacheLock.withLock {
            cache = cache.filter { $0.value.fs != nil }
            cache[key] = Entry(fs: fs, def: d)
        }
        return d
    }
}
